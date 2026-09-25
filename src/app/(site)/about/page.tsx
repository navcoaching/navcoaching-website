import type { Metadata } from "next";
import Link from "next/link";
import { getApprovedMedia, getSettings } from "@/lib/data";

export const revalidate = 300;
export const metadata: Metadata = { title: "عن المدربة" };

export default async function About() {
  const [s, photos] = await Promise.all([getSettings(), getApprovedMedia("about")]);
  return (
    <>
      <section className="page-hero">
        <div className="wrap">
          <span className="eyebrow">عن المدربة</span>
          <h1 style={{ fontSize: "clamp(30px,5vw,50px)", marginTop: 12 }}>{s.about.name}</h1>
          <p className="lead">{s.about.bio}</p>
        </div>
      </section>
      <section className="section">
        <div className="wrap grid g2" style={{ alignItems: "start" }}>
          <div className="stack">
            <ul className="checklist" style={{ fontSize: 18 }}>{s.about.points.map((p) => <li key={p}>{p}</li>)}</ul>
            {photos[0] && (
              // eslint-disable-next-line @next/next/no-img-element
              <img src={`/api/files/media/${photos[0].id}`} alt={photos[0].alt} loading="lazy" style={{ borderRadius: 22, width: "100%", height: "auto" }} />
            )}
            <div className="row"><Link className="btn" href="/programs">شوف البرامج</Link></div>
          </div>
          <div className="card">
            <h2 style={{ fontSize: 22, marginBottom: 14 }}>الشهادات والمؤهلات</h2>
            <ul className="checklist">{s.about.certs.map((c) => <li key={c}><bdi>{c}</bdi></li>)}</ul>
          </div>
        </div>
      </section>
    </>
  );
}
