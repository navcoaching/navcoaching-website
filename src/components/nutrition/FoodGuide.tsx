import Link from "next/link";
import type { Tx } from "@/lib/db";
import { SOURCE_GROUPS, SOURCE_TYPES, TAG_FILTERS, foodTags, matchesTag, nutrientRows, type FoodDetail } from "@/lib/food-tags";

export type GuideFood = FoodDetail & { id: string; kcal_100: number; carbs_100: number; fat_100: number };
export type GuideSP = { type?: string; tag?: string; q?: string };

/** أصناف قاعدة الأكل الفعّالة مع تفاصيلها (RLS: للمدربة ولمن عنده طلب مدفوع) */
export async function loadGuideFoods(tx: Tx): Promise<GuideFood[]> {
  return (await tx.query(
    `SELECT id, name_ar, source_type, serving_g::float, serving_label, kcal_100::float, protein_100::float, carbs_100::float, fat_100::float,
            fiber_100::float, micros
       FROM foods WHERE active ORDER BY name_ar`)).rows as GuideFood[];
}

const per = (f: GuideFood) => (f.serving_g ? `${f.serving_label ? `${f.serving_label} · ` : ""}${f.serving_g}غ` : "100غ");
const r0 = (v: number) => Math.round(v);
const scale = (v: number, f: GuideFood) => (v * (f.serving_g || 100)) / 100;

/** دليل مصادر الأكل: تصنيف حسب نوع المصدر (لحوم حمراء، دواجن، أسماك، بقوليات...) وحسب القيمة الغذائية (عالي الألياف، غني بفيتامين C...) */
export default function FoodGuide({ foods, sp, base }: { foods: GuideFood[]; sp: GuideSP; base: string }) {
  const type = SOURCE_TYPES.includes(sp.type as (typeof SOURCE_TYPES)[number]) ? sp.type! : "";
  const tag = TAG_FILTERS.some((t) => t.v === sp.tag) ? sp.tag! : "";
  const q = (sp.q ?? "").trim().slice(0, 60);
  const list = foods.filter((f) => (!type || f.source_type === type) && (!tag || matchesTag(f, tag)) && (!q || f.name_ar.includes(q)));
  const href = (over: GuideSP) => {
    const p = new URLSearchParams(Object.entries({ type, tag, q, ...over }).filter(([, v]) => v) as [string, string][]);
    return `${base}${p.size ? `?${p}` : ""}`;
  };
  const types = SOURCE_TYPES.filter((t) => foods.some((f) => f.source_type === t));
  const groups = type ? [type] : types;

  return (
    <div className="stack" style={{ ["--space" as string]: "16px" }} data-testid="food-guide">
      <form className="card stack" style={{ ["--space" as string]: "10px" }} action={base} method="get" aria-label="تصفية مصادر الأكل">
        <div className="grid g3">
          <div className="field"><label htmlFor="fg-type">نوع المصدر</label>
            <select id="fg-type" name="type" defaultValue={type}>
              <option value="">الكل</option>
              {SOURCE_GROUPS.map((g) => (
                <optgroup key={g.label} label={g.label}>
                  {g.types.filter((t) => types.includes(t as (typeof SOURCE_TYPES)[number])).map((t) => <option key={`${g.label}-${t}`} value={t}>{t}</option>)}
                </optgroup>
              ))}
            </select></div>
          <div className="field"><label htmlFor="fg-tag">القيمة الغذائية</label>
            <select id="fg-tag" name="tag" defaultValue={tag}>
              <option value="">الكل</option>
              {TAG_FILTERS.map((t) => <option key={t.v} value={t.v}>{t.l}</option>)}
            </select></div>
          <div className="field"><label htmlFor="fg-q">بحث بالاسم</label><input id="fg-q" name="q" defaultValue={q} maxLength={60} /></div>
        </div>
        <div className="row" style={{ gap: 8 }}>
          <button className="btn btn-sm" type="submit">عرض</button>
          {(type || tag || q) && <Link className="btn btn-ghost btn-sm" href={base}>مسح التصفية</Link>}
        </div>
      </form>

      <nav className="pill-nav" aria-label="اختصارات">
        {[["fiber", "عالي الألياف"], ["protein", "عالي البروتين"], ["vitamins", "غني بالفيتامينات"], ["minerals", "غني بالمعادن"]].map(([v, l]) => (
          <Link key={v} href={href({ tag: tag === v ? "" : v })} aria-current={tag === v ? "true" : undefined}>{l}</Link>
        ))}
      </nav>

      <p className="small muted" style={{ margin: 0 }} data-testid="guide-count">{list.length} صنف</p>
      {list.length === 0 && <p className="card muted">ما فيه أصناف بهذي التصفية.</p>}

      {groups.map((g) => {
        const items = list.filter((f) => f.source_type === g);
        if (!items.length) return null;
        return (
          <section key={g} className="stack" style={{ ["--space" as string]: "10px" }} aria-label={g}>
            <h2 style={{ fontSize: 19, margin: 0 }}>{g} <span className="small muted">({items.length})</span></h2>
            <div className="grid g2">
              {items.map((f) => {
                const tags = foodTags(f);
                const rows = nutrientRows(f).filter((r) => r.kind !== "protein");
                return (
                  <details key={f.id} className="card stack food-card" style={{ ["--space" as string]: "8px" }} data-testid="guide-food">
                    <summary style={{ cursor: "pointer", listStyle: "none" }}>
                      <b>{f.name_ar}</b>
                      <div className="small muted">لكل {per(f)}: <span className="num">{r0(scale(f.kcal_100, f))}</span> سعرة · ب <span className="num">{r0(scale(f.protein_100, f))}</span> · ك <span className="num">{r0(scale(f.carbs_100, f))}</span> · د <span className="num">{r0(scale(f.fat_100, f))}</span></div>
                      {tags.length > 0 && (
                        <div className="row" style={{ gap: 6, flexWrap: "wrap", marginTop: 6 }}>
                          {tags.slice(0, 4).map((t) => <span key={t.key} className={`status ${t.level === "rich" ? "ok" : "wait"}`}>{t.text}</span>)}
                          {tags.length > 4 && <span className="small muted">+{tags.length - 4}</span>}
                        </div>
                      )}
                      <span className="small" style={{ color: "var(--navy)" }}>التفاصيل ▾</span>
                    </summary>
                    <ul className="food-rows" aria-label={`القيم الغذائية لكل ${per(f)}`}>
                      {rows.map((r) => (
                        <li key={r.key}>
                          <span>{r.label}</span>
                          <span className="num">{r.amount} {r.unit}</span>
                          <span><span className="num">{r.pct}%</span>{r.level && <> <span className={`status ${r.level === "rich" ? "ok" : "wait"}`}>{r.level === "rich" ? "غني" : "جيد"}</span></>}</span>
                        </li>
                      ))}
                    </ul>
                    <span className="small muted">النسبة = من الاحتياج اليومي للحصة ({per(f)}).</span>
                  </details>
                );
              })}
            </div>
          </section>
        );
      })}

      <p className="small muted" style={{ margin: 0 }}>
        القيم من قاعدة بيانات USDA الأمريكية (FoodData Central). «غني» = 20% أو أكثر من الاحتياج اليومي في الحصة، و«مصدر جيد» = 10–19%،
        حسب الاحتياج اليومي للبالغين في ملصق الغذاء الأمريكي (FDA). العنصر اللي ما له قيمة في المصدر ما يظهر.
      </p>
    </div>
  );
}
