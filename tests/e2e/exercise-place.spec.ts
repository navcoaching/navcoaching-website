// محرر البرنامج: الترتيب بالأرقام، قوائم العضلة للتمرين المحفوظ، قسم التمارين التأهيلية، والأيام مطوية تلقائياً (قاعدة nav_e2e).
import { test, expect, type Page, type Browser } from "@playwright/test";
import pg from "pg";

const OWNER = process.env.E2E_DATABASE_URL_OWNER ?? "postgres://nav_owner:nav_owner_dev@localhost:5432/nav_e2e";
const db = new pg.Pool({ connectionString: OWNER, max: 2 });
test.afterAll(async () => { await db.end(); });

let ip = 140;
async function newPage(browser: Browser, tag: string) {
  const ctx = await browser.newContext({ ...test.info().project.use, extraHTTPHeaders: { "x-forwarded-for": `10.22.${tag.length}.${ip++}` } });
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

test("قالب البيت: الإضافة من تمارين البيت فقط، وتمرين النادي مرفوض", async ({ browser }, info) => {
  const project = info.project.name;
  const email = `coach-place-${project}@e2e.test`;
  const coach = await newPage(browser, project + "-p");
  await login(coach, email, "/admin");
  await db.query(`UPDATE "user" SET role = 'coach' WHERE email = $1`, [email]);
  const { rows: [t] } = await db.query(`INSERT INTO program_templates (name, weeks) VALUES ($1, 2) RETURNING id`, [`قالب بيت ${project} ${Date.now()}`]);
  const { rows: [d] } = await db.query(`INSERT INTO template_days (template_id, day_no, title) VALUES ($1, 1, 'DAY 1') RETURNING id`, [t.id]);
  const idOf = async (n: string) => (await db.query(`SELECT id, place FROM exercises WHERE name = $1`, [n])).rows[0] as { id: string; place: string };
  const [squat, legExt] = [await idOf("Back Squat"), await idOf("Leg Extension")];
  expect([squat.place, legExt.place]).toEqual(["منزل", "نادي"]);

  // القالب للنادي افتراضياً: تمرين الجهاز متاح في القائمة
  await coach.goto(`/admin/templates/${t.id}`);
  const day1 = coach.getByTestId("day-1");
  const addSelect = () => day1.locator(".add-item").getByTestId("exercise-picker").locator('select[name="exercise_id"] option');
  const ids = async () => addSelect().evaluateAll((os) => os.map((o) => (o as HTMLOptionElement).value));
  await day1.getByTestId("fold-1").click();
  await day1.getByText("+ إضافة تمرين").click();
  expect(await ids()).toContain(legExt.id);

  // تحويله للبيت من «بيانات القالب»
  await coach.getByText("بيانات القالب").click();
  await coach.getByTestId("template-place").selectOption("منزل");
  await coach.getByRole("button", { name: "حفظ", exact: true }).first().click();
  await expect.poll(async () => (await db.query(`SELECT place FROM program_templates WHERE id = $1`, [t.id])).rows[0].place).toBe("منزل");
  await coach.reload();
  await day1.getByTestId("fold-1").click();
  await day1.getByText("+ إضافة تمرين").click();
  const list = await ids();
  expect(list).toContain(squat.id);
  expect(list).not.toContain(legExt.id);

  // كتابة اسم تمرين النادي يدوياً: الخادم يرفضه
  const form = day1.locator(".add-item form");
  await form.locator('input[name="exercise"]').fill("Leg Extension");
  await form.locator('input[name="reps"]').fill("3x12");
  await form.getByRole("button", { name: "إضافة" }).click();
  await expect(form.getByText(/تمرين نادي، والبرنامج للبيت/)).toBeVisible();
  // تمرين البيت يُضاف عادي
  await form.locator('input[name="exercise"]').fill("Back Squat");
  await form.getByRole("button", { name: "إضافة" }).click();
  await expect.poll(async () => (await db.query(`SELECT count(*)::int n FROM template_items WHERE day_id = $1`, [d.id])).rows[0].n).toBe(1);
  await noHorizontalScroll(coach);
});
