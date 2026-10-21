// الصفحة الرئيسية (تصميم v3): ترتيب الأقسام، الهيرو بعمودين، الهيدر والتذييل، وعدم وجود تمرير أفقي على العروض الصغيرة.
import { test, expect } from "@playwright/test";

test("الرئيسية: الترتيب والهيرو والهيدر والتذييل", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator("html")).toHaveAttribute("lang", "ar");
  await expect(page.locator("html")).toHaveAttribute("dir", "rtl");

  // الهيرو (تصميم v3): العنوان بسطرين، زر واحد، رابط نصي للاختبار، وسطر ثقة بدون الشعار اللفظي الإنجليزي
  const hero = page.locator(".v3-hero");
  await expect(hero.locator("h1")).toContainText("برنامج مبني عليك،");
  await expect(hero.locator("h1 .hl")).toHaveText("مو جدول جاهز");
  // ارتفاع السطر يكفي لنقاط الحروف العربية (بدون تداخل)
  expect(parseFloat(await hero.locator("h1").evaluate((e) => getComputedStyle(e).lineHeight)) / parseFloat(await hero.locator("h1").evaluate((e) => getComputedStyle(e).fontSize))).toBeGreaterThanOrEqual(1.3);
  await expect(hero.locator(".btn")).toHaveCount(1);
  await expect(hero.getByRole("link", { name: /البرامج والأسعار/ })).toHaveAttribute("href", "#programs");
  await expect(hero.locator("a.text-link", { hasText: "أي برنامج يناسبني؟" })).toHaveAttribute("href", "/programs#quiz");
  await expect(page.getByTestId("trust-line")).toContainText("أدرّب منذ 2017");
  await expect(page.locator("body")).not.toContainText("Where Passion Meets Quality");
  // لقطة «برنامجي» الأمامية: نسخة واحدة ظاهرة حسب الوضع (فاتح/داكن)
  await expect(hero.locator(".v3-shot-front img:visible")).toHaveCount(1);
  // النص والزر ظاهران فوراً بدون حركة دخول تخفيهما
  expect(Number(await hero.locator(".lead").evaluate((e) => getComputedStyle(e).opacity))).toBe(1);

  // ترتيب الأقسام: الهيرو، المدربة، البرامج، ليش Nav، الخطوات، المكافأة، (التقييمات)، الأسئلة
  const ids = await page.locator("main section[id]").evaluateAll((els) => els.map((e) => e.id));
  const order = ["about", "programs", "why", "how", "reward", "faq"].map((id) => ids.indexOf(id));
  expect(order.every((i) => i >= 0), JSON.stringify(ids)).toBe(true);
  expect([...order].sort((a, b) => a - b)).toEqual(order);
  await expect(page.locator("#calculator")).toHaveCount(0);

  // البرامج: 3 بطاقات رئيسية بالترتيب، والموصى بها مميزة
  const main = page.locator("#programs .v3-pgrid .v3-plan");
  await expect(main).toHaveCount(3);
  expect(await main.evaluateAll((els) => els.map((e) => e.getAttribute("href")))).toEqual(["/programs/intensive", "/programs/advanced", "/programs/basic"]);
  await expect(page.locator("#programs .v3-plan.feat")).toHaveCount(1);
  await expect(page.locator("#programs")).toContainText("خصم 10% للطلاب · مجاني لأهل غزة · الدفع بتحويل بنكي");

  // حاسبة المكافأة: تغيير الالتزام يغيّر النتيجة
  const calc = page.getByTestId("reward-calc");
  await calc.evaluate((e) => e.scrollIntoView({ block: "center" })); // تطفو باستمرار (v3-bob) فلا تثبت
  const before = await calc.textContent();
  const range = calc.locator('input[type="range"]').first();
  await range.focus();
  for (let i = 0; i < 4; i++) await range.press("ArrowDown");
  await expect.poll(() => calc.textContent()).not.toBe(before);

  // الهيدر: روابط القائمة بلون واحد، وزر «البرامج والأسعار»
  if (await page.locator(".nav").isVisible()) {
    const links = page.locator(".nav > a:not(.btn)");
    expect(await links.allTextContents()).toEqual(["البرامج", "عن المدربة", "التقييمات", "الأسئلة الشائعة"]);
    const colors = new Set(await links.evaluateAll((els) => els.map((e) => getComputedStyle(e).color)));
    expect(colors.size).toBe(1);
    await expect(page.locator(".nav .btn", { hasText: "البرامج والأسعار" })).toBeVisible();
  }
  // التذييل: «أدوات مجانية»
  const foot = page.locator(".site-footer");
  await expect(foot.getByRole("heading", { name: "أدوات مجانية" })).toBeVisible();
  await expect(foot.getByRole("link", { name: "حاسبة السعرات" })).toHaveAttribute("href", "/calculator");
  // رابط الجداول المجانية يظهر فقط إذا فيه جدول منشور
  const fp = foot.getByRole("link", { name: "الجداول المجانية" });
  if (await fp.count()) await expect(fp).toHaveAttribute("href", "/free-plans");
  await expect(foot.getByRole("link", { name: "نظرة داخل البرنامج" })).toHaveAttribute("href", "/program-preview");
  // حسابات التواصل: تيك توك يظهر بجانب انستقرام
  await expect(foot.getByRole("link", { name: "تيك توك" })).toHaveAttribute("href", "https://www.tiktok.com/@navcoaching");
  await expect(page.getByText("الانتقال إلى المحتوى")).toHaveCount(1);
});

test("الرئيسية: لا تمرير أفقي على 320 و375 و414 و768، والأزرار على سطر واحد", async ({ page }) => {
  for (const width of [320, 375, 414, 768]) {
    await page.setViewportSize({ width, height: 800 });
    await page.goto("/");
    const [sw, iw] = await page.evaluate(() => [document.documentElement.scrollWidth, window.innerWidth]);
    expect(sw, `width ${width}`).toBeLessThanOrEqual(iw);
    const wrapped = await page.locator("main .btn:visible").evaluateAll((els) =>
      els.filter((e) => { const cs = getComputedStyle(e); return e.getBoundingClientRect().height > parseFloat(cs.lineHeight || "0") * 1.9 + 30; }).map((e) => e.textContent));
    expect(wrapped, `width ${width}`).toEqual([]);
  }
});

test("نظرة داخل البرنامج: صفحة مستقلة", async ({ page }) => {
  await page.goto("/program-preview");
  await expect(page.getByRole("heading", { level: 1 })).toHaveText("كيف يبدو البرنامج من الداخل؟");
  await expect(page.locator("main img").first()).toBeVisible();
});

test("صفحة الباقة: السعر وزر الاشتراك في أول الشاشة، وشريط ثابت على الجوال", async ({ page }, info) => {
  await page.goto("/programs/intensive");
  const offers = page.locator("#offers");
  const top = await offers.evaluate((e) => e.getBoundingClientRect().top + scrollY);
  const phone = (page.viewportSize()?.width ?? 1440) <= 760;
  if (phone) {
    // صندوق المدة مباشرة بعد العنوان، والشريط الثابت ظاهر
    expect(top).toBeLessThan(900);
    await expect(page.getByTestId("buy-bar")).toBeVisible();
    await expect(page.getByTestId("hero-buy")).toBeHidden();
  } else {
    await expect(page.getByTestId("hero-buy")).toBeVisible();
    await expect(page.getByTestId("buy-bar")).toBeHidden();
  }
  // توفير عرض الـ 3 أشهر محسوب من سعر الشهر
  await expect(offers).toContainText("توفير");
  // خط «وش يصير بعد الطلب؟» بدون خطوات مكتملة
  await expect(page.locator(".timeline li.done")).toHaveCount(0);
  // رأس الصفحات الداخلية بدون شبكة النقاط
  expect(await page.locator(".page-hero").evaluate((e) => getComputedStyle(e).backgroundImage)).not.toContain("radial-gradient");
  const [sw, iw] = await page.evaluate(() => [document.documentElement.scrollWidth, window.innerWidth]);
  expect(sw).toBeLessThanOrEqual(iw);
  void info;
});
