/** اللغات المدعومة. العربية بلا بادئة في الرابط (/programs)، والإنجليزية تحت /en (/en/programs). */
export const LANGS = ["ar", "en"] as const;
export type Lang = (typeof LANGS)[number];
export const isLang = (v: string): v is Lang => (LANGS as readonly string[]).includes(v);
export const dirOf = (lang: Lang) => (lang === "en" ? "ltr" : "rtl");
/** رابط داخلي بلغة الصفحة: href("en", "/programs") → /en/programs */
export const href = (lang: Lang, path: string) => (lang === "en" ? `/en${path === "/" ? "" : path}` || "/en" : path);
/** لغة الصفحة من مسار المتصفح (للمكونات في المتصفح) */
export const langOfPath = (path: string | null): Lang => (path === "/en" || path?.startsWith("/en/") ? "en" : "ar");
/** المسار نفسه باللغة الأخرى */
export const switchPath = (path: string, to: Lang) => {
  const bare = path === "/en" ? "/" : path.startsWith("/en/") ? path.slice(3) : path;
  return href(to, bare);
};
