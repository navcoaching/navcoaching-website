"use client";
import { useEffect, useState } from "react";

type Mode = "auto" | "light" | "dark";
const KEY = "nav_theme";
const NEXT: Record<Mode, Mode> = { auto: "light", light: "dark", dark: "auto" };
const LABEL: Record<Mode, string> = { auto: "تلقائي (حسب الجهاز)", light: "فاتح", dark: "داكن" };

function apply(mode: Mode) {
  const root = document.documentElement;
  if (mode === "auto") delete root.dataset.theme;
  else root.dataset.theme = mode;
  try {
    if (mode === "auto") localStorage.removeItem(KEY);
    else localStorage.setItem(KEY, mode);
  } catch { /* التخزين غير متاح: يبقى الاختيار لهذه الصفحة فقط */ }
}

/** زر المظهر: تلقائي ← فاتح ← داكن. الاختيار محفوظ على جهاز الزائر فقط. */
export default function ThemeToggle({ withLabel = false }: { withLabel?: boolean }) {
  const [mode, setMode] = useState<Mode>("auto");
  useEffect(() => {
    const t = document.documentElement.dataset.theme;
    setMode(t === "light" || t === "dark" ? t : "auto");
  }, []);
  const next = () => { const m = NEXT[mode]; apply(m); setMode(m); };
  const btn = (
    <button type="button" className="theme-btn" onClick={next} aria-label={`المظهر: ${LABEL[mode]}. اضغط للتغيير`} title={`المظهر: ${LABEL[mode]}`}>
      {mode === "dark" ? <Moon /> : mode === "light" ? <Sun /> : <Auto />}
    </button>
  );
  return withLabel ? <div className="theme-row"><span>المظهر: {LABEL[mode]}</span>{btn}</div> : btn;
}

const svg = { width: 20, height: 20, viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", strokeWidth: 1.8, strokeLinecap: "round" as const, strokeLinejoin: "round" as const, "aria-hidden": true };
const Sun = () => <svg {...svg}><circle cx="12" cy="12" r="4" /><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4" /></svg>;
const Moon = () => <svg {...svg}><path d="M20 14.5A8 8 0 1 1 9.5 4a6.5 6.5 0 0 0 10.5 10.5z" /></svg>;
const Auto = () => <svg {...svg}><circle cx="12" cy="12" r="8" /><path d="M12 4a8 8 0 0 1 0 16z" fill="currentColor" /></svg>;
