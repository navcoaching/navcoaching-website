"use client";
import { useState } from "react";
import Link from "next/link";
import { checkVideosAction, type VideoCheck as Result } from "@/app/actions/training";

/** زر «فحص روابط الفيديو»: يتأكد أن كل مقاطع التمارين موجودة وتشتغل داخل الموقع */
export default function VideoCheck() {
  const [res, setRes] = useState<Result | null>(null);
  const [busy, setBusy] = useState(false);
  const run = async () => {
    setBusy(true);
    try { setRes(await checkVideosAction()); } catch { setRes({ error: "تعذّر الفحص الآن. حاولي بعد شوي." }); } finally { setBusy(false); }
  };
  return (
    <section className="card stack" data-testid="video-check" style={{ ["--space" as string]: "10px" }}>
      <div className="row" style={{ justifyContent: "space-between", gap: 8 }}>
        <b>🎬 فحص روابط الفيديو</b>
        <button type="button" className="btn btn-ghost btn-sm" onClick={run} disabled={busy}>{busy ? "جارٍ الفحص… (حتى دقيقة)" : "افحص الآن"}</button>
      </div>
      {res?.error && <p className="alert err small" style={{ margin: 0 }}>{res.error}</p>}
      {res?.bad && (res.bad.length === 0
        ? <p className="alert ok small" style={{ margin: 0 }}>كل المقاطع ({res.total}) تشتغل داخل الموقع ✅</p>
        : (
          <>
            <p className="small" style={{ margin: 0 }}>{res.ok} من {res.total} تشتغل. تحتاج مراجعة:</p>
            <ul className="small" style={{ margin: 0, paddingInlineStart: 18 }}>
              {res.bad.map((b) => (
                <li key={b.id}><Link href={`/admin/exercises/${b.id}`}><bdi dir="ltr">{b.name}</bdi></Link> — {b.reason}{" "}
                  <a href={b.url} target="_blank" rel="noopener noreferrer" className="muted">(الرابط)</a></li>
              ))}
            </ul>
          </>
        ))}
      <span className="hint">يتأكد من يوتيوب أن كل مقطع موجود ومسموح تشغيله داخل الموقع. لتبديل مقطع افتحي التمرين وحطي رابط جديد.</span>
    </section>
  );
}
