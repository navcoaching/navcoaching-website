/* Summaries & Slides / Study mode — pages registered into the main app router. */
(() => {
  "use strict";
  const P = (window.NAV_PAGES = window.NAV_PAGES || {});
  const LEVELS = ["quick", "standard", "detailed", "expert"];
  const SECTIONS = ["overview", "quick", "key_points", "concepts", "findings", "methodology", "limitations", "conclusion",
    "practical", "numbers", "tables", "relations", "section_summaries"];
  const METHOD_KEYS = ["design", "participants", "sample_characteristics", "duration", "intervention", "measures",
    "measurement_method", "main_results"];

  function helpers(ctx) {
    const { esc, t } = ctx;
    const srcChip = (s, stale) => {
      if (!s) return "";
      const page = s.page || s.unit_index;
      const where = page ? `${t("page")} ${esc(page)}` : esc(s.location || s.section || s.filename);
      const printed = s.printed_page ? ` <span class="muted">(${t("printed_page")} ${esc(s.printed_page)})</span>` : "";
      const tip = `${s.filename}${s.section ? " — " + s.section : ""}${stale ? " — " + t("sm_stale_src") : ""}`;
      return `<span class="srcchip${stale ? " stale" : ""}"><a target="_blank" rel="noopener" href="${esc(s.open_url)}" title="${esc(tip)}">${t("sm_source")} → ${where}${printed}</a>`
        + `<a class="ev" href="#/evidence/${esc(s.chunk_id)}" title="${esc(t("open_evidence"))}">¶</a></span>`;
    };
    const claim = (c, stale, opts = {}) => {
      if (!c) return "";
      if (!c.sources || !c.sources.length) return `<li class="claim2 notfound">${esc(c.text || t("sm_not_found"))}</li>`;
      const label = opts.label || c.term || c.label;
      const kind = c.kind === "quote" ? `<span class="badge info" title="${esc(t("sm_quote_tip"))}">${t("quote")}</span>`
        : c.kind === "stated" ? `<span class="badge ok">${t("sm_verified")}</span>` : c.kind === "unverified" ? `<span class="badge err">!</span>` : "";
      const hl = (c.highlights || []).map((h) => `<span class="bignum">${esc(h)}</span>`).join("");
      return `<li class="claim2">${hl ? `<div class="hlrow">${hl}</div>` : ""}<div class="${c.kind === "quote" ? "qtext" : ""}">${label ? `<b>${esc(label)}</b> — ` : ""}${esc(c.text)}</div>`
        + `<div class="chips">${kind}${c.sources.map((s) => srcChip(s, stale)).join("")}${(c.warnings || []).length ? `<span class="small warnline">⚠ ${esc(c.warnings.join("; "))}</span>` : ""}</div></li>`;
    };
    const explainOut = (e) => {
      if (!e) return "";
      return `<div class="explain-box"><div class="row"><b>🎓 ${esc(e.title || "")}</b><span class="spacer"></span><span class="small muted">${esc(e.mode || "")}</span></div>
        ${e.note ? `<div class="small muted">${esc(e.note)}</div>` : ""}
        ${(e.parts || []).map((p) => `<h4>${esc(p.label)}</h4>${p.items && p.items.length ? `<ul class="claims">${p.items.map((c) => claim(c)).join("")}</ul>` : `<p class="muted small">${esc(p.message || "")}</p>`}`).join("")}</div>`;
    };
    return { srcChip, claim, explainOut };
  }

  // ------------------------------------------------------------------ list page
  P.summaries = async (ctx, id) => (id ? SummaryPage(ctx, id) : SummaryList(ctx));

  async function SummaryList(ctx) {
    const { api, esc, t, view, loading, fmtDate, $ } = ctx;
    loading();
    const [list, docs] = await Promise.all([api("/api/summaries"), api("/api/documents")]);
    const usable = docs.filter((d) => d.status === "processed" || d.status === "needs_review");
    view().innerHTML = `<h1>📚 ${t("nav_summaries")}</h1><p class="sub">${t("sm_sub")}</p>
      <div class="flowline">${["sm_flow_upload", "sm_flow_index", "sm_flow_summary", "sm_flow_slides", "sm_flow_study", "sm_flow_ask"].map((k) => `<span>${t(k)}</span>`).join("<b>›</b>")}</div>
      <div class="card"><h2>${t("sm_new")}</h2><div class="row">
        <select id="smDoc" style="min-width:260px">${usable.map((d) => `<option value="${esc(d.id)}">${esc(d.title || d.filename)}</option>`).join("")}</select>
        <select id="smLevel">${LEVELS.map((l) => `<option value="${l}" ${l === "standard" ? "selected" : ""}>${t("lv_" + l)}</option>`).join("")}</select>
        <button class="btn" id="smGo" ${usable.length ? "" : "disabled"}>${t("sm_generate")}</button></div>
        <p class="small muted">${t("sm_levels_note")}</p></div>
      <div class="card">${list.length ? `<div class="table-wrap"><table><thead><tr><th>${t("title")}</th><th>${t("col_file")}</th><th>${t("sm_level")}</th><th>${t("col_status")}</th><th></th></tr></thead><tbody>
        ${list.map((s) => `<tr><td><a href="#/summaries/${esc(s.id)}">${esc(s.title)}</a>${s.stale ? ` <span class="badge warn">${t("sm_stale_badge")}</span>` : ""}</td>
          <td class="small">${esc(s.filename)}</td><td>${esc(t("lv_" + s.level))}</td>
          <td><span class="badge ${s.status === "done" ? "ok" : s.status === "failed" ? "err" : "info"}">${esc(t("sm_st_" + s.status))}</span></td>
          <td class="small muted">${esc(fmtDate(s.generated_at || s.created_at))}</td></tr>`).join("")}</tbody></table></div>` : `<p class="muted">${t("none")}</p>`}</div>`;
    $("#smGo").addEventListener("click", async () => {
      const s = await api("/api/summaries", { method: "POST", json: { doc_id: $("#smDoc").value, level: $("#smLevel").value, lang: ctx.S.lang } });
      location.hash = `#/summaries/${s.id}`;
    });
  }

  // ------------------------------------------------------------------ summary page
  async function SummaryPage(ctx, id) {
    const { api, esc, t, view, loading, fmtDate, $, $$, toast, confirmModal, S } = ctx;
    const { claim, explainOut, srcChip } = helpers(ctx);
    loading();
    const s = await api(`/api/summaries/${id}`);
    if (s.status !== "done") {
      view().innerHTML = `<p><a href="#/summaries">← ${t("back")}</a></p><h1>${esc(s.title)}</h1>
        ${s.status === "failed" ? `<div class="notice err">${esc(s.error || t("error"))}</div><button class="btn" id="regen">${t("sm_regenerate")}</button>`
          : `<div class="notice"><span class="spinner"></span> ${t("sm_generating")} ${esc(s.progress || "")}</div>`}`;
      if (s.status === "failed") $("#regen").addEventListener("click", async () => { await api(`/api/summaries/${id}/regenerate`, { method: "POST", json: {} }); ctx.route(); });
      else S.pollTimer = setTimeout(ctx.route, 1500);
      return;
    }
    const c = s.content, ov = c.overview, stale = s.stale;
    const list = (items, opts) => (items && items.length ? `<ul class="claims">${items.map((x) => claim(x, stale, opts)).join("")}</ul>` : `<p class="muted">${t("sm_not_found")}</p>`);
    const sec = (key, title, body, explain = true) => `<section class="card sm-sec" id="sec-${key}"><div class="row"><h2>${title}</h2><span class="spacer"></span>
      ${explain ? `<button class="btn small secondary" data-explain="${key}">🎓 ${t("sm_explain")}</button>` : ""}</div>${body}<div class="ex-out" id="ex-${key}"></div></section>`;
    const meth = c.methodology || {};
    const outline = c.outline || [];
    const ssById = Object.fromEntries((c.section_summaries || []).map((x) => [x.section_id, x]));
    const body = {
      overview: sec("overview", t("sm_overview"), `<div class="grid k4 ov">${[
        [t("title"), ov.title], [t("sm_filetype"), ov.file_type], [t("doc_type"), ov.doc_type || t("sm_unknown")],
        [t("authors"), ov.authors || t("sm_not_stated")], [t("year"), ov.year || t("sm_not_stated")],
        [t("col_pages"), `${ov.pages_read ?? "-"} / ${ov.pages ?? "-"}`], [t("sm_added"), fmtDate(ov.added_at)], [t("mode"), s.mode]]
        .map(([k, v]) => `<div class="kpi"><div class="l">${esc(k)}</div><div class="small"><b>${esc(v ?? "")}</b></div></div>`).join("")}</div>
        ${(c.warnings || []).map((w) => `<div class="notice warn small">${esc(w)}</div>`).join("")}`, false),
      quick: sec("quick", t("sm_quick"), `<div class="grid k2">${c.quick.map((q) => `<div class="qcard"><div class="l">${t("sm_q_" + q.key)}</div><ul class="claims">${claim(q, stale)}</ul></div>`).join("")}</div>`),
      key_points: sec("key_points", t("sm_key_points"), `<p class="small muted">${t("sm_ranked")}</p>${list(c.key_points)}`),
      concepts: sec("concepts", t("sm_concepts"), list(c.concepts)),
      findings: sec("findings", t("sm_findings"), list(c.findings)),
      methodology: sec("methodology", t("sm_methodology"), meth._applicable
        ? `<div class="table-wrap"><table><tbody>${METHOD_KEYS.map((k) => `<tr><th style="width:22%">${t("m_" + k)}</th><td><ul class="claims">${claim(meth[k], stale)}</ul></td></tr>`).join("")}</tbody></table></div>`
        : `<p class="muted">${t("sm_no_method")}</p>`),
      limitations: sec("limitations", t("sm_limitations"), c.limitations && c.limitations.length ? list(c.limitations) : `<p class="muted">${esc(c.limitations_message || "")}</p>`),
      conclusion: sec("conclusion", t("sm_conclusion"), list(c.conclusion)),
      practical: sec("practical", t("sm_practical"), list(c.practical)),
      numbers: sec("numbers", t("sm_numbers"), list(c.numbers)),
      tables: sec("tables", t("sm_tables"), (c.tables || []).length ? c.tables.map((tb) => `<h4>${esc(tb.caption)} ${srcChip(tb.source, stale)}</h4>
        <div class="table-wrap"><table><thead><tr>${tb.header.map((h) => `<th>${esc(h)}</th>`).join("")}</tr></thead><tbody>${tb.rows.map((r) => `<tr>${r.map((x) => `<td>${esc(x)}</td>`).join("")}</tr>`).join("")}</tbody></table></div>`).join("")
        : `<p class="muted">${t("sm_no_tables")}</p>`, false),
      relations: sec("relations", t("sm_relations"), (c.relations || []).length ? `<ul class="claims">${c.relations.map((r) => claim(r, stale, { label: r.a && r.b ? `${r.a} ↔ ${r.b}` : null })).join("")}</ul>` : `<p class="muted">${t("sm_no_relations")}</p>`),
      section_summaries: (c.section_summaries || []).length ? `<section class="card sm-sec" id="sec-section_summaries"><h2>${t("sm_by_section")}</h2>
        ${c.section_summaries.map((x) => `<div class="ss" id="ss-${esc(x.section_id)}"><div class="row"><h3>${esc(x.title)}</h3><span class="spacer"></span><button class="btn small secondary" data-explain="${esc(x.section_id)}">🎓 ${t("sm_explain")}</button></div>
        ${list(x.claims)}<div class="ex-out" id="ex-${esc(x.section_id)}"></div></div>`).join("")}</section>` : "",
    };
    view().innerHTML = `<p><a href="#/summaries">← ${t("nav_summaries")}</a></p>
      ${stale ? `<div class="notice warn">${t("sm_stale")} <button class="btn small" id="regenStale">${t("sm_regenerate")}</button></div>` : ""}
      <div class="row"><h1 id="smTitle">${esc(s.title)}</h1><button class="btn small secondary" id="rename">✎</button></div>
      <p class="sub">${t("sm_from_file")}: <a href="#/library/${esc(s.doc_id)}">${esc(ov.filename)}</a> • ${t("sm_level")}: ${esc(t("lv_" + s.level))} • ${esc(fmtDate(s.generated_at))}
        • ${t("sm_verification")}: ${esc(s.verification.accepted)}/${esc(s.verification.checked)}</p>
      <div class="notice small">${t("sm_file_only")}</div>
      <div class="row" style="margin-bottom:14px">
        <a class="btn" href="#/slides/${esc(id)}/1">🎓 ${t("sm_open_slides")}</a><a class="btn" href="#/study/${esc(id)}">🧠 ${t("sm_study")}</a>
        <a class="btn secondary" href="#sec-askdoc" id="toAsk">💬 ${t("sm_ask_doc")}</a>
        <a class="btn secondary" target="_blank" href="/api/summaries/${esc(id)}/export?format=md">${t("export_md")}</a>
        <span class="spacer"></span>
        <select id="lvl">${LEVELS.map((l) => `<option value="${l}" ${l === s.level ? "selected" : ""}>${t("lv_" + l)}</option>`).join("")}</select>
        <button class="btn secondary" id="regen">${t("sm_regenerate")}</button><button class="btn danger" id="delS">${t("del")}</button></div>
      <div class="sm-layout">
        <aside class="sm-toc card"><b>${t("sm_contents")}</b><ul>${SECTIONS.filter((k) => body[k]).map((k) => `<li><a href="javascript:void(0)" data-goto="sec-${k}">${t("sm_" + (k === "overview" ? "overview" : k === "quick" ? "quick" : k === "section_summaries" ? "by_section" : k))}</a></li>`).join("")}</ul>
          ${outline.length ? `<b>${t("sm_outline")}</b><ul class="outline">${outline.map((o) => `<li style="padding-inline-start:${(o.level - 1) * 12}px">
            <a href="javascript:void(0)" data-goto="${ssById[o.id] ? "ss-" + esc(o.id) : ""}" data-chunk="${esc(o.first_chunk_id || "")}">${esc(o.title)}</a>
            ${o.first_chunk_id ? `<a class="viewsrc" href="#/evidence/${esc(o.first_chunk_id)}" title="${t("sm_view_source")}">${t("sm_view_source")}${o.page_start ? " · " + t("page") + " " + esc(o.page_start) : ""}</a>` : ""}</li>`).join("")}</ul>` : ""}</aside>
        <div class="sm-main">${SECTIONS.map((k) => body[k] || "").join("")}
          <section class="card" id="sec-askdoc"><h2>💬 ${t("sm_ask_doc")}</h2><p class="small muted">${t("sm_ask_doc_note")}</p>
            <div class="row"><input type="text" id="adq" style="flex:1" placeholder="${t("sm_ask_ph")}"><button class="btn" id="adb">${t("ask_btn")}</button></div><div id="ada"></div></section>
          ${(s.verification.rejected || []).length ? `<details class="card"><summary>${t("rejected")} (${s.verification.rejected.length})</summary><ul>${s.verification.rejected.map((r) => `<li class="small">${esc(r.text)} — <span class="muted">${esc(r.reason)}</span></li>`).join("")}</ul></details>` : ""}
        </div></div>`;
    $$("[data-goto]").forEach((a) => a.addEventListener("click", () => {
      const target = a.dataset.goto && document.getElementById(a.dataset.goto);
      if (target) target.scrollIntoView({ behavior: "smooth", block: "start" });
      else if (a.dataset.chunk) location.hash = `#/evidence/${a.dataset.chunk}`;
    }));
    $$("[data-explain]").forEach((b) => b.addEventListener("click", async () => {
      const out = document.getElementById("ex-" + b.dataset.explain);
      out.innerHTML = `<p><span class="spinner"></span></p>`;
      try { out.innerHTML = explainOut(await api(`/api/summaries/${id}/explain`, { method: "POST", json: { section: b.dataset.explain, lang: S.lang } })); }
      catch (e) { out.innerHTML = ctx.errorBox(e); }
    }));
    const regen = async (lvl) => { await api(`/api/summaries/${id}/regenerate`, { method: "POST", json: { level: lvl, lang: S.lang } }); ctx.route(); };
    $("#regen").addEventListener("click", () => regen($("#lvl").value));
    if ($("#regenStale")) $("#regenStale").addEventListener("click", () => regen(s.level));
    $("#delS").addEventListener("click", async () => {
      if (!(await confirmModal(t("sm_confirm_delete")))) return;
      await api(`/api/summaries/${id}?confirm=true`, { method: "DELETE" }); location.hash = "#/summaries";
    });
    $("#rename").addEventListener("click", async () => {
      const name = window.prompt(t("sm_rename"), s.title);
      if (name && name.trim()) { await api(`/api/summaries/${id}`, { method: "PATCH", json: { title: name } }); toast(t("saved")); ctx.route(); }
    });
    $("#toAsk").addEventListener("click", (e) => { e.preventDefault(); $("#sec-askdoc").scrollIntoView({ behavior: "smooth" }); $("#adq").focus(); });
    askDocWire(ctx, s.doc_id, "#adq", "#adb", "#ada");
  }

  function askDocWire(ctx, docId, qSel, bSel, outSel) {
    const { api, $, esc, S } = ctx;
    const go = async () => {
      const q = $(qSel).value.trim(); if (!q) return;
      $(outSel).innerHTML = `<p><span class="spinner"></span></p>`;
      try {
        const r = await api(`/api/documents/${docId}/ask`, { method: "POST", json: { question: q, lang: S.lang } });
        $(outSel).innerHTML = `<div class="notice small">📄 ${esc(r.scope_note)}</div>${ctx.renderAnswer(r)}`;
        ctx.wireJumps($(outSel));
      } catch (e) { $(outSel).innerHTML = ctx.errorBox(e); }
    };
    $(bSel).addEventListener("click", go);
    $(qSel).addEventListener("keydown", (e) => { if (e.key === "Enter") go(); });
  }

  // ------------------------------------------------------------------ document page panel
  P.docPanel = async (ctx, d, mount) => {
    const { api, esc, t, $, fmtDate } = ctx;
    if (!(d.status === "processed" || d.status === "needs_review")) return;
    const list = await api(`/api/summaries?doc_id=${encodeURIComponent(d.id)}`);
    mount.innerHTML = `<div class="card"><h2>📚 ${t("nav_summaries")}</h2>
      <div class="row"><select id="dpLevel">${LEVELS.map((l) => `<option value="${l}" ${l === "standard" ? "selected" : ""}>${t("lv_" + l)}</option>`).join("")}</select>
        <button class="btn" id="dpGen">✨ ${t("sm_generate")}</button>
        ${list.length ? list.map((s) => `<a class="btn small secondary" href="#/summaries/${esc(s.id)}">${esc(t("lv_" + s.level))} • ${esc(fmtDate(s.generated_at || s.created_at))}${s.stale ? " ⚠" : ""}</a>`).join("") : ""}</div>
      <h3>💬 ${t("sm_ask_doc")}</h3><p class="small muted">${t("sm_ask_doc_note")}</p>
      <div class="row"><input type="text" id="dpq" style="flex:1" placeholder="${t("sm_ask_ph")}"><button class="btn" id="dpb">${t("ask_btn")}</button></div><div id="dpa"></div></div>`;
    $("#dpGen").addEventListener("click", async () => {
      const s = await api("/api/summaries", { method: "POST", json: { doc_id: d.id, level: $("#dpLevel").value, lang: ctx.S.lang } });
      location.hash = `#/summaries/${s.id}`;
    });
    askDocWire(ctx, d.id, "#dpq", "#dpb", "#dpa");
  };

  // ------------------------------------------------------------------ slides viewer
  function barChart(v, esc) {
    const W = 680, H = 300, padL = 50, padB = 60, padT = 24;
    const n = v.labels.length, k = v.series.length;
    const max = Math.max(...v.series.flatMap((s) => s.values), 0) || 1;
    const min = Math.min(...v.series.flatMap((s) => s.values), 0);
    const range = max - min || 1;
    const gw = (W - padL - 10) / n, bw = Math.max(8, (gw * 0.7) / k);
    const y = (val) => padT + (H - padT - padB) * (1 - (val - min) / range);
    const colors = ["var(--chart1)", "var(--chart2)", "var(--chart3)"];
    let out = `<svg viewBox="0 0 ${W} ${H}" class="chart" role="img" aria-label="${esc(v.caption)}">`;
    out += `<line x1="${padL}" y1="${y(0)}" x2="${W - 5}" y2="${y(0)}" class="axis"/>`;
    v.labels.forEach((lab, i) => {
      v.series.forEach((s, j) => {
        const x = padL + i * gw + (gw - bw * k) / 2 + j * bw, val = s.values[i];
        const top = Math.min(y(val), y(0)), h = Math.abs(y(val) - y(0));
        out += `<rect x="${x}" y="${top}" width="${bw - 2}" height="${Math.max(h, 1)}" fill="${colors[j % 3]}" rx="2"><title>${esc(s.name)}: ${val}</title></rect>`;
        out += `<text x="${x + (bw - 2) / 2}" y="${top - 4}" class="vlabel">${val}</text>`;
      });
      out += `<text x="${padL + i * gw + gw / 2}" y="${H - padB + 18}" class="xlabel">${esc(lab)}</text>`;
    });
    out += "</svg>";
    if (k > 1) out += `<div class="legend">${v.series.map((s, j) => `<span><i style="background:${colors[j % 3]}"></i>${esc(s.name)}</span>`).join("")}</div>`;
    else out += `<div class="legend"><span><i style="background:${colors[0]}"></i>${esc(v.series[0].name)}</span></div>`;
    return out;
  }

  function conceptMap(v, esc) {
    const W = 680, H = 320, cx = W / 2, cy = H / 2, r = Math.min(W, H) / 2 - 50;
    const pos = {};
    v.nodes.forEach((n, i) => { const a = (2 * Math.PI * i) / v.nodes.length - Math.PI / 2; pos[n] = [cx + r * 1.5 * Math.cos(a), cy + r * Math.sin(a)]; });
    let out = `<svg viewBox="0 0 ${W} ${H}" class="cmap">`;
    v.edges.forEach((e) => {
      const [x1, y1] = pos[e.a], [x2, y2] = pos[e.b];
      const mx = (x1 + x2) / 2, my = (y1 + y2) / 2, dx = cx - mx, dy = cy - my, d = Math.hypot(dx, dy) || 1;
      out += `<line x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}" class="edge"/><text x="${mx - (dx / d) * 14}" y="${my - (dy / d) * 14 + 4}" class="elabel">${esc(e.label)}</text>`;
    });
    v.nodes.forEach((n) => { const [x, y] = pos[n]; out += `<g><rect x="${x - 70}" y="${y - 16}" width="140" height="32" rx="16" class="node"/><text x="${x}" y="${y + 5}" class="nlabel">${esc(n.length > 22 ? n.slice(0, 21) + "…" : n)}</text></g>`; });
    return out + "</svg>";
  }

  function slideHTML(ctx, sl, deckLang) {
    const { esc, t } = ctx;
    const { srcChip } = helpers(ctx);
    const chips = (b) => (b.sources || []).slice(0, 2).map((s) => srcChip(s)).join("");
    const v = sl.visual || {};
    let inner = "";
    if (sl.layout === "title") {
      inner = `<div class="sl-title-wrap"><div class="sl-kicker">📚 ${t("nav_summaries")}</div><h1 class="sl-h1">${esc(sl.title)}</h1>${sl.subtitle ? `<p class="sl-sub">${esc(sl.subtitle)}</p>` : ""}
        ${(sl.bullets || []).map((b) => `<div class="chips center">${chips(b)}</div>`).join("")}</div>`;
    } else {
      inner = `<h2 class="sl-h2">${esc(sl.title)}</h2>`;
      if (sl.layout === "cards") {
        inner += `<div class="sl-cards">${sl.bullets.map((b) => `<div class="sl-card ${b.kind === "not_found" ? "nf" : ""}">${b.label ? `<div class="sl-card-l">${esc(b.label)}</div>` : ""}<div>${esc(b.text)}</div><div class="chips">${chips(b)}</div></div>`).join("")}</div>`;
      } else if (sl.layout === "flow" && v.nodes) {
        inner += `<div class="sl-flow">${v.nodes.map((n, i) => `${i ? `<div class="arrow">${deckLang === "ar" ? "←" : "→"}</div>` : ""}<div class="sl-node"><div class="sl-card-l">${esc(n.label)}</div><div class="small">${esc(n.text)}</div><div class="chips">${chips(n)}</div></div>`).join("")}</div>`;
      } else if (sl.layout === "bignumbers") {
        inner += `<div class="sl-big">${sl.bullets.map((b) => `<div class="sl-bigrow">${b.highlight ? `<div class="sl-num">${esc(b.highlight)}</div>` : `<div class="sl-num dim">•</div>`}<div><div>${esc(b.text)}</div><div class="chips">${chips(b)}</div></div></div>`).join("")}</div>`;
      } else if (sl.layout === "chart" && v.type === "bar") {
        inner += `<div class="sl-chart">${barChart(v, esc)}<div class="small muted">${t("sm_chart_note")} — ${esc(v.caption)} ${srcChip(v.source)}</div></div>`;
      } else if (sl.layout === "table" && v.type === "table") {
        inner += `<div class="table-wrap"><table><thead><tr>${v.header.map((h) => `<th>${esc(h)}</th>`).join("")}</tr></thead><tbody>${v.rows.map((r) => `<tr>${r.map((x) => `<td>${esc(x)}</td>`).join("")}</tr>`).join("")}</tbody></table></div><div class="chips">${srcChip(v.source)}</div>`;
      } else if (sl.layout === "map" && v.type === "map") {
        inner += `<div class="sl-chart">${conceptMap(v, esc)}<div class="small muted">${t("sm_map_note")}</div></div>`;
      } else {
        inner += `<ul class="sl-list">${sl.bullets.map((b) => `<li class="${b.kind === "not_found" ? "nf" : ""}">${esc(b.text)}<div class="chips">${chips(b)}</div></li>`).join("")}</ul>`;
      }
    }
    return `<div class="slide sl-${esc(sl.type)}">${inner}</div>`;
  }

  P.slides = async (ctx, id, n) => {
    const { api, esc, t, view, loading, $, $$, S } = ctx;
    const { srcChip, explainOut } = helpers(ctx);
    loading();
    const s = await api(`/api/summaries/${id}`);
    if (s.status !== "done") { location.hash = `#/summaries/${id}`; return; }
    const deck = s.slides, slides = deck.slides;
    let idx = Math.min(Math.max(parseInt(n || "1", 10) - 1, 0), slides.length - 1);
    let theme = "light", scale = 1, notesOpen = true;
    try { theme = localStorage.getItem("nav_deck_theme") || "light"; scale = parseFloat(localStorage.getItem("nav_deck_scale") || "1"); } catch (e) { /* ignore */ }
    view().innerHTML = `<div class="deck-wrap theme-${theme}" id="deck">
      <div class="deck-bar">
        <a class="btn small secondary" href="#/summaries/${esc(id)}">←</a><b class="deck-title">${esc(s.title)}</b><span class="spacer"></span>
        <input type="text" id="dsearch" placeholder="🔍 ${t("sm_search_slides")}" style="width:170px">
        <button class="btn small secondary" id="aMinus" title="A-">A−</button><button class="btn small secondary" id="aPlus" title="A+">A+</button>
        <button class="btn small secondary" id="theme">${theme === "dark" ? "☀️" : "🌙"}</button>
        <button class="btn small secondary" id="notesT">📝 ${t("sm_notes")}</button>
        <button class="btn small secondary" id="fs">⛶ ${t("sm_fullscreen")}</button>
        <a class="btn small secondary" href="/api/summaries/${esc(id)}/export?format=pptx">⬇ PPTX</a>
        <button class="btn small secondary" id="pdf">⬇ PDF</button>
      </div>
      <div id="searchRes" class="search-res" hidden></div>
      <div class="deck-body">
        <div class="deck-main">
          <div class="stage" id="stage"></div>
          <div class="deck-nav"><button class="btn secondary" id="prev">${S.lang === "ar" ? "→" : "←"}</button>
            <div class="progress"><div id="pbar"></div></div><span id="counter" class="small"></span>
            <button class="btn" id="next">${S.lang === "ar" ? "←" : "→"}</button></div>
          <div class="thumbs" id="thumbs">${slides.map((sl, i) => `<button class="thumb" data-i="${i}"><span>${i + 1}</span>${esc(sl.title.slice(0, 40))}</button>`).join("")}</div>
        </div>
        <aside class="deck-side" id="side"></aside>
      </div></div>
      <div class="print-deck">${slides.map((sl) => `<div class="print-slide">${slideHTML(ctx, sl, deck.lang)}<div class="print-notes">${sl.notes.map((nn) => `<p>${esc(nn.text)}</p>`).join("")}</div></div>`).join("")}</div>`;
    const render = () => {
      const sl = slides[idx];
      $("#stage").innerHTML = slideHTML(ctx, sl, deck.lang);
      $("#stage .slide").style.fontSize = `${scale}em`;
      $("#counter").textContent = `${idx + 1} / ${slides.length}`;
      $("#pbar").style.width = `${((idx + 1) / slides.length) * 100}%`;
      $$(".thumb").forEach((b) => b.classList.toggle("active", +b.dataset.i === idx));
      const th = $(`.thumb[data-i="${idx}"]`); if (th) th.scrollIntoView({ block: "nearest", inline: "nearest" });
      $("#side").hidden = !notesOpen;
      $("#side").innerHTML = `<h3>📝 ${t("sm_notes")}</h3>${sl.notes.length ? `<ul class="claims">${sl.notes.map((nn) => `<li class="claim2 ${nn.context ? "ctx" : ""}">${nn.label ? `<b>${esc(nn.label)}</b> — ` : ""}${esc(nn.text)}<div class="chips">${(nn.sources || []).map((x) => srcChip(x, s.stale)).join("")}</div></li>`).join("")}</ul>` : `<p class="muted small">—</p>`}
        <button class="btn small secondary" id="exSl">🎓 ${t("sm_explain")}</button><div id="exOut"></div>
        <h3>💬 ${t("sm_slide_chat")}</h3><p class="small muted">${t("sm_slide_chat_note")}</p>
        <div class="row"><input type="text" id="scq" style="flex:1" placeholder="${t("sm_slide_chat_ph")}"><button class="btn small" id="scb">${t("ask_btn")}</button></div>
        <div class="row small" style="margin-top:4px">${["sm_chip_simpler", "sm_chip_meaning", "sm_chip_example", "sm_chip_remember"].map((k) => `<button class="chip-q" data-q="${esc(t(k))}">${t(k)}</button>`).join("")}</div>
        <div id="scOut"></div>
        <h3>${t("sm_sources")}</h3><div class="chips">${sl.sources.map((x) => srcChip(x, s.stale)).join("") || "—"}</div>`;
      $("#exSl").addEventListener("click", async () => {
        $("#exOut").innerHTML = `<span class="spinner"></span>`;
        $("#exOut").innerHTML = explainOut(await api(`/api/summaries/${id}/explain`, { method: "POST", json: { section: sl.id, lang: S.lang } }));
      });
      const ask = async (q) => {
        if (!q) return;
        $("#scOut").innerHTML = `<span class="spinner"></span>`;
        try {
          const r = await api(`/api/summaries/${id}/slide-chat`, { method: "POST", json: { slide_id: sl.id, question: q, lang: S.lang } });
          $("#scOut").innerHTML = r.kind === "document_answer" ? `<div class="notice small">📄 ${esc(r.answer.scope_note)}</div>${ctx.renderAnswer(r.answer)}` : explainOut(r.explanation);
          ctx.wireJumps($("#scOut"));
        } catch (e) { $("#scOut").innerHTML = ctx.errorBox(e); }
      };
      $("#scb").addEventListener("click", () => ask($("#scq").value.trim()));
      $("#scq").addEventListener("keydown", (e) => { if (e.key === "Enter") ask($("#scq").value.trim()); e.stopPropagation(); });
      $$(".chip-q").forEach((b) => b.addEventListener("click", () => { $("#scq").value = b.dataset.q; ask(b.dataset.q); }));
      history.replaceState(null, "", `#/slides/${id}/${idx + 1}`);
    };
    const go = (i) => { idx = Math.min(Math.max(i, 0), slides.length - 1); render(); };
    $("#prev").addEventListener("click", () => go(idx - 1));
    $("#next").addEventListener("click", () => go(idx + 1));
    $$(".thumb").forEach((b) => b.addEventListener("click", () => go(+b.dataset.i)));
    const setScale = (d) => { scale = Math.min(1.6, Math.max(0.7, +(scale + d).toFixed(2))); try { localStorage.setItem("nav_deck_scale", scale); } catch (e) { /* */ } render(); };
    $("#aMinus").addEventListener("click", () => setScale(-0.1));
    $("#aPlus").addEventListener("click", () => setScale(0.1));
    $("#theme").addEventListener("click", () => {
      theme = theme === "dark" ? "light" : "dark";
      try { localStorage.setItem("nav_deck_theme", theme); } catch (e) { /* */ }
      $("#deck").className = `deck-wrap theme-${theme}`; $("#theme").textContent = theme === "dark" ? "☀️" : "🌙";
    });
    $("#notesT").addEventListener("click", () => { notesOpen = !notesOpen; render(); });
    $("#fs").addEventListener("click", () => { const el = $("#deck"); if (document.fullscreenElement) document.exitFullscreen(); else if (el.requestFullscreen) el.requestFullscreen(); });
    $("#pdf").addEventListener("click", () => window.print());
    $("#dsearch").addEventListener("input", () => {
      const q = $("#dsearch").value.trim().toLowerCase(), box = $("#searchRes");
      if (!q) { box.hidden = true; return; }
      const hits = slides.map((sl, i) => [i, sl]).filter(([, sl]) => JSON.stringify([sl.title, sl.bullets.map((b) => b.full || b.text), sl.notes.map((x) => x.text)]).toLowerCase().includes(q));
      box.hidden = false;
      box.innerHTML = hits.length ? hits.map(([i, sl]) => `<button data-i="${i}">${i + 1}. ${esc(sl.title)}</button>`).join("") : `<span class="muted small">${t("none")}</span>`;
      $$("button", box).forEach((b) => b.addEventListener("click", () => { box.hidden = true; go(+b.dataset.i); }));
    });
    S.keyHandler = (e) => {
      if (e.target && (e.target.tagName === "INPUT" || e.target.tagName === "TEXTAREA")) return;
      const rtl = document.documentElement.dir === "rtl";
      if (e.key === "ArrowRight") go(idx + (rtl ? -1 : 1));
      else if (e.key === "ArrowLeft") go(idx + (rtl ? 1 : -1));
      else if (e.key === " " || e.key === "PageDown") { e.preventDefault(); go(idx + 1); }
      else if (e.key === "PageUp") go(idx - 1);
      else if (e.key === "Home") go(0);
      else if (e.key === "End") go(slides.length - 1);
      else if (e.key === "f") $("#fs").click();
      else if (e.key === "n") $("#notesT").click();
    };
    document.addEventListener("keydown", S.keyHandler);
    render();
  };

  // ------------------------------------------------------------------ study mode
  P.study = async (ctx, id) => {
    const { api, esc, t, view, loading, $, $$, S } = ctx;
    const { claim, srcChip } = helpers(ctx);
    loading();
    const s = await api(`/api/summaries/${id}`);
    if (s.status !== "done") { location.hash = `#/summaries/${id}`; return; }
    const st = s.study;
    const tabs = ["concepts", "findings", "remember", "misconceptions", "quiz"];
    view().innerHTML = `<p><a href="#/summaries/${esc(id)}">← ${esc(s.title)}</a></p><h1>🧠 ${t("sm_study")}</h1>
      <p class="sub">${t("sm_study_note")}</p>
      <div class="tabs">${tabs.map((k, i) => `<button data-tab="${k}" class="${i ? "" : "active"}">${t("st_tab_" + k)}</button>`).join("")}</div>
      <div id="tab-concepts">${st.key_concepts.length ? `<div class="flipgrid">${st.key_concepts.map((c) => `<div class="flip" tabindex="0"><div class="front">${esc(c.term)}</div><div class="back">${esc(c.text)}<div class="chips">${(c.sources || []).map((x) => srcChip(x, s.stale)).join("")}</div></div></div>`).join("")}</div><p class="small muted">${t("st_flip")}</p>` : `<p class="muted">${t("sm_not_found")}</p>`}</div>
      <div id="tab-findings" hidden><ul class="claims">${st.findings.map((c) => claim(c, s.stale)).join("") || `<li class="muted">${t("sm_not_found")}</li>`}</ul></div>
      <div id="tab-remember" hidden><ol class="claims remember">${st.remember.map((c) => claim(c, s.stale)).join("")}</ol></div>
      <div id="tab-misconceptions" hidden>${st.misconceptions.length ? `<ul class="claims">${st.misconceptions.map((c) => claim(c, s.stale)).join("")}</ul>` : `<p class="muted">${esc(st.misconceptions_message)}</p>`}</div>
      <div id="tab-quiz" hidden><div class="row"><b>${t("st_score")}: <span id="score">0</span> / ${st.questions.length}</b></div>
        ${st.questions.map((q, i) => `<div class="card quiz" data-q="${esc(q.id)}" data-type="${esc(q.type)}">
          <div class="small muted">${i + 1}. ${esc(t("qt_" + q.type))}</div><div><b>${esc(q.prompt)}</b></div>
          ${q.statement ? `<div class="qtext">${esc(q.statement)}</div>` : ""}
          ${q.type === "mcq" ? `<div class="opts">${q.options.map((o, j) => `<label><input type="radio" name="${esc(q.id)}" value="${j}"> ${esc(o)}</label>`).join("")}</div>`
            : q.type === "tf" ? `<div class="opts"><label><input type="radio" name="${esc(q.id)}" value="true"> ${t("st_true")}</label><label><input type="radio" name="${esc(q.id)}" value="false"> ${t("st_false")}</label></div>`
            : `<input type="text" class="wide sa" placeholder="${t("st_your_answer")}">`}
          <button class="btn small chk">${t("st_check")}</button><div class="qres"></div></div>`).join("") || `<p class="muted">${t("sm_not_found")}</p>`}</div>`;
    $$("[data-tab]").forEach((b) => b.addEventListener("click", () => {
      $$("[data-tab]").forEach((x) => x.classList.toggle("active", x === b));
      tabs.forEach((k) => { $("#tab-" + k).hidden = k !== b.dataset.tab; });
    }));
    $$(".flip").forEach((f) => { const flip = () => f.classList.toggle("on"); f.addEventListener("click", flip); f.addEventListener("keydown", (e) => { if (e.key === "Enter") flip(); }); });
    let score = 0;
    $$(".quiz").forEach((box) => $(".chk", box).addEventListener("click", async () => {
      const type = box.dataset.type;
      let ans;
      if (type === "short") ans = $(".sa", box).value;
      else { const sel = $("input:checked", box); if (!sel) return; ans = type === "tf" ? sel.value === "true" : +sel.value; }
      const r = await api(`/api/summaries/${id}/answer`, { method: "POST", json: { question_id: box.dataset.q, answer: ans, lang: S.lang } });
      if (r.correct === true && !box.dataset.done) score++;
      box.dataset.done = "1";
      $("#score").textContent = score;
      const verdict = r.correct === true ? `<span class="badge ok">✓ ${t("st_correct")}</span>` : r.correct === false ? `<span class="badge err">✗ ${t("st_incorrect")}</span>` : `<span class="badge warn">${esc(r.note)}</span>`;
      const ca = typeof r.correct_answer === "boolean" ? (r.correct_answer ? t("st_true") : t("st_false")) : r.correct_answer;
      $(".qres", box).innerHTML = `<div class="explain-box">${verdict}<div><b>${t("st_correct_answer")}:</b> ${esc(ca)}</div><div class="small">${esc(r.explanation)}</div><div class="chips">${srcChip(r.source, s.stale)}</div></div>`;
    }));
  };
})();
