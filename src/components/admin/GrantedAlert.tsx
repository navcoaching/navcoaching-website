import Link from "next/link";

/** نتيجة منح مكافأة الالتزام (بعد التحويل من الإجراء) */
export default function GrantedAlert({ no, sent }: { no: string; sent: boolean }) {
  return (
    <p className="alert ok" role="status" data-testid="granted-alert">
      <span>تم منح 3 أشهر مجاناً (طلب <Link href={`/admin/orders/${no}`}><bdi className="num">{no}</bdi></Link>). تبدأ بعد نهاية اشتراكه الحالي.
        {sent ? " ووصله إشعار." : " الإشعار لم يُرسل فعلياً (البريد/واتساب غير مفعّل أو معطّل في تفضيلاته)."}</span>
    </p>
  );
}
