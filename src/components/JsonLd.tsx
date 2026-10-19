/** بيانات منظّمة (schema.org) لمحركات البحث. `<` تُهرَّب حتى لا يُغلق النص وسم السكربت. */
export default function JsonLd({ data }: { data: Record<string, unknown> }) {
  return <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: JSON.stringify(data).replace(/</g, "\\u003c") }} />;
}

export const siteUrl = () => process.env.NEXT_PUBLIC_SITE_URL ?? "http://localhost:3000";
/** نص عادي من نص الأسئلة (يزيل ** و[رابط](…)) */
export const plain = (t: string) => t.replace(/\*\*/g, "").replace(/\[([^\]]+)\]\([^)]*\)/g, "$1").replace(/\s+/g, " ").trim();
