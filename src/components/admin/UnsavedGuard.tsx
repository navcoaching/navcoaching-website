"use client";
import { useEffect, useState } from "react";

/** صفحات فيها أكثر من نموذج حفظ مستقل: تنبيه إذا فيه تعديل ما انحفظ قبل مغادرة الصفحة،
 *  وسطر ثابت يذكّر بالأقسام اللي تحتاج «حفظ» (الحفظ لكل قسم لحاله) */
export default function UnsavedGuard() {
  const [dirty, setDirty] = useState<string[]>([]);
  useEffect(() => {
    const forms = new Set<HTMLFormElement>();
    const name = (f: HTMLFormElement) => f.closest("section, .card")?.querySelector("h2, h3")?.textContent?.trim() || "قسم";
    const sync = () => setDirty([...forms].filter((f) => f.isConnected).map(name));
    const onInput = (e: Event) => {
      const f = (e.target as HTMLElement).closest?.("form");
      if (f && f.closest(".admin-main")) { forms.add(f); sync(); }
    };
    const onSubmit = (e: Event) => { forms.delete(e.target as HTMLFormElement); sync(); };
    const onLeave = (e: BeforeUnloadEvent) => { if ([...forms].some((f) => f.isConnected)) { e.preventDefault(); e.returnValue = ""; } };
    document.addEventListener("input", onInput, true);
    document.addEventListener("submit", onSubmit, true);
    window.addEventListener("beforeunload", onLeave);
    return () => { document.removeEventListener("input", onInput, true); document.removeEventListener("submit", onSubmit, true); window.removeEventListener("beforeunload", onLeave); };
  }, []);
  if (!dirty.length) return null;
  return (
    <p className="unsaved-bar" role="status" data-testid="unsaved-bar">
      تعديلات غير محفوظة في: <b>{[...new Set(dirty)].join("، ")}</b>. كل قسم يُحفظ بزر «حفظ» الخاص فيه.
    </p>
  );
}
