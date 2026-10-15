import Link from "next/link";
import { notFound } from "next/navigation";
import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import ActionForm from "@/components/admin/ActionForm";
import NutritionPlanEditor from "@/components/admin/NutritionPlanEditor";
import { deletePlanAction, savePlanAction } from "@/app/actions/nutrition";
import { loadPlans } from "@/lib/nutrition-data";

export default async function PlanPage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ created?: string }> }) {
  const coach = await requireCoach();
  const { id } = await params;
  const { created } = await searchParams;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const data = await withUser(coach.id, async (tx) => {
    const [plan] = await loadPlans(tx, { ids: [id] });
    if (!plan) return null;
    const owner = plan.order_id ? (await tx.query(`SELECT order_no, contact_name FROM orders WHERE id = $1`, [plan.order_id])).rows[0] : null;
    return { plan, owner: owner as { order_no: string; contact_name: string } | null };
  });
  if (!data) notFound();
  const { plan, owner } = data;
  return (
    <div className="stack" style={{ ["--space" as string]: "18px", maxWidth: 1000 }}>
      <nav className="small">
        {owner ? <><Link href={`/admin/orders/${owner.order_no}/nutrition`}>التغذية — {owner.contact_name}</Link> / {plan.name}</>
          : <><Link href="/admin/nutrition">التغذية والمكملات</Link> / {plan.name}</>}
      </nav>
      <h1>{plan.name}</h1>
      {owner && <p className="alert info">نسخة خاصة بالمتدرب {owner.contact_name}. التعديل هنا يظهر له مباشرة ولا يغيّر القالب.</p>}
      {created && <p className="alert ok" role="status">تم إنشاء الجدول. أضيفي الوجبات بالأسفل.</p>}
      <details className="card">
        <summary style={{ cursor: "pointer", minHeight: 40, fontWeight: 700 }}>اسم الجدول والملاحظات</summary>
        <ActionForm action={savePlanAction}>
          <input type="hidden" name="id" value={plan.id} />
          <div className="field"><label htmlFor="pl-name">الاسم</label><input id="pl-name" name="name" type="text" required maxLength={120} defaultValue={plan.name} /></div>
          <div className="field"><label htmlFor="pl-notes">ملاحظات (تظهر للمتدرب)</label><textarea id="pl-notes" name="notes" maxLength={3000} rows={3} defaultValue={plan.notes ?? ""} /></div>
          <label className="check"><input type="checkbox" name="archived" defaultChecked={plan.archived} /><span>{owner ? "مخفي عن المتدرب" : "مؤرشف (لا يظهر في قائمة الإسناد)"}</span></label>
        </ActionForm>
        <ActionForm action={deletePlanAction} className="form" submit="حذف الجدول" submitClass="btn btn-ghost btn-sm danger" confirm={`حذف «${plan.name}» نهائياً؟`}>
          <input type="hidden" name="id" value={plan.id} />
        </ActionForm>
      </details>
      <NutritionPlanEditor plan={plan} />
    </div>
  );
}
