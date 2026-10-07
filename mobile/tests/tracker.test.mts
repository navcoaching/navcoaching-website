import { test } from "node:test";
import assert from "node:assert/strict";
import { e1rm, formatDuration, formatKg, newRecords, parseNumber, parseReps, volume } from "../src/lib/tracker/logic.ts";
import { makeTracker, TrackerError } from "../src/lib/tracker/repo.ts";
import { memoryDb } from "./node-db.mts";

test("logic: e1rm / parseReps / parseNumber / format", () => {
  assert.equal(e1rm(100, 1), 100);
  assert.equal(e1rm(100, 10), 133.3);
  assert.equal(e1rm(0, 10), 0);
  assert.deepEqual(parseReps("8-12"), { min: 8, max: 12 });
  assert.deepEqual(parseReps(" 10 "), { min: 10, max: 10 });
  assert.equal(parseReps("12-8"), null);
  assert.equal(parseReps("abc"), null);
  assert.equal(parseNumber("٤٢٫٥", { max: 1000 }), 42.5);
  assert.equal(parseNumber("42,5", { max: 1000 }), 42.5);
  assert.equal(parseNumber("10.5", { max: 200, integer: true }), null);
  assert.equal(parseNumber("", { max: 10 }), null);
  assert.equal(parseNumber("2000", { max: 1000 }), null);
  assert.equal(formatKg(42.5), "42.5");
  assert.equal(formatKg(40), "40");
  assert.equal(formatDuration(3909), "1:05:09");
  assert.equal(formatDuration(2709), "45:09");
});

test("logic: volume ignores warmups; first time is not a record", () => {
  const sets = [
    { exerciseId: "a", kind: "warmup" as const, weight: 20, reps: 10 },
    { exerciseId: "a", kind: "normal" as const, weight: 50, reps: 10 },
    { exerciseId: "b", kind: "normal" as const, weight: 30, reps: 8 },
  ];
  assert.equal(volume(sets), 740);
  const recs = newRecords(sets, new Map([["a", { e1rm: 60, weight: 45 }]]));
  assert.deepEqual(recs.map((r) => `${r.exerciseId}:${r.type}`).sort(), ["a:e1rm", "a:weight"]);
});

function setup() {
  let n = 0, t = 1_000_000;
  const tr = makeTracker(memoryDb(), () => `id${++n}`, () => (t += 60_000));
  return tr;
}

test("program: create, days, items, validation", async () => {
  const tr = setup();
  await tr.migrate();
  await tr.migrate(); // مرة ثانية لا تكرر الجداول
  const pid = await tr.createProgram("  علوي سفلي ");
  const p = (await tr.getProgram(pid))!;
  assert.equal(p.name, "علوي سفلي");
  assert.equal(p.days.length, 1);
  const day = p.days[0].id;
  const i1 = await tr.addItem(day, "back-squat");
  const i2 = await tr.addItem(day, "bench-press");
  await tr.updateItem(i1, { sets: 4, reps: "8 – 12", target_weight: 60, rest_sec: 120 });
  await assert.rejects(tr.updateItem(i1, { reps: "x" }), TrackerError);
  await assert.rejects(tr.updateItem(i1, { sets: 0 }), TrackerError);
  await tr.moveItem(i2, -1);
  const p2 = (await tr.getProgram(pid))!;
  assert.deepEqual(p2.days[0].items.map((i) => i.exercise_id), ["bench-press", "back-squat"]);
  assert.equal(p2.days[0].items[1].reps, "8-12");
  assert.equal(p2.days[0].items[1].sets, 4);
  await assert.rejects(tr.deleteDay(day), /يوماً واحداً/);
  const d2 = await tr.addDay(pid);
  await tr.renameDay(d2, "سفلي");
  await tr.deleteDay(d2);
  assert.equal((await tr.listPrograms())[0].days.length, 1);
  await tr.archiveProgram(pid);
  assert.equal((await tr.listPrograms()).length, 0);
});

test("workout: start from day, previous values, finish, records", async () => {
  const tr = setup();
  await tr.migrate();
  const pid = await tr.createProgram("برنامجي");
  const day = (await tr.getProgram(pid))!.days[0].id;
  await assert.rejects(tr.startWorkout({ dayId: day }), /تمريناً واحداً/);
  const item = await tr.addItem(day, "back-squat");
  await tr.updateItem(item, { sets: 2, target_weight: 60 });

  // التمرين الأول
  const w1 = await tr.startWorkout({ dayId: day });
  await assert.rejects(tr.startWorkout({ title: "x" }), /تمرين جارٍ/);
  let w = (await tr.getWorkout(w1))!;
  assert.equal(w.exercises.length, 1);
  assert.equal(w.exercises[0].sets.length, 2);
  assert.equal(w.exercises[0].target?.weight, 60);
  assert.deepEqual(w.exercises[0].previous, []);
  const [s1, s2] = w.exercises[0].sets;
  await assert.rejects(tr.updateSet(s1.id, { done: true }), /التكرارات/);
  await tr.updateSet(s1.id, { weight: 60, reps: 10, done: true });
  await assert.rejects(tr.finishWorkout("nope"), TrackerError);
  const sum1 = await tr.finishWorkout(w1);
  assert.equal(sum1.sets, 1, "غير المكتملة تُحذف");
  assert.equal(sum1.volume, 600);
  assert.deepEqual(sum1.records, [], "أول مرة ليست رقماً قياسياً");
  assert.equal((await tr.getWorkout(w1))!.exercises[0].sets.length, 1);
  void s2;

  // التمرين الثاني: يظهر «المرة السابقة» ورقم قياسي جديد
  const w2 = await tr.startWorkout({ dayId: day });
  w = (await tr.getWorkout(w2))!;
  assert.deepEqual(w.exercises[0].previous, [{ kind: "normal", weight: 60, reps: 10 }]);
  await tr.updateSet(w.exercises[0].sets[0].id, { weight: 65, reps: 8, done: true });
  await tr.addSet(w2, 0);
  w = (await tr.getWorkout(w2))!;
  assert.equal(w.exercises[0].sets.length, 3);
  await tr.deleteSet(w.exercises[0].sets[1].id);
  w = (await tr.getWorkout(w2))!;
  assert.deepEqual(w.exercises[0].sets.map((s) => s.set_no), [1, 2]);
  const sum2 = await tr.finishWorkout(w2);
  assert.deepEqual(sum2.records.map((r) => r.type).sort(), ["e1rm", "weight"]);

  // ملخص التمرين الأول ثابت بعد الثاني
  assert.deepEqual((await tr.summary(w1))!.records, []);
  const hist = await tr.history();
  assert.deepEqual(hist.map((h) => h.id), [w2, w1]);
  const ex = await tr.exerciseHistory("back-squat");
  assert.deepEqual(ex.map((r) => [r.max_weight, r.best_reps]), [[60, 10], [65, 8]]);

  // حذف البرنامج لا يحذف السجل
  await tr.archiveProgram(pid);
  assert.equal((await tr.history()).length, 2);
});

test("workout: free workout, add exercise, discard", async () => {
  const tr = setup();
  await tr.migrate();
  const id = await tr.startWorkout({ title: "" });
  await tr.addExerciseToWorkout(id, "push-up", 2);
  await tr.addExerciseToWorkout(id, "plank", 1);
  const w = (await tr.getWorkout(id))!;
  assert.equal(w.title, "تمرين حر");
  assert.deepEqual(w.exercises.map((e) => [e.position, e.sets.length]), [[0, 2], [1, 1]]);
  await assert.rejects(tr.finishWorkout(id), /جولة واحدة/);
  await tr.discardWorkout(id);
  assert.equal(await tr.activeWorkoutId(), null);
});

test("import coach program", async () => {
  const tr = setup();
  await tr.migrate();
  const id = await tr.importProgram({
    sourceId: "tpl-1", name: "تمرين 3 أيام",
    days: [{ title: "علوي", items: [{ exercise_id: "bench-press", sets: 3, reps: "8-12" }, { exercise_id: "row", sets: 99, reps: "bad" }] }],
  });
  const p = (await tr.getProgram(id))!;
  assert.equal(p.days[0].title, "علوي");
  assert.deepEqual(p.days[0].items.map((i) => [i.exercise_id, i.sets, i.reps]), [["bench-press", 3, "8-12"], ["row", 10, "10"]]);
  assert.deepEqual([...(await tr.importedSources())], ["tpl-1"]);
  await tr.archiveProgram(id);
  assert.equal((await tr.importedSources()).size, 0);
  await assert.rejects(tr.importProgram({ sourceId: "x", name: "x", days: [] }), TrackerError);
});
