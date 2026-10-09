// يولّد صور «الدليل المصوّر» (public/guide/*.png) ومواقع الأرقام (src/lib/guide-shots.json) من صفحات الموقع ببيانات تجريبية.
// لا يعمل في الاختبارات العادية. التشغيل: GUIDE_SHOTS=1 npx playwright test zz-guide-shots --project=iphone
import { test, type Page, type Locator } from "@playwright/test";
import pg from "pg";
import fs from "node:fs";
import path from "node:path";

const OWNER = process.env.E2E_DATABASE_URL_OWNER ?? "postgres://nav_owner:nav_owner_dev@localhost:5432/nav_e2e";
const OUT_IMG = path.join(process.cwd(), "public/guide");
const OUT_JSON = path.join(process.cwd(), "src/lib/guide-shots.json");

test.skip(!process.env.GUIDE_SHOTS, "يُشغَّل يدوياً لتحديث صور الدليل");

type Box = { x: number; y: number; w: number; h: number };
const shots: Record<string, { w: number; h: number; markers: Record<string, Box> }> = {};

async function rect(l: Locator) {
  const b = await l.first().evaluate((el) => { const r = el.getBoundingClientRect(); return { x: r.left + scrollX, y: r.top + scrollY, w: r.width, h: r.height }; });
  if (!b.w || !b.h) throw new Error(`marker not visible: ${l}`);
  return b;
}

/** صورة لجزء من الصفحة من أعلى `from` إلى أسفل `to`، بعرض الصفحة كاملة، مع أرقام على العناصر */
async function capture(page: Page, key: string, from: Locator, to: Locator, markers: Locator[], maxH = 2000) {
  await page.evaluate(() => document.fonts.ready);
  const a = await rect(from), z = await rect(to);
  const pad = 10;
  const width = await page.evaluate(() => document.documentElement.clientWidth);
  const top = Math.max(0, a.y - pad);
  const clip = { x: 0, y: top, width, height: Math.min(maxH, z.y + z.h + pad - top) };
  const boxes: Record<string, Box> = {};
  for (const [i, m] of markers.entries()) {
    const b = await rect(m);
    const y1 = Math.max(b.y - 3, clip.y), y2 = Math.min(b.y + b.h + 3, clip.y + clip.height);
    const x1 = Math.max(b.x - 3, 1), x2 = Math.min(b.x + b.w + 3, width - 1);
    const pct = (v: number, d: number) => Math.round(v * 10000 / d) / 100;
    boxes[String(i + 1)] = { x: pct(x1, width), y: pct(y1 - clip.y, clip.height), w: pct(x2 - x1, width), h: pct(y2 - y1, clip.height) };
  }
  await page.screenshot({ path: path.join(OUT_IMG, `${key}.png`), clip, fullPage: true, animations: "disabled" });
  shots[key] = { w: Math.round(clip.width), h: Math.round(clip.height), markers: boxes };
}

test("صور الدليل المصوّر", async ({ browser }) => {
  test.setTimeout(180_000);
  const db = new pg.Pool({ connectionString: OWNER, max: 2 });
  fs.mkdirSync(OUT_IMG, { recursive: true });
  const email = `guide-${Date.now()}@e2e.test`;
  const ctx = await browser.newContext({ ...test.info().project.use, viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, extraHTTPHeaders: { "x-forwarded-for": "10.99.1.1" } });
  const page = await ctx.newPage();

  await page.goto(`/login?next=/account`);
  await page.getByLabel("البريد الإلكتروني").fill(email);
  await page.getByRole("button", { name: "أرسل رمز الدخول" }).click();
  let code = "";
  for (let i = 0; i < 20 && !code; i++) {
    const { rows } = await db.query("SELECT body FROM dev_mailbox WHERE recipient = $1 AND subject LIKE 'رمز الدخول%' ORDER BY id DESC LIMIT 1", [email]);
    code = rows[0]?.body.match(/رمز الدخول: (\d{6})/)?.[1] ?? "";
    if (!code) await new Promise((r) => setTimeout(r, 250));
  }
  await page.getByLabel("رمز الدخول").fill(code);
  await page.getByRole("button", { name: "دخول" }).click();
  await page.waitForURL((u) => !u.pathname.startsWith("/login"));

  // ---------- بيانات تجريبية ----------
  const q = (sql: string, args: unknown[] = []) => db.query(sql, args);
  const { rows: [u] } = await q(`UPDATE "user" SET name = 'نورة' WHERE email = $1 RETURNING id`, [email]);
  const { rows: [p] } = await q(`SELECT p.id, p.name, o.id AS offer_id, o.label, o.price_halalas FROM products p JOIN product_offers o ON o.product_id = p.id WHERE p.slug = 'intensive' AND o.months = 3`);
  const orderNo = (await q("SELECT app.new_order_no() AS no")).rows[0].no as string;
  const { rows: [o] } = await q(
    `INSERT INTO orders (order_no, user_id, product_id, offer_id, category, product_name, offer_label, months, list_price_halalas, amount_due_halalas, status,
                         contact_name, contact_phone, idempotency_key, paid_at, sub_start_at, sub_end_at, review_weekday)
     VALUES ($1,$2,$3,$4,'follow',$5,$6,3,$7,$7,'active','نورة','+966500000000',$1, now() - interval '14 days',
             now() - interval '14 days', now() + interval '76 days', extract(dow FROM (now() AT TIME ZONE 'Asia/Riyadh'))::int) RETURNING id`,
    [orderNo, u.id, p.id, p.offer_id, p.name, p.label, p.price_halalas]);
  const { rows: [b] } = await q(`INSERT INTO blocks (order_id, user_id, name, start_date, weeks) VALUES ($1,$2,'Block 1',(now() AT TIME ZONE 'Asia/Riyadh')::date - 10,4) RETURNING id`, [o.id, u.id]);
  const exs = (await q(`SELECT id, name FROM exercises WHERE status = 'approved' AND video_url IS NOT NULL AND instructions IS NOT NULL AND split_part(primary_muscle, ' ', 1) IN ('Quadriceps','Glutes','Hamstrings') ORDER BY name LIMIT 4`)).rows;
  const up = (await q(`SELECT id, name FROM exercises WHERE status = 'approved' AND video_url IS NOT NULL AND split_part(primary_muscle, ' ', 1) IN ('Back','Chest') ORDER BY name LIMIT 4`)).rows;
  const plan = JSON.stringify(Array(4).fill({ sets: 3, reps: [10, 10, 10], rir: 2 }));
  const days: { id: string; items: string[] }[] = [];
  for (const [n, title, list] of [[1, "DAY 1 — LOWER", exs], [2, "DAY 2 — UPPER", up]] as const) {
    const { rows: [d] } = await q(`INSERT INTO block_days (block_id, day_no, title) VALUES ($1,$2,$3) RETURNING id`, [b.id, n, title]);
    const items: string[] = [];
    for (const [i, e] of list.entries()) items.push((await q(`INSERT INTO block_items (day_id, position, exercise_id, coach_exercise_id, plan) VALUES ($1,$2,$3,$3,$4) RETURNING id`, [d.id, i + 1, e.id, plan])).rows[0].id);
    days.push({ id: d.id, items });
  }
  // الأسبوع 1 كامل، والأسبوع 2: أول تمرين (مثال الدليل: 20 كغ، 10-10-9، RIR 2)
  for (const d of days) for (const [i, it] of d.items.entries()) {
    await q(`INSERT INTO item_logs (block_item_id, week_no, exercise_id, weight, reps, rir, logged_at) SELECT $1, 1, exercise_id, $2, '{10,10,10}', 2, now() - interval '8 days' FROM block_items WHERE id = $1`, [it, 15 + i * 5]);
  }
  await q(`INSERT INTO item_logs (block_item_id, week_no, exercise_id, weight, reps, rir) SELECT $1, 2, exercise_id, 20, '{10,10,9}', 2 FROM block_items WHERE id = $1`, [days[0].items[0]]);
  await q(`INSERT INTO day_ratings (block_day_id, week_no, rating) VALUES ($1, 1, 4), ($2, 1, 5)`, [days[0].id, days[1].id]);
  for (const [ago, kg] of [[13, 68.4], [11, 68.1], [9, 67.9], [6, 67.6], [4, 67.5], [2, 67.2], [0, 67.0]] as const) {
    await q(`INSERT INTO weight_logs (user_id, logged_on, kg) VALUES ($1, (now() AT TIME ZONE 'Asia/Riyadh')::date - $2::int, $3)`, [u.id, ago, kg]);
  }
  for (const [ago, w, h, c, t] of [[14, 78, 102, 92, 60], [7, 77, 101.5, 91.5, 59.5], [0, 76, 100.5, 91, 59]] as const) {
    await q(`INSERT INTO body_measurements (user_id, measured_on, chest, waist, hips, thigh) VALUES ($1, (now() AT TIME ZONE 'Asia/Riyadh')::date - $2::int, $3, $4, $5, $6)`, [u.id, ago, c, w, h, t]);
  }
  await q(`INSERT INTO step_logs (block_id, week_no, total) VALUES ($1, 1, 52400)`, [b.id]);
  // التغذية: أهداف (مثال ورقة التعليمات) + نسخة من «الجدول الغذائي 1» المستورد، والسجل من وجباته
  await q(`INSERT INTO nutrition_targets (order_id, kcal, protein, carbs, fat) VALUES ($1, 1885, 125, 200, 62)`, [o.id]);
  const { rows: [tpl] } = await q(`SELECT id FROM nutrition_plans WHERE order_id IS NULL AND name = 'الجدول الغذائي 1'`);
  const { rows: [np] } = await q(`INSERT INTO nutrition_plans (order_id, source_id, name) VALUES ($1,$2,'الجدول الغذائي 1') RETURNING id`, [o.id, tpl.id]);
  const meals = (await q(`SELECT id, kind, title, method, position FROM plan_meals WHERE plan_id = $1 ORDER BY position`, [tpl.id])).rows;
  const mine: { id: string; kind: string; title: string; p: number; c: number; f: number }[] = [];
  for (const m of meals) {
    const { rows: [nm] } = await q(`INSERT INTO plan_meals (plan_id, kind, title, method, position) VALUES ($1,$2,$3,$4,$5) RETURNING id`, [np.id, m.kind, m.title, m.method, m.position]);
    await q(`INSERT INTO plan_items (meal_id, food, portion, protein, carbs, fat, position) SELECT $1, food, portion, protein, carbs, fat, position FROM plan_items WHERE meal_id = $2`, [nm.id, m.id]);
    const { rows: [t] } = await q(`SELECT coalesce(sum(protein),0)::float p, coalesce(sum(carbs),0)::float c, coalesce(sum(fat),0)::float f FROM plan_items WHERE meal_id = $1`, [nm.id]);
    mine.push({ id: nm.id, kind: m.kind, title: m.title, ...t });
  }
  for (let ago = 0; ago < 12; ago++) {
    const pick = mine.filter((m, i) => ago === 0 ? m.kind === "breakfast" || m.kind === "lunch" : (i + ago) % 5 !== 0);
    for (const m of pick) {
      await q(`INSERT INTO food_logs (user_id, order_id, log_date, kind, meal_id, name, protein, carbs, fat) VALUES ($1,$2,(now() AT TIME ZONE 'Asia/Riyadh')::date - $3::int,$4,$5,$6,$7,$8,$9)`,
        [u.id, o.id, ago, m.kind, m.id, m.title, m.p, m.c, m.f]);
    }
  }
  // متدرب حفظ تفضيلاته وأغلق شريط التثبيت من قبل (الصورة تعرض الحساب كما يظهر عادةً)
  await q(`INSERT INTO user_prefs (user_id) VALUES ($1) ON CONFLICT DO NOTHING`, [u.id]);
  await ctx.addInitScript(() => { try { localStorage.setItem("nav_install_dismissed", "1"); } catch {} });
  await q(`INSERT INTO check_ins (order_id, user_id, answers, coach_reply, replied_at, created_at) VALUES ($1,$2,'[]'::jsonb,'تم',now() - interval '6 days', now() - interval '7 days')`, [o.id, u.id]);

  const base = `/account/orders/${orderNo}`;
  await ctx.addInitScript(() => document.addEventListener("DOMContentLoaded", () => { const st = document.createElement("style"); st.textContent = ".wa-float,.account-who{display:none!important}"; document.head.append(st); }));
  // ---------- الصور ----------
  await page.goto("/account");
  await capture(page, "home", page.locator("body"), page.getByTestId("today-nutrition"), [
    page.locator(".account-side"), page.locator(".my-program > .row").first(), page.getByTestId("adherence").first(),
    page.getByTestId("today-training"), page.getByTestId("today-nutrition"),
  ]);
  await page.locator("#instructions details").evaluateAll((els) => els.forEach((e) => e.removeAttribute("open")));
  await capture(page, "instructions", page.locator("#instructions"), page.locator("#instructions"), [
    page.locator(".ins-info"), page.locator("#instructions .today-macros"), page.locator(".rules-grid"),
  ]);

  await page.goto(`${base}/training?week=2&day=${days[0].id}`);
  await capture(page, "training", page.getByRole("navigation", { name: "اليوم" }), page.getByTestId("exercise-list"), [
    page.getByRole("navigation", { name: "اليوم" }), page.getByTestId("exercise-list"),
  ]);
  await page.getByTestId("exercise-card").first().click();
  await page.waitForURL(/\/training\/[0-9a-f-]{36}/);
  const card = page.getByTestId("exercise-log");
  await capture(page, "log", card, card, [
    card.locator(".set-rows"), card.locator(".rir-field"), card.getByTestId("one-rm"),
    card.getByRole("button", { name: "تحديث" }), card.locator(".swap-form"),
  ]);
  await page.goBack();
  await page.getByText("قيّم تمرين اليوم").click();
  await capture(page, "rate", page.getByTestId("rate-day"), page.getByTestId("rate-day"), [page.getByTestId("rate-day")]);

  await page.goto(`${base}/progress`);
  const forms = page.locator(".progress-forms > section");
  await capture(page, "body", page.locator(".progress-forms"), page.locator(".progress-forms"), [forms.nth(0), forms.nth(1), forms.nth(2)]);

  await page.goto(`${base}/progress`);
  await page.locator("section[aria-labelledby=ws-h], section[aria-labelledby=st-h], section[aria-labelledby=ms-h]").evaluateAll((els) => els.forEach((e) => ((e as HTMLElement).style.display = "none")));
  await capture(page, "progress", page.getByTestId("progress-stats"), page.getByTestId("prs"), [
    page.getByTestId("progress-stats"), page.locator("section[aria-labelledby=wt-h]"), page.getByTestId("prs"),
  ], 1150);

  await page.goto(`${base}/nutrition`);
  // التصميم الجديد (مثل MyFitnessPal): اليوم، ملخص الباقي، ثم الوجبات وزر «+ إضافة أكل» تحت كل وجبة
  await capture(page, "nutrition", page.getByTestId("log-date"), page.getByTestId("meal-breakfast"), [
    page.locator(".row", { has: page.getByTestId("log-date") }).last(), page.getByTestId("macro-summary"), page.getByTestId("add-food-breakfast"),
  ]);

  await page.goto(`${base}/nutrition/log`);
  await capture(page, "macrolog", page.getByTestId("macro-avg"), page.getByTestId("macro-log"), [
    page.getByTestId("macro-avg"), page.locator(".grid.g2 > section").first(), page.getByTestId("macro-log"),
  ], 1300);

  await page.goto(base);
  await capture(page, "weeks", page.getByTestId("review-history"), page.getByTestId("review-history"), [
    page.getByTestId("review-window"), page.locator("ol.weeks"),
  ]);
  const ck = page.locator("#checkin");
  await capture(page, "checkin", ck, ck, [ck.locator("form")], 900);

  fs.writeFileSync(OUT_JSON, JSON.stringify(shots, null, 2) + "\n");
  if (process.env.GUIDE_REVIEW) {
    const dir = process.env.GUIDE_REVIEW;
    for (const [name, url, w] of [["guide-phone", "/account/guide", 390], ["progress-phone", `${base}/progress`, 390], ["account-desktop", "/account", 1440], ["guide-desktop", "/account/guide", 1440], ["macrolog-desktop", `${base}/nutrition/log`, 1440], ["progress-ipad", `${base}/progress`, 810]] as const) {
      await page.setViewportSize({ width: w, height: 900 });
      await page.goto(url);
      await page.evaluate(() => document.fonts.ready);
      await page.screenshot({ path: path.join(dir, `${name}.png`), fullPage: true });
    }
  }
  await ctx.close();
  // تنظيف البيانات التجريبية
  await q(`DELETE FROM orders WHERE user_id = $1`, [u.id]);
  await q(`DELETE FROM "user" WHERE id = $1`, [u.id]);
  await db.end();
});
