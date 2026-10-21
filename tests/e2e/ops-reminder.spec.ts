// تذكير انتهاء رمز Netlify في «المحتوى والإعدادات»: الحالة حسب الأيام الباقية، والإعداد غير عام (قاعدة nav_e2e).
import { test, expect, type Page, type Browser } from "@playwright/test";
import pg from "pg";

const OWNER = process.env.E2E_DATABASE_URL_OWNER ?? "postgres://nav_owner:nav_owner_dev@localhost:5432/nav_e2e";
const db = new pg.Pool({ connectionString: OWNER, max: 2 });
test.afterAll(async () => { await db.end(); });

let ip = 120;
async function newPage(browser: Browser, tag: string) {
  const ctx = await browser.newContext({ ...test.info().project.use, extraHTTPHeaders: { "x-forwarded-for": `10.21.${tag.length}.${ip++}` } });
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
// تاريخ الرياض بعد n يوم (YYYY-MM-DD)
const riyadhPlus = (n: number) => new Date(Date.now() + 3 * 3_600_000 + n * 86_400_000).toISOString().slice(0, 10);

test("تذكير انتهاء رمز Netlify: باقي/قريب/منتهي، ولا يظهر للزوار", async ({ browser }, info) => {
  const coachEmail = `coach-ops-${info.project.name}@e2e.test`;
  const coach = await newPage(browser, info.project.name);
  await login(coach, coachEmail, "/admin");
  await db.query(`UPDATE "user" SET role = 'coach' WHERE email = $1`, [coachEmail]);
  await coach.goto("/admin/content#ops");
  const box = coach.getByTestId("ops-settings");
  const date = box.getByLabel("تاريخ انتهاء رمز Netlify");
  const save = async (d: string) => {
    await date.fill(d);
    await box.getByRole("button", { name: "حفظ" }).click();
    await expect(box.getByText(/تم/)).toBeVisible();
    await coach.reload();
  };

  await save(riyadhPlus(365));
  await expect(box.getByTestId("token-status")).toHaveText("صالح، باقي 365 يوم.");
  await expect(date).toHaveValue(riyadhPlus(365));
  await save(riyadhPlus(10));
  await expect(box.getByTestId("token-status")).toHaveText("ينتهي بعد 10 يوم. جدّديه الآن.");
  await save(riyadhPlus(-2));
  await expect(box.getByTestId("token-status")).toHaveText("انتهى الرمز قبل 2 يوم. جدّديه الآن.");

  const { rows: [row] } = await db.query("SELECT is_public FROM site_settings WHERE key = 'ops'");
  expect(row.is_public).toBe(false);
  await save(riyadhPlus(365));
});
