"use client";
import { useMemo, useState } from "react";
import Link from "next/link";
import { QUIZ_SKU, recommend } from "@/lib/quiz";

type OfferInfo = { sku: string; name: string; slug: string; price: string; monthly: boolean };
const Q = [
  { name: "level", title: "وش مستواك في التمرين؟", opts: [["beg", "مبتدئ · أقل من 6 أشهر"], ["mid", "متوسط · 6 أشهر – سنتين"], ["adv", "متقدم · أكثر من سنتين"]] },
  { name: "need", title: "وش تحتاج بالضبط؟", opts: [["both", "تمرين وتغذية"], ["train", "تمرين فقط"], ["food", "تغذية فقط"], ["askT", "عندي أسئلة محددة في التمرين"], ["askN", "عندي أسئلة محددة في التغذية"]] },
  { name: "follow", title: "أي نوع متابعة يناسبك؟", opts: [["close", "متابعة أسبوعية + مكالمات زوم"], ["weekly", "متابعة أسبوعية بدون مكالمات"], ["none", "ما أحتاج متابعة، أبي جدول وأمشي عليه"]] },
  { name: "live", title: "تحتاج جلسة حضورية لتصحيح التكنيك؟ (للبنات في المنطقة الشرقية)", opts: [["yes", "نعم"], ["no", "لا"]] },
] as const;

export default function Quiz({ offers }: { offers: Record<string, OfferInfo> }) {
  const [a, setA] = useState<Record<string, string>>({});
  const asking = a.need?.startsWith("ask");
  const done = a.level && a.need && (asking || (a.follow && a.live));
  const r = useMemo(() => (done ? recommend({ level: a.level, need: a.need, follow: a.follow ?? "", live: a.live ?? "" }) : null), [a, done]);
  const P = r ? offers[QUIZ_SKU[r.k]] : null;
  const A = r?.alt && r.alt !== r.k ? offers[QUIZ_SKU[r.alt]] : null;
  return (
    <div className="grid g2 quiz" style={{ alignItems: "start" }}>
      <form className="form card flat" onSubmit={(e) => e.preventDefault()}>
        {Q.map((q, i) => (asking && i >= 2 ? null : (
          <fieldset className="field" key={q.name}>
            <legend>{i + 1}. {q.title}</legend>
            <div className="choices">
              {q.opts.map(([v, label]) => (
                <label className="choice" key={v}>
                  <input type="radio" name={q.name} value={v} checked={a[q.name] === v} onChange={() => setA({ ...a, [q.name]: v })} />
                  <span>{label}</span>
                </label>
              ))}
            </div>
          </fieldset>
        )))}
      </form>
      <div className="card" aria-live="polite">
        {!P ? (
          <p className="muted">جاوب على الأسئلة وتظهر لك التوصية هنا.</p>
        ) : (
          <div className="stack">
            <span className="eyebrow">الباقة الأنسب لك</span>
            <h3 style={{ fontSize: 26 }}>{P.name}</h3>
            <p className="num" style={{ fontWeight: 600 }}>{P.price}{P.monthly ? " / شهر" : ""}</p>
            <ul className="checklist">{r!.why.map((w) => <li key={w}>{w}</li>)}</ul>
            <div className="row">
              <Link className="btn" href={`/checkout/${P.sku}`}>اشترك في {P.name}</Link>
              <Link className="btn btn-ghost" href={`/programs/${P.slug}`}>شوف تفاصيلها</Link>
            </div>
            {A && <p className="small muted">بديل مناسب: <Link href={`/programs/${A.slug}`}>{A.name}</Link> ({A.price}{A.monthly ? " / شهر" : ""})</p>}
          </div>
        )}
      </div>
    </div>
  );
}
