import { test } from "node:test";
import assert from "node:assert/strict";
import { DEFAULT_TIKTOK, TIKTOK_RE, withTiktok } from "../../src/lib/social.ts";

test("تيك توك: الافتراضي يظهر إذا ما حُفظ، والمسح يخفيه، والرابط يُتحقق منه", () => {
  assert.equal(withTiktok({ instagram: "x" } as { instagram: string; tiktok?: string }).tiktok, DEFAULT_TIKTOK);
  assert.equal(withTiktok({ tiktok: "" }).tiktok, "");
  assert.ok(TIKTOK_RE.test(DEFAULT_TIKTOK));
  assert.ok(TIKTOK_RE.test("https://tiktok.com/@nav.coaching/"));
  assert.ok(!TIKTOK_RE.test("http://www.tiktok.com/@navcoaching"));
  assert.ok(!TIKTOK_RE.test("https://evil.com/@navcoaching"));
  assert.ok(!TIKTOK_RE.test("https://www.tiktok.com/@nav\"><script>"));
});
