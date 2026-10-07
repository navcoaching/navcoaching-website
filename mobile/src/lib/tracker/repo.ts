// الوصول لبيانات المتتبّع على الجهاز. يعمل مع expo-sqlite في التطبيق، ومع node:sqlite في الاختبارات.
import { e1rm, newRecords, parseReps, volume, type DoneSet, type Record, type SetKind } from "./logic.ts";
import { MIGRATIONS } from "./schema.ts";

type Bind = string | number | null;

/** الجزء المستخدم من SQLiteDatabase في expo-sqlite */
export interface Db {
  execAsync(sql: string): Promise<void>;
  runAsync(sql: string, params: Bind[]): Promise<unknown>;
  getAllAsync<T>(sql: string, params: Bind[]): Promise<T[]>;
  getFirstAsync<T>(sql: string, params: Bind[]): Promise<T | null>;
  withTransactionAsync(fn: () => Promise<void>): Promise<void>;
}

export class TrackerError extends Error {}

export type ProgramSummary = { id: string; name: string; days: { id: string; title: string; items: number }[] };
export type ProgramItem = {
  id: string; position: number; exercise_id: string; sets: number; reps: string;
  target_weight: number | null; rest_sec: number; note: string | null;
};
export type ProgramDay = { id: string; position: number; title: string; items: ProgramItem[] };
export type Program = { id: string; name: string; days: ProgramDay[] };

export type WorkoutSet = {
  id: string; set_no: number; kind: SetKind; weight: number | null; reps: number | null; rir: number | null; done: boolean;
};
export type PrevSet = { kind: SetKind; weight: number | null; reps: number | null };
export type WorkoutExercise = {
  position: number; exercise_id: string; item_id: string | null;
  target: { reps: string; weight: number | null; rest_sec: number } | null;
  sets: WorkoutSet[];
  /** جولات آخر تمرين مكتمل لنفس التمرين، بترتيبها (لعرض «المرة السابقة») */
  previous: PrevSet[];
};
export type Workout = {
  id: string; title: string; program_id: string | null; day_id: string | null;
  started_at: number; finished_at: number | null; exercises: WorkoutExercise[];
};
export type ExercisePoint = { workout_id: string; finished_at: number; max_weight: number; best_reps: number; best_e1rm: number; sets: number };
export type WorkoutSummary = {
  id: string; title: string; started_at: number; finished_at: number;
  duration_sec: number; sets: number; volume: number; exercises: number; records: Record[];
};

const DEFAULT_REST = 90;

export function makeTracker(db: Db, newId: () => string, now: () => number = Date.now) {
  async function tx<T>(fn: () => Promise<T>): Promise<T> {
    let out!: T;
    await db.withTransactionAsync(async () => { out = await fn(); });
    return out;
  }
  async function nextPos(table: "program_days" | "program_items", col: "program_id" | "day_id", id: string) {
    const r = await db.getFirstAsync<{ p: number | null }>(`SELECT max(position) AS p FROM ${table} WHERE ${col} = ?`, [id]);
    return (r?.p ?? -1) + 1;
  }
  async function touchProgram(programId: string) {
    await db.runAsync("UPDATE programs SET updated_at = ? WHERE id = ?", [now(), programId]);
  }
  async function dayProgram(dayId: string) {
    const r = await db.getFirstAsync<{ program_id: string }>("SELECT program_id FROM program_days WHERE id = ?", [dayId]);
    if (!r) throw new TrackerError("اليوم غير موجود.");
    return r.program_id;
  }

  return {
    async migrate() {
      const r = await db.getFirstAsync<{ user_version: number }>("PRAGMA user_version", []);
      let v = r?.user_version ?? 0;
      await db.execAsync("PRAGMA foreign_keys = ON");
      if (v === 0) await db.execAsync("PRAGMA journal_mode = WAL");
      while (v < MIGRATIONS.length) {
        const sql = MIGRATIONS[v];
        await tx(async () => {
          await db.execAsync(sql);
          await db.execAsync(`PRAGMA user_version = ${v + 1}`);
        });
        v++;
      }
    },

    // ---------- البرامج ----------
    async listPrograms(): Promise<ProgramSummary[]> {
      const programs = await db.getAllAsync<{ id: string; name: string }>(
        "SELECT id, name FROM programs WHERE archived = 0 ORDER BY updated_at DESC", []);
      const days = await db.getAllAsync<{ id: string; program_id: string; title: string; items: number }>(
        `SELECT d.id, d.program_id, d.title, (SELECT count(*) FROM program_items i WHERE i.day_id = d.id) AS items
           FROM program_days d JOIN programs p ON p.id = d.program_id WHERE p.archived = 0 ORDER BY d.position`, []);
      return programs.map((p) => ({ ...p, days: days.filter((d) => d.program_id === p.id).map(({ id, title, items }) => ({ id, title, items })) }));
    },

    async createProgram(name: string): Promise<string> {
      const n = name.trim();
      if (n.length < 1 || n.length > 80) throw new TrackerError("اسم البرنامج من 1 إلى 80 حرفاً.");
      const id = newId();
      await tx(async () => {
        await db.runAsync("INSERT INTO programs (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)", [id, n, now(), now()]);
        await db.runAsync("INSERT INTO program_days (id, program_id, position, title) VALUES (?, ?, 0, ?)", [newId(), id, "اليوم 1"]);
      });
      return id;
    },

    /** ينسخ برنامجاً جاهزاً (من برامج المدربة المجانية) إلى الجهاز كبرنامج قابل للتعديل */
    async importProgram(src: {
      sourceId: string; name: string;
      days: { title: string; items: { exercise_id: string; sets: number; reps: string }[] }[];
    }): Promise<string> {
      if (src.days.length === 0 || src.days.length > 14) throw new TrackerError("البرنامج غير صالح.");
      const id = newId();
      await tx(async () => {
        await db.runAsync("INSERT INTO programs (id, name, source_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
          [id, src.name.trim().slice(0, 80) || "برنامج", src.sourceId, now(), now()]);
        for (const [dPos, d] of src.days.entries()) {
          const dayId = newId();
          await db.runAsync("INSERT INTO program_days (id, program_id, position, title) VALUES (?, ?, ?, ?)",
            [dayId, id, dPos, d.title.trim().slice(0, 60) || `اليوم ${dPos + 1}`]);
          for (const [iPos, it] of d.items.slice(0, 20).entries()) {
            const sets = Math.min(10, Math.max(1, Math.round(it.sets) || 3));
            const reps = parseReps(it.reps) ? it.reps : "10";
            await db.runAsync(
              "INSERT INTO program_items (id, day_id, position, exercise_id, sets, reps, rest_sec) VALUES (?, ?, ?, ?, ?, ?, ?)",
              [newId(), dayId, iPos, it.exercise_id, sets, reps, DEFAULT_REST]);
          }
        }
      });
      return id;
    },

    /** معرّفات برامج المدربة المنسوخة على الجهاز (غير المحذوفة) */
    async importedSources(): Promise<Set<string>> {
      const rows = await db.getAllAsync<{ source_id: string }>(
        "SELECT source_id FROM programs WHERE source_id IS NOT NULL AND archived = 0", []);
      return new Set(rows.map((r) => r.source_id));
    },

    async getProgram(id: string): Promise<Program | null> {
      const p = await db.getFirstAsync<{ id: string; name: string }>("SELECT id, name FROM programs WHERE id = ? AND archived = 0", [id]);
      if (!p) return null;
      const days = await db.getAllAsync<Omit<ProgramDay, "items">>(
        "SELECT id, position, title FROM program_days WHERE program_id = ? ORDER BY position", [id]);
      const items = await db.getAllAsync<ProgramItem & { day_id: string }>(
        `SELECT i.* FROM program_items i JOIN program_days d ON d.id = i.day_id WHERE d.program_id = ? ORDER BY i.position`, [id]);
      return { ...p, days: days.map((d) => ({ ...d, items: items.filter((i) => i.day_id === d.id).map(({ day_id: _, ...i }) => i) })) };
    },

    async renameProgram(id: string, name: string) {
      const n = name.trim();
      if (n.length < 1 || n.length > 80) throw new TrackerError("اسم البرنامج من 1 إلى 80 حرفاً.");
      await db.runAsync("UPDATE programs SET name = ?, updated_at = ? WHERE id = ?", [n, now(), id]);
    },

    /** حذف ناعم: سجل التمارين السابقة يبقى كما هو */
    async archiveProgram(id: string) {
      await db.runAsync("UPDATE programs SET archived = 1, updated_at = ? WHERE id = ?", [now(), id]);
    },

    async addDay(programId: string): Promise<string> {
      const id = newId();
      await tx(async () => {
        const pos = await nextPos("program_days", "program_id", programId);
        if (pos >= 14) throw new TrackerError("الحد الأعلى 14 يوماً في البرنامج.");
        await db.runAsync("INSERT INTO program_days (id, program_id, position, title) VALUES (?, ?, ?, ?)", [id, programId, pos, `اليوم ${pos + 1}`]);
        await touchProgram(programId);
      });
      return id;
    },

    async renameDay(dayId: string, title: string) {
      const t = title.trim();
      if (t.length < 1 || t.length > 60) throw new TrackerError("اسم اليوم من 1 إلى 60 حرفاً.");
      await db.runAsync("UPDATE program_days SET title = ? WHERE id = ?", [t, dayId]);
      await touchProgram(await dayProgram(dayId));
    },

    async deleteDay(dayId: string) {
      const programId = await dayProgram(dayId);
      await tx(async () => {
        const c = await db.getFirstAsync<{ n: number }>("SELECT count(*) AS n FROM program_days WHERE program_id = ?", [programId]);
        if ((c?.n ?? 0) <= 1) throw new TrackerError("البرنامج يحتاج يوماً واحداً على الأقل.");
        await db.runAsync("DELETE FROM program_days WHERE id = ?", [dayId]);
        await touchProgram(programId);
      });
    },

    async addItem(dayId: string, exerciseId: string): Promise<string> {
      const id = newId();
      await tx(async () => {
        const pos = await nextPos("program_items", "day_id", dayId);
        if (pos >= 20) throw new TrackerError("الحد الأعلى 20 تمريناً في اليوم.");
        await db.runAsync(
          "INSERT INTO program_items (id, day_id, position, exercise_id, sets, reps, rest_sec) VALUES (?, ?, ?, ?, 3, '10', ?)",
          [id, dayId, pos, exerciseId, DEFAULT_REST]);
        await touchProgram(await dayProgram(dayId));
      });
      return id;
    },

    async updateItem(itemId: string, patch: { sets?: number; reps?: string; target_weight?: number | null; rest_sec?: number }) {
      if (patch.sets !== undefined && !(Number.isInteger(patch.sets) && patch.sets >= 1 && patch.sets <= 10)) throw new TrackerError("عدد الجولات من 1 إلى 10.");
      if (patch.reps !== undefined && !parseReps(patch.reps)) throw new TrackerError("التكرارات رقم مثل 10 أو مدى مثل 8-12.");
      if (patch.target_weight != null && !(patch.target_weight >= 0 && patch.target_weight <= 1000)) throw new TrackerError("الوزن من 0 إلى 1000.");
      if (patch.rest_sec !== undefined && !(Number.isInteger(patch.rest_sec) && patch.rest_sec >= 0 && patch.rest_sec <= 600)) throw new TrackerError("الراحة من 0 إلى 600 ثانية.");
      const cols = Object.entries(patch).filter(([, v]) => v !== undefined);
      if (cols.length === 0) return;
      await db.runAsync(
        `UPDATE program_items SET ${cols.map(([k]) => `${k} = ?`).join(", ")} WHERE id = ?`,
        [...cols.map(([k, v]) => (k === "reps" ? String(v).replace(/\s|–/g, (c) => (c === "–" ? "-" : "")) : (v as Bind))), itemId]);
    },

    async deleteItem(itemId: string) {
      await db.runAsync("DELETE FROM program_items WHERE id = ?", [itemId]);
    },

    /** تحريك التمرين للأعلى (-1) أو للأسفل (+1) داخل يومه */
    async moveItem(itemId: string, dir: -1 | 1) {
      await tx(async () => {
        const it = await db.getFirstAsync<{ day_id: string; position: number }>("SELECT day_id, position FROM program_items WHERE id = ?", [itemId]);
        if (!it) return;
        const other = await db.getFirstAsync<{ id: string; position: number }>(
          dir < 0
            ? "SELECT id, position FROM program_items WHERE day_id = ? AND position < ? ORDER BY position DESC LIMIT 1"
            : "SELECT id, position FROM program_items WHERE day_id = ? AND position > ? ORDER BY position ASC LIMIT 1",
          [it.day_id, it.position]);
        if (!other) return;
        await db.runAsync("UPDATE program_items SET position = ? WHERE id = ?", [other.position, itemId]);
        await db.runAsync("UPDATE program_items SET position = ? WHERE id = ?", [it.position, other.id]);
      });
    },

    // ---------- التمرين الجاري ----------
    async activeWorkoutId(): Promise<string | null> {
      const r = await db.getFirstAsync<{ id: string }>("SELECT id FROM workouts WHERE finished_at IS NULL ORDER BY started_at DESC LIMIT 1", []);
      return r?.id ?? null;
    },

    /** يبدأ تمريناً من يوم في برنامج (جولاته جاهزة)، أو تمريناً حراً فارغاً. تمرين واحد جارٍ فقط في نفس الوقت. */
    async startWorkout(from: { dayId: string } | { title: string }): Promise<string> {
      const id = newId();
      await tx(async () => {
        const active = await db.getFirstAsync<{ id: string }>("SELECT id FROM workouts WHERE finished_at IS NULL LIMIT 1", []);
        if (active) throw new TrackerError("عندك تمرين جارٍ. أنهه أو احذفه أولاً.");
        if ("dayId" in from) {
          const d = await db.getFirstAsync<{ program_id: string; title: string; name: string }>(
            "SELECT d.program_id, d.title, p.name FROM program_days d JOIN programs p ON p.id = d.program_id WHERE d.id = ?", [from.dayId]);
          if (!d) throw new TrackerError("اليوم غير موجود.");
          const items = await db.getAllAsync<{ id: string; exercise_id: string; sets: number }>(
            "SELECT id, exercise_id, sets FROM program_items WHERE day_id = ? ORDER BY position", [from.dayId]);
          if (items.length === 0) throw new TrackerError("أضف تمريناً واحداً على الأقل لهذا اليوم.");
          await db.runAsync("INSERT INTO workouts (id, program_id, day_id, title, started_at) VALUES (?, ?, ?, ?, ?)",
            [id, d.program_id, from.dayId, `${d.name} · ${d.title}`, now()]);
          for (const [pos, it] of items.entries()) {
            for (let n = 1; n <= it.sets; n++) {
              await db.runAsync("INSERT INTO workout_sets (id, workout_id, exercise_id, item_id, position, set_no) VALUES (?, ?, ?, ?, ?, ?)",
                [newId(), id, it.exercise_id, it.id, pos, n]);
            }
          }
        } else {
          const t = from.title.trim() || "تمرين حر";
          await db.runAsync("INSERT INTO workouts (id, title, started_at) VALUES (?, ?, ?)", [id, t.slice(0, 80), now()]);
        }
      });
      return id;
    },

    async getWorkout(id: string): Promise<Workout | null> {
      const w = await db.getFirstAsync<Omit<Workout, "exercises">>(
        "SELECT id, title, program_id, day_id, started_at, finished_at FROM workouts WHERE id = ?", [id]);
      if (!w) return null;
      const sets = await db.getAllAsync<Omit<WorkoutSet, "done"> & { position: number; exercise_id: string; item_id: string | null; done: number }>(
        "SELECT id, position, exercise_id, item_id, set_no, kind, weight, reps, rir, done FROM workout_sets WHERE workout_id = ? ORDER BY position, set_no", [id]);
      const groups = new Map<number, WorkoutExercise>();
      for (const s of sets) {
        let g = groups.get(s.position);
        if (!g) groups.set(s.position, (g = { position: s.position, exercise_id: s.exercise_id, item_id: s.item_id, target: null, sets: [], previous: [] }));
        g.sets.push({ id: s.id, set_no: s.set_no, kind: s.kind, weight: s.weight, reps: s.reps, rir: s.rir, done: s.done === 1 });
      }
      const exercises = [...groups.values()];
      for (const g of exercises) {
        if (g.item_id) {
          const t = await db.getFirstAsync<{ reps: string; target_weight: number | null; rest_sec: number }>(
            "SELECT reps, target_weight, rest_sec FROM program_items WHERE id = ?", [g.item_id]);
          if (t) g.target = { reps: t.reps, weight: t.target_weight, rest_sec: t.rest_sec };
        }
        const last = await db.getFirstAsync<{ workout_id: string; position: number }>(
          `SELECT s.workout_id, s.position FROM workout_sets s JOIN workouts w ON w.id = s.workout_id
            WHERE s.exercise_id = ? AND s.done = 1 AND w.finished_at IS NOT NULL AND w.id <> ?
            ORDER BY w.finished_at DESC LIMIT 1`, [g.exercise_id, id]);
        if (last) {
          g.previous = await db.getAllAsync<PrevSet>(
            "SELECT kind, weight, reps FROM workout_sets WHERE workout_id = ? AND position = ? AND exercise_id = ? AND done = 1 ORDER BY set_no",
            [last.workout_id, last.position, g.exercise_id]);
        }
      }
      return { ...w, exercises };
    },

    async addExerciseToWorkout(workoutId: string, exerciseId: string, sets = 3) {
      await tx(async () => {
        const r = await db.getFirstAsync<{ p: number | null }>("SELECT max(position) AS p FROM workout_sets WHERE workout_id = ?", [workoutId]);
        const pos = (r?.p ?? -1) + 1;
        for (let n = 1; n <= sets; n++) {
          await db.runAsync("INSERT INTO workout_sets (id, workout_id, exercise_id, position, set_no) VALUES (?, ?, ?, ?, ?)",
            [newId(), workoutId, exerciseId, pos, n]);
        }
      });
    },

    async addSet(workoutId: string, position: number) {
      await tx(async () => {
        const r = await db.getFirstAsync<{ exercise_id: string; item_id: string | null; n: number }>(
          "SELECT exercise_id, item_id, max(set_no) AS n FROM workout_sets WHERE workout_id = ? AND position = ? GROUP BY exercise_id, item_id",
          [workoutId, position]);
        if (!r) throw new TrackerError("التمرين غير موجود.");
        if (r.n >= 15) throw new TrackerError("الحد الأعلى 15 جولة للتمرين.");
        await db.runAsync("INSERT INTO workout_sets (id, workout_id, exercise_id, item_id, position, set_no) VALUES (?, ?, ?, ?, ?, ?)",
          [newId(), workoutId, r.exercise_id, r.item_id, position, r.n + 1]);
      });
    },

    /** حذف جولة وإعادة ترقيم ما بعدها؛ حذف آخر جولة يحذف التمرين من هذا التمرين */
    async deleteSet(setId: string) {
      await tx(async () => {
        const s = await db.getFirstAsync<{ workout_id: string; position: number; set_no: number }>(
          "SELECT workout_id, position, set_no FROM workout_sets WHERE id = ?", [setId]);
        if (!s) return;
        await db.runAsync("DELETE FROM workout_sets WHERE id = ?", [setId]);
        await db.runAsync("UPDATE workout_sets SET set_no = set_no - 1 WHERE workout_id = ? AND position = ? AND set_no > ?",
          [s.workout_id, s.position, s.set_no]);
      });
    },

    async updateSet(setId: string, patch: { weight?: number | null; reps?: number | null; rir?: number | null; kind?: SetKind; done?: boolean }) {
      if (patch.weight != null && !(patch.weight >= 0 && patch.weight <= 1000)) throw new TrackerError("الوزن من 0 إلى 1000.");
      if (patch.reps != null && !(Number.isInteger(patch.reps) && patch.reps >= 0 && patch.reps <= 200)) throw new TrackerError("التكرارات من 0 إلى 200.");
      if (patch.rir != null && !(patch.rir >= 0 && patch.rir <= 10)) throw new TrackerError("RIR من 0 إلى 10.");
      if (patch.done) {
        const cur = await db.getFirstAsync<{ weight: number | null; reps: number | null }>("SELECT weight, reps FROM workout_sets WHERE id = ?", [setId]);
        const reps = patch.reps !== undefined ? patch.reps : cur?.reps;
        const weight = patch.weight !== undefined ? patch.weight : cur?.weight;
        if (reps == null || reps < 1) throw new TrackerError("اكتب عدد التكرارات قبل إكمال الجولة.");
        if (weight == null) throw new TrackerError("اكتب الوزن (0 لوزن الجسم) قبل إكمال الجولة.");
      }
      const cols: [string, Bind][] = [];
      if (patch.weight !== undefined) cols.push(["weight", patch.weight]);
      if (patch.reps !== undefined) cols.push(["reps", patch.reps]);
      if (patch.rir !== undefined) cols.push(["rir", patch.rir]);
      if (patch.kind !== undefined) cols.push(["kind", patch.kind]);
      if (patch.done !== undefined) cols.push(["done", patch.done ? 1 : 0], ["done_at", patch.done ? now() : null]);
      if (cols.length === 0) return;
      await db.runAsync(`UPDATE workout_sets SET ${cols.map(([k]) => `${k} = ?`).join(", ")} WHERE id = ?`, [...cols.map(([, v]) => v), setId]);
    },

    /** ينهي التمرين: الجولات غير المكتملة تُحذف، ويرجع الملخص والأرقام القياسية الجديدة */
    async finishWorkout(id: string): Promise<WorkoutSummary> {
      await tx(async () => {
        const w = await db.getFirstAsync<{ finished_at: number | null }>("SELECT finished_at FROM workouts WHERE id = ?", [id]);
        if (!w) throw new TrackerError("التمرين غير موجود.");
        if (w.finished_at) throw new TrackerError("التمرين منتهي.");
        const c = await db.getFirstAsync<{ n: number }>("SELECT count(*) AS n FROM workout_sets WHERE workout_id = ? AND done = 1", [id]);
        if ((c?.n ?? 0) === 0) throw new TrackerError("أكمل جولة واحدة على الأقل، أو احذف التمرين.");
        await db.runAsync("DELETE FROM workout_sets WHERE workout_id = ? AND done = 0", [id]);
        await db.runAsync("UPDATE workouts SET finished_at = ? WHERE id = ?", [now(), id]);
      });
      return (await this.summary(id))!;
    },

    async discardWorkout(id: string) {
      await db.runAsync("DELETE FROM workouts WHERE id = ? AND finished_at IS NULL", [id]);
    },

    async deleteWorkout(id: string) {
      await db.runAsync("DELETE FROM workouts WHERE id = ?", [id]);
    },

    // ---------- السجل ----------
    async summary(id: string): Promise<WorkoutSummary | null> {
      const w = await db.getFirstAsync<{ id: string; title: string; started_at: number; finished_at: number | null }>(
        "SELECT id, title, started_at, finished_at FROM workouts WHERE id = ?", [id]);
      if (!w || !w.finished_at) return null;
      const rows = await db.getAllAsync<{ exercise_id: string; kind: SetKind; weight: number; reps: number }>(
        "SELECT exercise_id, kind, weight, reps FROM workout_sets WHERE workout_id = ? AND done = 1", [id]);
      const sets: DoneSet[] = rows.map((r) => ({ exerciseId: r.exercise_id, kind: r.kind, weight: r.weight, reps: r.reps }));
      // الأرقام القياسية تُقارن بما قبل هذا التمرين فقط (حتى يبقى ملخص تمرين قديم ثابتاً)
      const before = await db.getAllAsync<{ exercise_id: string; weight: number; reps: number }>(
        `SELECT s.exercise_id, s.weight, s.reps FROM workout_sets s JOIN workouts w ON w.id = s.workout_id
          WHERE s.done = 1 AND s.kind <> 'warmup' AND w.finished_at IS NOT NULL AND w.finished_at < ?`, [w.finished_at]);
      const ids = new Set(sets.map((s) => s.exerciseId));
      const best = new Map<string, { e1rm: number; weight: number }>();
      for (const r of before) {
        if (!ids.has(r.exercise_id)) continue;
        const cur = best.get(r.exercise_id) ?? { e1rm: 0, weight: 0 };
        best.set(r.exercise_id, { e1rm: Math.max(cur.e1rm, e1rm(r.weight, r.reps)), weight: Math.max(cur.weight, r.weight) });
      }
      return {
        id: w.id, title: w.title, started_at: w.started_at, finished_at: w.finished_at,
        duration_sec: Math.round((w.finished_at - w.started_at) / 1000),
        sets: sets.filter((s) => s.kind !== "warmup").length,
        volume: volume(sets),
        exercises: ids.size,
        records: newRecords(sets, best),
      };
    },

    async history(limit = 50): Promise<WorkoutSummary[]> {
      const ids = await db.getAllAsync<{ id: string }>(
        "SELECT id FROM workouts WHERE finished_at IS NOT NULL ORDER BY finished_at DESC LIMIT ?", [limit]);
      const out: WorkoutSummary[] = [];
      for (const { id } of ids) {
        const s = await this.summary(id);
        if (s) out.push(s);
      }
      return out;
    },

    /** أفضل أداء لتمرين في كل تمرين مكتمل، الأقدم أولاً (للرسوم البيانية وسجل التمرين) */
    async exerciseHistory(exerciseId: string): Promise<ExercisePoint[]> {
      const rows = await db.getAllAsync<{ workout_id: string; finished_at: number; weight: number; reps: number }>(
        `SELECT w.id AS workout_id, w.finished_at, s.weight, s.reps
           FROM workout_sets s JOIN workouts w ON w.id = s.workout_id
          WHERE s.exercise_id = ? AND s.done = 1 AND s.kind <> 'warmup' AND w.finished_at IS NOT NULL
          ORDER BY w.finished_at`, [exerciseId]);
      const out: ExercisePoint[] = [];
      for (const r of rows) {
        let p = out[out.length - 1];
        if (!p || p.workout_id !== r.workout_id) out.push((p = { workout_id: r.workout_id, finished_at: r.finished_at, max_weight: 0, best_reps: 0, best_e1rm: 0, sets: 0 }));
        p.sets++;
        if (r.weight > p.max_weight || (r.weight === p.max_weight && r.reps > p.best_reps)) { p.max_weight = r.weight; p.best_reps = r.reps; }
        p.best_e1rm = Math.max(p.best_e1rm, e1rm(r.weight, r.reps));
      }
      return out;
    },

    /** إعدادات بسيطة على الجهاز (مثل التذكيرات) */
    async getSetting(key: string): Promise<string | null> {
      const r = await db.getFirstAsync<{ value: string }>("SELECT value FROM settings WHERE key = ?", [key]);
      return r?.value ?? null;
    },
    async setSetting(key: string, value: string) {
      await db.runAsync("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value", [key, value]);
    },
  };
}

export type Tracker = ReturnType<typeof makeTracker>;
