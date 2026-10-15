import { useCallback, useState } from "react";
import { useFocusEffect } from "expo-router";
import { api, ApiError, type Coaching } from "./api";

// بيانات برنامج المدربة للمتدرب. محفوظة في الذاكرة بين الشاشات حتى لا تُطلب مع كل انتقال.
let cache: Coaching | null = null;

export function useCoaching() {
  const [data, setData] = useState<Coaching | null>(cache);
  const [error, setError] = useState<string | null>(null);
  const reload = useCallback(async () => {
    try {
      const r = await api<{ coaching: Coaching | null }>("/coaching");
      cache = r.coaching;
      setData(r.coaching);
      setError(null);
    } catch (e) {
      setError(e instanceof ApiError && e.status === 401 ? "login" : "تعذّر تحميل برنامجك. تأكد من الاتصال.");
    }
  }, []);
  useFocusEffect(useCallback(() => { reload(); }, [reload]));
  return { data, error, reload };
}

export function clearCoachingCache() { cache = null; }

/** المستهدف كما في الموقع: "3 × 10 · RIR 2" أو "3 × 12/10/8" */
export function planText(p: { reps: number[]; rir: number | null } | undefined): string {
  if (!p || p.reps.length === 0) return "—";
  const same = p.reps.every((r) => r === p.reps[0]);
  return `${p.reps.length} × ${same ? p.reps[0] : p.reps.join("/")}${p.rir != null ? ` · RIR ${p.rir}` : ""}`;
}
