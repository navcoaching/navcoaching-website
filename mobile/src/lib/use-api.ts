import { useFocusEffect } from "expo-router";
import { useCallback, useState } from "react";
import { api, ApiError } from "./api";

/** يحمّل واجهة من /api/mobile/v1 عند ظهور الشاشة. error = "login" إذا انتهت الجلسة. */
export function useApi<T>(path: string) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<string | null>(null);
  const reload = useCallback(async () => {
    try { setData(await api<T>(path)); setError(null); }
    catch (e) { setError(e instanceof ApiError && e.status === 401 ? "login" : "تعذّر التحميل. تأكد من الاتصال."); }
  }, [path]);
  useFocusEffect(useCallback(() => { reload(); }, [reload]));
  return { data, error, reload };
}
