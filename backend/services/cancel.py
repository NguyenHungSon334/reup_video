"""Cooperative cancellation for a running job.

One job runs on exactly one worker thread, so the current thread identifies the
job. That lets deep code (download loop, ffmpeg reader, Drive upload) call
`check()` directly instead of every layer in between threading a cancel flag
through its signature.

Cancellation is cooperative: it takes effect at the next checkpoint, so the
checkpoints live inside the loops that actually take time.
"""
import threading


class JobCancelled(Exception):
    """Raised at a checkpoint when the job's cancel flag is set."""

    def __str__(self) -> str:
        return "Đã hủy theo yêu cầu"


_events: dict[int, threading.Event] = {}


def bind(event: threading.Event) -> None:
    """Attach a cancel flag to the calling worker thread."""
    _events[threading.get_ident()] = event


def unbind() -> None:
    """Detach the calling thread's flag. Always call this when the job ends —
    thread ids are recycled, so a stale entry would cancel an unrelated job."""
    _events.pop(threading.get_ident(), None)


def is_cancelled() -> bool:
    event = _events.get(threading.get_ident())
    return event is not None and event.is_set()


def check() -> None:
    if is_cancelled():
        raise JobCancelled()


if __name__ == "__main__":
    ev = threading.Event()
    assert not is_cancelled()          # nothing bound
    bind(ev)
    assert not is_cancelled()          # bound but not set
    check()                            # no raise
    ev.set()
    assert is_cancelled()
    try:
        check()
        raise AssertionError("check() must raise once the flag is set")
    except JobCancelled:
        pass

    # A flag set on one thread must not cancel another thread's job.
    other: list[bool] = []
    t = threading.Thread(target=lambda: other.append(is_cancelled()))
    t.start(); t.join()
    assert other == [False], "cancel leaked across threads"

    unbind()
    assert not is_cancelled(), "unbind must clear the flag (thread ids recycle)"
    print("OK — cancel self-check passed")
