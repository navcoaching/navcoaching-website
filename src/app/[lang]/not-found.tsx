import type { Metadata } from "next";
import Link from "next/link";
import { lang as rootLang } from "next/root-params";
import { href, isLang } from "@/lib/lang";
import { t } from "@/i18n/ui";

export async function generateMetadata(): Promise<Metadata> {
  const l = (await rootLang()) ?? "ar";
  return { title: t(isLang(l) ? l : "ar").notFound.title, robots: { index: false } };
}

export default async function NotFound() {
  const l = (await rootLang()) ?? "ar";
  const lang = isLang(l) ? l : "ar";
  const u = t(lang).notFound;
  return (
    <main className="section" id="main">
      <div className="wrap stack center" style={{ maxWidth: 560 }}>
        <p className="eyebrow" style={{ justifyContent: "center" }}>404</p>
        <h1 style={{ fontSize: 34 }}>{u.title}</h1>
        <p className="muted">{u.text}</p>
        <div className="row" style={{ justifyContent: "center" }}><Link className="btn" href={href(lang, "/")}>{u.home}</Link><Link className="btn btn-ghost" href="/account">{u.account}</Link></div>
      </div>
    </main>
  );
}
