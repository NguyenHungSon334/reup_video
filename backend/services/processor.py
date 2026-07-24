import os
import re
import shutil
import subprocess
import sys
from typing import Callable

from backend.services.cancel import JobCancelled, is_cancelled
from backend.services.progress import throttled

_NO_WINDOW = subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0
# Run ffmpeg below normal priority so the desktop UI thread always gets
# scheduled — CPU starvation is what triggers Flutter's GPU "context lost"
# crash on weaker machines. Lower priority lets us hand ffmpeg more threads
# for speed without freezing the app.
_LOW_PRIORITY = subprocess.BELOW_NORMAL_PRIORITY_CLASS if sys.platform == "win32" else 0
_CREATE_FLAGS = _NO_WINDOW | _LOW_PRIORITY

# Encode with half the cores (min 2). Leaves the rest for the UI + decode so
# the machine stays responsive; far faster than the old single-thread cap.
_ENCODE_THREADS = str(max(2, (os.cpu_count() or 2) // 2))

_HMS = re.compile(r"(\d+):(\d+):(\d+(?:\.\d+)?)")
_FPS = re.compile(r"([\d.]+)\s*fps")       # only read from the Stream/Video line
_FRAME = re.compile(r"frame=\s*(\d+)")     # current encoded frame in stat lines
_DIMS = re.compile(r"Video:.*?(\d{2,5})x(\d{2,5})")


def _hms_to_secs(text: str) -> float | None:
    m = _HMS.search(text)
    if not m:
        return None
    h, mnt, s = m.groups()
    return int(h) * 3600 + int(mnt) * 60 + float(s)


def _probe_duration(src: str) -> float | None:
    """Read the source video's duration up front. Needed to hard-cap output with
    -t, which prevents the -shortest + -stream_loop hang at the end of encode."""
    cmd = [_ffmpeg_exe(), "-hide_banner", "-i", src]
    try:
        # ffmpeg with no output exits non-zero but still prints Duration to stderr.
        r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                           errors="replace", timeout=30, creationflags=_NO_WINDOW)
    except Exception:
        return None
    for line in (r.stderr or "").splitlines():
        if "Duration:" in line:
            return _hms_to_secs(line.split("Duration:", 1)[-1])
    return None


def _base_dims(src: str, max_height: int) -> tuple[int, int]:
    """Output dims of the base video after the max_height downscale, so overlays
    can be scaled to an explicit size instead of via scale2ref."""
    dims = probe_dims(src)
    if not dims:
        return (-2, max_height or 720)
    w, h = dims
    if not max_height or h <= max_height:
        return (w - w % 2, h - h % 2)
    w2 = round(w * max_height / h)
    return (w2 - w2 % 2, max_height - max_height % 2)


def _has_audio(src: str) -> bool:
    """True if the file carries at least one audio stream."""
    cmd = [_ffmpeg_exe(), "-hide_banner", "-i", src]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                           errors="replace", timeout=30, creationflags=_NO_WINDOW)
    except Exception:
        return False
    return "Audio:" in (r.stderr or "")


def probe_dims(src: str) -> tuple[int, int] | None:
    """Read a video/image file's pixel width/height via ffmpeg -i (no decode)."""
    cmd = [_ffmpeg_exe(), "-hide_banner", "-i", src]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                           errors="replace", timeout=30, creationflags=_NO_WINDOW)
    except Exception:
        return None
    for line in (r.stderr or "").splitlines():
        m = _DIMS.search(line)
        if m:
            return int(m.group(1)), int(m.group(2))
    return None


def _ffmpeg_exe() -> str:
    """Return path to ffmpeg binary — bundled via imageio-ffmpeg or system PATH."""
    try:
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    except Exception:
        return "ffmpeg"


# Hardware-encoder candidates by platform, fastest first. Each maps to the
# codec_opts that give a quality roughly comparable to libx264 -crf 23.
# macOS ships VideoToolbox on every modern Mac; Windows depends on the GPU
# vendor, so we probe each and fall back to CPU libx264 if none work.
_HW_CANDIDATES: dict[str, list[tuple[str, list[str]]]] = {
    "darwin": [
        ("h264_videotoolbox", ["-c:v", "h264_videotoolbox", "-b:v", "6000k", "-realtime", "1"]),
    ],
    "win32": [
        # ONLY nvenc (NVIDIA, dedicated NVENC ASIC — separate from the render
        # engine, so it doesn't fight Flutter's D3D11 UI for the GPU). qsv (Intel)
        # and amf (AMD APU) share the SAME integrated GPU as the UI; running them
        # alongside Flutter caused a driver TDR reset → "EGL Context Lost (12302)".
        # No nvenc → fall through to CPU (libx264), which never touches the GPU.
        ("h264_nvenc", ["-c:v", "h264_nvenc", "-preset", "p4", "-rc", "vbr", "-cq", "23", "-b:v", "0"]),
    ],
}

# CPU fallback — identical to the original libx264 ultrafast path.
_CPU_ENCODER: tuple[str, list[str]] = (
    "libx264",
    ["-c:v", "libx264", "-preset", "ultrafast",
     "-x264-params", "rc-lookahead=0:ref=1:bframes=0", "-crf", "23"],
)

_selected_encoder: tuple[str, list[str]] | None = None


def _probe_encoder(name: str) -> bool:
    """Encode one tiny frame to verify the encoder actually works on this
    machine (a codec can be listed but unusable, e.g. nvenc with no NVIDIA GPU)."""
    cmd = [
        _ffmpeg_exe(), "-hide_banner", "-loglevel", "error",
        "-f", "lavfi", "-i", "testsrc=duration=0.1:size=128x128:rate=10",
        "-frames:v", "1", "-c:v", name, "-f", "null", "-",
    ]
    try:
        return subprocess.run(
            cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=15, creationflags=_NO_WINDOW,
        ).returncode == 0
    except Exception:
        return False


def _select_video_encoder(log: Callable[[str, str], None] | None = None) -> tuple[str, list[str]]:
    """Pick the fastest working H.264 encoder once, then cache it."""
    global _selected_encoder
    if _selected_encoder is not None:
        return _selected_encoder
    for name, opts in _HW_CANDIDATES.get(sys.platform, []):
        if _probe_encoder(name):
            if log:
                log(f"⚡ Using hardware encoder: {name}", "info")
            _selected_encoder = (name, opts)
            return _selected_encoder
    if log:
        log("⚙ No hardware encoder available — using CPU (libx264)", "info")
    _selected_encoder = _CPU_ENCODER
    return _selected_encoder


_LOGO_POSITIONS = {
    "top_left":     "10:10",
    "top_right":    "W-w-10:10",
    "center":       "(W-w)/2:(H-h)/2",
    "bottom_left":  "10:H-h-10",
    "bottom_right": "W-w-10:H-h-10",
}

# Seconds the video plays before the banner appears.
_BANNER_DELAY_S = 4


def process_video(
    src: str,
    dst: str,
    log: Callable[[str, str], None],
    logo: str | None = None,
    music: str | None = None,
    banner: str | None = None,
    logo_scale: int = 150,
    logo_position: str = "top_left",
    logo_opacity: float = 1.0,
    max_height: int = 720,
    banner_scale_pct: float = 100.0,
) -> str:
    if not logo and not music and not banner:
        shutil.copy2(src, dst)
        return dst

    # Probe duration so we can hard-cap the output with -t. -shortest alone hangs
    # for minutes at the end when banner/music are infinitely looped inputs.
    src_dur = _probe_duration(src) if (banner or music) else None

    cmd = [_ffmpeg_exe(), "-y"]
    # Override possibly-invalid/unspecified color metadata on the source BEFORE
    # decode. Some Douyin clips tag a colorspace the overlay buffersrc rejects
    # outright ("[graph 0 input] Invalid color space"), which happens before any
    # setparams filter can run. Forcing valid tags on the input fixes it.
    cmd += ["-colorspace", "bt709", "-color_primaries", "bt709",
            "-color_trc", "bt709", "-color_range", "tv"]
    cmd += ["-i", src]
    logo_idx = banner_idx = music_idx = None

    next_idx = 1
    if logo:
        logo_idx = next_idx; next_idx += 1
        cmd += ["-i", logo]
    if banner:
        banner_idx = next_idx; next_idx += 1
        # Banner plays once (no loop), delayed to start at _BANNER_DELAY_S.
        cmd += ["-i", banner]
    if music:
        music_idx = next_idx; next_idx += 1
        cmd += ["-stream_loop", "-1", "-i", music]

    filters: list[str] = []
    maps: list[str] = []
    codec_opts: list[str] = []

    if logo or banner:
        # Normalize the base video's pixel format + color metadata before overlay.
        # Some Douyin clips carry an invalid/variable color space that makes the
        # overlay filter reinit mid-stream and abort ("Invalid color space" /
        # "Error reinitializing filters"). Pinning params here prevents the reinit.
        # Downscale to max_height BEFORE overlay — the overlay/scale2ref filters
        # run on CPU per-frame, so fewer pixels here is the biggest speed win
        # (QSV/nvenc only accelerate the final encode, not the filtering).
        # -2 keeps aspect + even width; min() never upscales smaller clips.
        # ponytail: default 720p; raise max_height in config if quality matters.
        # setsar=1 forces square pixels. Downscaling a 9:16 clip (1080x1920 ->
        # 406x720) yields an odd SAR (405:406) that segfaults scale2ref later —
        # normalizing SAR here prevents that crash.
        scale = f"scale=-2:min(ih\\,{max_height})," if max_height else ""
        chain = [f"[0:v]{scale}setsar=1,format=yuv420p,"
                 "setparams=colorspace=bt709:color_primaries=bt709:color_trc=bt709[base]"]
        cur = "base"
        if logo:
            pos = _LOGO_POSITIONS.get(logo_position, "10:10")
            opacity = max(0.0, min(1.0, logo_opacity))
            if opacity < 1.0:
                chain.append(f"[{logo_idx}:v]scale={logo_scale}:-1,format=rgba,"
                             f"colorchannelmixer=aa={opacity:.2f}[wm]")
            else:
                chain.append(f"[{logo_idx}:v]scale={logo_scale}:-1[wm]")
            chain.append(f"[{cur}][wm]overlay={pos}[vlogo]")
            cur = "vlogo"
        if banner:
            # Banner is authored 9:16 full-frame with alpha — stretch it to the
            # base frame and overlay at 0:0, no positioning knobs needed.
            # Play once from banner's first frame, shifted to appear at t=4s.
            # Scale to explicit base dims, NOT scale2ref: scale2ref consumes one
            # reference frame per banner frame, so the base video freezes on its
            # last matched frame once the (shorter) banner ends.
            bw, bh = _base_dims(src, max_height)
            chain.append(f"[{banner_idx}:v]setsar=1,scale={bw}:{bh},format=yuva420p,"
                         f"setpts=PTS+{_BANNER_DELAY_S}/TB[bnrp]")
            # eof_action=pass: after the (unlooped) banner ends, keep the base video.
            chain.append(f"[{cur}][bnrp]overlay=0:0:eof_action=pass[outv]")
            cur = "outv"
        filters.append(";".join(chain))
        maps += ["-map", f"[{cur}]"]
        codec_opts += _select_video_encoder(log)[1]
    else:
        maps += ["-map", "0:v"]
        codec_opts += ["-c:v", "copy"]

    banner_has_voice = bool(banner) and _has_audio(banner)
    # The audio bed is the background music when enabled, otherwise the source
    # video's own audio. Music replacing source audio is the existing behaviour.
    if music:
        bed = f"[{music_idx}:a]aresample=44100,volume=1.5[bed]"
    elif _has_audio(src):
        bed = "[0:a]aresample=44100[bed]"
    else:
        bed = None

    if banner_has_voice and bed:
        # Banner voice plays over the bed; the bed ducks while the voice speaks
        # (sidechaincompress keyed off the voice), then recovers.
        delay_ms = _BANNER_DELAY_S * 1000
        filters.append(
            f"{bed};"
            f"[{banner_idx}:a]aresample=44100,adelay={delay_ms}|{delay_ms},"
            f"asplit=2[voice][vkeyr];"
            # apad: sidechaincompress ends with its SHORTEST input, so an
            # unpadded key would truncate the bed when the voice stops.
            f"[vkeyr]apad[vkey];"
            f"[bed][vkey]sidechaincompress=threshold=0.03:ratio=8:attack=20:release=800[bedd];"
            f"[bedd][voice]amix=inputs=2:duration=first:normalize=0[aout]"
        )
        maps += ["-map", "[aout]"]
        codec_opts += ["-c:a", "aac", "-b:a", "128k"]
    elif banner_has_voice:
        delay_ms = _BANNER_DELAY_S * 1000
        filters.append(f"[{banner_idx}:a]adelay={delay_ms}|{delay_ms}[aout]")
        maps += ["-map", "[aout]"]
        codec_opts += ["-c:a", "aac", "-b:a", "128k"]
    elif music:
        filters.append(f"[{music_idx}:a]volume=1.5[aout]")
        maps += ["-map", "[aout]"]
        codec_opts += ["-c:a", "aac", "-b:a", "128k"]
    else:
        maps += ["-map", "0:a"]
        codec_opts += ["-c:a", "copy"]

    if filters:
        cmd += ["-filter_complex", ";".join(filters)]
    cmd += maps + codec_opts + ["-threads", _ENCODE_THREADS]
    # Hard time-cap when duration is known (looped inputs) — deterministic stop,
    # no -shortest end-of-stream hang. Fall back to -shortest otherwise.
    if src_dur and src_dur > 0:
        cmd += ["-t", f"{src_dur:.3f}"]
    else:
        cmd += ["-shortest"]
    cmd += [dst]

    parts = (["watermark"] if logo else []) + (["banner"] if banner else []) + (["background music"] if music else [])
    log(f"▶ Adding {' + '.join(parts)}...", "info")

    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            creationflags=_CREATE_FLAGS,
        )
    except FileNotFoundError:
        raise RuntimeError(
            f"ffmpeg not found at '{cmd[0]}'. "
            "imageio-ffmpeg may have failed to provide a binary."
        )

    output_lines: list[str] = []
    emit = throttled(log)
    total_secs: float | None = src_dur
    fps: float | None = None
    total_frames: int | None = None
    for line in proc.stdout:
        if is_cancelled():
            proc.kill()
            proc.wait()
            raise JobCancelled()
        line = line.rstrip()
        if not line:
            continue
        output_lines.append(line)
        low = line.lower()
        if total_secs is None and "duration:" in low:
            total_secs = _hms_to_secs(line.split("Duration:", 1)[-1])
        if fps is None and "stream" in low and "video:" in low:
            m = _FPS.search(line)
            if m:
                fps = float(m.group(1))
        if total_frames is None and total_secs and fps:
            total_frames = round(total_secs * fps)
        if "error" in low or "invalid" in low:
            log(line, "info")  # always surface errors
        elif "time=" in line:
            # Emit real percent + frame X/total for the UI progress display.
            cur = _hms_to_secs(line.split("time=", 1)[-1])
            fm = _FRAME.search(line)
            frame_txt = ""
            if fm and total_frames:
                frame_txt = f" (frame {int(fm.group(1))}/{total_frames})"
            elif fm:
                frame_txt = f" (frame {int(fm.group(1))})"
            if total_secs and cur is not None and total_secs > 0:
                pct = max(0.0, min(100.0, cur / total_secs * 100))
                emit(f"⚙ Xử lý video: {pct:.0f}%{frame_txt}", "info", pct=pct)
            else:
                emit(line, "info")  # no duration known → raw stat line
    proc.wait()
    if proc.returncode != 0:
        tail = "\n".join(output_lines[-20:])
        raise RuntimeError(f"ffmpeg exited with code {proc.returncode}:\n{tail}")
    log("✓ Processing done", "success")
    return dst


if __name__ == "__main__":
    # Self-check: probe selection on this machine and verify the chosen
    # encoder actually round-trips a frame.
    def _safe_print(m: str, t: str) -> None:
        print(m.encode("ascii", "replace").decode("ascii"))

    name, opts = _select_video_encoder(_safe_print)
    assert opts and opts[0] == "-c:v" and opts[1] == name
    assert _probe_encoder(name), f"selected encoder {name} failed probe"
    print(f"OK — selected encoder: {name}")
