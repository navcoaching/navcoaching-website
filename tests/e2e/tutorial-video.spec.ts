// فيديو «كيف تستخدم الموقع»: زر في الصفحة الرئيسية يفتح يوتيوب في نافذة منبثقة، ويُضبط من «المحتوى والإعدادات» (قاعدة nav_e2e).
import { test, expect, type Page, type Browser } from "@playwright/test";
import pg from "pg";

const OWNER = process.env.E2E_DATABASE_URL_OWNER ?? "postgres://nav_owner:nav_owner_dev@localhost:5432/nav_e2e";
const db = new pg.Pool({ connectionString: OWNER, max: 2 });
test.afterAll(async () => { await db.end(); });

let ip = 60;
async function newPage(browser: Browser, tag: string) {
  const ctx = await browser.newContext({ ...test.info().project.use, extraHTTPHeaders: { "x-forwarded-for": `10.17.${tag.length}.${ip++}` } });
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


test("فيديو شرح الموقع: مخفي بدون رابط، والمدربة تضيفه، ويفتح في نافذة منبثقة", async ({ browser }, info) => {
  const project = info.project.name;
  const coachEmail = `coach-tut-${project}@e2e.test`;
  const coach = await newPage(browser, project + "-c");
  await login(coach, coachEmail, "/admin");
  await db.query(`UPDATE "user" SET role = 'coach' WHERE email = $1`, [coachEmail]);
  await coach.goto("/admin/content#tutorial");
  const box = coach.getByTestId("tutorial-video-settings");
  // بدون رابط: الزر مخفي
  await box.getByLabel("رابط الفيديو على يوتيوب").fill("");
  await box.getByRole("button", { name: "حفظ" }).click();
  await expect(box.getByText(/تم/)).toBeVisible();
  const visitor = await newPage(browser, project + "-v");
  await visitor.goto("/");
  await expect(visitor.getByTestId("tutorial-video")).toHaveCount(0);

  // رابط غير صالح يُرفض، ثم رابط صحيح
  await coach.reload();
  await box.getByLabel("رابط الفيديو على يوتيوب").fill("https://example.com/video.mp4");
  await box.getByRole("button", { name: "حفظ" }).click();
  await expect(box.getByText("الرابط غير صالح")).toBeVisible();
  await box.getByLabel("رابط الفيديو على يوتيوب").fill("https://youtu.be/dQw4w9WgXcQ");
  await box.getByLabel("نص الزر").fill("كيف تستخدم الموقع");
  await box.getByRole("button", { name: "حفظ" }).click();
  await expect(box.getByText(/تم/)).toBeVisible();

  // الزائر: الزر ظاهر ويفتح الفيديو داخل الموقع
  await visitor.goto("/");
  const btn = visitor.getByTestId("tutorial-video");
  await expect(btn).toHaveText("▶ كيف تستخدم الموقع");
  await btn.click();
  const frame = visitor.getByTestId("video-iframe");
  await expect(frame).toBeVisible();
  await expect(frame).toHaveAttribute("src", /youtube-nocookie\.com\/embed\/dQw4w9WgXcQ/);
  await visitor.getByRole("button", { name: "إغلاق الفيديو" }).click();
  await expect(frame).toHaveCount(0);
  await noHorizontalScroll(visitor);
});
