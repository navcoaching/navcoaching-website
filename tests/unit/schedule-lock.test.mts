import { test } from "node:test";
import assert from "node:assert/strict";
import { programLockedUntil } from "../../src/lib/schedule.ts";

test("programLockedUntil: يقفل فقط إذا اختار المتدرب تاريخاً وما وصل بعد", () => {
  const today = "2026-10-14";
  assert.equal(programLockedUntil({ preferred_start: null, sub_start_at: "2026-10-20T00:00:00+03:00" }, today), null);
  assert.equal(programLockedUntil({ preferred_start: "2026-10-20", sub_start_at: null }, today), null);
  assert.equal(programLockedUntil({ preferred_start: "2026-10-20", sub_start_at: "2026-10-19T21:00:00Z" }, today), "2026-10-20");
  assert.equal(programLockedUntil({ preferred_start: "2026-10-20", sub_start_at: "2026-10-13T21:00:00Z" }, today), null);
  assert.equal(programLockedUntil({ preferred_start: "2026-10-20", sub_start_at: "2026-10-10T21:00:00Z" }, today), null);
});
