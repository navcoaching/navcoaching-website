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

-- ---------- المحتوى المستورد من الموقع الحالي ----------
INSERT INTO public.exercises VALUES ('5143aad3-d434-42c1-afdd-83479273e49e', 'Back Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/bEv6CCg2BC8', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('89fb4cb9-3889-4886-827f-c04b40dbf1d5', 'Box Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtube.com/shorts/9uhEh9gpwUU?si=xaTY7AJiCeQfa3by', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل.', 'تعليمات بديلة في المصدر (صف 13): ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل، انزل واثبت على البوكس ثانية وارفع.', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8c1bce16-452c-425c-b61c-1d73f662ea73', 'Hack Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/0tn5K9NlCfo', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Machine Squat / سكوات بالجهاز', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('59b1c89a-e9ad-4dfa-af24-70da92fa73fd', 'Mid Leg Press', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/s9-zeWzPUmA', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Leg Press / ضغط الأرجل', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1fe25d8f-b8d8-43fe-926f-d21c873edde2', 'Quads Leg Press', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/A218isnErfM', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي، ثبت القدمين أسفل اللوح لاستهداف أكبر للكوادز.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Leg Press / ضغط الأرجل', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7a070258-d712-4f17-a758-951396736f4d', 'Deficit Goblet Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/9719SO5zvpU?si=whohbunAsXkH3j6f', 'وقف باتساع اكتافك تقريبًا، ادفع ركبك للامام وانزل، انزل لأقصى حد تقدر عليه بدون ما يتقوس ظهرك السفلي.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('52235a71-4720-43bc-a7d4-2f273a957bd2', 'Front Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'بار', 'متوسط', 'نادي', NULL, 'ثبت البار على الأكتاف، ادفع ركبك للامام وانزل.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d088cfce-625d-4853-8f95-49484e87ba72', 'V Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://www.youtube.com/watch?v=u_GSjH58s0g', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Machine Squat / سكوات بالجهاز', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2ecefdf6-abbe-41f2-b487-e23c8c9794b0', 'Resistance Band Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/6rE0IYlMPZA?si=goqtRTlR_W4HSGBN', 'ثبت الباند علي جوانب اكتافك، ادفع ركبك للأمام وإنزل.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ce0eb340-b302-442c-8036-575834120894', 'Squat Smith Machine', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/oBwhrRcNWyM', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Machine Squat / سكوات بالجهاز', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7e4ab1c9-7c23-4198-b57c-f8e094d0efab', 'Single Leg Press', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/ZYDTJaAM-gE', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Single-leg Press / ضغط رجل واحدة', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a7250971-8845-4874-9ad8-64eeba12f3cc', 'Drop Lunges', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/WH8lteLrMIs?si=61QSVA7iw_Z6Zr3p', 'تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a3e4b189-0a00-4c48-873d-61e8d8b53259', 'Beginner Lunges', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/QOVaHwm-Q6U', 'تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5bc69a88-1a2e-47eb-a84e-8e2885690dbc', 'Forward Lunges', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/_DLAdo2Pvjs', 'تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness | ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('06e54867-27d9-4f18-a574-a55dc9f67735', 'Supported BSS', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/poBie3TTeGE?si=QSiMUYtcHhrmg8mx', 'وقف عند البنش او الستيب، ارفع رجلك وثبت اصابع قدمك على البنش، خذ خطوة وحدة للأمام برجلك الثانية ثم ابدأ التمرين، تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Split Squat / سبليت سكوات', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d8e737e1-2a4c-4b8b-a9c9-70dac160b8ff', 'Supported Reverse Lunge', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/WH8lteLrMIs?si=M9s9a7qOVvvyDm82', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('75927eb4-1a2e-4a79-ac39-ed3167fd34ef', 'Smith Machine Reverse Lunge', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/zAVYcwnlxrQ?si=M5HL4sG-bsYBFyDQ', 'استخدم ارتفاع بسيط مثل الستيب ، ارفع نفسك بالضغط علي الرجل المرفوعة بتحكم بدون قفز.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('969cd31e-d614-4db3-a8e5-6b172845bddc', 'Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/gtZ4AwZVtMI', 'اجلس وثبت ظهرك السفلي كويس، تأكد ان مسمار الارتفاع يكون بمستوى ركبتك، امسك المقابض لزيادة الثبات، إرفع الوزن اثبت ثانية فوق ثم انزل نزول كامل بتحكم.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a9a72847-98d8-4965-8ac4-326a709a4e40', 'Single Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/82IuSLk5zNc?si=FTMqZrmawQFRr8dN', 'اجلس وثبت ظهرك السفلي كويس، تأكد ان مسمار الارتفاع يكون بمستوى ركبتك، امسك المقابض لزيادة الثبات، إرفع الوزن اثبت ثانية فوق ثم انزل نزول كامل بتحكم.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('45a81b8a-76ce-4caf-8564-f4b89f60c99b', 'Band Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/hs7D3gDw3UM', 'اجلس وثبت ظهرك السفلي كويس وامسك الكرسي للثبات، اثبت ثانية فوق ثم انزل نزول كامل بتحكم.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('beafe0aa-17f3-45b7-9972-f1a27f2381e7', 'Standing Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/fyF6FQOUGDI', 'الحركة كلها بثني ومد الركبة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4c42bdca-ff49-4e0a-8f7b-f8e636680011', 'Sissy Squat', 'Quadriceps / الأمامية', '{"Adductors / الأفخاذ الداخلية"}', 'Knee Extension / مد الركبة', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://youtu.be/yONKTprKCDA', 'الورك ثابت طول الجولة والحركة كلها من مفصل الركبة، اذا توازنك يخرب عليك ادبل الوزن بيد واليد الثانية امسك فيها جدار او عصى', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Sissy Squat / سيسي سكوات', 'Knee Extension / مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('65a6ff6d-81c3-4dbd-9186-554bd4f5d7ea', 'Cable Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/ebjD98gZd8E', 'اجلس وثبت ظهرك السفلي كويس وامسك الكرسي للثبات، اثبت ثانية فوق ثم انزل نزول كامل بتحكم.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b5a697e8-7fc5-4e70-9bd5-574cf790b51b', 'Standing Leg Extension', 'Quadriceps / الأمامية', '{"Core / البطن والكور"}', 'Knee Extension / مد الركبة', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/133/standing-leg-extension/', NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a014cfa5-89d5-474d-a4dd-088748005c96', 'Bodyweight Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Lower back / أسفل الظهر"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/135/bodyweight-squat/', NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('58a0bb47-0f11-43e8-b851-4a5b5f6195cb', 'Single Leg Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'وزن الجسم', 'متقدم', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/136/single-leg-squat/', 'ضعف الألوية الكبرى / Gluteus Maximus Weakness | ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Single-leg Squat / سكوات رجل واحدة', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d927fb5d-f235-44d5-b24c-19c46f5e350f', 'DB Glutes Step Ups', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/GCnJiYJfboA?feature=share', 'استخدم ارتفاع يكون بحدود ارتفاع ركبتك أو أقل، ارفع نفسك بالضغط علي الرجل المرفوعة بتحكم بدون قفز.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a8769842-a16e-43c9-a83c-9cc032b51af3', 'Supported Glutes Step Ups', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/ZKzoOkQALaY?si=-56txwBlxSSCQYJd', 'استخدم ارتفاع يكون بحدود ارتفاع ركبتك أو أقل، ارفع نفسك بالضغط علي الرجل المرفوعة بتحكم بدون قفز.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b47ad698-4524-4331-8c06-e1d7cabe7512', 'Cable Glutes Step Ups', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ed39cdde-56d4-40ff-b66a-6ff27859d7d7', 'Glute Pushdown', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/8h2kZ64Sp5k?si=NLPf4tywxhDGY9em', 'تمسك بمقابض الجهاز، (كل ما زاد ارتفاع البنش زادت الصعوبة) + الطلوع والنزول يكون بواسطة القدم المرفوعة على البنش مو بالقدم اللي تحت، ارفع بتحكم الى أقصى ارتفاع تقدرعليه بدون ما يتقوس ظهرك السفلي، انزل لحد ما تقفل ركبتك تماما', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a37b9e90-9e9f-498a-8888-6a31a8288813', 'Glute Max Kickbacks', 'Glutes / المؤخرة', '{}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/t5mwSx4uNMc?feature=share', 'ثبت الحبل على الكاحل، ارجع خطوة للخلف وانحني للامام قليلاً وتمسك بالكيبل لزيادة الثبات، اسحب للخلف مع انثناء بسيط بالركب.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Kickback / ركلة خلفية', 'Hip Extension / بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('05f64402-2e76-49a0-a00d-80a1f28c47d7', 'Hip Abduction', 'Abductors / مبعدات الفخذ', '{"Glutes / المؤخرة"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/_ARUxqrII3Y?si=Jcz5uh2Uu-IdVCS1', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1ecfae64-824f-413c-9e3b-7a1238139a7a', 'Smith Machine Kickback', 'Glutes / المؤخرة', '{}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/GR4ny80bmhM?si=WeZcWM1hyfoLElM2', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Kickback / ركلة خلفية', 'Hip Extension / بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('873a4785-a2d0-46d5-822d-945d870f02cd', 'Glute Medius Kickbacks', 'Abductors / مبعدات الفخذ', '{"Glutes / المؤخرة"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/kccsnZNbMFA?si=6c-VoB8Zsz8NxoyM', 'ثبت الحبل على الكاحل، ارجع خطوة للخلف وانحني للامام قليلاً وتمسك بالكيبل لزيادة الثبات، اسحب للخلف وللخارج مع انثناء بسيط بالركب.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Abduction Kickback / ركلة خلفية مع تبعيد', 'Hip Abduction + Hip Extension / تبعيد الورك + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d45793a5-2bfc-432b-8836-138835ad8ecd', 'Side Step Up', 'Glutes / المؤخرة', '{"Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/xOwIRnI4VxA?si=SJOgODRmNGdfHPb4', 'يد فيها الوزن واليد الثانية سندها على الجدار', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية المتوسطة / Gluteus Medius Weakness | ضعف الألوية الصغرى / Gluteus Minimus Weakness', 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('45ccb254-da17-4bad-a65a-763964a967c1', 'Hip Thrusts Machine', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/0xfdeCBwoYw?si=HgJcNeB0a24gODkK', 'ممكن تسويه بالسميث مشين او البار الحر ، اختر بوكس او بنش يكون بمستوى اكتافك الخلفية وانت جالس، لما ترفع البار فوق المفروض ركبك تكون بنفس مستوى القدم.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b873b3ff-9473-4131-9421-13f6d48ddb86', 'Hip Thrusts', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/O0EoaP7gR1A?si=cGPZ8iIwM2mQjwSb', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2014bb6a-8218-4fe8-8239-3be9cfeee84b', 'Glute Bridge', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', NULL, 'مبتدئ', NULL, 'https://www.youtube.com/watch?v=dtlGynVdHYM', 'ممكن تسويه بالسميث مشين او البار الحر ، اختر بوكس او بنش يكون بمستوى اكتافك الخلفية وانت جالس، لما ترفع البار فوق المفروض ركبك تكون بنفس مستوى القدم.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness | آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('46b5f1a0-42ed-4714-9a85-d9602f8d551b', 'DB Floor Glute Bridge', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/iOrJXNUH3to?si=JySX6JMhoP2vWEVa', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness', 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4526ba11-0ff0-4275-b324-4f6010d747a2', 'Glute Raise', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/X_kL_x4m77c', 'ثبت رجولك تحت، الاسفنجة تكون تحت الورك أعلى الفخذ مو على الورك مباشرة، امسك وزن بيدينك بذراع مستقيمة، ارفع وكأنك تبي تدخل القلوتس جوا الاسفنجة، بمجرد ما تنقبض مؤخرتك وقف لا ترفع أكثر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', '45° Hip Extension / بسط الورك على جهاز الظهر', 'Hip Extension / بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e3a9ca8d-6fa3-4296-ab89-8fbf47a65f52', 'Single Hip Thrusts', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/ymg2AMDAwrY?si=fY8kBPTDYWRMHuAs', 'اختر بوكس او بنش يكون بمستوى اكتافك الخلفية وانت جالس، لما ترفع فوق المفروض ركبك تكون بنفس مستوى القدم، التمرين صعب طبيعي تواجه صعوبة بالبداية لذلك لا تستعجل باضافة الاوزان', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7eb02693-a112-4733-8cbf-dca86920ce23', 'Glute Press', 'Glutes / المؤخرة', '{}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/293/glute-press/', NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Kickback / ركلة خلفية', 'Hip Extension + Knee Extension / بسط الورك + مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fca6dcde-460a-4750-bc36-5380e37d4ce7', 'Bulgarian Split Squat', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/366/bulgarian-split-squat/', NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Split Squat / سبليت سكوات', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5c11df46-30ab-4781-ae50-9287e215ec83', 'Sumo Deadlift', 'Hamstrings / الخلفية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://www.youtube.com/watch?v=cDlOSfu-zHY', 'وقف بفتحة أرجل واسعة بحيث الركب تكون خط مستقيم مع كعب القدم و اصابع الرجل باتجاه الخارج، البار بمنتصف القدم، شد ظهرك العلوي وادفع الارض برجولك واسحب البار للأعلى، وقف لما تنقبض مؤخرتك ولا تبالغ بتقفيل حوضك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Deadlift / ديدلفت', 'Hip Extension + Knee Extension / بسط الورك + مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5f1721fb-2258-4b58-b7c9-56cc8e93dfef', 'DB Lying Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/ZHlBSI6JPsA?si=SpBiHxluwrYE8CTP', 'ركبك ثابته على الارض، ارفع الوزن بثني ومد الركبة بدون ما يرتفع حوضك', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c84b8502-6979-48d6-aa2a-9fb85f972c2b', 'Conventional Deadlift', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/GxsLrTzyGUU', 'وقف باتساع اكتافك أو أوسع شوي، البار بمنتصف القدم، شد ظهرك العلوي وادفع الارض برجولك واسحب البار للأعلى، وقف لما تنقبض مؤخرتك ولا تبالغ بتقفيل حوضك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Deadlift / ديدلفت', 'Hip Extension + Knee Extension / بسط الورك + مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e6cadfdd-e39d-4196-84bc-99ee0f295661', 'BB RDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/mZxxJEncsyw', 'وقف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، انزل وادفع مؤخرتك لآخر شي تقدر عليه للخلف وكأنك بتلمس جدار خلفك مع انثناء بسيط بالركب', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0aba228c-bea8-454a-bd69-5e55bc97ca76', 'DB RDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/RApyTtH6qAo', 'وقف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، انزل وادفع مؤخرتك لآخر شي تقدر عليه للخلف وكأنك بتلمس جدار خلفك مع انثناء بسيط بالركب', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ebefed11-d9f6-4d5f-a3de-21c8aae838a2', 'SM SLDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/qlL1wnpLQj4?si=-jD_X6mIJkkI8SwX', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5a5f10e6-db39-4a39-99e4-997988e552e5', 'Single DB RDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/U3prDlAbJDw?si=MRSBcSIcf9M-WQBH', 'وقف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، انزل وادفع مؤخرتك لآخر شي تقدر عليه للخلف وكأنك بتلمس جدار خلفك مع انثناء بسيط بالركب', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness', 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6390141c-800b-4538-9b6e-201320f62037', 'SLDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/RApyTtH6qAo', 'قف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، ابدأ الحركة بدفع مؤخرتك للخلف والأعلى وانزل', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fc0d70d2-641c-4625-9ff7-7a702ffaee3d', 'Single DB SLDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/U3prDlAbJDw?si=MRSBcSIcf9M-WQBH', 'قف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، ابدأ الحركة بدفع مؤخرتك للخلف والأعلى وانزل', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('51a069a2-640d-4513-85e5-8db55ee1682a', 'Good Morning', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/f23vXjoG2e8?si=9rkfUF_6XUEcQ3Xs', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع مؤخرتك لأقصى قدر تقدر عليه وكأنك بتلمس جدار خلفك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Good Morning / قود مورنينق', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b22801ab-76fa-42e6-849c-e178a363d743', 'Seated Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/o_J6MWyt5jM', 'اجلس على الكرسي وثبت ظهرك السفلي على المقعد تمامًا، انزل لأقصى حد تقدر عليه وارفع لحد ما تستقيم ركبتك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0956cf57-9a40-4c72-bf8a-96d2ee0096f5', 'Band Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/I-HTMUrJnxs', 'ثبت الباند فوق الكعب، اجلس على طرف البنش وتمسك بيدينك لزيادة الثبات، اسحب الحبل لاقصى حد تقدر عليه واترك رجلك تستقيم تمامًا في الانبساط.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fb8b578e-6529-4054-b798-afa9b6e1402a', 'Lying Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/vl5nUdE9mWM', 'حوضك ثابت على البنش، ارفع الوزن بثني ومد الركبة بدون ما يرتفع حوضك عن الكرسي', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1ae7c7bf-2639-4c8e-a71c-64ae40e9a666', 'Cable Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/mBJXWg8ZOy0', 'اجلس على الكرسي وثبت ظهرك السفلي على المقعد تمامًا، ممكن تقدّم ظهرك العلوي وتمسك المقابض لزيادة الثبات، انزل لأقصى حد تقدر عليه وارفع لحد ما تستقيم ركبتك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b3129bc6-3f27-4f81-8ff8-d6974308fd55', 'Supine Cable Hamstring Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/sDCc1F5J8XA?si=Fi3D39aJogrB5ihd', 'الركبة ثبت مكانها، اسحب الحبل لاقصى حد تقدر عليه واترك رجلك تستقيم تمامًا في الانبساط.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('859521d8-8d10-4ef7-90a0-7b7685b051d3', 'Nordic Hamstring Curl', 'Hamstrings / الخلفية', '{}', 'Knee Flexion / ثني الركبة', 'قوة', 'وزن الجسم', 'متقدم', 'بدون معدات', 'https://youtu.be/Lgibr8od0yA?si=nfRetEkDRk55Bu0a', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Nordic (Eccentric) / نوردك (لامركزي)', 'Knee Flexion / ثني الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a7c995ed-07a0-4a50-bf7c-d41ce52408e6', 'Stability Ball Hamstring Curl', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة"}', 'Knee Flexion / ثني الركبة', 'قوة', 'كرة سويسرية', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/59/stability-ball-hamstring-curl/', NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Bridge Curl / ثني الركبة مع رفع الورك', 'Knee Flexion + Hip Extension / ثني الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b8fc16d1-c26a-4d3c-84cd-a4a73f67cc77', 'Hip Hinge', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/33/hip-hinge/', NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Hinge Drill / تمرين مفصلة الورك', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('764997da-1245-4650-a0c7-de42d804de62', 'TRX Hamstrings Curl', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة"}', 'Knee Flexion / ثني الركبة', 'قوة', 'TRX', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/86/trx-reg-hamstrings-curl/', NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Bridge Curl / ثني الركبة مع رفع الورك', 'Knee Flexion + Hip Extension / ثني الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a5ffcfa2-5226-49bf-93e7-56a41a1b6ee5', 'Flat DB Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/xphvjGDZeYE', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b32c8f82-223c-4155-bbf0-24b530112f70', 'DB Floor Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/UBmpZ7l5Nlk?si=kDcN-ueaTFxfKtbr', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9ac14b98-c4dd-4623-a59f-ac19f520b55f', 'Flat Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/vcBig73ojpE', 'استلق على بنش،القبضة بنفس مستوى الاكتاف أو أوسع قليلًا، قوّس ظهرك العلوي قليلاً، انزل لين تلمس صدرك واثبت ثانية ثم ارفع.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5492f0ed-7e71-4f77-82e6-a4124f51a41f', 'Machine Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/pOCRC2kpxB8?si=02xGtrfPjiYpspMv', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('648db100-eb32-4fe6-bd00-dd291eb54f6e', 'Feet Up Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/HrehfM1dmBE', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d660d118-9cd2-47f9-a7af-1430d68af8c1', 'Torso Elevated Push Up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/noaPB7u4_CU', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا', 'تصنيف فرعي: اليدان مرفوعتان؛ زاوية الضغط بالنسبة للجذع تشبه الضغط المائل لأسفل رغم تسميته الشائعة Incline Push-up — يحدده المدرب', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Decline Press / ضغط مائل لأسفل', 'Horizontal Adduction + Shoulder Extension / تقريب أفقي + مد الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c361cfb7-9490-40ca-b2ce-827cb63c71a4', 'Push Up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://youtu.be/WDIpL0pjun0?si=utydS_A8QfRIJtJm', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('868a01ce-73ae-4ec8-8420-3438069b226a', 'Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://www.youtube.com/watch?v=JvOJdUtx6UQ', 'استلق على بنش،القبضة بنفس مستوى الاكتاف أو أوسع قليلًا، قوّس ظهرك العلوي قليلاً، انزل لين تلمس صدرك واثبت ثانية ثم ارفع.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('338059f8-483f-462b-8cba-7f0835288096', 'Paused Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://www.youtube.com/shorts/Q3GmnmJISwE', 'استلق على بنش،القبضة بنفس مستوى الاكتاف أو أوسع قليلًا، قوّس ظهرك العلوي قليلاً، انزل لين تلمس صدرك واثبت 3 ثواني ثم ارفع.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1d5bb381-148f-4f39-b287-598b1f1d5877', 'Incline Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/0G2_XV7slIg', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Incline Press / ضغط مائل لأعلى', 'Shoulder Flexion + Horizontal Adduction / ثني الكتف + تقريب أفقي', 'Incline Press / ضغط مائل لأعلى') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6d2ee86e-5526-46a3-bb87-50ed37ccf759', 'Smith Machine Incline Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/EeLLZMdg6zI?si=UVsgFN7jhXMm0vW3', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Incline Press / ضغط مائل لأعلى', 'Shoulder Flexion + Horizontal Adduction / ثني الكتف + تقريب أفقي', 'Incline Press / ضغط مائل لأعلى') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('64fde419-092c-4c18-9eda-d76843d18ac4', 'Cable Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/tAILewhtCb0', 'اجلس على بنش انكلاين، اضبط الكيبل بمستوى صدرك تقريبا، ادفع الوزن للأمام باتجاه الداخل، احرص ان كوعك ما يكون بنفس ارتفاع كتفك', 'تصنيف فرعي: التعليمات تذكر بنش انكلاين، وتصنيف المصدر iso_push_chest — يُحسم بين Incline Press وعزل الصدر', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Incline Press / ضغط مائل لأعلى', 'Shoulder Flexion + Horizontal Adduction / ثني الكتف + تقريب أفقي', 'Incline Press / ضغط مائل لأعلى') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7a90e872-f186-483b-87a0-6cbb593527f4', 'Sternal Cable Press Around', 'Chest / الصدر', '{}', 'Horizontal Push / دفع أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/y8XQibXDnNo', 'اضبط الكيبل بمستوى صدرك تقريبا، حافظ على ذراعك قريبة من جسمك،ادفع الحبل للأمام باتجاه الداخل.', 'تصنيف فرعي: حركة مختلطة بين الضغط والـ Fly — يُحسم بين Flat Press وعزل الصدر', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Press-around / ضغط مع تقريب', 'Horizontal Adduction + Elbow Extension / تقريب أفقي + مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('bf10d9fb-1d7d-4de2-a222-86db4851a62e', 'Machine Chest Fly', 'Chest / الصدر', '{}', 'Horizontal Adduction (Fly) / تقريب أفقي للكتف (فلاي)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Chest Isolation / عزل الصدر', 'Horizontal Adduction / تقريب أفقي للكتف', 'Chest Isolation / عزل الصدر') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4133ff3c-7d19-4c81-a4b9-7a7dfb0f485a', 'Bar Cable Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/NhD3h6RG2TA?si=SoyNTIGB-nY2KiXl', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ec8533f0-ba69-470a-a504-8b139dc97ea7', 'Cable Chest Fly', 'Chest / الصدر', '{"Shoulders / الأكتاف"}', 'Horizontal Adduction (Fly) / تقريب أفقي للكتف (فلاي)', 'قوة', 'كيبل', 'مبتدئ', 'نادي', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/160/standing-chest-fly/', NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Chest Isolation / عزل الصدر', 'Horizontal Adduction / تقريب أفقي للكتف', 'Chest Isolation / عزل الصدر') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ec349418-962d-4ae4-ad90-dbe24ced58a6', 'Bent Knee Push-up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/13/bent-knee-push-up/', NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('35bb217b-f21c-4203-a77d-c6ec09c5d999', 'Stability Ball Push-Up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس","Core / البطن والكور"}', 'Horizontal Push / دفع أفقي', 'قوة', 'كرة سويسرية', 'متوسط', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف فرعي: الزاوية تعتمد على موضع الكرة (تحت اليدين أو القدمين) — غير محدد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/63/stability-ball-push-up/', NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ab543e71-14bc-4bfe-a204-fa2128f8bd7a', 'Cable Reardelt Rows', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/uIdXVGjcfFE', 'ثبت نفسك بالكرسي، فتحة واسعة، الكيبل بمستوى اسفل صدرك، واسحب لما تنقبض اكتافك الخلفية.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Wide-grip Row / تجديف بقبضة واسعة', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d3892f8c-cde2-4a72-a9b8-aac34503ea5c', 'Upper Back Horizontal Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/TSWohpfMlso', 'ثبت نفسك بالكرسي، فتحة واسعة، الكيبل بمستوى أعلى صدرك، واسحب لما تنقبض الترابز.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness', 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Wide-grip Row / تجديف بقبضة واسعة', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2293805d-f0e4-439d-97f1-ce114773c4ee', 'DB Chest Supported Reardelt Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/x0v6GWYzI18?si=-jDt3D-ARIHouHjp', 'ثبت صدرك على الكرسي، فتحة واسعة، واسحب لما تنقبض اكتافك الخلفية.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Wide-grip Row / تجديف بقبضة واسعة', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8ddf5228-f162-4df6-838f-9c2f195f9e4b', 'Bent-over Barbell Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'بار', 'متوسط', 'نادي', NULL, 'ادفع مؤخرتك للخلف واثني ركبك، قبضتك بنفس مستوى اكتافك، اسحب لما تنقبض عضلات الظهر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e842a599-6dbd-43bd-a558-291a897c2e3d', 'Cable Reardelt Fly', 'Shoulders / الأكتاف', '{"Rotator cuffs / الكفة المدورة"}', 'Shoulder Rear Pull / سحب خلفي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/bkejPHrPkmA?si=-O8q_5e72udoPRiY', NULL, 'تصنيف فرعي: حركة Fly (تبعيد أفقي للكتف) وليست سحباً أفقياً أو عمودياً', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Rear Delt Fly / فتح خلفي', 'Horizontal Abduction / تبعيد أفقي للكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f7d20873-d1bb-4e09-b5f3-bc71f4571e53', 'DB Chest Supported Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/H75im9fAUMc', 'ثبت صدرك على الكرسي، فتحة واسعة، واسحب الدمبل باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('33da7808-f971-4b4a-80df-1f3fff30d49c', 'Head Supported Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/c6lkPMhuyFA?si=eUivRGYSi0W7PmVe', 'راسك ثابت على البنش بدون أي ميلان بالرقبة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6ba8d117-2568-469c-ae47-589a7be25279', 'Single Arm Dumbbell Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/QBjaGx8mS1o', 'اسحب باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6d19b21d-f6ce-4735-abfd-048a7946a6f2', 'Single Arm Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/Qn_mHGObb8E?si=IZ0q9_tseiRIMtcs', 'اسحب باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ca7d5a27-0db9-4be0-a63f-52d1241b72ce', 'Seated Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/0G3W83dFUeY', 'اسحب باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness | تحدب الظهر / Postural Thoracic Kyphosis', 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ccc5982a-fc78-4231-b69c-a43359bfa349', 'Band Seated Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/Jy-WCFAofBY?si=9gqVby588rk1zFi9', 'فتحة واسعة، واسحب لما تنقبض عضلات الظهر.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness | تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture', 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f9ffb7ec-3e1b-4002-8157-8634baa18751', 'Chest Supported Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/DgHtyrQEMJ4?si=oTfTKVgD9j1H12wA', 'ثبت صدرك على الكرسي، فتحة واسعة، واسحب لما تنقبض عضلات الظهر.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness', 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('43680478-f4f8-419c-b23e-954db698f4af', 'Chest Supported Machine Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/BZrdEAiR2Xs?si=WhKaSGhR0gKeeies', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('df340099-8985-433f-845a-344a5d1f0d3d', 'T-Bar Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/6OtcNinT0HM?si=UPfYyypfZCaN9tTA', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b592f64e-8669-42d1-9b3b-d9c0739656f5', 'Lats Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/CQkT-W18N5g', 'الكيبل بنفس مستوى بطنك، اسحب باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Lat-focused Row / تجديف لاتس', 'Shoulder Extension / مد الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('456b4a55-f0e5-45f7-93cb-9759079a5172', 'Upperback Pulldowns', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/bNmvKpJSWKM?si=hy5HgBDAHkzFHcvv', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Wide-grip Pulldown / سحب علوي بقبضة واسعة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d5584576-f646-42dd-ae3f-e1c59ca66765', 'Straight Arm Pulldown', 'Back & Lats / الظهر واللاتس', '{}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/hAMcfubonDc?si=ocU_a8VQ4VzZnTg3', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Straight-arm Pull / سحب بذراع مستقيمة', 'Shoulder Extension + Scapular Depression / مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ba7fa653-2dc3-4b70-a797-144503684ffc', 'DB Pullover', 'Back & Lats / الظهر واللاتس', '{"Chest / الصدر","Triceps / الترايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/ieFKuQAGYIA?si=uwqyrbKhBL6Id3_-', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Straight-arm Pull / سحب بذراع مستقيمة', 'Shoulder Extension + Scapular Depression / مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('80f170d1-d74a-45b4-a272-0df0310d1a42', 'Band Lat Pulldown', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/5R0RYj3Y9Ro', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a0a652bb-0a02-472f-88eb-b6ecdefc9722', 'Band Assisted Pull Ups', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://youtu.be/Ks8ah-8P1b0', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('75ecf476-64f2-4681-98e4-8376f2b85fc4', 'Pull Ups', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متقدم', 'نادي', 'https://youtu.be/x3NPAxiMRPw?si=Mwg6U1Df5aIFpjKB', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a952f34a-0bb7-4f3d-8616-8618994085de', 'Negative Pull-Up', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://youtu.be/gbPURTSxQLY?si=TvQF5zDWfU_rR1Ax', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر، نزول بطيء.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ceb1dc9d-4590-4c20-8b73-663a45b3ebe3', 'Neutral Grip Lat Pulldown', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/kVB6SlEyjQM', 'القبضة بنفس مستوى الكتف، اسحب باتجاه اعلى الصدر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fbaa5b6b-ea32-4af0-84e6-e51c6fb645e9', 'Single Lats Pulldown', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/Qed5O9toqT8', 'اجلس على بنش واسند صدرك عليه، ارجع للخلف قليلا بحيث ان الكيبل ما يكون فوق راسك مباشرة، اسحب الكوع باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('92a33db2-5f5f-45e1-9038-bc11d6bf3951', 'Band Assisted Chin Ups', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://youtu.be/i0yC-0YK6Uk?si=gNX26kIFz_THnR4p', 'مسكة ضيقة بمستوى الأكتاف، كل ما كان الحبل خفيف زادت المقاومة وزدات صعوبة التمرين لذلك ابدأ بحبل ثقيل وخفف كل ما تحسن مستواك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b15232f8-f648-4d85-9206-513120fd76bd', 'Chin Ups', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متقدم', 'نادي', 'https://youtube.com/shorts/aV9Mz9nCsMw?si=E_ullJojGO_7srW2', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('20a7b6d5-34df-4d0e-8b7e-8adb9a34296d', 'Kneeling Lat Pulldown', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', NULL, 'متوسط', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/35/kneeling-lat-pulldown/', NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('dfc42312-c8c4-485f-9f74-494bd4efc0b2', 'TRX Back Row', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس","Core / البطن والكور","Lower back / أسفل الظهر"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'TRX', 'متوسط', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/84/trx-reg-back-row/', NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('862040b0-1341-422d-93e3-8041b416f0f8', 'Shrug', 'Back & Lats / الظهر واللاتس', '{"Trapezius / الترابيس"}', 'Scapular Elevation / رفع لوح الكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف فرعي: رفع الأكتاف (Shrug) ليس نمط سحب أفقي أو عمودي', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/72/shrug/', NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Shrug / هز الكتفين', 'Scapular Elevation / رفع لوح الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('514e88b1-3e2e-4d27-bce7-c35f6da45b96', 'DB Shoulder Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/NKeyUrDYqPk', 'قوّس ظهرك العلوي قليلاً، الكوع قريب من الجسم، النزول الى مستوى الاكتاف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9fd7ddd9-3232-40c8-8461-1140cd59e550', 'DB Standing Shoulder Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/wO0l5jW2NtQ?si=MVvS4F_7iFS8ji9R', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e9c1aa41-a26e-41ea-954d-cd371d69a917', 'Machine Shoulder Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/3R14MnZbcpw', 'قوّس ظهرك العلوي قليلاً، الكوع قريب من الجسم، النزول الى مستوى الاكتاف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4aed78e1-2a10-488a-ba70-7ef1d3970894', 'BB Overhead Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/_RlRDWO2jfg', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('764fab0c-62f1-450b-9957-1a54615bc4c5', 'DB Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/qqntiuPmLDM?feature=share', 'انحني للأمام قليلًا، ارفع للأعلى الى أن تصل لمستوى الأكتاف.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f064bd74-6afd-41e9-aebb-1f87682cd5d7', 'Seated Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/v7fwGurZ9SU?feature=share', 'انحني للأمام قليلًا، ارفع للأعلى الى أن تصل لمستوى الأكتاف.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c4c13885-e459-4a64-bcf5-00f14de1c1e5', 'Lateral Raise Machine', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/d0pRsZ9SY5w?si=XuXb_Ti0Flow7qvW', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c11de669-d0a2-4a5d-9b00-592e4c75ce2d', 'Cable Crossover Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/wKgCc5UQjoU?si=zsaz3i31PnEU9A43', 'الكيبل يبدأ من الأسفل، انحني للأمام قليلًا، ارفع للأعلى وتحكم بالنزول.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ceeb3b27-ae99-4d35-8cd0-54a4413722e5', 'DB Y Raises', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/lXp16YozXgk', 'ثبت صدرك على البنش،ارفع الوزن على شكل Y.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Y Raise (Scaption) / رفع Y بمستوى لوح الكتف', 'Shoulder Elevation in Scapular Plane (Scaption) / رفع الذراع بمستوى لوح الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3e12e648-6998-4d62-a076-219217b90a39', 'Cable Y Raises', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/P7u6PEeOn6Q?feature=share', 'الكيبل يبدأ من تحت،ارفع الوزن على شكل Y.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Y Raise (Scaption) / رفع Y بمستوى لوح الكتف', 'Shoulder Elevation in Scapular Plane (Scaption) / رفع الذراع بمستوى لوح الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5108b424-f551-4e22-836d-ab6d747c5256', 'Single Arm DB Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/Jm6GqVhWhNY', 'انحني للأمام قليلًا، ارفع للأعلى الى أن تصل لمستوى الأكتاف.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a6e664e7-852a-4f1b-b657-6a6c0066d726', 'Single Arm Cable Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/J-6uEOkYAKM', 'الكيبل يبدأ من الأسفل، انحني للأمام قليلًا، ارفع للأعلى وتحكم بالنزول.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('234b1cc6-05a4-4e6a-8578-6d3ce634ace2', 'Front Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Front Raise / رفع أمامي للكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/54/front-raise/', NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Front Raise / رفع أمامي', 'Shoulder Flexion / ثني الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0d305d36-717f-4476-8be5-7410191ba6c3', 'Diagonal Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/371/diagonal-raise/', NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Diagonal Raise / رفع قطري', 'Shoulder Flexion + Abduction (Diagonal) / ثني وتبعيد الكتف (قطري)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('64292438-933f-4266-9c75-d10f2cdfddfa', 'High Row', 'Shoulders / الأكتاف', '{}', 'Shoulder Rear Pull / سحب خلفي للكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/336/high-row/', NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'High Row / Face Pull / سحب عالٍ باتجاه الوجه', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('19ae3673-f754-4e4d-9f44-58264be6e401', 'Biceps Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/09AYfVFf7pg?si=dcwLVAYqIbDLM6jd', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('61504d7f-840d-4ba7-b5b6-4bc898a1c5b8', 'Cable Rope Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/xNXUTJ6TBZA?si=-r-Ql97awoVZla_1', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Hammer / Neutral-grip Curl / ثني بقبضة محايدة', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e075ad54-ac04-4a1e-a1b1-a5ff7cbf5ad2', 'Cable Facing Away Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/fV9BpknCjGM', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d922ffb8-6e33-41fc-a32b-945a4fcfc6ad', 'DB Incline Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/js_StxxyxBM', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c9fbb028-b4cf-40e4-83eb-84ced28c32b2', 'Cable Facing In Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/5z4y7QRTx1w', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('51b4f866-444e-4c32-a370-fc4c526d8543', 'Single Arm Cable Facing Away Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/6sO-pK7pTPs?feature=share', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5904e8c9-45fa-447f-a58c-e6395d98c639', 'Single Arm Cable Facing In Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/I-197ZW9Ffo?si=M1Yq4R1PIpdZMXRx', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ea9645ce-ea25-4ed3-a3dd-e18b634799e9', 'DB Preacher', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/DZJNTb-zzn0?si=SwbdZ0O_0eTOET-5', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Preacher Curl / ثني على مسند', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2029e9c7-d4f5-47d8-9479-453ebd127e4f', 'Preacher Curl Machine', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/TouYMA3-ua4?feature=share', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Preacher Curl / ثني على مسند', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2f6233de-4ed4-4b59-9bec-90963c8839c0', 'DB Spider Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/cTMjzB2_IH8?si=qsIKEEFVfEvPXwqf', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9d61a757-4cfa-46b6-8bdb-d01ea297e1e5', 'Zottman Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://www.youtube.com/watch?v=ZXbOOIOPOi8', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1656fb81-ec82-41db-95e4-3a042666a6b6', 'Hammer Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/10/hammer-curl/', NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Hammer / Neutral-grip Curl / ثني بقبضة محايدة', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('abed783c-9fa3-4e9e-8563-99a151fd7ca2', 'TRX Biceps Curl', 'Biceps / البايسبس', '{"Forearms / الساعد","Core / البطن والكور"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'TRX', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/78/trx-reg-biceps-curl/', NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8c606057-4484-4556-a963-18fac5fd2ced', 'DB Triceps Extensions', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/d7SXlU5HkYM?si=WuuPa9-yeByaP5sI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Overhead Extension / مد فوق الرأس', 'Elbow Extension / مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('089da09b-0af2-4971-8ac8-56ec28b1d8b8', 'DB Floor Triceps Extensions', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/dpFav9Ve4rY?si=ZBdKK8VF4aPMpi3v', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Lying Extension / مد مستلقٍ', 'Elbow Extension / مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0f33799d-70d5-4c31-896a-8089eabd8bd4', 'Cable Crossbody Extensions', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://www.youtube.com/watch?v=jtLTcED38Dg', 'الكيبل يبدأ بالمنتصف زي الفيديو، بحيث لما تسحب الكيبل يكون بنفس مستوى الترابس، الأكواع والأكتاف ثابتين مكانهم والحركة كلها بثني وفرد الكوع.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Cross-body Extension / مد عرضي', 'Elbow Extension / مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('201cfb9c-f42f-4cc7-88f9-a04603b4e886', 'Triceps Pushdown', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/QsoN4u6j8nM?feature=share', 'انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6202b592-6a50-4b3f-a34f-82ebabeee289', 'Cable Crossover Pressdowns', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/Y3CDzx-oj3k', 'الكيبل يبدأ من الأعلى،انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fd168b7c-829c-4573-a64e-a54eae785a80', 'Band Triceps Pushdown', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/mYs1rEYtZK4?si=k8vdZxNNEB5wj2CA', 'الكيبل يبدأ من الأعلى،انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2a73d120-3fff-44ee-8afd-c262b16b7a5f', 'Single Cable Triceps Pressdowns', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/8rl4ioij6lc', 'الكيبل يبدأ من الأعلى،انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c395d459-2803-47dc-9e25-88dc8c122699', 'Cable Overhead Extension', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://www.youtube.com/shorts/Q3bO1Fh4734', 'اترك الحبل يسحب معصمك وكوعك ثابت لما تستطيل التراي ثم ارفع الوزن لما تستقيم اليد، كوعك ثابت طول الوقت والحركة ثني ومد من مفصل الكوع، ممكن تطبق كل يد لحالها اذا كان اسهل لك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Overhead Extension / مد فوق الرأس', 'Elbow Extension / مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d8b9fe3b-269a-45f1-8701-5f23f4fcff82', 'Triceps Dips', 'Triceps / الترايسبس', '{"Chest / الصدر","Shoulders / الأكتاف"}', 'Vertical Push / دفع عمودي', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/SpSE_A5L-YA?si=bSAzRM9SBuX-3mE0', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Dip / متوازي', 'Shoulder Extension + Elbow Extension / مد الكتف + مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a7523b1f-0051-4639-be7d-78b53959a169', 'Triceps Kickback', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/YebyKE3Ts8o?si=H_h9z5BXutFBbFhq', NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/55/triceps-kickback/', NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Triceps Kickback / ركلة الترايسبس', 'Elbow Extension / مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d66dbdcf-86d3-402e-9a29-600bf86e5c28', 'Plank', 'Core / البطن والكور', '{"Shoulders / الأكتاف","Glutes / المؤخرة"}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/pvIjsG5Svck?si=cTP8ZyfMAJPfaEhw', 'لما ترتفع الاكتاف تكون فوق الكوع والرجل ممتدة بالكامل.', NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('82e50667-ee68-48d3-a21e-f504be7a554f', 'deadbug', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/g_BYB0R-4Ws?si=D4nwJri73eBqJRqL', NULL, 'اسم مشابه موجود في المكتبة (deadbug / dead bug) — تُراجَع قبل الحذف أو الدمج', 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'rejected', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9750c804-7f3b-477c-9e91-24a14c3725ce', 'Band Dead Bug', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'مطاط', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/iW_CtYtzbeU?si=Epequw3rqA3_TwTr', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3d2f0531-7f17-49f9-8fb1-48e963c28733', 'Side Plank', 'Core / البطن والكور', '{"Abductors / مبعدات الفخذ","Shoulders / الأكتاف"}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'لما ترتفع الاكتاف تكون فوق الكوع والرجل ممتدة بالكامل.', NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain | ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Anti-Lateral Flexion / مقاومة الميلان الجانبي', 'Isometric Anti-Lateral Flexion / تثبيت الجذع ضد الميلان', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7a6c0ba8-759d-44d1-9e82-15eee71a9fd5', 'McGill Big 3', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/jZylx81_kfg?si=_jP064GZIzvEvzyN', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Mixed (McGill Big 3) / مختلط', 'Isometric Trunk Stabilization / تثبيت الجذع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('aa9d2d82-6694-4bbd-8fb5-3b1936915a3e', 'Suitcase Carry', 'Core / البطن والكور', '{"Forearms / الساعد"}', 'Loaded Carry / حمل ومشي', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/BaRMAhD7SP4?si=KkiMH8OSIEz_TB53', NULL, 'نفس التمرين ورد أيضاً تحت التصنيف «Functional Training» (صف المصدر 160) || رابط آخر في المصدر (صف 160): https://youtu.be/BaRMAhD7SP4?si=dCR2n2VSPaHhxfL3', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Suitcase Carry / حمل جانبي', 'Isometric Trunk + Grip Under Load / تثبيت الجذع والقبضة أثناء المشي', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e502a30d-2d9e-46da-a739-5b102d873cde', 'Single Leg Raise', 'Core / البطن والكور', '{"Glutes / المؤخرة","Hamstrings / الخلفية"}', NULL, NULL, 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/ZJodU5OOaiA?si=p6ZD9dpzyRKBUn16', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1405a1dd-e9ec-4748-a8cf-37f4dd980a75', 'Cable Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/ToJeyhydUxU?si=Z5dv34foxX4VtRH6', 'الحركة عبارة عن ثني للعمود الفقري وكأنك تقرب صدرك لوركك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Crunch / كرنش', 'Trunk Flexion / ثني الجذع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5b6c9ae7-868c-49ae-8d8c-7d3b8a511d50', 'Leg Raises', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/UqmbxvOgnX4?si=U3pDG4Jf0x1mtC_7', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Reverse Crunch / Leg Raise / كرنش عكسي ورفع الأرجل', 'Hip Flexion + Posterior Pelvic Tilt / ثني الورك + إمالة الحوض للخلف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ad1e5bc2-fa50-45d8-9139-7118e7caf0a5', 'Bosu Ball Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'أخرى', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/KjvDgHPxXcg?si=zad59CHC6Y-calzi', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Crunch / كرنش', 'Trunk Flexion / ثني الجذع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e35b9314-46d6-4e65-8cdd-a71c8077afef', 'Bent Knee V-Up', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/sbyFIM30_G8?si=dED0NQSRS44dz5G9', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'V-up / في أب', 'Trunk Flexion + Hip Flexion / ثني الجذع + ثني الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cc29fcdd-1d2d-4055-9ff8-4a909a3cbeed', 'Reverse Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/esYVzdEfs04?si=N44MZZHlVeSQc1S3', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Reverse Crunch / Leg Raise / كرنش عكسي ورفع الأرجل', 'Hip Flexion + Posterior Pelvic Tilt / ثني الورك + إمالة الحوض للخلف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f691a822-fe82-42ba-bf9c-58873cf84414', 'Belly Breathing', 'Core / البطن والكور', '{}', 'Core Activation & Breathing / تفعيل الجذع والتنفس', 'إحماء/تفعيل', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/Shk8cmgv0Ew?si=mXkcj9PH6eH_tLcd', 'نفس عميق من الانف ننفخ فيه البطن ثم نطلعه من الفم ببطئ مع ضغط البطن للداخل اثناء اخراج النفس', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Diaphragmatic Breathing / تنفس حجابي', 'Diaphragmatic Breathing + Abdominal Bracing / تنفس حجابي + شد البطن', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('11289bdc-1c32-4fbb-be2a-c03b4677f76a', 'Dead Bug', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/_zkkMOtXuOQ?si=GIkLuCUJvdaOk5FP', 'نحرك الرجلين ببطئ قليلا و بتحكم باستخدام عضلات البطن', 'اسم مشابه موجود في المكتبة (deadbug / dead bug) — تُراجَع قبل الحذف أو الدمج', 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5fa9826f-97e1-42a5-b0e3-375d0b1c85c7', 'Reverse Tabletop Bridge', 'Core / البطن والكور', '{"Glutes / المؤخرة"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://youtu.be/d1yE9cGtPWo?si=2aoNqmUAN054rP75', 'اخذ نفس اثناء الطلوع، اثبت ثواني فوق واشد عضلات بطني، اطلع النفس اثناء النزول', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('85d60a42-1795-46c4-9110-0f30d3904b53', 'Bird Dog', 'Core / البطن والكور', '{"Lower back / أسفل الظهر","Glutes / المؤخرة"}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/L91QMACdA6Q?si=KBnuQDcm9WcUXxxI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Anti-Rotation / مقاومة الدوران', 'Isometric Anti-Rotation / تثبيت الجذع ضد الدوران', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ec073e99-d5c0-471f-8fb7-01783ed9ccc7', 'Pelvic Tilting', 'Core / البطن والكور', '{}', 'Core Activation & Breathing / تفعيل الجذع والتنفس', 'إحماء/تفعيل', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/DqqUIfMuDX4?si=uzl0SRl_M9guUT3j', 'الحركة من الحوض، اخذ نفس وادف حوضي للاعلى قليلا، اطلع النفس اثناء نزول الحوض والصق اسفل ظهري بالارض', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Pelvic Tilt / إمالة الحوض', 'Posterior Pelvic Tilt / إمالة الحوض للخلف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3c97943e-77d4-4227-94d6-782cef2112cb', 'Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/52/crunch/', NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Crunch / كرنش', 'Trunk Flexion / ثني الجذع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4ab99383-6e32-4fd1-8c95-5e4e2e8de9d6', 'Standing Wood Chop', 'Core / البطن والكور', '{}', 'Trunk Rotation / دوران الجذع', 'كور', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/108/standing-wood-chop/', NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Rotation / Chop / دوران وتقطيع', 'Trunk Rotation / دوران الجذع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('30346c72-ac5f-4265-837e-7b53c1e9834f', 'Russian Twist', 'Core / البطن والكور', '{"Lower back / أسفل الظهر"}', 'Trunk Rotation / دوران الجذع', 'كور', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/65/russian-twist/', NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Rotation / Chop / دوران وتقطيع', 'Trunk Rotation / دوران الجذع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7dcc2c9b-fcfc-46df-a2f4-7e269a5ce61e', 'Cable Twisted', 'Core / البطن والكور', '{"Lower back / أسفل الظهر"}', 'Trunk Rotation / دوران الجذع', 'كور', 'كيبل', 'مبتدئ', 'نادي', NULL, NULL, NULL, 'إضافة المدربة', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Rotation / Chop / دوران وتقطيع', 'Trunk Rotation / دوران الجذع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c29dbb3b-09af-4aa1-a427-faec522533c7', 'Calves On Leg Press', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/XdtWVYFVhGU', 'ثبت أصابعك أو مقدمة رجلك على الجهاز، لا تبالغ بالوزن، انزل بكعبك لين تمتد بطاتك بشكل كامل ثم ادفع.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('21739ca5-a1e2-479e-bd60-bbe7669fdab9', 'Calves Raise', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/H6WptvjXkgw', 'حط تحت اقدامك بليتس أو أي شي يرفعك عن الأرض، انزل من اصابعك اقصى نزول ثم ادفع للأعلى', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('39a5497a-2afb-453d-b4bb-1c7d14e77455', 'Calf Raise (Machine)', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', 'جهاز', 'مبتدئ', 'نادي', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/294/calf-raise/', NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('13bb2109-1b98-4b35-a3a9-013cd79c0089', 'Calf Raises (Barbell)', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', 'بار', 'مبتدئ', 'نادي', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/51/calf-raises/', NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6ada107f-d151-409c-bd8c-8ca2ef3154ce', 'High-Load Heel Raise (Towel Under Toes)', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', NULL, 'مبتدئ', NULL, NULL, 'رفع الكعب على رجل واحدة مع منشفة ملفوفة تحت أصابع القدم؛ صعود بطيء ثم ثبات قصير ثم نزول بطيء.', 'أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Rathleff et al. 2015 — Scand J Med Sci Sports (RCT)', 'https://doi.org/10.1111/sms.12313', 'اللفافة الأخمصية / Plantar Fasciopathy', 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a65aefbe-2ddd-4072-935c-3097b688d1eb', 'Adductor Slides', 'Adductors / الأفخاذ الداخلية', '{}', 'Hip Adduction / تقريب الورك', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/6U7dfuxaX9g?si=lkH35E7tZxGBePBj', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor strength»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Adductor Slide / انزلاق للتقريب', 'Hip Adduction / تقريب الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('26b9cb52-fe68-4a27-8d78-5c1933c2c590', 'Adductor Machine', 'Adductors / الأفخاذ الداخلية', '{}', 'Hip Adduction / تقريب الورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/SU1LQhq3o2g?si=_55FKBOlcn8Ilw4X', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Adductor Machine / جهاز التقريب', 'Hip Adduction / تقريب الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2c548a91-7ae1-4fc1-8b26-1f2e62010949', 'Side Lunge', 'Adductors / الأفخاذ الداخلية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/50/side-lunge/', 'ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Lateral Lunge / لانج جانبي', 'Knee/Hip Extension + Hip Adduction / مد الركبة والورك + تقريب الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d3038a52-0d6e-4c11-8ceb-73658c8e058f', 'Seated Abductor Machine', 'Abductors / مبعدات الفخذ', '{}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/riEMreTHNbM?si=wE3vfJBYQY7j_oJ2', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor strength»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('eb68d01b-22e8-4db8-88f4-15dffa3d53c5', 'Sled Pull/Push', 'Functional / التمارين الوظيفية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Calves / البطات"}', 'Locomotion / مشي وجري ودفع', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://www.youtube.com/watch?v=3KWK7SIdPz4', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Sled Push / Pull / دفع وسحب الزلاجة', 'Hip/Knee Extension in Gait / بسط الورك والركبة بنمط المشي', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('47eb84ff-5919-40a3-b2b3-fd488d22d56c', 'Hip Abductor Plank', 'Abductors / مبعدات الفخذ', '{"Core / البطن والكور"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/2lB5RL91yWo?si=WRm9rUORpFK6dXPl', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor strength»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f04bac3d-2397-4544-96b4-7d0f62a76da3', 'Dirty Dog', 'Abductors / مبعدات الفخذ', '{"Core / البطن والكور"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/109/dirty-dog/', NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b16e023b-bac0-4a5f-96c5-4417c7048c53', 'Hip Hitch (Pelvic Drop)', 'Abductors / مبعدات الفخذ', '{}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Ganderton et al. — GMin/GMed EMG (RMIT University)', 'https://research-repository.rmit.edu.au/articles/journal_contribution/Gluteus_Minimus_and_Gluteus_Medius_Muscle_Activity_during_Common_Rehabilitation_Exercises_in_Healthy_Postmenopausal_Women/27572301', 'ضعف الألوية المتوسطة / Gluteus Medius Weakness | ضعف الألوية الصغرى / Gluteus Minimus Weakness', 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Pelvic Drop (Stance Leg) / تثبيت الحوض برجل الارتكاز', 'Hip Abduction of Stance Leg / تبعيد ورك رجل الارتكاز', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4ac1443b-9ab7-4f0c-9668-9b2162accd15', 'Rotator Cuff', 'Rotator cuffs / الكفة المدورة', '{}', 'Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/mO8YJAxVG2M?si=KL_llR6Z47Yt89uk', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «Functional Training»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'External Rotation / دوران خارجي', 'Shoulder External Rotation / دوران خارجي للكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1795e8b2-6450-4a42-9ba3-5e149ff188fc', 'Shoulder I-Y-T-W Series', 'Rotator cuffs / الكفة المدورة', '{"Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/237/shoulder-stability-mobility-series-i-y-t-w-formations/', 'تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture | ضعف العضلة المعينية / Rhomboid Weakness', 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'I-Y-T-W / تمارين I-Y-T-W', 'Scapular Retraction/Depression + Arm Elevation / سحب وخفض لوح الكتف مع رفع الذراع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('35e7c856-468d-4e52-a9c4-df1016f6d5b9', 'Supine Snow Angel (Wipers)', 'Rotator cuffs / الكفة المدورة', '{"Shoulders / الأكتاف","Core / البطن والكور"}', 'Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/124/supine-snow-angel-wipers-exercise/', 'تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture', 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Snow Angel / الملاك', 'Shoulder Abduction/Adduction + Scapular Control / تبعيد وتقريب الكتف مع تحكم لوح الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5cb17c07-b220-46e1-8e49-3b6a8252108e', 'Back Extension', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة","Hamstrings / الخلفية"}', 'Spinal Extension / بسط الجذع', 'كور', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/bs7S3RFyIYs?si=tDLl3OYuDBIwK4Fj', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «Functional Training»)', 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain | تحدب الظهر / Postural Thoracic Kyphosis', 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Back Extension / بسط الظهر', 'Hip Extension + Spinal Extension / بسط الورك + بسط العمود الفقري', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d71feb66-e2ef-4782-8069-0215b5d5ac06', 'Supermans', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة","Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Spinal Extension / بسط الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/9/supermans/', 'تحدب الظهر / Postural Thoracic Kyphosis | آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Prone Extension / بسط على البطن', 'Spinal Extension / بسط العمود الفقري', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('73c7c3c3-d46b-48ed-8b66-5bc783e7f51f', 'Stability Ball Reverse Extensions', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة"}', 'Spinal Extension / بسط الجذع', 'كور', 'كرة سويسرية', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/64/stability-ball-reverse-extensions/', NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Reverse Extension / بسط عكسي', 'Hip Extension + Spinal Extension / بسط الورك + بسط العمود الفقري', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7f666923-6132-4a1d-a579-7e2f4258e728', 'Farmer’s Walk', 'Functional / التمارين الوظيفية', '{"Forearms / الساعد","Core / البطن والكور","Back & Lats / الظهر واللاتس"}', 'Loaded Carry / حمل ومشي', 'قوة', NULL, 'مبتدئ', NULL, 'https://www.youtube.com/watch?v=hx24PM6gXs8', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Farmer''s Walk / مشي المزارع', 'Isometric Trunk + Grip Under Load / تثبيت الجذع والقبضة أثناء المشي', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('10bb5345-3324-46e3-bec7-538431bcdd73', 'Contralateral Limb Raises', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة","Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Spinal Extension / بسط الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/53/contralateral-limb-raises/', NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Prone Extension / بسط على البطن', 'Spinal Extension / بسط العمود الفقري', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('424406bd-6343-4a39-9a93-2fa331de82e1', 'Inner Thigh Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/uqCfJYKojLU?si=Gev0VeOwVp5z6gB2', 'الضغط والدفع يكون من جهة الفخذ ، لا تدفع من ركبتك!', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «stretch»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Adductor Stretch / إطالة المقربات', 'Hip Abduction (Adductor Stretch) / تبعيد الورك (إطالة المقربات)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('19e73bdd-2784-490f-944c-0ff84f51ffb3', 'Hips Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/uqCfJYKojLU?si=Gev0VeOwVp5z6gB2', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «stretch»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Hip Stretch / إطالة الورك', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('61b36832-4233-4374-ae7f-d0c4eb4fc2bb', 'Kneeling Hip-flexor Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'من وضع الركوع: الركبة الخلفية تحت الورك والقدم الأمامية أمامك والركبة فوق الكاحل. شد البطن وادفع الحوض للأمام دون تقويس أسفل الظهر، واعصر مؤخرة الجهة الخلفية لزيادة الإطالة. اثبت 30–45 ثانية، 2–5 مرات.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/142/kneeling-hip-flexor-stretch/', NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Hip Flexor Stretch / إطالة ثانيات الورك', 'Hip Extension (End Range) / بسط الورك في نهاية المدى', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3d436622-ca05-4568-b83f-9091ce2cc5a7', 'Supine Hamstrings Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'استلقِ على ظهرك وارفع رجلاً واحدة ومدّها ببطء مع سحب أصابع القدم نحوك، دون أي حركة في الحوض أو أسفل الظهر. اثبت 15–30 ثانية، 2–4 مرات لكل رجل.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/235/supine-hamstrings-stretch/', NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Hamstring Stretch / إطالة الخلفية', 'Hip Flexion with Knee Extended / ثني الورك مع مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('149d0128-2e92-4e88-ad7a-3d0d014ad2de', 'Side Lying Quadriceps Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'استلقِ على جنبك وشد البطن، واسحب كعب الرجل العلوية نحو المؤخرة بيدك مع إبقاء الركبة في خط الورك. اثبت 30–45 ثانية، 2–5 مرات لكل جهة.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/149/side-lying-quadriceps-stretch/', NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Quadriceps Stretch / إطالة الأمامية', 'Knee Flexion + Hip Extension (End Range) / ثني الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c086b464-2c9e-4afa-9b68-aa7568eeb6cf', 'Standing Dorsi-Flexion (Calf Stretch)', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/152/standing-dorsi-flexion-calf-stretch/', 'اللفافة الأخمصية / Plantar Fasciopathy', 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Calf Stretch / إطالة البطات', 'Ankle Dorsiflexion / ثني ظهري للكاحل', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('868105a8-0e01-449e-8754-abb516569962', 'Cat-Cow', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/15/cat-cow/', 'تحدب الظهر / Postural Thoracic Kyphosis | آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Spinal Mobility / مرونة العمود الفقري', 'Spinal Flexion/Extension / ثني وبسط العمود الفقري', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9c8569b6-b6d8-4873-854a-dbc7f94e2750', 'Standing Lunge Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/137/standing-lunge-stretch/', NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Hip Flexor Stretch / إطالة ثانيات الورك', 'Hip Extension (End Range) / بسط الورك في نهاية المدى', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e5268548-dc7a-43d7-9cd3-4336b8db90c0', 'Plantar Fascia-Specific Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'تُسحب أصابع القدم للخلف باليد حتى يُشعر بشد في باطن القدم، مع تحسّس اللفافة للتأكد من الشد.', 'أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Rathleff et al. 2015 — Scand J Med Sci Sports (RCT)', 'https://doi.org/10.1111/sms.12313', 'اللفافة الأخمصية / Plantar Fasciopathy', 'review', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Plantar Fascia Stretch / إطالة اللفافة الأخمصية', 'Toe Extension + Ankle Dorsiflexion / مد أصابع القدم + ثني ظهري', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e5c43110-f362-492c-9295-ae25ffb90348', 'Crab Reach (Thoracic Bridge)', 'Functional / التمارين الوظيفية', '{"Glutes / المؤخرة","Shoulders / الأكتاف"}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://www.youtube.com/watch?v=fgsUe3Lc3hI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'تحدب الظهر / Postural Thoracic Kyphosis', 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Thoracic Bridge / جسر صدري', 'Hip Extension + Thoracic Rotation / بسط الورك + دوران الصدر', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('476bad67-74b1-41d1-8c04-b9fa274f5703', 'Lateral Bound', 'Plyometrics / التمارين الانفجارية', '{"Glutes / المؤخرة","Quadriceps / الأمامية","Abductors / مبعدات الفخذ"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://www.youtube.com/watch?v=soqQy4dzEts', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «Functional Training»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Lateral Jump / قفز جانبي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0d321c9a-2ed3-4e8f-a831-f5ed9d318052', 'Box Jumps', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Calves / البطات"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'أخرى', 'متوسط', 'نادي', NULL, NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «CrossFit»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Vertical Jump / قفز عمودي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('36661dd9-8db3-4f53-937f-19d6016a1e40', 'Squat Jump', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متوسط', 'بدون معدات', NULL, 'قف بعرض الحوض، ادفع الورك للخلف وانزل، ثم اقفز بقوة بمدّ الكاحل والركبة والورك معاً. انزل بهدوء على منتصف القدم مع دفع الورك للخلف ودون قفل الركب. ابدأ بقفزات صغيرة حتى تتقن الهبوط.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/222/squat-jump/', NULL, 'review', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Vertical Jump / قفز عمودي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('37b0a0cd-473c-4df6-88d1-02f2e2dbe8db', 'Tuck Jump', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متقدم', 'بدون معدات', NULL, 'استخدم الذراعين للزخم: أرجعهما للخلف عند النزول وأرجحهما للأمام والأعلى عند القفز، واسحب الركبتين نحو الصدر في الهواء.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/180/tuck-jump/', NULL, 'review', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Vertical Jump / قفز عمودي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4eb609c4-bab5-41d2-943b-f81a4772bfa0', 'Cycled Split-Squat Jump', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Hamstrings / الخلفية"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متقدم', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/234/cycled-split-squat-jump/', NULL, 'review', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Split Jump / قفز سبليت', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5b12ee66-0a13-488f-b051-748671c54f84', 'Lateral Cone Jumps', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Calves / البطات"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'أخرى', 'متوسط', 'نادي', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/120/lateral-cone-jumps/', NULL, 'review', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Lateral Jump / قفز جانبي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('49725262-fdf6-476b-9638-2a9cb822f2c3', 'Forward Linear Jumps', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Hamstrings / الخلفية"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متوسط', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/177/forward-linear-jumps/', NULL, 'review', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Horizontal Jump / قفز أمامي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c7c223bb-b0b8-472c-87b5-4615cb4c083d', 'Jogging', 'CrossFit / كروس فت', '{"Quadriceps / الأمامية","Hamstrings / الخلفية","Calves / البطات"}', 'Locomotion / مشي وجري ودفع', 'كارديو', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Running / جري', 'Gait: Alternating Hip/Knee Extension / نمط المشي والجري', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('181ffb6b-1da8-44fb-8ad1-85c78a838bb9', 'Wall Ball', 'CrossFit / كروس فت', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Shoulders / الأكتاف"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'أخرى', 'متوسط', 'نادي', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Squat to Throw / سكوات مع رمي', 'Knee/Hip Extension + Shoulder Flexion / مد الركبة والورك + ثني الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a32c2afc-2066-4b72-8bfe-89d06df992e8', 'Snatch', 'CrossFit / كروس فت', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Shoulders / الأكتاف"}', 'Olympic Lift (Triple Extension) / رفعات أولمبية (بسط ثلاثي)', 'قدرة', 'بار', 'متقدم', 'نادي', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Snatch / سناتش', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f49fa36b-a47c-44c7-b333-db1efa73e7cf', 'Clean', 'CrossFit / كروس فت', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Quadriceps / الأمامية"}', 'Olympic Lift (Triple Extension) / رفعات أولمبية (بسط ثلاثي)', 'قدرة', 'بار', 'متقدم', 'نادي', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Clean / كلين', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a1918f5e-e9e7-48cc-8c69-a61030099917', 'Turkish Get-Up', 'Functional / التمارين الوظيفية', '{"Shoulders / الأكتاف","Core / البطن والكور","Glutes / المؤخرة"}', 'Full-body Integrated / حركة متكاملة للجسم', 'قوة', 'كيتلبل', 'متقدم', 'منزل', 'https://www.youtube.com/watch?v=0bWRPC49-KI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Turkish Get-Up / النهوض التركي', 'Multi-joint Integrated / حركة متعددة المفاصل', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('556d2836-cebe-495e-abc4-a0a6fc76821f', '90s Transition', 'Functional / التمارين الوظيفية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://www.youtube.com/watch?v=ogU-azeGe_k', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Hip Rotation Mobility (90/90) / مرونة دوران الورك', 'Hip Internal/External Rotation / دوران الورك الداخلي والخارجي', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1ae13640-abef-4981-8f75-870782ed2e63', 'Prone Swimmer', 'Functional / التمارين الوظيفية', '{"Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Shoulder Rear Pull / سحب خلفي للكتف', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://www.youtube.com/watch?v=M8a1cgnhyqk', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture', 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Prone Swimmer / سبّاح على البطن', 'Shoulder Extension/Abduction + Rotation / مد وتبعيد الكتف مع الدوران', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('036ccc3b-a18a-44c7-972e-a204e8372ab7', 'Kettlebell Swing', 'Functional / التمارين الوظيفية', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Core / البطن والكور"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قدرة', 'كيتلبل', 'متوسط', 'منزل', 'https://www.youtube.com/watch?v=d94xX-AQZ0A', NULL, 'نفس التمرين ورد أيضاً تحت التصنيف «CrossFit» (صف المصدر 168)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Ballistic Hinge (Swing) / مفصلة انفجارية (سوينق)', 'Hip Extension (Ballistic) / بسط الورك الانفجاري', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('037975a5-8427-4830-bbf9-aed5ca83bf3d', 'left over db', 'Functional / التمارين الوظيفية', '{}', NULL, NULL, 'دمبل', NULL, 'منزل', 'https://youtu.be/pLnRt-caepc?si=DAS9jeYr8vS6RRtz', 'طبق الحركة بأقصى عدد ممكن من التكرارات وأحسبها كجولة، ثم ابدأ بالجولة الثانية بنفس الطريقة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6371e48a-4704-4130-b0a9-71c889b9cd66', 'Serratus Punches Supine', 'Functional / التمارين الوظيفية', '{"Shoulders / الأكتاف","Chest / الصدر"}', 'Horizontal Push / دفع أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/cxaAqmdlrgk?si=2YRAIgFFXPAvDadG', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Scapular Protraction / دفع لوح الكتف', 'Scapular Protraction / دفع لوح الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4f4c9d45-7dbc-460c-abf4-881628bfd40a', 'Isometric Wrist Extension', 'Forearms / الساعد', '{}', 'Wrist Extension / مد الرسغ', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'مرفق التنس / Lateral Elbow Tendinopathy', 'review', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Isometric / ثابت', 'Wrist Extension / مد الرسغ', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4af03b46-258d-437d-9b49-187251b3e5f6', 'Eccentric Wrist Extension', 'Forearms / الساعد', '{}', 'Wrist Extension / مد الرسغ', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'مرفق التنس / Lateral Elbow Tendinopathy', 'review', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Eccentric / لامركزي', 'Wrist Extension / مد الرسغ', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('50aea61e-e61e-47bb-9fd3-ccf712ad1288', 'Chin Tuck (Deep Neck Flexor)', 'Neck / الرقبة', '{}', 'Neck Flexion (Deep Flexors) / ثني الرقبة العميق', 'إحماء/تفعيل', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Sheikhhoseini et al. 2018 — JMPT (Systematic review, FHP)', 'https://pubmed.ncbi.nlm.nih.gov/30107937/', 'وضعية الرأس للأمام / Forward Head Posture', 'review', '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00', 'Chin Tuck / سحب الذقن', 'Upper Cervical Flexion + Retraction / ثني علوي للرقبة مع سحبها للخلف', NULL) ON CONFLICT DO NOTHING;



INSERT INTO public.exercise_alternatives VALUES ('5143aad3-d434-42c1-afdd-83479273e49e', '89fb4cb9-3889-4886-827f-c04b40dbf1d5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5143aad3-d434-42c1-afdd-83479273e49e', '7a070258-d712-4f17-a758-951396736f4d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5143aad3-d434-42c1-afdd-83479273e49e', '52235a71-4720-43bc-a7d4-2f273a957bd2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5143aad3-d434-42c1-afdd-83479273e49e', '2ecefdf6-abbe-41f2-b487-e23c8c9794b0', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5143aad3-d434-42c1-afdd-83479273e49e', 'a014cfa5-89d5-474d-a4dd-088748005c96', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89fb4cb9-3889-4886-827f-c04b40dbf1d5', '5143aad3-d434-42c1-afdd-83479273e49e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89fb4cb9-3889-4886-827f-c04b40dbf1d5', '7a070258-d712-4f17-a758-951396736f4d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89fb4cb9-3889-4886-827f-c04b40dbf1d5', '52235a71-4720-43bc-a7d4-2f273a957bd2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89fb4cb9-3889-4886-827f-c04b40dbf1d5', '2ecefdf6-abbe-41f2-b487-e23c8c9794b0', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89fb4cb9-3889-4886-827f-c04b40dbf1d5', 'a014cfa5-89d5-474d-a4dd-088748005c96', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8c1bce16-452c-425c-b61c-1d73f662ea73', 'd088cfce-625d-4853-8f95-49484e87ba72', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8c1bce16-452c-425c-b61c-1d73f662ea73', 'ce0eb340-b302-442c-8036-575834120894', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8c1bce16-452c-425c-b61c-1d73f662ea73', '5143aad3-d434-42c1-afdd-83479273e49e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8c1bce16-452c-425c-b61c-1d73f662ea73', '89fb4cb9-3889-4886-827f-c04b40dbf1d5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8c1bce16-452c-425c-b61c-1d73f662ea73', '59b1c89a-e9ad-4dfa-af24-70da92fa73fd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59b1c89a-e9ad-4dfa-af24-70da92fa73fd', '1fe25d8f-b8d8-43fe-926f-d21c873edde2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59b1c89a-e9ad-4dfa-af24-70da92fa73fd', '5143aad3-d434-42c1-afdd-83479273e49e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59b1c89a-e9ad-4dfa-af24-70da92fa73fd', '89fb4cb9-3889-4886-827f-c04b40dbf1d5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59b1c89a-e9ad-4dfa-af24-70da92fa73fd', '8c1bce16-452c-425c-b61c-1d73f662ea73', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59b1c89a-e9ad-4dfa-af24-70da92fa73fd', '7a070258-d712-4f17-a758-951396736f4d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1fe25d8f-b8d8-43fe-926f-d21c873edde2', '59b1c89a-e9ad-4dfa-af24-70da92fa73fd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1fe25d8f-b8d8-43fe-926f-d21c873edde2', '5143aad3-d434-42c1-afdd-83479273e49e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1fe25d8f-b8d8-43fe-926f-d21c873edde2', '89fb4cb9-3889-4886-827f-c04b40dbf1d5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1fe25d8f-b8d8-43fe-926f-d21c873edde2', '8c1bce16-452c-425c-b61c-1d73f662ea73', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1fe25d8f-b8d8-43fe-926f-d21c873edde2', '7a070258-d712-4f17-a758-951396736f4d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a070258-d712-4f17-a758-951396736f4d', '5143aad3-d434-42c1-afdd-83479273e49e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a070258-d712-4f17-a758-951396736f4d', '89fb4cb9-3889-4886-827f-c04b40dbf1d5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a070258-d712-4f17-a758-951396736f4d', '52235a71-4720-43bc-a7d4-2f273a957bd2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a070258-d712-4f17-a758-951396736f4d', '2ecefdf6-abbe-41f2-b487-e23c8c9794b0', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a070258-d712-4f17-a758-951396736f4d', 'a014cfa5-89d5-474d-a4dd-088748005c96', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('52235a71-4720-43bc-a7d4-2f273a957bd2', '5143aad3-d434-42c1-afdd-83479273e49e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('52235a71-4720-43bc-a7d4-2f273a957bd2', '89fb4cb9-3889-4886-827f-c04b40dbf1d5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('52235a71-4720-43bc-a7d4-2f273a957bd2', '7a070258-d712-4f17-a758-951396736f4d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('52235a71-4720-43bc-a7d4-2f273a957bd2', '2ecefdf6-abbe-41f2-b487-e23c8c9794b0', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('52235a71-4720-43bc-a7d4-2f273a957bd2', 'a014cfa5-89d5-474d-a4dd-088748005c96', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d088cfce-625d-4853-8f95-49484e87ba72', '8c1bce16-452c-425c-b61c-1d73f662ea73', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d088cfce-625d-4853-8f95-49484e87ba72', 'ce0eb340-b302-442c-8036-575834120894', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d088cfce-625d-4853-8f95-49484e87ba72', '5143aad3-d434-42c1-afdd-83479273e49e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d088cfce-625d-4853-8f95-49484e87ba72', '89fb4cb9-3889-4886-827f-c04b40dbf1d5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d088cfce-625d-4853-8f95-49484e87ba72', '59b1c89a-e9ad-4dfa-af24-70da92fa73fd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2ecefdf6-abbe-41f2-b487-e23c8c9794b0', '5143aad3-d434-42c1-afdd-83479273e49e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2ecefdf6-abbe-41f2-b487-e23c8c9794b0', '89fb4cb9-3889-4886-827f-c04b40dbf1d5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2ecefdf6-abbe-41f2-b487-e23c8c9794b0', '7a070258-d712-4f17-a758-951396736f4d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2ecefdf6-abbe-41f2-b487-e23c8c9794b0', '52235a71-4720-43bc-a7d4-2f273a957bd2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2ecefdf6-abbe-41f2-b487-e23c8c9794b0', 'a014cfa5-89d5-474d-a4dd-088748005c96', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce0eb340-b302-442c-8036-575834120894', '8c1bce16-452c-425c-b61c-1d73f662ea73', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce0eb340-b302-442c-8036-575834120894', 'd088cfce-625d-4853-8f95-49484e87ba72', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce0eb340-b302-442c-8036-575834120894', '5143aad3-d434-42c1-afdd-83479273e49e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce0eb340-b302-442c-8036-575834120894', '89fb4cb9-3889-4886-827f-c04b40dbf1d5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce0eb340-b302-442c-8036-575834120894', '59b1c89a-e9ad-4dfa-af24-70da92fa73fd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7e4ab1c9-7c23-4198-b57c-f8e094d0efab', 'a7250971-8845-4874-9ad8-64eeba12f3cc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7e4ab1c9-7c23-4198-b57c-f8e094d0efab', 'a3e4b189-0a00-4c48-873d-61e8d8b53259', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7e4ab1c9-7c23-4198-b57c-f8e094d0efab', '5bc69a88-1a2e-47eb-a84e-8e2885690dbc', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7e4ab1c9-7c23-4198-b57c-f8e094d0efab', '06e54867-27d9-4f18-a574-a55dc9f67735', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7e4ab1c9-7c23-4198-b57c-f8e094d0efab', 'd8e737e1-2a4c-4b8b-a9c9-70dac160b8ff', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a7250971-8845-4874-9ad8-64eeba12f3cc', 'a3e4b189-0a00-4c48-873d-61e8d8b53259', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a7250971-8845-4874-9ad8-64eeba12f3cc', '5bc69a88-1a2e-47eb-a84e-8e2885690dbc', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a7250971-8845-4874-9ad8-64eeba12f3cc', 'd8e737e1-2a4c-4b8b-a9c9-70dac160b8ff', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a7250971-8845-4874-9ad8-64eeba12f3cc', '75927eb4-1a2e-4a79-ac39-ed3167fd34ef', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a7250971-8845-4874-9ad8-64eeba12f3cc', '7e4ab1c9-7c23-4198-b57c-f8e094d0efab', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a3e4b189-0a00-4c48-873d-61e8d8b53259', 'a7250971-8845-4874-9ad8-64eeba12f3cc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a3e4b189-0a00-4c48-873d-61e8d8b53259', '5bc69a88-1a2e-47eb-a84e-8e2885690dbc', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a3e4b189-0a00-4c48-873d-61e8d8b53259', 'd8e737e1-2a4c-4b8b-a9c9-70dac160b8ff', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a3e4b189-0a00-4c48-873d-61e8d8b53259', '75927eb4-1a2e-4a79-ac39-ed3167fd34ef', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a3e4b189-0a00-4c48-873d-61e8d8b53259', '7e4ab1c9-7c23-4198-b57c-f8e094d0efab', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5bc69a88-1a2e-47eb-a84e-8e2885690dbc', 'a7250971-8845-4874-9ad8-64eeba12f3cc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5bc69a88-1a2e-47eb-a84e-8e2885690dbc', 'a3e4b189-0a00-4c48-873d-61e8d8b53259', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5bc69a88-1a2e-47eb-a84e-8e2885690dbc', 'd8e737e1-2a4c-4b8b-a9c9-70dac160b8ff', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5bc69a88-1a2e-47eb-a84e-8e2885690dbc', '75927eb4-1a2e-4a79-ac39-ed3167fd34ef', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5bc69a88-1a2e-47eb-a84e-8e2885690dbc', '7e4ab1c9-7c23-4198-b57c-f8e094d0efab', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('06e54867-27d9-4f18-a574-a55dc9f67735', '7e4ab1c9-7c23-4198-b57c-f8e094d0efab', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('06e54867-27d9-4f18-a574-a55dc9f67735', 'a7250971-8845-4874-9ad8-64eeba12f3cc', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('06e54867-27d9-4f18-a574-a55dc9f67735', 'a3e4b189-0a00-4c48-873d-61e8d8b53259', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('06e54867-27d9-4f18-a574-a55dc9f67735', '5bc69a88-1a2e-47eb-a84e-8e2885690dbc', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('06e54867-27d9-4f18-a574-a55dc9f67735', 'd8e737e1-2a4c-4b8b-a9c9-70dac160b8ff', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d8e737e1-2a4c-4b8b-a9c9-70dac160b8ff', 'a7250971-8845-4874-9ad8-64eeba12f3cc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d8e737e1-2a4c-4b8b-a9c9-70dac160b8ff', 'a3e4b189-0a00-4c48-873d-61e8d8b53259', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d8e737e1-2a4c-4b8b-a9c9-70dac160b8ff', '5bc69a88-1a2e-47eb-a84e-8e2885690dbc', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d8e737e1-2a4c-4b8b-a9c9-70dac160b8ff', '75927eb4-1a2e-4a79-ac39-ed3167fd34ef', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d8e737e1-2a4c-4b8b-a9c9-70dac160b8ff', '7e4ab1c9-7c23-4198-b57c-f8e094d0efab', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75927eb4-1a2e-4a79-ac39-ed3167fd34ef', 'a7250971-8845-4874-9ad8-64eeba12f3cc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75927eb4-1a2e-4a79-ac39-ed3167fd34ef', 'a3e4b189-0a00-4c48-873d-61e8d8b53259', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75927eb4-1a2e-4a79-ac39-ed3167fd34ef', '5bc69a88-1a2e-47eb-a84e-8e2885690dbc', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75927eb4-1a2e-4a79-ac39-ed3167fd34ef', 'd8e737e1-2a4c-4b8b-a9c9-70dac160b8ff', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75927eb4-1a2e-4a79-ac39-ed3167fd34ef', '7e4ab1c9-7c23-4198-b57c-f8e094d0efab', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('969cd31e-d614-4db3-a8e5-6b172845bddc', 'a9a72847-98d8-4965-8ac4-326a709a4e40', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('969cd31e-d614-4db3-a8e5-6b172845bddc', '45a81b8a-76ce-4caf-8564-f4b89f60c99b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('969cd31e-d614-4db3-a8e5-6b172845bddc', '65a6ff6d-81c3-4dbd-9186-554bd4f5d7ea', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('969cd31e-d614-4db3-a8e5-6b172845bddc', 'b5a697e8-7fc5-4e70-9bd5-574cf790b51b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('969cd31e-d614-4db3-a8e5-6b172845bddc', '4c42bdca-ff49-4e0a-8f7b-f8e636680011', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a9a72847-98d8-4965-8ac4-326a709a4e40', '969cd31e-d614-4db3-a8e5-6b172845bddc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a9a72847-98d8-4965-8ac4-326a709a4e40', '45a81b8a-76ce-4caf-8564-f4b89f60c99b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a9a72847-98d8-4965-8ac4-326a709a4e40', '65a6ff6d-81c3-4dbd-9186-554bd4f5d7ea', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a9a72847-98d8-4965-8ac4-326a709a4e40', 'b5a697e8-7fc5-4e70-9bd5-574cf790b51b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a9a72847-98d8-4965-8ac4-326a709a4e40', '4c42bdca-ff49-4e0a-8f7b-f8e636680011', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45a81b8a-76ce-4caf-8564-f4b89f60c99b', '969cd31e-d614-4db3-a8e5-6b172845bddc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45a81b8a-76ce-4caf-8564-f4b89f60c99b', 'a9a72847-98d8-4965-8ac4-326a709a4e40', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45a81b8a-76ce-4caf-8564-f4b89f60c99b', '65a6ff6d-81c3-4dbd-9186-554bd4f5d7ea', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45a81b8a-76ce-4caf-8564-f4b89f60c99b', 'b5a697e8-7fc5-4e70-9bd5-574cf790b51b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45a81b8a-76ce-4caf-8564-f4b89f60c99b', '4c42bdca-ff49-4e0a-8f7b-f8e636680011', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c42bdca-ff49-4e0a-8f7b-f8e636680011', '969cd31e-d614-4db3-a8e5-6b172845bddc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c42bdca-ff49-4e0a-8f7b-f8e636680011', 'a9a72847-98d8-4965-8ac4-326a709a4e40', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c42bdca-ff49-4e0a-8f7b-f8e636680011', '45a81b8a-76ce-4caf-8564-f4b89f60c99b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c42bdca-ff49-4e0a-8f7b-f8e636680011', '65a6ff6d-81c3-4dbd-9186-554bd4f5d7ea', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c42bdca-ff49-4e0a-8f7b-f8e636680011', 'b5a697e8-7fc5-4e70-9bd5-574cf790b51b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('65a6ff6d-81c3-4dbd-9186-554bd4f5d7ea', '969cd31e-d614-4db3-a8e5-6b172845bddc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('65a6ff6d-81c3-4dbd-9186-554bd4f5d7ea', 'a9a72847-98d8-4965-8ac4-326a709a4e40', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('65a6ff6d-81c3-4dbd-9186-554bd4f5d7ea', '45a81b8a-76ce-4caf-8564-f4b89f60c99b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('65a6ff6d-81c3-4dbd-9186-554bd4f5d7ea', 'b5a697e8-7fc5-4e70-9bd5-574cf790b51b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('65a6ff6d-81c3-4dbd-9186-554bd4f5d7ea', '4c42bdca-ff49-4e0a-8f7b-f8e636680011', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b5a697e8-7fc5-4e70-9bd5-574cf790b51b', '969cd31e-d614-4db3-a8e5-6b172845bddc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b5a697e8-7fc5-4e70-9bd5-574cf790b51b', 'a9a72847-98d8-4965-8ac4-326a709a4e40', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b5a697e8-7fc5-4e70-9bd5-574cf790b51b', '45a81b8a-76ce-4caf-8564-f4b89f60c99b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b5a697e8-7fc5-4e70-9bd5-574cf790b51b', '65a6ff6d-81c3-4dbd-9186-554bd4f5d7ea', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b5a697e8-7fc5-4e70-9bd5-574cf790b51b', '4c42bdca-ff49-4e0a-8f7b-f8e636680011', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a014cfa5-89d5-474d-a4dd-088748005c96', '5143aad3-d434-42c1-afdd-83479273e49e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a014cfa5-89d5-474d-a4dd-088748005c96', '89fb4cb9-3889-4886-827f-c04b40dbf1d5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a014cfa5-89d5-474d-a4dd-088748005c96', '7a070258-d712-4f17-a758-951396736f4d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a014cfa5-89d5-474d-a4dd-088748005c96', '52235a71-4720-43bc-a7d4-2f273a957bd2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a014cfa5-89d5-474d-a4dd-088748005c96', '2ecefdf6-abbe-41f2-b487-e23c8c9794b0', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('58a0bb47-0f11-43e8-b851-4a5b5f6195cb', '7e4ab1c9-7c23-4198-b57c-f8e094d0efab', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('58a0bb47-0f11-43e8-b851-4a5b5f6195cb', 'a7250971-8845-4874-9ad8-64eeba12f3cc', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('58a0bb47-0f11-43e8-b851-4a5b5f6195cb', 'a3e4b189-0a00-4c48-873d-61e8d8b53259', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('58a0bb47-0f11-43e8-b851-4a5b5f6195cb', '5bc69a88-1a2e-47eb-a84e-8e2885690dbc', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('58a0bb47-0f11-43e8-b851-4a5b5f6195cb', '06e54867-27d9-4f18-a574-a55dc9f67735', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d927fb5d-f235-44d5-b24c-19c46f5e350f', 'a8769842-a16e-43c9-a83c-9cc032b51af3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d927fb5d-f235-44d5-b24c-19c46f5e350f', 'b47ad698-4524-4331-8c06-e1d7cabe7512', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d927fb5d-f235-44d5-b24c-19c46f5e350f', 'ed39cdde-56d4-40ff-b66a-6ff27859d7d7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a8769842-a16e-43c9-a83c-9cc032b51af3', 'd927fb5d-f235-44d5-b24c-19c46f5e350f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a8769842-a16e-43c9-a83c-9cc032b51af3', 'b47ad698-4524-4331-8c06-e1d7cabe7512', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a8769842-a16e-43c9-a83c-9cc032b51af3', 'ed39cdde-56d4-40ff-b66a-6ff27859d7d7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b47ad698-4524-4331-8c06-e1d7cabe7512', 'd927fb5d-f235-44d5-b24c-19c46f5e350f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b47ad698-4524-4331-8c06-e1d7cabe7512', 'a8769842-a16e-43c9-a83c-9cc032b51af3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b47ad698-4524-4331-8c06-e1d7cabe7512', 'ed39cdde-56d4-40ff-b66a-6ff27859d7d7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ed39cdde-56d4-40ff-b66a-6ff27859d7d7', 'd927fb5d-f235-44d5-b24c-19c46f5e350f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ed39cdde-56d4-40ff-b66a-6ff27859d7d7', 'a8769842-a16e-43c9-a83c-9cc032b51af3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ed39cdde-56d4-40ff-b66a-6ff27859d7d7', 'b47ad698-4524-4331-8c06-e1d7cabe7512', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a37b9e90-9e9f-498a-8888-6a31a8288813', '1ecfae64-824f-413c-9e3b-7a1238139a7a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a37b9e90-9e9f-498a-8888-6a31a8288813', '7eb02693-a112-4733-8cbf-dca86920ce23', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a37b9e90-9e9f-498a-8888-6a31a8288813', '45ccb254-da17-4bad-a65a-763964a967c1', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a37b9e90-9e9f-498a-8888-6a31a8288813', 'b873b3ff-9473-4131-9421-13f6d48ddb86', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a37b9e90-9e9f-498a-8888-6a31a8288813', '2014bb6a-8218-4fe8-8239-3be9cfeee84b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('05f64402-2e76-49a0-a00d-80a1f28c47d7', 'd3038a52-0d6e-4c11-8ceb-73658c8e058f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('05f64402-2e76-49a0-a00d-80a1f28c47d7', '47eb84ff-5919-40a3-b2b3-fd488d22d56c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('05f64402-2e76-49a0-a00d-80a1f28c47d7', 'f04bac3d-2397-4544-96b4-7d0f62a76da3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('05f64402-2e76-49a0-a00d-80a1f28c47d7', '873a4785-a2d0-46d5-822d-945d870f02cd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('05f64402-2e76-49a0-a00d-80a1f28c47d7', 'b16e023b-bac0-4a5f-96c5-4417c7048c53', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ecfae64-824f-413c-9e3b-7a1238139a7a', 'a37b9e90-9e9f-498a-8888-6a31a8288813', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ecfae64-824f-413c-9e3b-7a1238139a7a', '7eb02693-a112-4733-8cbf-dca86920ce23', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ecfae64-824f-413c-9e3b-7a1238139a7a', '45ccb254-da17-4bad-a65a-763964a967c1', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ecfae64-824f-413c-9e3b-7a1238139a7a', 'b873b3ff-9473-4131-9421-13f6d48ddb86', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ecfae64-824f-413c-9e3b-7a1238139a7a', '2014bb6a-8218-4fe8-8239-3be9cfeee84b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('873a4785-a2d0-46d5-822d-945d870f02cd', '05f64402-2e76-49a0-a00d-80a1f28c47d7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('873a4785-a2d0-46d5-822d-945d870f02cd', 'd3038a52-0d6e-4c11-8ceb-73658c8e058f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('873a4785-a2d0-46d5-822d-945d870f02cd', '47eb84ff-5919-40a3-b2b3-fd488d22d56c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('873a4785-a2d0-46d5-822d-945d870f02cd', 'f04bac3d-2397-4544-96b4-7d0f62a76da3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('873a4785-a2d0-46d5-822d-945d870f02cd', 'b16e023b-bac0-4a5f-96c5-4417c7048c53', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d45793a5-2bfc-432b-8836-138835ad8ecd', 'd927fb5d-f235-44d5-b24c-19c46f5e350f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d45793a5-2bfc-432b-8836-138835ad8ecd', 'a8769842-a16e-43c9-a83c-9cc032b51af3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d45793a5-2bfc-432b-8836-138835ad8ecd', 'b47ad698-4524-4331-8c06-e1d7cabe7512', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d45793a5-2bfc-432b-8836-138835ad8ecd', 'ed39cdde-56d4-40ff-b66a-6ff27859d7d7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45ccb254-da17-4bad-a65a-763964a967c1', 'b873b3ff-9473-4131-9421-13f6d48ddb86', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45ccb254-da17-4bad-a65a-763964a967c1', '2014bb6a-8218-4fe8-8239-3be9cfeee84b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45ccb254-da17-4bad-a65a-763964a967c1', '46b5f1a0-42ed-4714-9a85-d9602f8d551b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45ccb254-da17-4bad-a65a-763964a967c1', 'e3a9ca8d-6fa3-4296-ab89-8fbf47a65f52', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45ccb254-da17-4bad-a65a-763964a967c1', 'a37b9e90-9e9f-498a-8888-6a31a8288813', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b873b3ff-9473-4131-9421-13f6d48ddb86', '45ccb254-da17-4bad-a65a-763964a967c1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b873b3ff-9473-4131-9421-13f6d48ddb86', '2014bb6a-8218-4fe8-8239-3be9cfeee84b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b873b3ff-9473-4131-9421-13f6d48ddb86', '46b5f1a0-42ed-4714-9a85-d9602f8d551b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b873b3ff-9473-4131-9421-13f6d48ddb86', 'e3a9ca8d-6fa3-4296-ab89-8fbf47a65f52', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b873b3ff-9473-4131-9421-13f6d48ddb86', 'a37b9e90-9e9f-498a-8888-6a31a8288813', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2014bb6a-8218-4fe8-8239-3be9cfeee84b', '45ccb254-da17-4bad-a65a-763964a967c1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2014bb6a-8218-4fe8-8239-3be9cfeee84b', 'b873b3ff-9473-4131-9421-13f6d48ddb86', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2014bb6a-8218-4fe8-8239-3be9cfeee84b', '46b5f1a0-42ed-4714-9a85-d9602f8d551b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2014bb6a-8218-4fe8-8239-3be9cfeee84b', 'e3a9ca8d-6fa3-4296-ab89-8fbf47a65f52', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2014bb6a-8218-4fe8-8239-3be9cfeee84b', 'a37b9e90-9e9f-498a-8888-6a31a8288813', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('46b5f1a0-42ed-4714-9a85-d9602f8d551b', '45ccb254-da17-4bad-a65a-763964a967c1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('46b5f1a0-42ed-4714-9a85-d9602f8d551b', 'b873b3ff-9473-4131-9421-13f6d48ddb86', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('46b5f1a0-42ed-4714-9a85-d9602f8d551b', '2014bb6a-8218-4fe8-8239-3be9cfeee84b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('46b5f1a0-42ed-4714-9a85-d9602f8d551b', 'e3a9ca8d-6fa3-4296-ab89-8fbf47a65f52', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('46b5f1a0-42ed-4714-9a85-d9602f8d551b', 'a37b9e90-9e9f-498a-8888-6a31a8288813', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4526ba11-0ff0-4275-b324-4f6010d747a2', 'a37b9e90-9e9f-498a-8888-6a31a8288813', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4526ba11-0ff0-4275-b324-4f6010d747a2', '1ecfae64-824f-413c-9e3b-7a1238139a7a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4526ba11-0ff0-4275-b324-4f6010d747a2', '45ccb254-da17-4bad-a65a-763964a967c1', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4526ba11-0ff0-4275-b324-4f6010d747a2', 'b873b3ff-9473-4131-9421-13f6d48ddb86', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4526ba11-0ff0-4275-b324-4f6010d747a2', '2014bb6a-8218-4fe8-8239-3be9cfeee84b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3a9ca8d-6fa3-4296-ab89-8fbf47a65f52', '45ccb254-da17-4bad-a65a-763964a967c1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3a9ca8d-6fa3-4296-ab89-8fbf47a65f52', 'b873b3ff-9473-4131-9421-13f6d48ddb86', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3a9ca8d-6fa3-4296-ab89-8fbf47a65f52', '2014bb6a-8218-4fe8-8239-3be9cfeee84b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3a9ca8d-6fa3-4296-ab89-8fbf47a65f52', '46b5f1a0-42ed-4714-9a85-d9602f8d551b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3a9ca8d-6fa3-4296-ab89-8fbf47a65f52', 'a37b9e90-9e9f-498a-8888-6a31a8288813', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7eb02693-a112-4733-8cbf-dca86920ce23', 'a37b9e90-9e9f-498a-8888-6a31a8288813', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7eb02693-a112-4733-8cbf-dca86920ce23', '1ecfae64-824f-413c-9e3b-7a1238139a7a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7eb02693-a112-4733-8cbf-dca86920ce23', '45ccb254-da17-4bad-a65a-763964a967c1', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7eb02693-a112-4733-8cbf-dca86920ce23', 'b873b3ff-9473-4131-9421-13f6d48ddb86', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7eb02693-a112-4733-8cbf-dca86920ce23', '2014bb6a-8218-4fe8-8239-3be9cfeee84b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fca6dcde-460a-4750-bc36-5380e37d4ce7', 'd927fb5d-f235-44d5-b24c-19c46f5e350f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fca6dcde-460a-4750-bc36-5380e37d4ce7', 'a8769842-a16e-43c9-a83c-9cc032b51af3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fca6dcde-460a-4750-bc36-5380e37d4ce7', 'b47ad698-4524-4331-8c06-e1d7cabe7512', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fca6dcde-460a-4750-bc36-5380e37d4ce7', 'ed39cdde-56d4-40ff-b66a-6ff27859d7d7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5c11df46-30ab-4781-ae50-9287e215ec83', 'e6cadfdd-e39d-4196-84bc-99ee0f295661', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5c11df46-30ab-4781-ae50-9287e215ec83', '0aba228c-bea8-454a-bd69-5e55bc97ca76', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5c11df46-30ab-4781-ae50-9287e215ec83', 'ebefed11-d9f6-4d5f-a3de-21c8aae838a2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5c11df46-30ab-4781-ae50-9287e215ec83', '5a5f10e6-db39-4a39-99e4-997988e552e5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5c11df46-30ab-4781-ae50-9287e215ec83', '6390141c-800b-4538-9b6e-201320f62037', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c84b8502-6979-48d6-aa2a-9fb85f972c2b', 'e6cadfdd-e39d-4196-84bc-99ee0f295661', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c84b8502-6979-48d6-aa2a-9fb85f972c2b', '0aba228c-bea8-454a-bd69-5e55bc97ca76', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c84b8502-6979-48d6-aa2a-9fb85f972c2b', 'ebefed11-d9f6-4d5f-a3de-21c8aae838a2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c84b8502-6979-48d6-aa2a-9fb85f972c2b', '5a5f10e6-db39-4a39-99e4-997988e552e5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c84b8502-6979-48d6-aa2a-9fb85f972c2b', '6390141c-800b-4538-9b6e-201320f62037', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e6cadfdd-e39d-4196-84bc-99ee0f295661', '0aba228c-bea8-454a-bd69-5e55bc97ca76', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e6cadfdd-e39d-4196-84bc-99ee0f295661', 'ebefed11-d9f6-4d5f-a3de-21c8aae838a2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e6cadfdd-e39d-4196-84bc-99ee0f295661', '5a5f10e6-db39-4a39-99e4-997988e552e5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e6cadfdd-e39d-4196-84bc-99ee0f295661', '6390141c-800b-4538-9b6e-201320f62037', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e6cadfdd-e39d-4196-84bc-99ee0f295661', 'fc0d70d2-641c-4625-9ff7-7a702ffaee3d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0aba228c-bea8-454a-bd69-5e55bc97ca76', 'e6cadfdd-e39d-4196-84bc-99ee0f295661', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0aba228c-bea8-454a-bd69-5e55bc97ca76', 'ebefed11-d9f6-4d5f-a3de-21c8aae838a2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0aba228c-bea8-454a-bd69-5e55bc97ca76', '5a5f10e6-db39-4a39-99e4-997988e552e5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0aba228c-bea8-454a-bd69-5e55bc97ca76', '6390141c-800b-4538-9b6e-201320f62037', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0aba228c-bea8-454a-bd69-5e55bc97ca76', 'fc0d70d2-641c-4625-9ff7-7a702ffaee3d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ebefed11-d9f6-4d5f-a3de-21c8aae838a2', 'e6cadfdd-e39d-4196-84bc-99ee0f295661', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ebefed11-d9f6-4d5f-a3de-21c8aae838a2', '0aba228c-bea8-454a-bd69-5e55bc97ca76', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ebefed11-d9f6-4d5f-a3de-21c8aae838a2', '5a5f10e6-db39-4a39-99e4-997988e552e5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ebefed11-d9f6-4d5f-a3de-21c8aae838a2', '6390141c-800b-4538-9b6e-201320f62037', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ebefed11-d9f6-4d5f-a3de-21c8aae838a2', 'fc0d70d2-641c-4625-9ff7-7a702ffaee3d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5a5f10e6-db39-4a39-99e4-997988e552e5', 'e6cadfdd-e39d-4196-84bc-99ee0f295661', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5a5f10e6-db39-4a39-99e4-997988e552e5', '0aba228c-bea8-454a-bd69-5e55bc97ca76', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5a5f10e6-db39-4a39-99e4-997988e552e5', 'ebefed11-d9f6-4d5f-a3de-21c8aae838a2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5a5f10e6-db39-4a39-99e4-997988e552e5', '6390141c-800b-4538-9b6e-201320f62037', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5a5f10e6-db39-4a39-99e4-997988e552e5', 'fc0d70d2-641c-4625-9ff7-7a702ffaee3d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6390141c-800b-4538-9b6e-201320f62037', 'e6cadfdd-e39d-4196-84bc-99ee0f295661', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6390141c-800b-4538-9b6e-201320f62037', '0aba228c-bea8-454a-bd69-5e55bc97ca76', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6390141c-800b-4538-9b6e-201320f62037', 'ebefed11-d9f6-4d5f-a3de-21c8aae838a2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6390141c-800b-4538-9b6e-201320f62037', '5a5f10e6-db39-4a39-99e4-997988e552e5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6390141c-800b-4538-9b6e-201320f62037', 'fc0d70d2-641c-4625-9ff7-7a702ffaee3d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc0d70d2-641c-4625-9ff7-7a702ffaee3d', 'e6cadfdd-e39d-4196-84bc-99ee0f295661', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc0d70d2-641c-4625-9ff7-7a702ffaee3d', '0aba228c-bea8-454a-bd69-5e55bc97ca76', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc0d70d2-641c-4625-9ff7-7a702ffaee3d', 'ebefed11-d9f6-4d5f-a3de-21c8aae838a2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc0d70d2-641c-4625-9ff7-7a702ffaee3d', '5a5f10e6-db39-4a39-99e4-997988e552e5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc0d70d2-641c-4625-9ff7-7a702ffaee3d', '6390141c-800b-4538-9b6e-201320f62037', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('51a069a2-640d-4513-85e5-8db55ee1682a', 'e6cadfdd-e39d-4196-84bc-99ee0f295661', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('51a069a2-640d-4513-85e5-8db55ee1682a', '0aba228c-bea8-454a-bd69-5e55bc97ca76', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('51a069a2-640d-4513-85e5-8db55ee1682a', 'ebefed11-d9f6-4d5f-a3de-21c8aae838a2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('51a069a2-640d-4513-85e5-8db55ee1682a', '5a5f10e6-db39-4a39-99e4-997988e552e5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('51a069a2-640d-4513-85e5-8db55ee1682a', '6390141c-800b-4538-9b6e-201320f62037', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b22801ab-76fa-42e6-849c-e178a363d743', '0956cf57-9a40-4c72-bf8a-96d2ee0096f5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b22801ab-76fa-42e6-849c-e178a363d743', 'fb8b578e-6529-4054-b798-afa9b6e1402a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b22801ab-76fa-42e6-849c-e178a363d743', '5f1721fb-2258-4b58-b7c9-56cc8e93dfef', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b22801ab-76fa-42e6-849c-e178a363d743', 'beafe0aa-17f3-45b7-9972-f1a27f2381e7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b22801ab-76fa-42e6-849c-e178a363d743', '1ae7c7bf-2639-4c8e-a71c-64ae40e9a666', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0956cf57-9a40-4c72-bf8a-96d2ee0096f5', 'b22801ab-76fa-42e6-849c-e178a363d743', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0956cf57-9a40-4c72-bf8a-96d2ee0096f5', 'fb8b578e-6529-4054-b798-afa9b6e1402a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0956cf57-9a40-4c72-bf8a-96d2ee0096f5', '5f1721fb-2258-4b58-b7c9-56cc8e93dfef', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0956cf57-9a40-4c72-bf8a-96d2ee0096f5', 'beafe0aa-17f3-45b7-9972-f1a27f2381e7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0956cf57-9a40-4c72-bf8a-96d2ee0096f5', '1ae7c7bf-2639-4c8e-a71c-64ae40e9a666', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fb8b578e-6529-4054-b798-afa9b6e1402a', 'b22801ab-76fa-42e6-849c-e178a363d743', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fb8b578e-6529-4054-b798-afa9b6e1402a', '0956cf57-9a40-4c72-bf8a-96d2ee0096f5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fb8b578e-6529-4054-b798-afa9b6e1402a', '5f1721fb-2258-4b58-b7c9-56cc8e93dfef', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fb8b578e-6529-4054-b798-afa9b6e1402a', 'beafe0aa-17f3-45b7-9972-f1a27f2381e7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fb8b578e-6529-4054-b798-afa9b6e1402a', '1ae7c7bf-2639-4c8e-a71c-64ae40e9a666', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5f1721fb-2258-4b58-b7c9-56cc8e93dfef', 'b22801ab-76fa-42e6-849c-e178a363d743', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5f1721fb-2258-4b58-b7c9-56cc8e93dfef', '0956cf57-9a40-4c72-bf8a-96d2ee0096f5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5f1721fb-2258-4b58-b7c9-56cc8e93dfef', 'fb8b578e-6529-4054-b798-afa9b6e1402a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5f1721fb-2258-4b58-b7c9-56cc8e93dfef', 'beafe0aa-17f3-45b7-9972-f1a27f2381e7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5f1721fb-2258-4b58-b7c9-56cc8e93dfef', '1ae7c7bf-2639-4c8e-a71c-64ae40e9a666', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('beafe0aa-17f3-45b7-9972-f1a27f2381e7', 'b22801ab-76fa-42e6-849c-e178a363d743', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('beafe0aa-17f3-45b7-9972-f1a27f2381e7', '0956cf57-9a40-4c72-bf8a-96d2ee0096f5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('beafe0aa-17f3-45b7-9972-f1a27f2381e7', 'fb8b578e-6529-4054-b798-afa9b6e1402a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('beafe0aa-17f3-45b7-9972-f1a27f2381e7', '5f1721fb-2258-4b58-b7c9-56cc8e93dfef', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('beafe0aa-17f3-45b7-9972-f1a27f2381e7', '1ae7c7bf-2639-4c8e-a71c-64ae40e9a666', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ae7c7bf-2639-4c8e-a71c-64ae40e9a666', 'b22801ab-76fa-42e6-849c-e178a363d743', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ae7c7bf-2639-4c8e-a71c-64ae40e9a666', '0956cf57-9a40-4c72-bf8a-96d2ee0096f5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ae7c7bf-2639-4c8e-a71c-64ae40e9a666', 'fb8b578e-6529-4054-b798-afa9b6e1402a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ae7c7bf-2639-4c8e-a71c-64ae40e9a666', '5f1721fb-2258-4b58-b7c9-56cc8e93dfef', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ae7c7bf-2639-4c8e-a71c-64ae40e9a666', 'beafe0aa-17f3-45b7-9972-f1a27f2381e7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b3129bc6-3f27-4f81-8ff8-d6974308fd55', 'b22801ab-76fa-42e6-849c-e178a363d743', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b3129bc6-3f27-4f81-8ff8-d6974308fd55', '0956cf57-9a40-4c72-bf8a-96d2ee0096f5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b3129bc6-3f27-4f81-8ff8-d6974308fd55', 'fb8b578e-6529-4054-b798-afa9b6e1402a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b3129bc6-3f27-4f81-8ff8-d6974308fd55', '5f1721fb-2258-4b58-b7c9-56cc8e93dfef', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b3129bc6-3f27-4f81-8ff8-d6974308fd55', 'beafe0aa-17f3-45b7-9972-f1a27f2381e7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('859521d8-8d10-4ef7-90a0-7b7685b051d3', 'b22801ab-76fa-42e6-849c-e178a363d743', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('859521d8-8d10-4ef7-90a0-7b7685b051d3', '0956cf57-9a40-4c72-bf8a-96d2ee0096f5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('859521d8-8d10-4ef7-90a0-7b7685b051d3', 'fb8b578e-6529-4054-b798-afa9b6e1402a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('859521d8-8d10-4ef7-90a0-7b7685b051d3', '5f1721fb-2258-4b58-b7c9-56cc8e93dfef', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('859521d8-8d10-4ef7-90a0-7b7685b051d3', 'beafe0aa-17f3-45b7-9972-f1a27f2381e7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a7c995ed-07a0-4a50-bf7c-d41ce52408e6', '764997da-1245-4650-a0c7-de42d804de62', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a7c995ed-07a0-4a50-bf7c-d41ce52408e6', 'b22801ab-76fa-42e6-849c-e178a363d743', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a7c995ed-07a0-4a50-bf7c-d41ce52408e6', '0956cf57-9a40-4c72-bf8a-96d2ee0096f5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a7c995ed-07a0-4a50-bf7c-d41ce52408e6', 'fb8b578e-6529-4054-b798-afa9b6e1402a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a7c995ed-07a0-4a50-bf7c-d41ce52408e6', '5f1721fb-2258-4b58-b7c9-56cc8e93dfef', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b8fc16d1-c26a-4d3c-84cd-a4a73f67cc77', 'e6cadfdd-e39d-4196-84bc-99ee0f295661', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b8fc16d1-c26a-4d3c-84cd-a4a73f67cc77', '0aba228c-bea8-454a-bd69-5e55bc97ca76', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b8fc16d1-c26a-4d3c-84cd-a4a73f67cc77', 'ebefed11-d9f6-4d5f-a3de-21c8aae838a2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b8fc16d1-c26a-4d3c-84cd-a4a73f67cc77', '5a5f10e6-db39-4a39-99e4-997988e552e5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b8fc16d1-c26a-4d3c-84cd-a4a73f67cc77', '6390141c-800b-4538-9b6e-201320f62037', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('764997da-1245-4650-a0c7-de42d804de62', 'a7c995ed-07a0-4a50-bf7c-d41ce52408e6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('764997da-1245-4650-a0c7-de42d804de62', 'b22801ab-76fa-42e6-849c-e178a363d743', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('764997da-1245-4650-a0c7-de42d804de62', '0956cf57-9a40-4c72-bf8a-96d2ee0096f5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('764997da-1245-4650-a0c7-de42d804de62', 'fb8b578e-6529-4054-b798-afa9b6e1402a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('764997da-1245-4650-a0c7-de42d804de62', '5f1721fb-2258-4b58-b7c9-56cc8e93dfef', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a5ffcfa2-5226-49bf-93e7-56a41a1b6ee5', 'b32c8f82-223c-4155-bbf0-24b530112f70', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a5ffcfa2-5226-49bf-93e7-56a41a1b6ee5', '9ac14b98-c4dd-4623-a59f-ac19f520b55f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a5ffcfa2-5226-49bf-93e7-56a41a1b6ee5', '5492f0ed-7e71-4f77-82e6-a4124f51a41f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a5ffcfa2-5226-49bf-93e7-56a41a1b6ee5', '648db100-eb32-4fe6-bd00-dd291eb54f6e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a5ffcfa2-5226-49bf-93e7-56a41a1b6ee5', 'c361cfb7-9490-40ca-b2ce-827cb63c71a4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b32c8f82-223c-4155-bbf0-24b530112f70', 'a5ffcfa2-5226-49bf-93e7-56a41a1b6ee5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b32c8f82-223c-4155-bbf0-24b530112f70', '9ac14b98-c4dd-4623-a59f-ac19f520b55f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b32c8f82-223c-4155-bbf0-24b530112f70', '5492f0ed-7e71-4f77-82e6-a4124f51a41f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b32c8f82-223c-4155-bbf0-24b530112f70', '648db100-eb32-4fe6-bd00-dd291eb54f6e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b32c8f82-223c-4155-bbf0-24b530112f70', 'c361cfb7-9490-40ca-b2ce-827cb63c71a4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ac14b98-c4dd-4623-a59f-ac19f520b55f', 'a5ffcfa2-5226-49bf-93e7-56a41a1b6ee5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ac14b98-c4dd-4623-a59f-ac19f520b55f', 'b32c8f82-223c-4155-bbf0-24b530112f70', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ac14b98-c4dd-4623-a59f-ac19f520b55f', '5492f0ed-7e71-4f77-82e6-a4124f51a41f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ac14b98-c4dd-4623-a59f-ac19f520b55f', '648db100-eb32-4fe6-bd00-dd291eb54f6e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ac14b98-c4dd-4623-a59f-ac19f520b55f', 'c361cfb7-9490-40ca-b2ce-827cb63c71a4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5492f0ed-7e71-4f77-82e6-a4124f51a41f', 'a5ffcfa2-5226-49bf-93e7-56a41a1b6ee5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5492f0ed-7e71-4f77-82e6-a4124f51a41f', 'b32c8f82-223c-4155-bbf0-24b530112f70', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5492f0ed-7e71-4f77-82e6-a4124f51a41f', '9ac14b98-c4dd-4623-a59f-ac19f520b55f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5492f0ed-7e71-4f77-82e6-a4124f51a41f', '648db100-eb32-4fe6-bd00-dd291eb54f6e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5492f0ed-7e71-4f77-82e6-a4124f51a41f', 'c361cfb7-9490-40ca-b2ce-827cb63c71a4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('648db100-eb32-4fe6-bd00-dd291eb54f6e', 'a5ffcfa2-5226-49bf-93e7-56a41a1b6ee5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('648db100-eb32-4fe6-bd00-dd291eb54f6e', 'b32c8f82-223c-4155-bbf0-24b530112f70', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('648db100-eb32-4fe6-bd00-dd291eb54f6e', '9ac14b98-c4dd-4623-a59f-ac19f520b55f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('648db100-eb32-4fe6-bd00-dd291eb54f6e', '5492f0ed-7e71-4f77-82e6-a4124f51a41f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('648db100-eb32-4fe6-bd00-dd291eb54f6e', 'c361cfb7-9490-40ca-b2ce-827cb63c71a4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d660d118-9cd2-47f9-a7af-1430d68af8c1', 'a5ffcfa2-5226-49bf-93e7-56a41a1b6ee5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d660d118-9cd2-47f9-a7af-1430d68af8c1', 'b32c8f82-223c-4155-bbf0-24b530112f70', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d660d118-9cd2-47f9-a7af-1430d68af8c1', '9ac14b98-c4dd-4623-a59f-ac19f520b55f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d660d118-9cd2-47f9-a7af-1430d68af8c1', '5492f0ed-7e71-4f77-82e6-a4124f51a41f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d660d118-9cd2-47f9-a7af-1430d68af8c1', '648db100-eb32-4fe6-bd00-dd291eb54f6e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c361cfb7-9490-40ca-b2ce-827cb63c71a4', 'a5ffcfa2-5226-49bf-93e7-56a41a1b6ee5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c361cfb7-9490-40ca-b2ce-827cb63c71a4', 'b32c8f82-223c-4155-bbf0-24b530112f70', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c361cfb7-9490-40ca-b2ce-827cb63c71a4', '9ac14b98-c4dd-4623-a59f-ac19f520b55f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c361cfb7-9490-40ca-b2ce-827cb63c71a4', '5492f0ed-7e71-4f77-82e6-a4124f51a41f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c361cfb7-9490-40ca-b2ce-827cb63c71a4', '648db100-eb32-4fe6-bd00-dd291eb54f6e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('868a01ce-73ae-4ec8-8420-3438069b226a', 'a5ffcfa2-5226-49bf-93e7-56a41a1b6ee5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('868a01ce-73ae-4ec8-8420-3438069b226a', 'b32c8f82-223c-4155-bbf0-24b530112f70', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('868a01ce-73ae-4ec8-8420-3438069b226a', '9ac14b98-c4dd-4623-a59f-ac19f520b55f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('868a01ce-73ae-4ec8-8420-3438069b226a', '5492f0ed-7e71-4f77-82e6-a4124f51a41f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('868a01ce-73ae-4ec8-8420-3438069b226a', '648db100-eb32-4fe6-bd00-dd291eb54f6e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('338059f8-483f-462b-8cba-7f0835288096', 'a5ffcfa2-5226-49bf-93e7-56a41a1b6ee5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('338059f8-483f-462b-8cba-7f0835288096', 'b32c8f82-223c-4155-bbf0-24b530112f70', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('338059f8-483f-462b-8cba-7f0835288096', '9ac14b98-c4dd-4623-a59f-ac19f520b55f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('338059f8-483f-462b-8cba-7f0835288096', '5492f0ed-7e71-4f77-82e6-a4124f51a41f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('338059f8-483f-462b-8cba-7f0835288096', '648db100-eb32-4fe6-bd00-dd291eb54f6e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1d5bb381-148f-4f39-b287-598b1f1d5877', '6d2ee86e-5526-46a3-bb87-50ed37ccf759', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1d5bb381-148f-4f39-b287-598b1f1d5877', '64fde419-092c-4c18-9eda-d76843d18ac4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1d5bb381-148f-4f39-b287-598b1f1d5877', 'a5ffcfa2-5226-49bf-93e7-56a41a1b6ee5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1d5bb381-148f-4f39-b287-598b1f1d5877', 'b32c8f82-223c-4155-bbf0-24b530112f70', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1d5bb381-148f-4f39-b287-598b1f1d5877', '9ac14b98-c4dd-4623-a59f-ac19f520b55f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6d2ee86e-5526-46a3-bb87-50ed37ccf759', '1d5bb381-148f-4f39-b287-598b1f1d5877', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6d2ee86e-5526-46a3-bb87-50ed37ccf759', '64fde419-092c-4c18-9eda-d76843d18ac4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6d2ee86e-5526-46a3-bb87-50ed37ccf759', 'a5ffcfa2-5226-49bf-93e7-56a41a1b6ee5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6d2ee86e-5526-46a3-bb87-50ed37ccf759', 'b32c8f82-223c-4155-bbf0-24b530112f70', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6d2ee86e-5526-46a3-bb87-50ed37ccf759', '9ac14b98-c4dd-4623-a59f-ac19f520b55f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('64fde419-092c-4c18-9eda-d76843d18ac4', '1d5bb381-148f-4f39-b287-598b1f1d5877', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('64fde419-092c-4c18-9eda-d76843d18ac4', '6d2ee86e-5526-46a3-bb87-50ed37ccf759', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('64fde419-092c-4c18-9eda-d76843d18ac4', 'a5ffcfa2-5226-49bf-93e7-56a41a1b6ee5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('64fde419-092c-4c18-9eda-d76843d18ac4', 'b32c8f82-223c-4155-bbf0-24b530112f70', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('64fde419-092c-4c18-9eda-d76843d18ac4', '9ac14b98-c4dd-4623-a59f-ac19f520b55f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a90e872-f186-483b-87a0-6cbb593527f4', 'a5ffcfa2-5226-49bf-93e7-56a41a1b6ee5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a90e872-f186-483b-87a0-6cbb593527f4', 'b32c8f82-223c-4155-bbf0-24b530112f70', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a90e872-f186-483b-87a0-6cbb593527f4', '9ac14b98-c4dd-4623-a59f-ac19f520b55f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a90e872-f186-483b-87a0-6cbb593527f4', '5492f0ed-7e71-4f77-82e6-a4124f51a41f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a90e872-f186-483b-87a0-6cbb593527f4', '648db100-eb32-4fe6-bd00-dd291eb54f6e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bf10d9fb-1d7d-4de2-a222-86db4851a62e', 'ec8533f0-ba69-470a-a504-8b139dc97ea7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bf10d9fb-1d7d-4de2-a222-86db4851a62e', 'a5ffcfa2-5226-49bf-93e7-56a41a1b6ee5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bf10d9fb-1d7d-4de2-a222-86db4851a62e', 'b32c8f82-223c-4155-bbf0-24b530112f70', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4133ff3c-7d19-4c81-a4b9-7a7dfb0f485a', 'a5ffcfa2-5226-49bf-93e7-56a41a1b6ee5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4133ff3c-7d19-4c81-a4b9-7a7dfb0f485a', 'b32c8f82-223c-4155-bbf0-24b530112f70', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4133ff3c-7d19-4c81-a4b9-7a7dfb0f485a', '9ac14b98-c4dd-4623-a59f-ac19f520b55f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4133ff3c-7d19-4c81-a4b9-7a7dfb0f485a', '5492f0ed-7e71-4f77-82e6-a4124f51a41f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4133ff3c-7d19-4c81-a4b9-7a7dfb0f485a', '648db100-eb32-4fe6-bd00-dd291eb54f6e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ec8533f0-ba69-470a-a504-8b139dc97ea7', 'bf10d9fb-1d7d-4de2-a222-86db4851a62e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ec8533f0-ba69-470a-a504-8b139dc97ea7', 'a5ffcfa2-5226-49bf-93e7-56a41a1b6ee5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ec8533f0-ba69-470a-a504-8b139dc97ea7', 'b32c8f82-223c-4155-bbf0-24b530112f70', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ec349418-962d-4ae4-ad90-dbe24ced58a6', 'a5ffcfa2-5226-49bf-93e7-56a41a1b6ee5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ec349418-962d-4ae4-ad90-dbe24ced58a6', 'b32c8f82-223c-4155-bbf0-24b530112f70', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ec349418-962d-4ae4-ad90-dbe24ced58a6', '9ac14b98-c4dd-4623-a59f-ac19f520b55f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ec349418-962d-4ae4-ad90-dbe24ced58a6', '5492f0ed-7e71-4f77-82e6-a4124f51a41f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ec349418-962d-4ae4-ad90-dbe24ced58a6', '648db100-eb32-4fe6-bd00-dd291eb54f6e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('35bb217b-f21c-4203-a77d-c6ec09c5d999', 'a5ffcfa2-5226-49bf-93e7-56a41a1b6ee5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('35bb217b-f21c-4203-a77d-c6ec09c5d999', 'b32c8f82-223c-4155-bbf0-24b530112f70', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('35bb217b-f21c-4203-a77d-c6ec09c5d999', '9ac14b98-c4dd-4623-a59f-ac19f520b55f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('35bb217b-f21c-4203-a77d-c6ec09c5d999', '5492f0ed-7e71-4f77-82e6-a4124f51a41f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('35bb217b-f21c-4203-a77d-c6ec09c5d999', '648db100-eb32-4fe6-bd00-dd291eb54f6e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab543e71-14bc-4bfe-a204-fa2128f8bd7a', 'd3892f8c-cde2-4a72-a9b8-aac34503ea5c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab543e71-14bc-4bfe-a204-fa2128f8bd7a', '2293805d-f0e4-439d-97f1-ce114773c4ee', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab543e71-14bc-4bfe-a204-fa2128f8bd7a', '8ddf5228-f162-4df6-838f-9c2f195f9e4b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab543e71-14bc-4bfe-a204-fa2128f8bd7a', 'f7d20873-d1bb-4e09-b5f3-bc71f4571e53', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab543e71-14bc-4bfe-a204-fa2128f8bd7a', '33da7808-f971-4b4a-80df-1f3fff30d49c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3892f8c-cde2-4a72-a9b8-aac34503ea5c', 'ab543e71-14bc-4bfe-a204-fa2128f8bd7a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3892f8c-cde2-4a72-a9b8-aac34503ea5c', '2293805d-f0e4-439d-97f1-ce114773c4ee', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3892f8c-cde2-4a72-a9b8-aac34503ea5c', '8ddf5228-f162-4df6-838f-9c2f195f9e4b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3892f8c-cde2-4a72-a9b8-aac34503ea5c', 'f7d20873-d1bb-4e09-b5f3-bc71f4571e53', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3892f8c-cde2-4a72-a9b8-aac34503ea5c', '33da7808-f971-4b4a-80df-1f3fff30d49c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2293805d-f0e4-439d-97f1-ce114773c4ee', 'ab543e71-14bc-4bfe-a204-fa2128f8bd7a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2293805d-f0e4-439d-97f1-ce114773c4ee', 'd3892f8c-cde2-4a72-a9b8-aac34503ea5c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2293805d-f0e4-439d-97f1-ce114773c4ee', '8ddf5228-f162-4df6-838f-9c2f195f9e4b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2293805d-f0e4-439d-97f1-ce114773c4ee', 'f7d20873-d1bb-4e09-b5f3-bc71f4571e53', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2293805d-f0e4-439d-97f1-ce114773c4ee', '33da7808-f971-4b4a-80df-1f3fff30d49c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8ddf5228-f162-4df6-838f-9c2f195f9e4b', 'f7d20873-d1bb-4e09-b5f3-bc71f4571e53', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8ddf5228-f162-4df6-838f-9c2f195f9e4b', '33da7808-f971-4b4a-80df-1f3fff30d49c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8ddf5228-f162-4df6-838f-9c2f195f9e4b', '6ba8d117-2568-469c-ae47-589a7be25279', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8ddf5228-f162-4df6-838f-9c2f195f9e4b', '6d19b21d-f6ce-4735-abfd-048a7946a6f2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8ddf5228-f162-4df6-838f-9c2f195f9e4b', 'ca7d5a27-0db9-4be0-a63f-52d1241b72ce', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e842a599-6dbd-43bd-a558-291a897c2e3d', '64292438-933f-4266-9c75-d10f2cdfddfa', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e842a599-6dbd-43bd-a558-291a897c2e3d', '514e88b1-3e2e-4d27-bce7-c35f6da45b96', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e842a599-6dbd-43bd-a558-291a897c2e3d', '9fd7ddd9-3232-40c8-8461-1140cd59e550', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f7d20873-d1bb-4e09-b5f3-bc71f4571e53', '8ddf5228-f162-4df6-838f-9c2f195f9e4b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f7d20873-d1bb-4e09-b5f3-bc71f4571e53', '33da7808-f971-4b4a-80df-1f3fff30d49c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f7d20873-d1bb-4e09-b5f3-bc71f4571e53', '6ba8d117-2568-469c-ae47-589a7be25279', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f7d20873-d1bb-4e09-b5f3-bc71f4571e53', '6d19b21d-f6ce-4735-abfd-048a7946a6f2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f7d20873-d1bb-4e09-b5f3-bc71f4571e53', 'ca7d5a27-0db9-4be0-a63f-52d1241b72ce', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('33da7808-f971-4b4a-80df-1f3fff30d49c', '8ddf5228-f162-4df6-838f-9c2f195f9e4b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('33da7808-f971-4b4a-80df-1f3fff30d49c', 'f7d20873-d1bb-4e09-b5f3-bc71f4571e53', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('33da7808-f971-4b4a-80df-1f3fff30d49c', '6ba8d117-2568-469c-ae47-589a7be25279', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('33da7808-f971-4b4a-80df-1f3fff30d49c', '6d19b21d-f6ce-4735-abfd-048a7946a6f2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('33da7808-f971-4b4a-80df-1f3fff30d49c', 'ca7d5a27-0db9-4be0-a63f-52d1241b72ce', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6ba8d117-2568-469c-ae47-589a7be25279', '8ddf5228-f162-4df6-838f-9c2f195f9e4b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6ba8d117-2568-469c-ae47-589a7be25279', 'f7d20873-d1bb-4e09-b5f3-bc71f4571e53', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6ba8d117-2568-469c-ae47-589a7be25279', '33da7808-f971-4b4a-80df-1f3fff30d49c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6ba8d117-2568-469c-ae47-589a7be25279', '6d19b21d-f6ce-4735-abfd-048a7946a6f2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6ba8d117-2568-469c-ae47-589a7be25279', 'ca7d5a27-0db9-4be0-a63f-52d1241b72ce', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6d19b21d-f6ce-4735-abfd-048a7946a6f2', '8ddf5228-f162-4df6-838f-9c2f195f9e4b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6d19b21d-f6ce-4735-abfd-048a7946a6f2', 'f7d20873-d1bb-4e09-b5f3-bc71f4571e53', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6d19b21d-f6ce-4735-abfd-048a7946a6f2', '33da7808-f971-4b4a-80df-1f3fff30d49c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6d19b21d-f6ce-4735-abfd-048a7946a6f2', '6ba8d117-2568-469c-ae47-589a7be25279', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6d19b21d-f6ce-4735-abfd-048a7946a6f2', 'ca7d5a27-0db9-4be0-a63f-52d1241b72ce', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ca7d5a27-0db9-4be0-a63f-52d1241b72ce', '8ddf5228-f162-4df6-838f-9c2f195f9e4b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ca7d5a27-0db9-4be0-a63f-52d1241b72ce', 'f7d20873-d1bb-4e09-b5f3-bc71f4571e53', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ca7d5a27-0db9-4be0-a63f-52d1241b72ce', '33da7808-f971-4b4a-80df-1f3fff30d49c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ca7d5a27-0db9-4be0-a63f-52d1241b72ce', '6ba8d117-2568-469c-ae47-589a7be25279', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ca7d5a27-0db9-4be0-a63f-52d1241b72ce', '6d19b21d-f6ce-4735-abfd-048a7946a6f2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ccc5982a-fc78-4231-b69c-a43359bfa349', '8ddf5228-f162-4df6-838f-9c2f195f9e4b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ccc5982a-fc78-4231-b69c-a43359bfa349', 'f7d20873-d1bb-4e09-b5f3-bc71f4571e53', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ccc5982a-fc78-4231-b69c-a43359bfa349', '33da7808-f971-4b4a-80df-1f3fff30d49c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ccc5982a-fc78-4231-b69c-a43359bfa349', '6ba8d117-2568-469c-ae47-589a7be25279', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ccc5982a-fc78-4231-b69c-a43359bfa349', '6d19b21d-f6ce-4735-abfd-048a7946a6f2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9ffb7ec-3e1b-4002-8157-8634baa18751', '8ddf5228-f162-4df6-838f-9c2f195f9e4b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9ffb7ec-3e1b-4002-8157-8634baa18751', 'f7d20873-d1bb-4e09-b5f3-bc71f4571e53', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9ffb7ec-3e1b-4002-8157-8634baa18751', '33da7808-f971-4b4a-80df-1f3fff30d49c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9ffb7ec-3e1b-4002-8157-8634baa18751', '6ba8d117-2568-469c-ae47-589a7be25279', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9ffb7ec-3e1b-4002-8157-8634baa18751', '6d19b21d-f6ce-4735-abfd-048a7946a6f2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('43680478-f4f8-419c-b23e-954db698f4af', '8ddf5228-f162-4df6-838f-9c2f195f9e4b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('43680478-f4f8-419c-b23e-954db698f4af', 'f7d20873-d1bb-4e09-b5f3-bc71f4571e53', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('43680478-f4f8-419c-b23e-954db698f4af', '33da7808-f971-4b4a-80df-1f3fff30d49c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('43680478-f4f8-419c-b23e-954db698f4af', '6ba8d117-2568-469c-ae47-589a7be25279', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('43680478-f4f8-419c-b23e-954db698f4af', '6d19b21d-f6ce-4735-abfd-048a7946a6f2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('df340099-8985-433f-845a-344a5d1f0d3d', '8ddf5228-f162-4df6-838f-9c2f195f9e4b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('df340099-8985-433f-845a-344a5d1f0d3d', 'f7d20873-d1bb-4e09-b5f3-bc71f4571e53', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('df340099-8985-433f-845a-344a5d1f0d3d', '33da7808-f971-4b4a-80df-1f3fff30d49c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('df340099-8985-433f-845a-344a5d1f0d3d', '6ba8d117-2568-469c-ae47-589a7be25279', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('df340099-8985-433f-845a-344a5d1f0d3d', '6d19b21d-f6ce-4735-abfd-048a7946a6f2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b592f64e-8669-42d1-9b3b-d9c0739656f5', 'ab543e71-14bc-4bfe-a204-fa2128f8bd7a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b592f64e-8669-42d1-9b3b-d9c0739656f5', 'd3892f8c-cde2-4a72-a9b8-aac34503ea5c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b592f64e-8669-42d1-9b3b-d9c0739656f5', '2293805d-f0e4-439d-97f1-ce114773c4ee', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b592f64e-8669-42d1-9b3b-d9c0739656f5', '8ddf5228-f162-4df6-838f-9c2f195f9e4b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b592f64e-8669-42d1-9b3b-d9c0739656f5', 'f7d20873-d1bb-4e09-b5f3-bc71f4571e53', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('456b4a55-f0e5-45f7-93cb-9759079a5172', 'd5584576-f646-42dd-ae3f-e1c59ca66765', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('456b4a55-f0e5-45f7-93cb-9759079a5172', '80f170d1-d74a-45b4-a272-0df0310d1a42', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('456b4a55-f0e5-45f7-93cb-9759079a5172', 'a0a652bb-0a02-472f-88eb-b6ecdefc9722', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('456b4a55-f0e5-45f7-93cb-9759079a5172', '75ecf476-64f2-4681-98e4-8376f2b85fc4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('456b4a55-f0e5-45f7-93cb-9759079a5172', 'a952f34a-0bb7-4f3d-8616-8618994085de', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d5584576-f646-42dd-ae3f-e1c59ca66765', '456b4a55-f0e5-45f7-93cb-9759079a5172', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d5584576-f646-42dd-ae3f-e1c59ca66765', '80f170d1-d74a-45b4-a272-0df0310d1a42', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d5584576-f646-42dd-ae3f-e1c59ca66765', 'a0a652bb-0a02-472f-88eb-b6ecdefc9722', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d5584576-f646-42dd-ae3f-e1c59ca66765', '75ecf476-64f2-4681-98e4-8376f2b85fc4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d5584576-f646-42dd-ae3f-e1c59ca66765', 'a952f34a-0bb7-4f3d-8616-8618994085de', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba7fa653-2dc3-4b70-a797-144503684ffc', 'd5584576-f646-42dd-ae3f-e1c59ca66765', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba7fa653-2dc3-4b70-a797-144503684ffc', '456b4a55-f0e5-45f7-93cb-9759079a5172', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba7fa653-2dc3-4b70-a797-144503684ffc', '80f170d1-d74a-45b4-a272-0df0310d1a42', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba7fa653-2dc3-4b70-a797-144503684ffc', 'a0a652bb-0a02-472f-88eb-b6ecdefc9722', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba7fa653-2dc3-4b70-a797-144503684ffc', '75ecf476-64f2-4681-98e4-8376f2b85fc4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('80f170d1-d74a-45b4-a272-0df0310d1a42', 'ceb1dc9d-4590-4c20-8b73-663a45b3ebe3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('80f170d1-d74a-45b4-a272-0df0310d1a42', 'fbaa5b6b-ea32-4af0-84e6-e51c6fb645e9', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('80f170d1-d74a-45b4-a272-0df0310d1a42', '20a7b6d5-34df-4d0e-8b7e-8adb9a34296d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('80f170d1-d74a-45b4-a272-0df0310d1a42', '456b4a55-f0e5-45f7-93cb-9759079a5172', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('80f170d1-d74a-45b4-a272-0df0310d1a42', 'd5584576-f646-42dd-ae3f-e1c59ca66765', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0a652bb-0a02-472f-88eb-b6ecdefc9722', '75ecf476-64f2-4681-98e4-8376f2b85fc4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0a652bb-0a02-472f-88eb-b6ecdefc9722', 'a952f34a-0bb7-4f3d-8616-8618994085de', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0a652bb-0a02-472f-88eb-b6ecdefc9722', '92a33db2-5f5f-45e1-9038-bc11d6bf3951', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0a652bb-0a02-472f-88eb-b6ecdefc9722', 'b15232f8-f648-4d85-9206-513120fd76bd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0a652bb-0a02-472f-88eb-b6ecdefc9722', '456b4a55-f0e5-45f7-93cb-9759079a5172', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75ecf476-64f2-4681-98e4-8376f2b85fc4', 'a0a652bb-0a02-472f-88eb-b6ecdefc9722', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75ecf476-64f2-4681-98e4-8376f2b85fc4', 'a952f34a-0bb7-4f3d-8616-8618994085de', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75ecf476-64f2-4681-98e4-8376f2b85fc4', '92a33db2-5f5f-45e1-9038-bc11d6bf3951', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75ecf476-64f2-4681-98e4-8376f2b85fc4', 'b15232f8-f648-4d85-9206-513120fd76bd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75ecf476-64f2-4681-98e4-8376f2b85fc4', '456b4a55-f0e5-45f7-93cb-9759079a5172', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a952f34a-0bb7-4f3d-8616-8618994085de', 'a0a652bb-0a02-472f-88eb-b6ecdefc9722', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a952f34a-0bb7-4f3d-8616-8618994085de', '75ecf476-64f2-4681-98e4-8376f2b85fc4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a952f34a-0bb7-4f3d-8616-8618994085de', '92a33db2-5f5f-45e1-9038-bc11d6bf3951', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a952f34a-0bb7-4f3d-8616-8618994085de', 'b15232f8-f648-4d85-9206-513120fd76bd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a952f34a-0bb7-4f3d-8616-8618994085de', '456b4a55-f0e5-45f7-93cb-9759079a5172', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ceb1dc9d-4590-4c20-8b73-663a45b3ebe3', '80f170d1-d74a-45b4-a272-0df0310d1a42', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ceb1dc9d-4590-4c20-8b73-663a45b3ebe3', 'fbaa5b6b-ea32-4af0-84e6-e51c6fb645e9', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ceb1dc9d-4590-4c20-8b73-663a45b3ebe3', '20a7b6d5-34df-4d0e-8b7e-8adb9a34296d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ceb1dc9d-4590-4c20-8b73-663a45b3ebe3', '456b4a55-f0e5-45f7-93cb-9759079a5172', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ceb1dc9d-4590-4c20-8b73-663a45b3ebe3', 'd5584576-f646-42dd-ae3f-e1c59ca66765', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fbaa5b6b-ea32-4af0-84e6-e51c6fb645e9', '80f170d1-d74a-45b4-a272-0df0310d1a42', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fbaa5b6b-ea32-4af0-84e6-e51c6fb645e9', 'ceb1dc9d-4590-4c20-8b73-663a45b3ebe3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fbaa5b6b-ea32-4af0-84e6-e51c6fb645e9', '20a7b6d5-34df-4d0e-8b7e-8adb9a34296d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fbaa5b6b-ea32-4af0-84e6-e51c6fb645e9', '456b4a55-f0e5-45f7-93cb-9759079a5172', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fbaa5b6b-ea32-4af0-84e6-e51c6fb645e9', 'd5584576-f646-42dd-ae3f-e1c59ca66765', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('92a33db2-5f5f-45e1-9038-bc11d6bf3951', 'a0a652bb-0a02-472f-88eb-b6ecdefc9722', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('92a33db2-5f5f-45e1-9038-bc11d6bf3951', '75ecf476-64f2-4681-98e4-8376f2b85fc4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('92a33db2-5f5f-45e1-9038-bc11d6bf3951', 'a952f34a-0bb7-4f3d-8616-8618994085de', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('92a33db2-5f5f-45e1-9038-bc11d6bf3951', 'b15232f8-f648-4d85-9206-513120fd76bd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('92a33db2-5f5f-45e1-9038-bc11d6bf3951', '456b4a55-f0e5-45f7-93cb-9759079a5172', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b15232f8-f648-4d85-9206-513120fd76bd', 'a0a652bb-0a02-472f-88eb-b6ecdefc9722', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b15232f8-f648-4d85-9206-513120fd76bd', '75ecf476-64f2-4681-98e4-8376f2b85fc4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b15232f8-f648-4d85-9206-513120fd76bd', 'a952f34a-0bb7-4f3d-8616-8618994085de', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b15232f8-f648-4d85-9206-513120fd76bd', '92a33db2-5f5f-45e1-9038-bc11d6bf3951', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b15232f8-f648-4d85-9206-513120fd76bd', '456b4a55-f0e5-45f7-93cb-9759079a5172', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('20a7b6d5-34df-4d0e-8b7e-8adb9a34296d', '80f170d1-d74a-45b4-a272-0df0310d1a42', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('20a7b6d5-34df-4d0e-8b7e-8adb9a34296d', 'ceb1dc9d-4590-4c20-8b73-663a45b3ebe3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('20a7b6d5-34df-4d0e-8b7e-8adb9a34296d', 'fbaa5b6b-ea32-4af0-84e6-e51c6fb645e9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('20a7b6d5-34df-4d0e-8b7e-8adb9a34296d', '456b4a55-f0e5-45f7-93cb-9759079a5172', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('20a7b6d5-34df-4d0e-8b7e-8adb9a34296d', 'd5584576-f646-42dd-ae3f-e1c59ca66765', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dfc42312-c8c4-485f-9f74-494bd4efc0b2', '8ddf5228-f162-4df6-838f-9c2f195f9e4b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dfc42312-c8c4-485f-9f74-494bd4efc0b2', 'f7d20873-d1bb-4e09-b5f3-bc71f4571e53', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dfc42312-c8c4-485f-9f74-494bd4efc0b2', '33da7808-f971-4b4a-80df-1f3fff30d49c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dfc42312-c8c4-485f-9f74-494bd4efc0b2', '6ba8d117-2568-469c-ae47-589a7be25279', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dfc42312-c8c4-485f-9f74-494bd4efc0b2', '6d19b21d-f6ce-4735-abfd-048a7946a6f2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('862040b0-1341-422d-93e3-8041b416f0f8', 'ab543e71-14bc-4bfe-a204-fa2128f8bd7a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('862040b0-1341-422d-93e3-8041b416f0f8', 'd3892f8c-cde2-4a72-a9b8-aac34503ea5c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('862040b0-1341-422d-93e3-8041b416f0f8', '2293805d-f0e4-439d-97f1-ce114773c4ee', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('514e88b1-3e2e-4d27-bce7-c35f6da45b96', '9fd7ddd9-3232-40c8-8461-1140cd59e550', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('514e88b1-3e2e-4d27-bce7-c35f6da45b96', 'e9c1aa41-a26e-41ea-954d-cd371d69a917', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('514e88b1-3e2e-4d27-bce7-c35f6da45b96', '4aed78e1-2a10-488a-ba70-7ef1d3970894', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9fd7ddd9-3232-40c8-8461-1140cd59e550', '514e88b1-3e2e-4d27-bce7-c35f6da45b96', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9fd7ddd9-3232-40c8-8461-1140cd59e550', 'e9c1aa41-a26e-41ea-954d-cd371d69a917', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9fd7ddd9-3232-40c8-8461-1140cd59e550', '4aed78e1-2a10-488a-ba70-7ef1d3970894', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e9c1aa41-a26e-41ea-954d-cd371d69a917', '514e88b1-3e2e-4d27-bce7-c35f6da45b96', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e9c1aa41-a26e-41ea-954d-cd371d69a917', '9fd7ddd9-3232-40c8-8461-1140cd59e550', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e9c1aa41-a26e-41ea-954d-cd371d69a917', '4aed78e1-2a10-488a-ba70-7ef1d3970894', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4aed78e1-2a10-488a-ba70-7ef1d3970894', '514e88b1-3e2e-4d27-bce7-c35f6da45b96', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4aed78e1-2a10-488a-ba70-7ef1d3970894', '9fd7ddd9-3232-40c8-8461-1140cd59e550', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4aed78e1-2a10-488a-ba70-7ef1d3970894', 'e9c1aa41-a26e-41ea-954d-cd371d69a917', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('764fab0c-62f1-450b-9957-1a54615bc4c5', 'f064bd74-6afd-41e9-aebb-1f87682cd5d7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('764fab0c-62f1-450b-9957-1a54615bc4c5', 'c4c13885-e459-4a64-bcf5-00f14de1c1e5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('764fab0c-62f1-450b-9957-1a54615bc4c5', 'c11de669-d0a2-4a5d-9b00-592e4c75ce2d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('764fab0c-62f1-450b-9957-1a54615bc4c5', '5108b424-f551-4e22-836d-ab6d747c5256', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('764fab0c-62f1-450b-9957-1a54615bc4c5', 'a6e664e7-852a-4f1b-b657-6a6c0066d726', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f064bd74-6afd-41e9-aebb-1f87682cd5d7', '764fab0c-62f1-450b-9957-1a54615bc4c5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f064bd74-6afd-41e9-aebb-1f87682cd5d7', 'c4c13885-e459-4a64-bcf5-00f14de1c1e5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f064bd74-6afd-41e9-aebb-1f87682cd5d7', 'c11de669-d0a2-4a5d-9b00-592e4c75ce2d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f064bd74-6afd-41e9-aebb-1f87682cd5d7', '5108b424-f551-4e22-836d-ab6d747c5256', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f064bd74-6afd-41e9-aebb-1f87682cd5d7', 'a6e664e7-852a-4f1b-b657-6a6c0066d726', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c4c13885-e459-4a64-bcf5-00f14de1c1e5', '764fab0c-62f1-450b-9957-1a54615bc4c5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c4c13885-e459-4a64-bcf5-00f14de1c1e5', 'f064bd74-6afd-41e9-aebb-1f87682cd5d7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c4c13885-e459-4a64-bcf5-00f14de1c1e5', 'c11de669-d0a2-4a5d-9b00-592e4c75ce2d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c4c13885-e459-4a64-bcf5-00f14de1c1e5', '5108b424-f551-4e22-836d-ab6d747c5256', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c4c13885-e459-4a64-bcf5-00f14de1c1e5', 'a6e664e7-852a-4f1b-b657-6a6c0066d726', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c11de669-d0a2-4a5d-9b00-592e4c75ce2d', '764fab0c-62f1-450b-9957-1a54615bc4c5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c11de669-d0a2-4a5d-9b00-592e4c75ce2d', 'f064bd74-6afd-41e9-aebb-1f87682cd5d7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c11de669-d0a2-4a5d-9b00-592e4c75ce2d', 'c4c13885-e459-4a64-bcf5-00f14de1c1e5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c11de669-d0a2-4a5d-9b00-592e4c75ce2d', '5108b424-f551-4e22-836d-ab6d747c5256', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c11de669-d0a2-4a5d-9b00-592e4c75ce2d', 'a6e664e7-852a-4f1b-b657-6a6c0066d726', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ceeb3b27-ae99-4d35-8cd0-54a4413722e5', '3e12e648-6998-4d62-a076-219217b90a39', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ceeb3b27-ae99-4d35-8cd0-54a4413722e5', '764fab0c-62f1-450b-9957-1a54615bc4c5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ceeb3b27-ae99-4d35-8cd0-54a4413722e5', 'f064bd74-6afd-41e9-aebb-1f87682cd5d7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ceeb3b27-ae99-4d35-8cd0-54a4413722e5', 'c4c13885-e459-4a64-bcf5-00f14de1c1e5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ceeb3b27-ae99-4d35-8cd0-54a4413722e5', 'c11de669-d0a2-4a5d-9b00-592e4c75ce2d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3e12e648-6998-4d62-a076-219217b90a39', 'ceeb3b27-ae99-4d35-8cd0-54a4413722e5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3e12e648-6998-4d62-a076-219217b90a39', '764fab0c-62f1-450b-9957-1a54615bc4c5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3e12e648-6998-4d62-a076-219217b90a39', 'f064bd74-6afd-41e9-aebb-1f87682cd5d7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3e12e648-6998-4d62-a076-219217b90a39', 'c4c13885-e459-4a64-bcf5-00f14de1c1e5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3e12e648-6998-4d62-a076-219217b90a39', 'c11de669-d0a2-4a5d-9b00-592e4c75ce2d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5108b424-f551-4e22-836d-ab6d747c5256', '764fab0c-62f1-450b-9957-1a54615bc4c5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5108b424-f551-4e22-836d-ab6d747c5256', 'f064bd74-6afd-41e9-aebb-1f87682cd5d7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5108b424-f551-4e22-836d-ab6d747c5256', 'c4c13885-e459-4a64-bcf5-00f14de1c1e5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5108b424-f551-4e22-836d-ab6d747c5256', 'c11de669-d0a2-4a5d-9b00-592e4c75ce2d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5108b424-f551-4e22-836d-ab6d747c5256', 'a6e664e7-852a-4f1b-b657-6a6c0066d726', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6e664e7-852a-4f1b-b657-6a6c0066d726', '764fab0c-62f1-450b-9957-1a54615bc4c5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6e664e7-852a-4f1b-b657-6a6c0066d726', 'f064bd74-6afd-41e9-aebb-1f87682cd5d7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6e664e7-852a-4f1b-b657-6a6c0066d726', 'c4c13885-e459-4a64-bcf5-00f14de1c1e5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6e664e7-852a-4f1b-b657-6a6c0066d726', 'c11de669-d0a2-4a5d-9b00-592e4c75ce2d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6e664e7-852a-4f1b-b657-6a6c0066d726', '5108b424-f551-4e22-836d-ab6d747c5256', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('234b1cc6-05a4-4e6a-8578-6d3ce634ace2', 'e842a599-6dbd-43bd-a558-291a897c2e3d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('234b1cc6-05a4-4e6a-8578-6d3ce634ace2', '514e88b1-3e2e-4d27-bce7-c35f6da45b96', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('234b1cc6-05a4-4e6a-8578-6d3ce634ace2', '9fd7ddd9-3232-40c8-8461-1140cd59e550', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0d305d36-717f-4476-8be5-7410191ba6c3', '764fab0c-62f1-450b-9957-1a54615bc4c5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0d305d36-717f-4476-8be5-7410191ba6c3', 'f064bd74-6afd-41e9-aebb-1f87682cd5d7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0d305d36-717f-4476-8be5-7410191ba6c3', 'c4c13885-e459-4a64-bcf5-00f14de1c1e5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0d305d36-717f-4476-8be5-7410191ba6c3', 'c11de669-d0a2-4a5d-9b00-592e4c75ce2d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0d305d36-717f-4476-8be5-7410191ba6c3', 'ceeb3b27-ae99-4d35-8cd0-54a4413722e5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('64292438-933f-4266-9c75-d10f2cdfddfa', 'e842a599-6dbd-43bd-a558-291a897c2e3d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('64292438-933f-4266-9c75-d10f2cdfddfa', '514e88b1-3e2e-4d27-bce7-c35f6da45b96', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('64292438-933f-4266-9c75-d10f2cdfddfa', '9fd7ddd9-3232-40c8-8461-1140cd59e550', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19ae3673-f754-4e4d-9f44-58264be6e401', 'e075ad54-ac04-4a1e-a1b1-a5ff7cbf5ad2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19ae3673-f754-4e4d-9f44-58264be6e401', 'd922ffb8-6e33-41fc-a32b-945a4fcfc6ad', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19ae3673-f754-4e4d-9f44-58264be6e401', 'c9fbb028-b4cf-40e4-83eb-84ced28c32b2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19ae3673-f754-4e4d-9f44-58264be6e401', '51b4f866-444e-4c32-a370-fc4c526d8543', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19ae3673-f754-4e4d-9f44-58264be6e401', '5904e8c9-45fa-447f-a58c-e6395d98c639', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('61504d7f-840d-4ba7-b5b6-4bc898a1c5b8', '1656fb81-ec82-41db-95e4-3a042666a6b6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('61504d7f-840d-4ba7-b5b6-4bc898a1c5b8', '19ae3673-f754-4e4d-9f44-58264be6e401', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('61504d7f-840d-4ba7-b5b6-4bc898a1c5b8', 'e075ad54-ac04-4a1e-a1b1-a5ff7cbf5ad2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('61504d7f-840d-4ba7-b5b6-4bc898a1c5b8', 'd922ffb8-6e33-41fc-a32b-945a4fcfc6ad', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('61504d7f-840d-4ba7-b5b6-4bc898a1c5b8', 'c9fbb028-b4cf-40e4-83eb-84ced28c32b2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e075ad54-ac04-4a1e-a1b1-a5ff7cbf5ad2', '19ae3673-f754-4e4d-9f44-58264be6e401', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e075ad54-ac04-4a1e-a1b1-a5ff7cbf5ad2', 'd922ffb8-6e33-41fc-a32b-945a4fcfc6ad', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e075ad54-ac04-4a1e-a1b1-a5ff7cbf5ad2', 'c9fbb028-b4cf-40e4-83eb-84ced28c32b2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e075ad54-ac04-4a1e-a1b1-a5ff7cbf5ad2', '51b4f866-444e-4c32-a370-fc4c526d8543', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e075ad54-ac04-4a1e-a1b1-a5ff7cbf5ad2', '5904e8c9-45fa-447f-a58c-e6395d98c639', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d922ffb8-6e33-41fc-a32b-945a4fcfc6ad', '19ae3673-f754-4e4d-9f44-58264be6e401', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d922ffb8-6e33-41fc-a32b-945a4fcfc6ad', 'e075ad54-ac04-4a1e-a1b1-a5ff7cbf5ad2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d922ffb8-6e33-41fc-a32b-945a4fcfc6ad', 'c9fbb028-b4cf-40e4-83eb-84ced28c32b2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d922ffb8-6e33-41fc-a32b-945a4fcfc6ad', '51b4f866-444e-4c32-a370-fc4c526d8543', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d922ffb8-6e33-41fc-a32b-945a4fcfc6ad', '5904e8c9-45fa-447f-a58c-e6395d98c639', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9fbb028-b4cf-40e4-83eb-84ced28c32b2', '19ae3673-f754-4e4d-9f44-58264be6e401', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9fbb028-b4cf-40e4-83eb-84ced28c32b2', 'e075ad54-ac04-4a1e-a1b1-a5ff7cbf5ad2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9fbb028-b4cf-40e4-83eb-84ced28c32b2', 'd922ffb8-6e33-41fc-a32b-945a4fcfc6ad', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9fbb028-b4cf-40e4-83eb-84ced28c32b2', '51b4f866-444e-4c32-a370-fc4c526d8543', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9fbb028-b4cf-40e4-83eb-84ced28c32b2', '5904e8c9-45fa-447f-a58c-e6395d98c639', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('51b4f866-444e-4c32-a370-fc4c526d8543', '19ae3673-f754-4e4d-9f44-58264be6e401', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('51b4f866-444e-4c32-a370-fc4c526d8543', 'e075ad54-ac04-4a1e-a1b1-a5ff7cbf5ad2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('51b4f866-444e-4c32-a370-fc4c526d8543', 'd922ffb8-6e33-41fc-a32b-945a4fcfc6ad', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('51b4f866-444e-4c32-a370-fc4c526d8543', 'c9fbb028-b4cf-40e4-83eb-84ced28c32b2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('51b4f866-444e-4c32-a370-fc4c526d8543', '5904e8c9-45fa-447f-a58c-e6395d98c639', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5904e8c9-45fa-447f-a58c-e6395d98c639', '19ae3673-f754-4e4d-9f44-58264be6e401', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5904e8c9-45fa-447f-a58c-e6395d98c639', 'e075ad54-ac04-4a1e-a1b1-a5ff7cbf5ad2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5904e8c9-45fa-447f-a58c-e6395d98c639', 'd922ffb8-6e33-41fc-a32b-945a4fcfc6ad', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5904e8c9-45fa-447f-a58c-e6395d98c639', 'c9fbb028-b4cf-40e4-83eb-84ced28c32b2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5904e8c9-45fa-447f-a58c-e6395d98c639', '51b4f866-444e-4c32-a370-fc4c526d8543', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ea9645ce-ea25-4ed3-a3dd-e18b634799e9', '2029e9c7-d4f5-47d8-9479-453ebd127e4f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ea9645ce-ea25-4ed3-a3dd-e18b634799e9', '19ae3673-f754-4e4d-9f44-58264be6e401', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ea9645ce-ea25-4ed3-a3dd-e18b634799e9', '61504d7f-840d-4ba7-b5b6-4bc898a1c5b8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ea9645ce-ea25-4ed3-a3dd-e18b634799e9', 'e075ad54-ac04-4a1e-a1b1-a5ff7cbf5ad2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ea9645ce-ea25-4ed3-a3dd-e18b634799e9', 'd922ffb8-6e33-41fc-a32b-945a4fcfc6ad', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2029e9c7-d4f5-47d8-9479-453ebd127e4f', 'ea9645ce-ea25-4ed3-a3dd-e18b634799e9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2029e9c7-d4f5-47d8-9479-453ebd127e4f', '19ae3673-f754-4e4d-9f44-58264be6e401', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2029e9c7-d4f5-47d8-9479-453ebd127e4f', '61504d7f-840d-4ba7-b5b6-4bc898a1c5b8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2029e9c7-d4f5-47d8-9479-453ebd127e4f', 'e075ad54-ac04-4a1e-a1b1-a5ff7cbf5ad2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2029e9c7-d4f5-47d8-9479-453ebd127e4f', 'd922ffb8-6e33-41fc-a32b-945a4fcfc6ad', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2f6233de-4ed4-4b59-9bec-90963c8839c0', '19ae3673-f754-4e4d-9f44-58264be6e401', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2f6233de-4ed4-4b59-9bec-90963c8839c0', 'e075ad54-ac04-4a1e-a1b1-a5ff7cbf5ad2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2f6233de-4ed4-4b59-9bec-90963c8839c0', 'd922ffb8-6e33-41fc-a32b-945a4fcfc6ad', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2f6233de-4ed4-4b59-9bec-90963c8839c0', 'c9fbb028-b4cf-40e4-83eb-84ced28c32b2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2f6233de-4ed4-4b59-9bec-90963c8839c0', '51b4f866-444e-4c32-a370-fc4c526d8543', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9d61a757-4cfa-46b6-8bdb-d01ea297e1e5', '19ae3673-f754-4e4d-9f44-58264be6e401', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9d61a757-4cfa-46b6-8bdb-d01ea297e1e5', 'e075ad54-ac04-4a1e-a1b1-a5ff7cbf5ad2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9d61a757-4cfa-46b6-8bdb-d01ea297e1e5', 'd922ffb8-6e33-41fc-a32b-945a4fcfc6ad', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9d61a757-4cfa-46b6-8bdb-d01ea297e1e5', 'c9fbb028-b4cf-40e4-83eb-84ced28c32b2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9d61a757-4cfa-46b6-8bdb-d01ea297e1e5', '51b4f866-444e-4c32-a370-fc4c526d8543', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1656fb81-ec82-41db-95e4-3a042666a6b6', '61504d7f-840d-4ba7-b5b6-4bc898a1c5b8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1656fb81-ec82-41db-95e4-3a042666a6b6', '19ae3673-f754-4e4d-9f44-58264be6e401', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1656fb81-ec82-41db-95e4-3a042666a6b6', 'e075ad54-ac04-4a1e-a1b1-a5ff7cbf5ad2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1656fb81-ec82-41db-95e4-3a042666a6b6', 'd922ffb8-6e33-41fc-a32b-945a4fcfc6ad', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1656fb81-ec82-41db-95e4-3a042666a6b6', 'c9fbb028-b4cf-40e4-83eb-84ced28c32b2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('abed783c-9fa3-4e9e-8563-99a151fd7ca2', '19ae3673-f754-4e4d-9f44-58264be6e401', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('abed783c-9fa3-4e9e-8563-99a151fd7ca2', 'e075ad54-ac04-4a1e-a1b1-a5ff7cbf5ad2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('abed783c-9fa3-4e9e-8563-99a151fd7ca2', 'd922ffb8-6e33-41fc-a32b-945a4fcfc6ad', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('abed783c-9fa3-4e9e-8563-99a151fd7ca2', 'c9fbb028-b4cf-40e4-83eb-84ced28c32b2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('abed783c-9fa3-4e9e-8563-99a151fd7ca2', '51b4f866-444e-4c32-a370-fc4c526d8543', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8c606057-4484-4556-a963-18fac5fd2ced', 'c395d459-2803-47dc-9e25-88dc8c122699', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8c606057-4484-4556-a963-18fac5fd2ced', '089da09b-0af2-4971-8ac8-56ec28b1d8b8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8c606057-4484-4556-a963-18fac5fd2ced', '0f33799d-70d5-4c31-896a-8089eabd8bd4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8c606057-4484-4556-a963-18fac5fd2ced', '201cfb9c-f42f-4cc7-88f9-a04603b4e886', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8c606057-4484-4556-a963-18fac5fd2ced', '6202b592-6a50-4b3f-a34f-82ebabeee289', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('089da09b-0af2-4971-8ac8-56ec28b1d8b8', '8c606057-4484-4556-a963-18fac5fd2ced', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('089da09b-0af2-4971-8ac8-56ec28b1d8b8', '0f33799d-70d5-4c31-896a-8089eabd8bd4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('089da09b-0af2-4971-8ac8-56ec28b1d8b8', '201cfb9c-f42f-4cc7-88f9-a04603b4e886', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('089da09b-0af2-4971-8ac8-56ec28b1d8b8', '6202b592-6a50-4b3f-a34f-82ebabeee289', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('089da09b-0af2-4971-8ac8-56ec28b1d8b8', 'fd168b7c-829c-4573-a64e-a54eae785a80', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0f33799d-70d5-4c31-896a-8089eabd8bd4', '8c606057-4484-4556-a963-18fac5fd2ced', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0f33799d-70d5-4c31-896a-8089eabd8bd4', '089da09b-0af2-4971-8ac8-56ec28b1d8b8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0f33799d-70d5-4c31-896a-8089eabd8bd4', '201cfb9c-f42f-4cc7-88f9-a04603b4e886', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0f33799d-70d5-4c31-896a-8089eabd8bd4', '6202b592-6a50-4b3f-a34f-82ebabeee289', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0f33799d-70d5-4c31-896a-8089eabd8bd4', 'fd168b7c-829c-4573-a64e-a54eae785a80', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('201cfb9c-f42f-4cc7-88f9-a04603b4e886', '6202b592-6a50-4b3f-a34f-82ebabeee289', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('201cfb9c-f42f-4cc7-88f9-a04603b4e886', 'fd168b7c-829c-4573-a64e-a54eae785a80', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('201cfb9c-f42f-4cc7-88f9-a04603b4e886', '2a73d120-3fff-44ee-8afd-c262b16b7a5f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('201cfb9c-f42f-4cc7-88f9-a04603b4e886', '8c606057-4484-4556-a963-18fac5fd2ced', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('201cfb9c-f42f-4cc7-88f9-a04603b4e886', '089da09b-0af2-4971-8ac8-56ec28b1d8b8', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6202b592-6a50-4b3f-a34f-82ebabeee289', '201cfb9c-f42f-4cc7-88f9-a04603b4e886', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6202b592-6a50-4b3f-a34f-82ebabeee289', 'fd168b7c-829c-4573-a64e-a54eae785a80', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6202b592-6a50-4b3f-a34f-82ebabeee289', '2a73d120-3fff-44ee-8afd-c262b16b7a5f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6202b592-6a50-4b3f-a34f-82ebabeee289', '8c606057-4484-4556-a963-18fac5fd2ced', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6202b592-6a50-4b3f-a34f-82ebabeee289', '089da09b-0af2-4971-8ac8-56ec28b1d8b8', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fd168b7c-829c-4573-a64e-a54eae785a80', '201cfb9c-f42f-4cc7-88f9-a04603b4e886', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fd168b7c-829c-4573-a64e-a54eae785a80', '6202b592-6a50-4b3f-a34f-82ebabeee289', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fd168b7c-829c-4573-a64e-a54eae785a80', '2a73d120-3fff-44ee-8afd-c262b16b7a5f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fd168b7c-829c-4573-a64e-a54eae785a80', '8c606057-4484-4556-a963-18fac5fd2ced', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fd168b7c-829c-4573-a64e-a54eae785a80', '089da09b-0af2-4971-8ac8-56ec28b1d8b8', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2a73d120-3fff-44ee-8afd-c262b16b7a5f', '201cfb9c-f42f-4cc7-88f9-a04603b4e886', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2a73d120-3fff-44ee-8afd-c262b16b7a5f', '6202b592-6a50-4b3f-a34f-82ebabeee289', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2a73d120-3fff-44ee-8afd-c262b16b7a5f', 'fd168b7c-829c-4573-a64e-a54eae785a80', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2a73d120-3fff-44ee-8afd-c262b16b7a5f', '8c606057-4484-4556-a963-18fac5fd2ced', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2a73d120-3fff-44ee-8afd-c262b16b7a5f', '089da09b-0af2-4971-8ac8-56ec28b1d8b8', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c395d459-2803-47dc-9e25-88dc8c122699', '8c606057-4484-4556-a963-18fac5fd2ced', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c395d459-2803-47dc-9e25-88dc8c122699', '089da09b-0af2-4971-8ac8-56ec28b1d8b8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c395d459-2803-47dc-9e25-88dc8c122699', '0f33799d-70d5-4c31-896a-8089eabd8bd4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c395d459-2803-47dc-9e25-88dc8c122699', '201cfb9c-f42f-4cc7-88f9-a04603b4e886', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c395d459-2803-47dc-9e25-88dc8c122699', '6202b592-6a50-4b3f-a34f-82ebabeee289', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d8b9fe3b-269a-45f1-8701-5f23f4fcff82', '8c606057-4484-4556-a963-18fac5fd2ced', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d8b9fe3b-269a-45f1-8701-5f23f4fcff82', '089da09b-0af2-4971-8ac8-56ec28b1d8b8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d8b9fe3b-269a-45f1-8701-5f23f4fcff82', '0f33799d-70d5-4c31-896a-8089eabd8bd4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a7523b1f-0051-4639-be7d-78b53959a169', '8c606057-4484-4556-a963-18fac5fd2ced', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a7523b1f-0051-4639-be7d-78b53959a169', '089da09b-0af2-4971-8ac8-56ec28b1d8b8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a7523b1f-0051-4639-be7d-78b53959a169', '0f33799d-70d5-4c31-896a-8089eabd8bd4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a7523b1f-0051-4639-be7d-78b53959a169', '201cfb9c-f42f-4cc7-88f9-a04603b4e886', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a7523b1f-0051-4639-be7d-78b53959a169', '6202b592-6a50-4b3f-a34f-82ebabeee289', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d66dbdcf-86d3-402e-9a29-600bf86e5c28', '9750c804-7f3b-477c-9e91-24a14c3725ce', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d66dbdcf-86d3-402e-9a29-600bf86e5c28', '11289bdc-1c32-4fbb-be2a-c03b4677f76a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d66dbdcf-86d3-402e-9a29-600bf86e5c28', '3d2f0531-7f17-49f9-8fb1-48e963c28733', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d66dbdcf-86d3-402e-9a29-600bf86e5c28', '7a6c0ba8-759d-44d1-9e82-15eee71a9fd5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d66dbdcf-86d3-402e-9a29-600bf86e5c28', '85d60a42-1795-46c4-9110-0f30d3904b53', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('82e50667-ee68-48d3-a21e-f504be7a554f', 'd66dbdcf-86d3-402e-9a29-600bf86e5c28', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('82e50667-ee68-48d3-a21e-f504be7a554f', '9750c804-7f3b-477c-9e91-24a14c3725ce', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('82e50667-ee68-48d3-a21e-f504be7a554f', '11289bdc-1c32-4fbb-be2a-c03b4677f76a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('82e50667-ee68-48d3-a21e-f504be7a554f', '3d2f0531-7f17-49f9-8fb1-48e963c28733', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('82e50667-ee68-48d3-a21e-f504be7a554f', '7a6c0ba8-759d-44d1-9e82-15eee71a9fd5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9750c804-7f3b-477c-9e91-24a14c3725ce', 'd66dbdcf-86d3-402e-9a29-600bf86e5c28', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9750c804-7f3b-477c-9e91-24a14c3725ce', '11289bdc-1c32-4fbb-be2a-c03b4677f76a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9750c804-7f3b-477c-9e91-24a14c3725ce', '3d2f0531-7f17-49f9-8fb1-48e963c28733', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9750c804-7f3b-477c-9e91-24a14c3725ce', '7a6c0ba8-759d-44d1-9e82-15eee71a9fd5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9750c804-7f3b-477c-9e91-24a14c3725ce', '85d60a42-1795-46c4-9110-0f30d3904b53', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d2f0531-7f17-49f9-8fb1-48e963c28733', 'd66dbdcf-86d3-402e-9a29-600bf86e5c28', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d2f0531-7f17-49f9-8fb1-48e963c28733', '9750c804-7f3b-477c-9e91-24a14c3725ce', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d2f0531-7f17-49f9-8fb1-48e963c28733', '7a6c0ba8-759d-44d1-9e82-15eee71a9fd5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d2f0531-7f17-49f9-8fb1-48e963c28733', '11289bdc-1c32-4fbb-be2a-c03b4677f76a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d2f0531-7f17-49f9-8fb1-48e963c28733', '85d60a42-1795-46c4-9110-0f30d3904b53', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a6c0ba8-759d-44d1-9e82-15eee71a9fd5', 'd66dbdcf-86d3-402e-9a29-600bf86e5c28', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a6c0ba8-759d-44d1-9e82-15eee71a9fd5', '9750c804-7f3b-477c-9e91-24a14c3725ce', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a6c0ba8-759d-44d1-9e82-15eee71a9fd5', '3d2f0531-7f17-49f9-8fb1-48e963c28733', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a6c0ba8-759d-44d1-9e82-15eee71a9fd5', '11289bdc-1c32-4fbb-be2a-c03b4677f76a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a6c0ba8-759d-44d1-9e82-15eee71a9fd5', '85d60a42-1795-46c4-9110-0f30d3904b53', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aa9d2d82-6694-4bbd-8fb5-3b1936915a3e', 'd66dbdcf-86d3-402e-9a29-600bf86e5c28', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aa9d2d82-6694-4bbd-8fb5-3b1936915a3e', '9750c804-7f3b-477c-9e91-24a14c3725ce', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aa9d2d82-6694-4bbd-8fb5-3b1936915a3e', '3d2f0531-7f17-49f9-8fb1-48e963c28733', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e502a30d-2d9e-46da-a739-5b102d873cde', 'd66dbdcf-86d3-402e-9a29-600bf86e5c28', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e502a30d-2d9e-46da-a739-5b102d873cde', '9750c804-7f3b-477c-9e91-24a14c3725ce', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e502a30d-2d9e-46da-a739-5b102d873cde', '3d2f0531-7f17-49f9-8fb1-48e963c28733', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1405a1dd-e9ec-4748-a8cf-37f4dd980a75', 'ad1e5bc2-fa50-45d8-9139-7118e7caf0a5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1405a1dd-e9ec-4748-a8cf-37f4dd980a75', '3c97943e-77d4-4227-94d6-782cef2112cb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1405a1dd-e9ec-4748-a8cf-37f4dd980a75', '5b6c9ae7-868c-49ae-8d8c-7d3b8a511d50', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1405a1dd-e9ec-4748-a8cf-37f4dd980a75', 'e35b9314-46d6-4e65-8cdd-a71c8077afef', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1405a1dd-e9ec-4748-a8cf-37f4dd980a75', 'cc29fcdd-1d2d-4055-9ff8-4a909a3cbeed', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5b6c9ae7-868c-49ae-8d8c-7d3b8a511d50', 'cc29fcdd-1d2d-4055-9ff8-4a909a3cbeed', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5b6c9ae7-868c-49ae-8d8c-7d3b8a511d50', '1405a1dd-e9ec-4748-a8cf-37f4dd980a75', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5b6c9ae7-868c-49ae-8d8c-7d3b8a511d50', 'ad1e5bc2-fa50-45d8-9139-7118e7caf0a5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5b6c9ae7-868c-49ae-8d8c-7d3b8a511d50', 'e35b9314-46d6-4e65-8cdd-a71c8077afef', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5b6c9ae7-868c-49ae-8d8c-7d3b8a511d50', '3c97943e-77d4-4227-94d6-782cef2112cb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ad1e5bc2-fa50-45d8-9139-7118e7caf0a5', '1405a1dd-e9ec-4748-a8cf-37f4dd980a75', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ad1e5bc2-fa50-45d8-9139-7118e7caf0a5', '3c97943e-77d4-4227-94d6-782cef2112cb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ad1e5bc2-fa50-45d8-9139-7118e7caf0a5', '5b6c9ae7-868c-49ae-8d8c-7d3b8a511d50', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ad1e5bc2-fa50-45d8-9139-7118e7caf0a5', 'e35b9314-46d6-4e65-8cdd-a71c8077afef', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ad1e5bc2-fa50-45d8-9139-7118e7caf0a5', 'cc29fcdd-1d2d-4055-9ff8-4a909a3cbeed', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e35b9314-46d6-4e65-8cdd-a71c8077afef', '1405a1dd-e9ec-4748-a8cf-37f4dd980a75', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e35b9314-46d6-4e65-8cdd-a71c8077afef', '5b6c9ae7-868c-49ae-8d8c-7d3b8a511d50', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e35b9314-46d6-4e65-8cdd-a71c8077afef', 'ad1e5bc2-fa50-45d8-9139-7118e7caf0a5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e35b9314-46d6-4e65-8cdd-a71c8077afef', 'cc29fcdd-1d2d-4055-9ff8-4a909a3cbeed', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e35b9314-46d6-4e65-8cdd-a71c8077afef', '3c97943e-77d4-4227-94d6-782cef2112cb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cc29fcdd-1d2d-4055-9ff8-4a909a3cbeed', '5b6c9ae7-868c-49ae-8d8c-7d3b8a511d50', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cc29fcdd-1d2d-4055-9ff8-4a909a3cbeed', '1405a1dd-e9ec-4748-a8cf-37f4dd980a75', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cc29fcdd-1d2d-4055-9ff8-4a909a3cbeed', 'ad1e5bc2-fa50-45d8-9139-7118e7caf0a5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cc29fcdd-1d2d-4055-9ff8-4a909a3cbeed', 'e35b9314-46d6-4e65-8cdd-a71c8077afef', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cc29fcdd-1d2d-4055-9ff8-4a909a3cbeed', '3c97943e-77d4-4227-94d6-782cef2112cb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f691a822-fe82-42ba-bf9c-58873cf84414', 'ec073e99-d5c0-471f-8fb7-01783ed9ccc7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f691a822-fe82-42ba-bf9c-58873cf84414', 'd66dbdcf-86d3-402e-9a29-600bf86e5c28', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f691a822-fe82-42ba-bf9c-58873cf84414', '9750c804-7f3b-477c-9e91-24a14c3725ce', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('11289bdc-1c32-4fbb-be2a-c03b4677f76a', 'd66dbdcf-86d3-402e-9a29-600bf86e5c28', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('11289bdc-1c32-4fbb-be2a-c03b4677f76a', '9750c804-7f3b-477c-9e91-24a14c3725ce', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('11289bdc-1c32-4fbb-be2a-c03b4677f76a', '3d2f0531-7f17-49f9-8fb1-48e963c28733', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('11289bdc-1c32-4fbb-be2a-c03b4677f76a', '7a6c0ba8-759d-44d1-9e82-15eee71a9fd5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('11289bdc-1c32-4fbb-be2a-c03b4677f76a', '85d60a42-1795-46c4-9110-0f30d3904b53', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5fa9826f-97e1-42a5-b0e3-375d0b1c85c7', 'd66dbdcf-86d3-402e-9a29-600bf86e5c28', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5fa9826f-97e1-42a5-b0e3-375d0b1c85c7', '9750c804-7f3b-477c-9e91-24a14c3725ce', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5fa9826f-97e1-42a5-b0e3-375d0b1c85c7', '3d2f0531-7f17-49f9-8fb1-48e963c28733', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('85d60a42-1795-46c4-9110-0f30d3904b53', 'd66dbdcf-86d3-402e-9a29-600bf86e5c28', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('85d60a42-1795-46c4-9110-0f30d3904b53', '9750c804-7f3b-477c-9e91-24a14c3725ce', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('85d60a42-1795-46c4-9110-0f30d3904b53', '3d2f0531-7f17-49f9-8fb1-48e963c28733', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('85d60a42-1795-46c4-9110-0f30d3904b53', '7a6c0ba8-759d-44d1-9e82-15eee71a9fd5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('85d60a42-1795-46c4-9110-0f30d3904b53', '11289bdc-1c32-4fbb-be2a-c03b4677f76a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ec073e99-d5c0-471f-8fb7-01783ed9ccc7', 'f691a822-fe82-42ba-bf9c-58873cf84414', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ec073e99-d5c0-471f-8fb7-01783ed9ccc7', 'd66dbdcf-86d3-402e-9a29-600bf86e5c28', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ec073e99-d5c0-471f-8fb7-01783ed9ccc7', '9750c804-7f3b-477c-9e91-24a14c3725ce', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3c97943e-77d4-4227-94d6-782cef2112cb', '1405a1dd-e9ec-4748-a8cf-37f4dd980a75', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3c97943e-77d4-4227-94d6-782cef2112cb', 'ad1e5bc2-fa50-45d8-9139-7118e7caf0a5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3c97943e-77d4-4227-94d6-782cef2112cb', '5b6c9ae7-868c-49ae-8d8c-7d3b8a511d50', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3c97943e-77d4-4227-94d6-782cef2112cb', 'e35b9314-46d6-4e65-8cdd-a71c8077afef', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3c97943e-77d4-4227-94d6-782cef2112cb', 'cc29fcdd-1d2d-4055-9ff8-4a909a3cbeed', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4ab99383-6e32-4fd1-8c95-5e4e2e8de9d6', '30346c72-ac5f-4265-837e-7b53c1e9834f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4ab99383-6e32-4fd1-8c95-5e4e2e8de9d6', '7dcc2c9b-fcfc-46df-a2f4-7e269a5ce61e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4ab99383-6e32-4fd1-8c95-5e4e2e8de9d6', 'd66dbdcf-86d3-402e-9a29-600bf86e5c28', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('30346c72-ac5f-4265-837e-7b53c1e9834f', '4ab99383-6e32-4fd1-8c95-5e4e2e8de9d6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('30346c72-ac5f-4265-837e-7b53c1e9834f', '7dcc2c9b-fcfc-46df-a2f4-7e269a5ce61e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('30346c72-ac5f-4265-837e-7b53c1e9834f', 'd66dbdcf-86d3-402e-9a29-600bf86e5c28', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7dcc2c9b-fcfc-46df-a2f4-7e269a5ce61e', '4ab99383-6e32-4fd1-8c95-5e4e2e8de9d6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7dcc2c9b-fcfc-46df-a2f4-7e269a5ce61e', '30346c72-ac5f-4265-837e-7b53c1e9834f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7dcc2c9b-fcfc-46df-a2f4-7e269a5ce61e', 'd66dbdcf-86d3-402e-9a29-600bf86e5c28', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c29dbb3b-09af-4aa1-a427-faec522533c7', '21739ca5-a1e2-479e-bd60-bbe7669fdab9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c29dbb3b-09af-4aa1-a427-faec522533c7', '39a5497a-2afb-453d-b4bb-1c7d14e77455', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c29dbb3b-09af-4aa1-a427-faec522533c7', '13bb2109-1b98-4b35-a3a9-013cd79c0089', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c29dbb3b-09af-4aa1-a427-faec522533c7', '6ada107f-d151-409c-bd8c-8ca2ef3154ce', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('21739ca5-a1e2-479e-bd60-bbe7669fdab9', 'c29dbb3b-09af-4aa1-a427-faec522533c7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('21739ca5-a1e2-479e-bd60-bbe7669fdab9', '39a5497a-2afb-453d-b4bb-1c7d14e77455', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('21739ca5-a1e2-479e-bd60-bbe7669fdab9', '13bb2109-1b98-4b35-a3a9-013cd79c0089', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('21739ca5-a1e2-479e-bd60-bbe7669fdab9', '6ada107f-d151-409c-bd8c-8ca2ef3154ce', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39a5497a-2afb-453d-b4bb-1c7d14e77455', 'c29dbb3b-09af-4aa1-a427-faec522533c7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39a5497a-2afb-453d-b4bb-1c7d14e77455', '21739ca5-a1e2-479e-bd60-bbe7669fdab9', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39a5497a-2afb-453d-b4bb-1c7d14e77455', '13bb2109-1b98-4b35-a3a9-013cd79c0089', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39a5497a-2afb-453d-b4bb-1c7d14e77455', '6ada107f-d151-409c-bd8c-8ca2ef3154ce', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('13bb2109-1b98-4b35-a3a9-013cd79c0089', 'c29dbb3b-09af-4aa1-a427-faec522533c7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('13bb2109-1b98-4b35-a3a9-013cd79c0089', '21739ca5-a1e2-479e-bd60-bbe7669fdab9', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('13bb2109-1b98-4b35-a3a9-013cd79c0089', '39a5497a-2afb-453d-b4bb-1c7d14e77455', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('13bb2109-1b98-4b35-a3a9-013cd79c0089', '6ada107f-d151-409c-bd8c-8ca2ef3154ce', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6ada107f-d151-409c-bd8c-8ca2ef3154ce', 'c29dbb3b-09af-4aa1-a427-faec522533c7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6ada107f-d151-409c-bd8c-8ca2ef3154ce', '21739ca5-a1e2-479e-bd60-bbe7669fdab9', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6ada107f-d151-409c-bd8c-8ca2ef3154ce', '39a5497a-2afb-453d-b4bb-1c7d14e77455', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6ada107f-d151-409c-bd8c-8ca2ef3154ce', '13bb2109-1b98-4b35-a3a9-013cd79c0089', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a65aefbe-2ddd-4072-935c-3097b688d1eb', '26b9cb52-fe68-4a27-8d78-5c1933c2c590', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a65aefbe-2ddd-4072-935c-3097b688d1eb', '2c548a91-7ae1-4fc1-8b26-1f2e62010949', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('26b9cb52-fe68-4a27-8d78-5c1933c2c590', 'a65aefbe-2ddd-4072-935c-3097b688d1eb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('26b9cb52-fe68-4a27-8d78-5c1933c2c590', '2c548a91-7ae1-4fc1-8b26-1f2e62010949', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2c548a91-7ae1-4fc1-8b26-1f2e62010949', 'a65aefbe-2ddd-4072-935c-3097b688d1eb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2c548a91-7ae1-4fc1-8b26-1f2e62010949', '26b9cb52-fe68-4a27-8d78-5c1933c2c590', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3038a52-0d6e-4c11-8ceb-73658c8e058f', '05f64402-2e76-49a0-a00d-80a1f28c47d7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3038a52-0d6e-4c11-8ceb-73658c8e058f', '47eb84ff-5919-40a3-b2b3-fd488d22d56c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3038a52-0d6e-4c11-8ceb-73658c8e058f', 'f04bac3d-2397-4544-96b4-7d0f62a76da3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3038a52-0d6e-4c11-8ceb-73658c8e058f', '873a4785-a2d0-46d5-822d-945d870f02cd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3038a52-0d6e-4c11-8ceb-73658c8e058f', 'b16e023b-bac0-4a5f-96c5-4417c7048c53', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('47eb84ff-5919-40a3-b2b3-fd488d22d56c', '05f64402-2e76-49a0-a00d-80a1f28c47d7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('47eb84ff-5919-40a3-b2b3-fd488d22d56c', 'd3038a52-0d6e-4c11-8ceb-73658c8e058f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('47eb84ff-5919-40a3-b2b3-fd488d22d56c', 'f04bac3d-2397-4544-96b4-7d0f62a76da3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('47eb84ff-5919-40a3-b2b3-fd488d22d56c', '873a4785-a2d0-46d5-822d-945d870f02cd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('47eb84ff-5919-40a3-b2b3-fd488d22d56c', 'b16e023b-bac0-4a5f-96c5-4417c7048c53', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f04bac3d-2397-4544-96b4-7d0f62a76da3', '05f64402-2e76-49a0-a00d-80a1f28c47d7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f04bac3d-2397-4544-96b4-7d0f62a76da3', 'd3038a52-0d6e-4c11-8ceb-73658c8e058f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f04bac3d-2397-4544-96b4-7d0f62a76da3', '47eb84ff-5919-40a3-b2b3-fd488d22d56c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f04bac3d-2397-4544-96b4-7d0f62a76da3', '873a4785-a2d0-46d5-822d-945d870f02cd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f04bac3d-2397-4544-96b4-7d0f62a76da3', 'b16e023b-bac0-4a5f-96c5-4417c7048c53', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b16e023b-bac0-4a5f-96c5-4417c7048c53', '05f64402-2e76-49a0-a00d-80a1f28c47d7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b16e023b-bac0-4a5f-96c5-4417c7048c53', '873a4785-a2d0-46d5-822d-945d870f02cd', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b16e023b-bac0-4a5f-96c5-4417c7048c53', 'd3038a52-0d6e-4c11-8ceb-73658c8e058f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b16e023b-bac0-4a5f-96c5-4417c7048c53', '47eb84ff-5919-40a3-b2b3-fd488d22d56c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b16e023b-bac0-4a5f-96c5-4417c7048c53', 'f04bac3d-2397-4544-96b4-7d0f62a76da3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4ac1443b-9ab7-4f0c-9668-9b2162accd15', '1795e8b2-6450-4a42-9ba3-5e149ff188fc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4ac1443b-9ab7-4f0c-9668-9b2162accd15', '35e7c856-468d-4e52-a9c4-df1016f6d5b9', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1795e8b2-6450-4a42-9ba3-5e149ff188fc', '4ac1443b-9ab7-4f0c-9668-9b2162accd15', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1795e8b2-6450-4a42-9ba3-5e149ff188fc', '35e7c856-468d-4e52-a9c4-df1016f6d5b9', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('35e7c856-468d-4e52-a9c4-df1016f6d5b9', '4ac1443b-9ab7-4f0c-9668-9b2162accd15', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('35e7c856-468d-4e52-a9c4-df1016f6d5b9', '1795e8b2-6450-4a42-9ba3-5e149ff188fc', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5cb17c07-b220-46e1-8e49-3b6a8252108e', 'd71feb66-e2ef-4782-8069-0215b5d5ac06', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5cb17c07-b220-46e1-8e49-3b6a8252108e', '73c7c3c3-d46b-48ed-8b66-5bc783e7f51f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5cb17c07-b220-46e1-8e49-3b6a8252108e', '10bb5345-3324-46e3-bec7-538431bcdd73', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d71feb66-e2ef-4782-8069-0215b5d5ac06', '10bb5345-3324-46e3-bec7-538431bcdd73', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d71feb66-e2ef-4782-8069-0215b5d5ac06', '5cb17c07-b220-46e1-8e49-3b6a8252108e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d71feb66-e2ef-4782-8069-0215b5d5ac06', '73c7c3c3-d46b-48ed-8b66-5bc783e7f51f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('73c7c3c3-d46b-48ed-8b66-5bc783e7f51f', '5cb17c07-b220-46e1-8e49-3b6a8252108e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('73c7c3c3-d46b-48ed-8b66-5bc783e7f51f', 'd71feb66-e2ef-4782-8069-0215b5d5ac06', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('73c7c3c3-d46b-48ed-8b66-5bc783e7f51f', '10bb5345-3324-46e3-bec7-538431bcdd73', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('10bb5345-3324-46e3-bec7-538431bcdd73', 'd71feb66-e2ef-4782-8069-0215b5d5ac06', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('10bb5345-3324-46e3-bec7-538431bcdd73', '5cb17c07-b220-46e1-8e49-3b6a8252108e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('10bb5345-3324-46e3-bec7-538431bcdd73', '73c7c3c3-d46b-48ed-8b66-5bc783e7f51f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('424406bd-6343-4a39-9a93-2fa331de82e1', '19e73bdd-2784-490f-944c-0ff84f51ffb3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('424406bd-6343-4a39-9a93-2fa331de82e1', '61b36832-4233-4374-ae7f-d0c4eb4fc2bb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('424406bd-6343-4a39-9a93-2fa331de82e1', '3d436622-ca05-4568-b83f-9091ce2cc5a7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('424406bd-6343-4a39-9a93-2fa331de82e1', '149d0128-2e92-4e88-ad7a-3d0d014ad2de', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('424406bd-6343-4a39-9a93-2fa331de82e1', 'c086b464-2c9e-4afa-9b68-aa7568eeb6cf', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19e73bdd-2784-490f-944c-0ff84f51ffb3', '424406bd-6343-4a39-9a93-2fa331de82e1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19e73bdd-2784-490f-944c-0ff84f51ffb3', '61b36832-4233-4374-ae7f-d0c4eb4fc2bb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19e73bdd-2784-490f-944c-0ff84f51ffb3', '3d436622-ca05-4568-b83f-9091ce2cc5a7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19e73bdd-2784-490f-944c-0ff84f51ffb3', '149d0128-2e92-4e88-ad7a-3d0d014ad2de', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19e73bdd-2784-490f-944c-0ff84f51ffb3', 'c086b464-2c9e-4afa-9b68-aa7568eeb6cf', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('61b36832-4233-4374-ae7f-d0c4eb4fc2bb', '9c8569b6-b6d8-4873-854a-dbc7f94e2750', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('61b36832-4233-4374-ae7f-d0c4eb4fc2bb', '424406bd-6343-4a39-9a93-2fa331de82e1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('61b36832-4233-4374-ae7f-d0c4eb4fc2bb', '19e73bdd-2784-490f-944c-0ff84f51ffb3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('61b36832-4233-4374-ae7f-d0c4eb4fc2bb', '3d436622-ca05-4568-b83f-9091ce2cc5a7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('61b36832-4233-4374-ae7f-d0c4eb4fc2bb', '149d0128-2e92-4e88-ad7a-3d0d014ad2de', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d436622-ca05-4568-b83f-9091ce2cc5a7', '424406bd-6343-4a39-9a93-2fa331de82e1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d436622-ca05-4568-b83f-9091ce2cc5a7', '19e73bdd-2784-490f-944c-0ff84f51ffb3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d436622-ca05-4568-b83f-9091ce2cc5a7', '61b36832-4233-4374-ae7f-d0c4eb4fc2bb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d436622-ca05-4568-b83f-9091ce2cc5a7', '149d0128-2e92-4e88-ad7a-3d0d014ad2de', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d436622-ca05-4568-b83f-9091ce2cc5a7', 'c086b464-2c9e-4afa-9b68-aa7568eeb6cf', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('149d0128-2e92-4e88-ad7a-3d0d014ad2de', '424406bd-6343-4a39-9a93-2fa331de82e1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('149d0128-2e92-4e88-ad7a-3d0d014ad2de', '19e73bdd-2784-490f-944c-0ff84f51ffb3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('149d0128-2e92-4e88-ad7a-3d0d014ad2de', '61b36832-4233-4374-ae7f-d0c4eb4fc2bb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('149d0128-2e92-4e88-ad7a-3d0d014ad2de', '3d436622-ca05-4568-b83f-9091ce2cc5a7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('149d0128-2e92-4e88-ad7a-3d0d014ad2de', 'c086b464-2c9e-4afa-9b68-aa7568eeb6cf', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c086b464-2c9e-4afa-9b68-aa7568eeb6cf', '424406bd-6343-4a39-9a93-2fa331de82e1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c086b464-2c9e-4afa-9b68-aa7568eeb6cf', '19e73bdd-2784-490f-944c-0ff84f51ffb3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c086b464-2c9e-4afa-9b68-aa7568eeb6cf', '61b36832-4233-4374-ae7f-d0c4eb4fc2bb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c086b464-2c9e-4afa-9b68-aa7568eeb6cf', '3d436622-ca05-4568-b83f-9091ce2cc5a7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c086b464-2c9e-4afa-9b68-aa7568eeb6cf', '149d0128-2e92-4e88-ad7a-3d0d014ad2de', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('868105a8-0e01-449e-8754-abb516569962', '424406bd-6343-4a39-9a93-2fa331de82e1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('868105a8-0e01-449e-8754-abb516569962', '19e73bdd-2784-490f-944c-0ff84f51ffb3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('868105a8-0e01-449e-8754-abb516569962', '61b36832-4233-4374-ae7f-d0c4eb4fc2bb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('868105a8-0e01-449e-8754-abb516569962', '3d436622-ca05-4568-b83f-9091ce2cc5a7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('868105a8-0e01-449e-8754-abb516569962', '149d0128-2e92-4e88-ad7a-3d0d014ad2de', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9c8569b6-b6d8-4873-854a-dbc7f94e2750', '61b36832-4233-4374-ae7f-d0c4eb4fc2bb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9c8569b6-b6d8-4873-854a-dbc7f94e2750', '424406bd-6343-4a39-9a93-2fa331de82e1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9c8569b6-b6d8-4873-854a-dbc7f94e2750', '19e73bdd-2784-490f-944c-0ff84f51ffb3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9c8569b6-b6d8-4873-854a-dbc7f94e2750', '3d436622-ca05-4568-b83f-9091ce2cc5a7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9c8569b6-b6d8-4873-854a-dbc7f94e2750', '149d0128-2e92-4e88-ad7a-3d0d014ad2de', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e5268548-dc7a-43d7-9cd3-4336b8db90c0', '424406bd-6343-4a39-9a93-2fa331de82e1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e5268548-dc7a-43d7-9cd3-4336b8db90c0', '19e73bdd-2784-490f-944c-0ff84f51ffb3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e5268548-dc7a-43d7-9cd3-4336b8db90c0', '61b36832-4233-4374-ae7f-d0c4eb4fc2bb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e5268548-dc7a-43d7-9cd3-4336b8db90c0', '3d436622-ca05-4568-b83f-9091ce2cc5a7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e5268548-dc7a-43d7-9cd3-4336b8db90c0', '149d0128-2e92-4e88-ad7a-3d0d014ad2de', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('476bad67-74b1-41d1-8c04-b9fa274f5703', '0d321c9a-2ed3-4e8f-a831-f5ed9d318052', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('36661dd9-8db3-4f53-937f-19d6016a1e40', '0d321c9a-2ed3-4e8f-a831-f5ed9d318052', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('37b0a0cd-473c-4df6-88d1-02f2e2dbe8db', '0d321c9a-2ed3-4e8f-a831-f5ed9d318052', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4eb609c4-bab5-41d2-943b-f81a4772bfa0', '0d321c9a-2ed3-4e8f-a831-f5ed9d318052', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5b12ee66-0a13-488f-b051-748671c54f84', '0d321c9a-2ed3-4e8f-a831-f5ed9d318052', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('49725262-fdf6-476b-9638-2a9cb822f2c3', '0d321c9a-2ed3-4e8f-a831-f5ed9d318052', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c7c223bb-b0b8-472c-87b5-4615cb4c083d', '181ffb6b-1da8-44fb-8ad1-85c78a838bb9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c7c223bb-b0b8-472c-87b5-4615cb4c083d', 'a32c2afc-2066-4b72-8bfe-89d06df992e8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c7c223bb-b0b8-472c-87b5-4615cb4c083d', 'f49fa36b-a47c-44c7-b333-db1efa73e7cf', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('181ffb6b-1da8-44fb-8ad1-85c78a838bb9', 'c7c223bb-b0b8-472c-87b5-4615cb4c083d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('181ffb6b-1da8-44fb-8ad1-85c78a838bb9', 'a32c2afc-2066-4b72-8bfe-89d06df992e8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('181ffb6b-1da8-44fb-8ad1-85c78a838bb9', 'f49fa36b-a47c-44c7-b333-db1efa73e7cf', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a32c2afc-2066-4b72-8bfe-89d06df992e8', 'f49fa36b-a47c-44c7-b333-db1efa73e7cf', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a32c2afc-2066-4b72-8bfe-89d06df992e8', 'c7c223bb-b0b8-472c-87b5-4615cb4c083d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a32c2afc-2066-4b72-8bfe-89d06df992e8', '181ffb6b-1da8-44fb-8ad1-85c78a838bb9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f49fa36b-a47c-44c7-b333-db1efa73e7cf', 'a32c2afc-2066-4b72-8bfe-89d06df992e8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f49fa36b-a47c-44c7-b333-db1efa73e7cf', 'c7c223bb-b0b8-472c-87b5-4615cb4c083d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f49fa36b-a47c-44c7-b333-db1efa73e7cf', '181ffb6b-1da8-44fb-8ad1-85c78a838bb9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a1918f5e-e9e7-48cc-8c69-a61030099917', '7f666923-6132-4a1d-a579-7e2f4258e728', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a1918f5e-e9e7-48cc-8c69-a61030099917', '036ccc3b-a18a-44c7-972e-a204e8372ab7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e5c43110-f362-492c-9295-ae25ffb90348', 'a1918f5e-e9e7-48cc-8c69-a61030099917', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e5c43110-f362-492c-9295-ae25ffb90348', '7f666923-6132-4a1d-a579-7e2f4258e728', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e5c43110-f362-492c-9295-ae25ffb90348', '036ccc3b-a18a-44c7-972e-a204e8372ab7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb68d01b-22e8-4db8-88f4-15dffa3d53c5', 'a1918f5e-e9e7-48cc-8c69-a61030099917', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb68d01b-22e8-4db8-88f4-15dffa3d53c5', '7f666923-6132-4a1d-a579-7e2f4258e728', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb68d01b-22e8-4db8-88f4-15dffa3d53c5', '036ccc3b-a18a-44c7-972e-a204e8372ab7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7f666923-6132-4a1d-a579-7e2f4258e728', 'a1918f5e-e9e7-48cc-8c69-a61030099917', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7f666923-6132-4a1d-a579-7e2f4258e728', '036ccc3b-a18a-44c7-972e-a204e8372ab7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('556d2836-cebe-495e-abc4-a0a6fc76821f', 'a1918f5e-e9e7-48cc-8c69-a61030099917', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('556d2836-cebe-495e-abc4-a0a6fc76821f', '7f666923-6132-4a1d-a579-7e2f4258e728', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('556d2836-cebe-495e-abc4-a0a6fc76821f', '036ccc3b-a18a-44c7-972e-a204e8372ab7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ae13640-abef-4981-8f75-870782ed2e63', 'a1918f5e-e9e7-48cc-8c69-a61030099917', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ae13640-abef-4981-8f75-870782ed2e63', '7f666923-6132-4a1d-a579-7e2f4258e728', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ae13640-abef-4981-8f75-870782ed2e63', '036ccc3b-a18a-44c7-972e-a204e8372ab7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('036ccc3b-a18a-44c7-972e-a204e8372ab7', 'a1918f5e-e9e7-48cc-8c69-a61030099917', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('036ccc3b-a18a-44c7-972e-a204e8372ab7', '7f666923-6132-4a1d-a579-7e2f4258e728', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('037975a5-8427-4830-bbf9-aed5ca83bf3d', 'a1918f5e-e9e7-48cc-8c69-a61030099917', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('037975a5-8427-4830-bbf9-aed5ca83bf3d', '7f666923-6132-4a1d-a579-7e2f4258e728', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('037975a5-8427-4830-bbf9-aed5ca83bf3d', '036ccc3b-a18a-44c7-972e-a204e8372ab7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6371e48a-4704-4130-b0a9-71c889b9cd66', 'a1918f5e-e9e7-48cc-8c69-a61030099917', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6371e48a-4704-4130-b0a9-71c889b9cd66', '7f666923-6132-4a1d-a579-7e2f4258e728', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6371e48a-4704-4130-b0a9-71c889b9cd66', '036ccc3b-a18a-44c7-972e-a204e8372ab7', 2) ON CONFLICT DO NOTHING;



INSERT INTO public.faqs VALUES ('a83976ed-0a61-4988-8d91-2a3ac288b9de', 'متى يوصلني الرد بعد الاشتراك؟', 'خلال 48 ساعة عمل. أيام العمل من الأحد إلى الخميس، من 12 الظهر حتى 9 مساءً، والتواصل على واتساب.', 0, true, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('43352ec4-9c36-4bfd-b319-068fd583889a', 'كيف تتم المتابعة؟', 'ترسل مراجعتك الأسبوعية في يوم المراجعة، وأرد عليك بتعديلات مسجلة (فيديو أو صوت). في الباقة الأساسية المتابعة كل أسبوعين. التواصل اليومي على واتساب مع رد خلال 48 ساعة.', 1, true, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('11bb6693-034f-4403-8f35-8e139016d1db', 'أنا مبتدئ تماماً، هل يناسبني؟', 'نعم. البرنامج يُبنى على مستواك الحالي، والتمارين مشروحة، وتقدر ترسل مقاطع أدائك لتصحيح التكنيك.', 2, true, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('987b11ce-3343-40ac-89f5-59aad968e7a6', 'أتمرن في البيت، ماذا أحتاج من أدوات؟', 'تحدد في النموذج الأدوات المتوفرة عندك (دمبلز، حبال مقاومة، بار…) ويُبنى جدولك عليها.', 3, true, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('f12d7f85-8ff1-4a19-a497-cb7f1419cb56', 'كيف أدفع؟', 'بتحويل بنكي بعد تعبئة الاستبيان. أول ما ترسل الاستبيان يظهر لك رقم طلبك والمبلغ وبيانات الحساب. حوّل المبلغ وارفع صورة الإيصال من صفحة طلبك، ويتأكد اشتراكك بعد التحقق من وصول المبلغ.', 4, true, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('1aa448dd-1eb5-496b-a72c-4bd5bef53c62', 'ما شروط ضمان استرجاع المبلغ؟', 'في اشتراكات 3 أشهر لباقات المتابعة (المكثفة، المتقدمة، الأساسية): إذا لم يتحسن أي مؤشر من مؤشرات تقدمك بعد 12 أسبوعاً، يرجع لك المبلغ كاملاً.
مؤشرات التقدم (بحسب هدفك): متوسط الوزن الأسبوعي، أو محيط الخصر، أو القوة في التمارين الأساسية (الوزن أو التكرارات).
شروط الضمان:
- إرسال المراجعة الأسبوعية كل أسبوع.
- أخذ القياسات بانتظام.
- تصوير التمارين وإرسالها.
- الالتزام بجدول التغذية المخصص (في الباقات التي تشمل تغذية).
يُطلب الاسترجاع عبر واتساب خلال 14 يوماً من نهاية الأشهر الثلاثة.', 5, true, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('abc61473-d292-4377-bcda-8551eec7af07', 'هل الجداول لي بعد انتهاء الاشتراك؟', 'نعم، جميع الجداول لك مدى الحياة وتقدر تعدّل عليها.', 6, true, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('f0de316c-5e8c-44a0-8e13-cd9b30d09209', 'ما هو التجديد المجاني؟', 'مكافأة للملتزمين: إذا كان اشتراكك 3 أشهر تحصل على 3 أشهر إضافية مجاناً، فيصير المجموع 6 أشهر بسعر 3.
الشروط:
- نسبة التزام 90% فأكثر: المراجعات الأسبوعية المرسلة والتمارين المسجلة.
- تقدم واضح في مؤشرات التقدم نفسها المذكورة في الضمان.
- للمتدربين الرجال: إرسال صور التطور (قبل وبعد) للمدربة للتوثيق، مع تغطية الوجه والسرة.
نشر الصور في السوشل ميديا اختياري بالكامل حسب موافقتك، ولا يؤثر على استحقاقك للتجديد.', 7, true, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('6b8d9aaf-6c4c-4fe2-89b0-e14590c55701', 'من يطّلع على بياناتي؟', 'المدربة فقط، وتُستخدم لتصميم برنامجك ومتابعتك. لا تُنشر نتيجتك أو صورتك إلا بموافقتك الصريحة في النموذج.', 8, true, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;



INSERT INTO public.foods VALUES ('833cb2d6-1dbd-4da4-8aa6-d6d3b3a5c7be', 'رز أبيض مطبوخ', 'Rice, white, long-grain, regular, enriched, cooked', 'حبوب ونشويات', 130.0, 2.7, 28.2, 0.3, 150.0, 'كوب إلا ربع', 'usda', '168878', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('c11806c7-456a-4c28-a0fa-680e56f6e279', 'رز بني مطبوخ', 'Rice, brown, long-grain, cooked (Includes foods for USDA''s Food Distribution Program)', 'حبوب ونشويات', 123.0, 2.7, 25.6, 1.0, 150.0, NULL, 'usda', '169704', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('0d27b7b3-93ce-4e5c-acac-51e1b68da63b', 'رز أبيض (غير مطبوخ)', 'Rice, white, long-grain, regular, raw, enriched', 'حبوب ونشويات', 365.0, 7.1, 80.0, 0.7, 75.0, NULL, 'usda', '168877', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('57569e28-d8e7-4d4b-bf25-72e90eaba202', 'مكرونة مطبوخة', 'Pasta, cooked, enriched, without added salt', 'حبوب ونشويات', 158.0, 5.8, 30.9, 0.9, 140.0, 'كوب', 'usda', '169737', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a8b32697-abae-49c9-a116-1eccfc333ea7', 'مكرونة (غير مطبوخة)', 'Pasta, dry, enriched', 'حبوب ونشويات', 371.0, 13.0, 74.7, 1.5, 75.0, NULL, 'usda', '169736', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('1995acea-c971-4096-8bc5-c834b1fb6b90', 'شوفان', 'Cereals, oats, regular and quick, not fortified, dry', 'حبوب ونشويات', 379.0, 13.2, 67.7, 6.5, 40.0, 'نص كوب', 'usda', '173904', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('e8d1eab2-e654-4443-a4a4-c7f05dcf8250', 'خبز أبيض (توست)', 'Bread, white, commercially prepared (includes soft bread crumbs)', 'خبز', 266.0, 8.9, 49.4, 3.3, 28.0, 'شريحة', 'usda', '174924', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('fa71bff5-f13e-407d-bbf2-61e11a16c521', 'خبز بر (توست أسمر)', 'Bread, whole-wheat, commercially prepared', 'خبز', 252.0, 12.5, 42.7, 3.5, 32.0, 'شريحة', 'usda', '172688', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('9ac9fa99-7c8b-47db-9411-db13fec91b16', 'خبز عربي أبيض', 'Bread, pita, white, enriched', 'خبز', 275.0, 9.1, 55.7, 1.2, 60.0, 'رغيف صغير', 'usda', '174915', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('91d86ad1-06d0-4f4c-9ac0-0d6f3c668487', 'خبز عربي بر', 'Bread, pita, whole-wheat', 'خبز', 262.0, 9.8, 55.9, 1.7, 64.0, 'رغيف صغير', 'usda', '174916', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('8ba5fff8-5702-4c43-8b7c-2e9afbf8241b', 'تورتيلا قمح', 'Tortillas, ready-to-bake or -fry, flour, refrigerated', 'خبز', 306.0, 8.2, 49.4, 8.0, 45.0, 'حبة', 'usda', '175037', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a0903ddb-c434-4f80-a26b-df65b6a4a467', 'بطاطس مسلوقة', 'Potatoes, boiled, cooked without skin, flesh, without salt', 'حبوب ونشويات', 86.0, 1.7, 20.0, 0.1, 150.0, 'حبة وسط', 'usda', '170440', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('cd7e9c93-87c6-4eec-859b-525961a7dc52', 'بطاطا حلوة مشوية', 'Sweet potato, cooked, baked in skin, flesh, without salt', 'حبوب ونشويات', 90.0, 2.0, 20.7, 0.2, 150.0, 'حبة وسط', 'usda', '168483', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ab2f4c42-e34f-4d6c-8361-75dff3ce6bcb', 'برغل مطبوخ', 'Bulgur, cooked', 'حبوب ونشويات', 83.0, 3.1, 18.6, 0.2, 150.0, NULL, 'usda', '170287', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('47127a30-090f-492f-b5e0-a09dfb99f37d', 'كينوا مطبوخة', 'Quinoa, cooked', 'حبوب ونشويات', 120.0, 4.4, 21.3, 1.9, 150.0, NULL, 'usda', '168917', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('cf58f791-68cd-4611-b850-c9da5746b9df', 'كورن فليكس', 'Cereals ready-to-eat, RALSTON Corn Flakes', 'حبوب ونشويات', 384.0, 5.9, 88.0, 0.9, 30.0, NULL, 'usda', '174648', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('56ac55c2-94b2-4012-beff-2644ce56dced', 'صدر دجاج مشوي', 'Chicken, broilers or fryers, breast, meat only, cooked, roasted', 'لحوم ودواجن', 165.0, 31.0, 0.0, 3.6, 100.0, NULL, 'usda', '171477', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('57f1b26d-89c1-4308-8775-1d5b8d947559', 'صدر دجاج نيء', 'Chicken, broiler or fryers, breast, skinless, boneless, meat only, raw', 'لحوم ودواجن', 120.0, 22.5, 0.0, 2.6, 150.0, NULL, 'usda', '171077', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ed96d77f-2295-4b28-8fec-ba6bc87a34f1', 'فخذ دجاج مشوي (بدون جلد)', 'Chicken, broilers or fryers, thigh, meat only, cooked, roasted', 'لحوم ودواجن', 179.0, 24.8, 0.0, 8.2, 100.0, NULL, 'usda', '172388', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a6901812-b19b-4fb3-8064-eb54c1a618f2', 'لحم بقري مفروم 90% مطبوخ', 'Beef, ground, 90% lean meat / 10% fat, patty, cooked, broiled', 'لحوم ودواجن', 217.0, 26.1, 0.0, 11.8, 100.0, NULL, 'usda', '174031', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('c0330289-45a0-443c-ad31-a0d935fd9713', 'لحم بقري مفروم 80% مطبوخ', 'Beef, ground, 80% lean meat / 20% fat, patty, cooked, broiled', 'لحوم ودواجن', 270.0, 25.8, 0.0, 17.8, 100.0, NULL, 'usda', '171797', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('edea51c1-0dec-4136-8c18-fe34de0dd1eb', 'لحم غنم مطبوخ', 'Lamb, composite of trimmed retail cuts, separable lean only, trimmed to 1/4" fat, choice, cooked', 'لحوم ودواجن', 206.0, 28.2, 0.0, 9.5, 100.0, NULL, 'usda', '174308', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('9e8416b7-fe07-4303-bc6c-836ff77b97ee', 'ديك رومي (شرائح)', 'Turkey, whole, breast, meat only, cooked, roasted', 'لحوم ودواجن', 147.0, 30.1, 0.0, 2.1, 50.0, NULL, 'usda', '171496', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3d99afac-a0b1-4ab7-8b10-58d4d05a1e8a', 'تونة معلبة بالماء', 'Fish, tuna, light, canned in water, drained solids (Includes foods for USDA''s Food Distribution Program)', 'أسماك', 86.0, 19.4, 0.0, 1.0, 100.0, 'علبة صغيرة مصفاة', 'usda', '173709', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d002370d-dad3-48f0-9968-3f8fe129ad41', 'تونة معلبة بالزيت', 'Fish, tuna, light, canned in oil, drained solids', 'أسماك', 198.0, 29.1, 0.0, 8.2, 100.0, NULL, 'usda', '173708', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('c90ec491-bba3-4d7d-81de-1456bd44a43f', 'سلمون مطبوخ', 'Fish, salmon, Atlantic, farmed, cooked, dry heat', 'أسماك', 206.0, 22.1, 0.0, 12.4, 120.0, NULL, 'usda', '175168', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b1fe7ea6-8295-4134-97ef-3fb5c395b8d5', 'سلمون مدخن', 'Fish, salmon, chinook, smoked', 'أسماك', 117.0, 18.3, 0.0, 4.3, 60.0, NULL, 'usda', '173687', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b94f5b2e-5c1f-47bf-be94-72de4adba547', 'روبيان مطبوخ', 'Crustaceans, shrimp, cooked', 'أسماك', 99.0, 24.0, 0.2, 0.3, 100.0, NULL, 'usda', '175180', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('0a8056f8-1d41-4287-83a3-656777a91e60', 'هامور/سمك أبيض مطبوخ', 'Fish, grouper, mixed species, cooked, dry heat', 'أسماك', 118.0, 24.8, 0.0, 1.3, 150.0, NULL, 'usda', '171963', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('0313250a-132e-4a90-ad5e-55f74dc0cf87', 'بيض كامل', 'Egg, whole, raw, fresh', 'بيض وألبان', 143.0, 12.6, 0.7, 9.5, 50.0, 'بيضة', 'usda', '171287', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('8d6de3bd-017c-4a36-a5f3-27a064435fd6', 'بياض بيض', 'Egg, white, raw, fresh', 'بيض وألبان', 52.0, 10.9, 0.7, 0.2, 33.0, 'بياض بيضة', 'usda', '172183', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('9d0da6b0-5c0a-4bbe-abca-70137ed9292c', 'بيض مسلوق', 'Egg, whole, cooked, hard-boiled', 'بيض وألبان', 155.0, 12.6, 1.1, 10.6, 50.0, 'بيضة', 'usda', '173424', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('78cc339b-b4c2-46e3-82f3-8672f33a701a', 'حليب كامل الدسم', 'Milk, whole, 3.25% milkfat, with added vitamin D', 'بيض وألبان', 61.0, 3.2, 4.8, 3.3, 244.0, 'كوب', 'usda', '171265', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('35ff8b91-1535-4180-b07b-79de1c0fe602', 'حليب قليل الدسم 1%', 'Milk, lowfat, fluid, 1% milkfat, with added vitamin A and vitamin D', 'بيض وألبان', 42.0, 3.4, 5.0, 1.0, 244.0, 'كوب', 'usda', '170872', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('e42531d4-53f7-40ee-8031-cbf8d99f6e66', 'حليب خالي الدسم', 'Milk, nonfat, fluid, with added vitamin A and vitamin D (fat free or skim)', 'بيض وألبان', 34.0, 3.4, 5.0, 0.1, 245.0, 'كوب', 'usda', '171269', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('05ed783a-0c6a-41ab-ad82-8a47ca4c33be', 'زبادي كامل الدسم', 'Yogurt, plain, whole milk', 'بيض وألبان', 61.0, 3.5, 4.7, 3.3, 170.0, NULL, 'usda', '171284', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('5e9bbd01-5f16-4743-ab4b-c013312c3792', 'زبادي قليل الدسم', 'Yogurt, plain, low fat', 'بيض وألبان', 63.0, 5.3, 7.0, 1.6, 170.0, NULL, 'usda', '170886', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('4c6e433b-74a5-4a36-b04a-a494ad0f8b08', 'زبادي يوناني قليل الدسم', 'Yogurt, Greek, plain, lowfat', 'بيض وألبان', 73.0, 10.0, 3.9, 1.9, 170.0, NULL, 'usda', '170903', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ddd62d4b-b9bc-4d28-bf65-908b9c48f674', 'زبدة فول سوداني', 'Peanut butter, smooth style, without salt', 'دهون ومكسرات', 598.0, 22.2, 22.3, 51.4, 16.0, 'ملعقة كبيرة', 'usda', '172470', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('61b23d68-9f84-4fa5-93a0-63e12cc81b30', 'زبادي يوناني خالي الدسم', 'Yogurt, Greek, plain, nonfat (Includes foods for USDA''s Food Distribution Program)', 'بيض وألبان', 59.0, 10.2, 3.6, 0.4, 170.0, NULL, 'usda', '170894', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('68aedb80-dfb9-4f19-a535-8024be9e27b8', 'جبنة قريش (كوتج)', 'Cheese, cottage, lowfat, 2% milkfat', 'بيض وألبان', 81.0, 10.5, 4.8, 2.3, 113.0, 'نص كوب', 'usda', '172182', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ebabc591-9a31-4372-add7-17d66e00f93b', 'جبنة موزاريلا قليلة الدسم', 'Cheese, mozzarella, part skim milk', 'بيض وألبان', 254.0, 24.3, 2.8, 15.9, 28.0, NULL, 'usda', '170847', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('4f0217e6-1b3c-4861-b86e-b045b23172ea', 'جبنة شيدر', 'Cheese, cheddar (Includes foods for USDA''s Food Distribution Program)', 'بيض وألبان', 403.0, 22.9, 3.4, 33.3, 28.0, 'شريحة', 'usda', '173414', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d3c7667d-f385-4fce-8971-513ee7264eaa', 'جبنة فيتا', 'Cheese, feta', 'بيض وألبان', 265.0, 14.2, 3.9, 21.5, 28.0, NULL, 'usda', '173420', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('44aecd5c-6012-4a51-8f4d-01e5e2ef19b0', 'جبنة كريمية', 'Cheese, cream', 'بيض وألبان', 350.0, 6.2, 5.5, 34.4, 30.0, NULL, 'usda', '173418', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b22922eb-4344-40d0-a1c7-eeaedaa59bfa', 'واي بروتين', 'Beverages, Whey protein powder isolate', 'مكملات', 359.0, 58.1, 29.1, 1.2, 30.0, 'سكوب', 'usda', '173177', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b5f24237-1d52-4eb4-968b-107763f04c0a', 'عدس مطبوخ', 'Lentils, mature seeds, cooked, boiled, without salt', 'بقوليات', 116.0, 9.0, 20.1, 0.4, 150.0, NULL, 'usda', '172421', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('88ae6734-339f-48ef-9a30-0505d3d45d23', 'حمص مطبوخ', 'Chickpeas (garbanzo beans, bengal gram), mature seeds, cooked, boiled, without salt', 'بقوليات', 164.0, 8.9, 27.4, 2.6, 150.0, NULL, 'usda', '173757', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('20d6e8a3-c652-46b7-a1a3-536e773a88b4', 'فول مدمس (مطبوخ)', 'Broadbeans (fava beans), mature seeds, cooked, boiled, without salt', 'بقوليات', 110.0, 7.6, 19.7, 0.4, 150.0, NULL, 'usda', '173753', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('8dc0b1af-fa3e-4dc7-a24b-545a1c5c4a8c', 'فاصوليا حمراء مطبوخة', 'Beans, kidney, all types, mature seeds, cooked, boiled, without salt', 'بقوليات', 127.0, 8.7, 22.8, 0.5, 150.0, NULL, 'usda', '173740', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('82c53cbb-cb86-4f11-abea-b7628ba186dc', 'حمص بطحينة (حمص جاهز)', 'Hummus, commercial', 'بقوليات', 237.0, 7.8, 15.0, 17.8, 60.0, NULL, 'usda', '174289', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('29315620-e5e8-4765-838b-ba319e6ef090', 'تمر مجدول', 'Dates, medjool', 'فواكه', 277.0, 1.8, 75.0, 0.2, 24.0, 'حبة', 'usda', '168191', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('5e2515ee-7136-4e88-910c-d33558e39697', 'تمر (دقلة نور)', 'Dates, deglet noor', 'فواكه', 282.0, 2.5, 75.0, 0.4, 7.0, 'حبة', 'usda', '171726', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f78613e2-d2a8-4a0f-8213-426a0ec43262', 'موز', 'Bananas, raw', 'فواكه', 89.0, 1.1, 22.8, 0.3, 118.0, 'حبة وسط', 'usda', '173944', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3016b12a-61c9-474b-bd2d-f3db90e86329', 'تفاح', 'Apples, raw, with skin (Includes foods for USDA''s Food Distribution Program)', 'فواكه', 52.0, 0.3, 13.8, 0.2, 182.0, 'حبة وسط', 'usda', '171688', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('25ee7a90-4742-4413-ae0c-876655dd2206', 'برتقال', 'Oranges, raw, all commercial varieties', 'فواكه', 47.0, 0.9, 11.8, 0.1, 131.0, 'حبة', 'usda', '169097', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d01d88e6-8579-4180-8daf-f92623f1852a', 'فراولة', 'Strawberries, raw', 'فواكه', 32.0, 0.7, 7.7, 0.3, 150.0, 'كوب', 'usda', '167762', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('817a9c44-cf49-43a3-b215-8ff941600df2', 'عنب', 'Grapes, red or green (European type, such as Thompson seedless), raw', 'فواكه', 69.0, 0.7, 18.1, 0.2, 150.0, 'كوب', 'usda', '174683', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('414f4496-ca3a-4dfc-8e5a-5b838c60beda', 'بطيخ', 'Watermelon, raw', 'فواكه', 30.0, 0.6, 7.6, 0.2, 280.0, 'كوب ونص', 'usda', '167765', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('04f3b2e2-d884-4e4b-99dd-23f2da483a58', 'مانجو', 'Mangos, raw', 'فواكه', 60.0, 0.8, 15.0, 0.4, 165.0, 'كوب', 'usda', '169910', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d2b633ac-9a3a-4235-91e2-b1dfecde9d38', 'أناناس', 'Pineapple, raw, all varieties', 'فواكه', 50.0, 0.5, 13.1, 0.1, 165.0, 'كوب', 'usda', '169124', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('9df8c445-9e16-40af-894d-92fd6d9449b8', 'توت أزرق', 'Blueberries, raw', 'فواكه', 57.0, 0.7, 14.5, 0.3, 148.0, 'كوب', 'usda', '171711', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3cc7f53a-1f7a-4be9-9212-80aacd931684', 'كيوي', 'Kiwifruit, green, raw', 'فواكه', 61.0, 1.1, 14.7, 0.5, 75.0, 'حبة', 'usda', '168153', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('e5462313-2be7-4289-bc00-c69421632c8c', 'رمان', 'Pomegranates, raw', 'فواكه', 83.0, 1.7, 18.7, 1.2, 87.0, 'نص كوب حبوب', 'usda', '169134', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3e7c4cfc-a277-4fee-9518-aa5bd608e626', 'خيار', 'Cucumber, with peel, raw', 'خضار', 15.0, 0.7, 3.6, 0.1, 100.0, NULL, 'usda', '168409', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('94434693-f32e-4d27-b1df-83f1a0210f92', 'طماطم', 'Tomatoes, red, ripe, raw, year round average', 'خضار', 18.0, 0.9, 3.9, 0.2, 120.0, 'حبة وسط', 'usda', '170457', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('4da36b09-94c3-468b-9e4c-56eb7b4d74d9', 'خس', 'Lettuce, cos or romaine, raw', 'خضار', 17.0, 1.2, 3.3, 0.3, 50.0, NULL, 'usda', '169247', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('fb5155bb-1c6d-40af-b4e3-af5a1b94422d', 'جزر', 'Carrots, raw', 'خضار', 41.0, 0.9, 9.6, 0.2, 60.0, 'حبة', 'usda', '170393', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('224759e8-d183-47cb-81ee-4ff7f5ff9334', 'بروكلي مطبوخ', 'Broccoli, cooked, boiled, drained, without salt', 'خضار', 35.0, 2.4, 7.2, 0.4, 90.0, NULL, 'usda', '169967', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('8de50d92-f39f-420e-8c83-738a61d98ca8', 'سبانخ', 'Spinach, raw', 'خضار', 23.0, 2.9, 3.6, 0.4, 30.0, 'كوب', 'usda', '168462', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('bdfdbd5b-0132-4711-8cea-82cb5183e1f2', 'فلفل رومي أحمر', 'Peppers, sweet, red, raw', 'خضار', 26.0, 1.0, 6.0, 0.3, 120.0, 'حبة', 'usda', '170108', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d6d6e8d0-ffa6-40de-bb45-2304d3ed90db', 'بصل', 'Onions, raw', 'خضار', 40.0, 1.1, 9.3, 0.1, 110.0, 'حبة وسط', 'usda', '170000', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('4fb29161-2600-4099-b57f-cd393db012f7', 'فطر (مشروم)', 'Mushrooms, white, raw', 'خضار', 22.0, 3.1, 3.3, 0.3, 70.0, 'كوب', 'usda', '169251', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('fc2071a6-4fce-4ed4-ab3a-5af7f400ab3e', 'كوسا مطبوخة', 'Squash, summer, zucchini, includes skin, cooked, boiled, drained, without salt', 'خضار', 15.0, 1.1, 2.7, 0.4, 180.0, NULL, 'usda', '169292', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ec6e34eb-b3b3-4865-a470-41d4eb799d03', 'باذنجان مطبوخ', 'Eggplant, cooked, boiled, drained, without salt', 'خضار', 35.0, 0.8, 8.7, 0.2, 100.0, NULL, 'usda', '169229', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('71a8f284-df89-4d12-ab52-122d49037500', 'ذرة حلوة مطبوخة', 'Corn, sweet, yellow, cooked, boiled, drained, without salt', 'خضار', 96.0, 3.4, 21.0, 1.5, 150.0, NULL, 'usda', '169999', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f2fb9af2-6015-46f9-937e-9dbd8b25006e', 'أفوكادو', 'Avocados, raw, all commercial varieties', 'دهون ومكسرات', 160.0, 2.0, 8.5, 14.7, 50.0, 'ثلث حبة', 'usda', '171705', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('867b1633-9253-4e87-9c10-4556437deff1', 'زيت زيتون', 'Oil, olive, salad or cooking', 'دهون ومكسرات', 884.0, 0.0, 0.0, 100.0, 5.0, 'ملعقة صغيرة', 'usda', '171413', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('1e2a10ff-a86a-4bfe-b225-14dc35e21180', 'زبدة', 'Butter, salted', 'دهون ومكسرات', 717.0, 0.9, 0.1, 81.1, 5.0, 'ملعقة صغيرة', 'usda', '173410', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('43b098f3-7a42-4635-a673-b67cbbf231eb', 'لوز', 'Nuts, almonds', 'دهون ومكسرات', 579.0, 21.2, 21.6, 49.9, 28.0, 'حفنة', 'usda', '170567', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('effaef98-f2dc-49f3-ae33-51aceb6a14e0', 'كاجو', 'Nuts, cashew nuts, raw', 'دهون ومكسرات', 553.0, 18.2, 30.2, 43.9, 28.0, 'حفنة', 'usda', '170162', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('9fce2e3c-a961-431e-af66-29f9b9aaff13', 'فستق حلبي', 'Nuts, pistachio nuts, raw', 'دهون ومكسرات', 560.0, 20.2, 27.2, 45.3, 28.0, 'حفنة', 'usda', '170184', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('e82e10d3-a12f-48a7-8336-0d835fec7c81', 'جوز (عين الجمل)', 'Nuts, walnuts, english', 'دهون ومكسرات', 654.0, 15.2, 13.7, 65.2, 28.0, 'حفنة', 'usda', '170187', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('fe27976e-ace0-4fc4-9dc6-d5587278bc2e', 'فول سوداني', 'Peanuts, all types, raw', 'دهون ومكسرات', 567.0, 25.8, 16.1, 49.2, 28.0, 'حفنة', 'usda', '172430', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a95dfe6c-7516-42de-95fd-6425627befbb', 'طحينة', 'Seeds, sesame butter, tahini, from roasted and toasted kernels (most common type)', 'دهون ومكسرات', 595.0, 17.0, 21.2, 53.8, 15.0, 'ملعقة كبيرة', 'usda', '170189', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('1934e797-f146-4629-9528-94a778732fb2', 'بذور الشيا', 'Seeds, chia seeds, dried', 'دهون ومكسرات', 486.0, 16.5, 42.1, 30.7, 12.0, 'ملعقة كبيرة', 'usda', '170554', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('6f64aff9-b2d5-43f8-9e92-cab29c172230', 'عسل', 'Honey', 'حلويات ومشروبات', 304.0, 0.3, 82.4, 0.0, 21.0, 'ملعقة كبيرة', 'usda', '169640', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('1ac98157-90aa-48db-a857-9e016a1309ef', 'سكر أبيض', 'Sugars, granulated', 'حلويات ومشروبات', 387.0, 0.0, 100.0, 0.0, 4.0, 'ملعقة صغيرة', 'usda', '169655', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('37680773-19fb-47b5-ac80-2dfad10b3e18', 'شوكولاتة داكنة 70-85%', 'Chocolate, dark, 70-85% cacao solids', 'حلويات ومشروبات', 598.0, 7.8, 45.9, 42.6, 20.0, NULL, 'usda', '170273', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ed0074c4-d12e-4df3-913e-7da8121648ab', 'عصير برتقال', 'Orange juice, raw (Includes foods for USDA''s Food Distribution Program)', 'حلويات ومشروبات', 45.0, 0.7, 10.4, 0.2, 248.0, 'كوب', 'usda', '169098', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('be1cfaf9-634d-4514-88a4-272dbf0f1a2e', 'مايونيز', 'Salad dressing, mayonnaise, regular', 'صوصات', 680.0, 1.0, 0.6, 74.9, 15.0, 'ملعقة كبيرة', 'usda', '171009', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('969b69e4-e187-45e8-9229-ac921fd68aed', 'كاتشب', 'Catsup', 'صوصات', 101.0, 1.0, 27.4, 0.1, 17.0, 'ملعقة كبيرة', 'usda', '168556', true, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;



INSERT INTO public.policies VALUES ('terms', 'الشروط والأحكام', '- يبدأ الاشتراك بعد التحقق من وصول التحويل البنكي، وتعبئة استبيان المتدرب.
- ساعات العمل: الأحد – الخميس، 12 ظهراً – 9 مساءً. الرد على الرسائل خلال 48 ساعة عمل.
- البرنامج لا يغني عن الاستشارة الطبية، والمتدرب مسؤول عن الإفصاح عن أي إصابة أو حالة صحية.
- الجداول ملك المتدرب مدى الحياة ويمكنه التعديل عليها.
- الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي.', 0, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.policies VALUES ('refund', 'الضمان والاسترجاع', '- في اشتراكات 3 أشهر لباقات المتابعة (المكثفة، المتقدمة، الأساسية): يُسترد المبلغ كاملاً إذا لم يتحسن أي من مؤشرات التقدم (متوسط الوزن الأسبوعي، محيط الخصر، القوة في التمارين الأساسية) بعد 12 أسبوعاً.
- شروط الضمان: إرسال المراجعة الأسبوعية كل أسبوع، وأخذ القياسات بانتظام، وتصوير التمارين وإرسالها، والالتزام بجدول التغذية المخصص في الباقات التي تشملها.
- يُطلب الاسترجاع عبر واتساب خلال 14 يوماً من نهاية الأشهر الثلاثة، ويُرجع المبلغ بتحويل بنكي.
- التجديد المجاني: اشتراك 3 أشهر يُكافأ بـ 3 أشهر إضافية عند التزام 90% فأكثر وتقدم واضح في مؤشرات التقدم. صور التطور تُرسل للمدربة للتوثيق (للرجال مع تغطية الوجه والسرة)، ونشرها اختياري.', 1, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.policies VALUES ('privacy', 'سياسة الخصوصية', '- نجمع: الاسم، البريد الإلكتروني (للدخول إلى حسابك)، رقم الجوال (واتساب)، الباقة المختارة، ومعلومات الاستبيان التي تكتبها بنفسك (ومنها معلومات صحية وقياسات اختيارية).
- الغرض: تنفيذ طلبك، وتصميم برنامجك ومتابعتك، والتواصل معك بخصوصه فقط.
- المعلومات الصحية تُحفظ منفصلة، ولا يطّلع عليها إلا أنت والمدربة، ولا تُرسل في رسائل البريد أو التنبيهات.
- الدفع بتحويل بنكي مباشر لحساب المؤسسة، والموقع لا يطلب أو يخزن أي بيانات بنكية أو بيانات بطاقات. إيصال التحويل يُستخدم لتأكيد طلبك فقط، ويُحفظ في تخزين خاص لا يُفتح إلا لك وللمدربة.
- لا نبيع بياناتك ولا نشاركها مع أي طرف لأغراض تسويقية، ولا تُنشر نتيجتك أو صورتك إلا بموافقتك الصريحة.
- تقدر تطلب نسخة من بياناتك أو حذفها أو سحب موافقتك على النشر بمراسلتنا على واتساب.', 2, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.policies VALUES ('reviews', 'سياسة التقييمات', '- يكتب التقييم فقط من اشترى خدمة وبدأها فعلاً، وتقييم واحد لكل طلب.
- كل تقييم يُراجع قبل ظهوره للعامة، ولا يُعدّل نصه أبداً.
- تختار بنفسك طريقة ظهور اسمك: الاسم كامل، أو الاسم الأول فقط، أو بدون اسم. والموافقة على النشر منفصلة واختيارية.
- لا يُنشر تقييم يحتوي أرقام هواتف أو بريد أو روابط أو تفاصيل صحية خاصة أو إساءة لأي شخص.
- يحق للمدربة الرد على التقييم، أو إخفاء التقييم المخالف لهذه السياسة مع تسجيل السبب.
- تقدر تطلب إخفاء تقييمك في أي وقت بمراسلتنا على واتساب.', 3, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;



INSERT INTO public.products VALUES ('40cf7e86-201d-4167-8f1a-9a42f30e283c', 'intensive', 'follow', 'الباقة المكثفة', 'الأنسب للمبتدئين ولمن يحتاج متابعة أسبوعية مع زوم: تمرين + تغذية + زوم + جلسة حضورية', '[{"text": "جلسة حضورية مجانية لمدة ساعة لتصحيح التكنيك والتأكد من جودة التمرين (للبنات في المنطقة الشرقية)", "included": true}, {"text": "ملف شامل للخطة التدريبية والتغذية مع شروحات وافية للتمارين، بالمنزل أو بالنادي", "included": true}, {"text": "4 مكالمات زوم شهرياً نتابع فيها تطورك واستفساراتك الرياضية والنفسية", "included": true}, {"text": "مناقشة أسبوعية لتطورك البدني والنفسي (فيديو أو تسجيل صوتي) مع تعديل السعرات أو التمرين عند الحاجة", "included": true}, {"text": "شرح سهل ومبسط لتطبيق حساب السعرات MyFitnessPal", "included": true}, {"text": "كتيب شامل للرياضة والتغذية", "included": true}, {"text": "مساعدتك على اختيارات أنسب لصحتك ونمط حياتك في التغذية والروتين اليومي", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}]', NULL, 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.', true, NULL, 'published', 0, false, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('bc8def06-636e-48b1-b622-53294de3a5cb', 'advanced', 'follow', 'الباقة المتقدمة', 'لمن عنده خبرة ويحتاج تمرين + تغذية مع متابعة أسبوعية، بدون زوم', '[{"text": "ملف شامل للخطة التدريبية والتغذية مع شروحات وافية للتمارين، بالمنزل أو بالنادي", "included": true}, {"text": "مناقشة أسبوعية لتطورك البدني والنفسي (فيديو أو تسجيل صوتي) مع تعديل السعرات أو التمرين عند الحاجة", "included": true}, {"text": "كتيب شامل للرياضة والتغذية", "included": true}, {"text": "مساعدتك على اختيارات أنسب لصحتك ونمط حياتك في التمرين والروتين اليومي", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}, {"text": "مكالمات زوم والجلسة الحضورية (في المكثفة فقط)", "included": false}]', NULL, 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.', false, NULL, 'published', 1, false, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('2293097e-3e77-4254-97bc-0109f0b96ef5', 'basic', 'follow', 'الباقة الأساسية', 'لمن يعرف يضبط أكله ويحتاج خطة تمرين فقط، ومتابعة كل أسبوعين', '[{"text": "ملف شامل للخطة التدريبية مع شروحات وافية للتمارين، بالمنزل أو بالنادي", "included": true}, {"text": "مناقشة كل أسبوعين لتطورك البدني والنفسي (فيديو أو تسجيل صوتي) مع تعديل التمرين عند الحاجة", "included": true}, {"text": "كتيب شامل للرياضة والتغذية", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}, {"text": "بدون خطة تغذية", "included": false}]', NULL, 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.', false, NULL, 'published', 2, false, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('6976a743-bb7e-48c0-a5e6-539dc18a4dd1', 'nutrition', 'follow', 'باقة التغذية', 'لمن يحتاج خطة تغذية شاملة ويتعلم حساب السعرات، بدون خطة تمرين', '[{"text": "خطة تغذية شاملة تناسب هدفك ونمط حياتك", "included": true}, {"text": "تحديد السعرات المناسبة لك ولهدفك", "included": true}, {"text": "تعليمك حسبة السعرات ومساعدتك باختيارات تغذية تناسبك", "included": true}, {"text": "ملف Excel لمتابعة التطور والقياسات", "included": true}, {"text": "مناقشة أسبوعية لعلاقتك بالتغذية في المنزل أو خارجه", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}, {"text": "لا تحتاجها إذا كنت مشتركاً في المكثفة أو المتقدمة، لأن التغذية ضمنها", "included": false}]', 'شهر واحد · غالباً لا تحتاج تجديد', 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي، ولا يوجد تجديد تلقائي. ضمان الاسترجاع يشمل اشتراكات 3 أشهر للمكثفة والمتقدمة والأساسية فقط.', false, NULL, 'published', 3, false, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('83a6cb99-ea70-4381-b075-6ca59ed419b7', 'custom-training-plan', 'files', 'بديل التدريب الشخصي', 'لمن لا يحتاج متابعة (متقدم)، أو كبديل أوفر للتدريب الشخصي', '[{"text": "جدول تمرين مخصص لعدد أيام التمرين اللي تحتاجها", "included": true}, {"text": "طريقة حساب الجهد وعدد الجولات المطلوبة", "included": true}, {"text": "تقدر تحمّل الجدول على جهازك", "included": true}]', NULL, 'جدول مخصص بعد الاستبيان تستلمه كملف، وتقدر تحمّله على جهازك. بدون متابعة.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي. الجداول لك مدى الحياة وتقدر تعدّل عليها.', false, NULL, 'published', 4, false, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('dc5a4671-ade0-450e-930f-0d9757cd6585', 'training-nutrition-plan', 'files', 'جدول تمارين مع التغذية', 'لمن لا يحتاج متابعة (متقدم)، أو كبديل أوفر للتدريب الشخصي', '[{"text": "جدول تمرين مخصص لعدد أيام التمرين اللي تحتاجها", "included": true}, {"text": "طريقة حساب الجهد وعدد الجولات المطلوبة", "included": true}, {"text": "جدول تغذية فيه خيارات تناسب هدفك الرياضي", "included": true}, {"text": "تقدر تحمّل الجدول على جهازك", "included": true}]', NULL, 'جدول مخصص بعد الاستبيان تستلمه كملف، وتقدر تحمّله على جهازك. بدون متابعة.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي. الجداول لك مدى الحياة وتقدر تعدّل عليها.', false, NULL, 'published', 5, false, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('33beab11-c511-4529-a396-f02740db99dd', 'nutrition-consultation', 'consult', 'جلسة استشارة تغذية', 'لمن عنده أسئلة محددة في التغذية: جلسة وحدة تكفي لحسبة سعراتك ونصائح الأكل.', '[{"text": "مناقشة كل أسئلتك في مجال التغذية", "included": true}, {"text": "حسبة سعرات مناسبة لهدفك مع اقتراحات لأصناف الطعام", "included": true}, {"text": "نصائح في المكملات، وكيف تأكل برّا بطريقة صحيحة", "included": true}]', NULL, 'جلسة عبر Google Meet أو واتساب — المناسب لك.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي.', false, NULL, 'published', 6, false, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('c08427bc-9348-4a17-bd75-cf0e780ef81d', 'training-consultation', 'consult', 'جلسة استشارة تمرين', 'لمن عنده أسئلة محددة في التمرين: جلسة وحدة تكفي لتعديل جدولك وتصحيح التكنيك.', '[{"text": "مناقشة كل أسئلتك في مجال التمرين", "included": true}, {"text": "تعديل جدولك الرياضي بما يناسب هدفك، مع اقتراحات لتمارين المرونة", "included": true}, {"text": "تصحيح تكنيك التمارين اللي تشك إنها غلط أو تسبب لك ألم", "included": true}, {"text": "التأكد من أن جودة تمرينك مناسبة للبناء العضلي", "included": true}]', NULL, 'جلسة عبر Google Meet أو واتساب — المناسب لك.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي.', false, NULL, 'published', 7, false, '2026-09-27 19:19:43.694459+00', '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;



INSERT INTO public.product_offers VALUES ('5d162791-4b1d-4edb-8f1b-3b50bc254960', '40cf7e86-201d-4167-8f1a-9a42f30e283c', 'int1', 'شهر واحد', 1, 59900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('fb3472ea-2d12-4446-82eb-fd725bc004b5', '40cf7e86-201d-4167-8f1a-9a42f30e283c', 'int3', '3 أشهر', 3, 155000, 'SAR', true, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('9014d6d7-aab3-42de-baed-9b7691389e2d', 'bc8def06-636e-48b1-b622-53294de3a5cb', 'adv1', 'شهر واحد', 1, 49900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('502dee78-8133-4d31-b3e8-4a567a432ea9', 'bc8def06-636e-48b1-b622-53294de3a5cb', 'adv3', '3 أشهر', 3, 125000, 'SAR', true, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('401b39a5-097f-46e7-9212-1ce68c5a3561', '2293097e-3e77-4254-97bc-0109f0b96ef5', 'bas1', 'شهر واحد', 1, 34900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('5bd853f1-d5ff-40f4-9d92-41c2e14976c8', '2293097e-3e77-4254-97bc-0109f0b96ef5', 'bas3', '3 أشهر', 3, 95000, 'SAR', true, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('075b26d2-d7f5-4680-bce6-cc1c205f4810', '6976a743-bb7e-48c0-a5e6-539dc18a4dd1', 'nut1', 'شهر واحد', 1, 25000, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('0db8fe67-7208-4130-a8df-b1a18cc32383', '83a6cb99-ea70-4381-b075-6ca59ed419b7', 'diy', 'دفعة واحدة', 0, 19900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('fee56a53-6c8b-4a35-bdba-5602dccc3c74', 'dc5a4671-ade0-450e-930f-0d9757cd6585', 'diyN', 'دفعة واحدة', 0, 25000, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('edfb71af-4653-428f-9dbf-603ef4b0c5c2', '33beab11-c511-4529-a396-f02740db99dd', 'cN', 'دفعة واحدة', 0, 15000, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('d6f2ec13-9fa5-4331-a5d5-9b03d8a2ddea', 'c08427bc-9348-4a17-bd75-cf0e780ef81d', 'cT', 'دفعة واحدة', 0, 18900, 'SAR', true, 0) ON CONFLICT DO NOTHING;



INSERT INTO public.reviews VALUES ('a1da27ed-dbf5-4acd-8617-8c4ecdb28c9d', 'legacy', NULL, NULL, NULL, NULL, 'اشتركت معها 3 شهور وكانت أول مره التزم بالتمرين بعد سحبات سنين، اسلوبها سهل وسريع بس نتايجه واضحه من اول اسبوعين قياسات جسمي بدت تتغير والكوتش مريحه نفسيًا وشاطرة الله يعطيها العافيه غيرت حياتي واعطتني افضل بداية 🙏🏻', 'first', 'ريم', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 0, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('d898aa2e-4ccd-46b2-85bb-2d8656aa98c3', 'legacy', NULL, NULL, NULL, 5, 'من أصدق التجارب اللي مرّيت فيها! تدريبك ما كان بس جداول رياضه وتغذية كان دعم نفسي وتحفيز وتغيير حقيقي في حياتي حسّيت بفرق كبير في جسمي وطاقتي وثقتي بنفسي من أول أسبوع شكراً من القلب على تعبك وحرصك على كل تفصيلة وتعطي من قلبك، فعلاً you are the best coach ever تستاهلين كل النجاح والله ❤️', 'first', 'نورة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 1, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('e3ff1efe-0647-4456-ab73-0d188f03527f', 'legacy', NULL, NULL, NULL, 5, 'بعد شهر من الالتزام بالجدول، لاحظت فرق واضح! متنوع وفعال، أنصح فيه بشدة 😍👌', 'first', 'البندري', 'مارس 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 2, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('cb06bb8d-96eb-4c00-b497-ccc932eb2eaa', 'legacy', NULL, NULL, NULL, NULL, 'رغم ان فتره تدريبي معاها كانت اقل من شهرين السنه الماضيه الا ان نتايج هالشهرين مستمره معي الى اليوم 😍 اسلوب احترافي وفعال وتركز على بناء وتطوير عادات تدوم مو بس تمارين مؤقته 👍🏻', 'first', 'خديجة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 3, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('a4870af9-f7ca-436d-81e8-a628ffa598cb', 'legacy', NULL, NULL, NULL, 5, 'كوتش ساره جداً شاطره و بروفيشنال، جداً متعاونه و تعرف شغلها كويس، جداً لطيفه، كنت لفتره متدربه عندها و كنت أشوف نتايج بطله بالاضافه لكوني اروح اتمرن و أنا مستمتعه، شكراً ساره', 'first', 'نجمة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 4, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('dddcc0f0-8c6c-465f-8031-2b3f2742706a', 'legacy', NULL, NULL, NULL, 5, 'ممتاز جدول حلو ومرتب جدا وفرق معي كثير 🤍', 'first', 'سعود', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 5, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('01e84654-28f9-4e07-b93e-d419c21d7117', 'legacy', NULL, NULL, NULL, 5, 'كنت اعاني من الم بظهري مستمررر سنوات وانحراف بالعمود ولكن بفضل الله ثم المدربة تحسنت بنسبة كبيرة وتابع معي خطوة بخطوة بكل أمانة وإتقان الله يكثر من امثالك 🤍', 'first', 'ش**س**', 'أغسطس 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 6, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('ebda01e7-a936-4e51-9d65-e3371d8ae266', 'legacy', NULL, NULL, NULL, 5, 'الشكر يعجز عنك يااروع كوتش باشتراكي معك شفت صحة وراحة بعد الله وساعدتيني مره بمشكلة ظهري وضعف العضلات العلوية وانعكس على نفسيتي وادائي اليومي شكررا شكرا من القلب وياحظنا فيك', 'first', 'فاطمة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 7, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('0b56ba8c-ff8d-40ee-a1a5-fbc581c51e22', 'legacy', NULL, NULL, NULL, 5, 'مره استفدت بالتدريب مع كوتش ناف و مبسوطه ان في احد بذمة و ضمير جالس يتابع تقدمي و ينصحني من قلب الله يسعدك ويوفقك ❤️', 'first', 'ميثاء', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 8, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('c89a0719-f82d-47f1-a4c0-87ddd6053686', 'legacy', NULL, NULL, NULL, 5, 'تجربه ولا أروع ! أحب جداولها وقد ايش تختصر وتعطيك المهم والاهم والنتايج رهيييبه ❤️', 'first', 'أمجاد', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 9, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('3959a429-838a-422f-9fe4-5302258dc47f', 'legacy', NULL, NULL, NULL, 5, 'افضل مدربة بالمجرة، كنت دبه ونحفت بثلاث شهور بس، i highly recommend her she is the best 💗', 'first', 'شروق', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 10, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('98771dfb-2d90-4dd2-9ccf-33413cfd7dc9', 'legacy', NULL, NULL, NULL, 5, 'الجدول ممتاز و فعّال لفترة الصيام، يساعدك تنظم وقتك ويقدّم توصيات غذائيه و خطه تمارين تساعدك تحافظ على لياقتك بدون إرهاق 👍🏻. خيار ممتاز خاصة للأشخاص للي وقتها محدود ومزحوم فرمضان.', 'first', 'خديجة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 11, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;



INSERT INTO public.site_settings VALUES ('reminders', '{"review_text": "مرحباً {name}، تذكير بمراجعتك الأسبوعية: المراجعة مفتوحة من {window_start} إلى {window_end}.", "sub_expiry_days": [7, 3], "sub_expiry_text": "مرحباً {name}، اشتراكك في {product} ينتهي بتاريخ {end_date}. للتجديد أو الاستفسار تواصل معنا.", "review_lead_days": 1, "missed_review_text": "مرحباً {name}، ما وصلتنا مراجعة الأسبوع المنتهي في {window_end}. متى ما تيسّر لك، حدّثها عشان نتابع تقدمك.", "review_window_days": 2, "manual_cooldown_minutes": 10}', false, NULL, '2026-09-27 19:19:43.421848+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('hero', '{"lead": "خطة تدريب وغذاء منظمة، متابعة للتقدم، وتعديلات أسبوعية تناسب مستواك وظروفك.", "title": "برامج تدريب وتغذية مخصصة لأهدافك", "eyebrow": "Nav Coaching · الكوتش ساره", "tagline": "Where Passion Meets Quality", "title_tail": "تحت إشراف مدربة يدفعها الشغف"}', true, NULL, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('badges', '["خصم 10% للطلاب", "مجاني لأهل غزة", "ضمان استرجاع المبلغ بشروط"]', true, NULL, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('why', '[{"body": "البرنامج يُصمم بعد استبيان مفصل لهدفك وأيامك المتاحة وأدواتك وأي إصابة تحتاج مراعاة.", "title": "مبني على هدفك ومستواك"}, {"body": "مراجعة منتظمة بالفيديو أو الصوت، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.", "title": "متابعة أسبوعية واضحة"}, {"body": "نعدّل التمرين والسعرات بناءً على قياساتك والتزامك، عشان تثبت النتيجة.", "title": "تعديلات حسب تقدمك"}]', true, NULL, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('how_steps', '[{"body": "اختر الباقة والمدة، وعبّي استبيان قصير عن هدفك ومستواك وأيامك وأي إصابة.", "title": "اختر برنامجك وعبّي الاستبيان"}, {"body": "بعد الاستبيان يظهر لك رقم طلبك وبيانات الحساب. حوّل وارفع صورة الإيصال من صفحة طلبك.", "title": "حوّل المبلغ"}, {"body": "بعد التحقق من التحويل أتواصل معك خلال 48 ساعة عمل، وتستلم ملف برنامجك وتبدأ المتابعة.", "title": "استلم برنامجك وابدأ"}]', true, NULL, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('about', '{"bio": "مدربة شخصية معتمدة، أدرب منذ 2017. أساعدك تبني روتين تدريب وتغذية واضح يناسب هدفك ووقتك ومستواك، مع متابعة أسبوعية تساعدك تستمر وتتقدم.", "fit": ["اللي يؤمن إن التمرين أسلوب حياة، مو تمرين لشكل مؤقت أو لفترة الصيف بس.", "**وإذا ما التزمت؟** أحاول أفهم أسبابك، وأساعدك تعالجها بقدر ما أقدر. وإذا كان الموضوع أكبر من اللي أقدر أقدمه، أقول لك بصراحة وأعتذر عن تدريبك."], "name": "الكوتش ساره | ناڤ", "certs": ["Saudi Reps — Level 4", "NCSF", "Menno Henselmans CPT", "Functional Mobility", "Pre & Postnatal Training", "Prenatal Fitness Training — Aspire Academy", "ماجستير تدريب رياضي — جامعة ستيرلنق"], "notes": [{"body": "لأني جاية من عالم الرياضات الإلكترونية، صممت باقة خاصة للقيمرز: لياقة أفضل داخل وخارج الشاشة، والتعامل مع آلام الظهر والمفاصل من الجلوس الطويل.", "href": "/programs/gamers", "label": "شوف باقة القيمرز ←", "title": "للاعبي الألعاب الإلكترونية"}, {"body": "تدريب الحوامل عندي حضوري فقط. أونلاين يصعب أتأكد إن التمرين يتنفذ بإتقان، والحمل فترة مهمة جداً تحتاج هالتأكد. أونلاين أقدم للحوامل متابعة التغذية فقط.", "href": "", "label": "", "title": "للحوامل"}], "story": ["قبل ما أصير مدربة، كنت متدربة تعبت من التجارب. اشتركت مع مدربات أجانب، وما لقيت أحد يشرح لي التمرين صح أو يهتم بأهدافي.", "لين اشتركت مع الكوتش سحر الحارثي. غيّرت نظرتي للتمرين، وحفّزتني أصير كوتش، وإلى اليوم أشكرها على كل اللي علمتني إياه. من هنا قررت أكون الشخص اللي احتجته أنا.", "والرياضة جزء مني من بدري: لعبت كرة السلة وكنت كابتن فريق السلة في جامعة الإمام عبدالرحمن بن فيصل، ولعبت باحتراف في الرياضات الإلكترونية. بدأت التدريب في 2017 مع كرة السلة، واشتغلت مساعد مدرب في نادي الجامعة، وبعدها دربت في بيور جم وجمنيشن وفتنس لاونج ونوادي خاصة."], "points": ["برنامج مبني على هدفك ومستواك.", "متابعة أسبوعية واضحة.", "تعديلات مستمرة حسب تقدمك والتزامك."], "pillars": [{"body": "ما أرسل لك جدول وأتركك. أراجعه معك بمقطع فيديو أشرح فيه كل شي، عشان تبدأ وأنت فاهم وش تسوي وليش.", "title": "جدولك مشروح بالفيديو"}, {"body": "ما أمشي على أنظمة الحرمان أبداً. خطتك تناسب حياتك، مو قائمة ممنوعات.", "title": "بدون حرمان"}, {"body": "أتابعك كل أسبوع وأهتم بالتزامك، وأعدّل خطتك حسب تقدمك وظروفك.", "title": "متابعة جادة وخطة واقعية"}, {"body": "حب تعليم الناس معي من الصغر. اللي أعرفه ما أبخل فيه، علمياً ونفسياً، وما أوقف عن البحث والتعلم عشان أتطور وأطورك معي.", "title": "أعلّمك، مو بس أدربك"}], "home_bio": "مدربة شخصية معتمدة، أدرب منذ 2017، وكابتن سابقة لفريق السلة في جامعة الإمام عبدالرحمن بن فيصل. أساعدك تبني روتين تدريب وتغذية واضح يناسب هدفك ووقتك ومستواك، مع متابعة أسبوعية وبدون أنظمة حرمان.", "fit_title": "أكثر شخص أفرق معه", "experience": ["أدرب منذ 2017، والبداية في كرة السلة.", "مساعد مدرب في نادي الجامعة.", "مدربة في بيور جم، وجمنيشن، وفتنس لاونج، ونوادي خاصة."], "story_title": "صرت الشخص اللي كنت أحتاجه", "pillars_title": "وش يميز التدريب معي؟", "experience_title": "شهاداتي وخبرتي"}', true, NULL, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('intro_video', '{"url": "", "body": "مقطع قصير أتكلم فيه عن نفسي وخلفيتي وطريقة شغلي مع المتدربين.", "title": "تعرّف عليّ في دقيقة"}', true, NULL, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('testimonials_disclaimer', '"التجارب شخصية وتختلف النتائج من شخص لآخر حسب الالتزام والحالة، والتدريب لا يغني عن استشارة الطبيب أو أخصائي العلاج الطبيعي."', true, NULL, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('prices_note', '"الأسعار بالريال السعودي. الدفع بتحويل بنكي على حساب المؤسسة."', true, NULL, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('checkins', '{"enabled": true, "questions": [{"q": "ملاحظاتك الصحية؟ الحركة اليومية وجودة الحياة صارت أحسن؟", "topic": "الصحة العامة"}, {"q": "أداؤك في التمارين؟ في تقدم في الأوزان والأداء؟", "topic": "التمارين"}, {"q": "فرق في شكلك ومظهرك؟ إيجابي أو سلبي؟", "topic": "المظهر"}, {"q": "فرق في الملابس أو المقاسات؟ إيجابي أو سلبي؟", "topic": "الملابس"}, {"q": "النظام الغذائي — قدرت تمشي عليه؟ فيه صعوبة؟", "topic": "الغذاء"}, {"q": "تحسّ بالجوع واجد؟ إن وُجد، كم تعطيه من 5؟", "topic": "الجوع"}, {"q": "أي ملاحظات سلبية تبي تشاركها؟ (مهمة أو بسيطة — نتقبل النقد)", "topic": "ملاحظات سلبية"}, {"q": "أي إشكاليات أو ملاحظات إضافية تحتاج مساعدة فيها؟", "topic": "ملاحظات أخرى"}, {"q": "وصلت لأي أسبوع تدريبي الآن؟", "topic": "الأسبوع"}]}', true, NULL, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('contact', '{"whatsapp": "966599162724", "instagram": "https://www.instagram.com/navvcoaching/"}', true, NULL, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('response_time', '"48 ساعة عمل (الأحد – الخميس، 12 ظهراً – 9 مساءً)"', true, NULL, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('legal', '{"cr": "7050950752", "name": "مؤسسة ناف كوتشنق للتدريب الرياضي"}', true, NULL, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('bank', '{"iban": "SA1280000139608016245411", "bankName": "مصرف الراجحي", "accountName": "مؤسسة ناف كوتشنق للتدريب الرياضي"}', true, NULL, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('program_shots', '[{"h": 720, "w": 754, "alt": "لقطة من صفحة «حسابي» ببيانات مثال: شريط الالتزام، أيام تمرين الأسبوع الحالي، ملخص تغذية اليوم، وروتين المكملات", "src": "shots/my-program.webp", "title": "برنامجي", "caption": "أول ما تدخل حسابك: نسبة التزامك وأسابيعك المتتالية، أيام تمرين الأسبوع، تغذية اليوم مقابل أهدافك، وروتين المكملات."}, {"h": 960, "w": 1148, "alt": "لقطة من صفحة برنامج التمرين ببيانات مثال: أيام الأسبوع، وبطاقة كل تمرين مع المستهدف وخانات الوزن والتكرارات وRIR", "src": "shots/training-log.webp", "title": "تسجيل التمرين", "caption": "لكل تمرين المستهدف من الجولات والتكرارات وRIR، وتسجّل وزنك وتكراراتك من جوالك، ولك تبديله ببديل تختاره المدربة."}, {"h": 1020, "w": 1148, "alt": "لقطة من صفحة التغذية ببيانات مثال: ملخص اليوم مقابل الأهداف، ونموذج إضافة أكلة، وأكل اليوم حسب الوجبات", "src": "shots/nutrition-day.webp", "title": "التغذية اليومية", "caption": "أهدافك اليومية من السعرات والماكروز وكم باقي لك، وتسجّل أكلك من جداولك الغذائية أو بالغرام من قاعدة الأكل."}, {"h": 307, "w": 1116, "alt": "لقطة من لوحة التقدم ببيانات مثال: رسم الوزن ورسم القياسات", "src": "shots/progress-charts.webp", "title": "لوحة التقدم", "caption": "وزنك وقياساتك برسوم واضحة أسبوعاً بأسبوع، ببيانات مثال."}]', true, NULL, '2026-09-27 19:19:43.694459+00') ON CONFLICT DO NOTHING;
COMMIT;
