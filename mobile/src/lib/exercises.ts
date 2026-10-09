import data from "@/data/exercises.json";

export type Exercise = {
  id: string; name: string; muscle: string; secondary: string[]; kind: string | null; equipment: string | null;
  place: string | null; level: string | null; video: string | null; instructions: string | null;
};

export const EXERCISES = data as Exercise[];
const byId = new Map(EXERCISES.map((e) => [e.id, e]));

/** تمرين محذوف من المكتبة يبقى ظاهراً في السجل بمعرّفه */
export function exercise(id: string): Exercise {
  return byId.get(id) ?? { id, name: id, muscle: "", secondary: [], kind: null, equipment: null, place: null, level: null, video: null, instructions: null };
}

export const MUSCLES = [...new Set(EXERCISES.map((e) => e.muscle))];

export function searchExercises(q: string, muscle: string | null): Exercise[] {
  const s = q.trim().toLowerCase();
  return EXERCISES.filter((e) => (!muscle || e.muscle === muscle) && (!s || e.name.toLowerCase().includes(s) || e.muscle.includes(s) || (e.equipment ?? "").includes(s)));
}
