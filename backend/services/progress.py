"""Throttle high-frequency progress logs so they don't flood the WebSocket/UI.

yt-dlp, ffmpeg and Google Drive all emit progress on every tick (many per
second). Forwarding each one churns the desktop UI. `throttled` gates them to
at most one update per `min_interval` seconds, or when percent jumps by
`min_pct`, and always lets 100%/final through.
"""
import time
from typing import Callable


def throttled(
    log: Callable[[str, str], None],
    min_pct: float = 5.0,
    min_interval: float = 0.5,
) -> Callable[..., None]:
    state = {"pct": -1000.0, "t": 0.0}

    def emit(message: str, level: str = "info", pct: float | None = None) -> None:
        now = time.monotonic()
        force = pct is not None and pct >= 100
        gate_pct = pct is not None and (pct - state["pct"]) >= min_pct
        gate_time = (now - state["t"]) >= min_interval
        if force or gate_pct or gate_time:
            if pct is not None:
                state["pct"] = pct
            state["t"] = now
            log(message, level)

    return emit
