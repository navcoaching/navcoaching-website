/** حساب تيك توك الافتراضي: يظهر حتى لو ما حُفظ في الإعدادات بعد، وإذا مسحته المدربة (نص فاضي) يختفي */
export const DEFAULT_TIKTOK = "https://www.tiktok.com/@navcoaching";
export const withTiktok = <T extends { tiktok?: string }>(c: T): T & { tiktok: string } => ({ ...c, tiktok: c.tiktok ?? DEFAULT_TIKTOK });
export const TIKTOK_RE = /^https:\/\/(www\.)?tiktok\.com\/@[\w.]{2,24}\/?$/;
