/* Nav Coaching — single-page UI (no build step, no external requests). */
(() => {
  "use strict";
  const S = { lang: "ar", settings: null, collections: [], pollTimer: null };
  try { S.lang = localStorage.getItem("nav_lang") || "ar"; } catch (e) { /* storage unavailable */ }
  const t = (k) => (I18N[S.lang] && I18N[S.lang][k]) ?? I18N.en[k] ?? k;
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));
  const view = () => $("#view");
  const fmtDate = (ts) => ts ? new Date(ts * 1000).toLocaleString(S.lang === "ar" ? "ar-SA-u-ca-gregory-nu-latn" : "en-GB") : "";

  async function api(path, opts = {}) {
    const o = { ...opts };
    if (o.json !== undefined) { o.body = JSON.stringify(o.json); o.headers = { "Content-Type": "application/json" }; delete o.json; }
    const r = await fetch(path, o);
    const ct = r.headers.get("content-type") || "";
    const data = ct.includes("application/json") ? await r.json() : await r.text();
    if (!r.ok) throw new Error((data && data.detail) || r.statusText);
    return data;
  }
  function toast(msg, ms = 3000) {
    const el = document.createElement("div"); el.className = "toast"; el.textContent = msg;
    document.body.appendChild(el); setTimeout(() => el.remove(), ms);
  }
  function confirmModal(text, opts = {}) {
    return new Promise((resolve) => {
      const bg = document.createElement("div"); bg.className = "modal-bg";
      bg.innerHTML = `<div class="modal" role="dialog" aria-modal="true"><p>${esc(text)}</p>
        <div class="row"><span class="spacer"></span><button class="btn secondary" data-a="no">${t("cancel")}</button>
        <button class="btn ${opts.danger === false ? "" : "danger"}" data-a="yes">${esc(opts.ok || t("yes"))}</button></div></div>`;
      bg.addEventListener("click", (e) => { const a = e.target.dataset.a; if (a || e.target === bg) { bg.remove(); resolve(a === "yes"); } });
      document.body.appendChild(bg); $("[data-a=no]", bg).focus();
    });
  }
  const statusBadge = (s) => {
    const cls = { processed: "ok", needs_review: "warn", failed: "err", pending: "info", processing: "info" }[s] || "";
    const spin = (s === "pending" || s === "processing") ? '<span class="spinner"></span> ' : "";
    return `<span class="badge ${cls}">${spin}${esc(t("st_" + s))}</span>`;
  };
  const loading = () => { view().innerHTML = `<p class="muted"><span class="spinner"></span> ${t("loading")}</p>`; };
  const errorBox = (e) => `<div class="notice err">${t("error")}: ${esc(e.message || e)}</div>`;

  // ------------------------------------------------------------------ shell
  const NAV = [["dashboard", "📊"], ["library", "📚"], ["summaries", "📖"], ["ask", "💬"], ["clients", "🧑‍🤝‍🧑"], ["programs", "🗓️"], ["evidence", "🔎"], ["settings", "⚙️"]];
  function shell() {
    document.documentElement.lang = S.lang;
    document.documentElement.dir = S.lang === "ar" ? "rtl" : "ltr";
    $$("[data-i18n]").forEach((el) => { el.textContent = t(el.dataset.i18n); });
    const page = (location.hash.slice(2).split("/")[0]) || "dashboard";
    $("#nav").innerHTML = NAV.map(([k, ic]) => `<a href="#/${k}" class="${page === k ? "active" : ""}"><span aria-hidden="true">${ic}</span>${esc(t("nav_" + k))}</a>`).join("");
    $("#langToggle").textContent = t("lang_toggle");
    const ext = S.settings && S.settings.llm_is_external && S.settings.allow_external_llm;
    $("#privacyPill").innerHTML = ext ? `⚠️ ${t("privacy_external")}` : `🔒 ${t("privacy_local")}`;
  }
  $("#langToggle").addEventListener("click", () => {
    S.lang = S.lang === "ar" ? "en" : "ar";
    try { localStorage.setItem("nav_lang", S.lang); } catch (e) { /* ignore */ }
    route();
  });

  async function route() {
    if (S.pollTimer) { clearTimeout(S.pollTimer); S.pollTimer = null; }
    if (S.keyHandler) { document.removeEventListener("keydown", S.keyHandler); S.keyHandler = null; }
    if (!S.settings) { try { S.settings = await api("/api/settings"); } catch (e) { /* ignore */ } }
    shell();
    const [page, id, sub] = location.hash.slice(2).split("/");
    try {
      const ext = window.NAV_PAGES || {};
      if (["summaries", "slides", "study"].includes(page) && ext[page]) return await ext[page](ctx(), id, sub);
      switch (page || "dashboard") {
        case "dashboard": return await Dashboard();
        case "library": return id ? await DocDetail(id) : await Library();
        case "ask": return await Ask();
        case "clients": return id ? await ClientDetail(id) : await Clients();
        case "programs": return id ? await ProgramDetail(id) : await Programs();
        case "evidence": return id ? await EvidenceDetail(id) : await Evidence();
        case "history": return await HistoryDetail(id);
        case "settings": return await Settings();
        default: return await Dashboard();
      }
    } catch (e) { view().innerHTML = errorBox(e); }
  }
  window.addEventListener("hashchange", route);

  const ctx = () => ({ api, esc, t, $, $$, toast, confirmModal, view, loading, errorBox, renderAnswer, wireJumps, fmtDate, S,
    statusBadge, route });

  // ------------------------------------------------------------------ citations
  function citationCard(c) {
    if (!c) return "";
    const pageBits = [];
    if (c.pdf_page) pageBits.push(`${t("pdf_page")}: ${esc(c.pdf_page)}`);
    if (c.pdf_page !== null && c.pdf_page !== undefined) pageBits.push(`${t("printed_page")}: ${c.printed_page ? esc(c.printed_page) : t("not_detected")}`);
    if (c.location) pageBits.push(esc(c.location));
    if (c.unit_index && !c.location) pageBits.push(`#${esc(c.unit_index)}`);
    const meta = [c.title && c.title !== c.filename ? esc(c.title) : null, c.authors ? esc(c.authors) : null, c.year ? esc(c.year) : null].filter(Boolean).join(" — ");
    return `<div class="evidence-card" id="cite-${esc(c.id)}">
      <div class="row"><span class="cite">${esc(c.id)}</span><span class="src">${esc(c.filename)}</span>
        ${c.quality === "ocr" ? '<span class="badge warn">OCR</span>' : ""}
        ${c.source_deleted ? `<span class="badge err">${t("source_deleted")}</span>` : ""}<span class="spacer"></span>
        ${c.source_deleted ? "" : `<a class="btn small secondary" target="_blank" rel="noopener" href="${esc(c.open_url)}">${t("open_in_file")}</a>
        <a class="btn small secondary" href="#/evidence/${esc(c.chunk_id)}">${t("open_evidence")}</a>`}</div>
      ${meta ? `<div class="small muted">${meta}</div>` : ""}
      <div class="small">${pageBits.join(" • ")}${c.section ? ` • ${t("section")}: ${esc(c.section)}` : ""}</div>
      ${(c.quotes && c.quotes.length ? c.quotes : (c.quote ? [c.quote] : [])).map((q) => `<div class="quote">${esc(q)}</div>`).join("")}
    </div>`;
  }
  const citeChips = (ids) => (ids || []).map((i) => `<a class="cite" href="javascript:void(0)" data-jump="${esc(i)}">${esc(i)}</a>`).join("");
  function wireJumps(root) {
    $$("[data-jump]", root).forEach((a) => a.addEventListener("click", () => {
      const el = document.getElementById("cite-" + a.dataset.jump);
      if (el) { el.scrollIntoView({ behavior: "smooth", block: "center" }); el.style.outline = "2px solid var(--gold)"; setTimeout(() => (el.style.outline = ""), 1500); }
    }));
  }

  function renderVerification(v) {
    if (!v) return "";
    const cls = v.verdict === "verified" ? "ok" : "warn";
    const vals = (v.values || []).filter((u) => u.values.length).map((u) => `<tr><td>${esc(u.unit)}</td><td>${u.values.map((x) =>
      `<b>${esc(x.value)}</b> — ${x.sources.map((s) => `${esc(s.filename)}${s.page ? ` (${t("page")} ${esc(s.page)})` : ""} <a href="#/evidence/${esc(s.chunk_id)}">${esc(s.evidence_id)}</a>`).join("، ")}`).join("<br>")}</td></tr>`).join("");
    const files = Object.entries(v.supporting_by_file || {}).map(([f, n]) => `${esc(f)}: ${esc(n)}`).join(" • ");
    return `<div class="notice ${cls}" style="margin-top:12px"><h3 style="margin-top:0">🔎 ${t("final_check")}</h3>
      ${(v.summary || []).map((l) => `<div>${esc(l)}</div>`).join("")}
      ${files ? `<div class="small muted" style="margin-top:4px">${t("support_by_file")}: ${files}</div>` : ""}
      ${vals ? `<table class="small" style="margin-top:6px"><tr><th>${t("stated_values")}</th><th></th></tr>${vals}</table>` : ""}
      <details class="small"><summary>${t("files_scanned")} (${esc((v.files_scanned || []).length)})</summary>${(v.files_scanned || []).map(esc).join("<br>")}</details></div>`;
  }

  function renderAnswer(r) {
    const parts = [];
    parts.push(`<div class="notice">${esc(r.notice)}</div>`);
    if (r.mode_note) parts.push(`<div class="notice">${esc(r.mode_note)}</div>`);
    if (r.untranslated_hint) parts.push(`<div class="notice warn small">🔤 ${esc(r.untranslated_hint)}</div>`);
    if (r.status !== "answered") {
      parts.push(`<div class="notice warn"><b>${esc(r.message)}</b><br>${esc(r.next_steps || "")}</div>`);
      if (r.near_misses && r.near_misses.length) {
        parts.push(`<h3>${t("near_misses")}</h3><ul>${r.near_misses.map((n) => `<li><a href="#/evidence/${esc(n.chunk_id)}">${esc(n.filename)}</a> ${n.page ? `(${t("page")} ${esc(n.page)})` : ""} — ${t("coverage")}: ${Math.round(n.coverage * 100)}%</li>`).join("")}</ul>`);
      }
    } else {
      parts.push(`<h2>${t("answer")}</h2>`);
      r.claims.forEach((c) => {
        const typ = c.type === "quote" ? t("quote") : c.type === "inference" ? t("inference") : t("stated");
        const badge = c.type === "inference" ? "warn" : c.type === "quote" ? "info" : "ok";
        parts.push(`<div class="claim"><div class="meta"><span class="badge ${badge}">${esc(typ)}</span></div>
          ${c.type === "quote" ? `<div class="quote">${esc(c.text)}</div>` : `<div>${esc(c.text)}</div>`}
          <div>${citeChips(c.citations)}</div>
          ${(c.also_stated_in || []).length ? `<div class="small muted">✔ ${t("also_stated")} ${esc(c.also_stated_in.length)}: ${c.also_stated_in.slice(0, 12).map((x) => `<a href="#/evidence/${esc(x.chunk_id)}">${esc(x.filename)}${x.page ? ` ${t("page")} ${esc(x.page)}` : ""}</a>`).join("، ")}${c.also_stated_in.length > 12 ? " …" : ""}</div>` : ""}
          ${(c.warnings || []).map((w) => `<div class="small" style="color:#9a6a0f">⚠ ${esc(w)}</div>`).join("")}</div>`);
      });
      if (r.conflicts && r.conflicts.length) {
        parts.push(`<h2>⚖️ ${t("conflicts")}</h2>`);
        r.conflicts.forEach((cf) => {
          parts.push(`<div class="conflict"><div><b>${esc(cf.topic)}</b></div>${cf.positions.map((p) => `
            <div style="margin-top:6px"><span class="badge">${esc(p.polarity ? t(p.polarity) : "")}</span> <b>${esc(p.filename)}</b> ${citeChips(p.evidence_id ? [p.evidence_id] : [])}
            ${p.text ? `<div class="quote">${esc(p.text)}</div>` : ""}</div>`).join("")}</div>`);
        });
      }
      parts.push(renderVerification(r.verification));
      parts.push(`<h2>${t("evidence")}</h2>`);
      Object.values(r.citations || {}).forEach((c) => parts.push(citationCard(c)));
      if (r.documents_used) parts.push(`<p class="small muted">${t("documents_used")}: ${r.documents_used.map(esc).join("، ")}</p>`);
    }
    if ((r.limitations || []).length || (r.gaps || []).length) {
      parts.push(`<h3>${t("limitations")}</h3><ul>${(r.limitations || []).map((l) => `<li>${esc(l)}</li>`).join("")}${(r.gaps || []).map((g) => `<li>${t("gaps")}: ${esc(g)}</li>`).join("")}</ul>`);
    }
    if ((r.rejected_claims || []).length) {
      parts.push(`<details><summary>${t("rejected")} (${r.rejected_claims.length})</summary><ul>${r.rejected_claims.map((x) => `<li>${esc(x.text)} — <span class="muted">${esc((x.reasons || []).join("; "))}</span></li>`).join("")}</ul></details>`);
    }
    if ((r.warnings || []).length) parts.push(`<div class="notice warn small">${r.warnings.map(esc).join("<br>")}</div>`);
    const net = r.network || {};
    parts.push(`<p class="small muted">${t("mode")}: ${esc(r.mode)} • ${net.external_attempts ? `external attempts: ${esc(net.external_attempts)} (blocked ${esc(net.blocked)})` : t("network_ok")}</p>`);
    return parts.join("");
  }

  // ------------------------------------------------------------------ dashboard
  async function Dashboard() {
    loading();
    const [st, docs] = await Promise.all([api("/api/stats"), api("/api/documents")]);
    const k = (v, l) => `<div class="kpi"><div class="v">${esc(v)}</div><div class="l">${esc(l)}</div></div>`;
    view().innerHTML = `<h1>${t("dash_title")}</h1><p class="sub">${t("dash_sub")}</p>
      ${st.index.needs_rebuild ? `<div class="notice warn">${t("index_needs_rebuild")}</div>` : ""}
      <div class="grid k4">${k(st.docs, t("k_docs"))}${k(st.pages_ok + st.pages_ocr, t("k_pages"))}${k(st.pages_failed, t("k_failed_pages"))}${k(st.chunks, t("k_chunks"))}${k(st.queries, t("k_queries"))}${k(st.clients, t("k_clients"))}${k(st.programs, t("k_programs"))}</div>
      <div class="grid k2" style="margin-top:16px">
        <div class="card"><h2>${t("by_status")}</h2>${Object.entries(st.by_status).map(([s, n]) => `<div class="row">${statusBadge(s)}<span class="spacer"></span><b>${n}</b></div>`).join("") || `<p class="muted">${t("none")}</p>`}</div>
        <div class="card"><h2>${t("by_type")}</h2>${Object.entries(st.by_type).map(([s, n]) => `<div class="row"><span>${esc(s)}</span><span class="spacer"></span><b>${n}</b></div>`).join("") || `<p class="muted">${t("none")}</p>`}</div>
      </div>
      <div class="card"><h2>${t("recent_docs")}</h2>${docTable(docs.slice(0, 8), false)}</div>`;
    if (st.queue || docs.some((d) => d.status === "pending" || d.status === "processing")) S.pollTimer = setTimeout(route, 2500);
  }

  function docTable(docs, actions = true) {
    if (!docs.length) return `<p class="muted">${t("none")}</p>`;
    return `<div class="table-wrap"><table><thead><tr><th>${t("col_file")}</th><th>${t("col_title")}</th><th>${t("col_year")}</th><th>${t("col_type")}</th><th>${t("col_status")}</th><th>${t("col_pages")}</th>${actions ? `<th>${t("col_actions")}</th>` : ""}</tr></thead><tbody>
      ${docs.map((d) => `<tr><td><a href="#/library/${esc(d.id)}">${esc(d.filename)}</a>${(d.tags || []).map((x) => ` <span class="badge">${esc(x)}</span>`).join("")}</td>
        <td>${esc(d.title || "")}</td><td>${esc(d.year || "")}</td><td>${esc(d.doc_type || "")}</td>
        <td>${statusBadge(d.status)}${d.status_detail ? `<div class="small muted">${esc(d.status_detail)}</div>` : ""}</td>
        <td>${d.page_count != null ? `${esc(d.pages_ok + (d.pages_ocr || 0))}/${esc(d.page_count)}` : ""}</td>
        ${actions ? `<td class="row"><a class="btn small secondary" href="#/library/${esc(d.id)}">${t("view")}</a><button class="btn small danger" data-del="${esc(d.id)}" data-name="${esc(d.filename)}">${t("del")}</button></td>` : ""}</tr>`).join("")}
      </tbody></table></div>`;
  }

  // ------------------------------------------------------------------ library
  async function Library() {
    loading();
    S.collections = await api("/api/collections");
    const params = new URLSearchParams(location.hash.split("?")[1] || "");
    view().innerHTML = `<h1>${t("lib_title")}</h1><p class="sub">${t("lib_sub")}</p>
      <div class="card">
        <div class="dropzone" id="dz">${t("drop_here")}
          <label class="btn secondary small" style="margin:0 6px">${t("choose_files")}<input id="fileIn" type="file" multiple hidden accept=".pdf,.docx,.pptx,.xlsx,.xlsm,.csv,.txt,.md,.markdown"></label>
          <label class="btn secondary small">${t("choose_folder")}<input id="folderIn" type="file" webkitdirectory multiple hidden></label>
        </div>
        <div class="row" style="margin-top:10px"><span class="small">${t("name_conflict")}</span>
          <select id="nc"><option value="ask">${t("nc_ask")}</option><option value="replace">${t("nc_replace")}</option><option value="keep_both">${t("nc_keep")}</option></select></div>
        <div class="row" style="margin-top:10px"><span class="small">${t("import_path")}</span><input type="text" id="pathIn" style="min-width:260px" placeholder="C:\\Research or /home/me/research"><button class="btn small" id="pathBtn">${t("import")}</button></div>
        <div id="upRes"></div>
      </div>
      <div class="card">
        <div class="row" style="margin-bottom:10px"><input type="text" id="q" placeholder="${t("search_library")}" value="${esc(params.get("q") || "")}">
          <select id="colF"><option value="">${t("all_collections")}</option>${S.collections.map((c) => `<option value="${esc(c.id)}">${esc(S.lang === "ar" ? c.name_ar || c.name : c.name)} (${c.n})</option>`).join("")}</select>
          <span class="spacer"></span>
          <input type="text" id="newCol" placeholder="${t("new_collection")}"><button class="btn small secondary" id="addCol">${t("add")}</button></div>
        <div id="docList"></div>
      </div>`;
    const load = async () => {
      const qs = new URLSearchParams();
      if ($("#q").value) qs.set("q", $("#q").value);
      if ($("#colF").value) qs.set("collection_id", $("#colF").value);
      const docs = await api("/api/documents?" + qs);
      $("#docList").innerHTML = docTable(docs);
      $$("[data-del]").forEach((b) => b.addEventListener("click", async () => {
        if (!(await confirmModal(`${b.dataset.name}: ${t("confirm_delete_doc")}`))) return;
        await api(`/api/documents/${b.dataset.del}?confirm=true`, { method: "DELETE" }); toast(t("saved")); load();
      }));
      if (docs.some((d) => d.status === "pending" || d.status === "processing")) S.pollTimer = setTimeout(load, 2000);
    };
    $("#q").addEventListener("input", () => { clearTimeout(S.pollTimer); load(); });
    $("#colF").addEventListener("change", load);
    $("#addCol").addEventListener("click", async () => {
      const n = $("#newCol").value.trim(); if (!n) return;
      try { await api("/api/collections", { method: "POST", json: { name: n, name_ar: n } }); Library(); } catch (e) { toast(e.message); }
    });
    const upload = async (files, rels) => {
      if (!files.length) return;
      const fd = new FormData();
      files.forEach((f) => fd.append("files", f));
      fd.append("on_name_conflict", $("#nc").value);
      if (rels) fd.append("relative_paths", rels.join("\n"));
      $("#upRes").innerHTML = `<p><span class="spinner"></span> ${t("loading")}</p>`;
      try {
        const res = await api("/api/documents", { method: "POST", body: fd });
        $("#upRes").innerHTML = `<h3>${t("upload_results")}</h3><ul>${res.results.map((r) => `<li><b>${esc(r.file)}</b>: ${esc(t("r_" + r.result))}${r.error ? ` — ${esc(r.error)}` : ""}${r.existing ? ` → <a href="#/library/${esc(r.existing.id)}">${esc(r.existing.filename)}</a>` : ""}</li>`).join("")}</ul>`;
      } catch (e) { $("#upRes").innerHTML = errorBox(e); }
      load();
    };
    const ok = (f) => /\.(pdf|docx|pptx|xlsx|xlsm|csv|txt|md|markdown)$/i.test(f.name);
    $("#fileIn").addEventListener("change", (e) => upload(Array.from(e.target.files)));
    $("#folderIn").addEventListener("change", (e) => { const fs = Array.from(e.target.files).filter(ok); upload(fs, fs.map((f) => f.webkitRelativePath || f.name)); });
    const dz = $("#dz");
    dz.addEventListener("dragover", (e) => { e.preventDefault(); dz.classList.add("drag"); });
    dz.addEventListener("dragleave", () => dz.classList.remove("drag"));
    dz.addEventListener("drop", (e) => { e.preventDefault(); dz.classList.remove("drag"); upload(Array.from(e.dataTransfer.files).filter(ok)); });
    $("#pathBtn").addEventListener("click", async () => {
      const p = $("#pathIn").value.trim(); if (!p) return;
      $("#upRes").innerHTML = `<p><span class="spinner"></span> ${t("loading")}</p>`;
      try {
        const r = await api("/api/documents/import-folder", { method: "POST", json: { path: p, on_name_conflict: $("#nc").value === "ask" ? "replace" : $("#nc").value } });
        $("#upRes").innerHTML = `<div class="notice">added: ${r.added.length} • replaced: ${r.replaced.length} • duplicates: ${r.duplicates.length} • skipped: ${r.skipped.length} • errors: ${r.errors.length}</div>`;
      } catch (e) { $("#upRes").innerHTML = errorBox(e); }
      load();
    });
    load();
  }

  async function DocDetail(id) {
    loading();
    const [d, cols] = await Promise.all([api(`/api/documents/${id}`), api("/api/collections")]);
    const rep = d.extraction_report || { units: [] };
    const inCol = new Set((d.collections || []).map((c) => c.id));
    view().innerHTML = `<p><a href="#/library">← ${t("back")}</a></p><h1>${esc(d.title || d.filename)}</h1>
      <div class="row">${statusBadge(d.status)}<span class="muted small">${esc(d.filename)} • ${esc(d.status_detail || "")}</span></div>
      <div class="row" style="margin:12px 0"><a class="btn secondary" target="_blank" rel="noopener" href="/api/documents/${esc(d.id)}/file">${t("open_file")}</a>
        <button class="btn secondary" id="rp">${t("reprocess")}</button>
        <label class="btn secondary">${t("replace_file")}<input type="file" id="rf" hidden></label>
        <span class="spacer"></span><button class="btn danger" id="del">${t("del")}</button></div>
      <div id="docStudy"></div>
      <div class="grid k2">
        <div class="card"><h2>${t("doc_details")}</h2><p class="small muted">${t("meta_note")}</p>
          <label class="field"><span>${t("title")}</span><input class="wide" type="text" id="m_title" value="${esc(d.title || "")}"></label>
          <label class="field"><span>${t("authors")}</span><input class="wide" type="text" id="m_authors" value="${esc(d.authors || "")}"></label>
          <div class="row"><label class="field"><span>${t("year")}</span><input type="number" id="m_year" value="${esc(d.year || "")}"></label>
          <label class="field"><span>${t("doc_type")}</span><input type="text" id="m_type" value="${esc(d.doc_type || "")}"></label></div>
          <label class="field"><span>${t("tags")}</span><input class="wide" type="text" id="m_tags" value="${esc((d.tags || []).join(", "))}"></label>
          <div class="field"><span class="small muted">${t("collections")}</span><div class="row">${cols.map((c) => `<label class="small"><input type="checkbox" value="${esc(c.id)}" ${inCol.has(c.id) ? "checked" : ""}> ${esc(S.lang === "ar" ? c.name_ar || c.name : c.name)}</label>`).join("")}</div></div>
          <button class="btn" id="saveMeta">${t("save")}</button>
          ${d.doi ? `<p class="small">DOI: ${esc(d.doi)}</p>` : ""}</div>
        <div class="card"><h2>${t("summary_extracted")}</h2>${d.summary ? `<div class="quote">${esc(d.summary)}</div>` : `<p class="muted">${t("none")}</p>`}
          <p class="small muted">${t("k_chunks")}: ${esc(d.chunk_count)} • ${t("col_pages")}: ${esc(d.pages_ok ?? "-")}/${esc(d.page_count ?? "-")} • OCR: ${esc(d.pages_ocr ?? 0)} • ${t("k_failed_pages")}: ${esc(d.pages_failed ?? 0)}</p></div>
      </div>
      <div class="card"><h2>${t("extraction_report")}</h2>
        ${(rep.warnings || []).map((w) => `<div class="notice warn small">${esc(w)}</div>`).join("")}
        <div class="table-wrap"><table><thead><tr><th>#</th><th>${t("printed_page")}</th><th>${t("col_status")}</th><th>chars</th><th></th></tr></thead><tbody>
        ${rep.units.map((u, i) => `<tr><td>${esc(u.page ?? u.location ?? i + 1)}</td><td>${esc(u.printed_page || "")}</td>
          <td><span class="badge ${u.status === "ok" ? "ok" : u.status === "ocr" ? "warn" : u.status === "empty" ? "" : "err"}">${esc(t("unit_" + u.status))}</span></td>
          <td>${esc(u.chars)}</td><td class="small">${(u.warnings || []).map(esc).join("; ")}</td></tr>`).join("")}</tbody></table></div></div>`;
    if (window.NAV_PAGES && window.NAV_PAGES.docPanel) window.NAV_PAGES.docPanel(ctx(), d, $("#docStudy")).catch(() => {});
    $("#del").addEventListener("click", async () => {
      if (!(await confirmModal(t("confirm_delete_doc")))) return;
      await api(`/api/documents/${id}?confirm=true`, { method: "DELETE" }); location.hash = "#/library";
    });
    $("#rp").addEventListener("click", async () => { await api(`/api/documents/${id}/reprocess`, { method: "POST" }); toast(t("st_pending")); setTimeout(route, 1500); });
    $("#rf").addEventListener("change", async (e) => {
      const f = e.target.files[0]; if (!f) return;
      const fd = new FormData(); fd.append("file", f);
      try { await api(`/api/documents/${id}/file`, { method: "PUT", body: fd }); toast(t("st_pending")); setTimeout(route, 1500); } catch (er) { toast(er.message); }
    });
    $("#saveMeta").addEventListener("click", async () => {
      await api(`/api/documents/${id}`, { method: "PATCH", json: {
        title: $("#m_title").value, authors: $("#m_authors").value, year: $("#m_year").value ? parseInt($("#m_year").value, 10) : null,
        doc_type: $("#m_type").value, tags: $("#m_tags").value.split(/[,،]/).map((x) => x.trim()).filter(Boolean),
        collection_ids: $$(".grid input[type=checkbox]:checked").map((c) => c.value) } });
      toast(t("saved"));
    });
    if (d.status === "pending" || d.status === "processing") S.pollTimer = setTimeout(route, 2000);
  }

  // ------------------------------------------------------------------ ask
  async function Ask() {
    loading();
    const [cols, docs] = await Promise.all([api("/api/collections"), api("/api/documents")]);
    const usable = docs.filter((d) => d.status === "processed" || d.status === "needs_review");
    view().innerHTML = `<h1>${t("ask_title")}</h1><p class="sub">${t("ask_sub")}</p>
      <div class="tabs"><button class="active" data-tab="ask">${t("ask_title")}</button><button data-tab="cmp">${t("compare_title")}</button></div>
      <div id="tab-ask"><div class="card">
        <textarea id="question" placeholder="${t("ask_placeholder")}"></textarea>
        <div class="row" style="margin-top:8px"><span class="small">${t("limit_scope")}</span>
          <select id="scope"><option value="">${t("all_library")}</option>${cols.map((c) => `<option value="${esc(c.id)}">${esc(S.lang === "ar" ? c.name_ar || c.name : c.name)}</option>`).join("")}</select>
          <span class="spacer"></span><button class="btn" id="askBtn">${t("ask_btn")}</button></div>
      </div><div id="answer"></div></div>
      <div id="tab-cmp" hidden><div class="card"><p class="small muted">${t("compare_sub")}</p>
        <div style="max-height:220px;overflow:auto">${usable.map((d) => `<label class="small" style="display:block"><input type="checkbox" class="cmpDoc" value="${esc(d.id)}"> ${esc(d.title || d.filename)} <span class="muted">(${esc(d.filename)})</span></label>`).join("") || `<p class="muted">${t("none")}</p>`}</div>
        <div class="row" style="margin-top:8px"><input type="text" id="cmpQ" style="flex:1" placeholder="${t("optional_question")}"><button class="btn" id="cmpBtn">${t("compare_btn")}</button></div>
      </div><div id="cmpOut"></div></div>`;
    $$("[data-tab]").forEach((b) => b.addEventListener("click", () => {
      $$("[data-tab]").forEach((x) => x.classList.toggle("active", x === b));
      $("#tab-ask").hidden = b.dataset.tab !== "ask"; $("#tab-cmp").hidden = b.dataset.tab !== "cmp";
    }));
    const go = async () => {
      const q = $("#question").value.trim(); if (!q) return;
      $("#askBtn").disabled = true; $("#answer").innerHTML = `<p><span class="spinner"></span> ${t("loading")}</p>`;
      try {
        const r = await api("/api/ask", { method: "POST", json: { question: q, lang: S.lang, collection_id: $("#scope").value || null } });
        $("#answer").innerHTML = `<div class="card">${renderAnswer(r)}</div>`; wireJumps($("#answer"));
      } catch (e) { $("#answer").innerHTML = errorBox(e); }
      $("#askBtn").disabled = false;
    };
    $("#askBtn").addEventListener("click", go);
    $("#question").addEventListener("keydown", (e) => { if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) go(); });
    $("#cmpBtn").addEventListener("click", async () => {
      const ids = $$(".cmpDoc:checked").map((c) => c.value);
      if (ids.length < 2) { toast(t("compare_sub")); return; }
      $("#cmpOut").innerHTML = `<p><span class="spinner"></span></p>`;
      try {
        const r = await api("/api/compare", { method: "POST", json: { doc_ids: ids, question: $("#cmpQ").value, lang: S.lang } });
        $("#cmpOut").innerHTML = `<div class="card"><div class="notice small">${esc(r.note)}</div><div class="table-wrap"><table><thead><tr><th>${t("col_title")}</th><th>${t("col_year")}</th>${r.columns.map((c) => `<th>${esc(c.label)}</th>`).join("")}</tr></thead><tbody>
          ${r.rows.map((row) => `<tr><td><b>${esc(row.title)}</b><div class="small muted">${esc(row.filename)}</div></td><td>${esc(row.year)}</td>
          ${r.columns.map((c) => { const cell = row.cells[c.key] || {}; return `<td class="small">${cell.citation ? `<span style="unicode-bidi:plaintext">${esc(cell.text)}</span> ${citeChips([cell.citation])}` : `<span class="muted">${esc(cell.text || "")}</span>`}</td>`; }).join("")}</tr>`).join("")}
          </tbody></table></div><h3>${t("evidence")}</h3>${Object.values(r.citations).map(citationCard).join("")}</div>`;
        wireJumps($("#cmpOut"));
      } catch (e) { $("#cmpOut").innerHTML = errorBox(e); }
    });
  }

  // ------------------------------------------------------------------ evidence
  async function Evidence() {
    loading();
    const hist = await api("/api/history?limit=100");
    view().innerHTML = `<h1>${t("ev_title")}</h1><p class="sub">${t("ev_sub")}</p>
      <div class="card"><div class="row"><input type="text" id="sq" style="flex:1" placeholder="${t("ev_search")}"><button class="btn" id="sb">${t("ev_search")}</button></div><div id="hits"></div></div>
      <div class="card"><h2>${t("history")}</h2><div class="table-wrap"><table><thead><tr><th></th><th>${t("ask_btn")}</th><th>${t("col_status")}</th><th>${t("mode")}</th><th>${t("documents_used")}</th></tr></thead><tbody>
      ${hist.map((h) => `<tr><td class="small">${esc(fmtDate(h.created_at))}<div class="badge">${esc(h.kind)}</div></td><td>${h.kind === "ask" || h.kind === "compare" ? `<a href="#/history/${esc(h.id)}">${esc(h.question)}</a>` : esc(h.question)}</td>
        <td><span class="badge ${h.status === "answered" ? "ok" : "warn"}">${esc(h.status)}</span></td><td class="small">${esc(h.mode)}</td>
        <td class="small">${(h.documents || []).map((d) => d.deleted ? `<s>${esc(d.doc_id)}</s> <span class="badge err">${t("source_deleted")}</span>` : `<a href="#/library/${esc(d.doc_id)}">${esc(d.filename)}</a>`).join("<br>")}</td></tr>`).join("")}
      </tbody></table></div></div>`;
    $("#sb").addEventListener("click", async () => {
      const q = $("#sq").value.trim(); if (!q) return;
      $("#hits").innerHTML = `<p><span class="spinner"></span></p>`;
      const r = await api("/api/search", { method: "POST", json: { query: q, k: 15 } });
      $("#hits").innerHTML = (r.hits.length ? r.hits : []).map((h) => `<div class="evidence-card"><div class="row"><span class="src">${esc(h.filename)}</span>
        ${h.page ? `<span class="small">${t("page")} ${esc(h.page)}${h.printed_page ? ` (${t("printed_page")} ${esc(h.printed_page)})` : ""}</span>` : `<span class="small">${esc(h.location || "")}</span>`}
        ${h.section ? `<span class="small muted">${esc(h.section)}</span>` : ""}<span class="spacer"></span>
        <span class="badge ${h.passes_gate ? "ok" : ""}">${h.passes_gate ? t("passes_gate") : t("fails_gate")} • ${t("coverage")} ${Math.round(h.coverage * 100)}%</span>
        <a class="btn small secondary" href="#/evidence/${esc(h.chunk_id)}">${t("open_evidence")}</a></div>
        <div class="passage small">${esc(h.text.slice(0, 600))}${h.text.length > 600 ? "…" : ""}</div></div>`).join("") || `<p class="muted">${t("none")}</p>`;
    });
  }

  async function EvidenceDetail(chunkId) {
    loading();
    const r = await api(`/api/chunks/${chunkId}`);
    const c = r.chunk;
    view().innerHTML = `<p><a href="javascript:history.back()">← ${t("back")}</a></p>
      <h1>${esc(r.document.title || r.document.filename)}</h1>
      <p class="sub">${esc(r.document.filename)} • ${c.page ? `${t("page")} ${esc(c.page)}` : esc(c.location || "")} ${c.printed_page ? `• ${t("printed_page")} ${esc(c.printed_page)}` : ""} ${c.section ? `• ${t("section")}: ${esc(c.section)}` : ""}</p>
      ${c.quality === "ocr" ? `<div class="notice warn">OCR</div>` : ""}
      ${(c.flags || []).length ? `<div class="notice warn small">⚠ ${esc(c.flags.join(", "))}</div>` : ""}
      <div class="row" style="margin-bottom:12px"><a class="btn" target="_blank" rel="noopener" href="${esc(r.open_url)}">${t("open_in_file")}</a></div>
      <div class="card"><h2>${t("evidence")}</h2><div class="passage">${esc(c.text)}</div></div>
      <details class="card"><summary>${t("context")}</summary>${r.context.filter((x) => x.id !== c.id).map((x) => `<div class="passage small muted" style="margin-top:8px">${esc(x.text)}</div>`).join("")}</details>`;
  }

  async function HistoryDetail(qid) {
    loading();
    const h = await api(`/api/history/${qid}`);
    const a = h.answer || {};
    let body;
    if (h.kind === "compare") {
      body = `<div class="table-wrap"><table><thead><tr><th>${t("col_title")}</th>${(a.columns || []).map((c) => `<th>${esc(c.label)}</th>`).join("")}</tr></thead><tbody>${(a.rows || []).map((row) => `<tr><td>${esc(row.title)}</td>${a.columns.map((c) => `<td class="small">${esc((row.cells[c.key] || {}).text || "")} ${citeChips((row.cells[c.key] || {}).citation ? [row.cells[c.key].citation] : [])}</td>`).join("")}</tr>`).join("")}</tbody></table></div>${Object.values(a.citations || {}).map(citationCard).join("")}`;
    } else body = renderAnswer(a);
    view().innerHTML = `<p><a href="#/evidence">← ${t("back")}</a></p><h1>${esc(h.question)}</h1><p class="sub">${esc(fmtDate(h.created_at))}</p><div class="card">${body}</div>`;
    wireJumps(view());
  }

  // ------------------------------------------------------------------ clients
  async function Clients() {
    loading();
    const list = await api("/api/clients");
    view().innerHTML = `<h1>${t("cl_title")}</h1><p class="sub">${t("cl_sub")}</p>
      <div class="card"><div class="row"><input type="text" id="cn" placeholder="${t("client_name")}"><button class="btn" id="cc">${t("new_client")}</button></div></div>
      <div class="card">${list.length ? `<div class="table-wrap"><table><tbody>${list.map((c) => `<tr><td><a href="#/clients/${esc(c.id)}">${esc(c.name)}</a></td><td class="small muted">${esc(fmtDate(c.updated_at))}</td></tr>`).join("")}</tbody></table></div>` : `<p class="muted">${t("none")}</p>`}</div>`;
    $("#cc").addEventListener("click", async () => {
      const n = $("#cn").value.trim(); if (!n) return;
      const c = await api("/api/clients", { method: "POST", json: { name: n } });
      location.hash = `#/clients/${c.id}`;
    });
  }

  async function ClientDetail(id) {
    loading();
    const [c, fields] = await Promise.all([api(`/api/clients/${id}`), api("/api/client-fields")]);
    const p = c.profile || {};
    view().innerHTML = `<p><a href="#/clients">← ${t("back")}</a></p><h1>${esc(c.name)}</h1>
      <div class="grid k2">
        <div class="card"><h2>${t("profile")}</h2>
          ${fields.filter((f) => f.key !== "name").map((f) => `<label class="field"><span>${esc(S.lang === "ar" ? f.ar : f.en)}${f.required ? ` <span class="badge warn">${t("required")}</span>` : ""}</span><input class="wide pf" type="text" data-k="${esc(f.key)}" value="${esc(p[f.key] || "")}"></label>`).join("")}
          <label class="field"><span>Notes</span><textarea id="notes">${esc(c.notes || "")}</textarea></label>
          <button class="btn" id="saveP">${t("save")}</button></div>
        <div>
          <div class="card"><h2>${t("upload_client_file")}</h2><input type="file" id="cf" accept=".pdf,.docx,.xlsx,.csv,.txt,.md">
            <ul>${(c.files || []).map((f) => `<li>${esc(f.filename)} ${statusBadge(f.status)} <button class="btn small danger" data-df="${esc(f.id)}">${t("del")}</button></li>`).join("")}</ul></div>
          <div class="card"><div class="row"><button class="btn" id="an">${t("analyze")}</button><span class="spacer"></span><button class="btn danger small" id="dc">${t("del")}</button></div>
            <h3>${t("nav_programs")}</h3><ul>${(c.programs || []).map((x) => `<li><a href="#/programs/${esc(x.id)}">${esc(x.title)} v${esc(x.version)}</a></li>`).join("") || `<li class="muted">${t("none")}</li>`}</ul></div>
        </div>
      </div><div id="analysis"></div>`;
    $("#saveP").addEventListener("click", async () => {
      const prof = {}; $$(".pf").forEach((i) => { if (i.value.trim()) prof[i.dataset.k] = i.value.trim(); });
      await api(`/api/clients/${id}`, { method: "PATCH", json: { profile: prof, notes: $("#notes").value } }); toast(t("saved"));
    });
    $("#cf").addEventListener("change", async (e) => {
      const f = e.target.files[0]; if (!f) return;
      const fd = new FormData(); fd.append("file", f);
      try { await api(`/api/clients/${id}/files`, { method: "POST", body: fd }); route(); } catch (er) { toast(er.message); }
    });
    $$("[data-df]").forEach((b) => b.addEventListener("click", async () => {
      if (!(await confirmModal(t("del") + "?"))) return;
      await api(`/api/clients/${id}/files/${b.dataset.df}?confirm=true`, { method: "DELETE" }); route();
    }));
    $("#dc").addEventListener("click", async () => {
      if (!(await confirmModal(t("confirm_delete_client")))) return;
      await api(`/api/clients/${id}?confirm=true`, { method: "DELETE" }); location.hash = "#/clients";
    });
    $("#an").addEventListener("click", async () => {
      $("#analysis").innerHTML = `<p><span class="spinner"></span> ${t("loading")}</p>`;
      try { renderAnalysis(id, await api(`/api/clients/${id}/analyze`, { method: "POST", json: { lang: S.lang } })); }
      catch (e) { $("#analysis").innerHTML = errorBox(e); }
    });
  }

  function renderAnalysis(id, a) {
    const ready = a.readiness;
    const cls = ready === "ready" ? "" : ready === "needs_info" ? "warn" : "err";
    const allCites = {};
    a.priorities.forEach((p, i) => { if (p.evidence) Object.values(p.evidence.citations || {}).forEach((c) => { allCites[`P${i + 1}-${c.id}`] = { ...c, id: `P${i + 1}-${c.id}` }; }); });
    $("#analysis").innerHTML = `<div class="card">
      <div class="notice ${cls}"><b>${t("readiness")}:</b> ${esc(t(ready))}</div>
      <div class="notice warn small"><b>${t("disclaimer_title")}:</b> ${esc(a.disclaimer)}</div>
      ${a.red_flags.length ? `<h2>🚩 ${t("red_flags")}</h2><div class="table-wrap"><table><thead><tr><th></th><th>${t("source")}</th><th>${t("referral")}</th></tr></thead><tbody>${a.red_flags.map((f) => `<tr><td><b>${esc(S.lang === "ar" ? f.label_ar : f.label_en)}</b></td><td class="small">${esc(f.excerpt)}</td><td>${esc(f.referral)}</td></tr>`).join("")}</tbody></table></div>` : ""}
      <h2>${t("facts")}</h2><div class="table-wrap"><table><thead><tr><th></th><th></th><th>${t("source")}</th></tr></thead><tbody>
      ${a.facts.map((f) => `<tr><td>${esc(f.label)}</td><td>${esc(f.value)}${f.conflicting_values.length ? `<div class="small" style="color:#9a6a0f">⚠ ${t("conflicting_values")}: ${f.conflicting_values.map((v) => `${esc(v.value)} (${esc(v.source)})`).join("; ")}</div>` : ""}</td><td class="small muted">${esc(f.source)}</td></tr>`).join("") || `<tr><td class="muted">${t("none")}</td></tr>`}</tbody></table></div>
      ${a.training_log.length ? `<h3>${t("training_log")}</h3><div class="table-wrap"><table><tbody>${a.training_log.map((x) => `<tr><td>${esc(x.exercise)}</td><td>${esc(x.sets)}×${esc(x.reps)}</td><td>${esc(x.load || "")} ${esc(x.unit || "")}</td><td>${esc(x.effort_scale || "")} ${esc(x.effort || "")}</td><td class="small muted">${esc(x.source)}</td></tr>`).join("")}</tbody></table></div>` : ""}
      <h2>${t("missing")}</h2><ul>${a.missing.map((m) => `<li><b>${esc(m.label)}</b>${m.required_for_program ? ` <span class="badge warn">${t("required")}</span>` : ""}${m.question ? ` — ${esc(m.question)}` : ""}</li>`).join("") || `<li class="muted">${t("none")}</li>`}</ul>
      <p class="small muted">${t("derived")}: ${esc(JSON.stringify({ experience: a.derived.experience_level, days: a.derived.days_available }))} — ${esc(a.derived.note)}</p>
      <h2>${t("priorities")}</h2>${a.priorities.map((p, i) => `<div class="claim"><div><b>${esc(p.title)}</b> <span class="badge ${p.basis === "inference" ? "warn" : "info"}">${esc(p.basis === "inference" ? t("inference") : t("facts"))}</span></div>
        ${p.evidence ? (p.evidence.status === "answered" ? p.evidence.claims.map((c) => `<div class="quote">${esc(c.text)}</div>${citeChips(c.citations.map((x) => `P${i + 1}-${x}`))}`).join("") : `<div class="small muted">${esc(p.evidence.message)}</div>`) : ""}</div>`).join("")}
      ${Object.keys(allCites).length ? `<h3>${t("evidence")}</h3>${Object.values(allCites).map(citationCard).join("")}` : ""}
      <hr><div>${a.red_flags.length ? `<label class="small"><input type="checkbox" id="clr"> ${t("clearance_confirm")}</label><br>` : ""}
      <button class="btn" id="bp" style="margin-top:8px">${t("build_program")}</button></div><div id="bpOut"></div></div>`;
    wireJumps($("#analysis"));
    $("#bp").addEventListener("click", async () => {
      $("#bpOut").innerHTML = `<p><span class="spinner"></span> ${t("loading")}</p>`;
      try {
        const r = await api(`/api/clients/${id}/programs`, { method: "POST", json: { lang: S.lang, medical_clearance_confirmed: !!($("#clr") && $("#clr").checked) } });
        if (r.id) { location.hash = `#/programs/${r.id}`; return; }
        $("#bpOut").innerHTML = `<div class="notice warn"><b>${esc(t(r.status))}</b><br>${esc(r.message)}${(r.questions || []).length ? `<ul>${r.questions.map((q) => `<li>${esc(q)}</li>`).join("")}</ul>` : ""}</div>`;
      } catch (e) { $("#bpOut").innerHTML = errorBox(e); }
    });
  }

  // ------------------------------------------------------------------ programs
  async function Programs() {
    loading();
    const list = await api("/api/programs");
    view().innerHTML = `<h1>${t("pr_title")}</h1><p class="sub">${t("pr_sub")}</p><div class="card">
      ${list.length ? `<div class="table-wrap"><table><tbody>${list.map((p) => `<tr><td><a href="#/programs/${esc(p.id)}">${esc(p.title)}</a></td><td>v${esc(p.version)}</td><td>${esc(p.client_name || "")}</td><td class="small muted">${esc(fmtDate(p.created_at))}</td></tr>`).join("")}</tbody></table></div>` : `<p class="muted">${t("no_programs")}</p>`}</div>`;
  }

  async function ProgramDetail(id) {
    loading();
    const p = await api(`/api/programs/${id}`);
    const c = p.content;
    const basis = (b) => `<span class="badge ${b === "evidence" ? "ok" : b === "no_evidence" ? "err" : "warn"}">${esc(t("basis_" + b))}</span>`;
    view().innerHTML = `<p><a href="#/clients/${esc(p.client_id)}">← ${esc(c.client_name)}</a></p>
      <h1>${esc(c.title)} <span class="badge">v${esc(p.version)}</span></h1>
      <div class="notice small">${esc(c.note)}</div><div class="notice warn small"><b>${t("disclaimer_title")}:</b> ${esc(c.disclaimer)}</div>
      <div class="row" style="margin:10px 0"><a class="btn secondary small" target="_blank" href="/api/programs/${esc(id)}/export?format=md&lang=${S.lang}">${t("export_md")}</a>
        <a class="btn secondary small" href="/api/programs/${esc(id)}/export?format=csv&lang=${S.lang}">${t("export_csv")}</a>
        <button class="btn secondary small" id="cp">${t("copy")}</button><button class="btn small" id="ed">${t("edit_program")}</button>
        <span class="spacer"></span><button class="btn danger small" id="dp">${t("del")}</button></div>
      <div class="row small">${t("versions")}: ${p.versions.map((v) => v.id === id ? `<b>v${v.version}</b>` : `<a href="#/programs/${esc(v.id)}">v${v.version}</a>`).join(" • ")}</div>
      ${(p.change_notes || []).length ? `<div class="card"><h2>${t("changes")}</h2><ul>${p.change_notes.map((n) => `<li><b>${esc(n.element)}</b> (${esc(n.field)}): <s>${esc(n.before)}</s> → ${esc(n.after)} — <i>${esc(n.reason)}</i></li>`).join("")}</ul></div>` : ""}
      <div class="card"><div class="table-wrap"><table><thead><tr><th>${t("element")}</th><th>${t("client_constraint")}</th><th>${t("evidence_values")}</th><th>${t("proposed")}</th><th>${t("basis")}</th><th>${t("applicability")}</th><th>${t("coach_notes")}</th></tr></thead><tbody>
      ${c.elements.map((e) => `<tr data-key="${esc(e.key)}"><td><b>${esc(e.label)}</b><div>${citeChips(e.citations)}</div></td><td class="small">${esc(e.client_constraint || "")}</td>
        <td class="small">${e.evidence_values.map((v) => `<div><span style="unicode-bidi:plaintext">${esc(v.value)}</span> ${citeChips([v.citation])}${v.population.length ? ` <span class="badge">${esc(v.population.join(", "))}</span>` : ""}</div>`).join("") || "—"}</td>
        <td class="prop">${esc(e.proposed)}</td><td>${basis(e.basis)}</td>
        <td class="small">${(e.applicability || []).map((x) => `<div>• ${esc(x)}</div>`).join("")}${(e.conflicts || []).length ? `<div class="badge warn">⚖️ ${t("conflicts")}</div>` : ""}</td>
        <td class="small notes">${esc(e.coach_notes || "")}</td></tr>`).join("")}</tbody></table></div>
        <div id="editBox" hidden><label class="field"><span>${t("change_reason")}</span><input class="wide" type="text" id="reason"></label><button class="btn" id="saveEd">${t("save")}</button></div></div>
      ${c.sessions ? `<div class="card"><h2>${t("sessions")}</h2><div class="grid k4">${c.sessions.map((s) => `<div class="kpi"><b>${esc(s.name)}</b>${s.items.map((i) => `<div class="small">${esc(i.element)}: ${esc(i.value)}</div>`).join("")}</div>`).join("")}</div></div>` : ""}
      ${(c.current_exercises_from_client_file || []).length ? `<div class="card"><h2>${t("current_exercises")}</h2><ul>${c.current_exercises_from_client_file.map((x) => `<li>${esc(x.exercise)} — ${esc(x.sets)}×${esc(x.reps)} ${esc(x.load || "")}${esc(x.unit || "")} ${esc(x.effort_scale || "")} ${esc(x.effort || "")} <span class="muted small">(${esc(x.source)})</span></li>`).join("")}</ul></div>` : ""}
      ${c.elements.filter((e) => (e.conflicts || []).length).map((e) => `<div class="card"><h2>⚖️ ${esc(e.label)}</h2>${e.conflicts.map((cf) => `<div class="conflict">${cf.positions.map((pp) => `<div><span class="badge">${esc(pp.polarity ? t(pp.polarity) : "")}</span> <b>${esc(pp.filename)}</b> ${citeChips(pp.evidence_id ? [pp.evidence_id] : [])}${pp.text ? `<div class="quote">${esc(pp.text)}</div>` : ""}</div>`).join("")}</div>`).join("")}</div>`).join("")}
      <div class="card"><h2>${t("references")}</h2>${Object.values(c.citations).map(citationCard).join("")}</div>`;
    wireJumps(view());
    $("#cp").addEventListener("click", async () => {
      const md = await api(`/api/programs/${id}/export?format=md&lang=${S.lang}`);
      try { await navigator.clipboard.writeText(md); toast(t("saved")); } catch (e) { toast(t("error")); }
    });
    $("#dp").addEventListener("click", async () => {
      if (!(await confirmModal(t("confirm_delete_program")))) return;
      await api(`/api/programs/lineage/${p.lineage_id}?confirm=true`, { method: "DELETE" }); location.hash = "#/programs";
    });
    $("#ed").addEventListener("click", () => {
      $("#editBox").hidden = false;
      $$("tr[data-key]").forEach((tr) => {
        const e = c.elements.find((x) => x.key === tr.dataset.key);
        $(".prop", tr).innerHTML = `<textarea class="eprop">${esc(e.proposed)}</textarea>`;
        $(".notes", tr).innerHTML = `<textarea class="enotes">${esc(e.coach_notes || "")}</textarea>`;
      });
    });
    $("#saveEd").addEventListener("click", async () => {
      const edits = $$("tr[data-key]").map((tr) => ({ key: tr.dataset.key, proposed: $(".eprop", tr).value, coach_notes: $(".enotes", tr).value }));
      try {
        const np = await api(`/api/programs/${id}/revise`, { method: "POST", json: { edits, reason: $("#reason").value } });
        location.hash = `#/programs/${np.id}`;
      } catch (e) { toast(e.message); }
    });
  }

  // ------------------------------------------------------------------ settings
  async function Settings() {
    loading();
    const [s, backups, priv] = await Promise.all([api("/api/settings"), api("/api/backups"), api("/api/privacy")]);
    S.settings = s; shell();
    const opt = (v, cur, label) => `<option value="${v}" ${v === cur ? "selected" : ""}>${esc(label)}</option>`;
    view().innerHTML = `<h1>${t("st_title")}</h1><p class="sub">${t("st_sub")}</p>
      <div class="card"><h2>${t("model_section")}</h2>
        <label class="field"><span>${t("provider")}</span><select id="prov">${opt("none", s.llm_provider, t("p_none"))}${opt("ollama", s.llm_provider, t("p_ollama"))}${opt("openai_compat", s.llm_provider, t("p_openai"))}${opt("anthropic", s.llm_provider, t("p_anthropic"))}</select></label>
        <div class="grid k2"><label class="field"><span>Ollama URL</span><input class="wide" type="text" id="ou" value="${esc(s.ollama_url)}"></label><label class="field"><span>Ollama model</span><input class="wide" type="text" id="om" value="${esc(s.ollama_model)}"></label>
        <label class="field"><span>OpenAI-compatible URL</span><input class="wide" type="text" id="cu" value="${esc(s.openai_compat_url)}"></label><label class="field"><span>Model</span><input class="wide" type="text" id="cm" value="${esc(s.openai_compat_model)}"></label>
        <label class="field"><span>Claude model</span><input class="wide" type="text" id="am" value="${esc(s.anthropic_model)}"></label></div>
        <div class="notice warn" id="extWarn" hidden>${t("external_warning")}</div>
        <label class="small" style="display:block"><input type="checkbox" id="ae" ${s.allow_external_llm ? "checked" : ""}> ${t("allow_external")}</label>
        <label class="small" style="display:block"><input type="checkbox" id="ac" ${s.allow_client_data_external ? "checked" : ""}> ${t("allow_client_external")}</label>
        <label class="small" style="display:block"><input type="checkbox" id="vc" ${s.llm_verify_claims ? "checked" : ""}> ${t("verify_claims")}</label>
        <div class="row" style="margin-top:10px"><button class="btn" id="saveM">${t("save")}</button><button class="btn secondary" id="testM">${t("test_model")}</button><span id="testOut" class="small"></span></div></div>
      <div class="card"><h2>${t("embed_section")}</h2>
        <label class="field"><span>${t("embedder")}</span><select id="emb">${opt("hash", s.embedding_provider, t("e_hash"))}${opt("ollama", s.embedding_provider, t("e_ollama"))}${opt("fastembed", s.embedding_provider, t("e_fastembed"))}</select></label>
        <div class="grid k2"><label class="field"><span>Ollama embedding model</span><input class="wide" type="text" id="oem" value="${esc(s.ollama_embedding_model)}"></label><label class="field"><span>fastembed model</span><input class="wide" type="text" id="fem" value="${esc(s.fastembed_model)}"></label></div>
        <label class="small"><input type="checkbox" id="md" ${s.allow_model_download ? "checked" : ""}> ${t("allow_download")}</label>
        <h3>${t("retrieval")}</h3><div class="row"><label class="field"><span>${t("top_k")}</span><input type="number" id="tk" min="3" max="20" value="${esc(s.top_k)}"></label>
        <label class="field"><span>${t("min_cov")}</span><input type="number" id="mc" step="0.05" min="0.2" max="1" value="${esc(s.min_concept_coverage)}"></label>
        <label class="field"><span>${t("min_sim")}</span><input type="number" id="ms" step="0.05" min="0" max="1" value="${esc(s.min_vector_similarity)}"></label></div>
        <div class="row"><button class="btn" id="saveE">${t("save")}</button><span class="spacer"></span><button class="btn secondary" id="rb">${t("rebuild_index")}</button></div><div id="rbOut"></div></div>
      <div class="card"><h2>${t("storage_section")}</h2>
        <p><b>${t("data_dir")}:</b> <span class="mono">${esc(s.data_dir)}</span></p>
        <p class="small">${esc(priv.storage)} • internet search: <b>${priv.internet_search ? t("yes") : t("no")}</b> • ${esc(priv.network_guard)}</p>
        <p class="small">library → external: <b>${priv.library_text_leaves_device ? t("yes") : t("no")}</b> • clients → external: <b>${priv.client_data_leaves_device ? t("yes") : t("no")}</b></p>
        <p class="small"><b>${t("secrets")}:</b> ${Object.entries(s.secrets).map(([k, v]) => `${esc(k)}: ${esc(v)}`).join(" • ")}</p>
        <label class="field"><span>${t("language")}</span><select id="lng">${opt("ar", s.language, "العربية")}${opt("en", s.language, "English")}</select></label></div>
      <div class="card"><h2>${t("backup_section")}</h2>
        <div class="row"><label class="small"><input type="checkbox" id="ic" checked> ${t("include_clients")}</label><button class="btn" id="mb">${t("make_backup")}</button></div>
        <ul>${backups.map((b) => `<li><a href="/api/backups/${encodeURIComponent(b.name)}">${esc(b.name)}</a> <span class="small muted">${Math.round(b.size / 1024)} KB</span></li>`).join("")}</ul>
        <div class="row"><span class="small">${t("restore")}:</span><input type="file" id="rs" accept=".zip"></div></div>`;
    const updWarn = () => {
      const p = $("#prov").value;
      const url = p === "ollama" ? $("#ou").value : p === "openai_compat" ? $("#cu").value : p === "anthropic" ? "https://api.anthropic.com" : "";
      $("#extWarn").hidden = !url || /^https?:\/\/(localhost|127\.0\.0\.1|\[::1\])(:|\/|$)/i.test(url);
    };
    ["prov", "ou", "cu"].forEach((x) => $("#" + x).addEventListener("input", updWarn)); updWarn();
    $("#saveM").addEventListener("click", async () => {
      try {
        S.settings = await api("/api/settings", { method: "POST", json: { llm_provider: $("#prov").value, ollama_url: $("#ou").value, ollama_model: $("#om").value,
          openai_compat_url: $("#cu").value, openai_compat_model: $("#cm").value, anthropic_model: $("#am").value,
          allow_external_llm: $("#ae").checked, allow_client_data_external: $("#ac").checked, llm_verify_claims: $("#vc").checked, language: $("#lng").value } });
        toast(t("saved")); shell();
      } catch (e) { toast(e.message === "external_model_requires_consent" ? t("external_warning") : e.message, 6000); }
    });
    $("#testM").addEventListener("click", async () => { $("#testOut").textContent = "…"; const r = await api("/api/llm/test", { method: "POST" }); $("#testOut").textContent = r.provider === "none" ? t("test_none") : r.ok ? `✓ ${r.provider}` : `✗ ${r.error}`; });
    $("#saveE").addEventListener("click", async () => {
      try {
        S.settings = await api("/api/settings", { method: "POST", json: { embedding_provider: $("#emb").value, ollama_embedding_model: $("#oem").value, fastembed_model: $("#fem").value,
          allow_model_download: $("#md").checked, top_k: parseInt($("#tk").value, 10), min_concept_coverage: parseFloat($("#mc").value), min_vector_similarity: parseFloat($("#ms").value) } });
        toast(t("saved"));
      } catch (e) { toast(e.message); }
    });
    $("#rb").addEventListener("click", async () => {
      if (!(await confirmModal(t("confirm_rebuild"), { danger: false }))) return;
      $("#rbOut").innerHTML = `<p><span class="spinner"></span></p>`;
      try { const r = await api("/api/index/rebuild?confirm=true", { method: "POST" }); $("#rbOut").innerHTML = `<div class="notice">${esc(JSON.stringify(r))}</div>`; }
      catch (e) { $("#rbOut").innerHTML = String(e.message).startsWith("embedder_not_ready") ? `<div class="notice err">${t("embedder_not_ready")}<div class="small mono">${esc(e.message)}</div></div>` : errorBox(e); }
    });
    $("#mb").addEventListener("click", async () => { await api("/api/backup", { method: "POST", json: { include_clients: $("#ic").checked } }); route(); });
    $("#rs").addEventListener("change", async (e) => {
      const f = e.target.files[0]; if (!f) return;
      if (!(await confirmModal(t("confirm_restore")))) return;
      const fd = new FormData(); fd.append("file", f); fd.append("confirm", "true");
      try { await api("/api/restore", { method: "POST", body: fd }); toast(t("saved")); S.settings = null; route(); } catch (er) { toast(er.message); }
    });
  }

  route();
})();
