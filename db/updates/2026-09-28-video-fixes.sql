-- استبدال 3 مقاطع يوتيوب محذوفة/ممنوعة من التشغيل في مكتبة التمارين (فُحصت 160 مقطعاً: 157 تشتغل).
-- يُحدَّث التمرين فقط إذا كان رابطه ما زال القديم (ما يغيّر أي رابط عدّلتيه). آمن لو انشغّل مرتين.
BEGIN;
UPDATE exercises SET video_url = 'https://youtu.be/0cB0_SzqgBU'   -- How To: Smith Machine Stiff-Legged Deadlift
 WHERE name = 'SM SLDL' AND video_url = 'https://youtube.com/shorts/qlL1wnpLQj4?si=-jD_X6mIJkkI8SwX';
UPDATE exercises SET video_url = 'https://youtu.be/rDRwAURNbzU'   -- How To Do A STANDING LEG CURL
 WHERE name = 'Standing Leg Curl' AND video_url = 'https://youtu.be/fyF6FQOUGDI';
UPDATE exercises SET video_url = 'https://youtu.be/bxn9FBrt4-A'   -- How to do a Dead Bug | NASM
 WHERE name = 'Dead Bug' AND video_url = 'https://youtube.com/shorts/_zkkMOtXuOQ?si=GIkLuCUJvdaOk5FP';
SELECT name, video_url FROM exercises WHERE name IN ('SM SLDL', 'Standing Leg Curl', 'Dead Bug') ORDER BY name;
COMMIT;
