import { randomUUID } from "expo-crypto";
import { useFocusEffect } from "expo-router";
import { SQLiteProvider, useSQLiteContext } from "expo-sqlite";
import { createContext, useCallback, useContext, useMemo, useState, type ReactNode } from "react";
import { Alert } from "react-native";
import { makeTracker, TrackerError, type Tracker } from "./repo";

const Ctx = createContext<Tracker | null>(null);

function Inner({ children }: { children: ReactNode }) {
  const db = useSQLiteContext();
  const tracker = useMemo(() => makeTracker(db, randomUUID), [db]);
  return <Ctx.Provider value={tracker}>{children}</Ctx.Provider>;
}

/** قاعدة بيانات المتتبّع على الجهاز. تُنشأ الجداول عند أول تشغيل. */
export function TrackerProvider({ children }: { children: ReactNode }) {
  return (
    <SQLiteProvider databaseName="tracker.db" onInit={(db) => makeTracker(db, randomUUID).migrate()} useSuspense>
      <Inner>{children}</Inner>
    </SQLiteProvider>
  );
}

export function useTracker(): Tracker {
  const t = useContext(Ctx);
  if (!t) throw new Error("TrackerProvider missing");
  return t;
}

/** يحمّل بيانات الشاشة كلما ظهرت (بعد الرجوع من شاشة أخرى عدّلت البيانات) */
export function useScreenData<T>(load: (t: Tracker) => Promise<T>, deps: unknown[] = []) {
  const tracker = useTracker();
  const [data, setData] = useState<T | undefined>(undefined);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  const reload = useCallback(() => load(tracker).then(setData).catch(showError), [tracker, ...deps]);
  useFocusEffect(useCallback(() => { reload(); }, [reload]));
  return { data, reload };
}

/** أخطاء التحقق تظهر للمستخدم برسالتها؛ غيرها رسالة عامة */
export function showError(err: unknown) {
  if (err instanceof TrackerError) Alert.alert("تنبيه", err.message);
  else { console.error(err); Alert.alert("خطأ", "حدث خطأ غير متوقع. حاول مرة ثانية."); }
}

/** ينفّذ عملية ويعرض خطأها إن وُجد؛ يرجع true عند النجاح */
export async function attempt(fn: () => Promise<unknown>): Promise<boolean> {
  try { await fn(); return true; } catch (e) { showError(e); return false; }
}
