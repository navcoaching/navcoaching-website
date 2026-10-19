import type { Metadata } from "next";
import { Client } from "pg";
import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import { dbInfoFromUrl, median, regionName, verdict, normRegion } from "@/lib/speed";
import BrowserTiming from "./BrowserTiming";

export const metadata: Metadata = { title: "فحص السرعة" };
export const dynamic = "force-dynamic";

// وقت تشغيل نسخة الخادم الحالية: إذا كانت جديدة جداً فهذا الطلب كان «تشغيلاً بارداً»
const STARTED = Date.now();
const ms = (v: number | null) => (v == null ? "—" : `${v < 10 ? v.toFixed(1) : Math.round(v)} مللي ثانية`);

/** يقيس اتصالاً جديداً تماماً بالقاعدة (مثل أول طلب بعد خمول) ثم يغلقه */
async function freshConnect(): Promise<number | null> {
  const c = new Client({
    connectionString: process.env.DATABASE_URL,
    ssl: process.env.DATABASE_SSL === "true" ? { rejectUnauthorized: true } : undefined,
    connectionTimeoutMillis: 10_000,
  });
  const t = performance.now();
  try {
    await c.connect();
    await c.query("SELECT 1");
    return performance.now() - t;
  } catch {
    return null;
  } finally {
    await c.end().catch(() => {});
  }
}

export default async function AdminSpeed() {
  const t0 = performance.now();
  const coach = await requireCoach();
  const auth = performance.now() - t0;

  const fresh = await freshConnect();
  const { rtts, page } = await withUser(coach.id, async (tx) => {
    const rtts: number[] = [];
    for (let i = 0; i < 5; i++) {
      const t = performance.now();
      await tx.query("SELECT 1");
      rtts.push(performance.now() - t);
    }
    // ثلاث قراءات حقيقية متتالية مثل صفحة إدارة عادية
    const t = performance.now();
    await tx.query("SELECT count(*) FROM orders");
    await tx.query("SELECT count(*) FROM check_ins");
    await tx.query("SELECT count(*) FROM \"user\"");
    return { rtts, page: performance.now() - t };
  });

  const rtt = median(rtts);
  const fnRegion = process.env.AWS_REGION ?? null;
  const db = dbInfoFromUrl(process.env.DATABASE_URL);
  const verdicts = verdict(fnRegion, db, rtt);
  const uptime = (Date.now() - STARTED) / 1000;
  const total = performance.now() - t0;

  const rows: [string, string, string][] = [
    ["منطقة الخادم (دوال Netlify)", regionName(normRegion(fnRegion)), "speed-fn-region"],
    ["منطقة قاعدة البيانات (Neon)", regionName(db.region), "speed-db-region"],
    ["رابط القاعدة مجمّع (pooler)؟", db.neon ? (db.pooled ? "نعم" : "لا") : "—", "speed-pooled"],
    ["رحلة واحدة للقاعدة (المتوسط من 5)", ms(rtt), "speed-rtt"],
    ["اتصال جديد بالقاعدة (أول طلب بعد خمول)", ms(fresh), "speed-fresh"],
    ["3 استعلامات متتالية (مثل صفحة عادية)", ms(page), "speed-page"],
    ["التحقق من الدخول", ms(auth), "speed-auth"],
    ["مجموع وقت الخادم لهذي الصفحة", ms(total), "speed-total"],
    ["عمر نسخة الخادم", uptime < 30 ? `${Math.round(uptime)} ثانية (تشغيل بارد: الطلب هذا انتظر تشغيل الخادم)` : `${Math.round(uptime / 60)} دقيقة`, "speed-uptime"],
  ];

  return (
    <div className="stack" style={{ ["--space" as string]: "18px" }}>
      <h1>فحص السرعة</h1>
      <p className="muted small">كل مرة تفتحين الصفحة أو تحدّثينها يُعاد القياس. حدّثيها 2–3 مرات وخذي آخر نتيجة، لأن أول فتح بعد خمول يكون أبطأ.</p>
      <section className="stack" data-testid="speed-verdicts" style={{ ["--space" as string]: "8px" }}>
        {verdicts.map((v, i) => <p key={i} className={`alert ${v.tone === "ok" ? "ok" : v.tone === "warn" ? "warn" : "err"}`}>{v.text}</p>)}
      </section>
      <section className="card speed-list" data-testid="speed-table">
        {rows.map(([k, v, id]) => <div key={id} className="speed-row"><span>{k}</span><b data-testid={id}>{v}</b></div>)}
        <BrowserTiming />
      </section>
      <details className="card">
        <summary><b>كيف أغيّر منطقة الخادم في Netlify؟</b></summary>
        <ol className="small" style={{ lineHeight: 1.9 }}>
          <li>Netlify ← موقعك ← <b>Project configuration</b> (أو Site configuration).</li>
          <li><b>Build &amp; deploy</b> ← <b>Continuous deployment</b> ← <b>Functions region</b> ← <b>Configure</b>.</li>
          <li>اختاري نفس منطقة القاعدة، مثلاً <b>EU (Frankfurt) · fra / eu-central-1</b>، واحفظي.</li>
          <li><b>Deploys</b> ← <b>Trigger deploy</b> ← <b>Deploy site</b>. التغيير ما يطبق إلا على النشر الجديد.</li>
          <li>ارجعي لهذي الصفحة: المفروض تصير المنطقتين نفس الشي، والرحلة الواحدة أقل من 10 مللي ثانية.</li>
        </ol>
      </details>
    </div>
  );
}
