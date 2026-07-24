"""Checks that concurrent jobs never receive a half-downloaded logo/banner,
and that a failed asset fetch is reported instead of silently skipped."""

import threading
import time
from pathlib import Path

from . import routes


def test_concurrent_download_never_returns_partial_file(tmp_path, monkeypatch):
    """Two jobs resolving the same Drive asset must both get the complete file."""
    full = b"x" * 5000

    def slow_download(file_id, destination_path, credentials_path=None):
        # Simulates chunked download: file exists and is non-empty long before
        # it is complete. The old code returned this path to the second thread.
        with open(destination_path, "wb") as fh:
            fh.write(full[:100])
            fh.flush()
            time.sleep(0.2)
            fh.write(full[100:])

    monkeypatch.setattr(routes, "download_gdrive_file", slow_download)
    monkeypatch.setattr(routes, "get_file_metadata",
                        lambda fid, credentials_path=None: {"name": "banner.mov"})
    monkeypatch.setattr(routes, "list_folder_files",
                        lambda fid, credentials_path=None: [
                            {"id": "1AAAAAAAAAAAAAAAAAAAAAAA", "name": "banner.mov"}])
    monkeypatch.setattr(routes, "_ASSET_CACHE_DIR", tmp_path)
    routes._asset_path_cache.clear()

    cfg = {"banner_gdrive_folder_id": "folder1", "banner_path": ""}
    sizes: list[int] = []

    def run():
        p = routes._pick_banner({}, cfg, str(tmp_path), lambda *a, **k: None)
        sizes.append(Path(p).stat().st_size if p else -1)

    threads = [threading.Thread(target=run) for _ in range(2)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    routes._asset_path_cache.clear()
    assert sizes == [len(full), len(full)], f"partial file leaked: {sizes}"
    assert not list(tmp_path.glob("*.part")), "temp download file left behind"


def test_failed_download_returns_none(tmp_path, monkeypatch):
    def boom(file_id, destination_path, credentials_path=None):
        Path(destination_path).write_bytes(b"partial")
        raise RuntimeError("drive 503")

    monkeypatch.setattr(routes, "download_gdrive_file", boom)
    monkeypatch.setattr(routes, "get_file_metadata",
                        lambda fid, credentials_path=None: {"name": "logo.png"})

    got = routes._download_drive_path(
        "1AAAAAAAAAAAAAAAAAAAAAAA", {}, str(tmp_path), lambda *a, **k: None)

    assert got is None
    # No truncated leftover that a later run would treat as a valid cache hit.
    assert not list(tmp_path.iterdir())
