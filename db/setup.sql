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

-- ---------- المحتوى المستورد من الموقع الحالي ----------
INSERT INTO public.exercises VALUES ('3fb57426-5cdd-49b7-96ef-40716748869a', 'Back Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/bEv6CCg2BC8', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('96188b17-9e07-4ae8-915b-bbd87e378432', 'Box Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtube.com/shorts/9uhEh9gpwUU?si=xaTY7AJiCeQfa3by', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل.', 'تعليمات بديلة في المصدر (صف 13): ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل، انزل واثبت على البوكس ثانية وارفع.', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8b96473d-316d-4211-87f8-4cd0de078eaa', 'Hack Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/0tn5K9NlCfo', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('24d336c6-c388-4f6d-8f71-dc044dc1dbfe', 'Mid Leg Press', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/s9-zeWzPUmA', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b7f2a3ca-2d62-41da-a81d-5a598ee71c13', 'Quads Leg Press', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/A218isnErfM', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي، ثبت القدمين أسفل اللوح لاستهداف أكبر للكوادز.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('45bf2bbb-b5dc-437a-8856-8854231e9c6d', 'Deficit Goblet Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/9719SO5zvpU?si=whohbunAsXkH3j6f', 'وقف باتساع اكتافك تقريبًا، ادفع ركبك للامام وانزل، انزل لأقصى حد تقدر عليه بدون ما يتقوس ظهرك السفلي.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('75a5dea1-8537-49e8-b834-b90510e69db9', 'Front Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'بار', 'متوسط', 'نادي', NULL, 'ثبت البار على الأكتاف، ادفع ركبك للامام وانزل.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1e970ca7-437e-4c78-bd19-5df2f7cc2177', 'V Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://www.youtube.com/watch?v=u_GSjH58s0g', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('62262ac6-9751-4620-ae71-da86a1f29c56', 'Resistance Band Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/6rE0IYlMPZA?si=goqtRTlR_W4HSGBN', 'ثبت الباند علي جوانب اكتافك، ادفع ركبك للأمام وإنزل.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8abdb58e-452c-49c7-b991-5b08f1ace32c', 'Squat Smith Machine', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/oBwhrRcNWyM', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e4fca552-62be-4e27-8a72-580d1349e344', 'Single Leg Press', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/ZYDTJaAM-gE', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ce34ff36-2831-45d4-bef9-ac8c39dbf119', 'Drop Lunges', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/WH8lteLrMIs?si=61QSVA7iw_Z6Zr3p', 'تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fe84610a-a6f3-4f05-b577-392212e84d5b', 'Beginner Lunges', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/QOVaHwm-Q6U', 'تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f456e66e-4dd4-4a4f-ae13-cac6ce2b30a4', 'DB Lying Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/ZHlBSI6JPsA?si=SpBiHxluwrYE8CTP', 'ركبك ثابته على الارض، ارفع الوزن بثني ومد الركبة بدون ما يرتفع حوضك', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('bb708f0d-334b-44c9-a53e-3bccd5e84a84', 'Forward Lunges', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/_DLAdo2Pvjs', 'تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness | ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('223a7451-aede-44ed-8c48-6f4830c5a5d9', 'Supported BSS', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/poBie3TTeGE?si=QSiMUYtcHhrmg8mx', 'وقف عند البنش او الستيب، ارفع رجلك وثبت اصابع قدمك على البنش، خذ خطوة وحدة للأمام برجلك الثانية ثم ابدأ التمرين، تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2e628064-5dbc-45d6-a58e-8dd7ba6ae1dc', 'Supported Reverse Lunge', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/WH8lteLrMIs?si=M9s9a7qOVvvyDm82', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b2f4c07c-7d5b-4b69-963b-b3a82096c890', 'Smith Machine Reverse Lunge', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/zAVYcwnlxrQ?si=M5HL4sG-bsYBFyDQ', 'استخدم ارتفاع بسيط مثل الستيب ، ارفع نفسك بالضغط علي الرجل المرفوعة بتحكم بدون قفز.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('422fe6d2-a701-4588-aa9f-68b9c00d832f', 'Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/gtZ4AwZVtMI', 'اجلس وثبت ظهرك السفلي كويس، تأكد ان مسمار الارتفاع يكون بمستوى ركبتك، امسك المقابض لزيادة الثبات، إرفع الوزن اثبت ثانية فوق ثم انزل نزول كامل بتحكم.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('12ca3c57-f811-47e4-ba9d-eaf0b97556ab', 'Single Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/82IuSLk5zNc?si=FTMqZrmawQFRr8dN', 'اجلس وثبت ظهرك السفلي كويس، تأكد ان مسمار الارتفاع يكون بمستوى ركبتك، امسك المقابض لزيادة الثبات، إرفع الوزن اثبت ثانية فوق ثم انزل نزول كامل بتحكم.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('15f8d065-2d87-486d-b4b3-ab4b60ae996a', 'Band Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/hs7D3gDw3UM', 'اجلس وثبت ظهرك السفلي كويس وامسك الكرسي للثبات، اثبت ثانية فوق ثم انزل نزول كامل بتحكم.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('bb1f9c36-3d68-434c-b3f2-d79f179c8f60', 'Sissy Squat', 'Quadriceps / الأمامية', '{"Adductors / الأفخاذ الداخلية"}', 'Knee Extension / مد الركبة', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://youtu.be/yONKTprKCDA', 'الورك ثابت طول الجولة والحركة كلها من مفصل الركبة، اذا توازنك يخرب عليك ادبل الوزن بيد واليد الثانية امسك فيها جدار او عصى', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d874649f-98a7-4b6c-aae7-0360df709b7a', 'Cable Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/ebjD98gZd8E', 'اجلس وثبت ظهرك السفلي كويس وامسك الكرسي للثبات، اثبت ثانية فوق ثم انزل نزول كامل بتحكم.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cd4b9b10-4303-4133-affa-7bea0a640c5f', 'Standing Leg Extension', 'Quadriceps / الأمامية', '{"Core / البطن والكور"}', 'Knee Extension / مد الركبة', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/133/standing-leg-extension/', NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('87952861-3183-42cd-a845-e3c65d0fa22d', 'Bodyweight Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Lower back / أسفل الظهر"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/135/bodyweight-squat/', NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('048ac230-6c6b-4a71-8f41-b2515c1f390b', 'Single Leg Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'وزن الجسم', 'متقدم', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/136/single-leg-squat/', 'ضعف الألوية الكبرى / Gluteus Maximus Weakness | ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3312b8e8-efd4-4780-ae5f-178b9001f6ef', 'DB Glutes Step Ups', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/GCnJiYJfboA?feature=share', 'استخدم ارتفاع يكون بحدود ارتفاع ركبتك أو أقل، ارفع نفسك بالضغط علي الرجل المرفوعة بتحكم بدون قفز.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2b08f365-19f4-4c8a-9c11-f5b16845e9bf', 'Standing Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/fyF6FQOUGDI', 'الحركة كلها بثني ومد الركبة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('47c8002b-ba74-4444-adf3-5163d4b0a7b5', 'Supported Glutes Step Ups', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/ZKzoOkQALaY?si=-56txwBlxSSCQYJd', 'استخدم ارتفاع يكون بحدود ارتفاع ركبتك أو أقل، ارفع نفسك بالضغط علي الرجل المرفوعة بتحكم بدون قفز.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1ac49e41-b7ff-40f3-8df0-e5715c7bb26f', 'Cable Glutes Step Ups', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7de0ca13-cd12-4f78-ad53-00970d28737c', 'Glute Pushdown', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/8h2kZ64Sp5k?si=NLPf4tywxhDGY9em', 'تمسك بمقابض الجهاز، (كل ما زاد ارتفاع البنش زادت الصعوبة) + الطلوع والنزول يكون بواسطة القدم المرفوعة على البنش مو بالقدم اللي تحت، ارفع بتحكم الى أقصى ارتفاع تقدرعليه بدون ما يتقوس ظهرك السفلي، انزل لحد ما تقفل ركبتك تماما', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('47f45dec-b3d8-4447-8c54-89ed8f40cc99', 'Glute Max Kickbacks', 'Glutes / المؤخرة', '{}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/t5mwSx4uNMc?feature=share', 'ثبت الحبل على الكاحل، ارجع خطوة للخلف وانحني للامام قليلاً وتمسك بالكيبل لزيادة الثبات، اسحب للخلف مع انثناء بسيط بالركب.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('da164b65-e4f2-4abb-8611-65b78f099561', 'Hip Abduction', 'Abductors / مبعدات الفخذ', '{"Glutes / المؤخرة"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/_ARUxqrII3Y?si=Jcz5uh2Uu-IdVCS1', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c64b4897-76db-4bb0-85b4-4a8f33faa50d', 'Smith Machine Kickback', 'Glutes / المؤخرة', '{}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/GR4ny80bmhM?si=WeZcWM1hyfoLElM2', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('dc7de871-73bb-45da-86f9-b18e7e3d4089', 'Glute Medius Kickbacks', 'Abductors / مبعدات الفخذ', '{"Glutes / المؤخرة"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/kccsnZNbMFA?si=6c-VoB8Zsz8NxoyM', 'ثبت الحبل على الكاحل، ارجع خطوة للخلف وانحني للامام قليلاً وتمسك بالكيبل لزيادة الثبات، اسحب للخلف وللخارج مع انثناء بسيط بالركب.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2d86e837-a80a-4a54-a5f6-bfa02a0f9699', 'Side Step Up', 'Glutes / المؤخرة', '{"Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/xOwIRnI4VxA?si=SJOgODRmNGdfHPb4', 'يد فيها الوزن واليد الثانية سندها على الجدار', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية المتوسطة / Gluteus Medius Weakness | ضعف الألوية الصغرى / Gluteus Minimus Weakness', 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('055e82f0-1e3d-41ec-a054-e3daae413566', 'Hip Thrusts Machine', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/0xfdeCBwoYw?si=HgJcNeB0a24gODkK', 'ممكن تسويه بالسميث مشين او البار الحر ، اختر بوكس او بنش يكون بمستوى اكتافك الخلفية وانت جالس، لما ترفع البار فوق المفروض ركبك تكون بنفس مستوى القدم.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b15ee4cd-6c9f-4c80-994c-30305114ab70', 'Hip Thrusts', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/O0EoaP7gR1A?si=cGPZ8iIwM2mQjwSb', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4060b2ba-e6d5-4363-8746-b994a8b1f625', 'Glute Bridge', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', NULL, 'مبتدئ', NULL, 'https://www.youtube.com/watch?v=dtlGynVdHYM', 'ممكن تسويه بالسميث مشين او البار الحر ، اختر بوكس او بنش يكون بمستوى اكتافك الخلفية وانت جالس، لما ترفع البار فوق المفروض ركبك تكون بنفس مستوى القدم.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness | آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('15e52aae-a1a6-430a-80f8-a5a520da14e3', 'DB Floor Glute Bridge', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/iOrJXNUH3to?si=JySX6JMhoP2vWEVa', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness', 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2bff1fb2-e127-49fa-a0ad-fb5a29394961', 'Glute Raise', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/X_kL_x4m77c', 'ثبت رجولك تحت، الاسفنجة تكون تحت الورك أعلى الفخذ مو على الورك مباشرة، امسك وزن بيدينك بذراع مستقيمة، ارفع وكأنك تبي تدخل القلوتس جوا الاسفنجة، بمجرد ما تنقبض مؤخرتك وقف لا ترفع أكثر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a24837a1-fd7d-4df5-90e7-ea3f3d5b840f', 'Single Hip Thrusts', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/ymg2AMDAwrY?si=fY8kBPTDYWRMHuAs', 'اختر بوكس او بنش يكون بمستوى اكتافك الخلفية وانت جالس، لما ترفع فوق المفروض ركبك تكون بنفس مستوى القدم، التمرين صعب طبيعي تواجه صعوبة بالبداية لذلك لا تستعجل باضافة الاوزان', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c246062b-3cde-4d00-b217-11105e479617', 'Glute Press', 'Glutes / المؤخرة', '{}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/293/glute-press/', NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d3252a57-b954-4eee-8e41-2c4d5345d21c', 'Bulgarian Split Squat', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/366/bulgarian-split-squat/', NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e1455aa3-5f15-4b59-b1d0-715d099308b3', 'Sumo Deadlift', 'Hamstrings / الخلفية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://www.youtube.com/watch?v=cDlOSfu-zHY', 'وقف بفتحة أرجل واسعة بحيث الركب تكون خط مستقيم مع كعب القدم و اصابع الرجل باتجاه الخارج، البار بمنتصف القدم، شد ظهرك العلوي وادفع الارض برجولك واسحب البار للأعلى، وقف لما تنقبض مؤخرتك ولا تبالغ بتقفيل حوضك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('18181561-f3f4-48c4-975a-9a62c0cb24bc', 'Conventional Deadlift', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/GxsLrTzyGUU', 'وقف باتساع اكتافك أو أوسع شوي، البار بمنتصف القدم، شد ظهرك العلوي وادفع الارض برجولك واسحب البار للأعلى، وقف لما تنقبض مؤخرتك ولا تبالغ بتقفيل حوضك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3f3b97cd-3bc6-462f-a99f-369042c398e6', 'BB RDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/mZxxJEncsyw', 'وقف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، انزل وادفع مؤخرتك لآخر شي تقدر عليه للخلف وكأنك بتلمس جدار خلفك مع انثناء بسيط بالركب', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('bba5deb1-6337-472d-9a64-f247f7c5f44c', 'DB RDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/RApyTtH6qAo', 'وقف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، انزل وادفع مؤخرتك لآخر شي تقدر عليه للخلف وكأنك بتلمس جدار خلفك مع انثناء بسيط بالركب', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('766c1dec-37af-4274-8436-90a38de86343', 'SM SLDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/qlL1wnpLQj4?si=-jD_X6mIJkkI8SwX', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a8a0811b-6013-487f-b6cb-5351fc97000c', 'Single DB RDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/U3prDlAbJDw?si=MRSBcSIcf9M-WQBH', 'وقف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، انزل وادفع مؤخرتك لآخر شي تقدر عليه للخلف وكأنك بتلمس جدار خلفك مع انثناء بسيط بالركب', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness', 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('64b23c52-b3dc-475d-a5d3-cba02666b22b', 'SLDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/RApyTtH6qAo', 'قف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، ابدأ الحركة بدفع مؤخرتك للخلف والأعلى وانزل', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('69949b56-d024-4cef-9b63-d62161a5f515', 'Single DB SLDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/U3prDlAbJDw?si=MRSBcSIcf9M-WQBH', 'قف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، ابدأ الحركة بدفع مؤخرتك للخلف والأعلى وانزل', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0f12a9fb-456a-4b8f-a7db-192fdc66bb62', 'Good Morning', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/f23vXjoG2e8?si=9rkfUF_6XUEcQ3Xs', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع مؤخرتك لأقصى قدر تقدر عليه وكأنك بتلمس جدار خلفك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('96e40aba-1dbd-4532-b88e-e39b25f564d5', 'Seated Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/o_J6MWyt5jM', 'اجلس على الكرسي وثبت ظهرك السفلي على المقعد تمامًا، انزل لأقصى حد تقدر عليه وارفع لحد ما تستقيم ركبتك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e5e82cf4-400d-4fdc-98a7-385470c7a716', 'Band Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/I-HTMUrJnxs', 'ثبت الباند فوق الكعب، اجلس على طرف البنش وتمسك بيدينك لزيادة الثبات، اسحب الحبل لاقصى حد تقدر عليه واترك رجلك تستقيم تمامًا في الانبساط.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('67146b07-25e1-496b-9edb-5146cf0a71f3', 'Lying Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/vl5nUdE9mWM', 'حوضك ثابت على البنش، ارفع الوزن بثني ومد الركبة بدون ما يرتفع حوضك عن الكرسي', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('62fe58db-a728-4a3b-b954-297733392ecb', 'Smith Machine Incline Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/EeLLZMdg6zI?si=UVsgFN7jhXMm0vW3', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('87cff249-29cc-4f7e-9acb-2756d97a9e15', 'Cable Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/mBJXWg8ZOy0', 'اجلس على الكرسي وثبت ظهرك السفلي على المقعد تمامًا، ممكن تقدّم ظهرك العلوي وتمسك المقابض لزيادة الثبات، انزل لأقصى حد تقدر عليه وارفع لحد ما تستقيم ركبتك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0bc10599-b82e-40df-a005-2a27a2f85058', 'Supine Cable Hamstring Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/sDCc1F5J8XA?si=Fi3D39aJogrB5ihd', 'الركبة ثبت مكانها، اسحب الحبل لاقصى حد تقدر عليه واترك رجلك تستقيم تمامًا في الانبساط.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('43512a2f-bcbf-4404-94b4-8c3f93940bab', 'Nordic Hamstring Curl', 'Hamstrings / الخلفية', '{}', 'Knee Flexion / ثني الركبة', 'قوة', 'وزن الجسم', 'متقدم', 'بدون معدات', 'https://youtu.be/Lgibr8od0yA?si=nfRetEkDRk55Bu0a', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b6229983-1163-4120-9f60-7552694a9def', 'Stability Ball Hamstring Curl', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة"}', 'Knee Flexion / ثني الركبة', 'قوة', 'كرة سويسرية', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/59/stability-ball-hamstring-curl/', NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9ad7f1b4-dc4f-437a-923d-6552ec0ecdb8', 'Hip Hinge', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/33/hip-hinge/', NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2ce52aa6-2a6f-4038-845c-eccdd7bb0fa5', 'TRX Hamstrings Curl', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة"}', 'Knee Flexion / ثني الركبة', 'قوة', 'TRX', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/86/trx-reg-hamstrings-curl/', NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d95499ed-f35b-4a0d-9ebc-5999c26c11c6', 'Flat DB Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/xphvjGDZeYE', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0e5f073b-b4bc-464d-b211-e708a1d9648c', 'DB Floor Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/UBmpZ7l5Nlk?si=kDcN-ueaTFxfKtbr', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9d0386c5-faa6-4b3c-a306-911d5526153b', 'Flat Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/vcBig73ojpE', 'استلق على بنش،القبضة بنفس مستوى الاكتاف أو أوسع قليلًا، قوّس ظهرك العلوي قليلاً، انزل لين تلمس صدرك واثبت ثانية ثم ارفع.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3850a330-4de1-45cc-846e-4d02cd2a6079', 'Machine Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/pOCRC2kpxB8?si=02xGtrfPjiYpspMv', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('dd5e9468-4d79-4c93-9c16-a88f18b41fd0', 'Feet Up Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/HrehfM1dmBE', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ecb41983-9d73-4dcf-8f1e-92bd0c858042', 'Torso Elevated Push Up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/noaPB7u4_CU', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا', 'تصنيف فرعي: اليدان مرفوعتان؛ زاوية الضغط بالنسبة للجذع تشبه الضغط المائل لأسفل رغم تسميته الشائعة Incline Push-up — يحدده المدرب', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('19f8bb69-c60d-4199-96e6-6fc224b9862b', 'Push Up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://youtu.be/WDIpL0pjun0?si=utydS_A8QfRIJtJm', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('51371706-8c26-4a85-ab90-f94bd865634d', 'Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://www.youtube.com/watch?v=JvOJdUtx6UQ', 'استلق على بنش،القبضة بنفس مستوى الاكتاف أو أوسع قليلًا، قوّس ظهرك العلوي قليلاً، انزل لين تلمس صدرك واثبت ثانية ثم ارفع.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c51936cb-a913-4c78-b5b8-fcdafb423580', 'Paused Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://www.youtube.com/shorts/Q3GmnmJISwE', 'استلق على بنش،القبضة بنفس مستوى الاكتاف أو أوسع قليلًا، قوّس ظهرك العلوي قليلاً، انزل لين تلمس صدرك واثبت 3 ثواني ثم ارفع.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8c548a44-f772-433d-937e-b0e6276f8faf', 'Incline Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/0G2_XV7slIg', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d86b5af2-b2bf-4ffc-a507-363b95fe364a', 'Cable Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/tAILewhtCb0', 'اجلس على بنش انكلاين، اضبط الكيبل بمستوى صدرك تقريبا، ادفع الوزن للأمام باتجاه الداخل، احرص ان كوعك ما يكون بنفس ارتفاع كتفك', 'تصنيف فرعي: التعليمات تذكر بنش انكلاين، وتصنيف المصدر iso_push_chest — يُحسم بين Incline Press وعزل الصدر', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6af5f3ff-e735-4682-b02c-712a57840695', 'Sternal Cable Press Around', 'Chest / الصدر', '{}', 'Horizontal Push / دفع أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/y8XQibXDnNo', 'اضبط الكيبل بمستوى صدرك تقريبا، حافظ على ذراعك قريبة من جسمك،ادفع الحبل للأمام باتجاه الداخل.', 'تصنيف فرعي: حركة مختلطة بين الضغط والـ Fly — يُحسم بين Flat Press وعزل الصدر', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('928027c3-5ab0-49dc-9da7-331acd888ea7', 'Machine Chest Fly', 'Chest / الصدر', '{}', 'Horizontal Adduction (Fly) / تقريب أفقي للكتف (فلاي)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e1a83a54-088d-474a-8213-577afb26e52d', 'Bar Cable Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/NhD3h6RG2TA?si=SoyNTIGB-nY2KiXl', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('70dbf46c-ffd0-44c4-9a4c-8789c6a92a18', 'Cable Chest Fly', 'Chest / الصدر', '{"Shoulders / الأكتاف"}', 'Horizontal Adduction (Fly) / تقريب أفقي للكتف (فلاي)', 'قوة', 'كيبل', 'مبتدئ', 'نادي', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/160/standing-chest-fly/', NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0d713ac4-c294-4d89-86a3-7156f826f61d', 'Bent Knee Push-up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/13/bent-knee-push-up/', NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d04808ee-0ed5-4fda-a6fc-af49e3e909e8', 'Stability Ball Push-Up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس","Core / البطن والكور"}', 'Horizontal Push / دفع أفقي', 'قوة', 'كرة سويسرية', 'متوسط', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف فرعي: الزاوية تعتمد على موضع الكرة (تحت اليدين أو القدمين) — غير محدد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/63/stability-ball-push-up/', NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6dcd222a-15c8-4e52-ad9e-f6118e0744c2', 'Cable Reardelt Rows', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/uIdXVGjcfFE', 'ثبت نفسك بالكرسي، فتحة واسعة، الكيبل بمستوى اسفل صدرك، واسحب لما تنقبض اكتافك الخلفية.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ccc20310-504e-4cf2-83b4-36fe1233bfad', 'Upper Back Horizontal Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/TSWohpfMlso', 'ثبت نفسك بالكرسي، فتحة واسعة، الكيبل بمستوى أعلى صدرك، واسحب لما تنقبض الترابز.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness', 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('456ce182-d6ef-4643-b3bf-2aef3085ba44', 'DB Chest Supported Reardelt Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/x0v6GWYzI18?si=-jDt3D-ARIHouHjp', 'ثبت صدرك على الكرسي، فتحة واسعة، واسحب لما تنقبض اكتافك الخلفية.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6bf87f2b-1511-4233-8f46-b8df00093551', 'Bent-over Barbell Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'بار', 'متوسط', 'نادي', NULL, 'ادفع مؤخرتك للخلف واثني ركبك، قبضتك بنفس مستوى اكتافك، اسحب لما تنقبض عضلات الظهر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('223fc80a-61ac-4eee-9352-20440662adae', 'Cable Reardelt Fly', 'Shoulders / الأكتاف', '{"Rotator cuffs / الكفة المدورة"}', 'Shoulder Rear Pull / سحب خلفي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/bkejPHrPkmA?si=-O8q_5e72udoPRiY', NULL, 'تصنيف فرعي: حركة Fly (تبعيد أفقي للكتف) وليست سحباً أفقياً أو عمودياً', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2da858b9-250a-4b37-a5a7-b45a8f38d313', 'DB Chest Supported Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/H75im9fAUMc', 'ثبت صدرك على الكرسي، فتحة واسعة، واسحب الدمبل باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('33318523-7f14-425e-99c9-28e305018a8e', 'Head Supported Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/c6lkPMhuyFA?si=eUivRGYSi0W7PmVe', 'راسك ثابت على البنش بدون أي ميلان بالرقبة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1c60aa43-0028-4f23-85e5-b9c651b9935f', 'Single Arm Dumbbell Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/QBjaGx8mS1o', 'اسحب باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b7bc7c71-1822-4473-ae18-ee167993d683', 'Single Arm Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/Qn_mHGObb8E?si=IZ0q9_tseiRIMtcs', 'اسحب باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c6c39e07-ea81-476b-80b6-da1d2a6b4496', 'Seated Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/0G3W83dFUeY', 'اسحب باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness | تحدب الظهر / Postural Thoracic Kyphosis', 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e5779ed4-1c1d-4c73-8cd2-a14eb3f85b5a', 'Band Seated Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/Jy-WCFAofBY?si=9gqVby588rk1zFi9', 'فتحة واسعة، واسحب لما تنقبض عضلات الظهر.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness | تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture', 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('50d565f4-6eff-463e-9fd6-261ed244295c', 'Chest Supported Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/DgHtyrQEMJ4?si=oTfTKVgD9j1H12wA', 'ثبت صدرك على الكرسي، فتحة واسعة، واسحب لما تنقبض عضلات الظهر.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness', 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d64b40e5-ac5f-405f-98dc-63c19273310d', 'Chest Supported Machine Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/BZrdEAiR2Xs?si=WhKaSGhR0gKeeies', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('63e124d1-f58d-4bc4-9250-ed24782a7229', 'T-Bar Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/6OtcNinT0HM?si=UPfYyypfZCaN9tTA', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4b562d5c-07a0-46ab-964d-b63f21946845', 'Lats Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/CQkT-W18N5g', 'الكيبل بنفس مستوى بطنك، اسحب باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0e8cd1a3-18d7-4738-91df-40a7142882cd', 'Upperback Pulldowns', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/bNmvKpJSWKM?si=hy5HgBDAHkzFHcvv', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c18c7bab-c1ac-4be4-b6bd-15627bed54bd', 'Straight Arm Pulldown', 'Back & Lats / الظهر واللاتس', '{}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/hAMcfubonDc?si=ocU_a8VQ4VzZnTg3', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a0382781-165b-4281-a511-34bf0260bc25', 'DB Pullover', 'Back & Lats / الظهر واللاتس', '{"Chest / الصدر","Triceps / الترايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/ieFKuQAGYIA?si=uwqyrbKhBL6Id3_-', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a2a57441-334a-4bf5-8ea4-be0c94fecc52', 'Band Lat Pulldown', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/5R0RYj3Y9Ro', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c225888d-5bb7-43db-9a49-d125ee1509f3', 'Band Assisted Pull Ups', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://youtu.be/Ks8ah-8P1b0', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('671295c8-fb09-4fe0-8d05-8e86d3deab3b', 'Pull Ups', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متقدم', 'نادي', 'https://youtu.be/x3NPAxiMRPw?si=Mwg6U1Df5aIFpjKB', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d5d107d0-eb45-4612-9890-5a03bca40518', 'Negative Pull-Up', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://youtu.be/gbPURTSxQLY?si=TvQF5zDWfU_rR1Ax', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر، نزول بطيء.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d9210945-0354-4cf9-9e1b-56c3f3287c97', 'Neutral Grip Lat Pulldown', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/kVB6SlEyjQM', 'القبضة بنفس مستوى الكتف، اسحب باتجاه اعلى الصدر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b4a6e601-23d5-44cb-99bb-a8881a9d6259', 'Single Lats Pulldown', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/Qed5O9toqT8', 'اجلس على بنش واسند صدرك عليه، ارجع للخلف قليلا بحيث ان الكيبل ما يكون فوق راسك مباشرة، اسحب الكوع باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('864d3b50-edf3-4efb-b2b9-60c65cb9e1a8', 'Band Assisted Chin Ups', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://youtu.be/i0yC-0YK6Uk?si=gNX26kIFz_THnR4p', 'مسكة ضيقة بمستوى الأكتاف، كل ما كان الحبل خفيف زادت المقاومة وزدات صعوبة التمرين لذلك ابدأ بحبل ثقيل وخفف كل ما تحسن مستواك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('21040500-b163-4372-87df-cd65a8ed6b27', 'Chin Ups', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متقدم', 'نادي', 'https://youtube.com/shorts/aV9Mz9nCsMw?si=E_ullJojGO_7srW2', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7e75f438-b7e3-4e68-bb62-9595b4f87ea4', 'Biceps Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/09AYfVFf7pg?si=dcwLVAYqIbDLM6jd', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('45b7f847-405f-4264-b702-126b71fbf1d2', 'Kneeling Lat Pulldown', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', NULL, 'متوسط', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/35/kneeling-lat-pulldown/', NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('485566e2-e133-458f-ad0c-2b3b738cfff1', 'TRX Back Row', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس","Core / البطن والكور","Lower back / أسفل الظهر"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'TRX', 'متوسط', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/84/trx-reg-back-row/', NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('29d1fc30-5a7d-4a69-952c-4b2fead804a5', 'Shrug', 'Back & Lats / الظهر واللاتس', '{"Trapezius / الترابيس"}', 'Scapular Elevation / رفع لوح الكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف فرعي: رفع الأكتاف (Shrug) ليس نمط سحب أفقي أو عمودي', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/72/shrug/', NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('bc61274e-ed7f-4888-b7d3-0667a41c6ab6', 'DB Shoulder Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/NKeyUrDYqPk', 'قوّس ظهرك العلوي قليلاً، الكوع قريب من الجسم، النزول الى مستوى الاكتاف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4012e0b9-9945-4e41-aa67-6f5d0e5d6b35', 'DB Standing Shoulder Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/wO0l5jW2NtQ?si=MVvS4F_7iFS8ji9R', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('98b807df-a89d-4ed8-b9e1-b25ce929bc68', 'Machine Shoulder Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/3R14MnZbcpw', 'قوّس ظهرك العلوي قليلاً، الكوع قريب من الجسم، النزول الى مستوى الاكتاف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6046819d-8eba-4c1b-a778-86945d702a67', 'BB Overhead Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/_RlRDWO2jfg', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ba0a0824-b012-48a1-a69a-39964b81d0c0', 'DB Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/qqntiuPmLDM?feature=share', 'انحني للأمام قليلًا، ارفع للأعلى الى أن تصل لمستوى الأكتاف.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('62049dfb-83e0-47b4-a791-a04a010fc934', 'Seated Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/v7fwGurZ9SU?feature=share', 'انحني للأمام قليلًا، ارفع للأعلى الى أن تصل لمستوى الأكتاف.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('db2f10a3-437a-480f-abf8-1eb48a1014f3', 'Lateral Raise Machine', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/d0pRsZ9SY5w?si=XuXb_Ti0Flow7qvW', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4dc86e8a-ea32-4b8b-ac90-583f73a4724f', 'Cable Crossover Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/wKgCc5UQjoU?si=zsaz3i31PnEU9A43', 'الكيبل يبدأ من الأسفل، انحني للأمام قليلًا، ارفع للأعلى وتحكم بالنزول.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('64e30faf-54bb-43f4-93d2-dd63c38edf9d', 'DB Y Raises', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/lXp16YozXgk', 'ثبت صدرك على البنش،ارفع الوزن على شكل Y.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0c34bad4-6d0f-43ac-b06f-2cf6b3f11f37', 'Cable Y Raises', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/P7u6PEeOn6Q?feature=share', 'الكيبل يبدأ من تحت،ارفع الوزن على شكل Y.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('835f3c25-0dec-4df3-98b8-209ca4f6a0e6', 'Single Arm DB Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/Jm6GqVhWhNY', 'انحني للأمام قليلًا، ارفع للأعلى الى أن تصل لمستوى الأكتاف.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cba4b6cd-b157-4dba-8cfe-30413f85df28', 'Single Arm Cable Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/J-6uEOkYAKM', 'الكيبل يبدأ من الأسفل، انحني للأمام قليلًا، ارفع للأعلى وتحكم بالنزول.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('41edc4c4-de3e-486e-832f-f55b167bd343', 'Front Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Front Raise / رفع أمامي للكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/54/front-raise/', NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d9eb5102-51e3-4582-b72b-2ff5c9d45db6', 'Diagonal Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/371/diagonal-raise/', NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('94a9deee-9435-4667-b094-cbbf6980f288', 'High Row', 'Shoulders / الأكتاف', '{}', 'Shoulder Rear Pull / سحب خلفي للكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/336/high-row/', NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('997a2f6b-93ff-4676-91c7-3c4423f6ff11', 'Cable Rope Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/xNXUTJ6TBZA?si=-r-Ql97awoVZla_1', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('aa08f6c7-7555-456a-bfc0-0a8ef71d7b99', 'Cable Facing Away Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/fV9BpknCjGM', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7a37758c-5aa3-4683-8bd1-0524740a393d', 'DB Incline Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/js_StxxyxBM', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('89447648-d923-446b-8037-02dbb64da76b', 'Cable Facing In Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/5z4y7QRTx1w', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4621b5c6-eeb2-4049-a6a1-e5256380f9e5', 'Single Arm Cable Facing Away Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/6sO-pK7pTPs?feature=share', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('baa701ee-e22f-4855-861f-c83f0a0cd87e', 'Single Arm Cable Facing In Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/I-197ZW9Ffo?si=M1Yq4R1PIpdZMXRx', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('99703a9e-fae4-4ea3-97bb-ebc27188c323', 'DB Preacher', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/DZJNTb-zzn0?si=SwbdZ0O_0eTOET-5', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('226cda52-ac67-42b6-ba68-eceb3eeb5dbb', 'Preacher Curl Machine', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/TouYMA3-ua4?feature=share', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('edd16988-a266-427e-a638-f18f755320e4', 'DB Spider Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/cTMjzB2_IH8?si=qsIKEEFVfEvPXwqf', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e6ed5d60-7576-4447-a979-440fbf835de3', 'Zottman Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://www.youtube.com/watch?v=ZXbOOIOPOi8', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('46a8f7ff-8155-42df-8d69-ec338320df73', 'Hammer Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/10/hammer-curl/', NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c9f5f48d-584f-4415-98c4-dfb8a01c2eb4', 'TRX Biceps Curl', 'Biceps / البايسبس', '{"Forearms / الساعد","Core / البطن والكور"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'TRX', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/78/trx-reg-biceps-curl/', NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3ef04288-5165-4210-82d9-93a103056dc3', 'DB Triceps Extensions', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/d7SXlU5HkYM?si=WuuPa9-yeByaP5sI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5dc93b1f-2ad9-42ed-9799-3db68751d634', 'DB Floor Triceps Extensions', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/dpFav9Ve4rY?si=ZBdKK8VF4aPMpi3v', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('56155486-dca5-49b4-99ea-4e6f7b208599', 'Cable Crossbody Extensions', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://www.youtube.com/watch?v=jtLTcED38Dg', 'الكيبل يبدأ بالمنتصف زي الفيديو، بحيث لما تسحب الكيبل يكون بنفس مستوى الترابس، الأكواع والأكتاف ثابتين مكانهم والحركة كلها بثني وفرد الكوع.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7ab458a9-0c25-465e-becf-8f353c485a4f', 'Triceps Pushdown', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/QsoN4u6j8nM?feature=share', 'انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('29a837c0-d73c-4a2b-b956-7b8773d622a3', 'Cable Crossover Pressdowns', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/Y3CDzx-oj3k', 'الكيبل يبدأ من الأعلى،انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a0b9049b-f014-4883-8740-c16b237e5a11', 'Band Triceps Pushdown', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/mYs1rEYtZK4?si=k8vdZxNNEB5wj2CA', 'الكيبل يبدأ من الأعلى،انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0d4952fe-05fa-494e-a169-cb4bc0fc7dad', 'Single Cable Triceps Pressdowns', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/8rl4ioij6lc', 'الكيبل يبدأ من الأعلى،انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ca22273b-2a14-4434-9d4a-5dd70ec6f410', 'Cable Overhead Extension', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://www.youtube.com/shorts/Q3bO1Fh4734', 'اترك الحبل يسحب معصمك وكوعك ثابت لما تستطيل التراي ثم ارفع الوزن لما تستقيم اليد، كوعك ثابت طول الوقت والحركة ثني ومد من مفصل الكوع، ممكن تطبق كل يد لحالها اذا كان اسهل لك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b821e709-245b-4f2c-ad79-5daec769ee19', 'Triceps Dips', 'Triceps / الترايسبس', '{"Chest / الصدر","Shoulders / الأكتاف"}', 'Vertical Push / دفع عمودي', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/SpSE_A5L-YA?si=bSAzRM9SBuX-3mE0', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7c28cacf-b85e-4490-b453-979b51c53294', 'Triceps Kickback', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/YebyKE3Ts8o?si=H_h9z5BXutFBbFhq', NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/55/triceps-kickback/', NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7f386970-2aa4-456e-845d-2d25be49159c', 'Plank', 'Core / البطن والكور', '{"Shoulders / الأكتاف","Glutes / المؤخرة"}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/pvIjsG5Svck?si=cTP8ZyfMAJPfaEhw', 'لما ترتفع الاكتاف تكون فوق الكوع والرجل ممتدة بالكامل.', NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d36a1af4-2d85-44b0-b8da-42555141dd2d', 'deadbug', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/g_BYB0R-4Ws?si=D4nwJri73eBqJRqL', NULL, 'اسم مشابه موجود في المكتبة (deadbug / dead bug) — تُراجَع قبل الحذف أو الدمج', 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'rejected', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cf1087b9-1d3a-4741-afeb-5aa11462597b', 'Band Dead Bug', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'مطاط', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/iW_CtYtzbeU?si=Epequw3rqA3_TwTr', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('229bd8b2-ae80-4db5-8240-4ec98e137eab', 'Side Plank', 'Core / البطن والكور', '{"Abductors / مبعدات الفخذ","Shoulders / الأكتاف"}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'لما ترتفع الاكتاف تكون فوق الكوع والرجل ممتدة بالكامل.', NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain | ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2e9b96dd-b7dd-458d-a929-4de08f6f044c', 'McGill Big 3', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/jZylx81_kfg?si=_jP064GZIzvEvzyN', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9ad38921-949b-4350-852f-f7c5e5f1d127', 'Suitcase Carry', 'Core / البطن والكور', '{"Forearms / الساعد"}', 'Loaded Carry / حمل ومشي', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/BaRMAhD7SP4?si=KkiMH8OSIEz_TB53', NULL, 'نفس التمرين ورد أيضاً تحت التصنيف «Functional Training» (صف المصدر 160) || رابط آخر في المصدر (صف 160): https://youtu.be/BaRMAhD7SP4?si=dCR2n2VSPaHhxfL3', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4b96ee70-0e44-48cd-bff9-a7b806fd852e', 'Single Leg Raise', 'Core / البطن والكور', '{"Glutes / المؤخرة","Hamstrings / الخلفية"}', NULL, NULL, 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/ZJodU5OOaiA?si=p6ZD9dpzyRKBUn16', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e86b48a6-c521-436b-ab5c-25cb92baaf72', 'Cable Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/ToJeyhydUxU?si=Z5dv34foxX4VtRH6', 'الحركة عبارة عن ثني للعمود الفقري وكأنك تقرب صدرك لوركك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7873b699-ab2f-4145-bfea-83c853d62a94', 'Leg Raises', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/UqmbxvOgnX4?si=U3pDG4Jf0x1mtC_7', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f0cf9f3b-e1bf-4f75-af12-43776349e460', 'Bosu Ball Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'أخرى', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/KjvDgHPxXcg?si=zad59CHC6Y-calzi', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('79586d2b-c8ea-471e-be5d-b489c8d04114', 'Bent Knee V-Up', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/sbyFIM30_G8?si=dED0NQSRS44dz5G9', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('527b06f0-1d67-4604-aeec-88ee206ef0b7', 'Reverse Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/esYVzdEfs04?si=N44MZZHlVeSQc1S3', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c19138fc-5b23-4560-a4d5-a2aaca20a81d', 'Belly Breathing', 'Core / البطن والكور', '{}', 'Core Activation & Breathing / تفعيل الجذع والتنفس', 'إحماء/تفعيل', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/Shk8cmgv0Ew?si=mXkcj9PH6eH_tLcd', 'نفس عميق من الانف ننفخ فيه البطن ثم نطلعه من الفم ببطئ مع ضغط البطن للداخل اثناء اخراج النفس', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('40d5eddb-e47b-41e9-960e-612a4d2326d1', 'Dead Bug', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/_zkkMOtXuOQ?si=GIkLuCUJvdaOk5FP', 'نحرك الرجلين ببطئ قليلا و بتحكم باستخدام عضلات البطن', 'اسم مشابه موجود في المكتبة (deadbug / dead bug) — تُراجَع قبل الحذف أو الدمج', 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7be5cfd2-0af2-47d5-b1cc-8b4a798d46c6', 'Reverse Tabletop Bridge', 'Core / البطن والكور', '{"Glutes / المؤخرة"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://youtu.be/d1yE9cGtPWo?si=2aoNqmUAN054rP75', 'اخذ نفس اثناء الطلوع، اثبت ثواني فوق واشد عضلات بطني، اطلع النفس اثناء النزول', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9ada068a-d416-44f1-9a68-c3e3fd3affd7', 'Bird Dog', 'Core / البطن والكور', '{"Lower back / أسفل الظهر","Glutes / المؤخرة"}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/L91QMACdA6Q?si=KBnuQDcm9WcUXxxI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('35408dab-342b-48b7-bae6-cbbf186d8b74', 'Pelvic Tilting', 'Core / البطن والكور', '{}', 'Core Activation & Breathing / تفعيل الجذع والتنفس', 'إحماء/تفعيل', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/DqqUIfMuDX4?si=uzl0SRl_M9guUT3j', 'الحركة من الحوض، اخذ نفس وادف حوضي للاعلى قليلا، اطلع النفس اثناء نزول الحوض والصق اسفل ظهري بالارض', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5908b363-8a7d-4b1a-b69f-935809a89e3d', 'Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/52/crunch/', NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f7bd70d9-d277-4cc8-88d9-31d50bb99a24', 'Standing Wood Chop', 'Core / البطن والكور', '{}', 'Trunk Rotation / دوران الجذع', 'كور', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/108/standing-wood-chop/', NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('487d6685-e0a6-4c42-bdc4-741d005972cb', 'Russian Twist', 'Core / البطن والكور', '{"Lower back / أسفل الظهر"}', 'Trunk Rotation / دوران الجذع', 'كور', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/65/russian-twist/', NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9f39c082-6323-4809-8fd4-352ed87c5823', 'Cable Twisted', 'Core / البطن والكور', '{"Lower back / أسفل الظهر"}', 'Trunk Rotation / دوران الجذع', 'كور', 'كيبل', 'مبتدئ', 'نادي', NULL, NULL, NULL, 'إضافة المدربة', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('56044ca9-2767-4217-9495-de5527a66d38', 'Calves On Leg Press', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/XdtWVYFVhGU', 'ثبت أصابعك أو مقدمة رجلك على الجهاز، لا تبالغ بالوزن، انزل بكعبك لين تمتد بطاتك بشكل كامل ثم ادفع.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e35eb7c5-9557-4596-bb31-eaaf116a2dc3', 'Calves Raise', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/H6WptvjXkgw', 'حط تحت اقدامك بليتس أو أي شي يرفعك عن الأرض، انزل من اصابعك اقصى نزول ثم ادفع للأعلى', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6b6dc61a-2d5b-4762-8031-d60c304682ad', 'Calf Raise (Machine)', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', 'جهاز', 'مبتدئ', 'نادي', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/294/calf-raise/', NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('dd137c78-7e75-4862-89ff-ea396b7c8c71', 'Calf Raises (Barbell)', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', 'بار', 'مبتدئ', 'نادي', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/51/calf-raises/', NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a94fd314-fcd9-4344-a9de-9ab1a2207b4e', 'High-Load Heel Raise (Towel Under Toes)', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', NULL, 'مبتدئ', NULL, NULL, 'رفع الكعب على رجل واحدة مع منشفة ملفوفة تحت أصابع القدم؛ صعود بطيء ثم ثبات قصير ثم نزول بطيء.', 'أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Rathleff et al. 2015 — Scand J Med Sci Sports (RCT)', 'https://doi.org/10.1111/sms.12313', 'اللفافة الأخمصية / Plantar Fasciopathy', 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('074f6b67-07c5-41dd-b8cb-a9020ca07389', 'Adductor Slides', 'Adductors / الأفخاذ الداخلية', '{}', 'Hip Adduction / تقريب الورك', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/6U7dfuxaX9g?si=lkH35E7tZxGBePBj', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor strength»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2c03e118-6e99-4d00-b773-df031e3c89a8', 'Adductor Machine', 'Adductors / الأفخاذ الداخلية', '{}', 'Hip Adduction / تقريب الورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/SU1LQhq3o2g?si=_55FKBOlcn8Ilw4X', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6a3d4ef4-3786-4ef2-a120-37ebbf3095a7', 'Side Lunge', 'Adductors / الأفخاذ الداخلية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/50/side-lunge/', 'ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0c8ee958-84e1-4795-a3b2-9edb416de299', 'Seated Abductor Machine', 'Abductors / مبعدات الفخذ', '{}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/riEMreTHNbM?si=wE3vfJBYQY7j_oJ2', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor strength»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a3f91f9b-5dd2-41bf-a3d1-94824d4aa83f', 'Hip Abductor Plank', 'Abductors / مبعدات الفخذ', '{"Core / البطن والكور"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/2lB5RL91yWo?si=WRm9rUORpFK6dXPl', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor strength»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c211836f-fb17-4358-9aea-bca65569c159', 'Dirty Dog', 'Abductors / مبعدات الفخذ', '{"Core / البطن والكور"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/109/dirty-dog/', NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('59073842-fa9a-46ad-a35d-258bff33564b', 'Hip Hitch (Pelvic Drop)', 'Abductors / مبعدات الفخذ', '{}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Ganderton et al. — GMin/GMed EMG (RMIT University)', 'https://research-repository.rmit.edu.au/articles/journal_contribution/Gluteus_Minimus_and_Gluteus_Medius_Muscle_Activity_during_Common_Rehabilitation_Exercises_in_Healthy_Postmenopausal_Women/27572301', 'ضعف الألوية المتوسطة / Gluteus Medius Weakness | ضعف الألوية الصغرى / Gluteus Minimus Weakness', 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('422622ae-ee74-40c0-9b40-59fad23a1c3f', 'Rotator Cuff', 'Rotator cuffs / الكفة المدورة', '{}', 'Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/mO8YJAxVG2M?si=KL_llR6Z47Yt89uk', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «Functional Training»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3a8b3697-0afc-4095-bbfa-6ed7090e7e53', 'Shoulder I-Y-T-W Series', 'Rotator cuffs / الكفة المدورة', '{"Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/237/shoulder-stability-mobility-series-i-y-t-w-formations/', 'تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture | ضعف العضلة المعينية / Rhomboid Weakness', 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('941e84d1-1806-4911-87df-9a83441b5f07', 'Supine Snow Angel (Wipers)', 'Rotator cuffs / الكفة المدورة', '{"Shoulders / الأكتاف","Core / البطن والكور"}', 'Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/124/supine-snow-angel-wipers-exercise/', 'تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture', 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a9208cd4-87b2-4e50-9e17-1c0582372456', 'Back Extension', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة","Hamstrings / الخلفية"}', 'Spinal Extension / بسط الجذع', 'كور', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/bs7S3RFyIYs?si=tDLl3OYuDBIwK4Fj', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «Functional Training»)', 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain | تحدب الظهر / Postural Thoracic Kyphosis', 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('de01828f-0355-491b-9e1f-8c4eb11f4d9b', 'Supermans', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة","Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Spinal Extension / بسط الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/9/supermans/', 'تحدب الظهر / Postural Thoracic Kyphosis | آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('021770b2-f3b2-4f6f-a973-c12d114c35c9', 'Stability Ball Reverse Extensions', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة"}', 'Spinal Extension / بسط الجذع', 'كور', 'كرة سويسرية', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/64/stability-ball-reverse-extensions/', NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('abbc96db-97be-484c-b2b2-49e7adf5893d', 'Contralateral Limb Raises', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة","Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Spinal Extension / بسط الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/53/contralateral-limb-raises/', NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('15121c12-9656-4c1d-9e47-17b3cafe8bb3', 'Inner Thigh Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/uqCfJYKojLU?si=Gev0VeOwVp5z6gB2', 'الضغط والدفع يكون من جهة الفخذ ، لا تدفع من ركبتك!', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «stretch»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5c75951a-4e73-466e-9b49-38fa30a1d819', 'Hips Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/uqCfJYKojLU?si=Gev0VeOwVp5z6gB2', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «stretch»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('30b3ec4b-bfa1-4f68-8d62-10fc2f261841', 'Kneeling Hip-flexor Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'من وضع الركوع: الركبة الخلفية تحت الورك والقدم الأمامية أمامك والركبة فوق الكاحل. شد البطن وادفع الحوض للأمام دون تقويس أسفل الظهر، واعصر مؤخرة الجهة الخلفية لزيادة الإطالة. اثبت 30–45 ثانية، 2–5 مرات.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/142/kneeling-hip-flexor-stretch/', NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('27219e71-cd1d-4f5e-8d52-9538f1053295', 'Supine Hamstrings Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'استلقِ على ظهرك وارفع رجلاً واحدة ومدّها ببطء مع سحب أصابع القدم نحوك، دون أي حركة في الحوض أو أسفل الظهر. اثبت 15–30 ثانية، 2–4 مرات لكل رجل.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/235/supine-hamstrings-stretch/', NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('28b2a821-aa3d-452a-a8b0-7f891b6bdfc2', 'Side Lying Quadriceps Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'استلقِ على جنبك وشد البطن، واسحب كعب الرجل العلوية نحو المؤخرة بيدك مع إبقاء الركبة في خط الورك. اثبت 30–45 ثانية، 2–5 مرات لكل جهة.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/149/side-lying-quadriceps-stretch/', NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('60751958-3358-43ef-8bf6-32005aefc399', 'Standing Dorsi-Flexion (Calf Stretch)', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/152/standing-dorsi-flexion-calf-stretch/', 'اللفافة الأخمصية / Plantar Fasciopathy', 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b1424461-86bf-435e-a7f5-18480ff54d1e', 'Cat-Cow', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/15/cat-cow/', 'تحدب الظهر / Postural Thoracic Kyphosis | آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a0133db2-df29-4811-92d7-2d8fe9119009', 'Standing Lunge Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/137/standing-lunge-stretch/', NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('96387da3-3821-4685-a3a0-b889f3b01bc0', 'Plantar Fascia-Specific Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'تُسحب أصابع القدم للخلف باليد حتى يُشعر بشد في باطن القدم، مع تحسّس اللفافة للتأكد من الشد.', 'أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Rathleff et al. 2015 — Scand J Med Sci Sports (RCT)', 'https://doi.org/10.1111/sms.12313', 'اللفافة الأخمصية / Plantar Fasciopathy', 'review', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3ad0cf96-6302-4f90-b390-1fdc67bd274b', 'Lateral Bound', 'Plyometrics / التمارين الانفجارية', '{"Glutes / المؤخرة","Quadriceps / الأمامية","Abductors / مبعدات الفخذ"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://www.youtube.com/watch?v=soqQy4dzEts', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «Functional Training»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ada59c68-ab38-47fd-b498-10fd9443b648', 'Box Jumps', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Calves / البطات"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'أخرى', 'متوسط', 'نادي', NULL, NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «CrossFit»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d208dc8a-acec-4245-860e-13142ab7c087', 'Squat Jump', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متوسط', 'بدون معدات', NULL, 'قف بعرض الحوض، ادفع الورك للخلف وانزل، ثم اقفز بقوة بمدّ الكاحل والركبة والورك معاً. انزل بهدوء على منتصف القدم مع دفع الورك للخلف ودون قفل الركب. ابدأ بقفزات صغيرة حتى تتقن الهبوط.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/222/squat-jump/', NULL, 'review', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ddc1955d-ee54-405c-a9dc-1cb6bdaa3cbc', 'Tuck Jump', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متقدم', 'بدون معدات', NULL, 'استخدم الذراعين للزخم: أرجعهما للخلف عند النزول وأرجحهما للأمام والأعلى عند القفز، واسحب الركبتين نحو الصدر في الهواء.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/180/tuck-jump/', NULL, 'review', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f5c74d8f-94ce-44e5-a245-dc025f3e36b2', 'Cycled Split-Squat Jump', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Hamstrings / الخلفية"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متقدم', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/234/cycled-split-squat-jump/', NULL, 'review', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9627dce3-0728-4202-bda8-713661ba2fbe', 'Lateral Cone Jumps', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Calves / البطات"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'أخرى', 'متوسط', 'نادي', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/120/lateral-cone-jumps/', NULL, 'review', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('22749348-02e9-4c81-a37e-26ed50e7642d', 'Forward Linear Jumps', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Hamstrings / الخلفية"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متوسط', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/177/forward-linear-jumps/', NULL, 'review', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('218261e9-9488-4e99-b444-f0059c1251ce', 'Jogging', 'CrossFit / كروس فت', '{"Quadriceps / الأمامية","Hamstrings / الخلفية","Calves / البطات"}', 'Locomotion / مشي وجري ودفع', 'كارديو', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('61aa5b07-edda-4576-ac28-ed2765df1a56', 'Wall Ball', 'CrossFit / كروس فت', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Shoulders / الأكتاف"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'أخرى', 'متوسط', 'نادي', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('35184def-2db2-46f7-a2fb-263128c73df1', 'Snatch', 'CrossFit / كروس فت', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Shoulders / الأكتاف"}', 'Olympic Lift (Triple Extension) / رفعات أولمبية (بسط ثلاثي)', 'قدرة', 'بار', 'متقدم', 'نادي', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8c3fe9ee-4983-4186-a347-c9c7288996db', 'Clean', 'CrossFit / كروس فت', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Quadriceps / الأمامية"}', 'Olympic Lift (Triple Extension) / رفعات أولمبية (بسط ثلاثي)', 'قدرة', 'بار', 'متقدم', 'نادي', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a75f8c88-c055-4e91-b7ff-390f36262aa3', 'Turkish Get-Up', 'Functional / التمارين الوظيفية', '{"Shoulders / الأكتاف","Core / البطن والكور","Glutes / المؤخرة"}', 'Full-body Integrated / حركة متكاملة للجسم', 'قوة', 'كيتلبل', 'متقدم', 'منزل', 'https://www.youtube.com/watch?v=0bWRPC49-KI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b6cdb318-dacc-49f1-89b1-3147e86e0909', 'Crab Reach (Thoracic Bridge)', 'Functional / التمارين الوظيفية', '{"Glutes / المؤخرة","Shoulders / الأكتاف"}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://www.youtube.com/watch?v=fgsUe3Lc3hI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'تحدب الظهر / Postural Thoracic Kyphosis', 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d9b7904b-dad9-4a39-8717-3bfa51bd2e88', 'Sled Pull/Push', 'Functional / التمارين الوظيفية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Calves / البطات"}', 'Locomotion / مشي وجري ودفع', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://www.youtube.com/watch?v=3KWK7SIdPz4', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c975a833-ba21-4bee-b48a-125783268a1a', 'Farmer’s Walk', 'Functional / التمارين الوظيفية', '{"Forearms / الساعد","Core / البطن والكور","Back & Lats / الظهر واللاتس"}', 'Loaded Carry / حمل ومشي', 'قوة', NULL, 'مبتدئ', NULL, 'https://www.youtube.com/watch?v=hx24PM6gXs8', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f0de1e07-20d6-493e-8033-409c93fc2e94', '90s Transition', 'Functional / التمارين الوظيفية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://www.youtube.com/watch?v=ogU-azeGe_k', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4eb3ad03-5609-4301-8b53-9a3127adfe22', 'Prone Swimmer', 'Functional / التمارين الوظيفية', '{"Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Shoulder Rear Pull / سحب خلفي للكتف', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://www.youtube.com/watch?v=M8a1cgnhyqk', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture', 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('69355460-5253-4e85-b728-427092995393', 'Kettlebell Swing', 'Functional / التمارين الوظيفية', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Core / البطن والكور"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قدرة', 'كيتلبل', 'متوسط', 'منزل', 'https://www.youtube.com/watch?v=d94xX-AQZ0A', NULL, 'نفس التمرين ورد أيضاً تحت التصنيف «CrossFit» (صف المصدر 168)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c634e286-0375-42e4-8c1a-4122d8f8253f', 'left over db', 'Functional / التمارين الوظيفية', '{}', NULL, NULL, 'دمبل', NULL, 'منزل', 'https://youtu.be/pLnRt-caepc?si=DAS9jeYr8vS6RRtz', 'طبق الحركة بأقصى عدد ممكن من التكرارات وأحسبها كجولة، ثم ابدأ بالجولة الثانية بنفس الطريقة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5b6f2ade-941a-465f-b81e-1e25715d3513', 'Serratus Punches Supine', 'Functional / التمارين الوظيفية', '{"Shoulders / الأكتاف","Chest / الصدر"}', 'Horizontal Push / دفع أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/cxaAqmdlrgk?si=2YRAIgFFXPAvDadG', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('341ed716-1e08-406a-91f4-75984b2f02fd', 'Isometric Wrist Extension', 'Forearms / الساعد', '{}', 'Wrist Extension / مد الرسغ', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'مرفق التنس / Lateral Elbow Tendinopathy', 'review', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c262d714-865c-4f35-83dc-65d59b765440', 'Eccentric Wrist Extension', 'Forearms / الساعد', '{}', 'Wrist Extension / مد الرسغ', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'مرفق التنس / Lateral Elbow Tendinopathy', 'review', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('aaa2dcfe-640c-47d0-9924-ef04e0627fd1', 'Chin Tuck (Deep Neck Flexor)', 'Neck / الرقبة', '{}', 'Neck Flexion (Deep Flexors) / ثني الرقبة العميق', 'إحماء/تفعيل', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Sheikhhoseini et al. 2018 — JMPT (Systematic review, FHP)', 'https://pubmed.ncbi.nlm.nih.gov/30107937/', 'وضعية الرأس للأمام / Forward Head Posture', 'review', '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;



INSERT INTO public.exercise_alternatives VALUES ('3fb57426-5cdd-49b7-96ef-40716748869a', '96188b17-9e07-4ae8-915b-bbd87e378432', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3fb57426-5cdd-49b7-96ef-40716748869a', '45bf2bbb-b5dc-437a-8856-8854231e9c6d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3fb57426-5cdd-49b7-96ef-40716748869a', '75a5dea1-8537-49e8-b834-b90510e69db9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3fb57426-5cdd-49b7-96ef-40716748869a', '62262ac6-9751-4620-ae71-da86a1f29c56', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3fb57426-5cdd-49b7-96ef-40716748869a', '87952861-3183-42cd-a845-e3c65d0fa22d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('96188b17-9e07-4ae8-915b-bbd87e378432', '3fb57426-5cdd-49b7-96ef-40716748869a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('96188b17-9e07-4ae8-915b-bbd87e378432', '45bf2bbb-b5dc-437a-8856-8854231e9c6d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('96188b17-9e07-4ae8-915b-bbd87e378432', '75a5dea1-8537-49e8-b834-b90510e69db9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('96188b17-9e07-4ae8-915b-bbd87e378432', '62262ac6-9751-4620-ae71-da86a1f29c56', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('96188b17-9e07-4ae8-915b-bbd87e378432', '87952861-3183-42cd-a845-e3c65d0fa22d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b96473d-316d-4211-87f8-4cd0de078eaa', '1e970ca7-437e-4c78-bd19-5df2f7cc2177', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b96473d-316d-4211-87f8-4cd0de078eaa', '8abdb58e-452c-49c7-b991-5b08f1ace32c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b96473d-316d-4211-87f8-4cd0de078eaa', '3fb57426-5cdd-49b7-96ef-40716748869a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b96473d-316d-4211-87f8-4cd0de078eaa', '96188b17-9e07-4ae8-915b-bbd87e378432', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b96473d-316d-4211-87f8-4cd0de078eaa', '24d336c6-c388-4f6d-8f71-dc044dc1dbfe', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('24d336c6-c388-4f6d-8f71-dc044dc1dbfe', 'b7f2a3ca-2d62-41da-a81d-5a598ee71c13', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('24d336c6-c388-4f6d-8f71-dc044dc1dbfe', '3fb57426-5cdd-49b7-96ef-40716748869a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('24d336c6-c388-4f6d-8f71-dc044dc1dbfe', '96188b17-9e07-4ae8-915b-bbd87e378432', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('24d336c6-c388-4f6d-8f71-dc044dc1dbfe', '8b96473d-316d-4211-87f8-4cd0de078eaa', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('24d336c6-c388-4f6d-8f71-dc044dc1dbfe', '45bf2bbb-b5dc-437a-8856-8854231e9c6d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7f2a3ca-2d62-41da-a81d-5a598ee71c13', '24d336c6-c388-4f6d-8f71-dc044dc1dbfe', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7f2a3ca-2d62-41da-a81d-5a598ee71c13', '3fb57426-5cdd-49b7-96ef-40716748869a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7f2a3ca-2d62-41da-a81d-5a598ee71c13', '96188b17-9e07-4ae8-915b-bbd87e378432', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7f2a3ca-2d62-41da-a81d-5a598ee71c13', '8b96473d-316d-4211-87f8-4cd0de078eaa', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7f2a3ca-2d62-41da-a81d-5a598ee71c13', '45bf2bbb-b5dc-437a-8856-8854231e9c6d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45bf2bbb-b5dc-437a-8856-8854231e9c6d', '3fb57426-5cdd-49b7-96ef-40716748869a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45bf2bbb-b5dc-437a-8856-8854231e9c6d', '96188b17-9e07-4ae8-915b-bbd87e378432', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45bf2bbb-b5dc-437a-8856-8854231e9c6d', '75a5dea1-8537-49e8-b834-b90510e69db9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45bf2bbb-b5dc-437a-8856-8854231e9c6d', '62262ac6-9751-4620-ae71-da86a1f29c56', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45bf2bbb-b5dc-437a-8856-8854231e9c6d', '87952861-3183-42cd-a845-e3c65d0fa22d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75a5dea1-8537-49e8-b834-b90510e69db9', '3fb57426-5cdd-49b7-96ef-40716748869a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75a5dea1-8537-49e8-b834-b90510e69db9', '96188b17-9e07-4ae8-915b-bbd87e378432', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75a5dea1-8537-49e8-b834-b90510e69db9', '45bf2bbb-b5dc-437a-8856-8854231e9c6d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75a5dea1-8537-49e8-b834-b90510e69db9', '62262ac6-9751-4620-ae71-da86a1f29c56', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75a5dea1-8537-49e8-b834-b90510e69db9', '87952861-3183-42cd-a845-e3c65d0fa22d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1e970ca7-437e-4c78-bd19-5df2f7cc2177', '8b96473d-316d-4211-87f8-4cd0de078eaa', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1e970ca7-437e-4c78-bd19-5df2f7cc2177', '8abdb58e-452c-49c7-b991-5b08f1ace32c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1e970ca7-437e-4c78-bd19-5df2f7cc2177', '3fb57426-5cdd-49b7-96ef-40716748869a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1e970ca7-437e-4c78-bd19-5df2f7cc2177', '96188b17-9e07-4ae8-915b-bbd87e378432', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1e970ca7-437e-4c78-bd19-5df2f7cc2177', '24d336c6-c388-4f6d-8f71-dc044dc1dbfe', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('62262ac6-9751-4620-ae71-da86a1f29c56', '3fb57426-5cdd-49b7-96ef-40716748869a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('62262ac6-9751-4620-ae71-da86a1f29c56', '96188b17-9e07-4ae8-915b-bbd87e378432', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('62262ac6-9751-4620-ae71-da86a1f29c56', '45bf2bbb-b5dc-437a-8856-8854231e9c6d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('62262ac6-9751-4620-ae71-da86a1f29c56', '75a5dea1-8537-49e8-b834-b90510e69db9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('62262ac6-9751-4620-ae71-da86a1f29c56', '87952861-3183-42cd-a845-e3c65d0fa22d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8abdb58e-452c-49c7-b991-5b08f1ace32c', '8b96473d-316d-4211-87f8-4cd0de078eaa', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8abdb58e-452c-49c7-b991-5b08f1ace32c', '1e970ca7-437e-4c78-bd19-5df2f7cc2177', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8abdb58e-452c-49c7-b991-5b08f1ace32c', '3fb57426-5cdd-49b7-96ef-40716748869a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8abdb58e-452c-49c7-b991-5b08f1ace32c', '96188b17-9e07-4ae8-915b-bbd87e378432', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8abdb58e-452c-49c7-b991-5b08f1ace32c', '24d336c6-c388-4f6d-8f71-dc044dc1dbfe', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e4fca552-62be-4e27-8a72-580d1349e344', 'ce34ff36-2831-45d4-bef9-ac8c39dbf119', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e4fca552-62be-4e27-8a72-580d1349e344', 'fe84610a-a6f3-4f05-b577-392212e84d5b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e4fca552-62be-4e27-8a72-580d1349e344', 'bb708f0d-334b-44c9-a53e-3bccd5e84a84', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e4fca552-62be-4e27-8a72-580d1349e344', '223a7451-aede-44ed-8c48-6f4830c5a5d9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e4fca552-62be-4e27-8a72-580d1349e344', '2e628064-5dbc-45d6-a58e-8dd7ba6ae1dc', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce34ff36-2831-45d4-bef9-ac8c39dbf119', 'fe84610a-a6f3-4f05-b577-392212e84d5b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce34ff36-2831-45d4-bef9-ac8c39dbf119', 'bb708f0d-334b-44c9-a53e-3bccd5e84a84', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce34ff36-2831-45d4-bef9-ac8c39dbf119', '2e628064-5dbc-45d6-a58e-8dd7ba6ae1dc', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce34ff36-2831-45d4-bef9-ac8c39dbf119', 'b2f4c07c-7d5b-4b69-963b-b3a82096c890', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce34ff36-2831-45d4-bef9-ac8c39dbf119', 'e4fca552-62be-4e27-8a72-580d1349e344', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe84610a-a6f3-4f05-b577-392212e84d5b', 'ce34ff36-2831-45d4-bef9-ac8c39dbf119', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe84610a-a6f3-4f05-b577-392212e84d5b', 'bb708f0d-334b-44c9-a53e-3bccd5e84a84', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe84610a-a6f3-4f05-b577-392212e84d5b', '2e628064-5dbc-45d6-a58e-8dd7ba6ae1dc', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe84610a-a6f3-4f05-b577-392212e84d5b', 'b2f4c07c-7d5b-4b69-963b-b3a82096c890', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe84610a-a6f3-4f05-b577-392212e84d5b', 'e4fca552-62be-4e27-8a72-580d1349e344', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bb708f0d-334b-44c9-a53e-3bccd5e84a84', 'ce34ff36-2831-45d4-bef9-ac8c39dbf119', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bb708f0d-334b-44c9-a53e-3bccd5e84a84', 'fe84610a-a6f3-4f05-b577-392212e84d5b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bb708f0d-334b-44c9-a53e-3bccd5e84a84', '2e628064-5dbc-45d6-a58e-8dd7ba6ae1dc', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bb708f0d-334b-44c9-a53e-3bccd5e84a84', 'b2f4c07c-7d5b-4b69-963b-b3a82096c890', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bb708f0d-334b-44c9-a53e-3bccd5e84a84', 'e4fca552-62be-4e27-8a72-580d1349e344', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('223a7451-aede-44ed-8c48-6f4830c5a5d9', 'e4fca552-62be-4e27-8a72-580d1349e344', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('223a7451-aede-44ed-8c48-6f4830c5a5d9', 'ce34ff36-2831-45d4-bef9-ac8c39dbf119', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('223a7451-aede-44ed-8c48-6f4830c5a5d9', 'fe84610a-a6f3-4f05-b577-392212e84d5b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('223a7451-aede-44ed-8c48-6f4830c5a5d9', 'bb708f0d-334b-44c9-a53e-3bccd5e84a84', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('223a7451-aede-44ed-8c48-6f4830c5a5d9', '2e628064-5dbc-45d6-a58e-8dd7ba6ae1dc', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2e628064-5dbc-45d6-a58e-8dd7ba6ae1dc', 'ce34ff36-2831-45d4-bef9-ac8c39dbf119', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2e628064-5dbc-45d6-a58e-8dd7ba6ae1dc', 'fe84610a-a6f3-4f05-b577-392212e84d5b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2e628064-5dbc-45d6-a58e-8dd7ba6ae1dc', 'bb708f0d-334b-44c9-a53e-3bccd5e84a84', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2e628064-5dbc-45d6-a58e-8dd7ba6ae1dc', 'b2f4c07c-7d5b-4b69-963b-b3a82096c890', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2e628064-5dbc-45d6-a58e-8dd7ba6ae1dc', 'e4fca552-62be-4e27-8a72-580d1349e344', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b2f4c07c-7d5b-4b69-963b-b3a82096c890', 'ce34ff36-2831-45d4-bef9-ac8c39dbf119', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b2f4c07c-7d5b-4b69-963b-b3a82096c890', 'fe84610a-a6f3-4f05-b577-392212e84d5b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b2f4c07c-7d5b-4b69-963b-b3a82096c890', 'bb708f0d-334b-44c9-a53e-3bccd5e84a84', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b2f4c07c-7d5b-4b69-963b-b3a82096c890', '2e628064-5dbc-45d6-a58e-8dd7ba6ae1dc', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b2f4c07c-7d5b-4b69-963b-b3a82096c890', 'e4fca552-62be-4e27-8a72-580d1349e344', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('422fe6d2-a701-4588-aa9f-68b9c00d832f', '12ca3c57-f811-47e4-ba9d-eaf0b97556ab', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('422fe6d2-a701-4588-aa9f-68b9c00d832f', '15f8d065-2d87-486d-b4b3-ab4b60ae996a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('422fe6d2-a701-4588-aa9f-68b9c00d832f', 'd874649f-98a7-4b6c-aae7-0360df709b7a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('422fe6d2-a701-4588-aa9f-68b9c00d832f', 'cd4b9b10-4303-4133-affa-7bea0a640c5f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('422fe6d2-a701-4588-aa9f-68b9c00d832f', 'bb1f9c36-3d68-434c-b3f2-d79f179c8f60', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('12ca3c57-f811-47e4-ba9d-eaf0b97556ab', '422fe6d2-a701-4588-aa9f-68b9c00d832f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('12ca3c57-f811-47e4-ba9d-eaf0b97556ab', '15f8d065-2d87-486d-b4b3-ab4b60ae996a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('12ca3c57-f811-47e4-ba9d-eaf0b97556ab', 'd874649f-98a7-4b6c-aae7-0360df709b7a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('12ca3c57-f811-47e4-ba9d-eaf0b97556ab', 'cd4b9b10-4303-4133-affa-7bea0a640c5f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('12ca3c57-f811-47e4-ba9d-eaf0b97556ab', 'bb1f9c36-3d68-434c-b3f2-d79f179c8f60', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('15f8d065-2d87-486d-b4b3-ab4b60ae996a', '422fe6d2-a701-4588-aa9f-68b9c00d832f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('15f8d065-2d87-486d-b4b3-ab4b60ae996a', '12ca3c57-f811-47e4-ba9d-eaf0b97556ab', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('15f8d065-2d87-486d-b4b3-ab4b60ae996a', 'd874649f-98a7-4b6c-aae7-0360df709b7a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('15f8d065-2d87-486d-b4b3-ab4b60ae996a', 'cd4b9b10-4303-4133-affa-7bea0a640c5f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('15f8d065-2d87-486d-b4b3-ab4b60ae996a', 'bb1f9c36-3d68-434c-b3f2-d79f179c8f60', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bb1f9c36-3d68-434c-b3f2-d79f179c8f60', '422fe6d2-a701-4588-aa9f-68b9c00d832f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bb1f9c36-3d68-434c-b3f2-d79f179c8f60', '12ca3c57-f811-47e4-ba9d-eaf0b97556ab', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bb1f9c36-3d68-434c-b3f2-d79f179c8f60', '15f8d065-2d87-486d-b4b3-ab4b60ae996a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bb1f9c36-3d68-434c-b3f2-d79f179c8f60', 'd874649f-98a7-4b6c-aae7-0360df709b7a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bb1f9c36-3d68-434c-b3f2-d79f179c8f60', 'cd4b9b10-4303-4133-affa-7bea0a640c5f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d874649f-98a7-4b6c-aae7-0360df709b7a', '422fe6d2-a701-4588-aa9f-68b9c00d832f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d874649f-98a7-4b6c-aae7-0360df709b7a', '12ca3c57-f811-47e4-ba9d-eaf0b97556ab', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d874649f-98a7-4b6c-aae7-0360df709b7a', '15f8d065-2d87-486d-b4b3-ab4b60ae996a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d874649f-98a7-4b6c-aae7-0360df709b7a', 'cd4b9b10-4303-4133-affa-7bea0a640c5f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d874649f-98a7-4b6c-aae7-0360df709b7a', 'bb1f9c36-3d68-434c-b3f2-d79f179c8f60', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd4b9b10-4303-4133-affa-7bea0a640c5f', '422fe6d2-a701-4588-aa9f-68b9c00d832f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd4b9b10-4303-4133-affa-7bea0a640c5f', '12ca3c57-f811-47e4-ba9d-eaf0b97556ab', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd4b9b10-4303-4133-affa-7bea0a640c5f', '15f8d065-2d87-486d-b4b3-ab4b60ae996a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd4b9b10-4303-4133-affa-7bea0a640c5f', 'd874649f-98a7-4b6c-aae7-0360df709b7a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd4b9b10-4303-4133-affa-7bea0a640c5f', 'bb1f9c36-3d68-434c-b3f2-d79f179c8f60', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('87952861-3183-42cd-a845-e3c65d0fa22d', '3fb57426-5cdd-49b7-96ef-40716748869a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('87952861-3183-42cd-a845-e3c65d0fa22d', '96188b17-9e07-4ae8-915b-bbd87e378432', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('87952861-3183-42cd-a845-e3c65d0fa22d', '45bf2bbb-b5dc-437a-8856-8854231e9c6d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('87952861-3183-42cd-a845-e3c65d0fa22d', '75a5dea1-8537-49e8-b834-b90510e69db9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('87952861-3183-42cd-a845-e3c65d0fa22d', '62262ac6-9751-4620-ae71-da86a1f29c56', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('048ac230-6c6b-4a71-8f41-b2515c1f390b', 'e4fca552-62be-4e27-8a72-580d1349e344', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('048ac230-6c6b-4a71-8f41-b2515c1f390b', 'ce34ff36-2831-45d4-bef9-ac8c39dbf119', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('048ac230-6c6b-4a71-8f41-b2515c1f390b', 'fe84610a-a6f3-4f05-b577-392212e84d5b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('048ac230-6c6b-4a71-8f41-b2515c1f390b', 'bb708f0d-334b-44c9-a53e-3bccd5e84a84', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('048ac230-6c6b-4a71-8f41-b2515c1f390b', '223a7451-aede-44ed-8c48-6f4830c5a5d9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3312b8e8-efd4-4780-ae5f-178b9001f6ef', '47c8002b-ba74-4444-adf3-5163d4b0a7b5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3312b8e8-efd4-4780-ae5f-178b9001f6ef', '1ac49e41-b7ff-40f3-8df0-e5715c7bb26f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3312b8e8-efd4-4780-ae5f-178b9001f6ef', '7de0ca13-cd12-4f78-ad53-00970d28737c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('47c8002b-ba74-4444-adf3-5163d4b0a7b5', '3312b8e8-efd4-4780-ae5f-178b9001f6ef', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('47c8002b-ba74-4444-adf3-5163d4b0a7b5', '1ac49e41-b7ff-40f3-8df0-e5715c7bb26f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('47c8002b-ba74-4444-adf3-5163d4b0a7b5', '7de0ca13-cd12-4f78-ad53-00970d28737c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ac49e41-b7ff-40f3-8df0-e5715c7bb26f', '3312b8e8-efd4-4780-ae5f-178b9001f6ef', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ac49e41-b7ff-40f3-8df0-e5715c7bb26f', '47c8002b-ba74-4444-adf3-5163d4b0a7b5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ac49e41-b7ff-40f3-8df0-e5715c7bb26f', '7de0ca13-cd12-4f78-ad53-00970d28737c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7de0ca13-cd12-4f78-ad53-00970d28737c', '3312b8e8-efd4-4780-ae5f-178b9001f6ef', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7de0ca13-cd12-4f78-ad53-00970d28737c', '47c8002b-ba74-4444-adf3-5163d4b0a7b5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7de0ca13-cd12-4f78-ad53-00970d28737c', '1ac49e41-b7ff-40f3-8df0-e5715c7bb26f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('47f45dec-b3d8-4447-8c54-89ed8f40cc99', 'c64b4897-76db-4bb0-85b4-4a8f33faa50d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('47f45dec-b3d8-4447-8c54-89ed8f40cc99', 'c246062b-3cde-4d00-b217-11105e479617', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('47f45dec-b3d8-4447-8c54-89ed8f40cc99', '055e82f0-1e3d-41ec-a054-e3daae413566', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('47f45dec-b3d8-4447-8c54-89ed8f40cc99', 'b15ee4cd-6c9f-4c80-994c-30305114ab70', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('47f45dec-b3d8-4447-8c54-89ed8f40cc99', '4060b2ba-e6d5-4363-8746-b994a8b1f625', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('da164b65-e4f2-4abb-8611-65b78f099561', '0c8ee958-84e1-4795-a3b2-9edb416de299', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('da164b65-e4f2-4abb-8611-65b78f099561', 'a3f91f9b-5dd2-41bf-a3d1-94824d4aa83f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('da164b65-e4f2-4abb-8611-65b78f099561', 'c211836f-fb17-4358-9aea-bca65569c159', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('da164b65-e4f2-4abb-8611-65b78f099561', 'dc7de871-73bb-45da-86f9-b18e7e3d4089', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('da164b65-e4f2-4abb-8611-65b78f099561', '59073842-fa9a-46ad-a35d-258bff33564b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c64b4897-76db-4bb0-85b4-4a8f33faa50d', '47f45dec-b3d8-4447-8c54-89ed8f40cc99', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c64b4897-76db-4bb0-85b4-4a8f33faa50d', 'c246062b-3cde-4d00-b217-11105e479617', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c64b4897-76db-4bb0-85b4-4a8f33faa50d', '055e82f0-1e3d-41ec-a054-e3daae413566', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c64b4897-76db-4bb0-85b4-4a8f33faa50d', 'b15ee4cd-6c9f-4c80-994c-30305114ab70', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c64b4897-76db-4bb0-85b4-4a8f33faa50d', '4060b2ba-e6d5-4363-8746-b994a8b1f625', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dc7de871-73bb-45da-86f9-b18e7e3d4089', 'da164b65-e4f2-4abb-8611-65b78f099561', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dc7de871-73bb-45da-86f9-b18e7e3d4089', '0c8ee958-84e1-4795-a3b2-9edb416de299', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dc7de871-73bb-45da-86f9-b18e7e3d4089', 'a3f91f9b-5dd2-41bf-a3d1-94824d4aa83f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dc7de871-73bb-45da-86f9-b18e7e3d4089', 'c211836f-fb17-4358-9aea-bca65569c159', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dc7de871-73bb-45da-86f9-b18e7e3d4089', '59073842-fa9a-46ad-a35d-258bff33564b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d86e837-a80a-4a54-a5f6-bfa02a0f9699', '3312b8e8-efd4-4780-ae5f-178b9001f6ef', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d86e837-a80a-4a54-a5f6-bfa02a0f9699', '47c8002b-ba74-4444-adf3-5163d4b0a7b5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d86e837-a80a-4a54-a5f6-bfa02a0f9699', '1ac49e41-b7ff-40f3-8df0-e5715c7bb26f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d86e837-a80a-4a54-a5f6-bfa02a0f9699', '7de0ca13-cd12-4f78-ad53-00970d28737c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('055e82f0-1e3d-41ec-a054-e3daae413566', 'b15ee4cd-6c9f-4c80-994c-30305114ab70', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('055e82f0-1e3d-41ec-a054-e3daae413566', '4060b2ba-e6d5-4363-8746-b994a8b1f625', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('055e82f0-1e3d-41ec-a054-e3daae413566', '15e52aae-a1a6-430a-80f8-a5a520da14e3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('055e82f0-1e3d-41ec-a054-e3daae413566', 'a24837a1-fd7d-4df5-90e7-ea3f3d5b840f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('055e82f0-1e3d-41ec-a054-e3daae413566', '47f45dec-b3d8-4447-8c54-89ed8f40cc99', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b15ee4cd-6c9f-4c80-994c-30305114ab70', '055e82f0-1e3d-41ec-a054-e3daae413566', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b15ee4cd-6c9f-4c80-994c-30305114ab70', '4060b2ba-e6d5-4363-8746-b994a8b1f625', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b15ee4cd-6c9f-4c80-994c-30305114ab70', '15e52aae-a1a6-430a-80f8-a5a520da14e3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b15ee4cd-6c9f-4c80-994c-30305114ab70', 'a24837a1-fd7d-4df5-90e7-ea3f3d5b840f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b15ee4cd-6c9f-4c80-994c-30305114ab70', '47f45dec-b3d8-4447-8c54-89ed8f40cc99', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4060b2ba-e6d5-4363-8746-b994a8b1f625', '055e82f0-1e3d-41ec-a054-e3daae413566', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4060b2ba-e6d5-4363-8746-b994a8b1f625', 'b15ee4cd-6c9f-4c80-994c-30305114ab70', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4060b2ba-e6d5-4363-8746-b994a8b1f625', '15e52aae-a1a6-430a-80f8-a5a520da14e3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4060b2ba-e6d5-4363-8746-b994a8b1f625', 'a24837a1-fd7d-4df5-90e7-ea3f3d5b840f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4060b2ba-e6d5-4363-8746-b994a8b1f625', '47f45dec-b3d8-4447-8c54-89ed8f40cc99', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('15e52aae-a1a6-430a-80f8-a5a520da14e3', '055e82f0-1e3d-41ec-a054-e3daae413566', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('15e52aae-a1a6-430a-80f8-a5a520da14e3', 'b15ee4cd-6c9f-4c80-994c-30305114ab70', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('15e52aae-a1a6-430a-80f8-a5a520da14e3', '4060b2ba-e6d5-4363-8746-b994a8b1f625', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('15e52aae-a1a6-430a-80f8-a5a520da14e3', 'a24837a1-fd7d-4df5-90e7-ea3f3d5b840f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('15e52aae-a1a6-430a-80f8-a5a520da14e3', '47f45dec-b3d8-4447-8c54-89ed8f40cc99', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2bff1fb2-e127-49fa-a0ad-fb5a29394961', '47f45dec-b3d8-4447-8c54-89ed8f40cc99', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2bff1fb2-e127-49fa-a0ad-fb5a29394961', 'c64b4897-76db-4bb0-85b4-4a8f33faa50d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2bff1fb2-e127-49fa-a0ad-fb5a29394961', '055e82f0-1e3d-41ec-a054-e3daae413566', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2bff1fb2-e127-49fa-a0ad-fb5a29394961', 'b15ee4cd-6c9f-4c80-994c-30305114ab70', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2bff1fb2-e127-49fa-a0ad-fb5a29394961', '4060b2ba-e6d5-4363-8746-b994a8b1f625', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a24837a1-fd7d-4df5-90e7-ea3f3d5b840f', '055e82f0-1e3d-41ec-a054-e3daae413566', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a24837a1-fd7d-4df5-90e7-ea3f3d5b840f', 'b15ee4cd-6c9f-4c80-994c-30305114ab70', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a24837a1-fd7d-4df5-90e7-ea3f3d5b840f', '4060b2ba-e6d5-4363-8746-b994a8b1f625', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a24837a1-fd7d-4df5-90e7-ea3f3d5b840f', '15e52aae-a1a6-430a-80f8-a5a520da14e3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a24837a1-fd7d-4df5-90e7-ea3f3d5b840f', '47f45dec-b3d8-4447-8c54-89ed8f40cc99', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c246062b-3cde-4d00-b217-11105e479617', '47f45dec-b3d8-4447-8c54-89ed8f40cc99', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c246062b-3cde-4d00-b217-11105e479617', 'c64b4897-76db-4bb0-85b4-4a8f33faa50d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c246062b-3cde-4d00-b217-11105e479617', '055e82f0-1e3d-41ec-a054-e3daae413566', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c246062b-3cde-4d00-b217-11105e479617', 'b15ee4cd-6c9f-4c80-994c-30305114ab70', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c246062b-3cde-4d00-b217-11105e479617', '4060b2ba-e6d5-4363-8746-b994a8b1f625', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3252a57-b954-4eee-8e41-2c4d5345d21c', '3312b8e8-efd4-4780-ae5f-178b9001f6ef', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3252a57-b954-4eee-8e41-2c4d5345d21c', '47c8002b-ba74-4444-adf3-5163d4b0a7b5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3252a57-b954-4eee-8e41-2c4d5345d21c', '1ac49e41-b7ff-40f3-8df0-e5715c7bb26f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3252a57-b954-4eee-8e41-2c4d5345d21c', '7de0ca13-cd12-4f78-ad53-00970d28737c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e1455aa3-5f15-4b59-b1d0-715d099308b3', '3f3b97cd-3bc6-462f-a99f-369042c398e6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e1455aa3-5f15-4b59-b1d0-715d099308b3', 'bba5deb1-6337-472d-9a64-f247f7c5f44c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e1455aa3-5f15-4b59-b1d0-715d099308b3', '766c1dec-37af-4274-8436-90a38de86343', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e1455aa3-5f15-4b59-b1d0-715d099308b3', 'a8a0811b-6013-487f-b6cb-5351fc97000c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e1455aa3-5f15-4b59-b1d0-715d099308b3', '64b23c52-b3dc-475d-a5d3-cba02666b22b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('18181561-f3f4-48c4-975a-9a62c0cb24bc', '3f3b97cd-3bc6-462f-a99f-369042c398e6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('18181561-f3f4-48c4-975a-9a62c0cb24bc', 'bba5deb1-6337-472d-9a64-f247f7c5f44c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('18181561-f3f4-48c4-975a-9a62c0cb24bc', '766c1dec-37af-4274-8436-90a38de86343', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('18181561-f3f4-48c4-975a-9a62c0cb24bc', 'a8a0811b-6013-487f-b6cb-5351fc97000c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('18181561-f3f4-48c4-975a-9a62c0cb24bc', '64b23c52-b3dc-475d-a5d3-cba02666b22b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f3b97cd-3bc6-462f-a99f-369042c398e6', 'bba5deb1-6337-472d-9a64-f247f7c5f44c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f3b97cd-3bc6-462f-a99f-369042c398e6', '766c1dec-37af-4274-8436-90a38de86343', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f3b97cd-3bc6-462f-a99f-369042c398e6', 'a8a0811b-6013-487f-b6cb-5351fc97000c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f3b97cd-3bc6-462f-a99f-369042c398e6', '64b23c52-b3dc-475d-a5d3-cba02666b22b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f3b97cd-3bc6-462f-a99f-369042c398e6', '69949b56-d024-4cef-9b63-d62161a5f515', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bba5deb1-6337-472d-9a64-f247f7c5f44c', '3f3b97cd-3bc6-462f-a99f-369042c398e6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bba5deb1-6337-472d-9a64-f247f7c5f44c', '766c1dec-37af-4274-8436-90a38de86343', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bba5deb1-6337-472d-9a64-f247f7c5f44c', 'a8a0811b-6013-487f-b6cb-5351fc97000c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bba5deb1-6337-472d-9a64-f247f7c5f44c', '64b23c52-b3dc-475d-a5d3-cba02666b22b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bba5deb1-6337-472d-9a64-f247f7c5f44c', '69949b56-d024-4cef-9b63-d62161a5f515', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('766c1dec-37af-4274-8436-90a38de86343', '3f3b97cd-3bc6-462f-a99f-369042c398e6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('766c1dec-37af-4274-8436-90a38de86343', 'bba5deb1-6337-472d-9a64-f247f7c5f44c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('766c1dec-37af-4274-8436-90a38de86343', 'a8a0811b-6013-487f-b6cb-5351fc97000c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('766c1dec-37af-4274-8436-90a38de86343', '64b23c52-b3dc-475d-a5d3-cba02666b22b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('766c1dec-37af-4274-8436-90a38de86343', '69949b56-d024-4cef-9b63-d62161a5f515', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a8a0811b-6013-487f-b6cb-5351fc97000c', '3f3b97cd-3bc6-462f-a99f-369042c398e6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a8a0811b-6013-487f-b6cb-5351fc97000c', 'bba5deb1-6337-472d-9a64-f247f7c5f44c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a8a0811b-6013-487f-b6cb-5351fc97000c', '766c1dec-37af-4274-8436-90a38de86343', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a8a0811b-6013-487f-b6cb-5351fc97000c', '64b23c52-b3dc-475d-a5d3-cba02666b22b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a8a0811b-6013-487f-b6cb-5351fc97000c', '69949b56-d024-4cef-9b63-d62161a5f515', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('64b23c52-b3dc-475d-a5d3-cba02666b22b', '3f3b97cd-3bc6-462f-a99f-369042c398e6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('64b23c52-b3dc-475d-a5d3-cba02666b22b', 'bba5deb1-6337-472d-9a64-f247f7c5f44c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('64b23c52-b3dc-475d-a5d3-cba02666b22b', '766c1dec-37af-4274-8436-90a38de86343', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('64b23c52-b3dc-475d-a5d3-cba02666b22b', 'a8a0811b-6013-487f-b6cb-5351fc97000c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('64b23c52-b3dc-475d-a5d3-cba02666b22b', '69949b56-d024-4cef-9b63-d62161a5f515', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('69949b56-d024-4cef-9b63-d62161a5f515', '3f3b97cd-3bc6-462f-a99f-369042c398e6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('69949b56-d024-4cef-9b63-d62161a5f515', 'bba5deb1-6337-472d-9a64-f247f7c5f44c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('69949b56-d024-4cef-9b63-d62161a5f515', '766c1dec-37af-4274-8436-90a38de86343', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('69949b56-d024-4cef-9b63-d62161a5f515', 'a8a0811b-6013-487f-b6cb-5351fc97000c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('69949b56-d024-4cef-9b63-d62161a5f515', '64b23c52-b3dc-475d-a5d3-cba02666b22b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0f12a9fb-456a-4b8f-a7db-192fdc66bb62', '3f3b97cd-3bc6-462f-a99f-369042c398e6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0f12a9fb-456a-4b8f-a7db-192fdc66bb62', 'bba5deb1-6337-472d-9a64-f247f7c5f44c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0f12a9fb-456a-4b8f-a7db-192fdc66bb62', '766c1dec-37af-4274-8436-90a38de86343', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0f12a9fb-456a-4b8f-a7db-192fdc66bb62', 'a8a0811b-6013-487f-b6cb-5351fc97000c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0f12a9fb-456a-4b8f-a7db-192fdc66bb62', '64b23c52-b3dc-475d-a5d3-cba02666b22b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('96e40aba-1dbd-4532-b88e-e39b25f564d5', 'e5e82cf4-400d-4fdc-98a7-385470c7a716', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('96e40aba-1dbd-4532-b88e-e39b25f564d5', '67146b07-25e1-496b-9edb-5146cf0a71f3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('96e40aba-1dbd-4532-b88e-e39b25f564d5', 'f456e66e-4dd4-4a4f-ae13-cac6ce2b30a4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('96e40aba-1dbd-4532-b88e-e39b25f564d5', '2b08f365-19f4-4c8a-9c11-f5b16845e9bf', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('96e40aba-1dbd-4532-b88e-e39b25f564d5', '87cff249-29cc-4f7e-9acb-2756d97a9e15', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e5e82cf4-400d-4fdc-98a7-385470c7a716', '96e40aba-1dbd-4532-b88e-e39b25f564d5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e5e82cf4-400d-4fdc-98a7-385470c7a716', '67146b07-25e1-496b-9edb-5146cf0a71f3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e5e82cf4-400d-4fdc-98a7-385470c7a716', 'f456e66e-4dd4-4a4f-ae13-cac6ce2b30a4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e5e82cf4-400d-4fdc-98a7-385470c7a716', '2b08f365-19f4-4c8a-9c11-f5b16845e9bf', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e5e82cf4-400d-4fdc-98a7-385470c7a716', '87cff249-29cc-4f7e-9acb-2756d97a9e15', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('67146b07-25e1-496b-9edb-5146cf0a71f3', '96e40aba-1dbd-4532-b88e-e39b25f564d5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('67146b07-25e1-496b-9edb-5146cf0a71f3', 'e5e82cf4-400d-4fdc-98a7-385470c7a716', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('67146b07-25e1-496b-9edb-5146cf0a71f3', 'f456e66e-4dd4-4a4f-ae13-cac6ce2b30a4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('67146b07-25e1-496b-9edb-5146cf0a71f3', '2b08f365-19f4-4c8a-9c11-f5b16845e9bf', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('67146b07-25e1-496b-9edb-5146cf0a71f3', '87cff249-29cc-4f7e-9acb-2756d97a9e15', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f456e66e-4dd4-4a4f-ae13-cac6ce2b30a4', '96e40aba-1dbd-4532-b88e-e39b25f564d5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f456e66e-4dd4-4a4f-ae13-cac6ce2b30a4', 'e5e82cf4-400d-4fdc-98a7-385470c7a716', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f456e66e-4dd4-4a4f-ae13-cac6ce2b30a4', '67146b07-25e1-496b-9edb-5146cf0a71f3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f456e66e-4dd4-4a4f-ae13-cac6ce2b30a4', '2b08f365-19f4-4c8a-9c11-f5b16845e9bf', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f456e66e-4dd4-4a4f-ae13-cac6ce2b30a4', '87cff249-29cc-4f7e-9acb-2756d97a9e15', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2b08f365-19f4-4c8a-9c11-f5b16845e9bf', '96e40aba-1dbd-4532-b88e-e39b25f564d5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2b08f365-19f4-4c8a-9c11-f5b16845e9bf', 'e5e82cf4-400d-4fdc-98a7-385470c7a716', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2b08f365-19f4-4c8a-9c11-f5b16845e9bf', '67146b07-25e1-496b-9edb-5146cf0a71f3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2b08f365-19f4-4c8a-9c11-f5b16845e9bf', 'f456e66e-4dd4-4a4f-ae13-cac6ce2b30a4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2b08f365-19f4-4c8a-9c11-f5b16845e9bf', '87cff249-29cc-4f7e-9acb-2756d97a9e15', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('87cff249-29cc-4f7e-9acb-2756d97a9e15', '96e40aba-1dbd-4532-b88e-e39b25f564d5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('87cff249-29cc-4f7e-9acb-2756d97a9e15', 'e5e82cf4-400d-4fdc-98a7-385470c7a716', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('87cff249-29cc-4f7e-9acb-2756d97a9e15', '67146b07-25e1-496b-9edb-5146cf0a71f3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('87cff249-29cc-4f7e-9acb-2756d97a9e15', 'f456e66e-4dd4-4a4f-ae13-cac6ce2b30a4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('87cff249-29cc-4f7e-9acb-2756d97a9e15', '2b08f365-19f4-4c8a-9c11-f5b16845e9bf', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0bc10599-b82e-40df-a005-2a27a2f85058', '96e40aba-1dbd-4532-b88e-e39b25f564d5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0bc10599-b82e-40df-a005-2a27a2f85058', 'e5e82cf4-400d-4fdc-98a7-385470c7a716', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0bc10599-b82e-40df-a005-2a27a2f85058', '67146b07-25e1-496b-9edb-5146cf0a71f3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0bc10599-b82e-40df-a005-2a27a2f85058', 'f456e66e-4dd4-4a4f-ae13-cac6ce2b30a4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0bc10599-b82e-40df-a005-2a27a2f85058', '2b08f365-19f4-4c8a-9c11-f5b16845e9bf', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('43512a2f-bcbf-4404-94b4-8c3f93940bab', '96e40aba-1dbd-4532-b88e-e39b25f564d5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('43512a2f-bcbf-4404-94b4-8c3f93940bab', 'e5e82cf4-400d-4fdc-98a7-385470c7a716', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('43512a2f-bcbf-4404-94b4-8c3f93940bab', '67146b07-25e1-496b-9edb-5146cf0a71f3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('43512a2f-bcbf-4404-94b4-8c3f93940bab', 'f456e66e-4dd4-4a4f-ae13-cac6ce2b30a4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('43512a2f-bcbf-4404-94b4-8c3f93940bab', '2b08f365-19f4-4c8a-9c11-f5b16845e9bf', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b6229983-1163-4120-9f60-7552694a9def', '2ce52aa6-2a6f-4038-845c-eccdd7bb0fa5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b6229983-1163-4120-9f60-7552694a9def', '96e40aba-1dbd-4532-b88e-e39b25f564d5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b6229983-1163-4120-9f60-7552694a9def', 'e5e82cf4-400d-4fdc-98a7-385470c7a716', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b6229983-1163-4120-9f60-7552694a9def', '67146b07-25e1-496b-9edb-5146cf0a71f3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b6229983-1163-4120-9f60-7552694a9def', 'f456e66e-4dd4-4a4f-ae13-cac6ce2b30a4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ad7f1b4-dc4f-437a-923d-6552ec0ecdb8', '3f3b97cd-3bc6-462f-a99f-369042c398e6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ad7f1b4-dc4f-437a-923d-6552ec0ecdb8', 'bba5deb1-6337-472d-9a64-f247f7c5f44c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ad7f1b4-dc4f-437a-923d-6552ec0ecdb8', '766c1dec-37af-4274-8436-90a38de86343', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ad7f1b4-dc4f-437a-923d-6552ec0ecdb8', 'a8a0811b-6013-487f-b6cb-5351fc97000c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ad7f1b4-dc4f-437a-923d-6552ec0ecdb8', '64b23c52-b3dc-475d-a5d3-cba02666b22b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2ce52aa6-2a6f-4038-845c-eccdd7bb0fa5', 'b6229983-1163-4120-9f60-7552694a9def', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2ce52aa6-2a6f-4038-845c-eccdd7bb0fa5', '96e40aba-1dbd-4532-b88e-e39b25f564d5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2ce52aa6-2a6f-4038-845c-eccdd7bb0fa5', 'e5e82cf4-400d-4fdc-98a7-385470c7a716', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2ce52aa6-2a6f-4038-845c-eccdd7bb0fa5', '67146b07-25e1-496b-9edb-5146cf0a71f3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2ce52aa6-2a6f-4038-845c-eccdd7bb0fa5', 'f456e66e-4dd4-4a4f-ae13-cac6ce2b30a4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d95499ed-f35b-4a0d-9ebc-5999c26c11c6', '0e5f073b-b4bc-464d-b211-e708a1d9648c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d95499ed-f35b-4a0d-9ebc-5999c26c11c6', '9d0386c5-faa6-4b3c-a306-911d5526153b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d95499ed-f35b-4a0d-9ebc-5999c26c11c6', '3850a330-4de1-45cc-846e-4d02cd2a6079', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d95499ed-f35b-4a0d-9ebc-5999c26c11c6', 'dd5e9468-4d79-4c93-9c16-a88f18b41fd0', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d95499ed-f35b-4a0d-9ebc-5999c26c11c6', '19f8bb69-c60d-4199-96e6-6fc224b9862b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0e5f073b-b4bc-464d-b211-e708a1d9648c', 'd95499ed-f35b-4a0d-9ebc-5999c26c11c6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0e5f073b-b4bc-464d-b211-e708a1d9648c', '9d0386c5-faa6-4b3c-a306-911d5526153b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0e5f073b-b4bc-464d-b211-e708a1d9648c', '3850a330-4de1-45cc-846e-4d02cd2a6079', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0e5f073b-b4bc-464d-b211-e708a1d9648c', 'dd5e9468-4d79-4c93-9c16-a88f18b41fd0', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0e5f073b-b4bc-464d-b211-e708a1d9648c', '19f8bb69-c60d-4199-96e6-6fc224b9862b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9d0386c5-faa6-4b3c-a306-911d5526153b', 'd95499ed-f35b-4a0d-9ebc-5999c26c11c6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9d0386c5-faa6-4b3c-a306-911d5526153b', '0e5f073b-b4bc-464d-b211-e708a1d9648c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9d0386c5-faa6-4b3c-a306-911d5526153b', '3850a330-4de1-45cc-846e-4d02cd2a6079', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9d0386c5-faa6-4b3c-a306-911d5526153b', 'dd5e9468-4d79-4c93-9c16-a88f18b41fd0', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9d0386c5-faa6-4b3c-a306-911d5526153b', '19f8bb69-c60d-4199-96e6-6fc224b9862b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3850a330-4de1-45cc-846e-4d02cd2a6079', 'd95499ed-f35b-4a0d-9ebc-5999c26c11c6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3850a330-4de1-45cc-846e-4d02cd2a6079', '0e5f073b-b4bc-464d-b211-e708a1d9648c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3850a330-4de1-45cc-846e-4d02cd2a6079', '9d0386c5-faa6-4b3c-a306-911d5526153b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3850a330-4de1-45cc-846e-4d02cd2a6079', 'dd5e9468-4d79-4c93-9c16-a88f18b41fd0', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3850a330-4de1-45cc-846e-4d02cd2a6079', '19f8bb69-c60d-4199-96e6-6fc224b9862b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dd5e9468-4d79-4c93-9c16-a88f18b41fd0', 'd95499ed-f35b-4a0d-9ebc-5999c26c11c6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dd5e9468-4d79-4c93-9c16-a88f18b41fd0', '0e5f073b-b4bc-464d-b211-e708a1d9648c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dd5e9468-4d79-4c93-9c16-a88f18b41fd0', '9d0386c5-faa6-4b3c-a306-911d5526153b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dd5e9468-4d79-4c93-9c16-a88f18b41fd0', '3850a330-4de1-45cc-846e-4d02cd2a6079', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dd5e9468-4d79-4c93-9c16-a88f18b41fd0', '19f8bb69-c60d-4199-96e6-6fc224b9862b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ecb41983-9d73-4dcf-8f1e-92bd0c858042', 'd95499ed-f35b-4a0d-9ebc-5999c26c11c6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ecb41983-9d73-4dcf-8f1e-92bd0c858042', '0e5f073b-b4bc-464d-b211-e708a1d9648c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ecb41983-9d73-4dcf-8f1e-92bd0c858042', '9d0386c5-faa6-4b3c-a306-911d5526153b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ecb41983-9d73-4dcf-8f1e-92bd0c858042', '3850a330-4de1-45cc-846e-4d02cd2a6079', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ecb41983-9d73-4dcf-8f1e-92bd0c858042', 'dd5e9468-4d79-4c93-9c16-a88f18b41fd0', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19f8bb69-c60d-4199-96e6-6fc224b9862b', 'd95499ed-f35b-4a0d-9ebc-5999c26c11c6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19f8bb69-c60d-4199-96e6-6fc224b9862b', '0e5f073b-b4bc-464d-b211-e708a1d9648c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19f8bb69-c60d-4199-96e6-6fc224b9862b', '9d0386c5-faa6-4b3c-a306-911d5526153b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19f8bb69-c60d-4199-96e6-6fc224b9862b', '3850a330-4de1-45cc-846e-4d02cd2a6079', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19f8bb69-c60d-4199-96e6-6fc224b9862b', 'dd5e9468-4d79-4c93-9c16-a88f18b41fd0', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('51371706-8c26-4a85-ab90-f94bd865634d', 'd95499ed-f35b-4a0d-9ebc-5999c26c11c6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('51371706-8c26-4a85-ab90-f94bd865634d', '0e5f073b-b4bc-464d-b211-e708a1d9648c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('51371706-8c26-4a85-ab90-f94bd865634d', '9d0386c5-faa6-4b3c-a306-911d5526153b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('51371706-8c26-4a85-ab90-f94bd865634d', '3850a330-4de1-45cc-846e-4d02cd2a6079', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('51371706-8c26-4a85-ab90-f94bd865634d', 'dd5e9468-4d79-4c93-9c16-a88f18b41fd0', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c51936cb-a913-4c78-b5b8-fcdafb423580', 'd95499ed-f35b-4a0d-9ebc-5999c26c11c6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c51936cb-a913-4c78-b5b8-fcdafb423580', '0e5f073b-b4bc-464d-b211-e708a1d9648c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c51936cb-a913-4c78-b5b8-fcdafb423580', '9d0386c5-faa6-4b3c-a306-911d5526153b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c51936cb-a913-4c78-b5b8-fcdafb423580', '3850a330-4de1-45cc-846e-4d02cd2a6079', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c51936cb-a913-4c78-b5b8-fcdafb423580', 'dd5e9468-4d79-4c93-9c16-a88f18b41fd0', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8c548a44-f772-433d-937e-b0e6276f8faf', '62fe58db-a728-4a3b-b954-297733392ecb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8c548a44-f772-433d-937e-b0e6276f8faf', 'd86b5af2-b2bf-4ffc-a507-363b95fe364a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8c548a44-f772-433d-937e-b0e6276f8faf', 'd95499ed-f35b-4a0d-9ebc-5999c26c11c6', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8c548a44-f772-433d-937e-b0e6276f8faf', '0e5f073b-b4bc-464d-b211-e708a1d9648c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8c548a44-f772-433d-937e-b0e6276f8faf', '9d0386c5-faa6-4b3c-a306-911d5526153b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('62fe58db-a728-4a3b-b954-297733392ecb', '8c548a44-f772-433d-937e-b0e6276f8faf', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('62fe58db-a728-4a3b-b954-297733392ecb', 'd86b5af2-b2bf-4ffc-a507-363b95fe364a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('62fe58db-a728-4a3b-b954-297733392ecb', 'd95499ed-f35b-4a0d-9ebc-5999c26c11c6', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('62fe58db-a728-4a3b-b954-297733392ecb', '0e5f073b-b4bc-464d-b211-e708a1d9648c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('62fe58db-a728-4a3b-b954-297733392ecb', '9d0386c5-faa6-4b3c-a306-911d5526153b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d86b5af2-b2bf-4ffc-a507-363b95fe364a', '8c548a44-f772-433d-937e-b0e6276f8faf', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d86b5af2-b2bf-4ffc-a507-363b95fe364a', '62fe58db-a728-4a3b-b954-297733392ecb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d86b5af2-b2bf-4ffc-a507-363b95fe364a', 'd95499ed-f35b-4a0d-9ebc-5999c26c11c6', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d86b5af2-b2bf-4ffc-a507-363b95fe364a', '0e5f073b-b4bc-464d-b211-e708a1d9648c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d86b5af2-b2bf-4ffc-a507-363b95fe364a', '9d0386c5-faa6-4b3c-a306-911d5526153b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6af5f3ff-e735-4682-b02c-712a57840695', 'd95499ed-f35b-4a0d-9ebc-5999c26c11c6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6af5f3ff-e735-4682-b02c-712a57840695', '0e5f073b-b4bc-464d-b211-e708a1d9648c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6af5f3ff-e735-4682-b02c-712a57840695', '9d0386c5-faa6-4b3c-a306-911d5526153b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6af5f3ff-e735-4682-b02c-712a57840695', '3850a330-4de1-45cc-846e-4d02cd2a6079', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6af5f3ff-e735-4682-b02c-712a57840695', 'dd5e9468-4d79-4c93-9c16-a88f18b41fd0', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('928027c3-5ab0-49dc-9da7-331acd888ea7', '70dbf46c-ffd0-44c4-9a4c-8789c6a92a18', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('928027c3-5ab0-49dc-9da7-331acd888ea7', 'd95499ed-f35b-4a0d-9ebc-5999c26c11c6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('928027c3-5ab0-49dc-9da7-331acd888ea7', '0e5f073b-b4bc-464d-b211-e708a1d9648c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e1a83a54-088d-474a-8213-577afb26e52d', 'd95499ed-f35b-4a0d-9ebc-5999c26c11c6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e1a83a54-088d-474a-8213-577afb26e52d', '0e5f073b-b4bc-464d-b211-e708a1d9648c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e1a83a54-088d-474a-8213-577afb26e52d', '9d0386c5-faa6-4b3c-a306-911d5526153b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e1a83a54-088d-474a-8213-577afb26e52d', '3850a330-4de1-45cc-846e-4d02cd2a6079', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e1a83a54-088d-474a-8213-577afb26e52d', 'dd5e9468-4d79-4c93-9c16-a88f18b41fd0', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('70dbf46c-ffd0-44c4-9a4c-8789c6a92a18', '928027c3-5ab0-49dc-9da7-331acd888ea7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('70dbf46c-ffd0-44c4-9a4c-8789c6a92a18', 'd95499ed-f35b-4a0d-9ebc-5999c26c11c6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('70dbf46c-ffd0-44c4-9a4c-8789c6a92a18', '0e5f073b-b4bc-464d-b211-e708a1d9648c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0d713ac4-c294-4d89-86a3-7156f826f61d', 'd95499ed-f35b-4a0d-9ebc-5999c26c11c6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0d713ac4-c294-4d89-86a3-7156f826f61d', '0e5f073b-b4bc-464d-b211-e708a1d9648c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0d713ac4-c294-4d89-86a3-7156f826f61d', '9d0386c5-faa6-4b3c-a306-911d5526153b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0d713ac4-c294-4d89-86a3-7156f826f61d', '3850a330-4de1-45cc-846e-4d02cd2a6079', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0d713ac4-c294-4d89-86a3-7156f826f61d', 'dd5e9468-4d79-4c93-9c16-a88f18b41fd0', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d04808ee-0ed5-4fda-a6fc-af49e3e909e8', 'd95499ed-f35b-4a0d-9ebc-5999c26c11c6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d04808ee-0ed5-4fda-a6fc-af49e3e909e8', '0e5f073b-b4bc-464d-b211-e708a1d9648c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d04808ee-0ed5-4fda-a6fc-af49e3e909e8', '9d0386c5-faa6-4b3c-a306-911d5526153b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d04808ee-0ed5-4fda-a6fc-af49e3e909e8', '3850a330-4de1-45cc-846e-4d02cd2a6079', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d04808ee-0ed5-4fda-a6fc-af49e3e909e8', 'dd5e9468-4d79-4c93-9c16-a88f18b41fd0', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6dcd222a-15c8-4e52-ad9e-f6118e0744c2', 'ccc20310-504e-4cf2-83b4-36fe1233bfad', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6dcd222a-15c8-4e52-ad9e-f6118e0744c2', '456ce182-d6ef-4643-b3bf-2aef3085ba44', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6dcd222a-15c8-4e52-ad9e-f6118e0744c2', '6bf87f2b-1511-4233-8f46-b8df00093551', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6dcd222a-15c8-4e52-ad9e-f6118e0744c2', '2da858b9-250a-4b37-a5a7-b45a8f38d313', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6dcd222a-15c8-4e52-ad9e-f6118e0744c2', '33318523-7f14-425e-99c9-28e305018a8e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ccc20310-504e-4cf2-83b4-36fe1233bfad', '6dcd222a-15c8-4e52-ad9e-f6118e0744c2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ccc20310-504e-4cf2-83b4-36fe1233bfad', '456ce182-d6ef-4643-b3bf-2aef3085ba44', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ccc20310-504e-4cf2-83b4-36fe1233bfad', '6bf87f2b-1511-4233-8f46-b8df00093551', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ccc20310-504e-4cf2-83b4-36fe1233bfad', '2da858b9-250a-4b37-a5a7-b45a8f38d313', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ccc20310-504e-4cf2-83b4-36fe1233bfad', '33318523-7f14-425e-99c9-28e305018a8e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('456ce182-d6ef-4643-b3bf-2aef3085ba44', '6dcd222a-15c8-4e52-ad9e-f6118e0744c2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('456ce182-d6ef-4643-b3bf-2aef3085ba44', 'ccc20310-504e-4cf2-83b4-36fe1233bfad', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('456ce182-d6ef-4643-b3bf-2aef3085ba44', '6bf87f2b-1511-4233-8f46-b8df00093551', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('456ce182-d6ef-4643-b3bf-2aef3085ba44', '2da858b9-250a-4b37-a5a7-b45a8f38d313', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('456ce182-d6ef-4643-b3bf-2aef3085ba44', '33318523-7f14-425e-99c9-28e305018a8e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6bf87f2b-1511-4233-8f46-b8df00093551', '2da858b9-250a-4b37-a5a7-b45a8f38d313', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6bf87f2b-1511-4233-8f46-b8df00093551', '33318523-7f14-425e-99c9-28e305018a8e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6bf87f2b-1511-4233-8f46-b8df00093551', '1c60aa43-0028-4f23-85e5-b9c651b9935f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6bf87f2b-1511-4233-8f46-b8df00093551', 'b7bc7c71-1822-4473-ae18-ee167993d683', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6bf87f2b-1511-4233-8f46-b8df00093551', 'c6c39e07-ea81-476b-80b6-da1d2a6b4496', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('223fc80a-61ac-4eee-9352-20440662adae', '94a9deee-9435-4667-b094-cbbf6980f288', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('223fc80a-61ac-4eee-9352-20440662adae', 'bc61274e-ed7f-4888-b7d3-0667a41c6ab6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('223fc80a-61ac-4eee-9352-20440662adae', '4012e0b9-9945-4e41-aa67-6f5d0e5d6b35', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2da858b9-250a-4b37-a5a7-b45a8f38d313', '6bf87f2b-1511-4233-8f46-b8df00093551', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2da858b9-250a-4b37-a5a7-b45a8f38d313', '33318523-7f14-425e-99c9-28e305018a8e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2da858b9-250a-4b37-a5a7-b45a8f38d313', '1c60aa43-0028-4f23-85e5-b9c651b9935f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2da858b9-250a-4b37-a5a7-b45a8f38d313', 'b7bc7c71-1822-4473-ae18-ee167993d683', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2da858b9-250a-4b37-a5a7-b45a8f38d313', 'c6c39e07-ea81-476b-80b6-da1d2a6b4496', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('33318523-7f14-425e-99c9-28e305018a8e', '6bf87f2b-1511-4233-8f46-b8df00093551', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('33318523-7f14-425e-99c9-28e305018a8e', '2da858b9-250a-4b37-a5a7-b45a8f38d313', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('33318523-7f14-425e-99c9-28e305018a8e', '1c60aa43-0028-4f23-85e5-b9c651b9935f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('33318523-7f14-425e-99c9-28e305018a8e', 'b7bc7c71-1822-4473-ae18-ee167993d683', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('33318523-7f14-425e-99c9-28e305018a8e', 'c6c39e07-ea81-476b-80b6-da1d2a6b4496', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1c60aa43-0028-4f23-85e5-b9c651b9935f', '6bf87f2b-1511-4233-8f46-b8df00093551', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1c60aa43-0028-4f23-85e5-b9c651b9935f', '2da858b9-250a-4b37-a5a7-b45a8f38d313', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1c60aa43-0028-4f23-85e5-b9c651b9935f', '33318523-7f14-425e-99c9-28e305018a8e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1c60aa43-0028-4f23-85e5-b9c651b9935f', 'b7bc7c71-1822-4473-ae18-ee167993d683', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1c60aa43-0028-4f23-85e5-b9c651b9935f', 'c6c39e07-ea81-476b-80b6-da1d2a6b4496', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7bc7c71-1822-4473-ae18-ee167993d683', '6bf87f2b-1511-4233-8f46-b8df00093551', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7bc7c71-1822-4473-ae18-ee167993d683', '2da858b9-250a-4b37-a5a7-b45a8f38d313', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7bc7c71-1822-4473-ae18-ee167993d683', '33318523-7f14-425e-99c9-28e305018a8e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7bc7c71-1822-4473-ae18-ee167993d683', '1c60aa43-0028-4f23-85e5-b9c651b9935f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7bc7c71-1822-4473-ae18-ee167993d683', 'c6c39e07-ea81-476b-80b6-da1d2a6b4496', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6c39e07-ea81-476b-80b6-da1d2a6b4496', '6bf87f2b-1511-4233-8f46-b8df00093551', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6c39e07-ea81-476b-80b6-da1d2a6b4496', '2da858b9-250a-4b37-a5a7-b45a8f38d313', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6c39e07-ea81-476b-80b6-da1d2a6b4496', '33318523-7f14-425e-99c9-28e305018a8e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6c39e07-ea81-476b-80b6-da1d2a6b4496', '1c60aa43-0028-4f23-85e5-b9c651b9935f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6c39e07-ea81-476b-80b6-da1d2a6b4496', 'b7bc7c71-1822-4473-ae18-ee167993d683', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e5779ed4-1c1d-4c73-8cd2-a14eb3f85b5a', '6bf87f2b-1511-4233-8f46-b8df00093551', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e5779ed4-1c1d-4c73-8cd2-a14eb3f85b5a', '2da858b9-250a-4b37-a5a7-b45a8f38d313', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e5779ed4-1c1d-4c73-8cd2-a14eb3f85b5a', '33318523-7f14-425e-99c9-28e305018a8e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e5779ed4-1c1d-4c73-8cd2-a14eb3f85b5a', '1c60aa43-0028-4f23-85e5-b9c651b9935f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e5779ed4-1c1d-4c73-8cd2-a14eb3f85b5a', 'b7bc7c71-1822-4473-ae18-ee167993d683', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('50d565f4-6eff-463e-9fd6-261ed244295c', '6bf87f2b-1511-4233-8f46-b8df00093551', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('50d565f4-6eff-463e-9fd6-261ed244295c', '2da858b9-250a-4b37-a5a7-b45a8f38d313', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('50d565f4-6eff-463e-9fd6-261ed244295c', '33318523-7f14-425e-99c9-28e305018a8e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('50d565f4-6eff-463e-9fd6-261ed244295c', '1c60aa43-0028-4f23-85e5-b9c651b9935f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('50d565f4-6eff-463e-9fd6-261ed244295c', 'b7bc7c71-1822-4473-ae18-ee167993d683', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d64b40e5-ac5f-405f-98dc-63c19273310d', '6bf87f2b-1511-4233-8f46-b8df00093551', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d64b40e5-ac5f-405f-98dc-63c19273310d', '2da858b9-250a-4b37-a5a7-b45a8f38d313', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d64b40e5-ac5f-405f-98dc-63c19273310d', '33318523-7f14-425e-99c9-28e305018a8e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d64b40e5-ac5f-405f-98dc-63c19273310d', '1c60aa43-0028-4f23-85e5-b9c651b9935f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d64b40e5-ac5f-405f-98dc-63c19273310d', 'b7bc7c71-1822-4473-ae18-ee167993d683', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('63e124d1-f58d-4bc4-9250-ed24782a7229', '6bf87f2b-1511-4233-8f46-b8df00093551', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('63e124d1-f58d-4bc4-9250-ed24782a7229', '2da858b9-250a-4b37-a5a7-b45a8f38d313', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('63e124d1-f58d-4bc4-9250-ed24782a7229', '33318523-7f14-425e-99c9-28e305018a8e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('63e124d1-f58d-4bc4-9250-ed24782a7229', '1c60aa43-0028-4f23-85e5-b9c651b9935f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('63e124d1-f58d-4bc4-9250-ed24782a7229', 'b7bc7c71-1822-4473-ae18-ee167993d683', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b562d5c-07a0-46ab-964d-b63f21946845', '6dcd222a-15c8-4e52-ad9e-f6118e0744c2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b562d5c-07a0-46ab-964d-b63f21946845', 'ccc20310-504e-4cf2-83b4-36fe1233bfad', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b562d5c-07a0-46ab-964d-b63f21946845', '456ce182-d6ef-4643-b3bf-2aef3085ba44', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b562d5c-07a0-46ab-964d-b63f21946845', '6bf87f2b-1511-4233-8f46-b8df00093551', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b562d5c-07a0-46ab-964d-b63f21946845', '2da858b9-250a-4b37-a5a7-b45a8f38d313', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0e8cd1a3-18d7-4738-91df-40a7142882cd', 'c18c7bab-c1ac-4be4-b6bd-15627bed54bd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0e8cd1a3-18d7-4738-91df-40a7142882cd', 'a2a57441-334a-4bf5-8ea4-be0c94fecc52', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0e8cd1a3-18d7-4738-91df-40a7142882cd', 'c225888d-5bb7-43db-9a49-d125ee1509f3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0e8cd1a3-18d7-4738-91df-40a7142882cd', '671295c8-fb09-4fe0-8d05-8e86d3deab3b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0e8cd1a3-18d7-4738-91df-40a7142882cd', 'd5d107d0-eb45-4612-9890-5a03bca40518', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c18c7bab-c1ac-4be4-b6bd-15627bed54bd', '0e8cd1a3-18d7-4738-91df-40a7142882cd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c18c7bab-c1ac-4be4-b6bd-15627bed54bd', 'a2a57441-334a-4bf5-8ea4-be0c94fecc52', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c18c7bab-c1ac-4be4-b6bd-15627bed54bd', 'c225888d-5bb7-43db-9a49-d125ee1509f3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c18c7bab-c1ac-4be4-b6bd-15627bed54bd', '671295c8-fb09-4fe0-8d05-8e86d3deab3b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c18c7bab-c1ac-4be4-b6bd-15627bed54bd', 'd5d107d0-eb45-4612-9890-5a03bca40518', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0382781-165b-4281-a511-34bf0260bc25', 'c18c7bab-c1ac-4be4-b6bd-15627bed54bd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0382781-165b-4281-a511-34bf0260bc25', '0e8cd1a3-18d7-4738-91df-40a7142882cd', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0382781-165b-4281-a511-34bf0260bc25', 'a2a57441-334a-4bf5-8ea4-be0c94fecc52', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0382781-165b-4281-a511-34bf0260bc25', 'c225888d-5bb7-43db-9a49-d125ee1509f3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0382781-165b-4281-a511-34bf0260bc25', '671295c8-fb09-4fe0-8d05-8e86d3deab3b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a2a57441-334a-4bf5-8ea4-be0c94fecc52', 'd9210945-0354-4cf9-9e1b-56c3f3287c97', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a2a57441-334a-4bf5-8ea4-be0c94fecc52', 'b4a6e601-23d5-44cb-99bb-a8881a9d6259', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a2a57441-334a-4bf5-8ea4-be0c94fecc52', '45b7f847-405f-4264-b702-126b71fbf1d2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a2a57441-334a-4bf5-8ea4-be0c94fecc52', '0e8cd1a3-18d7-4738-91df-40a7142882cd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a2a57441-334a-4bf5-8ea4-be0c94fecc52', 'c18c7bab-c1ac-4be4-b6bd-15627bed54bd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c225888d-5bb7-43db-9a49-d125ee1509f3', '671295c8-fb09-4fe0-8d05-8e86d3deab3b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c225888d-5bb7-43db-9a49-d125ee1509f3', 'd5d107d0-eb45-4612-9890-5a03bca40518', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c225888d-5bb7-43db-9a49-d125ee1509f3', '864d3b50-edf3-4efb-b2b9-60c65cb9e1a8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c225888d-5bb7-43db-9a49-d125ee1509f3', '21040500-b163-4372-87df-cd65a8ed6b27', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c225888d-5bb7-43db-9a49-d125ee1509f3', '0e8cd1a3-18d7-4738-91df-40a7142882cd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('671295c8-fb09-4fe0-8d05-8e86d3deab3b', 'c225888d-5bb7-43db-9a49-d125ee1509f3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('671295c8-fb09-4fe0-8d05-8e86d3deab3b', 'd5d107d0-eb45-4612-9890-5a03bca40518', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('671295c8-fb09-4fe0-8d05-8e86d3deab3b', '864d3b50-edf3-4efb-b2b9-60c65cb9e1a8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('671295c8-fb09-4fe0-8d05-8e86d3deab3b', '21040500-b163-4372-87df-cd65a8ed6b27', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('671295c8-fb09-4fe0-8d05-8e86d3deab3b', '0e8cd1a3-18d7-4738-91df-40a7142882cd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d5d107d0-eb45-4612-9890-5a03bca40518', 'c225888d-5bb7-43db-9a49-d125ee1509f3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d5d107d0-eb45-4612-9890-5a03bca40518', '671295c8-fb09-4fe0-8d05-8e86d3deab3b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d5d107d0-eb45-4612-9890-5a03bca40518', '864d3b50-edf3-4efb-b2b9-60c65cb9e1a8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d5d107d0-eb45-4612-9890-5a03bca40518', '21040500-b163-4372-87df-cd65a8ed6b27', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d5d107d0-eb45-4612-9890-5a03bca40518', '0e8cd1a3-18d7-4738-91df-40a7142882cd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d9210945-0354-4cf9-9e1b-56c3f3287c97', 'a2a57441-334a-4bf5-8ea4-be0c94fecc52', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d9210945-0354-4cf9-9e1b-56c3f3287c97', 'b4a6e601-23d5-44cb-99bb-a8881a9d6259', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d9210945-0354-4cf9-9e1b-56c3f3287c97', '45b7f847-405f-4264-b702-126b71fbf1d2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d9210945-0354-4cf9-9e1b-56c3f3287c97', '0e8cd1a3-18d7-4738-91df-40a7142882cd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d9210945-0354-4cf9-9e1b-56c3f3287c97', 'c18c7bab-c1ac-4be4-b6bd-15627bed54bd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b4a6e601-23d5-44cb-99bb-a8881a9d6259', 'a2a57441-334a-4bf5-8ea4-be0c94fecc52', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b4a6e601-23d5-44cb-99bb-a8881a9d6259', 'd9210945-0354-4cf9-9e1b-56c3f3287c97', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b4a6e601-23d5-44cb-99bb-a8881a9d6259', '45b7f847-405f-4264-b702-126b71fbf1d2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b4a6e601-23d5-44cb-99bb-a8881a9d6259', '0e8cd1a3-18d7-4738-91df-40a7142882cd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b4a6e601-23d5-44cb-99bb-a8881a9d6259', 'c18c7bab-c1ac-4be4-b6bd-15627bed54bd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('864d3b50-edf3-4efb-b2b9-60c65cb9e1a8', 'c225888d-5bb7-43db-9a49-d125ee1509f3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('864d3b50-edf3-4efb-b2b9-60c65cb9e1a8', '671295c8-fb09-4fe0-8d05-8e86d3deab3b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('864d3b50-edf3-4efb-b2b9-60c65cb9e1a8', 'd5d107d0-eb45-4612-9890-5a03bca40518', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('864d3b50-edf3-4efb-b2b9-60c65cb9e1a8', '21040500-b163-4372-87df-cd65a8ed6b27', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('864d3b50-edf3-4efb-b2b9-60c65cb9e1a8', '0e8cd1a3-18d7-4738-91df-40a7142882cd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('21040500-b163-4372-87df-cd65a8ed6b27', 'c225888d-5bb7-43db-9a49-d125ee1509f3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('21040500-b163-4372-87df-cd65a8ed6b27', '671295c8-fb09-4fe0-8d05-8e86d3deab3b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('21040500-b163-4372-87df-cd65a8ed6b27', 'd5d107d0-eb45-4612-9890-5a03bca40518', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('21040500-b163-4372-87df-cd65a8ed6b27', '864d3b50-edf3-4efb-b2b9-60c65cb9e1a8', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('21040500-b163-4372-87df-cd65a8ed6b27', '0e8cd1a3-18d7-4738-91df-40a7142882cd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45b7f847-405f-4264-b702-126b71fbf1d2', 'a2a57441-334a-4bf5-8ea4-be0c94fecc52', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45b7f847-405f-4264-b702-126b71fbf1d2', 'd9210945-0354-4cf9-9e1b-56c3f3287c97', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45b7f847-405f-4264-b702-126b71fbf1d2', 'b4a6e601-23d5-44cb-99bb-a8881a9d6259', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45b7f847-405f-4264-b702-126b71fbf1d2', '0e8cd1a3-18d7-4738-91df-40a7142882cd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45b7f847-405f-4264-b702-126b71fbf1d2', 'c18c7bab-c1ac-4be4-b6bd-15627bed54bd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('485566e2-e133-458f-ad0c-2b3b738cfff1', '6bf87f2b-1511-4233-8f46-b8df00093551', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('485566e2-e133-458f-ad0c-2b3b738cfff1', '2da858b9-250a-4b37-a5a7-b45a8f38d313', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('485566e2-e133-458f-ad0c-2b3b738cfff1', '33318523-7f14-425e-99c9-28e305018a8e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('485566e2-e133-458f-ad0c-2b3b738cfff1', '1c60aa43-0028-4f23-85e5-b9c651b9935f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('485566e2-e133-458f-ad0c-2b3b738cfff1', 'b7bc7c71-1822-4473-ae18-ee167993d683', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('29d1fc30-5a7d-4a69-952c-4b2fead804a5', '6dcd222a-15c8-4e52-ad9e-f6118e0744c2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('29d1fc30-5a7d-4a69-952c-4b2fead804a5', 'ccc20310-504e-4cf2-83b4-36fe1233bfad', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('29d1fc30-5a7d-4a69-952c-4b2fead804a5', '456ce182-d6ef-4643-b3bf-2aef3085ba44', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bc61274e-ed7f-4888-b7d3-0667a41c6ab6', '4012e0b9-9945-4e41-aa67-6f5d0e5d6b35', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bc61274e-ed7f-4888-b7d3-0667a41c6ab6', '98b807df-a89d-4ed8-b9e1-b25ce929bc68', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bc61274e-ed7f-4888-b7d3-0667a41c6ab6', '6046819d-8eba-4c1b-a778-86945d702a67', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4012e0b9-9945-4e41-aa67-6f5d0e5d6b35', 'bc61274e-ed7f-4888-b7d3-0667a41c6ab6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4012e0b9-9945-4e41-aa67-6f5d0e5d6b35', '98b807df-a89d-4ed8-b9e1-b25ce929bc68', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4012e0b9-9945-4e41-aa67-6f5d0e5d6b35', '6046819d-8eba-4c1b-a778-86945d702a67', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('98b807df-a89d-4ed8-b9e1-b25ce929bc68', 'bc61274e-ed7f-4888-b7d3-0667a41c6ab6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('98b807df-a89d-4ed8-b9e1-b25ce929bc68', '4012e0b9-9945-4e41-aa67-6f5d0e5d6b35', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('98b807df-a89d-4ed8-b9e1-b25ce929bc68', '6046819d-8eba-4c1b-a778-86945d702a67', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6046819d-8eba-4c1b-a778-86945d702a67', 'bc61274e-ed7f-4888-b7d3-0667a41c6ab6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6046819d-8eba-4c1b-a778-86945d702a67', '4012e0b9-9945-4e41-aa67-6f5d0e5d6b35', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6046819d-8eba-4c1b-a778-86945d702a67', '98b807df-a89d-4ed8-b9e1-b25ce929bc68', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba0a0824-b012-48a1-a69a-39964b81d0c0', '62049dfb-83e0-47b4-a791-a04a010fc934', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba0a0824-b012-48a1-a69a-39964b81d0c0', 'db2f10a3-437a-480f-abf8-1eb48a1014f3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba0a0824-b012-48a1-a69a-39964b81d0c0', '4dc86e8a-ea32-4b8b-ac90-583f73a4724f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba0a0824-b012-48a1-a69a-39964b81d0c0', '835f3c25-0dec-4df3-98b8-209ca4f6a0e6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba0a0824-b012-48a1-a69a-39964b81d0c0', 'cba4b6cd-b157-4dba-8cfe-30413f85df28', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('62049dfb-83e0-47b4-a791-a04a010fc934', 'ba0a0824-b012-48a1-a69a-39964b81d0c0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('62049dfb-83e0-47b4-a791-a04a010fc934', 'db2f10a3-437a-480f-abf8-1eb48a1014f3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('62049dfb-83e0-47b4-a791-a04a010fc934', '4dc86e8a-ea32-4b8b-ac90-583f73a4724f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('62049dfb-83e0-47b4-a791-a04a010fc934', '835f3c25-0dec-4df3-98b8-209ca4f6a0e6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('62049dfb-83e0-47b4-a791-a04a010fc934', 'cba4b6cd-b157-4dba-8cfe-30413f85df28', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('db2f10a3-437a-480f-abf8-1eb48a1014f3', 'ba0a0824-b012-48a1-a69a-39964b81d0c0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('db2f10a3-437a-480f-abf8-1eb48a1014f3', '62049dfb-83e0-47b4-a791-a04a010fc934', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('db2f10a3-437a-480f-abf8-1eb48a1014f3', '4dc86e8a-ea32-4b8b-ac90-583f73a4724f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('db2f10a3-437a-480f-abf8-1eb48a1014f3', '835f3c25-0dec-4df3-98b8-209ca4f6a0e6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('db2f10a3-437a-480f-abf8-1eb48a1014f3', 'cba4b6cd-b157-4dba-8cfe-30413f85df28', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4dc86e8a-ea32-4b8b-ac90-583f73a4724f', 'ba0a0824-b012-48a1-a69a-39964b81d0c0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4dc86e8a-ea32-4b8b-ac90-583f73a4724f', '62049dfb-83e0-47b4-a791-a04a010fc934', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4dc86e8a-ea32-4b8b-ac90-583f73a4724f', 'db2f10a3-437a-480f-abf8-1eb48a1014f3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4dc86e8a-ea32-4b8b-ac90-583f73a4724f', '835f3c25-0dec-4df3-98b8-209ca4f6a0e6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4dc86e8a-ea32-4b8b-ac90-583f73a4724f', 'cba4b6cd-b157-4dba-8cfe-30413f85df28', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('64e30faf-54bb-43f4-93d2-dd63c38edf9d', '0c34bad4-6d0f-43ac-b06f-2cf6b3f11f37', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('64e30faf-54bb-43f4-93d2-dd63c38edf9d', 'ba0a0824-b012-48a1-a69a-39964b81d0c0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('64e30faf-54bb-43f4-93d2-dd63c38edf9d', '62049dfb-83e0-47b4-a791-a04a010fc934', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('64e30faf-54bb-43f4-93d2-dd63c38edf9d', 'db2f10a3-437a-480f-abf8-1eb48a1014f3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('64e30faf-54bb-43f4-93d2-dd63c38edf9d', '4dc86e8a-ea32-4b8b-ac90-583f73a4724f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c34bad4-6d0f-43ac-b06f-2cf6b3f11f37', '64e30faf-54bb-43f4-93d2-dd63c38edf9d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c34bad4-6d0f-43ac-b06f-2cf6b3f11f37', 'ba0a0824-b012-48a1-a69a-39964b81d0c0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c34bad4-6d0f-43ac-b06f-2cf6b3f11f37', '62049dfb-83e0-47b4-a791-a04a010fc934', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c34bad4-6d0f-43ac-b06f-2cf6b3f11f37', 'db2f10a3-437a-480f-abf8-1eb48a1014f3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c34bad4-6d0f-43ac-b06f-2cf6b3f11f37', '4dc86e8a-ea32-4b8b-ac90-583f73a4724f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('835f3c25-0dec-4df3-98b8-209ca4f6a0e6', 'ba0a0824-b012-48a1-a69a-39964b81d0c0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('835f3c25-0dec-4df3-98b8-209ca4f6a0e6', '62049dfb-83e0-47b4-a791-a04a010fc934', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('835f3c25-0dec-4df3-98b8-209ca4f6a0e6', 'db2f10a3-437a-480f-abf8-1eb48a1014f3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('835f3c25-0dec-4df3-98b8-209ca4f6a0e6', '4dc86e8a-ea32-4b8b-ac90-583f73a4724f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('835f3c25-0dec-4df3-98b8-209ca4f6a0e6', 'cba4b6cd-b157-4dba-8cfe-30413f85df28', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cba4b6cd-b157-4dba-8cfe-30413f85df28', 'ba0a0824-b012-48a1-a69a-39964b81d0c0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cba4b6cd-b157-4dba-8cfe-30413f85df28', '62049dfb-83e0-47b4-a791-a04a010fc934', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cba4b6cd-b157-4dba-8cfe-30413f85df28', 'db2f10a3-437a-480f-abf8-1eb48a1014f3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cba4b6cd-b157-4dba-8cfe-30413f85df28', '4dc86e8a-ea32-4b8b-ac90-583f73a4724f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cba4b6cd-b157-4dba-8cfe-30413f85df28', '835f3c25-0dec-4df3-98b8-209ca4f6a0e6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('41edc4c4-de3e-486e-832f-f55b167bd343', '223fc80a-61ac-4eee-9352-20440662adae', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('41edc4c4-de3e-486e-832f-f55b167bd343', 'bc61274e-ed7f-4888-b7d3-0667a41c6ab6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('41edc4c4-de3e-486e-832f-f55b167bd343', '4012e0b9-9945-4e41-aa67-6f5d0e5d6b35', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d9eb5102-51e3-4582-b72b-2ff5c9d45db6', 'ba0a0824-b012-48a1-a69a-39964b81d0c0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d9eb5102-51e3-4582-b72b-2ff5c9d45db6', '62049dfb-83e0-47b4-a791-a04a010fc934', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d9eb5102-51e3-4582-b72b-2ff5c9d45db6', 'db2f10a3-437a-480f-abf8-1eb48a1014f3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d9eb5102-51e3-4582-b72b-2ff5c9d45db6', '4dc86e8a-ea32-4b8b-ac90-583f73a4724f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d9eb5102-51e3-4582-b72b-2ff5c9d45db6', '64e30faf-54bb-43f4-93d2-dd63c38edf9d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('94a9deee-9435-4667-b094-cbbf6980f288', '223fc80a-61ac-4eee-9352-20440662adae', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('94a9deee-9435-4667-b094-cbbf6980f288', 'bc61274e-ed7f-4888-b7d3-0667a41c6ab6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('94a9deee-9435-4667-b094-cbbf6980f288', '4012e0b9-9945-4e41-aa67-6f5d0e5d6b35', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7e75f438-b7e3-4e68-bb62-9595b4f87ea4', 'aa08f6c7-7555-456a-bfc0-0a8ef71d7b99', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7e75f438-b7e3-4e68-bb62-9595b4f87ea4', '7a37758c-5aa3-4683-8bd1-0524740a393d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7e75f438-b7e3-4e68-bb62-9595b4f87ea4', '89447648-d923-446b-8037-02dbb64da76b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7e75f438-b7e3-4e68-bb62-9595b4f87ea4', '4621b5c6-eeb2-4049-a6a1-e5256380f9e5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7e75f438-b7e3-4e68-bb62-9595b4f87ea4', 'baa701ee-e22f-4855-861f-c83f0a0cd87e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('997a2f6b-93ff-4676-91c7-3c4423f6ff11', '46a8f7ff-8155-42df-8d69-ec338320df73', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('997a2f6b-93ff-4676-91c7-3c4423f6ff11', '7e75f438-b7e3-4e68-bb62-9595b4f87ea4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('997a2f6b-93ff-4676-91c7-3c4423f6ff11', 'aa08f6c7-7555-456a-bfc0-0a8ef71d7b99', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('997a2f6b-93ff-4676-91c7-3c4423f6ff11', '7a37758c-5aa3-4683-8bd1-0524740a393d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('997a2f6b-93ff-4676-91c7-3c4423f6ff11', '89447648-d923-446b-8037-02dbb64da76b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aa08f6c7-7555-456a-bfc0-0a8ef71d7b99', '7e75f438-b7e3-4e68-bb62-9595b4f87ea4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aa08f6c7-7555-456a-bfc0-0a8ef71d7b99', '7a37758c-5aa3-4683-8bd1-0524740a393d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aa08f6c7-7555-456a-bfc0-0a8ef71d7b99', '89447648-d923-446b-8037-02dbb64da76b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aa08f6c7-7555-456a-bfc0-0a8ef71d7b99', '4621b5c6-eeb2-4049-a6a1-e5256380f9e5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aa08f6c7-7555-456a-bfc0-0a8ef71d7b99', 'baa701ee-e22f-4855-861f-c83f0a0cd87e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a37758c-5aa3-4683-8bd1-0524740a393d', '7e75f438-b7e3-4e68-bb62-9595b4f87ea4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a37758c-5aa3-4683-8bd1-0524740a393d', 'aa08f6c7-7555-456a-bfc0-0a8ef71d7b99', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a37758c-5aa3-4683-8bd1-0524740a393d', '89447648-d923-446b-8037-02dbb64da76b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a37758c-5aa3-4683-8bd1-0524740a393d', '4621b5c6-eeb2-4049-a6a1-e5256380f9e5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a37758c-5aa3-4683-8bd1-0524740a393d', 'baa701ee-e22f-4855-861f-c83f0a0cd87e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89447648-d923-446b-8037-02dbb64da76b', '7e75f438-b7e3-4e68-bb62-9595b4f87ea4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89447648-d923-446b-8037-02dbb64da76b', 'aa08f6c7-7555-456a-bfc0-0a8ef71d7b99', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89447648-d923-446b-8037-02dbb64da76b', '7a37758c-5aa3-4683-8bd1-0524740a393d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89447648-d923-446b-8037-02dbb64da76b', '4621b5c6-eeb2-4049-a6a1-e5256380f9e5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89447648-d923-446b-8037-02dbb64da76b', 'baa701ee-e22f-4855-861f-c83f0a0cd87e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4621b5c6-eeb2-4049-a6a1-e5256380f9e5', '7e75f438-b7e3-4e68-bb62-9595b4f87ea4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4621b5c6-eeb2-4049-a6a1-e5256380f9e5', 'aa08f6c7-7555-456a-bfc0-0a8ef71d7b99', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4621b5c6-eeb2-4049-a6a1-e5256380f9e5', '7a37758c-5aa3-4683-8bd1-0524740a393d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4621b5c6-eeb2-4049-a6a1-e5256380f9e5', '89447648-d923-446b-8037-02dbb64da76b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4621b5c6-eeb2-4049-a6a1-e5256380f9e5', 'baa701ee-e22f-4855-861f-c83f0a0cd87e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('baa701ee-e22f-4855-861f-c83f0a0cd87e', '7e75f438-b7e3-4e68-bb62-9595b4f87ea4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('baa701ee-e22f-4855-861f-c83f0a0cd87e', 'aa08f6c7-7555-456a-bfc0-0a8ef71d7b99', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('baa701ee-e22f-4855-861f-c83f0a0cd87e', '7a37758c-5aa3-4683-8bd1-0524740a393d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('baa701ee-e22f-4855-861f-c83f0a0cd87e', '89447648-d923-446b-8037-02dbb64da76b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('baa701ee-e22f-4855-861f-c83f0a0cd87e', '4621b5c6-eeb2-4049-a6a1-e5256380f9e5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('99703a9e-fae4-4ea3-97bb-ebc27188c323', '226cda52-ac67-42b6-ba68-eceb3eeb5dbb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('99703a9e-fae4-4ea3-97bb-ebc27188c323', '7e75f438-b7e3-4e68-bb62-9595b4f87ea4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('99703a9e-fae4-4ea3-97bb-ebc27188c323', '997a2f6b-93ff-4676-91c7-3c4423f6ff11', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('99703a9e-fae4-4ea3-97bb-ebc27188c323', 'aa08f6c7-7555-456a-bfc0-0a8ef71d7b99', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('99703a9e-fae4-4ea3-97bb-ebc27188c323', '7a37758c-5aa3-4683-8bd1-0524740a393d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('226cda52-ac67-42b6-ba68-eceb3eeb5dbb', '99703a9e-fae4-4ea3-97bb-ebc27188c323', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('226cda52-ac67-42b6-ba68-eceb3eeb5dbb', '7e75f438-b7e3-4e68-bb62-9595b4f87ea4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('226cda52-ac67-42b6-ba68-eceb3eeb5dbb', '997a2f6b-93ff-4676-91c7-3c4423f6ff11', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('226cda52-ac67-42b6-ba68-eceb3eeb5dbb', 'aa08f6c7-7555-456a-bfc0-0a8ef71d7b99', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('226cda52-ac67-42b6-ba68-eceb3eeb5dbb', '7a37758c-5aa3-4683-8bd1-0524740a393d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('edd16988-a266-427e-a638-f18f755320e4', '7e75f438-b7e3-4e68-bb62-9595b4f87ea4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('edd16988-a266-427e-a638-f18f755320e4', 'aa08f6c7-7555-456a-bfc0-0a8ef71d7b99', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('edd16988-a266-427e-a638-f18f755320e4', '7a37758c-5aa3-4683-8bd1-0524740a393d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('edd16988-a266-427e-a638-f18f755320e4', '89447648-d923-446b-8037-02dbb64da76b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('edd16988-a266-427e-a638-f18f755320e4', '4621b5c6-eeb2-4049-a6a1-e5256380f9e5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e6ed5d60-7576-4447-a979-440fbf835de3', '7e75f438-b7e3-4e68-bb62-9595b4f87ea4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e6ed5d60-7576-4447-a979-440fbf835de3', 'aa08f6c7-7555-456a-bfc0-0a8ef71d7b99', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e6ed5d60-7576-4447-a979-440fbf835de3', '7a37758c-5aa3-4683-8bd1-0524740a393d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e6ed5d60-7576-4447-a979-440fbf835de3', '89447648-d923-446b-8037-02dbb64da76b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e6ed5d60-7576-4447-a979-440fbf835de3', '4621b5c6-eeb2-4049-a6a1-e5256380f9e5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('46a8f7ff-8155-42df-8d69-ec338320df73', '997a2f6b-93ff-4676-91c7-3c4423f6ff11', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('46a8f7ff-8155-42df-8d69-ec338320df73', '7e75f438-b7e3-4e68-bb62-9595b4f87ea4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('46a8f7ff-8155-42df-8d69-ec338320df73', 'aa08f6c7-7555-456a-bfc0-0a8ef71d7b99', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('46a8f7ff-8155-42df-8d69-ec338320df73', '7a37758c-5aa3-4683-8bd1-0524740a393d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('46a8f7ff-8155-42df-8d69-ec338320df73', '89447648-d923-446b-8037-02dbb64da76b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9f5f48d-584f-4415-98c4-dfb8a01c2eb4', '7e75f438-b7e3-4e68-bb62-9595b4f87ea4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9f5f48d-584f-4415-98c4-dfb8a01c2eb4', 'aa08f6c7-7555-456a-bfc0-0a8ef71d7b99', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9f5f48d-584f-4415-98c4-dfb8a01c2eb4', '7a37758c-5aa3-4683-8bd1-0524740a393d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9f5f48d-584f-4415-98c4-dfb8a01c2eb4', '89447648-d923-446b-8037-02dbb64da76b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9f5f48d-584f-4415-98c4-dfb8a01c2eb4', '4621b5c6-eeb2-4049-a6a1-e5256380f9e5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3ef04288-5165-4210-82d9-93a103056dc3', 'ca22273b-2a14-4434-9d4a-5dd70ec6f410', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3ef04288-5165-4210-82d9-93a103056dc3', '5dc93b1f-2ad9-42ed-9799-3db68751d634', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3ef04288-5165-4210-82d9-93a103056dc3', '56155486-dca5-49b4-99ea-4e6f7b208599', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3ef04288-5165-4210-82d9-93a103056dc3', '7ab458a9-0c25-465e-becf-8f353c485a4f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3ef04288-5165-4210-82d9-93a103056dc3', '29a837c0-d73c-4a2b-b956-7b8773d622a3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5dc93b1f-2ad9-42ed-9799-3db68751d634', '3ef04288-5165-4210-82d9-93a103056dc3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5dc93b1f-2ad9-42ed-9799-3db68751d634', '56155486-dca5-49b4-99ea-4e6f7b208599', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5dc93b1f-2ad9-42ed-9799-3db68751d634', '7ab458a9-0c25-465e-becf-8f353c485a4f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5dc93b1f-2ad9-42ed-9799-3db68751d634', '29a837c0-d73c-4a2b-b956-7b8773d622a3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5dc93b1f-2ad9-42ed-9799-3db68751d634', 'a0b9049b-f014-4883-8740-c16b237e5a11', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('56155486-dca5-49b4-99ea-4e6f7b208599', '3ef04288-5165-4210-82d9-93a103056dc3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('56155486-dca5-49b4-99ea-4e6f7b208599', '5dc93b1f-2ad9-42ed-9799-3db68751d634', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('56155486-dca5-49b4-99ea-4e6f7b208599', '7ab458a9-0c25-465e-becf-8f353c485a4f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('56155486-dca5-49b4-99ea-4e6f7b208599', '29a837c0-d73c-4a2b-b956-7b8773d622a3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('56155486-dca5-49b4-99ea-4e6f7b208599', 'a0b9049b-f014-4883-8740-c16b237e5a11', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7ab458a9-0c25-465e-becf-8f353c485a4f', '29a837c0-d73c-4a2b-b956-7b8773d622a3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7ab458a9-0c25-465e-becf-8f353c485a4f', 'a0b9049b-f014-4883-8740-c16b237e5a11', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7ab458a9-0c25-465e-becf-8f353c485a4f', '0d4952fe-05fa-494e-a169-cb4bc0fc7dad', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7ab458a9-0c25-465e-becf-8f353c485a4f', '3ef04288-5165-4210-82d9-93a103056dc3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7ab458a9-0c25-465e-becf-8f353c485a4f', '5dc93b1f-2ad9-42ed-9799-3db68751d634', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('29a837c0-d73c-4a2b-b956-7b8773d622a3', '7ab458a9-0c25-465e-becf-8f353c485a4f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('29a837c0-d73c-4a2b-b956-7b8773d622a3', 'a0b9049b-f014-4883-8740-c16b237e5a11', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('29a837c0-d73c-4a2b-b956-7b8773d622a3', '0d4952fe-05fa-494e-a169-cb4bc0fc7dad', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('29a837c0-d73c-4a2b-b956-7b8773d622a3', '3ef04288-5165-4210-82d9-93a103056dc3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('29a837c0-d73c-4a2b-b956-7b8773d622a3', '5dc93b1f-2ad9-42ed-9799-3db68751d634', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0b9049b-f014-4883-8740-c16b237e5a11', '7ab458a9-0c25-465e-becf-8f353c485a4f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0b9049b-f014-4883-8740-c16b237e5a11', '29a837c0-d73c-4a2b-b956-7b8773d622a3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0b9049b-f014-4883-8740-c16b237e5a11', '0d4952fe-05fa-494e-a169-cb4bc0fc7dad', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0b9049b-f014-4883-8740-c16b237e5a11', '3ef04288-5165-4210-82d9-93a103056dc3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0b9049b-f014-4883-8740-c16b237e5a11', '5dc93b1f-2ad9-42ed-9799-3db68751d634', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0d4952fe-05fa-494e-a169-cb4bc0fc7dad', '7ab458a9-0c25-465e-becf-8f353c485a4f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0d4952fe-05fa-494e-a169-cb4bc0fc7dad', '29a837c0-d73c-4a2b-b956-7b8773d622a3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0d4952fe-05fa-494e-a169-cb4bc0fc7dad', 'a0b9049b-f014-4883-8740-c16b237e5a11', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0d4952fe-05fa-494e-a169-cb4bc0fc7dad', '3ef04288-5165-4210-82d9-93a103056dc3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0d4952fe-05fa-494e-a169-cb4bc0fc7dad', '5dc93b1f-2ad9-42ed-9799-3db68751d634', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ca22273b-2a14-4434-9d4a-5dd70ec6f410', '3ef04288-5165-4210-82d9-93a103056dc3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ca22273b-2a14-4434-9d4a-5dd70ec6f410', '5dc93b1f-2ad9-42ed-9799-3db68751d634', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ca22273b-2a14-4434-9d4a-5dd70ec6f410', '56155486-dca5-49b4-99ea-4e6f7b208599', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ca22273b-2a14-4434-9d4a-5dd70ec6f410', '7ab458a9-0c25-465e-becf-8f353c485a4f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ca22273b-2a14-4434-9d4a-5dd70ec6f410', '29a837c0-d73c-4a2b-b956-7b8773d622a3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b821e709-245b-4f2c-ad79-5daec769ee19', '3ef04288-5165-4210-82d9-93a103056dc3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b821e709-245b-4f2c-ad79-5daec769ee19', '5dc93b1f-2ad9-42ed-9799-3db68751d634', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b821e709-245b-4f2c-ad79-5daec769ee19', '56155486-dca5-49b4-99ea-4e6f7b208599', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7c28cacf-b85e-4490-b453-979b51c53294', '3ef04288-5165-4210-82d9-93a103056dc3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7c28cacf-b85e-4490-b453-979b51c53294', '5dc93b1f-2ad9-42ed-9799-3db68751d634', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7c28cacf-b85e-4490-b453-979b51c53294', '56155486-dca5-49b4-99ea-4e6f7b208599', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7c28cacf-b85e-4490-b453-979b51c53294', '7ab458a9-0c25-465e-becf-8f353c485a4f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7c28cacf-b85e-4490-b453-979b51c53294', '29a837c0-d73c-4a2b-b956-7b8773d622a3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7f386970-2aa4-456e-845d-2d25be49159c', 'cf1087b9-1d3a-4741-afeb-5aa11462597b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7f386970-2aa4-456e-845d-2d25be49159c', '40d5eddb-e47b-41e9-960e-612a4d2326d1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7f386970-2aa4-456e-845d-2d25be49159c', '229bd8b2-ae80-4db5-8240-4ec98e137eab', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7f386970-2aa4-456e-845d-2d25be49159c', '2e9b96dd-b7dd-458d-a929-4de08f6f044c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7f386970-2aa4-456e-845d-2d25be49159c', '9ada068a-d416-44f1-9a68-c3e3fd3affd7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d36a1af4-2d85-44b0-b8da-42555141dd2d', '7f386970-2aa4-456e-845d-2d25be49159c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d36a1af4-2d85-44b0-b8da-42555141dd2d', 'cf1087b9-1d3a-4741-afeb-5aa11462597b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d36a1af4-2d85-44b0-b8da-42555141dd2d', '40d5eddb-e47b-41e9-960e-612a4d2326d1', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d36a1af4-2d85-44b0-b8da-42555141dd2d', '229bd8b2-ae80-4db5-8240-4ec98e137eab', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d36a1af4-2d85-44b0-b8da-42555141dd2d', '2e9b96dd-b7dd-458d-a929-4de08f6f044c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cf1087b9-1d3a-4741-afeb-5aa11462597b', '7f386970-2aa4-456e-845d-2d25be49159c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cf1087b9-1d3a-4741-afeb-5aa11462597b', '40d5eddb-e47b-41e9-960e-612a4d2326d1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cf1087b9-1d3a-4741-afeb-5aa11462597b', '229bd8b2-ae80-4db5-8240-4ec98e137eab', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cf1087b9-1d3a-4741-afeb-5aa11462597b', '2e9b96dd-b7dd-458d-a929-4de08f6f044c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cf1087b9-1d3a-4741-afeb-5aa11462597b', '9ada068a-d416-44f1-9a68-c3e3fd3affd7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('229bd8b2-ae80-4db5-8240-4ec98e137eab', '7f386970-2aa4-456e-845d-2d25be49159c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('229bd8b2-ae80-4db5-8240-4ec98e137eab', 'cf1087b9-1d3a-4741-afeb-5aa11462597b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('229bd8b2-ae80-4db5-8240-4ec98e137eab', '2e9b96dd-b7dd-458d-a929-4de08f6f044c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('229bd8b2-ae80-4db5-8240-4ec98e137eab', '40d5eddb-e47b-41e9-960e-612a4d2326d1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('229bd8b2-ae80-4db5-8240-4ec98e137eab', '9ada068a-d416-44f1-9a68-c3e3fd3affd7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2e9b96dd-b7dd-458d-a929-4de08f6f044c', '7f386970-2aa4-456e-845d-2d25be49159c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2e9b96dd-b7dd-458d-a929-4de08f6f044c', 'cf1087b9-1d3a-4741-afeb-5aa11462597b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2e9b96dd-b7dd-458d-a929-4de08f6f044c', '229bd8b2-ae80-4db5-8240-4ec98e137eab', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2e9b96dd-b7dd-458d-a929-4de08f6f044c', '40d5eddb-e47b-41e9-960e-612a4d2326d1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2e9b96dd-b7dd-458d-a929-4de08f6f044c', '9ada068a-d416-44f1-9a68-c3e3fd3affd7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ad38921-949b-4350-852f-f7c5e5f1d127', '7f386970-2aa4-456e-845d-2d25be49159c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ad38921-949b-4350-852f-f7c5e5f1d127', 'cf1087b9-1d3a-4741-afeb-5aa11462597b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ad38921-949b-4350-852f-f7c5e5f1d127', '229bd8b2-ae80-4db5-8240-4ec98e137eab', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b96ee70-0e44-48cd-bff9-a7b806fd852e', '7f386970-2aa4-456e-845d-2d25be49159c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b96ee70-0e44-48cd-bff9-a7b806fd852e', 'cf1087b9-1d3a-4741-afeb-5aa11462597b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b96ee70-0e44-48cd-bff9-a7b806fd852e', '229bd8b2-ae80-4db5-8240-4ec98e137eab', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e86b48a6-c521-436b-ab5c-25cb92baaf72', 'f0cf9f3b-e1bf-4f75-af12-43776349e460', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e86b48a6-c521-436b-ab5c-25cb92baaf72', '5908b363-8a7d-4b1a-b69f-935809a89e3d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e86b48a6-c521-436b-ab5c-25cb92baaf72', '7873b699-ab2f-4145-bfea-83c853d62a94', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e86b48a6-c521-436b-ab5c-25cb92baaf72', '79586d2b-c8ea-471e-be5d-b489c8d04114', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e86b48a6-c521-436b-ab5c-25cb92baaf72', '527b06f0-1d67-4604-aeec-88ee206ef0b7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7873b699-ab2f-4145-bfea-83c853d62a94', '527b06f0-1d67-4604-aeec-88ee206ef0b7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7873b699-ab2f-4145-bfea-83c853d62a94', 'e86b48a6-c521-436b-ab5c-25cb92baaf72', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7873b699-ab2f-4145-bfea-83c853d62a94', 'f0cf9f3b-e1bf-4f75-af12-43776349e460', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7873b699-ab2f-4145-bfea-83c853d62a94', '79586d2b-c8ea-471e-be5d-b489c8d04114', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7873b699-ab2f-4145-bfea-83c853d62a94', '5908b363-8a7d-4b1a-b69f-935809a89e3d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0cf9f3b-e1bf-4f75-af12-43776349e460', 'e86b48a6-c521-436b-ab5c-25cb92baaf72', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0cf9f3b-e1bf-4f75-af12-43776349e460', '5908b363-8a7d-4b1a-b69f-935809a89e3d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0cf9f3b-e1bf-4f75-af12-43776349e460', '7873b699-ab2f-4145-bfea-83c853d62a94', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0cf9f3b-e1bf-4f75-af12-43776349e460', '79586d2b-c8ea-471e-be5d-b489c8d04114', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0cf9f3b-e1bf-4f75-af12-43776349e460', '527b06f0-1d67-4604-aeec-88ee206ef0b7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('79586d2b-c8ea-471e-be5d-b489c8d04114', 'e86b48a6-c521-436b-ab5c-25cb92baaf72', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('79586d2b-c8ea-471e-be5d-b489c8d04114', '7873b699-ab2f-4145-bfea-83c853d62a94', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('79586d2b-c8ea-471e-be5d-b489c8d04114', 'f0cf9f3b-e1bf-4f75-af12-43776349e460', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('79586d2b-c8ea-471e-be5d-b489c8d04114', '527b06f0-1d67-4604-aeec-88ee206ef0b7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('79586d2b-c8ea-471e-be5d-b489c8d04114', '5908b363-8a7d-4b1a-b69f-935809a89e3d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('527b06f0-1d67-4604-aeec-88ee206ef0b7', '7873b699-ab2f-4145-bfea-83c853d62a94', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('527b06f0-1d67-4604-aeec-88ee206ef0b7', 'e86b48a6-c521-436b-ab5c-25cb92baaf72', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('527b06f0-1d67-4604-aeec-88ee206ef0b7', 'f0cf9f3b-e1bf-4f75-af12-43776349e460', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('527b06f0-1d67-4604-aeec-88ee206ef0b7', '79586d2b-c8ea-471e-be5d-b489c8d04114', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('527b06f0-1d67-4604-aeec-88ee206ef0b7', '5908b363-8a7d-4b1a-b69f-935809a89e3d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c19138fc-5b23-4560-a4d5-a2aaca20a81d', '35408dab-342b-48b7-bae6-cbbf186d8b74', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c19138fc-5b23-4560-a4d5-a2aaca20a81d', '7f386970-2aa4-456e-845d-2d25be49159c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c19138fc-5b23-4560-a4d5-a2aaca20a81d', 'cf1087b9-1d3a-4741-afeb-5aa11462597b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('40d5eddb-e47b-41e9-960e-612a4d2326d1', '7f386970-2aa4-456e-845d-2d25be49159c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('40d5eddb-e47b-41e9-960e-612a4d2326d1', 'cf1087b9-1d3a-4741-afeb-5aa11462597b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('40d5eddb-e47b-41e9-960e-612a4d2326d1', '229bd8b2-ae80-4db5-8240-4ec98e137eab', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('40d5eddb-e47b-41e9-960e-612a4d2326d1', '2e9b96dd-b7dd-458d-a929-4de08f6f044c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('40d5eddb-e47b-41e9-960e-612a4d2326d1', '9ada068a-d416-44f1-9a68-c3e3fd3affd7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7be5cfd2-0af2-47d5-b1cc-8b4a798d46c6', '7f386970-2aa4-456e-845d-2d25be49159c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7be5cfd2-0af2-47d5-b1cc-8b4a798d46c6', 'cf1087b9-1d3a-4741-afeb-5aa11462597b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7be5cfd2-0af2-47d5-b1cc-8b4a798d46c6', '229bd8b2-ae80-4db5-8240-4ec98e137eab', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ada068a-d416-44f1-9a68-c3e3fd3affd7', '7f386970-2aa4-456e-845d-2d25be49159c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ada068a-d416-44f1-9a68-c3e3fd3affd7', 'cf1087b9-1d3a-4741-afeb-5aa11462597b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ada068a-d416-44f1-9a68-c3e3fd3affd7', '229bd8b2-ae80-4db5-8240-4ec98e137eab', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ada068a-d416-44f1-9a68-c3e3fd3affd7', '2e9b96dd-b7dd-458d-a929-4de08f6f044c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ada068a-d416-44f1-9a68-c3e3fd3affd7', '40d5eddb-e47b-41e9-960e-612a4d2326d1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('35408dab-342b-48b7-bae6-cbbf186d8b74', 'c19138fc-5b23-4560-a4d5-a2aaca20a81d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('35408dab-342b-48b7-bae6-cbbf186d8b74', '7f386970-2aa4-456e-845d-2d25be49159c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('35408dab-342b-48b7-bae6-cbbf186d8b74', 'cf1087b9-1d3a-4741-afeb-5aa11462597b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5908b363-8a7d-4b1a-b69f-935809a89e3d', 'e86b48a6-c521-436b-ab5c-25cb92baaf72', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5908b363-8a7d-4b1a-b69f-935809a89e3d', 'f0cf9f3b-e1bf-4f75-af12-43776349e460', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5908b363-8a7d-4b1a-b69f-935809a89e3d', '7873b699-ab2f-4145-bfea-83c853d62a94', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5908b363-8a7d-4b1a-b69f-935809a89e3d', '79586d2b-c8ea-471e-be5d-b489c8d04114', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5908b363-8a7d-4b1a-b69f-935809a89e3d', '527b06f0-1d67-4604-aeec-88ee206ef0b7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f7bd70d9-d277-4cc8-88d9-31d50bb99a24', '487d6685-e0a6-4c42-bdc4-741d005972cb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f7bd70d9-d277-4cc8-88d9-31d50bb99a24', '9f39c082-6323-4809-8fd4-352ed87c5823', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f7bd70d9-d277-4cc8-88d9-31d50bb99a24', '7f386970-2aa4-456e-845d-2d25be49159c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('487d6685-e0a6-4c42-bdc4-741d005972cb', 'f7bd70d9-d277-4cc8-88d9-31d50bb99a24', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('487d6685-e0a6-4c42-bdc4-741d005972cb', '9f39c082-6323-4809-8fd4-352ed87c5823', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('487d6685-e0a6-4c42-bdc4-741d005972cb', '7f386970-2aa4-456e-845d-2d25be49159c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9f39c082-6323-4809-8fd4-352ed87c5823', 'f7bd70d9-d277-4cc8-88d9-31d50bb99a24', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9f39c082-6323-4809-8fd4-352ed87c5823', '487d6685-e0a6-4c42-bdc4-741d005972cb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9f39c082-6323-4809-8fd4-352ed87c5823', '7f386970-2aa4-456e-845d-2d25be49159c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('56044ca9-2767-4217-9495-de5527a66d38', 'e35eb7c5-9557-4596-bb31-eaaf116a2dc3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('56044ca9-2767-4217-9495-de5527a66d38', '6b6dc61a-2d5b-4762-8031-d60c304682ad', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('56044ca9-2767-4217-9495-de5527a66d38', 'dd137c78-7e75-4862-89ff-ea396b7c8c71', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('56044ca9-2767-4217-9495-de5527a66d38', 'a94fd314-fcd9-4344-a9de-9ab1a2207b4e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e35eb7c5-9557-4596-bb31-eaaf116a2dc3', '56044ca9-2767-4217-9495-de5527a66d38', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e35eb7c5-9557-4596-bb31-eaaf116a2dc3', '6b6dc61a-2d5b-4762-8031-d60c304682ad', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e35eb7c5-9557-4596-bb31-eaaf116a2dc3', 'dd137c78-7e75-4862-89ff-ea396b7c8c71', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e35eb7c5-9557-4596-bb31-eaaf116a2dc3', 'a94fd314-fcd9-4344-a9de-9ab1a2207b4e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6b6dc61a-2d5b-4762-8031-d60c304682ad', '56044ca9-2767-4217-9495-de5527a66d38', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6b6dc61a-2d5b-4762-8031-d60c304682ad', 'e35eb7c5-9557-4596-bb31-eaaf116a2dc3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6b6dc61a-2d5b-4762-8031-d60c304682ad', 'dd137c78-7e75-4862-89ff-ea396b7c8c71', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6b6dc61a-2d5b-4762-8031-d60c304682ad', 'a94fd314-fcd9-4344-a9de-9ab1a2207b4e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dd137c78-7e75-4862-89ff-ea396b7c8c71', '56044ca9-2767-4217-9495-de5527a66d38', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dd137c78-7e75-4862-89ff-ea396b7c8c71', 'e35eb7c5-9557-4596-bb31-eaaf116a2dc3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dd137c78-7e75-4862-89ff-ea396b7c8c71', '6b6dc61a-2d5b-4762-8031-d60c304682ad', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dd137c78-7e75-4862-89ff-ea396b7c8c71', 'a94fd314-fcd9-4344-a9de-9ab1a2207b4e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a94fd314-fcd9-4344-a9de-9ab1a2207b4e', '56044ca9-2767-4217-9495-de5527a66d38', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a94fd314-fcd9-4344-a9de-9ab1a2207b4e', 'e35eb7c5-9557-4596-bb31-eaaf116a2dc3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a94fd314-fcd9-4344-a9de-9ab1a2207b4e', '6b6dc61a-2d5b-4762-8031-d60c304682ad', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a94fd314-fcd9-4344-a9de-9ab1a2207b4e', 'dd137c78-7e75-4862-89ff-ea396b7c8c71', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('074f6b67-07c5-41dd-b8cb-a9020ca07389', '2c03e118-6e99-4d00-b773-df031e3c89a8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('074f6b67-07c5-41dd-b8cb-a9020ca07389', '6a3d4ef4-3786-4ef2-a120-37ebbf3095a7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2c03e118-6e99-4d00-b773-df031e3c89a8', '074f6b67-07c5-41dd-b8cb-a9020ca07389', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2c03e118-6e99-4d00-b773-df031e3c89a8', '6a3d4ef4-3786-4ef2-a120-37ebbf3095a7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6a3d4ef4-3786-4ef2-a120-37ebbf3095a7', '074f6b67-07c5-41dd-b8cb-a9020ca07389', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6a3d4ef4-3786-4ef2-a120-37ebbf3095a7', '2c03e118-6e99-4d00-b773-df031e3c89a8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c8ee958-84e1-4795-a3b2-9edb416de299', 'da164b65-e4f2-4abb-8611-65b78f099561', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c8ee958-84e1-4795-a3b2-9edb416de299', 'a3f91f9b-5dd2-41bf-a3d1-94824d4aa83f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c8ee958-84e1-4795-a3b2-9edb416de299', 'c211836f-fb17-4358-9aea-bca65569c159', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c8ee958-84e1-4795-a3b2-9edb416de299', 'dc7de871-73bb-45da-86f9-b18e7e3d4089', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c8ee958-84e1-4795-a3b2-9edb416de299', '59073842-fa9a-46ad-a35d-258bff33564b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a3f91f9b-5dd2-41bf-a3d1-94824d4aa83f', 'da164b65-e4f2-4abb-8611-65b78f099561', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a3f91f9b-5dd2-41bf-a3d1-94824d4aa83f', '0c8ee958-84e1-4795-a3b2-9edb416de299', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a3f91f9b-5dd2-41bf-a3d1-94824d4aa83f', 'c211836f-fb17-4358-9aea-bca65569c159', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a3f91f9b-5dd2-41bf-a3d1-94824d4aa83f', 'dc7de871-73bb-45da-86f9-b18e7e3d4089', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a3f91f9b-5dd2-41bf-a3d1-94824d4aa83f', '59073842-fa9a-46ad-a35d-258bff33564b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c211836f-fb17-4358-9aea-bca65569c159', 'da164b65-e4f2-4abb-8611-65b78f099561', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c211836f-fb17-4358-9aea-bca65569c159', '0c8ee958-84e1-4795-a3b2-9edb416de299', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c211836f-fb17-4358-9aea-bca65569c159', 'a3f91f9b-5dd2-41bf-a3d1-94824d4aa83f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c211836f-fb17-4358-9aea-bca65569c159', 'dc7de871-73bb-45da-86f9-b18e7e3d4089', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c211836f-fb17-4358-9aea-bca65569c159', '59073842-fa9a-46ad-a35d-258bff33564b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59073842-fa9a-46ad-a35d-258bff33564b', 'da164b65-e4f2-4abb-8611-65b78f099561', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59073842-fa9a-46ad-a35d-258bff33564b', 'dc7de871-73bb-45da-86f9-b18e7e3d4089', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59073842-fa9a-46ad-a35d-258bff33564b', '0c8ee958-84e1-4795-a3b2-9edb416de299', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59073842-fa9a-46ad-a35d-258bff33564b', 'a3f91f9b-5dd2-41bf-a3d1-94824d4aa83f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59073842-fa9a-46ad-a35d-258bff33564b', 'c211836f-fb17-4358-9aea-bca65569c159', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('422622ae-ee74-40c0-9b40-59fad23a1c3f', '3a8b3697-0afc-4095-bbfa-6ed7090e7e53', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('422622ae-ee74-40c0-9b40-59fad23a1c3f', '941e84d1-1806-4911-87df-9a83441b5f07', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a8b3697-0afc-4095-bbfa-6ed7090e7e53', '422622ae-ee74-40c0-9b40-59fad23a1c3f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a8b3697-0afc-4095-bbfa-6ed7090e7e53', '941e84d1-1806-4911-87df-9a83441b5f07', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('941e84d1-1806-4911-87df-9a83441b5f07', '422622ae-ee74-40c0-9b40-59fad23a1c3f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('941e84d1-1806-4911-87df-9a83441b5f07', '3a8b3697-0afc-4095-bbfa-6ed7090e7e53', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a9208cd4-87b2-4e50-9e17-1c0582372456', 'de01828f-0355-491b-9e1f-8c4eb11f4d9b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a9208cd4-87b2-4e50-9e17-1c0582372456', '021770b2-f3b2-4f6f-a973-c12d114c35c9', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a9208cd4-87b2-4e50-9e17-1c0582372456', 'abbc96db-97be-484c-b2b2-49e7adf5893d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('de01828f-0355-491b-9e1f-8c4eb11f4d9b', 'abbc96db-97be-484c-b2b2-49e7adf5893d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('de01828f-0355-491b-9e1f-8c4eb11f4d9b', 'a9208cd4-87b2-4e50-9e17-1c0582372456', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('de01828f-0355-491b-9e1f-8c4eb11f4d9b', '021770b2-f3b2-4f6f-a973-c12d114c35c9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('021770b2-f3b2-4f6f-a973-c12d114c35c9', 'a9208cd4-87b2-4e50-9e17-1c0582372456', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('021770b2-f3b2-4f6f-a973-c12d114c35c9', 'de01828f-0355-491b-9e1f-8c4eb11f4d9b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('021770b2-f3b2-4f6f-a973-c12d114c35c9', 'abbc96db-97be-484c-b2b2-49e7adf5893d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('abbc96db-97be-484c-b2b2-49e7adf5893d', 'de01828f-0355-491b-9e1f-8c4eb11f4d9b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('abbc96db-97be-484c-b2b2-49e7adf5893d', 'a9208cd4-87b2-4e50-9e17-1c0582372456', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('abbc96db-97be-484c-b2b2-49e7adf5893d', '021770b2-f3b2-4f6f-a973-c12d114c35c9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('15121c12-9656-4c1d-9e47-17b3cafe8bb3', '5c75951a-4e73-466e-9b49-38fa30a1d819', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('15121c12-9656-4c1d-9e47-17b3cafe8bb3', '30b3ec4b-bfa1-4f68-8d62-10fc2f261841', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('15121c12-9656-4c1d-9e47-17b3cafe8bb3', '27219e71-cd1d-4f5e-8d52-9538f1053295', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('15121c12-9656-4c1d-9e47-17b3cafe8bb3', '28b2a821-aa3d-452a-a8b0-7f891b6bdfc2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('15121c12-9656-4c1d-9e47-17b3cafe8bb3', '60751958-3358-43ef-8bf6-32005aefc399', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5c75951a-4e73-466e-9b49-38fa30a1d819', '15121c12-9656-4c1d-9e47-17b3cafe8bb3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5c75951a-4e73-466e-9b49-38fa30a1d819', '30b3ec4b-bfa1-4f68-8d62-10fc2f261841', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5c75951a-4e73-466e-9b49-38fa30a1d819', '27219e71-cd1d-4f5e-8d52-9538f1053295', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5c75951a-4e73-466e-9b49-38fa30a1d819', '28b2a821-aa3d-452a-a8b0-7f891b6bdfc2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5c75951a-4e73-466e-9b49-38fa30a1d819', '60751958-3358-43ef-8bf6-32005aefc399', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('30b3ec4b-bfa1-4f68-8d62-10fc2f261841', 'a0133db2-df29-4811-92d7-2d8fe9119009', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('30b3ec4b-bfa1-4f68-8d62-10fc2f261841', '15121c12-9656-4c1d-9e47-17b3cafe8bb3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('30b3ec4b-bfa1-4f68-8d62-10fc2f261841', '5c75951a-4e73-466e-9b49-38fa30a1d819', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('30b3ec4b-bfa1-4f68-8d62-10fc2f261841', '27219e71-cd1d-4f5e-8d52-9538f1053295', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('30b3ec4b-bfa1-4f68-8d62-10fc2f261841', '28b2a821-aa3d-452a-a8b0-7f891b6bdfc2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('27219e71-cd1d-4f5e-8d52-9538f1053295', '15121c12-9656-4c1d-9e47-17b3cafe8bb3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('27219e71-cd1d-4f5e-8d52-9538f1053295', '5c75951a-4e73-466e-9b49-38fa30a1d819', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('27219e71-cd1d-4f5e-8d52-9538f1053295', '30b3ec4b-bfa1-4f68-8d62-10fc2f261841', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('27219e71-cd1d-4f5e-8d52-9538f1053295', '28b2a821-aa3d-452a-a8b0-7f891b6bdfc2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('27219e71-cd1d-4f5e-8d52-9538f1053295', '60751958-3358-43ef-8bf6-32005aefc399', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('28b2a821-aa3d-452a-a8b0-7f891b6bdfc2', '15121c12-9656-4c1d-9e47-17b3cafe8bb3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('28b2a821-aa3d-452a-a8b0-7f891b6bdfc2', '5c75951a-4e73-466e-9b49-38fa30a1d819', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('28b2a821-aa3d-452a-a8b0-7f891b6bdfc2', '30b3ec4b-bfa1-4f68-8d62-10fc2f261841', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('28b2a821-aa3d-452a-a8b0-7f891b6bdfc2', '27219e71-cd1d-4f5e-8d52-9538f1053295', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('28b2a821-aa3d-452a-a8b0-7f891b6bdfc2', '60751958-3358-43ef-8bf6-32005aefc399', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('60751958-3358-43ef-8bf6-32005aefc399', '15121c12-9656-4c1d-9e47-17b3cafe8bb3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('60751958-3358-43ef-8bf6-32005aefc399', '5c75951a-4e73-466e-9b49-38fa30a1d819', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('60751958-3358-43ef-8bf6-32005aefc399', '30b3ec4b-bfa1-4f68-8d62-10fc2f261841', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('60751958-3358-43ef-8bf6-32005aefc399', '27219e71-cd1d-4f5e-8d52-9538f1053295', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('60751958-3358-43ef-8bf6-32005aefc399', '28b2a821-aa3d-452a-a8b0-7f891b6bdfc2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b1424461-86bf-435e-a7f5-18480ff54d1e', '15121c12-9656-4c1d-9e47-17b3cafe8bb3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b1424461-86bf-435e-a7f5-18480ff54d1e', '5c75951a-4e73-466e-9b49-38fa30a1d819', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b1424461-86bf-435e-a7f5-18480ff54d1e', '30b3ec4b-bfa1-4f68-8d62-10fc2f261841', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b1424461-86bf-435e-a7f5-18480ff54d1e', '27219e71-cd1d-4f5e-8d52-9538f1053295', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b1424461-86bf-435e-a7f5-18480ff54d1e', '28b2a821-aa3d-452a-a8b0-7f891b6bdfc2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0133db2-df29-4811-92d7-2d8fe9119009', '30b3ec4b-bfa1-4f68-8d62-10fc2f261841', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0133db2-df29-4811-92d7-2d8fe9119009', '15121c12-9656-4c1d-9e47-17b3cafe8bb3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0133db2-df29-4811-92d7-2d8fe9119009', '5c75951a-4e73-466e-9b49-38fa30a1d819', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0133db2-df29-4811-92d7-2d8fe9119009', '27219e71-cd1d-4f5e-8d52-9538f1053295', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0133db2-df29-4811-92d7-2d8fe9119009', '28b2a821-aa3d-452a-a8b0-7f891b6bdfc2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('96387da3-3821-4685-a3a0-b889f3b01bc0', '15121c12-9656-4c1d-9e47-17b3cafe8bb3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('96387da3-3821-4685-a3a0-b889f3b01bc0', '5c75951a-4e73-466e-9b49-38fa30a1d819', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('96387da3-3821-4685-a3a0-b889f3b01bc0', '30b3ec4b-bfa1-4f68-8d62-10fc2f261841', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('96387da3-3821-4685-a3a0-b889f3b01bc0', '27219e71-cd1d-4f5e-8d52-9538f1053295', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('96387da3-3821-4685-a3a0-b889f3b01bc0', '28b2a821-aa3d-452a-a8b0-7f891b6bdfc2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3ad0cf96-6302-4f90-b390-1fdc67bd274b', 'ada59c68-ab38-47fd-b498-10fd9443b648', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d208dc8a-acec-4245-860e-13142ab7c087', 'ada59c68-ab38-47fd-b498-10fd9443b648', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ddc1955d-ee54-405c-a9dc-1cb6bdaa3cbc', 'ada59c68-ab38-47fd-b498-10fd9443b648', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f5c74d8f-94ce-44e5-a245-dc025f3e36b2', 'ada59c68-ab38-47fd-b498-10fd9443b648', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9627dce3-0728-4202-bda8-713661ba2fbe', 'ada59c68-ab38-47fd-b498-10fd9443b648', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22749348-02e9-4c81-a37e-26ed50e7642d', 'ada59c68-ab38-47fd-b498-10fd9443b648', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('218261e9-9488-4e99-b444-f0059c1251ce', '61aa5b07-edda-4576-ac28-ed2765df1a56', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('218261e9-9488-4e99-b444-f0059c1251ce', '35184def-2db2-46f7-a2fb-263128c73df1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('218261e9-9488-4e99-b444-f0059c1251ce', '8c3fe9ee-4983-4186-a347-c9c7288996db', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('61aa5b07-edda-4576-ac28-ed2765df1a56', '218261e9-9488-4e99-b444-f0059c1251ce', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('61aa5b07-edda-4576-ac28-ed2765df1a56', '35184def-2db2-46f7-a2fb-263128c73df1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('61aa5b07-edda-4576-ac28-ed2765df1a56', '8c3fe9ee-4983-4186-a347-c9c7288996db', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('35184def-2db2-46f7-a2fb-263128c73df1', '8c3fe9ee-4983-4186-a347-c9c7288996db', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('35184def-2db2-46f7-a2fb-263128c73df1', '218261e9-9488-4e99-b444-f0059c1251ce', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('35184def-2db2-46f7-a2fb-263128c73df1', '61aa5b07-edda-4576-ac28-ed2765df1a56', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8c3fe9ee-4983-4186-a347-c9c7288996db', '35184def-2db2-46f7-a2fb-263128c73df1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8c3fe9ee-4983-4186-a347-c9c7288996db', '218261e9-9488-4e99-b444-f0059c1251ce', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8c3fe9ee-4983-4186-a347-c9c7288996db', '61aa5b07-edda-4576-ac28-ed2765df1a56', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a75f8c88-c055-4e91-b7ff-390f36262aa3', 'c975a833-ba21-4bee-b48a-125783268a1a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a75f8c88-c055-4e91-b7ff-390f36262aa3', '69355460-5253-4e85-b728-427092995393', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b6cdb318-dacc-49f1-89b1-3147e86e0909', 'a75f8c88-c055-4e91-b7ff-390f36262aa3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b6cdb318-dacc-49f1-89b1-3147e86e0909', 'c975a833-ba21-4bee-b48a-125783268a1a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b6cdb318-dacc-49f1-89b1-3147e86e0909', '69355460-5253-4e85-b728-427092995393', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d9b7904b-dad9-4a39-8717-3bfa51bd2e88', 'a75f8c88-c055-4e91-b7ff-390f36262aa3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d9b7904b-dad9-4a39-8717-3bfa51bd2e88', 'c975a833-ba21-4bee-b48a-125783268a1a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d9b7904b-dad9-4a39-8717-3bfa51bd2e88', '69355460-5253-4e85-b728-427092995393', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c975a833-ba21-4bee-b48a-125783268a1a', 'a75f8c88-c055-4e91-b7ff-390f36262aa3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c975a833-ba21-4bee-b48a-125783268a1a', '69355460-5253-4e85-b728-427092995393', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0de1e07-20d6-493e-8033-409c93fc2e94', 'a75f8c88-c055-4e91-b7ff-390f36262aa3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0de1e07-20d6-493e-8033-409c93fc2e94', 'c975a833-ba21-4bee-b48a-125783268a1a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0de1e07-20d6-493e-8033-409c93fc2e94', '69355460-5253-4e85-b728-427092995393', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4eb3ad03-5609-4301-8b53-9a3127adfe22', 'a75f8c88-c055-4e91-b7ff-390f36262aa3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4eb3ad03-5609-4301-8b53-9a3127adfe22', 'c975a833-ba21-4bee-b48a-125783268a1a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4eb3ad03-5609-4301-8b53-9a3127adfe22', '69355460-5253-4e85-b728-427092995393', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('69355460-5253-4e85-b728-427092995393', 'a75f8c88-c055-4e91-b7ff-390f36262aa3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('69355460-5253-4e85-b728-427092995393', 'c975a833-ba21-4bee-b48a-125783268a1a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c634e286-0375-42e4-8c1a-4122d8f8253f', 'a75f8c88-c055-4e91-b7ff-390f36262aa3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c634e286-0375-42e4-8c1a-4122d8f8253f', 'c975a833-ba21-4bee-b48a-125783268a1a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c634e286-0375-42e4-8c1a-4122d8f8253f', '69355460-5253-4e85-b728-427092995393', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5b6f2ade-941a-465f-b81e-1e25715d3513', 'a75f8c88-c055-4e91-b7ff-390f36262aa3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5b6f2ade-941a-465f-b81e-1e25715d3513', 'c975a833-ba21-4bee-b48a-125783268a1a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5b6f2ade-941a-465f-b81e-1e25715d3513', '69355460-5253-4e85-b728-427092995393', 2) ON CONFLICT DO NOTHING;



INSERT INTO public.faqs VALUES ('862244df-3217-42e1-a51a-d62afc8bdbbc', 'متى يوصلني الرد بعد الاشتراك؟', 'خلال 48 ساعة عمل. أيام العمل من الأحد إلى الخميس، من 12 الظهر حتى 9 مساءً، والتواصل على واتساب.', 0, true, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('070c8b2b-7fe8-4d4c-9079-57eb306dbf2e', 'كيف تتم المتابعة؟', 'ترسل مراجعتك الأسبوعية في يوم المراجعة، وأرد عليك بتعديلات مسجلة (فيديو أو صوت). في الباقة الأساسية المتابعة كل أسبوعين. التواصل اليومي على واتساب مع رد خلال 48 ساعة.', 1, true, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('1d3e7990-c987-45ec-9af6-cec88d3c70f1', 'أنا مبتدئ تماماً، هل يناسبني؟', 'نعم. البرنامج يُبنى على مستواك الحالي، والتمارين مشروحة، وتقدر ترسل مقاطع أدائك لتصحيح التكنيك.', 2, true, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('b55a3596-2fc8-4605-b8eb-4f1e89a13fbf', 'أتمرن في البيت، ماذا أحتاج من أدوات؟', 'تحدد في النموذج الأدوات المتوفرة عندك (دمبلز، حبال مقاومة، بار…) ويُبنى جدولك عليها.', 3, true, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('51fe9bc3-1647-4e95-91ac-7a11dc56a84d', 'كيف أدفع؟', 'بتحويل بنكي بعد تعبئة الاستبيان. أول ما ترسل الاستبيان يظهر لك رقم طلبك والمبلغ وبيانات الحساب. حوّل المبلغ وارفع صورة الإيصال من صفحة طلبك، ويتأكد اشتراكك بعد التحقق من وصول المبلغ.', 4, true, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('ae8566ea-6442-4ea2-9a98-1bef635def65', 'ما شروط ضمان استرجاع المبلغ؟', 'في اشتراكات 3 أشهر لباقات المتابعة (المكثفة، المتقدمة، الأساسية): إذا لم يتحسن أي مؤشر من مؤشرات تقدمك بعد 12 أسبوعاً، يرجع لك المبلغ كاملاً.
مؤشرات التقدم (بحسب هدفك): متوسط الوزن الأسبوعي، أو محيط الخصر، أو القوة في التمارين الأساسية (الوزن أو التكرارات).
شروط الضمان:
- إرسال المراجعة الأسبوعية كل أسبوع.
- أخذ القياسات بانتظام.
- تصوير التمارين وإرسالها.
- الالتزام بجدول التغذية المخصص (في الباقات التي تشمل تغذية).
يُطلب الاسترجاع عبر واتساب خلال 14 يوماً من نهاية الأشهر الثلاثة.', 5, true, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('151d31f9-7428-4086-b3d5-594c262680c6', 'هل الجداول لي بعد انتهاء الاشتراك؟', 'نعم، جميع الجداول لك مدى الحياة وتقدر تعدّل عليها.', 6, true, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('7261aeb5-634f-4723-9abe-5297b7d6119b', 'ما هو التجديد المجاني؟', 'مكافأة للملتزمين: إذا كان اشتراكك 3 أشهر تحصل على 3 أشهر إضافية مجاناً، فيصير المجموع 6 أشهر بسعر 3.
الشروط:
- نسبة التزام 90% فأكثر: المراجعات الأسبوعية المرسلة والتمارين المسجلة.
- تقدم واضح في مؤشرات التقدم نفسها المذكورة في الضمان.
- للمتدربين الرجال: إرسال صور التطور (قبل وبعد) للمدربة للتوثيق، مع تغطية الوجه والسرة.
نشر الصور في السوشل ميديا اختياري بالكامل حسب موافقتك، ولا يؤثر على استحقاقك للتجديد.', 7, true, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('8a438b4d-3dcd-421f-87d1-e5482412a346', 'من يطّلع على بياناتي؟', 'المدربة فقط، وتُستخدم لتصميم برنامجك ومتابعتك. لا تُنشر نتيجتك أو صورتك إلا بموافقتك الصريحة في النموذج.', 8, true, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;



INSERT INTO public.policies VALUES ('terms', 'الشروط والأحكام', '- يبدأ الاشتراك بعد التحقق من وصول التحويل البنكي، وتعبئة استبيان المتدرب.
- ساعات العمل: الأحد – الخميس، 12 ظهراً – 9 مساءً. الرد على الرسائل خلال 48 ساعة عمل.
- البرنامج لا يغني عن الاستشارة الطبية، والمتدرب مسؤول عن الإفصاح عن أي إصابة أو حالة صحية.
- الجداول ملك المتدرب مدى الحياة ويمكنه التعديل عليها.
- الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي.', 0, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.policies VALUES ('refund', 'الضمان والاسترجاع', '- في اشتراكات 3 أشهر لباقات المتابعة (المكثفة، المتقدمة، الأساسية): يُسترد المبلغ كاملاً إذا لم يتحسن أي من مؤشرات التقدم (متوسط الوزن الأسبوعي، محيط الخصر، القوة في التمارين الأساسية) بعد 12 أسبوعاً.
- شروط الضمان: إرسال المراجعة الأسبوعية كل أسبوع، وأخذ القياسات بانتظام، وتصوير التمارين وإرسالها، والالتزام بجدول التغذية المخصص في الباقات التي تشملها.
- يُطلب الاسترجاع عبر واتساب خلال 14 يوماً من نهاية الأشهر الثلاثة، ويُرجع المبلغ بتحويل بنكي.
- التجديد المجاني: اشتراك 3 أشهر يُكافأ بـ 3 أشهر إضافية عند التزام 90% فأكثر وتقدم واضح في مؤشرات التقدم. صور التطور تُرسل للمدربة للتوثيق (للرجال مع تغطية الوجه والسرة)، ونشرها اختياري.', 1, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.policies VALUES ('privacy', 'سياسة الخصوصية', '- نجمع: الاسم، البريد الإلكتروني (للدخول إلى حسابك)، رقم الجوال (واتساب)، الباقة المختارة، ومعلومات الاستبيان التي تكتبها بنفسك (ومنها معلومات صحية وقياسات اختيارية).
- الغرض: تنفيذ طلبك، وتصميم برنامجك ومتابعتك، والتواصل معك بخصوصه فقط.
- المعلومات الصحية تُحفظ منفصلة، ولا يطّلع عليها إلا أنت والمدربة، ولا تُرسل في رسائل البريد أو التنبيهات.
- الدفع بتحويل بنكي مباشر لحساب المؤسسة، والموقع لا يطلب أو يخزن أي بيانات بنكية أو بيانات بطاقات. إيصال التحويل يُستخدم لتأكيد طلبك فقط، ويُحفظ في تخزين خاص لا يُفتح إلا لك وللمدربة.
- لا نبيع بياناتك ولا نشاركها مع أي طرف لأغراض تسويقية، ولا تُنشر نتيجتك أو صورتك إلا بموافقتك الصريحة.
- تقدر تطلب نسخة من بياناتك أو حذفها أو سحب موافقتك على النشر بمراسلتنا على واتساب.', 2, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.policies VALUES ('reviews', 'سياسة التقييمات', '- يكتب التقييم فقط من اشترى خدمة وبدأها فعلاً، وتقييم واحد لكل طلب.
- كل تقييم يُراجع قبل ظهوره للعامة، ولا يُعدّل نصه أبداً.
- تختار بنفسك طريقة ظهور اسمك: الاسم كامل، أو الاسم الأول فقط، أو بدون اسم. والموافقة على النشر منفصلة واختيارية.
- لا يُنشر تقييم يحتوي أرقام هواتف أو بريد أو روابط أو تفاصيل صحية خاصة أو إساءة لأي شخص.
- يحق للمدربة الرد على التقييم، أو إخفاء التقييم المخالف لهذه السياسة مع تسجيل السبب.
- تقدر تطلب إخفاء تقييمك في أي وقت بمراسلتنا على واتساب.', 3, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;



INSERT INTO public.products VALUES ('b483d6ec-2d78-4ac0-ba22-84c1dec6eac7', 'intensive', 'follow', 'الباقة المكثفة', 'الأنسب للمبتدئين ولمن يحتاج متابعة أسبوعية مع زوم: تمرين + تغذية + زوم + جلسة حضورية', '[{"text": "جلسة حضورية مجانية لمدة ساعة لتصحيح التكنيك والتأكد من جودة التمرين (للبنات في المنطقة الشرقية)", "included": true}, {"text": "ملف شامل للخطة التدريبية والتغذية مع شروحات وافية للتمارين، بالمنزل أو بالنادي", "included": true}, {"text": "4 مكالمات زوم شهرياً نتابع فيها تطورك واستفساراتك الرياضية والنفسية", "included": true}, {"text": "مناقشة أسبوعية لتطورك البدني والنفسي (فيديو أو تسجيل صوتي) مع تعديل السعرات أو التمرين عند الحاجة", "included": true}, {"text": "شرح سهل ومبسط لتطبيق حساب السعرات MyFitnessPal", "included": true}, {"text": "كتيب شامل للرياضة والتغذية", "included": true}, {"text": "مساعدتك على اختيارات أنسب لصحتك ونمط حياتك في التغذية والروتين اليومي", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}]', NULL, 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.', true, NULL, 'published', 0, false, '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('33eaf6fb-b622-4eed-814c-fa5104bd6633', 'advanced', 'follow', 'الباقة المتقدمة', 'لمن عنده خبرة ويحتاج تمرين + تغذية مع متابعة أسبوعية، بدون زوم', '[{"text": "ملف شامل للخطة التدريبية والتغذية مع شروحات وافية للتمارين، بالمنزل أو بالنادي", "included": true}, {"text": "مناقشة أسبوعية لتطورك البدني والنفسي (فيديو أو تسجيل صوتي) مع تعديل السعرات أو التمرين عند الحاجة", "included": true}, {"text": "كتيب شامل للرياضة والتغذية", "included": true}, {"text": "مساعدتك على اختيارات أنسب لصحتك ونمط حياتك في التمرين والروتين اليومي", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}, {"text": "مكالمات زوم والجلسة الحضورية (في المكثفة فقط)", "included": false}]', NULL, 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.', false, NULL, 'published', 1, false, '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('94caa529-8593-436e-9f5e-9e8273632374', 'basic', 'follow', 'الباقة الأساسية', 'لمن يعرف يضبط أكله ويحتاج خطة تمرين فقط، ومتابعة كل أسبوعين', '[{"text": "ملف شامل للخطة التدريبية مع شروحات وافية للتمارين، بالمنزل أو بالنادي", "included": true}, {"text": "مناقشة كل أسبوعين لتطورك البدني والنفسي (فيديو أو تسجيل صوتي) مع تعديل التمرين عند الحاجة", "included": true}, {"text": "كتيب شامل للرياضة والتغذية", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}, {"text": "بدون خطة تغذية", "included": false}]', NULL, 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.', false, NULL, 'published', 2, false, '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('80350d23-e433-4f27-92b0-adc66a64cb6c', 'nutrition', 'follow', 'باقة التغذية', 'لمن يحتاج خطة تغذية شاملة ويتعلم حساب السعرات، بدون خطة تمرين', '[{"text": "خطة تغذية شاملة تناسب هدفك ونمط حياتك", "included": true}, {"text": "تحديد السعرات المناسبة لك ولهدفك", "included": true}, {"text": "تعليمك حسبة السعرات ومساعدتك باختيارات تغذية تناسبك", "included": true}, {"text": "ملف Excel لمتابعة التطور والقياسات", "included": true}, {"text": "مناقشة أسبوعية لعلاقتك بالتغذية في المنزل أو خارجه", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}, {"text": "لا تحتاجها إذا كنت مشتركاً في المكثفة أو المتقدمة، لأن التغذية ضمنها", "included": false}]', 'شهر واحد · غالباً لا تحتاج تجديد', 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي، ولا يوجد تجديد تلقائي. ضمان الاسترجاع يشمل اشتراكات 3 أشهر للمكثفة والمتقدمة والأساسية فقط.', false, NULL, 'published', 3, false, '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('45a664bd-8c07-4fe6-89e2-ae92c00d806b', 'custom-training-plan', 'files', 'بديل التدريب الشخصي', 'لمن لا يحتاج متابعة (متقدم)، أو كبديل أوفر للتدريب الشخصي', '[{"text": "جدول تمرين مخصص لعدد أيام التمرين اللي تحتاجها", "included": true}, {"text": "طريقة حساب الجهد وعدد الجولات المطلوبة", "included": true}, {"text": "تقدر تحمّل الجدول على جهازك", "included": true}]', NULL, 'جدول مخصص بعد الاستبيان تستلمه كملف، وتقدر تحمّله على جهازك. بدون متابعة.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي. الجداول لك مدى الحياة وتقدر تعدّل عليها.', false, NULL, 'published', 4, false, '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('980af9dd-af29-4bd9-a601-33f3c9d998b9', 'training-nutrition-plan', 'files', 'جدول تمارين مع التغذية', 'لمن لا يحتاج متابعة (متقدم)، أو كبديل أوفر للتدريب الشخصي', '[{"text": "جدول تمرين مخصص لعدد أيام التمرين اللي تحتاجها", "included": true}, {"text": "طريقة حساب الجهد وعدد الجولات المطلوبة", "included": true}, {"text": "جدول تغذية فيه خيارات تناسب هدفك الرياضي", "included": true}, {"text": "تقدر تحمّل الجدول على جهازك", "included": true}]', NULL, 'جدول مخصص بعد الاستبيان تستلمه كملف، وتقدر تحمّله على جهازك. بدون متابعة.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي. الجداول لك مدى الحياة وتقدر تعدّل عليها.', false, NULL, 'published', 5, false, '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('2d737893-4630-4504-8251-cdf132b68328', 'nutrition-consultation', 'consult', 'جلسة استشارة تغذية', 'لمن عنده أسئلة محددة في التغذية: جلسة وحدة تكفي لحسبة سعراتك ونصائح الأكل.', '[{"text": "مناقشة كل أسئلتك في مجال التغذية", "included": true}, {"text": "حسبة سعرات مناسبة لهدفك مع اقتراحات لأصناف الطعام", "included": true}, {"text": "نصائح في المكملات، وكيف تأكل برّا بطريقة صحيحة", "included": true}]', NULL, 'جلسة عبر Google Meet أو واتساب — المناسب لك.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي.', false, NULL, 'published', 6, false, '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('13497080-5ddf-4188-a9dc-57b733e45b0c', 'training-consultation', 'consult', 'جلسة استشارة تمرين', 'لمن عنده أسئلة محددة في التمرين: جلسة وحدة تكفي لتعديل جدولك وتصحيح التكنيك.', '[{"text": "مناقشة كل أسئلتك في مجال التمرين", "included": true}, {"text": "تعديل جدولك الرياضي بما يناسب هدفك، مع اقتراحات لتمارين المرونة", "included": true}, {"text": "تصحيح تكنيك التمارين اللي تشك إنها غلط أو تسبب لك ألم", "included": true}, {"text": "التأكد من أن جودة تمرينك مناسبة للبناء العضلي", "included": true}]', NULL, 'جلسة عبر Google Meet أو واتساب — المناسب لك.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي.', false, NULL, 'published', 7, false, '2026-09-27 11:29:28.468315+00', '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;



INSERT INTO public.product_offers VALUES ('445b6361-7bb6-439b-84d9-61bc21ec0356', 'b483d6ec-2d78-4ac0-ba22-84c1dec6eac7', 'int1', 'شهر واحد', 1, 59900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('7fca95e4-1570-4892-9fbc-ea407dad7ac3', 'b483d6ec-2d78-4ac0-ba22-84c1dec6eac7', 'int3', '3 أشهر', 3, 155000, 'SAR', true, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('c84b7dec-a3de-4874-aaa5-18961170d043', '33eaf6fb-b622-4eed-814c-fa5104bd6633', 'adv1', 'شهر واحد', 1, 49900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('67baf79e-caa5-4dd5-b63f-4bdfb71db69e', '33eaf6fb-b622-4eed-814c-fa5104bd6633', 'adv3', '3 أشهر', 3, 125000, 'SAR', true, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('7c08459c-ff1d-4e2d-b722-0b2e6cb95e9a', '94caa529-8593-436e-9f5e-9e8273632374', 'bas1', 'شهر واحد', 1, 34900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('1df7ef75-f71c-44c9-a0ec-459a99e14329', '94caa529-8593-436e-9f5e-9e8273632374', 'bas3', '3 أشهر', 3, 95000, 'SAR', true, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('d42d8b7b-d296-48fa-9715-6f902fd19597', '80350d23-e433-4f27-92b0-adc66a64cb6c', 'nut1', 'شهر واحد', 1, 25000, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('934d6c8c-c4b3-445a-afc1-640a0732bc37', '45a664bd-8c07-4fe6-89e2-ae92c00d806b', 'diy', 'دفعة واحدة', 0, 19900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('1a9b7b48-6611-4c49-88a1-16bd07922821', '980af9dd-af29-4bd9-a601-33f3c9d998b9', 'diyN', 'دفعة واحدة', 0, 25000, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('1972dc48-afea-4a3d-9dc4-4cff12ad6ce2', '2d737893-4630-4504-8251-cdf132b68328', 'cN', 'دفعة واحدة', 0, 15000, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('bd9e255c-7ae4-4768-b22b-245c1c05dda1', '13497080-5ddf-4188-a9dc-57b733e45b0c', 'cT', 'دفعة واحدة', 0, 18900, 'SAR', true, 0) ON CONFLICT DO NOTHING;



INSERT INTO public.reviews VALUES ('06914987-abdf-4dd2-b90a-d49261e92251', 'legacy', NULL, NULL, NULL, NULL, 'اشتركت معها 3 شهور وكانت أول مره التزم بالتمرين بعد سحبات سنين، اسلوبها سهل وسريع بس نتايجه واضحه من اول اسبوعين قياسات جسمي بدت تتغير والكوتش مريحه نفسيًا وشاطرة الله يعطيها العافيه غيرت حياتي واعطتني افضل بداية 🙏🏻', 'first', 'ريم', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 0, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('a5c427b8-041a-47ec-a11b-c833c4a82417', 'legacy', NULL, NULL, NULL, 5, 'من أصدق التجارب اللي مرّيت فيها! تدريبك ما كان بس جداول رياضه وتغذية كان دعم نفسي وتحفيز وتغيير حقيقي في حياتي حسّيت بفرق كبير في جسمي وطاقتي وثقتي بنفسي من أول أسبوع شكراً من القلب على تعبك وحرصك على كل تفصيلة وتعطي من قلبك، فعلاً you are the best coach ever تستاهلين كل النجاح والله ❤️', 'first', 'نورة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 1, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('068d54c9-5687-4fb9-b4c4-23bd4f88b344', 'legacy', NULL, NULL, NULL, 5, 'بعد شهر من الالتزام بالجدول، لاحظت فرق واضح! متنوع وفعال، أنصح فيه بشدة 😍👌', 'first', 'البندري', 'مارس 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 2, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('9716463d-81cc-42a9-badd-07e888ecc8b2', 'legacy', NULL, NULL, NULL, NULL, 'رغم ان فتره تدريبي معاها كانت اقل من شهرين السنه الماضيه الا ان نتايج هالشهرين مستمره معي الى اليوم 😍 اسلوب احترافي وفعال وتركز على بناء وتطوير عادات تدوم مو بس تمارين مؤقته 👍🏻', 'first', 'خديجة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 3, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('41204993-ba94-4040-b80b-4ef3be62897a', 'legacy', NULL, NULL, NULL, 5, 'كوتش ساره جداً شاطره و بروفيشنال، جداً متعاونه و تعرف شغلها كويس، جداً لطيفه، كنت لفتره متدربه عندها و كنت أشوف نتايج بطله بالاضافه لكوني اروح اتمرن و أنا مستمتعه، شكراً ساره', 'first', 'نجمة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 4, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('f92f4733-7424-4633-9e6b-63933797c867', 'legacy', NULL, NULL, NULL, 5, 'ممتاز جدول حلو ومرتب جدا وفرق معي كثير 🤍', 'first', 'سعود', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 5, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('51dac357-48ad-4459-8011-fa021fcd95bc', 'legacy', NULL, NULL, NULL, 5, 'كنت اعاني من الم بظهري مستمررر سنوات وانحراف بالعمود ولكن بفضل الله ثم المدربة تحسنت بنسبة كبيرة وتابع معي خطوة بخطوة بكل أمانة وإتقان الله يكثر من امثالك 🤍', 'first', 'ش**س**', 'أغسطس 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 6, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('6495774e-43c8-4ed2-a366-e5534e5a3259', 'legacy', NULL, NULL, NULL, 5, 'الشكر يعجز عنك يااروع كوتش باشتراكي معك شفت صحة وراحة بعد الله وساعدتيني مره بمشكلة ظهري وضعف العضلات العلوية وانعكس على نفسيتي وادائي اليومي شكررا شكرا من القلب وياحظنا فيك', 'first', 'فاطمة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 7, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('8618e36f-18bf-4794-9e91-089a948c819d', 'legacy', NULL, NULL, NULL, 5, 'مره استفدت بالتدريب مع كوتش ناف و مبسوطه ان في احد بذمة و ضمير جالس يتابع تقدمي و ينصحني من قلب الله يسعدك ويوفقك ❤️', 'first', 'ميثاء', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 8, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('4b4c28f7-8428-4f56-ad40-d3aa9f7f8ac4', 'legacy', NULL, NULL, NULL, 5, 'تجربه ولا أروع ! أحب جداولها وقد ايش تختصر وتعطيك المهم والاهم والنتايج رهيييبه ❤️', 'first', 'أمجاد', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 9, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('d8f32a0d-34ba-4bbb-b817-e1833969ece3', 'legacy', NULL, NULL, NULL, 5, 'افضل مدربة بالمجرة، كنت دبه ونحفت بثلاث شهور بس، i highly recommend her she is the best 💗', 'first', 'شروق', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 10, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('18da186d-f5df-4b6c-ac47-987479d97cf7', 'legacy', NULL, NULL, NULL, 5, 'الجدول ممتاز و فعّال لفترة الصيام، يساعدك تنظم وقتك ويقدّم توصيات غذائيه و خطه تمارين تساعدك تحافظ على لياقتك بدون إرهاق 👍🏻. خيار ممتاز خاصة للأشخاص للي وقتها محدود ومزحوم فرمضان.', 'first', 'خديجة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 11, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;



INSERT INTO public.site_settings VALUES ('reminders', '{"review_text": "مرحباً {name}، تذكير بمراجعتك الأسبوعية: المراجعة مفتوحة من {window_start} إلى {window_end}.", "sub_expiry_days": [7, 3], "sub_expiry_text": "مرحباً {name}، اشتراكك في {product} ينتهي بتاريخ {end_date}. للتجديد أو الاستفسار تواصل معنا.", "review_lead_days": 1, "missed_review_text": "مرحباً {name}، ما وصلتنا مراجعة الأسبوع المنتهي في {window_end}. متى ما تيسّر لك، حدّثها عشان نتابع تقدمك.", "review_window_days": 2, "manual_cooldown_minutes": 10}', false, NULL, '2026-09-27 11:29:28.21359+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('hero', '{"lead": "خطة تدريب وغذاء منظمة، متابعة للتقدم، وتعديلات أسبوعية تناسب مستواك وظروفك.", "title": "برامج تدريب وتغذية مخصصة لأهدافك", "eyebrow": "Nav Coaching · الكوتش ساره", "tagline": "Where Passion Meets Quality", "title_tail": "تحت إشراف مدربة يدفعها الشغف"}', true, NULL, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('badges', '["خصم 10% للطلاب", "مجاني لأهل غزة", "ضمان استرجاع المبلغ بشروط"]', true, NULL, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('why', '[{"body": "البرنامج يُصمم بعد استبيان مفصل لهدفك وأيامك المتاحة وأدواتك وأي إصابة تحتاج مراعاة.", "title": "مبني على هدفك ومستواك"}, {"body": "مراجعة منتظمة بالفيديو أو الصوت، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.", "title": "متابعة أسبوعية واضحة"}, {"body": "نعدّل التمرين والسعرات بناءً على قياساتك والتزامك، عشان تثبت النتيجة.", "title": "تعديلات حسب تقدمك"}]', true, NULL, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('how_steps', '[{"body": "اختر الباقة والمدة، وعبّي استبيان قصير عن هدفك ومستواك وأيامك وأي إصابة.", "title": "اختر برنامجك وعبّي الاستبيان"}, {"body": "بعد الاستبيان يظهر لك رقم طلبك وبيانات الحساب. حوّل وارفع صورة الإيصال من صفحة طلبك.", "title": "حوّل المبلغ"}, {"body": "بعد التحقق من التحويل أتواصل معك خلال 48 ساعة عمل، وتستلم ملف برنامجك وتبدأ المتابعة.", "title": "استلم برنامجك وابدأ"}]', true, NULL, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('about', '{"bio": "مدربة شخصية معتمدة، أدرب منذ 2017. أساعدك تبني روتين تدريب وتغذية واضح يناسب هدفك ووقتك ومستواك، مع متابعة أسبوعية تساعدك تستمر وتتقدم.", "fit": ["اللي يؤمن إن التمرين أسلوب حياة، مو تمرين لشكل مؤقت أو لفترة الصيف بس.", "**وإذا ما التزمت؟** أحاول أفهم أسبابك، وأساعدك تعالجها بقدر ما أقدر. وإذا كان الموضوع أكبر من اللي أقدر أقدمه، أقول لك بصراحة وأعتذر عن تدريبك."], "name": "الكوتش ساره | ناڤ", "certs": ["Saudi Reps — Level 4", "NCSF", "Menno Henselmans CPT", "Functional Mobility", "Pre & Postnatal Training", "Prenatal Fitness Training — Aspire Academy", "ماجستير تدريب رياضي — جامعة ستيرلنق"], "notes": [{"body": "لأني جاية من عالم الرياضات الإلكترونية، صممت باقة خاصة للقيمرز: لياقة أفضل داخل وخارج الشاشة، والتعامل مع آلام الظهر والمفاصل من الجلوس الطويل.", "href": "/programs/gamers", "label": "شوف باقة القيمرز ←", "title": "للاعبي الألعاب الإلكترونية"}, {"body": "تدريب الحوامل عندي حضوري فقط. أونلاين يصعب أتأكد إن التمرين يتنفذ بإتقان، والحمل فترة مهمة جداً تحتاج هالتأكد. أونلاين أقدم للحوامل متابعة التغذية فقط.", "href": "", "label": "", "title": "للحوامل"}], "story": ["قبل ما أصير مدربة، كنت متدربة تعبت من التجارب. اشتركت مع مدربات أجانب، وما لقيت أحد يشرح لي التمرين صح أو يهتم بأهدافي.", "لين اشتركت مع الكوتش سحر الحارثي. غيّرت نظرتي للتمرين، وحفّزتني أصير كوتش، وإلى اليوم أشكرها على كل اللي علمتني إياه. من هنا قررت أكون الشخص اللي احتجته أنا.", "والرياضة جزء مني من بدري: لعبت كرة السلة وكنت كابتن فريق السلة في جامعة الإمام عبدالرحمن بن فيصل، ولعبت باحتراف في الرياضات الإلكترونية. بدأت التدريب في 2017 مع كرة السلة، واشتغلت مساعد مدرب في نادي الجامعة، وبعدها دربت في بيور جم وجمنيشن وفتنس لاونج ونوادي خاصة."], "points": ["برنامج مبني على هدفك ومستواك.", "متابعة أسبوعية واضحة.", "تعديلات مستمرة حسب تقدمك والتزامك."], "pillars": [{"body": "ما أرسل لك جدول وأتركك. أراجعه معك بمقطع فيديو أشرح فيه كل شي، عشان تبدأ وأنت فاهم وش تسوي وليش.", "title": "جدولك مشروح بالفيديو"}, {"body": "ما أمشي على أنظمة الحرمان أبداً. خطتك تناسب حياتك، مو قائمة ممنوعات.", "title": "بدون حرمان"}, {"body": "أتابعك كل أسبوع وأهتم بالتزامك، وأعدّل خطتك حسب تقدمك وظروفك.", "title": "متابعة جادة وخطة واقعية"}, {"body": "حب تعليم الناس معي من الصغر. اللي أعرفه ما أبخل فيه، علمياً ونفسياً، وما أوقف عن البحث والتعلم عشان أتطور وأطورك معي.", "title": "أعلّمك، مو بس أدربك"}], "home_bio": "مدربة شخصية معتمدة، أدرب منذ 2017، وكابتن سابقة لفريق السلة في جامعة الإمام عبدالرحمن بن فيصل. أساعدك تبني روتين تدريب وتغذية واضح يناسب هدفك ووقتك ومستواك، مع متابعة أسبوعية وبدون أنظمة حرمان.", "fit_title": "أكثر شخص أفرق معه", "experience": ["أدرب منذ 2017، والبداية في كرة السلة.", "مساعد مدرب في نادي الجامعة.", "مدربة في بيور جم، وجمنيشن، وفتنس لاونج، ونوادي خاصة."], "story_title": "صرت الشخص اللي كنت أحتاجه", "pillars_title": "وش يميز التدريب معي؟", "experience_title": "شهاداتي وخبرتي"}', true, NULL, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('intro_video', '{"url": "", "body": "مقطع قصير أتكلم فيه عن نفسي وخلفيتي وطريقة شغلي مع المتدربين.", "title": "تعرّف عليّ في دقيقة"}', true, NULL, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('testimonials_disclaimer', '"التجارب شخصية وتختلف النتائج من شخص لآخر حسب الالتزام والحالة، والتدريب لا يغني عن استشارة الطبيب أو أخصائي العلاج الطبيعي."', true, NULL, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('prices_note', '"الأسعار بالريال السعودي. الدفع بتحويل بنكي على حساب المؤسسة."', true, NULL, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('checkins', '{"enabled": true, "questions": [{"q": "ملاحظاتك الصحية؟ الحركة اليومية وجودة الحياة صارت أحسن؟", "topic": "الصحة العامة"}, {"q": "أداؤك في التمارين؟ في تقدم في الأوزان والأداء؟", "topic": "التمارين"}, {"q": "فرق في شكلك ومظهرك؟ إيجابي أو سلبي؟", "topic": "المظهر"}, {"q": "فرق في الملابس أو المقاسات؟ إيجابي أو سلبي؟", "topic": "الملابس"}, {"q": "النظام الغذائي — قدرت تمشي عليه؟ فيه صعوبة؟", "topic": "الغذاء"}, {"q": "تحسّ بالجوع واجد؟ إن وُجد، كم تعطيه من 5؟", "topic": "الجوع"}, {"q": "أي ملاحظات سلبية تبي تشاركها؟ (مهمة أو بسيطة — نتقبل النقد)", "topic": "ملاحظات سلبية"}, {"q": "أي إشكاليات أو ملاحظات إضافية تحتاج مساعدة فيها؟", "topic": "ملاحظات أخرى"}, {"q": "وصلت لأي أسبوع تدريبي الآن؟", "topic": "الأسبوع"}]}', true, NULL, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('contact', '{"whatsapp": "966599162724", "instagram": "https://www.instagram.com/navvcoaching/"}', true, NULL, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('response_time', '"48 ساعة عمل (الأحد – الخميس، 12 ظهراً – 9 مساءً)"', true, NULL, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('legal', '{"cr": "7050950752", "name": "مؤسسة ناف كوتشنق للتدريب الرياضي"}', true, NULL, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('bank', '{"iban": "SA1280000139608016245411", "bankName": "مصرف الراجحي", "accountName": "مؤسسة ناف كوتشنق للتدريب الرياضي"}', true, NULL, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('program_shots', '[{"h": 368, "w": 1310, "alt": "لقطة من ملف المتدرب: جدول اليوم الأول لتمارين الجزء السفلي مع الجولات والتكرارات وRIR", "src": "shots/training.webp", "title": "جدول التمرين", "caption": "جدول لكل يوم تدريبي: التمرين، الجولات، التكرارات، الوزن، وRIR، وتظهر العضلة الأساسية والثانوية تلقائياً."}, {"h": 473, "w": 1472, "alt": "لقطة من ملف المتدرب: قائمة منسدلة لاختيار التمرين أو البديل مع العضلة الأساسية والثانوية", "src": "shots/exercise-picker.webp", "title": "اختيار التمرين والبدائل", "caption": "تختار التمرين أو بديله من قائمة منسدلة، وتتحدث العضلات المستهدفة مباشرة."}, {"h": 634, "w": 1034, "alt": "لقطة من لوحة التقدم في ملف المتدرب ببيانات مثال: الوزن والقياسات والخطوات الأسبوعية مقابل الهدف", "src": "shots/progress.webp", "title": "لوحة التقدم", "caption": "متوسط الوزن الأسبوعي والقياسات والخطوات مقابل الهدف، ببيانات مثال."}, {"h": 641, "w": 1600, "alt": "لقطة من ورقة المراجعة الأسبوعية في ملف المتدرب: أسئلة المراجعة بدون إجابات", "src": "shots/weekly-review.webp", "title": "المراجعة الأسبوعية", "caption": "أسئلة ثابتة كل أسبوع عن الصحة والتمارين والغذاء والجوع، وبجانبها ملاحظات المدربة."}]', true, NULL, '2026-09-27 11:29:28.468315+00') ON CONFLICT DO NOTHING;
COMMIT;
