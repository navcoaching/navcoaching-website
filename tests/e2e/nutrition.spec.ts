// التغذية والمكملات: قوالب مستوردة، أهداف المتدرب، إسناد جدول وروتين، سجل الأكل اليومي (من الجداول وإدخال حر). قاعدة nav_e2e.
import { test, expect, type Page, type Browser } from "@playwright/test";
import pg from "pg";

const OWNER = process.env.E2E_DATABASE_URL_OWNER ?? "postgres://nav_owner:nav_owner_dev@localhost:5432/nav_e2e";
const db = new pg.Pool({ connectionString: OWNER, max: 2 });
test.afterAll(async () => { await db.end(); });

let ip = 50;
async function newPage(browser: Browser, tag: string) {
  const ctx = await browser.newContext({ ...test.info().project.use, extraHTTPHeaders: { "x-forwarded-for": `10.7.${tag.length}.${ip++}` } });
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
/** طلب متابعة نشط للمتدرب (بدون المرور بالدفع) */
async function activeOrder(email: string, name: string) {
  const { rows: [u] } = await db.query(`SELECT id FROM "user" WHERE email = $1`, [email]);
  const { rows: [p] } = await db.query(
    `SELECT p.id, p.name, o.id AS offer_id, o.label, o.price_halalas FROM products p JOIN product_offers o ON o.product_id = p.id WHERE p.slug = 'intensive' AND o.months = 3`);
  const orderNo = (await db.query("SELECT app.new_order_no() AS no")).rows[0].no as string;
  await db.query(
    `INSERT INTO orders (order_no, user_id, product_id, offer_id, category, product_name, offer_label, months, list_price_halalas,
                         amount_due_halalas, status, contact_name, contact_phone, idempotency_key, paid_at)
     VALUES ($1,$2,$3,$4,'follow',$5,$6,3,$7,$7,'active',$8,'+966512345678',$9, now())`,
    [orderNo, u.id, p.id, p.offer_id, p.name, p.label, p.price_halalas, name, `k-${orderNo}-nutrition`]);
  return orderNo;
}

test("التغذية والمكملات: الأهداف، الجداول، المكملات، وسجل اليوم", async ({ browser }, info) => {
  const project = info.project.name;
  const coachEmail = `coach-nu-${project}@e2e.test`;
  const traineeEmail = `trainee-nu-${project}@e2e.test`;

  // ---------- المدربة: القوالب ----------
  const coach = await newPage(browser, project + "-c");
  await login(coach, coachEmail, "/admin");
  await db.query(`UPDATE "user" SET role = 'coach' WHERE email = $1`, [coachEmail]);
  await coach.goto("/admin/nutrition");
  await expect(coach.getByTestId("nutrition-templates")).toContainText("الجدول الغذائي 5");
  await expect(coach.getByTestId("supp-templates")).toContainText("روتين المكملات والأداء الذهني");
  await noHorizontalScroll(coach);
  await coach.getByTestId("nutrition-templates").getByRole("row", { name: /الجدول الغذائي 1/ }).getByRole("link", { name: "فتح" }).click();
  await expect(coach.getByTestId("plan-total")).toContainText("1749"); // 1748.5 كما في ورقة تغذية ١
  await noHorizontalScroll(coach);

  // ---------- المدربة: أهداف المتدرب والإسناد ----------
  const trainee = await newPage(browser, project + "-t");
  await login(trainee, traineeEmail);
  const orderNo = await activeOrder(traineeEmail, `ريم تغذية ${project}`);
  await coach.goto(`/admin/orders/${orderNo}`);
  await coach.getByTestId("nutrition-card").getByRole("link", { name: "فتح" }).click();
  const targets = coach.getByTestId("targets");
  await targets.getByLabel("السعرات").fill("1885");
  await targets.getByLabel("البروتين (غ)").fill("125");
  await targets.getByLabel("الكارب (غ)").fill("200");
  await targets.getByLabel("الدهون (غ)").fill("62");
  await targets.getByRole("button", { name: "حفظ الأهداف" }).click();
  await expect(coach.getByText("تم حفظ الأهداف")).toBeVisible();
  await coach.reload();
  await expect(coach.getByTestId("target-check")).toContainText("مطابق: 1858");
  await coach.getByLabel("إضافة جدول من القوالب").selectOption({ label: "الجدول الغذائي 2" });
  await coach.getByRole("button", { name: "إضافة للمتدرب" }).click();
  await expect(coach.getByText("تمت إضافة الجدول للمتدرب")).toBeVisible();
  // جدول ثاني حتى يختار المتدرب بينهم
  await coach.getByLabel("إضافة جدول من القوالب").selectOption({ label: "الجدول الغذائي 1" });
  await coach.getByRole("button", { name: "إضافة للمتدرب" }).click();
  await expect(coach.getByText("تمت إضافة الجدول للمتدرب").last()).toBeVisible();
  await coach.getByLabel("إسناد روتين من القوالب").selectOption({ label: "روتين المكملات والأداء الذهني" });
  await coach.getByRole("button", { name: "إسناد", exact: true }).click();
  await expect(coach.getByText("تم إسناد روتين المكملات")).toBeVisible();
  await coach.reload();
  await expect(coach.getByTestId("trainee-plans")).toContainText("الجدول الغذائي 2");
  await noHorizontalScroll(coach);

  // ---------- المدربة: صنف في قاعدة الأكل ----------
  const foodName = `رز بسمتي مطبوخ ${project}`;
  await coach.goto("/admin/foods");
  await coach.getByText("+ صنف جديد").click();
  await coach.getByLabel("الاسم بالعربي").first().fill(foodName);
  await coach.getByLabel("بروتين").first().fill("2.7");
  await coach.getByLabel("كارب").first().fill("28.2");
  await coach.getByLabel("دهون").first().fill("0.3");
  await coach.getByLabel("الحصة الافتراضية (غ)").first().fill("150");
  await coach.getByRole("button", { name: "إضافة الصنف" }).click();
  await expect(coach.getByText("تمت إضافة الصنف")).toBeVisible();
  await coach.goto(`/admin/foods?q=${encodeURIComponent(foodName)}`);
  await expect(coach.getByTestId("admin-foods")).toContainText(foodName);
  await noHorizontalScroll(coach);

  // ---------- المتدرب: سجل اليوم ----------
  await trainee.goto(`/account/orders/${orderNo}`);
  await trainee.getByTestId("nutrition-link").click();
  await trainee.waitForURL(/\/nutrition/);
  const form = trainee.getByTestId("food-log-form");
  await form.getByRole("radio", { name: "الغداء" }).check();
  const mealSel = form.getByLabel("اختر من وجبات جداولك");
  const shawarma = await mealSel.locator("option", { hasText: "شورما دجاج" }).getAttribute("value");
  await mealSel.selectOption(shawarma!);
  await form.getByRole("button", { name: "إضافة" }).click();
  await expect(trainee.getByText("تمت الإضافة ✅")).toBeVisible();
  await expect(trainee.getByTestId("food-log-list")).toContainText("شورما دجاج");
  await expect(trainee.getByTestId("macro-summary")).toContainText("383"); // 382.5 من الورقة
  await form.getByRole("radio", { name: "سناك" }).check();
  await form.getByRole("radio", { name: "أكلة أخرى" }).check();
  await form.getByLabel("اسم الأكلة").fill("تفاحة");
  await form.getByLabel("كارب (غ)").fill("25");
  await form.getByRole("button", { name: "إضافة" }).click();
  await expect(trainee.getByTestId("food-log-list")).toContainText("تفاحة");
  await expect(trainee.getByTestId("macro-summary")).toContainText("المتبقي");
  await noHorizontalScroll(trainee);
  trainee.once("dialog", (d) => d.accept());
  await trainee.getByRole("button", { name: "حذف تفاحة" }).click();
  await expect(trainee.getByTestId("food-log-list")).not.toContainText("تفاحة");

  // البحث بالغرام: يختار الصنف ويكتب الكمية، وتظهر الماكروز قبل الحفظ
  await form.getByRole("radio", { name: "العشاء" }).check();
  await form.getByRole("radio", { name: "ابحث بالغرام" }).check();
  await form.getByLabel("ابحث عن أكل").fill(`بسمتي مطبوخ ${project}`);
  await form.getByTestId("food-results").getByRole("button", { name: new RegExp(foodName) }).click();
  await expect(form.getByLabel("الكمية (غرام)")).toHaveValue("150");
  await form.getByLabel("الكمية (غرام)").fill("200");
  await expect(form.getByTestId("grams-preview")).toContainText("كارب 56.4");
  await form.getByRole("button", { name: "إضافة" }).click();
  await expect(trainee.getByTestId("food-log-list")).toContainText(`${foodName} — 200غ`);
  await noHorizontalScroll(trainee);

  await trainee.getByRole("link", { name: "جداولي الغذائية" }).click();
  // اختيار الجدول: كل الجداول ظاهرة كخيارات، ويُعرض المختار فقط
  const picker = trainee.getByTestId("plan-picker");
  await expect(picker.getByRole("link")).toHaveCount(2);
  await expect(trainee.getByTestId("my-plan")).toHaveCount(1);
  await expect(trainee.getByTestId("my-plan")).toContainText("مكرونة بيني");
  await picker.getByRole("link", { name: /الجدول الغذائي 1/ }).click();
  await expect(trainee.getByTestId("my-plan").locator("h2")).toContainText("الجدول الغذائي 1");
  await expect(picker.getByRole("link", { name: /الجدول الغذائي 1/ })).toHaveAttribute("aria-current", "true");
  await picker.getByRole("link", { name: /الجدول الغذائي 2/ }).click();
  await expect(trainee.getByTestId("my-plan")).toContainText("مكرونة بيني");
  await noHorizontalScroll(trainee);
  await trainee.getByRole("link", { name: "المكملات", exact: true }).click();
  await expect(trainee.getByTestId("my-supplements")).toContainText("مغنيسيوم سترات");
  await noHorizontalScroll(trainee);

  // ---------- المدربة ترى سجل الأكل ----------
  await coach.goto(`/admin/orders/${orderNo}/nutrition`);
  await expect(coach.getByTestId("food-log-review")).toContainText("635"); // شورما 382.5 + رز 200غ 252.6

  // ---------- «برنامجي» أعلى حسابي + تنبيه قرب انتهاء الباقة (3 أيام) ----------
  await db.query(
    `UPDATE orders SET sub_start_at = now() - interval '27 days', sub_end_at = ((now() AT TIME ZONE 'Asia/Riyadh')::date + 3 + time '12:00') AT TIME ZONE 'Asia/Riyadh' WHERE order_no = $1`, [orderNo]);
  await trainee.goto("/account");
  const mine = trainee.getByTestId("my-program");
  await expect(mine).toContainText("التغذية والمكملات");
  await expect(mine.getByTestId("today-nutrition")).toContainText("السعرات");
  await expect(mine.getByTestId("today-supplements")).toContainText("مغنيسيوم سترات");
  await expect(mine.getByTestId("expiry-alert")).toContainText("ينتهي خلال 3 أيام");
  await expect(mine.getByTestId("expiry-alert").getByRole("button", { name: "جدّد بخصم 10%" })).toBeVisible();
  await trainee.getByTestId("renewal-popup").getByRole("button", { name: "لاحقاً" }).click();
  await noHorizontalScroll(trainee);
  await trainee.goto(`/account/orders/${orderNo}`);
  await expect(trainee.getByTestId("expiry-alert")).toBeVisible();

  // ---------- شريط حالة الطلب ثابت أثناء التمرير ----------
  await coach.goto(`/admin/orders/${orderNo}`);
  await coach.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
  await expect(coach.getByTestId("status-bar")).toBeInViewport();
  await expect(coach.getByTestId("status-bar").getByLabel("تغيير الحالة إلى")).toContainText("انتهى الاشتراك (إنهاء الآن)");
  await noHorizontalScroll(coach);

  // ---------- مستخدم آخر لا يرى ----------
  const other = await newPage(browser, project + "-o");
  await login(other, `other-nu-${project}@e2e.test`);
  expect((await other.goto(`/account/orders/${orderNo}/nutrition`))?.status()).toBe(404);
});
