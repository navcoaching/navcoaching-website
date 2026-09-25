import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import { getSettings } from "@/lib/data";
import { youtubeId } from "@/lib/youtube";
import ActionForm from "@/components/admin/ActionForm";
import { saveFaqAction, savePolicyAction, saveSettingAction } from "@/app/actions/admin";

export default async function AdminContent() {
  const coach = await requireCoach();
  const [s, { faqs, policies, heroMedia }] = await Promise.all([
    getSettings(),
    withUser(coach.id, async (tx) => ({
      faqs: (await tx.query("SELECT * FROM faqs ORDER BY sort")).rows,
      policies: (await tx.query("SELECT * FROM policies ORDER BY sort")).rows,
      heroMedia: (await tx.query("SELECT id, alt FROM media_assets WHERE approved AND usage = 'hero' ORDER BY created_at DESC")).rows as { id: string; alt: string }[],
    })),
  ]);
  const vid = youtubeId(s.intro_video?.url);
  const H = ({ children, id }: { children: React.ReactNode; id: string }) => <h2 id={id} style={{ fontSize: 20 }}>{children}</h2>;

  return (
    <div className="stack" style={{ ["--space" as string]: "22px" }}>
      <h1>المحتوى والإعدادات</h1>
      <nav className="pill-nav">
        {[["video", "مقطع التعريف"], ["hero", "الواجهة"], ["contact", "التواصل ومدة الرد"], ["bank", "الحساب البنكي"], ["about", "عن المدربة"], ["checkins", "المراجعة الأسبوعية"], ["faq", "الأسئلة الشائعة"], ["policies", "السياسات"]].map(([id, l]) => <a key={id} href={`#${id}`}>{l}</a>)}
      </nav>

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
        <ActionForm action={saveSettingAction}>
          <input type="hidden" name="key" value="about" />
          <div className="field"><label>الاسم</label><input name="name" type="text" defaultValue={s.about.name} /></div>
          <div className="field"><label>النبذة</label><textarea name="bio" defaultValue={s.about.bio} /></div>
          <div className="field"><label>النقاط (سطر لكل نقطة)</label><textarea name="points" defaultValue={s.about.points.join("\n")} /></div>
          <div className="field"><label>الشهادات (سطر لكل شهادة)</label><textarea name="certs" defaultValue={s.about.certs.join("\n")} /></div>
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
