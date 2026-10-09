import type { Metadata } from "next";
import { requireUser } from "@/lib/session";
import { COLORS, GUIDE } from "@/lib/guide";
import shots from "@/lib/guide-shots.json";

export const metadata: Metadata = { title: "دليل الاستخدام", robots: { index: false } };

type Box = { x: number; y: number; w: number; h: number };
type Shot = { w: number; h: number; markers: Record<string, Box> };
const SHOTS = shots as Record<string, Shot>;

/** الدليل المصوّر: صور من الموقع ببيانات تجريبية، والأرقام البرتقالية تطابق الخطوات */
export default async function GuidePage() {
  await requireUser("/account/guide");
  return (
    <section className="section tight">
      <div className="wrap stack guide" style={{ ["--space" as string]: "22px" }}>
        <div>
          <h1 style={{ fontSize: "clamp(24px,4vw,32px)", margin: 0 }}>📖 دليل الاستخدام المصوّر</h1>
          <p className="muted" style={{ margin: "6px 0 0" }}>الأرقام البرتقالية في الصور تطابق أرقام الخطوات. البيانات في الصور تجريبية للتوضيح فقط.</p>
        </div>
        <nav className="pill-nav" aria-label="أقسام الدليل">
          {GUIDE.map((s) => <a key={s.id} href={`#${s.id}`}>{s.title.replace(/^[^ ]+ /, "")}</a>)}
        </nav>

        <section className="card stack" aria-labelledby="colors-h">
          <h2 id="colors-h" style={{ fontSize: 18 }}>معاني الألوان والعلامات</h2>
          <ul className="guide-colors">
            {COLORS.map(([cls, label, body]) => <li key={cls}><span className={`status ${cls}`}>{label}</span> {body}</li>)}
          </ul>
        </section>

        {GUIDE.map((sec) => (
          <section key={sec.id} id={sec.id} className="stack guide-section" style={{ ["--space" as string]: "14px" }} aria-labelledby={`${sec.id}-h`}>
            <h2 id={`${sec.id}-h`} style={{ fontSize: 22 }}>{sec.title}</h2>
            {sec.intro && <p style={{ margin: 0 }}>{sec.intro}</p>}
            {sec.shots.map((g) => {
              const shot = SHOTS[g.key];
              return (
                <div key={g.key} className="card guide-shot" data-testid={`guide-${g.key}`}>
                  {shot ? (
                    <figure className="guide-figure">
                      <div className="guide-img" style={{ aspectRatio: `${shot.w} / ${shot.h}` }}>
                        {/* eslint-disable-next-line @next/next/no-img-element */}
                        <img src={`/guide/${g.key}.png`} alt={g.caption} width={shot.w} height={shot.h} loading="lazy" />
                        {Object.entries(shot.markers).map(([n, b]) => (
                          <span key={n} aria-hidden="true">
                            <span className="guide-box" style={{ left: `${b.x}%`, top: `${b.y}%`, width: `${b.w}%`, height: `${b.h}%` }} />
                            <span className="guide-num" style={{ left: `${Math.min(96, b.x + b.w)}%`, top: `${b.y}%` }}>{n}</span>
                          </span>
                        ))}
                      </div>
                      <figcaption className="small muted">{g.caption}</figcaption>
                    </figure>
                  ) : <p className="small muted">{g.caption}</p>}
                  <ol className="guide-steps">
                    {g.steps.map((st, i) => (
                      <li key={i}><span className="guide-num static">{i + 1}</span><div><b>{st.title}</b><p>{st.body}</p></div></li>
                    ))}
                  </ol>
                </div>
              );
            })}
            {sec.warn && <p className="alert warn" style={{ margin: 0 }}>⚠️ {sec.warn}</p>}
          </section>
        ))}
      </div>
    </section>
  );
}
