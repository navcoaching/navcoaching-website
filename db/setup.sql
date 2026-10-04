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

-- ---------- المحتوى المستورد من الموقع الحالي ----------
INSERT INTO public.exercises VALUES ('30f06711-e719-41bf-bd29-0134e17b0b40', 'Seated Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/0G3W83dFUeY', 'اسحب باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness | تحدب الظهر / Postural Thoracic Kyphosis', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', 'تقوية سحب وانكماش لوح الكتف', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moseley et al. 1992 — AJSM (EMG, scapular muscles) | Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://pubmed.ncbi.nlm.nih.gov/1558238/ | https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1faae23e-3054-4ea8-b002-c663343d734f', 'Forward Lunges', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/_DLAdo2Pvjs', 'تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness | ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, 'تقوية الورك ضمن نمط حركي وظيفي', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Distefano et al. 2009 — JOSPT (EMG) | Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin)', 'https://pubmed.ncbi.nlm.nih.gov/19574661/ | https://pubmed.ncbi.nlm.nih.gov/33344003/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f3e3666c-4404-4a1f-a6d2-163d06ffe32b', 'Bird Dog', 'Core / البطن والكور', '{"Lower back / أسفل الظهر","Glutes / المؤخرة"}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/L91QMACdA6Q?si=KBnuQDcm9WcUXxxI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Anti-Rotation / مقاومة الدوران', 'Isometric Anti-Rotation / تثبيت الجذع ضد الدوران', NULL, 'التحكم الحركي وتحمّل الجذع', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('659c9f41-bcd2-4757-91ae-9433e7a856b7', 'Single Leg Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'وزن الجسم', 'متقدم', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/136/single-leg-squat/', 'ضعف الألوية الكبرى / Gluteus Maximus Weakness | ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Single-leg Squat / سكوات رجل واحدة', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, 'تقوية باسطات ومبعدات الورك وتحكم أحادي الطرف', 'متقدمة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ يتطلب تحكماً جيداً بالركبة والحوض', 'Distefano et al. 2009 — JOSPT (EMG) | Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin)', 'https://pubmed.ncbi.nlm.nih.gov/19574661/ | https://pubmed.ncbi.nlm.nih.gov/33344003/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fbb9dcc5-00fd-4435-883f-0f3b80eaf1c8', 'Hip Abduction', 'Abductors / مبعدات الفخذ', '{"Glutes / المؤخرة"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/_ARUxqrII3Y?si=Jcz5uh2Uu-IdVCS1', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL, 'تقوية مبعدات الورك بمقاومة خارجية', 'مبكرة–متوسطة', 'منخفض–متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ الدليل يخص إبعاد الورك بمقاومة خارجية؛ يُتحقق من نوع الأداء', 'Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin)', 'https://pubmed.ncbi.nlm.nih.gov/33344003/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('367bfe94-dcea-49b5-99bd-39394447b709', 'Side Step Up', 'Glutes / المؤخرة', '{"Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/xOwIRnI4VxA?si=SJOgODRmNGdfHPb4', 'يد فيها الوزن واليد الثانية سندها على الجدار', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية المتوسطة / Gluteus Medius Weakness | ضعف الألوية الصغرى / Gluteus Minimus Weakness', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, 'تقوية مبعدات الورك والتحكم بالحوض على رجل واحدة', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin) | Ganderton et al. — GMin/GMed EMG (RMIT University)', 'https://pubmed.ncbi.nlm.nih.gov/33344003/ | https://research-repository.rmit.edu.au/articles/journal_contribution/Gluteus_Minimus_and_Gluteus_Medius_Muscle_Activity_during_Common_Rehabilitation_Exercises_in_Healthy_Postmenopausal_Women/27572301', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d50775b9-d8ce-4dc0-aed4-0fedd015ffcf', 'Glute Bridge', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', NULL, 'مبتدئ', NULL, 'https://www.youtube.com/watch?v=dtlGynVdHYM', 'ممكن تسويه بالسميث مشين او البار الحر ، اختر بوكس او بنش يكون بمستوى اكتافك الخلفية وانت جالس، لما ترفع البار فوق المفروض ركبك تكون بنفس مستوى القدم.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness | آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, 'تقوية بسط الورك وتحمّل الجذع', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Boren et al. 2011 — IJSPT (EMG) | JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/22034614/ | https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('053b1176-7c11-4e7d-9c3c-7f1bc6998a68', 'DB Floor Glute Bridge', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/iOrJXNUH3to?si=JySX6JMhoP2vWEVa', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, 'تقوية بسط الورك بتحميل خارجي متدرج', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Boren et al. 2011 — IJSPT (EMG)', 'https://pubmed.ncbi.nlm.nih.gov/22034614/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('eea44714-b447-4b6a-b6f5-dd000b956381', 'Single DB RDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/U3prDlAbJDw?si=MRSBcSIcf9M-WQBH', 'وقف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، انزل وادفع مؤخرتك لآخر شي تقدر عليه للخلف وكأنك بتلمس جدار خلفك مع انثناء بسيط بالركب', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, 'تقوية باسطات الورك وتحكم أحادي الطرف', 'متقدمة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ مع الحفاظ على وضع محايد للظهر', 'Distefano et al. 2009 — JOSPT (EMG)', 'https://pubmed.ncbi.nlm.nih.gov/19574661/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('37fb949a-27b4-4773-bd6b-935edf7d2752', 'Upper Back Horizontal Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/TSWohpfMlso', 'ثبت نفسك بالكرسي، فتحة واسعة، الكيبل بمستوى أعلى صدرك، واسحب لما تنقبض الترابز.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Wide-grip Row / تجديف بقبضة واسعة', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', 'تقوية انكماش لوح الكتف والظهر العلوي', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moseley et al. 1992 — AJSM (EMG, scapular muscles)', 'https://pubmed.ncbi.nlm.nih.gov/1558238/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8cc961d8-de85-49aa-a1a6-4525c7fa0e4d', 'Band Seated Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/Jy-WCFAofBY?si=9gqVby588rk1zFi9', 'فتحة واسعة، واسحب لما تنقبض عضلات الظهر.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness | تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', 'تقوية سحب لوح الكتف بمقاومة منخفضة', 'مبكرة–متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moseley et al. 1992 — AJSM (EMG, scapular muscles) | Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://pubmed.ncbi.nlm.nih.gov/1558238/ | https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('12a18553-9f99-44bc-a297-f76cfea02cf5', 'Chest Supported Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/DgHtyrQEMJ4?si=oTfTKVgD9j1H12wA', 'ثبت صدرك على الكرسي، فتحة واسعة، واسحب لما تنقبض عضلات الظهر.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', 'تقوية انكماش لوح الكتف مع دعم الجذع', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moseley et al. 1992 — AJSM (EMG, scapular muscles)', 'https://pubmed.ncbi.nlm.nih.gov/1558238/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1dde8f57-469e-47b2-b9e2-8e5e8d1ece20', 'Plank', 'Core / البطن والكور', '{"Shoulders / الأكتاف","Glutes / المؤخرة"}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/pvIjsG5Svck?si=cTP8ZyfMAJPfaEhw', 'لما ترتفع الاكتاف تكون فوق الكوع والرجل ممتدة بالكامل.', NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL, 'تحمّل عضلات الجذع', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('20d5d6c0-8c80-4f6f-abd5-62d14395424e', 'deadbug', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/g_BYB0R-4Ws?si=D4nwJri73eBqJRqL', NULL, 'اسم مشابه موجود في المكتبة (deadbug / dead bug) — تُراجَع قبل الحذف أو الدمج', 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'rejected', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL, 'التحكم الحركي وتحمّل الجذع', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1e7e26b5-4c02-4197-9edc-f6f309549c2d', 'Band Dead Bug', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'مطاط', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/iW_CtYtzbeU?si=Epequw3rqA3_TwTr', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL, 'التحكم الحركي وتحمّل الجذع بمقاومة', 'مبكرة–متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('493f0c7c-6266-4073-9413-f5c75bfec787', 'Side Plank', 'Core / البطن والكور', '{"Abductors / مبعدات الفخذ","Shoulders / الأكتاف"}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'لما ترتفع الاكتاف تكون فوق الكوع والرجل ممتدة بالكامل.', NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain | ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Anti-Lateral Flexion / مقاومة الميلان الجانبي', 'Isometric Anti-Lateral Flexion / تثبيت الجذع ضد الميلان', NULL, 'تحمّل الجذع الجانبي وتنشيط مبعدات الورك', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.) | Boren et al. 2011 — IJSPT (EMG)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/ | https://pubmed.ncbi.nlm.nih.gov/22034614/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c530f3c1-409d-4e68-be24-c37006116a39', 'McGill Big 3', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/jZylx81_kfg?si=_jP064GZIzvEvzyN', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Mixed (McGill Big 3) / مختلط', 'Isometric Trunk Stabilization / تثبيت الجذع', NULL, 'التحكم الحركي وتحمّل الجذع', 'مبكرة–متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('dcb9b881-a091-43f5-93f5-ee91b42008ea', 'Dead Bug', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/bxn9FBrt4-A', 'نحرك الرجلين ببطئ قليلا و بتحكم باستخدام عضلات البطن', 'اسم مشابه موجود في المكتبة (deadbug / dead bug) — تُراجَع قبل الحذف أو الدمج', 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL, 'التحكم الحركي وتحمّل الجذع', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cd59b929-d682-4e1c-86a5-e0832ec0b413', 'High-Load Heel Raise (Towel Under Toes)', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', NULL, 'مبتدئ', NULL, NULL, 'رفع الكعب على رجل واحدة مع منشفة ملفوفة تحت أصابع القدم؛ صعود بطيء ثم ثبات قصير ثم نزول بطيء.', 'أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Rathleff et al. 2015 — Scand J Med Sci Sports (RCT)', 'https://doi.org/10.1111/sms.12313', 'اللفافة الأخمصية / Plantar Fasciopathy', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL, 'تحميل تدريجي للقدم والكاحل', 'متقدمة', 'مرتفع', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ يُبدأ بعد تحسّن الأعراض وبتدرّج', 'Rathleff et al. 2015 — Scand J Med Sci Sports (RCT) | JOSPT CPG 2023 — Heel Pain/Plantar Fasciitis (Koc et al.)', 'https://doi.org/10.1111/sms.12313 | https://pubmed.ncbi.nlm.nih.gov/38037331/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('90f2d550-1e0a-4e20-9bbc-366c207323ac', 'Side Lunge', 'Adductors / الأفخاذ الداخلية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/50/side-lunge/', 'ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Lateral Lunge / لانج جانبي', 'Knee/Hip Extension + Hip Adduction / مد الركبة والورك + تقريب الورك', NULL, 'تقوية مبعدات الورك والتحكم بالحوض', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin)', 'https://pubmed.ncbi.nlm.nih.gov/33344003/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('99990b68-c893-41d6-bd47-c595e72366dd', 'Hip Hitch (Pelvic Drop)', 'Abductors / مبعدات الفخذ', '{}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Ganderton et al. — GMin/GMed EMG (RMIT University)', 'https://research-repository.rmit.edu.au/articles/journal_contribution/Gluteus_Minimus_and_Gluteus_Medius_Muscle_Activity_during_Common_Rehabilitation_Exercises_in_Healthy_Postmenopausal_Women/27572301', 'ضعف الألوية المتوسطة / Gluteus Medius Weakness | ضعف الألوية الصغرى / Gluteus Minimus Weakness', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Pelvic Drop (Stance Leg) / تثبيت الحوض برجل الارتكاز', 'Hip Abduction of Stance Leg / تبعيد ورك رجل الارتكاز', NULL, 'تنشيط وتقوية مبعدات الورك (الألوية المتوسطة والصغرى) والتحكم بالحوض', 'مبكرة–متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Ganderton et al. — GMin/GMed EMG (RMIT University) | Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin)', 'https://research-repository.rmit.edu.au/articles/journal_contribution/Gluteus_Minimus_and_Gluteus_Medius_Muscle_Activity_during_Common_Rehabilitation_Exercises_in_Healthy_Postmenopausal_Women/27572301 | https://pubmed.ncbi.nlm.nih.gov/33344003/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('16736818-22a3-403a-ada3-b938712cd657', 'Shoulder I-Y-T-W Series', 'Rotator cuffs / الكفة المدورة', '{"Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/237/shoulder-stability-mobility-series-i-y-t-w-formations/', 'تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture | ضعف العضلة المعينية / Rhomboid Weakness', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'I-Y-T-W / تمارين I-Y-T-W', 'Scapular Retraction/Depression + Arm Elevation / سحب وخفض لوح الكتف مع رفع الذراع', NULL, 'تقوية وتحكم عضلات لوح الكتف (الانكماش والتدوير)', 'مبكرة–متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis) | Sheikhhoseini et al. 2018 — JMPT (Systematic review, FHP) | Castelein et al. 2016 — Man Ther (EMG, rhomboid)', 'https://doi.org/10.1186/s12891-024-07224-4 | https://pubmed.ncbi.nlm.nih.gov/30107937/ | https://pubmed.ncbi.nlm.nih.gov/26409441/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('516aead8-35f2-4375-b304-89fd9c6a8119', 'Supine Snow Angel (Wipers)', 'Rotator cuffs / الكفة المدورة', '{"Shoulders / الأكتاف","Core / البطن والكور"}', 'Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/124/supine-snow-angel-wipers-exercise/', 'تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Snow Angel / الملاك', 'Shoulder Abduction/Adduction + Scapular Control / تبعيد وتقريب الكتف مع تحكم لوح الكتف', NULL, 'حركة الكتف والتحكم بلوح الكتف', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a9eb9f06-7159-4ff4-9a4e-c91fa9649d8e', 'Single Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/82IuSLk5zNc?si=FTMqZrmawQFRr8dN', 'اجلس وثبت ظهرك السفلي كويس، تأكد ان مسمار الارتفاع يكون بمستوى ركبتك، امسك المقابض لزيادة الثبات، إرفع الوزن اثبت ثانية فوق ثم انزل نزول كامل بتحكم.

ملاحظات مهمة:
• اعمل برجل واحدة بنفس ضبط الجهاز
• ثبّت الجذع ولا تتمايل لتعويض الوزن
• افرد الركبة ببطء وانزل بتحكم
• وزن أخف من العمل بالرجلين', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f07e5431-3c9e-4342-b8dd-1dc11ecce624', 'Back Extension', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة","Hamstrings / الخلفية"}', 'Spinal Extension / بسط الجذع', 'كور', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/bs7S3RFyIYs?si=tDLl3OYuDBIwK4Fj', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «Functional Training»)', 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain | تحدب الظهر / Postural Thoracic Kyphosis', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Back Extension / بسط الظهر', 'Hip Extension + Spinal Extension / بسط الورك + بسط العمود الفقري', NULL, 'تقوية باسطات الظهر', 'متقدمة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ يُراجَع إذا زاد الألم مع الامتداد', 'JOSPT CPG 2021 — Low Back Pain (George et al.) | Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/ | https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c4609a8b-998a-4552-8966-e15384631a40', 'Supermans', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة","Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Spinal Extension / بسط الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/9/supermans/', 'تحدب الظهر / Postural Thoracic Kyphosis | آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Prone Extension / بسط على البطن', 'Spinal Extension / بسط العمود الفقري', NULL, 'تقوية باسطات الظهر والتحكم الوضعي', 'متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis) | JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://doi.org/10.1186/s12891-024-07224-4 | https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1128979e-f5f1-4942-bdc3-17cdb094333f', 'Standing Dorsi-Flexion (Calf Stretch)', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/152/standing-dorsi-flexion-calf-stretch/', 'اللفافة الأخمصية / Plantar Fasciopathy', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Calf Stretch / إطالة البطات', 'Ankle Dorsiflexion / ثني ظهري للكاحل', NULL, 'إطالة عضلات الساق', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2023 — Heel Pain/Plantar Fasciitis (Koc et al.)', 'https://pubmed.ncbi.nlm.nih.gov/38037331/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('17fbbe0c-ee03-4fc1-8e0c-0aaee0a190ff', 'Cat-Cow', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/15/cat-cow/', 'تحدب الظهر / Postural Thoracic Kyphosis | آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Spinal Mobility / مرونة العمود الفقري', 'Spinal Flexion/Extension / ثني وبسط العمود الفقري', NULL, 'حركة العمود الفقري ضمن مدى حركة مريح', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis) | JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://doi.org/10.1186/s12891-024-07224-4 | https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3ee7885b-2a5e-4a79-b7d9-ca62543e608f', 'Plantar Fascia-Specific Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'تُسحب أصابع القدم للخلف باليد حتى يُشعر بشد في باطن القدم، مع تحسّس اللفافة للتأكد من الشد.', 'أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Rathleff et al. 2015 — Scand J Med Sci Sports (RCT)', 'https://doi.org/10.1111/sms.12313', 'اللفافة الأخمصية / Plantar Fasciopathy', 'review', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Plantar Fascia Stretch / إطالة اللفافة الأخمصية', 'Toe Extension + Ankle Dorsiflexion / مد أصابع القدم + ثني ظهري', NULL, 'إطالة اللفافة الأخمصية', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2023 — Heel Pain/Plantar Fasciitis (Koc et al.) | Rathleff et al. 2015 — Scand J Med Sci Sports (RCT)', 'https://pubmed.ncbi.nlm.nih.gov/38037331/ | https://doi.org/10.1111/sms.12313', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('715e8e70-4c95-477a-aad2-6f96b8dd080c', 'Crab Reach (Thoracic Bridge)', 'Functional / التمارين الوظيفية', '{"Glutes / المؤخرة","Shoulders / الأكتاف"}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://www.youtube.com/watch?v=fgsUe3Lc3hI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'تحدب الظهر / Postural Thoracic Kyphosis', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Thoracic Bridge / جسر صدري', 'Hip Extension + Thoracic Rotation / بسط الورك + دوران الصدر', NULL, 'حركة الامتداد والدوران الصدري', 'متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ يتطلب تحمّلاً جيداً للرسغ والكتف', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0cc87278-da45-4689-9425-227edc65146f', 'Prone Swimmer', 'Functional / التمارين الوظيفية', '{"Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Shoulder Rear Pull / سحب خلفي للكتف', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://www.youtube.com/watch?v=M8a1cgnhyqk', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Prone Swimmer / سبّاح على البطن', 'Shoulder Extension/Abduction + Rotation / مد وتبعيد الكتف مع الدوران', NULL, 'تحمّل عضلات لوح الكتف والامتداد الصدري', 'متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('34ec9dff-e0aa-4206-a420-b603226f1883', 'Isometric Wrist Extension', 'Forearms / الساعد', '{}', 'Wrist Extension / مد الرسغ', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'مرفق التنس / Lateral Elbow Tendinopathy', 'review', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Isometric / ثابت', 'Wrist Extension / مد الرسغ', NULL, 'تحميل تدريجي لباسطات الرسغ (انقباض ثابت)', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ ضمن ألم مقبول لا يتزايد بعد التمرين', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cf519867-9b75-4bc3-b639-681b982070c5', 'Eccentric Wrist Extension', 'Forearms / الساعد', '{}', 'Wrist Extension / مد الرسغ', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'مرفق التنس / Lateral Elbow Tendinopathy', 'review', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Eccentric / لامركزي', 'Wrist Extension / مد الرسغ', NULL, 'تحميل تدريجي لباسطات الرسغ (لامركزي)', 'متوسطة', 'منخفض–متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ ضمن ألم مقبول لا يتزايد بعد التمرين', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('945459c9-241b-4b58-8b15-d69c1362711a', 'Chin Tuck (Deep Neck Flexor)', 'Neck / الرقبة', '{}', 'Neck Flexion (Deep Flexors) / ثني الرقبة العميق', 'إحماء/تفعيل', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Sheikhhoseini et al. 2018 — JMPT (Systematic review, FHP)', 'https://pubmed.ncbi.nlm.nih.gov/30107937/', 'وضعية الرأس للأمام / Forward Head Posture', 'review', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Chin Tuck / سحب الذقن', 'Upper Cervical Flexion + Retraction / ثني علوي للرقبة مع سحبها للخلف', NULL, 'تحكم عضلات الرقبة العميقة ووضعية الرأس', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ يُوقف مع دوخة أو ألم/تنميل يمتد للذراع', 'Sheikhhoseini et al. 2018 — JMPT (Systematic review, FHP) | Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://pubmed.ncbi.nlm.nih.gov/30107937/ | https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9210885b-7385-416d-b03b-970c3b50b71b', 'Terminal Knee Extension (Band)', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'مطاط', 'مبتدئ', 'منزل', NULL, 'اربط الشريط المطاطي خلف الركبة وقف بثبات. من ركبة مثنية قليلاً، افرد الركبة بالكامل ببطء وشد عضلة الفخذ الأمامية ثانية، ثم ارجع ببطء. 2–3 مجموعات × 12–15 تكرار.', NULL, 'مصدر خارجي موثوق', 'JOSPT CPG 2019 — Patellofemoral Pain (Willy et al.)', 'https://doi.org/10.2519/jospt.2019.0302', 'ألم الرضفة والفخذ (الركبة الأمامية) / Patellofemoral Pain', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Knee Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, 'تقوية الفخذ الأمامي في مدى آمن للركبة', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي. يكون الألم أثناء التمرين خفيفاً ومقبولاً (حتى 3 من 10) ويهدأ خلال 24 ساعة، وإذا زاد الألم أو ظهر تورم أو إحساس بقفل أو خذلان في الركبة يتوقف التمرين وتُراجَع أخصائي.', 'Willy et al. 2019 — JOSPT (Patellofemoral Pain CPG) | Lack et al. 2015 — Br J Sports Med (Proximal muscle rehabilitation for PFP, meta-analysis)', 'https://doi.org/10.2519/jospt.2019.0302 | https://bjsm.bmj.com/content/49/21/1365', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('071387c5-766c-475f-aaee-ee78a3a04302', 'Mini Squat (Partial Range)', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'انزل نزولاً جزئياً فقط (حتى نحو 45° من ثني الركبة) مع ثبات الركبة فوق القدم وعدم انهيارها للداخل، ثم اصعد. 2–3 مجموعات × 10–15 تكرار. زد المدى تدريجياً حسب الراحة.', NULL, 'مصدر خارجي موثوق', 'JOSPT CPG 2019 — Patellofemoral Pain (Willy et al.)', 'https://doi.org/10.2519/jospt.2019.0302', 'ألم الرضفة والفخذ (الركبة الأمامية) / Patellofemoral Pain', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, 'تقوية الفخذ الأمامي والورك بحمل خفيف على مفصل الرضفة', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي. يكون الألم أثناء التمرين خفيفاً ومقبولاً (حتى 3 من 10) ويهدأ خلال 24 ساعة، وإذا زاد الألم أو ظهر تورم أو إحساس بقفل أو خذلان في الركبة يتوقف التمرين وتُراجَع أخصائي.', 'Willy et al. 2019 — JOSPT (Patellofemoral Pain CPG) | Lack et al. 2015 — Br J Sports Med (Proximal muscle rehabilitation for PFP, meta-analysis)', 'https://doi.org/10.2519/jospt.2019.0302 | https://bjsm.bmj.com/content/49/21/1365', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0c6e3538-4f0b-49c1-be98-b697414afe9d', 'Lateral Step-Down (Slow Eccentric)', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', NULL, 'قف على حافة درجة بقدم واحدة. انزل بالقدم الأخرى ببطء (3 ثوانٍ) مع إبقاء الحوض مستوياً والركبة فوق أصابع القدم، المس الأرض بخفة ثم اصعد. 2–3 مجموعات × 8–12 تكرار لكل رجل.', NULL, 'مصدر خارجي موثوق', 'JOSPT CPG 2019 — Patellofemoral Pain (Willy et al.)', 'https://doi.org/10.2519/jospt.2019.0302', 'ألم الرضفة والفخذ (الركبة الأمامية) / Patellofemoral Pain', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Step-up / صعود الدرجة', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, 'تحكم الورك والركبة أثناء الحمل على رجل واحدة', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي. يكون الألم أثناء التمرين خفيفاً ومقبولاً (حتى 3 من 10) ويهدأ خلال 24 ساعة، وإذا زاد الألم أو ظهر تورم أو إحساس بقفل أو خذلان في الركبة يتوقف التمرين وتُراجَع أخصائي.', 'Willy et al. 2019 — JOSPT (Patellofemoral Pain CPG) | Lack et al. 2015 — Br J Sports Med (Proximal muscle rehabilitation for PFP, meta-analysis)', 'https://doi.org/10.2519/jospt.2019.0302 | https://bjsm.bmj.com/content/49/21/1365', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c69cfc00-0f1e-418b-a764-4dadf0a6acb8', 'Clamshell', 'Glutes / المؤخرة', '{"Abductors / مبعدات الفخذ"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'استلقِ على جنبك وركبتاك مثنيتان 45° وقدماك ملتصقتان. افتح الركبة العليا كالصدفة دون تحريك الحوض للخلف، ثم أغلقها ببطء. 2–3 مجموعات × 12–20 تكرار. يمكن إضافة شريط مطاطي للتدرج.', NULL, 'مصدر خارجي موثوق', 'BJSM 2015 — Proximal muscle rehabilitation for PFP (Lack et al.)', 'https://bjsm.bmj.com/content/49/21/1365', 'ألم الرضفة والفخذ (الركبة الأمامية) / Patellofemoral Pain', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Hip External Rotation / دوران الورك للخارج', 'Hip External Rotation / دوران الورك للخارج', NULL, 'تقوية دوران الورك الخارجي والألوية الوسطى', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي. يكون الألم أثناء التمرين خفيفاً ومقبولاً (حتى 3 من 10) ويهدأ خلال 24 ساعة، وإذا زاد الألم أو ظهر تورم أو إحساس بقفل أو خذلان في الركبة يتوقف التمرين وتُراجَع أخصائي.', 'Willy et al. 2019 — JOSPT (Patellofemoral Pain CPG) | Lack et al. 2015 — Br J Sports Med (Proximal muscle rehabilitation for PFP, meta-analysis)', 'https://doi.org/10.2519/jospt.2019.0302 | https://bjsm.bmj.com/content/49/21/1365', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('28c20efb-a371-4c9e-a305-64b70e22634b', 'Wall Sit (Isometric Quad Hold)', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'ضع ظهرك على الحائط وانزل حتى ركبتين مثنيتين بزاوية مريحة (نحو 60–90°) وثبّت. 4–5 مجموعات × 30–45 ثانية مع راحة دقيقتين. يُستخدم عند ألم الوتر لتخفيف الألم قبل التمارين الأخرى.', NULL, 'مصدر خارجي موثوق', 'Br J Sports Med 2015 — Isometric exercise in patellar tendinopathy (Rio et al.)', 'https://pubmed.ncbi.nlm.nih.gov/25979840/', 'اعتلال وتر الرضفة / Patellar Tendinopathy | ألم الرضفة والفخذ (الركبة الأمامية) / Patellofemoral Pain', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Isometric Knee Extension / انقباض ثابت لمد الركبة', NULL, 'تخفيف الألم وتحميل آمن لوتر الرضفة بالانقباض الثابت', 'مبكرة', 'منخفض–متوسط', 'يُستخدم بعد تقييم فردي. يكون الألم أثناء التمرين خفيفاً ومقبولاً (حتى 3 من 10) ويهدأ خلال 24 ساعة، وإذا زاد الألم أو ظهر تورم أو إحساس بقفل أو خذلان في الركبة يتوقف التمرين وتُراجَع أخصائي.', 'Rio et al. 2015 — Br J Sports Med (Isometric exercise and analgesia in patellar tendinopathy) | Willy et al. 2019 — JOSPT (Patellofemoral Pain CPG) | Lack et al. 2015 — Br J Sports Med (Proximal muscle rehabilitation for PFP, meta-analysis)', 'https://pubmed.ncbi.nlm.nih.gov/25979840/ | https://doi.org/10.2519/jospt.2019.0302 | https://bjsm.bmj.com/content/49/21/1365', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1e76be6f-7f04-43bb-82e5-d4e94b821351', 'Isometric Leg Extension Hold (Machine)', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'جهاز', 'متوسط', 'نادي', NULL, 'اجلس على جهاز فرد الركبة وثبّت الزاوية عند نحو 60° من ثني الركبة. ادفع بجهد متوسط–عالٍ (نحو 70% من أقصى قوة) وثبّت 45 ثانية، 5 مجموعات مع راحة دقيقتين. بروتوكول الدراسة المرجعية.', NULL, 'مصدر خارجي موثوق', 'Br J Sports Med 2015 — Isometric exercise in patellar tendinopathy (Rio et al.)', 'https://pubmed.ncbi.nlm.nih.gov/25979840/', 'اعتلال وتر الرضفة / Patellar Tendinopathy', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Isometric / ثابت', 'Isometric Knee Extension / انقباض ثابت لمد الركبة', NULL, 'تخفيف ألم الوتر وتقليل التثبيط العضلي', 'مبكرة', 'متوسط', 'يُستخدم بعد تقييم فردي. يكون الألم أثناء التمرين خفيفاً ومقبولاً (حتى 3 من 10) ويهدأ خلال 24 ساعة، وإذا زاد الألم أو ظهر تورم أو إحساس بقفل أو خذلان في الركبة يتوقف التمرين وتُراجَع أخصائي.', 'Rio et al. 2015 — Br J Sports Med (Isometric exercise and analgesia in patellar tendinopathy)', 'https://pubmed.ncbi.nlm.nih.gov/25979840/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('42b5ad26-c32f-41b1-b811-309ef3435a76', 'Slow Leg Press (Heavy Slow Resistance)', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'متوسط', 'نادي', NULL, 'ضغط الأرجل بحركة بطيئة جداً: 3 ثوانٍ للدفع و3 ثوانٍ للنزول بدون توقف. تزيد الأوزان وتقل التكرارات تدريجياً (من 15 إلى 6) خلال 12 أسبوعاً، 3 أيام في الأسبوع بالتناوب مع تمرين سكوات وهاك سكوات.', NULL, 'مصدر خارجي موثوق', 'Scand J Med Sci Sports 2009 — HSR in patellar tendinopathy (Kongsgaard et al.)', 'https://pubmed.ncbi.nlm.nih.gov/19793213/', 'اعتلال وتر الرضفة / Patellar Tendinopathy', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Leg Press / ضغط الأرجل', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, 'تحميل تدريجي لوتر الرضفة بمقاومة عالية وبطيئة', 'متوسطة–متقدمة', 'مرتفع', 'يُستخدم بعد تقييم فردي. يكون الألم أثناء التمرين خفيفاً ومقبولاً (حتى 3 من 10) ويهدأ خلال 24 ساعة، وإذا زاد الألم أو ظهر تورم أو إحساس بقفل أو خذلان في الركبة يتوقف التمرين وتُراجَع أخصائي.', 'Kongsgaard et al. 2009 — Scand J Med Sci Sports (Heavy slow resistance vs eccentric decline squat vs corticosteroid in patellar tendinopathy)', 'https://pubmed.ncbi.nlm.nih.gov/19793213/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('63cb145e-03f2-4829-b550-c839e30f1999', 'Modified Curl-Up (McGill)', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'استلقِ على ظهرك، ركبة مثنية والأخرى مفرودة، ويداك تحت أسفل الظهر للحفاظ على انحنائه الطبيعي. ارفع الرأس والكتفين قليلاً فقط (دون ثني أسفل الظهر) وثبّت 7–10 ثوانٍ، ثم ارجع. 3 جولات (تنازلية 6-4-2) حسب برنامج ماكجيل.', NULL, 'مصدر خارجي موثوق', 'McGill 2010 — Core training (Strength Cond J)', NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL, 'تقوية عضلات البطن بأقل حمل على العمود الفقري', 'مبكرة', 'منخفض', 'لا يُجرى مع ألم حاد أو ألم ينتشر للساق أو تنميل. يتوقف التمرين إذا زاد الألم، وتُراجَع أخصائي.', 'NICE NG59 (2020) — Low back pain and sciatica in over 16s | Hayden et al. 2021 — Cochrane (Exercise therapy for chronic low back pain) | McGill 2010 — Strength Cond J (Core training)', 'https://www.nice.org.uk/guidance/ng59 | https://doi.org/10.1002/14651858.CD009790.pub2', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e8c1d0f0-9eef-4188-88a0-b0ecaa188f72', 'Supine Pelvic Tilt', 'Core / البطن والكور', '{"Glutes / المؤخرة"}', 'Core Activation & Breathing / تفعيل الجذع والتنفس', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'استلقِ على ظهرك وركبتاك مثنيتان. اضغط أسفل الظهر برفق نحو الأرض بشد البطن والألوية قليلاً، ثبّت 5 ثوانٍ مع تنفس طبيعي ثم استرخِ. 2 مجموعات × 10 تكرارات.', NULL, 'مصدر خارجي موثوق', 'NICE NG59 — Low back pain and sciatica in over 16s', 'https://www.nice.org.uk/guidance/ng59', 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Pelvic Control / التحكم بالحوض', 'Posterior Pelvic Tilt / إمالة الحوض للخلف', NULL, 'تفعيل الجذع وتحسين وعي الحوض في المراحل الأولى', 'مبكرة', 'منخفض', 'تمرين تمهيدي خفيف. لا تدفع بقوة، ويتوقف عند زيادة الألم.', 'NICE NG59 (2020) | Hayden et al. 2021 — Cochrane (دليل عام على التمارين، ولا توجد تجربة تعزل هذا التمرين بعينه)', 'https://www.nice.org.uk/guidance/ng59 | https://doi.org/10.1002/14651858.CD009790.pub2', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3dc5d55c-a134-4321-87c8-ca77a5559000', 'Tyler Twist (FlexBar)', 'Forearms / الساعد', '{}', 'Wrist Extension / مد الرسغ', 'قوة', 'أخرى', 'متوسط', 'منزل', NULL, 'أمسك قضيب FlexBar عمودياً: اليد المصابة من الأعلى والسليمة من الأسفل، والرسغ المصاب مفرود للخلف. لفّ القضيب باليد السليمة (التواء)، ثم مدّ الذراعين أمامك وأرخِ الالتواء ببطء بالرسغ المصاب حتى يستقيم (حركة لامركزية بطيئة). 3 مجموعات × 15 تكرار يومياً، وتزيد مقاومة القضيب تدريجياً. هذا الوصف مبسّط، فيُراجَع مع أخصائي عند أول استخدام.', NULL, 'مصدر خارجي موثوق', 'J Shoulder Elbow Surg 2010 — Tyler Twist (Tyler et al.)', NULL, 'مرفق التنس / Lateral Elbow Tendinopathy', 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Eccentric / لامركزي', 'Wrist Extension / مد الرسغ', NULL, 'تقوية لامركزية لباسطات الرسغ لألم مرفق التنس', 'مبكرة–متوسطة', 'منخفض–متوسط', 'يكون الألم أثناء التمرين خفيفاً ومقبولاً. إذا زاد الألم أو ظهر تنميل أو ضعف في اليد يتوقف التمرين وتُراجَع أخصائي.', 'Tyler et al. 2010 — J Shoulder Elbow Surg 19(6):917–922 (Tyler Twist with FlexBar)', NULL, 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e6aae816-4097-41f5-a838-f9d4f51dc913', 'Single Leg Raise', 'Core / البطن والكور', '{"Glutes / المؤخرة","Hamstrings / الخلفية"}', NULL, NULL, 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/ZJodU5OOaiA?si=p6ZD9dpzyRKBUn16', 'ملاحظات مهمة:
• استلقِ وثبّت أسفل الظهر على الأرض
• ارفع الرجل بتحكم دون تقوّس الظهر
• نزول بطيء
• لا ترتد', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6f81f99d-2b44-4b51-b3cd-9e2ac03e6f4e', 'Nordic Hamstring Curl', 'Hamstrings / الخلفية', '{}', 'Knee Flexion / ثني الركبة', 'قوة', 'وزن الجسم', 'متقدم', 'بدون معدات', 'https://youtu.be/Lgibr8od0yA?si=nfRetEkDRk55Bu0a', 'ملاحظات مهمة:
• ثبّت الكعبين جيداً وانزل ببطء بجسم مستقيم من الركبة للرأس
• استخدم اليدين لتخفيف الحمل في البداية
• عُد بدفع خفيف باليدين
• ابدأ بمدى قصير لتجنب شد الخلفية', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Nordic (Eccentric) / نوردك (لامركزي)', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6e437211-13b4-4e14-84d0-6271547dfa73', 'Box Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtube.com/shorts/9uhEh9gpwUU?si=xaTY7AJiCeQfa3by', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل.

ملاحظات مهمة:
• اجلس للخلف على الصندوق بتحكم وجذع مرفوع ولا ترتمِ عليه
• توقف لحظة دون إرخاء العضلات ثم ادفع الأرض بالكعبين
• الصندوق بارتفاع يجعل الفخذ موازياً للأرض تقريباً
• الخطأ الشائع: تقوّس الظهر عند الانطلاق من الصندوق', 'تعليمات بديلة في المصدر (صف 13): ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل، انزل واثبت على البوكس ثانية وارفع.', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ef14fa72-c6f2-4705-a3f1-0fc69d1ebc6e', 'Back Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/bEv6CCg2BC8', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل.

ملاحظات مهمة:
• البار على أعلى الظهر (عضلة الترابيس) لا على الرقبة، والقبضة ثابتة، والصدر مرفوع
• القدمان بعرض الكتفين وأصابعهما للخارج قليلاً، والركبتان تتبعان اتجاه الأصابع
• انزل بعمق يسمح به مدى الورك والكاحل مع شد البطن، وتجنّب انحناء أسفل الظهر في القاع
• الخطأ الشائع: رفع الكعبين أو انهيار الركبتين للداخل', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('288b735c-2ce7-4b9a-af4d-1d894cd31c35', 'Hack Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/0tn5K9NlCfo', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.

ملاحظات مهمة:
• ظهر وأرداف ملتصقان بالمسند طوال الحركة
• القدمان بعرض الكتفين على منتصف المنصة، وإنزالهما للأسفل يزيد تركيز الفخذ الأمامي
• انزل حتى مدى مريح للركبة ثم ادفع بكامل القدم
• لا تفرد الركبتين بقوة في الأعلى', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Machine Squat / سكوات بالجهاز', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2bc0e9b7-d795-4e3e-9f64-3acb88f16a8e', 'Mid Leg Press', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/s9-zeWzPUmA', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.

ملاحظات مهمة:
• ضع القدمين في منتصف المنصة بعرض الكتفين
• أنزل المنصة حتى ثني الركبة نحو 90° دون أن يرتفع الحوض عن المقعد
• ادفع بكامل القدم، ولا تغلق الركبتين بقوة في الأعلى
• لا تضع اليدين على الركبتين للمساعدة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Leg Press / ضغط الأرجل', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('16403045-f2d5-475d-9d58-d5f98850f7ca', 'Quads Leg Press', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/A218isnErfM', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي، ثبت القدمين أسفل اللوح لاستهداف أكبر للكوادز.

ملاحظات مهمة:
• القدمان منخفضتان على المنصة وقريبتان من بعض قليلاً لزيادة تركيز الفخذ الأمامي
• الركبتان تتجهان فوق أصابع القدم أثناء النزول
• نزول بطيء بتحكم ثم دفع بدون ارتداد
• احذر ارتفاع الحوض وتقوّس أسفل الظهر عند النزول العميق', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Leg Press / ضغط الأرجل', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2efbaf3d-bfa5-4556-8dfd-403f47751ae4', 'Deficit Goblet Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/9719SO5zvpU?si=whohbunAsXkH3j6f', 'وقف باتساع اكتافك تقريبًا، ادفع ركبك للامام وانزل، انزل لأقصى حد تقدر عليه بدون ما يتقوس ظهرك السفلي.

ملاحظات مهمة:
• ثبّت الدمبل أمام الصدر والمرفقان للأسفل
• القدمان على منصة صغيرة (ديفيزيت) تزيد مدى الحركة، فانزل بتحكم ولا تتجاوز مدى كاحلك
• حافظ على الجذع مرفوعاً والكعبين ثابتين
• الخطأ الشائع: ارتداد القاع وانحناء الظهر', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9fadb633-7dd8-4917-ab41-4591ae41444f', 'Front Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'بار', 'متوسط', 'نادي', NULL, 'ثبت البار على الأكتاف، ادفع ركبك للامام وانزل.

ملاحظات مهمة:
• البار على مقدمة الكتفين مع مرفقين عاليين أمام الجسم
• الجذع مستقيم أكثر من السكوات الخلفي والركبتان للأمام
• شد البطن وانزل بتحكم
• الخطأ الشائع: سقوط المرفقين فيسقط البار للأمام', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2570306c-0eb0-4ef2-9d89-8f098ee22f37', 'V Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://www.youtube.com/watch?v=u_GSjH58s0g', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.

ملاحظات مهمة:
• ثبّت الظهر والأرداف على الجهاز واجعل القدمين على المنصة بعرض الكتفين
• انزل بتحكم حتى مدى مريح وادفع بالكعبين
• لا تفرد الركبتين بالكامل بعنف
• ابقِ الركبتين باتجاه أصابع القدم', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Machine Squat / سكوات بالجهاز', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('95b83ce8-8451-4852-9b91-032e4242935d', 'Resistance Band Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/6rE0IYlMPZA?si=goqtRTlR_W4HSGBN', 'ثبت الباند علي جوانب اكتافك، ادفع ركبك للأمام وإنزل.

ملاحظات مهمة:
• ثبّت الشريط تحت القدمين ومرره على الكتفين أو أمام الصدر
• الشد يزيد في أعلى الحركة، فادفع بتحكم ولا تقفز
• ركبتان باتجاه الأصابع وصدر مرفوع
• تأكد من سلامة الشريط وثباته', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c0485135-217a-4661-a87e-5672ca7aae37', 'Squat Smith Machine', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/oBwhrRcNWyM', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل.

ملاحظات مهمة:
• ضع القدمين أمام خط البار قليلاً ليتمكن الجذع من البقاء مستقيماً
• انزل حتى مدى مريح مع ثبات الكعبين
• اضبط حوامل الأمان قبل البدء
• الخطأ الشائع: وضع القدمين تحت البار تماماً فيضغط على الركبتين', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Machine Squat / سكوات بالجهاز', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5aeb8562-208b-48db-a12a-290cc985e2c6', 'Single Arm Cable Facing Away Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/6sO-pK7pTPs?feature=share', 'ملاحظات مهمة:
• بيد واحدة مع ثبات الجذع
• المرفق ثابت
• اثنِ بتحكم
• نزول بطيء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('09a08f9c-bcaf-4247-a40f-735bfd1c4370', 'Single Leg Press', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/ZYDTJaAM-gE', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.

ملاحظات مهمة:
• ضع قدماً واحدة على منتصف المنصة والأخرى بعيداً عنها
• لا يرتفع الحوض عن المقعد ولا ينحرف للجانب
• انزل حتى 90° تقريباً بتحكم
• لا تفرد الركبة بقوة في الأعلى', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Single-leg Press / ضغط رجل واحدة', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('19638d3b-c1a7-4526-bc3c-b845ed878a16', 'Drop Lunges', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/WH8lteLrMIs?si=61QSVA7iw_Z6Zr3p', 'تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.

ملاحظات مهمة:
• ارجع بقدم خلفاً بقوس خلف القدم الثابتة وانزل للأسفل بتحكم
• الجذع مستقيم والركبة الأمامية فوق القدم
• ادفع بكعب الرجل الأمامية للعودة
• ابدأ بوزن خفيف لإتقان التوازن', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c48b6150-d6de-4a64-9033-bfc2563758de', 'Beginner Lunges', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/QOVaHwm-Q6U', 'تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.

ملاحظات مهمة:
• خطوة طويلة بما يكفي لتبقى الركبة الأمامية فوق القدم
• انزل عمودياً حتى تقترب الركبة الخلفية من الأرض
• ادفع بكعب الرجل الأمامية
• يمكنك الإمساك بسند للتوازن في البداية', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('842420d6-23a2-4151-bafb-9ce8f69eac0a', 'Standing Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/rDRwAURNbzU', 'الحركة كلها بثني ومد الركبة

ملاحظات مهمة:
• قف بثبات وأمسك سنداً
• اثنِ الركبة بتحكم والجذع ثابت
• لا تتأرجح بالورك
• نزول بطيء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('880d2650-6e97-4355-a6ff-a05aaa2d7feb', 'Supported BSS', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/poBie3TTeGE?si=QSiMUYtcHhrmg8mx', 'وقف عند البنش او الستيب، ارفع رجلك وثبت اصابع قدمك على البنش، خذ خطوة وحدة للأمام برجلك الثانية ثم ابدأ التمرين، تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.

ملاحظات مهمة:
• ضع القدم الخلفية على مقعد واستند بيدك على ثابت
• انزل عمودياً والركبة الأمامية فوق القدم
• الجذع مائل قليلاً للأمام يزيد تفعيل الألوية
• لا تدفع بالقدم الخلفية', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Split Squat / سبليت سكوات', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('295f00b7-64bb-4318-871d-ffd0ec95b00f', 'Supported Reverse Lunge', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/WH8lteLrMIs?si=M9s9a7qOVvvyDm82', 'ملاحظات مهمة:
• ابقَ ممسكاً بسند خفيف للتوازن، وخطوة للخلف ثم نزول عمودي
• ادفع بكعب الرجل الأمامية للعودة
• حوض مستوٍ وجذع مستقيم
• الخطأ الشائع: الاتكاء على السند بدل الرجل', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f33375ab-3973-4261-8447-cdb9546484ba', 'Smith Machine Reverse Lunge', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/zAVYcwnlxrQ?si=M5HL4sG-bsYBFyDQ', 'استخدم ارتفاع بسيط مثل الستيب ، ارفع نفسك بالضغط علي الرجل المرفوعة بتحكم بدون قفز.

ملاحظات مهمة:
• اضبط البار بحيث تكون القدم الأمامية تحته أو أمامه قليلاً
• خطوة للخلف ونزول بتحكم
• ادفع بكعب الرجل الأمامية
• تأكد من حوامل الأمان', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('dd420495-3b5c-4ea1-a428-0288641ed801', 'Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/gtZ4AwZVtMI', 'اجلس وثبت ظهرك السفلي كويس، تأكد ان مسمار الارتفاع يكون بمستوى ركبتك، امسك المقابض لزيادة الثبات، إرفع الوزن اثبت ثانية فوق ثم انزل نزول كامل بتحكم.

ملاحظات مهمة:
• اضبط مسند الظهر لتكون الركبة عند محور الجهاز
• افرد الركبة بتحكم وثبّت لحظة في الأعلى
• نزول بطيء 2–3 ثوانٍ دون ارتداد الوزن
• تجنّب الأوزان الثقيلة جداً عند ألم الركبة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4b5eee23-8dd9-46c0-b208-0c27ada15af2', 'Band Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/hs7D3gDw3UM', 'اجلس وثبت ظهرك السفلي كويس وامسك الكرسي للثبات، اثبت ثانية فوق ثم انزل نزول كامل بتحكم.

ملاحظات مهمة:
• ثبّت الشريط خلف الكاحل وثبّت الطرف الآخر أمامك
• افرد الركبة ببطء ثم انزل بتحكم
• الشد يزداد في الأعلى فاضغط الفخذ لحظة
• تأكد من ثبات الشريط', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c9249e91-0b2c-4a60-bd79-757f89625a60', 'Sissy Squat', 'Quadriceps / الأمامية', '{"Adductors / الأفخاذ الداخلية"}', 'Knee Extension / مد الركبة', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://youtu.be/yONKTprKCDA', 'الورك ثابت طول الجولة والحركة كلها من مفصل الركبة، اذا توازنك يخرب عليك ادبل الوزن بيد واليد الثانية امسك فيها جدار او عصى

ملاحظات مهمة:
• ابدأ بسند وبمدى قصير فالتمرين متقدم على الركبة
• مِل بالجذع والركبتين للأمام وكعباك مرفوعان بخط واحد من الركبة للكتف
• انزل ببطء وارجع بتحكم
• تجنّب التمرين مع ألم الركبة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Sissy Squat / سيسي سكوات', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('eb4d9593-c0d1-4e42-bf40-d3bf0a55b1ad', 'Cable Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/ebjD98gZd8E', 'اجلس وثبت ظهرك السفلي كويس وامسك الكرسي للثبات، اثبت ثانية فوق ثم انزل نزول كامل بتحكم.

ملاحظات مهمة:
• ثبّت الكيبل على الكاحل واجلس بثبات
• افرد الركبة بتحكم ولا تتأرجح بالجذع
• شد الكيبل مستمر طوال الحركة
• نزول بطيء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('091b1055-b231-42be-a6c3-20663abb12fd', 'Standing Leg Extension', 'Quadriceps / الأمامية', '{"Core / البطن والكور"}', 'Knee Extension / مد الركبة', 'قوة', NULL, 'مبتدئ', NULL, NULL, 'ملاحظات مهمة:
• قف على رجل ثابتة وأمسك سنداً
• افرد الركبة بالرجل الأخرى بتحكم دون ميلان الجذع
• شد في الأعلى لحظة
• وزن خفيف مع حركة منضبطة', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/133/standing-leg-extension/', NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('68d8244b-07be-474a-9906-733a40728827', 'Bodyweight Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Lower back / أسفل الظهر"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'ملاحظات مهمة:
• القدمان بعرض الكتفين والذراعان أمامك للتوازن
• انزل بالورك للخلف وللأسفل والصدر مرفوع
• ركبتان باتجاه الأصابع والكعبان ثابتان
• ارتفع بدفع الأرض بكامل القدم', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/135/bodyweight-squat/', NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('683ad0dc-d865-4636-8bfe-cc686b2259a9', 'Cable Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/mBJXWg8ZOy0', 'اجلس على الكرسي وثبت ظهرك السفلي على المقعد تمامًا، ممكن تقدّم ظهرك العلوي وتمسك المقابض لزيادة الثبات، انزل لأقصى حد تقدر عليه وارفع لحد ما تستقيم ركبتك.

ملاحظات مهمة:
• ثبّت الكيبل على الكاحل ومرجع ثابت لليد
• اثنِ الركبة بتحكم والورك ثابت
• عودة بطيئة
• وزن مناسب دون ميلان الجذع', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('570b42f7-9479-421a-93d2-62d8269b97e9', 'DB Glutes Step Ups', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/GCnJiYJfboA?feature=share', 'استخدم ارتفاع يكون بحدود ارتفاع ركبتك أو أقل، ارفع نفسك بالضغط علي الرجل المرفوعة بتحكم بدون قفز.

ملاحظات مهمة:
• استخدم صندوقاً بارتفاع يجعل الركبة نحو 90°
• أمل الجذع قليلاً للأمام لتفعيل الألوية وادفع بكعب القدم التي على الصندوق
• انزل بتحكم دون ارتماء
• لا تدفع بالرجل الخلفية', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7b4b17b5-255b-45bc-89bc-ef3c2d602966', 'Supported Glutes Step Ups', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/ZKzoOkQALaY?si=-56txwBlxSSCQYJd', 'استخدم ارتفاع يكون بحدود ارتفاع ركبتك أو أقل، ارفع نفسك بالضغط علي الرجل المرفوعة بتحكم بدون قفز.

ملاحظات مهمة:
• أمسك سنداً خفيفاً للتوازن فقط
• اصعد بالرجل التي على الصندوق وجذع مائل قليلاً
• نزول بطيء ببطء
• لا تعتمد على اليد في الصعود', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b9a61c4f-41c3-4ea8-b13d-6245d29a215c', 'Cable Glutes Step Ups', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', NULL, 'ملاحظات مهمة:
• ثبّت الكيبل مناسباً للحزام أو اليدين
• اصعد بتحكم والجذع مستقيم مع إمالة بسيطة
• شد الكيبل لا يسحبك للخلف
• نزول بطيء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b0d9d87b-ccb1-4348-a20b-574ed353a97c', 'Single Arm Cable Facing In Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/I-197ZW9Ffo?si=M1Yq4R1PIpdZMXRx', 'ملاحظات مهمة:
• بيد واحدة مع ثبات الجذع
• المرفق للأمام قليلاً
• اثنِ بتحكم
• نزول بطيء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('805e0739-b8af-46ce-a865-b05bf92828a2', 'Glute Pushdown', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/8h2kZ64Sp5k?si=NLPf4tywxhDGY9em', 'تمسك بمقابض الجهاز، (كل ما زاد ارتفاع البنش زادت الصعوبة) + الطلوع والنزول يكون بواسطة القدم المرفوعة على البنش مو بالقدم اللي تحت، ارفع بتحكم الى أقصى ارتفاع تقدرعليه بدون ما يتقوس ظهرك السفلي، انزل لحد ما تقفل ركبتك تماما

ملاحظات مهمة:
• ثبّت جسمك على الجهاز وادفع بالقدم بتحكم
• ركّز على انقباض الألوية في نهاية الدفع
• لا تقوّس أسفل الظهر
• نزول بطيء دون ارتداد', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0605fdd6-d87c-4994-8f04-2c178f756131', 'Glute Max Kickbacks', 'Glutes / المؤخرة', '{}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/t5mwSx4uNMc?feature=share', 'ثبت الحبل على الكاحل، ارجع خطوة للخلف وانحني للامام قليلاً وتمسك بالكيبل لزيادة الثبات، اسحب للخلف مع انثناء بسيط بالركب.

ملاحظات مهمة:
• ثبّت الكيبل على الكاحل وأمسك بسند بيد
• ارفع الرجل للخلف من الورك دون تقوّس أسفل الظهر
• انقباض الألوية لحظة في الأعلى
• وزن خفيف مع حركة منضبطة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Kickback / ركلة خلفية', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0c58ee69-5d5d-4988-a212-69b98a7711ef', 'Smith Machine Kickback', 'Glutes / المؤخرة', '{}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/GR4ny80bmhM?si=WeZcWM1hyfoLElM2', 'ملاحظات مهمة:
• ضع القدم الخلفية على البار وأمسك السميث
• ادفع للأعلى وللخلف من الورك
• الحوض ثابت دون دوران
• نزول بطيء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Kickback / ركلة خلفية', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7dbb6674-656f-4e0a-8fd8-722ae77b30a3', 'Glute Medius Kickbacks', 'Abductors / مبعدات الفخذ', '{"Glutes / المؤخرة"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/kccsnZNbMFA?si=6c-VoB8Zsz8NxoyM', 'ثبت الحبل على الكاحل، ارجع خطوة للخلف وانحني للامام قليلاً وتمسك بالكيبل لزيادة الثبات، اسحب للخلف وللخارج مع انثناء بسيط بالركب.

ملاحظات مهمة:
• ثبّت الكيبل على الكاحل البعيد عن الكيبل وارفع الرجل للجانب والخلف
• حافظ على حوض ثابت دون دوران وجذع مستقيم
• انقباض لحظة في الأعلى
• وزن خفيف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Abduction Kickback / ركلة خلفية مع تبعيد', 'Hip Abduction + Hip Extension / تبعيد الورك + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b85db40f-596c-4aea-a097-98b6d2a775ba', 'Hip Thrusts Machine', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/0xfdeCBwoYw?si=HgJcNeB0a24gODkK', 'ممكن تسويه بالسميث مشين او البار الحر ، اختر بوكس او بنش يكون بمستوى اكتافك الخلفية وانت جالس، لما ترفع البار فوق المفروض ركبك تكون بنفس مستوى القدم.

ملاحظات مهمة:
• اضبط الجهاز ليكون الحزام على الحوض
• ادفع بالكعبين مع انقباض الألوية في الأعلى
• ذقن للأسفل قليلاً والأضلاع للأسفل
• لا تقوّس أسفل الظهر', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('64b7301a-fb4a-4e13-af46-e96e1790713a', 'Hip Thrusts', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/O0EoaP7gR1A?si=cGPZ8iIwM2mQjwSb', 'ملاحظات مهمة:
• ظهر الكتفين على مقعد والبار على الحوض (مع وسادة)
• ركبتان بزاوية نحو 90° في الأعلى
• ادفع بالكعبين وانقباض الألوية لحظة
• الخطأ الشائع: ثني مفرط لأسفل الظهر', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('66775356-b7f8-4ee4-966b-80bea35766b3', 'Glute Raise', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/X_kL_x4m77c', 'ثبت رجولك تحت، الاسفنجة تكون تحت الورك أعلى الفخذ مو على الورك مباشرة، امسك وزن بيدينك بذراع مستقيمة، ارفع وكأنك تبي تدخل القلوتس جوا الاسفنجة، بمجرد ما تنقبض مؤخرتك وقف لا ترفع أكثر.

ملاحظات مهمة:
• اضبط الجهاز بحيث يتحرك الورك بحرية
• ارفع الجسم من الورك حتى استقامة الجسم فقط
• لا تبالغ في تقوّس الظهر
• انقباض الألوية في الأعلى', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', '45° Hip Extension / بسط الورك على جهاز الظهر', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e224ef13-574b-4d36-af55-6210195f5b75', 'Single Hip Thrusts', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/ymg2AMDAwrY?si=fY8kBPTDYWRMHuAs', 'اختر بوكس او بنش يكون بمستوى اكتافك الخلفية وانت جالس، لما ترفع فوق المفروض ركبك تكون بنفس مستوى القدم، التمرين صعب طبيعي تواجه صعوبة بالبداية لذلك لا تستعجل باضافة الاوزان

ملاحظات مهمة:
• اعمل برجل واحدة والأخرى مرفوعة أو مثنية
• حافظ على حوض مستوٍ دون ميلان
• ادفع بالكعب وانقباض الألوية
• ابدأ بوزن الجسم قبل زيادة الحمل', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('45ed927a-45be-429c-a240-961ddd88c54e', 'DB Preacher', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/DZJNTb-zzn0?si=SwbdZ0O_0eTOET-5', 'ملاحظات مهمة:
• العضد على المسند ولا يرتفع
• اثنِ وانزل ببطء دون فرد المرفق بعنف
• وزن مناسب دون زخم
• رسغ محايد', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Preacher Curl / ثني على مسند', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f06a1813-4a99-4002-bae7-62005cd19953', 'Glute Press', 'Glutes / المؤخرة', '{}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', NULL, 'ملاحظات مهمة:
• ثبّت الجذع على الجهاز وادفع بالقدم بتحكم
• ركّز على انقباض الألوية وليس الظهر
• لا تفرد الركبة بقوة
• نزول بطيء', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/293/glute-press/', NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Kickback / ركلة خلفية', 'Hip Extension + Knee Extension / بسط الورك + مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0330e907-cd43-4c4a-865a-69e74bfefb54', 'Bulgarian Split Squat', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, NULL, 'ملاحظات مهمة:
• القدم الخلفية على مقعد خلفك والأمامية بمسافة كافية
• انزل عمودياً والركبة الأمامية فوق القدم
• مِل بالجذع قليلاً للأمام لتفعيل الألوية، وبشكل مستقيم للفخذ الأمامي
• ادفع بكعب الرجل الأمامية', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/366/bulgarian-split-squat/', NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Split Squat / سبليت سكوات', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('11900c94-e9a7-48ec-aaf9-8f7f4411d035', 'Sumo Deadlift', 'Hamstrings / الخلفية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://www.youtube.com/watch?v=cDlOSfu-zHY', 'وقف بفتحة أرجل واسعة بحيث الركب تكون خط مستقيم مع كعب القدم و اصابع الرجل باتجاه الخارج، البار بمنتصف القدم، شد ظهرك العلوي وادفع الارض برجولك واسحب البار للأعلى، وقف لما تنقبض مؤخرتك ولا تبالغ بتقفيل حوضك.

ملاحظات مهمة:
• وقفة واسعة وأصابع للخارج والقبضة داخل الركبتين
• ركبتان باتجاه الأصابع وظهر محايد
• ادفع الأرض بالقدمين وارفع الورك والكتفين معاً
• البار قريب من الجسم', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Deadlift / ديدلفت', 'Hip Extension + Knee Extension / بسط الورك + مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e2e39a72-2c7d-4d55-b28f-bf7e588afb15', 'Conventional Deadlift', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/GxsLrTzyGUU', 'وقف باتساع اكتافك أو أوسع شوي، البار بمنتصف القدم، شد ظهرك العلوي وادفع الارض برجولك واسحب البار للأعلى، وقف لما تنقبض مؤخرتك ولا تبالغ بتقفيل حوضك.

ملاحظات مهمة:
• القدمان بعرض الحوض والبار فوق منتصف القدم
• شد البطن وثبّت الظهر محايداً قبل الرفع
• ادفع الأرض ثم افرد الورك
• البار على الجسم ولا ينحني الظهر في أي مرحلة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Deadlift / ديدلفت', 'Hip Extension + Knee Extension / بسط الورك + مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('af675da9-1848-4642-a14c-45fb9901473d', 'Supine Cable Hamstring Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/sDCc1F5J8XA?si=Fi3D39aJogrB5ihd', 'الركبة ثبت مكانها، اسحب الحبل لاقصى حد تقدر عليه واترك رجلك تستقيم تمامًا في الانبساط.

ملاحظات مهمة:
• استلقِ على الظهر وثبّت الكيبل على الكاحل
• اسحب الكعب نحو الأرداف مع بقاء الحوض على الأرض أو مرفوعاً حسب الأداء
• تحكم في العودة
• لا تقوّس الظهر', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('16789399-9d25-42d1-a2cf-4a9f015fba92', 'BB RDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/mZxxJEncsyw', 'وقف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، انزل وادفع مؤخرتك لآخر شي تقدر عليه للخلف وكأنك بتلمس جدار خلفك مع انثناء بسيط بالركب

ملاحظات مهمة:
• ثني بسيط ثابت في الركبتين والبار قريب من الساقين
• ادفع الورك للخلف حتى تمدد الخلفية ثم عُد بدفع الورك للأمام
• ظهر محايد وكتفان للخلف
• لا تنزل أبعد من مدى مرونتك', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f22dbb60-83b9-470e-8e71-a4d1986d5114', 'DB RDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/RApyTtH6qAo', 'وقف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، انزل وادفع مؤخرتك لآخر شي تقدر عليه للخلف وكأنك بتلمس جدار خلفك مع انثناء بسيط بالركب

ملاحظات مهمة:
• الدمبلان قريبان من الساقين
• ادفع الورك للخلف وليس انحناء الظهر
• انزل حتى تمدد الخلفية ثم ارتفع بدفع الورك
• كتفان للخلف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('87ceafcd-e58f-43ee-bce8-d10986d579de', 'SM SLDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/0cB0_SzqgBU', 'ملاحظات مهمة:
• القدمان تحت البار والركبتان شبه مفرودتين
• ادفع الورك للخلف والبار على الساقين
• ظهر محايد وانزل حتى تمدد الخلفية
• حوامل أمان', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c0b31b2a-87dd-4c6e-b18b-ea1aa59de382', 'SLDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/RApyTtH6qAo', 'قف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، ابدأ الحركة بدفع مؤخرتك للخلف والأعلى وانزل

ملاحظات مهمة:
• ركبتان شبه مفرودتين دون قفل
• الحركة من الورك وظهر مستقيم
• انزل حتى تمدد الخلفية
• ارجع بدفع الورك للأمام', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cbd39c91-42b3-4011-9687-fb55c24a0e1b', 'Single DB SLDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/U3prDlAbJDw?si=MRSBcSIcf9M-WQBH', 'قف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، ابدأ الحركة بدفع مؤخرتك للخلف والأعلى وانزل

ملاحظات مهمة:
• دمبل بيد وثبات على رجل مع ثني بسيط
• ادفع الورك للخلف والرجل الأخرى تمتد خلفك
• حوض مستوٍ دون دوران
• استعن بسند عند صعوبة التوازن', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4b06bb55-135b-4651-994c-54d74bb4cf4d', 'Good Morning', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/f23vXjoG2e8?si=9rkfUF_6XUEcQ3Xs', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع مؤخرتك لأقصى قدر تقدر عليه وكأنك بتلمس جدار خلفك.

ملاحظات مهمة:
• البار على الظهر مع ثني بسيط في الركبتين
• ادفع الورك للخلف بظهر محايد حتى تمدد الخلفية
• ارجع بدفع الورك للأمام
• وزن خفيف جداً في البداية', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Good Morning / قود مورنينق', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fd40af84-3e11-47ce-b948-e5d18f8d09f9', 'Seated Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/o_J6MWyt5jM', 'اجلس على الكرسي وثبت ظهرك السفلي على المقعد تمامًا، انزل لأقصى حد تقدر عليه وارفع لحد ما تستقيم ركبتك.

ملاحظات مهمة:
• اضبط محور الركبة مع محور الجهاز وثبّت المسند على الفخذ
• اثنِ الركبة بتحكم وثبّت لحظة
• عودة بطيئة
• لا ترفع الورك عن المقعد', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3a534df6-57c6-4501-97fd-4079b5b1b8eb', 'Band Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/I-HTMUrJnxs', 'ثبت الباند فوق الكعب، اجلس على طرف البنش وتمسك بيدينك لزيادة الثبات، اسحب الحبل لاقصى حد تقدر عليه واترك رجلك تستقيم تمامًا في الانبساط.

ملاحظات مهمة:
• ثبّت الشريط على الكاحل ومرجع ثابت
• اثنِ الركبة بتحكم دون تمايل
• عودة بطيئة
• تأكد من ثبات الشريط', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9d689e94-6b9c-4aa1-ba35-350acdb1dbf8', 'Lying Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/vl5nUdE9mWM', 'حوضك ثابت على البنش، ارفع الوزن بثني ومد الركبة بدون ما يرتفع حوضك عن الكرسي

ملاحظات مهمة:
• استلقِ بحيث تكون الركبة عند محور الجهاز
• اثنِ الركبة بتحكم دون رفع الحوض
• انقباض لحظة وعودة بطيئة
• لا تقوّس أسفل الظهر', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a83dfd53-0bbf-4e07-9506-946af2130334', 'DB Lying Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/ZHlBSI6JPsA?si=SpBiHxluwrYE8CTP', 'ركبك ثابته على الارض، ارفع الوزن بثني ومد الركبة بدون ما يرتفع حوضك

ملاحظات مهمة:
• ثبّت الدمبل بين القدمين
• اثنِ الركبة بتحكم دون رفع الحوض
• وزن خفيف مع سيطرة
• نزول بطيء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('60f5e640-ffc7-461d-b59f-a921efefb213', 'Stability Ball Hamstring Curl', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة"}', 'Knee Flexion / ثني الركبة', 'قوة', 'كرة سويسرية', 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• ارفع الحوض ثم اسحب الكرة نحو الأرداف بالكعبين
• حافظ على الحوض مرفوعاً دون تقوّس
• عودة بطيئة
• تحكم في الكرة', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/59/stability-ball-hamstring-curl/', NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Bridge Curl / ثني الركبة مع رفع الورك', 'Knee Flexion + Hip Extension / ثني الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fc4dfff3-20ce-4a0c-9c9e-0822a99f6a83', 'Hip Hinge', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', NULL, 'مبتدئ', NULL, NULL, 'ملاحظات مهمة:
• وزن الجسم والعصا على الظهر لمراقبة الاستقامة
• ادفع الورك للخلف مع ثني بسيط للركبتين
• ظهر محايد
• لا تثنِ العمود الفقري', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/33/hip-hinge/', NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Hinge Drill / تمرين مفصلة الورك', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b0e28e1d-38c5-45f8-b025-d6f069f2a0e2', 'TRX Hamstrings Curl', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة"}', 'Knee Flexion / ثني الركبة', 'قوة', 'TRX', 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• القدمان في الحزام والحوض مرفوع
• اثنِ الركبتين بالسحب نحو الأرداف مع بقاء الحوض مرتفعاً
• عودة بتحكم
• شد البطن لتجنب تقوّس الظهر', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/86/trx-reg-hamstrings-curl/', NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Bridge Curl / ثني الركبة مع رفع الورك', 'Knee Flexion + Hip Extension / ثني الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('81a993df-a0dc-498d-b598-eb434eafe5ca', 'Flat DB Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/xphvjGDZeYE', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا

ملاحظات مهمة:
• ثبّت لوحي الكتف للخلف وللأسفل على المقعد
• انزل الدمبلين بتحكم حتى مستوى الصدر، والمرفقان بزاوية نحو 45–70°
• ادفع للأعلى دون رفع الكتفين
• حافظ على قدمين ثابتتين وأرداف على المقعد', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4fa9f03f-8126-41f0-8172-3492d97fe8ff', 'DB Floor Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/UBmpZ7l5Nlk?si=kDcN-ueaTFxfKtbr', 'ملاحظات مهمة:
• استلقِ على الأرض وانزل حتى لمس العضد للأرض بخفة
• ادفع للأعلى دون ارتداد
• لوحا الكتف للخلف
• مدى أقصر من المقعد وهو آمن للكتف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e3af2027-c6f8-49ef-b6c3-6c1c1159e73d', 'Flat Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/vcBig73ojpE', 'استلق على بنش،القبضة بنفس مستوى الاكتاف أو أوسع قليلًا، قوّس ظهرك العلوي قليلاً، انزل لين تلمس صدرك واثبت ثانية ثم ارفع.

ملاحظات مهمة:
• العينان تحت البار وقبضة أوسع قليلاً من الكتفين
• ثبّت لوحي الكتف للخلف وللأسفل وصدر مرفوع
• انزل بتحكم إلى أسفل الصدر وادفع بخط ثابت
• استعن بمساعد أو حوامل أمان عند الأوزان الثقيلة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a46b38f8-0a90-405b-8165-ed4bcefc7e7d', 'Machine Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/pOCRC2kpxB8?si=02xGtrfPjiYpspMv', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا

ملاحظات مهمة:
• اضبط المقعد ليكون المقبض بمستوى منتصف الصدر
• الكتفان للخلف والظهر ملتصق بالمسند
• ادفع دون قفل المرفقين وانزل بتحكم
• لا ترفع الكتفين', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7e09cc43-9807-4cf7-b006-47a55b0fead6', 'Feet Up Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/HrehfM1dmBE', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا

ملاحظات مهمة:
• القدمان مرفوعتان على المقعد لتقليل تقوّس الظهر
• ثبّت الظهر على المقعد وانزل بتحكم
• وزن أخف من الضغط العادي
• حافظ على لوحي الكتف للخلف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('88ac5ffe-f7ae-4273-b70b-e4d241c93c33', 'Torso Elevated Push Up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/noaPB7u4_CU', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا

ملاحظات مهمة:
• اليدان على مرتفع (مقعد) لتخفيف الحمل
• جسم مستقيم من الرأس للكعب والبطن مشدود
• انزل بالصدر نحو المرتفع والمرفقان بزاوية نحو 45°
• لا تدلِّ الورك', 'تصنيف فرعي: اليدان مرفوعتان؛ زاوية الضغط بالنسبة للجذع تشبه الضغط المائل لأسفل رغم تسميته الشائعة Incline Push-up — يحدده المدرب', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Decline Press / ضغط مائل لأسفل', 'Horizontal Adduction + Shoulder Extension / تقريب أفقي + مد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8f485271-45e7-4983-a3e5-90c85e2549bb', 'Push Up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://youtu.be/WDIpL0pjun0?si=utydS_A8QfRIJtJm', 'ملاحظات مهمة:
• اليدان بعرض الكتفين أو أوسع قليلاً والجسم خط مستقيم
• انزل بالصدر حتى قرب الأرض والمرفقان بزاوية 45°
• ادفع دون تدلي الورك أو رفعه
• شد البطن والألوية', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a8af9d3c-8d49-4fce-818e-65dcb43f8031', 'Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://www.youtube.com/watch?v=JvOJdUtx6UQ', 'استلق على بنش،القبضة بنفس مستوى الاكتاف أو أوسع قليلًا، قوّس ظهرك العلوي قليلاً، انزل لين تلمس صدرك واثبت ثانية ثم ارفع.

ملاحظات مهمة:
• العينان تحت البار وقبضة أوسع قليلاً من الكتفين
• ثبّت لوحي الكتف وصدر مرفوع، وقدمان ثابتتان
• انزل بتحكم وادفع بخط ثابت
• حوامل أمان أو مساعد للأوزان الثقيلة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ed2dfc56-bd57-4372-8214-cf3539e68297', 'Paused Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://www.youtube.com/shorts/Q3GmnmJISwE', 'استلق على بنش،القبضة بنفس مستوى الاكتاف أو أوسع قليلًا، قوّس ظهرك العلوي قليلاً، انزل لين تلمس صدرك واثبت 3 ثواني ثم ارفع.

ملاحظات مهمة:
• انزل بتحكم واثبت ثانية على الصدر دون استرخاء ثم ادفع
• الوزن أخف من الضغط العادي
• ثبّت لوحي الكتف طوال التوقف
• لا ترتد بالبار', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d9b17593-b7e0-4dd6-88e7-c70047fc8787', 'Incline Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/0G2_XV7slIg', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا

ملاحظات مهمة:
• اضبط الميل بزاوية معتدلة (نحو 30°)
• ثبّت لوحي الكتف وانزل بتحكم إلى أعلى الصدر
• لا ترفع الأرداف
• لا تجعل الميل شديداً فيتحول التمرين لكتف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Incline Press / ضغط مائل لأعلى', 'Shoulder Flexion + Horizontal Adduction / ثني الكتف + تقريب أفقي', 'Incline Press / ضغط مائل لأعلى', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('26d3dd01-5df0-4888-983c-5d9f0c31f321', 'Smith Machine Incline Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/EeLLZMdg6zI?si=UVsgFN7jhXMm0vW3', 'ملاحظات مهمة:
• ضع المقعد بحيث ينزل البار على أعلى الصدر
• ثبّت لوحي الكتف وانزل بتحكم
• اضبط الحوامل
• لا ترفع الأرداف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Incline Press / ضغط مائل لأعلى', 'Shoulder Flexion + Horizontal Adduction / ثني الكتف + تقريب أفقي', 'Incline Press / ضغط مائل لأعلى', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0eb660cd-9662-4ec1-b76d-01ec49ebf520', 'Cable Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/tAILewhtCb0', 'اجلس على بنش انكلاين، اضبط الكيبل بمستوى صدرك تقريبا، ادفع الوزن للأمام باتجاه الداخل، احرص ان كوعك ما يكون بنفس ارتفاع كتفك

ملاحظات مهمة:
• اضبط الكيبل بمستوى الصدر أو أعلى حسب الميل
• قف أو اجلس بثبات وادفع للأمام مع تقريب اليدين
• تحكم في العودة
• الجذع ثابت دون ميلان', 'تصنيف فرعي: التعليمات تذكر بنش انكلاين، وتصنيف المصدر iso_push_chest — يُحسم بين Incline Press وعزل الصدر', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Incline Press / ضغط مائل لأعلى', 'Shoulder Flexion + Horizontal Adduction / ثني الكتف + تقريب أفقي', 'Incline Press / ضغط مائل لأعلى', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('45b4aabf-82f6-4f3a-9d68-5ee7ce66aaa3', 'Sternal Cable Press Around', 'Chest / الصدر', '{}', 'Horizontal Push / دفع أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/y8XQibXDnNo', 'اضبط الكيبل بمستوى صدرك تقريبا، حافظ على ذراعك قريبة من جسمك،ادفع الحبل للأمام باتجاه الداخل.

ملاحظات مهمة:
• ادفع بتقريب اليدين أمام منتصف الصدر
• لا تغلق المرفقين بقوة
• ركّز على انقباض الصدر
• الجذع ثابت وكتفان للخلف', 'تصنيف فرعي: حركة مختلطة بين الضغط والـ Fly — يُحسم بين Flat Press وعزل الصدر', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Press-around / ضغط مع تقريب', 'Horizontal Adduction + Elbow Extension / تقريب أفقي + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('22f24b3b-d89b-43d1-b7fd-71f662f9c727', 'Machine Chest Fly', 'Chest / الصدر', '{}', 'Horizontal Adduction (Fly) / تقريب أفقي للكتف (فلاي)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', NULL, 'ملاحظات مهمة:
• اضبط المقعد ليكون المرفقان بمستوى الصدر
• ثني بسيط ثابت في المرفقين
• افتح حتى تمدد مريح ثم ضم بقوة
• لا ترفع الكتفين', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Chest Isolation / عزل الصدر', 'Horizontal Adduction / تقريب أفقي للكتف', 'Chest Isolation / عزل الصدر', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4e51bd50-32ed-4679-a889-c103a133f459', 'Bar Cable Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/NhD3h6RG2TA?si=SoyNTIGB-nY2KiXl', 'ملاحظات مهمة:
• استخدم القضيب أمام الصدر والكيبل بالمنتصف
• ادفع بتحكم دون ميلان الجذع
• الكتفان للخلف
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0241376f-fd2d-4f06-8ad1-ca50abaec6e3', 'DB Chest Supported Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/H75im9fAUMc', 'ثبت صدرك على الكرسي، فتحة واسعة، واسحب الدمبل باتجاه الورك.

ملاحظات مهمة:
• صدرك على مقعد مائل لتثبيت الجذع
• اسحب الدمبلين نحو الجانبين مع ضم لوحي الكتف
• لا ترفع الصدر عن المقعد
• انزل ببطء حتى تمدد', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8f053287-d454-47a6-9611-4ffab20d3413', 'Cable Chest Fly', 'Chest / الصدر', '{"Shoulders / الأكتاف"}', 'Horizontal Adduction (Fly) / تقريب أفقي للكتف (فلاي)', 'قوة', 'كيبل', 'مبتدئ', 'نادي', NULL, 'ملاحظات مهمة:
• ضع الكيبل بمستوى الكتف أو أعلى وخطوة أمامية للثبات
• ثني بسيط ثابت في المرفقين
• قرّب اليدين أمام الصدر بقوس
• لا تنزل اليدين أسفل مستوى الصدر', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/160/standing-chest-fly/', NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Chest Isolation / عزل الصدر', 'Horizontal Adduction / تقريب أفقي للكتف', 'Chest Isolation / عزل الصدر', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f281e3d1-51d5-4c95-8991-bec339b61380', 'Bent Knee Push-up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'ملاحظات مهمة:
• الركبتان على الأرض والجسم خط من الركبة للرأس
• انزل بالصدر حتى قرب الأرض والمرفقان 45°
• ادفع بدون تدلي الحوض
• تدرّج لاحقاً للضغط الكامل', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/13/bent-knee-push-up/', NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e17d2298-55b7-43e5-a836-e05b6179d075', 'Stability Ball Push-Up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس","Core / البطن والكور"}', 'Horizontal Push / دفع أفقي', 'قوة', 'كرة سويسرية', 'متوسط', 'منزل', NULL, 'ملاحظات مهمة:
• اليدان على الكرة أو القدمان عليها حسب الصعوبة
• حافظ على جسم مستقيم وثبات الكرة
• نزول بتحكم
• الخطأ الشائع: تمايل الكرة وتدلّي الورك', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف فرعي: الزاوية تعتمد على موضع الكرة (تحت اليدين أو القدمين) — غير محدد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/63/stability-ball-push-up/', NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9cba8e1e-dccb-445d-b8da-f55fa0832de8', 'Cable Reardelt Rows', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/uIdXVGjcfFE', 'ثبت نفسك بالكرسي، فتحة واسعة، الكيبل بمستوى اسفل صدرك، واسحب لما تنقبض اكتافك الخلفية.

ملاحظات مهمة:
• اجلس أو قف وأمسك الحبل بقبضة والمرفقان للجانبين بمستوى الكتف
• اسحب نحو الوجه والمرفقان عاليان مع ضم لوحي الكتف
• لا تتمايل بالجذع
• وزن خفيف مع انقباض لحظة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Wide-grip Row / تجديف بقبضة واسعة', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8d7df314-1967-420a-b81a-3c171670e960', 'DB Triceps Extensions', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/d7SXlU5HkYM?si=WuuPa9-yeByaP5sI', 'ملاحظات مهمة:
• مرفقان قريبان من الرأس وثابتان
• انزل خلف الرأس بتحكم ثم افرد المرفقين
• شد البطن وجذع ثابت
• وزن مناسب', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Overhead Extension / مد فوق الرأس', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('622587b3-c23f-49c8-81c9-24021af114dc', 'DB Chest Supported Reardelt Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/x0v6GWYzI18?si=-jDt3D-ARIHouHjp', 'ثبت صدرك على الكرسي، فتحة واسعة، واسحب لما تنقبض اكتافك الخلفية.

ملاحظات مهمة:
• صدرك على مقعد مائل والدمبلان للأسفل
• ارفع المرفقين للجانبين بمستوى الكتف
• لا ترفع الرقبة ولا تستخدم الزخم
• وزن خفيف مع انقباض الكتف الخلفي', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Wide-grip Row / تجديف بقبضة واسعة', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e4c6a7b8-69d7-4a34-920f-c2d983232a0a', 'Bent-over Barbell Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'بار', 'متوسط', 'نادي', NULL, 'ادفع مؤخرتك للخلف واثني ركبك، قبضتك بنفس مستوى اكتافك، اسحب لما تنقبض عضلات الظهر.

ملاحظات مهمة:
• انحنِ من الورك حتى جذع شبه موازٍ للأرض وظهر محايد
• اسحب البار نحو أسفل الصدر والمرفقان قريبان من الجسم
• ثبّت الجذع ولا ترفعه لتعويض الوزن
• الخطأ الشائع: تقوّس الظهر وتأرجح الجذع', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fc51784e-1d38-4e28-8a19-23d8b7ad38bd', 'Cable Reardelt Fly', 'Shoulders / الأكتاف', '{"Rotator cuffs / الكفة المدورة"}', 'Shoulder Rear Pull / سحب خلفي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/bkejPHrPkmA?si=-O8q_5e72udoPRiY', 'ملاحظات مهمة:
• مرفقان مثنيان قليلاً وثابتان
• افتح الذراعين للجانبين بمستوى الكتف باتجاه الخلف
• لا تتمايل بالجذع
• وزن خفيف وانقباض لحظة', 'تصنيف فرعي: حركة Fly (تبعيد أفقي للكتف) وليست سحباً أفقياً أو عمودياً', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Rear Delt Fly / فتح خلفي', 'Horizontal Abduction / تبعيد أفقي للكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d507596e-004e-478a-a0f3-986b5d095468', 'Head Supported Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/c6lkPMhuyFA?si=eUivRGYSi0W7PmVe', 'راسك ثابت على البنش بدون أي ميلان بالرقبة.

ملاحظات مهمة:
• الجبهة أو الصدر على المسند لتثبيت الجذع
• اسحب بالمرفقين وضم لوحي الكتف
• لا ترفع الرقبة
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e7946c1f-1043-4418-8c2c-f74b5eda3833', 'Single Arm Dumbbell Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/QBjaGx8mS1o', 'اسحب باتجاه الورك.

ملاحظات مهمة:
• ركبة ويد على المقعد وظهر مسطح
• اسحب الدمبل نحو الورك والمرفق قريب من الجسم
• لا تدوّر الجذع
• انزل حتى تمدد لوح الكتف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3cf8c2e2-6cd7-4ddd-aa2c-b09fe6e6dab9', 'Single Arm Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/Qn_mHGObb8E?si=IZ0q9_tseiRIMtcs', 'اسحب باتجاه الورك.

ملاحظات مهمة:
• ثبات القدمين والجذع
• اسحب المقبض نحو الخصر مع ضم لوح الكتف
• لا تميل أو تدوّر الجذع
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2f08a737-e5b5-4816-8db7-28ce637e0636', 'Chin Ups', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متقدم', 'نادي', 'https://youtube.com/shorts/aV9Mz9nCsMw?si=E_ullJojGO_7srW2', 'ملاحظات مهمة:
• قبضة معكوسة بعرض الكتفين
• اسحب المرفقين للأسفل وللخلف حتى الذقن فوق القضيب
• تعلّق كامل في الأسفل
• تجنّب التأرجح', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('57b9b0d1-d123-4862-8dbb-991303936849', 'Chest Supported Machine Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/BZrdEAiR2Xs?si=WhKaSGhR0gKeeies', 'ملاحظات مهمة:
• اضبط المقعد ليكون الصدر على المسند والذراعان ممدودتان
• اسحب المقبضين وضم لوحي الكتف
• لا ترفع الكتفين
• عودة بتحكم', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('32388468-af52-4ce5-8aec-3987d523bce7', 'T-Bar Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/6OtcNinT0HM?si=UPfYyypfZCaN9tTA', 'ملاحظات مهمة:
• ظهر محايد وانحناء من الورك
• اسحب نحو الصدر والمرفقان قريبان من الجسم
• لا تدور الجذع
• حافظ على قبضة ثابتة وركبتين مثنيتين قليلاً', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('265b7f22-e217-4bf9-8cb9-76f4810a897e', 'Lats Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/CQkT-W18N5g', 'الكيبل بنفس مستوى بطنك، اسحب باتجاه الورك.

ملاحظات مهمة:
• اسحب المقبض نحو أسفل البطن وليس الصدر
• المرفقان قريبان من الجسم وصدر مرفوع
• لا تميل للخلف كثيراً
• تمدد اللاتس في العودة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Lat-focused Row / تجديف لاتس', 'Shoulder Extension / مد الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b7b6b6f6-b290-400a-9b38-3a00f4502630', 'Upperback Pulldowns', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/bNmvKpJSWKM?si=hy5HgBDAHkzFHcvv', 'ملاحظات مهمة:
• اسحب القضيب نحو أعلى الصدر مع ضم لوحي الكتف والمرفقان للجانبين
• جذع مائل قليلاً للخلف دون تأرجح
• لا ترفع الكتفين
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Wide-grip Pulldown / سحب علوي بقبضة واسعة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c8460171-1cc0-41b0-bfc0-a388eb4efe51', 'Straight Arm Pulldown', 'Back & Lats / الظهر واللاتس', '{}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/hAMcfubonDc?si=ocU_a8VQ4VzZnTg3', 'ملاحظات مهمة:
• ذراعان شبه مستقيمتين
• اسحب القضيب للأسفل نحو الفخذين بحركة من الكتف
• شد البطن ولا تقوّس الظهر
• شعور بتمدد اللاتس في الأعلى', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Straight-arm Pull / سحب بذراع مستقيمة', 'Shoulder Extension + Scapular Depression / مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a0cc0922-38b1-4bef-b9ce-a9efdea2e0f8', 'DB Y Raises', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/lXp16YozXgk', 'ثبت صدرك على البنش،ارفع الوزن على شكل Y.

ملاحظات مهمة:
• ارفع الذراعين بشكل Y أمام الجسم والإبهام للأعلى
• وزن خفيف جداً
• ثبّت الصدر ولا تتمايل
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Y Raise (Scaption) / رفع Y بمستوى لوح الكتف', 'Shoulder Elevation in Scapular Plane (Scaption) / رفع الذراع بمستوى لوح الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d91aff09-23ed-4727-b6be-763d9aae3ff5', 'DB Pullover', 'Back & Lats / الظهر واللاتس', '{"Chest / الصدر","Triceps / الترايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/ieFKuQAGYIA?si=uwqyrbKhBL6Id3_-', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.

ملاحظات مهمة:
• استلقِ على مقعد والدمبل بكلتا اليدين فوق الصدر
• انزل خلف الرأس بذراعين شبه مستقيمتين حتى تمدد مريح
• عُد بالسحب بالكتف
• لا تقوّس الظهر ولا تنزل أكثر من مدى كتفك', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Straight-arm Pull / سحب بذراع مستقيمة', 'Shoulder Extension + Scapular Depression / مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('96e759bc-7b51-423c-94db-fbd79692c8a5', 'Band Lat Pulldown', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/5R0RYj3Y9Ro', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.

ملاحظات مهمة:
• ثبّت الشريط عالياً واسحب نحو أعلى الصدر
• المرفقان للأسفل وللجانبين
• لا تتمايل بالجذع
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('66bb6b0b-1ce4-4548-87d1-6951e9a266e4', 'Band Assisted Pull Ups', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://youtu.be/Ks8ah-8P1b0', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.

ملاحظات مهمة:
• ضع الشريط على الركبة أو القدم لتخفيف الوزن
• ابدأ من تعلّق كامل واسحب حتى الذقن فوق القضيب
• تجنّب التأرجح
• انزل ببطء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e1fbf528-b0e8-46bc-b574-f7f672affad4', 'Pull Ups', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متقدم', 'نادي', 'https://youtu.be/x3NPAxiMRPw?si=Mwg6U1Df5aIFpjKB', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.

ملاحظات مهمة:
• قبضة أوسع قليلاً من الكتفين وتعلّق كامل بكتفين منخفضين
• اسحب المرفقين نحو الجنبين حتى الذقن فوق القضيب
• تجنّب التأرجح واللعب بالرأس
• انزل ببطء 2–3 ثوانٍ', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a2bf7471-75ae-446c-95bc-9b0b6707b385', 'Negative Pull-Up', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://youtu.be/gbPURTSxQLY?si=TvQF5zDWfU_rR1Ax', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر، نزول بطيء.

ملاحظات مهمة:
• اصعد بقفزة أو بمساعدة ثم انزل ببطء 3–5 ثوانٍ
• تحكم كامل حتى تعلّق كامل
• الكتفان منخفضان
• لا تسقط في النهاية', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('57a98fe9-e604-4f7f-ae69-e5c46c1527cf', 'Neutral Grip Lat Pulldown', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/kVB6SlEyjQM', 'القبضة بنفس مستوى الكتف، اسحب باتجاه اعلى الصدر.

ملاحظات مهمة:
• قبضة محايدة والمقبض قريب
• اسحب نحو أعلى الصدر والمرفقان للأسفل
• جذع مائل قليلاً دون تأرجح
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('82aa0c7e-d6c7-4847-8771-940b384b65b4', 'Single Lats Pulldown', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/Qed5O9toqT8', 'اجلس على بنش واسند صدرك عليه، ارجع للخلف قليلا بحيث ان الكيبل ما يكون فوق راسك مباشرة، اسحب الكوع باتجاه الورك.

ملاحظات مهمة:
• اعمل بيد واحدة مع ثبات الجذع
• اسحب المرفق نحو الجنب
• لا تدوّر الجذع
• عودة بطيئة حتى تمدد اللاتس', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('65b69690-bbd0-4f96-b1e3-ae1a79864fa2', 'Band Assisted Chin Ups', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://youtu.be/i0yC-0YK6Uk?si=gNX26kIFz_THnR4p', 'مسكة ضيقة بمستوى الأكتاف، كل ما كان الحبل خفيف زادت المقاومة وزدات صعوبة التمرين لذلك ابدأ بحبل ثقيل وخفف كل ما تحسن مستواك.

ملاحظات مهمة:
• قبضة معكوسة وشريط مساعد
• اسحب حتى الذقن فوق القضيب
• تحكم بالنزول
• لا تتأرجح', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8b05b931-4886-4fa4-a099-f43977f76b58', 'Kneeling Lat Pulldown', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', NULL, 'متوسط', NULL, NULL, 'ملاحظات مهمة:
• اركع بثبات وجذع مستقيم
• اسحب الكيبل نحو أعلى الصدر أو الخصر بحسب الاتجاه
• لا تجلس على الكعبين
• عودة بطيئة', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/35/kneeling-lat-pulldown/', NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b7a7e77b-e387-4f7e-891d-134e0a655ea7', 'TRX Back Row', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس","Core / البطن والكور","Lower back / أسفل الظهر"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'TRX', 'متوسط', 'منزل', NULL, 'ملاحظات مهمة:
• جسم مستقيم ومائل للخلف حسب الصعوبة
• اسحب الصدر نحو المقابض وضم لوحي الكتف
• الورك لا يتدلى
• عودة بطيئة', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/84/trx-reg-back-row/', NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('774c931d-1a05-4127-8786-0da36ec1e2d3', 'Shrug', 'Back & Lats / الظهر واللاتس', '{"Trapezius / الترابيس"}', 'Scapular Elevation / رفع لوح الكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, 'ملاحظات مهمة:
• ارفع الكتفين مباشرة نحو الأذنين دون تدوير
• ثبّت لحظة في الأعلى وانزل بتحكم
• ذراعان مستقيمتان
• لا تحرك الرقبة للأمام', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف فرعي: رفع الأكتاف (Shrug) ليس نمط سحب أفقي أو عمودي', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/72/shrug/', NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Shrug / هز الكتفين', 'Scapular Elevation / رفع لوح الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('07621952-d77b-452e-a101-4fab913a065f', 'DB Shoulder Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/NKeyUrDYqPk', 'قوّس ظهرك العلوي قليلاً، الكوع قريب من الجسم، النزول الى مستوى الاكتاف

ملاحظات مهمة:
• اجلس بظهر مسنود وانزل الدمبلين حتى مستوى الأذنين
• ادفع للأعلى بخط فوق الكتفين
• لا تغلق المرفقين بعنف
• لا تبالغ في تقوّس الظهر', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e76fde01-b89d-48d2-a96b-fdc126fb97df', 'DB Standing Shoulder Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/wO0l5jW2NtQ?si=MVvS4F_7iFS8ji9R', 'ملاحظات مهمة:
• قف بثبات وشد البطن والألوية
• ادفع للأعلى دون ميلان الجذع للخلف
• انزل حتى الأذنين
• وزن مناسب دون زخم', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f031a9df-5a34-46ac-95e4-b0e5dddc9b35', 'Machine Shoulder Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/3R14MnZbcpw', 'قوّس ظهرك العلوي قليلاً، الكوع قريب من الجسم، النزول الى مستوى الاكتاف

ملاحظات مهمة:
• اضبط المقعد ليكون المقبض بمستوى الكتف
• الظهر ملتصق بالمسند
• ادفع دون رفع الكتفين
• عودة بتحكم', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('76008ff3-d918-45c5-8049-cd5331adf0bd', 'BB Overhead Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/_RlRDWO2jfg', 'ملاحظات مهمة:
• قبضة أوسع قليلاً من الكتفين
• شد البطن والألوية وادفع بخط مستقيم
• حرّك الرأس للخلف ثم للأمام عند مرور البار
• لا تقوّس أسفل الظهر', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cdfac5b4-7372-48cb-9eb0-acde9ad1b683', 'DB Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/qqntiuPmLDM?feature=share', 'انحني للأمام قليلًا، ارفع للأعلى الى أن تصل لمستوى الأكتاف.

ملاحظات مهمة:
• ارفع بمرفق مثني قليلاً حتى مستوى الكتف فقط
• قدّم المرفق على اليد ولا ترفع الكتفين نحو الأذنين
• نزول بطيء 2–3 ثوانٍ
• لا تتأرجح بالجذع', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0c464f74-da1d-4a9c-9482-ebe004982cb6', 'Seated Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/v7fwGurZ9SU?feature=share', 'انحني للأمام قليلًا، ارفع للأعلى الى أن تصل لمستوى الأكتاف.

ملاحظات مهمة:
• اجلس بظهر مسنود لإزالة الزخم
• ارفع حتى مستوى الكتف والمرفقان مثنيان قليلاً
• نزول بطيء
• وزن خفيف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cb72cfa7-c8f7-4389-927a-08abf4f4d750', 'Lateral Raise Machine', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/d0pRsZ9SY5w?si=XuXb_Ti0Flow7qvW', 'ملاحظات مهمة:
• اضبط المقعد ليكون محور الكتف مع محور الجهاز
• ارفع الذراعين للجانبين دون رفع الكتفين
• نزول بطيء
• لا تدفع بالجذع', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('68cf0e68-ad17-47d6-b6f0-92a4db17f1de', 'Cable Crossover Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/wKgCc5UQjoU?si=zsaz3i31PnEU9A43', 'الكيبل يبدأ من الأسفل، انحني للأمام قليلًا، ارفع للأعلى وتحكم بالنزول.

ملاحظات مهمة:
• الكيبل من الجهة المقابلة
• ارفع الذراع قطرياً للجانب حتى مستوى الكتف
• جذع ثابت
• وزن خفيف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f7b3f5cd-e09d-4dab-9779-30d5f9c63402', 'Cable Y Raises', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/P7u6PEeOn6Q?feature=share', 'الكيبل يبدأ من تحت،ارفع الوزن على شكل Y.

ملاحظات مهمة:
• الكيبل من الأسفل ويدك على شكل Y
• ارفع نحو الأعلى وللخارج بخط قطري
• وزن خفيف وثبات الجذع
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Y Raise (Scaption) / رفع Y بمستوى لوح الكتف', 'Shoulder Elevation in Scapular Plane (Scaption) / رفع الذراع بمستوى لوح الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('10ad654a-1dd9-434a-aec4-7482ef213dd5', 'Single Arm DB Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/Jm6GqVhWhNY', 'انحني للأمام قليلًا، ارفع للأعلى الى أن تصل لمستوى الأكتاف.

ملاحظات مهمة:
• اعمل بيد واحدة وأمسك سنداً بالأخرى
• ارفع حتى مستوى الكتف دون ميلان الجذع
• نزول بطيء
• وزن خفيف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('755b0997-45ff-40fa-aa9c-580940f07439', 'Single Arm Cable Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/J-6uEOkYAKM', 'الكيبل يبدأ من الأسفل، انحني للأمام قليلًا، ارفع للأعلى وتحكم بالنزول.

ملاحظات مهمة:
• ثبّت الجذع وارفع الذراع للجانب
• الكيبل يعطي شداً من البداية فتحكم في الأسفل
• حتى مستوى الكتف
• لا ترفع الكتف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('80286434-093e-4c85-b27d-59869bcde22b', 'Front Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Front Raise / رفع أمامي للكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, 'ملاحظات مهمة:
• ارفع حتى مستوى الكتف فقط والمرفق مثني قليلاً
• لا تتأرجح بالجذع
• نزول بطيء
• وزن مناسب', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/54/front-raise/', NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Front Raise / رفع أمامي', 'Shoulder Flexion / ثني الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e0696dc1-32b0-4e4e-a993-bb15fa9827f3', 'Diagonal Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, 'ملاحظات مهمة:
• ارفع بخط قطري من الفخذ المقابل نحو الكتف
• حرّك بتحكم دون تدوير الجذع
• وزن خفيف
• حتى مستوى الكتف', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/371/diagonal-raise/', NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Diagonal Raise / رفع قطري', 'Shoulder Flexion + Abduction (Diagonal) / ثني وتبعيد الكتف (قطري)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ce011cf0-8795-48b9-86be-eddc4687e8f9', 'High Row', 'Shoulders / الأكتاف', '{}', 'Shoulder Rear Pull / سحب خلفي للكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, 'ملاحظات مهمة:
• اسحب نحو الوجه والمرفقان للأعلى وللجانبين
• دوّر الذراعين للخارج في النهاية
• لا تتمايل للخلف
• الرسغ مستقيم', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/336/high-row/', NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'High Row / Face Pull / سحب عالٍ باتجاه الوجه', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ed65f017-8c9e-476a-bf0c-47e61efa4efd', 'Biceps Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/09AYfVFf7pg?si=dcwLVAYqIbDLM6jd', 'ملاحظات مهمة:
• المرفقان ثابتان بجانب الجسم ولا تتأرجح
• اثنِ حتى انقباض كامل وانزل ببطء 2–3 ثوانٍ
• رسغ محايد
• لا ترفع الكتفين', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('76ab13fc-95aa-4d7a-ad4b-2860e1c71659', 'Cable Rope Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/xNXUTJ6TBZA?si=-r-Ql97awoVZla_1', 'ملاحظات مهمة:
• قبضة محايدة بالحبل والمرفقان ثابتان
• اثنِ وأدر الحبل للخارج في الأعلى
• نزول بطيء
• الجذع ثابت', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Hammer / Neutral-grip Curl / ثني بقبضة محايدة', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9dd33b98-1e9a-4d92-8e68-6d81d142fde5', 'Cable Facing Away Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/fV9BpknCjGM', 'ملاحظات مهمة:
• وجهك بعيداً عن الكيبل والذراعان للخلف قليلاً
• اثنِ بالمرفقين مع ثباتهما
• تمدد البايسبس في الأسفل
• لا تتأرجح', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c11ec1b2-0059-4e56-8e6a-b1a7af2ed155', 'DB Incline Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/js_StxxyxBM', 'ملاحظات مهمة:
• على مقعد مائل والذراعان خلف الجسم
• اثنِ بالمرفقين دون تقديمهما للأمام
• تمدد كامل في الأسفل
• وزن خفيف نسبياً', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ead00843-6860-4569-a731-2e2a82b455f5', 'Cable Facing In Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/5z4y7QRTx1w', 'ملاحظات مهمة:
• وجهك للكيبل والمرفقان للأمام قليلاً
• اثنِ حتى انقباض كامل
• حافظ على شد الكيبل
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ac987f9c-f00c-4e0c-b8db-39642099ffb4', 'Preacher Curl Machine', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/TouYMA3-ua4?feature=share', 'ملاحظات مهمة:
• اضبط المقعد ليكون العضد على المسند
• اثنِ حتى انقباض
• نزول بطيء دون فرد عنيف
• لا ترفع الكتفين', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Preacher Curl / ثني على مسند', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('beba0582-4d01-478a-9cb2-6da57639d0a3', 'DB Spider Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/cTMjzB2_IH8?si=qsIKEEFVfEvPXwqf', 'ملاحظات مهمة:
• الصدر على مقعد مائل والذراعان للأسفل
• اثنِ بالمرفقين مع ثباتهما
• انقباض في الأعلى
• نزول بطيء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('12a54747-2dab-486f-a626-c67488c4a176', 'Zottman Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://www.youtube.com/watch?v=ZXbOOIOPOi8', 'ملاحظات مهمة:
• اثنِ بقبضة عادية ثم دوّر الرسغ في الأعلى وانزل بقبضة معكوسة
• نزول بطيء
• وزن خفيف للساعد
• المرفق ثابت', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d2027142-4b50-4822-addc-c97617d1668b', 'Hammer Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• قبضة محايدة والمرفقان ثابتان
• اثنِ دون تأرجح
• نزول بطيء
• الإبهام للأعلى', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/10/hammer-curl/', NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Hammer / Neutral-grip Curl / ثني بقبضة محايدة', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1fd19eac-655c-456b-8a28-121237b0b739', 'TRX Biceps Curl', 'Biceps / البايسبس', '{"Forearms / الساعد","Core / البطن والكور"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'TRX', 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• جسم مستقيم ومائل للخلف والمرفقان للأمام
• اثنِ المرفقين نحو الجبهة
• عودة بطيئة
• الورك لا يتدلى', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/78/trx-reg-biceps-curl/', NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4009e6a4-0878-4f5f-bdb5-3df7554df698', 'DB Floor Triceps Extensions', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/dpFav9Ve4rY?si=ZBdKK8VF4aPMpi3v', 'ملاحظات مهمة:
• استلقِ على الأرض والمرفقان للأعلى
• انزل نحو الجبهة أو خلف الرأس بتحكم
• افرد المرفقين دون تحريك العضد
• وزن خفيف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Lying Extension / مد مستلقٍ', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0f21496c-a04f-452d-8cd8-d3a0d24222a7', 'Cable Crossbody Extensions', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://www.youtube.com/watch?v=jtLTcED38Dg', 'الكيبل يبدأ بالمنتصف زي الفيديو، بحيث لما تسحب الكيبل يكون بنفس مستوى الترابس، الأكواع والأكتاف ثابتين مكانهم والحركة كلها بثني وفرد الكوع.

ملاحظات مهمة:
• اسحب الكيبل بالمرفق ثابتاً وعبر الجسم
• افرد بالكامل مع انقباض الترايسبس
• العضد ثابت
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Cross-body Extension / مد عرضي', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8eff7985-1ea3-4f61-95f5-ebac0f549438', 'Triceps Pushdown', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/QsoN4u6j8nM?feature=share', 'انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.

ملاحظات مهمة:
• المرفقان ثابتان بجانب الجسم
• افرد المرفقين بالكامل مع انقباض لحظة
• عودة بطيئة دون رفع الكتفين
• لا تتمايل', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c9b724f5-3a7c-43df-a51c-241f80f5c90c', 'Cable Crossover Pressdowns', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/Y3CDzx-oj3k', 'الكيبل يبدأ من الأعلى،انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.

ملاحظات مهمة:
• ادفع من الجهتين بمرفقين ثابتين
• افرد بالكامل وانقباض
• عودة بطيئة
• جذع ثابت', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('86104b1e-0488-4d42-9e1d-3d3831267096', 'Band Triceps Pushdown', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/mYs1rEYtZK4?si=k8vdZxNNEB5wj2CA', 'الكيبل يبدأ من الأعلى،انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.

ملاحظات مهمة:
• ثبّت الشريط عالياً
• افرد المرفقين مع بقاء العضد ثابتاً
• عودة بطيئة
• تأكد من ثبات الشريط', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7b1df8a9-d5fa-41bb-81a3-57d18775f6f0', 'Single Cable Triceps Pressdowns', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/8rl4ioij6lc', 'الكيبل يبدأ من الأعلى،انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.

ملاحظات مهمة:
• بيد واحدة والمرفق ثابت
• افرد بالكامل
• عودة بطيئة
• جذع ثابت', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('42d564a8-4d1f-426f-8e7b-0739cce9ef66', 'Cable Overhead Extension', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://www.youtube.com/shorts/Q3bO1Fh4734', 'اترك الحبل يسحب معصمك وكوعك ثابت لما تستطيل التراي ثم ارفع الوزن لما تستقيم اليد، كوعك ثابت طول الوقت والحركة ثني ومد من مفصل الكوع، ممكن تطبق كل يد لحالها اذا كان اسهل لك.

ملاحظات مهمة:
• وجهك للأمام أو الخلف والمرفقان قريبان من الرأس
• افرد المرفقين فوق الرأس بتحكم
• شد البطن لتجنب التقوّس
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Overhead Extension / مد فوق الرأس', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e498b1d9-c4d0-4849-91eb-25f50e0e8b18', 'Triceps Dips', 'Triceps / الترايسبس', '{"Chest / الصدر","Shoulders / الأكتاف"}', 'Vertical Push / دفع عمودي', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/SpSE_A5L-YA?si=bSAzRM9SBuX-3mE0', 'ملاحظات مهمة:
• جسم مستقيم على مقعد أو متوازي
• انزل بالمرفقين حتى 90° تقريباً
• لا تتجاوز مدى كتفك
• توقف عند ألم الكتف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Dip / متوازي', 'Shoulder Extension + Elbow Extension / مد الكتف + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5c567ddc-6d37-45ab-b69c-d0d873684208', 'Triceps Kickback', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/YebyKE3Ts8o?si=H_h9z5BXutFBbFhq', 'ملاحظات مهمة:
• العضد موازٍ للجسم وثابت
• افرد المرفق للخلف بتحكم
• انقباض في الأعلى
• وزن خفيف', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/55/triceps-kickback/', NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Triceps Kickback / ركلة الترايسبس', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('72b2d4bc-1bb9-459e-91e2-6f860970a92b', 'Suitcase Carry', 'Core / البطن والكور', '{"Forearms / الساعد"}', 'Loaded Carry / حمل ومشي', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/BaRMAhD7SP4?si=KkiMH8OSIEz_TB53', 'ملاحظات مهمة:
• امشِ بجذع مستقيم دون ميلان نحو الوزن
• كتفان ثابتان وخطوات منتظمة
• شد البطن
• بدّل الجهة', 'نفس التمرين ورد أيضاً تحت التصنيف «Functional Training» (صف المصدر 160) || رابط آخر في المصدر (صف 160): https://youtu.be/BaRMAhD7SP4?si=dCR2n2VSPaHhxfL3', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Suitcase Carry / حمل جانبي', 'Isometric Trunk + Grip Under Load / تثبيت الجذع والقبضة أثناء المشي', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('33ca5569-1a78-4ee1-b885-2a6a7c3c0b10', 'Cable Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/ToJeyhydUxU?si=Z5dv34foxX4VtRH6', 'الحركة عبارة عن ثني للعمود الفقري وكأنك تقرب صدرك لوركك.

ملاحظات مهمة:
• اركع أمام الكيبل والحبل عند الرأس
• اثنِ الجذع نحو الأرض بتقوّسه
• الحوض ثابت والحركة من البطن
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Crunch / كرنش', 'Trunk Flexion / ثني الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f214661a-72b1-4f0f-982d-0de615acd292', 'Leg Raises', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/UqmbxvOgnX4?si=U3pDG4Jf0x1mtC_7', 'ملاحظات مهمة:
• علّق أو استلقِ وثبّت الظهر
• ارفع الرجلين بتحكم دون تأرجح
• اثنِ الركبتين عند الصعوبة
• نزول بطيء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Reverse Crunch / Leg Raise / كرنش عكسي ورفع الأرجل', 'Hip Flexion + Posterior Pelvic Tilt / ثني الورك + إمالة الحوض للخلف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e743c92b-5d9f-449a-9c0c-db4a8924ce8b', 'Bosu Ball Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'أخرى', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/KjvDgHPxXcg?si=zad59CHC6Y-calzi', 'ملاحظات مهمة:
• استلقِ على الكرة وأسفل الظهر مدعوم
• اثنِ الجذع للأعلى بتحكم
• لا تسحب الرقبة
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Crunch / كرنش', 'Trunk Flexion / ثني الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('37fd1cf6-469c-4b3b-828f-a27c00e1633e', 'Bent Knee V-Up', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/sbyFIM30_G8?si=dED0NQSRS44dz5G9', 'ملاحظات مهمة:
• ارفع الجذع والركبتين معاً نحو بعضهما
• حركة بطيئة بتحكم
• أسفل الظهر لا يتقوس
• زفير عند الرفع', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'V-up / في أب', 'Trunk Flexion + Hip Flexion / ثني الجذع + ثني الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9d6e0fed-933f-4122-a351-5fe806f669ae', 'Reverse Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/esYVzdEfs04?si=N44MZZHlVeSQc1S3', 'ملاحظات مهمة:
• ارفع الحوض عن الأرض بتقوّس أسفل الظهر
• لا تستخدم الزخم
• نزول بطيء
• الركبتان مثنيتان', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Reverse Crunch / Leg Raise / كرنش عكسي ورفع الأرجل', 'Hip Flexion + Posterior Pelvic Tilt / ثني الورك + إمالة الحوض للخلف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a76443a7-99a3-495b-b836-d1391739c897', 'Belly Breathing', 'Core / البطن والكور', '{}', 'Core Activation & Breathing / تفعيل الجذع والتنفس', 'إحماء/تفعيل', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/Shk8cmgv0Ew?si=mXkcj9PH6eH_tLcd', 'نفس عميق من الانف ننفخ فيه البطن ثم نطلعه من الفم ببطئ مع ضغط البطن للداخل اثناء اخراج النفس

ملاحظات مهمة:
• شهيق بطيء من الأنف يوسّع البطن
• زفير بطيء من الفم
• الكتفان مرتخيان
• لا ترفع الصدر', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Diaphragmatic Breathing / تنفس حجابي', 'Diaphragmatic Breathing + Abdominal Bracing / تنفس حجابي + شد البطن', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8e4ddd54-61b2-4ad1-bab0-2bfbd3eb2e3d', 'Reverse Tabletop Bridge', 'Core / البطن والكور', '{"Glutes / المؤخرة"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://youtu.be/d1yE9cGtPWo?si=2aoNqmUAN054rP75', 'اخذ نفس اثناء الطلوع، اثبت ثواني فوق واشد عضلات بطني، اطلع النفس اثناء النزول

ملاحظات مهمة:
• ارفع الورك حتى استقامة الجسم مع اليدين خلفك
• انقباض الألوية
• الرأس محايد
• لا تبالغ في تقوّس الظهر', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7c4ab3bb-59be-4ec6-ac69-a283ee56eb3a', 'Pelvic Tilting', 'Core / البطن والكور', '{}', 'Core Activation & Breathing / تفعيل الجذع والتنفس', 'إحماء/تفعيل', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/DqqUIfMuDX4?si=uzl0SRl_M9guUT3j', 'الحركة من الحوض، اخذ نفس وادف حوضي للاعلى قليلا، اطلع النفس اثناء نزول الحوض والصق اسفل ظهري بالارض

ملاحظات مهمة:
• حركة صغيرة ناعمة من الحوض بشد البطن
• لا ترفع الأرداف
• تنفس طبيعي
• لا تضغط بقوة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Pelvic Tilt / إمالة الحوض', 'Posterior Pelvic Tilt / إمالة الحوض للخلف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0363a22b-945d-4322-870b-c7e76be8a1d3', 'Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'ملاحظات مهمة:
• ارفع الكتفين فقط عن الأرض
• لا تسحب الرقبة باليدين
• زفير عند الرفع وانقباض لحظة
• نزول بطيء', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/52/crunch/', NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Crunch / كرنش', 'Trunk Flexion / ثني الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d0bf6c82-f176-484f-bcb9-26c22dca5150', 'Standing Wood Chop', 'Core / البطن والكور', '{}', 'Trunk Rotation / دوران الجذع', 'كور', NULL, 'مبتدئ', NULL, NULL, 'ملاحظات مهمة:
• دوّر من الجذع والورك والذراعان شبه مستقيمتين
• حرّك من الأعلى للأسفل بخط قطري
• الحوض مستقر
• تحكم في العودة', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/108/standing-wood-chop/', NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Rotation / Chop / دوران وتقطيع', 'Trunk Rotation / دوران الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a0e666f7-5923-463e-a148-8336ee527d0f', 'Russian Twist', 'Core / البطن والكور', '{"Lower back / أسفل الظهر"}', 'Trunk Rotation / دوران الجذع', 'كور', NULL, 'مبتدئ', NULL, NULL, 'ملاحظات مهمة:
• اجلس مائلاً قليلاً بجذع مستقيم
• دوّر الكتفين والجذع لا اليدين فقط
• الرجلان على الأرض عند الصعوبة
• حركة بطيئة', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/65/russian-twist/', NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Rotation / Chop / دوران وتقطيع', 'Trunk Rotation / دوران الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1afcd42c-07fd-4677-82b3-ec515077fde0', 'Cable Twisted', 'Core / البطن والكور', '{"Lower back / أسفل الظهر"}', 'Trunk Rotation / دوران الجذع', 'كور', 'كيبل', 'مبتدئ', 'نادي', NULL, 'ملاحظات مهمة:
• ثبّت الحوض ودوّر من الجذع
• ذراعان شبه مستقيمتين
• تحكم في العودة
• وزن مناسب', NULL, 'إضافة المدربة', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Rotation / Chop / دوران وتقطيع', 'Trunk Rotation / دوران الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('138289fa-df6a-4357-addc-3e61f33a366a', 'Calves On Leg Press', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/XdtWVYFVhGU', 'ثبت أصابعك أو مقدمة رجلك على الجهاز، لا تبالغ بالوزن، انزل بكعبك لين تمتد بطاتك بشكل كامل ثم ادفع.

ملاحظات مهمة:
• القدمان على الحافة السفلى للمنصة والركبتان مفرودتان قليلاً دون قفل
• ادفع بمقدمة القدم لأقصى ارتفاع ثم انزل حتى تمدد البطة
• توقف لحظة في الأعلى والأسفل
• لا ترتد', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('abcdd770-0f40-4bbc-9375-f15d74b5b712', 'Calves Raise', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/H6WptvjXkgw', 'حط تحت اقدامك بليتس أو أي شي يرفعك عن الأرض، انزل من اصابعك اقصى نزول ثم ادفع للأعلى

ملاحظات مهمة:
• ارتفع على أطراف الأصابع لأقصى مدى
• انزل حتى تمدد البطة
• توقف في الأعلى
• حركة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d41ef5e6-9deb-4ef1-8db3-a5a2be46d684', 'Calf Raise (Machine)', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', 'جهاز', 'مبتدئ', 'نادي', NULL, 'ملاحظات مهمة:
• ضع الكتفين تحت المساند وأصابع القدم على الحافة
• ارتفع لأقصى مدى وانزل حتى تمدد
• توقف لحظة في الأعلى
• لا ترتد', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/294/calf-raise/', NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('25c20fd0-0fd2-4544-9845-edad943e28f2', 'Calf Raises (Barbell)', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', 'بار', 'مبتدئ', 'نادي', NULL, 'ملاحظات مهمة:
• البار على أعلى الظهر وقوف ثابت
• ارتفع على الأصابع بتحكم
• مدى كامل بدون ارتداد
• سند للتوازن', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/51/calf-raises/', NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9e61aafe-a0ad-41b2-b00c-f7dda16f9e47', 'Adductor Slides', 'Adductors / الأفخاذ الداخلية', '{}', 'Hip Adduction / تقريب الورك', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/6U7dfuxaX9g?si=lkH35E7tZxGBePBj', 'ملاحظات مهمة:
• انزلق بالرجل للجانب بتحكم
• الجذع ثابت
• ادفع للعودة بالعضلة الداخلية
• حركة بطيئة', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor strength»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Adductor Slide / انزلاق للتقريب', 'Hip Adduction / تقريب الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('19226686-93ce-4abd-95a4-d870e54c8bc2', 'Adductor Machine', 'Adductors / الأفخاذ الداخلية', '{}', 'Hip Adduction / تقريب الورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/SU1LQhq3o2g?si=_55FKBOlcn8Ilw4X', 'ملاحظات مهمة:
• اضبط مدى مريح للبداية
• اضغط الفخذين معاً بتحكم
• عودة بطيئة دون ارتداد
• لا تفتح أكثر من مدى مريح', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Adductor Machine / جهاز التقريب', 'Hip Adduction / تقريب الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('47df8e26-c3a2-43b2-a230-206433f15370', 'Supine Hamstrings Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'استلقِ على ظهرك وارفع رجلاً واحدة ومدّها ببطء مع سحب أصابع القدم نحوك، دون أي حركة في الحوض أو أسفل الظهر. اثبت 15–30 ثانية، 2–4 مرات لكل رجل.

ملاحظات مهمة:
• استلقِ وارفع رجلاً بمساعدة شريط أو يدين
• ركبة شبه مفرودة بدون ألم
• شد مريح للخلفية
• ثبّت 20–40 ثانية', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/235/supine-hamstrings-stretch/', NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Hamstring Stretch / إطالة الخلفية', 'Hip Flexion with Knee Extended / ثني الورك مع مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a685d8e3-f8aa-433c-8aef-a991b3990334', 'Seated Abductor Machine', 'Abductors / مبعدات الفخذ', '{}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/riEMreTHNbM?si=wE3vfJBYQY7j_oJ2', 'ملاحظات مهمة:
• ظهر ملتصق بالمسند
• افتح الركبتين للخارج بتحكم
• انقباض لحظة
• عودة بطيئة', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor strength»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('317eff52-efb1-4adc-bb7e-f7f7ba8c6c24', 'Hip Abductor Plank', 'Abductors / مبعدات الفخذ', '{"Core / البطن والكور"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/2lB5RL91yWo?si=WRm9rUORpFK6dXPl', 'ملاحظات مهمة:
• بلانك جانبي بجسم مستقيم
• ارفع الرجل العليا بتحكم
• الحوض لا يميل
• ثبّت الكتف تحت المرفق', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor strength»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('479a7444-a6c5-4d8a-bc02-b3de1677649c', 'Dirty Dog', 'Abductors / مبعدات الفخذ', '{"Core / البطن والكور"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'ملاحظات مهمة:
• على أربع مع ظهر محايد
• ارفع الركبة للجانب كالكلب بتحكم
• الحوض ثابت دون ميلان
• حركة بطيئة', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/109/dirty-dog/', NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ca6d08f7-98cc-4a9c-8b83-2a0827b06c97', 'Rotator Cuff', 'Rotator cuffs / الكفة المدورة', '{}', 'Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/mO8YJAxVG2M?si=KL_llR6Z47Yt89uk', 'ملاحظات مهمة:
• وزن خفيف جداً والمرفق ملتصق بالجسم
• دوّر الساعد للخارج بتحكم دون ألم
• حركة بطيئة
• لا تقوّس الظهر', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «Functional Training»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'External Rotation / دوران خارجي', 'Shoulder External Rotation / دوران خارجي للكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('10ede506-e062-4bce-b8ed-3d1991eae236', 'Side Lying Quadriceps Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'استلقِ على جنبك وشد البطن، واسحب كعب الرجل العلوية نحو المؤخرة بيدك مع إبقاء الركبة في خط الورك. اثبت 30–45 ثانية، 2–5 مرات لكل جهة.

ملاحظات مهمة:
• على الجنب اسحب الكعب نحو الأرداف
• الركبتان متقاربتان والحوض ثابت
• شد مريح بدون ألم الركبة
• ثبّت 20–40 ثانية', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/149/side-lying-quadriceps-stretch/', NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Quadriceps Stretch / إطالة الأمامية', 'Knee Flexion + Hip Extension (End Range) / ثني الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1f95a3a1-cebe-4301-9ed4-4ef5fb8b2b0d', 'Stability Ball Reverse Extensions', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة"}', 'Spinal Extension / بسط الجذع', 'كور', 'كرة سويسرية', 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• على بطنك على الكرة
• ارفع الرجلين بتحكم حتى استقامة الجسم
• لا تبالغ بالتقوّس
• شد الألوية', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/64/stability-ball-reverse-extensions/', NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Reverse Extension / بسط عكسي', 'Hip Extension + Spinal Extension / بسط الورك + بسط العمود الفقري', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3e4fdf6a-72ec-44ea-9178-d239887e40a9', 'Contralateral Limb Raises', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة","Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Spinal Extension / بسط الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'ملاحظات مهمة:
• على أربع، ارفع اليد والرجل المقابلة بتحكم
• الحوض والظهر ثابتان دون ميلان
• ثبّت لحظة
• بدّل الجهة', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/53/contralateral-limb-raises/', NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Prone Extension / بسط على البطن', 'Spinal Extension / بسط العمود الفقري', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fed8577c-28e7-43e9-ba3a-343a149592e9', 'Inner Thigh Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/uqCfJYKojLU?si=Gev0VeOwVp5z6gB2', 'الضغط والدفع يكون من جهة الفخذ ، لا تدفع من ركبتك!

ملاحظات مهمة:
• اجلس بفتح الرجلين وقدمين ملتصقتين
• اضغط الركبتين للأسفل برفق
• شد مريح وليس ألماً
• ثبّت 20–40 ثانية', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «stretch»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Adductor Stretch / إطالة المقربات', 'Hip Abduction (Adductor Stretch) / تبعيد الورك (إطالة المقربات)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0c5bcc1d-05cf-4089-b618-1284bca532c0', 'Hips Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/uqCfJYKojLU?si=Gev0VeOwVp5z6gB2', 'ملاحظات مهمة:
• وضعية ممتدة للورك بجذع مستقيم
• اضغط برفق دون ألم
• تنفس بهدوء
• ثبّت 20–40 ثانية', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «stretch»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Hip Stretch / إطالة الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d3652669-082a-43ac-818c-c25665c3b37c', 'Kneeling Hip-flexor Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'من وضع الركوع: الركبة الخلفية تحت الورك والقدم الأمامية أمامك والركبة فوق الكاحل. شد البطن وادفع الحوض للأمام دون تقويس أسفل الظهر، واعصر مؤخرة الجهة الخلفية لزيادة الإطالة. اثبت 30–45 ثانية، 2–5 مرات.

ملاحظات مهمة:
• ركبة على الأرض والأخرى أمامك
• ادفع الحوض للأمام مع شد البطن
• شد في مقدمة الورك
• لا تقوّس أسفل الظهر', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/142/kneeling-hip-flexor-stretch/', NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Hip Flexor Stretch / إطالة ثانيات الورك', 'Hip Extension (End Range) / بسط الورك في نهاية المدى', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6a85df59-c91b-448d-a607-3b0be421a728', 'Standing Lunge Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'ملاحظات مهمة:
• وضعية لانج ثابتة وحوض للأمام
• جذع مستقيم وشد البطن
• شد في مقدمة ورك الرجل الخلفية
• ثبّت 20–40 ثانية', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/137/standing-lunge-stretch/', NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Hip Flexor Stretch / إطالة ثانيات الورك', 'Hip Extension (End Range) / بسط الورك في نهاية المدى', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('898b9d1f-816a-4961-ad6f-609995fb2793', 'Lateral Bound', 'Plyometrics / التمارين الانفجارية', '{"Glutes / المؤخرة","Quadriceps / الأمامية","Abductors / مبعدات الفخذ"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://www.youtube.com/watch?v=soqQy4dzEts', 'ملاحظات مهمة:
• اقفز جانبياً وهبوط ناعم على رجل واحدة
• الركبة فوق القدم دون انهيار
• ثبّت لحظة
• ابدأ بمسافة قصيرة', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «Functional Training»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Lateral Jump / قفز جانبي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('21c76db0-c631-4704-ab30-610939fa8e6c', 'Box Jumps', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Calves / البطات"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'أخرى', 'متوسط', 'نادي', NULL, 'ملاحظات مهمة:
• اقفز بانفجار وهبوط ناعم على صندوق
• الركبتان مثنيتان عند الهبوط
• انزل بالخطوة لا بالقفز
• ابدأ بارتفاع منخفض', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «CrossFit»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Vertical Jump / قفز عمودي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2feae2c9-bf06-45f0-a412-59694c23efe3', 'Squat Jump', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متوسط', 'بدون معدات', NULL, 'قف بعرض الحوض، ادفع الورك للخلف وانزل، ثم اقفز بقوة بمدّ الكاحل والركبة والورك معاً. انزل بهدوء على منتصف القدم مع دفع الورك للخلف ودون قفل الركب. ابدأ بقفزات صغيرة حتى تتقن الهبوط.

ملاحظات مهمة:
• انزل بسكوات ثم اقفز لأعلى بانفجار
• هبوط ناعم على كامل القدم
• الركبتان باتجاه الأصابع
• أوقف المجموعة عند هبوط الأداء', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/222/squat-jump/', NULL, 'review', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Vertical Jump / قفز عمودي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('850b8a2b-d029-4147-b2de-a8a0203132cc', 'Tuck Jump', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متقدم', 'بدون معدات', NULL, 'استخدم الذراعين للزخم: أرجعهما للخلف عند النزول وأرجحهما للأمام والأعلى عند القفز، واسحب الركبتين نحو الصدر في الهواء.

ملاحظات مهمة:
• اقفز واسحب الركبتين نحو الصدر
• هبوط ناعم والركبتان مثنيتان
• حافظ على جذع مستقيم
• مجموعات قصيرة', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/180/tuck-jump/', NULL, 'review', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Vertical Jump / قفز عمودي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cdb502cb-e814-45da-861a-488bb4ce0cdd', 'Cycled Split-Squat Jump', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Hamstrings / الخلفية"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متقدم', 'بدون معدات', NULL, 'ملاحظات مهمة:
• من وضع لانج اقفز وبدّل الرجلين في الهواء
• هبوط ناعم والركبة فوق القدم
• جذع مرفوع
• مجموعات قصيرة', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/234/cycled-split-squat-jump/', NULL, 'review', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Split Jump / قفز سبليت', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('93bffa85-d279-47c8-899a-dd8044cf5f72', 'Lateral Cone Jumps', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Calves / البطات"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'أخرى', 'متوسط', 'نادي', NULL, 'ملاحظات مهمة:
• اقفز جانبياً فوق الحواجز بتحكم
• هبوط ناعم وركبتان مثنيتان
• حافظ على الجسم متزناً
• مسافة آمنة', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/120/lateral-cone-jumps/', NULL, 'review', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Lateral Jump / قفز جانبي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0a91db10-2764-4d97-b95e-5af30db7b134', 'Forward Linear Jumps', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Hamstrings / الخلفية"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متوسط', 'بدون معدات', NULL, 'ملاحظات مهمة:
• اقفز للأمام بانفجار وهبوط ناعم
• ركبتان باتجاه الأصابع
• حافظ على توازنك قبل القفزة التالية
• مسافات قصيرة في البداية', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/177/forward-linear-jumps/', NULL, 'review', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Horizontal Jump / قفز أمامي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('67be5877-19c7-43b3-9b37-8ece26c83e2c', 'Jogging', 'CrossFit / كروس فت', '{"Quadriceps / الأمامية","Hamstrings / الخلفية","Calves / البطات"}', 'Locomotion / مشي وجري ودفع', 'كارديو', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'ملاحظات مهمة:
• ابدأ بإحماء تدريجي وخطوات خفيفة
• جذع مستقيم وكتفان مرتخيان
• زد السرعة والمسافة تدريجياً
• حذاء مناسب', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Running / جري', 'Gait: Alternating Hip/Knee Extension / نمط المشي والجري', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('08516d4a-9206-4cdc-a69d-9cf4de96768f', 'Wall Ball', 'CrossFit / كروس فت', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Shoulders / الأكتاف"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'أخرى', 'متوسط', 'نادي', NULL, 'ملاحظات مهمة:
• سكوات ثم رمي الكرة على الهدف بانفجار
• ابدأ بوزن خفيف
• استقبل الكرة بذراعين مرنتين
• ركبتان باتجاه الأصابع', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Squat to Throw / سكوات مع رمي', 'Knee/Hip Extension + Shoulder Flexion / مد الركبة والورك + ثني الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8c517bd0-cb24-4d2f-bfd3-7acac37a1cbe', 'Snatch', 'CrossFit / كروس فت', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Shoulders / الأكتاف"}', 'Olympic Lift (Triple Extension) / رفعات أولمبية (بسط ثلاثي)', 'قدرة', 'بار', 'متقدم', 'نادي', NULL, 'ملاحظات مهمة:
• تقنية معقدة، تعلّمها بعصا أو وزن خفيف وبإشراف مدرب
• البار قريب من الجسم
• الدفع من الورك والركبة والكاحل
• ظهر محايد', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Snatch / سناتش', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b6109891-dc33-4d09-ac3d-f1802d99d136', 'Clean', 'CrossFit / كروس فت', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Quadriceps / الأمامية"}', 'Olympic Lift (Triple Extension) / رفعات أولمبية (بسط ثلاثي)', 'قدرة', 'بار', 'متقدم', 'نادي', NULL, 'ملاحظات مهمة:
• تقنية معقدة، ابدأ بوزن خفيف وبإشراف مدرب
• الدفع من الورك ثم استقبال البار بمرفقين عاليين
• البار قريب من الجسم
• ظهر محايد', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Clean / كلين', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5ff01baf-04b2-4786-b8a7-8bca7bd95639', 'Turkish Get-Up', 'Functional / التمارين الوظيفية', '{"Shoulders / الأكتاف","Core / البطن والكور","Glutes / المؤخرة"}', 'Full-body Integrated / حركة متكاملة للجسم', 'قوة', 'كيتلبل', 'متقدم', 'منزل', 'https://www.youtube.com/watch?v=0bWRPC49-KI', 'ملاحظات مهمة:
• تحرك بخطوات واضحة وعيناك على الوزن
• الذراع عمودية فوقك طوال الحركة
• ابدأ بدون وزن
• حركة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Turkish Get-Up / النهوض التركي', 'Multi-joint Integrated / حركة متعددة المفاصل', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d526c37f-fa4d-4fc5-8acf-6a3ebbb1f3a1', 'Sled Pull/Push', 'Functional / التمارين الوظيفية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Calves / البطات"}', 'Locomotion / مشي وجري ودفع', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://www.youtube.com/watch?v=3KWK7SIdPz4', 'ملاحظات مهمة:
• جذع ثابت مائل للأمام
• خطوات قوية متتالية
• تنفس منتظم
• وزن يسمح بالحفاظ على الوضعية', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Sled Push / Pull / دفع وسحب الزلاجة', 'Hip/Knee Extension in Gait / بسط الورك والركبة بنمط المشي', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8f89bc3a-a995-4cf6-94e7-2cee01006816', 'Farmer’s Walk', 'Functional / التمارين الوظيفية', '{"Forearms / الساعد","Core / البطن والكور","Back & Lats / الظهر واللاتس"}', 'Loaded Carry / حمل ومشي', 'قوة', NULL, 'مبتدئ', NULL, 'https://www.youtube.com/watch?v=hx24PM6gXs8', 'ملاحظات مهمة:
• قبضة قوية وكتفان للخلف
• جذع مستقيم وخطوات قصيرة
• شد البطن
• لا تتمايل', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Farmer''s Walk / مشي المزارع', 'Isometric Trunk + Grip Under Load / تثبيت الجذع والقبضة أثناء المشي', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e7943a3d-ffd1-4292-bed2-5d69f67e8ce9', '90s Transition', 'Functional / التمارين الوظيفية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://www.youtube.com/watch?v=ogU-azeGe_k', 'ملاحظات مهمة:
• اجلس بزاوية 90° للورك والركبة وانتقل بتحكم
• جذع مستقيم
• حركة بطيئة ضمن مدى مريح
• لا تفرض المدى', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Hip Rotation Mobility (90/90) / مرونة دوران الورك', 'Hip Internal/External Rotation / دوران الورك الداخلي والخارجي', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fcab71f2-3378-49a9-ad47-e19da022bd11', 'Kettlebell Swing', 'Functional / التمارين الوظيفية', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Core / البطن والكور"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قدرة', 'كيتلبل', 'متوسط', 'منزل', 'https://www.youtube.com/watch?v=d94xX-AQZ0A', 'ملاحظات مهمة:
• ادفع الورك للأمام بانفجار ولا ترفع الكيتلبل بالذراعين
• ظهر محايد وركبتان مثنيتان قليلاً
• شد الألوية في الأعلى
• الكيتلبل يعود بين الساقين بتحكم', 'نفس التمرين ورد أيضاً تحت التصنيف «CrossFit» (صف المصدر 168)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Ballistic Hinge (Swing) / مفصلة انفجارية (سوينق)', 'Hip Extension (Ballistic) / بسط الورك الانفجاري', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('04912576-806d-4637-8b7e-db606aa121b4', 'Serratus Punches Supine', 'Functional / التمارين الوظيفية', '{"Shoulders / الأكتاف","Chest / الصدر"}', 'Horizontal Push / دفع أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/cxaAqmdlrgk?si=2YRAIgFFXPAvDadG', 'ملاحظات مهمة:
• استلقِ والذراعان نحو السقف
• ادفع الكتف للأعلى بحركة لوح الكتف دون ثني المرفق
• حركة صغيرة بتحكم
• لا ترفع الرأس', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'Scapular Protraction / دفع لوح الكتف', 'Scapular Protraction / دفع لوح الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;



INSERT INTO public.exercise_alternatives VALUES ('ef14fa72-c6f2-4705-a3f1-0fc69d1ebc6e', '6e437211-13b4-4e14-84d0-6271547dfa73', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ef14fa72-c6f2-4705-a3f1-0fc69d1ebc6e', '2efbaf3d-bfa5-4556-8dfd-403f47751ae4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ef14fa72-c6f2-4705-a3f1-0fc69d1ebc6e', '9fadb633-7dd8-4917-ab41-4591ae41444f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ef14fa72-c6f2-4705-a3f1-0fc69d1ebc6e', '95b83ce8-8451-4852-9b91-032e4242935d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ef14fa72-c6f2-4705-a3f1-0fc69d1ebc6e', '68d8244b-07be-474a-9906-733a40728827', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6e437211-13b4-4e14-84d0-6271547dfa73', 'ef14fa72-c6f2-4705-a3f1-0fc69d1ebc6e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6e437211-13b4-4e14-84d0-6271547dfa73', '2efbaf3d-bfa5-4556-8dfd-403f47751ae4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6e437211-13b4-4e14-84d0-6271547dfa73', '9fadb633-7dd8-4917-ab41-4591ae41444f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6e437211-13b4-4e14-84d0-6271547dfa73', '95b83ce8-8451-4852-9b91-032e4242935d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6e437211-13b4-4e14-84d0-6271547dfa73', '68d8244b-07be-474a-9906-733a40728827', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('288b735c-2ce7-4b9a-af4d-1d894cd31c35', '2570306c-0eb0-4ef2-9d89-8f098ee22f37', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('288b735c-2ce7-4b9a-af4d-1d894cd31c35', 'c0485135-217a-4661-a87e-5672ca7aae37', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('288b735c-2ce7-4b9a-af4d-1d894cd31c35', 'ef14fa72-c6f2-4705-a3f1-0fc69d1ebc6e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('288b735c-2ce7-4b9a-af4d-1d894cd31c35', '6e437211-13b4-4e14-84d0-6271547dfa73', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('288b735c-2ce7-4b9a-af4d-1d894cd31c35', '2bc0e9b7-d795-4e3e-9f64-3acb88f16a8e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2bc0e9b7-d795-4e3e-9f64-3acb88f16a8e', '16403045-f2d5-475d-9d58-d5f98850f7ca', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2bc0e9b7-d795-4e3e-9f64-3acb88f16a8e', 'ef14fa72-c6f2-4705-a3f1-0fc69d1ebc6e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2bc0e9b7-d795-4e3e-9f64-3acb88f16a8e', '6e437211-13b4-4e14-84d0-6271547dfa73', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2bc0e9b7-d795-4e3e-9f64-3acb88f16a8e', '288b735c-2ce7-4b9a-af4d-1d894cd31c35', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2bc0e9b7-d795-4e3e-9f64-3acb88f16a8e', '2efbaf3d-bfa5-4556-8dfd-403f47751ae4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16403045-f2d5-475d-9d58-d5f98850f7ca', '2bc0e9b7-d795-4e3e-9f64-3acb88f16a8e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16403045-f2d5-475d-9d58-d5f98850f7ca', 'ef14fa72-c6f2-4705-a3f1-0fc69d1ebc6e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16403045-f2d5-475d-9d58-d5f98850f7ca', '6e437211-13b4-4e14-84d0-6271547dfa73', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16403045-f2d5-475d-9d58-d5f98850f7ca', '288b735c-2ce7-4b9a-af4d-1d894cd31c35', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16403045-f2d5-475d-9d58-d5f98850f7ca', '2efbaf3d-bfa5-4556-8dfd-403f47751ae4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2efbaf3d-bfa5-4556-8dfd-403f47751ae4', 'ef14fa72-c6f2-4705-a3f1-0fc69d1ebc6e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2efbaf3d-bfa5-4556-8dfd-403f47751ae4', '6e437211-13b4-4e14-84d0-6271547dfa73', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2efbaf3d-bfa5-4556-8dfd-403f47751ae4', '9fadb633-7dd8-4917-ab41-4591ae41444f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2efbaf3d-bfa5-4556-8dfd-403f47751ae4', '95b83ce8-8451-4852-9b91-032e4242935d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2efbaf3d-bfa5-4556-8dfd-403f47751ae4', '68d8244b-07be-474a-9906-733a40728827', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9fadb633-7dd8-4917-ab41-4591ae41444f', 'ef14fa72-c6f2-4705-a3f1-0fc69d1ebc6e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9fadb633-7dd8-4917-ab41-4591ae41444f', '6e437211-13b4-4e14-84d0-6271547dfa73', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9fadb633-7dd8-4917-ab41-4591ae41444f', '2efbaf3d-bfa5-4556-8dfd-403f47751ae4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9fadb633-7dd8-4917-ab41-4591ae41444f', '95b83ce8-8451-4852-9b91-032e4242935d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9fadb633-7dd8-4917-ab41-4591ae41444f', '68d8244b-07be-474a-9906-733a40728827', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2570306c-0eb0-4ef2-9d89-8f098ee22f37', '288b735c-2ce7-4b9a-af4d-1d894cd31c35', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2570306c-0eb0-4ef2-9d89-8f098ee22f37', 'c0485135-217a-4661-a87e-5672ca7aae37', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2570306c-0eb0-4ef2-9d89-8f098ee22f37', 'ef14fa72-c6f2-4705-a3f1-0fc69d1ebc6e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2570306c-0eb0-4ef2-9d89-8f098ee22f37', '6e437211-13b4-4e14-84d0-6271547dfa73', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2570306c-0eb0-4ef2-9d89-8f098ee22f37', '2bc0e9b7-d795-4e3e-9f64-3acb88f16a8e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('95b83ce8-8451-4852-9b91-032e4242935d', 'ef14fa72-c6f2-4705-a3f1-0fc69d1ebc6e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('95b83ce8-8451-4852-9b91-032e4242935d', '6e437211-13b4-4e14-84d0-6271547dfa73', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('95b83ce8-8451-4852-9b91-032e4242935d', '2efbaf3d-bfa5-4556-8dfd-403f47751ae4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('95b83ce8-8451-4852-9b91-032e4242935d', '9fadb633-7dd8-4917-ab41-4591ae41444f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('95b83ce8-8451-4852-9b91-032e4242935d', '68d8244b-07be-474a-9906-733a40728827', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c0485135-217a-4661-a87e-5672ca7aae37', '288b735c-2ce7-4b9a-af4d-1d894cd31c35', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c0485135-217a-4661-a87e-5672ca7aae37', '2570306c-0eb0-4ef2-9d89-8f098ee22f37', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c0485135-217a-4661-a87e-5672ca7aae37', 'ef14fa72-c6f2-4705-a3f1-0fc69d1ebc6e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c0485135-217a-4661-a87e-5672ca7aae37', '6e437211-13b4-4e14-84d0-6271547dfa73', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c0485135-217a-4661-a87e-5672ca7aae37', '2bc0e9b7-d795-4e3e-9f64-3acb88f16a8e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('09a08f9c-bcaf-4247-a40f-735bfd1c4370', '19638d3b-c1a7-4526-bc3c-b845ed878a16', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('09a08f9c-bcaf-4247-a40f-735bfd1c4370', 'c48b6150-d6de-4a64-9033-bfc2563758de', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('09a08f9c-bcaf-4247-a40f-735bfd1c4370', '1faae23e-3054-4ea8-b002-c663343d734f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('09a08f9c-bcaf-4247-a40f-735bfd1c4370', '880d2650-6e97-4355-a6ff-a05aaa2d7feb', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('09a08f9c-bcaf-4247-a40f-735bfd1c4370', '295f00b7-64bb-4318-871d-ffd0ec95b00f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19638d3b-c1a7-4526-bc3c-b845ed878a16', 'c48b6150-d6de-4a64-9033-bfc2563758de', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19638d3b-c1a7-4526-bc3c-b845ed878a16', '1faae23e-3054-4ea8-b002-c663343d734f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19638d3b-c1a7-4526-bc3c-b845ed878a16', '295f00b7-64bb-4318-871d-ffd0ec95b00f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19638d3b-c1a7-4526-bc3c-b845ed878a16', 'f33375ab-3973-4261-8447-cdb9546484ba', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19638d3b-c1a7-4526-bc3c-b845ed878a16', '09a08f9c-bcaf-4247-a40f-735bfd1c4370', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c48b6150-d6de-4a64-9033-bfc2563758de', '19638d3b-c1a7-4526-bc3c-b845ed878a16', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c48b6150-d6de-4a64-9033-bfc2563758de', '1faae23e-3054-4ea8-b002-c663343d734f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c48b6150-d6de-4a64-9033-bfc2563758de', '295f00b7-64bb-4318-871d-ffd0ec95b00f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c48b6150-d6de-4a64-9033-bfc2563758de', 'f33375ab-3973-4261-8447-cdb9546484ba', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c48b6150-d6de-4a64-9033-bfc2563758de', '09a08f9c-bcaf-4247-a40f-735bfd1c4370', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1faae23e-3054-4ea8-b002-c663343d734f', '19638d3b-c1a7-4526-bc3c-b845ed878a16', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1faae23e-3054-4ea8-b002-c663343d734f', 'c48b6150-d6de-4a64-9033-bfc2563758de', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1faae23e-3054-4ea8-b002-c663343d734f', '295f00b7-64bb-4318-871d-ffd0ec95b00f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1faae23e-3054-4ea8-b002-c663343d734f', 'f33375ab-3973-4261-8447-cdb9546484ba', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1faae23e-3054-4ea8-b002-c663343d734f', '09a08f9c-bcaf-4247-a40f-735bfd1c4370', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('880d2650-6e97-4355-a6ff-a05aaa2d7feb', '09a08f9c-bcaf-4247-a40f-735bfd1c4370', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('880d2650-6e97-4355-a6ff-a05aaa2d7feb', '19638d3b-c1a7-4526-bc3c-b845ed878a16', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('880d2650-6e97-4355-a6ff-a05aaa2d7feb', 'c48b6150-d6de-4a64-9033-bfc2563758de', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('880d2650-6e97-4355-a6ff-a05aaa2d7feb', '1faae23e-3054-4ea8-b002-c663343d734f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('880d2650-6e97-4355-a6ff-a05aaa2d7feb', '295f00b7-64bb-4318-871d-ffd0ec95b00f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('295f00b7-64bb-4318-871d-ffd0ec95b00f', '19638d3b-c1a7-4526-bc3c-b845ed878a16', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('295f00b7-64bb-4318-871d-ffd0ec95b00f', 'c48b6150-d6de-4a64-9033-bfc2563758de', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('295f00b7-64bb-4318-871d-ffd0ec95b00f', '1faae23e-3054-4ea8-b002-c663343d734f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('295f00b7-64bb-4318-871d-ffd0ec95b00f', 'f33375ab-3973-4261-8447-cdb9546484ba', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('295f00b7-64bb-4318-871d-ffd0ec95b00f', '09a08f9c-bcaf-4247-a40f-735bfd1c4370', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f33375ab-3973-4261-8447-cdb9546484ba', '19638d3b-c1a7-4526-bc3c-b845ed878a16', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f33375ab-3973-4261-8447-cdb9546484ba', 'c48b6150-d6de-4a64-9033-bfc2563758de', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f33375ab-3973-4261-8447-cdb9546484ba', '1faae23e-3054-4ea8-b002-c663343d734f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f33375ab-3973-4261-8447-cdb9546484ba', '295f00b7-64bb-4318-871d-ffd0ec95b00f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f33375ab-3973-4261-8447-cdb9546484ba', '09a08f9c-bcaf-4247-a40f-735bfd1c4370', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dd420495-3b5c-4ea1-a428-0288641ed801', 'a9eb9f06-7159-4ff4-9a4e-c91fa9649d8e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dd420495-3b5c-4ea1-a428-0288641ed801', '4b5eee23-8dd9-46c0-b208-0c27ada15af2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dd420495-3b5c-4ea1-a428-0288641ed801', 'eb4d9593-c0d1-4e42-bf40-d3bf0a55b1ad', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dd420495-3b5c-4ea1-a428-0288641ed801', '091b1055-b231-42be-a6c3-20663abb12fd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dd420495-3b5c-4ea1-a428-0288641ed801', 'c9249e91-0b2c-4a60-bd79-757f89625a60', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a9eb9f06-7159-4ff4-9a4e-c91fa9649d8e', 'dd420495-3b5c-4ea1-a428-0288641ed801', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a9eb9f06-7159-4ff4-9a4e-c91fa9649d8e', '4b5eee23-8dd9-46c0-b208-0c27ada15af2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a9eb9f06-7159-4ff4-9a4e-c91fa9649d8e', 'eb4d9593-c0d1-4e42-bf40-d3bf0a55b1ad', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a9eb9f06-7159-4ff4-9a4e-c91fa9649d8e', '091b1055-b231-42be-a6c3-20663abb12fd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a9eb9f06-7159-4ff4-9a4e-c91fa9649d8e', 'c9249e91-0b2c-4a60-bd79-757f89625a60', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b5eee23-8dd9-46c0-b208-0c27ada15af2', 'dd420495-3b5c-4ea1-a428-0288641ed801', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b5eee23-8dd9-46c0-b208-0c27ada15af2', 'a9eb9f06-7159-4ff4-9a4e-c91fa9649d8e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b5eee23-8dd9-46c0-b208-0c27ada15af2', 'eb4d9593-c0d1-4e42-bf40-d3bf0a55b1ad', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b5eee23-8dd9-46c0-b208-0c27ada15af2', '091b1055-b231-42be-a6c3-20663abb12fd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b5eee23-8dd9-46c0-b208-0c27ada15af2', 'c9249e91-0b2c-4a60-bd79-757f89625a60', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9249e91-0b2c-4a60-bd79-757f89625a60', 'dd420495-3b5c-4ea1-a428-0288641ed801', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9249e91-0b2c-4a60-bd79-757f89625a60', 'a9eb9f06-7159-4ff4-9a4e-c91fa9649d8e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9249e91-0b2c-4a60-bd79-757f89625a60', '4b5eee23-8dd9-46c0-b208-0c27ada15af2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9249e91-0b2c-4a60-bd79-757f89625a60', 'eb4d9593-c0d1-4e42-bf40-d3bf0a55b1ad', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9249e91-0b2c-4a60-bd79-757f89625a60', '091b1055-b231-42be-a6c3-20663abb12fd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb4d9593-c0d1-4e42-bf40-d3bf0a55b1ad', 'dd420495-3b5c-4ea1-a428-0288641ed801', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb4d9593-c0d1-4e42-bf40-d3bf0a55b1ad', 'a9eb9f06-7159-4ff4-9a4e-c91fa9649d8e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb4d9593-c0d1-4e42-bf40-d3bf0a55b1ad', '4b5eee23-8dd9-46c0-b208-0c27ada15af2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb4d9593-c0d1-4e42-bf40-d3bf0a55b1ad', '091b1055-b231-42be-a6c3-20663abb12fd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb4d9593-c0d1-4e42-bf40-d3bf0a55b1ad', 'c9249e91-0b2c-4a60-bd79-757f89625a60', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('091b1055-b231-42be-a6c3-20663abb12fd', 'dd420495-3b5c-4ea1-a428-0288641ed801', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('091b1055-b231-42be-a6c3-20663abb12fd', 'a9eb9f06-7159-4ff4-9a4e-c91fa9649d8e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('091b1055-b231-42be-a6c3-20663abb12fd', '4b5eee23-8dd9-46c0-b208-0c27ada15af2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('091b1055-b231-42be-a6c3-20663abb12fd', 'eb4d9593-c0d1-4e42-bf40-d3bf0a55b1ad', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('091b1055-b231-42be-a6c3-20663abb12fd', 'c9249e91-0b2c-4a60-bd79-757f89625a60', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('68d8244b-07be-474a-9906-733a40728827', 'ef14fa72-c6f2-4705-a3f1-0fc69d1ebc6e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('68d8244b-07be-474a-9906-733a40728827', '6e437211-13b4-4e14-84d0-6271547dfa73', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('68d8244b-07be-474a-9906-733a40728827', '2efbaf3d-bfa5-4556-8dfd-403f47751ae4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('68d8244b-07be-474a-9906-733a40728827', '9fadb633-7dd8-4917-ab41-4591ae41444f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('68d8244b-07be-474a-9906-733a40728827', '95b83ce8-8451-4852-9b91-032e4242935d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('659c9f41-bcd2-4757-91ae-9433e7a856b7', '09a08f9c-bcaf-4247-a40f-735bfd1c4370', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('659c9f41-bcd2-4757-91ae-9433e7a856b7', '19638d3b-c1a7-4526-bc3c-b845ed878a16', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('659c9f41-bcd2-4757-91ae-9433e7a856b7', 'c48b6150-d6de-4a64-9033-bfc2563758de', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('659c9f41-bcd2-4757-91ae-9433e7a856b7', '1faae23e-3054-4ea8-b002-c663343d734f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('659c9f41-bcd2-4757-91ae-9433e7a856b7', '880d2650-6e97-4355-a6ff-a05aaa2d7feb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('570b42f7-9479-421a-93d2-62d8269b97e9', '7b4b17b5-255b-45bc-89bc-ef3c2d602966', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('570b42f7-9479-421a-93d2-62d8269b97e9', 'b9a61c4f-41c3-4ea8-b13d-6245d29a215c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('570b42f7-9479-421a-93d2-62d8269b97e9', '805e0739-b8af-46ce-a865-b05bf92828a2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7b4b17b5-255b-45bc-89bc-ef3c2d602966', '570b42f7-9479-421a-93d2-62d8269b97e9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7b4b17b5-255b-45bc-89bc-ef3c2d602966', 'b9a61c4f-41c3-4ea8-b13d-6245d29a215c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7b4b17b5-255b-45bc-89bc-ef3c2d602966', '805e0739-b8af-46ce-a865-b05bf92828a2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b9a61c4f-41c3-4ea8-b13d-6245d29a215c', '570b42f7-9479-421a-93d2-62d8269b97e9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b9a61c4f-41c3-4ea8-b13d-6245d29a215c', '7b4b17b5-255b-45bc-89bc-ef3c2d602966', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b9a61c4f-41c3-4ea8-b13d-6245d29a215c', '805e0739-b8af-46ce-a865-b05bf92828a2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('805e0739-b8af-46ce-a865-b05bf92828a2', '570b42f7-9479-421a-93d2-62d8269b97e9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('805e0739-b8af-46ce-a865-b05bf92828a2', '7b4b17b5-255b-45bc-89bc-ef3c2d602966', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('805e0739-b8af-46ce-a865-b05bf92828a2', 'b9a61c4f-41c3-4ea8-b13d-6245d29a215c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0605fdd6-d87c-4994-8f04-2c178f756131', '0c58ee69-5d5d-4988-a212-69b98a7711ef', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0605fdd6-d87c-4994-8f04-2c178f756131', 'f06a1813-4a99-4002-bae7-62005cd19953', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0605fdd6-d87c-4994-8f04-2c178f756131', 'b85db40f-596c-4aea-a097-98b6d2a775ba', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0605fdd6-d87c-4994-8f04-2c178f756131', '64b7301a-fb4a-4e13-af46-e96e1790713a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0605fdd6-d87c-4994-8f04-2c178f756131', 'd50775b9-d8ce-4dc0-aed4-0fedd015ffcf', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fbb9dcc5-00fd-4435-883f-0f3b80eaf1c8', 'a685d8e3-f8aa-433c-8aef-a991b3990334', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fbb9dcc5-00fd-4435-883f-0f3b80eaf1c8', '317eff52-efb1-4adc-bb7e-f7f7ba8c6c24', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fbb9dcc5-00fd-4435-883f-0f3b80eaf1c8', '479a7444-a6c5-4d8a-bc02-b3de1677649c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fbb9dcc5-00fd-4435-883f-0f3b80eaf1c8', '7dbb6674-656f-4e0a-8fd8-722ae77b30a3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fbb9dcc5-00fd-4435-883f-0f3b80eaf1c8', '99990b68-c893-41d6-bd47-c595e72366dd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c58ee69-5d5d-4988-a212-69b98a7711ef', '0605fdd6-d87c-4994-8f04-2c178f756131', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c58ee69-5d5d-4988-a212-69b98a7711ef', 'f06a1813-4a99-4002-bae7-62005cd19953', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c58ee69-5d5d-4988-a212-69b98a7711ef', 'b85db40f-596c-4aea-a097-98b6d2a775ba', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c58ee69-5d5d-4988-a212-69b98a7711ef', '64b7301a-fb4a-4e13-af46-e96e1790713a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c58ee69-5d5d-4988-a212-69b98a7711ef', 'd50775b9-d8ce-4dc0-aed4-0fedd015ffcf', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7dbb6674-656f-4e0a-8fd8-722ae77b30a3', 'fbb9dcc5-00fd-4435-883f-0f3b80eaf1c8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7dbb6674-656f-4e0a-8fd8-722ae77b30a3', 'a685d8e3-f8aa-433c-8aef-a991b3990334', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7dbb6674-656f-4e0a-8fd8-722ae77b30a3', '317eff52-efb1-4adc-bb7e-f7f7ba8c6c24', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7dbb6674-656f-4e0a-8fd8-722ae77b30a3', '479a7444-a6c5-4d8a-bc02-b3de1677649c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7dbb6674-656f-4e0a-8fd8-722ae77b30a3', '99990b68-c893-41d6-bd47-c595e72366dd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('367bfe94-dcea-49b5-99bd-39394447b709', '570b42f7-9479-421a-93d2-62d8269b97e9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('367bfe94-dcea-49b5-99bd-39394447b709', '7b4b17b5-255b-45bc-89bc-ef3c2d602966', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('367bfe94-dcea-49b5-99bd-39394447b709', 'b9a61c4f-41c3-4ea8-b13d-6245d29a215c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('367bfe94-dcea-49b5-99bd-39394447b709', '805e0739-b8af-46ce-a865-b05bf92828a2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b85db40f-596c-4aea-a097-98b6d2a775ba', '64b7301a-fb4a-4e13-af46-e96e1790713a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b85db40f-596c-4aea-a097-98b6d2a775ba', 'd50775b9-d8ce-4dc0-aed4-0fedd015ffcf', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b85db40f-596c-4aea-a097-98b6d2a775ba', '053b1176-7c11-4e7d-9c3c-7f1bc6998a68', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b85db40f-596c-4aea-a097-98b6d2a775ba', 'e224ef13-574b-4d36-af55-6210195f5b75', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b85db40f-596c-4aea-a097-98b6d2a775ba', '0605fdd6-d87c-4994-8f04-2c178f756131', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('64b7301a-fb4a-4e13-af46-e96e1790713a', 'b85db40f-596c-4aea-a097-98b6d2a775ba', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('64b7301a-fb4a-4e13-af46-e96e1790713a', 'd50775b9-d8ce-4dc0-aed4-0fedd015ffcf', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('64b7301a-fb4a-4e13-af46-e96e1790713a', '053b1176-7c11-4e7d-9c3c-7f1bc6998a68', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('64b7301a-fb4a-4e13-af46-e96e1790713a', 'e224ef13-574b-4d36-af55-6210195f5b75', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('64b7301a-fb4a-4e13-af46-e96e1790713a', '0605fdd6-d87c-4994-8f04-2c178f756131', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d50775b9-d8ce-4dc0-aed4-0fedd015ffcf', 'b85db40f-596c-4aea-a097-98b6d2a775ba', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d50775b9-d8ce-4dc0-aed4-0fedd015ffcf', '64b7301a-fb4a-4e13-af46-e96e1790713a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d50775b9-d8ce-4dc0-aed4-0fedd015ffcf', '053b1176-7c11-4e7d-9c3c-7f1bc6998a68', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d50775b9-d8ce-4dc0-aed4-0fedd015ffcf', 'e224ef13-574b-4d36-af55-6210195f5b75', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d50775b9-d8ce-4dc0-aed4-0fedd015ffcf', '0605fdd6-d87c-4994-8f04-2c178f756131', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('053b1176-7c11-4e7d-9c3c-7f1bc6998a68', 'b85db40f-596c-4aea-a097-98b6d2a775ba', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('053b1176-7c11-4e7d-9c3c-7f1bc6998a68', '64b7301a-fb4a-4e13-af46-e96e1790713a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('053b1176-7c11-4e7d-9c3c-7f1bc6998a68', 'd50775b9-d8ce-4dc0-aed4-0fedd015ffcf', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('053b1176-7c11-4e7d-9c3c-7f1bc6998a68', 'e224ef13-574b-4d36-af55-6210195f5b75', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('053b1176-7c11-4e7d-9c3c-7f1bc6998a68', '0605fdd6-d87c-4994-8f04-2c178f756131', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('66775356-b7f8-4ee4-966b-80bea35766b3', '0605fdd6-d87c-4994-8f04-2c178f756131', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('66775356-b7f8-4ee4-966b-80bea35766b3', '0c58ee69-5d5d-4988-a212-69b98a7711ef', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('66775356-b7f8-4ee4-966b-80bea35766b3', 'b85db40f-596c-4aea-a097-98b6d2a775ba', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('66775356-b7f8-4ee4-966b-80bea35766b3', '64b7301a-fb4a-4e13-af46-e96e1790713a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('66775356-b7f8-4ee4-966b-80bea35766b3', 'd50775b9-d8ce-4dc0-aed4-0fedd015ffcf', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e224ef13-574b-4d36-af55-6210195f5b75', 'b85db40f-596c-4aea-a097-98b6d2a775ba', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e224ef13-574b-4d36-af55-6210195f5b75', '64b7301a-fb4a-4e13-af46-e96e1790713a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e224ef13-574b-4d36-af55-6210195f5b75', 'd50775b9-d8ce-4dc0-aed4-0fedd015ffcf', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e224ef13-574b-4d36-af55-6210195f5b75', '053b1176-7c11-4e7d-9c3c-7f1bc6998a68', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e224ef13-574b-4d36-af55-6210195f5b75', '0605fdd6-d87c-4994-8f04-2c178f756131', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f06a1813-4a99-4002-bae7-62005cd19953', '0605fdd6-d87c-4994-8f04-2c178f756131', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f06a1813-4a99-4002-bae7-62005cd19953', '0c58ee69-5d5d-4988-a212-69b98a7711ef', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f06a1813-4a99-4002-bae7-62005cd19953', 'b85db40f-596c-4aea-a097-98b6d2a775ba', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f06a1813-4a99-4002-bae7-62005cd19953', '64b7301a-fb4a-4e13-af46-e96e1790713a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f06a1813-4a99-4002-bae7-62005cd19953', 'd50775b9-d8ce-4dc0-aed4-0fedd015ffcf', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0330e907-cd43-4c4a-865a-69e74bfefb54', '570b42f7-9479-421a-93d2-62d8269b97e9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0330e907-cd43-4c4a-865a-69e74bfefb54', '7b4b17b5-255b-45bc-89bc-ef3c2d602966', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0330e907-cd43-4c4a-865a-69e74bfefb54', 'b9a61c4f-41c3-4ea8-b13d-6245d29a215c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0330e907-cd43-4c4a-865a-69e74bfefb54', '805e0739-b8af-46ce-a865-b05bf92828a2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('11900c94-e9a7-48ec-aaf9-8f7f4411d035', '16789399-9d25-42d1-a2cf-4a9f015fba92', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('11900c94-e9a7-48ec-aaf9-8f7f4411d035', 'f22dbb60-83b9-470e-8e71-a4d1986d5114', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('11900c94-e9a7-48ec-aaf9-8f7f4411d035', '87ceafcd-e58f-43ee-bce8-d10986d579de', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('11900c94-e9a7-48ec-aaf9-8f7f4411d035', 'eea44714-b447-4b6a-b6f5-dd000b956381', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('11900c94-e9a7-48ec-aaf9-8f7f4411d035', 'c0b31b2a-87dd-4c6e-b18b-ea1aa59de382', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e2e39a72-2c7d-4d55-b28f-bf7e588afb15', '16789399-9d25-42d1-a2cf-4a9f015fba92', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e2e39a72-2c7d-4d55-b28f-bf7e588afb15', 'f22dbb60-83b9-470e-8e71-a4d1986d5114', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e2e39a72-2c7d-4d55-b28f-bf7e588afb15', '87ceafcd-e58f-43ee-bce8-d10986d579de', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e2e39a72-2c7d-4d55-b28f-bf7e588afb15', 'eea44714-b447-4b6a-b6f5-dd000b956381', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e2e39a72-2c7d-4d55-b28f-bf7e588afb15', 'c0b31b2a-87dd-4c6e-b18b-ea1aa59de382', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16789399-9d25-42d1-a2cf-4a9f015fba92', 'f22dbb60-83b9-470e-8e71-a4d1986d5114', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16789399-9d25-42d1-a2cf-4a9f015fba92', '87ceafcd-e58f-43ee-bce8-d10986d579de', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16789399-9d25-42d1-a2cf-4a9f015fba92', 'eea44714-b447-4b6a-b6f5-dd000b956381', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16789399-9d25-42d1-a2cf-4a9f015fba92', 'c0b31b2a-87dd-4c6e-b18b-ea1aa59de382', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16789399-9d25-42d1-a2cf-4a9f015fba92', 'cbd39c91-42b3-4011-9687-fb55c24a0e1b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f22dbb60-83b9-470e-8e71-a4d1986d5114', '16789399-9d25-42d1-a2cf-4a9f015fba92', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f22dbb60-83b9-470e-8e71-a4d1986d5114', '87ceafcd-e58f-43ee-bce8-d10986d579de', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f22dbb60-83b9-470e-8e71-a4d1986d5114', 'eea44714-b447-4b6a-b6f5-dd000b956381', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f22dbb60-83b9-470e-8e71-a4d1986d5114', 'c0b31b2a-87dd-4c6e-b18b-ea1aa59de382', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f22dbb60-83b9-470e-8e71-a4d1986d5114', 'cbd39c91-42b3-4011-9687-fb55c24a0e1b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('87ceafcd-e58f-43ee-bce8-d10986d579de', '16789399-9d25-42d1-a2cf-4a9f015fba92', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('87ceafcd-e58f-43ee-bce8-d10986d579de', 'f22dbb60-83b9-470e-8e71-a4d1986d5114', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('87ceafcd-e58f-43ee-bce8-d10986d579de', 'eea44714-b447-4b6a-b6f5-dd000b956381', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('87ceafcd-e58f-43ee-bce8-d10986d579de', 'c0b31b2a-87dd-4c6e-b18b-ea1aa59de382', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('87ceafcd-e58f-43ee-bce8-d10986d579de', 'cbd39c91-42b3-4011-9687-fb55c24a0e1b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eea44714-b447-4b6a-b6f5-dd000b956381', '16789399-9d25-42d1-a2cf-4a9f015fba92', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eea44714-b447-4b6a-b6f5-dd000b956381', 'f22dbb60-83b9-470e-8e71-a4d1986d5114', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eea44714-b447-4b6a-b6f5-dd000b956381', '87ceafcd-e58f-43ee-bce8-d10986d579de', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eea44714-b447-4b6a-b6f5-dd000b956381', 'c0b31b2a-87dd-4c6e-b18b-ea1aa59de382', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eea44714-b447-4b6a-b6f5-dd000b956381', 'cbd39c91-42b3-4011-9687-fb55c24a0e1b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c0b31b2a-87dd-4c6e-b18b-ea1aa59de382', '16789399-9d25-42d1-a2cf-4a9f015fba92', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c0b31b2a-87dd-4c6e-b18b-ea1aa59de382', 'f22dbb60-83b9-470e-8e71-a4d1986d5114', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c0b31b2a-87dd-4c6e-b18b-ea1aa59de382', '87ceafcd-e58f-43ee-bce8-d10986d579de', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c0b31b2a-87dd-4c6e-b18b-ea1aa59de382', 'eea44714-b447-4b6a-b6f5-dd000b956381', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c0b31b2a-87dd-4c6e-b18b-ea1aa59de382', 'cbd39c91-42b3-4011-9687-fb55c24a0e1b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cbd39c91-42b3-4011-9687-fb55c24a0e1b', '16789399-9d25-42d1-a2cf-4a9f015fba92', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cbd39c91-42b3-4011-9687-fb55c24a0e1b', 'f22dbb60-83b9-470e-8e71-a4d1986d5114', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cbd39c91-42b3-4011-9687-fb55c24a0e1b', '87ceafcd-e58f-43ee-bce8-d10986d579de', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cbd39c91-42b3-4011-9687-fb55c24a0e1b', 'eea44714-b447-4b6a-b6f5-dd000b956381', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cbd39c91-42b3-4011-9687-fb55c24a0e1b', 'c0b31b2a-87dd-4c6e-b18b-ea1aa59de382', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b06bb55-135b-4651-994c-54d74bb4cf4d', '16789399-9d25-42d1-a2cf-4a9f015fba92', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b06bb55-135b-4651-994c-54d74bb4cf4d', 'f22dbb60-83b9-470e-8e71-a4d1986d5114', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b06bb55-135b-4651-994c-54d74bb4cf4d', '87ceafcd-e58f-43ee-bce8-d10986d579de', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b06bb55-135b-4651-994c-54d74bb4cf4d', 'eea44714-b447-4b6a-b6f5-dd000b956381', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b06bb55-135b-4651-994c-54d74bb4cf4d', 'c0b31b2a-87dd-4c6e-b18b-ea1aa59de382', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fd40af84-3e11-47ce-b948-e5d18f8d09f9', '3a534df6-57c6-4501-97fd-4079b5b1b8eb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fd40af84-3e11-47ce-b948-e5d18f8d09f9', '9d689e94-6b9c-4aa1-ba35-350acdb1dbf8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fd40af84-3e11-47ce-b948-e5d18f8d09f9', 'a83dfd53-0bbf-4e07-9506-946af2130334', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fd40af84-3e11-47ce-b948-e5d18f8d09f9', '842420d6-23a2-4151-bafb-9ce8f69eac0a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fd40af84-3e11-47ce-b948-e5d18f8d09f9', '683ad0dc-d865-4636-8bfe-cc686b2259a9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a534df6-57c6-4501-97fd-4079b5b1b8eb', 'fd40af84-3e11-47ce-b948-e5d18f8d09f9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a534df6-57c6-4501-97fd-4079b5b1b8eb', '9d689e94-6b9c-4aa1-ba35-350acdb1dbf8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a534df6-57c6-4501-97fd-4079b5b1b8eb', 'a83dfd53-0bbf-4e07-9506-946af2130334', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a534df6-57c6-4501-97fd-4079b5b1b8eb', '842420d6-23a2-4151-bafb-9ce8f69eac0a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a534df6-57c6-4501-97fd-4079b5b1b8eb', '683ad0dc-d865-4636-8bfe-cc686b2259a9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9d689e94-6b9c-4aa1-ba35-350acdb1dbf8', 'fd40af84-3e11-47ce-b948-e5d18f8d09f9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9d689e94-6b9c-4aa1-ba35-350acdb1dbf8', '3a534df6-57c6-4501-97fd-4079b5b1b8eb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9d689e94-6b9c-4aa1-ba35-350acdb1dbf8', 'a83dfd53-0bbf-4e07-9506-946af2130334', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9d689e94-6b9c-4aa1-ba35-350acdb1dbf8', '842420d6-23a2-4151-bafb-9ce8f69eac0a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9d689e94-6b9c-4aa1-ba35-350acdb1dbf8', '683ad0dc-d865-4636-8bfe-cc686b2259a9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a83dfd53-0bbf-4e07-9506-946af2130334', 'fd40af84-3e11-47ce-b948-e5d18f8d09f9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a83dfd53-0bbf-4e07-9506-946af2130334', '3a534df6-57c6-4501-97fd-4079b5b1b8eb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a83dfd53-0bbf-4e07-9506-946af2130334', '9d689e94-6b9c-4aa1-ba35-350acdb1dbf8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a83dfd53-0bbf-4e07-9506-946af2130334', '842420d6-23a2-4151-bafb-9ce8f69eac0a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a83dfd53-0bbf-4e07-9506-946af2130334', '683ad0dc-d865-4636-8bfe-cc686b2259a9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('842420d6-23a2-4151-bafb-9ce8f69eac0a', 'fd40af84-3e11-47ce-b948-e5d18f8d09f9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('842420d6-23a2-4151-bafb-9ce8f69eac0a', '3a534df6-57c6-4501-97fd-4079b5b1b8eb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('842420d6-23a2-4151-bafb-9ce8f69eac0a', '9d689e94-6b9c-4aa1-ba35-350acdb1dbf8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('842420d6-23a2-4151-bafb-9ce8f69eac0a', 'a83dfd53-0bbf-4e07-9506-946af2130334', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('842420d6-23a2-4151-bafb-9ce8f69eac0a', '683ad0dc-d865-4636-8bfe-cc686b2259a9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('683ad0dc-d865-4636-8bfe-cc686b2259a9', 'fd40af84-3e11-47ce-b948-e5d18f8d09f9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('683ad0dc-d865-4636-8bfe-cc686b2259a9', '3a534df6-57c6-4501-97fd-4079b5b1b8eb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('683ad0dc-d865-4636-8bfe-cc686b2259a9', '9d689e94-6b9c-4aa1-ba35-350acdb1dbf8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('683ad0dc-d865-4636-8bfe-cc686b2259a9', 'a83dfd53-0bbf-4e07-9506-946af2130334', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('683ad0dc-d865-4636-8bfe-cc686b2259a9', '842420d6-23a2-4151-bafb-9ce8f69eac0a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('af675da9-1848-4642-a14c-45fb9901473d', 'fd40af84-3e11-47ce-b948-e5d18f8d09f9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('af675da9-1848-4642-a14c-45fb9901473d', '3a534df6-57c6-4501-97fd-4079b5b1b8eb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('af675da9-1848-4642-a14c-45fb9901473d', '9d689e94-6b9c-4aa1-ba35-350acdb1dbf8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('af675da9-1848-4642-a14c-45fb9901473d', 'a83dfd53-0bbf-4e07-9506-946af2130334', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('af675da9-1848-4642-a14c-45fb9901473d', '842420d6-23a2-4151-bafb-9ce8f69eac0a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6f81f99d-2b44-4b51-b3cd-9e2ac03e6f4e', 'fd40af84-3e11-47ce-b948-e5d18f8d09f9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6f81f99d-2b44-4b51-b3cd-9e2ac03e6f4e', '3a534df6-57c6-4501-97fd-4079b5b1b8eb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6f81f99d-2b44-4b51-b3cd-9e2ac03e6f4e', '9d689e94-6b9c-4aa1-ba35-350acdb1dbf8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6f81f99d-2b44-4b51-b3cd-9e2ac03e6f4e', 'a83dfd53-0bbf-4e07-9506-946af2130334', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6f81f99d-2b44-4b51-b3cd-9e2ac03e6f4e', '842420d6-23a2-4151-bafb-9ce8f69eac0a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('60f5e640-ffc7-461d-b59f-a921efefb213', 'b0e28e1d-38c5-45f8-b025-d6f069f2a0e2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('60f5e640-ffc7-461d-b59f-a921efefb213', 'fd40af84-3e11-47ce-b948-e5d18f8d09f9', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('60f5e640-ffc7-461d-b59f-a921efefb213', '3a534df6-57c6-4501-97fd-4079b5b1b8eb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('60f5e640-ffc7-461d-b59f-a921efefb213', '9d689e94-6b9c-4aa1-ba35-350acdb1dbf8', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('60f5e640-ffc7-461d-b59f-a921efefb213', 'a83dfd53-0bbf-4e07-9506-946af2130334', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc4dfff3-20ce-4a0c-9c9e-0822a99f6a83', '16789399-9d25-42d1-a2cf-4a9f015fba92', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc4dfff3-20ce-4a0c-9c9e-0822a99f6a83', 'f22dbb60-83b9-470e-8e71-a4d1986d5114', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc4dfff3-20ce-4a0c-9c9e-0822a99f6a83', '87ceafcd-e58f-43ee-bce8-d10986d579de', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc4dfff3-20ce-4a0c-9c9e-0822a99f6a83', 'eea44714-b447-4b6a-b6f5-dd000b956381', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc4dfff3-20ce-4a0c-9c9e-0822a99f6a83', 'c0b31b2a-87dd-4c6e-b18b-ea1aa59de382', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b0e28e1d-38c5-45f8-b025-d6f069f2a0e2', '60f5e640-ffc7-461d-b59f-a921efefb213', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b0e28e1d-38c5-45f8-b025-d6f069f2a0e2', 'fd40af84-3e11-47ce-b948-e5d18f8d09f9', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b0e28e1d-38c5-45f8-b025-d6f069f2a0e2', '3a534df6-57c6-4501-97fd-4079b5b1b8eb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b0e28e1d-38c5-45f8-b025-d6f069f2a0e2', '9d689e94-6b9c-4aa1-ba35-350acdb1dbf8', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b0e28e1d-38c5-45f8-b025-d6f069f2a0e2', 'a83dfd53-0bbf-4e07-9506-946af2130334', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('81a993df-a0dc-498d-b598-eb434eafe5ca', '4fa9f03f-8126-41f0-8172-3492d97fe8ff', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('81a993df-a0dc-498d-b598-eb434eafe5ca', 'e3af2027-c6f8-49ef-b6c3-6c1c1159e73d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('81a993df-a0dc-498d-b598-eb434eafe5ca', 'a46b38f8-0a90-405b-8165-ed4bcefc7e7d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('81a993df-a0dc-498d-b598-eb434eafe5ca', '7e09cc43-9807-4cf7-b006-47a55b0fead6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('81a993df-a0dc-498d-b598-eb434eafe5ca', '8f485271-45e7-4983-a3e5-90c85e2549bb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4fa9f03f-8126-41f0-8172-3492d97fe8ff', '81a993df-a0dc-498d-b598-eb434eafe5ca', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4fa9f03f-8126-41f0-8172-3492d97fe8ff', 'e3af2027-c6f8-49ef-b6c3-6c1c1159e73d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4fa9f03f-8126-41f0-8172-3492d97fe8ff', 'a46b38f8-0a90-405b-8165-ed4bcefc7e7d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4fa9f03f-8126-41f0-8172-3492d97fe8ff', '7e09cc43-9807-4cf7-b006-47a55b0fead6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4fa9f03f-8126-41f0-8172-3492d97fe8ff', '8f485271-45e7-4983-a3e5-90c85e2549bb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3af2027-c6f8-49ef-b6c3-6c1c1159e73d', '81a993df-a0dc-498d-b598-eb434eafe5ca', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3af2027-c6f8-49ef-b6c3-6c1c1159e73d', '4fa9f03f-8126-41f0-8172-3492d97fe8ff', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3af2027-c6f8-49ef-b6c3-6c1c1159e73d', 'a46b38f8-0a90-405b-8165-ed4bcefc7e7d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3af2027-c6f8-49ef-b6c3-6c1c1159e73d', '7e09cc43-9807-4cf7-b006-47a55b0fead6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3af2027-c6f8-49ef-b6c3-6c1c1159e73d', '8f485271-45e7-4983-a3e5-90c85e2549bb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a46b38f8-0a90-405b-8165-ed4bcefc7e7d', '81a993df-a0dc-498d-b598-eb434eafe5ca', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a46b38f8-0a90-405b-8165-ed4bcefc7e7d', '4fa9f03f-8126-41f0-8172-3492d97fe8ff', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a46b38f8-0a90-405b-8165-ed4bcefc7e7d', 'e3af2027-c6f8-49ef-b6c3-6c1c1159e73d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a46b38f8-0a90-405b-8165-ed4bcefc7e7d', '7e09cc43-9807-4cf7-b006-47a55b0fead6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a46b38f8-0a90-405b-8165-ed4bcefc7e7d', '8f485271-45e7-4983-a3e5-90c85e2549bb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7e09cc43-9807-4cf7-b006-47a55b0fead6', '81a993df-a0dc-498d-b598-eb434eafe5ca', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7e09cc43-9807-4cf7-b006-47a55b0fead6', '4fa9f03f-8126-41f0-8172-3492d97fe8ff', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7e09cc43-9807-4cf7-b006-47a55b0fead6', 'e3af2027-c6f8-49ef-b6c3-6c1c1159e73d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7e09cc43-9807-4cf7-b006-47a55b0fead6', 'a46b38f8-0a90-405b-8165-ed4bcefc7e7d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7e09cc43-9807-4cf7-b006-47a55b0fead6', '8f485271-45e7-4983-a3e5-90c85e2549bb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('88ac5ffe-f7ae-4273-b70b-e4d241c93c33', '81a993df-a0dc-498d-b598-eb434eafe5ca', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('88ac5ffe-f7ae-4273-b70b-e4d241c93c33', '4fa9f03f-8126-41f0-8172-3492d97fe8ff', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('88ac5ffe-f7ae-4273-b70b-e4d241c93c33', 'e3af2027-c6f8-49ef-b6c3-6c1c1159e73d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('88ac5ffe-f7ae-4273-b70b-e4d241c93c33', 'a46b38f8-0a90-405b-8165-ed4bcefc7e7d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('88ac5ffe-f7ae-4273-b70b-e4d241c93c33', '7e09cc43-9807-4cf7-b006-47a55b0fead6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f485271-45e7-4983-a3e5-90c85e2549bb', '81a993df-a0dc-498d-b598-eb434eafe5ca', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f485271-45e7-4983-a3e5-90c85e2549bb', '4fa9f03f-8126-41f0-8172-3492d97fe8ff', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f485271-45e7-4983-a3e5-90c85e2549bb', 'e3af2027-c6f8-49ef-b6c3-6c1c1159e73d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f485271-45e7-4983-a3e5-90c85e2549bb', 'a46b38f8-0a90-405b-8165-ed4bcefc7e7d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f485271-45e7-4983-a3e5-90c85e2549bb', '7e09cc43-9807-4cf7-b006-47a55b0fead6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a8af9d3c-8d49-4fce-818e-65dcb43f8031', '81a993df-a0dc-498d-b598-eb434eafe5ca', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a8af9d3c-8d49-4fce-818e-65dcb43f8031', '4fa9f03f-8126-41f0-8172-3492d97fe8ff', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a8af9d3c-8d49-4fce-818e-65dcb43f8031', 'e3af2027-c6f8-49ef-b6c3-6c1c1159e73d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a8af9d3c-8d49-4fce-818e-65dcb43f8031', 'a46b38f8-0a90-405b-8165-ed4bcefc7e7d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a8af9d3c-8d49-4fce-818e-65dcb43f8031', '7e09cc43-9807-4cf7-b006-47a55b0fead6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ed2dfc56-bd57-4372-8214-cf3539e68297', '81a993df-a0dc-498d-b598-eb434eafe5ca', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ed2dfc56-bd57-4372-8214-cf3539e68297', '4fa9f03f-8126-41f0-8172-3492d97fe8ff', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ed2dfc56-bd57-4372-8214-cf3539e68297', 'e3af2027-c6f8-49ef-b6c3-6c1c1159e73d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ed2dfc56-bd57-4372-8214-cf3539e68297', 'a46b38f8-0a90-405b-8165-ed4bcefc7e7d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ed2dfc56-bd57-4372-8214-cf3539e68297', '7e09cc43-9807-4cf7-b006-47a55b0fead6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d9b17593-b7e0-4dd6-88e7-c70047fc8787', '26d3dd01-5df0-4888-983c-5d9f0c31f321', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d9b17593-b7e0-4dd6-88e7-c70047fc8787', '0eb660cd-9662-4ec1-b76d-01ec49ebf520', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d9b17593-b7e0-4dd6-88e7-c70047fc8787', '81a993df-a0dc-498d-b598-eb434eafe5ca', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d9b17593-b7e0-4dd6-88e7-c70047fc8787', '4fa9f03f-8126-41f0-8172-3492d97fe8ff', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d9b17593-b7e0-4dd6-88e7-c70047fc8787', 'e3af2027-c6f8-49ef-b6c3-6c1c1159e73d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('26d3dd01-5df0-4888-983c-5d9f0c31f321', 'd9b17593-b7e0-4dd6-88e7-c70047fc8787', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('26d3dd01-5df0-4888-983c-5d9f0c31f321', '0eb660cd-9662-4ec1-b76d-01ec49ebf520', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('26d3dd01-5df0-4888-983c-5d9f0c31f321', '81a993df-a0dc-498d-b598-eb434eafe5ca', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('26d3dd01-5df0-4888-983c-5d9f0c31f321', '4fa9f03f-8126-41f0-8172-3492d97fe8ff', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('26d3dd01-5df0-4888-983c-5d9f0c31f321', 'e3af2027-c6f8-49ef-b6c3-6c1c1159e73d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0eb660cd-9662-4ec1-b76d-01ec49ebf520', 'd9b17593-b7e0-4dd6-88e7-c70047fc8787', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0eb660cd-9662-4ec1-b76d-01ec49ebf520', '26d3dd01-5df0-4888-983c-5d9f0c31f321', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0eb660cd-9662-4ec1-b76d-01ec49ebf520', '81a993df-a0dc-498d-b598-eb434eafe5ca', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0eb660cd-9662-4ec1-b76d-01ec49ebf520', '4fa9f03f-8126-41f0-8172-3492d97fe8ff', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0eb660cd-9662-4ec1-b76d-01ec49ebf520', 'e3af2027-c6f8-49ef-b6c3-6c1c1159e73d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45b4aabf-82f6-4f3a-9d68-5ee7ce66aaa3', '81a993df-a0dc-498d-b598-eb434eafe5ca', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45b4aabf-82f6-4f3a-9d68-5ee7ce66aaa3', '4fa9f03f-8126-41f0-8172-3492d97fe8ff', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45b4aabf-82f6-4f3a-9d68-5ee7ce66aaa3', 'e3af2027-c6f8-49ef-b6c3-6c1c1159e73d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45b4aabf-82f6-4f3a-9d68-5ee7ce66aaa3', 'a46b38f8-0a90-405b-8165-ed4bcefc7e7d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45b4aabf-82f6-4f3a-9d68-5ee7ce66aaa3', '7e09cc43-9807-4cf7-b006-47a55b0fead6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22f24b3b-d89b-43d1-b7fd-71f662f9c727', '8f053287-d454-47a6-9611-4ffab20d3413', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22f24b3b-d89b-43d1-b7fd-71f662f9c727', '81a993df-a0dc-498d-b598-eb434eafe5ca', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22f24b3b-d89b-43d1-b7fd-71f662f9c727', '4fa9f03f-8126-41f0-8172-3492d97fe8ff', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4e51bd50-32ed-4679-a889-c103a133f459', '81a993df-a0dc-498d-b598-eb434eafe5ca', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4e51bd50-32ed-4679-a889-c103a133f459', '4fa9f03f-8126-41f0-8172-3492d97fe8ff', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4e51bd50-32ed-4679-a889-c103a133f459', 'e3af2027-c6f8-49ef-b6c3-6c1c1159e73d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4e51bd50-32ed-4679-a889-c103a133f459', 'a46b38f8-0a90-405b-8165-ed4bcefc7e7d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4e51bd50-32ed-4679-a889-c103a133f459', '7e09cc43-9807-4cf7-b006-47a55b0fead6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f053287-d454-47a6-9611-4ffab20d3413', '22f24b3b-d89b-43d1-b7fd-71f662f9c727', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f053287-d454-47a6-9611-4ffab20d3413', '81a993df-a0dc-498d-b598-eb434eafe5ca', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f053287-d454-47a6-9611-4ffab20d3413', '4fa9f03f-8126-41f0-8172-3492d97fe8ff', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f281e3d1-51d5-4c95-8991-bec339b61380', '81a993df-a0dc-498d-b598-eb434eafe5ca', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f281e3d1-51d5-4c95-8991-bec339b61380', '4fa9f03f-8126-41f0-8172-3492d97fe8ff', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f281e3d1-51d5-4c95-8991-bec339b61380', 'e3af2027-c6f8-49ef-b6c3-6c1c1159e73d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f281e3d1-51d5-4c95-8991-bec339b61380', 'a46b38f8-0a90-405b-8165-ed4bcefc7e7d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f281e3d1-51d5-4c95-8991-bec339b61380', '7e09cc43-9807-4cf7-b006-47a55b0fead6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e17d2298-55b7-43e5-a836-e05b6179d075', '81a993df-a0dc-498d-b598-eb434eafe5ca', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e17d2298-55b7-43e5-a836-e05b6179d075', '4fa9f03f-8126-41f0-8172-3492d97fe8ff', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e17d2298-55b7-43e5-a836-e05b6179d075', 'e3af2027-c6f8-49ef-b6c3-6c1c1159e73d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e17d2298-55b7-43e5-a836-e05b6179d075', 'a46b38f8-0a90-405b-8165-ed4bcefc7e7d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e17d2298-55b7-43e5-a836-e05b6179d075', '7e09cc43-9807-4cf7-b006-47a55b0fead6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9cba8e1e-dccb-445d-b8da-f55fa0832de8', '37fb949a-27b4-4773-bd6b-935edf7d2752', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9cba8e1e-dccb-445d-b8da-f55fa0832de8', '622587b3-c23f-49c8-81c9-24021af114dc', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9cba8e1e-dccb-445d-b8da-f55fa0832de8', 'e4c6a7b8-69d7-4a34-920f-c2d983232a0a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9cba8e1e-dccb-445d-b8da-f55fa0832de8', '0241376f-fd2d-4f06-8ad1-ca50abaec6e3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9cba8e1e-dccb-445d-b8da-f55fa0832de8', 'd507596e-004e-478a-a0f3-986b5d095468', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('37fb949a-27b4-4773-bd6b-935edf7d2752', '9cba8e1e-dccb-445d-b8da-f55fa0832de8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('37fb949a-27b4-4773-bd6b-935edf7d2752', '622587b3-c23f-49c8-81c9-24021af114dc', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('37fb949a-27b4-4773-bd6b-935edf7d2752', 'e4c6a7b8-69d7-4a34-920f-c2d983232a0a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('37fb949a-27b4-4773-bd6b-935edf7d2752', '0241376f-fd2d-4f06-8ad1-ca50abaec6e3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('37fb949a-27b4-4773-bd6b-935edf7d2752', 'd507596e-004e-478a-a0f3-986b5d095468', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('622587b3-c23f-49c8-81c9-24021af114dc', '9cba8e1e-dccb-445d-b8da-f55fa0832de8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('622587b3-c23f-49c8-81c9-24021af114dc', '37fb949a-27b4-4773-bd6b-935edf7d2752', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('622587b3-c23f-49c8-81c9-24021af114dc', 'e4c6a7b8-69d7-4a34-920f-c2d983232a0a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('622587b3-c23f-49c8-81c9-24021af114dc', '0241376f-fd2d-4f06-8ad1-ca50abaec6e3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('622587b3-c23f-49c8-81c9-24021af114dc', 'd507596e-004e-478a-a0f3-986b5d095468', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e4c6a7b8-69d7-4a34-920f-c2d983232a0a', '0241376f-fd2d-4f06-8ad1-ca50abaec6e3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e4c6a7b8-69d7-4a34-920f-c2d983232a0a', 'd507596e-004e-478a-a0f3-986b5d095468', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e4c6a7b8-69d7-4a34-920f-c2d983232a0a', 'e7946c1f-1043-4418-8c2c-f74b5eda3833', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e4c6a7b8-69d7-4a34-920f-c2d983232a0a', '3cf8c2e2-6cd7-4ddd-aa2c-b09fe6e6dab9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e4c6a7b8-69d7-4a34-920f-c2d983232a0a', '30f06711-e719-41bf-bd29-0134e17b0b40', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc51784e-1d38-4e28-8a19-23d8b7ad38bd', 'ce011cf0-8795-48b9-86be-eddc4687e8f9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc51784e-1d38-4e28-8a19-23d8b7ad38bd', '07621952-d77b-452e-a101-4fab913a065f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc51784e-1d38-4e28-8a19-23d8b7ad38bd', 'e76fde01-b89d-48d2-a96b-fdc126fb97df', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0241376f-fd2d-4f06-8ad1-ca50abaec6e3', 'e4c6a7b8-69d7-4a34-920f-c2d983232a0a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0241376f-fd2d-4f06-8ad1-ca50abaec6e3', 'd507596e-004e-478a-a0f3-986b5d095468', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0241376f-fd2d-4f06-8ad1-ca50abaec6e3', 'e7946c1f-1043-4418-8c2c-f74b5eda3833', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0241376f-fd2d-4f06-8ad1-ca50abaec6e3', '3cf8c2e2-6cd7-4ddd-aa2c-b09fe6e6dab9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0241376f-fd2d-4f06-8ad1-ca50abaec6e3', '30f06711-e719-41bf-bd29-0134e17b0b40', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d507596e-004e-478a-a0f3-986b5d095468', 'e4c6a7b8-69d7-4a34-920f-c2d983232a0a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d507596e-004e-478a-a0f3-986b5d095468', '0241376f-fd2d-4f06-8ad1-ca50abaec6e3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d507596e-004e-478a-a0f3-986b5d095468', 'e7946c1f-1043-4418-8c2c-f74b5eda3833', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d507596e-004e-478a-a0f3-986b5d095468', '3cf8c2e2-6cd7-4ddd-aa2c-b09fe6e6dab9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d507596e-004e-478a-a0f3-986b5d095468', '30f06711-e719-41bf-bd29-0134e17b0b40', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e7946c1f-1043-4418-8c2c-f74b5eda3833', 'e4c6a7b8-69d7-4a34-920f-c2d983232a0a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e7946c1f-1043-4418-8c2c-f74b5eda3833', '0241376f-fd2d-4f06-8ad1-ca50abaec6e3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e7946c1f-1043-4418-8c2c-f74b5eda3833', 'd507596e-004e-478a-a0f3-986b5d095468', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e7946c1f-1043-4418-8c2c-f74b5eda3833', '3cf8c2e2-6cd7-4ddd-aa2c-b09fe6e6dab9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e7946c1f-1043-4418-8c2c-f74b5eda3833', '30f06711-e719-41bf-bd29-0134e17b0b40', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3cf8c2e2-6cd7-4ddd-aa2c-b09fe6e6dab9', 'e4c6a7b8-69d7-4a34-920f-c2d983232a0a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3cf8c2e2-6cd7-4ddd-aa2c-b09fe6e6dab9', '0241376f-fd2d-4f06-8ad1-ca50abaec6e3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3cf8c2e2-6cd7-4ddd-aa2c-b09fe6e6dab9', 'd507596e-004e-478a-a0f3-986b5d095468', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3cf8c2e2-6cd7-4ddd-aa2c-b09fe6e6dab9', 'e7946c1f-1043-4418-8c2c-f74b5eda3833', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3cf8c2e2-6cd7-4ddd-aa2c-b09fe6e6dab9', '30f06711-e719-41bf-bd29-0134e17b0b40', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('30f06711-e719-41bf-bd29-0134e17b0b40', 'e4c6a7b8-69d7-4a34-920f-c2d983232a0a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('30f06711-e719-41bf-bd29-0134e17b0b40', '0241376f-fd2d-4f06-8ad1-ca50abaec6e3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('30f06711-e719-41bf-bd29-0134e17b0b40', 'd507596e-004e-478a-a0f3-986b5d095468', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('30f06711-e719-41bf-bd29-0134e17b0b40', 'e7946c1f-1043-4418-8c2c-f74b5eda3833', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('30f06711-e719-41bf-bd29-0134e17b0b40', '3cf8c2e2-6cd7-4ddd-aa2c-b09fe6e6dab9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8cc961d8-de85-49aa-a1a6-4525c7fa0e4d', 'e4c6a7b8-69d7-4a34-920f-c2d983232a0a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8cc961d8-de85-49aa-a1a6-4525c7fa0e4d', '0241376f-fd2d-4f06-8ad1-ca50abaec6e3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8cc961d8-de85-49aa-a1a6-4525c7fa0e4d', 'd507596e-004e-478a-a0f3-986b5d095468', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8cc961d8-de85-49aa-a1a6-4525c7fa0e4d', 'e7946c1f-1043-4418-8c2c-f74b5eda3833', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8cc961d8-de85-49aa-a1a6-4525c7fa0e4d', '3cf8c2e2-6cd7-4ddd-aa2c-b09fe6e6dab9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('12a18553-9f99-44bc-a297-f76cfea02cf5', 'e4c6a7b8-69d7-4a34-920f-c2d983232a0a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('12a18553-9f99-44bc-a297-f76cfea02cf5', '0241376f-fd2d-4f06-8ad1-ca50abaec6e3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('12a18553-9f99-44bc-a297-f76cfea02cf5', 'd507596e-004e-478a-a0f3-986b5d095468', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('12a18553-9f99-44bc-a297-f76cfea02cf5', 'e7946c1f-1043-4418-8c2c-f74b5eda3833', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('12a18553-9f99-44bc-a297-f76cfea02cf5', '3cf8c2e2-6cd7-4ddd-aa2c-b09fe6e6dab9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('57b9b0d1-d123-4862-8dbb-991303936849', 'e4c6a7b8-69d7-4a34-920f-c2d983232a0a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('57b9b0d1-d123-4862-8dbb-991303936849', '0241376f-fd2d-4f06-8ad1-ca50abaec6e3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('57b9b0d1-d123-4862-8dbb-991303936849', 'd507596e-004e-478a-a0f3-986b5d095468', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('57b9b0d1-d123-4862-8dbb-991303936849', 'e7946c1f-1043-4418-8c2c-f74b5eda3833', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('57b9b0d1-d123-4862-8dbb-991303936849', '3cf8c2e2-6cd7-4ddd-aa2c-b09fe6e6dab9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('32388468-af52-4ce5-8aec-3987d523bce7', 'e4c6a7b8-69d7-4a34-920f-c2d983232a0a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('32388468-af52-4ce5-8aec-3987d523bce7', '0241376f-fd2d-4f06-8ad1-ca50abaec6e3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('32388468-af52-4ce5-8aec-3987d523bce7', 'd507596e-004e-478a-a0f3-986b5d095468', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('32388468-af52-4ce5-8aec-3987d523bce7', 'e7946c1f-1043-4418-8c2c-f74b5eda3833', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('32388468-af52-4ce5-8aec-3987d523bce7', '3cf8c2e2-6cd7-4ddd-aa2c-b09fe6e6dab9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('265b7f22-e217-4bf9-8cb9-76f4810a897e', '9cba8e1e-dccb-445d-b8da-f55fa0832de8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('265b7f22-e217-4bf9-8cb9-76f4810a897e', '37fb949a-27b4-4773-bd6b-935edf7d2752', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('265b7f22-e217-4bf9-8cb9-76f4810a897e', '622587b3-c23f-49c8-81c9-24021af114dc', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('265b7f22-e217-4bf9-8cb9-76f4810a897e', 'e4c6a7b8-69d7-4a34-920f-c2d983232a0a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('265b7f22-e217-4bf9-8cb9-76f4810a897e', '0241376f-fd2d-4f06-8ad1-ca50abaec6e3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7b6b6f6-b290-400a-9b38-3a00f4502630', 'c8460171-1cc0-41b0-bfc0-a388eb4efe51', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7b6b6f6-b290-400a-9b38-3a00f4502630', '96e759bc-7b51-423c-94db-fbd79692c8a5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7b6b6f6-b290-400a-9b38-3a00f4502630', '66bb6b0b-1ce4-4548-87d1-6951e9a266e4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7b6b6f6-b290-400a-9b38-3a00f4502630', 'e1fbf528-b0e8-46bc-b574-f7f672affad4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7b6b6f6-b290-400a-9b38-3a00f4502630', 'a2bf7471-75ae-446c-95bc-9b0b6707b385', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c8460171-1cc0-41b0-bfc0-a388eb4efe51', 'b7b6b6f6-b290-400a-9b38-3a00f4502630', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c8460171-1cc0-41b0-bfc0-a388eb4efe51', '96e759bc-7b51-423c-94db-fbd79692c8a5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c8460171-1cc0-41b0-bfc0-a388eb4efe51', '66bb6b0b-1ce4-4548-87d1-6951e9a266e4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c8460171-1cc0-41b0-bfc0-a388eb4efe51', 'e1fbf528-b0e8-46bc-b574-f7f672affad4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c8460171-1cc0-41b0-bfc0-a388eb4efe51', 'a2bf7471-75ae-446c-95bc-9b0b6707b385', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d91aff09-23ed-4727-b6be-763d9aae3ff5', 'c8460171-1cc0-41b0-bfc0-a388eb4efe51', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d91aff09-23ed-4727-b6be-763d9aae3ff5', 'b7b6b6f6-b290-400a-9b38-3a00f4502630', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d91aff09-23ed-4727-b6be-763d9aae3ff5', '96e759bc-7b51-423c-94db-fbd79692c8a5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d91aff09-23ed-4727-b6be-763d9aae3ff5', '66bb6b0b-1ce4-4548-87d1-6951e9a266e4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d91aff09-23ed-4727-b6be-763d9aae3ff5', 'e1fbf528-b0e8-46bc-b574-f7f672affad4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('96e759bc-7b51-423c-94db-fbd79692c8a5', '57a98fe9-e604-4f7f-ae69-e5c46c1527cf', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('96e759bc-7b51-423c-94db-fbd79692c8a5', '82aa0c7e-d6c7-4847-8771-940b384b65b4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('96e759bc-7b51-423c-94db-fbd79692c8a5', '8b05b931-4886-4fa4-a099-f43977f76b58', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('96e759bc-7b51-423c-94db-fbd79692c8a5', 'b7b6b6f6-b290-400a-9b38-3a00f4502630', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('96e759bc-7b51-423c-94db-fbd79692c8a5', 'c8460171-1cc0-41b0-bfc0-a388eb4efe51', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('66bb6b0b-1ce4-4548-87d1-6951e9a266e4', 'e1fbf528-b0e8-46bc-b574-f7f672affad4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('66bb6b0b-1ce4-4548-87d1-6951e9a266e4', 'a2bf7471-75ae-446c-95bc-9b0b6707b385', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('66bb6b0b-1ce4-4548-87d1-6951e9a266e4', '65b69690-bbd0-4f96-b1e3-ae1a79864fa2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('66bb6b0b-1ce4-4548-87d1-6951e9a266e4', '2f08a737-e5b5-4816-8db7-28ce637e0636', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('66bb6b0b-1ce4-4548-87d1-6951e9a266e4', 'b7b6b6f6-b290-400a-9b38-3a00f4502630', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e1fbf528-b0e8-46bc-b574-f7f672affad4', '66bb6b0b-1ce4-4548-87d1-6951e9a266e4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e1fbf528-b0e8-46bc-b574-f7f672affad4', 'a2bf7471-75ae-446c-95bc-9b0b6707b385', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e1fbf528-b0e8-46bc-b574-f7f672affad4', '65b69690-bbd0-4f96-b1e3-ae1a79864fa2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e1fbf528-b0e8-46bc-b574-f7f672affad4', '2f08a737-e5b5-4816-8db7-28ce637e0636', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e1fbf528-b0e8-46bc-b574-f7f672affad4', 'b7b6b6f6-b290-400a-9b38-3a00f4502630', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a2bf7471-75ae-446c-95bc-9b0b6707b385', '66bb6b0b-1ce4-4548-87d1-6951e9a266e4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a2bf7471-75ae-446c-95bc-9b0b6707b385', 'e1fbf528-b0e8-46bc-b574-f7f672affad4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a2bf7471-75ae-446c-95bc-9b0b6707b385', '65b69690-bbd0-4f96-b1e3-ae1a79864fa2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a2bf7471-75ae-446c-95bc-9b0b6707b385', '2f08a737-e5b5-4816-8db7-28ce637e0636', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a2bf7471-75ae-446c-95bc-9b0b6707b385', 'b7b6b6f6-b290-400a-9b38-3a00f4502630', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('57a98fe9-e604-4f7f-ae69-e5c46c1527cf', '96e759bc-7b51-423c-94db-fbd79692c8a5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('57a98fe9-e604-4f7f-ae69-e5c46c1527cf', '82aa0c7e-d6c7-4847-8771-940b384b65b4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('57a98fe9-e604-4f7f-ae69-e5c46c1527cf', '8b05b931-4886-4fa4-a099-f43977f76b58', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('57a98fe9-e604-4f7f-ae69-e5c46c1527cf', 'b7b6b6f6-b290-400a-9b38-3a00f4502630', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('57a98fe9-e604-4f7f-ae69-e5c46c1527cf', 'c8460171-1cc0-41b0-bfc0-a388eb4efe51', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('82aa0c7e-d6c7-4847-8771-940b384b65b4', '96e759bc-7b51-423c-94db-fbd79692c8a5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('82aa0c7e-d6c7-4847-8771-940b384b65b4', '57a98fe9-e604-4f7f-ae69-e5c46c1527cf', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('82aa0c7e-d6c7-4847-8771-940b384b65b4', '8b05b931-4886-4fa4-a099-f43977f76b58', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('82aa0c7e-d6c7-4847-8771-940b384b65b4', 'b7b6b6f6-b290-400a-9b38-3a00f4502630', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('82aa0c7e-d6c7-4847-8771-940b384b65b4', 'c8460171-1cc0-41b0-bfc0-a388eb4efe51', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('65b69690-bbd0-4f96-b1e3-ae1a79864fa2', '66bb6b0b-1ce4-4548-87d1-6951e9a266e4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('65b69690-bbd0-4f96-b1e3-ae1a79864fa2', 'e1fbf528-b0e8-46bc-b574-f7f672affad4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('65b69690-bbd0-4f96-b1e3-ae1a79864fa2', 'a2bf7471-75ae-446c-95bc-9b0b6707b385', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('65b69690-bbd0-4f96-b1e3-ae1a79864fa2', '2f08a737-e5b5-4816-8db7-28ce637e0636', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('65b69690-bbd0-4f96-b1e3-ae1a79864fa2', 'b7b6b6f6-b290-400a-9b38-3a00f4502630', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2f08a737-e5b5-4816-8db7-28ce637e0636', '66bb6b0b-1ce4-4548-87d1-6951e9a266e4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2f08a737-e5b5-4816-8db7-28ce637e0636', 'e1fbf528-b0e8-46bc-b574-f7f672affad4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2f08a737-e5b5-4816-8db7-28ce637e0636', 'a2bf7471-75ae-446c-95bc-9b0b6707b385', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2f08a737-e5b5-4816-8db7-28ce637e0636', '65b69690-bbd0-4f96-b1e3-ae1a79864fa2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2f08a737-e5b5-4816-8db7-28ce637e0636', 'b7b6b6f6-b290-400a-9b38-3a00f4502630', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b05b931-4886-4fa4-a099-f43977f76b58', '96e759bc-7b51-423c-94db-fbd79692c8a5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b05b931-4886-4fa4-a099-f43977f76b58', '57a98fe9-e604-4f7f-ae69-e5c46c1527cf', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b05b931-4886-4fa4-a099-f43977f76b58', '82aa0c7e-d6c7-4847-8771-940b384b65b4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b05b931-4886-4fa4-a099-f43977f76b58', 'b7b6b6f6-b290-400a-9b38-3a00f4502630', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b05b931-4886-4fa4-a099-f43977f76b58', 'c8460171-1cc0-41b0-bfc0-a388eb4efe51', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7a7e77b-e387-4f7e-891d-134e0a655ea7', 'e4c6a7b8-69d7-4a34-920f-c2d983232a0a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7a7e77b-e387-4f7e-891d-134e0a655ea7', '0241376f-fd2d-4f06-8ad1-ca50abaec6e3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7a7e77b-e387-4f7e-891d-134e0a655ea7', 'd507596e-004e-478a-a0f3-986b5d095468', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7a7e77b-e387-4f7e-891d-134e0a655ea7', 'e7946c1f-1043-4418-8c2c-f74b5eda3833', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7a7e77b-e387-4f7e-891d-134e0a655ea7', '3cf8c2e2-6cd7-4ddd-aa2c-b09fe6e6dab9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('774c931d-1a05-4127-8786-0da36ec1e2d3', '9cba8e1e-dccb-445d-b8da-f55fa0832de8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('774c931d-1a05-4127-8786-0da36ec1e2d3', '37fb949a-27b4-4773-bd6b-935edf7d2752', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('774c931d-1a05-4127-8786-0da36ec1e2d3', '622587b3-c23f-49c8-81c9-24021af114dc', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('07621952-d77b-452e-a101-4fab913a065f', 'e76fde01-b89d-48d2-a96b-fdc126fb97df', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('07621952-d77b-452e-a101-4fab913a065f', 'f031a9df-5a34-46ac-95e4-b0e5dddc9b35', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('07621952-d77b-452e-a101-4fab913a065f', '76008ff3-d918-45c5-8049-cd5331adf0bd', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e76fde01-b89d-48d2-a96b-fdc126fb97df', '07621952-d77b-452e-a101-4fab913a065f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e76fde01-b89d-48d2-a96b-fdc126fb97df', 'f031a9df-5a34-46ac-95e4-b0e5dddc9b35', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e76fde01-b89d-48d2-a96b-fdc126fb97df', '76008ff3-d918-45c5-8049-cd5331adf0bd', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f031a9df-5a34-46ac-95e4-b0e5dddc9b35', '07621952-d77b-452e-a101-4fab913a065f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f031a9df-5a34-46ac-95e4-b0e5dddc9b35', 'e76fde01-b89d-48d2-a96b-fdc126fb97df', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f031a9df-5a34-46ac-95e4-b0e5dddc9b35', '76008ff3-d918-45c5-8049-cd5331adf0bd', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('76008ff3-d918-45c5-8049-cd5331adf0bd', '07621952-d77b-452e-a101-4fab913a065f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('76008ff3-d918-45c5-8049-cd5331adf0bd', 'e76fde01-b89d-48d2-a96b-fdc126fb97df', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('76008ff3-d918-45c5-8049-cd5331adf0bd', 'f031a9df-5a34-46ac-95e4-b0e5dddc9b35', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cdfac5b4-7372-48cb-9eb0-acde9ad1b683', '0c464f74-da1d-4a9c-9482-ebe004982cb6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cdfac5b4-7372-48cb-9eb0-acde9ad1b683', 'cb72cfa7-c8f7-4389-927a-08abf4f4d750', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cdfac5b4-7372-48cb-9eb0-acde9ad1b683', '68cf0e68-ad17-47d6-b6f0-92a4db17f1de', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cdfac5b4-7372-48cb-9eb0-acde9ad1b683', '10ad654a-1dd9-434a-aec4-7482ef213dd5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cdfac5b4-7372-48cb-9eb0-acde9ad1b683', '755b0997-45ff-40fa-aa9c-580940f07439', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c464f74-da1d-4a9c-9482-ebe004982cb6', 'cdfac5b4-7372-48cb-9eb0-acde9ad1b683', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c464f74-da1d-4a9c-9482-ebe004982cb6', 'cb72cfa7-c8f7-4389-927a-08abf4f4d750', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c464f74-da1d-4a9c-9482-ebe004982cb6', '68cf0e68-ad17-47d6-b6f0-92a4db17f1de', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c464f74-da1d-4a9c-9482-ebe004982cb6', '10ad654a-1dd9-434a-aec4-7482ef213dd5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c464f74-da1d-4a9c-9482-ebe004982cb6', '755b0997-45ff-40fa-aa9c-580940f07439', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cb72cfa7-c8f7-4389-927a-08abf4f4d750', 'cdfac5b4-7372-48cb-9eb0-acde9ad1b683', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cb72cfa7-c8f7-4389-927a-08abf4f4d750', '0c464f74-da1d-4a9c-9482-ebe004982cb6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cb72cfa7-c8f7-4389-927a-08abf4f4d750', '68cf0e68-ad17-47d6-b6f0-92a4db17f1de', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cb72cfa7-c8f7-4389-927a-08abf4f4d750', '10ad654a-1dd9-434a-aec4-7482ef213dd5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cb72cfa7-c8f7-4389-927a-08abf4f4d750', '755b0997-45ff-40fa-aa9c-580940f07439', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('68cf0e68-ad17-47d6-b6f0-92a4db17f1de', 'cdfac5b4-7372-48cb-9eb0-acde9ad1b683', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('68cf0e68-ad17-47d6-b6f0-92a4db17f1de', '0c464f74-da1d-4a9c-9482-ebe004982cb6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('68cf0e68-ad17-47d6-b6f0-92a4db17f1de', 'cb72cfa7-c8f7-4389-927a-08abf4f4d750', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('68cf0e68-ad17-47d6-b6f0-92a4db17f1de', '10ad654a-1dd9-434a-aec4-7482ef213dd5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('68cf0e68-ad17-47d6-b6f0-92a4db17f1de', '755b0997-45ff-40fa-aa9c-580940f07439', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0cc0922-38b1-4bef-b9ce-a9efdea2e0f8', 'f7b3f5cd-e09d-4dab-9779-30d5f9c63402', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0cc0922-38b1-4bef-b9ce-a9efdea2e0f8', 'cdfac5b4-7372-48cb-9eb0-acde9ad1b683', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0cc0922-38b1-4bef-b9ce-a9efdea2e0f8', '0c464f74-da1d-4a9c-9482-ebe004982cb6', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0cc0922-38b1-4bef-b9ce-a9efdea2e0f8', 'cb72cfa7-c8f7-4389-927a-08abf4f4d750', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0cc0922-38b1-4bef-b9ce-a9efdea2e0f8', '68cf0e68-ad17-47d6-b6f0-92a4db17f1de', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f7b3f5cd-e09d-4dab-9779-30d5f9c63402', 'a0cc0922-38b1-4bef-b9ce-a9efdea2e0f8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f7b3f5cd-e09d-4dab-9779-30d5f9c63402', 'cdfac5b4-7372-48cb-9eb0-acde9ad1b683', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f7b3f5cd-e09d-4dab-9779-30d5f9c63402', '0c464f74-da1d-4a9c-9482-ebe004982cb6', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f7b3f5cd-e09d-4dab-9779-30d5f9c63402', 'cb72cfa7-c8f7-4389-927a-08abf4f4d750', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f7b3f5cd-e09d-4dab-9779-30d5f9c63402', '68cf0e68-ad17-47d6-b6f0-92a4db17f1de', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('10ad654a-1dd9-434a-aec4-7482ef213dd5', 'cdfac5b4-7372-48cb-9eb0-acde9ad1b683', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('10ad654a-1dd9-434a-aec4-7482ef213dd5', '0c464f74-da1d-4a9c-9482-ebe004982cb6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('10ad654a-1dd9-434a-aec4-7482ef213dd5', 'cb72cfa7-c8f7-4389-927a-08abf4f4d750', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('10ad654a-1dd9-434a-aec4-7482ef213dd5', '68cf0e68-ad17-47d6-b6f0-92a4db17f1de', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('10ad654a-1dd9-434a-aec4-7482ef213dd5', '755b0997-45ff-40fa-aa9c-580940f07439', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('755b0997-45ff-40fa-aa9c-580940f07439', 'cdfac5b4-7372-48cb-9eb0-acde9ad1b683', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('755b0997-45ff-40fa-aa9c-580940f07439', '0c464f74-da1d-4a9c-9482-ebe004982cb6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('755b0997-45ff-40fa-aa9c-580940f07439', 'cb72cfa7-c8f7-4389-927a-08abf4f4d750', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('755b0997-45ff-40fa-aa9c-580940f07439', '68cf0e68-ad17-47d6-b6f0-92a4db17f1de', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('755b0997-45ff-40fa-aa9c-580940f07439', '10ad654a-1dd9-434a-aec4-7482ef213dd5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('80286434-093e-4c85-b27d-59869bcde22b', 'fc51784e-1d38-4e28-8a19-23d8b7ad38bd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('80286434-093e-4c85-b27d-59869bcde22b', '07621952-d77b-452e-a101-4fab913a065f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('80286434-093e-4c85-b27d-59869bcde22b', 'e76fde01-b89d-48d2-a96b-fdc126fb97df', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e0696dc1-32b0-4e4e-a993-bb15fa9827f3', 'cdfac5b4-7372-48cb-9eb0-acde9ad1b683', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e0696dc1-32b0-4e4e-a993-bb15fa9827f3', '0c464f74-da1d-4a9c-9482-ebe004982cb6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e0696dc1-32b0-4e4e-a993-bb15fa9827f3', 'cb72cfa7-c8f7-4389-927a-08abf4f4d750', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e0696dc1-32b0-4e4e-a993-bb15fa9827f3', '68cf0e68-ad17-47d6-b6f0-92a4db17f1de', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e0696dc1-32b0-4e4e-a993-bb15fa9827f3', 'a0cc0922-38b1-4bef-b9ce-a9efdea2e0f8', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce011cf0-8795-48b9-86be-eddc4687e8f9', 'fc51784e-1d38-4e28-8a19-23d8b7ad38bd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce011cf0-8795-48b9-86be-eddc4687e8f9', '07621952-d77b-452e-a101-4fab913a065f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce011cf0-8795-48b9-86be-eddc4687e8f9', 'e76fde01-b89d-48d2-a96b-fdc126fb97df', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ed65f017-8c9e-476a-bf0c-47e61efa4efd', '9dd33b98-1e9a-4d92-8e68-6d81d142fde5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ed65f017-8c9e-476a-bf0c-47e61efa4efd', 'c11ec1b2-0059-4e56-8e6a-b1a7af2ed155', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ed65f017-8c9e-476a-bf0c-47e61efa4efd', 'ead00843-6860-4569-a731-2e2a82b455f5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ed65f017-8c9e-476a-bf0c-47e61efa4efd', '5aeb8562-208b-48db-a12a-290cc985e2c6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ed65f017-8c9e-476a-bf0c-47e61efa4efd', 'b0d9d87b-ccb1-4348-a20b-574ed353a97c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('76ab13fc-95aa-4d7a-ad4b-2860e1c71659', 'd2027142-4b50-4822-addc-c97617d1668b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('76ab13fc-95aa-4d7a-ad4b-2860e1c71659', 'ed65f017-8c9e-476a-bf0c-47e61efa4efd', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('76ab13fc-95aa-4d7a-ad4b-2860e1c71659', '9dd33b98-1e9a-4d92-8e68-6d81d142fde5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('76ab13fc-95aa-4d7a-ad4b-2860e1c71659', 'c11ec1b2-0059-4e56-8e6a-b1a7af2ed155', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('76ab13fc-95aa-4d7a-ad4b-2860e1c71659', 'ead00843-6860-4569-a731-2e2a82b455f5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9dd33b98-1e9a-4d92-8e68-6d81d142fde5', 'ed65f017-8c9e-476a-bf0c-47e61efa4efd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9dd33b98-1e9a-4d92-8e68-6d81d142fde5', 'c11ec1b2-0059-4e56-8e6a-b1a7af2ed155', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9dd33b98-1e9a-4d92-8e68-6d81d142fde5', 'ead00843-6860-4569-a731-2e2a82b455f5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9dd33b98-1e9a-4d92-8e68-6d81d142fde5', '5aeb8562-208b-48db-a12a-290cc985e2c6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9dd33b98-1e9a-4d92-8e68-6d81d142fde5', 'b0d9d87b-ccb1-4348-a20b-574ed353a97c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c11ec1b2-0059-4e56-8e6a-b1a7af2ed155', 'ed65f017-8c9e-476a-bf0c-47e61efa4efd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c11ec1b2-0059-4e56-8e6a-b1a7af2ed155', '9dd33b98-1e9a-4d92-8e68-6d81d142fde5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c11ec1b2-0059-4e56-8e6a-b1a7af2ed155', 'ead00843-6860-4569-a731-2e2a82b455f5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c11ec1b2-0059-4e56-8e6a-b1a7af2ed155', '5aeb8562-208b-48db-a12a-290cc985e2c6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c11ec1b2-0059-4e56-8e6a-b1a7af2ed155', 'b0d9d87b-ccb1-4348-a20b-574ed353a97c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ead00843-6860-4569-a731-2e2a82b455f5', 'ed65f017-8c9e-476a-bf0c-47e61efa4efd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ead00843-6860-4569-a731-2e2a82b455f5', '9dd33b98-1e9a-4d92-8e68-6d81d142fde5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ead00843-6860-4569-a731-2e2a82b455f5', 'c11ec1b2-0059-4e56-8e6a-b1a7af2ed155', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ead00843-6860-4569-a731-2e2a82b455f5', '5aeb8562-208b-48db-a12a-290cc985e2c6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ead00843-6860-4569-a731-2e2a82b455f5', 'b0d9d87b-ccb1-4348-a20b-574ed353a97c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5aeb8562-208b-48db-a12a-290cc985e2c6', 'ed65f017-8c9e-476a-bf0c-47e61efa4efd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5aeb8562-208b-48db-a12a-290cc985e2c6', '9dd33b98-1e9a-4d92-8e68-6d81d142fde5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5aeb8562-208b-48db-a12a-290cc985e2c6', 'c11ec1b2-0059-4e56-8e6a-b1a7af2ed155', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5aeb8562-208b-48db-a12a-290cc985e2c6', 'ead00843-6860-4569-a731-2e2a82b455f5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5aeb8562-208b-48db-a12a-290cc985e2c6', 'b0d9d87b-ccb1-4348-a20b-574ed353a97c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b0d9d87b-ccb1-4348-a20b-574ed353a97c', 'ed65f017-8c9e-476a-bf0c-47e61efa4efd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b0d9d87b-ccb1-4348-a20b-574ed353a97c', '9dd33b98-1e9a-4d92-8e68-6d81d142fde5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b0d9d87b-ccb1-4348-a20b-574ed353a97c', 'c11ec1b2-0059-4e56-8e6a-b1a7af2ed155', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b0d9d87b-ccb1-4348-a20b-574ed353a97c', 'ead00843-6860-4569-a731-2e2a82b455f5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b0d9d87b-ccb1-4348-a20b-574ed353a97c', '5aeb8562-208b-48db-a12a-290cc985e2c6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45ed927a-45be-429c-a240-961ddd88c54e', 'ac987f9c-f00c-4e0c-b8db-39642099ffb4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45ed927a-45be-429c-a240-961ddd88c54e', 'ed65f017-8c9e-476a-bf0c-47e61efa4efd', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45ed927a-45be-429c-a240-961ddd88c54e', '76ab13fc-95aa-4d7a-ad4b-2860e1c71659', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45ed927a-45be-429c-a240-961ddd88c54e', '9dd33b98-1e9a-4d92-8e68-6d81d142fde5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45ed927a-45be-429c-a240-961ddd88c54e', 'c11ec1b2-0059-4e56-8e6a-b1a7af2ed155', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ac987f9c-f00c-4e0c-b8db-39642099ffb4', '45ed927a-45be-429c-a240-961ddd88c54e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ac987f9c-f00c-4e0c-b8db-39642099ffb4', 'ed65f017-8c9e-476a-bf0c-47e61efa4efd', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ac987f9c-f00c-4e0c-b8db-39642099ffb4', '76ab13fc-95aa-4d7a-ad4b-2860e1c71659', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ac987f9c-f00c-4e0c-b8db-39642099ffb4', '9dd33b98-1e9a-4d92-8e68-6d81d142fde5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ac987f9c-f00c-4e0c-b8db-39642099ffb4', 'c11ec1b2-0059-4e56-8e6a-b1a7af2ed155', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('beba0582-4d01-478a-9cb2-6da57639d0a3', 'ed65f017-8c9e-476a-bf0c-47e61efa4efd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('beba0582-4d01-478a-9cb2-6da57639d0a3', '9dd33b98-1e9a-4d92-8e68-6d81d142fde5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('beba0582-4d01-478a-9cb2-6da57639d0a3', 'c11ec1b2-0059-4e56-8e6a-b1a7af2ed155', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('beba0582-4d01-478a-9cb2-6da57639d0a3', 'ead00843-6860-4569-a731-2e2a82b455f5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('beba0582-4d01-478a-9cb2-6da57639d0a3', '5aeb8562-208b-48db-a12a-290cc985e2c6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('12a54747-2dab-486f-a626-c67488c4a176', 'ed65f017-8c9e-476a-bf0c-47e61efa4efd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('12a54747-2dab-486f-a626-c67488c4a176', '9dd33b98-1e9a-4d92-8e68-6d81d142fde5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('12a54747-2dab-486f-a626-c67488c4a176', 'c11ec1b2-0059-4e56-8e6a-b1a7af2ed155', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('12a54747-2dab-486f-a626-c67488c4a176', 'ead00843-6860-4569-a731-2e2a82b455f5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('12a54747-2dab-486f-a626-c67488c4a176', '5aeb8562-208b-48db-a12a-290cc985e2c6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d2027142-4b50-4822-addc-c97617d1668b', '76ab13fc-95aa-4d7a-ad4b-2860e1c71659', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d2027142-4b50-4822-addc-c97617d1668b', 'ed65f017-8c9e-476a-bf0c-47e61efa4efd', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d2027142-4b50-4822-addc-c97617d1668b', '9dd33b98-1e9a-4d92-8e68-6d81d142fde5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d2027142-4b50-4822-addc-c97617d1668b', 'c11ec1b2-0059-4e56-8e6a-b1a7af2ed155', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d2027142-4b50-4822-addc-c97617d1668b', 'ead00843-6860-4569-a731-2e2a82b455f5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1fd19eac-655c-456b-8a28-121237b0b739', 'ed65f017-8c9e-476a-bf0c-47e61efa4efd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1fd19eac-655c-456b-8a28-121237b0b739', '9dd33b98-1e9a-4d92-8e68-6d81d142fde5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1fd19eac-655c-456b-8a28-121237b0b739', 'c11ec1b2-0059-4e56-8e6a-b1a7af2ed155', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1fd19eac-655c-456b-8a28-121237b0b739', 'ead00843-6860-4569-a731-2e2a82b455f5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1fd19eac-655c-456b-8a28-121237b0b739', '5aeb8562-208b-48db-a12a-290cc985e2c6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d7df314-1967-420a-b81a-3c171670e960', '42d564a8-4d1f-426f-8e7b-0739cce9ef66', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d7df314-1967-420a-b81a-3c171670e960', '4009e6a4-0878-4f5f-bdb5-3df7554df698', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d7df314-1967-420a-b81a-3c171670e960', '0f21496c-a04f-452d-8cd8-d3a0d24222a7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d7df314-1967-420a-b81a-3c171670e960', '8eff7985-1ea3-4f61-95f5-ebac0f549438', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d7df314-1967-420a-b81a-3c171670e960', 'c9b724f5-3a7c-43df-a51c-241f80f5c90c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4009e6a4-0878-4f5f-bdb5-3df7554df698', '8d7df314-1967-420a-b81a-3c171670e960', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4009e6a4-0878-4f5f-bdb5-3df7554df698', '0f21496c-a04f-452d-8cd8-d3a0d24222a7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4009e6a4-0878-4f5f-bdb5-3df7554df698', '8eff7985-1ea3-4f61-95f5-ebac0f549438', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4009e6a4-0878-4f5f-bdb5-3df7554df698', 'c9b724f5-3a7c-43df-a51c-241f80f5c90c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4009e6a4-0878-4f5f-bdb5-3df7554df698', '86104b1e-0488-4d42-9e1d-3d3831267096', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0f21496c-a04f-452d-8cd8-d3a0d24222a7', '8d7df314-1967-420a-b81a-3c171670e960', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0f21496c-a04f-452d-8cd8-d3a0d24222a7', '4009e6a4-0878-4f5f-bdb5-3df7554df698', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0f21496c-a04f-452d-8cd8-d3a0d24222a7', '8eff7985-1ea3-4f61-95f5-ebac0f549438', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0f21496c-a04f-452d-8cd8-d3a0d24222a7', 'c9b724f5-3a7c-43df-a51c-241f80f5c90c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0f21496c-a04f-452d-8cd8-d3a0d24222a7', '86104b1e-0488-4d42-9e1d-3d3831267096', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8eff7985-1ea3-4f61-95f5-ebac0f549438', 'c9b724f5-3a7c-43df-a51c-241f80f5c90c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8eff7985-1ea3-4f61-95f5-ebac0f549438', '86104b1e-0488-4d42-9e1d-3d3831267096', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8eff7985-1ea3-4f61-95f5-ebac0f549438', '7b1df8a9-d5fa-41bb-81a3-57d18775f6f0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8eff7985-1ea3-4f61-95f5-ebac0f549438', '8d7df314-1967-420a-b81a-3c171670e960', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8eff7985-1ea3-4f61-95f5-ebac0f549438', '4009e6a4-0878-4f5f-bdb5-3df7554df698', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9b724f5-3a7c-43df-a51c-241f80f5c90c', '8eff7985-1ea3-4f61-95f5-ebac0f549438', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9b724f5-3a7c-43df-a51c-241f80f5c90c', '86104b1e-0488-4d42-9e1d-3d3831267096', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9b724f5-3a7c-43df-a51c-241f80f5c90c', '7b1df8a9-d5fa-41bb-81a3-57d18775f6f0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9b724f5-3a7c-43df-a51c-241f80f5c90c', '8d7df314-1967-420a-b81a-3c171670e960', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9b724f5-3a7c-43df-a51c-241f80f5c90c', '4009e6a4-0878-4f5f-bdb5-3df7554df698', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('86104b1e-0488-4d42-9e1d-3d3831267096', '8eff7985-1ea3-4f61-95f5-ebac0f549438', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('86104b1e-0488-4d42-9e1d-3d3831267096', 'c9b724f5-3a7c-43df-a51c-241f80f5c90c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('86104b1e-0488-4d42-9e1d-3d3831267096', '7b1df8a9-d5fa-41bb-81a3-57d18775f6f0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('86104b1e-0488-4d42-9e1d-3d3831267096', '8d7df314-1967-420a-b81a-3c171670e960', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('86104b1e-0488-4d42-9e1d-3d3831267096', '4009e6a4-0878-4f5f-bdb5-3df7554df698', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7b1df8a9-d5fa-41bb-81a3-57d18775f6f0', '8eff7985-1ea3-4f61-95f5-ebac0f549438', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7b1df8a9-d5fa-41bb-81a3-57d18775f6f0', 'c9b724f5-3a7c-43df-a51c-241f80f5c90c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7b1df8a9-d5fa-41bb-81a3-57d18775f6f0', '86104b1e-0488-4d42-9e1d-3d3831267096', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7b1df8a9-d5fa-41bb-81a3-57d18775f6f0', '8d7df314-1967-420a-b81a-3c171670e960', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7b1df8a9-d5fa-41bb-81a3-57d18775f6f0', '4009e6a4-0878-4f5f-bdb5-3df7554df698', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('42d564a8-4d1f-426f-8e7b-0739cce9ef66', '8d7df314-1967-420a-b81a-3c171670e960', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('42d564a8-4d1f-426f-8e7b-0739cce9ef66', '4009e6a4-0878-4f5f-bdb5-3df7554df698', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('42d564a8-4d1f-426f-8e7b-0739cce9ef66', '0f21496c-a04f-452d-8cd8-d3a0d24222a7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('42d564a8-4d1f-426f-8e7b-0739cce9ef66', '8eff7985-1ea3-4f61-95f5-ebac0f549438', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('42d564a8-4d1f-426f-8e7b-0739cce9ef66', 'c9b724f5-3a7c-43df-a51c-241f80f5c90c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e498b1d9-c4d0-4849-91eb-25f50e0e8b18', '8d7df314-1967-420a-b81a-3c171670e960', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e498b1d9-c4d0-4849-91eb-25f50e0e8b18', '4009e6a4-0878-4f5f-bdb5-3df7554df698', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e498b1d9-c4d0-4849-91eb-25f50e0e8b18', '0f21496c-a04f-452d-8cd8-d3a0d24222a7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5c567ddc-6d37-45ab-b69c-d0d873684208', '8d7df314-1967-420a-b81a-3c171670e960', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5c567ddc-6d37-45ab-b69c-d0d873684208', '4009e6a4-0878-4f5f-bdb5-3df7554df698', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5c567ddc-6d37-45ab-b69c-d0d873684208', '0f21496c-a04f-452d-8cd8-d3a0d24222a7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5c567ddc-6d37-45ab-b69c-d0d873684208', '8eff7985-1ea3-4f61-95f5-ebac0f549438', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5c567ddc-6d37-45ab-b69c-d0d873684208', 'c9b724f5-3a7c-43df-a51c-241f80f5c90c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1dde8f57-469e-47b2-b9e2-8e5e8d1ece20', '1e7e26b5-4c02-4197-9edc-f6f309549c2d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1dde8f57-469e-47b2-b9e2-8e5e8d1ece20', 'dcb9b881-a091-43f5-93f5-ee91b42008ea', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1dde8f57-469e-47b2-b9e2-8e5e8d1ece20', '493f0c7c-6266-4073-9413-f5c75bfec787', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1dde8f57-469e-47b2-b9e2-8e5e8d1ece20', 'c530f3c1-409d-4e68-be24-c37006116a39', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1dde8f57-469e-47b2-b9e2-8e5e8d1ece20', 'f3e3666c-4404-4a1f-a6d2-163d06ffe32b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('20d5d6c0-8c80-4f6f-abd5-62d14395424e', '1dde8f57-469e-47b2-b9e2-8e5e8d1ece20', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('20d5d6c0-8c80-4f6f-abd5-62d14395424e', '1e7e26b5-4c02-4197-9edc-f6f309549c2d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('20d5d6c0-8c80-4f6f-abd5-62d14395424e', 'dcb9b881-a091-43f5-93f5-ee91b42008ea', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('20d5d6c0-8c80-4f6f-abd5-62d14395424e', '493f0c7c-6266-4073-9413-f5c75bfec787', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('20d5d6c0-8c80-4f6f-abd5-62d14395424e', 'c530f3c1-409d-4e68-be24-c37006116a39', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1e7e26b5-4c02-4197-9edc-f6f309549c2d', '1dde8f57-469e-47b2-b9e2-8e5e8d1ece20', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1e7e26b5-4c02-4197-9edc-f6f309549c2d', 'dcb9b881-a091-43f5-93f5-ee91b42008ea', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1e7e26b5-4c02-4197-9edc-f6f309549c2d', '493f0c7c-6266-4073-9413-f5c75bfec787', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1e7e26b5-4c02-4197-9edc-f6f309549c2d', 'c530f3c1-409d-4e68-be24-c37006116a39', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1e7e26b5-4c02-4197-9edc-f6f309549c2d', 'f3e3666c-4404-4a1f-a6d2-163d06ffe32b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('493f0c7c-6266-4073-9413-f5c75bfec787', '1dde8f57-469e-47b2-b9e2-8e5e8d1ece20', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('493f0c7c-6266-4073-9413-f5c75bfec787', '1e7e26b5-4c02-4197-9edc-f6f309549c2d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('493f0c7c-6266-4073-9413-f5c75bfec787', 'c530f3c1-409d-4e68-be24-c37006116a39', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('493f0c7c-6266-4073-9413-f5c75bfec787', 'dcb9b881-a091-43f5-93f5-ee91b42008ea', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('493f0c7c-6266-4073-9413-f5c75bfec787', 'f3e3666c-4404-4a1f-a6d2-163d06ffe32b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c530f3c1-409d-4e68-be24-c37006116a39', '1dde8f57-469e-47b2-b9e2-8e5e8d1ece20', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c530f3c1-409d-4e68-be24-c37006116a39', '1e7e26b5-4c02-4197-9edc-f6f309549c2d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c530f3c1-409d-4e68-be24-c37006116a39', '493f0c7c-6266-4073-9413-f5c75bfec787', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c530f3c1-409d-4e68-be24-c37006116a39', 'dcb9b881-a091-43f5-93f5-ee91b42008ea', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c530f3c1-409d-4e68-be24-c37006116a39', 'f3e3666c-4404-4a1f-a6d2-163d06ffe32b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('72b2d4bc-1bb9-459e-91e2-6f860970a92b', '1dde8f57-469e-47b2-b9e2-8e5e8d1ece20', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('72b2d4bc-1bb9-459e-91e2-6f860970a92b', '1e7e26b5-4c02-4197-9edc-f6f309549c2d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('72b2d4bc-1bb9-459e-91e2-6f860970a92b', '493f0c7c-6266-4073-9413-f5c75bfec787', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e6aae816-4097-41f5-a838-f9d4f51dc913', '1dde8f57-469e-47b2-b9e2-8e5e8d1ece20', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e6aae816-4097-41f5-a838-f9d4f51dc913', '1e7e26b5-4c02-4197-9edc-f6f309549c2d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e6aae816-4097-41f5-a838-f9d4f51dc913', '493f0c7c-6266-4073-9413-f5c75bfec787', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('33ca5569-1a78-4ee1-b885-2a6a7c3c0b10', 'e743c92b-5d9f-449a-9c0c-db4a8924ce8b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('33ca5569-1a78-4ee1-b885-2a6a7c3c0b10', '0363a22b-945d-4322-870b-c7e76be8a1d3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('33ca5569-1a78-4ee1-b885-2a6a7c3c0b10', 'f214661a-72b1-4f0f-982d-0de615acd292', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('33ca5569-1a78-4ee1-b885-2a6a7c3c0b10', '37fd1cf6-469c-4b3b-828f-a27c00e1633e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('33ca5569-1a78-4ee1-b885-2a6a7c3c0b10', '9d6e0fed-933f-4122-a351-5fe806f669ae', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f214661a-72b1-4f0f-982d-0de615acd292', '9d6e0fed-933f-4122-a351-5fe806f669ae', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f214661a-72b1-4f0f-982d-0de615acd292', '33ca5569-1a78-4ee1-b885-2a6a7c3c0b10', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f214661a-72b1-4f0f-982d-0de615acd292', 'e743c92b-5d9f-449a-9c0c-db4a8924ce8b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f214661a-72b1-4f0f-982d-0de615acd292', '37fd1cf6-469c-4b3b-828f-a27c00e1633e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f214661a-72b1-4f0f-982d-0de615acd292', '0363a22b-945d-4322-870b-c7e76be8a1d3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e743c92b-5d9f-449a-9c0c-db4a8924ce8b', '33ca5569-1a78-4ee1-b885-2a6a7c3c0b10', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e743c92b-5d9f-449a-9c0c-db4a8924ce8b', '0363a22b-945d-4322-870b-c7e76be8a1d3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e743c92b-5d9f-449a-9c0c-db4a8924ce8b', 'f214661a-72b1-4f0f-982d-0de615acd292', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e743c92b-5d9f-449a-9c0c-db4a8924ce8b', '37fd1cf6-469c-4b3b-828f-a27c00e1633e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e743c92b-5d9f-449a-9c0c-db4a8924ce8b', '9d6e0fed-933f-4122-a351-5fe806f669ae', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('37fd1cf6-469c-4b3b-828f-a27c00e1633e', '33ca5569-1a78-4ee1-b885-2a6a7c3c0b10', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('37fd1cf6-469c-4b3b-828f-a27c00e1633e', 'f214661a-72b1-4f0f-982d-0de615acd292', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('37fd1cf6-469c-4b3b-828f-a27c00e1633e', 'e743c92b-5d9f-449a-9c0c-db4a8924ce8b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('37fd1cf6-469c-4b3b-828f-a27c00e1633e', '9d6e0fed-933f-4122-a351-5fe806f669ae', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('37fd1cf6-469c-4b3b-828f-a27c00e1633e', '0363a22b-945d-4322-870b-c7e76be8a1d3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9d6e0fed-933f-4122-a351-5fe806f669ae', 'f214661a-72b1-4f0f-982d-0de615acd292', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9d6e0fed-933f-4122-a351-5fe806f669ae', '33ca5569-1a78-4ee1-b885-2a6a7c3c0b10', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9d6e0fed-933f-4122-a351-5fe806f669ae', 'e743c92b-5d9f-449a-9c0c-db4a8924ce8b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9d6e0fed-933f-4122-a351-5fe806f669ae', '37fd1cf6-469c-4b3b-828f-a27c00e1633e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9d6e0fed-933f-4122-a351-5fe806f669ae', '0363a22b-945d-4322-870b-c7e76be8a1d3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a76443a7-99a3-495b-b836-d1391739c897', '7c4ab3bb-59be-4ec6-ac69-a283ee56eb3a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a76443a7-99a3-495b-b836-d1391739c897', '1dde8f57-469e-47b2-b9e2-8e5e8d1ece20', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a76443a7-99a3-495b-b836-d1391739c897', '1e7e26b5-4c02-4197-9edc-f6f309549c2d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dcb9b881-a091-43f5-93f5-ee91b42008ea', '1dde8f57-469e-47b2-b9e2-8e5e8d1ece20', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dcb9b881-a091-43f5-93f5-ee91b42008ea', '1e7e26b5-4c02-4197-9edc-f6f309549c2d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dcb9b881-a091-43f5-93f5-ee91b42008ea', '493f0c7c-6266-4073-9413-f5c75bfec787', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dcb9b881-a091-43f5-93f5-ee91b42008ea', 'c530f3c1-409d-4e68-be24-c37006116a39', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dcb9b881-a091-43f5-93f5-ee91b42008ea', 'f3e3666c-4404-4a1f-a6d2-163d06ffe32b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8e4ddd54-61b2-4ad1-bab0-2bfbd3eb2e3d', '1dde8f57-469e-47b2-b9e2-8e5e8d1ece20', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8e4ddd54-61b2-4ad1-bab0-2bfbd3eb2e3d', '1e7e26b5-4c02-4197-9edc-f6f309549c2d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8e4ddd54-61b2-4ad1-bab0-2bfbd3eb2e3d', '493f0c7c-6266-4073-9413-f5c75bfec787', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f3e3666c-4404-4a1f-a6d2-163d06ffe32b', '1dde8f57-469e-47b2-b9e2-8e5e8d1ece20', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f3e3666c-4404-4a1f-a6d2-163d06ffe32b', '1e7e26b5-4c02-4197-9edc-f6f309549c2d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f3e3666c-4404-4a1f-a6d2-163d06ffe32b', '493f0c7c-6266-4073-9413-f5c75bfec787', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f3e3666c-4404-4a1f-a6d2-163d06ffe32b', 'c530f3c1-409d-4e68-be24-c37006116a39', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f3e3666c-4404-4a1f-a6d2-163d06ffe32b', 'dcb9b881-a091-43f5-93f5-ee91b42008ea', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7c4ab3bb-59be-4ec6-ac69-a283ee56eb3a', 'a76443a7-99a3-495b-b836-d1391739c897', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7c4ab3bb-59be-4ec6-ac69-a283ee56eb3a', '1dde8f57-469e-47b2-b9e2-8e5e8d1ece20', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7c4ab3bb-59be-4ec6-ac69-a283ee56eb3a', '1e7e26b5-4c02-4197-9edc-f6f309549c2d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0363a22b-945d-4322-870b-c7e76be8a1d3', '33ca5569-1a78-4ee1-b885-2a6a7c3c0b10', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0363a22b-945d-4322-870b-c7e76be8a1d3', 'e743c92b-5d9f-449a-9c0c-db4a8924ce8b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0363a22b-945d-4322-870b-c7e76be8a1d3', 'f214661a-72b1-4f0f-982d-0de615acd292', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0363a22b-945d-4322-870b-c7e76be8a1d3', '37fd1cf6-469c-4b3b-828f-a27c00e1633e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0363a22b-945d-4322-870b-c7e76be8a1d3', '9d6e0fed-933f-4122-a351-5fe806f669ae', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d0bf6c82-f176-484f-bcb9-26c22dca5150', 'a0e666f7-5923-463e-a148-8336ee527d0f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d0bf6c82-f176-484f-bcb9-26c22dca5150', '1afcd42c-07fd-4677-82b3-ec515077fde0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d0bf6c82-f176-484f-bcb9-26c22dca5150', '1dde8f57-469e-47b2-b9e2-8e5e8d1ece20', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0e666f7-5923-463e-a148-8336ee527d0f', 'd0bf6c82-f176-484f-bcb9-26c22dca5150', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0e666f7-5923-463e-a148-8336ee527d0f', '1afcd42c-07fd-4677-82b3-ec515077fde0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0e666f7-5923-463e-a148-8336ee527d0f', '1dde8f57-469e-47b2-b9e2-8e5e8d1ece20', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1afcd42c-07fd-4677-82b3-ec515077fde0', 'd0bf6c82-f176-484f-bcb9-26c22dca5150', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1afcd42c-07fd-4677-82b3-ec515077fde0', 'a0e666f7-5923-463e-a148-8336ee527d0f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1afcd42c-07fd-4677-82b3-ec515077fde0', '1dde8f57-469e-47b2-b9e2-8e5e8d1ece20', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('138289fa-df6a-4357-addc-3e61f33a366a', 'abcdd770-0f40-4bbc-9375-f15d74b5b712', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('138289fa-df6a-4357-addc-3e61f33a366a', 'd41ef5e6-9deb-4ef1-8db3-a5a2be46d684', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('138289fa-df6a-4357-addc-3e61f33a366a', '25c20fd0-0fd2-4544-9845-edad943e28f2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('138289fa-df6a-4357-addc-3e61f33a366a', 'cd59b929-d682-4e1c-86a5-e0832ec0b413', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('abcdd770-0f40-4bbc-9375-f15d74b5b712', '138289fa-df6a-4357-addc-3e61f33a366a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('abcdd770-0f40-4bbc-9375-f15d74b5b712', 'd41ef5e6-9deb-4ef1-8db3-a5a2be46d684', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('abcdd770-0f40-4bbc-9375-f15d74b5b712', '25c20fd0-0fd2-4544-9845-edad943e28f2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('abcdd770-0f40-4bbc-9375-f15d74b5b712', 'cd59b929-d682-4e1c-86a5-e0832ec0b413', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d41ef5e6-9deb-4ef1-8db3-a5a2be46d684', '138289fa-df6a-4357-addc-3e61f33a366a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d41ef5e6-9deb-4ef1-8db3-a5a2be46d684', 'abcdd770-0f40-4bbc-9375-f15d74b5b712', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d41ef5e6-9deb-4ef1-8db3-a5a2be46d684', '25c20fd0-0fd2-4544-9845-edad943e28f2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d41ef5e6-9deb-4ef1-8db3-a5a2be46d684', 'cd59b929-d682-4e1c-86a5-e0832ec0b413', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('25c20fd0-0fd2-4544-9845-edad943e28f2', '138289fa-df6a-4357-addc-3e61f33a366a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('25c20fd0-0fd2-4544-9845-edad943e28f2', 'abcdd770-0f40-4bbc-9375-f15d74b5b712', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('25c20fd0-0fd2-4544-9845-edad943e28f2', 'd41ef5e6-9deb-4ef1-8db3-a5a2be46d684', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('25c20fd0-0fd2-4544-9845-edad943e28f2', 'cd59b929-d682-4e1c-86a5-e0832ec0b413', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd59b929-d682-4e1c-86a5-e0832ec0b413', '138289fa-df6a-4357-addc-3e61f33a366a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd59b929-d682-4e1c-86a5-e0832ec0b413', 'abcdd770-0f40-4bbc-9375-f15d74b5b712', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd59b929-d682-4e1c-86a5-e0832ec0b413', 'd41ef5e6-9deb-4ef1-8db3-a5a2be46d684', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd59b929-d682-4e1c-86a5-e0832ec0b413', '25c20fd0-0fd2-4544-9845-edad943e28f2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9e61aafe-a0ad-41b2-b00c-f7dda16f9e47', '19226686-93ce-4abd-95a4-d870e54c8bc2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9e61aafe-a0ad-41b2-b00c-f7dda16f9e47', '90f2d550-1e0a-4e20-9bbc-366c207323ac', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19226686-93ce-4abd-95a4-d870e54c8bc2', '9e61aafe-a0ad-41b2-b00c-f7dda16f9e47', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19226686-93ce-4abd-95a4-d870e54c8bc2', '90f2d550-1e0a-4e20-9bbc-366c207323ac', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('90f2d550-1e0a-4e20-9bbc-366c207323ac', '9e61aafe-a0ad-41b2-b00c-f7dda16f9e47', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('90f2d550-1e0a-4e20-9bbc-366c207323ac', '19226686-93ce-4abd-95a4-d870e54c8bc2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a685d8e3-f8aa-433c-8aef-a991b3990334', 'fbb9dcc5-00fd-4435-883f-0f3b80eaf1c8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a685d8e3-f8aa-433c-8aef-a991b3990334', '317eff52-efb1-4adc-bb7e-f7f7ba8c6c24', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a685d8e3-f8aa-433c-8aef-a991b3990334', '479a7444-a6c5-4d8a-bc02-b3de1677649c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a685d8e3-f8aa-433c-8aef-a991b3990334', '7dbb6674-656f-4e0a-8fd8-722ae77b30a3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a685d8e3-f8aa-433c-8aef-a991b3990334', '99990b68-c893-41d6-bd47-c595e72366dd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('317eff52-efb1-4adc-bb7e-f7f7ba8c6c24', 'fbb9dcc5-00fd-4435-883f-0f3b80eaf1c8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('317eff52-efb1-4adc-bb7e-f7f7ba8c6c24', 'a685d8e3-f8aa-433c-8aef-a991b3990334', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('317eff52-efb1-4adc-bb7e-f7f7ba8c6c24', '479a7444-a6c5-4d8a-bc02-b3de1677649c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('317eff52-efb1-4adc-bb7e-f7f7ba8c6c24', '7dbb6674-656f-4e0a-8fd8-722ae77b30a3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('317eff52-efb1-4adc-bb7e-f7f7ba8c6c24', '99990b68-c893-41d6-bd47-c595e72366dd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('479a7444-a6c5-4d8a-bc02-b3de1677649c', 'fbb9dcc5-00fd-4435-883f-0f3b80eaf1c8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('479a7444-a6c5-4d8a-bc02-b3de1677649c', 'a685d8e3-f8aa-433c-8aef-a991b3990334', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('479a7444-a6c5-4d8a-bc02-b3de1677649c', '317eff52-efb1-4adc-bb7e-f7f7ba8c6c24', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('479a7444-a6c5-4d8a-bc02-b3de1677649c', '7dbb6674-656f-4e0a-8fd8-722ae77b30a3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('479a7444-a6c5-4d8a-bc02-b3de1677649c', '99990b68-c893-41d6-bd47-c595e72366dd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('99990b68-c893-41d6-bd47-c595e72366dd', 'fbb9dcc5-00fd-4435-883f-0f3b80eaf1c8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('99990b68-c893-41d6-bd47-c595e72366dd', '7dbb6674-656f-4e0a-8fd8-722ae77b30a3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('99990b68-c893-41d6-bd47-c595e72366dd', 'a685d8e3-f8aa-433c-8aef-a991b3990334', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('99990b68-c893-41d6-bd47-c595e72366dd', '317eff52-efb1-4adc-bb7e-f7f7ba8c6c24', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('99990b68-c893-41d6-bd47-c595e72366dd', '479a7444-a6c5-4d8a-bc02-b3de1677649c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ca6d08f7-98cc-4a9c-8b83-2a0827b06c97', '16736818-22a3-403a-ada3-b938712cd657', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ca6d08f7-98cc-4a9c-8b83-2a0827b06c97', '516aead8-35f2-4375-b304-89fd9c6a8119', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16736818-22a3-403a-ada3-b938712cd657', 'ca6d08f7-98cc-4a9c-8b83-2a0827b06c97', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16736818-22a3-403a-ada3-b938712cd657', '516aead8-35f2-4375-b304-89fd9c6a8119', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('516aead8-35f2-4375-b304-89fd9c6a8119', 'ca6d08f7-98cc-4a9c-8b83-2a0827b06c97', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('516aead8-35f2-4375-b304-89fd9c6a8119', '16736818-22a3-403a-ada3-b938712cd657', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f07e5431-3c9e-4342-b8dd-1dc11ecce624', 'c4609a8b-998a-4552-8966-e15384631a40', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f07e5431-3c9e-4342-b8dd-1dc11ecce624', '1f95a3a1-cebe-4301-9ed4-4ef5fb8b2b0d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f07e5431-3c9e-4342-b8dd-1dc11ecce624', '3e4fdf6a-72ec-44ea-9178-d239887e40a9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c4609a8b-998a-4552-8966-e15384631a40', '3e4fdf6a-72ec-44ea-9178-d239887e40a9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c4609a8b-998a-4552-8966-e15384631a40', 'f07e5431-3c9e-4342-b8dd-1dc11ecce624', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c4609a8b-998a-4552-8966-e15384631a40', '1f95a3a1-cebe-4301-9ed4-4ef5fb8b2b0d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1f95a3a1-cebe-4301-9ed4-4ef5fb8b2b0d', 'f07e5431-3c9e-4342-b8dd-1dc11ecce624', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1f95a3a1-cebe-4301-9ed4-4ef5fb8b2b0d', 'c4609a8b-998a-4552-8966-e15384631a40', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1f95a3a1-cebe-4301-9ed4-4ef5fb8b2b0d', '3e4fdf6a-72ec-44ea-9178-d239887e40a9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3e4fdf6a-72ec-44ea-9178-d239887e40a9', 'c4609a8b-998a-4552-8966-e15384631a40', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3e4fdf6a-72ec-44ea-9178-d239887e40a9', 'f07e5431-3c9e-4342-b8dd-1dc11ecce624', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3e4fdf6a-72ec-44ea-9178-d239887e40a9', '1f95a3a1-cebe-4301-9ed4-4ef5fb8b2b0d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fed8577c-28e7-43e9-ba3a-343a149592e9', '0c5bcc1d-05cf-4089-b618-1284bca532c0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fed8577c-28e7-43e9-ba3a-343a149592e9', 'd3652669-082a-43ac-818c-c25665c3b37c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fed8577c-28e7-43e9-ba3a-343a149592e9', '47df8e26-c3a2-43b2-a230-206433f15370', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fed8577c-28e7-43e9-ba3a-343a149592e9', '10ede506-e062-4bce-b8ed-3d1991eae236', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fed8577c-28e7-43e9-ba3a-343a149592e9', '1128979e-f5f1-4942-bdc3-17cdb094333f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c5bcc1d-05cf-4089-b618-1284bca532c0', 'fed8577c-28e7-43e9-ba3a-343a149592e9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c5bcc1d-05cf-4089-b618-1284bca532c0', 'd3652669-082a-43ac-818c-c25665c3b37c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c5bcc1d-05cf-4089-b618-1284bca532c0', '47df8e26-c3a2-43b2-a230-206433f15370', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c5bcc1d-05cf-4089-b618-1284bca532c0', '10ede506-e062-4bce-b8ed-3d1991eae236', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c5bcc1d-05cf-4089-b618-1284bca532c0', '1128979e-f5f1-4942-bdc3-17cdb094333f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3652669-082a-43ac-818c-c25665c3b37c', '6a85df59-c91b-448d-a607-3b0be421a728', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3652669-082a-43ac-818c-c25665c3b37c', 'fed8577c-28e7-43e9-ba3a-343a149592e9', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3652669-082a-43ac-818c-c25665c3b37c', '0c5bcc1d-05cf-4089-b618-1284bca532c0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3652669-082a-43ac-818c-c25665c3b37c', '47df8e26-c3a2-43b2-a230-206433f15370', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3652669-082a-43ac-818c-c25665c3b37c', '10ede506-e062-4bce-b8ed-3d1991eae236', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('47df8e26-c3a2-43b2-a230-206433f15370', 'fed8577c-28e7-43e9-ba3a-343a149592e9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('47df8e26-c3a2-43b2-a230-206433f15370', '0c5bcc1d-05cf-4089-b618-1284bca532c0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('47df8e26-c3a2-43b2-a230-206433f15370', 'd3652669-082a-43ac-818c-c25665c3b37c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('47df8e26-c3a2-43b2-a230-206433f15370', '10ede506-e062-4bce-b8ed-3d1991eae236', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('47df8e26-c3a2-43b2-a230-206433f15370', '1128979e-f5f1-4942-bdc3-17cdb094333f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('10ede506-e062-4bce-b8ed-3d1991eae236', 'fed8577c-28e7-43e9-ba3a-343a149592e9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('10ede506-e062-4bce-b8ed-3d1991eae236', '0c5bcc1d-05cf-4089-b618-1284bca532c0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('10ede506-e062-4bce-b8ed-3d1991eae236', 'd3652669-082a-43ac-818c-c25665c3b37c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('10ede506-e062-4bce-b8ed-3d1991eae236', '47df8e26-c3a2-43b2-a230-206433f15370', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('10ede506-e062-4bce-b8ed-3d1991eae236', '1128979e-f5f1-4942-bdc3-17cdb094333f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1128979e-f5f1-4942-bdc3-17cdb094333f', 'fed8577c-28e7-43e9-ba3a-343a149592e9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1128979e-f5f1-4942-bdc3-17cdb094333f', '0c5bcc1d-05cf-4089-b618-1284bca532c0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1128979e-f5f1-4942-bdc3-17cdb094333f', 'd3652669-082a-43ac-818c-c25665c3b37c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1128979e-f5f1-4942-bdc3-17cdb094333f', '47df8e26-c3a2-43b2-a230-206433f15370', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1128979e-f5f1-4942-bdc3-17cdb094333f', '10ede506-e062-4bce-b8ed-3d1991eae236', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('17fbbe0c-ee03-4fc1-8e0c-0aaee0a190ff', 'fed8577c-28e7-43e9-ba3a-343a149592e9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('17fbbe0c-ee03-4fc1-8e0c-0aaee0a190ff', '0c5bcc1d-05cf-4089-b618-1284bca532c0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('17fbbe0c-ee03-4fc1-8e0c-0aaee0a190ff', 'd3652669-082a-43ac-818c-c25665c3b37c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('17fbbe0c-ee03-4fc1-8e0c-0aaee0a190ff', '47df8e26-c3a2-43b2-a230-206433f15370', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('17fbbe0c-ee03-4fc1-8e0c-0aaee0a190ff', '10ede506-e062-4bce-b8ed-3d1991eae236', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6a85df59-c91b-448d-a607-3b0be421a728', 'd3652669-082a-43ac-818c-c25665c3b37c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6a85df59-c91b-448d-a607-3b0be421a728', 'fed8577c-28e7-43e9-ba3a-343a149592e9', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6a85df59-c91b-448d-a607-3b0be421a728', '0c5bcc1d-05cf-4089-b618-1284bca532c0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6a85df59-c91b-448d-a607-3b0be421a728', '47df8e26-c3a2-43b2-a230-206433f15370', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6a85df59-c91b-448d-a607-3b0be421a728', '10ede506-e062-4bce-b8ed-3d1991eae236', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3ee7885b-2a5e-4a79-b7d9-ca62543e608f', 'fed8577c-28e7-43e9-ba3a-343a149592e9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3ee7885b-2a5e-4a79-b7d9-ca62543e608f', '0c5bcc1d-05cf-4089-b618-1284bca532c0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3ee7885b-2a5e-4a79-b7d9-ca62543e608f', 'd3652669-082a-43ac-818c-c25665c3b37c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3ee7885b-2a5e-4a79-b7d9-ca62543e608f', '47df8e26-c3a2-43b2-a230-206433f15370', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3ee7885b-2a5e-4a79-b7d9-ca62543e608f', '10ede506-e062-4bce-b8ed-3d1991eae236', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('898b9d1f-816a-4961-ad6f-609995fb2793', '21c76db0-c631-4704-ab30-610939fa8e6c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2feae2c9-bf06-45f0-a412-59694c23efe3', '21c76db0-c631-4704-ab30-610939fa8e6c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('850b8a2b-d029-4147-b2de-a8a0203132cc', '21c76db0-c631-4704-ab30-610939fa8e6c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cdb502cb-e814-45da-861a-488bb4ce0cdd', '21c76db0-c631-4704-ab30-610939fa8e6c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('93bffa85-d279-47c8-899a-dd8044cf5f72', '21c76db0-c631-4704-ab30-610939fa8e6c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0a91db10-2764-4d97-b95e-5af30db7b134', '21c76db0-c631-4704-ab30-610939fa8e6c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('67be5877-19c7-43b3-9b37-8ece26c83e2c', '08516d4a-9206-4cdc-a69d-9cf4de96768f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('67be5877-19c7-43b3-9b37-8ece26c83e2c', '8c517bd0-cb24-4d2f-bfd3-7acac37a1cbe', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('67be5877-19c7-43b3-9b37-8ece26c83e2c', 'b6109891-dc33-4d09-ac3d-f1802d99d136', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('08516d4a-9206-4cdc-a69d-9cf4de96768f', '67be5877-19c7-43b3-9b37-8ece26c83e2c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('08516d4a-9206-4cdc-a69d-9cf4de96768f', '8c517bd0-cb24-4d2f-bfd3-7acac37a1cbe', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('08516d4a-9206-4cdc-a69d-9cf4de96768f', 'b6109891-dc33-4d09-ac3d-f1802d99d136', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8c517bd0-cb24-4d2f-bfd3-7acac37a1cbe', 'b6109891-dc33-4d09-ac3d-f1802d99d136', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8c517bd0-cb24-4d2f-bfd3-7acac37a1cbe', '67be5877-19c7-43b3-9b37-8ece26c83e2c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8c517bd0-cb24-4d2f-bfd3-7acac37a1cbe', '08516d4a-9206-4cdc-a69d-9cf4de96768f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b6109891-dc33-4d09-ac3d-f1802d99d136', '8c517bd0-cb24-4d2f-bfd3-7acac37a1cbe', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b6109891-dc33-4d09-ac3d-f1802d99d136', '67be5877-19c7-43b3-9b37-8ece26c83e2c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b6109891-dc33-4d09-ac3d-f1802d99d136', '08516d4a-9206-4cdc-a69d-9cf4de96768f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5ff01baf-04b2-4786-b8a7-8bca7bd95639', '8f89bc3a-a995-4cf6-94e7-2cee01006816', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5ff01baf-04b2-4786-b8a7-8bca7bd95639', 'fcab71f2-3378-49a9-ad47-e19da022bd11', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('715e8e70-4c95-477a-aad2-6f96b8dd080c', '5ff01baf-04b2-4786-b8a7-8bca7bd95639', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('715e8e70-4c95-477a-aad2-6f96b8dd080c', '8f89bc3a-a995-4cf6-94e7-2cee01006816', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('715e8e70-4c95-477a-aad2-6f96b8dd080c', 'fcab71f2-3378-49a9-ad47-e19da022bd11', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d526c37f-fa4d-4fc5-8acf-6a3ebbb1f3a1', '5ff01baf-04b2-4786-b8a7-8bca7bd95639', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d526c37f-fa4d-4fc5-8acf-6a3ebbb1f3a1', '8f89bc3a-a995-4cf6-94e7-2cee01006816', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d526c37f-fa4d-4fc5-8acf-6a3ebbb1f3a1', 'fcab71f2-3378-49a9-ad47-e19da022bd11', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f89bc3a-a995-4cf6-94e7-2cee01006816', '5ff01baf-04b2-4786-b8a7-8bca7bd95639', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f89bc3a-a995-4cf6-94e7-2cee01006816', 'fcab71f2-3378-49a9-ad47-e19da022bd11', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e7943a3d-ffd1-4292-bed2-5d69f67e8ce9', '5ff01baf-04b2-4786-b8a7-8bca7bd95639', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e7943a3d-ffd1-4292-bed2-5d69f67e8ce9', '8f89bc3a-a995-4cf6-94e7-2cee01006816', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e7943a3d-ffd1-4292-bed2-5d69f67e8ce9', 'fcab71f2-3378-49a9-ad47-e19da022bd11', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0cc87278-da45-4689-9425-227edc65146f', '5ff01baf-04b2-4786-b8a7-8bca7bd95639', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0cc87278-da45-4689-9425-227edc65146f', '8f89bc3a-a995-4cf6-94e7-2cee01006816', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0cc87278-da45-4689-9425-227edc65146f', 'fcab71f2-3378-49a9-ad47-e19da022bd11', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fcab71f2-3378-49a9-ad47-e19da022bd11', '5ff01baf-04b2-4786-b8a7-8bca7bd95639', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fcab71f2-3378-49a9-ad47-e19da022bd11', '8f89bc3a-a995-4cf6-94e7-2cee01006816', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('04912576-806d-4637-8b7e-db606aa121b4', '5ff01baf-04b2-4786-b8a7-8bca7bd95639', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('04912576-806d-4637-8b7e-db606aa121b4', '8f89bc3a-a995-4cf6-94e7-2cee01006816', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('04912576-806d-4637-8b7e-db606aa121b4', 'fcab71f2-3378-49a9-ad47-e19da022bd11', 2) ON CONFLICT DO NOTHING;



INSERT INTO public.faqs VALUES ('615f471d-52d1-4987-b755-ce45061d49ce', 'متى يوصلني الرد بعد الاشتراك؟', 'خلال 48 ساعة عمل. أيام العمل من الأحد إلى الخميس، من 12 الظهر حتى 9 مساءً، والتواصل على واتساب.', 0, true, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('855675bb-4b0d-4c1a-843c-b33bf8993ced', 'كيف تتم المتابعة؟', 'ترسل مراجعتك الأسبوعية في يوم المراجعة، وأرد عليك بتعديلات مسجلة (فيديو أو صوت). في الباقة الأساسية المتابعة كل أسبوعين. التواصل اليومي على واتساب مع رد خلال 48 ساعة.', 1, true, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('b0c8dffc-4d57-4af3-be23-7d8a9689507d', 'أنا مبتدئ تماماً، هل يناسبني؟', 'نعم. البرنامج يُبنى على مستواك الحالي، والتمارين مشروحة، وتقدر ترسل مقاطع أدائك لتصحيح التكنيك.', 2, true, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('19001c45-957d-49db-b35c-a09fe1196212', 'أتمرن في البيت، ماذا أحتاج من أدوات؟', 'تحدد في النموذج الأدوات المتوفرة عندك (دمبلز، حبال مقاومة، بار…) ويُبنى جدولك عليها.', 3, true, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('d680302d-deb6-41d7-963c-eda134152f52', 'كيف أدفع؟', 'بتحويل بنكي بعد تعبئة الاستبيان. أول ما ترسل الاستبيان يظهر لك رقم طلبك والمبلغ وبيانات الحساب. حوّل المبلغ وارفع صورة الإيصال من صفحة طلبك، ويتأكد اشتراكك بعد التحقق من وصول المبلغ.', 4, true, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('de86ffb0-32be-4548-bf07-a8166a2f8db8', 'ما شروط ضمان استرجاع المبلغ؟', 'في اشتراكات 3 أشهر لباقات المتابعة (المكثفة، المتقدمة، الأساسية): إذا لم يتحسن أي مؤشر من مؤشرات تقدمك بعد 12 أسبوعاً، يرجع لك المبلغ كاملاً.
مؤشرات التقدم (بحسب هدفك): متوسط الوزن الأسبوعي، أو محيط الخصر، أو القوة في التمارين الأساسية (الوزن أو التكرارات).
شروط الضمان:
- إرسال المراجعة الأسبوعية كل أسبوع.
- أخذ القياسات بانتظام.
- تصوير التمارين وإرسالها.
- الالتزام بجدول التغذية المخصص (في الباقات التي تشمل تغذية).
يُطلب الاسترجاع عبر واتساب خلال 14 يوماً من نهاية الأشهر الثلاثة.', 5, true, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('8d90e695-b5a8-4879-af72-49779a7a48ef', 'هل الجداول لي بعد انتهاء الاشتراك؟', 'نعم، جميع الجداول لك مدى الحياة وتقدر تعدّل عليها.', 6, true, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('92333900-355e-40ca-954d-517bb0718d84', 'ما هو التجديد المجاني؟', 'مكافأة للملتزمين: إذا كان اشتراكك 3 أشهر تحصل على 3 أشهر إضافية مجاناً، فيصير المجموع 6 أشهر بسعر 3.
الشروط:
- نسبة التزام 90% فأكثر: المراجعات الأسبوعية المرسلة والتمارين المسجلة.
- تقدم واضح في مؤشرات التقدم نفسها المذكورة في الضمان.
- للمتدربين الرجال: إرسال صور التطور (قبل وبعد) للمدربة للتوثيق، مع تغطية الوجه والسرة.
نشر الصور في السوشل ميديا اختياري بالكامل حسب موافقتك، ولا يؤثر على استحقاقك للتجديد.', 7, true, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('6024e148-a455-4e24-898d-3a6a285fe648', 'من يطّلع على بياناتي؟', 'المدربة فقط، وتُستخدم لتصميم برنامجك ومتابعتك. لا تُنشر نتيجتك أو صورتك إلا بموافقتك الصريحة في النموذج.', 8, true, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;



INSERT INTO public.foods VALUES ('aeb49bb2-4a3b-4ea7-9ecb-7bc85416854e', 'حليب بروتين سادة (ندى 320 مل)', 'Nada Protein Plain Milk 320ml', 'مشروبات بروتينية', 60.0, 8.5, 8.7, 0.1, 320.0, 'عبوة 320 مل', 'coach', 'nada.com.sa/protein-plain-milk', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('9b5a773a-99b0-40c8-aa91-f5426b2763c7', 'رز أبيض مطبوخ', 'Rice, white, long-grain, regular, enriched, cooked', 'حبوب ونشويات', 130.0, 2.7, 28.2, 0.3, 150.0, 'كوب إلا ربع', 'usda', '168878', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'حبوب ونشويات', 0.4, '{"iron": 1.2, "zinc": 0.49, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.04, "vit_k": 0, "folate": 97, "vit_b6": 0.093, "calcium": 10, "vit_b12": 0, "magnesium": 12, "potassium": 35}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a1eccce8-0e1a-4eab-b16f-658a3d023891', 'رز بني مطبوخ', 'Rice, brown, long-grain, cooked (Includes foods for USDA''s Food Distribution Program)', 'حبوب ونشويات', 123.0, 2.7, 25.6, 1.0, 150.0, NULL, 'usda', '169704', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'حبوب ونشويات', 1.6, '{"iron": 0.56, "zinc": 0.71, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.17, "vit_k": 0.2, "folate": 9, "vit_b6": 0.123, "calcium": 3, "vit_b12": 0, "magnesium": 39, "potassium": 86}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('65b4d7fa-303f-46d2-b2b3-89bfc2718015', 'رز أبيض (غير مطبوخ)', 'Rice, white, long-grain, regular, raw, enriched', 'حبوب ونشويات', 365.0, 7.1, 80.0, 0.7, 75.0, NULL, 'usda', '168877', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'حبوب ونشويات', 1.3, '{"iron": 4.31, "zinc": 1.09, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.11, "vit_k": 0.1, "folate": 387, "vit_b6": 0.164, "calcium": 28, "vit_b12": 0, "magnesium": 25, "potassium": 115}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('cec5f39a-b630-43a3-b530-1b340dfdc266', 'مكرونة مطبوخة', 'Pasta, cooked, enriched, without added salt', 'حبوب ونشويات', 158.0, 5.8, 30.9, 0.9, 140.0, 'كوب', 'usda', '169737', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'حبوب ونشويات', 1.8, '{"iron": 1.28, "zinc": 0.51, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.06, "vit_k": 0, "folate": 119, "vit_b6": 0.049, "calcium": 7, "vit_b12": 0, "magnesium": 18, "potassium": 44}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('8ef7894e-66c6-4be1-a3ab-605412417083', 'مكرونة (غير مطبوخة)', 'Pasta, dry, enriched', 'حبوب ونشويات', 371.0, 13.0, 74.7, 1.5, 75.0, NULL, 'usda', '169736', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'حبوب ونشويات', 3.2, '{"iron": 3.3, "zinc": 1.41, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.11, "vit_k": 0.1, "folate": 391, "vit_b6": 0.142, "calcium": 21, "vit_b12": 0, "magnesium": 53, "potassium": 223}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f7e13714-7490-4c19-a1f9-fddf7a6907b1', 'شوفان', 'Cereals, oats, regular and quick, not fortified, dry', 'حبوب ونشويات', 379.0, 13.2, 67.7, 6.5, 40.0, 'نص كوب', 'usda', '173904', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'حبوب ونشويات', 10.1, '{"iron": 4.25, "zinc": 3.64, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.42, "vit_k": 2, "folate": 32, "vit_b6": 0.1, "calcium": 52, "vit_b12": 0, "magnesium": 138, "potassium": 362}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('bc82cd5d-235c-4c77-98f9-ca5c38ee72a0', 'خبز أبيض (توست)', 'Bread, white, commercially prepared (includes soft bread crumbs)', 'خبز', 266.0, 8.9, 49.4, 3.3, 28.0, 'شريحة', 'usda', '174924', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'حبوب ونشويات', 2.7, '{"iron": 3.61, "zinc": 0.74, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.22, "vit_k": 0.2, "folate": 171, "vit_b6": 0.087, "calcium": 144, "vit_b12": 0, "magnesium": 23, "potassium": 126}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('94414456-33e9-40e1-9cd1-c4fd0e153d18', 'خبز بر (توست أسمر)', 'Bread, whole-wheat, commercially prepared', 'خبز', 252.0, 12.5, 42.7, 3.5, 32.0, 'شريحة', 'usda', '172688', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'حبوب ونشويات', 6.0, '{"iron": 2.47, "zinc": 1.77, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 2.66, "vit_k": 7.8, "folate": 42, "vit_b6": 0.215, "calcium": 161, "vit_b12": 0, "magnesium": 75, "potassium": 254}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3b2bce16-f967-4bb3-bed0-5461cbfc41eb', 'خبز عربي أبيض', 'Bread, pita, white, enriched', 'خبز', 275.0, 9.1, 55.7, 1.2, 60.0, 'رغيف صغير', 'usda', '174915', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'حبوب ونشويات', 2.2, '{"iron": 2.62, "zinc": 0.84, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.3, "vit_k": 0.2, "folate": 165, "vit_b6": 0.034, "calcium": 86, "vit_b12": 0, "magnesium": 26, "potassium": 120}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('736f35b0-3448-4bb9-8268-d7959ac02d2a', 'خبز عربي بر', 'Bread, pita, whole-wheat', 'خبز', 262.0, 9.8, 55.9, 1.7, 64.0, 'رغيف صغير', 'usda', '174916', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'حبوب ونشويات', 6.1, '{"iron": 3.06, "zinc": 1.52, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.61, "vit_k": 1.4, "folate": 35, "vit_b6": 0.265, "calcium": 15, "vit_b12": 0, "magnesium": 69, "potassium": 170}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f7788334-3174-4dc1-8ac1-dcd10087a624', 'تورتيلا قمح', 'Tortillas, ready-to-bake or -fry, flour, refrigerated', 'خبز', 306.0, 8.2, 49.4, 8.0, 45.0, 'حبة', 'usda', '175037', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'حبوب ونشويات', 3.5, '{"iron": 3.63, "zinc": 0.53, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0, "vit_k": 7.2, "folate": 149, "vit_b6": 0.059, "calcium": 146, "vit_b12": 0, "magnesium": 22, "potassium": 125}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ad444eb1-a475-48b7-9db4-44620074c39e', 'بطاطس مسلوقة', 'Potatoes, boiled, cooked without skin, flesh, without salt', 'حبوب ونشويات', 86.0, 1.7, 20.0, 0.1, 150.0, 'حبة وسط', 'usda', '170440', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'خضار نشوية', 1.8, '{"iron": 0.31, "zinc": 0.27, "vit_a": 0, "vit_c": 7.4, "vit_d": 0, "vit_e": 0.01, "vit_k": 2.2, "folate": 9, "vit_b6": 0.269, "calcium": 8, "vit_b12": 0, "magnesium": 20, "potassium": 328}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('6befb371-55ba-4122-850b-2a44f7facb4b', 'بطاطا حلوة مشوية', 'Sweet potato, cooked, baked in skin, flesh, without salt', 'حبوب ونشويات', 90.0, 2.0, 20.7, 0.2, 150.0, 'حبة وسط', 'usda', '168483', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'خضار نشوية', 3.3, '{"iron": 0.69, "zinc": 0.32, "vit_a": 961, "vit_c": 19.6, "vit_d": 0, "vit_e": 0.71, "vit_k": 2.3, "folate": 6, "vit_b6": 0.286, "calcium": 38, "vit_b12": 0, "magnesium": 27, "potassium": 475}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('5948ac96-7549-45b8-8f24-7e17fd4807ef', 'برغل مطبوخ', 'Bulgur, cooked', 'حبوب ونشويات', 83.0, 3.1, 18.6, 0.2, 150.0, NULL, 'usda', '170287', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'حبوب ونشويات', 4.5, '{"iron": 0.96, "zinc": 0.57, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.01, "vit_k": 0.5, "folate": 18, "vit_b6": 0.083, "calcium": 10, "vit_b12": 0, "magnesium": 32, "potassium": 68}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('54905b2e-ea5c-4e58-8a7d-208fa6cb06fb', 'كينوا مطبوخة', 'Quinoa, cooked', 'حبوب ونشويات', 120.0, 4.4, 21.3, 1.9, 150.0, NULL, 'usda', '168917', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'حبوب ونشويات', 2.8, '{"iron": 1.49, "zinc": 1.09, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.63, "vit_k": 0, "folate": 42, "vit_b6": 0.123, "calcium": 17, "vit_b12": 0, "magnesium": 64, "potassium": 172}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('0551faef-8ac2-46d0-9d9a-8831784a1972', 'كورن فليكس', 'Cereals ready-to-eat, RALSTON Corn Flakes', 'حبوب ونشويات', 384.0, 5.9, 88.0, 0.9, 30.0, NULL, 'usda', '174648', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'حبوب ونشويات', 2.7, '{"iron": 19.4, "zinc": 0.2, "vit_a": 981, "vit_c": 65, "vit_d": 7.1, "vit_e": 0.02, "vit_k": 0, "vit_b6": 1.907, "calcium": 2, "vit_b12": 5.36, "magnesium": 7, "potassium": 107}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('c942988e-b91f-44b5-b53d-7063258bc157', 'صدر دجاج مشوي', 'Chicken, broilers or fryers, breast, meat only, cooked, roasted', 'لحوم ودواجن', 165.0, 31.0, 0.0, 3.6, 100.0, NULL, 'usda', '171477', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'لحوم بيضاء (دواجن)', 0.0, '{"iron": 1.04, "zinc": 1, "vit_a": 6, "vit_c": 0, "vit_d": 0.1, "vit_e": 0.27, "vit_k": 0.3, "folate": 4, "vit_b6": 0.6, "calcium": 15, "vit_b12": 0.34, "magnesium": 29, "potassium": 256}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('613b3a7f-5143-4583-813c-c78a1bab8901', 'صدر دجاج نيء', 'Chicken, broiler or fryers, breast, skinless, boneless, meat only, raw', 'لحوم ودواجن', 120.0, 22.5, 0.0, 2.6, 150.0, NULL, 'usda', '171077', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'لحوم بيضاء (دواجن)', 0.0, '{"iron": 0.37, "zinc": 0.68, "vit_a": 9, "vit_c": 0, "vit_d": 0, "vit_e": 0.56, "vit_k": 0, "folate": 9, "vit_b6": 0.811, "calcium": 5, "vit_b12": 0.21, "magnesium": 28, "potassium": 334}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('94dcf0fa-7d6e-464e-84a1-79d1a9053158', 'فخذ دجاج مشوي (بدون جلد)', 'Chicken, broilers or fryers, thigh, meat only, cooked, roasted', 'لحوم ودواجن', 179.0, 24.8, 0.0, 8.2, 100.0, NULL, 'usda', '172388', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'لحوم بيضاء (دواجن)', 0.0, '{"iron": 1.13, "zinc": 1.92, "vit_a": 8, "vit_c": 0, "vit_d": 0.2, "vit_e": 0.18, "vit_k": 3.9, "folate": 5, "vit_b6": 0.462, "calcium": 9, "vit_b12": 0.42, "magnesium": 24, "potassium": 269}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('32478483-029e-47c6-a0a8-e334d9f2aa60', 'لحم بقري مفروم 90% مطبوخ', 'Beef, ground, 90% lean meat / 10% fat, patty, cooked, broiled', 'لحوم ودواجن', 217.0, 26.1, 0.0, 11.8, 100.0, NULL, 'usda', '174031', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'لحوم حمراء', 0.0, '{"iron": 2.71, "zinc": 6.37, "vit_a": 3, "vit_c": 0, "vit_d": 0, "vit_e": 0.12, "vit_k": 1.1, "folate": 8, "vit_b6": 0.397, "calcium": 13, "vit_b12": 2.56, "magnesium": 22, "potassium": 333}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('dc3fddb7-9cc8-4976-9ea4-f8fdc0caa971', 'لحم بقري مفروم 80% مطبوخ', 'Beef, ground, 80% lean meat / 20% fat, patty, cooked, broiled', 'لحوم ودواجن', 270.0, 25.8, 0.0, 17.8, 100.0, NULL, 'usda', '171797', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'لحوم حمراء', 0.0, '{"iron": 2.48, "zinc": 6.25, "vit_a": 3, "vit_c": 0, "vit_d": 0, "vit_e": 0.12, "vit_k": 1.6, "folate": 10, "vit_b6": 0.366, "calcium": 24, "vit_b12": 2.73, "magnesium": 20, "potassium": 304}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('1682c95d-b5db-41f9-91c1-dfa1a07c8a3f', 'لحم غنم مطبوخ', 'Lamb, composite of trimmed retail cuts, separable lean only, trimmed to 1/4" fat, choice, cooked', 'لحوم ودواجن', 206.0, 28.2, 0.0, 9.5, 100.0, NULL, 'usda', '174308', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'لحوم حمراء', 0.0, '{"iron": 2.05, "zinc": 5.27, "vit_a": 0, "vit_c": 0, "vit_e": 0.19, "folate": 23, "vit_b6": 0.16, "calcium": 15, "vit_b12": 2.61, "magnesium": 26, "potassium": 344}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('198735f8-4f93-42b2-8a24-d569fbe229c1', 'ديك رومي (شرائح)', 'Turkey, whole, breast, meat only, cooked, roasted', 'لحوم ودواجن', 147.0, 30.1, 0.0, 2.1, 50.0, NULL, 'usda', '171496', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'لحوم بيضاء (دواجن)', 0.0, '{"iron": 0.71, "zinc": 1.72, "vit_a": 3, "vit_c": 0, "vit_d": 0.3, "vit_e": 0.06, "vit_k": 0, "folate": 9, "vit_b6": 0.807, "calcium": 9, "vit_b12": 0.39, "magnesium": 32, "potassium": 249}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ba518847-cc65-4374-b865-564b0fe42aa8', 'تونة معلبة بالماء', 'Fish, tuna, light, canned in water, drained solids (Includes foods for USDA''s Food Distribution Program)', 'أسماك', 86.0, 19.4, 0.0, 1.0, 100.0, 'علبة صغيرة مصفاة', 'usda', '173709', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'أسماك ومأكولات بحرية', 0.0, '{"iron": 1.63, "zinc": 0.69, "vit_a": 17, "vit_c": 0, "vit_d": 1.2, "vit_e": 0.33, "vit_k": 0.2, "folate": 4, "vit_b6": 0.319, "calcium": 17, "vit_b12": 2.55, "magnesium": 23, "potassium": 179}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('12f19836-ed50-4ae8-b1e7-66d98ea94af2', 'تونة معلبة بالزيت', 'Fish, tuna, light, canned in oil, drained solids', 'أسماك', 198.0, 29.1, 0.0, 8.2, 100.0, NULL, 'usda', '173708', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'أسماك ومأكولات بحرية', 0.0, '{"iron": 1.39, "zinc": 0.9, "vit_a": 23, "vit_c": 0, "vit_d": 6.7, "vit_e": 0.87, "vit_k": 44, "folate": 5, "vit_b6": 0.11, "calcium": 13, "vit_b12": 2.2, "magnesium": 31, "potassium": 207}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ffd06252-f668-45b9-849b-88706a7efd49', 'سلمون مطبوخ', 'Fish, salmon, Atlantic, farmed, cooked, dry heat', 'أسماك', 206.0, 22.1, 0.0, 12.4, 120.0, NULL, 'usda', '175168', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'أسماك ومأكولات بحرية', 0.0, '{"iron": 0.34, "zinc": 0.43, "vit_a": 69, "vit_c": 3.7, "vit_d": 13.1, "vit_e": 1.14, "vit_k": 0.1, "folate": 34, "vit_b6": 0.647, "calcium": 15, "vit_b12": 2.8, "magnesium": 30, "potassium": 384}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d11535de-0df2-4b5b-bc68-df5a1583e785', 'سلمون مدخن', 'Fish, salmon, chinook, smoked', 'أسماك', 117.0, 18.3, 0.0, 4.3, 60.0, NULL, 'usda', '173687', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'أسماك ومأكولات بحرية', 0.0, '{"iron": 0.85, "zinc": 0.31, "vit_a": 26, "vit_c": 0, "vit_d": 17.1, "vit_e": 1.35, "vit_k": 0.1, "folate": 2, "vit_b6": 0.278, "calcium": 11, "vit_b12": 3.26, "magnesium": 18, "potassium": 175}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('6eea90ff-9a2b-4fbe-9bf1-258c9231a49a', 'روبيان مطبوخ', 'Crustaceans, shrimp, cooked', 'أسماك', 99.0, 24.0, 0.2, 0.3, 100.0, NULL, 'usda', '175180', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'أسماك ومأكولات بحرية', 0.0, '{"iron": 0.51, "zinc": 1.64, "calcium": 70, "magnesium": 39, "potassium": 259}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b3747d6d-26bb-47bc-88b9-3a7c16495743', 'هامور/سمك أبيض مطبوخ', 'Fish, grouper, mixed species, cooked, dry heat', 'أسماك', 118.0, 24.8, 0.0, 1.3, 150.0, NULL, 'usda', '171963', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'أسماك ومأكولات بحرية', 0.0, '{"iron": 1.14, "zinc": 0.51, "vit_a": 50, "vit_c": 0, "folate": 10, "vit_b6": 0.35, "calcium": 21, "vit_b12": 0.69, "magnesium": 37, "potassium": 475}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('447a902b-cdfe-45d6-97f7-28bc42fd11d0', 'بيض كامل', 'Egg, whole, raw, fresh', 'بيض وألبان', 143.0, 12.6, 0.7, 9.5, 50.0, 'بيضة', 'usda', '171287', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'بيض', 0.0, '{"iron": 1.75, "zinc": 1.29, "vit_a": 160, "vit_c": 0, "vit_d": 2, "vit_e": 1.05, "vit_k": 0.3, "folate": 47, "vit_b6": 0.17, "calcium": 56, "vit_b12": 0.89, "magnesium": 12, "potassium": 138}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('72b2da54-5017-4c81-990a-145da57389b8', 'بياض بيض', 'Egg, white, raw, fresh', 'بيض وألبان', 52.0, 10.9, 0.7, 0.2, 33.0, 'بياض بيضة', 'usda', '172183', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'بيض', 0.0, '{"iron": 0.08, "zinc": 0.03, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0, "vit_k": 0, "folate": 4, "vit_b6": 0.005, "calcium": 7, "vit_b12": 0.09, "magnesium": 11, "potassium": 163}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('87985dcb-1d6a-4e85-9db2-b93e4b8aeb9e', 'بيض مسلوق', 'Egg, whole, cooked, hard-boiled', 'بيض وألبان', 155.0, 12.6, 1.1, 10.6, 50.0, 'بيضة', 'usda', '173424', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'بيض', 0.0, '{"iron": 1.19, "zinc": 1.05, "vit_a": 149, "vit_c": 0, "vit_d": 2.2, "vit_e": 1.03, "vit_k": 0.3, "folate": 44, "vit_b6": 0.121, "calcium": 50, "vit_b12": 1.11, "magnesium": 10, "potassium": 126}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('4b4dc25d-1f15-4aa8-a8df-b8767246d247', 'حليب كامل الدسم', 'Milk, whole, 3.25% milkfat, with added vitamin D', 'بيض وألبان', 61.0, 3.2, 4.8, 3.3, 244.0, 'كوب', 'usda', '171265', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', 0.0, '{"iron": 0.03, "zinc": 0.37, "vit_a": 46, "vit_c": 0, "vit_d": 1.3, "vit_e": 0.07, "vit_k": 0.3, "folate": 5, "vit_b6": 0.036, "calcium": 113, "vit_b12": 0.45, "magnesium": 10, "potassium": 132}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b54b8706-99a9-44e7-8dfb-0e8db540e5ac', 'حليب قليل الدسم 1%', 'Milk, lowfat, fluid, 1% milkfat, with added vitamin A and vitamin D', 'بيض وألبان', 42.0, 3.4, 5.0, 1.0, 244.0, 'كوب', 'usda', '170872', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', 0.0, '{"iron": 0.03, "zinc": 0.42, "vit_a": 58, "vit_c": 0, "vit_d": 1.2, "vit_e": 0.01, "vit_k": 0.1, "folate": 5, "vit_b6": 0.037, "calcium": 125, "vit_b12": 0.47, "magnesium": 11, "potassium": 150}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d4d7f205-4465-4d2a-8bc7-42864205bf97', 'حليب خالي الدسم', 'Milk, nonfat, fluid, with added vitamin A and vitamin D (fat free or skim)', 'بيض وألبان', 34.0, 3.4, 5.0, 0.1, 245.0, 'كوب', 'usda', '171269', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', 0.0, '{"iron": 0.03, "zinc": 0.42, "vit_a": 61, "vit_c": 0, "vit_d": 1.2, "vit_e": 0.01, "vit_k": 0, "folate": 5, "vit_b6": 0.037, "calcium": 122, "vit_b12": 0.5, "magnesium": 11, "potassium": 156}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b0575571-4b5c-4a7c-8820-b605338594a4', 'زبادي كامل الدسم', 'Yogurt, plain, whole milk', 'بيض وألبان', 61.0, 3.5, 4.7, 3.3, 170.0, NULL, 'usda', '171284', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', 0.0, '{"iron": 0.05, "zinc": 0.59, "vit_a": 27, "vit_c": 0.5, "vit_d": 0.1, "vit_e": 0.06, "vit_k": 0.2, "folate": 7, "vit_b6": 0.032, "calcium": 121, "vit_b12": 0.37, "magnesium": 12, "potassium": 155}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('de12736b-5009-4626-8c78-3b27e1a579f2', 'زبادي قليل الدسم', 'Yogurt, plain, low fat', 'بيض وألبان', 63.0, 5.3, 7.0, 1.6, 170.0, NULL, 'usda', '170886', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', 0.0, '{"iron": 0.08, "zinc": 0.89, "vit_a": 14, "vit_c": 0.8, "vit_d": 0, "vit_e": 0.03, "vit_k": 0.2, "folate": 11, "vit_b6": 0.049, "calcium": 183, "vit_b12": 0.56, "magnesium": 17, "potassium": 234}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('db05e64b-d379-4ec8-b145-0648b6f4c6d7', 'زبادي يوناني قليل الدسم', 'Yogurt, Greek, plain, lowfat', 'بيض وألبان', 73.0, 10.0, 3.9, 1.9, 170.0, NULL, 'usda', '170903', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', 0.0, '{"iron": 0.04, "zinc": 0.6, "vit_a": 90, "vit_c": 0.8, "vit_d": 0, "vit_e": 0.04, "vit_k": 0.2, "folate": 12, "vit_b6": 0.055, "calcium": 115, "vit_b12": 0.52, "magnesium": 11, "potassium": 141}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('900ea2f9-f5a5-4b5b-b2db-0c5175269a8a', 'زبادي يوناني خالي الدسم', 'Yogurt, Greek, plain, nonfat (Includes foods for USDA''s Food Distribution Program)', 'بيض وألبان', 59.0, 10.2, 3.6, 0.4, 170.0, NULL, 'usda', '170894', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', 0.0, '{"iron": 0.07, "zinc": 0.52, "vit_a": 1, "vit_c": 0, "vit_d": 0, "vit_e": 0.01, "vit_k": 0, "folate": 7, "vit_b6": 0.063, "calcium": 110, "vit_b12": 0.75, "magnesium": 11, "potassium": 141}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('6a19d55d-aa14-460d-830d-df5fff142523', 'جبنة قريش (كوتج)', 'Cheese, cottage, lowfat, 2% milkfat', 'بيض وألبان', 81.0, 10.5, 4.8, 2.3, 113.0, 'نص كوب', 'usda', '172182', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', 0.0, '{"iron": 0.13, "zinc": 0.51, "vit_a": 68, "vit_c": 0, "vit_d": 0, "vit_e": 0.08, "vit_k": 0, "folate": 8, "vit_b6": 0.057, "calcium": 111, "vit_b12": 0.47, "magnesium": 9, "potassium": 125}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('894559b9-36a8-4b71-bb6a-9c90f51e874b', 'جبنة موزاريلا قليلة الدسم', 'Cheese, mozzarella, part skim milk', 'بيض وألبان', 254.0, 24.3, 2.8, 15.9, 28.0, NULL, 'usda', '170847', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', 0.0, '{"iron": 0.22, "zinc": 2.76, "vit_a": 127, "vit_c": 0, "vit_d": 0.3, "vit_e": 0.14, "vit_k": 1.6, "folate": 9, "vit_b6": 0.07, "calcium": 782, "vit_b12": 0.82, "magnesium": 23, "potassium": 84}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('5c120fd6-8fe2-412e-bc14-bdddce977b33', 'جبنة شيدر', 'Cheese, cheddar (Includes foods for USDA''s Food Distribution Program)', 'بيض وألبان', 403.0, 22.9, 3.4, 33.3, 28.0, 'شريحة', 'usda', '173414', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', 0.0, '{"iron": 0.14, "zinc": 3.64, "vit_a": 337, "vit_c": 0, "vit_d": 0.6, "vit_e": 0.71, "vit_k": 2.4, "folate": 27, "vit_b6": 0.066, "calcium": 710, "vit_b12": 1.1, "magnesium": 27, "potassium": 76}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('8fa784bb-757b-4129-963c-66ddbd56d273', 'جبنة فيتا', 'Cheese, feta', 'بيض وألبان', 265.0, 14.2, 3.9, 21.5, 28.0, NULL, 'usda', '173420', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', 0.0, '{"iron": 0.65, "zinc": 2.88, "vit_a": 125, "vit_c": 0, "vit_d": 0.4, "vit_e": 0.18, "vit_k": 1.8, "folate": 32, "vit_b6": 0.424, "calcium": 493, "vit_b12": 1.69, "magnesium": 19, "potassium": 62}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('bfa8b862-4ac8-48fe-88c0-7f81028c4bfd', 'جبنة كريمية', 'Cheese, cream', 'بيض وألبان', 350.0, 6.2, 5.5, 34.4, 30.0, NULL, 'usda', '173418', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', 0.0, '{"iron": 0.11, "zinc": 0.5, "vit_a": 308, "vit_c": 0, "vit_d": 0, "vit_e": 0.86, "vit_k": 2.1, "folate": 9, "vit_b6": 0.056, "calcium": 97, "vit_b12": 0.22, "magnesium": 9, "potassium": 132}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('8e326615-89e1-4731-82d4-9a3a50f6c5bb', 'واي بروتين', 'Beverages, Whey protein powder isolate', 'مكملات', 359.0, 58.1, 29.1, 1.2, 30.0, 'سكوب', 'usda', '173177', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'مكملات', 0.0, '{"iron": 1.26, "zinc": 8.72, "vit_a": 872, "vit_c": 34.9, "vit_d": 0, "vit_e": 7.85, "vit_k": 46.5, "folate": 395, "vit_b6": 1.163, "calcium": 698, "vit_b12": 3.49, "magnesium": 233, "potassium": 872}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('be7dac3b-4830-43c5-a976-b383bcf98fee', 'عدس مطبوخ', 'Lentils, mature seeds, cooked, boiled, without salt', 'بقوليات', 116.0, 9.0, 20.1, 0.4, 150.0, NULL, 'usda', '172421', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'بقوليات', 7.9, '{"iron": 3.33, "zinc": 1.27, "vit_a": 0, "vit_c": 1.5, "vit_d": 0, "vit_e": 0.11, "vit_k": 1.7, "folate": 181, "vit_b6": 0.178, "calcium": 19, "vit_b12": 0, "magnesium": 36, "potassium": 369}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('cb31e5bf-418f-4bce-820a-2e5a34880046', 'حمص مطبوخ', 'Chickpeas (garbanzo beans, bengal gram), mature seeds, cooked, boiled, without salt', 'بقوليات', 164.0, 8.9, 27.4, 2.6, 150.0, NULL, 'usda', '173757', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'بقوليات', 7.6, '{"iron": 2.89, "zinc": 1.53, "vit_a": 1, "vit_c": 1.3, "vit_d": 0, "vit_e": 0.35, "vit_k": 4, "folate": 172, "vit_b6": 0.139, "calcium": 49, "vit_b12": 0, "magnesium": 48, "potassium": 291}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('bb2e9cc2-f311-4137-a3cc-38248c6c6bbf', 'فول مدمس (مطبوخ)', 'Broadbeans (fava beans), mature seeds, cooked, boiled, without salt', 'بقوليات', 110.0, 7.6, 19.7, 0.4, 150.0, NULL, 'usda', '173753', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'بقوليات', 5.4, '{"iron": 1.5, "zinc": 1.01, "vit_a": 1, "vit_c": 0.3, "vit_d": 0, "vit_e": 0.02, "vit_k": 2.9, "folate": 104, "vit_b6": 0.072, "calcium": 36, "vit_b12": 0, "magnesium": 43, "potassium": 268}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('70bc41ba-b94c-4433-bdf0-73321e0719d3', 'فاصوليا حمراء مطبوخة', 'Beans, kidney, all types, mature seeds, cooked, boiled, without salt', 'بقوليات', 127.0, 8.7, 22.8, 0.5, 150.0, NULL, 'usda', '173740', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'بقوليات', 6.4, '{"iron": 2.22, "zinc": 1, "vit_a": 0, "vit_c": 1.2, "vit_d": 0, "vit_e": 0.03, "vit_k": 8.4, "folate": 130, "vit_b6": 0.12, "calcium": 35, "vit_b12": 0, "magnesium": 42, "potassium": 405}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('14e33428-ec3a-4ef5-b1d9-f1049824c955', 'حمص بطحينة (حمص جاهز)', 'Hummus, commercial', 'بقوليات', 237.0, 7.8, 15.0, 17.8, 60.0, NULL, 'usda', '174289', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'بقوليات', 5.5, '{"iron": 2.54, "zinc": 1.44, "vit_a": 1, "vit_c": 0, "vit_d": 0, "vit_e": 1.54, "vit_k": 22.8, "folate": 48, "vit_b6": 0.146, "calcium": 47, "vit_b12": 0, "magnesium": 75, "potassium": 312}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('fac7f530-5286-43fb-b9f4-6347c566c94d', 'تمر مجدول', 'Dates, medjool', 'فواكه', 277.0, 1.8, 75.0, 0.2, 24.0, 'حبة', 'usda', '168191', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'فواكه', 6.7, '{"iron": 0.9, "zinc": 0.44, "vit_a": 7, "vit_c": 0, "vit_d": 0, "vit_k": 2.7, "folate": 15, "vit_b6": 0.249, "calcium": 64, "magnesium": 54, "potassium": 696}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d7888a25-a7d3-4bb7-8643-68e177dff2a0', 'تمر (دقلة نور)', 'Dates, deglet noor', 'فواكه', 282.0, 2.5, 75.0, 0.4, 7.0, 'حبة', 'usda', '171726', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'فواكه', 8.0, '{"iron": 1.02, "zinc": 0.29, "vit_a": 0, "vit_c": 0.4, "vit_d": 0, "vit_e": 0.05, "vit_k": 2.7, "folate": 19, "vit_b6": 0.165, "calcium": 39, "vit_b12": 0, "magnesium": 43, "potassium": 656}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('e9c8bd8d-1fd6-430d-afd4-6ad5d541e931', 'موز', 'Bananas, raw', 'فواكه', 89.0, 1.1, 22.8, 0.3, 118.0, 'حبة وسط', 'usda', '173944', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'فواكه', 2.6, '{"iron": 0.26, "zinc": 0.15, "vit_a": 3, "vit_c": 8.7, "vit_d": 0, "vit_e": 0.1, "vit_k": 0.5, "folate": 20, "vit_b6": 0.367, "calcium": 5, "vit_b12": 0, "magnesium": 27, "potassium": 358}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('4e2d3249-6c3f-4e45-8845-e444cc0da084', 'تفاح', 'Apples, raw, with skin (Includes foods for USDA''s Food Distribution Program)', 'فواكه', 52.0, 0.3, 13.8, 0.2, 182.0, 'حبة وسط', 'usda', '171688', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'فواكه', 2.4, '{"iron": 0.12, "zinc": 0.04, "vit_a": 3, "vit_c": 4.6, "vit_d": 0, "vit_e": 0.18, "vit_k": 2.2, "folate": 3, "vit_b6": 0.041, "calcium": 6, "vit_b12": 0, "magnesium": 5, "potassium": 107}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('8e3f945f-10ee-4a27-a7f9-1b5b3e6d3fca', 'برتقال', 'Oranges, raw, all commercial varieties', 'فواكه', 47.0, 0.9, 11.8, 0.1, 131.0, 'حبة', 'usda', '169097', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'فواكه', 2.4, '{"iron": 0.1, "zinc": 0.07, "vit_a": 11, "vit_c": 53.2, "vit_d": 0, "vit_e": 0.18, "vit_k": 0, "folate": 30, "vit_b6": 0.06, "calcium": 40, "vit_b12": 0, "magnesium": 10, "potassium": 181}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('edd4bc71-d374-474b-b52c-6740f8ae026f', 'فراولة', 'Strawberries, raw', 'فواكه', 32.0, 0.7, 7.7, 0.3, 150.0, 'كوب', 'usda', '167762', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'فواكه', 2.0, '{"iron": 0.41, "zinc": 0.14, "vit_a": 1, "vit_c": 58.8, "vit_d": 0, "vit_e": 0.29, "vit_k": 2.2, "folate": 24, "vit_b6": 0.047, "calcium": 16, "vit_b12": 0, "magnesium": 13, "potassium": 153}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('5a9f15d0-0a33-46e2-99b9-6300c4eebfbf', 'عنب', 'Grapes, red or green (European type, such as Thompson seedless), raw', 'فواكه', 69.0, 0.7, 18.1, 0.2, 150.0, 'كوب', 'usda', '174683', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'فواكه', 0.9, '{"iron": 0.36, "zinc": 0.07, "vit_a": 3, "vit_c": 3.2, "vit_d": 0, "vit_e": 0.19, "vit_k": 14.6, "folate": 2, "vit_b6": 0.086, "calcium": 10, "vit_b12": 0, "magnesium": 7, "potassium": 191}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('508b8e0f-79ef-47be-ae99-835909a9c08e', 'بطيخ', 'Watermelon, raw', 'فواكه', 30.0, 0.6, 7.6, 0.2, 280.0, 'كوب ونص', 'usda', '167765', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'فواكه', 0.4, '{"iron": 0.24, "zinc": 0.1, "vit_a": 28, "vit_c": 8.1, "vit_d": 0, "vit_e": 0.05, "vit_k": 0.1, "folate": 3, "vit_b6": 0.045, "calcium": 7, "vit_b12": 0, "magnesium": 10, "potassium": 112}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('84cf7eb5-fe1e-4a92-9179-1472da285453', 'مانجو', 'Mangos, raw', 'فواكه', 60.0, 0.8, 15.0, 0.4, 165.0, 'كوب', 'usda', '169910', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'فواكه', 1.6, '{"iron": 0.16, "zinc": 0.09, "vit_a": 54, "vit_c": 36.4, "vit_d": 0, "vit_e": 0.9, "vit_k": 4.2, "folate": 43, "vit_b6": 0.119, "calcium": 11, "vit_b12": 0, "magnesium": 10, "potassium": 168}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('49b2359d-5ef6-405c-9f9c-9dc09545d90a', 'أناناس', 'Pineapple, raw, all varieties', 'فواكه', 50.0, 0.5, 13.1, 0.1, 165.0, 'كوب', 'usda', '169124', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'فواكه', 1.4, '{"iron": 0.29, "zinc": 0.12, "vit_a": 3, "vit_c": 47.8, "vit_d": 0, "vit_e": 0.02, "vit_k": 0.7, "folate": 18, "vit_b6": 0.112, "calcium": 13, "vit_b12": 0, "magnesium": 12, "potassium": 109}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('5e5f5a93-6027-4f63-8239-4ab55858aa3d', 'توت أزرق', 'Blueberries, raw', 'فواكه', 57.0, 0.7, 14.5, 0.3, 148.0, 'كوب', 'usda', '171711', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'فواكه', 2.4, '{"iron": 0.28, "zinc": 0.16, "vit_a": 3, "vit_c": 9.7, "vit_d": 0, "vit_e": 0.57, "vit_k": 19.3, "folate": 6, "vit_b6": 0.052, "calcium": 6, "vit_b12": 0, "magnesium": 6, "potassium": 77}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('bafe502d-8a4b-4e44-ad6b-d40b16f7444e', 'كيوي', 'Kiwifruit, green, raw', 'فواكه', 61.0, 1.1, 14.7, 0.5, 75.0, 'حبة', 'usda', '168153', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'فواكه', 3.0, '{"iron": 0.31, "zinc": 0.14, "vit_a": 4, "vit_c": 92.7, "vit_d": 0, "vit_e": 1.46, "vit_k": 40.3, "folate": 25, "vit_b6": 0.063, "calcium": 34, "vit_b12": 0, "magnesium": 17, "potassium": 312}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('8d2602f9-da07-4968-9f4e-2b3d440c56f6', 'رمان', 'Pomegranates, raw', 'فواكه', 83.0, 1.7, 18.7, 1.2, 87.0, 'نص كوب حبوب', 'usda', '169134', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'فواكه', 4.0, '{"iron": 0.3, "zinc": 0.35, "vit_a": 0, "vit_c": 10.2, "vit_d": 0, "vit_e": 0.6, "vit_k": 16.4, "folate": 38, "vit_b6": 0.075, "calcium": 10, "vit_b12": 0, "magnesium": 12, "potassium": 236}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('95831e86-a9a6-4c38-b31a-23fd987c2570', 'خيار', 'Cucumber, with peel, raw', 'خضار', 15.0, 0.7, 3.6, 0.1, 100.0, NULL, 'usda', '168409', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'خضار', 0.5, '{"iron": 0.28, "zinc": 0.2, "vit_a": 5, "vit_c": 2.8, "vit_d": 0, "vit_e": 0.03, "vit_k": 16.4, "folate": 7, "vit_b6": 0.04, "calcium": 16, "vit_b12": 0, "magnesium": 13, "potassium": 147}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('98efa982-18e7-4fd7-b7b2-55e00d892cf1', 'طماطم', 'Tomatoes, red, ripe, raw, year round average', 'خضار', 18.0, 0.9, 3.9, 0.2, 120.0, 'حبة وسط', 'usda', '170457', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'خضار', 1.2, '{"iron": 0.27, "zinc": 0.17, "vit_a": 42, "vit_c": 13.7, "vit_d": 0, "vit_e": 0.54, "vit_k": 7.9, "folate": 15, "vit_b6": 0.08, "calcium": 10, "vit_b12": 0, "magnesium": 11, "potassium": 237}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a8cc2500-5aea-4551-8786-44ecee467c78', 'خس', 'Lettuce, cos or romaine, raw', 'خضار', 17.0, 1.2, 3.3, 0.3, 50.0, NULL, 'usda', '169247', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'خضار', 2.1, '{"iron": 0.97, "zinc": 0.23, "vit_a": 436, "vit_c": 4, "vit_d": 0, "vit_e": 0.13, "vit_k": 102.5, "folate": 136, "vit_b6": 0.074, "calcium": 33, "vit_b12": 0, "magnesium": 14, "potassium": 247}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d4806204-75f7-438b-877a-9fdb75c4cb3d', 'جزر', 'Carrots, raw', 'خضار', 41.0, 0.9, 9.6, 0.2, 60.0, 'حبة', 'usda', '170393', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'خضار', 2.8, '{"iron": 0.3, "zinc": 0.24, "vit_a": 835, "vit_c": 5.9, "vit_d": 0, "vit_e": 0.66, "vit_k": 13.2, "folate": 19, "vit_b6": 0.138, "calcium": 33, "vit_b12": 0, "magnesium": 12, "potassium": 320}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('934fafb0-3595-41c0-bf50-2d2c45b37d4d', 'بروكلي مطبوخ', 'Broccoli, cooked, boiled, drained, without salt', 'خضار', 35.0, 2.4, 7.2, 0.4, 90.0, NULL, 'usda', '169967', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'خضار', 3.3, '{"iron": 0.67, "zinc": 0.45, "vit_a": 77, "vit_c": 64.9, "vit_d": 0, "vit_e": 1.45, "vit_k": 141.1, "folate": 108, "vit_b6": 0.2, "calcium": 40, "vit_b12": 0, "magnesium": 21, "potassium": 293}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('139653c1-79f7-4699-93f3-62f9f8cbfd75', 'سبانخ', 'Spinach, raw', 'خضار', 23.0, 2.9, 3.6, 0.4, 30.0, 'كوب', 'usda', '168462', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'خضار', 2.2, '{"iron": 2.71, "zinc": 0.53, "vit_a": 469, "vit_c": 28.1, "vit_d": 0, "vit_e": 2.03, "vit_k": 482.9, "folate": 194, "vit_b6": 0.195, "calcium": 99, "vit_b12": 0, "magnesium": 79, "potassium": 558}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('4028f4f9-ba99-43bb-8dad-2e0250ee434d', 'فلفل رومي أحمر', 'Peppers, sweet, red, raw', 'خضار', 26.0, 1.0, 6.0, 0.3, 120.0, 'حبة', 'usda', '170108', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'خضار', 2.1, '{"iron": 0.43, "zinc": 0.25, "vit_a": 157, "vit_c": 127.7, "vit_d": 0, "vit_e": 1.58, "vit_k": 4.9, "folate": 46, "vit_b6": 0.291, "calcium": 7, "vit_b12": 0, "magnesium": 12, "potassium": 211}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('e299b5e2-2135-434a-957b-b9b792f5c3d9', 'بصل', 'Onions, raw', 'خضار', 40.0, 1.1, 9.3, 0.1, 110.0, 'حبة وسط', 'usda', '170000', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'خضار', 1.7, '{"iron": 0.21, "zinc": 0.17, "vit_a": 0, "vit_c": 7.4, "vit_d": 0, "vit_e": 0.02, "vit_k": 0.4, "folate": 19, "vit_b6": 0.12, "calcium": 23, "vit_b12": 0, "magnesium": 10, "potassium": 146}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f267070b-291f-48bb-88b6-bb6292e79b5b', 'فطر (مشروم)', 'Mushrooms, white, raw', 'خضار', 22.0, 3.1, 3.3, 0.3, 70.0, 'كوب', 'usda', '169251', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'خضار', 1.0, '{"iron": 0.5, "zinc": 0.52, "vit_a": 0, "vit_c": 2.1, "vit_d": 0.2, "vit_e": 0.01, "vit_k": 0, "folate": 17, "vit_b6": 0.104, "calcium": 3, "vit_b12": 0.04, "magnesium": 9, "potassium": 318}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('6028d946-889b-45b0-a388-e3f708021203', 'كوسا مطبوخة', 'Squash, summer, zucchini, includes skin, cooked, boiled, drained, without salt', 'خضار', 15.0, 1.1, 2.7, 0.4, 180.0, NULL, 'usda', '169292', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'خضار', 1.0, '{"iron": 0.37, "zinc": 0.33, "vit_a": 56, "vit_c": 12.9, "vit_d": 0, "vit_e": 0.12, "vit_k": 4.2, "folate": 28, "vit_b6": 0.08, "calcium": 18, "vit_b12": 0, "magnesium": 19, "potassium": 264}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('c2c40713-9c10-4d0b-ba88-7fc3fbf0a11a', 'باذنجان مطبوخ', 'Eggplant, cooked, boiled, drained, without salt', 'خضار', 35.0, 0.8, 8.7, 0.2, 100.0, NULL, 'usda', '169229', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'خضار', 2.5, '{"iron": 0.25, "zinc": 0.12, "vit_a": 2, "vit_c": 1.3, "vit_d": 0, "vit_e": 0.41, "vit_k": 2.9, "folate": 14, "vit_b6": 0.086, "calcium": 6, "vit_b12": 0, "magnesium": 11, "potassium": 123}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('35559993-296b-4803-8f88-eb902cde6c19', 'ذرة حلوة مطبوخة', 'Corn, sweet, yellow, cooked, boiled, drained, without salt', 'خضار', 96.0, 3.4, 21.0, 1.5, 150.0, NULL, 'usda', '169999', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'خضار نشوية', 2.4, '{"iron": 0.45, "zinc": 0.62, "vit_a": 13, "vit_c": 5.5, "vit_d": 0, "vit_e": 0.09, "vit_k": 0.4, "folate": 23, "vit_b6": 0.139, "calcium": 3, "vit_b12": 0, "magnesium": 26, "potassium": 218}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d9586a5c-b187-4613-91bf-607e594a3196', 'أفوكادو', 'Avocados, raw, all commercial varieties', 'دهون ومكسرات', 160.0, 2.0, 8.5, 14.7, 50.0, 'ثلث حبة', 'usda', '171705', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'فواكه', 6.7, '{"iron": 0.55, "zinc": 0.64, "vit_a": 7, "vit_c": 10, "vit_d": 0, "vit_e": 2.07, "vit_k": 21, "folate": 81, "vit_b6": 0.257, "calcium": 12, "vit_b12": 0, "magnesium": 29, "potassium": 485}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f4be9e5b-e855-48ba-8082-8b15b92ece6b', 'زيت زيتون', 'Oil, olive, salad or cooking', 'دهون ومكسرات', 884.0, 0.0, 0.0, 100.0, 5.0, 'ملعقة صغيرة', 'usda', '171413', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'دهون وزيوت', 0.0, '{"iron": 0.56, "zinc": 0, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 14.35, "vit_k": 60.2, "folate": 0, "vit_b6": 0, "calcium": 1, "vit_b12": 0, "magnesium": 0, "potassium": 1}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('9d11c4ce-eafd-4fb6-aa73-86282744a636', 'زبدة', 'Butter, salted', 'دهون ومكسرات', 717.0, 0.9, 0.1, 81.1, 5.0, 'ملعقة صغيرة', 'usda', '173410', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'دهون وزيوت', 0.0, '{"iron": 0.02, "zinc": 0.09, "vit_a": 684, "vit_c": 0, "vit_d": 0, "vit_e": 2.32, "vit_k": 7, "folate": 3, "vit_b6": 0.003, "calcium": 24, "vit_b12": 0.17, "magnesium": 2, "potassium": 24}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('9265e2a6-8206-43ff-8b7b-acc6cccbecf2', 'لوز', 'Nuts, almonds', 'دهون ومكسرات', 579.0, 21.2, 21.6, 49.9, 28.0, 'حفنة', 'usda', '170567', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'مكسرات وبذور', 12.5, '{"iron": 3.71, "zinc": 3.12, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 25.63, "vit_k": 0, "folate": 44, "vit_b6": 0.137, "calcium": 269, "vit_b12": 0, "magnesium": 270, "potassium": 733}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('60c0453a-6cc1-44e6-8c5e-3a8938712cf4', 'كاجو', 'Nuts, cashew nuts, raw', 'دهون ومكسرات', 553.0, 18.2, 30.2, 43.9, 28.0, 'حفنة', 'usda', '170162', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'مكسرات وبذور', 3.3, '{"iron": 6.68, "zinc": 5.78, "vit_a": 0, "vit_c": 0.5, "vit_d": 0, "vit_e": 0.9, "vit_k": 34.1, "folate": 25, "vit_b6": 0.417, "calcium": 37, "vit_b12": 0, "magnesium": 292, "potassium": 660}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('88e85ed9-80d8-490a-b408-7af28ed9a202', 'فستق حلبي', 'Nuts, pistachio nuts, raw', 'دهون ومكسرات', 560.0, 20.2, 27.2, 45.3, 28.0, 'حفنة', 'usda', '170184', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'مكسرات وبذور', 10.6, '{"iron": 3.92, "zinc": 2.2, "vit_a": 26, "vit_c": 5.6, "vit_d": 0, "vit_e": 2.86, "folate": 51, "vit_b6": 1.7, "calcium": 105, "vit_b12": 0, "magnesium": 121, "potassium": 1025}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('99130b94-a634-45bc-9a0b-b118560db285', 'جوز (عين الجمل)', 'Nuts, walnuts, english', 'دهون ومكسرات', 654.0, 15.2, 13.7, 65.2, 28.0, 'حفنة', 'usda', '170187', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'مكسرات وبذور', 6.7, '{"iron": 2.91, "zinc": 3.09, "vit_a": 1, "vit_c": 1.3, "vit_d": 0, "vit_e": 0.7, "vit_k": 2.7, "folate": 98, "vit_b6": 0.537, "calcium": 98, "vit_b12": 0, "magnesium": 158, "potassium": 441}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('23931615-45aa-48e1-85be-4fc8d155c206', 'زبدة فول سوداني', 'Peanut butter, smooth style, without salt', 'دهون ومكسرات', 598.0, 22.2, 22.3, 51.4, 16.0, 'ملعقة كبيرة', 'usda', '172470', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'مكسرات وبذور', 5.0, '{"iron": 1.74, "zinc": 2.51, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 9.1, "vit_k": 0.3, "folate": 87, "vit_b6": 0.441, "calcium": 49, "vit_b12": 0, "magnesium": 168, "potassium": 558}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('afba29aa-cb18-4020-95b9-1cc8117e0b3b', 'فول سوداني', 'Peanuts, all types, raw', 'دهون ومكسرات', 567.0, 25.8, 16.1, 49.2, 28.0, 'حفنة', 'usda', '172430', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'مكسرات وبذور', 8.5, '{"iron": 4.58, "zinc": 3.27, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 8.33, "vit_k": 0, "folate": 240, "vit_b6": 0.348, "calcium": 92, "vit_b12": 0, "magnesium": 168, "potassium": 705}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('4136df1d-f976-4653-964d-4ec2f1032f9f', 'طحينة', 'Seeds, sesame butter, tahini, from roasted and toasted kernels (most common type)', 'دهون ومكسرات', 595.0, 17.0, 21.2, 53.8, 15.0, 'ملعقة كبيرة', 'usda', '170189', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'مكسرات وبذور', 9.3, '{"iron": 8.95, "zinc": 4.62, "vit_a": 3, "vit_c": 0, "vit_d": 0, "vit_e": 0.25, "vit_k": 0, "folate": 98, "vit_b6": 0.149, "calcium": 426, "vit_b12": 0, "magnesium": 95, "potassium": 414}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('778f4a3d-c58d-4035-bd54-e59a2124689f', 'بذور الشيا', 'Seeds, chia seeds, dried', 'دهون ومكسرات', 486.0, 16.5, 42.1, 30.7, 12.0, 'ملعقة كبيرة', 'usda', '170554', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'مكسرات وبذور', 34.4, '{"iron": 7.72, "zinc": 4.58, "vit_c": 1.6, "vit_e": 0.5, "calcium": 631, "vit_b12": 0, "magnesium": 335, "potassium": 407}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('66d19762-5261-4e6d-8af5-419eb669f9bf', 'عسل', 'Honey', 'حلويات ومشروبات', 304.0, 0.3, 82.4, 0.0, 21.0, 'ملعقة كبيرة', 'usda', '169640', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'حلويات ومحليات', 0.2, '{"iron": 0.42, "zinc": 0.22, "vit_a": 0, "vit_c": 0.5, "vit_d": 0, "vit_e": 0, "vit_k": 0, "folate": 2, "vit_b6": 0.024, "calcium": 6, "vit_b12": 0, "magnesium": 2, "potassium": 52}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('831ff768-1d49-4a70-8d31-4dd0095b0472', 'سكر أبيض', 'Sugars, granulated', 'حلويات ومشروبات', 387.0, 0.0, 100.0, 0.0, 4.0, 'ملعقة صغيرة', 'usda', '169655', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'حلويات ومحليات', 0.0, '{"iron": 0.05, "zinc": 0.01, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0, "vit_k": 0, "folate": 0, "vit_b6": 0, "calcium": 1, "vit_b12": 0, "magnesium": 0, "potassium": 2}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('39da9f2c-9868-4946-ad8d-cd1d7c8b87f8', 'شوكولاتة داكنة 70-85%', 'Chocolate, dark, 70-85% cacao solids', 'حلويات ومشروبات', 598.0, 7.8, 45.9, 42.6, 20.0, NULL, 'usda', '170273', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'حلويات ومحليات', 10.9, '{"iron": 11.9, "zinc": 3.31, "vit_a": 2, "vit_e": 0.59, "vit_k": 7.3, "vit_b6": 0.038, "calcium": 73, "vit_b12": 0.28, "magnesium": 228, "potassium": 715}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('6b11fa4b-2341-4e55-ab40-fbe3155d5b7f', 'عصير برتقال', 'Orange juice, raw (Includes foods for USDA''s Food Distribution Program)', 'حلويات ومشروبات', 45.0, 0.7, 10.4, 0.2, 248.0, 'كوب', 'usda', '169098', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'مشروبات', 0.2, '{"iron": 0.2, "zinc": 0.05, "vit_a": 10, "vit_c": 50, "vit_d": 0, "vit_e": 0.04, "vit_k": 0.1, "folate": 30, "vit_b6": 0.04, "calcium": 11, "vit_b12": 0, "magnesium": 11, "potassium": 200}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('2b5cc833-aa05-46e3-b215-60db54fe3c89', 'مايونيز', 'Salad dressing, mayonnaise, regular', 'صوصات', 680.0, 1.0, 0.6, 74.9, 15.0, 'ملعقة كبيرة', 'usda', '171009', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'دهون وزيوت', 0.0, '{"iron": 0.21, "zinc": 0.15, "vit_a": 16, "vit_c": 0, "vit_d": 0.2, "vit_e": 3.28, "vit_k": 163, "folate": 5, "vit_b6": 0.008, "calcium": 8, "vit_b12": 0.12, "magnesium": 1, "potassium": 20}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('6b4b0299-c91f-4009-affa-f5c744f6eec8', 'كاتشب', 'Catsup', 'صوصات', 101.0, 1.0, 27.4, 0.1, 17.0, 'ملعقة كبيرة', 'usda', '168556', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'صلصات', 0.3, '{"iron": 0.35, "zinc": 0.17, "vit_a": 26, "vit_c": 4.1, "vit_d": 0, "vit_e": 1.46, "vit_k": 3, "folate": 9, "vit_b6": 0.158, "calcium": 15, "vit_b12": 0, "magnesium": 13, "potassium": 281}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('438899c4-2dcb-4984-b066-94076133fa40', 'حليب بروتين قهوة (ندى 320 مل)', 'Nada Protein Milk Coffee 320ml', 'مشروبات بروتينية', 87.0, 9.5, 10.0, 0.1, 320.0, 'عبوة 320 مل', 'coach', 'nada.com.sa/protein-milk-320ml-coffee', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f63c0e91-15f0-4e55-9f3f-643d1c8bf6d5', 'حليب بروتين شوكولاتة (ندى 320 مل)', 'Nada Protein Chocolate Milk 320ml', 'مشروبات بروتينية', 84.0, 8.5, 12.5, 0.1, 320.0, 'عبوة 320 مل', 'coach', 'nada.com.sa/protein-chocolate-milk', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('215dcb2c-4597-4ee5-addc-8bb38348966b', 'حليب بروتين تمر (ندى 320 مل)', 'Nada Protein Dates Milk 320ml', 'مشروبات بروتينية', 108.0, 8.5, 15.0, 1.5, 320.0, 'عبوة 320 مل', 'coach', 'nada.com.sa/protein-dates-milk', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('2e1a3ea1-7f0a-411e-99f3-ffef98726c3c', 'باور ميلك قهوة (ندى 425 مل)', 'Nada Power Milk Coffee 425ml', 'مشروبات بروتينية', 87.0, 9.5, 10.0, 0.1, 425.0, 'عبوة 425 مل', 'coach', 'nada.com.sa/power-milk-425ml-coffee', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('1d909e6e-417b-4c11-bdb6-941a4e6792bf', 'باور ميلك شوكولاتة (ندى)', 'Nada Power Milk Chocolate', 'مشروبات بروتينية', 87.0, 9.5, 12.5, 0.1, NULL, NULL, 'coach', 'nada.com.sa/power-milk-chocolate', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('4d7c0d3f-8946-445d-8bca-c46a91e269ea', 'باور ميلك فانيلا (ندى)', 'Nada Power Milk Vanilla', 'مشروبات بروتينية', 87.0, 9.5, 12.5, 0.1, NULL, NULL, 'coach', 'nada.com.sa/power-milk-vanilla-mixed-fru', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('1b9e3d39-8cca-426e-95e3-0f60ed895e0f', 'حليب بروتين شوكولاتة (المراعي 400 مل)', 'Almarai Protein Milk Chocolate 400ml', 'مشروبات بروتينية', 73.0, 8.5, 9.6, 0.4, 400.0, 'عبوة 400 مل', 'coach', 'almarai.com/protein-milk-chocolate', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('576945fd-f32e-4641-93ce-464bed7c7b59', 'حليب بروتين فراولة وموز (المراعي 400 مل)', 'Almarai Protein Milk Strawberry Banana 400ml', 'مشروبات بروتينية', 71.0, 8.5, 9.2, 0.3, 400.0, 'عبوة 400 مل', 'coach', 'almarai.com/protein-milk-strawberry-bana', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('880baa5d-8d51-4607-9e74-57d1db7b4633', 'حليب بروتين فانيلا (المراعي 400 مل)', 'Almarai Protein Milk Vanilla 400ml', 'مشروبات بروتينية', 72.0, 8.5, 9.4, 0.3, 400.0, 'عبوة 400 مل', 'coach', 'almarai.com/protein-milk-vanilla', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('329fa407-22e0-473a-a125-cf51b00b5f16', 'ماسل ميلك شوكولاتة (المراعي 400 مل)', 'Almarai Muscle Milk Chocolate 400ml', 'مشروبات بروتينية', 68.0, 10.0, 6.1, 0.3, 400.0, 'عبوة 400 مل', 'coach', 'almarai.com/muscle-milk-chocolate', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('dc0ab897-ce8e-4c30-a6d3-2d008217da10', 'ماسل ميلك سادة (المراعي 400 مل)', 'Almarai Muscle Milk Plain 400ml', 'مشروبات بروتينية', 58.0, 10.0, 3.8, 0.2, 400.0, 'عبوة 400 مل', 'coach', 'almarai.com/muscle-milk-plain', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ed426d70-6fe2-4508-983c-e076c6ff40de', 'زبادي يوناني كامل الدسم فراولة (ندى 160 غ)', 'Nada Greek Yoghurt Full Fat Strawberry 160g', 'زبادي يوناني', 147.0, 7.0, 14.0, 7.0, 160.0, 'عبوة 160 غ', 'coach', 'nada.com.sa/greek-yoghurt-full-fat-straw', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('2b4f5ab9-c68b-4634-87fd-0f246f33a02f', 'زبادي يوناني كامل الدسم توت أزرق (ندى)', 'Nada Greek Yoghurt Blueberry Full Cream', 'زبادي يوناني', 147.0, 7.0, 14.0, 7.0, NULL, NULL, 'coach', 'nada.com.sa/greek-yoghurt-with-blueberry', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('25060fbd-8012-42a2-9eac-1f68291f08e9', 'زبادي يوناني ليمون ونعناع (ندى)', 'Nada Greek Yoghurt Lemon Mint', 'زبادي يوناني', 137.0, 7.0, 11.5, 7.0, NULL, NULL, 'coach', 'nada.com.sa/greek-yoghurt-with-lemon-min', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('41c10959-560d-4296-9b45-5ded949a698c', 'زبادي يوناني توت مشكل كامل الدسم (ندى)', 'Nada Greek Yoghurt Mixed Berry Full Cream', 'زبادي يوناني', 148.0, 7.0, 14.3, 7.0, NULL, NULL, 'coach', 'nada.com.sa/greek-yoghurt-with-mixed-ber', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('82a5f375-9f43-4e0d-9a23-796a678e5f62', 'زبادي يوناني سادة (ندى 160)', 'Nada Greek Yoghurt Plain', 'زبادي يوناني', 111.0, 7.0, 5.0, 7.0, 160.0, 'عبوة 160 مل', 'coach', 'nada.com.sa/greek-yoghurt-plain', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ba245f1f-0505-4f02-a214-8712377ae812', 'زبادي يوناني 0% دهون سادة (ندى 160)', 'Nada Greek Yoghurt 0% Fat Plain', 'زبادي يوناني', 63.0, 10.0, 5.0, 0.3, 160.0, 'عبوة 160 مل', 'coach', 'nada.com.sa/greek-yoghurt-0-fat-plain', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ced9493f-d6d4-4340-a4d7-6967a4361783', 'زبادي يوناني قليل الدسم سادة (ندى 160)', 'Nada Greek Yoghurt Low Fat Plain', 'زبادي يوناني', 66.0, 7.0, 5.0, 2.0, 160.0, 'عبوة 160 مل', 'coach', 'nada.com.sa/greek-yoghurt-low-fat-plain', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('58e26787-4fa4-494d-a81b-d6d9c486f9cc', 'زبادي يوناني بالعسل الطبيعي (ندى 160)', 'Nada Greek Yoghurt Natural Honey', 'زبادي يوناني', 141.0, 7.0, 12.5, 7.0, 160.0, 'عبوة 160 مل', 'coach', 'nada.com.sa/greek-yoghurt-natural-honey', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a16f5d8c-e6b6-4a99-93e1-7ecc64c40a50', 'زبادي يوناني توت أسود وتوت العليق (ندى 160)', 'Nada Greek Yoghurt Blackberry Raspberry', 'زبادي يوناني', 151.0, 7.0, 15.0, 7.0, 160.0, 'عبوة 160 مل', 'coach', 'nada.com.sa/greek-yoghurt-berry', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('df51ae4c-2e60-4a2b-9b3a-afe95d53418d', 'زبادي يوناني 0% دهون توت مشكل (ندى 160)', 'Nada Greek Yoghurt 0% Fat Mixed Berry', 'زبادي يوناني', 100.0, 10.0, 14.3, 0.3, 160.0, 'عبوة 160 مل', 'coach', 'nada.com.sa/greek-yoghurt-0-fat-mixed-be', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('01532060-569e-4c2a-8684-c944f427dd50', 'زبادي يوناني قليل الدسم توت أزرق (ندى 160)', 'Nada Greek Yoghurt Low Fat Blueberry', 'زبادي يوناني', 102.0, 7.0, 14.0, 2.0, 160.0, 'عبوة 160 مل', 'coach', 'nada.com.sa/greek-yoghurt-low-fat-bluebe', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d77f8f74-6e78-4e2a-9118-3e52c6b22265', 'زبادي يوناني 0% دهون مانجو وخوخ (ندى 160)', 'Nada Greek Yoghurt 0% Fat Mango Peach', 'زبادي يوناني', 111.0, 10.0, 17.0, 0.3, 160.0, 'عبوة 160 مل', 'coach', 'nada.com.sa/greek-yoghurt-0-fat-mango-pe', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('20be57a9-b988-4c42-a89b-79da3a19ae94', 'زبادي يوناني قليل الدسم فراولة (ندى 160)', 'Nada Greek Yoghurt Low Fat Strawberry', 'زبادي يوناني', 98.0, 6.0, 14.0, 2.0, 160.0, 'عبوة 160 مل', 'coach', 'nada.com.sa/greek-yoghurt-low-fat-strawb', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('08baf7e5-49e6-4231-ac16-9b3906985880', 'لبن زبادي طازج قليل الدسم (ندى 150 غ)', 'Nada Fresh Yoghurt Low Fat', 'زبادي يوناني', 45.0, 3.1, 5.5, 1.2, 150.0, 'عبوة 150 غ', 'coach', 'nada.com.sa/fresh-yoghurt-low-fat', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('7598150e-2835-46b0-aaa9-de95a308f46a', 'زبادي يوناني للشرب سادة (ندى 330 مل)', 'Nada Drinking Greek Yoghurt Plain', 'زبادي يوناني', 68.0, 9.1, 4.5, 1.5, 330.0, 'عبوة 330 مل', 'coach', 'nada.com.sa/drinking-greek-yoghurt-plain', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f6a7cb42-0b69-4869-96df-11a8d259c0f8', 'زبادي يوناني للشرب توت أسود وتوت العليق (ندى 330 مل)', 'Nada Drinking Greek Yoghurt Blackberry Raspberry', 'زبادي يوناني', 97.0, 8.2, 12.7, 1.5, 330.0, 'عبوة 330 مل', 'coach', 'nada.com.sa/drinking-greek-yoghurt-berry', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('7d7a63c6-d7b1-444b-b18e-7696e8ee3a47', 'زبادي يوناني للشرب مانجو (ندى 330 مل)', 'Nada Drinking Greek Yoghurt Mango', 'زبادي يوناني', 94.0, 8.2, 11.9, 1.5, 330.0, 'عبوة 330 مل', 'coach', 'nada.com.sa/drinking-greek-yoghurt-mango', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('115e10a6-66b2-4efa-b227-d2a00ffd12de', 'زبادي يوناني للشرب باشن فروت وبذور الشيا (ندى 330 مل)', 'Nada Drinking Greek Yoghurt Passion Chia', 'زبادي يوناني', 101.0, 8.2, 13.6, 1.5, 330.0, 'عبوة 330 مل', 'coach', 'nada.com.sa/drinking-greek-yoghurt-passi', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('0f234d22-2f5b-422d-83fc-5f04659b4d3c', 'زبادي يوناني للشرب فراولة وحبوب (ندى 330 مل)', 'Nada Drinking Greek Yoghurt Strawberry Cereal', 'زبادي يوناني', 94.0, 8.2, 11.9, 1.5, 330.0, 'عبوة 330 مل', 'coach', 'nada.com.sa/drinking-greek-yoghurt-straw', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('8518fc4f-a512-4a78-b6c1-baef3a616899', 'زبادي يوناني سادة (المراعي 150 غ)', 'Almarai Plain Greek Style Yoghurt 150g', 'زبادي يوناني', 139.0, 6.7, 8.7, 8.7, 150.0, 'عبوة 150 غ', 'coach', 'almarai.com/plain-greek-style-yoghurt', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('149589bb-6ee8-419b-9ee8-821ba84f8185', 'زبادي يوناني فراولة (المراعي 150 غ)', 'Almarai Strawberry Greek Style Yoghurt 150g', 'زبادي يوناني', 150.0, 6.0, 15.3, 7.3, 150.0, 'عبوة 150 غ', 'coach', 'almarai.com/strawberry-greek-style-yoghu', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('fd3e3dea-82f0-48bb-ae7d-d395fe377dd9', 'زبادي يوناني مانجو (المراعي 150 غ)', 'Almarai Mango Greek Style Yoghurt 150g', 'زبادي يوناني', 150.0, 5.9, 15.3, 7.2, 150.0, 'عبوة 150 غ', 'coach', 'almarai.com/mango-greek-style-yoghurt', true, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;



INSERT INTO public.policies VALUES ('terms', 'الشروط والأحكام', '- يبدأ الاشتراك بعد التحقق من وصول التحويل البنكي، وتعبئة استبيان المتدرب.
- ساعات العمل: الأحد – الخميس، 12 ظهراً – 9 مساءً. الرد على الرسائل خلال 48 ساعة عمل.
- البرنامج لا يغني عن الاستشارة الطبية، والمتدرب مسؤول عن الإفصاح عن أي إصابة أو حالة صحية.
- الجداول ملك المتدرب مدى الحياة ويمكنه التعديل عليها.
- الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي.', 0, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;
INSERT INTO public.policies VALUES ('refund', 'الضمان والاسترجاع', '- في اشتراكات 3 أشهر لباقات المتابعة (المكثفة، المتقدمة، الأساسية): يُسترد المبلغ كاملاً إذا لم يتحسن أي من مؤشرات التقدم (متوسط الوزن الأسبوعي، محيط الخصر، القوة في التمارين الأساسية) بعد 12 أسبوعاً.
- شروط الضمان: إرسال المراجعة الأسبوعية كل أسبوع، وأخذ القياسات بانتظام، وتصوير التمارين وإرسالها، والالتزام بجدول التغذية المخصص في الباقات التي تشملها.
- يُطلب الاسترجاع عبر واتساب خلال 14 يوماً من نهاية الأشهر الثلاثة، ويُرجع المبلغ بتحويل بنكي.
- التجديد المجاني: اشتراك 3 أشهر يُكافأ بـ 3 أشهر إضافية عند التزام 90% فأكثر وتقدم واضح في مؤشرات التقدم. صور التطور تُرسل للمدربة للتوثيق (للرجال مع تغطية الوجه والسرة)، ونشرها اختياري.', 1, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;
INSERT INTO public.policies VALUES ('privacy', 'سياسة الخصوصية', '- نجمع: الاسم، البريد الإلكتروني (للدخول إلى حسابك)، رقم الجوال (واتساب)، الباقة المختارة، ومعلومات الاستبيان التي تكتبها بنفسك (ومنها معلومات صحية وقياسات اختيارية).
- الغرض: تنفيذ طلبك، وتصميم برنامجك ومتابعتك، والتواصل معك بخصوصه فقط.
- المعلومات الصحية تُحفظ منفصلة، ولا يطّلع عليها إلا أنت والمدربة، ولا تُرسل في رسائل البريد أو التنبيهات.
- الدفع بتحويل بنكي مباشر لحساب المؤسسة، والموقع لا يطلب أو يخزن أي بيانات بنكية أو بيانات بطاقات. إيصال التحويل يُستخدم لتأكيد طلبك فقط، ويُحفظ في تخزين خاص لا يُفتح إلا لك وللمدربة.
- لا نبيع بياناتك ولا نشاركها مع أي طرف لأغراض تسويقية، ولا تُنشر نتيجتك أو صورتك إلا بموافقتك الصريحة.
- تقدر تطلب نسخة من بياناتك أو حذفها أو سحب موافقتك على النشر بمراسلتنا على واتساب.
- القياس والتحليلات: نستخدم Google Analytics لقياس زيارات صفحات الموقع العامة وتحسين تجربتك، وذلك فقط بعد موافقتك على الشريط الذي يظهر عند أول زيارة، وتقدر ترفض فلا نقيس زيارتك. لا نفعّل القياس داخل حسابك أو صفحات الطلب والدفع والبرامج، ولا نربطه ببياناتك الصحية أو الشخصية، ولا نستخدمه للإعلانات. تُعالَج بيانات القياس لدى Google، وهي مجهولة الهوية في غالبها (عنوان IP يُقنَّع، وبدون ميزات الإعلانات المخصصة). تقدر تسحب موافقتك بمسح بيانات الموقع من متصفحك، فيظهر لك الشريط مرة ثانية.', 2, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;
INSERT INTO public.policies VALUES ('reviews', 'سياسة التقييمات', '- يكتب التقييم فقط من اشترى خدمة وبدأها فعلاً، وتقييم واحد لكل طلب.
- كل تقييم يُراجع قبل ظهوره للعامة، ولا يُعدّل نصه أبداً.
- تختار بنفسك طريقة ظهور اسمك: الاسم كامل، أو الاسم الأول فقط، أو بدون اسم. والموافقة على النشر منفصلة واختيارية.
- لا يُنشر تقييم يحتوي أرقام هواتف أو بريد أو روابط أو تفاصيل صحية خاصة أو إساءة لأي شخص.
- يحق للمدربة الرد على التقييم، أو إخفاء التقييم المخالف لهذه السياسة مع تسجيل السبب.
- تقدر تطلب إخفاء تقييمك في أي وقت بمراسلتنا على واتساب.', 3, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;



INSERT INTO public.products VALUES ('b66366d6-1398-4a99-aaca-39c28526f35f', 'intensive', 'follow', 'الباقة المكثفة', 'الأنسب للمبتدئين ولمن يحتاج متابعة أسبوعية مع زوم: تمرين + تغذية + زوم + جلسة حضورية', '[{"text": "جلسة حضورية مجانية لمدة ساعة لتصحيح التكنيك والتأكد من جودة التمرين (للبنات في المنطقة الشرقية)", "included": true}, {"text": "ملف شامل للخطة التدريبية والتغذية مع شروحات وافية للتمارين، بالمنزل أو بالنادي", "included": true}, {"text": "4 مكالمات زوم شهرياً نتابع فيها تطورك واستفساراتك الرياضية والنفسية", "included": true}, {"text": "مناقشة أسبوعية لتطورك البدني والنفسي (فيديو أو تسجيل صوتي) مع تعديل السعرات أو التمرين عند الحاجة", "included": true}, {"text": "شرح سهل ومبسط لتطبيق حساب السعرات MyFitnessPal", "included": true}, {"text": "كتيب شامل للرياضة والتغذية", "included": true}, {"text": "مساعدتك على اختيارات أنسب لصحتك ونمط حياتك في التغذية والروتين اليومي", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}]', NULL, 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.', true, NULL, 'published', 0, false, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('629e7ae0-d8ae-4166-a2af-2a733893f48c', 'advanced', 'follow', 'الباقة المتقدمة', 'لمن عنده خبرة ويحتاج تمرين + تغذية مع متابعة أسبوعية، بدون زوم', '[{"text": "ملف شامل للخطة التدريبية والتغذية مع شروحات وافية للتمارين، بالمنزل أو بالنادي", "included": true}, {"text": "مناقشة أسبوعية لتطورك البدني والنفسي (فيديو أو تسجيل صوتي) مع تعديل السعرات أو التمرين عند الحاجة", "included": true}, {"text": "كتيب شامل للرياضة والتغذية", "included": true}, {"text": "مساعدتك على اختيارات أنسب لصحتك ونمط حياتك في التمرين والروتين اليومي", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}, {"text": "مكالمات زوم والجلسة الحضورية (في المكثفة فقط)", "included": false}]', NULL, 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.', false, NULL, 'published', 1, false, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('6390b03e-8903-44d5-a5e7-e55f6bce602a', 'basic', 'follow', 'الباقة الأساسية', 'لمن يعرف يضبط أكله ويحتاج خطة تمرين فقط، ومتابعة كل أسبوعين', '[{"text": "ملف شامل للخطة التدريبية مع شروحات وافية للتمارين، بالمنزل أو بالنادي", "included": true}, {"text": "مناقشة كل أسبوعين لتطورك البدني والنفسي (فيديو أو تسجيل صوتي) مع تعديل التمرين عند الحاجة", "included": true}, {"text": "كتيب شامل للرياضة والتغذية", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}, {"text": "بدون خطة تغذية", "included": false}]', NULL, 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.', false, NULL, 'published', 2, false, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('80249df4-bcd5-48d3-a42a-35058243a148', 'nutrition', 'follow', 'باقة التغذية', 'لمن يحتاج خطة تغذية شاملة ويتعلم حساب السعرات، بدون خطة تمرين', '[{"text": "خطة تغذية شاملة تناسب هدفك ونمط حياتك", "included": true}, {"text": "تحديد السعرات المناسبة لك ولهدفك", "included": true}, {"text": "تعليمك حسبة السعرات ومساعدتك باختيارات تغذية تناسبك", "included": true}, {"text": "ملف Excel لمتابعة التطور والقياسات", "included": true}, {"text": "مناقشة أسبوعية لعلاقتك بالتغذية في المنزل أو خارجه", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}, {"text": "لا تحتاجها إذا كنت مشتركاً في المكثفة أو المتقدمة، لأن التغذية ضمنها", "included": false}]', 'شهر واحد · غالباً لا تحتاج تجديد', 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي، ولا يوجد تجديد تلقائي. ضمان الاسترجاع يشمل اشتراكات 3 أشهر للمكثفة والمتقدمة والأساسية فقط.', false, NULL, 'published', 3, false, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('b180d667-9e0b-4803-9113-72bd80b8bad1', 'custom-training-plan', 'files', 'بديل التدريب الشخصي', 'لمن لا يحتاج متابعة (متقدم)، أو كبديل أوفر للتدريب الشخصي', '[{"text": "جدول تمرين مخصص لعدد أيام التمرين اللي تحتاجها", "included": true}, {"text": "طريقة حساب الجهد وعدد الجولات المطلوبة", "included": true}, {"text": "تقدر تحمّل الجدول على جهازك", "included": true}]', NULL, 'جدول مخصص بعد الاستبيان تستلمه كملف، وتقدر تحمّله على جهازك. بدون متابعة.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي. الجداول لك مدى الحياة وتقدر تعدّل عليها.', false, NULL, 'published', 4, false, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('6ee9517b-5031-4e5c-9a37-589ca8d030e6', 'training-nutrition-plan', 'files', 'جدول تمارين مع التغذية', 'لمن لا يحتاج متابعة (متقدم)، أو كبديل أوفر للتدريب الشخصي', '[{"text": "جدول تمرين مخصص لعدد أيام التمرين اللي تحتاجها", "included": true}, {"text": "طريقة حساب الجهد وعدد الجولات المطلوبة", "included": true}, {"text": "جدول تغذية فيه خيارات تناسب هدفك الرياضي", "included": true}, {"text": "تقدر تحمّل الجدول على جهازك", "included": true}]', NULL, 'جدول مخصص بعد الاستبيان تستلمه كملف، وتقدر تحمّله على جهازك. بدون متابعة.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي. الجداول لك مدى الحياة وتقدر تعدّل عليها.', false, NULL, 'published', 5, false, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('2386b6cd-f851-424f-942f-1bb326d29258', 'nutrition-consultation', 'consult', 'جلسة استشارة تغذية', 'لمن عنده أسئلة محددة في التغذية: جلسة وحدة تكفي لحسبة سعراتك ونصائح الأكل.', '[{"text": "مناقشة كل أسئلتك في مجال التغذية", "included": true}, {"text": "حسبة سعرات مناسبة لهدفك مع اقتراحات لأصناف الطعام", "included": true}, {"text": "نصائح في المكملات، وكيف تأكل برّا بطريقة صحيحة", "included": true}]', NULL, 'جلسة عبر Google Meet أو واتساب — المناسب لك.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي.', false, NULL, 'published', 6, false, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('1ca7cf34-17d5-434a-9f82-ee8e31dadac8', 'training-consultation', 'consult', 'جلسة استشارة تمرين', 'لمن عنده أسئلة محددة في التمرين: جلسة وحدة تكفي لتعديل جدولك وتصحيح التكنيك.', '[{"text": "مناقشة كل أسئلتك في مجال التمرين", "included": true}, {"text": "تعديل جدولك الرياضي بما يناسب هدفك، مع اقتراحات لتمارين المرونة", "included": true}, {"text": "تصحيح تكنيك التمارين اللي تشك إنها غلط أو تسبب لك ألم", "included": true}, {"text": "التأكد من أن جودة تمرينك مناسبة للبناء العضلي", "included": true}]', NULL, 'جلسة عبر Google Meet أو واتساب — المناسب لك.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي.', false, NULL, 'published', 7, false, '2026-10-04 16:29:10.915054+00', '2026-10-04 16:29:10.915054+00', false) ON CONFLICT DO NOTHING;



INSERT INTO public.product_offers VALUES ('c7338f6f-0455-471b-97c0-05af30f99196', 'b66366d6-1398-4a99-aaca-39c28526f35f', 'int1', 'شهر واحد', 1, 59900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('dd33a150-0937-4220-8a1a-ddec90028bc1', 'b66366d6-1398-4a99-aaca-39c28526f35f', 'int3', '3 أشهر', 3, 155000, 'SAR', true, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('1ab0b0b5-3dfe-4cb2-8821-59d43527777a', '629e7ae0-d8ae-4166-a2af-2a733893f48c', 'adv1', 'شهر واحد', 1, 49900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('4c9c09a5-315b-4f8e-af61-e75e89b2d6e4', '629e7ae0-d8ae-4166-a2af-2a733893f48c', 'adv3', '3 أشهر', 3, 125000, 'SAR', true, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('f11772e9-3524-48e6-97de-1a5615087bf1', '6390b03e-8903-44d5-a5e7-e55f6bce602a', 'bas1', 'شهر واحد', 1, 34900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('81af1255-5922-4a85-a9ec-04e14e06b22a', '6390b03e-8903-44d5-a5e7-e55f6bce602a', 'bas3', '3 أشهر', 3, 95000, 'SAR', true, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('b624f53c-6ab9-4146-b613-49daa4b876be', '80249df4-bcd5-48d3-a42a-35058243a148', 'nut1', 'شهر واحد', 1, 25000, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('b083c2e9-97a2-49b3-9af0-2f32923775f2', 'b180d667-9e0b-4803-9113-72bd80b8bad1', 'diy', 'دفعة واحدة', 0, 19900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('57332344-50e0-403b-b8ea-fb1b233ae160', '6ee9517b-5031-4e5c-9a37-589ca8d030e6', 'diyN', 'دفعة واحدة', 0, 25000, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('513b9090-bdfc-425b-95e4-0581a4f14e9a', '2386b6cd-f851-424f-942f-1bb326d29258', 'cN', 'دفعة واحدة', 0, 15000, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('2df67d14-e531-4eab-8358-e43844c81788', '1ca7cf34-17d5-434a-9f82-ee8e31dadac8', 'cT', 'دفعة واحدة', 0, 18900, 'SAR', true, 0) ON CONFLICT DO NOTHING;



INSERT INTO public.reviews VALUES ('17dd2707-1390-4738-b003-1807be3600e5', 'legacy', NULL, NULL, NULL, NULL, 'اشتركت معها 3 شهور وكانت أول مره التزم بالتمرين بعد سحبات سنين، اسلوبها سهل وسريع بس نتايجه واضحه من اول اسبوعين قياسات جسمي بدت تتغير والكوتش مريحه نفسيًا وشاطرة الله يعطيها العافيه غيرت حياتي واعطتني افضل بداية 🙏🏻', 'first', 'ريم', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 0, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('ecb69b5d-517d-4eff-adab-6435612e31c9', 'legacy', NULL, NULL, NULL, 5, 'من أصدق التجارب اللي مرّيت فيها! تدريبك ما كان بس جداول رياضه وتغذية كان دعم نفسي وتحفيز وتغيير حقيقي في حياتي حسّيت بفرق كبير في جسمي وطاقتي وثقتي بنفسي من أول أسبوع شكراً من القلب على تعبك وحرصك على كل تفصيلة وتعطي من قلبك، فعلاً you are the best coach ever تستاهلين كل النجاح والله ❤️', 'first', 'نورة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 1, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('b2d0eba0-2507-4a9a-9d5b-fb22a8e5c8ff', 'legacy', NULL, NULL, NULL, 5, 'بعد شهر من الالتزام بالجدول، لاحظت فرق واضح! متنوع وفعال، أنصح فيه بشدة 😍👌', 'first', 'البندري', 'مارس 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 2, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('ac838ab7-9d8a-49e2-9c5c-cb742a55bc9e', 'legacy', NULL, NULL, NULL, NULL, 'رغم ان فتره تدريبي معاها كانت اقل من شهرين السنه الماضيه الا ان نتايج هالشهرين مستمره معي الى اليوم 😍 اسلوب احترافي وفعال وتركز على بناء وتطوير عادات تدوم مو بس تمارين مؤقته 👍🏻', 'first', 'خديجة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 3, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('3d5c2666-fc61-4b79-a824-eda2280b5769', 'legacy', NULL, NULL, NULL, 5, 'كوتش ساره جداً شاطره و بروفيشنال، جداً متعاونه و تعرف شغلها كويس، جداً لطيفه، كنت لفتره متدربه عندها و كنت أشوف نتايج بطله بالاضافه لكوني اروح اتمرن و أنا مستمتعه، شكراً ساره', 'first', 'نجمة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 4, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('53cb5a86-0e8a-412e-83d3-ec163c58c664', 'legacy', NULL, NULL, NULL, 5, 'ممتاز جدول حلو ومرتب جدا وفرق معي كثير 🤍', 'first', 'سعود', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 5, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('51c33b1e-858f-417a-811d-4f4868c2de1f', 'legacy', NULL, NULL, NULL, 5, 'كنت اعاني من الم بظهري مستمررر سنوات وانحراف بالعمود ولكن بفضل الله ثم المدربة تحسنت بنسبة كبيرة وتابع معي خطوة بخطوة بكل أمانة وإتقان الله يكثر من امثالك 🤍', 'first', 'ش**س**', 'أغسطس 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 6, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('544c133a-f4a5-4568-8b45-dfb52edf34d0', 'legacy', NULL, NULL, NULL, 5, 'الشكر يعجز عنك يااروع كوتش باشتراكي معك شفت صحة وراحة بعد الله وساعدتيني مره بمشكلة ظهري وضعف العضلات العلوية وانعكس على نفسيتي وادائي اليومي شكررا شكرا من القلب وياحظنا فيك', 'first', 'فاطمة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 7, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('2923111d-f981-4ac9-bfdf-11278551e260', 'legacy', NULL, NULL, NULL, 5, 'مره استفدت بالتدريب مع كوتش ناف و مبسوطه ان في احد بذمة و ضمير جالس يتابع تقدمي و ينصحني من قلب الله يسعدك ويوفقك ❤️', 'first', 'ميثاء', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 8, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('13ef6e55-baee-4d69-b159-8bf57dfa6427', 'legacy', NULL, NULL, NULL, 5, 'تجربه ولا أروع ! أحب جداولها وقد ايش تختصر وتعطيك المهم والاهم والنتايج رهيييبه ❤️', 'first', 'أمجاد', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 9, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('9dba9d06-bd46-46d3-af68-e52b3e5f9b86', 'legacy', NULL, NULL, NULL, 5, 'افضل مدربة بالمجرة، كنت دبه ونحفت بثلاث شهور بس، i highly recommend her she is the best 💗', 'first', 'شروق', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 10, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('96071c74-42d9-42a0-a915-9e1234e415b6', 'legacy', NULL, NULL, NULL, 5, 'الجدول ممتاز و فعّال لفترة الصيام، يساعدك تنظم وقتك ويقدّم توصيات غذائيه و خطه تمارين تساعدك تحافظ على لياقتك بدون إرهاق 👍🏻. خيار ممتاز خاصة للأشخاص للي وقتها محدود ومزحوم فرمضان.', 'first', 'خديجة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 11, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;



INSERT INTO public.site_settings VALUES ('reminders', '{"review_text": "مرحباً {name}، تذكير بمراجعتك الأسبوعية: المراجعة مفتوحة من {window_start} إلى {window_end}.", "sub_expiry_days": [7, 3], "sub_expiry_text": "مرحباً {name}، اشتراكك في {product} ينتهي بتاريخ {end_date}. للتجديد أو الاستفسار تواصل معنا.", "review_lead_days": 1, "missed_review_text": "مرحباً {name}، ما وصلتنا مراجعة الأسبوع المنتهي في {window_end}. متى ما تيسّر لك، حدّثها عشان نتابع تقدمك.", "review_window_days": 2, "manual_cooldown_minutes": 10}', false, NULL, '2026-10-04 16:29:10.187799+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('hero', '{"lead": "خطة تدريب وغذاء منظمة، متابعة للتقدم، وتعديلات أسبوعية تناسب مستواك وظروفك.", "title": "برامج تدريب وتغذية مخصصة لأهدافك", "eyebrow": "Nav Coaching · الكوتش ساره", "tagline": "Where Passion Meets Quality", "title_tail": "تحت إشراف مدربة يدفعها الشغف"}', true, NULL, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('badges', '["خصم 10% للطلاب", "مجاني لأهل غزة", "ضمان استرجاع المبلغ بشروط"]', true, NULL, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('why', '[{"body": "البرنامج يُصمم بعد استبيان مفصل لهدفك وأيامك المتاحة وأدواتك وأي إصابة تحتاج مراعاة.", "title": "مبني على هدفك ومستواك"}, {"body": "مراجعة منتظمة بالفيديو أو الصوت، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.", "title": "متابعة أسبوعية واضحة"}, {"body": "نعدّل التمرين والسعرات بناءً على قياساتك والتزامك، عشان تثبت النتيجة.", "title": "تعديلات حسب تقدمك"}]', true, NULL, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('how_steps', '[{"body": "اختر الباقة والمدة، وعبّي استبيان قصير عن هدفك ومستواك وأيامك وأي إصابة.", "title": "اختر برنامجك وعبّي الاستبيان"}, {"body": "بعد الاستبيان يظهر لك رقم طلبك وبيانات الحساب. حوّل وارفع صورة الإيصال من صفحة طلبك.", "title": "حوّل المبلغ"}, {"body": "بعد التحقق من التحويل أتواصل معك خلال 48 ساعة عمل، وتستلم ملف برنامجك وتبدأ المتابعة.", "title": "استلم برنامجك وابدأ"}]', true, NULL, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('about', '{"bio": "مدربة شخصية معتمدة، أدرب منذ 2017. أساعدك تبني روتين تدريب وتغذية واضح يناسب هدفك ووقتك ومستواك، مع متابعة أسبوعية تساعدك تستمر وتتقدم.", "fit": ["اللي يؤمن إن التمرين أسلوب حياة، مو تمرين لشكل مؤقت أو لفترة الصيف بس.", "**وإذا ما التزمت؟** أحاول أفهم أسبابك، وأساعدك تعالجها بقدر ما أقدر. وإذا كان الموضوع أكبر من اللي أقدر أقدمه، أقول لك بصراحة وأعتذر عن تدريبك."], "name": "الكوتش ساره | ناڤ", "certs": ["Saudi Reps — Level 4", "NCSF", "Menno Henselmans CPT", "Functional Mobility", "Pre & Postnatal Training", "Prenatal Fitness Training — Aspire Academy", "ماجستير تدريب رياضي — جامعة ستيرلنق"], "notes": [{"body": "لأني جاية من عالم الرياضات الإلكترونية، صممت باقة خاصة للقيمرز: لياقة أفضل داخل وخارج الشاشة، والتعامل مع آلام الظهر والمفاصل من الجلوس الطويل.", "href": "/programs/gamers", "label": "شوف باقة القيمرز ←", "title": "للاعبي الألعاب الإلكترونية"}, {"body": "تدريب الحوامل عندي حضوري فقط. أونلاين يصعب أتأكد إن التمرين يتنفذ بإتقان، والحمل فترة مهمة جداً تحتاج هالتأكد. أونلاين أقدم للحوامل متابعة التغذية فقط.", "href": "", "label": "", "title": "للحوامل"}], "story": ["قبل ما أصير مدربة، كنت متدربة تعبت من التجارب. اشتركت مع مدربات أجانب، وما لقيت أحد يشرح لي التمرين صح أو يهتم بأهدافي.", "لين اشتركت مع الكوتش سحر الحارثي. غيّرت نظرتي للتمرين، وحفّزتني أصير كوتش، وإلى اليوم أشكرها على كل اللي علمتني إياه. من هنا قررت أكون الشخص اللي احتجته أنا.", "والرياضة جزء مني من بدري: لعبت كرة السلة وكنت كابتن فريق السلة في جامعة الإمام عبدالرحمن بن فيصل، ولعبت باحتراف في الرياضات الإلكترونية. بدأت التدريب في 2017 مع كرة السلة، واشتغلت مساعد مدرب في نادي الجامعة، وبعدها دربت في بيور جم وجمنيشن وفتنس لاونج ونوادي خاصة."], "points": ["برنامج مبني على هدفك ومستواك.", "متابعة أسبوعية واضحة.", "تعديلات مستمرة حسب تقدمك والتزامك."], "pillars": [{"body": "ما أرسل لك جدول وأتركك. أراجعه معك بمقطع فيديو أشرح فيه كل شي، عشان تبدأ وأنت فاهم وش تسوي وليش.", "title": "جدولك مشروح بالفيديو"}, {"body": "ما أمشي على أنظمة الحرمان أبداً. خطتك تناسب حياتك، مو قائمة ممنوعات.", "title": "بدون حرمان"}, {"body": "أتابعك كل أسبوع وأهتم بالتزامك، وأعدّل خطتك حسب تقدمك وظروفك.", "title": "متابعة جادة وخطة واقعية"}, {"body": "حب تعليم الناس معي من الصغر. اللي أعرفه ما أبخل فيه، علمياً ونفسياً، وما أوقف عن البحث والتعلم عشان أتطور وأطورك معي.", "title": "أعلّمك، مو بس أدربك"}], "home_bio": "مدربة شخصية معتمدة، أدرب منذ 2017، وكابتن سابقة لفريق السلة في جامعة الإمام عبدالرحمن بن فيصل. أساعدك تبني روتين تدريب وتغذية واضح يناسب هدفك ووقتك ومستواك، مع متابعة أسبوعية وبدون أنظمة حرمان.", "fit_title": "أكثر شخص أفرق معه", "experience": ["أدرب منذ 2017، والبداية في كرة السلة.", "مساعد مدرب في نادي الجامعة.", "مدربة في بيور جم، وجمنيشن، وفتنس لاونج، ونوادي خاصة."], "story_title": "صرت الشخص اللي كنت أحتاجه", "pillars_title": "وش يميز التدريب معي؟", "experience_title": "شهاداتي وخبرتي"}', true, NULL, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('intro_video', '{"url": "", "body": "مقطع قصير أتكلم فيه عن نفسي وخلفيتي وطريقة شغلي مع المتدربين.", "title": "تعرّف عليّ في دقيقة"}', true, NULL, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('testimonials_disclaimer', '"التجارب شخصية وتختلف النتائج من شخص لآخر حسب الالتزام والحالة، والتدريب لا يغني عن استشارة الطبيب أو أخصائي العلاج الطبيعي."', true, NULL, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('prices_note', '"الأسعار بالريال السعودي. الدفع بتحويل بنكي على حساب المؤسسة."', true, NULL, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('checkins', '{"enabled": true, "questions": [{"q": "ملاحظاتك الصحية؟ الحركة اليومية وجودة الحياة صارت أحسن؟", "topic": "الصحة العامة"}, {"q": "أداؤك في التمارين؟ في تقدم في الأوزان والأداء؟", "topic": "التمارين"}, {"q": "فرق في شكلك ومظهرك؟ إيجابي أو سلبي؟", "topic": "المظهر"}, {"q": "فرق في الملابس أو المقاسات؟ إيجابي أو سلبي؟", "topic": "الملابس"}, {"q": "النظام الغذائي — قدرت تمشي عليه؟ فيه صعوبة؟", "topic": "الغذاء"}, {"q": "تحسّ بالجوع واجد؟ إن وُجد، كم تعطيه من 5؟", "topic": "الجوع"}, {"q": "أي ملاحظات سلبية تبي تشاركها؟ (مهمة أو بسيطة — نتقبل النقد)", "topic": "ملاحظات سلبية"}, {"q": "أي إشكاليات أو ملاحظات إضافية تحتاج مساعدة فيها؟", "topic": "ملاحظات أخرى"}, {"q": "وصلت لأي أسبوع تدريبي الآن؟", "topic": "الأسبوع"}]}', true, NULL, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('contact', '{"whatsapp": "966599162724", "instagram": "https://www.instagram.com/navvcoaching/"}', true, NULL, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('response_time', '"48 ساعة عمل (الأحد – الخميس، 12 ظهراً – 9 مساءً)"', true, NULL, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('legal', '{"cr": "7050950752", "name": "مؤسسة ناف كوتشنق للتدريب الرياضي"}', true, NULL, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('bank', '{"iban": "SA1280000139608016245411", "bankName": "مصرف الراجحي", "accountName": "مؤسسة ناف كوتشنق للتدريب الرياضي"}', true, NULL, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('program_shots', '[{"h": 720, "w": 754, "alt": "لقطة من صفحة «حسابي» ببيانات مثال: شريط الالتزام، أيام تمرين الأسبوع الحالي، ملخص تغذية اليوم، وروتين المكملات", "src": "shots/my-program.webp", "title": "برنامجي", "caption": "أول ما تدخل حسابك: نسبة التزامك وأسابيعك المتتالية، أيام تمرين الأسبوع، تغذية اليوم مقابل أهدافك، وروتين المكملات."}, {"h": 960, "w": 1148, "alt": "لقطة من صفحة برنامج التمرين ببيانات مثال: أيام الأسبوع، وبطاقة كل تمرين مع المستهدف وخانات الوزن والتكرارات وRIR", "src": "shots/training-log.webp", "title": "تسجيل التمرين", "caption": "لكل تمرين المستهدف من الجولات والتكرارات وRIR، وتسجّل وزنك وتكراراتك من جوالك، ولك تبديله ببديل تختاره المدربة."}, {"h": 1020, "w": 1148, "alt": "لقطة من صفحة التغذية ببيانات مثال: ملخص اليوم مقابل الأهداف، ونموذج إضافة أكلة، وأكل اليوم حسب الوجبات", "src": "shots/nutrition-day.webp", "title": "التغذية اليومية", "caption": "أهدافك اليومية من السعرات والماكروز وكم باقي لك، وتسجّل أكلك من جداولك الغذائية أو بالغرام من قاعدة الأكل."}, {"h": 307, "w": 1116, "alt": "لقطة من لوحة التقدم ببيانات مثال: رسم الوزن ورسم القياسات", "src": "shots/progress-charts.webp", "title": "لوحة التقدم", "caption": "وزنك وقياساتك برسوم واضحة أسبوعاً بأسبوع، ببيانات مثال."}]', true, NULL, '2026-10-04 16:29:10.915054+00') ON CONFLICT DO NOTHING;
COMMIT;
