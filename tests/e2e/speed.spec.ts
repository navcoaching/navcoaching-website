// صفحة «فحص السرعة» في لوحة الإدارة: للمدربة فقط، تعرض المناطق وأزمنة القاعدة والمتصفح بدون كشف رابط الاتصال.
import { test, expect, type Page, type Browser } from "@playwright/test";
import pg from "pg";

const OWNER = process.env.E2E_DATABASE_URL_OWNER ?? "postgres://nav_owner:nav_owner_dev@localhost:5432/nav_e2e";
const db = new pg.Pool({ connectionString: OWNER, max: 2 });
test.afterAll(async () => { await db.end(); });

let ip = 10;
async function newPage(browser: Browser, tag: string) {
  const ctx = await browser.newContext({ ...test.info().project.use, extraHTTPHeaders: { "x-forwarded-for": `10.53.${tag.length}.${ip++}` } });
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

test("فحص السرعة: للمدربة فقط ويعرض الأزمنة", async ({ browser }, info) => {
  const p = info.project.name;
  const traineeEmail = `speed-t-${p}@e2e.test`, coachEmail = `speed-c-${p}@e2e.test`;

  const trainee = await newPage(browser, p + "t");
  await login(trainee, traineeEmail, "/account");
  await trainee.goto("/admin/speed");
  expect(trainee.url()).not.toContain("/admin/speed");
  expect(await trainee.getByTestId("speed-table").count()).toBe(0);

  const coach = await newPage(browser, p + "c");
  await login(coach, coachEmail, "/account");
  await db.query(`UPDATE "user" SET role = 'coach' WHERE email = $1`, [coachEmail]);
  await coach.goto("/admin/speed");
  await expect(coach.getByRole("heading", { name: "فحص السرعة" })).toBeVisible();
  await expect(coach.getByTestId("speed-rtt")).toContainText("مللي ثانية");
  await expect(coach.getByTestId("speed-fresh")).toContainText("مللي ثانية");
  await expect(coach.getByTestId("speed-browser-wait")).toContainText("مللي ثانية");
  await expect(coach.getByTestId("speed-verdicts").locator(".alert").first()).toBeVisible();
  const html = await coach.content();
  expect(html).not.toMatch(/postgres(ql)?:\/\//);
  expect(html).not.toContain("nav_app_dev");
  const [sw, iw] = await coach.evaluate(() => [document.documentElement.scrollWidth, window.innerWidth]);
  expect(sw).toBeLessThanOrEqual(iw);
  await coach.screenshot({ path: `test-results/speed-${p}.png`, fullPage: true });
});
