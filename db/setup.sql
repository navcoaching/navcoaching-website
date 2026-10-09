-- =====================================================================
-- Nav Coaching — ملف الإعداد الكامل (يُنفَّذ مرة واحدة فقط على قاعدة فارغة)
-- مولَّد تلقائياً بـ scripts/build-setup-sql.mjs — لا تعدّليه يدوياً.
-- =====================================================================
BEGIN;
CREATE TABLE schema_migrations (name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now());

-- ---------- 001_schema.sql ----------
-- =====================================================================
-- Nav Coaching — المخطط الأساسي
-- تُشغَّل بحساب مالك قاعدة البيانات (DATABASE_URL_OWNER).
-- التطبيق يتصل بدور nav_app (ليس مالكاً ولا يتجاوز RLS).
-- =====================================================================

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nav_app') THEN
    CREATE ROLE nav_app NOLOGIN NOBYPASSRLS; -- فعّليه لاحقاً: ALTER ROLE nav_app LOGIN PASSWORD '...';
  END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS app;

-- ---------- جداول الدخول (Better Auth) ----------
CREATE TABLE "user" (
  "id" text PRIMARY KEY,
  "name" text NOT NULL,
  "email" text NOT NULL UNIQUE,
  "emailVerified" boolean NOT NULL,
  "image" text,
  "createdAt" timestamptz NOT NULL DEFAULT now(),
  "updatedAt" timestamptz NOT NULL DEFAULT now(),
  "role" text DEFAULT 'client' CHECK ("role" IN ('client', 'coach')),
  "phone" text
);
CREATE TABLE "session" (
  "id" text PRIMARY KEY,
  "expiresAt" timestamptz NOT NULL,
  "token" text NOT NULL UNIQUE,
  "createdAt" timestamptz NOT NULL DEFAULT now(),
  "updatedAt" timestamptz NOT NULL,
  "ipAddress" text,
  "userAgent" text,
  "userId" text NOT NULL REFERENCES "user" ("id") ON DELETE CASCADE
);
CREATE TABLE "account" (
  "id" text PRIMARY KEY,
  "accountId" text NOT NULL,
  "providerId" text NOT NULL,
  "userId" text NOT NULL REFERENCES "user" ("id") ON DELETE CASCADE,
  "accessToken" text, "refreshToken" text, "idToken" text,
  "accessTokenExpiresAt" timestamptz, "refreshTokenExpiresAt" timestamptz,
  "scope" text, "password" text,
  "createdAt" timestamptz NOT NULL DEFAULT now(),
  "updatedAt" timestamptz NOT NULL
);
CREATE TABLE "verification" (
  "id" text PRIMARY KEY,
  "identifier" text NOT NULL,
  "value" text NOT NULL,
  "expiresAt" timestamptz NOT NULL,
  "createdAt" timestamptz NOT NULL DEFAULT now(),
  "updatedAt" timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE "rateLimit" (
  "id" text PRIMARY KEY,
  "key" text NOT NULL UNIQUE,
  "count" integer NOT NULL,
  "lastRequest" bigint NOT NULL
);
CREATE INDEX "session_userId_idx" ON "session" ("userId");
CREATE INDEX "account_userId_idx" ON "account" ("userId");
CREATE INDEX "verification_identifier_idx" ON "verification" ("identifier");

-- ---------- المحتوى والمنتجات ----------
CREATE TABLE products (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug text NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9-]{2,60}$'),
  category text NOT NULL CHECK (category IN ('follow', 'files', 'consult')),
  name text NOT NULL,
  audience text NOT NULL DEFAULT '',          -- لمن يناسب
  items jsonb NOT NULL DEFAULT '[]'::jsonb,   -- [{ "text": "...", "included": true }]
  note text,
  delivery text,                              -- طريقة التسليم أو المتابعة
  requirements text,                          -- المطلوب من العميل قبل البدء
  policy_note text,                           -- سياسة الدفع/الاسترجاع الخاصة بالمنتج
  recommended boolean NOT NULL DEFAULT false,
  image_id uuid,
  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'published', 'archived')),
  sort int NOT NULL DEFAULT 0,
  is_demo boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE product_offers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL REFERENCES products (id) ON DELETE CASCADE,
  sku text NOT NULL UNIQUE CHECK (sku ~ '^[A-Za-z0-9_-]{1,40}$'),
  label text NOT NULL,
  months int NOT NULL DEFAULT 0 CHECK (months >= 0),
  price_halalas int NOT NULL CHECK (price_halalas >= 0),
  currency text NOT NULL DEFAULT 'SAR',
  active boolean NOT NULL DEFAULT true,
  sort int NOT NULL DEFAULT 0
);
CREATE INDEX ON product_offers (product_id);

CREATE TABLE site_settings (
  key text PRIMARY KEY,
  value jsonb NOT NULL,
  is_public boolean NOT NULL DEFAULT true,
  updated_by text REFERENCES "user" (id) ON DELETE SET NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE faqs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  question text NOT NULL,
  answer text NOT NULL,       -- نص عادي؛ الأسطر التي تبدأ بـ "- " تُعرض كقائمة
  sort int NOT NULL DEFAULT 0,
  published boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE policies (
  slug text PRIMARY KEY CHECK (slug ~ '^[a-z-]{2,40}$'),
  title text NOT NULL,
  body text NOT NULL,         -- كل سطر يبدأ بـ "- " عنصر قائمة
  sort int NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE media_assets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  storage_key text NOT NULL UNIQUE,
  mime text NOT NULL,
  size_bytes int NOT NULL,
  width int, height int,
  alt text NOT NULL DEFAULT '',
  usage text NOT NULL DEFAULT 'gallery' CHECK (usage IN ('hero', 'about', 'gallery', 'product')),
  rights_note text NOT NULL,              -- مصدر الصورة/إذن النشر (إلزامي)
  approved boolean NOT NULL DEFAULT false, -- مسموح بنشرها
  created_by text REFERENCES "user" (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE products ADD CONSTRAINT products_image_fk FOREIGN KEY (image_id) REFERENCES media_assets (id) ON DELETE SET NULL;

-- ---------- الطلبات ----------
CREATE TABLE orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_no text NOT NULL UNIQUE,
  user_id text NOT NULL REFERENCES "user" (id) ON DELETE RESTRICT,
  product_id uuid REFERENCES products (id) ON DELETE SET NULL,
  offer_id uuid REFERENCES product_offers (id) ON DELETE SET NULL,
  -- نسخة ثابتة من المنتج والسعر وقت الطلب (لا تتأثر بتعديل الأسعار لاحقاً)
  category text NOT NULL CHECK (category IN ('follow', 'files', 'consult')),
  product_name text NOT NULL,
  offer_label text NOT NULL,
  months int NOT NULL DEFAULT 0,
  list_price_halalas int NOT NULL,
  amount_due_halalas int CHECK (amount_due_halalas >= 0), -- NULL حتى تأكيد المبلغ (خصم الطالب)
  currency text NOT NULL DEFAULT 'SAR',
  student_discount_requested boolean NOT NULL DEFAULT false,
  payment_method text NOT NULL DEFAULT 'bank_transfer' CHECK (payment_method IN ('bank_transfer', 'gateway')),
  status text NOT NULL CHECK (status IN (
    'awaiting_quote', 'awaiting_payment', 'payment_review',
    'preparing', 'active', 'delivered', 'completed', 'cancelled')),
  contact_name text NOT NULL,
  contact_phone text NOT NULL,
  client_note text,
  idempotency_key text NOT NULL,
  is_demo boolean NOT NULL DEFAULT false,
  paid_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, idempotency_key)
);
CREATE INDEX ON orders (user_id, created_at DESC);
CREATE INDEX ON orders (status, created_at DESC);

-- سجل تغييرات الحالة: لا يُعدّل ولا يُحذف
CREATE TABLE order_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  order_id uuid NOT NULL REFERENCES orders (id) ON DELETE CASCADE,
  from_status text,
  to_status text NOT NULL,
  actor_id text REFERENCES "user" (id) ON DELETE SET NULL,
  actor_role text NOT NULL CHECK (actor_role IN ('client', 'coach', 'system')),
  note text,
  client_visible boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON order_events (order_id, id);

-- التقييم الأولي (يحتوي بيانات صحية حساسة في عمود منفصل)
CREATE TABLE intakes (
  order_id uuid PRIMARY KEY REFERENCES orders (id) ON DELETE CASCADE,
  user_id text NOT NULL REFERENCES "user" (id) ON DELETE CASCADE,
  answers jsonb NOT NULL,
  health jsonb NOT NULL DEFAULT '{}'::jsonb,
  health_flag boolean NOT NULL DEFAULT false,
  media_consent text NOT NULL,
  consent_terms_at timestamptz NOT NULL,
  consent_whatsapp_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE payment_proofs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES orders (id) ON DELETE CASCADE,
  user_id text NOT NULL REFERENCES "user" (id) ON DELETE CASCADE,
  storage_key text NOT NULL UNIQUE,
  mime text NOT NULL,
  size_bytes int NOT NULL,
  sha256 text NOT NULL,
  review_status text NOT NULL DEFAULT 'pending' CHECK (review_status IN ('pending', 'approved', 'rejected')),
  reviewed_by text REFERENCES "user" (id) ON DELETE SET NULL,
  reviewed_at timestamptz,
  review_note text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON payment_proofs (order_id);
CREATE UNIQUE INDEX payment_proofs_same_file ON payment_proofs (order_id, sha256);

CREATE TABLE deliverables (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES orders (id) ON DELETE CASCADE,
  title text NOT NULL,
  kind text NOT NULL CHECK (kind IN ('file', 'link')),
  storage_key text UNIQUE,
  mime text,
  size_bytes int,
  url text CHECK (url IS NULL OR url ~ '^https://'),
  created_by text REFERENCES "user" (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((kind = 'file' AND storage_key IS NOT NULL) OR (kind = 'link' AND url IS NOT NULL))
);
CREATE INDEX ON deliverables (order_id);

CREATE TABLE check_ins (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES orders (id) ON DELETE CASCADE,
  user_id text NOT NULL REFERENCES "user" (id) ON DELETE CASCADE,
  answers jsonb NOT NULL,
  coach_reply text,
  replied_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON check_ins (order_id, created_at DESC);

-- ---------- التقييمات ----------
CREATE TABLE reviews (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source text NOT NULL DEFAULT 'platform' CHECK (source IN ('platform', 'legacy')),
  user_id text REFERENCES "user" (id) ON DELETE SET NULL,
  order_id uuid UNIQUE REFERENCES orders (id) ON DELETE SET NULL,
  product_name text,
  rating smallint CHECK (rating BETWEEN 1 AND 5),
  body text NOT NULL CHECK (char_length(body) BETWEEN 10 AND 1500),
  display_mode text NOT NULL CHECK (display_mode IN ('full', 'first', 'anon')),
  display_name text NOT NULL,
  period_label text,
  consent_publish boolean NOT NULL,
  consent_at timestamptz,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'published', 'rejected', 'hidden')),
  coach_reply text,
  moderation_reason text,
  moderated_by text REFERENCES "user" (id) ON DELETE SET NULL,
  moderated_at timestamptz,
  sort int NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (status <> 'published' OR consent_publish)
);

CREATE TABLE review_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  review_id uuid NOT NULL REFERENCES reviews (id) ON DELETE CASCADE,
  action text NOT NULL,
  from_status text,
  to_status text,
  reason text,
  actor_id text REFERENCES "user" (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ---------- سجل الإدارة، حدود الطلبات، بريد التطوير ----------
CREATE TABLE admin_log (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  actor_id text REFERENCES "user" (id) ON DELETE SET NULL,
  action text NOT NULL,
  target text,
  details jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE rate_hits (
  key text NOT NULL,
  at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON rate_hits (key, at);

-- يُستخدم فقط في التطوير والاختبار عندما لا يوجد مزود بريد (لا يُكتب فيه في الإنتاج)
CREATE TABLE dev_mailbox (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  recipient text NOT NULL,
  subject text NOT NULL,
  body text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO schema_migrations (name) VALUES ('001_schema.sql');

-- ---------- 002_security.sql ----------
-- =====================================================================
-- الصلاحيات على مستوى قاعدة البيانات
-- * هوية المستخدم تأتي من app.user_id الذي يضبطه الخادم بعد التحقق من الجلسة.
-- * الدور (coach/client) يُقرأ من جدول user، ولا يُؤخذ من الطلب.
-- * الطلبات والإيصالات والتقييمات لا تُكتب مباشرة؛ فقط عبر دوال تتحقق من الملكية والحالة.
-- =====================================================================

CREATE OR REPLACE FUNCTION app.uid() RETURNS text
LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('app.user_id', true), '') $$;

CREATE OR REPLACE FUNCTION app.is_coach() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM "user" WHERE id = app.uid() AND role = 'coach')
$$;

CREATE OR REPLACE FUNCTION app.require_user() RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE u text := app.uid();
BEGIN
  IF u IS NULL THEN RAISE EXCEPTION 'يلزم تسجيل الدخول.' USING ERRCODE = 'P0001'; END IF;
  RETURN u;
END $$;

CREATE OR REPLACE FUNCTION app.require_coach() RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NOT app.is_coach() THEN RAISE EXCEPTION 'هذا الإجراء للمدربة فقط.' USING ERRCODE = '42501'; END IF;
  RETURN app.uid();
END $$;

-- هل يحق لصاحب الطلب الوصول لملفات البرنامج؟ (بعد تأكيد الدفع فقط)
CREATE OR REPLACE FUNCTION app.order_entitled(p_order uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM orders o WHERE o.id = p_order AND o.user_id = app.uid()
                 AND o.status IN ('active', 'delivered', 'completed'))
$$;

CREATE OR REPLACE FUNCTION app.owns_order(p_order uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM orders o WHERE o.id = p_order AND o.user_id = app.uid())
$$;

-- ---------- حد الطلبات ----------
CREATE OR REPLACE FUNCTION app.rate_limit(p_key text, p_max int, p_window_seconds int) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE n int;
BEGIN
  DELETE FROM rate_hits WHERE key = p_key AND at < now() - make_interval(secs => p_window_seconds);
  SELECT count(*) INTO n FROM rate_hits WHERE key = p_key;
  IF n >= p_max THEN RETURN false; END IF;
  INSERT INTO rate_hits (key) VALUES (p_key);
  RETURN true;
END $$;

-- ---------- رقم الطلب ----------
CREATE OR REPLACE FUNCTION app.new_order_no() RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  candidate text;
  i int;
BEGIN
  LOOP
    candidate := 'NAV-' || to_char(now() AT TIME ZONE 'Asia/Riyadh', 'YYMMDD') || '-';
    FOR i IN 1..5 LOOP
      candidate := candidate || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    END LOOP;
    EXIT WHEN NOT EXISTS (SELECT 1 FROM orders WHERE order_no = candidate);
  END LOOP;
  RETURN candidate;
END $$;

-- ---------- إنشاء الطلب ----------
-- السعر يُقرأ من قاعدة البيانات دائماً؛ العميل يرسل رمز العرض (sku) فقط.
CREATE OR REPLACE FUNCTION app.create_order(
  p_sku text, p_idempotency_key text, p_student boolean,
  p_contact_name text, p_contact_phone text,
  p_answers jsonb, p_health jsonb, p_health_flag boolean,
  p_media_consent text, p_client_note text
) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_user text := app.require_user();
  v_offer record;
  v_order_no text;
  v_order uuid;
  v_status text;
BEGIN
  IF p_idempotency_key IS NULL OR length(p_idempotency_key) < 16 THEN
    RAISE EXCEPTION 'طلب غير صالح.' USING ERRCODE = 'P0001';
  END IF;

  SELECT order_no INTO v_order_no FROM orders WHERE user_id = v_user AND idempotency_key = p_idempotency_key;
  IF FOUND THEN RETURN v_order_no; END IF; -- نفس الطلب أُرسل مرتين

  SELECT o.id AS offer_id, o.label, o.months, o.price_halalas, o.currency,
         p.id AS product_id, p.name, p.category, p.is_demo
    INTO v_offer
    FROM product_offers o JOIN products p ON p.id = o.product_id
   WHERE o.sku = p_sku AND o.active AND p.status = 'published';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'هذا البرنامج غير متاح حالياً.' USING ERRCODE = 'P0001';
  END IF;

  v_status := CASE WHEN p_student THEN 'awaiting_quote' ELSE 'awaiting_payment' END;
  v_order_no := app.new_order_no();

  INSERT INTO orders (order_no, user_id, product_id, offer_id, category, product_name, offer_label, months,
                      list_price_halalas, amount_due_halalas, currency, student_discount_requested, status,
                      contact_name, contact_phone, client_note, idempotency_key, is_demo)
  VALUES (v_order_no, v_user, v_offer.product_id, v_offer.offer_id, v_offer.category, v_offer.name, v_offer.label,
          v_offer.months, v_offer.price_halalas,
          CASE WHEN p_student THEN NULL ELSE v_offer.price_halalas END,
          v_offer.currency, p_student, v_status,
          p_contact_name, p_contact_phone, nullif(p_client_note, ''), p_idempotency_key, v_offer.is_demo)
  RETURNING id INTO v_order;

  INSERT INTO intakes (order_id, user_id, answers, health, health_flag, media_consent, consent_terms_at, consent_whatsapp_at)
  VALUES (v_order, v_user, p_answers, coalesce(p_health, '{}'::jsonb), p_health_flag, p_media_consent, now(), now());

  INSERT INTO order_events (order_id, from_status, to_status, actor_id, actor_role, note)
  VALUES (v_order, NULL, v_status, v_user, 'client',
          CASE WHEN p_student THEN 'تم استلام الطلب والتقييم. بانتظار تأكيد مبلغ خصم الطالب.'
               ELSE 'تم استلام الطلب والتقييم.' END);

  UPDATE "user" SET phone = p_contact_phone,
         name = CASE WHEN name = '' OR name = split_part(email, '@', 1) THEN p_contact_name ELSE name END
   WHERE id = v_user;

  RETURN v_order_no;
END $$;

-- ---------- رفع إيصال التحويل (العميل) ----------
CREATE OR REPLACE FUNCTION app.submit_payment_proof(
  p_order_no text, p_storage_key text, p_mime text, p_size int, p_sha256 text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_user text := app.require_user();
  v_order orders%ROWTYPE;
BEGIN
  SELECT * INTO v_order FROM orders WHERE order_no = p_order_no AND user_id = v_user FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  IF v_order.status <> 'awaiting_payment' THEN
    RAISE EXCEPTION 'لا يمكن رفع إيصال في حالة الطلب الحالية.' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM payment_proofs WHERE order_id = v_order.id AND sha256 = p_sha256) THEN
    RAISE EXCEPTION 'هذا الإيصال مرفوع مسبقاً لهذا الطلب.' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO payment_proofs (order_id, user_id, storage_key, mime, size_bytes, sha256)
  VALUES (v_order.id, v_user, p_storage_key, p_mime, p_size, p_sha256);

  UPDATE orders SET status = 'payment_review', updated_at = now() WHERE id = v_order.id;
  INSERT INTO order_events (order_id, from_status, to_status, actor_id, actor_role, note)
  VALUES (v_order.id, v_order.status, 'payment_review', v_user, 'client', 'تم رفع إيصال التحويل.');
END $$;

-- ---------- إلغاء العميل قبل الدفع ----------
CREATE OR REPLACE FUNCTION app.client_cancel(p_order_no text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_user text := app.require_user();
  v_order orders%ROWTYPE;
BEGIN
  SELECT * INTO v_order FROM orders WHERE order_no = p_order_no AND user_id = v_user FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  IF v_order.status NOT IN ('awaiting_quote', 'awaiting_payment') THEN
    RAISE EXCEPTION 'لا يمكن إلغاء الطلب في حالته الحالية. تواصل معنا على واتساب.' USING ERRCODE = 'P0001';
  END IF;
  UPDATE orders SET status = 'cancelled', updated_at = now() WHERE id = v_order.id;
  INSERT INTO order_events (order_id, from_status, to_status, actor_id, actor_role, note)
  VALUES (v_order.id, v_order.status, 'cancelled', v_user, 'client', 'ألغى العميل الطلب قبل الدفع.');
END $$;

-- ---------- تأكيد المبلغ (خصم الطالب/حالات خاصة) ----------
CREATE OR REPLACE FUNCTION app.coach_set_amount(p_order_no text, p_amount_halalas int, p_note text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_coach text := app.require_coach();
  v_order orders%ROWTYPE;
  v_to text;
BEGIN
  SELECT * INTO v_order FROM orders WHERE order_no = p_order_no FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  IF v_order.status NOT IN ('awaiting_quote', 'awaiting_payment') THEN
    RAISE EXCEPTION 'لا يمكن تعديل المبلغ بعد رفع الإيصال أو تأكيد الدفع.' USING ERRCODE = 'P0001';
  END IF;
  IF p_amount_halalas IS NULL OR p_amount_halalas < 0 OR p_amount_halalas > v_order.list_price_halalas THEN
    RAISE EXCEPTION 'المبلغ غير صالح.' USING ERRCODE = 'P0001';
  END IF;
  v_to := CASE WHEN p_amount_halalas = 0 THEN 'preparing' ELSE 'awaiting_payment' END;
  UPDATE orders SET amount_due_halalas = p_amount_halalas, status = v_to, updated_at = now(),
                    paid_at = CASE WHEN p_amount_halalas = 0 THEN now() ELSE paid_at END
   WHERE id = v_order.id;
  INSERT INTO order_events (order_id, from_status, to_status, actor_id, actor_role, note)
  VALUES (v_order.id, v_order.status, v_to, v_coach, 'coach',
          concat_ws(' — ', 'تم تأكيد المبلغ: ' || (p_amount_halalas / 100)::text || ' ر.س', nullif(p_note, '')));
END $$;

-- ---------- تغيير الحالة (المدربة) ----------
CREATE OR REPLACE FUNCTION app.coach_transition(
  p_order_no text, p_to text, p_note text, p_bank_confirmed boolean DEFAULT false
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_coach text := app.require_coach();
  v_order orders%ROWTYPE;
  v_ok boolean;
BEGIN
  SELECT * INTO v_order FROM orders WHERE order_no = p_order_no FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود.' USING ERRCODE = 'P0001'; END IF;

  v_ok := CASE
    WHEN p_to = 'cancelled' THEN v_order.status NOT IN ('completed', 'cancelled')
    WHEN v_order.status = 'awaiting_payment' THEN p_to = 'preparing'
    WHEN v_order.status = 'payment_review'   THEN p_to IN ('preparing', 'awaiting_payment')
    WHEN v_order.status = 'preparing' THEN
      (v_order.category = 'follow' AND p_to = 'active') OR
      (v_order.category = 'files' AND p_to = 'delivered') OR
      (v_order.category = 'consult' AND p_to = 'completed')
    WHEN v_order.status = 'active'    THEN p_to = 'completed'
    WHEN v_order.status = 'delivered' THEN p_to = 'completed'
    ELSE false END;
  IF NOT v_ok THEN
    RAISE EXCEPTION 'انتقال غير مسموح من هذه الحالة.' USING ERRCODE = 'P0001';
  END IF;

  IF p_to = 'preparing' THEN
    IF v_order.amount_due_halalas IS NULL THEN
      RAISE EXCEPTION 'حددي المبلغ أولاً.' USING ERRCODE = 'P0001';
    END IF;
    IF NOT p_bank_confirmed THEN
      RAISE EXCEPTION 'لا يُعتمد الدفع إلا بعد التأكد من وصول المبلغ في كشف الحساب.' USING ERRCODE = 'P0001';
    END IF;
    UPDATE payment_proofs SET review_status = 'approved', reviewed_by = v_coach, reviewed_at = now(),
                              review_note = nullif(p_note, '')
     WHERE order_id = v_order.id AND review_status = 'pending';
  END IF;

  IF v_order.status = 'payment_review' AND p_to = 'awaiting_payment' THEN
    IF coalesce(trim(p_note), '') = '' THEN
      RAISE EXCEPTION 'اكتبي سبب رفض الإيصال ليظهر للعميل.' USING ERRCODE = 'P0001';
    END IF;
    UPDATE payment_proofs SET review_status = 'rejected', reviewed_by = v_coach, reviewed_at = now(), review_note = p_note
     WHERE order_id = v_order.id AND review_status = 'pending';
  END IF;

  UPDATE orders SET status = p_to, updated_at = now(),
                    paid_at = CASE WHEN p_to = 'preparing' THEN now() ELSE paid_at END
   WHERE id = v_order.id;
  INSERT INTO order_events (order_id, from_status, to_status, actor_id, actor_role, note)
  VALUES (v_order.id, v_order.status, p_to, v_coach, 'coach', nullif(p_note, ''));
END $$;

-- ---------- المراجعة الأسبوعية ----------
CREATE OR REPLACE FUNCTION app.submit_checkin(p_order_no text, p_answers jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_user text := app.require_user();
  v_order orders%ROWTYPE;
BEGIN
  SELECT * INTO v_order FROM orders WHERE order_no = p_order_no AND user_id = v_user;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  IF v_order.category <> 'follow' OR v_order.status <> 'active' THEN
    RAISE EXCEPTION 'المراجعة الأسبوعية متاحة للبرامج النشطة مع متابعة فقط.' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM check_ins WHERE order_id = v_order.id AND created_at > now() - interval '20 hours') THEN
    RAISE EXCEPTION 'أرسلت مراجعة قبل قليل. تقدر ترسل المراجعة التالية لاحقاً.' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO check_ins (order_id, user_id, answers) VALUES (v_order.id, v_user, p_answers);
END $$;

CREATE OR REPLACE FUNCTION app.reply_checkin(p_id uuid, p_reply text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  PERFORM app.require_coach();
  UPDATE check_ins SET coach_reply = p_reply, replied_at = now() WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'المراجعة غير موجودة.' USING ERRCODE = 'P0001'; END IF;
END $$;

-- ---------- التقييمات ----------
CREATE OR REPLACE FUNCTION app.submit_review(
  p_order_no text, p_rating int, p_body text, p_display_mode text, p_consent boolean
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_user text := app.require_user();
  v_order orders%ROWTYPE;
  v_name text;
  v_compact text;
BEGIN
  SELECT * INTO v_order FROM orders WHERE order_no = p_order_no AND user_id = v_user;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  IF v_order.status NOT IN ('active', 'delivered', 'completed') THEN
    RAISE EXCEPTION 'تقدر تكتب تقييمك بعد بدء الخدمة.' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM reviews WHERE order_id = v_order.id) THEN
    RAISE EXCEPTION 'أرسلت تقييماً لهذا الطلب مسبقاً.' USING ERRCODE = 'P0001';
  END IF;
  IF p_display_mode NOT IN ('full', 'first', 'anon') THEN
    RAISE EXCEPTION 'اختيار عرض الاسم غير صالح.' USING ERRCODE = 'P0001';
  END IF;
  -- منع أرقام الهواتف والبريد والروابط داخل نص التقييم
  v_compact := regexp_replace(translate(p_body, '٠١٢٣٤٥٦٧٨٩', '0123456789'), '[\s\-\.\(\)+]', '', 'g');
  IF v_compact ~ '[0-9]{7,}' OR p_body ~* '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}' OR p_body ~* '(https?://|www\.)' THEN
    RAISE EXCEPTION 'احذف أرقام الهواتف أو البريد أو الروابط من نص التقييم.' USING ERRCODE = 'P0001';
  END IF;

  SELECT name INTO v_name FROM "user" WHERE id = v_user;
  INSERT INTO reviews (source, user_id, order_id, product_name, rating, body, display_mode, display_name,
                       consent_publish, consent_at, status)
  VALUES ('platform', v_user, v_order.id, v_order.product_name, p_rating, trim(p_body), p_display_mode,
          CASE p_display_mode WHEN 'full' THEN v_name
                              WHEN 'first' THEN split_part(trim(v_name), ' ', 1)
                              ELSE 'متدرب/ة في Nav Coaching' END,
          p_consent, CASE WHEN p_consent THEN now() END, 'pending');
END $$;

CREATE OR REPLACE FUNCTION app.moderate_review(p_id uuid, p_action text, p_reason text, p_reply text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_coach text := app.require_coach();
  v_review reviews%ROWTYPE;
  v_to text;
BEGIN
  SELECT * INTO v_review FROM reviews WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'التقييم غير موجود.' USING ERRCODE = 'P0001'; END IF;

  IF p_action = 'reply' THEN
    UPDATE reviews SET coach_reply = nullif(trim(p_reply), '') WHERE id = p_id;
    INSERT INTO review_events (review_id, action, from_status, to_status, reason, actor_id)
    VALUES (p_id, 'reply', v_review.status, v_review.status, NULL, v_coach);
    RETURN;
  END IF;

  v_to := CASE p_action WHEN 'publish' THEN 'published' WHEN 'reject' THEN 'rejected' WHEN 'hide' THEN 'hidden' END;
  IF v_to IS NULL THEN RAISE EXCEPTION 'إجراء غير معروف.' USING ERRCODE = 'P0001'; END IF;
  IF v_to = 'published' AND NOT v_review.consent_publish THEN
    RAISE EXCEPTION 'صاحب التقييم لم يوافق على النشر.' USING ERRCODE = 'P0001';
  END IF;
  IF v_to IN ('rejected', 'hidden') AND coalesce(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'اذكري سبب الرفض أو الإخفاء وفق سياسة التقييمات.' USING ERRCODE = 'P0001';
  END IF;

  UPDATE reviews SET status = v_to, moderation_reason = nullif(trim(p_reason), ''),
                     moderated_by = v_coach, moderated_at = now() WHERE id = p_id;
  INSERT INTO review_events (review_id, action, from_status, to_status, reason, actor_id)
  VALUES (p_id, p_action, v_review.status, v_to, nullif(trim(p_reason), ''), v_coach);
END $$;

-- نص التقييم ودرجته لا يُعدّلان بعد الإرسال، ولا من المدربة
CREATE OR REPLACE FUNCTION app.protect_review_content() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.body IS DISTINCT FROM OLD.body OR NEW.rating IS DISTINCT FROM OLD.rating
     OR NEW.display_name IS DISTINCT FROM OLD.display_name OR NEW.consent_publish IS DISTINCT FROM OLD.consent_publish THEN
    RAISE EXCEPTION 'لا يمكن تعديل مضمون التقييم.' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER reviews_protect_content BEFORE UPDATE ON reviews FOR EACH ROW EXECUTE FUNCTION app.protect_review_content();

-- السجلات لا تُعدّل ولا تُحذف
CREATE OR REPLACE FUNCTION app.append_only() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'السجل للإضافة فقط.' USING ERRCODE = 'P0001';
END $$;
CREATE TRIGGER order_events_append_only BEFORE UPDATE OR DELETE ON order_events FOR EACH ROW EXECUTE FUNCTION app.append_only();
CREATE TRIGGER review_events_append_only BEFORE UPDATE OR DELETE ON review_events FOR EACH ROW EXECUTE FUNCTION app.append_only();
CREATE TRIGGER admin_log_append_only BEFORE UPDATE OR DELETE ON admin_log FOR EACH ROW EXECUTE FUNCTION app.append_only();

-- عرض عام للتقييمات المنشورة بحقول آمنة فقط (بدون معرّف المستخدم أو الطلب)
CREATE VIEW public_reviews AS
  SELECT id, source, product_name, rating, body, display_name, period_label, coach_reply, created_at, sort
    FROM reviews WHERE status = 'published';

-- ---------- تفعيل RLS ----------
ALTER TABLE products        ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_offers  ENABLE ROW LEVEL SECURITY;
ALTER TABLE site_settings   ENABLE ROW LEVEL SECURITY;
ALTER TABLE faqs            ENABLE ROW LEVEL SECURITY;
ALTER TABLE policies        ENABLE ROW LEVEL SECURITY;
ALTER TABLE media_assets    ENABLE ROW LEVEL SECURITY;
ALTER TABLE orders          ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_events    ENABLE ROW LEVEL SECURITY;
ALTER TABLE intakes         ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_proofs  ENABLE ROW LEVEL SECURITY;
ALTER TABLE deliverables    ENABLE ROW LEVEL SECURITY;
ALTER TABLE check_ins       ENABLE ROW LEVEL SECURITY;
ALTER TABLE reviews         ENABLE ROW LEVEL SECURITY;
ALTER TABLE review_events   ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_log       ENABLE ROW LEVEL SECURITY;
ALTER TABLE rate_hits       ENABLE ROW LEVEL SECURITY;
ALTER TABLE dev_mailbox     ENABLE ROW LEVEL SECURITY;

-- محتوى عام: القراءة للجميع للمنشور فقط، والتعديل للمدربة
CREATE POLICY products_read ON products FOR SELECT USING (status = 'published' OR app.is_coach());
CREATE POLICY products_write ON products FOR ALL USING (app.is_coach()) WITH CHECK (app.is_coach());

CREATE POLICY offers_read ON product_offers FOR SELECT USING (
  app.is_coach() OR (active AND EXISTS (SELECT 1 FROM products p WHERE p.id = product_id AND p.status = 'published')));
CREATE POLICY offers_write ON product_offers FOR ALL USING (app.is_coach()) WITH CHECK (app.is_coach());

CREATE POLICY settings_read ON site_settings FOR SELECT USING (is_public OR app.is_coach());
CREATE POLICY settings_write ON site_settings FOR ALL USING (app.is_coach()) WITH CHECK (app.is_coach());

CREATE POLICY faqs_read ON faqs FOR SELECT USING (published OR app.is_coach());
CREATE POLICY faqs_write ON faqs FOR ALL USING (app.is_coach()) WITH CHECK (app.is_coach());

CREATE POLICY policies_read ON policies FOR SELECT USING (true);
CREATE POLICY policies_write ON policies FOR ALL USING (app.is_coach()) WITH CHECK (app.is_coach());

CREATE POLICY media_read ON media_assets FOR SELECT USING (approved OR app.is_coach());
CREATE POLICY media_write ON media_assets FOR ALL USING (app.is_coach()) WITH CHECK (app.is_coach());

-- بيانات العملاء: صاحبها أو المدربة فقط
CREATE POLICY orders_read ON orders FOR SELECT USING (user_id = app.uid() OR app.is_coach());
CREATE POLICY events_read ON order_events FOR SELECT USING (
  app.is_coach() OR (client_visible AND app.owns_order(order_id)));
CREATE POLICY intakes_read ON intakes FOR SELECT USING (user_id = app.uid() OR app.is_coach());
CREATE POLICY proofs_read ON payment_proofs FOR SELECT USING (user_id = app.uid() OR app.is_coach());
CREATE POLICY deliverables_read ON deliverables FOR SELECT USING (app.is_coach() OR app.order_entitled(order_id));
CREATE POLICY deliverables_write ON deliverables FOR ALL USING (app.is_coach()) WITH CHECK (app.is_coach());
CREATE POLICY checkins_read ON check_ins FOR SELECT USING (user_id = app.uid() OR app.is_coach());
CREATE POLICY reviews_read ON reviews FOR SELECT USING (user_id = app.uid() OR app.is_coach());
CREATE POLICY review_events_read ON review_events FOR SELECT USING (app.is_coach());
CREATE POLICY admin_log_read ON admin_log FOR SELECT USING (app.is_coach());
CREATE POLICY admin_log_write ON admin_log FOR INSERT WITH CHECK (app.is_coach() AND actor_id = app.uid());
-- rate_hits: لا وصول مباشر (عبر app.rate_limit فقط)
CREATE POLICY dev_mailbox_insert ON dev_mailbox FOR INSERT WITH CHECK (true);

-- ---------- الصلاحيات للدور nav_app ----------
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT USAGE ON SCHEMA public, app TO nav_app;

-- جداول الدخول: يديرها Better Auth من الخادم فقط
GRANT SELECT, INSERT, UPDATE, DELETE ON "user", "session", "account", "verification", "rateLimit" TO nav_app;

GRANT SELECT ON products, product_offers, site_settings, faqs, policies, media_assets TO nav_app;
GRANT INSERT, UPDATE, DELETE ON products, product_offers, site_settings, faqs, policies, media_assets, deliverables TO nav_app;
GRANT SELECT ON orders, order_events, intakes, payment_proofs, deliverables, check_ins, reviews, review_events, admin_log TO nav_app;
GRANT INSERT ON admin_log, dev_mailbox TO nav_app;
GRANT SELECT ON public_reviews TO nav_app;

GRANT EXECUTE ON FUNCTION
  app.uid(), app.is_coach(), app.require_user(), app.require_coach(), app.order_entitled(uuid), app.owns_order(uuid),
  app.rate_limit(text, int, int),
  app.create_order(text, text, boolean, text, text, jsonb, jsonb, boolean, text, text),
  app.submit_payment_proof(text, text, text, int, text),
  app.client_cancel(text),
  app.coach_set_amount(text, int, text),
  app.coach_transition(text, text, text, boolean),
  app.submit_checkin(text, jsonb),
  app.reply_checkin(uuid, text),
  app.submit_review(text, int, text, text, boolean),
  app.moderate_review(uuid, text, text, text)
TO nav_app;

INSERT INTO schema_migrations (name) VALUES ('002_security.sql');

-- ---------- 003_order_archive.sql ----------
-- =====================================================================
-- أرشفة الطلبات (إخفاؤها من قائمة الإدارة) والحذف النهائي للطلبات الملغاة فقط
-- =====================================================================

ALTER TABLE orders ADD COLUMN IF NOT EXISTS archived_at timestamptz;
CREATE INDEX IF NOT EXISTS orders_archived_idx ON orders (archived_at);

-- السجل يبقى للإضافة فقط، إلا داخل دالة الحذف النهائي (تضبط app.allow_purge داخل معاملتها)
CREATE OR REPLACE FUNCTION app.append_only() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' AND current_setting('app.allow_purge', true) = '1' THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'السجل للإضافة فقط.' USING ERRCODE = 'P0001';
END $$;

-- إخفاء/إظهار طلب في قائمة الإدارة (لا يغيّر الطلب نفسه، والعميل يراه كما هو)
CREATE OR REPLACE FUNCTION app.coach_archive_order(p_order_no text, p_archive boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_coach text := app.require_coach();
BEGIN
  UPDATE orders SET archived_at = CASE WHEN p_archive THEN now() END WHERE order_no = p_order_no;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  INSERT INTO admin_log (actor_id, action, target) VALUES (v_coach, CASE WHEN p_archive THEN 'order.archive' ELSE 'order.unarchive' END, p_order_no);
END $$;

-- حذف نهائي: للطلبات الملغاة فقط. يرجع مفاتيح الملفات لحذفها من التخزين.
CREATE OR REPLACE FUNCTION app.coach_delete_order(p_order_no text) RETURNS text[]
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_coach text := app.require_coach();
  v_order orders%ROWTYPE;
  v_keys text[];
BEGIN
  SELECT * INTO v_order FROM orders WHERE order_no = p_order_no FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  IF v_order.status <> 'cancelled' THEN
    RAISE EXCEPTION 'الحذف النهائي للطلبات الملغاة فقط. ألغي الطلب أولاً، أو استخدمي الإخفاء من القائمة.' USING ERRCODE = 'P0001';
  END IF;

  SELECT coalesce(array_agg(k), '{}') INTO v_keys FROM (
    SELECT storage_key AS k FROM payment_proofs WHERE order_id = v_order.id
    UNION ALL
    SELECT storage_key FROM deliverables WHERE order_id = v_order.id AND storage_key IS NOT NULL
  ) s;

  PERFORM set_config('app.allow_purge', '1', true);
  DELETE FROM orders WHERE id = v_order.id;
  PERFORM set_config('app.allow_purge', '', true);

  INSERT INTO admin_log (actor_id, action, target, details)
  VALUES (v_coach, 'order.delete', p_order_no,
          jsonb_build_object('product', v_order.product_name, 'offer', v_order.offer_label, 'created_at', v_order.created_at));
  RETURN v_keys;
END $$;

REVOKE ALL ON FUNCTION app.coach_archive_order(text, boolean), app.coach_delete_order(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.coach_archive_order(text, boolean), app.coach_delete_order(text) TO nav_app;

INSERT INTO schema_migrations (name) VALUES ('003_order_archive.sql');

-- ---------- 004_followup.sql ----------
-- =====================================================================
-- متابعة المتدربين: ملاحظات إدارية خاصة، تواريخ الاشتراك، جدول المراجعة الأسبوعية،
-- سجل الإشعارات، تفضيلات التواصل، ومستخدم نظام للمهام المجدولة.
-- =====================================================================

-- ---------- مستخدم النظام (للتذكيرات المجدولة) ----------
-- لا يستطيع أحد الدخول به: بريده بنطاق .invalid لا يستقبل رمز الدخول، ولوحة الإدارة تسمح للدور coach فقط.
ALTER TABLE "user" DROP CONSTRAINT IF EXISTS "user_role_check";
ALTER TABLE "user" ADD CONSTRAINT "user_role_check" CHECK ("role" IN ('client', 'coach', 'system'));
INSERT INTO "user" (id, name, email, "emailVerified", role)
VALUES ('system-scheduler', 'التذكيرات التلقائية', 'scheduler@navcoaching.invalid', false, 'system')
ON CONFLICT (id) DO NOTHING;

-- صلاحيات الإدارة في قاعدة البيانات: المدربة، ومستخدم النظام للمهام المجدولة
CREATE OR REPLACE FUNCTION app.is_coach() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM "user" WHERE id = app.uid() AND role IN ('coach', 'system'))
$$;

-- ---------- 1) ملاحظات المدربة الخاصة على الطلب (لا تُقرأ إلا بصلاحية إدارية) ----------
CREATE TABLE order_admin_notes (
  order_id uuid PRIMARY KEY REFERENCES orders (id) ON DELETE CASCADE,
  body text NOT NULL DEFAULT '',
  updated_by text REFERENCES "user" (id) ON DELETE SET NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE order_admin_notes ENABLE ROW LEVEL SECURITY;
CREATE POLICY admin_notes_read ON order_admin_notes FOR SELECT USING (app.is_coach());
GRANT SELECT ON order_admin_notes TO nav_app;

CREATE OR REPLACE FUNCTION app.coach_save_note(p_order_no text, p_body text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_coach text := app.require_coach();
  v_order uuid;
BEGIN
  SELECT id INTO v_order FROM orders WHERE order_no = p_order_no;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  IF length(p_body) > 5000 THEN RAISE EXCEPTION 'الملاحظة أطول من 5000 حرف.' USING ERRCODE = 'P0001'; END IF;
  INSERT INTO order_admin_notes (order_id, body, updated_by, updated_at) VALUES (v_order, p_body, v_coach, now())
  ON CONFLICT (order_id) DO UPDATE SET body = EXCLUDED.body, updated_by = EXCLUDED.updated_by, updated_at = now();
END $$;

-- ---------- 4) تواريخ الاشتراك ----------
ALTER TABLE orders ADD COLUMN IF NOT EXISTS sub_start_at timestamptz;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS sub_end_at timestamptz;
-- 5) يوم المراجعة الأسبوعية (0 = الأحد … 6 = السبت، بتوقيت الرياض)
ALTER TABLE orders ADD COLUMN IF NOT EXISTS review_weekday smallint CHECK (review_weekday BETWEEN 0 AND 6);

-- يُسجّل البدء تلقائياً عند تفعيل اشتراك له مدة (الانتقال إلى «نشط»)، ولا يُعاد عند أي تحديث لاحق
CREATE OR REPLACE FUNCTION app.set_subscription_dates() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status = 'active' AND OLD.status IS DISTINCT FROM 'active' AND NEW.months > 0 AND NEW.sub_start_at IS NULL THEN
    NEW.sub_start_at := now();
    NEW.sub_end_at := now() + make_interval(months => NEW.months);
    NEW.review_weekday := coalesce(NEW.review_weekday, extract(dow FROM (now() AT TIME ZONE 'Asia/Riyadh'))::smallint);
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER orders_subscription_dates BEFORE UPDATE OF status ON orders
  FOR EACH ROW EXECUTE FUNCTION app.set_subscription_dates();

-- تعديل يدوي من المدربة (مثل التجديد المجاني أو تأجيل البداية)
CREATE OR REPLACE FUNCTION app.coach_set_subscription(p_order_no text, p_start timestamptz, p_end timestamptz, p_weekday int)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_coach text := app.require_coach();
  v_order orders%ROWTYPE;
BEGIN
  SELECT * INTO v_order FROM orders WHERE order_no = p_order_no FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  IF v_order.months = 0 THEN RAISE EXCEPTION 'هذا المنتج بدون مدة اشتراك.' USING ERRCODE = 'P0001'; END IF;
  IF p_start IS NULL OR p_end IS NULL OR p_end <= p_start THEN
    RAISE EXCEPTION 'تاريخ الانتهاء لازم يكون بعد تاريخ البدء.' USING ERRCODE = 'P0001';
  END IF;
  IF p_weekday IS NOT NULL AND (p_weekday < 0 OR p_weekday > 6) THEN
    RAISE EXCEPTION 'يوم المراجعة غير صالح.' USING ERRCODE = 'P0001';
  END IF;
  UPDATE orders SET sub_start_at = p_start, sub_end_at = p_end, review_weekday = p_weekday, updated_at = now()
   WHERE id = v_order.id;
  INSERT INTO admin_log (actor_id, action, target, details)
  VALUES (v_coach, 'subscription.set', p_order_no,
          jsonb_build_object('start', p_start, 'end', p_end, 'weekday', p_weekday,
                             'old_start', v_order.sub_start_at, 'old_end', v_order.sub_end_at));
END $$;

-- ---------- 6) إنجاز المراجعات الأسبوعية (يدوي من المدربة إلى حين مزامنة Google Sheets) ----------
CREATE TABLE review_weeks (
  order_id uuid NOT NULL REFERENCES orders (id) ON DELETE CASCADE,
  week_no int NOT NULL CHECK (week_no BETWEEN 1 AND 200),
  done_at timestamptz NOT NULL DEFAULT now(),
  done_by text REFERENCES "user" (id) ON DELETE SET NULL,
  source text NOT NULL DEFAULT 'manual' CHECK (source IN ('manual', 'sheet')),
  PRIMARY KEY (order_id, week_no)
);
ALTER TABLE review_weeks ENABLE ROW LEVEL SECURITY;
CREATE POLICY review_weeks_read ON review_weeks FOR SELECT USING (app.is_coach() OR app.owns_order(order_id));
GRANT SELECT ON review_weeks TO nav_app;

CREATE OR REPLACE FUNCTION app.coach_mark_week(p_order_no text, p_week int, p_done boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_coach text := app.require_coach();
  v_order uuid;
BEGIN
  SELECT id INTO v_order FROM orders WHERE order_no = p_order_no;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  IF p_done THEN
    INSERT INTO review_weeks (order_id, week_no, done_by) VALUES (v_order, p_week, v_coach) ON CONFLICT DO NOTHING;
  ELSE
    DELETE FROM review_weeks WHERE order_id = v_order AND week_no = p_week;
  END IF;
END $$;

-- ---------- 12) تحديث الوزن والطول للاستبيانات القديمة (صاحب الطلب فقط) ----------
CREATE OR REPLACE FUNCTION app.update_intake_measurements(p_order_no text, p_weight numeric, p_height numeric) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_user text := app.require_user();
  v_order uuid;
BEGIN
  SELECT id INTO v_order FROM orders WHERE order_no = p_order_no AND user_id = v_user;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  IF p_weight IS NULL OR p_weight < 30 OR p_weight > 250 THEN RAISE EXCEPTION 'اكتب وزناً بين 30 و 250 كغ.' USING ERRCODE = 'P0001'; END IF;
  IF p_height IS NULL OR p_height < 120 OR p_height > 230 THEN RAISE EXCEPTION 'اكتب طولاً بين 120 و 230 سم.' USING ERRCODE = 'P0001'; END IF;
  UPDATE intakes SET health = health || jsonb_build_object('weight', p_weight, 'height', p_height)
   WHERE order_id = v_order;
END $$;

-- ---------- 7) تفضيلات التواصل ----------
CREATE TABLE user_prefs (
  user_id text PRIMARY KEY REFERENCES "user" (id) ON DELETE CASCADE,
  email_enabled boolean NOT NULL DEFAULT true,
  whatsapp_enabled boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE user_prefs ENABLE ROW LEVEL SECURITY;
CREATE POLICY prefs_read ON user_prefs FOR SELECT USING (user_id = app.uid() OR app.is_coach());
CREATE POLICY prefs_insert ON user_prefs FOR INSERT WITH CHECK (user_id = app.uid());
CREATE POLICY prefs_update ON user_prefs FOR UPDATE USING (user_id = app.uid()) WITH CHECK (user_id = app.uid());
GRANT SELECT, INSERT, UPDATE ON user_prefs TO nav_app;

-- ---------- 7، 8) سجل الإشعارات ----------
CREATE TABLE notification_log (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id text REFERENCES "user" (id) ON DELETE SET NULL,
  order_id uuid REFERENCES orders (id) ON DELETE SET NULL,
  kind text NOT NULL,              -- deliverable, checkin_reply, status, sub_expiry, review_upcoming, review_missed, review_manual, measurements
  channel text NOT NULL CHECK (channel IN ('email', 'whatsapp')),
  status text NOT NULL CHECK (status IN ('pending', 'sent', 'simulated', 'failed', 'skipped')),
  detail text,                     -- سبب الفشل أو التخطي
  occasion_key text,               -- لمنع تكرار نفس التذكير
  body text NOT NULL,              -- النص المرسل (بدون بيانات صحية)
  triggered_by text REFERENCES "user" (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX notification_once ON notification_log (order_id, occasion_key, channel) WHERE occasion_key IS NOT NULL;
CREATE INDEX ON notification_log (order_id, created_at DESC);
ALTER TABLE notification_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY notif_read ON notification_log FOR SELECT USING (app.is_coach());
GRANT SELECT ON notification_log TO nav_app;

-- يحجز الإشعار قبل إرساله (يمنع التكرار حتى مع طلبين متزامنين). يرجع NULL إذا سبق إرساله لنفس المناسبة.
CREATE OR REPLACE FUNCTION app.notify_claim(p_order uuid, p_user text, p_kind text, p_channel text, p_occasion text, p_body text)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_actor text := app.require_coach();
  v_id bigint;
BEGIN
  INSERT INTO notification_log (user_id, order_id, kind, channel, status, occasion_key, body, triggered_by)
  VALUES (p_user, p_order, p_kind, p_channel, 'pending', p_occasion, p_body, v_actor)
  ON CONFLICT (order_id, occasion_key, channel) WHERE occasion_key IS NOT NULL DO NOTHING
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION app.notify_finish(p_id bigint, p_status text, p_detail text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  PERFORM app.require_coach();
  UPDATE notification_log SET status = p_status, detail = p_detail WHERE id = p_id AND status = 'pending';
END $$;

REVOKE ALL ON FUNCTION app.coach_save_note(text, text), app.set_subscription_dates(),
  app.coach_set_subscription(text, timestamptz, timestamptz, int), app.coach_mark_week(text, int, boolean),
  app.update_intake_measurements(text, numeric, numeric),
  app.notify_claim(uuid, text, text, text, text, text), app.notify_finish(bigint, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.coach_save_note(text, text),
  app.coach_set_subscription(text, timestamptz, timestamptz, int), app.coach_mark_week(text, int, boolean),
  app.update_intake_measurements(text, numeric, numeric),
  app.notify_claim(uuid, text, text, text, text, text), app.notify_finish(bigint, text, text) TO nav_app;

-- ---------- إعدادات التنبيهات (قابلة للتعديل من لوحة الإدارة، غير عامة) ----------
INSERT INTO site_settings (key, value, is_public) VALUES ('reminders', jsonb_build_object(
  'sub_expiry_days', jsonb_build_array(7, 3),
  'sub_expiry_text', 'مرحباً {name}، اشتراكك في {product} ينتهي بتاريخ {end_date}. للتجديد أو الاستفسار تواصل معنا.',
  'review_lead_days', 1,
  'review_window_days', 2,
  'review_text', 'مرحباً {name}، تذكير بمراجعتك الأسبوعية: المراجعة مفتوحة من {window_start} إلى {window_end}.',
  'missed_review_text', 'مرحباً {name}، ما وصلتنا مراجعة الأسبوع المنتهي في {window_end}. متى ما تيسّر لك، حدّثها عشان نتابع تقدمك.',
  'manual_cooldown_minutes', 10
), false) ON CONFLICT (key) DO NOTHING;

-- ---------- جدول المراجعة للمتدرب: يكشف مدة نافذة التسليم فقط (نصوص التذكير تبقى خاصة بالمدربة) ----------
CREATE OR REPLACE FUNCTION app.review_schedule() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object(
    'review_window_days', coalesce((value->>'review_window_days')::int, 2),
    'review_lead_days', coalesce((value->>'review_lead_days')::int, 1),
    'sub_expiry_days', coalesce(value->'sub_expiry_days', '[7,3]'::jsonb))
    FROM site_settings WHERE key = 'reminders'
$$;
REVOKE ALL ON FUNCTION app.review_schedule() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.review_schedule() TO nav_app;

-- ---------- ملء تواريخ الاشتراكات الموجودة من سجل الحالات (وقت الانتقال إلى «نشط») ----------
UPDATE orders o SET
  sub_start_at = e.at,
  sub_end_at = e.at + make_interval(months => o.months),
  review_weekday = coalesce(o.review_weekday, extract(dow FROM (e.at AT TIME ZONE 'Asia/Riyadh'))::smallint)
FROM (SELECT order_id, min(created_at) AS at FROM order_events WHERE to_status = 'active' GROUP BY order_id) e
WHERE e.order_id = o.id AND o.months > 0 AND o.sub_start_at IS NULL;

INSERT INTO schema_migrations (name) VALUES ('004_followup.sql');

-- ---------- 005_questionnaire_wording.sql ----------
-- =====================================================================
-- تسمية «تقييم المتدرب» (نموذج التسجيل الأولي) أصبحت «الاستبيان» في النصوص الظاهرة فقط.
-- لا تغيير على أسماء الجداول أو الحقول (intakes = الاستبيان). تقييمات الخدمة (reviews) لا تتأثر:
-- العبارات المستبدلة محددة بسياق الاستبيان فقط.
-- =====================================================================

CREATE OR REPLACE FUNCTION app.create_order(
  p_sku text, p_idempotency_key text, p_student boolean,
  p_contact_name text, p_contact_phone text,
  p_answers jsonb, p_health jsonb, p_health_flag boolean,
  p_media_consent text, p_client_note text
) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_user text := app.require_user();
  v_offer record;
  v_order_no text;
  v_order uuid;
  v_status text;
BEGIN
  IF p_idempotency_key IS NULL OR length(p_idempotency_key) < 16 THEN
    RAISE EXCEPTION 'طلب غير صالح.' USING ERRCODE = 'P0001';
  END IF;

  SELECT order_no INTO v_order_no FROM orders WHERE user_id = v_user AND idempotency_key = p_idempotency_key;
  IF FOUND THEN RETURN v_order_no; END IF; -- نفس الطلب أُرسل مرتين

  SELECT o.id AS offer_id, o.label, o.months, o.price_halalas, o.currency,
         p.id AS product_id, p.name, p.category, p.is_demo
    INTO v_offer
    FROM product_offers o JOIN products p ON p.id = o.product_id
   WHERE o.sku = p_sku AND o.active AND p.status = 'published';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'هذا البرنامج غير متاح حالياً.' USING ERRCODE = 'P0001';
  END IF;

  v_status := CASE WHEN p_student THEN 'awaiting_quote' ELSE 'awaiting_payment' END;
  v_order_no := app.new_order_no();

  INSERT INTO orders (order_no, user_id, product_id, offer_id, category, product_name, offer_label, months,
                      list_price_halalas, amount_due_halalas, currency, student_discount_requested, status,
                      contact_name, contact_phone, client_note, idempotency_key, is_demo)
  VALUES (v_order_no, v_user, v_offer.product_id, v_offer.offer_id, v_offer.category, v_offer.name, v_offer.label,
          v_offer.months, v_offer.price_halalas,
          CASE WHEN p_student THEN NULL ELSE v_offer.price_halalas END,
          v_offer.currency, p_student, v_status,
          p_contact_name, p_contact_phone, nullif(p_client_note, ''), p_idempotency_key, v_offer.is_demo)
  RETURNING id INTO v_order;

  INSERT INTO intakes (order_id, user_id, answers, health, health_flag, media_consent, consent_terms_at, consent_whatsapp_at)
  VALUES (v_order, v_user, p_answers, coalesce(p_health, '{}'::jsonb), p_health_flag, p_media_consent, now(), now());

  INSERT INTO order_events (order_id, from_status, to_status, actor_id, actor_role, note)
  VALUES (v_order, NULL, v_status, v_user, 'client',
          CASE WHEN p_student THEN 'تم استلام الطلب والاستبيان. بانتظار تأكيد مبلغ خصم الطالب.'
               ELSE 'تم استلام الطلب والاستبيان.' END);

  UPDATE "user" SET phone = p_contact_phone,
         name = CASE WHEN name = '' OR name = split_part(email, '@', 1) THEN p_contact_name ELSE name END
   WHERE id = v_user;

  RETURN v_order_no;
END $$;

UPDATE site_settings SET value = (replace(replace(replace(replace(replace(replace(replace(replace(replace(value::text, 'عبّي التقييم', 'عبّي الاستبيان'), 'تقييم قصير', 'استبيان قصير'), 'بعد التقييم', 'بعد الاستبيان'), 'تعبئة التقييم', 'تعبئة الاستبيان'), 'ترسل التقييم', 'ترسل الاستبيان'), 'تقييم المتدرب', 'استبيان المتدرب'), 'تقييم مفصل', 'استبيان مفصل'), 'معلومات التقييم', 'معلومات الاستبيان'), 'إرسال التقييم', 'إرسال الاستبيان'))::jsonb WHERE key IN ('how_steps', 'why', 'hero', 'prices_note');
UPDATE faqs SET question = replace(replace(replace(replace(replace(replace(replace(replace(replace(question, 'عبّي التقييم', 'عبّي الاستبيان'), 'تقييم قصير', 'استبيان قصير'), 'بعد التقييم', 'بعد الاستبيان'), 'تعبئة التقييم', 'تعبئة الاستبيان'), 'ترسل التقييم', 'ترسل الاستبيان'), 'تقييم المتدرب', 'استبيان المتدرب'), 'تقييم مفصل', 'استبيان مفصل'), 'معلومات التقييم', 'معلومات الاستبيان'), 'إرسال التقييم', 'إرسال الاستبيان'), answer = replace(replace(replace(replace(replace(replace(replace(replace(replace(answer, 'عبّي التقييم', 'عبّي الاستبيان'), 'تقييم قصير', 'استبيان قصير'), 'بعد التقييم', 'بعد الاستبيان'), 'تعبئة التقييم', 'تعبئة الاستبيان'), 'ترسل التقييم', 'ترسل الاستبيان'), 'تقييم المتدرب', 'استبيان المتدرب'), 'تقييم مفصل', 'استبيان مفصل'), 'معلومات التقييم', 'معلومات الاستبيان'), 'إرسال التقييم', 'إرسال الاستبيان');
UPDATE policies SET body = replace(replace(replace(replace(replace(replace(replace(replace(replace(body, 'عبّي التقييم', 'عبّي الاستبيان'), 'تقييم قصير', 'استبيان قصير'), 'بعد التقييم', 'بعد الاستبيان'), 'تعبئة التقييم', 'تعبئة الاستبيان'), 'ترسل التقييم', 'ترسل الاستبيان'), 'تقييم المتدرب', 'استبيان المتدرب'), 'تقييم مفصل', 'استبيان مفصل'), 'معلومات التقييم', 'معلومات الاستبيان'), 'إرسال التقييم', 'إرسال الاستبيان') WHERE slug <> 'reviews';
UPDATE products SET requirements = replace(replace(replace(replace(replace(replace(replace(replace(replace(coalesce(requirements, ''), 'عبّي التقييم', 'عبّي الاستبيان'), 'تقييم قصير', 'استبيان قصير'), 'بعد التقييم', 'بعد الاستبيان'), 'تعبئة التقييم', 'تعبئة الاستبيان'), 'ترسل التقييم', 'ترسل الاستبيان'), 'تقييم المتدرب', 'استبيان المتدرب'), 'تقييم مفصل', 'استبيان مفصل'), 'معلومات التقييم', 'معلومات الاستبيان'), 'إرسال التقييم', 'إرسال الاستبيان'), delivery = replace(replace(replace(replace(replace(replace(replace(replace(replace(coalesce(delivery, ''), 'عبّي التقييم', 'عبّي الاستبيان'), 'تقييم قصير', 'استبيان قصير'), 'بعد التقييم', 'بعد الاستبيان'), 'تعبئة التقييم', 'تعبئة الاستبيان'), 'ترسل التقييم', 'ترسل الاستبيان'), 'تقييم المتدرب', 'استبيان المتدرب'), 'تقييم مفصل', 'استبيان مفصل'), 'معلومات التقييم', 'معلومات الاستبيان'), 'إرسال التقييم', 'إرسال الاستبيان');

INSERT INTO schema_migrations (name) VALUES ('005_questionnaire_wording.sql');

-- ---------- 006_manual_orders.sql ----------
-- =====================================================================
-- طلبات يدوية من المدربة: إضافة برنامج لمتدرب بدون استبيان الموقع (مثلاً اتفاق على واتساب).
-- إذا لم يكن للمتدرب حساب يُنشأ له حساب ببريده، ويدخل لاحقاً برمز البريد كالمعتاد.
-- =====================================================================

ALTER TABLE orders ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'site' CHECK (source IN ('site', 'manual'));

CREATE OR REPLACE FUNCTION app.coach_create_manual_order(
  p_email text, p_name text, p_phone text, p_sku text, p_status text, p_amount_halalas int, p_note text
) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_coach text := app.require_coach();
  v_email text := lower(trim(p_email));
  v_user "user"%ROWTYPE;
  v_offer record;
  v_order uuid;
  v_order_no text;
  v_first text;
  v_amount int;
BEGIN
  IF v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' OR length(v_email) > 200 THEN
    RAISE EXCEPTION 'اكتبي بريداً صحيحاً للمتدرب.' USING ERRCODE = 'P0001';
  END IF;
  IF length(coalesce(trim(p_name), '')) NOT BETWEEN 2 AND 80 THEN
    RAISE EXCEPTION 'اكتبي اسم المتدرب (حرفين على الأقل).' USING ERRCODE = 'P0001';
  END IF;

  SELECT o.id AS offer_id, o.label, o.months, o.price_halalas, o.currency, p.id AS product_id, p.name, p.category
    INTO v_offer
    FROM product_offers o JOIN products p ON p.id = o.product_id
   WHERE o.sku = p_sku;
  IF NOT FOUND THEN RAISE EXCEPTION 'اختاري الباقة والمدة.' USING ERRCODE = 'P0001'; END IF;

  -- الحالات المسموحة عند الإنشاء اليدوي حسب نوع المنتج
  IF NOT (p_status IN ('awaiting_payment', 'preparing')
          OR (p_status = 'active' AND v_offer.category = 'follow')
          OR (p_status = 'delivered' AND v_offer.category = 'files')) THEN
    RAISE EXCEPTION 'الحالة لا تناسب نوع هذه الباقة.' USING ERRCODE = 'P0001';
  END IF;
  v_amount := coalesce(p_amount_halalas, v_offer.price_halalas);
  IF v_amount < 0 OR v_amount > 10000000 THEN RAISE EXCEPTION 'المبلغ غير صالح.' USING ERRCODE = 'P0001'; END IF;

  SELECT * INTO v_user FROM "user" WHERE lower(email) = v_email;
  IF NOT FOUND THEN
    INSERT INTO "user" (id, name, email, "emailVerified", role, phone)
    VALUES (gen_random_uuid()::text, trim(p_name), v_email, false, 'client', nullif(trim(coalesce(p_phone, '')), ''))
    RETURNING * INTO v_user;
  ELSIF v_user.role <> 'client' THEN
    RAISE EXCEPTION 'هذا البريد لحساب إداري، وليس لمتدرب.' USING ERRCODE = 'P0001';
  END IF;

  v_first := CASE WHEN p_status = 'awaiting_payment' THEN 'awaiting_payment' ELSE 'preparing' END;
  v_order_no := app.new_order_no();
  INSERT INTO orders (order_no, user_id, product_id, offer_id, category, product_name, offer_label, months,
                      list_price_halalas, amount_due_halalas, currency, status, contact_name, contact_phone,
                      idempotency_key, paid_at, source)
  VALUES (v_order_no, v_user.id, v_offer.product_id, v_offer.offer_id, v_offer.category, v_offer.name, v_offer.label,
          v_offer.months, v_offer.price_halalas, v_amount, v_offer.currency, v_first, trim(p_name),
          coalesce(nullif(trim(coalesce(p_phone, '')), ''), v_user.phone, ''),
          'manual-' || gen_random_uuid()::text, CASE WHEN v_first = 'preparing' THEN now() END, 'manual')
  RETURNING id INTO v_order;

  INSERT INTO order_events (order_id, from_status, to_status, actor_id, actor_role, note)
  VALUES (v_order, NULL, v_first, v_coach, 'coach',
          'أضافت المدربة هذا البرنامج لحسابك.' || coalesce(' ' || nullif(trim(p_note), ''), ''));

  -- التفعيل عبر تحديث الحالة حتى يُضبط تاريخ بدء الاشتراك ونهايته تلقائياً
  IF p_status <> v_first THEN
    UPDATE orders SET status = p_status, updated_at = now() WHERE id = v_order;
    INSERT INTO order_events (order_id, from_status, to_status, actor_id, actor_role)
    VALUES (v_order, v_first, p_status, v_coach, 'coach');
  END IF;

  INSERT INTO admin_log (actor_id, action, target, details)
  VALUES (v_coach, 'order.manual_create', v_order_no,
          jsonb_build_object('email', v_email, 'sku', p_sku, 'status', p_status, 'amount', v_amount));
  RETURN v_order_no;
END $$;

REVOKE ALL ON FUNCTION app.coach_create_manual_order(text, text, text, text, text, int, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.coach_create_manual_order(text, text, text, text, text, int, text) TO nav_app;

INSERT INTO schema_migrations (name) VALUES ('006_manual_orders.sql');

-- ---------- 007_note_log.sql ----------
-- =====================================================================
-- ملاحظات المدربة كسجل: كل ملاحظة سطر مستقل بتاريخها وكاتبتها (بدل نص واحد يُستبدل).
-- خاصة بالمدربة فقط (RLS)، والإضافة والحذف عبر دوال تتحقق من الصلاحية داخل قاعدة البيانات.
-- الملاحظة القديمة (order_admin_notes) تُنقل كأول سطر في السجل، ويبقى جدولها كما هو بدون استخدام.
-- =====================================================================

CREATE TABLE IF NOT EXISTS order_note_entries (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  order_id uuid NOT NULL REFERENCES orders (id) ON DELETE CASCADE,
  body text NOT NULL CHECK (length(body) BETWEEN 1 AND 5000),
  created_by text REFERENCES "user" (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS order_note_entries_order_idx ON order_note_entries (order_id, created_at DESC);
ALTER TABLE order_note_entries ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS note_entries_read ON order_note_entries;
CREATE POLICY note_entries_read ON order_note_entries FOR SELECT USING (app.is_coach());
GRANT SELECT ON order_note_entries TO nav_app;

INSERT INTO order_note_entries (order_id, body, created_by, created_at)
SELECT n.order_id, n.body, n.updated_by, n.updated_at FROM order_admin_notes n
 WHERE trim(n.body) <> ''
   AND NOT EXISTS (SELECT 1 FROM order_note_entries e WHERE e.order_id = n.order_id);

CREATE OR REPLACE FUNCTION app.coach_add_note(p_order_no text, p_body text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_coach text := app.require_coach();
  v_order uuid;
BEGIN
  SELECT id INTO v_order FROM orders WHERE order_no = p_order_no;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  IF coalesce(trim(p_body), '') = '' THEN RAISE EXCEPTION 'اكتبي الملاحظة أولاً.' USING ERRCODE = 'P0001'; END IF;
  IF length(p_body) > 5000 THEN RAISE EXCEPTION 'الملاحظة أطول من 5000 حرف.' USING ERRCODE = 'P0001'; END IF;
  INSERT INTO order_note_entries (order_id, body, created_by) VALUES (v_order, trim(p_body), v_coach);
END $$;

CREATE OR REPLACE FUNCTION app.coach_delete_note(p_id bigint) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_coach text := app.require_coach();
  v_row order_note_entries%ROWTYPE;
BEGIN
  DELETE FROM order_note_entries WHERE id = p_id RETURNING * INTO v_row;
  IF NOT FOUND THEN RAISE EXCEPTION 'الملاحظة غير موجودة.' USING ERRCODE = 'P0001'; END IF;
  INSERT INTO admin_log (actor_id, action, target, details)
  VALUES (v_coach, 'note.delete', v_row.order_id::text, jsonb_build_object('created_at', v_row.created_at));
END $$;

REVOKE ALL ON FUNCTION app.coach_add_note(text, text), app.coach_delete_note(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.coach_add_note(text, text), app.coach_delete_note(bigint) TO nav_app;

INSERT INTO schema_migrations (name) VALUES ('007_note_log.sql');

-- ---------- 008_free_plans.sql ----------
-- =====================================================================
-- الجداول المجانية: جدول PDF يطلبه المستخدم المسجّل مجاناً ويحمّله من حسابه.
-- منفصلة تماماً عن طلبات الباقات المدفوعة (orders).
-- - ملف PDF في التخزين الخاص؛ مفتاحه لا يُقرأ من التطبيق مباشرة (صلاحيات أعمدة)،
--   ولا يُسلَّم إلا عبر app.free_plan_file() بعد التحقق من أن الطلب يخص المستخدم نفسه.
-- - الإضافة والتعديل للمدربة فقط عبر app.coach_save_free_plan().
-- =====================================================================

ALTER TABLE media_assets DROP CONSTRAINT IF EXISTS media_assets_usage_check;
ALTER TABLE media_assets ADD CONSTRAINT media_assets_usage_check
  CHECK (usage IN ('hero', 'about', 'gallery', 'product', 'free_plan'));

CREATE TABLE free_plans (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug text NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' AND length(slug) <= 60),
  title text NOT NULL CHECK (length(title) BETWEEN 3 AND 120),
  summary text NOT NULL CHECK (length(summary) BETWEEN 10 AND 600),
  audience text CHECK (audience IS NULL OR length(audience) <= 120),
  image_id uuid REFERENCES media_assets (id) ON DELETE SET NULL,
  file_key text,
  file_mime text,
  file_size int,
  file_sha256 text,
  file_updated_at timestamptz,
  status text NOT NULL DEFAULT 'hidden' CHECK (status IN ('published', 'hidden')),
  sort int NOT NULL DEFAULT 0,
  created_by text REFERENCES "user" (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  -- لا يُنشر جدول بدون ملف
  CONSTRAINT free_plans_published_has_file CHECK (status <> 'published' OR file_key IS NOT NULL)
);

CREATE TABLE free_plan_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id uuid NOT NULL REFERENCES free_plans (id) ON DELETE CASCADE,
  user_id text NOT NULL REFERENCES "user" (id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (plan_id, user_id)
);
CREATE INDEX free_plan_requests_user_idx ON free_plan_requests (user_id, created_at DESC);

ALTER TABLE free_plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE free_plan_requests ENABLE ROW LEVEL SECURITY;
-- الزائر يرى المنشور فقط؛ المدربة ترى الكل
CREATE POLICY free_plans_read ON free_plans FOR SELECT USING (status = 'published' OR app.is_coach());
-- كل مستخدم يرى طلباته فقط؛ المدربة ترى الكل (للإحصاءات)
CREATE POLICY free_plan_requests_read ON free_plan_requests FOR SELECT USING (user_id = app.uid() OR app.is_coach());

-- صلاحيات أعمدة: مفتاح الملف وبصمته غير قابلة للقراءة من التطبيق، ولا كتابة مباشرة على الجدولين
GRANT SELECT (id, slug, title, summary, audience, image_id, file_mime, file_size, file_updated_at, status, sort, created_at, updated_at)
  ON free_plans TO nav_app;
GRANT SELECT ON free_plan_requests TO nav_app;

-- ---------- طلب جدول مجاني (مستخدم مسجّل، جدول منشور، بدون تكرار) ----------
CREATE OR REPLACE FUNCTION app.request_free_plan(p_slug text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_user text := app.require_user();
  v_plan uuid;
  v_req uuid;
BEGIN
  SELECT id INTO v_plan FROM free_plans WHERE slug = p_slug AND status = 'published';
  IF NOT FOUND THEN RAISE EXCEPTION 'هذا الجدول غير متاح حالياً.' USING ERRCODE = 'P0001'; END IF;
  INSERT INTO free_plan_requests (plan_id, user_id) VALUES (v_plan, v_user)
  ON CONFLICT (plan_id, user_id) DO NOTHING RETURNING id INTO v_req;
  IF v_req IS NOT NULL THEN
    RETURN jsonb_build_object('request_id', v_req, 'created', true);
  END IF;
  SELECT id INTO v_req FROM free_plan_requests WHERE plan_id = v_plan AND user_id = v_user;
  RETURN jsonb_build_object('request_id', v_req, 'created', false);
END $$;

-- ---------- جداولي: تبقى ظاهرة لصاحبها حتى لو أُخفي الجدول لاحقاً من الصفحة العامة ----------
CREATE OR REPLACE FUNCTION app.my_free_plans()
RETURNS TABLE (request_id uuid, requested_at timestamptz, slug text, title text, summary text, has_file boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT r.id, r.created_at, p.slug, p.title, p.summary, p.file_key IS NOT NULL
    FROM free_plan_requests r JOIN free_plans p ON p.id = r.plan_id
   WHERE r.user_id = app.uid()
   ORDER BY r.created_at DESC
$$;

-- ---------- ملف التنزيل: فقط لصاحب الطلب ----------
CREATE OR REPLACE FUNCTION app.free_plan_file(p_request uuid)
RETURNS TABLE (file_key text, file_mime text, slug text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT p.file_key, p.file_mime, p.slug
    FROM free_plan_requests r JOIN free_plans p ON p.id = r.plan_id
   WHERE r.id = p_request AND r.user_id = app.uid() AND app.uid() IS NOT NULL
$$;

-- ---------- إضافة/تعديل جدول (المدربة فقط). يرجع المعرّف ومفتاح الملف القديم لحذفه من التخزين ----------
CREATE OR REPLACE FUNCTION app.coach_save_free_plan(
  p_id uuid, p_slug text, p_title text, p_summary text, p_audience text, p_image uuid, p_status text, p_sort int,
  p_file_key text, p_file_mime text, p_file_size int, p_file_sha256 text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_coach text := app.require_coach();
  v_old free_plans%ROWTYPE;
  v_id uuid;
BEGIN
  IF p_file_key IS NOT NULL AND (p_file_mime IS DISTINCT FROM 'application/pdf' OR p_file_size IS NULL OR p_file_size <= 0) THEN
    RAISE EXCEPTION 'الملف يجب أن يكون PDF.' USING ERRCODE = 'P0001';
  END IF;
  IF p_id IS NULL THEN
    IF p_status = 'published' AND p_file_key IS NULL THEN
      RAISE EXCEPTION 'ارفعي ملف PDF قبل نشر الجدول.' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO free_plans (slug, title, summary, audience, image_id, status, sort, file_key, file_mime, file_size, file_sha256, file_updated_at, created_by)
    VALUES (p_slug, p_title, p_summary, nullif(trim(coalesce(p_audience, '')), ''), p_image, p_status, coalesce(p_sort, 0),
            p_file_key, p_file_mime, p_file_size, p_file_sha256, CASE WHEN p_file_key IS NOT NULL THEN now() END, v_coach)
    RETURNING id INTO v_id;
    INSERT INTO admin_log (actor_id, action, target, details) VALUES (v_coach, 'free_plan.create', p_slug, jsonb_build_object('status', p_status));
    RETURN jsonb_build_object('id', v_id, 'old_file_key', NULL);
  END IF;

  SELECT * INTO v_old FROM free_plans WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الجدول غير موجود.' USING ERRCODE = 'P0001'; END IF;
  IF p_status = 'published' AND p_file_key IS NULL AND v_old.file_key IS NULL THEN
    RAISE EXCEPTION 'ارفعي ملف PDF قبل نشر الجدول.' USING ERRCODE = 'P0001';
  END IF;
  UPDATE free_plans SET
    slug = p_slug, title = p_title, summary = p_summary, audience = nullif(trim(coalesce(p_audience, '')), ''),
    image_id = p_image, status = p_status, sort = coalesce(p_sort, 0), updated_at = now(),
    file_key = coalesce(p_file_key, file_key), file_mime = coalesce(p_file_mime, file_mime),
    file_size = coalesce(p_file_size, file_size), file_sha256 = coalesce(p_file_sha256, file_sha256),
    file_updated_at = CASE WHEN p_file_key IS NOT NULL THEN now() ELSE file_updated_at END
  WHERE id = p_id;
  INSERT INTO admin_log (actor_id, action, target, details)
  VALUES (v_coach, 'free_plan.update', p_slug, jsonb_build_object('status', p_status, 'file_replaced', p_file_key IS NOT NULL));
  RETURN jsonb_build_object('id', p_id, 'old_file_key', CASE WHEN p_file_key IS NOT NULL THEN v_old.file_key END);
END $$;

REVOKE ALL ON FUNCTION app.request_free_plan(text), app.my_free_plans(), app.free_plan_file(uuid),
  app.coach_save_free_plan(uuid, text, text, text, text, uuid, text, int, text, text, int, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.request_free_plan(text), app.my_free_plans(), app.free_plan_file(uuid),
  app.coach_save_free_plan(uuid, text, text, text, text, uuid, text, int, text, text, int, text) TO nav_app;

INSERT INTO schema_migrations (name) VALUES ('008_free_plans.sql');

-- ---------- 009_training.sql ----------
-- =====================================================================
-- منصة التدريب (بديل ملف Google Sheets): مكتبة التمارين، القوالب، بلوك المتدرب، السجلات، التقدم.
-- * المكتبة والقوالب ملك المدربة: قراءة وكتابة للمدربة فقط.
-- * البلوك نسخة من قالب مرتبطة بطلب المتدرب؛ يراه صاحب الطلب بعد تأكيد الدفع فقط (app.order_entitled).
-- * المتدرب لا يكتب مباشرة على أي جدول: التسجيل والتبديل عبر دوال تتحقق من الملكية والحالة ورقم الأسبوع.
-- * من المكتبة يرى المتدرب فقط الاسم والعضلات والفيديو والتعليمات لتمارين برنامجه وبدائلها (عبر دوال)، لا الملاحظات والمصادر.
-- =====================================================================

-- ---------- مكتبة التمارين ----------
CREATE TABLE exercises (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (length(trim(name)) BETWEEN 2 AND 120),
  primary_muscle text NOT NULL CHECK (length(primary_muscle) BETWEEN 2 AND 80),
  secondary_muscles text[] NOT NULL DEFAULT '{}',
  pattern text CHECK (pattern IS NULL OR length(pattern) <= 120),
  kind text CHECK (kind IS NULL OR length(kind) <= 40),          -- نوع التمرين: قوة، كور، مرونة...
  equipment text CHECK (equipment IS NULL OR length(equipment) <= 40),
  level text CHECK (level IS NULL OR level IN ('مبتدئ', 'متوسط', 'متقدم')),
  place text CHECK (place IS NULL OR place IN ('نادي', 'منزل', 'بدون معدات')),
  video_url text CHECK (video_url IS NULL OR video_url ~ '^https://'),
  instructions text CHECK (instructions IS NULL OR length(instructions) <= 4000),
  notes text CHECK (notes IS NULL OR length(notes) <= 4000),       -- ملاحظات المدربة (لا تظهر للمتدرب)
  source text CHECK (source IS NULL OR length(source) <= 120),
  source_name text CHECK (source_name IS NULL OR length(source_name) <= 200),
  source_url text CHECK (source_url IS NULL OR source_url ~ '^https?://'),
  rehab_category text CHECK (rehab_category IS NULL OR length(rehab_category) <= 500),
  status text NOT NULL DEFAULT 'review' CHECK (status IN ('approved', 'review', 'rejected')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX exercises_name_key ON exercises (lower(trim(name)));
CREATE INDEX exercises_muscle_idx ON exercises (primary_muscle, status);

-- بدائل التمرين (مرتبة كما في عمود «بدائل التمرين» في الشيت)
CREATE TABLE exercise_alternatives (
  exercise_id uuid NOT NULL REFERENCES exercises (id) ON DELETE CASCADE,
  alt_id uuid NOT NULL REFERENCES exercises (id) ON DELETE CASCADE,
  position int NOT NULL DEFAULT 0,
  PRIMARY KEY (exercise_id, alt_id),
  CHECK (exercise_id <> alt_id)
);

-- ---------- القوالب ----------
-- plan لكل تمرين: مصفوفة بطول عدد الأسابيع، كل عنصر {"sets": 3, "reps": [12,12,12], "rir": 3}
CREATE TABLE program_templates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (length(trim(name)) BETWEEN 2 AND 120),
  weeks int NOT NULL DEFAULT 5 CHECK (weeks BETWEEN 1 AND 12),
  instructions text CHECK (instructions IS NULL OR length(instructions) <= 4000),
  archived boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE template_days (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  template_id uuid NOT NULL REFERENCES program_templates (id) ON DELETE CASCADE,
  day_no int NOT NULL CHECK (day_no BETWEEN 1 AND 14),
  title text NOT NULL CHECK (length(trim(title)) BETWEEN 1 AND 80),
  UNIQUE (template_id, day_no)
);
CREATE TABLE template_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  day_id uuid NOT NULL REFERENCES template_days (id) ON DELETE CASCADE,
  position int NOT NULL DEFAULT 0,
  exercise_id uuid NOT NULL REFERENCES exercises (id) ON DELETE RESTRICT,
  plan jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(plan) = 'array'),
  note text CHECK (note IS NULL OR length(note) <= 500)
);
CREATE INDEX template_items_day_idx ON template_items (day_id, position);

-- ---------- بلوك المتدرب ----------
CREATE TABLE blocks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES orders (id) ON DELETE CASCADE,
  user_id text NOT NULL REFERENCES "user" (id) ON DELETE CASCADE,
  template_id uuid REFERENCES program_templates (id) ON DELETE SET NULL,
  name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 120),
  start_date date NOT NULL,
  weeks int NOT NULL CHECK (weeks BETWEEN 1 AND 12),
  instructions text CHECK (instructions IS NULL OR length(instructions) <= 4000),
  steps_goal_week int NOT NULL DEFAULT 56000 CHECK (steps_goal_week BETWEEN 0 AND 300000),
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'archived')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX blocks_one_active ON blocks (order_id) WHERE status = 'active';
CREATE INDEX blocks_user_idx ON blocks (user_id, created_at DESC);
CREATE TABLE block_days (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  block_id uuid NOT NULL REFERENCES blocks (id) ON DELETE CASCADE,
  day_no int NOT NULL CHECK (day_no BETWEEN 1 AND 14),
  title text NOT NULL CHECK (length(trim(title)) BETWEEN 1 AND 80),
  UNIQUE (block_id, day_no)
);
CREATE TABLE block_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  day_id uuid NOT NULL REFERENCES block_days (id) ON DELETE CASCADE,
  position int NOT NULL DEFAULT 0,
  exercise_id uuid NOT NULL REFERENCES exercises (id) ON DELETE RESTRICT,
  -- اختيار المدربة الأصلي؛ بدائل التبديل تُحسب منه حتى لا ينجرف التبديل بعيداً عن خطة المدربة
  coach_exercise_id uuid NOT NULL REFERENCES exercises (id) ON DELETE RESTRICT,
  plan jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(plan) = 'array'),
  note text CHECK (note IS NULL OR length(note) <= 500)
);
CREATE INDEX block_items_day_idx ON block_items (day_id, position);

-- ملاحظات المدربة للمتدرب (للبلوك كله أو لأسبوع محدد) — تظهر للمتدرب
CREATE TABLE block_notes (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  block_id uuid NOT NULL REFERENCES blocks (id) ON DELETE CASCADE,
  week_no int CHECK (week_no IS NULL OR week_no BETWEEN 1 AND 12),
  body text NOT NULL CHECK (length(body) BETWEEN 1 AND 3000),
  created_by text REFERENCES "user" (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX block_notes_block_idx ON block_notes (block_id, created_at DESC);

-- ---------- سجلات المتدرب ----------
CREATE TABLE item_logs (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  block_item_id uuid NOT NULL REFERENCES block_items (id) ON DELETE CASCADE,
  week_no int NOT NULL CHECK (week_no BETWEEN 1 AND 12),
  exercise_id uuid NOT NULL REFERENCES exercises (id) ON DELETE RESTRICT, -- التمرين وقت التسجيل (للأرقام القياسية بعد التبديل)
  weight numeric(6,2) NOT NULL CHECK (weight >= 0 AND weight <= 1000),
  reps int[] NOT NULL DEFAULT '{}',
  rir numeric(3,1) CHECK (rir IS NULL OR rir BETWEEN 0 AND 10),
  logged_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (block_item_id, week_no)
);
CREATE TABLE day_ratings (
  block_day_id uuid NOT NULL REFERENCES block_days (id) ON DELETE CASCADE,
  week_no int NOT NULL CHECK (week_no BETWEEN 1 AND 12),
  rating smallint NOT NULL CHECK (rating BETWEEN 1 AND 5),
  rated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (block_day_id, week_no)
);
CREATE TABLE weight_logs (
  user_id text NOT NULL REFERENCES "user" (id) ON DELETE CASCADE,
  logged_on date NOT NULL,
  kg numeric(5,2) NOT NULL CHECK (kg BETWEEN 25 AND 350),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, logged_on)
);
CREATE TABLE body_measurements (
  user_id text NOT NULL REFERENCES "user" (id) ON DELETE CASCADE,
  measured_on date NOT NULL,
  chest numeric(5,1) CHECK (chest IS NULL OR chest BETWEEN 30 AND 250),
  waist numeric(5,1) CHECK (waist IS NULL OR waist BETWEEN 30 AND 250),
  hips numeric(5,1) CHECK (hips IS NULL OR hips BETWEEN 30 AND 250),
  thigh numeric(5,1) CHECK (thigh IS NULL OR thigh BETWEEN 20 AND 150),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, measured_on),
  CHECK (coalesce(chest, waist, hips, thigh) IS NOT NULL)
);
CREATE TABLE step_logs (
  block_id uuid NOT NULL REFERENCES blocks (id) ON DELETE CASCADE,
  week_no int NOT NULL CHECK (week_no BETWEEN 1 AND 12),
  total int NOT NULL CHECK (total BETWEEN 0 AND 500000),
  logged_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (block_id, week_no)
);

-- تبديل المتدرب لتمرين ببديله: سجل دائم + إشعار للمدربة حتى تطّلع عليه (seen_at)
CREATE TABLE exercise_swaps (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  block_item_id uuid NOT NULL REFERENCES block_items (id) ON DELETE CASCADE,
  block_id uuid NOT NULL REFERENCES blocks (id) ON DELETE CASCADE,
  user_id text NOT NULL REFERENCES "user" (id) ON DELETE CASCADE,
  from_exercise_id uuid NOT NULL REFERENCES exercises (id) ON DELETE RESTRICT,
  to_exercise_id uuid NOT NULL REFERENCES exercises (id) ON DELETE RESTRICT,
  week_no int,
  created_at timestamptz NOT NULL DEFAULT now(),
  seen_at timestamptz
);
CREATE INDEX exercise_swaps_unseen_idx ON exercise_swaps (user_id, created_at DESC) WHERE seen_at IS NULL;
CREATE INDEX exercise_swaps_block_idx ON exercise_swaps (block_id, created_at DESC);

-- ---------- صلاحيات ----------
-- هل يحق للمستخدم الحالي رؤية هذا البلوك؟ (المدربة، أو صاحب طلب مدفوع)
CREATE OR REPLACE FUNCTION app.block_visible(p_block uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT app.is_coach() OR EXISTS (SELECT 1 FROM blocks b WHERE b.id = p_block AND app.order_entitled(b.order_id))
$$;
CREATE OR REPLACE FUNCTION app.day_block(p_day uuid) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$ SELECT block_id FROM block_days WHERE id = p_day $$;
CREATE OR REPLACE FUNCTION app.item_block(p_item uuid) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT d.block_id FROM block_items i JOIN block_days d ON d.id = i.day_id WHERE i.id = p_item
$$;

ALTER TABLE exercises ENABLE ROW LEVEL SECURITY;
ALTER TABLE exercise_alternatives ENABLE ROW LEVEL SECURITY;
ALTER TABLE program_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE template_days ENABLE ROW LEVEL SECURITY;
ALTER TABLE template_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE blocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE block_days ENABLE ROW LEVEL SECURITY;
ALTER TABLE block_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE block_notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE item_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE day_ratings ENABLE ROW LEVEL SECURITY;
ALTER TABLE weight_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE body_measurements ENABLE ROW LEVEL SECURITY;
ALTER TABLE step_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE exercise_swaps ENABLE ROW LEVEL SECURITY;

-- المكتبة والقوالب: المدربة فقط
CREATE POLICY exercises_coach ON exercises FOR ALL USING (app.is_coach()) WITH CHECK (app.is_coach());
CREATE POLICY exercise_alts_coach ON exercise_alternatives FOR ALL USING (app.is_coach()) WITH CHECK (app.is_coach());
CREATE POLICY templates_coach ON program_templates FOR ALL USING (app.is_coach()) WITH CHECK (app.is_coach());
CREATE POLICY template_days_coach ON template_days FOR ALL USING (app.is_coach()) WITH CHECK (app.is_coach());
CREATE POLICY template_items_coach ON template_items FOR ALL USING (app.is_coach()) WITH CHECK (app.is_coach());

-- البلوك: قراءة للمدربة وصاحب الطلب المدفوع؛ الكتابة المباشرة للمدربة فقط
CREATE POLICY blocks_read ON blocks FOR SELECT USING (app.block_visible(id));
CREATE POLICY blocks_write ON blocks FOR ALL USING (app.is_coach()) WITH CHECK (app.is_coach());
CREATE POLICY block_days_read ON block_days FOR SELECT USING (app.block_visible(block_id));
CREATE POLICY block_days_write ON block_days FOR ALL USING (app.is_coach()) WITH CHECK (app.is_coach());
CREATE POLICY block_items_read ON block_items FOR SELECT USING (app.block_visible(app.day_block(day_id)));
CREATE POLICY block_items_write ON block_items FOR ALL USING (app.is_coach()) WITH CHECK (app.is_coach());
CREATE POLICY block_notes_read ON block_notes FOR SELECT USING (app.block_visible(block_id));
CREATE POLICY block_notes_write ON block_notes FOR ALL USING (app.is_coach()) WITH CHECK (app.is_coach());

-- السجلات: قراءة فقط (الكتابة عبر الدوال)
CREATE POLICY item_logs_read ON item_logs FOR SELECT USING (app.block_visible(app.item_block(block_item_id)));
CREATE POLICY day_ratings_read ON day_ratings FOR SELECT USING (app.block_visible(app.day_block(block_day_id)));
CREATE POLICY step_logs_read ON step_logs FOR SELECT USING (app.block_visible(block_id));
CREATE POLICY weight_logs_read ON weight_logs FOR SELECT USING (user_id = app.uid() OR app.is_coach());
CREATE POLICY measurements_read ON body_measurements FOR SELECT USING (user_id = app.uid() OR app.is_coach());
CREATE POLICY swaps_read ON exercise_swaps FOR SELECT USING (user_id = app.uid() OR app.is_coach());

GRANT SELECT, INSERT, UPDATE, DELETE ON exercises, exercise_alternatives, program_templates, template_days, template_items,
  blocks, block_days, block_items, block_notes TO nav_app;
GRANT SELECT ON item_logs, day_ratings, weight_logs, body_measurements, step_logs, exercise_swaps TO nav_app;

-- ---------- دوال مساعدة داخلية ----------
-- البلوك الذي يملكه المتدرب الحالي وهو نشط، أو خطأ واضح
CREATE OR REPLACE FUNCTION app.my_active_block(p_block uuid) RETURNS blocks
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v blocks%ROWTYPE;
BEGIN
  PERFORM app.require_user();
  SELECT * INTO v FROM blocks WHERE id = p_block;
  IF NOT FOUND OR v.user_id <> app.uid() OR NOT app.order_entitled(v.order_id) THEN
    RAISE EXCEPTION 'البرنامج غير موجود.' USING ERRCODE = 'P0001';
  END IF;
  IF v.status <> 'active' THEN RAISE EXCEPTION 'هذا البرنامج منتهي ولا يقبل تعديلات.' USING ERRCODE = 'P0001'; END IF;
  RETURN v;
END $$;

CREATE OR REPLACE FUNCTION app.check_week(p_block blocks, p_week int) RETURNS void
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF p_week IS NULL OR p_week < 1 OR p_week > p_block.weeks THEN
    RAISE EXCEPTION 'رقم الأسبوع غير صحيح.' USING ERRCODE = 'P0001';
  END IF;
END $$;

-- ---------- قراءة المتدرب: تمارين برنامجه (أعمدة محدودة) ----------
CREATE OR REPLACE FUNCTION app.block_exercises(p_block uuid)
RETURNS TABLE (id uuid, name text, primary_muscle text, secondary_muscles text[], video_url text, instructions text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT e.id, e.name, e.primary_muscle, e.secondary_muscles, e.video_url, e.instructions
    FROM exercises e
   WHERE app.block_visible(p_block)
     AND e.id IN (
       SELECT i.exercise_id FROM block_items i JOIN block_days d ON d.id = i.day_id WHERE d.block_id = p_block
       UNION SELECT i.coach_exercise_id FROM block_items i JOIN block_days d ON d.id = i.day_id WHERE d.block_id = p_block
       UNION SELECT l.exercise_id FROM item_logs l JOIN block_items i ON i.id = l.block_item_id JOIN block_days d ON d.id = i.day_id WHERE d.block_id = p_block)
$$;

-- خيارات التبديل لتمرين في البلوك: تمرين المدربة الأصلي + بدائله المعتمدة (بالترتيب).
-- إن لم تُحدَّد بدائل: التمارين المعتمدة بنفس العضلة الأساسية ونفس تصنيف الحركة.
CREATE OR REPLACE FUNCTION app.swap_options(p_item uuid)
RETURNS TABLE (id uuid, name text, video_url text, is_coach_choice boolean, is_current boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_item block_items%ROWTYPE;
  v_base exercises%ROWTYPE;
BEGIN
  SELECT * INTO v_item FROM block_items WHERE block_items.id = p_item;
  IF NOT FOUND OR NOT app.block_visible(app.item_block(p_item)) THEN RETURN; END IF;
  SELECT * INTO v_base FROM exercises WHERE exercises.id = v_item.coach_exercise_id;
  IF EXISTS (SELECT 1 FROM exercise_alternatives a WHERE a.exercise_id = v_base.id) THEN
    RETURN QUERY
      SELECT v_base.id, v_base.name, v_base.video_url, true, v_base.id = v_item.exercise_id
      UNION ALL
      SELECT e.id, e.name, e.video_url, false, e.id = v_item.exercise_id
        FROM (SELECT a.alt_id, a.position FROM exercise_alternatives a WHERE a.exercise_id = v_base.id ORDER BY a.position) x
        JOIN exercises e ON e.id = x.alt_id AND e.status = 'approved';
  ELSE
    RETURN QUERY
      SELECT v_base.id, v_base.name, v_base.video_url, true, v_base.id = v_item.exercise_id
      UNION ALL
      (SELECT e.id, e.name, e.video_url, false, e.id = v_item.exercise_id
         FROM exercises e
        WHERE e.status = 'approved' AND e.id <> v_base.id AND e.primary_muscle = v_base.primary_muscle
          AND e.pattern IS NOT DISTINCT FROM v_base.pattern
        ORDER BY e.name LIMIT 8);
  END IF;
END $$;

-- ---------- كتابة المتدرب ----------
-- تبديل تمرين ببديله: يسري على بقية البلوك، والسجلات السابقة تبقى باسم التمرين الذي سُجّلت عليه
CREATE OR REPLACE FUNCTION app.swap_exercise(p_item uuid, p_exercise uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_item block_items%ROWTYPE;
  v_block blocks%ROWTYPE;
  v_week int;
BEGIN
  SELECT * INTO v_item FROM block_items WHERE id = p_item FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'التمرين غير موجود.' USING ERRCODE = 'P0001'; END IF;
  v_block := app.my_active_block(app.item_block(p_item));
  IF v_item.exercise_id = p_exercise THEN RETURN jsonb_build_object('changed', false); END IF;
  IF NOT EXISTS (SELECT 1 FROM app.swap_options(p_item) o WHERE o.id = p_exercise) THEN
    RAISE EXCEPTION 'هذا التمرين ليس من البدائل المتاحة.' USING ERRCODE = 'P0001';
  END IF;
  IF NOT app.rate_limit('swap:' || app.uid(), 30, 3600) THEN
    RAISE EXCEPTION 'محاولات كثيرة، حاول بعد قليل.' USING ERRCODE = 'P0001';
  END IF;
  v_week := greatest(1, least(v_block.weeks, ((now() AT TIME ZONE 'Asia/Riyadh')::date - v_block.start_date) / 7 + 1));
  UPDATE block_items SET exercise_id = p_exercise WHERE id = p_item;
  INSERT INTO exercise_swaps (block_item_id, block_id, user_id, from_exercise_id, to_exercise_id, week_no)
  VALUES (p_item, v_block.id, v_block.user_id, v_item.exercise_id, p_exercise, v_week);
  RETURN jsonb_build_object('changed', true,
    'from', (SELECT name FROM exercises WHERE id = v_item.exercise_id),
    'to', (SELECT name FROM exercises WHERE id = p_exercise));
END $$;

-- تسجيل أداء تمرين لأسبوع (الوزن فارغ = حذف التسجيل)
CREATE OR REPLACE FUNCTION app.log_item(p_item uuid, p_week int, p_weight numeric, p_reps int[], p_rir numeric) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_block blocks%ROWTYPE;
  v_ex uuid;
BEGIN
  SELECT exercise_id INTO v_ex FROM block_items WHERE id = p_item;
  IF NOT FOUND THEN RAISE EXCEPTION 'التمرين غير موجود.' USING ERRCODE = 'P0001'; END IF;
  v_block := app.my_active_block(app.item_block(p_item));
  PERFORM app.check_week(v_block, p_week);
  IF p_weight IS NULL THEN
    DELETE FROM item_logs WHERE block_item_id = p_item AND week_no = p_week;
    RETURN;
  END IF;
  IF p_weight < 0 OR p_weight > 1000 THEN RAISE EXCEPTION 'الوزن غير منطقي.' USING ERRCODE = 'P0001'; END IF;
  IF p_reps IS NOT NULL AND (cardinality(p_reps) > 10 OR EXISTS (SELECT 1 FROM unnest(p_reps) r WHERE r IS NULL OR r < 0 OR r > 200)) THEN
    RAISE EXCEPTION 'التكرارات غير صحيحة.' USING ERRCODE = 'P0001';
  END IF;
  IF p_rir IS NOT NULL AND (p_rir < 0 OR p_rir > 10) THEN RAISE EXCEPTION 'RIR بين 0 و 10.' USING ERRCODE = 'P0001'; END IF;
  INSERT INTO item_logs (block_item_id, week_no, exercise_id, weight, reps, rir)
  VALUES (p_item, p_week, v_ex, p_weight, coalesce(p_reps, '{}'), p_rir)
  ON CONFLICT (block_item_id, week_no) DO UPDATE
    SET weight = EXCLUDED.weight, reps = EXCLUDED.reps, rir = EXCLUDED.rir, exercise_id = EXCLUDED.exercise_id, logged_at = now();
END $$;

CREATE OR REPLACE FUNCTION app.rate_day(p_day uuid, p_week int, p_rating int) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_block blocks%ROWTYPE;
BEGIN
  IF app.day_block(p_day) IS NULL THEN RAISE EXCEPTION 'اليوم غير موجود.' USING ERRCODE = 'P0001'; END IF;
  v_block := app.my_active_block(app.day_block(p_day));
  PERFORM app.check_week(v_block, p_week);
  IF p_rating IS NULL OR p_rating NOT BETWEEN 1 AND 5 THEN RAISE EXCEPTION 'التقييم من 1 إلى 5.' USING ERRCODE = 'P0001'; END IF;
  INSERT INTO day_ratings (block_day_id, week_no, rating) VALUES (p_day, p_week, p_rating)
  ON CONFLICT (block_day_id, week_no) DO UPDATE SET rating = EXCLUDED.rating, rated_at = now();
END $$;

CREATE OR REPLACE FUNCTION app.log_steps(p_block uuid, p_week int, p_total int) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_block blocks%ROWTYPE := app.my_active_block(p_block);
BEGIN
  PERFORM app.check_week(v_block, p_week);
  IF p_total IS NULL THEN DELETE FROM step_logs WHERE block_id = p_block AND week_no = p_week; RETURN; END IF;
  IF p_total < 0 OR p_total > 500000 THEN RAISE EXCEPTION 'عدد الخطوات غير منطقي.' USING ERRCODE = 'P0001'; END IF;
  INSERT INTO step_logs (block_id, week_no, total) VALUES (p_block, p_week, p_total)
  ON CONFLICT (block_id, week_no) DO UPDATE SET total = EXCLUDED.total, logged_at = now();
END $$;

-- الوزن والقياسات مرتبطة بالمتدرب (تستمر عبر البلوكات والتجديد)، وتتطلب برنامجاً نشطاً
CREATE OR REPLACE FUNCTION app.require_training() RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE u text := app.require_user();
BEGIN
  IF NOT EXISTS (SELECT 1 FROM blocks b WHERE b.user_id = u AND b.status = 'active' AND app.order_entitled(b.order_id)) THEN
    RAISE EXCEPTION 'لا يوجد برنامج نشط.' USING ERRCODE = 'P0001';
  END IF;
  RETURN u;
END $$;

CREATE OR REPLACE FUNCTION app.log_weight(p_date date, p_kg numeric) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  u text := app.require_training();
  today date := (now() AT TIME ZONE 'Asia/Riyadh')::date;
BEGIN
  IF p_date IS NULL OR p_date > today OR p_date < today - 400 THEN RAISE EXCEPTION 'التاريخ غير صحيح.' USING ERRCODE = 'P0001'; END IF;
  IF p_kg IS NULL THEN DELETE FROM weight_logs WHERE user_id = u AND logged_on = p_date; RETURN; END IF;
  IF p_kg < 25 OR p_kg > 350 THEN RAISE EXCEPTION 'الوزن غير منطقي.' USING ERRCODE = 'P0001'; END IF;
  INSERT INTO weight_logs (user_id, logged_on, kg) VALUES (u, p_date, p_kg)
  ON CONFLICT (user_id, logged_on) DO UPDATE SET kg = EXCLUDED.kg, created_at = now();
END $$;

CREATE OR REPLACE FUNCTION app.log_measurements(p_date date, p_chest numeric, p_waist numeric, p_hips numeric, p_thigh numeric) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  u text := app.require_training();
  today date := (now() AT TIME ZONE 'Asia/Riyadh')::date;
BEGIN
  IF p_date IS NULL OR p_date > today OR p_date < today - 400 THEN RAISE EXCEPTION 'التاريخ غير صحيح.' USING ERRCODE = 'P0001'; END IF;
  IF coalesce(p_chest, p_waist, p_hips, p_thigh) IS NULL THEN
    DELETE FROM body_measurements WHERE user_id = u AND measured_on = p_date; RETURN;
  END IF;
  INSERT INTO body_measurements (user_id, measured_on, chest, waist, hips, thigh) VALUES (u, p_date, p_chest, p_waist, p_hips, p_thigh)
  ON CONFLICT (user_id, measured_on) DO UPDATE
    SET chest = EXCLUDED.chest, waist = EXCLUDED.waist, hips = EXCLUDED.hips, thigh = EXCLUDED.thigh, created_at = now();
EXCEPTION WHEN check_violation THEN
  RAISE EXCEPTION 'أحد القياسات غير منطقي، راجع الأرقام (بالسنتيمتر).' USING ERRCODE = 'P0001';
END $$;

-- ---------- المدربة ----------
-- إسناد قالب لطلب: ينسخ الأيام والتمارين إلى بلوك جديد ويؤرشف البلوك النشط السابق لنفس الطلب
CREATE OR REPLACE FUNCTION app.coach_assign_template(p_order_no text, p_template uuid, p_start date, p_name text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_coach text := app.require_coach();
  v_order orders%ROWTYPE;
  v_tpl program_templates%ROWTYPE;
  v_block uuid;
  d record;
  v_day uuid;
BEGIN
  SELECT * INTO v_order FROM orders WHERE order_no = p_order_no;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO v_tpl FROM program_templates WHERE id = p_template;
  IF NOT FOUND THEN RAISE EXCEPTION 'القالب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  IF p_start IS NULL THEN RAISE EXCEPTION 'اختاري تاريخ البداية.' USING ERRCODE = 'P0001'; END IF;
  IF NOT EXISTS (SELECT 1 FROM template_days td JOIN template_items ti ON ti.day_id = td.id WHERE td.template_id = p_template) THEN
    RAISE EXCEPTION 'القالب فارغ: أضيفي أياماً وتمارين أولاً.' USING ERRCODE = 'P0001';
  END IF;

  UPDATE blocks SET status = 'archived', updated_at = now() WHERE order_id = v_order.id AND status = 'active';
  INSERT INTO blocks (order_id, user_id, template_id, name, start_date, weeks, instructions)
  VALUES (v_order.id, v_order.user_id, v_tpl.id, coalesce(nullif(trim(p_name), ''), v_tpl.name), p_start, v_tpl.weeks, v_tpl.instructions)
  RETURNING id INTO v_block;
  FOR d IN SELECT * FROM template_days WHERE template_id = p_template ORDER BY day_no LOOP
    INSERT INTO block_days (block_id, day_no, title) VALUES (v_block, d.day_no, d.title) RETURNING id INTO v_day;
    INSERT INTO block_items (day_id, position, exercise_id, coach_exercise_id, plan, note)
    SELECT v_day, ti.position, ti.exercise_id, ti.exercise_id, ti.plan, ti.note FROM template_items ti WHERE ti.day_id = d.id;
  END LOOP;
  INSERT INTO admin_log (actor_id, action, target, details)
  VALUES (v_coach, 'block.assign', p_order_no, jsonb_build_object('template', v_tpl.name, 'start', p_start));
  RETURN v_block;
END $$;

-- المدربة اطّلعت على تبديلات متدرب
CREATE OR REPLACE FUNCTION app.coach_mark_swaps_seen(p_user text) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE n int;
BEGIN
  PERFORM app.require_coach();
  UPDATE exercise_swaps SET seen_at = now() WHERE user_id = p_user AND seen_at IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

REVOKE ALL ON FUNCTION
  app.block_visible(uuid), app.day_block(uuid), app.item_block(uuid), app.my_active_block(uuid), app.check_week(blocks, int),
  app.block_exercises(uuid), app.swap_options(uuid), app.swap_exercise(uuid, uuid),
  app.log_item(uuid, int, numeric, int[], numeric), app.rate_day(uuid, int, int), app.log_steps(uuid, int, int),
  app.require_training(), app.log_weight(date, numeric), app.log_measurements(date, numeric, numeric, numeric, numeric),
  app.coach_assign_template(text, uuid, date, text), app.coach_mark_swaps_seen(text)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.block_visible(uuid), app.day_block(uuid), app.item_block(uuid),
  app.block_exercises(uuid), app.swap_options(uuid), app.swap_exercise(uuid, uuid),
  app.log_item(uuid, int, numeric, int[], numeric), app.rate_day(uuid, int, int), app.log_steps(uuid, int, int),
  app.log_weight(date, numeric), app.log_measurements(date, numeric, numeric, numeric, numeric),
  app.coach_assign_template(text, uuid, date, text), app.coach_mark_swaps_seen(text)
TO nav_app;

INSERT INTO schema_migrations (name) VALUES ('009_training.sql');

-- ---------- 010_exercise_taxonomy.sql ----------
-- =====================================================================
-- تصنيف التمارين التفصيلي (من ورقة «مكتبة التمارين»): النمط الفرعي / زاوية الحركة،
-- الحركة التشريحية الأساسية، والتصنيف الفرعي للحركة. تُستخدم للاختيار المتسلسل:
-- العضلة ← نمط الحركة ← النمط الفرعي ← الحركة التشريحية ← التصنيف الفرعي ← التمرين.
-- =====================================================================
ALTER TABLE exercises
  ADD COLUMN IF NOT EXISTS sub_pattern text CHECK (sub_pattern IS NULL OR length(sub_pattern) <= 160),
  ADD COLUMN IF NOT EXISTS anatomical_action text CHECK (anatomical_action IS NULL OR length(anatomical_action) <= 200),
  ADD COLUMN IF NOT EXISTS movement_subcategory text CHECK (movement_subcategory IS NULL OR length(movement_subcategory) <= 160);
CREATE INDEX IF NOT EXISTS exercises_taxonomy_idx ON exercises (primary_muscle, pattern, sub_pattern);

INSERT INTO schema_migrations (name) VALUES ('010_exercise_taxonomy.sql');

-- ---------- 011_nutrition.sql ----------
-- =====================================================================
-- التغذية والمكملات (بديل أوراق «التعليمات» و«تغذية ١–٥» و«Macro Log» و«روتين المكملات»).
-- * الجداول الغذائية وروتين المكملات: order_id فارغ = قالب في مكتبة المدربة، وغير فارغ = نسخة لمتدرب.
--   الإسناد ينسخ القالب للمتدرب، فتعديله لا يغيّر القالب ولا العكس.
-- * المتدرب يقرأ نسخه فقط بعد تأكيد الدفع (app.order_entitled)، والكتابة للمدربة فقط.
-- * سجل الأكل اليومي يكتبه المتدرب عبر دوال فقط: من وجبات جداوله أو إدخال حر.
-- =====================================================================

-- ---------- الأهداف اليومية لكل متدرب ----------
CREATE TABLE nutrition_targets (
  order_id uuid PRIMARY KEY REFERENCES orders (id) ON DELETE CASCADE,
  kcal int CHECK (kcal IS NULL OR kcal BETWEEN 500 and 10000),
  protein numeric(6,1) CHECK (protein IS NULL OR protein BETWEEN 0 AND 1000),
  carbs numeric(6,1) CHECK (carbs IS NULL OR carbs BETWEEN 0 AND 1500),
  fat numeric(6,1) CHECK (fat IS NULL OR fat BETWEEN 0 AND 500),
  rules text CHECK (rules IS NULL OR length(rules) <= 5000),
  updated_by text REFERENCES "user" (id) ON DELETE SET NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- ---------- الجداول الغذائية (قوالب ونسخ المتدربين) ----------
CREATE TABLE nutrition_plans (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid REFERENCES orders (id) ON DELETE CASCADE,          -- فارغ = قالب
  source_id uuid REFERENCES nutrition_plans (id) ON DELETE SET NULL,
  name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 120),
  notes text CHECK (notes IS NULL OR length(notes) <= 3000),
  position int NOT NULL DEFAULT 0,
  archived boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX nutrition_plans_order_idx ON nutrition_plans (order_id, position);
CREATE UNIQUE INDEX nutrition_plans_template_name ON nutrition_plans (lower(trim(name))) WHERE order_id IS NULL;

CREATE TABLE plan_meals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id uuid NOT NULL REFERENCES nutrition_plans (id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('breakfast', 'lunch', 'dinner', 'snack')),
  title text NOT NULL CHECK (length(trim(title)) BETWEEN 1 AND 120),
  method text CHECK (method IS NULL OR length(method) <= 3000),     -- طريقة التحضير
  position int NOT NULL DEFAULT 0
);
CREATE INDEX plan_meals_plan_idx ON plan_meals (plan_id, position);

CREATE TABLE plan_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  meal_id uuid NOT NULL REFERENCES plan_meals (id) ON DELETE CASCADE,
  food text NOT NULL CHECK (length(trim(food)) BETWEEN 1 AND 160),
  portion text CHECK (portion IS NULL OR length(portion) <= 80),
  protein numeric(6,1) NOT NULL DEFAULT 0 CHECK (protein BETWEEN 0 AND 500),
  carbs numeric(6,1) NOT NULL DEFAULT 0 CHECK (carbs BETWEEN 0 AND 500),
  fat numeric(6,1) NOT NULL DEFAULT 0 CHECK (fat BETWEEN 0 AND 300),
  position int NOT NULL DEFAULT 0
);
CREATE INDEX plan_items_meal_idx ON plan_items (meal_id, position);

-- ---------- سجل الأكل اليومي (Macro Log) ----------
CREATE TABLE food_logs (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id text NOT NULL REFERENCES "user" (id) ON DELETE CASCADE,
  order_id uuid NOT NULL REFERENCES orders (id) ON DELETE CASCADE,
  log_date date NOT NULL,
  kind text NOT NULL CHECK (kind IN ('breakfast', 'lunch', 'dinner', 'snack')),
  meal_id uuid REFERENCES plan_meals (id) ON DELETE SET NULL,       -- فارغ = إدخال حر
  name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 160),
  protein numeric(6,1) NOT NULL CHECK (protein BETWEEN 0 AND 500),
  carbs numeric(6,1) NOT NULL CHECK (carbs BETWEEN 0 AND 500),
  fat numeric(6,1) NOT NULL CHECK (fat BETWEEN 0 AND 300),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX food_logs_user_date_idx ON food_logs (user_id, log_date DESC);
CREATE INDEX food_logs_order_date_idx ON food_logs (order_id, log_date DESC);

-- ---------- روتين المكملات (قوالب ونسخ المتدربين) ----------
CREATE TABLE supplement_routines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid REFERENCES orders (id) ON DELETE CASCADE,          -- فارغ = قالب
  name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 120),
  intro text CHECK (intro IS NULL OR length(intro) <= 2000),
  archived boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX supplement_routines_one_per_order ON supplement_routines (order_id) WHERE order_id IS NOT NULL;
CREATE UNIQUE INDEX supplement_routines_template_name ON supplement_routines (lower(trim(name))) WHERE order_id IS NULL;

CREATE TABLE supplement_sections (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  routine_id uuid NOT NULL REFERENCES supplement_routines (id) ON DELETE CASCADE,
  title text NOT NULL CHECK (length(trim(title)) BETWEEN 1 AND 120),
  routine text CHECK (routine IS NULL OR length(routine) <= 4000),   -- نص «الروتين» تحت القسم
  position int NOT NULL DEFAULT 0
);
CREATE TABLE supplement_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  section_id uuid NOT NULL REFERENCES supplement_sections (id) ON DELETE CASCADE,
  name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 120),
  dose text CHECK (dose IS NULL OR length(dose) <= 120),
  timing text CHECK (timing IS NULL OR length(timing) <= 160),
  importance text CHECK (importance IS NULL OR length(importance) <= 60),
  benefit text CHECK (benefit IS NULL OR length(benefit) <= 1000),
  link text CHECK (link IS NULL OR link ~ '^https://'),
  position int NOT NULL DEFAULT 0
);

-- ---------- صلاحيات ----------
CREATE OR REPLACE FUNCTION app.plan_visible(p_plan uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT app.is_coach() OR EXISTS (SELECT 1 FROM nutrition_plans p WHERE p.id = p_plan AND p.order_id IS NOT NULL AND NOT p.archived AND app.order_entitled(p.order_id))
$$;
CREATE OR REPLACE FUNCTION app.meal_plan(p_meal uuid) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$ SELECT plan_id FROM plan_meals WHERE id = p_meal $$;
CREATE OR REPLACE FUNCTION app.routine_visible(p_routine uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT app.is_coach() OR EXISTS (SELECT 1 FROM supplement_routines r WHERE r.id = p_routine AND r.order_id IS NOT NULL AND NOT r.archived AND app.order_entitled(r.order_id))
$$;
CREATE OR REPLACE FUNCTION app.section_routine(p_section uuid) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$ SELECT routine_id FROM supplement_sections WHERE id = p_section $$;

ALTER TABLE nutrition_targets ENABLE ROW LEVEL SECURITY;
ALTER TABLE nutrition_plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE plan_meals ENABLE ROW LEVEL SECURITY;
ALTER TABLE plan_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE food_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE supplement_routines ENABLE ROW LEVEL SECURITY;
ALTER TABLE supplement_sections ENABLE ROW LEVEL SECURITY;
ALTER TABLE supplement_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY targets_read ON nutrition_targets FOR SELECT USING (app.is_coach() OR app.order_entitled(order_id));
CREATE POLICY targets_write ON nutrition_targets FOR ALL USING (app.is_coach()) WITH CHECK (app.is_coach());
CREATE POLICY nplans_read ON nutrition_plans FOR SELECT USING (app.plan_visible(id));
CREATE POLICY nplans_write ON nutrition_plans FOR ALL USING (app.is_coach()) WITH CHECK (app.is_coach());
CREATE POLICY pmeals_read ON plan_meals FOR SELECT USING (app.plan_visible(plan_id));
CREATE POLICY pmeals_write ON plan_meals FOR ALL USING (app.is_coach()) WITH CHECK (app.is_coach());
CREATE POLICY pitems_read ON plan_items FOR SELECT USING (app.plan_visible(app.meal_plan(meal_id)));
CREATE POLICY pitems_write ON plan_items FOR ALL USING (app.is_coach()) WITH CHECK (app.is_coach());
CREATE POLICY food_logs_read ON food_logs FOR SELECT USING (user_id = app.uid() OR app.is_coach());
CREATE POLICY sroutines_read ON supplement_routines FOR SELECT USING (app.routine_visible(id));
CREATE POLICY sroutines_write ON supplement_routines FOR ALL USING (app.is_coach()) WITH CHECK (app.is_coach());
CREATE POLICY ssections_read ON supplement_sections FOR SELECT USING (app.routine_visible(routine_id));
CREATE POLICY ssections_write ON supplement_sections FOR ALL USING (app.is_coach()) WITH CHECK (app.is_coach());
CREATE POLICY sitems_read ON supplement_items FOR SELECT USING (app.routine_visible(app.section_routine(section_id)));
CREATE POLICY sitems_write ON supplement_items FOR ALL USING (app.is_coach()) WITH CHECK (app.is_coach());

GRANT SELECT, INSERT, UPDATE, DELETE ON nutrition_targets, nutrition_plans, plan_meals, plan_items,
  supplement_routines, supplement_sections, supplement_items TO nav_app;
GRANT SELECT ON food_logs TO nav_app;

-- ---------- المتدرب: سجل الأكل ----------
-- إضافة: من وجبة في جداوله (p_meal) بمجموع مكوناتها، أو إدخال حر (الاسم والماكروز)
CREATE OR REPLACE FUNCTION app.log_food(p_order_no text, p_date date, p_kind text, p_meal uuid,
                                        p_name text, p_protein numeric, p_carbs numeric, p_fat numeric) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  u text := app.require_user();
  v_order uuid;
  today date := (now() AT TIME ZONE 'Asia/Riyadh')::date;
  v_name text; v_p numeric; v_c numeric; v_f numeric; v_kind text := p_kind;
  v_id bigint;
BEGIN
  SELECT id INTO v_order FROM orders WHERE order_no = p_order_no AND user_id = u;
  IF NOT FOUND OR NOT app.order_entitled(v_order) THEN RAISE EXCEPTION 'الطلب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  IF p_date IS NULL OR p_date > today OR p_date < today - 60 THEN RAISE EXCEPTION 'التاريخ غير صحيح.' USING ERRCODE = 'P0001'; END IF;
  IF p_meal IS NOT NULL THEN
    SELECT m.title, m.kind, coalesce(sum(i.protein), 0), coalesce(sum(i.carbs), 0), coalesce(sum(i.fat), 0)
      INTO v_name, v_kind, v_p, v_c, v_f
      FROM plan_meals m JOIN nutrition_plans p ON p.id = m.plan_id LEFT JOIN plan_items i ON i.meal_id = m.id
     WHERE m.id = p_meal AND p.order_id = v_order AND NOT p.archived
     GROUP BY m.id;
    IF NOT FOUND THEN RAISE EXCEPTION 'الوجبة غير موجودة في جداولك.' USING ERRCODE = 'P0001'; END IF;
    v_name := (SELECT name FROM nutrition_plans WHERE id = app.meal_plan(p_meal)) || ' — ' || v_name;
    v_kind := coalesce(p_kind, v_kind);
  ELSE
    v_name := nullif(trim(coalesce(p_name, '')), '');
    IF v_name IS NULL THEN RAISE EXCEPTION 'اكتب اسم الأكلة.' USING ERRCODE = 'P0001'; END IF;
    v_p := coalesce(p_protein, 0); v_c := coalesce(p_carbs, 0); v_f := coalesce(p_fat, 0);
    IF v_p < 0 OR v_c < 0 OR v_f < 0 OR v_p > 500 OR v_c > 500 OR v_f > 300 THEN
      RAISE EXCEPTION 'أرقام الماكروز غير منطقية.' USING ERRCODE = 'P0001';
    END IF;
    IF v_p + v_c + v_f = 0 THEN RAISE EXCEPTION 'اكتب البروتين أو الكارب أو الدهون.' USING ERRCODE = 'P0001'; END IF;
  END IF;
  IF v_kind NOT IN ('breakfast', 'lunch', 'dinner', 'snack') THEN RAISE EXCEPTION 'اختر الوجبة.' USING ERRCODE = 'P0001'; END IF;
  IF (SELECT count(*) FROM food_logs WHERE user_id = u AND log_date = p_date) >= 30 THEN
    RAISE EXCEPTION 'وصلت الحد الأعلى لتسجيلات اليوم.' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO food_logs (user_id, order_id, log_date, kind, meal_id, name, protein, carbs, fat)
  VALUES (u, v_order, p_date, v_kind, p_meal, left(v_name, 160), round(v_p, 1), round(v_c, 1), round(v_f, 1))
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION app.delete_food_log(p_id bigint) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE u text := app.require_user();
BEGIN
  DELETE FROM food_logs WHERE id = p_id AND user_id = u AND log_date >= (now() AT TIME ZONE 'Asia/Riyadh')::date - 60;
  IF NOT FOUND THEN RAISE EXCEPTION 'التسجيل غير موجود.' USING ERRCODE = 'P0001'; END IF;
END $$;

-- ---------- المدربة: إسناد قالب (نسخ) ----------
CREATE OR REPLACE FUNCTION app.coach_assign_nutrition(p_order_no text, p_template uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_coach text := app.require_coach();
  v_order uuid; v_tpl nutrition_plans%ROWTYPE; v_new uuid; m record; v_meal uuid;
BEGIN
  SELECT id INTO v_order FROM orders WHERE order_no = p_order_no;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO v_tpl FROM nutrition_plans WHERE id = p_template AND order_id IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'الجدول غير موجود.' USING ERRCODE = 'P0001'; END IF;
  INSERT INTO nutrition_plans (order_id, source_id, name, notes, position)
  VALUES (v_order, v_tpl.id, v_tpl.name, v_tpl.notes, (SELECT coalesce(max(position), -1) + 1 FROM nutrition_plans WHERE order_id = v_order))
  RETURNING id INTO v_new;
  FOR m IN SELECT * FROM plan_meals WHERE plan_id = v_tpl.id ORDER BY position LOOP
    INSERT INTO plan_meals (plan_id, kind, title, method, position) VALUES (v_new, m.kind, m.title, m.method, m.position) RETURNING id INTO v_meal;
    INSERT INTO plan_items (meal_id, food, portion, protein, carbs, fat, position)
    SELECT v_meal, food, portion, protein, carbs, fat, position FROM plan_items WHERE meal_id = m.id;
  END LOOP;
  INSERT INTO admin_log (actor_id, action, target, details) VALUES (v_coach, 'nutrition.assign', p_order_no, jsonb_build_object('plan', v_tpl.name));
  RETURN v_new;
END $$;

CREATE OR REPLACE FUNCTION app.coach_assign_supplements(p_order_no text, p_template uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_coach text := app.require_coach();
  v_order uuid; v_tpl supplement_routines%ROWTYPE; v_new uuid; s record; v_sec uuid;
BEGIN
  SELECT id INTO v_order FROM orders WHERE order_no = p_order_no;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO v_tpl FROM supplement_routines WHERE id = p_template AND order_id IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'الروتين غير موجود.' USING ERRCODE = 'P0001'; END IF;
  DELETE FROM supplement_routines WHERE order_id = v_order;   -- روتين واحد لكل متدرب: الإسناد الجديد يستبدله
  INSERT INTO supplement_routines (order_id, name, intro) VALUES (v_order, v_tpl.name, v_tpl.intro) RETURNING id INTO v_new;
  FOR s IN SELECT * FROM supplement_sections WHERE routine_id = v_tpl.id ORDER BY position LOOP
    INSERT INTO supplement_sections (routine_id, title, routine, position) VALUES (v_new, s.title, s.routine, s.position) RETURNING id INTO v_sec;
    INSERT INTO supplement_items (section_id, name, dose, timing, importance, benefit, link, position)
    SELECT v_sec, name, dose, timing, importance, benefit, link, position FROM supplement_items WHERE section_id = s.id;
  END LOOP;
  INSERT INTO admin_log (actor_id, action, target, details) VALUES (v_coach, 'supplements.assign', p_order_no, jsonb_build_object('routine', v_tpl.name));
  RETURN v_new;
END $$;

REVOKE ALL ON FUNCTION app.plan_visible(uuid), app.meal_plan(uuid), app.routine_visible(uuid), app.section_routine(uuid),
  app.log_food(text, date, text, uuid, text, numeric, numeric, numeric), app.delete_food_log(bigint),
  app.coach_assign_nutrition(text, uuid), app.coach_assign_supplements(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.plan_visible(uuid), app.meal_plan(uuid), app.routine_visible(uuid), app.section_routine(uuid),
  app.log_food(text, date, text, uuid, text, numeric, numeric, numeric), app.delete_food_log(bigint),
  app.coach_assign_nutrition(text, uuid), app.coach_assign_supplements(text, uuid) TO nav_app;

INSERT INTO schema_migrations (name) VALUES ('011_nutrition.sql');

-- ---------- 012_foods.sql ----------
-- =====================================================================
-- قاعدة الأكل بالغرامات: أصناف بقيمها لكل 100غ (من USDA FoodData Central — ملكية عامة CC0،
-- أو أصناف تضيفها المدربة). المتدرب يختار الصنف ويكتب الغرامات، وقاعدة البيانات تحسب الماكروز.
-- =====================================================================

CREATE TABLE foods (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name_ar text NOT NULL CHECK (length(trim(name_ar)) BETWEEN 2 AND 120),
  name_en text CHECK (name_en IS NULL OR length(name_en) <= 160),
  category text CHECK (category IS NULL OR length(category) <= 60),
  kcal_100 numeric(6,1) NOT NULL CHECK (kcal_100 BETWEEN 0 AND 950),
  protein_100 numeric(5,1) NOT NULL CHECK (protein_100 BETWEEN 0 AND 100),
  carbs_100 numeric(5,1) NOT NULL CHECK (carbs_100 BETWEEN 0 AND 100),
  fat_100 numeric(5,1) NOT NULL CHECK (fat_100 BETWEEN 0 AND 100),
  serving_g numeric(6,1) CHECK (serving_g IS NULL OR serving_g BETWEEN 1 AND 3000),
  serving_label text CHECK (serving_label IS NULL OR length(serving_label) <= 60),
  source text NOT NULL DEFAULT 'coach' CHECK (source IN ('usda', 'coach')),
  source_ref text CHECK (source_ref IS NULL OR length(source_ref) <= 40),   -- رقم fdcId في USDA
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX foods_name_ar_key ON foods (lower(trim(name_ar)));
CREATE INDEX foods_active_idx ON foods (active, category);

ALTER TABLE foods ENABLE ROW LEVEL SECURITY;
-- الأصناف بيانات عامة غير شخصية: يقرأ النشط منها أي مستخدم مسجّل، والمدربة تقرأ وتكتب الكل
CREATE POLICY foods_read ON foods FOR SELECT USING (app.is_coach() OR (active AND app.uid() IS NOT NULL));
CREATE POLICY foods_write ON foods FOR ALL USING (app.is_coach()) WITH CHECK (app.is_coach());
GRANT SELECT, INSERT, UPDATE, DELETE ON foods TO nav_app;

-- مصدر كل تسجيل أكل والغرامات
ALTER TABLE food_logs ADD COLUMN IF NOT EXISTS food_id uuid REFERENCES foods (id) ON DELETE SET NULL;
ALTER TABLE food_logs ADD COLUMN IF NOT EXISTS grams numeric(6,1) CHECK (grams IS NULL OR grams BETWEEN 1 AND 3000);
ALTER TABLE food_logs ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'free' CHECK (source IN ('plan', 'food', 'fatsecret', 'free'));
UPDATE food_logs SET source = 'plan' WHERE meal_id IS NOT NULL AND source = 'free';
-- تسجيلات app.log_food من وجبات الجداول تُعلَّم «plan» تلقائياً
CREATE OR REPLACE FUNCTION app.food_log_source() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.meal_id IS NOT NULL AND NEW.source = 'free' THEN NEW.source := 'plan'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER food_logs_source BEFORE INSERT ON food_logs FOR EACH ROW EXECUTE FUNCTION app.food_log_source();

-- إضافة من القاعدة بالغرامات: الماكروز تُحسب هنا من قيم 100غ (لا تُقبل أرقام من المتصفح)
CREATE OR REPLACE FUNCTION app.log_food_grams(p_order_no text, p_date date, p_kind text, p_food uuid, p_grams numeric) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  u text := app.require_user();
  v_order uuid;
  today date := (now() AT TIME ZONE 'Asia/Riyadh')::date;
  f foods%ROWTYPE;
  v_id bigint;
BEGIN
  SELECT id INTO v_order FROM orders WHERE order_no = p_order_no AND user_id = u;
  IF NOT FOUND OR NOT app.order_entitled(v_order) THEN RAISE EXCEPTION 'الطلب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  IF p_date IS NULL OR p_date > today OR p_date < today - 60 THEN RAISE EXCEPTION 'التاريخ غير صحيح.' USING ERRCODE = 'P0001'; END IF;
  IF p_kind IS NULL OR p_kind NOT IN ('breakfast', 'lunch', 'dinner', 'snack') THEN RAISE EXCEPTION 'اختر الوجبة.' USING ERRCODE = 'P0001'; END IF;
  IF p_grams IS NULL OR p_grams < 1 OR p_grams > 3000 THEN RAISE EXCEPTION 'اكتب الكمية بالغرام (من 1 إلى 3000).' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO f FROM foods WHERE id = p_food AND active;
  IF NOT FOUND THEN RAISE EXCEPTION 'الصنف غير موجود.' USING ERRCODE = 'P0001'; END IF;
  IF (SELECT count(*) FROM food_logs WHERE user_id = u AND log_date = p_date) >= 30 THEN
    RAISE EXCEPTION 'وصلت الحد الأعلى لتسجيلات اليوم.' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO food_logs (user_id, order_id, log_date, kind, food_id, grams, source, name, protein, carbs, fat)
  VALUES (u, v_order, p_date, p_kind, f.id, round(p_grams, 1), 'food',
          left(f.name_ar || ' — ' || trim(to_char(round(p_grams, 1), 'FM99990.9'), '.') || 'غ', 160),
          round(f.protein_100 * p_grams / 100, 1), round(f.carbs_100 * p_grams / 100, 1), round(f.fat_100 * p_grams / 100, 1))
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- إضافة من FatSecret: القيم لكل 100غ يجلبها الخادم من FatSecret نفسه (ليس من المتصفح) ثم تُحسب هنا
CREATE OR REPLACE FUNCTION app.log_food_external(p_order_no text, p_date date, p_kind text, p_name text, p_grams numeric,
                                                 p_protein_100 numeric, p_carbs_100 numeric, p_fat_100 numeric) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  u text := app.require_user();
  v_order uuid;
  today date := (now() AT TIME ZONE 'Asia/Riyadh')::date;
  v_id bigint;
BEGIN
  SELECT id INTO v_order FROM orders WHERE order_no = p_order_no AND user_id = u;
  IF NOT FOUND OR NOT app.order_entitled(v_order) THEN RAISE EXCEPTION 'الطلب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  IF p_date IS NULL OR p_date > today OR p_date < today - 60 THEN RAISE EXCEPTION 'التاريخ غير صحيح.' USING ERRCODE = 'P0001'; END IF;
  IF p_kind IS NULL OR p_kind NOT IN ('breakfast', 'lunch', 'dinner', 'snack') THEN RAISE EXCEPTION 'اختر الوجبة.' USING ERRCODE = 'P0001'; END IF;
  IF p_grams IS NULL OR p_grams < 1 OR p_grams > 3000 THEN RAISE EXCEPTION 'اكتب الكمية بالغرام (من 1 إلى 3000).' USING ERRCODE = 'P0001'; END IF;
  IF coalesce(trim(p_name), '') = '' OR p_protein_100 NOT BETWEEN 0 AND 100 OR p_carbs_100 NOT BETWEEN 0 AND 100 OR p_fat_100 NOT BETWEEN 0 AND 100 THEN
    RAISE EXCEPTION 'بيانات الصنف غير صحيحة.' USING ERRCODE = 'P0001';
  END IF;
  IF (SELECT count(*) FROM food_logs WHERE user_id = u AND log_date = p_date) >= 30 THEN
    RAISE EXCEPTION 'وصلت الحد الأعلى لتسجيلات اليوم.' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO food_logs (user_id, order_id, log_date, kind, grams, source, name, protein, carbs, fat)
  VALUES (u, v_order, p_date, p_kind, round(p_grams, 1), 'fatsecret',
          left(trim(p_name) || ' — ' || trim(to_char(round(p_grams, 1), 'FM99990.9'), '.') || 'g', 160),
          round(p_protein_100 * p_grams / 100, 1), round(p_carbs_100 * p_grams / 100, 1), round(p_fat_100 * p_grams / 100, 1))
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

REVOKE ALL ON FUNCTION app.log_food_grams(text, date, text, uuid, numeric),
  app.log_food_external(text, date, text, text, numeric, numeric, numeric, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.log_food_grams(text, date, text, uuid, numeric),
  app.log_food_external(text, date, text, text, numeric, numeric, numeric, numeric) TO nav_app;

INSERT INTO schema_migrations (name) VALUES ('012_foods.sql');

-- ---------- 013_retention.sql ----------
-- =====================================================================
-- الاحتفاظ بالمتدربين: تجديد بخصم 10% قبل انتهاء الاشتراك، ومكافأة الالتزام (3 أشهر مجاناً).
-- الخصم والسعر يُحسبان هنا من قاعدة البيانات (لا يُقبل مبلغ من المتصفح).
-- =====================================================================

-- الطلب الذي يمدّد اشتراكاً سابقاً (تجديد مدفوع أو مكافأة)
ALTER TABLE orders ADD COLUMN IF NOT EXISTS renewal_of uuid REFERENCES orders (id) ON DELETE SET NULL;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS renewal_kind text CHECK (renewal_kind IS NULL OR renewal_kind IN ('renewal', 'reward'));
-- تجديد مدفوع واحد (غير ملغى) لكل اشتراك، ومكافأة واحدة لكل اشتراك
CREATE UNIQUE INDEX IF NOT EXISTS orders_one_renewal_idx ON orders (renewal_of, renewal_kind) WHERE renewal_of IS NOT NULL AND status <> 'cancelled';

-- عند تفعيل طلب تجديد: يبدأ بعد نهاية آخر اشتراك قائم للمتدرب (لا تضيع أيام)، وإلا من الآن
CREATE OR REPLACE FUNCTION app.set_subscription_dates() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_start timestamptz := now();
BEGIN
  IF NEW.status = 'active' AND OLD.status IS DISTINCT FROM 'active' AND NEW.months > 0 AND NEW.sub_start_at IS NULL THEN
    IF NEW.renewal_of IS NOT NULL THEN
      SELECT greatest(now(), coalesce(max(o.sub_end_at), now())) INTO v_start
        FROM orders o
       WHERE o.user_id = NEW.user_id AND o.id <> NEW.id AND o.category = 'follow'
         AND o.status IN ('active', 'delivered', 'completed') AND o.sub_end_at IS NOT NULL
         AND (o.id = NEW.renewal_of OR o.renewal_of = NEW.renewal_of);
    END IF;
    NEW.sub_start_at := v_start;
    NEW.sub_end_at := v_start + make_interval(months => NEW.months);
    NEW.review_weekday := coalesce(NEW.review_weekday,
      (SELECT o.review_weekday FROM orders o WHERE o.id = NEW.renewal_of),
      extract(dow FROM (now() AT TIME ZONE 'Asia/Riyadh'))::smallint);
  END IF;
  RETURN NEW;
END $$;

-- ---------- التجديد بالخصم (المتدرب صاحب الطلب) ----------
CREATE OR REPLACE FUNCTION app.create_renewal(p_order_no text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  u text := app.require_user();
  o orders%ROWTYPE;
  -- نفس القيم في src/lib/renewal.ts (RENEWAL_PCT و RENEWAL_WINDOW_DAYS)
  v_pct constant int := 10;
  v_window constant int := 5;
  today date := (now() AT TIME ZONE 'Asia/Riyadh')::date;
  v_end date;
  v_offer record;
  v_price int;
  v_new uuid;
  v_no text;
BEGIN
  SELECT * INTO o FROM orders WHERE order_no = p_order_no AND user_id = u FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  IF o.category <> 'follow' OR o.months <= 0 OR o.status NOT IN ('active', 'delivered') OR o.sub_end_at IS NULL THEN
    RAISE EXCEPTION 'هذا الطلب لا يقبل التجديد.' USING ERRCODE = 'P0001';
  END IF;
  v_end := (o.sub_end_at AT TIME ZONE 'Asia/Riyadh')::date;
  IF today < v_end - v_window OR today > v_end THEN
    RAISE EXCEPTION 'عرض التجديد متاح خلال آخر % أيام من الاشتراك.', v_window USING ERRCODE = 'P0001';
  END IF;
  -- طلب تجديد سابق لنفس الاشتراك (غير ملغى): نرجعه بدل إنشاء آخر
  SELECT order_no INTO v_no FROM orders WHERE renewal_of = o.id AND renewal_kind = 'renewal' AND status <> 'cancelled';
  IF FOUND THEN RETURN v_no; END IF;

  -- السعر الحالي للعرض نفسه إن كان متاحاً، وإلا سعر الطلب الأصلي
  SELECT po.id, po.label, po.months, po.price_halalas, po.currency, p.id AS product_id, p.name
    INTO v_offer
    FROM product_offers po JOIN products p ON p.id = po.product_id
   WHERE po.id = o.offer_id AND po.active AND p.status = 'published';
  v_price := CASE WHEN FOUND THEN v_offer.price_halalas ELSE o.list_price_halalas END;

  v_no := app.new_order_no();
  INSERT INTO orders (order_no, user_id, product_id, offer_id, category, product_name, offer_label, months,
                      list_price_halalas, amount_due_halalas, currency, status, contact_name, contact_phone,
                      idempotency_key, is_demo, renewal_of, renewal_kind)
  VALUES (v_no, u, o.product_id, o.offer_id, o.category, coalesce(v_offer.name, o.product_name),
          coalesce(v_offer.label, o.offer_label), coalesce(v_offer.months, o.months),
          v_price, round(v_price * (100 - v_pct) / 100.0)::int, coalesce(v_offer.currency, o.currency),
          'awaiting_payment', o.contact_name, o.contact_phone,
          'renewal-' || gen_random_uuid()::text, o.is_demo, o.id, 'renewal')
  RETURNING id INTO v_new;

  -- نسخة من الاستبيان السابق (البرنامج مستمر لنفس المتدرب)، والموافقة على الشروط بتاريخ التجديد
  INSERT INTO intakes (order_id, user_id, answers, health, health_flag, media_consent, consent_terms_at, consent_whatsapp_at)
  SELECT v_new, u, i.answers, i.health, i.health_flag, i.media_consent, now(), i.consent_whatsapp_at
    FROM intakes i WHERE i.order_id = o.id;

  INSERT INTO order_events (order_id, from_status, to_status, actor_id, actor_role, note)
  VALUES (v_new, NULL, 'awaiting_payment', u, 'client',
          format('طلب تجديد بخصم %s%% لاشتراك %s. بعد الدفع يبدأ من نهاية اشتراكك الحالي.', v_pct, o.order_no));
  RETURN v_no;
END $$;

-- ---------- مكافأة الالتزام (للمدربة) ----------
CREATE TABLE IF NOT EXISTS loyalty_rewards (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  order_id uuid NOT NULL UNIQUE REFERENCES orders (id) ON DELETE CASCADE,
  reward_order_id uuid REFERENCES orders (id) ON DELETE SET NULL,
  adherence numeric(4,3) CHECK (adherence IS NULL OR adherence BETWEEN 0 AND 1),
  granted_by text REFERENCES "user" (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE loyalty_rewards ENABLE ROW LEVEL SECURITY;
CREATE POLICY loyalty_rewards_read ON loyalty_rewards FOR SELECT USING (app.is_coach() OR app.owns_order(order_id));
GRANT SELECT ON loyalty_rewards TO nav_app;

CREATE OR REPLACE FUNCTION app.coach_grant_reward(p_order_no text, p_adherence numeric) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_coach text := app.require_coach();
  o orders%ROWTYPE;
  v_new uuid;
  v_no text;
BEGIN
  SELECT * INTO o FROM orders WHERE order_no = p_order_no FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  IF o.category <> 'follow' OR o.months < 3 OR o.status NOT IN ('active', 'delivered', 'completed') OR o.sub_start_at IS NULL THEN
    RAISE EXCEPTION 'المكافأة لاشتراكات المتابعة 3 أشهر فأكثر فقط.' USING ERRCODE = 'P0001';
  END IF;
  IF p_adherence IS NULL OR p_adherence < 0.9 OR p_adherence > 1 THEN
    RAISE EXCEPTION 'نسبة الالتزام أقل من 90%%.' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM loyalty_rewards WHERE order_id = o.id) THEN
    RAISE EXCEPTION 'مُنحت المكافأة لهذا الاشتراك من قبل.' USING ERRCODE = 'P0001';
  END IF;

  v_no := app.new_order_no();
  INSERT INTO orders (order_no, user_id, product_id, offer_id, category, product_name, offer_label, months,
                      list_price_halalas, amount_due_halalas, currency, status, contact_name, contact_phone,
                      idempotency_key, is_demo, paid_at, source, renewal_of, renewal_kind)
  VALUES (v_no, o.user_id, o.product_id, o.offer_id, o.category, o.product_name, 'مكافأة الالتزام — 3 أشهر مجاناً', 3,
          0, 0, o.currency, 'preparing', o.contact_name, o.contact_phone,
          'reward-' || gen_random_uuid()::text, o.is_demo, now(), 'manual', o.id, 'reward')
  RETURNING id INTO v_new;

  INSERT INTO intakes (order_id, user_id, answers, health, health_flag, media_consent, consent_terms_at, consent_whatsapp_at)
  SELECT v_new, o.user_id, i.answers, i.health, i.health_flag, i.media_consent, i.consent_terms_at, i.consent_whatsapp_at
    FROM intakes i WHERE i.order_id = o.id;

  INSERT INTO order_events (order_id, from_status, to_status, actor_id, actor_role, note)
  VALUES (v_new, NULL, 'preparing', v_coach, 'coach',
          format('مكافأة التزامك بنسبة %s%% خلال اشتراكك: 3 أشهر مجاناً 🎉', round(p_adherence * 100)));
  -- التفعيل عبر تحديث الحالة ليبدأ من نهاية الاشتراك الحالي
  UPDATE orders SET status = 'active', updated_at = now() WHERE id = v_new;
  INSERT INTO order_events (order_id, from_status, to_status, actor_id, actor_role)
  VALUES (v_new, 'preparing', 'active', v_coach, 'coach');

  INSERT INTO loyalty_rewards (order_id, reward_order_id, adherence, granted_by)
  VALUES (o.id, v_new, round(p_adherence, 3), v_coach);
  INSERT INTO admin_log (actor_id, action, target, details)
  VALUES (v_coach, 'reward.grant', o.order_no, jsonb_build_object('reward_order', v_no, 'adherence', round(p_adherence, 3)));
  RETURN v_no;
END $$;

REVOKE ALL ON FUNCTION app.create_renewal(text), app.coach_grant_reward(text, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.create_renewal(text), app.coach_grant_reward(text, numeric) TO nav_app;

INSERT INTO schema_migrations (name) VALUES ('013_retention.sql');

-- ---------- 014_exit_survey.sql ----------
-- =====================================================================
-- استبيان نهاية البرنامج: يظهر للمتدرب عند انتهاء اشتراك المتابعة، ويصل للمدربة فقط (غير منشور).
-- =====================================================================

CREATE TABLE IF NOT EXISTS exit_surveys (
  order_id uuid PRIMARY KEY REFERENCES orders (id) ON DELETE CASCADE,
  user_id text NOT NULL REFERENCES "user" (id) ON DELETE CASCADE,
  wants_renewal boolean NOT NULL,
  reason text NOT NULL CHECK (length(trim(reason)) BETWEEN 2 AND 1000),
  experience text NOT NULL CHECK (length(trim(experience)) BETWEEN 2 AND 2000),
  created_at timestamptz NOT NULL DEFAULT now(),
  seen_at timestamptz
);
CREATE INDEX IF NOT EXISTS exit_surveys_unseen_idx ON exit_surveys (created_at) WHERE seen_at IS NULL;
ALTER TABLE exit_surveys ENABLE ROW LEVEL SECURITY;
CREATE POLICY exit_surveys_read ON exit_surveys FOR SELECT USING (app.is_coach() OR user_id = app.uid());
GRANT SELECT ON exit_surveys TO nav_app;

-- المتدرب يرسل مرة واحدة لكل اشتراك، من يوم انتهائه (بتوقيت الرياض) أو بعد إنهاء المدربة للطلب
CREATE OR REPLACE FUNCTION app.submit_exit_survey(p_order_no text, p_wants boolean, p_reason text, p_experience text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  u text := app.require_user();
  o orders%ROWTYPE;
BEGIN
  SELECT * INTO o FROM orders WHERE order_no = p_order_no AND user_id = u;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  IF o.category <> 'follow' OR o.months <= 0 OR o.status NOT IN ('active', 'delivered', 'completed')
     OR (o.status <> 'completed' AND (o.sub_end_at IS NULL OR (now() AT TIME ZONE 'Asia/Riyadh')::date < (o.sub_end_at AT TIME ZONE 'Asia/Riyadh')::date)) THEN
    RAISE EXCEPTION 'الاستبيان يُتاح عند نهاية البرنامج.' USING ERRCODE = 'P0001';
  END IF;
  IF p_wants IS NULL THEN RAISE EXCEPTION 'اختر: عندك رغبة بالتجديد أو لا.' USING ERRCODE = 'P0001'; END IF;
  IF length(trim(coalesce(p_reason, ''))) < 2 THEN RAISE EXCEPTION 'وضّح السبب باختصار.' USING ERRCODE = 'P0001'; END IF;
  IF length(trim(coalesce(p_experience, ''))) < 2 THEN RAISE EXCEPTION 'اكتب باختصار كيف كانت تجربتك.' USING ERRCODE = 'P0001'; END IF;
  IF EXISTS (SELECT 1 FROM exit_surveys WHERE order_id = o.id) THEN
    RAISE EXCEPTION 'وصلنا ردك على هذا الاستبيان من قبل. شكراً لك.' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO exit_surveys (order_id, user_id, wants_renewal, reason, experience)
  VALUES (o.id, u, p_wants, left(trim(p_reason), 1000), left(trim(p_experience), 2000));
END $$;

-- المدربة: «اطّلعت عليه» يخفيه من قائمة ما يحتاج متابعة
CREATE OR REPLACE FUNCTION app.coach_mark_survey_seen(p_order_no text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_coach text := app.require_coach();
BEGIN
  UPDATE exit_surveys s SET seen_at = now() FROM orders o WHERE o.id = s.order_id AND o.order_no = p_order_no AND s.seen_at IS NULL;
END $$;

REVOKE ALL ON FUNCTION app.submit_exit_survey(text, boolean, text, text), app.coach_mark_survey_seen(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.submit_exit_survey(text, boolean, text, text), app.coach_mark_survey_seen(text) TO nav_app;

INSERT INTO schema_migrations (name) VALUES ('014_exit_survey.sql');

-- ---------- 015_status_expiry.sql ----------
-- =====================================================================
-- حالات الطلب من القائمة: «قيد الإعداد» و«تفعيل البرنامج» مباشرة بعد تأكيد الدفع، و«تم إلغاء الطلب»،
-- و«انتهى الاشتراك» تلقائياً (completed) لاشتراكات المتابعة بعد يوم انتهائها (بتوقيت الرياض).
-- =====================================================================

CREATE OR REPLACE FUNCTION app.coach_transition(
  p_order_no text, p_to text, p_note text, p_bank_confirmed boolean DEFAULT false
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_coach text := app.require_coach();
  v_order orders%ROWTYPE;
  v_ok boolean;
  v_paying boolean;
BEGIN
  SELECT * INTO v_order FROM orders WHERE order_no = p_order_no FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود.' USING ERRCODE = 'P0001'; END IF;

  v_ok := CASE
    WHEN p_to = 'cancelled' THEN v_order.status NOT IN ('completed', 'cancelled')
    -- تأكيد الدفع: إلى «قيد الإعداد»، أو «تفعيل البرنامج» مباشرة لاشتراكات المتابعة
    WHEN v_order.status IN ('awaiting_payment', 'payment_review') AND p_to = 'preparing' THEN true
    WHEN v_order.status IN ('awaiting_payment', 'payment_review') AND p_to = 'active' THEN v_order.category = 'follow'
    WHEN v_order.status = 'payment_review' THEN p_to = 'awaiting_payment'
    WHEN v_order.status = 'preparing' THEN
      (v_order.category = 'follow' AND p_to = 'active') OR
      (v_order.category = 'files' AND p_to = 'delivered') OR
      (v_order.category = 'consult' AND p_to = 'completed')
    WHEN v_order.status = 'active'    THEN p_to = 'completed'
    WHEN v_order.status = 'delivered' THEN p_to = 'completed'
    ELSE false END;
  IF NOT v_ok THEN
    RAISE EXCEPTION 'انتقال غير مسموح من هذه الحالة.' USING ERRCODE = 'P0001';
  END IF;

  v_paying := v_order.status IN ('awaiting_payment', 'payment_review') AND p_to IN ('preparing', 'active');
  IF v_paying THEN
    IF v_order.amount_due_halalas IS NULL THEN
      RAISE EXCEPTION 'حددي المبلغ أولاً.' USING ERRCODE = 'P0001';
    END IF;
    IF NOT p_bank_confirmed THEN
      RAISE EXCEPTION 'لا يُعتمد الدفع إلا بعد التأكد من وصول المبلغ في كشف الحساب.' USING ERRCODE = 'P0001';
    END IF;
    UPDATE payment_proofs SET review_status = 'approved', reviewed_by = v_coach, reviewed_at = now(),
                              review_note = nullif(p_note, '')
     WHERE order_id = v_order.id AND review_status = 'pending';
  END IF;

  IF v_order.status = 'payment_review' AND p_to = 'awaiting_payment' THEN
    IF coalesce(trim(p_note), '') = '' THEN
      RAISE EXCEPTION 'اكتبي سبب رفض الإيصال ليظهر للعميل.' USING ERRCODE = 'P0001';
    END IF;
    UPDATE payment_proofs SET review_status = 'rejected', reviewed_by = v_coach, reviewed_at = now(), review_note = p_note
     WHERE order_id = v_order.id AND review_status = 'pending';
  END IF;

  UPDATE orders SET status = p_to, updated_at = now(),
                    paid_at = CASE WHEN v_paying THEN now() ELSE paid_at END
   WHERE id = v_order.id;
  INSERT INTO order_events (order_id, from_status, to_status, actor_id, actor_role, note)
  VALUES (v_order.id, v_order.status, p_to, v_coach, 'coach', nullif(p_note, ''));
END $$;

-- انتهاء الاشتراك تلقائياً: اشتراك متابعة نشط مرّ يوم انتهائه ← «انتهى الاشتراك» (completed).
-- يُستدعى من التذكيرات المجدولة ومن لوحة الإدارة، وتكراره آمن. يرجع أرقام الطلبات التي انتهت الآن.
CREATE OR REPLACE FUNCTION app.expire_subscriptions() RETURNS text[]
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_actor text := app.require_coach();
  v_nos text[];
BEGIN
  WITH ended AS (
    UPDATE orders SET status = 'completed', updated_at = now()
     WHERE status = 'active' AND category = 'follow' AND sub_end_at IS NOT NULL
       AND (now() AT TIME ZONE 'Asia/Riyadh')::date > (sub_end_at AT TIME ZONE 'Asia/Riyadh')::date
    RETURNING id, order_no
  ), ev AS (
    INSERT INTO order_events (order_id, from_status, to_status, actor_id, actor_role, note)
    SELECT id, 'active', 'completed', NULL, 'system', 'انتهى الاشتراك تلقائياً بانتهاء مدته.' FROM ended
  )
  SELECT coalesce(array_agg(order_no), '{}') INTO v_nos FROM ended;
  IF cardinality(v_nos) > 0 THEN
    INSERT INTO admin_log (actor_id, action, target, details)
    VALUES (v_actor, 'subscription.expire', array_to_string(v_nos, ','), jsonb_build_object('count', cardinality(v_nos)));
  END IF;
  RETURN v_nos;
END $$;

REVOKE ALL ON FUNCTION app.expire_subscriptions() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.expire_subscriptions() TO nav_app;

INSERT INTO schema_migrations (name) VALUES ('015_status_expiry.sql');

-- ---------- 016_exercise_aliases.sql ----------
-- =====================================================================
-- ربط أسماء التمارين من تطبيقات خارجية (مثل Strong) بتمارين برنامج المتدرب.
-- يُحفظ الربط لكل متدرب حتى تُطابق الصورة التالية تلقائياً.
-- =====================================================================

CREATE TABLE IF NOT EXISTS exercise_aliases (
  user_id text NOT NULL REFERENCES "user" (id) ON DELETE CASCADE,
  external_name text NOT NULL CHECK (length(external_name) BETWEEN 1 AND 120),  -- الاسم بعد التطبيع
  exercise_id uuid NOT NULL REFERENCES exercises (id) ON DELETE CASCADE,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, external_name)
);
ALTER TABLE exercise_aliases ENABLE ROW LEVEL SECURITY;
CREATE POLICY exercise_aliases_read ON exercise_aliases FOR SELECT USING (app.is_coach() OR user_id = app.uid());
GRANT SELECT ON exercise_aliases TO nav_app;

-- يحفظ الربط لتمرين موجود في أحد برامج المتدرب فقط
CREATE OR REPLACE FUNCTION app.save_exercise_alias(p_name text, p_exercise uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE u text := app.require_user();
BEGIN
  IF length(coalesce(trim(p_name), '')) NOT BETWEEN 1 AND 120 THEN
    RAISE EXCEPTION 'اسم التمرين غير صالح.' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM block_items i JOIN block_days d ON d.id = i.day_id JOIN blocks b ON b.id = d.block_id
     WHERE b.user_id = u AND i.exercise_id = p_exercise) THEN
    RAISE EXCEPTION 'التمرين غير موجود في برنامجك.' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO exercise_aliases (user_id, external_name, exercise_id) VALUES (u, trim(p_name), p_exercise)
  ON CONFLICT (user_id, external_name) DO UPDATE SET exercise_id = EXCLUDED.exercise_id, updated_at = now();
END $$;

REVOKE ALL ON FUNCTION app.save_exercise_alias(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.save_exercise_alias(text, uuid) TO nav_app;

INSERT INTO schema_migrations (name) VALUES ('016_exercise_aliases.sql');

-- ---------- 017_exercise_rehab.sql ----------
-- =====================================================================
-- التصنيف التأهيلي / العلاجي للتمارين (أعمدة V–AC في ورقة «مكتبة التمارين»، وصفحة «التمارين التأهيلية»).
-- للتنظيم والتعليم فقط، ولا يُعد تشخيصاً أو خطة علاج. تقرؤه المدربة فقط (لا يظهر للمتدرب).
-- =====================================================================

ALTER TABLE exercises
  ADD COLUMN IF NOT EXISTS rehab_goal text CHECK (rehab_goal IS NULL OR length(rehab_goal) <= 300),          -- الهدف الحركي أو العلاجي
  ADD COLUMN IF NOT EXISTS rehab_phase text CHECK (rehab_phase IS NULL OR length(rehab_phase) <= 60),        -- المرحلة المقترحة
  ADD COLUMN IF NOT EXISTS rehab_load text CHECK (rehab_load IS NULL OR length(rehab_load) <= 60),           -- مستوى التحميل
  ADD COLUMN IF NOT EXISTS rehab_safety text CHECK (rehab_safety IS NULL OR length(rehab_safety) <= 1000),   -- ملاحظات السلامة
  ADD COLUMN IF NOT EXISTS rehab_evidence text CHECK (rehab_evidence IS NULL OR length(rehab_evidence) <= 1000), -- مصدر الدليل
  ADD COLUMN IF NOT EXISTS rehab_refs text CHECK (rehab_refs IS NULL OR length(rehab_refs) <= 2000),         -- روابط المراجع (يفصل بينها « | »)
  ADD COLUMN IF NOT EXISTS rehab_review text CHECK (rehab_review IS NULL OR rehab_review IN ('specialist', 'needs_review', 'not_approved')); -- حالة المراجعة العلاجية

INSERT INTO schema_migrations (name) VALUES ('017_exercise_rehab.sql');

-- ---------- 018_set_weights.sql ----------
-- =====================================================================
-- وزن لكل جولة: المتدرب يسجّل وزن كل مجموعة مع تكراراتها.
-- weights = أوزان المجموعات بنفس ترتيب reps. عمود weight يبقى = أثقل مجموعة
-- (للأرقام القياسية والسجلات القديمة). weights فارغ = نفس الوزن لكل المجموعات.
-- =====================================================================

ALTER TABLE item_logs ADD COLUMN IF NOT EXISTS weights numeric(6,2)[];

CREATE OR REPLACE FUNCTION app.log_item_sets(p_item uuid, p_week int, p_weights numeric[], p_reps int[], p_rir numeric) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_block blocks%ROWTYPE;
  v_ex uuid;
  n int := coalesce(cardinality(p_weights), 0);
BEGIN
  SELECT exercise_id INTO v_ex FROM block_items WHERE id = p_item;
  IF NOT FOUND THEN RAISE EXCEPTION 'التمرين غير موجود.' USING ERRCODE = 'P0001'; END IF;
  v_block := app.my_active_block(app.item_block(p_item));
  PERFORM app.check_week(v_block, p_week);
  IF n = 0 THEN
    DELETE FROM item_logs WHERE block_item_id = p_item AND week_no = p_week;
    RETURN;
  END IF;
  IF n > 10 OR n <> coalesce(cardinality(p_reps), 0) THEN
    RAISE EXCEPTION 'لكل جولة وزن وتكرارات.' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM unnest(p_weights) w WHERE w IS NULL OR w < 0 OR w > 1000) THEN
    RAISE EXCEPTION 'الوزن غير منطقي.' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM unnest(p_reps) r WHERE r IS NULL OR r < 0 OR r > 200) THEN
    RAISE EXCEPTION 'التكرارات غير صحيحة.' USING ERRCODE = 'P0001';
  END IF;
  IF p_rir IS NOT NULL AND (p_rir < 0 OR p_rir > 10) THEN RAISE EXCEPTION 'RIR بين 0 و 10.' USING ERRCODE = 'P0001'; END IF;
  INSERT INTO item_logs (block_item_id, week_no, exercise_id, weight, weights, reps, rir)
  VALUES (p_item, p_week, v_ex, (SELECT max(w) FROM unnest(p_weights) w), p_weights, p_reps, p_rir)
  ON CONFLICT (block_item_id, week_no) DO UPDATE
    SET weight = EXCLUDED.weight, weights = EXCLUDED.weights, reps = EXCLUDED.reps, rir = EXCLUDED.rir,
        exercise_id = EXCLUDED.exercise_id, logged_at = now();
END $$;

-- التسجيل القديم (وزن واحد لكل المجموعات) يمسح أوزان الجولات السابقة حتى لا تتعارض
CREATE OR REPLACE FUNCTION app.log_item(p_item uuid, p_week int, p_weight numeric, p_reps int[], p_rir numeric) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_block blocks%ROWTYPE;
  v_ex uuid;
BEGIN
  SELECT exercise_id INTO v_ex FROM block_items WHERE id = p_item;
  IF NOT FOUND THEN RAISE EXCEPTION 'التمرين غير موجود.' USING ERRCODE = 'P0001'; END IF;
  v_block := app.my_active_block(app.item_block(p_item));
  PERFORM app.check_week(v_block, p_week);
  IF p_weight IS NULL THEN
    DELETE FROM item_logs WHERE block_item_id = p_item AND week_no = p_week;
    RETURN;
  END IF;
  IF p_weight < 0 OR p_weight > 1000 THEN RAISE EXCEPTION 'الوزن غير منطقي.' USING ERRCODE = 'P0001'; END IF;
  IF p_reps IS NOT NULL AND (cardinality(p_reps) > 10 OR EXISTS (SELECT 1 FROM unnest(p_reps) r WHERE r IS NULL OR r < 0 OR r > 200)) THEN
    RAISE EXCEPTION 'التكرارات غير صحيحة.' USING ERRCODE = 'P0001';
  END IF;
  IF p_rir IS NOT NULL AND (p_rir < 0 OR p_rir > 10) THEN RAISE EXCEPTION 'RIR بين 0 و 10.' USING ERRCODE = 'P0001'; END IF;
  INSERT INTO item_logs (block_item_id, week_no, exercise_id, weight, reps, rir)
  VALUES (p_item, p_week, v_ex, p_weight, coalesce(p_reps, '{}'), p_rir)
  ON CONFLICT (block_item_id, week_no) DO UPDATE
    SET weight = EXCLUDED.weight, weights = NULL, reps = EXCLUDED.reps, rir = EXCLUDED.rir, exercise_id = EXCLUDED.exercise_id, logged_at = now();
END $$;

REVOKE ALL ON FUNCTION app.log_item_sets(uuid, int, numeric[], int[], numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.log_item_sets(uuid, int, numeric[], int[], numeric) TO nav_app;

INSERT INTO schema_migrations (name) VALUES ('018_set_weights.sql');

-- ---------- 019_push.sql ----------
-- =====================================================================
-- إشعارات الجوال (Web Push) للتطبيق المثبّت من المتصفح.
-- اشتراك لكل جهاز، لصاحبه فقط. الإرسال من الخادم بمفاتيح VAPID (متغيرات البيئة).
-- =====================================================================

CREATE TABLE IF NOT EXISTS push_subscriptions (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id text NOT NULL REFERENCES "user" (id) ON DELETE CASCADE,
  endpoint text NOT NULL UNIQUE CHECK (endpoint ~ '^https://' AND length(endpoint) <= 1000),
  p256dh text NOT NULL CHECK (length(p256dh) BETWEEN 20 AND 200),
  auth text NOT NULL CHECK (length(auth) BETWEEN 8 AND 100),
  device text CHECK (device IS NULL OR length(device) <= 200),
  created_at timestamptz NOT NULL DEFAULT now(),
  last_used_at timestamptz
);
CREATE INDEX IF NOT EXISTS push_subscriptions_user_idx ON push_subscriptions (user_id);
ALTER TABLE push_subscriptions ENABLE ROW LEVEL SECURITY;
-- المدربة (ومستخدم النظام للتذكيرات) تقرأ الاشتراكات للإرسال، وتحذف المنتهي منها
CREATE POLICY push_read ON push_subscriptions FOR SELECT USING (user_id = app.uid() OR app.is_coach());
CREATE POLICY push_delete ON push_subscriptions FOR DELETE USING (user_id = app.uid() OR app.is_coach());
GRANT UPDATE (last_used_at) ON push_subscriptions TO nav_app;
CREATE POLICY push_touch ON push_subscriptions FOR UPDATE USING (app.is_coach()) WITH CHECK (app.is_coach());
GRANT SELECT, DELETE ON push_subscriptions TO nav_app;

-- الاشتراك/التحديث عبر دالة: نفس الجهاز (endpoint) ينتقل لآخر مستخدم سجّل دخوله عليه
CREATE OR REPLACE FUNCTION app.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text, p_device text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE u text := app.require_user();
BEGIN
  INSERT INTO push_subscriptions (user_id, endpoint, p256dh, auth, device) VALUES (u, p_endpoint, p_p256dh, p_auth, left(p_device, 200))
  ON CONFLICT (endpoint) DO UPDATE SET user_id = u, p256dh = EXCLUDED.p256dh, auth = EXCLUDED.auth, device = EXCLUDED.device, created_at = now();
END $$;
REVOKE ALL ON FUNCTION app.save_push_subscription(text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.save_push_subscription(text, text, text, text) TO nav_app;

ALTER TABLE user_prefs ADD COLUMN IF NOT EXISTS push_enabled boolean NOT NULL DEFAULT true;

ALTER TABLE notification_log DROP CONSTRAINT IF EXISTS notification_log_channel_check;
ALTER TABLE notification_log ADD CONSTRAINT notification_log_channel_check CHECK (channel IN ('email', 'whatsapp', 'push'));

INSERT INTO schema_migrations (name) VALUES ('019_push.sql');

-- ---------- 020_calorie_profile.sql ----------
-- =====================================================================
-- السعرات المقترحة: بيانات حساب السعرات لكل اشتراك (حاسبة Henselmans في الموقع).
-- المتدرب يحدّث الطول والنشاط وأيام التمرين؛ الموقع يقترح سعرات جديدة، والمدربة تعتمد أو تتجاهل.
-- + سجل الإيميل اليومي للمدربة (مرة واحدة لكل يوم).
-- =====================================================================

CREATE TABLE IF NOT EXISTS calorie_profiles (
  order_id uuid PRIMARY KEY REFERENCES orders (id) ON DELETE CASCADE,
  method text NOT NULL DEFAULT 'tenhaaf' CHECK (method IN ('cunningham', 'tenhaaf', 'tinsley')),
  sex text CHECK (sex IS NULL OR sex IN ('male', 'female')),
  age int CHECK (age IS NULL OR age BETWEEN 10 AND 90),
  height_cm numeric(5,1) CHECK (height_cm IS NULL OR height_cm BETWEEN 120 AND 230),
  body_fat numeric(4,1) CHECK (body_fat IS NULL OR body_fat BETWEEN 3 AND 60),
  paf numeric(3,2) NOT NULL DEFAULT 1.1 CHECK (paf BETWEEN 1 AND 2),
  training_days int NOT NULL DEFAULT 3 CHECK (training_days BETWEEN 0 AND 7),
  minutes int NOT NULL DEFAULT 60 CHECK (minutes BETWEEN 0 AND 240),
  eb_factor numeric(3,2) NOT NULL DEFAULT 1 CHECK (eb_factor BETWEEN 0.6 AND 1.3),
  dismissed_kcal int,                                   -- آخر اقتراح تجاهلته المدربة (لا يتكرر نفس الرقم)
  updated_by text REFERENCES "user" (id) ON DELETE SET NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE calorie_profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY calprof_read ON calorie_profiles FOR SELECT USING (app.is_coach() OR app.owns_order(order_id));
CREATE POLICY calprof_coach_write ON calorie_profiles FOR ALL USING (app.is_coach()) WITH CHECK (app.is_coach());
GRANT SELECT, INSERT, UPDATE ON calorie_profiles TO nav_app;

-- المتدرب يحدّث بياناته (الطول والنشاط وأيام التمرين ومدته) لاشتراكه الفعّال فقط.
-- p_sex / p_age / p_eb: قيم البداية من الاستبيان، تُستخدم فقط عند إنشاء الملف أول مرة (لا تغيّر ما عدّلته المدربة)
CREATE OR REPLACE FUNCTION app.update_my_calorie_profile(p_order_no text, p_height numeric, p_paf numeric, p_days int, p_minutes int,
  p_sex text, p_age int, p_eb numeric) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  u text := app.require_user();
  v_order uuid;
BEGIN
  SELECT id INTO v_order FROM orders WHERE order_no = p_order_no AND user_id = u AND status IN ('active', 'delivered');
  IF v_order IS NULL THEN RAISE EXCEPTION 'الطلب غير موجود أو غير فعّال.' USING ERRCODE = 'P0001'; END IF;
  IF p_height IS NOT NULL AND (p_height < 120 OR p_height > 230) THEN RAISE EXCEPTION 'الطول بين 120 و 230 سم.' USING ERRCODE = 'P0001'; END IF;
  IF p_paf IS NULL OR p_paf NOT IN (1.0, 1.1, 1.2, 1.3, 1.4) THEN RAISE EXCEPTION 'اختر مستوى نشاطك.' USING ERRCODE = 'P0001'; END IF;
  IF p_days IS NULL OR p_days NOT BETWEEN 0 AND 7 THEN RAISE EXCEPTION 'أيام التمرين من 0 إلى 7.' USING ERRCODE = 'P0001'; END IF;
  IF p_minutes IS NULL OR p_minutes NOT BETWEEN 0 AND 240 THEN RAISE EXCEPTION 'مدة التمرين بين 0 و 240 دقيقة.' USING ERRCODE = 'P0001'; END IF;
  INSERT INTO calorie_profiles (order_id, sex, age, eb_factor, height_cm, paf, training_days, minutes, updated_by)
  VALUES (v_order, CASE WHEN p_sex IN ('male', 'female') THEN p_sex END, CASE WHEN p_age BETWEEN 10 AND 90 THEN p_age END,
          CASE WHEN p_eb BETWEEN 0.6 AND 1.3 THEN p_eb ELSE 1 END, p_height, p_paf, p_days, p_minutes, u)
  ON CONFLICT (order_id) DO UPDATE SET height_cm = coalesce(EXCLUDED.height_cm, calorie_profiles.height_cm), paf = EXCLUDED.paf,
    training_days = EXCLUDED.training_days, minutes = EXCLUDED.minutes, updated_by = u, updated_at = now();
END $$;
REVOKE ALL ON FUNCTION app.update_my_calorie_profile(text, numeric, numeric, int, int, text, int, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.update_my_calorie_profile(text, numeric, numeric, int, int, text, int, numeric) TO nav_app;

-- الإيميل اليومي للمدربة: صف لكل يوم أُرسل فيه (يمنع التكرار مع تشغيل التذكيرات كل ساعة)
CREATE TABLE IF NOT EXISTS coach_digests (
  day date PRIMARY KEY,
  sent_at timestamptz NOT NULL DEFAULT now(),
  items int NOT NULL DEFAULT 0
);
ALTER TABLE coach_digests ENABLE ROW LEVEL SECURITY;
CREATE POLICY digests_coach ON coach_digests FOR ALL USING (app.is_coach()) WITH CHECK (app.is_coach());
GRANT SELECT, INSERT ON coach_digests TO nav_app;

INSERT INTO schema_migrations (name) VALUES ('020_calorie_profile.sql');

-- ---------- 021_start_pref.sql ----------
-- =====================================================================
-- موعد بداية البرنامج يختاره المتدرب: «بأقرب وقت» (NULL) أو تاريخ خلال 31 يوماً.
-- عند التفعيل يبدأ الاشتراك (وعدّاد الأشهر والمراجعات) من التاريخ المختار.
-- =====================================================================

ALTER TABLE orders ADD COLUMN IF NOT EXISTS preferred_start date;

-- المتدرب صاحب الطلب يحدد/يغيّر الموعد قبل التفعيل فقط
CREATE OR REPLACE FUNCTION app.set_my_start_pref(p_order_no text, p_date date) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  u text := app.require_user();
  today date := (now() AT TIME ZONE 'Asia/Riyadh')::date;
  v_order uuid;
BEGIN
  SELECT id INTO v_order FROM orders
   WHERE order_no = p_order_no AND user_id = u AND status IN ('awaiting_quote', 'awaiting_payment', 'payment_review', 'preparing');
  IF v_order IS NULL THEN RAISE EXCEPTION 'لا يمكن تغيير موعد البداية لهذا الطلب.' USING ERRCODE = 'P0001'; END IF;
  IF p_date IS NOT NULL AND (p_date <= today OR p_date > today + 31) THEN
    RAISE EXCEPTION 'اختر تاريخاً من بكرة إلى شهر من اليوم.' USING ERRCODE = 'P0001';
  END IF;
  UPDATE orders SET preferred_start = p_date WHERE id = v_order;
END $$;
REVOKE ALL ON FUNCTION app.set_my_start_pref(text, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.set_my_start_pref(text, date) TO nav_app;

-- عند التفعيل: البداية = الأبعد من (الآن، نهاية الاشتراك السابق للتجديد، الموعد المختار)
CREATE OR REPLACE FUNCTION app.set_subscription_dates() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_start timestamptz := now();
BEGIN
  IF NEW.status = 'active' AND OLD.status IS DISTINCT FROM 'active' AND NEW.months > 0 AND NEW.sub_start_at IS NULL THEN
    IF NEW.renewal_of IS NOT NULL THEN
      SELECT greatest(now(), coalesce(max(o.sub_end_at), now())) INTO v_start
        FROM orders o
       WHERE o.user_id = NEW.user_id AND o.id <> NEW.id AND o.category = 'follow'
         AND o.status IN ('active', 'delivered', 'completed') AND o.sub_end_at IS NOT NULL
         AND (o.id = NEW.renewal_of OR o.renewal_of = NEW.renewal_of);
    END IF;
    IF NEW.preferred_start IS NOT NULL THEN
      v_start := greatest(v_start, NEW.preferred_start::timestamp AT TIME ZONE 'Asia/Riyadh');
    END IF;
    NEW.sub_start_at := v_start;
    NEW.sub_end_at := v_start + make_interval(months => NEW.months);
    NEW.review_weekday := coalesce(NEW.review_weekday,
      (SELECT o.review_weekday FROM orders o WHERE o.id = NEW.renewal_of),
      extract(dow FROM (v_start AT TIME ZONE 'Asia/Riyadh'))::smallint);
  END IF;
  RETURN NEW;
END $$;

INSERT INTO schema_migrations (name) VALUES ('021_start_pref.sql');

-- ---------- 022_checkin_video.sql ----------
-- =====================================================================
-- فيديو شرح المراجعة الأسبوعية: المدربة تضيف رابط فيديو مع ردها على مراجعة المتدرب،
-- والخانة تظهر فقط للباقات المفعّل فيها «مراجعة بالفيديو».
-- =====================================================================

ALTER TABLE products ADD COLUMN IF NOT EXISTS video_review boolean NOT NULL DEFAULT false;

ALTER TABLE check_ins ADD COLUMN IF NOT EXISTS coach_video_url text
  CHECK (coach_video_url IS NULL OR (coach_video_url ~ '^https://' AND length(coach_video_url) <= 500));

-- الرد: نص و/أو رابط فيديو (واحد منهما على الأقل)
CREATE OR REPLACE FUNCTION app.reply_checkin(p_id uuid, p_reply text, p_video text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_video text := nullif(trim(coalesce(p_video, '')), '');
BEGIN
  PERFORM app.require_coach();
  IF v_video IS NOT NULL AND (v_video !~ '^https://' OR length(v_video) > 500) THEN
    RAISE EXCEPTION 'رابط الفيديو لازم يبدأ بـ https://' USING ERRCODE = 'P0001';
  END IF;
  IF nullif(trim(coalesce(p_reply, '')), '') IS NULL AND v_video IS NULL THEN
    RAISE EXCEPTION 'اكتبي الرد أو أضيفي رابط الفيديو.' USING ERRCODE = 'P0001';
  END IF;
  UPDATE check_ins SET coach_reply = nullif(trim(coalesce(p_reply, '')), ''), coach_video_url = v_video, replied_at = now() WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'المراجعة غير موجودة.' USING ERRCODE = 'P0001'; END IF;
END $$;
REVOKE ALL ON FUNCTION app.reply_checkin(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.reply_checkin(uuid, text, text) TO nav_app;

INSERT INTO schema_migrations (name) VALUES ('022_checkin_video.sql');

-- ---------- 023_coach_message.sql ----------
-- =====================================================================
-- رسالة من المدربة للمتدرب: تُحفظ كتحديث ظاهر للمتدرب في صفحة طلبه (order_events)
-- بدون تغيير حالة الطلب (from_status = to_status = الحالة الحالية).
-- =====================================================================

CREATE OR REPLACE FUNCTION app.coach_message(p_order_no text, p_text text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid text := app.require_coach();
  v_order orders%ROWTYPE;
  v_text text := trim(coalesce(p_text, ''));
BEGIN
  IF length(v_text) < 2 OR length(v_text) > 2000 THEN
    RAISE EXCEPTION 'اكتبي الرسالة (حتى 2000 حرف).' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_order FROM orders WHERE order_no = p_order_no;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  INSERT INTO order_events (order_id, from_status, to_status, actor_id, actor_role, note, client_visible)
  VALUES (v_order.id, v_order.status, v_order.status, v_uid, 'coach', v_text, true);
END $$;
REVOKE ALL ON FUNCTION app.coach_message(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.coach_message(text, text) TO nav_app;

INSERT INTO schema_migrations (name) VALUES ('023_coach_message.sql');

-- ---------- 024_weekly_subscriptions.sql ----------
-- =====================================================================
-- مدة الاشتراك بالأسابيع من أول يوم: الشهر = 4 أسابيع (28 يوماً)، ويوم المراجعة = يوم البداية من الأسبوع،
-- فتكون المراجعة كل 7 أيام من أول يوم (الأسبوع 1 = الأيام 1–7). للاشتراكات الجديدة فقط؛ القائمة لا تتغير.
-- =====================================================================

CREATE OR REPLACE FUNCTION app.set_subscription_dates() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_start timestamptz := now();
BEGIN
  IF NEW.status = 'active' AND OLD.status IS DISTINCT FROM 'active' AND NEW.months > 0 AND NEW.sub_start_at IS NULL THEN
    IF NEW.renewal_of IS NOT NULL THEN
      SELECT greatest(now(), coalesce(max(o.sub_end_at), now())) INTO v_start
        FROM orders o
       WHERE o.user_id = NEW.user_id AND o.id <> NEW.id AND o.category = 'follow'
         AND o.status IN ('active', 'delivered', 'completed') AND o.sub_end_at IS NOT NULL
         AND (o.id = NEW.renewal_of OR o.renewal_of = NEW.renewal_of);
    END IF;
    IF NEW.preferred_start IS NOT NULL THEN
      v_start := greatest(v_start, NEW.preferred_start::timestamp AT TIME ZONE 'Asia/Riyadh');
    END IF;
    NEW.sub_start_at := v_start;
    NEW.sub_end_at := v_start + make_interval(days => 28 * NEW.months);
    -- التجديد يكمل على نفس يوم المراجعة السابق؛ غير ذلك يوم البداية
    NEW.review_weekday := coalesce(NEW.review_weekday,
      (SELECT o.review_weekday FROM orders o WHERE o.id = NEW.renewal_of),
      extract(dow FROM (v_start AT TIME ZONE 'Asia/Riyadh'))::smallint);
  END IF;
  RETURN NEW;
END $$;

INSERT INTO schema_migrations (name) VALUES ('024_weekly_subscriptions.sql');

-- ---------- 025_auto_kcal.sql ----------
-- =====================================================================
-- السعرات التلقائية: عند توفر بيانات المتدرب يُحسب هدف السعرات بحاسبة الموقع ويُحفظ تلقائياً
-- ويظهر للمدربة بشارة «بانتظار تأكيدك» حتى تؤكد الحسبة أو تعدّل الرقم.
-- kcal_source: auto = حسبة تلقائية، coach = أدخلته أو اعتمدته المدربة.
-- =====================================================================
ALTER TABLE nutrition_targets
  ADD COLUMN kcal_source text NOT NULL DEFAULT 'coach' CHECK (kcal_source IN ('auto', 'coach')),
  ADD COLUMN kcal_confirmed_at timestamptz;

-- الأهداف الموجودة أدخلتها المدربة، فتُعتبر مؤكدة
UPDATE nutrition_targets SET kcal_confirmed_at = updated_at WHERE kcal IS NOT NULL;

INSERT INTO schema_migrations (name) VALUES ('025_auto_kcal.sql');

-- ---------- 026_booklets.sql ----------
-- =====================================================================
-- الكتيبات: ملفات PDF ترفعها المدربة، ويحمّلها كل متدرب عنده اشتراك (نشط، تم التسليم، مكتمل).
-- الملف في التخزين الخاص، والتحميل عبر /api/booklets/[id] بعد تحقق RLS.
-- =====================================================================
CREATE TABLE booklets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL CHECK (length(trim(title)) BETWEEN 2 AND 120),
  description text CHECK (description IS NULL OR length(description) <= 300),
  file_key text NOT NULL,
  file_size int NOT NULL CHECK (file_size > 0),
  file_sha256 text NOT NULL,
  published boolean NOT NULL DEFAULT true,
  sort int NOT NULL DEFAULT 0,
  created_by text REFERENCES "user" (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- هل للمستخدم الحالي اشتراك يخوّله تحميل الكتيبات؟
CREATE OR REPLACE FUNCTION app.has_program() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM orders WHERE user_id = app.uid() AND status IN ('active', 'delivered', 'completed'));
$$;

ALTER TABLE booklets ENABLE ROW LEVEL SECURITY;
CREATE POLICY booklets_read ON booklets FOR SELECT USING (app.is_coach() OR (published AND app.has_program()));
CREATE POLICY booklets_write ON booklets FOR ALL USING (app.is_coach()) WITH CHECK (app.is_coach());
GRANT SELECT, INSERT, UPDATE, DELETE ON booklets TO nav_app;
GRANT EXECUTE ON FUNCTION app.has_program() TO nav_app;

INSERT INTO schema_migrations (name) VALUES ('026_booklets.sql');

-- ---------- 027_auto_kcal_hidden.sql ----------
-- =====================================================================
-- السعرات المحسوبة تلقائياً لا يراها المتدرب حتى تؤكدها المدربة.
-- السطر التلقائي فيه السعرات فقط (بدون ماكروز أو قواعد)، فيُخفى كاملاً عن المتدرب؛ المدربة ترى الكل.
-- =====================================================================
DROP POLICY targets_read ON nutrition_targets;
CREATE POLICY targets_read ON nutrition_targets FOR SELECT USING (
  app.is_coach() OR (app.order_entitled(order_id) AND (kcal_source <> 'auto' OR kcal_confirmed_at IS NOT NULL))
);

INSERT INTO schema_migrations (name) VALUES ('027_auto_kcal_hidden.sql');

-- ---------- 028_food_details.sql ----------
-- =====================================================================
-- تفاصيل مصادر الأكل: نوع المصدر (لحوم حمراء، دواجن، أسماك، بقوليات...) والألياف والفيتامينات والمعادن لكل 100غ.
-- القيم من USDA FoodData Central (SR Legacy) عبر source_ref، والتعبئة في ملف البيانات (scripts/foods-sql.mjs).
-- micros: vit_a, vit_c, vit_d, vit_e, vit_k, vit_b6, vit_b12, folate (ميكروغرام/ملغ حسب USDA)، iron, calcium, potassium, magnesium, zinc.
-- =====================================================================
ALTER TABLE foods
  ADD COLUMN source_type text CHECK (source_type IS NULL OR length(source_type) <= 60),
  ADD COLUMN fiber_100 numeric(6,1) CHECK (fiber_100 IS NULL OR fiber_100 BETWEEN 0 AND 100),
  ADD COLUMN micros jsonb CHECK (micros IS NULL OR jsonb_typeof(micros) = 'object');
CREATE INDEX foods_source_type_idx ON foods (active, source_type);

INSERT INTO schema_migrations (name) VALUES ('028_food_details.sql');

-- ---------- 029_library_meals.sql ----------
-- =====================================================================
-- المتدرب يختار أي وجبة من وجبات قوالب التغذية (مو بس من جداوله):
-- - app.library_meals(): وجبات القوالب غير المخفية بمجاميعها (اسم الوجبة والماكروز فقط، بدون طريقة التحضير)، لمن عنده اشتراك.
-- - app.log_food: تقبل وجبة من جداوله أو من قالب. الماكروز تُحسب في القاعدة من مكونات الوجبة، والتسجيل يحفظ نسخة منها.
-- =====================================================================
CREATE OR REPLACE FUNCTION app.library_meals()
RETURNS TABLE (meal_id uuid, plan_name text, kind text, title text, protein numeric, carbs numeric, fat numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT DISTINCT ON (m.title, t.protein, t.carbs, t.fat) m.id, p.name, m.kind, m.title, t.protein, t.carbs, t.fat
    FROM plan_meals m
    JOIN nutrition_plans p ON p.id = m.plan_id AND p.order_id IS NULL AND NOT p.archived
    JOIN LATERAL (SELECT coalesce(sum(i.protein), 0) AS protein, coalesce(sum(i.carbs), 0) AS carbs, coalesce(sum(i.fat), 0) AS fat
                    FROM plan_items i WHERE i.meal_id = m.id) t ON true
   WHERE app.is_coach() OR app.has_program()
   ORDER BY m.title, t.protein, t.carbs, t.fat, p.position, m.position;
$$;
REVOKE ALL ON FUNCTION app.library_meals() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.library_meals() TO nav_app;

-- الوجبة من جداول المتدرب أو من قوالب التغذية (وجبات جداول متدربين آخرين مرفوضة)
CREATE OR REPLACE FUNCTION app.log_food(p_order_no text, p_date date, p_kind text, p_meal uuid,
                                        p_name text, p_protein numeric, p_carbs numeric, p_fat numeric) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  u text := app.require_user();
  v_order uuid;
  today date := (now() AT TIME ZONE 'Asia/Riyadh')::date;
  v_name text; v_p numeric; v_c numeric; v_f numeric; v_kind text := p_kind;
  v_id bigint;
BEGIN
  SELECT id INTO v_order FROM orders WHERE order_no = p_order_no AND user_id = u;
  IF NOT FOUND OR NOT app.order_entitled(v_order) THEN RAISE EXCEPTION 'الطلب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  IF p_date IS NULL OR p_date > today OR p_date < today - 60 THEN RAISE EXCEPTION 'التاريخ غير صحيح.' USING ERRCODE = 'P0001'; END IF;
  IF p_meal IS NOT NULL THEN
    SELECT m.title, m.kind, coalesce(sum(i.protein), 0), coalesce(sum(i.carbs), 0), coalesce(sum(i.fat), 0)
      INTO v_name, v_kind, v_p, v_c, v_f
      FROM plan_meals m JOIN nutrition_plans p ON p.id = m.plan_id LEFT JOIN plan_items i ON i.meal_id = m.id
     WHERE m.id = p_meal AND (p.order_id = v_order OR p.order_id IS NULL) AND NOT p.archived
     GROUP BY m.id;
    IF NOT FOUND THEN RAISE EXCEPTION 'الوجبة غير موجودة.' USING ERRCODE = 'P0001'; END IF;
    v_name := (SELECT name FROM nutrition_plans WHERE id = app.meal_plan(p_meal)) || ' — ' || v_name;
    v_kind := coalesce(p_kind, v_kind);
  ELSE
    v_name := nullif(trim(coalesce(p_name, '')), '');
    IF v_name IS NULL THEN RAISE EXCEPTION 'اكتب اسم الأكلة.' USING ERRCODE = 'P0001'; END IF;
    v_p := coalesce(p_protein, 0); v_c := coalesce(p_carbs, 0); v_f := coalesce(p_fat, 0);
    IF v_p < 0 OR v_c < 0 OR v_f < 0 OR v_p > 500 OR v_c > 500 OR v_f > 300 THEN
      RAISE EXCEPTION 'أرقام الماكروز غير منطقية.' USING ERRCODE = 'P0001';
    END IF;
    IF v_p + v_c + v_f = 0 THEN RAISE EXCEPTION 'اكتب البروتين أو الكارب أو الدهون.' USING ERRCODE = 'P0001'; END IF;
  END IF;
  IF v_kind NOT IN ('breakfast', 'lunch', 'dinner', 'snack') THEN RAISE EXCEPTION 'اختر الوجبة.' USING ERRCODE = 'P0001'; END IF;
  IF (SELECT count(*) FROM food_logs WHERE user_id = u AND log_date = p_date) >= 30 THEN
    RAISE EXCEPTION 'وصلت الحد الأعلى لتسجيلات اليوم.' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO food_logs (user_id, order_id, log_date, kind, meal_id, name, protein, carbs, fat)
  VALUES (u, v_order, p_date, v_kind, p_meal, left(v_name, 160), round(v_p, 1), round(v_c, 1), round(v_f, 1))
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

INSERT INTO schema_migrations (name) VALUES ('029_library_meals.sql');

-- ---------- 030_meal_library_plan.sql ----------
-- =====================================================================
-- مكتبة الوجبات: جدول خاص (is_library) يحمل كل الوصفات كوجبات ليختار منها المتدرب في «كل الوجبات».
-- لا يظهر ضمن القوالب المقترحة ولا قائمة إسناد الجداول. وتسجيل وجبة قالب/مكتبة يحفظ اسم الوجبة فقط.
-- =====================================================================
ALTER TABLE nutrition_plans ADD COLUMN is_library boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION app.log_food(p_order_no text, p_date date, p_kind text, p_meal uuid,
                                        p_name text, p_protein numeric, p_carbs numeric, p_fat numeric) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  u text := app.require_user();
  v_order uuid;
  today date := (now() AT TIME ZONE 'Asia/Riyadh')::date;
  v_name text; v_tpl boolean; v_p numeric; v_c numeric; v_f numeric; v_kind text := p_kind;
  v_id bigint;
BEGIN
  SELECT id INTO v_order FROM orders WHERE order_no = p_order_no AND user_id = u;
  IF NOT FOUND OR NOT app.order_entitled(v_order) THEN RAISE EXCEPTION 'الطلب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  IF p_date IS NULL OR p_date > today OR p_date < today - 60 THEN RAISE EXCEPTION 'التاريخ غير صحيح.' USING ERRCODE = 'P0001'; END IF;
  IF p_meal IS NOT NULL THEN
    SELECT m.title, m.kind, (p.order_id IS NULL), coalesce(sum(i.protein), 0), coalesce(sum(i.carbs), 0), coalesce(sum(i.fat), 0)
      INTO v_name, v_kind, v_tpl, v_p, v_c, v_f
      FROM plan_meals m JOIN nutrition_plans p ON p.id = m.plan_id LEFT JOIN plan_items i ON i.meal_id = m.id
     WHERE m.id = p_meal AND (p.order_id = v_order OR p.order_id IS NULL) AND NOT p.archived
     GROUP BY m.id, p.order_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'الوجبة غير موجودة.' USING ERRCODE = 'P0001'; END IF;
    -- وجبة من مكتبة الوجبات (قالب): الاسم بس؛ من جدول المتدرب: «الجدول — الوجبة»
    IF NOT v_tpl THEN v_name := (SELECT name FROM nutrition_plans WHERE id = app.meal_plan(p_meal)) || ' — ' || v_name; END IF;
    v_kind := coalesce(p_kind, v_kind);
  ELSE
    v_name := nullif(trim(coalesce(p_name, '')), '');
    IF v_name IS NULL THEN RAISE EXCEPTION 'اكتب اسم الأكلة.' USING ERRCODE = 'P0001'; END IF;
    v_p := coalesce(p_protein, 0); v_c := coalesce(p_carbs, 0); v_f := coalesce(p_fat, 0);
    IF v_p < 0 OR v_c < 0 OR v_f < 0 OR v_p > 500 OR v_c > 500 OR v_f > 300 THEN
      RAISE EXCEPTION 'أرقام الماكروز غير منطقية.' USING ERRCODE = 'P0001';
    END IF;
    IF v_p + v_c + v_f = 0 THEN RAISE EXCEPTION 'اكتب البروتين أو الكارب أو الدهون.' USING ERRCODE = 'P0001'; END IF;
  END IF;
  IF v_kind NOT IN ('breakfast', 'lunch', 'dinner', 'snack') THEN RAISE EXCEPTION 'اختر الوجبة.' USING ERRCODE = 'P0001'; END IF;
  IF (SELECT count(*) FROM food_logs WHERE user_id = u AND log_date = p_date) >= 30 THEN
    RAISE EXCEPTION 'وصلت الحد الأعلى لتسجيلات اليوم.' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO food_logs (user_id, order_id, log_date, kind, meal_id, name, protein, carbs, fat)
  VALUES (u, v_order, p_date, v_kind, p_meal, left(v_name, 160), round(v_p, 1), round(v_c, 1), round(v_f, 1))
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

INSERT INTO schema_migrations (name) VALUES ('030_meal_library_plan.sql');

-- ---------- 031_free_orders.sql ----------
-- =====================================================================
-- قبول الطلب مجاناً: خيار في «تحديث الحالة». المبلغ 0 بدون دفع ولا إيصال، ويتفعّل الاشتراك فقط في المدة اللي تحددها المدربة
-- (تاريخ بداية ونهاية). يبقى نشطاً حتى نهاية تاريخ النهاية ثم ينتهي تلقائياً مثل باقي الاشتراكات (app.expire_subscriptions).
-- للملفات والاستشارات: يتحول لـ «قيد الإعداد» بدون دفع.
-- =====================================================================
ALTER TABLE orders ADD COLUMN is_free boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION app.coach_accept_free(p_order_no text, p_start date, p_end date, p_note text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_coach text := app.require_coach();
  v_order orders%ROWTYPE;
  v_to text;
  today date := (now() AT TIME ZONE 'Asia/Riyadh')::date;
  v_start timestamptz; v_end timestamptz;
BEGIN
  SELECT * INTO v_order FROM orders WHERE order_no = p_order_no FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  IF v_order.status NOT IN ('awaiting_quote', 'awaiting_payment', 'payment_review') THEN
    RAISE EXCEPTION 'القبول المجاني قبل الدفع فقط.' USING ERRCODE = 'P0001';
  END IF;

  IF v_order.category = 'follow' THEN
    IF p_start IS NULL OR p_end IS NULL THEN RAISE EXCEPTION 'حددي تاريخ بداية ونهاية الاشتراك المجاني.' USING ERRCODE = 'P0001'; END IF;
    IF p_end < p_start THEN RAISE EXCEPTION 'تاريخ النهاية لازم يكون بعد تاريخ البداية أو يساويه.' USING ERRCODE = 'P0001'; END IF;
    IF p_end < today THEN RAISE EXCEPTION 'تاريخ النهاية مضى. اختاري تاريخاً من اليوم فصاعداً.' USING ERRCODE = 'P0001'; END IF;
    IF p_end - p_start > 366 THEN RAISE EXCEPTION 'المدة أطول من سنة.' USING ERRCODE = 'P0001'; END IF;
    v_to := 'active';
    v_start := p_start::timestamp AT TIME ZONE 'Asia/Riyadh';
    v_end := (p_end::timestamp AT TIME ZONE 'Asia/Riyadh') + interval '12 hours'; -- نشط طوال يوم النهاية
  ELSE
    v_to := 'preparing';
  END IF;

  UPDATE payment_proofs SET review_status = 'rejected', reviewed_by = v_coach, reviewed_at = now(), review_note = 'طلب مجاني — ما يحتاج دفع'
   WHERE order_id = v_order.id AND review_status = 'pending';

  UPDATE orders SET is_free = true, amount_due_halalas = 0, status = v_to, updated_at = now(),
                    sub_start_at = coalesce(v_start, sub_start_at), sub_end_at = coalesce(v_end, sub_end_at),
                    review_weekday = CASE WHEN v_start IS NULL THEN review_weekday
                                          ELSE extract(dow FROM (v_start AT TIME ZONE 'Asia/Riyadh'))::smallint END
   WHERE id = v_order.id;

  INSERT INTO order_events (order_id, from_status, to_status, actor_id, actor_role, note)
  VALUES (v_order.id, v_order.status, v_to, v_coach, 'coach',
          'قبول مجاني' || CASE WHEN v_start IS NULL THEN '' ELSE ' من ' || p_start || ' إلى ' || p_end END
          || CASE WHEN coalesce(trim(p_note), '') = '' THEN '' ELSE ' — ' || trim(p_note) END);
  INSERT INTO admin_log (actor_id, action, target, details)
  VALUES (v_coach, 'order.free', p_order_no, jsonb_build_object('start', p_start, 'end', p_end, 'from', v_order.status));
END $$;

REVOKE ALL ON FUNCTION app.coach_accept_free(text, date, date, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.coach_accept_free(text, date, date, text) TO nav_app;

INSERT INTO schema_migrations (name) VALUES ('031_free_orders.sql');

-- ---------- 032_delete_block_member.sql ----------
-- =====================================================================
-- حذف برنامج أُضيف بالخطأ، وحذف عضو مسجّل. كلاهما للمدربة فقط، وقاعدة البيانات تمنع حذف ما له بيانات فعلية:
-- - البرنامج: يُحذف مع أيامه وتمارينه وملاحظاته فقط إذا ما سجّل المتدرب عليه أي تمرين (وإلا: «إنهاء البرنامج»).
-- - العضو: فقط إذا ما عنده أي طلب (الطلبات سجلات مالية لا تُحذف). حساب المدربة لا يُحذف أبداً.
-- =====================================================================

CREATE OR REPLACE FUNCTION app.coach_delete_block(p_block uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_coach text := app.require_coach();
  v_b blocks%ROWTYPE;
  v_order text;
BEGIN
  SELECT * INTO v_b FROM blocks WHERE id = p_block;
  IF NOT FOUND THEN RAISE EXCEPTION 'البرنامج غير موجود.' USING ERRCODE = 'P0001'; END IF;
  IF EXISTS (SELECT 1 FROM item_logs l JOIN block_items i ON i.id = l.block_item_id JOIN block_days d ON d.id = i.day_id WHERE d.block_id = p_block) THEN
    RAISE EXCEPTION 'المتدرب سجّل على هذا البرنامج، فلا يُحذف. استخدمي «إنهاء البرنامج».' USING ERRCODE = 'P0001';
  END IF;
  SELECT order_no INTO v_order FROM orders WHERE id = v_b.order_id;
  INSERT INTO admin_log (actor_id, action, target, details)
  VALUES (v_coach, 'block.delete', v_order, jsonb_build_object('name', v_b.name, 'start', v_b.start_date, 'status', v_b.status));
  DELETE FROM blocks WHERE id = p_block;
  RETURN v_order;
END $$;

CREATE OR REPLACE FUNCTION app.coach_delete_member(p_user text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_coach text := app.require_coach();
  v_u "user"%ROWTYPE;
BEGIN
  SELECT * INTO v_u FROM "user" WHERE id = p_user;
  IF NOT FOUND THEN RAISE EXCEPTION 'العضو غير موجود.' USING ERRCODE = 'P0001'; END IF;
  IF v_u.role IS DISTINCT FROM 'client' THEN RAISE EXCEPTION 'لا يمكن حذف حساب المدربة.' USING ERRCODE = 'P0001'; END IF;
  IF EXISTS (SELECT 1 FROM orders WHERE user_id = p_user) THEN
    RAISE EXCEPTION 'عند العضو طلبات مسجّلة، فلا يُحذف حسابه (الطلبات سجلات مالية).' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO admin_log (actor_id, action, target, details)
  VALUES (v_coach, 'member.delete', v_u.email, jsonb_build_object('name', v_u.name));
  DELETE FROM "user" WHERE id = p_user;
  RETURN v_u.email;
END $$;

REVOKE ALL ON FUNCTION app.coach_delete_block(uuid), app.coach_delete_member(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.coach_delete_block(uuid), app.coach_delete_member(text) TO nav_app;

INSERT INTO schema_migrations (name) VALUES ('032_delete_block_member.sql');

-- ---------- 033_member_profile_delete_orders.sql ----------
-- =====================================================================
-- 1) حذف عضو حتى لو عنده طلبات (حسابات تجربة الموقع والباقات). للمدربة فقط، ويُسجَّل في admin_log مع أرقام الطلبات.
--    حساب المدربة لا يُحذف أبداً. حذف الطلبات يحذف تبعاتها (استبيان، إيصالات، برامج، سجلات)، والعملية لا رجعة فيها.
-- 2) استبيان العضو بدون طلب: member_profiles. يعبّيه أو يحدّثه العضو من «بياناتي» (للمسجّلين بجدول مجاني بلا طلب).
-- =====================================================================

-- يرجع {email, keys}: مفاتيح ملفات الإيصالات والتسليمات لحذفها من التخزين
DROP FUNCTION IF EXISTS app.coach_delete_member(text);
CREATE FUNCTION app.coach_delete_member(p_user text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_coach text := app.require_coach();
  v_u "user"%ROWTYPE;
  v_orders text[];
  v_keys text[];
BEGIN
  SELECT * INTO v_u FROM "user" WHERE id = p_user;
  IF NOT FOUND THEN RAISE EXCEPTION 'العضو غير موجود.' USING ERRCODE = 'P0001'; END IF;
  IF v_u.role IS DISTINCT FROM 'client' THEN RAISE EXCEPTION 'لا يمكن حذف حساب المدربة.' USING ERRCODE = 'P0001'; END IF;
  SELECT coalesce(array_agg(order_no ORDER BY created_at), '{}') INTO v_orders FROM orders WHERE user_id = p_user;
  SELECT coalesce(array_agg(k), '{}') INTO v_keys FROM (
    SELECT p.storage_key AS k FROM payment_proofs p JOIN orders o ON o.id = p.order_id WHERE o.user_id = p_user
    UNION ALL
    SELECT d.storage_key FROM deliverables d JOIN orders o ON o.id = d.order_id WHERE o.user_id = p_user AND d.storage_key IS NOT NULL
  ) s;
  INSERT INTO admin_log (actor_id, action, target, details)
  VALUES (v_coach, 'member.delete', v_u.email, jsonb_build_object('name', v_u.name, 'orders', v_orders));
  -- سجل الطلب للإضافة فقط، ويُسمح بحذفه داخل هذه الدالة وحدها (مثل الحذف النهائي للطلب الملغى)
  PERFORM set_config('app.allow_purge', '1', true);
  DELETE FROM orders WHERE user_id = p_user;
  DELETE FROM "user" WHERE id = p_user;
  PERFORM set_config('app.allow_purge', '', true);
  RETURN jsonb_build_object('email', v_u.email, 'keys', to_jsonb(v_keys));
END $$;
REVOKE ALL ON FUNCTION app.coach_delete_member(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.coach_delete_member(text) TO nav_app;

CREATE TABLE IF NOT EXISTS member_profiles (
  user_id text PRIMARY KEY REFERENCES "user" (id) ON DELETE CASCADE,
  answers jsonb NOT NULL DEFAULT '{}'::jsonb,
  health jsonb NOT NULL DEFAULT '{}'::jsonb,
  health_flag boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE member_profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_profiles_read ON member_profiles FOR SELECT USING (user_id = app.uid() OR app.is_coach());
GRANT SELECT ON member_profiles TO nav_app;

CREATE OR REPLACE FUNCTION app.save_my_profile(p_answers jsonb, p_health jsonb, p_flag boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_uid text := app.uid();
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'سجّل الدخول أولاً.' USING ERRCODE = 'P0001'; END IF;
  INSERT INTO member_profiles (user_id, answers, health, health_flag, updated_at)
  VALUES (v_uid, coalesce(p_answers, '{}'), coalesce(p_health, '{}'), coalesce(p_flag, false), now())
  ON CONFLICT (user_id) DO UPDATE SET answers = EXCLUDED.answers, health = EXCLUDED.health, health_flag = EXCLUDED.health_flag, updated_at = now();
END $$;
REVOKE ALL ON FUNCTION app.save_my_profile(jsonb, jsonb, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.save_my_profile(jsonb, jsonb, boolean) TO nav_app;

INSERT INTO schema_migrations (name) VALUES ('033_member_profile_delete_orders.sql');

-- ---------- 034_meal_details.sql ----------
-- =====================================================================
-- وجبات التغذية: اسم الوجبة الواضح + عرض المكونات وطريقة التحضير بعد الإضافة
-- - library_meals(): تضيف أسماء الأطعمة (foods) لتُعرض عندما يكون عنوان الوجبة مجرد «الفطور».
-- - meal_details(uuid[]): مكونات وطريقة تحضير وجبات سجّلها المتدرب (من جداوله أو من قوالب التغذية) لمن عنده اشتراك. للقراءة فقط.
-- =====================================================================
DROP FUNCTION IF EXISTS app.library_meals();
CREATE FUNCTION app.library_meals()
RETURNS TABLE (meal_id uuid, plan_name text, kind text, title text, protein numeric, carbs numeric, fat numeric, foods text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT DISTINCT ON (m.title, t.protein, t.carbs, t.fat) m.id, p.name, m.kind, m.title, t.protein, t.carbs, t.fat, t.foods
    FROM plan_meals m
    JOIN nutrition_plans p ON p.id = m.plan_id AND p.order_id IS NULL AND NOT p.archived
    JOIN LATERAL (SELECT coalesce(sum(i.protein), 0) AS protein, coalesce(sum(i.carbs), 0) AS carbs, coalesce(sum(i.fat), 0) AS fat,
                         string_agg(i.food, '، ' ORDER BY i.position) AS foods
                    FROM plan_items i WHERE i.meal_id = m.id) t ON true
   WHERE app.is_coach() OR app.has_program()
   ORDER BY m.title, t.protein, t.carbs, t.fat, p.position, m.position;
$$;
REVOKE ALL ON FUNCTION app.library_meals() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.library_meals() TO nav_app;

CREATE OR REPLACE FUNCTION app.meal_details(p_meals uuid[])
RETURNS TABLE (meal_id uuid, method text, items jsonb)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT m.id, m.method,
         coalesce((SELECT jsonb_agg(jsonb_build_object('food', i.food, 'portion', i.portion, 'protein', i.protein, 'carbs', i.carbs, 'fat', i.fat) ORDER BY i.position)
                     FROM plan_items i WHERE i.meal_id = m.id), '[]'::jsonb)
    FROM plan_meals m JOIN nutrition_plans p ON p.id = m.plan_id AND NOT p.archived
   WHERE m.id = ANY(p_meals)
     AND (app.is_coach() OR (app.has_program() AND (p.order_id IS NULL OR EXISTS (SELECT 1 FROM orders o WHERE o.id = p.order_id AND o.user_id = app.uid()))));
$$;
REVOKE ALL ON FUNCTION app.meal_details(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.meal_details(uuid[]) TO nav_app;

INSERT INTO schema_migrations (name) VALUES ('034_meal_details.sql');

-- ---------- 035_move_order.sql ----------
-- =====================================================================
-- نقل طلب لحساب صاحبه الصحيح (للمدربة فقط)
-- يحدث عند إضافة طلب يدوي ببريد شخص آخر، أو طلب أرسلته متدربة من حساب غيرها (جوال مشترك مثلاً).
-- ينقل الطلب وكل ما يتبعه (البرنامج والمراجعات والاستبيان والتغذية والإيصالات...) لحساب البريد المحدد،
-- وينشئ الحساب إن لم يكن موجوداً. لا يحذف شيئاً، ويُسجَّل في سجل الإدارة وسجل الطلب.
-- =====================================================================
CREATE OR REPLACE FUNCTION app.coach_move_order(p_order_no text, p_email text, p_name text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_coach text := app.require_coach();
  v_email text := lower(trim(coalesce(p_email, '')));
  v_name text := trim(coalesce(p_name, ''));
  v_order orders%ROWTYPE;
  v_from "user"%ROWTYPE;
  v_to "user"%ROWTYPE;
BEGIN
  IF v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' OR length(v_email) > 200 THEN
    RAISE EXCEPTION 'اكتبي بريد صاحبة الطلب الصحيح.' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_order FROM orders WHERE order_no = p_order_no FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO v_from FROM "user" WHERE id = v_order.user_id;

  SELECT * INTO v_to FROM "user" WHERE lower(email) = v_email;
  IF NOT FOUND THEN
    IF length(v_name) NOT BETWEEN 2 AND 80 THEN
      RAISE EXCEPTION 'هذا البريد غير مسجّل؛ اكتبي اسم صاحبة الطلب لإنشاء حسابها.' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO "user" (id, name, email, "emailVerified", role, phone)
    VALUES (gen_random_uuid()::text, v_name, v_email, false, 'client', nullif(v_order.contact_phone, ''))
    RETURNING * INTO v_to;
  ELSIF v_to.role <> 'client' THEN
    RAISE EXCEPTION 'هذا البريد لحساب إداري، وليس لمتدرب.' USING ERRCODE = 'P0001';
  END IF;
  IF v_to.id = v_order.user_id THEN
    RAISE EXCEPTION 'الطلب أصلاً في حساب هذا البريد.' USING ERRCODE = 'P0001';
  END IF;

  UPDATE orders SET user_id = v_to.id, updated_at = now() WHERE id = v_order.id;
  UPDATE blocks SET user_id = v_to.id WHERE order_id = v_order.id;
  UPDATE exercise_swaps SET user_id = v_to.id WHERE block_id IN (SELECT id FROM blocks WHERE order_id = v_order.id);
  UPDATE check_ins SET user_id = v_to.id WHERE order_id = v_order.id;
  UPDATE exit_surveys SET user_id = v_to.id WHERE order_id = v_order.id;
  UPDATE food_logs SET user_id = v_to.id WHERE order_id = v_order.id;
  UPDATE intakes SET user_id = v_to.id WHERE order_id = v_order.id;
  UPDATE notification_log SET user_id = v_to.id WHERE order_id = v_order.id;
  UPDATE payment_proofs SET user_id = v_to.id WHERE order_id = v_order.id;
  UPDATE reviews SET user_id = v_to.id WHERE order_id = v_order.id;

  -- اسم الحساب الجديد: إن كان فارغاً أو مأخوذاً من البريد يأخذ الاسم المكتوب
  IF length(v_name) BETWEEN 2 AND 80 AND (v_to.name = '' OR v_to.name = split_part(v_to.email, '@', 1)) THEN
    UPDATE "user" SET name = v_name, "updatedAt" = now() WHERE id = v_to.id;
  END IF;

  INSERT INTO order_events (order_id, from_status, to_status, actor_id, actor_role, note, client_visible)
  VALUES (v_order.id, v_order.status, v_order.status, v_coach, 'coach', 'نُقل الطلب لحساب صاحبته الصحيح (' || v_to.email || ').', false);
  INSERT INTO admin_log (actor_id, action, target, details)
  VALUES (v_coach, 'order.move', v_order.order_no,
          jsonb_build_object('from_user', v_order.user_id, 'from_email', v_from.email, 'to_user', v_to.id, 'to_email', v_to.email));
  RETURN v_to.email;
END $$;
REVOKE ALL ON FUNCTION app.coach_move_order(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.coach_move_order(text, text, text) TO nav_app;

-- تعديل اسم حساب متدرب (مثلاً حساب أخذ اسم شخص آخر بالخطأ)
CREATE OR REPLACE FUNCTION app.coach_rename_member(p_user_id text, p_name text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_coach text := app.require_coach();
  v_name text := trim(coalesce(p_name, ''));
BEGIN
  IF length(v_name) NOT BETWEEN 2 AND 80 THEN RAISE EXCEPTION 'الاسم بين حرفين و80 حرفاً.' USING ERRCODE = 'P0001'; END IF;
  UPDATE "user" SET name = v_name, "updatedAt" = now() WHERE id = p_user_id AND role = 'client';
  IF NOT FOUND THEN RAISE EXCEPTION 'الحساب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  INSERT INTO admin_log (actor_id, action, target, details) VALUES (v_coach, 'member.rename', p_user_id, jsonb_build_object('name', v_name));
END $$;
REVOKE ALL ON FUNCTION app.coach_rename_member(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.coach_rename_member(text, text) TO nav_app;

INSERT INTO schema_migrations (name) VALUES ('035_move_order.sql');

-- ---------- 035_public_templates.sql ----------
-- =====================================================================
-- برامج المدربة المجانية في تطبيق الجوال: قالب تختار المدربة نشره يظهر لأي زائر في التطبيق،
-- ويبدأه المستخدم كنسخة على جهازه. لا يُكشف إلا الأسبوع الأول (الجولات والتكرارات وRIR)
-- وأسماء التمارين؛ لا ملاحظات المدربة ولا بيانات المكتبة الداخلية.
-- =====================================================================
ALTER TABLE program_templates ADD COLUMN public boolean NOT NULL DEFAULT false;
ALTER TABLE program_templates ADD COLUMN public_summary text CHECK (public_summary IS NULL OR length(public_summary) <= 300);

CREATE OR REPLACE FUNCTION app.public_programs() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce(jsonb_agg(p ORDER BY p->>'name'), '[]'::jsonb) FROM (
    SELECT jsonb_build_object(
      'id', t.id, 'name', t.name, 'summary', t.public_summary, 'instructions', t.instructions,
      'days', coalesce((
        SELECT jsonb_agg(jsonb_build_object(
          'title', d.title,
          'items', coalesce((
            SELECT jsonb_agg(jsonb_build_object('exercise', e.name, 'week1', i.plan->0) ORDER BY i.position)
              FROM template_items i JOIN exercises e ON e.id = i.exercise_id WHERE i.day_id = d.id), '[]'::jsonb)
        ) ORDER BY d.day_no) FROM template_days d WHERE d.template_id = t.id), '[]'::jsonb)
    ) AS p
    FROM program_templates t WHERE t.public AND NOT t.archived
  ) x
$$;
REVOKE ALL ON FUNCTION app.public_programs() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.public_programs() TO nav_app;

INSERT INTO schema_migrations (name) VALUES ('035_public_templates.sql');

-- ---------- 036_auth_tables_rls.sql ----------
-- =====================================================================
-- RLS على جداول الدخول (user / session / account / verification / rateLimit / schema_migrations)
-- مكتبة الدخول (better-auth) تعمل بدون هوية متدرب في الاتصال (app.uid() = NULL) فتبقى كما هي.
-- داخل طلب متدرب (withUser) يشوف صفّه فقط؛ والمدربة وحساب النظام يشوفون الكل.
-- + منع تغيير الدور (client/coach) أو إنشاء حساب بدور غير متدرب من اتصال التطبيق نفسه.
-- =====================================================================
ALTER TABLE "user" ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS user_access ON "user";
CREATE POLICY user_access ON "user"
  USING (app.uid() IS NULL OR id = app.uid() OR app.is_coach())
  WITH CHECK (app.uid() IS NULL OR id = app.uid() OR app.is_coach());

ALTER TABLE "session" ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS session_access ON "session";
CREATE POLICY session_access ON "session"
  USING (app.uid() IS NULL OR "userId" = app.uid() OR app.is_coach())
  WITH CHECK (app.uid() IS NULL OR "userId" = app.uid() OR app.is_coach());

ALTER TABLE "account" ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS account_access ON "account";
CREATE POLICY account_access ON "account"
  USING (app.uid() IS NULL OR "userId" = app.uid() OR app.is_coach())
  WITH CHECK (app.uid() IS NULL OR "userId" = app.uid() OR app.is_coach());

-- رموز الدخول وحدود الطلبات: لمكتبة الدخول فقط (خارج أي طلب متدرب)
ALTER TABLE "verification" ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS verification_access ON "verification";
CREATE POLICY verification_access ON "verification" USING (app.uid() IS NULL) WITH CHECK (app.uid() IS NULL);

ALTER TABLE "rateLimit" ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ratelimit_access ON "rateLimit";
CREATE POLICY ratelimit_access ON "rateLimit" USING (app.uid() IS NULL) WITH CHECK (app.uid() IS NULL);

-- سجل التحديثات: للمالك فقط (لا صلاحيات للتطبيق أصلاً)
ALTER TABLE schema_migrations ENABLE ROW LEVEL SECURITY;

-- الدور لا يتغير من اتصال التطبيق (nav_app). ترقية حساب لمدربة تتم من محرر قاعدة البيانات فقط.
CREATE OR REPLACE FUNCTION app.protect_user_role() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF current_user = 'nav_app' THEN
    IF TG_OP = 'INSERT' AND coalesce(NEW.role, 'client') <> 'client' THEN
      RAISE EXCEPTION 'لا يمكن إنشاء حساب بدور غير متدرب.' USING ERRCODE = '42501';
    END IF;
    IF TG_OP = 'UPDATE' AND NEW.role IS DISTINCT FROM OLD.role THEN
      RAISE EXCEPTION 'لا يمكن تغيير الدور من التطبيق.' USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS user_protect_role ON "user";
CREATE TRIGGER user_protect_role BEFORE INSERT OR UPDATE ON "user" FOR EACH ROW EXECUTE FUNCTION app.protect_user_role();

-- فحص لوحة الإدارة: هل اتصال الموقع يطبّق RLS؟ (لو كان بحساب المالك تتعطل الحماية بين الحسابات)
CREATE OR REPLACE FUNCTION app.connection_enforces_rls() RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT NOT (r.rolsuper OR r.rolbypassrls)
     AND NOT EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'orders' AND tableowner = current_user)
    FROM pg_roles r WHERE r.rolname = current_user
$$;
GRANT EXECUTE ON FUNCTION app.connection_enforces_rls() TO nav_app;

INSERT INTO schema_migrations (name) VALUES ('036_auth_tables_rls.sql');

-- ---------- 036_self_delete.sql ----------
-- =====================================================================
-- حذف الحساب من التطبيق (إلزامي في App Store، البند 5.1.1(v)): العضو يحذف حسابه بنفسه.
-- نفس أثر حذف المدربة للعضو: الطلبات وتبعاتها (الاستبيان، الإيصالات، البرامج، السجلات) تُحذف نهائياً.
-- يبقى أثر في admin_log (البريد وأرقام الطلبات فقط) للرجوع المالي. حساب المدربة لا يُحذف من هنا.
-- =====================================================================
CREATE OR REPLACE FUNCTION app.delete_my_account() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_user text := app.require_user();
  v_u "user"%ROWTYPE;
  v_orders text[];
  v_keys text[];
BEGIN
  SELECT * INTO v_u FROM "user" WHERE id = v_user;
  IF NOT FOUND THEN RAISE EXCEPTION 'الحساب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  IF v_u.role IS DISTINCT FROM 'client' THEN RAISE EXCEPTION 'حساب المدربة لا يُحذف من التطبيق.' USING ERRCODE = 'P0001'; END IF;
  SELECT coalesce(array_agg(order_no ORDER BY created_at), '{}') INTO v_orders FROM orders WHERE user_id = v_user;
  SELECT coalesce(array_agg(k), '{}') INTO v_keys FROM (
    SELECT p.storage_key AS k FROM payment_proofs p JOIN orders o ON o.id = p.order_id WHERE o.user_id = v_user
    UNION ALL
    SELECT d.storage_key FROM deliverables d JOIN orders o ON o.id = d.order_id WHERE o.user_id = v_user AND d.storage_key IS NOT NULL
  ) s;
  -- actor_id فارغ: السجل للإضافة فقط ولا يُحدَّث عند حذف المستخدم
  INSERT INTO admin_log (actor_id, action, target, details)
  VALUES (NULL, 'member.self_delete', v_u.email, jsonb_build_object('name', v_u.name, 'orders', v_orders));
  PERFORM set_config('app.allow_purge', '1', true);
  DELETE FROM orders WHERE user_id = v_user;
  DELETE FROM "user" WHERE id = v_user;
  PERFORM set_config('app.allow_purge', '', true);
  RETURN jsonb_build_object('email', v_u.email, 'orders', to_jsonb(v_orders), 'keys', to_jsonb(v_keys));
END $$;
REVOKE ALL ON FUNCTION app.delete_my_account() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.delete_my_account() TO nav_app;

INSERT INTO schema_migrations (name) VALUES ('036_self_delete.sql');

-- ---------- 037_app_addons.sql ----------
-- =====================================================================
-- خدمات إضافية بأسعار رمزية من تطبيق الجوال (منتجات عادية في لوحة الإدارة، يحددها حقل app_addon):
--  * program_review: «راجعي جدولي» — يرسل المتدرب برنامجه المجاني وسجل آخر 4 أسابيع من جواله.
--  * form_check: «تصحيح أداء تمرين» — يرسل مقطع فيديو قصير لتمرين واحد.
--  * meal_library: «وجباتي» — الوصول لوجبات قوالب التغذية التي تصممها المدربة.
-- الدفع بنفس مسار الطلبات (تحويل بنكي ثم تأكيد المدربة). بيانات الطلب في addon_requests وتُحذف مع الطلب.
-- =====================================================================
ALTER TABLE products ADD COLUMN app_addon text CHECK (app_addon IS NULL OR app_addon IN ('program_review', 'form_check', 'meal_library'));
CREATE UNIQUE INDEX products_app_addon_key ON products (app_addon) WHERE app_addon IS NOT NULL AND status = 'published';

CREATE TABLE addon_requests (
  order_id uuid PRIMARY KEY REFERENCES orders (id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('program_review', 'form_check', 'meal_library')),
  payload jsonb CHECK (payload IS NULL OR (jsonb_typeof(payload) = 'object' AND pg_column_size(payload) <= 200000)),
  note text CHECK (note IS NULL OR length(note) <= 1000),
  video_key text,
  video_mime text CHECK (video_mime IS NULL OR video_mime IN ('video/mp4', 'video/quicktime')),
  video_size int CHECK (video_size IS NULL OR video_size BETWEEN 1 AND 6000000),
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE addon_requests ENABLE ROW LEVEL SECURITY;
CREATE POLICY addon_requests_read ON addon_requests FOR SELECT USING (app.is_coach() OR app.owns_order(order_id));
-- مفتاح الفيديو لا يُقرأ مباشرة إلا عبر مسار الملفات بعد تحقق RLS
GRANT SELECT ON addon_requests TO nav_app;

-- يُرفق بطلب الخدمة الإضافية بعد إنشائه مباشرة (صاحب الطلب، والطلب ينتظر الدفع، ومرة واحدة)
CREATE OR REPLACE FUNCTION app.submit_addon(p_order_no text, p_payload jsonb, p_note text, p_video_key text, p_video_mime text, p_video_size int)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  u text := app.require_user();
  v_order uuid; v_status text; v_kind text;
BEGIN
  SELECT o.id, o.status, p.app_addon INTO v_order, v_status, v_kind
    FROM orders o JOIN products p ON p.id = o.product_id WHERE o.order_no = p_order_no AND o.user_id = u;
  IF NOT FOUND OR v_kind IS NULL THEN RAISE EXCEPTION 'الطلب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  IF v_status NOT IN ('awaiting_payment', 'awaiting_quote') THEN RAISE EXCEPTION 'لا يمكن تعديل هذا الطلب الآن.' USING ERRCODE = 'P0001'; END IF;
  IF v_kind = 'program_review' AND (p_payload IS NULL OR NOT (p_payload ? 'program')) THEN
    RAISE EXCEPTION 'اختر البرنامج اللي تبي المدربة تراجعه.' USING ERRCODE = 'P0001';
  END IF;
  IF v_kind = 'form_check' AND p_video_key IS NULL THEN
    RAISE EXCEPTION 'أرفق مقطع الفيديو.' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO addon_requests (order_id, kind, payload, note, video_key, video_mime, video_size)
  VALUES (v_order, v_kind, p_payload, nullif(trim(coalesce(p_note, '')), ''), p_video_key, p_video_mime, p_video_size);
END $$;
REVOKE ALL ON FUNCTION app.submit_addon(text, jsonb, text, text, text, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.submit_addon(text, jsonb, text, text, text, int) TO nav_app;

-- «عنده برنامج»: يفتح الكتيبات ووجبات قوالب التغذية. خدمات المراجعة الصغيرة لا تفتحها؛ اشتراك «وجباتي» يفتحها.
CREATE OR REPLACE FUNCTION app.has_program() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM orders o LEFT JOIN products p ON p.id = o.product_id
                  WHERE o.user_id = app.uid() AND o.status IN ('active', 'delivered', 'completed')
                    AND (p.app_addon IS NULL OR p.app_addon = 'meal_library'));
$$;

INSERT INTO schema_migrations (name) VALUES ('037_app_addons.sql');

-- ---------- 038_coach_alts.sql ----------
-- =====================================================================
-- «ناف برو» في تطبيق الجوال: اشتراك واحد يجمع
--  * بدائل الكوتش لكل تمرين (جدول exercise_alternatives اللي تعدّله المدربة من لوحة الإدارة) في المتتبّع المجاني.
--    المتتبّع يقدّم للجميع بدائل عامة من نفس العضلة.
--  * «وجباتي»: وجبات قوالب التغذية (كانت لمن عنده برنامج أو اشترى «وجباتي»، وتبقى لهم).
-- الاستحقاق الآن: المدربة، أو متدرب باشتراك متابعة جارٍ (ميزة ضمن الباقة). اشتراك Apple يُضاف هنا لاحقاً.
-- =====================================================================
CREATE OR REPLACE FUNCTION app.has_pro() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT app.is_coach() OR EXISTS (SELECT 1 FROM orders o LEFT JOIN products p ON p.id = o.product_id
                                    WHERE o.user_id = app.uid() AND o.status = 'active' AND p.app_addon IS NULL);
$$;
REVOKE ALL ON FUNCTION app.has_pro() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.has_pro() TO nav_app;

-- اسم التمرين → أسماء بدائله بترتيب المدربة (المعتمدة فقط). NULL لغير المشترك.
CREATE OR REPLACE FUNCTION app.coach_alts() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT CASE WHEN app.has_pro() THEN (
    SELECT coalesce(jsonb_object_agg(t.name, t.alts), '{}'::jsonb) FROM (
      SELECT e.name, jsonb_agg(x.name ORDER BY a.position, x.name) AS alts
        FROM exercise_alternatives a
        JOIN exercises e ON e.id = a.exercise_id AND e.status = 'approved'
        JOIN exercises x ON x.id = a.alt_id AND x.status = 'approved'
       GROUP BY e.name) t)
  END
$$;
REVOKE ALL ON FUNCTION app.coach_alts() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.coach_alts() TO nav_app;

-- «وجباتي»: من عنده برنامج (أو اشترى «وجباتي» من الموقع) أو مشترك «ناف برو»
CREATE OR REPLACE FUNCTION app.has_meals() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT app.has_program() OR app.has_pro();
$$;
REVOKE ALL ON FUNCTION app.has_meals() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.has_meals() TO nav_app;

-- نفس تعريف 034 مع الاستحقاق الجديد
CREATE OR REPLACE FUNCTION app.library_meals()
RETURNS TABLE (meal_id uuid, plan_name text, kind text, title text, protein numeric, carbs numeric, fat numeric, foods text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT DISTINCT ON (m.title, t.protein, t.carbs, t.fat) m.id, p.name, m.kind, m.title, t.protein, t.carbs, t.fat, t.foods
    FROM plan_meals m
    JOIN nutrition_plans p ON p.id = m.plan_id AND p.order_id IS NULL AND NOT p.archived
    JOIN LATERAL (SELECT coalesce(sum(i.protein), 0) AS protein, coalesce(sum(i.carbs), 0) AS carbs, coalesce(sum(i.fat), 0) AS fat,
                         string_agg(i.food, '، ' ORDER BY i.position) AS foods
                    FROM plan_items i WHERE i.meal_id = m.id) t ON true
   WHERE app.is_coach() OR app.has_meals()
   ORDER BY m.title, t.protein, t.carbs, t.fat, p.position, m.position;
$$;

CREATE OR REPLACE FUNCTION app.meal_details(p_meals uuid[])
RETURNS TABLE (meal_id uuid, method text, items jsonb)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT m.id, m.method,
         coalesce((SELECT jsonb_agg(jsonb_build_object('food', i.food, 'portion', i.portion, 'protein', i.protein, 'carbs', i.carbs, 'fat', i.fat) ORDER BY i.position)
                     FROM plan_items i WHERE i.meal_id = m.id), '[]'::jsonb)
    FROM plan_meals m JOIN nutrition_plans p ON p.id = m.plan_id AND NOT p.archived
   WHERE m.id = ANY(p_meals)
     AND (app.is_coach() OR (app.has_meals() AND (p.order_id IS NULL OR EXISTS (SELECT 1 FROM orders o WHERE o.id = p.order_id AND o.user_id = app.uid()))));
$$;

INSERT INTO schema_migrations (name) VALUES ('038_coach_alts.sql');

-- ---------- 039_review_interval.sql ----------
-- =====================================================================
-- تكرار المراجعة لكل باقة: كل أسبوع (الافتراضي) أو كل أسبوعين (الباقة الأساسية) ...
-- - products.review_every_weeks: إعداد الباقة، تغيّره المدربة من صفحة المنتج.
-- - orders.review_every_weeks: نسخة في الطلب (تُؤخذ من الباقة عند إنشائه)، فيبقى جدول المتدرب ثابتاً
--   حتى لو صارت الباقة مخفية أو مؤرشفة.
-- - تغيير الإعداد من صفحة المنتج يطبَّق على طلبات الباقة الحالية، وعلامات «تمت المراجعة» اليدوية
--   تنتقل لرقم المراجعة الجديد المقابل لنفس الفترة (فلا تضيع).
-- =====================================================================
ALTER TABLE products ADD COLUMN IF NOT EXISTS review_every_weeks smallint NOT NULL DEFAULT 1
  CHECK (review_every_weeks BETWEEN 1 AND 4);
ALTER TABLE orders ADD COLUMN IF NOT EXISTS review_every_weeks smallint NOT NULL DEFAULT 1
  CHECK (review_every_weeks BETWEEN 1 AND 4);

-- الطلب الجديد (من الموقع، يدوي، تجديد، مكافأة) يأخذ تكرار المراجعة من باقته
CREATE OR REPLACE FUNCTION app.order_review_every() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  NEW.review_every_weeks := coalesce((SELECT review_every_weeks FROM products WHERE id = NEW.product_id), NEW.review_every_weeks, 1);
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS orders_review_every ON orders;
CREATE TRIGGER orders_review_every BEFORE INSERT ON orders FOR EACH ROW EXECUTE FUNCTION app.order_review_every();

-- يطبّق تكرار المراجعة على باقة وكل طلباتها. علامة المراجعة رقم k بالتكرار القديم (old)
-- تخص الفترة المنتهية بعد k×old أسبوع، فتنتقل للمراجعة رقم ceil(k×old/new) بالتكرار الجديد.
-- داخلية: لا تُمنح لاتصال الموقع (تستدعيها coach_set_review_every بعد التحقق من المدربة)
CREATE OR REPLACE FUNCTION app.apply_review_every(p_product uuid, p_weeks int) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v record;
  v_rows jsonb;
  v_n int := 0;
BEGIN
  IF p_weeks IS NULL OR p_weeks NOT BETWEEN 1 AND 4 THEN
    RAISE EXCEPTION 'تكرار المراجعة من أسبوع إلى 4 أسابيع.' USING ERRCODE = 'P0001';
  END IF;
  UPDATE products SET review_every_weeks = p_weeks WHERE id = p_product AND review_every_weeks <> p_weeks;
  FOR v IN SELECT id, review_every_weeks AS old FROM orders WHERE product_id = p_product AND review_every_weeks <> p_weeks FOR UPDATE LOOP
    SELECT coalesce(jsonb_agg(to_jsonb(rw)), '[]'::jsonb) INTO v_rows FROM review_weeks rw WHERE rw.order_id = v.id;
    DELETE FROM review_weeks WHERE order_id = v.id;
    INSERT INTO review_weeks (order_id, week_no, done_at, done_by, source)
    SELECT DISTINCT ON (s.week_no) v.id, s.week_no, s.done_at, s.done_by, s.source
      FROM (SELECT least(200, ceil((x->>'week_no')::int * v.old / p_weeks::numeric))::int AS week_no,
                   (x->>'done_at')::timestamptz AS done_at, x->>'done_by' AS done_by, x->>'source' AS source
              FROM jsonb_array_elements(v_rows) x) s
     ORDER BY s.week_no, s.done_at;
    UPDATE orders SET review_every_weeks = p_weeks, updated_at = now() WHERE id = v.id;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION app.apply_review_every(uuid, int) FROM PUBLIC;

-- للمدربة: من صفحة المنتج. ترجع عدد الطلبات التي تغيّر جدولها
CREATE OR REPLACE FUNCTION app.coach_set_review_every(p_product uuid, p_weeks int) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_coach text := app.require_coach();
  v_old int;
  v_slug text;
  v_n int;
BEGIN
  SELECT review_every_weeks, slug INTO v_old, v_slug FROM products WHERE id = p_product;
  IF NOT FOUND THEN RAISE EXCEPTION 'المنتج غير موجود.' USING ERRCODE = 'P0001'; END IF;
  v_n := app.apply_review_every(p_product, p_weeks);
  IF v_old <> p_weeks THEN
    INSERT INTO admin_log (actor_id, action, target, details)
    VALUES (v_coach, 'product.review_every', v_slug, jsonb_build_object('from', v_old, 'to', p_weeks, 'orders', v_n));
  END IF;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION app.coach_set_review_every(uuid, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.coach_set_review_every(uuid, int) TO nav_app;

-- الباقة الأساسية: مراجعة كل أسبوعين (مع طلباتها الحالية)
SELECT app.apply_review_every(id, 2) FROM products WHERE slug = 'basic';

INSERT INTO schema_migrations (name) VALUES ('039_review_interval.sql');

-- ---------- المحتوى المستورد من الموقع الحالي ----------
INSERT INTO public.exercises VALUES ('75c76baa-e469-4d3c-88a9-6fca0b6c2237', 'Seated Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/0G3W83dFUeY', 'اسحب باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness | تحدب الظهر / Postural Thoracic Kyphosis', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', 'تقوية سحب وانكماش لوح الكتف', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moseley et al. 1992 — AJSM (EMG, scapular muscles) | Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://pubmed.ncbi.nlm.nih.gov/1558238/ | https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8d9e9619-9a0a-4434-9427-0662bb3edf36', 'Forward Lunges', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/_DLAdo2Pvjs', 'تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness | ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, 'تقوية الورك ضمن نمط حركي وظيفي', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Distefano et al. 2009 — JOSPT (EMG) | Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin)', 'https://pubmed.ncbi.nlm.nih.gov/19574661/ | https://pubmed.ncbi.nlm.nih.gov/33344003/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('28672f51-3438-4ab4-a68d-4bc15e72e980', 'Bird Dog', 'Core / البطن والكور', '{"Lower back / أسفل الظهر","Glutes / المؤخرة"}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/L91QMACdA6Q?si=KBnuQDcm9WcUXxxI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Anti-Rotation / مقاومة الدوران', 'Isometric Anti-Rotation / تثبيت الجذع ضد الدوران', NULL, 'التحكم الحركي وتحمّل الجذع', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a78af0f2-c8b7-4ef2-987a-07bf6af46637', 'Single Leg Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'وزن الجسم', 'متقدم', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/136/single-leg-squat/', 'ضعف الألوية الكبرى / Gluteus Maximus Weakness | ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Single-leg Squat / سكوات رجل واحدة', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, 'تقوية باسطات ومبعدات الورك وتحكم أحادي الطرف', 'متقدمة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ يتطلب تحكماً جيداً بالركبة والحوض', 'Distefano et al. 2009 — JOSPT (EMG) | Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin)', 'https://pubmed.ncbi.nlm.nih.gov/19574661/ | https://pubmed.ncbi.nlm.nih.gov/33344003/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9ca7d96a-22dd-4fa6-8d52-bab17df996c7', 'Hip Abduction', 'Abductors / مبعدات الفخذ', '{"Glutes / المؤخرة"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/_ARUxqrII3Y?si=Jcz5uh2Uu-IdVCS1', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL, 'تقوية مبعدات الورك بمقاومة خارجية', 'مبكرة–متوسطة', 'منخفض–متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ الدليل يخص إبعاد الورك بمقاومة خارجية؛ يُتحقق من نوع الأداء', 'Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin)', 'https://pubmed.ncbi.nlm.nih.gov/33344003/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3f7ff0c7-93ea-4b52-b245-07a498fd1746', 'Side Step Up', 'Glutes / المؤخرة', '{"Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/xOwIRnI4VxA?si=SJOgODRmNGdfHPb4', 'يد فيها الوزن واليد الثانية سندها على الجدار', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية المتوسطة / Gluteus Medius Weakness | ضعف الألوية الصغرى / Gluteus Minimus Weakness', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, 'تقوية مبعدات الورك والتحكم بالحوض على رجل واحدة', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin) | Ganderton et al. — GMin/GMed EMG (RMIT University)', 'https://pubmed.ncbi.nlm.nih.gov/33344003/ | https://research-repository.rmit.edu.au/articles/journal_contribution/Gluteus_Minimus_and_Gluteus_Medius_Muscle_Activity_during_Common_Rehabilitation_Exercises_in_Healthy_Postmenopausal_Women/27572301', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ee99ccbf-57be-4028-b0f4-35c860cefdd0', 'Glute Bridge', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', NULL, 'مبتدئ', NULL, 'https://www.youtube.com/watch?v=dtlGynVdHYM', 'ممكن تسويه بالسميث مشين او البار الحر ، اختر بوكس او بنش يكون بمستوى اكتافك الخلفية وانت جالس، لما ترفع البار فوق المفروض ركبك تكون بنفس مستوى القدم.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness | آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, 'تقوية بسط الورك وتحمّل الجذع', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Boren et al. 2011 — IJSPT (EMG) | JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/22034614/ | https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4f5079bb-7dcb-4aa5-86c4-0cdd2226bf22', 'DB Floor Glute Bridge', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/iOrJXNUH3to?si=JySX6JMhoP2vWEVa', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, 'تقوية بسط الورك بتحميل خارجي متدرج', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Boren et al. 2011 — IJSPT (EMG)', 'https://pubmed.ncbi.nlm.nih.gov/22034614/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('596de19f-262b-4274-8da8-1abf61670446', 'Single DB RDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/U3prDlAbJDw?si=MRSBcSIcf9M-WQBH', 'وقف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، انزل وادفع مؤخرتك لآخر شي تقدر عليه للخلف وكأنك بتلمس جدار خلفك مع انثناء بسيط بالركب', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, 'تقوية باسطات الورك وتحكم أحادي الطرف', 'متقدمة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ مع الحفاظ على وضع محايد للظهر', 'Distefano et al. 2009 — JOSPT (EMG)', 'https://pubmed.ncbi.nlm.nih.gov/19574661/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4df4885c-2e40-43be-8106-76dd8cb70395', 'Upper Back Horizontal Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/TSWohpfMlso', 'ثبت نفسك بالكرسي، فتحة واسعة، الكيبل بمستوى أعلى صدرك، واسحب لما تنقبض الترابز.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Wide-grip Row / تجديف بقبضة واسعة', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', 'تقوية انكماش لوح الكتف والظهر العلوي', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moseley et al. 1992 — AJSM (EMG, scapular muscles)', 'https://pubmed.ncbi.nlm.nih.gov/1558238/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('16b751e5-f9ea-4565-b0fe-e45b2953b133', 'Band Seated Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/Jy-WCFAofBY?si=9gqVby588rk1zFi9', 'فتحة واسعة، واسحب لما تنقبض عضلات الظهر.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness | تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', 'تقوية سحب لوح الكتف بمقاومة منخفضة', 'مبكرة–متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moseley et al. 1992 — AJSM (EMG, scapular muscles) | Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://pubmed.ncbi.nlm.nih.gov/1558238/ | https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('30912dc7-b7bc-4cb4-b2e7-15fc032f3a26', 'Chest Supported Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/DgHtyrQEMJ4?si=oTfTKVgD9j1H12wA', 'ثبت صدرك على الكرسي، فتحة واسعة، واسحب لما تنقبض عضلات الظهر.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', 'تقوية انكماش لوح الكتف مع دعم الجذع', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moseley et al. 1992 — AJSM (EMG, scapular muscles)', 'https://pubmed.ncbi.nlm.nih.gov/1558238/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f0059c65-1e7f-4d11-b896-fd6b40bbb812', 'Plank', 'Core / البطن والكور', '{"Shoulders / الأكتاف","Glutes / المؤخرة"}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/pvIjsG5Svck?si=cTP8ZyfMAJPfaEhw', 'لما ترتفع الاكتاف تكون فوق الكوع والرجل ممتدة بالكامل.', NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL, 'تحمّل عضلات الجذع', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('879f5b96-15d6-491a-a0ff-3f13f7b235c4', 'deadbug', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/g_BYB0R-4Ws?si=D4nwJri73eBqJRqL', NULL, 'اسم مشابه موجود في المكتبة (deadbug / dead bug) — تُراجَع قبل الحذف أو الدمج', 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'rejected', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL, 'التحكم الحركي وتحمّل الجذع', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e44ffa76-f62d-4f86-8aaa-002b7906d431', 'Band Dead Bug', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'مطاط', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/iW_CtYtzbeU?si=Epequw3rqA3_TwTr', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL, 'التحكم الحركي وتحمّل الجذع بمقاومة', 'مبكرة–متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7ccd7004-8477-4e2c-a5a4-381cd3ee2f2f', 'Side Plank', 'Core / البطن والكور', '{"Abductors / مبعدات الفخذ","Shoulders / الأكتاف"}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'لما ترتفع الاكتاف تكون فوق الكوع والرجل ممتدة بالكامل.', NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain | ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Anti-Lateral Flexion / مقاومة الميلان الجانبي', 'Isometric Anti-Lateral Flexion / تثبيت الجذع ضد الميلان', NULL, 'تحمّل الجذع الجانبي وتنشيط مبعدات الورك', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.) | Boren et al. 2011 — IJSPT (EMG)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/ | https://pubmed.ncbi.nlm.nih.gov/22034614/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1d20813f-623e-4b73-a61e-b46639e18e0b', 'McGill Big 3', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/jZylx81_kfg?si=_jP064GZIzvEvzyN', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Mixed (McGill Big 3) / مختلط', 'Isometric Trunk Stabilization / تثبيت الجذع', NULL, 'التحكم الحركي وتحمّل الجذع', 'مبكرة–متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a04059d7-ac84-4b02-9d53-96bde2664671', 'Dead Bug', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/bxn9FBrt4-A', 'نحرك الرجلين ببطئ قليلا و بتحكم باستخدام عضلات البطن', 'اسم مشابه موجود في المكتبة (deadbug / dead bug) — تُراجَع قبل الحذف أو الدمج', 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL, 'التحكم الحركي وتحمّل الجذع', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a7ed7ab2-5177-4a02-9b02-e787e290c7be', 'High-Load Heel Raise (Towel Under Toes)', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', NULL, 'مبتدئ', NULL, NULL, 'رفع الكعب على رجل واحدة مع منشفة ملفوفة تحت أصابع القدم؛ صعود بطيء ثم ثبات قصير ثم نزول بطيء.', 'أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Rathleff et al. 2015 — Scand J Med Sci Sports (RCT)', 'https://doi.org/10.1111/sms.12313', 'اللفافة الأخمصية / Plantar Fasciopathy', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL, 'تحميل تدريجي للقدم والكاحل', 'متقدمة', 'مرتفع', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ يُبدأ بعد تحسّن الأعراض وبتدرّج', 'Rathleff et al. 2015 — Scand J Med Sci Sports (RCT) | JOSPT CPG 2023 — Heel Pain/Plantar Fasciitis (Koc et al.)', 'https://doi.org/10.1111/sms.12313 | https://pubmed.ncbi.nlm.nih.gov/38037331/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('dd02bdd2-bd27-4a60-bfe2-946bc309f3ee', 'Side Lunge', 'Adductors / الأفخاذ الداخلية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/50/side-lunge/', 'ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Lateral Lunge / لانج جانبي', 'Knee/Hip Extension + Hip Adduction / مد الركبة والورك + تقريب الورك', NULL, 'تقوية مبعدات الورك والتحكم بالحوض', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin)', 'https://pubmed.ncbi.nlm.nih.gov/33344003/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d2a81e56-587c-4270-9683-93480c5af8b8', 'Hip Hitch (Pelvic Drop)', 'Abductors / مبعدات الفخذ', '{}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Ganderton et al. — GMin/GMed EMG (RMIT University)', 'https://research-repository.rmit.edu.au/articles/journal_contribution/Gluteus_Minimus_and_Gluteus_Medius_Muscle_Activity_during_Common_Rehabilitation_Exercises_in_Healthy_Postmenopausal_Women/27572301', 'ضعف الألوية المتوسطة / Gluteus Medius Weakness | ضعف الألوية الصغرى / Gluteus Minimus Weakness', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Pelvic Drop (Stance Leg) / تثبيت الحوض برجل الارتكاز', 'Hip Abduction of Stance Leg / تبعيد ورك رجل الارتكاز', NULL, 'تنشيط وتقوية مبعدات الورك (الألوية المتوسطة والصغرى) والتحكم بالحوض', 'مبكرة–متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Ganderton et al. — GMin/GMed EMG (RMIT University) | Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin)', 'https://research-repository.rmit.edu.au/articles/journal_contribution/Gluteus_Minimus_and_Gluteus_Medius_Muscle_Activity_during_Common_Rehabilitation_Exercises_in_Healthy_Postmenopausal_Women/27572301 | https://pubmed.ncbi.nlm.nih.gov/33344003/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6fa5e6a1-5a64-4913-b4cd-f5bf4af30d53', 'Shoulder I-Y-T-W Series', 'Rotator cuffs / الكفة المدورة', '{"Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/237/shoulder-stability-mobility-series-i-y-t-w-formations/', 'تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture | ضعف العضلة المعينية / Rhomboid Weakness', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'I-Y-T-W / تمارين I-Y-T-W', 'Scapular Retraction/Depression + Arm Elevation / سحب وخفض لوح الكتف مع رفع الذراع', NULL, 'تقوية وتحكم عضلات لوح الكتف (الانكماش والتدوير)', 'مبكرة–متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis) | Sheikhhoseini et al. 2018 — JMPT (Systematic review, FHP) | Castelein et al. 2016 — Man Ther (EMG, rhomboid)', 'https://doi.org/10.1186/s12891-024-07224-4 | https://pubmed.ncbi.nlm.nih.gov/30107937/ | https://pubmed.ncbi.nlm.nih.gov/26409441/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('abc0b6d3-5635-4622-af2d-e8a2f608ab39', 'Supine Snow Angel (Wipers)', 'Rotator cuffs / الكفة المدورة', '{"Shoulders / الأكتاف","Core / البطن والكور"}', 'Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/124/supine-snow-angel-wipers-exercise/', 'تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Snow Angel / الملاك', 'Shoulder Abduction/Adduction + Scapular Control / تبعيد وتقريب الكتف مع تحكم لوح الكتف', NULL, 'حركة الكتف والتحكم بلوح الكتف', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a221b7ff-3aa5-4289-9994-abd75bcd58e2', 'Single Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/82IuSLk5zNc?si=FTMqZrmawQFRr8dN', 'اجلس وثبت ظهرك السفلي كويس، تأكد ان مسمار الارتفاع يكون بمستوى ركبتك، امسك المقابض لزيادة الثبات، إرفع الوزن اثبت ثانية فوق ثم انزل نزول كامل بتحكم.

ملاحظات مهمة:
• اعمل برجل واحدة بنفس ضبط الجهاز
• ثبّت الجذع ولا تتمايل لتعويض الوزن
• افرد الركبة ببطء وانزل بتحكم
• وزن أخف من العمل بالرجلين', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('65cf8e00-d025-4950-a7fb-676f2fc07b30', 'Back Extension', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة","Hamstrings / الخلفية"}', 'Spinal Extension / بسط الجذع', 'كور', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/bs7S3RFyIYs?si=tDLl3OYuDBIwK4Fj', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «Functional Training»)', 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain | تحدب الظهر / Postural Thoracic Kyphosis', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Back Extension / بسط الظهر', 'Hip Extension + Spinal Extension / بسط الورك + بسط العمود الفقري', NULL, 'تقوية باسطات الظهر', 'متقدمة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ يُراجَع إذا زاد الألم مع الامتداد', 'JOSPT CPG 2021 — Low Back Pain (George et al.) | Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/ | https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b9018b05-90eb-47e4-b06f-bdd04382ca4e', 'Supermans', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة","Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Spinal Extension / بسط الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/9/supermans/', 'تحدب الظهر / Postural Thoracic Kyphosis | آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Prone Extension / بسط على البطن', 'Spinal Extension / بسط العمود الفقري', NULL, 'تقوية باسطات الظهر والتحكم الوضعي', 'متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis) | JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://doi.org/10.1186/s12891-024-07224-4 | https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6cf99213-527b-42b3-be20-822a58f71095', 'Standing Dorsi-Flexion (Calf Stretch)', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/152/standing-dorsi-flexion-calf-stretch/', 'اللفافة الأخمصية / Plantar Fasciopathy', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Calf Stretch / إطالة البطات', 'Ankle Dorsiflexion / ثني ظهري للكاحل', NULL, 'إطالة عضلات الساق', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2023 — Heel Pain/Plantar Fasciitis (Koc et al.)', 'https://pubmed.ncbi.nlm.nih.gov/38037331/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ee7f9dc6-677b-4504-bf95-bdf2f90605ad', 'Cat-Cow', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/15/cat-cow/', 'تحدب الظهر / Postural Thoracic Kyphosis | آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Spinal Mobility / مرونة العمود الفقري', 'Spinal Flexion/Extension / ثني وبسط العمود الفقري', NULL, 'حركة العمود الفقري ضمن مدى حركة مريح', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis) | JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://doi.org/10.1186/s12891-024-07224-4 | https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('02b2235e-b7f7-461f-b875-549b755abac8', 'Plantar Fascia-Specific Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'تُسحب أصابع القدم للخلف باليد حتى يُشعر بشد في باطن القدم، مع تحسّس اللفافة للتأكد من الشد.', 'أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Rathleff et al. 2015 — Scand J Med Sci Sports (RCT)', 'https://doi.org/10.1111/sms.12313', 'اللفافة الأخمصية / Plantar Fasciopathy', 'review', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Plantar Fascia Stretch / إطالة اللفافة الأخمصية', 'Toe Extension + Ankle Dorsiflexion / مد أصابع القدم + ثني ظهري', NULL, 'إطالة اللفافة الأخمصية', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2023 — Heel Pain/Plantar Fasciitis (Koc et al.) | Rathleff et al. 2015 — Scand J Med Sci Sports (RCT)', 'https://pubmed.ncbi.nlm.nih.gov/38037331/ | https://doi.org/10.1111/sms.12313', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('056ea8ae-4517-4685-8ef8-62029b547944', 'Crab Reach (Thoracic Bridge)', 'Functional / التمارين الوظيفية', '{"Glutes / المؤخرة","Shoulders / الأكتاف"}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://www.youtube.com/watch?v=fgsUe3Lc3hI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'تحدب الظهر / Postural Thoracic Kyphosis', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Thoracic Bridge / جسر صدري', 'Hip Extension + Thoracic Rotation / بسط الورك + دوران الصدر', NULL, 'حركة الامتداد والدوران الصدري', 'متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ يتطلب تحمّلاً جيداً للرسغ والكتف', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('db8f64d0-421e-4a31-8f12-be2848bcd8fa', 'Prone Swimmer', 'Functional / التمارين الوظيفية', '{"Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Shoulder Rear Pull / سحب خلفي للكتف', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://www.youtube.com/watch?v=M8a1cgnhyqk', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Prone Swimmer / سبّاح على البطن', 'Shoulder Extension/Abduction + Rotation / مد وتبعيد الكتف مع الدوران', NULL, 'تحمّل عضلات لوح الكتف والامتداد الصدري', 'متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2f985ba2-8909-4720-8fd3-e778b0dd6a50', 'Isometric Wrist Extension', 'Forearms / الساعد', '{}', 'Wrist Extension / مد الرسغ', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'مرفق التنس / Lateral Elbow Tendinopathy', 'review', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Isometric / ثابت', 'Wrist Extension / مد الرسغ', NULL, 'تحميل تدريجي لباسطات الرسغ (انقباض ثابت)', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ ضمن ألم مقبول لا يتزايد بعد التمرين', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d3c2aa2b-f829-4627-b2c5-bfc349e46cd8', 'Eccentric Wrist Extension', 'Forearms / الساعد', '{}', 'Wrist Extension / مد الرسغ', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'مرفق التنس / Lateral Elbow Tendinopathy', 'review', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Eccentric / لامركزي', 'Wrist Extension / مد الرسغ', NULL, 'تحميل تدريجي لباسطات الرسغ (لامركزي)', 'متوسطة', 'منخفض–متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ ضمن ألم مقبول لا يتزايد بعد التمرين', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d62cc4d7-52a4-4237-a537-819ef89ff833', 'Chin Tuck (Deep Neck Flexor)', 'Neck / الرقبة', '{}', 'Neck Flexion (Deep Flexors) / ثني الرقبة العميق', 'إحماء/تفعيل', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Sheikhhoseini et al. 2018 — JMPT (Systematic review, FHP)', 'https://pubmed.ncbi.nlm.nih.gov/30107937/', 'وضعية الرأس للأمام / Forward Head Posture', 'review', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Chin Tuck / سحب الذقن', 'Upper Cervical Flexion + Retraction / ثني علوي للرقبة مع سحبها للخلف', NULL, 'تحكم عضلات الرقبة العميقة ووضعية الرأس', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ يُوقف مع دوخة أو ألم/تنميل يمتد للذراع', 'Sheikhhoseini et al. 2018 — JMPT (Systematic review, FHP) | Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://pubmed.ncbi.nlm.nih.gov/30107937/ | https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4fc76f77-34ab-472f-8736-a72f9750060a', 'Terminal Knee Extension (Band)', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'مطاط', 'مبتدئ', 'منزل', NULL, 'اربط الشريط المطاطي خلف الركبة وقف بثبات. من ركبة مثنية قليلاً، افرد الركبة بالكامل ببطء وشد عضلة الفخذ الأمامية ثانية، ثم ارجع ببطء. 2–3 مجموعات × 12–15 تكرار.', NULL, 'مصدر خارجي موثوق', 'JOSPT CPG 2019 — Patellofemoral Pain (Willy et al.)', 'https://doi.org/10.2519/jospt.2019.0302', 'ألم الرضفة والفخذ (الركبة الأمامية) / Patellofemoral Pain', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Knee Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, 'تقوية الفخذ الأمامي في مدى آمن للركبة', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي. يكون الألم أثناء التمرين خفيفاً ومقبولاً (حتى 3 من 10) ويهدأ خلال 24 ساعة، وإذا زاد الألم أو ظهر تورم أو إحساس بقفل أو خذلان في الركبة يتوقف التمرين وتُراجَع أخصائي.', 'Willy et al. 2019 — JOSPT (Patellofemoral Pain CPG) | Lack et al. 2015 — Br J Sports Med (Proximal muscle rehabilitation for PFP, meta-analysis)', 'https://doi.org/10.2519/jospt.2019.0302 | https://bjsm.bmj.com/content/49/21/1365', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('77ec2c36-2d29-49c1-944c-242e3fc3aa10', 'Mini Squat (Partial Range)', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'انزل نزولاً جزئياً فقط (حتى نحو 45° من ثني الركبة) مع ثبات الركبة فوق القدم وعدم انهيارها للداخل، ثم اصعد. 2–3 مجموعات × 10–15 تكرار. زد المدى تدريجياً حسب الراحة.', NULL, 'مصدر خارجي موثوق', 'JOSPT CPG 2019 — Patellofemoral Pain (Willy et al.)', 'https://doi.org/10.2519/jospt.2019.0302', 'ألم الرضفة والفخذ (الركبة الأمامية) / Patellofemoral Pain', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, 'تقوية الفخذ الأمامي والورك بحمل خفيف على مفصل الرضفة', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي. يكون الألم أثناء التمرين خفيفاً ومقبولاً (حتى 3 من 10) ويهدأ خلال 24 ساعة، وإذا زاد الألم أو ظهر تورم أو إحساس بقفل أو خذلان في الركبة يتوقف التمرين وتُراجَع أخصائي.', 'Willy et al. 2019 — JOSPT (Patellofemoral Pain CPG) | Lack et al. 2015 — Br J Sports Med (Proximal muscle rehabilitation for PFP, meta-analysis)', 'https://doi.org/10.2519/jospt.2019.0302 | https://bjsm.bmj.com/content/49/21/1365', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('67973267-c4d5-4ef1-b135-20ac2cc79cb2', 'Lateral Step-Down (Slow Eccentric)', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', NULL, 'قف على حافة درجة بقدم واحدة. انزل بالقدم الأخرى ببطء (3 ثوانٍ) مع إبقاء الحوض مستوياً والركبة فوق أصابع القدم، المس الأرض بخفة ثم اصعد. 2–3 مجموعات × 8–12 تكرار لكل رجل.', NULL, 'مصدر خارجي موثوق', 'JOSPT CPG 2019 — Patellofemoral Pain (Willy et al.)', 'https://doi.org/10.2519/jospt.2019.0302', 'ألم الرضفة والفخذ (الركبة الأمامية) / Patellofemoral Pain', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Step-up / صعود الدرجة', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, 'تحكم الورك والركبة أثناء الحمل على رجل واحدة', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي. يكون الألم أثناء التمرين خفيفاً ومقبولاً (حتى 3 من 10) ويهدأ خلال 24 ساعة، وإذا زاد الألم أو ظهر تورم أو إحساس بقفل أو خذلان في الركبة يتوقف التمرين وتُراجَع أخصائي.', 'Willy et al. 2019 — JOSPT (Patellofemoral Pain CPG) | Lack et al. 2015 — Br J Sports Med (Proximal muscle rehabilitation for PFP, meta-analysis)', 'https://doi.org/10.2519/jospt.2019.0302 | https://bjsm.bmj.com/content/49/21/1365', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('23dea696-3ba6-4c0e-a672-493e73739107', 'Clamshell', 'Glutes / المؤخرة', '{"Abductors / مبعدات الفخذ"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'استلقِ على جنبك وركبتاك مثنيتان 45° وقدماك ملتصقتان. افتح الركبة العليا كالصدفة دون تحريك الحوض للخلف، ثم أغلقها ببطء. 2–3 مجموعات × 12–20 تكرار. يمكن إضافة شريط مطاطي للتدرج.', NULL, 'مصدر خارجي موثوق', 'BJSM 2015 — Proximal muscle rehabilitation for PFP (Lack et al.)', 'https://bjsm.bmj.com/content/49/21/1365', 'ألم الرضفة والفخذ (الركبة الأمامية) / Patellofemoral Pain', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Hip External Rotation / دوران الورك للخارج', 'Hip External Rotation / دوران الورك للخارج', NULL, 'تقوية دوران الورك الخارجي والألوية الوسطى', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي. يكون الألم أثناء التمرين خفيفاً ومقبولاً (حتى 3 من 10) ويهدأ خلال 24 ساعة، وإذا زاد الألم أو ظهر تورم أو إحساس بقفل أو خذلان في الركبة يتوقف التمرين وتُراجَع أخصائي.', 'Willy et al. 2019 — JOSPT (Patellofemoral Pain CPG) | Lack et al. 2015 — Br J Sports Med (Proximal muscle rehabilitation for PFP, meta-analysis)', 'https://doi.org/10.2519/jospt.2019.0302 | https://bjsm.bmj.com/content/49/21/1365', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4aac6002-cc2a-4746-9fdf-192a36da011a', 'Wall Sit (Isometric Quad Hold)', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'ضع ظهرك على الحائط وانزل حتى ركبتين مثنيتين بزاوية مريحة (نحو 60–90°) وثبّت. 4–5 مجموعات × 30–45 ثانية مع راحة دقيقتين. يُستخدم عند ألم الوتر لتخفيف الألم قبل التمارين الأخرى.', NULL, 'مصدر خارجي موثوق', 'Br J Sports Med 2015 — Isometric exercise in patellar tendinopathy (Rio et al.)', 'https://pubmed.ncbi.nlm.nih.gov/25979840/', 'اعتلال وتر الرضفة / Patellar Tendinopathy | ألم الرضفة والفخذ (الركبة الأمامية) / Patellofemoral Pain', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Isometric Knee Extension / انقباض ثابت لمد الركبة', NULL, 'تخفيف الألم وتحميل آمن لوتر الرضفة بالانقباض الثابت', 'مبكرة', 'منخفض–متوسط', 'يُستخدم بعد تقييم فردي. يكون الألم أثناء التمرين خفيفاً ومقبولاً (حتى 3 من 10) ويهدأ خلال 24 ساعة، وإذا زاد الألم أو ظهر تورم أو إحساس بقفل أو خذلان في الركبة يتوقف التمرين وتُراجَع أخصائي.', 'Rio et al. 2015 — Br J Sports Med (Isometric exercise and analgesia in patellar tendinopathy) | Willy et al. 2019 — JOSPT (Patellofemoral Pain CPG) | Lack et al. 2015 — Br J Sports Med (Proximal muscle rehabilitation for PFP, meta-analysis)', 'https://pubmed.ncbi.nlm.nih.gov/25979840/ | https://doi.org/10.2519/jospt.2019.0302 | https://bjsm.bmj.com/content/49/21/1365', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f1aad7d7-2eaf-4477-8b39-e5a4a38798e0', 'Isometric Leg Extension Hold (Machine)', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'جهاز', 'متوسط', 'نادي', NULL, 'اجلس على جهاز فرد الركبة وثبّت الزاوية عند نحو 60° من ثني الركبة. ادفع بجهد متوسط–عالٍ (نحو 70% من أقصى قوة) وثبّت 45 ثانية، 5 مجموعات مع راحة دقيقتين. بروتوكول الدراسة المرجعية.', NULL, 'مصدر خارجي موثوق', 'Br J Sports Med 2015 — Isometric exercise in patellar tendinopathy (Rio et al.)', 'https://pubmed.ncbi.nlm.nih.gov/25979840/', 'اعتلال وتر الرضفة / Patellar Tendinopathy', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Isometric / ثابت', 'Isometric Knee Extension / انقباض ثابت لمد الركبة', NULL, 'تخفيف ألم الوتر وتقليل التثبيط العضلي', 'مبكرة', 'متوسط', 'يُستخدم بعد تقييم فردي. يكون الألم أثناء التمرين خفيفاً ومقبولاً (حتى 3 من 10) ويهدأ خلال 24 ساعة، وإذا زاد الألم أو ظهر تورم أو إحساس بقفل أو خذلان في الركبة يتوقف التمرين وتُراجَع أخصائي.', 'Rio et al. 2015 — Br J Sports Med (Isometric exercise and analgesia in patellar tendinopathy)', 'https://pubmed.ncbi.nlm.nih.gov/25979840/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e8dec305-9b26-4635-8d09-f635584b63b6', 'Slow Leg Press (Heavy Slow Resistance)', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'متوسط', 'نادي', NULL, 'ضغط الأرجل بحركة بطيئة جداً: 3 ثوانٍ للدفع و3 ثوانٍ للنزول بدون توقف. تزيد الأوزان وتقل التكرارات تدريجياً (من 15 إلى 6) خلال 12 أسبوعاً، 3 أيام في الأسبوع بالتناوب مع تمرين سكوات وهاك سكوات.', NULL, 'مصدر خارجي موثوق', 'Scand J Med Sci Sports 2009 — HSR in patellar tendinopathy (Kongsgaard et al.)', 'https://pubmed.ncbi.nlm.nih.gov/19793213/', 'اعتلال وتر الرضفة / Patellar Tendinopathy', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Leg Press / ضغط الأرجل', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, 'تحميل تدريجي لوتر الرضفة بمقاومة عالية وبطيئة', 'متوسطة–متقدمة', 'مرتفع', 'يُستخدم بعد تقييم فردي. يكون الألم أثناء التمرين خفيفاً ومقبولاً (حتى 3 من 10) ويهدأ خلال 24 ساعة، وإذا زاد الألم أو ظهر تورم أو إحساس بقفل أو خذلان في الركبة يتوقف التمرين وتُراجَع أخصائي.', 'Kongsgaard et al. 2009 — Scand J Med Sci Sports (Heavy slow resistance vs eccentric decline squat vs corticosteroid in patellar tendinopathy)', 'https://pubmed.ncbi.nlm.nih.gov/19793213/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1e5db916-31af-4eeb-9911-f74092dbc4ba', 'Modified Curl-Up (McGill)', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'استلقِ على ظهرك، ركبة مثنية والأخرى مفرودة، ويداك تحت أسفل الظهر للحفاظ على انحنائه الطبيعي. ارفع الرأس والكتفين قليلاً فقط (دون ثني أسفل الظهر) وثبّت 7–10 ثوانٍ، ثم ارجع. 3 جولات (تنازلية 6-4-2) حسب برنامج ماكجيل.', NULL, 'مصدر خارجي موثوق', 'McGill 2010 — Core training (Strength Cond J)', NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL, 'تقوية عضلات البطن بأقل حمل على العمود الفقري', 'مبكرة', 'منخفض', 'لا يُجرى مع ألم حاد أو ألم ينتشر للساق أو تنميل. يتوقف التمرين إذا زاد الألم، وتُراجَع أخصائي.', 'NICE NG59 (2020) — Low back pain and sciatica in over 16s | Hayden et al. 2021 — Cochrane (Exercise therapy for chronic low back pain) | McGill 2010 — Strength Cond J (Core training)', 'https://www.nice.org.uk/guidance/ng59 | https://doi.org/10.1002/14651858.CD009790.pub2', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d8c18aa3-0366-4c87-a57f-6e1d44003256', 'Supine Pelvic Tilt', 'Core / البطن والكور', '{"Glutes / المؤخرة"}', 'Core Activation & Breathing / تفعيل الجذع والتنفس', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'استلقِ على ظهرك وركبتاك مثنيتان. اضغط أسفل الظهر برفق نحو الأرض بشد البطن والألوية قليلاً، ثبّت 5 ثوانٍ مع تنفس طبيعي ثم استرخِ. 2 مجموعات × 10 تكرارات.', NULL, 'مصدر خارجي موثوق', 'NICE NG59 — Low back pain and sciatica in over 16s', 'https://www.nice.org.uk/guidance/ng59', 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Pelvic Control / التحكم بالحوض', 'Posterior Pelvic Tilt / إمالة الحوض للخلف', NULL, 'تفعيل الجذع وتحسين وعي الحوض في المراحل الأولى', 'مبكرة', 'منخفض', 'تمرين تمهيدي خفيف. لا تدفع بقوة، ويتوقف عند زيادة الألم.', 'NICE NG59 (2020) | Hayden et al. 2021 — Cochrane (دليل عام على التمارين، ولا توجد تجربة تعزل هذا التمرين بعينه)', 'https://www.nice.org.uk/guidance/ng59 | https://doi.org/10.1002/14651858.CD009790.pub2', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('569bcb14-f144-410b-a4c7-67f42ffb7774', 'Tyler Twist (FlexBar)', 'Forearms / الساعد', '{}', 'Wrist Extension / مد الرسغ', 'قوة', 'أخرى', 'متوسط', 'منزل', NULL, 'أمسك قضيب FlexBar عمودياً: اليد المصابة من الأعلى والسليمة من الأسفل، والرسغ المصاب مفرود للخلف. لفّ القضيب باليد السليمة (التواء)، ثم مدّ الذراعين أمامك وأرخِ الالتواء ببطء بالرسغ المصاب حتى يستقيم (حركة لامركزية بطيئة). 3 مجموعات × 15 تكرار يومياً، وتزيد مقاومة القضيب تدريجياً. هذا الوصف مبسّط، فيُراجَع مع أخصائي عند أول استخدام.', NULL, 'مصدر خارجي موثوق', 'J Shoulder Elbow Surg 2010 — Tyler Twist (Tyler et al.)', NULL, 'مرفق التنس / Lateral Elbow Tendinopathy', 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Eccentric / لامركزي', 'Wrist Extension / مد الرسغ', NULL, 'تقوية لامركزية لباسطات الرسغ لألم مرفق التنس', 'مبكرة–متوسطة', 'منخفض–متوسط', 'يكون الألم أثناء التمرين خفيفاً ومقبولاً. إذا زاد الألم أو ظهر تنميل أو ضعف في اليد يتوقف التمرين وتُراجَع أخصائي.', 'Tyler et al. 2010 — J Shoulder Elbow Surg 19(6):917–922 (Tyler Twist with FlexBar)', NULL, 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('311de6be-724b-469c-9e0e-ac0485fa7ff9', 'Single Leg Raise', 'Core / البطن والكور', '{"Glutes / المؤخرة","Hamstrings / الخلفية"}', NULL, NULL, 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/ZJodU5OOaiA?si=p6ZD9dpzyRKBUn16', 'ملاحظات مهمة:
• استلقِ وثبّت أسفل الظهر على الأرض
• ارفع الرجل بتحكم دون تقوّس الظهر
• نزول بطيء
• لا ترتد', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ff744a70-1dcb-42f5-9cd4-96eb1b794987', 'Nordic Hamstring Curl', 'Hamstrings / الخلفية', '{}', 'Knee Flexion / ثني الركبة', 'قوة', 'وزن الجسم', 'متقدم', 'بدون معدات', 'https://youtu.be/Lgibr8od0yA?si=nfRetEkDRk55Bu0a', 'ملاحظات مهمة:
• ثبّت الكعبين جيداً وانزل ببطء بجسم مستقيم من الركبة للرأس
• استخدم اليدين لتخفيف الحمل في البداية
• عُد بدفع خفيف باليدين
• ابدأ بمدى قصير لتجنب شد الخلفية', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Nordic (Eccentric) / نوردك (لامركزي)', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7deccd5f-6286-48f2-b468-18ed4323448a', 'Box Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtube.com/shorts/9uhEh9gpwUU?si=xaTY7AJiCeQfa3by', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل.

ملاحظات مهمة:
• اجلس للخلف على الصندوق بتحكم وجذع مرفوع ولا ترتمِ عليه
• توقف لحظة دون إرخاء العضلات ثم ادفع الأرض بالكعبين
• الصندوق بارتفاع يجعل الفخذ موازياً للأرض تقريباً
• الخطأ الشائع: تقوّس الظهر عند الانطلاق من الصندوق', 'تعليمات بديلة في المصدر (صف 13): ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل، انزل واثبت على البوكس ثانية وارفع.', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7bfc5640-266c-43b2-b23c-b2e63a09769d', 'Back Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/bEv6CCg2BC8', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل.

ملاحظات مهمة:
• البار على أعلى الظهر (عضلة الترابيس) لا على الرقبة، والقبضة ثابتة، والصدر مرفوع
• القدمان بعرض الكتفين وأصابعهما للخارج قليلاً، والركبتان تتبعان اتجاه الأصابع
• انزل بعمق يسمح به مدى الورك والكاحل مع شد البطن، وتجنّب انحناء أسفل الظهر في القاع
• الخطأ الشائع: رفع الكعبين أو انهيار الركبتين للداخل', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8610de54-0061-418e-8659-926ffc6db37a', 'Hack Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/0tn5K9NlCfo', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.

ملاحظات مهمة:
• ظهر وأرداف ملتصقان بالمسند طوال الحركة
• القدمان بعرض الكتفين على منتصف المنصة، وإنزالهما للأسفل يزيد تركيز الفخذ الأمامي
• انزل حتى مدى مريح للركبة ثم ادفع بكامل القدم
• لا تفرد الركبتين بقوة في الأعلى', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Machine Squat / سكوات بالجهاز', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9b4df58b-200a-47a5-8e52-b2815a1c9d94', 'Mid Leg Press', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/s9-zeWzPUmA', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.

ملاحظات مهمة:
• ضع القدمين في منتصف المنصة بعرض الكتفين
• أنزل المنصة حتى ثني الركبة نحو 90° دون أن يرتفع الحوض عن المقعد
• ادفع بكامل القدم، ولا تغلق الركبتين بقوة في الأعلى
• لا تضع اليدين على الركبتين للمساعدة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Leg Press / ضغط الأرجل', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('dcc16d18-66e8-44a6-9a15-a6130ca5ce03', 'Quads Leg Press', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/A218isnErfM', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي، ثبت القدمين أسفل اللوح لاستهداف أكبر للكوادز.

ملاحظات مهمة:
• القدمان منخفضتان على المنصة وقريبتان من بعض قليلاً لزيادة تركيز الفخذ الأمامي
• الركبتان تتجهان فوق أصابع القدم أثناء النزول
• نزول بطيء بتحكم ثم دفع بدون ارتداد
• احذر ارتفاع الحوض وتقوّس أسفل الظهر عند النزول العميق', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Leg Press / ضغط الأرجل', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d4f97644-6634-481d-af59-5fc3855f6f13', 'Deficit Goblet Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/9719SO5zvpU?si=whohbunAsXkH3j6f', 'وقف باتساع اكتافك تقريبًا، ادفع ركبك للامام وانزل، انزل لأقصى حد تقدر عليه بدون ما يتقوس ظهرك السفلي.

ملاحظات مهمة:
• ثبّت الدمبل أمام الصدر والمرفقان للأسفل
• القدمان على منصة صغيرة (ديفيزيت) تزيد مدى الحركة، فانزل بتحكم ولا تتجاوز مدى كاحلك
• حافظ على الجذع مرفوعاً والكعبين ثابتين
• الخطأ الشائع: ارتداد القاع وانحناء الظهر', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b0b682ac-5a77-47f9-9782-6ad2410f4e42', 'Front Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'بار', 'متوسط', 'نادي', NULL, 'ثبت البار على الأكتاف، ادفع ركبك للامام وانزل.

ملاحظات مهمة:
• البار على مقدمة الكتفين مع مرفقين عاليين أمام الجسم
• الجذع مستقيم أكثر من السكوات الخلفي والركبتان للأمام
• شد البطن وانزل بتحكم
• الخطأ الشائع: سقوط المرفقين فيسقط البار للأمام', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4e116cb4-634f-4f48-b2f4-9a12f9f41986', 'V Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://www.youtube.com/watch?v=u_GSjH58s0g', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.

ملاحظات مهمة:
• ثبّت الظهر والأرداف على الجهاز واجعل القدمين على المنصة بعرض الكتفين
• انزل بتحكم حتى مدى مريح وادفع بالكعبين
• لا تفرد الركبتين بالكامل بعنف
• ابقِ الركبتين باتجاه أصابع القدم', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Machine Squat / سكوات بالجهاز', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6eaf69c5-3832-4da2-8741-d420e847da20', 'Resistance Band Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/6rE0IYlMPZA?si=goqtRTlR_W4HSGBN', 'ثبت الباند علي جوانب اكتافك، ادفع ركبك للأمام وإنزل.

ملاحظات مهمة:
• ثبّت الشريط تحت القدمين ومرره على الكتفين أو أمام الصدر
• الشد يزيد في أعلى الحركة، فادفع بتحكم ولا تقفز
• ركبتان باتجاه الأصابع وصدر مرفوع
• تأكد من سلامة الشريط وثباته', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b0ef835f-72d7-4512-8f2f-74984e54d763', 'Squat Smith Machine', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/oBwhrRcNWyM', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل.

ملاحظات مهمة:
• ضع القدمين أمام خط البار قليلاً ليتمكن الجذع من البقاء مستقيماً
• انزل حتى مدى مريح مع ثبات الكعبين
• اضبط حوامل الأمان قبل البدء
• الخطأ الشائع: وضع القدمين تحت البار تماماً فيضغط على الركبتين', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Machine Squat / سكوات بالجهاز', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8a7f9c44-8537-4d22-bc45-7cbb0dc9492d', 'Single Arm Cable Facing Away Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/6sO-pK7pTPs?feature=share', 'ملاحظات مهمة:
• بيد واحدة مع ثبات الجذع
• المرفق ثابت
• اثنِ بتحكم
• نزول بطيء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a75c3fe7-b81f-4214-a12e-b9afc4617225', 'Single Leg Press', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/ZYDTJaAM-gE', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.

ملاحظات مهمة:
• ضع قدماً واحدة على منتصف المنصة والأخرى بعيداً عنها
• لا يرتفع الحوض عن المقعد ولا ينحرف للجانب
• انزل حتى 90° تقريباً بتحكم
• لا تفرد الركبة بقوة في الأعلى', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Single-leg Press / ضغط رجل واحدة', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f503b9b8-571a-43e1-8f3b-e05fb8ed1345', 'Drop Lunges', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/WH8lteLrMIs?si=61QSVA7iw_Z6Zr3p', 'تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.

ملاحظات مهمة:
• ارجع بقدم خلفاً بقوس خلف القدم الثابتة وانزل للأسفل بتحكم
• الجذع مستقيم والركبة الأمامية فوق القدم
• ادفع بكعب الرجل الأمامية للعودة
• ابدأ بوزن خفيف لإتقان التوازن', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8d7ea629-f469-4716-80c2-98e0b5b31a16', 'Beginner Lunges', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/QOVaHwm-Q6U', 'تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.

ملاحظات مهمة:
• خطوة طويلة بما يكفي لتبقى الركبة الأمامية فوق القدم
• انزل عمودياً حتى تقترب الركبة الخلفية من الأرض
• ادفع بكعب الرجل الأمامية
• يمكنك الإمساك بسند للتوازن في البداية', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2ac1c432-c77b-4580-b0ce-0ec3962c331c', 'Standing Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/rDRwAURNbzU', 'الحركة كلها بثني ومد الركبة

ملاحظات مهمة:
• قف بثبات وأمسك سنداً
• اثنِ الركبة بتحكم والجذع ثابت
• لا تتأرجح بالورك
• نزول بطيء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('13ed71a8-2d1f-40e6-bbfe-96d3d9e7f17c', 'Supported BSS', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/poBie3TTeGE?si=QSiMUYtcHhrmg8mx', 'وقف عند البنش او الستيب، ارفع رجلك وثبت اصابع قدمك على البنش، خذ خطوة وحدة للأمام برجلك الثانية ثم ابدأ التمرين، تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.

ملاحظات مهمة:
• ضع القدم الخلفية على مقعد واستند بيدك على ثابت
• انزل عمودياً والركبة الأمامية فوق القدم
• الجذع مائل قليلاً للأمام يزيد تفعيل الألوية
• لا تدفع بالقدم الخلفية', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Split Squat / سبليت سكوات', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('08f5cc31-1989-40bf-967d-c4f289c9711e', 'Supported Reverse Lunge', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/WH8lteLrMIs?si=M9s9a7qOVvvyDm82', 'ملاحظات مهمة:
• ابقَ ممسكاً بسند خفيف للتوازن، وخطوة للخلف ثم نزول عمودي
• ادفع بكعب الرجل الأمامية للعودة
• حوض مستوٍ وجذع مستقيم
• الخطأ الشائع: الاتكاء على السند بدل الرجل', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3acf9527-6efb-4cf0-ab2e-d8bf65b489e7', 'Smith Machine Reverse Lunge', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/zAVYcwnlxrQ?si=M5HL4sG-bsYBFyDQ', 'استخدم ارتفاع بسيط مثل الستيب ، ارفع نفسك بالضغط علي الرجل المرفوعة بتحكم بدون قفز.

ملاحظات مهمة:
• اضبط البار بحيث تكون القدم الأمامية تحته أو أمامه قليلاً
• خطوة للخلف ونزول بتحكم
• ادفع بكعب الرجل الأمامية
• تأكد من حوامل الأمان', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0ed49074-9555-47cd-8c0a-c9f135dadffb', 'Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/gtZ4AwZVtMI', 'اجلس وثبت ظهرك السفلي كويس، تأكد ان مسمار الارتفاع يكون بمستوى ركبتك، امسك المقابض لزيادة الثبات، إرفع الوزن اثبت ثانية فوق ثم انزل نزول كامل بتحكم.

ملاحظات مهمة:
• اضبط مسند الظهر لتكون الركبة عند محور الجهاز
• افرد الركبة بتحكم وثبّت لحظة في الأعلى
• نزول بطيء 2–3 ثوانٍ دون ارتداد الوزن
• تجنّب الأوزان الثقيلة جداً عند ألم الركبة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c83153b9-a669-4f97-870e-793f32b3dcb0', 'Band Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/hs7D3gDw3UM', 'اجلس وثبت ظهرك السفلي كويس وامسك الكرسي للثبات، اثبت ثانية فوق ثم انزل نزول كامل بتحكم.

ملاحظات مهمة:
• ثبّت الشريط خلف الكاحل وثبّت الطرف الآخر أمامك
• افرد الركبة ببطء ثم انزل بتحكم
• الشد يزداد في الأعلى فاضغط الفخذ لحظة
• تأكد من ثبات الشريط', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('68678024-b913-4183-8203-9090b40ff749', 'Sissy Squat', 'Quadriceps / الأمامية', '{"Adductors / الأفخاذ الداخلية"}', 'Knee Extension / مد الركبة', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://youtu.be/yONKTprKCDA', 'الورك ثابت طول الجولة والحركة كلها من مفصل الركبة، اذا توازنك يخرب عليك ادبل الوزن بيد واليد الثانية امسك فيها جدار او عصى

ملاحظات مهمة:
• ابدأ بسند وبمدى قصير فالتمرين متقدم على الركبة
• مِل بالجذع والركبتين للأمام وكعباك مرفوعان بخط واحد من الركبة للكتف
• انزل ببطء وارجع بتحكم
• تجنّب التمرين مع ألم الركبة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Sissy Squat / سيسي سكوات', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4d4f442e-5094-474d-be88-57e5487ac24c', 'Cable Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/ebjD98gZd8E', 'اجلس وثبت ظهرك السفلي كويس وامسك الكرسي للثبات، اثبت ثانية فوق ثم انزل نزول كامل بتحكم.

ملاحظات مهمة:
• ثبّت الكيبل على الكاحل واجلس بثبات
• افرد الركبة بتحكم ولا تتأرجح بالجذع
• شد الكيبل مستمر طوال الحركة
• نزول بطيء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6338b1ed-93ae-4464-9ed7-5bea009580ff', 'Standing Leg Extension', 'Quadriceps / الأمامية', '{"Core / البطن والكور"}', 'Knee Extension / مد الركبة', 'قوة', NULL, 'مبتدئ', NULL, NULL, 'ملاحظات مهمة:
• قف على رجل ثابتة وأمسك سنداً
• افرد الركبة بالرجل الأخرى بتحكم دون ميلان الجذع
• شد في الأعلى لحظة
• وزن خفيف مع حركة منضبطة', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/133/standing-leg-extension/', NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d8ea403a-57d8-4d59-88e3-1a756f9d1280', 'Bodyweight Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Lower back / أسفل الظهر"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'ملاحظات مهمة:
• القدمان بعرض الكتفين والذراعان أمامك للتوازن
• انزل بالورك للخلف وللأسفل والصدر مرفوع
• ركبتان باتجاه الأصابع والكعبان ثابتان
• ارتفع بدفع الأرض بكامل القدم', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/135/bodyweight-squat/', NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('024a7384-14ff-44d3-851d-11398cdda0f4', 'Cable Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/mBJXWg8ZOy0', 'اجلس على الكرسي وثبت ظهرك السفلي على المقعد تمامًا، ممكن تقدّم ظهرك العلوي وتمسك المقابض لزيادة الثبات، انزل لأقصى حد تقدر عليه وارفع لحد ما تستقيم ركبتك.

ملاحظات مهمة:
• ثبّت الكيبل على الكاحل ومرجع ثابت لليد
• اثنِ الركبة بتحكم والورك ثابت
• عودة بطيئة
• وزن مناسب دون ميلان الجذع', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('16ece208-c599-4da2-89fc-2a3bb6b9f1f0', 'DB Glutes Step Ups', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/GCnJiYJfboA?feature=share', 'استخدم ارتفاع يكون بحدود ارتفاع ركبتك أو أقل، ارفع نفسك بالضغط علي الرجل المرفوعة بتحكم بدون قفز.

ملاحظات مهمة:
• استخدم صندوقاً بارتفاع يجعل الركبة نحو 90°
• أمل الجذع قليلاً للأمام لتفعيل الألوية وادفع بكعب القدم التي على الصندوق
• انزل بتحكم دون ارتماء
• لا تدفع بالرجل الخلفية', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ff6f9020-6070-4c78-9069-5b1ef83ac582', 'Supported Glutes Step Ups', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/ZKzoOkQALaY?si=-56txwBlxSSCQYJd', 'استخدم ارتفاع يكون بحدود ارتفاع ركبتك أو أقل، ارفع نفسك بالضغط علي الرجل المرفوعة بتحكم بدون قفز.

ملاحظات مهمة:
• أمسك سنداً خفيفاً للتوازن فقط
• اصعد بالرجل التي على الصندوق وجذع مائل قليلاً
• نزول بطيء ببطء
• لا تعتمد على اليد في الصعود', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d41e04e7-2c60-47eb-b894-c5c4348c66c2', 'Cable Glutes Step Ups', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', NULL, 'ملاحظات مهمة:
• ثبّت الكيبل مناسباً للحزام أو اليدين
• اصعد بتحكم والجذع مستقيم مع إمالة بسيطة
• شد الكيبل لا يسحبك للخلف
• نزول بطيء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ce18cb73-a6a2-4956-ac9d-c422463b88e4', 'Single Arm Cable Facing In Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/I-197ZW9Ffo?si=M1Yq4R1PIpdZMXRx', 'ملاحظات مهمة:
• بيد واحدة مع ثبات الجذع
• المرفق للأمام قليلاً
• اثنِ بتحكم
• نزول بطيء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('07f729bd-7463-4d19-b4c0-e815b77db1b0', 'Glute Pushdown', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/8h2kZ64Sp5k?si=NLPf4tywxhDGY9em', 'تمسك بمقابض الجهاز، (كل ما زاد ارتفاع البنش زادت الصعوبة) + الطلوع والنزول يكون بواسطة القدم المرفوعة على البنش مو بالقدم اللي تحت، ارفع بتحكم الى أقصى ارتفاع تقدرعليه بدون ما يتقوس ظهرك السفلي، انزل لحد ما تقفل ركبتك تماما

ملاحظات مهمة:
• ثبّت جسمك على الجهاز وادفع بالقدم بتحكم
• ركّز على انقباض الألوية في نهاية الدفع
• لا تقوّس أسفل الظهر
• نزول بطيء دون ارتداد', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('238f0b15-3b43-4fd4-8512-fb1e19573133', 'Glute Max Kickbacks', 'Glutes / المؤخرة', '{}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/t5mwSx4uNMc?feature=share', 'ثبت الحبل على الكاحل، ارجع خطوة للخلف وانحني للامام قليلاً وتمسك بالكيبل لزيادة الثبات، اسحب للخلف مع انثناء بسيط بالركب.

ملاحظات مهمة:
• ثبّت الكيبل على الكاحل وأمسك بسند بيد
• ارفع الرجل للخلف من الورك دون تقوّس أسفل الظهر
• انقباض الألوية لحظة في الأعلى
• وزن خفيف مع حركة منضبطة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Kickback / ركلة خلفية', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('726aa617-5b15-4d84-8226-2b4b549e117b', 'Smith Machine Kickback', 'Glutes / المؤخرة', '{}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/GR4ny80bmhM?si=WeZcWM1hyfoLElM2', 'ملاحظات مهمة:
• ضع القدم الخلفية على البار وأمسك السميث
• ادفع للأعلى وللخلف من الورك
• الحوض ثابت دون دوران
• نزول بطيء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Kickback / ركلة خلفية', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1f12e257-f317-4e05-bec4-c8704b7d0946', 'Glute Medius Kickbacks', 'Abductors / مبعدات الفخذ', '{"Glutes / المؤخرة"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/kccsnZNbMFA?si=6c-VoB8Zsz8NxoyM', 'ثبت الحبل على الكاحل، ارجع خطوة للخلف وانحني للامام قليلاً وتمسك بالكيبل لزيادة الثبات، اسحب للخلف وللخارج مع انثناء بسيط بالركب.

ملاحظات مهمة:
• ثبّت الكيبل على الكاحل البعيد عن الكيبل وارفع الرجل للجانب والخلف
• حافظ على حوض ثابت دون دوران وجذع مستقيم
• انقباض لحظة في الأعلى
• وزن خفيف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Abduction Kickback / ركلة خلفية مع تبعيد', 'Hip Abduction + Hip Extension / تبعيد الورك + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3a22c742-49c4-4e08-a476-23e6e881bccd', 'Hip Thrusts Machine', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/0xfdeCBwoYw?si=HgJcNeB0a24gODkK', 'ممكن تسويه بالسميث مشين او البار الحر ، اختر بوكس او بنش يكون بمستوى اكتافك الخلفية وانت جالس، لما ترفع البار فوق المفروض ركبك تكون بنفس مستوى القدم.

ملاحظات مهمة:
• اضبط الجهاز ليكون الحزام على الحوض
• ادفع بالكعبين مع انقباض الألوية في الأعلى
• ذقن للأسفل قليلاً والأضلاع للأسفل
• لا تقوّس أسفل الظهر', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e28ab78e-4266-4637-8d16-9800759462e3', 'Hip Thrusts', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/O0EoaP7gR1A?si=cGPZ8iIwM2mQjwSb', 'ملاحظات مهمة:
• ظهر الكتفين على مقعد والبار على الحوض (مع وسادة)
• ركبتان بزاوية نحو 90° في الأعلى
• ادفع بالكعبين وانقباض الألوية لحظة
• الخطأ الشائع: ثني مفرط لأسفل الظهر', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d281d358-d450-4be2-a7f8-b08112c4d8e9', 'Glute Raise', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/X_kL_x4m77c', 'ثبت رجولك تحت، الاسفنجة تكون تحت الورك أعلى الفخذ مو على الورك مباشرة، امسك وزن بيدينك بذراع مستقيمة، ارفع وكأنك تبي تدخل القلوتس جوا الاسفنجة، بمجرد ما تنقبض مؤخرتك وقف لا ترفع أكثر.

ملاحظات مهمة:
• اضبط الجهاز بحيث يتحرك الورك بحرية
• ارفع الجسم من الورك حتى استقامة الجسم فقط
• لا تبالغ في تقوّس الظهر
• انقباض الألوية في الأعلى', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', '45° Hip Extension / بسط الورك على جهاز الظهر', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('841a9155-e60b-440b-9731-c4578bba4c3a', 'Single Hip Thrusts', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/ymg2AMDAwrY?si=fY8kBPTDYWRMHuAs', 'اختر بوكس او بنش يكون بمستوى اكتافك الخلفية وانت جالس، لما ترفع فوق المفروض ركبك تكون بنفس مستوى القدم، التمرين صعب طبيعي تواجه صعوبة بالبداية لذلك لا تستعجل باضافة الاوزان

ملاحظات مهمة:
• اعمل برجل واحدة والأخرى مرفوعة أو مثنية
• حافظ على حوض مستوٍ دون ميلان
• ادفع بالكعب وانقباض الألوية
• ابدأ بوزن الجسم قبل زيادة الحمل', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5ae6a377-f124-47c6-8423-3931e12a8f75', 'DB Preacher', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/DZJNTb-zzn0?si=SwbdZ0O_0eTOET-5', 'ملاحظات مهمة:
• العضد على المسند ولا يرتفع
• اثنِ وانزل ببطء دون فرد المرفق بعنف
• وزن مناسب دون زخم
• رسغ محايد', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Preacher Curl / ثني على مسند', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1b6a58ff-a331-44e8-9aab-f197230cd534', 'Glute Press', 'Glutes / المؤخرة', '{}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', NULL, 'ملاحظات مهمة:
• ثبّت الجذع على الجهاز وادفع بالقدم بتحكم
• ركّز على انقباض الألوية وليس الظهر
• لا تفرد الركبة بقوة
• نزول بطيء', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/293/glute-press/', NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Kickback / ركلة خلفية', 'Hip Extension + Knee Extension / بسط الورك + مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2c4f6a83-3b3e-43ca-bf37-3a6d0daabb16', 'Bulgarian Split Squat', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, NULL, 'ملاحظات مهمة:
• القدم الخلفية على مقعد خلفك والأمامية بمسافة كافية
• انزل عمودياً والركبة الأمامية فوق القدم
• مِل بالجذع قليلاً للأمام لتفعيل الألوية، وبشكل مستقيم للفخذ الأمامي
• ادفع بكعب الرجل الأمامية', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/366/bulgarian-split-squat/', NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Split Squat / سبليت سكوات', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('879e5bb3-bd76-4773-9cfa-4eef25e8b44f', 'Sumo Deadlift', 'Hamstrings / الخلفية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://www.youtube.com/watch?v=cDlOSfu-zHY', 'وقف بفتحة أرجل واسعة بحيث الركب تكون خط مستقيم مع كعب القدم و اصابع الرجل باتجاه الخارج، البار بمنتصف القدم، شد ظهرك العلوي وادفع الارض برجولك واسحب البار للأعلى، وقف لما تنقبض مؤخرتك ولا تبالغ بتقفيل حوضك.

ملاحظات مهمة:
• وقفة واسعة وأصابع للخارج والقبضة داخل الركبتين
• ركبتان باتجاه الأصابع وظهر محايد
• ادفع الأرض بالقدمين وارفع الورك والكتفين معاً
• البار قريب من الجسم', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Deadlift / ديدلفت', 'Hip Extension + Knee Extension / بسط الورك + مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('92c93a8c-a3ba-4ae3-9c6d-14ac655798ea', 'Conventional Deadlift', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/GxsLrTzyGUU', 'وقف باتساع اكتافك أو أوسع شوي، البار بمنتصف القدم، شد ظهرك العلوي وادفع الارض برجولك واسحب البار للأعلى، وقف لما تنقبض مؤخرتك ولا تبالغ بتقفيل حوضك.

ملاحظات مهمة:
• القدمان بعرض الحوض والبار فوق منتصف القدم
• شد البطن وثبّت الظهر محايداً قبل الرفع
• ادفع الأرض ثم افرد الورك
• البار على الجسم ولا ينحني الظهر في أي مرحلة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Deadlift / ديدلفت', 'Hip Extension + Knee Extension / بسط الورك + مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2d39510a-6679-466e-832b-918979c90985', 'Supine Cable Hamstring Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/sDCc1F5J8XA?si=Fi3D39aJogrB5ihd', 'الركبة ثبت مكانها، اسحب الحبل لاقصى حد تقدر عليه واترك رجلك تستقيم تمامًا في الانبساط.

ملاحظات مهمة:
• استلقِ على الظهر وثبّت الكيبل على الكاحل
• اسحب الكعب نحو الأرداف مع بقاء الحوض على الأرض أو مرفوعاً حسب الأداء
• تحكم في العودة
• لا تقوّس الظهر', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c25b718d-6e99-4993-9722-69cfcd85cf3f', 'BB RDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/mZxxJEncsyw', 'وقف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، انزل وادفع مؤخرتك لآخر شي تقدر عليه للخلف وكأنك بتلمس جدار خلفك مع انثناء بسيط بالركب

ملاحظات مهمة:
• ثني بسيط ثابت في الركبتين والبار قريب من الساقين
• ادفع الورك للخلف حتى تمدد الخلفية ثم عُد بدفع الورك للأمام
• ظهر محايد وكتفان للخلف
• لا تنزل أبعد من مدى مرونتك', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a43e3c7f-ac79-47aa-80ee-147e9dd89e49', 'DB RDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/RApyTtH6qAo', 'وقف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، انزل وادفع مؤخرتك لآخر شي تقدر عليه للخلف وكأنك بتلمس جدار خلفك مع انثناء بسيط بالركب

ملاحظات مهمة:
• الدمبلان قريبان من الساقين
• ادفع الورك للخلف وليس انحناء الظهر
• انزل حتى تمدد الخلفية ثم ارتفع بدفع الورك
• كتفان للخلف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a95a6418-c661-4848-b11d-722f353d8a0d', 'SM SLDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/0cB0_SzqgBU', 'ملاحظات مهمة:
• القدمان تحت البار والركبتان شبه مفرودتين
• ادفع الورك للخلف والبار على الساقين
• ظهر محايد وانزل حتى تمدد الخلفية
• حوامل أمان', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9eef657a-bc9e-444a-8351-50328d198235', 'SLDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/RApyTtH6qAo', 'قف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، ابدأ الحركة بدفع مؤخرتك للخلف والأعلى وانزل

ملاحظات مهمة:
• ركبتان شبه مفرودتين دون قفل
• الحركة من الورك وظهر مستقيم
• انزل حتى تمدد الخلفية
• ارجع بدفع الورك للأمام', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0f0c3797-ae0f-4f36-a679-50e2da84e9d5', 'Single DB SLDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/U3prDlAbJDw?si=MRSBcSIcf9M-WQBH', 'قف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، ابدأ الحركة بدفع مؤخرتك للخلف والأعلى وانزل

ملاحظات مهمة:
• دمبل بيد وثبات على رجل مع ثني بسيط
• ادفع الورك للخلف والرجل الأخرى تمتد خلفك
• حوض مستوٍ دون دوران
• استعن بسند عند صعوبة التوازن', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('998e8c35-02b5-490c-879b-054dda2e227a', 'Good Morning', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/f23vXjoG2e8?si=9rkfUF_6XUEcQ3Xs', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع مؤخرتك لأقصى قدر تقدر عليه وكأنك بتلمس جدار خلفك.

ملاحظات مهمة:
• البار على الظهر مع ثني بسيط في الركبتين
• ادفع الورك للخلف بظهر محايد حتى تمدد الخلفية
• ارجع بدفع الورك للأمام
• وزن خفيف جداً في البداية', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Good Morning / قود مورنينق', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b3e80ee0-d697-4e60-934f-387f31604763', 'Seated Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/o_J6MWyt5jM', 'اجلس على الكرسي وثبت ظهرك السفلي على المقعد تمامًا، انزل لأقصى حد تقدر عليه وارفع لحد ما تستقيم ركبتك.

ملاحظات مهمة:
• اضبط محور الركبة مع محور الجهاز وثبّت المسند على الفخذ
• اثنِ الركبة بتحكم وثبّت لحظة
• عودة بطيئة
• لا ترفع الورك عن المقعد', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b23249ed-17e7-4f42-8dea-d0ac71417bf6', 'Band Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/I-HTMUrJnxs', 'ثبت الباند فوق الكعب، اجلس على طرف البنش وتمسك بيدينك لزيادة الثبات، اسحب الحبل لاقصى حد تقدر عليه واترك رجلك تستقيم تمامًا في الانبساط.

ملاحظات مهمة:
• ثبّت الشريط على الكاحل ومرجع ثابت
• اثنِ الركبة بتحكم دون تمايل
• عودة بطيئة
• تأكد من ثبات الشريط', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9725eec0-c65a-42ab-91eb-1f878c5e4381', 'Lying Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/vl5nUdE9mWM', 'حوضك ثابت على البنش، ارفع الوزن بثني ومد الركبة بدون ما يرتفع حوضك عن الكرسي

ملاحظات مهمة:
• استلقِ بحيث تكون الركبة عند محور الجهاز
• اثنِ الركبة بتحكم دون رفع الحوض
• انقباض لحظة وعودة بطيئة
• لا تقوّس أسفل الظهر', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a4ea523b-cc77-4ba5-8698-8d9623770ab6', 'DB Lying Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/ZHlBSI6JPsA?si=SpBiHxluwrYE8CTP', 'ركبك ثابته على الارض، ارفع الوزن بثني ومد الركبة بدون ما يرتفع حوضك

ملاحظات مهمة:
• ثبّت الدمبل بين القدمين
• اثنِ الركبة بتحكم دون رفع الحوض
• وزن خفيف مع سيطرة
• نزول بطيء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d0ca15f4-02dd-4bb2-bdad-69d116a86436', 'Stability Ball Hamstring Curl', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة"}', 'Knee Flexion / ثني الركبة', 'قوة', 'كرة سويسرية', 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• ارفع الحوض ثم اسحب الكرة نحو الأرداف بالكعبين
• حافظ على الحوض مرفوعاً دون تقوّس
• عودة بطيئة
• تحكم في الكرة', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/59/stability-ball-hamstring-curl/', NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Bridge Curl / ثني الركبة مع رفع الورك', 'Knee Flexion + Hip Extension / ثني الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('86446b14-9288-4d7d-8780-a65ca1e19afc', 'Hip Hinge', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', NULL, 'مبتدئ', NULL, NULL, 'ملاحظات مهمة:
• وزن الجسم والعصا على الظهر لمراقبة الاستقامة
• ادفع الورك للخلف مع ثني بسيط للركبتين
• ظهر محايد
• لا تثنِ العمود الفقري', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/33/hip-hinge/', NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Hinge Drill / تمرين مفصلة الورك', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c4740619-61b3-4310-b593-ab70452bf6d7', 'TRX Hamstrings Curl', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة"}', 'Knee Flexion / ثني الركبة', 'قوة', 'TRX', 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• القدمان في الحزام والحوض مرفوع
• اثنِ الركبتين بالسحب نحو الأرداف مع بقاء الحوض مرتفعاً
• عودة بتحكم
• شد البطن لتجنب تقوّس الظهر', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/86/trx-reg-hamstrings-curl/', NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Bridge Curl / ثني الركبة مع رفع الورك', 'Knee Flexion + Hip Extension / ثني الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b5a697d5-2cc1-4ebf-8ce9-4437dca983cc', 'Flat DB Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/xphvjGDZeYE', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا

ملاحظات مهمة:
• ثبّت لوحي الكتف للخلف وللأسفل على المقعد
• انزل الدمبلين بتحكم حتى مستوى الصدر، والمرفقان بزاوية نحو 45–70°
• ادفع للأعلى دون رفع الكتفين
• حافظ على قدمين ثابتتين وأرداف على المقعد', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('eb71451f-6d9b-470f-a686-3863edaddb2d', 'DB Floor Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/UBmpZ7l5Nlk?si=kDcN-ueaTFxfKtbr', 'ملاحظات مهمة:
• استلقِ على الأرض وانزل حتى لمس العضد للأرض بخفة
• ادفع للأعلى دون ارتداد
• لوحا الكتف للخلف
• مدى أقصر من المقعد وهو آمن للكتف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('59416c81-b9db-491f-b456-3bd0dd98aab2', 'Flat Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/vcBig73ojpE', 'استلق على بنش،القبضة بنفس مستوى الاكتاف أو أوسع قليلًا، قوّس ظهرك العلوي قليلاً، انزل لين تلمس صدرك واثبت ثانية ثم ارفع.

ملاحظات مهمة:
• العينان تحت البار وقبضة أوسع قليلاً من الكتفين
• ثبّت لوحي الكتف للخلف وللأسفل وصدر مرفوع
• انزل بتحكم إلى أسفل الصدر وادفع بخط ثابت
• استعن بمساعد أو حوامل أمان عند الأوزان الثقيلة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('69117ae7-f951-4045-a87a-bde869b70c57', 'Machine Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/pOCRC2kpxB8?si=02xGtrfPjiYpspMv', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا

ملاحظات مهمة:
• اضبط المقعد ليكون المقبض بمستوى منتصف الصدر
• الكتفان للخلف والظهر ملتصق بالمسند
• ادفع دون قفل المرفقين وانزل بتحكم
• لا ترفع الكتفين', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8e445021-775d-4cd7-8b5d-1d28bfb7df21', 'Feet Up Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/HrehfM1dmBE', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا

ملاحظات مهمة:
• القدمان مرفوعتان على المقعد لتقليل تقوّس الظهر
• ثبّت الظهر على المقعد وانزل بتحكم
• وزن أخف من الضغط العادي
• حافظ على لوحي الكتف للخلف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b9a99cec-c597-4026-b8c1-3f1c5ed7e234', 'Torso Elevated Push Up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/noaPB7u4_CU', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا

ملاحظات مهمة:
• اليدان على مرتفع (مقعد) لتخفيف الحمل
• جسم مستقيم من الرأس للكعب والبطن مشدود
• انزل بالصدر نحو المرتفع والمرفقان بزاوية نحو 45°
• لا تدلِّ الورك', 'تصنيف فرعي: اليدان مرفوعتان؛ زاوية الضغط بالنسبة للجذع تشبه الضغط المائل لأسفل رغم تسميته الشائعة Incline Push-up — يحدده المدرب', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Decline Press / ضغط مائل لأسفل', 'Horizontal Adduction + Shoulder Extension / تقريب أفقي + مد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b701f744-e2cd-439f-b0ad-3059161e1901', 'Push Up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://youtu.be/WDIpL0pjun0?si=utydS_A8QfRIJtJm', 'ملاحظات مهمة:
• اليدان بعرض الكتفين أو أوسع قليلاً والجسم خط مستقيم
• انزل بالصدر حتى قرب الأرض والمرفقان بزاوية 45°
• ادفع دون تدلي الورك أو رفعه
• شد البطن والألوية', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fb53279e-e7af-452d-be25-bf2272faf372', 'Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://www.youtube.com/watch?v=JvOJdUtx6UQ', 'استلق على بنش،القبضة بنفس مستوى الاكتاف أو أوسع قليلًا، قوّس ظهرك العلوي قليلاً، انزل لين تلمس صدرك واثبت ثانية ثم ارفع.

ملاحظات مهمة:
• العينان تحت البار وقبضة أوسع قليلاً من الكتفين
• ثبّت لوحي الكتف وصدر مرفوع، وقدمان ثابتتان
• انزل بتحكم وادفع بخط ثابت
• حوامل أمان أو مساعد للأوزان الثقيلة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('844ea849-149a-4dbe-8c85-c7f2bd4e54d9', 'Paused Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://www.youtube.com/shorts/Q3GmnmJISwE', 'استلق على بنش،القبضة بنفس مستوى الاكتاف أو أوسع قليلًا، قوّس ظهرك العلوي قليلاً، انزل لين تلمس صدرك واثبت 3 ثواني ثم ارفع.

ملاحظات مهمة:
• انزل بتحكم واثبت ثانية على الصدر دون استرخاء ثم ادفع
• الوزن أخف من الضغط العادي
• ثبّت لوحي الكتف طوال التوقف
• لا ترتد بالبار', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4bbb3e81-594f-4128-9686-871e11e64957', 'Incline Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/0G2_XV7slIg', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا

ملاحظات مهمة:
• اضبط الميل بزاوية معتدلة (نحو 30°)
• ثبّت لوحي الكتف وانزل بتحكم إلى أعلى الصدر
• لا ترفع الأرداف
• لا تجعل الميل شديداً فيتحول التمرين لكتف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Incline Press / ضغط مائل لأعلى', 'Shoulder Flexion + Horizontal Adduction / ثني الكتف + تقريب أفقي', 'Incline Press / ضغط مائل لأعلى', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4a04aeb3-1011-434c-8d4c-03e2f872d50d', 'Smith Machine Incline Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/EeLLZMdg6zI?si=UVsgFN7jhXMm0vW3', 'ملاحظات مهمة:
• ضع المقعد بحيث ينزل البار على أعلى الصدر
• ثبّت لوحي الكتف وانزل بتحكم
• اضبط الحوامل
• لا ترفع الأرداف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Incline Press / ضغط مائل لأعلى', 'Shoulder Flexion + Horizontal Adduction / ثني الكتف + تقريب أفقي', 'Incline Press / ضغط مائل لأعلى', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c11087a8-8065-43b9-a21a-df42da187d98', 'Cable Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/tAILewhtCb0', 'اجلس على بنش انكلاين، اضبط الكيبل بمستوى صدرك تقريبا، ادفع الوزن للأمام باتجاه الداخل، احرص ان كوعك ما يكون بنفس ارتفاع كتفك

ملاحظات مهمة:
• اضبط الكيبل بمستوى الصدر أو أعلى حسب الميل
• قف أو اجلس بثبات وادفع للأمام مع تقريب اليدين
• تحكم في العودة
• الجذع ثابت دون ميلان', 'تصنيف فرعي: التعليمات تذكر بنش انكلاين، وتصنيف المصدر iso_push_chest — يُحسم بين Incline Press وعزل الصدر', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Incline Press / ضغط مائل لأعلى', 'Shoulder Flexion + Horizontal Adduction / ثني الكتف + تقريب أفقي', 'Incline Press / ضغط مائل لأعلى', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('39b29131-858e-4507-ae84-cf645a0b3e73', 'Sternal Cable Press Around', 'Chest / الصدر', '{}', 'Horizontal Push / دفع أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/y8XQibXDnNo', 'اضبط الكيبل بمستوى صدرك تقريبا، حافظ على ذراعك قريبة من جسمك،ادفع الحبل للأمام باتجاه الداخل.

ملاحظات مهمة:
• ادفع بتقريب اليدين أمام منتصف الصدر
• لا تغلق المرفقين بقوة
• ركّز على انقباض الصدر
• الجذع ثابت وكتفان للخلف', 'تصنيف فرعي: حركة مختلطة بين الضغط والـ Fly — يُحسم بين Flat Press وعزل الصدر', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Press-around / ضغط مع تقريب', 'Horizontal Adduction + Elbow Extension / تقريب أفقي + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8bd588dc-130b-4217-9845-6ad310b21466', 'Machine Chest Fly', 'Chest / الصدر', '{}', 'Horizontal Adduction (Fly) / تقريب أفقي للكتف (فلاي)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', NULL, 'ملاحظات مهمة:
• اضبط المقعد ليكون المرفقان بمستوى الصدر
• ثني بسيط ثابت في المرفقين
• افتح حتى تمدد مريح ثم ضم بقوة
• لا ترفع الكتفين', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Chest Isolation / عزل الصدر', 'Horizontal Adduction / تقريب أفقي للكتف', 'Chest Isolation / عزل الصدر', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b2eaf398-9526-4622-acd8-7c894b79bc84', 'Bar Cable Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/NhD3h6RG2TA?si=SoyNTIGB-nY2KiXl', 'ملاحظات مهمة:
• استخدم القضيب أمام الصدر والكيبل بالمنتصف
• ادفع بتحكم دون ميلان الجذع
• الكتفان للخلف
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2fa3994e-4b01-4199-90bb-13cac1b299b3', 'DB Chest Supported Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/H75im9fAUMc', 'ثبت صدرك على الكرسي، فتحة واسعة، واسحب الدمبل باتجاه الورك.

ملاحظات مهمة:
• صدرك على مقعد مائل لتثبيت الجذع
• اسحب الدمبلين نحو الجانبين مع ضم لوحي الكتف
• لا ترفع الصدر عن المقعد
• انزل ببطء حتى تمدد', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b376d457-d285-4f4a-995a-cbc563b39b6b', 'Cable Chest Fly', 'Chest / الصدر', '{"Shoulders / الأكتاف"}', 'Horizontal Adduction (Fly) / تقريب أفقي للكتف (فلاي)', 'قوة', 'كيبل', 'مبتدئ', 'نادي', NULL, 'ملاحظات مهمة:
• ضع الكيبل بمستوى الكتف أو أعلى وخطوة أمامية للثبات
• ثني بسيط ثابت في المرفقين
• قرّب اليدين أمام الصدر بقوس
• لا تنزل اليدين أسفل مستوى الصدر', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/160/standing-chest-fly/', NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Chest Isolation / عزل الصدر', 'Horizontal Adduction / تقريب أفقي للكتف', 'Chest Isolation / عزل الصدر', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c6b556a2-9ff7-460b-8b2f-3459881646d6', 'Bent Knee Push-up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'ملاحظات مهمة:
• الركبتان على الأرض والجسم خط من الركبة للرأس
• انزل بالصدر حتى قرب الأرض والمرفقان 45°
• ادفع بدون تدلي الحوض
• تدرّج لاحقاً للضغط الكامل', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/13/bent-knee-push-up/', NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6f38ed0d-76ff-4c70-b3b5-fa79ff0b6202', 'Stability Ball Push-Up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس","Core / البطن والكور"}', 'Horizontal Push / دفع أفقي', 'قوة', 'كرة سويسرية', 'متوسط', 'منزل', NULL, 'ملاحظات مهمة:
• اليدان على الكرة أو القدمان عليها حسب الصعوبة
• حافظ على جسم مستقيم وثبات الكرة
• نزول بتحكم
• الخطأ الشائع: تمايل الكرة وتدلّي الورك', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف فرعي: الزاوية تعتمد على موضع الكرة (تحت اليدين أو القدمين) — غير محدد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/63/stability-ball-push-up/', NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('dcfee4b4-f1dc-46c3-982f-926dee664450', 'Cable Reardelt Rows', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/uIdXVGjcfFE', 'ثبت نفسك بالكرسي، فتحة واسعة، الكيبل بمستوى اسفل صدرك، واسحب لما تنقبض اكتافك الخلفية.

ملاحظات مهمة:
• اجلس أو قف وأمسك الحبل بقبضة والمرفقان للجانبين بمستوى الكتف
• اسحب نحو الوجه والمرفقان عاليان مع ضم لوحي الكتف
• لا تتمايل بالجذع
• وزن خفيف مع انقباض لحظة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Wide-grip Row / تجديف بقبضة واسعة', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('46792d0b-57c4-4fa2-b533-76307d2b9f66', 'DB Triceps Extensions', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/d7SXlU5HkYM?si=WuuPa9-yeByaP5sI', 'ملاحظات مهمة:
• مرفقان قريبان من الرأس وثابتان
• انزل خلف الرأس بتحكم ثم افرد المرفقين
• شد البطن وجذع ثابت
• وزن مناسب', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Overhead Extension / مد فوق الرأس', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a3d167da-8037-49d5-9c16-ea0d8667550a', 'DB Chest Supported Reardelt Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/x0v6GWYzI18?si=-jDt3D-ARIHouHjp', 'ثبت صدرك على الكرسي، فتحة واسعة، واسحب لما تنقبض اكتافك الخلفية.

ملاحظات مهمة:
• صدرك على مقعد مائل والدمبلان للأسفل
• ارفع المرفقين للجانبين بمستوى الكتف
• لا ترفع الرقبة ولا تستخدم الزخم
• وزن خفيف مع انقباض الكتف الخلفي', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Wide-grip Row / تجديف بقبضة واسعة', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d5f484f2-96c2-4444-abdc-3ff97f9b18da', 'Bent-over Barbell Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'بار', 'متوسط', 'نادي', NULL, 'ادفع مؤخرتك للخلف واثني ركبك، قبضتك بنفس مستوى اكتافك، اسحب لما تنقبض عضلات الظهر.

ملاحظات مهمة:
• انحنِ من الورك حتى جذع شبه موازٍ للأرض وظهر محايد
• اسحب البار نحو أسفل الصدر والمرفقان قريبان من الجسم
• ثبّت الجذع ولا ترفعه لتعويض الوزن
• الخطأ الشائع: تقوّس الظهر وتأرجح الجذع', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fd597b80-4f12-4ad0-886f-7fc1f24291a1', 'Cable Reardelt Fly', 'Shoulders / الأكتاف', '{"Rotator cuffs / الكفة المدورة"}', 'Shoulder Rear Pull / سحب خلفي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/bkejPHrPkmA?si=-O8q_5e72udoPRiY', 'ملاحظات مهمة:
• مرفقان مثنيان قليلاً وثابتان
• افتح الذراعين للجانبين بمستوى الكتف باتجاه الخلف
• لا تتمايل بالجذع
• وزن خفيف وانقباض لحظة', 'تصنيف فرعي: حركة Fly (تبعيد أفقي للكتف) وليست سحباً أفقياً أو عمودياً', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Rear Delt Fly / فتح خلفي', 'Horizontal Abduction / تبعيد أفقي للكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('111b7118-d77c-414d-91e5-4b58babba901', 'Head Supported Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/c6lkPMhuyFA?si=eUivRGYSi0W7PmVe', 'راسك ثابت على البنش بدون أي ميلان بالرقبة.

ملاحظات مهمة:
• الجبهة أو الصدر على المسند لتثبيت الجذع
• اسحب بالمرفقين وضم لوحي الكتف
• لا ترفع الرقبة
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e171b0d2-1cb0-4935-95d6-aff9a0117d7a', 'Single Arm Dumbbell Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/QBjaGx8mS1o', 'اسحب باتجاه الورك.

ملاحظات مهمة:
• ركبة ويد على المقعد وظهر مسطح
• اسحب الدمبل نحو الورك والمرفق قريب من الجسم
• لا تدوّر الجذع
• انزل حتى تمدد لوح الكتف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ccf7755e-9f02-4483-ba9f-ee4d890febd1', 'Single Arm Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/Qn_mHGObb8E?si=IZ0q9_tseiRIMtcs', 'اسحب باتجاه الورك.

ملاحظات مهمة:
• ثبات القدمين والجذع
• اسحب المقبض نحو الخصر مع ضم لوح الكتف
• لا تميل أو تدوّر الجذع
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a2413978-e1ac-40ef-9402-d2abfb3c5ecd', 'Chin Ups', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متقدم', 'نادي', 'https://youtube.com/shorts/aV9Mz9nCsMw?si=E_ullJojGO_7srW2', 'ملاحظات مهمة:
• قبضة معكوسة بعرض الكتفين
• اسحب المرفقين للأسفل وللخلف حتى الذقن فوق القضيب
• تعلّق كامل في الأسفل
• تجنّب التأرجح', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('23ad5aff-736e-4654-b1d5-3b57b6f5e456', 'Chest Supported Machine Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/BZrdEAiR2Xs?si=WhKaSGhR0gKeeies', 'ملاحظات مهمة:
• اضبط المقعد ليكون الصدر على المسند والذراعان ممدودتان
• اسحب المقبضين وضم لوحي الكتف
• لا ترفع الكتفين
• عودة بتحكم', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('443dc2b5-53ed-4469-be74-fab227462c32', 'T-Bar Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/6OtcNinT0HM?si=UPfYyypfZCaN9tTA', 'ملاحظات مهمة:
• ظهر محايد وانحناء من الورك
• اسحب نحو الصدر والمرفقان قريبان من الجسم
• لا تدور الجذع
• حافظ على قبضة ثابتة وركبتين مثنيتين قليلاً', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f7f134aa-805c-408e-89da-774579d53823', 'Lats Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/CQkT-W18N5g', 'الكيبل بنفس مستوى بطنك، اسحب باتجاه الورك.

ملاحظات مهمة:
• اسحب المقبض نحو أسفل البطن وليس الصدر
• المرفقان قريبان من الجسم وصدر مرفوع
• لا تميل للخلف كثيراً
• تمدد اللاتس في العودة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Lat-focused Row / تجديف لاتس', 'Shoulder Extension / مد الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9cf36ee4-a7f7-4177-b5d6-bc8ff5bd80ad', 'Upperback Pulldowns', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/bNmvKpJSWKM?si=hy5HgBDAHkzFHcvv', 'ملاحظات مهمة:
• اسحب القضيب نحو أعلى الصدر مع ضم لوحي الكتف والمرفقان للجانبين
• جذع مائل قليلاً للخلف دون تأرجح
• لا ترفع الكتفين
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Wide-grip Pulldown / سحب علوي بقبضة واسعة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4dd7f3a2-a953-4fad-b53a-6009721fd845', 'Straight Arm Pulldown', 'Back & Lats / الظهر واللاتس', '{}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/hAMcfubonDc?si=ocU_a8VQ4VzZnTg3', 'ملاحظات مهمة:
• ذراعان شبه مستقيمتين
• اسحب القضيب للأسفل نحو الفخذين بحركة من الكتف
• شد البطن ولا تقوّس الظهر
• شعور بتمدد اللاتس في الأعلى', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Straight-arm Pull / سحب بذراع مستقيمة', 'Shoulder Extension + Scapular Depression / مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c6f46b30-4eb7-421c-8c16-fdb50e927fa2', 'DB Y Raises', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/lXp16YozXgk', 'ثبت صدرك على البنش،ارفع الوزن على شكل Y.

ملاحظات مهمة:
• ارفع الذراعين بشكل Y أمام الجسم والإبهام للأعلى
• وزن خفيف جداً
• ثبّت الصدر ولا تتمايل
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Y Raise (Scaption) / رفع Y بمستوى لوح الكتف', 'Shoulder Elevation in Scapular Plane (Scaption) / رفع الذراع بمستوى لوح الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d75409c5-f293-4b60-b097-7b32dc797be0', 'DB Pullover', 'Back & Lats / الظهر واللاتس', '{"Chest / الصدر","Triceps / الترايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/ieFKuQAGYIA?si=uwqyrbKhBL6Id3_-', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.

ملاحظات مهمة:
• استلقِ على مقعد والدمبل بكلتا اليدين فوق الصدر
• انزل خلف الرأس بذراعين شبه مستقيمتين حتى تمدد مريح
• عُد بالسحب بالكتف
• لا تقوّس الظهر ولا تنزل أكثر من مدى كتفك', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Straight-arm Pull / سحب بذراع مستقيمة', 'Shoulder Extension + Scapular Depression / مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('09889b54-575a-43a7-ad7a-c4a27a74a637', 'Band Lat Pulldown', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/5R0RYj3Y9Ro', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.

ملاحظات مهمة:
• ثبّت الشريط عالياً واسحب نحو أعلى الصدر
• المرفقان للأسفل وللجانبين
• لا تتمايل بالجذع
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('72a73ba0-da54-4b15-b7f1-a5ae32ccb79a', 'Band Assisted Pull Ups', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://youtu.be/Ks8ah-8P1b0', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.

ملاحظات مهمة:
• ضع الشريط على الركبة أو القدم لتخفيف الوزن
• ابدأ من تعلّق كامل واسحب حتى الذقن فوق القضيب
• تجنّب التأرجح
• انزل ببطء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a08fb528-1dd0-4212-8870-4cad5df6caf1', 'Pull Ups', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متقدم', 'نادي', 'https://youtu.be/x3NPAxiMRPw?si=Mwg6U1Df5aIFpjKB', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.

ملاحظات مهمة:
• قبضة أوسع قليلاً من الكتفين وتعلّق كامل بكتفين منخفضين
• اسحب المرفقين نحو الجنبين حتى الذقن فوق القضيب
• تجنّب التأرجح واللعب بالرأس
• انزل ببطء 2–3 ثوانٍ', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('08df0597-aaca-4cea-921c-d57e5d3cdcd2', 'Negative Pull-Up', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://youtu.be/gbPURTSxQLY?si=TvQF5zDWfU_rR1Ax', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر، نزول بطيء.

ملاحظات مهمة:
• اصعد بقفزة أو بمساعدة ثم انزل ببطء 3–5 ثوانٍ
• تحكم كامل حتى تعلّق كامل
• الكتفان منخفضان
• لا تسقط في النهاية', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a58af20a-8c6c-4a09-befd-4395ea0de224', 'Neutral Grip Lat Pulldown', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/kVB6SlEyjQM', 'القبضة بنفس مستوى الكتف، اسحب باتجاه اعلى الصدر.

ملاحظات مهمة:
• قبضة محايدة والمقبض قريب
• اسحب نحو أعلى الصدر والمرفقان للأسفل
• جذع مائل قليلاً دون تأرجح
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4f1ff2e0-3066-43b7-8cec-95e0ef1e67ec', 'Single Lats Pulldown', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/Qed5O9toqT8', 'اجلس على بنش واسند صدرك عليه، ارجع للخلف قليلا بحيث ان الكيبل ما يكون فوق راسك مباشرة، اسحب الكوع باتجاه الورك.

ملاحظات مهمة:
• اعمل بيد واحدة مع ثبات الجذع
• اسحب المرفق نحو الجنب
• لا تدوّر الجذع
• عودة بطيئة حتى تمدد اللاتس', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('39869c02-0155-4315-b8f5-aae3e2948a51', 'Band Assisted Chin Ups', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://youtu.be/i0yC-0YK6Uk?si=gNX26kIFz_THnR4p', 'مسكة ضيقة بمستوى الأكتاف، كل ما كان الحبل خفيف زادت المقاومة وزدات صعوبة التمرين لذلك ابدأ بحبل ثقيل وخفف كل ما تحسن مستواك.

ملاحظات مهمة:
• قبضة معكوسة وشريط مساعد
• اسحب حتى الذقن فوق القضيب
• تحكم بالنزول
• لا تتأرجح', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b6e38eab-d817-405b-8b0a-7910a28999a0', 'Kneeling Lat Pulldown', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', NULL, 'متوسط', NULL, NULL, 'ملاحظات مهمة:
• اركع بثبات وجذع مستقيم
• اسحب الكيبل نحو أعلى الصدر أو الخصر بحسب الاتجاه
• لا تجلس على الكعبين
• عودة بطيئة', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/35/kneeling-lat-pulldown/', NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e87de2e0-c984-45c0-90fe-3c8d6683b203', 'TRX Back Row', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس","Core / البطن والكور","Lower back / أسفل الظهر"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'TRX', 'متوسط', 'منزل', NULL, 'ملاحظات مهمة:
• جسم مستقيم ومائل للخلف حسب الصعوبة
• اسحب الصدر نحو المقابض وضم لوحي الكتف
• الورك لا يتدلى
• عودة بطيئة', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/84/trx-reg-back-row/', NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1a5c0fc9-0cef-441c-ba96-f479b992f94f', 'Shrug', 'Back & Lats / الظهر واللاتس', '{"Trapezius / الترابيس"}', 'Scapular Elevation / رفع لوح الكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, 'ملاحظات مهمة:
• ارفع الكتفين مباشرة نحو الأذنين دون تدوير
• ثبّت لحظة في الأعلى وانزل بتحكم
• ذراعان مستقيمتان
• لا تحرك الرقبة للأمام', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف فرعي: رفع الأكتاف (Shrug) ليس نمط سحب أفقي أو عمودي', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/72/shrug/', NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Shrug / هز الكتفين', 'Scapular Elevation / رفع لوح الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('02ef8a3c-93b1-49ef-a771-d33e059cf062', 'DB Shoulder Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/NKeyUrDYqPk', 'قوّس ظهرك العلوي قليلاً، الكوع قريب من الجسم، النزول الى مستوى الاكتاف

ملاحظات مهمة:
• اجلس بظهر مسنود وانزل الدمبلين حتى مستوى الأذنين
• ادفع للأعلى بخط فوق الكتفين
• لا تغلق المرفقين بعنف
• لا تبالغ في تقوّس الظهر', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('aef1e601-4aac-4576-8578-476d56f36d1d', 'DB Standing Shoulder Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/wO0l5jW2NtQ?si=MVvS4F_7iFS8ji9R', 'ملاحظات مهمة:
• قف بثبات وشد البطن والألوية
• ادفع للأعلى دون ميلان الجذع للخلف
• انزل حتى الأذنين
• وزن مناسب دون زخم', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f943e74c-7af0-44f2-aa9a-8125a77bac95', 'Machine Shoulder Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/3R14MnZbcpw', 'قوّس ظهرك العلوي قليلاً، الكوع قريب من الجسم، النزول الى مستوى الاكتاف

ملاحظات مهمة:
• اضبط المقعد ليكون المقبض بمستوى الكتف
• الظهر ملتصق بالمسند
• ادفع دون رفع الكتفين
• عودة بتحكم', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('646cd154-cc80-4da8-b2e6-14c92d0d5efb', 'BB Overhead Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/_RlRDWO2jfg', 'ملاحظات مهمة:
• قبضة أوسع قليلاً من الكتفين
• شد البطن والألوية وادفع بخط مستقيم
• حرّك الرأس للخلف ثم للأمام عند مرور البار
• لا تقوّس أسفل الظهر', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d370842b-57dd-4856-a4ad-c58482e35943', 'DB Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/qqntiuPmLDM?feature=share', 'انحني للأمام قليلًا، ارفع للأعلى الى أن تصل لمستوى الأكتاف.

ملاحظات مهمة:
• ارفع بمرفق مثني قليلاً حتى مستوى الكتف فقط
• قدّم المرفق على اليد ولا ترفع الكتفين نحو الأذنين
• نزول بطيء 2–3 ثوانٍ
• لا تتأرجح بالجذع', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f1f9c2e3-ddf7-4ba3-b3f4-5a910bd2f95f', 'Seated Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/v7fwGurZ9SU?feature=share', 'انحني للأمام قليلًا، ارفع للأعلى الى أن تصل لمستوى الأكتاف.

ملاحظات مهمة:
• اجلس بظهر مسنود لإزالة الزخم
• ارفع حتى مستوى الكتف والمرفقان مثنيان قليلاً
• نزول بطيء
• وزن خفيف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3d4fe315-bf9b-4173-87b5-223eff3d3693', 'Lateral Raise Machine', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/d0pRsZ9SY5w?si=XuXb_Ti0Flow7qvW', 'ملاحظات مهمة:
• اضبط المقعد ليكون محور الكتف مع محور الجهاز
• ارفع الذراعين للجانبين دون رفع الكتفين
• نزول بطيء
• لا تدفع بالجذع', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('12e2db5f-2e21-49fc-ac57-01bbbd67cc03', 'Cable Crossover Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/wKgCc5UQjoU?si=zsaz3i31PnEU9A43', 'الكيبل يبدأ من الأسفل، انحني للأمام قليلًا، ارفع للأعلى وتحكم بالنزول.

ملاحظات مهمة:
• الكيبل من الجهة المقابلة
• ارفع الذراع قطرياً للجانب حتى مستوى الكتف
• جذع ثابت
• وزن خفيف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('68b0cec9-afa7-471d-8e3c-7b168ca9515b', 'Cable Y Raises', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/P7u6PEeOn6Q?feature=share', 'الكيبل يبدأ من تحت،ارفع الوزن على شكل Y.

ملاحظات مهمة:
• الكيبل من الأسفل ويدك على شكل Y
• ارفع نحو الأعلى وللخارج بخط قطري
• وزن خفيف وثبات الجذع
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Y Raise (Scaption) / رفع Y بمستوى لوح الكتف', 'Shoulder Elevation in Scapular Plane (Scaption) / رفع الذراع بمستوى لوح الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('43a506b9-9a7d-442c-89d6-eb1e26fff61d', 'Single Arm DB Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/Jm6GqVhWhNY', 'انحني للأمام قليلًا، ارفع للأعلى الى أن تصل لمستوى الأكتاف.

ملاحظات مهمة:
• اعمل بيد واحدة وأمسك سنداً بالأخرى
• ارفع حتى مستوى الكتف دون ميلان الجذع
• نزول بطيء
• وزن خفيف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5b0c5537-eccd-4c5c-840a-b900342c4892', 'Single Arm Cable Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/J-6uEOkYAKM', 'الكيبل يبدأ من الأسفل، انحني للأمام قليلًا، ارفع للأعلى وتحكم بالنزول.

ملاحظات مهمة:
• ثبّت الجذع وارفع الذراع للجانب
• الكيبل يعطي شداً من البداية فتحكم في الأسفل
• حتى مستوى الكتف
• لا ترفع الكتف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('46ed6558-be36-4feb-b25c-41af9470f4c7', 'Front Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Front Raise / رفع أمامي للكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, 'ملاحظات مهمة:
• ارفع حتى مستوى الكتف فقط والمرفق مثني قليلاً
• لا تتأرجح بالجذع
• نزول بطيء
• وزن مناسب', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/54/front-raise/', NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Front Raise / رفع أمامي', 'Shoulder Flexion / ثني الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('588175ee-cfeb-4269-9353-aa369b9f3896', 'Diagonal Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, 'ملاحظات مهمة:
• ارفع بخط قطري من الفخذ المقابل نحو الكتف
• حرّك بتحكم دون تدوير الجذع
• وزن خفيف
• حتى مستوى الكتف', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/371/diagonal-raise/', NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Diagonal Raise / رفع قطري', 'Shoulder Flexion + Abduction (Diagonal) / ثني وتبعيد الكتف (قطري)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('47825c16-f7f5-4fc5-8b22-90ecee38acf0', 'High Row', 'Shoulders / الأكتاف', '{}', 'Shoulder Rear Pull / سحب خلفي للكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, 'ملاحظات مهمة:
• اسحب نحو الوجه والمرفقان للأعلى وللجانبين
• دوّر الذراعين للخارج في النهاية
• لا تتمايل للخلف
• الرسغ مستقيم', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/336/high-row/', NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'High Row / Face Pull / سحب عالٍ باتجاه الوجه', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c213f7c3-c7f0-43ba-b46b-d29da1019c32', 'Biceps Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/09AYfVFf7pg?si=dcwLVAYqIbDLM6jd', 'ملاحظات مهمة:
• المرفقان ثابتان بجانب الجسم ولا تتأرجح
• اثنِ حتى انقباض كامل وانزل ببطء 2–3 ثوانٍ
• رسغ محايد
• لا ترفع الكتفين', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('786e11ea-96a9-4fc8-bb44-8b92c0dbb2c3', 'Cable Rope Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/xNXUTJ6TBZA?si=-r-Ql97awoVZla_1', 'ملاحظات مهمة:
• قبضة محايدة بالحبل والمرفقان ثابتان
• اثنِ وأدر الحبل للخارج في الأعلى
• نزول بطيء
• الجذع ثابت', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Hammer / Neutral-grip Curl / ثني بقبضة محايدة', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0919381b-2cac-47ff-9939-24cca58da948', 'Cable Facing Away Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/fV9BpknCjGM', 'ملاحظات مهمة:
• وجهك بعيداً عن الكيبل والذراعان للخلف قليلاً
• اثنِ بالمرفقين مع ثباتهما
• تمدد البايسبس في الأسفل
• لا تتأرجح', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a6742eb1-53a3-455d-8ea0-2da5fea942a2', 'DB Incline Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/js_StxxyxBM', 'ملاحظات مهمة:
• على مقعد مائل والذراعان خلف الجسم
• اثنِ بالمرفقين دون تقديمهما للأمام
• تمدد كامل في الأسفل
• وزن خفيف نسبياً', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0766750f-5bd1-4913-ae1f-c9f26cbc55f1', 'Cable Facing In Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/5z4y7QRTx1w', 'ملاحظات مهمة:
• وجهك للكيبل والمرفقان للأمام قليلاً
• اثنِ حتى انقباض كامل
• حافظ على شد الكيبل
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d3f9276a-8f79-4cf7-91ea-efed3935cf9e', 'Preacher Curl Machine', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/TouYMA3-ua4?feature=share', 'ملاحظات مهمة:
• اضبط المقعد ليكون العضد على المسند
• اثنِ حتى انقباض
• نزول بطيء دون فرد عنيف
• لا ترفع الكتفين', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Preacher Curl / ثني على مسند', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8b6cb62e-b691-4ca2-80ac-1e779e61b978', 'DB Spider Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/cTMjzB2_IH8?si=qsIKEEFVfEvPXwqf', 'ملاحظات مهمة:
• الصدر على مقعد مائل والذراعان للأسفل
• اثنِ بالمرفقين مع ثباتهما
• انقباض في الأعلى
• نزول بطيء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3761c5ef-df2f-4a43-a642-9591f1d9bc8b', 'Zottman Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://www.youtube.com/watch?v=ZXbOOIOPOi8', 'ملاحظات مهمة:
• اثنِ بقبضة عادية ثم دوّر الرسغ في الأعلى وانزل بقبضة معكوسة
• نزول بطيء
• وزن خفيف للساعد
• المرفق ثابت', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('573d92d1-99c8-47de-9719-96a855c32b14', 'Hammer Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• قبضة محايدة والمرفقان ثابتان
• اثنِ دون تأرجح
• نزول بطيء
• الإبهام للأعلى', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/10/hammer-curl/', NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Hammer / Neutral-grip Curl / ثني بقبضة محايدة', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('38fda179-9589-4d7a-942f-635c81ac2f54', 'TRX Biceps Curl', 'Biceps / البايسبس', '{"Forearms / الساعد","Core / البطن والكور"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'TRX', 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• جسم مستقيم ومائل للخلف والمرفقان للأمام
• اثنِ المرفقين نحو الجبهة
• عودة بطيئة
• الورك لا يتدلى', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/78/trx-reg-biceps-curl/', NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('13efe4e6-2998-4d44-9319-2d675d4fdc98', 'DB Floor Triceps Extensions', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/dpFav9Ve4rY?si=ZBdKK8VF4aPMpi3v', 'ملاحظات مهمة:
• استلقِ على الأرض والمرفقان للأعلى
• انزل نحو الجبهة أو خلف الرأس بتحكم
• افرد المرفقين دون تحريك العضد
• وزن خفيف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Lying Extension / مد مستلقٍ', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5ff7b3dc-6761-42d9-8704-440530c689e6', 'Cable Crossbody Extensions', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://www.youtube.com/watch?v=jtLTcED38Dg', 'الكيبل يبدأ بالمنتصف زي الفيديو، بحيث لما تسحب الكيبل يكون بنفس مستوى الترابس، الأكواع والأكتاف ثابتين مكانهم والحركة كلها بثني وفرد الكوع.

ملاحظات مهمة:
• اسحب الكيبل بالمرفق ثابتاً وعبر الجسم
• افرد بالكامل مع انقباض الترايسبس
• العضد ثابت
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Cross-body Extension / مد عرضي', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f123b27a-2a3f-42d8-bdd0-763d847f858f', 'Triceps Pushdown', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/QsoN4u6j8nM?feature=share', 'انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.

ملاحظات مهمة:
• المرفقان ثابتان بجانب الجسم
• افرد المرفقين بالكامل مع انقباض لحظة
• عودة بطيئة دون رفع الكتفين
• لا تتمايل', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a04880a1-d36b-4aac-a73e-103c3b95d0e7', 'Cable Crossover Pressdowns', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/Y3CDzx-oj3k', 'الكيبل يبدأ من الأعلى،انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.

ملاحظات مهمة:
• ادفع من الجهتين بمرفقين ثابتين
• افرد بالكامل وانقباض
• عودة بطيئة
• جذع ثابت', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c167de34-a981-4773-a4ab-35fba3932b07', 'Band Triceps Pushdown', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/mYs1rEYtZK4?si=k8vdZxNNEB5wj2CA', 'الكيبل يبدأ من الأعلى،انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.

ملاحظات مهمة:
• ثبّت الشريط عالياً
• افرد المرفقين مع بقاء العضد ثابتاً
• عودة بطيئة
• تأكد من ثبات الشريط', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1121332d-65b8-4b3f-b7f0-9f40dc2e349d', 'Single Cable Triceps Pressdowns', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/8rl4ioij6lc', 'الكيبل يبدأ من الأعلى،انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.

ملاحظات مهمة:
• بيد واحدة والمرفق ثابت
• افرد بالكامل
• عودة بطيئة
• جذع ثابت', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('78f8be3b-ad16-4cc5-90a1-98a5370c0ff5', 'Cable Overhead Extension', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://www.youtube.com/shorts/Q3bO1Fh4734', 'اترك الحبل يسحب معصمك وكوعك ثابت لما تستطيل التراي ثم ارفع الوزن لما تستقيم اليد، كوعك ثابت طول الوقت والحركة ثني ومد من مفصل الكوع، ممكن تطبق كل يد لحالها اذا كان اسهل لك.

ملاحظات مهمة:
• وجهك للأمام أو الخلف والمرفقان قريبان من الرأس
• افرد المرفقين فوق الرأس بتحكم
• شد البطن لتجنب التقوّس
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Overhead Extension / مد فوق الرأس', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('30815f70-c698-4e1c-8431-826220ba0b14', 'Triceps Dips', 'Triceps / الترايسبس', '{"Chest / الصدر","Shoulders / الأكتاف"}', 'Vertical Push / دفع عمودي', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/SpSE_A5L-YA?si=bSAzRM9SBuX-3mE0', 'ملاحظات مهمة:
• جسم مستقيم على مقعد أو متوازي
• انزل بالمرفقين حتى 90° تقريباً
• لا تتجاوز مدى كتفك
• توقف عند ألم الكتف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Dip / متوازي', 'Shoulder Extension + Elbow Extension / مد الكتف + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('94a6be50-124b-40e3-b0ac-9ff0ced8475f', 'Triceps Kickback', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/YebyKE3Ts8o?si=H_h9z5BXutFBbFhq', 'ملاحظات مهمة:
• العضد موازٍ للجسم وثابت
• افرد المرفق للخلف بتحكم
• انقباض في الأعلى
• وزن خفيف', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/55/triceps-kickback/', NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Triceps Kickback / ركلة الترايسبس', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('dac231cd-d5d0-45af-8ccb-1eb2dacb80e9', 'Suitcase Carry', 'Core / البطن والكور', '{"Forearms / الساعد"}', 'Loaded Carry / حمل ومشي', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/BaRMAhD7SP4?si=KkiMH8OSIEz_TB53', 'ملاحظات مهمة:
• امشِ بجذع مستقيم دون ميلان نحو الوزن
• كتفان ثابتان وخطوات منتظمة
• شد البطن
• بدّل الجهة', 'نفس التمرين ورد أيضاً تحت التصنيف «Functional Training» (صف المصدر 160) || رابط آخر في المصدر (صف 160): https://youtu.be/BaRMAhD7SP4?si=dCR2n2VSPaHhxfL3', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Suitcase Carry / حمل جانبي', 'Isometric Trunk + Grip Under Load / تثبيت الجذع والقبضة أثناء المشي', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d4d63a0a-dac4-4174-befb-a4e151b6b25c', 'Cable Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/ToJeyhydUxU?si=Z5dv34foxX4VtRH6', 'الحركة عبارة عن ثني للعمود الفقري وكأنك تقرب صدرك لوركك.

ملاحظات مهمة:
• اركع أمام الكيبل والحبل عند الرأس
• اثنِ الجذع نحو الأرض بتقوّسه
• الحوض ثابت والحركة من البطن
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Crunch / كرنش', 'Trunk Flexion / ثني الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('66ffeb12-9dbd-4811-bf34-db9e771bf56d', 'Leg Raises', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/UqmbxvOgnX4?si=U3pDG4Jf0x1mtC_7', 'ملاحظات مهمة:
• علّق أو استلقِ وثبّت الظهر
• ارفع الرجلين بتحكم دون تأرجح
• اثنِ الركبتين عند الصعوبة
• نزول بطيء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Reverse Crunch / Leg Raise / كرنش عكسي ورفع الأرجل', 'Hip Flexion + Posterior Pelvic Tilt / ثني الورك + إمالة الحوض للخلف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2546b51a-f704-44c2-ad45-455938c39a3d', 'Bosu Ball Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'أخرى', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/KjvDgHPxXcg?si=zad59CHC6Y-calzi', 'ملاحظات مهمة:
• استلقِ على الكرة وأسفل الظهر مدعوم
• اثنِ الجذع للأعلى بتحكم
• لا تسحب الرقبة
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Crunch / كرنش', 'Trunk Flexion / ثني الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6f6b0a0d-aba0-4c72-b7b1-e0e69291d160', 'Bent Knee V-Up', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/sbyFIM30_G8?si=dED0NQSRS44dz5G9', 'ملاحظات مهمة:
• ارفع الجذع والركبتين معاً نحو بعضهما
• حركة بطيئة بتحكم
• أسفل الظهر لا يتقوس
• زفير عند الرفع', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'V-up / في أب', 'Trunk Flexion + Hip Flexion / ثني الجذع + ثني الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2d401e53-d0c8-43c3-98f2-4435036df7e2', 'Reverse Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/esYVzdEfs04?si=N44MZZHlVeSQc1S3', 'ملاحظات مهمة:
• ارفع الحوض عن الأرض بتقوّس أسفل الظهر
• لا تستخدم الزخم
• نزول بطيء
• الركبتان مثنيتان', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Reverse Crunch / Leg Raise / كرنش عكسي ورفع الأرجل', 'Hip Flexion + Posterior Pelvic Tilt / ثني الورك + إمالة الحوض للخلف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('bbad9bef-df3b-4589-bb01-0dbade9bc098', 'Belly Breathing', 'Core / البطن والكور', '{}', 'Core Activation & Breathing / تفعيل الجذع والتنفس', 'إحماء/تفعيل', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/Shk8cmgv0Ew?si=mXkcj9PH6eH_tLcd', 'نفس عميق من الانف ننفخ فيه البطن ثم نطلعه من الفم ببطئ مع ضغط البطن للداخل اثناء اخراج النفس

ملاحظات مهمة:
• شهيق بطيء من الأنف يوسّع البطن
• زفير بطيء من الفم
• الكتفان مرتخيان
• لا ترفع الصدر', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Diaphragmatic Breathing / تنفس حجابي', 'Diaphragmatic Breathing + Abdominal Bracing / تنفس حجابي + شد البطن', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('379389f6-cfca-4000-a8e3-bc2e8fa16ec5', 'Reverse Tabletop Bridge', 'Core / البطن والكور', '{"Glutes / المؤخرة"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://youtu.be/d1yE9cGtPWo?si=2aoNqmUAN054rP75', 'اخذ نفس اثناء الطلوع، اثبت ثواني فوق واشد عضلات بطني، اطلع النفس اثناء النزول

ملاحظات مهمة:
• ارفع الورك حتى استقامة الجسم مع اليدين خلفك
• انقباض الألوية
• الرأس محايد
• لا تبالغ في تقوّس الظهر', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('89875b6d-fb13-4ddf-bd32-d0814652f13d', 'Pelvic Tilting', 'Core / البطن والكور', '{}', 'Core Activation & Breathing / تفعيل الجذع والتنفس', 'إحماء/تفعيل', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/DqqUIfMuDX4?si=uzl0SRl_M9guUT3j', 'الحركة من الحوض، اخذ نفس وادف حوضي للاعلى قليلا، اطلع النفس اثناء نزول الحوض والصق اسفل ظهري بالارض

ملاحظات مهمة:
• حركة صغيرة ناعمة من الحوض بشد البطن
• لا ترفع الأرداف
• تنفس طبيعي
• لا تضغط بقوة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Pelvic Tilt / إمالة الحوض', 'Posterior Pelvic Tilt / إمالة الحوض للخلف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ac6a07fc-e94a-4be9-85d3-054318956c6c', 'Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'ملاحظات مهمة:
• ارفع الكتفين فقط عن الأرض
• لا تسحب الرقبة باليدين
• زفير عند الرفع وانقباض لحظة
• نزول بطيء', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/52/crunch/', NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Crunch / كرنش', 'Trunk Flexion / ثني الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b984da28-45a9-4a9e-b73b-e1fdf096f108', 'Standing Wood Chop', 'Core / البطن والكور', '{}', 'Trunk Rotation / دوران الجذع', 'كور', NULL, 'مبتدئ', NULL, NULL, 'ملاحظات مهمة:
• دوّر من الجذع والورك والذراعان شبه مستقيمتين
• حرّك من الأعلى للأسفل بخط قطري
• الحوض مستقر
• تحكم في العودة', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/108/standing-wood-chop/', NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Rotation / Chop / دوران وتقطيع', 'Trunk Rotation / دوران الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('aed71285-480d-4b9f-a74a-95d88bf41aa2', 'Russian Twist', 'Core / البطن والكور', '{"Lower back / أسفل الظهر"}', 'Trunk Rotation / دوران الجذع', 'كور', NULL, 'مبتدئ', NULL, NULL, 'ملاحظات مهمة:
• اجلس مائلاً قليلاً بجذع مستقيم
• دوّر الكتفين والجذع لا اليدين فقط
• الرجلان على الأرض عند الصعوبة
• حركة بطيئة', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/65/russian-twist/', NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Rotation / Chop / دوران وتقطيع', 'Trunk Rotation / دوران الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('61f48f60-9984-476a-add4-760c2c4e971a', 'Cable Twisted', 'Core / البطن والكور', '{"Lower back / أسفل الظهر"}', 'Trunk Rotation / دوران الجذع', 'كور', 'كيبل', 'مبتدئ', 'نادي', NULL, 'ملاحظات مهمة:
• ثبّت الحوض ودوّر من الجذع
• ذراعان شبه مستقيمتين
• تحكم في العودة
• وزن مناسب', NULL, 'إضافة المدربة', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Rotation / Chop / دوران وتقطيع', 'Trunk Rotation / دوران الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('bb6faa2b-a0c8-484f-a11b-756d38d238b1', 'Calves On Leg Press', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/XdtWVYFVhGU', 'ثبت أصابعك أو مقدمة رجلك على الجهاز، لا تبالغ بالوزن، انزل بكعبك لين تمتد بطاتك بشكل كامل ثم ادفع.

ملاحظات مهمة:
• القدمان على الحافة السفلى للمنصة والركبتان مفرودتان قليلاً دون قفل
• ادفع بمقدمة القدم لأقصى ارتفاع ثم انزل حتى تمدد البطة
• توقف لحظة في الأعلى والأسفل
• لا ترتد', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fc57cd32-feee-43e6-840f-6d4191fe4857', 'Calves Raise', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/H6WptvjXkgw', 'حط تحت اقدامك بليتس أو أي شي يرفعك عن الأرض، انزل من اصابعك اقصى نزول ثم ادفع للأعلى

ملاحظات مهمة:
• ارتفع على أطراف الأصابع لأقصى مدى
• انزل حتى تمدد البطة
• توقف في الأعلى
• حركة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3f897a84-3277-4145-a96e-9caffae27a67', 'Calf Raise (Machine)', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', 'جهاز', 'مبتدئ', 'نادي', NULL, 'ملاحظات مهمة:
• ضع الكتفين تحت المساند وأصابع القدم على الحافة
• ارتفع لأقصى مدى وانزل حتى تمدد
• توقف لحظة في الأعلى
• لا ترتد', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/294/calf-raise/', NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f8188f97-0e8f-420e-b209-916b31c139c2', 'Calf Raises (Barbell)', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', 'بار', 'مبتدئ', 'نادي', NULL, 'ملاحظات مهمة:
• البار على أعلى الظهر وقوف ثابت
• ارتفع على الأصابع بتحكم
• مدى كامل بدون ارتداد
• سند للتوازن', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/51/calf-raises/', NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9c92f3f3-0f0a-4555-a792-5e912df688f0', 'Adductor Slides', 'Adductors / الأفخاذ الداخلية', '{}', 'Hip Adduction / تقريب الورك', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/6U7dfuxaX9g?si=lkH35E7tZxGBePBj', 'ملاحظات مهمة:
• انزلق بالرجل للجانب بتحكم
• الجذع ثابت
• ادفع للعودة بالعضلة الداخلية
• حركة بطيئة', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor strength»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Adductor Slide / انزلاق للتقريب', 'Hip Adduction / تقريب الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a9cdf1af-5eff-4029-84cc-0bfbe41cec40', 'Adductor Machine', 'Adductors / الأفخاذ الداخلية', '{}', 'Hip Adduction / تقريب الورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/SU1LQhq3o2g?si=_55FKBOlcn8Ilw4X', 'ملاحظات مهمة:
• اضبط مدى مريح للبداية
• اضغط الفخذين معاً بتحكم
• عودة بطيئة دون ارتداد
• لا تفتح أكثر من مدى مريح', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Adductor Machine / جهاز التقريب', 'Hip Adduction / تقريب الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('75f47949-c691-4848-a32e-295138b89916', 'Supine Hamstrings Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'استلقِ على ظهرك وارفع رجلاً واحدة ومدّها ببطء مع سحب أصابع القدم نحوك، دون أي حركة في الحوض أو أسفل الظهر. اثبت 15–30 ثانية، 2–4 مرات لكل رجل.

ملاحظات مهمة:
• استلقِ وارفع رجلاً بمساعدة شريط أو يدين
• ركبة شبه مفرودة بدون ألم
• شد مريح للخلفية
• ثبّت 20–40 ثانية', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/235/supine-hamstrings-stretch/', NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Hamstring Stretch / إطالة الخلفية', 'Hip Flexion with Knee Extended / ثني الورك مع مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('74b9261c-be85-41fa-9a04-78796081bd49', 'Seated Abductor Machine', 'Abductors / مبعدات الفخذ', '{}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/riEMreTHNbM?si=wE3vfJBYQY7j_oJ2', 'ملاحظات مهمة:
• ظهر ملتصق بالمسند
• افتح الركبتين للخارج بتحكم
• انقباض لحظة
• عودة بطيئة', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor strength»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0c89d7c4-84fb-4a05-9f65-e6e3abb458b3', 'Hip Abductor Plank', 'Abductors / مبعدات الفخذ', '{"Core / البطن والكور"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/2lB5RL91yWo?si=WRm9rUORpFK6dXPl', 'ملاحظات مهمة:
• بلانك جانبي بجسم مستقيم
• ارفع الرجل العليا بتحكم
• الحوض لا يميل
• ثبّت الكتف تحت المرفق', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor strength»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ffa7379d-79d6-4c3d-9ea8-d77aa2a9f3d8', 'Dirty Dog', 'Abductors / مبعدات الفخذ', '{"Core / البطن والكور"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'ملاحظات مهمة:
• على أربع مع ظهر محايد
• ارفع الركبة للجانب كالكلب بتحكم
• الحوض ثابت دون ميلان
• حركة بطيئة', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/109/dirty-dog/', NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2e1b4b58-bb34-47bb-bc92-0a014fcef1ae', 'Rotator Cuff', 'Rotator cuffs / الكفة المدورة', '{}', 'Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/mO8YJAxVG2M?si=KL_llR6Z47Yt89uk', 'ملاحظات مهمة:
• وزن خفيف جداً والمرفق ملتصق بالجسم
• دوّر الساعد للخارج بتحكم دون ألم
• حركة بطيئة
• لا تقوّس الظهر', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «Functional Training»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'External Rotation / دوران خارجي', 'Shoulder External Rotation / دوران خارجي للكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('28249b86-5bc8-4450-89a8-ab8aafe35e09', 'Side Lying Quadriceps Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'استلقِ على جنبك وشد البطن، واسحب كعب الرجل العلوية نحو المؤخرة بيدك مع إبقاء الركبة في خط الورك. اثبت 30–45 ثانية، 2–5 مرات لكل جهة.

ملاحظات مهمة:
• على الجنب اسحب الكعب نحو الأرداف
• الركبتان متقاربتان والحوض ثابت
• شد مريح بدون ألم الركبة
• ثبّت 20–40 ثانية', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/149/side-lying-quadriceps-stretch/', NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Quadriceps Stretch / إطالة الأمامية', 'Knee Flexion + Hip Extension (End Range) / ثني الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('017c0ff8-3b8b-4053-bc2d-14ae78391e9c', 'Stability Ball Reverse Extensions', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة"}', 'Spinal Extension / بسط الجذع', 'كور', 'كرة سويسرية', 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• على بطنك على الكرة
• ارفع الرجلين بتحكم حتى استقامة الجسم
• لا تبالغ بالتقوّس
• شد الألوية', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/64/stability-ball-reverse-extensions/', NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Reverse Extension / بسط عكسي', 'Hip Extension + Spinal Extension / بسط الورك + بسط العمود الفقري', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cb880508-0ca5-4f39-99eb-fb8d9bfa861f', 'Contralateral Limb Raises', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة","Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Spinal Extension / بسط الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'ملاحظات مهمة:
• على أربع، ارفع اليد والرجل المقابلة بتحكم
• الحوض والظهر ثابتان دون ميلان
• ثبّت لحظة
• بدّل الجهة', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/53/contralateral-limb-raises/', NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Prone Extension / بسط على البطن', 'Spinal Extension / بسط العمود الفقري', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('75d33853-de99-4572-aed5-6d205cbbdef3', 'Inner Thigh Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/uqCfJYKojLU?si=Gev0VeOwVp5z6gB2', 'الضغط والدفع يكون من جهة الفخذ ، لا تدفع من ركبتك!

ملاحظات مهمة:
• اجلس بفتح الرجلين وقدمين ملتصقتين
• اضغط الركبتين للأسفل برفق
• شد مريح وليس ألماً
• ثبّت 20–40 ثانية', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «stretch»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Adductor Stretch / إطالة المقربات', 'Hip Abduction (Adductor Stretch) / تبعيد الورك (إطالة المقربات)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3f151158-fdd9-4eca-9297-73033f237d53', 'Hips Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/uqCfJYKojLU?si=Gev0VeOwVp5z6gB2', 'ملاحظات مهمة:
• وضعية ممتدة للورك بجذع مستقيم
• اضغط برفق دون ألم
• تنفس بهدوء
• ثبّت 20–40 ثانية', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «stretch»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Hip Stretch / إطالة الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5ac2334d-7b1d-4d9c-af06-b3fc56bb8c40', 'Kneeling Hip-flexor Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'من وضع الركوع: الركبة الخلفية تحت الورك والقدم الأمامية أمامك والركبة فوق الكاحل. شد البطن وادفع الحوض للأمام دون تقويس أسفل الظهر، واعصر مؤخرة الجهة الخلفية لزيادة الإطالة. اثبت 30–45 ثانية، 2–5 مرات.

ملاحظات مهمة:
• ركبة على الأرض والأخرى أمامك
• ادفع الحوض للأمام مع شد البطن
• شد في مقدمة الورك
• لا تقوّس أسفل الظهر', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/142/kneeling-hip-flexor-stretch/', NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Hip Flexor Stretch / إطالة ثانيات الورك', 'Hip Extension (End Range) / بسط الورك في نهاية المدى', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('27a517b8-a2a7-4e70-97cf-7f04128aba66', 'Standing Lunge Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'ملاحظات مهمة:
• وضعية لانج ثابتة وحوض للأمام
• جذع مستقيم وشد البطن
• شد في مقدمة ورك الرجل الخلفية
• ثبّت 20–40 ثانية', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/137/standing-lunge-stretch/', NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Hip Flexor Stretch / إطالة ثانيات الورك', 'Hip Extension (End Range) / بسط الورك في نهاية المدى', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('32df053a-c085-442e-a30b-529b1eef965c', 'Lateral Bound', 'Plyometrics / التمارين الانفجارية', '{"Glutes / المؤخرة","Quadriceps / الأمامية","Abductors / مبعدات الفخذ"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://www.youtube.com/watch?v=soqQy4dzEts', 'ملاحظات مهمة:
• اقفز جانبياً وهبوط ناعم على رجل واحدة
• الركبة فوق القدم دون انهيار
• ثبّت لحظة
• ابدأ بمسافة قصيرة', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «Functional Training»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Lateral Jump / قفز جانبي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('76c2d5bc-c31e-4de6-a4b4-05876fe7fa24', 'Box Jumps', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Calves / البطات"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'أخرى', 'متوسط', 'نادي', NULL, 'ملاحظات مهمة:
• اقفز بانفجار وهبوط ناعم على صندوق
• الركبتان مثنيتان عند الهبوط
• انزل بالخطوة لا بالقفز
• ابدأ بارتفاع منخفض', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «CrossFit»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Vertical Jump / قفز عمودي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('931e763a-af9f-48d9-82d6-ca9cd3bb63af', 'Squat Jump', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متوسط', 'بدون معدات', NULL, 'قف بعرض الحوض، ادفع الورك للخلف وانزل، ثم اقفز بقوة بمدّ الكاحل والركبة والورك معاً. انزل بهدوء على منتصف القدم مع دفع الورك للخلف ودون قفل الركب. ابدأ بقفزات صغيرة حتى تتقن الهبوط.

ملاحظات مهمة:
• انزل بسكوات ثم اقفز لأعلى بانفجار
• هبوط ناعم على كامل القدم
• الركبتان باتجاه الأصابع
• أوقف المجموعة عند هبوط الأداء', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/222/squat-jump/', NULL, 'review', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Vertical Jump / قفز عمودي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('50b97236-0949-42a2-89b8-35266b495a02', 'Tuck Jump', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متقدم', 'بدون معدات', NULL, 'استخدم الذراعين للزخم: أرجعهما للخلف عند النزول وأرجحهما للأمام والأعلى عند القفز، واسحب الركبتين نحو الصدر في الهواء.

ملاحظات مهمة:
• اقفز واسحب الركبتين نحو الصدر
• هبوط ناعم والركبتان مثنيتان
• حافظ على جذع مستقيم
• مجموعات قصيرة', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/180/tuck-jump/', NULL, 'review', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Vertical Jump / قفز عمودي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('57cc7676-5773-4ff8-858f-f5006ea0716f', 'Cycled Split-Squat Jump', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Hamstrings / الخلفية"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متقدم', 'بدون معدات', NULL, 'ملاحظات مهمة:
• من وضع لانج اقفز وبدّل الرجلين في الهواء
• هبوط ناعم والركبة فوق القدم
• جذع مرفوع
• مجموعات قصيرة', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/234/cycled-split-squat-jump/', NULL, 'review', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Split Jump / قفز سبليت', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c5d66830-3e19-4e90-b18f-735ccc1505ab', 'Lateral Cone Jumps', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Calves / البطات"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'أخرى', 'متوسط', 'نادي', NULL, 'ملاحظات مهمة:
• اقفز جانبياً فوق الحواجز بتحكم
• هبوط ناعم وركبتان مثنيتان
• حافظ على الجسم متزناً
• مسافة آمنة', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/120/lateral-cone-jumps/', NULL, 'review', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Lateral Jump / قفز جانبي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('21180806-d8c3-479b-b6aa-3a0d2dbdd6b7', 'Forward Linear Jumps', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Hamstrings / الخلفية"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متوسط', 'بدون معدات', NULL, 'ملاحظات مهمة:
• اقفز للأمام بانفجار وهبوط ناعم
• ركبتان باتجاه الأصابع
• حافظ على توازنك قبل القفزة التالية
• مسافات قصيرة في البداية', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/177/forward-linear-jumps/', NULL, 'review', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Horizontal Jump / قفز أمامي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0054c0a5-aa72-4434-8bf5-e21de913d7dd', 'Jogging', 'CrossFit / كروس فت', '{"Quadriceps / الأمامية","Hamstrings / الخلفية","Calves / البطات"}', 'Locomotion / مشي وجري ودفع', 'كارديو', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'ملاحظات مهمة:
• ابدأ بإحماء تدريجي وخطوات خفيفة
• جذع مستقيم وكتفان مرتخيان
• زد السرعة والمسافة تدريجياً
• حذاء مناسب', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Running / جري', 'Gait: Alternating Hip/Knee Extension / نمط المشي والجري', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('277f5554-633b-4c45-8e8f-9e73cd2e6df3', 'Wall Ball', 'CrossFit / كروس فت', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Shoulders / الأكتاف"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'أخرى', 'متوسط', 'نادي', NULL, 'ملاحظات مهمة:
• سكوات ثم رمي الكرة على الهدف بانفجار
• ابدأ بوزن خفيف
• استقبل الكرة بذراعين مرنتين
• ركبتان باتجاه الأصابع', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Squat to Throw / سكوات مع رمي', 'Knee/Hip Extension + Shoulder Flexion / مد الركبة والورك + ثني الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d8750ce2-452e-48a3-b56e-ba1645cff844', 'Snatch', 'CrossFit / كروس فت', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Shoulders / الأكتاف"}', 'Olympic Lift (Triple Extension) / رفعات أولمبية (بسط ثلاثي)', 'قدرة', 'بار', 'متقدم', 'نادي', NULL, 'ملاحظات مهمة:
• تقنية معقدة، تعلّمها بعصا أو وزن خفيف وبإشراف مدرب
• البار قريب من الجسم
• الدفع من الورك والركبة والكاحل
• ظهر محايد', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Snatch / سناتش', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5ffaf748-3d3a-4a4b-9f4d-7a846147c710', 'Clean', 'CrossFit / كروس فت', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Quadriceps / الأمامية"}', 'Olympic Lift (Triple Extension) / رفعات أولمبية (بسط ثلاثي)', 'قدرة', 'بار', 'متقدم', 'نادي', NULL, 'ملاحظات مهمة:
• تقنية معقدة، ابدأ بوزن خفيف وبإشراف مدرب
• الدفع من الورك ثم استقبال البار بمرفقين عاليين
• البار قريب من الجسم
• ظهر محايد', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Clean / كلين', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('faac12b3-1639-458c-98e5-8528f338a2b3', 'Turkish Get-Up', 'Functional / التمارين الوظيفية', '{"Shoulders / الأكتاف","Core / البطن والكور","Glutes / المؤخرة"}', 'Full-body Integrated / حركة متكاملة للجسم', 'قوة', 'كيتلبل', 'متقدم', 'منزل', 'https://www.youtube.com/watch?v=0bWRPC49-KI', 'ملاحظات مهمة:
• تحرك بخطوات واضحة وعيناك على الوزن
• الذراع عمودية فوقك طوال الحركة
• ابدأ بدون وزن
• حركة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Turkish Get-Up / النهوض التركي', 'Multi-joint Integrated / حركة متعددة المفاصل', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5e2dbd1f-1c98-412c-9739-622d841691ba', 'Sled Pull/Push', 'Functional / التمارين الوظيفية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Calves / البطات"}', 'Locomotion / مشي وجري ودفع', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://www.youtube.com/watch?v=3KWK7SIdPz4', 'ملاحظات مهمة:
• جذع ثابت مائل للأمام
• خطوات قوية متتالية
• تنفس منتظم
• وزن يسمح بالحفاظ على الوضعية', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Sled Push / Pull / دفع وسحب الزلاجة', 'Hip/Knee Extension in Gait / بسط الورك والركبة بنمط المشي', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b368183b-b1aa-41d4-a2e2-2ecb4e1a0b4d', 'Farmer’s Walk', 'Functional / التمارين الوظيفية', '{"Forearms / الساعد","Core / البطن والكور","Back & Lats / الظهر واللاتس"}', 'Loaded Carry / حمل ومشي', 'قوة', NULL, 'مبتدئ', NULL, 'https://www.youtube.com/watch?v=hx24PM6gXs8', 'ملاحظات مهمة:
• قبضة قوية وكتفان للخلف
• جذع مستقيم وخطوات قصيرة
• شد البطن
• لا تتمايل', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Farmer''s Walk / مشي المزارع', 'Isometric Trunk + Grip Under Load / تثبيت الجذع والقبضة أثناء المشي', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1405ba07-f087-4174-ab6a-ecf7313cb3ff', '90s Transition', 'Functional / التمارين الوظيفية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://www.youtube.com/watch?v=ogU-azeGe_k', 'ملاحظات مهمة:
• اجلس بزاوية 90° للورك والركبة وانتقل بتحكم
• جذع مستقيم
• حركة بطيئة ضمن مدى مريح
• لا تفرض المدى', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Hip Rotation Mobility (90/90) / مرونة دوران الورك', 'Hip Internal/External Rotation / دوران الورك الداخلي والخارجي', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('05f929dd-57ec-421b-8443-b4167a3394bb', 'Kettlebell Swing', 'Functional / التمارين الوظيفية', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Core / البطن والكور"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قدرة', 'كيتلبل', 'متوسط', 'منزل', 'https://www.youtube.com/watch?v=d94xX-AQZ0A', 'ملاحظات مهمة:
• ادفع الورك للأمام بانفجار ولا ترفع الكيتلبل بالذراعين
• ظهر محايد وركبتان مثنيتان قليلاً
• شد الألوية في الأعلى
• الكيتلبل يعود بين الساقين بتحكم', 'نفس التمرين ورد أيضاً تحت التصنيف «CrossFit» (صف المصدر 168)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Ballistic Hinge (Swing) / مفصلة انفجارية (سوينق)', 'Hip Extension (Ballistic) / بسط الورك الانفجاري', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f2da7996-247c-4f5e-87c0-14cd0e2b8faa', 'Serratus Punches Supine', 'Functional / التمارين الوظيفية', '{"Shoulders / الأكتاف","Chest / الصدر"}', 'Horizontal Push / دفع أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/cxaAqmdlrgk?si=2YRAIgFFXPAvDadG', 'ملاحظات مهمة:
• استلقِ والذراعان نحو السقف
• ادفع الكتف للأعلى بحركة لوح الكتف دون ثني المرفق
• حركة صغيرة بتحكم
• لا ترفع الرأس', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'Scapular Protraction / دفع لوح الكتف', 'Scapular Protraction / دفع لوح الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;



INSERT INTO public.exercise_alternatives VALUES ('7bfc5640-266c-43b2-b23c-b2e63a09769d', '7deccd5f-6286-48f2-b468-18ed4323448a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7bfc5640-266c-43b2-b23c-b2e63a09769d', 'd4f97644-6634-481d-af59-5fc3855f6f13', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7bfc5640-266c-43b2-b23c-b2e63a09769d', 'b0b682ac-5a77-47f9-9782-6ad2410f4e42', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7bfc5640-266c-43b2-b23c-b2e63a09769d', '6eaf69c5-3832-4da2-8741-d420e847da20', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7bfc5640-266c-43b2-b23c-b2e63a09769d', 'd8ea403a-57d8-4d59-88e3-1a756f9d1280', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7deccd5f-6286-48f2-b468-18ed4323448a', '7bfc5640-266c-43b2-b23c-b2e63a09769d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7deccd5f-6286-48f2-b468-18ed4323448a', 'd4f97644-6634-481d-af59-5fc3855f6f13', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7deccd5f-6286-48f2-b468-18ed4323448a', 'b0b682ac-5a77-47f9-9782-6ad2410f4e42', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7deccd5f-6286-48f2-b468-18ed4323448a', '6eaf69c5-3832-4da2-8741-d420e847da20', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7deccd5f-6286-48f2-b468-18ed4323448a', 'd8ea403a-57d8-4d59-88e3-1a756f9d1280', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8610de54-0061-418e-8659-926ffc6db37a', '4e116cb4-634f-4f48-b2f4-9a12f9f41986', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8610de54-0061-418e-8659-926ffc6db37a', 'b0ef835f-72d7-4512-8f2f-74984e54d763', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8610de54-0061-418e-8659-926ffc6db37a', '7bfc5640-266c-43b2-b23c-b2e63a09769d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8610de54-0061-418e-8659-926ffc6db37a', '7deccd5f-6286-48f2-b468-18ed4323448a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8610de54-0061-418e-8659-926ffc6db37a', '9b4df58b-200a-47a5-8e52-b2815a1c9d94', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9b4df58b-200a-47a5-8e52-b2815a1c9d94', 'dcc16d18-66e8-44a6-9a15-a6130ca5ce03', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9b4df58b-200a-47a5-8e52-b2815a1c9d94', '7bfc5640-266c-43b2-b23c-b2e63a09769d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9b4df58b-200a-47a5-8e52-b2815a1c9d94', '7deccd5f-6286-48f2-b468-18ed4323448a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9b4df58b-200a-47a5-8e52-b2815a1c9d94', '8610de54-0061-418e-8659-926ffc6db37a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9b4df58b-200a-47a5-8e52-b2815a1c9d94', 'd4f97644-6634-481d-af59-5fc3855f6f13', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dcc16d18-66e8-44a6-9a15-a6130ca5ce03', '9b4df58b-200a-47a5-8e52-b2815a1c9d94', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dcc16d18-66e8-44a6-9a15-a6130ca5ce03', '7bfc5640-266c-43b2-b23c-b2e63a09769d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dcc16d18-66e8-44a6-9a15-a6130ca5ce03', '7deccd5f-6286-48f2-b468-18ed4323448a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dcc16d18-66e8-44a6-9a15-a6130ca5ce03', '8610de54-0061-418e-8659-926ffc6db37a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dcc16d18-66e8-44a6-9a15-a6130ca5ce03', 'd4f97644-6634-481d-af59-5fc3855f6f13', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d4f97644-6634-481d-af59-5fc3855f6f13', '7bfc5640-266c-43b2-b23c-b2e63a09769d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d4f97644-6634-481d-af59-5fc3855f6f13', '7deccd5f-6286-48f2-b468-18ed4323448a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d4f97644-6634-481d-af59-5fc3855f6f13', 'b0b682ac-5a77-47f9-9782-6ad2410f4e42', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d4f97644-6634-481d-af59-5fc3855f6f13', '6eaf69c5-3832-4da2-8741-d420e847da20', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d4f97644-6634-481d-af59-5fc3855f6f13', 'd8ea403a-57d8-4d59-88e3-1a756f9d1280', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b0b682ac-5a77-47f9-9782-6ad2410f4e42', '7bfc5640-266c-43b2-b23c-b2e63a09769d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b0b682ac-5a77-47f9-9782-6ad2410f4e42', '7deccd5f-6286-48f2-b468-18ed4323448a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b0b682ac-5a77-47f9-9782-6ad2410f4e42', 'd4f97644-6634-481d-af59-5fc3855f6f13', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b0b682ac-5a77-47f9-9782-6ad2410f4e42', '6eaf69c5-3832-4da2-8741-d420e847da20', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b0b682ac-5a77-47f9-9782-6ad2410f4e42', 'd8ea403a-57d8-4d59-88e3-1a756f9d1280', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4e116cb4-634f-4f48-b2f4-9a12f9f41986', '8610de54-0061-418e-8659-926ffc6db37a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4e116cb4-634f-4f48-b2f4-9a12f9f41986', 'b0ef835f-72d7-4512-8f2f-74984e54d763', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4e116cb4-634f-4f48-b2f4-9a12f9f41986', '7bfc5640-266c-43b2-b23c-b2e63a09769d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4e116cb4-634f-4f48-b2f4-9a12f9f41986', '7deccd5f-6286-48f2-b468-18ed4323448a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4e116cb4-634f-4f48-b2f4-9a12f9f41986', '9b4df58b-200a-47a5-8e52-b2815a1c9d94', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6eaf69c5-3832-4da2-8741-d420e847da20', '7bfc5640-266c-43b2-b23c-b2e63a09769d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6eaf69c5-3832-4da2-8741-d420e847da20', '7deccd5f-6286-48f2-b468-18ed4323448a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6eaf69c5-3832-4da2-8741-d420e847da20', 'd4f97644-6634-481d-af59-5fc3855f6f13', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6eaf69c5-3832-4da2-8741-d420e847da20', 'b0b682ac-5a77-47f9-9782-6ad2410f4e42', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6eaf69c5-3832-4da2-8741-d420e847da20', 'd8ea403a-57d8-4d59-88e3-1a756f9d1280', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b0ef835f-72d7-4512-8f2f-74984e54d763', '8610de54-0061-418e-8659-926ffc6db37a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b0ef835f-72d7-4512-8f2f-74984e54d763', '4e116cb4-634f-4f48-b2f4-9a12f9f41986', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b0ef835f-72d7-4512-8f2f-74984e54d763', '7bfc5640-266c-43b2-b23c-b2e63a09769d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b0ef835f-72d7-4512-8f2f-74984e54d763', '7deccd5f-6286-48f2-b468-18ed4323448a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b0ef835f-72d7-4512-8f2f-74984e54d763', '9b4df58b-200a-47a5-8e52-b2815a1c9d94', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a75c3fe7-b81f-4214-a12e-b9afc4617225', 'f503b9b8-571a-43e1-8f3b-e05fb8ed1345', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a75c3fe7-b81f-4214-a12e-b9afc4617225', '8d7ea629-f469-4716-80c2-98e0b5b31a16', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a75c3fe7-b81f-4214-a12e-b9afc4617225', '8d9e9619-9a0a-4434-9427-0662bb3edf36', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a75c3fe7-b81f-4214-a12e-b9afc4617225', '13ed71a8-2d1f-40e6-bbfe-96d3d9e7f17c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a75c3fe7-b81f-4214-a12e-b9afc4617225', '08f5cc31-1989-40bf-967d-c4f289c9711e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f503b9b8-571a-43e1-8f3b-e05fb8ed1345', '8d7ea629-f469-4716-80c2-98e0b5b31a16', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f503b9b8-571a-43e1-8f3b-e05fb8ed1345', '8d9e9619-9a0a-4434-9427-0662bb3edf36', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f503b9b8-571a-43e1-8f3b-e05fb8ed1345', '08f5cc31-1989-40bf-967d-c4f289c9711e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f503b9b8-571a-43e1-8f3b-e05fb8ed1345', '3acf9527-6efb-4cf0-ab2e-d8bf65b489e7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f503b9b8-571a-43e1-8f3b-e05fb8ed1345', 'a75c3fe7-b81f-4214-a12e-b9afc4617225', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d7ea629-f469-4716-80c2-98e0b5b31a16', 'f503b9b8-571a-43e1-8f3b-e05fb8ed1345', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d7ea629-f469-4716-80c2-98e0b5b31a16', '8d9e9619-9a0a-4434-9427-0662bb3edf36', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d7ea629-f469-4716-80c2-98e0b5b31a16', '08f5cc31-1989-40bf-967d-c4f289c9711e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d7ea629-f469-4716-80c2-98e0b5b31a16', '3acf9527-6efb-4cf0-ab2e-d8bf65b489e7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d7ea629-f469-4716-80c2-98e0b5b31a16', 'a75c3fe7-b81f-4214-a12e-b9afc4617225', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d9e9619-9a0a-4434-9427-0662bb3edf36', 'f503b9b8-571a-43e1-8f3b-e05fb8ed1345', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d9e9619-9a0a-4434-9427-0662bb3edf36', '8d7ea629-f469-4716-80c2-98e0b5b31a16', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d9e9619-9a0a-4434-9427-0662bb3edf36', '08f5cc31-1989-40bf-967d-c4f289c9711e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d9e9619-9a0a-4434-9427-0662bb3edf36', '3acf9527-6efb-4cf0-ab2e-d8bf65b489e7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d9e9619-9a0a-4434-9427-0662bb3edf36', 'a75c3fe7-b81f-4214-a12e-b9afc4617225', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('13ed71a8-2d1f-40e6-bbfe-96d3d9e7f17c', 'a75c3fe7-b81f-4214-a12e-b9afc4617225', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('13ed71a8-2d1f-40e6-bbfe-96d3d9e7f17c', 'f503b9b8-571a-43e1-8f3b-e05fb8ed1345', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('13ed71a8-2d1f-40e6-bbfe-96d3d9e7f17c', '8d7ea629-f469-4716-80c2-98e0b5b31a16', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('13ed71a8-2d1f-40e6-bbfe-96d3d9e7f17c', '8d9e9619-9a0a-4434-9427-0662bb3edf36', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('13ed71a8-2d1f-40e6-bbfe-96d3d9e7f17c', '08f5cc31-1989-40bf-967d-c4f289c9711e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('08f5cc31-1989-40bf-967d-c4f289c9711e', 'f503b9b8-571a-43e1-8f3b-e05fb8ed1345', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('08f5cc31-1989-40bf-967d-c4f289c9711e', '8d7ea629-f469-4716-80c2-98e0b5b31a16', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('08f5cc31-1989-40bf-967d-c4f289c9711e', '8d9e9619-9a0a-4434-9427-0662bb3edf36', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('08f5cc31-1989-40bf-967d-c4f289c9711e', '3acf9527-6efb-4cf0-ab2e-d8bf65b489e7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('08f5cc31-1989-40bf-967d-c4f289c9711e', 'a75c3fe7-b81f-4214-a12e-b9afc4617225', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3acf9527-6efb-4cf0-ab2e-d8bf65b489e7', 'f503b9b8-571a-43e1-8f3b-e05fb8ed1345', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3acf9527-6efb-4cf0-ab2e-d8bf65b489e7', '8d7ea629-f469-4716-80c2-98e0b5b31a16', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3acf9527-6efb-4cf0-ab2e-d8bf65b489e7', '8d9e9619-9a0a-4434-9427-0662bb3edf36', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3acf9527-6efb-4cf0-ab2e-d8bf65b489e7', '08f5cc31-1989-40bf-967d-c4f289c9711e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3acf9527-6efb-4cf0-ab2e-d8bf65b489e7', 'a75c3fe7-b81f-4214-a12e-b9afc4617225', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0ed49074-9555-47cd-8c0a-c9f135dadffb', 'a221b7ff-3aa5-4289-9994-abd75bcd58e2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0ed49074-9555-47cd-8c0a-c9f135dadffb', 'c83153b9-a669-4f97-870e-793f32b3dcb0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0ed49074-9555-47cd-8c0a-c9f135dadffb', '4d4f442e-5094-474d-be88-57e5487ac24c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0ed49074-9555-47cd-8c0a-c9f135dadffb', '6338b1ed-93ae-4464-9ed7-5bea009580ff', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0ed49074-9555-47cd-8c0a-c9f135dadffb', '68678024-b913-4183-8203-9090b40ff749', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a221b7ff-3aa5-4289-9994-abd75bcd58e2', '0ed49074-9555-47cd-8c0a-c9f135dadffb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a221b7ff-3aa5-4289-9994-abd75bcd58e2', 'c83153b9-a669-4f97-870e-793f32b3dcb0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a221b7ff-3aa5-4289-9994-abd75bcd58e2', '4d4f442e-5094-474d-be88-57e5487ac24c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a221b7ff-3aa5-4289-9994-abd75bcd58e2', '6338b1ed-93ae-4464-9ed7-5bea009580ff', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a221b7ff-3aa5-4289-9994-abd75bcd58e2', '68678024-b913-4183-8203-9090b40ff749', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c83153b9-a669-4f97-870e-793f32b3dcb0', '0ed49074-9555-47cd-8c0a-c9f135dadffb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c83153b9-a669-4f97-870e-793f32b3dcb0', 'a221b7ff-3aa5-4289-9994-abd75bcd58e2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c83153b9-a669-4f97-870e-793f32b3dcb0', '4d4f442e-5094-474d-be88-57e5487ac24c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c83153b9-a669-4f97-870e-793f32b3dcb0', '6338b1ed-93ae-4464-9ed7-5bea009580ff', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c83153b9-a669-4f97-870e-793f32b3dcb0', '68678024-b913-4183-8203-9090b40ff749', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('68678024-b913-4183-8203-9090b40ff749', '0ed49074-9555-47cd-8c0a-c9f135dadffb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('68678024-b913-4183-8203-9090b40ff749', 'a221b7ff-3aa5-4289-9994-abd75bcd58e2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('68678024-b913-4183-8203-9090b40ff749', 'c83153b9-a669-4f97-870e-793f32b3dcb0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('68678024-b913-4183-8203-9090b40ff749', '4d4f442e-5094-474d-be88-57e5487ac24c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('68678024-b913-4183-8203-9090b40ff749', '6338b1ed-93ae-4464-9ed7-5bea009580ff', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4d4f442e-5094-474d-be88-57e5487ac24c', '0ed49074-9555-47cd-8c0a-c9f135dadffb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4d4f442e-5094-474d-be88-57e5487ac24c', 'a221b7ff-3aa5-4289-9994-abd75bcd58e2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4d4f442e-5094-474d-be88-57e5487ac24c', 'c83153b9-a669-4f97-870e-793f32b3dcb0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4d4f442e-5094-474d-be88-57e5487ac24c', '6338b1ed-93ae-4464-9ed7-5bea009580ff', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4d4f442e-5094-474d-be88-57e5487ac24c', '68678024-b913-4183-8203-9090b40ff749', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6338b1ed-93ae-4464-9ed7-5bea009580ff', '0ed49074-9555-47cd-8c0a-c9f135dadffb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6338b1ed-93ae-4464-9ed7-5bea009580ff', 'a221b7ff-3aa5-4289-9994-abd75bcd58e2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6338b1ed-93ae-4464-9ed7-5bea009580ff', 'c83153b9-a669-4f97-870e-793f32b3dcb0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6338b1ed-93ae-4464-9ed7-5bea009580ff', '4d4f442e-5094-474d-be88-57e5487ac24c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6338b1ed-93ae-4464-9ed7-5bea009580ff', '68678024-b913-4183-8203-9090b40ff749', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d8ea403a-57d8-4d59-88e3-1a756f9d1280', '7bfc5640-266c-43b2-b23c-b2e63a09769d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d8ea403a-57d8-4d59-88e3-1a756f9d1280', '7deccd5f-6286-48f2-b468-18ed4323448a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d8ea403a-57d8-4d59-88e3-1a756f9d1280', 'd4f97644-6634-481d-af59-5fc3855f6f13', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d8ea403a-57d8-4d59-88e3-1a756f9d1280', 'b0b682ac-5a77-47f9-9782-6ad2410f4e42', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d8ea403a-57d8-4d59-88e3-1a756f9d1280', '6eaf69c5-3832-4da2-8741-d420e847da20', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a78af0f2-c8b7-4ef2-987a-07bf6af46637', 'a75c3fe7-b81f-4214-a12e-b9afc4617225', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a78af0f2-c8b7-4ef2-987a-07bf6af46637', 'f503b9b8-571a-43e1-8f3b-e05fb8ed1345', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a78af0f2-c8b7-4ef2-987a-07bf6af46637', '8d7ea629-f469-4716-80c2-98e0b5b31a16', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a78af0f2-c8b7-4ef2-987a-07bf6af46637', '8d9e9619-9a0a-4434-9427-0662bb3edf36', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a78af0f2-c8b7-4ef2-987a-07bf6af46637', '13ed71a8-2d1f-40e6-bbfe-96d3d9e7f17c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16ece208-c599-4da2-89fc-2a3bb6b9f1f0', 'ff6f9020-6070-4c78-9069-5b1ef83ac582', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16ece208-c599-4da2-89fc-2a3bb6b9f1f0', 'd41e04e7-2c60-47eb-b894-c5c4348c66c2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16ece208-c599-4da2-89fc-2a3bb6b9f1f0', '07f729bd-7463-4d19-b4c0-e815b77db1b0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ff6f9020-6070-4c78-9069-5b1ef83ac582', '16ece208-c599-4da2-89fc-2a3bb6b9f1f0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ff6f9020-6070-4c78-9069-5b1ef83ac582', 'd41e04e7-2c60-47eb-b894-c5c4348c66c2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ff6f9020-6070-4c78-9069-5b1ef83ac582', '07f729bd-7463-4d19-b4c0-e815b77db1b0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d41e04e7-2c60-47eb-b894-c5c4348c66c2', '16ece208-c599-4da2-89fc-2a3bb6b9f1f0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d41e04e7-2c60-47eb-b894-c5c4348c66c2', 'ff6f9020-6070-4c78-9069-5b1ef83ac582', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d41e04e7-2c60-47eb-b894-c5c4348c66c2', '07f729bd-7463-4d19-b4c0-e815b77db1b0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('07f729bd-7463-4d19-b4c0-e815b77db1b0', '16ece208-c599-4da2-89fc-2a3bb6b9f1f0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('07f729bd-7463-4d19-b4c0-e815b77db1b0', 'ff6f9020-6070-4c78-9069-5b1ef83ac582', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('07f729bd-7463-4d19-b4c0-e815b77db1b0', 'd41e04e7-2c60-47eb-b894-c5c4348c66c2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('238f0b15-3b43-4fd4-8512-fb1e19573133', '726aa617-5b15-4d84-8226-2b4b549e117b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('238f0b15-3b43-4fd4-8512-fb1e19573133', '1b6a58ff-a331-44e8-9aab-f197230cd534', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('238f0b15-3b43-4fd4-8512-fb1e19573133', '3a22c742-49c4-4e08-a476-23e6e881bccd', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('238f0b15-3b43-4fd4-8512-fb1e19573133', 'e28ab78e-4266-4637-8d16-9800759462e3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('238f0b15-3b43-4fd4-8512-fb1e19573133', 'ee99ccbf-57be-4028-b0f4-35c860cefdd0', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ca7d96a-22dd-4fa6-8d52-bab17df996c7', '74b9261c-be85-41fa-9a04-78796081bd49', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ca7d96a-22dd-4fa6-8d52-bab17df996c7', '0c89d7c4-84fb-4a05-9f65-e6e3abb458b3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ca7d96a-22dd-4fa6-8d52-bab17df996c7', 'ffa7379d-79d6-4c3d-9ea8-d77aa2a9f3d8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ca7d96a-22dd-4fa6-8d52-bab17df996c7', '1f12e257-f317-4e05-bec4-c8704b7d0946', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ca7d96a-22dd-4fa6-8d52-bab17df996c7', 'd2a81e56-587c-4270-9683-93480c5af8b8', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('726aa617-5b15-4d84-8226-2b4b549e117b', '238f0b15-3b43-4fd4-8512-fb1e19573133', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('726aa617-5b15-4d84-8226-2b4b549e117b', '1b6a58ff-a331-44e8-9aab-f197230cd534', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('726aa617-5b15-4d84-8226-2b4b549e117b', '3a22c742-49c4-4e08-a476-23e6e881bccd', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('726aa617-5b15-4d84-8226-2b4b549e117b', 'e28ab78e-4266-4637-8d16-9800759462e3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('726aa617-5b15-4d84-8226-2b4b549e117b', 'ee99ccbf-57be-4028-b0f4-35c860cefdd0', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1f12e257-f317-4e05-bec4-c8704b7d0946', '9ca7d96a-22dd-4fa6-8d52-bab17df996c7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1f12e257-f317-4e05-bec4-c8704b7d0946', '74b9261c-be85-41fa-9a04-78796081bd49', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1f12e257-f317-4e05-bec4-c8704b7d0946', '0c89d7c4-84fb-4a05-9f65-e6e3abb458b3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1f12e257-f317-4e05-bec4-c8704b7d0946', 'ffa7379d-79d6-4c3d-9ea8-d77aa2a9f3d8', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1f12e257-f317-4e05-bec4-c8704b7d0946', 'd2a81e56-587c-4270-9683-93480c5af8b8', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f7ff0c7-93ea-4b52-b245-07a498fd1746', '16ece208-c599-4da2-89fc-2a3bb6b9f1f0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f7ff0c7-93ea-4b52-b245-07a498fd1746', 'ff6f9020-6070-4c78-9069-5b1ef83ac582', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f7ff0c7-93ea-4b52-b245-07a498fd1746', 'd41e04e7-2c60-47eb-b894-c5c4348c66c2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f7ff0c7-93ea-4b52-b245-07a498fd1746', '07f729bd-7463-4d19-b4c0-e815b77db1b0', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a22c742-49c4-4e08-a476-23e6e881bccd', 'e28ab78e-4266-4637-8d16-9800759462e3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a22c742-49c4-4e08-a476-23e6e881bccd', 'ee99ccbf-57be-4028-b0f4-35c860cefdd0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a22c742-49c4-4e08-a476-23e6e881bccd', '4f5079bb-7dcb-4aa5-86c4-0cdd2226bf22', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a22c742-49c4-4e08-a476-23e6e881bccd', '841a9155-e60b-440b-9731-c4578bba4c3a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a22c742-49c4-4e08-a476-23e6e881bccd', '238f0b15-3b43-4fd4-8512-fb1e19573133', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e28ab78e-4266-4637-8d16-9800759462e3', '3a22c742-49c4-4e08-a476-23e6e881bccd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e28ab78e-4266-4637-8d16-9800759462e3', 'ee99ccbf-57be-4028-b0f4-35c860cefdd0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e28ab78e-4266-4637-8d16-9800759462e3', '4f5079bb-7dcb-4aa5-86c4-0cdd2226bf22', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e28ab78e-4266-4637-8d16-9800759462e3', '841a9155-e60b-440b-9731-c4578bba4c3a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e28ab78e-4266-4637-8d16-9800759462e3', '238f0b15-3b43-4fd4-8512-fb1e19573133', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ee99ccbf-57be-4028-b0f4-35c860cefdd0', '3a22c742-49c4-4e08-a476-23e6e881bccd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ee99ccbf-57be-4028-b0f4-35c860cefdd0', 'e28ab78e-4266-4637-8d16-9800759462e3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ee99ccbf-57be-4028-b0f4-35c860cefdd0', '4f5079bb-7dcb-4aa5-86c4-0cdd2226bf22', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ee99ccbf-57be-4028-b0f4-35c860cefdd0', '841a9155-e60b-440b-9731-c4578bba4c3a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ee99ccbf-57be-4028-b0f4-35c860cefdd0', '238f0b15-3b43-4fd4-8512-fb1e19573133', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4f5079bb-7dcb-4aa5-86c4-0cdd2226bf22', '3a22c742-49c4-4e08-a476-23e6e881bccd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4f5079bb-7dcb-4aa5-86c4-0cdd2226bf22', 'e28ab78e-4266-4637-8d16-9800759462e3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4f5079bb-7dcb-4aa5-86c4-0cdd2226bf22', 'ee99ccbf-57be-4028-b0f4-35c860cefdd0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4f5079bb-7dcb-4aa5-86c4-0cdd2226bf22', '841a9155-e60b-440b-9731-c4578bba4c3a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4f5079bb-7dcb-4aa5-86c4-0cdd2226bf22', '238f0b15-3b43-4fd4-8512-fb1e19573133', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d281d358-d450-4be2-a7f8-b08112c4d8e9', '238f0b15-3b43-4fd4-8512-fb1e19573133', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d281d358-d450-4be2-a7f8-b08112c4d8e9', '726aa617-5b15-4d84-8226-2b4b549e117b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d281d358-d450-4be2-a7f8-b08112c4d8e9', '3a22c742-49c4-4e08-a476-23e6e881bccd', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d281d358-d450-4be2-a7f8-b08112c4d8e9', 'e28ab78e-4266-4637-8d16-9800759462e3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d281d358-d450-4be2-a7f8-b08112c4d8e9', 'ee99ccbf-57be-4028-b0f4-35c860cefdd0', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('841a9155-e60b-440b-9731-c4578bba4c3a', '3a22c742-49c4-4e08-a476-23e6e881bccd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('841a9155-e60b-440b-9731-c4578bba4c3a', 'e28ab78e-4266-4637-8d16-9800759462e3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('841a9155-e60b-440b-9731-c4578bba4c3a', 'ee99ccbf-57be-4028-b0f4-35c860cefdd0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('841a9155-e60b-440b-9731-c4578bba4c3a', '4f5079bb-7dcb-4aa5-86c4-0cdd2226bf22', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('841a9155-e60b-440b-9731-c4578bba4c3a', '238f0b15-3b43-4fd4-8512-fb1e19573133', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1b6a58ff-a331-44e8-9aab-f197230cd534', '238f0b15-3b43-4fd4-8512-fb1e19573133', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1b6a58ff-a331-44e8-9aab-f197230cd534', '726aa617-5b15-4d84-8226-2b4b549e117b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1b6a58ff-a331-44e8-9aab-f197230cd534', '3a22c742-49c4-4e08-a476-23e6e881bccd', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1b6a58ff-a331-44e8-9aab-f197230cd534', 'e28ab78e-4266-4637-8d16-9800759462e3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1b6a58ff-a331-44e8-9aab-f197230cd534', 'ee99ccbf-57be-4028-b0f4-35c860cefdd0', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2c4f6a83-3b3e-43ca-bf37-3a6d0daabb16', '16ece208-c599-4da2-89fc-2a3bb6b9f1f0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2c4f6a83-3b3e-43ca-bf37-3a6d0daabb16', 'ff6f9020-6070-4c78-9069-5b1ef83ac582', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2c4f6a83-3b3e-43ca-bf37-3a6d0daabb16', 'd41e04e7-2c60-47eb-b894-c5c4348c66c2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2c4f6a83-3b3e-43ca-bf37-3a6d0daabb16', '07f729bd-7463-4d19-b4c0-e815b77db1b0', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('879e5bb3-bd76-4773-9cfa-4eef25e8b44f', 'c25b718d-6e99-4993-9722-69cfcd85cf3f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('879e5bb3-bd76-4773-9cfa-4eef25e8b44f', 'a43e3c7f-ac79-47aa-80ee-147e9dd89e49', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('879e5bb3-bd76-4773-9cfa-4eef25e8b44f', 'a95a6418-c661-4848-b11d-722f353d8a0d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('879e5bb3-bd76-4773-9cfa-4eef25e8b44f', '596de19f-262b-4274-8da8-1abf61670446', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('879e5bb3-bd76-4773-9cfa-4eef25e8b44f', '9eef657a-bc9e-444a-8351-50328d198235', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('92c93a8c-a3ba-4ae3-9c6d-14ac655798ea', 'c25b718d-6e99-4993-9722-69cfcd85cf3f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('92c93a8c-a3ba-4ae3-9c6d-14ac655798ea', 'a43e3c7f-ac79-47aa-80ee-147e9dd89e49', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('92c93a8c-a3ba-4ae3-9c6d-14ac655798ea', 'a95a6418-c661-4848-b11d-722f353d8a0d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('92c93a8c-a3ba-4ae3-9c6d-14ac655798ea', '596de19f-262b-4274-8da8-1abf61670446', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('92c93a8c-a3ba-4ae3-9c6d-14ac655798ea', '9eef657a-bc9e-444a-8351-50328d198235', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c25b718d-6e99-4993-9722-69cfcd85cf3f', 'a43e3c7f-ac79-47aa-80ee-147e9dd89e49', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c25b718d-6e99-4993-9722-69cfcd85cf3f', 'a95a6418-c661-4848-b11d-722f353d8a0d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c25b718d-6e99-4993-9722-69cfcd85cf3f', '596de19f-262b-4274-8da8-1abf61670446', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c25b718d-6e99-4993-9722-69cfcd85cf3f', '9eef657a-bc9e-444a-8351-50328d198235', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c25b718d-6e99-4993-9722-69cfcd85cf3f', '0f0c3797-ae0f-4f36-a679-50e2da84e9d5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a43e3c7f-ac79-47aa-80ee-147e9dd89e49', 'c25b718d-6e99-4993-9722-69cfcd85cf3f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a43e3c7f-ac79-47aa-80ee-147e9dd89e49', 'a95a6418-c661-4848-b11d-722f353d8a0d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a43e3c7f-ac79-47aa-80ee-147e9dd89e49', '596de19f-262b-4274-8da8-1abf61670446', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a43e3c7f-ac79-47aa-80ee-147e9dd89e49', '9eef657a-bc9e-444a-8351-50328d198235', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a43e3c7f-ac79-47aa-80ee-147e9dd89e49', '0f0c3797-ae0f-4f36-a679-50e2da84e9d5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a95a6418-c661-4848-b11d-722f353d8a0d', 'c25b718d-6e99-4993-9722-69cfcd85cf3f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a95a6418-c661-4848-b11d-722f353d8a0d', 'a43e3c7f-ac79-47aa-80ee-147e9dd89e49', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a95a6418-c661-4848-b11d-722f353d8a0d', '596de19f-262b-4274-8da8-1abf61670446', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a95a6418-c661-4848-b11d-722f353d8a0d', '9eef657a-bc9e-444a-8351-50328d198235', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a95a6418-c661-4848-b11d-722f353d8a0d', '0f0c3797-ae0f-4f36-a679-50e2da84e9d5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('596de19f-262b-4274-8da8-1abf61670446', 'c25b718d-6e99-4993-9722-69cfcd85cf3f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('596de19f-262b-4274-8da8-1abf61670446', 'a43e3c7f-ac79-47aa-80ee-147e9dd89e49', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('596de19f-262b-4274-8da8-1abf61670446', 'a95a6418-c661-4848-b11d-722f353d8a0d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('596de19f-262b-4274-8da8-1abf61670446', '9eef657a-bc9e-444a-8351-50328d198235', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('596de19f-262b-4274-8da8-1abf61670446', '0f0c3797-ae0f-4f36-a679-50e2da84e9d5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9eef657a-bc9e-444a-8351-50328d198235', 'c25b718d-6e99-4993-9722-69cfcd85cf3f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9eef657a-bc9e-444a-8351-50328d198235', 'a43e3c7f-ac79-47aa-80ee-147e9dd89e49', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9eef657a-bc9e-444a-8351-50328d198235', 'a95a6418-c661-4848-b11d-722f353d8a0d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9eef657a-bc9e-444a-8351-50328d198235', '596de19f-262b-4274-8da8-1abf61670446', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9eef657a-bc9e-444a-8351-50328d198235', '0f0c3797-ae0f-4f36-a679-50e2da84e9d5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0f0c3797-ae0f-4f36-a679-50e2da84e9d5', 'c25b718d-6e99-4993-9722-69cfcd85cf3f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0f0c3797-ae0f-4f36-a679-50e2da84e9d5', 'a43e3c7f-ac79-47aa-80ee-147e9dd89e49', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0f0c3797-ae0f-4f36-a679-50e2da84e9d5', 'a95a6418-c661-4848-b11d-722f353d8a0d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0f0c3797-ae0f-4f36-a679-50e2da84e9d5', '596de19f-262b-4274-8da8-1abf61670446', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0f0c3797-ae0f-4f36-a679-50e2da84e9d5', '9eef657a-bc9e-444a-8351-50328d198235', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('998e8c35-02b5-490c-879b-054dda2e227a', 'c25b718d-6e99-4993-9722-69cfcd85cf3f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('998e8c35-02b5-490c-879b-054dda2e227a', 'a43e3c7f-ac79-47aa-80ee-147e9dd89e49', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('998e8c35-02b5-490c-879b-054dda2e227a', 'a95a6418-c661-4848-b11d-722f353d8a0d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('998e8c35-02b5-490c-879b-054dda2e227a', '596de19f-262b-4274-8da8-1abf61670446', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('998e8c35-02b5-490c-879b-054dda2e227a', '9eef657a-bc9e-444a-8351-50328d198235', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b3e80ee0-d697-4e60-934f-387f31604763', 'b23249ed-17e7-4f42-8dea-d0ac71417bf6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b3e80ee0-d697-4e60-934f-387f31604763', '9725eec0-c65a-42ab-91eb-1f878c5e4381', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b3e80ee0-d697-4e60-934f-387f31604763', 'a4ea523b-cc77-4ba5-8698-8d9623770ab6', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b3e80ee0-d697-4e60-934f-387f31604763', '2ac1c432-c77b-4580-b0ce-0ec3962c331c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b3e80ee0-d697-4e60-934f-387f31604763', '024a7384-14ff-44d3-851d-11398cdda0f4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b23249ed-17e7-4f42-8dea-d0ac71417bf6', 'b3e80ee0-d697-4e60-934f-387f31604763', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b23249ed-17e7-4f42-8dea-d0ac71417bf6', '9725eec0-c65a-42ab-91eb-1f878c5e4381', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b23249ed-17e7-4f42-8dea-d0ac71417bf6', 'a4ea523b-cc77-4ba5-8698-8d9623770ab6', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b23249ed-17e7-4f42-8dea-d0ac71417bf6', '2ac1c432-c77b-4580-b0ce-0ec3962c331c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b23249ed-17e7-4f42-8dea-d0ac71417bf6', '024a7384-14ff-44d3-851d-11398cdda0f4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9725eec0-c65a-42ab-91eb-1f878c5e4381', 'b3e80ee0-d697-4e60-934f-387f31604763', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9725eec0-c65a-42ab-91eb-1f878c5e4381', 'b23249ed-17e7-4f42-8dea-d0ac71417bf6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9725eec0-c65a-42ab-91eb-1f878c5e4381', 'a4ea523b-cc77-4ba5-8698-8d9623770ab6', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9725eec0-c65a-42ab-91eb-1f878c5e4381', '2ac1c432-c77b-4580-b0ce-0ec3962c331c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9725eec0-c65a-42ab-91eb-1f878c5e4381', '024a7384-14ff-44d3-851d-11398cdda0f4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a4ea523b-cc77-4ba5-8698-8d9623770ab6', 'b3e80ee0-d697-4e60-934f-387f31604763', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a4ea523b-cc77-4ba5-8698-8d9623770ab6', 'b23249ed-17e7-4f42-8dea-d0ac71417bf6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a4ea523b-cc77-4ba5-8698-8d9623770ab6', '9725eec0-c65a-42ab-91eb-1f878c5e4381', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a4ea523b-cc77-4ba5-8698-8d9623770ab6', '2ac1c432-c77b-4580-b0ce-0ec3962c331c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a4ea523b-cc77-4ba5-8698-8d9623770ab6', '024a7384-14ff-44d3-851d-11398cdda0f4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2ac1c432-c77b-4580-b0ce-0ec3962c331c', 'b3e80ee0-d697-4e60-934f-387f31604763', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2ac1c432-c77b-4580-b0ce-0ec3962c331c', 'b23249ed-17e7-4f42-8dea-d0ac71417bf6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2ac1c432-c77b-4580-b0ce-0ec3962c331c', '9725eec0-c65a-42ab-91eb-1f878c5e4381', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2ac1c432-c77b-4580-b0ce-0ec3962c331c', 'a4ea523b-cc77-4ba5-8698-8d9623770ab6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2ac1c432-c77b-4580-b0ce-0ec3962c331c', '024a7384-14ff-44d3-851d-11398cdda0f4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('024a7384-14ff-44d3-851d-11398cdda0f4', 'b3e80ee0-d697-4e60-934f-387f31604763', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('024a7384-14ff-44d3-851d-11398cdda0f4', 'b23249ed-17e7-4f42-8dea-d0ac71417bf6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('024a7384-14ff-44d3-851d-11398cdda0f4', '9725eec0-c65a-42ab-91eb-1f878c5e4381', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('024a7384-14ff-44d3-851d-11398cdda0f4', 'a4ea523b-cc77-4ba5-8698-8d9623770ab6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('024a7384-14ff-44d3-851d-11398cdda0f4', '2ac1c432-c77b-4580-b0ce-0ec3962c331c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d39510a-6679-466e-832b-918979c90985', 'b3e80ee0-d697-4e60-934f-387f31604763', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d39510a-6679-466e-832b-918979c90985', 'b23249ed-17e7-4f42-8dea-d0ac71417bf6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d39510a-6679-466e-832b-918979c90985', '9725eec0-c65a-42ab-91eb-1f878c5e4381', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d39510a-6679-466e-832b-918979c90985', 'a4ea523b-cc77-4ba5-8698-8d9623770ab6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d39510a-6679-466e-832b-918979c90985', '2ac1c432-c77b-4580-b0ce-0ec3962c331c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ff744a70-1dcb-42f5-9cd4-96eb1b794987', 'b3e80ee0-d697-4e60-934f-387f31604763', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ff744a70-1dcb-42f5-9cd4-96eb1b794987', 'b23249ed-17e7-4f42-8dea-d0ac71417bf6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ff744a70-1dcb-42f5-9cd4-96eb1b794987', '9725eec0-c65a-42ab-91eb-1f878c5e4381', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ff744a70-1dcb-42f5-9cd4-96eb1b794987', 'a4ea523b-cc77-4ba5-8698-8d9623770ab6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ff744a70-1dcb-42f5-9cd4-96eb1b794987', '2ac1c432-c77b-4580-b0ce-0ec3962c331c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d0ca15f4-02dd-4bb2-bdad-69d116a86436', 'c4740619-61b3-4310-b593-ab70452bf6d7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d0ca15f4-02dd-4bb2-bdad-69d116a86436', 'b3e80ee0-d697-4e60-934f-387f31604763', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d0ca15f4-02dd-4bb2-bdad-69d116a86436', 'b23249ed-17e7-4f42-8dea-d0ac71417bf6', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d0ca15f4-02dd-4bb2-bdad-69d116a86436', '9725eec0-c65a-42ab-91eb-1f878c5e4381', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d0ca15f4-02dd-4bb2-bdad-69d116a86436', 'a4ea523b-cc77-4ba5-8698-8d9623770ab6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('86446b14-9288-4d7d-8780-a65ca1e19afc', 'c25b718d-6e99-4993-9722-69cfcd85cf3f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('86446b14-9288-4d7d-8780-a65ca1e19afc', 'a43e3c7f-ac79-47aa-80ee-147e9dd89e49', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('86446b14-9288-4d7d-8780-a65ca1e19afc', 'a95a6418-c661-4848-b11d-722f353d8a0d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('86446b14-9288-4d7d-8780-a65ca1e19afc', '596de19f-262b-4274-8da8-1abf61670446', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('86446b14-9288-4d7d-8780-a65ca1e19afc', '9eef657a-bc9e-444a-8351-50328d198235', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c4740619-61b3-4310-b593-ab70452bf6d7', 'd0ca15f4-02dd-4bb2-bdad-69d116a86436', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c4740619-61b3-4310-b593-ab70452bf6d7', 'b3e80ee0-d697-4e60-934f-387f31604763', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c4740619-61b3-4310-b593-ab70452bf6d7', 'b23249ed-17e7-4f42-8dea-d0ac71417bf6', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c4740619-61b3-4310-b593-ab70452bf6d7', '9725eec0-c65a-42ab-91eb-1f878c5e4381', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c4740619-61b3-4310-b593-ab70452bf6d7', 'a4ea523b-cc77-4ba5-8698-8d9623770ab6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b5a697d5-2cc1-4ebf-8ce9-4437dca983cc', 'eb71451f-6d9b-470f-a686-3863edaddb2d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b5a697d5-2cc1-4ebf-8ce9-4437dca983cc', '59416c81-b9db-491f-b456-3bd0dd98aab2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b5a697d5-2cc1-4ebf-8ce9-4437dca983cc', '69117ae7-f951-4045-a87a-bde869b70c57', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b5a697d5-2cc1-4ebf-8ce9-4437dca983cc', '8e445021-775d-4cd7-8b5d-1d28bfb7df21', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b5a697d5-2cc1-4ebf-8ce9-4437dca983cc', 'b701f744-e2cd-439f-b0ad-3059161e1901', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb71451f-6d9b-470f-a686-3863edaddb2d', 'b5a697d5-2cc1-4ebf-8ce9-4437dca983cc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb71451f-6d9b-470f-a686-3863edaddb2d', '59416c81-b9db-491f-b456-3bd0dd98aab2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb71451f-6d9b-470f-a686-3863edaddb2d', '69117ae7-f951-4045-a87a-bde869b70c57', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb71451f-6d9b-470f-a686-3863edaddb2d', '8e445021-775d-4cd7-8b5d-1d28bfb7df21', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb71451f-6d9b-470f-a686-3863edaddb2d', 'b701f744-e2cd-439f-b0ad-3059161e1901', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59416c81-b9db-491f-b456-3bd0dd98aab2', 'b5a697d5-2cc1-4ebf-8ce9-4437dca983cc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59416c81-b9db-491f-b456-3bd0dd98aab2', 'eb71451f-6d9b-470f-a686-3863edaddb2d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59416c81-b9db-491f-b456-3bd0dd98aab2', '69117ae7-f951-4045-a87a-bde869b70c57', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59416c81-b9db-491f-b456-3bd0dd98aab2', '8e445021-775d-4cd7-8b5d-1d28bfb7df21', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59416c81-b9db-491f-b456-3bd0dd98aab2', 'b701f744-e2cd-439f-b0ad-3059161e1901', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('69117ae7-f951-4045-a87a-bde869b70c57', 'b5a697d5-2cc1-4ebf-8ce9-4437dca983cc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('69117ae7-f951-4045-a87a-bde869b70c57', 'eb71451f-6d9b-470f-a686-3863edaddb2d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('69117ae7-f951-4045-a87a-bde869b70c57', '59416c81-b9db-491f-b456-3bd0dd98aab2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('69117ae7-f951-4045-a87a-bde869b70c57', '8e445021-775d-4cd7-8b5d-1d28bfb7df21', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('69117ae7-f951-4045-a87a-bde869b70c57', 'b701f744-e2cd-439f-b0ad-3059161e1901', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8e445021-775d-4cd7-8b5d-1d28bfb7df21', 'b5a697d5-2cc1-4ebf-8ce9-4437dca983cc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8e445021-775d-4cd7-8b5d-1d28bfb7df21', 'eb71451f-6d9b-470f-a686-3863edaddb2d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8e445021-775d-4cd7-8b5d-1d28bfb7df21', '59416c81-b9db-491f-b456-3bd0dd98aab2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8e445021-775d-4cd7-8b5d-1d28bfb7df21', '69117ae7-f951-4045-a87a-bde869b70c57', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8e445021-775d-4cd7-8b5d-1d28bfb7df21', 'b701f744-e2cd-439f-b0ad-3059161e1901', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b9a99cec-c597-4026-b8c1-3f1c5ed7e234', 'b5a697d5-2cc1-4ebf-8ce9-4437dca983cc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b9a99cec-c597-4026-b8c1-3f1c5ed7e234', 'eb71451f-6d9b-470f-a686-3863edaddb2d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b9a99cec-c597-4026-b8c1-3f1c5ed7e234', '59416c81-b9db-491f-b456-3bd0dd98aab2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b9a99cec-c597-4026-b8c1-3f1c5ed7e234', '69117ae7-f951-4045-a87a-bde869b70c57', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b9a99cec-c597-4026-b8c1-3f1c5ed7e234', '8e445021-775d-4cd7-8b5d-1d28bfb7df21', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b701f744-e2cd-439f-b0ad-3059161e1901', 'b5a697d5-2cc1-4ebf-8ce9-4437dca983cc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b701f744-e2cd-439f-b0ad-3059161e1901', 'eb71451f-6d9b-470f-a686-3863edaddb2d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b701f744-e2cd-439f-b0ad-3059161e1901', '59416c81-b9db-491f-b456-3bd0dd98aab2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b701f744-e2cd-439f-b0ad-3059161e1901', '69117ae7-f951-4045-a87a-bde869b70c57', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b701f744-e2cd-439f-b0ad-3059161e1901', '8e445021-775d-4cd7-8b5d-1d28bfb7df21', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fb53279e-e7af-452d-be25-bf2272faf372', 'b5a697d5-2cc1-4ebf-8ce9-4437dca983cc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fb53279e-e7af-452d-be25-bf2272faf372', 'eb71451f-6d9b-470f-a686-3863edaddb2d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fb53279e-e7af-452d-be25-bf2272faf372', '59416c81-b9db-491f-b456-3bd0dd98aab2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fb53279e-e7af-452d-be25-bf2272faf372', '69117ae7-f951-4045-a87a-bde869b70c57', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fb53279e-e7af-452d-be25-bf2272faf372', '8e445021-775d-4cd7-8b5d-1d28bfb7df21', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('844ea849-149a-4dbe-8c85-c7f2bd4e54d9', 'b5a697d5-2cc1-4ebf-8ce9-4437dca983cc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('844ea849-149a-4dbe-8c85-c7f2bd4e54d9', 'eb71451f-6d9b-470f-a686-3863edaddb2d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('844ea849-149a-4dbe-8c85-c7f2bd4e54d9', '59416c81-b9db-491f-b456-3bd0dd98aab2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('844ea849-149a-4dbe-8c85-c7f2bd4e54d9', '69117ae7-f951-4045-a87a-bde869b70c57', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('844ea849-149a-4dbe-8c85-c7f2bd4e54d9', '8e445021-775d-4cd7-8b5d-1d28bfb7df21', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4bbb3e81-594f-4128-9686-871e11e64957', '4a04aeb3-1011-434c-8d4c-03e2f872d50d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4bbb3e81-594f-4128-9686-871e11e64957', 'c11087a8-8065-43b9-a21a-df42da187d98', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4bbb3e81-594f-4128-9686-871e11e64957', 'b5a697d5-2cc1-4ebf-8ce9-4437dca983cc', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4bbb3e81-594f-4128-9686-871e11e64957', 'eb71451f-6d9b-470f-a686-3863edaddb2d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4bbb3e81-594f-4128-9686-871e11e64957', '59416c81-b9db-491f-b456-3bd0dd98aab2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a04aeb3-1011-434c-8d4c-03e2f872d50d', '4bbb3e81-594f-4128-9686-871e11e64957', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a04aeb3-1011-434c-8d4c-03e2f872d50d', 'c11087a8-8065-43b9-a21a-df42da187d98', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a04aeb3-1011-434c-8d4c-03e2f872d50d', 'b5a697d5-2cc1-4ebf-8ce9-4437dca983cc', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a04aeb3-1011-434c-8d4c-03e2f872d50d', 'eb71451f-6d9b-470f-a686-3863edaddb2d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a04aeb3-1011-434c-8d4c-03e2f872d50d', '59416c81-b9db-491f-b456-3bd0dd98aab2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c11087a8-8065-43b9-a21a-df42da187d98', '4bbb3e81-594f-4128-9686-871e11e64957', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c11087a8-8065-43b9-a21a-df42da187d98', '4a04aeb3-1011-434c-8d4c-03e2f872d50d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c11087a8-8065-43b9-a21a-df42da187d98', 'b5a697d5-2cc1-4ebf-8ce9-4437dca983cc', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c11087a8-8065-43b9-a21a-df42da187d98', 'eb71451f-6d9b-470f-a686-3863edaddb2d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c11087a8-8065-43b9-a21a-df42da187d98', '59416c81-b9db-491f-b456-3bd0dd98aab2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39b29131-858e-4507-ae84-cf645a0b3e73', 'b5a697d5-2cc1-4ebf-8ce9-4437dca983cc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39b29131-858e-4507-ae84-cf645a0b3e73', 'eb71451f-6d9b-470f-a686-3863edaddb2d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39b29131-858e-4507-ae84-cf645a0b3e73', '59416c81-b9db-491f-b456-3bd0dd98aab2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39b29131-858e-4507-ae84-cf645a0b3e73', '69117ae7-f951-4045-a87a-bde869b70c57', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39b29131-858e-4507-ae84-cf645a0b3e73', '8e445021-775d-4cd7-8b5d-1d28bfb7df21', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8bd588dc-130b-4217-9845-6ad310b21466', 'b376d457-d285-4f4a-995a-cbc563b39b6b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8bd588dc-130b-4217-9845-6ad310b21466', 'b5a697d5-2cc1-4ebf-8ce9-4437dca983cc', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8bd588dc-130b-4217-9845-6ad310b21466', 'eb71451f-6d9b-470f-a686-3863edaddb2d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b2eaf398-9526-4622-acd8-7c894b79bc84', 'b5a697d5-2cc1-4ebf-8ce9-4437dca983cc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b2eaf398-9526-4622-acd8-7c894b79bc84', 'eb71451f-6d9b-470f-a686-3863edaddb2d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b2eaf398-9526-4622-acd8-7c894b79bc84', '59416c81-b9db-491f-b456-3bd0dd98aab2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b2eaf398-9526-4622-acd8-7c894b79bc84', '69117ae7-f951-4045-a87a-bde869b70c57', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b2eaf398-9526-4622-acd8-7c894b79bc84', '8e445021-775d-4cd7-8b5d-1d28bfb7df21', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b376d457-d285-4f4a-995a-cbc563b39b6b', '8bd588dc-130b-4217-9845-6ad310b21466', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b376d457-d285-4f4a-995a-cbc563b39b6b', 'b5a697d5-2cc1-4ebf-8ce9-4437dca983cc', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b376d457-d285-4f4a-995a-cbc563b39b6b', 'eb71451f-6d9b-470f-a686-3863edaddb2d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6b556a2-9ff7-460b-8b2f-3459881646d6', 'b5a697d5-2cc1-4ebf-8ce9-4437dca983cc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6b556a2-9ff7-460b-8b2f-3459881646d6', 'eb71451f-6d9b-470f-a686-3863edaddb2d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6b556a2-9ff7-460b-8b2f-3459881646d6', '59416c81-b9db-491f-b456-3bd0dd98aab2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6b556a2-9ff7-460b-8b2f-3459881646d6', '69117ae7-f951-4045-a87a-bde869b70c57', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6b556a2-9ff7-460b-8b2f-3459881646d6', '8e445021-775d-4cd7-8b5d-1d28bfb7df21', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6f38ed0d-76ff-4c70-b3b5-fa79ff0b6202', 'b5a697d5-2cc1-4ebf-8ce9-4437dca983cc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6f38ed0d-76ff-4c70-b3b5-fa79ff0b6202', 'eb71451f-6d9b-470f-a686-3863edaddb2d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6f38ed0d-76ff-4c70-b3b5-fa79ff0b6202', '59416c81-b9db-491f-b456-3bd0dd98aab2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6f38ed0d-76ff-4c70-b3b5-fa79ff0b6202', '69117ae7-f951-4045-a87a-bde869b70c57', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6f38ed0d-76ff-4c70-b3b5-fa79ff0b6202', '8e445021-775d-4cd7-8b5d-1d28bfb7df21', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dcfee4b4-f1dc-46c3-982f-926dee664450', '4df4885c-2e40-43be-8106-76dd8cb70395', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dcfee4b4-f1dc-46c3-982f-926dee664450', 'a3d167da-8037-49d5-9c16-ea0d8667550a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dcfee4b4-f1dc-46c3-982f-926dee664450', 'd5f484f2-96c2-4444-abdc-3ff97f9b18da', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dcfee4b4-f1dc-46c3-982f-926dee664450', '2fa3994e-4b01-4199-90bb-13cac1b299b3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dcfee4b4-f1dc-46c3-982f-926dee664450', '111b7118-d77c-414d-91e5-4b58babba901', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4df4885c-2e40-43be-8106-76dd8cb70395', 'dcfee4b4-f1dc-46c3-982f-926dee664450', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4df4885c-2e40-43be-8106-76dd8cb70395', 'a3d167da-8037-49d5-9c16-ea0d8667550a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4df4885c-2e40-43be-8106-76dd8cb70395', 'd5f484f2-96c2-4444-abdc-3ff97f9b18da', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4df4885c-2e40-43be-8106-76dd8cb70395', '2fa3994e-4b01-4199-90bb-13cac1b299b3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4df4885c-2e40-43be-8106-76dd8cb70395', '111b7118-d77c-414d-91e5-4b58babba901', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a3d167da-8037-49d5-9c16-ea0d8667550a', 'dcfee4b4-f1dc-46c3-982f-926dee664450', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a3d167da-8037-49d5-9c16-ea0d8667550a', '4df4885c-2e40-43be-8106-76dd8cb70395', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a3d167da-8037-49d5-9c16-ea0d8667550a', 'd5f484f2-96c2-4444-abdc-3ff97f9b18da', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a3d167da-8037-49d5-9c16-ea0d8667550a', '2fa3994e-4b01-4199-90bb-13cac1b299b3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a3d167da-8037-49d5-9c16-ea0d8667550a', '111b7118-d77c-414d-91e5-4b58babba901', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d5f484f2-96c2-4444-abdc-3ff97f9b18da', '2fa3994e-4b01-4199-90bb-13cac1b299b3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d5f484f2-96c2-4444-abdc-3ff97f9b18da', '111b7118-d77c-414d-91e5-4b58babba901', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d5f484f2-96c2-4444-abdc-3ff97f9b18da', 'e171b0d2-1cb0-4935-95d6-aff9a0117d7a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d5f484f2-96c2-4444-abdc-3ff97f9b18da', 'ccf7755e-9f02-4483-ba9f-ee4d890febd1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d5f484f2-96c2-4444-abdc-3ff97f9b18da', '75c76baa-e469-4d3c-88a9-6fca0b6c2237', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fd597b80-4f12-4ad0-886f-7fc1f24291a1', '47825c16-f7f5-4fc5-8b22-90ecee38acf0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fd597b80-4f12-4ad0-886f-7fc1f24291a1', '02ef8a3c-93b1-49ef-a771-d33e059cf062', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fd597b80-4f12-4ad0-886f-7fc1f24291a1', 'aef1e601-4aac-4576-8578-476d56f36d1d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2fa3994e-4b01-4199-90bb-13cac1b299b3', 'd5f484f2-96c2-4444-abdc-3ff97f9b18da', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2fa3994e-4b01-4199-90bb-13cac1b299b3', '111b7118-d77c-414d-91e5-4b58babba901', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2fa3994e-4b01-4199-90bb-13cac1b299b3', 'e171b0d2-1cb0-4935-95d6-aff9a0117d7a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2fa3994e-4b01-4199-90bb-13cac1b299b3', 'ccf7755e-9f02-4483-ba9f-ee4d890febd1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2fa3994e-4b01-4199-90bb-13cac1b299b3', '75c76baa-e469-4d3c-88a9-6fca0b6c2237', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('111b7118-d77c-414d-91e5-4b58babba901', 'd5f484f2-96c2-4444-abdc-3ff97f9b18da', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('111b7118-d77c-414d-91e5-4b58babba901', '2fa3994e-4b01-4199-90bb-13cac1b299b3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('111b7118-d77c-414d-91e5-4b58babba901', 'e171b0d2-1cb0-4935-95d6-aff9a0117d7a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('111b7118-d77c-414d-91e5-4b58babba901', 'ccf7755e-9f02-4483-ba9f-ee4d890febd1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('111b7118-d77c-414d-91e5-4b58babba901', '75c76baa-e469-4d3c-88a9-6fca0b6c2237', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e171b0d2-1cb0-4935-95d6-aff9a0117d7a', 'd5f484f2-96c2-4444-abdc-3ff97f9b18da', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e171b0d2-1cb0-4935-95d6-aff9a0117d7a', '2fa3994e-4b01-4199-90bb-13cac1b299b3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e171b0d2-1cb0-4935-95d6-aff9a0117d7a', '111b7118-d77c-414d-91e5-4b58babba901', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e171b0d2-1cb0-4935-95d6-aff9a0117d7a', 'ccf7755e-9f02-4483-ba9f-ee4d890febd1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e171b0d2-1cb0-4935-95d6-aff9a0117d7a', '75c76baa-e469-4d3c-88a9-6fca0b6c2237', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ccf7755e-9f02-4483-ba9f-ee4d890febd1', 'd5f484f2-96c2-4444-abdc-3ff97f9b18da', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ccf7755e-9f02-4483-ba9f-ee4d890febd1', '2fa3994e-4b01-4199-90bb-13cac1b299b3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ccf7755e-9f02-4483-ba9f-ee4d890febd1', '111b7118-d77c-414d-91e5-4b58babba901', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ccf7755e-9f02-4483-ba9f-ee4d890febd1', 'e171b0d2-1cb0-4935-95d6-aff9a0117d7a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ccf7755e-9f02-4483-ba9f-ee4d890febd1', '75c76baa-e469-4d3c-88a9-6fca0b6c2237', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75c76baa-e469-4d3c-88a9-6fca0b6c2237', 'd5f484f2-96c2-4444-abdc-3ff97f9b18da', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75c76baa-e469-4d3c-88a9-6fca0b6c2237', '2fa3994e-4b01-4199-90bb-13cac1b299b3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75c76baa-e469-4d3c-88a9-6fca0b6c2237', '111b7118-d77c-414d-91e5-4b58babba901', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75c76baa-e469-4d3c-88a9-6fca0b6c2237', 'e171b0d2-1cb0-4935-95d6-aff9a0117d7a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75c76baa-e469-4d3c-88a9-6fca0b6c2237', 'ccf7755e-9f02-4483-ba9f-ee4d890febd1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16b751e5-f9ea-4565-b0fe-e45b2953b133', 'd5f484f2-96c2-4444-abdc-3ff97f9b18da', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16b751e5-f9ea-4565-b0fe-e45b2953b133', '2fa3994e-4b01-4199-90bb-13cac1b299b3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16b751e5-f9ea-4565-b0fe-e45b2953b133', '111b7118-d77c-414d-91e5-4b58babba901', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16b751e5-f9ea-4565-b0fe-e45b2953b133', 'e171b0d2-1cb0-4935-95d6-aff9a0117d7a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16b751e5-f9ea-4565-b0fe-e45b2953b133', 'ccf7755e-9f02-4483-ba9f-ee4d890febd1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('30912dc7-b7bc-4cb4-b2e7-15fc032f3a26', 'd5f484f2-96c2-4444-abdc-3ff97f9b18da', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('30912dc7-b7bc-4cb4-b2e7-15fc032f3a26', '2fa3994e-4b01-4199-90bb-13cac1b299b3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('30912dc7-b7bc-4cb4-b2e7-15fc032f3a26', '111b7118-d77c-414d-91e5-4b58babba901', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('30912dc7-b7bc-4cb4-b2e7-15fc032f3a26', 'e171b0d2-1cb0-4935-95d6-aff9a0117d7a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('30912dc7-b7bc-4cb4-b2e7-15fc032f3a26', 'ccf7755e-9f02-4483-ba9f-ee4d890febd1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('23ad5aff-736e-4654-b1d5-3b57b6f5e456', 'd5f484f2-96c2-4444-abdc-3ff97f9b18da', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('23ad5aff-736e-4654-b1d5-3b57b6f5e456', '2fa3994e-4b01-4199-90bb-13cac1b299b3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('23ad5aff-736e-4654-b1d5-3b57b6f5e456', '111b7118-d77c-414d-91e5-4b58babba901', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('23ad5aff-736e-4654-b1d5-3b57b6f5e456', 'e171b0d2-1cb0-4935-95d6-aff9a0117d7a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('23ad5aff-736e-4654-b1d5-3b57b6f5e456', 'ccf7755e-9f02-4483-ba9f-ee4d890febd1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('443dc2b5-53ed-4469-be74-fab227462c32', 'd5f484f2-96c2-4444-abdc-3ff97f9b18da', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('443dc2b5-53ed-4469-be74-fab227462c32', '2fa3994e-4b01-4199-90bb-13cac1b299b3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('443dc2b5-53ed-4469-be74-fab227462c32', '111b7118-d77c-414d-91e5-4b58babba901', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('443dc2b5-53ed-4469-be74-fab227462c32', 'e171b0d2-1cb0-4935-95d6-aff9a0117d7a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('443dc2b5-53ed-4469-be74-fab227462c32', 'ccf7755e-9f02-4483-ba9f-ee4d890febd1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f7f134aa-805c-408e-89da-774579d53823', 'dcfee4b4-f1dc-46c3-982f-926dee664450', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f7f134aa-805c-408e-89da-774579d53823', '4df4885c-2e40-43be-8106-76dd8cb70395', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f7f134aa-805c-408e-89da-774579d53823', 'a3d167da-8037-49d5-9c16-ea0d8667550a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f7f134aa-805c-408e-89da-774579d53823', 'd5f484f2-96c2-4444-abdc-3ff97f9b18da', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f7f134aa-805c-408e-89da-774579d53823', '2fa3994e-4b01-4199-90bb-13cac1b299b3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9cf36ee4-a7f7-4177-b5d6-bc8ff5bd80ad', '4dd7f3a2-a953-4fad-b53a-6009721fd845', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9cf36ee4-a7f7-4177-b5d6-bc8ff5bd80ad', '09889b54-575a-43a7-ad7a-c4a27a74a637', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9cf36ee4-a7f7-4177-b5d6-bc8ff5bd80ad', '72a73ba0-da54-4b15-b7f1-a5ae32ccb79a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9cf36ee4-a7f7-4177-b5d6-bc8ff5bd80ad', 'a08fb528-1dd0-4212-8870-4cad5df6caf1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9cf36ee4-a7f7-4177-b5d6-bc8ff5bd80ad', '08df0597-aaca-4cea-921c-d57e5d3cdcd2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4dd7f3a2-a953-4fad-b53a-6009721fd845', '9cf36ee4-a7f7-4177-b5d6-bc8ff5bd80ad', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4dd7f3a2-a953-4fad-b53a-6009721fd845', '09889b54-575a-43a7-ad7a-c4a27a74a637', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4dd7f3a2-a953-4fad-b53a-6009721fd845', '72a73ba0-da54-4b15-b7f1-a5ae32ccb79a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4dd7f3a2-a953-4fad-b53a-6009721fd845', 'a08fb528-1dd0-4212-8870-4cad5df6caf1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4dd7f3a2-a953-4fad-b53a-6009721fd845', '08df0597-aaca-4cea-921c-d57e5d3cdcd2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d75409c5-f293-4b60-b097-7b32dc797be0', '4dd7f3a2-a953-4fad-b53a-6009721fd845', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d75409c5-f293-4b60-b097-7b32dc797be0', '9cf36ee4-a7f7-4177-b5d6-bc8ff5bd80ad', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d75409c5-f293-4b60-b097-7b32dc797be0', '09889b54-575a-43a7-ad7a-c4a27a74a637', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d75409c5-f293-4b60-b097-7b32dc797be0', '72a73ba0-da54-4b15-b7f1-a5ae32ccb79a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d75409c5-f293-4b60-b097-7b32dc797be0', 'a08fb528-1dd0-4212-8870-4cad5df6caf1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('09889b54-575a-43a7-ad7a-c4a27a74a637', 'a58af20a-8c6c-4a09-befd-4395ea0de224', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('09889b54-575a-43a7-ad7a-c4a27a74a637', '4f1ff2e0-3066-43b7-8cec-95e0ef1e67ec', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('09889b54-575a-43a7-ad7a-c4a27a74a637', 'b6e38eab-d817-405b-8b0a-7910a28999a0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('09889b54-575a-43a7-ad7a-c4a27a74a637', '9cf36ee4-a7f7-4177-b5d6-bc8ff5bd80ad', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('09889b54-575a-43a7-ad7a-c4a27a74a637', '4dd7f3a2-a953-4fad-b53a-6009721fd845', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('72a73ba0-da54-4b15-b7f1-a5ae32ccb79a', 'a08fb528-1dd0-4212-8870-4cad5df6caf1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('72a73ba0-da54-4b15-b7f1-a5ae32ccb79a', '08df0597-aaca-4cea-921c-d57e5d3cdcd2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('72a73ba0-da54-4b15-b7f1-a5ae32ccb79a', '39869c02-0155-4315-b8f5-aae3e2948a51', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('72a73ba0-da54-4b15-b7f1-a5ae32ccb79a', 'a2413978-e1ac-40ef-9402-d2abfb3c5ecd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('72a73ba0-da54-4b15-b7f1-a5ae32ccb79a', '9cf36ee4-a7f7-4177-b5d6-bc8ff5bd80ad', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a08fb528-1dd0-4212-8870-4cad5df6caf1', '72a73ba0-da54-4b15-b7f1-a5ae32ccb79a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a08fb528-1dd0-4212-8870-4cad5df6caf1', '08df0597-aaca-4cea-921c-d57e5d3cdcd2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a08fb528-1dd0-4212-8870-4cad5df6caf1', '39869c02-0155-4315-b8f5-aae3e2948a51', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a08fb528-1dd0-4212-8870-4cad5df6caf1', 'a2413978-e1ac-40ef-9402-d2abfb3c5ecd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a08fb528-1dd0-4212-8870-4cad5df6caf1', '9cf36ee4-a7f7-4177-b5d6-bc8ff5bd80ad', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('08df0597-aaca-4cea-921c-d57e5d3cdcd2', '72a73ba0-da54-4b15-b7f1-a5ae32ccb79a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('08df0597-aaca-4cea-921c-d57e5d3cdcd2', 'a08fb528-1dd0-4212-8870-4cad5df6caf1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('08df0597-aaca-4cea-921c-d57e5d3cdcd2', '39869c02-0155-4315-b8f5-aae3e2948a51', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('08df0597-aaca-4cea-921c-d57e5d3cdcd2', 'a2413978-e1ac-40ef-9402-d2abfb3c5ecd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('08df0597-aaca-4cea-921c-d57e5d3cdcd2', '9cf36ee4-a7f7-4177-b5d6-bc8ff5bd80ad', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a58af20a-8c6c-4a09-befd-4395ea0de224', '09889b54-575a-43a7-ad7a-c4a27a74a637', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a58af20a-8c6c-4a09-befd-4395ea0de224', '4f1ff2e0-3066-43b7-8cec-95e0ef1e67ec', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a58af20a-8c6c-4a09-befd-4395ea0de224', 'b6e38eab-d817-405b-8b0a-7910a28999a0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a58af20a-8c6c-4a09-befd-4395ea0de224', '9cf36ee4-a7f7-4177-b5d6-bc8ff5bd80ad', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a58af20a-8c6c-4a09-befd-4395ea0de224', '4dd7f3a2-a953-4fad-b53a-6009721fd845', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4f1ff2e0-3066-43b7-8cec-95e0ef1e67ec', '09889b54-575a-43a7-ad7a-c4a27a74a637', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4f1ff2e0-3066-43b7-8cec-95e0ef1e67ec', 'a58af20a-8c6c-4a09-befd-4395ea0de224', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4f1ff2e0-3066-43b7-8cec-95e0ef1e67ec', 'b6e38eab-d817-405b-8b0a-7910a28999a0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4f1ff2e0-3066-43b7-8cec-95e0ef1e67ec', '9cf36ee4-a7f7-4177-b5d6-bc8ff5bd80ad', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4f1ff2e0-3066-43b7-8cec-95e0ef1e67ec', '4dd7f3a2-a953-4fad-b53a-6009721fd845', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39869c02-0155-4315-b8f5-aae3e2948a51', '72a73ba0-da54-4b15-b7f1-a5ae32ccb79a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39869c02-0155-4315-b8f5-aae3e2948a51', 'a08fb528-1dd0-4212-8870-4cad5df6caf1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39869c02-0155-4315-b8f5-aae3e2948a51', '08df0597-aaca-4cea-921c-d57e5d3cdcd2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39869c02-0155-4315-b8f5-aae3e2948a51', 'a2413978-e1ac-40ef-9402-d2abfb3c5ecd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39869c02-0155-4315-b8f5-aae3e2948a51', '9cf36ee4-a7f7-4177-b5d6-bc8ff5bd80ad', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a2413978-e1ac-40ef-9402-d2abfb3c5ecd', '72a73ba0-da54-4b15-b7f1-a5ae32ccb79a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a2413978-e1ac-40ef-9402-d2abfb3c5ecd', 'a08fb528-1dd0-4212-8870-4cad5df6caf1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a2413978-e1ac-40ef-9402-d2abfb3c5ecd', '08df0597-aaca-4cea-921c-d57e5d3cdcd2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a2413978-e1ac-40ef-9402-d2abfb3c5ecd', '39869c02-0155-4315-b8f5-aae3e2948a51', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a2413978-e1ac-40ef-9402-d2abfb3c5ecd', '9cf36ee4-a7f7-4177-b5d6-bc8ff5bd80ad', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b6e38eab-d817-405b-8b0a-7910a28999a0', '09889b54-575a-43a7-ad7a-c4a27a74a637', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b6e38eab-d817-405b-8b0a-7910a28999a0', 'a58af20a-8c6c-4a09-befd-4395ea0de224', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b6e38eab-d817-405b-8b0a-7910a28999a0', '4f1ff2e0-3066-43b7-8cec-95e0ef1e67ec', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b6e38eab-d817-405b-8b0a-7910a28999a0', '9cf36ee4-a7f7-4177-b5d6-bc8ff5bd80ad', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b6e38eab-d817-405b-8b0a-7910a28999a0', '4dd7f3a2-a953-4fad-b53a-6009721fd845', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e87de2e0-c984-45c0-90fe-3c8d6683b203', 'd5f484f2-96c2-4444-abdc-3ff97f9b18da', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e87de2e0-c984-45c0-90fe-3c8d6683b203', '2fa3994e-4b01-4199-90bb-13cac1b299b3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e87de2e0-c984-45c0-90fe-3c8d6683b203', '111b7118-d77c-414d-91e5-4b58babba901', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e87de2e0-c984-45c0-90fe-3c8d6683b203', 'e171b0d2-1cb0-4935-95d6-aff9a0117d7a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e87de2e0-c984-45c0-90fe-3c8d6683b203', 'ccf7755e-9f02-4483-ba9f-ee4d890febd1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1a5c0fc9-0cef-441c-ba96-f479b992f94f', 'dcfee4b4-f1dc-46c3-982f-926dee664450', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1a5c0fc9-0cef-441c-ba96-f479b992f94f', '4df4885c-2e40-43be-8106-76dd8cb70395', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1a5c0fc9-0cef-441c-ba96-f479b992f94f', 'a3d167da-8037-49d5-9c16-ea0d8667550a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02ef8a3c-93b1-49ef-a771-d33e059cf062', 'aef1e601-4aac-4576-8578-476d56f36d1d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02ef8a3c-93b1-49ef-a771-d33e059cf062', 'f943e74c-7af0-44f2-aa9a-8125a77bac95', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02ef8a3c-93b1-49ef-a771-d33e059cf062', '646cd154-cc80-4da8-b2e6-14c92d0d5efb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aef1e601-4aac-4576-8578-476d56f36d1d', '02ef8a3c-93b1-49ef-a771-d33e059cf062', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aef1e601-4aac-4576-8578-476d56f36d1d', 'f943e74c-7af0-44f2-aa9a-8125a77bac95', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aef1e601-4aac-4576-8578-476d56f36d1d', '646cd154-cc80-4da8-b2e6-14c92d0d5efb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f943e74c-7af0-44f2-aa9a-8125a77bac95', '02ef8a3c-93b1-49ef-a771-d33e059cf062', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f943e74c-7af0-44f2-aa9a-8125a77bac95', 'aef1e601-4aac-4576-8578-476d56f36d1d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f943e74c-7af0-44f2-aa9a-8125a77bac95', '646cd154-cc80-4da8-b2e6-14c92d0d5efb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('646cd154-cc80-4da8-b2e6-14c92d0d5efb', '02ef8a3c-93b1-49ef-a771-d33e059cf062', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('646cd154-cc80-4da8-b2e6-14c92d0d5efb', 'aef1e601-4aac-4576-8578-476d56f36d1d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('646cd154-cc80-4da8-b2e6-14c92d0d5efb', 'f943e74c-7af0-44f2-aa9a-8125a77bac95', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d370842b-57dd-4856-a4ad-c58482e35943', 'f1f9c2e3-ddf7-4ba3-b3f4-5a910bd2f95f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d370842b-57dd-4856-a4ad-c58482e35943', '3d4fe315-bf9b-4173-87b5-223eff3d3693', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d370842b-57dd-4856-a4ad-c58482e35943', '12e2db5f-2e21-49fc-ac57-01bbbd67cc03', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d370842b-57dd-4856-a4ad-c58482e35943', '43a506b9-9a7d-442c-89d6-eb1e26fff61d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d370842b-57dd-4856-a4ad-c58482e35943', '5b0c5537-eccd-4c5c-840a-b900342c4892', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f1f9c2e3-ddf7-4ba3-b3f4-5a910bd2f95f', 'd370842b-57dd-4856-a4ad-c58482e35943', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f1f9c2e3-ddf7-4ba3-b3f4-5a910bd2f95f', '3d4fe315-bf9b-4173-87b5-223eff3d3693', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f1f9c2e3-ddf7-4ba3-b3f4-5a910bd2f95f', '12e2db5f-2e21-49fc-ac57-01bbbd67cc03', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f1f9c2e3-ddf7-4ba3-b3f4-5a910bd2f95f', '43a506b9-9a7d-442c-89d6-eb1e26fff61d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f1f9c2e3-ddf7-4ba3-b3f4-5a910bd2f95f', '5b0c5537-eccd-4c5c-840a-b900342c4892', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d4fe315-bf9b-4173-87b5-223eff3d3693', 'd370842b-57dd-4856-a4ad-c58482e35943', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d4fe315-bf9b-4173-87b5-223eff3d3693', 'f1f9c2e3-ddf7-4ba3-b3f4-5a910bd2f95f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d4fe315-bf9b-4173-87b5-223eff3d3693', '12e2db5f-2e21-49fc-ac57-01bbbd67cc03', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d4fe315-bf9b-4173-87b5-223eff3d3693', '43a506b9-9a7d-442c-89d6-eb1e26fff61d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d4fe315-bf9b-4173-87b5-223eff3d3693', '5b0c5537-eccd-4c5c-840a-b900342c4892', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('12e2db5f-2e21-49fc-ac57-01bbbd67cc03', 'd370842b-57dd-4856-a4ad-c58482e35943', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('12e2db5f-2e21-49fc-ac57-01bbbd67cc03', 'f1f9c2e3-ddf7-4ba3-b3f4-5a910bd2f95f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('12e2db5f-2e21-49fc-ac57-01bbbd67cc03', '3d4fe315-bf9b-4173-87b5-223eff3d3693', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('12e2db5f-2e21-49fc-ac57-01bbbd67cc03', '43a506b9-9a7d-442c-89d6-eb1e26fff61d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('12e2db5f-2e21-49fc-ac57-01bbbd67cc03', '5b0c5537-eccd-4c5c-840a-b900342c4892', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6f46b30-4eb7-421c-8c16-fdb50e927fa2', '68b0cec9-afa7-471d-8e3c-7b168ca9515b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6f46b30-4eb7-421c-8c16-fdb50e927fa2', 'd370842b-57dd-4856-a4ad-c58482e35943', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6f46b30-4eb7-421c-8c16-fdb50e927fa2', 'f1f9c2e3-ddf7-4ba3-b3f4-5a910bd2f95f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6f46b30-4eb7-421c-8c16-fdb50e927fa2', '3d4fe315-bf9b-4173-87b5-223eff3d3693', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6f46b30-4eb7-421c-8c16-fdb50e927fa2', '12e2db5f-2e21-49fc-ac57-01bbbd67cc03', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('68b0cec9-afa7-471d-8e3c-7b168ca9515b', 'c6f46b30-4eb7-421c-8c16-fdb50e927fa2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('68b0cec9-afa7-471d-8e3c-7b168ca9515b', 'd370842b-57dd-4856-a4ad-c58482e35943', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('68b0cec9-afa7-471d-8e3c-7b168ca9515b', 'f1f9c2e3-ddf7-4ba3-b3f4-5a910bd2f95f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('68b0cec9-afa7-471d-8e3c-7b168ca9515b', '3d4fe315-bf9b-4173-87b5-223eff3d3693', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('68b0cec9-afa7-471d-8e3c-7b168ca9515b', '12e2db5f-2e21-49fc-ac57-01bbbd67cc03', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('43a506b9-9a7d-442c-89d6-eb1e26fff61d', 'd370842b-57dd-4856-a4ad-c58482e35943', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('43a506b9-9a7d-442c-89d6-eb1e26fff61d', 'f1f9c2e3-ddf7-4ba3-b3f4-5a910bd2f95f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('43a506b9-9a7d-442c-89d6-eb1e26fff61d', '3d4fe315-bf9b-4173-87b5-223eff3d3693', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('43a506b9-9a7d-442c-89d6-eb1e26fff61d', '12e2db5f-2e21-49fc-ac57-01bbbd67cc03', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('43a506b9-9a7d-442c-89d6-eb1e26fff61d', '5b0c5537-eccd-4c5c-840a-b900342c4892', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5b0c5537-eccd-4c5c-840a-b900342c4892', 'd370842b-57dd-4856-a4ad-c58482e35943', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5b0c5537-eccd-4c5c-840a-b900342c4892', 'f1f9c2e3-ddf7-4ba3-b3f4-5a910bd2f95f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5b0c5537-eccd-4c5c-840a-b900342c4892', '3d4fe315-bf9b-4173-87b5-223eff3d3693', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5b0c5537-eccd-4c5c-840a-b900342c4892', '12e2db5f-2e21-49fc-ac57-01bbbd67cc03', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5b0c5537-eccd-4c5c-840a-b900342c4892', '43a506b9-9a7d-442c-89d6-eb1e26fff61d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('46ed6558-be36-4feb-b25c-41af9470f4c7', 'fd597b80-4f12-4ad0-886f-7fc1f24291a1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('46ed6558-be36-4feb-b25c-41af9470f4c7', '02ef8a3c-93b1-49ef-a771-d33e059cf062', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('46ed6558-be36-4feb-b25c-41af9470f4c7', 'aef1e601-4aac-4576-8578-476d56f36d1d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('588175ee-cfeb-4269-9353-aa369b9f3896', 'd370842b-57dd-4856-a4ad-c58482e35943', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('588175ee-cfeb-4269-9353-aa369b9f3896', 'f1f9c2e3-ddf7-4ba3-b3f4-5a910bd2f95f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('588175ee-cfeb-4269-9353-aa369b9f3896', '3d4fe315-bf9b-4173-87b5-223eff3d3693', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('588175ee-cfeb-4269-9353-aa369b9f3896', '12e2db5f-2e21-49fc-ac57-01bbbd67cc03', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('588175ee-cfeb-4269-9353-aa369b9f3896', 'c6f46b30-4eb7-421c-8c16-fdb50e927fa2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('47825c16-f7f5-4fc5-8b22-90ecee38acf0', 'fd597b80-4f12-4ad0-886f-7fc1f24291a1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('47825c16-f7f5-4fc5-8b22-90ecee38acf0', '02ef8a3c-93b1-49ef-a771-d33e059cf062', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('47825c16-f7f5-4fc5-8b22-90ecee38acf0', 'aef1e601-4aac-4576-8578-476d56f36d1d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c213f7c3-c7f0-43ba-b46b-d29da1019c32', '0919381b-2cac-47ff-9939-24cca58da948', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c213f7c3-c7f0-43ba-b46b-d29da1019c32', 'a6742eb1-53a3-455d-8ea0-2da5fea942a2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c213f7c3-c7f0-43ba-b46b-d29da1019c32', '0766750f-5bd1-4913-ae1f-c9f26cbc55f1', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c213f7c3-c7f0-43ba-b46b-d29da1019c32', '8a7f9c44-8537-4d22-bc45-7cbb0dc9492d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c213f7c3-c7f0-43ba-b46b-d29da1019c32', 'ce18cb73-a6a2-4956-ac9d-c422463b88e4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('786e11ea-96a9-4fc8-bb44-8b92c0dbb2c3', '573d92d1-99c8-47de-9719-96a855c32b14', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('786e11ea-96a9-4fc8-bb44-8b92c0dbb2c3', 'c213f7c3-c7f0-43ba-b46b-d29da1019c32', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('786e11ea-96a9-4fc8-bb44-8b92c0dbb2c3', '0919381b-2cac-47ff-9939-24cca58da948', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('786e11ea-96a9-4fc8-bb44-8b92c0dbb2c3', 'a6742eb1-53a3-455d-8ea0-2da5fea942a2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('786e11ea-96a9-4fc8-bb44-8b92c0dbb2c3', '0766750f-5bd1-4913-ae1f-c9f26cbc55f1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0919381b-2cac-47ff-9939-24cca58da948', 'c213f7c3-c7f0-43ba-b46b-d29da1019c32', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0919381b-2cac-47ff-9939-24cca58da948', 'a6742eb1-53a3-455d-8ea0-2da5fea942a2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0919381b-2cac-47ff-9939-24cca58da948', '0766750f-5bd1-4913-ae1f-c9f26cbc55f1', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0919381b-2cac-47ff-9939-24cca58da948', '8a7f9c44-8537-4d22-bc45-7cbb0dc9492d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0919381b-2cac-47ff-9939-24cca58da948', 'ce18cb73-a6a2-4956-ac9d-c422463b88e4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6742eb1-53a3-455d-8ea0-2da5fea942a2', 'c213f7c3-c7f0-43ba-b46b-d29da1019c32', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6742eb1-53a3-455d-8ea0-2da5fea942a2', '0919381b-2cac-47ff-9939-24cca58da948', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6742eb1-53a3-455d-8ea0-2da5fea942a2', '0766750f-5bd1-4913-ae1f-c9f26cbc55f1', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6742eb1-53a3-455d-8ea0-2da5fea942a2', '8a7f9c44-8537-4d22-bc45-7cbb0dc9492d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6742eb1-53a3-455d-8ea0-2da5fea942a2', 'ce18cb73-a6a2-4956-ac9d-c422463b88e4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0766750f-5bd1-4913-ae1f-c9f26cbc55f1', 'c213f7c3-c7f0-43ba-b46b-d29da1019c32', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0766750f-5bd1-4913-ae1f-c9f26cbc55f1', '0919381b-2cac-47ff-9939-24cca58da948', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0766750f-5bd1-4913-ae1f-c9f26cbc55f1', 'a6742eb1-53a3-455d-8ea0-2da5fea942a2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0766750f-5bd1-4913-ae1f-c9f26cbc55f1', '8a7f9c44-8537-4d22-bc45-7cbb0dc9492d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0766750f-5bd1-4913-ae1f-c9f26cbc55f1', 'ce18cb73-a6a2-4956-ac9d-c422463b88e4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8a7f9c44-8537-4d22-bc45-7cbb0dc9492d', 'c213f7c3-c7f0-43ba-b46b-d29da1019c32', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8a7f9c44-8537-4d22-bc45-7cbb0dc9492d', '0919381b-2cac-47ff-9939-24cca58da948', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8a7f9c44-8537-4d22-bc45-7cbb0dc9492d', 'a6742eb1-53a3-455d-8ea0-2da5fea942a2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8a7f9c44-8537-4d22-bc45-7cbb0dc9492d', '0766750f-5bd1-4913-ae1f-c9f26cbc55f1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8a7f9c44-8537-4d22-bc45-7cbb0dc9492d', 'ce18cb73-a6a2-4956-ac9d-c422463b88e4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce18cb73-a6a2-4956-ac9d-c422463b88e4', 'c213f7c3-c7f0-43ba-b46b-d29da1019c32', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce18cb73-a6a2-4956-ac9d-c422463b88e4', '0919381b-2cac-47ff-9939-24cca58da948', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce18cb73-a6a2-4956-ac9d-c422463b88e4', 'a6742eb1-53a3-455d-8ea0-2da5fea942a2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce18cb73-a6a2-4956-ac9d-c422463b88e4', '0766750f-5bd1-4913-ae1f-c9f26cbc55f1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce18cb73-a6a2-4956-ac9d-c422463b88e4', '8a7f9c44-8537-4d22-bc45-7cbb0dc9492d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5ae6a377-f124-47c6-8423-3931e12a8f75', 'd3f9276a-8f79-4cf7-91ea-efed3935cf9e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5ae6a377-f124-47c6-8423-3931e12a8f75', 'c213f7c3-c7f0-43ba-b46b-d29da1019c32', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5ae6a377-f124-47c6-8423-3931e12a8f75', '786e11ea-96a9-4fc8-bb44-8b92c0dbb2c3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5ae6a377-f124-47c6-8423-3931e12a8f75', '0919381b-2cac-47ff-9939-24cca58da948', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5ae6a377-f124-47c6-8423-3931e12a8f75', 'a6742eb1-53a3-455d-8ea0-2da5fea942a2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3f9276a-8f79-4cf7-91ea-efed3935cf9e', '5ae6a377-f124-47c6-8423-3931e12a8f75', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3f9276a-8f79-4cf7-91ea-efed3935cf9e', 'c213f7c3-c7f0-43ba-b46b-d29da1019c32', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3f9276a-8f79-4cf7-91ea-efed3935cf9e', '786e11ea-96a9-4fc8-bb44-8b92c0dbb2c3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3f9276a-8f79-4cf7-91ea-efed3935cf9e', '0919381b-2cac-47ff-9939-24cca58da948', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3f9276a-8f79-4cf7-91ea-efed3935cf9e', 'a6742eb1-53a3-455d-8ea0-2da5fea942a2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b6cb62e-b691-4ca2-80ac-1e779e61b978', 'c213f7c3-c7f0-43ba-b46b-d29da1019c32', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b6cb62e-b691-4ca2-80ac-1e779e61b978', '0919381b-2cac-47ff-9939-24cca58da948', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b6cb62e-b691-4ca2-80ac-1e779e61b978', 'a6742eb1-53a3-455d-8ea0-2da5fea942a2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b6cb62e-b691-4ca2-80ac-1e779e61b978', '0766750f-5bd1-4913-ae1f-c9f26cbc55f1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b6cb62e-b691-4ca2-80ac-1e779e61b978', '8a7f9c44-8537-4d22-bc45-7cbb0dc9492d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3761c5ef-df2f-4a43-a642-9591f1d9bc8b', 'c213f7c3-c7f0-43ba-b46b-d29da1019c32', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3761c5ef-df2f-4a43-a642-9591f1d9bc8b', '0919381b-2cac-47ff-9939-24cca58da948', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3761c5ef-df2f-4a43-a642-9591f1d9bc8b', 'a6742eb1-53a3-455d-8ea0-2da5fea942a2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3761c5ef-df2f-4a43-a642-9591f1d9bc8b', '0766750f-5bd1-4913-ae1f-c9f26cbc55f1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3761c5ef-df2f-4a43-a642-9591f1d9bc8b', '8a7f9c44-8537-4d22-bc45-7cbb0dc9492d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('573d92d1-99c8-47de-9719-96a855c32b14', '786e11ea-96a9-4fc8-bb44-8b92c0dbb2c3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('573d92d1-99c8-47de-9719-96a855c32b14', 'c213f7c3-c7f0-43ba-b46b-d29da1019c32', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('573d92d1-99c8-47de-9719-96a855c32b14', '0919381b-2cac-47ff-9939-24cca58da948', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('573d92d1-99c8-47de-9719-96a855c32b14', 'a6742eb1-53a3-455d-8ea0-2da5fea942a2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('573d92d1-99c8-47de-9719-96a855c32b14', '0766750f-5bd1-4913-ae1f-c9f26cbc55f1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('38fda179-9589-4d7a-942f-635c81ac2f54', 'c213f7c3-c7f0-43ba-b46b-d29da1019c32', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('38fda179-9589-4d7a-942f-635c81ac2f54', '0919381b-2cac-47ff-9939-24cca58da948', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('38fda179-9589-4d7a-942f-635c81ac2f54', 'a6742eb1-53a3-455d-8ea0-2da5fea942a2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('38fda179-9589-4d7a-942f-635c81ac2f54', '0766750f-5bd1-4913-ae1f-c9f26cbc55f1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('38fda179-9589-4d7a-942f-635c81ac2f54', '8a7f9c44-8537-4d22-bc45-7cbb0dc9492d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('46792d0b-57c4-4fa2-b533-76307d2b9f66', '78f8be3b-ad16-4cc5-90a1-98a5370c0ff5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('46792d0b-57c4-4fa2-b533-76307d2b9f66', '13efe4e6-2998-4d44-9319-2d675d4fdc98', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('46792d0b-57c4-4fa2-b533-76307d2b9f66', '5ff7b3dc-6761-42d9-8704-440530c689e6', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('46792d0b-57c4-4fa2-b533-76307d2b9f66', 'f123b27a-2a3f-42d8-bdd0-763d847f858f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('46792d0b-57c4-4fa2-b533-76307d2b9f66', 'a04880a1-d36b-4aac-a73e-103c3b95d0e7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('13efe4e6-2998-4d44-9319-2d675d4fdc98', '46792d0b-57c4-4fa2-b533-76307d2b9f66', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('13efe4e6-2998-4d44-9319-2d675d4fdc98', '5ff7b3dc-6761-42d9-8704-440530c689e6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('13efe4e6-2998-4d44-9319-2d675d4fdc98', 'f123b27a-2a3f-42d8-bdd0-763d847f858f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('13efe4e6-2998-4d44-9319-2d675d4fdc98', 'a04880a1-d36b-4aac-a73e-103c3b95d0e7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('13efe4e6-2998-4d44-9319-2d675d4fdc98', 'c167de34-a981-4773-a4ab-35fba3932b07', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5ff7b3dc-6761-42d9-8704-440530c689e6', '46792d0b-57c4-4fa2-b533-76307d2b9f66', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5ff7b3dc-6761-42d9-8704-440530c689e6', '13efe4e6-2998-4d44-9319-2d675d4fdc98', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5ff7b3dc-6761-42d9-8704-440530c689e6', 'f123b27a-2a3f-42d8-bdd0-763d847f858f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5ff7b3dc-6761-42d9-8704-440530c689e6', 'a04880a1-d36b-4aac-a73e-103c3b95d0e7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5ff7b3dc-6761-42d9-8704-440530c689e6', 'c167de34-a981-4773-a4ab-35fba3932b07', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f123b27a-2a3f-42d8-bdd0-763d847f858f', 'a04880a1-d36b-4aac-a73e-103c3b95d0e7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f123b27a-2a3f-42d8-bdd0-763d847f858f', 'c167de34-a981-4773-a4ab-35fba3932b07', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f123b27a-2a3f-42d8-bdd0-763d847f858f', '1121332d-65b8-4b3f-b7f0-9f40dc2e349d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f123b27a-2a3f-42d8-bdd0-763d847f858f', '46792d0b-57c4-4fa2-b533-76307d2b9f66', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f123b27a-2a3f-42d8-bdd0-763d847f858f', '13efe4e6-2998-4d44-9319-2d675d4fdc98', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a04880a1-d36b-4aac-a73e-103c3b95d0e7', 'f123b27a-2a3f-42d8-bdd0-763d847f858f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a04880a1-d36b-4aac-a73e-103c3b95d0e7', 'c167de34-a981-4773-a4ab-35fba3932b07', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a04880a1-d36b-4aac-a73e-103c3b95d0e7', '1121332d-65b8-4b3f-b7f0-9f40dc2e349d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a04880a1-d36b-4aac-a73e-103c3b95d0e7', '46792d0b-57c4-4fa2-b533-76307d2b9f66', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a04880a1-d36b-4aac-a73e-103c3b95d0e7', '13efe4e6-2998-4d44-9319-2d675d4fdc98', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c167de34-a981-4773-a4ab-35fba3932b07', 'f123b27a-2a3f-42d8-bdd0-763d847f858f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c167de34-a981-4773-a4ab-35fba3932b07', 'a04880a1-d36b-4aac-a73e-103c3b95d0e7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c167de34-a981-4773-a4ab-35fba3932b07', '1121332d-65b8-4b3f-b7f0-9f40dc2e349d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c167de34-a981-4773-a4ab-35fba3932b07', '46792d0b-57c4-4fa2-b533-76307d2b9f66', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c167de34-a981-4773-a4ab-35fba3932b07', '13efe4e6-2998-4d44-9319-2d675d4fdc98', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1121332d-65b8-4b3f-b7f0-9f40dc2e349d', 'f123b27a-2a3f-42d8-bdd0-763d847f858f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1121332d-65b8-4b3f-b7f0-9f40dc2e349d', 'a04880a1-d36b-4aac-a73e-103c3b95d0e7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1121332d-65b8-4b3f-b7f0-9f40dc2e349d', 'c167de34-a981-4773-a4ab-35fba3932b07', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1121332d-65b8-4b3f-b7f0-9f40dc2e349d', '46792d0b-57c4-4fa2-b533-76307d2b9f66', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1121332d-65b8-4b3f-b7f0-9f40dc2e349d', '13efe4e6-2998-4d44-9319-2d675d4fdc98', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('78f8be3b-ad16-4cc5-90a1-98a5370c0ff5', '46792d0b-57c4-4fa2-b533-76307d2b9f66', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('78f8be3b-ad16-4cc5-90a1-98a5370c0ff5', '13efe4e6-2998-4d44-9319-2d675d4fdc98', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('78f8be3b-ad16-4cc5-90a1-98a5370c0ff5', '5ff7b3dc-6761-42d9-8704-440530c689e6', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('78f8be3b-ad16-4cc5-90a1-98a5370c0ff5', 'f123b27a-2a3f-42d8-bdd0-763d847f858f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('78f8be3b-ad16-4cc5-90a1-98a5370c0ff5', 'a04880a1-d36b-4aac-a73e-103c3b95d0e7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('30815f70-c698-4e1c-8431-826220ba0b14', '46792d0b-57c4-4fa2-b533-76307d2b9f66', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('30815f70-c698-4e1c-8431-826220ba0b14', '13efe4e6-2998-4d44-9319-2d675d4fdc98', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('30815f70-c698-4e1c-8431-826220ba0b14', '5ff7b3dc-6761-42d9-8704-440530c689e6', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('94a6be50-124b-40e3-b0ac-9ff0ced8475f', '46792d0b-57c4-4fa2-b533-76307d2b9f66', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('94a6be50-124b-40e3-b0ac-9ff0ced8475f', '13efe4e6-2998-4d44-9319-2d675d4fdc98', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('94a6be50-124b-40e3-b0ac-9ff0ced8475f', '5ff7b3dc-6761-42d9-8704-440530c689e6', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('94a6be50-124b-40e3-b0ac-9ff0ced8475f', 'f123b27a-2a3f-42d8-bdd0-763d847f858f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('94a6be50-124b-40e3-b0ac-9ff0ced8475f', 'a04880a1-d36b-4aac-a73e-103c3b95d0e7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0059c65-1e7f-4d11-b896-fd6b40bbb812', 'e44ffa76-f62d-4f86-8aaa-002b7906d431', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0059c65-1e7f-4d11-b896-fd6b40bbb812', 'a04059d7-ac84-4b02-9d53-96bde2664671', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0059c65-1e7f-4d11-b896-fd6b40bbb812', '7ccd7004-8477-4e2c-a5a4-381cd3ee2f2f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0059c65-1e7f-4d11-b896-fd6b40bbb812', '1d20813f-623e-4b73-a61e-b46639e18e0b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0059c65-1e7f-4d11-b896-fd6b40bbb812', '28672f51-3438-4ab4-a68d-4bc15e72e980', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('879f5b96-15d6-491a-a0ff-3f13f7b235c4', 'f0059c65-1e7f-4d11-b896-fd6b40bbb812', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('879f5b96-15d6-491a-a0ff-3f13f7b235c4', 'e44ffa76-f62d-4f86-8aaa-002b7906d431', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('879f5b96-15d6-491a-a0ff-3f13f7b235c4', 'a04059d7-ac84-4b02-9d53-96bde2664671', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('879f5b96-15d6-491a-a0ff-3f13f7b235c4', '7ccd7004-8477-4e2c-a5a4-381cd3ee2f2f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('879f5b96-15d6-491a-a0ff-3f13f7b235c4', '1d20813f-623e-4b73-a61e-b46639e18e0b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e44ffa76-f62d-4f86-8aaa-002b7906d431', 'f0059c65-1e7f-4d11-b896-fd6b40bbb812', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e44ffa76-f62d-4f86-8aaa-002b7906d431', 'a04059d7-ac84-4b02-9d53-96bde2664671', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e44ffa76-f62d-4f86-8aaa-002b7906d431', '7ccd7004-8477-4e2c-a5a4-381cd3ee2f2f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e44ffa76-f62d-4f86-8aaa-002b7906d431', '1d20813f-623e-4b73-a61e-b46639e18e0b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e44ffa76-f62d-4f86-8aaa-002b7906d431', '28672f51-3438-4ab4-a68d-4bc15e72e980', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7ccd7004-8477-4e2c-a5a4-381cd3ee2f2f', 'f0059c65-1e7f-4d11-b896-fd6b40bbb812', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7ccd7004-8477-4e2c-a5a4-381cd3ee2f2f', 'e44ffa76-f62d-4f86-8aaa-002b7906d431', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7ccd7004-8477-4e2c-a5a4-381cd3ee2f2f', '1d20813f-623e-4b73-a61e-b46639e18e0b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7ccd7004-8477-4e2c-a5a4-381cd3ee2f2f', 'a04059d7-ac84-4b02-9d53-96bde2664671', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7ccd7004-8477-4e2c-a5a4-381cd3ee2f2f', '28672f51-3438-4ab4-a68d-4bc15e72e980', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1d20813f-623e-4b73-a61e-b46639e18e0b', 'f0059c65-1e7f-4d11-b896-fd6b40bbb812', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1d20813f-623e-4b73-a61e-b46639e18e0b', 'e44ffa76-f62d-4f86-8aaa-002b7906d431', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1d20813f-623e-4b73-a61e-b46639e18e0b', '7ccd7004-8477-4e2c-a5a4-381cd3ee2f2f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1d20813f-623e-4b73-a61e-b46639e18e0b', 'a04059d7-ac84-4b02-9d53-96bde2664671', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1d20813f-623e-4b73-a61e-b46639e18e0b', '28672f51-3438-4ab4-a68d-4bc15e72e980', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dac231cd-d5d0-45af-8ccb-1eb2dacb80e9', 'f0059c65-1e7f-4d11-b896-fd6b40bbb812', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dac231cd-d5d0-45af-8ccb-1eb2dacb80e9', 'e44ffa76-f62d-4f86-8aaa-002b7906d431', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dac231cd-d5d0-45af-8ccb-1eb2dacb80e9', '7ccd7004-8477-4e2c-a5a4-381cd3ee2f2f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('311de6be-724b-469c-9e0e-ac0485fa7ff9', 'f0059c65-1e7f-4d11-b896-fd6b40bbb812', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('311de6be-724b-469c-9e0e-ac0485fa7ff9', 'e44ffa76-f62d-4f86-8aaa-002b7906d431', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('311de6be-724b-469c-9e0e-ac0485fa7ff9', '7ccd7004-8477-4e2c-a5a4-381cd3ee2f2f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d4d63a0a-dac4-4174-befb-a4e151b6b25c', '2546b51a-f704-44c2-ad45-455938c39a3d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d4d63a0a-dac4-4174-befb-a4e151b6b25c', 'ac6a07fc-e94a-4be9-85d3-054318956c6c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d4d63a0a-dac4-4174-befb-a4e151b6b25c', '66ffeb12-9dbd-4811-bf34-db9e771bf56d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d4d63a0a-dac4-4174-befb-a4e151b6b25c', '6f6b0a0d-aba0-4c72-b7b1-e0e69291d160', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d4d63a0a-dac4-4174-befb-a4e151b6b25c', '2d401e53-d0c8-43c3-98f2-4435036df7e2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('66ffeb12-9dbd-4811-bf34-db9e771bf56d', '2d401e53-d0c8-43c3-98f2-4435036df7e2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('66ffeb12-9dbd-4811-bf34-db9e771bf56d', 'd4d63a0a-dac4-4174-befb-a4e151b6b25c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('66ffeb12-9dbd-4811-bf34-db9e771bf56d', '2546b51a-f704-44c2-ad45-455938c39a3d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('66ffeb12-9dbd-4811-bf34-db9e771bf56d', '6f6b0a0d-aba0-4c72-b7b1-e0e69291d160', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('66ffeb12-9dbd-4811-bf34-db9e771bf56d', 'ac6a07fc-e94a-4be9-85d3-054318956c6c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2546b51a-f704-44c2-ad45-455938c39a3d', 'd4d63a0a-dac4-4174-befb-a4e151b6b25c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2546b51a-f704-44c2-ad45-455938c39a3d', 'ac6a07fc-e94a-4be9-85d3-054318956c6c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2546b51a-f704-44c2-ad45-455938c39a3d', '66ffeb12-9dbd-4811-bf34-db9e771bf56d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2546b51a-f704-44c2-ad45-455938c39a3d', '6f6b0a0d-aba0-4c72-b7b1-e0e69291d160', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2546b51a-f704-44c2-ad45-455938c39a3d', '2d401e53-d0c8-43c3-98f2-4435036df7e2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6f6b0a0d-aba0-4c72-b7b1-e0e69291d160', 'd4d63a0a-dac4-4174-befb-a4e151b6b25c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6f6b0a0d-aba0-4c72-b7b1-e0e69291d160', '66ffeb12-9dbd-4811-bf34-db9e771bf56d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6f6b0a0d-aba0-4c72-b7b1-e0e69291d160', '2546b51a-f704-44c2-ad45-455938c39a3d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6f6b0a0d-aba0-4c72-b7b1-e0e69291d160', '2d401e53-d0c8-43c3-98f2-4435036df7e2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6f6b0a0d-aba0-4c72-b7b1-e0e69291d160', 'ac6a07fc-e94a-4be9-85d3-054318956c6c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d401e53-d0c8-43c3-98f2-4435036df7e2', '66ffeb12-9dbd-4811-bf34-db9e771bf56d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d401e53-d0c8-43c3-98f2-4435036df7e2', 'd4d63a0a-dac4-4174-befb-a4e151b6b25c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d401e53-d0c8-43c3-98f2-4435036df7e2', '2546b51a-f704-44c2-ad45-455938c39a3d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d401e53-d0c8-43c3-98f2-4435036df7e2', '6f6b0a0d-aba0-4c72-b7b1-e0e69291d160', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d401e53-d0c8-43c3-98f2-4435036df7e2', 'ac6a07fc-e94a-4be9-85d3-054318956c6c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bbad9bef-df3b-4589-bb01-0dbade9bc098', '89875b6d-fb13-4ddf-bd32-d0814652f13d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bbad9bef-df3b-4589-bb01-0dbade9bc098', 'f0059c65-1e7f-4d11-b896-fd6b40bbb812', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bbad9bef-df3b-4589-bb01-0dbade9bc098', 'e44ffa76-f62d-4f86-8aaa-002b7906d431', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a04059d7-ac84-4b02-9d53-96bde2664671', 'f0059c65-1e7f-4d11-b896-fd6b40bbb812', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a04059d7-ac84-4b02-9d53-96bde2664671', 'e44ffa76-f62d-4f86-8aaa-002b7906d431', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a04059d7-ac84-4b02-9d53-96bde2664671', '7ccd7004-8477-4e2c-a5a4-381cd3ee2f2f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a04059d7-ac84-4b02-9d53-96bde2664671', '1d20813f-623e-4b73-a61e-b46639e18e0b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a04059d7-ac84-4b02-9d53-96bde2664671', '28672f51-3438-4ab4-a68d-4bc15e72e980', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('379389f6-cfca-4000-a8e3-bc2e8fa16ec5', 'f0059c65-1e7f-4d11-b896-fd6b40bbb812', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('379389f6-cfca-4000-a8e3-bc2e8fa16ec5', 'e44ffa76-f62d-4f86-8aaa-002b7906d431', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('379389f6-cfca-4000-a8e3-bc2e8fa16ec5', '7ccd7004-8477-4e2c-a5a4-381cd3ee2f2f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('28672f51-3438-4ab4-a68d-4bc15e72e980', 'f0059c65-1e7f-4d11-b896-fd6b40bbb812', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('28672f51-3438-4ab4-a68d-4bc15e72e980', 'e44ffa76-f62d-4f86-8aaa-002b7906d431', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('28672f51-3438-4ab4-a68d-4bc15e72e980', '7ccd7004-8477-4e2c-a5a4-381cd3ee2f2f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('28672f51-3438-4ab4-a68d-4bc15e72e980', '1d20813f-623e-4b73-a61e-b46639e18e0b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('28672f51-3438-4ab4-a68d-4bc15e72e980', 'a04059d7-ac84-4b02-9d53-96bde2664671', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89875b6d-fb13-4ddf-bd32-d0814652f13d', 'bbad9bef-df3b-4589-bb01-0dbade9bc098', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89875b6d-fb13-4ddf-bd32-d0814652f13d', 'f0059c65-1e7f-4d11-b896-fd6b40bbb812', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89875b6d-fb13-4ddf-bd32-d0814652f13d', 'e44ffa76-f62d-4f86-8aaa-002b7906d431', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ac6a07fc-e94a-4be9-85d3-054318956c6c', 'd4d63a0a-dac4-4174-befb-a4e151b6b25c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ac6a07fc-e94a-4be9-85d3-054318956c6c', '2546b51a-f704-44c2-ad45-455938c39a3d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ac6a07fc-e94a-4be9-85d3-054318956c6c', '66ffeb12-9dbd-4811-bf34-db9e771bf56d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ac6a07fc-e94a-4be9-85d3-054318956c6c', '6f6b0a0d-aba0-4c72-b7b1-e0e69291d160', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ac6a07fc-e94a-4be9-85d3-054318956c6c', '2d401e53-d0c8-43c3-98f2-4435036df7e2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b984da28-45a9-4a9e-b73b-e1fdf096f108', 'aed71285-480d-4b9f-a74a-95d88bf41aa2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b984da28-45a9-4a9e-b73b-e1fdf096f108', '61f48f60-9984-476a-add4-760c2c4e971a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b984da28-45a9-4a9e-b73b-e1fdf096f108', 'f0059c65-1e7f-4d11-b896-fd6b40bbb812', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aed71285-480d-4b9f-a74a-95d88bf41aa2', 'b984da28-45a9-4a9e-b73b-e1fdf096f108', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aed71285-480d-4b9f-a74a-95d88bf41aa2', '61f48f60-9984-476a-add4-760c2c4e971a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aed71285-480d-4b9f-a74a-95d88bf41aa2', 'f0059c65-1e7f-4d11-b896-fd6b40bbb812', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('61f48f60-9984-476a-add4-760c2c4e971a', 'b984da28-45a9-4a9e-b73b-e1fdf096f108', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('61f48f60-9984-476a-add4-760c2c4e971a', 'aed71285-480d-4b9f-a74a-95d88bf41aa2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('61f48f60-9984-476a-add4-760c2c4e971a', 'f0059c65-1e7f-4d11-b896-fd6b40bbb812', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bb6faa2b-a0c8-484f-a11b-756d38d238b1', 'fc57cd32-feee-43e6-840f-6d4191fe4857', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bb6faa2b-a0c8-484f-a11b-756d38d238b1', '3f897a84-3277-4145-a96e-9caffae27a67', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bb6faa2b-a0c8-484f-a11b-756d38d238b1', 'f8188f97-0e8f-420e-b209-916b31c139c2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bb6faa2b-a0c8-484f-a11b-756d38d238b1', 'a7ed7ab2-5177-4a02-9b02-e787e290c7be', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc57cd32-feee-43e6-840f-6d4191fe4857', 'bb6faa2b-a0c8-484f-a11b-756d38d238b1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc57cd32-feee-43e6-840f-6d4191fe4857', '3f897a84-3277-4145-a96e-9caffae27a67', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc57cd32-feee-43e6-840f-6d4191fe4857', 'f8188f97-0e8f-420e-b209-916b31c139c2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc57cd32-feee-43e6-840f-6d4191fe4857', 'a7ed7ab2-5177-4a02-9b02-e787e290c7be', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f897a84-3277-4145-a96e-9caffae27a67', 'bb6faa2b-a0c8-484f-a11b-756d38d238b1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f897a84-3277-4145-a96e-9caffae27a67', 'fc57cd32-feee-43e6-840f-6d4191fe4857', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f897a84-3277-4145-a96e-9caffae27a67', 'f8188f97-0e8f-420e-b209-916b31c139c2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f897a84-3277-4145-a96e-9caffae27a67', 'a7ed7ab2-5177-4a02-9b02-e787e290c7be', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f8188f97-0e8f-420e-b209-916b31c139c2', 'bb6faa2b-a0c8-484f-a11b-756d38d238b1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f8188f97-0e8f-420e-b209-916b31c139c2', 'fc57cd32-feee-43e6-840f-6d4191fe4857', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f8188f97-0e8f-420e-b209-916b31c139c2', '3f897a84-3277-4145-a96e-9caffae27a67', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f8188f97-0e8f-420e-b209-916b31c139c2', 'a7ed7ab2-5177-4a02-9b02-e787e290c7be', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a7ed7ab2-5177-4a02-9b02-e787e290c7be', 'bb6faa2b-a0c8-484f-a11b-756d38d238b1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a7ed7ab2-5177-4a02-9b02-e787e290c7be', 'fc57cd32-feee-43e6-840f-6d4191fe4857', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a7ed7ab2-5177-4a02-9b02-e787e290c7be', '3f897a84-3277-4145-a96e-9caffae27a67', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a7ed7ab2-5177-4a02-9b02-e787e290c7be', 'f8188f97-0e8f-420e-b209-916b31c139c2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9c92f3f3-0f0a-4555-a792-5e912df688f0', 'a9cdf1af-5eff-4029-84cc-0bfbe41cec40', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9c92f3f3-0f0a-4555-a792-5e912df688f0', 'dd02bdd2-bd27-4a60-bfe2-946bc309f3ee', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a9cdf1af-5eff-4029-84cc-0bfbe41cec40', '9c92f3f3-0f0a-4555-a792-5e912df688f0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a9cdf1af-5eff-4029-84cc-0bfbe41cec40', 'dd02bdd2-bd27-4a60-bfe2-946bc309f3ee', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dd02bdd2-bd27-4a60-bfe2-946bc309f3ee', '9c92f3f3-0f0a-4555-a792-5e912df688f0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dd02bdd2-bd27-4a60-bfe2-946bc309f3ee', 'a9cdf1af-5eff-4029-84cc-0bfbe41cec40', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('74b9261c-be85-41fa-9a04-78796081bd49', '9ca7d96a-22dd-4fa6-8d52-bab17df996c7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('74b9261c-be85-41fa-9a04-78796081bd49', '0c89d7c4-84fb-4a05-9f65-e6e3abb458b3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('74b9261c-be85-41fa-9a04-78796081bd49', 'ffa7379d-79d6-4c3d-9ea8-d77aa2a9f3d8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('74b9261c-be85-41fa-9a04-78796081bd49', '1f12e257-f317-4e05-bec4-c8704b7d0946', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('74b9261c-be85-41fa-9a04-78796081bd49', 'd2a81e56-587c-4270-9683-93480c5af8b8', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c89d7c4-84fb-4a05-9f65-e6e3abb458b3', '9ca7d96a-22dd-4fa6-8d52-bab17df996c7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c89d7c4-84fb-4a05-9f65-e6e3abb458b3', '74b9261c-be85-41fa-9a04-78796081bd49', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c89d7c4-84fb-4a05-9f65-e6e3abb458b3', 'ffa7379d-79d6-4c3d-9ea8-d77aa2a9f3d8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c89d7c4-84fb-4a05-9f65-e6e3abb458b3', '1f12e257-f317-4e05-bec4-c8704b7d0946', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c89d7c4-84fb-4a05-9f65-e6e3abb458b3', 'd2a81e56-587c-4270-9683-93480c5af8b8', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ffa7379d-79d6-4c3d-9ea8-d77aa2a9f3d8', '9ca7d96a-22dd-4fa6-8d52-bab17df996c7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ffa7379d-79d6-4c3d-9ea8-d77aa2a9f3d8', '74b9261c-be85-41fa-9a04-78796081bd49', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ffa7379d-79d6-4c3d-9ea8-d77aa2a9f3d8', '0c89d7c4-84fb-4a05-9f65-e6e3abb458b3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ffa7379d-79d6-4c3d-9ea8-d77aa2a9f3d8', '1f12e257-f317-4e05-bec4-c8704b7d0946', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ffa7379d-79d6-4c3d-9ea8-d77aa2a9f3d8', 'd2a81e56-587c-4270-9683-93480c5af8b8', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d2a81e56-587c-4270-9683-93480c5af8b8', '9ca7d96a-22dd-4fa6-8d52-bab17df996c7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d2a81e56-587c-4270-9683-93480c5af8b8', '1f12e257-f317-4e05-bec4-c8704b7d0946', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d2a81e56-587c-4270-9683-93480c5af8b8', '74b9261c-be85-41fa-9a04-78796081bd49', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d2a81e56-587c-4270-9683-93480c5af8b8', '0c89d7c4-84fb-4a05-9f65-e6e3abb458b3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d2a81e56-587c-4270-9683-93480c5af8b8', 'ffa7379d-79d6-4c3d-9ea8-d77aa2a9f3d8', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2e1b4b58-bb34-47bb-bc92-0a014fcef1ae', '6fa5e6a1-5a64-4913-b4cd-f5bf4af30d53', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2e1b4b58-bb34-47bb-bc92-0a014fcef1ae', 'abc0b6d3-5635-4622-af2d-e8a2f608ab39', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6fa5e6a1-5a64-4913-b4cd-f5bf4af30d53', '2e1b4b58-bb34-47bb-bc92-0a014fcef1ae', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6fa5e6a1-5a64-4913-b4cd-f5bf4af30d53', 'abc0b6d3-5635-4622-af2d-e8a2f608ab39', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('abc0b6d3-5635-4622-af2d-e8a2f608ab39', '2e1b4b58-bb34-47bb-bc92-0a014fcef1ae', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('abc0b6d3-5635-4622-af2d-e8a2f608ab39', '6fa5e6a1-5a64-4913-b4cd-f5bf4af30d53', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('65cf8e00-d025-4950-a7fb-676f2fc07b30', 'b9018b05-90eb-47e4-b06f-bdd04382ca4e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('65cf8e00-d025-4950-a7fb-676f2fc07b30', '017c0ff8-3b8b-4053-bc2d-14ae78391e9c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('65cf8e00-d025-4950-a7fb-676f2fc07b30', 'cb880508-0ca5-4f39-99eb-fb8d9bfa861f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b9018b05-90eb-47e4-b06f-bdd04382ca4e', 'cb880508-0ca5-4f39-99eb-fb8d9bfa861f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b9018b05-90eb-47e4-b06f-bdd04382ca4e', '65cf8e00-d025-4950-a7fb-676f2fc07b30', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b9018b05-90eb-47e4-b06f-bdd04382ca4e', '017c0ff8-3b8b-4053-bc2d-14ae78391e9c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('017c0ff8-3b8b-4053-bc2d-14ae78391e9c', '65cf8e00-d025-4950-a7fb-676f2fc07b30', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('017c0ff8-3b8b-4053-bc2d-14ae78391e9c', 'b9018b05-90eb-47e4-b06f-bdd04382ca4e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('017c0ff8-3b8b-4053-bc2d-14ae78391e9c', 'cb880508-0ca5-4f39-99eb-fb8d9bfa861f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cb880508-0ca5-4f39-99eb-fb8d9bfa861f', 'b9018b05-90eb-47e4-b06f-bdd04382ca4e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cb880508-0ca5-4f39-99eb-fb8d9bfa861f', '65cf8e00-d025-4950-a7fb-676f2fc07b30', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cb880508-0ca5-4f39-99eb-fb8d9bfa861f', '017c0ff8-3b8b-4053-bc2d-14ae78391e9c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75d33853-de99-4572-aed5-6d205cbbdef3', '3f151158-fdd9-4eca-9297-73033f237d53', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75d33853-de99-4572-aed5-6d205cbbdef3', '5ac2334d-7b1d-4d9c-af06-b3fc56bb8c40', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75d33853-de99-4572-aed5-6d205cbbdef3', '75f47949-c691-4848-a32e-295138b89916', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75d33853-de99-4572-aed5-6d205cbbdef3', '28249b86-5bc8-4450-89a8-ab8aafe35e09', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75d33853-de99-4572-aed5-6d205cbbdef3', '6cf99213-527b-42b3-be20-822a58f71095', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f151158-fdd9-4eca-9297-73033f237d53', '75d33853-de99-4572-aed5-6d205cbbdef3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f151158-fdd9-4eca-9297-73033f237d53', '5ac2334d-7b1d-4d9c-af06-b3fc56bb8c40', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f151158-fdd9-4eca-9297-73033f237d53', '75f47949-c691-4848-a32e-295138b89916', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f151158-fdd9-4eca-9297-73033f237d53', '28249b86-5bc8-4450-89a8-ab8aafe35e09', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f151158-fdd9-4eca-9297-73033f237d53', '6cf99213-527b-42b3-be20-822a58f71095', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5ac2334d-7b1d-4d9c-af06-b3fc56bb8c40', '27a517b8-a2a7-4e70-97cf-7f04128aba66', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5ac2334d-7b1d-4d9c-af06-b3fc56bb8c40', '75d33853-de99-4572-aed5-6d205cbbdef3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5ac2334d-7b1d-4d9c-af06-b3fc56bb8c40', '3f151158-fdd9-4eca-9297-73033f237d53', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5ac2334d-7b1d-4d9c-af06-b3fc56bb8c40', '75f47949-c691-4848-a32e-295138b89916', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5ac2334d-7b1d-4d9c-af06-b3fc56bb8c40', '28249b86-5bc8-4450-89a8-ab8aafe35e09', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75f47949-c691-4848-a32e-295138b89916', '75d33853-de99-4572-aed5-6d205cbbdef3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75f47949-c691-4848-a32e-295138b89916', '3f151158-fdd9-4eca-9297-73033f237d53', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75f47949-c691-4848-a32e-295138b89916', '5ac2334d-7b1d-4d9c-af06-b3fc56bb8c40', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75f47949-c691-4848-a32e-295138b89916', '28249b86-5bc8-4450-89a8-ab8aafe35e09', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75f47949-c691-4848-a32e-295138b89916', '6cf99213-527b-42b3-be20-822a58f71095', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('28249b86-5bc8-4450-89a8-ab8aafe35e09', '75d33853-de99-4572-aed5-6d205cbbdef3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('28249b86-5bc8-4450-89a8-ab8aafe35e09', '3f151158-fdd9-4eca-9297-73033f237d53', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('28249b86-5bc8-4450-89a8-ab8aafe35e09', '5ac2334d-7b1d-4d9c-af06-b3fc56bb8c40', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('28249b86-5bc8-4450-89a8-ab8aafe35e09', '75f47949-c691-4848-a32e-295138b89916', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('28249b86-5bc8-4450-89a8-ab8aafe35e09', '6cf99213-527b-42b3-be20-822a58f71095', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6cf99213-527b-42b3-be20-822a58f71095', '75d33853-de99-4572-aed5-6d205cbbdef3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6cf99213-527b-42b3-be20-822a58f71095', '3f151158-fdd9-4eca-9297-73033f237d53', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6cf99213-527b-42b3-be20-822a58f71095', '5ac2334d-7b1d-4d9c-af06-b3fc56bb8c40', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6cf99213-527b-42b3-be20-822a58f71095', '75f47949-c691-4848-a32e-295138b89916', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6cf99213-527b-42b3-be20-822a58f71095', '28249b86-5bc8-4450-89a8-ab8aafe35e09', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ee7f9dc6-677b-4504-bf95-bdf2f90605ad', '75d33853-de99-4572-aed5-6d205cbbdef3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ee7f9dc6-677b-4504-bf95-bdf2f90605ad', '3f151158-fdd9-4eca-9297-73033f237d53', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ee7f9dc6-677b-4504-bf95-bdf2f90605ad', '5ac2334d-7b1d-4d9c-af06-b3fc56bb8c40', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ee7f9dc6-677b-4504-bf95-bdf2f90605ad', '75f47949-c691-4848-a32e-295138b89916', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ee7f9dc6-677b-4504-bf95-bdf2f90605ad', '28249b86-5bc8-4450-89a8-ab8aafe35e09', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('27a517b8-a2a7-4e70-97cf-7f04128aba66', '5ac2334d-7b1d-4d9c-af06-b3fc56bb8c40', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('27a517b8-a2a7-4e70-97cf-7f04128aba66', '75d33853-de99-4572-aed5-6d205cbbdef3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('27a517b8-a2a7-4e70-97cf-7f04128aba66', '3f151158-fdd9-4eca-9297-73033f237d53', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('27a517b8-a2a7-4e70-97cf-7f04128aba66', '75f47949-c691-4848-a32e-295138b89916', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('27a517b8-a2a7-4e70-97cf-7f04128aba66', '28249b86-5bc8-4450-89a8-ab8aafe35e09', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02b2235e-b7f7-461f-b875-549b755abac8', '75d33853-de99-4572-aed5-6d205cbbdef3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02b2235e-b7f7-461f-b875-549b755abac8', '3f151158-fdd9-4eca-9297-73033f237d53', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02b2235e-b7f7-461f-b875-549b755abac8', '5ac2334d-7b1d-4d9c-af06-b3fc56bb8c40', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02b2235e-b7f7-461f-b875-549b755abac8', '75f47949-c691-4848-a32e-295138b89916', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02b2235e-b7f7-461f-b875-549b755abac8', '28249b86-5bc8-4450-89a8-ab8aafe35e09', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('32df053a-c085-442e-a30b-529b1eef965c', '76c2d5bc-c31e-4de6-a4b4-05876fe7fa24', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('931e763a-af9f-48d9-82d6-ca9cd3bb63af', '76c2d5bc-c31e-4de6-a4b4-05876fe7fa24', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('50b97236-0949-42a2-89b8-35266b495a02', '76c2d5bc-c31e-4de6-a4b4-05876fe7fa24', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('57cc7676-5773-4ff8-858f-f5006ea0716f', '76c2d5bc-c31e-4de6-a4b4-05876fe7fa24', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c5d66830-3e19-4e90-b18f-735ccc1505ab', '76c2d5bc-c31e-4de6-a4b4-05876fe7fa24', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('21180806-d8c3-479b-b6aa-3a0d2dbdd6b7', '76c2d5bc-c31e-4de6-a4b4-05876fe7fa24', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0054c0a5-aa72-4434-8bf5-e21de913d7dd', '277f5554-633b-4c45-8e8f-9e73cd2e6df3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0054c0a5-aa72-4434-8bf5-e21de913d7dd', 'd8750ce2-452e-48a3-b56e-ba1645cff844', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0054c0a5-aa72-4434-8bf5-e21de913d7dd', '5ffaf748-3d3a-4a4b-9f4d-7a846147c710', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('277f5554-633b-4c45-8e8f-9e73cd2e6df3', '0054c0a5-aa72-4434-8bf5-e21de913d7dd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('277f5554-633b-4c45-8e8f-9e73cd2e6df3', 'd8750ce2-452e-48a3-b56e-ba1645cff844', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('277f5554-633b-4c45-8e8f-9e73cd2e6df3', '5ffaf748-3d3a-4a4b-9f4d-7a846147c710', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d8750ce2-452e-48a3-b56e-ba1645cff844', '5ffaf748-3d3a-4a4b-9f4d-7a846147c710', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d8750ce2-452e-48a3-b56e-ba1645cff844', '0054c0a5-aa72-4434-8bf5-e21de913d7dd', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d8750ce2-452e-48a3-b56e-ba1645cff844', '277f5554-633b-4c45-8e8f-9e73cd2e6df3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5ffaf748-3d3a-4a4b-9f4d-7a846147c710', 'd8750ce2-452e-48a3-b56e-ba1645cff844', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5ffaf748-3d3a-4a4b-9f4d-7a846147c710', '0054c0a5-aa72-4434-8bf5-e21de913d7dd', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5ffaf748-3d3a-4a4b-9f4d-7a846147c710', '277f5554-633b-4c45-8e8f-9e73cd2e6df3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('faac12b3-1639-458c-98e5-8528f338a2b3', 'b368183b-b1aa-41d4-a2e2-2ecb4e1a0b4d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('faac12b3-1639-458c-98e5-8528f338a2b3', '05f929dd-57ec-421b-8443-b4167a3394bb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('056ea8ae-4517-4685-8ef8-62029b547944', 'faac12b3-1639-458c-98e5-8528f338a2b3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('056ea8ae-4517-4685-8ef8-62029b547944', 'b368183b-b1aa-41d4-a2e2-2ecb4e1a0b4d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('056ea8ae-4517-4685-8ef8-62029b547944', '05f929dd-57ec-421b-8443-b4167a3394bb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5e2dbd1f-1c98-412c-9739-622d841691ba', 'faac12b3-1639-458c-98e5-8528f338a2b3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5e2dbd1f-1c98-412c-9739-622d841691ba', 'b368183b-b1aa-41d4-a2e2-2ecb4e1a0b4d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5e2dbd1f-1c98-412c-9739-622d841691ba', '05f929dd-57ec-421b-8443-b4167a3394bb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b368183b-b1aa-41d4-a2e2-2ecb4e1a0b4d', 'faac12b3-1639-458c-98e5-8528f338a2b3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b368183b-b1aa-41d4-a2e2-2ecb4e1a0b4d', '05f929dd-57ec-421b-8443-b4167a3394bb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1405ba07-f087-4174-ab6a-ecf7313cb3ff', 'faac12b3-1639-458c-98e5-8528f338a2b3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1405ba07-f087-4174-ab6a-ecf7313cb3ff', 'b368183b-b1aa-41d4-a2e2-2ecb4e1a0b4d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1405ba07-f087-4174-ab6a-ecf7313cb3ff', '05f929dd-57ec-421b-8443-b4167a3394bb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('db8f64d0-421e-4a31-8f12-be2848bcd8fa', 'faac12b3-1639-458c-98e5-8528f338a2b3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('db8f64d0-421e-4a31-8f12-be2848bcd8fa', 'b368183b-b1aa-41d4-a2e2-2ecb4e1a0b4d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('db8f64d0-421e-4a31-8f12-be2848bcd8fa', '05f929dd-57ec-421b-8443-b4167a3394bb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('05f929dd-57ec-421b-8443-b4167a3394bb', 'faac12b3-1639-458c-98e5-8528f338a2b3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('05f929dd-57ec-421b-8443-b4167a3394bb', 'b368183b-b1aa-41d4-a2e2-2ecb4e1a0b4d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f2da7996-247c-4f5e-87c0-14cd0e2b8faa', 'faac12b3-1639-458c-98e5-8528f338a2b3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f2da7996-247c-4f5e-87c0-14cd0e2b8faa', 'b368183b-b1aa-41d4-a2e2-2ecb4e1a0b4d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f2da7996-247c-4f5e-87c0-14cd0e2b8faa', '05f929dd-57ec-421b-8443-b4167a3394bb', 2) ON CONFLICT DO NOTHING;



INSERT INTO public.faqs VALUES ('41b1f61a-f3e7-4dbc-a0c3-7f2544c9be68', 'متى يوصلني الرد بعد الاشتراك؟', 'خلال 48 ساعة عمل. أيام العمل من الأحد إلى الخميس، من 12 الظهر حتى 9 مساءً، والتواصل على واتساب.', 0, true, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('9ab560e8-adb6-4a33-9b84-235b0f53a907', 'كيف تتم المتابعة؟', 'ترسل مراجعتك الأسبوعية في يوم المراجعة، وأرد عليك بتعديلات مسجلة (فيديو أو صوت). في الباقة الأساسية المتابعة كل أسبوعين. التواصل اليومي على واتساب مع رد خلال 48 ساعة.', 1, true, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('93383204-cfad-46a7-afd4-ff4127f2ec30', 'أنا مبتدئ تماماً، هل يناسبني؟', 'نعم. البرنامج يُبنى على مستواك الحالي، والتمارين مشروحة، وتقدر ترسل مقاطع أدائك لتصحيح التكنيك.', 2, true, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('03a22e2c-fa62-489d-8aeb-42b8a94f8df7', 'أتمرن في البيت، ماذا أحتاج من أدوات؟', 'تحدد في النموذج الأدوات المتوفرة عندك (دمبلز، حبال مقاومة، بار…) ويُبنى جدولك عليها.', 3, true, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('e19872ca-b8cb-45fd-9716-08579f3d6a55', 'كيف أدفع؟', 'بتحويل بنكي بعد تعبئة الاستبيان. أول ما ترسل الاستبيان يظهر لك رقم طلبك والمبلغ وبيانات الحساب. حوّل المبلغ وارفع صورة الإيصال من صفحة طلبك، ويتأكد اشتراكك بعد التحقق من وصول المبلغ.', 4, true, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('19127f2f-5ba6-422f-9693-3e3a35d97e19', 'ما شروط ضمان استرجاع المبلغ؟', 'في اشتراكات 3 أشهر لباقات المتابعة (المكثفة، المتقدمة، الأساسية): إذا لم يتحسن أي مؤشر من مؤشرات تقدمك بعد 12 أسبوعاً، يرجع لك المبلغ كاملاً.
مؤشرات التقدم (بحسب هدفك): متوسط الوزن الأسبوعي، أو محيط الخصر، أو القوة في التمارين الأساسية (الوزن أو التكرارات).
شروط الضمان:
- إرسال المراجعة الأسبوعية كل أسبوع.
- أخذ القياسات بانتظام.
- تصوير التمارين وإرسالها.
- الالتزام بجدول التغذية المخصص (في الباقات التي تشمل تغذية).
يُطلب الاسترجاع عبر واتساب خلال 14 يوماً من نهاية الأشهر الثلاثة.', 5, true, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('2b531892-7a41-4124-a386-60974d1b9a85', 'هل الجداول لي بعد انتهاء الاشتراك؟', 'نعم، جميع الجداول لك مدى الحياة وتقدر تعدّل عليها.', 6, true, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('398d9892-b427-4203-bf1f-1bd937c4301d', 'ما هو التجديد المجاني؟', 'مكافأة للملتزمين: إذا كان اشتراكك 3 أشهر تحصل على 3 أشهر إضافية مجاناً، فيصير المجموع 6 أشهر بسعر 3.
الشروط:
- نسبة التزام 90% فأكثر: المراجعات الأسبوعية المرسلة والتمارين المسجلة.
- تقدم واضح في مؤشرات التقدم نفسها المذكورة في الضمان.
- للمتدربين الرجال: إرسال صور التطور (قبل وبعد) للمدربة للتوثيق، مع تغطية الوجه والسرة.
نشر الصور في السوشل ميديا اختياري بالكامل حسب موافقتك، ولا يؤثر على استحقاقك للتجديد.', 7, true, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('9013e658-727a-43a4-b69a-f93afd2458df', 'من يطّلع على بياناتي؟', 'المدربة فقط، وتُستخدم لتصميم برنامجك ومتابعتك. لا تُنشر نتيجتك أو صورتك إلا بموافقتك الصريحة في النموذج.', 8, true, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;



INSERT INTO public.foods VALUES ('f0b475bc-06dc-41b3-9755-b0c72107a921', 'حليب بروتين سادة (ندى 320 مل)', 'Nada Protein Plain Milk 320ml', 'مشروبات بروتينية', 60.0, 8.5, 8.7, 0.1, 320.0, 'عبوة 320 مل', 'coach', 'nada.com.sa/protein-plain-milk', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('842caf87-d639-4f7b-88d3-29cb04540fc7', 'رز أبيض مطبوخ', 'Rice, white, long-grain, regular, enriched, cooked', 'حبوب ونشويات', 130.0, 2.7, 28.2, 0.3, 150.0, 'كوب إلا ربع', 'usda', '168878', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'حبوب ونشويات', 0.4, '{"iron": 1.2, "zinc": 0.49, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.04, "vit_k": 0, "folate": 97, "vit_b6": 0.093, "calcium": 10, "vit_b12": 0, "magnesium": 12, "potassium": 35}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('6c873115-ac3f-4b59-aefd-bf10ad63f1c6', 'رز بني مطبوخ', 'Rice, brown, long-grain, cooked (Includes foods for USDA''s Food Distribution Program)', 'حبوب ونشويات', 123.0, 2.7, 25.6, 1.0, 150.0, NULL, 'usda', '169704', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'حبوب ونشويات', 1.6, '{"iron": 0.56, "zinc": 0.71, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.17, "vit_k": 0.2, "folate": 9, "vit_b6": 0.123, "calcium": 3, "vit_b12": 0, "magnesium": 39, "potassium": 86}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('cb933bd7-918e-4d8a-a4d3-5d811078743b', 'رز أبيض (غير مطبوخ)', 'Rice, white, long-grain, regular, raw, enriched', 'حبوب ونشويات', 365.0, 7.1, 80.0, 0.7, 75.0, NULL, 'usda', '168877', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'حبوب ونشويات', 1.3, '{"iron": 4.31, "zinc": 1.09, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.11, "vit_k": 0.1, "folate": 387, "vit_b6": 0.164, "calcium": 28, "vit_b12": 0, "magnesium": 25, "potassium": 115}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('0017d7b4-349c-4a2c-bdeb-e741e1dec8a1', 'مكرونة مطبوخة', 'Pasta, cooked, enriched, without added salt', 'حبوب ونشويات', 158.0, 5.8, 30.9, 0.9, 140.0, 'كوب', 'usda', '169737', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'حبوب ونشويات', 1.8, '{"iron": 1.28, "zinc": 0.51, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.06, "vit_k": 0, "folate": 119, "vit_b6": 0.049, "calcium": 7, "vit_b12": 0, "magnesium": 18, "potassium": 44}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('96594751-0ce2-484e-9045-8a15de33b57b', 'مكرونة (غير مطبوخة)', 'Pasta, dry, enriched', 'حبوب ونشويات', 371.0, 13.0, 74.7, 1.5, 75.0, NULL, 'usda', '169736', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'حبوب ونشويات', 3.2, '{"iron": 3.3, "zinc": 1.41, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.11, "vit_k": 0.1, "folate": 391, "vit_b6": 0.142, "calcium": 21, "vit_b12": 0, "magnesium": 53, "potassium": 223}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d4664b3e-3617-47bc-b87a-5f30befac505', 'شوفان', 'Cereals, oats, regular and quick, not fortified, dry', 'حبوب ونشويات', 379.0, 13.2, 67.7, 6.5, 40.0, 'نص كوب', 'usda', '173904', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'حبوب ونشويات', 10.1, '{"iron": 4.25, "zinc": 3.64, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.42, "vit_k": 2, "folate": 32, "vit_b6": 0.1, "calcium": 52, "vit_b12": 0, "magnesium": 138, "potassium": 362}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('db2dc12f-ff2f-4f35-8a44-08b2fca72f94', 'خبز أبيض (توست)', 'Bread, white, commercially prepared (includes soft bread crumbs)', 'خبز', 266.0, 8.9, 49.4, 3.3, 28.0, 'شريحة', 'usda', '174924', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'حبوب ونشويات', 2.7, '{"iron": 3.61, "zinc": 0.74, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.22, "vit_k": 0.2, "folate": 171, "vit_b6": 0.087, "calcium": 144, "vit_b12": 0, "magnesium": 23, "potassium": 126}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('dbda9253-969c-4837-8715-b9c05ff5bfe0', 'خبز بر (توست أسمر)', 'Bread, whole-wheat, commercially prepared', 'خبز', 252.0, 12.5, 42.7, 3.5, 32.0, 'شريحة', 'usda', '172688', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'حبوب ونشويات', 6.0, '{"iron": 2.47, "zinc": 1.77, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 2.66, "vit_k": 7.8, "folate": 42, "vit_b6": 0.215, "calcium": 161, "vit_b12": 0, "magnesium": 75, "potassium": 254}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('09f79766-48d8-4b5f-b75f-5d9a5bfc1f5c', 'خبز عربي أبيض', 'Bread, pita, white, enriched', 'خبز', 275.0, 9.1, 55.7, 1.2, 60.0, 'رغيف صغير', 'usda', '174915', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'حبوب ونشويات', 2.2, '{"iron": 2.62, "zinc": 0.84, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.3, "vit_k": 0.2, "folate": 165, "vit_b6": 0.034, "calcium": 86, "vit_b12": 0, "magnesium": 26, "potassium": 120}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('35c2fcd1-1fe7-4dd9-9638-c08dd2a385de', 'خبز عربي بر', 'Bread, pita, whole-wheat', 'خبز', 262.0, 9.8, 55.9, 1.7, 64.0, 'رغيف صغير', 'usda', '174916', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'حبوب ونشويات', 6.1, '{"iron": 3.06, "zinc": 1.52, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.61, "vit_k": 1.4, "folate": 35, "vit_b6": 0.265, "calcium": 15, "vit_b12": 0, "magnesium": 69, "potassium": 170}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('e415f388-59f2-4421-a802-52ee69601d18', 'تورتيلا قمح', 'Tortillas, ready-to-bake or -fry, flour, refrigerated', 'خبز', 306.0, 8.2, 49.4, 8.0, 45.0, 'حبة', 'usda', '175037', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'حبوب ونشويات', 3.5, '{"iron": 3.63, "zinc": 0.53, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0, "vit_k": 7.2, "folate": 149, "vit_b6": 0.059, "calcium": 146, "vit_b12": 0, "magnesium": 22, "potassium": 125}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3f50514c-6839-47cc-9f0d-3df6755f5587', 'بطاطس مسلوقة', 'Potatoes, boiled, cooked without skin, flesh, without salt', 'حبوب ونشويات', 86.0, 1.7, 20.0, 0.1, 150.0, 'حبة وسط', 'usda', '170440', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'خضار نشوية', 1.8, '{"iron": 0.31, "zinc": 0.27, "vit_a": 0, "vit_c": 7.4, "vit_d": 0, "vit_e": 0.01, "vit_k": 2.2, "folate": 9, "vit_b6": 0.269, "calcium": 8, "vit_b12": 0, "magnesium": 20, "potassium": 328}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('05c086ef-1e8b-4115-9a82-a6ed921db6e3', 'بطاطا حلوة مشوية', 'Sweet potato, cooked, baked in skin, flesh, without salt', 'حبوب ونشويات', 90.0, 2.0, 20.7, 0.2, 150.0, 'حبة وسط', 'usda', '168483', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'خضار نشوية', 3.3, '{"iron": 0.69, "zinc": 0.32, "vit_a": 961, "vit_c": 19.6, "vit_d": 0, "vit_e": 0.71, "vit_k": 2.3, "folate": 6, "vit_b6": 0.286, "calcium": 38, "vit_b12": 0, "magnesium": 27, "potassium": 475}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a85e8e64-7787-4805-8f52-a381fa276a57', 'برغل مطبوخ', 'Bulgur, cooked', 'حبوب ونشويات', 83.0, 3.1, 18.6, 0.2, 150.0, NULL, 'usda', '170287', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'حبوب ونشويات', 4.5, '{"iron": 0.96, "zinc": 0.57, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.01, "vit_k": 0.5, "folate": 18, "vit_b6": 0.083, "calcium": 10, "vit_b12": 0, "magnesium": 32, "potassium": 68}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('47235f6b-1c81-490d-952a-d01bae0dde3f', 'كينوا مطبوخة', 'Quinoa, cooked', 'حبوب ونشويات', 120.0, 4.4, 21.3, 1.9, 150.0, NULL, 'usda', '168917', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'حبوب ونشويات', 2.8, '{"iron": 1.49, "zinc": 1.09, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.63, "vit_k": 0, "folate": 42, "vit_b6": 0.123, "calcium": 17, "vit_b12": 0, "magnesium": 64, "potassium": 172}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('e23afdad-d291-4963-8d7c-afc478e17b09', 'كورن فليكس', 'Cereals ready-to-eat, RALSTON Corn Flakes', 'حبوب ونشويات', 384.0, 5.9, 88.0, 0.9, 30.0, NULL, 'usda', '174648', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'حبوب ونشويات', 2.7, '{"iron": 19.4, "zinc": 0.2, "vit_a": 981, "vit_c": 65, "vit_d": 7.1, "vit_e": 0.02, "vit_k": 0, "vit_b6": 1.907, "calcium": 2, "vit_b12": 5.36, "magnesium": 7, "potassium": 107}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d37969b3-760e-4b37-8c1f-d65bbca8f5f1', 'صدر دجاج مشوي', 'Chicken, broilers or fryers, breast, meat only, cooked, roasted', 'لحوم ودواجن', 165.0, 31.0, 0.0, 3.6, 100.0, NULL, 'usda', '171477', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'لحوم بيضاء (دواجن)', 0.0, '{"iron": 1.04, "zinc": 1, "vit_a": 6, "vit_c": 0, "vit_d": 0.1, "vit_e": 0.27, "vit_k": 0.3, "folate": 4, "vit_b6": 0.6, "calcium": 15, "vit_b12": 0.34, "magnesium": 29, "potassium": 256}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('711ea359-c2ce-484b-9cc8-f4cbf7e9bfe5', 'صدر دجاج نيء', 'Chicken, broiler or fryers, breast, skinless, boneless, meat only, raw', 'لحوم ودواجن', 120.0, 22.5, 0.0, 2.6, 150.0, NULL, 'usda', '171077', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'لحوم بيضاء (دواجن)', 0.0, '{"iron": 0.37, "zinc": 0.68, "vit_a": 9, "vit_c": 0, "vit_d": 0, "vit_e": 0.56, "vit_k": 0, "folate": 9, "vit_b6": 0.811, "calcium": 5, "vit_b12": 0.21, "magnesium": 28, "potassium": 334}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('094b0b13-fc2d-4465-aa47-b8ad14aaed2f', 'فخذ دجاج مشوي (بدون جلد)', 'Chicken, broilers or fryers, thigh, meat only, cooked, roasted', 'لحوم ودواجن', 179.0, 24.8, 0.0, 8.2, 100.0, NULL, 'usda', '172388', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'لحوم بيضاء (دواجن)', 0.0, '{"iron": 1.13, "zinc": 1.92, "vit_a": 8, "vit_c": 0, "vit_d": 0.2, "vit_e": 0.18, "vit_k": 3.9, "folate": 5, "vit_b6": 0.462, "calcium": 9, "vit_b12": 0.42, "magnesium": 24, "potassium": 269}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('2085d57a-9185-4b7e-9976-8b8ce44fbb72', 'لحم بقري مفروم 90% مطبوخ', 'Beef, ground, 90% lean meat / 10% fat, patty, cooked, broiled', 'لحوم ودواجن', 217.0, 26.1, 0.0, 11.8, 100.0, NULL, 'usda', '174031', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'لحوم حمراء', 0.0, '{"iron": 2.71, "zinc": 6.37, "vit_a": 3, "vit_c": 0, "vit_d": 0, "vit_e": 0.12, "vit_k": 1.1, "folate": 8, "vit_b6": 0.397, "calcium": 13, "vit_b12": 2.56, "magnesium": 22, "potassium": 333}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('0ef651c0-cffd-4540-b4c8-c0f75137830f', 'لحم بقري مفروم 80% مطبوخ', 'Beef, ground, 80% lean meat / 20% fat, patty, cooked, broiled', 'لحوم ودواجن', 270.0, 25.8, 0.0, 17.8, 100.0, NULL, 'usda', '171797', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'لحوم حمراء', 0.0, '{"iron": 2.48, "zinc": 6.25, "vit_a": 3, "vit_c": 0, "vit_d": 0, "vit_e": 0.12, "vit_k": 1.6, "folate": 10, "vit_b6": 0.366, "calcium": 24, "vit_b12": 2.73, "magnesium": 20, "potassium": 304}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ed263880-cd7d-4ce8-b8e0-3b0656935fdc', 'لحم غنم مطبوخ', 'Lamb, composite of trimmed retail cuts, separable lean only, trimmed to 1/4" fat, choice, cooked', 'لحوم ودواجن', 206.0, 28.2, 0.0, 9.5, 100.0, NULL, 'usda', '174308', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'لحوم حمراء', 0.0, '{"iron": 2.05, "zinc": 5.27, "vit_a": 0, "vit_c": 0, "vit_e": 0.19, "folate": 23, "vit_b6": 0.16, "calcium": 15, "vit_b12": 2.61, "magnesium": 26, "potassium": 344}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('654fe21f-7413-483e-9f42-7b7d9da58e7e', 'ديك رومي (شرائح)', 'Turkey, whole, breast, meat only, cooked, roasted', 'لحوم ودواجن', 147.0, 30.1, 0.0, 2.1, 50.0, NULL, 'usda', '171496', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'لحوم بيضاء (دواجن)', 0.0, '{"iron": 0.71, "zinc": 1.72, "vit_a": 3, "vit_c": 0, "vit_d": 0.3, "vit_e": 0.06, "vit_k": 0, "folate": 9, "vit_b6": 0.807, "calcium": 9, "vit_b12": 0.39, "magnesium": 32, "potassium": 249}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a4839565-1589-4e29-be38-39647c4fafd1', 'تونة معلبة بالماء', 'Fish, tuna, light, canned in water, drained solids (Includes foods for USDA''s Food Distribution Program)', 'أسماك', 86.0, 19.4, 0.0, 1.0, 100.0, 'علبة صغيرة مصفاة', 'usda', '173709', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'أسماك ومأكولات بحرية', 0.0, '{"iron": 1.63, "zinc": 0.69, "vit_a": 17, "vit_c": 0, "vit_d": 1.2, "vit_e": 0.33, "vit_k": 0.2, "folate": 4, "vit_b6": 0.319, "calcium": 17, "vit_b12": 2.55, "magnesium": 23, "potassium": 179}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('912c20ed-a079-44ec-9539-15c163a186f3', 'تونة معلبة بالزيت', 'Fish, tuna, light, canned in oil, drained solids', 'أسماك', 198.0, 29.1, 0.0, 8.2, 100.0, NULL, 'usda', '173708', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'أسماك ومأكولات بحرية', 0.0, '{"iron": 1.39, "zinc": 0.9, "vit_a": 23, "vit_c": 0, "vit_d": 6.7, "vit_e": 0.87, "vit_k": 44, "folate": 5, "vit_b6": 0.11, "calcium": 13, "vit_b12": 2.2, "magnesium": 31, "potassium": 207}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('7c8e74e1-6908-40a9-b6d3-8cd5913ac7c8', 'سلمون مطبوخ', 'Fish, salmon, Atlantic, farmed, cooked, dry heat', 'أسماك', 206.0, 22.1, 0.0, 12.4, 120.0, NULL, 'usda', '175168', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'أسماك ومأكولات بحرية', 0.0, '{"iron": 0.34, "zinc": 0.43, "vit_a": 69, "vit_c": 3.7, "vit_d": 13.1, "vit_e": 1.14, "vit_k": 0.1, "folate": 34, "vit_b6": 0.647, "calcium": 15, "vit_b12": 2.8, "magnesium": 30, "potassium": 384}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f2b64009-ede0-4128-9d7b-cabb560f1e30', 'سلمون مدخن', 'Fish, salmon, chinook, smoked', 'أسماك', 117.0, 18.3, 0.0, 4.3, 60.0, NULL, 'usda', '173687', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'أسماك ومأكولات بحرية', 0.0, '{"iron": 0.85, "zinc": 0.31, "vit_a": 26, "vit_c": 0, "vit_d": 17.1, "vit_e": 1.35, "vit_k": 0.1, "folate": 2, "vit_b6": 0.278, "calcium": 11, "vit_b12": 3.26, "magnesium": 18, "potassium": 175}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3815a3b8-4a61-4603-b7e5-5864d6b4b6c4', 'روبيان مطبوخ', 'Crustaceans, shrimp, cooked', 'أسماك', 99.0, 24.0, 0.2, 0.3, 100.0, NULL, 'usda', '175180', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'أسماك ومأكولات بحرية', 0.0, '{"iron": 0.51, "zinc": 1.64, "calcium": 70, "magnesium": 39, "potassium": 259}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('1a594a0c-6bae-46ef-bb01-804324172f4e', 'هامور/سمك أبيض مطبوخ', 'Fish, grouper, mixed species, cooked, dry heat', 'أسماك', 118.0, 24.8, 0.0, 1.3, 150.0, NULL, 'usda', '171963', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'أسماك ومأكولات بحرية', 0.0, '{"iron": 1.14, "zinc": 0.51, "vit_a": 50, "vit_c": 0, "folate": 10, "vit_b6": 0.35, "calcium": 21, "vit_b12": 0.69, "magnesium": 37, "potassium": 475}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3a742d3c-aad7-4154-b56e-05da03ca435e', 'بيض كامل', 'Egg, whole, raw, fresh', 'بيض وألبان', 143.0, 12.6, 0.7, 9.5, 50.0, 'بيضة', 'usda', '171287', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'بيض', 0.0, '{"iron": 1.75, "zinc": 1.29, "vit_a": 160, "vit_c": 0, "vit_d": 2, "vit_e": 1.05, "vit_k": 0.3, "folate": 47, "vit_b6": 0.17, "calcium": 56, "vit_b12": 0.89, "magnesium": 12, "potassium": 138}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('22789608-1862-4051-8f48-cf9b501c28d1', 'بياض بيض', 'Egg, white, raw, fresh', 'بيض وألبان', 52.0, 10.9, 0.7, 0.2, 33.0, 'بياض بيضة', 'usda', '172183', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'بيض', 0.0, '{"iron": 0.08, "zinc": 0.03, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0, "vit_k": 0, "folate": 4, "vit_b6": 0.005, "calcium": 7, "vit_b12": 0.09, "magnesium": 11, "potassium": 163}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('043f719e-2284-49d9-bcb3-15a872c0a163', 'بيض مسلوق', 'Egg, whole, cooked, hard-boiled', 'بيض وألبان', 155.0, 12.6, 1.1, 10.6, 50.0, 'بيضة', 'usda', '173424', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'بيض', 0.0, '{"iron": 1.19, "zinc": 1.05, "vit_a": 149, "vit_c": 0, "vit_d": 2.2, "vit_e": 1.03, "vit_k": 0.3, "folate": 44, "vit_b6": 0.121, "calcium": 50, "vit_b12": 1.11, "magnesium": 10, "potassium": 126}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3e81f078-2b0d-45d6-9365-b8f434ffb464', 'حليب كامل الدسم', 'Milk, whole, 3.25% milkfat, with added vitamin D', 'بيض وألبان', 61.0, 3.2, 4.8, 3.3, 244.0, 'كوب', 'usda', '171265', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', 0.0, '{"iron": 0.03, "zinc": 0.37, "vit_a": 46, "vit_c": 0, "vit_d": 1.3, "vit_e": 0.07, "vit_k": 0.3, "folate": 5, "vit_b6": 0.036, "calcium": 113, "vit_b12": 0.45, "magnesium": 10, "potassium": 132}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('07203df3-93ca-4384-8dda-888a234c57ed', 'حليب قليل الدسم 1%', 'Milk, lowfat, fluid, 1% milkfat, with added vitamin A and vitamin D', 'بيض وألبان', 42.0, 3.4, 5.0, 1.0, 244.0, 'كوب', 'usda', '170872', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', 0.0, '{"iron": 0.03, "zinc": 0.42, "vit_a": 58, "vit_c": 0, "vit_d": 1.2, "vit_e": 0.01, "vit_k": 0.1, "folate": 5, "vit_b6": 0.037, "calcium": 125, "vit_b12": 0.47, "magnesium": 11, "potassium": 150}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('e1e15b26-e905-4f60-be99-107f13cc59f8', 'حليب خالي الدسم', 'Milk, nonfat, fluid, with added vitamin A and vitamin D (fat free or skim)', 'بيض وألبان', 34.0, 3.4, 5.0, 0.1, 245.0, 'كوب', 'usda', '171269', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', 0.0, '{"iron": 0.03, "zinc": 0.42, "vit_a": 61, "vit_c": 0, "vit_d": 1.2, "vit_e": 0.01, "vit_k": 0, "folate": 5, "vit_b6": 0.037, "calcium": 122, "vit_b12": 0.5, "magnesium": 11, "potassium": 156}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('1fa8c8c8-47ea-4f5c-8a9c-79aa5eb16f00', 'زبادي كامل الدسم', 'Yogurt, plain, whole milk', 'بيض وألبان', 61.0, 3.5, 4.7, 3.3, 170.0, NULL, 'usda', '171284', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', 0.0, '{"iron": 0.05, "zinc": 0.59, "vit_a": 27, "vit_c": 0.5, "vit_d": 0.1, "vit_e": 0.06, "vit_k": 0.2, "folate": 7, "vit_b6": 0.032, "calcium": 121, "vit_b12": 0.37, "magnesium": 12, "potassium": 155}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f3c169ca-e461-44ad-a378-6c929e6dd2fd', 'زبادي قليل الدسم', 'Yogurt, plain, low fat', 'بيض وألبان', 63.0, 5.3, 7.0, 1.6, 170.0, NULL, 'usda', '170886', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', 0.0, '{"iron": 0.08, "zinc": 0.89, "vit_a": 14, "vit_c": 0.8, "vit_d": 0, "vit_e": 0.03, "vit_k": 0.2, "folate": 11, "vit_b6": 0.049, "calcium": 183, "vit_b12": 0.56, "magnesium": 17, "potassium": 234}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a87ddae8-034c-4901-a798-13a8573900b0', 'زبادي يوناني قليل الدسم', 'Yogurt, Greek, plain, lowfat', 'بيض وألبان', 73.0, 10.0, 3.9, 1.9, 170.0, NULL, 'usda', '170903', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', 0.0, '{"iron": 0.04, "zinc": 0.6, "vit_a": 90, "vit_c": 0.8, "vit_d": 0, "vit_e": 0.04, "vit_k": 0.2, "folate": 12, "vit_b6": 0.055, "calcium": 115, "vit_b12": 0.52, "magnesium": 11, "potassium": 141}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('9fc5bb4d-3a82-4e23-b01c-15ce0e577bf3', 'زبادي يوناني خالي الدسم', 'Yogurt, Greek, plain, nonfat (Includes foods for USDA''s Food Distribution Program)', 'بيض وألبان', 59.0, 10.2, 3.6, 0.4, 170.0, NULL, 'usda', '170894', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', 0.0, '{"iron": 0.07, "zinc": 0.52, "vit_a": 1, "vit_c": 0, "vit_d": 0, "vit_e": 0.01, "vit_k": 0, "folate": 7, "vit_b6": 0.063, "calcium": 110, "vit_b12": 0.75, "magnesium": 11, "potassium": 141}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('9ab6ec2c-1d4e-424a-a56e-b3111eb57653', 'جبنة قريش (كوتج)', 'Cheese, cottage, lowfat, 2% milkfat', 'بيض وألبان', 81.0, 10.5, 4.8, 2.3, 113.0, 'نص كوب', 'usda', '172182', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', 0.0, '{"iron": 0.13, "zinc": 0.51, "vit_a": 68, "vit_c": 0, "vit_d": 0, "vit_e": 0.08, "vit_k": 0, "folate": 8, "vit_b6": 0.057, "calcium": 111, "vit_b12": 0.47, "magnesium": 9, "potassium": 125}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ea8bf57e-5686-4b47-a3d8-93f68478bc87', 'جبنة موزاريلا قليلة الدسم', 'Cheese, mozzarella, part skim milk', 'بيض وألبان', 254.0, 24.3, 2.8, 15.9, 28.0, NULL, 'usda', '170847', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', 0.0, '{"iron": 0.22, "zinc": 2.76, "vit_a": 127, "vit_c": 0, "vit_d": 0.3, "vit_e": 0.14, "vit_k": 1.6, "folate": 9, "vit_b6": 0.07, "calcium": 782, "vit_b12": 0.82, "magnesium": 23, "potassium": 84}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3a71bae8-c2f2-4e69-9fd9-7c08a639a12f', 'جبنة شيدر', 'Cheese, cheddar (Includes foods for USDA''s Food Distribution Program)', 'بيض وألبان', 403.0, 22.9, 3.4, 33.3, 28.0, 'شريحة', 'usda', '173414', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', 0.0, '{"iron": 0.14, "zinc": 3.64, "vit_a": 337, "vit_c": 0, "vit_d": 0.6, "vit_e": 0.71, "vit_k": 2.4, "folate": 27, "vit_b6": 0.066, "calcium": 710, "vit_b12": 1.1, "magnesium": 27, "potassium": 76}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('7fa336ae-8244-4af9-9479-f5d75e3f9780', 'جبنة فيتا', 'Cheese, feta', 'بيض وألبان', 265.0, 14.2, 3.9, 21.5, 28.0, NULL, 'usda', '173420', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', 0.0, '{"iron": 0.65, "zinc": 2.88, "vit_a": 125, "vit_c": 0, "vit_d": 0.4, "vit_e": 0.18, "vit_k": 1.8, "folate": 32, "vit_b6": 0.424, "calcium": 493, "vit_b12": 1.69, "magnesium": 19, "potassium": 62}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3202e137-643f-462f-96cd-1a31f692c4db', 'جبنة كريمية', 'Cheese, cream', 'بيض وألبان', 350.0, 6.2, 5.5, 34.4, 30.0, NULL, 'usda', '173418', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', 0.0, '{"iron": 0.11, "zinc": 0.5, "vit_a": 308, "vit_c": 0, "vit_d": 0, "vit_e": 0.86, "vit_k": 2.1, "folate": 9, "vit_b6": 0.056, "calcium": 97, "vit_b12": 0.22, "magnesium": 9, "potassium": 132}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('37c836d0-6b6d-4cdd-b449-32ec7fbc5ab4', 'واي بروتين', 'Beverages, Whey protein powder isolate', 'مكملات', 359.0, 58.1, 29.1, 1.2, 30.0, 'سكوب', 'usda', '173177', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'مكملات', 0.0, '{"iron": 1.26, "zinc": 8.72, "vit_a": 872, "vit_c": 34.9, "vit_d": 0, "vit_e": 7.85, "vit_k": 46.5, "folate": 395, "vit_b6": 1.163, "calcium": 698, "vit_b12": 3.49, "magnesium": 233, "potassium": 872}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('297cac30-d34d-4f34-a93a-4b7ec7e0569f', 'عدس مطبوخ', 'Lentils, mature seeds, cooked, boiled, without salt', 'بقوليات', 116.0, 9.0, 20.1, 0.4, 150.0, NULL, 'usda', '172421', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'بقوليات', 7.9, '{"iron": 3.33, "zinc": 1.27, "vit_a": 0, "vit_c": 1.5, "vit_d": 0, "vit_e": 0.11, "vit_k": 1.7, "folate": 181, "vit_b6": 0.178, "calcium": 19, "vit_b12": 0, "magnesium": 36, "potassium": 369}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ef2fa7c9-e64e-45f6-a3a6-67cd66f1b855', 'حمص مطبوخ', 'Chickpeas (garbanzo beans, bengal gram), mature seeds, cooked, boiled, without salt', 'بقوليات', 164.0, 8.9, 27.4, 2.6, 150.0, NULL, 'usda', '173757', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'بقوليات', 7.6, '{"iron": 2.89, "zinc": 1.53, "vit_a": 1, "vit_c": 1.3, "vit_d": 0, "vit_e": 0.35, "vit_k": 4, "folate": 172, "vit_b6": 0.139, "calcium": 49, "vit_b12": 0, "magnesium": 48, "potassium": 291}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a74598f6-6557-4c00-b526-d0178f612ed0', 'فول مدمس (مطبوخ)', 'Broadbeans (fava beans), mature seeds, cooked, boiled, without salt', 'بقوليات', 110.0, 7.6, 19.7, 0.4, 150.0, NULL, 'usda', '173753', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'بقوليات', 5.4, '{"iron": 1.5, "zinc": 1.01, "vit_a": 1, "vit_c": 0.3, "vit_d": 0, "vit_e": 0.02, "vit_k": 2.9, "folate": 104, "vit_b6": 0.072, "calcium": 36, "vit_b12": 0, "magnesium": 43, "potassium": 268}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('77bd0bf1-bca6-4020-b962-80f6585a5fc7', 'فاصوليا حمراء مطبوخة', 'Beans, kidney, all types, mature seeds, cooked, boiled, without salt', 'بقوليات', 127.0, 8.7, 22.8, 0.5, 150.0, NULL, 'usda', '173740', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'بقوليات', 6.4, '{"iron": 2.22, "zinc": 1, "vit_a": 0, "vit_c": 1.2, "vit_d": 0, "vit_e": 0.03, "vit_k": 8.4, "folate": 130, "vit_b6": 0.12, "calcium": 35, "vit_b12": 0, "magnesium": 42, "potassium": 405}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('85bde9fe-3d8c-4dbc-be94-77502c9d3f00', 'حمص بطحينة (حمص جاهز)', 'Hummus, commercial', 'بقوليات', 237.0, 7.8, 15.0, 17.8, 60.0, NULL, 'usda', '174289', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'بقوليات', 5.5, '{"iron": 2.54, "zinc": 1.44, "vit_a": 1, "vit_c": 0, "vit_d": 0, "vit_e": 1.54, "vit_k": 22.8, "folate": 48, "vit_b6": 0.146, "calcium": 47, "vit_b12": 0, "magnesium": 75, "potassium": 312}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('32da22e7-da59-4981-bd3e-bfad2e22bdea', 'تمر مجدول', 'Dates, medjool', 'فواكه', 277.0, 1.8, 75.0, 0.2, 24.0, 'حبة', 'usda', '168191', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'فواكه', 6.7, '{"iron": 0.9, "zinc": 0.44, "vit_a": 7, "vit_c": 0, "vit_d": 0, "vit_k": 2.7, "folate": 15, "vit_b6": 0.249, "calcium": 64, "magnesium": 54, "potassium": 696}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a659d837-57ca-4f6c-9573-b1b01f0e4785', 'تمر (دقلة نور)', 'Dates, deglet noor', 'فواكه', 282.0, 2.5, 75.0, 0.4, 7.0, 'حبة', 'usda', '171726', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'فواكه', 8.0, '{"iron": 1.02, "zinc": 0.29, "vit_a": 0, "vit_c": 0.4, "vit_d": 0, "vit_e": 0.05, "vit_k": 2.7, "folate": 19, "vit_b6": 0.165, "calcium": 39, "vit_b12": 0, "magnesium": 43, "potassium": 656}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('1dead6d1-5370-4d5c-9bd7-e84995f9e67a', 'موز', 'Bananas, raw', 'فواكه', 89.0, 1.1, 22.8, 0.3, 118.0, 'حبة وسط', 'usda', '173944', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'فواكه', 2.6, '{"iron": 0.26, "zinc": 0.15, "vit_a": 3, "vit_c": 8.7, "vit_d": 0, "vit_e": 0.1, "vit_k": 0.5, "folate": 20, "vit_b6": 0.367, "calcium": 5, "vit_b12": 0, "magnesium": 27, "potassium": 358}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d873e98e-6766-4afe-b076-30649d034e6e', 'تفاح', 'Apples, raw, with skin (Includes foods for USDA''s Food Distribution Program)', 'فواكه', 52.0, 0.3, 13.8, 0.2, 182.0, 'حبة وسط', 'usda', '171688', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'فواكه', 2.4, '{"iron": 0.12, "zinc": 0.04, "vit_a": 3, "vit_c": 4.6, "vit_d": 0, "vit_e": 0.18, "vit_k": 2.2, "folate": 3, "vit_b6": 0.041, "calcium": 6, "vit_b12": 0, "magnesium": 5, "potassium": 107}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('54ac5287-5030-4cec-96bd-e596f523e400', 'برتقال', 'Oranges, raw, all commercial varieties', 'فواكه', 47.0, 0.9, 11.8, 0.1, 131.0, 'حبة', 'usda', '169097', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'فواكه', 2.4, '{"iron": 0.1, "zinc": 0.07, "vit_a": 11, "vit_c": 53.2, "vit_d": 0, "vit_e": 0.18, "vit_k": 0, "folate": 30, "vit_b6": 0.06, "calcium": 40, "vit_b12": 0, "magnesium": 10, "potassium": 181}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('281cbeda-cf07-4f6e-990b-190c3c8211d5', 'فراولة', 'Strawberries, raw', 'فواكه', 32.0, 0.7, 7.7, 0.3, 150.0, 'كوب', 'usda', '167762', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'فواكه', 2.0, '{"iron": 0.41, "zinc": 0.14, "vit_a": 1, "vit_c": 58.8, "vit_d": 0, "vit_e": 0.29, "vit_k": 2.2, "folate": 24, "vit_b6": 0.047, "calcium": 16, "vit_b12": 0, "magnesium": 13, "potassium": 153}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('094c6ba5-df60-4dbe-bd86-65557b5d967f', 'عنب', 'Grapes, red or green (European type, such as Thompson seedless), raw', 'فواكه', 69.0, 0.7, 18.1, 0.2, 150.0, 'كوب', 'usda', '174683', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'فواكه', 0.9, '{"iron": 0.36, "zinc": 0.07, "vit_a": 3, "vit_c": 3.2, "vit_d": 0, "vit_e": 0.19, "vit_k": 14.6, "folate": 2, "vit_b6": 0.086, "calcium": 10, "vit_b12": 0, "magnesium": 7, "potassium": 191}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('aacca572-dbd5-4de4-8e50-ae5716c1287a', 'بطيخ', 'Watermelon, raw', 'فواكه', 30.0, 0.6, 7.6, 0.2, 280.0, 'كوب ونص', 'usda', '167765', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'فواكه', 0.4, '{"iron": 0.24, "zinc": 0.1, "vit_a": 28, "vit_c": 8.1, "vit_d": 0, "vit_e": 0.05, "vit_k": 0.1, "folate": 3, "vit_b6": 0.045, "calcium": 7, "vit_b12": 0, "magnesium": 10, "potassium": 112}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('530e420b-4918-41c2-8c16-3a8ef4d82a9d', 'مانجو', 'Mangos, raw', 'فواكه', 60.0, 0.8, 15.0, 0.4, 165.0, 'كوب', 'usda', '169910', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'فواكه', 1.6, '{"iron": 0.16, "zinc": 0.09, "vit_a": 54, "vit_c": 36.4, "vit_d": 0, "vit_e": 0.9, "vit_k": 4.2, "folate": 43, "vit_b6": 0.119, "calcium": 11, "vit_b12": 0, "magnesium": 10, "potassium": 168}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('61e1f0ee-372f-4e27-a18c-c7e422e012c6', 'أناناس', 'Pineapple, raw, all varieties', 'فواكه', 50.0, 0.5, 13.1, 0.1, 165.0, 'كوب', 'usda', '169124', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'فواكه', 1.4, '{"iron": 0.29, "zinc": 0.12, "vit_a": 3, "vit_c": 47.8, "vit_d": 0, "vit_e": 0.02, "vit_k": 0.7, "folate": 18, "vit_b6": 0.112, "calcium": 13, "vit_b12": 0, "magnesium": 12, "potassium": 109}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('fc549a57-0b77-48aa-a12a-b4148f4d7ca8', 'توت أزرق', 'Blueberries, raw', 'فواكه', 57.0, 0.7, 14.5, 0.3, 148.0, 'كوب', 'usda', '171711', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'فواكه', 2.4, '{"iron": 0.28, "zinc": 0.16, "vit_a": 3, "vit_c": 9.7, "vit_d": 0, "vit_e": 0.57, "vit_k": 19.3, "folate": 6, "vit_b6": 0.052, "calcium": 6, "vit_b12": 0, "magnesium": 6, "potassium": 77}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('722399cf-9c12-41ee-a30a-88ce1ce0b13c', 'كيوي', 'Kiwifruit, green, raw', 'فواكه', 61.0, 1.1, 14.7, 0.5, 75.0, 'حبة', 'usda', '168153', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'فواكه', 3.0, '{"iron": 0.31, "zinc": 0.14, "vit_a": 4, "vit_c": 92.7, "vit_d": 0, "vit_e": 1.46, "vit_k": 40.3, "folate": 25, "vit_b6": 0.063, "calcium": 34, "vit_b12": 0, "magnesium": 17, "potassium": 312}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('64b70fc9-eb2e-4bb1-ac26-2c4a548bd2f0', 'رمان', 'Pomegranates, raw', 'فواكه', 83.0, 1.7, 18.7, 1.2, 87.0, 'نص كوب حبوب', 'usda', '169134', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'فواكه', 4.0, '{"iron": 0.3, "zinc": 0.35, "vit_a": 0, "vit_c": 10.2, "vit_d": 0, "vit_e": 0.6, "vit_k": 16.4, "folate": 38, "vit_b6": 0.075, "calcium": 10, "vit_b12": 0, "magnesium": 12, "potassium": 236}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d0407168-331d-434a-9031-3574798207f5', 'خيار', 'Cucumber, with peel, raw', 'خضار', 15.0, 0.7, 3.6, 0.1, 100.0, NULL, 'usda', '168409', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'خضار', 0.5, '{"iron": 0.28, "zinc": 0.2, "vit_a": 5, "vit_c": 2.8, "vit_d": 0, "vit_e": 0.03, "vit_k": 16.4, "folate": 7, "vit_b6": 0.04, "calcium": 16, "vit_b12": 0, "magnesium": 13, "potassium": 147}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('4fb777f4-f320-45aa-851a-cd2eeafd6aff', 'طماطم', 'Tomatoes, red, ripe, raw, year round average', 'خضار', 18.0, 0.9, 3.9, 0.2, 120.0, 'حبة وسط', 'usda', '170457', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'خضار', 1.2, '{"iron": 0.27, "zinc": 0.17, "vit_a": 42, "vit_c": 13.7, "vit_d": 0, "vit_e": 0.54, "vit_k": 7.9, "folate": 15, "vit_b6": 0.08, "calcium": 10, "vit_b12": 0, "magnesium": 11, "potassium": 237}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('67a69a9e-25db-42f6-905c-3fbb2fb1730e', 'خس', 'Lettuce, cos or romaine, raw', 'خضار', 17.0, 1.2, 3.3, 0.3, 50.0, NULL, 'usda', '169247', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'خضار', 2.1, '{"iron": 0.97, "zinc": 0.23, "vit_a": 436, "vit_c": 4, "vit_d": 0, "vit_e": 0.13, "vit_k": 102.5, "folate": 136, "vit_b6": 0.074, "calcium": 33, "vit_b12": 0, "magnesium": 14, "potassium": 247}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('dc261de1-a522-4f4d-971f-29951b13942d', 'جزر', 'Carrots, raw', 'خضار', 41.0, 0.9, 9.6, 0.2, 60.0, 'حبة', 'usda', '170393', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'خضار', 2.8, '{"iron": 0.3, "zinc": 0.24, "vit_a": 835, "vit_c": 5.9, "vit_d": 0, "vit_e": 0.66, "vit_k": 13.2, "folate": 19, "vit_b6": 0.138, "calcium": 33, "vit_b12": 0, "magnesium": 12, "potassium": 320}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('8d3aaacc-4027-473f-93f3-f8517a588868', 'بروكلي مطبوخ', 'Broccoli, cooked, boiled, drained, without salt', 'خضار', 35.0, 2.4, 7.2, 0.4, 90.0, NULL, 'usda', '169967', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'خضار', 3.3, '{"iron": 0.67, "zinc": 0.45, "vit_a": 77, "vit_c": 64.9, "vit_d": 0, "vit_e": 1.45, "vit_k": 141.1, "folate": 108, "vit_b6": 0.2, "calcium": 40, "vit_b12": 0, "magnesium": 21, "potassium": 293}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('847b79bc-273f-45d9-b5da-8f819cc8de88', 'سبانخ', 'Spinach, raw', 'خضار', 23.0, 2.9, 3.6, 0.4, 30.0, 'كوب', 'usda', '168462', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'خضار', 2.2, '{"iron": 2.71, "zinc": 0.53, "vit_a": 469, "vit_c": 28.1, "vit_d": 0, "vit_e": 2.03, "vit_k": 482.9, "folate": 194, "vit_b6": 0.195, "calcium": 99, "vit_b12": 0, "magnesium": 79, "potassium": 558}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('add1cbd4-dd79-4187-861d-95b61115f25a', 'فلفل رومي أحمر', 'Peppers, sweet, red, raw', 'خضار', 26.0, 1.0, 6.0, 0.3, 120.0, 'حبة', 'usda', '170108', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'خضار', 2.1, '{"iron": 0.43, "zinc": 0.25, "vit_a": 157, "vit_c": 127.7, "vit_d": 0, "vit_e": 1.58, "vit_k": 4.9, "folate": 46, "vit_b6": 0.291, "calcium": 7, "vit_b12": 0, "magnesium": 12, "potassium": 211}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('78a9592c-d37d-479f-9d29-87b14e8e4b70', 'بصل', 'Onions, raw', 'خضار', 40.0, 1.1, 9.3, 0.1, 110.0, 'حبة وسط', 'usda', '170000', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'خضار', 1.7, '{"iron": 0.21, "zinc": 0.17, "vit_a": 0, "vit_c": 7.4, "vit_d": 0, "vit_e": 0.02, "vit_k": 0.4, "folate": 19, "vit_b6": 0.12, "calcium": 23, "vit_b12": 0, "magnesium": 10, "potassium": 146}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b5999c70-864f-4ad2-8205-d94fd51222d5', 'فطر (مشروم)', 'Mushrooms, white, raw', 'خضار', 22.0, 3.1, 3.3, 0.3, 70.0, 'كوب', 'usda', '169251', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'خضار', 1.0, '{"iron": 0.5, "zinc": 0.52, "vit_a": 0, "vit_c": 2.1, "vit_d": 0.2, "vit_e": 0.01, "vit_k": 0, "folate": 17, "vit_b6": 0.104, "calcium": 3, "vit_b12": 0.04, "magnesium": 9, "potassium": 318}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('bf1e538f-e8a9-475d-86b4-ac5161a6808f', 'كوسا مطبوخة', 'Squash, summer, zucchini, includes skin, cooked, boiled, drained, without salt', 'خضار', 15.0, 1.1, 2.7, 0.4, 180.0, NULL, 'usda', '169292', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'خضار', 1.0, '{"iron": 0.37, "zinc": 0.33, "vit_a": 56, "vit_c": 12.9, "vit_d": 0, "vit_e": 0.12, "vit_k": 4.2, "folate": 28, "vit_b6": 0.08, "calcium": 18, "vit_b12": 0, "magnesium": 19, "potassium": 264}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('c5209a18-d15e-4542-b0bd-a67d7883573d', 'باذنجان مطبوخ', 'Eggplant, cooked, boiled, drained, without salt', 'خضار', 35.0, 0.8, 8.7, 0.2, 100.0, NULL, 'usda', '169229', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'خضار', 2.5, '{"iron": 0.25, "zinc": 0.12, "vit_a": 2, "vit_c": 1.3, "vit_d": 0, "vit_e": 0.41, "vit_k": 2.9, "folate": 14, "vit_b6": 0.086, "calcium": 6, "vit_b12": 0, "magnesium": 11, "potassium": 123}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('0b046ff6-4d1f-418c-8c2f-064f8507154c', 'ذرة حلوة مطبوخة', 'Corn, sweet, yellow, cooked, boiled, drained, without salt', 'خضار', 96.0, 3.4, 21.0, 1.5, 150.0, NULL, 'usda', '169999', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'خضار نشوية', 2.4, '{"iron": 0.45, "zinc": 0.62, "vit_a": 13, "vit_c": 5.5, "vit_d": 0, "vit_e": 0.09, "vit_k": 0.4, "folate": 23, "vit_b6": 0.139, "calcium": 3, "vit_b12": 0, "magnesium": 26, "potassium": 218}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('155fc8fd-eb31-4b26-936b-8c3791a6981e', 'أفوكادو', 'Avocados, raw, all commercial varieties', 'دهون ومكسرات', 160.0, 2.0, 8.5, 14.7, 50.0, 'ثلث حبة', 'usda', '171705', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'فواكه', 6.7, '{"iron": 0.55, "zinc": 0.64, "vit_a": 7, "vit_c": 10, "vit_d": 0, "vit_e": 2.07, "vit_k": 21, "folate": 81, "vit_b6": 0.257, "calcium": 12, "vit_b12": 0, "magnesium": 29, "potassium": 485}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('e8e955e6-cdcf-45c3-af9d-6e1901307e0b', 'زيت زيتون', 'Oil, olive, salad or cooking', 'دهون ومكسرات', 884.0, 0.0, 0.0, 100.0, 5.0, 'ملعقة صغيرة', 'usda', '171413', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'دهون وزيوت', 0.0, '{"iron": 0.56, "zinc": 0, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 14.35, "vit_k": 60.2, "folate": 0, "vit_b6": 0, "calcium": 1, "vit_b12": 0, "magnesium": 0, "potassium": 1}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('bfca0288-d69f-4517-92aa-9cef78d27b9c', 'زبدة', 'Butter, salted', 'دهون ومكسرات', 717.0, 0.9, 0.1, 81.1, 5.0, 'ملعقة صغيرة', 'usda', '173410', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'دهون وزيوت', 0.0, '{"iron": 0.02, "zinc": 0.09, "vit_a": 684, "vit_c": 0, "vit_d": 0, "vit_e": 2.32, "vit_k": 7, "folate": 3, "vit_b6": 0.003, "calcium": 24, "vit_b12": 0.17, "magnesium": 2, "potassium": 24}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('c9b914fb-55cf-4c52-9191-787d6ec5e21f', 'لوز', 'Nuts, almonds', 'دهون ومكسرات', 579.0, 21.2, 21.6, 49.9, 28.0, 'حفنة', 'usda', '170567', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'مكسرات وبذور', 12.5, '{"iron": 3.71, "zinc": 3.12, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 25.63, "vit_k": 0, "folate": 44, "vit_b6": 0.137, "calcium": 269, "vit_b12": 0, "magnesium": 270, "potassium": 733}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('5ad4b220-a83e-4503-ad60-875c6bfba6da', 'كاجو', 'Nuts, cashew nuts, raw', 'دهون ومكسرات', 553.0, 18.2, 30.2, 43.9, 28.0, 'حفنة', 'usda', '170162', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'مكسرات وبذور', 3.3, '{"iron": 6.68, "zinc": 5.78, "vit_a": 0, "vit_c": 0.5, "vit_d": 0, "vit_e": 0.9, "vit_k": 34.1, "folate": 25, "vit_b6": 0.417, "calcium": 37, "vit_b12": 0, "magnesium": 292, "potassium": 660}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('95c5e4d7-c8a6-4722-92d8-b9c02b6a316b', 'فستق حلبي', 'Nuts, pistachio nuts, raw', 'دهون ومكسرات', 560.0, 20.2, 27.2, 45.3, 28.0, 'حفنة', 'usda', '170184', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'مكسرات وبذور', 10.6, '{"iron": 3.92, "zinc": 2.2, "vit_a": 26, "vit_c": 5.6, "vit_d": 0, "vit_e": 2.86, "folate": 51, "vit_b6": 1.7, "calcium": 105, "vit_b12": 0, "magnesium": 121, "potassium": 1025}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('27550918-17c8-4038-82d1-df71c1b41730', 'جوز (عين الجمل)', 'Nuts, walnuts, english', 'دهون ومكسرات', 654.0, 15.2, 13.7, 65.2, 28.0, 'حفنة', 'usda', '170187', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'مكسرات وبذور', 6.7, '{"iron": 2.91, "zinc": 3.09, "vit_a": 1, "vit_c": 1.3, "vit_d": 0, "vit_e": 0.7, "vit_k": 2.7, "folate": 98, "vit_b6": 0.537, "calcium": 98, "vit_b12": 0, "magnesium": 158, "potassium": 441}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('c3858744-1349-421c-a122-70a0dc85b9ad', 'زبدة فول سوداني', 'Peanut butter, smooth style, without salt', 'دهون ومكسرات', 598.0, 22.2, 22.3, 51.4, 16.0, 'ملعقة كبيرة', 'usda', '172470', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'مكسرات وبذور', 5.0, '{"iron": 1.74, "zinc": 2.51, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 9.1, "vit_k": 0.3, "folate": 87, "vit_b6": 0.441, "calcium": 49, "vit_b12": 0, "magnesium": 168, "potassium": 558}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('0fadb018-e911-4bbf-ac7c-1e6248b11ab7', 'فول سوداني', 'Peanuts, all types, raw', 'دهون ومكسرات', 567.0, 25.8, 16.1, 49.2, 28.0, 'حفنة', 'usda', '172430', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'مكسرات وبذور', 8.5, '{"iron": 4.58, "zinc": 3.27, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 8.33, "vit_k": 0, "folate": 240, "vit_b6": 0.348, "calcium": 92, "vit_b12": 0, "magnesium": 168, "potassium": 705}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('5961aebe-a7f5-49bb-9421-e0bf536d1df0', 'طحينة', 'Seeds, sesame butter, tahini, from roasted and toasted kernels (most common type)', 'دهون ومكسرات', 595.0, 17.0, 21.2, 53.8, 15.0, 'ملعقة كبيرة', 'usda', '170189', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'مكسرات وبذور', 9.3, '{"iron": 8.95, "zinc": 4.62, "vit_a": 3, "vit_c": 0, "vit_d": 0, "vit_e": 0.25, "vit_k": 0, "folate": 98, "vit_b6": 0.149, "calcium": 426, "vit_b12": 0, "magnesium": 95, "potassium": 414}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('28f220f3-2b58-4d50-9387-cfbd27b5c785', 'بذور الشيا', 'Seeds, chia seeds, dried', 'دهون ومكسرات', 486.0, 16.5, 42.1, 30.7, 12.0, 'ملعقة كبيرة', 'usda', '170554', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'مكسرات وبذور', 34.4, '{"iron": 7.72, "zinc": 4.58, "vit_c": 1.6, "vit_e": 0.5, "calcium": 631, "vit_b12": 0, "magnesium": 335, "potassium": 407}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b6203eb3-d87c-4b11-94e9-757676f6d209', 'عسل', 'Honey', 'حلويات ومشروبات', 304.0, 0.3, 82.4, 0.0, 21.0, 'ملعقة كبيرة', 'usda', '169640', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'حلويات ومحليات', 0.2, '{"iron": 0.42, "zinc": 0.22, "vit_a": 0, "vit_c": 0.5, "vit_d": 0, "vit_e": 0, "vit_k": 0, "folate": 2, "vit_b6": 0.024, "calcium": 6, "vit_b12": 0, "magnesium": 2, "potassium": 52}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('1ac1a724-313c-45f6-a441-89c0749fa8a1', 'سكر أبيض', 'Sugars, granulated', 'حلويات ومشروبات', 387.0, 0.0, 100.0, 0.0, 4.0, 'ملعقة صغيرة', 'usda', '169655', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'حلويات ومحليات', 0.0, '{"iron": 0.05, "zinc": 0.01, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0, "vit_k": 0, "folate": 0, "vit_b6": 0, "calcium": 1, "vit_b12": 0, "magnesium": 0, "potassium": 2}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('927d0016-eb28-48aa-be80-f764b64e9035', 'شوكولاتة داكنة 70-85%', 'Chocolate, dark, 70-85% cacao solids', 'حلويات ومشروبات', 598.0, 7.8, 45.9, 42.6, 20.0, NULL, 'usda', '170273', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'حلويات ومحليات', 10.9, '{"iron": 11.9, "zinc": 3.31, "vit_a": 2, "vit_e": 0.59, "vit_k": 7.3, "vit_b6": 0.038, "calcium": 73, "vit_b12": 0.28, "magnesium": 228, "potassium": 715}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('70fe15cf-2344-46c2-a5d9-143226691a92', 'عصير برتقال', 'Orange juice, raw (Includes foods for USDA''s Food Distribution Program)', 'حلويات ومشروبات', 45.0, 0.7, 10.4, 0.2, 248.0, 'كوب', 'usda', '169098', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'مشروبات', 0.2, '{"iron": 0.2, "zinc": 0.05, "vit_a": 10, "vit_c": 50, "vit_d": 0, "vit_e": 0.04, "vit_k": 0.1, "folate": 30, "vit_b6": 0.04, "calcium": 11, "vit_b12": 0, "magnesium": 11, "potassium": 200}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('243cf437-b0ad-4c35-9af8-80f70ece0516', 'مايونيز', 'Salad dressing, mayonnaise, regular', 'صوصات', 680.0, 1.0, 0.6, 74.9, 15.0, 'ملعقة كبيرة', 'usda', '171009', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'دهون وزيوت', 0.0, '{"iron": 0.21, "zinc": 0.15, "vit_a": 16, "vit_c": 0, "vit_d": 0.2, "vit_e": 3.28, "vit_k": 163, "folate": 5, "vit_b6": 0.008, "calcium": 8, "vit_b12": 0.12, "magnesium": 1, "potassium": 20}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ea7f3afe-a28d-4e7d-8ebc-c1d7d6370617', 'كاتشب', 'Catsup', 'صوصات', 101.0, 1.0, 27.4, 0.1, 17.0, 'ملعقة كبيرة', 'usda', '168556', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'صلصات', 0.3, '{"iron": 0.35, "zinc": 0.17, "vit_a": 26, "vit_c": 4.1, "vit_d": 0, "vit_e": 1.46, "vit_k": 3, "folate": 9, "vit_b6": 0.158, "calcium": 15, "vit_b12": 0, "magnesium": 13, "potassium": 281}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d58d2325-eb2f-47db-a527-e913bb2403c9', 'حليب بروتين قهوة (ندى 320 مل)', 'Nada Protein Milk Coffee 320ml', 'مشروبات بروتينية', 87.0, 9.5, 10.0, 0.1, 320.0, 'عبوة 320 مل', 'coach', 'nada.com.sa/protein-milk-320ml-coffee', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f3d31f4b-10b3-42f6-a5c4-9150d9d46252', 'حليب بروتين شوكولاتة (ندى 320 مل)', 'Nada Protein Chocolate Milk 320ml', 'مشروبات بروتينية', 84.0, 8.5, 12.5, 0.1, 320.0, 'عبوة 320 مل', 'coach', 'nada.com.sa/protein-chocolate-milk', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f423c03e-635d-4e52-93e7-b6cf3d8df568', 'حليب بروتين تمر (ندى 320 مل)', 'Nada Protein Dates Milk 320ml', 'مشروبات بروتينية', 108.0, 8.5, 15.0, 1.5, 320.0, 'عبوة 320 مل', 'coach', 'nada.com.sa/protein-dates-milk', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('5c857daf-a41f-4065-bbf0-ca21eeacce18', 'باور ميلك قهوة (ندى 425 مل)', 'Nada Power Milk Coffee 425ml', 'مشروبات بروتينية', 87.0, 9.5, 10.0, 0.1, 425.0, 'عبوة 425 مل', 'coach', 'nada.com.sa/power-milk-425ml-coffee', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('1ac4a5df-da30-4c43-a57b-b73c66b63fba', 'باور ميلك شوكولاتة (ندى)', 'Nada Power Milk Chocolate', 'مشروبات بروتينية', 87.0, 9.5, 12.5, 0.1, NULL, NULL, 'coach', 'nada.com.sa/power-milk-chocolate', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('6c01c6cd-e92a-4d3e-b804-971873d50ade', 'باور ميلك فانيلا (ندى)', 'Nada Power Milk Vanilla', 'مشروبات بروتينية', 87.0, 9.5, 12.5, 0.1, NULL, NULL, 'coach', 'nada.com.sa/power-milk-vanilla-mixed-fru', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('6a77ddc8-2472-4e3c-9218-5e6320ca317c', 'حليب بروتين شوكولاتة (المراعي 400 مل)', 'Almarai Protein Milk Chocolate 400ml', 'مشروبات بروتينية', 73.0, 8.5, 9.6, 0.4, 400.0, 'عبوة 400 مل', 'coach', 'almarai.com/protein-milk-chocolate', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('6f4b34c1-cb85-4249-a54e-cd7bb11c8172', 'حليب بروتين فراولة وموز (المراعي 400 مل)', 'Almarai Protein Milk Strawberry Banana 400ml', 'مشروبات بروتينية', 71.0, 8.5, 9.2, 0.3, 400.0, 'عبوة 400 مل', 'coach', 'almarai.com/protein-milk-strawberry-bana', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('fd93fcdb-f34c-4fd9-ba1f-5249d8ba21c1', 'حليب بروتين فانيلا (المراعي 400 مل)', 'Almarai Protein Milk Vanilla 400ml', 'مشروبات بروتينية', 72.0, 8.5, 9.4, 0.3, 400.0, 'عبوة 400 مل', 'coach', 'almarai.com/protein-milk-vanilla', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('949d8e08-2348-492d-b41d-5a8d0c6b95c3', 'ماسل ميلك شوكولاتة (المراعي 400 مل)', 'Almarai Muscle Milk Chocolate 400ml', 'مشروبات بروتينية', 68.0, 10.0, 6.1, 0.3, 400.0, 'عبوة 400 مل', 'coach', 'almarai.com/muscle-milk-chocolate', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('e8d26cf2-2e93-4bb0-bddf-65c8169a2070', 'ماسل ميلك سادة (المراعي 400 مل)', 'Almarai Muscle Milk Plain 400ml', 'مشروبات بروتينية', 58.0, 10.0, 3.8, 0.2, 400.0, 'عبوة 400 مل', 'coach', 'almarai.com/muscle-milk-plain', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('428917f0-7c84-4aa8-9ec7-82c8cfdb1e11', 'زبادي يوناني كامل الدسم فراولة (ندى 160 غ)', 'Nada Greek Yoghurt Full Fat Strawberry 160g', 'زبادي يوناني', 147.0, 7.0, 14.0, 7.0, 160.0, 'عبوة 160 غ', 'coach', 'nada.com.sa/greek-yoghurt-full-fat-straw', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('87e3d178-bf65-4fdd-b4e3-12b554ba1e82', 'زبادي يوناني كامل الدسم توت أزرق (ندى)', 'Nada Greek Yoghurt Blueberry Full Cream', 'زبادي يوناني', 147.0, 7.0, 14.0, 7.0, NULL, NULL, 'coach', 'nada.com.sa/greek-yoghurt-with-blueberry', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('c9d987fe-f343-48e3-9c1c-b4cabff5607e', 'زبادي يوناني ليمون ونعناع (ندى)', 'Nada Greek Yoghurt Lemon Mint', 'زبادي يوناني', 137.0, 7.0, 11.5, 7.0, NULL, NULL, 'coach', 'nada.com.sa/greek-yoghurt-with-lemon-min', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f435ed3a-d5d7-47d7-80df-17b4fa9ed204', 'زبادي يوناني توت مشكل كامل الدسم (ندى)', 'Nada Greek Yoghurt Mixed Berry Full Cream', 'زبادي يوناني', 148.0, 7.0, 14.3, 7.0, NULL, NULL, 'coach', 'nada.com.sa/greek-yoghurt-with-mixed-ber', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('437784b9-90ee-4337-a6d3-6472df050803', 'زبادي يوناني سادة (ندى 160)', 'Nada Greek Yoghurt Plain', 'زبادي يوناني', 111.0, 7.0, 5.0, 7.0, 160.0, 'عبوة 160 مل', 'coach', 'nada.com.sa/greek-yoghurt-plain', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('44f10876-66a7-40e6-9c00-b29577b53b47', 'زبادي يوناني 0% دهون سادة (ندى 160)', 'Nada Greek Yoghurt 0% Fat Plain', 'زبادي يوناني', 63.0, 10.0, 5.0, 0.3, 160.0, 'عبوة 160 مل', 'coach', 'nada.com.sa/greek-yoghurt-0-fat-plain', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a53f33ee-afd9-4671-b73f-66a2cdab5944', 'زبادي يوناني قليل الدسم سادة (ندى 160)', 'Nada Greek Yoghurt Low Fat Plain', 'زبادي يوناني', 66.0, 7.0, 5.0, 2.0, 160.0, 'عبوة 160 مل', 'coach', 'nada.com.sa/greek-yoghurt-low-fat-plain', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('c031b5e4-a275-453f-a4a6-4679723d18c1', 'زبادي يوناني بالعسل الطبيعي (ندى 160)', 'Nada Greek Yoghurt Natural Honey', 'زبادي يوناني', 141.0, 7.0, 12.5, 7.0, 160.0, 'عبوة 160 مل', 'coach', 'nada.com.sa/greek-yoghurt-natural-honey', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('1e1809b6-d17b-47ca-9408-c02169b5404f', 'زبادي يوناني توت أسود وتوت العليق (ندى 160)', 'Nada Greek Yoghurt Blackberry Raspberry', 'زبادي يوناني', 151.0, 7.0, 15.0, 7.0, 160.0, 'عبوة 160 مل', 'coach', 'nada.com.sa/greek-yoghurt-berry', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b208b465-8c26-411f-a069-5f5ed9ef528a', 'زبادي يوناني 0% دهون توت مشكل (ندى 160)', 'Nada Greek Yoghurt 0% Fat Mixed Berry', 'زبادي يوناني', 100.0, 10.0, 14.3, 0.3, 160.0, 'عبوة 160 مل', 'coach', 'nada.com.sa/greek-yoghurt-0-fat-mixed-be', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('eb45b4bd-f426-4fa4-98de-bf3fc267d6b0', 'زبادي يوناني قليل الدسم توت أزرق (ندى 160)', 'Nada Greek Yoghurt Low Fat Blueberry', 'زبادي يوناني', 102.0, 7.0, 14.0, 2.0, 160.0, 'عبوة 160 مل', 'coach', 'nada.com.sa/greek-yoghurt-low-fat-bluebe', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('c2838ab6-1dba-4778-8fa3-03964e3fd83e', 'زبادي يوناني 0% دهون مانجو وخوخ (ندى 160)', 'Nada Greek Yoghurt 0% Fat Mango Peach', 'زبادي يوناني', 111.0, 10.0, 17.0, 0.3, 160.0, 'عبوة 160 مل', 'coach', 'nada.com.sa/greek-yoghurt-0-fat-mango-pe', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f28a9d03-83c2-440b-8d4f-49785b7f3f3b', 'زبادي يوناني قليل الدسم فراولة (ندى 160)', 'Nada Greek Yoghurt Low Fat Strawberry', 'زبادي يوناني', 98.0, 6.0, 14.0, 2.0, 160.0, 'عبوة 160 مل', 'coach', 'nada.com.sa/greek-yoghurt-low-fat-strawb', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('2ca4ddca-90cb-4126-a36a-1349a4ee166d', 'لبن زبادي طازج قليل الدسم (ندى 150 غ)', 'Nada Fresh Yoghurt Low Fat', 'زبادي يوناني', 45.0, 3.1, 5.5, 1.2, 150.0, 'عبوة 150 غ', 'coach', 'nada.com.sa/fresh-yoghurt-low-fat', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('fd6327d5-8d60-4deb-aa99-74ba1c126746', 'زبادي يوناني للشرب سادة (ندى 330 مل)', 'Nada Drinking Greek Yoghurt Plain', 'زبادي يوناني', 68.0, 9.1, 4.5, 1.5, 330.0, 'عبوة 330 مل', 'coach', 'nada.com.sa/drinking-greek-yoghurt-plain', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('bd00651b-96b4-44fd-8f8b-b4f6639b8c7d', 'زبادي يوناني للشرب توت أسود وتوت العليق (ندى 330 مل)', 'Nada Drinking Greek Yoghurt Blackberry Raspberry', 'زبادي يوناني', 97.0, 8.2, 12.7, 1.5, 330.0, 'عبوة 330 مل', 'coach', 'nada.com.sa/drinking-greek-yoghurt-berry', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('0eb43e90-b31b-4772-a97d-b35c867b9ab6', 'زبادي يوناني للشرب مانجو (ندى 330 مل)', 'Nada Drinking Greek Yoghurt Mango', 'زبادي يوناني', 94.0, 8.2, 11.9, 1.5, 330.0, 'عبوة 330 مل', 'coach', 'nada.com.sa/drinking-greek-yoghurt-mango', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('28a71980-12c7-4340-8977-339dfc688b16', 'زبادي يوناني للشرب باشن فروت وبذور الشيا (ندى 330 مل)', 'Nada Drinking Greek Yoghurt Passion Chia', 'زبادي يوناني', 101.0, 8.2, 13.6, 1.5, 330.0, 'عبوة 330 مل', 'coach', 'nada.com.sa/drinking-greek-yoghurt-passi', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('8fa7eba8-e161-49c3-9bce-81a9426bdf15', 'زبادي يوناني للشرب فراولة وحبوب (ندى 330 مل)', 'Nada Drinking Greek Yoghurt Strawberry Cereal', 'زبادي يوناني', 94.0, 8.2, 11.9, 1.5, 330.0, 'عبوة 330 مل', 'coach', 'nada.com.sa/drinking-greek-yoghurt-straw', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('7bf2e5f5-bd27-4444-84be-581304577236', 'زبادي يوناني سادة (المراعي 150 غ)', 'Almarai Plain Greek Style Yoghurt 150g', 'زبادي يوناني', 139.0, 6.7, 8.7, 8.7, 150.0, 'عبوة 150 غ', 'coach', 'almarai.com/plain-greek-style-yoghurt', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b4fd008f-de0e-4d1d-b327-b24e9067a508', 'زبادي يوناني فراولة (المراعي 150 غ)', 'Almarai Strawberry Greek Style Yoghurt 150g', 'زبادي يوناني', 150.0, 6.0, 15.3, 7.3, 150.0, 'عبوة 150 غ', 'coach', 'almarai.com/strawberry-greek-style-yoghu', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b5e2e8fe-cf30-4b3f-97d4-047d6f6d71cc', 'زبادي يوناني مانجو (المراعي 150 غ)', 'Almarai Mango Greek Style Yoghurt 150g', 'زبادي يوناني', 150.0, 5.9, 15.3, 7.2, 150.0, 'عبوة 150 غ', 'coach', 'almarai.com/mango-greek-style-yoghurt', true, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;



INSERT INTO public.policies VALUES ('terms', 'الشروط والأحكام', '- يبدأ الاشتراك بعد التحقق من وصول التحويل البنكي، وتعبئة استبيان المتدرب.
- ساعات العمل: الأحد – الخميس، 12 ظهراً – 9 مساءً. الرد على الرسائل خلال 48 ساعة عمل.
- البرنامج لا يغني عن الاستشارة الطبية، والمتدرب مسؤول عن الإفصاح عن أي إصابة أو حالة صحية.
- الجداول ملك المتدرب مدى الحياة ويمكنه التعديل عليها.
- الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي.', 0, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;
INSERT INTO public.policies VALUES ('refund', 'الضمان والاسترجاع', '- في اشتراكات 3 أشهر لباقات المتابعة (المكثفة، المتقدمة، الأساسية): يُسترد المبلغ كاملاً إذا لم يتحسن أي من مؤشرات التقدم (متوسط الوزن الأسبوعي، محيط الخصر، القوة في التمارين الأساسية) بعد 12 أسبوعاً.
- شروط الضمان: إرسال المراجعة الأسبوعية كل أسبوع، وأخذ القياسات بانتظام، وتصوير التمارين وإرسالها، والالتزام بجدول التغذية المخصص في الباقات التي تشملها.
- يُطلب الاسترجاع عبر واتساب خلال 14 يوماً من نهاية الأشهر الثلاثة، ويُرجع المبلغ بتحويل بنكي.
- التجديد المجاني: اشتراك 3 أشهر يُكافأ بـ 3 أشهر إضافية عند التزام 90% فأكثر وتقدم واضح في مؤشرات التقدم. صور التطور تُرسل للمدربة للتوثيق (للرجال مع تغطية الوجه والسرة)، ونشرها اختياري.', 1, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;
INSERT INTO public.policies VALUES ('privacy', 'سياسة الخصوصية', '- نجمع: الاسم، البريد الإلكتروني (للدخول إلى حسابك)، رقم الجوال (واتساب)، الباقة المختارة، ومعلومات الاستبيان التي تكتبها بنفسك (ومنها معلومات صحية وقياسات اختيارية).
- الغرض: تنفيذ طلبك، وتصميم برنامجك ومتابعتك، والتواصل معك بخصوصه فقط.
- المعلومات الصحية تُحفظ منفصلة، ولا يطّلع عليها إلا أنت والمدربة، ولا تُرسل في رسائل البريد أو التنبيهات.
- الدفع بتحويل بنكي مباشر لحساب المؤسسة، والموقع لا يطلب أو يخزن أي بيانات بنكية أو بيانات بطاقات. إيصال التحويل يُستخدم لتأكيد طلبك فقط، ويُحفظ في تخزين خاص لا يُفتح إلا لك وللمدربة.
- لا نبيع بياناتك ولا نشاركها مع أي طرف لأغراض تسويقية، ولا تُنشر نتيجتك أو صورتك إلا بموافقتك الصريحة.
- تقدر تطلب نسخة من بياناتك أو حذفها أو سحب موافقتك على النشر بمراسلتنا على واتساب.
- القياس والتحليلات: نستخدم Google Analytics لقياس زيارات صفحات الموقع العامة وتحسين تجربتك، وذلك فقط بعد موافقتك على الشريط الذي يظهر عند أول زيارة، وتقدر ترفض فلا نقيس زيارتك. لا نفعّل القياس داخل حسابك أو صفحات الطلب والدفع والبرامج، ولا نربطه ببياناتك الصحية أو الشخصية، ولا نستخدمه للإعلانات. تُعالَج بيانات القياس لدى Google، وهي مجهولة الهوية في غالبها (عنوان IP يُقنَّع، وبدون ميزات الإعلانات المخصصة). تقدر تسحب موافقتك بمسح بيانات الموقع من متصفحك، فيظهر لك الشريط مرة ثانية.', 2, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;
INSERT INTO public.policies VALUES ('reviews', 'سياسة التقييمات', '- يكتب التقييم فقط من اشترى خدمة وبدأها فعلاً، وتقييم واحد لكل طلب.
- كل تقييم يُراجع قبل ظهوره للعامة، ولا يُعدّل نصه أبداً.
- تختار بنفسك طريقة ظهور اسمك: الاسم كامل، أو الاسم الأول فقط، أو بدون اسم. والموافقة على النشر منفصلة واختيارية.
- لا يُنشر تقييم يحتوي أرقام هواتف أو بريد أو روابط أو تفاصيل صحية خاصة أو إساءة لأي شخص.
- يحق للمدربة الرد على التقييم، أو إخفاء التقييم المخالف لهذه السياسة مع تسجيل السبب.
- تقدر تطلب إخفاء تقييمك في أي وقت بمراسلتنا على واتساب.', 3, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;



INSERT INTO public.products VALUES ('82a66386-a940-476a-a905-14ea0b95ed2a', 'intensive', 'follow', 'الباقة المكثفة', 'الأنسب للمبتدئين ولمن يحتاج متابعة أسبوعية مع زوم: تمرين + تغذية + زوم + جلسة حضورية', '[{"text": "جلسة حضورية مجانية لمدة ساعة لتصحيح التكنيك والتأكد من جودة التمرين (للبنات في المنطقة الشرقية)", "included": true}, {"text": "ملف شامل للخطة التدريبية والتغذية مع شروحات وافية للتمارين، بالمنزل أو بالنادي", "included": true}, {"text": "4 مكالمات زوم شهرياً نتابع فيها تطورك واستفساراتك الرياضية والنفسية", "included": true}, {"text": "مناقشة أسبوعية لتطورك البدني والنفسي (فيديو أو تسجيل صوتي) مع تعديل السعرات أو التمرين عند الحاجة", "included": true}, {"text": "شرح سهل ومبسط لتطبيق حساب السعرات MyFitnessPal", "included": true}, {"text": "كتيب شامل للرياضة والتغذية", "included": true}, {"text": "مساعدتك على اختيارات أنسب لصحتك ونمط حياتك في التغذية والروتين اليومي", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}]', NULL, 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.', true, NULL, 'published', 0, false, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', false, NULL, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('62240cee-c1e7-4bc3-b1b5-0342fa6b11b2', 'advanced', 'follow', 'الباقة المتقدمة', 'لمن عنده خبرة ويحتاج تمرين + تغذية مع متابعة أسبوعية، بدون زوم', '[{"text": "ملف شامل للخطة التدريبية والتغذية مع شروحات وافية للتمارين، بالمنزل أو بالنادي", "included": true}, {"text": "مناقشة أسبوعية لتطورك البدني والنفسي (فيديو أو تسجيل صوتي) مع تعديل السعرات أو التمرين عند الحاجة", "included": true}, {"text": "كتيب شامل للرياضة والتغذية", "included": true}, {"text": "مساعدتك على اختيارات أنسب لصحتك ونمط حياتك في التمرين والروتين اليومي", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}, {"text": "مكالمات زوم والجلسة الحضورية (في المكثفة فقط)", "included": false}]', NULL, 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.', false, NULL, 'published', 1, false, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', false, NULL, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('c04efd46-c393-4e0f-93cc-76d7bce1c3a8', 'basic', 'follow', 'الباقة الأساسية', 'لمن يعرف يضبط أكله ويحتاج خطة تمرين فقط، ومتابعة كل أسبوعين', '[{"text": "ملف شامل للخطة التدريبية مع شروحات وافية للتمارين، بالمنزل أو بالنادي", "included": true}, {"text": "مناقشة كل أسبوعين لتطورك البدني والنفسي (فيديو أو تسجيل صوتي) مع تعديل التمرين عند الحاجة", "included": true}, {"text": "كتيب شامل للرياضة والتغذية", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}, {"text": "بدون خطة تغذية", "included": false}]', NULL, 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.', false, NULL, 'published', 2, false, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', false, NULL, 2) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('08721db0-2d50-43de-83d0-31f2def239b8', 'nutrition', 'follow', 'باقة التغذية', 'لمن يحتاج خطة تغذية شاملة ويتعلم حساب السعرات، بدون خطة تمرين', '[{"text": "خطة تغذية شاملة تناسب هدفك ونمط حياتك", "included": true}, {"text": "تحديد السعرات المناسبة لك ولهدفك", "included": true}, {"text": "تعليمك حسبة السعرات ومساعدتك باختيارات تغذية تناسبك", "included": true}, {"text": "ملف Excel لمتابعة التطور والقياسات", "included": true}, {"text": "مناقشة أسبوعية لعلاقتك بالتغذية في المنزل أو خارجه", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}, {"text": "لا تحتاجها إذا كنت مشتركاً في المكثفة أو المتقدمة، لأن التغذية ضمنها", "included": false}]', 'شهر واحد · غالباً لا تحتاج تجديد', 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي، ولا يوجد تجديد تلقائي. ضمان الاسترجاع يشمل اشتراكات 3 أشهر للمكثفة والمتقدمة والأساسية فقط.', false, NULL, 'published', 3, false, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', false, NULL, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('45537fb1-ffbc-420e-a891-2538697b0c72', 'custom-training-plan', 'files', 'بديل التدريب الشخصي', 'لمن لا يحتاج متابعة (متقدم)، أو كبديل أوفر للتدريب الشخصي', '[{"text": "جدول تمرين مخصص لعدد أيام التمرين اللي تحتاجها", "included": true}, {"text": "طريقة حساب الجهد وعدد الجولات المطلوبة", "included": true}, {"text": "تقدر تحمّل الجدول على جهازك", "included": true}]', NULL, 'جدول مخصص بعد الاستبيان تستلمه كملف، وتقدر تحمّله على جهازك. بدون متابعة.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي. الجداول لك مدى الحياة وتقدر تعدّل عليها.', false, NULL, 'published', 4, false, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', false, NULL, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('ce690e4d-6d7b-4ef0-b79b-f1eb27811414', 'training-nutrition-plan', 'files', 'جدول تمارين مع التغذية', 'لمن لا يحتاج متابعة (متقدم)، أو كبديل أوفر للتدريب الشخصي', '[{"text": "جدول تمرين مخصص لعدد أيام التمرين اللي تحتاجها", "included": true}, {"text": "طريقة حساب الجهد وعدد الجولات المطلوبة", "included": true}, {"text": "جدول تغذية فيه خيارات تناسب هدفك الرياضي", "included": true}, {"text": "تقدر تحمّل الجدول على جهازك", "included": true}]', NULL, 'جدول مخصص بعد الاستبيان تستلمه كملف، وتقدر تحمّله على جهازك. بدون متابعة.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي. الجداول لك مدى الحياة وتقدر تعدّل عليها.', false, NULL, 'published', 5, false, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', false, NULL, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('e06c8f93-6e82-47d0-ba03-b655757b1338', 'nutrition-consultation', 'consult', 'جلسة استشارة تغذية', 'لمن عنده أسئلة محددة في التغذية: جلسة وحدة تكفي لحسبة سعراتك ونصائح الأكل.', '[{"text": "مناقشة كل أسئلتك في مجال التغذية", "included": true}, {"text": "حسبة سعرات مناسبة لهدفك مع اقتراحات لأصناف الطعام", "included": true}, {"text": "نصائح في المكملات، وكيف تأكل برّا بطريقة صحيحة", "included": true}]', NULL, 'جلسة عبر Google Meet أو واتساب — المناسب لك.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي.', false, NULL, 'published', 6, false, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', false, NULL, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('c23ba79d-dbf8-4887-9b7e-515419b780f4', 'training-consultation', 'consult', 'جلسة استشارة تمرين', 'لمن عنده أسئلة محددة في التمرين: جلسة وحدة تكفي لتعديل جدولك وتصحيح التكنيك.', '[{"text": "مناقشة كل أسئلتك في مجال التمرين", "included": true}, {"text": "تعديل جدولك الرياضي بما يناسب هدفك، مع اقتراحات لتمارين المرونة", "included": true}, {"text": "تصحيح تكنيك التمارين اللي تشك إنها غلط أو تسبب لك ألم", "included": true}, {"text": "التأكد من أن جودة تمرينك مناسبة للبناء العضلي", "included": true}]', NULL, 'جلسة عبر Google Meet أو واتساب — المناسب لك.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي.', false, NULL, 'published', 7, false, '2026-10-09 21:11:33.273715+00', '2026-10-09 21:11:33.273715+00', false, NULL, 1) ON CONFLICT DO NOTHING;



INSERT INTO public.product_offers VALUES ('8a8bc4ba-d038-42eb-879f-49637e93ae24', '82a66386-a940-476a-a905-14ea0b95ed2a', 'int1', 'شهر واحد', 1, 59900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('983ba4e5-1838-4ca1-afad-19291f0d29e1', '82a66386-a940-476a-a905-14ea0b95ed2a', 'int3', '3 أشهر', 3, 155000, 'SAR', true, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('f2058696-b6fb-4759-a7cf-22424de2cdb9', '62240cee-c1e7-4bc3-b1b5-0342fa6b11b2', 'adv1', 'شهر واحد', 1, 49900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('76c0708d-2c71-411c-bce6-63f75746c74d', '62240cee-c1e7-4bc3-b1b5-0342fa6b11b2', 'adv3', '3 أشهر', 3, 125000, 'SAR', true, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('e7bb2a47-30f2-455b-9518-825646855e94', 'c04efd46-c393-4e0f-93cc-76d7bce1c3a8', 'bas1', 'شهر واحد', 1, 34900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('e85eb9eb-c999-4652-84b1-9e6e5e8fac3e', 'c04efd46-c393-4e0f-93cc-76d7bce1c3a8', 'bas3', '3 أشهر', 3, 95000, 'SAR', true, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('24512e72-24a5-4aa8-b2c0-9e59cd5bf69b', '08721db0-2d50-43de-83d0-31f2def239b8', 'nut1', 'شهر واحد', 1, 25000, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('52839e88-e2ed-4f21-b8cc-2f28f880bcc6', '45537fb1-ffbc-420e-a891-2538697b0c72', 'diy', 'دفعة واحدة', 0, 19900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('05adb725-884a-4616-8762-90dd1009d891', 'ce690e4d-6d7b-4ef0-b79b-f1eb27811414', 'diyN', 'دفعة واحدة', 0, 25000, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('ccb8c69e-ecd1-42e4-8c1b-d97fcb10a55a', 'e06c8f93-6e82-47d0-ba03-b655757b1338', 'cN', 'دفعة واحدة', 0, 15000, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('80931f4b-d226-4cd6-a60f-e85847dbf21e', 'c23ba79d-dbf8-4887-9b7e-515419b780f4', 'cT', 'دفعة واحدة', 0, 18900, 'SAR', true, 0) ON CONFLICT DO NOTHING;



INSERT INTO public.reviews VALUES ('6a236d0a-f141-45e0-89f9-c876777f2a5a', 'legacy', NULL, NULL, NULL, NULL, 'اشتركت معها 3 شهور وكانت أول مره التزم بالتمرين بعد سحبات سنين، اسلوبها سهل وسريع بس نتايجه واضحه من اول اسبوعين قياسات جسمي بدت تتغير والكوتش مريحه نفسيًا وشاطرة الله يعطيها العافيه غيرت حياتي واعطتني افضل بداية 🙏🏻', 'first', 'ريم', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 0, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('7c0fe322-4cd1-4ee8-97f4-bf627c511028', 'legacy', NULL, NULL, NULL, 5, 'من أصدق التجارب اللي مرّيت فيها! تدريبك ما كان بس جداول رياضه وتغذية كان دعم نفسي وتحفيز وتغيير حقيقي في حياتي حسّيت بفرق كبير في جسمي وطاقتي وثقتي بنفسي من أول أسبوع شكراً من القلب على تعبك وحرصك على كل تفصيلة وتعطي من قلبك، فعلاً you are the best coach ever تستاهلين كل النجاح والله ❤️', 'first', 'نورة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 1, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('80d6ca88-e9d5-40bc-91ec-cf3a647a6063', 'legacy', NULL, NULL, NULL, 5, 'بعد شهر من الالتزام بالجدول، لاحظت فرق واضح! متنوع وفعال، أنصح فيه بشدة 😍👌', 'first', 'البندري', 'مارس 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 2, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('dd03dcb2-2a76-47af-ae4d-029b6e812644', 'legacy', NULL, NULL, NULL, NULL, 'رغم ان فتره تدريبي معاها كانت اقل من شهرين السنه الماضيه الا ان نتايج هالشهرين مستمره معي الى اليوم 😍 اسلوب احترافي وفعال وتركز على بناء وتطوير عادات تدوم مو بس تمارين مؤقته 👍🏻', 'first', 'خديجة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 3, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('76c48274-607f-4945-853c-925ab4739a48', 'legacy', NULL, NULL, NULL, 5, 'كوتش ساره جداً شاطره و بروفيشنال، جداً متعاونه و تعرف شغلها كويس، جداً لطيفه، كنت لفتره متدربه عندها و كنت أشوف نتايج بطله بالاضافه لكوني اروح اتمرن و أنا مستمتعه، شكراً ساره', 'first', 'نجمة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 4, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('71483a6c-9452-4d9a-8114-50bd02ff5b2d', 'legacy', NULL, NULL, NULL, 5, 'ممتاز جدول حلو ومرتب جدا وفرق معي كثير 🤍', 'first', 'سعود', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 5, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('edefdc9f-0dcd-4864-bc66-9329ac1f3afc', 'legacy', NULL, NULL, NULL, 5, 'كنت اعاني من الم بظهري مستمررر سنوات وانحراف بالعمود ولكن بفضل الله ثم المدربة تحسنت بنسبة كبيرة وتابع معي خطوة بخطوة بكل أمانة وإتقان الله يكثر من امثالك 🤍', 'first', 'ش**س**', 'أغسطس 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 6, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('ada9de1c-a4a4-4eff-ac1e-8c1f75b25674', 'legacy', NULL, NULL, NULL, 5, 'الشكر يعجز عنك يااروع كوتش باشتراكي معك شفت صحة وراحة بعد الله وساعدتيني مره بمشكلة ظهري وضعف العضلات العلوية وانعكس على نفسيتي وادائي اليومي شكررا شكرا من القلب وياحظنا فيك', 'first', 'فاطمة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 7, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('aee5685e-8d7c-4041-8c11-6f6267928c24', 'legacy', NULL, NULL, NULL, 5, 'مره استفدت بالتدريب مع كوتش ناف و مبسوطه ان في احد بذمة و ضمير جالس يتابع تقدمي و ينصحني من قلب الله يسعدك ويوفقك ❤️', 'first', 'ميثاء', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 8, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('2726630d-5013-40e3-8e3d-ad4bbc51de83', 'legacy', NULL, NULL, NULL, 5, 'تجربه ولا أروع ! أحب جداولها وقد ايش تختصر وتعطيك المهم والاهم والنتايج رهيييبه ❤️', 'first', 'أمجاد', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 9, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('0ff56f4d-6a65-43a3-9ea6-fc910fa39369', 'legacy', NULL, NULL, NULL, 5, 'افضل مدربة بالمجرة، كنت دبه ونحفت بثلاث شهور بس، i highly recommend her she is the best 💗', 'first', 'شروق', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 10, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('72e68673-7d96-4039-9941-e7b7ef0363c3', 'legacy', NULL, NULL, NULL, 5, 'الجدول ممتاز و فعّال لفترة الصيام، يساعدك تنظم وقتك ويقدّم توصيات غذائيه و خطه تمارين تساعدك تحافظ على لياقتك بدون إرهاق 👍🏻. خيار ممتاز خاصة للأشخاص للي وقتها محدود ومزحوم فرمضان.', 'first', 'خديجة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 11, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;



INSERT INTO public.site_settings VALUES ('reminders', '{"review_text": "مرحباً {name}، تذكير بمراجعتك الأسبوعية: المراجعة مفتوحة من {window_start} إلى {window_end}.", "sub_expiry_days": [7, 3], "sub_expiry_text": "مرحباً {name}، اشتراكك في {product} ينتهي بتاريخ {end_date}. للتجديد أو الاستفسار تواصل معنا.", "review_lead_days": 1, "missed_review_text": "مرحباً {name}، ما وصلتنا مراجعة الأسبوع المنتهي في {window_end}. متى ما تيسّر لك، حدّثها عشان نتابع تقدمك.", "review_window_days": 2, "manual_cooldown_minutes": 10}', false, NULL, '2026-10-09 21:11:29.839676+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('hero', '{"lead": "خطة تدريب وغذاء منظمة، متابعة للتقدم، وتعديلات أسبوعية تناسب مستواك وظروفك.", "title": "برامج تدريب وتغذية مخصصة لأهدافك", "eyebrow": "Nav Coaching · الكوتش ساره", "tagline": "Where Passion Meets Quality", "title_tail": "تحت إشراف مدربة يدفعها الشغف"}', true, NULL, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('badges', '["خصم 10% للطلاب", "مجاني لأهل غزة", "ضمان استرجاع المبلغ بشروط"]', true, NULL, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('why', '[{"body": "البرنامج يُصمم بعد استبيان مفصل لهدفك وأيامك المتاحة وأدواتك وأي إصابة تحتاج مراعاة.", "title": "مبني على هدفك ومستواك"}, {"body": "مراجعة منتظمة بالفيديو أو الصوت، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.", "title": "متابعة أسبوعية واضحة"}, {"body": "نعدّل التمرين والسعرات بناءً على قياساتك والتزامك، عشان تثبت النتيجة.", "title": "تعديلات حسب تقدمك"}]', true, NULL, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('how_steps', '[{"body": "اختر الباقة والمدة، وعبّي استبيان قصير عن هدفك ومستواك وأيامك وأي إصابة.", "title": "اختر برنامجك وعبّي الاستبيان"}, {"body": "بعد الاستبيان يظهر لك رقم طلبك وبيانات الحساب. حوّل وارفع صورة الإيصال من صفحة طلبك.", "title": "حوّل المبلغ"}, {"body": "بعد التحقق من التحويل أتواصل معك خلال 48 ساعة عمل، وتستلم ملف برنامجك وتبدأ المتابعة.", "title": "استلم برنامجك وابدأ"}]', true, NULL, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('about', '{"bio": "مدربة شخصية معتمدة، أدرب منذ 2017. أساعدك تبني روتين تدريب وتغذية واضح يناسب هدفك ووقتك ومستواك، مع متابعة أسبوعية تساعدك تستمر وتتقدم.", "fit": ["اللي يؤمن إن التمرين أسلوب حياة، مو تمرين لشكل مؤقت أو لفترة الصيف بس.", "**وإذا ما التزمت؟** أحاول أفهم أسبابك، وأساعدك تعالجها بقدر ما أقدر. وإذا كان الموضوع أكبر من اللي أقدر أقدمه، أقول لك بصراحة وأعتذر عن تدريبك."], "name": "الكوتش ساره | ناڤ", "certs": ["Saudi Reps — Level 4", "NCSF", "Menno Henselmans CPT", "Functional Mobility", "Pre & Postnatal Training", "Prenatal Fitness Training — Aspire Academy", "ماجستير تدريب رياضي — جامعة ستيرلنق"], "notes": [{"body": "لأني جاية من عالم الرياضات الإلكترونية، صممت باقة خاصة للقيمرز: لياقة أفضل داخل وخارج الشاشة، والتعامل مع آلام الظهر والمفاصل من الجلوس الطويل.", "href": "/programs/gamers", "label": "شوف باقة القيمرز ←", "title": "للاعبي الألعاب الإلكترونية"}, {"body": "تدريب الحوامل عندي حضوري فقط. أونلاين يصعب أتأكد إن التمرين يتنفذ بإتقان، والحمل فترة مهمة جداً تحتاج هالتأكد. أونلاين أقدم للحوامل متابعة التغذية فقط.", "href": "", "label": "", "title": "للحوامل"}], "story": ["قبل ما أصير مدربة، كنت متدربة تعبت من التجارب. اشتركت مع مدربات أجانب، وما لقيت أحد يشرح لي التمرين صح أو يهتم بأهدافي.", "لين اشتركت مع الكوتش سحر الحارثي. غيّرت نظرتي للتمرين، وحفّزتني أصير كوتش، وإلى اليوم أشكرها على كل اللي علمتني إياه. من هنا قررت أكون الشخص اللي احتجته أنا.", "والرياضة جزء مني من بدري: لعبت كرة السلة وكنت كابتن فريق السلة في جامعة الإمام عبدالرحمن بن فيصل، ولعبت باحتراف في الرياضات الإلكترونية. بدأت التدريب في 2017 مع كرة السلة، واشتغلت مساعد مدرب في نادي الجامعة، وبعدها دربت في بيور جم وجمنيشن وفتنس لاونج ونوادي خاصة."], "points": ["برنامج مبني على هدفك ومستواك.", "متابعة أسبوعية واضحة.", "تعديلات مستمرة حسب تقدمك والتزامك."], "pillars": [{"body": "ما أرسل لك جدول وأتركك. أراجعه معك بمقطع فيديو أشرح فيه كل شي، عشان تبدأ وأنت فاهم وش تسوي وليش.", "title": "جدولك مشروح بالفيديو"}, {"body": "ما أمشي على أنظمة الحرمان أبداً. خطتك تناسب حياتك، مو قائمة ممنوعات.", "title": "بدون حرمان"}, {"body": "أتابعك كل أسبوع وأهتم بالتزامك، وأعدّل خطتك حسب تقدمك وظروفك.", "title": "متابعة جادة وخطة واقعية"}, {"body": "حب تعليم الناس معي من الصغر. اللي أعرفه ما أبخل فيه، علمياً ونفسياً، وما أوقف عن البحث والتعلم عشان أتطور وأطورك معي.", "title": "أعلّمك، مو بس أدربك"}], "home_bio": "مدربة شخصية معتمدة، أدرب منذ 2017، وكابتن سابقة لفريق السلة في جامعة الإمام عبدالرحمن بن فيصل. أساعدك تبني روتين تدريب وتغذية واضح يناسب هدفك ووقتك ومستواك، مع متابعة أسبوعية وبدون أنظمة حرمان.", "fit_title": "أكثر شخص أفرق معه", "experience": ["أدرب منذ 2017، والبداية في كرة السلة.", "مساعد مدرب في نادي الجامعة.", "مدربة في بيور جم، وجمنيشن، وفتنس لاونج، ونوادي خاصة."], "story_title": "صرت الشخص اللي كنت أحتاجه", "pillars_title": "وش يميز التدريب معي؟", "experience_title": "شهاداتي وخبرتي"}', true, NULL, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('intro_video', '{"url": "", "body": "مقطع قصير أتكلم فيه عن نفسي وخلفيتي وطريقة شغلي مع المتدربين.", "title": "تعرّف عليّ في دقيقة"}', true, NULL, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('testimonials_disclaimer', '"التجارب شخصية وتختلف النتائج من شخص لآخر حسب الالتزام والحالة، والتدريب لا يغني عن استشارة الطبيب أو أخصائي العلاج الطبيعي."', true, NULL, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('prices_note', '"الأسعار بالريال السعودي. الدفع بتحويل بنكي على حساب المؤسسة."', true, NULL, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('checkins', '{"enabled": true, "questions": [{"q": "ملاحظاتك الصحية؟ الحركة اليومية وجودة الحياة صارت أحسن؟", "topic": "الصحة العامة"}, {"q": "أداؤك في التمارين؟ في تقدم في الأوزان والأداء؟", "topic": "التمارين"}, {"q": "فرق في شكلك ومظهرك؟ إيجابي أو سلبي؟", "topic": "المظهر"}, {"q": "فرق في الملابس أو المقاسات؟ إيجابي أو سلبي؟", "topic": "الملابس"}, {"q": "النظام الغذائي — قدرت تمشي عليه؟ فيه صعوبة؟", "topic": "الغذاء"}, {"q": "تحسّ بالجوع واجد؟ إن وُجد، كم تعطيه من 5؟", "topic": "الجوع"}, {"q": "أي ملاحظات سلبية تبي تشاركها؟ (مهمة أو بسيطة — نتقبل النقد)", "topic": "ملاحظات سلبية"}, {"q": "أي إشكاليات أو ملاحظات إضافية تحتاج مساعدة فيها؟", "topic": "ملاحظات أخرى"}, {"q": "وصلت لأي أسبوع تدريبي الآن؟", "topic": "الأسبوع"}]}', true, NULL, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('contact', '{"whatsapp": "966599162724", "instagram": "https://www.instagram.com/navvcoaching/"}', true, NULL, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('response_time', '"48 ساعة عمل (الأحد – الخميس، 12 ظهراً – 9 مساءً)"', true, NULL, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('legal', '{"cr": "7050950752", "name": "مؤسسة ناف كوتشنق للتدريب الرياضي"}', true, NULL, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('bank', '{"iban": "SA1280000139608016245411", "bankName": "مصرف الراجحي", "accountName": "مؤسسة ناف كوتشنق للتدريب الرياضي"}', true, NULL, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('program_shots', '[{"h": 720, "w": 754, "alt": "لقطة من صفحة «حسابي» ببيانات مثال: شريط الالتزام، أيام تمرين الأسبوع الحالي، ملخص تغذية اليوم، وروتين المكملات", "src": "shots/my-program.webp", "title": "برنامجي", "caption": "أول ما تدخل حسابك: نسبة التزامك وأسابيعك المتتالية، أيام تمرين الأسبوع، تغذية اليوم مقابل أهدافك، وروتين المكملات."}, {"h": 960, "w": 1148, "alt": "لقطة من صفحة برنامج التمرين ببيانات مثال: أيام الأسبوع، وبطاقة كل تمرين مع المستهدف وخانات الوزن والتكرارات وRIR", "src": "shots/training-log.webp", "title": "تسجيل التمرين", "caption": "لكل تمرين المستهدف من الجولات والتكرارات وRIR، وتسجّل وزنك وتكراراتك من جوالك، ولك تبديله ببديل تختاره المدربة."}, {"h": 1020, "w": 1148, "alt": "لقطة من صفحة التغذية ببيانات مثال: ملخص اليوم مقابل الأهداف، ونموذج إضافة أكلة، وأكل اليوم حسب الوجبات", "src": "shots/nutrition-day.webp", "title": "التغذية اليومية", "caption": "أهدافك اليومية من السعرات والماكروز وكم باقي لك، وتسجّل أكلك من جداولك الغذائية أو بالغرام من قاعدة الأكل."}, {"h": 307, "w": 1116, "alt": "لقطة من لوحة التقدم ببيانات مثال: رسم الوزن ورسم القياسات", "src": "shots/progress-charts.webp", "title": "لوحة التقدم", "caption": "وزنك وقياساتك برسوم واضحة أسبوعاً بأسبوع، ببيانات مثال."}]', true, NULL, '2026-10-09 21:11:33.273715+00') ON CONFLICT DO NOTHING;
COMMIT;
