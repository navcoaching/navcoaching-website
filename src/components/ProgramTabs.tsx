"use client";
import { useEffect, useState } from "react";

type Cat = "follow" | "files" | "consult";

/** تبويبات الأقسام في المتصفح، حتى تبقى صفحة البرامج ثابتة وسريعة. يدعم الروابط القديمة ?cat= */
export default function ProgramTabs({ labels, panels }: { labels: Record<Cat, string>; panels: Record<Cat, React.ReactNode> }) {
  const cats = Object.keys(labels) as Cat[];
  const [cur, setCur] = useState<Cat>("follow");
  useEffect(() => {
    const q = new URLSearchParams(window.location.search).get("cat") as Cat | null;
    if (q && cats.includes(q)) setCur(q);
  }, []); // eslint-disable-line react-hooks/exhaustive-deps
  const pick = (c: Cat) => {
    setCur(c);
    const url = new URL(window.location.href);
    url.searchParams.set("cat", c);
    window.history.replaceState(null, "", url);
  };
  return (
    <>
      <div className="tabs" role="tablist" aria-label="نوع البرنامج">
        {cats.map((c) => (
          <a key={c} role="tab" href={`?cat=${c}`} aria-selected={c === cur} aria-current={c === cur ? "true" : undefined}
            onClick={(e) => { e.preventDefault(); pick(c); }}>{labels[c]}</a>
        ))}
      </div>
      {cats.map((c) => <div key={c} role="tabpanel" hidden={c !== cur}>{panels[c]}</div>)}
    </>
  );
}
