// محرر البرنامج: الترتيب بالأرقام، قوائم العضلة للتمرين المحفوظ، قسم التمارين التأهيلية، والأيام مطوية تلقائياً (قاعدة nav_e2e).
import { test, expect, type Page, type Browser } from "@playwright/test";
import pg from "pg";

const OWNER = process.env.E2E_DATABASE_URL_OWNER ?? "postgres://nav_owner:nav_owner_dev@localhost:5432/nav_e2e";
const db = new pg.Pool({ connectionString: OWNER, max: 2 });
test.afterAll(async () => { await db.end(); });

let ip = 120;
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

test("محرر البرنامج: ترتيب بالأرقام، قوائم التمرين المحفوظ، القسم التأهيلي", async ({ browser }, info) => {
  const project = info.project.name;
  const email = `coach-editor-${project}@e2e.test`;
  const coach = await newPage(browser, project + "-c");
  await login(coach, email, "/admin");
  await db.query(`UPDATE "user" SET role = 'coach' WHERE email = $1`, [email]);
  const names = ["Back Squat", "Bodyweight Squat", "Glute Bridge"];
  const ids: string[] = [];
  for (const n of names) ids.push((await db.query(`SELECT id FROM exercises WHERE name = $1`, [n])).rows[0].id);
  const { rows: [t] } = await db.query(`INSERT INTO program_templates (name, weeks) VALUES ($1, 2) RETURNING id`, [`قالب ترتيب ${project} ${Date.now()}`]);
  const { rows: [d] } = await db.query(`INSERT INTO template_days (template_id, day_no, title) VALUES ($1, 1, 'DAY 1') RETURNING id`, [t.id]);
  for (const [i, id] of ids.entries()) {
    await db.query(`INSERT INTO template_items (day_id, position, exercise_id, plan) VALUES ($1,$2,$3,$4)`,
      [d.id, i, id, JSON.stringify([{ sets: 3, reps: [10, 10, 10], rir: 2 }, { sets: 3, reps: [10, 10, 10], rir: 2 }])]);
  }
  const order = async () => (await db.query(`SELECT e.name FROM template_items i JOIN exercises e ON e.id = i.exercise_id WHERE i.day_id = $1 ORDER BY i.position`, [d.id])).rows.map((r) => r.name as string);

  await coach.goto(`/admin/templates/${t.id}`);
  const day1 = coach.getByTestId("day-1");
  // مطوي تلقائياً
  await expect(day1.getByLabel("اليوم 1")).toBeHidden();
  await day1.getByTestId("fold-1").click();
  await expect(day1.getByLabel("اليوم 1")).toBeVisible();

  // 1) نقل التمرين الثالث للمركز الأول برقم (بدون أزرار أعلى/أسفل)
  await expect(day1.getByRole("button", { name: /لأعلى|لأسفل/ })).toHaveCount(0);
  const third = day1.locator(".program-items > li").nth(2);
  await third.locator("summary").click();
  await expect(third.getByLabel(/^الترتيب في اليوم/)).toHaveValue("3");
  await third.getByLabel(/^الترتيب في اليوم/).fill("1");
  await third.getByRole("button", { name: "حفظ التمرين" }).click();
  await expect.poll(order).toEqual(["Glute Bridge", "Back Squat", "Bodyweight Squat"]);

  // 2) قوائم العضلة للتمرين المحفوظ: معبأة بالتمرين الحالي، وتغييرها يحفظ التمرين الجديد
  await coach.reload();
  await day1.getByTestId("fold-1").click();
  const first = day1.locator(".program-items > li").nth(0);
  await first.locator("summary").click();
  const ped = first.getByTestId("exercise-picker");
  await expect(ped.getByLabel(/^\d+ العضلة$/)).toHaveValue("Glutes / المؤخرة");
  await expect(ped.getByLabel(/^التمرين/)).toHaveValue(ids[2]);
  await ped.getByLabel(/^\d+ العضلة$/).selectOption("Hamstrings / الخلفية");
  const hamOptions = ped.getByLabel(/^التمرين/).locator("option");
  expect(await hamOptions.count()).toBeGreaterThan(3);
  const rdl = (await db.query(`SELECT id, name FROM exercises WHERE primary_muscle = 'Hamstrings / الخلفية' AND status = 'approved' ORDER BY name LIMIT 1`)).rows[0];
  await ped.getByLabel(/^التمرين/).selectOption(rdl.id);
  await first.getByRole("button", { name: "حفظ التمرين" }).click();
  await expect.poll(order).toEqual([rdl.name, "Back Squat", "Bodyweight Squat"]);

  // 3) إضافة تمرين برقم ترتيب (الثاني) + القسم التأهيلي بحالة الركبة
  await coach.reload();
  await day1.getByTestId("fold-1").click();
  await day1.getByText("+ إضافة تمرين").click();
  const pick = day1.locator("details.add-item").getByTestId("exercise-picker");
  await pick.getByLabel("القسم").selectOption("rehab");
  const cond = pick.getByLabel("الحالة");
  await expect(cond).toContainText("Patellar Tendinopathy");
  await expect(cond).toContainText("Patellofemoral Pain");
  await expect(cond).toContainText("Lateral Elbow Tendinopathy");
  await cond.selectOption({ label: /Patellar Tendinopathy/ as unknown as string }).catch(async () => {
    const v = await cond.locator("option", { hasText: "Patellar Tendinopathy" }).first().getAttribute("value");
    await cond.selectOption(v!);
  });
  const list = pick.getByLabel(/^التمرين/);
  await expect(list).toContainText("Wall Sit (Isometric Quad Hold)");
  await expect(list).toContainText("Slow Leg Press (Heavy Slow Resistance)");
  await expect(list).not.toContainText("Tyler Twist");
  await list.selectOption({ label: "Wall Sit (Isometric Quad Hold) — وزن الجسم" });
  await day1.locator("details.add-item").getByLabel("الترتيب في اليوم").fill("2");
  await day1.locator("details.add-item").getByLabel("المجموعات × التكرارات").fill("4x40");
  await day1.locator("details.add-item").getByRole("button", { name: "إضافة", exact: true }).click();
  await expect.poll(order).toEqual([rdl.name, "Wall Sit (Isometric Quad Hold)", "Back Squat", "Bodyweight Squat"]);
  await noHorizontalScroll(coach);
  await coach.screenshot({ path: `${process.env.SHOT_DIR ?? "/tmp"}/editor-${project}.png`, fullPage: false });
  await db.query(`DELETE FROM program_templates WHERE id = $1`, [t.id]);
});
