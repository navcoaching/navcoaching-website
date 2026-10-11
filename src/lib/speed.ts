// منطق صفحة «فحص السرعة» (خالص، بدون اتصال): قراءة منطقة القاعدة من رابط الاتصال ومقارنتها بمنطقة الخادم.
// لا يرجع أبداً كلمة السر ولا اسم المضيف كاملاً، فقط المنطقة وهل الاتصال مجمّع (pooler).

export type DbInfo = { region: string | null; pooled: boolean; neon: boolean };

/** يستخرج منطقة Neon من رابط الاتصال، مثل ep-x-pooler.eu-central-1.aws.neon.tech ← eu-central-1 */
export function dbInfoFromUrl(url: string | undefined | null): DbInfo {
  let host = "";
  try { host = new URL(url ?? "").hostname.toLowerCase(); } catch { /* رابط غير صالح */ }
  const neon = host.endsWith(".neon.tech");
  const m = host.match(/\.([a-z]{2}-[a-z]+-\d)\.aws\.neon\.tech$/);
  return { region: m?.[1] ?? null, pooled: host.split(".")[0]?.endsWith("-pooler") ?? false, neon };
}

// رموز مناطق Netlify الحديثة (رمز المطار) ← منطقة AWS المقابلة
const NETLIFY_CODES: Record<string, string> = { fra: "eu-central-1", lhr: "eu-west-2", dub: "eu-west-1", iad: "us-east-1", cmh: "us-east-2", pdx: "us-west-2", sfo: "us-west-1", cdg: "eu-west-3", gru: "sa-east-1", syd: "ap-southeast-2", sin: "ap-southeast-1", nrt: "ap-northeast-1", bom: "ap-south-1", yul: "ca-central-1" };
export const normRegion = (r: string | null | undefined) => (r ? NETLIFY_CODES[r.toLowerCase()] ?? r.toLowerCase() : null);

const NAMES: Record<string, string> = {
  "eu-central-1": "فرانكفورت (ألمانيا)", "eu-west-1": "دبلن (أيرلندا)", "eu-west-2": "لندن", "eu-west-3": "باريس",
  "us-east-1": "فرجينيا (أمريكا)", "us-east-2": "أوهايو (أمريكا)", "us-west-1": "كاليفورنيا (أمريكا)", "us-west-2": "أوريغون (أمريكا)",
  "me-south-1": "البحرين", "me-central-1": "الإمارات", "ap-south-1": "مومباي", "ap-southeast-1": "سنغافورة",
};
export const regionName = (r: string | null) => (r ? `${NAMES[r] ?? r} · ${r}` : "غير معروفة");

export type Verdict = { tone: "ok" | "warn" | "bad"; text: string };

/** الحكم النهائي من المنطقتين وزمن الرحلة الواحدة للقاعدة (بالمللي ثانية) */
export function verdict(fnRegion: string | null, db: DbInfo, rttMs: number | null): Verdict[] {
  const out: Verdict[] = [];
  const fn = normRegion(fnRegion);
  if (fn && db.region && fn !== db.region) {
    out.push({ tone: "bad", text: `الخادم في ${regionName(fn)} والقاعدة في ${regionName(db.region)}: كل استعلام يقطع هذي المسافة رايح وراجع. هذا أكبر سبب للبطء، والحل تغيير منطقة دوال Netlify إلى نفس منطقة القاعدة.` });
  } else if (fn && db.region) {
    out.push({ tone: "ok", text: "الخادم والقاعدة في نفس المنطقة ✅" });
  } else {
    out.push({ tone: "warn", text: "ما قدرت أحدد إحدى المنطقتين (يحدث في بيئة التطوير). قارنيها يدوياً من إعدادات Netlify وNeon." });
  }
  if (db.neon && !db.pooled) out.push({ tone: "warn", text: "رابط القاعدة ليس المجمّع (pooler). خذي من Neon الرابط اللي فيه ‎-pooler وضعيه في DATABASE_URL في Netlify." });
  if (rttMs != null) {
    const r = rttMs < 10 ? rttMs.toFixed(1) : String(Math.round(rttMs));
    if (rttMs > 60) out.push({ tone: "bad", text: `الرحلة الواحدة للقاعدة ${r} مللي ثانية. المفروض أقل من 10 إذا كانا في نفس المنطقة.` });
    else if (rttMs > 15) out.push({ tone: "warn", text: `الرحلة الواحدة للقاعدة ${r} مللي ثانية: مقبولة لكن أعلى من المثالي (أقل من 10).` });
    else out.push({ tone: "ok", text: `الرحلة الواحدة للقاعدة ${r} مللي ثانية: ممتازة.` });
  }
  return out;
}

export const median = (xs: number[]) => {
  if (!xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  return s.length % 2 ? s[(s.length - 1) / 2] : (s[s.length / 2 - 1] + s[s.length / 2]) / 2;
};
