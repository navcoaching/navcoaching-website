# مراجع تصميم «عصري ومو vibe coded»

**متى تقرأه:** إذا طلبت المدربة تصميماً عصرياً/مميزاً، أو قالت «مو vibe coded». اقرأ معه `DESIGN.md`.
المصدر: قائمة @himanshubuildss (40 مرجعاً، 2026). ملاحظة: البند الأول (scrolltide) معروض كإعلان في التغريدة — قيّمه كأي مرجع، لا كأفضلها.

## طريقة العمل (إلزامية)
1. حدّد نوع القسم المطلوب (هيرو، أسعار، فوتر، نموذج، قائمة…) واختر من المعرض المتخصص له أدناه 2–3 أمثلة حقيقية.
   افتحها بـ `curl -sL -A 'Mozilla/5.0'` (WebFetch محجوب عن بعضها). land-book وuiverse وawwwards ترفض الطلب من البيئة؛ اطلب لقطة من المدربة إن لزم.
2. استخرج **المبدأ** لا الكود: الإيقاع والمسافات، هرمية الخطوط، كيف يُستخدم اللون، الحركة الدقيقة.
3. اعرض 2–3 خيارات كنماذج HTML بصور (جوال + كمبيوتر، فاتح + داكن) مطبّقاً عليها هوية `DESIGN.md`، ثم نفّذ المختار.

## علامات التصميم «الـ vibe coded» (تجنّبها)
- تدرجات بنفسجي/وردي عشوائية، توهج نيون في كل مكان، glassmorphism بلا سبب.
- كل البطاقات بنفس الحجم والظل وأيقونة إيموجي في الزاوية؛ شبكة 3 أعمدة متطابقة في كل قسم.
- عناوين عامة («Unlock your potential»)، أرقام إحصاءات مختلقة، شعارات عملاء وهمية.
- أكثر من خطين، أوزان كثيرة، زوايا دائرية مختلفة بلا نظام، حركة على كل عنصر.
- البديل: نظام tokens واحد، تفاوت مقصود في أحجام البطاقات (bento)، محتوى حقيقي، لمسة هوية واحدة متكررة (عندنا: الميل 37°)، مساحات بيضاء سخية.

## خادم designmd (MCP)
مضاف في `.mcp.json` (يقرأ المفتاح من متغير البيئة `DESIGNMD_API_KEY` — لا يُكتب المفتاح في الملفات).
يبحث في مكتبة designmd.ai وينزّل أنظمة DESIGN.md. استخدمه للاستلهام فقط: هويتنا في `DESIGN.md` هي المرجع.

## المراجع حسب الحاجة
**أنظمة تصميم وprompts**
- designmd.ai — مكتبة ملفات DESIGN.md (صيغة Google) جاهزة؛ تصلح لاستلهام بنية tokens. (يعمل من البيئة)
- vibeprompts.dev — prompts للوحات وصفحات الهبوط. (يعمل)
- scrolltide.co — prompts كاملة لمواقع حائزة جوائز + كود. (معروض كإعلان)
- styles.refero.design — 2000+ نمط منتج حقيقي مع الخطوط. (يعمل) ← الأفضل لاختيار ثنائية خطوط/ألوان.

**معارض إلهام عامة**: minimal.gallery (يعمل)، godly.website، awwwards.com (محجوب)، land-book.com (محجوب)، hoverstat.es (تجريبي)، landing.love (حركة).

**معارض متخصصة لكل قسم**
- هيرو: supahero.io (يعمل) · أسعار: pricingpages.design (يعمل) ← لصفحة البرامج
- قوائم: navbar.gallery · فوتر: footer.design · أزرار/نماذج/نوافذ: cta.gallery
- عنصر واحد عبر أنظمة كبرى: component.gallery (يعمل) · جوال: mobbin.com

**مكونات وحركة** (React/Tailwind غالباً — ننقل الفكرة إلى CSS، لا نضيف المكتبة)
- ui.shadcn.com، shadcnblocks.com، 21st.dev (فيه MCP)، ui.aceternity.com، magicui.design، motion-primitives.com، smoothui.dev، uiverse.io
- حركة: kinetics.colorion.co (150+ تأثير مع prompts)، microkit.co (تفاعلات دقيقة)، animejs.com (مكتبة خفيفة إن احتجنا JS)
- زجاج/انكسار: glass.samasante.com — نادراً ما يناسب هويتنا.

**3D وshaders** (ثقيلة على الجوال — فقط بطلب صريح): threejs.org، shadertoy.com، thebookofshaders.com، threejs-journey.com
**رسومات وأيقونات**: kitbitz.art (رسومات يدوية)، 3dicons.co — تحقق من الرخصة قبل الاستخدام.
**أدوات**: Claude Code، Cursor، v0.dev، lovable.dev.
