// جداول المتتبّع على الجهاز. كل إصدار يُضاف في آخر المصفوفة ولا يُعدَّل ما قبله (PRAGMA user_version).
export const MIGRATIONS: string[] = [
  `
  CREATE TABLE programs (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    archived INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
  );
  CREATE TABLE program_days (
    id TEXT PRIMARY KEY,
    program_id TEXT NOT NULL REFERENCES programs (id) ON DELETE CASCADE,
    position INTEGER NOT NULL,
    title TEXT NOT NULL
  );
  CREATE INDEX program_days_program ON program_days (program_id, position);
  CREATE TABLE program_items (
    id TEXT PRIMARY KEY,
    day_id TEXT NOT NULL REFERENCES program_days (id) ON DELETE CASCADE,
    position INTEGER NOT NULL,
    exercise_id TEXT NOT NULL,
    sets INTEGER NOT NULL DEFAULT 3 CHECK (sets BETWEEN 1 AND 10),
    reps TEXT NOT NULL DEFAULT '10',
    target_weight REAL CHECK (target_weight IS NULL OR target_weight BETWEEN 0 AND 1000),
    rest_sec INTEGER NOT NULL DEFAULT 90 CHECK (rest_sec BETWEEN 0 AND 600),
    note TEXT
  );
  CREATE INDEX program_items_day ON program_items (day_id, position);
  CREATE TABLE workouts (
    id TEXT PRIMARY KEY,
    program_id TEXT REFERENCES programs (id) ON DELETE SET NULL,
    day_id TEXT REFERENCES program_days (id) ON DELETE SET NULL,
    title TEXT NOT NULL,
    started_at INTEGER NOT NULL,
    finished_at INTEGER
  );
  CREATE INDEX workouts_finished ON workouts (finished_at);
  CREATE TABLE workout_sets (
    id TEXT PRIMARY KEY,
    workout_id TEXT NOT NULL REFERENCES workouts (id) ON DELETE CASCADE,
    exercise_id TEXT NOT NULL,
    item_id TEXT REFERENCES program_items (id) ON DELETE SET NULL,
    position INTEGER NOT NULL,
    set_no INTEGER NOT NULL,
    kind TEXT NOT NULL DEFAULT 'normal' CHECK (kind IN ('warmup', 'normal', 'drop')),
    weight REAL CHECK (weight IS NULL OR weight BETWEEN 0 AND 1000),
    reps INTEGER CHECK (reps IS NULL OR reps BETWEEN 0 AND 200),
    rir REAL CHECK (rir IS NULL OR rir BETWEEN 0 AND 10),
    done INTEGER NOT NULL DEFAULT 0,
    done_at INTEGER
  );
  CREATE INDEX workout_sets_workout ON workout_sets (workout_id, position, set_no);
  CREATE INDEX workout_sets_exercise ON workout_sets (exercise_id, done);
  `,
  // 2: البرنامج المنسوخ من برامج المدربة المجانية يحفظ معرّف مصدره (لمعرفة أنه أُضيف من قبل)
  `ALTER TABLE programs ADD COLUMN source_id TEXT;`,
  // 3: إعدادات على الجهاز
  `CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);`,
];
