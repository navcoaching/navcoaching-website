// وصف صفحة الباقة لنتائج البحث (meta description): جملة كاملة من «لمن تناسب» + أهم ما تشمله + السعر، بحدود ~155 حرفاً.
type P = { name: string; audience: string; category: string; items: { text: string; included: boolean }[]; offers: { price_halalas: number; active: boolean }[] };
const KIND: Record<string, string> = { follow: "باقة متابعة تدريب وتغذية", files: "جداول تدريب وتغذية جاهزة", consult: "استشارة تدريب وتغذية" };
export const META_MAX = 155;

const clean = (t: string) => t.replace(/\s+/g, " ").replace(/[.,،\s]+$/g, "").trim();
const cut = (t: string, max: number) => {
  if (t.length <= max) return t;
  const c = t.slice(0, max - 1);
  return `${c.slice(0, Math.max(c.lastIndexOf(" "), 20)).trim()}…`;
};

const KIND_EN: Record<string, string> = { follow: "training and nutrition coaching plan", files: "ready-made training and nutrition plans", consult: "training and nutrition consultation" };
export function productDescription(p: P, lang: "ar" | "en" = "ar"): string {
  const price = Math.min(...p.offers.filter((o) => o.active).map((o) => o.price_halalas));
  const priceN = Math.round(price / 100).toLocaleString("en-US");
  const priceTxt = Number.isFinite(price) ? (lang === "en" ? `From SAR ${priceN}.` : `تبدأ من ${priceN} ريال.`) : "";
  const aud = clean(p.audience);
  // «لمن تناسب» نص حر من لوحة الإدارة، فنضعه بعد «لمن تناسب:» بدل دمجه نحوياً في جملة
  const lead = lang === "en"
    ? `${p.name}: ${KIND_EN[p.category] ?? "program with Coach Sara"}${aud ? `. For: ${aud}` : ""}.`
    : `${p.name}: ${KIND[p.category] ?? "برنامج مع الكوتش ساره"}${aud ? `. لمن تناسب: ${aud.replace(/^(لـ?|تناسب\s+)/, "")}` : ""}.`;
  const inc = p.items.filter((i) => i.included).slice(0, 2).map((i) => clean(i.text)).filter(Boolean).join(lang === "en" ? ", " : "، ");
  const mid = inc ? (lang === "en" ? `Includes ${inc}.` : `تشمل ${inc}.`) : "";
  const full = [lead, mid, priceTxt].filter(Boolean).join(" ");
  if (full.length <= META_MAX) return full;
  // نختصر الوسط أولاً ثم نقص التعريف إن لزم، ونحتفظ بالسعر
  const short = [lead, priceTxt].filter(Boolean).join(" ");
  return short.length <= META_MAX ? short : `${cut(lead, META_MAX - priceTxt.length - 1)} ${priceTxt}`.trim();
}
