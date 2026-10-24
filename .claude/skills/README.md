# مهارات التصميم المثبّتة للمشروع

مهارات Claude Code من GitHub، منسوخة كما هي بدون تعديل، وتشتغل تلقائياً في كل جلسة على هذا المستودع.
ما تدخل في بناء الموقع ولا تُنشر معه.

| المجلد | المصدر | النسخة | الترخيص |
|---|---|---|---|
| `impeccable/` | [pbakaus/impeccable](https://github.com/pbakaus/impeccable) | 4.6.0 · `9304afa` | Apache-2.0 |
| `design-taste-frontend/` (Taste) | [Leonxlnx/taste-skill](https://github.com/Leonxlnx/taste-skill) `skills/taste-skill` | v2 · `f624f37` | MIT |
| `animate/` `improve-animations/` `review-animations/` `animation-performance/` `find-animation-opportunities/` `animation-vocabulary/` (Motion) | [emilkowalski/skill](https://github.com/emilkowalski/skill) | `2d22863` | MIT |
| `ponytail/` `ponytail-review/` `ponytail-audit/` `ponytail-debt/` `ponytail-gain/` `ponytail-help/` (Ponytail) | [DietrichGebert/ponytail](https://github.com/DietrichGebert/ponytail) `skills/` | `09c434a` | MIT |
| `.agents/skills/*` (95 مهارة، روابط رمزية هنا) | [trailofbits/skills](https://github.com/trailofbits/skills) | `196a907` | CC-BY-SA-4.0 |

ملاحظات:
- Impeccable يحمّل محركه (ملف تنفيذي) من إصدارات GitHub أول مرة يُستخدم، ويحفظه في `~/.impeccable/` خارج المستودع. الـ hooks حقته ما ثُبّتت.
- Taste يكتب ملفات عمله في `.taste-skill/` (مستثنى في `.gitignore`)، وسكربت الصور فيه يبحث في أرشيفات مفتوحة (ويكيميديا، أرشيف الإنترنت، المتاحف) بدون مفاتيح.
- Ponytail: نُسخت المهارات فقط بدون hooks الإضافة (تحتاج تثبيت كـ plugin وتكتب في `~/.claude`). التفعيل الدائم صار عن طريق سطر في `CLAUDE.md`.
- Trail of Bits: ثُبّتت بأمر `npx skills add trailofbits/skills` (الملفات في `.agents/skills/` والـ lock في `skills-lock.json`). للتحديث: `npx skills update`.
- للتحديث: يُعاد نسخ المجلد من المصدر، ويُحدَّث رقم النسخة هنا.
