import Link from "next/link";
import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import { EX_STATUS, REHAB_CATEGORIES, REHAB_DISCLAIMER, REHAB_REVIEW, REHAB_STOP, muscleAr, splitPipes, type ExStatus, type RehabReview } from "@/lib/exercises";
import AutoSubmitForm from "@/components/admin/AutoSubmitForm";

type SP = { cat?: string; view?: string };
type Row = {
  id: string; name: string; primary_muscle: string; status: ExStatus; rehab_category: string; rehab_goal: string | null; rehab_phase: string | null;
  rehab_load: string | null; rehab_safety: string | null; rehab_evidence: string | null; rehab_refs: string | null; rehab_review: RehabReview | null;
};
const REVIEW_CLASS: Record<RehabReview, string> = { specialist: "ok", needs_review: "action", not_approved: "err" };

/** التمارين التأهيلية — عرض حسب التصنيف (كما في ورقة «التمارين التأهيلية»). لا يرتبط بقوائم البرامج. */
export default async function Rehab({ searchParams }: { searchParams: Promise<SP> }) {
  const coach = await requireCoach();
  const sp = await searchParams;
  const cat = (REHAB_CATEGORIES as readonly string[]).includes(sp.cat ?? "") ? sp.cat! : "";
  const onlySpecialist = sp.view === "specialist";
  const all = await withUser(coach.id, async (tx) => (await tx.query(
    `SELECT id, name, primary_muscle, status, rehab_category, rehab_goal, rehab_phase, rehab_load, rehab_safety, rehab_evidence, rehab_refs, rehab_review
       FROM exercises WHERE rehab_category IS NOT NULL ORDER BY name`)).rows as Row[]);
  const counts = new Map(REHAB_CATEGORIES.map((c) => [c, all.filter((r) => splitPipes(r.rehab_category).includes(c)).length]));
  const rows = all.filter((r) => (!cat || splitPipes(r.rehab_category).includes(cat)) && (!onlySpecialist || r.rehab_review === "specialist"));

  return (
    <div className="stack" style={{ ["--space" as string]: "16px" }}>
      <div>
        <h1>التمارين التأهيلية</h1>
        <p className="small muted" style={{ margin: 0 }}>عرض حسب التصنيف. للمدربة فقط، ولا يرتبط بقوائم البرامج. التعديل من صفحة التمرين في المكتبة.</p>
      </div>
      <p className="alert warn" style={{ margin: 0 }}>{REHAB_DISCLAIMER}</p>
      <p className="alert err" style={{ margin: 0 }}>{REHAB_STOP}</p>

      <AutoSubmitForm className="filters">
        <div className="field"><label htmlFor="rh-cat">التصنيف</label>
          <select id="rh-cat" name="cat" defaultValue={cat}>
            <option value="">الكل ({all.length})</option>
            {REHAB_CATEGORIES.map((c) => <option key={c} value={c}>{c} ({counts.get(c)})</option>)}
          </select></div>
        <div className="field"><label htmlFor="rh-view">العرض</label>
          <select id="rh-view" name="view" defaultValue={onlySpecialist ? "specialist" : ""}>
            <option value="">الكل</option>
            <option value="specialist">المعتمد من مختص فقط</option>
          </select></div>
        <noscript><button className="btn btn-sm">عرض</button></noscript>
      </AutoSubmitForm>
      <p className="small" style={{ margin: 0 }} data-testid="rehab-count">النتائج: <b>{rows.length}</b></p>
      {onlySpecialist && rows.length === 0 && <p className="card muted">لا توجد تمارين معتمدة من مختص في هذا التصنيف بعد. غيّري «حالة المراجعة العلاجية» من صفحة التمرين بعد اعتماد الأخصائي.</p>}

      {rows.length > 0 && (
        <div className="table-wrap">
          <table className="t rehab-table" data-testid="rehab-table">
            <thead><tr><th>#</th><th>التمرين</th><th>العضلة الأساسية</th><th>الهدف الحركي أو العلاجي</th><th>المرحلة</th><th>التحميل</th><th>ملاحظات السلامة</th><th>مصدر الدليل</th><th>رابط المرجع</th><th>حالة المراجعة العلاجية</th><th>اعتماد المدربة</th></tr></thead>
            <tbody>
              {rows.map((r, i) => (
                <tr key={r.id}>
                  <td className="num">{i + 1}</td>
                  <td><Link href={`/admin/exercises/${r.id}`}><bdi dir="ltr">{r.name}</bdi></Link>
                    {!cat && <div className="small muted">{splitPipes(r.rehab_category).map((c) => c.split(" / ")[0]).join("، ")}</div>}</td>
                  <td>{muscleAr(r.primary_muscle)}</td>
                  <td>{r.rehab_goal ?? "—"}</td>
                  <td>{r.rehab_phase ?? "—"}</td>
                  <td>{r.rehab_load ?? "—"}</td>
                  <td className="small">{r.rehab_safety ?? "—"}</td>
                  <td className="small" dir="auto">{splitPipes(r.rehab_evidence).map((e) => <div key={e}>{e}</div>)}</td>
                  <td className="small">{splitPipes(r.rehab_refs).map((u, j) => <div key={u}><a href={u} target="_blank" rel="noopener noreferrer">مرجع {j + 1} ↗</a></div>)}</td>
                  <td>{r.rehab_review ? <span className={`status ${REVIEW_CLASS[r.rehab_review]}`}>{REHAB_REVIEW[r.rehab_review]}</span> : "—"}</td>
                  <td>{r.status === "approved" ? <span className="status ok">{EX_STATUS[r.status]}</span> : <span className="status muted">{EX_STATUS[r.status]}</span>}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
