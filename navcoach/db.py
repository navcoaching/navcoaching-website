"""SQLite persistence (documents, chunks, FTS index, vectors, logs, clients)."""
from __future__ import annotations

import json
import sqlite3
import threading
import time
import uuid
from contextlib import contextmanager
from pathlib import Path

from .config import data_dir

SCHEMA = """
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS documents (
    id TEXT PRIMARY KEY,
    filename TEXT NOT NULL,
    stored_path TEXT NOT NULL,
    source_path TEXT,
    sha256 TEXT NOT NULL,
    size_bytes INTEGER,
    file_type TEXT,
    status TEXT NOT NULL,            -- pending | processing | processed | needs_review | failed
    status_detail TEXT,
    title TEXT, authors TEXT, year INTEGER, doi TEXT,
    doc_type TEXT,                   -- detected: systematic_review | meta_analysis | rct | review | book | ...
    page_count INTEGER, pages_ok INTEGER, pages_failed INTEGER, pages_ocr INTEGER,
    chunk_count INTEGER DEFAULT 0,
    summary TEXT,
    extraction_report TEXT,          -- JSON: per-page status & warnings
    embedder TEXT,
    created_at REAL, updated_at REAL, processed_at REAL
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_doc_sha ON documents(sha256);

CREATE TABLE IF NOT EXISTS chunks (
    id TEXT PRIMARY KEY,
    doc_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    ordinal INTEGER NOT NULL,
    page INTEGER,                    -- 1-based PDF page / slide / sheet index (NULL if not paged)
    printed_page TEXT,               -- page label printed on the page, if detected
    location TEXT,                   -- human readable position (e.g. "paragraph 12", "Sheet1 rows 2-40")
    section TEXT,
    text TEXT NOT NULL,
    quality TEXT DEFAULT 'ok',       -- ok | ocr
    flags TEXT                       -- JSON list e.g. ["possible_instruction"]
);
CREATE INDEX IF NOT EXISTS idx_chunks_doc ON chunks(doc_id);
CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(chunk_id UNINDEXED, body, tokenize='unicode61 remove_diacritics 2');
CREATE TABLE IF NOT EXISTS vectors (
    chunk_id TEXT PRIMARY KEY REFERENCES chunks(id) ON DELETE CASCADE,
    doc_id TEXT NOT NULL,
    dim INTEGER NOT NULL,
    vec BLOB NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_vectors_doc ON vectors(doc_id);

CREATE TABLE IF NOT EXISTS collections (
    id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE, name_ar TEXT, created_at REAL
);
CREATE TABLE IF NOT EXISTS document_collections (
    doc_id TEXT REFERENCES documents(id) ON DELETE CASCADE,
    collection_id TEXT REFERENCES collections(id) ON DELETE CASCADE,
    PRIMARY KEY (doc_id, collection_id)
);
CREATE TABLE IF NOT EXISTS document_tags (
    doc_id TEXT REFERENCES documents(id) ON DELETE CASCADE,
    tag TEXT NOT NULL,
    PRIMARY KEY (doc_id, tag)
);

CREATE TABLE IF NOT EXISTS queries (
    id TEXT PRIMARY KEY,
    created_at REAL,
    kind TEXT,                       -- ask | compare | client_analysis | program
    question TEXT,
    status TEXT,                     -- answered | insufficient | error
    mode TEXT,                       -- extractive | llm:<provider>
    answer TEXT,                     -- JSON
    doc_ids TEXT,                    -- JSON list of cited documents
    network_attempts TEXT            -- JSON list of blocked/allowed external attempts during the call
);

CREATE TABLE IF NOT EXISTS clients (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    profile TEXT,                    -- JSON: manually entered fields (original data, never overwritten by inference)
    notes TEXT,
    created_at REAL, updated_at REAL
);
CREATE TABLE IF NOT EXISTS client_files (
    id TEXT PRIMARY KEY,
    client_id TEXT NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
    filename TEXT, stored_path TEXT, text TEXT, extracted TEXT, status TEXT, created_at REAL
);
CREATE INDEX IF NOT EXISTS idx_client_files ON client_files(client_id);
CREATE TABLE IF NOT EXISTS client_analyses (
    id TEXT PRIMARY KEY,
    client_id TEXT NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
    created_at REAL, result TEXT
);
CREATE TABLE IF NOT EXISTS programs (
    id TEXT PRIMARY KEY,
    client_id TEXT REFERENCES clients(id) ON DELETE CASCADE,
    lineage_id TEXT NOT NULL,        -- shared by all versions of the same program
    version INTEGER NOT NULL,
    title TEXT,
    content TEXT,                    -- JSON
    change_notes TEXT,               -- JSON: list of {field, before, after, reason}
    created_at REAL
);
CREATE INDEX IF NOT EXISTS idx_programs_client ON programs(client_id);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
"""

DEFAULT_COLLECTIONS = [
    ("Hypertrophy", "التضخم العضلي"),
    ("Strength", "القوة"),
    ("Nutrition", "التغذية"),
    ("Rehabilitation", "التأهيل"),
    ("Sleep & Recovery", "النوم والتعافي"),
    ("Mobility & Flexibility", "الحركة والمرونة"),
    ("Physiology & Biomechanics", "علم وظائف الأعضاء والميكانيكا الحيوية"),
    ("Load Management", "إدارة الحمل التدريبي"),
]

_init_lock = threading.Lock()
_initialised: set[str] = set()


def db_path() -> Path:
    return data_dir() / "navcoach.db"


def connect() -> sqlite3.Connection:
    path = db_path()
    conn = sqlite3.connect(path, timeout=30, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute("PRAGMA busy_timeout=30000")
    key = str(path)
    if key not in _initialised:
        with _init_lock:
            if key not in _initialised:
                conn.executescript(SCHEMA)
                for name, name_ar in DEFAULT_COLLECTIONS:
                    conn.execute(
                        "INSERT OR IGNORE INTO collections(id,name,name_ar,created_at) VALUES(?,?,?,?)",
                        (new_id(), name, name_ar, time.time()),
                    )
                conn.commit()
                _initialised.add(key)
    return conn


@contextmanager
def session():
    conn = connect()
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def reset_init_cache() -> None:
    _initialised.clear()


def new_id() -> str:
    return uuid.uuid4().hex[:16]


def row_to_dict(row: sqlite3.Row | None) -> dict | None:
    if row is None:
        return None
    d = dict(row)
    for k in ("extraction_report", "flags", "answer", "doc_ids", "profile", "extracted", "result", "content",
              "change_notes", "network_attempts"):
        if k in d and isinstance(d[k], str) and d[k] and d[k][0] in "[{":
            try:
                d[k] = json.loads(d[k])
            except ValueError:
                pass
    return d


def get_meta(conn: sqlite3.Connection, key: str, default: str | None = None) -> str | None:
    r = conn.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
    return r["value"] if r else default


def set_meta(conn: sqlite3.Connection, key: str, value: str) -> None:
    conn.execute("INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (key, value))
