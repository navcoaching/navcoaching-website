import type { Lang } from "@/lib/lang";

/** نصوص صفحة الحاسبة ومكوّنيها باللغتين */
const ar = {
  metaTitle: "حاسبة السعرات اليومية وتوازن الطاقة",
  metaDesc: "السعرات اليومية حسب الهدف (تنشيف، محافظة، تضخيم) من الوزن وتركيبة الجسم والتمرين، وسعرات المحافظة الفعلية من التغيّر في الجسم بين قياسين.",
  eyebrow: "أداة مجانية", title: "حاسبة السعرات", lead: "السعرات اليومية حسب الهدف من الوزن وتركيبة الجسم والتمرين، أو معرفة سعرات المحافظة الفعلية من التغيّر الحقيقي في الجسم بين قياسين.", navAria: "الحاسبات",
  dailyTitle: "حاسبة السعرات اليومية", dailyLead: "نقطة بداية لسعراتك حسب هدفك، من وزنك وتركيبة جسمك ونشاطك وتمرينك.",
  ebTitle: "حاسبة توازن الطاقة", ebLead: "لمن عنده قياسين (مثل فحصي InBody) بينهما 4 أسابيع أو أكثر: تحسب عجزك أو فائضك الفعلي وسعرات المحافظة الحقيقية لجسمك.",
  disclaimer: "هذه الحاسبة توفر إرشادات عامة مناسبة لمعظم الأشخاص ولا تعوض عن الاستشارة الطبية. في حال وجود حالة صحية مثل السكري أو ارتفاع ضغط الدم، يجب استشارة مختص قبل إجراء تغييرات كبيرة في نظامك الغذائي أو التمريني.",
  faqTitle: "أسئلة شائعة",
  faq: [
    { q: "أي حاسبة أستخدم؟", a: "البداية من حاسبة السعرات اليومية: تعطي نقطة بداية من الوزن وتركيبة الجسم والتمرين. بعد 4 أسابيع أو أكثر، ومع وجود قياسين (مثل InBody) وأكل مسجّل، حاسبة توازن الطاقة هي الأنسب لمعرفة سعرات المحافظة الفعلية والتعديل عليها." },
    { q: "ليش نسبة الدهون تعطي نتيجة أدق؟", a: "العضلات والأعضاء هي اللي تصرف أغلب الطاقة وقت الراحة، والدهون تصرف قليل. لما نعرف الكتلة الخالية من الدهون نحسب الأيض الأساسي منها مباشرة، بدل تقديره من الوزن والطول والعمر." },
    { q: "وش الفرق بين هذي الحاسبة والحاسبات العادية؟", a: "الحاسبات العادية تقدّر سعراتك بمعادلات عامة (عمر، وزن، طول، نشاط) وقد تخطئ مئات السعرات. هذي الحاسبة تحسب توازن طاقتك الفعلي من التغيّر الحقيقي في جسمك وأكلك الفعلي، فتعطيك سعرات المحافظة الخاصة فيك." },
    { q: "من وين أجيب أرقام الكتلة الخالية من الدهون وكتلة الدهون؟", a: "من فحصين InBody (أو أي جهاز تحليل جسم) على نفس الجهاز وبنفس الظروف: الصبح، على الريق، وبعد دخول الحمام. المطلوب: الفرق في «كتلة الدهون» بالكيلو (مو النسبة)، والفرق في «الكتلة الخالية من الدهون» (الوزن − كتلة الدهون)." },
    { q: "كم لازم تكون المدة بين القياسين؟", a: "4 أسابيع أو أكثر. المدد القصيرة تتأثر كثيراً بالماء والأكل وأخطاء الجهاز، فتطلع النتيجة غير دقيقة." },
    { q: "كيف أحسب سعرات يوم التمرين ويوم الراحة؟", a: "من تطبيق تسجيل الأكل خلال نفس الفترة: متوسط السعرات في أيام التمرين، ومتوسطها في أيام الراحة. كل ما كان التسجيل أدق، كانت النتيجة أدق." },
  ],
  intake: {
    methods: [["أعرف نسبة الدهون", "الأدق: يعتمد على الكتلة الخالية من الدهون (معادلة Cunningham)."], ["ما أعرف نسبة الدهون", "يعتمد على الوزن والطول والعمر والجنس (معادلة Ten Haaf) — مناسبة للأشخاص الرياضيين."], ["بنية رياضية وعضلية عالية", "للاعبي كمال الأجسام ومن في بنيتهم فقط (معادلة Tinsley)."]],
    formAria: "حاسبة السعرات اليومية", method: "طريقة الحساب", weight: "الوزن", kg: "كغ", bodyFat: "نسبة الدهون", bodyFatHint: "من فحص InBody أو تقدير تقريبي من صور نسب الدهون المرجعية.", height: "الطول", cm: "سم", age: "العمر", years: "سنة", sex: "الجنس", male: "ذكر", female: "أنثى",
    paf: "نشاطك اليومي خارج التمرين", trainingDays: "أيام تمرين المقاومة في الأسبوع", noTraining: "لا أتمرن", oneDay: "يوم واحد", twoDays: "يومين", days: "أيام", minutes: "مدة جلسة التمرين", min: "دقيقة", goal: "هدفك", submit: "حساب السعرات",
    resultAria: "النتيجة", result: "النتيجة", target: "متوسط سعراتك اليومية لهدفك", kcalDaily: "سعرة حرارية يومياً", trainingDay: "يوم التمرين", restDay: "يوم الراحة", kcal: "سعرة", maintenance: "سعرات المحافظة", kcalPerDay: "سعرة يومياً", bmr: "معدل الأيض الأساسي",
    macros: "الماكروز اليومية (تقدير مبدئي)", proteinLevel: "مستوى البروتين", fatPerKg: "الدهون (غ لكل كغ)", avg: "المتوسط", protein: "بروتين", carbs: "كارب", fat: "دهون", g: "غ",
    macroHint: "البروتين والدهون ثابتة حسب وزنك، والكارب هو الباقي من السعرات (السعرات = بروتين×4 + كارب×4 + دهون×9). الأرقام مبدئية والتعديل عليها متاح، وخطتك مع المدربة تحدد المناسب لك.",
    how: "كيف حسبناها؟", ffm: "الكتلة الخالية من الدهون:", bmrLine: "معدل الأيض الأساسي", trainingEE: "مصروف التمرين: 0.1 × الوزن × مدة الجلسة =", restEE: "يوم الراحة = الأيض × عامل النشاط × 1.2 (التأثير الحراري للطعام) =", trainingEEday: "يوم التمرين = (الأيض × عامل النشاط + مصروف التمرين) × 1.2 =", maintLine: "المحافظة = متوسط الأسبوع؛ والهدف = المحافظة ×", macroLine: "الماكروز: بروتين = (1.6 للمعتدل أو 2.2 للعالي) غ/كغ × الوزن، ودهون = غ/كغ × الوزن، والكارب = (السعرات − بروتين×4 − دهون×9) ÷ 4.", source: "معادلات السعرات من حاسبة Menno Henselmans (Energy Intake Calculator).",
    startNote1: "نقطة بداية تقريبية: مراقبة الوزن والقياسات أسبوعين إلى ثلاثة، والتعديل حسب النتيجة. بعد فترة تُحسب السعرات الفعلية بدقة من", ebLink: "حاسبة توازن الطاقة", cta: "خطة تدريب وتغذية مبنية على أرقامك مع متابعة أسبوعية؟", programs: "البرامج",
  },
  eb: {
    formAria: "حاسبة توازن الطاقة", change: "التغيّر في جسمك", changeLead: "مقارنة قياسين (مثل فحصي InBody) بينهما 4 أسابيع أو أكثر، وكتابة الفرق.", lean: "الكتلة الخالية من الدهون", leanHint: "في InBody: Lean Body Mass أو «الكتلة الخالية من الدهون» (= الوزن − كتلة الدهون).", fatMass: "كتلة الدهون", fatHint: "في InBody: Body Fat Mass أو «كتلة الدهون» بالكيلو، وليس النسبة المئوية.", dirAria: "اتجاه", up: "زاد", down: "نقص", inKg: "بالكيلوغرام", kg: "كغ",
    startDate: "تاريخ القياس الأول", endDate: "تاريخ القياس الثاني", food: "أكلك خلال نفس الفترة", trainingKcal: "سعرات يوم التمرين", trainingDays: "أيام التمرين في الأسبوع", restDaysHint: "أيام الراحة = الباقي", day: "يوم", days: "أيام", oneDay: "يوم واحد", twoDays: "يومين", restKcal: "سعرات يوم الراحة", kcal: "سعرة", submit: "حساب توازن الطاقة",
    resultAria: "النتيجة", result: "النتيجة", daily: "توازن الطاقة اليومي", kcalDaily: "سعرة يومياً", deficit: "عجز", surplus: "فائض", balance: "توازن", maintenance: "سعرات المحافظة الفعلية", kcalDailyEst: "سعرة يومياً (تقديرية)", avgIntake: "متوسط أكلك اليومي", net: "صافي التوازن للفترة", period: "مدة الفترة", dayUnit: "يوم",
    how: "كيف حسبناها؟", leanLine: "طاقة الكتلة الخالية من الدهون: التغيّر × 7.6 ميغاجول/كغ =", fatLine: "طاقة الدهون: التغيّر × 39.5 ميغاجول/كغ =", mj: "ميغاجول", netLine: "صافي التوازن = المجموع × 238.85 سعرة/ميغاجول =", perDayLine: "يومياً", maintLine: "سعرات المحافظة الفعلية = متوسط أكلك", minusLine: "− التوازن اليومي", source: "المعادلة من حاسبة توازن الطاقة لـ Menno Henselmans.", cta: "خطة تدريب وتغذية مبنية على أرقامك مع متابعة أسبوعية؟", programs: "البرامج",
  },
};
export type CalcText = typeof ar;
const en: CalcText = {
  metaTitle: "Daily calorie and energy-balance calculator",
  metaDesc: "Daily calories for your goal (cut, maintain, bulk) from weight, body composition, and training, and your real maintenance calories from the change in your body between two measurements.",
  eyebrow: "Free tool", title: "Calorie calculator", lead: "Daily calories for your goal from weight, body composition, and training, or your real maintenance calories from the actual change in your body between two measurements.", navAria: "Calculators",
  dailyTitle: "Daily calorie calculator", dailyLead: "A starting point for your calories by goal, from your weight, body composition, activity, and training.",
  ebTitle: "Energy-balance calculator", ebLead: "If you have two measurements (such as two InBody scans) 4 weeks or more apart: it calculates your real deficit or surplus and your true maintenance calories.",
  disclaimer: "This calculator gives general guidance suitable for most people and does not replace medical advice. If you have a health condition such as diabetes or high blood pressure, consult a specialist before making major changes to your diet or training.",
  faqTitle: "FAQ",
  faq: [
    { q: "Which calculator should I use?", a: "Start with the daily calorie calculator: it gives a starting point from weight, body composition, and training. After 4 weeks or more, with two measurements (such as InBody) and logged food, the energy-balance calculator is best for finding your real maintenance calories and adjusting." },
    { q: "Why does body-fat percentage give a more accurate result?", a: "Muscle and organs burn most of the energy at rest, while fat burns little. Knowing your lean body mass lets us calculate basal metabolic rate from it directly instead of estimating from weight, height, and age." },
    { q: "How is this different from ordinary calculators?", a: "Ordinary calculators estimate your calories with general formulas (age, weight, height, activity) and can be off by hundreds of calories. This one calculates your actual energy balance from the real change in your body and what you actually ate, giving you your own maintenance calories." },
    { q: "Where do I get the lean-mass and fat-mass numbers?", a: "From two InBody scans (or any body-composition device) on the same device under the same conditions: morning, fasted, after using the bathroom. You need the difference in fat mass in kg (not the percentage) and the difference in lean body mass (weight minus fat mass)." },
    { q: "How long should the gap between measurements be?", a: "4 weeks or more. Short periods are strongly affected by water, food, and device error, so the result becomes inaccurate." },
    { q: "How do I calculate training-day and rest-day calories?", a: "From your food-logging app over the same period: the average calories on training days and the average on rest days. The more accurate the logging, the more accurate the result." },
  ],
  intake: {
    methods: [["I know my body-fat percentage", "Most accurate: based on lean body mass (Cunningham equation)."], ["I don’t know my body-fat percentage", "Based on weight, height, age, and sex (Ten Haaf equation), suited to athletic people."], ["Highly muscular, athletic build", "For bodybuilders and similar physiques only (Tinsley equation)."]],
    formAria: "Daily calorie calculator", method: "Calculation method", weight: "Weight", kg: "kg", bodyFat: "Body-fat percentage", bodyFatHint: "From an InBody scan or a rough estimate from reference body-fat photos.", height: "Height", cm: "cm", age: "Age", years: "years", sex: "Sex", male: "Male", female: "Female",
    paf: "Daily activity outside training", trainingDays: "Resistance-training days per week", noTraining: "I don’t train", oneDay: "1 day", twoDays: "2 days", days: "days", minutes: "Training session length", min: "min", goal: "Your goal", submit: "Calculate calories",
    resultAria: "Result", result: "Result", target: "Your average daily calories for your goal", kcalDaily: "kcal per day", trainingDay: "Training day", restDay: "Rest day", kcal: "kcal", maintenance: "Maintenance calories", kcalPerDay: "kcal per day", bmr: "Basal metabolic rate",
    macros: "Daily macros (initial estimate)", proteinLevel: "Protein level", fatPerKg: "Fat (g per kg)", avg: "Average", protein: "Protein", carbs: "Carbs", fat: "Fat", g: "g",
    macroHint: "Protein and fat are fixed by your weight, and carbs are the remaining calories (calories = protein×4 + carbs×4 + fat×9). The numbers are a starting point you can adjust; your plan with the coach sets what suits you.",
    how: "How did we calculate it?", ffm: "Lean body mass:", bmrLine: "Basal metabolic rate", trainingEE: "Training expenditure: 0.1 × weight × session length =", restEE: "Rest day = BMR × activity factor × 1.2 (thermic effect of food) =", trainingEEday: "Training day = (BMR × activity factor + training expenditure) × 1.2 =", maintLine: "Maintenance = weekly average; target = maintenance ×", macroLine: "Macros: protein = (1.6 moderate or 2.2 high) g/kg × weight, fat = g/kg × weight, carbs = (calories − protein×4 − fat×9) ÷ 4.", source: "Calorie equations from Menno Henselmans’ Energy Intake Calculator.",
    startNote1: "An approximate starting point: track weight and measurements for two to three weeks and adjust by the result. Later, calculate your actual calories precisely with the", ebLink: "energy-balance calculator", cta: "Want a training and nutrition plan built on your numbers with weekly follow-up?", programs: "Programs",
  },
  eb: {
    formAria: "Energy-balance calculator", change: "The change in your body", changeLead: "Compare two measurements (such as two InBody scans) 4 weeks or more apart and enter the difference.", lean: "Lean body mass", leanHint: "In InBody: Lean Body Mass (= weight − fat mass).", fatMass: "Fat mass", fatHint: "In InBody: Body Fat Mass in kg, not the percentage.", dirAria: "Direction of", up: "Increased", down: "Decreased", inKg: "in kilograms", kg: "kg",
    startDate: "Date of first measurement", endDate: "Date of second measurement", food: "Your food over the same period", trainingKcal: "Training-day calories", trainingDays: "Training days per week", restDaysHint: "Rest days = the remainder", day: "day", days: "days", oneDay: "1 day", twoDays: "2 days", restKcal: "Rest-day calories", kcal: "kcal", submit: "Calculate energy balance",
    resultAria: "Result", result: "Result", daily: "Daily energy balance", kcalDaily: "kcal per day", deficit: "deficit", surplus: "surplus", balance: "balance", maintenance: "Real maintenance calories", kcalDailyEst: "kcal per day (estimate)", avgIntake: "Your average daily intake", net: "Net balance for the period", period: "Length of period", dayUnit: "days",
    how: "How did we calculate it?", leanLine: "Lean-mass energy: change × 7.6 MJ/kg =", fatLine: "Fat energy: change × 39.5 MJ/kg =", mj: "MJ", netLine: "Net balance = total × 238.85 kcal/MJ =", perDayLine: "per day", maintLine: "Real maintenance calories = your average intake", minusLine: "− daily balance", source: "Equation from Menno Henselmans’ energy-balance calculator.", cta: "Want a training and nutrition plan built on your numbers with weekly follow-up?", programs: "Programs",
  },
};
export const CALC: Record<Lang, CalcText> = { ar, en };
