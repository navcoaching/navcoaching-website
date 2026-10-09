// التطبيق من المتصفح (PWA): إشعارات الجوال (محاكاة PUSH_MOCK)، الاختصارات، Service Worker، وصفحة عدم الاتصال. قاعدة nav_e2e.
import { test, expect, type Page, type Browser } from "@playwright/test";
import pg from "pg";

const OWNER = process.env.E2E_DATABASE_URL_OWNER ?? "postgres://nav_owner:nav_owner_dev@localhost:5432/nav_e2e";
const db = new pg.Pool({ connectionString: OWNER, max: 2 });
test.afterAll(async () => { await db.end(); });

let ip = 220;
async function newPage(browser: Browser, tag: string) {
  const ctx = await browser.newContext({ ...test.info().project.use, extraHTTPHeaders: { "x-forwarded-for": `10.14.${tag.length}.${ip++}` } });
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

test("إشعارات الجوال: التفعيل، التجربة، وصول تنبيه المدربة، والإيقاف", async ({ browser }, info) => {
  const project = info.project.name;
  const email = `trainee-push-${project}@e2e.test`;
  const page = await newPage(browser, project);
  await login(page, email);

  // طلب متابعة نشط مع جدول مراجعة (للتنبيه من المدربة)
  const { rows: [u] } = await db.query(`SELECT id FROM "user" WHERE email = $1`, [email]);
  const { rows: [p] } = await db.query(`SELECT p.id, p.name, o.id AS offer_id, o.label, o.price_halalas FROM products p JOIN product_offers o ON o.product_id = p.id WHERE p.slug = 'intensive' AND o.months = 3`);
  const orderNo = (await db.query("SELECT app.new_order_no() AS no")).rows[0].no as string;
  const { rows: [o] } = await db.query(
    `INSERT INTO orders (order_no, user_id, product_id, offer_id, category, product_name, offer_label, months, list_price_halalas, amount_due_halalas, status,
                         contact_name, contact_phone, idempotency_key, paid_at, sub_start_at, sub_end_at, review_weekday)
     VALUES ($1,$2,$3,$4,'follow',$5,$6,3,$7,$7,'active','ريم إشعارات','+966500000000',$1, now(), now() - interval '10 days', now() + interval '80 days', 1) RETURNING id`,
    [orderNo, u.id, p.id, p.offer_id, p.name, p.label, p.price_halalas]);
  await db.query(`INSERT INTO blocks (order_id, user_id, name, start_date, weeks) VALUES ($1,$2,'بلوك',(now() AT TIME ZONE 'Asia/Riyadh')::date,4)`, [o.id, u.id]);

  await page.goto("/account");
  const card = page.getByTestId("push-card");
  await expect(card).toHaveAttribute("data-state", "off");
  await card.getByRole("button", { name: "فعّل الإشعارات على هذا الجهاز" }).click();
  await expect(card).toContainText("تم تفعيل الإشعارات");
  await expect(card).toHaveAttribute("data-state", "on");
  const subs = (await db.query(`SELECT device FROM push_subscriptions WHERE user_id = $1`, [u.id])).rows;
  expect(subs.length).toBe(1);
  await card.getByRole("button", { name: "إرسال تجربة" }).click();
  await expect(card).toContainText("أرسلنا إشعار تجربة");
  // خيار الإشعارات في تفضيلات التواصل
  await expect(page.getByTestId("prefs-form").getByLabel("إشعارات الجوال (التطبيق)")).toBeChecked();
  await noHorizontalScroll(page);

  // المدربة ترسل تنبيه المراجعة: يُسجَّل بقناة push بجانب البريد
  const coachEmail = `coach-push-${project}@e2e.test`;
  const coach = await newPage(browser, project + "-c");
  await login(coach, coachEmail, "/admin");
  await db.query(`UPDATE "user" SET role = 'coach' WHERE email = $1`, [coachEmail]);
  await coach.goto(`/admin/orders/${orderNo}`);
  coach.once("dialog", (d) => d.accept());
  await coach.getByRole("button", { name: "إرسال تنبيه المراجعة الآن" }).click();
  await expect.poll(async () => (await db.query(
    `SELECT status FROM notification_log WHERE order_id = $1 AND channel = 'push' ORDER BY id DESC LIMIT 1`, [o.id])).rows[0]?.status).toBe("sent");

  // لوحة الإدارة: توليد مفاتيح الإشعارات (تُعرض مرة للنسخ، ولا تُحفظ)
  await coach.goto("/admin/content");
  const vapid = coach.getByTestId("vapid");
  await vapid.getByRole("button", { name: "توليد مفاتيح الإشعارات" }).click();
  await expect(vapid).toContainText("NEXT_PUBLIC_VAPID_PUBLIC_KEY");
  await expect(vapid).toContainText("VAPID_PRIVATE_KEY");
  await expect(vapid).toContainText(`mailto:${coachEmail}`);
  expect((await vapid.locator(".vapid-row code").first().textContent())!.length).toBeGreaterThan(60);
  await noHorizontalScroll(coach);

  // الإيقاف يحذف الاشتراك
  await page.reload();
  await page.getByTestId("push-card").getByRole("button", { name: "إيقاف" }).click();
  await expect(page.getByTestId("push-card")).toHaveAttribute("data-state", "off");
  expect((await db.query(`SELECT count(*)::int n FROM push_subscriptions WHERE user_id = $1`, [u.id])).rows[0].n).toBe(0);

  // اختصار أيقونة التطبيق يفتح برنامج الاشتراك الحالي
  await page.goto("/account/go/training");
  await expect(page).toHaveURL(new RegExp(`/account/orders/${orderNo}/training`));
  await page.goto("/account/go/unknown");
  await expect(page).toHaveURL(/\/account$/);
});

test("الـ Manifest والاختصارات وملف Service Worker وصفحة عدم الاتصال", async ({ request, browser }, info) => {
  const m = await (await request.get("/manifest.webmanifest")).json();
  expect(m.display).toBe("standalone");
  expect(m.shortcuts.map((s: { url: string }) => s.url)).toEqual(["/account/go/training", "/account/go/food", "/account/go/checkin", "/account/go/progress"]);
  const sw = await request.get("/sw.js");
  expect(sw.status()).toBe(200);
  expect(sw.headers()["content-type"]).toContain("javascript");
  expect(sw.headers()["cache-control"]).toContain("no-cache");
  expect(await sw.text()).toContain("notificationclick");

  const page = await newPage(browser, info.project.name + "-o");
  await page.goto("/offline");
  await expect(page.getByRole("heading", { name: "لا يوجد اتصال بالإنترنت" })).toBeVisible();
  await noHorizontalScroll(page);
  await page.goto("/install");
  await expect(page.getByTestId("install-after")).toContainText("إشعارات الجوال");
});

test("Service Worker يعمل فعلياً: يُسجَّل ويتحكم بالصفحة، وصفحة عدم الاتصال محفوظة للاحتياط", async ({ browser }, info) => {
  const ctx = await browser.newContext({ ...info.project.use, serviceWorkers: "allow" });
  const page = await ctx.newPage();
  await page.goto("/");
  const scope = await page.evaluate(async () => (await navigator.serviceWorker.ready).scope);
  expect(scope).toMatch(/\/$/);
  await page.reload(); // الصفحة صارت تحت تحكم الـ Service Worker
  await expect.poll(() => page.evaluate(() => Boolean(navigator.serviceWorker.controller))).toBe(true);
  // التنقل العادي يمر على الشبكة (لا تُخزَّن الصفحات)
  await page.goto("/programs");
  await expect(page).toHaveURL(/\/programs$/);
  // الصفحة الاحتياطية الوحيدة في الذاكرة: /offline (تظهر عند انقطاع النت)
  const cached = await page.evaluate(async () => {
    const keys = await caches.keys();
    const c = await caches.open(keys[0]);
    const reqs = (await c.keys()).map((r) => new URL(r.url).pathname).sort();
    const off = await c.match("/offline");
    return { keys, reqs, hasHeading: (await off?.text())?.includes("لا يوجد اتصال بالإنترنت") };
  });
  expect(cached.keys).toEqual(["nav-offline-v1"]);
  expect(cached.reqs).toEqual(["/icons/icon-192.png", "/offline"]);
  expect(cached.hasHeading).toBe(true);
  await ctx.close();
});
