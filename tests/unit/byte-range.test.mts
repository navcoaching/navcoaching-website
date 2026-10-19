import { test } from "node:test";
import assert from "node:assert/strict";
import { byteRange } from "../../src/lib/byte-range.ts";

test("نطاقات الفيديو (Safari)", () => {
  assert.equal(byteRange(null, 100), null);
  assert.equal(byteRange("bytes=-", 100), null);
  assert.equal(byteRange("items=0-1", 100), null);
  assert.deepEqual(byteRange("bytes=0-1", 100), { start: 0, end: 1 });
  assert.deepEqual(byteRange("bytes=10-", 100), { start: 10, end: 99 });
  assert.deepEqual(byteRange("bytes=90-500", 100), { start: 90, end: 99 });
  assert.deepEqual(byteRange("bytes=-20", 100), { start: 80, end: 99 });
  assert.deepEqual(byteRange("bytes=-500", 100), { start: 0, end: 99 });
  assert.equal(byteRange("bytes=100-", 100), "invalid");
  assert.equal(byteRange("bytes=5-2", 100), "invalid");
  assert.equal(byteRange("bytes=-0", 100), "invalid");
});
