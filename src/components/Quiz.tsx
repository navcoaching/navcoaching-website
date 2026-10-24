"use client";
import { useMemo, useState } from "react";
import Link from "next/link";
import { QUIZ_SKU, recommend } from "@/lib/quiz";
import { href } from "@/lib/lang";
import { useLang } from "@/lib/use-lang";
import { t } from "@/i18n/ui";

type OfferInfo = { sku: string; name: string; slug: string; price: string; monthly: boolean };
const KEYS = [
  { name: "level", vals: ["beg", "mid", "adv"] },
  { name: "need", vals: ["both", "train", "food", "askT", "askN"] },
  { name: "follow", vals: ["close", "weekly", "none"] },
  { name: "live", vals: ["yes", "no"] },
] as const;

export default function Quiz({ offers }: { offers: Record<string, OfferInfo> }) {
  const lang = useLang();
  const u = t(lang).quiz;
  const [a, setA] = useState<Record<string, string>>({});
  const asking = a.need?.startsWith("ask");
  const done = a.level && a.need && (asking || (a.follow && a.live));
  const r = useMemo(() => (done ? recommend({ level: a.level, need: a.need, follow: a.follow ?? "", live: a.live ?? "" }, lang) : null), [a, done, lang]);
  const P = r ? offers[QUIZ_SKU[r.k]] : null;
  const A = r?.alt && r.alt !== r.k ? offers[QUIZ_SKU[r.alt]] : null;
  return (
    <div className="grid g2 quiz" style={{ alignItems: "start" }}>
      <form className="form card flat" onSubmit={(e) => e.preventDefault()}>
        {KEYS.map((q, i) => (asking && i >= 2 ? null : (
          <fieldset className="field" key={q.name}>
            <legend>{i + 1}. {u.q[i].title}</legend>
            <div className="choices">
              {q.vals.map((v, j) => (
                <label className="choice" key={v}>
                  <input type="radio" name={q.name} value={v} checked={a[q.name] === v} onChange={() => setA({ ...a, [q.name]: v })} />
                  <span>{u.q[i].opts[j]}</span>
                </label>
              ))}
            </div>
          </fieldset>
        )))}
      </form>
      <div className="card" aria-live="polite">
        {!P ? (
          <p className="muted">{u.waiting}</p>
        ) : (
          <div className="stack">
            <span className="eyebrow">{u.best}</span>
            <h3 style={{ fontSize: 26 }}>{P.name}</h3>
            <p className="num" style={{ fontWeight: 600 }}>{P.price}{P.monthly ? u.perMonth : ""}</p>
            <ul className="checklist">{r!.why.map((w) => <li key={w}>{w}</li>)}</ul>
            <div className="row">
              <Link className="btn" href={`/checkout/${P.sku}`}>{u.subscribeIn} {P.name}</Link>
              <Link className="btn btn-ghost" href={href(lang, `/programs/${P.slug}`)}>{u.details}</Link>
            </div>
            {A && <p className="small muted">{u.alt} <Link href={href(lang, `/programs/${A.slug}`)}>{A.name}</Link> ({A.price}{A.monthly ? u.perMonth : ""})</p>}
          </div>
        )}
      </div>
    </div>
  );
}
