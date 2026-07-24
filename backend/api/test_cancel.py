"""Checks the per-job cancel endpoint and the cooperative checkpoint it drives."""

import threading

from fastapi import FastAPI
from fastapi.testclient import TestClient

from ..services import cancel
from . import routes


def _client() -> TestClient:
    app = FastAPI()
    app.include_router(routes.router)
    return TestClient(app)


def test_cancel_sets_the_job_flag():
    jid = "cancel-me"
    routes._job_cancels[jid] = threading.Event()
    try:
        body = _client().post(f"/jobs/{jid}/cancel").json()
        assert body == {"cancelled": True}
        assert routes._job_cancels[jid].is_set()
    finally:
        routes._job_cancels.pop(jid, None)


def test_cancel_unknown_job_is_not_an_error():
    body = _client().post("/jobs/does-not-exist/cancel").json()
    assert body["cancelled"] is False


def test_worker_thread_stops_at_its_next_checkpoint():
    """A cancel raised on the worker thread must interrupt a running loop."""
    flag = threading.Event()
    iterations = 0
    stopped = []

    def worker():
        nonlocal iterations
        cancel.bind(flag)
        try:
            while iterations < 1000:
                cancel.check()
                iterations += 1
                if iterations == 5:
                    flag.set()  # stands in for the HTTP cancel arriving
        except cancel.JobCancelled:
            stopped.append(iterations)
        finally:
            cancel.unbind()

    t = threading.Thread(target=worker)
    t.start()
    t.join(timeout=5)

    assert stopped == [5], f"loop did not stop at the checkpoint: {stopped}"
