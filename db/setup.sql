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

-- ---------- المحتوى المستورد من الموقع الحالي ----------
INSERT INTO public.exercises VALUES ('a5d11f5e-ee19-4d6f-b352-97b68de45e2e', 'Back Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/bEv6CCg2BC8', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('90f0b87b-a046-4721-8faa-1a039d901414', 'Box Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtube.com/shorts/9uhEh9gpwUU?si=xaTY7AJiCeQfa3by', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل.', 'تعليمات بديلة في المصدر (صف 13): ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل، انزل واثبت على البوكس ثانية وارفع.', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8b6e3842-ae29-41f2-a1d9-6163de3666a6', 'Hack Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/0tn5K9NlCfo', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Machine Squat / سكوات بالجهاز', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c2f89c47-2255-4bdf-baa2-5d9be2d97a94', 'Mid Leg Press', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/s9-zeWzPUmA', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Leg Press / ضغط الأرجل', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('494b7262-2230-443f-94ec-065abc700d89', 'Quads Leg Press', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/A218isnErfM', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي، ثبت القدمين أسفل اللوح لاستهداف أكبر للكوادز.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Leg Press / ضغط الأرجل', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('963a79d6-1afb-4d57-b70b-d003aea93da7', 'Deficit Goblet Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/9719SO5zvpU?si=whohbunAsXkH3j6f', 'وقف باتساع اكتافك تقريبًا، ادفع ركبك للامام وانزل، انزل لأقصى حد تقدر عليه بدون ما يتقوس ظهرك السفلي.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8f1856ef-9808-4556-afd3-60538b886863', 'Front Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'بار', 'متوسط', 'نادي', NULL, 'ثبت البار على الأكتاف، ادفع ركبك للامام وانزل.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5690a819-0d6c-4c29-b963-031174f8aae0', 'V Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://www.youtube.com/watch?v=u_GSjH58s0g', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Machine Squat / سكوات بالجهاز', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b9346494-c920-4a7c-a771-89e02bdad829', 'Resistance Band Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/6rE0IYlMPZA?si=goqtRTlR_W4HSGBN', 'ثبت الباند علي جوانب اكتافك، ادفع ركبك للأمام وإنزل.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('bdce7900-3d1d-46e7-8f86-ce4201d73b40', 'Squat Smith Machine', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/oBwhrRcNWyM', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Machine Squat / سكوات بالجهاز', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('998b46f5-52fe-4dbc-9867-1c6070584f76', 'Single Leg Press', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/ZYDTJaAM-gE', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Single-leg Press / ضغط رجل واحدة', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f0749f1e-5c91-4e2e-af90-c47b1c6cc148', 'Drop Lunges', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/WH8lteLrMIs?si=61QSVA7iw_Z6Zr3p', 'تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6d0e5bd4-fd84-4814-9e49-5443ef93ca48', 'Beginner Lunges', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/QOVaHwm-Q6U', 'تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4fe5c32a-7183-4ec2-b14c-14a3f3199016', 'Forward Lunges', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/_DLAdo2Pvjs', 'تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness | ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ae409910-e27d-4fbe-9758-0829bc88cf38', 'Supported BSS', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/poBie3TTeGE?si=QSiMUYtcHhrmg8mx', 'وقف عند البنش او الستيب، ارفع رجلك وثبت اصابع قدمك على البنش، خذ خطوة وحدة للأمام برجلك الثانية ثم ابدأ التمرين، تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Split Squat / سبليت سكوات', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ac436bb1-0cbc-400d-89fe-207df5bf17ee', 'Supported Reverse Lunge', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/WH8lteLrMIs?si=M9s9a7qOVvvyDm82', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('82bf0d45-647b-4dce-83fd-53dbcdc33257', 'Smith Machine Reverse Lunge', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/zAVYcwnlxrQ?si=M5HL4sG-bsYBFyDQ', 'استخدم ارتفاع بسيط مثل الستيب ، ارفع نفسك بالضغط علي الرجل المرفوعة بتحكم بدون قفز.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7e997159-159a-4464-9502-f4afe00ac393', 'Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/gtZ4AwZVtMI', 'اجلس وثبت ظهرك السفلي كويس، تأكد ان مسمار الارتفاع يكون بمستوى ركبتك، امسك المقابض لزيادة الثبات، إرفع الوزن اثبت ثانية فوق ثم انزل نزول كامل بتحكم.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8668146a-0ca6-4c82-8da6-dac9b43654ae', 'Single Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/82IuSLk5zNc?si=FTMqZrmawQFRr8dN', 'اجلس وثبت ظهرك السفلي كويس، تأكد ان مسمار الارتفاع يكون بمستوى ركبتك، امسك المقابض لزيادة الثبات، إرفع الوزن اثبت ثانية فوق ثم انزل نزول كامل بتحكم.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3652db69-0204-4a82-ab8b-5164fefd6f2b', 'Band Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/hs7D3gDw3UM', 'اجلس وثبت ظهرك السفلي كويس وامسك الكرسي للثبات، اثبت ثانية فوق ثم انزل نزول كامل بتحكم.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cb8e3acd-ba6e-4ae1-bc7c-94fdcf630db5', 'Standing Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/fyF6FQOUGDI', 'الحركة كلها بثني ومد الركبة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d8ed9d02-4063-438a-ae7c-d6f3ab856049', 'Sissy Squat', 'Quadriceps / الأمامية', '{"Adductors / الأفخاذ الداخلية"}', 'Knee Extension / مد الركبة', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://youtu.be/yONKTprKCDA', 'الورك ثابت طول الجولة والحركة كلها من مفصل الركبة، اذا توازنك يخرب عليك ادبل الوزن بيد واليد الثانية امسك فيها جدار او عصى', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Sissy Squat / سيسي سكوات', 'Knee Extension / مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5c893433-0709-438c-b582-fa608f45a8f1', 'Cable Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/ebjD98gZd8E', 'اجلس وثبت ظهرك السفلي كويس وامسك الكرسي للثبات، اثبت ثانية فوق ثم انزل نزول كامل بتحكم.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d06fa4f5-d5b7-4f37-844b-494d11b69e2b', 'Standing Leg Extension', 'Quadriceps / الأمامية', '{"Core / البطن والكور"}', 'Knee Extension / مد الركبة', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/133/standing-leg-extension/', NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fcb0fc40-657c-4f12-9a5e-76829ccf0580', 'Bodyweight Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Lower back / أسفل الظهر"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/135/bodyweight-squat/', NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c18f4c5a-5681-46f2-b15e-c6d844eb06af', 'Single Leg Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'وزن الجسم', 'متقدم', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/136/single-leg-squat/', 'ضعف الألوية الكبرى / Gluteus Maximus Weakness | ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Single-leg Squat / سكوات رجل واحدة', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4cf3afd9-fb58-4da9-aada-ffd1d396c9e9', 'DB Glutes Step Ups', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/GCnJiYJfboA?feature=share', 'استخدم ارتفاع يكون بحدود ارتفاع ركبتك أو أقل، ارفع نفسك بالضغط علي الرجل المرفوعة بتحكم بدون قفز.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('bffbaf70-aeb4-49e7-9452-f7e2cfd4c3ea', 'Supported Glutes Step Ups', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/ZKzoOkQALaY?si=-56txwBlxSSCQYJd', 'استخدم ارتفاع يكون بحدود ارتفاع ركبتك أو أقل، ارفع نفسك بالضغط علي الرجل المرفوعة بتحكم بدون قفز.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d333dda7-ba47-4e57-a355-333a6e76fbed', 'Cable Glutes Step Ups', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3173ec0b-4321-4448-9613-19e9a74d0266', 'Glute Pushdown', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/8h2kZ64Sp5k?si=NLPf4tywxhDGY9em', 'تمسك بمقابض الجهاز، (كل ما زاد ارتفاع البنش زادت الصعوبة) + الطلوع والنزول يكون بواسطة القدم المرفوعة على البنش مو بالقدم اللي تحت، ارفع بتحكم الى أقصى ارتفاع تقدرعليه بدون ما يتقوس ظهرك السفلي، انزل لحد ما تقفل ركبتك تماما', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('34294e90-d32e-4c7d-9c5e-1ba3707a9e8b', 'Glute Max Kickbacks', 'Glutes / المؤخرة', '{}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/t5mwSx4uNMc?feature=share', 'ثبت الحبل على الكاحل، ارجع خطوة للخلف وانحني للامام قليلاً وتمسك بالكيبل لزيادة الثبات، اسحب للخلف مع انثناء بسيط بالركب.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Kickback / ركلة خلفية', 'Hip Extension / بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('84b0059f-2697-4bc1-b2e9-5ea444a6500a', 'Hip Abduction', 'Abductors / مبعدات الفخذ', '{"Glutes / المؤخرة"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/_ARUxqrII3Y?si=Jcz5uh2Uu-IdVCS1', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2751a1a5-d3d4-48d7-bd55-7739f01c560c', 'Smith Machine Kickback', 'Glutes / المؤخرة', '{}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/GR4ny80bmhM?si=WeZcWM1hyfoLElM2', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Kickback / ركلة خلفية', 'Hip Extension / بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d2e5bf68-021b-4550-a171-33d9bd98d35d', 'Glute Medius Kickbacks', 'Abductors / مبعدات الفخذ', '{"Glutes / المؤخرة"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/kccsnZNbMFA?si=6c-VoB8Zsz8NxoyM', 'ثبت الحبل على الكاحل، ارجع خطوة للخلف وانحني للامام قليلاً وتمسك بالكيبل لزيادة الثبات، اسحب للخلف وللخارج مع انثناء بسيط بالركب.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Abduction Kickback / ركلة خلفية مع تبعيد', 'Hip Abduction + Hip Extension / تبعيد الورك + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5d4be35c-b048-4c58-bac1-455aa392725f', 'Side Step Up', 'Glutes / المؤخرة', '{"Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/xOwIRnI4VxA?si=SJOgODRmNGdfHPb4', 'يد فيها الوزن واليد الثانية سندها على الجدار', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية المتوسطة / Gluteus Medius Weakness | ضعف الألوية الصغرى / Gluteus Minimus Weakness', 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f9db8317-7f1e-4ded-b3a7-1c852d2af071', 'Hip Thrusts Machine', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/0xfdeCBwoYw?si=HgJcNeB0a24gODkK', 'ممكن تسويه بالسميث مشين او البار الحر ، اختر بوكس او بنش يكون بمستوى اكتافك الخلفية وانت جالس، لما ترفع البار فوق المفروض ركبك تكون بنفس مستوى القدم.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('85b69bb7-18a3-4673-a213-0f033747be1b', 'Hip Thrusts', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/O0EoaP7gR1A?si=cGPZ8iIwM2mQjwSb', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0789410c-b33e-4c7c-900a-534910fbfc35', 'Glute Bridge', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', NULL, 'مبتدئ', NULL, 'https://www.youtube.com/watch?v=dtlGynVdHYM', 'ممكن تسويه بالسميث مشين او البار الحر ، اختر بوكس او بنش يكون بمستوى اكتافك الخلفية وانت جالس، لما ترفع البار فوق المفروض ركبك تكون بنفس مستوى القدم.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness | آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9bc9d946-dc35-4ce5-b93f-3a1cd9806db8', 'DB Floor Glute Bridge', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/iOrJXNUH3to?si=JySX6JMhoP2vWEVa', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness', 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c257f17a-7a01-4c6e-8c26-51e2fbda401f', 'Glute Raise', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/X_kL_x4m77c', 'ثبت رجولك تحت، الاسفنجة تكون تحت الورك أعلى الفخذ مو على الورك مباشرة، امسك وزن بيدينك بذراع مستقيمة، ارفع وكأنك تبي تدخل القلوتس جوا الاسفنجة، بمجرد ما تنقبض مؤخرتك وقف لا ترفع أكثر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', '45° Hip Extension / بسط الورك على جهاز الظهر', 'Hip Extension / بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('443e91f6-fd24-4e23-943e-455d2aaa97c4', 'Single Hip Thrusts', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/ymg2AMDAwrY?si=fY8kBPTDYWRMHuAs', 'اختر بوكس او بنش يكون بمستوى اكتافك الخلفية وانت جالس، لما ترفع فوق المفروض ركبك تكون بنفس مستوى القدم، التمرين صعب طبيعي تواجه صعوبة بالبداية لذلك لا تستعجل باضافة الاوزان', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ab2ab425-51fc-4d9e-8ae7-801e97e586e1', 'Glute Press', 'Glutes / المؤخرة', '{}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/293/glute-press/', NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Kickback / ركلة خلفية', 'Hip Extension + Knee Extension / بسط الورك + مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a0febfcf-ab2a-463c-9ba8-a20aa1828a86', 'Bulgarian Split Squat', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/366/bulgarian-split-squat/', NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Split Squat / سبليت سكوات', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('05cb8cb3-9f2d-4863-a6d1-275086a1e508', 'Sumo Deadlift', 'Hamstrings / الخلفية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://www.youtube.com/watch?v=cDlOSfu-zHY', 'وقف بفتحة أرجل واسعة بحيث الركب تكون خط مستقيم مع كعب القدم و اصابع الرجل باتجاه الخارج، البار بمنتصف القدم، شد ظهرك العلوي وادفع الارض برجولك واسحب البار للأعلى، وقف لما تنقبض مؤخرتك ولا تبالغ بتقفيل حوضك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Deadlift / ديدلفت', 'Hip Extension + Knee Extension / بسط الورك + مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a33ebcdb-dc75-4390-9f74-4d3f49bc7ad0', 'DB Lying Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/ZHlBSI6JPsA?si=SpBiHxluwrYE8CTP', 'ركبك ثابته على الارض، ارفع الوزن بثني ومد الركبة بدون ما يرتفع حوضك', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('09df9672-96fb-46d0-af95-aaa5861ab6c5', 'Conventional Deadlift', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/GxsLrTzyGUU', 'وقف باتساع اكتافك أو أوسع شوي، البار بمنتصف القدم، شد ظهرك العلوي وادفع الارض برجولك واسحب البار للأعلى، وقف لما تنقبض مؤخرتك ولا تبالغ بتقفيل حوضك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Deadlift / ديدلفت', 'Hip Extension + Knee Extension / بسط الورك + مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5d10d4ff-4d8c-4d94-9a09-714f12183c28', 'BB RDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/mZxxJEncsyw', 'وقف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، انزل وادفع مؤخرتك لآخر شي تقدر عليه للخلف وكأنك بتلمس جدار خلفك مع انثناء بسيط بالركب', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('58696193-f5b7-4c57-8c1f-b5eef29549a6', 'DB RDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/RApyTtH6qAo', 'وقف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، انزل وادفع مؤخرتك لآخر شي تقدر عليه للخلف وكأنك بتلمس جدار خلفك مع انثناء بسيط بالركب', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a23e824f-48fc-4875-a533-de27e522fbdf', 'SM SLDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/qlL1wnpLQj4?si=-jD_X6mIJkkI8SwX', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ba7a0f61-413e-4e7b-99f3-6aba1c93848a', 'Single DB RDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/U3prDlAbJDw?si=MRSBcSIcf9M-WQBH', 'وقف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، انزل وادفع مؤخرتك لآخر شي تقدر عليه للخلف وكأنك بتلمس جدار خلفك مع انثناء بسيط بالركب', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness', 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f707f8c6-baec-4786-bc50-b6906af5bd2d', 'SLDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/RApyTtH6qAo', 'قف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، ابدأ الحركة بدفع مؤخرتك للخلف والأعلى وانزل', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('56c8742b-0021-4d86-aa4d-79c81885ce46', 'Single DB SLDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/U3prDlAbJDw?si=MRSBcSIcf9M-WQBH', 'قف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، ابدأ الحركة بدفع مؤخرتك للخلف والأعلى وانزل', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('00e03881-a4ca-4310-b494-da3816b0740a', 'Good Morning', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/f23vXjoG2e8?si=9rkfUF_6XUEcQ3Xs', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع مؤخرتك لأقصى قدر تقدر عليه وكأنك بتلمس جدار خلفك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Good Morning / قود مورنينق', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4477ab2e-f028-496e-ae4d-c912aac39bfb', 'Seated Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/o_J6MWyt5jM', 'اجلس على الكرسي وثبت ظهرك السفلي على المقعد تمامًا، انزل لأقصى حد تقدر عليه وارفع لحد ما تستقيم ركبتك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e2b76e53-1ece-4418-996a-9cbf66dc5ea6', 'Band Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/I-HTMUrJnxs', 'ثبت الباند فوق الكعب، اجلس على طرف البنش وتمسك بيدينك لزيادة الثبات، اسحب الحبل لاقصى حد تقدر عليه واترك رجلك تستقيم تمامًا في الانبساط.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0b6a52bd-793d-4a6b-8d36-b1306237abaf', 'Lying Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/vl5nUdE9mWM', 'حوضك ثابت على البنش، ارفع الوزن بثني ومد الركبة بدون ما يرتفع حوضك عن الكرسي', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1159212c-32ae-4a5d-859a-108f2b52d39f', 'Cable Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/mBJXWg8ZOy0', 'اجلس على الكرسي وثبت ظهرك السفلي على المقعد تمامًا، ممكن تقدّم ظهرك العلوي وتمسك المقابض لزيادة الثبات، انزل لأقصى حد تقدر عليه وارفع لحد ما تستقيم ركبتك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7b4419c6-db53-4e78-8dd8-a7deb3b5fb43', 'Supine Cable Hamstring Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/sDCc1F5J8XA?si=Fi3D39aJogrB5ihd', 'الركبة ثبت مكانها، اسحب الحبل لاقصى حد تقدر عليه واترك رجلك تستقيم تمامًا في الانبساط.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3adc14a1-e06e-4cdb-8d3a-074240458467', 'Nordic Hamstring Curl', 'Hamstrings / الخلفية', '{}', 'Knee Flexion / ثني الركبة', 'قوة', 'وزن الجسم', 'متقدم', 'بدون معدات', 'https://youtu.be/Lgibr8od0yA?si=nfRetEkDRk55Bu0a', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Nordic (Eccentric) / نوردك (لامركزي)', 'Knee Flexion / ثني الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('769c8d38-ce91-43c5-a9f6-4c7ab86b773e', 'Stability Ball Hamstring Curl', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة"}', 'Knee Flexion / ثني الركبة', 'قوة', 'كرة سويسرية', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/59/stability-ball-hamstring-curl/', NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Bridge Curl / ثني الركبة مع رفع الورك', 'Knee Flexion + Hip Extension / ثني الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fe0761be-026a-4841-87a6-aecd0854d379', 'Hip Hinge', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/33/hip-hinge/', NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Hinge Drill / تمرين مفصلة الورك', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a51932c7-e8d2-4112-b28d-9412d191174d', 'TRX Hamstrings Curl', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة"}', 'Knee Flexion / ثني الركبة', 'قوة', 'TRX', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/86/trx-reg-hamstrings-curl/', NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Bridge Curl / ثني الركبة مع رفع الورك', 'Knee Flexion + Hip Extension / ثني الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3a8172cd-a930-4d80-a8e6-afbefe817d6b', 'Flat DB Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/xphvjGDZeYE', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('457b3dff-59f8-4211-a2c5-02004ceabbb0', 'DB Floor Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/UBmpZ7l5Nlk?si=kDcN-ueaTFxfKtbr', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6e02676c-ebdd-4aee-91a0-9667dd631935', 'Flat Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/vcBig73ojpE', 'استلق على بنش،القبضة بنفس مستوى الاكتاف أو أوسع قليلًا، قوّس ظهرك العلوي قليلاً، انزل لين تلمس صدرك واثبت ثانية ثم ارفع.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7801e677-b6c3-4ed1-bbfe-ab716460423a', 'Machine Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/pOCRC2kpxB8?si=02xGtrfPjiYpspMv', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d57d7f1d-ac7d-473a-8520-3461e5ee96b2', 'Feet Up Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/HrehfM1dmBE', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('48bd6d54-887d-4ee3-8b0e-610120067759', 'Torso Elevated Push Up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/noaPB7u4_CU', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا', 'تصنيف فرعي: اليدان مرفوعتان؛ زاوية الضغط بالنسبة للجذع تشبه الضغط المائل لأسفل رغم تسميته الشائعة Incline Push-up — يحدده المدرب', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Decline Press / ضغط مائل لأسفل', 'Horizontal Adduction + Shoulder Extension / تقريب أفقي + مد الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ed960741-d825-45b9-a233-a2697b36925f', 'Push Up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://youtu.be/WDIpL0pjun0?si=utydS_A8QfRIJtJm', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c02abe76-8295-4f53-80db-9c04280a14f4', 'Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://www.youtube.com/watch?v=JvOJdUtx6UQ', 'استلق على بنش،القبضة بنفس مستوى الاكتاف أو أوسع قليلًا، قوّس ظهرك العلوي قليلاً، انزل لين تلمس صدرك واثبت ثانية ثم ارفع.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4a195114-2c1e-4ac3-97ae-d4a9dca6b643', 'Paused Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://www.youtube.com/shorts/Q3GmnmJISwE', 'استلق على بنش،القبضة بنفس مستوى الاكتاف أو أوسع قليلًا، قوّس ظهرك العلوي قليلاً، انزل لين تلمس صدرك واثبت 3 ثواني ثم ارفع.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d387855e-8e6b-4e5b-a599-a805828b54de', 'Incline Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/0G2_XV7slIg', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Incline Press / ضغط مائل لأعلى', 'Shoulder Flexion + Horizontal Adduction / ثني الكتف + تقريب أفقي', 'Incline Press / ضغط مائل لأعلى') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8149ef71-3be5-4b60-a9b9-f1b10e494e9c', 'Smith Machine Incline Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/EeLLZMdg6zI?si=UVsgFN7jhXMm0vW3', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Incline Press / ضغط مائل لأعلى', 'Shoulder Flexion + Horizontal Adduction / ثني الكتف + تقريب أفقي', 'Incline Press / ضغط مائل لأعلى') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cf4d5ad1-e149-4249-82ed-9fa5bf2579be', 'Cable Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/tAILewhtCb0', 'اجلس على بنش انكلاين، اضبط الكيبل بمستوى صدرك تقريبا، ادفع الوزن للأمام باتجاه الداخل، احرص ان كوعك ما يكون بنفس ارتفاع كتفك', 'تصنيف فرعي: التعليمات تذكر بنش انكلاين، وتصنيف المصدر iso_push_chest — يُحسم بين Incline Press وعزل الصدر', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Incline Press / ضغط مائل لأعلى', 'Shoulder Flexion + Horizontal Adduction / ثني الكتف + تقريب أفقي', 'Incline Press / ضغط مائل لأعلى') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fff43558-0d0f-41b7-9671-08abc9e7fd55', 'Sternal Cable Press Around', 'Chest / الصدر', '{}', 'Horizontal Push / دفع أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/y8XQibXDnNo', 'اضبط الكيبل بمستوى صدرك تقريبا، حافظ على ذراعك قريبة من جسمك،ادفع الحبل للأمام باتجاه الداخل.', 'تصنيف فرعي: حركة مختلطة بين الضغط والـ Fly — يُحسم بين Flat Press وعزل الصدر', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Press-around / ضغط مع تقريب', 'Horizontal Adduction + Elbow Extension / تقريب أفقي + مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('75d978d9-cc0a-46a8-ac67-2c90646f7fe7', 'Machine Chest Fly', 'Chest / الصدر', '{}', 'Horizontal Adduction (Fly) / تقريب أفقي للكتف (فلاي)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Chest Isolation / عزل الصدر', 'Horizontal Adduction / تقريب أفقي للكتف', 'Chest Isolation / عزل الصدر') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6a85e81e-7ef5-468b-a6a0-b41360582b4b', 'Bar Cable Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/NhD3h6RG2TA?si=SoyNTIGB-nY2KiXl', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e6086f6b-2c2f-4b05-81cd-ee50341d1e19', 'Cable Chest Fly', 'Chest / الصدر', '{"Shoulders / الأكتاف"}', 'Horizontal Adduction (Fly) / تقريب أفقي للكتف (فلاي)', 'قوة', 'كيبل', 'مبتدئ', 'نادي', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/160/standing-chest-fly/', NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Chest Isolation / عزل الصدر', 'Horizontal Adduction / تقريب أفقي للكتف', 'Chest Isolation / عزل الصدر') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('602447ba-8a9b-4171-b6b6-a23077af1bc4', 'Bent Knee Push-up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/13/bent-knee-push-up/', NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1382130a-15d3-4fc8-b211-9d69a4a4f5c7', 'Stability Ball Push-Up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس","Core / البطن والكور"}', 'Horizontal Push / دفع أفقي', 'قوة', 'كرة سويسرية', 'متوسط', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف فرعي: الزاوية تعتمد على موضع الكرة (تحت اليدين أو القدمين) — غير محدد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/63/stability-ball-push-up/', NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6f3ad445-c833-4dea-b8f6-9d4c2b151de4', 'Cable Reardelt Rows', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/uIdXVGjcfFE', 'ثبت نفسك بالكرسي، فتحة واسعة، الكيبل بمستوى اسفل صدرك، واسحب لما تنقبض اكتافك الخلفية.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Wide-grip Row / تجديف بقبضة واسعة', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8593f083-fb57-49cf-8e63-baa3e07d0a43', 'Upper Back Horizontal Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/TSWohpfMlso', 'ثبت نفسك بالكرسي، فتحة واسعة، الكيبل بمستوى أعلى صدرك، واسحب لما تنقبض الترابز.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness', 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Wide-grip Row / تجديف بقبضة واسعة', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9f49c067-a4d1-4a59-b5d3-b6ba2bab55c3', 'DB Chest Supported Reardelt Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/x0v6GWYzI18?si=-jDt3D-ARIHouHjp', 'ثبت صدرك على الكرسي، فتحة واسعة، واسحب لما تنقبض اكتافك الخلفية.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Wide-grip Row / تجديف بقبضة واسعة', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fd8f313d-ed26-4965-a0ad-b9fb92de8379', 'Bent-over Barbell Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'بار', 'متوسط', 'نادي', NULL, 'ادفع مؤخرتك للخلف واثني ركبك، قبضتك بنفس مستوى اكتافك، اسحب لما تنقبض عضلات الظهر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('58dfa8f2-c8c9-4eef-9a6d-c9abbccac09c', 'Cable Reardelt Fly', 'Shoulders / الأكتاف', '{"Rotator cuffs / الكفة المدورة"}', 'Shoulder Rear Pull / سحب خلفي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/bkejPHrPkmA?si=-O8q_5e72udoPRiY', NULL, 'تصنيف فرعي: حركة Fly (تبعيد أفقي للكتف) وليست سحباً أفقياً أو عمودياً', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Rear Delt Fly / فتح خلفي', 'Horizontal Abduction / تبعيد أفقي للكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('04ad1381-3145-41e9-9808-b6951b25b73d', 'DB Chest Supported Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/H75im9fAUMc', 'ثبت صدرك على الكرسي، فتحة واسعة، واسحب الدمبل باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('745b2223-a012-4dc8-aa64-e0453d0e407d', 'Head Supported Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/c6lkPMhuyFA?si=eUivRGYSi0W7PmVe', 'راسك ثابت على البنش بدون أي ميلان بالرقبة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b677cd3d-e8a2-4632-b14a-3d96cb33af11', 'Single Arm Dumbbell Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/QBjaGx8mS1o', 'اسحب باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3f1dec17-20d8-4dcb-9e8f-a33ddd6a1691', 'Single Arm Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/Qn_mHGObb8E?si=IZ0q9_tseiRIMtcs', 'اسحب باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ac64f82f-d7cc-4730-947e-0f41f8cfed65', 'Seated Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/0G3W83dFUeY', 'اسحب باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness | تحدب الظهر / Postural Thoracic Kyphosis', 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ff9b276b-fa1f-40c1-a6fa-ca514180b196', 'Band Seated Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/Jy-WCFAofBY?si=9gqVby588rk1zFi9', 'فتحة واسعة، واسحب لما تنقبض عضلات الظهر.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness | تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture', 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('30cb1de1-d458-4e1a-9605-e466d1c13c30', 'Chest Supported Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/DgHtyrQEMJ4?si=oTfTKVgD9j1H12wA', 'ثبت صدرك على الكرسي، فتحة واسعة، واسحب لما تنقبض عضلات الظهر.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness', 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('73951126-fd42-45f7-8c21-9a7874fa28da', 'Chest Supported Machine Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/BZrdEAiR2Xs?si=WhKaSGhR0gKeeies', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('be0669d3-f062-4246-bba0-0567d9f4e993', 'T-Bar Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/6OtcNinT0HM?si=UPfYyypfZCaN9tTA', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cdfafb45-5417-4862-8d82-677c445cd3d3', 'Lats Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/CQkT-W18N5g', 'الكيبل بنفس مستوى بطنك، اسحب باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Lat-focused Row / تجديف لاتس', 'Shoulder Extension / مد الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('eb632143-11e2-4856-901f-d69b7a4283ec', 'Upperback Pulldowns', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/bNmvKpJSWKM?si=hy5HgBDAHkzFHcvv', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Wide-grip Pulldown / سحب علوي بقبضة واسعة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('620749ee-6ce4-42ad-b706-1d71f913c3ab', 'Straight Arm Pulldown', 'Back & Lats / الظهر واللاتس', '{}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/hAMcfubonDc?si=ocU_a8VQ4VzZnTg3', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Straight-arm Pull / سحب بذراع مستقيمة', 'Shoulder Extension + Scapular Depression / مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cd200722-98da-475c-ac65-2c1e03bcfe63', 'DB Pullover', 'Back & Lats / الظهر واللاتس', '{"Chest / الصدر","Triceps / الترايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/ieFKuQAGYIA?si=uwqyrbKhBL6Id3_-', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Straight-arm Pull / سحب بذراع مستقيمة', 'Shoulder Extension + Scapular Depression / مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d3e7016d-202f-4638-bdcd-e90310a0ecf0', 'Band Lat Pulldown', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/5R0RYj3Y9Ro', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1ecd53cb-3cc2-48b1-a6dd-37d5c793b60d', 'Band Assisted Pull Ups', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://youtu.be/Ks8ah-8P1b0', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4bbc56c4-6370-4fdb-a33b-57afc190b588', 'Pull Ups', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متقدم', 'نادي', 'https://youtu.be/x3NPAxiMRPw?si=Mwg6U1Df5aIFpjKB', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('50c200b6-b7dd-4a95-829e-a275f6e3d21d', 'Negative Pull-Up', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://youtu.be/gbPURTSxQLY?si=TvQF5zDWfU_rR1Ax', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر، نزول بطيء.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('20a76776-e7ec-4190-a6cd-8da1bd082aef', 'Neutral Grip Lat Pulldown', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/kVB6SlEyjQM', 'القبضة بنفس مستوى الكتف، اسحب باتجاه اعلى الصدر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('bc9f27e1-4ee8-4b74-a41f-e09cca0e5d67', 'Single Lats Pulldown', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/Qed5O9toqT8', 'اجلس على بنش واسند صدرك عليه، ارجع للخلف قليلا بحيث ان الكيبل ما يكون فوق راسك مباشرة، اسحب الكوع باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ace6c367-7989-43b6-bee4-dcb67b5c3ba8', 'Band Assisted Chin Ups', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://youtu.be/i0yC-0YK6Uk?si=gNX26kIFz_THnR4p', 'مسكة ضيقة بمستوى الأكتاف، كل ما كان الحبل خفيف زادت المقاومة وزدات صعوبة التمرين لذلك ابدأ بحبل ثقيل وخفف كل ما تحسن مستواك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('dffcd79d-c0a4-4f6e-bc70-e47125f0ff68', 'Chin Ups', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متقدم', 'نادي', 'https://youtube.com/shorts/aV9Mz9nCsMw?si=E_ullJojGO_7srW2', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cdc10036-be2f-4175-816c-827a99c7cc87', 'Kneeling Lat Pulldown', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', NULL, 'متوسط', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/35/kneeling-lat-pulldown/', NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('816eb9fc-97d7-4d2e-b4a4-46d7f6337de7', 'TRX Back Row', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس","Core / البطن والكور","Lower back / أسفل الظهر"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'TRX', 'متوسط', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/84/trx-reg-back-row/', NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3ec02c28-dee7-4e22-bf27-08754a4afe3f', 'Shrug', 'Back & Lats / الظهر واللاتس', '{"Trapezius / الترابيس"}', 'Scapular Elevation / رفع لوح الكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف فرعي: رفع الأكتاف (Shrug) ليس نمط سحب أفقي أو عمودي', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/72/shrug/', NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Shrug / هز الكتفين', 'Scapular Elevation / رفع لوح الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ad3beda0-1c75-4754-a5e0-480517aa89c7', 'DB Shoulder Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/NKeyUrDYqPk', 'قوّس ظهرك العلوي قليلاً، الكوع قريب من الجسم، النزول الى مستوى الاكتاف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9252f5ac-02a2-4573-8ca9-6e02b6efc513', 'DB Standing Shoulder Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/wO0l5jW2NtQ?si=MVvS4F_7iFS8ji9R', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b489e9b6-88bc-4f8d-8142-6d5e27f486f6', 'Machine Shoulder Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/3R14MnZbcpw', 'قوّس ظهرك العلوي قليلاً، الكوع قريب من الجسم، النزول الى مستوى الاكتاف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c02957eb-6b6b-482e-98b2-1fc107237c0c', 'BB Overhead Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/_RlRDWO2jfg', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('41f8a9d5-482f-4e6e-b354-f35c744ae6bd', 'DB Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/qqntiuPmLDM?feature=share', 'انحني للأمام قليلًا، ارفع للأعلى الى أن تصل لمستوى الأكتاف.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('496b7bc3-9443-4fd2-918d-359151cc24a0', 'Seated Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/v7fwGurZ9SU?feature=share', 'انحني للأمام قليلًا، ارفع للأعلى الى أن تصل لمستوى الأكتاف.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('db54c40c-39e9-42f3-b49b-dcd9983b5661', 'Lateral Raise Machine', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/d0pRsZ9SY5w?si=XuXb_Ti0Flow7qvW', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2037adb4-5ea7-43b6-9cc2-b994c291cf9e', 'Cable Crossover Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/wKgCc5UQjoU?si=zsaz3i31PnEU9A43', 'الكيبل يبدأ من الأسفل، انحني للأمام قليلًا، ارفع للأعلى وتحكم بالنزول.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('efedba63-9547-4310-90c3-dde9524c5fe6', 'DB Y Raises', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/lXp16YozXgk', 'ثبت صدرك على البنش،ارفع الوزن على شكل Y.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Y Raise (Scaption) / رفع Y بمستوى لوح الكتف', 'Shoulder Elevation in Scapular Plane (Scaption) / رفع الذراع بمستوى لوح الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c0e41d68-7c3a-4d57-a87d-acb09dd0f68f', 'Cable Y Raises', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/P7u6PEeOn6Q?feature=share', 'الكيبل يبدأ من تحت،ارفع الوزن على شكل Y.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Y Raise (Scaption) / رفع Y بمستوى لوح الكتف', 'Shoulder Elevation in Scapular Plane (Scaption) / رفع الذراع بمستوى لوح الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3f6e87b0-1b59-4fe7-8cd1-d97529ebec06', 'Single Arm DB Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/Jm6GqVhWhNY', 'انحني للأمام قليلًا، ارفع للأعلى الى أن تصل لمستوى الأكتاف.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1d7fe40a-2a25-4890-8552-757cabb8c2b6', 'Single Arm Cable Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/J-6uEOkYAKM', 'الكيبل يبدأ من الأسفل، انحني للأمام قليلًا، ارفع للأعلى وتحكم بالنزول.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f51b6fb1-bc4a-49fa-9e36-ee8e9b13ed51', 'Front Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Front Raise / رفع أمامي للكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/54/front-raise/', NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Front Raise / رفع أمامي', 'Shoulder Flexion / ثني الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fa29664c-ce7c-43a3-bf5a-c75d32766446', 'Diagonal Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/371/diagonal-raise/', NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Diagonal Raise / رفع قطري', 'Shoulder Flexion + Abduction (Diagonal) / ثني وتبعيد الكتف (قطري)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6e5af508-69ab-46a3-8f05-90484daa8736', 'High Row', 'Shoulders / الأكتاف', '{}', 'Shoulder Rear Pull / سحب خلفي للكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/336/high-row/', NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'High Row / Face Pull / سحب عالٍ باتجاه الوجه', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8fc3706b-26fa-424c-b800-4cc55a7b0e7e', 'Biceps Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/09AYfVFf7pg?si=dcwLVAYqIbDLM6jd', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('07f42b5d-03d1-4c26-9333-778acbbd6887', 'Cable Rope Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/xNXUTJ6TBZA?si=-r-Ql97awoVZla_1', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Hammer / Neutral-grip Curl / ثني بقبضة محايدة', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a1353bf7-2801-4f73-b51c-36f043c995d0', 'Cable Facing Away Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/fV9BpknCjGM', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7768998e-02ba-4e0e-9602-0500b05700a3', 'DB Incline Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/js_StxxyxBM', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('94e78166-bb8f-4cbc-a257-f7230caf1ed5', 'Cable Facing In Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/5z4y7QRTx1w', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4c766a13-9a28-4880-885b-5c1480d92db5', 'Single Arm Cable Facing Away Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/6sO-pK7pTPs?feature=share', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8d892bd0-be9e-4cb5-a252-ae471f64673c', 'Single Arm Cable Facing In Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/I-197ZW9Ffo?si=M1Yq4R1PIpdZMXRx', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('72dc48fb-c34e-4fa1-bc03-f8b67425d412', 'DB Preacher', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/DZJNTb-zzn0?si=SwbdZ0O_0eTOET-5', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Preacher Curl / ثني على مسند', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('be7df035-f0af-4d65-95e5-85588ae4eacb', 'Preacher Curl Machine', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/TouYMA3-ua4?feature=share', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Preacher Curl / ثني على مسند', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1b9d755e-a8a6-428e-9b8e-0fcc31d2f1fb', 'DB Spider Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/cTMjzB2_IH8?si=qsIKEEFVfEvPXwqf', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('93a619ef-d068-4f52-96a9-ed7fb5aa88f7', 'Zottman Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://www.youtube.com/watch?v=ZXbOOIOPOi8', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cbb387b2-456c-4033-9601-68ac129b40f1', 'Hammer Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/10/hammer-curl/', NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Hammer / Neutral-grip Curl / ثني بقبضة محايدة', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8d50146f-63b7-4ea1-a62f-b5bfcc8959cd', 'TRX Biceps Curl', 'Biceps / البايسبس', '{"Forearms / الساعد","Core / البطن والكور"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'TRX', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/78/trx-reg-biceps-curl/', NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f9feb2e8-470a-4533-9c9b-a0f41b0f41c4', 'DB Triceps Extensions', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/d7SXlU5HkYM?si=WuuPa9-yeByaP5sI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Overhead Extension / مد فوق الرأس', 'Elbow Extension / مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9537556f-6df9-4d7b-91f0-f8356ed7bfb8', 'DB Floor Triceps Extensions', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/dpFav9Ve4rY?si=ZBdKK8VF4aPMpi3v', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Lying Extension / مد مستلقٍ', 'Elbow Extension / مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9af221fb-b1ea-4dff-9219-8b42fb408029', 'Cable Crossbody Extensions', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://www.youtube.com/watch?v=jtLTcED38Dg', 'الكيبل يبدأ بالمنتصف زي الفيديو، بحيث لما تسحب الكيبل يكون بنفس مستوى الترابس، الأكواع والأكتاف ثابتين مكانهم والحركة كلها بثني وفرد الكوع.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Cross-body Extension / مد عرضي', 'Elbow Extension / مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cdb1a14b-16cc-4582-9ad1-a30f24ca3409', 'Triceps Pushdown', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/QsoN4u6j8nM?feature=share', 'انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0d126b7f-f3a2-461f-8740-2b988f965c94', 'Cable Crossover Pressdowns', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/Y3CDzx-oj3k', 'الكيبل يبدأ من الأعلى،انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7e91716c-a01c-44f2-aa16-1ee98974568f', 'Band Triceps Pushdown', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/mYs1rEYtZK4?si=k8vdZxNNEB5wj2CA', 'الكيبل يبدأ من الأعلى،انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('105846d2-b60e-4d28-a5d5-04b62fdf0c0f', 'Single Cable Triceps Pressdowns', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/8rl4ioij6lc', 'الكيبل يبدأ من الأعلى،انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('bf9f644d-0b68-429d-8896-bcca69998358', 'Cable Overhead Extension', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://www.youtube.com/shorts/Q3bO1Fh4734', 'اترك الحبل يسحب معصمك وكوعك ثابت لما تستطيل التراي ثم ارفع الوزن لما تستقيم اليد، كوعك ثابت طول الوقت والحركة ثني ومد من مفصل الكوع، ممكن تطبق كل يد لحالها اذا كان اسهل لك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Overhead Extension / مد فوق الرأس', 'Elbow Extension / مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('65f669cf-aba0-41d2-bec5-dcbd46259967', 'Triceps Dips', 'Triceps / الترايسبس', '{"Chest / الصدر","Shoulders / الأكتاف"}', 'Vertical Push / دفع عمودي', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/SpSE_A5L-YA?si=bSAzRM9SBuX-3mE0', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Dip / متوازي', 'Shoulder Extension + Elbow Extension / مد الكتف + مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('89ee12a3-31d3-4bfd-b96c-70a9610f75d9', 'Triceps Kickback', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/YebyKE3Ts8o?si=H_h9z5BXutFBbFhq', NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/55/triceps-kickback/', NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Triceps Kickback / ركلة الترايسبس', 'Elbow Extension / مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('dd82939d-776d-4664-b4bc-5d5e6f4fc8b7', 'Plank', 'Core / البطن والكور', '{"Shoulders / الأكتاف","Glutes / المؤخرة"}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/pvIjsG5Svck?si=cTP8ZyfMAJPfaEhw', 'لما ترتفع الاكتاف تكون فوق الكوع والرجل ممتدة بالكامل.', NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e47d9aa8-1ed3-4754-b6b7-8ddf8d90ca94', 'deadbug', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/g_BYB0R-4Ws?si=D4nwJri73eBqJRqL', NULL, 'اسم مشابه موجود في المكتبة (deadbug / dead bug) — تُراجَع قبل الحذف أو الدمج', 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'rejected', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6217e97d-48f9-4415-b72a-ec41604caf3e', 'Band Dead Bug', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'مطاط', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/iW_CtYtzbeU?si=Epequw3rqA3_TwTr', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cf616dfc-f074-483a-a1d3-2fbec8c24082', 'Side Plank', 'Core / البطن والكور', '{"Abductors / مبعدات الفخذ","Shoulders / الأكتاف"}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'لما ترتفع الاكتاف تكون فوق الكوع والرجل ممتدة بالكامل.', NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain | ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Anti-Lateral Flexion / مقاومة الميلان الجانبي', 'Isometric Anti-Lateral Flexion / تثبيت الجذع ضد الميلان', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('00d7acb2-44cc-4a70-acbf-d4c975fedb56', 'McGill Big 3', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/jZylx81_kfg?si=_jP064GZIzvEvzyN', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Mixed (McGill Big 3) / مختلط', 'Isometric Trunk Stabilization / تثبيت الجذع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('af5c5e9a-e4fa-44cf-9e32-a904daf2aaa4', 'Suitcase Carry', 'Core / البطن والكور', '{"Forearms / الساعد"}', 'Loaded Carry / حمل ومشي', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/BaRMAhD7SP4?si=KkiMH8OSIEz_TB53', NULL, 'نفس التمرين ورد أيضاً تحت التصنيف «Functional Training» (صف المصدر 160) || رابط آخر في المصدر (صف 160): https://youtu.be/BaRMAhD7SP4?si=dCR2n2VSPaHhxfL3', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Suitcase Carry / حمل جانبي', 'Isometric Trunk + Grip Under Load / تثبيت الجذع والقبضة أثناء المشي', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5d0e09c1-8565-4df8-996e-5cfe6a79c5da', 'Single Leg Raise', 'Core / البطن والكور', '{"Glutes / المؤخرة","Hamstrings / الخلفية"}', NULL, NULL, 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/ZJodU5OOaiA?si=p6ZD9dpzyRKBUn16', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('76e3a887-93ca-4d4b-a1c7-4b91109fb3dc', 'Cable Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/ToJeyhydUxU?si=Z5dv34foxX4VtRH6', 'الحركة عبارة عن ثني للعمود الفقري وكأنك تقرب صدرك لوركك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Crunch / كرنش', 'Trunk Flexion / ثني الجذع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6bab9884-cb6c-4136-9f10-3ff104da0ca8', 'Leg Raises', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/UqmbxvOgnX4?si=U3pDG4Jf0x1mtC_7', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Reverse Crunch / Leg Raise / كرنش عكسي ورفع الأرجل', 'Hip Flexion + Posterior Pelvic Tilt / ثني الورك + إمالة الحوض للخلف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('13605bab-1be8-48b3-8b4b-dad2f51c350a', 'Bosu Ball Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'أخرى', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/KjvDgHPxXcg?si=zad59CHC6Y-calzi', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Crunch / كرنش', 'Trunk Flexion / ثني الجذع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1369fd19-d81f-4ee9-8431-22fb6f556799', 'Bent Knee V-Up', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/sbyFIM30_G8?si=dED0NQSRS44dz5G9', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'V-up / في أب', 'Trunk Flexion + Hip Flexion / ثني الجذع + ثني الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2939015a-ae2f-49ed-8c50-8dfa3d91fdbb', 'Reverse Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/esYVzdEfs04?si=N44MZZHlVeSQc1S3', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Reverse Crunch / Leg Raise / كرنش عكسي ورفع الأرجل', 'Hip Flexion + Posterior Pelvic Tilt / ثني الورك + إمالة الحوض للخلف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('867313af-3ac1-4878-9eac-d232c0dfae18', 'Belly Breathing', 'Core / البطن والكور', '{}', 'Core Activation & Breathing / تفعيل الجذع والتنفس', 'إحماء/تفعيل', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/Shk8cmgv0Ew?si=mXkcj9PH6eH_tLcd', 'نفس عميق من الانف ننفخ فيه البطن ثم نطلعه من الفم ببطئ مع ضغط البطن للداخل اثناء اخراج النفس', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Diaphragmatic Breathing / تنفس حجابي', 'Diaphragmatic Breathing + Abdominal Bracing / تنفس حجابي + شد البطن', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('89fefec5-521d-4a67-a890-8ae51c4ccfeb', 'Dead Bug', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/_zkkMOtXuOQ?si=GIkLuCUJvdaOk5FP', 'نحرك الرجلين ببطئ قليلا و بتحكم باستخدام عضلات البطن', 'اسم مشابه موجود في المكتبة (deadbug / dead bug) — تُراجَع قبل الحذف أو الدمج', 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ef926b97-9599-4c86-a074-5fd6c0a948e0', 'Reverse Tabletop Bridge', 'Core / البطن والكور', '{"Glutes / المؤخرة"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://youtu.be/d1yE9cGtPWo?si=2aoNqmUAN054rP75', 'اخذ نفس اثناء الطلوع، اثبت ثواني فوق واشد عضلات بطني، اطلع النفس اثناء النزول', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b7906809-4a77-4cd4-8475-95dc9f36db52', 'Bird Dog', 'Core / البطن والكور', '{"Lower back / أسفل الظهر","Glutes / المؤخرة"}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/L91QMACdA6Q?si=KBnuQDcm9WcUXxxI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Anti-Rotation / مقاومة الدوران', 'Isometric Anti-Rotation / تثبيت الجذع ضد الدوران', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cda01428-418a-432d-9322-6d7b9f298890', 'Pelvic Tilting', 'Core / البطن والكور', '{}', 'Core Activation & Breathing / تفعيل الجذع والتنفس', 'إحماء/تفعيل', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/DqqUIfMuDX4?si=uzl0SRl_M9guUT3j', 'الحركة من الحوض، اخذ نفس وادف حوضي للاعلى قليلا، اطلع النفس اثناء نزول الحوض والصق اسفل ظهري بالارض', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Pelvic Tilt / إمالة الحوض', 'Posterior Pelvic Tilt / إمالة الحوض للخلف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('87e3c906-7e86-4203-aee4-992b7657b729', 'Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/52/crunch/', NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Crunch / كرنش', 'Trunk Flexion / ثني الجذع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b3ab74a9-5e38-471b-9174-3073180c0d05', 'Standing Wood Chop', 'Core / البطن والكور', '{}', 'Trunk Rotation / دوران الجذع', 'كور', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/108/standing-wood-chop/', NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Rotation / Chop / دوران وتقطيع', 'Trunk Rotation / دوران الجذع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f56e7574-e375-4d59-bd68-7e283056414d', 'Russian Twist', 'Core / البطن والكور', '{"Lower back / أسفل الظهر"}', 'Trunk Rotation / دوران الجذع', 'كور', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/65/russian-twist/', NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Rotation / Chop / دوران وتقطيع', 'Trunk Rotation / دوران الجذع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f69f9a37-df16-4c58-a940-e49f5c23faa8', 'Cable Twisted', 'Core / البطن والكور', '{"Lower back / أسفل الظهر"}', 'Trunk Rotation / دوران الجذع', 'كور', 'كيبل', 'مبتدئ', 'نادي', NULL, NULL, NULL, 'إضافة المدربة', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Rotation / Chop / دوران وتقطيع', 'Trunk Rotation / دوران الجذع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6e9d52fc-1a3b-4926-80b4-0d4dbb136827', 'Calves On Leg Press', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/XdtWVYFVhGU', 'ثبت أصابعك أو مقدمة رجلك على الجهاز، لا تبالغ بالوزن، انزل بكعبك لين تمتد بطاتك بشكل كامل ثم ادفع.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ce62b747-0cfa-4b13-ba80-9f5e5884ce46', 'Calves Raise', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/H6WptvjXkgw', 'حط تحت اقدامك بليتس أو أي شي يرفعك عن الأرض، انزل من اصابعك اقصى نزول ثم ادفع للأعلى', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('81d40672-a784-4d6f-a34f-dbd6fcdf033a', 'Calf Raise (Machine)', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', 'جهاز', 'مبتدئ', 'نادي', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/294/calf-raise/', NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c85c7af6-2f9a-4828-b356-909aba5fb817', 'Calf Raises (Barbell)', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', 'بار', 'مبتدئ', 'نادي', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/51/calf-raises/', NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4a60afa5-c856-4cad-92b8-7d389fe26a6a', 'High-Load Heel Raise (Towel Under Toes)', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', NULL, 'مبتدئ', NULL, NULL, 'رفع الكعب على رجل واحدة مع منشفة ملفوفة تحت أصابع القدم؛ صعود بطيء ثم ثبات قصير ثم نزول بطيء.', 'أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Rathleff et al. 2015 — Scand J Med Sci Sports (RCT)', 'https://doi.org/10.1111/sms.12313', 'اللفافة الأخمصية / Plantar Fasciopathy', 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('343067eb-1337-455f-ac60-1efe33043900', 'Adductor Slides', 'Adductors / الأفخاذ الداخلية', '{}', 'Hip Adduction / تقريب الورك', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/6U7dfuxaX9g?si=lkH35E7tZxGBePBj', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor strength»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Adductor Slide / انزلاق للتقريب', 'Hip Adduction / تقريب الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d8bed89f-913f-41ba-951b-b63d39502870', 'Adductor Machine', 'Adductors / الأفخاذ الداخلية', '{}', 'Hip Adduction / تقريب الورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/SU1LQhq3o2g?si=_55FKBOlcn8Ilw4X', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Adductor Machine / جهاز التقريب', 'Hip Adduction / تقريب الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6a029fde-c862-48a5-80c3-76ff6d7b3fcb', 'Side Lunge', 'Adductors / الأفخاذ الداخلية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/50/side-lunge/', 'ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Lateral Lunge / لانج جانبي', 'Knee/Hip Extension + Hip Adduction / مد الركبة والورك + تقريب الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('067368d3-5de2-47bf-92cb-1e09decc5565', 'Seated Abductor Machine', 'Abductors / مبعدات الفخذ', '{}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/riEMreTHNbM?si=wE3vfJBYQY7j_oJ2', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor strength»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9b621145-9c46-4d72-8e31-a7f33d9d1802', 'Sled Pull/Push', 'Functional / التمارين الوظيفية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Calves / البطات"}', 'Locomotion / مشي وجري ودفع', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://www.youtube.com/watch?v=3KWK7SIdPz4', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Sled Push / Pull / دفع وسحب الزلاجة', 'Hip/Knee Extension in Gait / بسط الورك والركبة بنمط المشي', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3d339586-f201-47c7-ba32-fe9056b006d9', 'Hip Abductor Plank', 'Abductors / مبعدات الفخذ', '{"Core / البطن والكور"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/2lB5RL91yWo?si=WRm9rUORpFK6dXPl', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor strength»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1d8b121d-2eeb-4283-9def-a19f08215e7f', 'Dirty Dog', 'Abductors / مبعدات الفخذ', '{"Core / البطن والكور"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/109/dirty-dog/', NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3c36eee9-f7dc-4722-a0ce-27d94c55b380', 'Hip Hitch (Pelvic Drop)', 'Abductors / مبعدات الفخذ', '{}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Ganderton et al. — GMin/GMed EMG (RMIT University)', 'https://research-repository.rmit.edu.au/articles/journal_contribution/Gluteus_Minimus_and_Gluteus_Medius_Muscle_Activity_during_Common_Rehabilitation_Exercises_in_Healthy_Postmenopausal_Women/27572301', 'ضعف الألوية المتوسطة / Gluteus Medius Weakness | ضعف الألوية الصغرى / Gluteus Minimus Weakness', 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Pelvic Drop (Stance Leg) / تثبيت الحوض برجل الارتكاز', 'Hip Abduction of Stance Leg / تبعيد ورك رجل الارتكاز', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('054b1c19-697f-465d-b59f-939c25abb368', 'Rotator Cuff', 'Rotator cuffs / الكفة المدورة', '{}', 'Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/mO8YJAxVG2M?si=KL_llR6Z47Yt89uk', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «Functional Training»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'External Rotation / دوران خارجي', 'Shoulder External Rotation / دوران خارجي للكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('46782ed4-9dcd-409c-bc44-233b93c9045e', 'Shoulder I-Y-T-W Series', 'Rotator cuffs / الكفة المدورة', '{"Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/237/shoulder-stability-mobility-series-i-y-t-w-formations/', 'تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture | ضعف العضلة المعينية / Rhomboid Weakness', 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'I-Y-T-W / تمارين I-Y-T-W', 'Scapular Retraction/Depression + Arm Elevation / سحب وخفض لوح الكتف مع رفع الذراع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('033842a8-4069-494c-b5ad-77d5fc4374cc', 'Supine Snow Angel (Wipers)', 'Rotator cuffs / الكفة المدورة', '{"Shoulders / الأكتاف","Core / البطن والكور"}', 'Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/124/supine-snow-angel-wipers-exercise/', 'تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture', 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Snow Angel / الملاك', 'Shoulder Abduction/Adduction + Scapular Control / تبعيد وتقريب الكتف مع تحكم لوح الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f84689be-4569-46c8-867d-3efa970b3445', 'Back Extension', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة","Hamstrings / الخلفية"}', 'Spinal Extension / بسط الجذع', 'كور', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/bs7S3RFyIYs?si=tDLl3OYuDBIwK4Fj', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «Functional Training»)', 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain | تحدب الظهر / Postural Thoracic Kyphosis', 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Back Extension / بسط الظهر', 'Hip Extension + Spinal Extension / بسط الورك + بسط العمود الفقري', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('733ee975-e778-459c-a816-6c05d94483db', 'Supermans', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة","Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Spinal Extension / بسط الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/9/supermans/', 'تحدب الظهر / Postural Thoracic Kyphosis | آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Prone Extension / بسط على البطن', 'Spinal Extension / بسط العمود الفقري', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f3a82e6c-8bb0-43ba-95e3-986d3d7723d5', 'Stability Ball Reverse Extensions', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة"}', 'Spinal Extension / بسط الجذع', 'كور', 'كرة سويسرية', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/64/stability-ball-reverse-extensions/', NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Reverse Extension / بسط عكسي', 'Hip Extension + Spinal Extension / بسط الورك + بسط العمود الفقري', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6d87b190-1310-40a9-87f1-cf28fd2af510', 'Farmer’s Walk', 'Functional / التمارين الوظيفية', '{"Forearms / الساعد","Core / البطن والكور","Back & Lats / الظهر واللاتس"}', 'Loaded Carry / حمل ومشي', 'قوة', NULL, 'مبتدئ', NULL, 'https://www.youtube.com/watch?v=hx24PM6gXs8', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Farmer''s Walk / مشي المزارع', 'Isometric Trunk + Grip Under Load / تثبيت الجذع والقبضة أثناء المشي', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ce366b22-15f8-4390-a1be-b3ec32a14419', 'Contralateral Limb Raises', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة","Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Spinal Extension / بسط الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/53/contralateral-limb-raises/', NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Prone Extension / بسط على البطن', 'Spinal Extension / بسط العمود الفقري', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1bbab166-9bbc-45aa-8c77-bfb53cb5690f', 'Inner Thigh Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/uqCfJYKojLU?si=Gev0VeOwVp5z6gB2', 'الضغط والدفع يكون من جهة الفخذ ، لا تدفع من ركبتك!', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «stretch»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Adductor Stretch / إطالة المقربات', 'Hip Abduction (Adductor Stretch) / تبعيد الورك (إطالة المقربات)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fc359414-dfe8-4380-8e82-437f5eb7de94', 'Hips Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/uqCfJYKojLU?si=Gev0VeOwVp5z6gB2', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «stretch»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Hip Stretch / إطالة الورك', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('98ee9741-55ac-4ca6-bd0f-f999e181a2a8', 'Kneeling Hip-flexor Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'من وضع الركوع: الركبة الخلفية تحت الورك والقدم الأمامية أمامك والركبة فوق الكاحل. شد البطن وادفع الحوض للأمام دون تقويس أسفل الظهر، واعصر مؤخرة الجهة الخلفية لزيادة الإطالة. اثبت 30–45 ثانية، 2–5 مرات.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/142/kneeling-hip-flexor-stretch/', NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Hip Flexor Stretch / إطالة ثانيات الورك', 'Hip Extension (End Range) / بسط الورك في نهاية المدى', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7878cb97-a45a-4b2b-bf3b-6ac96344fcee', 'Supine Hamstrings Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'استلقِ على ظهرك وارفع رجلاً واحدة ومدّها ببطء مع سحب أصابع القدم نحوك، دون أي حركة في الحوض أو أسفل الظهر. اثبت 15–30 ثانية، 2–4 مرات لكل رجل.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/235/supine-hamstrings-stretch/', NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Hamstring Stretch / إطالة الخلفية', 'Hip Flexion with Knee Extended / ثني الورك مع مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f5e5ce91-4989-4dda-ac76-8effe198e24a', 'Side Lying Quadriceps Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'استلقِ على جنبك وشد البطن، واسحب كعب الرجل العلوية نحو المؤخرة بيدك مع إبقاء الركبة في خط الورك. اثبت 30–45 ثانية، 2–5 مرات لكل جهة.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/149/side-lying-quadriceps-stretch/', NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Quadriceps Stretch / إطالة الأمامية', 'Knee Flexion + Hip Extension (End Range) / ثني الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2533b591-e1f6-40d6-8e78-0ab8811aa26a', 'Standing Dorsi-Flexion (Calf Stretch)', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/152/standing-dorsi-flexion-calf-stretch/', 'اللفافة الأخمصية / Plantar Fasciopathy', 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Calf Stretch / إطالة البطات', 'Ankle Dorsiflexion / ثني ظهري للكاحل', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6d1834f5-0861-42d1-913d-9af2ed5387cf', 'Cat-Cow', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/15/cat-cow/', 'تحدب الظهر / Postural Thoracic Kyphosis | آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Spinal Mobility / مرونة العمود الفقري', 'Spinal Flexion/Extension / ثني وبسط العمود الفقري', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('222017dd-ac27-4db5-9a77-a090edc8004b', 'Standing Lunge Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/137/standing-lunge-stretch/', NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Hip Flexor Stretch / إطالة ثانيات الورك', 'Hip Extension (End Range) / بسط الورك في نهاية المدى', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1eb1afac-47d7-40ef-a18f-201b3ab554de', 'Plantar Fascia-Specific Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'تُسحب أصابع القدم للخلف باليد حتى يُشعر بشد في باطن القدم، مع تحسّس اللفافة للتأكد من الشد.', 'أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Rathleff et al. 2015 — Scand J Med Sci Sports (RCT)', 'https://doi.org/10.1111/sms.12313', 'اللفافة الأخمصية / Plantar Fasciopathy', 'review', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Plantar Fascia Stretch / إطالة اللفافة الأخمصية', 'Toe Extension + Ankle Dorsiflexion / مد أصابع القدم + ثني ظهري', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('83b5c0cb-ecfb-412a-b29d-ede3252526ab', 'Crab Reach (Thoracic Bridge)', 'Functional / التمارين الوظيفية', '{"Glutes / المؤخرة","Shoulders / الأكتاف"}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://www.youtube.com/watch?v=fgsUe3Lc3hI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'تحدب الظهر / Postural Thoracic Kyphosis', 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Thoracic Bridge / جسر صدري', 'Hip Extension + Thoracic Rotation / بسط الورك + دوران الصدر', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5bfff03a-e6a3-4168-ad3d-b2f7528e430f', 'Lateral Bound', 'Plyometrics / التمارين الانفجارية', '{"Glutes / المؤخرة","Quadriceps / الأمامية","Abductors / مبعدات الفخذ"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://www.youtube.com/watch?v=soqQy4dzEts', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «Functional Training»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Lateral Jump / قفز جانبي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a1b50169-99da-4f2b-bce7-b2c04038cf2f', 'Box Jumps', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Calves / البطات"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'أخرى', 'متوسط', 'نادي', NULL, NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «CrossFit»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Vertical Jump / قفز عمودي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('247fc586-d5f5-4d2e-916b-45007c61932d', 'Squat Jump', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متوسط', 'بدون معدات', NULL, 'قف بعرض الحوض، ادفع الورك للخلف وانزل، ثم اقفز بقوة بمدّ الكاحل والركبة والورك معاً. انزل بهدوء على منتصف القدم مع دفع الورك للخلف ودون قفل الركب. ابدأ بقفزات صغيرة حتى تتقن الهبوط.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/222/squat-jump/', NULL, 'review', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Vertical Jump / قفز عمودي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2f85e376-068b-4635-8105-344291077bc4', 'Tuck Jump', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متقدم', 'بدون معدات', NULL, 'استخدم الذراعين للزخم: أرجعهما للخلف عند النزول وأرجحهما للأمام والأعلى عند القفز، واسحب الركبتين نحو الصدر في الهواء.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/180/tuck-jump/', NULL, 'review', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Vertical Jump / قفز عمودي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('45c1277a-800d-49b8-84cc-a4aa65c069b9', 'Cycled Split-Squat Jump', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Hamstrings / الخلفية"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متقدم', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/234/cycled-split-squat-jump/', NULL, 'review', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Split Jump / قفز سبليت', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('961f729f-a93c-4504-b5f3-c63f9e9a813e', 'Lateral Cone Jumps', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Calves / البطات"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'أخرى', 'متوسط', 'نادي', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/120/lateral-cone-jumps/', NULL, 'review', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Lateral Jump / قفز جانبي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ea316212-90e8-490b-911d-ca326ce6f538', 'Forward Linear Jumps', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Hamstrings / الخلفية"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متوسط', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/177/forward-linear-jumps/', NULL, 'review', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Horizontal Jump / قفز أمامي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f5332e09-9824-4e60-939e-f9b1d86cf0d0', 'Jogging', 'CrossFit / كروس فت', '{"Quadriceps / الأمامية","Hamstrings / الخلفية","Calves / البطات"}', 'Locomotion / مشي وجري ودفع', 'كارديو', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Running / جري', 'Gait: Alternating Hip/Knee Extension / نمط المشي والجري', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b6672065-25cc-49c9-9faf-3510532590fe', 'Wall Ball', 'CrossFit / كروس فت', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Shoulders / الأكتاف"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'أخرى', 'متوسط', 'نادي', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Squat to Throw / سكوات مع رمي', 'Knee/Hip Extension + Shoulder Flexion / مد الركبة والورك + ثني الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('555f6a86-44e6-47cc-a851-b75d22fea2f7', 'Snatch', 'CrossFit / كروس فت', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Shoulders / الأكتاف"}', 'Olympic Lift (Triple Extension) / رفعات أولمبية (بسط ثلاثي)', 'قدرة', 'بار', 'متقدم', 'نادي', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Snatch / سناتش', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('97fd9f3e-dd96-49ee-a0b6-21cdf5d12d63', 'Clean', 'CrossFit / كروس فت', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Quadriceps / الأمامية"}', 'Olympic Lift (Triple Extension) / رفعات أولمبية (بسط ثلاثي)', 'قدرة', 'بار', 'متقدم', 'نادي', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Clean / كلين', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7cdcb816-e88f-4f4e-b39d-bafa190d5e29', 'Turkish Get-Up', 'Functional / التمارين الوظيفية', '{"Shoulders / الأكتاف","Core / البطن والكور","Glutes / المؤخرة"}', 'Full-body Integrated / حركة متكاملة للجسم', 'قوة', 'كيتلبل', 'متقدم', 'منزل', 'https://www.youtube.com/watch?v=0bWRPC49-KI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Turkish Get-Up / النهوض التركي', 'Multi-joint Integrated / حركة متعددة المفاصل', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('184f9bad-5127-4cda-9240-dfefe30a6190', '90s Transition', 'Functional / التمارين الوظيفية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://www.youtube.com/watch?v=ogU-azeGe_k', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Hip Rotation Mobility (90/90) / مرونة دوران الورك', 'Hip Internal/External Rotation / دوران الورك الداخلي والخارجي', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0884e985-e078-495f-9c90-d4729d9e6a84', 'Prone Swimmer', 'Functional / التمارين الوظيفية', '{"Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Shoulder Rear Pull / سحب خلفي للكتف', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://www.youtube.com/watch?v=M8a1cgnhyqk', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture', 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Prone Swimmer / سبّاح على البطن', 'Shoulder Extension/Abduction + Rotation / مد وتبعيد الكتف مع الدوران', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d6ac8267-6393-46d6-8c4e-58277cc11869', 'Kettlebell Swing', 'Functional / التمارين الوظيفية', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Core / البطن والكور"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قدرة', 'كيتلبل', 'متوسط', 'منزل', 'https://www.youtube.com/watch?v=d94xX-AQZ0A', NULL, 'نفس التمرين ورد أيضاً تحت التصنيف «CrossFit» (صف المصدر 168)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Ballistic Hinge (Swing) / مفصلة انفجارية (سوينق)', 'Hip Extension (Ballistic) / بسط الورك الانفجاري', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7d798023-9d6e-4eb8-b41e-3bc04fcd2545', 'left over db', 'Functional / التمارين الوظيفية', '{}', NULL, NULL, 'دمبل', NULL, 'منزل', 'https://youtu.be/pLnRt-caepc?si=DAS9jeYr8vS6RRtz', 'طبق الحركة بأقصى عدد ممكن من التكرارات وأحسبها كجولة، ثم ابدأ بالجولة الثانية بنفس الطريقة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('91dbd7e3-bd50-4e6a-8c71-d042eef818b3', 'Serratus Punches Supine', 'Functional / التمارين الوظيفية', '{"Shoulders / الأكتاف","Chest / الصدر"}', 'Horizontal Push / دفع أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/cxaAqmdlrgk?si=2YRAIgFFXPAvDadG', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Scapular Protraction / دفع لوح الكتف', 'Scapular Protraction / دفع لوح الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6f341bf6-2e51-400e-b8bd-aa219179e5f4', 'Isometric Wrist Extension', 'Forearms / الساعد', '{}', 'Wrist Extension / مد الرسغ', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'مرفق التنس / Lateral Elbow Tendinopathy', 'review', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Isometric / ثابت', 'Wrist Extension / مد الرسغ', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b4459321-165d-4b35-9981-3ed17f912f78', 'Eccentric Wrist Extension', 'Forearms / الساعد', '{}', 'Wrist Extension / مد الرسغ', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'مرفق التنس / Lateral Elbow Tendinopathy', 'review', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Eccentric / لامركزي', 'Wrist Extension / مد الرسغ', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c27f0f5d-64e4-41d3-ab14-5098e2304c34', 'Chin Tuck (Deep Neck Flexor)', 'Neck / الرقبة', '{}', 'Neck Flexion (Deep Flexors) / ثني الرقبة العميق', 'إحماء/تفعيل', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Sheikhhoseini et al. 2018 — JMPT (Systematic review, FHP)', 'https://pubmed.ncbi.nlm.nih.gov/30107937/', 'وضعية الرأس للأمام / Forward Head Posture', 'review', '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00', 'Chin Tuck / سحب الذقن', 'Upper Cervical Flexion + Retraction / ثني علوي للرقبة مع سحبها للخلف', NULL) ON CONFLICT DO NOTHING;



INSERT INTO public.exercise_alternatives VALUES ('a5d11f5e-ee19-4d6f-b352-97b68de45e2e', '90f0b87b-a046-4721-8faa-1a039d901414', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a5d11f5e-ee19-4d6f-b352-97b68de45e2e', '963a79d6-1afb-4d57-b70b-d003aea93da7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a5d11f5e-ee19-4d6f-b352-97b68de45e2e', '8f1856ef-9808-4556-afd3-60538b886863', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a5d11f5e-ee19-4d6f-b352-97b68de45e2e', 'b9346494-c920-4a7c-a771-89e02bdad829', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a5d11f5e-ee19-4d6f-b352-97b68de45e2e', 'fcb0fc40-657c-4f12-9a5e-76829ccf0580', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('90f0b87b-a046-4721-8faa-1a039d901414', 'a5d11f5e-ee19-4d6f-b352-97b68de45e2e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('90f0b87b-a046-4721-8faa-1a039d901414', '963a79d6-1afb-4d57-b70b-d003aea93da7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('90f0b87b-a046-4721-8faa-1a039d901414', '8f1856ef-9808-4556-afd3-60538b886863', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('90f0b87b-a046-4721-8faa-1a039d901414', 'b9346494-c920-4a7c-a771-89e02bdad829', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('90f0b87b-a046-4721-8faa-1a039d901414', 'fcb0fc40-657c-4f12-9a5e-76829ccf0580', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b6e3842-ae29-41f2-a1d9-6163de3666a6', '5690a819-0d6c-4c29-b963-031174f8aae0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b6e3842-ae29-41f2-a1d9-6163de3666a6', 'bdce7900-3d1d-46e7-8f86-ce4201d73b40', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b6e3842-ae29-41f2-a1d9-6163de3666a6', 'a5d11f5e-ee19-4d6f-b352-97b68de45e2e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b6e3842-ae29-41f2-a1d9-6163de3666a6', '90f0b87b-a046-4721-8faa-1a039d901414', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b6e3842-ae29-41f2-a1d9-6163de3666a6', 'c2f89c47-2255-4bdf-baa2-5d9be2d97a94', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c2f89c47-2255-4bdf-baa2-5d9be2d97a94', '494b7262-2230-443f-94ec-065abc700d89', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c2f89c47-2255-4bdf-baa2-5d9be2d97a94', 'a5d11f5e-ee19-4d6f-b352-97b68de45e2e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c2f89c47-2255-4bdf-baa2-5d9be2d97a94', '90f0b87b-a046-4721-8faa-1a039d901414', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c2f89c47-2255-4bdf-baa2-5d9be2d97a94', '8b6e3842-ae29-41f2-a1d9-6163de3666a6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c2f89c47-2255-4bdf-baa2-5d9be2d97a94', '963a79d6-1afb-4d57-b70b-d003aea93da7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('494b7262-2230-443f-94ec-065abc700d89', 'c2f89c47-2255-4bdf-baa2-5d9be2d97a94', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('494b7262-2230-443f-94ec-065abc700d89', 'a5d11f5e-ee19-4d6f-b352-97b68de45e2e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('494b7262-2230-443f-94ec-065abc700d89', '90f0b87b-a046-4721-8faa-1a039d901414', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('494b7262-2230-443f-94ec-065abc700d89', '8b6e3842-ae29-41f2-a1d9-6163de3666a6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('494b7262-2230-443f-94ec-065abc700d89', '963a79d6-1afb-4d57-b70b-d003aea93da7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('963a79d6-1afb-4d57-b70b-d003aea93da7', 'a5d11f5e-ee19-4d6f-b352-97b68de45e2e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('963a79d6-1afb-4d57-b70b-d003aea93da7', '90f0b87b-a046-4721-8faa-1a039d901414', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('963a79d6-1afb-4d57-b70b-d003aea93da7', '8f1856ef-9808-4556-afd3-60538b886863', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('963a79d6-1afb-4d57-b70b-d003aea93da7', 'b9346494-c920-4a7c-a771-89e02bdad829', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('963a79d6-1afb-4d57-b70b-d003aea93da7', 'fcb0fc40-657c-4f12-9a5e-76829ccf0580', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f1856ef-9808-4556-afd3-60538b886863', 'a5d11f5e-ee19-4d6f-b352-97b68de45e2e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f1856ef-9808-4556-afd3-60538b886863', '90f0b87b-a046-4721-8faa-1a039d901414', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f1856ef-9808-4556-afd3-60538b886863', '963a79d6-1afb-4d57-b70b-d003aea93da7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f1856ef-9808-4556-afd3-60538b886863', 'b9346494-c920-4a7c-a771-89e02bdad829', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f1856ef-9808-4556-afd3-60538b886863', 'fcb0fc40-657c-4f12-9a5e-76829ccf0580', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5690a819-0d6c-4c29-b963-031174f8aae0', '8b6e3842-ae29-41f2-a1d9-6163de3666a6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5690a819-0d6c-4c29-b963-031174f8aae0', 'bdce7900-3d1d-46e7-8f86-ce4201d73b40', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5690a819-0d6c-4c29-b963-031174f8aae0', 'a5d11f5e-ee19-4d6f-b352-97b68de45e2e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5690a819-0d6c-4c29-b963-031174f8aae0', '90f0b87b-a046-4721-8faa-1a039d901414', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5690a819-0d6c-4c29-b963-031174f8aae0', 'c2f89c47-2255-4bdf-baa2-5d9be2d97a94', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b9346494-c920-4a7c-a771-89e02bdad829', 'a5d11f5e-ee19-4d6f-b352-97b68de45e2e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b9346494-c920-4a7c-a771-89e02bdad829', '90f0b87b-a046-4721-8faa-1a039d901414', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b9346494-c920-4a7c-a771-89e02bdad829', '963a79d6-1afb-4d57-b70b-d003aea93da7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b9346494-c920-4a7c-a771-89e02bdad829', '8f1856ef-9808-4556-afd3-60538b886863', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b9346494-c920-4a7c-a771-89e02bdad829', 'fcb0fc40-657c-4f12-9a5e-76829ccf0580', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bdce7900-3d1d-46e7-8f86-ce4201d73b40', '8b6e3842-ae29-41f2-a1d9-6163de3666a6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bdce7900-3d1d-46e7-8f86-ce4201d73b40', '5690a819-0d6c-4c29-b963-031174f8aae0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bdce7900-3d1d-46e7-8f86-ce4201d73b40', 'a5d11f5e-ee19-4d6f-b352-97b68de45e2e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bdce7900-3d1d-46e7-8f86-ce4201d73b40', '90f0b87b-a046-4721-8faa-1a039d901414', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bdce7900-3d1d-46e7-8f86-ce4201d73b40', 'c2f89c47-2255-4bdf-baa2-5d9be2d97a94', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('998b46f5-52fe-4dbc-9867-1c6070584f76', 'f0749f1e-5c91-4e2e-af90-c47b1c6cc148', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('998b46f5-52fe-4dbc-9867-1c6070584f76', '6d0e5bd4-fd84-4814-9e49-5443ef93ca48', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('998b46f5-52fe-4dbc-9867-1c6070584f76', '4fe5c32a-7183-4ec2-b14c-14a3f3199016', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('998b46f5-52fe-4dbc-9867-1c6070584f76', 'ae409910-e27d-4fbe-9758-0829bc88cf38', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('998b46f5-52fe-4dbc-9867-1c6070584f76', 'ac436bb1-0cbc-400d-89fe-207df5bf17ee', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0749f1e-5c91-4e2e-af90-c47b1c6cc148', '6d0e5bd4-fd84-4814-9e49-5443ef93ca48', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0749f1e-5c91-4e2e-af90-c47b1c6cc148', '4fe5c32a-7183-4ec2-b14c-14a3f3199016', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0749f1e-5c91-4e2e-af90-c47b1c6cc148', 'ac436bb1-0cbc-400d-89fe-207df5bf17ee', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0749f1e-5c91-4e2e-af90-c47b1c6cc148', '82bf0d45-647b-4dce-83fd-53dbcdc33257', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0749f1e-5c91-4e2e-af90-c47b1c6cc148', '998b46f5-52fe-4dbc-9867-1c6070584f76', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6d0e5bd4-fd84-4814-9e49-5443ef93ca48', 'f0749f1e-5c91-4e2e-af90-c47b1c6cc148', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6d0e5bd4-fd84-4814-9e49-5443ef93ca48', '4fe5c32a-7183-4ec2-b14c-14a3f3199016', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6d0e5bd4-fd84-4814-9e49-5443ef93ca48', 'ac436bb1-0cbc-400d-89fe-207df5bf17ee', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6d0e5bd4-fd84-4814-9e49-5443ef93ca48', '82bf0d45-647b-4dce-83fd-53dbcdc33257', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6d0e5bd4-fd84-4814-9e49-5443ef93ca48', '998b46f5-52fe-4dbc-9867-1c6070584f76', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4fe5c32a-7183-4ec2-b14c-14a3f3199016', 'f0749f1e-5c91-4e2e-af90-c47b1c6cc148', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4fe5c32a-7183-4ec2-b14c-14a3f3199016', '6d0e5bd4-fd84-4814-9e49-5443ef93ca48', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4fe5c32a-7183-4ec2-b14c-14a3f3199016', 'ac436bb1-0cbc-400d-89fe-207df5bf17ee', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4fe5c32a-7183-4ec2-b14c-14a3f3199016', '82bf0d45-647b-4dce-83fd-53dbcdc33257', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4fe5c32a-7183-4ec2-b14c-14a3f3199016', '998b46f5-52fe-4dbc-9867-1c6070584f76', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ae409910-e27d-4fbe-9758-0829bc88cf38', '998b46f5-52fe-4dbc-9867-1c6070584f76', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ae409910-e27d-4fbe-9758-0829bc88cf38', 'f0749f1e-5c91-4e2e-af90-c47b1c6cc148', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ae409910-e27d-4fbe-9758-0829bc88cf38', '6d0e5bd4-fd84-4814-9e49-5443ef93ca48', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ae409910-e27d-4fbe-9758-0829bc88cf38', '4fe5c32a-7183-4ec2-b14c-14a3f3199016', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ae409910-e27d-4fbe-9758-0829bc88cf38', 'ac436bb1-0cbc-400d-89fe-207df5bf17ee', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ac436bb1-0cbc-400d-89fe-207df5bf17ee', 'f0749f1e-5c91-4e2e-af90-c47b1c6cc148', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ac436bb1-0cbc-400d-89fe-207df5bf17ee', '6d0e5bd4-fd84-4814-9e49-5443ef93ca48', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ac436bb1-0cbc-400d-89fe-207df5bf17ee', '4fe5c32a-7183-4ec2-b14c-14a3f3199016', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ac436bb1-0cbc-400d-89fe-207df5bf17ee', '82bf0d45-647b-4dce-83fd-53dbcdc33257', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ac436bb1-0cbc-400d-89fe-207df5bf17ee', '998b46f5-52fe-4dbc-9867-1c6070584f76', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('82bf0d45-647b-4dce-83fd-53dbcdc33257', 'f0749f1e-5c91-4e2e-af90-c47b1c6cc148', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('82bf0d45-647b-4dce-83fd-53dbcdc33257', '6d0e5bd4-fd84-4814-9e49-5443ef93ca48', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('82bf0d45-647b-4dce-83fd-53dbcdc33257', '4fe5c32a-7183-4ec2-b14c-14a3f3199016', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('82bf0d45-647b-4dce-83fd-53dbcdc33257', 'ac436bb1-0cbc-400d-89fe-207df5bf17ee', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('82bf0d45-647b-4dce-83fd-53dbcdc33257', '998b46f5-52fe-4dbc-9867-1c6070584f76', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7e997159-159a-4464-9502-f4afe00ac393', '8668146a-0ca6-4c82-8da6-dac9b43654ae', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7e997159-159a-4464-9502-f4afe00ac393', '3652db69-0204-4a82-ab8b-5164fefd6f2b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7e997159-159a-4464-9502-f4afe00ac393', '5c893433-0709-438c-b582-fa608f45a8f1', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7e997159-159a-4464-9502-f4afe00ac393', 'd06fa4f5-d5b7-4f37-844b-494d11b69e2b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7e997159-159a-4464-9502-f4afe00ac393', 'd8ed9d02-4063-438a-ae7c-d6f3ab856049', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8668146a-0ca6-4c82-8da6-dac9b43654ae', '7e997159-159a-4464-9502-f4afe00ac393', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8668146a-0ca6-4c82-8da6-dac9b43654ae', '3652db69-0204-4a82-ab8b-5164fefd6f2b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8668146a-0ca6-4c82-8da6-dac9b43654ae', '5c893433-0709-438c-b582-fa608f45a8f1', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8668146a-0ca6-4c82-8da6-dac9b43654ae', 'd06fa4f5-d5b7-4f37-844b-494d11b69e2b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8668146a-0ca6-4c82-8da6-dac9b43654ae', 'd8ed9d02-4063-438a-ae7c-d6f3ab856049', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3652db69-0204-4a82-ab8b-5164fefd6f2b', '7e997159-159a-4464-9502-f4afe00ac393', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3652db69-0204-4a82-ab8b-5164fefd6f2b', '8668146a-0ca6-4c82-8da6-dac9b43654ae', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3652db69-0204-4a82-ab8b-5164fefd6f2b', '5c893433-0709-438c-b582-fa608f45a8f1', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3652db69-0204-4a82-ab8b-5164fefd6f2b', 'd06fa4f5-d5b7-4f37-844b-494d11b69e2b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3652db69-0204-4a82-ab8b-5164fefd6f2b', 'd8ed9d02-4063-438a-ae7c-d6f3ab856049', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d8ed9d02-4063-438a-ae7c-d6f3ab856049', '7e997159-159a-4464-9502-f4afe00ac393', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d8ed9d02-4063-438a-ae7c-d6f3ab856049', '8668146a-0ca6-4c82-8da6-dac9b43654ae', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d8ed9d02-4063-438a-ae7c-d6f3ab856049', '3652db69-0204-4a82-ab8b-5164fefd6f2b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d8ed9d02-4063-438a-ae7c-d6f3ab856049', '5c893433-0709-438c-b582-fa608f45a8f1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d8ed9d02-4063-438a-ae7c-d6f3ab856049', 'd06fa4f5-d5b7-4f37-844b-494d11b69e2b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5c893433-0709-438c-b582-fa608f45a8f1', '7e997159-159a-4464-9502-f4afe00ac393', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5c893433-0709-438c-b582-fa608f45a8f1', '8668146a-0ca6-4c82-8da6-dac9b43654ae', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5c893433-0709-438c-b582-fa608f45a8f1', '3652db69-0204-4a82-ab8b-5164fefd6f2b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5c893433-0709-438c-b582-fa608f45a8f1', 'd06fa4f5-d5b7-4f37-844b-494d11b69e2b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5c893433-0709-438c-b582-fa608f45a8f1', 'd8ed9d02-4063-438a-ae7c-d6f3ab856049', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d06fa4f5-d5b7-4f37-844b-494d11b69e2b', '7e997159-159a-4464-9502-f4afe00ac393', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d06fa4f5-d5b7-4f37-844b-494d11b69e2b', '8668146a-0ca6-4c82-8da6-dac9b43654ae', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d06fa4f5-d5b7-4f37-844b-494d11b69e2b', '3652db69-0204-4a82-ab8b-5164fefd6f2b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d06fa4f5-d5b7-4f37-844b-494d11b69e2b', '5c893433-0709-438c-b582-fa608f45a8f1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d06fa4f5-d5b7-4f37-844b-494d11b69e2b', 'd8ed9d02-4063-438a-ae7c-d6f3ab856049', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fcb0fc40-657c-4f12-9a5e-76829ccf0580', 'a5d11f5e-ee19-4d6f-b352-97b68de45e2e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fcb0fc40-657c-4f12-9a5e-76829ccf0580', '90f0b87b-a046-4721-8faa-1a039d901414', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fcb0fc40-657c-4f12-9a5e-76829ccf0580', '963a79d6-1afb-4d57-b70b-d003aea93da7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fcb0fc40-657c-4f12-9a5e-76829ccf0580', '8f1856ef-9808-4556-afd3-60538b886863', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fcb0fc40-657c-4f12-9a5e-76829ccf0580', 'b9346494-c920-4a7c-a771-89e02bdad829', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c18f4c5a-5681-46f2-b15e-c6d844eb06af', '998b46f5-52fe-4dbc-9867-1c6070584f76', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c18f4c5a-5681-46f2-b15e-c6d844eb06af', 'f0749f1e-5c91-4e2e-af90-c47b1c6cc148', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c18f4c5a-5681-46f2-b15e-c6d844eb06af', '6d0e5bd4-fd84-4814-9e49-5443ef93ca48', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c18f4c5a-5681-46f2-b15e-c6d844eb06af', '4fe5c32a-7183-4ec2-b14c-14a3f3199016', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c18f4c5a-5681-46f2-b15e-c6d844eb06af', 'ae409910-e27d-4fbe-9758-0829bc88cf38', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4cf3afd9-fb58-4da9-aada-ffd1d396c9e9', 'bffbaf70-aeb4-49e7-9452-f7e2cfd4c3ea', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4cf3afd9-fb58-4da9-aada-ffd1d396c9e9', 'd333dda7-ba47-4e57-a355-333a6e76fbed', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4cf3afd9-fb58-4da9-aada-ffd1d396c9e9', '3173ec0b-4321-4448-9613-19e9a74d0266', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bffbaf70-aeb4-49e7-9452-f7e2cfd4c3ea', '4cf3afd9-fb58-4da9-aada-ffd1d396c9e9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bffbaf70-aeb4-49e7-9452-f7e2cfd4c3ea', 'd333dda7-ba47-4e57-a355-333a6e76fbed', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bffbaf70-aeb4-49e7-9452-f7e2cfd4c3ea', '3173ec0b-4321-4448-9613-19e9a74d0266', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d333dda7-ba47-4e57-a355-333a6e76fbed', '4cf3afd9-fb58-4da9-aada-ffd1d396c9e9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d333dda7-ba47-4e57-a355-333a6e76fbed', 'bffbaf70-aeb4-49e7-9452-f7e2cfd4c3ea', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d333dda7-ba47-4e57-a355-333a6e76fbed', '3173ec0b-4321-4448-9613-19e9a74d0266', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3173ec0b-4321-4448-9613-19e9a74d0266', '4cf3afd9-fb58-4da9-aada-ffd1d396c9e9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3173ec0b-4321-4448-9613-19e9a74d0266', 'bffbaf70-aeb4-49e7-9452-f7e2cfd4c3ea', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3173ec0b-4321-4448-9613-19e9a74d0266', 'd333dda7-ba47-4e57-a355-333a6e76fbed', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('34294e90-d32e-4c7d-9c5e-1ba3707a9e8b', '2751a1a5-d3d4-48d7-bd55-7739f01c560c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('34294e90-d32e-4c7d-9c5e-1ba3707a9e8b', 'ab2ab425-51fc-4d9e-8ae7-801e97e586e1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('34294e90-d32e-4c7d-9c5e-1ba3707a9e8b', 'f9db8317-7f1e-4ded-b3a7-1c852d2af071', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('34294e90-d32e-4c7d-9c5e-1ba3707a9e8b', '85b69bb7-18a3-4673-a213-0f033747be1b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('34294e90-d32e-4c7d-9c5e-1ba3707a9e8b', '0789410c-b33e-4c7c-900a-534910fbfc35', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84b0059f-2697-4bc1-b2e9-5ea444a6500a', '067368d3-5de2-47bf-92cb-1e09decc5565', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84b0059f-2697-4bc1-b2e9-5ea444a6500a', '3d339586-f201-47c7-ba32-fe9056b006d9', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84b0059f-2697-4bc1-b2e9-5ea444a6500a', '1d8b121d-2eeb-4283-9def-a19f08215e7f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84b0059f-2697-4bc1-b2e9-5ea444a6500a', 'd2e5bf68-021b-4550-a171-33d9bd98d35d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84b0059f-2697-4bc1-b2e9-5ea444a6500a', '3c36eee9-f7dc-4722-a0ce-27d94c55b380', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2751a1a5-d3d4-48d7-bd55-7739f01c560c', '34294e90-d32e-4c7d-9c5e-1ba3707a9e8b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2751a1a5-d3d4-48d7-bd55-7739f01c560c', 'ab2ab425-51fc-4d9e-8ae7-801e97e586e1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2751a1a5-d3d4-48d7-bd55-7739f01c560c', 'f9db8317-7f1e-4ded-b3a7-1c852d2af071', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2751a1a5-d3d4-48d7-bd55-7739f01c560c', '85b69bb7-18a3-4673-a213-0f033747be1b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2751a1a5-d3d4-48d7-bd55-7739f01c560c', '0789410c-b33e-4c7c-900a-534910fbfc35', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d2e5bf68-021b-4550-a171-33d9bd98d35d', '84b0059f-2697-4bc1-b2e9-5ea444a6500a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d2e5bf68-021b-4550-a171-33d9bd98d35d', '067368d3-5de2-47bf-92cb-1e09decc5565', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d2e5bf68-021b-4550-a171-33d9bd98d35d', '3d339586-f201-47c7-ba32-fe9056b006d9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d2e5bf68-021b-4550-a171-33d9bd98d35d', '1d8b121d-2eeb-4283-9def-a19f08215e7f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d2e5bf68-021b-4550-a171-33d9bd98d35d', '3c36eee9-f7dc-4722-a0ce-27d94c55b380', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5d4be35c-b048-4c58-bac1-455aa392725f', '4cf3afd9-fb58-4da9-aada-ffd1d396c9e9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5d4be35c-b048-4c58-bac1-455aa392725f', 'bffbaf70-aeb4-49e7-9452-f7e2cfd4c3ea', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5d4be35c-b048-4c58-bac1-455aa392725f', 'd333dda7-ba47-4e57-a355-333a6e76fbed', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5d4be35c-b048-4c58-bac1-455aa392725f', '3173ec0b-4321-4448-9613-19e9a74d0266', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9db8317-7f1e-4ded-b3a7-1c852d2af071', '85b69bb7-18a3-4673-a213-0f033747be1b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9db8317-7f1e-4ded-b3a7-1c852d2af071', '0789410c-b33e-4c7c-900a-534910fbfc35', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9db8317-7f1e-4ded-b3a7-1c852d2af071', '9bc9d946-dc35-4ce5-b93f-3a1cd9806db8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9db8317-7f1e-4ded-b3a7-1c852d2af071', '443e91f6-fd24-4e23-943e-455d2aaa97c4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9db8317-7f1e-4ded-b3a7-1c852d2af071', '34294e90-d32e-4c7d-9c5e-1ba3707a9e8b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('85b69bb7-18a3-4673-a213-0f033747be1b', 'f9db8317-7f1e-4ded-b3a7-1c852d2af071', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('85b69bb7-18a3-4673-a213-0f033747be1b', '0789410c-b33e-4c7c-900a-534910fbfc35', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('85b69bb7-18a3-4673-a213-0f033747be1b', '9bc9d946-dc35-4ce5-b93f-3a1cd9806db8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('85b69bb7-18a3-4673-a213-0f033747be1b', '443e91f6-fd24-4e23-943e-455d2aaa97c4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('85b69bb7-18a3-4673-a213-0f033747be1b', '34294e90-d32e-4c7d-9c5e-1ba3707a9e8b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0789410c-b33e-4c7c-900a-534910fbfc35', 'f9db8317-7f1e-4ded-b3a7-1c852d2af071', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0789410c-b33e-4c7c-900a-534910fbfc35', '85b69bb7-18a3-4673-a213-0f033747be1b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0789410c-b33e-4c7c-900a-534910fbfc35', '9bc9d946-dc35-4ce5-b93f-3a1cd9806db8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0789410c-b33e-4c7c-900a-534910fbfc35', '443e91f6-fd24-4e23-943e-455d2aaa97c4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0789410c-b33e-4c7c-900a-534910fbfc35', '34294e90-d32e-4c7d-9c5e-1ba3707a9e8b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9bc9d946-dc35-4ce5-b93f-3a1cd9806db8', 'f9db8317-7f1e-4ded-b3a7-1c852d2af071', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9bc9d946-dc35-4ce5-b93f-3a1cd9806db8', '85b69bb7-18a3-4673-a213-0f033747be1b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9bc9d946-dc35-4ce5-b93f-3a1cd9806db8', '0789410c-b33e-4c7c-900a-534910fbfc35', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9bc9d946-dc35-4ce5-b93f-3a1cd9806db8', '443e91f6-fd24-4e23-943e-455d2aaa97c4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9bc9d946-dc35-4ce5-b93f-3a1cd9806db8', '34294e90-d32e-4c7d-9c5e-1ba3707a9e8b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c257f17a-7a01-4c6e-8c26-51e2fbda401f', '34294e90-d32e-4c7d-9c5e-1ba3707a9e8b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c257f17a-7a01-4c6e-8c26-51e2fbda401f', '2751a1a5-d3d4-48d7-bd55-7739f01c560c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c257f17a-7a01-4c6e-8c26-51e2fbda401f', 'f9db8317-7f1e-4ded-b3a7-1c852d2af071', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c257f17a-7a01-4c6e-8c26-51e2fbda401f', '85b69bb7-18a3-4673-a213-0f033747be1b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c257f17a-7a01-4c6e-8c26-51e2fbda401f', '0789410c-b33e-4c7c-900a-534910fbfc35', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('443e91f6-fd24-4e23-943e-455d2aaa97c4', 'f9db8317-7f1e-4ded-b3a7-1c852d2af071', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('443e91f6-fd24-4e23-943e-455d2aaa97c4', '85b69bb7-18a3-4673-a213-0f033747be1b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('443e91f6-fd24-4e23-943e-455d2aaa97c4', '0789410c-b33e-4c7c-900a-534910fbfc35', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('443e91f6-fd24-4e23-943e-455d2aaa97c4', '9bc9d946-dc35-4ce5-b93f-3a1cd9806db8', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('443e91f6-fd24-4e23-943e-455d2aaa97c4', '34294e90-d32e-4c7d-9c5e-1ba3707a9e8b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab2ab425-51fc-4d9e-8ae7-801e97e586e1', '34294e90-d32e-4c7d-9c5e-1ba3707a9e8b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab2ab425-51fc-4d9e-8ae7-801e97e586e1', '2751a1a5-d3d4-48d7-bd55-7739f01c560c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab2ab425-51fc-4d9e-8ae7-801e97e586e1', 'f9db8317-7f1e-4ded-b3a7-1c852d2af071', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab2ab425-51fc-4d9e-8ae7-801e97e586e1', '85b69bb7-18a3-4673-a213-0f033747be1b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab2ab425-51fc-4d9e-8ae7-801e97e586e1', '0789410c-b33e-4c7c-900a-534910fbfc35', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0febfcf-ab2a-463c-9ba8-a20aa1828a86', '4cf3afd9-fb58-4da9-aada-ffd1d396c9e9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0febfcf-ab2a-463c-9ba8-a20aa1828a86', 'bffbaf70-aeb4-49e7-9452-f7e2cfd4c3ea', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0febfcf-ab2a-463c-9ba8-a20aa1828a86', 'd333dda7-ba47-4e57-a355-333a6e76fbed', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0febfcf-ab2a-463c-9ba8-a20aa1828a86', '3173ec0b-4321-4448-9613-19e9a74d0266', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('05cb8cb3-9f2d-4863-a6d1-275086a1e508', '5d10d4ff-4d8c-4d94-9a09-714f12183c28', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('05cb8cb3-9f2d-4863-a6d1-275086a1e508', '58696193-f5b7-4c57-8c1f-b5eef29549a6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('05cb8cb3-9f2d-4863-a6d1-275086a1e508', 'a23e824f-48fc-4875-a533-de27e522fbdf', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('05cb8cb3-9f2d-4863-a6d1-275086a1e508', 'ba7a0f61-413e-4e7b-99f3-6aba1c93848a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('05cb8cb3-9f2d-4863-a6d1-275086a1e508', 'f707f8c6-baec-4786-bc50-b6906af5bd2d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('09df9672-96fb-46d0-af95-aaa5861ab6c5', '5d10d4ff-4d8c-4d94-9a09-714f12183c28', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('09df9672-96fb-46d0-af95-aaa5861ab6c5', '58696193-f5b7-4c57-8c1f-b5eef29549a6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('09df9672-96fb-46d0-af95-aaa5861ab6c5', 'a23e824f-48fc-4875-a533-de27e522fbdf', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('09df9672-96fb-46d0-af95-aaa5861ab6c5', 'ba7a0f61-413e-4e7b-99f3-6aba1c93848a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('09df9672-96fb-46d0-af95-aaa5861ab6c5', 'f707f8c6-baec-4786-bc50-b6906af5bd2d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5d10d4ff-4d8c-4d94-9a09-714f12183c28', '58696193-f5b7-4c57-8c1f-b5eef29549a6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5d10d4ff-4d8c-4d94-9a09-714f12183c28', 'a23e824f-48fc-4875-a533-de27e522fbdf', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5d10d4ff-4d8c-4d94-9a09-714f12183c28', 'ba7a0f61-413e-4e7b-99f3-6aba1c93848a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5d10d4ff-4d8c-4d94-9a09-714f12183c28', 'f707f8c6-baec-4786-bc50-b6906af5bd2d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5d10d4ff-4d8c-4d94-9a09-714f12183c28', '56c8742b-0021-4d86-aa4d-79c81885ce46', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('58696193-f5b7-4c57-8c1f-b5eef29549a6', '5d10d4ff-4d8c-4d94-9a09-714f12183c28', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('58696193-f5b7-4c57-8c1f-b5eef29549a6', 'a23e824f-48fc-4875-a533-de27e522fbdf', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('58696193-f5b7-4c57-8c1f-b5eef29549a6', 'ba7a0f61-413e-4e7b-99f3-6aba1c93848a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('58696193-f5b7-4c57-8c1f-b5eef29549a6', 'f707f8c6-baec-4786-bc50-b6906af5bd2d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('58696193-f5b7-4c57-8c1f-b5eef29549a6', '56c8742b-0021-4d86-aa4d-79c81885ce46', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a23e824f-48fc-4875-a533-de27e522fbdf', '5d10d4ff-4d8c-4d94-9a09-714f12183c28', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a23e824f-48fc-4875-a533-de27e522fbdf', '58696193-f5b7-4c57-8c1f-b5eef29549a6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a23e824f-48fc-4875-a533-de27e522fbdf', 'ba7a0f61-413e-4e7b-99f3-6aba1c93848a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a23e824f-48fc-4875-a533-de27e522fbdf', 'f707f8c6-baec-4786-bc50-b6906af5bd2d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a23e824f-48fc-4875-a533-de27e522fbdf', '56c8742b-0021-4d86-aa4d-79c81885ce46', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba7a0f61-413e-4e7b-99f3-6aba1c93848a', '5d10d4ff-4d8c-4d94-9a09-714f12183c28', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba7a0f61-413e-4e7b-99f3-6aba1c93848a', '58696193-f5b7-4c57-8c1f-b5eef29549a6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba7a0f61-413e-4e7b-99f3-6aba1c93848a', 'a23e824f-48fc-4875-a533-de27e522fbdf', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba7a0f61-413e-4e7b-99f3-6aba1c93848a', 'f707f8c6-baec-4786-bc50-b6906af5bd2d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba7a0f61-413e-4e7b-99f3-6aba1c93848a', '56c8742b-0021-4d86-aa4d-79c81885ce46', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f707f8c6-baec-4786-bc50-b6906af5bd2d', '5d10d4ff-4d8c-4d94-9a09-714f12183c28', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f707f8c6-baec-4786-bc50-b6906af5bd2d', '58696193-f5b7-4c57-8c1f-b5eef29549a6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f707f8c6-baec-4786-bc50-b6906af5bd2d', 'a23e824f-48fc-4875-a533-de27e522fbdf', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f707f8c6-baec-4786-bc50-b6906af5bd2d', 'ba7a0f61-413e-4e7b-99f3-6aba1c93848a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f707f8c6-baec-4786-bc50-b6906af5bd2d', '56c8742b-0021-4d86-aa4d-79c81885ce46', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('56c8742b-0021-4d86-aa4d-79c81885ce46', '5d10d4ff-4d8c-4d94-9a09-714f12183c28', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('56c8742b-0021-4d86-aa4d-79c81885ce46', '58696193-f5b7-4c57-8c1f-b5eef29549a6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('56c8742b-0021-4d86-aa4d-79c81885ce46', 'a23e824f-48fc-4875-a533-de27e522fbdf', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('56c8742b-0021-4d86-aa4d-79c81885ce46', 'ba7a0f61-413e-4e7b-99f3-6aba1c93848a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('56c8742b-0021-4d86-aa4d-79c81885ce46', 'f707f8c6-baec-4786-bc50-b6906af5bd2d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('00e03881-a4ca-4310-b494-da3816b0740a', '5d10d4ff-4d8c-4d94-9a09-714f12183c28', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('00e03881-a4ca-4310-b494-da3816b0740a', '58696193-f5b7-4c57-8c1f-b5eef29549a6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('00e03881-a4ca-4310-b494-da3816b0740a', 'a23e824f-48fc-4875-a533-de27e522fbdf', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('00e03881-a4ca-4310-b494-da3816b0740a', 'ba7a0f61-413e-4e7b-99f3-6aba1c93848a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('00e03881-a4ca-4310-b494-da3816b0740a', 'f707f8c6-baec-4786-bc50-b6906af5bd2d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4477ab2e-f028-496e-ae4d-c912aac39bfb', 'e2b76e53-1ece-4418-996a-9cbf66dc5ea6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4477ab2e-f028-496e-ae4d-c912aac39bfb', '0b6a52bd-793d-4a6b-8d36-b1306237abaf', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4477ab2e-f028-496e-ae4d-c912aac39bfb', 'a33ebcdb-dc75-4390-9f74-4d3f49bc7ad0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4477ab2e-f028-496e-ae4d-c912aac39bfb', 'cb8e3acd-ba6e-4ae1-bc7c-94fdcf630db5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4477ab2e-f028-496e-ae4d-c912aac39bfb', '1159212c-32ae-4a5d-859a-108f2b52d39f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e2b76e53-1ece-4418-996a-9cbf66dc5ea6', '4477ab2e-f028-496e-ae4d-c912aac39bfb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e2b76e53-1ece-4418-996a-9cbf66dc5ea6', '0b6a52bd-793d-4a6b-8d36-b1306237abaf', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e2b76e53-1ece-4418-996a-9cbf66dc5ea6', 'a33ebcdb-dc75-4390-9f74-4d3f49bc7ad0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e2b76e53-1ece-4418-996a-9cbf66dc5ea6', 'cb8e3acd-ba6e-4ae1-bc7c-94fdcf630db5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e2b76e53-1ece-4418-996a-9cbf66dc5ea6', '1159212c-32ae-4a5d-859a-108f2b52d39f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0b6a52bd-793d-4a6b-8d36-b1306237abaf', '4477ab2e-f028-496e-ae4d-c912aac39bfb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0b6a52bd-793d-4a6b-8d36-b1306237abaf', 'e2b76e53-1ece-4418-996a-9cbf66dc5ea6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0b6a52bd-793d-4a6b-8d36-b1306237abaf', 'a33ebcdb-dc75-4390-9f74-4d3f49bc7ad0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0b6a52bd-793d-4a6b-8d36-b1306237abaf', 'cb8e3acd-ba6e-4ae1-bc7c-94fdcf630db5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0b6a52bd-793d-4a6b-8d36-b1306237abaf', '1159212c-32ae-4a5d-859a-108f2b52d39f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a33ebcdb-dc75-4390-9f74-4d3f49bc7ad0', '4477ab2e-f028-496e-ae4d-c912aac39bfb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a33ebcdb-dc75-4390-9f74-4d3f49bc7ad0', 'e2b76e53-1ece-4418-996a-9cbf66dc5ea6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a33ebcdb-dc75-4390-9f74-4d3f49bc7ad0', '0b6a52bd-793d-4a6b-8d36-b1306237abaf', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a33ebcdb-dc75-4390-9f74-4d3f49bc7ad0', 'cb8e3acd-ba6e-4ae1-bc7c-94fdcf630db5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a33ebcdb-dc75-4390-9f74-4d3f49bc7ad0', '1159212c-32ae-4a5d-859a-108f2b52d39f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cb8e3acd-ba6e-4ae1-bc7c-94fdcf630db5', '4477ab2e-f028-496e-ae4d-c912aac39bfb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cb8e3acd-ba6e-4ae1-bc7c-94fdcf630db5', 'e2b76e53-1ece-4418-996a-9cbf66dc5ea6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cb8e3acd-ba6e-4ae1-bc7c-94fdcf630db5', '0b6a52bd-793d-4a6b-8d36-b1306237abaf', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cb8e3acd-ba6e-4ae1-bc7c-94fdcf630db5', 'a33ebcdb-dc75-4390-9f74-4d3f49bc7ad0', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cb8e3acd-ba6e-4ae1-bc7c-94fdcf630db5', '1159212c-32ae-4a5d-859a-108f2b52d39f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1159212c-32ae-4a5d-859a-108f2b52d39f', '4477ab2e-f028-496e-ae4d-c912aac39bfb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1159212c-32ae-4a5d-859a-108f2b52d39f', 'e2b76e53-1ece-4418-996a-9cbf66dc5ea6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1159212c-32ae-4a5d-859a-108f2b52d39f', '0b6a52bd-793d-4a6b-8d36-b1306237abaf', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1159212c-32ae-4a5d-859a-108f2b52d39f', 'a33ebcdb-dc75-4390-9f74-4d3f49bc7ad0', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1159212c-32ae-4a5d-859a-108f2b52d39f', 'cb8e3acd-ba6e-4ae1-bc7c-94fdcf630db5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7b4419c6-db53-4e78-8dd8-a7deb3b5fb43', '4477ab2e-f028-496e-ae4d-c912aac39bfb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7b4419c6-db53-4e78-8dd8-a7deb3b5fb43', 'e2b76e53-1ece-4418-996a-9cbf66dc5ea6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7b4419c6-db53-4e78-8dd8-a7deb3b5fb43', '0b6a52bd-793d-4a6b-8d36-b1306237abaf', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7b4419c6-db53-4e78-8dd8-a7deb3b5fb43', 'a33ebcdb-dc75-4390-9f74-4d3f49bc7ad0', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7b4419c6-db53-4e78-8dd8-a7deb3b5fb43', 'cb8e3acd-ba6e-4ae1-bc7c-94fdcf630db5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3adc14a1-e06e-4cdb-8d3a-074240458467', '4477ab2e-f028-496e-ae4d-c912aac39bfb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3adc14a1-e06e-4cdb-8d3a-074240458467', 'e2b76e53-1ece-4418-996a-9cbf66dc5ea6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3adc14a1-e06e-4cdb-8d3a-074240458467', '0b6a52bd-793d-4a6b-8d36-b1306237abaf', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3adc14a1-e06e-4cdb-8d3a-074240458467', 'a33ebcdb-dc75-4390-9f74-4d3f49bc7ad0', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3adc14a1-e06e-4cdb-8d3a-074240458467', 'cb8e3acd-ba6e-4ae1-bc7c-94fdcf630db5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('769c8d38-ce91-43c5-a9f6-4c7ab86b773e', 'a51932c7-e8d2-4112-b28d-9412d191174d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('769c8d38-ce91-43c5-a9f6-4c7ab86b773e', '4477ab2e-f028-496e-ae4d-c912aac39bfb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('769c8d38-ce91-43c5-a9f6-4c7ab86b773e', 'e2b76e53-1ece-4418-996a-9cbf66dc5ea6', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('769c8d38-ce91-43c5-a9f6-4c7ab86b773e', '0b6a52bd-793d-4a6b-8d36-b1306237abaf', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('769c8d38-ce91-43c5-a9f6-4c7ab86b773e', 'a33ebcdb-dc75-4390-9f74-4d3f49bc7ad0', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe0761be-026a-4841-87a6-aecd0854d379', '5d10d4ff-4d8c-4d94-9a09-714f12183c28', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe0761be-026a-4841-87a6-aecd0854d379', '58696193-f5b7-4c57-8c1f-b5eef29549a6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe0761be-026a-4841-87a6-aecd0854d379', 'a23e824f-48fc-4875-a533-de27e522fbdf', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe0761be-026a-4841-87a6-aecd0854d379', 'ba7a0f61-413e-4e7b-99f3-6aba1c93848a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe0761be-026a-4841-87a6-aecd0854d379', 'f707f8c6-baec-4786-bc50-b6906af5bd2d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a51932c7-e8d2-4112-b28d-9412d191174d', '769c8d38-ce91-43c5-a9f6-4c7ab86b773e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a51932c7-e8d2-4112-b28d-9412d191174d', '4477ab2e-f028-496e-ae4d-c912aac39bfb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a51932c7-e8d2-4112-b28d-9412d191174d', 'e2b76e53-1ece-4418-996a-9cbf66dc5ea6', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a51932c7-e8d2-4112-b28d-9412d191174d', '0b6a52bd-793d-4a6b-8d36-b1306237abaf', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a51932c7-e8d2-4112-b28d-9412d191174d', 'a33ebcdb-dc75-4390-9f74-4d3f49bc7ad0', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a8172cd-a930-4d80-a8e6-afbefe817d6b', '457b3dff-59f8-4211-a2c5-02004ceabbb0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a8172cd-a930-4d80-a8e6-afbefe817d6b', '6e02676c-ebdd-4aee-91a0-9667dd631935', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a8172cd-a930-4d80-a8e6-afbefe817d6b', '7801e677-b6c3-4ed1-bbfe-ab716460423a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a8172cd-a930-4d80-a8e6-afbefe817d6b', 'd57d7f1d-ac7d-473a-8520-3461e5ee96b2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a8172cd-a930-4d80-a8e6-afbefe817d6b', 'ed960741-d825-45b9-a233-a2697b36925f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('457b3dff-59f8-4211-a2c5-02004ceabbb0', '3a8172cd-a930-4d80-a8e6-afbefe817d6b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('457b3dff-59f8-4211-a2c5-02004ceabbb0', '6e02676c-ebdd-4aee-91a0-9667dd631935', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('457b3dff-59f8-4211-a2c5-02004ceabbb0', '7801e677-b6c3-4ed1-bbfe-ab716460423a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('457b3dff-59f8-4211-a2c5-02004ceabbb0', 'd57d7f1d-ac7d-473a-8520-3461e5ee96b2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('457b3dff-59f8-4211-a2c5-02004ceabbb0', 'ed960741-d825-45b9-a233-a2697b36925f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6e02676c-ebdd-4aee-91a0-9667dd631935', '3a8172cd-a930-4d80-a8e6-afbefe817d6b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6e02676c-ebdd-4aee-91a0-9667dd631935', '457b3dff-59f8-4211-a2c5-02004ceabbb0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6e02676c-ebdd-4aee-91a0-9667dd631935', '7801e677-b6c3-4ed1-bbfe-ab716460423a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6e02676c-ebdd-4aee-91a0-9667dd631935', 'd57d7f1d-ac7d-473a-8520-3461e5ee96b2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6e02676c-ebdd-4aee-91a0-9667dd631935', 'ed960741-d825-45b9-a233-a2697b36925f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7801e677-b6c3-4ed1-bbfe-ab716460423a', '3a8172cd-a930-4d80-a8e6-afbefe817d6b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7801e677-b6c3-4ed1-bbfe-ab716460423a', '457b3dff-59f8-4211-a2c5-02004ceabbb0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7801e677-b6c3-4ed1-bbfe-ab716460423a', '6e02676c-ebdd-4aee-91a0-9667dd631935', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7801e677-b6c3-4ed1-bbfe-ab716460423a', 'd57d7f1d-ac7d-473a-8520-3461e5ee96b2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7801e677-b6c3-4ed1-bbfe-ab716460423a', 'ed960741-d825-45b9-a233-a2697b36925f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d57d7f1d-ac7d-473a-8520-3461e5ee96b2', '3a8172cd-a930-4d80-a8e6-afbefe817d6b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d57d7f1d-ac7d-473a-8520-3461e5ee96b2', '457b3dff-59f8-4211-a2c5-02004ceabbb0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d57d7f1d-ac7d-473a-8520-3461e5ee96b2', '6e02676c-ebdd-4aee-91a0-9667dd631935', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d57d7f1d-ac7d-473a-8520-3461e5ee96b2', '7801e677-b6c3-4ed1-bbfe-ab716460423a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d57d7f1d-ac7d-473a-8520-3461e5ee96b2', 'ed960741-d825-45b9-a233-a2697b36925f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('48bd6d54-887d-4ee3-8b0e-610120067759', '3a8172cd-a930-4d80-a8e6-afbefe817d6b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('48bd6d54-887d-4ee3-8b0e-610120067759', '457b3dff-59f8-4211-a2c5-02004ceabbb0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('48bd6d54-887d-4ee3-8b0e-610120067759', '6e02676c-ebdd-4aee-91a0-9667dd631935', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('48bd6d54-887d-4ee3-8b0e-610120067759', '7801e677-b6c3-4ed1-bbfe-ab716460423a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('48bd6d54-887d-4ee3-8b0e-610120067759', 'd57d7f1d-ac7d-473a-8520-3461e5ee96b2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ed960741-d825-45b9-a233-a2697b36925f', '3a8172cd-a930-4d80-a8e6-afbefe817d6b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ed960741-d825-45b9-a233-a2697b36925f', '457b3dff-59f8-4211-a2c5-02004ceabbb0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ed960741-d825-45b9-a233-a2697b36925f', '6e02676c-ebdd-4aee-91a0-9667dd631935', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ed960741-d825-45b9-a233-a2697b36925f', '7801e677-b6c3-4ed1-bbfe-ab716460423a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ed960741-d825-45b9-a233-a2697b36925f', 'd57d7f1d-ac7d-473a-8520-3461e5ee96b2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c02abe76-8295-4f53-80db-9c04280a14f4', '3a8172cd-a930-4d80-a8e6-afbefe817d6b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c02abe76-8295-4f53-80db-9c04280a14f4', '457b3dff-59f8-4211-a2c5-02004ceabbb0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c02abe76-8295-4f53-80db-9c04280a14f4', '6e02676c-ebdd-4aee-91a0-9667dd631935', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c02abe76-8295-4f53-80db-9c04280a14f4', '7801e677-b6c3-4ed1-bbfe-ab716460423a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c02abe76-8295-4f53-80db-9c04280a14f4', 'd57d7f1d-ac7d-473a-8520-3461e5ee96b2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a195114-2c1e-4ac3-97ae-d4a9dca6b643', '3a8172cd-a930-4d80-a8e6-afbefe817d6b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a195114-2c1e-4ac3-97ae-d4a9dca6b643', '457b3dff-59f8-4211-a2c5-02004ceabbb0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a195114-2c1e-4ac3-97ae-d4a9dca6b643', '6e02676c-ebdd-4aee-91a0-9667dd631935', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a195114-2c1e-4ac3-97ae-d4a9dca6b643', '7801e677-b6c3-4ed1-bbfe-ab716460423a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a195114-2c1e-4ac3-97ae-d4a9dca6b643', 'd57d7f1d-ac7d-473a-8520-3461e5ee96b2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d387855e-8e6b-4e5b-a599-a805828b54de', '8149ef71-3be5-4b60-a9b9-f1b10e494e9c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d387855e-8e6b-4e5b-a599-a805828b54de', 'cf4d5ad1-e149-4249-82ed-9fa5bf2579be', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d387855e-8e6b-4e5b-a599-a805828b54de', '3a8172cd-a930-4d80-a8e6-afbefe817d6b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d387855e-8e6b-4e5b-a599-a805828b54de', '457b3dff-59f8-4211-a2c5-02004ceabbb0', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d387855e-8e6b-4e5b-a599-a805828b54de', '6e02676c-ebdd-4aee-91a0-9667dd631935', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8149ef71-3be5-4b60-a9b9-f1b10e494e9c', 'd387855e-8e6b-4e5b-a599-a805828b54de', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8149ef71-3be5-4b60-a9b9-f1b10e494e9c', 'cf4d5ad1-e149-4249-82ed-9fa5bf2579be', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8149ef71-3be5-4b60-a9b9-f1b10e494e9c', '3a8172cd-a930-4d80-a8e6-afbefe817d6b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8149ef71-3be5-4b60-a9b9-f1b10e494e9c', '457b3dff-59f8-4211-a2c5-02004ceabbb0', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8149ef71-3be5-4b60-a9b9-f1b10e494e9c', '6e02676c-ebdd-4aee-91a0-9667dd631935', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cf4d5ad1-e149-4249-82ed-9fa5bf2579be', 'd387855e-8e6b-4e5b-a599-a805828b54de', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cf4d5ad1-e149-4249-82ed-9fa5bf2579be', '8149ef71-3be5-4b60-a9b9-f1b10e494e9c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cf4d5ad1-e149-4249-82ed-9fa5bf2579be', '3a8172cd-a930-4d80-a8e6-afbefe817d6b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cf4d5ad1-e149-4249-82ed-9fa5bf2579be', '457b3dff-59f8-4211-a2c5-02004ceabbb0', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cf4d5ad1-e149-4249-82ed-9fa5bf2579be', '6e02676c-ebdd-4aee-91a0-9667dd631935', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fff43558-0d0f-41b7-9671-08abc9e7fd55', '3a8172cd-a930-4d80-a8e6-afbefe817d6b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fff43558-0d0f-41b7-9671-08abc9e7fd55', '457b3dff-59f8-4211-a2c5-02004ceabbb0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fff43558-0d0f-41b7-9671-08abc9e7fd55', '6e02676c-ebdd-4aee-91a0-9667dd631935', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fff43558-0d0f-41b7-9671-08abc9e7fd55', '7801e677-b6c3-4ed1-bbfe-ab716460423a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fff43558-0d0f-41b7-9671-08abc9e7fd55', 'd57d7f1d-ac7d-473a-8520-3461e5ee96b2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75d978d9-cc0a-46a8-ac67-2c90646f7fe7', 'e6086f6b-2c2f-4b05-81cd-ee50341d1e19', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75d978d9-cc0a-46a8-ac67-2c90646f7fe7', '3a8172cd-a930-4d80-a8e6-afbefe817d6b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75d978d9-cc0a-46a8-ac67-2c90646f7fe7', '457b3dff-59f8-4211-a2c5-02004ceabbb0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6a85e81e-7ef5-468b-a6a0-b41360582b4b', '3a8172cd-a930-4d80-a8e6-afbefe817d6b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6a85e81e-7ef5-468b-a6a0-b41360582b4b', '457b3dff-59f8-4211-a2c5-02004ceabbb0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6a85e81e-7ef5-468b-a6a0-b41360582b4b', '6e02676c-ebdd-4aee-91a0-9667dd631935', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6a85e81e-7ef5-468b-a6a0-b41360582b4b', '7801e677-b6c3-4ed1-bbfe-ab716460423a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6a85e81e-7ef5-468b-a6a0-b41360582b4b', 'd57d7f1d-ac7d-473a-8520-3461e5ee96b2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e6086f6b-2c2f-4b05-81cd-ee50341d1e19', '75d978d9-cc0a-46a8-ac67-2c90646f7fe7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e6086f6b-2c2f-4b05-81cd-ee50341d1e19', '3a8172cd-a930-4d80-a8e6-afbefe817d6b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e6086f6b-2c2f-4b05-81cd-ee50341d1e19', '457b3dff-59f8-4211-a2c5-02004ceabbb0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('602447ba-8a9b-4171-b6b6-a23077af1bc4', '3a8172cd-a930-4d80-a8e6-afbefe817d6b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('602447ba-8a9b-4171-b6b6-a23077af1bc4', '457b3dff-59f8-4211-a2c5-02004ceabbb0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('602447ba-8a9b-4171-b6b6-a23077af1bc4', '6e02676c-ebdd-4aee-91a0-9667dd631935', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('602447ba-8a9b-4171-b6b6-a23077af1bc4', '7801e677-b6c3-4ed1-bbfe-ab716460423a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('602447ba-8a9b-4171-b6b6-a23077af1bc4', 'd57d7f1d-ac7d-473a-8520-3461e5ee96b2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1382130a-15d3-4fc8-b211-9d69a4a4f5c7', '3a8172cd-a930-4d80-a8e6-afbefe817d6b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1382130a-15d3-4fc8-b211-9d69a4a4f5c7', '457b3dff-59f8-4211-a2c5-02004ceabbb0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1382130a-15d3-4fc8-b211-9d69a4a4f5c7', '6e02676c-ebdd-4aee-91a0-9667dd631935', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1382130a-15d3-4fc8-b211-9d69a4a4f5c7', '7801e677-b6c3-4ed1-bbfe-ab716460423a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1382130a-15d3-4fc8-b211-9d69a4a4f5c7', 'd57d7f1d-ac7d-473a-8520-3461e5ee96b2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6f3ad445-c833-4dea-b8f6-9d4c2b151de4', '8593f083-fb57-49cf-8e63-baa3e07d0a43', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6f3ad445-c833-4dea-b8f6-9d4c2b151de4', '9f49c067-a4d1-4a59-b5d3-b6ba2bab55c3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6f3ad445-c833-4dea-b8f6-9d4c2b151de4', 'fd8f313d-ed26-4965-a0ad-b9fb92de8379', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6f3ad445-c833-4dea-b8f6-9d4c2b151de4', '04ad1381-3145-41e9-9808-b6951b25b73d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6f3ad445-c833-4dea-b8f6-9d4c2b151de4', '745b2223-a012-4dc8-aa64-e0453d0e407d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8593f083-fb57-49cf-8e63-baa3e07d0a43', '6f3ad445-c833-4dea-b8f6-9d4c2b151de4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8593f083-fb57-49cf-8e63-baa3e07d0a43', '9f49c067-a4d1-4a59-b5d3-b6ba2bab55c3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8593f083-fb57-49cf-8e63-baa3e07d0a43', 'fd8f313d-ed26-4965-a0ad-b9fb92de8379', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8593f083-fb57-49cf-8e63-baa3e07d0a43', '04ad1381-3145-41e9-9808-b6951b25b73d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8593f083-fb57-49cf-8e63-baa3e07d0a43', '745b2223-a012-4dc8-aa64-e0453d0e407d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9f49c067-a4d1-4a59-b5d3-b6ba2bab55c3', '6f3ad445-c833-4dea-b8f6-9d4c2b151de4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9f49c067-a4d1-4a59-b5d3-b6ba2bab55c3', '8593f083-fb57-49cf-8e63-baa3e07d0a43', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9f49c067-a4d1-4a59-b5d3-b6ba2bab55c3', 'fd8f313d-ed26-4965-a0ad-b9fb92de8379', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9f49c067-a4d1-4a59-b5d3-b6ba2bab55c3', '04ad1381-3145-41e9-9808-b6951b25b73d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9f49c067-a4d1-4a59-b5d3-b6ba2bab55c3', '745b2223-a012-4dc8-aa64-e0453d0e407d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fd8f313d-ed26-4965-a0ad-b9fb92de8379', '04ad1381-3145-41e9-9808-b6951b25b73d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fd8f313d-ed26-4965-a0ad-b9fb92de8379', '745b2223-a012-4dc8-aa64-e0453d0e407d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fd8f313d-ed26-4965-a0ad-b9fb92de8379', 'b677cd3d-e8a2-4632-b14a-3d96cb33af11', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fd8f313d-ed26-4965-a0ad-b9fb92de8379', '3f1dec17-20d8-4dcb-9e8f-a33ddd6a1691', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fd8f313d-ed26-4965-a0ad-b9fb92de8379', 'ac64f82f-d7cc-4730-947e-0f41f8cfed65', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('58dfa8f2-c8c9-4eef-9a6d-c9abbccac09c', '6e5af508-69ab-46a3-8f05-90484daa8736', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('58dfa8f2-c8c9-4eef-9a6d-c9abbccac09c', 'ad3beda0-1c75-4754-a5e0-480517aa89c7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('58dfa8f2-c8c9-4eef-9a6d-c9abbccac09c', '9252f5ac-02a2-4573-8ca9-6e02b6efc513', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('04ad1381-3145-41e9-9808-b6951b25b73d', 'fd8f313d-ed26-4965-a0ad-b9fb92de8379', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('04ad1381-3145-41e9-9808-b6951b25b73d', '745b2223-a012-4dc8-aa64-e0453d0e407d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('04ad1381-3145-41e9-9808-b6951b25b73d', 'b677cd3d-e8a2-4632-b14a-3d96cb33af11', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('04ad1381-3145-41e9-9808-b6951b25b73d', '3f1dec17-20d8-4dcb-9e8f-a33ddd6a1691', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('04ad1381-3145-41e9-9808-b6951b25b73d', 'ac64f82f-d7cc-4730-947e-0f41f8cfed65', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('745b2223-a012-4dc8-aa64-e0453d0e407d', 'fd8f313d-ed26-4965-a0ad-b9fb92de8379', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('745b2223-a012-4dc8-aa64-e0453d0e407d', '04ad1381-3145-41e9-9808-b6951b25b73d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('745b2223-a012-4dc8-aa64-e0453d0e407d', 'b677cd3d-e8a2-4632-b14a-3d96cb33af11', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('745b2223-a012-4dc8-aa64-e0453d0e407d', '3f1dec17-20d8-4dcb-9e8f-a33ddd6a1691', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('745b2223-a012-4dc8-aa64-e0453d0e407d', 'ac64f82f-d7cc-4730-947e-0f41f8cfed65', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b677cd3d-e8a2-4632-b14a-3d96cb33af11', 'fd8f313d-ed26-4965-a0ad-b9fb92de8379', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b677cd3d-e8a2-4632-b14a-3d96cb33af11', '04ad1381-3145-41e9-9808-b6951b25b73d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b677cd3d-e8a2-4632-b14a-3d96cb33af11', '745b2223-a012-4dc8-aa64-e0453d0e407d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b677cd3d-e8a2-4632-b14a-3d96cb33af11', '3f1dec17-20d8-4dcb-9e8f-a33ddd6a1691', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b677cd3d-e8a2-4632-b14a-3d96cb33af11', 'ac64f82f-d7cc-4730-947e-0f41f8cfed65', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f1dec17-20d8-4dcb-9e8f-a33ddd6a1691', 'fd8f313d-ed26-4965-a0ad-b9fb92de8379', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f1dec17-20d8-4dcb-9e8f-a33ddd6a1691', '04ad1381-3145-41e9-9808-b6951b25b73d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f1dec17-20d8-4dcb-9e8f-a33ddd6a1691', '745b2223-a012-4dc8-aa64-e0453d0e407d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f1dec17-20d8-4dcb-9e8f-a33ddd6a1691', 'b677cd3d-e8a2-4632-b14a-3d96cb33af11', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f1dec17-20d8-4dcb-9e8f-a33ddd6a1691', 'ac64f82f-d7cc-4730-947e-0f41f8cfed65', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ac64f82f-d7cc-4730-947e-0f41f8cfed65', 'fd8f313d-ed26-4965-a0ad-b9fb92de8379', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ac64f82f-d7cc-4730-947e-0f41f8cfed65', '04ad1381-3145-41e9-9808-b6951b25b73d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ac64f82f-d7cc-4730-947e-0f41f8cfed65', '745b2223-a012-4dc8-aa64-e0453d0e407d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ac64f82f-d7cc-4730-947e-0f41f8cfed65', 'b677cd3d-e8a2-4632-b14a-3d96cb33af11', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ac64f82f-d7cc-4730-947e-0f41f8cfed65', '3f1dec17-20d8-4dcb-9e8f-a33ddd6a1691', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ff9b276b-fa1f-40c1-a6fa-ca514180b196', 'fd8f313d-ed26-4965-a0ad-b9fb92de8379', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ff9b276b-fa1f-40c1-a6fa-ca514180b196', '04ad1381-3145-41e9-9808-b6951b25b73d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ff9b276b-fa1f-40c1-a6fa-ca514180b196', '745b2223-a012-4dc8-aa64-e0453d0e407d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ff9b276b-fa1f-40c1-a6fa-ca514180b196', 'b677cd3d-e8a2-4632-b14a-3d96cb33af11', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ff9b276b-fa1f-40c1-a6fa-ca514180b196', '3f1dec17-20d8-4dcb-9e8f-a33ddd6a1691', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('30cb1de1-d458-4e1a-9605-e466d1c13c30', 'fd8f313d-ed26-4965-a0ad-b9fb92de8379', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('30cb1de1-d458-4e1a-9605-e466d1c13c30', '04ad1381-3145-41e9-9808-b6951b25b73d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('30cb1de1-d458-4e1a-9605-e466d1c13c30', '745b2223-a012-4dc8-aa64-e0453d0e407d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('30cb1de1-d458-4e1a-9605-e466d1c13c30', 'b677cd3d-e8a2-4632-b14a-3d96cb33af11', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('30cb1de1-d458-4e1a-9605-e466d1c13c30', '3f1dec17-20d8-4dcb-9e8f-a33ddd6a1691', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('73951126-fd42-45f7-8c21-9a7874fa28da', 'fd8f313d-ed26-4965-a0ad-b9fb92de8379', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('73951126-fd42-45f7-8c21-9a7874fa28da', '04ad1381-3145-41e9-9808-b6951b25b73d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('73951126-fd42-45f7-8c21-9a7874fa28da', '745b2223-a012-4dc8-aa64-e0453d0e407d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('73951126-fd42-45f7-8c21-9a7874fa28da', 'b677cd3d-e8a2-4632-b14a-3d96cb33af11', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('73951126-fd42-45f7-8c21-9a7874fa28da', '3f1dec17-20d8-4dcb-9e8f-a33ddd6a1691', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('be0669d3-f062-4246-bba0-0567d9f4e993', 'fd8f313d-ed26-4965-a0ad-b9fb92de8379', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('be0669d3-f062-4246-bba0-0567d9f4e993', '04ad1381-3145-41e9-9808-b6951b25b73d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('be0669d3-f062-4246-bba0-0567d9f4e993', '745b2223-a012-4dc8-aa64-e0453d0e407d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('be0669d3-f062-4246-bba0-0567d9f4e993', 'b677cd3d-e8a2-4632-b14a-3d96cb33af11', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('be0669d3-f062-4246-bba0-0567d9f4e993', '3f1dec17-20d8-4dcb-9e8f-a33ddd6a1691', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cdfafb45-5417-4862-8d82-677c445cd3d3', '6f3ad445-c833-4dea-b8f6-9d4c2b151de4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cdfafb45-5417-4862-8d82-677c445cd3d3', '8593f083-fb57-49cf-8e63-baa3e07d0a43', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cdfafb45-5417-4862-8d82-677c445cd3d3', '9f49c067-a4d1-4a59-b5d3-b6ba2bab55c3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cdfafb45-5417-4862-8d82-677c445cd3d3', 'fd8f313d-ed26-4965-a0ad-b9fb92de8379', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cdfafb45-5417-4862-8d82-677c445cd3d3', '04ad1381-3145-41e9-9808-b6951b25b73d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb632143-11e2-4856-901f-d69b7a4283ec', '620749ee-6ce4-42ad-b706-1d71f913c3ab', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb632143-11e2-4856-901f-d69b7a4283ec', 'd3e7016d-202f-4638-bdcd-e90310a0ecf0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb632143-11e2-4856-901f-d69b7a4283ec', '1ecd53cb-3cc2-48b1-a6dd-37d5c793b60d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb632143-11e2-4856-901f-d69b7a4283ec', '4bbc56c4-6370-4fdb-a33b-57afc190b588', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb632143-11e2-4856-901f-d69b7a4283ec', '50c200b6-b7dd-4a95-829e-a275f6e3d21d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('620749ee-6ce4-42ad-b706-1d71f913c3ab', 'eb632143-11e2-4856-901f-d69b7a4283ec', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('620749ee-6ce4-42ad-b706-1d71f913c3ab', 'd3e7016d-202f-4638-bdcd-e90310a0ecf0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('620749ee-6ce4-42ad-b706-1d71f913c3ab', '1ecd53cb-3cc2-48b1-a6dd-37d5c793b60d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('620749ee-6ce4-42ad-b706-1d71f913c3ab', '4bbc56c4-6370-4fdb-a33b-57afc190b588', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('620749ee-6ce4-42ad-b706-1d71f913c3ab', '50c200b6-b7dd-4a95-829e-a275f6e3d21d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd200722-98da-475c-ac65-2c1e03bcfe63', '620749ee-6ce4-42ad-b706-1d71f913c3ab', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd200722-98da-475c-ac65-2c1e03bcfe63', 'eb632143-11e2-4856-901f-d69b7a4283ec', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd200722-98da-475c-ac65-2c1e03bcfe63', 'd3e7016d-202f-4638-bdcd-e90310a0ecf0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd200722-98da-475c-ac65-2c1e03bcfe63', '1ecd53cb-3cc2-48b1-a6dd-37d5c793b60d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd200722-98da-475c-ac65-2c1e03bcfe63', '4bbc56c4-6370-4fdb-a33b-57afc190b588', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3e7016d-202f-4638-bdcd-e90310a0ecf0', '20a76776-e7ec-4190-a6cd-8da1bd082aef', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3e7016d-202f-4638-bdcd-e90310a0ecf0', 'bc9f27e1-4ee8-4b74-a41f-e09cca0e5d67', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3e7016d-202f-4638-bdcd-e90310a0ecf0', 'cdc10036-be2f-4175-816c-827a99c7cc87', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3e7016d-202f-4638-bdcd-e90310a0ecf0', 'eb632143-11e2-4856-901f-d69b7a4283ec', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3e7016d-202f-4638-bdcd-e90310a0ecf0', '620749ee-6ce4-42ad-b706-1d71f913c3ab', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ecd53cb-3cc2-48b1-a6dd-37d5c793b60d', '4bbc56c4-6370-4fdb-a33b-57afc190b588', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ecd53cb-3cc2-48b1-a6dd-37d5c793b60d', '50c200b6-b7dd-4a95-829e-a275f6e3d21d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ecd53cb-3cc2-48b1-a6dd-37d5c793b60d', 'ace6c367-7989-43b6-bee4-dcb67b5c3ba8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ecd53cb-3cc2-48b1-a6dd-37d5c793b60d', 'dffcd79d-c0a4-4f6e-bc70-e47125f0ff68', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ecd53cb-3cc2-48b1-a6dd-37d5c793b60d', 'eb632143-11e2-4856-901f-d69b7a4283ec', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4bbc56c4-6370-4fdb-a33b-57afc190b588', '1ecd53cb-3cc2-48b1-a6dd-37d5c793b60d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4bbc56c4-6370-4fdb-a33b-57afc190b588', '50c200b6-b7dd-4a95-829e-a275f6e3d21d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4bbc56c4-6370-4fdb-a33b-57afc190b588', 'ace6c367-7989-43b6-bee4-dcb67b5c3ba8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4bbc56c4-6370-4fdb-a33b-57afc190b588', 'dffcd79d-c0a4-4f6e-bc70-e47125f0ff68', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4bbc56c4-6370-4fdb-a33b-57afc190b588', 'eb632143-11e2-4856-901f-d69b7a4283ec', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('50c200b6-b7dd-4a95-829e-a275f6e3d21d', '1ecd53cb-3cc2-48b1-a6dd-37d5c793b60d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('50c200b6-b7dd-4a95-829e-a275f6e3d21d', '4bbc56c4-6370-4fdb-a33b-57afc190b588', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('50c200b6-b7dd-4a95-829e-a275f6e3d21d', 'ace6c367-7989-43b6-bee4-dcb67b5c3ba8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('50c200b6-b7dd-4a95-829e-a275f6e3d21d', 'dffcd79d-c0a4-4f6e-bc70-e47125f0ff68', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('50c200b6-b7dd-4a95-829e-a275f6e3d21d', 'eb632143-11e2-4856-901f-d69b7a4283ec', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('20a76776-e7ec-4190-a6cd-8da1bd082aef', 'd3e7016d-202f-4638-bdcd-e90310a0ecf0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('20a76776-e7ec-4190-a6cd-8da1bd082aef', 'bc9f27e1-4ee8-4b74-a41f-e09cca0e5d67', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('20a76776-e7ec-4190-a6cd-8da1bd082aef', 'cdc10036-be2f-4175-816c-827a99c7cc87', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('20a76776-e7ec-4190-a6cd-8da1bd082aef', 'eb632143-11e2-4856-901f-d69b7a4283ec', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('20a76776-e7ec-4190-a6cd-8da1bd082aef', '620749ee-6ce4-42ad-b706-1d71f913c3ab', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bc9f27e1-4ee8-4b74-a41f-e09cca0e5d67', 'd3e7016d-202f-4638-bdcd-e90310a0ecf0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bc9f27e1-4ee8-4b74-a41f-e09cca0e5d67', '20a76776-e7ec-4190-a6cd-8da1bd082aef', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bc9f27e1-4ee8-4b74-a41f-e09cca0e5d67', 'cdc10036-be2f-4175-816c-827a99c7cc87', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bc9f27e1-4ee8-4b74-a41f-e09cca0e5d67', 'eb632143-11e2-4856-901f-d69b7a4283ec', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bc9f27e1-4ee8-4b74-a41f-e09cca0e5d67', '620749ee-6ce4-42ad-b706-1d71f913c3ab', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ace6c367-7989-43b6-bee4-dcb67b5c3ba8', '1ecd53cb-3cc2-48b1-a6dd-37d5c793b60d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ace6c367-7989-43b6-bee4-dcb67b5c3ba8', '4bbc56c4-6370-4fdb-a33b-57afc190b588', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ace6c367-7989-43b6-bee4-dcb67b5c3ba8', '50c200b6-b7dd-4a95-829e-a275f6e3d21d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ace6c367-7989-43b6-bee4-dcb67b5c3ba8', 'dffcd79d-c0a4-4f6e-bc70-e47125f0ff68', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ace6c367-7989-43b6-bee4-dcb67b5c3ba8', 'eb632143-11e2-4856-901f-d69b7a4283ec', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dffcd79d-c0a4-4f6e-bc70-e47125f0ff68', '1ecd53cb-3cc2-48b1-a6dd-37d5c793b60d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dffcd79d-c0a4-4f6e-bc70-e47125f0ff68', '4bbc56c4-6370-4fdb-a33b-57afc190b588', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dffcd79d-c0a4-4f6e-bc70-e47125f0ff68', '50c200b6-b7dd-4a95-829e-a275f6e3d21d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dffcd79d-c0a4-4f6e-bc70-e47125f0ff68', 'ace6c367-7989-43b6-bee4-dcb67b5c3ba8', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dffcd79d-c0a4-4f6e-bc70-e47125f0ff68', 'eb632143-11e2-4856-901f-d69b7a4283ec', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cdc10036-be2f-4175-816c-827a99c7cc87', 'd3e7016d-202f-4638-bdcd-e90310a0ecf0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cdc10036-be2f-4175-816c-827a99c7cc87', '20a76776-e7ec-4190-a6cd-8da1bd082aef', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cdc10036-be2f-4175-816c-827a99c7cc87', 'bc9f27e1-4ee8-4b74-a41f-e09cca0e5d67', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cdc10036-be2f-4175-816c-827a99c7cc87', 'eb632143-11e2-4856-901f-d69b7a4283ec', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cdc10036-be2f-4175-816c-827a99c7cc87', '620749ee-6ce4-42ad-b706-1d71f913c3ab', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('816eb9fc-97d7-4d2e-b4a4-46d7f6337de7', 'fd8f313d-ed26-4965-a0ad-b9fb92de8379', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('816eb9fc-97d7-4d2e-b4a4-46d7f6337de7', '04ad1381-3145-41e9-9808-b6951b25b73d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('816eb9fc-97d7-4d2e-b4a4-46d7f6337de7', '745b2223-a012-4dc8-aa64-e0453d0e407d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('816eb9fc-97d7-4d2e-b4a4-46d7f6337de7', 'b677cd3d-e8a2-4632-b14a-3d96cb33af11', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('816eb9fc-97d7-4d2e-b4a4-46d7f6337de7', '3f1dec17-20d8-4dcb-9e8f-a33ddd6a1691', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3ec02c28-dee7-4e22-bf27-08754a4afe3f', '6f3ad445-c833-4dea-b8f6-9d4c2b151de4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3ec02c28-dee7-4e22-bf27-08754a4afe3f', '8593f083-fb57-49cf-8e63-baa3e07d0a43', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3ec02c28-dee7-4e22-bf27-08754a4afe3f', '9f49c067-a4d1-4a59-b5d3-b6ba2bab55c3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ad3beda0-1c75-4754-a5e0-480517aa89c7', '9252f5ac-02a2-4573-8ca9-6e02b6efc513', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ad3beda0-1c75-4754-a5e0-480517aa89c7', 'b489e9b6-88bc-4f8d-8142-6d5e27f486f6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ad3beda0-1c75-4754-a5e0-480517aa89c7', 'c02957eb-6b6b-482e-98b2-1fc107237c0c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9252f5ac-02a2-4573-8ca9-6e02b6efc513', 'ad3beda0-1c75-4754-a5e0-480517aa89c7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9252f5ac-02a2-4573-8ca9-6e02b6efc513', 'b489e9b6-88bc-4f8d-8142-6d5e27f486f6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9252f5ac-02a2-4573-8ca9-6e02b6efc513', 'c02957eb-6b6b-482e-98b2-1fc107237c0c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b489e9b6-88bc-4f8d-8142-6d5e27f486f6', 'ad3beda0-1c75-4754-a5e0-480517aa89c7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b489e9b6-88bc-4f8d-8142-6d5e27f486f6', '9252f5ac-02a2-4573-8ca9-6e02b6efc513', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b489e9b6-88bc-4f8d-8142-6d5e27f486f6', 'c02957eb-6b6b-482e-98b2-1fc107237c0c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c02957eb-6b6b-482e-98b2-1fc107237c0c', 'ad3beda0-1c75-4754-a5e0-480517aa89c7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c02957eb-6b6b-482e-98b2-1fc107237c0c', '9252f5ac-02a2-4573-8ca9-6e02b6efc513', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c02957eb-6b6b-482e-98b2-1fc107237c0c', 'b489e9b6-88bc-4f8d-8142-6d5e27f486f6', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('41f8a9d5-482f-4e6e-b354-f35c744ae6bd', '496b7bc3-9443-4fd2-918d-359151cc24a0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('41f8a9d5-482f-4e6e-b354-f35c744ae6bd', 'db54c40c-39e9-42f3-b49b-dcd9983b5661', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('41f8a9d5-482f-4e6e-b354-f35c744ae6bd', '2037adb4-5ea7-43b6-9cc2-b994c291cf9e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('41f8a9d5-482f-4e6e-b354-f35c744ae6bd', '3f6e87b0-1b59-4fe7-8cd1-d97529ebec06', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('41f8a9d5-482f-4e6e-b354-f35c744ae6bd', '1d7fe40a-2a25-4890-8552-757cabb8c2b6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('496b7bc3-9443-4fd2-918d-359151cc24a0', '41f8a9d5-482f-4e6e-b354-f35c744ae6bd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('496b7bc3-9443-4fd2-918d-359151cc24a0', 'db54c40c-39e9-42f3-b49b-dcd9983b5661', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('496b7bc3-9443-4fd2-918d-359151cc24a0', '2037adb4-5ea7-43b6-9cc2-b994c291cf9e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('496b7bc3-9443-4fd2-918d-359151cc24a0', '3f6e87b0-1b59-4fe7-8cd1-d97529ebec06', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('496b7bc3-9443-4fd2-918d-359151cc24a0', '1d7fe40a-2a25-4890-8552-757cabb8c2b6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('db54c40c-39e9-42f3-b49b-dcd9983b5661', '41f8a9d5-482f-4e6e-b354-f35c744ae6bd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('db54c40c-39e9-42f3-b49b-dcd9983b5661', '496b7bc3-9443-4fd2-918d-359151cc24a0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('db54c40c-39e9-42f3-b49b-dcd9983b5661', '2037adb4-5ea7-43b6-9cc2-b994c291cf9e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('db54c40c-39e9-42f3-b49b-dcd9983b5661', '3f6e87b0-1b59-4fe7-8cd1-d97529ebec06', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('db54c40c-39e9-42f3-b49b-dcd9983b5661', '1d7fe40a-2a25-4890-8552-757cabb8c2b6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2037adb4-5ea7-43b6-9cc2-b994c291cf9e', '41f8a9d5-482f-4e6e-b354-f35c744ae6bd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2037adb4-5ea7-43b6-9cc2-b994c291cf9e', '496b7bc3-9443-4fd2-918d-359151cc24a0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2037adb4-5ea7-43b6-9cc2-b994c291cf9e', 'db54c40c-39e9-42f3-b49b-dcd9983b5661', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2037adb4-5ea7-43b6-9cc2-b994c291cf9e', '3f6e87b0-1b59-4fe7-8cd1-d97529ebec06', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2037adb4-5ea7-43b6-9cc2-b994c291cf9e', '1d7fe40a-2a25-4890-8552-757cabb8c2b6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('efedba63-9547-4310-90c3-dde9524c5fe6', 'c0e41d68-7c3a-4d57-a87d-acb09dd0f68f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('efedba63-9547-4310-90c3-dde9524c5fe6', '41f8a9d5-482f-4e6e-b354-f35c744ae6bd', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('efedba63-9547-4310-90c3-dde9524c5fe6', '496b7bc3-9443-4fd2-918d-359151cc24a0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('efedba63-9547-4310-90c3-dde9524c5fe6', 'db54c40c-39e9-42f3-b49b-dcd9983b5661', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('efedba63-9547-4310-90c3-dde9524c5fe6', '2037adb4-5ea7-43b6-9cc2-b994c291cf9e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c0e41d68-7c3a-4d57-a87d-acb09dd0f68f', 'efedba63-9547-4310-90c3-dde9524c5fe6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c0e41d68-7c3a-4d57-a87d-acb09dd0f68f', '41f8a9d5-482f-4e6e-b354-f35c744ae6bd', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c0e41d68-7c3a-4d57-a87d-acb09dd0f68f', '496b7bc3-9443-4fd2-918d-359151cc24a0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c0e41d68-7c3a-4d57-a87d-acb09dd0f68f', 'db54c40c-39e9-42f3-b49b-dcd9983b5661', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c0e41d68-7c3a-4d57-a87d-acb09dd0f68f', '2037adb4-5ea7-43b6-9cc2-b994c291cf9e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f6e87b0-1b59-4fe7-8cd1-d97529ebec06', '41f8a9d5-482f-4e6e-b354-f35c744ae6bd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f6e87b0-1b59-4fe7-8cd1-d97529ebec06', '496b7bc3-9443-4fd2-918d-359151cc24a0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f6e87b0-1b59-4fe7-8cd1-d97529ebec06', 'db54c40c-39e9-42f3-b49b-dcd9983b5661', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f6e87b0-1b59-4fe7-8cd1-d97529ebec06', '2037adb4-5ea7-43b6-9cc2-b994c291cf9e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f6e87b0-1b59-4fe7-8cd1-d97529ebec06', '1d7fe40a-2a25-4890-8552-757cabb8c2b6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1d7fe40a-2a25-4890-8552-757cabb8c2b6', '41f8a9d5-482f-4e6e-b354-f35c744ae6bd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1d7fe40a-2a25-4890-8552-757cabb8c2b6', '496b7bc3-9443-4fd2-918d-359151cc24a0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1d7fe40a-2a25-4890-8552-757cabb8c2b6', 'db54c40c-39e9-42f3-b49b-dcd9983b5661', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1d7fe40a-2a25-4890-8552-757cabb8c2b6', '2037adb4-5ea7-43b6-9cc2-b994c291cf9e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1d7fe40a-2a25-4890-8552-757cabb8c2b6', '3f6e87b0-1b59-4fe7-8cd1-d97529ebec06', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f51b6fb1-bc4a-49fa-9e36-ee8e9b13ed51', '58dfa8f2-c8c9-4eef-9a6d-c9abbccac09c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f51b6fb1-bc4a-49fa-9e36-ee8e9b13ed51', 'ad3beda0-1c75-4754-a5e0-480517aa89c7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f51b6fb1-bc4a-49fa-9e36-ee8e9b13ed51', '9252f5ac-02a2-4573-8ca9-6e02b6efc513', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fa29664c-ce7c-43a3-bf5a-c75d32766446', '41f8a9d5-482f-4e6e-b354-f35c744ae6bd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fa29664c-ce7c-43a3-bf5a-c75d32766446', '496b7bc3-9443-4fd2-918d-359151cc24a0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fa29664c-ce7c-43a3-bf5a-c75d32766446', 'db54c40c-39e9-42f3-b49b-dcd9983b5661', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fa29664c-ce7c-43a3-bf5a-c75d32766446', '2037adb4-5ea7-43b6-9cc2-b994c291cf9e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fa29664c-ce7c-43a3-bf5a-c75d32766446', 'efedba63-9547-4310-90c3-dde9524c5fe6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6e5af508-69ab-46a3-8f05-90484daa8736', '58dfa8f2-c8c9-4eef-9a6d-c9abbccac09c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6e5af508-69ab-46a3-8f05-90484daa8736', 'ad3beda0-1c75-4754-a5e0-480517aa89c7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6e5af508-69ab-46a3-8f05-90484daa8736', '9252f5ac-02a2-4573-8ca9-6e02b6efc513', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8fc3706b-26fa-424c-b800-4cc55a7b0e7e', 'a1353bf7-2801-4f73-b51c-36f043c995d0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8fc3706b-26fa-424c-b800-4cc55a7b0e7e', '7768998e-02ba-4e0e-9602-0500b05700a3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8fc3706b-26fa-424c-b800-4cc55a7b0e7e', '94e78166-bb8f-4cbc-a257-f7230caf1ed5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8fc3706b-26fa-424c-b800-4cc55a7b0e7e', '4c766a13-9a28-4880-885b-5c1480d92db5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8fc3706b-26fa-424c-b800-4cc55a7b0e7e', '8d892bd0-be9e-4cb5-a252-ae471f64673c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('07f42b5d-03d1-4c26-9333-778acbbd6887', 'cbb387b2-456c-4033-9601-68ac129b40f1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('07f42b5d-03d1-4c26-9333-778acbbd6887', '8fc3706b-26fa-424c-b800-4cc55a7b0e7e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('07f42b5d-03d1-4c26-9333-778acbbd6887', 'a1353bf7-2801-4f73-b51c-36f043c995d0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('07f42b5d-03d1-4c26-9333-778acbbd6887', '7768998e-02ba-4e0e-9602-0500b05700a3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('07f42b5d-03d1-4c26-9333-778acbbd6887', '94e78166-bb8f-4cbc-a257-f7230caf1ed5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a1353bf7-2801-4f73-b51c-36f043c995d0', '8fc3706b-26fa-424c-b800-4cc55a7b0e7e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a1353bf7-2801-4f73-b51c-36f043c995d0', '7768998e-02ba-4e0e-9602-0500b05700a3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a1353bf7-2801-4f73-b51c-36f043c995d0', '94e78166-bb8f-4cbc-a257-f7230caf1ed5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a1353bf7-2801-4f73-b51c-36f043c995d0', '4c766a13-9a28-4880-885b-5c1480d92db5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a1353bf7-2801-4f73-b51c-36f043c995d0', '8d892bd0-be9e-4cb5-a252-ae471f64673c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7768998e-02ba-4e0e-9602-0500b05700a3', '8fc3706b-26fa-424c-b800-4cc55a7b0e7e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7768998e-02ba-4e0e-9602-0500b05700a3', 'a1353bf7-2801-4f73-b51c-36f043c995d0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7768998e-02ba-4e0e-9602-0500b05700a3', '94e78166-bb8f-4cbc-a257-f7230caf1ed5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7768998e-02ba-4e0e-9602-0500b05700a3', '4c766a13-9a28-4880-885b-5c1480d92db5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7768998e-02ba-4e0e-9602-0500b05700a3', '8d892bd0-be9e-4cb5-a252-ae471f64673c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('94e78166-bb8f-4cbc-a257-f7230caf1ed5', '8fc3706b-26fa-424c-b800-4cc55a7b0e7e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('94e78166-bb8f-4cbc-a257-f7230caf1ed5', 'a1353bf7-2801-4f73-b51c-36f043c995d0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('94e78166-bb8f-4cbc-a257-f7230caf1ed5', '7768998e-02ba-4e0e-9602-0500b05700a3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('94e78166-bb8f-4cbc-a257-f7230caf1ed5', '4c766a13-9a28-4880-885b-5c1480d92db5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('94e78166-bb8f-4cbc-a257-f7230caf1ed5', '8d892bd0-be9e-4cb5-a252-ae471f64673c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c766a13-9a28-4880-885b-5c1480d92db5', '8fc3706b-26fa-424c-b800-4cc55a7b0e7e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c766a13-9a28-4880-885b-5c1480d92db5', 'a1353bf7-2801-4f73-b51c-36f043c995d0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c766a13-9a28-4880-885b-5c1480d92db5', '7768998e-02ba-4e0e-9602-0500b05700a3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c766a13-9a28-4880-885b-5c1480d92db5', '94e78166-bb8f-4cbc-a257-f7230caf1ed5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c766a13-9a28-4880-885b-5c1480d92db5', '8d892bd0-be9e-4cb5-a252-ae471f64673c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d892bd0-be9e-4cb5-a252-ae471f64673c', '8fc3706b-26fa-424c-b800-4cc55a7b0e7e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d892bd0-be9e-4cb5-a252-ae471f64673c', 'a1353bf7-2801-4f73-b51c-36f043c995d0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d892bd0-be9e-4cb5-a252-ae471f64673c', '7768998e-02ba-4e0e-9602-0500b05700a3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d892bd0-be9e-4cb5-a252-ae471f64673c', '94e78166-bb8f-4cbc-a257-f7230caf1ed5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d892bd0-be9e-4cb5-a252-ae471f64673c', '4c766a13-9a28-4880-885b-5c1480d92db5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('72dc48fb-c34e-4fa1-bc03-f8b67425d412', 'be7df035-f0af-4d65-95e5-85588ae4eacb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('72dc48fb-c34e-4fa1-bc03-f8b67425d412', '8fc3706b-26fa-424c-b800-4cc55a7b0e7e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('72dc48fb-c34e-4fa1-bc03-f8b67425d412', '07f42b5d-03d1-4c26-9333-778acbbd6887', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('72dc48fb-c34e-4fa1-bc03-f8b67425d412', 'a1353bf7-2801-4f73-b51c-36f043c995d0', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('72dc48fb-c34e-4fa1-bc03-f8b67425d412', '7768998e-02ba-4e0e-9602-0500b05700a3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('be7df035-f0af-4d65-95e5-85588ae4eacb', '72dc48fb-c34e-4fa1-bc03-f8b67425d412', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('be7df035-f0af-4d65-95e5-85588ae4eacb', '8fc3706b-26fa-424c-b800-4cc55a7b0e7e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('be7df035-f0af-4d65-95e5-85588ae4eacb', '07f42b5d-03d1-4c26-9333-778acbbd6887', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('be7df035-f0af-4d65-95e5-85588ae4eacb', 'a1353bf7-2801-4f73-b51c-36f043c995d0', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('be7df035-f0af-4d65-95e5-85588ae4eacb', '7768998e-02ba-4e0e-9602-0500b05700a3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1b9d755e-a8a6-428e-9b8e-0fcc31d2f1fb', '8fc3706b-26fa-424c-b800-4cc55a7b0e7e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1b9d755e-a8a6-428e-9b8e-0fcc31d2f1fb', 'a1353bf7-2801-4f73-b51c-36f043c995d0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1b9d755e-a8a6-428e-9b8e-0fcc31d2f1fb', '7768998e-02ba-4e0e-9602-0500b05700a3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1b9d755e-a8a6-428e-9b8e-0fcc31d2f1fb', '94e78166-bb8f-4cbc-a257-f7230caf1ed5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1b9d755e-a8a6-428e-9b8e-0fcc31d2f1fb', '4c766a13-9a28-4880-885b-5c1480d92db5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('93a619ef-d068-4f52-96a9-ed7fb5aa88f7', '8fc3706b-26fa-424c-b800-4cc55a7b0e7e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('93a619ef-d068-4f52-96a9-ed7fb5aa88f7', 'a1353bf7-2801-4f73-b51c-36f043c995d0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('93a619ef-d068-4f52-96a9-ed7fb5aa88f7', '7768998e-02ba-4e0e-9602-0500b05700a3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('93a619ef-d068-4f52-96a9-ed7fb5aa88f7', '94e78166-bb8f-4cbc-a257-f7230caf1ed5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('93a619ef-d068-4f52-96a9-ed7fb5aa88f7', '4c766a13-9a28-4880-885b-5c1480d92db5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cbb387b2-456c-4033-9601-68ac129b40f1', '07f42b5d-03d1-4c26-9333-778acbbd6887', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cbb387b2-456c-4033-9601-68ac129b40f1', '8fc3706b-26fa-424c-b800-4cc55a7b0e7e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cbb387b2-456c-4033-9601-68ac129b40f1', 'a1353bf7-2801-4f73-b51c-36f043c995d0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cbb387b2-456c-4033-9601-68ac129b40f1', '7768998e-02ba-4e0e-9602-0500b05700a3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cbb387b2-456c-4033-9601-68ac129b40f1', '94e78166-bb8f-4cbc-a257-f7230caf1ed5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d50146f-63b7-4ea1-a62f-b5bfcc8959cd', '8fc3706b-26fa-424c-b800-4cc55a7b0e7e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d50146f-63b7-4ea1-a62f-b5bfcc8959cd', 'a1353bf7-2801-4f73-b51c-36f043c995d0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d50146f-63b7-4ea1-a62f-b5bfcc8959cd', '7768998e-02ba-4e0e-9602-0500b05700a3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d50146f-63b7-4ea1-a62f-b5bfcc8959cd', '94e78166-bb8f-4cbc-a257-f7230caf1ed5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d50146f-63b7-4ea1-a62f-b5bfcc8959cd', '4c766a13-9a28-4880-885b-5c1480d92db5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9feb2e8-470a-4533-9c9b-a0f41b0f41c4', 'bf9f644d-0b68-429d-8896-bcca69998358', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9feb2e8-470a-4533-9c9b-a0f41b0f41c4', '9537556f-6df9-4d7b-91f0-f8356ed7bfb8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9feb2e8-470a-4533-9c9b-a0f41b0f41c4', '9af221fb-b1ea-4dff-9219-8b42fb408029', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9feb2e8-470a-4533-9c9b-a0f41b0f41c4', 'cdb1a14b-16cc-4582-9ad1-a30f24ca3409', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9feb2e8-470a-4533-9c9b-a0f41b0f41c4', '0d126b7f-f3a2-461f-8740-2b988f965c94', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9537556f-6df9-4d7b-91f0-f8356ed7bfb8', 'f9feb2e8-470a-4533-9c9b-a0f41b0f41c4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9537556f-6df9-4d7b-91f0-f8356ed7bfb8', '9af221fb-b1ea-4dff-9219-8b42fb408029', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9537556f-6df9-4d7b-91f0-f8356ed7bfb8', 'cdb1a14b-16cc-4582-9ad1-a30f24ca3409', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9537556f-6df9-4d7b-91f0-f8356ed7bfb8', '0d126b7f-f3a2-461f-8740-2b988f965c94', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9537556f-6df9-4d7b-91f0-f8356ed7bfb8', '7e91716c-a01c-44f2-aa16-1ee98974568f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9af221fb-b1ea-4dff-9219-8b42fb408029', 'f9feb2e8-470a-4533-9c9b-a0f41b0f41c4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9af221fb-b1ea-4dff-9219-8b42fb408029', '9537556f-6df9-4d7b-91f0-f8356ed7bfb8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9af221fb-b1ea-4dff-9219-8b42fb408029', 'cdb1a14b-16cc-4582-9ad1-a30f24ca3409', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9af221fb-b1ea-4dff-9219-8b42fb408029', '0d126b7f-f3a2-461f-8740-2b988f965c94', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9af221fb-b1ea-4dff-9219-8b42fb408029', '7e91716c-a01c-44f2-aa16-1ee98974568f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cdb1a14b-16cc-4582-9ad1-a30f24ca3409', '0d126b7f-f3a2-461f-8740-2b988f965c94', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cdb1a14b-16cc-4582-9ad1-a30f24ca3409', '7e91716c-a01c-44f2-aa16-1ee98974568f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cdb1a14b-16cc-4582-9ad1-a30f24ca3409', '105846d2-b60e-4d28-a5d5-04b62fdf0c0f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cdb1a14b-16cc-4582-9ad1-a30f24ca3409', 'f9feb2e8-470a-4533-9c9b-a0f41b0f41c4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cdb1a14b-16cc-4582-9ad1-a30f24ca3409', '9537556f-6df9-4d7b-91f0-f8356ed7bfb8', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0d126b7f-f3a2-461f-8740-2b988f965c94', 'cdb1a14b-16cc-4582-9ad1-a30f24ca3409', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0d126b7f-f3a2-461f-8740-2b988f965c94', '7e91716c-a01c-44f2-aa16-1ee98974568f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0d126b7f-f3a2-461f-8740-2b988f965c94', '105846d2-b60e-4d28-a5d5-04b62fdf0c0f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0d126b7f-f3a2-461f-8740-2b988f965c94', 'f9feb2e8-470a-4533-9c9b-a0f41b0f41c4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0d126b7f-f3a2-461f-8740-2b988f965c94', '9537556f-6df9-4d7b-91f0-f8356ed7bfb8', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7e91716c-a01c-44f2-aa16-1ee98974568f', 'cdb1a14b-16cc-4582-9ad1-a30f24ca3409', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7e91716c-a01c-44f2-aa16-1ee98974568f', '0d126b7f-f3a2-461f-8740-2b988f965c94', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7e91716c-a01c-44f2-aa16-1ee98974568f', '105846d2-b60e-4d28-a5d5-04b62fdf0c0f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7e91716c-a01c-44f2-aa16-1ee98974568f', 'f9feb2e8-470a-4533-9c9b-a0f41b0f41c4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7e91716c-a01c-44f2-aa16-1ee98974568f', '9537556f-6df9-4d7b-91f0-f8356ed7bfb8', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('105846d2-b60e-4d28-a5d5-04b62fdf0c0f', 'cdb1a14b-16cc-4582-9ad1-a30f24ca3409', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('105846d2-b60e-4d28-a5d5-04b62fdf0c0f', '0d126b7f-f3a2-461f-8740-2b988f965c94', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('105846d2-b60e-4d28-a5d5-04b62fdf0c0f', '7e91716c-a01c-44f2-aa16-1ee98974568f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('105846d2-b60e-4d28-a5d5-04b62fdf0c0f', 'f9feb2e8-470a-4533-9c9b-a0f41b0f41c4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('105846d2-b60e-4d28-a5d5-04b62fdf0c0f', '9537556f-6df9-4d7b-91f0-f8356ed7bfb8', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bf9f644d-0b68-429d-8896-bcca69998358', 'f9feb2e8-470a-4533-9c9b-a0f41b0f41c4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bf9f644d-0b68-429d-8896-bcca69998358', '9537556f-6df9-4d7b-91f0-f8356ed7bfb8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bf9f644d-0b68-429d-8896-bcca69998358', '9af221fb-b1ea-4dff-9219-8b42fb408029', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bf9f644d-0b68-429d-8896-bcca69998358', 'cdb1a14b-16cc-4582-9ad1-a30f24ca3409', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bf9f644d-0b68-429d-8896-bcca69998358', '0d126b7f-f3a2-461f-8740-2b988f965c94', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('65f669cf-aba0-41d2-bec5-dcbd46259967', 'f9feb2e8-470a-4533-9c9b-a0f41b0f41c4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('65f669cf-aba0-41d2-bec5-dcbd46259967', '9537556f-6df9-4d7b-91f0-f8356ed7bfb8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('65f669cf-aba0-41d2-bec5-dcbd46259967', '9af221fb-b1ea-4dff-9219-8b42fb408029', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89ee12a3-31d3-4bfd-b96c-70a9610f75d9', 'f9feb2e8-470a-4533-9c9b-a0f41b0f41c4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89ee12a3-31d3-4bfd-b96c-70a9610f75d9', '9537556f-6df9-4d7b-91f0-f8356ed7bfb8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89ee12a3-31d3-4bfd-b96c-70a9610f75d9', '9af221fb-b1ea-4dff-9219-8b42fb408029', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89ee12a3-31d3-4bfd-b96c-70a9610f75d9', 'cdb1a14b-16cc-4582-9ad1-a30f24ca3409', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89ee12a3-31d3-4bfd-b96c-70a9610f75d9', '0d126b7f-f3a2-461f-8740-2b988f965c94', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dd82939d-776d-4664-b4bc-5d5e6f4fc8b7', '6217e97d-48f9-4415-b72a-ec41604caf3e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dd82939d-776d-4664-b4bc-5d5e6f4fc8b7', '89fefec5-521d-4a67-a890-8ae51c4ccfeb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dd82939d-776d-4664-b4bc-5d5e6f4fc8b7', 'cf616dfc-f074-483a-a1d3-2fbec8c24082', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dd82939d-776d-4664-b4bc-5d5e6f4fc8b7', '00d7acb2-44cc-4a70-acbf-d4c975fedb56', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dd82939d-776d-4664-b4bc-5d5e6f4fc8b7', 'b7906809-4a77-4cd4-8475-95dc9f36db52', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e47d9aa8-1ed3-4754-b6b7-8ddf8d90ca94', 'dd82939d-776d-4664-b4bc-5d5e6f4fc8b7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e47d9aa8-1ed3-4754-b6b7-8ddf8d90ca94', '6217e97d-48f9-4415-b72a-ec41604caf3e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e47d9aa8-1ed3-4754-b6b7-8ddf8d90ca94', '89fefec5-521d-4a67-a890-8ae51c4ccfeb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e47d9aa8-1ed3-4754-b6b7-8ddf8d90ca94', 'cf616dfc-f074-483a-a1d3-2fbec8c24082', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e47d9aa8-1ed3-4754-b6b7-8ddf8d90ca94', '00d7acb2-44cc-4a70-acbf-d4c975fedb56', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6217e97d-48f9-4415-b72a-ec41604caf3e', 'dd82939d-776d-4664-b4bc-5d5e6f4fc8b7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6217e97d-48f9-4415-b72a-ec41604caf3e', '89fefec5-521d-4a67-a890-8ae51c4ccfeb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6217e97d-48f9-4415-b72a-ec41604caf3e', 'cf616dfc-f074-483a-a1d3-2fbec8c24082', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6217e97d-48f9-4415-b72a-ec41604caf3e', '00d7acb2-44cc-4a70-acbf-d4c975fedb56', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6217e97d-48f9-4415-b72a-ec41604caf3e', 'b7906809-4a77-4cd4-8475-95dc9f36db52', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cf616dfc-f074-483a-a1d3-2fbec8c24082', 'dd82939d-776d-4664-b4bc-5d5e6f4fc8b7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cf616dfc-f074-483a-a1d3-2fbec8c24082', '6217e97d-48f9-4415-b72a-ec41604caf3e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cf616dfc-f074-483a-a1d3-2fbec8c24082', '00d7acb2-44cc-4a70-acbf-d4c975fedb56', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cf616dfc-f074-483a-a1d3-2fbec8c24082', '89fefec5-521d-4a67-a890-8ae51c4ccfeb', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cf616dfc-f074-483a-a1d3-2fbec8c24082', 'b7906809-4a77-4cd4-8475-95dc9f36db52', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('00d7acb2-44cc-4a70-acbf-d4c975fedb56', 'dd82939d-776d-4664-b4bc-5d5e6f4fc8b7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('00d7acb2-44cc-4a70-acbf-d4c975fedb56', '6217e97d-48f9-4415-b72a-ec41604caf3e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('00d7acb2-44cc-4a70-acbf-d4c975fedb56', 'cf616dfc-f074-483a-a1d3-2fbec8c24082', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('00d7acb2-44cc-4a70-acbf-d4c975fedb56', '89fefec5-521d-4a67-a890-8ae51c4ccfeb', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('00d7acb2-44cc-4a70-acbf-d4c975fedb56', 'b7906809-4a77-4cd4-8475-95dc9f36db52', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('af5c5e9a-e4fa-44cf-9e32-a904daf2aaa4', 'dd82939d-776d-4664-b4bc-5d5e6f4fc8b7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('af5c5e9a-e4fa-44cf-9e32-a904daf2aaa4', '6217e97d-48f9-4415-b72a-ec41604caf3e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('af5c5e9a-e4fa-44cf-9e32-a904daf2aaa4', 'cf616dfc-f074-483a-a1d3-2fbec8c24082', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5d0e09c1-8565-4df8-996e-5cfe6a79c5da', 'dd82939d-776d-4664-b4bc-5d5e6f4fc8b7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5d0e09c1-8565-4df8-996e-5cfe6a79c5da', '6217e97d-48f9-4415-b72a-ec41604caf3e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5d0e09c1-8565-4df8-996e-5cfe6a79c5da', 'cf616dfc-f074-483a-a1d3-2fbec8c24082', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('76e3a887-93ca-4d4b-a1c7-4b91109fb3dc', '13605bab-1be8-48b3-8b4b-dad2f51c350a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('76e3a887-93ca-4d4b-a1c7-4b91109fb3dc', '87e3c906-7e86-4203-aee4-992b7657b729', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('76e3a887-93ca-4d4b-a1c7-4b91109fb3dc', '6bab9884-cb6c-4136-9f10-3ff104da0ca8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('76e3a887-93ca-4d4b-a1c7-4b91109fb3dc', '1369fd19-d81f-4ee9-8431-22fb6f556799', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('76e3a887-93ca-4d4b-a1c7-4b91109fb3dc', '2939015a-ae2f-49ed-8c50-8dfa3d91fdbb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6bab9884-cb6c-4136-9f10-3ff104da0ca8', '2939015a-ae2f-49ed-8c50-8dfa3d91fdbb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6bab9884-cb6c-4136-9f10-3ff104da0ca8', '76e3a887-93ca-4d4b-a1c7-4b91109fb3dc', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6bab9884-cb6c-4136-9f10-3ff104da0ca8', '13605bab-1be8-48b3-8b4b-dad2f51c350a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6bab9884-cb6c-4136-9f10-3ff104da0ca8', '1369fd19-d81f-4ee9-8431-22fb6f556799', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6bab9884-cb6c-4136-9f10-3ff104da0ca8', '87e3c906-7e86-4203-aee4-992b7657b729', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('13605bab-1be8-48b3-8b4b-dad2f51c350a', '76e3a887-93ca-4d4b-a1c7-4b91109fb3dc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('13605bab-1be8-48b3-8b4b-dad2f51c350a', '87e3c906-7e86-4203-aee4-992b7657b729', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('13605bab-1be8-48b3-8b4b-dad2f51c350a', '6bab9884-cb6c-4136-9f10-3ff104da0ca8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('13605bab-1be8-48b3-8b4b-dad2f51c350a', '1369fd19-d81f-4ee9-8431-22fb6f556799', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('13605bab-1be8-48b3-8b4b-dad2f51c350a', '2939015a-ae2f-49ed-8c50-8dfa3d91fdbb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1369fd19-d81f-4ee9-8431-22fb6f556799', '76e3a887-93ca-4d4b-a1c7-4b91109fb3dc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1369fd19-d81f-4ee9-8431-22fb6f556799', '6bab9884-cb6c-4136-9f10-3ff104da0ca8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1369fd19-d81f-4ee9-8431-22fb6f556799', '13605bab-1be8-48b3-8b4b-dad2f51c350a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1369fd19-d81f-4ee9-8431-22fb6f556799', '2939015a-ae2f-49ed-8c50-8dfa3d91fdbb', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1369fd19-d81f-4ee9-8431-22fb6f556799', '87e3c906-7e86-4203-aee4-992b7657b729', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2939015a-ae2f-49ed-8c50-8dfa3d91fdbb', '6bab9884-cb6c-4136-9f10-3ff104da0ca8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2939015a-ae2f-49ed-8c50-8dfa3d91fdbb', '76e3a887-93ca-4d4b-a1c7-4b91109fb3dc', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2939015a-ae2f-49ed-8c50-8dfa3d91fdbb', '13605bab-1be8-48b3-8b4b-dad2f51c350a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2939015a-ae2f-49ed-8c50-8dfa3d91fdbb', '1369fd19-d81f-4ee9-8431-22fb6f556799', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2939015a-ae2f-49ed-8c50-8dfa3d91fdbb', '87e3c906-7e86-4203-aee4-992b7657b729', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('867313af-3ac1-4878-9eac-d232c0dfae18', 'cda01428-418a-432d-9322-6d7b9f298890', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('867313af-3ac1-4878-9eac-d232c0dfae18', 'dd82939d-776d-4664-b4bc-5d5e6f4fc8b7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('867313af-3ac1-4878-9eac-d232c0dfae18', '6217e97d-48f9-4415-b72a-ec41604caf3e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89fefec5-521d-4a67-a890-8ae51c4ccfeb', 'dd82939d-776d-4664-b4bc-5d5e6f4fc8b7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89fefec5-521d-4a67-a890-8ae51c4ccfeb', '6217e97d-48f9-4415-b72a-ec41604caf3e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89fefec5-521d-4a67-a890-8ae51c4ccfeb', 'cf616dfc-f074-483a-a1d3-2fbec8c24082', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89fefec5-521d-4a67-a890-8ae51c4ccfeb', '00d7acb2-44cc-4a70-acbf-d4c975fedb56', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89fefec5-521d-4a67-a890-8ae51c4ccfeb', 'b7906809-4a77-4cd4-8475-95dc9f36db52', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ef926b97-9599-4c86-a074-5fd6c0a948e0', 'dd82939d-776d-4664-b4bc-5d5e6f4fc8b7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ef926b97-9599-4c86-a074-5fd6c0a948e0', '6217e97d-48f9-4415-b72a-ec41604caf3e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ef926b97-9599-4c86-a074-5fd6c0a948e0', 'cf616dfc-f074-483a-a1d3-2fbec8c24082', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7906809-4a77-4cd4-8475-95dc9f36db52', 'dd82939d-776d-4664-b4bc-5d5e6f4fc8b7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7906809-4a77-4cd4-8475-95dc9f36db52', '6217e97d-48f9-4415-b72a-ec41604caf3e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7906809-4a77-4cd4-8475-95dc9f36db52', 'cf616dfc-f074-483a-a1d3-2fbec8c24082', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7906809-4a77-4cd4-8475-95dc9f36db52', '00d7acb2-44cc-4a70-acbf-d4c975fedb56', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7906809-4a77-4cd4-8475-95dc9f36db52', '89fefec5-521d-4a67-a890-8ae51c4ccfeb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cda01428-418a-432d-9322-6d7b9f298890', '867313af-3ac1-4878-9eac-d232c0dfae18', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cda01428-418a-432d-9322-6d7b9f298890', 'dd82939d-776d-4664-b4bc-5d5e6f4fc8b7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cda01428-418a-432d-9322-6d7b9f298890', '6217e97d-48f9-4415-b72a-ec41604caf3e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('87e3c906-7e86-4203-aee4-992b7657b729', '76e3a887-93ca-4d4b-a1c7-4b91109fb3dc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('87e3c906-7e86-4203-aee4-992b7657b729', '13605bab-1be8-48b3-8b4b-dad2f51c350a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('87e3c906-7e86-4203-aee4-992b7657b729', '6bab9884-cb6c-4136-9f10-3ff104da0ca8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('87e3c906-7e86-4203-aee4-992b7657b729', '1369fd19-d81f-4ee9-8431-22fb6f556799', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('87e3c906-7e86-4203-aee4-992b7657b729', '2939015a-ae2f-49ed-8c50-8dfa3d91fdbb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b3ab74a9-5e38-471b-9174-3073180c0d05', 'f56e7574-e375-4d59-bd68-7e283056414d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b3ab74a9-5e38-471b-9174-3073180c0d05', 'f69f9a37-df16-4c58-a940-e49f5c23faa8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b3ab74a9-5e38-471b-9174-3073180c0d05', 'dd82939d-776d-4664-b4bc-5d5e6f4fc8b7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f56e7574-e375-4d59-bd68-7e283056414d', 'b3ab74a9-5e38-471b-9174-3073180c0d05', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f56e7574-e375-4d59-bd68-7e283056414d', 'f69f9a37-df16-4c58-a940-e49f5c23faa8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f56e7574-e375-4d59-bd68-7e283056414d', 'dd82939d-776d-4664-b4bc-5d5e6f4fc8b7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f69f9a37-df16-4c58-a940-e49f5c23faa8', 'b3ab74a9-5e38-471b-9174-3073180c0d05', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f69f9a37-df16-4c58-a940-e49f5c23faa8', 'f56e7574-e375-4d59-bd68-7e283056414d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f69f9a37-df16-4c58-a940-e49f5c23faa8', 'dd82939d-776d-4664-b4bc-5d5e6f4fc8b7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6e9d52fc-1a3b-4926-80b4-0d4dbb136827', 'ce62b747-0cfa-4b13-ba80-9f5e5884ce46', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6e9d52fc-1a3b-4926-80b4-0d4dbb136827', '81d40672-a784-4d6f-a34f-dbd6fcdf033a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6e9d52fc-1a3b-4926-80b4-0d4dbb136827', 'c85c7af6-2f9a-4828-b356-909aba5fb817', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6e9d52fc-1a3b-4926-80b4-0d4dbb136827', '4a60afa5-c856-4cad-92b8-7d389fe26a6a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce62b747-0cfa-4b13-ba80-9f5e5884ce46', '6e9d52fc-1a3b-4926-80b4-0d4dbb136827', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce62b747-0cfa-4b13-ba80-9f5e5884ce46', '81d40672-a784-4d6f-a34f-dbd6fcdf033a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce62b747-0cfa-4b13-ba80-9f5e5884ce46', 'c85c7af6-2f9a-4828-b356-909aba5fb817', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce62b747-0cfa-4b13-ba80-9f5e5884ce46', '4a60afa5-c856-4cad-92b8-7d389fe26a6a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('81d40672-a784-4d6f-a34f-dbd6fcdf033a', '6e9d52fc-1a3b-4926-80b4-0d4dbb136827', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('81d40672-a784-4d6f-a34f-dbd6fcdf033a', 'ce62b747-0cfa-4b13-ba80-9f5e5884ce46', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('81d40672-a784-4d6f-a34f-dbd6fcdf033a', 'c85c7af6-2f9a-4828-b356-909aba5fb817', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('81d40672-a784-4d6f-a34f-dbd6fcdf033a', '4a60afa5-c856-4cad-92b8-7d389fe26a6a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c85c7af6-2f9a-4828-b356-909aba5fb817', '6e9d52fc-1a3b-4926-80b4-0d4dbb136827', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c85c7af6-2f9a-4828-b356-909aba5fb817', 'ce62b747-0cfa-4b13-ba80-9f5e5884ce46', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c85c7af6-2f9a-4828-b356-909aba5fb817', '81d40672-a784-4d6f-a34f-dbd6fcdf033a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c85c7af6-2f9a-4828-b356-909aba5fb817', '4a60afa5-c856-4cad-92b8-7d389fe26a6a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a60afa5-c856-4cad-92b8-7d389fe26a6a', '6e9d52fc-1a3b-4926-80b4-0d4dbb136827', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a60afa5-c856-4cad-92b8-7d389fe26a6a', 'ce62b747-0cfa-4b13-ba80-9f5e5884ce46', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a60afa5-c856-4cad-92b8-7d389fe26a6a', '81d40672-a784-4d6f-a34f-dbd6fcdf033a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a60afa5-c856-4cad-92b8-7d389fe26a6a', 'c85c7af6-2f9a-4828-b356-909aba5fb817', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('343067eb-1337-455f-ac60-1efe33043900', 'd8bed89f-913f-41ba-951b-b63d39502870', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('343067eb-1337-455f-ac60-1efe33043900', '6a029fde-c862-48a5-80c3-76ff6d7b3fcb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d8bed89f-913f-41ba-951b-b63d39502870', '343067eb-1337-455f-ac60-1efe33043900', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d8bed89f-913f-41ba-951b-b63d39502870', '6a029fde-c862-48a5-80c3-76ff6d7b3fcb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6a029fde-c862-48a5-80c3-76ff6d7b3fcb', '343067eb-1337-455f-ac60-1efe33043900', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6a029fde-c862-48a5-80c3-76ff6d7b3fcb', 'd8bed89f-913f-41ba-951b-b63d39502870', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('067368d3-5de2-47bf-92cb-1e09decc5565', '84b0059f-2697-4bc1-b2e9-5ea444a6500a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('067368d3-5de2-47bf-92cb-1e09decc5565', '3d339586-f201-47c7-ba32-fe9056b006d9', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('067368d3-5de2-47bf-92cb-1e09decc5565', '1d8b121d-2eeb-4283-9def-a19f08215e7f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('067368d3-5de2-47bf-92cb-1e09decc5565', 'd2e5bf68-021b-4550-a171-33d9bd98d35d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('067368d3-5de2-47bf-92cb-1e09decc5565', '3c36eee9-f7dc-4722-a0ce-27d94c55b380', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d339586-f201-47c7-ba32-fe9056b006d9', '84b0059f-2697-4bc1-b2e9-5ea444a6500a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d339586-f201-47c7-ba32-fe9056b006d9', '067368d3-5de2-47bf-92cb-1e09decc5565', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d339586-f201-47c7-ba32-fe9056b006d9', '1d8b121d-2eeb-4283-9def-a19f08215e7f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d339586-f201-47c7-ba32-fe9056b006d9', 'd2e5bf68-021b-4550-a171-33d9bd98d35d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d339586-f201-47c7-ba32-fe9056b006d9', '3c36eee9-f7dc-4722-a0ce-27d94c55b380', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1d8b121d-2eeb-4283-9def-a19f08215e7f', '84b0059f-2697-4bc1-b2e9-5ea444a6500a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1d8b121d-2eeb-4283-9def-a19f08215e7f', '067368d3-5de2-47bf-92cb-1e09decc5565', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1d8b121d-2eeb-4283-9def-a19f08215e7f', '3d339586-f201-47c7-ba32-fe9056b006d9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1d8b121d-2eeb-4283-9def-a19f08215e7f', 'd2e5bf68-021b-4550-a171-33d9bd98d35d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1d8b121d-2eeb-4283-9def-a19f08215e7f', '3c36eee9-f7dc-4722-a0ce-27d94c55b380', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3c36eee9-f7dc-4722-a0ce-27d94c55b380', '84b0059f-2697-4bc1-b2e9-5ea444a6500a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3c36eee9-f7dc-4722-a0ce-27d94c55b380', 'd2e5bf68-021b-4550-a171-33d9bd98d35d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3c36eee9-f7dc-4722-a0ce-27d94c55b380', '067368d3-5de2-47bf-92cb-1e09decc5565', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3c36eee9-f7dc-4722-a0ce-27d94c55b380', '3d339586-f201-47c7-ba32-fe9056b006d9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3c36eee9-f7dc-4722-a0ce-27d94c55b380', '1d8b121d-2eeb-4283-9def-a19f08215e7f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('054b1c19-697f-465d-b59f-939c25abb368', '46782ed4-9dcd-409c-bc44-233b93c9045e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('054b1c19-697f-465d-b59f-939c25abb368', '033842a8-4069-494c-b5ad-77d5fc4374cc', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('46782ed4-9dcd-409c-bc44-233b93c9045e', '054b1c19-697f-465d-b59f-939c25abb368', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('46782ed4-9dcd-409c-bc44-233b93c9045e', '033842a8-4069-494c-b5ad-77d5fc4374cc', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('033842a8-4069-494c-b5ad-77d5fc4374cc', '054b1c19-697f-465d-b59f-939c25abb368', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('033842a8-4069-494c-b5ad-77d5fc4374cc', '46782ed4-9dcd-409c-bc44-233b93c9045e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f84689be-4569-46c8-867d-3efa970b3445', '733ee975-e778-459c-a816-6c05d94483db', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f84689be-4569-46c8-867d-3efa970b3445', 'f3a82e6c-8bb0-43ba-95e3-986d3d7723d5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f84689be-4569-46c8-867d-3efa970b3445', 'ce366b22-15f8-4390-a1be-b3ec32a14419', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('733ee975-e778-459c-a816-6c05d94483db', 'ce366b22-15f8-4390-a1be-b3ec32a14419', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('733ee975-e778-459c-a816-6c05d94483db', 'f84689be-4569-46c8-867d-3efa970b3445', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('733ee975-e778-459c-a816-6c05d94483db', 'f3a82e6c-8bb0-43ba-95e3-986d3d7723d5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f3a82e6c-8bb0-43ba-95e3-986d3d7723d5', 'f84689be-4569-46c8-867d-3efa970b3445', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f3a82e6c-8bb0-43ba-95e3-986d3d7723d5', '733ee975-e778-459c-a816-6c05d94483db', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f3a82e6c-8bb0-43ba-95e3-986d3d7723d5', 'ce366b22-15f8-4390-a1be-b3ec32a14419', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce366b22-15f8-4390-a1be-b3ec32a14419', '733ee975-e778-459c-a816-6c05d94483db', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce366b22-15f8-4390-a1be-b3ec32a14419', 'f84689be-4569-46c8-867d-3efa970b3445', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce366b22-15f8-4390-a1be-b3ec32a14419', 'f3a82e6c-8bb0-43ba-95e3-986d3d7723d5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1bbab166-9bbc-45aa-8c77-bfb53cb5690f', 'fc359414-dfe8-4380-8e82-437f5eb7de94', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1bbab166-9bbc-45aa-8c77-bfb53cb5690f', '98ee9741-55ac-4ca6-bd0f-f999e181a2a8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1bbab166-9bbc-45aa-8c77-bfb53cb5690f', '7878cb97-a45a-4b2b-bf3b-6ac96344fcee', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1bbab166-9bbc-45aa-8c77-bfb53cb5690f', 'f5e5ce91-4989-4dda-ac76-8effe198e24a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1bbab166-9bbc-45aa-8c77-bfb53cb5690f', '2533b591-e1f6-40d6-8e78-0ab8811aa26a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc359414-dfe8-4380-8e82-437f5eb7de94', '1bbab166-9bbc-45aa-8c77-bfb53cb5690f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc359414-dfe8-4380-8e82-437f5eb7de94', '98ee9741-55ac-4ca6-bd0f-f999e181a2a8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc359414-dfe8-4380-8e82-437f5eb7de94', '7878cb97-a45a-4b2b-bf3b-6ac96344fcee', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc359414-dfe8-4380-8e82-437f5eb7de94', 'f5e5ce91-4989-4dda-ac76-8effe198e24a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc359414-dfe8-4380-8e82-437f5eb7de94', '2533b591-e1f6-40d6-8e78-0ab8811aa26a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('98ee9741-55ac-4ca6-bd0f-f999e181a2a8', '222017dd-ac27-4db5-9a77-a090edc8004b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('98ee9741-55ac-4ca6-bd0f-f999e181a2a8', '1bbab166-9bbc-45aa-8c77-bfb53cb5690f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('98ee9741-55ac-4ca6-bd0f-f999e181a2a8', 'fc359414-dfe8-4380-8e82-437f5eb7de94', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('98ee9741-55ac-4ca6-bd0f-f999e181a2a8', '7878cb97-a45a-4b2b-bf3b-6ac96344fcee', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('98ee9741-55ac-4ca6-bd0f-f999e181a2a8', 'f5e5ce91-4989-4dda-ac76-8effe198e24a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7878cb97-a45a-4b2b-bf3b-6ac96344fcee', '1bbab166-9bbc-45aa-8c77-bfb53cb5690f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7878cb97-a45a-4b2b-bf3b-6ac96344fcee', 'fc359414-dfe8-4380-8e82-437f5eb7de94', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7878cb97-a45a-4b2b-bf3b-6ac96344fcee', '98ee9741-55ac-4ca6-bd0f-f999e181a2a8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7878cb97-a45a-4b2b-bf3b-6ac96344fcee', 'f5e5ce91-4989-4dda-ac76-8effe198e24a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7878cb97-a45a-4b2b-bf3b-6ac96344fcee', '2533b591-e1f6-40d6-8e78-0ab8811aa26a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f5e5ce91-4989-4dda-ac76-8effe198e24a', '1bbab166-9bbc-45aa-8c77-bfb53cb5690f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f5e5ce91-4989-4dda-ac76-8effe198e24a', 'fc359414-dfe8-4380-8e82-437f5eb7de94', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f5e5ce91-4989-4dda-ac76-8effe198e24a', '98ee9741-55ac-4ca6-bd0f-f999e181a2a8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f5e5ce91-4989-4dda-ac76-8effe198e24a', '7878cb97-a45a-4b2b-bf3b-6ac96344fcee', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f5e5ce91-4989-4dda-ac76-8effe198e24a', '2533b591-e1f6-40d6-8e78-0ab8811aa26a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2533b591-e1f6-40d6-8e78-0ab8811aa26a', '1bbab166-9bbc-45aa-8c77-bfb53cb5690f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2533b591-e1f6-40d6-8e78-0ab8811aa26a', 'fc359414-dfe8-4380-8e82-437f5eb7de94', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2533b591-e1f6-40d6-8e78-0ab8811aa26a', '98ee9741-55ac-4ca6-bd0f-f999e181a2a8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2533b591-e1f6-40d6-8e78-0ab8811aa26a', '7878cb97-a45a-4b2b-bf3b-6ac96344fcee', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2533b591-e1f6-40d6-8e78-0ab8811aa26a', 'f5e5ce91-4989-4dda-ac76-8effe198e24a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6d1834f5-0861-42d1-913d-9af2ed5387cf', '1bbab166-9bbc-45aa-8c77-bfb53cb5690f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6d1834f5-0861-42d1-913d-9af2ed5387cf', 'fc359414-dfe8-4380-8e82-437f5eb7de94', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6d1834f5-0861-42d1-913d-9af2ed5387cf', '98ee9741-55ac-4ca6-bd0f-f999e181a2a8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6d1834f5-0861-42d1-913d-9af2ed5387cf', '7878cb97-a45a-4b2b-bf3b-6ac96344fcee', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6d1834f5-0861-42d1-913d-9af2ed5387cf', 'f5e5ce91-4989-4dda-ac76-8effe198e24a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('222017dd-ac27-4db5-9a77-a090edc8004b', '98ee9741-55ac-4ca6-bd0f-f999e181a2a8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('222017dd-ac27-4db5-9a77-a090edc8004b', '1bbab166-9bbc-45aa-8c77-bfb53cb5690f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('222017dd-ac27-4db5-9a77-a090edc8004b', 'fc359414-dfe8-4380-8e82-437f5eb7de94', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('222017dd-ac27-4db5-9a77-a090edc8004b', '7878cb97-a45a-4b2b-bf3b-6ac96344fcee', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('222017dd-ac27-4db5-9a77-a090edc8004b', 'f5e5ce91-4989-4dda-ac76-8effe198e24a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1eb1afac-47d7-40ef-a18f-201b3ab554de', '1bbab166-9bbc-45aa-8c77-bfb53cb5690f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1eb1afac-47d7-40ef-a18f-201b3ab554de', 'fc359414-dfe8-4380-8e82-437f5eb7de94', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1eb1afac-47d7-40ef-a18f-201b3ab554de', '98ee9741-55ac-4ca6-bd0f-f999e181a2a8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1eb1afac-47d7-40ef-a18f-201b3ab554de', '7878cb97-a45a-4b2b-bf3b-6ac96344fcee', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1eb1afac-47d7-40ef-a18f-201b3ab554de', 'f5e5ce91-4989-4dda-ac76-8effe198e24a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5bfff03a-e6a3-4168-ad3d-b2f7528e430f', 'a1b50169-99da-4f2b-bce7-b2c04038cf2f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('247fc586-d5f5-4d2e-916b-45007c61932d', 'a1b50169-99da-4f2b-bce7-b2c04038cf2f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2f85e376-068b-4635-8105-344291077bc4', 'a1b50169-99da-4f2b-bce7-b2c04038cf2f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45c1277a-800d-49b8-84cc-a4aa65c069b9', 'a1b50169-99da-4f2b-bce7-b2c04038cf2f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('961f729f-a93c-4504-b5f3-c63f9e9a813e', 'a1b50169-99da-4f2b-bce7-b2c04038cf2f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ea316212-90e8-490b-911d-ca326ce6f538', 'a1b50169-99da-4f2b-bce7-b2c04038cf2f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f5332e09-9824-4e60-939e-f9b1d86cf0d0', 'b6672065-25cc-49c9-9faf-3510532590fe', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f5332e09-9824-4e60-939e-f9b1d86cf0d0', '555f6a86-44e6-47cc-a851-b75d22fea2f7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f5332e09-9824-4e60-939e-f9b1d86cf0d0', '97fd9f3e-dd96-49ee-a0b6-21cdf5d12d63', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b6672065-25cc-49c9-9faf-3510532590fe', 'f5332e09-9824-4e60-939e-f9b1d86cf0d0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b6672065-25cc-49c9-9faf-3510532590fe', '555f6a86-44e6-47cc-a851-b75d22fea2f7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b6672065-25cc-49c9-9faf-3510532590fe', '97fd9f3e-dd96-49ee-a0b6-21cdf5d12d63', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('555f6a86-44e6-47cc-a851-b75d22fea2f7', '97fd9f3e-dd96-49ee-a0b6-21cdf5d12d63', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('555f6a86-44e6-47cc-a851-b75d22fea2f7', 'f5332e09-9824-4e60-939e-f9b1d86cf0d0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('555f6a86-44e6-47cc-a851-b75d22fea2f7', 'b6672065-25cc-49c9-9faf-3510532590fe', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('97fd9f3e-dd96-49ee-a0b6-21cdf5d12d63', '555f6a86-44e6-47cc-a851-b75d22fea2f7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('97fd9f3e-dd96-49ee-a0b6-21cdf5d12d63', 'f5332e09-9824-4e60-939e-f9b1d86cf0d0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('97fd9f3e-dd96-49ee-a0b6-21cdf5d12d63', 'b6672065-25cc-49c9-9faf-3510532590fe', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7cdcb816-e88f-4f4e-b39d-bafa190d5e29', '6d87b190-1310-40a9-87f1-cf28fd2af510', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7cdcb816-e88f-4f4e-b39d-bafa190d5e29', 'd6ac8267-6393-46d6-8c4e-58277cc11869', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('83b5c0cb-ecfb-412a-b29d-ede3252526ab', '7cdcb816-e88f-4f4e-b39d-bafa190d5e29', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('83b5c0cb-ecfb-412a-b29d-ede3252526ab', '6d87b190-1310-40a9-87f1-cf28fd2af510', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('83b5c0cb-ecfb-412a-b29d-ede3252526ab', 'd6ac8267-6393-46d6-8c4e-58277cc11869', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9b621145-9c46-4d72-8e31-a7f33d9d1802', '7cdcb816-e88f-4f4e-b39d-bafa190d5e29', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9b621145-9c46-4d72-8e31-a7f33d9d1802', '6d87b190-1310-40a9-87f1-cf28fd2af510', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9b621145-9c46-4d72-8e31-a7f33d9d1802', 'd6ac8267-6393-46d6-8c4e-58277cc11869', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6d87b190-1310-40a9-87f1-cf28fd2af510', '7cdcb816-e88f-4f4e-b39d-bafa190d5e29', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6d87b190-1310-40a9-87f1-cf28fd2af510', 'd6ac8267-6393-46d6-8c4e-58277cc11869', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('184f9bad-5127-4cda-9240-dfefe30a6190', '7cdcb816-e88f-4f4e-b39d-bafa190d5e29', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('184f9bad-5127-4cda-9240-dfefe30a6190', '6d87b190-1310-40a9-87f1-cf28fd2af510', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('184f9bad-5127-4cda-9240-dfefe30a6190', 'd6ac8267-6393-46d6-8c4e-58277cc11869', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0884e985-e078-495f-9c90-d4729d9e6a84', '7cdcb816-e88f-4f4e-b39d-bafa190d5e29', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0884e985-e078-495f-9c90-d4729d9e6a84', '6d87b190-1310-40a9-87f1-cf28fd2af510', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0884e985-e078-495f-9c90-d4729d9e6a84', 'd6ac8267-6393-46d6-8c4e-58277cc11869', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d6ac8267-6393-46d6-8c4e-58277cc11869', '7cdcb816-e88f-4f4e-b39d-bafa190d5e29', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d6ac8267-6393-46d6-8c4e-58277cc11869', '6d87b190-1310-40a9-87f1-cf28fd2af510', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7d798023-9d6e-4eb8-b41e-3bc04fcd2545', '7cdcb816-e88f-4f4e-b39d-bafa190d5e29', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7d798023-9d6e-4eb8-b41e-3bc04fcd2545', '6d87b190-1310-40a9-87f1-cf28fd2af510', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7d798023-9d6e-4eb8-b41e-3bc04fcd2545', 'd6ac8267-6393-46d6-8c4e-58277cc11869', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('91dbd7e3-bd50-4e6a-8c71-d042eef818b3', '7cdcb816-e88f-4f4e-b39d-bafa190d5e29', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('91dbd7e3-bd50-4e6a-8c71-d042eef818b3', '6d87b190-1310-40a9-87f1-cf28fd2af510', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('91dbd7e3-bd50-4e6a-8c71-d042eef818b3', 'd6ac8267-6393-46d6-8c4e-58277cc11869', 2) ON CONFLICT DO NOTHING;



INSERT INTO public.faqs VALUES ('ddf8c84c-5176-462e-9013-4ae249a6a1d0', 'متى يوصلني الرد بعد الاشتراك؟', 'خلال 48 ساعة عمل. أيام العمل من الأحد إلى الخميس، من 12 الظهر حتى 9 مساءً، والتواصل على واتساب.', 0, true, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('15a90bc1-a0a4-4331-9a30-3db230620457', 'كيف تتم المتابعة؟', 'ترسل مراجعتك الأسبوعية في يوم المراجعة، وأرد عليك بتعديلات مسجلة (فيديو أو صوت). في الباقة الأساسية المتابعة كل أسبوعين. التواصل اليومي على واتساب مع رد خلال 48 ساعة.', 1, true, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('43754303-9cb0-4510-af04-45e718cfc80e', 'أنا مبتدئ تماماً، هل يناسبني؟', 'نعم. البرنامج يُبنى على مستواك الحالي، والتمارين مشروحة، وتقدر ترسل مقاطع أدائك لتصحيح التكنيك.', 2, true, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('8f0bac24-db50-42a7-b99c-b7f4f3516d4f', 'أتمرن في البيت، ماذا أحتاج من أدوات؟', 'تحدد في النموذج الأدوات المتوفرة عندك (دمبلز، حبال مقاومة، بار…) ويُبنى جدولك عليها.', 3, true, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('854cd1f0-d58a-458c-9c3a-c533ce8ff68b', 'كيف أدفع؟', 'بتحويل بنكي بعد تعبئة الاستبيان. أول ما ترسل الاستبيان يظهر لك رقم طلبك والمبلغ وبيانات الحساب. حوّل المبلغ وارفع صورة الإيصال من صفحة طلبك، ويتأكد اشتراكك بعد التحقق من وصول المبلغ.', 4, true, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('cf93a4d0-828f-436f-935e-d5d71b13fd6a', 'ما شروط ضمان استرجاع المبلغ؟', 'في اشتراكات 3 أشهر لباقات المتابعة (المكثفة، المتقدمة، الأساسية): إذا لم يتحسن أي مؤشر من مؤشرات تقدمك بعد 12 أسبوعاً، يرجع لك المبلغ كاملاً.
مؤشرات التقدم (بحسب هدفك): متوسط الوزن الأسبوعي، أو محيط الخصر، أو القوة في التمارين الأساسية (الوزن أو التكرارات).
شروط الضمان:
- إرسال المراجعة الأسبوعية كل أسبوع.
- أخذ القياسات بانتظام.
- تصوير التمارين وإرسالها.
- الالتزام بجدول التغذية المخصص (في الباقات التي تشمل تغذية).
يُطلب الاسترجاع عبر واتساب خلال 14 يوماً من نهاية الأشهر الثلاثة.', 5, true, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('5bbdf459-6a6a-441f-a404-8b9d16df07b5', 'هل الجداول لي بعد انتهاء الاشتراك؟', 'نعم، جميع الجداول لك مدى الحياة وتقدر تعدّل عليها.', 6, true, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('48fd7a4e-3630-4e98-93f8-c3be3f0d0c4e', 'ما هو التجديد المجاني؟', 'مكافأة للملتزمين: إذا كان اشتراكك 3 أشهر تحصل على 3 أشهر إضافية مجاناً، فيصير المجموع 6 أشهر بسعر 3.
الشروط:
- نسبة التزام 90% فأكثر: المراجعات الأسبوعية المرسلة والتمارين المسجلة.
- تقدم واضح في مؤشرات التقدم نفسها المذكورة في الضمان.
- للمتدربين الرجال: إرسال صور التطور (قبل وبعد) للمدربة للتوثيق، مع تغطية الوجه والسرة.
نشر الصور في السوشل ميديا اختياري بالكامل حسب موافقتك، ولا يؤثر على استحقاقك للتجديد.', 7, true, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('60b7fbc5-036b-486e-b8fc-7db846b53594', 'من يطّلع على بياناتي؟', 'المدربة فقط، وتُستخدم لتصميم برنامجك ومتابعتك. لا تُنشر نتيجتك أو صورتك إلا بموافقتك الصريحة في النموذج.', 8, true, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;



INSERT INTO public.foods VALUES ('a232f05e-946a-48aa-8b55-8fb4e51a1189', 'رز أبيض مطبوخ', 'Rice, white, long-grain, regular, enriched, cooked', 'حبوب ونشويات', 130.0, 2.7, 28.2, 0.3, 150.0, 'كوب إلا ربع', 'usda', '168878', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('c5bd8f91-4e5e-4ea5-a163-770690035243', 'رز بني مطبوخ', 'Rice, brown, long-grain, cooked (Includes foods for USDA''s Food Distribution Program)', 'حبوب ونشويات', 123.0, 2.7, 25.6, 1.0, 150.0, NULL, 'usda', '169704', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('11679951-9e71-4001-acc2-0ba677851615', 'رز أبيض (غير مطبوخ)', 'Rice, white, long-grain, regular, raw, enriched', 'حبوب ونشويات', 365.0, 7.1, 80.0, 0.7, 75.0, NULL, 'usda', '168877', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('91181b36-44ee-40aa-9e48-da0c8a77dcff', 'مكرونة مطبوخة', 'Pasta, cooked, enriched, without added salt', 'حبوب ونشويات', 158.0, 5.8, 30.9, 0.9, 140.0, 'كوب', 'usda', '169737', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3a285639-8c9b-4a44-ae90-d28e8f999c02', 'مكرونة (غير مطبوخة)', 'Pasta, dry, enriched', 'حبوب ونشويات', 371.0, 13.0, 74.7, 1.5, 75.0, NULL, 'usda', '169736', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a09474ed-8cda-4add-9570-303ba1895d55', 'شوفان', 'Cereals, oats, regular and quick, not fortified, dry', 'حبوب ونشويات', 379.0, 13.2, 67.7, 6.5, 40.0, 'نص كوب', 'usda', '173904', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('edc6485e-fcd3-410e-8d2a-5daaac09733a', 'خبز أبيض (توست)', 'Bread, white, commercially prepared (includes soft bread crumbs)', 'خبز', 266.0, 8.9, 49.4, 3.3, 28.0, 'شريحة', 'usda', '174924', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('fd1940c4-5834-4e02-9edc-500ca18978c0', 'خبز بر (توست أسمر)', 'Bread, whole-wheat, commercially prepared', 'خبز', 252.0, 12.5, 42.7, 3.5, 32.0, 'شريحة', 'usda', '172688', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('be0cd646-c753-4177-b150-99d74ab89243', 'خبز عربي أبيض', 'Bread, pita, white, enriched', 'خبز', 275.0, 9.1, 55.7, 1.2, 60.0, 'رغيف صغير', 'usda', '174915', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('7ae0491e-d31e-49f2-b733-823b70774fc2', 'خبز عربي بر', 'Bread, pita, whole-wheat', 'خبز', 262.0, 9.8, 55.9, 1.7, 64.0, 'رغيف صغير', 'usda', '174916', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('9b35cbdc-7153-4bc8-b275-651007608fe5', 'تورتيلا قمح', 'Tortillas, ready-to-bake or -fry, flour, refrigerated', 'خبز', 306.0, 8.2, 49.4, 8.0, 45.0, 'حبة', 'usda', '175037', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d428aa23-7d96-491a-ac1a-57a55ae541b7', 'بطاطس مسلوقة', 'Potatoes, boiled, cooked without skin, flesh, without salt', 'حبوب ونشويات', 86.0, 1.7, 20.0, 0.1, 150.0, 'حبة وسط', 'usda', '170440', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('10f71676-ac18-4b6a-9b5d-8a716019ed7e', 'بطاطا حلوة مشوية', 'Sweet potato, cooked, baked in skin, flesh, without salt', 'حبوب ونشويات', 90.0, 2.0, 20.7, 0.2, 150.0, 'حبة وسط', 'usda', '168483', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f223212b-d6fd-4927-9684-196fd24b431e', 'برغل مطبوخ', 'Bulgur, cooked', 'حبوب ونشويات', 83.0, 3.1, 18.6, 0.2, 150.0, NULL, 'usda', '170287', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('dc5532a7-9953-47f2-8230-dc56fde8d012', 'كينوا مطبوخة', 'Quinoa, cooked', 'حبوب ونشويات', 120.0, 4.4, 21.3, 1.9, 150.0, NULL, 'usda', '168917', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('95884c26-678e-45b6-ab12-8bbc3e74ae66', 'كورن فليكس', 'Cereals ready-to-eat, RALSTON Corn Flakes', 'حبوب ونشويات', 384.0, 5.9, 88.0, 0.9, 30.0, NULL, 'usda', '174648', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('59d129fd-9684-48f2-a859-5c7ed25fd200', 'صدر دجاج مشوي', 'Chicken, broilers or fryers, breast, meat only, cooked, roasted', 'لحوم ودواجن', 165.0, 31.0, 0.0, 3.6, 100.0, NULL, 'usda', '171477', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('236f9189-8d54-45ca-9868-90dfaa0ca88b', 'صدر دجاج نيء', 'Chicken, broiler or fryers, breast, skinless, boneless, meat only, raw', 'لحوم ودواجن', 120.0, 22.5, 0.0, 2.6, 150.0, NULL, 'usda', '171077', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('aff03aa3-5ed6-41b5-afe6-415dcc15da7b', 'فخذ دجاج مشوي (بدون جلد)', 'Chicken, broilers or fryers, thigh, meat only, cooked, roasted', 'لحوم ودواجن', 179.0, 24.8, 0.0, 8.2, 100.0, NULL, 'usda', '172388', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('750219ab-c736-4ba5-ba1d-d32b539b43d6', 'لحم بقري مفروم 90% مطبوخ', 'Beef, ground, 90% lean meat / 10% fat, patty, cooked, broiled', 'لحوم ودواجن', 217.0, 26.1, 0.0, 11.8, 100.0, NULL, 'usda', '174031', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('aaee7544-0069-48e5-937b-5f9b02965985', 'لحم بقري مفروم 80% مطبوخ', 'Beef, ground, 80% lean meat / 20% fat, patty, cooked, broiled', 'لحوم ودواجن', 270.0, 25.8, 0.0, 17.8, 100.0, NULL, 'usda', '171797', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('9633fd25-d425-440a-b419-15e1bd62ac6c', 'لحم غنم مطبوخ', 'Lamb, composite of trimmed retail cuts, separable lean only, trimmed to 1/4" fat, choice, cooked', 'لحوم ودواجن', 206.0, 28.2, 0.0, 9.5, 100.0, NULL, 'usda', '174308', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('5dcaaec2-269c-4403-bbd4-e92390c0cc11', 'ديك رومي (شرائح)', 'Turkey, whole, breast, meat only, cooked, roasted', 'لحوم ودواجن', 147.0, 30.1, 0.0, 2.1, 50.0, NULL, 'usda', '171496', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('8e2579e4-65bb-4c33-9575-d7307d76e817', 'تونة معلبة بالماء', 'Fish, tuna, light, canned in water, drained solids (Includes foods for USDA''s Food Distribution Program)', 'أسماك', 86.0, 19.4, 0.0, 1.0, 100.0, 'علبة صغيرة مصفاة', 'usda', '173709', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3f2d5cb6-a9ff-44b0-acc6-1dca1d53644d', 'تونة معلبة بالزيت', 'Fish, tuna, light, canned in oil, drained solids', 'أسماك', 198.0, 29.1, 0.0, 8.2, 100.0, NULL, 'usda', '173708', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f52b09df-a098-48b2-a29d-50455b5d816d', 'سلمون مطبوخ', 'Fish, salmon, Atlantic, farmed, cooked, dry heat', 'أسماك', 206.0, 22.1, 0.0, 12.4, 120.0, NULL, 'usda', '175168', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('dd7029be-be15-4259-b3f5-2ab052215d60', 'سلمون مدخن', 'Fish, salmon, chinook, smoked', 'أسماك', 117.0, 18.3, 0.0, 4.3, 60.0, NULL, 'usda', '173687', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a70e48e5-e6fd-418c-845c-351e480d1076', 'روبيان مطبوخ', 'Crustaceans, shrimp, cooked', 'أسماك', 99.0, 24.0, 0.2, 0.3, 100.0, NULL, 'usda', '175180', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d2c7a374-2bb2-4355-8c8d-2ae684bad092', 'هامور/سمك أبيض مطبوخ', 'Fish, grouper, mixed species, cooked, dry heat', 'أسماك', 118.0, 24.8, 0.0, 1.3, 150.0, NULL, 'usda', '171963', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('63af0159-f9f0-440b-b258-293773f27efd', 'بيض كامل', 'Egg, whole, raw, fresh', 'بيض وألبان', 143.0, 12.6, 0.7, 9.5, 50.0, 'بيضة', 'usda', '171287', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('488ac671-5192-4247-a4c3-218d494da916', 'بياض بيض', 'Egg, white, raw, fresh', 'بيض وألبان', 52.0, 10.9, 0.7, 0.2, 33.0, 'بياض بيضة', 'usda', '172183', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('5dc14c16-ba4d-4053-881b-15a933ed2f7f', 'بيض مسلوق', 'Egg, whole, cooked, hard-boiled', 'بيض وألبان', 155.0, 12.6, 1.1, 10.6, 50.0, 'بيضة', 'usda', '173424', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('e55dafe4-2a1f-4670-b1cd-13d8c837dc4b', 'حليب كامل الدسم', 'Milk, whole, 3.25% milkfat, with added vitamin D', 'بيض وألبان', 61.0, 3.2, 4.8, 3.3, 244.0, 'كوب', 'usda', '171265', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('581d6cbc-40d9-4c2a-8d77-8287dc3c0d60', 'حليب قليل الدسم 1%', 'Milk, lowfat, fluid, 1% milkfat, with added vitamin A and vitamin D', 'بيض وألبان', 42.0, 3.4, 5.0, 1.0, 244.0, 'كوب', 'usda', '170872', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('03931b9a-7a27-42b5-a185-87246f27ca38', 'حليب خالي الدسم', 'Milk, nonfat, fluid, with added vitamin A and vitamin D (fat free or skim)', 'بيض وألبان', 34.0, 3.4, 5.0, 0.1, 245.0, 'كوب', 'usda', '171269', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('20200dcc-ee28-4eec-ab04-0a61db244911', 'زبادي كامل الدسم', 'Yogurt, plain, whole milk', 'بيض وألبان', 61.0, 3.5, 4.7, 3.3, 170.0, NULL, 'usda', '171284', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('0bee0c58-b6c6-4b0b-bb73-dc1f736d4fff', 'زبادي قليل الدسم', 'Yogurt, plain, low fat', 'بيض وألبان', 63.0, 5.3, 7.0, 1.6, 170.0, NULL, 'usda', '170886', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('9f4ca9b8-ccf5-4816-83ee-6d50cfc5106f', 'زبادي يوناني قليل الدسم', 'Yogurt, Greek, plain, lowfat', 'بيض وألبان', 73.0, 10.0, 3.9, 1.9, 170.0, NULL, 'usda', '170903', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('aeb9273e-f100-4691-892f-2c46641fdaf8', 'زبدة فول سوداني', 'Peanut butter, smooth style, without salt', 'دهون ومكسرات', 598.0, 22.2, 22.3, 51.4, 16.0, 'ملعقة كبيرة', 'usda', '172470', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('1f24ed67-82fb-4e20-a5c4-864f9ffb201c', 'زبادي يوناني خالي الدسم', 'Yogurt, Greek, plain, nonfat (Includes foods for USDA''s Food Distribution Program)', 'بيض وألبان', 59.0, 10.2, 3.6, 0.4, 170.0, NULL, 'usda', '170894', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('e5855c7e-6254-4c9b-897e-c6bd618b401f', 'جبنة قريش (كوتج)', 'Cheese, cottage, lowfat, 2% milkfat', 'بيض وألبان', 81.0, 10.5, 4.8, 2.3, 113.0, 'نص كوب', 'usda', '172182', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('04874227-71c4-47a9-9503-b13ceeb648c6', 'جبنة موزاريلا قليلة الدسم', 'Cheese, mozzarella, part skim milk', 'بيض وألبان', 254.0, 24.3, 2.8, 15.9, 28.0, NULL, 'usda', '170847', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d4b46616-1319-47e2-b36f-2671378cdb4d', 'جبنة شيدر', 'Cheese, cheddar (Includes foods for USDA''s Food Distribution Program)', 'بيض وألبان', 403.0, 22.9, 3.4, 33.3, 28.0, 'شريحة', 'usda', '173414', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('7b22ff7e-8717-4694-b1a1-a61c317d2174', 'جبنة فيتا', 'Cheese, feta', 'بيض وألبان', 265.0, 14.2, 3.9, 21.5, 28.0, NULL, 'usda', '173420', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('780abbd1-fe98-46e0-aa6d-4d0797a9967f', 'جبنة كريمية', 'Cheese, cream', 'بيض وألبان', 350.0, 6.2, 5.5, 34.4, 30.0, NULL, 'usda', '173418', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('faadad0e-8c1e-4366-a894-82a7f1fd8bda', 'واي بروتين', 'Beverages, Whey protein powder isolate', 'مكملات', 359.0, 58.1, 29.1, 1.2, 30.0, 'سكوب', 'usda', '173177', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ebcef81a-f761-4b75-bd91-9fce6df17923', 'عدس مطبوخ', 'Lentils, mature seeds, cooked, boiled, without salt', 'بقوليات', 116.0, 9.0, 20.1, 0.4, 150.0, NULL, 'usda', '172421', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('e5b4c51a-f863-4458-9d2a-27cf5cb21bad', 'حمص مطبوخ', 'Chickpeas (garbanzo beans, bengal gram), mature seeds, cooked, boiled, without salt', 'بقوليات', 164.0, 8.9, 27.4, 2.6, 150.0, NULL, 'usda', '173757', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('628bc0b2-8c10-4f65-929b-25241616ee79', 'فول مدمس (مطبوخ)', 'Broadbeans (fava beans), mature seeds, cooked, boiled, without salt', 'بقوليات', 110.0, 7.6, 19.7, 0.4, 150.0, NULL, 'usda', '173753', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f6fccc17-1bb8-4243-b656-f18904a6dd90', 'فاصوليا حمراء مطبوخة', 'Beans, kidney, all types, mature seeds, cooked, boiled, without salt', 'بقوليات', 127.0, 8.7, 22.8, 0.5, 150.0, NULL, 'usda', '173740', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('4461d30a-a685-4aa9-ad74-3fbbf7e4f628', 'حمص بطحينة (حمص جاهز)', 'Hummus, commercial', 'بقوليات', 237.0, 7.8, 15.0, 17.8, 60.0, NULL, 'usda', '174289', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('0af1dfed-c32b-4f05-a27c-a8d1c44aed5e', 'تمر مجدول', 'Dates, medjool', 'فواكه', 277.0, 1.8, 75.0, 0.2, 24.0, 'حبة', 'usda', '168191', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d6069a4e-890e-495f-a423-a3df03c8da2c', 'تمر (دقلة نور)', 'Dates, deglet noor', 'فواكه', 282.0, 2.5, 75.0, 0.4, 7.0, 'حبة', 'usda', '171726', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('9cd5d494-fb0c-4311-96aa-89c1687cb535', 'موز', 'Bananas, raw', 'فواكه', 89.0, 1.1, 22.8, 0.3, 118.0, 'حبة وسط', 'usda', '173944', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a9fec6e9-e380-4339-bf9c-3914ab1ceda4', 'تفاح', 'Apples, raw, with skin (Includes foods for USDA''s Food Distribution Program)', 'فواكه', 52.0, 0.3, 13.8, 0.2, 182.0, 'حبة وسط', 'usda', '171688', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('5f928df1-523b-4f71-8709-2b65d64b2675', 'برتقال', 'Oranges, raw, all commercial varieties', 'فواكه', 47.0, 0.9, 11.8, 0.1, 131.0, 'حبة', 'usda', '169097', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a673330b-59ec-448d-8051-48e932ce8ba4', 'فراولة', 'Strawberries, raw', 'فواكه', 32.0, 0.7, 7.7, 0.3, 150.0, 'كوب', 'usda', '167762', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('08ad8158-c6e8-41e1-99cd-afb4acf30d80', 'عنب', 'Grapes, red or green (European type, such as Thompson seedless), raw', 'فواكه', 69.0, 0.7, 18.1, 0.2, 150.0, 'كوب', 'usda', '174683', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('c078954e-ef47-4050-9ff3-fa0d214c458b', 'بطيخ', 'Watermelon, raw', 'فواكه', 30.0, 0.6, 7.6, 0.2, 280.0, 'كوب ونص', 'usda', '167765', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3c764598-2f98-4d38-9e07-6319f601c7b6', 'مانجو', 'Mangos, raw', 'فواكه', 60.0, 0.8, 15.0, 0.4, 165.0, 'كوب', 'usda', '169910', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b772ba16-cfd7-405d-b2ed-d5be6b7e0351', 'أناناس', 'Pineapple, raw, all varieties', 'فواكه', 50.0, 0.5, 13.1, 0.1, 165.0, 'كوب', 'usda', '169124', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('70cf5c99-fd3a-4904-8f4a-0dda164e1dbd', 'توت أزرق', 'Blueberries, raw', 'فواكه', 57.0, 0.7, 14.5, 0.3, 148.0, 'كوب', 'usda', '171711', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('de588a54-2f86-4586-a4bb-0bec5d9f92f4', 'كيوي', 'Kiwifruit, green, raw', 'فواكه', 61.0, 1.1, 14.7, 0.5, 75.0, 'حبة', 'usda', '168153', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('434d3b9c-5977-4d20-a23d-b821f72074df', 'رمان', 'Pomegranates, raw', 'فواكه', 83.0, 1.7, 18.7, 1.2, 87.0, 'نص كوب حبوب', 'usda', '169134', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('609382ed-e9ed-4075-a32f-bf201094fa6b', 'خيار', 'Cucumber, with peel, raw', 'خضار', 15.0, 0.7, 3.6, 0.1, 100.0, NULL, 'usda', '168409', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('199e7609-dd07-4da5-8d86-577a500b4ed6', 'طماطم', 'Tomatoes, red, ripe, raw, year round average', 'خضار', 18.0, 0.9, 3.9, 0.2, 120.0, 'حبة وسط', 'usda', '170457', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('22e49507-68be-4c7c-9b5c-7fdd743bafa5', 'خس', 'Lettuce, cos or romaine, raw', 'خضار', 17.0, 1.2, 3.3, 0.3, 50.0, NULL, 'usda', '169247', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3a8caf62-f458-404a-9b90-938b09050e05', 'جزر', 'Carrots, raw', 'خضار', 41.0, 0.9, 9.6, 0.2, 60.0, 'حبة', 'usda', '170393', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('716a8508-df5a-4a73-992e-df968282bdeb', 'بروكلي مطبوخ', 'Broccoli, cooked, boiled, drained, without salt', 'خضار', 35.0, 2.4, 7.2, 0.4, 90.0, NULL, 'usda', '169967', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b814a25f-f601-4d15-b49d-9a69ea03ce18', 'سبانخ', 'Spinach, raw', 'خضار', 23.0, 2.9, 3.6, 0.4, 30.0, 'كوب', 'usda', '168462', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ec45bc1f-d8c9-4086-a7bb-d3ec68166c18', 'فلفل رومي أحمر', 'Peppers, sweet, red, raw', 'خضار', 26.0, 1.0, 6.0, 0.3, 120.0, 'حبة', 'usda', '170108', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3d266862-7c97-4633-b6df-53895da7a7aa', 'بصل', 'Onions, raw', 'خضار', 40.0, 1.1, 9.3, 0.1, 110.0, 'حبة وسط', 'usda', '170000', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3c80e095-7e1a-4760-ad1c-3067e9571c7f', 'فطر (مشروم)', 'Mushrooms, white, raw', 'خضار', 22.0, 3.1, 3.3, 0.3, 70.0, 'كوب', 'usda', '169251', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('0183121b-ee61-491e-a273-8b9f75976eae', 'كوسا مطبوخة', 'Squash, summer, zucchini, includes skin, cooked, boiled, drained, without salt', 'خضار', 15.0, 1.1, 2.7, 0.4, 180.0, NULL, 'usda', '169292', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('58a7554e-7239-4564-b1cf-efd314c75a58', 'باذنجان مطبوخ', 'Eggplant, cooked, boiled, drained, without salt', 'خضار', 35.0, 0.8, 8.7, 0.2, 100.0, NULL, 'usda', '169229', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('7c885709-3fe7-456e-a688-79a754cd48a0', 'ذرة حلوة مطبوخة', 'Corn, sweet, yellow, cooked, boiled, drained, without salt', 'خضار', 96.0, 3.4, 21.0, 1.5, 150.0, NULL, 'usda', '169999', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('6611e860-aa59-4d3d-998c-be21020213e2', 'أفوكادو', 'Avocados, raw, all commercial varieties', 'دهون ومكسرات', 160.0, 2.0, 8.5, 14.7, 50.0, 'ثلث حبة', 'usda', '171705', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('1a01ec51-8afc-4651-9299-42c7d1e836b7', 'زيت زيتون', 'Oil, olive, salad or cooking', 'دهون ومكسرات', 884.0, 0.0, 0.0, 100.0, 5.0, 'ملعقة صغيرة', 'usda', '171413', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f2cfbeba-2d97-4925-a992-9239c218cd0d', 'زبدة', 'Butter, salted', 'دهون ومكسرات', 717.0, 0.9, 0.1, 81.1, 5.0, 'ملعقة صغيرة', 'usda', '173410', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('0b55c71c-1fc5-4f0c-b84f-a7aadcdfd262', 'لوز', 'Nuts, almonds', 'دهون ومكسرات', 579.0, 21.2, 21.6, 49.9, 28.0, 'حفنة', 'usda', '170567', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f1a78d4f-31a5-4bf9-8dfe-0f468aeb80fc', 'كاجو', 'Nuts, cashew nuts, raw', 'دهون ومكسرات', 553.0, 18.2, 30.2, 43.9, 28.0, 'حفنة', 'usda', '170162', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a862a719-ddd5-4628-ae3c-d013478c4851', 'فستق حلبي', 'Nuts, pistachio nuts, raw', 'دهون ومكسرات', 560.0, 20.2, 27.2, 45.3, 28.0, 'حفنة', 'usda', '170184', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ef9d76c3-7abc-4ad1-b178-b1bb298276d5', 'جوز (عين الجمل)', 'Nuts, walnuts, english', 'دهون ومكسرات', 654.0, 15.2, 13.7, 65.2, 28.0, 'حفنة', 'usda', '170187', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('395d2655-f1c0-4883-b1de-dc4da3b60f10', 'فول سوداني', 'Peanuts, all types, raw', 'دهون ومكسرات', 567.0, 25.8, 16.1, 49.2, 28.0, 'حفنة', 'usda', '172430', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d1d9f701-4e78-4d0c-bb07-494bfa3c2e2b', 'طحينة', 'Seeds, sesame butter, tahini, from roasted and toasted kernels (most common type)', 'دهون ومكسرات', 595.0, 17.0, 21.2, 53.8, 15.0, 'ملعقة كبيرة', 'usda', '170189', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('8dc6b71c-6d52-404a-b17a-24aaffae9dde', 'بذور الشيا', 'Seeds, chia seeds, dried', 'دهون ومكسرات', 486.0, 16.5, 42.1, 30.7, 12.0, 'ملعقة كبيرة', 'usda', '170554', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('9322159f-bfef-4e2c-aa1c-c919c773198f', 'عسل', 'Honey', 'حلويات ومشروبات', 304.0, 0.3, 82.4, 0.0, 21.0, 'ملعقة كبيرة', 'usda', '169640', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('2e36820b-18d0-4bca-8b00-5ca40d6a005c', 'سكر أبيض', 'Sugars, granulated', 'حلويات ومشروبات', 387.0, 0.0, 100.0, 0.0, 4.0, 'ملعقة صغيرة', 'usda', '169655', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('58447942-19ad-49e9-8a6a-a5857073fbf1', 'شوكولاتة داكنة 70-85%', 'Chocolate, dark, 70-85% cacao solids', 'حلويات ومشروبات', 598.0, 7.8, 45.9, 42.6, 20.0, NULL, 'usda', '170273', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('086fff6b-9fc1-466c-9a98-3bfeb7dd1c97', 'عصير برتقال', 'Orange juice, raw (Includes foods for USDA''s Food Distribution Program)', 'حلويات ومشروبات', 45.0, 0.7, 10.4, 0.2, 248.0, 'كوب', 'usda', '169098', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('7e48314b-f771-4c76-ad6d-4339fc23cdcb', 'مايونيز', 'Salad dressing, mayonnaise, regular', 'صوصات', 680.0, 1.0, 0.6, 74.9, 15.0, 'ملعقة كبيرة', 'usda', '171009', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('8491d8b7-1c69-4520-b5f8-48a2540b7329', 'كاتشب', 'Catsup', 'صوصات', 101.0, 1.0, 27.4, 0.1, 17.0, 'ملعقة كبيرة', 'usda', '168556', true, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;



INSERT INTO public.policies VALUES ('terms', 'الشروط والأحكام', '- يبدأ الاشتراك بعد التحقق من وصول التحويل البنكي، وتعبئة استبيان المتدرب.
- ساعات العمل: الأحد – الخميس، 12 ظهراً – 9 مساءً. الرد على الرسائل خلال 48 ساعة عمل.
- البرنامج لا يغني عن الاستشارة الطبية، والمتدرب مسؤول عن الإفصاح عن أي إصابة أو حالة صحية.
- الجداول ملك المتدرب مدى الحياة ويمكنه التعديل عليها.
- الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي.', 0, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.policies VALUES ('refund', 'الضمان والاسترجاع', '- في اشتراكات 3 أشهر لباقات المتابعة (المكثفة، المتقدمة، الأساسية): يُسترد المبلغ كاملاً إذا لم يتحسن أي من مؤشرات التقدم (متوسط الوزن الأسبوعي، محيط الخصر، القوة في التمارين الأساسية) بعد 12 أسبوعاً.
- شروط الضمان: إرسال المراجعة الأسبوعية كل أسبوع، وأخذ القياسات بانتظام، وتصوير التمارين وإرسالها، والالتزام بجدول التغذية المخصص في الباقات التي تشملها.
- يُطلب الاسترجاع عبر واتساب خلال 14 يوماً من نهاية الأشهر الثلاثة، ويُرجع المبلغ بتحويل بنكي.
- التجديد المجاني: اشتراك 3 أشهر يُكافأ بـ 3 أشهر إضافية عند التزام 90% فأكثر وتقدم واضح في مؤشرات التقدم. صور التطور تُرسل للمدربة للتوثيق (للرجال مع تغطية الوجه والسرة)، ونشرها اختياري.', 1, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.policies VALUES ('privacy', 'سياسة الخصوصية', '- نجمع: الاسم، البريد الإلكتروني (للدخول إلى حسابك)، رقم الجوال (واتساب)، الباقة المختارة، ومعلومات الاستبيان التي تكتبها بنفسك (ومنها معلومات صحية وقياسات اختيارية).
- الغرض: تنفيذ طلبك، وتصميم برنامجك ومتابعتك، والتواصل معك بخصوصه فقط.
- المعلومات الصحية تُحفظ منفصلة، ولا يطّلع عليها إلا أنت والمدربة، ولا تُرسل في رسائل البريد أو التنبيهات.
- الدفع بتحويل بنكي مباشر لحساب المؤسسة، والموقع لا يطلب أو يخزن أي بيانات بنكية أو بيانات بطاقات. إيصال التحويل يُستخدم لتأكيد طلبك فقط، ويُحفظ في تخزين خاص لا يُفتح إلا لك وللمدربة.
- لا نبيع بياناتك ولا نشاركها مع أي طرف لأغراض تسويقية، ولا تُنشر نتيجتك أو صورتك إلا بموافقتك الصريحة.
- تقدر تطلب نسخة من بياناتك أو حذفها أو سحب موافقتك على النشر بمراسلتنا على واتساب.', 2, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.policies VALUES ('reviews', 'سياسة التقييمات', '- يكتب التقييم فقط من اشترى خدمة وبدأها فعلاً، وتقييم واحد لكل طلب.
- كل تقييم يُراجع قبل ظهوره للعامة، ولا يُعدّل نصه أبداً.
- تختار بنفسك طريقة ظهور اسمك: الاسم كامل، أو الاسم الأول فقط، أو بدون اسم. والموافقة على النشر منفصلة واختيارية.
- لا يُنشر تقييم يحتوي أرقام هواتف أو بريد أو روابط أو تفاصيل صحية خاصة أو إساءة لأي شخص.
- يحق للمدربة الرد على التقييم، أو إخفاء التقييم المخالف لهذه السياسة مع تسجيل السبب.
- تقدر تطلب إخفاء تقييمك في أي وقت بمراسلتنا على واتساب.', 3, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;



INSERT INTO public.products VALUES ('7658fb16-68f4-45cc-b64c-f94f2f91fb02', 'intensive', 'follow', 'الباقة المكثفة', 'الأنسب للمبتدئين ولمن يحتاج متابعة أسبوعية مع زوم: تمرين + تغذية + زوم + جلسة حضورية', '[{"text": "جلسة حضورية مجانية لمدة ساعة لتصحيح التكنيك والتأكد من جودة التمرين (للبنات في المنطقة الشرقية)", "included": true}, {"text": "ملف شامل للخطة التدريبية والتغذية مع شروحات وافية للتمارين، بالمنزل أو بالنادي", "included": true}, {"text": "4 مكالمات زوم شهرياً نتابع فيها تطورك واستفساراتك الرياضية والنفسية", "included": true}, {"text": "مناقشة أسبوعية لتطورك البدني والنفسي (فيديو أو تسجيل صوتي) مع تعديل السعرات أو التمرين عند الحاجة", "included": true}, {"text": "شرح سهل ومبسط لتطبيق حساب السعرات MyFitnessPal", "included": true}, {"text": "كتيب شامل للرياضة والتغذية", "included": true}, {"text": "مساعدتك على اختيارات أنسب لصحتك ونمط حياتك في التغذية والروتين اليومي", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}]', NULL, 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.', true, NULL, 'published', 0, false, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('a723c17d-9d41-4579-ae7e-78d2da84b91c', 'advanced', 'follow', 'الباقة المتقدمة', 'لمن عنده خبرة ويحتاج تمرين + تغذية مع متابعة أسبوعية، بدون زوم', '[{"text": "ملف شامل للخطة التدريبية والتغذية مع شروحات وافية للتمارين، بالمنزل أو بالنادي", "included": true}, {"text": "مناقشة أسبوعية لتطورك البدني والنفسي (فيديو أو تسجيل صوتي) مع تعديل السعرات أو التمرين عند الحاجة", "included": true}, {"text": "كتيب شامل للرياضة والتغذية", "included": true}, {"text": "مساعدتك على اختيارات أنسب لصحتك ونمط حياتك في التمرين والروتين اليومي", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}, {"text": "مكالمات زوم والجلسة الحضورية (في المكثفة فقط)", "included": false}]', NULL, 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.', false, NULL, 'published', 1, false, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('9e2ff442-2cd6-47c3-a33b-a64470c0f165', 'basic', 'follow', 'الباقة الأساسية', 'لمن يعرف يضبط أكله ويحتاج خطة تمرين فقط، ومتابعة كل أسبوعين', '[{"text": "ملف شامل للخطة التدريبية مع شروحات وافية للتمارين، بالمنزل أو بالنادي", "included": true}, {"text": "مناقشة كل أسبوعين لتطورك البدني والنفسي (فيديو أو تسجيل صوتي) مع تعديل التمرين عند الحاجة", "included": true}, {"text": "كتيب شامل للرياضة والتغذية", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}, {"text": "بدون خطة تغذية", "included": false}]', NULL, 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.', false, NULL, 'published', 2, false, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('91ac8661-d815-4d08-a493-12fa6cdc1599', 'nutrition', 'follow', 'باقة التغذية', 'لمن يحتاج خطة تغذية شاملة ويتعلم حساب السعرات، بدون خطة تمرين', '[{"text": "خطة تغذية شاملة تناسب هدفك ونمط حياتك", "included": true}, {"text": "تحديد السعرات المناسبة لك ولهدفك", "included": true}, {"text": "تعليمك حسبة السعرات ومساعدتك باختيارات تغذية تناسبك", "included": true}, {"text": "ملف Excel لمتابعة التطور والقياسات", "included": true}, {"text": "مناقشة أسبوعية لعلاقتك بالتغذية في المنزل أو خارجه", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}, {"text": "لا تحتاجها إذا كنت مشتركاً في المكثفة أو المتقدمة، لأن التغذية ضمنها", "included": false}]', 'شهر واحد · غالباً لا تحتاج تجديد', 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي، ولا يوجد تجديد تلقائي. ضمان الاسترجاع يشمل اشتراكات 3 أشهر للمكثفة والمتقدمة والأساسية فقط.', false, NULL, 'published', 3, false, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('429d8930-dab2-49b2-9e70-58ba9a8db82e', 'custom-training-plan', 'files', 'بديل التدريب الشخصي', 'لمن لا يحتاج متابعة (متقدم)، أو كبديل أوفر للتدريب الشخصي', '[{"text": "جدول تمرين مخصص لعدد أيام التمرين اللي تحتاجها", "included": true}, {"text": "طريقة حساب الجهد وعدد الجولات المطلوبة", "included": true}, {"text": "تقدر تحمّل الجدول على جهازك", "included": true}]', NULL, 'جدول مخصص بعد الاستبيان تستلمه كملف، وتقدر تحمّله على جهازك. بدون متابعة.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي. الجداول لك مدى الحياة وتقدر تعدّل عليها.', false, NULL, 'published', 4, false, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('792ac54d-b452-4553-94bf-7a77e96ace56', 'training-nutrition-plan', 'files', 'جدول تمارين مع التغذية', 'لمن لا يحتاج متابعة (متقدم)، أو كبديل أوفر للتدريب الشخصي', '[{"text": "جدول تمرين مخصص لعدد أيام التمرين اللي تحتاجها", "included": true}, {"text": "طريقة حساب الجهد وعدد الجولات المطلوبة", "included": true}, {"text": "جدول تغذية فيه خيارات تناسب هدفك الرياضي", "included": true}, {"text": "تقدر تحمّل الجدول على جهازك", "included": true}]', NULL, 'جدول مخصص بعد الاستبيان تستلمه كملف، وتقدر تحمّله على جهازك. بدون متابعة.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي. الجداول لك مدى الحياة وتقدر تعدّل عليها.', false, NULL, 'published', 5, false, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('6b77d277-ea4c-42be-b920-e27c4db5b4c1', 'nutrition-consultation', 'consult', 'جلسة استشارة تغذية', 'لمن عنده أسئلة محددة في التغذية: جلسة وحدة تكفي لحسبة سعراتك ونصائح الأكل.', '[{"text": "مناقشة كل أسئلتك في مجال التغذية", "included": true}, {"text": "حسبة سعرات مناسبة لهدفك مع اقتراحات لأصناف الطعام", "included": true}, {"text": "نصائح في المكملات، وكيف تأكل برّا بطريقة صحيحة", "included": true}]', NULL, 'جلسة عبر Google Meet أو واتساب — المناسب لك.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي.', false, NULL, 'published', 6, false, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('f427af42-e891-4585-8bf2-0fa713fafb82', 'training-consultation', 'consult', 'جلسة استشارة تمرين', 'لمن عنده أسئلة محددة في التمرين: جلسة وحدة تكفي لتعديل جدولك وتصحيح التكنيك.', '[{"text": "مناقشة كل أسئلتك في مجال التمرين", "included": true}, {"text": "تعديل جدولك الرياضي بما يناسب هدفك، مع اقتراحات لتمارين المرونة", "included": true}, {"text": "تصحيح تكنيك التمارين اللي تشك إنها غلط أو تسبب لك ألم", "included": true}, {"text": "التأكد من أن جودة تمرينك مناسبة للبناء العضلي", "included": true}]', NULL, 'جلسة عبر Google Meet أو واتساب — المناسب لك.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي.', false, NULL, 'published', 7, false, '2026-09-27 13:38:37.68352+00', '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;



INSERT INTO public.product_offers VALUES ('e10a1d8e-2ed7-4528-80ad-b7ccef8da22e', '7658fb16-68f4-45cc-b64c-f94f2f91fb02', 'int1', 'شهر واحد', 1, 59900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('9c3fb975-5bc7-4562-8ebc-40f6c7e0688c', '7658fb16-68f4-45cc-b64c-f94f2f91fb02', 'int3', '3 أشهر', 3, 155000, 'SAR', true, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('713aec34-66fe-4d65-b00d-21e1a16750df', 'a723c17d-9d41-4579-ae7e-78d2da84b91c', 'adv1', 'شهر واحد', 1, 49900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('e7ee9a0d-ce53-4831-af6f-e68c19e74d11', 'a723c17d-9d41-4579-ae7e-78d2da84b91c', 'adv3', '3 أشهر', 3, 125000, 'SAR', true, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('fb2d7ea2-66d3-4946-9f84-bf8858527a59', '9e2ff442-2cd6-47c3-a33b-a64470c0f165', 'bas1', 'شهر واحد', 1, 34900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('da25ce25-1c4f-497a-9ea6-c7e45cbb63c6', '9e2ff442-2cd6-47c3-a33b-a64470c0f165', 'bas3', '3 أشهر', 3, 95000, 'SAR', true, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('ab47753f-3010-4cf5-959e-6ed4544a379b', '91ac8661-d815-4d08-a493-12fa6cdc1599', 'nut1', 'شهر واحد', 1, 25000, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('66be87bc-d2b6-4c90-8523-13335e45f142', '429d8930-dab2-49b2-9e70-58ba9a8db82e', 'diy', 'دفعة واحدة', 0, 19900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('c9b03e1c-d4f2-4656-b410-e12ea78722df', '792ac54d-b452-4553-94bf-7a77e96ace56', 'diyN', 'دفعة واحدة', 0, 25000, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('2af5a44a-e638-4a49-9f8c-be9e3d040ed2', '6b77d277-ea4c-42be-b920-e27c4db5b4c1', 'cN', 'دفعة واحدة', 0, 15000, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('aa71bbc7-4f76-497c-a000-67d609c3c503', 'f427af42-e891-4585-8bf2-0fa713fafb82', 'cT', 'دفعة واحدة', 0, 18900, 'SAR', true, 0) ON CONFLICT DO NOTHING;



INSERT INTO public.reviews VALUES ('b30bb26b-2912-41a0-9360-a2611e0e0156', 'legacy', NULL, NULL, NULL, NULL, 'اشتركت معها 3 شهور وكانت أول مره التزم بالتمرين بعد سحبات سنين، اسلوبها سهل وسريع بس نتايجه واضحه من اول اسبوعين قياسات جسمي بدت تتغير والكوتش مريحه نفسيًا وشاطرة الله يعطيها العافيه غيرت حياتي واعطتني افضل بداية 🙏🏻', 'first', 'ريم', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 0, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('2f8dd583-0e02-4b4d-8157-e355cb12a7e9', 'legacy', NULL, NULL, NULL, 5, 'من أصدق التجارب اللي مرّيت فيها! تدريبك ما كان بس جداول رياضه وتغذية كان دعم نفسي وتحفيز وتغيير حقيقي في حياتي حسّيت بفرق كبير في جسمي وطاقتي وثقتي بنفسي من أول أسبوع شكراً من القلب على تعبك وحرصك على كل تفصيلة وتعطي من قلبك، فعلاً you are the best coach ever تستاهلين كل النجاح والله ❤️', 'first', 'نورة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 1, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('c8e6e644-09ed-412c-a6ac-1da474ec4429', 'legacy', NULL, NULL, NULL, 5, 'بعد شهر من الالتزام بالجدول، لاحظت فرق واضح! متنوع وفعال، أنصح فيه بشدة 😍👌', 'first', 'البندري', 'مارس 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 2, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('512cee7a-777c-4efe-b3f3-f284c43770c7', 'legacy', NULL, NULL, NULL, NULL, 'رغم ان فتره تدريبي معاها كانت اقل من شهرين السنه الماضيه الا ان نتايج هالشهرين مستمره معي الى اليوم 😍 اسلوب احترافي وفعال وتركز على بناء وتطوير عادات تدوم مو بس تمارين مؤقته 👍🏻', 'first', 'خديجة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 3, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('fed82b4d-c913-4b87-8a9b-892b67999e4a', 'legacy', NULL, NULL, NULL, 5, 'كوتش ساره جداً شاطره و بروفيشنال، جداً متعاونه و تعرف شغلها كويس، جداً لطيفه، كنت لفتره متدربه عندها و كنت أشوف نتايج بطله بالاضافه لكوني اروح اتمرن و أنا مستمتعه، شكراً ساره', 'first', 'نجمة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 4, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('0c90c84c-ff7b-4071-9475-264e800fe58d', 'legacy', NULL, NULL, NULL, 5, 'ممتاز جدول حلو ومرتب جدا وفرق معي كثير 🤍', 'first', 'سعود', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 5, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('fdcb23c0-70e0-487a-8152-ca176da2eeed', 'legacy', NULL, NULL, NULL, 5, 'كنت اعاني من الم بظهري مستمررر سنوات وانحراف بالعمود ولكن بفضل الله ثم المدربة تحسنت بنسبة كبيرة وتابع معي خطوة بخطوة بكل أمانة وإتقان الله يكثر من امثالك 🤍', 'first', 'ش**س**', 'أغسطس 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 6, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('21d410d1-7695-48a0-9a7f-b87c73afce22', 'legacy', NULL, NULL, NULL, 5, 'الشكر يعجز عنك يااروع كوتش باشتراكي معك شفت صحة وراحة بعد الله وساعدتيني مره بمشكلة ظهري وضعف العضلات العلوية وانعكس على نفسيتي وادائي اليومي شكررا شكرا من القلب وياحظنا فيك', 'first', 'فاطمة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 7, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('8754d473-473b-4ae1-8c57-42bb4291d85f', 'legacy', NULL, NULL, NULL, 5, 'مره استفدت بالتدريب مع كوتش ناف و مبسوطه ان في احد بذمة و ضمير جالس يتابع تقدمي و ينصحني من قلب الله يسعدك ويوفقك ❤️', 'first', 'ميثاء', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 8, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('1fc3f7a9-b9da-4814-bad0-a1c0d3461f0c', 'legacy', NULL, NULL, NULL, 5, 'تجربه ولا أروع ! أحب جداولها وقد ايش تختصر وتعطيك المهم والاهم والنتايج رهيييبه ❤️', 'first', 'أمجاد', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 9, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('06fe4175-92ec-4bb7-afd8-49e872f8003e', 'legacy', NULL, NULL, NULL, 5, 'افضل مدربة بالمجرة، كنت دبه ونحفت بثلاث شهور بس، i highly recommend her she is the best 💗', 'first', 'شروق', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 10, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('27293eda-cf48-4763-92cf-ade9795aa4db', 'legacy', NULL, NULL, NULL, 5, 'الجدول ممتاز و فعّال لفترة الصيام، يساعدك تنظم وقتك ويقدّم توصيات غذائيه و خطه تمارين تساعدك تحافظ على لياقتك بدون إرهاق 👍🏻. خيار ممتاز خاصة للأشخاص للي وقتها محدود ومزحوم فرمضان.', 'first', 'خديجة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 11, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;



INSERT INTO public.site_settings VALUES ('reminders', '{"review_text": "مرحباً {name}، تذكير بمراجعتك الأسبوعية: المراجعة مفتوحة من {window_start} إلى {window_end}.", "sub_expiry_days": [7, 3], "sub_expiry_text": "مرحباً {name}، اشتراكك في {product} ينتهي بتاريخ {end_date}. للتجديد أو الاستفسار تواصل معنا.", "review_lead_days": 1, "missed_review_text": "مرحباً {name}، ما وصلتنا مراجعة الأسبوع المنتهي في {window_end}. متى ما تيسّر لك، حدّثها عشان نتابع تقدمك.", "review_window_days": 2, "manual_cooldown_minutes": 10}', false, NULL, '2026-09-27 13:38:37.417315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('hero', '{"lead": "خطة تدريب وغذاء منظمة، متابعة للتقدم، وتعديلات أسبوعية تناسب مستواك وظروفك.", "title": "برامج تدريب وتغذية مخصصة لأهدافك", "eyebrow": "Nav Coaching · الكوتش ساره", "tagline": "Where Passion Meets Quality", "title_tail": "تحت إشراف مدربة يدفعها الشغف"}', true, NULL, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('badges', '["خصم 10% للطلاب", "مجاني لأهل غزة", "ضمان استرجاع المبلغ بشروط"]', true, NULL, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('why', '[{"body": "البرنامج يُصمم بعد استبيان مفصل لهدفك وأيامك المتاحة وأدواتك وأي إصابة تحتاج مراعاة.", "title": "مبني على هدفك ومستواك"}, {"body": "مراجعة منتظمة بالفيديو أو الصوت، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.", "title": "متابعة أسبوعية واضحة"}, {"body": "نعدّل التمرين والسعرات بناءً على قياساتك والتزامك، عشان تثبت النتيجة.", "title": "تعديلات حسب تقدمك"}]', true, NULL, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('how_steps', '[{"body": "اختر الباقة والمدة، وعبّي استبيان قصير عن هدفك ومستواك وأيامك وأي إصابة.", "title": "اختر برنامجك وعبّي الاستبيان"}, {"body": "بعد الاستبيان يظهر لك رقم طلبك وبيانات الحساب. حوّل وارفع صورة الإيصال من صفحة طلبك.", "title": "حوّل المبلغ"}, {"body": "بعد التحقق من التحويل أتواصل معك خلال 48 ساعة عمل، وتستلم ملف برنامجك وتبدأ المتابعة.", "title": "استلم برنامجك وابدأ"}]', true, NULL, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('about', '{"bio": "مدربة شخصية معتمدة، أدرب منذ 2017. أساعدك تبني روتين تدريب وتغذية واضح يناسب هدفك ووقتك ومستواك، مع متابعة أسبوعية تساعدك تستمر وتتقدم.", "fit": ["اللي يؤمن إن التمرين أسلوب حياة، مو تمرين لشكل مؤقت أو لفترة الصيف بس.", "**وإذا ما التزمت؟** أحاول أفهم أسبابك، وأساعدك تعالجها بقدر ما أقدر. وإذا كان الموضوع أكبر من اللي أقدر أقدمه، أقول لك بصراحة وأعتذر عن تدريبك."], "name": "الكوتش ساره | ناڤ", "certs": ["Saudi Reps — Level 4", "NCSF", "Menno Henselmans CPT", "Functional Mobility", "Pre & Postnatal Training", "Prenatal Fitness Training — Aspire Academy", "ماجستير تدريب رياضي — جامعة ستيرلنق"], "notes": [{"body": "لأني جاية من عالم الرياضات الإلكترونية، صممت باقة خاصة للقيمرز: لياقة أفضل داخل وخارج الشاشة، والتعامل مع آلام الظهر والمفاصل من الجلوس الطويل.", "href": "/programs/gamers", "label": "شوف باقة القيمرز ←", "title": "للاعبي الألعاب الإلكترونية"}, {"body": "تدريب الحوامل عندي حضوري فقط. أونلاين يصعب أتأكد إن التمرين يتنفذ بإتقان، والحمل فترة مهمة جداً تحتاج هالتأكد. أونلاين أقدم للحوامل متابعة التغذية فقط.", "href": "", "label": "", "title": "للحوامل"}], "story": ["قبل ما أصير مدربة، كنت متدربة تعبت من التجارب. اشتركت مع مدربات أجانب، وما لقيت أحد يشرح لي التمرين صح أو يهتم بأهدافي.", "لين اشتركت مع الكوتش سحر الحارثي. غيّرت نظرتي للتمرين، وحفّزتني أصير كوتش، وإلى اليوم أشكرها على كل اللي علمتني إياه. من هنا قررت أكون الشخص اللي احتجته أنا.", "والرياضة جزء مني من بدري: لعبت كرة السلة وكنت كابتن فريق السلة في جامعة الإمام عبدالرحمن بن فيصل، ولعبت باحتراف في الرياضات الإلكترونية. بدأت التدريب في 2017 مع كرة السلة، واشتغلت مساعد مدرب في نادي الجامعة، وبعدها دربت في بيور جم وجمنيشن وفتنس لاونج ونوادي خاصة."], "points": ["برنامج مبني على هدفك ومستواك.", "متابعة أسبوعية واضحة.", "تعديلات مستمرة حسب تقدمك والتزامك."], "pillars": [{"body": "ما أرسل لك جدول وأتركك. أراجعه معك بمقطع فيديو أشرح فيه كل شي، عشان تبدأ وأنت فاهم وش تسوي وليش.", "title": "جدولك مشروح بالفيديو"}, {"body": "ما أمشي على أنظمة الحرمان أبداً. خطتك تناسب حياتك، مو قائمة ممنوعات.", "title": "بدون حرمان"}, {"body": "أتابعك كل أسبوع وأهتم بالتزامك، وأعدّل خطتك حسب تقدمك وظروفك.", "title": "متابعة جادة وخطة واقعية"}, {"body": "حب تعليم الناس معي من الصغر. اللي أعرفه ما أبخل فيه، علمياً ونفسياً، وما أوقف عن البحث والتعلم عشان أتطور وأطورك معي.", "title": "أعلّمك، مو بس أدربك"}], "home_bio": "مدربة شخصية معتمدة، أدرب منذ 2017، وكابتن سابقة لفريق السلة في جامعة الإمام عبدالرحمن بن فيصل. أساعدك تبني روتين تدريب وتغذية واضح يناسب هدفك ووقتك ومستواك، مع متابعة أسبوعية وبدون أنظمة حرمان.", "fit_title": "أكثر شخص أفرق معه", "experience": ["أدرب منذ 2017، والبداية في كرة السلة.", "مساعد مدرب في نادي الجامعة.", "مدربة في بيور جم، وجمنيشن، وفتنس لاونج، ونوادي خاصة."], "story_title": "صرت الشخص اللي كنت أحتاجه", "pillars_title": "وش يميز التدريب معي؟", "experience_title": "شهاداتي وخبرتي"}', true, NULL, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('intro_video', '{"url": "", "body": "مقطع قصير أتكلم فيه عن نفسي وخلفيتي وطريقة شغلي مع المتدربين.", "title": "تعرّف عليّ في دقيقة"}', true, NULL, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('testimonials_disclaimer', '"التجارب شخصية وتختلف النتائج من شخص لآخر حسب الالتزام والحالة، والتدريب لا يغني عن استشارة الطبيب أو أخصائي العلاج الطبيعي."', true, NULL, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('prices_note', '"الأسعار بالريال السعودي. الدفع بتحويل بنكي على حساب المؤسسة."', true, NULL, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('checkins', '{"enabled": true, "questions": [{"q": "ملاحظاتك الصحية؟ الحركة اليومية وجودة الحياة صارت أحسن؟", "topic": "الصحة العامة"}, {"q": "أداؤك في التمارين؟ في تقدم في الأوزان والأداء؟", "topic": "التمارين"}, {"q": "فرق في شكلك ومظهرك؟ إيجابي أو سلبي؟", "topic": "المظهر"}, {"q": "فرق في الملابس أو المقاسات؟ إيجابي أو سلبي؟", "topic": "الملابس"}, {"q": "النظام الغذائي — قدرت تمشي عليه؟ فيه صعوبة؟", "topic": "الغذاء"}, {"q": "تحسّ بالجوع واجد؟ إن وُجد، كم تعطيه من 5؟", "topic": "الجوع"}, {"q": "أي ملاحظات سلبية تبي تشاركها؟ (مهمة أو بسيطة — نتقبل النقد)", "topic": "ملاحظات سلبية"}, {"q": "أي إشكاليات أو ملاحظات إضافية تحتاج مساعدة فيها؟", "topic": "ملاحظات أخرى"}, {"q": "وصلت لأي أسبوع تدريبي الآن؟", "topic": "الأسبوع"}]}', true, NULL, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('contact', '{"whatsapp": "966599162724", "instagram": "https://www.instagram.com/navvcoaching/"}', true, NULL, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('response_time', '"48 ساعة عمل (الأحد – الخميس، 12 ظهراً – 9 مساءً)"', true, NULL, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('legal', '{"cr": "7050950752", "name": "مؤسسة ناف كوتشنق للتدريب الرياضي"}', true, NULL, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('bank', '{"iban": "SA1280000139608016245411", "bankName": "مصرف الراجحي", "accountName": "مؤسسة ناف كوتشنق للتدريب الرياضي"}', true, NULL, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('program_shots', '[{"h": 368, "w": 1310, "alt": "لقطة من ملف المتدرب: جدول اليوم الأول لتمارين الجزء السفلي مع الجولات والتكرارات وRIR", "src": "shots/training.webp", "title": "جدول التمرين", "caption": "جدول لكل يوم تدريبي: التمرين، الجولات، التكرارات، الوزن، وRIR، وتظهر العضلة الأساسية والثانوية تلقائياً."}, {"h": 473, "w": 1472, "alt": "لقطة من ملف المتدرب: قائمة منسدلة لاختيار التمرين أو البديل مع العضلة الأساسية والثانوية", "src": "shots/exercise-picker.webp", "title": "اختيار التمرين والبدائل", "caption": "تختار التمرين أو بديله من قائمة منسدلة، وتتحدث العضلات المستهدفة مباشرة."}, {"h": 634, "w": 1034, "alt": "لقطة من لوحة التقدم في ملف المتدرب ببيانات مثال: الوزن والقياسات والخطوات الأسبوعية مقابل الهدف", "src": "shots/progress.webp", "title": "لوحة التقدم", "caption": "متوسط الوزن الأسبوعي والقياسات والخطوات مقابل الهدف، ببيانات مثال."}, {"h": 641, "w": 1600, "alt": "لقطة من ورقة المراجعة الأسبوعية في ملف المتدرب: أسئلة المراجعة بدون إجابات", "src": "shots/weekly-review.webp", "title": "المراجعة الأسبوعية", "caption": "أسئلة ثابتة كل أسبوع عن الصحة والتمارين والغذاء والجوع، وبجانبها ملاحظات المدربة."}]', true, NULL, '2026-09-27 13:38:37.68352+00') ON CONFLICT DO NOTHING;
COMMIT;
