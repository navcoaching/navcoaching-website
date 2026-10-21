# النسخ الاحتياطي والاستعادة

| المتطلب | التطبيق |
|---|---|
| نسخة يومية للقاعدة والملفات | `.github/workflows/backup.yml` كل يوم 03:17 بتوقيت الرياض: `pg_dump` كامل + كل ملفات Netlify Blobs (إيصالات، ملفات البرامج، الصور، الفيديو) |
| موقع منفصل عن التشغيل | GitHub (مزوّد ثالث، غير Netlify وNeon) |
| مدة الحفظ | 30 يوماً (`retention-days: 30`)، تُحذف بعدها تلقائياً |
| التشفير | AES-256 بمفتاح مشتق PBKDF2 (200 ألف دورة) من `BACKUP_PASSPHRASE`. الملف بدون الكلمة غير مقروء |
| RPO ≤ 24 ساعة | نسخة كل 24 ساعة. ونسخ Neon الداخلي (استعادة لأي لحظة خلال مدة خطتك) طبقة ثانية لفقد أقل |
| التنبيه عند الفشل | GitHub يرسل بريداً لصاحب المستودع عند فشل أي تشغيل |

## الإعداد (مرة واحدة)
GitHub ← المستودع ← **Settings ← Secrets and variables ← Actions ← New repository secret**:

| الاسم | القيمة |
|---|---|
| `BACKUP_DATABASE_URL` | رابط **المالك** من Neon: Connect ← الفرع production ← قاعدة `neondb` ← الدور **`neondb_owner`** ← أطفئي Connection pooling (رابط مباشر بدون `-pooler`، ومعه `sslmode=require`). رابط `nav_app` لا يصلح لأنه محكوم بـ RLS ولن ينسخ كل البيانات |
| `BACKUP_PASSPHRASE` | `openssl rand -base64 32`. **احفظيها خارج GitHub** (مدير كلمات مرور). ضياعها = النسخ لا تُفتح |
| `NETLIFY_AUTH_TOKEN` | Netlify ← User settings ← Applications ← **Personal access tokens** ← New (مدة انتهاء سنة، وجدّديه قبلها) |

ثم: **Actions ← Daily backup ← Run workflow** للتجربة الأولى، وتأكدي أنه أخضر وأن فيه ملفاً في Artifacts.

> المخاطرة: رابط المالك ومفتاح Netlify يعطيان صلاحيات واسعة، فهما في GitHub Secrets فقط (لا يظهران في السجلات). أي شخص له صلاحية كتابة على المستودع يقدر يعدّل الـ workflow ويستخدمهما، فخلّي صلاحية الكتابة لك فقط.
> حجم التخزين: كل يوم نسخة كاملة × 30 يوماً. إذا كبرت الملفات (فيديو) راقبي حصة GitHub (Settings ← Billing ← Storage).

## الاستعادة
1. Actions ← آخر تشغيل ناجح ← Artifacts ← تحميل وفك الـ zip ← ملف `nav-backup-….tar.gz.enc`.
2. أنشئي قاعدة **فارغة** (في Neon: Branches ← New branch فارغ، أو قاعدة جديدة)، والدوران `neondb_owner` و`nav_app` موجودان فيها.
3. من جهازك:
   ```
   RESTORE_DATABASE_URL='postgres://neondb_owner:…@…/nav_restore?sslmode=require' DATABASE_SSL=true \
   BACKUP_PASSPHRASE='…' node scripts/restore.mjs nav-backup-….tar.gz.enc restored-files
   ```
   السكربت يرفض أي قاعدة فيها جداول (فما يمسح الإنتاج بالخطأ)، ويتحقق أن عدد صفوف كل جدول وبصمة كل ملف تطابق وقت النسخ.
4. الملفات في `restored-files/` بنفس مفاتيحها. لإرجاعها لـ Netlify Blobs ترفع بنفس المفتاح في متجر `private-files`.
5. وجّهي `DATABASE_URL` في Netlify (بدور `nav_app`) للقاعدة المستعادة، وأعيدي النشر.

## اختبار الاستعادة (قبل الإطلاق، ثم كل 3 أشهر)
**Actions ← Restore test ← Run workflow**: يفك آخر نسخة ناجحة بـ `BACKUP_PASSPHRASE` ويستعيدها في قاعدة PostgreSQL 18 مؤقتة داخل التشغيل (لا يلمس Neon)، ويتحقق من عدد صفوف كل جدول وبصمة كل ملف. سجّلي النتيجة هنا.

| التاريخ | النسخة | النتيجة | المدة | من |
|---|---|---|---|---|
| 2026-10-19 | محلية (قاعدة تطوير + ملفات تجريبية) | ✓ 64 جدول، 1759 صف، ملفان، مطابقة كاملة؛ RLS 64/64 بعد الاستعادة؛ كلمة سر خاطئة/ملف تالف/قاعدة غير فارغة ← رُفضت | 0.6 ثانية | Claude (قبل الإعداد على الإنتاج) |
| — | أول نسخة من الإنتاج | **مطلوب قبل الإطلاق** | | |
