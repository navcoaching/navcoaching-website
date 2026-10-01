import Header from "@/components/Header";
import Footer from "@/components/Footer";
import Reveal from "@/components/Reveal";
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
    </>
  );
}
