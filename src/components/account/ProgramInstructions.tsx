import { WEEKDAYS, fmtYMD, riyadhDate } from "@/lib/schedule";
import { DEFAULT_RULES } from "@/lib/nutrition";
import { CONTACT_RULES, RIR_VIDEO, TRAINING_RULES, type Rule } from "@/lib/instructions";
import type { ProgramToday } from "./ProgramToday";

type O = { contact_name?: string | null; product_name: string; offer_label: string; review_weekday?: number | null; sub_start_at?: string | null; sub_end_at?: string | null };

const n0 = (v: number) => Math.round(v).toLocaleString("en-US");

function Rules({ title, rules, id }: { title: string; rules: Rule[]; id: string }) {
  return (
    <details className="rules-box" open data-testid={id}>
      <summary>{title}</summary>
      <dl className="rules-list">
        {rules.map(([t, b], i) => (
          <div key={i}>{t && <dt>{t}</dt>}<dd>{b}{t.startsWith("شدة التمرين") && <> <a href={RIR_VIDEO} target="_blank" rel="noopener noreferrer">مثال على الشرح ▶</a></>}</dd></div>
        ))}
      </dl>
    </details>
  );
}

/** «التعليمات» كما في ورقة التعليمات بملف التدريب: المعلومات الأساسية، الأرقام الغذائية، والقواعد */
export default function ProgramInstructions({ o, p }: { o: O; p: ProgramToday | undefined }) {
  const start = o.sub_start_at ? riyadhDate(o.sub_start_at) : null;
  const end = o.sub_end_at ? riyadhDate(o.sub_end_at) : null;
  const info: [string, string][] = [
    ["الاسم", o.contact_name || "—"],
    ["الباقة", `${o.product_name} · ${o.offer_label}`],
    ["يوم المراجعة", o.review_weekday != null ? WEEKDAYS[o.review_weekday] : "تحدده المدربة"],
    ["تاريخ البداية", start ? fmtYMD(start) : "—"],
    ["تاريخ التجديد", end ? fmtYMD(end) : "—"],
    ["أسبوع البرنامج الحالي", p?.block ? `الأسبوع ${p.block.week} من ${p.block.weeks}` : "—"],
  ];
  const t = p?.target;
  const nutritionRules: Rule[] = (t?.rules?.trim() || DEFAULT_RULES).split("\n").map((l) => l.trim()).filter(Boolean).map((l) => {
    const i = l.indexOf(":");
    return i > 0 && i < 30 ? [l.slice(0, i).trim(), l.slice(i + 1).trim()] : ["", l];
  });
  return (
    <section id="instructions" className="card stack instructions" style={{ ["--space" as string]: "14px" }} aria-labelledby="ins-h" data-testid="instructions">
      <div>
        <h2 id="ins-h" style={{ fontSize: 19, margin: 0 }}>📋 التعليمات</h2>
        <p className="small muted" style={{ margin: "2px 0 0" }}>المعلومات الأساسية وقواعد البرنامج</p>
      </div>
      <dl className="ins-info">
        {info.map(([k, v]) => <div key={k}><dt>{k}</dt><dd>{v}</dd></div>)}
      </dl>
      {t && (t.kcal != null || t.protein != null) && (
        <div className="stack" style={{ ["--space" as string]: "6px" }}>
          <b className="small">الأرقام الغذائية اليومية</b>
          <div className="today-macros">
            {([["السعرات", t.kcal, "سعرة"], ["البروتين", t.protein, "غ"], ["الكارب", t.carbs, "غ"], ["الدهون", t.fat, "غ"]] as const).map(([label, v, unit]) => (
              <div key={label}><span className="small muted">{label}</span><b className="num">{v != null ? `${n0(v)} ${unit}` : "—"}</b></div>
            ))}
          </div>
        </div>
      )}
      <div className="rules-grid">
        <Rules id="rules-nutrition" title="🥗 قواعد التغذية" rules={nutritionRules} />
        <Rules id="rules-contact" title="💬 قواعد التواصل والمراجعة" rules={CONTACT_RULES} />
        <Rules id="rules-training" title="🏋️ تعليمات التمرين" rules={TRAINING_RULES} />
      </div>
    </section>
  );
}
