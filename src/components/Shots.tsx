"use client";
import { useRef, useState } from "react";
import type { Settings } from "@/lib/data";
import { shotSrc } from "@/lib/shot-src";
import { useLang } from "@/lib/use-lang";
import { t } from "@/i18n/ui";

export default function Shots({ shots }: { shots: Settings["program_shots"] }) {
  const dlg = useRef<HTMLDialogElement>(null);
  const [cur, setCur] = useState(0);
  const s = shots[cur];
  const lang = useLang();
  const u = t(lang).common;
  const zoom = t(lang).preview.zoom;
  return (
    <>
      <div className="shots">
        {shots.map((sh, i) => (
          <figure className="shot reveal" key={sh.src} style={{ ["--d" as string]: `${i * 80}ms` }}>
            <button type="button" onClick={() => { setCur(i); dlg.current?.showModal(); }} aria-label={`${zoom} ${sh.title}`}>
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img src={shotSrc(sh.src)} alt={sh.alt} width={sh.w} height={sh.h} loading="eager" decoding="async" />
            </button>
            <figcaption><b>{sh.title} <span className="tag soft sample">{u.sample}</span></b><span>{sh.caption}</span></figcaption>
          </figure>
        ))}
      </div>
      <dialog ref={dlg} className="lightbox" onClick={(e) => { if (e.target === dlg.current) dlg.current?.close(); }}>
        {s && (
          <>
            <div className="lb-bar"><span>{s.title} — {u.sample}</span><button className="btn btn-sm btn-cyan" onClick={() => dlg.current?.close()}>{u.close}</button></div>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={shotSrc(s.src)} alt={s.alt} />
          </>
        )}
      </dialog>
    </>
  );
}
