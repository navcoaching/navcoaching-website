import Header from "@/components/Header";
import Footer from "@/components/Footer";
import Reveal from "@/components/Reveal";
import CardFx from "@/components/CardFx";
import Analytics from "@/components/Analytics";
import { getSettings } from "@/lib/data";

export default async function SiteLayout({ children }: { children: React.ReactNode }) {
  const s = await getSettings();
  return (
    <>
      <a href="#main" className="skip">تخطَّ إلى المحتوى</a>
      <Header />
      <main id="main">{children}</main>
      <Footer s={s} />
      <Reveal />
      <CardFx />
      {s.analytics?.ga_id && /^G-[A-Z0-9]{6,12}$/.test(s.analytics.ga_id) && <Analytics id={s.analytics.ga_id} />}
    </>
  );
}
