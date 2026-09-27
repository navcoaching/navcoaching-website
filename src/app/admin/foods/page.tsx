import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import ActionForm from "@/components/admin/ActionForm";
import { saveFoodItemAction } from "@/app/actions/nutrition";
import { fatsecretEnabled } from "@/lib/fatsecret";

type Food = { id: string; name_ar: string; name_en: string | null; category: string | null; kcal_100: number; protein_100: number; carbs_100: number; fat_100: number; serving_g: number | null; serving_label: string | null; source: string; source_ref: string | null; active: boolean };

function FoodFields({ f, p }: { f?: Food; p: string }) {
  const n = (k: "kcal_100" | "protein_100" | "carbs_100" | "fat_100" | "serving_g", l: string, req = false) => (
    <div className="field"><label htmlFor={`${p}-${k}`}>{l}</label>
      <input id={`${p}-${k}`} name={k} type="number" inputMode="decimal" step="0.1" min={0} dir="ltr" required={req} defaultValue={f?.[k] ?? ""} /></div>
  );
  const t = (k: "name_ar" | "name_en" | "category" | "serving_label", l: string, max: number, req = false, ltr = false) => (
    <div className="field"><label htmlFor={`${p}-${k}`}>{l}</label>
      <input id={`${p}-${k}`} name={k} type="text" maxLength={max} required={req} dir={ltr ? "ltr" : undefined} defaultValue={f?.[k] ?? ""} /></div>
  );
  return (
    <>
      <div className="grid g3">{t("name_ar", "الاسم بالعربي", 120, true)}{t("name_en", "الاسم بالإنجليزي (للبحث)", 160, false, true)}{t("category", "الفئة", 60)}</div>
      <p className="small muted" style={{ margin: 0 }}>القيم لكل 100غ. اتركي السعرات فارغة لتُحسب من الماكروز.</p>
      <div className="grid g4">{n("protein_100", "بروتين", true)}{n("carbs_100", "كارب", true)}{n("fat_100", "دهون", true)}{n("kcal_100", "سعرات")}</div>
      <div className="grid g2">{n("serving_g", "الحصة الافتراضية (غ)")}{t("serving_label", "وصف الحصة", 60)}</div>
    </>
  );
}

/** قاعدة الأكل: أصناف بقيمها لكل 100غ، يختار منها المتدرب ويكتب الغرامات */
export default async function Foods({ searchParams }: { searchParams: Promise<{ q?: string }> }) {
  const coach = await requireCoach();
  const q = ((await searchParams).q ?? "").trim().slice(0, 60);
  const { rows, total } = await withUser(coach.id, async (tx) => ({
    rows: (await tx.query(
      `SELECT id, name_ar, name_en, category, kcal_100::float, protein_100::float, carbs_100::float, fat_100::float, serving_g::float, serving_label, source, source_ref, active
         FROM foods WHERE ($1 = '' OR name_ar ILIKE '%' || $1 || '%' OR coalesce(name_en, '') ILIKE '%' || $1 || '%')
        ORDER BY active DESC, category NULLS LAST, name_ar LIMIT 300`, [q])).rows as Food[],
    total: (await tx.query(`SELECT count(*)::int n FROM foods`)).rows[0].n as number,
  }));
  return (
    <div className="stack" style={{ ["--space" as string]: "18px" }}>
      <h1>قاعدة الأكل</h1>
      <p className="muted">
        {total} صنفاً. المتدرب يبحث من «التغذية ← يومي ← ابحث عن أكل» ويكتب الغرامات، والماكروز تُحسب تلقائياً.
        أصناف USDA من قاعدة FoodData Central الأمريكية (بيانات عامة CC0) ومرجعها رقم fdcId.
        {fatsecretEnabled() ? " بحث FatSecret مفعّل كمصدر إضافي للمنتجات ذات الماركات." : " بحث FatSecret غير مفعّل (يحتاج مفاتيح FATSECRET_CLIENT_ID و FATSECRET_CLIENT_SECRET)."}
      </p>
      <details className="card">
        <summary className="btn btn-sm">+ صنف جديد</summary>
        <ActionForm action={saveFoodItemAction} submit="إضافة الصنف" resetOnSuccess>
          <FoodFields p="new" />
        </ActionForm>
      </details>
      <form className="filters" role="search">
        <div className="field"><label htmlFor="fq">بحث</label><input id="fq" name="q" type="search" defaultValue={q} /></div>
        <button className="btn btn-sm">عرض</button>
      </form>
      <div className="table-wrap">
        <table className="t" data-testid="admin-foods">
          <thead><tr><th>الصنف</th><th>سعرات/100غ</th><th>بروتين</th><th>كارب</th><th>دهون</th><th>الحصة</th><th>المصدر</th></tr></thead>
          <tbody>
            {rows.length === 0 && <tr><td colSpan={7} className="muted">لا توجد أصناف{q ? " مطابقة" : " بعد"}.</td></tr>}
            {rows.map((f) => (
              <tr key={f.id}>
                <td>
                  <details>
                    <summary style={{ cursor: "pointer" }}><b>{f.name_ar}</b>{!f.active && <> <span className="status muted">مخفي</span></>}{f.name_en && <div className="small muted" dir="ltr">{f.name_en}</div>}</summary>
                    <ActionForm action={saveFoodItemAction} submit="حفظ">
                      <input type="hidden" name="id" value={f.id} />
                      <FoodFields f={f} p={`f-${f.id}`} />
                      <label className="check"><input type="checkbox" name="active" value="off" defaultChecked={!f.active} /><span>إخفاء عن المتدربين</span></label>
                    </ActionForm>
                  </details>
                </td>
                <td className="num">{Math.round(f.kcal_100)}</td><td className="num">{f.protein_100}</td><td className="num">{f.carbs_100}</td><td className="num">{f.fat_100}</td>
                <td className="small">{f.serving_g ? `${f.serving_g}غ` : "—"}{f.serving_label && <div className="muted">{f.serving_label}</div>}</td>
                <td className="small">{f.source === "usda" ? <>USDA{f.source_ref && <div className="muted num">#{f.source_ref}</div>}</> : "المدربة"}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
