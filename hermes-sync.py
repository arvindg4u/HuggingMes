#!/usr/bin/env python3
"""
HuggingMes — Hermes Agent workspace backup via huggingface_hub.

Syncs Hermes config, memory, skills, and credentials to a private HF Dataset
so data persists across HF Space restarts.
"""

import fcntl
import hashlib
import json
import logging
import os
import shutil
import signal
import sys
import tempfile
import time
from pathlib import Path

os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
os.environ.setdefault("HF_HUB_VERBOSITY", "error")

from huggingface_hub import HfApi, snapshot_download, upload_folder
from huggingface_hub.errors import HfHubHTTPError, RepositoryNotFoundError

logging.getLogger("huggingface_hub").setLevel(logging.ERROR)

# ── Paths ──
HERMES_HOME = Path(os.environ.get("HERMES_HOME", "/opt/data"))
STATUS_FILE = Path("/tmp/hermes-sync-status.json")
SYNC_LOCK_FILE = Path("/tmp/hermes-sync.lock")
INTERVAL = int(os.environ.get("SYNC_INTERVAL", "300"))  # 5 min
INITIAL_DELAY = int(os.environ.get("SYNC_START_DELAY", "10"))

HF_TOKEN = os.environ.get("HF_TOKEN", "").strip()
HF_USERNAME = os.environ.get("HF_USERNAME", "").strip()
SPACE_AUTHOR_NAME = os.environ.get("SPACE_AUTHOR_NAME", "").strip()
BACKUP_DATASET = (
    os.environ.get("BACKUP_DATASET_NAME", "").strip()
    or os.environ.get("BACKUP_DATASET", "").strip()
    or "huggingmes-backup"
)

EXCLUDED_DIRS = {
    "node_modules", ".git", "__pycache__", ".venv", "venv",
    ".npm", ".cache", ".yarn", "logs",
}
MAX_FILE_SIZE_BYTES = 50 * 1024 * 1024

# ── Sync lock ──
class SyncLock:
    def __init__(self, path: Path):
        self.path = path
        self.fd = None

    def __enter__(self):
        self.fd = self.path.open("w")
        fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return self

    def __exit__(self, *args):
        if self.fd:
            fcntl.flock(self.fd, fcntl.LOCK_UN)
            self.fd.close()
            self.fd = None

def acquire_lock(blocking: bool = False) -> SyncLock | None:
    lock = SyncLock(SYNC_LOCK_FILE)
    try:
        lock.__enter__()
        return lock
    except OSError:
        if blocking:
            lock.fd = SYNC_LOCK_FILE.open("w")
            fcntl.flock(lock.fd, fcntl.LOCK_EX)
            return lock
        return None

# ── Status file ──
def write_status(state: str, message: str = ""):
    payload = {
        "status": state,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "message": message,
    }
    tmp = STATUS_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload), encoding="utf-8")
    tmp.replace(STATUS_FILE)

def read_status() -> dict:
    try:
        return json.loads(STATUS_FILE.read_text(encoding="utf-8"))
    except Exception:
        return {}

# ── File helpers ──
def fingerprint_dir(path: Path) -> str:
    """SHA256 of all file paths + sizes + mtimes for change detection."""
    if not path.exists():
        return ""
    h = hashlib.sha256()
    for f in sorted(path.rglob("*"), key=str):
        if not f.is_file():
            continue
        rel = str(f.relative_to(path))
        try:
            st = f.stat()
            h.update(f"{rel}:{st.st_size}:{int(st.st_mtime)}\n".encode())
        except OSError:
            continue
    return h.hexdigest()

def file_marker(path: Path) -> str:
    try:
        st = path.stat()
        return f"{st.st_size}:{int(st.st_mtime)}"
    except OSError:
        return ""

def should_exclude(name: str) -> bool:
    return name in EXCLUDED_DIRS or name.startswith(".")

def collect_sync_dirs(base: Path) -> list[Path]:
    """Collect directories to sync from HERMES_HOME."""
    dirs = []
    for entry in base.iterdir():
        if entry.is_dir() and not should_exclude(entry.name):
            dirs.append(entry)
    # Also include root config files
    for f in ["config.yaml", ".env"]:
        p = base / f
        if p.exists():
            dirs.append(p)
    return dirs

# ── Restore ──
def restore() -> bool:
    if not HF_TOKEN:
        print("[sync] SKIP restore: HF_TOKEN not set")
        return True

    repo_id = f"{HF_USERNAME}/{BACKUP_DATASET}" if HF_USERNAME else BACKUP_DATASET

    try:
        print(f"[sync] Restoring from dataset: {repo_id}")

        # Check if dataset exists
        api = HfApi()
        try:
            api.dataset_info(repo_id, token=HF_TOKEN)
        except RepositoryNotFoundError:
            print(f"[sync] Dataset {repo_id} does not exist yet — nothing to restore")
            return True

        with tempfile.TemporaryDirectory() as tmpdir:
            snapshot_download(
                repo_id=repo_id,
                repo_type="dataset",
                token=HF_TOKEN,
                local_dir=tmpdir,
                allow_patterns=["**/*"],
            )

            tmp = Path(tmpdir)
            restored = 0
            for item in tmp.iterdir():
                dest = HERMES_HOME / item.name
                if item.is_dir():
                    if dest.exists():
                        shutil.rmtree(dest, ignore_errors=True)
                    shutil.copytree(item, dest)
                    restored += 1
                elif item.is_file():
                    shutil.copy2(item, dest)
                    restored += 1

            print(f"[sync] Restored {restored} items from dataset")
            write_status("restored", f"Restored {restored} items")
            return True

    except Exception as e:
        print(f"[sync] Restore failed: {e}")
        write_status("error", f"Restore failed: {e}")
        return False

# ── Upload ──
def upload() -> bool:
    if not HF_TOKEN:
        print("[sync] SKIP upload: HF_TOKEN not set")
        return True

    repo_id = f"{HF_USERNAME}/{BACKUP_DATASET}" if HF_USERNAME else BACKUP_DATASET

    try:
        print(f"[sync] Uploading to dataset: {repo_id}")

        # Create dataset if it doesn't exist
        api = HfApi()
        try:
            api.dataset_info(repo_id, token=HF_TOKEN)
        except RepositoryNotFoundError:
            print(f"[sync] Creating dataset {repo_id}")
            api.create_repo(
                repo_id=repo_id,
                repo_type="dataset",
                private=True,
                token=HF_TOKEN,
                exist_ok=True,
            )

        # Collect files to upload
        upload_paths = []
        for entry in HERMES_HOME.iterdir():
            if entry.name in EXCLUDED_DIRS or entry.name.startswith("."):
                continue
            if entry.is_dir():
                # Check total size
                total = sum(
                    f.stat().st_size for f in entry.rglob("*") if f.is_file()
                )
                if total <= MAX_FILE_SIZE_BYTES:
                    upload_paths.append(entry)
            elif entry.is_file():
                if entry.stat().st_size <= MAX_FILE_SIZE_BYTES:
                    upload_paths.append(entry)

        # Upload via temp dir
        with tempfile.TemporaryDirectory() as tmpdir:
            staging = Path(tmpdir)
            for src in upload_paths:
                dest = staging / src.name
                if src.is_dir():
                    shutil.copytree(src, dest)
                else:
                    shutil.copy2(src, dest)

            upload_folder(
                repo_id=repo_id,
                repo_type="dataset",
                token=HF_TOKEN,
                folder_path=str(staging),
                delete_patterns=["**/*"],
                allow_patterns=["**/*"],
            )

        print(f"[sync] Uploaded {len(upload_paths)} items")
        write_status("ok", f"Uploaded {len(upload_paths)} items")
        return True

    except Exception as e:
        print(f"[sync] Upload failed: {e}")
        write_status("error", f"Upload failed: {e}")
        return False

# ── Sync once ──
def sync_once(prev_fingerprint: str = "", prev_marker: str = ""):
    """Check for changes and upload if needed."""
    fp = fingerprint_dir(HERMES_HOME)
    marker = file_marker(HERMES_HOME / "config.yaml")

    if fp == prev_fingerprint and marker == prev_marker:
        write_status("idle", "No changes detected")
        return fp, marker

    lock = acquire_lock(blocking=False)
    if not lock:
        print("[sync] Another sync in progress, skipping")
        return prev_fingerprint, prev_marker

    with lock:
        print("[sync] Changes detected, uploading...")
        upload()
        write_status("synced", "Sync complete")

    return fp, marker

# ── Sync loop ──
def loop():
    """Background sync loop."""
    print(f"[sync] Starting sync loop (interval: {INTERVAL}s)")

    time.sleep(INITIAL_DELAY)

    if not restore():
        print("[sync] Initial restore failed, continuing with local state")

    last_fp = fingerprint_dir(HERMES_HOME)
    last_marker = file_marker(HERMES_HOME / "config.yaml")

    write_status("running", "Sync loop started")

    while True:
        time.sleep(INTERVAL)
        try:
            last_fp, last_marker = sync_once(last_fp, last_marker)
        except KeyboardInterrupt:
            print("[sync] Stopped")
            break
        except Exception as e:
            print(f"[sync] Loop error: {e}")
            write_status("error", str(e))

    # Final sync on shutdown
    print("[sync] Shutdown sync...")
    sync_once(last_fp, last_marker)
    return 0

# ── Main ──
def main() -> int:
    HERMES_HOME.mkdir(parents=True, exist_ok=True)

    if len(sys.argv) < 2:
        return loop()

    cmd = sys.argv[1]
    if cmd == "restore":
        return 0 if restore() else 1
    elif cmd == "sync-once":
        try:
            sync_once()
            return 0
        except Exception as e:
            print(f"[sync] sync-once failed: {e}")
            return 1
    elif cmd == "loop":
        return loop()
    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
