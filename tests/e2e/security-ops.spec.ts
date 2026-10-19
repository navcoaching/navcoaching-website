// قفل الدخول بعد 5 رموز خاطئة، مهلة الجلسة 12 ساعة، وسجل الأمان في لوحة المدربة.
import { test, expect, type Page, type Browser, type APIRequestContext } from "@playwright/test";
import pg from "pg";

const OWNER = process.env.E2E_DATABASE_URL_OWNER ?? "postgres://nav_owner:nav_owner_dev@localhost:5432/nav_e2e";
const db = new pg.Pool({ connectionString: OWNER, max: 2 });
test.afterAll(async () => { await db.end(); });

let ip = 10;
const nextIp = () => `10.61.${test.info().project.name.length}.${ip++}`;
async function newPage(browser: Browser) {
  const ctx = await browser.newContext({ ...test.info().project.use, extraHTTPHeaders: { "x-forwarded-for": nextIp() } });
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
async function login(page: Page, email: string, next: string) {
  await page.goto(`/login?next=${encodeURIComponent(next)}`);
  await page.getByLabel("البريد الإلكتروني").fill(email);
  await page.getByRole("button", { name: "أرسل رمز الدخول" }).click();
  await page.getByLabel("رمز الدخول").fill(await latestOtp(email));
  await page.getByRole("button", { name: "دخول" }).click();
  await page.waitForURL((u) => !u.pathname.startsWith("/login"));
}
const api = (request: APIRequestContext, path: string, data: object) =>
  request.post(`/api/auth${path}`, { data, headers: { origin: "http://localhost:3100", "x-forwarded-for": nextIp() } });

test("5 رموز خاطئة تقفل الدخول 15 دقيقة لهذا البريد فقط، ثم يرجع طبيعي", async ({ request, browser }) => {
  const email = `lock-${test.info().project.name}-${Date.now()}@e2e.test`;
  expect((await api(request, "/email-otp/send-verification-otp", { email, type: "sign-in" })).ok()).toBe(true);
  const code = await latestOtp(email);
  const wrong = code === "000000" ? "111111" : "000000";
  for (let i = 0; i < 5; i++) expect((await api(request, "/sign-in/email-otp", { email, otp: wrong })).status()).toBeGreaterThanOrEqual(400);

  // مقفل: لا رمز جديد ولا دخول، حتى بالرمز الصحيح ومن جهاز آخر
  for (const [path, data] of [["/email-otp/send-verification-otp", { email, type: "sign-in" }], ["/sign-in/email-otp", { email, otp: code }]] as const) {
    const r = await api(request, path, data);
    expect(r.status()).toBe(429);
    expect((await r.json()).code).toBe("ACCOUNT_LOCKED");
  }
  // بريد آخر غير متأثر
  expect((await api(request, "/email-otp/send-verification-otp", { email: `other-${email}`, type: "sign-in" })).ok()).toBe(true);

  // الواجهة تعرض سبب القفل
  const page = await newPage(browser);
  await page.goto("/login");
  await page.getByLabel("البريد الإلكتروني").fill(email);
  await page.getByRole("button", { name: "أرسل رمز الدخول" }).click();
  await expect(page.locator("p[role=alert]")).toContainText("مقفل مؤقتاً");

  // بعد 15 دقيقة (نقدّم وقت السجل) يرجع الدخول طبيعي ويُسجَّل
  await db.query("UPDATE security_log SET created_at = created_at - interval '16 minutes' WHERE email = $1", [email]);
  await db.query("DELETE FROM dev_mailbox WHERE recipient = $1", [email]); // حتى لا يُقرأ الرمز القديم
  await login(page, email, "/account");
  const { rows } = await db.query("SELECT event FROM security_log WHERE email = $1 ORDER BY id", [email]);
  const events = rows.map((r) => r.event);
  expect(events.filter((e) => e === "login_failed")).toHaveLength(5);
  expect(events).toContain("login_locked");
  expect(events.at(-1)).toBe("login_ok");
});

test("الجلسة تنتهي بعد 12 ساعة بلا نشاط", async ({ browser }) => {
  const email = `session-${test.info().project.name}@e2e.test`;
  const page = await newPage(browser);
  await login(page, email, "/account");
  const { rows: [s] } = await db.query(`SELECT extract(epoch FROM s."expiresAt" - now())::int AS left FROM session s JOIN "user" u ON u.id = s."userId" WHERE u.email = $1 ORDER BY s."createdAt" DESC LIMIT 1`, [email]);
  expect(s.left).toBeGreaterThan(11.9 * 3600);
  expect(s.left).toBeLessThanOrEqual(12 * 3600);

  // جلسة منتهية = يُطلب الدخول من جديد
  await db.query(`UPDATE session SET "expiresAt" = now() - interval '1 minute' WHERE "userId" = (SELECT id FROM "user" WHERE email = $1)`, [email]);
  await page.context().clearCookies({ name: /session_data/ }); // كاش الجلسة في الكوكي (5 دقائق)
  await page.goto("/account");
  await expect(page).toHaveURL(/\/login/);
});

test("صفحة الأمان والمراقبة: للمدربة فقط، وتعرض محاولات الدخول ومشاكل التشغيل", async ({ browser }) => {
  const p = test.info().project.name;
  const trainee = await newPage(browser);
  await login(trainee, `sec-trainee-${p}@e2e.test`, "/account");
  await trainee.goto("/admin/security");
  await expect(trainee).toHaveURL(/\/account/);

  const coachEmail = `sec-coach-${p}@e2e.test`;
  const coach = await newPage(browser);
  await login(coach, coachEmail, "/account");
  await db.query(`UPDATE "user" SET role = 'coach' WHERE email = $1`, [coachEmail]);
  await db.query("SELECT app.ops_event('push_failed', $1)", [`اختبار ${p}`]);
  await coach.goto("/admin/security");
  await expect(coach.getByRole("heading", { name: "الأمان والمراقبة" })).toBeVisible();
  await expect(coach.getByTestId("security-log")).toContainText(coachEmail);
  await expect(coach.getByTestId("ops-events")).toContainText(`اختبار ${p}`);
  const [sw, iw] = await coach.evaluate(() => [document.documentElement.scrollWidth, window.innerWidth]);
  expect(sw).toBeLessThanOrEqual(iw);
});
