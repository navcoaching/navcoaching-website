"""FastAPI application: REST API + static single-page UI."""
from __future__ import annotations

import csv
import hmac
import io
import logging
import mimetypes
import os
import sys
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import Body, FastAPI, File, Form, HTTPException, Query, Request, UploadFile
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, PlainTextResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles

from . import __version__, backup, clients, compare, db, index, ingest, netguard, programs, rag
from .config import data_dir, get_settings, update_settings
from .llm import LLMUnavailable, PrivacyBlocked, get_llm

def _redirect_output_if_headless() -> None:
    """pythonw (Windows background start) has no console: write logs to a file in the data directory."""
    if sys.stdout is not None and not os.environ.get("NAV_LOG_FILE"):
        return
    path = Path(os.environ.get("NAV_LOG_FILE") or data_dir() / "navcoach.log")
    if path.exists() and path.stat().st_size > 5 * 1024 * 1024:
        path.replace(path.with_name(path.name + ".1"))
    stream = open(path, "a", encoding="utf-8", buffering=1)
    sys.stdout = sys.stderr = stream


_redirect_output_if_headless()
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("navcoach")
netguard.install()

STATIC = Path(__file__).parent / "static"
MAX_UPLOAD = int(os.environ.get("NAV_MAX_UPLOAD_MB", "200")) * 1024 * 1024
ACCESS_TOKEN = os.environ.get("NAV_ACCESS_TOKEN") or None

@asynccontextmanager
async def lifespan(_app):
    db.connect().close()
    ingest.resume_pending()
    log.info("Nav Coaching started. Data directory: %s", data_dir())
    yield


app = FastAPI(title="Nav Coaching", version=__version__, docs_url="/api/docs", redoc_url=None, lifespan=lifespan)


@app.middleware("http")
async def access_control(request: Request, call_next):
    """Optional token (needed only when the app is exposed beyond localhost, e.g. to a tablet)."""
    if ACCESS_TOKEN and request.url.path.startswith("/api"):
        supplied = request.headers.get("x-nav-token") or request.cookies.get("nav_token") or ""
        if not hmac.compare_digest(supplied, ACCESS_TOKEN):
            return JSONResponse({"detail": "unauthorized"}, status_code=401)
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Referrer-Policy"] = "no-referrer"
    return response


@app.get("/login")
def login(token: str):
    if not ACCESS_TOKEN or not hmac.compare_digest(token, ACCESS_TOKEN):
        raise HTTPException(401, "invalid token")
    r = RedirectResponse("/")
    r.set_cookie("nav_token", token, httponly=True, samesite="strict")
    return r


# ----------------------------------------------------------------- helpers

async def _read_upload(f: UploadFile) -> bytes:
    data = await f.read(MAX_UPLOAD + 1)
    if len(data) > MAX_UPLOAD:
        raise HTTPException(413, f"file larger than {MAX_UPLOAD // 1024 // 1024} MB")
    return data


def _need(obj, what="not found"):
    if obj is None:
        raise HTTPException(404, what)
    return obj


# ----------------------------------------------------------------- general

@app.get("/api/health")
def health():
    return {"ok": True, "version": __version__}


@app.get("/api/stats")
def stats():
    return ingest.library_stats()


@app.get("/api/settings")
def read_settings():
    return get_settings().public_dict()


@app.post("/api/settings")
def write_settings(changes: dict = Body(...)):
    current = get_settings()
    provider = changes.get("llm_provider", current.llm_provider)
    consent = changes.get("allow_external_llm", current.allow_external_llm)
    # Selecting an external provider requires explicit consent in the same step.
    from .config import Settings
    probe = Settings(**{**current.__dict__, **{k: v for k, v in changes.items() if k in current.__dict__}})
    probe.llm_provider = provider
    if probe.llm_is_external() and not consent:
        raise HTTPException(400, "external_model_requires_consent")
    try:
        s = update_settings(changes)
    except ValueError as exc:
        raise HTTPException(400, str(exc))
    return s.public_dict()


@app.post("/api/llm/test")
def test_llm():
    s = get_settings()
    try:
        llm = get_llm(s, "library")
    except (PrivacyBlocked, LLMUnavailable) as exc:
        return {"ok": False, "error": str(exc)}
    if llm is None:
        return {"ok": True, "provider": "none", "note": "extractive mode (no model)"}
    try:
        out = llm.complete_json('Return ONLY {"ok": true}.', "ping", max_tokens=50)
        return {"ok": bool(out.get("ok")), "provider": llm.name}
    except (LLMUnavailable, netguard.ExternalNetworkBlocked) as exc:
        return {"ok": False, "provider": llm.name, "error": str(exc)}


@app.get("/api/privacy")
def privacy():
    s = get_settings()
    return {
        "data_dir": str(data_dir()),
        "storage": "local (SQLite database + original files on this computer)",
        "llm_provider": s.llm_provider, "llm_endpoint": s.llm_endpoint(), "llm_is_external": s.llm_is_external(),
        "library_text_leaves_device": bool(s.llm_is_external() and s.allow_external_llm),
        "client_data_leaves_device": bool(s.llm_is_external() and s.allow_external_llm and s.allow_client_data_external),
        "internet_search": False,
        "network_guard": "all non-local connections are blocked except the configured model after consent",
        "recent_network_attempts": netguard.attempts()[-20:],
    }


# ----------------------------------------------------------------- documents

@app.get("/api/documents")
def documents(collection_id: str | None = None, tag: str | None = None, q: str | None = None):
    return ingest.list_documents(collection_id, tag, q)


@app.post("/api/documents")
async def upload_documents(files: list[UploadFile] = File(...), on_name_conflict: str = Form("ask"),
                           relative_paths: str | None = Form(None)):
    if on_name_conflict not in ("ask", "replace", "keep_both"):
        raise HTTPException(400, "invalid on_name_conflict")
    rel = (relative_paths or "").split("\n") if relative_paths else []
    results = []
    for i, f in enumerate(files):
        name = f.filename or "file"
        try:
            data = await _read_upload(f)
            doc = ingest.add_file(name, data, source_path=rel[i] if i < len(rel) and rel[i] else None,
                                  on_name_conflict=on_name_conflict)
            results.append({"file": name, "result": "queued", "document": doc})
        except ingest.DuplicateFile as d:
            results.append({"file": name, "result": "duplicate", "existing": {"id": d.existing["id"], "filename": d.existing["filename"]}})
        except ingest.NameConflict as c:
            results.append({"file": name, "result": "name_conflict", "existing": {"id": c.existing["id"], "filename": c.existing["filename"]}})
        except ValueError as exc:
            results.append({"file": name, "result": "rejected", "error": str(exc)})
        except HTTPException as exc:
            results.append({"file": name, "result": "rejected", "error": exc.detail})
    return {"results": results}


@app.post("/api/documents/import-folder")
def import_folder(payload: dict = Body(...)):
    try:
        return ingest.import_folder(payload.get("path", ""), payload.get("on_name_conflict", "replace"))
    except ValueError as exc:
        raise HTTPException(400, str(exc))


@app.get("/api/documents/{doc_id}")
def document(doc_id: str):
    return _need(ingest.get_document(doc_id))


@app.patch("/api/documents/{doc_id}")
def patch_document(doc_id: str, changes: dict = Body(...)):
    _need(ingest.get_document(doc_id))
    return ingest.update_document_meta(doc_id, changes)


@app.put("/api/documents/{doc_id}/file")
async def replace_document(doc_id: str, file: UploadFile = File(...)):
    _need(ingest.get_document(doc_id))
    try:
        return ingest.replace_file(doc_id, await _read_upload(file), filename=file.filename)
    except ingest.DuplicateFile as d:
        raise HTTPException(409, f"identical file already in library: {d.existing['filename']}")


@app.post("/api/documents/{doc_id}/reprocess")
def reprocess(doc_id: str):
    _need(ingest.get_document(doc_id))
    ingest.worker.enqueue(doc_id)
    return {"queued": True}


@app.delete("/api/documents/{doc_id}")
def delete_document(doc_id: str, confirm: bool = False):
    if not confirm:
        raise HTTPException(400, "confirmation required (confirm=true)")
    if not ingest.delete_document(doc_id):
        raise HTTPException(404, "not found")
    return {"deleted": True}


@app.get("/api/documents/{doc_id}/file")
def document_file(doc_id: str):
    d = _need(ingest.get_document(doc_id))
    path = (data_dir() / d["stored_path"]).resolve()
    if not str(path).startswith(str(data_dir())) or not path.exists():
        raise HTTPException(404, "file missing")
    media = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
    if path.suffix.lower() in (".txt", ".md", ".markdown", ".csv"):
        media = "text/plain; charset=utf-8"
    return FileResponse(path, media_type=media, filename=path.name, content_disposition_type="inline")


@app.get("/api/documents/{doc_id}/chunks")
def document_chunks(doc_id: str, page: int | None = None):
    with db.session() as conn:
        sql, args = "SELECT * FROM chunks WHERE doc_id=?", [doc_id]
        if page is not None:
            sql += " AND page=?"
            args.append(page)
        return [db.row_to_dict(r) for r in conn.execute(sql + " ORDER BY ordinal", args)]


@app.get("/api/chunks/{chunk_id}")
def chunk(chunk_id: str):
    with db.session() as conn:
        c = _need(db.row_to_dict(conn.execute("SELECT * FROM chunks WHERE id=?", (chunk_id,)).fetchone()),
                  "evidence not found (the source may have been deleted)")
        d = db.row_to_dict(conn.execute("SELECT id, filename, title, authors, year, doc_type, status FROM documents WHERE id=?",
                                        (c["doc_id"],)).fetchone())
        neighbours = [db.row_to_dict(r) for r in conn.execute(
            "SELECT id, ordinal, page, section, text FROM chunks WHERE doc_id=? AND ordinal BETWEEN ? AND ? ORDER BY ordinal",
            (c["doc_id"], c["ordinal"] - 1, c["ordinal"] + 1))]
    return {"chunk": c, "document": d, "context": neighbours,
            "open_url": f"/api/documents/{c['doc_id']}/file" + (f"#page={c['page']}" if d["filename"].lower().endswith(".pdf") and c["page"] else "")}


@app.get("/api/index/status")
def idx_status():
    with db.session() as conn:
        return index.index_status(conn)


@app.post("/api/index/rebuild")
def rebuild(confirm: bool = False):
    if not confirm:
        raise HTTPException(400, "confirmation required (confirm=true)")
    return ingest.rebuild_index(sync=True)


@app.get("/api/collections")
def collections():
    with db.session() as conn:
        return [dict(r) for r in conn.execute(
            "SELECT c.*, (SELECT COUNT(*) FROM document_collections dc WHERE dc.collection_id=c.id) n FROM collections c ORDER BY name")]


@app.post("/api/collections")
def add_collection(payload: dict = Body(...)):
    name = (payload.get("name") or "").strip()
    if not name:
        raise HTTPException(400, "name required")
    import time
    with db.session() as conn:
        cid = db.new_id()
        try:
            conn.execute("INSERT INTO collections(id,name,name_ar,created_at) VALUES(?,?,?,?)",
                         (cid, name[:80], (payload.get("name_ar") or name)[:80], time.time()))
        except Exception:
            raise HTTPException(409, "collection exists")
    return {"id": cid}


@app.delete("/api/collections/{cid}")
def del_collection(cid: str, confirm: bool = False):
    if not confirm:
        raise HTTPException(400, "confirmation required (confirm=true)")
    with db.session() as conn:
        conn.execute("DELETE FROM collections WHERE id=?", (cid,))
    return {"deleted": True}


@app.get("/api/tags")
def tags():
    with db.session() as conn:
        return [dict(r) for r in conn.execute("SELECT tag, COUNT(*) n FROM document_tags GROUP BY tag ORDER BY tag")]


# ----------------------------------------------------------------- ask / evidence

@app.post("/api/ask")
def ask(payload: dict = Body(...)):
    q = (payload.get("question") or "").strip()
    if not q:
        raise HTTPException(400, "question required")
    return rag.ask(q, lang=payload.get("lang", "ar"), doc_ids=payload.get("doc_ids") or None,
                   collection_id=payload.get("collection_id") or None)


@app.post("/api/search")
def search(payload: dict = Body(...)):
    q = (payload.get("query") or "").strip()
    if not q:
        raise HTTPException(400, "query required")
    s = get_settings()
    hits, diag = index.search(q, k=int(payload.get("k", 15)), doc_ids=payload.get("doc_ids") or None,
                              collection_id=payload.get("collection_id") or None)
    semantic = bool(diag.get("semantic_embedder"))
    return {"diagnostics": diag, "hits": [
        {**{k: v for k, v in h.to_dict().items()}, "passes_gate": index.passes_gate(h, s, semantic),
         "open_url": f"/api/documents/{h.doc_id}/file" + (f"#page={h.page}" if h.filename.lower().endswith('.pdf') and h.page else "")}
        for h in hits]}


@app.post("/api/compare")
def compare_studies(payload: dict = Body(...)):
    ids = payload.get("doc_ids") or []
    if len(ids) < 2:
        raise HTTPException(400, "select at least two documents")
    return compare.compare(ids, payload.get("question", ""), payload.get("lang", "ar"))


@app.get("/api/history")
def history(kind: str | None = None, limit: int = 100):
    return rag.history(limit, kind)


@app.get("/api/history/{qid}")
def history_item(qid: str):
    return _need(rag.get_query(qid))


@app.delete("/api/history/{qid}")
def history_delete(qid: str):
    with db.session() as conn:
        conn.execute("DELETE FROM queries WHERE id=?", (qid,))
    return {"deleted": True}


# ----------------------------------------------------------------- clients & programs

@app.get("/api/client-fields")
def client_fields():
    return [{"key": k, "ar": ar, "en": en, "required": req} for k, ar, en, req, _ in clients.FIELDS]


@app.get("/api/clients")
def list_clients():
    return clients.list_clients()


@app.post("/api/clients")
def create_client(payload: dict = Body(...)):
    return clients.create_client(payload.get("name", ""), payload.get("profile") or {}, payload.get("notes", ""))


@app.get("/api/clients/{cid}")
def get_client(cid: str):
    return _need(clients.get_client(cid))


@app.patch("/api/clients/{cid}")
def patch_client(cid: str, payload: dict = Body(...)):
    try:
        return clients.update_client(cid, payload.get("name"), payload.get("profile"), payload.get("notes"))
    except KeyError:
        raise HTTPException(404, "not found")


@app.delete("/api/clients/{cid}")
def delete_client(cid: str, confirm: bool = False):
    if not confirm:
        raise HTTPException(400, "confirmation required (confirm=true)")
    if not clients.delete_client(cid):
        raise HTTPException(404, "not found")
    return {"deleted": True}


@app.post("/api/clients/{cid}/files")
async def client_file(cid: str, file: UploadFile = File(...)):
    _need(clients.get_client(cid))
    return clients.add_client_file(cid, file.filename or "client.txt", await _read_upload(file))


@app.delete("/api/clients/{cid}/files/{fid}")
def client_file_delete(cid: str, fid: str, confirm: bool = False):
    if not confirm:
        raise HTTPException(400, "confirmation required (confirm=true)")
    return {"deleted": clients.delete_client_file(cid, fid)}


@app.post("/api/clients/{cid}/analyze")
def analyze_client(cid: str, payload: dict = Body(default={})):
    _need(clients.get_client(cid))
    res = clients.analyze(cid, payload.get("lang", "ar"))
    rag.log_entry("client_analysis", f"analysis:{cid}", res["readiness"], "extractive",
                  {"client_id": cid, "analysis_id": res["id"]},
                  sorted({c["doc_id"] for p in res["priorities"] if p.get("evidence")
                          for c in (p["evidence"].get("citations") or {}).values()}))
    return res


@app.post("/api/clients/{cid}/programs")
def create_program(cid: str, payload: dict = Body(default={})):
    _need(clients.get_client(cid))
    res = programs.build_program(cid, payload.get("lang", "ar"), bool(payload.get("medical_clearance_confirmed")),
                                 payload.get("title"))
    if "id" in res:
        rag.log_entry("program", f"program:{cid}", "proposed", res["content"].get("mode", "extractive"),
                      {"program_id": res["id"]}, sorted({c["doc_id"] for c in res["content"]["citations"].values()}))
    return res


@app.get("/api/programs")
def list_programs(client_id: str | None = None):
    return programs.list_programs(client_id)


@app.get("/api/programs/{pid}")
def get_program(pid: str):
    return _need(programs.get_program(pid))


@app.post("/api/programs/{pid}/revise")
def revise_program(pid: str, payload: dict = Body(...)):
    try:
        return programs.revise_program(pid, payload.get("edits") or [], payload.get("reason", ""))
    except KeyError:
        raise HTTPException(404, "not found")
    except ValueError as exc:
        raise HTTPException(400, str(exc))


@app.get("/api/programs/{pid}/export")
def export_program(pid: str, format: str = Query("md"), lang: str = "ar"):
    p = _need(programs.get_program(pid))
    if format == "csv":
        buf = io.StringIO()
        w = csv.writer(buf)
        w.writerow(["element", "proposed", "basis", "references", "applicability", "coach_notes"])
        c = p["content"]
        for e in c.get("elements", []):
            refs = "; ".join(f"{c['citations'][r]['filename']} p.{c['citations'][r].get('pdf_page') or '-'}"
                             for r in e.get("citations", []) if r in c["citations"])
            w.writerow([e["label"], e["proposed"], e["basis"], refs, "; ".join(e.get("applicability", [])),
                        e.get("coach_notes", "")])
        return Response("﻿" + buf.getvalue(), media_type="text/csv; charset=utf-8",
                        headers={"Content-Disposition": f'attachment; filename="program-{pid}.csv"'})
    return PlainTextResponse(programs.program_markdown(p, lang))


@app.delete("/api/programs/lineage/{lineage_id}")
def delete_program(lineage_id: str, confirm: bool = False):
    if not confirm:
        raise HTTPException(400, "confirmation required (confirm=true)")
    return {"deleted": programs.delete_program_lineage(lineage_id)}


# ----------------------------------------------------------------- backup

@app.post("/api/backup")
def make_backup(payload: dict = Body(default={})):
    p = backup.create_backup(include_clients=bool(payload.get("include_clients", True)))
    return {"name": p.name, "size": p.stat().st_size}


@app.get("/api/backups")
def backups():
    return backup.list_backups()


@app.get("/api/backups/{name}")
def download_backup(name: str):
    p = (data_dir() / "backups" / Path(name).name)
    if not p.exists():
        raise HTTPException(404, "not found")
    return FileResponse(p, media_type="application/zip", filename=p.name)


@app.post("/api/restore")
async def restore(file: UploadFile = File(...), confirm: bool = Form(False)):
    if not confirm:
        raise HTTPException(400, "confirmation required")
    try:
        return backup.restore_backup(await file.read())
    except ValueError as exc:
        raise HTTPException(400, str(exc))


# ----------------------------------------------------------------- UI

@app.get("/", response_class=HTMLResponse)
def ui():
    return HTMLResponse((STATIC / "index.html").read_text(encoding="utf-8"))


app.mount("/static", StaticFiles(directory=STATIC), name="static")


def run():
    import uvicorn
    host = os.environ.get("NAV_HOST", "127.0.0.1")
    port = int(os.environ.get("NAV_PORT", "8000"))
    if host not in ("127.0.0.1", "localhost") and not ACCESS_TOKEN:
        log.warning("Binding to %s without NAV_ACCESS_TOKEN — anyone on your network could access your data.", host)
    uvicorn.run(app, host=host, port=port)


if __name__ == "__main__":
    run()
