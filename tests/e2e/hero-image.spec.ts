// صورة الواجهة المرفوعة تظهر كاملة بدون قص (نفس نسبة الأبعاد الأصلية) على الأجهزة الثلاثة (قاعدة nav_e2e).
import { test, expect, type Page, type Browser } from "@playwright/test";
import pg from "pg";

const OWNER = process.env.E2E_DATABASE_URL_OWNER ?? "postgres://nav_owner:nav_owner_dev@localhost:5432/nav_e2e";
const db = new pg.Pool({ connectionString: OWNER, max: 2 });
test.afterAll(async () => { await db.end(); });

let ip = 60;
async function newPage(browser: Browser, tag: string) {
  const ctx = await browser.newContext({ ...test.info().project.use, extraHTTPHeaders: { "x-forwarded-for": `10.18.${tag.length}.${ip++}` } });
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


test("صورة الواجهة: عريضة وطويلة تظهر كاملة بدون قص", async ({ browser }, info) => {
  const project = info.project.name;
  const sharp = (await import("sharp")).default;
  const coachEmail = `coach-hero-${project}@e2e.test`;
  const coach = await newPage(browser, project + "-c");
  await login(coach, coachEmail, "/admin");
  await db.query(`UPDATE "user" SET role = 'coach' WHERE email = $1`, [coachEmail]);

  for (const [w, h, tag] of [[1600, 800, "عريضة"], [700, 1100, "طويلة"]] as const) {
    const png = await sharp({ create: { width: w, height: h, channels: 3, background: { r: 40, g: 90, b: 160 } } }).png().toBuffer();
    await coach.goto("/admin/media");
    const form = coach.locator("form", { has: coach.getByRole("button", { name: "رفع الصورة" }) });
    await form.locator('input[name="file"]').setInputFiles({ name: `${tag}.png`, mimeType: "image/png", buffer: png });
    await form.locator('input[name="alt"]').fill(`صورة ${tag} ${project}`);
    await form.locator('select[name="usage"]').selectOption("hero");
    await form.locator('input[name="rights_note"]').fill("صورة اختبار");
    await form.locator('input[name="approved"]').check();
    await form.getByRole("button", { name: "رفع الصورة" }).click();
    await expect(coach.getByText(`صورة ${tag} ${project}`).first()).toBeVisible();

    await coach.goto("/admin/content#hero");
    await coach.locator('select[name="media_id"]').selectOption({ label: `صورة ${tag} ${project}` });
    await coach.getByRole("button", { name: "حفظ صورة الواجهة" }).click();
    const { rows: [media] } = await db.query(`SELECT id FROM media_assets WHERE alt = $1`, [`صورة ${tag} ${project}`]);
    await expect.poll(async () => (await db.query(`SELECT value->>'media_id' AS m FROM site_settings WHERE key = 'hero_image'`)).rows[0]?.m ?? null).toBe(media.id);

    const visitor = await newPage(browser, project + "-v" + tag);
    await visitor.goto("/");
    const img = visitor.locator(".hero-photo img");
    await expect(img).toBeVisible();
    await expect.poll(() => img.evaluate((e: HTMLImageElement) => e.complete && e.naturalWidth > 0)).toBe(true);
    const r = await img.evaluate((e: HTMLImageElement) => ({ nw: e.naturalWidth, nh: e.naturalHeight, w: e.getBoundingClientRect().width, h: e.getBoundingClientRect().height,
      fit: getComputedStyle(e).objectFit, clip: getComputedStyle(e.parentElement!).clipPath }));
    // الصورة تُعرض بنسبتها الأصلية (أو داخل صندوق أصغر بنفس النسبة)، بدون قص ولا شكل مائل
    const drawn = Math.min(r.w / r.nw, r.h / r.nh);
    expect(Math.abs(r.w / r.h - r.nw / r.nh) < 0.02 || r.fit === "contain", JSON.stringify(r)).toBe(true);
    expect(Math.abs(r.w / r.nw - drawn) < 0.02 || Math.abs(r.h / r.nh - drawn) < 0.02).toBe(true);
    expect(r.clip).toBe("none");
    await noHorizontalScroll(visitor);
    if (tag === "عريضة") await visitor.locator(".hero").screenshot({ path: `${process.env.SHOT_DIR ?? "/tmp"}/hero-${project}.png` });
  }
  // نرجع الرسم الافتراضي
  await coach.goto("/admin/content#hero");
  await coach.locator('select[name="media_id"]').selectOption("");
  await coach.getByRole("button", { name: "حفظ صورة الواجهة" }).click();
  await expect.poll(async () => (await db.query(`SELECT value->>'media_id' AS m FROM site_settings WHERE key = 'hero_image'`)).rows[0]?.m ?? null).toBeNull();
});
