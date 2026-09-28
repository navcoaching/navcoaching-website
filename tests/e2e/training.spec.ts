// منصة التدريب: المدربة تبني قالباً من المكتبة وتسنده، المتدرب يسجّل ويبدّل تمريناً ببديله،
// والمدربة ترى تنبيه التبديل عند اسم المتدرب في صفحة الأعضاء. كل البيانات في قاعدة nav_e2e المنفصلة.
import { test, expect, type Page, type Browser } from "@playwright/test";
import pg from "pg";

const OWNER = process.env.E2E_DATABASE_URL_OWNER ?? "postgres://nav_owner:nav_owner_dev@localhost:5432/nav_e2e";
const db = new pg.Pool({ connectionString: OWNER, max: 2 });
test.afterAll(async () => { await db.end(); });

let ip = 50;
async function newPage(browser: Browser, tag: string) {
  const ctx = await browser.newContext({ ...test.info().project.use, extraHTTPHeaders: { "x-forwarded-for": `10.8.${tag.length}.${ip++}` } });
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
/** طلب متابعة نشط للمتدرب (بدون المرور بالدفع) */
async function activeOrder(email: string, name: string) {
  const { rows: [u] } = await db.query(`SELECT id FROM "user" WHERE email = $1`, [email]);
  const { rows: [p] } = await db.query(
    `SELECT p.id, p.name, o.id AS offer_id, o.label, o.price_halalas FROM products p JOIN product_offers o ON o.product_id = p.id WHERE p.slug = 'intensive' AND o.months = 3`);
  const orderNo = (await db.query("SELECT app.new_order_no() AS no")).rows[0].no as string;
  await db.query(
    `INSERT INTO orders (order_no, user_id, product_id, offer_id, category, product_name, offer_label, months, list_price_halalas,
                         amount_due_halalas, status, contact_name, contact_phone, idempotency_key, paid_at)
     VALUES ($1,$2,$3,$4,'follow',$5,$6,3,$7,$7,'active',$8,'+966512345678',$9, now())`,
    [orderNo, u.id, p.id, p.offer_id, p.name, p.label, p.price_halalas, name, `k-${orderNo}-training`]);
  return orderNo;
}

test("منصة التدريب: قالب، إسناد، تسجيل، تبديل تمرين وتنبيه المدربة، التقدم", async ({ browser }, info) => {
  const project = info.project.name;
  const coachEmail = `coach-tr-${project}@e2e.test`;
  const traineeEmail = `trainee-tr-${project}@e2e.test`;
  const name = `سارة تدريب ${project}`;
  const tplName = `قالب اختبار ${project}`;

  // ---------- المدربة: المكتبة والقالب ----------
  const coach = await newPage(browser, project + "-c");
  await login(coach, coachEmail, "/admin");
  await db.query(`UPDATE "user" SET role = 'coach' WHERE email = $1`, [coachEmail]);
  await coach.goto("/admin/exercises?q=squat");
  await expect(coach.getByTestId("admin-exercises")).toContainText("Back Squat");
  // فحص روابط الفيديو من يوتيوب (مرة واحدة على الكمبيوتر فقط حتى ما نكرر الطلبات)
  if (project === "desktop") {
    const vc = coach.getByTestId("video-check");
    await vc.getByRole("button", { name: "افحص الآن" }).click();
    await expect(vc).toContainText(/كل المقاطع \(\d+\) تشتغل|من \d+ تشتغل/, { timeout: 120_000 });
  }
  // الفلاتر المتسلسلة في المكتبة (تُرسل تلقائياً عند التغيير)
  await coach.goto("/admin/exercises");
  await coach.getByLabel("العضلة").selectOption("Quadriceps / الأمامية");
  await coach.waitForURL(/primary_muscle=/);
  await coach.getByLabel("نمط الحركة").selectOption("Squat (Knee-dominant) / سكوات (هيمنة الركبة)");
  await coach.waitForURL(/pattern=/);
  await coach.getByLabel("النمط الفرعي / زاوية الحركة").selectOption("Leg Press / ضغط الأرجل");
  await coach.waitForURL(/sub_pattern=/);
  await expect(coach.getByTestId("admin-exercises")).toContainText("Mid Leg Press");
  await expect(coach.getByTestId("admin-exercises")).not.toContainText("Back Squat");
  await noHorizontalScroll(coach);

  await coach.goto("/admin/templates/new");
  await coach.getByLabel("اسم القالب").fill(tplName);
  await coach.getByRole("button", { name: "إنشاء القالب" }).click();
  await expect(coach.getByText("تم إنشاء القالب")).toBeVisible();
  const day1 = coach.getByTestId("day-1");
  const addForm = day1.locator("details.add-item");
  const openAdd = async () => { if ((await addForm.getAttribute("open")) === null) await day1.getByText("+ إضافة تمرين").click(); };
  // 1) بالقوائم المتسلسلة: العضلة ← النمط ← النمط الفرعي ← الحركة التشريحية ← التمرين
  await openAdd();
  const picker = day1.getByTestId("exercise-picker");
  await picker.getByLabel("العضلة").selectOption("Quadriceps / الأمامية");
  await picker.getByLabel("نمط الحركة").selectOption("Squat (Knee-dominant) / سكوات (هيمنة الركبة)");
  await picker.getByLabel("النمط الفرعي / زاوية الحركة").selectOption("Free / Bodyweight Squat / سكوات حر أو بوزن الجسم");
  await expect(picker.getByLabel("الحركة التشريحية الأساسية")).toContainText("Knee Extension + Hip Extension");
  const exSelect = picker.getByLabel(/^التمرين/);
  await expect(exSelect).not.toContainText("Leg Extension");
  await exSelect.selectOption({ label: "Back Squat — بار" });
  await day1.getByLabel("المجموعات × التكرارات").fill("3x10");
  await day1.getByLabel("RIR", { exact: true }).fill("2");
  await day1.getByRole("button", { name: "إضافة", exact: true }).click();
  await expect(day1.locator(".program-items")).toContainText("Back Squat");
  // 2) بالبحث بالاسم
  await openAdd();
  await picker.getByLabel("العضلة").selectOption("");
  await day1.getByLabel("أو ابحثي بالاسم").fill("Leg Extension");
  await day1.getByLabel("المجموعات × التكرارات").fill("12-12-10");
  await day1.getByLabel("RIR", { exact: true }).fill("1");
  await day1.getByRole("button", { name: "إضافة", exact: true }).click();
  await expect(day1.locator(".program-items")).toContainText("Leg Extension");
  await expect(day1.locator(".program-items")).toContainText("3×10 · RIR 2");
  await noHorizontalScroll(coach);

  // الجولات الأسبوعية لكل عضلة: Back Squat 3 (أمامية) + ½ للمؤخرة والأفخاذ الداخلية، Leg Extension 3 (أمامية)
  await coach.reload();
  const vol = coach.getByTestId("volume");
  const quads = vol.locator("tr", { has: coach.locator("th", { hasText: /^Quadriceps$/ }) });
  await expect(quads.locator("td").first()).toHaveText("6");
  const glutes = vol.locator("tr", { has: coach.locator("th", { hasText: /^Glutes$/ }) });
  await expect(glutes.locator("td").first()).toHaveText("1.5");
  // الحد الافتراضي 6–20 لكل عضلة: 1.5 أقل من الحد
  await expect(glutes.locator("td").first()).toHaveClass(/vol-low/);
  await expect(glutes.locator("td").last()).toHaveText("6–20");
  // حد أدنى 10 للأمامية ← يتلوّن الرقم
  await vol.getByText("تعديل الحدود لكل عضلة").click();
  await vol.getByLabel("الحد الأدنى — Quadriceps").fill("10");
  await vol.getByLabel("الحد الأعلى — Quadriceps").fill("20");
  await vol.getByRole("button", { name: "حفظ الحدود" }).click();
  await expect(vol.getByText("تم حفظ الحدود")).toBeVisible();
  await coach.reload();
  await expect(coach.getByTestId("volume").locator("tr", { has: coach.locator("th", { hasText: /^Quadriceps$/ }) }).locator("td").first()).toHaveClass(/vol-low/);
  await noHorizontalScroll(coach);

  // ---------- الإسناد لطلب نشط ----------
  const trainee = await newPage(browser, project + "-t");
  await login(trainee, traineeEmail);
  const orderNo = await activeOrder(traineeEmail, name);
  await coach.goto(`/admin/orders/${orderNo}`);
  await coach.getByTestId("program-card").getByRole("link", { name: "إسناد برنامج" }).click();
  await coach.getByLabel("القالب").selectOption({ label: `${tplName} (5 أسابيع)` });
  await coach.getByRole("button", { name: "إسناد البرنامج" }).click();
  await expect(coach.getByText("تم إسناد البرنامج")).toBeVisible();
  await expect(coach.getByRole("heading", { name: "الأيام والتمارين" })).toBeVisible();
  await noHorizontalScroll(coach);

  // ---------- المتدرب: التسجيل ----------
  // «برنامجي» في حسابي: أيام تمرين الأسبوع الحالي مباشرة
  await trainee.goto("/account");
  const todayTraining = trainee.getByTestId("today-training");
  await expect(todayTraining).toContainText("برنامجك الحالي");
  await expect(todayTraining.locator("li")).not.toHaveCount(0);
  await expect(trainee.getByRole("heading", { name: "جداولي المجانية" })).toHaveCount(0); // لم يطلب جداول مجانية
  await expect(trainee.getByTestId("volume")).toHaveCount(0); // جدول الجولات للمدربة فقط
  // القائمة الجانبية: طلباتي (الحالية) وجدول التمرين يفتح برنامجه
  const nav = trainee.getByTestId("account-nav");
  await expect(nav.getByRole("link", { name: "طلباتي" })).toHaveAttribute("aria-current", "page");
  await expect(nav.getByRole("link", { name: "جدول التمرين" })).toHaveAttribute("href", `/account/orders/${orderNo}/training`);
  await expect(nav.getByRole("link", { name: "المراجعة الأسبوعية" })).toHaveAttribute("href", `/account/orders/${orderNo}#checkin`);
  await noHorizontalScroll(trainee);
  await trainee.goto(`/account/orders/${orderNo}`);
  await trainee.getByTestId("training-link").click();
  await trainee.waitForURL(/\/training/);
  const card = trainee.getByTestId("exercise-card").first();
  // فيديو التمرين يشتغل في نافذة منبثقة داخل الموقع، والبطاقة ما تنطوي
  await card.getByTestId("exercise-video").click();
  await expect(trainee.getByTestId("video-iframe")).toHaveAttribute("src", /youtube-nocookie\.com\/embed\/[A-Za-z0-9_-]{11}\?autoplay=1/);
  await noHorizontalScroll(trainee);
  await trainee.keyboard.press("Escape");
  await expect(trainee.getByTestId("video-iframe")).toHaveCount(0);
  await expect(card).toHaveAttribute("open", "");
  await expect(card).toContainText("Back Squat");
  await expect(card).toContainText("3×10 · RIR 2");
  // وزن لكل جولة: الجولة الثانية فارغة = نفس وزن الأولى، والتكرارات الفارغة = المستهدف
  await card.getByLabel("وزن الجولة 1").fill("60");
  // الجولات اللي بعدها تتعبّى تلقائياً بنفس الوزن
  await expect(card.getByLabel("وزن الجولة 2")).toHaveValue("60");
  await expect(card.getByLabel("وزن الجولة 3")).toHaveValue("60");
  await card.getByLabel("وزن الجولة 3").fill("65");
  await expect(card.getByLabel("وزن الجولة 2")).toHaveValue("60"); // اللي قبلها ما تتغيّر
  await card.getByLabel("تكرارات الجولة 3").fill("8");
  await expect(card.getByTestId("one-rm")).toContainText("82.5"); // 65 × (1 + 8/30) = 82.3
  // ⧉ تكرار الجولة 3 بنفس الوزن والعدّات، و«+ جولة» تنسخ آخر جولة ثم تتعدّل
  await card.getByRole("button", { name: "تكرار الجولة 3" }).click();
  await expect(card.getByLabel("وزن الجولة 4")).toHaveValue("65");
  await expect(card.getByLabel("تكرارات الجولة 4")).toHaveValue("8");
  await card.getByRole("button", { name: "+ جولة" }).click();
  await expect(card.getByLabel("وزن الجولة 5")).toHaveValue("65");
  await card.getByLabel("وزن الجولة 5").fill("50");
  await card.getByLabel("تكرارات الجولة 5").fill("12");
  await card.getByRole("button", { name: "حفظ", exact: true }).click();
  await expect(card.getByText("تم الحفظ ✅")).toBeVisible();
  await expect(card.getByLabel("مسجّل")).toBeVisible();
  const log = (await db.query(
    `SELECT l.weight::float, l.weights::float[], l.reps, l.week_no FROM item_logs l JOIN block_items i ON i.id = l.block_item_id JOIN block_days d ON d.id = i.day_id
       JOIN blocks b ON b.id = d.block_id JOIN orders o ON o.id = b.order_id WHERE o.order_no = $1`, [orderNo])).rows;
  expect(log).toEqual([{ weight: 65, weights: [60, 60, 65, 65, 50], reps: [10, 10, 8, 8, 12], week_no: 1 }]);
  await trainee.reload();
  await expect(trainee.getByTestId("exercise-card").first().getByLabel("وزن الجولة 3")).toHaveValue("65");
  await expect(trainee.getByTestId("exercise-card").first()).toContainText("أعلى وزن تقديري (1RM): 82.5 كغ");
  await trainee.getByTestId("rate-day").getByRole("radio", { name: "4", exact: true }).check();
  await trainee.getByRole("button", { name: "حفظ التقييم" }).click();
  await expect(trainee.getByText("تم حفظ تقييم اليوم")).toBeVisible();
  await noHorizontalScroll(trainee);
  // بعد حفظ التقييم يرجع تلقائياً لصفحة حسابه الرئيسية
  await trainee.waitForURL(/\/account$/);
  await trainee.goto(`/account/orders/${orderNo}/training`);

  // ---------- المتدرب: تبديل التمرين من القائمة ----------
  // التمرين المسجّل ينطوي بعد إعادة التحميل ← نفتحه بضغطة
  await expect(card).not.toHaveAttribute("open", "");
  await card.locator("summary h3").click();
  const swap = card.locator("[data-testid^='swap-']");
  await swap.getByRole("combobox").selectOption({ label: "Box Squat" });
  trainee.once("dialog", (d) => d.accept());
  await swap.getByRole("button", { name: "تبديل" }).click();
  await expect(trainee.getByText("تم التبديل إلى Box Squat")).toBeVisible();
  await trainee.reload();
  await expect(trainee.getByTestId("exercise-card").first()).toContainText("Box Squat");

  // ---------- المدربة: التنبيه عند اسم المتدرب ----------
  const mail = (await db.query(`SELECT subject, body FROM dev_mailbox WHERE recipient = 'coach-notify@e2e.test' AND subject LIKE 'تبديل تمرين%' ORDER BY id DESC LIMIT 1`)).rows[0];
  expect(mail.body).toContain("Back Squat ← Box Squat");
  await coach.goto("/admin");
  await expect(coach.getByTestId("stat-swaps")).not.toContainText(/^\s*متدربون بدّلوا تمارين0/);
  await coach.goto(`/admin/members?q=${encodeURIComponent(traineeEmail)}`);
  const note = coach.getByTestId("member-swaps");
  await expect(note).toContainText("Box Squat");
  await expect(note).toContainText("Back Squat");
  await noHorizontalScroll(coach);
  await coach.goto(`/admin/orders/${orderNo}/program`);
  await expect(coach.getByTestId("swaps")).toContainText("Box Squat");
  await expect(coach.locator(".program-items")).toContainText("بدّله المتدرب من");
  await expect(coach.getByTestId("trainee-logs")).toContainText("60");
  await coach.goto(`/admin/members?q=${encodeURIComponent(traineeEmail)}`);
  await coach.getByTestId("member-swaps").getByRole("button", { name: "اطّلعت عليها" }).click();
  await expect(coach.getByTestId("member-swaps")).toHaveCount(0);
  await coach.reload();
  await expect(coach.getByTestId("member-swaps")).toHaveCount(0);

  // ---------- المتدرب: التقدم ----------
  await trainee.getByRole("link", { name: "التقدم والقياسات" }).click();
  await trainee.getByTestId("weight-form").getByLabel("الوزن (كغ)").fill("72.4");
  await trainee.getByRole("button", { name: "حفظ الوزن" }).click();
  await expect(trainee.getByText("تم حفظ الوزن")).toBeVisible();
  await trainee.getByLabel("الخصر (سم)").fill("80");
  await trainee.getByRole("button", { name: "حفظ القياسات" }).click();
  await expect(trainee.getByText("تم حفظ القياسات")).toBeVisible();
  await trainee.getByLabel("مجموع خطوات الأسبوع").fill("50000");
  await trainee.getByRole("button", { name: "حفظ الخطوات" }).click();
  await expect(trainee.getByText("تم حفظ الخطوات")).toBeVisible();
  await trainee.reload();
  await expect(trainee.getByTestId("weekly-summary")).toContainText("50,000");
  await expect(trainee.getByTestId("weekly-summary")).toContainText("72.4");
  await expect(trainee.getByTestId("prs")).toContainText("Back Squat");
  await noHorizontalScroll(trainee);

  // ---------- مستخدم آخر لا يرى البرنامج ----------
  const other = await newPage(browser, project + "-o");
  await login(other, `other-tr-${project}@e2e.test`);
  const res = await other.goto(`/account/orders/${orderNo}/training`);
  expect(res?.status()).toBe(404);
});
