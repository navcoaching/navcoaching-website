import { useCallback, useEffect, useState } from "react";
import { API_URL } from "./config";

export type CoachProgram = {
  id: string; name: string; summary: string | null; instructions: string | null;
  days: { title: string; items: { exercise_id: string; name: string; sets: number; reps: string; rir: number | null }[] }[];
};

// برامج المدربة المجانية من الموقع (عامة، بدون دخول). تُحفظ في الذاكرة حتى لا تُطلب مع كل شاشة.
let cache: CoachProgram[] | null = null;

async function fetchPrograms(): Promise<CoachProgram[]> {
  const res = await fetch(`${API_URL}/api/mobile/v1/programs`, { headers: { Accept: "application/json" } });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  cache = ((await res.json()) as { programs: CoachProgram[] }).programs;
  return cache;
}

export function useCoachPrograms() {
  const [programs, setPrograms] = useState<CoachProgram[] | null>(cache);
  const [failed, setFailed] = useState(false);
  const load = useCallback(() => {
    setFailed(false);
    fetchPrograms().then(setPrograms).catch(() => setFailed(true));
  }, []);
  useEffect(() => { if (!cache) load(); }, [load]);
  return { programs, failed, retry: load };
}

export function cachedCoachProgram(id: string): CoachProgram | undefined {
  return cache?.find((p) => p.id === id);
}
