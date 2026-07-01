import shutil
import subprocess
import sys
from typing import Callable

from backend.services.progress import throttled

_NO_WINDOW = subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0


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
        ("h264_nvenc", ["-c:v", "h264_nvenc", "-preset", "p4", "-rc", "vbr", "-cq", "23", "-b:v", "0"]),
        ("h264_qsv",   ["-c:v", "h264_qsv", "-preset", "veryfast", "-global_quality", "23"]),
        ("h264_amf",   ["-c:v", "h264_amf", "-quality", "speed", "-rc", "cqp", "-qp_i", "23", "-qp_p", "23"]),
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


def process_video(
    src: str,
    dst: str,
    log: Callable[[str, str], None],
    logo: str | None = None,
    music: str | None = None,
    logo_scale: int = 150,
    logo_position: str = "top_left",
    logo_opacity: float = 1.0,
) -> str:
    if not logo and not music:
        shutil.copy2(src, dst)
        return dst

    cmd = [_ffmpeg_exe(), "-y", "-threads", "2"]
    # Override possibly-invalid/unspecified color metadata on the source BEFORE
    # decode. Some Douyin clips tag a colorspace the overlay buffersrc rejects
    # outright ("[graph 0 input] Invalid color space"), which happens before any
    # setparams filter can run. Forcing valid tags on the input fixes it.
    cmd += ["-colorspace", "bt709", "-color_primaries", "bt709",
            "-color_trc", "bt709", "-color_range", "tv"]
    cmd += ["-i", src]
    logo_idx = music_idx = None

    if logo:
        logo_idx = 1
        cmd += ["-i", logo]
    if music:
        music_idx = 2 if logo else 1
        cmd += ["-stream_loop", "-1", "-i", music]

    filters: list[str] = []
    maps: list[str] = []
    codec_opts: list[str] = []

    if logo:
        pos = _LOGO_POSITIONS.get(logo_position, "10:10")
        opacity = max(0.0, min(1.0, logo_opacity))
        # Normalize the base video's pixel format + color metadata before overlay.
        # Some Douyin clips carry an invalid/variable color space that makes the
        # overlay filter reinit mid-stream and abort ("Invalid color space" /
        # "Error reinitializing filters"). Pinning params here prevents the reinit.
        base = ("[0:v]format=yuv420p,"
                "setparams=colorspace=bt709:color_primaries=bt709:color_trc=bt709[base];")
        if opacity < 1.0:
            filters.append(
                f"[{logo_idx}:v]scale={logo_scale}:-1,format=rgba,colorchannelmixer=aa={opacity:.2f}[wm];"
                f"{base}[base][wm]overlay={pos}[vout]"
            )
        else:
            filters.append(f"[{logo_idx}:v]scale={logo_scale}:-1[wm];{base}[base][wm]overlay={pos}[vout]")
        maps += ["-map", "[vout]"]
        codec_opts += _select_video_encoder(log)[1]
    else:
        maps += ["-map", "0:v"]
        codec_opts += ["-c:v", "copy"]

    if music:
        filters.append(f"[{music_idx}:a]volume=1.5[aout]")
        maps += ["-map", "[aout]"]
        codec_opts += ["-c:a", "aac", "-b:a", "128k"]
    else:
        maps += ["-map", "0:a"]
        codec_opts += ["-c:a", "copy"]

    if filters:
        cmd += ["-filter_complex", ";".join(filters)]
    cmd += maps + codec_opts + ["-threads", "1", "-shortest", dst]

    parts = (["watermark"] if logo else []) + (["background music"] if music else [])
    log(f"▶ Adding {' + '.join(parts)}...", "info")

    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            creationflags=_NO_WINDOW,
        )
    except FileNotFoundError:
        raise RuntimeError(
            f"ffmpeg not found at '{cmd[0]}'. "
            "imageio-ffmpeg may have failed to provide a binary."
        )

    output_lines: list[str] = []
    emit = throttled(log)
    for line in proc.stdout:
        line = line.rstrip()
        if not line:
            continue
        output_lines.append(line)
        low = line.lower()
        if "error" in low or "invalid" in low:
            log(line, "info")  # always surface errors
        elif "frame=" in line:
            emit(line, "info")  # time-throttled progress spam
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
