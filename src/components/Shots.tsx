"use client";
import { useRef, useState } from "react";
import type { Settings } from "@/lib/data";

export default function Shots({ shots }: { shots: Settings["program_shots"] }) {
  const dlg = useRef<HTMLDialogElement>(null);
  const [cur, setCur] = useState(0);
  const s = shots[cur];
  return (
    <>
      <div className="shots">
        {shots.map((sh, i) => (
          <figure className="shot reveal" key={sh.src} style={{ ["--d" as string]: `${i * 80}ms` }}>
            <button type="button" onClick={() => { setCur(i); dlg.current?.showModal(); }} aria-label={`تكبير: ${sh.title}`}>
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img src={sh.src} alt={sh.alt} width={sh.w} height={sh.h} loading="lazy" decoding="async" />
              <span className="tag soft sample">نموذج توضيحي</span>
            </button>
            <figcaption><b>{sh.title}</b><span>{sh.caption}</span></figcaption>
          </figure>
        ))}
      </div>
      <dialog ref={dlg} className="lightbox" onClick={(e) => { if (e.target === dlg.current) dlg.current?.close(); }}>
        {s && (
          <>
            <div className="lb-bar"><span>{s.title} — نموذج توضيحي</span><button className="btn btn-sm btn-cyan" onClick={() => dlg.current?.close()}>إغلاق</button></div>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={s.src} alt={s.alt} />
          </>
        )}
      </dialog>
    </>
  );
}
