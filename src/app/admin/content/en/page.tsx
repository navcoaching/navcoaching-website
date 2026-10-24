import Link from "next/link";
import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import ActionForm from "@/components/admin/ActionForm";
import UnsavedGuard from "@/components/admin/UnsavedGuard";
import { saveTranslationAction } from "@/app/actions/admin";

export const metadata = { title: "النسخة الإنجليزية" };

type En = Record<string, unknown>;
const s = (v: unknown) => (typeof v === "string" ? v : "");
const arr = (v: unknown) => (Array.isArray(v) ? v : []);
const joinLines = (v: unknown) => arr(v).map((x) => (typeof x === "string" ? x : s((x as { text?: string })?.text))).join("\n");
const joinPairs = (v: unknown) => arr(v).map((x) => `${s((x as En)?.title)} | ${s((x as En)?.body)}`).join("\n");

const F = ({ label, name, value, long }: { label: string; name: string; value: string; long?: boolean }) => (
  <div className="field"><label>{label}</label>{long ? <textarea name={name} defaultValue={value} dir="ltr" style={{ minHeight: 120 }} /> : <input name={name} type="text" defaultValue={value} dir="ltr" />}</div>
);
const Hidden = ({ kind, id }: { kind: string; id: string }) => (<><input type="hidden" name="kind" value={kind} /><input type="hidden" name="id" value={id} /></>);

/** ترجمة محتوى الموقع العام إلى الإنجليزية: كل صف له نموذجه، والفارغ يُعرض بالعربية. لا يمس النصوص العربية. */
export default async function AdminEnglish() {
  const coach = await requireCoach();
  const d = await withUser(coach.id, async (tx) => ({
    products: (await tx.query("SELECT id, slug, name, audience, note, delivery, requirements, policy_note, items, i18n FROM products WHERE booklet_id IS NULL ORDER BY sort")).rows,
    faqs: (await tx.query("SELECT id, question, answer, i18n FROM faqs ORDER BY sort")).rows,
    policies: (await tx.query("SELECT slug, title, body, i18n FROM policies ORDER BY sort")).rows,
    settings: Object.fromEntries((await tx.query("SELECT key, value, i18n FROM site_settings WHERE key = ANY($1)", [["hero", "badges", "why", "how_steps", "about", "testimonials_disclaimer", "prices_note", "response_time"]])).rows.map((r) => [r.key, { ar: r.value, en: (r.i18n?.en ?? {}) as En }])),
    plans: (await tx.query("SELECT id, slug, title, summary, audience, i18n FROM free_plans ORDER BY sort")).rows,
    booklets: (await tx.query("SELECT id, title, description, i18n FROM booklets ORDER BY sort")).rows,
  }));
  const en = (row: { i18n?: { en?: En } }) => row.i18n?.en ?? {};
  const st = (k: string) => d.settings[k] ?? { ar: null, en: {} };
  const H = ({ id, children }: { id: string; children: React.ReactNode }) => <h2 id={id} style={{ fontSize: 20 }}>{children}</h2>;
  const Ar = ({ children }: { children: React.ReactNode }) => <p className="small muted" style={{ margin: 0, whiteSpace: "pre-wrap" }}>{children}</p>;

  return (
    <div className="stack" style={{ ["--space" as string]: "22px" }}>
      <nav className="small"><Link href="/admin/content">المحتوى والإعدادات</Link> / النسخة الإنجليزية</nav>
      <h1>النسخة الإنجليزية</h1>
      <p className="muted">الموقع الإنجليزي على <bdi dir="ltr">/en</bdi>. كل حقل هنا يُعرض مكان نظيره العربي في الصفحات الإنجليزية، والحقل الفارغ يُعرض بالعربية. النص العربي الأصلي يظهر تحت كل عنوان للمقارنة، ولا يتغير من هنا.</p>
      <nav className="pill-nav">{[["hero", "الواجهة"], ["about", "عن المدربة"], ["products", "الباقات"], ["faq", "الأسئلة"], ["policies", "السياسات"], ["plans", "الجداول المجانية"], ["booklets", "الكتيبات"]].map(([id, l]) => <a key={id} href={`#${id}`}>{l}</a>)}</nav>

      <section className="card stack">
        <H id="hero">الواجهة والنصوص العامة</H>
        <ActionForm action={saveTranslationAction}><Hidden kind="setting" id="hero" />
          <Ar>{s((st("hero").ar as En)?.title)} {s((st("hero").ar as En)?.title_tail)} — {s((st("hero").ar as En)?.lead)}</Ar>
          <F label="Eyebrow" name="eyebrow" value={s(st("hero").en.eyebrow)} /><F label="Title" name="title" value={s(st("hero").en.title)} /><F label="Title (highlighted tail)" name="title_tail" value={s(st("hero").en.title_tail)} /><F label="Lead" name="lead" value={s(st("hero").en.lead)} long /><F label="Tagline" name="tagline" value={s(st("hero").en.tagline)} />
        </ActionForm>
        <ActionForm action={saveTranslationAction} submit="حفظ الشارات"><Hidden kind="setting" id="badges" /><Ar>{arr(st("badges").ar).join(" · ")}</Ar><F label="Badges (one per line)" name="value" value={joinLines(st("badges").en)} long /></ActionForm>
        <ActionForm action={saveTranslationAction} submit="حفظ «ليش Nav»"><Hidden kind="setting" id="why" /><Ar>{joinPairs(st("why").ar)}</Ar><F label="Why Nav (title | body, one per line)" name="value" value={joinPairs(st("why").en)} long /></ActionForm>
        <ActionForm action={saveTranslationAction} submit="حفظ الخطوات"><Hidden kind="setting" id="how_steps" /><Ar>{joinPairs(st("how_steps").ar)}</Ar><F label="How to start (title | body, one per line)" name="value" value={joinPairs(st("how_steps").en)} long /></ActionForm>
        <ActionForm action={saveTranslationAction} submit="حفظ"><Hidden kind="setting" id="testimonials_disclaimer" /><Ar>{s(st("testimonials_disclaimer").ar)}</Ar><F label="Reviews disclaimer" name="value" value={s(st("testimonials_disclaimer").en)} long /></ActionForm>
        <ActionForm action={saveTranslationAction} submit="حفظ"><Hidden kind="setting" id="prices_note" /><Ar>{s(st("prices_note").ar)}</Ar><F label="Prices note" name="value" value={s(st("prices_note").en)} /></ActionForm>
        <ActionForm action={saveTranslationAction} submit="حفظ"><Hidden kind="setting" id="response_time" /><Ar>{s(st("response_time").ar)}</Ar><F label="Reply time and working hours" name="value" value={s(st("response_time").en)} /></ActionForm>
      </section>

      <section className="card stack">
        <H id="about">عن المدربة</H>
        {(() => { const a = (st("about").ar ?? {}) as En; const e = st("about").en; return (
          <ActionForm action={saveTranslationAction}><Hidden kind="setting" id="about" />
            <Ar>{s(a.name)} — {s(a.bio)}</Ar>
            <F label="Name" name="name" value={s(e.name)} /><F label="Bio (about page)" name="bio" value={s(e.bio)} long /><F label="Bio (home)" name="home_bio" value={s(e.home_bio)} long />
            <F label="Story title" name="story_title" value={s(e.story_title)} /><F label="Story (one paragraph per line)" name="story" value={joinLines(e.story)} long />
            <F label="Approach title" name="pillars_title" value={s(e.pillars_title)} /><F label="Approach (title | body)" name="pillars" value={joinPairs(e.pillars)} long />
            <F label="Who is it for — title" name="fit_title" value={s(e.fit_title)} /><F label="Who is it for (one paragraph per line)" name="fit" value={joinLines(e.fit)} long />
            <F label="Notes (title | body | link | link text)" name="notes" value={arr(e.notes).map((n) => [s((n as En).title), s((n as En).body), s((n as En).href), s((n as En).label)].join(" | ")).join("\n")} long />
            <F label="Experience title" name="experience_title" value={s(e.experience_title)} /><F label="Experience (one per line)" name="experience" value={joinLines(e.experience)} long /><F label="Certifications (one per line)" name="certs" value={joinLines(e.certs)} long />
            <input type="hidden" name="points" value={joinLines(e.points)} />
          </ActionForm>); })()}
      </section>

      <section className="card stack">
        <H id="products">الباقات والخدمات</H>
        {d.products.map((p) => (
          <details key={p.id} className="card flat"><summary style={{ cursor: "pointer", minHeight: 44 }}>{p.name} {!en(p).name && <span className="tag soft">بلا ترجمة</span>}</summary>
            <ActionForm action={saveTranslationAction}><Hidden kind="product" id={p.id} />
              <Ar>{p.audience}</Ar>
              <F label="Name" name="name" value={s(en(p).name)} /><F label="Who it’s for" name="audience" value={s(en(p).audience)} long /><F label="Short note" name="note" value={s(en(p).note)} />
              <Ar>{arr(p.items).map((it) => `${(it as En).included ? "" : "- "}${s((it as En).text)}`).join("\n")}</Ar>
              <F label="What’s included (one per line, same order as Arabic; included/excluded follows the Arabic)" name="items" value={joinLines(en(p).items)} long />
              <F label="Delivery and follow-up" name="delivery" value={s(en(p).delivery)} long /><F label="Required before starting" name="requirements" value={s(en(p).requirements)} long /><F label="Payment and refund note" name="policy_note" value={s(en(p).policy_note)} long />
            </ActionForm>
          </details>
        ))}
      </section>

      <section className="card stack">
        <H id="faq">الأسئلة الشائعة</H>
        {d.faqs.map((f) => (
          <details key={f.id} className="card flat"><summary style={{ cursor: "pointer", minHeight: 44 }}>{f.question} {!en(f).question && <span className="tag soft">بلا ترجمة</span>}</summary>
            <ActionForm action={saveTranslationAction}><Hidden kind="faq" id={f.id} /><Ar>{f.answer}</Ar><F label="Question" name="question" value={s(en(f).question)} /><F label="Answer" name="answer" value={s(en(f).answer)} long /></ActionForm>
          </details>
        ))}
      </section>

      <section className="card stack">
        <H id="policies">السياسات</H>
        {d.policies.map((p) => (
          <details key={p.slug} className="card flat"><summary style={{ cursor: "pointer", minHeight: 44 }}>{p.title} {!en(p).title && <span className="tag soft">بلا ترجمة</span>}</summary>
            <ActionForm action={saveTranslationAction}><Hidden kind="policy" id={p.slug} /><Ar>{p.body}</Ar><F label="Title" name="title" value={s(en(p).title)} /><F label="Body (one item per line starting with “- ”)" name="body" value={s(en(p).body)} long /></ActionForm>
          </details>
        ))}
      </section>

      <section className="card stack">
        <H id="plans">الجداول المجانية</H>
        {d.plans.length === 0 && <p className="small muted">لا توجد جداول.</p>}
        {d.plans.map((p) => (
          <details key={p.id} className="card flat"><summary style={{ cursor: "pointer", minHeight: 44 }}>{p.title} {!en(p).title && <span className="tag soft">بلا ترجمة</span>}</summary>
            <ActionForm action={saveTranslationAction}><Hidden kind="free_plan" id={p.id} /><Ar>{p.summary}</Ar><F label="Title" name="title" value={s(en(p).title)} /><F label="Summary" name="summary" value={s(en(p).summary)} long /><F label="Audience" name="audience" value={s(en(p).audience)} /></ActionForm>
          </details>
        ))}
      </section>

      <section className="card stack">
        <H id="booklets">الكتيبات</H>
        {d.booklets.length === 0 && <p className="small muted">لا توجد كتيبات.</p>}
        {d.booklets.map((b) => (
          <details key={b.id} className="card flat"><summary style={{ cursor: "pointer", minHeight: 44 }}>{b.title} {!en(b).title && <span className="tag soft">بلا ترجمة</span>}</summary>
            <ActionForm action={saveTranslationAction}><Hidden kind="booklet" id={b.id} /><Ar>{b.description}</Ar><F label="Title" name="title" value={s(en(b).title)} /><F label="Description" name="description" value={s(en(b).description)} long /></ActionForm>
          </details>
        ))}
      </section>
      <UnsavedGuard />
    </div>
  );
}
