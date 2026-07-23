"""Checks for the replayable job-log buffer that lets a client reconnect
to a running job after navigating away or restarting."""

import asyncio

from fastapi import FastAPI
from fastapi.testclient import TestClient

from . import routes


def _app() -> FastAPI:
    app = FastAPI()
    app.include_router(routes.router)
    return app


def _seed(job_id: str, messages: list[dict]) -> None:
    routes._job_logs[job_id] = list(messages)
    routes._job_events[job_id] = asyncio.Event()


def test_push_appends_and_caps():
    jid = "cap-job"
    routes._job_logs[jid] = []
    routes._job_events[jid] = None
    loop = asyncio.new_event_loop()
    try:
        original_cap = routes._MAX_LOGS_PER_JOB
        routes._MAX_LOGS_PER_JOB = 3
        for i in range(5):
            routes._job_push(jid, {"type": "info", "message": str(i)}, loop)
        routes._job_push(jid, {"type": "done", "result": {"status": "success"}}, loop)
    finally:
        routes._MAX_LOGS_PER_JOB = original_cap
        loop.close()

    msgs = routes._job_logs.pop(jid)
    routes._job_events.pop(jid, None)
    assert [m["message"] for m in msgs[:3]] == ["0", "1", "2"]
    assert "cắt bớt" in msgs[3]["message"]      # truncation marker, once
    assert len(msgs) == 5                        # nothing between marker and done
    assert msgs[-1]["type"] == "done"            # 'done' always gets through


def test_ws_replays_history_from_the_start():
    jid = "replay-job"
    _seed(jid, [
        {"type": "info", "message": "a"},
        {"type": "info", "message": "b"},
        {"type": "done", "result": {"status": "success"}},
    ])
    try:
        with TestClient(_app()).websocket_connect(f"/ws/{jid}") as ws:
            assert ws.receive_json()["message"] == "a"
            assert ws.receive_json()["message"] == "b"
            assert ws.receive_json()["type"] == "done"
        # Buffer survives the disconnect so a second client replays it too.
        with TestClient(_app()).websocket_connect(f"/ws/{jid}") as ws:
            assert ws.receive_json()["message"] == "a"
    finally:
        routes._job_logs.pop(jid, None)
        routes._job_events.pop(jid, None)


def test_ws_falls_back_to_stored_result_when_buffer_expired():
    jid = "expired-job"
    routes._job_results[jid] = {"status": "success", "link": "x"}
    try:
        with TestClient(_app()).websocket_connect(f"/ws/{jid}") as ws:
            msg = ws.receive_json()
            assert msg["type"] == "done"
            assert msg["result"]["link"] == "x"
    finally:
        routes._job_results.pop(jid, None)


if __name__ == "__main__":
    test_push_appends_and_caps()
    test_ws_replays_history_from_the_start()
    test_ws_falls_back_to_stored_result_when_buffer_expired()
    print("ok")
