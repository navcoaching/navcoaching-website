import type { Lang } from "./lang";

export const riyals = (halalas: number | null | undefined, lang: Lang = "ar") => {
  if (halalas == null) return "—";
  const v = halalas / 100;
  const n = v.toLocaleString("en-US", { maximumFractionDigits: 2 });
  return lang === "en" ? `SAR ${n}` : `${n} ر.س`;
};
/** الرقم بلا عملة (للعرض الكبير بجانب رمز العملة) */
export const priceNum = (text: string) => text.replace(/\s*ر\.س|SAR\s*/g, "");
export const CURRENCY: Record<Lang, string> = { ar: "ر.س", en: "SAR" };
/** تسمية مدة العرض باللغة: «شهر واحد»/«1 month»، «3 أشهر»/«3 months»، «دفعة واحدة»/«One-time» */
export const offerLabel = (o: { label: string; months: number }, lang: Lang) =>
  lang === "ar" ? o.label : o.months === 0 ? "One-time" : o.months === 1 ? "1 month" : `${o.months} months`;

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

const dateFmtEn = new Intl.DateTimeFormat("en-GB", { timeZone: "Asia/Riyadh", day: "numeric", month: "long", year: "numeric" });
export const fmtDate = (d: Date | string, lang: Lang = "ar") => (lang === "en" ? dateFmtEn : dateFmt).format(new Date(d));
const dayMonthFmt = new Intl.DateTimeFormat("ar-SA-u-ca-gregory-nu-latn", { timeZone: "UTC", day: "numeric", month: "long" });
/** تاريخ بصيغة YYYY-MM-DD بدون اسم اليوم: «5 أكتوبر» */
export const fmtDayMonth = (ymd: string) => dayMonthFmt.format(new Date(`${ymd.slice(0, 10)}T12:00:00Z`));
export const fmtDateTime = (d: Date | string) => dateTimeFmt.format(new Date(d));

export const CATEGORY_LABEL: Record<string, string> = {
  follow: "مع متابعة",
  files: "ملفات بدون متابعة",
  consult: "استشارات",
};
const CATEGORY_LABEL_EN: Record<string, string> = { follow: "With follow-up", files: "Plans without follow-up", consult: "Consultations" };
export const categoryLabel = (c: string, lang: Lang) => (lang === "en" ? CATEGORY_LABEL_EN[c] ?? c : CATEGORY_LABEL[c] ?? c);

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

/** رسالة واتساب جاهزة مرتبة الأسطر (النص المعتمد من المدربة). القيم بين الأقواس يكملها العميل */
export function waIntro(pkg?: string | null) {
  return ["السلام عليكم كوتش ساره", `الباقة: [${pkg ?? " "}]`, "الهدف: [ ]", "المدينة: [ ]", "الاسم: [ ]"].join("\n");
}
