// تعبئة تسجيل التمرين من صورة تطبيق خارجي (قراءة الصورة محاكاة: WORKOUT_VISION_MOCK). قاعدة nav_e2e.
import { test, expect, type Page, type Browser } from "@playwright/test";
import pg from "pg";
import sharp from "sharp";

const OWNER = process.env.E2E_DATABASE_URL_OWNER ?? "postgres://nav_owner:nav_owner_dev@localhost:5432/nav_e2e";
const db = new pg.Pool({ connectionString: OWNER, max: 2 });
test.afterAll(async () => { await db.end(); });

let ip = 120;
async function newPage(browser: Browser, tag: string) {
  const ctx = await browser.newContext({ ...test.info().project.use, extraHTTPHeaders: { "x-forwarded-for": `10.11.${tag.length}.${ip++}` } });
  return ctx.newPage();
}
async function latestOtp(email: string) {
  for (let i = 0; i < 20; i++) {
    const { rows } = await db.query("SELECT body FROM dev_mailbox WHERE recipient = $1 AND subject LIKE 'رمز الدخول%' ORDER BY id DESC LIMIT 1", [email]);
    const m = rows[0]?.body.match(/رمز الدخول: (\d{6})/);
    if (m) return m[1];
    await new Promise((r) => setTimeout(r, 250));
  }
  throw new Error("OTP not found");
}
async function login(page: Page, email: string) {
  await page.goto(`/login?next=/account`);
  await page.getByLabel("البريد الإلكتروني").fill(email);
  await page.getByRole("button", { name: "أرسل رمز الدخول" }).click();
  await page.getByLabel("رمز الدخول").fill(await latestOtp(email));
  await page.getByRole("button", { name: "دخول" }).click();
  await page.waitForURL((u) => !u.pathname.startsWith("/login"));
}
async function noHorizontalScroll(page: Page) {
  const [sw, iw] = await page.evaluate(() => [document.documentElement.scrollWidth, window.innerWidth]);
  expect(sw, `horizontal overflow on ${page.url()}`).toBeLessThanOrEqual(iw);
}

test("تعبئة التسجيل من صورة: قراءة، ربط يدوي، حفظ، وتذكّر الربط", async ({ browser }, info) => {
  const email = `trainee-im-${info.project.name}@e2e.test`;
  const page = await newPage(browser, info.project.name);
  await login(page, email);

  // برنامج نشط فيه ثلاثة تمارين في اليوم الأول
  const { rows: [u] } = await db.query(`SELECT id FROM "user" WHERE email = $1`, [email]);
  const { rows: [p] } = await db.query(`SELECT p.id, p.name, o.id AS offer_id, o.label, o.price_halalas FROM products p JOIN product_offers o ON o.product_id = p.id WHERE p.slug = 'intensive' AND o.months = 3`);
  const orderNo = (await db.query("SELECT app.new_order_no() AS no")).rows[0].no as string;
  const { rows: [o] } = await db.query(
    `INSERT INTO orders (order_no, user_id, product_id, offer_id, category, product_name, offer_label, months, list_price_halalas, amount_due_halalas, status, contact_name, contact_phone, idempotency_key, paid_at)
     VALUES ($1,$2,$3,$4,'follow',$5,$6,3,$7,$7,'active','متدربة','+966500000000',$1, now()) RETURNING id`,
    [orderNo, u.id, p.id, p.offer_id, p.name, p.label, p.price_halalas]);
  const { rows: [b] } = await db.query(`INSERT INTO blocks (order_id, user_id, name, start_date, weeks) VALUES ($1,$2,'بلوك الصور',current_date,4) RETURNING id`, [o.id, u.id]);
  const { rows: [d] } = await db.query(`INSERT INTO block_days (block_id, day_no, title) VALUES ($1,1,'DAY 1 — LOWER') RETURNING id`, [b.id]);
  const plan = JSON.stringify(Array(4).fill({ sets: 2, reps: [10, 10], rir: 2 }));
  let pos = 1;
  for (const n of ["Mid Leg Press", "Hip Thrusts", "Seated Cable Row"]) {
    await db.query(`INSERT INTO block_items (day_id, position, exercise_id, coach_exercise_id, plan) SELECT $1, $2, id, id, $3 FROM exercises WHERE name = $4`, [d.id, pos++, plan, n]);
  }
  const image = await sharp({ create: { width: 40, height: 60, channels: 3, background: "#ffffff" } }).png().toBuffer();

  await page.goto(`/account/orders/${orderNo}/training?week=1`);
  // الأدوات الإضافية داخل «المزيد» لتخفيف زحمة الصفحة
  await page.getByTestId("more-tools").locator("summary").first().click();
  const box = page.getByTestId("import-image");
  await box.locator("summary").click();
  // صورة كبيرة (أكبر من حد 5MB): تتصغّر في الجهاز قبل الرفع بدل ما يفشل الطلب
  const W = 1300, H = 2800, noise = Buffer.alloc(W * H * 3);
  for (let i = 0; i < noise.length; i++) noise[i] = (i * 2654435761) >>> 24;
  const big = await sharp(noise, { raw: { width: W, height: H, channels: 3 } }).png({ compressionLevel: 0 }).toBuffer();
  expect(big.length).toBeGreaterThan(5 * 1024 * 1024);
  // أكثر من 4 صور ← رسالة، وحتى 4 صور (منها صورة كبيرة) تنقرأ بطلب واحد
  const five = Array.from({ length: 5 }, (_, i) => ({ name: `s${i}.png`, mimeType: "image/png", buffer: image }));
  await box.locator('input[type="file"]').setInputFiles(five);
  await box.getByRole("button", { name: "اقرأ الصورة" }).click();
  await expect(box.getByText("اختر حتى 4 صور.")).toBeVisible();
  await box.locator('input[type="file"]').setInputFiles([
    { name: "strong-1.png", mimeType: "image/png", buffer: big },
    { name: "strong-2.png", mimeType: "image/png", buffer: image },
  ]);
  await box.getByRole("button", { name: "اقرأ الصورة" }).click();
  const review = box.getByTestId("import-review");
  await expect(review.locator("fieldset")).toHaveCount(3);
  await expect(review.locator("fieldset").nth(0)).toContainText("مطابقة تقريبية");
  await expect(review.locator("fieldset").nth(1)).toContainText("مطابقة بالاسم");
  await expect(review.locator("fieldset").nth(2)).toContainText("اختر التمرين");
  await expect(review.locator('input[name="weights_0"]')).toHaveValue("100, 110"); // الإحماء لا يُحسب، ووزن لكل جولة
  await expect(review.locator('input[name="reps_0"]')).toHaveValue("12, 10");
  await expect(review.locator('input[name="weights_2"]')).toHaveValue("45.5"); // 100 lb
  await noHorizontalScroll(page);
  const rowOpt = await review.locator('select[name="item_2"] option', { hasText: "Seated Cable Row" }).getAttribute("value");
  await review.locator('select[name="item_2"]').selectOption(rowOpt!);
  await review.getByRole("button", { name: "حفظ الكل" }).click();
  await expect(box).toContainText("تم حفظ 3 تمارين");

  await page.reload();
  await expect(page.getByTestId("exercise-card").filter({ has: page.getByLabel("مسجّل") })).toHaveCount(3);
  await page.getByTestId("more-tools").locator("summary").first().click();
  const logs = (await db.query(
    `SELECT e.name, l.weight::float AS w, l.weights::float[] AS ws, l.reps FROM item_logs l JOIN block_items i ON i.id = l.block_item_id JOIN exercises e ON e.id = i.exercise_id
      WHERE i.day_id = $1 AND l.week_no = 1 ORDER BY i.position`, [d.id])).rows;
  expect(logs).toEqual([
    { name: "Mid Leg Press", w: 110, ws: [100, 110], reps: [12, 10] }, { name: "Hip Thrusts", w: 70, ws: [70, 70], reps: [10, 10] },
    { name: "Seated Cable Row", w: 45.5, ws: [45.5], reps: [12] }]);

  // المرة الثانية: الربط محفوظ
  const box2 = page.getByTestId("import-image");
  await box2.locator("summary").click();
  await box2.locator('input[type="file"]').setInputFiles({ name: "strong.png", mimeType: "image/png", buffer: image });
  await box2.getByRole("button", { name: "اقرأ الصورة" }).click();
  await expect(box2.getByTestId("import-review").locator("fieldset").nth(2)).toContainText("مربوط سابقاً");
  await expect(box2.getByTestId("import-review").locator('select[name="item_2"]')).toHaveValue(rowOpt!);
});
