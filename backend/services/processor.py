import shutil
import subprocess
import sys
from typing import Callable

_NO_WINDOW = subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0


def _ffmpeg_exe() -> str:
    """Return path to ffmpeg binary — bundled via imageio-ffmpeg or system PATH."""
    try:
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    except Exception:
        return "ffmpeg"


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

    cmd = [_ffmpeg_exe(), "-y", "-threads", "2", "-i", src]
    logo_idx = music_idx = None

    if logo:
        logo_idx = 1
        cmd += ["-i", logo]
    if music:
        music_idx = 2 if logo else 1
        cmd += ["-stream_loop", "-1", "-i", music]

    filters: list[str] = []
    maps: list[str] = []
    extra: list[str] = []

    if logo:
        pos = _LOGO_POSITIONS.get(logo_position, "10:10")
        opacity = max(0.0, min(1.0, logo_opacity))
        if opacity < 1.0:
            filters.append(
                f"[{logo_idx}:v]scale={logo_scale}:-1,format=rgba,colorchannelmixer=aa={opacity:.2f}[wm];"
                f"[0:v][wm]overlay={pos}[vout]"
            )
        else:
            filters.append(f"[{logo_idx}:v]scale={logo_scale}:-1[wm];[0:v][wm]overlay={pos}[vout]")
        maps += ["-map", "[vout]"]
    else:
        maps += ["-map", "0:v"]
        extra += ["-c:v", "copy"]

    if music:
        # Mute original video audio, replace with music at 1.5x volume
        filters.append(f"[{music_idx}:a]volume=1.5[aout]")
        maps += ["-map", "[aout]"]
    else:
        maps += ["-map", "0:a"]
        extra += ["-c:a", "copy"]

    if filters:
        cmd += ["-filter_complex", ";".join(filters)]
    cmd += maps + extra + ["-threads", "2", "-shortest", dst]

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
    for line in proc.stdout:
        line = line.rstrip()
        if not line:
            continue
        output_lines.append(line)
        if "frame=" in line or "error" in line.lower() or "invalid" in line.lower():
            log(line, "info")
    proc.wait()
    if proc.returncode != 0:
        tail = "\n".join(output_lines[-20:])
        raise RuntimeError(f"ffmpeg exited with code {proc.returncode}:\n{tail}")
    log("✓ Processing done", "success")
    return dst
