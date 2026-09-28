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

-- ---------- المحتوى المستورد من الموقع الحالي ----------
INSERT INTO public.exercises VALUES ('b9b18de0-f1a6-426d-9f8b-589404866006', 'Single Leg Raise', 'Core / البطن والكور', '{"Glutes / المؤخرة","Hamstrings / الخلفية"}', NULL, NULL, 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/ZJodU5OOaiA?si=p6ZD9dpzyRKBUn16', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a59403c0-ae92-4c15-9f4e-db96d4c4cf7f', 'Back Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/bEv6CCg2BC8', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('11aee3da-362d-4e7c-91c6-17dac7e010df', 'Box Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtube.com/shorts/9uhEh9gpwUU?si=xaTY7AJiCeQfa3by', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل.', 'تعليمات بديلة في المصدر (صف 13): ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل، انزل واثبت على البوكس ثانية وارفع.', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d54624c1-3ac8-4263-82da-440a3e4781f6', 'Hack Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/0tn5K9NlCfo', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Machine Squat / سكوات بالجهاز', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8a31e631-da2f-4e39-beb8-6a8f39553600', 'Mid Leg Press', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/s9-zeWzPUmA', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Leg Press / ضغط الأرجل', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('20993925-3ffd-4b18-970e-c37916ee4cdc', 'Quads Leg Press', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/A218isnErfM', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي، ثبت القدمين أسفل اللوح لاستهداف أكبر للكوادز.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Leg Press / ضغط الأرجل', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('42c60881-1299-471f-83e7-62fc3088a65c', 'Deficit Goblet Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/9719SO5zvpU?si=whohbunAsXkH3j6f', 'وقف باتساع اكتافك تقريبًا، ادفع ركبك للامام وانزل، انزل لأقصى حد تقدر عليه بدون ما يتقوس ظهرك السفلي.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('48f5b108-222a-4c55-8373-f5dbd3031a8e', 'Front Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'بار', 'متوسط', 'نادي', NULL, 'ثبت البار على الأكتاف، ادفع ركبك للامام وانزل.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1ad00ff8-26d5-4f93-a4c2-54f59888e094', 'V Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://www.youtube.com/watch?v=u_GSjH58s0g', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Machine Squat / سكوات بالجهاز', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8bf92264-e772-4eec-a8bd-f19681d5c186', 'Resistance Band Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/6rE0IYlMPZA?si=goqtRTlR_W4HSGBN', 'ثبت الباند علي جوانب اكتافك، ادفع ركبك للأمام وإنزل.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('41fd7bed-f2ba-4d88-9227-6c7352e80712', 'Squat Smith Machine', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/oBwhrRcNWyM', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Machine Squat / سكوات بالجهاز', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c4e2a4b3-0120-40db-a46c-265b8d7ba153', 'Single Leg Press', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/ZYDTJaAM-gE', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Single-leg Press / ضغط رجل واحدة', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c8831e03-cd96-43a6-8b25-21b7dd81d739', 'Drop Lunges', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/WH8lteLrMIs?si=61QSVA7iw_Z6Zr3p', 'تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('93170d0d-644c-4271-8e53-0f7dac031204', 'Beginner Lunges', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/QOVaHwm-Q6U', 'تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3a680616-62d9-4b50-a939-3ab71a8f42db', 'Standing Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/fyF6FQOUGDI', 'الحركة كلها بثني ومد الركبة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1a98a32d-2426-4091-a9be-52d4d9c0f657', 'Supported BSS', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/poBie3TTeGE?si=QSiMUYtcHhrmg8mx', 'وقف عند البنش او الستيب، ارفع رجلك وثبت اصابع قدمك على البنش، خذ خطوة وحدة للأمام برجلك الثانية ثم ابدأ التمرين، تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Split Squat / سبليت سكوات', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8830e934-dfef-4117-9e03-34b8a022225f', 'Supported Reverse Lunge', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/WH8lteLrMIs?si=M9s9a7qOVvvyDm82', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b1d52207-176b-404d-b61c-33eae413f752', 'Smith Machine Reverse Lunge', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/zAVYcwnlxrQ?si=M5HL4sG-bsYBFyDQ', 'استخدم ارتفاع بسيط مثل الستيب ، ارفع نفسك بالضغط علي الرجل المرفوعة بتحكم بدون قفز.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('124387d3-fd8f-4a59-b525-2663817aa123', 'Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/gtZ4AwZVtMI', 'اجلس وثبت ظهرك السفلي كويس، تأكد ان مسمار الارتفاع يكون بمستوى ركبتك، امسك المقابض لزيادة الثبات، إرفع الوزن اثبت ثانية فوق ثم انزل نزول كامل بتحكم.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9b1576f8-d0e4-49ae-b8e2-11fd41a95774', 'Single Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/82IuSLk5zNc?si=FTMqZrmawQFRr8dN', 'اجلس وثبت ظهرك السفلي كويس، تأكد ان مسمار الارتفاع يكون بمستوى ركبتك، امسك المقابض لزيادة الثبات، إرفع الوزن اثبت ثانية فوق ثم انزل نزول كامل بتحكم.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ac0625fa-e18d-4037-8086-e33ba8d10a01', 'Band Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/hs7D3gDw3UM', 'اجلس وثبت ظهرك السفلي كويس وامسك الكرسي للثبات، اثبت ثانية فوق ثم انزل نزول كامل بتحكم.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('add5d5cd-22ac-485f-a148-7c516a16ade4', 'Sissy Squat', 'Quadriceps / الأمامية', '{"Adductors / الأفخاذ الداخلية"}', 'Knee Extension / مد الركبة', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://youtu.be/yONKTprKCDA', 'الورك ثابت طول الجولة والحركة كلها من مفصل الركبة، اذا توازنك يخرب عليك ادبل الوزن بيد واليد الثانية امسك فيها جدار او عصى', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Sissy Squat / سيسي سكوات', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e2ae615b-54e3-4ff4-a77c-4b805a7f2537', 'Cable Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/ebjD98gZd8E', 'اجلس وثبت ظهرك السفلي كويس وامسك الكرسي للثبات، اثبت ثانية فوق ثم انزل نزول كامل بتحكم.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('43647e23-83b9-45e1-8673-ab97a3c01a3a', 'Standing Leg Extension', 'Quadriceps / الأمامية', '{"Core / البطن والكور"}', 'Knee Extension / مد الركبة', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/133/standing-leg-extension/', NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('37930fbf-c4eb-45fe-881d-ebd4ea68b29a', 'Bodyweight Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Lower back / أسفل الظهر"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/135/bodyweight-squat/', NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0aba350c-7e97-414a-9cd6-45552fc38a6c', 'Cable Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/mBJXWg8ZOy0', 'اجلس على الكرسي وثبت ظهرك السفلي على المقعد تمامًا، ممكن تقدّم ظهرك العلوي وتمسك المقابض لزيادة الثبات، انزل لأقصى حد تقدر عليه وارفع لحد ما تستقيم ركبتك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('85f81501-6cdd-4776-872a-26394c9bc231', 'DB Glutes Step Ups', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/GCnJiYJfboA?feature=share', 'استخدم ارتفاع يكون بحدود ارتفاع ركبتك أو أقل، ارفع نفسك بالضغط علي الرجل المرفوعة بتحكم بدون قفز.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('30c4befe-49fb-4b0c-83e6-3697c7e4a031', 'Supported Glutes Step Ups', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/ZKzoOkQALaY?si=-56txwBlxSSCQYJd', 'استخدم ارتفاع يكون بحدود ارتفاع ركبتك أو أقل، ارفع نفسك بالضغط علي الرجل المرفوعة بتحكم بدون قفز.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('518961af-80ba-4cb0-b624-5798dc2596a3', 'Cable Glutes Step Ups', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a15645df-ec1f-4688-a327-1ff2f344d006', 'Glute Pushdown', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/8h2kZ64Sp5k?si=NLPf4tywxhDGY9em', 'تمسك بمقابض الجهاز، (كل ما زاد ارتفاع البنش زادت الصعوبة) + الطلوع والنزول يكون بواسطة القدم المرفوعة على البنش مو بالقدم اللي تحت، ارفع بتحكم الى أقصى ارتفاع تقدرعليه بدون ما يتقوس ظهرك السفلي، انزل لحد ما تقفل ركبتك تماما', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f670b886-fe49-4e85-a703-3037f80e6ce1', 'Glute Max Kickbacks', 'Glutes / المؤخرة', '{}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/t5mwSx4uNMc?feature=share', 'ثبت الحبل على الكاحل، ارجع خطوة للخلف وانحني للامام قليلاً وتمسك بالكيبل لزيادة الثبات، اسحب للخلف مع انثناء بسيط بالركب.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Kickback / ركلة خلفية', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('adacc8bc-e55d-42e1-a64f-c269fe57a848', 'Smith Machine Kickback', 'Glutes / المؤخرة', '{}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/GR4ny80bmhM?si=WeZcWM1hyfoLElM2', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Kickback / ركلة خلفية', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('49fb1be3-1dfb-4652-b82a-5ba736511d36', 'Glute Medius Kickbacks', 'Abductors / مبعدات الفخذ', '{"Glutes / المؤخرة"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/kccsnZNbMFA?si=6c-VoB8Zsz8NxoyM', 'ثبت الحبل على الكاحل، ارجع خطوة للخلف وانحني للامام قليلاً وتمسك بالكيبل لزيادة الثبات، اسحب للخلف وللخارج مع انثناء بسيط بالركب.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Abduction Kickback / ركلة خلفية مع تبعيد', 'Hip Abduction + Hip Extension / تبعيد الورك + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4ef69fc9-367b-40b3-8722-0ccbeb1b8273', 'Hip Thrusts Machine', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/0xfdeCBwoYw?si=HgJcNeB0a24gODkK', 'ممكن تسويه بالسميث مشين او البار الحر ، اختر بوكس او بنش يكون بمستوى اكتافك الخلفية وانت جالس، لما ترفع البار فوق المفروض ركبك تكون بنفس مستوى القدم.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('93d9d2a4-3f2a-4c6a-8efb-4ae19b823292', 'Hip Thrusts', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/O0EoaP7gR1A?si=cGPZ8iIwM2mQjwSb', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b7f961c4-3d7e-4428-8217-83ba628eec45', 'Glute Raise', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/X_kL_x4m77c', 'ثبت رجولك تحت، الاسفنجة تكون تحت الورك أعلى الفخذ مو على الورك مباشرة، امسك وزن بيدينك بذراع مستقيمة، ارفع وكأنك تبي تدخل القلوتس جوا الاسفنجة، بمجرد ما تنقبض مؤخرتك وقف لا ترفع أكثر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', '45° Hip Extension / بسط الورك على جهاز الظهر', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2d42cccd-e0be-473e-91b2-572e5eb92b3b', 'Single Hip Thrusts', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/ymg2AMDAwrY?si=fY8kBPTDYWRMHuAs', 'اختر بوكس او بنش يكون بمستوى اكتافك الخلفية وانت جالس، لما ترفع فوق المفروض ركبك تكون بنفس مستوى القدم، التمرين صعب طبيعي تواجه صعوبة بالبداية لذلك لا تستعجل باضافة الاوزان', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3243345d-cfeb-44fd-81ac-b3bcdf55b746', 'Glute Press', 'Glutes / المؤخرة', '{}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/293/glute-press/', NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Kickback / ركلة خلفية', 'Hip Extension + Knee Extension / بسط الورك + مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b7257de2-961e-4195-900c-2ac8a236423e', 'Bulgarian Split Squat', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/366/bulgarian-split-squat/', NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Split Squat / سبليت سكوات', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('aee91b71-7355-473e-88ae-4458e16ed5e3', 'Sumo Deadlift', 'Hamstrings / الخلفية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://www.youtube.com/watch?v=cDlOSfu-zHY', 'وقف بفتحة أرجل واسعة بحيث الركب تكون خط مستقيم مع كعب القدم و اصابع الرجل باتجاه الخارج، البار بمنتصف القدم، شد ظهرك العلوي وادفع الارض برجولك واسحب البار للأعلى، وقف لما تنقبض مؤخرتك ولا تبالغ بتقفيل حوضك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Deadlift / ديدلفت', 'Hip Extension + Knee Extension / بسط الورك + مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8f65a6d8-f015-49f1-acef-a07b5753f6e3', 'Conventional Deadlift', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/GxsLrTzyGUU', 'وقف باتساع اكتافك أو أوسع شوي، البار بمنتصف القدم، شد ظهرك العلوي وادفع الارض برجولك واسحب البار للأعلى، وقف لما تنقبض مؤخرتك ولا تبالغ بتقفيل حوضك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Deadlift / ديدلفت', 'Hip Extension + Knee Extension / بسط الورك + مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('eb0207f9-4c58-4c5a-9005-97ed4d120cd3', 'Supine Cable Hamstring Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/sDCc1F5J8XA?si=Fi3D39aJogrB5ihd', 'الركبة ثبت مكانها، اسحب الحبل لاقصى حد تقدر عليه واترك رجلك تستقيم تمامًا في الانبساط.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c73367e0-c62e-4f7e-808c-a77e22726b09', 'BB RDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/mZxxJEncsyw', 'وقف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، انزل وادفع مؤخرتك لآخر شي تقدر عليه للخلف وكأنك بتلمس جدار خلفك مع انثناء بسيط بالركب', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2f123cfc-77e0-44e7-9b57-11864b6ee4ea', 'DB RDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/RApyTtH6qAo', 'وقف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، انزل وادفع مؤخرتك لآخر شي تقدر عليه للخلف وكأنك بتلمس جدار خلفك مع انثناء بسيط بالركب', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('02741241-cf82-4bfb-bae6-301383ff30d3', 'SM SLDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/qlL1wnpLQj4?si=-jD_X6mIJkkI8SwX', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cebfe975-8508-40b8-b1ae-3e2ce22b563b', 'SLDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/RApyTtH6qAo', 'قف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، ابدأ الحركة بدفع مؤخرتك للخلف والأعلى وانزل', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('beb3d44f-c7d9-4cac-ac34-1ec0d95e3ba9', 'Single DB SLDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/U3prDlAbJDw?si=MRSBcSIcf9M-WQBH', 'قف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، ابدأ الحركة بدفع مؤخرتك للخلف والأعلى وانزل', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9607248f-fa44-43ab-8ed1-7a214aacaf3c', 'Good Morning', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/f23vXjoG2e8?si=9rkfUF_6XUEcQ3Xs', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع مؤخرتك لأقصى قدر تقدر عليه وكأنك بتلمس جدار خلفك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Good Morning / قود مورنينق', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d06206c0-be84-4b48-99c2-14f477a35016', 'Seated Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/o_J6MWyt5jM', 'اجلس على الكرسي وثبت ظهرك السفلي على المقعد تمامًا، انزل لأقصى حد تقدر عليه وارفع لحد ما تستقيم ركبتك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f7014423-1706-4efb-bb4c-5a61f7b981f8', 'Band Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/I-HTMUrJnxs', 'ثبت الباند فوق الكعب، اجلس على طرف البنش وتمسك بيدينك لزيادة الثبات، اسحب الحبل لاقصى حد تقدر عليه واترك رجلك تستقيم تمامًا في الانبساط.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e14e7c61-dc24-40c5-afec-8f52b9e91b0f', 'Lying Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/vl5nUdE9mWM', 'حوضك ثابت على البنش، ارفع الوزن بثني ومد الركبة بدون ما يرتفع حوضك عن الكرسي', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7ed385bd-a2a4-451c-b6a4-b71a0a9050a4', 'DB Lying Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/ZHlBSI6JPsA?si=SpBiHxluwrYE8CTP', 'ركبك ثابته على الارض، ارفع الوزن بثني ومد الركبة بدون ما يرتفع حوضك', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('45de0da2-4083-4bde-8814-f2d02a7e1e65', 'Nordic Hamstring Curl', 'Hamstrings / الخلفية', '{}', 'Knee Flexion / ثني الركبة', 'قوة', 'وزن الجسم', 'متقدم', 'بدون معدات', 'https://youtu.be/Lgibr8od0yA?si=nfRetEkDRk55Bu0a', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Nordic (Eccentric) / نوردك (لامركزي)', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('431686d6-af1e-4b97-b604-2ed68e630995', 'Stability Ball Hamstring Curl', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة"}', 'Knee Flexion / ثني الركبة', 'قوة', 'كرة سويسرية', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/59/stability-ball-hamstring-curl/', NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Bridge Curl / ثني الركبة مع رفع الورك', 'Knee Flexion + Hip Extension / ثني الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7e1e9b80-99ae-4206-9622-0f4525b8b8c6', 'Hip Hinge', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/33/hip-hinge/', NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Hinge Drill / تمرين مفصلة الورك', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9f9560d9-fa8b-4c6e-a071-8cde1387f829', 'TRX Hamstrings Curl', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة"}', 'Knee Flexion / ثني الركبة', 'قوة', 'TRX', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/86/trx-reg-hamstrings-curl/', NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Bridge Curl / ثني الركبة مع رفع الورك', 'Knee Flexion + Hip Extension / ثني الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6dd1f67d-6ca0-4df3-8e90-e4b369c4a30f', 'Flat DB Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/xphvjGDZeYE', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('75a4472d-e324-4dc9-938b-3904e534880f', 'DB Floor Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/UBmpZ7l5Nlk?si=kDcN-ueaTFxfKtbr', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7a76606d-0eed-4756-b9a9-18511efcbf79', 'Flat Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/vcBig73ojpE', 'استلق على بنش،القبضة بنفس مستوى الاكتاف أو أوسع قليلًا، قوّس ظهرك العلوي قليلاً، انزل لين تلمس صدرك واثبت ثانية ثم ارفع.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('89a508bf-c5a6-449f-b0a1-eff7ecb08a79', 'Machine Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/pOCRC2kpxB8?si=02xGtrfPjiYpspMv', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b8bdcb41-ac08-4fad-a8fc-c68a95ba5bb7', 'Feet Up Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/HrehfM1dmBE', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('42fffcdd-d07b-4bb9-8056-2f7d26c64ca7', 'Torso Elevated Push Up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/noaPB7u4_CU', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا', 'تصنيف فرعي: اليدان مرفوعتان؛ زاوية الضغط بالنسبة للجذع تشبه الضغط المائل لأسفل رغم تسميته الشائعة Incline Push-up — يحدده المدرب', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Decline Press / ضغط مائل لأسفل', 'Horizontal Adduction + Shoulder Extension / تقريب أفقي + مد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fe1d328a-d8cf-416b-abd7-297f187f8b2f', 'Push Up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://youtu.be/WDIpL0pjun0?si=utydS_A8QfRIJtJm', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('89a85cc5-4f5a-4b6f-9457-c957726a9df5', 'Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://www.youtube.com/watch?v=JvOJdUtx6UQ', 'استلق على بنش،القبضة بنفس مستوى الاكتاف أو أوسع قليلًا، قوّس ظهرك العلوي قليلاً، انزل لين تلمس صدرك واثبت ثانية ثم ارفع.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d944b67a-9a36-42d0-b055-e3b8f452e4f0', 'Paused Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://www.youtube.com/shorts/Q3GmnmJISwE', 'استلق على بنش،القبضة بنفس مستوى الاكتاف أو أوسع قليلًا، قوّس ظهرك العلوي قليلاً، انزل لين تلمس صدرك واثبت 3 ثواني ثم ارفع.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fe1c8a53-e0c9-42e7-b4ba-026a053fc196', 'Incline Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/0G2_XV7slIg', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Incline Press / ضغط مائل لأعلى', 'Shoulder Flexion + Horizontal Adduction / ثني الكتف + تقريب أفقي', 'Incline Press / ضغط مائل لأعلى', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('335809e0-3e1b-4a5a-ae5c-fa04f86e458d', 'Smith Machine Incline Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/EeLLZMdg6zI?si=UVsgFN7jhXMm0vW3', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Incline Press / ضغط مائل لأعلى', 'Shoulder Flexion + Horizontal Adduction / ثني الكتف + تقريب أفقي', 'Incline Press / ضغط مائل لأعلى', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5dfd9bad-bdbe-4cc6-b893-6771d5e56129', 'Cable Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/tAILewhtCb0', 'اجلس على بنش انكلاين، اضبط الكيبل بمستوى صدرك تقريبا، ادفع الوزن للأمام باتجاه الداخل، احرص ان كوعك ما يكون بنفس ارتفاع كتفك', 'تصنيف فرعي: التعليمات تذكر بنش انكلاين، وتصنيف المصدر iso_push_chest — يُحسم بين Incline Press وعزل الصدر', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Incline Press / ضغط مائل لأعلى', 'Shoulder Flexion + Horizontal Adduction / ثني الكتف + تقريب أفقي', 'Incline Press / ضغط مائل لأعلى', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5d79968f-ef2b-4d61-b3d7-944860d7c858', 'Sternal Cable Press Around', 'Chest / الصدر', '{}', 'Horizontal Push / دفع أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/y8XQibXDnNo', 'اضبط الكيبل بمستوى صدرك تقريبا، حافظ على ذراعك قريبة من جسمك،ادفع الحبل للأمام باتجاه الداخل.', 'تصنيف فرعي: حركة مختلطة بين الضغط والـ Fly — يُحسم بين Flat Press وعزل الصدر', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Press-around / ضغط مع تقريب', 'Horizontal Adduction + Elbow Extension / تقريب أفقي + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('38b62114-dd99-4e14-a068-d647871dd417', 'Machine Chest Fly', 'Chest / الصدر', '{}', 'Horizontal Adduction (Fly) / تقريب أفقي للكتف (فلاي)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Chest Isolation / عزل الصدر', 'Horizontal Adduction / تقريب أفقي للكتف', 'Chest Isolation / عزل الصدر', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9248589a-cf88-487c-9264-e76b1f8a405f', 'Bar Cable Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/NhD3h6RG2TA?si=SoyNTIGB-nY2KiXl', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cf6ab98b-506a-404c-bcdf-6e8ed48061f5', 'Cable Chest Fly', 'Chest / الصدر', '{"Shoulders / الأكتاف"}', 'Horizontal Adduction (Fly) / تقريب أفقي للكتف (فلاي)', 'قوة', 'كيبل', 'مبتدئ', 'نادي', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/160/standing-chest-fly/', NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Chest Isolation / عزل الصدر', 'Horizontal Adduction / تقريب أفقي للكتف', 'Chest Isolation / عزل الصدر', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4b3b4f6e-8d42-4102-9fdf-fdecec039043', 'Bent Knee Push-up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/13/bent-knee-push-up/', NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f492c068-6f8d-4255-9f41-34c972d8d118', 'Stability Ball Push-Up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس","Core / البطن والكور"}', 'Horizontal Push / دفع أفقي', 'قوة', 'كرة سويسرية', 'متوسط', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف فرعي: الزاوية تعتمد على موضع الكرة (تحت اليدين أو القدمين) — غير محدد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/63/stability-ball-push-up/', NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('71599ffa-aa11-4612-9a5d-5365e475ce55', 'Cable Reardelt Rows', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/uIdXVGjcfFE', 'ثبت نفسك بالكرسي، فتحة واسعة، الكيبل بمستوى اسفل صدرك، واسحب لما تنقبض اكتافك الخلفية.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Wide-grip Row / تجديف بقبضة واسعة', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fb5ba96d-f5fd-47cb-adac-ba93e4909681', 'Single Lats Pulldown', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/Qed5O9toqT8', 'اجلس على بنش واسند صدرك عليه، ارجع للخلف قليلا بحيث ان الكيبل ما يكون فوق راسك مباشرة، اسحب الكوع باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('49b1eb5c-277a-4a56-a00b-2d58d1767ebd', 'DB Chest Supported Reardelt Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/x0v6GWYzI18?si=-jDt3D-ARIHouHjp', 'ثبت صدرك على الكرسي، فتحة واسعة، واسحب لما تنقبض اكتافك الخلفية.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Wide-grip Row / تجديف بقبضة واسعة', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('180a3154-5305-431e-9383-0130c9892e02', 'Bent-over Barbell Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'بار', 'متوسط', 'نادي', NULL, 'ادفع مؤخرتك للخلف واثني ركبك، قبضتك بنفس مستوى اكتافك، اسحب لما تنقبض عضلات الظهر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('67320027-4a8f-413a-ab9c-bbe449651dbc', 'Cable Reardelt Fly', 'Shoulders / الأكتاف', '{"Rotator cuffs / الكفة المدورة"}', 'Shoulder Rear Pull / سحب خلفي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/bkejPHrPkmA?si=-O8q_5e72udoPRiY', NULL, 'تصنيف فرعي: حركة Fly (تبعيد أفقي للكتف) وليست سحباً أفقياً أو عمودياً', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Rear Delt Fly / فتح خلفي', 'Horizontal Abduction / تبعيد أفقي للكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('bc56a01f-32e8-4301-8efe-9602b1f93588', 'DB Chest Supported Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/H75im9fAUMc', 'ثبت صدرك على الكرسي، فتحة واسعة، واسحب الدمبل باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('483ebe12-2e2a-41aa-9728-3544429a3284', 'Head Supported Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/c6lkPMhuyFA?si=eUivRGYSi0W7PmVe', 'راسك ثابت على البنش بدون أي ميلان بالرقبة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('eb28aaec-1882-4abd-b48c-eab5b44c6b20', 'Single Arm Dumbbell Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/QBjaGx8mS1o', 'اسحب باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f2f7e659-6dcd-4108-87f6-319ef97179a2', 'Single Arm Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/Qn_mHGObb8E?si=IZ0q9_tseiRIMtcs', 'اسحب باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('42c6fc2c-f841-4f7a-b793-e834e42eced0', 'Chest Supported Machine Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/BZrdEAiR2Xs?si=WhKaSGhR0gKeeies', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('55e15556-f52c-44a9-bbae-b8b531ebacea', 'T-Bar Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/6OtcNinT0HM?si=UPfYyypfZCaN9tTA', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('22e0dcf0-4dab-4605-8747-63f114c92c64', 'Lats Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/CQkT-W18N5g', 'الكيبل بنفس مستوى بطنك، اسحب باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Lat-focused Row / تجديف لاتس', 'Shoulder Extension / مد الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('04b1f17d-62e3-48f6-b7db-41bb71368171', 'Upperback Pulldowns', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/bNmvKpJSWKM?si=hy5HgBDAHkzFHcvv', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Wide-grip Pulldown / سحب علوي بقبضة واسعة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0b3fab2a-a212-4d5c-8a1f-8ad2e662e2d6', 'Straight Arm Pulldown', 'Back & Lats / الظهر واللاتس', '{}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/hAMcfubonDc?si=ocU_a8VQ4VzZnTg3', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Straight-arm Pull / سحب بذراع مستقيمة', 'Shoulder Extension + Scapular Depression / مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('08e0cf57-8a14-4257-8d94-5114e658e173', 'DB Pullover', 'Back & Lats / الظهر واللاتس', '{"Chest / الصدر","Triceps / الترايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/ieFKuQAGYIA?si=uwqyrbKhBL6Id3_-', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Straight-arm Pull / سحب بذراع مستقيمة', 'Shoulder Extension + Scapular Depression / مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9034a4b4-4f66-488e-a48b-e0dafd48bf86', 'Band Lat Pulldown', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/5R0RYj3Y9Ro', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8b7cdab9-c5f1-4e3c-9538-45203b3151dd', 'Band Assisted Pull Ups', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://youtu.be/Ks8ah-8P1b0', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('74ff5a37-6aec-4751-ae60-e0398c9f8125', 'Pull Ups', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متقدم', 'نادي', 'https://youtu.be/x3NPAxiMRPw?si=Mwg6U1Df5aIFpjKB', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e3684943-77ae-473f-b723-3244e487c3c4', 'Negative Pull-Up', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://youtu.be/gbPURTSxQLY?si=TvQF5zDWfU_rR1Ax', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر، نزول بطيء.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('06c2dc4e-fe90-45ae-802b-e40b2cafaed8', 'Neutral Grip Lat Pulldown', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/kVB6SlEyjQM', 'القبضة بنفس مستوى الكتف، اسحب باتجاه اعلى الصدر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5da87d7a-9a8f-462c-a644-bc8330395f64', 'Cable Y Raises', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/P7u6PEeOn6Q?feature=share', 'الكيبل يبدأ من تحت،ارفع الوزن على شكل Y.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Y Raise (Scaption) / رفع Y بمستوى لوح الكتف', 'Shoulder Elevation in Scapular Plane (Scaption) / رفع الذراع بمستوى لوح الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4279f4e9-eeb4-46a4-8034-05e50b9c6151', 'Band Assisted Chin Ups', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://youtu.be/i0yC-0YK6Uk?si=gNX26kIFz_THnR4p', 'مسكة ضيقة بمستوى الأكتاف، كل ما كان الحبل خفيف زادت المقاومة وزدات صعوبة التمرين لذلك ابدأ بحبل ثقيل وخفف كل ما تحسن مستواك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d943e419-2750-464f-9060-76995563cf9f', 'Chin Ups', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متقدم', 'نادي', 'https://youtube.com/shorts/aV9Mz9nCsMw?si=E_ullJojGO_7srW2', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b10b7f00-635c-47b9-a3e0-7ab004eb8e42', 'Kneeling Lat Pulldown', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', NULL, 'متوسط', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/35/kneeling-lat-pulldown/', NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9042e5f2-dd20-43f0-81be-9eec7a4159a9', 'TRX Back Row', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس","Core / البطن والكور","Lower back / أسفل الظهر"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'TRX', 'متوسط', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/84/trx-reg-back-row/', NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4effe73f-1589-4caf-abad-0ed6b2268138', 'Shrug', 'Back & Lats / الظهر واللاتس', '{"Trapezius / الترابيس"}', 'Scapular Elevation / رفع لوح الكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف فرعي: رفع الأكتاف (Shrug) ليس نمط سحب أفقي أو عمودي', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/72/shrug/', NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Shrug / هز الكتفين', 'Scapular Elevation / رفع لوح الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('af18468b-95f5-4c70-9a3d-cc537e2e1922', 'DB Shoulder Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/NKeyUrDYqPk', 'قوّس ظهرك العلوي قليلاً، الكوع قريب من الجسم، النزول الى مستوى الاكتاف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('31c93718-5124-4722-abdf-6b6600c68d36', 'DB Standing Shoulder Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/wO0l5jW2NtQ?si=MVvS4F_7iFS8ji9R', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cd4c786e-11e4-4a20-a8f9-74f87c01c965', 'Machine Shoulder Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/3R14MnZbcpw', 'قوّس ظهرك العلوي قليلاً، الكوع قريب من الجسم، النزول الى مستوى الاكتاف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f09aaea7-470e-4bf9-82af-38c472620dc0', 'BB Overhead Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/_RlRDWO2jfg', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('dab44a49-11b3-4f9c-81a9-a8bfedc08584', 'DB Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/qqntiuPmLDM?feature=share', 'انحني للأمام قليلًا، ارفع للأعلى الى أن تصل لمستوى الأكتاف.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f4f64aa2-10eb-4085-82d4-7625b01bfe16', 'Seated Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/v7fwGurZ9SU?feature=share', 'انحني للأمام قليلًا، ارفع للأعلى الى أن تصل لمستوى الأكتاف.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0dbbb938-944c-4a08-bbd6-913fc5d645bf', 'Lateral Raise Machine', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/d0pRsZ9SY5w?si=XuXb_Ti0Flow7qvW', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('69a41f89-3c78-4d3c-8dae-71ea8b12e4e3', 'Cable Crossover Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/wKgCc5UQjoU?si=zsaz3i31PnEU9A43', 'الكيبل يبدأ من الأسفل، انحني للأمام قليلًا، ارفع للأعلى وتحكم بالنزول.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f32d2e2c-3024-4ec8-a989-9b7020735c8f', 'DB Y Raises', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/lXp16YozXgk', 'ثبت صدرك على البنش،ارفع الوزن على شكل Y.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Y Raise (Scaption) / رفع Y بمستوى لوح الكتف', 'Shoulder Elevation in Scapular Plane (Scaption) / رفع الذراع بمستوى لوح الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('947503d5-7ee5-4e65-bda2-95da245e442f', 'Single Arm DB Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/Jm6GqVhWhNY', 'انحني للأمام قليلًا، ارفع للأعلى الى أن تصل لمستوى الأكتاف.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7ce85f68-e073-4ba1-9a55-7b9d2a21fc9d', 'Single Arm Cable Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/J-6uEOkYAKM', 'الكيبل يبدأ من الأسفل، انحني للأمام قليلًا، ارفع للأعلى وتحكم بالنزول.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('61654c86-e577-4d7d-991a-26caae263394', 'Front Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Front Raise / رفع أمامي للكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/54/front-raise/', NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Front Raise / رفع أمامي', 'Shoulder Flexion / ثني الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('208d32d9-3496-45de-8d2b-fa91f2764671', 'Diagonal Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/371/diagonal-raise/', NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Diagonal Raise / رفع قطري', 'Shoulder Flexion + Abduction (Diagonal) / ثني وتبعيد الكتف (قطري)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0454584e-ffb8-4d6a-990c-7139c980739b', 'High Row', 'Shoulders / الأكتاف', '{}', 'Shoulder Rear Pull / سحب خلفي للكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/336/high-row/', NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'High Row / Face Pull / سحب عالٍ باتجاه الوجه', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6fc8b00d-eb31-4f74-9da2-8e80ce1ccc06', 'Biceps Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/09AYfVFf7pg?si=dcwLVAYqIbDLM6jd', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('06476e58-1cda-4785-9e6f-2b8239f4c16a', 'Cable Rope Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/xNXUTJ6TBZA?si=-r-Ql97awoVZla_1', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Hammer / Neutral-grip Curl / ثني بقبضة محايدة', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('206192a0-731a-4a9d-b7e6-80b36a9c21af', 'Cable Facing Away Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/fV9BpknCjGM', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('42e1af6e-0376-46b7-b9b7-3fbfa213d530', 'DB Incline Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/js_StxxyxBM', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8fe023f2-cf9d-41e9-92e6-9ba25701b872', 'Cable Facing In Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/5z4y7QRTx1w', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4b03ea2a-dc70-42c2-86a1-3432c4582da4', 'Single Arm Cable Facing Away Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/6sO-pK7pTPs?feature=share', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('80d43dcc-1757-451e-92cc-ea0050dcfe19', 'Single Arm Cable Facing In Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/I-197ZW9Ffo?si=M1Yq4R1PIpdZMXRx', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6fdbae69-3ffb-4113-8730-299480e78762', 'DB Preacher', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/DZJNTb-zzn0?si=SwbdZ0O_0eTOET-5', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Preacher Curl / ثني على مسند', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('27b72689-3558-4d2e-b3e6-79628acbd292', 'Preacher Curl Machine', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/TouYMA3-ua4?feature=share', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Preacher Curl / ثني على مسند', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a56fda52-55e5-40b3-933b-12ce2e9753bc', 'DB Spider Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/cTMjzB2_IH8?si=qsIKEEFVfEvPXwqf', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('529924c4-5937-4bce-bfa5-7fbdc343e04c', 'Zottman Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://www.youtube.com/watch?v=ZXbOOIOPOi8', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7d7a0b3a-6c68-40d4-9b37-0c8e7ada7905', 'Hammer Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/10/hammer-curl/', NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Hammer / Neutral-grip Curl / ثني بقبضة محايدة', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b2def094-91be-474f-a709-72c2f6942185', 'TRX Biceps Curl', 'Biceps / البايسبس', '{"Forearms / الساعد","Core / البطن والكور"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'TRX', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/78/trx-reg-biceps-curl/', NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1350a6b2-f41a-4b06-9d5a-cb344d588a3a', 'DB Triceps Extensions', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/d7SXlU5HkYM?si=WuuPa9-yeByaP5sI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Overhead Extension / مد فوق الرأس', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9a6b732b-15e1-4140-9a4f-03157c64cfea', 'DB Floor Triceps Extensions', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/dpFav9Ve4rY?si=ZBdKK8VF4aPMpi3v', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Lying Extension / مد مستلقٍ', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('02f38701-35ec-46b7-90cc-f7b1691922cf', 'Cable Crossbody Extensions', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://www.youtube.com/watch?v=jtLTcED38Dg', 'الكيبل يبدأ بالمنتصف زي الفيديو، بحيث لما تسحب الكيبل يكون بنفس مستوى الترابس، الأكواع والأكتاف ثابتين مكانهم والحركة كلها بثني وفرد الكوع.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Cross-body Extension / مد عرضي', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('be793665-3290-469a-b2db-0b78f733dd25', 'Triceps Pushdown', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/QsoN4u6j8nM?feature=share', 'انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('aaa2830f-d3dc-436f-84d0-7b40b4eed07f', 'Cable Crossover Pressdowns', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/Y3CDzx-oj3k', 'الكيبل يبدأ من الأعلى،انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('921a6510-0274-47cf-8f37-d28b70da9c47', 'Band Triceps Pushdown', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/mYs1rEYtZK4?si=k8vdZxNNEB5wj2CA', 'الكيبل يبدأ من الأعلى،انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c442431d-0b47-49af-ae99-9f67a6b2dec3', 'Single Cable Triceps Pressdowns', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/8rl4ioij6lc', 'الكيبل يبدأ من الأعلى،انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1fc9ea9b-3ca4-48d2-986f-7ba96cae82f1', 'Cable Overhead Extension', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://www.youtube.com/shorts/Q3bO1Fh4734', 'اترك الحبل يسحب معصمك وكوعك ثابت لما تستطيل التراي ثم ارفع الوزن لما تستقيم اليد، كوعك ثابت طول الوقت والحركة ثني ومد من مفصل الكوع، ممكن تطبق كل يد لحالها اذا كان اسهل لك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Overhead Extension / مد فوق الرأس', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e9f19799-b1d8-4d24-b6b5-e2b49e7e771d', 'Triceps Dips', 'Triceps / الترايسبس', '{"Chest / الصدر","Shoulders / الأكتاف"}', 'Vertical Push / دفع عمودي', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/SpSE_A5L-YA?si=bSAzRM9SBuX-3mE0', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Dip / متوازي', 'Shoulder Extension + Elbow Extension / مد الكتف + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3d2d4f1d-0279-48f6-a361-3ae954de7454', 'Triceps Kickback', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/YebyKE3Ts8o?si=H_h9z5BXutFBbFhq', NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/55/triceps-kickback/', NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Triceps Kickback / ركلة الترايسبس', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ecb2f787-9325-46db-b237-34c1a3c58fa3', 'Suitcase Carry', 'Core / البطن والكور', '{"Forearms / الساعد"}', 'Loaded Carry / حمل ومشي', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/BaRMAhD7SP4?si=KkiMH8OSIEz_TB53', NULL, 'نفس التمرين ورد أيضاً تحت التصنيف «Functional Training» (صف المصدر 160) || رابط آخر في المصدر (صف 160): https://youtu.be/BaRMAhD7SP4?si=dCR2n2VSPaHhxfL3', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Suitcase Carry / حمل جانبي', 'Isometric Trunk + Grip Under Load / تثبيت الجذع والقبضة أثناء المشي', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('53d08c4a-f5ca-4121-b788-ecb71f74ed6f', 'Cable Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/ToJeyhydUxU?si=Z5dv34foxX4VtRH6', 'الحركة عبارة عن ثني للعمود الفقري وكأنك تقرب صدرك لوركك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Crunch / كرنش', 'Trunk Flexion / ثني الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d493bef7-8391-4d91-be09-570fead186e0', 'Leg Raises', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/UqmbxvOgnX4?si=U3pDG4Jf0x1mtC_7', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Reverse Crunch / Leg Raise / كرنش عكسي ورفع الأرجل', 'Hip Flexion + Posterior Pelvic Tilt / ثني الورك + إمالة الحوض للخلف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1404d67b-df55-4511-8c42-a8e3c4a1696e', 'Bosu Ball Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'أخرى', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/KjvDgHPxXcg?si=zad59CHC6Y-calzi', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Crunch / كرنش', 'Trunk Flexion / ثني الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9dec7374-6d48-49bd-b9f0-523525cff255', 'Bent Knee V-Up', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/sbyFIM30_G8?si=dED0NQSRS44dz5G9', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'V-up / في أب', 'Trunk Flexion + Hip Flexion / ثني الجذع + ثني الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('bcf616c3-7119-4bc3-9cef-890b2e0d691a', 'Reverse Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/esYVzdEfs04?si=N44MZZHlVeSQc1S3', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Reverse Crunch / Leg Raise / كرنش عكسي ورفع الأرجل', 'Hip Flexion + Posterior Pelvic Tilt / ثني الورك + إمالة الحوض للخلف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4d24ff77-51bb-42b6-aec3-39c7f6efb7d4', 'Belly Breathing', 'Core / البطن والكور', '{}', 'Core Activation & Breathing / تفعيل الجذع والتنفس', 'إحماء/تفعيل', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/Shk8cmgv0Ew?si=mXkcj9PH6eH_tLcd', 'نفس عميق من الانف ننفخ فيه البطن ثم نطلعه من الفم ببطئ مع ضغط البطن للداخل اثناء اخراج النفس', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Diaphragmatic Breathing / تنفس حجابي', 'Diaphragmatic Breathing + Abdominal Bracing / تنفس حجابي + شد البطن', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('99b9832a-2cde-434f-85a9-5d8c81861977', 'Reverse Tabletop Bridge', 'Core / البطن والكور', '{"Glutes / المؤخرة"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://youtu.be/d1yE9cGtPWo?si=2aoNqmUAN054rP75', 'اخذ نفس اثناء الطلوع، اثبت ثواني فوق واشد عضلات بطني، اطلع النفس اثناء النزول', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6a3d9b57-84cc-4e13-b860-0f5809cbf159', 'Pelvic Tilting', 'Core / البطن والكور', '{}', 'Core Activation & Breathing / تفعيل الجذع والتنفس', 'إحماء/تفعيل', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/DqqUIfMuDX4?si=uzl0SRl_M9guUT3j', 'الحركة من الحوض، اخذ نفس وادف حوضي للاعلى قليلا، اطلع النفس اثناء نزول الحوض والصق اسفل ظهري بالارض', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Pelvic Tilt / إمالة الحوض', 'Posterior Pelvic Tilt / إمالة الحوض للخلف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('dc44ca8e-2998-4483-906c-83b89d53ff32', 'Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/52/crunch/', NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Crunch / كرنش', 'Trunk Flexion / ثني الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('35444f65-9a5f-480c-aa22-d4ef4389404c', 'Standing Wood Chop', 'Core / البطن والكور', '{}', 'Trunk Rotation / دوران الجذع', 'كور', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/108/standing-wood-chop/', NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Rotation / Chop / دوران وتقطيع', 'Trunk Rotation / دوران الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c00a65d0-3339-468b-a45f-6090007fbcf0', 'Russian Twist', 'Core / البطن والكور', '{"Lower back / أسفل الظهر"}', 'Trunk Rotation / دوران الجذع', 'كور', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/65/russian-twist/', NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Rotation / Chop / دوران وتقطيع', 'Trunk Rotation / دوران الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('865c97df-5262-4f88-bb3f-fd32dcbd2664', 'Cable Twisted', 'Core / البطن والكور', '{"Lower back / أسفل الظهر"}', 'Trunk Rotation / دوران الجذع', 'كور', 'كيبل', 'مبتدئ', 'نادي', NULL, NULL, NULL, 'إضافة المدربة', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Rotation / Chop / دوران وتقطيع', 'Trunk Rotation / دوران الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3ce5af9f-ffae-42ce-91fa-e6fb6320ccd3', 'Calves On Leg Press', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/XdtWVYFVhGU', 'ثبت أصابعك أو مقدمة رجلك على الجهاز، لا تبالغ بالوزن، انزل بكعبك لين تمتد بطاتك بشكل كامل ثم ادفع.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c493249d-83de-49fb-a5c4-4e73b8674b3a', 'Calves Raise', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/H6WptvjXkgw', 'حط تحت اقدامك بليتس أو أي شي يرفعك عن الأرض، انزل من اصابعك اقصى نزول ثم ادفع للأعلى', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4aae3aa4-4383-4671-ac01-1fa47cf86b81', 'Calf Raise (Machine)', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', 'جهاز', 'مبتدئ', 'نادي', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/294/calf-raise/', NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0c308bce-10b0-4949-a1e0-185e78990783', 'Calf Raises (Barbell)', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', 'بار', 'مبتدئ', 'نادي', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/51/calf-raises/', NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1639e800-2ef1-4535-b3f6-534e2915255c', 'Adductor Slides', 'Adductors / الأفخاذ الداخلية', '{}', 'Hip Adduction / تقريب الورك', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/6U7dfuxaX9g?si=lkH35E7tZxGBePBj', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor strength»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Adductor Slide / انزلاق للتقريب', 'Hip Adduction / تقريب الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e9292d77-d3df-49e3-b7fa-f3ce36ef2a76', 'Adductor Machine', 'Adductors / الأفخاذ الداخلية', '{}', 'Hip Adduction / تقريب الورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/SU1LQhq3o2g?si=_55FKBOlcn8Ilw4X', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Adductor Machine / جهاز التقريب', 'Hip Adduction / تقريب الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4ce709fa-4b1d-44ee-8737-e882eb933f66', 'Seated Abductor Machine', 'Abductors / مبعدات الفخذ', '{}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/riEMreTHNbM?si=wE3vfJBYQY7j_oJ2', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor strength»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f0d23ca2-c923-4c7a-b026-db8c564c4e55', 'Hip Abductor Plank', 'Abductors / مبعدات الفخذ', '{"Core / البطن والكور"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/2lB5RL91yWo?si=WRm9rUORpFK6dXPl', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor strength»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7cfbfbb0-8792-4b79-8428-4c41f9261b3b', 'Dirty Dog', 'Abductors / مبعدات الفخذ', '{"Core / البطن والكور"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/109/dirty-dog/', NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7dfc499e-22dc-4b48-a4f7-dd7691f785c8', 'Rotator Cuff', 'Rotator cuffs / الكفة المدورة', '{}', 'Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/mO8YJAxVG2M?si=KL_llR6Z47Yt89uk', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «Functional Training»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'External Rotation / دوران خارجي', 'Shoulder External Rotation / دوران خارجي للكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('090ac8e1-7f43-433b-85cf-1553273c7b33', 'Supine Hamstrings Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'استلقِ على ظهرك وارفع رجلاً واحدة ومدّها ببطء مع سحب أصابع القدم نحوك، دون أي حركة في الحوض أو أسفل الظهر. اثبت 15–30 ثانية، 2–4 مرات لكل رجل.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/235/supine-hamstrings-stretch/', NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Hamstring Stretch / إطالة الخلفية', 'Hip Flexion with Knee Extended / ثني الورك مع مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5e65b655-4510-497f-a037-cc3976673828', 'Stability Ball Reverse Extensions', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة"}', 'Spinal Extension / بسط الجذع', 'كور', 'كرة سويسرية', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/64/stability-ball-reverse-extensions/', NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Reverse Extension / بسط عكسي', 'Hip Extension + Spinal Extension / بسط الورك + بسط العمود الفقري', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4413cd55-661c-4fab-9888-919da693d615', 'Contralateral Limb Raises', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة","Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Spinal Extension / بسط الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/53/contralateral-limb-raises/', NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Prone Extension / بسط على البطن', 'Spinal Extension / بسط العمود الفقري', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('419d5232-7e23-4773-a749-5284c4a88901', 'Inner Thigh Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/uqCfJYKojLU?si=Gev0VeOwVp5z6gB2', 'الضغط والدفع يكون من جهة الفخذ ، لا تدفع من ركبتك!', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «stretch»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Adductor Stretch / إطالة المقربات', 'Hip Abduction (Adductor Stretch) / تبعيد الورك (إطالة المقربات)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fe1a32fe-f8cd-4a2b-82fd-a2c72b36ed8d', 'Hips Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/uqCfJYKojLU?si=Gev0VeOwVp5z6gB2', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «stretch»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Hip Stretch / إطالة الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9c136fd0-3aaa-45f0-9eb2-60a14148b4c2', 'Kneeling Hip-flexor Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'من وضع الركوع: الركبة الخلفية تحت الورك والقدم الأمامية أمامك والركبة فوق الكاحل. شد البطن وادفع الحوض للأمام دون تقويس أسفل الظهر، واعصر مؤخرة الجهة الخلفية لزيادة الإطالة. اثبت 30–45 ثانية، 2–5 مرات.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/142/kneeling-hip-flexor-stretch/', NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Hip Flexor Stretch / إطالة ثانيات الورك', 'Hip Extension (End Range) / بسط الورك في نهاية المدى', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8d128e29-a4d9-4da2-8382-116a7e0bdf98', 'Side Lying Quadriceps Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'استلقِ على جنبك وشد البطن، واسحب كعب الرجل العلوية نحو المؤخرة بيدك مع إبقاء الركبة في خط الورك. اثبت 30–45 ثانية، 2–5 مرات لكل جهة.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/149/side-lying-quadriceps-stretch/', NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Quadriceps Stretch / إطالة الأمامية', 'Knee Flexion + Hip Extension (End Range) / ثني الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cbbc9a32-3f5d-4a8c-bb44-19ded56858f5', 'Standing Lunge Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/137/standing-lunge-stretch/', NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Hip Flexor Stretch / إطالة ثانيات الورك', 'Hip Extension (End Range) / بسط الورك في نهاية المدى', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('be96520a-ca90-4c73-b537-e65765916ced', 'Lateral Bound', 'Plyometrics / التمارين الانفجارية', '{"Glutes / المؤخرة","Quadriceps / الأمامية","Abductors / مبعدات الفخذ"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://www.youtube.com/watch?v=soqQy4dzEts', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «Functional Training»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Lateral Jump / قفز جانبي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('72d2cad6-4a7c-49ca-bb89-6280ff96b828', 'Box Jumps', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Calves / البطات"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'أخرى', 'متوسط', 'نادي', NULL, NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «CrossFit»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Vertical Jump / قفز عمودي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('74c87d07-8479-40db-aef4-97bb5e1af3d0', 'Squat Jump', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متوسط', 'بدون معدات', NULL, 'قف بعرض الحوض، ادفع الورك للخلف وانزل، ثم اقفز بقوة بمدّ الكاحل والركبة والورك معاً. انزل بهدوء على منتصف القدم مع دفع الورك للخلف ودون قفل الركب. ابدأ بقفزات صغيرة حتى تتقن الهبوط.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/222/squat-jump/', NULL, 'review', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Vertical Jump / قفز عمودي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b34db5ac-ab64-4f3f-abe1-e5f6f8eb2a9b', 'Tuck Jump', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متقدم', 'بدون معدات', NULL, 'استخدم الذراعين للزخم: أرجعهما للخلف عند النزول وأرجحهما للأمام والأعلى عند القفز، واسحب الركبتين نحو الصدر في الهواء.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/180/tuck-jump/', NULL, 'review', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Vertical Jump / قفز عمودي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('75b8b7ee-52e3-4ad2-ab62-03fa77152873', 'Cycled Split-Squat Jump', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Hamstrings / الخلفية"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متقدم', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/234/cycled-split-squat-jump/', NULL, 'review', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Split Jump / قفز سبليت', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('eefb3456-d89a-47d9-bb42-0bcdcffbbd17', 'Lateral Cone Jumps', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Calves / البطات"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'أخرى', 'متوسط', 'نادي', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/120/lateral-cone-jumps/', NULL, 'review', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Lateral Jump / قفز جانبي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('77127a2b-d87b-4943-ab26-0095174430e7', 'Forward Linear Jumps', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Hamstrings / الخلفية"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متوسط', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/177/forward-linear-jumps/', NULL, 'review', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Horizontal Jump / قفز أمامي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8aa5aec3-c6ff-467f-814a-e962b565ab2e', 'Jogging', 'CrossFit / كروس فت', '{"Quadriceps / الأمامية","Hamstrings / الخلفية","Calves / البطات"}', 'Locomotion / مشي وجري ودفع', 'كارديو', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Running / جري', 'Gait: Alternating Hip/Knee Extension / نمط المشي والجري', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5e141ace-84bc-47d1-b60e-d858b269f91e', 'Wall Ball', 'CrossFit / كروس فت', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Shoulders / الأكتاف"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'أخرى', 'متوسط', 'نادي', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Squat to Throw / سكوات مع رمي', 'Knee/Hip Extension + Shoulder Flexion / مد الركبة والورك + ثني الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('aaf7f38d-96d9-41b7-90ad-da7643ad1953', 'Snatch', 'CrossFit / كروس فت', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Shoulders / الأكتاف"}', 'Olympic Lift (Triple Extension) / رفعات أولمبية (بسط ثلاثي)', 'قدرة', 'بار', 'متقدم', 'نادي', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Snatch / سناتش', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1d654c12-4acb-4c23-b23b-ba217895031c', 'Clean', 'CrossFit / كروس فت', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Quadriceps / الأمامية"}', 'Olympic Lift (Triple Extension) / رفعات أولمبية (بسط ثلاثي)', 'قدرة', 'بار', 'متقدم', 'نادي', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Clean / كلين', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1fcb79ba-a8ef-4875-8760-7e4f0211e86e', 'Turkish Get-Up', 'Functional / التمارين الوظيفية', '{"Shoulders / الأكتاف","Core / البطن والكور","Glutes / المؤخرة"}', 'Full-body Integrated / حركة متكاملة للجسم', 'قوة', 'كيتلبل', 'متقدم', 'منزل', 'https://www.youtube.com/watch?v=0bWRPC49-KI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Turkish Get-Up / النهوض التركي', 'Multi-joint Integrated / حركة متعددة المفاصل', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('80ec5980-29f0-412e-a910-3a332a687a62', 'Sled Pull/Push', 'Functional / التمارين الوظيفية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Calves / البطات"}', 'Locomotion / مشي وجري ودفع', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://www.youtube.com/watch?v=3KWK7SIdPz4', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Sled Push / Pull / دفع وسحب الزلاجة', 'Hip/Knee Extension in Gait / بسط الورك والركبة بنمط المشي', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6b3f7642-5a72-4805-b6a0-a1eb14859cee', 'Farmer’s Walk', 'Functional / التمارين الوظيفية', '{"Forearms / الساعد","Core / البطن والكور","Back & Lats / الظهر واللاتس"}', 'Loaded Carry / حمل ومشي', 'قوة', NULL, 'مبتدئ', NULL, 'https://www.youtube.com/watch?v=hx24PM6gXs8', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Farmer''s Walk / مشي المزارع', 'Isometric Trunk + Grip Under Load / تثبيت الجذع والقبضة أثناء المشي', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('bf0a5257-2c86-4e7a-b800-fc411e97f41d', '90s Transition', 'Functional / التمارين الوظيفية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://www.youtube.com/watch?v=ogU-azeGe_k', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Hip Rotation Mobility (90/90) / مرونة دوران الورك', 'Hip Internal/External Rotation / دوران الورك الداخلي والخارجي', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2f06899b-19aa-4909-99bf-32b1bd4a8e00', 'Kettlebell Swing', 'Functional / التمارين الوظيفية', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Core / البطن والكور"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قدرة', 'كيتلبل', 'متوسط', 'منزل', 'https://www.youtube.com/watch?v=d94xX-AQZ0A', NULL, 'نفس التمرين ورد أيضاً تحت التصنيف «CrossFit» (صف المصدر 168)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Ballistic Hinge (Swing) / مفصلة انفجارية (سوينق)', 'Hip Extension (Ballistic) / بسط الورك الانفجاري', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c35479c8-05a6-49c2-8fd3-e558360c6032', 'left over db', 'Functional / التمارين الوظيفية', '{}', NULL, NULL, 'دمبل', NULL, 'منزل', 'https://youtu.be/pLnRt-caepc?si=DAS9jeYr8vS6RRtz', 'طبق الحركة بأقصى عدد ممكن من التكرارات وأحسبها كجولة، ثم ابدأ بالجولة الثانية بنفس الطريقة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cb71fb4a-8f22-419e-a74f-c67059b86b47', 'Serratus Punches Supine', 'Functional / التمارين الوظيفية', '{"Shoulders / الأكتاف","Chest / الصدر"}', 'Horizontal Push / دفع أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/cxaAqmdlrgk?si=2YRAIgFFXPAvDadG', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Scapular Protraction / دفع لوح الكتف', 'Scapular Protraction / دفع لوح الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ab68496f-2afd-486f-a4e0-7757e8cf671a', 'Forward Lunges', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/_DLAdo2Pvjs', 'تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness | ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, 'تقوية الورك ضمن نمط حركي وظيفي', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Distefano et al. 2009 — JOSPT (EMG) | Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin)', 'https://pubmed.ncbi.nlm.nih.gov/19574661/ | https://pubmed.ncbi.nlm.nih.gov/33344003/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('536ff630-038e-495e-8963-8573486b70f5', 'Seated Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/0G3W83dFUeY', 'اسحب باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness | تحدب الظهر / Postural Thoracic Kyphosis', 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', 'تقوية سحب وانكماش لوح الكتف', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moseley et al. 1992 — AJSM (EMG, scapular muscles) | Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://pubmed.ncbi.nlm.nih.gov/1558238/ | https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b92b1f9e-574c-459c-b481-4dcff829c178', 'Single Leg Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'وزن الجسم', 'متقدم', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/136/single-leg-squat/', 'ضعف الألوية الكبرى / Gluteus Maximus Weakness | ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Single-leg Squat / سكوات رجل واحدة', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, 'تقوية باسطات ومبعدات الورك وتحكم أحادي الطرف', 'متقدمة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ يتطلب تحكماً جيداً بالركبة والحوض', 'Distefano et al. 2009 — JOSPT (EMG) | Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin)', 'https://pubmed.ncbi.nlm.nih.gov/19574661/ | https://pubmed.ncbi.nlm.nih.gov/33344003/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('16525b39-3bf2-42b0-9faa-94e39fe0bac8', 'Hip Abduction', 'Abductors / مبعدات الفخذ', '{"Glutes / المؤخرة"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/_ARUxqrII3Y?si=Jcz5uh2Uu-IdVCS1', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL, 'تقوية مبعدات الورك بمقاومة خارجية', 'مبكرة–متوسطة', 'منخفض–متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ الدليل يخص إبعاد الورك بمقاومة خارجية؛ يُتحقق من نوع الأداء', 'Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin)', 'https://pubmed.ncbi.nlm.nih.gov/33344003/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('34c2c093-0189-4325-ad9d-f76bf69e0c4e', 'Side Step Up', 'Glutes / المؤخرة', '{"Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/xOwIRnI4VxA?si=SJOgODRmNGdfHPb4', 'يد فيها الوزن واليد الثانية سندها على الجدار', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية المتوسطة / Gluteus Medius Weakness | ضعف الألوية الصغرى / Gluteus Minimus Weakness', 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, 'تقوية مبعدات الورك والتحكم بالحوض على رجل واحدة', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin) | Ganderton et al. — GMin/GMed EMG (RMIT University)', 'https://pubmed.ncbi.nlm.nih.gov/33344003/ | https://research-repository.rmit.edu.au/articles/journal_contribution/Gluteus_Minimus_and_Gluteus_Medius_Muscle_Activity_during_Common_Rehabilitation_Exercises_in_Healthy_Postmenopausal_Women/27572301', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('51b67b30-e671-465c-b579-0a619cf9c1fc', 'Glute Bridge', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', NULL, 'مبتدئ', NULL, 'https://www.youtube.com/watch?v=dtlGynVdHYM', 'ممكن تسويه بالسميث مشين او البار الحر ، اختر بوكس او بنش يكون بمستوى اكتافك الخلفية وانت جالس، لما ترفع البار فوق المفروض ركبك تكون بنفس مستوى القدم.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness | آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, 'تقوية بسط الورك وتحمّل الجذع', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Boren et al. 2011 — IJSPT (EMG) | JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/22034614/ | https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1bc301a3-8658-4f22-8a9a-8aeb55dd3ba4', 'DB Floor Glute Bridge', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/iOrJXNUH3to?si=JySX6JMhoP2vWEVa', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness', 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, 'تقوية بسط الورك بتحميل خارجي متدرج', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Boren et al. 2011 — IJSPT (EMG)', 'https://pubmed.ncbi.nlm.nih.gov/22034614/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1581b70c-609d-4933-9db8-ad282739697c', 'Single DB RDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/U3prDlAbJDw?si=MRSBcSIcf9M-WQBH', 'وقف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، انزل وادفع مؤخرتك لآخر شي تقدر عليه للخلف وكأنك بتلمس جدار خلفك مع انثناء بسيط بالركب', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness', 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, 'تقوية باسطات الورك وتحكم أحادي الطرف', 'متقدمة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ مع الحفاظ على وضع محايد للظهر', 'Distefano et al. 2009 — JOSPT (EMG)', 'https://pubmed.ncbi.nlm.nih.gov/19574661/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('701923a2-f904-4e13-85a5-71bf7b730c93', 'Upper Back Horizontal Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/TSWohpfMlso', 'ثبت نفسك بالكرسي، فتحة واسعة، الكيبل بمستوى أعلى صدرك، واسحب لما تنقبض الترابز.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness', 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Wide-grip Row / تجديف بقبضة واسعة', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', 'تقوية انكماش لوح الكتف والظهر العلوي', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moseley et al. 1992 — AJSM (EMG, scapular muscles)', 'https://pubmed.ncbi.nlm.nih.gov/1558238/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('22b62338-8fa6-4f40-b991-bb957cd149a7', 'Band Seated Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/Jy-WCFAofBY?si=9gqVby588rk1zFi9', 'فتحة واسعة، واسحب لما تنقبض عضلات الظهر.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness | تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture', 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', 'تقوية سحب لوح الكتف بمقاومة منخفضة', 'مبكرة–متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moseley et al. 1992 — AJSM (EMG, scapular muscles) | Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://pubmed.ncbi.nlm.nih.gov/1558238/ | https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('02afeb53-cbbd-480c-ab64-771d11425ffd', 'Chest Supported Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/DgHtyrQEMJ4?si=oTfTKVgD9j1H12wA', 'ثبت صدرك على الكرسي، فتحة واسعة، واسحب لما تنقبض عضلات الظهر.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness', 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', 'تقوية انكماش لوح الكتف مع دعم الجذع', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moseley et al. 1992 — AJSM (EMG, scapular muscles)', 'https://pubmed.ncbi.nlm.nih.gov/1558238/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('018e36db-52a4-4750-bd0c-52934c85ca3a', 'Plank', 'Core / البطن والكور', '{"Shoulders / الأكتاف","Glutes / المؤخرة"}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/pvIjsG5Svck?si=cTP8ZyfMAJPfaEhw', 'لما ترتفع الاكتاف تكون فوق الكوع والرجل ممتدة بالكامل.', NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL, 'تحمّل عضلات الجذع', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('734d3fe1-4228-4c26-8d3c-1736cf51548b', 'deadbug', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/g_BYB0R-4Ws?si=D4nwJri73eBqJRqL', NULL, 'اسم مشابه موجود في المكتبة (deadbug / dead bug) — تُراجَع قبل الحذف أو الدمج', 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'rejected', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL, 'التحكم الحركي وتحمّل الجذع', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8941368f-4e42-4fdf-a32a-ad0fe08c6c23', 'Band Dead Bug', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'مطاط', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/iW_CtYtzbeU?si=Epequw3rqA3_TwTr', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL, 'التحكم الحركي وتحمّل الجذع بمقاومة', 'مبكرة–متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8de0a8a6-7e6b-4391-8f94-8e44f7b80244', 'Side Plank', 'Core / البطن والكور', '{"Abductors / مبعدات الفخذ","Shoulders / الأكتاف"}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'لما ترتفع الاكتاف تكون فوق الكوع والرجل ممتدة بالكامل.', NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain | ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Anti-Lateral Flexion / مقاومة الميلان الجانبي', 'Isometric Anti-Lateral Flexion / تثبيت الجذع ضد الميلان', NULL, 'تحمّل الجذع الجانبي وتنشيط مبعدات الورك', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.) | Boren et al. 2011 — IJSPT (EMG)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/ | https://pubmed.ncbi.nlm.nih.gov/22034614/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b367a6e4-b294-4d37-9ef3-cf70ddad85f3', 'McGill Big 3', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/jZylx81_kfg?si=_jP064GZIzvEvzyN', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Mixed (McGill Big 3) / مختلط', 'Isometric Trunk Stabilization / تثبيت الجذع', NULL, 'التحكم الحركي وتحمّل الجذع', 'مبكرة–متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6b598360-36d2-4190-971b-c4eb8a70af30', 'Dead Bug', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/_zkkMOtXuOQ?si=GIkLuCUJvdaOk5FP', 'نحرك الرجلين ببطئ قليلا و بتحكم باستخدام عضلات البطن', 'اسم مشابه موجود في المكتبة (deadbug / dead bug) — تُراجَع قبل الحذف أو الدمج', 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL, 'التحكم الحركي وتحمّل الجذع', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('708b8d39-ec51-4edc-973e-b5af0a958931', 'Bird Dog', 'Core / البطن والكور', '{"Lower back / أسفل الظهر","Glutes / المؤخرة"}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/L91QMACdA6Q?si=KBnuQDcm9WcUXxxI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Anti-Rotation / مقاومة الدوران', 'Isometric Anti-Rotation / تثبيت الجذع ضد الدوران', NULL, 'التحكم الحركي وتحمّل الجذع', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6d297801-54b7-4c12-9847-f9e0df64522c', 'High-Load Heel Raise (Towel Under Toes)', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', NULL, 'مبتدئ', NULL, NULL, 'رفع الكعب على رجل واحدة مع منشفة ملفوفة تحت أصابع القدم؛ صعود بطيء ثم ثبات قصير ثم نزول بطيء.', 'أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Rathleff et al. 2015 — Scand J Med Sci Sports (RCT)', 'https://doi.org/10.1111/sms.12313', 'اللفافة الأخمصية / Plantar Fasciopathy', 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL, 'تحميل تدريجي للقدم والكاحل', 'متقدمة', 'مرتفع', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ يُبدأ بعد تحسّن الأعراض وبتدرّج', 'Rathleff et al. 2015 — Scand J Med Sci Sports (RCT) | JOSPT CPG 2023 — Heel Pain/Plantar Fasciitis (Koc et al.)', 'https://doi.org/10.1111/sms.12313 | https://pubmed.ncbi.nlm.nih.gov/38037331/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9ac991b6-768c-468a-b80f-27204fc3e17e', 'Side Lunge', 'Adductors / الأفخاذ الداخلية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/50/side-lunge/', 'ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Lateral Lunge / لانج جانبي', 'Knee/Hip Extension + Hip Adduction / مد الركبة والورك + تقريب الورك', NULL, 'تقوية مبعدات الورك والتحكم بالحوض', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin)', 'https://pubmed.ncbi.nlm.nih.gov/33344003/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4bb8cc1b-6ec1-477f-b2e2-93f23c4b230b', 'Hip Hitch (Pelvic Drop)', 'Abductors / مبعدات الفخذ', '{}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Ganderton et al. — GMin/GMed EMG (RMIT University)', 'https://research-repository.rmit.edu.au/articles/journal_contribution/Gluteus_Minimus_and_Gluteus_Medius_Muscle_Activity_during_Common_Rehabilitation_Exercises_in_Healthy_Postmenopausal_Women/27572301', 'ضعف الألوية المتوسطة / Gluteus Medius Weakness | ضعف الألوية الصغرى / Gluteus Minimus Weakness', 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Pelvic Drop (Stance Leg) / تثبيت الحوض برجل الارتكاز', 'Hip Abduction of Stance Leg / تبعيد ورك رجل الارتكاز', NULL, 'تنشيط وتقوية مبعدات الورك (الألوية المتوسطة والصغرى) والتحكم بالحوض', 'مبكرة–متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Ganderton et al. — GMin/GMed EMG (RMIT University) | Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin)', 'https://research-repository.rmit.edu.au/articles/journal_contribution/Gluteus_Minimus_and_Gluteus_Medius_Muscle_Activity_during_Common_Rehabilitation_Exercises_in_Healthy_Postmenopausal_Women/27572301 | https://pubmed.ncbi.nlm.nih.gov/33344003/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('48dc5e93-efd8-405d-b1b2-99048a5de684', 'Shoulder I-Y-T-W Series', 'Rotator cuffs / الكفة المدورة', '{"Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/237/shoulder-stability-mobility-series-i-y-t-w-formations/', 'تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture | ضعف العضلة المعينية / Rhomboid Weakness', 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'I-Y-T-W / تمارين I-Y-T-W', 'Scapular Retraction/Depression + Arm Elevation / سحب وخفض لوح الكتف مع رفع الذراع', NULL, 'تقوية وتحكم عضلات لوح الكتف (الانكماش والتدوير)', 'مبكرة–متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis) | Sheikhhoseini et al. 2018 — JMPT (Systematic review, FHP) | Castelein et al. 2016 — Man Ther (EMG, rhomboid)', 'https://doi.org/10.1186/s12891-024-07224-4 | https://pubmed.ncbi.nlm.nih.gov/30107937/ | https://pubmed.ncbi.nlm.nih.gov/26409441/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3a7c05b5-f745-4e6e-852d-70a79069183b', 'Supine Snow Angel (Wipers)', 'Rotator cuffs / الكفة المدورة', '{"Shoulders / الأكتاف","Core / البطن والكور"}', 'Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/124/supine-snow-angel-wipers-exercise/', 'تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture', 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Snow Angel / الملاك', 'Shoulder Abduction/Adduction + Scapular Control / تبعيد وتقريب الكتف مع تحكم لوح الكتف', NULL, 'حركة الكتف والتحكم بلوح الكتف', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('808d8306-4185-4294-b232-e78bc0975f80', 'Back Extension', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة","Hamstrings / الخلفية"}', 'Spinal Extension / بسط الجذع', 'كور', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/bs7S3RFyIYs?si=tDLl3OYuDBIwK4Fj', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «Functional Training»)', 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain | تحدب الظهر / Postural Thoracic Kyphosis', 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Back Extension / بسط الظهر', 'Hip Extension + Spinal Extension / بسط الورك + بسط العمود الفقري', NULL, 'تقوية باسطات الظهر', 'متقدمة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ يُراجَع إذا زاد الألم مع الامتداد', 'JOSPT CPG 2021 — Low Back Pain (George et al.) | Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/ | https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c951aa24-c757-42e7-895b-54dc5ca11de9', 'Supermans', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة","Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Spinal Extension / بسط الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/9/supermans/', 'تحدب الظهر / Postural Thoracic Kyphosis | آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Prone Extension / بسط على البطن', 'Spinal Extension / بسط العمود الفقري', NULL, 'تقوية باسطات الظهر والتحكم الوضعي', 'متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis) | JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://doi.org/10.1186/s12891-024-07224-4 | https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fb66cef3-3f51-4427-9c1d-cc0d39e80fc7', 'Standing Dorsi-Flexion (Calf Stretch)', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/152/standing-dorsi-flexion-calf-stretch/', 'اللفافة الأخمصية / Plantar Fasciopathy', 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Calf Stretch / إطالة البطات', 'Ankle Dorsiflexion / ثني ظهري للكاحل', NULL, 'إطالة عضلات الساق', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2023 — Heel Pain/Plantar Fasciitis (Koc et al.)', 'https://pubmed.ncbi.nlm.nih.gov/38037331/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('998eca0a-d515-4285-81e2-13da2d74e50f', 'Cat-Cow', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/15/cat-cow/', 'تحدب الظهر / Postural Thoracic Kyphosis | آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Spinal Mobility / مرونة العمود الفقري', 'Spinal Flexion/Extension / ثني وبسط العمود الفقري', NULL, 'حركة العمود الفقري ضمن مدى حركة مريح', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis) | JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://doi.org/10.1186/s12891-024-07224-4 | https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4c8430fb-6a3e-4a1f-bdaa-3767a7efde02', 'Plantar Fascia-Specific Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'تُسحب أصابع القدم للخلف باليد حتى يُشعر بشد في باطن القدم، مع تحسّس اللفافة للتأكد من الشد.', 'أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Rathleff et al. 2015 — Scand J Med Sci Sports (RCT)', 'https://doi.org/10.1111/sms.12313', 'اللفافة الأخمصية / Plantar Fasciopathy', 'review', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Plantar Fascia Stretch / إطالة اللفافة الأخمصية', 'Toe Extension + Ankle Dorsiflexion / مد أصابع القدم + ثني ظهري', NULL, 'إطالة اللفافة الأخمصية', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2023 — Heel Pain/Plantar Fasciitis (Koc et al.) | Rathleff et al. 2015 — Scand J Med Sci Sports (RCT)', 'https://pubmed.ncbi.nlm.nih.gov/38037331/ | https://doi.org/10.1111/sms.12313', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d119c214-4fad-4ba5-bbc6-9be2474de1b1', 'Crab Reach (Thoracic Bridge)', 'Functional / التمارين الوظيفية', '{"Glutes / المؤخرة","Shoulders / الأكتاف"}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://www.youtube.com/watch?v=fgsUe3Lc3hI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'تحدب الظهر / Postural Thoracic Kyphosis', 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Thoracic Bridge / جسر صدري', 'Hip Extension + Thoracic Rotation / بسط الورك + دوران الصدر', NULL, 'حركة الامتداد والدوران الصدري', 'متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ يتطلب تحمّلاً جيداً للرسغ والكتف', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('319bac56-600e-4bff-bc6f-bcd9376205e7', 'Prone Swimmer', 'Functional / التمارين الوظيفية', '{"Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Shoulder Rear Pull / سحب خلفي للكتف', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://www.youtube.com/watch?v=M8a1cgnhyqk', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture', 'approved', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Prone Swimmer / سبّاح على البطن', 'Shoulder Extension/Abduction + Rotation / مد وتبعيد الكتف مع الدوران', NULL, 'تحمّل عضلات لوح الكتف والامتداد الصدري', 'متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c1e7024d-37c1-45e6-bc37-44bf319267a8', 'Isometric Wrist Extension', 'Forearms / الساعد', '{}', 'Wrist Extension / مد الرسغ', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'مرفق التنس / Lateral Elbow Tendinopathy', 'review', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Isometric / ثابت', 'Wrist Extension / مد الرسغ', NULL, 'تحميل تدريجي لباسطات الرسغ (انقباض ثابت)', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ ضمن ألم مقبول لا يتزايد بعد التمرين', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5aa150d6-8346-4a92-957e-9d9e7fa48407', 'Eccentric Wrist Extension', 'Forearms / الساعد', '{}', 'Wrist Extension / مد الرسغ', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'مرفق التنس / Lateral Elbow Tendinopathy', 'review', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Eccentric / لامركزي', 'Wrist Extension / مد الرسغ', NULL, 'تحميل تدريجي لباسطات الرسغ (لامركزي)', 'متوسطة', 'منخفض–متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ ضمن ألم مقبول لا يتزايد بعد التمرين', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('04ba98e8-cabe-479e-a7fc-80208cb655fa', 'Chin Tuck (Deep Neck Flexor)', 'Neck / الرقبة', '{}', 'Neck Flexion (Deep Flexors) / ثني الرقبة العميق', 'إحماء/تفعيل', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Sheikhhoseini et al. 2018 — JMPT (Systematic review, FHP)', 'https://pubmed.ncbi.nlm.nih.gov/30107937/', 'وضعية الرأس للأمام / Forward Head Posture', 'review', '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', 'Chin Tuck / سحب الذقن', 'Upper Cervical Flexion + Retraction / ثني علوي للرقبة مع سحبها للخلف', NULL, 'تحكم عضلات الرقبة العميقة ووضعية الرأس', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ يُوقف مع دوخة أو ألم/تنميل يمتد للذراع', 'Sheikhhoseini et al. 2018 — JMPT (Systematic review, FHP) | Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://pubmed.ncbi.nlm.nih.gov/30107937/ | https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;



INSERT INTO public.exercise_alternatives VALUES ('a59403c0-ae92-4c15-9f4e-db96d4c4cf7f', '11aee3da-362d-4e7c-91c6-17dac7e010df', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a59403c0-ae92-4c15-9f4e-db96d4c4cf7f', '42c60881-1299-471f-83e7-62fc3088a65c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a59403c0-ae92-4c15-9f4e-db96d4c4cf7f', '48f5b108-222a-4c55-8373-f5dbd3031a8e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a59403c0-ae92-4c15-9f4e-db96d4c4cf7f', '8bf92264-e772-4eec-a8bd-f19681d5c186', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a59403c0-ae92-4c15-9f4e-db96d4c4cf7f', '37930fbf-c4eb-45fe-881d-ebd4ea68b29a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('11aee3da-362d-4e7c-91c6-17dac7e010df', 'a59403c0-ae92-4c15-9f4e-db96d4c4cf7f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('11aee3da-362d-4e7c-91c6-17dac7e010df', '42c60881-1299-471f-83e7-62fc3088a65c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('11aee3da-362d-4e7c-91c6-17dac7e010df', '48f5b108-222a-4c55-8373-f5dbd3031a8e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('11aee3da-362d-4e7c-91c6-17dac7e010df', '8bf92264-e772-4eec-a8bd-f19681d5c186', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('11aee3da-362d-4e7c-91c6-17dac7e010df', '37930fbf-c4eb-45fe-881d-ebd4ea68b29a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d54624c1-3ac8-4263-82da-440a3e4781f6', '1ad00ff8-26d5-4f93-a4c2-54f59888e094', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d54624c1-3ac8-4263-82da-440a3e4781f6', '41fd7bed-f2ba-4d88-9227-6c7352e80712', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d54624c1-3ac8-4263-82da-440a3e4781f6', 'a59403c0-ae92-4c15-9f4e-db96d4c4cf7f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d54624c1-3ac8-4263-82da-440a3e4781f6', '11aee3da-362d-4e7c-91c6-17dac7e010df', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d54624c1-3ac8-4263-82da-440a3e4781f6', '8a31e631-da2f-4e39-beb8-6a8f39553600', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8a31e631-da2f-4e39-beb8-6a8f39553600', '20993925-3ffd-4b18-970e-c37916ee4cdc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8a31e631-da2f-4e39-beb8-6a8f39553600', 'a59403c0-ae92-4c15-9f4e-db96d4c4cf7f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8a31e631-da2f-4e39-beb8-6a8f39553600', '11aee3da-362d-4e7c-91c6-17dac7e010df', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8a31e631-da2f-4e39-beb8-6a8f39553600', 'd54624c1-3ac8-4263-82da-440a3e4781f6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8a31e631-da2f-4e39-beb8-6a8f39553600', '42c60881-1299-471f-83e7-62fc3088a65c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('20993925-3ffd-4b18-970e-c37916ee4cdc', '8a31e631-da2f-4e39-beb8-6a8f39553600', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('20993925-3ffd-4b18-970e-c37916ee4cdc', 'a59403c0-ae92-4c15-9f4e-db96d4c4cf7f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('20993925-3ffd-4b18-970e-c37916ee4cdc', '11aee3da-362d-4e7c-91c6-17dac7e010df', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('20993925-3ffd-4b18-970e-c37916ee4cdc', 'd54624c1-3ac8-4263-82da-440a3e4781f6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('20993925-3ffd-4b18-970e-c37916ee4cdc', '42c60881-1299-471f-83e7-62fc3088a65c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('42c60881-1299-471f-83e7-62fc3088a65c', 'a59403c0-ae92-4c15-9f4e-db96d4c4cf7f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('42c60881-1299-471f-83e7-62fc3088a65c', '11aee3da-362d-4e7c-91c6-17dac7e010df', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('42c60881-1299-471f-83e7-62fc3088a65c', '48f5b108-222a-4c55-8373-f5dbd3031a8e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('42c60881-1299-471f-83e7-62fc3088a65c', '8bf92264-e772-4eec-a8bd-f19681d5c186', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('42c60881-1299-471f-83e7-62fc3088a65c', '37930fbf-c4eb-45fe-881d-ebd4ea68b29a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('48f5b108-222a-4c55-8373-f5dbd3031a8e', 'a59403c0-ae92-4c15-9f4e-db96d4c4cf7f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('48f5b108-222a-4c55-8373-f5dbd3031a8e', '11aee3da-362d-4e7c-91c6-17dac7e010df', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('48f5b108-222a-4c55-8373-f5dbd3031a8e', '42c60881-1299-471f-83e7-62fc3088a65c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('48f5b108-222a-4c55-8373-f5dbd3031a8e', '8bf92264-e772-4eec-a8bd-f19681d5c186', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('48f5b108-222a-4c55-8373-f5dbd3031a8e', '37930fbf-c4eb-45fe-881d-ebd4ea68b29a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ad00ff8-26d5-4f93-a4c2-54f59888e094', 'd54624c1-3ac8-4263-82da-440a3e4781f6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ad00ff8-26d5-4f93-a4c2-54f59888e094', '41fd7bed-f2ba-4d88-9227-6c7352e80712', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ad00ff8-26d5-4f93-a4c2-54f59888e094', 'a59403c0-ae92-4c15-9f4e-db96d4c4cf7f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ad00ff8-26d5-4f93-a4c2-54f59888e094', '11aee3da-362d-4e7c-91c6-17dac7e010df', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ad00ff8-26d5-4f93-a4c2-54f59888e094', '8a31e631-da2f-4e39-beb8-6a8f39553600', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8bf92264-e772-4eec-a8bd-f19681d5c186', 'a59403c0-ae92-4c15-9f4e-db96d4c4cf7f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8bf92264-e772-4eec-a8bd-f19681d5c186', '11aee3da-362d-4e7c-91c6-17dac7e010df', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8bf92264-e772-4eec-a8bd-f19681d5c186', '42c60881-1299-471f-83e7-62fc3088a65c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8bf92264-e772-4eec-a8bd-f19681d5c186', '48f5b108-222a-4c55-8373-f5dbd3031a8e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8bf92264-e772-4eec-a8bd-f19681d5c186', '37930fbf-c4eb-45fe-881d-ebd4ea68b29a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('41fd7bed-f2ba-4d88-9227-6c7352e80712', 'd54624c1-3ac8-4263-82da-440a3e4781f6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('41fd7bed-f2ba-4d88-9227-6c7352e80712', '1ad00ff8-26d5-4f93-a4c2-54f59888e094', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('41fd7bed-f2ba-4d88-9227-6c7352e80712', 'a59403c0-ae92-4c15-9f4e-db96d4c4cf7f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('41fd7bed-f2ba-4d88-9227-6c7352e80712', '11aee3da-362d-4e7c-91c6-17dac7e010df', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('41fd7bed-f2ba-4d88-9227-6c7352e80712', '8a31e631-da2f-4e39-beb8-6a8f39553600', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c4e2a4b3-0120-40db-a46c-265b8d7ba153', 'c8831e03-cd96-43a6-8b25-21b7dd81d739', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c4e2a4b3-0120-40db-a46c-265b8d7ba153', '93170d0d-644c-4271-8e53-0f7dac031204', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c4e2a4b3-0120-40db-a46c-265b8d7ba153', 'ab68496f-2afd-486f-a4e0-7757e8cf671a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c4e2a4b3-0120-40db-a46c-265b8d7ba153', '1a98a32d-2426-4091-a9be-52d4d9c0f657', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c4e2a4b3-0120-40db-a46c-265b8d7ba153', '8830e934-dfef-4117-9e03-34b8a022225f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c8831e03-cd96-43a6-8b25-21b7dd81d739', '93170d0d-644c-4271-8e53-0f7dac031204', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c8831e03-cd96-43a6-8b25-21b7dd81d739', 'ab68496f-2afd-486f-a4e0-7757e8cf671a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c8831e03-cd96-43a6-8b25-21b7dd81d739', '8830e934-dfef-4117-9e03-34b8a022225f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c8831e03-cd96-43a6-8b25-21b7dd81d739', 'b1d52207-176b-404d-b61c-33eae413f752', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c8831e03-cd96-43a6-8b25-21b7dd81d739', 'c4e2a4b3-0120-40db-a46c-265b8d7ba153', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('93170d0d-644c-4271-8e53-0f7dac031204', 'c8831e03-cd96-43a6-8b25-21b7dd81d739', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('93170d0d-644c-4271-8e53-0f7dac031204', 'ab68496f-2afd-486f-a4e0-7757e8cf671a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('93170d0d-644c-4271-8e53-0f7dac031204', '8830e934-dfef-4117-9e03-34b8a022225f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('93170d0d-644c-4271-8e53-0f7dac031204', 'b1d52207-176b-404d-b61c-33eae413f752', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('93170d0d-644c-4271-8e53-0f7dac031204', 'c4e2a4b3-0120-40db-a46c-265b8d7ba153', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab68496f-2afd-486f-a4e0-7757e8cf671a', 'c8831e03-cd96-43a6-8b25-21b7dd81d739', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab68496f-2afd-486f-a4e0-7757e8cf671a', '93170d0d-644c-4271-8e53-0f7dac031204', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab68496f-2afd-486f-a4e0-7757e8cf671a', '8830e934-dfef-4117-9e03-34b8a022225f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab68496f-2afd-486f-a4e0-7757e8cf671a', 'b1d52207-176b-404d-b61c-33eae413f752', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab68496f-2afd-486f-a4e0-7757e8cf671a', 'c4e2a4b3-0120-40db-a46c-265b8d7ba153', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1a98a32d-2426-4091-a9be-52d4d9c0f657', 'c4e2a4b3-0120-40db-a46c-265b8d7ba153', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1a98a32d-2426-4091-a9be-52d4d9c0f657', 'c8831e03-cd96-43a6-8b25-21b7dd81d739', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1a98a32d-2426-4091-a9be-52d4d9c0f657', '93170d0d-644c-4271-8e53-0f7dac031204', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1a98a32d-2426-4091-a9be-52d4d9c0f657', 'ab68496f-2afd-486f-a4e0-7757e8cf671a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1a98a32d-2426-4091-a9be-52d4d9c0f657', '8830e934-dfef-4117-9e03-34b8a022225f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8830e934-dfef-4117-9e03-34b8a022225f', 'c8831e03-cd96-43a6-8b25-21b7dd81d739', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8830e934-dfef-4117-9e03-34b8a022225f', '93170d0d-644c-4271-8e53-0f7dac031204', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8830e934-dfef-4117-9e03-34b8a022225f', 'ab68496f-2afd-486f-a4e0-7757e8cf671a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8830e934-dfef-4117-9e03-34b8a022225f', 'b1d52207-176b-404d-b61c-33eae413f752', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8830e934-dfef-4117-9e03-34b8a022225f', 'c4e2a4b3-0120-40db-a46c-265b8d7ba153', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b1d52207-176b-404d-b61c-33eae413f752', 'c8831e03-cd96-43a6-8b25-21b7dd81d739', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b1d52207-176b-404d-b61c-33eae413f752', '93170d0d-644c-4271-8e53-0f7dac031204', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b1d52207-176b-404d-b61c-33eae413f752', 'ab68496f-2afd-486f-a4e0-7757e8cf671a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b1d52207-176b-404d-b61c-33eae413f752', '8830e934-dfef-4117-9e03-34b8a022225f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b1d52207-176b-404d-b61c-33eae413f752', 'c4e2a4b3-0120-40db-a46c-265b8d7ba153', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('124387d3-fd8f-4a59-b525-2663817aa123', '9b1576f8-d0e4-49ae-b8e2-11fd41a95774', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('124387d3-fd8f-4a59-b525-2663817aa123', 'ac0625fa-e18d-4037-8086-e33ba8d10a01', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('124387d3-fd8f-4a59-b525-2663817aa123', 'e2ae615b-54e3-4ff4-a77c-4b805a7f2537', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('124387d3-fd8f-4a59-b525-2663817aa123', '43647e23-83b9-45e1-8673-ab97a3c01a3a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('124387d3-fd8f-4a59-b525-2663817aa123', 'add5d5cd-22ac-485f-a148-7c516a16ade4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9b1576f8-d0e4-49ae-b8e2-11fd41a95774', '124387d3-fd8f-4a59-b525-2663817aa123', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9b1576f8-d0e4-49ae-b8e2-11fd41a95774', 'ac0625fa-e18d-4037-8086-e33ba8d10a01', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9b1576f8-d0e4-49ae-b8e2-11fd41a95774', 'e2ae615b-54e3-4ff4-a77c-4b805a7f2537', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9b1576f8-d0e4-49ae-b8e2-11fd41a95774', '43647e23-83b9-45e1-8673-ab97a3c01a3a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9b1576f8-d0e4-49ae-b8e2-11fd41a95774', 'add5d5cd-22ac-485f-a148-7c516a16ade4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ac0625fa-e18d-4037-8086-e33ba8d10a01', '124387d3-fd8f-4a59-b525-2663817aa123', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ac0625fa-e18d-4037-8086-e33ba8d10a01', '9b1576f8-d0e4-49ae-b8e2-11fd41a95774', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ac0625fa-e18d-4037-8086-e33ba8d10a01', 'e2ae615b-54e3-4ff4-a77c-4b805a7f2537', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ac0625fa-e18d-4037-8086-e33ba8d10a01', '43647e23-83b9-45e1-8673-ab97a3c01a3a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ac0625fa-e18d-4037-8086-e33ba8d10a01', 'add5d5cd-22ac-485f-a148-7c516a16ade4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('add5d5cd-22ac-485f-a148-7c516a16ade4', '124387d3-fd8f-4a59-b525-2663817aa123', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('add5d5cd-22ac-485f-a148-7c516a16ade4', '9b1576f8-d0e4-49ae-b8e2-11fd41a95774', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('add5d5cd-22ac-485f-a148-7c516a16ade4', 'ac0625fa-e18d-4037-8086-e33ba8d10a01', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('add5d5cd-22ac-485f-a148-7c516a16ade4', 'e2ae615b-54e3-4ff4-a77c-4b805a7f2537', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('add5d5cd-22ac-485f-a148-7c516a16ade4', '43647e23-83b9-45e1-8673-ab97a3c01a3a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e2ae615b-54e3-4ff4-a77c-4b805a7f2537', '124387d3-fd8f-4a59-b525-2663817aa123', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e2ae615b-54e3-4ff4-a77c-4b805a7f2537', '9b1576f8-d0e4-49ae-b8e2-11fd41a95774', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e2ae615b-54e3-4ff4-a77c-4b805a7f2537', 'ac0625fa-e18d-4037-8086-e33ba8d10a01', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e2ae615b-54e3-4ff4-a77c-4b805a7f2537', '43647e23-83b9-45e1-8673-ab97a3c01a3a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e2ae615b-54e3-4ff4-a77c-4b805a7f2537', 'add5d5cd-22ac-485f-a148-7c516a16ade4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('43647e23-83b9-45e1-8673-ab97a3c01a3a', '124387d3-fd8f-4a59-b525-2663817aa123', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('43647e23-83b9-45e1-8673-ab97a3c01a3a', '9b1576f8-d0e4-49ae-b8e2-11fd41a95774', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('43647e23-83b9-45e1-8673-ab97a3c01a3a', 'ac0625fa-e18d-4037-8086-e33ba8d10a01', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('43647e23-83b9-45e1-8673-ab97a3c01a3a', 'e2ae615b-54e3-4ff4-a77c-4b805a7f2537', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('43647e23-83b9-45e1-8673-ab97a3c01a3a', 'add5d5cd-22ac-485f-a148-7c516a16ade4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('37930fbf-c4eb-45fe-881d-ebd4ea68b29a', 'a59403c0-ae92-4c15-9f4e-db96d4c4cf7f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('37930fbf-c4eb-45fe-881d-ebd4ea68b29a', '11aee3da-362d-4e7c-91c6-17dac7e010df', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('37930fbf-c4eb-45fe-881d-ebd4ea68b29a', '42c60881-1299-471f-83e7-62fc3088a65c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('37930fbf-c4eb-45fe-881d-ebd4ea68b29a', '48f5b108-222a-4c55-8373-f5dbd3031a8e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('37930fbf-c4eb-45fe-881d-ebd4ea68b29a', '8bf92264-e772-4eec-a8bd-f19681d5c186', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b92b1f9e-574c-459c-b481-4dcff829c178', 'c4e2a4b3-0120-40db-a46c-265b8d7ba153', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b92b1f9e-574c-459c-b481-4dcff829c178', 'c8831e03-cd96-43a6-8b25-21b7dd81d739', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b92b1f9e-574c-459c-b481-4dcff829c178', '93170d0d-644c-4271-8e53-0f7dac031204', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b92b1f9e-574c-459c-b481-4dcff829c178', 'ab68496f-2afd-486f-a4e0-7757e8cf671a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b92b1f9e-574c-459c-b481-4dcff829c178', '1a98a32d-2426-4091-a9be-52d4d9c0f657', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('85f81501-6cdd-4776-872a-26394c9bc231', '30c4befe-49fb-4b0c-83e6-3697c7e4a031', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('85f81501-6cdd-4776-872a-26394c9bc231', '518961af-80ba-4cb0-b624-5798dc2596a3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('85f81501-6cdd-4776-872a-26394c9bc231', 'a15645df-ec1f-4688-a327-1ff2f344d006', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('30c4befe-49fb-4b0c-83e6-3697c7e4a031', '85f81501-6cdd-4776-872a-26394c9bc231', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('30c4befe-49fb-4b0c-83e6-3697c7e4a031', '518961af-80ba-4cb0-b624-5798dc2596a3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('30c4befe-49fb-4b0c-83e6-3697c7e4a031', 'a15645df-ec1f-4688-a327-1ff2f344d006', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('518961af-80ba-4cb0-b624-5798dc2596a3', '85f81501-6cdd-4776-872a-26394c9bc231', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('518961af-80ba-4cb0-b624-5798dc2596a3', '30c4befe-49fb-4b0c-83e6-3697c7e4a031', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('518961af-80ba-4cb0-b624-5798dc2596a3', 'a15645df-ec1f-4688-a327-1ff2f344d006', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a15645df-ec1f-4688-a327-1ff2f344d006', '85f81501-6cdd-4776-872a-26394c9bc231', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a15645df-ec1f-4688-a327-1ff2f344d006', '30c4befe-49fb-4b0c-83e6-3697c7e4a031', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a15645df-ec1f-4688-a327-1ff2f344d006', '518961af-80ba-4cb0-b624-5798dc2596a3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f670b886-fe49-4e85-a703-3037f80e6ce1', 'adacc8bc-e55d-42e1-a64f-c269fe57a848', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f670b886-fe49-4e85-a703-3037f80e6ce1', '3243345d-cfeb-44fd-81ac-b3bcdf55b746', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f670b886-fe49-4e85-a703-3037f80e6ce1', '4ef69fc9-367b-40b3-8722-0ccbeb1b8273', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f670b886-fe49-4e85-a703-3037f80e6ce1', '93d9d2a4-3f2a-4c6a-8efb-4ae19b823292', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f670b886-fe49-4e85-a703-3037f80e6ce1', '51b67b30-e671-465c-b579-0a619cf9c1fc', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16525b39-3bf2-42b0-9faa-94e39fe0bac8', '4ce709fa-4b1d-44ee-8737-e882eb933f66', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16525b39-3bf2-42b0-9faa-94e39fe0bac8', 'f0d23ca2-c923-4c7a-b026-db8c564c4e55', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16525b39-3bf2-42b0-9faa-94e39fe0bac8', '7cfbfbb0-8792-4b79-8428-4c41f9261b3b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16525b39-3bf2-42b0-9faa-94e39fe0bac8', '49fb1be3-1dfb-4652-b82a-5ba736511d36', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16525b39-3bf2-42b0-9faa-94e39fe0bac8', '4bb8cc1b-6ec1-477f-b2e2-93f23c4b230b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('adacc8bc-e55d-42e1-a64f-c269fe57a848', 'f670b886-fe49-4e85-a703-3037f80e6ce1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('adacc8bc-e55d-42e1-a64f-c269fe57a848', '3243345d-cfeb-44fd-81ac-b3bcdf55b746', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('adacc8bc-e55d-42e1-a64f-c269fe57a848', '4ef69fc9-367b-40b3-8722-0ccbeb1b8273', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('adacc8bc-e55d-42e1-a64f-c269fe57a848', '93d9d2a4-3f2a-4c6a-8efb-4ae19b823292', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('adacc8bc-e55d-42e1-a64f-c269fe57a848', '51b67b30-e671-465c-b579-0a619cf9c1fc', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('49fb1be3-1dfb-4652-b82a-5ba736511d36', '16525b39-3bf2-42b0-9faa-94e39fe0bac8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('49fb1be3-1dfb-4652-b82a-5ba736511d36', '4ce709fa-4b1d-44ee-8737-e882eb933f66', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('49fb1be3-1dfb-4652-b82a-5ba736511d36', 'f0d23ca2-c923-4c7a-b026-db8c564c4e55', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('49fb1be3-1dfb-4652-b82a-5ba736511d36', '7cfbfbb0-8792-4b79-8428-4c41f9261b3b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('49fb1be3-1dfb-4652-b82a-5ba736511d36', '4bb8cc1b-6ec1-477f-b2e2-93f23c4b230b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('34c2c093-0189-4325-ad9d-f76bf69e0c4e', '85f81501-6cdd-4776-872a-26394c9bc231', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('34c2c093-0189-4325-ad9d-f76bf69e0c4e', '30c4befe-49fb-4b0c-83e6-3697c7e4a031', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('34c2c093-0189-4325-ad9d-f76bf69e0c4e', '518961af-80ba-4cb0-b624-5798dc2596a3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('34c2c093-0189-4325-ad9d-f76bf69e0c4e', 'a15645df-ec1f-4688-a327-1ff2f344d006', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4ef69fc9-367b-40b3-8722-0ccbeb1b8273', '93d9d2a4-3f2a-4c6a-8efb-4ae19b823292', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4ef69fc9-367b-40b3-8722-0ccbeb1b8273', '51b67b30-e671-465c-b579-0a619cf9c1fc', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4ef69fc9-367b-40b3-8722-0ccbeb1b8273', '1bc301a3-8658-4f22-8a9a-8aeb55dd3ba4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4ef69fc9-367b-40b3-8722-0ccbeb1b8273', '2d42cccd-e0be-473e-91b2-572e5eb92b3b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4ef69fc9-367b-40b3-8722-0ccbeb1b8273', 'f670b886-fe49-4e85-a703-3037f80e6ce1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('93d9d2a4-3f2a-4c6a-8efb-4ae19b823292', '4ef69fc9-367b-40b3-8722-0ccbeb1b8273', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('93d9d2a4-3f2a-4c6a-8efb-4ae19b823292', '51b67b30-e671-465c-b579-0a619cf9c1fc', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('93d9d2a4-3f2a-4c6a-8efb-4ae19b823292', '1bc301a3-8658-4f22-8a9a-8aeb55dd3ba4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('93d9d2a4-3f2a-4c6a-8efb-4ae19b823292', '2d42cccd-e0be-473e-91b2-572e5eb92b3b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('93d9d2a4-3f2a-4c6a-8efb-4ae19b823292', 'f670b886-fe49-4e85-a703-3037f80e6ce1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('51b67b30-e671-465c-b579-0a619cf9c1fc', '4ef69fc9-367b-40b3-8722-0ccbeb1b8273', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('51b67b30-e671-465c-b579-0a619cf9c1fc', '93d9d2a4-3f2a-4c6a-8efb-4ae19b823292', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('51b67b30-e671-465c-b579-0a619cf9c1fc', '1bc301a3-8658-4f22-8a9a-8aeb55dd3ba4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('51b67b30-e671-465c-b579-0a619cf9c1fc', '2d42cccd-e0be-473e-91b2-572e5eb92b3b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('51b67b30-e671-465c-b579-0a619cf9c1fc', 'f670b886-fe49-4e85-a703-3037f80e6ce1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1bc301a3-8658-4f22-8a9a-8aeb55dd3ba4', '4ef69fc9-367b-40b3-8722-0ccbeb1b8273', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1bc301a3-8658-4f22-8a9a-8aeb55dd3ba4', '93d9d2a4-3f2a-4c6a-8efb-4ae19b823292', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1bc301a3-8658-4f22-8a9a-8aeb55dd3ba4', '51b67b30-e671-465c-b579-0a619cf9c1fc', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1bc301a3-8658-4f22-8a9a-8aeb55dd3ba4', '2d42cccd-e0be-473e-91b2-572e5eb92b3b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1bc301a3-8658-4f22-8a9a-8aeb55dd3ba4', 'f670b886-fe49-4e85-a703-3037f80e6ce1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7f961c4-3d7e-4428-8217-83ba628eec45', 'f670b886-fe49-4e85-a703-3037f80e6ce1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7f961c4-3d7e-4428-8217-83ba628eec45', 'adacc8bc-e55d-42e1-a64f-c269fe57a848', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7f961c4-3d7e-4428-8217-83ba628eec45', '4ef69fc9-367b-40b3-8722-0ccbeb1b8273', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7f961c4-3d7e-4428-8217-83ba628eec45', '93d9d2a4-3f2a-4c6a-8efb-4ae19b823292', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7f961c4-3d7e-4428-8217-83ba628eec45', '51b67b30-e671-465c-b579-0a619cf9c1fc', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d42cccd-e0be-473e-91b2-572e5eb92b3b', '4ef69fc9-367b-40b3-8722-0ccbeb1b8273', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d42cccd-e0be-473e-91b2-572e5eb92b3b', '93d9d2a4-3f2a-4c6a-8efb-4ae19b823292', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d42cccd-e0be-473e-91b2-572e5eb92b3b', '51b67b30-e671-465c-b579-0a619cf9c1fc', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d42cccd-e0be-473e-91b2-572e5eb92b3b', '1bc301a3-8658-4f22-8a9a-8aeb55dd3ba4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d42cccd-e0be-473e-91b2-572e5eb92b3b', 'f670b886-fe49-4e85-a703-3037f80e6ce1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3243345d-cfeb-44fd-81ac-b3bcdf55b746', 'f670b886-fe49-4e85-a703-3037f80e6ce1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3243345d-cfeb-44fd-81ac-b3bcdf55b746', 'adacc8bc-e55d-42e1-a64f-c269fe57a848', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3243345d-cfeb-44fd-81ac-b3bcdf55b746', '4ef69fc9-367b-40b3-8722-0ccbeb1b8273', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3243345d-cfeb-44fd-81ac-b3bcdf55b746', '93d9d2a4-3f2a-4c6a-8efb-4ae19b823292', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3243345d-cfeb-44fd-81ac-b3bcdf55b746', '51b67b30-e671-465c-b579-0a619cf9c1fc', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7257de2-961e-4195-900c-2ac8a236423e', '85f81501-6cdd-4776-872a-26394c9bc231', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7257de2-961e-4195-900c-2ac8a236423e', '30c4befe-49fb-4b0c-83e6-3697c7e4a031', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7257de2-961e-4195-900c-2ac8a236423e', '518961af-80ba-4cb0-b624-5798dc2596a3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7257de2-961e-4195-900c-2ac8a236423e', 'a15645df-ec1f-4688-a327-1ff2f344d006', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aee91b71-7355-473e-88ae-4458e16ed5e3', 'c73367e0-c62e-4f7e-808c-a77e22726b09', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aee91b71-7355-473e-88ae-4458e16ed5e3', '2f123cfc-77e0-44e7-9b57-11864b6ee4ea', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aee91b71-7355-473e-88ae-4458e16ed5e3', '02741241-cf82-4bfb-bae6-301383ff30d3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aee91b71-7355-473e-88ae-4458e16ed5e3', '1581b70c-609d-4933-9db8-ad282739697c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aee91b71-7355-473e-88ae-4458e16ed5e3', 'cebfe975-8508-40b8-b1ae-3e2ce22b563b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f65a6d8-f015-49f1-acef-a07b5753f6e3', 'c73367e0-c62e-4f7e-808c-a77e22726b09', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f65a6d8-f015-49f1-acef-a07b5753f6e3', '2f123cfc-77e0-44e7-9b57-11864b6ee4ea', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f65a6d8-f015-49f1-acef-a07b5753f6e3', '02741241-cf82-4bfb-bae6-301383ff30d3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f65a6d8-f015-49f1-acef-a07b5753f6e3', '1581b70c-609d-4933-9db8-ad282739697c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f65a6d8-f015-49f1-acef-a07b5753f6e3', 'cebfe975-8508-40b8-b1ae-3e2ce22b563b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c73367e0-c62e-4f7e-808c-a77e22726b09', '2f123cfc-77e0-44e7-9b57-11864b6ee4ea', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c73367e0-c62e-4f7e-808c-a77e22726b09', '02741241-cf82-4bfb-bae6-301383ff30d3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c73367e0-c62e-4f7e-808c-a77e22726b09', '1581b70c-609d-4933-9db8-ad282739697c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c73367e0-c62e-4f7e-808c-a77e22726b09', 'cebfe975-8508-40b8-b1ae-3e2ce22b563b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c73367e0-c62e-4f7e-808c-a77e22726b09', 'beb3d44f-c7d9-4cac-ac34-1ec0d95e3ba9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2f123cfc-77e0-44e7-9b57-11864b6ee4ea', 'c73367e0-c62e-4f7e-808c-a77e22726b09', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2f123cfc-77e0-44e7-9b57-11864b6ee4ea', '02741241-cf82-4bfb-bae6-301383ff30d3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2f123cfc-77e0-44e7-9b57-11864b6ee4ea', '1581b70c-609d-4933-9db8-ad282739697c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2f123cfc-77e0-44e7-9b57-11864b6ee4ea', 'cebfe975-8508-40b8-b1ae-3e2ce22b563b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2f123cfc-77e0-44e7-9b57-11864b6ee4ea', 'beb3d44f-c7d9-4cac-ac34-1ec0d95e3ba9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02741241-cf82-4bfb-bae6-301383ff30d3', 'c73367e0-c62e-4f7e-808c-a77e22726b09', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02741241-cf82-4bfb-bae6-301383ff30d3', '2f123cfc-77e0-44e7-9b57-11864b6ee4ea', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02741241-cf82-4bfb-bae6-301383ff30d3', '1581b70c-609d-4933-9db8-ad282739697c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02741241-cf82-4bfb-bae6-301383ff30d3', 'cebfe975-8508-40b8-b1ae-3e2ce22b563b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02741241-cf82-4bfb-bae6-301383ff30d3', 'beb3d44f-c7d9-4cac-ac34-1ec0d95e3ba9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1581b70c-609d-4933-9db8-ad282739697c', 'c73367e0-c62e-4f7e-808c-a77e22726b09', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1581b70c-609d-4933-9db8-ad282739697c', '2f123cfc-77e0-44e7-9b57-11864b6ee4ea', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1581b70c-609d-4933-9db8-ad282739697c', '02741241-cf82-4bfb-bae6-301383ff30d3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1581b70c-609d-4933-9db8-ad282739697c', 'cebfe975-8508-40b8-b1ae-3e2ce22b563b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1581b70c-609d-4933-9db8-ad282739697c', 'beb3d44f-c7d9-4cac-ac34-1ec0d95e3ba9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cebfe975-8508-40b8-b1ae-3e2ce22b563b', 'c73367e0-c62e-4f7e-808c-a77e22726b09', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cebfe975-8508-40b8-b1ae-3e2ce22b563b', '2f123cfc-77e0-44e7-9b57-11864b6ee4ea', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cebfe975-8508-40b8-b1ae-3e2ce22b563b', '02741241-cf82-4bfb-bae6-301383ff30d3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cebfe975-8508-40b8-b1ae-3e2ce22b563b', '1581b70c-609d-4933-9db8-ad282739697c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cebfe975-8508-40b8-b1ae-3e2ce22b563b', 'beb3d44f-c7d9-4cac-ac34-1ec0d95e3ba9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('beb3d44f-c7d9-4cac-ac34-1ec0d95e3ba9', 'c73367e0-c62e-4f7e-808c-a77e22726b09', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('beb3d44f-c7d9-4cac-ac34-1ec0d95e3ba9', '2f123cfc-77e0-44e7-9b57-11864b6ee4ea', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('beb3d44f-c7d9-4cac-ac34-1ec0d95e3ba9', '02741241-cf82-4bfb-bae6-301383ff30d3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('beb3d44f-c7d9-4cac-ac34-1ec0d95e3ba9', '1581b70c-609d-4933-9db8-ad282739697c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('beb3d44f-c7d9-4cac-ac34-1ec0d95e3ba9', 'cebfe975-8508-40b8-b1ae-3e2ce22b563b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9607248f-fa44-43ab-8ed1-7a214aacaf3c', 'c73367e0-c62e-4f7e-808c-a77e22726b09', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9607248f-fa44-43ab-8ed1-7a214aacaf3c', '2f123cfc-77e0-44e7-9b57-11864b6ee4ea', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9607248f-fa44-43ab-8ed1-7a214aacaf3c', '02741241-cf82-4bfb-bae6-301383ff30d3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9607248f-fa44-43ab-8ed1-7a214aacaf3c', '1581b70c-609d-4933-9db8-ad282739697c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9607248f-fa44-43ab-8ed1-7a214aacaf3c', 'cebfe975-8508-40b8-b1ae-3e2ce22b563b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d06206c0-be84-4b48-99c2-14f477a35016', 'f7014423-1706-4efb-bb4c-5a61f7b981f8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d06206c0-be84-4b48-99c2-14f477a35016', 'e14e7c61-dc24-40c5-afec-8f52b9e91b0f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d06206c0-be84-4b48-99c2-14f477a35016', '7ed385bd-a2a4-451c-b6a4-b71a0a9050a4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d06206c0-be84-4b48-99c2-14f477a35016', '3a680616-62d9-4b50-a939-3ab71a8f42db', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d06206c0-be84-4b48-99c2-14f477a35016', '0aba350c-7e97-414a-9cd6-45552fc38a6c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f7014423-1706-4efb-bb4c-5a61f7b981f8', 'd06206c0-be84-4b48-99c2-14f477a35016', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f7014423-1706-4efb-bb4c-5a61f7b981f8', 'e14e7c61-dc24-40c5-afec-8f52b9e91b0f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f7014423-1706-4efb-bb4c-5a61f7b981f8', '7ed385bd-a2a4-451c-b6a4-b71a0a9050a4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f7014423-1706-4efb-bb4c-5a61f7b981f8', '3a680616-62d9-4b50-a939-3ab71a8f42db', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f7014423-1706-4efb-bb4c-5a61f7b981f8', '0aba350c-7e97-414a-9cd6-45552fc38a6c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e14e7c61-dc24-40c5-afec-8f52b9e91b0f', 'd06206c0-be84-4b48-99c2-14f477a35016', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e14e7c61-dc24-40c5-afec-8f52b9e91b0f', 'f7014423-1706-4efb-bb4c-5a61f7b981f8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e14e7c61-dc24-40c5-afec-8f52b9e91b0f', '7ed385bd-a2a4-451c-b6a4-b71a0a9050a4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e14e7c61-dc24-40c5-afec-8f52b9e91b0f', '3a680616-62d9-4b50-a939-3ab71a8f42db', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e14e7c61-dc24-40c5-afec-8f52b9e91b0f', '0aba350c-7e97-414a-9cd6-45552fc38a6c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7ed385bd-a2a4-451c-b6a4-b71a0a9050a4', 'd06206c0-be84-4b48-99c2-14f477a35016', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7ed385bd-a2a4-451c-b6a4-b71a0a9050a4', 'f7014423-1706-4efb-bb4c-5a61f7b981f8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7ed385bd-a2a4-451c-b6a4-b71a0a9050a4', 'e14e7c61-dc24-40c5-afec-8f52b9e91b0f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7ed385bd-a2a4-451c-b6a4-b71a0a9050a4', '3a680616-62d9-4b50-a939-3ab71a8f42db', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7ed385bd-a2a4-451c-b6a4-b71a0a9050a4', '0aba350c-7e97-414a-9cd6-45552fc38a6c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a680616-62d9-4b50-a939-3ab71a8f42db', 'd06206c0-be84-4b48-99c2-14f477a35016', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a680616-62d9-4b50-a939-3ab71a8f42db', 'f7014423-1706-4efb-bb4c-5a61f7b981f8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a680616-62d9-4b50-a939-3ab71a8f42db', 'e14e7c61-dc24-40c5-afec-8f52b9e91b0f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a680616-62d9-4b50-a939-3ab71a8f42db', '7ed385bd-a2a4-451c-b6a4-b71a0a9050a4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a680616-62d9-4b50-a939-3ab71a8f42db', '0aba350c-7e97-414a-9cd6-45552fc38a6c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0aba350c-7e97-414a-9cd6-45552fc38a6c', 'd06206c0-be84-4b48-99c2-14f477a35016', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0aba350c-7e97-414a-9cd6-45552fc38a6c', 'f7014423-1706-4efb-bb4c-5a61f7b981f8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0aba350c-7e97-414a-9cd6-45552fc38a6c', 'e14e7c61-dc24-40c5-afec-8f52b9e91b0f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0aba350c-7e97-414a-9cd6-45552fc38a6c', '7ed385bd-a2a4-451c-b6a4-b71a0a9050a4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0aba350c-7e97-414a-9cd6-45552fc38a6c', '3a680616-62d9-4b50-a939-3ab71a8f42db', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb0207f9-4c58-4c5a-9005-97ed4d120cd3', 'd06206c0-be84-4b48-99c2-14f477a35016', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb0207f9-4c58-4c5a-9005-97ed4d120cd3', 'f7014423-1706-4efb-bb4c-5a61f7b981f8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb0207f9-4c58-4c5a-9005-97ed4d120cd3', 'e14e7c61-dc24-40c5-afec-8f52b9e91b0f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb0207f9-4c58-4c5a-9005-97ed4d120cd3', '7ed385bd-a2a4-451c-b6a4-b71a0a9050a4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb0207f9-4c58-4c5a-9005-97ed4d120cd3', '3a680616-62d9-4b50-a939-3ab71a8f42db', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45de0da2-4083-4bde-8814-f2d02a7e1e65', 'd06206c0-be84-4b48-99c2-14f477a35016', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45de0da2-4083-4bde-8814-f2d02a7e1e65', 'f7014423-1706-4efb-bb4c-5a61f7b981f8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45de0da2-4083-4bde-8814-f2d02a7e1e65', 'e14e7c61-dc24-40c5-afec-8f52b9e91b0f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45de0da2-4083-4bde-8814-f2d02a7e1e65', '7ed385bd-a2a4-451c-b6a4-b71a0a9050a4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45de0da2-4083-4bde-8814-f2d02a7e1e65', '3a680616-62d9-4b50-a939-3ab71a8f42db', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('431686d6-af1e-4b97-b604-2ed68e630995', '9f9560d9-fa8b-4c6e-a071-8cde1387f829', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('431686d6-af1e-4b97-b604-2ed68e630995', 'd06206c0-be84-4b48-99c2-14f477a35016', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('431686d6-af1e-4b97-b604-2ed68e630995', 'f7014423-1706-4efb-bb4c-5a61f7b981f8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('431686d6-af1e-4b97-b604-2ed68e630995', 'e14e7c61-dc24-40c5-afec-8f52b9e91b0f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('431686d6-af1e-4b97-b604-2ed68e630995', '7ed385bd-a2a4-451c-b6a4-b71a0a9050a4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7e1e9b80-99ae-4206-9622-0f4525b8b8c6', 'c73367e0-c62e-4f7e-808c-a77e22726b09', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7e1e9b80-99ae-4206-9622-0f4525b8b8c6', '2f123cfc-77e0-44e7-9b57-11864b6ee4ea', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7e1e9b80-99ae-4206-9622-0f4525b8b8c6', '02741241-cf82-4bfb-bae6-301383ff30d3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7e1e9b80-99ae-4206-9622-0f4525b8b8c6', '1581b70c-609d-4933-9db8-ad282739697c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7e1e9b80-99ae-4206-9622-0f4525b8b8c6', 'cebfe975-8508-40b8-b1ae-3e2ce22b563b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9f9560d9-fa8b-4c6e-a071-8cde1387f829', '431686d6-af1e-4b97-b604-2ed68e630995', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9f9560d9-fa8b-4c6e-a071-8cde1387f829', 'd06206c0-be84-4b48-99c2-14f477a35016', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9f9560d9-fa8b-4c6e-a071-8cde1387f829', 'f7014423-1706-4efb-bb4c-5a61f7b981f8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9f9560d9-fa8b-4c6e-a071-8cde1387f829', 'e14e7c61-dc24-40c5-afec-8f52b9e91b0f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9f9560d9-fa8b-4c6e-a071-8cde1387f829', '7ed385bd-a2a4-451c-b6a4-b71a0a9050a4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6dd1f67d-6ca0-4df3-8e90-e4b369c4a30f', '75a4472d-e324-4dc9-938b-3904e534880f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6dd1f67d-6ca0-4df3-8e90-e4b369c4a30f', '7a76606d-0eed-4756-b9a9-18511efcbf79', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6dd1f67d-6ca0-4df3-8e90-e4b369c4a30f', '89a508bf-c5a6-449f-b0a1-eff7ecb08a79', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6dd1f67d-6ca0-4df3-8e90-e4b369c4a30f', 'b8bdcb41-ac08-4fad-a8fc-c68a95ba5bb7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6dd1f67d-6ca0-4df3-8e90-e4b369c4a30f', 'fe1d328a-d8cf-416b-abd7-297f187f8b2f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75a4472d-e324-4dc9-938b-3904e534880f', '6dd1f67d-6ca0-4df3-8e90-e4b369c4a30f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75a4472d-e324-4dc9-938b-3904e534880f', '7a76606d-0eed-4756-b9a9-18511efcbf79', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75a4472d-e324-4dc9-938b-3904e534880f', '89a508bf-c5a6-449f-b0a1-eff7ecb08a79', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75a4472d-e324-4dc9-938b-3904e534880f', 'b8bdcb41-ac08-4fad-a8fc-c68a95ba5bb7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75a4472d-e324-4dc9-938b-3904e534880f', 'fe1d328a-d8cf-416b-abd7-297f187f8b2f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a76606d-0eed-4756-b9a9-18511efcbf79', '6dd1f67d-6ca0-4df3-8e90-e4b369c4a30f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a76606d-0eed-4756-b9a9-18511efcbf79', '75a4472d-e324-4dc9-938b-3904e534880f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a76606d-0eed-4756-b9a9-18511efcbf79', '89a508bf-c5a6-449f-b0a1-eff7ecb08a79', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a76606d-0eed-4756-b9a9-18511efcbf79', 'b8bdcb41-ac08-4fad-a8fc-c68a95ba5bb7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a76606d-0eed-4756-b9a9-18511efcbf79', 'fe1d328a-d8cf-416b-abd7-297f187f8b2f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89a508bf-c5a6-449f-b0a1-eff7ecb08a79', '6dd1f67d-6ca0-4df3-8e90-e4b369c4a30f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89a508bf-c5a6-449f-b0a1-eff7ecb08a79', '75a4472d-e324-4dc9-938b-3904e534880f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89a508bf-c5a6-449f-b0a1-eff7ecb08a79', '7a76606d-0eed-4756-b9a9-18511efcbf79', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89a508bf-c5a6-449f-b0a1-eff7ecb08a79', 'b8bdcb41-ac08-4fad-a8fc-c68a95ba5bb7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89a508bf-c5a6-449f-b0a1-eff7ecb08a79', 'fe1d328a-d8cf-416b-abd7-297f187f8b2f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b8bdcb41-ac08-4fad-a8fc-c68a95ba5bb7', '6dd1f67d-6ca0-4df3-8e90-e4b369c4a30f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b8bdcb41-ac08-4fad-a8fc-c68a95ba5bb7', '75a4472d-e324-4dc9-938b-3904e534880f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b8bdcb41-ac08-4fad-a8fc-c68a95ba5bb7', '7a76606d-0eed-4756-b9a9-18511efcbf79', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b8bdcb41-ac08-4fad-a8fc-c68a95ba5bb7', '89a508bf-c5a6-449f-b0a1-eff7ecb08a79', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b8bdcb41-ac08-4fad-a8fc-c68a95ba5bb7', 'fe1d328a-d8cf-416b-abd7-297f187f8b2f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('42fffcdd-d07b-4bb9-8056-2f7d26c64ca7', '6dd1f67d-6ca0-4df3-8e90-e4b369c4a30f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('42fffcdd-d07b-4bb9-8056-2f7d26c64ca7', '75a4472d-e324-4dc9-938b-3904e534880f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('42fffcdd-d07b-4bb9-8056-2f7d26c64ca7', '7a76606d-0eed-4756-b9a9-18511efcbf79', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('42fffcdd-d07b-4bb9-8056-2f7d26c64ca7', '89a508bf-c5a6-449f-b0a1-eff7ecb08a79', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('42fffcdd-d07b-4bb9-8056-2f7d26c64ca7', 'b8bdcb41-ac08-4fad-a8fc-c68a95ba5bb7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe1d328a-d8cf-416b-abd7-297f187f8b2f', '6dd1f67d-6ca0-4df3-8e90-e4b369c4a30f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe1d328a-d8cf-416b-abd7-297f187f8b2f', '75a4472d-e324-4dc9-938b-3904e534880f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe1d328a-d8cf-416b-abd7-297f187f8b2f', '7a76606d-0eed-4756-b9a9-18511efcbf79', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe1d328a-d8cf-416b-abd7-297f187f8b2f', '89a508bf-c5a6-449f-b0a1-eff7ecb08a79', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe1d328a-d8cf-416b-abd7-297f187f8b2f', 'b8bdcb41-ac08-4fad-a8fc-c68a95ba5bb7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89a85cc5-4f5a-4b6f-9457-c957726a9df5', '6dd1f67d-6ca0-4df3-8e90-e4b369c4a30f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89a85cc5-4f5a-4b6f-9457-c957726a9df5', '75a4472d-e324-4dc9-938b-3904e534880f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89a85cc5-4f5a-4b6f-9457-c957726a9df5', '7a76606d-0eed-4756-b9a9-18511efcbf79', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89a85cc5-4f5a-4b6f-9457-c957726a9df5', '89a508bf-c5a6-449f-b0a1-eff7ecb08a79', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89a85cc5-4f5a-4b6f-9457-c957726a9df5', 'b8bdcb41-ac08-4fad-a8fc-c68a95ba5bb7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d944b67a-9a36-42d0-b055-e3b8f452e4f0', '6dd1f67d-6ca0-4df3-8e90-e4b369c4a30f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d944b67a-9a36-42d0-b055-e3b8f452e4f0', '75a4472d-e324-4dc9-938b-3904e534880f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d944b67a-9a36-42d0-b055-e3b8f452e4f0', '7a76606d-0eed-4756-b9a9-18511efcbf79', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d944b67a-9a36-42d0-b055-e3b8f452e4f0', '89a508bf-c5a6-449f-b0a1-eff7ecb08a79', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d944b67a-9a36-42d0-b055-e3b8f452e4f0', 'b8bdcb41-ac08-4fad-a8fc-c68a95ba5bb7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe1c8a53-e0c9-42e7-b4ba-026a053fc196', '335809e0-3e1b-4a5a-ae5c-fa04f86e458d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe1c8a53-e0c9-42e7-b4ba-026a053fc196', '5dfd9bad-bdbe-4cc6-b893-6771d5e56129', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe1c8a53-e0c9-42e7-b4ba-026a053fc196', '6dd1f67d-6ca0-4df3-8e90-e4b369c4a30f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe1c8a53-e0c9-42e7-b4ba-026a053fc196', '75a4472d-e324-4dc9-938b-3904e534880f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe1c8a53-e0c9-42e7-b4ba-026a053fc196', '7a76606d-0eed-4756-b9a9-18511efcbf79', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('335809e0-3e1b-4a5a-ae5c-fa04f86e458d', 'fe1c8a53-e0c9-42e7-b4ba-026a053fc196', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('335809e0-3e1b-4a5a-ae5c-fa04f86e458d', '5dfd9bad-bdbe-4cc6-b893-6771d5e56129', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('335809e0-3e1b-4a5a-ae5c-fa04f86e458d', '6dd1f67d-6ca0-4df3-8e90-e4b369c4a30f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('335809e0-3e1b-4a5a-ae5c-fa04f86e458d', '75a4472d-e324-4dc9-938b-3904e534880f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('335809e0-3e1b-4a5a-ae5c-fa04f86e458d', '7a76606d-0eed-4756-b9a9-18511efcbf79', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5dfd9bad-bdbe-4cc6-b893-6771d5e56129', 'fe1c8a53-e0c9-42e7-b4ba-026a053fc196', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5dfd9bad-bdbe-4cc6-b893-6771d5e56129', '335809e0-3e1b-4a5a-ae5c-fa04f86e458d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5dfd9bad-bdbe-4cc6-b893-6771d5e56129', '6dd1f67d-6ca0-4df3-8e90-e4b369c4a30f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5dfd9bad-bdbe-4cc6-b893-6771d5e56129', '75a4472d-e324-4dc9-938b-3904e534880f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5dfd9bad-bdbe-4cc6-b893-6771d5e56129', '7a76606d-0eed-4756-b9a9-18511efcbf79', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5d79968f-ef2b-4d61-b3d7-944860d7c858', '6dd1f67d-6ca0-4df3-8e90-e4b369c4a30f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5d79968f-ef2b-4d61-b3d7-944860d7c858', '75a4472d-e324-4dc9-938b-3904e534880f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5d79968f-ef2b-4d61-b3d7-944860d7c858', '7a76606d-0eed-4756-b9a9-18511efcbf79', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5d79968f-ef2b-4d61-b3d7-944860d7c858', '89a508bf-c5a6-449f-b0a1-eff7ecb08a79', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5d79968f-ef2b-4d61-b3d7-944860d7c858', 'b8bdcb41-ac08-4fad-a8fc-c68a95ba5bb7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('38b62114-dd99-4e14-a068-d647871dd417', 'cf6ab98b-506a-404c-bcdf-6e8ed48061f5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('38b62114-dd99-4e14-a068-d647871dd417', '6dd1f67d-6ca0-4df3-8e90-e4b369c4a30f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('38b62114-dd99-4e14-a068-d647871dd417', '75a4472d-e324-4dc9-938b-3904e534880f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9248589a-cf88-487c-9264-e76b1f8a405f', '6dd1f67d-6ca0-4df3-8e90-e4b369c4a30f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9248589a-cf88-487c-9264-e76b1f8a405f', '75a4472d-e324-4dc9-938b-3904e534880f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9248589a-cf88-487c-9264-e76b1f8a405f', '7a76606d-0eed-4756-b9a9-18511efcbf79', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9248589a-cf88-487c-9264-e76b1f8a405f', '89a508bf-c5a6-449f-b0a1-eff7ecb08a79', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9248589a-cf88-487c-9264-e76b1f8a405f', 'b8bdcb41-ac08-4fad-a8fc-c68a95ba5bb7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cf6ab98b-506a-404c-bcdf-6e8ed48061f5', '38b62114-dd99-4e14-a068-d647871dd417', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cf6ab98b-506a-404c-bcdf-6e8ed48061f5', '6dd1f67d-6ca0-4df3-8e90-e4b369c4a30f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cf6ab98b-506a-404c-bcdf-6e8ed48061f5', '75a4472d-e324-4dc9-938b-3904e534880f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b3b4f6e-8d42-4102-9fdf-fdecec039043', '6dd1f67d-6ca0-4df3-8e90-e4b369c4a30f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b3b4f6e-8d42-4102-9fdf-fdecec039043', '75a4472d-e324-4dc9-938b-3904e534880f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b3b4f6e-8d42-4102-9fdf-fdecec039043', '7a76606d-0eed-4756-b9a9-18511efcbf79', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b3b4f6e-8d42-4102-9fdf-fdecec039043', '89a508bf-c5a6-449f-b0a1-eff7ecb08a79', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b3b4f6e-8d42-4102-9fdf-fdecec039043', 'b8bdcb41-ac08-4fad-a8fc-c68a95ba5bb7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f492c068-6f8d-4255-9f41-34c972d8d118', '6dd1f67d-6ca0-4df3-8e90-e4b369c4a30f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f492c068-6f8d-4255-9f41-34c972d8d118', '75a4472d-e324-4dc9-938b-3904e534880f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f492c068-6f8d-4255-9f41-34c972d8d118', '7a76606d-0eed-4756-b9a9-18511efcbf79', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f492c068-6f8d-4255-9f41-34c972d8d118', '89a508bf-c5a6-449f-b0a1-eff7ecb08a79', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f492c068-6f8d-4255-9f41-34c972d8d118', 'b8bdcb41-ac08-4fad-a8fc-c68a95ba5bb7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('71599ffa-aa11-4612-9a5d-5365e475ce55', '701923a2-f904-4e13-85a5-71bf7b730c93', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('71599ffa-aa11-4612-9a5d-5365e475ce55', '49b1eb5c-277a-4a56-a00b-2d58d1767ebd', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('71599ffa-aa11-4612-9a5d-5365e475ce55', '180a3154-5305-431e-9383-0130c9892e02', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('71599ffa-aa11-4612-9a5d-5365e475ce55', 'bc56a01f-32e8-4301-8efe-9602b1f93588', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('71599ffa-aa11-4612-9a5d-5365e475ce55', '483ebe12-2e2a-41aa-9728-3544429a3284', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('701923a2-f904-4e13-85a5-71bf7b730c93', '71599ffa-aa11-4612-9a5d-5365e475ce55', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('701923a2-f904-4e13-85a5-71bf7b730c93', '49b1eb5c-277a-4a56-a00b-2d58d1767ebd', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('701923a2-f904-4e13-85a5-71bf7b730c93', '180a3154-5305-431e-9383-0130c9892e02', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('701923a2-f904-4e13-85a5-71bf7b730c93', 'bc56a01f-32e8-4301-8efe-9602b1f93588', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('701923a2-f904-4e13-85a5-71bf7b730c93', '483ebe12-2e2a-41aa-9728-3544429a3284', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('49b1eb5c-277a-4a56-a00b-2d58d1767ebd', '71599ffa-aa11-4612-9a5d-5365e475ce55', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('49b1eb5c-277a-4a56-a00b-2d58d1767ebd', '701923a2-f904-4e13-85a5-71bf7b730c93', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('49b1eb5c-277a-4a56-a00b-2d58d1767ebd', '180a3154-5305-431e-9383-0130c9892e02', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('49b1eb5c-277a-4a56-a00b-2d58d1767ebd', 'bc56a01f-32e8-4301-8efe-9602b1f93588', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('49b1eb5c-277a-4a56-a00b-2d58d1767ebd', '483ebe12-2e2a-41aa-9728-3544429a3284', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('180a3154-5305-431e-9383-0130c9892e02', 'bc56a01f-32e8-4301-8efe-9602b1f93588', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('180a3154-5305-431e-9383-0130c9892e02', '483ebe12-2e2a-41aa-9728-3544429a3284', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('180a3154-5305-431e-9383-0130c9892e02', 'eb28aaec-1882-4abd-b48c-eab5b44c6b20', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('180a3154-5305-431e-9383-0130c9892e02', 'f2f7e659-6dcd-4108-87f6-319ef97179a2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('180a3154-5305-431e-9383-0130c9892e02', '536ff630-038e-495e-8963-8573486b70f5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('67320027-4a8f-413a-ab9c-bbe449651dbc', '0454584e-ffb8-4d6a-990c-7139c980739b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('67320027-4a8f-413a-ab9c-bbe449651dbc', 'af18468b-95f5-4c70-9a3d-cc537e2e1922', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('67320027-4a8f-413a-ab9c-bbe449651dbc', '31c93718-5124-4722-abdf-6b6600c68d36', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bc56a01f-32e8-4301-8efe-9602b1f93588', '180a3154-5305-431e-9383-0130c9892e02', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bc56a01f-32e8-4301-8efe-9602b1f93588', '483ebe12-2e2a-41aa-9728-3544429a3284', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bc56a01f-32e8-4301-8efe-9602b1f93588', 'eb28aaec-1882-4abd-b48c-eab5b44c6b20', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bc56a01f-32e8-4301-8efe-9602b1f93588', 'f2f7e659-6dcd-4108-87f6-319ef97179a2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bc56a01f-32e8-4301-8efe-9602b1f93588', '536ff630-038e-495e-8963-8573486b70f5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('483ebe12-2e2a-41aa-9728-3544429a3284', '180a3154-5305-431e-9383-0130c9892e02', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('483ebe12-2e2a-41aa-9728-3544429a3284', 'bc56a01f-32e8-4301-8efe-9602b1f93588', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('483ebe12-2e2a-41aa-9728-3544429a3284', 'eb28aaec-1882-4abd-b48c-eab5b44c6b20', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('483ebe12-2e2a-41aa-9728-3544429a3284', 'f2f7e659-6dcd-4108-87f6-319ef97179a2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('483ebe12-2e2a-41aa-9728-3544429a3284', '536ff630-038e-495e-8963-8573486b70f5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb28aaec-1882-4abd-b48c-eab5b44c6b20', '180a3154-5305-431e-9383-0130c9892e02', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb28aaec-1882-4abd-b48c-eab5b44c6b20', 'bc56a01f-32e8-4301-8efe-9602b1f93588', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb28aaec-1882-4abd-b48c-eab5b44c6b20', '483ebe12-2e2a-41aa-9728-3544429a3284', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb28aaec-1882-4abd-b48c-eab5b44c6b20', 'f2f7e659-6dcd-4108-87f6-319ef97179a2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb28aaec-1882-4abd-b48c-eab5b44c6b20', '536ff630-038e-495e-8963-8573486b70f5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f2f7e659-6dcd-4108-87f6-319ef97179a2', '180a3154-5305-431e-9383-0130c9892e02', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f2f7e659-6dcd-4108-87f6-319ef97179a2', 'bc56a01f-32e8-4301-8efe-9602b1f93588', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f2f7e659-6dcd-4108-87f6-319ef97179a2', '483ebe12-2e2a-41aa-9728-3544429a3284', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f2f7e659-6dcd-4108-87f6-319ef97179a2', 'eb28aaec-1882-4abd-b48c-eab5b44c6b20', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f2f7e659-6dcd-4108-87f6-319ef97179a2', '536ff630-038e-495e-8963-8573486b70f5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('536ff630-038e-495e-8963-8573486b70f5', '180a3154-5305-431e-9383-0130c9892e02', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('536ff630-038e-495e-8963-8573486b70f5', 'bc56a01f-32e8-4301-8efe-9602b1f93588', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('536ff630-038e-495e-8963-8573486b70f5', '483ebe12-2e2a-41aa-9728-3544429a3284', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('536ff630-038e-495e-8963-8573486b70f5', 'eb28aaec-1882-4abd-b48c-eab5b44c6b20', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('536ff630-038e-495e-8963-8573486b70f5', 'f2f7e659-6dcd-4108-87f6-319ef97179a2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22b62338-8fa6-4f40-b991-bb957cd149a7', '180a3154-5305-431e-9383-0130c9892e02', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22b62338-8fa6-4f40-b991-bb957cd149a7', 'bc56a01f-32e8-4301-8efe-9602b1f93588', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22b62338-8fa6-4f40-b991-bb957cd149a7', '483ebe12-2e2a-41aa-9728-3544429a3284', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22b62338-8fa6-4f40-b991-bb957cd149a7', 'eb28aaec-1882-4abd-b48c-eab5b44c6b20', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22b62338-8fa6-4f40-b991-bb957cd149a7', 'f2f7e659-6dcd-4108-87f6-319ef97179a2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02afeb53-cbbd-480c-ab64-771d11425ffd', '180a3154-5305-431e-9383-0130c9892e02', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02afeb53-cbbd-480c-ab64-771d11425ffd', 'bc56a01f-32e8-4301-8efe-9602b1f93588', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02afeb53-cbbd-480c-ab64-771d11425ffd', '483ebe12-2e2a-41aa-9728-3544429a3284', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02afeb53-cbbd-480c-ab64-771d11425ffd', 'eb28aaec-1882-4abd-b48c-eab5b44c6b20', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02afeb53-cbbd-480c-ab64-771d11425ffd', 'f2f7e659-6dcd-4108-87f6-319ef97179a2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('42c6fc2c-f841-4f7a-b793-e834e42eced0', '180a3154-5305-431e-9383-0130c9892e02', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('42c6fc2c-f841-4f7a-b793-e834e42eced0', 'bc56a01f-32e8-4301-8efe-9602b1f93588', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('42c6fc2c-f841-4f7a-b793-e834e42eced0', '483ebe12-2e2a-41aa-9728-3544429a3284', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('42c6fc2c-f841-4f7a-b793-e834e42eced0', 'eb28aaec-1882-4abd-b48c-eab5b44c6b20', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('42c6fc2c-f841-4f7a-b793-e834e42eced0', 'f2f7e659-6dcd-4108-87f6-319ef97179a2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('55e15556-f52c-44a9-bbae-b8b531ebacea', '180a3154-5305-431e-9383-0130c9892e02', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('55e15556-f52c-44a9-bbae-b8b531ebacea', 'bc56a01f-32e8-4301-8efe-9602b1f93588', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('55e15556-f52c-44a9-bbae-b8b531ebacea', '483ebe12-2e2a-41aa-9728-3544429a3284', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('55e15556-f52c-44a9-bbae-b8b531ebacea', 'eb28aaec-1882-4abd-b48c-eab5b44c6b20', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('55e15556-f52c-44a9-bbae-b8b531ebacea', 'f2f7e659-6dcd-4108-87f6-319ef97179a2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22e0dcf0-4dab-4605-8747-63f114c92c64', '71599ffa-aa11-4612-9a5d-5365e475ce55', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22e0dcf0-4dab-4605-8747-63f114c92c64', '701923a2-f904-4e13-85a5-71bf7b730c93', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22e0dcf0-4dab-4605-8747-63f114c92c64', '49b1eb5c-277a-4a56-a00b-2d58d1767ebd', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22e0dcf0-4dab-4605-8747-63f114c92c64', '180a3154-5305-431e-9383-0130c9892e02', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22e0dcf0-4dab-4605-8747-63f114c92c64', 'bc56a01f-32e8-4301-8efe-9602b1f93588', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('04b1f17d-62e3-48f6-b7db-41bb71368171', '0b3fab2a-a212-4d5c-8a1f-8ad2e662e2d6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('04b1f17d-62e3-48f6-b7db-41bb71368171', '9034a4b4-4f66-488e-a48b-e0dafd48bf86', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('04b1f17d-62e3-48f6-b7db-41bb71368171', '8b7cdab9-c5f1-4e3c-9538-45203b3151dd', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('04b1f17d-62e3-48f6-b7db-41bb71368171', '74ff5a37-6aec-4751-ae60-e0398c9f8125', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('04b1f17d-62e3-48f6-b7db-41bb71368171', 'e3684943-77ae-473f-b723-3244e487c3c4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0b3fab2a-a212-4d5c-8a1f-8ad2e662e2d6', '04b1f17d-62e3-48f6-b7db-41bb71368171', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0b3fab2a-a212-4d5c-8a1f-8ad2e662e2d6', '9034a4b4-4f66-488e-a48b-e0dafd48bf86', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0b3fab2a-a212-4d5c-8a1f-8ad2e662e2d6', '8b7cdab9-c5f1-4e3c-9538-45203b3151dd', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0b3fab2a-a212-4d5c-8a1f-8ad2e662e2d6', '74ff5a37-6aec-4751-ae60-e0398c9f8125', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0b3fab2a-a212-4d5c-8a1f-8ad2e662e2d6', 'e3684943-77ae-473f-b723-3244e487c3c4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('08e0cf57-8a14-4257-8d94-5114e658e173', '0b3fab2a-a212-4d5c-8a1f-8ad2e662e2d6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('08e0cf57-8a14-4257-8d94-5114e658e173', '04b1f17d-62e3-48f6-b7db-41bb71368171', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('08e0cf57-8a14-4257-8d94-5114e658e173', '9034a4b4-4f66-488e-a48b-e0dafd48bf86', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('08e0cf57-8a14-4257-8d94-5114e658e173', '8b7cdab9-c5f1-4e3c-9538-45203b3151dd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('08e0cf57-8a14-4257-8d94-5114e658e173', '74ff5a37-6aec-4751-ae60-e0398c9f8125', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9034a4b4-4f66-488e-a48b-e0dafd48bf86', '06c2dc4e-fe90-45ae-802b-e40b2cafaed8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9034a4b4-4f66-488e-a48b-e0dafd48bf86', 'fb5ba96d-f5fd-47cb-adac-ba93e4909681', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9034a4b4-4f66-488e-a48b-e0dafd48bf86', 'b10b7f00-635c-47b9-a3e0-7ab004eb8e42', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9034a4b4-4f66-488e-a48b-e0dafd48bf86', '04b1f17d-62e3-48f6-b7db-41bb71368171', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9034a4b4-4f66-488e-a48b-e0dafd48bf86', '0b3fab2a-a212-4d5c-8a1f-8ad2e662e2d6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b7cdab9-c5f1-4e3c-9538-45203b3151dd', '74ff5a37-6aec-4751-ae60-e0398c9f8125', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b7cdab9-c5f1-4e3c-9538-45203b3151dd', 'e3684943-77ae-473f-b723-3244e487c3c4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b7cdab9-c5f1-4e3c-9538-45203b3151dd', '4279f4e9-eeb4-46a4-8034-05e50b9c6151', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b7cdab9-c5f1-4e3c-9538-45203b3151dd', 'd943e419-2750-464f-9060-76995563cf9f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b7cdab9-c5f1-4e3c-9538-45203b3151dd', '04b1f17d-62e3-48f6-b7db-41bb71368171', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('74ff5a37-6aec-4751-ae60-e0398c9f8125', '8b7cdab9-c5f1-4e3c-9538-45203b3151dd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('74ff5a37-6aec-4751-ae60-e0398c9f8125', 'e3684943-77ae-473f-b723-3244e487c3c4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('74ff5a37-6aec-4751-ae60-e0398c9f8125', '4279f4e9-eeb4-46a4-8034-05e50b9c6151', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('74ff5a37-6aec-4751-ae60-e0398c9f8125', 'd943e419-2750-464f-9060-76995563cf9f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('74ff5a37-6aec-4751-ae60-e0398c9f8125', '04b1f17d-62e3-48f6-b7db-41bb71368171', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3684943-77ae-473f-b723-3244e487c3c4', '8b7cdab9-c5f1-4e3c-9538-45203b3151dd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3684943-77ae-473f-b723-3244e487c3c4', '74ff5a37-6aec-4751-ae60-e0398c9f8125', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3684943-77ae-473f-b723-3244e487c3c4', '4279f4e9-eeb4-46a4-8034-05e50b9c6151', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3684943-77ae-473f-b723-3244e487c3c4', 'd943e419-2750-464f-9060-76995563cf9f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3684943-77ae-473f-b723-3244e487c3c4', '04b1f17d-62e3-48f6-b7db-41bb71368171', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('06c2dc4e-fe90-45ae-802b-e40b2cafaed8', '9034a4b4-4f66-488e-a48b-e0dafd48bf86', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('06c2dc4e-fe90-45ae-802b-e40b2cafaed8', 'fb5ba96d-f5fd-47cb-adac-ba93e4909681', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('06c2dc4e-fe90-45ae-802b-e40b2cafaed8', 'b10b7f00-635c-47b9-a3e0-7ab004eb8e42', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('06c2dc4e-fe90-45ae-802b-e40b2cafaed8', '04b1f17d-62e3-48f6-b7db-41bb71368171', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('06c2dc4e-fe90-45ae-802b-e40b2cafaed8', '0b3fab2a-a212-4d5c-8a1f-8ad2e662e2d6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fb5ba96d-f5fd-47cb-adac-ba93e4909681', '9034a4b4-4f66-488e-a48b-e0dafd48bf86', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fb5ba96d-f5fd-47cb-adac-ba93e4909681', '06c2dc4e-fe90-45ae-802b-e40b2cafaed8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fb5ba96d-f5fd-47cb-adac-ba93e4909681', 'b10b7f00-635c-47b9-a3e0-7ab004eb8e42', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fb5ba96d-f5fd-47cb-adac-ba93e4909681', '04b1f17d-62e3-48f6-b7db-41bb71368171', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fb5ba96d-f5fd-47cb-adac-ba93e4909681', '0b3fab2a-a212-4d5c-8a1f-8ad2e662e2d6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4279f4e9-eeb4-46a4-8034-05e50b9c6151', '8b7cdab9-c5f1-4e3c-9538-45203b3151dd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4279f4e9-eeb4-46a4-8034-05e50b9c6151', '74ff5a37-6aec-4751-ae60-e0398c9f8125', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4279f4e9-eeb4-46a4-8034-05e50b9c6151', 'e3684943-77ae-473f-b723-3244e487c3c4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4279f4e9-eeb4-46a4-8034-05e50b9c6151', 'd943e419-2750-464f-9060-76995563cf9f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4279f4e9-eeb4-46a4-8034-05e50b9c6151', '04b1f17d-62e3-48f6-b7db-41bb71368171', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d943e419-2750-464f-9060-76995563cf9f', '8b7cdab9-c5f1-4e3c-9538-45203b3151dd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d943e419-2750-464f-9060-76995563cf9f', '74ff5a37-6aec-4751-ae60-e0398c9f8125', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d943e419-2750-464f-9060-76995563cf9f', 'e3684943-77ae-473f-b723-3244e487c3c4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d943e419-2750-464f-9060-76995563cf9f', '4279f4e9-eeb4-46a4-8034-05e50b9c6151', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d943e419-2750-464f-9060-76995563cf9f', '04b1f17d-62e3-48f6-b7db-41bb71368171', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b10b7f00-635c-47b9-a3e0-7ab004eb8e42', '9034a4b4-4f66-488e-a48b-e0dafd48bf86', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b10b7f00-635c-47b9-a3e0-7ab004eb8e42', '06c2dc4e-fe90-45ae-802b-e40b2cafaed8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b10b7f00-635c-47b9-a3e0-7ab004eb8e42', 'fb5ba96d-f5fd-47cb-adac-ba93e4909681', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b10b7f00-635c-47b9-a3e0-7ab004eb8e42', '04b1f17d-62e3-48f6-b7db-41bb71368171', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b10b7f00-635c-47b9-a3e0-7ab004eb8e42', '0b3fab2a-a212-4d5c-8a1f-8ad2e662e2d6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9042e5f2-dd20-43f0-81be-9eec7a4159a9', '180a3154-5305-431e-9383-0130c9892e02', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9042e5f2-dd20-43f0-81be-9eec7a4159a9', 'bc56a01f-32e8-4301-8efe-9602b1f93588', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9042e5f2-dd20-43f0-81be-9eec7a4159a9', '483ebe12-2e2a-41aa-9728-3544429a3284', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9042e5f2-dd20-43f0-81be-9eec7a4159a9', 'eb28aaec-1882-4abd-b48c-eab5b44c6b20', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9042e5f2-dd20-43f0-81be-9eec7a4159a9', 'f2f7e659-6dcd-4108-87f6-319ef97179a2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4effe73f-1589-4caf-abad-0ed6b2268138', '71599ffa-aa11-4612-9a5d-5365e475ce55', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4effe73f-1589-4caf-abad-0ed6b2268138', '701923a2-f904-4e13-85a5-71bf7b730c93', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4effe73f-1589-4caf-abad-0ed6b2268138', '49b1eb5c-277a-4a56-a00b-2d58d1767ebd', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('af18468b-95f5-4c70-9a3d-cc537e2e1922', '31c93718-5124-4722-abdf-6b6600c68d36', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('af18468b-95f5-4c70-9a3d-cc537e2e1922', 'cd4c786e-11e4-4a20-a8f9-74f87c01c965', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('af18468b-95f5-4c70-9a3d-cc537e2e1922', 'f09aaea7-470e-4bf9-82af-38c472620dc0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('31c93718-5124-4722-abdf-6b6600c68d36', 'af18468b-95f5-4c70-9a3d-cc537e2e1922', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('31c93718-5124-4722-abdf-6b6600c68d36', 'cd4c786e-11e4-4a20-a8f9-74f87c01c965', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('31c93718-5124-4722-abdf-6b6600c68d36', 'f09aaea7-470e-4bf9-82af-38c472620dc0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd4c786e-11e4-4a20-a8f9-74f87c01c965', 'af18468b-95f5-4c70-9a3d-cc537e2e1922', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd4c786e-11e4-4a20-a8f9-74f87c01c965', '31c93718-5124-4722-abdf-6b6600c68d36', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd4c786e-11e4-4a20-a8f9-74f87c01c965', 'f09aaea7-470e-4bf9-82af-38c472620dc0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f09aaea7-470e-4bf9-82af-38c472620dc0', 'af18468b-95f5-4c70-9a3d-cc537e2e1922', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f09aaea7-470e-4bf9-82af-38c472620dc0', '31c93718-5124-4722-abdf-6b6600c68d36', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f09aaea7-470e-4bf9-82af-38c472620dc0', 'cd4c786e-11e4-4a20-a8f9-74f87c01c965', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dab44a49-11b3-4f9c-81a9-a8bfedc08584', 'f4f64aa2-10eb-4085-82d4-7625b01bfe16', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dab44a49-11b3-4f9c-81a9-a8bfedc08584', '0dbbb938-944c-4a08-bbd6-913fc5d645bf', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dab44a49-11b3-4f9c-81a9-a8bfedc08584', '69a41f89-3c78-4d3c-8dae-71ea8b12e4e3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dab44a49-11b3-4f9c-81a9-a8bfedc08584', '947503d5-7ee5-4e65-bda2-95da245e442f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dab44a49-11b3-4f9c-81a9-a8bfedc08584', '7ce85f68-e073-4ba1-9a55-7b9d2a21fc9d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f4f64aa2-10eb-4085-82d4-7625b01bfe16', 'dab44a49-11b3-4f9c-81a9-a8bfedc08584', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f4f64aa2-10eb-4085-82d4-7625b01bfe16', '0dbbb938-944c-4a08-bbd6-913fc5d645bf', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f4f64aa2-10eb-4085-82d4-7625b01bfe16', '69a41f89-3c78-4d3c-8dae-71ea8b12e4e3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f4f64aa2-10eb-4085-82d4-7625b01bfe16', '947503d5-7ee5-4e65-bda2-95da245e442f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f4f64aa2-10eb-4085-82d4-7625b01bfe16', '7ce85f68-e073-4ba1-9a55-7b9d2a21fc9d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0dbbb938-944c-4a08-bbd6-913fc5d645bf', 'dab44a49-11b3-4f9c-81a9-a8bfedc08584', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0dbbb938-944c-4a08-bbd6-913fc5d645bf', 'f4f64aa2-10eb-4085-82d4-7625b01bfe16', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0dbbb938-944c-4a08-bbd6-913fc5d645bf', '69a41f89-3c78-4d3c-8dae-71ea8b12e4e3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0dbbb938-944c-4a08-bbd6-913fc5d645bf', '947503d5-7ee5-4e65-bda2-95da245e442f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0dbbb938-944c-4a08-bbd6-913fc5d645bf', '7ce85f68-e073-4ba1-9a55-7b9d2a21fc9d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('69a41f89-3c78-4d3c-8dae-71ea8b12e4e3', 'dab44a49-11b3-4f9c-81a9-a8bfedc08584', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('69a41f89-3c78-4d3c-8dae-71ea8b12e4e3', 'f4f64aa2-10eb-4085-82d4-7625b01bfe16', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('69a41f89-3c78-4d3c-8dae-71ea8b12e4e3', '0dbbb938-944c-4a08-bbd6-913fc5d645bf', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('69a41f89-3c78-4d3c-8dae-71ea8b12e4e3', '947503d5-7ee5-4e65-bda2-95da245e442f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('69a41f89-3c78-4d3c-8dae-71ea8b12e4e3', '7ce85f68-e073-4ba1-9a55-7b9d2a21fc9d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f32d2e2c-3024-4ec8-a989-9b7020735c8f', '5da87d7a-9a8f-462c-a644-bc8330395f64', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f32d2e2c-3024-4ec8-a989-9b7020735c8f', 'dab44a49-11b3-4f9c-81a9-a8bfedc08584', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f32d2e2c-3024-4ec8-a989-9b7020735c8f', 'f4f64aa2-10eb-4085-82d4-7625b01bfe16', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f32d2e2c-3024-4ec8-a989-9b7020735c8f', '0dbbb938-944c-4a08-bbd6-913fc5d645bf', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f32d2e2c-3024-4ec8-a989-9b7020735c8f', '69a41f89-3c78-4d3c-8dae-71ea8b12e4e3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5da87d7a-9a8f-462c-a644-bc8330395f64', 'f32d2e2c-3024-4ec8-a989-9b7020735c8f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5da87d7a-9a8f-462c-a644-bc8330395f64', 'dab44a49-11b3-4f9c-81a9-a8bfedc08584', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5da87d7a-9a8f-462c-a644-bc8330395f64', 'f4f64aa2-10eb-4085-82d4-7625b01bfe16', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5da87d7a-9a8f-462c-a644-bc8330395f64', '0dbbb938-944c-4a08-bbd6-913fc5d645bf', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5da87d7a-9a8f-462c-a644-bc8330395f64', '69a41f89-3c78-4d3c-8dae-71ea8b12e4e3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('947503d5-7ee5-4e65-bda2-95da245e442f', 'dab44a49-11b3-4f9c-81a9-a8bfedc08584', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('947503d5-7ee5-4e65-bda2-95da245e442f', 'f4f64aa2-10eb-4085-82d4-7625b01bfe16', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('947503d5-7ee5-4e65-bda2-95da245e442f', '0dbbb938-944c-4a08-bbd6-913fc5d645bf', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('947503d5-7ee5-4e65-bda2-95da245e442f', '69a41f89-3c78-4d3c-8dae-71ea8b12e4e3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('947503d5-7ee5-4e65-bda2-95da245e442f', '7ce85f68-e073-4ba1-9a55-7b9d2a21fc9d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7ce85f68-e073-4ba1-9a55-7b9d2a21fc9d', 'dab44a49-11b3-4f9c-81a9-a8bfedc08584', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7ce85f68-e073-4ba1-9a55-7b9d2a21fc9d', 'f4f64aa2-10eb-4085-82d4-7625b01bfe16', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7ce85f68-e073-4ba1-9a55-7b9d2a21fc9d', '0dbbb938-944c-4a08-bbd6-913fc5d645bf', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7ce85f68-e073-4ba1-9a55-7b9d2a21fc9d', '69a41f89-3c78-4d3c-8dae-71ea8b12e4e3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7ce85f68-e073-4ba1-9a55-7b9d2a21fc9d', '947503d5-7ee5-4e65-bda2-95da245e442f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('61654c86-e577-4d7d-991a-26caae263394', '67320027-4a8f-413a-ab9c-bbe449651dbc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('61654c86-e577-4d7d-991a-26caae263394', 'af18468b-95f5-4c70-9a3d-cc537e2e1922', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('61654c86-e577-4d7d-991a-26caae263394', '31c93718-5124-4722-abdf-6b6600c68d36', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('208d32d9-3496-45de-8d2b-fa91f2764671', 'dab44a49-11b3-4f9c-81a9-a8bfedc08584', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('208d32d9-3496-45de-8d2b-fa91f2764671', 'f4f64aa2-10eb-4085-82d4-7625b01bfe16', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('208d32d9-3496-45de-8d2b-fa91f2764671', '0dbbb938-944c-4a08-bbd6-913fc5d645bf', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('208d32d9-3496-45de-8d2b-fa91f2764671', '69a41f89-3c78-4d3c-8dae-71ea8b12e4e3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('208d32d9-3496-45de-8d2b-fa91f2764671', 'f32d2e2c-3024-4ec8-a989-9b7020735c8f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0454584e-ffb8-4d6a-990c-7139c980739b', '67320027-4a8f-413a-ab9c-bbe449651dbc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0454584e-ffb8-4d6a-990c-7139c980739b', 'af18468b-95f5-4c70-9a3d-cc537e2e1922', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0454584e-ffb8-4d6a-990c-7139c980739b', '31c93718-5124-4722-abdf-6b6600c68d36', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6fc8b00d-eb31-4f74-9da2-8e80ce1ccc06', '206192a0-731a-4a9d-b7e6-80b36a9c21af', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6fc8b00d-eb31-4f74-9da2-8e80ce1ccc06', '42e1af6e-0376-46b7-b9b7-3fbfa213d530', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6fc8b00d-eb31-4f74-9da2-8e80ce1ccc06', '8fe023f2-cf9d-41e9-92e6-9ba25701b872', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6fc8b00d-eb31-4f74-9da2-8e80ce1ccc06', '4b03ea2a-dc70-42c2-86a1-3432c4582da4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6fc8b00d-eb31-4f74-9da2-8e80ce1ccc06', '80d43dcc-1757-451e-92cc-ea0050dcfe19', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('06476e58-1cda-4785-9e6f-2b8239f4c16a', '7d7a0b3a-6c68-40d4-9b37-0c8e7ada7905', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('06476e58-1cda-4785-9e6f-2b8239f4c16a', '6fc8b00d-eb31-4f74-9da2-8e80ce1ccc06', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('06476e58-1cda-4785-9e6f-2b8239f4c16a', '206192a0-731a-4a9d-b7e6-80b36a9c21af', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('06476e58-1cda-4785-9e6f-2b8239f4c16a', '42e1af6e-0376-46b7-b9b7-3fbfa213d530', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('06476e58-1cda-4785-9e6f-2b8239f4c16a', '8fe023f2-cf9d-41e9-92e6-9ba25701b872', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('206192a0-731a-4a9d-b7e6-80b36a9c21af', '6fc8b00d-eb31-4f74-9da2-8e80ce1ccc06', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('206192a0-731a-4a9d-b7e6-80b36a9c21af', '42e1af6e-0376-46b7-b9b7-3fbfa213d530', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('206192a0-731a-4a9d-b7e6-80b36a9c21af', '8fe023f2-cf9d-41e9-92e6-9ba25701b872', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('206192a0-731a-4a9d-b7e6-80b36a9c21af', '4b03ea2a-dc70-42c2-86a1-3432c4582da4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('206192a0-731a-4a9d-b7e6-80b36a9c21af', '80d43dcc-1757-451e-92cc-ea0050dcfe19', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('42e1af6e-0376-46b7-b9b7-3fbfa213d530', '6fc8b00d-eb31-4f74-9da2-8e80ce1ccc06', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('42e1af6e-0376-46b7-b9b7-3fbfa213d530', '206192a0-731a-4a9d-b7e6-80b36a9c21af', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('42e1af6e-0376-46b7-b9b7-3fbfa213d530', '8fe023f2-cf9d-41e9-92e6-9ba25701b872', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('42e1af6e-0376-46b7-b9b7-3fbfa213d530', '4b03ea2a-dc70-42c2-86a1-3432c4582da4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('42e1af6e-0376-46b7-b9b7-3fbfa213d530', '80d43dcc-1757-451e-92cc-ea0050dcfe19', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8fe023f2-cf9d-41e9-92e6-9ba25701b872', '6fc8b00d-eb31-4f74-9da2-8e80ce1ccc06', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8fe023f2-cf9d-41e9-92e6-9ba25701b872', '206192a0-731a-4a9d-b7e6-80b36a9c21af', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8fe023f2-cf9d-41e9-92e6-9ba25701b872', '42e1af6e-0376-46b7-b9b7-3fbfa213d530', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8fe023f2-cf9d-41e9-92e6-9ba25701b872', '4b03ea2a-dc70-42c2-86a1-3432c4582da4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8fe023f2-cf9d-41e9-92e6-9ba25701b872', '80d43dcc-1757-451e-92cc-ea0050dcfe19', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b03ea2a-dc70-42c2-86a1-3432c4582da4', '6fc8b00d-eb31-4f74-9da2-8e80ce1ccc06', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b03ea2a-dc70-42c2-86a1-3432c4582da4', '206192a0-731a-4a9d-b7e6-80b36a9c21af', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b03ea2a-dc70-42c2-86a1-3432c4582da4', '42e1af6e-0376-46b7-b9b7-3fbfa213d530', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b03ea2a-dc70-42c2-86a1-3432c4582da4', '8fe023f2-cf9d-41e9-92e6-9ba25701b872', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b03ea2a-dc70-42c2-86a1-3432c4582da4', '80d43dcc-1757-451e-92cc-ea0050dcfe19', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('80d43dcc-1757-451e-92cc-ea0050dcfe19', '6fc8b00d-eb31-4f74-9da2-8e80ce1ccc06', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('80d43dcc-1757-451e-92cc-ea0050dcfe19', '206192a0-731a-4a9d-b7e6-80b36a9c21af', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('80d43dcc-1757-451e-92cc-ea0050dcfe19', '42e1af6e-0376-46b7-b9b7-3fbfa213d530', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('80d43dcc-1757-451e-92cc-ea0050dcfe19', '8fe023f2-cf9d-41e9-92e6-9ba25701b872', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('80d43dcc-1757-451e-92cc-ea0050dcfe19', '4b03ea2a-dc70-42c2-86a1-3432c4582da4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6fdbae69-3ffb-4113-8730-299480e78762', '27b72689-3558-4d2e-b3e6-79628acbd292', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6fdbae69-3ffb-4113-8730-299480e78762', '6fc8b00d-eb31-4f74-9da2-8e80ce1ccc06', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6fdbae69-3ffb-4113-8730-299480e78762', '06476e58-1cda-4785-9e6f-2b8239f4c16a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6fdbae69-3ffb-4113-8730-299480e78762', '206192a0-731a-4a9d-b7e6-80b36a9c21af', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6fdbae69-3ffb-4113-8730-299480e78762', '42e1af6e-0376-46b7-b9b7-3fbfa213d530', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('27b72689-3558-4d2e-b3e6-79628acbd292', '6fdbae69-3ffb-4113-8730-299480e78762', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('27b72689-3558-4d2e-b3e6-79628acbd292', '6fc8b00d-eb31-4f74-9da2-8e80ce1ccc06', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('27b72689-3558-4d2e-b3e6-79628acbd292', '06476e58-1cda-4785-9e6f-2b8239f4c16a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('27b72689-3558-4d2e-b3e6-79628acbd292', '206192a0-731a-4a9d-b7e6-80b36a9c21af', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('27b72689-3558-4d2e-b3e6-79628acbd292', '42e1af6e-0376-46b7-b9b7-3fbfa213d530', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a56fda52-55e5-40b3-933b-12ce2e9753bc', '6fc8b00d-eb31-4f74-9da2-8e80ce1ccc06', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a56fda52-55e5-40b3-933b-12ce2e9753bc', '206192a0-731a-4a9d-b7e6-80b36a9c21af', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a56fda52-55e5-40b3-933b-12ce2e9753bc', '42e1af6e-0376-46b7-b9b7-3fbfa213d530', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a56fda52-55e5-40b3-933b-12ce2e9753bc', '8fe023f2-cf9d-41e9-92e6-9ba25701b872', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a56fda52-55e5-40b3-933b-12ce2e9753bc', '4b03ea2a-dc70-42c2-86a1-3432c4582da4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('529924c4-5937-4bce-bfa5-7fbdc343e04c', '6fc8b00d-eb31-4f74-9da2-8e80ce1ccc06', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('529924c4-5937-4bce-bfa5-7fbdc343e04c', '206192a0-731a-4a9d-b7e6-80b36a9c21af', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('529924c4-5937-4bce-bfa5-7fbdc343e04c', '42e1af6e-0376-46b7-b9b7-3fbfa213d530', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('529924c4-5937-4bce-bfa5-7fbdc343e04c', '8fe023f2-cf9d-41e9-92e6-9ba25701b872', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('529924c4-5937-4bce-bfa5-7fbdc343e04c', '4b03ea2a-dc70-42c2-86a1-3432c4582da4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7d7a0b3a-6c68-40d4-9b37-0c8e7ada7905', '06476e58-1cda-4785-9e6f-2b8239f4c16a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7d7a0b3a-6c68-40d4-9b37-0c8e7ada7905', '6fc8b00d-eb31-4f74-9da2-8e80ce1ccc06', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7d7a0b3a-6c68-40d4-9b37-0c8e7ada7905', '206192a0-731a-4a9d-b7e6-80b36a9c21af', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7d7a0b3a-6c68-40d4-9b37-0c8e7ada7905', '42e1af6e-0376-46b7-b9b7-3fbfa213d530', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7d7a0b3a-6c68-40d4-9b37-0c8e7ada7905', '8fe023f2-cf9d-41e9-92e6-9ba25701b872', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b2def094-91be-474f-a709-72c2f6942185', '6fc8b00d-eb31-4f74-9da2-8e80ce1ccc06', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b2def094-91be-474f-a709-72c2f6942185', '206192a0-731a-4a9d-b7e6-80b36a9c21af', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b2def094-91be-474f-a709-72c2f6942185', '42e1af6e-0376-46b7-b9b7-3fbfa213d530', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b2def094-91be-474f-a709-72c2f6942185', '8fe023f2-cf9d-41e9-92e6-9ba25701b872', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b2def094-91be-474f-a709-72c2f6942185', '4b03ea2a-dc70-42c2-86a1-3432c4582da4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1350a6b2-f41a-4b06-9d5a-cb344d588a3a', '1fc9ea9b-3ca4-48d2-986f-7ba96cae82f1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1350a6b2-f41a-4b06-9d5a-cb344d588a3a', '9a6b732b-15e1-4140-9a4f-03157c64cfea', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1350a6b2-f41a-4b06-9d5a-cb344d588a3a', '02f38701-35ec-46b7-90cc-f7b1691922cf', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1350a6b2-f41a-4b06-9d5a-cb344d588a3a', 'be793665-3290-469a-b2db-0b78f733dd25', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1350a6b2-f41a-4b06-9d5a-cb344d588a3a', 'aaa2830f-d3dc-436f-84d0-7b40b4eed07f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9a6b732b-15e1-4140-9a4f-03157c64cfea', '1350a6b2-f41a-4b06-9d5a-cb344d588a3a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9a6b732b-15e1-4140-9a4f-03157c64cfea', '02f38701-35ec-46b7-90cc-f7b1691922cf', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9a6b732b-15e1-4140-9a4f-03157c64cfea', 'be793665-3290-469a-b2db-0b78f733dd25', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9a6b732b-15e1-4140-9a4f-03157c64cfea', 'aaa2830f-d3dc-436f-84d0-7b40b4eed07f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9a6b732b-15e1-4140-9a4f-03157c64cfea', '921a6510-0274-47cf-8f37-d28b70da9c47', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02f38701-35ec-46b7-90cc-f7b1691922cf', '1350a6b2-f41a-4b06-9d5a-cb344d588a3a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02f38701-35ec-46b7-90cc-f7b1691922cf', '9a6b732b-15e1-4140-9a4f-03157c64cfea', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02f38701-35ec-46b7-90cc-f7b1691922cf', 'be793665-3290-469a-b2db-0b78f733dd25', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02f38701-35ec-46b7-90cc-f7b1691922cf', 'aaa2830f-d3dc-436f-84d0-7b40b4eed07f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02f38701-35ec-46b7-90cc-f7b1691922cf', '921a6510-0274-47cf-8f37-d28b70da9c47', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('be793665-3290-469a-b2db-0b78f733dd25', 'aaa2830f-d3dc-436f-84d0-7b40b4eed07f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('be793665-3290-469a-b2db-0b78f733dd25', '921a6510-0274-47cf-8f37-d28b70da9c47', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('be793665-3290-469a-b2db-0b78f733dd25', 'c442431d-0b47-49af-ae99-9f67a6b2dec3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('be793665-3290-469a-b2db-0b78f733dd25', '1350a6b2-f41a-4b06-9d5a-cb344d588a3a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('be793665-3290-469a-b2db-0b78f733dd25', '9a6b732b-15e1-4140-9a4f-03157c64cfea', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aaa2830f-d3dc-436f-84d0-7b40b4eed07f', 'be793665-3290-469a-b2db-0b78f733dd25', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aaa2830f-d3dc-436f-84d0-7b40b4eed07f', '921a6510-0274-47cf-8f37-d28b70da9c47', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aaa2830f-d3dc-436f-84d0-7b40b4eed07f', 'c442431d-0b47-49af-ae99-9f67a6b2dec3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aaa2830f-d3dc-436f-84d0-7b40b4eed07f', '1350a6b2-f41a-4b06-9d5a-cb344d588a3a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aaa2830f-d3dc-436f-84d0-7b40b4eed07f', '9a6b732b-15e1-4140-9a4f-03157c64cfea', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('921a6510-0274-47cf-8f37-d28b70da9c47', 'be793665-3290-469a-b2db-0b78f733dd25', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('921a6510-0274-47cf-8f37-d28b70da9c47', 'aaa2830f-d3dc-436f-84d0-7b40b4eed07f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('921a6510-0274-47cf-8f37-d28b70da9c47', 'c442431d-0b47-49af-ae99-9f67a6b2dec3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('921a6510-0274-47cf-8f37-d28b70da9c47', '1350a6b2-f41a-4b06-9d5a-cb344d588a3a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('921a6510-0274-47cf-8f37-d28b70da9c47', '9a6b732b-15e1-4140-9a4f-03157c64cfea', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c442431d-0b47-49af-ae99-9f67a6b2dec3', 'be793665-3290-469a-b2db-0b78f733dd25', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c442431d-0b47-49af-ae99-9f67a6b2dec3', 'aaa2830f-d3dc-436f-84d0-7b40b4eed07f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c442431d-0b47-49af-ae99-9f67a6b2dec3', '921a6510-0274-47cf-8f37-d28b70da9c47', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c442431d-0b47-49af-ae99-9f67a6b2dec3', '1350a6b2-f41a-4b06-9d5a-cb344d588a3a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c442431d-0b47-49af-ae99-9f67a6b2dec3', '9a6b732b-15e1-4140-9a4f-03157c64cfea', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1fc9ea9b-3ca4-48d2-986f-7ba96cae82f1', '1350a6b2-f41a-4b06-9d5a-cb344d588a3a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1fc9ea9b-3ca4-48d2-986f-7ba96cae82f1', '9a6b732b-15e1-4140-9a4f-03157c64cfea', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1fc9ea9b-3ca4-48d2-986f-7ba96cae82f1', '02f38701-35ec-46b7-90cc-f7b1691922cf', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1fc9ea9b-3ca4-48d2-986f-7ba96cae82f1', 'be793665-3290-469a-b2db-0b78f733dd25', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1fc9ea9b-3ca4-48d2-986f-7ba96cae82f1', 'aaa2830f-d3dc-436f-84d0-7b40b4eed07f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e9f19799-b1d8-4d24-b6b5-e2b49e7e771d', '1350a6b2-f41a-4b06-9d5a-cb344d588a3a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e9f19799-b1d8-4d24-b6b5-e2b49e7e771d', '9a6b732b-15e1-4140-9a4f-03157c64cfea', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e9f19799-b1d8-4d24-b6b5-e2b49e7e771d', '02f38701-35ec-46b7-90cc-f7b1691922cf', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d2d4f1d-0279-48f6-a361-3ae954de7454', '1350a6b2-f41a-4b06-9d5a-cb344d588a3a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d2d4f1d-0279-48f6-a361-3ae954de7454', '9a6b732b-15e1-4140-9a4f-03157c64cfea', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d2d4f1d-0279-48f6-a361-3ae954de7454', '02f38701-35ec-46b7-90cc-f7b1691922cf', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d2d4f1d-0279-48f6-a361-3ae954de7454', 'be793665-3290-469a-b2db-0b78f733dd25', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d2d4f1d-0279-48f6-a361-3ae954de7454', 'aaa2830f-d3dc-436f-84d0-7b40b4eed07f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('018e36db-52a4-4750-bd0c-52934c85ca3a', '8941368f-4e42-4fdf-a32a-ad0fe08c6c23', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('018e36db-52a4-4750-bd0c-52934c85ca3a', '6b598360-36d2-4190-971b-c4eb8a70af30', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('018e36db-52a4-4750-bd0c-52934c85ca3a', '8de0a8a6-7e6b-4391-8f94-8e44f7b80244', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('018e36db-52a4-4750-bd0c-52934c85ca3a', 'b367a6e4-b294-4d37-9ef3-cf70ddad85f3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('018e36db-52a4-4750-bd0c-52934c85ca3a', '708b8d39-ec51-4edc-973e-b5af0a958931', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('734d3fe1-4228-4c26-8d3c-1736cf51548b', '018e36db-52a4-4750-bd0c-52934c85ca3a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('734d3fe1-4228-4c26-8d3c-1736cf51548b', '8941368f-4e42-4fdf-a32a-ad0fe08c6c23', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('734d3fe1-4228-4c26-8d3c-1736cf51548b', '6b598360-36d2-4190-971b-c4eb8a70af30', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('734d3fe1-4228-4c26-8d3c-1736cf51548b', '8de0a8a6-7e6b-4391-8f94-8e44f7b80244', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('734d3fe1-4228-4c26-8d3c-1736cf51548b', 'b367a6e4-b294-4d37-9ef3-cf70ddad85f3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8941368f-4e42-4fdf-a32a-ad0fe08c6c23', '018e36db-52a4-4750-bd0c-52934c85ca3a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8941368f-4e42-4fdf-a32a-ad0fe08c6c23', '6b598360-36d2-4190-971b-c4eb8a70af30', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8941368f-4e42-4fdf-a32a-ad0fe08c6c23', '8de0a8a6-7e6b-4391-8f94-8e44f7b80244', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8941368f-4e42-4fdf-a32a-ad0fe08c6c23', 'b367a6e4-b294-4d37-9ef3-cf70ddad85f3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8941368f-4e42-4fdf-a32a-ad0fe08c6c23', '708b8d39-ec51-4edc-973e-b5af0a958931', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8de0a8a6-7e6b-4391-8f94-8e44f7b80244', '018e36db-52a4-4750-bd0c-52934c85ca3a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8de0a8a6-7e6b-4391-8f94-8e44f7b80244', '8941368f-4e42-4fdf-a32a-ad0fe08c6c23', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8de0a8a6-7e6b-4391-8f94-8e44f7b80244', 'b367a6e4-b294-4d37-9ef3-cf70ddad85f3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8de0a8a6-7e6b-4391-8f94-8e44f7b80244', '6b598360-36d2-4190-971b-c4eb8a70af30', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8de0a8a6-7e6b-4391-8f94-8e44f7b80244', '708b8d39-ec51-4edc-973e-b5af0a958931', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b367a6e4-b294-4d37-9ef3-cf70ddad85f3', '018e36db-52a4-4750-bd0c-52934c85ca3a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b367a6e4-b294-4d37-9ef3-cf70ddad85f3', '8941368f-4e42-4fdf-a32a-ad0fe08c6c23', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b367a6e4-b294-4d37-9ef3-cf70ddad85f3', '8de0a8a6-7e6b-4391-8f94-8e44f7b80244', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b367a6e4-b294-4d37-9ef3-cf70ddad85f3', '6b598360-36d2-4190-971b-c4eb8a70af30', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b367a6e4-b294-4d37-9ef3-cf70ddad85f3', '708b8d39-ec51-4edc-973e-b5af0a958931', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ecb2f787-9325-46db-b237-34c1a3c58fa3', '018e36db-52a4-4750-bd0c-52934c85ca3a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ecb2f787-9325-46db-b237-34c1a3c58fa3', '8941368f-4e42-4fdf-a32a-ad0fe08c6c23', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ecb2f787-9325-46db-b237-34c1a3c58fa3', '8de0a8a6-7e6b-4391-8f94-8e44f7b80244', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b9b18de0-f1a6-426d-9f8b-589404866006', '018e36db-52a4-4750-bd0c-52934c85ca3a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b9b18de0-f1a6-426d-9f8b-589404866006', '8941368f-4e42-4fdf-a32a-ad0fe08c6c23', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b9b18de0-f1a6-426d-9f8b-589404866006', '8de0a8a6-7e6b-4391-8f94-8e44f7b80244', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('53d08c4a-f5ca-4121-b788-ecb71f74ed6f', '1404d67b-df55-4511-8c42-a8e3c4a1696e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('53d08c4a-f5ca-4121-b788-ecb71f74ed6f', 'dc44ca8e-2998-4483-906c-83b89d53ff32', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('53d08c4a-f5ca-4121-b788-ecb71f74ed6f', 'd493bef7-8391-4d91-be09-570fead186e0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('53d08c4a-f5ca-4121-b788-ecb71f74ed6f', '9dec7374-6d48-49bd-b9f0-523525cff255', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('53d08c4a-f5ca-4121-b788-ecb71f74ed6f', 'bcf616c3-7119-4bc3-9cef-890b2e0d691a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d493bef7-8391-4d91-be09-570fead186e0', 'bcf616c3-7119-4bc3-9cef-890b2e0d691a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d493bef7-8391-4d91-be09-570fead186e0', '53d08c4a-f5ca-4121-b788-ecb71f74ed6f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d493bef7-8391-4d91-be09-570fead186e0', '1404d67b-df55-4511-8c42-a8e3c4a1696e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d493bef7-8391-4d91-be09-570fead186e0', '9dec7374-6d48-49bd-b9f0-523525cff255', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d493bef7-8391-4d91-be09-570fead186e0', 'dc44ca8e-2998-4483-906c-83b89d53ff32', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1404d67b-df55-4511-8c42-a8e3c4a1696e', '53d08c4a-f5ca-4121-b788-ecb71f74ed6f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1404d67b-df55-4511-8c42-a8e3c4a1696e', 'dc44ca8e-2998-4483-906c-83b89d53ff32', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1404d67b-df55-4511-8c42-a8e3c4a1696e', 'd493bef7-8391-4d91-be09-570fead186e0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1404d67b-df55-4511-8c42-a8e3c4a1696e', '9dec7374-6d48-49bd-b9f0-523525cff255', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1404d67b-df55-4511-8c42-a8e3c4a1696e', 'bcf616c3-7119-4bc3-9cef-890b2e0d691a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9dec7374-6d48-49bd-b9f0-523525cff255', '53d08c4a-f5ca-4121-b788-ecb71f74ed6f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9dec7374-6d48-49bd-b9f0-523525cff255', 'd493bef7-8391-4d91-be09-570fead186e0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9dec7374-6d48-49bd-b9f0-523525cff255', '1404d67b-df55-4511-8c42-a8e3c4a1696e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9dec7374-6d48-49bd-b9f0-523525cff255', 'bcf616c3-7119-4bc3-9cef-890b2e0d691a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9dec7374-6d48-49bd-b9f0-523525cff255', 'dc44ca8e-2998-4483-906c-83b89d53ff32', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bcf616c3-7119-4bc3-9cef-890b2e0d691a', 'd493bef7-8391-4d91-be09-570fead186e0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bcf616c3-7119-4bc3-9cef-890b2e0d691a', '53d08c4a-f5ca-4121-b788-ecb71f74ed6f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bcf616c3-7119-4bc3-9cef-890b2e0d691a', '1404d67b-df55-4511-8c42-a8e3c4a1696e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bcf616c3-7119-4bc3-9cef-890b2e0d691a', '9dec7374-6d48-49bd-b9f0-523525cff255', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bcf616c3-7119-4bc3-9cef-890b2e0d691a', 'dc44ca8e-2998-4483-906c-83b89d53ff32', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4d24ff77-51bb-42b6-aec3-39c7f6efb7d4', '6a3d9b57-84cc-4e13-b860-0f5809cbf159', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4d24ff77-51bb-42b6-aec3-39c7f6efb7d4', '018e36db-52a4-4750-bd0c-52934c85ca3a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4d24ff77-51bb-42b6-aec3-39c7f6efb7d4', '8941368f-4e42-4fdf-a32a-ad0fe08c6c23', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6b598360-36d2-4190-971b-c4eb8a70af30', '018e36db-52a4-4750-bd0c-52934c85ca3a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6b598360-36d2-4190-971b-c4eb8a70af30', '8941368f-4e42-4fdf-a32a-ad0fe08c6c23', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6b598360-36d2-4190-971b-c4eb8a70af30', '8de0a8a6-7e6b-4391-8f94-8e44f7b80244', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6b598360-36d2-4190-971b-c4eb8a70af30', 'b367a6e4-b294-4d37-9ef3-cf70ddad85f3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6b598360-36d2-4190-971b-c4eb8a70af30', '708b8d39-ec51-4edc-973e-b5af0a958931', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('99b9832a-2cde-434f-85a9-5d8c81861977', '018e36db-52a4-4750-bd0c-52934c85ca3a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('99b9832a-2cde-434f-85a9-5d8c81861977', '8941368f-4e42-4fdf-a32a-ad0fe08c6c23', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('99b9832a-2cde-434f-85a9-5d8c81861977', '8de0a8a6-7e6b-4391-8f94-8e44f7b80244', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('708b8d39-ec51-4edc-973e-b5af0a958931', '018e36db-52a4-4750-bd0c-52934c85ca3a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('708b8d39-ec51-4edc-973e-b5af0a958931', '8941368f-4e42-4fdf-a32a-ad0fe08c6c23', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('708b8d39-ec51-4edc-973e-b5af0a958931', '8de0a8a6-7e6b-4391-8f94-8e44f7b80244', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('708b8d39-ec51-4edc-973e-b5af0a958931', 'b367a6e4-b294-4d37-9ef3-cf70ddad85f3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('708b8d39-ec51-4edc-973e-b5af0a958931', '6b598360-36d2-4190-971b-c4eb8a70af30', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6a3d9b57-84cc-4e13-b860-0f5809cbf159', '4d24ff77-51bb-42b6-aec3-39c7f6efb7d4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6a3d9b57-84cc-4e13-b860-0f5809cbf159', '018e36db-52a4-4750-bd0c-52934c85ca3a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6a3d9b57-84cc-4e13-b860-0f5809cbf159', '8941368f-4e42-4fdf-a32a-ad0fe08c6c23', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dc44ca8e-2998-4483-906c-83b89d53ff32', '53d08c4a-f5ca-4121-b788-ecb71f74ed6f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dc44ca8e-2998-4483-906c-83b89d53ff32', '1404d67b-df55-4511-8c42-a8e3c4a1696e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dc44ca8e-2998-4483-906c-83b89d53ff32', 'd493bef7-8391-4d91-be09-570fead186e0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dc44ca8e-2998-4483-906c-83b89d53ff32', '9dec7374-6d48-49bd-b9f0-523525cff255', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dc44ca8e-2998-4483-906c-83b89d53ff32', 'bcf616c3-7119-4bc3-9cef-890b2e0d691a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('35444f65-9a5f-480c-aa22-d4ef4389404c', 'c00a65d0-3339-468b-a45f-6090007fbcf0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('35444f65-9a5f-480c-aa22-d4ef4389404c', '865c97df-5262-4f88-bb3f-fd32dcbd2664', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('35444f65-9a5f-480c-aa22-d4ef4389404c', '018e36db-52a4-4750-bd0c-52934c85ca3a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c00a65d0-3339-468b-a45f-6090007fbcf0', '35444f65-9a5f-480c-aa22-d4ef4389404c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c00a65d0-3339-468b-a45f-6090007fbcf0', '865c97df-5262-4f88-bb3f-fd32dcbd2664', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c00a65d0-3339-468b-a45f-6090007fbcf0', '018e36db-52a4-4750-bd0c-52934c85ca3a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('865c97df-5262-4f88-bb3f-fd32dcbd2664', '35444f65-9a5f-480c-aa22-d4ef4389404c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('865c97df-5262-4f88-bb3f-fd32dcbd2664', 'c00a65d0-3339-468b-a45f-6090007fbcf0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('865c97df-5262-4f88-bb3f-fd32dcbd2664', '018e36db-52a4-4750-bd0c-52934c85ca3a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3ce5af9f-ffae-42ce-91fa-e6fb6320ccd3', 'c493249d-83de-49fb-a5c4-4e73b8674b3a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3ce5af9f-ffae-42ce-91fa-e6fb6320ccd3', '4aae3aa4-4383-4671-ac01-1fa47cf86b81', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3ce5af9f-ffae-42ce-91fa-e6fb6320ccd3', '0c308bce-10b0-4949-a1e0-185e78990783', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3ce5af9f-ffae-42ce-91fa-e6fb6320ccd3', '6d297801-54b7-4c12-9847-f9e0df64522c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c493249d-83de-49fb-a5c4-4e73b8674b3a', '3ce5af9f-ffae-42ce-91fa-e6fb6320ccd3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c493249d-83de-49fb-a5c4-4e73b8674b3a', '4aae3aa4-4383-4671-ac01-1fa47cf86b81', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c493249d-83de-49fb-a5c4-4e73b8674b3a', '0c308bce-10b0-4949-a1e0-185e78990783', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c493249d-83de-49fb-a5c4-4e73b8674b3a', '6d297801-54b7-4c12-9847-f9e0df64522c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4aae3aa4-4383-4671-ac01-1fa47cf86b81', '3ce5af9f-ffae-42ce-91fa-e6fb6320ccd3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4aae3aa4-4383-4671-ac01-1fa47cf86b81', 'c493249d-83de-49fb-a5c4-4e73b8674b3a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4aae3aa4-4383-4671-ac01-1fa47cf86b81', '0c308bce-10b0-4949-a1e0-185e78990783', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4aae3aa4-4383-4671-ac01-1fa47cf86b81', '6d297801-54b7-4c12-9847-f9e0df64522c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c308bce-10b0-4949-a1e0-185e78990783', '3ce5af9f-ffae-42ce-91fa-e6fb6320ccd3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c308bce-10b0-4949-a1e0-185e78990783', 'c493249d-83de-49fb-a5c4-4e73b8674b3a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c308bce-10b0-4949-a1e0-185e78990783', '4aae3aa4-4383-4671-ac01-1fa47cf86b81', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c308bce-10b0-4949-a1e0-185e78990783', '6d297801-54b7-4c12-9847-f9e0df64522c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6d297801-54b7-4c12-9847-f9e0df64522c', '3ce5af9f-ffae-42ce-91fa-e6fb6320ccd3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6d297801-54b7-4c12-9847-f9e0df64522c', 'c493249d-83de-49fb-a5c4-4e73b8674b3a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6d297801-54b7-4c12-9847-f9e0df64522c', '4aae3aa4-4383-4671-ac01-1fa47cf86b81', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6d297801-54b7-4c12-9847-f9e0df64522c', '0c308bce-10b0-4949-a1e0-185e78990783', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1639e800-2ef1-4535-b3f6-534e2915255c', 'e9292d77-d3df-49e3-b7fa-f3ce36ef2a76', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1639e800-2ef1-4535-b3f6-534e2915255c', '9ac991b6-768c-468a-b80f-27204fc3e17e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e9292d77-d3df-49e3-b7fa-f3ce36ef2a76', '1639e800-2ef1-4535-b3f6-534e2915255c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e9292d77-d3df-49e3-b7fa-f3ce36ef2a76', '9ac991b6-768c-468a-b80f-27204fc3e17e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ac991b6-768c-468a-b80f-27204fc3e17e', '1639e800-2ef1-4535-b3f6-534e2915255c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ac991b6-768c-468a-b80f-27204fc3e17e', 'e9292d77-d3df-49e3-b7fa-f3ce36ef2a76', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4ce709fa-4b1d-44ee-8737-e882eb933f66', '16525b39-3bf2-42b0-9faa-94e39fe0bac8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4ce709fa-4b1d-44ee-8737-e882eb933f66', 'f0d23ca2-c923-4c7a-b026-db8c564c4e55', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4ce709fa-4b1d-44ee-8737-e882eb933f66', '7cfbfbb0-8792-4b79-8428-4c41f9261b3b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4ce709fa-4b1d-44ee-8737-e882eb933f66', '49fb1be3-1dfb-4652-b82a-5ba736511d36', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4ce709fa-4b1d-44ee-8737-e882eb933f66', '4bb8cc1b-6ec1-477f-b2e2-93f23c4b230b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0d23ca2-c923-4c7a-b026-db8c564c4e55', '16525b39-3bf2-42b0-9faa-94e39fe0bac8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0d23ca2-c923-4c7a-b026-db8c564c4e55', '4ce709fa-4b1d-44ee-8737-e882eb933f66', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0d23ca2-c923-4c7a-b026-db8c564c4e55', '7cfbfbb0-8792-4b79-8428-4c41f9261b3b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0d23ca2-c923-4c7a-b026-db8c564c4e55', '49fb1be3-1dfb-4652-b82a-5ba736511d36', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0d23ca2-c923-4c7a-b026-db8c564c4e55', '4bb8cc1b-6ec1-477f-b2e2-93f23c4b230b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7cfbfbb0-8792-4b79-8428-4c41f9261b3b', '16525b39-3bf2-42b0-9faa-94e39fe0bac8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7cfbfbb0-8792-4b79-8428-4c41f9261b3b', '4ce709fa-4b1d-44ee-8737-e882eb933f66', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7cfbfbb0-8792-4b79-8428-4c41f9261b3b', 'f0d23ca2-c923-4c7a-b026-db8c564c4e55', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7cfbfbb0-8792-4b79-8428-4c41f9261b3b', '49fb1be3-1dfb-4652-b82a-5ba736511d36', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7cfbfbb0-8792-4b79-8428-4c41f9261b3b', '4bb8cc1b-6ec1-477f-b2e2-93f23c4b230b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4bb8cc1b-6ec1-477f-b2e2-93f23c4b230b', '16525b39-3bf2-42b0-9faa-94e39fe0bac8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4bb8cc1b-6ec1-477f-b2e2-93f23c4b230b', '49fb1be3-1dfb-4652-b82a-5ba736511d36', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4bb8cc1b-6ec1-477f-b2e2-93f23c4b230b', '4ce709fa-4b1d-44ee-8737-e882eb933f66', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4bb8cc1b-6ec1-477f-b2e2-93f23c4b230b', 'f0d23ca2-c923-4c7a-b026-db8c564c4e55', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4bb8cc1b-6ec1-477f-b2e2-93f23c4b230b', '7cfbfbb0-8792-4b79-8428-4c41f9261b3b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7dfc499e-22dc-4b48-a4f7-dd7691f785c8', '48dc5e93-efd8-405d-b1b2-99048a5de684', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7dfc499e-22dc-4b48-a4f7-dd7691f785c8', '3a7c05b5-f745-4e6e-852d-70a79069183b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('48dc5e93-efd8-405d-b1b2-99048a5de684', '7dfc499e-22dc-4b48-a4f7-dd7691f785c8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('48dc5e93-efd8-405d-b1b2-99048a5de684', '3a7c05b5-f745-4e6e-852d-70a79069183b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a7c05b5-f745-4e6e-852d-70a79069183b', '7dfc499e-22dc-4b48-a4f7-dd7691f785c8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a7c05b5-f745-4e6e-852d-70a79069183b', '48dc5e93-efd8-405d-b1b2-99048a5de684', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('808d8306-4185-4294-b232-e78bc0975f80', 'c951aa24-c757-42e7-895b-54dc5ca11de9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('808d8306-4185-4294-b232-e78bc0975f80', '5e65b655-4510-497f-a037-cc3976673828', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('808d8306-4185-4294-b232-e78bc0975f80', '4413cd55-661c-4fab-9888-919da693d615', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c951aa24-c757-42e7-895b-54dc5ca11de9', '4413cd55-661c-4fab-9888-919da693d615', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c951aa24-c757-42e7-895b-54dc5ca11de9', '808d8306-4185-4294-b232-e78bc0975f80', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c951aa24-c757-42e7-895b-54dc5ca11de9', '5e65b655-4510-497f-a037-cc3976673828', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5e65b655-4510-497f-a037-cc3976673828', '808d8306-4185-4294-b232-e78bc0975f80', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5e65b655-4510-497f-a037-cc3976673828', 'c951aa24-c757-42e7-895b-54dc5ca11de9', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5e65b655-4510-497f-a037-cc3976673828', '4413cd55-661c-4fab-9888-919da693d615', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4413cd55-661c-4fab-9888-919da693d615', 'c951aa24-c757-42e7-895b-54dc5ca11de9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4413cd55-661c-4fab-9888-919da693d615', '808d8306-4185-4294-b232-e78bc0975f80', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4413cd55-661c-4fab-9888-919da693d615', '5e65b655-4510-497f-a037-cc3976673828', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('419d5232-7e23-4773-a749-5284c4a88901', 'fe1a32fe-f8cd-4a2b-82fd-a2c72b36ed8d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('419d5232-7e23-4773-a749-5284c4a88901', '9c136fd0-3aaa-45f0-9eb2-60a14148b4c2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('419d5232-7e23-4773-a749-5284c4a88901', '090ac8e1-7f43-433b-85cf-1553273c7b33', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('419d5232-7e23-4773-a749-5284c4a88901', '8d128e29-a4d9-4da2-8382-116a7e0bdf98', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('419d5232-7e23-4773-a749-5284c4a88901', 'fb66cef3-3f51-4427-9c1d-cc0d39e80fc7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe1a32fe-f8cd-4a2b-82fd-a2c72b36ed8d', '419d5232-7e23-4773-a749-5284c4a88901', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe1a32fe-f8cd-4a2b-82fd-a2c72b36ed8d', '9c136fd0-3aaa-45f0-9eb2-60a14148b4c2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe1a32fe-f8cd-4a2b-82fd-a2c72b36ed8d', '090ac8e1-7f43-433b-85cf-1553273c7b33', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe1a32fe-f8cd-4a2b-82fd-a2c72b36ed8d', '8d128e29-a4d9-4da2-8382-116a7e0bdf98', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe1a32fe-f8cd-4a2b-82fd-a2c72b36ed8d', 'fb66cef3-3f51-4427-9c1d-cc0d39e80fc7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9c136fd0-3aaa-45f0-9eb2-60a14148b4c2', 'cbbc9a32-3f5d-4a8c-bb44-19ded56858f5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9c136fd0-3aaa-45f0-9eb2-60a14148b4c2', '419d5232-7e23-4773-a749-5284c4a88901', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9c136fd0-3aaa-45f0-9eb2-60a14148b4c2', 'fe1a32fe-f8cd-4a2b-82fd-a2c72b36ed8d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9c136fd0-3aaa-45f0-9eb2-60a14148b4c2', '090ac8e1-7f43-433b-85cf-1553273c7b33', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9c136fd0-3aaa-45f0-9eb2-60a14148b4c2', '8d128e29-a4d9-4da2-8382-116a7e0bdf98', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('090ac8e1-7f43-433b-85cf-1553273c7b33', '419d5232-7e23-4773-a749-5284c4a88901', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('090ac8e1-7f43-433b-85cf-1553273c7b33', 'fe1a32fe-f8cd-4a2b-82fd-a2c72b36ed8d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('090ac8e1-7f43-433b-85cf-1553273c7b33', '9c136fd0-3aaa-45f0-9eb2-60a14148b4c2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('090ac8e1-7f43-433b-85cf-1553273c7b33', '8d128e29-a4d9-4da2-8382-116a7e0bdf98', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('090ac8e1-7f43-433b-85cf-1553273c7b33', 'fb66cef3-3f51-4427-9c1d-cc0d39e80fc7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d128e29-a4d9-4da2-8382-116a7e0bdf98', '419d5232-7e23-4773-a749-5284c4a88901', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d128e29-a4d9-4da2-8382-116a7e0bdf98', 'fe1a32fe-f8cd-4a2b-82fd-a2c72b36ed8d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d128e29-a4d9-4da2-8382-116a7e0bdf98', '9c136fd0-3aaa-45f0-9eb2-60a14148b4c2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d128e29-a4d9-4da2-8382-116a7e0bdf98', '090ac8e1-7f43-433b-85cf-1553273c7b33', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d128e29-a4d9-4da2-8382-116a7e0bdf98', 'fb66cef3-3f51-4427-9c1d-cc0d39e80fc7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fb66cef3-3f51-4427-9c1d-cc0d39e80fc7', '419d5232-7e23-4773-a749-5284c4a88901', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fb66cef3-3f51-4427-9c1d-cc0d39e80fc7', 'fe1a32fe-f8cd-4a2b-82fd-a2c72b36ed8d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fb66cef3-3f51-4427-9c1d-cc0d39e80fc7', '9c136fd0-3aaa-45f0-9eb2-60a14148b4c2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fb66cef3-3f51-4427-9c1d-cc0d39e80fc7', '090ac8e1-7f43-433b-85cf-1553273c7b33', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fb66cef3-3f51-4427-9c1d-cc0d39e80fc7', '8d128e29-a4d9-4da2-8382-116a7e0bdf98', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('998eca0a-d515-4285-81e2-13da2d74e50f', '419d5232-7e23-4773-a749-5284c4a88901', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('998eca0a-d515-4285-81e2-13da2d74e50f', 'fe1a32fe-f8cd-4a2b-82fd-a2c72b36ed8d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('998eca0a-d515-4285-81e2-13da2d74e50f', '9c136fd0-3aaa-45f0-9eb2-60a14148b4c2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('998eca0a-d515-4285-81e2-13da2d74e50f', '090ac8e1-7f43-433b-85cf-1553273c7b33', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('998eca0a-d515-4285-81e2-13da2d74e50f', '8d128e29-a4d9-4da2-8382-116a7e0bdf98', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cbbc9a32-3f5d-4a8c-bb44-19ded56858f5', '9c136fd0-3aaa-45f0-9eb2-60a14148b4c2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cbbc9a32-3f5d-4a8c-bb44-19ded56858f5', '419d5232-7e23-4773-a749-5284c4a88901', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cbbc9a32-3f5d-4a8c-bb44-19ded56858f5', 'fe1a32fe-f8cd-4a2b-82fd-a2c72b36ed8d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cbbc9a32-3f5d-4a8c-bb44-19ded56858f5', '090ac8e1-7f43-433b-85cf-1553273c7b33', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cbbc9a32-3f5d-4a8c-bb44-19ded56858f5', '8d128e29-a4d9-4da2-8382-116a7e0bdf98', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c8430fb-6a3e-4a1f-bdaa-3767a7efde02', '419d5232-7e23-4773-a749-5284c4a88901', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c8430fb-6a3e-4a1f-bdaa-3767a7efde02', 'fe1a32fe-f8cd-4a2b-82fd-a2c72b36ed8d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c8430fb-6a3e-4a1f-bdaa-3767a7efde02', '9c136fd0-3aaa-45f0-9eb2-60a14148b4c2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c8430fb-6a3e-4a1f-bdaa-3767a7efde02', '090ac8e1-7f43-433b-85cf-1553273c7b33', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c8430fb-6a3e-4a1f-bdaa-3767a7efde02', '8d128e29-a4d9-4da2-8382-116a7e0bdf98', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('be96520a-ca90-4c73-b537-e65765916ced', '72d2cad6-4a7c-49ca-bb89-6280ff96b828', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('74c87d07-8479-40db-aef4-97bb5e1af3d0', '72d2cad6-4a7c-49ca-bb89-6280ff96b828', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b34db5ac-ab64-4f3f-abe1-e5f6f8eb2a9b', '72d2cad6-4a7c-49ca-bb89-6280ff96b828', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75b8b7ee-52e3-4ad2-ab62-03fa77152873', '72d2cad6-4a7c-49ca-bb89-6280ff96b828', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eefb3456-d89a-47d9-bb42-0bcdcffbbd17', '72d2cad6-4a7c-49ca-bb89-6280ff96b828', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('77127a2b-d87b-4943-ab26-0095174430e7', '72d2cad6-4a7c-49ca-bb89-6280ff96b828', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8aa5aec3-c6ff-467f-814a-e962b565ab2e', '5e141ace-84bc-47d1-b60e-d858b269f91e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8aa5aec3-c6ff-467f-814a-e962b565ab2e', 'aaf7f38d-96d9-41b7-90ad-da7643ad1953', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8aa5aec3-c6ff-467f-814a-e962b565ab2e', '1d654c12-4acb-4c23-b23b-ba217895031c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5e141ace-84bc-47d1-b60e-d858b269f91e', '8aa5aec3-c6ff-467f-814a-e962b565ab2e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5e141ace-84bc-47d1-b60e-d858b269f91e', 'aaf7f38d-96d9-41b7-90ad-da7643ad1953', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5e141ace-84bc-47d1-b60e-d858b269f91e', '1d654c12-4acb-4c23-b23b-ba217895031c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aaf7f38d-96d9-41b7-90ad-da7643ad1953', '1d654c12-4acb-4c23-b23b-ba217895031c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aaf7f38d-96d9-41b7-90ad-da7643ad1953', '8aa5aec3-c6ff-467f-814a-e962b565ab2e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aaf7f38d-96d9-41b7-90ad-da7643ad1953', '5e141ace-84bc-47d1-b60e-d858b269f91e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1d654c12-4acb-4c23-b23b-ba217895031c', 'aaf7f38d-96d9-41b7-90ad-da7643ad1953', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1d654c12-4acb-4c23-b23b-ba217895031c', '8aa5aec3-c6ff-467f-814a-e962b565ab2e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1d654c12-4acb-4c23-b23b-ba217895031c', '5e141ace-84bc-47d1-b60e-d858b269f91e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1fcb79ba-a8ef-4875-8760-7e4f0211e86e', '6b3f7642-5a72-4805-b6a0-a1eb14859cee', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1fcb79ba-a8ef-4875-8760-7e4f0211e86e', '2f06899b-19aa-4909-99bf-32b1bd4a8e00', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d119c214-4fad-4ba5-bbc6-9be2474de1b1', '1fcb79ba-a8ef-4875-8760-7e4f0211e86e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d119c214-4fad-4ba5-bbc6-9be2474de1b1', '6b3f7642-5a72-4805-b6a0-a1eb14859cee', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d119c214-4fad-4ba5-bbc6-9be2474de1b1', '2f06899b-19aa-4909-99bf-32b1bd4a8e00', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('80ec5980-29f0-412e-a910-3a332a687a62', '1fcb79ba-a8ef-4875-8760-7e4f0211e86e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('80ec5980-29f0-412e-a910-3a332a687a62', '6b3f7642-5a72-4805-b6a0-a1eb14859cee', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('80ec5980-29f0-412e-a910-3a332a687a62', '2f06899b-19aa-4909-99bf-32b1bd4a8e00', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6b3f7642-5a72-4805-b6a0-a1eb14859cee', '1fcb79ba-a8ef-4875-8760-7e4f0211e86e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6b3f7642-5a72-4805-b6a0-a1eb14859cee', '2f06899b-19aa-4909-99bf-32b1bd4a8e00', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bf0a5257-2c86-4e7a-b800-fc411e97f41d', '1fcb79ba-a8ef-4875-8760-7e4f0211e86e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bf0a5257-2c86-4e7a-b800-fc411e97f41d', '6b3f7642-5a72-4805-b6a0-a1eb14859cee', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bf0a5257-2c86-4e7a-b800-fc411e97f41d', '2f06899b-19aa-4909-99bf-32b1bd4a8e00', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('319bac56-600e-4bff-bc6f-bcd9376205e7', '1fcb79ba-a8ef-4875-8760-7e4f0211e86e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('319bac56-600e-4bff-bc6f-bcd9376205e7', '6b3f7642-5a72-4805-b6a0-a1eb14859cee', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('319bac56-600e-4bff-bc6f-bcd9376205e7', '2f06899b-19aa-4909-99bf-32b1bd4a8e00', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2f06899b-19aa-4909-99bf-32b1bd4a8e00', '1fcb79ba-a8ef-4875-8760-7e4f0211e86e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2f06899b-19aa-4909-99bf-32b1bd4a8e00', '6b3f7642-5a72-4805-b6a0-a1eb14859cee', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c35479c8-05a6-49c2-8fd3-e558360c6032', '1fcb79ba-a8ef-4875-8760-7e4f0211e86e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c35479c8-05a6-49c2-8fd3-e558360c6032', '6b3f7642-5a72-4805-b6a0-a1eb14859cee', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c35479c8-05a6-49c2-8fd3-e558360c6032', '2f06899b-19aa-4909-99bf-32b1bd4a8e00', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cb71fb4a-8f22-419e-a74f-c67059b86b47', '1fcb79ba-a8ef-4875-8760-7e4f0211e86e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cb71fb4a-8f22-419e-a74f-c67059b86b47', '6b3f7642-5a72-4805-b6a0-a1eb14859cee', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cb71fb4a-8f22-419e-a74f-c67059b86b47', '2f06899b-19aa-4909-99bf-32b1bd4a8e00', 2) ON CONFLICT DO NOTHING;



INSERT INTO public.faqs VALUES ('ffb79f9e-dcdb-48e9-a8e3-35bf5c3bc15a', 'متى يوصلني الرد بعد الاشتراك؟', 'خلال 48 ساعة عمل. أيام العمل من الأحد إلى الخميس، من 12 الظهر حتى 9 مساءً، والتواصل على واتساب.', 0, true, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('e9040b50-7bdf-4295-bd4f-5fc92f08fa38', 'كيف تتم المتابعة؟', 'ترسل مراجعتك الأسبوعية في يوم المراجعة، وأرد عليك بتعديلات مسجلة (فيديو أو صوت). في الباقة الأساسية المتابعة كل أسبوعين. التواصل اليومي على واتساب مع رد خلال 48 ساعة.', 1, true, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('720c10bc-8798-4bbc-b21d-93903b6aebbb', 'أنا مبتدئ تماماً، هل يناسبني؟', 'نعم. البرنامج يُبنى على مستواك الحالي، والتمارين مشروحة، وتقدر ترسل مقاطع أدائك لتصحيح التكنيك.', 2, true, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('60595e66-ba04-4fc9-8c7a-3a1a1ff2797d', 'أتمرن في البيت، ماذا أحتاج من أدوات؟', 'تحدد في النموذج الأدوات المتوفرة عندك (دمبلز، حبال مقاومة، بار…) ويُبنى جدولك عليها.', 3, true, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('6c16fb0e-b15a-474d-9b8d-b56e75801b2d', 'كيف أدفع؟', 'بتحويل بنكي بعد تعبئة الاستبيان. أول ما ترسل الاستبيان يظهر لك رقم طلبك والمبلغ وبيانات الحساب. حوّل المبلغ وارفع صورة الإيصال من صفحة طلبك، ويتأكد اشتراكك بعد التحقق من وصول المبلغ.', 4, true, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('6d4c04f5-f452-4fcc-886f-eaac50494666', 'ما شروط ضمان استرجاع المبلغ؟', 'في اشتراكات 3 أشهر لباقات المتابعة (المكثفة، المتقدمة، الأساسية): إذا لم يتحسن أي مؤشر من مؤشرات تقدمك بعد 12 أسبوعاً، يرجع لك المبلغ كاملاً.
مؤشرات التقدم (بحسب هدفك): متوسط الوزن الأسبوعي، أو محيط الخصر، أو القوة في التمارين الأساسية (الوزن أو التكرارات).
شروط الضمان:
- إرسال المراجعة الأسبوعية كل أسبوع.
- أخذ القياسات بانتظام.
- تصوير التمارين وإرسالها.
- الالتزام بجدول التغذية المخصص (في الباقات التي تشمل تغذية).
يُطلب الاسترجاع عبر واتساب خلال 14 يوماً من نهاية الأشهر الثلاثة.', 5, true, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('cfe77fd6-886d-4a60-8e6a-b69834f22606', 'هل الجداول لي بعد انتهاء الاشتراك؟', 'نعم، جميع الجداول لك مدى الحياة وتقدر تعدّل عليها.', 6, true, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('58474322-ce9b-42ba-8a0f-bc37296565f6', 'ما هو التجديد المجاني؟', 'مكافأة للملتزمين: إذا كان اشتراكك 3 أشهر تحصل على 3 أشهر إضافية مجاناً، فيصير المجموع 6 أشهر بسعر 3.
الشروط:
- نسبة التزام 90% فأكثر: المراجعات الأسبوعية المرسلة والتمارين المسجلة.
- تقدم واضح في مؤشرات التقدم نفسها المذكورة في الضمان.
- للمتدربين الرجال: إرسال صور التطور (قبل وبعد) للمدربة للتوثيق، مع تغطية الوجه والسرة.
نشر الصور في السوشل ميديا اختياري بالكامل حسب موافقتك، ولا يؤثر على استحقاقك للتجديد.', 7, true, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('58f5168d-dc5b-475c-91f4-c908aa3c422b', 'من يطّلع على بياناتي؟', 'المدربة فقط، وتُستخدم لتصميم برنامجك ومتابعتك. لا تُنشر نتيجتك أو صورتك إلا بموافقتك الصريحة في النموذج.', 8, true, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;



INSERT INTO public.foods VALUES ('1fb74c23-0fae-4158-954d-5d68671deb19', 'رز أبيض مطبوخ', 'Rice, white, long-grain, regular, enriched, cooked', 'حبوب ونشويات', 130.0, 2.7, 28.2, 0.3, 150.0, 'كوب إلا ربع', 'usda', '168878', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3b609b27-bb8c-42f5-99c9-43f2cc6121b8', 'رز بني مطبوخ', 'Rice, brown, long-grain, cooked (Includes foods for USDA''s Food Distribution Program)', 'حبوب ونشويات', 123.0, 2.7, 25.6, 1.0, 150.0, NULL, 'usda', '169704', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b8019b9d-8b95-4c8b-a026-f3f4b76ea1cd', 'رز أبيض (غير مطبوخ)', 'Rice, white, long-grain, regular, raw, enriched', 'حبوب ونشويات', 365.0, 7.1, 80.0, 0.7, 75.0, NULL, 'usda', '168877', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('65a85daa-b8cc-4e41-8e30-d36a479527c5', 'مكرونة مطبوخة', 'Pasta, cooked, enriched, without added salt', 'حبوب ونشويات', 158.0, 5.8, 30.9, 0.9, 140.0, 'كوب', 'usda', '169737', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d483c518-d1d5-4248-b2d0-266bf5e8cb36', 'مكرونة (غير مطبوخة)', 'Pasta, dry, enriched', 'حبوب ونشويات', 371.0, 13.0, 74.7, 1.5, 75.0, NULL, 'usda', '169736', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f2d771f7-43f8-4b4d-9ea9-c92d62d1401b', 'شوفان', 'Cereals, oats, regular and quick, not fortified, dry', 'حبوب ونشويات', 379.0, 13.2, 67.7, 6.5, 40.0, 'نص كوب', 'usda', '173904', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('932a2250-730e-498d-85ea-4a2b8e20fd1d', 'خبز أبيض (توست)', 'Bread, white, commercially prepared (includes soft bread crumbs)', 'خبز', 266.0, 8.9, 49.4, 3.3, 28.0, 'شريحة', 'usda', '174924', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b5732b81-0486-45f3-9a91-85b84c70924e', 'خبز بر (توست أسمر)', 'Bread, whole-wheat, commercially prepared', 'خبز', 252.0, 12.5, 42.7, 3.5, 32.0, 'شريحة', 'usda', '172688', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('4c9ee82d-d92f-4dd9-a8db-fbc9f9cbd285', 'خبز عربي أبيض', 'Bread, pita, white, enriched', 'خبز', 275.0, 9.1, 55.7, 1.2, 60.0, 'رغيف صغير', 'usda', '174915', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d415b2c1-a69e-467d-a645-8ac3f983f550', 'خبز عربي بر', 'Bread, pita, whole-wheat', 'خبز', 262.0, 9.8, 55.9, 1.7, 64.0, 'رغيف صغير', 'usda', '174916', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3d50d62f-c649-4a74-b74a-b805a47bc1ff', 'تورتيلا قمح', 'Tortillas, ready-to-bake or -fry, flour, refrigerated', 'خبز', 306.0, 8.2, 49.4, 8.0, 45.0, 'حبة', 'usda', '175037', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('eb2a6489-33e1-4d8b-96f6-87f1dcf06cc1', 'بطاطس مسلوقة', 'Potatoes, boiled, cooked without skin, flesh, without salt', 'حبوب ونشويات', 86.0, 1.7, 20.0, 0.1, 150.0, 'حبة وسط', 'usda', '170440', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('327d78b8-6ee9-4d30-a221-cec2f6cd3211', 'بطاطا حلوة مشوية', 'Sweet potato, cooked, baked in skin, flesh, without salt', 'حبوب ونشويات', 90.0, 2.0, 20.7, 0.2, 150.0, 'حبة وسط', 'usda', '168483', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('6e59213b-b6b0-46f8-b69e-f7b187d0eceb', 'برغل مطبوخ', 'Bulgur, cooked', 'حبوب ونشويات', 83.0, 3.1, 18.6, 0.2, 150.0, NULL, 'usda', '170287', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('57763e6b-8a06-4fda-8c11-6232bd47279b', 'كينوا مطبوخة', 'Quinoa, cooked', 'حبوب ونشويات', 120.0, 4.4, 21.3, 1.9, 150.0, NULL, 'usda', '168917', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('2d90639a-e07b-4cb1-850e-b4b5e30400ea', 'كورن فليكس', 'Cereals ready-to-eat, RALSTON Corn Flakes', 'حبوب ونشويات', 384.0, 5.9, 88.0, 0.9, 30.0, NULL, 'usda', '174648', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('c08dd7bd-05a7-4daa-bce3-6133570ea1c9', 'صدر دجاج مشوي', 'Chicken, broilers or fryers, breast, meat only, cooked, roasted', 'لحوم ودواجن', 165.0, 31.0, 0.0, 3.6, 100.0, NULL, 'usda', '171477', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('66ff161f-055d-4645-9962-4831f10b6c0e', 'صدر دجاج نيء', 'Chicken, broiler or fryers, breast, skinless, boneless, meat only, raw', 'لحوم ودواجن', 120.0, 22.5, 0.0, 2.6, 150.0, NULL, 'usda', '171077', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('cdf28b3c-447c-49fd-8716-7624758d49ee', 'فخذ دجاج مشوي (بدون جلد)', 'Chicken, broilers or fryers, thigh, meat only, cooked, roasted', 'لحوم ودواجن', 179.0, 24.8, 0.0, 8.2, 100.0, NULL, 'usda', '172388', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3946f375-d58c-4a4f-abe3-dfa0e9d5df6e', 'لحم بقري مفروم 90% مطبوخ', 'Beef, ground, 90% lean meat / 10% fat, patty, cooked, broiled', 'لحوم ودواجن', 217.0, 26.1, 0.0, 11.8, 100.0, NULL, 'usda', '174031', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f4e30ba6-83a1-4bbe-aba0-bf069804d7e6', 'لحم بقري مفروم 80% مطبوخ', 'Beef, ground, 80% lean meat / 20% fat, patty, cooked, broiled', 'لحوم ودواجن', 270.0, 25.8, 0.0, 17.8, 100.0, NULL, 'usda', '171797', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('5986fc5a-af40-4b1f-88a7-2fbfb6cfa0f7', 'لحم غنم مطبوخ', 'Lamb, composite of trimmed retail cuts, separable lean only, trimmed to 1/4" fat, choice, cooked', 'لحوم ودواجن', 206.0, 28.2, 0.0, 9.5, 100.0, NULL, 'usda', '174308', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('601ac7bc-3096-4a8c-8689-6fe8fc238861', 'ديك رومي (شرائح)', 'Turkey, whole, breast, meat only, cooked, roasted', 'لحوم ودواجن', 147.0, 30.1, 0.0, 2.1, 50.0, NULL, 'usda', '171496', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('c274a700-679a-4077-b334-e478752aade0', 'تونة معلبة بالماء', 'Fish, tuna, light, canned in water, drained solids (Includes foods for USDA''s Food Distribution Program)', 'أسماك', 86.0, 19.4, 0.0, 1.0, 100.0, 'علبة صغيرة مصفاة', 'usda', '173709', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('8a5196f6-06fa-4414-ae12-cfa8a21dc2f3', 'تونة معلبة بالزيت', 'Fish, tuna, light, canned in oil, drained solids', 'أسماك', 198.0, 29.1, 0.0, 8.2, 100.0, NULL, 'usda', '173708', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('afdfbfb5-be8a-4fb2-96e7-8eb856e11309', 'سلمون مطبوخ', 'Fish, salmon, Atlantic, farmed, cooked, dry heat', 'أسماك', 206.0, 22.1, 0.0, 12.4, 120.0, NULL, 'usda', '175168', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('9f2b1135-8d16-43ad-b28a-705dc30b3d51', 'سلمون مدخن', 'Fish, salmon, chinook, smoked', 'أسماك', 117.0, 18.3, 0.0, 4.3, 60.0, NULL, 'usda', '173687', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f726bb6e-767e-4bc2-8ce8-1ea76d31b103', 'روبيان مطبوخ', 'Crustaceans, shrimp, cooked', 'أسماك', 99.0, 24.0, 0.2, 0.3, 100.0, NULL, 'usda', '175180', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('e62dd61b-565c-4f4e-84c2-e3f01426df8d', 'هامور/سمك أبيض مطبوخ', 'Fish, grouper, mixed species, cooked, dry heat', 'أسماك', 118.0, 24.8, 0.0, 1.3, 150.0, NULL, 'usda', '171963', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b7f580cf-38c1-43fc-9fc1-efe6920fbd06', 'بيض كامل', 'Egg, whole, raw, fresh', 'بيض وألبان', 143.0, 12.6, 0.7, 9.5, 50.0, 'بيضة', 'usda', '171287', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('5453922b-b73b-4f9b-8e6c-d68ff935292f', 'بياض بيض', 'Egg, white, raw, fresh', 'بيض وألبان', 52.0, 10.9, 0.7, 0.2, 33.0, 'بياض بيضة', 'usda', '172183', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('dbc5d413-fac5-4944-8254-4bef794ea8ba', 'بيض مسلوق', 'Egg, whole, cooked, hard-boiled', 'بيض وألبان', 155.0, 12.6, 1.1, 10.6, 50.0, 'بيضة', 'usda', '173424', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f866080c-5724-4c91-980d-24934dbeeaf5', 'حليب كامل الدسم', 'Milk, whole, 3.25% milkfat, with added vitamin D', 'بيض وألبان', 61.0, 3.2, 4.8, 3.3, 244.0, 'كوب', 'usda', '171265', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('bd296fe0-a3b1-46e6-9880-980b7f3e7692', 'حليب قليل الدسم 1%', 'Milk, lowfat, fluid, 1% milkfat, with added vitamin A and vitamin D', 'بيض وألبان', 42.0, 3.4, 5.0, 1.0, 244.0, 'كوب', 'usda', '170872', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('01c4d853-39fd-4e47-b25a-b7b938515756', 'حليب خالي الدسم', 'Milk, nonfat, fluid, with added vitamin A and vitamin D (fat free or skim)', 'بيض وألبان', 34.0, 3.4, 5.0, 0.1, 245.0, 'كوب', 'usda', '171269', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('15dd614d-2fde-46f9-b59e-60dea323bc78', 'زبادي كامل الدسم', 'Yogurt, plain, whole milk', 'بيض وألبان', 61.0, 3.5, 4.7, 3.3, 170.0, NULL, 'usda', '171284', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b51788c8-f520-4a49-8ea8-ecfcd6b2a165', 'زبادي قليل الدسم', 'Yogurt, plain, low fat', 'بيض وألبان', 63.0, 5.3, 7.0, 1.6, 170.0, NULL, 'usda', '170886', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('39204943-4fdc-45cb-9edd-3f987d1e0d0e', 'زبادي يوناني قليل الدسم', 'Yogurt, Greek, plain, lowfat', 'بيض وألبان', 73.0, 10.0, 3.9, 1.9, 170.0, NULL, 'usda', '170903', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('c7e5865a-b028-46d1-b26f-0d60841a58f3', 'زبدة فول سوداني', 'Peanut butter, smooth style, without salt', 'دهون ومكسرات', 598.0, 22.2, 22.3, 51.4, 16.0, 'ملعقة كبيرة', 'usda', '172470', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('5f70cf66-8b7e-4fd4-b031-53552e40d81c', 'زبادي يوناني خالي الدسم', 'Yogurt, Greek, plain, nonfat (Includes foods for USDA''s Food Distribution Program)', 'بيض وألبان', 59.0, 10.2, 3.6, 0.4, 170.0, NULL, 'usda', '170894', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('98f6f7a0-cf1f-4193-9a12-d696052975b6', 'جبنة قريش (كوتج)', 'Cheese, cottage, lowfat, 2% milkfat', 'بيض وألبان', 81.0, 10.5, 4.8, 2.3, 113.0, 'نص كوب', 'usda', '172182', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f17e08a4-d0df-446a-9908-2f3a77e690c0', 'جبنة موزاريلا قليلة الدسم', 'Cheese, mozzarella, part skim milk', 'بيض وألبان', 254.0, 24.3, 2.8, 15.9, 28.0, NULL, 'usda', '170847', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('49077cc6-8cec-4252-a750-cd75259c1a4b', 'جبنة شيدر', 'Cheese, cheddar (Includes foods for USDA''s Food Distribution Program)', 'بيض وألبان', 403.0, 22.9, 3.4, 33.3, 28.0, 'شريحة', 'usda', '173414', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('46a25882-bbeb-4a47-90da-e4e727aabc72', 'جبنة فيتا', 'Cheese, feta', 'بيض وألبان', 265.0, 14.2, 3.9, 21.5, 28.0, NULL, 'usda', '173420', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d03e7894-cb85-4cda-b69c-98f672873fea', 'جبنة كريمية', 'Cheese, cream', 'بيض وألبان', 350.0, 6.2, 5.5, 34.4, 30.0, NULL, 'usda', '173418', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('16c50dbf-c45f-4533-8ffb-0d0b6c92449c', 'واي بروتين', 'Beverages, Whey protein powder isolate', 'مكملات', 359.0, 58.1, 29.1, 1.2, 30.0, 'سكوب', 'usda', '173177', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('25b53c60-7dbd-4a53-8eac-85784ebfc82a', 'عدس مطبوخ', 'Lentils, mature seeds, cooked, boiled, without salt', 'بقوليات', 116.0, 9.0, 20.1, 0.4, 150.0, NULL, 'usda', '172421', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('7b858cbf-f020-464b-b637-ddec02bd6be6', 'حمص مطبوخ', 'Chickpeas (garbanzo beans, bengal gram), mature seeds, cooked, boiled, without salt', 'بقوليات', 164.0, 8.9, 27.4, 2.6, 150.0, NULL, 'usda', '173757', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('284553ed-ee82-4faa-ae27-4959000be80b', 'فول مدمس (مطبوخ)', 'Broadbeans (fava beans), mature seeds, cooked, boiled, without salt', 'بقوليات', 110.0, 7.6, 19.7, 0.4, 150.0, NULL, 'usda', '173753', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('03f123ff-6fec-48f0-b71c-a2556dc94c49', 'فاصوليا حمراء مطبوخة', 'Beans, kidney, all types, mature seeds, cooked, boiled, without salt', 'بقوليات', 127.0, 8.7, 22.8, 0.5, 150.0, NULL, 'usda', '173740', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('88d201f9-3443-4739-91cb-5022acf70e8a', 'حمص بطحينة (حمص جاهز)', 'Hummus, commercial', 'بقوليات', 237.0, 7.8, 15.0, 17.8, 60.0, NULL, 'usda', '174289', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('e5416b19-914c-4589-b826-6ee9fd2c419b', 'تمر مجدول', 'Dates, medjool', 'فواكه', 277.0, 1.8, 75.0, 0.2, 24.0, 'حبة', 'usda', '168191', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('9b14d57b-71d4-401b-879d-95864e558cbd', 'تمر (دقلة نور)', 'Dates, deglet noor', 'فواكه', 282.0, 2.5, 75.0, 0.4, 7.0, 'حبة', 'usda', '171726', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('dec105b8-5d9f-4ed5-bf91-8519bb31afc6', 'موز', 'Bananas, raw', 'فواكه', 89.0, 1.1, 22.8, 0.3, 118.0, 'حبة وسط', 'usda', '173944', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('310d6747-4a1a-4cd7-ab4b-9fe581772842', 'تفاح', 'Apples, raw, with skin (Includes foods for USDA''s Food Distribution Program)', 'فواكه', 52.0, 0.3, 13.8, 0.2, 182.0, 'حبة وسط', 'usda', '171688', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('7d9981a2-6f64-4ac0-87aa-800c4a94dbb6', 'برتقال', 'Oranges, raw, all commercial varieties', 'فواكه', 47.0, 0.9, 11.8, 0.1, 131.0, 'حبة', 'usda', '169097', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b680dc5d-5164-41d9-851a-ba25ba9e200f', 'فراولة', 'Strawberries, raw', 'فواكه', 32.0, 0.7, 7.7, 0.3, 150.0, 'كوب', 'usda', '167762', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('501c61af-3fd2-4d22-8ef2-aec6edadd5ea', 'عنب', 'Grapes, red or green (European type, such as Thompson seedless), raw', 'فواكه', 69.0, 0.7, 18.1, 0.2, 150.0, 'كوب', 'usda', '174683', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('55d85507-6c61-4331-ad6f-69c0ffd0bcc8', 'بطيخ', 'Watermelon, raw', 'فواكه', 30.0, 0.6, 7.6, 0.2, 280.0, 'كوب ونص', 'usda', '167765', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ef629915-2167-47ab-a37d-05188ff68a28', 'مانجو', 'Mangos, raw', 'فواكه', 60.0, 0.8, 15.0, 0.4, 165.0, 'كوب', 'usda', '169910', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('33b2b0d1-704b-41ad-86b7-4cfe34bb8e4f', 'أناناس', 'Pineapple, raw, all varieties', 'فواكه', 50.0, 0.5, 13.1, 0.1, 165.0, 'كوب', 'usda', '169124', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('537497f7-db94-42b9-9b3b-f49a1262b62a', 'توت أزرق', 'Blueberries, raw', 'فواكه', 57.0, 0.7, 14.5, 0.3, 148.0, 'كوب', 'usda', '171711', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ca598fb8-06d2-4385-a649-9ab84990061e', 'كيوي', 'Kiwifruit, green, raw', 'فواكه', 61.0, 1.1, 14.7, 0.5, 75.0, 'حبة', 'usda', '168153', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('fc433e29-047a-4b52-bb35-07a74707f5cb', 'رمان', 'Pomegranates, raw', 'فواكه', 83.0, 1.7, 18.7, 1.2, 87.0, 'نص كوب حبوب', 'usda', '169134', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('485d3583-4ae1-43ff-bfb3-a08a8db19a26', 'خيار', 'Cucumber, with peel, raw', 'خضار', 15.0, 0.7, 3.6, 0.1, 100.0, NULL, 'usda', '168409', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('9c201963-5e71-457b-a6ee-91714278bbd8', 'طماطم', 'Tomatoes, red, ripe, raw, year round average', 'خضار', 18.0, 0.9, 3.9, 0.2, 120.0, 'حبة وسط', 'usda', '170457', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('7102cef0-17f2-4ae3-b4c5-63b3cebebee6', 'خس', 'Lettuce, cos or romaine, raw', 'خضار', 17.0, 1.2, 3.3, 0.3, 50.0, NULL, 'usda', '169247', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('5bbb1ec2-7704-4da6-8618-05dcaa74552c', 'جزر', 'Carrots, raw', 'خضار', 41.0, 0.9, 9.6, 0.2, 60.0, 'حبة', 'usda', '170393', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('732bb7ab-af3b-4d5e-a534-768cc09aeffd', 'بروكلي مطبوخ', 'Broccoli, cooked, boiled, drained, without salt', 'خضار', 35.0, 2.4, 7.2, 0.4, 90.0, NULL, 'usda', '169967', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('8fe669b2-8e45-4908-8e4b-520014ecec3a', 'سبانخ', 'Spinach, raw', 'خضار', 23.0, 2.9, 3.6, 0.4, 30.0, 'كوب', 'usda', '168462', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('4b709bfa-40f5-496f-aa92-6fb0b8f414eb', 'فلفل رومي أحمر', 'Peppers, sweet, red, raw', 'خضار', 26.0, 1.0, 6.0, 0.3, 120.0, 'حبة', 'usda', '170108', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('82d06e06-d6d7-4de7-8b24-98d56453f9c1', 'بصل', 'Onions, raw', 'خضار', 40.0, 1.1, 9.3, 0.1, 110.0, 'حبة وسط', 'usda', '170000', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('9d689376-cb57-4dca-92bb-30f43cfe518a', 'فطر (مشروم)', 'Mushrooms, white, raw', 'خضار', 22.0, 3.1, 3.3, 0.3, 70.0, 'كوب', 'usda', '169251', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('5d57edbb-83b5-49a6-993b-58314ee347d6', 'كوسا مطبوخة', 'Squash, summer, zucchini, includes skin, cooked, boiled, drained, without salt', 'خضار', 15.0, 1.1, 2.7, 0.4, 180.0, NULL, 'usda', '169292', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('7b6c448a-dec3-4dd1-afa7-de418cf89161', 'باذنجان مطبوخ', 'Eggplant, cooked, boiled, drained, without salt', 'خضار', 35.0, 0.8, 8.7, 0.2, 100.0, NULL, 'usda', '169229', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('dd333e10-e340-4dda-98e1-e543dfad6e3e', 'ذرة حلوة مطبوخة', 'Corn, sweet, yellow, cooked, boiled, drained, without salt', 'خضار', 96.0, 3.4, 21.0, 1.5, 150.0, NULL, 'usda', '169999', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('e16554b3-56b3-4614-a386-860203fe64ab', 'أفوكادو', 'Avocados, raw, all commercial varieties', 'دهون ومكسرات', 160.0, 2.0, 8.5, 14.7, 50.0, 'ثلث حبة', 'usda', '171705', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('21df7f2c-90f6-4b7c-97ac-bb5d31633b79', 'زيت زيتون', 'Oil, olive, salad or cooking', 'دهون ومكسرات', 884.0, 0.0, 0.0, 100.0, 5.0, 'ملعقة صغيرة', 'usda', '171413', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('4cab0148-bd49-4758-a621-546ab85e4bfc', 'زبدة', 'Butter, salted', 'دهون ومكسرات', 717.0, 0.9, 0.1, 81.1, 5.0, 'ملعقة صغيرة', 'usda', '173410', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('2968bc6d-a3d4-476f-abbf-070e58a4b6ec', 'لوز', 'Nuts, almonds', 'دهون ومكسرات', 579.0, 21.2, 21.6, 49.9, 28.0, 'حفنة', 'usda', '170567', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('9d843936-565c-4533-b685-be201d15b910', 'كاجو', 'Nuts, cashew nuts, raw', 'دهون ومكسرات', 553.0, 18.2, 30.2, 43.9, 28.0, 'حفنة', 'usda', '170162', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('031cac52-90e1-4532-8002-9d82603c3fce', 'فستق حلبي', 'Nuts, pistachio nuts, raw', 'دهون ومكسرات', 560.0, 20.2, 27.2, 45.3, 28.0, 'حفنة', 'usda', '170184', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b6a14c65-afb2-4c40-9f8f-154a6ece9b3e', 'جوز (عين الجمل)', 'Nuts, walnuts, english', 'دهون ومكسرات', 654.0, 15.2, 13.7, 65.2, 28.0, 'حفنة', 'usda', '170187', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b8b63d36-0c31-4caa-a8cf-40e2851e4c01', 'فول سوداني', 'Peanuts, all types, raw', 'دهون ومكسرات', 567.0, 25.8, 16.1, 49.2, 28.0, 'حفنة', 'usda', '172430', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('352ec177-f3ca-4145-9ded-f397dfb192cb', 'طحينة', 'Seeds, sesame butter, tahini, from roasted and toasted kernels (most common type)', 'دهون ومكسرات', 595.0, 17.0, 21.2, 53.8, 15.0, 'ملعقة كبيرة', 'usda', '170189', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('adcf8684-ce42-460a-b142-0546618ed288', 'بذور الشيا', 'Seeds, chia seeds, dried', 'دهون ومكسرات', 486.0, 16.5, 42.1, 30.7, 12.0, 'ملعقة كبيرة', 'usda', '170554', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ca698974-1271-472b-a4e2-47dbc82afeab', 'عسل', 'Honey', 'حلويات ومشروبات', 304.0, 0.3, 82.4, 0.0, 21.0, 'ملعقة كبيرة', 'usda', '169640', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d9a05c76-219f-443a-ae52-a39929a65ab3', 'سكر أبيض', 'Sugars, granulated', 'حلويات ومشروبات', 387.0, 0.0, 100.0, 0.0, 4.0, 'ملعقة صغيرة', 'usda', '169655', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3c672c9e-7d15-4291-8769-ba3b6faa21fc', 'شوكولاتة داكنة 70-85%', 'Chocolate, dark, 70-85% cacao solids', 'حلويات ومشروبات', 598.0, 7.8, 45.9, 42.6, 20.0, NULL, 'usda', '170273', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('71ef00da-7184-4008-a5b8-5ffaaa309dfa', 'عصير برتقال', 'Orange juice, raw (Includes foods for USDA''s Food Distribution Program)', 'حلويات ومشروبات', 45.0, 0.7, 10.4, 0.2, 248.0, 'كوب', 'usda', '169098', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('5361855c-107c-4330-8372-5b05203d42d2', 'مايونيز', 'Salad dressing, mayonnaise, regular', 'صوصات', 680.0, 1.0, 0.6, 74.9, 15.0, 'ملعقة كبيرة', 'usda', '171009', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('e965730e-c6f2-428a-8973-d278481eca20', 'كاتشب', 'Catsup', 'صوصات', 101.0, 1.0, 27.4, 0.1, 17.0, 'ملعقة كبيرة', 'usda', '168556', true, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;



INSERT INTO public.policies VALUES ('terms', 'الشروط والأحكام', '- يبدأ الاشتراك بعد التحقق من وصول التحويل البنكي، وتعبئة استبيان المتدرب.
- ساعات العمل: الأحد – الخميس، 12 ظهراً – 9 مساءً. الرد على الرسائل خلال 48 ساعة عمل.
- البرنامج لا يغني عن الاستشارة الطبية، والمتدرب مسؤول عن الإفصاح عن أي إصابة أو حالة صحية.
- الجداول ملك المتدرب مدى الحياة ويمكنه التعديل عليها.
- الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي.', 0, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.policies VALUES ('refund', 'الضمان والاسترجاع', '- في اشتراكات 3 أشهر لباقات المتابعة (المكثفة، المتقدمة، الأساسية): يُسترد المبلغ كاملاً إذا لم يتحسن أي من مؤشرات التقدم (متوسط الوزن الأسبوعي، محيط الخصر، القوة في التمارين الأساسية) بعد 12 أسبوعاً.
- شروط الضمان: إرسال المراجعة الأسبوعية كل أسبوع، وأخذ القياسات بانتظام، وتصوير التمارين وإرسالها، والالتزام بجدول التغذية المخصص في الباقات التي تشملها.
- يُطلب الاسترجاع عبر واتساب خلال 14 يوماً من نهاية الأشهر الثلاثة، ويُرجع المبلغ بتحويل بنكي.
- التجديد المجاني: اشتراك 3 أشهر يُكافأ بـ 3 أشهر إضافية عند التزام 90% فأكثر وتقدم واضح في مؤشرات التقدم. صور التطور تُرسل للمدربة للتوثيق (للرجال مع تغطية الوجه والسرة)، ونشرها اختياري.', 1, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.policies VALUES ('privacy', 'سياسة الخصوصية', '- نجمع: الاسم، البريد الإلكتروني (للدخول إلى حسابك)، رقم الجوال (واتساب)، الباقة المختارة، ومعلومات الاستبيان التي تكتبها بنفسك (ومنها معلومات صحية وقياسات اختيارية).
- الغرض: تنفيذ طلبك، وتصميم برنامجك ومتابعتك، والتواصل معك بخصوصه فقط.
- المعلومات الصحية تُحفظ منفصلة، ولا يطّلع عليها إلا أنت والمدربة، ولا تُرسل في رسائل البريد أو التنبيهات.
- الدفع بتحويل بنكي مباشر لحساب المؤسسة، والموقع لا يطلب أو يخزن أي بيانات بنكية أو بيانات بطاقات. إيصال التحويل يُستخدم لتأكيد طلبك فقط، ويُحفظ في تخزين خاص لا يُفتح إلا لك وللمدربة.
- لا نبيع بياناتك ولا نشاركها مع أي طرف لأغراض تسويقية، ولا تُنشر نتيجتك أو صورتك إلا بموافقتك الصريحة.
- تقدر تطلب نسخة من بياناتك أو حذفها أو سحب موافقتك على النشر بمراسلتنا على واتساب.', 2, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.policies VALUES ('reviews', 'سياسة التقييمات', '- يكتب التقييم فقط من اشترى خدمة وبدأها فعلاً، وتقييم واحد لكل طلب.
- كل تقييم يُراجع قبل ظهوره للعامة، ولا يُعدّل نصه أبداً.
- تختار بنفسك طريقة ظهور اسمك: الاسم كامل، أو الاسم الأول فقط، أو بدون اسم. والموافقة على النشر منفصلة واختيارية.
- لا يُنشر تقييم يحتوي أرقام هواتف أو بريد أو روابط أو تفاصيل صحية خاصة أو إساءة لأي شخص.
- يحق للمدربة الرد على التقييم، أو إخفاء التقييم المخالف لهذه السياسة مع تسجيل السبب.
- تقدر تطلب إخفاء تقييمك في أي وقت بمراسلتنا على واتساب.', 3, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;



INSERT INTO public.products VALUES ('d0e0968c-b924-40d2-a98b-80aaeea291c2', 'intensive', 'follow', 'الباقة المكثفة', 'الأنسب للمبتدئين ولمن يحتاج متابعة أسبوعية مع زوم: تمرين + تغذية + زوم + جلسة حضورية', '[{"text": "جلسة حضورية مجانية لمدة ساعة لتصحيح التكنيك والتأكد من جودة التمرين (للبنات في المنطقة الشرقية)", "included": true}, {"text": "ملف شامل للخطة التدريبية والتغذية مع شروحات وافية للتمارين، بالمنزل أو بالنادي", "included": true}, {"text": "4 مكالمات زوم شهرياً نتابع فيها تطورك واستفساراتك الرياضية والنفسية", "included": true}, {"text": "مناقشة أسبوعية لتطورك البدني والنفسي (فيديو أو تسجيل صوتي) مع تعديل السعرات أو التمرين عند الحاجة", "included": true}, {"text": "شرح سهل ومبسط لتطبيق حساب السعرات MyFitnessPal", "included": true}, {"text": "كتيب شامل للرياضة والتغذية", "included": true}, {"text": "مساعدتك على اختيارات أنسب لصحتك ونمط حياتك في التغذية والروتين اليومي", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}]', NULL, 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.', true, NULL, 'published', 0, false, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('797ba159-5cbb-4794-8a3d-5abab144ed76', 'advanced', 'follow', 'الباقة المتقدمة', 'لمن عنده خبرة ويحتاج تمرين + تغذية مع متابعة أسبوعية، بدون زوم', '[{"text": "ملف شامل للخطة التدريبية والتغذية مع شروحات وافية للتمارين، بالمنزل أو بالنادي", "included": true}, {"text": "مناقشة أسبوعية لتطورك البدني والنفسي (فيديو أو تسجيل صوتي) مع تعديل السعرات أو التمرين عند الحاجة", "included": true}, {"text": "كتيب شامل للرياضة والتغذية", "included": true}, {"text": "مساعدتك على اختيارات أنسب لصحتك ونمط حياتك في التمرين والروتين اليومي", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}, {"text": "مكالمات زوم والجلسة الحضورية (في المكثفة فقط)", "included": false}]', NULL, 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.', false, NULL, 'published', 1, false, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('222b9ce4-b4e4-49f9-bcec-3f85c6c66b87', 'basic', 'follow', 'الباقة الأساسية', 'لمن يعرف يضبط أكله ويحتاج خطة تمرين فقط، ومتابعة كل أسبوعين', '[{"text": "ملف شامل للخطة التدريبية مع شروحات وافية للتمارين، بالمنزل أو بالنادي", "included": true}, {"text": "مناقشة كل أسبوعين لتطورك البدني والنفسي (فيديو أو تسجيل صوتي) مع تعديل التمرين عند الحاجة", "included": true}, {"text": "كتيب شامل للرياضة والتغذية", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}, {"text": "بدون خطة تغذية", "included": false}]', NULL, 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.', false, NULL, 'published', 2, false, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('33c5a64f-c8bb-4e5f-8840-ba35cf9de6b3', 'nutrition', 'follow', 'باقة التغذية', 'لمن يحتاج خطة تغذية شاملة ويتعلم حساب السعرات، بدون خطة تمرين', '[{"text": "خطة تغذية شاملة تناسب هدفك ونمط حياتك", "included": true}, {"text": "تحديد السعرات المناسبة لك ولهدفك", "included": true}, {"text": "تعليمك حسبة السعرات ومساعدتك باختيارات تغذية تناسبك", "included": true}, {"text": "ملف Excel لمتابعة التطور والقياسات", "included": true}, {"text": "مناقشة أسبوعية لعلاقتك بالتغذية في المنزل أو خارجه", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}, {"text": "لا تحتاجها إذا كنت مشتركاً في المكثفة أو المتقدمة، لأن التغذية ضمنها", "included": false}]', 'شهر واحد · غالباً لا تحتاج تجديد', 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي، ولا يوجد تجديد تلقائي. ضمان الاسترجاع يشمل اشتراكات 3 أشهر للمكثفة والمتقدمة والأساسية فقط.', false, NULL, 'published', 3, false, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('02015451-475d-4266-bd20-b6e0e5bce9df', 'custom-training-plan', 'files', 'بديل التدريب الشخصي', 'لمن لا يحتاج متابعة (متقدم)، أو كبديل أوفر للتدريب الشخصي', '[{"text": "جدول تمرين مخصص لعدد أيام التمرين اللي تحتاجها", "included": true}, {"text": "طريقة حساب الجهد وعدد الجولات المطلوبة", "included": true}, {"text": "تقدر تحمّل الجدول على جهازك", "included": true}]', NULL, 'جدول مخصص بعد الاستبيان تستلمه كملف، وتقدر تحمّله على جهازك. بدون متابعة.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي. الجداول لك مدى الحياة وتقدر تعدّل عليها.', false, NULL, 'published', 4, false, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('707e8c88-63e1-4fe0-9e8c-fe873a54dc8d', 'training-nutrition-plan', 'files', 'جدول تمارين مع التغذية', 'لمن لا يحتاج متابعة (متقدم)، أو كبديل أوفر للتدريب الشخصي', '[{"text": "جدول تمرين مخصص لعدد أيام التمرين اللي تحتاجها", "included": true}, {"text": "طريقة حساب الجهد وعدد الجولات المطلوبة", "included": true}, {"text": "جدول تغذية فيه خيارات تناسب هدفك الرياضي", "included": true}, {"text": "تقدر تحمّل الجدول على جهازك", "included": true}]', NULL, 'جدول مخصص بعد الاستبيان تستلمه كملف، وتقدر تحمّله على جهازك. بدون متابعة.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي. الجداول لك مدى الحياة وتقدر تعدّل عليها.', false, NULL, 'published', 5, false, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('96c99801-5d49-4dc4-acba-748c3594d6d0', 'nutrition-consultation', 'consult', 'جلسة استشارة تغذية', 'لمن عنده أسئلة محددة في التغذية: جلسة وحدة تكفي لحسبة سعراتك ونصائح الأكل.', '[{"text": "مناقشة كل أسئلتك في مجال التغذية", "included": true}, {"text": "حسبة سعرات مناسبة لهدفك مع اقتراحات لأصناف الطعام", "included": true}, {"text": "نصائح في المكملات، وكيف تأكل برّا بطريقة صحيحة", "included": true}]', NULL, 'جلسة عبر Google Meet أو واتساب — المناسب لك.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي.', false, NULL, 'published', 6, false, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('7fb84637-5f2c-465e-8891-f198de649a21', 'training-consultation', 'consult', 'جلسة استشارة تمرين', 'لمن عنده أسئلة محددة في التمرين: جلسة وحدة تكفي لتعديل جدولك وتصحيح التكنيك.', '[{"text": "مناقشة كل أسئلتك في مجال التمرين", "included": true}, {"text": "تعديل جدولك الرياضي بما يناسب هدفك، مع اقتراحات لتمارين المرونة", "included": true}, {"text": "تصحيح تكنيك التمارين اللي تشك إنها غلط أو تسبب لك ألم", "included": true}, {"text": "التأكد من أن جودة تمرينك مناسبة للبناء العضلي", "included": true}]', NULL, 'جلسة عبر Google Meet أو واتساب — المناسب لك.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي.', false, NULL, 'published', 7, false, '2026-09-28 14:00:42.441495+00', '2026-09-28 14:00:42.441495+00', false) ON CONFLICT DO NOTHING;



INSERT INTO public.product_offers VALUES ('847d9b13-c646-436d-b89d-a5a75b4e695d', 'd0e0968c-b924-40d2-a98b-80aaeea291c2', 'int1', 'شهر واحد', 1, 59900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('4a5b7c3a-4f3f-4533-879c-a73e8f0bc8f6', 'd0e0968c-b924-40d2-a98b-80aaeea291c2', 'int3', '3 أشهر', 3, 155000, 'SAR', true, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('76dab339-faa7-4aa0-8972-0041f21cfbfd', '797ba159-5cbb-4794-8a3d-5abab144ed76', 'adv1', 'شهر واحد', 1, 49900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('8ba5a567-4a44-4a7e-9d22-dfb1c8dfdafb', '797ba159-5cbb-4794-8a3d-5abab144ed76', 'adv3', '3 أشهر', 3, 125000, 'SAR', true, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('f30b2273-3031-44ac-a7c8-cd33c4061c12', '222b9ce4-b4e4-49f9-bcec-3f85c6c66b87', 'bas1', 'شهر واحد', 1, 34900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('82be873e-43a5-412f-a6fa-212befc29558', '222b9ce4-b4e4-49f9-bcec-3f85c6c66b87', 'bas3', '3 أشهر', 3, 95000, 'SAR', true, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('f514a0e3-ddf4-49d0-8744-7aa333de23b2', '33c5a64f-c8bb-4e5f-8840-ba35cf9de6b3', 'nut1', 'شهر واحد', 1, 25000, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('ae57d372-2a9e-4778-8198-bb29a7ecc5bc', '02015451-475d-4266-bd20-b6e0e5bce9df', 'diy', 'دفعة واحدة', 0, 19900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('163bf1b5-9cc2-4e7c-ba82-7308c3cedac7', '707e8c88-63e1-4fe0-9e8c-fe873a54dc8d', 'diyN', 'دفعة واحدة', 0, 25000, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('42714060-452b-465f-b413-95104572b963', '96c99801-5d49-4dc4-acba-748c3594d6d0', 'cN', 'دفعة واحدة', 0, 15000, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('75ce6ffb-e83c-4c90-bee1-a0e9bac70246', '7fb84637-5f2c-465e-8891-f198de649a21', 'cT', 'دفعة واحدة', 0, 18900, 'SAR', true, 0) ON CONFLICT DO NOTHING;



INSERT INTO public.reviews VALUES ('edb177da-7c63-4a7e-a334-c9feaee47b43', 'legacy', NULL, NULL, NULL, NULL, 'اشتركت معها 3 شهور وكانت أول مره التزم بالتمرين بعد سحبات سنين، اسلوبها سهل وسريع بس نتايجه واضحه من اول اسبوعين قياسات جسمي بدت تتغير والكوتش مريحه نفسيًا وشاطرة الله يعطيها العافيه غيرت حياتي واعطتني افضل بداية 🙏🏻', 'first', 'ريم', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 0, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('a9604cd5-8650-45b1-ba54-ea7ed3236da5', 'legacy', NULL, NULL, NULL, 5, 'من أصدق التجارب اللي مرّيت فيها! تدريبك ما كان بس جداول رياضه وتغذية كان دعم نفسي وتحفيز وتغيير حقيقي في حياتي حسّيت بفرق كبير في جسمي وطاقتي وثقتي بنفسي من أول أسبوع شكراً من القلب على تعبك وحرصك على كل تفصيلة وتعطي من قلبك، فعلاً you are the best coach ever تستاهلين كل النجاح والله ❤️', 'first', 'نورة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 1, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('79032973-70ec-4fe6-a3b5-d50733a9be45', 'legacy', NULL, NULL, NULL, 5, 'بعد شهر من الالتزام بالجدول، لاحظت فرق واضح! متنوع وفعال، أنصح فيه بشدة 😍👌', 'first', 'البندري', 'مارس 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 2, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('e1d40d87-3419-458d-a0b2-58cb629c672e', 'legacy', NULL, NULL, NULL, NULL, 'رغم ان فتره تدريبي معاها كانت اقل من شهرين السنه الماضيه الا ان نتايج هالشهرين مستمره معي الى اليوم 😍 اسلوب احترافي وفعال وتركز على بناء وتطوير عادات تدوم مو بس تمارين مؤقته 👍🏻', 'first', 'خديجة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 3, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('adc80df7-aece-4080-bc4f-8ea08f3fdfbe', 'legacy', NULL, NULL, NULL, 5, 'كوتش ساره جداً شاطره و بروفيشنال، جداً متعاونه و تعرف شغلها كويس، جداً لطيفه، كنت لفتره متدربه عندها و كنت أشوف نتايج بطله بالاضافه لكوني اروح اتمرن و أنا مستمتعه، شكراً ساره', 'first', 'نجمة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 4, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('858cb0be-d9bb-4bcd-9feb-92aea88bb955', 'legacy', NULL, NULL, NULL, 5, 'ممتاز جدول حلو ومرتب جدا وفرق معي كثير 🤍', 'first', 'سعود', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 5, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('bb301eb5-4f38-40cf-b1ea-8fea6e085921', 'legacy', NULL, NULL, NULL, 5, 'كنت اعاني من الم بظهري مستمررر سنوات وانحراف بالعمود ولكن بفضل الله ثم المدربة تحسنت بنسبة كبيرة وتابع معي خطوة بخطوة بكل أمانة وإتقان الله يكثر من امثالك 🤍', 'first', 'ش**س**', 'أغسطس 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 6, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('0eeee79e-67ab-455a-87ea-2726b7d11ead', 'legacy', NULL, NULL, NULL, 5, 'الشكر يعجز عنك يااروع كوتش باشتراكي معك شفت صحة وراحة بعد الله وساعدتيني مره بمشكلة ظهري وضعف العضلات العلوية وانعكس على نفسيتي وادائي اليومي شكررا شكرا من القلب وياحظنا فيك', 'first', 'فاطمة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 7, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('c7e8fc75-62d3-4ba7-8d97-e35c2ae511f4', 'legacy', NULL, NULL, NULL, 5, 'مره استفدت بالتدريب مع كوتش ناف و مبسوطه ان في احد بذمة و ضمير جالس يتابع تقدمي و ينصحني من قلب الله يسعدك ويوفقك ❤️', 'first', 'ميثاء', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 8, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('4c4f119c-2f7c-480c-82e0-db1222f531d0', 'legacy', NULL, NULL, NULL, 5, 'تجربه ولا أروع ! أحب جداولها وقد ايش تختصر وتعطيك المهم والاهم والنتايج رهيييبه ❤️', 'first', 'أمجاد', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 9, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('ebdea4e4-5ea0-474f-8db3-625f51523a22', 'legacy', NULL, NULL, NULL, 5, 'افضل مدربة بالمجرة، كنت دبه ونحفت بثلاث شهور بس، i highly recommend her she is the best 💗', 'first', 'شروق', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 10, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('c8734957-fda0-4461-a24e-41ba05d3642d', 'legacy', NULL, NULL, NULL, 5, 'الجدول ممتاز و فعّال لفترة الصيام، يساعدك تنظم وقتك ويقدّم توصيات غذائيه و خطه تمارين تساعدك تحافظ على لياقتك بدون إرهاق 👍🏻. خيار ممتاز خاصة للأشخاص للي وقتها محدود ومزحوم فرمضان.', 'first', 'خديجة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 11, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;



INSERT INTO public.site_settings VALUES ('reminders', '{"review_text": "مرحباً {name}، تذكير بمراجعتك الأسبوعية: المراجعة مفتوحة من {window_start} إلى {window_end}.", "sub_expiry_days": [7, 3], "sub_expiry_text": "مرحباً {name}، اشتراكك في {product} ينتهي بتاريخ {end_date}. للتجديد أو الاستفسار تواصل معنا.", "review_lead_days": 1, "missed_review_text": "مرحباً {name}، ما وصلتنا مراجعة الأسبوع المنتهي في {window_end}. متى ما تيسّر لك، حدّثها عشان نتابع تقدمك.", "review_window_days": 2, "manual_cooldown_minutes": 10}', false, NULL, '2026-09-28 14:00:41.841295+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('hero', '{"lead": "خطة تدريب وغذاء منظمة، متابعة للتقدم، وتعديلات أسبوعية تناسب مستواك وظروفك.", "title": "برامج تدريب وتغذية مخصصة لأهدافك", "eyebrow": "Nav Coaching · الكوتش ساره", "tagline": "Where Passion Meets Quality", "title_tail": "تحت إشراف مدربة يدفعها الشغف"}', true, NULL, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('badges', '["خصم 10% للطلاب", "مجاني لأهل غزة", "ضمان استرجاع المبلغ بشروط"]', true, NULL, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('why', '[{"body": "البرنامج يُصمم بعد استبيان مفصل لهدفك وأيامك المتاحة وأدواتك وأي إصابة تحتاج مراعاة.", "title": "مبني على هدفك ومستواك"}, {"body": "مراجعة منتظمة بالفيديو أو الصوت، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.", "title": "متابعة أسبوعية واضحة"}, {"body": "نعدّل التمرين والسعرات بناءً على قياساتك والتزامك، عشان تثبت النتيجة.", "title": "تعديلات حسب تقدمك"}]', true, NULL, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('how_steps', '[{"body": "اختر الباقة والمدة، وعبّي استبيان قصير عن هدفك ومستواك وأيامك وأي إصابة.", "title": "اختر برنامجك وعبّي الاستبيان"}, {"body": "بعد الاستبيان يظهر لك رقم طلبك وبيانات الحساب. حوّل وارفع صورة الإيصال من صفحة طلبك.", "title": "حوّل المبلغ"}, {"body": "بعد التحقق من التحويل أتواصل معك خلال 48 ساعة عمل، وتستلم ملف برنامجك وتبدأ المتابعة.", "title": "استلم برنامجك وابدأ"}]', true, NULL, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('about', '{"bio": "مدربة شخصية معتمدة، أدرب منذ 2017. أساعدك تبني روتين تدريب وتغذية واضح يناسب هدفك ووقتك ومستواك، مع متابعة أسبوعية تساعدك تستمر وتتقدم.", "fit": ["اللي يؤمن إن التمرين أسلوب حياة، مو تمرين لشكل مؤقت أو لفترة الصيف بس.", "**وإذا ما التزمت؟** أحاول أفهم أسبابك، وأساعدك تعالجها بقدر ما أقدر. وإذا كان الموضوع أكبر من اللي أقدر أقدمه، أقول لك بصراحة وأعتذر عن تدريبك."], "name": "الكوتش ساره | ناڤ", "certs": ["Saudi Reps — Level 4", "NCSF", "Menno Henselmans CPT", "Functional Mobility", "Pre & Postnatal Training", "Prenatal Fitness Training — Aspire Academy", "ماجستير تدريب رياضي — جامعة ستيرلنق"], "notes": [{"body": "لأني جاية من عالم الرياضات الإلكترونية، صممت باقة خاصة للقيمرز: لياقة أفضل داخل وخارج الشاشة، والتعامل مع آلام الظهر والمفاصل من الجلوس الطويل.", "href": "/programs/gamers", "label": "شوف باقة القيمرز ←", "title": "للاعبي الألعاب الإلكترونية"}, {"body": "تدريب الحوامل عندي حضوري فقط. أونلاين يصعب أتأكد إن التمرين يتنفذ بإتقان، والحمل فترة مهمة جداً تحتاج هالتأكد. أونلاين أقدم للحوامل متابعة التغذية فقط.", "href": "", "label": "", "title": "للحوامل"}], "story": ["قبل ما أصير مدربة، كنت متدربة تعبت من التجارب. اشتركت مع مدربات أجانب، وما لقيت أحد يشرح لي التمرين صح أو يهتم بأهدافي.", "لين اشتركت مع الكوتش سحر الحارثي. غيّرت نظرتي للتمرين، وحفّزتني أصير كوتش، وإلى اليوم أشكرها على كل اللي علمتني إياه. من هنا قررت أكون الشخص اللي احتجته أنا.", "والرياضة جزء مني من بدري: لعبت كرة السلة وكنت كابتن فريق السلة في جامعة الإمام عبدالرحمن بن فيصل، ولعبت باحتراف في الرياضات الإلكترونية. بدأت التدريب في 2017 مع كرة السلة، واشتغلت مساعد مدرب في نادي الجامعة، وبعدها دربت في بيور جم وجمنيشن وفتنس لاونج ونوادي خاصة."], "points": ["برنامج مبني على هدفك ومستواك.", "متابعة أسبوعية واضحة.", "تعديلات مستمرة حسب تقدمك والتزامك."], "pillars": [{"body": "ما أرسل لك جدول وأتركك. أراجعه معك بمقطع فيديو أشرح فيه كل شي، عشان تبدأ وأنت فاهم وش تسوي وليش.", "title": "جدولك مشروح بالفيديو"}, {"body": "ما أمشي على أنظمة الحرمان أبداً. خطتك تناسب حياتك، مو قائمة ممنوعات.", "title": "بدون حرمان"}, {"body": "أتابعك كل أسبوع وأهتم بالتزامك، وأعدّل خطتك حسب تقدمك وظروفك.", "title": "متابعة جادة وخطة واقعية"}, {"body": "حب تعليم الناس معي من الصغر. اللي أعرفه ما أبخل فيه، علمياً ونفسياً، وما أوقف عن البحث والتعلم عشان أتطور وأطورك معي.", "title": "أعلّمك، مو بس أدربك"}], "home_bio": "مدربة شخصية معتمدة، أدرب منذ 2017، وكابتن سابقة لفريق السلة في جامعة الإمام عبدالرحمن بن فيصل. أساعدك تبني روتين تدريب وتغذية واضح يناسب هدفك ووقتك ومستواك، مع متابعة أسبوعية وبدون أنظمة حرمان.", "fit_title": "أكثر شخص أفرق معه", "experience": ["أدرب منذ 2017، والبداية في كرة السلة.", "مساعد مدرب في نادي الجامعة.", "مدربة في بيور جم، وجمنيشن، وفتنس لاونج، ونوادي خاصة."], "story_title": "صرت الشخص اللي كنت أحتاجه", "pillars_title": "وش يميز التدريب معي؟", "experience_title": "شهاداتي وخبرتي"}', true, NULL, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('intro_video', '{"url": "", "body": "مقطع قصير أتكلم فيه عن نفسي وخلفيتي وطريقة شغلي مع المتدربين.", "title": "تعرّف عليّ في دقيقة"}', true, NULL, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('testimonials_disclaimer', '"التجارب شخصية وتختلف النتائج من شخص لآخر حسب الالتزام والحالة، والتدريب لا يغني عن استشارة الطبيب أو أخصائي العلاج الطبيعي."', true, NULL, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('prices_note', '"الأسعار بالريال السعودي. الدفع بتحويل بنكي على حساب المؤسسة."', true, NULL, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('checkins', '{"enabled": true, "questions": [{"q": "ملاحظاتك الصحية؟ الحركة اليومية وجودة الحياة صارت أحسن؟", "topic": "الصحة العامة"}, {"q": "أداؤك في التمارين؟ في تقدم في الأوزان والأداء؟", "topic": "التمارين"}, {"q": "فرق في شكلك ومظهرك؟ إيجابي أو سلبي؟", "topic": "المظهر"}, {"q": "فرق في الملابس أو المقاسات؟ إيجابي أو سلبي؟", "topic": "الملابس"}, {"q": "النظام الغذائي — قدرت تمشي عليه؟ فيه صعوبة؟", "topic": "الغذاء"}, {"q": "تحسّ بالجوع واجد؟ إن وُجد، كم تعطيه من 5؟", "topic": "الجوع"}, {"q": "أي ملاحظات سلبية تبي تشاركها؟ (مهمة أو بسيطة — نتقبل النقد)", "topic": "ملاحظات سلبية"}, {"q": "أي إشكاليات أو ملاحظات إضافية تحتاج مساعدة فيها؟", "topic": "ملاحظات أخرى"}, {"q": "وصلت لأي أسبوع تدريبي الآن؟", "topic": "الأسبوع"}]}', true, NULL, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('contact', '{"whatsapp": "966599162724", "instagram": "https://www.instagram.com/navvcoaching/"}', true, NULL, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('response_time', '"48 ساعة عمل (الأحد – الخميس، 12 ظهراً – 9 مساءً)"', true, NULL, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('legal', '{"cr": "7050950752", "name": "مؤسسة ناف كوتشنق للتدريب الرياضي"}', true, NULL, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('bank', '{"iban": "SA1280000139608016245411", "bankName": "مصرف الراجحي", "accountName": "مؤسسة ناف كوتشنق للتدريب الرياضي"}', true, NULL, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('program_shots', '[{"h": 720, "w": 754, "alt": "لقطة من صفحة «حسابي» ببيانات مثال: شريط الالتزام، أيام تمرين الأسبوع الحالي، ملخص تغذية اليوم، وروتين المكملات", "src": "shots/my-program.webp", "title": "برنامجي", "caption": "أول ما تدخل حسابك: نسبة التزامك وأسابيعك المتتالية، أيام تمرين الأسبوع، تغذية اليوم مقابل أهدافك، وروتين المكملات."}, {"h": 960, "w": 1148, "alt": "لقطة من صفحة برنامج التمرين ببيانات مثال: أيام الأسبوع، وبطاقة كل تمرين مع المستهدف وخانات الوزن والتكرارات وRIR", "src": "shots/training-log.webp", "title": "تسجيل التمرين", "caption": "لكل تمرين المستهدف من الجولات والتكرارات وRIR، وتسجّل وزنك وتكراراتك من جوالك، ولك تبديله ببديل تختاره المدربة."}, {"h": 1020, "w": 1148, "alt": "لقطة من صفحة التغذية ببيانات مثال: ملخص اليوم مقابل الأهداف، ونموذج إضافة أكلة، وأكل اليوم حسب الوجبات", "src": "shots/nutrition-day.webp", "title": "التغذية اليومية", "caption": "أهدافك اليومية من السعرات والماكروز وكم باقي لك، وتسجّل أكلك من جداولك الغذائية أو بالغرام من قاعدة الأكل."}, {"h": 307, "w": 1116, "alt": "لقطة من لوحة التقدم ببيانات مثال: رسم الوزن ورسم القياسات", "src": "shots/progress-charts.webp", "title": "لوحة التقدم", "caption": "وزنك وقياساتك برسوم واضحة أسبوعاً بأسبوع، ببيانات مثال."}]', true, NULL, '2026-09-28 14:00:42.441495+00') ON CONFLICT DO NOTHING;
COMMIT;
