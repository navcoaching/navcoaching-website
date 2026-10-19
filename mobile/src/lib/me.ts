import { useFocusEffect } from "expo-router";
import { useCallback, useState } from "react";
import { api, type Me } from "./api";
import { authClient } from "./auth-client";

/** هوية المستخدم واشتراكه (null للزائر أو بدون اتصال). يُحدَّث عند ظهور الشاشة. */
export function useMe(): Me | null {
  const { data: session } = authClient.useSession();
  const [me, setMe] = useState<Me | null>(null);
  useFocusEffect(useCallback(() => {
    if (!session) { setMe(null); return; }
    api<Me>("/me").then(setMe).catch(() => setMe(null));
  }, [session?.user.id]));
  return me;
}
