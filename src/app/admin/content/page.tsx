import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import { getSettings } from "@/lib/data";
import { youtubeId } from "@/lib/youtube";
import ActionForm from "@/components/admin/ActionForm";
import { loadReminders } from "@/lib/reminders";
import { saveFaqAction, savePolicyAction, saveSettingAction } from "@/app/actions/admin";
import VapidKeys from "@/components/admin/VapidKeys";
import { pushConfigured, pushMock } from "@/lib/push";

export default async function AdminContent() {
  const coach = await requireCoach();
  const [s, { faqs, policies, heroMedia, rem }] = await Promise.all([
    getSettings(),
    withUser(coach.id, async (tx) => ({
      faqs: (await tx.query("SELECT * FROM faqs ORDER BY sort")).rows,
      policies: (await tx.query("SELECT * FROM policies ORDER BY sort")).rows,
      // إعداد التذكيرات غير عام (is_public=false) فيُقرأ بصلاحية المدربة
      rem: await loadReminders(tx),
      heroMedia: (await tx.query("SELECT id, alt FROM media_assets WHERE approved AND usage = 'hero' ORDER BY created_at DESC")).rows as { id: string; alt: string }[],
    })),
  ]);
  const vid = youtubeId(s.intro_video?.url);
  const H = ({ children, id }: { children: React.ReactNode; id: string }) => <h2 id={id} style={{ fontSize: 20 }}>{children}</h2>;

  return (
    <div className="stack" style={{ ["--space" as string]: "22px" }}>
      <h1>المحتوى والإعدادات</h1>
      <nav className="pill-nav">
        {[["video", "مقطع التعريف"], ["hero", "الواجهة"], ["contact", "التواصل ومدة الرد"], ["bank", "الحساب البنكي"], ["about", "عن المدربة"], ["checkins", "المراجعة الأسبوعية"], ["reminders", "التنبيهات والتذكيرات"], ["push", "إشعارات الجوال"], ["faq", "الأسئلة الشائعة"], ["policies", "السياسات"]].map(([id, l]) => <a key={id} href={`#${id}`}>{l}</a>)}
      </nav>

      <section className="card stack" aria-labelledby="push" data-testid="push-settings">
        <H id="push">إشعارات الجوال (التطبيق)</H>
        {pushConfigured() && !pushMock() ? (
          <p className="alert ok small" style={{ margin: 0 }}>مفعّلة. المتدرب يفعّلها من «حسابي» ← إشعارات الجوال، وتوصله نفس تنبيهات البريد وواتساب على جواله.</p>
        ) : (
          <>
            <p className="small" style={{ margin: 0 }}>غير مفعّلة بعد. خطوة وحدة: ولّدي المفاتيح هنا، وانسخيها لمتغيرات Netlify، ثم أعيدي النشر. بعدها يظهر للمتدربين زر «فعّل الإشعارات».</p>
            <VapidKeys email={coach.email} />
          </>
        )}
      </section>

      <section className="card stack">
        <H id="video">مقطع التعريف (YouTube Shorts)</H>
        <p className="small muted">القسم يظهر في الصفحة الرئيسية فقط بعد إضافة رابط صالح. الحالة الآن: <b>{vid ? "ظاهر" : "مخفي (لا يوجد رابط)"}</b>. الفيديو لا يعمل تلقائياً؛ يشتغل بعد نقر الزائر.</p>
        <ActionForm action={saveSettingAction}>
          <input type="hidden" name="key" value="intro_video" />
          <div className="field"><label>رابط المقطع</label><input name="url" type="url" dir="ltr" defaultValue={s.intro_video?.url} placeholder="https://youtube.com/shorts/XXXXXXXXXXX" /></div>
          <div className="field"><label>العنوان</label><input name="title" type="text" defaultValue={s.intro_video?.title} maxLength={80} /></div>
          <div className="field"><label>النص التعريفي</label><textarea name="body" defaultValue={s.intro_video?.body} maxLength={400} /></div>
        </ActionForm>
      </section>

      <section className="card stack">
        <H id="hero">الواجهة الرئيسية</H>
        <ActionForm action={saveSettingAction}>
          <input type="hidden" name="key" value="hero" />
          <div className="field"><label>السطر الصغير</label><input name="eyebrow" type="text" defaultValue={s.hero.eyebrow} /></div>
          <div className="field"><label>العنوان</label><input name="title" type="text" defaultValue={s.hero.title} /></div>
          <div className="field"><label>تكملة العنوان</label><input name="title_tail" type="text" defaultValue={s.hero.title_tail} /></div>
          <div className="field"><label>الوصف</label><textarea name="lead" defaultValue={s.hero.lead} /></div>
          <div className="field"><label>الشعار اللفظي</label><input name="tagline" type="text" defaultValue={s.hero.tagline} /></div>
        </ActionForm>
        <ActionForm action={saveSettingAction} submit="حفظ الشارات">
          <input type="hidden" name="key" value="badges" />
          <div className="field"><label>الشارات تحت العنوان (سطر لكل شارة)</label><textarea name="value" defaultValue={s.badges.join("\n")} /></div>
        </ActionForm>
        <ActionForm action={saveSettingAction} submit="حفظ صورة الواجهة">
          <input type="hidden" name="key" value="hero_image" />
          <div className="field"><label>صورة الواجهة (من الصور المعتمدة بنوع «الواجهة»)</label>
            <select name="media_id" defaultValue={s.hero_image?.media_id ?? ""}><option value="">الرسم التوضيحي الافتراضي</option>{heroMedia.map((m) => <option key={m.id} value={m.id}>{m.alt}</option>)}</select>
          </div>
        </ActionForm>
      </section>

      <section className="card stack">
        <H id="contact">التواصل ومدة الرد</H>
        <ActionForm action={saveSettingAction}>
          <input type="hidden" name="key" value="response_time" />
          <div className="field"><label>مدة الرد وساعات العمل (تظهر في الموقع وصفحات الطلب)</label><input name="value" type="text" defaultValue={s.response_time} /></div>
        </ActionForm>
        <ActionForm action={saveSettingAction}>
          <input type="hidden" name="key" value="contact" />
          <div className="field"><label>رقم واتساب (دولي بدون +)</label><input name="whatsapp" type="text" dir="ltr" defaultValue={s.contact.whatsapp} /></div>
          <div className="field"><label>رابط انستقرام</label><input name="instagram" type="url" dir="ltr" defaultValue={s.contact.instagram} /></div>
        </ActionForm>
      </section>

      <section className="card stack">
        <H id="bank">الحساب البنكي</H>
        <p className="alert warn small">راجعي الآيبان بعناية؛ يظهر للعملاء في صفحة الدفع. كل تعديل يُسجّل في سجل الإدارة.</p>
        <ActionForm action={saveSettingAction} confirm="تأكيد تعديل بيانات الحساب البنكي؟">
          <input type="hidden" name="key" value="bank" />
          <div className="field"><label>اسم الحساب</label><input name="accountName" type="text" defaultValue={s.bank.accountName} required /></div>
          <div className="field"><label>البنك</label><input name="bankName" type="text" defaultValue={s.bank.bankName} required /></div>
          <div className="field"><label>الآيبان</label><input name="iban" type="text" dir="ltr" defaultValue={s.bank.iban} required /></div>
        </ActionForm>
      </section>

      <section className="card stack">
        <H id="about">عن المدربة</H>
        <p className="small muted">كل سطر = فقرة أو عنصر. في «أسلوبي» و«ملاحظات»: افصلي بين الأجزاء بعلامة |. لجعل بداية فقرة عريضة: **النص العريض** ثم الباقي.</p>
        <ActionForm action={saveSettingAction}>
          <input type="hidden" name="key" value="about" />
          <div className="field"><label>الاسم</label><input name="name" type="text" defaultValue={s.about.name} /></div>
          <div className="field"><label>النبذة (أعلى صفحة عن المدربة)</label><textarea name="bio" defaultValue={s.about.bio} /></div>
          <div className="field"><label>النبذة في الصفحة الرئيسية</label><textarea name="home_bio" defaultValue={s.about.home_bio ?? ""} /></div>
          <div className="field"><label>قصتي — العنوان</label><input name="story_title" type="text" defaultValue={s.about.story_title ?? ""} /></div>
          <div className="field"><label>قصتي — الفقرات (سطر لكل فقرة)</label><textarea name="story" style={{ minHeight: 180 }} defaultValue={(s.about.story ?? []).join("\n")} /></div>
          <div className="field"><label>أسلوبي — العنوان</label><input name="pillars_title" type="text" defaultValue={s.about.pillars_title ?? ""} /></div>
          <div className="field"><label>أسلوبي — النقاط (العنوان | الشرح)</label><textarea name="pillars" style={{ minHeight: 160 }} defaultValue={(s.about.pillars ?? []).map((p) => `${p.title} | ${p.body}`).join("\n")} /></div>
          <div className="field"><label>لمن يناسب — العنوان</label><input name="fit_title" type="text" defaultValue={s.about.fit_title ?? ""} /></div>
          <div className="field"><label>لمن يناسب — الفقرات</label><textarea name="fit" defaultValue={(s.about.fit ?? []).join("\n")} /></div>
          <div className="field"><label>ملاحظات (العنوان | النص | الرابط اختياري | نص الرابط)</label><textarea name="notes" style={{ minHeight: 140 }} defaultValue={(s.about.notes ?? []).map((n) => [n.title, n.body, n.href ?? "", n.label ?? ""].join(" | ")).join("\n")} /></div>
          <div className="field"><label>الخبرة — العنوان</label><input name="experience_title" type="text" defaultValue={s.about.experience_title ?? ""} /></div>
          <div className="field"><label>الخبرة (سطر لكل نقطة)</label><textarea name="experience" defaultValue={(s.about.experience ?? []).join("\n")} /></div>
          <div className="field"><label>الشهادات (سطر لكل شهادة)</label><textarea name="certs" defaultValue={s.about.certs.join("\n")} /></div>
          <input type="hidden" name="points" value={(s.about.points ?? []).join("\n")} />
        </ActionForm>
      </section>

      <section className="card stack">
        <H id="checkins">المراجعة الأسبوعية</H>
        <ActionForm action={saveSettingAction}>
          <input type="hidden" name="key" value="checkins" />
          <label className="check"><input type="checkbox" name="enabled" defaultChecked={s.checkins?.enabled} /><span>تفعيل إرسال المراجعة الأسبوعية من الموقع (لباقات المتابعة النشطة)</span></label>
          <div className="field"><label>الأسئلة (سطر لكل سؤال بصيغة: الموضوع | السؤال)</label>
            <textarea name="questions" style={{ minHeight: 220 }} defaultValue={(s.checkins?.questions ?? []).map((q) => `${q.topic} | ${q.q}`).join("\n")} />
          </div>
        </ActionForm>
      </section>

      <section className="card stack">
        <H id="reminders">التنبيهات والتذكيرات</H>
        <p className="small muted">
          تُرسل بالبريد، وبواتساب بعد تفعيل WhatsApp Business API فقط. تعمل تلقائياً كل ساعة بين 9 صباحاً و9 مساءً (بتوقيت الرياض) إذا كان CRON_SECRET مضبوطاً.
          لا تكتبي بيانات صحية في النصوص؛ يُضاف رابط الحساب تلقائياً.
          المتغيرات المتاحة: <bdi dir="ltr">{"{name}"}</bdi> الاسم الأول، <bdi dir="ltr">{"{product}"}</bdi> الباقة، <bdi dir="ltr">{"{end_date}"}</bdi> تاريخ الانتهاء،
          <bdi dir="ltr">{" {window_start} {window_end}"}</bdi> بداية ونهاية نافذة المراجعة.
        </p>
        <ActionForm action={saveSettingAction} submit="حفظ إعدادات التذكير">
          <input type="hidden" name="key" value="reminders" />
          <div className="grid g2">
            <div className="field"><label htmlFor="rem-days">تذكير قبل انتهاء الاشتراك بـ (أيام، مفصولة بفاصلة)</label><input id="rem-days" name="sub_expiry_days" type="text" dir="ltr" defaultValue={rem.sub_expiry_days.join(", ")} /></div>
            <div className="field"><label htmlFor="rem-lead">تذكير المراجعة الأسبوعية قبل موعدها بـ (أيام، 0–6)</label><input id="rem-lead" name="review_lead_days" type="number" min={0} max={6} defaultValue={rem.review_lead_days} /></div>
            <div className="field"><label htmlFor="rem-window">مدة نافذة تسليم المراجعة بعد موعدها (أيام، 0–6)</label><input id="rem-window" name="review_window_days" type="number" min={0} max={6} defaultValue={rem.review_window_days} /></div>
            <div className="field"><label htmlFor="rem-cool">أقل مدة بين إرسالين يدويين لنفس المتدرب (دقائق)</label><input id="rem-cool" name="manual_cooldown_minutes" type="number" min={1} max={1440} defaultValue={rem.manual_cooldown_minutes} /></div>
          </div>
          <div className="field"><label htmlFor="rem-sub">نص تذكير انتهاء الاشتراك</label><textarea id="rem-sub" name="sub_expiry_text" maxLength={400} defaultValue={rem.sub_expiry_text} /></div>
          <div className="field"><label htmlFor="rem-review">نص تذكير المراجعة الأسبوعية</label><textarea id="rem-review" name="review_text" maxLength={400} defaultValue={rem.review_text} /></div>
          <div className="field"><label htmlFor="rem-missed">نص التذكير اللطيف عند فوات المراجعة</label><textarea id="rem-missed" name="missed_review_text" maxLength={400} defaultValue={rem.missed_review_text} /></div>
        </ActionForm>
      </section>

      <section className="card stack">
        <H id="faq">الأسئلة الشائعة</H>
        <p className="small muted">الأسطر التي تبدأ بـ «- » تظهر كقائمة.</p>
        {faqs.map((f) => (
          <details key={f.id} className="card flat">
            <summary style={{ cursor: "pointer", minHeight: 44 }}>{f.question} {!f.published && <span className="tag soft">مخفي</span>}</summary>
            <ActionForm action={saveFaqAction}>
              <input type="hidden" name="id" value={f.id} />
              <div className="field"><label>السؤال</label><input name="question" type="text" defaultValue={f.question} /></div>
              <div className="field"><label>الجواب</label><textarea name="answer" defaultValue={f.answer} style={{ minHeight: 160 }} /></div>
              <div className="row"><div className="field"><label>الترتيب</label><input name="sort" type="number" defaultValue={f.sort} style={{ maxWidth: 120 }} /></div>
                <label className="check"><input type="checkbox" name="published" defaultChecked={f.published} /><span>ظاهر</span></label></div>
            </ActionForm>
            <ActionForm action={saveFaqAction} submit="حذف السؤال" submitClass="btn btn-danger btn-sm" confirm="حذف هذا السؤال؟">
              <input type="hidden" name="id" value={f.id} /><input type="hidden" name="delete" value="1" />
            </ActionForm>
          </details>
        ))}
        <details className="card flat">
          <summary style={{ cursor: "pointer", minHeight: 44 }}>+ إضافة سؤال</summary>
          <ActionForm action={saveFaqAction} submit="إضافة">
            <div className="field"><label>السؤال</label><input name="question" type="text" /></div>
            <div className="field"><label>الجواب</label><textarea name="answer" /></div>
            <input type="hidden" name="sort" value={faqs.length} /><input type="hidden" name="published" value="on" />
          </ActionForm>
        </details>
      </section>

      <section className="card stack">
        <H id="policies">السياسات</H>
        {policies.map((p) => (
          <details key={p.slug} className="card flat">
            <summary style={{ cursor: "pointer", minHeight: 44 }}>{p.title}</summary>
            <ActionForm action={savePolicyAction}>
              <input type="hidden" name="slug" value={p.slug} />
              <div className="field"><label>العنوان</label><input name="title" type="text" defaultValue={p.title} /></div>
              <div className="field"><label>النص (سطر لكل بند يبدأ بـ «- »)</label><textarea name="body" defaultValue={p.body} style={{ minHeight: 220 }} /></div>
            </ActionForm>
          </details>
        ))}
      </section>
    </div>
  );
}
