// يستورد المحتوى الحقيقي من الموقع الحالي إلى قاعدة البيانات (آمن للتكرار):
//   المنتجات والأسعار ← db/seed/source/catalog.json
//   التواصل والحساب البنكي والتقييمات المنشورة ← db/seed/source/site.json
//   النصوص والأسئلة الشائعة والسياسات ← db/seed/content.json
// الإعدادات والأسئلة والسياسات لا تُستبدل إذا كانت موجودة (حتى لا تضيع تعديلات لوحة الإدارة)، إلا مع --force.
import { readFile } from "node:fs/promises";
import pg from "pg";
import { loadEnv } from "./env.mjs";

loadEnv();
const force = process.argv.includes("--force");
const read = async (p) => JSON.parse(await readFile(new URL(p, import.meta.url), "utf8"));
const catalog = await read("../db/seed/source/catalog.json");
const site = await read("../db/seed/source/site.json");
const content = await read("../db/seed/content.json");

const SLUGS = {
  int: "intensive", adv: "advanced", bas: "basic", nut: "nutrition",
  diy: "custom-training-plan", diyN: "training-nutrition-plan",
  cN: "nutrition-consultation", cT: "training-consultation",
};

// حقول صفحة المنتج — مأخوذة من نصوص الموقع الحالي (الأسئلة الشائعة، الشروط، كيف أشترك، الاختبار).
const REQ = "تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.";
const DETAILS = {
  follow: {
    delivery: "ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.",
    policy: "الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.",
  },
  files: {
    delivery: "جدول مخصص بعد الاستبيان تستلمه كملف، وتقدر تحمّله على جهازك. بدون متابعة.",
    policy: "الدفع مرة واحدة بتحويل بنكي. الجداول لك مدى الحياة وتقدر تعدّل عليها.",
  },
  consult: {
    delivery: "جلسة عبر Google Meet أو واتساب — المناسب لك.",
    policy: "الدفع مرة واحدة بتحويل بنكي.",
  },
};
const POLICY_OVERRIDE = {
  nut: "الدفع مرة واحدة بتحويل بنكي، ولا يوجد تجديد تلقائي. ضمان الاسترجاع يشمل اشتراكات 3 أشهر للمكثفة والمتقدمة والأساسية فقط.",
};
const AUDIENCE_OVERRIDE = {
  cN: "لمن عنده أسئلة محددة في التغذية: جلسة وحدة تكفي لحسبة سعراتك ونصائح الأكل.",
  cT: "لمن عنده أسئلة محددة في التمرين: جلسة وحدة تكفي لتعديل جدولك وتصحيح التكنيك.",
};

const db = new pg.Client({ connectionString: process.env.DATABASE_URL_OWNER, ssl: process.env.DATABASE_SSL === "true" ? { rejectUnauthorized: true } : undefined });
await db.connect();
try {
  await db.query("BEGIN");

  // ---------- المنتجات ----------
  let sort = 0;
  for (const p of catalog.packages) {
    const slug = SLUGS[p.id] ?? p.id.toLowerCase();
    const d = DETAILS[p.group];
    const { rows: [prod] } = await db.query(
      `INSERT INTO products (slug, category, name, audience, items, note, delivery, requirements, policy_note, recommended, status, sort)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,'published',$11)
       ON CONFLICT (slug) DO UPDATE SET category=EXCLUDED.category, name=EXCLUDED.name, audience=EXCLUDED.audience,
         items=EXCLUDED.items, note=EXCLUDED.note, recommended=EXCLUDED.recommended, sort=EXCLUDED.sort, updated_at=now()
         ${force ? ", delivery=EXCLUDED.delivery, requirements=EXCLUDED.requirements, policy_note=EXCLUDED.policy_note" : ""}
       RETURNING id`,
      [slug, p.group, p.name, AUDIENCE_OVERRIDE[p.id] ?? p.for, JSON.stringify(p.items.map(([text, ok]) => ({ text, included: Boolean(ok) }))),
       p.note || null, d.delivery, REQ, POLICY_OVERRIDE[p.id] ?? d.policy, Boolean(p.recommended), sort++],
    );
    let os = 0;
    for (const o of p.offers) {
      await db.query(
        `INSERT INTO product_offers (product_id, sku, label, months, price_halalas, currency, sort)
         VALUES ($1,$2,$3,$4,$5,$6,$7)
         ON CONFLICT (sku) DO UPDATE SET label=EXCLUDED.label, months=EXCLUDED.months, price_halalas=EXCLUDED.price_halalas, sort=EXCLUDED.sort`,
        [prod.id, o.sku, o.label, o.months, Math.round(o.price * 100), catalog.currency, os++],
      );
    }
  }

  // ---------- الإعدادات ----------
  const settings = {
    ...content.settings,
    contact: { whatsapp: site.whatsapp, instagram: site.instagram },
    response_time: site.responseTime,
    legal: { name: site.legalName, cr: site.crNumber },
    bank: site.bank,
    program_shots: site.programShots,
  };
  for (const [key, value] of Object.entries(settings)) {
    const clean = JSON.parse(JSON.stringify(value, (k, v) => (k.startsWith("_") ? undefined : v)));
    await db.query(
      `INSERT INTO site_settings (key, value) VALUES ($1, $2)
       ON CONFLICT (key) DO ${force ? "UPDATE SET value = EXCLUDED.value, updated_at = now()" : "NOTHING"}`,
      [key, JSON.stringify(clean)],
    );
  }

  // ---------- الأسئلة الشائعة والسياسات ----------
  const { rows: [{ n: faqCount }] } = await db.query("SELECT count(*)::int AS n FROM faqs");
  if (force || faqCount === 0) {
    await db.query("DELETE FROM faqs");
    for (const [i, f] of content.faqs.entries()) {
      await db.query("INSERT INTO faqs (question, answer, sort) VALUES ($1,$2,$3)", [f.q, f.a, i]);
    }
  }
  for (const [i, p] of content.policies.entries()) {
    await db.query(
      `INSERT INTO policies (slug, title, body, sort) VALUES ($1,$2,$3,$4)
       ON CONFLICT (slug) DO ${force ? "UPDATE SET title=EXCLUDED.title, body=EXCLUDED.body, sort=EXCLUDED.sort, updated_at=now()" : "NOTHING"}`,
      [p.slug, p.title, p.body, i],
    );
  }

  // ---------- التقييمات المنشورة حالياً (موافقة أصحابها مذكورة في README الموقع الحالي) ----------
  const { rows: [{ n: legacyCount }] } = await db.query("SELECT count(*)::int AS n FROM reviews WHERE source = 'legacy'");
  if (legacyCount === 0) {
    for (const [i, t] of site.testimonials.entries()) {
      await db.query(
        `INSERT INTO reviews (source, rating, body, display_mode, display_name, period_label, consent_publish, status, sort)
         VALUES ('legacy', $1, $2, 'first', $3, $4, true, 'published', $5)`,
        [t.stars || null, t.quote, t.name, t.period, i],
      );
    }
  }

  await db.query("COMMIT");
  console.log(`✓ استيراد: ${catalog.packages.length} منتجات، ${content.faqs.length} أسئلة، ${content.policies.length} سياسات، ${site.testimonials.length} تقييمات سابقة`);
} catch (err) {
  await db.query("ROLLBACK");
  throw err;
} finally {
  await db.end();
}
