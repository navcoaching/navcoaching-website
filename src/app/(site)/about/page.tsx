import type { Metadata } from "next";
import Link from "next/link";
import { getApprovedMedia, getSettings } from "@/lib/data";

export const revalidate = 300;
export const metadata: Metadata = { title: "عن المدربة" };

export default async function About() {
  const [s, photos] = await Promise.all([getSettings(), getApprovedMedia("about")]);
  // نفس محتوى وترتيب صفحة «عن المدربة» في الموقع الحالي
  return (
    <>
      <section className="page-hero">
        <div className="wrap">
          <span className="eyebrow">عن المدربة</span>
          <h1 style={{ fontSize: "clamp(32px,6vw,56px)", marginTop: 12 }}>{s.about.name}</h1>
        </div>
      </section>
      <section className="section">
        <div className="wrap">
          <div className="card stack about-card" style={{ ["--space" as string]: "22px", maxWidth: 860 }}>
            <span className="eyebrow">Nav Coaching</span>
            <p className="lead" style={{ color: "var(--text)" }}>{s.about.bio}</p>
            <ol className="about-points">{s.about.points.map((p) => <li key={p}>{p}</li>)}</ol>
            <div className="stack" style={{ ["--space" as string]: "12px" }}>
              <h2 style={{ fontSize: 20 }}>الشهادات والمؤهلات</h2>
              <ul className="certs">{s.about.certs.map((c) => <li key={c}><bdi>{c}</bdi></li>)}</ul>
            </div>
            {photos[0] && (
              // eslint-disable-next-line @next/next/no-img-element
              <img src={`/api/files/media/${photos[0].id}`} alt={photos[0].alt} loading="lazy" style={{ borderRadius: 18, width: "100%", height: "auto" }} />
            )}
            <div><Link className="btn" href="/programs">شوف البرامج</Link></div>
          </div>
        </div>
      </section>
    </>
  );
}
