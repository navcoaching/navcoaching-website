export const riyals = (halalas: number | null | undefined) => {
  if (halalas == null) return "—";
  const v = halalas / 100;
  return `${v.toLocaleString("en-US", { maximumFractionDigits: 2 })} ر.س`;
};

const dateFmt = new Intl.DateTimeFormat("ar-SA-u-ca-gregory-nu-latn", {
  timeZone: "Asia/Riyadh",
  day: "numeric",
  month: "long",
  year: "numeric",
});
const dateTimeFmt = new Intl.DateTimeFormat("ar-SA-u-ca-gregory-nu-latn", {
  timeZone: "Asia/Riyadh",
  day: "numeric",
  month: "short",
  hour: "numeric",
  minute: "2-digit",
});

export const fmtDate = (d: Date | string) => dateFmt.format(new Date(d));
const dayMonthFmt = new Intl.DateTimeFormat("ar-SA-u-ca-gregory-nu-latn", { timeZone: "UTC", day: "numeric", month: "long" });
/** تاريخ بصيغة YYYY-MM-DD بدون اسم اليوم: «5 أكتوبر» */
export const fmtDayMonth = (ymd: string) => dayMonthFmt.format(new Date(`${ymd.slice(0, 10)}T12:00:00Z`));
export const fmtDateTime = (d: Date | string) => dateTimeFmt.format(new Date(d));

export const CATEGORY_LABEL: Record<string, string> = {
  follow: "مع متابعة",
  files: "ملفات بدون متابعة",
  consult: "استشارات",
};

export function shortName(name: string) {
  return name.replace(/^الباقة\s+/, "").replace(/^باقة\s+/, "");
}

export function waLink(number: string, text?: string) {
  return `https://wa.me/${number}${text ? `?text=${encodeURIComponent(text)}` : ""}`;
}

/** عرض محلي لرقم واتساب السعودي: 966599162724 ← 0599162724 */
export function localPhone(international: string) {
  return international.startsWith("966") ? `0${international.slice(3)}` : `+${international}`;
}

const dayFmt = new Intl.DateTimeFormat("ar-SA-u-ca-gregory-nu-latn", { timeZone: "UTC", weekday: "long", day: "numeric", month: "long" });
/** تاريخ بصيغة YYYY-MM-DD مع اسم اليوم: «الخميس 9 أكتوبر» */
export const fmtDay = (ymd: string) => dayFmt.format(new Date(`${ymd.slice(0, 10)}T12:00:00Z`));
