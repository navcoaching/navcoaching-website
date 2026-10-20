import { createAuthClient } from "better-auth/react";
import { emailOTPClient } from "better-auth/client/plugins";
import { expoClient } from "@better-auth/expo/client";
import * as SecureStore from "expo-secure-store";
import { API_URL } from "./config";

/** نفس دخول الموقع (رمز من 6 أرقام يصل للبريد). الجلسة تُحفظ مشفّرة في SecureStore على الجهاز. */
export const authClient = createAuthClient({
  baseURL: API_URL,
  plugins: [
    expoClient({ scheme: "navcoaching", storagePrefix: "navcoaching", storage: SecureStore }),
    emailOTPClient(),
  ],
});
