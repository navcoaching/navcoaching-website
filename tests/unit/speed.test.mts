import { test } from "node:test";
import assert from "node:assert/strict";
import { dbInfoFromUrl, verdict, normRegion, median } from "../../src/lib/speed.ts";

test("منطقة Neon والمجمّع من رابط الاتصال بدون كشف كلمة السر", () => {
  const i = dbInfoFromUrl("postgresql://nav_app:secret@ep-cool-1234-pooler.eu-central-1.aws.neon.tech/neondb?sslmode=require");
  assert.deepEqual(i, { region: "eu-central-1", pooled: true, neon: true });
  assert.equal(JSON.stringify(i).includes("secret"), false);
  assert.deepEqual(dbInfoFromUrl("postgresql://u:p@ep-x.us-east-2.aws.neon.tech/db"), { region: "us-east-2", pooled: false, neon: true });
  assert.deepEqual(dbInfoFromUrl("postgres://u:p@localhost:5432/db"), { region: null, pooled: false, neon: false });
  assert.deepEqual(dbInfoFromUrl(undefined), { region: null, pooled: false, neon: false });
});

test("رمز Netlify fra = eu-central-1", () => {
  assert.equal(normRegion("fra"), "eu-central-1");
  assert.equal(normRegion("us-east-2"), "us-east-2");
  assert.equal(normRegion(null), null);
});

test("الحكم: اختلاف المنطقة سيئ، وتطابقها جيد، والرابط غير المجمّع تحذير", () => {
  const db = { region: "eu-central-1", pooled: true, neon: true };
  const bad = verdict("us-east-2", db, 95);
  assert.equal(bad[0].tone, "bad");
  assert.match(bad[0].text, /فرانكفورت/);
  assert.equal(bad.at(-1)!.tone, "bad");
  const ok = verdict("eu-central-1", db, 3);
  assert.deepEqual(ok.map((v) => v.tone), ["ok", "ok"]);
  assert.equal(verdict("fra", db, null)[0].tone, "ok");
  assert.ok(verdict("eu-central-1", { ...db, pooled: false }, 5).some((v) => v.tone === "warn" && /pooler/.test(v.text)));
  assert.equal(verdict(null, { region: null, pooled: false, neon: false }, 1)[0].tone, "warn");
});

test("الوسيط", () => {
  assert.equal(median([5, 1, 3]), 3);
  assert.equal(median([4, 1, 3, 2]), 2.5);
  assert.equal(median([]), null);
});
