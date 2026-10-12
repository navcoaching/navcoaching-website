import Header from "@/components/Header";
import Footer from "@/components/Footer";
import Reveal from "@/components/Reveal";
import CardFx from "@/components/CardFx";
import Analytics from "@/components/Analytics";
import { getFreePlans, getSettings } from "@/lib/data";

export default async function SiteLayout({ children }: { children: React.ReactNode }) {
  const [s, freePlans] = await Promise.all([getSettings(), getFreePlans(null).catch(() => [])]);
  return (
    <>
      <a href="#main" className="skip">الانتقال إلى المحتوى</a>
      <Header />
      <main id="main">{children}</main>
      <Footer s={s} hasFreePlans={freePlans.length > 0} />
      <Reveal />
      <CardFx />
      {s.analytics?.ga_id && /^G-[A-Z0-9]{6,12}$/.test(s.analytics.ga_id) && <Analytics id={s.analytics.ga_id} />}
    </>
  );
}
