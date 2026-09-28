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

-- ---------- المحتوى المستورد من الموقع الحالي ----------
INSERT INTO public.exercises VALUES ('559e96e2-16c1-4c7d-aa5e-d10fab29811c', 'Single Leg Raise', 'Core / البطن والكور', '{"Glutes / المؤخرة","Hamstrings / الخلفية"}', NULL, NULL, 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/ZJodU5OOaiA?si=p6ZD9dpzyRKBUn16', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3fc1bf4b-5ca5-43a8-811b-b6a27ce0fd77', 'Back Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/bEv6CCg2BC8', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f2d4440d-c2f2-4302-8d13-695fae0528df', 'Box Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtube.com/shorts/9uhEh9gpwUU?si=xaTY7AJiCeQfa3by', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل.', 'تعليمات بديلة في المصدر (صف 13): ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل، انزل واثبت على البوكس ثانية وارفع.', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a895d53b-74ea-4e5a-94a1-c8eba4e94208', 'Hack Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/0tn5K9NlCfo', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Machine Squat / سكوات بالجهاز', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('84c514a0-38ec-4a08-83ac-cf56384c3c5d', 'Mid Leg Press', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/s9-zeWzPUmA', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Leg Press / ضغط الأرجل', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('823018b3-f692-419e-a731-074361f36135', 'Quads Leg Press', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/A218isnErfM', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي، ثبت القدمين أسفل اللوح لاستهداف أكبر للكوادز.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Leg Press / ضغط الأرجل', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4080f40a-94c5-488c-8696-3e0e361867a9', 'Deficit Goblet Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/9719SO5zvpU?si=whohbunAsXkH3j6f', 'وقف باتساع اكتافك تقريبًا، ادفع ركبك للامام وانزل، انزل لأقصى حد تقدر عليه بدون ما يتقوس ظهرك السفلي.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9a3de3af-203f-4472-9e10-6261a73e5277', 'Front Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'بار', 'متوسط', 'نادي', NULL, 'ثبت البار على الأكتاف، ادفع ركبك للامام وانزل.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('236c3e48-e38b-4a91-a74d-187003e368b0', 'V Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://www.youtube.com/watch?v=u_GSjH58s0g', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Machine Squat / سكوات بالجهاز', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('01b9d2b3-3fd6-49e0-a5b2-89446b3fc032', 'Resistance Band Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/6rE0IYlMPZA?si=goqtRTlR_W4HSGBN', 'ثبت الباند علي جوانب اكتافك، ادفع ركبك للأمام وإنزل.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('975701ce-0d5c-4777-9290-f3b2f0bc2995', 'Squat Smith Machine', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/oBwhrRcNWyM', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Machine Squat / سكوات بالجهاز', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1b87e59d-1b1d-4db1-8cf0-6409e34d6f39', 'Single Leg Press', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/ZYDTJaAM-gE', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Single-leg Press / ضغط رجل واحدة', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('235f693c-13db-4fb6-8ec1-5bed0d9f5aeb', 'Drop Lunges', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/WH8lteLrMIs?si=61QSVA7iw_Z6Zr3p', 'تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('421ecaf6-0ef0-48bc-ae1f-69476c2510b5', 'Beginner Lunges', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/QOVaHwm-Q6U', 'تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b138d2e1-269f-4768-8a37-6281884ab769', 'Standing Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/rDRwAURNbzU', 'الحركة كلها بثني ومد الركبة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f0e523e7-ecb0-409f-b0d1-364de23423b5', 'Supported BSS', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/poBie3TTeGE?si=QSiMUYtcHhrmg8mx', 'وقف عند البنش او الستيب، ارفع رجلك وثبت اصابع قدمك على البنش، خذ خطوة وحدة للأمام برجلك الثانية ثم ابدأ التمرين، تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Split Squat / سبليت سكوات', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('edfa3417-22bb-4716-a9f3-c0073d9465e3', 'Supported Reverse Lunge', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/WH8lteLrMIs?si=M9s9a7qOVvvyDm82', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3f162607-b8be-428c-8123-69bdc28a0bdd', 'Smith Machine Reverse Lunge', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/zAVYcwnlxrQ?si=M5HL4sG-bsYBFyDQ', 'استخدم ارتفاع بسيط مثل الستيب ، ارفع نفسك بالضغط علي الرجل المرفوعة بتحكم بدون قفز.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2236da86-0d2c-4ddb-9cb1-d8206192f270', 'Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/gtZ4AwZVtMI', 'اجلس وثبت ظهرك السفلي كويس، تأكد ان مسمار الارتفاع يكون بمستوى ركبتك، امسك المقابض لزيادة الثبات، إرفع الوزن اثبت ثانية فوق ثم انزل نزول كامل بتحكم.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2ac8405f-b85d-4e89-b7ae-2f3e371ec99a', 'Single Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/82IuSLk5zNc?si=FTMqZrmawQFRr8dN', 'اجلس وثبت ظهرك السفلي كويس، تأكد ان مسمار الارتفاع يكون بمستوى ركبتك، امسك المقابض لزيادة الثبات، إرفع الوزن اثبت ثانية فوق ثم انزل نزول كامل بتحكم.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3d6efee2-6528-4e11-b290-1998ffe4c408', 'Band Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/hs7D3gDw3UM', 'اجلس وثبت ظهرك السفلي كويس وامسك الكرسي للثبات، اثبت ثانية فوق ثم انزل نزول كامل بتحكم.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a6bd2116-1f13-4c3d-bc3a-8b4176a8cb1f', 'Sissy Squat', 'Quadriceps / الأمامية', '{"Adductors / الأفخاذ الداخلية"}', 'Knee Extension / مد الركبة', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://youtu.be/yONKTprKCDA', 'الورك ثابت طول الجولة والحركة كلها من مفصل الركبة، اذا توازنك يخرب عليك ادبل الوزن بيد واليد الثانية امسك فيها جدار او عصى', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Sissy Squat / سيسي سكوات', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0c1d94ea-7fd0-436c-b8d2-6c8495d0bfa3', 'Cable Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/ebjD98gZd8E', 'اجلس وثبت ظهرك السفلي كويس وامسك الكرسي للثبات، اثبت ثانية فوق ثم انزل نزول كامل بتحكم.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('59a56eeb-2f59-4d6c-b113-8a7d62dbce2f', 'Standing Leg Extension', 'Quadriceps / الأمامية', '{"Core / البطن والكور"}', 'Knee Extension / مد الركبة', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/133/standing-leg-extension/', NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('84152864-255c-4543-a886-70cd2c3cf0b3', 'Bodyweight Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Lower back / أسفل الظهر"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/135/bodyweight-squat/', NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0deb4e76-9a71-43d3-bea0-6c19ae1d231b', 'Cable Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/mBJXWg8ZOy0', 'اجلس على الكرسي وثبت ظهرك السفلي على المقعد تمامًا، ممكن تقدّم ظهرك العلوي وتمسك المقابض لزيادة الثبات، انزل لأقصى حد تقدر عليه وارفع لحد ما تستقيم ركبتك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('743f4771-4023-4d48-ab1c-682eb47cc4da', 'DB Glutes Step Ups', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/GCnJiYJfboA?feature=share', 'استخدم ارتفاع يكون بحدود ارتفاع ركبتك أو أقل، ارفع نفسك بالضغط علي الرجل المرفوعة بتحكم بدون قفز.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('442e23ec-4d44-4cd6-b4a7-fd3e5af9c665', 'Supported Glutes Step Ups', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/ZKzoOkQALaY?si=-56txwBlxSSCQYJd', 'استخدم ارتفاع يكون بحدود ارتفاع ركبتك أو أقل، ارفع نفسك بالضغط علي الرجل المرفوعة بتحكم بدون قفز.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('54db7505-e75b-4e32-b383-67322a33dbac', 'Cable Glutes Step Ups', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('97ee4720-ffc8-40e2-8de6-b37f8f5aeda0', 'Glute Pushdown', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/8h2kZ64Sp5k?si=NLPf4tywxhDGY9em', 'تمسك بمقابض الجهاز، (كل ما زاد ارتفاع البنش زادت الصعوبة) + الطلوع والنزول يكون بواسطة القدم المرفوعة على البنش مو بالقدم اللي تحت، ارفع بتحكم الى أقصى ارتفاع تقدرعليه بدون ما يتقوس ظهرك السفلي، انزل لحد ما تقفل ركبتك تماما', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('543d6b1a-fbbd-4a42-9e32-be57e752baae', 'Glute Max Kickbacks', 'Glutes / المؤخرة', '{}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/t5mwSx4uNMc?feature=share', 'ثبت الحبل على الكاحل، ارجع خطوة للخلف وانحني للامام قليلاً وتمسك بالكيبل لزيادة الثبات، اسحب للخلف مع انثناء بسيط بالركب.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Kickback / ركلة خلفية', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4a5b7be4-b43e-419d-91ef-3b1ade99554b', 'Smith Machine Kickback', 'Glutes / المؤخرة', '{}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/GR4ny80bmhM?si=WeZcWM1hyfoLElM2', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Kickback / ركلة خلفية', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('05805aa6-b849-488b-8656-a71f2d9fd1f3', 'Glute Medius Kickbacks', 'Abductors / مبعدات الفخذ', '{"Glutes / المؤخرة"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/kccsnZNbMFA?si=6c-VoB8Zsz8NxoyM', 'ثبت الحبل على الكاحل، ارجع خطوة للخلف وانحني للامام قليلاً وتمسك بالكيبل لزيادة الثبات، اسحب للخلف وللخارج مع انثناء بسيط بالركب.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Abduction Kickback / ركلة خلفية مع تبعيد', 'Hip Abduction + Hip Extension / تبعيد الورك + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('77656cc9-59a7-489a-801d-bb37669fb175', 'Hip Thrusts Machine', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/0xfdeCBwoYw?si=HgJcNeB0a24gODkK', 'ممكن تسويه بالسميث مشين او البار الحر ، اختر بوكس او بنش يكون بمستوى اكتافك الخلفية وانت جالس، لما ترفع البار فوق المفروض ركبك تكون بنفس مستوى القدم.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ba064819-13bb-4035-bacb-abe76e01f519', 'Hip Thrusts', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/O0EoaP7gR1A?si=cGPZ8iIwM2mQjwSb', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('83a7600d-b546-450d-9672-88d698956709', 'Glute Raise', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/X_kL_x4m77c', 'ثبت رجولك تحت، الاسفنجة تكون تحت الورك أعلى الفخذ مو على الورك مباشرة، امسك وزن بيدينك بذراع مستقيمة، ارفع وكأنك تبي تدخل القلوتس جوا الاسفنجة، بمجرد ما تنقبض مؤخرتك وقف لا ترفع أكثر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', '45° Hip Extension / بسط الورك على جهاز الظهر', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f9c99d68-36b6-42f6-86a6-6edc08cf3293', 'Single Hip Thrusts', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/ymg2AMDAwrY?si=fY8kBPTDYWRMHuAs', 'اختر بوكس او بنش يكون بمستوى اكتافك الخلفية وانت جالس، لما ترفع فوق المفروض ركبك تكون بنفس مستوى القدم، التمرين صعب طبيعي تواجه صعوبة بالبداية لذلك لا تستعجل باضافة الاوزان', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3eb0c949-d937-4e8a-b4dc-bc46c1ae970c', 'Glute Press', 'Glutes / المؤخرة', '{}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/293/glute-press/', NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Kickback / ركلة خلفية', 'Hip Extension + Knee Extension / بسط الورك + مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f0f59bf0-d49e-4efb-9408-14dab2a76550', 'Bulgarian Split Squat', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/366/bulgarian-split-squat/', NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Split Squat / سبليت سكوات', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('320c2fb2-cffe-4340-8416-0b70184beec6', 'Sumo Deadlift', 'Hamstrings / الخلفية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://www.youtube.com/watch?v=cDlOSfu-zHY', 'وقف بفتحة أرجل واسعة بحيث الركب تكون خط مستقيم مع كعب القدم و اصابع الرجل باتجاه الخارج، البار بمنتصف القدم، شد ظهرك العلوي وادفع الارض برجولك واسحب البار للأعلى، وقف لما تنقبض مؤخرتك ولا تبالغ بتقفيل حوضك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Deadlift / ديدلفت', 'Hip Extension + Knee Extension / بسط الورك + مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b73035c2-cc76-4ce1-8544-0ebb15350308', 'Conventional Deadlift', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/GxsLrTzyGUU', 'وقف باتساع اكتافك أو أوسع شوي، البار بمنتصف القدم، شد ظهرك العلوي وادفع الارض برجولك واسحب البار للأعلى، وقف لما تنقبض مؤخرتك ولا تبالغ بتقفيل حوضك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Deadlift / ديدلفت', 'Hip Extension + Knee Extension / بسط الورك + مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8b4303d2-fe0d-47e6-abf2-faba9946af89', 'Supine Cable Hamstring Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/sDCc1F5J8XA?si=Fi3D39aJogrB5ihd', 'الركبة ثبت مكانها، اسحب الحبل لاقصى حد تقدر عليه واترك رجلك تستقيم تمامًا في الانبساط.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('baea4d9e-c409-45d0-8cc1-16b35455689c', 'BB RDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/mZxxJEncsyw', 'وقف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، انزل وادفع مؤخرتك لآخر شي تقدر عليه للخلف وكأنك بتلمس جدار خلفك مع انثناء بسيط بالركب', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2d51ca76-f1ca-47ac-a1ba-058f8a2938cc', 'DB RDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/RApyTtH6qAo', 'وقف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، انزل وادفع مؤخرتك لآخر شي تقدر عليه للخلف وكأنك بتلمس جدار خلفك مع انثناء بسيط بالركب', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('97fff122-5563-4f52-a21c-1fbdd8ada0bb', 'SM SLDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/0cB0_SzqgBU', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('de44e09c-a2d8-4a5c-a9df-b7f8eec9efd6', 'SLDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/RApyTtH6qAo', 'قف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، ابدأ الحركة بدفع مؤخرتك للخلف والأعلى وانزل', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f4b74aaa-f03e-4401-b240-9108f3303e94', 'Single DB SLDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/U3prDlAbJDw?si=MRSBcSIcf9M-WQBH', 'قف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، ابدأ الحركة بدفع مؤخرتك للخلف والأعلى وانزل', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9cc8f244-c140-48b7-8022-8ddaf55086de', 'Good Morning', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/f23vXjoG2e8?si=9rkfUF_6XUEcQ3Xs', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع مؤخرتك لأقصى قدر تقدر عليه وكأنك بتلمس جدار خلفك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Good Morning / قود مورنينق', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('41bfe8f5-c075-4ae0-9f0d-4de27b12e3cb', 'Seated Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/o_J6MWyt5jM', 'اجلس على الكرسي وثبت ظهرك السفلي على المقعد تمامًا، انزل لأقصى حد تقدر عليه وارفع لحد ما تستقيم ركبتك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1208d6cd-359d-467e-a7d9-7f84a1ee885f', 'Band Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/I-HTMUrJnxs', 'ثبت الباند فوق الكعب، اجلس على طرف البنش وتمسك بيدينك لزيادة الثبات، اسحب الحبل لاقصى حد تقدر عليه واترك رجلك تستقيم تمامًا في الانبساط.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4a5ea5cc-67a2-46cd-86fe-a23d2b211107', 'Lying Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/vl5nUdE9mWM', 'حوضك ثابت على البنش، ارفع الوزن بثني ومد الركبة بدون ما يرتفع حوضك عن الكرسي', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d215fd43-2837-4eeb-ac78-aa283ecc2a6a', 'DB Lying Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/ZHlBSI6JPsA?si=SpBiHxluwrYE8CTP', 'ركبك ثابته على الارض، ارفع الوزن بثني ومد الركبة بدون ما يرتفع حوضك', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9223bb94-c2c1-46f3-8cda-6df4b3de1a63', 'Nordic Hamstring Curl', 'Hamstrings / الخلفية', '{}', 'Knee Flexion / ثني الركبة', 'قوة', 'وزن الجسم', 'متقدم', 'بدون معدات', 'https://youtu.be/Lgibr8od0yA?si=nfRetEkDRk55Bu0a', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Nordic (Eccentric) / نوردك (لامركزي)', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0d6d03e2-2363-4194-b050-177f7933cdd1', 'Stability Ball Hamstring Curl', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة"}', 'Knee Flexion / ثني الركبة', 'قوة', 'كرة سويسرية', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/59/stability-ball-hamstring-curl/', NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Bridge Curl / ثني الركبة مع رفع الورك', 'Knee Flexion + Hip Extension / ثني الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7995fb58-4d91-4c82-9898-5f46fc1d0164', 'Hip Hinge', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/33/hip-hinge/', NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Hinge Drill / تمرين مفصلة الورك', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('42330662-2607-4a66-a08a-5a3c0a90804d', 'TRX Hamstrings Curl', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة"}', 'Knee Flexion / ثني الركبة', 'قوة', 'TRX', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/86/trx-reg-hamstrings-curl/', NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Bridge Curl / ثني الركبة مع رفع الورك', 'Knee Flexion + Hip Extension / ثني الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8f55644f-b823-4950-8316-c1d1165b81d3', 'Flat DB Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/xphvjGDZeYE', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ba2a3619-4ad6-497d-8659-63f042c5d56d', 'DB Floor Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/UBmpZ7l5Nlk?si=kDcN-ueaTFxfKtbr', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6cfe0d1c-7ca8-486d-8853-6ce65a27b687', 'Flat Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/vcBig73ojpE', 'استلق على بنش،القبضة بنفس مستوى الاكتاف أو أوسع قليلًا، قوّس ظهرك العلوي قليلاً، انزل لين تلمس صدرك واثبت ثانية ثم ارفع.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9e0d08fd-01cc-4ded-bc3d-5ce9d878a947', 'Machine Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/pOCRC2kpxB8?si=02xGtrfPjiYpspMv', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cfbdcabf-e7db-466a-8d54-b1ea769edda7', 'Feet Up Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/HrehfM1dmBE', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('297dc0c9-01ad-4c5e-a6b0-a7395f5f45ef', 'Torso Elevated Push Up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/noaPB7u4_CU', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا', 'تصنيف فرعي: اليدان مرفوعتان؛ زاوية الضغط بالنسبة للجذع تشبه الضغط المائل لأسفل رغم تسميته الشائعة Incline Push-up — يحدده المدرب', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Decline Press / ضغط مائل لأسفل', 'Horizontal Adduction + Shoulder Extension / تقريب أفقي + مد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c9313e39-c389-4d01-a9d3-9b9204ea34e4', 'Push Up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://youtu.be/WDIpL0pjun0?si=utydS_A8QfRIJtJm', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('196c8ff9-27d1-461a-892e-3e17cc68d640', 'Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://www.youtube.com/watch?v=JvOJdUtx6UQ', 'استلق على بنش،القبضة بنفس مستوى الاكتاف أو أوسع قليلًا، قوّس ظهرك العلوي قليلاً، انزل لين تلمس صدرك واثبت ثانية ثم ارفع.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('280bfdd4-874f-42a0-9f2f-55f74347b8bd', 'Paused Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://www.youtube.com/shorts/Q3GmnmJISwE', 'استلق على بنش،القبضة بنفس مستوى الاكتاف أو أوسع قليلًا، قوّس ظهرك العلوي قليلاً، انزل لين تلمس صدرك واثبت 3 ثواني ثم ارفع.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('34c3bc1a-05b0-4cd6-b765-a8869de76e84', 'Incline Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/0G2_XV7slIg', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Incline Press / ضغط مائل لأعلى', 'Shoulder Flexion + Horizontal Adduction / ثني الكتف + تقريب أفقي', 'Incline Press / ضغط مائل لأعلى', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('99145489-a01c-4e36-987c-de8d2228e87e', 'Smith Machine Incline Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/EeLLZMdg6zI?si=UVsgFN7jhXMm0vW3', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Incline Press / ضغط مائل لأعلى', 'Shoulder Flexion + Horizontal Adduction / ثني الكتف + تقريب أفقي', 'Incline Press / ضغط مائل لأعلى', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('156479a2-b9a8-4523-a32e-aefd5e673329', 'Cable Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/tAILewhtCb0', 'اجلس على بنش انكلاين، اضبط الكيبل بمستوى صدرك تقريبا، ادفع الوزن للأمام باتجاه الداخل، احرص ان كوعك ما يكون بنفس ارتفاع كتفك', 'تصنيف فرعي: التعليمات تذكر بنش انكلاين، وتصنيف المصدر iso_push_chest — يُحسم بين Incline Press وعزل الصدر', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Incline Press / ضغط مائل لأعلى', 'Shoulder Flexion + Horizontal Adduction / ثني الكتف + تقريب أفقي', 'Incline Press / ضغط مائل لأعلى', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9458e3dc-934b-49f7-b7bd-6209f6b5faa3', 'Sternal Cable Press Around', 'Chest / الصدر', '{}', 'Horizontal Push / دفع أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/y8XQibXDnNo', 'اضبط الكيبل بمستوى صدرك تقريبا، حافظ على ذراعك قريبة من جسمك،ادفع الحبل للأمام باتجاه الداخل.', 'تصنيف فرعي: حركة مختلطة بين الضغط والـ Fly — يُحسم بين Flat Press وعزل الصدر', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Press-around / ضغط مع تقريب', 'Horizontal Adduction + Elbow Extension / تقريب أفقي + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('494bee12-e6d3-43ab-a6f3-617e13f2c85f', 'Machine Chest Fly', 'Chest / الصدر', '{}', 'Horizontal Adduction (Fly) / تقريب أفقي للكتف (فلاي)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Chest Isolation / عزل الصدر', 'Horizontal Adduction / تقريب أفقي للكتف', 'Chest Isolation / عزل الصدر', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e0f9b222-a8fc-46f7-a529-bff439ab77eb', 'Bar Cable Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/NhD3h6RG2TA?si=SoyNTIGB-nY2KiXl', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3a56bf5f-e7bb-4406-a956-b3bc508a62ad', 'Cable Chest Fly', 'Chest / الصدر', '{"Shoulders / الأكتاف"}', 'Horizontal Adduction (Fly) / تقريب أفقي للكتف (فلاي)', 'قوة', 'كيبل', 'مبتدئ', 'نادي', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/160/standing-chest-fly/', NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Chest Isolation / عزل الصدر', 'Horizontal Adduction / تقريب أفقي للكتف', 'Chest Isolation / عزل الصدر', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('965f909e-c18f-43ac-83ac-3e63070965fe', 'Bent Knee Push-up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/13/bent-knee-push-up/', NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d321ebcd-5cb2-48c4-a766-95c352fe9c11', 'Stability Ball Push-Up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس","Core / البطن والكور"}', 'Horizontal Push / دفع أفقي', 'قوة', 'كرة سويسرية', 'متوسط', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف فرعي: الزاوية تعتمد على موضع الكرة (تحت اليدين أو القدمين) — غير محدد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/63/stability-ball-push-up/', NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('606db03b-e3b1-45f7-a784-9a82339db1f9', 'Cable Reardelt Rows', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/uIdXVGjcfFE', 'ثبت نفسك بالكرسي، فتحة واسعة، الكيبل بمستوى اسفل صدرك، واسحب لما تنقبض اكتافك الخلفية.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Wide-grip Row / تجديف بقبضة واسعة', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2d69a8fb-bfd2-4dab-90bc-a25c9c73a686', 'Single Lats Pulldown', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/Qed5O9toqT8', 'اجلس على بنش واسند صدرك عليه، ارجع للخلف قليلا بحيث ان الكيبل ما يكون فوق راسك مباشرة، اسحب الكوع باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9d2a6f31-3327-4e2b-adcb-bdcdeaa322e4', 'DB Chest Supported Reardelt Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/x0v6GWYzI18?si=-jDt3D-ARIHouHjp', 'ثبت صدرك على الكرسي، فتحة واسعة، واسحب لما تنقبض اكتافك الخلفية.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Wide-grip Row / تجديف بقبضة واسعة', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ab75e45c-9ad4-4403-a29b-b283b871f220', 'Bent-over Barbell Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'بار', 'متوسط', 'نادي', NULL, 'ادفع مؤخرتك للخلف واثني ركبك، قبضتك بنفس مستوى اكتافك، اسحب لما تنقبض عضلات الظهر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4c30f212-7155-4a24-8344-82f648ddb11e', 'Cable Reardelt Fly', 'Shoulders / الأكتاف', '{"Rotator cuffs / الكفة المدورة"}', 'Shoulder Rear Pull / سحب خلفي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/bkejPHrPkmA?si=-O8q_5e72udoPRiY', NULL, 'تصنيف فرعي: حركة Fly (تبعيد أفقي للكتف) وليست سحباً أفقياً أو عمودياً', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Rear Delt Fly / فتح خلفي', 'Horizontal Abduction / تبعيد أفقي للكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d88cbc75-423c-4834-8a66-5e0bb25d2b18', 'DB Chest Supported Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/H75im9fAUMc', 'ثبت صدرك على الكرسي، فتحة واسعة، واسحب الدمبل باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('024c8227-9978-477f-bd39-39df0f548b3d', 'Head Supported Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/c6lkPMhuyFA?si=eUivRGYSi0W7PmVe', 'راسك ثابت على البنش بدون أي ميلان بالرقبة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9b7fa90b-5451-4760-9cb9-1957e4815bd1', 'Single Arm Dumbbell Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/QBjaGx8mS1o', 'اسحب باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('122aa21b-d029-4746-9fda-fe0bbe77e9e1', 'Single Arm Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/Qn_mHGObb8E?si=IZ0q9_tseiRIMtcs', 'اسحب باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('217fc056-6ff8-40d8-8517-4eefccd5204c', 'Chest Supported Machine Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/BZrdEAiR2Xs?si=WhKaSGhR0gKeeies', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('22ae4393-6ecc-427a-90af-7f5386e00cf1', 'T-Bar Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/6OtcNinT0HM?si=UPfYyypfZCaN9tTA', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0456aaef-2f7c-42f5-8b39-c2834beb005a', 'Lats Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/CQkT-W18N5g', 'الكيبل بنفس مستوى بطنك، اسحب باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Lat-focused Row / تجديف لاتس', 'Shoulder Extension / مد الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('09ae539d-a0a4-46b4-88e2-b69c9502cfa0', 'Upperback Pulldowns', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/bNmvKpJSWKM?si=hy5HgBDAHkzFHcvv', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Wide-grip Pulldown / سحب علوي بقبضة واسعة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3aee9da8-2063-46c7-b251-031f9f4c7ed2', 'Straight Arm Pulldown', 'Back & Lats / الظهر واللاتس', '{}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/hAMcfubonDc?si=ocU_a8VQ4VzZnTg3', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Straight-arm Pull / سحب بذراع مستقيمة', 'Shoulder Extension + Scapular Depression / مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('15932d3a-4879-41e5-bfd5-e67ae177adf0', 'DB Pullover', 'Back & Lats / الظهر واللاتس', '{"Chest / الصدر","Triceps / الترايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/ieFKuQAGYIA?si=uwqyrbKhBL6Id3_-', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Straight-arm Pull / سحب بذراع مستقيمة', 'Shoulder Extension + Scapular Depression / مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('12acd498-d1bd-49b7-a9e8-e78bfe3bc026', 'Band Lat Pulldown', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/5R0RYj3Y9Ro', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cd304860-50c6-493f-9152-23c7902a0215', 'Band Assisted Pull Ups', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://youtu.be/Ks8ah-8P1b0', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fc07a96c-111e-4b52-877f-3948b4ee1a24', 'Pull Ups', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متقدم', 'نادي', 'https://youtu.be/x3NPAxiMRPw?si=Mwg6U1Df5aIFpjKB', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b2f695d5-d356-432e-ba3e-17d078fc59b3', 'Negative Pull-Up', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://youtu.be/gbPURTSxQLY?si=TvQF5zDWfU_rR1Ax', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر، نزول بطيء.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d6d59492-ca51-4e59-bfe2-e0c50a828bd6', 'Neutral Grip Lat Pulldown', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/kVB6SlEyjQM', 'القبضة بنفس مستوى الكتف، اسحب باتجاه اعلى الصدر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b896dd80-3795-4863-9a35-ccf71e923539', 'Cable Y Raises', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/P7u6PEeOn6Q?feature=share', 'الكيبل يبدأ من تحت،ارفع الوزن على شكل Y.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Y Raise (Scaption) / رفع Y بمستوى لوح الكتف', 'Shoulder Elevation in Scapular Plane (Scaption) / رفع الذراع بمستوى لوح الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e98f806c-9d1e-4691-8ddf-cf28a6d09bc3', 'Band Assisted Chin Ups', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://youtu.be/i0yC-0YK6Uk?si=gNX26kIFz_THnR4p', 'مسكة ضيقة بمستوى الأكتاف، كل ما كان الحبل خفيف زادت المقاومة وزدات صعوبة التمرين لذلك ابدأ بحبل ثقيل وخفف كل ما تحسن مستواك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f67bca3a-0c30-4c88-969f-b8121a6ec8b8', 'Chin Ups', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متقدم', 'نادي', 'https://youtube.com/shorts/aV9Mz9nCsMw?si=E_ullJojGO_7srW2', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e731a7e0-894d-4c6f-92a0-cdb932e7fc30', 'Kneeling Lat Pulldown', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', NULL, 'متوسط', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/35/kneeling-lat-pulldown/', NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('151d6ef7-88f1-4def-8e43-a3bc7bc570a8', 'TRX Back Row', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس","Core / البطن والكور","Lower back / أسفل الظهر"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'TRX', 'متوسط', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/84/trx-reg-back-row/', NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a6753ed9-3740-44d5-b104-3ce908a4bdf6', 'Shrug', 'Back & Lats / الظهر واللاتس', '{"Trapezius / الترابيس"}', 'Scapular Elevation / رفع لوح الكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف فرعي: رفع الأكتاف (Shrug) ليس نمط سحب أفقي أو عمودي', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/72/shrug/', NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Shrug / هز الكتفين', 'Scapular Elevation / رفع لوح الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7dd8d298-93cb-4103-8639-9cb314bbd2ae', 'DB Shoulder Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/NKeyUrDYqPk', 'قوّس ظهرك العلوي قليلاً، الكوع قريب من الجسم، النزول الى مستوى الاكتاف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a9c2e519-ba59-411a-90c0-4f29a0c2034c', 'DB Standing Shoulder Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/wO0l5jW2NtQ?si=MVvS4F_7iFS8ji9R', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('61ab3793-98f3-4fec-ab57-dd8623f67435', 'Machine Shoulder Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/3R14MnZbcpw', 'قوّس ظهرك العلوي قليلاً، الكوع قريب من الجسم، النزول الى مستوى الاكتاف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a78f9e5b-1120-46b9-a5b6-6a4e513cdb1c', 'BB Overhead Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/_RlRDWO2jfg', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('163cf409-c875-4ab7-86da-63a910a5fa8d', 'DB Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/qqntiuPmLDM?feature=share', 'انحني للأمام قليلًا، ارفع للأعلى الى أن تصل لمستوى الأكتاف.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('aec7aea8-f7d0-4147-b253-dff58b1287af', 'Seated Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/v7fwGurZ9SU?feature=share', 'انحني للأمام قليلًا، ارفع للأعلى الى أن تصل لمستوى الأكتاف.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8d215040-b2b6-41a5-99b2-59015909b747', 'Lateral Raise Machine', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/d0pRsZ9SY5w?si=XuXb_Ti0Flow7qvW', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a71e34c9-9ea9-4806-a4a9-1c5fbb1f1acb', 'Cable Crossover Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/wKgCc5UQjoU?si=zsaz3i31PnEU9A43', 'الكيبل يبدأ من الأسفل، انحني للأمام قليلًا، ارفع للأعلى وتحكم بالنزول.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('de0a31fa-9cac-48d0-9c1f-260949ee08c3', 'DB Y Raises', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/lXp16YozXgk', 'ثبت صدرك على البنش،ارفع الوزن على شكل Y.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Y Raise (Scaption) / رفع Y بمستوى لوح الكتف', 'Shoulder Elevation in Scapular Plane (Scaption) / رفع الذراع بمستوى لوح الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('97b897a4-9935-422b-b471-f678165e09a3', 'Single Arm DB Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/Jm6GqVhWhNY', 'انحني للأمام قليلًا، ارفع للأعلى الى أن تصل لمستوى الأكتاف.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1ad057a8-8844-412f-9bae-ee78095cfe72', 'Single Arm Cable Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/J-6uEOkYAKM', 'الكيبل يبدأ من الأسفل، انحني للأمام قليلًا، ارفع للأعلى وتحكم بالنزول.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fbee7e30-2fb8-4be8-9910-187ea0eda298', 'Front Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Front Raise / رفع أمامي للكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/54/front-raise/', NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Front Raise / رفع أمامي', 'Shoulder Flexion / ثني الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9c890ffc-6d1f-4586-b07f-7878fcbe85fb', 'Diagonal Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/371/diagonal-raise/', NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Diagonal Raise / رفع قطري', 'Shoulder Flexion + Abduction (Diagonal) / ثني وتبعيد الكتف (قطري)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('69638daf-3e3e-4a29-bf4a-49f965b54128', 'High Row', 'Shoulders / الأكتاف', '{}', 'Shoulder Rear Pull / سحب خلفي للكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/336/high-row/', NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'High Row / Face Pull / سحب عالٍ باتجاه الوجه', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('54b7263b-a02d-4dc4-ade6-1f50d8239401', 'Biceps Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/09AYfVFf7pg?si=dcwLVAYqIbDLM6jd', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cf8a66c3-bb82-43d3-a5f1-b586a46acbad', 'Cable Rope Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/xNXUTJ6TBZA?si=-r-Ql97awoVZla_1', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Hammer / Neutral-grip Curl / ثني بقبضة محايدة', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('363eae41-c9f1-4d7f-994a-85cf58365fa1', 'Cable Facing Away Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/fV9BpknCjGM', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ac456eb8-c713-4aa6-a021-3cf1a59e2641', 'DB Incline Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/js_StxxyxBM', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8682009e-dfbe-44c3-aa00-6dc19ba5818d', 'Cable Facing In Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/5z4y7QRTx1w', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f0d14e59-b7f4-435a-9846-425a8547d463', 'Single Arm Cable Facing Away Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/6sO-pK7pTPs?feature=share', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('22cd5faf-1ac9-46bf-95a3-15350093d1e6', 'Single Arm Cable Facing In Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/I-197ZW9Ffo?si=M1Yq4R1PIpdZMXRx', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e3dbd9cc-c642-4a6b-9a76-79f6f7583dae', 'DB Preacher', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/DZJNTb-zzn0?si=SwbdZ0O_0eTOET-5', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Preacher Curl / ثني على مسند', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0b584626-4378-41ee-9e5e-86bedb4adda8', 'Preacher Curl Machine', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/TouYMA3-ua4?feature=share', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Preacher Curl / ثني على مسند', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('766fe4e1-5d7d-4d2a-95bb-2362e876868b', 'DB Spider Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/cTMjzB2_IH8?si=qsIKEEFVfEvPXwqf', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('88c61fdd-579b-49e2-b564-ad6c155977bc', 'Zottman Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://www.youtube.com/watch?v=ZXbOOIOPOi8', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('52de045c-dabd-4656-9442-191bbaa44d95', 'Hammer Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/10/hammer-curl/', NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Hammer / Neutral-grip Curl / ثني بقبضة محايدة', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1dde3b33-636f-4de3-b1be-6caae052fdab', 'TRX Biceps Curl', 'Biceps / البايسبس', '{"Forearms / الساعد","Core / البطن والكور"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'TRX', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/78/trx-reg-biceps-curl/', NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f2073c55-bf68-49f0-bfd8-2e8a27ace174', 'DB Triceps Extensions', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/d7SXlU5HkYM?si=WuuPa9-yeByaP5sI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Overhead Extension / مد فوق الرأس', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('39018b55-4140-43a9-a50a-58dd3981929b', 'DB Floor Triceps Extensions', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/dpFav9Ve4rY?si=ZBdKK8VF4aPMpi3v', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Lying Extension / مد مستلقٍ', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('669707ba-42df-484c-a91a-36c119c6a5bd', 'Cable Crossbody Extensions', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://www.youtube.com/watch?v=jtLTcED38Dg', 'الكيبل يبدأ بالمنتصف زي الفيديو، بحيث لما تسحب الكيبل يكون بنفس مستوى الترابس، الأكواع والأكتاف ثابتين مكانهم والحركة كلها بثني وفرد الكوع.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Cross-body Extension / مد عرضي', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('940c4719-306a-4216-b6d7-08a6e8853bcb', 'Triceps Pushdown', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/QsoN4u6j8nM?feature=share', 'انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5c83d34b-453f-4c6b-b87d-e316ee332412', 'Cable Crossover Pressdowns', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/Y3CDzx-oj3k', 'الكيبل يبدأ من الأعلى،انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('02c0b17c-8bed-47bd-a8a6-b93142ce8814', 'Band Triceps Pushdown', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/mYs1rEYtZK4?si=k8vdZxNNEB5wj2CA', 'الكيبل يبدأ من الأعلى،انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('53a745eb-2441-476e-9b5a-cccaf37c5806', 'Single Cable Triceps Pressdowns', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/8rl4ioij6lc', 'الكيبل يبدأ من الأعلى،انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8d170d72-0251-4280-b8a9-001f5b4496e9', 'Cable Overhead Extension', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://www.youtube.com/shorts/Q3bO1Fh4734', 'اترك الحبل يسحب معصمك وكوعك ثابت لما تستطيل التراي ثم ارفع الوزن لما تستقيم اليد، كوعك ثابت طول الوقت والحركة ثني ومد من مفصل الكوع، ممكن تطبق كل يد لحالها اذا كان اسهل لك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Overhead Extension / مد فوق الرأس', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3e2179d6-88d8-4b55-a3c3-d9788d908c0c', 'Triceps Dips', 'Triceps / الترايسبس', '{"Chest / الصدر","Shoulders / الأكتاف"}', 'Vertical Push / دفع عمودي', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/SpSE_A5L-YA?si=bSAzRM9SBuX-3mE0', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Dip / متوازي', 'Shoulder Extension + Elbow Extension / مد الكتف + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('caf5df70-275b-42b3-b271-9d7825d2a174', 'Triceps Kickback', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/YebyKE3Ts8o?si=H_h9z5BXutFBbFhq', NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/55/triceps-kickback/', NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Triceps Kickback / ركلة الترايسبس', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('932d879d-154a-4147-9443-44dff5589209', 'Suitcase Carry', 'Core / البطن والكور', '{"Forearms / الساعد"}', 'Loaded Carry / حمل ومشي', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/BaRMAhD7SP4?si=KkiMH8OSIEz_TB53', NULL, 'نفس التمرين ورد أيضاً تحت التصنيف «Functional Training» (صف المصدر 160) || رابط آخر في المصدر (صف 160): https://youtu.be/BaRMAhD7SP4?si=dCR2n2VSPaHhxfL3', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Suitcase Carry / حمل جانبي', 'Isometric Trunk + Grip Under Load / تثبيت الجذع والقبضة أثناء المشي', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('660c2086-60d8-4fd5-bb07-19226c61a57a', 'Cable Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/ToJeyhydUxU?si=Z5dv34foxX4VtRH6', 'الحركة عبارة عن ثني للعمود الفقري وكأنك تقرب صدرك لوركك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Crunch / كرنش', 'Trunk Flexion / ثني الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c5117bfe-c1a0-41e1-bec9-eee35af44da0', 'Leg Raises', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/UqmbxvOgnX4?si=U3pDG4Jf0x1mtC_7', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Reverse Crunch / Leg Raise / كرنش عكسي ورفع الأرجل', 'Hip Flexion + Posterior Pelvic Tilt / ثني الورك + إمالة الحوض للخلف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('15b2432e-b182-4649-90a5-1a2c0b3804b5', 'Bosu Ball Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'أخرى', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/KjvDgHPxXcg?si=zad59CHC6Y-calzi', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Crunch / كرنش', 'Trunk Flexion / ثني الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e90c1e17-364e-4527-984f-d73666781035', 'Bent Knee V-Up', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/sbyFIM30_G8?si=dED0NQSRS44dz5G9', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'V-up / في أب', 'Trunk Flexion + Hip Flexion / ثني الجذع + ثني الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b061486d-5129-4bde-9988-e80aa579ffee', 'Reverse Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/esYVzdEfs04?si=N44MZZHlVeSQc1S3', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Reverse Crunch / Leg Raise / كرنش عكسي ورفع الأرجل', 'Hip Flexion + Posterior Pelvic Tilt / ثني الورك + إمالة الحوض للخلف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7fb741ea-f335-4a99-a5a3-a87c6cca7513', 'Belly Breathing', 'Core / البطن والكور', '{}', 'Core Activation & Breathing / تفعيل الجذع والتنفس', 'إحماء/تفعيل', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/Shk8cmgv0Ew?si=mXkcj9PH6eH_tLcd', 'نفس عميق من الانف ننفخ فيه البطن ثم نطلعه من الفم ببطئ مع ضغط البطن للداخل اثناء اخراج النفس', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Diaphragmatic Breathing / تنفس حجابي', 'Diaphragmatic Breathing + Abdominal Bracing / تنفس حجابي + شد البطن', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('81dfc68d-17c6-4a20-aa99-9fe661306011', 'Reverse Tabletop Bridge', 'Core / البطن والكور', '{"Glutes / المؤخرة"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://youtu.be/d1yE9cGtPWo?si=2aoNqmUAN054rP75', 'اخذ نفس اثناء الطلوع، اثبت ثواني فوق واشد عضلات بطني، اطلع النفس اثناء النزول', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('53322d30-83cc-4ed4-86f9-fcdf9a77dcbf', 'Pelvic Tilting', 'Core / البطن والكور', '{}', 'Core Activation & Breathing / تفعيل الجذع والتنفس', 'إحماء/تفعيل', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/DqqUIfMuDX4?si=uzl0SRl_M9guUT3j', 'الحركة من الحوض، اخذ نفس وادف حوضي للاعلى قليلا، اطلع النفس اثناء نزول الحوض والصق اسفل ظهري بالارض', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Pelvic Tilt / إمالة الحوض', 'Posterior Pelvic Tilt / إمالة الحوض للخلف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('da1dd5f9-ffd4-412e-b42a-edf93bac10ef', 'Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/52/crunch/', NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Crunch / كرنش', 'Trunk Flexion / ثني الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e8f17dfe-35d6-4925-88b1-f865ca451679', 'Standing Wood Chop', 'Core / البطن والكور', '{}', 'Trunk Rotation / دوران الجذع', 'كور', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/108/standing-wood-chop/', NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Rotation / Chop / دوران وتقطيع', 'Trunk Rotation / دوران الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5b82463e-9d7e-42c9-b196-fc51c5fcef55', 'Russian Twist', 'Core / البطن والكور', '{"Lower back / أسفل الظهر"}', 'Trunk Rotation / دوران الجذع', 'كور', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/65/russian-twist/', NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Rotation / Chop / دوران وتقطيع', 'Trunk Rotation / دوران الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6405153c-4b5b-490f-b98d-e3d91b9e002f', 'Cable Twisted', 'Core / البطن والكور', '{"Lower back / أسفل الظهر"}', 'Trunk Rotation / دوران الجذع', 'كور', 'كيبل', 'مبتدئ', 'نادي', NULL, NULL, NULL, 'إضافة المدربة', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Rotation / Chop / دوران وتقطيع', 'Trunk Rotation / دوران الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1a0cf4c7-9256-40cb-9961-16a8b6224aa5', 'Calves On Leg Press', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/XdtWVYFVhGU', 'ثبت أصابعك أو مقدمة رجلك على الجهاز، لا تبالغ بالوزن، انزل بكعبك لين تمتد بطاتك بشكل كامل ثم ادفع.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3356025d-dbf2-461e-bafc-39f9e1d779b2', 'Calves Raise', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/H6WptvjXkgw', 'حط تحت اقدامك بليتس أو أي شي يرفعك عن الأرض، انزل من اصابعك اقصى نزول ثم ادفع للأعلى', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1ab0fa1d-b99f-446f-9813-bdf4ab8540c2', 'Calf Raise (Machine)', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', 'جهاز', 'مبتدئ', 'نادي', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/294/calf-raise/', NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('331b1ce1-696c-42cb-8bd3-3956089ae940', 'Calf Raises (Barbell)', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', 'بار', 'مبتدئ', 'نادي', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/51/calf-raises/', NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b09de00a-0421-4c74-8625-4f7318d19066', 'Adductor Slides', 'Adductors / الأفخاذ الداخلية', '{}', 'Hip Adduction / تقريب الورك', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/6U7dfuxaX9g?si=lkH35E7tZxGBePBj', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor strength»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Adductor Slide / انزلاق للتقريب', 'Hip Adduction / تقريب الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f0e38ad7-e241-44a1-aa69-b46fa3fca42e', 'Adductor Machine', 'Adductors / الأفخاذ الداخلية', '{}', 'Hip Adduction / تقريب الورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/SU1LQhq3o2g?si=_55FKBOlcn8Ilw4X', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Adductor Machine / جهاز التقريب', 'Hip Adduction / تقريب الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('db0befcd-334f-46a1-b1a5-78a94eca6ef2', 'Seated Abductor Machine', 'Abductors / مبعدات الفخذ', '{}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/riEMreTHNbM?si=wE3vfJBYQY7j_oJ2', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor strength»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('edb8159c-88b8-48c2-9533-3ad72c084ba8', 'Hip Abductor Plank', 'Abductors / مبعدات الفخذ', '{"Core / البطن والكور"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/2lB5RL91yWo?si=WRm9rUORpFK6dXPl', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor strength»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fa6cf97b-ebfc-4aef-bb7c-bc1db4e3b410', 'Dirty Dog', 'Abductors / مبعدات الفخذ', '{"Core / البطن والكور"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/109/dirty-dog/', NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4e24463d-2432-48b9-9394-6708643b5a15', 'Rotator Cuff', 'Rotator cuffs / الكفة المدورة', '{}', 'Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/mO8YJAxVG2M?si=KL_llR6Z47Yt89uk', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «Functional Training»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'External Rotation / دوران خارجي', 'Shoulder External Rotation / دوران خارجي للكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cda53f29-165b-4ae8-a31a-ac812b0c9e0b', 'Supine Hamstrings Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'استلقِ على ظهرك وارفع رجلاً واحدة ومدّها ببطء مع سحب أصابع القدم نحوك، دون أي حركة في الحوض أو أسفل الظهر. اثبت 15–30 ثانية، 2–4 مرات لكل رجل.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/235/supine-hamstrings-stretch/', NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Hamstring Stretch / إطالة الخلفية', 'Hip Flexion with Knee Extended / ثني الورك مع مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c1030604-e4a9-4eed-900d-707f4727dcb4', 'Stability Ball Reverse Extensions', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة"}', 'Spinal Extension / بسط الجذع', 'كور', 'كرة سويسرية', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/64/stability-ball-reverse-extensions/', NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Reverse Extension / بسط عكسي', 'Hip Extension + Spinal Extension / بسط الورك + بسط العمود الفقري', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d50205cf-1b64-42d0-ae9c-93d3808f26fb', 'Contralateral Limb Raises', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة","Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Spinal Extension / بسط الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/53/contralateral-limb-raises/', NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Prone Extension / بسط على البطن', 'Spinal Extension / بسط العمود الفقري', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('be7db12f-e430-4bb1-9dbe-1dbce1228e89', 'Inner Thigh Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/uqCfJYKojLU?si=Gev0VeOwVp5z6gB2', 'الضغط والدفع يكون من جهة الفخذ ، لا تدفع من ركبتك!', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «stretch»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Adductor Stretch / إطالة المقربات', 'Hip Abduction (Adductor Stretch) / تبعيد الورك (إطالة المقربات)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('de76891e-bacd-488c-a8e9-880f8291d454', 'Hips Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/uqCfJYKojLU?si=Gev0VeOwVp5z6gB2', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «stretch»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Hip Stretch / إطالة الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ab432184-f87e-427c-94bf-d9c4b0dd7b2c', 'Kneeling Hip-flexor Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'من وضع الركوع: الركبة الخلفية تحت الورك والقدم الأمامية أمامك والركبة فوق الكاحل. شد البطن وادفع الحوض للأمام دون تقويس أسفل الظهر، واعصر مؤخرة الجهة الخلفية لزيادة الإطالة. اثبت 30–45 ثانية، 2–5 مرات.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/142/kneeling-hip-flexor-stretch/', NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Hip Flexor Stretch / إطالة ثانيات الورك', 'Hip Extension (End Range) / بسط الورك في نهاية المدى', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5f16e02a-3ccb-446b-9b11-d7441977f347', 'Side Lying Quadriceps Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'استلقِ على جنبك وشد البطن، واسحب كعب الرجل العلوية نحو المؤخرة بيدك مع إبقاء الركبة في خط الورك. اثبت 30–45 ثانية، 2–5 مرات لكل جهة.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/149/side-lying-quadriceps-stretch/', NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Quadriceps Stretch / إطالة الأمامية', 'Knee Flexion + Hip Extension (End Range) / ثني الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('90137e77-4cd9-40e7-9de6-a9217c78817a', 'Standing Lunge Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/137/standing-lunge-stretch/', NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Hip Flexor Stretch / إطالة ثانيات الورك', 'Hip Extension (End Range) / بسط الورك في نهاية المدى', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a591ed4e-7a6f-4895-b8ad-cb0448313574', 'Lateral Bound', 'Plyometrics / التمارين الانفجارية', '{"Glutes / المؤخرة","Quadriceps / الأمامية","Abductors / مبعدات الفخذ"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://www.youtube.com/watch?v=soqQy4dzEts', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «Functional Training»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Lateral Jump / قفز جانبي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('89bb7515-6199-4173-8655-b05ad5c86826', 'Box Jumps', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Calves / البطات"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'أخرى', 'متوسط', 'نادي', NULL, NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «CrossFit»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Vertical Jump / قفز عمودي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c5057506-8e96-412e-b374-49d62cd77c12', 'Squat Jump', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متوسط', 'بدون معدات', NULL, 'قف بعرض الحوض، ادفع الورك للخلف وانزل، ثم اقفز بقوة بمدّ الكاحل والركبة والورك معاً. انزل بهدوء على منتصف القدم مع دفع الورك للخلف ودون قفل الركب. ابدأ بقفزات صغيرة حتى تتقن الهبوط.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/222/squat-jump/', NULL, 'review', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Vertical Jump / قفز عمودي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('de78763a-fa62-438d-a8d4-dd2962239a80', 'Tuck Jump', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متقدم', 'بدون معدات', NULL, 'استخدم الذراعين للزخم: أرجعهما للخلف عند النزول وأرجحهما للأمام والأعلى عند القفز، واسحب الركبتين نحو الصدر في الهواء.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/180/tuck-jump/', NULL, 'review', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Vertical Jump / قفز عمودي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d62e5387-3dee-4158-b7d4-d2287e55c130', 'Cycled Split-Squat Jump', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Hamstrings / الخلفية"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متقدم', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/234/cycled-split-squat-jump/', NULL, 'review', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Split Jump / قفز سبليت', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8e458d98-6170-467c-b940-98ff2706add3', 'Lateral Cone Jumps', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Calves / البطات"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'أخرى', 'متوسط', 'نادي', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/120/lateral-cone-jumps/', NULL, 'review', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Lateral Jump / قفز جانبي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1efc6199-b6eb-4c56-8c25-58a69f28f7e0', 'Forward Linear Jumps', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Hamstrings / الخلفية"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متوسط', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/177/forward-linear-jumps/', NULL, 'review', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Horizontal Jump / قفز أمامي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('608d25af-3156-4ceb-be7c-a490f643ecc0', 'Jogging', 'CrossFit / كروس فت', '{"Quadriceps / الأمامية","Hamstrings / الخلفية","Calves / البطات"}', 'Locomotion / مشي وجري ودفع', 'كارديو', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Running / جري', 'Gait: Alternating Hip/Knee Extension / نمط المشي والجري', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7006b777-deb6-492f-bc05-db5e4f27311c', 'Wall Ball', 'CrossFit / كروس فت', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Shoulders / الأكتاف"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'أخرى', 'متوسط', 'نادي', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Squat to Throw / سكوات مع رمي', 'Knee/Hip Extension + Shoulder Flexion / مد الركبة والورك + ثني الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3e4b26c4-d6da-438c-860d-7cdd2453d646', 'Snatch', 'CrossFit / كروس فت', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Shoulders / الأكتاف"}', 'Olympic Lift (Triple Extension) / رفعات أولمبية (بسط ثلاثي)', 'قدرة', 'بار', 'متقدم', 'نادي', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Snatch / سناتش', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b6388b55-bb5d-4996-9cee-404fad4e6951', 'Clean', 'CrossFit / كروس فت', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Quadriceps / الأمامية"}', 'Olympic Lift (Triple Extension) / رفعات أولمبية (بسط ثلاثي)', 'قدرة', 'بار', 'متقدم', 'نادي', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Clean / كلين', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('939111c0-ce7e-4bc8-81c0-6485c9476da1', 'Turkish Get-Up', 'Functional / التمارين الوظيفية', '{"Shoulders / الأكتاف","Core / البطن والكور","Glutes / المؤخرة"}', 'Full-body Integrated / حركة متكاملة للجسم', 'قوة', 'كيتلبل', 'متقدم', 'منزل', 'https://www.youtube.com/watch?v=0bWRPC49-KI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Turkish Get-Up / النهوض التركي', 'Multi-joint Integrated / حركة متعددة المفاصل', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2c1749a1-2c56-44fe-96d8-e60faeaeecce', 'Sled Pull/Push', 'Functional / التمارين الوظيفية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Calves / البطات"}', 'Locomotion / مشي وجري ودفع', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://www.youtube.com/watch?v=3KWK7SIdPz4', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Sled Push / Pull / دفع وسحب الزلاجة', 'Hip/Knee Extension in Gait / بسط الورك والركبة بنمط المشي', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('45ac1578-b664-4777-935e-5206895f73f7', 'Farmer’s Walk', 'Functional / التمارين الوظيفية', '{"Forearms / الساعد","Core / البطن والكور","Back & Lats / الظهر واللاتس"}', 'Loaded Carry / حمل ومشي', 'قوة', NULL, 'مبتدئ', NULL, 'https://www.youtube.com/watch?v=hx24PM6gXs8', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Farmer''s Walk / مشي المزارع', 'Isometric Trunk + Grip Under Load / تثبيت الجذع والقبضة أثناء المشي', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8a51516b-933e-4cba-995b-9f813fa35502', '90s Transition', 'Functional / التمارين الوظيفية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://www.youtube.com/watch?v=ogU-azeGe_k', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Hip Rotation Mobility (90/90) / مرونة دوران الورك', 'Hip Internal/External Rotation / دوران الورك الداخلي والخارجي', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('089bf391-39e2-423b-b63b-28f476321263', 'Kettlebell Swing', 'Functional / التمارين الوظيفية', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Core / البطن والكور"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قدرة', 'كيتلبل', 'متوسط', 'منزل', 'https://www.youtube.com/watch?v=d94xX-AQZ0A', NULL, 'نفس التمرين ورد أيضاً تحت التصنيف «CrossFit» (صف المصدر 168)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Ballistic Hinge (Swing) / مفصلة انفجارية (سوينق)', 'Hip Extension (Ballistic) / بسط الورك الانفجاري', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('409b68d6-d420-423e-b052-08541b6eb2b5', 'left over db', 'Functional / التمارين الوظيفية', '{}', NULL, NULL, 'دمبل', NULL, 'منزل', 'https://youtu.be/pLnRt-caepc?si=DAS9jeYr8vS6RRtz', 'طبق الحركة بأقصى عدد ممكن من التكرارات وأحسبها كجولة، ثم ابدأ بالجولة الثانية بنفس الطريقة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('98097db7-c507-41d8-b3af-02fc6ce229c2', 'Serratus Punches Supine', 'Functional / التمارين الوظيفية', '{"Shoulders / الأكتاف","Chest / الصدر"}', 'Horizontal Push / دفع أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/cxaAqmdlrgk?si=2YRAIgFFXPAvDadG', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Scapular Protraction / دفع لوح الكتف', 'Scapular Protraction / دفع لوح الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('81313879-f7aa-4d21-a56b-5c4fb316bce3', 'Forward Lunges', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/_DLAdo2Pvjs', 'تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness | ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, 'تقوية الورك ضمن نمط حركي وظيفي', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Distefano et al. 2009 — JOSPT (EMG) | Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin)', 'https://pubmed.ncbi.nlm.nih.gov/19574661/ | https://pubmed.ncbi.nlm.nih.gov/33344003/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('10803c1f-112e-475e-a475-8bca2aa2c3eb', 'Seated Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/0G3W83dFUeY', 'اسحب باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness | تحدب الظهر / Postural Thoracic Kyphosis', 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', 'تقوية سحب وانكماش لوح الكتف', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moseley et al. 1992 — AJSM (EMG, scapular muscles) | Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://pubmed.ncbi.nlm.nih.gov/1558238/ | https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('00df8c27-55da-4db8-a64b-56133f96562e', 'Single Leg Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'وزن الجسم', 'متقدم', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/136/single-leg-squat/', 'ضعف الألوية الكبرى / Gluteus Maximus Weakness | ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Single-leg Squat / سكوات رجل واحدة', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, 'تقوية باسطات ومبعدات الورك وتحكم أحادي الطرف', 'متقدمة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ يتطلب تحكماً جيداً بالركبة والحوض', 'Distefano et al. 2009 — JOSPT (EMG) | Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin)', 'https://pubmed.ncbi.nlm.nih.gov/19574661/ | https://pubmed.ncbi.nlm.nih.gov/33344003/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('816fe4ff-8864-499f-bcb1-9cafcbc272a9', 'Hip Abduction', 'Abductors / مبعدات الفخذ', '{"Glutes / المؤخرة"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/_ARUxqrII3Y?si=Jcz5uh2Uu-IdVCS1', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL, 'تقوية مبعدات الورك بمقاومة خارجية', 'مبكرة–متوسطة', 'منخفض–متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ الدليل يخص إبعاد الورك بمقاومة خارجية؛ يُتحقق من نوع الأداء', 'Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin)', 'https://pubmed.ncbi.nlm.nih.gov/33344003/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8d29a0d4-601c-4dd4-b381-3cd58d4be6f3', 'Side Step Up', 'Glutes / المؤخرة', '{"Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/xOwIRnI4VxA?si=SJOgODRmNGdfHPb4', 'يد فيها الوزن واليد الثانية سندها على الجدار', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية المتوسطة / Gluteus Medius Weakness | ضعف الألوية الصغرى / Gluteus Minimus Weakness', 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, 'تقوية مبعدات الورك والتحكم بالحوض على رجل واحدة', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin) | Ganderton et al. — GMin/GMed EMG (RMIT University)', 'https://pubmed.ncbi.nlm.nih.gov/33344003/ | https://research-repository.rmit.edu.au/articles/journal_contribution/Gluteus_Minimus_and_Gluteus_Medius_Muscle_Activity_during_Common_Rehabilitation_Exercises_in_Healthy_Postmenopausal_Women/27572301', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('91ac4986-7a14-424e-ae03-656885736c75', 'Glute Bridge', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', NULL, 'مبتدئ', NULL, 'https://www.youtube.com/watch?v=dtlGynVdHYM', 'ممكن تسويه بالسميث مشين او البار الحر ، اختر بوكس او بنش يكون بمستوى اكتافك الخلفية وانت جالس، لما ترفع البار فوق المفروض ركبك تكون بنفس مستوى القدم.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness | آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, 'تقوية بسط الورك وتحمّل الجذع', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Boren et al. 2011 — IJSPT (EMG) | JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/22034614/ | https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('37711381-db7c-434d-9b14-3189c26154ea', 'DB Floor Glute Bridge', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/iOrJXNUH3to?si=JySX6JMhoP2vWEVa', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness', 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, 'تقوية بسط الورك بتحميل خارجي متدرج', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Boren et al. 2011 — IJSPT (EMG)', 'https://pubmed.ncbi.nlm.nih.gov/22034614/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cc095517-a9c1-4d67-b5db-a31495ecac09', 'Single DB RDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/U3prDlAbJDw?si=MRSBcSIcf9M-WQBH', 'وقف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، انزل وادفع مؤخرتك لآخر شي تقدر عليه للخلف وكأنك بتلمس جدار خلفك مع انثناء بسيط بالركب', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness', 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, 'تقوية باسطات الورك وتحكم أحادي الطرف', 'متقدمة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ مع الحفاظ على وضع محايد للظهر', 'Distefano et al. 2009 — JOSPT (EMG)', 'https://pubmed.ncbi.nlm.nih.gov/19574661/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('78315b43-ff71-46a9-a3d8-83d5465d6082', 'Upper Back Horizontal Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/TSWohpfMlso', 'ثبت نفسك بالكرسي، فتحة واسعة، الكيبل بمستوى أعلى صدرك، واسحب لما تنقبض الترابز.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness', 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Wide-grip Row / تجديف بقبضة واسعة', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', 'تقوية انكماش لوح الكتف والظهر العلوي', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moseley et al. 1992 — AJSM (EMG, scapular muscles)', 'https://pubmed.ncbi.nlm.nih.gov/1558238/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('eaf20c90-97ea-4b0a-b8d7-b28025fef140', 'Band Seated Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/Jy-WCFAofBY?si=9gqVby588rk1zFi9', 'فتحة واسعة، واسحب لما تنقبض عضلات الظهر.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness | تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture', 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', 'تقوية سحب لوح الكتف بمقاومة منخفضة', 'مبكرة–متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moseley et al. 1992 — AJSM (EMG, scapular muscles) | Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://pubmed.ncbi.nlm.nih.gov/1558238/ | https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c92ccd93-a8da-4a9e-b7e5-ca37d926f6e9', 'Chest Supported Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/DgHtyrQEMJ4?si=oTfTKVgD9j1H12wA', 'ثبت صدرك على الكرسي، فتحة واسعة، واسحب لما تنقبض عضلات الظهر.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness', 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', 'تقوية انكماش لوح الكتف مع دعم الجذع', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moseley et al. 1992 — AJSM (EMG, scapular muscles)', 'https://pubmed.ncbi.nlm.nih.gov/1558238/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('83a50612-e015-43dd-862c-b6211ce5b0f0', 'Plank', 'Core / البطن والكور', '{"Shoulders / الأكتاف","Glutes / المؤخرة"}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/pvIjsG5Svck?si=cTP8ZyfMAJPfaEhw', 'لما ترتفع الاكتاف تكون فوق الكوع والرجل ممتدة بالكامل.', NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL, 'تحمّل عضلات الجذع', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('78fc560d-bcc5-42b0-90cd-2b27dc224349', 'deadbug', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/g_BYB0R-4Ws?si=D4nwJri73eBqJRqL', NULL, 'اسم مشابه موجود في المكتبة (deadbug / dead bug) — تُراجَع قبل الحذف أو الدمج', 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'rejected', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL, 'التحكم الحركي وتحمّل الجذع', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('039137cb-4a18-4069-8355-20123e8bc6ac', 'Band Dead Bug', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'مطاط', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/iW_CtYtzbeU?si=Epequw3rqA3_TwTr', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL, 'التحكم الحركي وتحمّل الجذع بمقاومة', 'مبكرة–متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a1bdfd0c-3801-484e-bf7e-fbd5e446181c', 'Side Plank', 'Core / البطن والكور', '{"Abductors / مبعدات الفخذ","Shoulders / الأكتاف"}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'لما ترتفع الاكتاف تكون فوق الكوع والرجل ممتدة بالكامل.', NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain | ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Anti-Lateral Flexion / مقاومة الميلان الجانبي', 'Isometric Anti-Lateral Flexion / تثبيت الجذع ضد الميلان', NULL, 'تحمّل الجذع الجانبي وتنشيط مبعدات الورك', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.) | Boren et al. 2011 — IJSPT (EMG)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/ | https://pubmed.ncbi.nlm.nih.gov/22034614/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3dd2b0c1-9fce-4c3d-9989-9c9f7be81351', 'McGill Big 3', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/jZylx81_kfg?si=_jP064GZIzvEvzyN', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Mixed (McGill Big 3) / مختلط', 'Isometric Trunk Stabilization / تثبيت الجذع', NULL, 'التحكم الحركي وتحمّل الجذع', 'مبكرة–متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8a1365d9-52f8-4e4f-9c87-10de343653cd', 'Dead Bug', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/bxn9FBrt4-A', 'نحرك الرجلين ببطئ قليلا و بتحكم باستخدام عضلات البطن', 'اسم مشابه موجود في المكتبة (deadbug / dead bug) — تُراجَع قبل الحذف أو الدمج', 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL, 'التحكم الحركي وتحمّل الجذع', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1c79d482-7ea0-470b-9019-b31787f0d120', 'Bird Dog', 'Core / البطن والكور', '{"Lower back / أسفل الظهر","Glutes / المؤخرة"}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/L91QMACdA6Q?si=KBnuQDcm9WcUXxxI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Anti-Rotation / مقاومة الدوران', 'Isometric Anti-Rotation / تثبيت الجذع ضد الدوران', NULL, 'التحكم الحركي وتحمّل الجذع', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1b75ede6-261b-4e83-b896-7714ed28d3dd', 'High-Load Heel Raise (Towel Under Toes)', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', NULL, 'مبتدئ', NULL, NULL, 'رفع الكعب على رجل واحدة مع منشفة ملفوفة تحت أصابع القدم؛ صعود بطيء ثم ثبات قصير ثم نزول بطيء.', 'أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Rathleff et al. 2015 — Scand J Med Sci Sports (RCT)', 'https://doi.org/10.1111/sms.12313', 'اللفافة الأخمصية / Plantar Fasciopathy', 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL, 'تحميل تدريجي للقدم والكاحل', 'متقدمة', 'مرتفع', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ يُبدأ بعد تحسّن الأعراض وبتدرّج', 'Rathleff et al. 2015 — Scand J Med Sci Sports (RCT) | JOSPT CPG 2023 — Heel Pain/Plantar Fasciitis (Koc et al.)', 'https://doi.org/10.1111/sms.12313 | https://pubmed.ncbi.nlm.nih.gov/38037331/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('403e28f3-8109-45c7-9e8a-3bd1e51ed15a', 'Side Lunge', 'Adductors / الأفخاذ الداخلية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/50/side-lunge/', 'ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Lateral Lunge / لانج جانبي', 'Knee/Hip Extension + Hip Adduction / مد الركبة والورك + تقريب الورك', NULL, 'تقوية مبعدات الورك والتحكم بالحوض', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin)', 'https://pubmed.ncbi.nlm.nih.gov/33344003/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c9e2cd18-e55f-4493-ab6c-130b5fb08770', 'Hip Hitch (Pelvic Drop)', 'Abductors / مبعدات الفخذ', '{}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Ganderton et al. — GMin/GMed EMG (RMIT University)', 'https://research-repository.rmit.edu.au/articles/journal_contribution/Gluteus_Minimus_and_Gluteus_Medius_Muscle_Activity_during_Common_Rehabilitation_Exercises_in_Healthy_Postmenopausal_Women/27572301', 'ضعف الألوية المتوسطة / Gluteus Medius Weakness | ضعف الألوية الصغرى / Gluteus Minimus Weakness', 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Pelvic Drop (Stance Leg) / تثبيت الحوض برجل الارتكاز', 'Hip Abduction of Stance Leg / تبعيد ورك رجل الارتكاز', NULL, 'تنشيط وتقوية مبعدات الورك (الألوية المتوسطة والصغرى) والتحكم بالحوض', 'مبكرة–متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Ganderton et al. — GMin/GMed EMG (RMIT University) | Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin)', 'https://research-repository.rmit.edu.au/articles/journal_contribution/Gluteus_Minimus_and_Gluteus_Medius_Muscle_Activity_during_Common_Rehabilitation_Exercises_in_Healthy_Postmenopausal_Women/27572301 | https://pubmed.ncbi.nlm.nih.gov/33344003/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('536f52a4-cdd2-43f1-a475-e7863dfd8246', 'Shoulder I-Y-T-W Series', 'Rotator cuffs / الكفة المدورة', '{"Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/237/shoulder-stability-mobility-series-i-y-t-w-formations/', 'تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture | ضعف العضلة المعينية / Rhomboid Weakness', 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'I-Y-T-W / تمارين I-Y-T-W', 'Scapular Retraction/Depression + Arm Elevation / سحب وخفض لوح الكتف مع رفع الذراع', NULL, 'تقوية وتحكم عضلات لوح الكتف (الانكماش والتدوير)', 'مبكرة–متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis) | Sheikhhoseini et al. 2018 — JMPT (Systematic review, FHP) | Castelein et al. 2016 — Man Ther (EMG, rhomboid)', 'https://doi.org/10.1186/s12891-024-07224-4 | https://pubmed.ncbi.nlm.nih.gov/30107937/ | https://pubmed.ncbi.nlm.nih.gov/26409441/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('057b2911-d5fc-4871-909f-32d2bd3d7117', 'Supine Snow Angel (Wipers)', 'Rotator cuffs / الكفة المدورة', '{"Shoulders / الأكتاف","Core / البطن والكور"}', 'Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/124/supine-snow-angel-wipers-exercise/', 'تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture', 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Snow Angel / الملاك', 'Shoulder Abduction/Adduction + Scapular Control / تبعيد وتقريب الكتف مع تحكم لوح الكتف', NULL, 'حركة الكتف والتحكم بلوح الكتف', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('58fb933d-aef8-4146-93e8-4f407b197bdf', 'Back Extension', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة","Hamstrings / الخلفية"}', 'Spinal Extension / بسط الجذع', 'كور', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/bs7S3RFyIYs?si=tDLl3OYuDBIwK4Fj', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «Functional Training»)', 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain | تحدب الظهر / Postural Thoracic Kyphosis', 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Back Extension / بسط الظهر', 'Hip Extension + Spinal Extension / بسط الورك + بسط العمود الفقري', NULL, 'تقوية باسطات الظهر', 'متقدمة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ يُراجَع إذا زاد الألم مع الامتداد', 'JOSPT CPG 2021 — Low Back Pain (George et al.) | Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/ | https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6b0823dc-8c2d-4983-842a-d8f96c437843', 'Supermans', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة","Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Spinal Extension / بسط الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/9/supermans/', 'تحدب الظهر / Postural Thoracic Kyphosis | آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Prone Extension / بسط على البطن', 'Spinal Extension / بسط العمود الفقري', NULL, 'تقوية باسطات الظهر والتحكم الوضعي', 'متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis) | JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://doi.org/10.1186/s12891-024-07224-4 | https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e469aaea-efa2-47e6-9f15-0dc60aba46a9', 'Standing Dorsi-Flexion (Calf Stretch)', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/152/standing-dorsi-flexion-calf-stretch/', 'اللفافة الأخمصية / Plantar Fasciopathy', 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Calf Stretch / إطالة البطات', 'Ankle Dorsiflexion / ثني ظهري للكاحل', NULL, 'إطالة عضلات الساق', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2023 — Heel Pain/Plantar Fasciitis (Koc et al.)', 'https://pubmed.ncbi.nlm.nih.gov/38037331/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('51071576-3f0b-4fed-854f-c1f439f28f2b', 'Cat-Cow', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/15/cat-cow/', 'تحدب الظهر / Postural Thoracic Kyphosis | آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Spinal Mobility / مرونة العمود الفقري', 'Spinal Flexion/Extension / ثني وبسط العمود الفقري', NULL, 'حركة العمود الفقري ضمن مدى حركة مريح', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis) | JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://doi.org/10.1186/s12891-024-07224-4 | https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ce091d09-cad8-413f-86dd-6b09f9715344', 'Plantar Fascia-Specific Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'تُسحب أصابع القدم للخلف باليد حتى يُشعر بشد في باطن القدم، مع تحسّس اللفافة للتأكد من الشد.', 'أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Rathleff et al. 2015 — Scand J Med Sci Sports (RCT)', 'https://doi.org/10.1111/sms.12313', 'اللفافة الأخمصية / Plantar Fasciopathy', 'review', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Plantar Fascia Stretch / إطالة اللفافة الأخمصية', 'Toe Extension + Ankle Dorsiflexion / مد أصابع القدم + ثني ظهري', NULL, 'إطالة اللفافة الأخمصية', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2023 — Heel Pain/Plantar Fasciitis (Koc et al.) | Rathleff et al. 2015 — Scand J Med Sci Sports (RCT)', 'https://pubmed.ncbi.nlm.nih.gov/38037331/ | https://doi.org/10.1111/sms.12313', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e6815391-139c-424a-acc6-a06c90085452', 'Crab Reach (Thoracic Bridge)', 'Functional / التمارين الوظيفية', '{"Glutes / المؤخرة","Shoulders / الأكتاف"}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://www.youtube.com/watch?v=fgsUe3Lc3hI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'تحدب الظهر / Postural Thoracic Kyphosis', 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Thoracic Bridge / جسر صدري', 'Hip Extension + Thoracic Rotation / بسط الورك + دوران الصدر', NULL, 'حركة الامتداد والدوران الصدري', 'متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ يتطلب تحمّلاً جيداً للرسغ والكتف', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7ff26419-8648-40b7-9d70-fa13eeabbfa0', 'Prone Swimmer', 'Functional / التمارين الوظيفية', '{"Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Shoulder Rear Pull / سحب خلفي للكتف', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://www.youtube.com/watch?v=M8a1cgnhyqk', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture', 'approved', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Prone Swimmer / سبّاح على البطن', 'Shoulder Extension/Abduction + Rotation / مد وتبعيد الكتف مع الدوران', NULL, 'تحمّل عضلات لوح الكتف والامتداد الصدري', 'متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7bbfa95d-b0e6-4cdd-b451-194923480004', 'Isometric Wrist Extension', 'Forearms / الساعد', '{}', 'Wrist Extension / مد الرسغ', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'مرفق التنس / Lateral Elbow Tendinopathy', 'review', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Isometric / ثابت', 'Wrist Extension / مد الرسغ', NULL, 'تحميل تدريجي لباسطات الرسغ (انقباض ثابت)', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ ضمن ألم مقبول لا يتزايد بعد التمرين', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5397e4ec-4bfb-4279-9837-4619bdb7d6c2', 'Eccentric Wrist Extension', 'Forearms / الساعد', '{}', 'Wrist Extension / مد الرسغ', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'مرفق التنس / Lateral Elbow Tendinopathy', 'review', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Eccentric / لامركزي', 'Wrist Extension / مد الرسغ', NULL, 'تحميل تدريجي لباسطات الرسغ (لامركزي)', 'متوسطة', 'منخفض–متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ ضمن ألم مقبول لا يتزايد بعد التمرين', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('54265fbf-28e5-4ec3-9f94-670c81e94bbf', 'Chin Tuck (Deep Neck Flexor)', 'Neck / الرقبة', '{}', 'Neck Flexion (Deep Flexors) / ثني الرقبة العميق', 'إحماء/تفعيل', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Sheikhhoseini et al. 2018 — JMPT (Systematic review, FHP)', 'https://pubmed.ncbi.nlm.nih.gov/30107937/', 'وضعية الرأس للأمام / Forward Head Posture', 'review', '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', 'Chin Tuck / سحب الذقن', 'Upper Cervical Flexion + Retraction / ثني علوي للرقبة مع سحبها للخلف', NULL, 'تحكم عضلات الرقبة العميقة ووضعية الرأس', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ يُوقف مع دوخة أو ألم/تنميل يمتد للذراع', 'Sheikhhoseini et al. 2018 — JMPT (Systematic review, FHP) | Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://pubmed.ncbi.nlm.nih.gov/30107937/ | https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;



INSERT INTO public.exercise_alternatives VALUES ('3fc1bf4b-5ca5-43a8-811b-b6a27ce0fd77', 'f2d4440d-c2f2-4302-8d13-695fae0528df', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3fc1bf4b-5ca5-43a8-811b-b6a27ce0fd77', '4080f40a-94c5-488c-8696-3e0e361867a9', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3fc1bf4b-5ca5-43a8-811b-b6a27ce0fd77', '9a3de3af-203f-4472-9e10-6261a73e5277', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3fc1bf4b-5ca5-43a8-811b-b6a27ce0fd77', '01b9d2b3-3fd6-49e0-a5b2-89446b3fc032', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3fc1bf4b-5ca5-43a8-811b-b6a27ce0fd77', '84152864-255c-4543-a886-70cd2c3cf0b3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f2d4440d-c2f2-4302-8d13-695fae0528df', '3fc1bf4b-5ca5-43a8-811b-b6a27ce0fd77', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f2d4440d-c2f2-4302-8d13-695fae0528df', '4080f40a-94c5-488c-8696-3e0e361867a9', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f2d4440d-c2f2-4302-8d13-695fae0528df', '9a3de3af-203f-4472-9e10-6261a73e5277', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f2d4440d-c2f2-4302-8d13-695fae0528df', '01b9d2b3-3fd6-49e0-a5b2-89446b3fc032', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f2d4440d-c2f2-4302-8d13-695fae0528df', '84152864-255c-4543-a886-70cd2c3cf0b3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a895d53b-74ea-4e5a-94a1-c8eba4e94208', '236c3e48-e38b-4a91-a74d-187003e368b0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a895d53b-74ea-4e5a-94a1-c8eba4e94208', '975701ce-0d5c-4777-9290-f3b2f0bc2995', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a895d53b-74ea-4e5a-94a1-c8eba4e94208', '3fc1bf4b-5ca5-43a8-811b-b6a27ce0fd77', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a895d53b-74ea-4e5a-94a1-c8eba4e94208', 'f2d4440d-c2f2-4302-8d13-695fae0528df', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a895d53b-74ea-4e5a-94a1-c8eba4e94208', '84c514a0-38ec-4a08-83ac-cf56384c3c5d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84c514a0-38ec-4a08-83ac-cf56384c3c5d', '823018b3-f692-419e-a731-074361f36135', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84c514a0-38ec-4a08-83ac-cf56384c3c5d', '3fc1bf4b-5ca5-43a8-811b-b6a27ce0fd77', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84c514a0-38ec-4a08-83ac-cf56384c3c5d', 'f2d4440d-c2f2-4302-8d13-695fae0528df', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84c514a0-38ec-4a08-83ac-cf56384c3c5d', 'a895d53b-74ea-4e5a-94a1-c8eba4e94208', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84c514a0-38ec-4a08-83ac-cf56384c3c5d', '4080f40a-94c5-488c-8696-3e0e361867a9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('823018b3-f692-419e-a731-074361f36135', '84c514a0-38ec-4a08-83ac-cf56384c3c5d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('823018b3-f692-419e-a731-074361f36135', '3fc1bf4b-5ca5-43a8-811b-b6a27ce0fd77', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('823018b3-f692-419e-a731-074361f36135', 'f2d4440d-c2f2-4302-8d13-695fae0528df', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('823018b3-f692-419e-a731-074361f36135', 'a895d53b-74ea-4e5a-94a1-c8eba4e94208', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('823018b3-f692-419e-a731-074361f36135', '4080f40a-94c5-488c-8696-3e0e361867a9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4080f40a-94c5-488c-8696-3e0e361867a9', '3fc1bf4b-5ca5-43a8-811b-b6a27ce0fd77', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4080f40a-94c5-488c-8696-3e0e361867a9', 'f2d4440d-c2f2-4302-8d13-695fae0528df', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4080f40a-94c5-488c-8696-3e0e361867a9', '9a3de3af-203f-4472-9e10-6261a73e5277', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4080f40a-94c5-488c-8696-3e0e361867a9', '01b9d2b3-3fd6-49e0-a5b2-89446b3fc032', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4080f40a-94c5-488c-8696-3e0e361867a9', '84152864-255c-4543-a886-70cd2c3cf0b3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9a3de3af-203f-4472-9e10-6261a73e5277', '3fc1bf4b-5ca5-43a8-811b-b6a27ce0fd77', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9a3de3af-203f-4472-9e10-6261a73e5277', 'f2d4440d-c2f2-4302-8d13-695fae0528df', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9a3de3af-203f-4472-9e10-6261a73e5277', '4080f40a-94c5-488c-8696-3e0e361867a9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9a3de3af-203f-4472-9e10-6261a73e5277', '01b9d2b3-3fd6-49e0-a5b2-89446b3fc032', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9a3de3af-203f-4472-9e10-6261a73e5277', '84152864-255c-4543-a886-70cd2c3cf0b3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('236c3e48-e38b-4a91-a74d-187003e368b0', 'a895d53b-74ea-4e5a-94a1-c8eba4e94208', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('236c3e48-e38b-4a91-a74d-187003e368b0', '975701ce-0d5c-4777-9290-f3b2f0bc2995', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('236c3e48-e38b-4a91-a74d-187003e368b0', '3fc1bf4b-5ca5-43a8-811b-b6a27ce0fd77', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('236c3e48-e38b-4a91-a74d-187003e368b0', 'f2d4440d-c2f2-4302-8d13-695fae0528df', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('236c3e48-e38b-4a91-a74d-187003e368b0', '84c514a0-38ec-4a08-83ac-cf56384c3c5d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('01b9d2b3-3fd6-49e0-a5b2-89446b3fc032', '3fc1bf4b-5ca5-43a8-811b-b6a27ce0fd77', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('01b9d2b3-3fd6-49e0-a5b2-89446b3fc032', 'f2d4440d-c2f2-4302-8d13-695fae0528df', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('01b9d2b3-3fd6-49e0-a5b2-89446b3fc032', '4080f40a-94c5-488c-8696-3e0e361867a9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('01b9d2b3-3fd6-49e0-a5b2-89446b3fc032', '9a3de3af-203f-4472-9e10-6261a73e5277', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('01b9d2b3-3fd6-49e0-a5b2-89446b3fc032', '84152864-255c-4543-a886-70cd2c3cf0b3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('975701ce-0d5c-4777-9290-f3b2f0bc2995', 'a895d53b-74ea-4e5a-94a1-c8eba4e94208', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('975701ce-0d5c-4777-9290-f3b2f0bc2995', '236c3e48-e38b-4a91-a74d-187003e368b0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('975701ce-0d5c-4777-9290-f3b2f0bc2995', '3fc1bf4b-5ca5-43a8-811b-b6a27ce0fd77', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('975701ce-0d5c-4777-9290-f3b2f0bc2995', 'f2d4440d-c2f2-4302-8d13-695fae0528df', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('975701ce-0d5c-4777-9290-f3b2f0bc2995', '84c514a0-38ec-4a08-83ac-cf56384c3c5d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1b87e59d-1b1d-4db1-8cf0-6409e34d6f39', '235f693c-13db-4fb6-8ec1-5bed0d9f5aeb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1b87e59d-1b1d-4db1-8cf0-6409e34d6f39', '421ecaf6-0ef0-48bc-ae1f-69476c2510b5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1b87e59d-1b1d-4db1-8cf0-6409e34d6f39', '81313879-f7aa-4d21-a56b-5c4fb316bce3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1b87e59d-1b1d-4db1-8cf0-6409e34d6f39', 'f0e523e7-ecb0-409f-b0d1-364de23423b5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1b87e59d-1b1d-4db1-8cf0-6409e34d6f39', 'edfa3417-22bb-4716-a9f3-c0073d9465e3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('235f693c-13db-4fb6-8ec1-5bed0d9f5aeb', '421ecaf6-0ef0-48bc-ae1f-69476c2510b5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('235f693c-13db-4fb6-8ec1-5bed0d9f5aeb', '81313879-f7aa-4d21-a56b-5c4fb316bce3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('235f693c-13db-4fb6-8ec1-5bed0d9f5aeb', 'edfa3417-22bb-4716-a9f3-c0073d9465e3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('235f693c-13db-4fb6-8ec1-5bed0d9f5aeb', '3f162607-b8be-428c-8123-69bdc28a0bdd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('235f693c-13db-4fb6-8ec1-5bed0d9f5aeb', '1b87e59d-1b1d-4db1-8cf0-6409e34d6f39', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('421ecaf6-0ef0-48bc-ae1f-69476c2510b5', '235f693c-13db-4fb6-8ec1-5bed0d9f5aeb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('421ecaf6-0ef0-48bc-ae1f-69476c2510b5', '81313879-f7aa-4d21-a56b-5c4fb316bce3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('421ecaf6-0ef0-48bc-ae1f-69476c2510b5', 'edfa3417-22bb-4716-a9f3-c0073d9465e3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('421ecaf6-0ef0-48bc-ae1f-69476c2510b5', '3f162607-b8be-428c-8123-69bdc28a0bdd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('421ecaf6-0ef0-48bc-ae1f-69476c2510b5', '1b87e59d-1b1d-4db1-8cf0-6409e34d6f39', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('81313879-f7aa-4d21-a56b-5c4fb316bce3', '235f693c-13db-4fb6-8ec1-5bed0d9f5aeb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('81313879-f7aa-4d21-a56b-5c4fb316bce3', '421ecaf6-0ef0-48bc-ae1f-69476c2510b5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('81313879-f7aa-4d21-a56b-5c4fb316bce3', 'edfa3417-22bb-4716-a9f3-c0073d9465e3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('81313879-f7aa-4d21-a56b-5c4fb316bce3', '3f162607-b8be-428c-8123-69bdc28a0bdd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('81313879-f7aa-4d21-a56b-5c4fb316bce3', '1b87e59d-1b1d-4db1-8cf0-6409e34d6f39', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0e523e7-ecb0-409f-b0d1-364de23423b5', '1b87e59d-1b1d-4db1-8cf0-6409e34d6f39', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0e523e7-ecb0-409f-b0d1-364de23423b5', '235f693c-13db-4fb6-8ec1-5bed0d9f5aeb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0e523e7-ecb0-409f-b0d1-364de23423b5', '421ecaf6-0ef0-48bc-ae1f-69476c2510b5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0e523e7-ecb0-409f-b0d1-364de23423b5', '81313879-f7aa-4d21-a56b-5c4fb316bce3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0e523e7-ecb0-409f-b0d1-364de23423b5', 'edfa3417-22bb-4716-a9f3-c0073d9465e3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('edfa3417-22bb-4716-a9f3-c0073d9465e3', '235f693c-13db-4fb6-8ec1-5bed0d9f5aeb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('edfa3417-22bb-4716-a9f3-c0073d9465e3', '421ecaf6-0ef0-48bc-ae1f-69476c2510b5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('edfa3417-22bb-4716-a9f3-c0073d9465e3', '81313879-f7aa-4d21-a56b-5c4fb316bce3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('edfa3417-22bb-4716-a9f3-c0073d9465e3', '3f162607-b8be-428c-8123-69bdc28a0bdd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('edfa3417-22bb-4716-a9f3-c0073d9465e3', '1b87e59d-1b1d-4db1-8cf0-6409e34d6f39', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f162607-b8be-428c-8123-69bdc28a0bdd', '235f693c-13db-4fb6-8ec1-5bed0d9f5aeb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f162607-b8be-428c-8123-69bdc28a0bdd', '421ecaf6-0ef0-48bc-ae1f-69476c2510b5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f162607-b8be-428c-8123-69bdc28a0bdd', '81313879-f7aa-4d21-a56b-5c4fb316bce3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f162607-b8be-428c-8123-69bdc28a0bdd', 'edfa3417-22bb-4716-a9f3-c0073d9465e3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f162607-b8be-428c-8123-69bdc28a0bdd', '1b87e59d-1b1d-4db1-8cf0-6409e34d6f39', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2236da86-0d2c-4ddb-9cb1-d8206192f270', '2ac8405f-b85d-4e89-b7ae-2f3e371ec99a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2236da86-0d2c-4ddb-9cb1-d8206192f270', '3d6efee2-6528-4e11-b290-1998ffe4c408', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2236da86-0d2c-4ddb-9cb1-d8206192f270', '0c1d94ea-7fd0-436c-b8d2-6c8495d0bfa3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2236da86-0d2c-4ddb-9cb1-d8206192f270', '59a56eeb-2f59-4d6c-b113-8a7d62dbce2f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2236da86-0d2c-4ddb-9cb1-d8206192f270', 'a6bd2116-1f13-4c3d-bc3a-8b4176a8cb1f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2ac8405f-b85d-4e89-b7ae-2f3e371ec99a', '2236da86-0d2c-4ddb-9cb1-d8206192f270', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2ac8405f-b85d-4e89-b7ae-2f3e371ec99a', '3d6efee2-6528-4e11-b290-1998ffe4c408', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2ac8405f-b85d-4e89-b7ae-2f3e371ec99a', '0c1d94ea-7fd0-436c-b8d2-6c8495d0bfa3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2ac8405f-b85d-4e89-b7ae-2f3e371ec99a', '59a56eeb-2f59-4d6c-b113-8a7d62dbce2f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2ac8405f-b85d-4e89-b7ae-2f3e371ec99a', 'a6bd2116-1f13-4c3d-bc3a-8b4176a8cb1f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d6efee2-6528-4e11-b290-1998ffe4c408', '2236da86-0d2c-4ddb-9cb1-d8206192f270', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d6efee2-6528-4e11-b290-1998ffe4c408', '2ac8405f-b85d-4e89-b7ae-2f3e371ec99a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d6efee2-6528-4e11-b290-1998ffe4c408', '0c1d94ea-7fd0-436c-b8d2-6c8495d0bfa3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d6efee2-6528-4e11-b290-1998ffe4c408', '59a56eeb-2f59-4d6c-b113-8a7d62dbce2f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d6efee2-6528-4e11-b290-1998ffe4c408', 'a6bd2116-1f13-4c3d-bc3a-8b4176a8cb1f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6bd2116-1f13-4c3d-bc3a-8b4176a8cb1f', '2236da86-0d2c-4ddb-9cb1-d8206192f270', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6bd2116-1f13-4c3d-bc3a-8b4176a8cb1f', '2ac8405f-b85d-4e89-b7ae-2f3e371ec99a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6bd2116-1f13-4c3d-bc3a-8b4176a8cb1f', '3d6efee2-6528-4e11-b290-1998ffe4c408', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6bd2116-1f13-4c3d-bc3a-8b4176a8cb1f', '0c1d94ea-7fd0-436c-b8d2-6c8495d0bfa3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6bd2116-1f13-4c3d-bc3a-8b4176a8cb1f', '59a56eeb-2f59-4d6c-b113-8a7d62dbce2f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c1d94ea-7fd0-436c-b8d2-6c8495d0bfa3', '2236da86-0d2c-4ddb-9cb1-d8206192f270', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c1d94ea-7fd0-436c-b8d2-6c8495d0bfa3', '2ac8405f-b85d-4e89-b7ae-2f3e371ec99a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c1d94ea-7fd0-436c-b8d2-6c8495d0bfa3', '3d6efee2-6528-4e11-b290-1998ffe4c408', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c1d94ea-7fd0-436c-b8d2-6c8495d0bfa3', '59a56eeb-2f59-4d6c-b113-8a7d62dbce2f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c1d94ea-7fd0-436c-b8d2-6c8495d0bfa3', 'a6bd2116-1f13-4c3d-bc3a-8b4176a8cb1f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59a56eeb-2f59-4d6c-b113-8a7d62dbce2f', '2236da86-0d2c-4ddb-9cb1-d8206192f270', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59a56eeb-2f59-4d6c-b113-8a7d62dbce2f', '2ac8405f-b85d-4e89-b7ae-2f3e371ec99a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59a56eeb-2f59-4d6c-b113-8a7d62dbce2f', '3d6efee2-6528-4e11-b290-1998ffe4c408', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59a56eeb-2f59-4d6c-b113-8a7d62dbce2f', '0c1d94ea-7fd0-436c-b8d2-6c8495d0bfa3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59a56eeb-2f59-4d6c-b113-8a7d62dbce2f', 'a6bd2116-1f13-4c3d-bc3a-8b4176a8cb1f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84152864-255c-4543-a886-70cd2c3cf0b3', '3fc1bf4b-5ca5-43a8-811b-b6a27ce0fd77', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84152864-255c-4543-a886-70cd2c3cf0b3', 'f2d4440d-c2f2-4302-8d13-695fae0528df', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84152864-255c-4543-a886-70cd2c3cf0b3', '4080f40a-94c5-488c-8696-3e0e361867a9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84152864-255c-4543-a886-70cd2c3cf0b3', '9a3de3af-203f-4472-9e10-6261a73e5277', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84152864-255c-4543-a886-70cd2c3cf0b3', '01b9d2b3-3fd6-49e0-a5b2-89446b3fc032', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('00df8c27-55da-4db8-a64b-56133f96562e', '1b87e59d-1b1d-4db1-8cf0-6409e34d6f39', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('00df8c27-55da-4db8-a64b-56133f96562e', '235f693c-13db-4fb6-8ec1-5bed0d9f5aeb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('00df8c27-55da-4db8-a64b-56133f96562e', '421ecaf6-0ef0-48bc-ae1f-69476c2510b5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('00df8c27-55da-4db8-a64b-56133f96562e', '81313879-f7aa-4d21-a56b-5c4fb316bce3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('00df8c27-55da-4db8-a64b-56133f96562e', 'f0e523e7-ecb0-409f-b0d1-364de23423b5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('743f4771-4023-4d48-ab1c-682eb47cc4da', '442e23ec-4d44-4cd6-b4a7-fd3e5af9c665', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('743f4771-4023-4d48-ab1c-682eb47cc4da', '54db7505-e75b-4e32-b383-67322a33dbac', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('743f4771-4023-4d48-ab1c-682eb47cc4da', '97ee4720-ffc8-40e2-8de6-b37f8f5aeda0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('442e23ec-4d44-4cd6-b4a7-fd3e5af9c665', '743f4771-4023-4d48-ab1c-682eb47cc4da', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('442e23ec-4d44-4cd6-b4a7-fd3e5af9c665', '54db7505-e75b-4e32-b383-67322a33dbac', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('442e23ec-4d44-4cd6-b4a7-fd3e5af9c665', '97ee4720-ffc8-40e2-8de6-b37f8f5aeda0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('54db7505-e75b-4e32-b383-67322a33dbac', '743f4771-4023-4d48-ab1c-682eb47cc4da', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('54db7505-e75b-4e32-b383-67322a33dbac', '442e23ec-4d44-4cd6-b4a7-fd3e5af9c665', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('54db7505-e75b-4e32-b383-67322a33dbac', '97ee4720-ffc8-40e2-8de6-b37f8f5aeda0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('97ee4720-ffc8-40e2-8de6-b37f8f5aeda0', '743f4771-4023-4d48-ab1c-682eb47cc4da', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('97ee4720-ffc8-40e2-8de6-b37f8f5aeda0', '442e23ec-4d44-4cd6-b4a7-fd3e5af9c665', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('97ee4720-ffc8-40e2-8de6-b37f8f5aeda0', '54db7505-e75b-4e32-b383-67322a33dbac', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('543d6b1a-fbbd-4a42-9e32-be57e752baae', '4a5b7be4-b43e-419d-91ef-3b1ade99554b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('543d6b1a-fbbd-4a42-9e32-be57e752baae', '3eb0c949-d937-4e8a-b4dc-bc46c1ae970c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('543d6b1a-fbbd-4a42-9e32-be57e752baae', '77656cc9-59a7-489a-801d-bb37669fb175', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('543d6b1a-fbbd-4a42-9e32-be57e752baae', 'ba064819-13bb-4035-bacb-abe76e01f519', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('543d6b1a-fbbd-4a42-9e32-be57e752baae', '91ac4986-7a14-424e-ae03-656885736c75', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('816fe4ff-8864-499f-bcb1-9cafcbc272a9', 'db0befcd-334f-46a1-b1a5-78a94eca6ef2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('816fe4ff-8864-499f-bcb1-9cafcbc272a9', 'edb8159c-88b8-48c2-9533-3ad72c084ba8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('816fe4ff-8864-499f-bcb1-9cafcbc272a9', 'fa6cf97b-ebfc-4aef-bb7c-bc1db4e3b410', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('816fe4ff-8864-499f-bcb1-9cafcbc272a9', '05805aa6-b849-488b-8656-a71f2d9fd1f3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('816fe4ff-8864-499f-bcb1-9cafcbc272a9', 'c9e2cd18-e55f-4493-ab6c-130b5fb08770', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a5b7be4-b43e-419d-91ef-3b1ade99554b', '543d6b1a-fbbd-4a42-9e32-be57e752baae', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a5b7be4-b43e-419d-91ef-3b1ade99554b', '3eb0c949-d937-4e8a-b4dc-bc46c1ae970c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a5b7be4-b43e-419d-91ef-3b1ade99554b', '77656cc9-59a7-489a-801d-bb37669fb175', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a5b7be4-b43e-419d-91ef-3b1ade99554b', 'ba064819-13bb-4035-bacb-abe76e01f519', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a5b7be4-b43e-419d-91ef-3b1ade99554b', '91ac4986-7a14-424e-ae03-656885736c75', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('05805aa6-b849-488b-8656-a71f2d9fd1f3', '816fe4ff-8864-499f-bcb1-9cafcbc272a9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('05805aa6-b849-488b-8656-a71f2d9fd1f3', 'db0befcd-334f-46a1-b1a5-78a94eca6ef2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('05805aa6-b849-488b-8656-a71f2d9fd1f3', 'edb8159c-88b8-48c2-9533-3ad72c084ba8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('05805aa6-b849-488b-8656-a71f2d9fd1f3', 'fa6cf97b-ebfc-4aef-bb7c-bc1db4e3b410', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('05805aa6-b849-488b-8656-a71f2d9fd1f3', 'c9e2cd18-e55f-4493-ab6c-130b5fb08770', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d29a0d4-601c-4dd4-b381-3cd58d4be6f3', '743f4771-4023-4d48-ab1c-682eb47cc4da', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d29a0d4-601c-4dd4-b381-3cd58d4be6f3', '442e23ec-4d44-4cd6-b4a7-fd3e5af9c665', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d29a0d4-601c-4dd4-b381-3cd58d4be6f3', '54db7505-e75b-4e32-b383-67322a33dbac', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d29a0d4-601c-4dd4-b381-3cd58d4be6f3', '97ee4720-ffc8-40e2-8de6-b37f8f5aeda0', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('77656cc9-59a7-489a-801d-bb37669fb175', 'ba064819-13bb-4035-bacb-abe76e01f519', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('77656cc9-59a7-489a-801d-bb37669fb175', '91ac4986-7a14-424e-ae03-656885736c75', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('77656cc9-59a7-489a-801d-bb37669fb175', '37711381-db7c-434d-9b14-3189c26154ea', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('77656cc9-59a7-489a-801d-bb37669fb175', 'f9c99d68-36b6-42f6-86a6-6edc08cf3293', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('77656cc9-59a7-489a-801d-bb37669fb175', '543d6b1a-fbbd-4a42-9e32-be57e752baae', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba064819-13bb-4035-bacb-abe76e01f519', '77656cc9-59a7-489a-801d-bb37669fb175', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba064819-13bb-4035-bacb-abe76e01f519', '91ac4986-7a14-424e-ae03-656885736c75', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba064819-13bb-4035-bacb-abe76e01f519', '37711381-db7c-434d-9b14-3189c26154ea', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba064819-13bb-4035-bacb-abe76e01f519', 'f9c99d68-36b6-42f6-86a6-6edc08cf3293', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba064819-13bb-4035-bacb-abe76e01f519', '543d6b1a-fbbd-4a42-9e32-be57e752baae', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('91ac4986-7a14-424e-ae03-656885736c75', '77656cc9-59a7-489a-801d-bb37669fb175', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('91ac4986-7a14-424e-ae03-656885736c75', 'ba064819-13bb-4035-bacb-abe76e01f519', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('91ac4986-7a14-424e-ae03-656885736c75', '37711381-db7c-434d-9b14-3189c26154ea', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('91ac4986-7a14-424e-ae03-656885736c75', 'f9c99d68-36b6-42f6-86a6-6edc08cf3293', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('91ac4986-7a14-424e-ae03-656885736c75', '543d6b1a-fbbd-4a42-9e32-be57e752baae', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('37711381-db7c-434d-9b14-3189c26154ea', '77656cc9-59a7-489a-801d-bb37669fb175', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('37711381-db7c-434d-9b14-3189c26154ea', 'ba064819-13bb-4035-bacb-abe76e01f519', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('37711381-db7c-434d-9b14-3189c26154ea', '91ac4986-7a14-424e-ae03-656885736c75', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('37711381-db7c-434d-9b14-3189c26154ea', 'f9c99d68-36b6-42f6-86a6-6edc08cf3293', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('37711381-db7c-434d-9b14-3189c26154ea', '543d6b1a-fbbd-4a42-9e32-be57e752baae', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('83a7600d-b546-450d-9672-88d698956709', '543d6b1a-fbbd-4a42-9e32-be57e752baae', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('83a7600d-b546-450d-9672-88d698956709', '4a5b7be4-b43e-419d-91ef-3b1ade99554b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('83a7600d-b546-450d-9672-88d698956709', '77656cc9-59a7-489a-801d-bb37669fb175', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('83a7600d-b546-450d-9672-88d698956709', 'ba064819-13bb-4035-bacb-abe76e01f519', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('83a7600d-b546-450d-9672-88d698956709', '91ac4986-7a14-424e-ae03-656885736c75', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9c99d68-36b6-42f6-86a6-6edc08cf3293', '77656cc9-59a7-489a-801d-bb37669fb175', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9c99d68-36b6-42f6-86a6-6edc08cf3293', 'ba064819-13bb-4035-bacb-abe76e01f519', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9c99d68-36b6-42f6-86a6-6edc08cf3293', '91ac4986-7a14-424e-ae03-656885736c75', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9c99d68-36b6-42f6-86a6-6edc08cf3293', '37711381-db7c-434d-9b14-3189c26154ea', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9c99d68-36b6-42f6-86a6-6edc08cf3293', '543d6b1a-fbbd-4a42-9e32-be57e752baae', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3eb0c949-d937-4e8a-b4dc-bc46c1ae970c', '543d6b1a-fbbd-4a42-9e32-be57e752baae', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3eb0c949-d937-4e8a-b4dc-bc46c1ae970c', '4a5b7be4-b43e-419d-91ef-3b1ade99554b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3eb0c949-d937-4e8a-b4dc-bc46c1ae970c', '77656cc9-59a7-489a-801d-bb37669fb175', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3eb0c949-d937-4e8a-b4dc-bc46c1ae970c', 'ba064819-13bb-4035-bacb-abe76e01f519', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3eb0c949-d937-4e8a-b4dc-bc46c1ae970c', '91ac4986-7a14-424e-ae03-656885736c75', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0f59bf0-d49e-4efb-9408-14dab2a76550', '743f4771-4023-4d48-ab1c-682eb47cc4da', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0f59bf0-d49e-4efb-9408-14dab2a76550', '442e23ec-4d44-4cd6-b4a7-fd3e5af9c665', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0f59bf0-d49e-4efb-9408-14dab2a76550', '54db7505-e75b-4e32-b383-67322a33dbac', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0f59bf0-d49e-4efb-9408-14dab2a76550', '97ee4720-ffc8-40e2-8de6-b37f8f5aeda0', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('320c2fb2-cffe-4340-8416-0b70184beec6', 'baea4d9e-c409-45d0-8cc1-16b35455689c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('320c2fb2-cffe-4340-8416-0b70184beec6', '2d51ca76-f1ca-47ac-a1ba-058f8a2938cc', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('320c2fb2-cffe-4340-8416-0b70184beec6', '97fff122-5563-4f52-a21c-1fbdd8ada0bb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('320c2fb2-cffe-4340-8416-0b70184beec6', 'cc095517-a9c1-4d67-b5db-a31495ecac09', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('320c2fb2-cffe-4340-8416-0b70184beec6', 'de44e09c-a2d8-4a5c-a9df-b7f8eec9efd6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b73035c2-cc76-4ce1-8544-0ebb15350308', 'baea4d9e-c409-45d0-8cc1-16b35455689c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b73035c2-cc76-4ce1-8544-0ebb15350308', '2d51ca76-f1ca-47ac-a1ba-058f8a2938cc', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b73035c2-cc76-4ce1-8544-0ebb15350308', '97fff122-5563-4f52-a21c-1fbdd8ada0bb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b73035c2-cc76-4ce1-8544-0ebb15350308', 'cc095517-a9c1-4d67-b5db-a31495ecac09', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b73035c2-cc76-4ce1-8544-0ebb15350308', 'de44e09c-a2d8-4a5c-a9df-b7f8eec9efd6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('baea4d9e-c409-45d0-8cc1-16b35455689c', '2d51ca76-f1ca-47ac-a1ba-058f8a2938cc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('baea4d9e-c409-45d0-8cc1-16b35455689c', '97fff122-5563-4f52-a21c-1fbdd8ada0bb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('baea4d9e-c409-45d0-8cc1-16b35455689c', 'cc095517-a9c1-4d67-b5db-a31495ecac09', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('baea4d9e-c409-45d0-8cc1-16b35455689c', 'de44e09c-a2d8-4a5c-a9df-b7f8eec9efd6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('baea4d9e-c409-45d0-8cc1-16b35455689c', 'f4b74aaa-f03e-4401-b240-9108f3303e94', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d51ca76-f1ca-47ac-a1ba-058f8a2938cc', 'baea4d9e-c409-45d0-8cc1-16b35455689c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d51ca76-f1ca-47ac-a1ba-058f8a2938cc', '97fff122-5563-4f52-a21c-1fbdd8ada0bb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d51ca76-f1ca-47ac-a1ba-058f8a2938cc', 'cc095517-a9c1-4d67-b5db-a31495ecac09', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d51ca76-f1ca-47ac-a1ba-058f8a2938cc', 'de44e09c-a2d8-4a5c-a9df-b7f8eec9efd6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d51ca76-f1ca-47ac-a1ba-058f8a2938cc', 'f4b74aaa-f03e-4401-b240-9108f3303e94', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('97fff122-5563-4f52-a21c-1fbdd8ada0bb', 'baea4d9e-c409-45d0-8cc1-16b35455689c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('97fff122-5563-4f52-a21c-1fbdd8ada0bb', '2d51ca76-f1ca-47ac-a1ba-058f8a2938cc', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('97fff122-5563-4f52-a21c-1fbdd8ada0bb', 'cc095517-a9c1-4d67-b5db-a31495ecac09', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('97fff122-5563-4f52-a21c-1fbdd8ada0bb', 'de44e09c-a2d8-4a5c-a9df-b7f8eec9efd6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('97fff122-5563-4f52-a21c-1fbdd8ada0bb', 'f4b74aaa-f03e-4401-b240-9108f3303e94', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cc095517-a9c1-4d67-b5db-a31495ecac09', 'baea4d9e-c409-45d0-8cc1-16b35455689c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cc095517-a9c1-4d67-b5db-a31495ecac09', '2d51ca76-f1ca-47ac-a1ba-058f8a2938cc', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cc095517-a9c1-4d67-b5db-a31495ecac09', '97fff122-5563-4f52-a21c-1fbdd8ada0bb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cc095517-a9c1-4d67-b5db-a31495ecac09', 'de44e09c-a2d8-4a5c-a9df-b7f8eec9efd6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cc095517-a9c1-4d67-b5db-a31495ecac09', 'f4b74aaa-f03e-4401-b240-9108f3303e94', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('de44e09c-a2d8-4a5c-a9df-b7f8eec9efd6', 'baea4d9e-c409-45d0-8cc1-16b35455689c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('de44e09c-a2d8-4a5c-a9df-b7f8eec9efd6', '2d51ca76-f1ca-47ac-a1ba-058f8a2938cc', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('de44e09c-a2d8-4a5c-a9df-b7f8eec9efd6', '97fff122-5563-4f52-a21c-1fbdd8ada0bb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('de44e09c-a2d8-4a5c-a9df-b7f8eec9efd6', 'cc095517-a9c1-4d67-b5db-a31495ecac09', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('de44e09c-a2d8-4a5c-a9df-b7f8eec9efd6', 'f4b74aaa-f03e-4401-b240-9108f3303e94', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f4b74aaa-f03e-4401-b240-9108f3303e94', 'baea4d9e-c409-45d0-8cc1-16b35455689c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f4b74aaa-f03e-4401-b240-9108f3303e94', '2d51ca76-f1ca-47ac-a1ba-058f8a2938cc', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f4b74aaa-f03e-4401-b240-9108f3303e94', '97fff122-5563-4f52-a21c-1fbdd8ada0bb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f4b74aaa-f03e-4401-b240-9108f3303e94', 'cc095517-a9c1-4d67-b5db-a31495ecac09', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f4b74aaa-f03e-4401-b240-9108f3303e94', 'de44e09c-a2d8-4a5c-a9df-b7f8eec9efd6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9cc8f244-c140-48b7-8022-8ddaf55086de', 'baea4d9e-c409-45d0-8cc1-16b35455689c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9cc8f244-c140-48b7-8022-8ddaf55086de', '2d51ca76-f1ca-47ac-a1ba-058f8a2938cc', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9cc8f244-c140-48b7-8022-8ddaf55086de', '97fff122-5563-4f52-a21c-1fbdd8ada0bb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9cc8f244-c140-48b7-8022-8ddaf55086de', 'cc095517-a9c1-4d67-b5db-a31495ecac09', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9cc8f244-c140-48b7-8022-8ddaf55086de', 'de44e09c-a2d8-4a5c-a9df-b7f8eec9efd6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('41bfe8f5-c075-4ae0-9f0d-4de27b12e3cb', '1208d6cd-359d-467e-a7d9-7f84a1ee885f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('41bfe8f5-c075-4ae0-9f0d-4de27b12e3cb', '4a5ea5cc-67a2-46cd-86fe-a23d2b211107', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('41bfe8f5-c075-4ae0-9f0d-4de27b12e3cb', 'd215fd43-2837-4eeb-ac78-aa283ecc2a6a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('41bfe8f5-c075-4ae0-9f0d-4de27b12e3cb', 'b138d2e1-269f-4768-8a37-6281884ab769', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('41bfe8f5-c075-4ae0-9f0d-4de27b12e3cb', '0deb4e76-9a71-43d3-bea0-6c19ae1d231b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1208d6cd-359d-467e-a7d9-7f84a1ee885f', '41bfe8f5-c075-4ae0-9f0d-4de27b12e3cb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1208d6cd-359d-467e-a7d9-7f84a1ee885f', '4a5ea5cc-67a2-46cd-86fe-a23d2b211107', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1208d6cd-359d-467e-a7d9-7f84a1ee885f', 'd215fd43-2837-4eeb-ac78-aa283ecc2a6a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1208d6cd-359d-467e-a7d9-7f84a1ee885f', 'b138d2e1-269f-4768-8a37-6281884ab769', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1208d6cd-359d-467e-a7d9-7f84a1ee885f', '0deb4e76-9a71-43d3-bea0-6c19ae1d231b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a5ea5cc-67a2-46cd-86fe-a23d2b211107', '41bfe8f5-c075-4ae0-9f0d-4de27b12e3cb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a5ea5cc-67a2-46cd-86fe-a23d2b211107', '1208d6cd-359d-467e-a7d9-7f84a1ee885f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a5ea5cc-67a2-46cd-86fe-a23d2b211107', 'd215fd43-2837-4eeb-ac78-aa283ecc2a6a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a5ea5cc-67a2-46cd-86fe-a23d2b211107', 'b138d2e1-269f-4768-8a37-6281884ab769', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a5ea5cc-67a2-46cd-86fe-a23d2b211107', '0deb4e76-9a71-43d3-bea0-6c19ae1d231b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d215fd43-2837-4eeb-ac78-aa283ecc2a6a', '41bfe8f5-c075-4ae0-9f0d-4de27b12e3cb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d215fd43-2837-4eeb-ac78-aa283ecc2a6a', '1208d6cd-359d-467e-a7d9-7f84a1ee885f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d215fd43-2837-4eeb-ac78-aa283ecc2a6a', '4a5ea5cc-67a2-46cd-86fe-a23d2b211107', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d215fd43-2837-4eeb-ac78-aa283ecc2a6a', 'b138d2e1-269f-4768-8a37-6281884ab769', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d215fd43-2837-4eeb-ac78-aa283ecc2a6a', '0deb4e76-9a71-43d3-bea0-6c19ae1d231b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b138d2e1-269f-4768-8a37-6281884ab769', '41bfe8f5-c075-4ae0-9f0d-4de27b12e3cb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b138d2e1-269f-4768-8a37-6281884ab769', '1208d6cd-359d-467e-a7d9-7f84a1ee885f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b138d2e1-269f-4768-8a37-6281884ab769', '4a5ea5cc-67a2-46cd-86fe-a23d2b211107', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b138d2e1-269f-4768-8a37-6281884ab769', 'd215fd43-2837-4eeb-ac78-aa283ecc2a6a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b138d2e1-269f-4768-8a37-6281884ab769', '0deb4e76-9a71-43d3-bea0-6c19ae1d231b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0deb4e76-9a71-43d3-bea0-6c19ae1d231b', '41bfe8f5-c075-4ae0-9f0d-4de27b12e3cb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0deb4e76-9a71-43d3-bea0-6c19ae1d231b', '1208d6cd-359d-467e-a7d9-7f84a1ee885f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0deb4e76-9a71-43d3-bea0-6c19ae1d231b', '4a5ea5cc-67a2-46cd-86fe-a23d2b211107', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0deb4e76-9a71-43d3-bea0-6c19ae1d231b', 'd215fd43-2837-4eeb-ac78-aa283ecc2a6a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0deb4e76-9a71-43d3-bea0-6c19ae1d231b', 'b138d2e1-269f-4768-8a37-6281884ab769', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b4303d2-fe0d-47e6-abf2-faba9946af89', '41bfe8f5-c075-4ae0-9f0d-4de27b12e3cb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b4303d2-fe0d-47e6-abf2-faba9946af89', '1208d6cd-359d-467e-a7d9-7f84a1ee885f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b4303d2-fe0d-47e6-abf2-faba9946af89', '4a5ea5cc-67a2-46cd-86fe-a23d2b211107', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b4303d2-fe0d-47e6-abf2-faba9946af89', 'd215fd43-2837-4eeb-ac78-aa283ecc2a6a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b4303d2-fe0d-47e6-abf2-faba9946af89', 'b138d2e1-269f-4768-8a37-6281884ab769', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9223bb94-c2c1-46f3-8cda-6df4b3de1a63', '41bfe8f5-c075-4ae0-9f0d-4de27b12e3cb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9223bb94-c2c1-46f3-8cda-6df4b3de1a63', '1208d6cd-359d-467e-a7d9-7f84a1ee885f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9223bb94-c2c1-46f3-8cda-6df4b3de1a63', '4a5ea5cc-67a2-46cd-86fe-a23d2b211107', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9223bb94-c2c1-46f3-8cda-6df4b3de1a63', 'd215fd43-2837-4eeb-ac78-aa283ecc2a6a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9223bb94-c2c1-46f3-8cda-6df4b3de1a63', 'b138d2e1-269f-4768-8a37-6281884ab769', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0d6d03e2-2363-4194-b050-177f7933cdd1', '42330662-2607-4a66-a08a-5a3c0a90804d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0d6d03e2-2363-4194-b050-177f7933cdd1', '41bfe8f5-c075-4ae0-9f0d-4de27b12e3cb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0d6d03e2-2363-4194-b050-177f7933cdd1', '1208d6cd-359d-467e-a7d9-7f84a1ee885f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0d6d03e2-2363-4194-b050-177f7933cdd1', '4a5ea5cc-67a2-46cd-86fe-a23d2b211107', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0d6d03e2-2363-4194-b050-177f7933cdd1', 'd215fd43-2837-4eeb-ac78-aa283ecc2a6a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7995fb58-4d91-4c82-9898-5f46fc1d0164', 'baea4d9e-c409-45d0-8cc1-16b35455689c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7995fb58-4d91-4c82-9898-5f46fc1d0164', '2d51ca76-f1ca-47ac-a1ba-058f8a2938cc', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7995fb58-4d91-4c82-9898-5f46fc1d0164', '97fff122-5563-4f52-a21c-1fbdd8ada0bb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7995fb58-4d91-4c82-9898-5f46fc1d0164', 'cc095517-a9c1-4d67-b5db-a31495ecac09', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7995fb58-4d91-4c82-9898-5f46fc1d0164', 'de44e09c-a2d8-4a5c-a9df-b7f8eec9efd6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('42330662-2607-4a66-a08a-5a3c0a90804d', '0d6d03e2-2363-4194-b050-177f7933cdd1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('42330662-2607-4a66-a08a-5a3c0a90804d', '41bfe8f5-c075-4ae0-9f0d-4de27b12e3cb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('42330662-2607-4a66-a08a-5a3c0a90804d', '1208d6cd-359d-467e-a7d9-7f84a1ee885f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('42330662-2607-4a66-a08a-5a3c0a90804d', '4a5ea5cc-67a2-46cd-86fe-a23d2b211107', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('42330662-2607-4a66-a08a-5a3c0a90804d', 'd215fd43-2837-4eeb-ac78-aa283ecc2a6a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f55644f-b823-4950-8316-c1d1165b81d3', 'ba2a3619-4ad6-497d-8659-63f042c5d56d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f55644f-b823-4950-8316-c1d1165b81d3', '6cfe0d1c-7ca8-486d-8853-6ce65a27b687', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f55644f-b823-4950-8316-c1d1165b81d3', '9e0d08fd-01cc-4ded-bc3d-5ce9d878a947', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f55644f-b823-4950-8316-c1d1165b81d3', 'cfbdcabf-e7db-466a-8d54-b1ea769edda7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f55644f-b823-4950-8316-c1d1165b81d3', 'c9313e39-c389-4d01-a9d3-9b9204ea34e4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba2a3619-4ad6-497d-8659-63f042c5d56d', '8f55644f-b823-4950-8316-c1d1165b81d3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba2a3619-4ad6-497d-8659-63f042c5d56d', '6cfe0d1c-7ca8-486d-8853-6ce65a27b687', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba2a3619-4ad6-497d-8659-63f042c5d56d', '9e0d08fd-01cc-4ded-bc3d-5ce9d878a947', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba2a3619-4ad6-497d-8659-63f042c5d56d', 'cfbdcabf-e7db-466a-8d54-b1ea769edda7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba2a3619-4ad6-497d-8659-63f042c5d56d', 'c9313e39-c389-4d01-a9d3-9b9204ea34e4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6cfe0d1c-7ca8-486d-8853-6ce65a27b687', '8f55644f-b823-4950-8316-c1d1165b81d3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6cfe0d1c-7ca8-486d-8853-6ce65a27b687', 'ba2a3619-4ad6-497d-8659-63f042c5d56d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6cfe0d1c-7ca8-486d-8853-6ce65a27b687', '9e0d08fd-01cc-4ded-bc3d-5ce9d878a947', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6cfe0d1c-7ca8-486d-8853-6ce65a27b687', 'cfbdcabf-e7db-466a-8d54-b1ea769edda7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6cfe0d1c-7ca8-486d-8853-6ce65a27b687', 'c9313e39-c389-4d01-a9d3-9b9204ea34e4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9e0d08fd-01cc-4ded-bc3d-5ce9d878a947', '8f55644f-b823-4950-8316-c1d1165b81d3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9e0d08fd-01cc-4ded-bc3d-5ce9d878a947', 'ba2a3619-4ad6-497d-8659-63f042c5d56d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9e0d08fd-01cc-4ded-bc3d-5ce9d878a947', '6cfe0d1c-7ca8-486d-8853-6ce65a27b687', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9e0d08fd-01cc-4ded-bc3d-5ce9d878a947', 'cfbdcabf-e7db-466a-8d54-b1ea769edda7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9e0d08fd-01cc-4ded-bc3d-5ce9d878a947', 'c9313e39-c389-4d01-a9d3-9b9204ea34e4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cfbdcabf-e7db-466a-8d54-b1ea769edda7', '8f55644f-b823-4950-8316-c1d1165b81d3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cfbdcabf-e7db-466a-8d54-b1ea769edda7', 'ba2a3619-4ad6-497d-8659-63f042c5d56d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cfbdcabf-e7db-466a-8d54-b1ea769edda7', '6cfe0d1c-7ca8-486d-8853-6ce65a27b687', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cfbdcabf-e7db-466a-8d54-b1ea769edda7', '9e0d08fd-01cc-4ded-bc3d-5ce9d878a947', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cfbdcabf-e7db-466a-8d54-b1ea769edda7', 'c9313e39-c389-4d01-a9d3-9b9204ea34e4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('297dc0c9-01ad-4c5e-a6b0-a7395f5f45ef', '8f55644f-b823-4950-8316-c1d1165b81d3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('297dc0c9-01ad-4c5e-a6b0-a7395f5f45ef', 'ba2a3619-4ad6-497d-8659-63f042c5d56d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('297dc0c9-01ad-4c5e-a6b0-a7395f5f45ef', '6cfe0d1c-7ca8-486d-8853-6ce65a27b687', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('297dc0c9-01ad-4c5e-a6b0-a7395f5f45ef', '9e0d08fd-01cc-4ded-bc3d-5ce9d878a947', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('297dc0c9-01ad-4c5e-a6b0-a7395f5f45ef', 'cfbdcabf-e7db-466a-8d54-b1ea769edda7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9313e39-c389-4d01-a9d3-9b9204ea34e4', '8f55644f-b823-4950-8316-c1d1165b81d3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9313e39-c389-4d01-a9d3-9b9204ea34e4', 'ba2a3619-4ad6-497d-8659-63f042c5d56d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9313e39-c389-4d01-a9d3-9b9204ea34e4', '6cfe0d1c-7ca8-486d-8853-6ce65a27b687', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9313e39-c389-4d01-a9d3-9b9204ea34e4', '9e0d08fd-01cc-4ded-bc3d-5ce9d878a947', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9313e39-c389-4d01-a9d3-9b9204ea34e4', 'cfbdcabf-e7db-466a-8d54-b1ea769edda7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('196c8ff9-27d1-461a-892e-3e17cc68d640', '8f55644f-b823-4950-8316-c1d1165b81d3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('196c8ff9-27d1-461a-892e-3e17cc68d640', 'ba2a3619-4ad6-497d-8659-63f042c5d56d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('196c8ff9-27d1-461a-892e-3e17cc68d640', '6cfe0d1c-7ca8-486d-8853-6ce65a27b687', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('196c8ff9-27d1-461a-892e-3e17cc68d640', '9e0d08fd-01cc-4ded-bc3d-5ce9d878a947', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('196c8ff9-27d1-461a-892e-3e17cc68d640', 'cfbdcabf-e7db-466a-8d54-b1ea769edda7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('280bfdd4-874f-42a0-9f2f-55f74347b8bd', '8f55644f-b823-4950-8316-c1d1165b81d3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('280bfdd4-874f-42a0-9f2f-55f74347b8bd', 'ba2a3619-4ad6-497d-8659-63f042c5d56d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('280bfdd4-874f-42a0-9f2f-55f74347b8bd', '6cfe0d1c-7ca8-486d-8853-6ce65a27b687', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('280bfdd4-874f-42a0-9f2f-55f74347b8bd', '9e0d08fd-01cc-4ded-bc3d-5ce9d878a947', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('280bfdd4-874f-42a0-9f2f-55f74347b8bd', 'cfbdcabf-e7db-466a-8d54-b1ea769edda7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('34c3bc1a-05b0-4cd6-b765-a8869de76e84', '99145489-a01c-4e36-987c-de8d2228e87e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('34c3bc1a-05b0-4cd6-b765-a8869de76e84', '156479a2-b9a8-4523-a32e-aefd5e673329', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('34c3bc1a-05b0-4cd6-b765-a8869de76e84', '8f55644f-b823-4950-8316-c1d1165b81d3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('34c3bc1a-05b0-4cd6-b765-a8869de76e84', 'ba2a3619-4ad6-497d-8659-63f042c5d56d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('34c3bc1a-05b0-4cd6-b765-a8869de76e84', '6cfe0d1c-7ca8-486d-8853-6ce65a27b687', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('99145489-a01c-4e36-987c-de8d2228e87e', '34c3bc1a-05b0-4cd6-b765-a8869de76e84', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('99145489-a01c-4e36-987c-de8d2228e87e', '156479a2-b9a8-4523-a32e-aefd5e673329', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('99145489-a01c-4e36-987c-de8d2228e87e', '8f55644f-b823-4950-8316-c1d1165b81d3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('99145489-a01c-4e36-987c-de8d2228e87e', 'ba2a3619-4ad6-497d-8659-63f042c5d56d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('99145489-a01c-4e36-987c-de8d2228e87e', '6cfe0d1c-7ca8-486d-8853-6ce65a27b687', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('156479a2-b9a8-4523-a32e-aefd5e673329', '34c3bc1a-05b0-4cd6-b765-a8869de76e84', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('156479a2-b9a8-4523-a32e-aefd5e673329', '99145489-a01c-4e36-987c-de8d2228e87e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('156479a2-b9a8-4523-a32e-aefd5e673329', '8f55644f-b823-4950-8316-c1d1165b81d3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('156479a2-b9a8-4523-a32e-aefd5e673329', 'ba2a3619-4ad6-497d-8659-63f042c5d56d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('156479a2-b9a8-4523-a32e-aefd5e673329', '6cfe0d1c-7ca8-486d-8853-6ce65a27b687', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9458e3dc-934b-49f7-b7bd-6209f6b5faa3', '8f55644f-b823-4950-8316-c1d1165b81d3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9458e3dc-934b-49f7-b7bd-6209f6b5faa3', 'ba2a3619-4ad6-497d-8659-63f042c5d56d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9458e3dc-934b-49f7-b7bd-6209f6b5faa3', '6cfe0d1c-7ca8-486d-8853-6ce65a27b687', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9458e3dc-934b-49f7-b7bd-6209f6b5faa3', '9e0d08fd-01cc-4ded-bc3d-5ce9d878a947', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9458e3dc-934b-49f7-b7bd-6209f6b5faa3', 'cfbdcabf-e7db-466a-8d54-b1ea769edda7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('494bee12-e6d3-43ab-a6f3-617e13f2c85f', '3a56bf5f-e7bb-4406-a956-b3bc508a62ad', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('494bee12-e6d3-43ab-a6f3-617e13f2c85f', '8f55644f-b823-4950-8316-c1d1165b81d3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('494bee12-e6d3-43ab-a6f3-617e13f2c85f', 'ba2a3619-4ad6-497d-8659-63f042c5d56d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e0f9b222-a8fc-46f7-a529-bff439ab77eb', '8f55644f-b823-4950-8316-c1d1165b81d3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e0f9b222-a8fc-46f7-a529-bff439ab77eb', 'ba2a3619-4ad6-497d-8659-63f042c5d56d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e0f9b222-a8fc-46f7-a529-bff439ab77eb', '6cfe0d1c-7ca8-486d-8853-6ce65a27b687', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e0f9b222-a8fc-46f7-a529-bff439ab77eb', '9e0d08fd-01cc-4ded-bc3d-5ce9d878a947', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e0f9b222-a8fc-46f7-a529-bff439ab77eb', 'cfbdcabf-e7db-466a-8d54-b1ea769edda7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a56bf5f-e7bb-4406-a956-b3bc508a62ad', '494bee12-e6d3-43ab-a6f3-617e13f2c85f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a56bf5f-e7bb-4406-a956-b3bc508a62ad', '8f55644f-b823-4950-8316-c1d1165b81d3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a56bf5f-e7bb-4406-a956-b3bc508a62ad', 'ba2a3619-4ad6-497d-8659-63f042c5d56d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('965f909e-c18f-43ac-83ac-3e63070965fe', '8f55644f-b823-4950-8316-c1d1165b81d3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('965f909e-c18f-43ac-83ac-3e63070965fe', 'ba2a3619-4ad6-497d-8659-63f042c5d56d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('965f909e-c18f-43ac-83ac-3e63070965fe', '6cfe0d1c-7ca8-486d-8853-6ce65a27b687', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('965f909e-c18f-43ac-83ac-3e63070965fe', '9e0d08fd-01cc-4ded-bc3d-5ce9d878a947', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('965f909e-c18f-43ac-83ac-3e63070965fe', 'cfbdcabf-e7db-466a-8d54-b1ea769edda7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d321ebcd-5cb2-48c4-a766-95c352fe9c11', '8f55644f-b823-4950-8316-c1d1165b81d3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d321ebcd-5cb2-48c4-a766-95c352fe9c11', 'ba2a3619-4ad6-497d-8659-63f042c5d56d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d321ebcd-5cb2-48c4-a766-95c352fe9c11', '6cfe0d1c-7ca8-486d-8853-6ce65a27b687', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d321ebcd-5cb2-48c4-a766-95c352fe9c11', '9e0d08fd-01cc-4ded-bc3d-5ce9d878a947', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d321ebcd-5cb2-48c4-a766-95c352fe9c11', 'cfbdcabf-e7db-466a-8d54-b1ea769edda7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('606db03b-e3b1-45f7-a784-9a82339db1f9', '78315b43-ff71-46a9-a3d8-83d5465d6082', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('606db03b-e3b1-45f7-a784-9a82339db1f9', '9d2a6f31-3327-4e2b-adcb-bdcdeaa322e4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('606db03b-e3b1-45f7-a784-9a82339db1f9', 'ab75e45c-9ad4-4403-a29b-b283b871f220', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('606db03b-e3b1-45f7-a784-9a82339db1f9', 'd88cbc75-423c-4834-8a66-5e0bb25d2b18', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('606db03b-e3b1-45f7-a784-9a82339db1f9', '024c8227-9978-477f-bd39-39df0f548b3d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('78315b43-ff71-46a9-a3d8-83d5465d6082', '606db03b-e3b1-45f7-a784-9a82339db1f9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('78315b43-ff71-46a9-a3d8-83d5465d6082', '9d2a6f31-3327-4e2b-adcb-bdcdeaa322e4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('78315b43-ff71-46a9-a3d8-83d5465d6082', 'ab75e45c-9ad4-4403-a29b-b283b871f220', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('78315b43-ff71-46a9-a3d8-83d5465d6082', 'd88cbc75-423c-4834-8a66-5e0bb25d2b18', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('78315b43-ff71-46a9-a3d8-83d5465d6082', '024c8227-9978-477f-bd39-39df0f548b3d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9d2a6f31-3327-4e2b-adcb-bdcdeaa322e4', '606db03b-e3b1-45f7-a784-9a82339db1f9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9d2a6f31-3327-4e2b-adcb-bdcdeaa322e4', '78315b43-ff71-46a9-a3d8-83d5465d6082', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9d2a6f31-3327-4e2b-adcb-bdcdeaa322e4', 'ab75e45c-9ad4-4403-a29b-b283b871f220', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9d2a6f31-3327-4e2b-adcb-bdcdeaa322e4', 'd88cbc75-423c-4834-8a66-5e0bb25d2b18', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9d2a6f31-3327-4e2b-adcb-bdcdeaa322e4', '024c8227-9978-477f-bd39-39df0f548b3d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab75e45c-9ad4-4403-a29b-b283b871f220', 'd88cbc75-423c-4834-8a66-5e0bb25d2b18', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab75e45c-9ad4-4403-a29b-b283b871f220', '024c8227-9978-477f-bd39-39df0f548b3d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab75e45c-9ad4-4403-a29b-b283b871f220', '9b7fa90b-5451-4760-9cb9-1957e4815bd1', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab75e45c-9ad4-4403-a29b-b283b871f220', '122aa21b-d029-4746-9fda-fe0bbe77e9e1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab75e45c-9ad4-4403-a29b-b283b871f220', '10803c1f-112e-475e-a475-8bca2aa2c3eb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c30f212-7155-4a24-8344-82f648ddb11e', '69638daf-3e3e-4a29-bf4a-49f965b54128', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c30f212-7155-4a24-8344-82f648ddb11e', '7dd8d298-93cb-4103-8639-9cb314bbd2ae', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c30f212-7155-4a24-8344-82f648ddb11e', 'a9c2e519-ba59-411a-90c0-4f29a0c2034c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d88cbc75-423c-4834-8a66-5e0bb25d2b18', 'ab75e45c-9ad4-4403-a29b-b283b871f220', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d88cbc75-423c-4834-8a66-5e0bb25d2b18', '024c8227-9978-477f-bd39-39df0f548b3d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d88cbc75-423c-4834-8a66-5e0bb25d2b18', '9b7fa90b-5451-4760-9cb9-1957e4815bd1', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d88cbc75-423c-4834-8a66-5e0bb25d2b18', '122aa21b-d029-4746-9fda-fe0bbe77e9e1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d88cbc75-423c-4834-8a66-5e0bb25d2b18', '10803c1f-112e-475e-a475-8bca2aa2c3eb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('024c8227-9978-477f-bd39-39df0f548b3d', 'ab75e45c-9ad4-4403-a29b-b283b871f220', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('024c8227-9978-477f-bd39-39df0f548b3d', 'd88cbc75-423c-4834-8a66-5e0bb25d2b18', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('024c8227-9978-477f-bd39-39df0f548b3d', '9b7fa90b-5451-4760-9cb9-1957e4815bd1', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('024c8227-9978-477f-bd39-39df0f548b3d', '122aa21b-d029-4746-9fda-fe0bbe77e9e1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('024c8227-9978-477f-bd39-39df0f548b3d', '10803c1f-112e-475e-a475-8bca2aa2c3eb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9b7fa90b-5451-4760-9cb9-1957e4815bd1', 'ab75e45c-9ad4-4403-a29b-b283b871f220', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9b7fa90b-5451-4760-9cb9-1957e4815bd1', 'd88cbc75-423c-4834-8a66-5e0bb25d2b18', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9b7fa90b-5451-4760-9cb9-1957e4815bd1', '024c8227-9978-477f-bd39-39df0f548b3d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9b7fa90b-5451-4760-9cb9-1957e4815bd1', '122aa21b-d029-4746-9fda-fe0bbe77e9e1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9b7fa90b-5451-4760-9cb9-1957e4815bd1', '10803c1f-112e-475e-a475-8bca2aa2c3eb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('122aa21b-d029-4746-9fda-fe0bbe77e9e1', 'ab75e45c-9ad4-4403-a29b-b283b871f220', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('122aa21b-d029-4746-9fda-fe0bbe77e9e1', 'd88cbc75-423c-4834-8a66-5e0bb25d2b18', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('122aa21b-d029-4746-9fda-fe0bbe77e9e1', '024c8227-9978-477f-bd39-39df0f548b3d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('122aa21b-d029-4746-9fda-fe0bbe77e9e1', '9b7fa90b-5451-4760-9cb9-1957e4815bd1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('122aa21b-d029-4746-9fda-fe0bbe77e9e1', '10803c1f-112e-475e-a475-8bca2aa2c3eb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('10803c1f-112e-475e-a475-8bca2aa2c3eb', 'ab75e45c-9ad4-4403-a29b-b283b871f220', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('10803c1f-112e-475e-a475-8bca2aa2c3eb', 'd88cbc75-423c-4834-8a66-5e0bb25d2b18', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('10803c1f-112e-475e-a475-8bca2aa2c3eb', '024c8227-9978-477f-bd39-39df0f548b3d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('10803c1f-112e-475e-a475-8bca2aa2c3eb', '9b7fa90b-5451-4760-9cb9-1957e4815bd1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('10803c1f-112e-475e-a475-8bca2aa2c3eb', '122aa21b-d029-4746-9fda-fe0bbe77e9e1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eaf20c90-97ea-4b0a-b8d7-b28025fef140', 'ab75e45c-9ad4-4403-a29b-b283b871f220', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eaf20c90-97ea-4b0a-b8d7-b28025fef140', 'd88cbc75-423c-4834-8a66-5e0bb25d2b18', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eaf20c90-97ea-4b0a-b8d7-b28025fef140', '024c8227-9978-477f-bd39-39df0f548b3d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eaf20c90-97ea-4b0a-b8d7-b28025fef140', '9b7fa90b-5451-4760-9cb9-1957e4815bd1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eaf20c90-97ea-4b0a-b8d7-b28025fef140', '122aa21b-d029-4746-9fda-fe0bbe77e9e1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c92ccd93-a8da-4a9e-b7e5-ca37d926f6e9', 'ab75e45c-9ad4-4403-a29b-b283b871f220', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c92ccd93-a8da-4a9e-b7e5-ca37d926f6e9', 'd88cbc75-423c-4834-8a66-5e0bb25d2b18', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c92ccd93-a8da-4a9e-b7e5-ca37d926f6e9', '024c8227-9978-477f-bd39-39df0f548b3d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c92ccd93-a8da-4a9e-b7e5-ca37d926f6e9', '9b7fa90b-5451-4760-9cb9-1957e4815bd1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c92ccd93-a8da-4a9e-b7e5-ca37d926f6e9', '122aa21b-d029-4746-9fda-fe0bbe77e9e1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('217fc056-6ff8-40d8-8517-4eefccd5204c', 'ab75e45c-9ad4-4403-a29b-b283b871f220', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('217fc056-6ff8-40d8-8517-4eefccd5204c', 'd88cbc75-423c-4834-8a66-5e0bb25d2b18', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('217fc056-6ff8-40d8-8517-4eefccd5204c', '024c8227-9978-477f-bd39-39df0f548b3d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('217fc056-6ff8-40d8-8517-4eefccd5204c', '9b7fa90b-5451-4760-9cb9-1957e4815bd1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('217fc056-6ff8-40d8-8517-4eefccd5204c', '122aa21b-d029-4746-9fda-fe0bbe77e9e1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22ae4393-6ecc-427a-90af-7f5386e00cf1', 'ab75e45c-9ad4-4403-a29b-b283b871f220', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22ae4393-6ecc-427a-90af-7f5386e00cf1', 'd88cbc75-423c-4834-8a66-5e0bb25d2b18', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22ae4393-6ecc-427a-90af-7f5386e00cf1', '024c8227-9978-477f-bd39-39df0f548b3d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22ae4393-6ecc-427a-90af-7f5386e00cf1', '9b7fa90b-5451-4760-9cb9-1957e4815bd1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22ae4393-6ecc-427a-90af-7f5386e00cf1', '122aa21b-d029-4746-9fda-fe0bbe77e9e1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0456aaef-2f7c-42f5-8b39-c2834beb005a', '606db03b-e3b1-45f7-a784-9a82339db1f9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0456aaef-2f7c-42f5-8b39-c2834beb005a', '78315b43-ff71-46a9-a3d8-83d5465d6082', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0456aaef-2f7c-42f5-8b39-c2834beb005a', '9d2a6f31-3327-4e2b-adcb-bdcdeaa322e4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0456aaef-2f7c-42f5-8b39-c2834beb005a', 'ab75e45c-9ad4-4403-a29b-b283b871f220', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0456aaef-2f7c-42f5-8b39-c2834beb005a', 'd88cbc75-423c-4834-8a66-5e0bb25d2b18', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('09ae539d-a0a4-46b4-88e2-b69c9502cfa0', '3aee9da8-2063-46c7-b251-031f9f4c7ed2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('09ae539d-a0a4-46b4-88e2-b69c9502cfa0', '12acd498-d1bd-49b7-a9e8-e78bfe3bc026', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('09ae539d-a0a4-46b4-88e2-b69c9502cfa0', 'cd304860-50c6-493f-9152-23c7902a0215', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('09ae539d-a0a4-46b4-88e2-b69c9502cfa0', 'fc07a96c-111e-4b52-877f-3948b4ee1a24', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('09ae539d-a0a4-46b4-88e2-b69c9502cfa0', 'b2f695d5-d356-432e-ba3e-17d078fc59b3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3aee9da8-2063-46c7-b251-031f9f4c7ed2', '09ae539d-a0a4-46b4-88e2-b69c9502cfa0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3aee9da8-2063-46c7-b251-031f9f4c7ed2', '12acd498-d1bd-49b7-a9e8-e78bfe3bc026', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3aee9da8-2063-46c7-b251-031f9f4c7ed2', 'cd304860-50c6-493f-9152-23c7902a0215', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3aee9da8-2063-46c7-b251-031f9f4c7ed2', 'fc07a96c-111e-4b52-877f-3948b4ee1a24', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3aee9da8-2063-46c7-b251-031f9f4c7ed2', 'b2f695d5-d356-432e-ba3e-17d078fc59b3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('15932d3a-4879-41e5-bfd5-e67ae177adf0', '3aee9da8-2063-46c7-b251-031f9f4c7ed2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('15932d3a-4879-41e5-bfd5-e67ae177adf0', '09ae539d-a0a4-46b4-88e2-b69c9502cfa0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('15932d3a-4879-41e5-bfd5-e67ae177adf0', '12acd498-d1bd-49b7-a9e8-e78bfe3bc026', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('15932d3a-4879-41e5-bfd5-e67ae177adf0', 'cd304860-50c6-493f-9152-23c7902a0215', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('15932d3a-4879-41e5-bfd5-e67ae177adf0', 'fc07a96c-111e-4b52-877f-3948b4ee1a24', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('12acd498-d1bd-49b7-a9e8-e78bfe3bc026', 'd6d59492-ca51-4e59-bfe2-e0c50a828bd6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('12acd498-d1bd-49b7-a9e8-e78bfe3bc026', '2d69a8fb-bfd2-4dab-90bc-a25c9c73a686', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('12acd498-d1bd-49b7-a9e8-e78bfe3bc026', 'e731a7e0-894d-4c6f-92a0-cdb932e7fc30', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('12acd498-d1bd-49b7-a9e8-e78bfe3bc026', '09ae539d-a0a4-46b4-88e2-b69c9502cfa0', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('12acd498-d1bd-49b7-a9e8-e78bfe3bc026', '3aee9da8-2063-46c7-b251-031f9f4c7ed2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd304860-50c6-493f-9152-23c7902a0215', 'fc07a96c-111e-4b52-877f-3948b4ee1a24', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd304860-50c6-493f-9152-23c7902a0215', 'b2f695d5-d356-432e-ba3e-17d078fc59b3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd304860-50c6-493f-9152-23c7902a0215', 'e98f806c-9d1e-4691-8ddf-cf28a6d09bc3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd304860-50c6-493f-9152-23c7902a0215', 'f67bca3a-0c30-4c88-969f-b8121a6ec8b8', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd304860-50c6-493f-9152-23c7902a0215', '09ae539d-a0a4-46b4-88e2-b69c9502cfa0', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc07a96c-111e-4b52-877f-3948b4ee1a24', 'cd304860-50c6-493f-9152-23c7902a0215', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc07a96c-111e-4b52-877f-3948b4ee1a24', 'b2f695d5-d356-432e-ba3e-17d078fc59b3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc07a96c-111e-4b52-877f-3948b4ee1a24', 'e98f806c-9d1e-4691-8ddf-cf28a6d09bc3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc07a96c-111e-4b52-877f-3948b4ee1a24', 'f67bca3a-0c30-4c88-969f-b8121a6ec8b8', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc07a96c-111e-4b52-877f-3948b4ee1a24', '09ae539d-a0a4-46b4-88e2-b69c9502cfa0', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b2f695d5-d356-432e-ba3e-17d078fc59b3', 'cd304860-50c6-493f-9152-23c7902a0215', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b2f695d5-d356-432e-ba3e-17d078fc59b3', 'fc07a96c-111e-4b52-877f-3948b4ee1a24', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b2f695d5-d356-432e-ba3e-17d078fc59b3', 'e98f806c-9d1e-4691-8ddf-cf28a6d09bc3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b2f695d5-d356-432e-ba3e-17d078fc59b3', 'f67bca3a-0c30-4c88-969f-b8121a6ec8b8', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b2f695d5-d356-432e-ba3e-17d078fc59b3', '09ae539d-a0a4-46b4-88e2-b69c9502cfa0', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d6d59492-ca51-4e59-bfe2-e0c50a828bd6', '12acd498-d1bd-49b7-a9e8-e78bfe3bc026', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d6d59492-ca51-4e59-bfe2-e0c50a828bd6', '2d69a8fb-bfd2-4dab-90bc-a25c9c73a686', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d6d59492-ca51-4e59-bfe2-e0c50a828bd6', 'e731a7e0-894d-4c6f-92a0-cdb932e7fc30', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d6d59492-ca51-4e59-bfe2-e0c50a828bd6', '09ae539d-a0a4-46b4-88e2-b69c9502cfa0', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d6d59492-ca51-4e59-bfe2-e0c50a828bd6', '3aee9da8-2063-46c7-b251-031f9f4c7ed2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d69a8fb-bfd2-4dab-90bc-a25c9c73a686', '12acd498-d1bd-49b7-a9e8-e78bfe3bc026', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d69a8fb-bfd2-4dab-90bc-a25c9c73a686', 'd6d59492-ca51-4e59-bfe2-e0c50a828bd6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d69a8fb-bfd2-4dab-90bc-a25c9c73a686', 'e731a7e0-894d-4c6f-92a0-cdb932e7fc30', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d69a8fb-bfd2-4dab-90bc-a25c9c73a686', '09ae539d-a0a4-46b4-88e2-b69c9502cfa0', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d69a8fb-bfd2-4dab-90bc-a25c9c73a686', '3aee9da8-2063-46c7-b251-031f9f4c7ed2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e98f806c-9d1e-4691-8ddf-cf28a6d09bc3', 'cd304860-50c6-493f-9152-23c7902a0215', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e98f806c-9d1e-4691-8ddf-cf28a6d09bc3', 'fc07a96c-111e-4b52-877f-3948b4ee1a24', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e98f806c-9d1e-4691-8ddf-cf28a6d09bc3', 'b2f695d5-d356-432e-ba3e-17d078fc59b3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e98f806c-9d1e-4691-8ddf-cf28a6d09bc3', 'f67bca3a-0c30-4c88-969f-b8121a6ec8b8', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e98f806c-9d1e-4691-8ddf-cf28a6d09bc3', '09ae539d-a0a4-46b4-88e2-b69c9502cfa0', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f67bca3a-0c30-4c88-969f-b8121a6ec8b8', 'cd304860-50c6-493f-9152-23c7902a0215', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f67bca3a-0c30-4c88-969f-b8121a6ec8b8', 'fc07a96c-111e-4b52-877f-3948b4ee1a24', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f67bca3a-0c30-4c88-969f-b8121a6ec8b8', 'b2f695d5-d356-432e-ba3e-17d078fc59b3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f67bca3a-0c30-4c88-969f-b8121a6ec8b8', 'e98f806c-9d1e-4691-8ddf-cf28a6d09bc3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f67bca3a-0c30-4c88-969f-b8121a6ec8b8', '09ae539d-a0a4-46b4-88e2-b69c9502cfa0', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e731a7e0-894d-4c6f-92a0-cdb932e7fc30', '12acd498-d1bd-49b7-a9e8-e78bfe3bc026', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e731a7e0-894d-4c6f-92a0-cdb932e7fc30', 'd6d59492-ca51-4e59-bfe2-e0c50a828bd6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e731a7e0-894d-4c6f-92a0-cdb932e7fc30', '2d69a8fb-bfd2-4dab-90bc-a25c9c73a686', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e731a7e0-894d-4c6f-92a0-cdb932e7fc30', '09ae539d-a0a4-46b4-88e2-b69c9502cfa0', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e731a7e0-894d-4c6f-92a0-cdb932e7fc30', '3aee9da8-2063-46c7-b251-031f9f4c7ed2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('151d6ef7-88f1-4def-8e43-a3bc7bc570a8', 'ab75e45c-9ad4-4403-a29b-b283b871f220', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('151d6ef7-88f1-4def-8e43-a3bc7bc570a8', 'd88cbc75-423c-4834-8a66-5e0bb25d2b18', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('151d6ef7-88f1-4def-8e43-a3bc7bc570a8', '024c8227-9978-477f-bd39-39df0f548b3d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('151d6ef7-88f1-4def-8e43-a3bc7bc570a8', '9b7fa90b-5451-4760-9cb9-1957e4815bd1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('151d6ef7-88f1-4def-8e43-a3bc7bc570a8', '122aa21b-d029-4746-9fda-fe0bbe77e9e1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6753ed9-3740-44d5-b104-3ce908a4bdf6', '606db03b-e3b1-45f7-a784-9a82339db1f9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6753ed9-3740-44d5-b104-3ce908a4bdf6', '78315b43-ff71-46a9-a3d8-83d5465d6082', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6753ed9-3740-44d5-b104-3ce908a4bdf6', '9d2a6f31-3327-4e2b-adcb-bdcdeaa322e4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7dd8d298-93cb-4103-8639-9cb314bbd2ae', 'a9c2e519-ba59-411a-90c0-4f29a0c2034c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7dd8d298-93cb-4103-8639-9cb314bbd2ae', '61ab3793-98f3-4fec-ab57-dd8623f67435', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7dd8d298-93cb-4103-8639-9cb314bbd2ae', 'a78f9e5b-1120-46b9-a5b6-6a4e513cdb1c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a9c2e519-ba59-411a-90c0-4f29a0c2034c', '7dd8d298-93cb-4103-8639-9cb314bbd2ae', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a9c2e519-ba59-411a-90c0-4f29a0c2034c', '61ab3793-98f3-4fec-ab57-dd8623f67435', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a9c2e519-ba59-411a-90c0-4f29a0c2034c', 'a78f9e5b-1120-46b9-a5b6-6a4e513cdb1c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('61ab3793-98f3-4fec-ab57-dd8623f67435', '7dd8d298-93cb-4103-8639-9cb314bbd2ae', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('61ab3793-98f3-4fec-ab57-dd8623f67435', 'a9c2e519-ba59-411a-90c0-4f29a0c2034c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('61ab3793-98f3-4fec-ab57-dd8623f67435', 'a78f9e5b-1120-46b9-a5b6-6a4e513cdb1c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a78f9e5b-1120-46b9-a5b6-6a4e513cdb1c', '7dd8d298-93cb-4103-8639-9cb314bbd2ae', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a78f9e5b-1120-46b9-a5b6-6a4e513cdb1c', 'a9c2e519-ba59-411a-90c0-4f29a0c2034c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a78f9e5b-1120-46b9-a5b6-6a4e513cdb1c', '61ab3793-98f3-4fec-ab57-dd8623f67435', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('163cf409-c875-4ab7-86da-63a910a5fa8d', 'aec7aea8-f7d0-4147-b253-dff58b1287af', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('163cf409-c875-4ab7-86da-63a910a5fa8d', '8d215040-b2b6-41a5-99b2-59015909b747', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('163cf409-c875-4ab7-86da-63a910a5fa8d', 'a71e34c9-9ea9-4806-a4a9-1c5fbb1f1acb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('163cf409-c875-4ab7-86da-63a910a5fa8d', '97b897a4-9935-422b-b471-f678165e09a3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('163cf409-c875-4ab7-86da-63a910a5fa8d', '1ad057a8-8844-412f-9bae-ee78095cfe72', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aec7aea8-f7d0-4147-b253-dff58b1287af', '163cf409-c875-4ab7-86da-63a910a5fa8d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aec7aea8-f7d0-4147-b253-dff58b1287af', '8d215040-b2b6-41a5-99b2-59015909b747', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aec7aea8-f7d0-4147-b253-dff58b1287af', 'a71e34c9-9ea9-4806-a4a9-1c5fbb1f1acb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aec7aea8-f7d0-4147-b253-dff58b1287af', '97b897a4-9935-422b-b471-f678165e09a3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aec7aea8-f7d0-4147-b253-dff58b1287af', '1ad057a8-8844-412f-9bae-ee78095cfe72', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d215040-b2b6-41a5-99b2-59015909b747', '163cf409-c875-4ab7-86da-63a910a5fa8d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d215040-b2b6-41a5-99b2-59015909b747', 'aec7aea8-f7d0-4147-b253-dff58b1287af', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d215040-b2b6-41a5-99b2-59015909b747', 'a71e34c9-9ea9-4806-a4a9-1c5fbb1f1acb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d215040-b2b6-41a5-99b2-59015909b747', '97b897a4-9935-422b-b471-f678165e09a3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d215040-b2b6-41a5-99b2-59015909b747', '1ad057a8-8844-412f-9bae-ee78095cfe72', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a71e34c9-9ea9-4806-a4a9-1c5fbb1f1acb', '163cf409-c875-4ab7-86da-63a910a5fa8d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a71e34c9-9ea9-4806-a4a9-1c5fbb1f1acb', 'aec7aea8-f7d0-4147-b253-dff58b1287af', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a71e34c9-9ea9-4806-a4a9-1c5fbb1f1acb', '8d215040-b2b6-41a5-99b2-59015909b747', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a71e34c9-9ea9-4806-a4a9-1c5fbb1f1acb', '97b897a4-9935-422b-b471-f678165e09a3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a71e34c9-9ea9-4806-a4a9-1c5fbb1f1acb', '1ad057a8-8844-412f-9bae-ee78095cfe72', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('de0a31fa-9cac-48d0-9c1f-260949ee08c3', 'b896dd80-3795-4863-9a35-ccf71e923539', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('de0a31fa-9cac-48d0-9c1f-260949ee08c3', '163cf409-c875-4ab7-86da-63a910a5fa8d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('de0a31fa-9cac-48d0-9c1f-260949ee08c3', 'aec7aea8-f7d0-4147-b253-dff58b1287af', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('de0a31fa-9cac-48d0-9c1f-260949ee08c3', '8d215040-b2b6-41a5-99b2-59015909b747', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('de0a31fa-9cac-48d0-9c1f-260949ee08c3', 'a71e34c9-9ea9-4806-a4a9-1c5fbb1f1acb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b896dd80-3795-4863-9a35-ccf71e923539', 'de0a31fa-9cac-48d0-9c1f-260949ee08c3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b896dd80-3795-4863-9a35-ccf71e923539', '163cf409-c875-4ab7-86da-63a910a5fa8d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b896dd80-3795-4863-9a35-ccf71e923539', 'aec7aea8-f7d0-4147-b253-dff58b1287af', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b896dd80-3795-4863-9a35-ccf71e923539', '8d215040-b2b6-41a5-99b2-59015909b747', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b896dd80-3795-4863-9a35-ccf71e923539', 'a71e34c9-9ea9-4806-a4a9-1c5fbb1f1acb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('97b897a4-9935-422b-b471-f678165e09a3', '163cf409-c875-4ab7-86da-63a910a5fa8d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('97b897a4-9935-422b-b471-f678165e09a3', 'aec7aea8-f7d0-4147-b253-dff58b1287af', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('97b897a4-9935-422b-b471-f678165e09a3', '8d215040-b2b6-41a5-99b2-59015909b747', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('97b897a4-9935-422b-b471-f678165e09a3', 'a71e34c9-9ea9-4806-a4a9-1c5fbb1f1acb', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('97b897a4-9935-422b-b471-f678165e09a3', '1ad057a8-8844-412f-9bae-ee78095cfe72', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ad057a8-8844-412f-9bae-ee78095cfe72', '163cf409-c875-4ab7-86da-63a910a5fa8d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ad057a8-8844-412f-9bae-ee78095cfe72', 'aec7aea8-f7d0-4147-b253-dff58b1287af', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ad057a8-8844-412f-9bae-ee78095cfe72', '8d215040-b2b6-41a5-99b2-59015909b747', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ad057a8-8844-412f-9bae-ee78095cfe72', 'a71e34c9-9ea9-4806-a4a9-1c5fbb1f1acb', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ad057a8-8844-412f-9bae-ee78095cfe72', '97b897a4-9935-422b-b471-f678165e09a3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fbee7e30-2fb8-4be8-9910-187ea0eda298', '4c30f212-7155-4a24-8344-82f648ddb11e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fbee7e30-2fb8-4be8-9910-187ea0eda298', '7dd8d298-93cb-4103-8639-9cb314bbd2ae', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fbee7e30-2fb8-4be8-9910-187ea0eda298', 'a9c2e519-ba59-411a-90c0-4f29a0c2034c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9c890ffc-6d1f-4586-b07f-7878fcbe85fb', '163cf409-c875-4ab7-86da-63a910a5fa8d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9c890ffc-6d1f-4586-b07f-7878fcbe85fb', 'aec7aea8-f7d0-4147-b253-dff58b1287af', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9c890ffc-6d1f-4586-b07f-7878fcbe85fb', '8d215040-b2b6-41a5-99b2-59015909b747', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9c890ffc-6d1f-4586-b07f-7878fcbe85fb', 'a71e34c9-9ea9-4806-a4a9-1c5fbb1f1acb', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9c890ffc-6d1f-4586-b07f-7878fcbe85fb', 'de0a31fa-9cac-48d0-9c1f-260949ee08c3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('69638daf-3e3e-4a29-bf4a-49f965b54128', '4c30f212-7155-4a24-8344-82f648ddb11e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('69638daf-3e3e-4a29-bf4a-49f965b54128', '7dd8d298-93cb-4103-8639-9cb314bbd2ae', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('69638daf-3e3e-4a29-bf4a-49f965b54128', 'a9c2e519-ba59-411a-90c0-4f29a0c2034c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('54b7263b-a02d-4dc4-ade6-1f50d8239401', '363eae41-c9f1-4d7f-994a-85cf58365fa1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('54b7263b-a02d-4dc4-ade6-1f50d8239401', 'ac456eb8-c713-4aa6-a021-3cf1a59e2641', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('54b7263b-a02d-4dc4-ade6-1f50d8239401', '8682009e-dfbe-44c3-aa00-6dc19ba5818d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('54b7263b-a02d-4dc4-ade6-1f50d8239401', 'f0d14e59-b7f4-435a-9846-425a8547d463', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('54b7263b-a02d-4dc4-ade6-1f50d8239401', '22cd5faf-1ac9-46bf-95a3-15350093d1e6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cf8a66c3-bb82-43d3-a5f1-b586a46acbad', '52de045c-dabd-4656-9442-191bbaa44d95', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cf8a66c3-bb82-43d3-a5f1-b586a46acbad', '54b7263b-a02d-4dc4-ade6-1f50d8239401', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cf8a66c3-bb82-43d3-a5f1-b586a46acbad', '363eae41-c9f1-4d7f-994a-85cf58365fa1', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cf8a66c3-bb82-43d3-a5f1-b586a46acbad', 'ac456eb8-c713-4aa6-a021-3cf1a59e2641', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cf8a66c3-bb82-43d3-a5f1-b586a46acbad', '8682009e-dfbe-44c3-aa00-6dc19ba5818d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('363eae41-c9f1-4d7f-994a-85cf58365fa1', '54b7263b-a02d-4dc4-ade6-1f50d8239401', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('363eae41-c9f1-4d7f-994a-85cf58365fa1', 'ac456eb8-c713-4aa6-a021-3cf1a59e2641', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('363eae41-c9f1-4d7f-994a-85cf58365fa1', '8682009e-dfbe-44c3-aa00-6dc19ba5818d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('363eae41-c9f1-4d7f-994a-85cf58365fa1', 'f0d14e59-b7f4-435a-9846-425a8547d463', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('363eae41-c9f1-4d7f-994a-85cf58365fa1', '22cd5faf-1ac9-46bf-95a3-15350093d1e6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ac456eb8-c713-4aa6-a021-3cf1a59e2641', '54b7263b-a02d-4dc4-ade6-1f50d8239401', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ac456eb8-c713-4aa6-a021-3cf1a59e2641', '363eae41-c9f1-4d7f-994a-85cf58365fa1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ac456eb8-c713-4aa6-a021-3cf1a59e2641', '8682009e-dfbe-44c3-aa00-6dc19ba5818d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ac456eb8-c713-4aa6-a021-3cf1a59e2641', 'f0d14e59-b7f4-435a-9846-425a8547d463', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ac456eb8-c713-4aa6-a021-3cf1a59e2641', '22cd5faf-1ac9-46bf-95a3-15350093d1e6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8682009e-dfbe-44c3-aa00-6dc19ba5818d', '54b7263b-a02d-4dc4-ade6-1f50d8239401', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8682009e-dfbe-44c3-aa00-6dc19ba5818d', '363eae41-c9f1-4d7f-994a-85cf58365fa1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8682009e-dfbe-44c3-aa00-6dc19ba5818d', 'ac456eb8-c713-4aa6-a021-3cf1a59e2641', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8682009e-dfbe-44c3-aa00-6dc19ba5818d', 'f0d14e59-b7f4-435a-9846-425a8547d463', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8682009e-dfbe-44c3-aa00-6dc19ba5818d', '22cd5faf-1ac9-46bf-95a3-15350093d1e6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0d14e59-b7f4-435a-9846-425a8547d463', '54b7263b-a02d-4dc4-ade6-1f50d8239401', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0d14e59-b7f4-435a-9846-425a8547d463', '363eae41-c9f1-4d7f-994a-85cf58365fa1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0d14e59-b7f4-435a-9846-425a8547d463', 'ac456eb8-c713-4aa6-a021-3cf1a59e2641', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0d14e59-b7f4-435a-9846-425a8547d463', '8682009e-dfbe-44c3-aa00-6dc19ba5818d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0d14e59-b7f4-435a-9846-425a8547d463', '22cd5faf-1ac9-46bf-95a3-15350093d1e6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22cd5faf-1ac9-46bf-95a3-15350093d1e6', '54b7263b-a02d-4dc4-ade6-1f50d8239401', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22cd5faf-1ac9-46bf-95a3-15350093d1e6', '363eae41-c9f1-4d7f-994a-85cf58365fa1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22cd5faf-1ac9-46bf-95a3-15350093d1e6', 'ac456eb8-c713-4aa6-a021-3cf1a59e2641', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22cd5faf-1ac9-46bf-95a3-15350093d1e6', '8682009e-dfbe-44c3-aa00-6dc19ba5818d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22cd5faf-1ac9-46bf-95a3-15350093d1e6', 'f0d14e59-b7f4-435a-9846-425a8547d463', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3dbd9cc-c642-4a6b-9a76-79f6f7583dae', '0b584626-4378-41ee-9e5e-86bedb4adda8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3dbd9cc-c642-4a6b-9a76-79f6f7583dae', '54b7263b-a02d-4dc4-ade6-1f50d8239401', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3dbd9cc-c642-4a6b-9a76-79f6f7583dae', 'cf8a66c3-bb82-43d3-a5f1-b586a46acbad', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3dbd9cc-c642-4a6b-9a76-79f6f7583dae', '363eae41-c9f1-4d7f-994a-85cf58365fa1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3dbd9cc-c642-4a6b-9a76-79f6f7583dae', 'ac456eb8-c713-4aa6-a021-3cf1a59e2641', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0b584626-4378-41ee-9e5e-86bedb4adda8', 'e3dbd9cc-c642-4a6b-9a76-79f6f7583dae', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0b584626-4378-41ee-9e5e-86bedb4adda8', '54b7263b-a02d-4dc4-ade6-1f50d8239401', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0b584626-4378-41ee-9e5e-86bedb4adda8', 'cf8a66c3-bb82-43d3-a5f1-b586a46acbad', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0b584626-4378-41ee-9e5e-86bedb4adda8', '363eae41-c9f1-4d7f-994a-85cf58365fa1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0b584626-4378-41ee-9e5e-86bedb4adda8', 'ac456eb8-c713-4aa6-a021-3cf1a59e2641', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('766fe4e1-5d7d-4d2a-95bb-2362e876868b', '54b7263b-a02d-4dc4-ade6-1f50d8239401', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('766fe4e1-5d7d-4d2a-95bb-2362e876868b', '363eae41-c9f1-4d7f-994a-85cf58365fa1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('766fe4e1-5d7d-4d2a-95bb-2362e876868b', 'ac456eb8-c713-4aa6-a021-3cf1a59e2641', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('766fe4e1-5d7d-4d2a-95bb-2362e876868b', '8682009e-dfbe-44c3-aa00-6dc19ba5818d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('766fe4e1-5d7d-4d2a-95bb-2362e876868b', 'f0d14e59-b7f4-435a-9846-425a8547d463', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('88c61fdd-579b-49e2-b564-ad6c155977bc', '54b7263b-a02d-4dc4-ade6-1f50d8239401', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('88c61fdd-579b-49e2-b564-ad6c155977bc', '363eae41-c9f1-4d7f-994a-85cf58365fa1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('88c61fdd-579b-49e2-b564-ad6c155977bc', 'ac456eb8-c713-4aa6-a021-3cf1a59e2641', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('88c61fdd-579b-49e2-b564-ad6c155977bc', '8682009e-dfbe-44c3-aa00-6dc19ba5818d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('88c61fdd-579b-49e2-b564-ad6c155977bc', 'f0d14e59-b7f4-435a-9846-425a8547d463', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('52de045c-dabd-4656-9442-191bbaa44d95', 'cf8a66c3-bb82-43d3-a5f1-b586a46acbad', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('52de045c-dabd-4656-9442-191bbaa44d95', '54b7263b-a02d-4dc4-ade6-1f50d8239401', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('52de045c-dabd-4656-9442-191bbaa44d95', '363eae41-c9f1-4d7f-994a-85cf58365fa1', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('52de045c-dabd-4656-9442-191bbaa44d95', 'ac456eb8-c713-4aa6-a021-3cf1a59e2641', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('52de045c-dabd-4656-9442-191bbaa44d95', '8682009e-dfbe-44c3-aa00-6dc19ba5818d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1dde3b33-636f-4de3-b1be-6caae052fdab', '54b7263b-a02d-4dc4-ade6-1f50d8239401', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1dde3b33-636f-4de3-b1be-6caae052fdab', '363eae41-c9f1-4d7f-994a-85cf58365fa1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1dde3b33-636f-4de3-b1be-6caae052fdab', 'ac456eb8-c713-4aa6-a021-3cf1a59e2641', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1dde3b33-636f-4de3-b1be-6caae052fdab', '8682009e-dfbe-44c3-aa00-6dc19ba5818d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1dde3b33-636f-4de3-b1be-6caae052fdab', 'f0d14e59-b7f4-435a-9846-425a8547d463', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f2073c55-bf68-49f0-bfd8-2e8a27ace174', '8d170d72-0251-4280-b8a9-001f5b4496e9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f2073c55-bf68-49f0-bfd8-2e8a27ace174', '39018b55-4140-43a9-a50a-58dd3981929b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f2073c55-bf68-49f0-bfd8-2e8a27ace174', '669707ba-42df-484c-a91a-36c119c6a5bd', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f2073c55-bf68-49f0-bfd8-2e8a27ace174', '940c4719-306a-4216-b6d7-08a6e8853bcb', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f2073c55-bf68-49f0-bfd8-2e8a27ace174', '5c83d34b-453f-4c6b-b87d-e316ee332412', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39018b55-4140-43a9-a50a-58dd3981929b', 'f2073c55-bf68-49f0-bfd8-2e8a27ace174', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39018b55-4140-43a9-a50a-58dd3981929b', '669707ba-42df-484c-a91a-36c119c6a5bd', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39018b55-4140-43a9-a50a-58dd3981929b', '940c4719-306a-4216-b6d7-08a6e8853bcb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39018b55-4140-43a9-a50a-58dd3981929b', '5c83d34b-453f-4c6b-b87d-e316ee332412', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39018b55-4140-43a9-a50a-58dd3981929b', '02c0b17c-8bed-47bd-a8a6-b93142ce8814', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('669707ba-42df-484c-a91a-36c119c6a5bd', 'f2073c55-bf68-49f0-bfd8-2e8a27ace174', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('669707ba-42df-484c-a91a-36c119c6a5bd', '39018b55-4140-43a9-a50a-58dd3981929b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('669707ba-42df-484c-a91a-36c119c6a5bd', '940c4719-306a-4216-b6d7-08a6e8853bcb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('669707ba-42df-484c-a91a-36c119c6a5bd', '5c83d34b-453f-4c6b-b87d-e316ee332412', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('669707ba-42df-484c-a91a-36c119c6a5bd', '02c0b17c-8bed-47bd-a8a6-b93142ce8814', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('940c4719-306a-4216-b6d7-08a6e8853bcb', '5c83d34b-453f-4c6b-b87d-e316ee332412', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('940c4719-306a-4216-b6d7-08a6e8853bcb', '02c0b17c-8bed-47bd-a8a6-b93142ce8814', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('940c4719-306a-4216-b6d7-08a6e8853bcb', '53a745eb-2441-476e-9b5a-cccaf37c5806', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('940c4719-306a-4216-b6d7-08a6e8853bcb', 'f2073c55-bf68-49f0-bfd8-2e8a27ace174', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('940c4719-306a-4216-b6d7-08a6e8853bcb', '39018b55-4140-43a9-a50a-58dd3981929b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5c83d34b-453f-4c6b-b87d-e316ee332412', '940c4719-306a-4216-b6d7-08a6e8853bcb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5c83d34b-453f-4c6b-b87d-e316ee332412', '02c0b17c-8bed-47bd-a8a6-b93142ce8814', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5c83d34b-453f-4c6b-b87d-e316ee332412', '53a745eb-2441-476e-9b5a-cccaf37c5806', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5c83d34b-453f-4c6b-b87d-e316ee332412', 'f2073c55-bf68-49f0-bfd8-2e8a27ace174', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5c83d34b-453f-4c6b-b87d-e316ee332412', '39018b55-4140-43a9-a50a-58dd3981929b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02c0b17c-8bed-47bd-a8a6-b93142ce8814', '940c4719-306a-4216-b6d7-08a6e8853bcb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02c0b17c-8bed-47bd-a8a6-b93142ce8814', '5c83d34b-453f-4c6b-b87d-e316ee332412', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02c0b17c-8bed-47bd-a8a6-b93142ce8814', '53a745eb-2441-476e-9b5a-cccaf37c5806', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02c0b17c-8bed-47bd-a8a6-b93142ce8814', 'f2073c55-bf68-49f0-bfd8-2e8a27ace174', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02c0b17c-8bed-47bd-a8a6-b93142ce8814', '39018b55-4140-43a9-a50a-58dd3981929b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('53a745eb-2441-476e-9b5a-cccaf37c5806', '940c4719-306a-4216-b6d7-08a6e8853bcb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('53a745eb-2441-476e-9b5a-cccaf37c5806', '5c83d34b-453f-4c6b-b87d-e316ee332412', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('53a745eb-2441-476e-9b5a-cccaf37c5806', '02c0b17c-8bed-47bd-a8a6-b93142ce8814', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('53a745eb-2441-476e-9b5a-cccaf37c5806', 'f2073c55-bf68-49f0-bfd8-2e8a27ace174', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('53a745eb-2441-476e-9b5a-cccaf37c5806', '39018b55-4140-43a9-a50a-58dd3981929b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d170d72-0251-4280-b8a9-001f5b4496e9', 'f2073c55-bf68-49f0-bfd8-2e8a27ace174', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d170d72-0251-4280-b8a9-001f5b4496e9', '39018b55-4140-43a9-a50a-58dd3981929b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d170d72-0251-4280-b8a9-001f5b4496e9', '669707ba-42df-484c-a91a-36c119c6a5bd', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d170d72-0251-4280-b8a9-001f5b4496e9', '940c4719-306a-4216-b6d7-08a6e8853bcb', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d170d72-0251-4280-b8a9-001f5b4496e9', '5c83d34b-453f-4c6b-b87d-e316ee332412', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3e2179d6-88d8-4b55-a3c3-d9788d908c0c', 'f2073c55-bf68-49f0-bfd8-2e8a27ace174', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3e2179d6-88d8-4b55-a3c3-d9788d908c0c', '39018b55-4140-43a9-a50a-58dd3981929b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3e2179d6-88d8-4b55-a3c3-d9788d908c0c', '669707ba-42df-484c-a91a-36c119c6a5bd', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('caf5df70-275b-42b3-b271-9d7825d2a174', 'f2073c55-bf68-49f0-bfd8-2e8a27ace174', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('caf5df70-275b-42b3-b271-9d7825d2a174', '39018b55-4140-43a9-a50a-58dd3981929b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('caf5df70-275b-42b3-b271-9d7825d2a174', '669707ba-42df-484c-a91a-36c119c6a5bd', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('caf5df70-275b-42b3-b271-9d7825d2a174', '940c4719-306a-4216-b6d7-08a6e8853bcb', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('caf5df70-275b-42b3-b271-9d7825d2a174', '5c83d34b-453f-4c6b-b87d-e316ee332412', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('83a50612-e015-43dd-862c-b6211ce5b0f0', '039137cb-4a18-4069-8355-20123e8bc6ac', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('83a50612-e015-43dd-862c-b6211ce5b0f0', '8a1365d9-52f8-4e4f-9c87-10de343653cd', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('83a50612-e015-43dd-862c-b6211ce5b0f0', 'a1bdfd0c-3801-484e-bf7e-fbd5e446181c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('83a50612-e015-43dd-862c-b6211ce5b0f0', '3dd2b0c1-9fce-4c3d-9989-9c9f7be81351', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('83a50612-e015-43dd-862c-b6211ce5b0f0', '1c79d482-7ea0-470b-9019-b31787f0d120', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('78fc560d-bcc5-42b0-90cd-2b27dc224349', '83a50612-e015-43dd-862c-b6211ce5b0f0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('78fc560d-bcc5-42b0-90cd-2b27dc224349', '039137cb-4a18-4069-8355-20123e8bc6ac', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('78fc560d-bcc5-42b0-90cd-2b27dc224349', '8a1365d9-52f8-4e4f-9c87-10de343653cd', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('78fc560d-bcc5-42b0-90cd-2b27dc224349', 'a1bdfd0c-3801-484e-bf7e-fbd5e446181c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('78fc560d-bcc5-42b0-90cd-2b27dc224349', '3dd2b0c1-9fce-4c3d-9989-9c9f7be81351', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('039137cb-4a18-4069-8355-20123e8bc6ac', '83a50612-e015-43dd-862c-b6211ce5b0f0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('039137cb-4a18-4069-8355-20123e8bc6ac', '8a1365d9-52f8-4e4f-9c87-10de343653cd', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('039137cb-4a18-4069-8355-20123e8bc6ac', 'a1bdfd0c-3801-484e-bf7e-fbd5e446181c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('039137cb-4a18-4069-8355-20123e8bc6ac', '3dd2b0c1-9fce-4c3d-9989-9c9f7be81351', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('039137cb-4a18-4069-8355-20123e8bc6ac', '1c79d482-7ea0-470b-9019-b31787f0d120', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a1bdfd0c-3801-484e-bf7e-fbd5e446181c', '83a50612-e015-43dd-862c-b6211ce5b0f0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a1bdfd0c-3801-484e-bf7e-fbd5e446181c', '039137cb-4a18-4069-8355-20123e8bc6ac', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a1bdfd0c-3801-484e-bf7e-fbd5e446181c', '3dd2b0c1-9fce-4c3d-9989-9c9f7be81351', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a1bdfd0c-3801-484e-bf7e-fbd5e446181c', '8a1365d9-52f8-4e4f-9c87-10de343653cd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a1bdfd0c-3801-484e-bf7e-fbd5e446181c', '1c79d482-7ea0-470b-9019-b31787f0d120', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3dd2b0c1-9fce-4c3d-9989-9c9f7be81351', '83a50612-e015-43dd-862c-b6211ce5b0f0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3dd2b0c1-9fce-4c3d-9989-9c9f7be81351', '039137cb-4a18-4069-8355-20123e8bc6ac', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3dd2b0c1-9fce-4c3d-9989-9c9f7be81351', 'a1bdfd0c-3801-484e-bf7e-fbd5e446181c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3dd2b0c1-9fce-4c3d-9989-9c9f7be81351', '8a1365d9-52f8-4e4f-9c87-10de343653cd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3dd2b0c1-9fce-4c3d-9989-9c9f7be81351', '1c79d482-7ea0-470b-9019-b31787f0d120', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('932d879d-154a-4147-9443-44dff5589209', '83a50612-e015-43dd-862c-b6211ce5b0f0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('932d879d-154a-4147-9443-44dff5589209', '039137cb-4a18-4069-8355-20123e8bc6ac', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('932d879d-154a-4147-9443-44dff5589209', 'a1bdfd0c-3801-484e-bf7e-fbd5e446181c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('559e96e2-16c1-4c7d-aa5e-d10fab29811c', '83a50612-e015-43dd-862c-b6211ce5b0f0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('559e96e2-16c1-4c7d-aa5e-d10fab29811c', '039137cb-4a18-4069-8355-20123e8bc6ac', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('559e96e2-16c1-4c7d-aa5e-d10fab29811c', 'a1bdfd0c-3801-484e-bf7e-fbd5e446181c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('660c2086-60d8-4fd5-bb07-19226c61a57a', '15b2432e-b182-4649-90a5-1a2c0b3804b5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('660c2086-60d8-4fd5-bb07-19226c61a57a', 'da1dd5f9-ffd4-412e-b42a-edf93bac10ef', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('660c2086-60d8-4fd5-bb07-19226c61a57a', 'c5117bfe-c1a0-41e1-bec9-eee35af44da0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('660c2086-60d8-4fd5-bb07-19226c61a57a', 'e90c1e17-364e-4527-984f-d73666781035', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('660c2086-60d8-4fd5-bb07-19226c61a57a', 'b061486d-5129-4bde-9988-e80aa579ffee', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c5117bfe-c1a0-41e1-bec9-eee35af44da0', 'b061486d-5129-4bde-9988-e80aa579ffee', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c5117bfe-c1a0-41e1-bec9-eee35af44da0', '660c2086-60d8-4fd5-bb07-19226c61a57a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c5117bfe-c1a0-41e1-bec9-eee35af44da0', '15b2432e-b182-4649-90a5-1a2c0b3804b5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c5117bfe-c1a0-41e1-bec9-eee35af44da0', 'e90c1e17-364e-4527-984f-d73666781035', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c5117bfe-c1a0-41e1-bec9-eee35af44da0', 'da1dd5f9-ffd4-412e-b42a-edf93bac10ef', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('15b2432e-b182-4649-90a5-1a2c0b3804b5', '660c2086-60d8-4fd5-bb07-19226c61a57a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('15b2432e-b182-4649-90a5-1a2c0b3804b5', 'da1dd5f9-ffd4-412e-b42a-edf93bac10ef', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('15b2432e-b182-4649-90a5-1a2c0b3804b5', 'c5117bfe-c1a0-41e1-bec9-eee35af44da0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('15b2432e-b182-4649-90a5-1a2c0b3804b5', 'e90c1e17-364e-4527-984f-d73666781035', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('15b2432e-b182-4649-90a5-1a2c0b3804b5', 'b061486d-5129-4bde-9988-e80aa579ffee', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e90c1e17-364e-4527-984f-d73666781035', '660c2086-60d8-4fd5-bb07-19226c61a57a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e90c1e17-364e-4527-984f-d73666781035', 'c5117bfe-c1a0-41e1-bec9-eee35af44da0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e90c1e17-364e-4527-984f-d73666781035', '15b2432e-b182-4649-90a5-1a2c0b3804b5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e90c1e17-364e-4527-984f-d73666781035', 'b061486d-5129-4bde-9988-e80aa579ffee', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e90c1e17-364e-4527-984f-d73666781035', 'da1dd5f9-ffd4-412e-b42a-edf93bac10ef', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b061486d-5129-4bde-9988-e80aa579ffee', 'c5117bfe-c1a0-41e1-bec9-eee35af44da0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b061486d-5129-4bde-9988-e80aa579ffee', '660c2086-60d8-4fd5-bb07-19226c61a57a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b061486d-5129-4bde-9988-e80aa579ffee', '15b2432e-b182-4649-90a5-1a2c0b3804b5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b061486d-5129-4bde-9988-e80aa579ffee', 'e90c1e17-364e-4527-984f-d73666781035', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b061486d-5129-4bde-9988-e80aa579ffee', 'da1dd5f9-ffd4-412e-b42a-edf93bac10ef', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7fb741ea-f335-4a99-a5a3-a87c6cca7513', '53322d30-83cc-4ed4-86f9-fcdf9a77dcbf', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7fb741ea-f335-4a99-a5a3-a87c6cca7513', '83a50612-e015-43dd-862c-b6211ce5b0f0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7fb741ea-f335-4a99-a5a3-a87c6cca7513', '039137cb-4a18-4069-8355-20123e8bc6ac', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8a1365d9-52f8-4e4f-9c87-10de343653cd', '83a50612-e015-43dd-862c-b6211ce5b0f0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8a1365d9-52f8-4e4f-9c87-10de343653cd', '039137cb-4a18-4069-8355-20123e8bc6ac', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8a1365d9-52f8-4e4f-9c87-10de343653cd', 'a1bdfd0c-3801-484e-bf7e-fbd5e446181c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8a1365d9-52f8-4e4f-9c87-10de343653cd', '3dd2b0c1-9fce-4c3d-9989-9c9f7be81351', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8a1365d9-52f8-4e4f-9c87-10de343653cd', '1c79d482-7ea0-470b-9019-b31787f0d120', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('81dfc68d-17c6-4a20-aa99-9fe661306011', '83a50612-e015-43dd-862c-b6211ce5b0f0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('81dfc68d-17c6-4a20-aa99-9fe661306011', '039137cb-4a18-4069-8355-20123e8bc6ac', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('81dfc68d-17c6-4a20-aa99-9fe661306011', 'a1bdfd0c-3801-484e-bf7e-fbd5e446181c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1c79d482-7ea0-470b-9019-b31787f0d120', '83a50612-e015-43dd-862c-b6211ce5b0f0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1c79d482-7ea0-470b-9019-b31787f0d120', '039137cb-4a18-4069-8355-20123e8bc6ac', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1c79d482-7ea0-470b-9019-b31787f0d120', 'a1bdfd0c-3801-484e-bf7e-fbd5e446181c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1c79d482-7ea0-470b-9019-b31787f0d120', '3dd2b0c1-9fce-4c3d-9989-9c9f7be81351', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1c79d482-7ea0-470b-9019-b31787f0d120', '8a1365d9-52f8-4e4f-9c87-10de343653cd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('53322d30-83cc-4ed4-86f9-fcdf9a77dcbf', '7fb741ea-f335-4a99-a5a3-a87c6cca7513', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('53322d30-83cc-4ed4-86f9-fcdf9a77dcbf', '83a50612-e015-43dd-862c-b6211ce5b0f0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('53322d30-83cc-4ed4-86f9-fcdf9a77dcbf', '039137cb-4a18-4069-8355-20123e8bc6ac', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('da1dd5f9-ffd4-412e-b42a-edf93bac10ef', '660c2086-60d8-4fd5-bb07-19226c61a57a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('da1dd5f9-ffd4-412e-b42a-edf93bac10ef', '15b2432e-b182-4649-90a5-1a2c0b3804b5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('da1dd5f9-ffd4-412e-b42a-edf93bac10ef', 'c5117bfe-c1a0-41e1-bec9-eee35af44da0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('da1dd5f9-ffd4-412e-b42a-edf93bac10ef', 'e90c1e17-364e-4527-984f-d73666781035', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('da1dd5f9-ffd4-412e-b42a-edf93bac10ef', 'b061486d-5129-4bde-9988-e80aa579ffee', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e8f17dfe-35d6-4925-88b1-f865ca451679', '5b82463e-9d7e-42c9-b196-fc51c5fcef55', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e8f17dfe-35d6-4925-88b1-f865ca451679', '6405153c-4b5b-490f-b98d-e3d91b9e002f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e8f17dfe-35d6-4925-88b1-f865ca451679', '83a50612-e015-43dd-862c-b6211ce5b0f0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5b82463e-9d7e-42c9-b196-fc51c5fcef55', 'e8f17dfe-35d6-4925-88b1-f865ca451679', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5b82463e-9d7e-42c9-b196-fc51c5fcef55', '6405153c-4b5b-490f-b98d-e3d91b9e002f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5b82463e-9d7e-42c9-b196-fc51c5fcef55', '83a50612-e015-43dd-862c-b6211ce5b0f0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6405153c-4b5b-490f-b98d-e3d91b9e002f', 'e8f17dfe-35d6-4925-88b1-f865ca451679', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6405153c-4b5b-490f-b98d-e3d91b9e002f', '5b82463e-9d7e-42c9-b196-fc51c5fcef55', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6405153c-4b5b-490f-b98d-e3d91b9e002f', '83a50612-e015-43dd-862c-b6211ce5b0f0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1a0cf4c7-9256-40cb-9961-16a8b6224aa5', '3356025d-dbf2-461e-bafc-39f9e1d779b2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1a0cf4c7-9256-40cb-9961-16a8b6224aa5', '1ab0fa1d-b99f-446f-9813-bdf4ab8540c2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1a0cf4c7-9256-40cb-9961-16a8b6224aa5', '331b1ce1-696c-42cb-8bd3-3956089ae940', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1a0cf4c7-9256-40cb-9961-16a8b6224aa5', '1b75ede6-261b-4e83-b896-7714ed28d3dd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3356025d-dbf2-461e-bafc-39f9e1d779b2', '1a0cf4c7-9256-40cb-9961-16a8b6224aa5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3356025d-dbf2-461e-bafc-39f9e1d779b2', '1ab0fa1d-b99f-446f-9813-bdf4ab8540c2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3356025d-dbf2-461e-bafc-39f9e1d779b2', '331b1ce1-696c-42cb-8bd3-3956089ae940', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3356025d-dbf2-461e-bafc-39f9e1d779b2', '1b75ede6-261b-4e83-b896-7714ed28d3dd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ab0fa1d-b99f-446f-9813-bdf4ab8540c2', '1a0cf4c7-9256-40cb-9961-16a8b6224aa5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ab0fa1d-b99f-446f-9813-bdf4ab8540c2', '3356025d-dbf2-461e-bafc-39f9e1d779b2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ab0fa1d-b99f-446f-9813-bdf4ab8540c2', '331b1ce1-696c-42cb-8bd3-3956089ae940', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ab0fa1d-b99f-446f-9813-bdf4ab8540c2', '1b75ede6-261b-4e83-b896-7714ed28d3dd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('331b1ce1-696c-42cb-8bd3-3956089ae940', '1a0cf4c7-9256-40cb-9961-16a8b6224aa5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('331b1ce1-696c-42cb-8bd3-3956089ae940', '3356025d-dbf2-461e-bafc-39f9e1d779b2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('331b1ce1-696c-42cb-8bd3-3956089ae940', '1ab0fa1d-b99f-446f-9813-bdf4ab8540c2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('331b1ce1-696c-42cb-8bd3-3956089ae940', '1b75ede6-261b-4e83-b896-7714ed28d3dd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1b75ede6-261b-4e83-b896-7714ed28d3dd', '1a0cf4c7-9256-40cb-9961-16a8b6224aa5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1b75ede6-261b-4e83-b896-7714ed28d3dd', '3356025d-dbf2-461e-bafc-39f9e1d779b2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1b75ede6-261b-4e83-b896-7714ed28d3dd', '1ab0fa1d-b99f-446f-9813-bdf4ab8540c2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1b75ede6-261b-4e83-b896-7714ed28d3dd', '331b1ce1-696c-42cb-8bd3-3956089ae940', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b09de00a-0421-4c74-8625-4f7318d19066', 'f0e38ad7-e241-44a1-aa69-b46fa3fca42e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b09de00a-0421-4c74-8625-4f7318d19066', '403e28f3-8109-45c7-9e8a-3bd1e51ed15a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0e38ad7-e241-44a1-aa69-b46fa3fca42e', 'b09de00a-0421-4c74-8625-4f7318d19066', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0e38ad7-e241-44a1-aa69-b46fa3fca42e', '403e28f3-8109-45c7-9e8a-3bd1e51ed15a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('403e28f3-8109-45c7-9e8a-3bd1e51ed15a', 'b09de00a-0421-4c74-8625-4f7318d19066', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('403e28f3-8109-45c7-9e8a-3bd1e51ed15a', 'f0e38ad7-e241-44a1-aa69-b46fa3fca42e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('db0befcd-334f-46a1-b1a5-78a94eca6ef2', '816fe4ff-8864-499f-bcb1-9cafcbc272a9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('db0befcd-334f-46a1-b1a5-78a94eca6ef2', 'edb8159c-88b8-48c2-9533-3ad72c084ba8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('db0befcd-334f-46a1-b1a5-78a94eca6ef2', 'fa6cf97b-ebfc-4aef-bb7c-bc1db4e3b410', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('db0befcd-334f-46a1-b1a5-78a94eca6ef2', '05805aa6-b849-488b-8656-a71f2d9fd1f3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('db0befcd-334f-46a1-b1a5-78a94eca6ef2', 'c9e2cd18-e55f-4493-ab6c-130b5fb08770', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('edb8159c-88b8-48c2-9533-3ad72c084ba8', '816fe4ff-8864-499f-bcb1-9cafcbc272a9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('edb8159c-88b8-48c2-9533-3ad72c084ba8', 'db0befcd-334f-46a1-b1a5-78a94eca6ef2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('edb8159c-88b8-48c2-9533-3ad72c084ba8', 'fa6cf97b-ebfc-4aef-bb7c-bc1db4e3b410', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('edb8159c-88b8-48c2-9533-3ad72c084ba8', '05805aa6-b849-488b-8656-a71f2d9fd1f3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('edb8159c-88b8-48c2-9533-3ad72c084ba8', 'c9e2cd18-e55f-4493-ab6c-130b5fb08770', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fa6cf97b-ebfc-4aef-bb7c-bc1db4e3b410', '816fe4ff-8864-499f-bcb1-9cafcbc272a9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fa6cf97b-ebfc-4aef-bb7c-bc1db4e3b410', 'db0befcd-334f-46a1-b1a5-78a94eca6ef2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fa6cf97b-ebfc-4aef-bb7c-bc1db4e3b410', 'edb8159c-88b8-48c2-9533-3ad72c084ba8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fa6cf97b-ebfc-4aef-bb7c-bc1db4e3b410', '05805aa6-b849-488b-8656-a71f2d9fd1f3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fa6cf97b-ebfc-4aef-bb7c-bc1db4e3b410', 'c9e2cd18-e55f-4493-ab6c-130b5fb08770', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9e2cd18-e55f-4493-ab6c-130b5fb08770', '816fe4ff-8864-499f-bcb1-9cafcbc272a9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9e2cd18-e55f-4493-ab6c-130b5fb08770', '05805aa6-b849-488b-8656-a71f2d9fd1f3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9e2cd18-e55f-4493-ab6c-130b5fb08770', 'db0befcd-334f-46a1-b1a5-78a94eca6ef2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9e2cd18-e55f-4493-ab6c-130b5fb08770', 'edb8159c-88b8-48c2-9533-3ad72c084ba8', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9e2cd18-e55f-4493-ab6c-130b5fb08770', 'fa6cf97b-ebfc-4aef-bb7c-bc1db4e3b410', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4e24463d-2432-48b9-9394-6708643b5a15', '536f52a4-cdd2-43f1-a475-e7863dfd8246', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4e24463d-2432-48b9-9394-6708643b5a15', '057b2911-d5fc-4871-909f-32d2bd3d7117', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('536f52a4-cdd2-43f1-a475-e7863dfd8246', '4e24463d-2432-48b9-9394-6708643b5a15', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('536f52a4-cdd2-43f1-a475-e7863dfd8246', '057b2911-d5fc-4871-909f-32d2bd3d7117', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('057b2911-d5fc-4871-909f-32d2bd3d7117', '4e24463d-2432-48b9-9394-6708643b5a15', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('057b2911-d5fc-4871-909f-32d2bd3d7117', '536f52a4-cdd2-43f1-a475-e7863dfd8246', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('58fb933d-aef8-4146-93e8-4f407b197bdf', '6b0823dc-8c2d-4983-842a-d8f96c437843', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('58fb933d-aef8-4146-93e8-4f407b197bdf', 'c1030604-e4a9-4eed-900d-707f4727dcb4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('58fb933d-aef8-4146-93e8-4f407b197bdf', 'd50205cf-1b64-42d0-ae9c-93d3808f26fb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6b0823dc-8c2d-4983-842a-d8f96c437843', 'd50205cf-1b64-42d0-ae9c-93d3808f26fb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6b0823dc-8c2d-4983-842a-d8f96c437843', '58fb933d-aef8-4146-93e8-4f407b197bdf', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6b0823dc-8c2d-4983-842a-d8f96c437843', 'c1030604-e4a9-4eed-900d-707f4727dcb4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c1030604-e4a9-4eed-900d-707f4727dcb4', '58fb933d-aef8-4146-93e8-4f407b197bdf', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c1030604-e4a9-4eed-900d-707f4727dcb4', '6b0823dc-8c2d-4983-842a-d8f96c437843', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c1030604-e4a9-4eed-900d-707f4727dcb4', 'd50205cf-1b64-42d0-ae9c-93d3808f26fb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d50205cf-1b64-42d0-ae9c-93d3808f26fb', '6b0823dc-8c2d-4983-842a-d8f96c437843', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d50205cf-1b64-42d0-ae9c-93d3808f26fb', '58fb933d-aef8-4146-93e8-4f407b197bdf', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d50205cf-1b64-42d0-ae9c-93d3808f26fb', 'c1030604-e4a9-4eed-900d-707f4727dcb4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('be7db12f-e430-4bb1-9dbe-1dbce1228e89', 'de76891e-bacd-488c-a8e9-880f8291d454', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('be7db12f-e430-4bb1-9dbe-1dbce1228e89', 'ab432184-f87e-427c-94bf-d9c4b0dd7b2c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('be7db12f-e430-4bb1-9dbe-1dbce1228e89', 'cda53f29-165b-4ae8-a31a-ac812b0c9e0b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('be7db12f-e430-4bb1-9dbe-1dbce1228e89', '5f16e02a-3ccb-446b-9b11-d7441977f347', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('be7db12f-e430-4bb1-9dbe-1dbce1228e89', 'e469aaea-efa2-47e6-9f15-0dc60aba46a9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('de76891e-bacd-488c-a8e9-880f8291d454', 'be7db12f-e430-4bb1-9dbe-1dbce1228e89', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('de76891e-bacd-488c-a8e9-880f8291d454', 'ab432184-f87e-427c-94bf-d9c4b0dd7b2c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('de76891e-bacd-488c-a8e9-880f8291d454', 'cda53f29-165b-4ae8-a31a-ac812b0c9e0b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('de76891e-bacd-488c-a8e9-880f8291d454', '5f16e02a-3ccb-446b-9b11-d7441977f347', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('de76891e-bacd-488c-a8e9-880f8291d454', 'e469aaea-efa2-47e6-9f15-0dc60aba46a9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab432184-f87e-427c-94bf-d9c4b0dd7b2c', '90137e77-4cd9-40e7-9de6-a9217c78817a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab432184-f87e-427c-94bf-d9c4b0dd7b2c', 'be7db12f-e430-4bb1-9dbe-1dbce1228e89', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab432184-f87e-427c-94bf-d9c4b0dd7b2c', 'de76891e-bacd-488c-a8e9-880f8291d454', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab432184-f87e-427c-94bf-d9c4b0dd7b2c', 'cda53f29-165b-4ae8-a31a-ac812b0c9e0b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab432184-f87e-427c-94bf-d9c4b0dd7b2c', '5f16e02a-3ccb-446b-9b11-d7441977f347', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cda53f29-165b-4ae8-a31a-ac812b0c9e0b', 'be7db12f-e430-4bb1-9dbe-1dbce1228e89', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cda53f29-165b-4ae8-a31a-ac812b0c9e0b', 'de76891e-bacd-488c-a8e9-880f8291d454', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cda53f29-165b-4ae8-a31a-ac812b0c9e0b', 'ab432184-f87e-427c-94bf-d9c4b0dd7b2c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cda53f29-165b-4ae8-a31a-ac812b0c9e0b', '5f16e02a-3ccb-446b-9b11-d7441977f347', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cda53f29-165b-4ae8-a31a-ac812b0c9e0b', 'e469aaea-efa2-47e6-9f15-0dc60aba46a9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5f16e02a-3ccb-446b-9b11-d7441977f347', 'be7db12f-e430-4bb1-9dbe-1dbce1228e89', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5f16e02a-3ccb-446b-9b11-d7441977f347', 'de76891e-bacd-488c-a8e9-880f8291d454', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5f16e02a-3ccb-446b-9b11-d7441977f347', 'ab432184-f87e-427c-94bf-d9c4b0dd7b2c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5f16e02a-3ccb-446b-9b11-d7441977f347', 'cda53f29-165b-4ae8-a31a-ac812b0c9e0b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5f16e02a-3ccb-446b-9b11-d7441977f347', 'e469aaea-efa2-47e6-9f15-0dc60aba46a9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e469aaea-efa2-47e6-9f15-0dc60aba46a9', 'be7db12f-e430-4bb1-9dbe-1dbce1228e89', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e469aaea-efa2-47e6-9f15-0dc60aba46a9', 'de76891e-bacd-488c-a8e9-880f8291d454', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e469aaea-efa2-47e6-9f15-0dc60aba46a9', 'ab432184-f87e-427c-94bf-d9c4b0dd7b2c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e469aaea-efa2-47e6-9f15-0dc60aba46a9', 'cda53f29-165b-4ae8-a31a-ac812b0c9e0b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e469aaea-efa2-47e6-9f15-0dc60aba46a9', '5f16e02a-3ccb-446b-9b11-d7441977f347', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('51071576-3f0b-4fed-854f-c1f439f28f2b', 'be7db12f-e430-4bb1-9dbe-1dbce1228e89', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('51071576-3f0b-4fed-854f-c1f439f28f2b', 'de76891e-bacd-488c-a8e9-880f8291d454', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('51071576-3f0b-4fed-854f-c1f439f28f2b', 'ab432184-f87e-427c-94bf-d9c4b0dd7b2c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('51071576-3f0b-4fed-854f-c1f439f28f2b', 'cda53f29-165b-4ae8-a31a-ac812b0c9e0b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('51071576-3f0b-4fed-854f-c1f439f28f2b', '5f16e02a-3ccb-446b-9b11-d7441977f347', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('90137e77-4cd9-40e7-9de6-a9217c78817a', 'ab432184-f87e-427c-94bf-d9c4b0dd7b2c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('90137e77-4cd9-40e7-9de6-a9217c78817a', 'be7db12f-e430-4bb1-9dbe-1dbce1228e89', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('90137e77-4cd9-40e7-9de6-a9217c78817a', 'de76891e-bacd-488c-a8e9-880f8291d454', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('90137e77-4cd9-40e7-9de6-a9217c78817a', 'cda53f29-165b-4ae8-a31a-ac812b0c9e0b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('90137e77-4cd9-40e7-9de6-a9217c78817a', '5f16e02a-3ccb-446b-9b11-d7441977f347', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce091d09-cad8-413f-86dd-6b09f9715344', 'be7db12f-e430-4bb1-9dbe-1dbce1228e89', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce091d09-cad8-413f-86dd-6b09f9715344', 'de76891e-bacd-488c-a8e9-880f8291d454', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce091d09-cad8-413f-86dd-6b09f9715344', 'ab432184-f87e-427c-94bf-d9c4b0dd7b2c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce091d09-cad8-413f-86dd-6b09f9715344', 'cda53f29-165b-4ae8-a31a-ac812b0c9e0b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce091d09-cad8-413f-86dd-6b09f9715344', '5f16e02a-3ccb-446b-9b11-d7441977f347', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a591ed4e-7a6f-4895-b8ad-cb0448313574', '89bb7515-6199-4173-8655-b05ad5c86826', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c5057506-8e96-412e-b374-49d62cd77c12', '89bb7515-6199-4173-8655-b05ad5c86826', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('de78763a-fa62-438d-a8d4-dd2962239a80', '89bb7515-6199-4173-8655-b05ad5c86826', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d62e5387-3dee-4158-b7d4-d2287e55c130', '89bb7515-6199-4173-8655-b05ad5c86826', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8e458d98-6170-467c-b940-98ff2706add3', '89bb7515-6199-4173-8655-b05ad5c86826', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1efc6199-b6eb-4c56-8c25-58a69f28f7e0', '89bb7515-6199-4173-8655-b05ad5c86826', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('608d25af-3156-4ceb-be7c-a490f643ecc0', '7006b777-deb6-492f-bc05-db5e4f27311c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('608d25af-3156-4ceb-be7c-a490f643ecc0', '3e4b26c4-d6da-438c-860d-7cdd2453d646', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('608d25af-3156-4ceb-be7c-a490f643ecc0', 'b6388b55-bb5d-4996-9cee-404fad4e6951', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7006b777-deb6-492f-bc05-db5e4f27311c', '608d25af-3156-4ceb-be7c-a490f643ecc0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7006b777-deb6-492f-bc05-db5e4f27311c', '3e4b26c4-d6da-438c-860d-7cdd2453d646', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7006b777-deb6-492f-bc05-db5e4f27311c', 'b6388b55-bb5d-4996-9cee-404fad4e6951', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3e4b26c4-d6da-438c-860d-7cdd2453d646', 'b6388b55-bb5d-4996-9cee-404fad4e6951', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3e4b26c4-d6da-438c-860d-7cdd2453d646', '608d25af-3156-4ceb-be7c-a490f643ecc0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3e4b26c4-d6da-438c-860d-7cdd2453d646', '7006b777-deb6-492f-bc05-db5e4f27311c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b6388b55-bb5d-4996-9cee-404fad4e6951', '3e4b26c4-d6da-438c-860d-7cdd2453d646', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b6388b55-bb5d-4996-9cee-404fad4e6951', '608d25af-3156-4ceb-be7c-a490f643ecc0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b6388b55-bb5d-4996-9cee-404fad4e6951', '7006b777-deb6-492f-bc05-db5e4f27311c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('939111c0-ce7e-4bc8-81c0-6485c9476da1', '45ac1578-b664-4777-935e-5206895f73f7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('939111c0-ce7e-4bc8-81c0-6485c9476da1', '089bf391-39e2-423b-b63b-28f476321263', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e6815391-139c-424a-acc6-a06c90085452', '939111c0-ce7e-4bc8-81c0-6485c9476da1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e6815391-139c-424a-acc6-a06c90085452', '45ac1578-b664-4777-935e-5206895f73f7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e6815391-139c-424a-acc6-a06c90085452', '089bf391-39e2-423b-b63b-28f476321263', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2c1749a1-2c56-44fe-96d8-e60faeaeecce', '939111c0-ce7e-4bc8-81c0-6485c9476da1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2c1749a1-2c56-44fe-96d8-e60faeaeecce', '45ac1578-b664-4777-935e-5206895f73f7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2c1749a1-2c56-44fe-96d8-e60faeaeecce', '089bf391-39e2-423b-b63b-28f476321263', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45ac1578-b664-4777-935e-5206895f73f7', '939111c0-ce7e-4bc8-81c0-6485c9476da1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('45ac1578-b664-4777-935e-5206895f73f7', '089bf391-39e2-423b-b63b-28f476321263', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8a51516b-933e-4cba-995b-9f813fa35502', '939111c0-ce7e-4bc8-81c0-6485c9476da1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8a51516b-933e-4cba-995b-9f813fa35502', '45ac1578-b664-4777-935e-5206895f73f7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8a51516b-933e-4cba-995b-9f813fa35502', '089bf391-39e2-423b-b63b-28f476321263', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7ff26419-8648-40b7-9d70-fa13eeabbfa0', '939111c0-ce7e-4bc8-81c0-6485c9476da1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7ff26419-8648-40b7-9d70-fa13eeabbfa0', '45ac1578-b664-4777-935e-5206895f73f7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7ff26419-8648-40b7-9d70-fa13eeabbfa0', '089bf391-39e2-423b-b63b-28f476321263', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('089bf391-39e2-423b-b63b-28f476321263', '939111c0-ce7e-4bc8-81c0-6485c9476da1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('089bf391-39e2-423b-b63b-28f476321263', '45ac1578-b664-4777-935e-5206895f73f7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('409b68d6-d420-423e-b052-08541b6eb2b5', '939111c0-ce7e-4bc8-81c0-6485c9476da1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('409b68d6-d420-423e-b052-08541b6eb2b5', '45ac1578-b664-4777-935e-5206895f73f7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('409b68d6-d420-423e-b052-08541b6eb2b5', '089bf391-39e2-423b-b63b-28f476321263', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('98097db7-c507-41d8-b3af-02fc6ce229c2', '939111c0-ce7e-4bc8-81c0-6485c9476da1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('98097db7-c507-41d8-b3af-02fc6ce229c2', '45ac1578-b664-4777-935e-5206895f73f7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('98097db7-c507-41d8-b3af-02fc6ce229c2', '089bf391-39e2-423b-b63b-28f476321263', 2) ON CONFLICT DO NOTHING;



INSERT INTO public.faqs VALUES ('bf8410b4-c2b3-42d6-bc7d-91303a9ae43e', 'متى يوصلني الرد بعد الاشتراك؟', 'خلال 48 ساعة عمل. أيام العمل من الأحد إلى الخميس، من 12 الظهر حتى 9 مساءً، والتواصل على واتساب.', 0, true, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('b5be379c-eb18-41b3-9cfc-fc5b2c417800', 'كيف تتم المتابعة؟', 'ترسل مراجعتك الأسبوعية في يوم المراجعة، وأرد عليك بتعديلات مسجلة (فيديو أو صوت). في الباقة الأساسية المتابعة كل أسبوعين. التواصل اليومي على واتساب مع رد خلال 48 ساعة.', 1, true, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('70f09e4a-aa0a-4aa0-8ceb-acba485d24e2', 'أنا مبتدئ تماماً، هل يناسبني؟', 'نعم. البرنامج يُبنى على مستواك الحالي، والتمارين مشروحة، وتقدر ترسل مقاطع أدائك لتصحيح التكنيك.', 2, true, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('378e129e-32b9-4dba-b3b5-78471815c4be', 'أتمرن في البيت، ماذا أحتاج من أدوات؟', 'تحدد في النموذج الأدوات المتوفرة عندك (دمبلز، حبال مقاومة، بار…) ويُبنى جدولك عليها.', 3, true, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('abf44673-a9b0-43f9-8492-f2869bcab567', 'كيف أدفع؟', 'بتحويل بنكي بعد تعبئة الاستبيان. أول ما ترسل الاستبيان يظهر لك رقم طلبك والمبلغ وبيانات الحساب. حوّل المبلغ وارفع صورة الإيصال من صفحة طلبك، ويتأكد اشتراكك بعد التحقق من وصول المبلغ.', 4, true, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('835ec963-2a71-40f6-90bc-72f5bfe20ad8', 'ما شروط ضمان استرجاع المبلغ؟', 'في اشتراكات 3 أشهر لباقات المتابعة (المكثفة، المتقدمة، الأساسية): إذا لم يتحسن أي مؤشر من مؤشرات تقدمك بعد 12 أسبوعاً، يرجع لك المبلغ كاملاً.
مؤشرات التقدم (بحسب هدفك): متوسط الوزن الأسبوعي، أو محيط الخصر، أو القوة في التمارين الأساسية (الوزن أو التكرارات).
شروط الضمان:
- إرسال المراجعة الأسبوعية كل أسبوع.
- أخذ القياسات بانتظام.
- تصوير التمارين وإرسالها.
- الالتزام بجدول التغذية المخصص (في الباقات التي تشمل تغذية).
يُطلب الاسترجاع عبر واتساب خلال 14 يوماً من نهاية الأشهر الثلاثة.', 5, true, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('b8e017d5-bf67-47ac-a6e2-5668d13a2c0b', 'هل الجداول لي بعد انتهاء الاشتراك؟', 'نعم، جميع الجداول لك مدى الحياة وتقدر تعدّل عليها.', 6, true, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('fdade231-58ae-4629-8e63-499e8e8192b8', 'ما هو التجديد المجاني؟', 'مكافأة للملتزمين: إذا كان اشتراكك 3 أشهر تحصل على 3 أشهر إضافية مجاناً، فيصير المجموع 6 أشهر بسعر 3.
الشروط:
- نسبة التزام 90% فأكثر: المراجعات الأسبوعية المرسلة والتمارين المسجلة.
- تقدم واضح في مؤشرات التقدم نفسها المذكورة في الضمان.
- للمتدربين الرجال: إرسال صور التطور (قبل وبعد) للمدربة للتوثيق، مع تغطية الوجه والسرة.
نشر الصور في السوشل ميديا اختياري بالكامل حسب موافقتك، ولا يؤثر على استحقاقك للتجديد.', 7, true, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('9fc467d0-5484-4482-9087-f1b3ebc8f7aa', 'من يطّلع على بياناتي؟', 'المدربة فقط، وتُستخدم لتصميم برنامجك ومتابعتك. لا تُنشر نتيجتك أو صورتك إلا بموافقتك الصريحة في النموذج.', 8, true, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;



INSERT INTO public.foods VALUES ('9d22ada5-41ab-44af-9c62-0f25f93bd77e', 'رز أبيض مطبوخ', 'Rice, white, long-grain, regular, enriched, cooked', 'حبوب ونشويات', 130.0, 2.7, 28.2, 0.3, 150.0, 'كوب إلا ربع', 'usda', '168878', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ec3ad7c3-2824-48da-b34f-0437b3f498fb', 'رز بني مطبوخ', 'Rice, brown, long-grain, cooked (Includes foods for USDA''s Food Distribution Program)', 'حبوب ونشويات', 123.0, 2.7, 25.6, 1.0, 150.0, NULL, 'usda', '169704', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('51d8d827-5af0-4b4b-a31c-20cccc371336', 'رز أبيض (غير مطبوخ)', 'Rice, white, long-grain, regular, raw, enriched', 'حبوب ونشويات', 365.0, 7.1, 80.0, 0.7, 75.0, NULL, 'usda', '168877', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('460f6d76-1cf9-4f1a-9158-2f8d5facf016', 'مكرونة مطبوخة', 'Pasta, cooked, enriched, without added salt', 'حبوب ونشويات', 158.0, 5.8, 30.9, 0.9, 140.0, 'كوب', 'usda', '169737', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('62bec95b-300d-4a5f-a065-13062f1b546d', 'مكرونة (غير مطبوخة)', 'Pasta, dry, enriched', 'حبوب ونشويات', 371.0, 13.0, 74.7, 1.5, 75.0, NULL, 'usda', '169736', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('02eac654-478a-4a99-aaff-fbacecee4fce', 'شوفان', 'Cereals, oats, regular and quick, not fortified, dry', 'حبوب ونشويات', 379.0, 13.2, 67.7, 6.5, 40.0, 'نص كوب', 'usda', '173904', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b69d2e93-9d66-4fe6-9711-d63573856b09', 'خبز أبيض (توست)', 'Bread, white, commercially prepared (includes soft bread crumbs)', 'خبز', 266.0, 8.9, 49.4, 3.3, 28.0, 'شريحة', 'usda', '174924', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('1bfae249-77ff-4539-99ad-2728d6b7b926', 'خبز بر (توست أسمر)', 'Bread, whole-wheat, commercially prepared', 'خبز', 252.0, 12.5, 42.7, 3.5, 32.0, 'شريحة', 'usda', '172688', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('8f23f8f9-3d41-4cbb-b59b-8f5bbbecbe1a', 'خبز عربي أبيض', 'Bread, pita, white, enriched', 'خبز', 275.0, 9.1, 55.7, 1.2, 60.0, 'رغيف صغير', 'usda', '174915', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('c8a2706e-5847-4ac2-9669-1b0db9ca689c', 'خبز عربي بر', 'Bread, pita, whole-wheat', 'خبز', 262.0, 9.8, 55.9, 1.7, 64.0, 'رغيف صغير', 'usda', '174916', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ecb6bf39-cd5a-4dd2-8d56-7782e8660b99', 'تورتيلا قمح', 'Tortillas, ready-to-bake or -fry, flour, refrigerated', 'خبز', 306.0, 8.2, 49.4, 8.0, 45.0, 'حبة', 'usda', '175037', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('aa1dd409-9763-4270-9160-332e8ecc0a0d', 'بطاطس مسلوقة', 'Potatoes, boiled, cooked without skin, flesh, without salt', 'حبوب ونشويات', 86.0, 1.7, 20.0, 0.1, 150.0, 'حبة وسط', 'usda', '170440', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('0765d953-7559-4381-b3ce-dc7cd1eeadc7', 'بطاطا حلوة مشوية', 'Sweet potato, cooked, baked in skin, flesh, without salt', 'حبوب ونشويات', 90.0, 2.0, 20.7, 0.2, 150.0, 'حبة وسط', 'usda', '168483', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('1eefc2d7-b6f5-4075-91b2-9fd362de9bef', 'برغل مطبوخ', 'Bulgur, cooked', 'حبوب ونشويات', 83.0, 3.1, 18.6, 0.2, 150.0, NULL, 'usda', '170287', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('9e97b0f8-f6a4-41ca-a783-ccf96e1f491f', 'كينوا مطبوخة', 'Quinoa, cooked', 'حبوب ونشويات', 120.0, 4.4, 21.3, 1.9, 150.0, NULL, 'usda', '168917', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('6993bc21-f46b-4a75-b5c4-d7e2080b1aec', 'كورن فليكس', 'Cereals ready-to-eat, RALSTON Corn Flakes', 'حبوب ونشويات', 384.0, 5.9, 88.0, 0.9, 30.0, NULL, 'usda', '174648', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('e9c93f33-0289-4e7b-9728-bf94aa261e3d', 'صدر دجاج مشوي', 'Chicken, broilers or fryers, breast, meat only, cooked, roasted', 'لحوم ودواجن', 165.0, 31.0, 0.0, 3.6, 100.0, NULL, 'usda', '171477', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('4f6a815b-66d0-4e9c-8561-361374ca59f0', 'صدر دجاج نيء', 'Chicken, broiler or fryers, breast, skinless, boneless, meat only, raw', 'لحوم ودواجن', 120.0, 22.5, 0.0, 2.6, 150.0, NULL, 'usda', '171077', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('4f5cbe25-6208-4041-85c9-241c2bfcc80f', 'فخذ دجاج مشوي (بدون جلد)', 'Chicken, broilers or fryers, thigh, meat only, cooked, roasted', 'لحوم ودواجن', 179.0, 24.8, 0.0, 8.2, 100.0, NULL, 'usda', '172388', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('6bad1189-2257-4ff9-bf4e-2344d04ff800', 'لحم بقري مفروم 90% مطبوخ', 'Beef, ground, 90% lean meat / 10% fat, patty, cooked, broiled', 'لحوم ودواجن', 217.0, 26.1, 0.0, 11.8, 100.0, NULL, 'usda', '174031', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('438965f4-9aba-4d0e-bad5-125a800bf764', 'لحم بقري مفروم 80% مطبوخ', 'Beef, ground, 80% lean meat / 20% fat, patty, cooked, broiled', 'لحوم ودواجن', 270.0, 25.8, 0.0, 17.8, 100.0, NULL, 'usda', '171797', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('13d7ed1c-5800-493d-80cf-b734c0385ca0', 'لحم غنم مطبوخ', 'Lamb, composite of trimmed retail cuts, separable lean only, trimmed to 1/4" fat, choice, cooked', 'لحوم ودواجن', 206.0, 28.2, 0.0, 9.5, 100.0, NULL, 'usda', '174308', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('fa1a478d-54c8-44f3-a189-eaccd9571b43', 'ديك رومي (شرائح)', 'Turkey, whole, breast, meat only, cooked, roasted', 'لحوم ودواجن', 147.0, 30.1, 0.0, 2.1, 50.0, NULL, 'usda', '171496', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('cfb383e4-d781-4edc-82d1-4ac11d3e5e6d', 'تونة معلبة بالماء', 'Fish, tuna, light, canned in water, drained solids (Includes foods for USDA''s Food Distribution Program)', 'أسماك', 86.0, 19.4, 0.0, 1.0, 100.0, 'علبة صغيرة مصفاة', 'usda', '173709', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('8686d5c4-da4c-4513-bc41-85d08099f2a0', 'تونة معلبة بالزيت', 'Fish, tuna, light, canned in oil, drained solids', 'أسماك', 198.0, 29.1, 0.0, 8.2, 100.0, NULL, 'usda', '173708', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('4a139bc6-45d9-4b6c-b1f3-35200e5acc9a', 'سلمون مطبوخ', 'Fish, salmon, Atlantic, farmed, cooked, dry heat', 'أسماك', 206.0, 22.1, 0.0, 12.4, 120.0, NULL, 'usda', '175168', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a48a513d-3d96-42a5-8edb-10a99c1a2f46', 'سلمون مدخن', 'Fish, salmon, chinook, smoked', 'أسماك', 117.0, 18.3, 0.0, 4.3, 60.0, NULL, 'usda', '173687', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d9c2b694-6043-4073-8ec3-714791f66de1', 'روبيان مطبوخ', 'Crustaceans, shrimp, cooked', 'أسماك', 99.0, 24.0, 0.2, 0.3, 100.0, NULL, 'usda', '175180', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('bbcee06d-1bdd-4ce8-9c79-e186622272e5', 'هامور/سمك أبيض مطبوخ', 'Fish, grouper, mixed species, cooked, dry heat', 'أسماك', 118.0, 24.8, 0.0, 1.3, 150.0, NULL, 'usda', '171963', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('c525bc37-80c1-488a-84c9-5d52aa0f060a', 'بيض كامل', 'Egg, whole, raw, fresh', 'بيض وألبان', 143.0, 12.6, 0.7, 9.5, 50.0, 'بيضة', 'usda', '171287', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('220771ba-3add-40c2-a608-850ebbd31432', 'بياض بيض', 'Egg, white, raw, fresh', 'بيض وألبان', 52.0, 10.9, 0.7, 0.2, 33.0, 'بياض بيضة', 'usda', '172183', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('70e731a4-d114-43f9-9868-c365fbfa5559', 'بيض مسلوق', 'Egg, whole, cooked, hard-boiled', 'بيض وألبان', 155.0, 12.6, 1.1, 10.6, 50.0, 'بيضة', 'usda', '173424', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('9cb579bc-53b4-4838-bac5-98c8419268e2', 'حليب كامل الدسم', 'Milk, whole, 3.25% milkfat, with added vitamin D', 'بيض وألبان', 61.0, 3.2, 4.8, 3.3, 244.0, 'كوب', 'usda', '171265', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('0a3a0775-c9f2-48b9-b841-64669cc1a80c', 'حليب قليل الدسم 1%', 'Milk, lowfat, fluid, 1% milkfat, with added vitamin A and vitamin D', 'بيض وألبان', 42.0, 3.4, 5.0, 1.0, 244.0, 'كوب', 'usda', '170872', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a97b7bd0-21e4-41b1-818c-0ec56a78235d', 'حليب خالي الدسم', 'Milk, nonfat, fluid, with added vitamin A and vitamin D (fat free or skim)', 'بيض وألبان', 34.0, 3.4, 5.0, 0.1, 245.0, 'كوب', 'usda', '171269', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b467588f-f241-43cd-afad-61d278aa46b0', 'زبادي كامل الدسم', 'Yogurt, plain, whole milk', 'بيض وألبان', 61.0, 3.5, 4.7, 3.3, 170.0, NULL, 'usda', '171284', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b735211d-8b45-4a06-bf7c-4fe21259b9c8', 'زبادي قليل الدسم', 'Yogurt, plain, low fat', 'بيض وألبان', 63.0, 5.3, 7.0, 1.6, 170.0, NULL, 'usda', '170886', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('7053c5dc-5263-4fde-8e8c-8625a413e569', 'زبادي يوناني قليل الدسم', 'Yogurt, Greek, plain, lowfat', 'بيض وألبان', 73.0, 10.0, 3.9, 1.9, 170.0, NULL, 'usda', '170903', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('c969edcc-8f65-4406-a1b3-26094543d515', 'زبدة فول سوداني', 'Peanut butter, smooth style, without salt', 'دهون ومكسرات', 598.0, 22.2, 22.3, 51.4, 16.0, 'ملعقة كبيرة', 'usda', '172470', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('fba7079b-9192-4745-987b-3799740501bc', 'زبادي يوناني خالي الدسم', 'Yogurt, Greek, plain, nonfat (Includes foods for USDA''s Food Distribution Program)', 'بيض وألبان', 59.0, 10.2, 3.6, 0.4, 170.0, NULL, 'usda', '170894', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('e70ed3c5-e1ff-49b1-9d3e-c29433138c7b', 'جبنة قريش (كوتج)', 'Cheese, cottage, lowfat, 2% milkfat', 'بيض وألبان', 81.0, 10.5, 4.8, 2.3, 113.0, 'نص كوب', 'usda', '172182', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('2d4200d1-4654-4152-84ad-e06fad3231c0', 'جبنة موزاريلا قليلة الدسم', 'Cheese, mozzarella, part skim milk', 'بيض وألبان', 254.0, 24.3, 2.8, 15.9, 28.0, NULL, 'usda', '170847', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a754e702-d075-44b4-b56c-7ca829d438bf', 'جبنة شيدر', 'Cheese, cheddar (Includes foods for USDA''s Food Distribution Program)', 'بيض وألبان', 403.0, 22.9, 3.4, 33.3, 28.0, 'شريحة', 'usda', '173414', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d9fc1081-fdbd-45b2-abcc-a579ec2e15b3', 'جبنة فيتا', 'Cheese, feta', 'بيض وألبان', 265.0, 14.2, 3.9, 21.5, 28.0, NULL, 'usda', '173420', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('9909c119-ec54-4e68-89b4-cc77db3b46a0', 'جبنة كريمية', 'Cheese, cream', 'بيض وألبان', 350.0, 6.2, 5.5, 34.4, 30.0, NULL, 'usda', '173418', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('2d11e1b7-f35f-4428-9f45-0fff9928206c', 'واي بروتين', 'Beverages, Whey protein powder isolate', 'مكملات', 359.0, 58.1, 29.1, 1.2, 30.0, 'سكوب', 'usda', '173177', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('959e656d-a10c-4a5a-b4ce-b2622aa74670', 'عدس مطبوخ', 'Lentils, mature seeds, cooked, boiled, without salt', 'بقوليات', 116.0, 9.0, 20.1, 0.4, 150.0, NULL, 'usda', '172421', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('59f3f2b0-da1e-4a2a-b6cc-cbe2aaeb14ef', 'حمص مطبوخ', 'Chickpeas (garbanzo beans, bengal gram), mature seeds, cooked, boiled, without salt', 'بقوليات', 164.0, 8.9, 27.4, 2.6, 150.0, NULL, 'usda', '173757', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('18a053f1-9c87-4f89-ae16-a9ef97780b74', 'فول مدمس (مطبوخ)', 'Broadbeans (fava beans), mature seeds, cooked, boiled, without salt', 'بقوليات', 110.0, 7.6, 19.7, 0.4, 150.0, NULL, 'usda', '173753', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('34c6ddab-1696-438e-91ca-9f365f31af37', 'فاصوليا حمراء مطبوخة', 'Beans, kidney, all types, mature seeds, cooked, boiled, without salt', 'بقوليات', 127.0, 8.7, 22.8, 0.5, 150.0, NULL, 'usda', '173740', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3d425b00-d1e5-4bde-8f5a-10bed233da5a', 'حمص بطحينة (حمص جاهز)', 'Hummus, commercial', 'بقوليات', 237.0, 7.8, 15.0, 17.8, 60.0, NULL, 'usda', '174289', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('6643badf-ae69-4c3a-9566-d13911249378', 'تمر مجدول', 'Dates, medjool', 'فواكه', 277.0, 1.8, 75.0, 0.2, 24.0, 'حبة', 'usda', '168191', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('34775077-34fa-4e97-95f7-35c0f591130d', 'تمر (دقلة نور)', 'Dates, deglet noor', 'فواكه', 282.0, 2.5, 75.0, 0.4, 7.0, 'حبة', 'usda', '171726', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('196de67f-4e9e-4eaa-b0d7-d1f31fd48cfc', 'موز', 'Bananas, raw', 'فواكه', 89.0, 1.1, 22.8, 0.3, 118.0, 'حبة وسط', 'usda', '173944', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('41c083aa-e9a0-4756-823b-9b3c9d8024e6', 'تفاح', 'Apples, raw, with skin (Includes foods for USDA''s Food Distribution Program)', 'فواكه', 52.0, 0.3, 13.8, 0.2, 182.0, 'حبة وسط', 'usda', '171688', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('64ec06ab-4c06-47b4-a4b3-54e3962639a1', 'برتقال', 'Oranges, raw, all commercial varieties', 'فواكه', 47.0, 0.9, 11.8, 0.1, 131.0, 'حبة', 'usda', '169097', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('da4eb978-fbf1-429d-a3a2-c4e68750570e', 'فراولة', 'Strawberries, raw', 'فواكه', 32.0, 0.7, 7.7, 0.3, 150.0, 'كوب', 'usda', '167762', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('85d00353-e3bd-4c88-81bc-0230ee3f7759', 'عنب', 'Grapes, red or green (European type, such as Thompson seedless), raw', 'فواكه', 69.0, 0.7, 18.1, 0.2, 150.0, 'كوب', 'usda', '174683', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('859c64a6-a27c-425c-a523-2a72b96f462d', 'بطيخ', 'Watermelon, raw', 'فواكه', 30.0, 0.6, 7.6, 0.2, 280.0, 'كوب ونص', 'usda', '167765', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('bbab21b2-1cc4-43a8-9032-4a9d213285e7', 'مانجو', 'Mangos, raw', 'فواكه', 60.0, 0.8, 15.0, 0.4, 165.0, 'كوب', 'usda', '169910', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('82cbb571-18f9-449c-a4cf-ab57613b3aaf', 'أناناس', 'Pineapple, raw, all varieties', 'فواكه', 50.0, 0.5, 13.1, 0.1, 165.0, 'كوب', 'usda', '169124', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('4fe010c5-c532-44bb-ba07-4e7d90a1f0e5', 'توت أزرق', 'Blueberries, raw', 'فواكه', 57.0, 0.7, 14.5, 0.3, 148.0, 'كوب', 'usda', '171711', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('1a5f8fc0-c76d-4a73-b200-43a5ec3ae4c6', 'كيوي', 'Kiwifruit, green, raw', 'فواكه', 61.0, 1.1, 14.7, 0.5, 75.0, 'حبة', 'usda', '168153', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('e7d228b2-d812-45b8-819a-1b50732b6008', 'رمان', 'Pomegranates, raw', 'فواكه', 83.0, 1.7, 18.7, 1.2, 87.0, 'نص كوب حبوب', 'usda', '169134', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a5339eb3-ae6c-4309-8be1-0e9bc219194a', 'خيار', 'Cucumber, with peel, raw', 'خضار', 15.0, 0.7, 3.6, 0.1, 100.0, NULL, 'usda', '168409', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('2225e22b-866d-4593-a56a-db6fc251fae0', 'طماطم', 'Tomatoes, red, ripe, raw, year round average', 'خضار', 18.0, 0.9, 3.9, 0.2, 120.0, 'حبة وسط', 'usda', '170457', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('8b68b031-b06b-486d-b553-fb6beb1ef1c9', 'خس', 'Lettuce, cos or romaine, raw', 'خضار', 17.0, 1.2, 3.3, 0.3, 50.0, NULL, 'usda', '169247', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('5033ac4e-8bfa-46a0-8e97-7a6468ebacbc', 'جزر', 'Carrots, raw', 'خضار', 41.0, 0.9, 9.6, 0.2, 60.0, 'حبة', 'usda', '170393', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('94d7db05-4b39-447d-adfa-3f7151851186', 'بروكلي مطبوخ', 'Broccoli, cooked, boiled, drained, without salt', 'خضار', 35.0, 2.4, 7.2, 0.4, 90.0, NULL, 'usda', '169967', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('acb671bd-3bd3-47c1-8ef5-5c3ee0c3cbae', 'سبانخ', 'Spinach, raw', 'خضار', 23.0, 2.9, 3.6, 0.4, 30.0, 'كوب', 'usda', '168462', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('81efe074-6827-425f-b326-e0ac0e31a23e', 'فلفل رومي أحمر', 'Peppers, sweet, red, raw', 'خضار', 26.0, 1.0, 6.0, 0.3, 120.0, 'حبة', 'usda', '170108', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a49c500a-a89b-4534-9a58-1d4a7b71eceb', 'بصل', 'Onions, raw', 'خضار', 40.0, 1.1, 9.3, 0.1, 110.0, 'حبة وسط', 'usda', '170000', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a28b71a4-5067-49b8-a21c-09a689fd013e', 'فطر (مشروم)', 'Mushrooms, white, raw', 'خضار', 22.0, 3.1, 3.3, 0.3, 70.0, 'كوب', 'usda', '169251', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('7d091fbd-3112-4aff-9920-87271e92ce97', 'كوسا مطبوخة', 'Squash, summer, zucchini, includes skin, cooked, boiled, drained, without salt', 'خضار', 15.0, 1.1, 2.7, 0.4, 180.0, NULL, 'usda', '169292', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('0c226e06-ec6c-4683-89df-17b5c941fc3e', 'باذنجان مطبوخ', 'Eggplant, cooked, boiled, drained, without salt', 'خضار', 35.0, 0.8, 8.7, 0.2, 100.0, NULL, 'usda', '169229', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('0cf53ed3-fbd9-43ae-a423-ba5ed5a1b8b1', 'ذرة حلوة مطبوخة', 'Corn, sweet, yellow, cooked, boiled, drained, without salt', 'خضار', 96.0, 3.4, 21.0, 1.5, 150.0, NULL, 'usda', '169999', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ab2c7106-752a-4f84-9a8c-8ec9a3541521', 'أفوكادو', 'Avocados, raw, all commercial varieties', 'دهون ومكسرات', 160.0, 2.0, 8.5, 14.7, 50.0, 'ثلث حبة', 'usda', '171705', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('2c1b0646-3f37-471d-9972-26b43ed91887', 'زيت زيتون', 'Oil, olive, salad or cooking', 'دهون ومكسرات', 884.0, 0.0, 0.0, 100.0, 5.0, 'ملعقة صغيرة', 'usda', '171413', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('9fe7cdbc-0be7-490f-ab52-f6cacc7684e1', 'زبدة', 'Butter, salted', 'دهون ومكسرات', 717.0, 0.9, 0.1, 81.1, 5.0, 'ملعقة صغيرة', 'usda', '173410', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('506531b2-6fbe-4d3a-8b55-e413fbd5e956', 'لوز', 'Nuts, almonds', 'دهون ومكسرات', 579.0, 21.2, 21.6, 49.9, 28.0, 'حفنة', 'usda', '170567', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('38ef4334-5c6f-4d80-aef5-955a7f0c96d9', 'كاجو', 'Nuts, cashew nuts, raw', 'دهون ومكسرات', 553.0, 18.2, 30.2, 43.9, 28.0, 'حفنة', 'usda', '170162', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ad3680ac-fc72-4ee8-a070-96f59f517996', 'فستق حلبي', 'Nuts, pistachio nuts, raw', 'دهون ومكسرات', 560.0, 20.2, 27.2, 45.3, 28.0, 'حفنة', 'usda', '170184', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('669f67a7-db89-487b-9eee-62ead32bc2de', 'جوز (عين الجمل)', 'Nuts, walnuts, english', 'دهون ومكسرات', 654.0, 15.2, 13.7, 65.2, 28.0, 'حفنة', 'usda', '170187', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('5746be9e-a3d4-4a83-b359-4e184e10a85b', 'فول سوداني', 'Peanuts, all types, raw', 'دهون ومكسرات', 567.0, 25.8, 16.1, 49.2, 28.0, 'حفنة', 'usda', '172430', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('cc9afd84-4d2c-4c82-a9e3-b62849345437', 'طحينة', 'Seeds, sesame butter, tahini, from roasted and toasted kernels (most common type)', 'دهون ومكسرات', 595.0, 17.0, 21.2, 53.8, 15.0, 'ملعقة كبيرة', 'usda', '170189', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f1b22e6a-0754-4f36-b5f4-9e04b1484823', 'بذور الشيا', 'Seeds, chia seeds, dried', 'دهون ومكسرات', 486.0, 16.5, 42.1, 30.7, 12.0, 'ملعقة كبيرة', 'usda', '170554', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3c26bfc6-beff-4089-9373-82c5b1318089', 'عسل', 'Honey', 'حلويات ومشروبات', 304.0, 0.3, 82.4, 0.0, 21.0, 'ملعقة كبيرة', 'usda', '169640', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('4d8ae25b-d4e8-41b6-9540-1012f24777ca', 'سكر أبيض', 'Sugars, granulated', 'حلويات ومشروبات', 387.0, 0.0, 100.0, 0.0, 4.0, 'ملعقة صغيرة', 'usda', '169655', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('171f0381-191a-4cf8-8976-2e6a7a9f653d', 'شوكولاتة داكنة 70-85%', 'Chocolate, dark, 70-85% cacao solids', 'حلويات ومشروبات', 598.0, 7.8, 45.9, 42.6, 20.0, NULL, 'usda', '170273', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('78b1afe4-d6d2-4a12-83b3-23cfd1c04095', 'عصير برتقال', 'Orange juice, raw (Includes foods for USDA''s Food Distribution Program)', 'حلويات ومشروبات', 45.0, 0.7, 10.4, 0.2, 248.0, 'كوب', 'usda', '169098', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a17c9c7c-540d-4f11-bfe6-c7a9760cb40a', 'مايونيز', 'Salad dressing, mayonnaise, regular', 'صوصات', 680.0, 1.0, 0.6, 74.9, 15.0, 'ملعقة كبيرة', 'usda', '171009', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('4280b25c-eafe-482c-b593-c4bba51f7f8d', 'كاتشب', 'Catsup', 'صوصات', 101.0, 1.0, 27.4, 0.1, 17.0, 'ملعقة كبيرة', 'usda', '168556', true, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;



INSERT INTO public.policies VALUES ('terms', 'الشروط والأحكام', '- يبدأ الاشتراك بعد التحقق من وصول التحويل البنكي، وتعبئة استبيان المتدرب.
- ساعات العمل: الأحد – الخميس، 12 ظهراً – 9 مساءً. الرد على الرسائل خلال 48 ساعة عمل.
- البرنامج لا يغني عن الاستشارة الطبية، والمتدرب مسؤول عن الإفصاح عن أي إصابة أو حالة صحية.
- الجداول ملك المتدرب مدى الحياة ويمكنه التعديل عليها.
- الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي.', 0, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.policies VALUES ('refund', 'الضمان والاسترجاع', '- في اشتراكات 3 أشهر لباقات المتابعة (المكثفة، المتقدمة، الأساسية): يُسترد المبلغ كاملاً إذا لم يتحسن أي من مؤشرات التقدم (متوسط الوزن الأسبوعي، محيط الخصر، القوة في التمارين الأساسية) بعد 12 أسبوعاً.
- شروط الضمان: إرسال المراجعة الأسبوعية كل أسبوع، وأخذ القياسات بانتظام، وتصوير التمارين وإرسالها، والالتزام بجدول التغذية المخصص في الباقات التي تشملها.
- يُطلب الاسترجاع عبر واتساب خلال 14 يوماً من نهاية الأشهر الثلاثة، ويُرجع المبلغ بتحويل بنكي.
- التجديد المجاني: اشتراك 3 أشهر يُكافأ بـ 3 أشهر إضافية عند التزام 90% فأكثر وتقدم واضح في مؤشرات التقدم. صور التطور تُرسل للمدربة للتوثيق (للرجال مع تغطية الوجه والسرة)، ونشرها اختياري.', 1, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.policies VALUES ('privacy', 'سياسة الخصوصية', '- نجمع: الاسم، البريد الإلكتروني (للدخول إلى حسابك)، رقم الجوال (واتساب)، الباقة المختارة، ومعلومات الاستبيان التي تكتبها بنفسك (ومنها معلومات صحية وقياسات اختيارية).
- الغرض: تنفيذ طلبك، وتصميم برنامجك ومتابعتك، والتواصل معك بخصوصه فقط.
- المعلومات الصحية تُحفظ منفصلة، ولا يطّلع عليها إلا أنت والمدربة، ولا تُرسل في رسائل البريد أو التنبيهات.
- الدفع بتحويل بنكي مباشر لحساب المؤسسة، والموقع لا يطلب أو يخزن أي بيانات بنكية أو بيانات بطاقات. إيصال التحويل يُستخدم لتأكيد طلبك فقط، ويُحفظ في تخزين خاص لا يُفتح إلا لك وللمدربة.
- لا نبيع بياناتك ولا نشاركها مع أي طرف لأغراض تسويقية، ولا تُنشر نتيجتك أو صورتك إلا بموافقتك الصريحة.
- تقدر تطلب نسخة من بياناتك أو حذفها أو سحب موافقتك على النشر بمراسلتنا على واتساب.', 2, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.policies VALUES ('reviews', 'سياسة التقييمات', '- يكتب التقييم فقط من اشترى خدمة وبدأها فعلاً، وتقييم واحد لكل طلب.
- كل تقييم يُراجع قبل ظهوره للعامة، ولا يُعدّل نصه أبداً.
- تختار بنفسك طريقة ظهور اسمك: الاسم كامل، أو الاسم الأول فقط، أو بدون اسم. والموافقة على النشر منفصلة واختيارية.
- لا يُنشر تقييم يحتوي أرقام هواتف أو بريد أو روابط أو تفاصيل صحية خاصة أو إساءة لأي شخص.
- يحق للمدربة الرد على التقييم، أو إخفاء التقييم المخالف لهذه السياسة مع تسجيل السبب.
- تقدر تطلب إخفاء تقييمك في أي وقت بمراسلتنا على واتساب.', 3, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;



INSERT INTO public.products VALUES ('c9810dda-4672-41d5-8652-5df48fe4c425', 'intensive', 'follow', 'الباقة المكثفة', 'الأنسب للمبتدئين ولمن يحتاج متابعة أسبوعية مع زوم: تمرين + تغذية + زوم + جلسة حضورية', '[{"text": "جلسة حضورية مجانية لمدة ساعة لتصحيح التكنيك والتأكد من جودة التمرين (للبنات في المنطقة الشرقية)", "included": true}, {"text": "ملف شامل للخطة التدريبية والتغذية مع شروحات وافية للتمارين، بالمنزل أو بالنادي", "included": true}, {"text": "4 مكالمات زوم شهرياً نتابع فيها تطورك واستفساراتك الرياضية والنفسية", "included": true}, {"text": "مناقشة أسبوعية لتطورك البدني والنفسي (فيديو أو تسجيل صوتي) مع تعديل السعرات أو التمرين عند الحاجة", "included": true}, {"text": "شرح سهل ومبسط لتطبيق حساب السعرات MyFitnessPal", "included": true}, {"text": "كتيب شامل للرياضة والتغذية", "included": true}, {"text": "مساعدتك على اختيارات أنسب لصحتك ونمط حياتك في التغذية والروتين اليومي", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}]', NULL, 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.', true, NULL, 'published', 0, false, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('67a27488-eaf7-476e-b43a-d959582e46a6', 'advanced', 'follow', 'الباقة المتقدمة', 'لمن عنده خبرة ويحتاج تمرين + تغذية مع متابعة أسبوعية، بدون زوم', '[{"text": "ملف شامل للخطة التدريبية والتغذية مع شروحات وافية للتمارين، بالمنزل أو بالنادي", "included": true}, {"text": "مناقشة أسبوعية لتطورك البدني والنفسي (فيديو أو تسجيل صوتي) مع تعديل السعرات أو التمرين عند الحاجة", "included": true}, {"text": "كتيب شامل للرياضة والتغذية", "included": true}, {"text": "مساعدتك على اختيارات أنسب لصحتك ونمط حياتك في التمرين والروتين اليومي", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}, {"text": "مكالمات زوم والجلسة الحضورية (في المكثفة فقط)", "included": false}]', NULL, 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.', false, NULL, 'published', 1, false, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('2301cc8b-137e-422c-a6ad-93fdef4d3824', 'basic', 'follow', 'الباقة الأساسية', 'لمن يعرف يضبط أكله ويحتاج خطة تمرين فقط، ومتابعة كل أسبوعين', '[{"text": "ملف شامل للخطة التدريبية مع شروحات وافية للتمارين، بالمنزل أو بالنادي", "included": true}, {"text": "مناقشة كل أسبوعين لتطورك البدني والنفسي (فيديو أو تسجيل صوتي) مع تعديل التمرين عند الحاجة", "included": true}, {"text": "كتيب شامل للرياضة والتغذية", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}, {"text": "بدون خطة تغذية", "included": false}]', NULL, 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.', false, NULL, 'published', 2, false, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('1bcc0c77-60d5-4778-a183-3b1acff6666d', 'nutrition', 'follow', 'باقة التغذية', 'لمن يحتاج خطة تغذية شاملة ويتعلم حساب السعرات، بدون خطة تمرين', '[{"text": "خطة تغذية شاملة تناسب هدفك ونمط حياتك", "included": true}, {"text": "تحديد السعرات المناسبة لك ولهدفك", "included": true}, {"text": "تعليمك حسبة السعرات ومساعدتك باختيارات تغذية تناسبك", "included": true}, {"text": "ملف Excel لمتابعة التطور والقياسات", "included": true}, {"text": "مناقشة أسبوعية لعلاقتك بالتغذية في المنزل أو خارجه", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}, {"text": "لا تحتاجها إذا كنت مشتركاً في المكثفة أو المتقدمة، لأن التغذية ضمنها", "included": false}]', 'شهر واحد · غالباً لا تحتاج تجديد', 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي، ولا يوجد تجديد تلقائي. ضمان الاسترجاع يشمل اشتراكات 3 أشهر للمكثفة والمتقدمة والأساسية فقط.', false, NULL, 'published', 3, false, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('e8bcf578-9834-438c-bef9-33d2a16a137b', 'custom-training-plan', 'files', 'بديل التدريب الشخصي', 'لمن لا يحتاج متابعة (متقدم)، أو كبديل أوفر للتدريب الشخصي', '[{"text": "جدول تمرين مخصص لعدد أيام التمرين اللي تحتاجها", "included": true}, {"text": "طريقة حساب الجهد وعدد الجولات المطلوبة", "included": true}, {"text": "تقدر تحمّل الجدول على جهازك", "included": true}]', NULL, 'جدول مخصص بعد الاستبيان تستلمه كملف، وتقدر تحمّله على جهازك. بدون متابعة.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي. الجداول لك مدى الحياة وتقدر تعدّل عليها.', false, NULL, 'published', 4, false, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('12bd17c3-12d8-4dc8-85a6-4670640f69ba', 'training-nutrition-plan', 'files', 'جدول تمارين مع التغذية', 'لمن لا يحتاج متابعة (متقدم)، أو كبديل أوفر للتدريب الشخصي', '[{"text": "جدول تمرين مخصص لعدد أيام التمرين اللي تحتاجها", "included": true}, {"text": "طريقة حساب الجهد وعدد الجولات المطلوبة", "included": true}, {"text": "جدول تغذية فيه خيارات تناسب هدفك الرياضي", "included": true}, {"text": "تقدر تحمّل الجدول على جهازك", "included": true}]', NULL, 'جدول مخصص بعد الاستبيان تستلمه كملف، وتقدر تحمّله على جهازك. بدون متابعة.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي. الجداول لك مدى الحياة وتقدر تعدّل عليها.', false, NULL, 'published', 5, false, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('ba293475-8f02-4832-bbe2-f0ca9db76756', 'nutrition-consultation', 'consult', 'جلسة استشارة تغذية', 'لمن عنده أسئلة محددة في التغذية: جلسة وحدة تكفي لحسبة سعراتك ونصائح الأكل.', '[{"text": "مناقشة كل أسئلتك في مجال التغذية", "included": true}, {"text": "حسبة سعرات مناسبة لهدفك مع اقتراحات لأصناف الطعام", "included": true}, {"text": "نصائح في المكملات، وكيف تأكل برّا بطريقة صحيحة", "included": true}]', NULL, 'جلسة عبر Google Meet أو واتساب — المناسب لك.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي.', false, NULL, 'published', 6, false, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('c7d646a9-b854-42a6-8b20-fb868cf55ae5', 'training-consultation', 'consult', 'جلسة استشارة تمرين', 'لمن عنده أسئلة محددة في التمرين: جلسة وحدة تكفي لتعديل جدولك وتصحيح التكنيك.', '[{"text": "مناقشة كل أسئلتك في مجال التمرين", "included": true}, {"text": "تعديل جدولك الرياضي بما يناسب هدفك، مع اقتراحات لتمارين المرونة", "included": true}, {"text": "تصحيح تكنيك التمارين اللي تشك إنها غلط أو تسبب لك ألم", "included": true}, {"text": "التأكد من أن جودة تمرينك مناسبة للبناء العضلي", "included": true}]', NULL, 'جلسة عبر Google Meet أو واتساب — المناسب لك.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي.', false, NULL, 'published', 7, false, '2026-09-28 18:41:13.67219+00', '2026-09-28 18:41:13.67219+00', false) ON CONFLICT DO NOTHING;



INSERT INTO public.product_offers VALUES ('e790389b-c88d-42b2-9a72-3f49454ffd99', 'c9810dda-4672-41d5-8652-5df48fe4c425', 'int1', 'شهر واحد', 1, 59900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('62d76555-0589-4fa4-b572-021284611eb5', 'c9810dda-4672-41d5-8652-5df48fe4c425', 'int3', '3 أشهر', 3, 155000, 'SAR', true, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('ff472f09-51df-40cd-ba09-ffb6cb5a2888', '67a27488-eaf7-476e-b43a-d959582e46a6', 'adv1', 'شهر واحد', 1, 49900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('a8a2e06e-da3e-4cc9-9e99-4ca47176407b', '67a27488-eaf7-476e-b43a-d959582e46a6', 'adv3', '3 أشهر', 3, 125000, 'SAR', true, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('00bfcea5-2dc3-4ae4-aa8b-426f060c154c', '2301cc8b-137e-422c-a6ad-93fdef4d3824', 'bas1', 'شهر واحد', 1, 34900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('18147f5e-8c98-4832-8879-d73965e9ec8b', '2301cc8b-137e-422c-a6ad-93fdef4d3824', 'bas3', '3 أشهر', 3, 95000, 'SAR', true, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('1890eaef-a6a5-4d72-83f8-0f0da5da8807', '1bcc0c77-60d5-4778-a183-3b1acff6666d', 'nut1', 'شهر واحد', 1, 25000, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('d2b7b510-2bd4-424b-af0e-b8e8032de0db', 'e8bcf578-9834-438c-bef9-33d2a16a137b', 'diy', 'دفعة واحدة', 0, 19900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('2bd7a652-1258-4e82-ad8a-e3d5e64ef6d6', '12bd17c3-12d8-4dc8-85a6-4670640f69ba', 'diyN', 'دفعة واحدة', 0, 25000, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('b176a063-a612-48f4-926d-78d9024548b5', 'ba293475-8f02-4832-bbe2-f0ca9db76756', 'cN', 'دفعة واحدة', 0, 15000, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('ff7ce689-9975-492e-927e-2761964c3391', 'c7d646a9-b854-42a6-8b20-fb868cf55ae5', 'cT', 'دفعة واحدة', 0, 18900, 'SAR', true, 0) ON CONFLICT DO NOTHING;



INSERT INTO public.reviews VALUES ('9e63d294-d517-43fd-999c-86bc58bd4f14', 'legacy', NULL, NULL, NULL, NULL, 'اشتركت معها 3 شهور وكانت أول مره التزم بالتمرين بعد سحبات سنين، اسلوبها سهل وسريع بس نتايجه واضحه من اول اسبوعين قياسات جسمي بدت تتغير والكوتش مريحه نفسيًا وشاطرة الله يعطيها العافيه غيرت حياتي واعطتني افضل بداية 🙏🏻', 'first', 'ريم', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 0, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('cff049b5-d0b6-4c92-86d5-02b4578ec1a0', 'legacy', NULL, NULL, NULL, 5, 'من أصدق التجارب اللي مرّيت فيها! تدريبك ما كان بس جداول رياضه وتغذية كان دعم نفسي وتحفيز وتغيير حقيقي في حياتي حسّيت بفرق كبير في جسمي وطاقتي وثقتي بنفسي من أول أسبوع شكراً من القلب على تعبك وحرصك على كل تفصيلة وتعطي من قلبك، فعلاً you are the best coach ever تستاهلين كل النجاح والله ❤️', 'first', 'نورة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 1, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('76c25682-f1c5-4bf1-8a00-f4bd6bd1316d', 'legacy', NULL, NULL, NULL, 5, 'بعد شهر من الالتزام بالجدول، لاحظت فرق واضح! متنوع وفعال، أنصح فيه بشدة 😍👌', 'first', 'البندري', 'مارس 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 2, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('4d3a2a51-a9b6-439b-9f6f-6215ec6a5309', 'legacy', NULL, NULL, NULL, NULL, 'رغم ان فتره تدريبي معاها كانت اقل من شهرين السنه الماضيه الا ان نتايج هالشهرين مستمره معي الى اليوم 😍 اسلوب احترافي وفعال وتركز على بناء وتطوير عادات تدوم مو بس تمارين مؤقته 👍🏻', 'first', 'خديجة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 3, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('caad0cb2-0b80-4c36-b080-a0efa54afa2d', 'legacy', NULL, NULL, NULL, 5, 'كوتش ساره جداً شاطره و بروفيشنال، جداً متعاونه و تعرف شغلها كويس، جداً لطيفه، كنت لفتره متدربه عندها و كنت أشوف نتايج بطله بالاضافه لكوني اروح اتمرن و أنا مستمتعه، شكراً ساره', 'first', 'نجمة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 4, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('ccdc8d9b-3c5e-4707-9208-fdfcd745bfb6', 'legacy', NULL, NULL, NULL, 5, 'ممتاز جدول حلو ومرتب جدا وفرق معي كثير 🤍', 'first', 'سعود', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 5, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('cffca6b0-1f30-4faf-8f04-d4b7fc213f80', 'legacy', NULL, NULL, NULL, 5, 'كنت اعاني من الم بظهري مستمررر سنوات وانحراف بالعمود ولكن بفضل الله ثم المدربة تحسنت بنسبة كبيرة وتابع معي خطوة بخطوة بكل أمانة وإتقان الله يكثر من امثالك 🤍', 'first', 'ش**س**', 'أغسطس 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 6, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('74836102-9866-43c6-880b-b2e7ff43fbfc', 'legacy', NULL, NULL, NULL, 5, 'الشكر يعجز عنك يااروع كوتش باشتراكي معك شفت صحة وراحة بعد الله وساعدتيني مره بمشكلة ظهري وضعف العضلات العلوية وانعكس على نفسيتي وادائي اليومي شكررا شكرا من القلب وياحظنا فيك', 'first', 'فاطمة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 7, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('6ceab646-44d1-4ea2-9ef4-17f3ee67e350', 'legacy', NULL, NULL, NULL, 5, 'مره استفدت بالتدريب مع كوتش ناف و مبسوطه ان في احد بذمة و ضمير جالس يتابع تقدمي و ينصحني من قلب الله يسعدك ويوفقك ❤️', 'first', 'ميثاء', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 8, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('30ec9a14-eb0d-4843-baf2-06fe52994634', 'legacy', NULL, NULL, NULL, 5, 'تجربه ولا أروع ! أحب جداولها وقد ايش تختصر وتعطيك المهم والاهم والنتايج رهيييبه ❤️', 'first', 'أمجاد', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 9, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('4e644a65-0a2f-451a-ac34-8f4ac512b758', 'legacy', NULL, NULL, NULL, 5, 'افضل مدربة بالمجرة، كنت دبه ونحفت بثلاث شهور بس، i highly recommend her she is the best 💗', 'first', 'شروق', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 10, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('6a2750bc-e2dc-483f-ad71-a93dea04cbe6', 'legacy', NULL, NULL, NULL, 5, 'الجدول ممتاز و فعّال لفترة الصيام، يساعدك تنظم وقتك ويقدّم توصيات غذائيه و خطه تمارين تساعدك تحافظ على لياقتك بدون إرهاق 👍🏻. خيار ممتاز خاصة للأشخاص للي وقتها محدود ومزحوم فرمضان.', 'first', 'خديجة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 11, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;



INSERT INTO public.site_settings VALUES ('reminders', '{"review_text": "مرحباً {name}، تذكير بمراجعتك الأسبوعية: المراجعة مفتوحة من {window_start} إلى {window_end}.", "sub_expiry_days": [7, 3], "sub_expiry_text": "مرحباً {name}، اشتراكك في {product} ينتهي بتاريخ {end_date}. للتجديد أو الاستفسار تواصل معنا.", "review_lead_days": 1, "missed_review_text": "مرحباً {name}، ما وصلتنا مراجعة الأسبوع المنتهي في {window_end}. متى ما تيسّر لك، حدّثها عشان نتابع تقدمك.", "review_window_days": 2, "manual_cooldown_minutes": 10}', false, NULL, '2026-09-28 18:41:13.132153+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('hero', '{"lead": "خطة تدريب وغذاء منظمة، متابعة للتقدم، وتعديلات أسبوعية تناسب مستواك وظروفك.", "title": "برامج تدريب وتغذية مخصصة لأهدافك", "eyebrow": "Nav Coaching · الكوتش ساره", "tagline": "Where Passion Meets Quality", "title_tail": "تحت إشراف مدربة يدفعها الشغف"}', true, NULL, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('badges', '["خصم 10% للطلاب", "مجاني لأهل غزة", "ضمان استرجاع المبلغ بشروط"]', true, NULL, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('why', '[{"body": "البرنامج يُصمم بعد استبيان مفصل لهدفك وأيامك المتاحة وأدواتك وأي إصابة تحتاج مراعاة.", "title": "مبني على هدفك ومستواك"}, {"body": "مراجعة منتظمة بالفيديو أو الصوت، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.", "title": "متابعة أسبوعية واضحة"}, {"body": "نعدّل التمرين والسعرات بناءً على قياساتك والتزامك، عشان تثبت النتيجة.", "title": "تعديلات حسب تقدمك"}]', true, NULL, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('how_steps', '[{"body": "اختر الباقة والمدة، وعبّي استبيان قصير عن هدفك ومستواك وأيامك وأي إصابة.", "title": "اختر برنامجك وعبّي الاستبيان"}, {"body": "بعد الاستبيان يظهر لك رقم طلبك وبيانات الحساب. حوّل وارفع صورة الإيصال من صفحة طلبك.", "title": "حوّل المبلغ"}, {"body": "بعد التحقق من التحويل أتواصل معك خلال 48 ساعة عمل، وتستلم ملف برنامجك وتبدأ المتابعة.", "title": "استلم برنامجك وابدأ"}]', true, NULL, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('about', '{"bio": "مدربة شخصية معتمدة، أدرب منذ 2017. أساعدك تبني روتين تدريب وتغذية واضح يناسب هدفك ووقتك ومستواك، مع متابعة أسبوعية تساعدك تستمر وتتقدم.", "fit": ["اللي يؤمن إن التمرين أسلوب حياة، مو تمرين لشكل مؤقت أو لفترة الصيف بس.", "**وإذا ما التزمت؟** أحاول أفهم أسبابك، وأساعدك تعالجها بقدر ما أقدر. وإذا كان الموضوع أكبر من اللي أقدر أقدمه، أقول لك بصراحة وأعتذر عن تدريبك."], "name": "الكوتش ساره | ناڤ", "certs": ["Saudi Reps — Level 4", "NCSF", "Menno Henselmans CPT", "Functional Mobility", "Pre & Postnatal Training", "Prenatal Fitness Training — Aspire Academy", "ماجستير تدريب رياضي — جامعة ستيرلنق"], "notes": [{"body": "لأني جاية من عالم الرياضات الإلكترونية، صممت باقة خاصة للقيمرز: لياقة أفضل داخل وخارج الشاشة، والتعامل مع آلام الظهر والمفاصل من الجلوس الطويل.", "href": "/programs/gamers", "label": "شوف باقة القيمرز ←", "title": "للاعبي الألعاب الإلكترونية"}, {"body": "تدريب الحوامل عندي حضوري فقط. أونلاين يصعب أتأكد إن التمرين يتنفذ بإتقان، والحمل فترة مهمة جداً تحتاج هالتأكد. أونلاين أقدم للحوامل متابعة التغذية فقط.", "href": "", "label": "", "title": "للحوامل"}], "story": ["قبل ما أصير مدربة، كنت متدربة تعبت من التجارب. اشتركت مع مدربات أجانب، وما لقيت أحد يشرح لي التمرين صح أو يهتم بأهدافي.", "لين اشتركت مع الكوتش سحر الحارثي. غيّرت نظرتي للتمرين، وحفّزتني أصير كوتش، وإلى اليوم أشكرها على كل اللي علمتني إياه. من هنا قررت أكون الشخص اللي احتجته أنا.", "والرياضة جزء مني من بدري: لعبت كرة السلة وكنت كابتن فريق السلة في جامعة الإمام عبدالرحمن بن فيصل، ولعبت باحتراف في الرياضات الإلكترونية. بدأت التدريب في 2017 مع كرة السلة، واشتغلت مساعد مدرب في نادي الجامعة، وبعدها دربت في بيور جم وجمنيشن وفتنس لاونج ونوادي خاصة."], "points": ["برنامج مبني على هدفك ومستواك.", "متابعة أسبوعية واضحة.", "تعديلات مستمرة حسب تقدمك والتزامك."], "pillars": [{"body": "ما أرسل لك جدول وأتركك. أراجعه معك بمقطع فيديو أشرح فيه كل شي، عشان تبدأ وأنت فاهم وش تسوي وليش.", "title": "جدولك مشروح بالفيديو"}, {"body": "ما أمشي على أنظمة الحرمان أبداً. خطتك تناسب حياتك، مو قائمة ممنوعات.", "title": "بدون حرمان"}, {"body": "أتابعك كل أسبوع وأهتم بالتزامك، وأعدّل خطتك حسب تقدمك وظروفك.", "title": "متابعة جادة وخطة واقعية"}, {"body": "حب تعليم الناس معي من الصغر. اللي أعرفه ما أبخل فيه، علمياً ونفسياً، وما أوقف عن البحث والتعلم عشان أتطور وأطورك معي.", "title": "أعلّمك، مو بس أدربك"}], "home_bio": "مدربة شخصية معتمدة، أدرب منذ 2017، وكابتن سابقة لفريق السلة في جامعة الإمام عبدالرحمن بن فيصل. أساعدك تبني روتين تدريب وتغذية واضح يناسب هدفك ووقتك ومستواك، مع متابعة أسبوعية وبدون أنظمة حرمان.", "fit_title": "أكثر شخص أفرق معه", "experience": ["أدرب منذ 2017، والبداية في كرة السلة.", "مساعد مدرب في نادي الجامعة.", "مدربة في بيور جم، وجمنيشن، وفتنس لاونج، ونوادي خاصة."], "story_title": "صرت الشخص اللي كنت أحتاجه", "pillars_title": "وش يميز التدريب معي؟", "experience_title": "شهاداتي وخبرتي"}', true, NULL, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('intro_video', '{"url": "", "body": "مقطع قصير أتكلم فيه عن نفسي وخلفيتي وطريقة شغلي مع المتدربين.", "title": "تعرّف عليّ في دقيقة"}', true, NULL, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('testimonials_disclaimer', '"التجارب شخصية وتختلف النتائج من شخص لآخر حسب الالتزام والحالة، والتدريب لا يغني عن استشارة الطبيب أو أخصائي العلاج الطبيعي."', true, NULL, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('prices_note', '"الأسعار بالريال السعودي. الدفع بتحويل بنكي على حساب المؤسسة."', true, NULL, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('checkins', '{"enabled": true, "questions": [{"q": "ملاحظاتك الصحية؟ الحركة اليومية وجودة الحياة صارت أحسن؟", "topic": "الصحة العامة"}, {"q": "أداؤك في التمارين؟ في تقدم في الأوزان والأداء؟", "topic": "التمارين"}, {"q": "فرق في شكلك ومظهرك؟ إيجابي أو سلبي؟", "topic": "المظهر"}, {"q": "فرق في الملابس أو المقاسات؟ إيجابي أو سلبي؟", "topic": "الملابس"}, {"q": "النظام الغذائي — قدرت تمشي عليه؟ فيه صعوبة؟", "topic": "الغذاء"}, {"q": "تحسّ بالجوع واجد؟ إن وُجد، كم تعطيه من 5؟", "topic": "الجوع"}, {"q": "أي ملاحظات سلبية تبي تشاركها؟ (مهمة أو بسيطة — نتقبل النقد)", "topic": "ملاحظات سلبية"}, {"q": "أي إشكاليات أو ملاحظات إضافية تحتاج مساعدة فيها؟", "topic": "ملاحظات أخرى"}, {"q": "وصلت لأي أسبوع تدريبي الآن؟", "topic": "الأسبوع"}]}', true, NULL, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('contact', '{"whatsapp": "966599162724", "instagram": "https://www.instagram.com/navvcoaching/"}', true, NULL, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('response_time', '"48 ساعة عمل (الأحد – الخميس، 12 ظهراً – 9 مساءً)"', true, NULL, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('legal', '{"cr": "7050950752", "name": "مؤسسة ناف كوتشنق للتدريب الرياضي"}', true, NULL, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('bank', '{"iban": "SA1280000139608016245411", "bankName": "مصرف الراجحي", "accountName": "مؤسسة ناف كوتشنق للتدريب الرياضي"}', true, NULL, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('program_shots', '[{"h": 720, "w": 754, "alt": "لقطة من صفحة «حسابي» ببيانات مثال: شريط الالتزام، أيام تمرين الأسبوع الحالي، ملخص تغذية اليوم، وروتين المكملات", "src": "shots/my-program.webp", "title": "برنامجي", "caption": "أول ما تدخل حسابك: نسبة التزامك وأسابيعك المتتالية، أيام تمرين الأسبوع، تغذية اليوم مقابل أهدافك، وروتين المكملات."}, {"h": 960, "w": 1148, "alt": "لقطة من صفحة برنامج التمرين ببيانات مثال: أيام الأسبوع، وبطاقة كل تمرين مع المستهدف وخانات الوزن والتكرارات وRIR", "src": "shots/training-log.webp", "title": "تسجيل التمرين", "caption": "لكل تمرين المستهدف من الجولات والتكرارات وRIR، وتسجّل وزنك وتكراراتك من جوالك، ولك تبديله ببديل تختاره المدربة."}, {"h": 1020, "w": 1148, "alt": "لقطة من صفحة التغذية ببيانات مثال: ملخص اليوم مقابل الأهداف، ونموذج إضافة أكلة، وأكل اليوم حسب الوجبات", "src": "shots/nutrition-day.webp", "title": "التغذية اليومية", "caption": "أهدافك اليومية من السعرات والماكروز وكم باقي لك، وتسجّل أكلك من جداولك الغذائية أو بالغرام من قاعدة الأكل."}, {"h": 307, "w": 1116, "alt": "لقطة من لوحة التقدم ببيانات مثال: رسم الوزن ورسم القياسات", "src": "shots/progress-charts.webp", "title": "لوحة التقدم", "caption": "وزنك وقياساتك برسوم واضحة أسبوعاً بأسبوع، ببيانات مثال."}]', true, NULL, '2026-09-28 18:41:13.67219+00') ON CONFLICT DO NOTHING;
COMMIT;
