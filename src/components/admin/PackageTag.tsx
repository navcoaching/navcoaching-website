/**
 * شارة الباقة في الطلبات.
 * المنطق: تعرض اسم الباقة المحفوظ وقت الطلب (نسخة تاريخية دقيقة لا تتغير)،
 * واللون ثابت لكل منتج (مشتق من معرّفه) حتى لو تغيّر اسمه لاحقاً.
 * إذا تغيّر اسم المنتج في إدارة المنتجات يظهر الاسم الحالي كتلميح بجانبه.
 */
export function tagColor(productId: string | null) {
  if (!productId) return 0;
  let h = 0;
  for (const ch of productId) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
  return h % 8;
}

export default function PackageTag({ name, productId, currentName }: { name: string; productId: string | null; currentName?: string | null }) {
  const renamed = currentName && currentName !== name;
  return (
    <span className={`ptag c${tagColor(productId)}`} title={renamed ? `الاسم الحالي: ${currentName}` : undefined}>
      {name}{renamed && <span className="ptag-now"> ← {currentName}</span>}
    </span>
  );
}
