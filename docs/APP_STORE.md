# ملف رفع التطبيق على App Store

كل ما يُعبّأ في App Store Connect، جاهز للنسخ. الحقول بالإنجليزي تبقى بالإنجليزي (أبل والمراجع يقرؤونها كذلك).

## 1. معلومات التطبيق

| الحقل | القيمة |
|---|---|
| الاسم (Name) | Nav Coaching |
| العنوان الفرعي بالعربي (Subtitle, 30 حرفاً) | متتبّع تمارين ومدربة شخصية |
| العنوان الفرعي بالإنجليزي | Workout tracker & 1:1 coaching |
| اللغة الأساسية | Arabic، مع إضافة English |
| التصنيف الأساسي | Health & Fitness |
| التصنيف الثانوي | Lifestyle |
| التقييم العمري | 4+ (لا محتوى من القائمة) |
| Bundle ID | com.navcoaching.app |
| SKU | navcoaching-ios-1 |
| Support URL | https://navcoaching.com |
| Marketing URL | https://navcoaching.com |
| Privacy Policy URL | https://navcoaching.com/policies#privacy |
| حقوق النشر (Copyright) | 2026 مؤسسة ناف كوتشنق |
| التشفير (Export Compliance) | لا (HTTPS فقط) — مضبوط مسبقاً في `app.json` |

## 2. نص المتجر بالعربي

**النص الترويجي (170 حرفاً):**
سجّل تمارينك وأوزانك مجاناً، وخلّ التطبيق يقترح عليك الوزن الجاي. ولما تبي نتيجة أسرع، الكوتش ساره تصمم برنامجك وتتابعك بنفسها.

**الوصف:**
```
Nav Coaching تطبيق تدريب سعودي يجمع بين متتبّع تمارين مجاني ومتابعة شخصية مع الكوتش ساره.

متتبّع مجاني بالكامل، بدون حساب وبدون إنترنت:
• صمّم برنامجك بأيامه وتمارينه، أو ابدأ ببرنامج جاهز من الكوتش
• سجّل الأوزان والتكرارات بسرعة، ومؤقت راحة يشتغل والجوال مقفل
• يقترح عليك الوزن الجاي حسب أدائك المرة السابقة
• أرقامك القياسية ورسوم تقدّمك لكل تمرين
• أكثر من 200 تمرين مصنّفة بالعضلة بالعربي، وأغلبها مع فيديو طريقة الأداء
• بدّل أي تمرين ببديل من نفس العضلة
• تذكير بأيام تمرينك
• حاسبة السعرات وتوازن الطاقة

ناف برو:
• بدائل الكوتش ساره لكل تمرين: البدائل اللي اختارتها بنفسها، وتتحدّث باستمرار
• «وجباتي»: وجبات تصممها الكوتش بمقاديرها وسعراتها وطريقة تحضيرها

التدريب الشخصي مع الكوتش ساره:
• برنامج تدريب وتغذية مصمم لك بعد استبيان عن هدفك ومستواك وصحتك
• متابعة أسبوعية وتعديلات على واتساب
• برنامجك وسجلك وتقدّمك داخل التطبيق
• مراجعة جدولك أو تصحيح أداء تمرين بالفيديو بأسعار رمزية

بياناتك: سجل المتتبّع المجاني يبقى على جوالك فقط. وحسابك تقدر تحذفه من التطبيق في أي وقت.
```

**الكلمات المفتاحية (100 حرف):**
`جيم,تمارين,متتبع,أوزان,برنامج تدريب,كوتش,مدربة,لياقة,تغذية,سعرات,رياضة,نادي,عضلات,تنشيف,قوة`

> لا تضيفي أسماء تطبيقات منافسة (مثل Hevy) في الكلمات المفتاحية: أبل ترفضها (البند 2.3.7).

## 3. نص المتجر بالإنجليزي

**Promotional text:**
Log your workouts for free and get your next weight suggested. When you want faster results, Coach Sarah designs your program and follows up with you personally.

**Description:**
```
Nav Coaching combines a free workout tracker with personal coaching from Coach Sarah.

Free tracker — no account, works offline:
• Build your own program or start from a ready-made coach program
• Fast set logging and a rest timer that works with the phone locked
• Next-weight suggestions based on your last session
• Personal records and progress charts per exercise
• 200+ exercises grouped by muscle, most with form videos
• Swap any exercise for one that trains the same muscle
• Workout reminders, calorie and energy-balance calculator

Nav Pro:
• Coach Sarah's own alternatives for every exercise, continuously updated
• My Meals: coach-designed meals with portions, calories and preparation

Personal coaching with Coach Sarah:
• A training and nutrition plan designed for you after an intake questionnaire
• Weekly check-ins and adjustments on WhatsApp
• Your plan, logs and progress inside the app
• Low-cost program reviews and video form checks

Your data: the free tracker's history stays on your phone. You can delete your account from inside the app at any time.
```

**Keywords:**
`gym,workout,tracker,log,lifting,program,coach,fitness,nutrition,calories,strength,training,arabic`

## 4. ملاحظات المراجعة (App Review Information)

**Sign-in required:** نعم.
- **User name:** قيمة `APP_REVIEW_EMAIL` في Netlify
- **Password:** قيمة `APP_REVIEW_CODE` في Netlify (المراجع يكتبه في خانة الرمز)

**Notes** (انسخيها كما هي بعد تعبئة القيمتين):
```
The app interface is in Arabic (right-to-left).

Sign-in: the app uses email one-time codes (no passwords). For review, open the tab
"حسابي" (Account), tap "الدخول" (Sign in), enter the demo email above, tap "أرسل رمز الدخول" (Send code), then
enter the 6-digit code above and tap "دخول" (Sign in). No email is sent for this demo
account. The free workout tracker (tabs "تمريني" My workout and "السجل" History) works
without signing in.

The demo account has an active coaching subscription so you can see the coaching area
(My program, nutrition, progress, orders) and Nav Pro (coach exercise alternatives and
My Meals).

Payments:
- Personal coaching packages are one-to-one services delivered by a single named coach
  (Coach Sarah, licensed business, CR 7050950752): she designs each client's plan after an
  intake questionnaire and follows up with the client personally every week over WhatsApp.
  These are person-to-person services under guideline 3.1.3(d), consumed largely outside
  the app (3.1.3(e)), and are paid by bank transfer to the business; the app shows the
  order and transfer details and lets the client upload the receipt.
- "Program review" and "Exercise form check" are also delivered personally by the coach
  over WhatsApp (3.1.3(e)).
- Nav Pro (coach exercise alternatives + My Meals) is digital content and is sold only as
  an auto-renewable In-App Purchase subscription.

Account deletion: "حسابي" (Account) tab → "حذف الحساب" (Delete account) (guideline 5.1.1(v)).
```

**بيانات التواصل:** اسمك، جوالك، وبريد تتابعينه.

## 5. الخصوصية (App Privacy)

| السؤال | الإجابة |
|---|---|
| هل تجمعين بيانات؟ | نعم |
| التتبع (Tracking) | لا. التطبيق بلا إعلانات ولا تحليلات ولا مشاركة مع وسطاء بيانات |

البيانات المجمّعة: كلها **مرتبطة بهوية المستخدم (Linked to the user)** و**غير مستخدمة للتتبع (Not used for tracking)**.

| النوع في أبل | ماذا عندنا | الغرض |
|---|---|---|
| Contact Info → Name | الاسم | App Functionality |
| Contact Info → Email Address | البريد (الدخول) | App Functionality |
| Contact Info → Phone Number | واتساب في الطلب | App Functionality |
| Health & Fitness → Health | الإصابات والحالة الصحية والقياسات في الاستبيان | App Functionality |
| Health & Fitness → Fitness | سجل التمارين ضمن برنامج المدربة، الوزن، الخطوات | App Functionality |
| User Content → Photos or Videos | صورة إيصال التحويل، فيديو تصحيح الأداء | App Functionality |
| User Content → Other User Content | إجابات الاستبيان والمراجعات الأسبوعية والتقييمات | App Functionality |
| Purchases → Purchase History | الطلبات والاشتراكات | App Functionality |
| Identifiers → User ID | معرّف الحساب | App Functionality |

لا يُجمع: الموقع، جهات الاتصال، بيانات التصفح، التشخيص، بيانات الاستخدام. سجل المتتبّع المجاني يبقى على الجهاز ولا يُرسل.

## 6. إضافة لسياسة الخصوصية (من لوحة الإدارة ← السياسات ← سياسة الخصوصية)

```
- تطبيق الجوال: سجل التمارين في المتتبّع المجاني يُحفظ على جوالك فقط ولا يُرسل لنا. إذا سجّلت دخولك، تصلنا فقط بيانات حسابك وطلباتك وما تسجله ضمن برنامجك مع المدربة.
- فيديو «تصحيح أداء تمرين» وصور الإيصالات تُحفظ في تخزين خاص لا يفتحه إلا أنت والمدربة، وتُحذف مع حذف الطلب أو الحساب.
- الاشتراك في «ناف برو» يتم عبر Apple، ولا نستلم أي بيانات دفع منه.
- تقدر تحذف حسابك وكل بياناته من داخل التطبيق: حسابي ← حذف الحساب.
- لا يستخدم التطبيق أي تحليلات أو إعلانات أو تتبع.
```

## 7. ما يجهّز قبل الإرسال

1. **حساب المراجعة:**
   - في Netlify، ثم Site configuration، ثم Environment variables: أضيفي `APP_REVIEW_EMAIL` (مثل `review@navcoaching.com`) و`APP_REVIEW_CODE` (6 أرقام عشوائية)، ثم أعيدي النشر.
   - ادخلي بهذا البريد مرة واحدة من الموقع.
   - من لوحة الإدارة ← الأعضاء: أضيفي له باقة متابعة يدوياً، وبرنامجاً فيه أسبوع واحد على الأقل.
2. **محتوى التطبيق:**
   - قالب واحد على الأقل منشور مجاناً في التطبيق.
   - منتجا «راجعي جدولي» و«تصحيح الأداء» مربوطان بحقل «خدمة إضافية في التطبيق».
   - إضافة سياسة الخصوصية أعلاه.
3. **صور الشاشة:** 6.9 إنش (1320×2868)، من 3 إلى 10 صور. تُلتقط من نسخة TestFlight على الجوال. المقترح بالترتيب:
   1. تسجيل التمرين.
   2. اقتراح الوزن الجاي.
   3. الأرقام القياسية والرسم.
   4. البرامج الجاهزة.
   5. بدائل الكوتش.
   6. برنامجي مع الكوتش.
4. **«ناف برو» في App Store Connect:**
   - مجموعة اشتراك «Nav Pro» فيها اشتراك شهري وسنوي.
   - لكل اشتراك اسم ووصف عربي وصورة مراجعة.
   - يُربط في التطبيق بعد توفر الحساب.
