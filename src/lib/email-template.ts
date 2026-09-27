// قالب بريد العميل (HTML) بهوية Nav Coaching: ترحيب، عنوان، حالة الطلب بخطوات، ملخص الطلب، وتذييل.
// جداول وأنماط داخلية لأن برامج البريد لا تدعم CSS الحديث. منطق خالص بدون قاعدة بيانات (يُختبر مباشرة).
// لا بيانات صحية في البريد أبداً: اسم المتدرب والطلب والحالة فقط.

export type EmailOrder = {
  orderNo: string; createdAt: string; status: string; category: string;
  product: string; offer: string; amountHalalas: number | null; paymentMethod: string;
};
export type EmailBrand = { site: string; whatsapp?: string; instagram?: string; legalName?: string; cr?: string };
export type EmailInput = {
  name?: string | null;
  headline: string;
  message: string;
  order?: EmailOrder;
  code?: string;                 // رمز الدخول (بريد OTP)
  cta?: { label: string; url: string };
  brand: EmailBrand;
  kicker?: string;               // نص الترويسة بجانب الشعار (الافتراضي: شكراً لاختيارك)
};

const C = { ink: "#07142a", navy: "#284da0", cyan: "#4cc5ed", cyanInk: "#0a6a8f", paper: "#f3f6fa", soft: "#eef3f8", line: "#d8e1ea", text: "#15233a", muted: "#56667a" };
const FONT = "'IBM Plex Sans Arabic', Tahoma, Arial, sans-serif";

export const esc = (s: unknown) =>
  String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
const nl2br = (s: string) => esc(s).replace(/\n/g, "<br>")
  .replace(/https?:\/\/[^\s<]+/g, (u) => `<a href="${u}" style="color:${C.cyanInk};word-break:break-all" dir="ltr">${u}</a>`)
  .replace(/NAV-\d{6}-[A-Z0-9]{5}/g, (n) => `<span dir="ltr" style="white-space:nowrap">${n}</span>`);

export const sar = (h: number | null) => (h == null ? "بانتظار تأكيد المبلغ" : `${(h / 100).toLocaleString("en-US", { maximumFractionDigits: 2 })} ر.س`);

export function fmtOrderDate(iso: string) {
  const d = new Date(iso);
  const day = new Intl.DateTimeFormat("ar-SA-u-ca-gregory-nu-latn", { weekday: "long", day: "numeric", month: "long", year: "numeric", timeZone: "Asia/Riyadh" }).format(d);
  const time = new Intl.DateTimeFormat("ar-SA-u-nu-latn", { hour: "numeric", minute: "2-digit", timeZone: "Asia/Riyadh" }).format(d);
  return `${day} | ${time}`;
}

/** خطوات مختصرة لحالة الطلب (مثل: طلبك مؤكد ← قيد الإعداد ← جاهز) */
export function orderSteps(status: string, category: string): { label: string; state: "done" | "now" | "next" }[] {
  const last = category === "follow" ? "البرنامج نشط" : category === "files" ? "تم التسليم" : "تمت الجلسة";
  const labels = ["تم استلام طلبك", "تأكيد الدفع", category === "consult" ? "قيد التنسيق" : "قيد الإعداد", last];
  const idx: Record<string, number> = { awaiting_quote: 1, awaiting_payment: 1, payment_review: 1, preparing: 2, active: 3, delivered: 3, completed: 3 };
  const at = idx[status] ?? -1;
  const finished = ["active", "delivered", "completed"].includes(status);
  return labels.map((label, i) => ({ label, state: i < at || (finished && i === at) ? "done" : i === at ? "now" : "next" }));
}

export const PAYMENT_LABEL: Record<string, string> = { bank_transfer: "تحويل بنكي", gateway: "دفع إلكتروني" };

/** عنوان ونص البريد لكل حالة طلب */
export function statusCopy(status: string, category: string): { headline: string; message: string } {
  switch (status) {
    case "awaiting_quote": return { headline: "وصلنا طلبك 🙌", message: "طلبت خصم الطالب. أرسل إثبات الطالب على واتساب، ونأكد لك المبلغ النهائي في حسابك قبل التحويل." };
    case "awaiting_payment": return { headline: "وصلنا طلبك 🙌", message: "خطوة وحدة وتبدأ رحلتك: حوّل المبلغ على الحساب الموضح في صفحة طلبك، ثم ارفع صورة الإيصال." };
    case "payment_review": return { headline: "وصلنا إيصالك 🧾", message: "نتحقق الآن من وصول المبلغ، ونحدّث حالة طلبك بعد التأكد مباشرة." };
    case "preparing": return { headline: "نبشرك بتأكيد الطلب 😍", message: `ونعمل في هذه اللحظة على ${category === "consult" ? "تنسيق موعد جلستك" : "تجهيز برنامجك"}. سنوافيك بتحديث حالة الطلب قريباً. يومك سعيد ❤️` };
    case "active": return { headline: "برنامجك جاهز 💪", message: "برنامجك صار نشط. ادخل حسابك وابدأ: برنامج التمرين، التغذية، والمراجعة الأسبوعية كلها هناك." };
    case "delivered": return { headline: "ملفاتك جاهزة 🎉", message: "ملفات برنامجك متاحة الآن في حسابك، وهي لك مدى الحياة." };
    case "completed": return category === "follow"
      ? { headline: "انتهى برنامجك 🌱", message: "ولله الحمد انتهى البرنامج، لكن لم تنتهِ رحلتك في التطور النفسي والجسدي. يسعدنا نسمع رأيك من حسابك." }
      : { headline: "شكراً لك 🌱", message: "اكتمل طلبك. يسعدنا نسمع رأيك من حسابك." };
    case "cancelled": return { headline: "تم إلغاء طلبك", message: "إذا تحتاج مساعدة أو كان الإلغاء بالخطأ، تواصل معنا على واتساب." };
    default: return { headline: "تحديث على طلبك", message: "" };
  }
}

const STATUS_WORD: Record<string, string> = {
  awaiting_quote: "بانتظار تأكيد المبلغ", awaiting_payment: "بانتظار الدفع", payment_review: "جارٍ التحقق من الدفع", preparing: "مؤكد",
  active: "نشط", delivered: "تم التسليم", completed: "مكتمل", cancelled: "تم إلغاء الطلب",
};

function stepper(order: EmailOrder) {
  if (order.status === "cancelled") return "";
  const steps = orderSteps(order.status, order.category);
  const cells = steps.map((s, i) => {
    const bg = s.state === "next" ? "#ffffff" : C.ink;
    const fg = s.state === "next" ? C.muted : "#ffffff";
    const border = s.state === "next" ? C.line : C.ink;
    const mark = s.state === "done" ? "✓" : String(i + 1);
    return `<td align="center" valign="top" style="padding:0 2px;width:25%">
      <div style="width:35px;height:35px;line-height:35px;text-align:center;border-radius:50%;background:${bg};color:${fg};border:1.5px solid ${border};font:700 15px/35px ${FONT};margin:0 auto">${mark}</div>
      <div style="font:${s.state === "now" ? 700 : 400} 12px/1.5 ${FONT};color:${s.state === "next" ? C.muted : C.text};margin-top:6px">${esc(s.label)}</div>
    </td>`;
  }).join("");
  return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:${C.paper};border:1px solid ${C.line};border-radius:14px;padding:14px 6px;margin:22px 0 6px"><tr>${cells}</tr></table>`;
}

function summary(order: EmailOrder, link: string) {
  const row = (label: string, value: string) =>
    `<tr><td style="padding:10px 0 2px;font:400 14px ${FONT};color:${C.muted}">${label}</td></tr><tr><td style="padding:0 0 6px;font:500 16px ${FONT};color:${C.text}">${value}</td></tr>`;
  return `
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-top:26px">
    <tr><td style="font:700 20px ${FONT};color:${C.text};padding-bottom:10px;border-bottom:1px solid ${C.line}">🛍️ ملخص طلبك</td></tr>
    ${row("رقم الطلب", `<a href="${esc(link)}" style="color:${C.cyanInk};font-weight:700;text-decoration:underline" dir="ltr">#${esc(order.orderNo)}</a>`)}
    ${row("تاريخ الطلب", esc(fmtOrderDate(order.createdAt)))}
    ${row("طريقة الدفع", `<span style="display:inline-block;background:${C.soft};border-radius:999px;padding:6px 14px;font-size:14px;color:${C.text}">${esc(PAYMENT_LABEL[order.paymentMethod] ?? order.paymentMethod)}</span>`)}
    <tr><td style="padding-top:12px">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border:1px solid ${C.line};border-radius:12px">
        <tr><td style="padding:16px">
          <div style="font:700 17px ${FONT};color:${C.text}">${esc(order.product)}</div>
          <div style="font:500 14px ${FONT};color:${C.muted};margin-top:4px">المدة: ${esc(order.offer)}</div>
          <div style="font:700 16px ${FONT};color:${C.text};margin-top:10px" dir="rtl">${esc(sar(order.amountHalalas))}</div>
        </td></tr>
        <tr><td style="padding:12px 16px;border-top:1px solid ${C.line}">
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr>
            <td style="font:500 15px ${FONT};color:${C.muted}">المبلغ المستحق</td>
            <td align="left" style="font:700 16px ${FONT};color:${C.text}">${esc(sar(order.amountHalalas))}</td>
          </tr></table>
        </td></tr>
      </table>
    </td></tr>
  </table>`;
}

function footer(b: EmailBrand) {
  const icons = [
    b.whatsapp ? `<a href="https://wa.me/${esc(b.whatsapp.replace(/\D/g, ""))}" style="display:inline-block;margin:0 5px"><img src="${esc(b.site)}/email/whatsapp.png" width="40" height="40" alt="واتساب" style="display:block;border:0"></a>` : "",
    b.instagram ? `<a href="${esc(b.instagram)}" style="display:inline-block;margin:0 5px"><img src="${esc(b.site)}/email/instagram.png" width="40" height="40" alt="انستقرام" style="display:block;border:0"></a>` : "",
  ].join("");
  return `
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-top:30px;border-top:1px solid ${C.line}">
    <tr><td align="center" style="padding:26px 10px 6px">
      <img src="${esc(b.site)}/email/logo.png" width="170" alt="Nav Coaching" style="display:block;border:0;height:auto">
    </td></tr>
    <tr><td align="center" style="font:400 14px/1.8 ${FONT};color:${C.muted};padding:6px 10px">
      جميع الحقوق محفوظة لدى ${esc(b.legalName || "Nav Coaching")} | Nav Coaching${b.cr ? `<br>السجل التجاري: <span dir="ltr">${esc(b.cr)}</span>` : ""}
    </td></tr>
    ${icons ? `<tr><td align="center" style="font:400 14px/1.8 ${FONT};color:${C.muted};padding:10px 10px 4px">لتبقى على اطلاع بجديدنا، تابعنا على منصات التواصل الاجتماعي</td></tr>
    <tr><td align="center" style="padding:8px 0 4px">${icons}</td></tr>` : ""}
  </table>`;
}

/** يبني نسخة HTML للبريد. النص العادي (text) يبقى كما هو ويُرسل معها لبرامج البريد التي لا تعرض HTML. */
export function renderEmail(input: EmailInput): string {
  const b = input.brand;
  const o = input.order;
  const link = o ? `${b.site}/account/orders/${o.orderNo}` : input.cta?.url ?? `${b.site}/account`;
  const greeting = input.name?.trim()
    ? `<table role="presentation" align="center" cellpadding="0" cellspacing="0" style="margin:22px auto 0;border:1px solid ${C.line};border-radius:14px"><tr>
        <td style="padding:14px 22px;font:700 16px/1.7 ${FONT};color:${C.text};text-align:center">👤 يا هلا وسهلا ${esc(input.name.trim())}</td></tr></table>`
    : "";
  const statusLine = o
    ? `<p style="margin:18px 0 0;font:400 16px/1.9 ${FONT};color:${C.text};text-align:center">[ Nav Coaching ] أصبحت حالة طلبك
        <a href="${esc(link)}" style="color:${C.cyanInk};font-weight:700;white-space:nowrap" dir="ltr">${esc(o.orderNo)}</a> ${esc(o.status === "completed" && o.category === "follow" ? "انتهى الاشتراك" : STATUS_WORD[o.status] ?? o.status)}</p>`
    : "";
  const code = input.code
    ? `<div style="margin:22px auto 0;text-align:center"><span dir="ltr" style="display:inline-block;background:${C.soft};border:1px dashed ${C.cyanInk};border-radius:14px;padding:14px 26px;font:700 32px/1 'Courier New',monospace;letter-spacing:8px;color:${C.ink}">${esc(input.code)}</span></div>`
    : "";
  const cta = input.cta ?? (o ? { label: "عرض طلبك", url: link } : null);
  const button = cta
    ? `<table role="presentation" align="center" cellpadding="0" cellspacing="0" style="margin:22px auto 0"><tr><td style="border-radius:999px;background:${C.navy}">
        <a href="${esc(cta.url)}" style="display:inline-block;padding:13px 30px;font:700 16px ${FONT};color:#ffffff;text-decoration:none;border-radius:999px">${esc(cta.label)}</a></td></tr></table>`
    : "";
  return `<!doctype html>
<html lang="ar" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light only"><title>${esc(input.headline)}</title></head>
<body style="margin:0;padding:0;background:${C.paper}" dir="rtl">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:${C.paper}"><tr><td align="center" style="padding:20px 10px">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#ffffff;border-radius:18px;border:1px solid ${C.line}" dir="rtl">
    <tr><td style="padding:26px 22px 24px">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:${C.soft};border-radius:16px"><tr>
        <td align="center" style="padding:16px 12px">
          <table role="presentation" cellpadding="0" cellspacing="0"><tr>
            <td style="font:700 15px ${FONT};color:${C.text};padding-left:12px">${esc(input.kicker ?? "شكراً لاختيارك")}</td>
            <td><img src="${esc(b.site)}/email/logo.png" width="130" alt="Nav Coaching" style="display:block;border:0;height:auto"></td>
          </tr></table>
        </td></tr></table>
      ${greeting}
      <h1 style="margin:24px 0 0;font:800 30px/1.45 ${FONT};color:${C.text};text-align:center">${esc(input.headline)}</h1>
      ${input.message ? `<p style="margin:12px auto 0;max-width:420px;font:400 16px/2 ${FONT};color:${C.muted};text-align:center">${nl2br(input.message)}</p>` : ""}
      ${code}
      ${statusLine}
      ${o ? stepper(o) : ""}
      ${button}
      ${o ? summary(o, link) : ""}
      ${footer(b)}
    </td></tr>
  </table>
</td></tr></table>
</body></html>`;
}
