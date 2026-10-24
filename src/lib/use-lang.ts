"use client";
import { usePathname } from "next/navigation";
import { langOfPath } from "./lang";

/** لغة الصفحة الحالية في مكونات المتصفح (من المسار: /en/... إنجليزي، وغيره عربي) */
export const useLang = () => langOfPath(usePathname());
