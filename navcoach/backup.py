"""Backup / restore of the whole knowledge base (database + original files).

Secrets (.env) are never included.
"""
from __future__ import annotations

import io
import json
import shutil
import sqlite3
import tempfile
import time
import zipfile
from pathlib import Path

from . import db, index
from .config import data_dir, reset_settings_cache

MANIFEST = "navcoach-backup.json"


def create_backup(include_clients: bool = True) -> Path:
    out_dir = data_dir() / "backups"
    out_dir.mkdir(exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    out = out_dir / f"navcoach-backup-{stamp}.zip"
    with tempfile.TemporaryDirectory() as tmp:
        snap = Path(tmp) / "navcoach.db"
        src = db.connect()
        dst = sqlite3.connect(snap)
        src.backup(dst)
        dst.close()
        src.close()
        if not include_clients:
            c = sqlite3.connect(snap)
            c.execute("PRAGMA foreign_keys=ON")
            for t in ("programs", "client_analyses", "client_files", "clients"):
                c.execute(f"DELETE FROM {t}")
            c.execute("DELETE FROM queries WHERE kind IN ('client_analysis','program')")
            c.commit()
            c.close()
        with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
            z.write(snap, "navcoach.db")
            settings = data_dir() / "settings.json"
            if settings.exists():
                z.write(settings, "settings.json")
            for folder in (["library", "clients"] if include_clients else ["library"]):
                root = data_dir() / folder
                if root.exists():
                    for p in root.rglob("*"):
                        if p.is_file():
                            z.write(p, str(p.relative_to(data_dir())))
            z.writestr(MANIFEST, json.dumps({"created_at": time.time(), "include_clients": include_clients,
                                             "format": 1}))
    return out


def restore_backup(data: bytes) -> dict:
    """Replace current data with a backup. The current data is backed up first."""
    try:
        z = zipfile.ZipFile(io.BytesIO(data))
    except zipfile.BadZipFile as exc:
        raise ValueError("not a valid backup file") from exc
    names = z.namelist()
    if MANIFEST not in names or "navcoach.db" not in names:
        raise ValueError("not a Nav Coaching backup")
    for n in names:
        if n.startswith("/") or ".." in Path(n).parts:
            raise ValueError("unsafe path in backup")
    safety = create_backup()
    with tempfile.TemporaryDirectory() as tmp:
        z.extractall(tmp)
        check = sqlite3.connect(Path(tmp) / "navcoach.db")
        check.execute("SELECT COUNT(*) FROM documents").fetchone()
        check.close()
        d = data_dir()
        for folder in ("library", "clients"):
            shutil.rmtree(d / folder, ignore_errors=True)
        for suffix in ("", "-wal", "-shm"):
            p = d / f"navcoach.db{suffix}"
            if p.exists():
                p.unlink()
        shutil.copy2(Path(tmp) / "navcoach.db", d / "navcoach.db")
        for folder in ("library", "clients"):
            if (Path(tmp) / folder).exists():
                shutil.copytree(Path(tmp) / folder, d / folder)
        if (Path(tmp) / "settings.json").exists():
            shutil.copy2(Path(tmp) / "settings.json", d / "settings.json")
    db.reset_init_cache()
    reset_settings_cache()
    index.vector_cache.invalidate()
    return {"restored": True, "safety_backup": safety.name}


def list_backups() -> list[dict]:
    d = data_dir() / "backups"
    if not d.exists():
        return []
    return [{"name": p.name, "size": p.stat().st_size, "created_at": p.stat().st_mtime}
            for p in sorted(d.glob("*.zip"), reverse=True)]
