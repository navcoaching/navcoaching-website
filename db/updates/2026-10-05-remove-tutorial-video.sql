-- يحذف إعداد فيديو «كيف تستخدم الموقع» المحفوظ (الميزة أُزيلت من الموقع). آمن للتكرار.
BEGIN;
DELETE FROM site_settings WHERE key = 'tutorial_video';
COMMIT;
