import Header from "@/components/Header";
import Footer from "@/components/Footer";
import Reveal from "@/components/Reveal";
import CardFx from "@/components/CardFx";
import ScrollStory from "@/components/home/ScrollStory";
import Analytics from "@/components/Analytics";
import MobileBar from "@/components/MobileBar";
import { getFreePlans, getSettings } from "@/lib/data";
import { isLang } from "@/lib/lang";
import { t } from "@/i18n/ui";

export default async function SiteLayout({ children, params }: { children: React.ReactNode; params: Promise<{ lang: string }> }) {
  const { lang: raw } = await params;
  const lang = isLang(raw) ? raw : "ar";
  const [s, freePlans] = await Promise.all([getSettings(lang), getFreePlans(null, undefined, lang).catch(() => [])]);
  return (
    <>
      <a href="#main" className="skip">{t(lang).nav.skip}</a>
      <Header lang={lang} />
      <main id="main">{children}</main>
      <Footer s={s} hasFreePlans={freePlans.length > 0} lang={lang} />
      <MobileBar whatsapp={s.contact.whatsapp} />
      <Reveal />
      <ScrollStory />
      <CardFx />
      {s.analytics?.ga_id && /^G-[A-Z0-9]{6,12}$/.test(s.analytics.ga_id) && <Analytics id={s.analytics.ga_id} />}
    </>
  );
}
