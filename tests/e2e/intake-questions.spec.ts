// أسئلة الاستبيان القابلة للتعديل: المدربة تعدّل نصاً وتخفي سؤالاً وتضيف سؤالاً، فيظهر في الاستبيان وتنحفظ إجابته (قاعدة nav_e2e).
import { test, expect, type Page, type Browser } from "@playwright/test";
import pg from "pg";

const OWNER = process.env.E2E_DATABASE_URL_OWNER ?? "postgres://nav_owner:nav_owner_dev@localhost:5432/nav_e2e";
const db = new pg.Pool({ connectionString: OWNER, max: 2 });
test.afterAll(async () => { await db.end(); });

let ip = 60;
async function newPage(browser: Browser, tag: string) {
  const ctx = await browser.newContext({ ...test.info().project.use, extraHTTPHeaders: { "x-forwarded-for": `10.20.${tag.length}.${ip++}` } });
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


const pick = (page: Page, name: string, value: string) => page.locator(`input[name="${name}"][value="${value}"]`).locator("xpath=..").click();

test("أسئلة الاستبيان: المدربة تعدّل وتخفي وتضيف، وتظهر في الاستبيان وتنحفظ إجاباتها", async ({ browser }, info) => {
  test.setTimeout(120_000);
  const project = info.project.name;
  const coachEmail = `coach-iq-${project}@e2e.test`;
  const coach = await newPage(browser, project + "-c");
  await login(coach, coachEmail, "/admin");
  await db.query(`UPDATE "user" SET role = 'coach' WHERE email = $1`, [coachEmail]);
  await db.query(`DELETE FROM site_settings WHERE key = 'intake_questions'`);
  try {
    await coach.goto("/admin/content/intake");
    await noHorizontalScroll(coach);
    await coach.getByTestId("q-goal").getByLabel("نص السؤال").fill("وش هدفك من التدريب؟");
    await coach.getByTestId("q-level").getByLabel("تلميح تحت السؤال (اختياري)").fill("اختر بصدق");
    await coach.getByTestId("q-sleep").getByLabel(/إخفاء هذا السؤال/).check();
    await expect(coach.getByTestId("q-goal").getByLabel(/إخفاء هذا السؤال/)).toHaveCount(0); // المطلوب ما ينخفى
    const rows = coach.getByTestId("custom-row");
    await rows.nth(0).getByLabel("سؤال جديد").fill("وش رياضتك المفضلة؟");
    await rows.nth(0).getByLabel("نوع السؤال").selectOption("choice");
    await rows.nth(0).getByLabel("تظهر في الخطوة").selectOption("2");
    await rows.nth(0).getByLabel(/الخيارات/).fill("جري\nحديد");
    await rows.nth(0).getByLabel("مطلوب").check();
    await rows.nth(1).getByLabel("سؤال جديد").fill("أي أكل ما تحبه؟");
    await rows.nth(1).getByLabel("نوع السؤال").selectOption("long");
    await rows.nth(1).getByLabel("تظهر في الخطوة").selectOption("4");
    // خيارات ناقصة تُرفض
    await rows.nth(2).getByLabel("سؤال جديد").fill("سؤال ناقص");
    await rows.nth(2).getByLabel("نوع السؤال").selectOption("choice");
    await coach.getByRole("button", { name: "حفظ الأسئلة" }).click();
    await expect(coach.getByText(/يحتاج خيارين على الأقل/)).toBeVisible();
    await rows.nth(2).getByLabel("سؤال جديد").fill("");
    await coach.getByRole("button", { name: "حفظ الأسئلة" }).click();
    await expect(coach.getByText("تم حفظ الأسئلة")).toBeVisible();
    await coach.reload();
    await expect(coach.getByTestId("q-goal").getByLabel("نص السؤال")).toHaveValue("وش هدفك من التدريب؟");
    await expect(coach.getByTestId("custom-row").nth(0).getByLabel("سؤال إضافي 1")).toHaveValue("وش رياضتك المفضلة؟");

    // المتدرب: الاستبيان يعرض التعديلات مباشرة
    const email = `trainee-iq-${project}@e2e.test`;
    const page = await newPage(browser, project + "-t");
    await login(page, email, "/checkout/int1");
    await page.getByLabel("الاسم").fill("سارة الأسئلة");
    await page.locator("#phone").fill("512345678");
    await pick(page, "gender", "أنثى");
    await page.locator("#age").fill("29");
    await page.getByRole("button", { name: "التالي" }).click();
    await expect(page.getByText("وش هدفك من التدريب؟")).toBeVisible();
    await expect(page.getByText("هدفك الرئيسي")).toHaveCount(0);
    await expect(page.getByText("اختر بصدق")).toBeVisible();
    await pick(page, "goal", "لياقة وقوة");
    await pick(page, "level", "مبتدئ · أقل من 6 أشهر");
    await pick(page, "place", "نادي");
    await page.locator("#days").selectOption("3 أيام");
    await page.locator("#duration").selectOption("ساعة");
    // السؤال الإضافي المطلوب: يمنع التقدم بدون إجابة
    await page.getByRole("button", { name: "التالي" }).click();
    await expect(page.getByText("هذا السؤال مطلوب.").first()).toBeVisible();
    await expect(page.locator('fieldset[data-step="2"]')).toBeVisible();
    await pick(page, "cq_" + (await db.query(`SELECT value->'custom'->0->>'id' AS id FROM site_settings WHERE key = 'intake_questions'`)).rows[0].id, "حديد");
    await page.getByRole("button", { name: "التالي" }).click();
    await pick(page, "injury", "لا");
    await pick(page, "condition", "لا");
    await page.locator('input[name="health_ack"]').check();
    await page.getByRole("button", { name: "التالي" }).click();
    await expect(page.locator("#sleep")).toHaveCount(0); // السؤال المخفي ما يظهر
    await expect(page.getByText("أي أكل ما تحبه؟")).toBeVisible();
    await page.getByLabel("أي أكل ما تحبه؟").fill("ما أحب الكبدة");
    await page.locator("#weight").fill("70");
    await page.locator("#height").fill("165");
    await page.locator("#calories").selectOption("أعرف الأساسيات");
    await page.getByRole("button", { name: "التالي" }).click();
    await page.locator("#expectations").fill("متابعة واضحة");
    await page.locator("#media").selectOption("لا، أفضّل الخصوصية");
    await page.locator('input[name="consent_terms"]').check();
    await page.locator('input[name="consent_wa"]').check();
    await noHorizontalScroll(page);
    await page.getByRole("button", { name: "أرسل الاستبيان وانتقل للدفع" }).click();
    await expect(page).toHaveURL(/\/account\/orders\/NAV-\d{6}-[A-Z0-9]{5}\?new=1/);
    const orderNo = page.url().match(/NAV-\d{6}-[A-Z0-9]{5}/)![0];

    const { rows: [i] } = await db.query(`SELECT answers->'custom' AS custom, answers->>'goal' AS goal FROM intakes WHERE order_id = (SELECT id FROM orders WHERE order_no = $1)`, [orderNo]);
    expect(i.goal).toBe("لياقة وقوة");
    expect(i.custom).toEqual([
      { id: expect.any(String), label: "وش رياضتك المفضلة؟", value: "حديد" },
      { id: expect.any(String), label: "أي أكل ما تحبه؟", value: "ما أحب الكبدة" },
    ]);
    // المدربة تشوف الإجابات بنص السؤال وقت الإرسال
    await coach.goto(`/admin/orders/${orderNo}`);
    await coach.getByTestId("intake").locator("summary").first().click();
    await expect(coach.getByTestId("custom-answer").first()).toHaveText("وش رياضتك المفضلة؟");
    await expect(coach.getByText("ما أحب الكبدة")).toBeAttached();
  } finally {
    await db.query(`DELETE FROM site_settings WHERE key = 'intake_questions'`);
  }
});
