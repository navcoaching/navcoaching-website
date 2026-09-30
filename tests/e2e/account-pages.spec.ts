// صفحات حساب المتدرب: القائمة الجانبية، التقدم، سجل الماكروز، التعليمات، الدليل المصوّر + طيّ اليوم في محرر القالب. قاعدة nav_e2e.
import { test, expect, type Page, type Browser } from "@playwright/test";
import pg from "pg";

const OWNER = process.env.E2E_DATABASE_URL_OWNER ?? "postgres://nav_owner:nav_owner_dev@localhost:5432/nav_e2e";
const db = new pg.Pool({ connectionString: OWNER, max: 2 });
test.afterAll(async () => { await db.end(); });

let ip = 160;
async function newPage(browser: Browser, tag: string) {
  const ctx = await browser.newContext({ ...test.info().project.use, extraHTTPHeaders: { "x-forwarded-for": `10.12.${tag.length}.${ip++}` } });
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
async function login(page: Page, email: string, next = "/account") {
  await page.goto(`/login?next=${encodeURIComponent(next)}`);
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

test("حساب المتدرب: التقدم، سجل الماكروز، التعليمات، والدليل", async ({ browser }, info) => {
  const project = info.project.name;
  const email = `trainee-ap-${project}@e2e.test`;
  const page = await newPage(browser, project);
  await login(page, email);

  const { rows: [u] } = await db.query(`SELECT id FROM "user" WHERE email = $1`, [email]);
  const { rows: [p] } = await db.query(`SELECT p.id, p.name, o.id AS offer_id, o.label, o.price_halalas FROM products p JOIN product_offers o ON o.product_id = p.id WHERE p.slug = 'intensive' AND o.months = 3`);
  const orderNo = (await db.query("SELECT app.new_order_no() AS no")).rows[0].no as string;
  const { rows: [o] } = await db.query(
    `INSERT INTO orders (order_no, user_id, product_id, offer_id, category, product_name, offer_label, months, list_price_halalas, amount_due_halalas, status,
                         contact_name, contact_phone, idempotency_key, paid_at, sub_start_at, sub_end_at, review_weekday)
     VALUES ($1,$2,$3,$4,'follow',$5,$6,3,$7,$7,'active','سارة صفحات','+966500000000',$1, now(), now() - interval '3 days', now() + interval '80 days', 1) RETURNING id`,
    [orderNo, u.id, p.id, p.offer_id, p.name, p.label, p.price_halalas]);
  const { rows: [b] } = await db.query(`INSERT INTO blocks (order_id, user_id, name, start_date, weeks, steps_goal_week) VALUES ($1,$2,'بلوك الصفحات',(now() AT TIME ZONE 'Asia/Riyadh')::date - 3,4,70000) RETURNING id`, [o.id, u.id]);
  const { rows: [d] } = await db.query(`INSERT INTO block_days (block_id, day_no, title) VALUES ($1,1,'DAY 1') RETURNING id`, [b.id]);
  const { rows: [it] } = await db.query(
    `INSERT INTO block_items (day_id, position, exercise_id, coach_exercise_id, plan) SELECT $1, 1, id, id, $2 FROM exercises WHERE name = 'Mid Leg Press' RETURNING id`,
    [d.id, JSON.stringify(Array(4).fill({ sets: 3, reps: [10, 10, 10], rir: 2 }))]);
  await db.query(`INSERT INTO item_logs (block_item_id, week_no, exercise_id, weight, reps, rir) SELECT $1, 1, exercise_id, 80, '{10,10,9}', 2 FROM block_items WHERE id = $1`, [it.id]);
  await db.query(`INSERT INTO weight_logs (user_id, logged_on, kg) VALUES ($1, (now() AT TIME ZONE 'Asia/Riyadh')::date - 3, 70.4), ($1, (now() AT TIME ZONE 'Asia/Riyadh')::date, 69.8)`, [u.id]);
  await db.query(`INSERT INTO body_measurements (user_id, measured_on, waist) VALUES ($1, (now() AT TIME ZONE 'Asia/Riyadh')::date - 3, 80), ($1, (now() AT TIME ZONE 'Asia/Riyadh')::date, 79)`, [u.id]);
  await db.query(`INSERT INTO nutrition_targets (order_id, kcal, protein, carbs, fat, rules) VALUES ($1, 1885, 125, 200, 62, 'الصيام: لا تتجاوز 12 ساعة صيام.')`, [o.id]);
  await db.query(
    `INSERT INTO food_logs (user_id, order_id, log_date, kind, name, protein, carbs, fat)
     VALUES ($1,$2,(now() AT TIME ZONE 'Asia/Riyadh')::date,'lunch','غداء',50,100,20), ($1,$2,(now() AT TIME ZONE 'Asia/Riyadh')::date - 1,'lunch','غداء',40,80,10), ($1,$2,(now() AT TIME ZONE 'Asia/Riyadh')::date - 1,'dinner','عشاء',30,40,10)`, [u.id, o.id]);

  // «حسابي»: التعليمات والقائمة
  await page.goto("/account");
  const ins = page.getByTestId("instructions");
  await expect(ins).toContainText("سارة صفحات");
  await expect(ins).toContainText("الإثنين");
  await expect(ins).toContainText("1,885");
  await expect(page.getByTestId("rules-nutrition")).toContainText("لا تتجاوز 12 ساعة صيام");
  await expect(page.getByTestId("rules-contact")).toContainText("خلال 48 ساعة كحد أقصى");
  await expect(page.getByTestId("rules-training")).toContainText("قاعدة زيادة الوزن");
  // الخطوات اليومية من هدف المدربة لهذا المتدرب (70,000 أسبوعياً ÷ 7)
  await expect(page.getByTestId("rules-training")).toContainText("10,000 خطوة/يوم (70,000 أسبوعياً)");
  await noHorizontalScroll(page);
  const side = page.locator(".account-side");
  if (project === "desktop") {
    // القائمة ملاصقة لأقصى يمين الصفحة
    const box = (await side.boundingBox())!;
    expect(Math.round(box.x + box.width)).toBeGreaterThanOrEqual(1440 - 20);
  }

  // التقدم
  await side.getByRole("link", { name: "التقدم" }).click();
  await expect(page).toHaveURL(new RegExp(`/account/orders/${orderNo}/progress$`));
  await expect(page.getByTestId("progress-stats")).toContainText("69.8 كغ");
  await expect(page.getByTestId("progress-stats")).toContainText("-0.6");
  await expect(page.getByTestId("prs")).toContainText("Mid Leg Press");
  await expect(page.locator(".account-side a[aria-current=page]")).toHaveText(/التقدم/);
  await noHorizontalScroll(page);

  // سجل الماكروز
  await side.getByRole("link", { name: "سجل الماكروز" }).click();
  await expect(page).toHaveURL(new RegExp(`/nutrition/log$`));
  await expect(page.locator(".account-side a[aria-current=page]")).toHaveText(/سجل الماكروز/);
  const table = page.getByTestId("macro-log");
  await expect(table.locator("tbody tr")).toHaveCount(2);
  await expect(table.locator("tbody tr").first()).toContainText("780"); // 50×4 + 100×4 + 20×9
  await expect(page.getByTestId("macro-avg")).toContainText("860"); // (780 + 940) ÷ 2
  await noHorizontalScroll(page);
  await table.getByRole("link", { name: "اليوم" }).click();
  await expect(page.getByTestId("log-date")).toHaveText("اليوم");

  // المراجعة الأسبوعية: رابط «سجّلت تمرين هذا الأسبوع؟»
  await page.goto(`/account/orders/${orderNo}`);
  await page.getByTestId("checkin-training").getByRole("link", { name: /افتح جدول التمرين/ }).click();
  await expect(page).toHaveURL(new RegExp(`/account/orders/${orderNo}/training$`));

  // الدليل المصوّر
  await page.goto("/account/guide");
  await expect(page.getByRole("heading", { name: /دليل الاستخدام المصوّر/ })).toBeVisible();
  await expect(page.getByTestId("guide-log").locator("img")).toBeVisible();
  await expect(page.getByTestId("guide-log").locator(".guide-num")).not.toHaveCount(0);
  await noHorizontalScroll(page);

  // مستخدم آخر لا يرى صفحات هذا الطلب
  const other = await newPage(browser, project + "-x");
  await login(other, `other-ap-${project}@e2e.test`);
  for (const path of ["progress", "nutrition/log"]) {
    const res = await other.goto(`/account/orders/${orderNo}/${path}`);
    expect(res?.status()).toBe(404);
  }
});

test("محرر القالب: طيّ اليوم وفتحه", async ({ browser }, info) => {
  const project = info.project.name;
  const email = `coach-fold-${project}@e2e.test`;
  const page = await newPage(browser, project + "-fold");
  await login(page, email, "/admin");
  await db.query(`UPDATE "user" SET role = 'coach' WHERE email = $1`, [email]);
  const { rows: [t] } = await db.query(`INSERT INTO program_templates (name, weeks) VALUES ($1, 4) RETURNING id`, [`قالب طي ${project} ${Date.now()}`]);
  await db.query(`INSERT INTO template_days (template_id, day_no, title) VALUES ($1, 1, 'DAY 1 | Lower Body'), ($1, 2, 'DAY 2 | Upper Body')`, [t.id]);
  await page.goto(`/admin/templates/${t.id}`);
  const day1 = page.getByTestId("day-1");
  const title = day1.getByLabel("اليوم 1");
  // الأيام مطوية تلقائياً
  await expect(title).toBeHidden();
  await expect(day1.getByTestId("fold-1")).toContainText("فتح اليوم");
  await expect(page.getByTestId("day-2").getByLabel("اليوم 2")).toBeHidden();
  await day1.getByTestId("fold-1").click();
  await expect(title).toBeVisible();
  await expect(day1.getByTestId("fold-1")).toContainText("طيّ اليوم");
  await expect(page.getByTestId("day-2").getByLabel("اليوم 2")).toBeHidden();
  await day1.getByTestId("fold-1").click();
  await expect(title).toBeHidden();
  await noHorizontalScroll(page);
  await db.query(`DELETE FROM program_templates WHERE id = $1`, [t.id]);
});

test("التمارين التأهيلية: التصفية حسب التصنيف، والتعديل من صفحة التمرين", async ({ browser }, info) => {
  const project = info.project.name;
  const email = `coach-rehab-${project}@e2e.test`;
  const page = await newPage(browser, project + "-rehab");
  await login(page, email, "/admin");
  await db.query(`UPDATE "user" SET role = 'coach' WHERE email = $1`, [email]);
  await page.goto("/admin/rehab");
  await expect(page.getByText("لأغراض تنظيمية وتعليمية فقط").first()).toBeVisible();
  await expect(page.getByTestId("rehab-count")).toContainText("43");
  await page.getByLabel("التصنيف").selectOption("آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain");
  await expect(page.getByTestId("rehab-count")).toContainText("13");
  const row = page.getByTestId("rehab-table").getByRole("row", { name: /Glute Bridge/ }).first();
  await expect(row).toContainText("تقوية بسط الورك وتحمّل الجذع");
  await expect(row).toContainText("يحتاج مراجعة أخصائي");
  await noHorizontalScroll(page);
  await page.getByLabel("العرض").selectOption("specialist");
  await expect(page.getByTestId("rehab-count")).toContainText("0");

  // اعتماد مختص من صفحة التمرين ثم يظهر في «المعتمد من مختص فقط»
  const { rows: [ex] } = await db.query(`SELECT id, rehab_review FROM exercises WHERE name = 'Glute Bridge'`);
  await page.goto(`/admin/exercises/${ex.id}`);
  const box = page.getByTestId("rehab-edit");
  await expect(box.getByLabel("آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain")).toBeChecked();
  await box.getByLabel("حالة المراجعة العلاجية").selectOption("specialist");
  await page.getByRole("button", { name: "حفظ التعديلات" }).click();
  await expect(page.getByText("تم الحفظ.")).toBeVisible();
  await page.goto("/admin/rehab?cat=" + encodeURIComponent("آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain") + "&view=specialist");
  await expect(page.getByTestId("rehab-count")).toContainText("1");
  await expect(page.getByTestId("rehab-table")).toContainText("معتمد من مختص");
  await db.query(`UPDATE exercises SET rehab_review = $2 WHERE id = $1`, [ex.id, ex.rehab_review]);
});
