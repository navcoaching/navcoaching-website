// الأساسيات التقنية لمحركات البحث في الصفحات العامة: رابط أساسي، بيانات منظّمة صالحة، h1 واحد، robots وsitemap. قاعدة nav_e2e.
import { test, expect } from "@playwright/test";

const PUBLIC = ["/", "/programs", "/about", "/faq", "/reviews", "/policies"];

test("SEO: الصفحات العامة فيها canonical وh1 واحد وبيانات منظّمة صالحة", async ({ page }) => {
  for (const path of PUBLIC) {
    await page.goto(path);
    await expect(page.locator("h1"), path).toHaveCount(1);
    const canonical = await page.locator('link[rel="canonical"]').getAttribute("href");
    expect(canonical, path).toBeTruthy();
    expect(new URL(canonical!).pathname.replace(/\/$/, ""), path).toBe(path === "/" ? "" : path);
    const robotsMeta = page.locator('meta[name="robots"]');
    if (await robotsMeta.count()) expect(await robotsMeta.first().getAttribute("content"), path).not.toContain("noindex");
    for (const raw of await page.locator('script[type="application/ld+json"]').allTextContents()) {
      const j = JSON.parse(raw);
      expect(j["@context"] ?? j["@graph"], path).toBeTruthy();
    }
  }
  await page.goto("/");
  const types = (await page.locator('script[type="application/ld+json"]').allTextContents()).join();
  expect(types).toContain("Organization");
  await page.goto("/faq");
  expect(await page.locator('script[type="application/ld+json"]').first().textContent()).toContain("FAQPage");
});

test("SEO: robots وsitemap، والصفحات الخاصة غير مفهرسة", async ({ page, request }) => {
  const robots = await (await request.get("/robots.txt")).text();
  for (const p of ["/admin", "/account", "/checkout", "/login", "/api"]) expect(robots).toContain(`Disallow: ${p}`);
  expect(robots).toContain("Sitemap:");
  const map = await (await request.get("/sitemap.xml")).text();
  expect(map).toContain("/programs");
  expect(map).not.toContain("/account");
  const res = await page.goto("/login");
  expect(res?.status()).toBeLessThan(400);
  await expect(page.locator('meta[name="robots"]')).toHaveAttribute("content", /noindex/);
});
