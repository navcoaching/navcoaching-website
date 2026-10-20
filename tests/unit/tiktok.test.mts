import { test } from "node:test";
import assert from "node:assert/strict";
import { tiktokId, youtubeId } from "../../src/lib/youtube.ts";

test("تيك توك: الرابط الكامل فقط", () => {
  assert.equal(tiktokId("https://www.tiktok.com/@nav/video/7301234567890123456"), "7301234567890123456");
  assert.equal(tiktokId("https://m.tiktok.com/@nav/video/7301234567890123456?is_from_webapp=1"), "7301234567890123456");
  assert.equal(tiktokId("https://www.tiktok.com/embed/v2/7301234567890123456"), "7301234567890123456");
  assert.equal(tiktokId("https://vm.tiktok.com/ZMabc123/"), null);
  assert.equal(tiktokId("http://www.tiktok.com/@a/video/7301234567890123456"), null);
  assert.equal(tiktokId("https://evil.com/tiktok.com/video/7301234567890123456"), null);
  assert.equal(tiktokId("https://youtu.be/dQw4w9WgXcQ"), null);
  assert.equal(youtubeId("https://www.tiktok.com/@a/video/7301234567890123456"), null);
});
