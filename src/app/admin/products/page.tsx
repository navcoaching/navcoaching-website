import Link from "next/link";
import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import { CATEGORY_LABEL, riyals } from "@/lib/format";

export default async function AdminProducts() {
  const coach = await requireCoach();
  const rows = await withUser(coach.id, async (tx) => (await tx.query(
    `SELECT p.id, p.slug, p.name, p.category, p.status, p.is_demo, p.sort,
            coalesce(json_agg(json_build_object('label', o.label, 'price', o.price_halalas, 'active', o.active) ORDER BY o.sort) FILTER (WHERE o.id IS NOT NULL), '[]') offers
       FROM products p LEFT JOIN product_offers o ON o.product_id = p.id GROUP BY p.id ORDER BY p.category, p.sort`)).rows);
  const ST: Record<string, string> = { draft: "مسودة", published: "منشور", archived: "مؤرشف" };
  return (
    <div>
      <div className="row" style={{ justifyContent: "space-between" }}><h1>المنتجات</h1><Link className="btn btn-sm" href="/admin/products/new">منتج جديد</Link></div>
      <p className="small muted" style={{ marginBottom: 14 }}>تعديل السعر لا يغيّر مبلغ الطلبات السابقة؛ كل طلب يحتفظ بسعره وقت الطلب.</p>
      <div className="table-wrap">
        <table className="t">
          <thead><tr><th>المنتج</th><th>القسم</th><th>الأسعار</th><th>الحالة</th></tr></thead>
          <tbody>
            {rows.map((p) => (
              <tr key={p.id}>
                <td><Link href={`/admin/products/${p.id}`}>{p.name}</Link>{p.is_demo && <span className="tag demo" style={{ marginInlineStart: 6 }}>تجريبي</span>}<div className="small muted ltr">/programs/{p.slug}</div></td>
                <td>{CATEGORY_LABEL[p.category]}</td>
                <td className="small">{(p.offers as { label: string; price: number; active: boolean }[]).map((o) => <div key={o.label} className={o.active ? "" : "muted"}>{o.label}: {riyals(o.price)}{o.active ? "" : " (موقوف)"}</div>)}</td>
                <td>{ST[p.status]}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
