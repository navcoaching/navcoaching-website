import { useEffect, useState } from "react";
import { api, type Addon } from "./api";

let cache: Addon[] | null = null;

/** خدمات الكوتش الإضافية المنشورة (من لوحة الإدارة) */
export function useAddons() {
  const [addons, setAddons] = useState<Addon[] | null>(cache);
  const [failed, setFailed] = useState(false);
  useEffect(() => {
    api<{ addons: Addon[] }>("/addons").then((r) => { cache = r.addons; setAddons(r.addons); }).catch(() => setFailed(true));
  }, []);
  return { addons, failed };
}
