// سياسة السكربتات الصارمة (nonce) على الصفحات الخاصة: الترويسة كاملة، ولا سكربت محجوب، والصفحات تشتغل بعد الدخول.
import { test, expect, type Page, type Browser } from "@playwright/test";
import pg from "pg";

const OWNER = process.env.E2E_DATABASE_URL_OWNER ?? "postgres://nav_owner:nav_owner_dev@localhost:5432/nav_e2e";
const db = new pg.Pool({ connectionString: OWNER, max: 2 });
test.afterAll(async () => { await db.end(); });

let ip = 10;
async function newPage(browser: Browser) {
  const ctx = await browser.newContext({ ...test.info().project.use, extraHTTPHeaders: { "x-forwarded-for": `10.47.${test.info().project.name.length}.${ip++}` } });
  const page = await ctx.newPage();
  const blocked: string[] = [];
  page.on("console", (m) => { if (/Content Security Policy/i.test(m.text())) blocked.push(m.text()); });
  return { page, blocked };
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
const scriptSrc = (csp: string) => csp.match(/script-src [^;]+/)?.[0] ?? "";

test("الصفحات الخاصة: nonce بدل unsafe-inline مع باقي السياسة كاملة", async ({ request }) => {
  for (const path of ["/login", "/account", "/admin", "/checkout"]) {
    const csp = (await request.get(path, { maxRedirects: 0 })).headers()["content-security-policy"] ?? "";
    expect(scriptSrc(csp), path).toMatch(/'nonce-[A-Za-z0-9+/=]{20,}' 'strict-dynamic'/);
    expect(scriptSrc(csp), path).not.toContain("unsafe-inline");
    for (const d of ["default-src 'self'", "frame-ancestors 'none'", "form-action 'self'", "object-src 'none'", "base-uri 'self'"]) expect(csp, path).toContain(d);
  }
  const a = (await request.get("/login")).headers()["content-security-policy"];
  const b = (await request.get("/login")).headers()["content-security-policy"];
  expect(a).not.toBe(b); // nonce جديد لكل طلب
});

test("الصفحات العامة: السياسة كما هي (تبقى ثابتة)", async ({ request }) => {
  const csp = (await request.get("/")).headers()["content-security-policy"] ?? "";
  expect(scriptSrc(csp)).toContain("'unsafe-inline'");
  expect(scriptSrc(csp)).not.toContain("nonce-");
});

test("الدخول وحساب المتدرب ولوحة المدربة تشتغل بدون سكربت محجوب", async ({ browser }) => {
  const p = test.info().project.name;
  const { page, blocked } = await newPage(browser);
  await login(page, `csp-${p}@e2e.test`, "/account");
  await expect(page).toHaveURL(/\/account/);
  await expect(page.locator("html")).toHaveClass(/\bjs\b/); // سكربت الثيم (مسموح بالـ hash) اشتغل
  await page.reload();
  await expect(page.locator("main")).toBeVisible();

  const coachEmail = `csp-coach-${p}@e2e.test`;
  const coach = await newPage(browser);
  await login(coach.page, coachEmail, "/account");
  await db.query(`UPDATE "user" SET role = 'coach' WHERE email = $1`, [coachEmail]);
  await coach.page.goto("/admin");
  await expect(coach.page).toHaveURL(/\/admin/);
  await expect(coach.page.locator("main")).toBeVisible();

  expect([...blocked, ...coach.blocked]).toEqual([]);
});
