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
