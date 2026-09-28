"use client";
import { useEffect } from "react";

/** يسجّل Service Worker (إشعارات الجوال + صفحة عدم الاتصال). لا يعمل في وضع التطوير. */
export default function SwRegister() {
  useEffect(() => {
    if (!("serviceWorker" in navigator) || process.env.NODE_ENV !== "production") return;
    navigator.serviceWorker.register("/sw.js", { scope: "/", updateViaCache: "none" }).catch(() => {});
  }, []);
  return null;
}
