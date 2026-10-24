import Link from "next/link";
import Image from "next/image";
import type { Settings } from "@/lib/data";
import { waLink } from "@/lib/format";
import { href, type Lang } from "@/lib/lang";
import { t } from "@/i18n/ui";
import { IconInstagram, IconTikTok, IconWhatsApp } from "./Icons";
import LangSwitch from "./LangSwitch";

export default function Footer({ s, hasFreePlans = true, lang = "ar" }: { s: Settings; hasFreePlans?: boolean; lang?: Lang }) {
  const u = t(lang).footer;
  const L = (p: string) => href(lang, p);
  return (
    <footer className="site-footer">
      <div className="wrap">
        <div className="foot-grid">
          <div className="stack" style={{ ["--space" as string]: "14px" }}>
            <Image src="/brand/logo-white.webp" alt="Nav Coaching" width={150} height={34} />
            <p>{u.tagline}</p>
            <p className="small">{u.hours} {s.response_time}</p>
            <div className="social" aria-label={u.social}>
              <a href={waLink(s.contact.whatsapp)} target="_blank" rel="noopener" aria-label={u.whatsapp} title={u.whatsapp} className="wa"><IconWhatsApp size={24} /></a>
              {s.contact.instagram && <a href={s.contact.instagram} target="_blank" rel="noopener" aria-label={u.instagram} title={u.instagram} className="ig"><IconInstagram size={24} /></a>}
              {s.contact.tiktok && <a href={s.contact.tiktok} target="_blank" rel="noopener" aria-label={u.tiktok} title={u.tiktok} className="tt"><IconTikTok size={22} /></a>}
            </div>
            <p className="small"><span className="muted">{u.language}: </span><LangSwitch className="text-link" /></p>
          </div>
          <div>
            <h2>{u.site}</h2>
            <ul>
              <li><Link href={L("/programs")}>{t(lang).nav.pricing}</Link></li>
              <li><Link href={L("/booklets")}>{u.booklets}</Link></li>
              <li><Link href={L("/about")}>{t(lang).nav.about}</Link></li>
              <li><Link href={L("/reviews")}>{u.reviews}</Link></li>
              <li><Link href={L("/faq")}>{t(lang).nav.faq}</Link></li>
              <li><Link href="/account">{u.myAccount}</Link></li>
            </ul>
          </div>
          <div>
            <h2>{u.tools}</h2>
            <ul>
              <li><Link href={L("/calculator")}>{u.calculator}</Link></li>
              {hasFreePlans && <li><Link href={L("/free-plans")}>{u.freePlans}</Link></li>}
              {s.guide_video?.url && <li><Link href={L("/video-guide")}>{u.guideVideo}</Link></li>}
              <li><Link href={L("/program-preview")}>{u.preview}</Link></li>
            </ul>
          </div>
          <div>
            <h2>{u.policies}</h2>
            <ul>
              <li><Link href={L("/policies#privacy")}>{u.privacy}</Link></li>
              <li><Link href={L("/policies#terms")}>{u.terms}</Link></li>
              <li><Link href={L("/policies#refund")}>{u.refund}</Link></li>
              <li><Link href={L("/policies#reviews")}>{u.reviewsPolicy}</Link></li>
            </ul>
          </div>
        </div>
        <div className="foot-legal">
          <span>{s.legal.name} · {u.cr} <bdi>{s.legal.cr}</bdi></span>
          <span>© Nav Coaching · {u.rights}</span>
        </div>
      </div>
    </footer>
  );
}
