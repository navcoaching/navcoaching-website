// لوحة الإدارة: التنقّل على الجوال وتنبيه التعديلات غير المحفوظة
import { test, expect, type Page, type Browser } from "@playwright/test";
import pg from "pg";

const OWNER = process.env.E2E_DATABASE_URL_OWNER ?? "postgres://nav_owner:nav_owner_dev@localhost:5432/nav_e2e";
const db = new pg.Pool({ connectionString: OWNER, max: 2 });
test.afterAll(async () => { await db.end(); });

let ip = 10;
async function newPage(browser: Browser, tag: string) {
  const ctx = await browser.newContext({ ...test.info().project.use, extraHTTPHeaders: { "x-forwarded-for": `10.47.${tag.length}.${ip++}` } });
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
async function noHorizontalScroll(page: Page) {
  const [sw, iw] = await page.evaluate(() => [document.documentElement.scrollWidth, window.innerWidth]);
  expect(sw).toBeLessThanOrEqual(iw);
}

test("لوحة الإدارة: الشريط السفلي و«المزيد» على الجوال، وتنبيه التعديلات غير المحفوظة", async ({ browser }, info) => {
  const p = info.project.name;
  const email = `coach-ux-${p}@e2e.test`;
  const coach = await newPage(browser, p + "ux");
  await login(coach, email, "/admin");
  await db.query(`UPDATE "user" SET role = 'coach' WHERE email = $1`, [email]);
  await coach.goto("/admin/checkins");
  const tabs = coach.getByTestId("admin-tabs");
  if (p === "desktop") {
    await expect(tabs).toBeHidden();
    await expect(coach.locator(".admin-side").getByRole("link", { name: "المراجعات الأسبوعية" })).toHaveAttribute("aria-current", "page");
  } else {
    await expect(tabs).toBeVisible();
    await expect(tabs.getByRole("link", { name: "المراجعات" })).toHaveAttribute("aria-current", "page");
    await tabs.getByRole("button", { name: "المزيد" }).click();
    const sheet = coach.getByRole("dialog", { name: "كل صفحات الإدارة" });
    await sheet.getByRole("link", { name: "مكتبة التمارين" }).click();
    await coach.waitForURL(/\/admin\/exercises/);
    await expect(sheet).toBeHidden();
  }
  await noHorizontalScroll(coach);

  // «المحتوى والإعدادات»: تعديل بدون حفظ يظهر تنبيهاً باسم القسم
  await coach.goto("/admin/content");
  await expect(coach.getByTestId("unsaved-bar")).toHaveCount(0);
  await coach.locator("#ga-id").fill("G-TEST12345");
  await expect(coach.getByTestId("unsaved-bar")).toBeVisible();
  await coach.context().close();
});
