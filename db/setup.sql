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
INSERT INTO public.exercises VALUES ('59bdcca6-40cc-4075-b32f-82aa15adaa11', 'Back Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/bEv6CCg2BC8', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('49938c2e-ea1a-4457-ba87-9aae6ed90d05', 'Box Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtube.com/shorts/9uhEh9gpwUU?si=xaTY7AJiCeQfa3by', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل.', 'تعليمات بديلة في المصدر (صف 13): ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل، انزل واثبت على البوكس ثانية وارفع.', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('46ec9a3e-e6d8-46a1-a214-60f8d6d5a95f', 'Hack Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/0tn5K9NlCfo', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Machine Squat / سكوات بالجهاز', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('74f92f70-5d8a-47c6-97d4-e92e95b83b46', 'Mid Leg Press', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/s9-zeWzPUmA', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Leg Press / ضغط الأرجل', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('449d498f-7c20-49d5-a06d-36166f892b9d', 'Quads Leg Press', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/A218isnErfM', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي، ثبت القدمين أسفل اللوح لاستهداف أكبر للكوادز.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Leg Press / ضغط الأرجل', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f366fad7-2dfe-4829-8f71-8f767524c0c5', 'Deficit Goblet Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/9719SO5zvpU?si=whohbunAsXkH3j6f', 'وقف باتساع اكتافك تقريبًا، ادفع ركبك للامام وانزل، انزل لأقصى حد تقدر عليه بدون ما يتقوس ظهرك السفلي.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('757066d3-e325-43c1-872d-0b0e4ca27e49', 'Front Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'بار', 'متوسط', 'نادي', NULL, 'ثبت البار على الأكتاف، ادفع ركبك للامام وانزل.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b0a2789d-ca22-4811-822f-252f6c5b3b9d', 'V Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://www.youtube.com/watch?v=u_GSjH58s0g', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Machine Squat / سكوات بالجهاز', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d408fdc4-7f66-4077-b690-895987f359ff', 'Resistance Band Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/6rE0IYlMPZA?si=goqtRTlR_W4HSGBN', 'ثبت الباند علي جوانب اكتافك، ادفع ركبك للأمام وإنزل.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1a89c394-141c-4527-9e7a-9de8a66b47d6', 'Squat Smith Machine', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/oBwhrRcNWyM', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Machine Squat / سكوات بالجهاز', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ebcb428a-ed74-4478-ab6e-bec5ce73c3cc', 'Single Leg Press', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/ZYDTJaAM-gE', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Single-leg Press / ضغط رجل واحدة', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('99ac9e6a-2be1-434d-8077-c4f06813c064', 'Drop Lunges', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/WH8lteLrMIs?si=61QSVA7iw_Z6Zr3p', 'تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f2536b24-9ed7-4d99-94a9-945728e1dc50', 'Beginner Lunges', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/QOVaHwm-Q6U', 'تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a0651b82-2757-42ca-bbda-0f59168ec008', 'Forward Lunges', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/_DLAdo2Pvjs', 'تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness | ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b16dbf7f-d33d-4f09-8625-e560b07131dd', 'Supported BSS', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/poBie3TTeGE?si=QSiMUYtcHhrmg8mx', 'وقف عند البنش او الستيب، ارفع رجلك وثبت اصابع قدمك على البنش، خذ خطوة وحدة للأمام برجلك الثانية ثم ابدأ التمرين، تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Split Squat / سبليت سكوات', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('11317970-ac8f-4c13-818b-e63b47d6c94c', 'Supported Reverse Lunge', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/WH8lteLrMIs?si=M9s9a7qOVvvyDm82', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('853950b8-faa7-4acc-be42-338e1ad6fec2', 'Smith Machine Reverse Lunge', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/zAVYcwnlxrQ?si=M5HL4sG-bsYBFyDQ', 'استخدم ارتفاع بسيط مثل الستيب ، ارفع نفسك بالضغط علي الرجل المرفوعة بتحكم بدون قفز.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('679e569a-80ab-41e9-86ee-c929df41a088', 'Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/gtZ4AwZVtMI', 'اجلس وثبت ظهرك السفلي كويس، تأكد ان مسمار الارتفاع يكون بمستوى ركبتك، امسك المقابض لزيادة الثبات، إرفع الوزن اثبت ثانية فوق ثم انزل نزول كامل بتحكم.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('bb44dee0-bd60-4f4a-8ca3-17a5f544f1c5', 'Single Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/82IuSLk5zNc?si=FTMqZrmawQFRr8dN', 'اجلس وثبت ظهرك السفلي كويس، تأكد ان مسمار الارتفاع يكون بمستوى ركبتك، امسك المقابض لزيادة الثبات، إرفع الوزن اثبت ثانية فوق ثم انزل نزول كامل بتحكم.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f4711051-8eb7-4cd0-885d-e3ae3c9268a4', 'Band Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/hs7D3gDw3UM', 'اجلس وثبت ظهرك السفلي كويس وامسك الكرسي للثبات، اثبت ثانية فوق ثم انزل نزول كامل بتحكم.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('22e3f4b6-df2b-461e-bb20-6c4fa1afd356', 'Standing Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/fyF6FQOUGDI', 'الحركة كلها بثني ومد الركبة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c87a85ba-2fe0-42c9-b771-31c2d0a12c53', 'Sissy Squat', 'Quadriceps / الأمامية', '{"Adductors / الأفخاذ الداخلية"}', 'Knee Extension / مد الركبة', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://youtu.be/yONKTprKCDA', 'الورك ثابت طول الجولة والحركة كلها من مفصل الركبة، اذا توازنك يخرب عليك ادبل الوزن بيد واليد الثانية امسك فيها جدار او عصى', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Sissy Squat / سيسي سكوات', 'Knee Extension / مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8949d898-6a4e-4397-8529-3ef96cb65c75', 'Cable Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/ebjD98gZd8E', 'اجلس وثبت ظهرك السفلي كويس وامسك الكرسي للثبات، اثبت ثانية فوق ثم انزل نزول كامل بتحكم.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1e3cf9ee-5435-40b2-94a7-76db653a5f3d', 'Standing Leg Extension', 'Quadriceps / الأمامية', '{"Core / البطن والكور"}', 'Knee Extension / مد الركبة', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/133/standing-leg-extension/', NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e3186677-d366-4dab-b010-097f05ebce45', 'Bodyweight Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Lower back / أسفل الظهر"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/135/bodyweight-squat/', NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e6846da6-016e-4da7-a92a-2c81f3f8dcf9', 'Single Leg Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'وزن الجسم', 'متقدم', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/136/single-leg-squat/', 'ضعف الألوية الكبرى / Gluteus Maximus Weakness | ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Single-leg Squat / سكوات رجل واحدة', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1c9586ef-4b5b-4cb6-b297-c2f207a5f83d', 'DB Glutes Step Ups', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/GCnJiYJfboA?feature=share', 'استخدم ارتفاع يكون بحدود ارتفاع ركبتك أو أقل، ارفع نفسك بالضغط علي الرجل المرفوعة بتحكم بدون قفز.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5303dd6c-34de-4b6f-b388-45d7b7d97dfe', 'Supported Glutes Step Ups', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/ZKzoOkQALaY?si=-56txwBlxSSCQYJd', 'استخدم ارتفاع يكون بحدود ارتفاع ركبتك أو أقل، ارفع نفسك بالضغط علي الرجل المرفوعة بتحكم بدون قفز.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('839d8a61-5e7f-4b31-9a10-1d6164067302', 'Cable Glutes Step Ups', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c6428037-8c1a-47b4-acf4-8d9877e4d192', 'Glute Pushdown', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/8h2kZ64Sp5k?si=NLPf4tywxhDGY9em', 'تمسك بمقابض الجهاز، (كل ما زاد ارتفاع البنش زادت الصعوبة) + الطلوع والنزول يكون بواسطة القدم المرفوعة على البنش مو بالقدم اللي تحت، ارفع بتحكم الى أقصى ارتفاع تقدرعليه بدون ما يتقوس ظهرك السفلي، انزل لحد ما تقفل ركبتك تماما', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('894061a6-00e6-4563-9a74-d0f4a8219e6f', 'Glute Max Kickbacks', 'Glutes / المؤخرة', '{}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/t5mwSx4uNMc?feature=share', 'ثبت الحبل على الكاحل، ارجع خطوة للخلف وانحني للامام قليلاً وتمسك بالكيبل لزيادة الثبات، اسحب للخلف مع انثناء بسيط بالركب.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Kickback / ركلة خلفية', 'Hip Extension / بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d5212195-338c-4708-bbbe-3791fcd758c7', 'Hip Abduction', 'Abductors / مبعدات الفخذ', '{"Glutes / المؤخرة"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/_ARUxqrII3Y?si=Jcz5uh2Uu-IdVCS1', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1000226b-ca06-469e-801b-1681d398f742', 'Smith Machine Kickback', 'Glutes / المؤخرة', '{}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/GR4ny80bmhM?si=WeZcWM1hyfoLElM2', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Kickback / ركلة خلفية', 'Hip Extension / بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6987fbc1-6f31-497d-bd26-089fd8febd6e', 'Glute Medius Kickbacks', 'Abductors / مبعدات الفخذ', '{"Glutes / المؤخرة"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/kccsnZNbMFA?si=6c-VoB8Zsz8NxoyM', 'ثبت الحبل على الكاحل، ارجع خطوة للخلف وانحني للامام قليلاً وتمسك بالكيبل لزيادة الثبات، اسحب للخلف وللخارج مع انثناء بسيط بالركب.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Abduction Kickback / ركلة خلفية مع تبعيد', 'Hip Abduction + Hip Extension / تبعيد الورك + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a37021a2-dc38-4ac4-b709-f688866416b0', 'Side Step Up', 'Glutes / المؤخرة', '{"Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/xOwIRnI4VxA?si=SJOgODRmNGdfHPb4', 'يد فيها الوزن واليد الثانية سندها على الجدار', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية المتوسطة / Gluteus Medius Weakness | ضعف الألوية الصغرى / Gluteus Minimus Weakness', 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f1719b2e-03ae-4ce6-b037-01d3f958e86b', 'Hip Thrusts Machine', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/0xfdeCBwoYw?si=HgJcNeB0a24gODkK', 'ممكن تسويه بالسميث مشين او البار الحر ، اختر بوكس او بنش يكون بمستوى اكتافك الخلفية وانت جالس، لما ترفع البار فوق المفروض ركبك تكون بنفس مستوى القدم.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2ff6f83f-aaf5-4360-9885-8a81ce3bfd4c', 'Hip Thrusts', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/O0EoaP7gR1A?si=cGPZ8iIwM2mQjwSb', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a9201dc3-6efd-4cc5-89bf-9218e46ab278', 'Glute Bridge', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', NULL, 'مبتدئ', NULL, 'https://www.youtube.com/watch?v=dtlGynVdHYM', 'ممكن تسويه بالسميث مشين او البار الحر ، اختر بوكس او بنش يكون بمستوى اكتافك الخلفية وانت جالس، لما ترفع البار فوق المفروض ركبك تكون بنفس مستوى القدم.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness | آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5f0b1fc8-bb6a-4d3c-b893-b52b7dcc0055', 'DB Floor Glute Bridge', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/iOrJXNUH3to?si=JySX6JMhoP2vWEVa', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness', 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('346479c6-e553-473d-83b6-23984d575ebd', 'Glute Raise', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/X_kL_x4m77c', 'ثبت رجولك تحت، الاسفنجة تكون تحت الورك أعلى الفخذ مو على الورك مباشرة، امسك وزن بيدينك بذراع مستقيمة، ارفع وكأنك تبي تدخل القلوتس جوا الاسفنجة، بمجرد ما تنقبض مؤخرتك وقف لا ترفع أكثر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', '45° Hip Extension / بسط الورك على جهاز الظهر', 'Hip Extension / بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2e0518c5-9b1c-47d2-ab4f-349d9ffe95c5', 'Single Hip Thrusts', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/ymg2AMDAwrY?si=fY8kBPTDYWRMHuAs', 'اختر بوكس او بنش يكون بمستوى اكتافك الخلفية وانت جالس، لما ترفع فوق المفروض ركبك تكون بنفس مستوى القدم، التمرين صعب طبيعي تواجه صعوبة بالبداية لذلك لا تستعجل باضافة الاوزان', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('11478028-d875-4975-bc1c-22547440c675', 'Glute Press', 'Glutes / المؤخرة', '{}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/293/glute-press/', NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Kickback / ركلة خلفية', 'Hip Extension + Knee Extension / بسط الورك + مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ab1b2f8b-9406-4b39-8c2e-c0b7b7e665aa', 'Bulgarian Split Squat', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/366/bulgarian-split-squat/', NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Split Squat / سبليت سكوات', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2c645aa5-fcf7-4c55-952a-00efdb93e362', 'Sumo Deadlift', 'Hamstrings / الخلفية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://www.youtube.com/watch?v=cDlOSfu-zHY', 'وقف بفتحة أرجل واسعة بحيث الركب تكون خط مستقيم مع كعب القدم و اصابع الرجل باتجاه الخارج، البار بمنتصف القدم، شد ظهرك العلوي وادفع الارض برجولك واسحب البار للأعلى، وقف لما تنقبض مؤخرتك ولا تبالغ بتقفيل حوضك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Deadlift / ديدلفت', 'Hip Extension + Knee Extension / بسط الورك + مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c44cd8c0-90a7-40dc-aa5a-e0e6ca70f32e', 'DB Lying Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/ZHlBSI6JPsA?si=SpBiHxluwrYE8CTP', 'ركبك ثابته على الارض، ارفع الوزن بثني ومد الركبة بدون ما يرتفع حوضك', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('df9370e2-8766-423e-872b-492481c39e5e', 'Conventional Deadlift', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/GxsLrTzyGUU', 'وقف باتساع اكتافك أو أوسع شوي، البار بمنتصف القدم، شد ظهرك العلوي وادفع الارض برجولك واسحب البار للأعلى، وقف لما تنقبض مؤخرتك ولا تبالغ بتقفيل حوضك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Deadlift / ديدلفت', 'Hip Extension + Knee Extension / بسط الورك + مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f1450a30-ff11-47f1-b94b-48884a641628', 'BB RDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/mZxxJEncsyw', 'وقف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، انزل وادفع مؤخرتك لآخر شي تقدر عليه للخلف وكأنك بتلمس جدار خلفك مع انثناء بسيط بالركب', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('31bc2147-9b7d-436d-8c9a-882d0d19d531', 'DB RDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/RApyTtH6qAo', 'وقف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، انزل وادفع مؤخرتك لآخر شي تقدر عليه للخلف وكأنك بتلمس جدار خلفك مع انثناء بسيط بالركب', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c56b6734-1a78-443d-86b0-10689f0faf6f', 'SM SLDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/qlL1wnpLQj4?si=-jD_X6mIJkkI8SwX', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c011b0c4-82e1-4660-8007-185c3fa20cb5', 'Single DB RDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/U3prDlAbJDw?si=MRSBcSIcf9M-WQBH', 'وقف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، انزل وادفع مؤخرتك لآخر شي تقدر عليه للخلف وكأنك بتلمس جدار خلفك مع انثناء بسيط بالركب', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness', 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6ec77b27-0d18-4e92-9a5f-656c59b46941', 'SLDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/RApyTtH6qAo', 'قف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، ابدأ الحركة بدفع مؤخرتك للخلف والأعلى وانزل', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0bd67926-0d76-4d08-9321-0fc9d891fd8f', 'Single DB SLDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/U3prDlAbJDw?si=MRSBcSIcf9M-WQBH', 'قف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، ابدأ الحركة بدفع مؤخرتك للخلف والأعلى وانزل', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('28767603-fb98-4809-bf5a-7275fb381e81', 'Good Morning', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/f23vXjoG2e8?si=9rkfUF_6XUEcQ3Xs', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع مؤخرتك لأقصى قدر تقدر عليه وكأنك بتلمس جدار خلفك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Good Morning / قود مورنينق', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('364c7ccb-df98-4975-b6de-7ecf9216adf9', 'Seated Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/o_J6MWyt5jM', 'اجلس على الكرسي وثبت ظهرك السفلي على المقعد تمامًا، انزل لأقصى حد تقدر عليه وارفع لحد ما تستقيم ركبتك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('dc1f23bd-aaa8-4ac2-9677-69c845e3fe60', 'Band Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/I-HTMUrJnxs', 'ثبت الباند فوق الكعب، اجلس على طرف البنش وتمسك بيدينك لزيادة الثبات، اسحب الحبل لاقصى حد تقدر عليه واترك رجلك تستقيم تمامًا في الانبساط.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3a369231-0454-431e-9e3b-ab822ca20144', 'Lying Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/vl5nUdE9mWM', 'حوضك ثابت على البنش، ارفع الوزن بثني ومد الركبة بدون ما يرتفع حوضك عن الكرسي', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7731f184-af43-4e35-87d6-6c28566a50f2', 'Cable Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/mBJXWg8ZOy0', 'اجلس على الكرسي وثبت ظهرك السفلي على المقعد تمامًا، ممكن تقدّم ظهرك العلوي وتمسك المقابض لزيادة الثبات، انزل لأقصى حد تقدر عليه وارفع لحد ما تستقيم ركبتك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('edb97e21-ca32-4cf0-b920-0e52bbcf5318', 'Supine Cable Hamstring Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/sDCc1F5J8XA?si=Fi3D39aJogrB5ihd', 'الركبة ثبت مكانها، اسحب الحبل لاقصى حد تقدر عليه واترك رجلك تستقيم تمامًا في الانبساط.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4977e165-93a6-4a15-80b1-2b301db1e060', 'Nordic Hamstring Curl', 'Hamstrings / الخلفية', '{}', 'Knee Flexion / ثني الركبة', 'قوة', 'وزن الجسم', 'متقدم', 'بدون معدات', 'https://youtu.be/Lgibr8od0yA?si=nfRetEkDRk55Bu0a', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Nordic (Eccentric) / نوردك (لامركزي)', 'Knee Flexion / ثني الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8da145ec-8904-414f-9e49-d73990479f9d', 'Stability Ball Hamstring Curl', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة"}', 'Knee Flexion / ثني الركبة', 'قوة', 'كرة سويسرية', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/59/stability-ball-hamstring-curl/', NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Bridge Curl / ثني الركبة مع رفع الورك', 'Knee Flexion + Hip Extension / ثني الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4421f971-8e7b-489c-a7b9-a92bfa2fbb80', 'Hip Hinge', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/33/hip-hinge/', NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Hinge Drill / تمرين مفصلة الورك', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('bc3ad3ee-6912-43e5-b1b4-b336d3beb5cc', 'TRX Hamstrings Curl', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة"}', 'Knee Flexion / ثني الركبة', 'قوة', 'TRX', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/86/trx-reg-hamstrings-curl/', NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Bridge Curl / ثني الركبة مع رفع الورك', 'Knee Flexion + Hip Extension / ثني الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7dc7a1da-135e-43c2-b6c8-c67f1075243b', 'Flat DB Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/xphvjGDZeYE', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('84c1f552-b912-4208-b48d-1c27e4d9eb2b', 'DB Floor Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/UBmpZ7l5Nlk?si=kDcN-ueaTFxfKtbr', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a6b409f1-eea9-40b0-880c-ac07e1e49e2a', 'Flat Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/vcBig73ojpE', 'استلق على بنش،القبضة بنفس مستوى الاكتاف أو أوسع قليلًا، قوّس ظهرك العلوي قليلاً، انزل لين تلمس صدرك واثبت ثانية ثم ارفع.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7d1e4f0c-6928-46d0-9cb5-28142b363eb9', 'Machine Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/pOCRC2kpxB8?si=02xGtrfPjiYpspMv', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('48a640bc-19d3-49c4-8ff6-f0b84ea6ff49', 'Feet Up Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/HrehfM1dmBE', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('98cacd58-9cc0-4831-9561-c11115ed0b7a', 'Torso Elevated Push Up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/noaPB7u4_CU', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا', 'تصنيف فرعي: اليدان مرفوعتان؛ زاوية الضغط بالنسبة للجذع تشبه الضغط المائل لأسفل رغم تسميته الشائعة Incline Push-up — يحدده المدرب', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Decline Press / ضغط مائل لأسفل', 'Horizontal Adduction + Shoulder Extension / تقريب أفقي + مد الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('11f5c383-b2d6-4bb9-963c-94d96ef41fc7', 'Push Up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://youtu.be/WDIpL0pjun0?si=utydS_A8QfRIJtJm', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a7ebfc73-ce55-4009-9d94-247c69c5a08f', 'Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://www.youtube.com/watch?v=JvOJdUtx6UQ', 'استلق على بنش،القبضة بنفس مستوى الاكتاف أو أوسع قليلًا، قوّس ظهرك العلوي قليلاً، انزل لين تلمس صدرك واثبت ثانية ثم ارفع.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('39b1c8ad-d6cf-44b1-ae88-5b33e1fb55b0', 'Paused Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://www.youtube.com/shorts/Q3GmnmJISwE', 'استلق على بنش،القبضة بنفس مستوى الاكتاف أو أوسع قليلًا، قوّس ظهرك العلوي قليلاً، انزل لين تلمس صدرك واثبت 3 ثواني ثم ارفع.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d6d107e9-f41f-4d52-a01a-c963d3d91cf6', 'Incline Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/0G2_XV7slIg', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Incline Press / ضغط مائل لأعلى', 'Shoulder Flexion + Horizontal Adduction / ثني الكتف + تقريب أفقي', 'Incline Press / ضغط مائل لأعلى') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3be394f2-9365-453f-b8af-1bcdf9e8ebcd', 'Smith Machine Incline Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/EeLLZMdg6zI?si=UVsgFN7jhXMm0vW3', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Incline Press / ضغط مائل لأعلى', 'Shoulder Flexion + Horizontal Adduction / ثني الكتف + تقريب أفقي', 'Incline Press / ضغط مائل لأعلى') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cd88b969-267e-4090-9fc4-f0b321f362db', 'Cable Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/tAILewhtCb0', 'اجلس على بنش انكلاين، اضبط الكيبل بمستوى صدرك تقريبا، ادفع الوزن للأمام باتجاه الداخل، احرص ان كوعك ما يكون بنفس ارتفاع كتفك', 'تصنيف فرعي: التعليمات تذكر بنش انكلاين، وتصنيف المصدر iso_push_chest — يُحسم بين Incline Press وعزل الصدر', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Incline Press / ضغط مائل لأعلى', 'Shoulder Flexion + Horizontal Adduction / ثني الكتف + تقريب أفقي', 'Incline Press / ضغط مائل لأعلى') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('90aed34a-6299-4b8a-baf4-2b09e920f494', 'Sternal Cable Press Around', 'Chest / الصدر', '{}', 'Horizontal Push / دفع أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/y8XQibXDnNo', 'اضبط الكيبل بمستوى صدرك تقريبا، حافظ على ذراعك قريبة من جسمك،ادفع الحبل للأمام باتجاه الداخل.', 'تصنيف فرعي: حركة مختلطة بين الضغط والـ Fly — يُحسم بين Flat Press وعزل الصدر', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Press-around / ضغط مع تقريب', 'Horizontal Adduction + Elbow Extension / تقريب أفقي + مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('18115c2a-05e1-4dd1-9ef7-0d17f56b7c7e', 'Machine Chest Fly', 'Chest / الصدر', '{}', 'Horizontal Adduction (Fly) / تقريب أفقي للكتف (فلاي)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Chest Isolation / عزل الصدر', 'Horizontal Adduction / تقريب أفقي للكتف', 'Chest Isolation / عزل الصدر') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('03eef5ef-0285-462c-a7e1-b6fbd768bb83', 'Bar Cable Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/NhD3h6RG2TA?si=SoyNTIGB-nY2KiXl', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('61b83d33-3480-4328-904e-698630e328a9', 'Cable Chest Fly', 'Chest / الصدر', '{"Shoulders / الأكتاف"}', 'Horizontal Adduction (Fly) / تقريب أفقي للكتف (فلاي)', 'قوة', 'كيبل', 'مبتدئ', 'نادي', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/160/standing-chest-fly/', NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Chest Isolation / عزل الصدر', 'Horizontal Adduction / تقريب أفقي للكتف', 'Chest Isolation / عزل الصدر') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('35a12ef3-fcd9-4987-888e-f6d9d378a1e3', 'Bent Knee Push-up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/13/bent-knee-push-up/', NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3e6e63c3-b7c5-4a1e-a0e9-8e4a4541f8df', 'Stability Ball Push-Up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس","Core / البطن والكور"}', 'Horizontal Push / دفع أفقي', 'قوة', 'كرة سويسرية', 'متوسط', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف فرعي: الزاوية تعتمد على موضع الكرة (تحت اليدين أو القدمين) — غير محدد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/63/stability-ball-push-up/', NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('44c54fd5-b22e-4f63-b6c7-f15c95c0caa2', 'Cable Reardelt Rows', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/uIdXVGjcfFE', 'ثبت نفسك بالكرسي، فتحة واسعة، الكيبل بمستوى اسفل صدرك، واسحب لما تنقبض اكتافك الخلفية.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Wide-grip Row / تجديف بقبضة واسعة', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('22f0e970-3ac6-46f9-ac87-8b3d4b50b961', 'Upper Back Horizontal Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/TSWohpfMlso', 'ثبت نفسك بالكرسي، فتحة واسعة، الكيبل بمستوى أعلى صدرك، واسحب لما تنقبض الترابز.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness', 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Wide-grip Row / تجديف بقبضة واسعة', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('122034a4-ecc3-48a6-a67a-3fb5878b2f0f', 'DB Chest Supported Reardelt Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/x0v6GWYzI18?si=-jDt3D-ARIHouHjp', 'ثبت صدرك على الكرسي، فتحة واسعة، واسحب لما تنقبض اكتافك الخلفية.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Wide-grip Row / تجديف بقبضة واسعة', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('39d065fd-61b9-4745-b8df-0ecbe03c84eb', 'Bent-over Barbell Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'بار', 'متوسط', 'نادي', NULL, 'ادفع مؤخرتك للخلف واثني ركبك، قبضتك بنفس مستوى اكتافك، اسحب لما تنقبض عضلات الظهر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('66fe9be3-cc87-4413-ba0d-bba0d31cc196', 'Cable Reardelt Fly', 'Shoulders / الأكتاف', '{"Rotator cuffs / الكفة المدورة"}', 'Shoulder Rear Pull / سحب خلفي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/bkejPHrPkmA?si=-O8q_5e72udoPRiY', NULL, 'تصنيف فرعي: حركة Fly (تبعيد أفقي للكتف) وليست سحباً أفقياً أو عمودياً', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Rear Delt Fly / فتح خلفي', 'Horizontal Abduction / تبعيد أفقي للكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e9abffbc-c952-4e81-903e-835a8d0b6d8d', 'DB Chest Supported Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/H75im9fAUMc', 'ثبت صدرك على الكرسي، فتحة واسعة، واسحب الدمبل باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('68f3272c-2f41-4122-b337-980121754d43', 'Head Supported Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/c6lkPMhuyFA?si=eUivRGYSi0W7PmVe', 'راسك ثابت على البنش بدون أي ميلان بالرقبة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8eec5ec3-6e11-4d54-9e55-ad398cf64c6e', 'Single Arm Dumbbell Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/QBjaGx8mS1o', 'اسحب باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9e2bebf4-ec8c-4604-b5ec-611b3c644894', 'Single Arm Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/Qn_mHGObb8E?si=IZ0q9_tseiRIMtcs', 'اسحب باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7446b598-18f3-41d4-815f-10cc33024a0a', 'Seated Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/0G3W83dFUeY', 'اسحب باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness | تحدب الظهر / Postural Thoracic Kyphosis', 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('94ab3462-c0b9-403c-b871-dfb89f4cbda0', 'Band Seated Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/Jy-WCFAofBY?si=9gqVby588rk1zFi9', 'فتحة واسعة، واسحب لما تنقبض عضلات الظهر.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness | تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture', 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('272cf329-9a88-4cff-9ad4-f5f8262060ed', 'Chest Supported Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/DgHtyrQEMJ4?si=oTfTKVgD9j1H12wA', 'ثبت صدرك على الكرسي، فتحة واسعة، واسحب لما تنقبض عضلات الظهر.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness', 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f9fdbbdb-fb09-4b83-a682-273f362082a3', 'Chest Supported Machine Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/BZrdEAiR2Xs?si=WhKaSGhR0gKeeies', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('699d441a-14d5-40c4-8dba-b130ad393ad7', 'T-Bar Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/6OtcNinT0HM?si=UPfYyypfZCaN9tTA', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('076772ec-45a4-4b32-bee5-a468ec2c4578', 'Lats Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/CQkT-W18N5g', 'الكيبل بنفس مستوى بطنك، اسحب باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Lat-focused Row / تجديف لاتس', 'Shoulder Extension / مد الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d2f54725-be2d-4dc5-bc92-cf885f4d1673', 'Upperback Pulldowns', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/bNmvKpJSWKM?si=hy5HgBDAHkzFHcvv', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Wide-grip Pulldown / سحب علوي بقبضة واسعة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b93ff3d9-2db5-4820-bf8c-4db0a6563fec', 'Straight Arm Pulldown', 'Back & Lats / الظهر واللاتس', '{}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/hAMcfubonDc?si=ocU_a8VQ4VzZnTg3', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Straight-arm Pull / سحب بذراع مستقيمة', 'Shoulder Extension + Scapular Depression / مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('263e24da-59f8-4fb7-a0c8-82052221bd2b', 'DB Pullover', 'Back & Lats / الظهر واللاتس', '{"Chest / الصدر","Triceps / الترايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/ieFKuQAGYIA?si=uwqyrbKhBL6Id3_-', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Straight-arm Pull / سحب بذراع مستقيمة', 'Shoulder Extension + Scapular Depression / مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c6cf82a9-bb32-458a-9b0d-50381d4474a4', 'Band Lat Pulldown', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/5R0RYj3Y9Ro', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c735a155-7026-472e-87b9-293e27804e8f', 'Band Assisted Pull Ups', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://youtu.be/Ks8ah-8P1b0', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b999b275-cac3-487b-bcf5-df4fd36f879c', 'Pull Ups', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متقدم', 'نادي', 'https://youtu.be/x3NPAxiMRPw?si=Mwg6U1Df5aIFpjKB', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('32a58696-08da-4d9c-8725-0c03922e12dc', 'Negative Pull-Up', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://youtu.be/gbPURTSxQLY?si=TvQF5zDWfU_rR1Ax', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر، نزول بطيء.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('88e2ba82-2a8f-499d-b904-eb638c5391ba', 'Neutral Grip Lat Pulldown', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/kVB6SlEyjQM', 'القبضة بنفس مستوى الكتف، اسحب باتجاه اعلى الصدر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1369eb08-0816-4bd6-8d70-0a16af8e89eb', 'Single Lats Pulldown', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/Qed5O9toqT8', 'اجلس على بنش واسند صدرك عليه، ارجع للخلف قليلا بحيث ان الكيبل ما يكون فوق راسك مباشرة، اسحب الكوع باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c262642b-b57e-4bc0-bca4-f25d775681be', 'Band Assisted Chin Ups', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://youtu.be/i0yC-0YK6Uk?si=gNX26kIFz_THnR4p', 'مسكة ضيقة بمستوى الأكتاف، كل ما كان الحبل خفيف زادت المقاومة وزدات صعوبة التمرين لذلك ابدأ بحبل ثقيل وخفف كل ما تحسن مستواك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('abdd3f15-4d46-40c8-b933-dd19b0f5a4ad', 'Chin Ups', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متقدم', 'نادي', 'https://youtube.com/shorts/aV9Mz9nCsMw?si=E_ullJojGO_7srW2', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('79ae1782-0a45-4891-9d42-480df6a5fd4d', 'Kneeling Lat Pulldown', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', NULL, 'متوسط', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/35/kneeling-lat-pulldown/', NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ea10a3f0-8d37-4fde-b5e2-cc13e9ab82f5', 'TRX Back Row', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس","Core / البطن والكور","Lower back / أسفل الظهر"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'TRX', 'متوسط', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/84/trx-reg-back-row/', NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1241cde5-7a3d-43f7-8b33-f53daa7e72c7', 'Shrug', 'Back & Lats / الظهر واللاتس', '{"Trapezius / الترابيس"}', 'Scapular Elevation / رفع لوح الكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف فرعي: رفع الأكتاف (Shrug) ليس نمط سحب أفقي أو عمودي', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/72/shrug/', NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Shrug / هز الكتفين', 'Scapular Elevation / رفع لوح الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ccd1cbb7-dd85-42b2-8620-fb2998359f6b', 'DB Shoulder Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/NKeyUrDYqPk', 'قوّس ظهرك العلوي قليلاً، الكوع قريب من الجسم، النزول الى مستوى الاكتاف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('74ec9382-93ae-450e-9faa-ecd117158dbe', 'DB Standing Shoulder Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/wO0l5jW2NtQ?si=MVvS4F_7iFS8ji9R', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0c8d7e1f-d0ba-43ab-8ace-5430c4e4f477', 'Machine Shoulder Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/3R14MnZbcpw', 'قوّس ظهرك العلوي قليلاً، الكوع قريب من الجسم، النزول الى مستوى الاكتاف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6cd141a8-7b9b-4bca-8ffb-3b4031929a1e', 'BB Overhead Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/_RlRDWO2jfg', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0d5c0618-8630-4298-94e4-5b638be58ac4', 'DB Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/qqntiuPmLDM?feature=share', 'انحني للأمام قليلًا، ارفع للأعلى الى أن تصل لمستوى الأكتاف.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2efba67c-a707-47ad-a575-59706072430a', 'Seated Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/v7fwGurZ9SU?feature=share', 'انحني للأمام قليلًا، ارفع للأعلى الى أن تصل لمستوى الأكتاف.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('702f0b63-075b-45c9-9ebc-a6cf70fcb872', 'Lateral Raise Machine', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/d0pRsZ9SY5w?si=XuXb_Ti0Flow7qvW', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('faabda08-1d4c-451f-a4cc-cae3f5ed9209', 'Cable Crossover Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/wKgCc5UQjoU?si=zsaz3i31PnEU9A43', 'الكيبل يبدأ من الأسفل، انحني للأمام قليلًا، ارفع للأعلى وتحكم بالنزول.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ee5e11a5-ff05-461e-aef9-f53bd1d10e67', 'DB Y Raises', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/lXp16YozXgk', 'ثبت صدرك على البنش،ارفع الوزن على شكل Y.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Y Raise (Scaption) / رفع Y بمستوى لوح الكتف', 'Shoulder Elevation in Scapular Plane (Scaption) / رفع الذراع بمستوى لوح الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ef17d320-2f68-4295-b6ae-ed75183b20d7', 'Cable Y Raises', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/P7u6PEeOn6Q?feature=share', 'الكيبل يبدأ من تحت،ارفع الوزن على شكل Y.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Y Raise (Scaption) / رفع Y بمستوى لوح الكتف', 'Shoulder Elevation in Scapular Plane (Scaption) / رفع الذراع بمستوى لوح الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8f7d1bfc-b822-4f45-9bda-e073db7b56eb', 'Single Arm DB Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/Jm6GqVhWhNY', 'انحني للأمام قليلًا، ارفع للأعلى الى أن تصل لمستوى الأكتاف.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('31be5254-435e-42e0-bdb2-1db4237ae290', 'Single Arm Cable Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/J-6uEOkYAKM', 'الكيبل يبدأ من الأسفل، انحني للأمام قليلًا، ارفع للأعلى وتحكم بالنزول.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6e507ec7-a58c-414a-8129-e86100ff727b', 'Front Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Front Raise / رفع أمامي للكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/54/front-raise/', NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Front Raise / رفع أمامي', 'Shoulder Flexion / ثني الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('eb8c0570-8281-4669-a0b4-d852856325b7', 'Diagonal Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/371/diagonal-raise/', NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Diagonal Raise / رفع قطري', 'Shoulder Flexion + Abduction (Diagonal) / ثني وتبعيد الكتف (قطري)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('66b70497-a935-45a2-8ec0-ed6dfab274fe', 'High Row', 'Shoulders / الأكتاف', '{}', 'Shoulder Rear Pull / سحب خلفي للكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/336/high-row/', NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'High Row / Face Pull / سحب عالٍ باتجاه الوجه', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('871acefd-6469-4e89-a01c-cf3792062d8d', 'Biceps Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/09AYfVFf7pg?si=dcwLVAYqIbDLM6jd', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f382ac02-4b57-40d8-ba51-fac323b9784c', 'Cable Rope Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/xNXUTJ6TBZA?si=-r-Ql97awoVZla_1', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Hammer / Neutral-grip Curl / ثني بقبضة محايدة', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a6378497-47e5-46cb-be1d-103b8cffe09e', 'Cable Facing Away Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/fV9BpknCjGM', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a61868f4-8b36-486f-aa9a-3569988158fa', 'DB Incline Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/js_StxxyxBM', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c3d0767d-66ec-4a04-930c-62c2521da158', 'Cable Facing In Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/5z4y7QRTx1w', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2ea27f3c-f71a-4a6d-8d5d-c18565688e9e', 'Single Arm Cable Facing Away Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/6sO-pK7pTPs?feature=share', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8584a8f2-b271-4848-8ccd-fec6f3387b26', 'Single Arm Cable Facing In Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/I-197ZW9Ffo?si=M1Yq4R1PIpdZMXRx', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2619b440-b999-4f3d-96be-127e419f18bf', 'DB Preacher', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/DZJNTb-zzn0?si=SwbdZ0O_0eTOET-5', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Preacher Curl / ثني على مسند', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('98760507-fa79-4286-bf53-48bc690a93d5', 'Preacher Curl Machine', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/TouYMA3-ua4?feature=share', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Preacher Curl / ثني على مسند', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5322cccd-d86b-4ed8-9e5f-f6dd7e2889af', 'DB Spider Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/cTMjzB2_IH8?si=qsIKEEFVfEvPXwqf', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('59e374a7-bcbb-4625-adf1-0edab04547cb', 'Zottman Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://www.youtube.com/watch?v=ZXbOOIOPOi8', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('486f7da3-d7d2-4c15-9a8e-c763c34217d1', 'Hammer Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/10/hammer-curl/', NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Hammer / Neutral-grip Curl / ثني بقبضة محايدة', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a79fa71f-53a9-4d0c-b779-f0f344dd7cda', 'TRX Biceps Curl', 'Biceps / البايسبس', '{"Forearms / الساعد","Core / البطن والكور"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'TRX', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/78/trx-reg-biceps-curl/', NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('18f51cd1-2860-4f5d-b73d-d912ee65df13', 'DB Triceps Extensions', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/d7SXlU5HkYM?si=WuuPa9-yeByaP5sI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Overhead Extension / مد فوق الرأس', 'Elbow Extension / مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e4841332-3e45-4c7c-86e1-5f9fc0d7b627', 'DB Floor Triceps Extensions', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/dpFav9Ve4rY?si=ZBdKK8VF4aPMpi3v', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Lying Extension / مد مستلقٍ', 'Elbow Extension / مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('487c881c-ea5a-4060-a95e-41240bfd9b68', 'Cable Crossbody Extensions', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://www.youtube.com/watch?v=jtLTcED38Dg', 'الكيبل يبدأ بالمنتصف زي الفيديو، بحيث لما تسحب الكيبل يكون بنفس مستوى الترابس، الأكواع والأكتاف ثابتين مكانهم والحركة كلها بثني وفرد الكوع.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Cross-body Extension / مد عرضي', 'Elbow Extension / مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0ee07ea9-8d3a-453e-9885-50e3203ecf32', 'Triceps Pushdown', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/QsoN4u6j8nM?feature=share', 'انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ebcc30be-2ff7-4033-9dd1-259dcab2020e', 'Cable Crossover Pressdowns', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/Y3CDzx-oj3k', 'الكيبل يبدأ من الأعلى،انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f1225e16-d0fc-4473-9ba8-fd09f87e021e', 'Band Triceps Pushdown', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/mYs1rEYtZK4?si=k8vdZxNNEB5wj2CA', 'الكيبل يبدأ من الأعلى،انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('04be2028-33e0-415c-81f1-2f527d40741a', 'Single Cable Triceps Pressdowns', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/8rl4ioij6lc', 'الكيبل يبدأ من الأعلى،انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6da087e1-a7b6-4200-921e-dfa17db24e83', 'Cable Overhead Extension', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://www.youtube.com/shorts/Q3bO1Fh4734', 'اترك الحبل يسحب معصمك وكوعك ثابت لما تستطيل التراي ثم ارفع الوزن لما تستقيم اليد، كوعك ثابت طول الوقت والحركة ثني ومد من مفصل الكوع، ممكن تطبق كل يد لحالها اذا كان اسهل لك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Overhead Extension / مد فوق الرأس', 'Elbow Extension / مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3d00cbef-5e1c-4efe-a283-213785092f51', 'Triceps Dips', 'Triceps / الترايسبس', '{"Chest / الصدر","Shoulders / الأكتاف"}', 'Vertical Push / دفع عمودي', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/SpSE_A5L-YA?si=bSAzRM9SBuX-3mE0', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Dip / متوازي', 'Shoulder Extension + Elbow Extension / مد الكتف + مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('79b5c3c6-59df-4ca6-867b-04ac1f284bea', 'Triceps Kickback', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/YebyKE3Ts8o?si=H_h9z5BXutFBbFhq', NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/55/triceps-kickback/', NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Triceps Kickback / ركلة الترايسبس', 'Elbow Extension / مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f3ed62fe-0251-4cba-856b-e487a6bf64b2', 'Plank', 'Core / البطن والكور', '{"Shoulders / الأكتاف","Glutes / المؤخرة"}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/pvIjsG5Svck?si=cTP8ZyfMAJPfaEhw', 'لما ترتفع الاكتاف تكون فوق الكوع والرجل ممتدة بالكامل.', NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('655873ed-d5e2-4cfc-91ee-387a98189f87', 'deadbug', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/g_BYB0R-4Ws?si=D4nwJri73eBqJRqL', NULL, 'اسم مشابه موجود في المكتبة (deadbug / dead bug) — تُراجَع قبل الحذف أو الدمج', 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'rejected', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fff20d5f-29f8-407f-b2ef-3611dd6f64ae', 'Band Dead Bug', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'مطاط', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/iW_CtYtzbeU?si=Epequw3rqA3_TwTr', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7bfe9835-72ea-4d0f-a147-ff3b7f24a127', 'Side Plank', 'Core / البطن والكور', '{"Abductors / مبعدات الفخذ","Shoulders / الأكتاف"}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'لما ترتفع الاكتاف تكون فوق الكوع والرجل ممتدة بالكامل.', NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain | ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Anti-Lateral Flexion / مقاومة الميلان الجانبي', 'Isometric Anti-Lateral Flexion / تثبيت الجذع ضد الميلان', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('da03e444-c95d-4114-a2c4-c7c4a63eff0d', 'McGill Big 3', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/jZylx81_kfg?si=_jP064GZIzvEvzyN', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Mixed (McGill Big 3) / مختلط', 'Isometric Trunk Stabilization / تثبيت الجذع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f631b34e-d992-4b76-b491-1fcdef0fa20a', 'Suitcase Carry', 'Core / البطن والكور', '{"Forearms / الساعد"}', 'Loaded Carry / حمل ومشي', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/BaRMAhD7SP4?si=KkiMH8OSIEz_TB53', NULL, 'نفس التمرين ورد أيضاً تحت التصنيف «Functional Training» (صف المصدر 160) || رابط آخر في المصدر (صف 160): https://youtu.be/BaRMAhD7SP4?si=dCR2n2VSPaHhxfL3', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Suitcase Carry / حمل جانبي', 'Isometric Trunk + Grip Under Load / تثبيت الجذع والقبضة أثناء المشي', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c43180d3-7b2d-42e8-bf57-e2ae9737d344', 'Single Leg Raise', 'Core / البطن والكور', '{"Glutes / المؤخرة","Hamstrings / الخلفية"}', NULL, NULL, 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/ZJodU5OOaiA?si=p6ZD9dpzyRKBUn16', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5f420c00-f31b-4061-a7ff-064379e8c490', 'Cable Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/ToJeyhydUxU?si=Z5dv34foxX4VtRH6', 'الحركة عبارة عن ثني للعمود الفقري وكأنك تقرب صدرك لوركك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Crunch / كرنش', 'Trunk Flexion / ثني الجذع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('06719b5a-9bab-4dbd-93c6-18cce69b2f18', 'Leg Raises', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/UqmbxvOgnX4?si=U3pDG4Jf0x1mtC_7', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Reverse Crunch / Leg Raise / كرنش عكسي ورفع الأرجل', 'Hip Flexion + Posterior Pelvic Tilt / ثني الورك + إمالة الحوض للخلف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('057cebc7-697d-4e54-9d52-24aab3218c2d', 'Bosu Ball Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'أخرى', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/KjvDgHPxXcg?si=zad59CHC6Y-calzi', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Crunch / كرنش', 'Trunk Flexion / ثني الجذع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('635ce954-3e84-4b29-81be-0fd8cf5961b1', 'Bent Knee V-Up', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/sbyFIM30_G8?si=dED0NQSRS44dz5G9', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'V-up / في أب', 'Trunk Flexion + Hip Flexion / ثني الجذع + ثني الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('757b2e61-8bd2-4859-87a6-f03652df9926', 'Reverse Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/esYVzdEfs04?si=N44MZZHlVeSQc1S3', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Reverse Crunch / Leg Raise / كرنش عكسي ورفع الأرجل', 'Hip Flexion + Posterior Pelvic Tilt / ثني الورك + إمالة الحوض للخلف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ecacad44-4653-40fe-9a51-a34e892ccd71', 'Belly Breathing', 'Core / البطن والكور', '{}', 'Core Activation & Breathing / تفعيل الجذع والتنفس', 'إحماء/تفعيل', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/Shk8cmgv0Ew?si=mXkcj9PH6eH_tLcd', 'نفس عميق من الانف ننفخ فيه البطن ثم نطلعه من الفم ببطئ مع ضغط البطن للداخل اثناء اخراج النفس', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Diaphragmatic Breathing / تنفس حجابي', 'Diaphragmatic Breathing + Abdominal Bracing / تنفس حجابي + شد البطن', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('47553c1f-7b85-477e-918a-7bfa9a249f22', 'Dead Bug', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/_zkkMOtXuOQ?si=GIkLuCUJvdaOk5FP', 'نحرك الرجلين ببطئ قليلا و بتحكم باستخدام عضلات البطن', 'اسم مشابه موجود في المكتبة (deadbug / dead bug) — تُراجَع قبل الحذف أو الدمج', 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f401b388-f821-4e33-b5f8-f94d9d18f5e9', 'Reverse Tabletop Bridge', 'Core / البطن والكور', '{"Glutes / المؤخرة"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://youtu.be/d1yE9cGtPWo?si=2aoNqmUAN054rP75', 'اخذ نفس اثناء الطلوع، اثبت ثواني فوق واشد عضلات بطني، اطلع النفس اثناء النزول', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e151bcbc-3e0e-4441-b4ba-27f6daf7add3', 'Bird Dog', 'Core / البطن والكور', '{"Lower back / أسفل الظهر","Glutes / المؤخرة"}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/L91QMACdA6Q?si=KBnuQDcm9WcUXxxI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Anti-Rotation / مقاومة الدوران', 'Isometric Anti-Rotation / تثبيت الجذع ضد الدوران', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('04380168-a7d9-45a9-9da6-bf1c8280c066', 'Pelvic Tilting', 'Core / البطن والكور', '{}', 'Core Activation & Breathing / تفعيل الجذع والتنفس', 'إحماء/تفعيل', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/DqqUIfMuDX4?si=uzl0SRl_M9guUT3j', 'الحركة من الحوض، اخذ نفس وادف حوضي للاعلى قليلا، اطلع النفس اثناء نزول الحوض والصق اسفل ظهري بالارض', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Pelvic Tilt / إمالة الحوض', 'Posterior Pelvic Tilt / إمالة الحوض للخلف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('67d962ee-8be4-4bb6-91ff-09c7ecb2f876', 'Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/52/crunch/', NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Crunch / كرنش', 'Trunk Flexion / ثني الجذع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('264c047b-9977-4a5b-b8ac-cc9d6e226ca8', 'Standing Wood Chop', 'Core / البطن والكور', '{}', 'Trunk Rotation / دوران الجذع', 'كور', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/108/standing-wood-chop/', NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Rotation / Chop / دوران وتقطيع', 'Trunk Rotation / دوران الجذع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('59aff6b7-889b-4b49-a4b6-78169070b09a', 'Russian Twist', 'Core / البطن والكور', '{"Lower back / أسفل الظهر"}', 'Trunk Rotation / دوران الجذع', 'كور', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/65/russian-twist/', NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Rotation / Chop / دوران وتقطيع', 'Trunk Rotation / دوران الجذع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('36022ca5-ed44-4ead-95eb-eff65bb453b2', 'Cable Twisted', 'Core / البطن والكور', '{"Lower back / أسفل الظهر"}', 'Trunk Rotation / دوران الجذع', 'كور', 'كيبل', 'مبتدئ', 'نادي', NULL, NULL, NULL, 'إضافة المدربة', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Rotation / Chop / دوران وتقطيع', 'Trunk Rotation / دوران الجذع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cba53fef-18fd-44d4-9389-dc89030819d6', 'Calves On Leg Press', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/XdtWVYFVhGU', 'ثبت أصابعك أو مقدمة رجلك على الجهاز، لا تبالغ بالوزن، انزل بكعبك لين تمتد بطاتك بشكل كامل ثم ادفع.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5b1dc45a-2d47-4020-9426-34bb08b9ad8d', 'Calves Raise', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/H6WptvjXkgw', 'حط تحت اقدامك بليتس أو أي شي يرفعك عن الأرض، انزل من اصابعك اقصى نزول ثم ادفع للأعلى', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b070e3e1-93e0-47ee-830d-6014d58790a1', 'Calf Raise (Machine)', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', 'جهاز', 'مبتدئ', 'نادي', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/294/calf-raise/', NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e51c427e-8ecd-4064-981d-9557b618da69', 'Calf Raises (Barbell)', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', 'بار', 'مبتدئ', 'نادي', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/51/calf-raises/', NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ced922ba-c779-4295-b477-b55661c3ac87', 'High-Load Heel Raise (Towel Under Toes)', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', NULL, 'مبتدئ', NULL, NULL, 'رفع الكعب على رجل واحدة مع منشفة ملفوفة تحت أصابع القدم؛ صعود بطيء ثم ثبات قصير ثم نزول بطيء.', 'أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Rathleff et al. 2015 — Scand J Med Sci Sports (RCT)', 'https://doi.org/10.1111/sms.12313', 'اللفافة الأخمصية / Plantar Fasciopathy', 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('777e5e97-9bb4-4390-a063-aa3c21dcb855', 'Adductor Slides', 'Adductors / الأفخاذ الداخلية', '{}', 'Hip Adduction / تقريب الورك', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/6U7dfuxaX9g?si=lkH35E7tZxGBePBj', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor strength»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Adductor Slide / انزلاق للتقريب', 'Hip Adduction / تقريب الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0c65d871-82b0-4bf1-8e38-e07c294b16af', 'Adductor Machine', 'Adductors / الأفخاذ الداخلية', '{}', 'Hip Adduction / تقريب الورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/SU1LQhq3o2g?si=_55FKBOlcn8Ilw4X', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Adductor Machine / جهاز التقريب', 'Hip Adduction / تقريب الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e86ea632-5012-4ca0-9a20-65dce553f582', 'Side Lunge', 'Adductors / الأفخاذ الداخلية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/50/side-lunge/', 'ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Lateral Lunge / لانج جانبي', 'Knee/Hip Extension + Hip Adduction / مد الركبة والورك + تقريب الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('479fd45f-58bc-46ba-8164-3e63ae671285', 'Seated Abductor Machine', 'Abductors / مبعدات الفخذ', '{}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/riEMreTHNbM?si=wE3vfJBYQY7j_oJ2', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor strength»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a4cba2fe-4ac8-444b-9ebd-1342142f21d4', 'Sled Pull/Push', 'Functional / التمارين الوظيفية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Calves / البطات"}', 'Locomotion / مشي وجري ودفع', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://www.youtube.com/watch?v=3KWK7SIdPz4', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Sled Push / Pull / دفع وسحب الزلاجة', 'Hip/Knee Extension in Gait / بسط الورك والركبة بنمط المشي', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c77249ad-559f-4618-9603-c40e0a6727b4', 'Hip Abductor Plank', 'Abductors / مبعدات الفخذ', '{"Core / البطن والكور"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/2lB5RL91yWo?si=WRm9rUORpFK6dXPl', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor strength»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('96653e7b-58d3-42c0-b939-dc953c9a1d19', 'Dirty Dog', 'Abductors / مبعدات الفخذ', '{"Core / البطن والكور"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/109/dirty-dog/', NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('82aa4b80-f785-4a15-b3a8-ddeb35fc64ea', 'Hip Hitch (Pelvic Drop)', 'Abductors / مبعدات الفخذ', '{}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Ganderton et al. — GMin/GMed EMG (RMIT University)', 'https://research-repository.rmit.edu.au/articles/journal_contribution/Gluteus_Minimus_and_Gluteus_Medius_Muscle_Activity_during_Common_Rehabilitation_Exercises_in_Healthy_Postmenopausal_Women/27572301', 'ضعف الألوية المتوسطة / Gluteus Medius Weakness | ضعف الألوية الصغرى / Gluteus Minimus Weakness', 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Pelvic Drop (Stance Leg) / تثبيت الحوض برجل الارتكاز', 'Hip Abduction of Stance Leg / تبعيد ورك رجل الارتكاز', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e36d6d33-ccd1-40e4-a8e1-f5ed39ee3d86', 'Rotator Cuff', 'Rotator cuffs / الكفة المدورة', '{}', 'Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/mO8YJAxVG2M?si=KL_llR6Z47Yt89uk', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «Functional Training»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'External Rotation / دوران خارجي', 'Shoulder External Rotation / دوران خارجي للكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f6f1859d-1c35-47cd-bf50-b8dfdf6f2c96', 'Shoulder I-Y-T-W Series', 'Rotator cuffs / الكفة المدورة', '{"Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/237/shoulder-stability-mobility-series-i-y-t-w-formations/', 'تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture | ضعف العضلة المعينية / Rhomboid Weakness', 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'I-Y-T-W / تمارين I-Y-T-W', 'Scapular Retraction/Depression + Arm Elevation / سحب وخفض لوح الكتف مع رفع الذراع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f88ad193-61a3-4eb8-892e-51d51e1bb654', 'Supine Snow Angel (Wipers)', 'Rotator cuffs / الكفة المدورة', '{"Shoulders / الأكتاف","Core / البطن والكور"}', 'Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/124/supine-snow-angel-wipers-exercise/', 'تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture', 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Snow Angel / الملاك', 'Shoulder Abduction/Adduction + Scapular Control / تبعيد وتقريب الكتف مع تحكم لوح الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('24f32e57-fa48-4334-b7c4-7755ca82a4f5', 'Back Extension', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة","Hamstrings / الخلفية"}', 'Spinal Extension / بسط الجذع', 'كور', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/bs7S3RFyIYs?si=tDLl3OYuDBIwK4Fj', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «Functional Training»)', 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain | تحدب الظهر / Postural Thoracic Kyphosis', 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Back Extension / بسط الظهر', 'Hip Extension + Spinal Extension / بسط الورك + بسط العمود الفقري', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9199c506-1194-4e12-94aa-1ae3ab3a0bd1', 'Supermans', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة","Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Spinal Extension / بسط الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/9/supermans/', 'تحدب الظهر / Postural Thoracic Kyphosis | آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Prone Extension / بسط على البطن', 'Spinal Extension / بسط العمود الفقري', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c80f3a44-aa96-43d6-8aed-7d61f8163ae2', 'Stability Ball Reverse Extensions', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة"}', 'Spinal Extension / بسط الجذع', 'كور', 'كرة سويسرية', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/64/stability-ball-reverse-extensions/', NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Reverse Extension / بسط عكسي', 'Hip Extension + Spinal Extension / بسط الورك + بسط العمود الفقري', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('79ada8de-a505-4a4f-a5a1-f9c4610cf30d', 'Farmer’s Walk', 'Functional / التمارين الوظيفية', '{"Forearms / الساعد","Core / البطن والكور","Back & Lats / الظهر واللاتس"}', 'Loaded Carry / حمل ومشي', 'قوة', NULL, 'مبتدئ', NULL, 'https://www.youtube.com/watch?v=hx24PM6gXs8', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Farmer''s Walk / مشي المزارع', 'Isometric Trunk + Grip Under Load / تثبيت الجذع والقبضة أثناء المشي', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4a85c379-1327-44ac-bcae-12753145e8f5', 'Contralateral Limb Raises', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة","Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Spinal Extension / بسط الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/53/contralateral-limb-raises/', NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Prone Extension / بسط على البطن', 'Spinal Extension / بسط العمود الفقري', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5b17643d-c77d-4e57-baee-d774e4939ef5', 'Inner Thigh Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/uqCfJYKojLU?si=Gev0VeOwVp5z6gB2', 'الضغط والدفع يكون من جهة الفخذ ، لا تدفع من ركبتك!', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «stretch»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Adductor Stretch / إطالة المقربات', 'Hip Abduction (Adductor Stretch) / تبعيد الورك (إطالة المقربات)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1e0f99d1-9e49-406b-926d-fb822d2bf6cd', 'Hips Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/uqCfJYKojLU?si=Gev0VeOwVp5z6gB2', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «stretch»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Hip Stretch / إطالة الورك', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('986e8d1b-e1df-4c6b-b96f-f433982c5f68', 'Kneeling Hip-flexor Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'من وضع الركوع: الركبة الخلفية تحت الورك والقدم الأمامية أمامك والركبة فوق الكاحل. شد البطن وادفع الحوض للأمام دون تقويس أسفل الظهر، واعصر مؤخرة الجهة الخلفية لزيادة الإطالة. اثبت 30–45 ثانية، 2–5 مرات.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/142/kneeling-hip-flexor-stretch/', NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Hip Flexor Stretch / إطالة ثانيات الورك', 'Hip Extension (End Range) / بسط الورك في نهاية المدى', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('975af0f7-e4b2-4d1a-88c9-512f18ce3900', 'Supine Hamstrings Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'استلقِ على ظهرك وارفع رجلاً واحدة ومدّها ببطء مع سحب أصابع القدم نحوك، دون أي حركة في الحوض أو أسفل الظهر. اثبت 15–30 ثانية، 2–4 مرات لكل رجل.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/235/supine-hamstrings-stretch/', NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Hamstring Stretch / إطالة الخلفية', 'Hip Flexion with Knee Extended / ثني الورك مع مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('df7b5e52-58a0-4365-8c17-7ca42f1fac46', 'Side Lying Quadriceps Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'استلقِ على جنبك وشد البطن، واسحب كعب الرجل العلوية نحو المؤخرة بيدك مع إبقاء الركبة في خط الورك. اثبت 30–45 ثانية، 2–5 مرات لكل جهة.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/149/side-lying-quadriceps-stretch/', NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Quadriceps Stretch / إطالة الأمامية', 'Knee Flexion + Hip Extension (End Range) / ثني الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c65d3939-4671-4310-8aed-80ea14692272', 'Standing Dorsi-Flexion (Calf Stretch)', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/152/standing-dorsi-flexion-calf-stretch/', 'اللفافة الأخمصية / Plantar Fasciopathy', 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Calf Stretch / إطالة البطات', 'Ankle Dorsiflexion / ثني ظهري للكاحل', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a918f24e-289c-42b1-a69e-6634f6425576', 'Cat-Cow', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/15/cat-cow/', 'تحدب الظهر / Postural Thoracic Kyphosis | آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Spinal Mobility / مرونة العمود الفقري', 'Spinal Flexion/Extension / ثني وبسط العمود الفقري', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('545fc4da-c5ba-47fc-a4a1-0e811077557e', 'Standing Lunge Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/137/standing-lunge-stretch/', NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Hip Flexor Stretch / إطالة ثانيات الورك', 'Hip Extension (End Range) / بسط الورك في نهاية المدى', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('30d97729-f7ca-4c43-81e6-fc3c9780d64c', 'Plantar Fascia-Specific Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'تُسحب أصابع القدم للخلف باليد حتى يُشعر بشد في باطن القدم، مع تحسّس اللفافة للتأكد من الشد.', 'أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Rathleff et al. 2015 — Scand J Med Sci Sports (RCT)', 'https://doi.org/10.1111/sms.12313', 'اللفافة الأخمصية / Plantar Fasciopathy', 'review', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Plantar Fascia Stretch / إطالة اللفافة الأخمصية', 'Toe Extension + Ankle Dorsiflexion / مد أصابع القدم + ثني ظهري', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('538cdaea-8e63-4122-b82f-d8bc545dcfeb', 'Crab Reach (Thoracic Bridge)', 'Functional / التمارين الوظيفية', '{"Glutes / المؤخرة","Shoulders / الأكتاف"}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://www.youtube.com/watch?v=fgsUe3Lc3hI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'تحدب الظهر / Postural Thoracic Kyphosis', 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Thoracic Bridge / جسر صدري', 'Hip Extension + Thoracic Rotation / بسط الورك + دوران الصدر', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1236753d-746e-4bf2-a737-e22d59277e64', 'Lateral Bound', 'Plyometrics / التمارين الانفجارية', '{"Glutes / المؤخرة","Quadriceps / الأمامية","Abductors / مبعدات الفخذ"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://www.youtube.com/watch?v=soqQy4dzEts', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «Functional Training»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Lateral Jump / قفز جانبي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a1c0a67e-673b-46b5-90a6-5643bc03abc4', 'Box Jumps', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Calves / البطات"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'أخرى', 'متوسط', 'نادي', NULL, NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «CrossFit»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Vertical Jump / قفز عمودي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a0aca655-4ae3-4ecd-ad1b-ddf57029f877', 'Squat Jump', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متوسط', 'بدون معدات', NULL, 'قف بعرض الحوض، ادفع الورك للخلف وانزل، ثم اقفز بقوة بمدّ الكاحل والركبة والورك معاً. انزل بهدوء على منتصف القدم مع دفع الورك للخلف ودون قفل الركب. ابدأ بقفزات صغيرة حتى تتقن الهبوط.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/222/squat-jump/', NULL, 'review', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Vertical Jump / قفز عمودي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a26b9b40-4067-439a-881f-75f81f8568e9', 'Tuck Jump', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متقدم', 'بدون معدات', NULL, 'استخدم الذراعين للزخم: أرجعهما للخلف عند النزول وأرجحهما للأمام والأعلى عند القفز، واسحب الركبتين نحو الصدر في الهواء.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/180/tuck-jump/', NULL, 'review', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Vertical Jump / قفز عمودي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3b289a95-43f9-4841-a60f-e70bf4aa1473', 'Cycled Split-Squat Jump', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Hamstrings / الخلفية"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متقدم', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/234/cycled-split-squat-jump/', NULL, 'review', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Split Jump / قفز سبليت', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e737549b-21f8-4a70-9a81-beebc6aaec2c', 'Lateral Cone Jumps', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Calves / البطات"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'أخرى', 'متوسط', 'نادي', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/120/lateral-cone-jumps/', NULL, 'review', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Lateral Jump / قفز جانبي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c2bb229e-9e81-4a9c-9794-c075bb15adac', 'Forward Linear Jumps', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Hamstrings / الخلفية"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متوسط', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/177/forward-linear-jumps/', NULL, 'review', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Horizontal Jump / قفز أمامي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('36f43450-aafe-41a1-ad32-1bffb9184490', 'Jogging', 'CrossFit / كروس فت', '{"Quadriceps / الأمامية","Hamstrings / الخلفية","Calves / البطات"}', 'Locomotion / مشي وجري ودفع', 'كارديو', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Running / جري', 'Gait: Alternating Hip/Knee Extension / نمط المشي والجري', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fd470370-ecba-4c62-869e-359b45a60e35', 'Wall Ball', 'CrossFit / كروس فت', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Shoulders / الأكتاف"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'أخرى', 'متوسط', 'نادي', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Squat to Throw / سكوات مع رمي', 'Knee/Hip Extension + Shoulder Flexion / مد الركبة والورك + ثني الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3701db69-adbd-47a6-abbc-fe63e4af995d', 'Snatch', 'CrossFit / كروس فت', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Shoulders / الأكتاف"}', 'Olympic Lift (Triple Extension) / رفعات أولمبية (بسط ثلاثي)', 'قدرة', 'بار', 'متقدم', 'نادي', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Snatch / سناتش', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('da7f612a-b1f6-42ee-a4bd-7f3f711d2c85', 'Clean', 'CrossFit / كروس فت', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Quadriceps / الأمامية"}', 'Olympic Lift (Triple Extension) / رفعات أولمبية (بسط ثلاثي)', 'قدرة', 'بار', 'متقدم', 'نادي', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Clean / كلين', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c76ddda4-0445-4934-95bf-8a51a313ef40', 'Turkish Get-Up', 'Functional / التمارين الوظيفية', '{"Shoulders / الأكتاف","Core / البطن والكور","Glutes / المؤخرة"}', 'Full-body Integrated / حركة متكاملة للجسم', 'قوة', 'كيتلبل', 'متقدم', 'منزل', 'https://www.youtube.com/watch?v=0bWRPC49-KI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Turkish Get-Up / النهوض التركي', 'Multi-joint Integrated / حركة متعددة المفاصل', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a6850e68-66dd-4374-ac20-22b9ae8aa981', '90s Transition', 'Functional / التمارين الوظيفية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://www.youtube.com/watch?v=ogU-azeGe_k', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Hip Rotation Mobility (90/90) / مرونة دوران الورك', 'Hip Internal/External Rotation / دوران الورك الداخلي والخارجي', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9fcc1ce7-39eb-40e1-94bc-316f8c2be4a2', 'Prone Swimmer', 'Functional / التمارين الوظيفية', '{"Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Shoulder Rear Pull / سحب خلفي للكتف', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://www.youtube.com/watch?v=M8a1cgnhyqk', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture', 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Prone Swimmer / سبّاح على البطن', 'Shoulder Extension/Abduction + Rotation / مد وتبعيد الكتف مع الدوران', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3dd22a58-1ba5-4fc5-b245-9267b22c678d', 'Kettlebell Swing', 'Functional / التمارين الوظيفية', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Core / البطن والكور"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قدرة', 'كيتلبل', 'متوسط', 'منزل', 'https://www.youtube.com/watch?v=d94xX-AQZ0A', NULL, 'نفس التمرين ورد أيضاً تحت التصنيف «CrossFit» (صف المصدر 168)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Ballistic Hinge (Swing) / مفصلة انفجارية (سوينق)', 'Hip Extension (Ballistic) / بسط الورك الانفجاري', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5a5af824-a078-4add-a850-a1176476eebb', 'left over db', 'Functional / التمارين الوظيفية', '{}', NULL, NULL, 'دمبل', NULL, 'منزل', 'https://youtu.be/pLnRt-caepc?si=DAS9jeYr8vS6RRtz', 'طبق الحركة بأقصى عدد ممكن من التكرارات وأحسبها كجولة، ثم ابدأ بالجولة الثانية بنفس الطريقة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('867e8afb-6449-417c-8c4b-9ea713699b34', 'Serratus Punches Supine', 'Functional / التمارين الوظيفية', '{"Shoulders / الأكتاف","Chest / الصدر"}', 'Horizontal Push / دفع أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/cxaAqmdlrgk?si=2YRAIgFFXPAvDadG', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Scapular Protraction / دفع لوح الكتف', 'Scapular Protraction / دفع لوح الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d89cb9fe-d0f1-435f-8207-e5843d9d97c5', 'Isometric Wrist Extension', 'Forearms / الساعد', '{}', 'Wrist Extension / مد الرسغ', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'مرفق التنس / Lateral Elbow Tendinopathy', 'review', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Isometric / ثابت', 'Wrist Extension / مد الرسغ', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cf664039-bad5-4fe0-92f6-3db918a90cfb', 'Eccentric Wrist Extension', 'Forearms / الساعد', '{}', 'Wrist Extension / مد الرسغ', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'مرفق التنس / Lateral Elbow Tendinopathy', 'review', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Eccentric / لامركزي', 'Wrist Extension / مد الرسغ', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('10caa480-5302-424e-8d2d-d0a2b382b857', 'Chin Tuck (Deep Neck Flexor)', 'Neck / الرقبة', '{}', 'Neck Flexion (Deep Flexors) / ثني الرقبة العميق', 'إحماء/تفعيل', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Sheikhhoseini et al. 2018 — JMPT (Systematic review, FHP)', 'https://pubmed.ncbi.nlm.nih.gov/30107937/', 'وضعية الرأس للأمام / Forward Head Posture', 'review', '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00', 'Chin Tuck / سحب الذقن', 'Upper Cervical Flexion + Retraction / ثني علوي للرقبة مع سحبها للخلف', NULL) ON CONFLICT DO NOTHING;



INSERT INTO public.exercise_alternatives VALUES ('59bdcca6-40cc-4075-b32f-82aa15adaa11', '49938c2e-ea1a-4457-ba87-9aae6ed90d05', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59bdcca6-40cc-4075-b32f-82aa15adaa11', 'f366fad7-2dfe-4829-8f71-8f767524c0c5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59bdcca6-40cc-4075-b32f-82aa15adaa11', '757066d3-e325-43c1-872d-0b0e4ca27e49', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59bdcca6-40cc-4075-b32f-82aa15adaa11', 'd408fdc4-7f66-4077-b690-895987f359ff', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59bdcca6-40cc-4075-b32f-82aa15adaa11', 'e3186677-d366-4dab-b010-097f05ebce45', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('49938c2e-ea1a-4457-ba87-9aae6ed90d05', '59bdcca6-40cc-4075-b32f-82aa15adaa11', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('49938c2e-ea1a-4457-ba87-9aae6ed90d05', 'f366fad7-2dfe-4829-8f71-8f767524c0c5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('49938c2e-ea1a-4457-ba87-9aae6ed90d05', '757066d3-e325-43c1-872d-0b0e4ca27e49', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('49938c2e-ea1a-4457-ba87-9aae6ed90d05', 'd408fdc4-7f66-4077-b690-895987f359ff', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('49938c2e-ea1a-4457-ba87-9aae6ed90d05', 'e3186677-d366-4dab-b010-097f05ebce45', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('46ec9a3e-e6d8-46a1-a214-60f8d6d5a95f', 'b0a2789d-ca22-4811-822f-252f6c5b3b9d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('46ec9a3e-e6d8-46a1-a214-60f8d6d5a95f', '1a89c394-141c-4527-9e7a-9de8a66b47d6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('46ec9a3e-e6d8-46a1-a214-60f8d6d5a95f', '59bdcca6-40cc-4075-b32f-82aa15adaa11', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('46ec9a3e-e6d8-46a1-a214-60f8d6d5a95f', '49938c2e-ea1a-4457-ba87-9aae6ed90d05', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('46ec9a3e-e6d8-46a1-a214-60f8d6d5a95f', '74f92f70-5d8a-47c6-97d4-e92e95b83b46', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('74f92f70-5d8a-47c6-97d4-e92e95b83b46', '449d498f-7c20-49d5-a06d-36166f892b9d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('74f92f70-5d8a-47c6-97d4-e92e95b83b46', '59bdcca6-40cc-4075-b32f-82aa15adaa11', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('74f92f70-5d8a-47c6-97d4-e92e95b83b46', '49938c2e-ea1a-4457-ba87-9aae6ed90d05', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('74f92f70-5d8a-47c6-97d4-e92e95b83b46', '46ec9a3e-e6d8-46a1-a214-60f8d6d5a95f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('74f92f70-5d8a-47c6-97d4-e92e95b83b46', 'f366fad7-2dfe-4829-8f71-8f767524c0c5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('449d498f-7c20-49d5-a06d-36166f892b9d', '74f92f70-5d8a-47c6-97d4-e92e95b83b46', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('449d498f-7c20-49d5-a06d-36166f892b9d', '59bdcca6-40cc-4075-b32f-82aa15adaa11', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('449d498f-7c20-49d5-a06d-36166f892b9d', '49938c2e-ea1a-4457-ba87-9aae6ed90d05', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('449d498f-7c20-49d5-a06d-36166f892b9d', '46ec9a3e-e6d8-46a1-a214-60f8d6d5a95f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('449d498f-7c20-49d5-a06d-36166f892b9d', 'f366fad7-2dfe-4829-8f71-8f767524c0c5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f366fad7-2dfe-4829-8f71-8f767524c0c5', '59bdcca6-40cc-4075-b32f-82aa15adaa11', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f366fad7-2dfe-4829-8f71-8f767524c0c5', '49938c2e-ea1a-4457-ba87-9aae6ed90d05', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f366fad7-2dfe-4829-8f71-8f767524c0c5', '757066d3-e325-43c1-872d-0b0e4ca27e49', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f366fad7-2dfe-4829-8f71-8f767524c0c5', 'd408fdc4-7f66-4077-b690-895987f359ff', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f366fad7-2dfe-4829-8f71-8f767524c0c5', 'e3186677-d366-4dab-b010-097f05ebce45', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('757066d3-e325-43c1-872d-0b0e4ca27e49', '59bdcca6-40cc-4075-b32f-82aa15adaa11', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('757066d3-e325-43c1-872d-0b0e4ca27e49', '49938c2e-ea1a-4457-ba87-9aae6ed90d05', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('757066d3-e325-43c1-872d-0b0e4ca27e49', 'f366fad7-2dfe-4829-8f71-8f767524c0c5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('757066d3-e325-43c1-872d-0b0e4ca27e49', 'd408fdc4-7f66-4077-b690-895987f359ff', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('757066d3-e325-43c1-872d-0b0e4ca27e49', 'e3186677-d366-4dab-b010-097f05ebce45', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b0a2789d-ca22-4811-822f-252f6c5b3b9d', '46ec9a3e-e6d8-46a1-a214-60f8d6d5a95f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b0a2789d-ca22-4811-822f-252f6c5b3b9d', '1a89c394-141c-4527-9e7a-9de8a66b47d6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b0a2789d-ca22-4811-822f-252f6c5b3b9d', '59bdcca6-40cc-4075-b32f-82aa15adaa11', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b0a2789d-ca22-4811-822f-252f6c5b3b9d', '49938c2e-ea1a-4457-ba87-9aae6ed90d05', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b0a2789d-ca22-4811-822f-252f6c5b3b9d', '74f92f70-5d8a-47c6-97d4-e92e95b83b46', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d408fdc4-7f66-4077-b690-895987f359ff', '59bdcca6-40cc-4075-b32f-82aa15adaa11', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d408fdc4-7f66-4077-b690-895987f359ff', '49938c2e-ea1a-4457-ba87-9aae6ed90d05', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d408fdc4-7f66-4077-b690-895987f359ff', 'f366fad7-2dfe-4829-8f71-8f767524c0c5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d408fdc4-7f66-4077-b690-895987f359ff', '757066d3-e325-43c1-872d-0b0e4ca27e49', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d408fdc4-7f66-4077-b690-895987f359ff', 'e3186677-d366-4dab-b010-097f05ebce45', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1a89c394-141c-4527-9e7a-9de8a66b47d6', '46ec9a3e-e6d8-46a1-a214-60f8d6d5a95f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1a89c394-141c-4527-9e7a-9de8a66b47d6', 'b0a2789d-ca22-4811-822f-252f6c5b3b9d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1a89c394-141c-4527-9e7a-9de8a66b47d6', '59bdcca6-40cc-4075-b32f-82aa15adaa11', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1a89c394-141c-4527-9e7a-9de8a66b47d6', '49938c2e-ea1a-4457-ba87-9aae6ed90d05', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1a89c394-141c-4527-9e7a-9de8a66b47d6', '74f92f70-5d8a-47c6-97d4-e92e95b83b46', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ebcb428a-ed74-4478-ab6e-bec5ce73c3cc', '99ac9e6a-2be1-434d-8077-c4f06813c064', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ebcb428a-ed74-4478-ab6e-bec5ce73c3cc', 'f2536b24-9ed7-4d99-94a9-945728e1dc50', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ebcb428a-ed74-4478-ab6e-bec5ce73c3cc', 'a0651b82-2757-42ca-bbda-0f59168ec008', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ebcb428a-ed74-4478-ab6e-bec5ce73c3cc', 'b16dbf7f-d33d-4f09-8625-e560b07131dd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ebcb428a-ed74-4478-ab6e-bec5ce73c3cc', '11317970-ac8f-4c13-818b-e63b47d6c94c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('99ac9e6a-2be1-434d-8077-c4f06813c064', 'f2536b24-9ed7-4d99-94a9-945728e1dc50', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('99ac9e6a-2be1-434d-8077-c4f06813c064', 'a0651b82-2757-42ca-bbda-0f59168ec008', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('99ac9e6a-2be1-434d-8077-c4f06813c064', '11317970-ac8f-4c13-818b-e63b47d6c94c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('99ac9e6a-2be1-434d-8077-c4f06813c064', '853950b8-faa7-4acc-be42-338e1ad6fec2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('99ac9e6a-2be1-434d-8077-c4f06813c064', 'ebcb428a-ed74-4478-ab6e-bec5ce73c3cc', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f2536b24-9ed7-4d99-94a9-945728e1dc50', '99ac9e6a-2be1-434d-8077-c4f06813c064', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f2536b24-9ed7-4d99-94a9-945728e1dc50', 'a0651b82-2757-42ca-bbda-0f59168ec008', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f2536b24-9ed7-4d99-94a9-945728e1dc50', '11317970-ac8f-4c13-818b-e63b47d6c94c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f2536b24-9ed7-4d99-94a9-945728e1dc50', '853950b8-faa7-4acc-be42-338e1ad6fec2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f2536b24-9ed7-4d99-94a9-945728e1dc50', 'ebcb428a-ed74-4478-ab6e-bec5ce73c3cc', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0651b82-2757-42ca-bbda-0f59168ec008', '99ac9e6a-2be1-434d-8077-c4f06813c064', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0651b82-2757-42ca-bbda-0f59168ec008', 'f2536b24-9ed7-4d99-94a9-945728e1dc50', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0651b82-2757-42ca-bbda-0f59168ec008', '11317970-ac8f-4c13-818b-e63b47d6c94c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0651b82-2757-42ca-bbda-0f59168ec008', '853950b8-faa7-4acc-be42-338e1ad6fec2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0651b82-2757-42ca-bbda-0f59168ec008', 'ebcb428a-ed74-4478-ab6e-bec5ce73c3cc', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b16dbf7f-d33d-4f09-8625-e560b07131dd', 'ebcb428a-ed74-4478-ab6e-bec5ce73c3cc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b16dbf7f-d33d-4f09-8625-e560b07131dd', '99ac9e6a-2be1-434d-8077-c4f06813c064', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b16dbf7f-d33d-4f09-8625-e560b07131dd', 'f2536b24-9ed7-4d99-94a9-945728e1dc50', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b16dbf7f-d33d-4f09-8625-e560b07131dd', 'a0651b82-2757-42ca-bbda-0f59168ec008', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b16dbf7f-d33d-4f09-8625-e560b07131dd', '11317970-ac8f-4c13-818b-e63b47d6c94c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('11317970-ac8f-4c13-818b-e63b47d6c94c', '99ac9e6a-2be1-434d-8077-c4f06813c064', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('11317970-ac8f-4c13-818b-e63b47d6c94c', 'f2536b24-9ed7-4d99-94a9-945728e1dc50', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('11317970-ac8f-4c13-818b-e63b47d6c94c', 'a0651b82-2757-42ca-bbda-0f59168ec008', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('11317970-ac8f-4c13-818b-e63b47d6c94c', '853950b8-faa7-4acc-be42-338e1ad6fec2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('11317970-ac8f-4c13-818b-e63b47d6c94c', 'ebcb428a-ed74-4478-ab6e-bec5ce73c3cc', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('853950b8-faa7-4acc-be42-338e1ad6fec2', '99ac9e6a-2be1-434d-8077-c4f06813c064', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('853950b8-faa7-4acc-be42-338e1ad6fec2', 'f2536b24-9ed7-4d99-94a9-945728e1dc50', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('853950b8-faa7-4acc-be42-338e1ad6fec2', 'a0651b82-2757-42ca-bbda-0f59168ec008', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('853950b8-faa7-4acc-be42-338e1ad6fec2', '11317970-ac8f-4c13-818b-e63b47d6c94c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('853950b8-faa7-4acc-be42-338e1ad6fec2', 'ebcb428a-ed74-4478-ab6e-bec5ce73c3cc', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('679e569a-80ab-41e9-86ee-c929df41a088', 'bb44dee0-bd60-4f4a-8ca3-17a5f544f1c5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('679e569a-80ab-41e9-86ee-c929df41a088', 'f4711051-8eb7-4cd0-885d-e3ae3c9268a4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('679e569a-80ab-41e9-86ee-c929df41a088', '8949d898-6a4e-4397-8529-3ef96cb65c75', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('679e569a-80ab-41e9-86ee-c929df41a088', '1e3cf9ee-5435-40b2-94a7-76db653a5f3d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('679e569a-80ab-41e9-86ee-c929df41a088', 'c87a85ba-2fe0-42c9-b771-31c2d0a12c53', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bb44dee0-bd60-4f4a-8ca3-17a5f544f1c5', '679e569a-80ab-41e9-86ee-c929df41a088', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bb44dee0-bd60-4f4a-8ca3-17a5f544f1c5', 'f4711051-8eb7-4cd0-885d-e3ae3c9268a4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bb44dee0-bd60-4f4a-8ca3-17a5f544f1c5', '8949d898-6a4e-4397-8529-3ef96cb65c75', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bb44dee0-bd60-4f4a-8ca3-17a5f544f1c5', '1e3cf9ee-5435-40b2-94a7-76db653a5f3d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bb44dee0-bd60-4f4a-8ca3-17a5f544f1c5', 'c87a85ba-2fe0-42c9-b771-31c2d0a12c53', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f4711051-8eb7-4cd0-885d-e3ae3c9268a4', '679e569a-80ab-41e9-86ee-c929df41a088', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f4711051-8eb7-4cd0-885d-e3ae3c9268a4', 'bb44dee0-bd60-4f4a-8ca3-17a5f544f1c5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f4711051-8eb7-4cd0-885d-e3ae3c9268a4', '8949d898-6a4e-4397-8529-3ef96cb65c75', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f4711051-8eb7-4cd0-885d-e3ae3c9268a4', '1e3cf9ee-5435-40b2-94a7-76db653a5f3d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f4711051-8eb7-4cd0-885d-e3ae3c9268a4', 'c87a85ba-2fe0-42c9-b771-31c2d0a12c53', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c87a85ba-2fe0-42c9-b771-31c2d0a12c53', '679e569a-80ab-41e9-86ee-c929df41a088', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c87a85ba-2fe0-42c9-b771-31c2d0a12c53', 'bb44dee0-bd60-4f4a-8ca3-17a5f544f1c5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c87a85ba-2fe0-42c9-b771-31c2d0a12c53', 'f4711051-8eb7-4cd0-885d-e3ae3c9268a4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c87a85ba-2fe0-42c9-b771-31c2d0a12c53', '8949d898-6a4e-4397-8529-3ef96cb65c75', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c87a85ba-2fe0-42c9-b771-31c2d0a12c53', '1e3cf9ee-5435-40b2-94a7-76db653a5f3d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8949d898-6a4e-4397-8529-3ef96cb65c75', '679e569a-80ab-41e9-86ee-c929df41a088', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8949d898-6a4e-4397-8529-3ef96cb65c75', 'bb44dee0-bd60-4f4a-8ca3-17a5f544f1c5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8949d898-6a4e-4397-8529-3ef96cb65c75', 'f4711051-8eb7-4cd0-885d-e3ae3c9268a4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8949d898-6a4e-4397-8529-3ef96cb65c75', '1e3cf9ee-5435-40b2-94a7-76db653a5f3d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8949d898-6a4e-4397-8529-3ef96cb65c75', 'c87a85ba-2fe0-42c9-b771-31c2d0a12c53', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1e3cf9ee-5435-40b2-94a7-76db653a5f3d', '679e569a-80ab-41e9-86ee-c929df41a088', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1e3cf9ee-5435-40b2-94a7-76db653a5f3d', 'bb44dee0-bd60-4f4a-8ca3-17a5f544f1c5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1e3cf9ee-5435-40b2-94a7-76db653a5f3d', 'f4711051-8eb7-4cd0-885d-e3ae3c9268a4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1e3cf9ee-5435-40b2-94a7-76db653a5f3d', '8949d898-6a4e-4397-8529-3ef96cb65c75', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1e3cf9ee-5435-40b2-94a7-76db653a5f3d', 'c87a85ba-2fe0-42c9-b771-31c2d0a12c53', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3186677-d366-4dab-b010-097f05ebce45', '59bdcca6-40cc-4075-b32f-82aa15adaa11', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3186677-d366-4dab-b010-097f05ebce45', '49938c2e-ea1a-4457-ba87-9aae6ed90d05', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3186677-d366-4dab-b010-097f05ebce45', 'f366fad7-2dfe-4829-8f71-8f767524c0c5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3186677-d366-4dab-b010-097f05ebce45', '757066d3-e325-43c1-872d-0b0e4ca27e49', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3186677-d366-4dab-b010-097f05ebce45', 'd408fdc4-7f66-4077-b690-895987f359ff', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e6846da6-016e-4da7-a92a-2c81f3f8dcf9', 'ebcb428a-ed74-4478-ab6e-bec5ce73c3cc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e6846da6-016e-4da7-a92a-2c81f3f8dcf9', '99ac9e6a-2be1-434d-8077-c4f06813c064', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e6846da6-016e-4da7-a92a-2c81f3f8dcf9', 'f2536b24-9ed7-4d99-94a9-945728e1dc50', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e6846da6-016e-4da7-a92a-2c81f3f8dcf9', 'a0651b82-2757-42ca-bbda-0f59168ec008', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e6846da6-016e-4da7-a92a-2c81f3f8dcf9', 'b16dbf7f-d33d-4f09-8625-e560b07131dd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1c9586ef-4b5b-4cb6-b297-c2f207a5f83d', '5303dd6c-34de-4b6f-b388-45d7b7d97dfe', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1c9586ef-4b5b-4cb6-b297-c2f207a5f83d', '839d8a61-5e7f-4b31-9a10-1d6164067302', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1c9586ef-4b5b-4cb6-b297-c2f207a5f83d', 'c6428037-8c1a-47b4-acf4-8d9877e4d192', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5303dd6c-34de-4b6f-b388-45d7b7d97dfe', '1c9586ef-4b5b-4cb6-b297-c2f207a5f83d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5303dd6c-34de-4b6f-b388-45d7b7d97dfe', '839d8a61-5e7f-4b31-9a10-1d6164067302', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5303dd6c-34de-4b6f-b388-45d7b7d97dfe', 'c6428037-8c1a-47b4-acf4-8d9877e4d192', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('839d8a61-5e7f-4b31-9a10-1d6164067302', '1c9586ef-4b5b-4cb6-b297-c2f207a5f83d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('839d8a61-5e7f-4b31-9a10-1d6164067302', '5303dd6c-34de-4b6f-b388-45d7b7d97dfe', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('839d8a61-5e7f-4b31-9a10-1d6164067302', 'c6428037-8c1a-47b4-acf4-8d9877e4d192', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6428037-8c1a-47b4-acf4-8d9877e4d192', '1c9586ef-4b5b-4cb6-b297-c2f207a5f83d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6428037-8c1a-47b4-acf4-8d9877e4d192', '5303dd6c-34de-4b6f-b388-45d7b7d97dfe', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6428037-8c1a-47b4-acf4-8d9877e4d192', '839d8a61-5e7f-4b31-9a10-1d6164067302', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('894061a6-00e6-4563-9a74-d0f4a8219e6f', '1000226b-ca06-469e-801b-1681d398f742', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('894061a6-00e6-4563-9a74-d0f4a8219e6f', '11478028-d875-4975-bc1c-22547440c675', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('894061a6-00e6-4563-9a74-d0f4a8219e6f', 'f1719b2e-03ae-4ce6-b037-01d3f958e86b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('894061a6-00e6-4563-9a74-d0f4a8219e6f', '2ff6f83f-aaf5-4360-9885-8a81ce3bfd4c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('894061a6-00e6-4563-9a74-d0f4a8219e6f', 'a9201dc3-6efd-4cc5-89bf-9218e46ab278', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d5212195-338c-4708-bbbe-3791fcd758c7', '479fd45f-58bc-46ba-8164-3e63ae671285', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d5212195-338c-4708-bbbe-3791fcd758c7', 'c77249ad-559f-4618-9603-c40e0a6727b4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d5212195-338c-4708-bbbe-3791fcd758c7', '96653e7b-58d3-42c0-b939-dc953c9a1d19', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d5212195-338c-4708-bbbe-3791fcd758c7', '6987fbc1-6f31-497d-bd26-089fd8febd6e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d5212195-338c-4708-bbbe-3791fcd758c7', '82aa4b80-f785-4a15-b3a8-ddeb35fc64ea', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1000226b-ca06-469e-801b-1681d398f742', '894061a6-00e6-4563-9a74-d0f4a8219e6f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1000226b-ca06-469e-801b-1681d398f742', '11478028-d875-4975-bc1c-22547440c675', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1000226b-ca06-469e-801b-1681d398f742', 'f1719b2e-03ae-4ce6-b037-01d3f958e86b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1000226b-ca06-469e-801b-1681d398f742', '2ff6f83f-aaf5-4360-9885-8a81ce3bfd4c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1000226b-ca06-469e-801b-1681d398f742', 'a9201dc3-6efd-4cc5-89bf-9218e46ab278', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6987fbc1-6f31-497d-bd26-089fd8febd6e', 'd5212195-338c-4708-bbbe-3791fcd758c7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6987fbc1-6f31-497d-bd26-089fd8febd6e', '479fd45f-58bc-46ba-8164-3e63ae671285', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6987fbc1-6f31-497d-bd26-089fd8febd6e', 'c77249ad-559f-4618-9603-c40e0a6727b4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6987fbc1-6f31-497d-bd26-089fd8febd6e', '96653e7b-58d3-42c0-b939-dc953c9a1d19', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6987fbc1-6f31-497d-bd26-089fd8febd6e', '82aa4b80-f785-4a15-b3a8-ddeb35fc64ea', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a37021a2-dc38-4ac4-b709-f688866416b0', '1c9586ef-4b5b-4cb6-b297-c2f207a5f83d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a37021a2-dc38-4ac4-b709-f688866416b0', '5303dd6c-34de-4b6f-b388-45d7b7d97dfe', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a37021a2-dc38-4ac4-b709-f688866416b0', '839d8a61-5e7f-4b31-9a10-1d6164067302', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a37021a2-dc38-4ac4-b709-f688866416b0', 'c6428037-8c1a-47b4-acf4-8d9877e4d192', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f1719b2e-03ae-4ce6-b037-01d3f958e86b', '2ff6f83f-aaf5-4360-9885-8a81ce3bfd4c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f1719b2e-03ae-4ce6-b037-01d3f958e86b', 'a9201dc3-6efd-4cc5-89bf-9218e46ab278', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f1719b2e-03ae-4ce6-b037-01d3f958e86b', '5f0b1fc8-bb6a-4d3c-b893-b52b7dcc0055', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f1719b2e-03ae-4ce6-b037-01d3f958e86b', '2e0518c5-9b1c-47d2-ab4f-349d9ffe95c5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f1719b2e-03ae-4ce6-b037-01d3f958e86b', '894061a6-00e6-4563-9a74-d0f4a8219e6f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2ff6f83f-aaf5-4360-9885-8a81ce3bfd4c', 'f1719b2e-03ae-4ce6-b037-01d3f958e86b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2ff6f83f-aaf5-4360-9885-8a81ce3bfd4c', 'a9201dc3-6efd-4cc5-89bf-9218e46ab278', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2ff6f83f-aaf5-4360-9885-8a81ce3bfd4c', '5f0b1fc8-bb6a-4d3c-b893-b52b7dcc0055', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2ff6f83f-aaf5-4360-9885-8a81ce3bfd4c', '2e0518c5-9b1c-47d2-ab4f-349d9ffe95c5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2ff6f83f-aaf5-4360-9885-8a81ce3bfd4c', '894061a6-00e6-4563-9a74-d0f4a8219e6f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a9201dc3-6efd-4cc5-89bf-9218e46ab278', 'f1719b2e-03ae-4ce6-b037-01d3f958e86b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a9201dc3-6efd-4cc5-89bf-9218e46ab278', '2ff6f83f-aaf5-4360-9885-8a81ce3bfd4c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a9201dc3-6efd-4cc5-89bf-9218e46ab278', '5f0b1fc8-bb6a-4d3c-b893-b52b7dcc0055', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a9201dc3-6efd-4cc5-89bf-9218e46ab278', '2e0518c5-9b1c-47d2-ab4f-349d9ffe95c5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a9201dc3-6efd-4cc5-89bf-9218e46ab278', '894061a6-00e6-4563-9a74-d0f4a8219e6f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5f0b1fc8-bb6a-4d3c-b893-b52b7dcc0055', 'f1719b2e-03ae-4ce6-b037-01d3f958e86b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5f0b1fc8-bb6a-4d3c-b893-b52b7dcc0055', '2ff6f83f-aaf5-4360-9885-8a81ce3bfd4c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5f0b1fc8-bb6a-4d3c-b893-b52b7dcc0055', 'a9201dc3-6efd-4cc5-89bf-9218e46ab278', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5f0b1fc8-bb6a-4d3c-b893-b52b7dcc0055', '2e0518c5-9b1c-47d2-ab4f-349d9ffe95c5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5f0b1fc8-bb6a-4d3c-b893-b52b7dcc0055', '894061a6-00e6-4563-9a74-d0f4a8219e6f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('346479c6-e553-473d-83b6-23984d575ebd', '894061a6-00e6-4563-9a74-d0f4a8219e6f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('346479c6-e553-473d-83b6-23984d575ebd', '1000226b-ca06-469e-801b-1681d398f742', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('346479c6-e553-473d-83b6-23984d575ebd', 'f1719b2e-03ae-4ce6-b037-01d3f958e86b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('346479c6-e553-473d-83b6-23984d575ebd', '2ff6f83f-aaf5-4360-9885-8a81ce3bfd4c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('346479c6-e553-473d-83b6-23984d575ebd', 'a9201dc3-6efd-4cc5-89bf-9218e46ab278', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2e0518c5-9b1c-47d2-ab4f-349d9ffe95c5', 'f1719b2e-03ae-4ce6-b037-01d3f958e86b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2e0518c5-9b1c-47d2-ab4f-349d9ffe95c5', '2ff6f83f-aaf5-4360-9885-8a81ce3bfd4c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2e0518c5-9b1c-47d2-ab4f-349d9ffe95c5', 'a9201dc3-6efd-4cc5-89bf-9218e46ab278', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2e0518c5-9b1c-47d2-ab4f-349d9ffe95c5', '5f0b1fc8-bb6a-4d3c-b893-b52b7dcc0055', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2e0518c5-9b1c-47d2-ab4f-349d9ffe95c5', '894061a6-00e6-4563-9a74-d0f4a8219e6f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('11478028-d875-4975-bc1c-22547440c675', '894061a6-00e6-4563-9a74-d0f4a8219e6f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('11478028-d875-4975-bc1c-22547440c675', '1000226b-ca06-469e-801b-1681d398f742', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('11478028-d875-4975-bc1c-22547440c675', 'f1719b2e-03ae-4ce6-b037-01d3f958e86b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('11478028-d875-4975-bc1c-22547440c675', '2ff6f83f-aaf5-4360-9885-8a81ce3bfd4c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('11478028-d875-4975-bc1c-22547440c675', 'a9201dc3-6efd-4cc5-89bf-9218e46ab278', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab1b2f8b-9406-4b39-8c2e-c0b7b7e665aa', '1c9586ef-4b5b-4cb6-b297-c2f207a5f83d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab1b2f8b-9406-4b39-8c2e-c0b7b7e665aa', '5303dd6c-34de-4b6f-b388-45d7b7d97dfe', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab1b2f8b-9406-4b39-8c2e-c0b7b7e665aa', '839d8a61-5e7f-4b31-9a10-1d6164067302', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab1b2f8b-9406-4b39-8c2e-c0b7b7e665aa', 'c6428037-8c1a-47b4-acf4-8d9877e4d192', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2c645aa5-fcf7-4c55-952a-00efdb93e362', 'f1450a30-ff11-47f1-b94b-48884a641628', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2c645aa5-fcf7-4c55-952a-00efdb93e362', '31bc2147-9b7d-436d-8c9a-882d0d19d531', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2c645aa5-fcf7-4c55-952a-00efdb93e362', 'c56b6734-1a78-443d-86b0-10689f0faf6f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2c645aa5-fcf7-4c55-952a-00efdb93e362', 'c011b0c4-82e1-4660-8007-185c3fa20cb5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2c645aa5-fcf7-4c55-952a-00efdb93e362', '6ec77b27-0d18-4e92-9a5f-656c59b46941', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('df9370e2-8766-423e-872b-492481c39e5e', 'f1450a30-ff11-47f1-b94b-48884a641628', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('df9370e2-8766-423e-872b-492481c39e5e', '31bc2147-9b7d-436d-8c9a-882d0d19d531', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('df9370e2-8766-423e-872b-492481c39e5e', 'c56b6734-1a78-443d-86b0-10689f0faf6f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('df9370e2-8766-423e-872b-492481c39e5e', 'c011b0c4-82e1-4660-8007-185c3fa20cb5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('df9370e2-8766-423e-872b-492481c39e5e', '6ec77b27-0d18-4e92-9a5f-656c59b46941', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f1450a30-ff11-47f1-b94b-48884a641628', '31bc2147-9b7d-436d-8c9a-882d0d19d531', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f1450a30-ff11-47f1-b94b-48884a641628', 'c56b6734-1a78-443d-86b0-10689f0faf6f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f1450a30-ff11-47f1-b94b-48884a641628', 'c011b0c4-82e1-4660-8007-185c3fa20cb5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f1450a30-ff11-47f1-b94b-48884a641628', '6ec77b27-0d18-4e92-9a5f-656c59b46941', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f1450a30-ff11-47f1-b94b-48884a641628', '0bd67926-0d76-4d08-9321-0fc9d891fd8f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('31bc2147-9b7d-436d-8c9a-882d0d19d531', 'f1450a30-ff11-47f1-b94b-48884a641628', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('31bc2147-9b7d-436d-8c9a-882d0d19d531', 'c56b6734-1a78-443d-86b0-10689f0faf6f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('31bc2147-9b7d-436d-8c9a-882d0d19d531', 'c011b0c4-82e1-4660-8007-185c3fa20cb5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('31bc2147-9b7d-436d-8c9a-882d0d19d531', '6ec77b27-0d18-4e92-9a5f-656c59b46941', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('31bc2147-9b7d-436d-8c9a-882d0d19d531', '0bd67926-0d76-4d08-9321-0fc9d891fd8f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c56b6734-1a78-443d-86b0-10689f0faf6f', 'f1450a30-ff11-47f1-b94b-48884a641628', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c56b6734-1a78-443d-86b0-10689f0faf6f', '31bc2147-9b7d-436d-8c9a-882d0d19d531', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c56b6734-1a78-443d-86b0-10689f0faf6f', 'c011b0c4-82e1-4660-8007-185c3fa20cb5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c56b6734-1a78-443d-86b0-10689f0faf6f', '6ec77b27-0d18-4e92-9a5f-656c59b46941', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c56b6734-1a78-443d-86b0-10689f0faf6f', '0bd67926-0d76-4d08-9321-0fc9d891fd8f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c011b0c4-82e1-4660-8007-185c3fa20cb5', 'f1450a30-ff11-47f1-b94b-48884a641628', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c011b0c4-82e1-4660-8007-185c3fa20cb5', '31bc2147-9b7d-436d-8c9a-882d0d19d531', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c011b0c4-82e1-4660-8007-185c3fa20cb5', 'c56b6734-1a78-443d-86b0-10689f0faf6f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c011b0c4-82e1-4660-8007-185c3fa20cb5', '6ec77b27-0d18-4e92-9a5f-656c59b46941', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c011b0c4-82e1-4660-8007-185c3fa20cb5', '0bd67926-0d76-4d08-9321-0fc9d891fd8f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6ec77b27-0d18-4e92-9a5f-656c59b46941', 'f1450a30-ff11-47f1-b94b-48884a641628', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6ec77b27-0d18-4e92-9a5f-656c59b46941', '31bc2147-9b7d-436d-8c9a-882d0d19d531', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6ec77b27-0d18-4e92-9a5f-656c59b46941', 'c56b6734-1a78-443d-86b0-10689f0faf6f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6ec77b27-0d18-4e92-9a5f-656c59b46941', 'c011b0c4-82e1-4660-8007-185c3fa20cb5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6ec77b27-0d18-4e92-9a5f-656c59b46941', '0bd67926-0d76-4d08-9321-0fc9d891fd8f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0bd67926-0d76-4d08-9321-0fc9d891fd8f', 'f1450a30-ff11-47f1-b94b-48884a641628', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0bd67926-0d76-4d08-9321-0fc9d891fd8f', '31bc2147-9b7d-436d-8c9a-882d0d19d531', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0bd67926-0d76-4d08-9321-0fc9d891fd8f', 'c56b6734-1a78-443d-86b0-10689f0faf6f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0bd67926-0d76-4d08-9321-0fc9d891fd8f', 'c011b0c4-82e1-4660-8007-185c3fa20cb5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0bd67926-0d76-4d08-9321-0fc9d891fd8f', '6ec77b27-0d18-4e92-9a5f-656c59b46941', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('28767603-fb98-4809-bf5a-7275fb381e81', 'f1450a30-ff11-47f1-b94b-48884a641628', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('28767603-fb98-4809-bf5a-7275fb381e81', '31bc2147-9b7d-436d-8c9a-882d0d19d531', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('28767603-fb98-4809-bf5a-7275fb381e81', 'c56b6734-1a78-443d-86b0-10689f0faf6f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('28767603-fb98-4809-bf5a-7275fb381e81', 'c011b0c4-82e1-4660-8007-185c3fa20cb5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('28767603-fb98-4809-bf5a-7275fb381e81', '6ec77b27-0d18-4e92-9a5f-656c59b46941', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('364c7ccb-df98-4975-b6de-7ecf9216adf9', 'dc1f23bd-aaa8-4ac2-9677-69c845e3fe60', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('364c7ccb-df98-4975-b6de-7ecf9216adf9', '3a369231-0454-431e-9e3b-ab822ca20144', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('364c7ccb-df98-4975-b6de-7ecf9216adf9', 'c44cd8c0-90a7-40dc-aa5a-e0e6ca70f32e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('364c7ccb-df98-4975-b6de-7ecf9216adf9', '22e3f4b6-df2b-461e-bb20-6c4fa1afd356', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('364c7ccb-df98-4975-b6de-7ecf9216adf9', '7731f184-af43-4e35-87d6-6c28566a50f2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dc1f23bd-aaa8-4ac2-9677-69c845e3fe60', '364c7ccb-df98-4975-b6de-7ecf9216adf9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dc1f23bd-aaa8-4ac2-9677-69c845e3fe60', '3a369231-0454-431e-9e3b-ab822ca20144', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dc1f23bd-aaa8-4ac2-9677-69c845e3fe60', 'c44cd8c0-90a7-40dc-aa5a-e0e6ca70f32e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dc1f23bd-aaa8-4ac2-9677-69c845e3fe60', '22e3f4b6-df2b-461e-bb20-6c4fa1afd356', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dc1f23bd-aaa8-4ac2-9677-69c845e3fe60', '7731f184-af43-4e35-87d6-6c28566a50f2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a369231-0454-431e-9e3b-ab822ca20144', '364c7ccb-df98-4975-b6de-7ecf9216adf9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a369231-0454-431e-9e3b-ab822ca20144', 'dc1f23bd-aaa8-4ac2-9677-69c845e3fe60', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a369231-0454-431e-9e3b-ab822ca20144', 'c44cd8c0-90a7-40dc-aa5a-e0e6ca70f32e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a369231-0454-431e-9e3b-ab822ca20144', '22e3f4b6-df2b-461e-bb20-6c4fa1afd356', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a369231-0454-431e-9e3b-ab822ca20144', '7731f184-af43-4e35-87d6-6c28566a50f2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c44cd8c0-90a7-40dc-aa5a-e0e6ca70f32e', '364c7ccb-df98-4975-b6de-7ecf9216adf9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c44cd8c0-90a7-40dc-aa5a-e0e6ca70f32e', 'dc1f23bd-aaa8-4ac2-9677-69c845e3fe60', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c44cd8c0-90a7-40dc-aa5a-e0e6ca70f32e', '3a369231-0454-431e-9e3b-ab822ca20144', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c44cd8c0-90a7-40dc-aa5a-e0e6ca70f32e', '22e3f4b6-df2b-461e-bb20-6c4fa1afd356', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c44cd8c0-90a7-40dc-aa5a-e0e6ca70f32e', '7731f184-af43-4e35-87d6-6c28566a50f2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22e3f4b6-df2b-461e-bb20-6c4fa1afd356', '364c7ccb-df98-4975-b6de-7ecf9216adf9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22e3f4b6-df2b-461e-bb20-6c4fa1afd356', 'dc1f23bd-aaa8-4ac2-9677-69c845e3fe60', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22e3f4b6-df2b-461e-bb20-6c4fa1afd356', '3a369231-0454-431e-9e3b-ab822ca20144', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22e3f4b6-df2b-461e-bb20-6c4fa1afd356', 'c44cd8c0-90a7-40dc-aa5a-e0e6ca70f32e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22e3f4b6-df2b-461e-bb20-6c4fa1afd356', '7731f184-af43-4e35-87d6-6c28566a50f2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7731f184-af43-4e35-87d6-6c28566a50f2', '364c7ccb-df98-4975-b6de-7ecf9216adf9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7731f184-af43-4e35-87d6-6c28566a50f2', 'dc1f23bd-aaa8-4ac2-9677-69c845e3fe60', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7731f184-af43-4e35-87d6-6c28566a50f2', '3a369231-0454-431e-9e3b-ab822ca20144', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7731f184-af43-4e35-87d6-6c28566a50f2', 'c44cd8c0-90a7-40dc-aa5a-e0e6ca70f32e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7731f184-af43-4e35-87d6-6c28566a50f2', '22e3f4b6-df2b-461e-bb20-6c4fa1afd356', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('edb97e21-ca32-4cf0-b920-0e52bbcf5318', '364c7ccb-df98-4975-b6de-7ecf9216adf9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('edb97e21-ca32-4cf0-b920-0e52bbcf5318', 'dc1f23bd-aaa8-4ac2-9677-69c845e3fe60', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('edb97e21-ca32-4cf0-b920-0e52bbcf5318', '3a369231-0454-431e-9e3b-ab822ca20144', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('edb97e21-ca32-4cf0-b920-0e52bbcf5318', 'c44cd8c0-90a7-40dc-aa5a-e0e6ca70f32e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('edb97e21-ca32-4cf0-b920-0e52bbcf5318', '22e3f4b6-df2b-461e-bb20-6c4fa1afd356', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4977e165-93a6-4a15-80b1-2b301db1e060', '364c7ccb-df98-4975-b6de-7ecf9216adf9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4977e165-93a6-4a15-80b1-2b301db1e060', 'dc1f23bd-aaa8-4ac2-9677-69c845e3fe60', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4977e165-93a6-4a15-80b1-2b301db1e060', '3a369231-0454-431e-9e3b-ab822ca20144', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4977e165-93a6-4a15-80b1-2b301db1e060', 'c44cd8c0-90a7-40dc-aa5a-e0e6ca70f32e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4977e165-93a6-4a15-80b1-2b301db1e060', '22e3f4b6-df2b-461e-bb20-6c4fa1afd356', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8da145ec-8904-414f-9e49-d73990479f9d', 'bc3ad3ee-6912-43e5-b1b4-b336d3beb5cc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8da145ec-8904-414f-9e49-d73990479f9d', '364c7ccb-df98-4975-b6de-7ecf9216adf9', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8da145ec-8904-414f-9e49-d73990479f9d', 'dc1f23bd-aaa8-4ac2-9677-69c845e3fe60', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8da145ec-8904-414f-9e49-d73990479f9d', '3a369231-0454-431e-9e3b-ab822ca20144', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8da145ec-8904-414f-9e49-d73990479f9d', 'c44cd8c0-90a7-40dc-aa5a-e0e6ca70f32e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4421f971-8e7b-489c-a7b9-a92bfa2fbb80', 'f1450a30-ff11-47f1-b94b-48884a641628', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4421f971-8e7b-489c-a7b9-a92bfa2fbb80', '31bc2147-9b7d-436d-8c9a-882d0d19d531', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4421f971-8e7b-489c-a7b9-a92bfa2fbb80', 'c56b6734-1a78-443d-86b0-10689f0faf6f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4421f971-8e7b-489c-a7b9-a92bfa2fbb80', 'c011b0c4-82e1-4660-8007-185c3fa20cb5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4421f971-8e7b-489c-a7b9-a92bfa2fbb80', '6ec77b27-0d18-4e92-9a5f-656c59b46941', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bc3ad3ee-6912-43e5-b1b4-b336d3beb5cc', '8da145ec-8904-414f-9e49-d73990479f9d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bc3ad3ee-6912-43e5-b1b4-b336d3beb5cc', '364c7ccb-df98-4975-b6de-7ecf9216adf9', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bc3ad3ee-6912-43e5-b1b4-b336d3beb5cc', 'dc1f23bd-aaa8-4ac2-9677-69c845e3fe60', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bc3ad3ee-6912-43e5-b1b4-b336d3beb5cc', '3a369231-0454-431e-9e3b-ab822ca20144', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bc3ad3ee-6912-43e5-b1b4-b336d3beb5cc', 'c44cd8c0-90a7-40dc-aa5a-e0e6ca70f32e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7dc7a1da-135e-43c2-b6c8-c67f1075243b', '84c1f552-b912-4208-b48d-1c27e4d9eb2b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7dc7a1da-135e-43c2-b6c8-c67f1075243b', 'a6b409f1-eea9-40b0-880c-ac07e1e49e2a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7dc7a1da-135e-43c2-b6c8-c67f1075243b', '7d1e4f0c-6928-46d0-9cb5-28142b363eb9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7dc7a1da-135e-43c2-b6c8-c67f1075243b', '48a640bc-19d3-49c4-8ff6-f0b84ea6ff49', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7dc7a1da-135e-43c2-b6c8-c67f1075243b', '11f5c383-b2d6-4bb9-963c-94d96ef41fc7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84c1f552-b912-4208-b48d-1c27e4d9eb2b', '7dc7a1da-135e-43c2-b6c8-c67f1075243b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84c1f552-b912-4208-b48d-1c27e4d9eb2b', 'a6b409f1-eea9-40b0-880c-ac07e1e49e2a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84c1f552-b912-4208-b48d-1c27e4d9eb2b', '7d1e4f0c-6928-46d0-9cb5-28142b363eb9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84c1f552-b912-4208-b48d-1c27e4d9eb2b', '48a640bc-19d3-49c4-8ff6-f0b84ea6ff49', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84c1f552-b912-4208-b48d-1c27e4d9eb2b', '11f5c383-b2d6-4bb9-963c-94d96ef41fc7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6b409f1-eea9-40b0-880c-ac07e1e49e2a', '7dc7a1da-135e-43c2-b6c8-c67f1075243b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6b409f1-eea9-40b0-880c-ac07e1e49e2a', '84c1f552-b912-4208-b48d-1c27e4d9eb2b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6b409f1-eea9-40b0-880c-ac07e1e49e2a', '7d1e4f0c-6928-46d0-9cb5-28142b363eb9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6b409f1-eea9-40b0-880c-ac07e1e49e2a', '48a640bc-19d3-49c4-8ff6-f0b84ea6ff49', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6b409f1-eea9-40b0-880c-ac07e1e49e2a', '11f5c383-b2d6-4bb9-963c-94d96ef41fc7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7d1e4f0c-6928-46d0-9cb5-28142b363eb9', '7dc7a1da-135e-43c2-b6c8-c67f1075243b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7d1e4f0c-6928-46d0-9cb5-28142b363eb9', '84c1f552-b912-4208-b48d-1c27e4d9eb2b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7d1e4f0c-6928-46d0-9cb5-28142b363eb9', 'a6b409f1-eea9-40b0-880c-ac07e1e49e2a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7d1e4f0c-6928-46d0-9cb5-28142b363eb9', '48a640bc-19d3-49c4-8ff6-f0b84ea6ff49', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7d1e4f0c-6928-46d0-9cb5-28142b363eb9', '11f5c383-b2d6-4bb9-963c-94d96ef41fc7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('48a640bc-19d3-49c4-8ff6-f0b84ea6ff49', '7dc7a1da-135e-43c2-b6c8-c67f1075243b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('48a640bc-19d3-49c4-8ff6-f0b84ea6ff49', '84c1f552-b912-4208-b48d-1c27e4d9eb2b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('48a640bc-19d3-49c4-8ff6-f0b84ea6ff49', 'a6b409f1-eea9-40b0-880c-ac07e1e49e2a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('48a640bc-19d3-49c4-8ff6-f0b84ea6ff49', '7d1e4f0c-6928-46d0-9cb5-28142b363eb9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('48a640bc-19d3-49c4-8ff6-f0b84ea6ff49', '11f5c383-b2d6-4bb9-963c-94d96ef41fc7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('98cacd58-9cc0-4831-9561-c11115ed0b7a', '7dc7a1da-135e-43c2-b6c8-c67f1075243b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('98cacd58-9cc0-4831-9561-c11115ed0b7a', '84c1f552-b912-4208-b48d-1c27e4d9eb2b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('98cacd58-9cc0-4831-9561-c11115ed0b7a', 'a6b409f1-eea9-40b0-880c-ac07e1e49e2a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('98cacd58-9cc0-4831-9561-c11115ed0b7a', '7d1e4f0c-6928-46d0-9cb5-28142b363eb9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('98cacd58-9cc0-4831-9561-c11115ed0b7a', '48a640bc-19d3-49c4-8ff6-f0b84ea6ff49', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('11f5c383-b2d6-4bb9-963c-94d96ef41fc7', '7dc7a1da-135e-43c2-b6c8-c67f1075243b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('11f5c383-b2d6-4bb9-963c-94d96ef41fc7', '84c1f552-b912-4208-b48d-1c27e4d9eb2b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('11f5c383-b2d6-4bb9-963c-94d96ef41fc7', 'a6b409f1-eea9-40b0-880c-ac07e1e49e2a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('11f5c383-b2d6-4bb9-963c-94d96ef41fc7', '7d1e4f0c-6928-46d0-9cb5-28142b363eb9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('11f5c383-b2d6-4bb9-963c-94d96ef41fc7', '48a640bc-19d3-49c4-8ff6-f0b84ea6ff49', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a7ebfc73-ce55-4009-9d94-247c69c5a08f', '7dc7a1da-135e-43c2-b6c8-c67f1075243b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a7ebfc73-ce55-4009-9d94-247c69c5a08f', '84c1f552-b912-4208-b48d-1c27e4d9eb2b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a7ebfc73-ce55-4009-9d94-247c69c5a08f', 'a6b409f1-eea9-40b0-880c-ac07e1e49e2a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a7ebfc73-ce55-4009-9d94-247c69c5a08f', '7d1e4f0c-6928-46d0-9cb5-28142b363eb9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a7ebfc73-ce55-4009-9d94-247c69c5a08f', '48a640bc-19d3-49c4-8ff6-f0b84ea6ff49', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39b1c8ad-d6cf-44b1-ae88-5b33e1fb55b0', '7dc7a1da-135e-43c2-b6c8-c67f1075243b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39b1c8ad-d6cf-44b1-ae88-5b33e1fb55b0', '84c1f552-b912-4208-b48d-1c27e4d9eb2b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39b1c8ad-d6cf-44b1-ae88-5b33e1fb55b0', 'a6b409f1-eea9-40b0-880c-ac07e1e49e2a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39b1c8ad-d6cf-44b1-ae88-5b33e1fb55b0', '7d1e4f0c-6928-46d0-9cb5-28142b363eb9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39b1c8ad-d6cf-44b1-ae88-5b33e1fb55b0', '48a640bc-19d3-49c4-8ff6-f0b84ea6ff49', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d6d107e9-f41f-4d52-a01a-c963d3d91cf6', '3be394f2-9365-453f-b8af-1bcdf9e8ebcd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d6d107e9-f41f-4d52-a01a-c963d3d91cf6', 'cd88b969-267e-4090-9fc4-f0b321f362db', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d6d107e9-f41f-4d52-a01a-c963d3d91cf6', '7dc7a1da-135e-43c2-b6c8-c67f1075243b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d6d107e9-f41f-4d52-a01a-c963d3d91cf6', '84c1f552-b912-4208-b48d-1c27e4d9eb2b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d6d107e9-f41f-4d52-a01a-c963d3d91cf6', 'a6b409f1-eea9-40b0-880c-ac07e1e49e2a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3be394f2-9365-453f-b8af-1bcdf9e8ebcd', 'd6d107e9-f41f-4d52-a01a-c963d3d91cf6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3be394f2-9365-453f-b8af-1bcdf9e8ebcd', 'cd88b969-267e-4090-9fc4-f0b321f362db', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3be394f2-9365-453f-b8af-1bcdf9e8ebcd', '7dc7a1da-135e-43c2-b6c8-c67f1075243b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3be394f2-9365-453f-b8af-1bcdf9e8ebcd', '84c1f552-b912-4208-b48d-1c27e4d9eb2b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3be394f2-9365-453f-b8af-1bcdf9e8ebcd', 'a6b409f1-eea9-40b0-880c-ac07e1e49e2a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd88b969-267e-4090-9fc4-f0b321f362db', 'd6d107e9-f41f-4d52-a01a-c963d3d91cf6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd88b969-267e-4090-9fc4-f0b321f362db', '3be394f2-9365-453f-b8af-1bcdf9e8ebcd', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd88b969-267e-4090-9fc4-f0b321f362db', '7dc7a1da-135e-43c2-b6c8-c67f1075243b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd88b969-267e-4090-9fc4-f0b321f362db', '84c1f552-b912-4208-b48d-1c27e4d9eb2b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd88b969-267e-4090-9fc4-f0b321f362db', 'a6b409f1-eea9-40b0-880c-ac07e1e49e2a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('90aed34a-6299-4b8a-baf4-2b09e920f494', '7dc7a1da-135e-43c2-b6c8-c67f1075243b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('90aed34a-6299-4b8a-baf4-2b09e920f494', '84c1f552-b912-4208-b48d-1c27e4d9eb2b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('90aed34a-6299-4b8a-baf4-2b09e920f494', 'a6b409f1-eea9-40b0-880c-ac07e1e49e2a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('90aed34a-6299-4b8a-baf4-2b09e920f494', '7d1e4f0c-6928-46d0-9cb5-28142b363eb9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('90aed34a-6299-4b8a-baf4-2b09e920f494', '48a640bc-19d3-49c4-8ff6-f0b84ea6ff49', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('18115c2a-05e1-4dd1-9ef7-0d17f56b7c7e', '61b83d33-3480-4328-904e-698630e328a9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('18115c2a-05e1-4dd1-9ef7-0d17f56b7c7e', '7dc7a1da-135e-43c2-b6c8-c67f1075243b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('18115c2a-05e1-4dd1-9ef7-0d17f56b7c7e', '84c1f552-b912-4208-b48d-1c27e4d9eb2b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('03eef5ef-0285-462c-a7e1-b6fbd768bb83', '7dc7a1da-135e-43c2-b6c8-c67f1075243b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('03eef5ef-0285-462c-a7e1-b6fbd768bb83', '84c1f552-b912-4208-b48d-1c27e4d9eb2b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('03eef5ef-0285-462c-a7e1-b6fbd768bb83', 'a6b409f1-eea9-40b0-880c-ac07e1e49e2a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('03eef5ef-0285-462c-a7e1-b6fbd768bb83', '7d1e4f0c-6928-46d0-9cb5-28142b363eb9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('03eef5ef-0285-462c-a7e1-b6fbd768bb83', '48a640bc-19d3-49c4-8ff6-f0b84ea6ff49', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('61b83d33-3480-4328-904e-698630e328a9', '18115c2a-05e1-4dd1-9ef7-0d17f56b7c7e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('61b83d33-3480-4328-904e-698630e328a9', '7dc7a1da-135e-43c2-b6c8-c67f1075243b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('61b83d33-3480-4328-904e-698630e328a9', '84c1f552-b912-4208-b48d-1c27e4d9eb2b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('35a12ef3-fcd9-4987-888e-f6d9d378a1e3', '7dc7a1da-135e-43c2-b6c8-c67f1075243b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('35a12ef3-fcd9-4987-888e-f6d9d378a1e3', '84c1f552-b912-4208-b48d-1c27e4d9eb2b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('35a12ef3-fcd9-4987-888e-f6d9d378a1e3', 'a6b409f1-eea9-40b0-880c-ac07e1e49e2a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('35a12ef3-fcd9-4987-888e-f6d9d378a1e3', '7d1e4f0c-6928-46d0-9cb5-28142b363eb9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('35a12ef3-fcd9-4987-888e-f6d9d378a1e3', '48a640bc-19d3-49c4-8ff6-f0b84ea6ff49', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3e6e63c3-b7c5-4a1e-a0e9-8e4a4541f8df', '7dc7a1da-135e-43c2-b6c8-c67f1075243b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3e6e63c3-b7c5-4a1e-a0e9-8e4a4541f8df', '84c1f552-b912-4208-b48d-1c27e4d9eb2b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3e6e63c3-b7c5-4a1e-a0e9-8e4a4541f8df', 'a6b409f1-eea9-40b0-880c-ac07e1e49e2a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3e6e63c3-b7c5-4a1e-a0e9-8e4a4541f8df', '7d1e4f0c-6928-46d0-9cb5-28142b363eb9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3e6e63c3-b7c5-4a1e-a0e9-8e4a4541f8df', '48a640bc-19d3-49c4-8ff6-f0b84ea6ff49', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('44c54fd5-b22e-4f63-b6c7-f15c95c0caa2', '22f0e970-3ac6-46f9-ac87-8b3d4b50b961', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('44c54fd5-b22e-4f63-b6c7-f15c95c0caa2', '122034a4-ecc3-48a6-a67a-3fb5878b2f0f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('44c54fd5-b22e-4f63-b6c7-f15c95c0caa2', '39d065fd-61b9-4745-b8df-0ecbe03c84eb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('44c54fd5-b22e-4f63-b6c7-f15c95c0caa2', 'e9abffbc-c952-4e81-903e-835a8d0b6d8d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('44c54fd5-b22e-4f63-b6c7-f15c95c0caa2', '68f3272c-2f41-4122-b337-980121754d43', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22f0e970-3ac6-46f9-ac87-8b3d4b50b961', '44c54fd5-b22e-4f63-b6c7-f15c95c0caa2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22f0e970-3ac6-46f9-ac87-8b3d4b50b961', '122034a4-ecc3-48a6-a67a-3fb5878b2f0f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22f0e970-3ac6-46f9-ac87-8b3d4b50b961', '39d065fd-61b9-4745-b8df-0ecbe03c84eb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22f0e970-3ac6-46f9-ac87-8b3d4b50b961', 'e9abffbc-c952-4e81-903e-835a8d0b6d8d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22f0e970-3ac6-46f9-ac87-8b3d4b50b961', '68f3272c-2f41-4122-b337-980121754d43', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('122034a4-ecc3-48a6-a67a-3fb5878b2f0f', '44c54fd5-b22e-4f63-b6c7-f15c95c0caa2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('122034a4-ecc3-48a6-a67a-3fb5878b2f0f', '22f0e970-3ac6-46f9-ac87-8b3d4b50b961', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('122034a4-ecc3-48a6-a67a-3fb5878b2f0f', '39d065fd-61b9-4745-b8df-0ecbe03c84eb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('122034a4-ecc3-48a6-a67a-3fb5878b2f0f', 'e9abffbc-c952-4e81-903e-835a8d0b6d8d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('122034a4-ecc3-48a6-a67a-3fb5878b2f0f', '68f3272c-2f41-4122-b337-980121754d43', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39d065fd-61b9-4745-b8df-0ecbe03c84eb', 'e9abffbc-c952-4e81-903e-835a8d0b6d8d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39d065fd-61b9-4745-b8df-0ecbe03c84eb', '68f3272c-2f41-4122-b337-980121754d43', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39d065fd-61b9-4745-b8df-0ecbe03c84eb', '8eec5ec3-6e11-4d54-9e55-ad398cf64c6e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39d065fd-61b9-4745-b8df-0ecbe03c84eb', '9e2bebf4-ec8c-4604-b5ec-611b3c644894', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39d065fd-61b9-4745-b8df-0ecbe03c84eb', '7446b598-18f3-41d4-815f-10cc33024a0a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('66fe9be3-cc87-4413-ba0d-bba0d31cc196', '66b70497-a935-45a2-8ec0-ed6dfab274fe', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('66fe9be3-cc87-4413-ba0d-bba0d31cc196', 'ccd1cbb7-dd85-42b2-8620-fb2998359f6b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('66fe9be3-cc87-4413-ba0d-bba0d31cc196', '74ec9382-93ae-450e-9faa-ecd117158dbe', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e9abffbc-c952-4e81-903e-835a8d0b6d8d', '39d065fd-61b9-4745-b8df-0ecbe03c84eb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e9abffbc-c952-4e81-903e-835a8d0b6d8d', '68f3272c-2f41-4122-b337-980121754d43', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e9abffbc-c952-4e81-903e-835a8d0b6d8d', '8eec5ec3-6e11-4d54-9e55-ad398cf64c6e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e9abffbc-c952-4e81-903e-835a8d0b6d8d', '9e2bebf4-ec8c-4604-b5ec-611b3c644894', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e9abffbc-c952-4e81-903e-835a8d0b6d8d', '7446b598-18f3-41d4-815f-10cc33024a0a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('68f3272c-2f41-4122-b337-980121754d43', '39d065fd-61b9-4745-b8df-0ecbe03c84eb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('68f3272c-2f41-4122-b337-980121754d43', 'e9abffbc-c952-4e81-903e-835a8d0b6d8d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('68f3272c-2f41-4122-b337-980121754d43', '8eec5ec3-6e11-4d54-9e55-ad398cf64c6e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('68f3272c-2f41-4122-b337-980121754d43', '9e2bebf4-ec8c-4604-b5ec-611b3c644894', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('68f3272c-2f41-4122-b337-980121754d43', '7446b598-18f3-41d4-815f-10cc33024a0a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8eec5ec3-6e11-4d54-9e55-ad398cf64c6e', '39d065fd-61b9-4745-b8df-0ecbe03c84eb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8eec5ec3-6e11-4d54-9e55-ad398cf64c6e', 'e9abffbc-c952-4e81-903e-835a8d0b6d8d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8eec5ec3-6e11-4d54-9e55-ad398cf64c6e', '68f3272c-2f41-4122-b337-980121754d43', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8eec5ec3-6e11-4d54-9e55-ad398cf64c6e', '9e2bebf4-ec8c-4604-b5ec-611b3c644894', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8eec5ec3-6e11-4d54-9e55-ad398cf64c6e', '7446b598-18f3-41d4-815f-10cc33024a0a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9e2bebf4-ec8c-4604-b5ec-611b3c644894', '39d065fd-61b9-4745-b8df-0ecbe03c84eb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9e2bebf4-ec8c-4604-b5ec-611b3c644894', 'e9abffbc-c952-4e81-903e-835a8d0b6d8d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9e2bebf4-ec8c-4604-b5ec-611b3c644894', '68f3272c-2f41-4122-b337-980121754d43', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9e2bebf4-ec8c-4604-b5ec-611b3c644894', '8eec5ec3-6e11-4d54-9e55-ad398cf64c6e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9e2bebf4-ec8c-4604-b5ec-611b3c644894', '7446b598-18f3-41d4-815f-10cc33024a0a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7446b598-18f3-41d4-815f-10cc33024a0a', '39d065fd-61b9-4745-b8df-0ecbe03c84eb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7446b598-18f3-41d4-815f-10cc33024a0a', 'e9abffbc-c952-4e81-903e-835a8d0b6d8d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7446b598-18f3-41d4-815f-10cc33024a0a', '68f3272c-2f41-4122-b337-980121754d43', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7446b598-18f3-41d4-815f-10cc33024a0a', '8eec5ec3-6e11-4d54-9e55-ad398cf64c6e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7446b598-18f3-41d4-815f-10cc33024a0a', '9e2bebf4-ec8c-4604-b5ec-611b3c644894', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('94ab3462-c0b9-403c-b871-dfb89f4cbda0', '39d065fd-61b9-4745-b8df-0ecbe03c84eb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('94ab3462-c0b9-403c-b871-dfb89f4cbda0', 'e9abffbc-c952-4e81-903e-835a8d0b6d8d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('94ab3462-c0b9-403c-b871-dfb89f4cbda0', '68f3272c-2f41-4122-b337-980121754d43', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('94ab3462-c0b9-403c-b871-dfb89f4cbda0', '8eec5ec3-6e11-4d54-9e55-ad398cf64c6e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('94ab3462-c0b9-403c-b871-dfb89f4cbda0', '9e2bebf4-ec8c-4604-b5ec-611b3c644894', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('272cf329-9a88-4cff-9ad4-f5f8262060ed', '39d065fd-61b9-4745-b8df-0ecbe03c84eb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('272cf329-9a88-4cff-9ad4-f5f8262060ed', 'e9abffbc-c952-4e81-903e-835a8d0b6d8d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('272cf329-9a88-4cff-9ad4-f5f8262060ed', '68f3272c-2f41-4122-b337-980121754d43', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('272cf329-9a88-4cff-9ad4-f5f8262060ed', '8eec5ec3-6e11-4d54-9e55-ad398cf64c6e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('272cf329-9a88-4cff-9ad4-f5f8262060ed', '9e2bebf4-ec8c-4604-b5ec-611b3c644894', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9fdbbdb-fb09-4b83-a682-273f362082a3', '39d065fd-61b9-4745-b8df-0ecbe03c84eb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9fdbbdb-fb09-4b83-a682-273f362082a3', 'e9abffbc-c952-4e81-903e-835a8d0b6d8d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9fdbbdb-fb09-4b83-a682-273f362082a3', '68f3272c-2f41-4122-b337-980121754d43', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9fdbbdb-fb09-4b83-a682-273f362082a3', '8eec5ec3-6e11-4d54-9e55-ad398cf64c6e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9fdbbdb-fb09-4b83-a682-273f362082a3', '9e2bebf4-ec8c-4604-b5ec-611b3c644894', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('699d441a-14d5-40c4-8dba-b130ad393ad7', '39d065fd-61b9-4745-b8df-0ecbe03c84eb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('699d441a-14d5-40c4-8dba-b130ad393ad7', 'e9abffbc-c952-4e81-903e-835a8d0b6d8d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('699d441a-14d5-40c4-8dba-b130ad393ad7', '68f3272c-2f41-4122-b337-980121754d43', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('699d441a-14d5-40c4-8dba-b130ad393ad7', '8eec5ec3-6e11-4d54-9e55-ad398cf64c6e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('699d441a-14d5-40c4-8dba-b130ad393ad7', '9e2bebf4-ec8c-4604-b5ec-611b3c644894', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('076772ec-45a4-4b32-bee5-a468ec2c4578', '44c54fd5-b22e-4f63-b6c7-f15c95c0caa2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('076772ec-45a4-4b32-bee5-a468ec2c4578', '22f0e970-3ac6-46f9-ac87-8b3d4b50b961', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('076772ec-45a4-4b32-bee5-a468ec2c4578', '122034a4-ecc3-48a6-a67a-3fb5878b2f0f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('076772ec-45a4-4b32-bee5-a468ec2c4578', '39d065fd-61b9-4745-b8df-0ecbe03c84eb', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('076772ec-45a4-4b32-bee5-a468ec2c4578', 'e9abffbc-c952-4e81-903e-835a8d0b6d8d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d2f54725-be2d-4dc5-bc92-cf885f4d1673', 'b93ff3d9-2db5-4820-bf8c-4db0a6563fec', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d2f54725-be2d-4dc5-bc92-cf885f4d1673', 'c6cf82a9-bb32-458a-9b0d-50381d4474a4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d2f54725-be2d-4dc5-bc92-cf885f4d1673', 'c735a155-7026-472e-87b9-293e27804e8f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d2f54725-be2d-4dc5-bc92-cf885f4d1673', 'b999b275-cac3-487b-bcf5-df4fd36f879c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d2f54725-be2d-4dc5-bc92-cf885f4d1673', '32a58696-08da-4d9c-8725-0c03922e12dc', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b93ff3d9-2db5-4820-bf8c-4db0a6563fec', 'd2f54725-be2d-4dc5-bc92-cf885f4d1673', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b93ff3d9-2db5-4820-bf8c-4db0a6563fec', 'c6cf82a9-bb32-458a-9b0d-50381d4474a4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b93ff3d9-2db5-4820-bf8c-4db0a6563fec', 'c735a155-7026-472e-87b9-293e27804e8f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b93ff3d9-2db5-4820-bf8c-4db0a6563fec', 'b999b275-cac3-487b-bcf5-df4fd36f879c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b93ff3d9-2db5-4820-bf8c-4db0a6563fec', '32a58696-08da-4d9c-8725-0c03922e12dc', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('263e24da-59f8-4fb7-a0c8-82052221bd2b', 'b93ff3d9-2db5-4820-bf8c-4db0a6563fec', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('263e24da-59f8-4fb7-a0c8-82052221bd2b', 'd2f54725-be2d-4dc5-bc92-cf885f4d1673', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('263e24da-59f8-4fb7-a0c8-82052221bd2b', 'c6cf82a9-bb32-458a-9b0d-50381d4474a4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('263e24da-59f8-4fb7-a0c8-82052221bd2b', 'c735a155-7026-472e-87b9-293e27804e8f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('263e24da-59f8-4fb7-a0c8-82052221bd2b', 'b999b275-cac3-487b-bcf5-df4fd36f879c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6cf82a9-bb32-458a-9b0d-50381d4474a4', '88e2ba82-2a8f-499d-b904-eb638c5391ba', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6cf82a9-bb32-458a-9b0d-50381d4474a4', '1369eb08-0816-4bd6-8d70-0a16af8e89eb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6cf82a9-bb32-458a-9b0d-50381d4474a4', '79ae1782-0a45-4891-9d42-480df6a5fd4d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6cf82a9-bb32-458a-9b0d-50381d4474a4', 'd2f54725-be2d-4dc5-bc92-cf885f4d1673', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6cf82a9-bb32-458a-9b0d-50381d4474a4', 'b93ff3d9-2db5-4820-bf8c-4db0a6563fec', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c735a155-7026-472e-87b9-293e27804e8f', 'b999b275-cac3-487b-bcf5-df4fd36f879c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c735a155-7026-472e-87b9-293e27804e8f', '32a58696-08da-4d9c-8725-0c03922e12dc', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c735a155-7026-472e-87b9-293e27804e8f', 'c262642b-b57e-4bc0-bca4-f25d775681be', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c735a155-7026-472e-87b9-293e27804e8f', 'abdd3f15-4d46-40c8-b933-dd19b0f5a4ad', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c735a155-7026-472e-87b9-293e27804e8f', 'd2f54725-be2d-4dc5-bc92-cf885f4d1673', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b999b275-cac3-487b-bcf5-df4fd36f879c', 'c735a155-7026-472e-87b9-293e27804e8f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b999b275-cac3-487b-bcf5-df4fd36f879c', '32a58696-08da-4d9c-8725-0c03922e12dc', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b999b275-cac3-487b-bcf5-df4fd36f879c', 'c262642b-b57e-4bc0-bca4-f25d775681be', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b999b275-cac3-487b-bcf5-df4fd36f879c', 'abdd3f15-4d46-40c8-b933-dd19b0f5a4ad', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b999b275-cac3-487b-bcf5-df4fd36f879c', 'd2f54725-be2d-4dc5-bc92-cf885f4d1673', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('32a58696-08da-4d9c-8725-0c03922e12dc', 'c735a155-7026-472e-87b9-293e27804e8f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('32a58696-08da-4d9c-8725-0c03922e12dc', 'b999b275-cac3-487b-bcf5-df4fd36f879c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('32a58696-08da-4d9c-8725-0c03922e12dc', 'c262642b-b57e-4bc0-bca4-f25d775681be', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('32a58696-08da-4d9c-8725-0c03922e12dc', 'abdd3f15-4d46-40c8-b933-dd19b0f5a4ad', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('32a58696-08da-4d9c-8725-0c03922e12dc', 'd2f54725-be2d-4dc5-bc92-cf885f4d1673', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('88e2ba82-2a8f-499d-b904-eb638c5391ba', 'c6cf82a9-bb32-458a-9b0d-50381d4474a4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('88e2ba82-2a8f-499d-b904-eb638c5391ba', '1369eb08-0816-4bd6-8d70-0a16af8e89eb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('88e2ba82-2a8f-499d-b904-eb638c5391ba', '79ae1782-0a45-4891-9d42-480df6a5fd4d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('88e2ba82-2a8f-499d-b904-eb638c5391ba', 'd2f54725-be2d-4dc5-bc92-cf885f4d1673', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('88e2ba82-2a8f-499d-b904-eb638c5391ba', 'b93ff3d9-2db5-4820-bf8c-4db0a6563fec', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1369eb08-0816-4bd6-8d70-0a16af8e89eb', 'c6cf82a9-bb32-458a-9b0d-50381d4474a4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1369eb08-0816-4bd6-8d70-0a16af8e89eb', '88e2ba82-2a8f-499d-b904-eb638c5391ba', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1369eb08-0816-4bd6-8d70-0a16af8e89eb', '79ae1782-0a45-4891-9d42-480df6a5fd4d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1369eb08-0816-4bd6-8d70-0a16af8e89eb', 'd2f54725-be2d-4dc5-bc92-cf885f4d1673', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1369eb08-0816-4bd6-8d70-0a16af8e89eb', 'b93ff3d9-2db5-4820-bf8c-4db0a6563fec', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c262642b-b57e-4bc0-bca4-f25d775681be', 'c735a155-7026-472e-87b9-293e27804e8f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c262642b-b57e-4bc0-bca4-f25d775681be', 'b999b275-cac3-487b-bcf5-df4fd36f879c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c262642b-b57e-4bc0-bca4-f25d775681be', '32a58696-08da-4d9c-8725-0c03922e12dc', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c262642b-b57e-4bc0-bca4-f25d775681be', 'abdd3f15-4d46-40c8-b933-dd19b0f5a4ad', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c262642b-b57e-4bc0-bca4-f25d775681be', 'd2f54725-be2d-4dc5-bc92-cf885f4d1673', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('abdd3f15-4d46-40c8-b933-dd19b0f5a4ad', 'c735a155-7026-472e-87b9-293e27804e8f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('abdd3f15-4d46-40c8-b933-dd19b0f5a4ad', 'b999b275-cac3-487b-bcf5-df4fd36f879c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('abdd3f15-4d46-40c8-b933-dd19b0f5a4ad', '32a58696-08da-4d9c-8725-0c03922e12dc', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('abdd3f15-4d46-40c8-b933-dd19b0f5a4ad', 'c262642b-b57e-4bc0-bca4-f25d775681be', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('abdd3f15-4d46-40c8-b933-dd19b0f5a4ad', 'd2f54725-be2d-4dc5-bc92-cf885f4d1673', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('79ae1782-0a45-4891-9d42-480df6a5fd4d', 'c6cf82a9-bb32-458a-9b0d-50381d4474a4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('79ae1782-0a45-4891-9d42-480df6a5fd4d', '88e2ba82-2a8f-499d-b904-eb638c5391ba', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('79ae1782-0a45-4891-9d42-480df6a5fd4d', '1369eb08-0816-4bd6-8d70-0a16af8e89eb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('79ae1782-0a45-4891-9d42-480df6a5fd4d', 'd2f54725-be2d-4dc5-bc92-cf885f4d1673', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('79ae1782-0a45-4891-9d42-480df6a5fd4d', 'b93ff3d9-2db5-4820-bf8c-4db0a6563fec', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ea10a3f0-8d37-4fde-b5e2-cc13e9ab82f5', '39d065fd-61b9-4745-b8df-0ecbe03c84eb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ea10a3f0-8d37-4fde-b5e2-cc13e9ab82f5', 'e9abffbc-c952-4e81-903e-835a8d0b6d8d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ea10a3f0-8d37-4fde-b5e2-cc13e9ab82f5', '68f3272c-2f41-4122-b337-980121754d43', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ea10a3f0-8d37-4fde-b5e2-cc13e9ab82f5', '8eec5ec3-6e11-4d54-9e55-ad398cf64c6e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ea10a3f0-8d37-4fde-b5e2-cc13e9ab82f5', '9e2bebf4-ec8c-4604-b5ec-611b3c644894', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1241cde5-7a3d-43f7-8b33-f53daa7e72c7', '44c54fd5-b22e-4f63-b6c7-f15c95c0caa2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1241cde5-7a3d-43f7-8b33-f53daa7e72c7', '22f0e970-3ac6-46f9-ac87-8b3d4b50b961', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1241cde5-7a3d-43f7-8b33-f53daa7e72c7', '122034a4-ecc3-48a6-a67a-3fb5878b2f0f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ccd1cbb7-dd85-42b2-8620-fb2998359f6b', '74ec9382-93ae-450e-9faa-ecd117158dbe', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ccd1cbb7-dd85-42b2-8620-fb2998359f6b', '0c8d7e1f-d0ba-43ab-8ace-5430c4e4f477', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ccd1cbb7-dd85-42b2-8620-fb2998359f6b', '6cd141a8-7b9b-4bca-8ffb-3b4031929a1e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('74ec9382-93ae-450e-9faa-ecd117158dbe', 'ccd1cbb7-dd85-42b2-8620-fb2998359f6b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('74ec9382-93ae-450e-9faa-ecd117158dbe', '0c8d7e1f-d0ba-43ab-8ace-5430c4e4f477', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('74ec9382-93ae-450e-9faa-ecd117158dbe', '6cd141a8-7b9b-4bca-8ffb-3b4031929a1e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c8d7e1f-d0ba-43ab-8ace-5430c4e4f477', 'ccd1cbb7-dd85-42b2-8620-fb2998359f6b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c8d7e1f-d0ba-43ab-8ace-5430c4e4f477', '74ec9382-93ae-450e-9faa-ecd117158dbe', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c8d7e1f-d0ba-43ab-8ace-5430c4e4f477', '6cd141a8-7b9b-4bca-8ffb-3b4031929a1e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6cd141a8-7b9b-4bca-8ffb-3b4031929a1e', 'ccd1cbb7-dd85-42b2-8620-fb2998359f6b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6cd141a8-7b9b-4bca-8ffb-3b4031929a1e', '74ec9382-93ae-450e-9faa-ecd117158dbe', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6cd141a8-7b9b-4bca-8ffb-3b4031929a1e', '0c8d7e1f-d0ba-43ab-8ace-5430c4e4f477', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0d5c0618-8630-4298-94e4-5b638be58ac4', '2efba67c-a707-47ad-a575-59706072430a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0d5c0618-8630-4298-94e4-5b638be58ac4', '702f0b63-075b-45c9-9ebc-a6cf70fcb872', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0d5c0618-8630-4298-94e4-5b638be58ac4', 'faabda08-1d4c-451f-a4cc-cae3f5ed9209', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0d5c0618-8630-4298-94e4-5b638be58ac4', '8f7d1bfc-b822-4f45-9bda-e073db7b56eb', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0d5c0618-8630-4298-94e4-5b638be58ac4', '31be5254-435e-42e0-bdb2-1db4237ae290', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2efba67c-a707-47ad-a575-59706072430a', '0d5c0618-8630-4298-94e4-5b638be58ac4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2efba67c-a707-47ad-a575-59706072430a', '702f0b63-075b-45c9-9ebc-a6cf70fcb872', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2efba67c-a707-47ad-a575-59706072430a', 'faabda08-1d4c-451f-a4cc-cae3f5ed9209', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2efba67c-a707-47ad-a575-59706072430a', '8f7d1bfc-b822-4f45-9bda-e073db7b56eb', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2efba67c-a707-47ad-a575-59706072430a', '31be5254-435e-42e0-bdb2-1db4237ae290', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('702f0b63-075b-45c9-9ebc-a6cf70fcb872', '0d5c0618-8630-4298-94e4-5b638be58ac4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('702f0b63-075b-45c9-9ebc-a6cf70fcb872', '2efba67c-a707-47ad-a575-59706072430a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('702f0b63-075b-45c9-9ebc-a6cf70fcb872', 'faabda08-1d4c-451f-a4cc-cae3f5ed9209', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('702f0b63-075b-45c9-9ebc-a6cf70fcb872', '8f7d1bfc-b822-4f45-9bda-e073db7b56eb', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('702f0b63-075b-45c9-9ebc-a6cf70fcb872', '31be5254-435e-42e0-bdb2-1db4237ae290', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('faabda08-1d4c-451f-a4cc-cae3f5ed9209', '0d5c0618-8630-4298-94e4-5b638be58ac4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('faabda08-1d4c-451f-a4cc-cae3f5ed9209', '2efba67c-a707-47ad-a575-59706072430a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('faabda08-1d4c-451f-a4cc-cae3f5ed9209', '702f0b63-075b-45c9-9ebc-a6cf70fcb872', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('faabda08-1d4c-451f-a4cc-cae3f5ed9209', '8f7d1bfc-b822-4f45-9bda-e073db7b56eb', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('faabda08-1d4c-451f-a4cc-cae3f5ed9209', '31be5254-435e-42e0-bdb2-1db4237ae290', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ee5e11a5-ff05-461e-aef9-f53bd1d10e67', 'ef17d320-2f68-4295-b6ae-ed75183b20d7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ee5e11a5-ff05-461e-aef9-f53bd1d10e67', '0d5c0618-8630-4298-94e4-5b638be58ac4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ee5e11a5-ff05-461e-aef9-f53bd1d10e67', '2efba67c-a707-47ad-a575-59706072430a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ee5e11a5-ff05-461e-aef9-f53bd1d10e67', '702f0b63-075b-45c9-9ebc-a6cf70fcb872', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ee5e11a5-ff05-461e-aef9-f53bd1d10e67', 'faabda08-1d4c-451f-a4cc-cae3f5ed9209', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ef17d320-2f68-4295-b6ae-ed75183b20d7', 'ee5e11a5-ff05-461e-aef9-f53bd1d10e67', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ef17d320-2f68-4295-b6ae-ed75183b20d7', '0d5c0618-8630-4298-94e4-5b638be58ac4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ef17d320-2f68-4295-b6ae-ed75183b20d7', '2efba67c-a707-47ad-a575-59706072430a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ef17d320-2f68-4295-b6ae-ed75183b20d7', '702f0b63-075b-45c9-9ebc-a6cf70fcb872', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ef17d320-2f68-4295-b6ae-ed75183b20d7', 'faabda08-1d4c-451f-a4cc-cae3f5ed9209', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f7d1bfc-b822-4f45-9bda-e073db7b56eb', '0d5c0618-8630-4298-94e4-5b638be58ac4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f7d1bfc-b822-4f45-9bda-e073db7b56eb', '2efba67c-a707-47ad-a575-59706072430a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f7d1bfc-b822-4f45-9bda-e073db7b56eb', '702f0b63-075b-45c9-9ebc-a6cf70fcb872', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f7d1bfc-b822-4f45-9bda-e073db7b56eb', 'faabda08-1d4c-451f-a4cc-cae3f5ed9209', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f7d1bfc-b822-4f45-9bda-e073db7b56eb', '31be5254-435e-42e0-bdb2-1db4237ae290', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('31be5254-435e-42e0-bdb2-1db4237ae290', '0d5c0618-8630-4298-94e4-5b638be58ac4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('31be5254-435e-42e0-bdb2-1db4237ae290', '2efba67c-a707-47ad-a575-59706072430a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('31be5254-435e-42e0-bdb2-1db4237ae290', '702f0b63-075b-45c9-9ebc-a6cf70fcb872', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('31be5254-435e-42e0-bdb2-1db4237ae290', 'faabda08-1d4c-451f-a4cc-cae3f5ed9209', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('31be5254-435e-42e0-bdb2-1db4237ae290', '8f7d1bfc-b822-4f45-9bda-e073db7b56eb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6e507ec7-a58c-414a-8129-e86100ff727b', '66fe9be3-cc87-4413-ba0d-bba0d31cc196', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6e507ec7-a58c-414a-8129-e86100ff727b', 'ccd1cbb7-dd85-42b2-8620-fb2998359f6b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6e507ec7-a58c-414a-8129-e86100ff727b', '74ec9382-93ae-450e-9faa-ecd117158dbe', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb8c0570-8281-4669-a0b4-d852856325b7', '0d5c0618-8630-4298-94e4-5b638be58ac4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb8c0570-8281-4669-a0b4-d852856325b7', '2efba67c-a707-47ad-a575-59706072430a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb8c0570-8281-4669-a0b4-d852856325b7', '702f0b63-075b-45c9-9ebc-a6cf70fcb872', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb8c0570-8281-4669-a0b4-d852856325b7', 'faabda08-1d4c-451f-a4cc-cae3f5ed9209', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb8c0570-8281-4669-a0b4-d852856325b7', 'ee5e11a5-ff05-461e-aef9-f53bd1d10e67', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('66b70497-a935-45a2-8ec0-ed6dfab274fe', '66fe9be3-cc87-4413-ba0d-bba0d31cc196', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('66b70497-a935-45a2-8ec0-ed6dfab274fe', 'ccd1cbb7-dd85-42b2-8620-fb2998359f6b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('66b70497-a935-45a2-8ec0-ed6dfab274fe', '74ec9382-93ae-450e-9faa-ecd117158dbe', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('871acefd-6469-4e89-a01c-cf3792062d8d', 'a6378497-47e5-46cb-be1d-103b8cffe09e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('871acefd-6469-4e89-a01c-cf3792062d8d', 'a61868f4-8b36-486f-aa9a-3569988158fa', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('871acefd-6469-4e89-a01c-cf3792062d8d', 'c3d0767d-66ec-4a04-930c-62c2521da158', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('871acefd-6469-4e89-a01c-cf3792062d8d', '2ea27f3c-f71a-4a6d-8d5d-c18565688e9e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('871acefd-6469-4e89-a01c-cf3792062d8d', '8584a8f2-b271-4848-8ccd-fec6f3387b26', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f382ac02-4b57-40d8-ba51-fac323b9784c', '486f7da3-d7d2-4c15-9a8e-c763c34217d1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f382ac02-4b57-40d8-ba51-fac323b9784c', '871acefd-6469-4e89-a01c-cf3792062d8d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f382ac02-4b57-40d8-ba51-fac323b9784c', 'a6378497-47e5-46cb-be1d-103b8cffe09e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f382ac02-4b57-40d8-ba51-fac323b9784c', 'a61868f4-8b36-486f-aa9a-3569988158fa', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f382ac02-4b57-40d8-ba51-fac323b9784c', 'c3d0767d-66ec-4a04-930c-62c2521da158', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6378497-47e5-46cb-be1d-103b8cffe09e', '871acefd-6469-4e89-a01c-cf3792062d8d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6378497-47e5-46cb-be1d-103b8cffe09e', 'a61868f4-8b36-486f-aa9a-3569988158fa', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6378497-47e5-46cb-be1d-103b8cffe09e', 'c3d0767d-66ec-4a04-930c-62c2521da158', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6378497-47e5-46cb-be1d-103b8cffe09e', '2ea27f3c-f71a-4a6d-8d5d-c18565688e9e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6378497-47e5-46cb-be1d-103b8cffe09e', '8584a8f2-b271-4848-8ccd-fec6f3387b26', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a61868f4-8b36-486f-aa9a-3569988158fa', '871acefd-6469-4e89-a01c-cf3792062d8d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a61868f4-8b36-486f-aa9a-3569988158fa', 'a6378497-47e5-46cb-be1d-103b8cffe09e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a61868f4-8b36-486f-aa9a-3569988158fa', 'c3d0767d-66ec-4a04-930c-62c2521da158', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a61868f4-8b36-486f-aa9a-3569988158fa', '2ea27f3c-f71a-4a6d-8d5d-c18565688e9e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a61868f4-8b36-486f-aa9a-3569988158fa', '8584a8f2-b271-4848-8ccd-fec6f3387b26', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c3d0767d-66ec-4a04-930c-62c2521da158', '871acefd-6469-4e89-a01c-cf3792062d8d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c3d0767d-66ec-4a04-930c-62c2521da158', 'a6378497-47e5-46cb-be1d-103b8cffe09e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c3d0767d-66ec-4a04-930c-62c2521da158', 'a61868f4-8b36-486f-aa9a-3569988158fa', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c3d0767d-66ec-4a04-930c-62c2521da158', '2ea27f3c-f71a-4a6d-8d5d-c18565688e9e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c3d0767d-66ec-4a04-930c-62c2521da158', '8584a8f2-b271-4848-8ccd-fec6f3387b26', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2ea27f3c-f71a-4a6d-8d5d-c18565688e9e', '871acefd-6469-4e89-a01c-cf3792062d8d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2ea27f3c-f71a-4a6d-8d5d-c18565688e9e', 'a6378497-47e5-46cb-be1d-103b8cffe09e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2ea27f3c-f71a-4a6d-8d5d-c18565688e9e', 'a61868f4-8b36-486f-aa9a-3569988158fa', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2ea27f3c-f71a-4a6d-8d5d-c18565688e9e', 'c3d0767d-66ec-4a04-930c-62c2521da158', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2ea27f3c-f71a-4a6d-8d5d-c18565688e9e', '8584a8f2-b271-4848-8ccd-fec6f3387b26', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8584a8f2-b271-4848-8ccd-fec6f3387b26', '871acefd-6469-4e89-a01c-cf3792062d8d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8584a8f2-b271-4848-8ccd-fec6f3387b26', 'a6378497-47e5-46cb-be1d-103b8cffe09e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8584a8f2-b271-4848-8ccd-fec6f3387b26', 'a61868f4-8b36-486f-aa9a-3569988158fa', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8584a8f2-b271-4848-8ccd-fec6f3387b26', 'c3d0767d-66ec-4a04-930c-62c2521da158', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8584a8f2-b271-4848-8ccd-fec6f3387b26', '2ea27f3c-f71a-4a6d-8d5d-c18565688e9e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2619b440-b999-4f3d-96be-127e419f18bf', '98760507-fa79-4286-bf53-48bc690a93d5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2619b440-b999-4f3d-96be-127e419f18bf', '871acefd-6469-4e89-a01c-cf3792062d8d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2619b440-b999-4f3d-96be-127e419f18bf', 'f382ac02-4b57-40d8-ba51-fac323b9784c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2619b440-b999-4f3d-96be-127e419f18bf', 'a6378497-47e5-46cb-be1d-103b8cffe09e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2619b440-b999-4f3d-96be-127e419f18bf', 'a61868f4-8b36-486f-aa9a-3569988158fa', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('98760507-fa79-4286-bf53-48bc690a93d5', '2619b440-b999-4f3d-96be-127e419f18bf', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('98760507-fa79-4286-bf53-48bc690a93d5', '871acefd-6469-4e89-a01c-cf3792062d8d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('98760507-fa79-4286-bf53-48bc690a93d5', 'f382ac02-4b57-40d8-ba51-fac323b9784c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('98760507-fa79-4286-bf53-48bc690a93d5', 'a6378497-47e5-46cb-be1d-103b8cffe09e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('98760507-fa79-4286-bf53-48bc690a93d5', 'a61868f4-8b36-486f-aa9a-3569988158fa', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5322cccd-d86b-4ed8-9e5f-f6dd7e2889af', '871acefd-6469-4e89-a01c-cf3792062d8d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5322cccd-d86b-4ed8-9e5f-f6dd7e2889af', 'a6378497-47e5-46cb-be1d-103b8cffe09e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5322cccd-d86b-4ed8-9e5f-f6dd7e2889af', 'a61868f4-8b36-486f-aa9a-3569988158fa', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5322cccd-d86b-4ed8-9e5f-f6dd7e2889af', 'c3d0767d-66ec-4a04-930c-62c2521da158', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5322cccd-d86b-4ed8-9e5f-f6dd7e2889af', '2ea27f3c-f71a-4a6d-8d5d-c18565688e9e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59e374a7-bcbb-4625-adf1-0edab04547cb', '871acefd-6469-4e89-a01c-cf3792062d8d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59e374a7-bcbb-4625-adf1-0edab04547cb', 'a6378497-47e5-46cb-be1d-103b8cffe09e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59e374a7-bcbb-4625-adf1-0edab04547cb', 'a61868f4-8b36-486f-aa9a-3569988158fa', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59e374a7-bcbb-4625-adf1-0edab04547cb', 'c3d0767d-66ec-4a04-930c-62c2521da158', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59e374a7-bcbb-4625-adf1-0edab04547cb', '2ea27f3c-f71a-4a6d-8d5d-c18565688e9e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('486f7da3-d7d2-4c15-9a8e-c763c34217d1', 'f382ac02-4b57-40d8-ba51-fac323b9784c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('486f7da3-d7d2-4c15-9a8e-c763c34217d1', '871acefd-6469-4e89-a01c-cf3792062d8d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('486f7da3-d7d2-4c15-9a8e-c763c34217d1', 'a6378497-47e5-46cb-be1d-103b8cffe09e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('486f7da3-d7d2-4c15-9a8e-c763c34217d1', 'a61868f4-8b36-486f-aa9a-3569988158fa', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('486f7da3-d7d2-4c15-9a8e-c763c34217d1', 'c3d0767d-66ec-4a04-930c-62c2521da158', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a79fa71f-53a9-4d0c-b779-f0f344dd7cda', '871acefd-6469-4e89-a01c-cf3792062d8d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a79fa71f-53a9-4d0c-b779-f0f344dd7cda', 'a6378497-47e5-46cb-be1d-103b8cffe09e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a79fa71f-53a9-4d0c-b779-f0f344dd7cda', 'a61868f4-8b36-486f-aa9a-3569988158fa', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a79fa71f-53a9-4d0c-b779-f0f344dd7cda', 'c3d0767d-66ec-4a04-930c-62c2521da158', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a79fa71f-53a9-4d0c-b779-f0f344dd7cda', '2ea27f3c-f71a-4a6d-8d5d-c18565688e9e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('18f51cd1-2860-4f5d-b73d-d912ee65df13', '6da087e1-a7b6-4200-921e-dfa17db24e83', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('18f51cd1-2860-4f5d-b73d-d912ee65df13', 'e4841332-3e45-4c7c-86e1-5f9fc0d7b627', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('18f51cd1-2860-4f5d-b73d-d912ee65df13', '487c881c-ea5a-4060-a95e-41240bfd9b68', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('18f51cd1-2860-4f5d-b73d-d912ee65df13', '0ee07ea9-8d3a-453e-9885-50e3203ecf32', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('18f51cd1-2860-4f5d-b73d-d912ee65df13', 'ebcc30be-2ff7-4033-9dd1-259dcab2020e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e4841332-3e45-4c7c-86e1-5f9fc0d7b627', '18f51cd1-2860-4f5d-b73d-d912ee65df13', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e4841332-3e45-4c7c-86e1-5f9fc0d7b627', '487c881c-ea5a-4060-a95e-41240bfd9b68', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e4841332-3e45-4c7c-86e1-5f9fc0d7b627', '0ee07ea9-8d3a-453e-9885-50e3203ecf32', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e4841332-3e45-4c7c-86e1-5f9fc0d7b627', 'ebcc30be-2ff7-4033-9dd1-259dcab2020e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e4841332-3e45-4c7c-86e1-5f9fc0d7b627', 'f1225e16-d0fc-4473-9ba8-fd09f87e021e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('487c881c-ea5a-4060-a95e-41240bfd9b68', '18f51cd1-2860-4f5d-b73d-d912ee65df13', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('487c881c-ea5a-4060-a95e-41240bfd9b68', 'e4841332-3e45-4c7c-86e1-5f9fc0d7b627', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('487c881c-ea5a-4060-a95e-41240bfd9b68', '0ee07ea9-8d3a-453e-9885-50e3203ecf32', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('487c881c-ea5a-4060-a95e-41240bfd9b68', 'ebcc30be-2ff7-4033-9dd1-259dcab2020e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('487c881c-ea5a-4060-a95e-41240bfd9b68', 'f1225e16-d0fc-4473-9ba8-fd09f87e021e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0ee07ea9-8d3a-453e-9885-50e3203ecf32', 'ebcc30be-2ff7-4033-9dd1-259dcab2020e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0ee07ea9-8d3a-453e-9885-50e3203ecf32', 'f1225e16-d0fc-4473-9ba8-fd09f87e021e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0ee07ea9-8d3a-453e-9885-50e3203ecf32', '04be2028-33e0-415c-81f1-2f527d40741a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0ee07ea9-8d3a-453e-9885-50e3203ecf32', '18f51cd1-2860-4f5d-b73d-d912ee65df13', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0ee07ea9-8d3a-453e-9885-50e3203ecf32', 'e4841332-3e45-4c7c-86e1-5f9fc0d7b627', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ebcc30be-2ff7-4033-9dd1-259dcab2020e', '0ee07ea9-8d3a-453e-9885-50e3203ecf32', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ebcc30be-2ff7-4033-9dd1-259dcab2020e', 'f1225e16-d0fc-4473-9ba8-fd09f87e021e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ebcc30be-2ff7-4033-9dd1-259dcab2020e', '04be2028-33e0-415c-81f1-2f527d40741a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ebcc30be-2ff7-4033-9dd1-259dcab2020e', '18f51cd1-2860-4f5d-b73d-d912ee65df13', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ebcc30be-2ff7-4033-9dd1-259dcab2020e', 'e4841332-3e45-4c7c-86e1-5f9fc0d7b627', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f1225e16-d0fc-4473-9ba8-fd09f87e021e', '0ee07ea9-8d3a-453e-9885-50e3203ecf32', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f1225e16-d0fc-4473-9ba8-fd09f87e021e', 'ebcc30be-2ff7-4033-9dd1-259dcab2020e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f1225e16-d0fc-4473-9ba8-fd09f87e021e', '04be2028-33e0-415c-81f1-2f527d40741a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f1225e16-d0fc-4473-9ba8-fd09f87e021e', '18f51cd1-2860-4f5d-b73d-d912ee65df13', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f1225e16-d0fc-4473-9ba8-fd09f87e021e', 'e4841332-3e45-4c7c-86e1-5f9fc0d7b627', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('04be2028-33e0-415c-81f1-2f527d40741a', '0ee07ea9-8d3a-453e-9885-50e3203ecf32', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('04be2028-33e0-415c-81f1-2f527d40741a', 'ebcc30be-2ff7-4033-9dd1-259dcab2020e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('04be2028-33e0-415c-81f1-2f527d40741a', 'f1225e16-d0fc-4473-9ba8-fd09f87e021e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('04be2028-33e0-415c-81f1-2f527d40741a', '18f51cd1-2860-4f5d-b73d-d912ee65df13', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('04be2028-33e0-415c-81f1-2f527d40741a', 'e4841332-3e45-4c7c-86e1-5f9fc0d7b627', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6da087e1-a7b6-4200-921e-dfa17db24e83', '18f51cd1-2860-4f5d-b73d-d912ee65df13', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6da087e1-a7b6-4200-921e-dfa17db24e83', 'e4841332-3e45-4c7c-86e1-5f9fc0d7b627', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6da087e1-a7b6-4200-921e-dfa17db24e83', '487c881c-ea5a-4060-a95e-41240bfd9b68', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6da087e1-a7b6-4200-921e-dfa17db24e83', '0ee07ea9-8d3a-453e-9885-50e3203ecf32', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6da087e1-a7b6-4200-921e-dfa17db24e83', 'ebcc30be-2ff7-4033-9dd1-259dcab2020e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d00cbef-5e1c-4efe-a283-213785092f51', '18f51cd1-2860-4f5d-b73d-d912ee65df13', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d00cbef-5e1c-4efe-a283-213785092f51', 'e4841332-3e45-4c7c-86e1-5f9fc0d7b627', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d00cbef-5e1c-4efe-a283-213785092f51', '487c881c-ea5a-4060-a95e-41240bfd9b68', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('79b5c3c6-59df-4ca6-867b-04ac1f284bea', '18f51cd1-2860-4f5d-b73d-d912ee65df13', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('79b5c3c6-59df-4ca6-867b-04ac1f284bea', 'e4841332-3e45-4c7c-86e1-5f9fc0d7b627', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('79b5c3c6-59df-4ca6-867b-04ac1f284bea', '487c881c-ea5a-4060-a95e-41240bfd9b68', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('79b5c3c6-59df-4ca6-867b-04ac1f284bea', '0ee07ea9-8d3a-453e-9885-50e3203ecf32', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('79b5c3c6-59df-4ca6-867b-04ac1f284bea', 'ebcc30be-2ff7-4033-9dd1-259dcab2020e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f3ed62fe-0251-4cba-856b-e487a6bf64b2', 'fff20d5f-29f8-407f-b2ef-3611dd6f64ae', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f3ed62fe-0251-4cba-856b-e487a6bf64b2', '47553c1f-7b85-477e-918a-7bfa9a249f22', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f3ed62fe-0251-4cba-856b-e487a6bf64b2', '7bfe9835-72ea-4d0f-a147-ff3b7f24a127', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f3ed62fe-0251-4cba-856b-e487a6bf64b2', 'da03e444-c95d-4114-a2c4-c7c4a63eff0d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f3ed62fe-0251-4cba-856b-e487a6bf64b2', 'e151bcbc-3e0e-4441-b4ba-27f6daf7add3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('655873ed-d5e2-4cfc-91ee-387a98189f87', 'f3ed62fe-0251-4cba-856b-e487a6bf64b2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('655873ed-d5e2-4cfc-91ee-387a98189f87', 'fff20d5f-29f8-407f-b2ef-3611dd6f64ae', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('655873ed-d5e2-4cfc-91ee-387a98189f87', '47553c1f-7b85-477e-918a-7bfa9a249f22', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('655873ed-d5e2-4cfc-91ee-387a98189f87', '7bfe9835-72ea-4d0f-a147-ff3b7f24a127', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('655873ed-d5e2-4cfc-91ee-387a98189f87', 'da03e444-c95d-4114-a2c4-c7c4a63eff0d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fff20d5f-29f8-407f-b2ef-3611dd6f64ae', 'f3ed62fe-0251-4cba-856b-e487a6bf64b2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fff20d5f-29f8-407f-b2ef-3611dd6f64ae', '47553c1f-7b85-477e-918a-7bfa9a249f22', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fff20d5f-29f8-407f-b2ef-3611dd6f64ae', '7bfe9835-72ea-4d0f-a147-ff3b7f24a127', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fff20d5f-29f8-407f-b2ef-3611dd6f64ae', 'da03e444-c95d-4114-a2c4-c7c4a63eff0d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fff20d5f-29f8-407f-b2ef-3611dd6f64ae', 'e151bcbc-3e0e-4441-b4ba-27f6daf7add3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7bfe9835-72ea-4d0f-a147-ff3b7f24a127', 'f3ed62fe-0251-4cba-856b-e487a6bf64b2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7bfe9835-72ea-4d0f-a147-ff3b7f24a127', 'fff20d5f-29f8-407f-b2ef-3611dd6f64ae', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7bfe9835-72ea-4d0f-a147-ff3b7f24a127', 'da03e444-c95d-4114-a2c4-c7c4a63eff0d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7bfe9835-72ea-4d0f-a147-ff3b7f24a127', '47553c1f-7b85-477e-918a-7bfa9a249f22', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7bfe9835-72ea-4d0f-a147-ff3b7f24a127', 'e151bcbc-3e0e-4441-b4ba-27f6daf7add3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('da03e444-c95d-4114-a2c4-c7c4a63eff0d', 'f3ed62fe-0251-4cba-856b-e487a6bf64b2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('da03e444-c95d-4114-a2c4-c7c4a63eff0d', 'fff20d5f-29f8-407f-b2ef-3611dd6f64ae', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('da03e444-c95d-4114-a2c4-c7c4a63eff0d', '7bfe9835-72ea-4d0f-a147-ff3b7f24a127', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('da03e444-c95d-4114-a2c4-c7c4a63eff0d', '47553c1f-7b85-477e-918a-7bfa9a249f22', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('da03e444-c95d-4114-a2c4-c7c4a63eff0d', 'e151bcbc-3e0e-4441-b4ba-27f6daf7add3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f631b34e-d992-4b76-b491-1fcdef0fa20a', 'f3ed62fe-0251-4cba-856b-e487a6bf64b2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f631b34e-d992-4b76-b491-1fcdef0fa20a', 'fff20d5f-29f8-407f-b2ef-3611dd6f64ae', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f631b34e-d992-4b76-b491-1fcdef0fa20a', '7bfe9835-72ea-4d0f-a147-ff3b7f24a127', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c43180d3-7b2d-42e8-bf57-e2ae9737d344', 'f3ed62fe-0251-4cba-856b-e487a6bf64b2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c43180d3-7b2d-42e8-bf57-e2ae9737d344', 'fff20d5f-29f8-407f-b2ef-3611dd6f64ae', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c43180d3-7b2d-42e8-bf57-e2ae9737d344', '7bfe9835-72ea-4d0f-a147-ff3b7f24a127', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5f420c00-f31b-4061-a7ff-064379e8c490', '057cebc7-697d-4e54-9d52-24aab3218c2d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5f420c00-f31b-4061-a7ff-064379e8c490', '67d962ee-8be4-4bb6-91ff-09c7ecb2f876', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5f420c00-f31b-4061-a7ff-064379e8c490', '06719b5a-9bab-4dbd-93c6-18cce69b2f18', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5f420c00-f31b-4061-a7ff-064379e8c490', '635ce954-3e84-4b29-81be-0fd8cf5961b1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5f420c00-f31b-4061-a7ff-064379e8c490', '757b2e61-8bd2-4859-87a6-f03652df9926', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('06719b5a-9bab-4dbd-93c6-18cce69b2f18', '757b2e61-8bd2-4859-87a6-f03652df9926', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('06719b5a-9bab-4dbd-93c6-18cce69b2f18', '5f420c00-f31b-4061-a7ff-064379e8c490', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('06719b5a-9bab-4dbd-93c6-18cce69b2f18', '057cebc7-697d-4e54-9d52-24aab3218c2d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('06719b5a-9bab-4dbd-93c6-18cce69b2f18', '635ce954-3e84-4b29-81be-0fd8cf5961b1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('06719b5a-9bab-4dbd-93c6-18cce69b2f18', '67d962ee-8be4-4bb6-91ff-09c7ecb2f876', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('057cebc7-697d-4e54-9d52-24aab3218c2d', '5f420c00-f31b-4061-a7ff-064379e8c490', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('057cebc7-697d-4e54-9d52-24aab3218c2d', '67d962ee-8be4-4bb6-91ff-09c7ecb2f876', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('057cebc7-697d-4e54-9d52-24aab3218c2d', '06719b5a-9bab-4dbd-93c6-18cce69b2f18', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('057cebc7-697d-4e54-9d52-24aab3218c2d', '635ce954-3e84-4b29-81be-0fd8cf5961b1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('057cebc7-697d-4e54-9d52-24aab3218c2d', '757b2e61-8bd2-4859-87a6-f03652df9926', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('635ce954-3e84-4b29-81be-0fd8cf5961b1', '5f420c00-f31b-4061-a7ff-064379e8c490', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('635ce954-3e84-4b29-81be-0fd8cf5961b1', '06719b5a-9bab-4dbd-93c6-18cce69b2f18', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('635ce954-3e84-4b29-81be-0fd8cf5961b1', '057cebc7-697d-4e54-9d52-24aab3218c2d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('635ce954-3e84-4b29-81be-0fd8cf5961b1', '757b2e61-8bd2-4859-87a6-f03652df9926', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('635ce954-3e84-4b29-81be-0fd8cf5961b1', '67d962ee-8be4-4bb6-91ff-09c7ecb2f876', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('757b2e61-8bd2-4859-87a6-f03652df9926', '06719b5a-9bab-4dbd-93c6-18cce69b2f18', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('757b2e61-8bd2-4859-87a6-f03652df9926', '5f420c00-f31b-4061-a7ff-064379e8c490', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('757b2e61-8bd2-4859-87a6-f03652df9926', '057cebc7-697d-4e54-9d52-24aab3218c2d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('757b2e61-8bd2-4859-87a6-f03652df9926', '635ce954-3e84-4b29-81be-0fd8cf5961b1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('757b2e61-8bd2-4859-87a6-f03652df9926', '67d962ee-8be4-4bb6-91ff-09c7ecb2f876', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ecacad44-4653-40fe-9a51-a34e892ccd71', '04380168-a7d9-45a9-9da6-bf1c8280c066', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ecacad44-4653-40fe-9a51-a34e892ccd71', 'f3ed62fe-0251-4cba-856b-e487a6bf64b2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ecacad44-4653-40fe-9a51-a34e892ccd71', 'fff20d5f-29f8-407f-b2ef-3611dd6f64ae', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('47553c1f-7b85-477e-918a-7bfa9a249f22', 'f3ed62fe-0251-4cba-856b-e487a6bf64b2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('47553c1f-7b85-477e-918a-7bfa9a249f22', 'fff20d5f-29f8-407f-b2ef-3611dd6f64ae', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('47553c1f-7b85-477e-918a-7bfa9a249f22', '7bfe9835-72ea-4d0f-a147-ff3b7f24a127', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('47553c1f-7b85-477e-918a-7bfa9a249f22', 'da03e444-c95d-4114-a2c4-c7c4a63eff0d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('47553c1f-7b85-477e-918a-7bfa9a249f22', 'e151bcbc-3e0e-4441-b4ba-27f6daf7add3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f401b388-f821-4e33-b5f8-f94d9d18f5e9', 'f3ed62fe-0251-4cba-856b-e487a6bf64b2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f401b388-f821-4e33-b5f8-f94d9d18f5e9', 'fff20d5f-29f8-407f-b2ef-3611dd6f64ae', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f401b388-f821-4e33-b5f8-f94d9d18f5e9', '7bfe9835-72ea-4d0f-a147-ff3b7f24a127', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e151bcbc-3e0e-4441-b4ba-27f6daf7add3', 'f3ed62fe-0251-4cba-856b-e487a6bf64b2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e151bcbc-3e0e-4441-b4ba-27f6daf7add3', 'fff20d5f-29f8-407f-b2ef-3611dd6f64ae', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e151bcbc-3e0e-4441-b4ba-27f6daf7add3', '7bfe9835-72ea-4d0f-a147-ff3b7f24a127', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e151bcbc-3e0e-4441-b4ba-27f6daf7add3', 'da03e444-c95d-4114-a2c4-c7c4a63eff0d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e151bcbc-3e0e-4441-b4ba-27f6daf7add3', '47553c1f-7b85-477e-918a-7bfa9a249f22', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('04380168-a7d9-45a9-9da6-bf1c8280c066', 'ecacad44-4653-40fe-9a51-a34e892ccd71', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('04380168-a7d9-45a9-9da6-bf1c8280c066', 'f3ed62fe-0251-4cba-856b-e487a6bf64b2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('04380168-a7d9-45a9-9da6-bf1c8280c066', 'fff20d5f-29f8-407f-b2ef-3611dd6f64ae', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('67d962ee-8be4-4bb6-91ff-09c7ecb2f876', '5f420c00-f31b-4061-a7ff-064379e8c490', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('67d962ee-8be4-4bb6-91ff-09c7ecb2f876', '057cebc7-697d-4e54-9d52-24aab3218c2d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('67d962ee-8be4-4bb6-91ff-09c7ecb2f876', '06719b5a-9bab-4dbd-93c6-18cce69b2f18', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('67d962ee-8be4-4bb6-91ff-09c7ecb2f876', '635ce954-3e84-4b29-81be-0fd8cf5961b1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('67d962ee-8be4-4bb6-91ff-09c7ecb2f876', '757b2e61-8bd2-4859-87a6-f03652df9926', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('264c047b-9977-4a5b-b8ac-cc9d6e226ca8', '59aff6b7-889b-4b49-a4b6-78169070b09a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('264c047b-9977-4a5b-b8ac-cc9d6e226ca8', '36022ca5-ed44-4ead-95eb-eff65bb453b2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('264c047b-9977-4a5b-b8ac-cc9d6e226ca8', 'f3ed62fe-0251-4cba-856b-e487a6bf64b2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59aff6b7-889b-4b49-a4b6-78169070b09a', '264c047b-9977-4a5b-b8ac-cc9d6e226ca8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59aff6b7-889b-4b49-a4b6-78169070b09a', '36022ca5-ed44-4ead-95eb-eff65bb453b2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59aff6b7-889b-4b49-a4b6-78169070b09a', 'f3ed62fe-0251-4cba-856b-e487a6bf64b2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('36022ca5-ed44-4ead-95eb-eff65bb453b2', '264c047b-9977-4a5b-b8ac-cc9d6e226ca8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('36022ca5-ed44-4ead-95eb-eff65bb453b2', '59aff6b7-889b-4b49-a4b6-78169070b09a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('36022ca5-ed44-4ead-95eb-eff65bb453b2', 'f3ed62fe-0251-4cba-856b-e487a6bf64b2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cba53fef-18fd-44d4-9389-dc89030819d6', '5b1dc45a-2d47-4020-9426-34bb08b9ad8d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cba53fef-18fd-44d4-9389-dc89030819d6', 'b070e3e1-93e0-47ee-830d-6014d58790a1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cba53fef-18fd-44d4-9389-dc89030819d6', 'e51c427e-8ecd-4064-981d-9557b618da69', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cba53fef-18fd-44d4-9389-dc89030819d6', 'ced922ba-c779-4295-b477-b55661c3ac87', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5b1dc45a-2d47-4020-9426-34bb08b9ad8d', 'cba53fef-18fd-44d4-9389-dc89030819d6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5b1dc45a-2d47-4020-9426-34bb08b9ad8d', 'b070e3e1-93e0-47ee-830d-6014d58790a1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5b1dc45a-2d47-4020-9426-34bb08b9ad8d', 'e51c427e-8ecd-4064-981d-9557b618da69', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5b1dc45a-2d47-4020-9426-34bb08b9ad8d', 'ced922ba-c779-4295-b477-b55661c3ac87', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b070e3e1-93e0-47ee-830d-6014d58790a1', 'cba53fef-18fd-44d4-9389-dc89030819d6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b070e3e1-93e0-47ee-830d-6014d58790a1', '5b1dc45a-2d47-4020-9426-34bb08b9ad8d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b070e3e1-93e0-47ee-830d-6014d58790a1', 'e51c427e-8ecd-4064-981d-9557b618da69', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b070e3e1-93e0-47ee-830d-6014d58790a1', 'ced922ba-c779-4295-b477-b55661c3ac87', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e51c427e-8ecd-4064-981d-9557b618da69', 'cba53fef-18fd-44d4-9389-dc89030819d6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e51c427e-8ecd-4064-981d-9557b618da69', '5b1dc45a-2d47-4020-9426-34bb08b9ad8d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e51c427e-8ecd-4064-981d-9557b618da69', 'b070e3e1-93e0-47ee-830d-6014d58790a1', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e51c427e-8ecd-4064-981d-9557b618da69', 'ced922ba-c779-4295-b477-b55661c3ac87', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ced922ba-c779-4295-b477-b55661c3ac87', 'cba53fef-18fd-44d4-9389-dc89030819d6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ced922ba-c779-4295-b477-b55661c3ac87', '5b1dc45a-2d47-4020-9426-34bb08b9ad8d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ced922ba-c779-4295-b477-b55661c3ac87', 'b070e3e1-93e0-47ee-830d-6014d58790a1', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ced922ba-c779-4295-b477-b55661c3ac87', 'e51c427e-8ecd-4064-981d-9557b618da69', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('777e5e97-9bb4-4390-a063-aa3c21dcb855', '0c65d871-82b0-4bf1-8e38-e07c294b16af', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('777e5e97-9bb4-4390-a063-aa3c21dcb855', 'e86ea632-5012-4ca0-9a20-65dce553f582', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c65d871-82b0-4bf1-8e38-e07c294b16af', '777e5e97-9bb4-4390-a063-aa3c21dcb855', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c65d871-82b0-4bf1-8e38-e07c294b16af', 'e86ea632-5012-4ca0-9a20-65dce553f582', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e86ea632-5012-4ca0-9a20-65dce553f582', '777e5e97-9bb4-4390-a063-aa3c21dcb855', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e86ea632-5012-4ca0-9a20-65dce553f582', '0c65d871-82b0-4bf1-8e38-e07c294b16af', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('479fd45f-58bc-46ba-8164-3e63ae671285', 'd5212195-338c-4708-bbbe-3791fcd758c7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('479fd45f-58bc-46ba-8164-3e63ae671285', 'c77249ad-559f-4618-9603-c40e0a6727b4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('479fd45f-58bc-46ba-8164-3e63ae671285', '96653e7b-58d3-42c0-b939-dc953c9a1d19', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('479fd45f-58bc-46ba-8164-3e63ae671285', '6987fbc1-6f31-497d-bd26-089fd8febd6e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('479fd45f-58bc-46ba-8164-3e63ae671285', '82aa4b80-f785-4a15-b3a8-ddeb35fc64ea', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c77249ad-559f-4618-9603-c40e0a6727b4', 'd5212195-338c-4708-bbbe-3791fcd758c7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c77249ad-559f-4618-9603-c40e0a6727b4', '479fd45f-58bc-46ba-8164-3e63ae671285', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c77249ad-559f-4618-9603-c40e0a6727b4', '96653e7b-58d3-42c0-b939-dc953c9a1d19', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c77249ad-559f-4618-9603-c40e0a6727b4', '6987fbc1-6f31-497d-bd26-089fd8febd6e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c77249ad-559f-4618-9603-c40e0a6727b4', '82aa4b80-f785-4a15-b3a8-ddeb35fc64ea', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('96653e7b-58d3-42c0-b939-dc953c9a1d19', 'd5212195-338c-4708-bbbe-3791fcd758c7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('96653e7b-58d3-42c0-b939-dc953c9a1d19', '479fd45f-58bc-46ba-8164-3e63ae671285', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('96653e7b-58d3-42c0-b939-dc953c9a1d19', 'c77249ad-559f-4618-9603-c40e0a6727b4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('96653e7b-58d3-42c0-b939-dc953c9a1d19', '6987fbc1-6f31-497d-bd26-089fd8febd6e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('96653e7b-58d3-42c0-b939-dc953c9a1d19', '82aa4b80-f785-4a15-b3a8-ddeb35fc64ea', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('82aa4b80-f785-4a15-b3a8-ddeb35fc64ea', 'd5212195-338c-4708-bbbe-3791fcd758c7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('82aa4b80-f785-4a15-b3a8-ddeb35fc64ea', '6987fbc1-6f31-497d-bd26-089fd8febd6e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('82aa4b80-f785-4a15-b3a8-ddeb35fc64ea', '479fd45f-58bc-46ba-8164-3e63ae671285', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('82aa4b80-f785-4a15-b3a8-ddeb35fc64ea', 'c77249ad-559f-4618-9603-c40e0a6727b4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('82aa4b80-f785-4a15-b3a8-ddeb35fc64ea', '96653e7b-58d3-42c0-b939-dc953c9a1d19', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e36d6d33-ccd1-40e4-a8e1-f5ed39ee3d86', 'f6f1859d-1c35-47cd-bf50-b8dfdf6f2c96', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e36d6d33-ccd1-40e4-a8e1-f5ed39ee3d86', 'f88ad193-61a3-4eb8-892e-51d51e1bb654', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f6f1859d-1c35-47cd-bf50-b8dfdf6f2c96', 'e36d6d33-ccd1-40e4-a8e1-f5ed39ee3d86', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f6f1859d-1c35-47cd-bf50-b8dfdf6f2c96', 'f88ad193-61a3-4eb8-892e-51d51e1bb654', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f88ad193-61a3-4eb8-892e-51d51e1bb654', 'e36d6d33-ccd1-40e4-a8e1-f5ed39ee3d86', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f88ad193-61a3-4eb8-892e-51d51e1bb654', 'f6f1859d-1c35-47cd-bf50-b8dfdf6f2c96', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('24f32e57-fa48-4334-b7c4-7755ca82a4f5', '9199c506-1194-4e12-94aa-1ae3ab3a0bd1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('24f32e57-fa48-4334-b7c4-7755ca82a4f5', 'c80f3a44-aa96-43d6-8aed-7d61f8163ae2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('24f32e57-fa48-4334-b7c4-7755ca82a4f5', '4a85c379-1327-44ac-bcae-12753145e8f5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9199c506-1194-4e12-94aa-1ae3ab3a0bd1', '4a85c379-1327-44ac-bcae-12753145e8f5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9199c506-1194-4e12-94aa-1ae3ab3a0bd1', '24f32e57-fa48-4334-b7c4-7755ca82a4f5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9199c506-1194-4e12-94aa-1ae3ab3a0bd1', 'c80f3a44-aa96-43d6-8aed-7d61f8163ae2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c80f3a44-aa96-43d6-8aed-7d61f8163ae2', '24f32e57-fa48-4334-b7c4-7755ca82a4f5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c80f3a44-aa96-43d6-8aed-7d61f8163ae2', '9199c506-1194-4e12-94aa-1ae3ab3a0bd1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c80f3a44-aa96-43d6-8aed-7d61f8163ae2', '4a85c379-1327-44ac-bcae-12753145e8f5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a85c379-1327-44ac-bcae-12753145e8f5', '9199c506-1194-4e12-94aa-1ae3ab3a0bd1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a85c379-1327-44ac-bcae-12753145e8f5', '24f32e57-fa48-4334-b7c4-7755ca82a4f5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a85c379-1327-44ac-bcae-12753145e8f5', 'c80f3a44-aa96-43d6-8aed-7d61f8163ae2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5b17643d-c77d-4e57-baee-d774e4939ef5', '1e0f99d1-9e49-406b-926d-fb822d2bf6cd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5b17643d-c77d-4e57-baee-d774e4939ef5', '986e8d1b-e1df-4c6b-b96f-f433982c5f68', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5b17643d-c77d-4e57-baee-d774e4939ef5', '975af0f7-e4b2-4d1a-88c9-512f18ce3900', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5b17643d-c77d-4e57-baee-d774e4939ef5', 'df7b5e52-58a0-4365-8c17-7ca42f1fac46', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5b17643d-c77d-4e57-baee-d774e4939ef5', 'c65d3939-4671-4310-8aed-80ea14692272', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1e0f99d1-9e49-406b-926d-fb822d2bf6cd', '5b17643d-c77d-4e57-baee-d774e4939ef5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1e0f99d1-9e49-406b-926d-fb822d2bf6cd', '986e8d1b-e1df-4c6b-b96f-f433982c5f68', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1e0f99d1-9e49-406b-926d-fb822d2bf6cd', '975af0f7-e4b2-4d1a-88c9-512f18ce3900', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1e0f99d1-9e49-406b-926d-fb822d2bf6cd', 'df7b5e52-58a0-4365-8c17-7ca42f1fac46', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1e0f99d1-9e49-406b-926d-fb822d2bf6cd', 'c65d3939-4671-4310-8aed-80ea14692272', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('986e8d1b-e1df-4c6b-b96f-f433982c5f68', '545fc4da-c5ba-47fc-a4a1-0e811077557e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('986e8d1b-e1df-4c6b-b96f-f433982c5f68', '5b17643d-c77d-4e57-baee-d774e4939ef5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('986e8d1b-e1df-4c6b-b96f-f433982c5f68', '1e0f99d1-9e49-406b-926d-fb822d2bf6cd', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('986e8d1b-e1df-4c6b-b96f-f433982c5f68', '975af0f7-e4b2-4d1a-88c9-512f18ce3900', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('986e8d1b-e1df-4c6b-b96f-f433982c5f68', 'df7b5e52-58a0-4365-8c17-7ca42f1fac46', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('975af0f7-e4b2-4d1a-88c9-512f18ce3900', '5b17643d-c77d-4e57-baee-d774e4939ef5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('975af0f7-e4b2-4d1a-88c9-512f18ce3900', '1e0f99d1-9e49-406b-926d-fb822d2bf6cd', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('975af0f7-e4b2-4d1a-88c9-512f18ce3900', '986e8d1b-e1df-4c6b-b96f-f433982c5f68', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('975af0f7-e4b2-4d1a-88c9-512f18ce3900', 'df7b5e52-58a0-4365-8c17-7ca42f1fac46', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('975af0f7-e4b2-4d1a-88c9-512f18ce3900', 'c65d3939-4671-4310-8aed-80ea14692272', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('df7b5e52-58a0-4365-8c17-7ca42f1fac46', '5b17643d-c77d-4e57-baee-d774e4939ef5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('df7b5e52-58a0-4365-8c17-7ca42f1fac46', '1e0f99d1-9e49-406b-926d-fb822d2bf6cd', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('df7b5e52-58a0-4365-8c17-7ca42f1fac46', '986e8d1b-e1df-4c6b-b96f-f433982c5f68', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('df7b5e52-58a0-4365-8c17-7ca42f1fac46', '975af0f7-e4b2-4d1a-88c9-512f18ce3900', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('df7b5e52-58a0-4365-8c17-7ca42f1fac46', 'c65d3939-4671-4310-8aed-80ea14692272', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c65d3939-4671-4310-8aed-80ea14692272', '5b17643d-c77d-4e57-baee-d774e4939ef5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c65d3939-4671-4310-8aed-80ea14692272', '1e0f99d1-9e49-406b-926d-fb822d2bf6cd', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c65d3939-4671-4310-8aed-80ea14692272', '986e8d1b-e1df-4c6b-b96f-f433982c5f68', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c65d3939-4671-4310-8aed-80ea14692272', '975af0f7-e4b2-4d1a-88c9-512f18ce3900', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c65d3939-4671-4310-8aed-80ea14692272', 'df7b5e52-58a0-4365-8c17-7ca42f1fac46', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a918f24e-289c-42b1-a69e-6634f6425576', '5b17643d-c77d-4e57-baee-d774e4939ef5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a918f24e-289c-42b1-a69e-6634f6425576', '1e0f99d1-9e49-406b-926d-fb822d2bf6cd', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a918f24e-289c-42b1-a69e-6634f6425576', '986e8d1b-e1df-4c6b-b96f-f433982c5f68', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a918f24e-289c-42b1-a69e-6634f6425576', '975af0f7-e4b2-4d1a-88c9-512f18ce3900', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a918f24e-289c-42b1-a69e-6634f6425576', 'df7b5e52-58a0-4365-8c17-7ca42f1fac46', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('545fc4da-c5ba-47fc-a4a1-0e811077557e', '986e8d1b-e1df-4c6b-b96f-f433982c5f68', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('545fc4da-c5ba-47fc-a4a1-0e811077557e', '5b17643d-c77d-4e57-baee-d774e4939ef5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('545fc4da-c5ba-47fc-a4a1-0e811077557e', '1e0f99d1-9e49-406b-926d-fb822d2bf6cd', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('545fc4da-c5ba-47fc-a4a1-0e811077557e', '975af0f7-e4b2-4d1a-88c9-512f18ce3900', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('545fc4da-c5ba-47fc-a4a1-0e811077557e', 'df7b5e52-58a0-4365-8c17-7ca42f1fac46', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('30d97729-f7ca-4c43-81e6-fc3c9780d64c', '5b17643d-c77d-4e57-baee-d774e4939ef5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('30d97729-f7ca-4c43-81e6-fc3c9780d64c', '1e0f99d1-9e49-406b-926d-fb822d2bf6cd', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('30d97729-f7ca-4c43-81e6-fc3c9780d64c', '986e8d1b-e1df-4c6b-b96f-f433982c5f68', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('30d97729-f7ca-4c43-81e6-fc3c9780d64c', '975af0f7-e4b2-4d1a-88c9-512f18ce3900', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('30d97729-f7ca-4c43-81e6-fc3c9780d64c', 'df7b5e52-58a0-4365-8c17-7ca42f1fac46', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1236753d-746e-4bf2-a737-e22d59277e64', 'a1c0a67e-673b-46b5-90a6-5643bc03abc4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a0aca655-4ae3-4ecd-ad1b-ddf57029f877', 'a1c0a67e-673b-46b5-90a6-5643bc03abc4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a26b9b40-4067-439a-881f-75f81f8568e9', 'a1c0a67e-673b-46b5-90a6-5643bc03abc4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3b289a95-43f9-4841-a60f-e70bf4aa1473', 'a1c0a67e-673b-46b5-90a6-5643bc03abc4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e737549b-21f8-4a70-9a81-beebc6aaec2c', 'a1c0a67e-673b-46b5-90a6-5643bc03abc4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c2bb229e-9e81-4a9c-9794-c075bb15adac', 'a1c0a67e-673b-46b5-90a6-5643bc03abc4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('36f43450-aafe-41a1-ad32-1bffb9184490', 'fd470370-ecba-4c62-869e-359b45a60e35', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('36f43450-aafe-41a1-ad32-1bffb9184490', '3701db69-adbd-47a6-abbc-fe63e4af995d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('36f43450-aafe-41a1-ad32-1bffb9184490', 'da7f612a-b1f6-42ee-a4bd-7f3f711d2c85', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fd470370-ecba-4c62-869e-359b45a60e35', '36f43450-aafe-41a1-ad32-1bffb9184490', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fd470370-ecba-4c62-869e-359b45a60e35', '3701db69-adbd-47a6-abbc-fe63e4af995d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fd470370-ecba-4c62-869e-359b45a60e35', 'da7f612a-b1f6-42ee-a4bd-7f3f711d2c85', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3701db69-adbd-47a6-abbc-fe63e4af995d', 'da7f612a-b1f6-42ee-a4bd-7f3f711d2c85', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3701db69-adbd-47a6-abbc-fe63e4af995d', '36f43450-aafe-41a1-ad32-1bffb9184490', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3701db69-adbd-47a6-abbc-fe63e4af995d', 'fd470370-ecba-4c62-869e-359b45a60e35', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('da7f612a-b1f6-42ee-a4bd-7f3f711d2c85', '3701db69-adbd-47a6-abbc-fe63e4af995d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('da7f612a-b1f6-42ee-a4bd-7f3f711d2c85', '36f43450-aafe-41a1-ad32-1bffb9184490', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('da7f612a-b1f6-42ee-a4bd-7f3f711d2c85', 'fd470370-ecba-4c62-869e-359b45a60e35', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c76ddda4-0445-4934-95bf-8a51a313ef40', '79ada8de-a505-4a4f-a5a1-f9c4610cf30d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c76ddda4-0445-4934-95bf-8a51a313ef40', '3dd22a58-1ba5-4fc5-b245-9267b22c678d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('538cdaea-8e63-4122-b82f-d8bc545dcfeb', 'c76ddda4-0445-4934-95bf-8a51a313ef40', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('538cdaea-8e63-4122-b82f-d8bc545dcfeb', '79ada8de-a505-4a4f-a5a1-f9c4610cf30d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('538cdaea-8e63-4122-b82f-d8bc545dcfeb', '3dd22a58-1ba5-4fc5-b245-9267b22c678d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a4cba2fe-4ac8-444b-9ebd-1342142f21d4', 'c76ddda4-0445-4934-95bf-8a51a313ef40', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a4cba2fe-4ac8-444b-9ebd-1342142f21d4', '79ada8de-a505-4a4f-a5a1-f9c4610cf30d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a4cba2fe-4ac8-444b-9ebd-1342142f21d4', '3dd22a58-1ba5-4fc5-b245-9267b22c678d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('79ada8de-a505-4a4f-a5a1-f9c4610cf30d', 'c76ddda4-0445-4934-95bf-8a51a313ef40', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('79ada8de-a505-4a4f-a5a1-f9c4610cf30d', '3dd22a58-1ba5-4fc5-b245-9267b22c678d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6850e68-66dd-4374-ac20-22b9ae8aa981', 'c76ddda4-0445-4934-95bf-8a51a313ef40', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6850e68-66dd-4374-ac20-22b9ae8aa981', '79ada8de-a505-4a4f-a5a1-f9c4610cf30d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6850e68-66dd-4374-ac20-22b9ae8aa981', '3dd22a58-1ba5-4fc5-b245-9267b22c678d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9fcc1ce7-39eb-40e1-94bc-316f8c2be4a2', 'c76ddda4-0445-4934-95bf-8a51a313ef40', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9fcc1ce7-39eb-40e1-94bc-316f8c2be4a2', '79ada8de-a505-4a4f-a5a1-f9c4610cf30d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9fcc1ce7-39eb-40e1-94bc-316f8c2be4a2', '3dd22a58-1ba5-4fc5-b245-9267b22c678d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3dd22a58-1ba5-4fc5-b245-9267b22c678d', 'c76ddda4-0445-4934-95bf-8a51a313ef40', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3dd22a58-1ba5-4fc5-b245-9267b22c678d', '79ada8de-a505-4a4f-a5a1-f9c4610cf30d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5a5af824-a078-4add-a850-a1176476eebb', 'c76ddda4-0445-4934-95bf-8a51a313ef40', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5a5af824-a078-4add-a850-a1176476eebb', '79ada8de-a505-4a4f-a5a1-f9c4610cf30d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5a5af824-a078-4add-a850-a1176476eebb', '3dd22a58-1ba5-4fc5-b245-9267b22c678d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('867e8afb-6449-417c-8c4b-9ea713699b34', 'c76ddda4-0445-4934-95bf-8a51a313ef40', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('867e8afb-6449-417c-8c4b-9ea713699b34', '79ada8de-a505-4a4f-a5a1-f9c4610cf30d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('867e8afb-6449-417c-8c4b-9ea713699b34', '3dd22a58-1ba5-4fc5-b245-9267b22c678d', 2) ON CONFLICT DO NOTHING;



INSERT INTO public.faqs VALUES ('56dd39c8-b4ff-45cb-a2d8-4268c97393d9', 'متى يوصلني الرد بعد الاشتراك؟', 'خلال 48 ساعة عمل. أيام العمل من الأحد إلى الخميس، من 12 الظهر حتى 9 مساءً، والتواصل على واتساب.', 0, true, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('b049f46b-7977-4199-a28b-2d2cc617c5c3', 'كيف تتم المتابعة؟', 'ترسل مراجعتك الأسبوعية في يوم المراجعة، وأرد عليك بتعديلات مسجلة (فيديو أو صوت). في الباقة الأساسية المتابعة كل أسبوعين. التواصل اليومي على واتساب مع رد خلال 48 ساعة.', 1, true, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('6182ec0c-c015-49b6-a597-ab63537a913d', 'أنا مبتدئ تماماً، هل يناسبني؟', 'نعم. البرنامج يُبنى على مستواك الحالي، والتمارين مشروحة، وتقدر ترسل مقاطع أدائك لتصحيح التكنيك.', 2, true, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('4bf359c3-4900-41b0-b169-23b1e487c581', 'أتمرن في البيت، ماذا أحتاج من أدوات؟', 'تحدد في النموذج الأدوات المتوفرة عندك (دمبلز، حبال مقاومة، بار…) ويُبنى جدولك عليها.', 3, true, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('48ecdfd0-bbda-4fd6-b281-c5d745d897b8', 'كيف أدفع؟', 'بتحويل بنكي بعد تعبئة الاستبيان. أول ما ترسل الاستبيان يظهر لك رقم طلبك والمبلغ وبيانات الحساب. حوّل المبلغ وارفع صورة الإيصال من صفحة طلبك، ويتأكد اشتراكك بعد التحقق من وصول المبلغ.', 4, true, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('56f391d8-2ad0-4f0a-8d32-c60cafb0f812', 'ما شروط ضمان استرجاع المبلغ؟', 'في اشتراكات 3 أشهر لباقات المتابعة (المكثفة، المتقدمة، الأساسية): إذا لم يتحسن أي مؤشر من مؤشرات تقدمك بعد 12 أسبوعاً، يرجع لك المبلغ كاملاً.
مؤشرات التقدم (بحسب هدفك): متوسط الوزن الأسبوعي، أو محيط الخصر، أو القوة في التمارين الأساسية (الوزن أو التكرارات).
شروط الضمان:
- إرسال المراجعة الأسبوعية كل أسبوع.
- أخذ القياسات بانتظام.
- تصوير التمارين وإرسالها.
- الالتزام بجدول التغذية المخصص (في الباقات التي تشمل تغذية).
يُطلب الاسترجاع عبر واتساب خلال 14 يوماً من نهاية الأشهر الثلاثة.', 5, true, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('7467aa4b-5d07-4c30-a72c-0d8ce0c804a2', 'هل الجداول لي بعد انتهاء الاشتراك؟', 'نعم، جميع الجداول لك مدى الحياة وتقدر تعدّل عليها.', 6, true, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('0088ce4e-7a2c-4723-82c2-73aa1f1fbd63', 'ما هو التجديد المجاني؟', 'مكافأة للملتزمين: إذا كان اشتراكك 3 أشهر تحصل على 3 أشهر إضافية مجاناً، فيصير المجموع 6 أشهر بسعر 3.
الشروط:
- نسبة التزام 90% فأكثر: المراجعات الأسبوعية المرسلة والتمارين المسجلة.
- تقدم واضح في مؤشرات التقدم نفسها المذكورة في الضمان.
- للمتدربين الرجال: إرسال صور التطور (قبل وبعد) للمدربة للتوثيق، مع تغطية الوجه والسرة.
نشر الصور في السوشل ميديا اختياري بالكامل حسب موافقتك، ولا يؤثر على استحقاقك للتجديد.', 7, true, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('36a6d3b5-190b-42e3-bb3f-8c3577d2223c', 'من يطّلع على بياناتي؟', 'المدربة فقط، وتُستخدم لتصميم برنامجك ومتابعتك. لا تُنشر نتيجتك أو صورتك إلا بموافقتك الصريحة في النموذج.', 8, true, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;






INSERT INTO public.policies VALUES ('terms', 'الشروط والأحكام', '- يبدأ الاشتراك بعد التحقق من وصول التحويل البنكي، وتعبئة استبيان المتدرب.
- ساعات العمل: الأحد – الخميس، 12 ظهراً – 9 مساءً. الرد على الرسائل خلال 48 ساعة عمل.
- البرنامج لا يغني عن الاستشارة الطبية، والمتدرب مسؤول عن الإفصاح عن أي إصابة أو حالة صحية.
- الجداول ملك المتدرب مدى الحياة ويمكنه التعديل عليها.
- الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي.', 0, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.policies VALUES ('refund', 'الضمان والاسترجاع', '- في اشتراكات 3 أشهر لباقات المتابعة (المكثفة، المتقدمة، الأساسية): يُسترد المبلغ كاملاً إذا لم يتحسن أي من مؤشرات التقدم (متوسط الوزن الأسبوعي، محيط الخصر، القوة في التمارين الأساسية) بعد 12 أسبوعاً.
- شروط الضمان: إرسال المراجعة الأسبوعية كل أسبوع، وأخذ القياسات بانتظام، وتصوير التمارين وإرسالها، والالتزام بجدول التغذية المخصص في الباقات التي تشملها.
- يُطلب الاسترجاع عبر واتساب خلال 14 يوماً من نهاية الأشهر الثلاثة، ويُرجع المبلغ بتحويل بنكي.
- التجديد المجاني: اشتراك 3 أشهر يُكافأ بـ 3 أشهر إضافية عند التزام 90% فأكثر وتقدم واضح في مؤشرات التقدم. صور التطور تُرسل للمدربة للتوثيق (للرجال مع تغطية الوجه والسرة)، ونشرها اختياري.', 1, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.policies VALUES ('privacy', 'سياسة الخصوصية', '- نجمع: الاسم، البريد الإلكتروني (للدخول إلى حسابك)، رقم الجوال (واتساب)، الباقة المختارة، ومعلومات الاستبيان التي تكتبها بنفسك (ومنها معلومات صحية وقياسات اختيارية).
- الغرض: تنفيذ طلبك، وتصميم برنامجك ومتابعتك، والتواصل معك بخصوصه فقط.
- المعلومات الصحية تُحفظ منفصلة، ولا يطّلع عليها إلا أنت والمدربة، ولا تُرسل في رسائل البريد أو التنبيهات.
- الدفع بتحويل بنكي مباشر لحساب المؤسسة، والموقع لا يطلب أو يخزن أي بيانات بنكية أو بيانات بطاقات. إيصال التحويل يُستخدم لتأكيد طلبك فقط، ويُحفظ في تخزين خاص لا يُفتح إلا لك وللمدربة.
- لا نبيع بياناتك ولا نشاركها مع أي طرف لأغراض تسويقية، ولا تُنشر نتيجتك أو صورتك إلا بموافقتك الصريحة.
- تقدر تطلب نسخة من بياناتك أو حذفها أو سحب موافقتك على النشر بمراسلتنا على واتساب.', 2, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.policies VALUES ('reviews', 'سياسة التقييمات', '- يكتب التقييم فقط من اشترى خدمة وبدأها فعلاً، وتقييم واحد لكل طلب.
- كل تقييم يُراجع قبل ظهوره للعامة، ولا يُعدّل نصه أبداً.
- تختار بنفسك طريقة ظهور اسمك: الاسم كامل، أو الاسم الأول فقط، أو بدون اسم. والموافقة على النشر منفصلة واختيارية.
- لا يُنشر تقييم يحتوي أرقام هواتف أو بريد أو روابط أو تفاصيل صحية خاصة أو إساءة لأي شخص.
- يحق للمدربة الرد على التقييم، أو إخفاء التقييم المخالف لهذه السياسة مع تسجيل السبب.
- تقدر تطلب إخفاء تقييمك في أي وقت بمراسلتنا على واتساب.', 3, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;



INSERT INTO public.products VALUES ('354787ec-1429-4d41-a906-557f0a153fc2', 'intensive', 'follow', 'الباقة المكثفة', 'الأنسب للمبتدئين ولمن يحتاج متابعة أسبوعية مع زوم: تمرين + تغذية + زوم + جلسة حضورية', '[{"text": "جلسة حضورية مجانية لمدة ساعة لتصحيح التكنيك والتأكد من جودة التمرين (للبنات في المنطقة الشرقية)", "included": true}, {"text": "ملف شامل للخطة التدريبية والتغذية مع شروحات وافية للتمارين، بالمنزل أو بالنادي", "included": true}, {"text": "4 مكالمات زوم شهرياً نتابع فيها تطورك واستفساراتك الرياضية والنفسية", "included": true}, {"text": "مناقشة أسبوعية لتطورك البدني والنفسي (فيديو أو تسجيل صوتي) مع تعديل السعرات أو التمرين عند الحاجة", "included": true}, {"text": "شرح سهل ومبسط لتطبيق حساب السعرات MyFitnessPal", "included": true}, {"text": "كتيب شامل للرياضة والتغذية", "included": true}, {"text": "مساعدتك على اختيارات أنسب لصحتك ونمط حياتك في التغذية والروتين اليومي", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}]', NULL, 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.', true, NULL, 'published', 0, false, '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('67ef0039-0e1a-4fa1-a490-36bb09c8396b', 'advanced', 'follow', 'الباقة المتقدمة', 'لمن عنده خبرة ويحتاج تمرين + تغذية مع متابعة أسبوعية، بدون زوم', '[{"text": "ملف شامل للخطة التدريبية والتغذية مع شروحات وافية للتمارين، بالمنزل أو بالنادي", "included": true}, {"text": "مناقشة أسبوعية لتطورك البدني والنفسي (فيديو أو تسجيل صوتي) مع تعديل السعرات أو التمرين عند الحاجة", "included": true}, {"text": "كتيب شامل للرياضة والتغذية", "included": true}, {"text": "مساعدتك على اختيارات أنسب لصحتك ونمط حياتك في التمرين والروتين اليومي", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}, {"text": "مكالمات زوم والجلسة الحضورية (في المكثفة فقط)", "included": false}]', NULL, 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.', false, NULL, 'published', 1, false, '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('a19f384e-2fcd-4716-8b63-2cc3b8d9c482', 'basic', 'follow', 'الباقة الأساسية', 'لمن يعرف يضبط أكله ويحتاج خطة تمرين فقط، ومتابعة كل أسبوعين', '[{"text": "ملف شامل للخطة التدريبية مع شروحات وافية للتمارين، بالمنزل أو بالنادي", "included": true}, {"text": "مناقشة كل أسبوعين لتطورك البدني والنفسي (فيديو أو تسجيل صوتي) مع تعديل التمرين عند الحاجة", "included": true}, {"text": "كتيب شامل للرياضة والتغذية", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}, {"text": "بدون خطة تغذية", "included": false}]', NULL, 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.', false, NULL, 'published', 2, false, '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('ed906738-0b77-4663-bb06-e7f1c98e5dfe', 'nutrition', 'follow', 'باقة التغذية', 'لمن يحتاج خطة تغذية شاملة ويتعلم حساب السعرات، بدون خطة تمرين', '[{"text": "خطة تغذية شاملة تناسب هدفك ونمط حياتك", "included": true}, {"text": "تحديد السعرات المناسبة لك ولهدفك", "included": true}, {"text": "تعليمك حسبة السعرات ومساعدتك باختيارات تغذية تناسبك", "included": true}, {"text": "ملف Excel لمتابعة التطور والقياسات", "included": true}, {"text": "مناقشة أسبوعية لعلاقتك بالتغذية في المنزل أو خارجه", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}, {"text": "لا تحتاجها إذا كنت مشتركاً في المكثفة أو المتقدمة، لأن التغذية ضمنها", "included": false}]', 'شهر واحد · غالباً لا تحتاج تجديد', 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي، ولا يوجد تجديد تلقائي. ضمان الاسترجاع يشمل اشتراكات 3 أشهر للمكثفة والمتقدمة والأساسية فقط.', false, NULL, 'published', 3, false, '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('7e786d60-86b1-4843-93e2-22049f29381c', 'custom-training-plan', 'files', 'بديل التدريب الشخصي', 'لمن لا يحتاج متابعة (متقدم)، أو كبديل أوفر للتدريب الشخصي', '[{"text": "جدول تمرين مخصص لعدد أيام التمرين اللي تحتاجها", "included": true}, {"text": "طريقة حساب الجهد وعدد الجولات المطلوبة", "included": true}, {"text": "تقدر تحمّل الجدول على جهازك", "included": true}]', NULL, 'جدول مخصص بعد الاستبيان تستلمه كملف، وتقدر تحمّله على جهازك. بدون متابعة.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي. الجداول لك مدى الحياة وتقدر تعدّل عليها.', false, NULL, 'published', 4, false, '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('8ed92efb-22d6-4353-ab28-957338fd84ba', 'training-nutrition-plan', 'files', 'جدول تمارين مع التغذية', 'لمن لا يحتاج متابعة (متقدم)، أو كبديل أوفر للتدريب الشخصي', '[{"text": "جدول تمرين مخصص لعدد أيام التمرين اللي تحتاجها", "included": true}, {"text": "طريقة حساب الجهد وعدد الجولات المطلوبة", "included": true}, {"text": "جدول تغذية فيه خيارات تناسب هدفك الرياضي", "included": true}, {"text": "تقدر تحمّل الجدول على جهازك", "included": true}]', NULL, 'جدول مخصص بعد الاستبيان تستلمه كملف، وتقدر تحمّله على جهازك. بدون متابعة.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي. الجداول لك مدى الحياة وتقدر تعدّل عليها.', false, NULL, 'published', 5, false, '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('9c1febdb-320a-466f-8715-95b62c60c1f4', 'nutrition-consultation', 'consult', 'جلسة استشارة تغذية', 'لمن عنده أسئلة محددة في التغذية: جلسة وحدة تكفي لحسبة سعراتك ونصائح الأكل.', '[{"text": "مناقشة كل أسئلتك في مجال التغذية", "included": true}, {"text": "حسبة سعرات مناسبة لهدفك مع اقتراحات لأصناف الطعام", "included": true}, {"text": "نصائح في المكملات، وكيف تأكل برّا بطريقة صحيحة", "included": true}]', NULL, 'جلسة عبر Google Meet أو واتساب — المناسب لك.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي.', false, NULL, 'published', 6, false, '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('02ffbb52-a2fd-4972-bc84-6861f0930077', 'training-consultation', 'consult', 'جلسة استشارة تمرين', 'لمن عنده أسئلة محددة في التمرين: جلسة وحدة تكفي لتعديل جدولك وتصحيح التكنيك.', '[{"text": "مناقشة كل أسئلتك في مجال التمرين", "included": true}, {"text": "تعديل جدولك الرياضي بما يناسب هدفك، مع اقتراحات لتمارين المرونة", "included": true}, {"text": "تصحيح تكنيك التمارين اللي تشك إنها غلط أو تسبب لك ألم", "included": true}, {"text": "التأكد من أن جودة تمرينك مناسبة للبناء العضلي", "included": true}]', NULL, 'جلسة عبر Google Meet أو واتساب — المناسب لك.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي.', false, NULL, 'published', 7, false, '2026-09-27 13:37:23.796574+00', '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;



INSERT INTO public.product_offers VALUES ('cc8576e1-3516-44ca-96e7-5ca45b5ae3c8', '354787ec-1429-4d41-a906-557f0a153fc2', 'int1', 'شهر واحد', 1, 59900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('385cee37-e2b4-44c5-b49b-132023fb3423', '354787ec-1429-4d41-a906-557f0a153fc2', 'int3', '3 أشهر', 3, 155000, 'SAR', true, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('0fc12b20-fc44-4b11-b6e7-6be5ea7dd22b', '67ef0039-0e1a-4fa1-a490-36bb09c8396b', 'adv1', 'شهر واحد', 1, 49900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('5f8141c4-c054-4878-a4c2-5311855e9d66', '67ef0039-0e1a-4fa1-a490-36bb09c8396b', 'adv3', '3 أشهر', 3, 125000, 'SAR', true, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('9f6d4944-b0f6-43b8-8c9c-fd42613f9718', 'a19f384e-2fcd-4716-8b63-2cc3b8d9c482', 'bas1', 'شهر واحد', 1, 34900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('d855cc99-907c-4d47-8e1e-15b91771d053', 'a19f384e-2fcd-4716-8b63-2cc3b8d9c482', 'bas3', '3 أشهر', 3, 95000, 'SAR', true, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('b6ef64cf-dc5a-4405-814c-6c6317451cf3', 'ed906738-0b77-4663-bb06-e7f1c98e5dfe', 'nut1', 'شهر واحد', 1, 25000, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('90be59c0-ed99-41f1-9bc5-ecf632ae23bb', '7e786d60-86b1-4843-93e2-22049f29381c', 'diy', 'دفعة واحدة', 0, 19900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('57570559-86dc-42fb-91a9-48e6bc011b1e', '8ed92efb-22d6-4353-ab28-957338fd84ba', 'diyN', 'دفعة واحدة', 0, 25000, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('cbe43631-addb-49e3-b829-4917a1dd07c6', '9c1febdb-320a-466f-8715-95b62c60c1f4', 'cN', 'دفعة واحدة', 0, 15000, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('07e8e57f-0677-47b4-a648-8529e42b044d', '02ffbb52-a2fd-4972-bc84-6861f0930077', 'cT', 'دفعة واحدة', 0, 18900, 'SAR', true, 0) ON CONFLICT DO NOTHING;



INSERT INTO public.reviews VALUES ('07379ee9-74f8-43f1-a092-1fb3ae4c2e97', 'legacy', NULL, NULL, NULL, NULL, 'اشتركت معها 3 شهور وكانت أول مره التزم بالتمرين بعد سحبات سنين، اسلوبها سهل وسريع بس نتايجه واضحه من اول اسبوعين قياسات جسمي بدت تتغير والكوتش مريحه نفسيًا وشاطرة الله يعطيها العافيه غيرت حياتي واعطتني افضل بداية 🙏🏻', 'first', 'ريم', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 0, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('acfa55eb-bdd3-4bbd-9cc1-26ec97080557', 'legacy', NULL, NULL, NULL, 5, 'من أصدق التجارب اللي مرّيت فيها! تدريبك ما كان بس جداول رياضه وتغذية كان دعم نفسي وتحفيز وتغيير حقيقي في حياتي حسّيت بفرق كبير في جسمي وطاقتي وثقتي بنفسي من أول أسبوع شكراً من القلب على تعبك وحرصك على كل تفصيلة وتعطي من قلبك، فعلاً you are the best coach ever تستاهلين كل النجاح والله ❤️', 'first', 'نورة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 1, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('24a5c2c1-0dd7-4fcc-95f7-2ed9471338f0', 'legacy', NULL, NULL, NULL, 5, 'بعد شهر من الالتزام بالجدول، لاحظت فرق واضح! متنوع وفعال، أنصح فيه بشدة 😍👌', 'first', 'البندري', 'مارس 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 2, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('0b41d0e1-0f6d-42f0-aaa4-b8d22e6e8126', 'legacy', NULL, NULL, NULL, NULL, 'رغم ان فتره تدريبي معاها كانت اقل من شهرين السنه الماضيه الا ان نتايج هالشهرين مستمره معي الى اليوم 😍 اسلوب احترافي وفعال وتركز على بناء وتطوير عادات تدوم مو بس تمارين مؤقته 👍🏻', 'first', 'خديجة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 3, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('97bdc8a6-3c25-473c-9fbe-6befe34b3656', 'legacy', NULL, NULL, NULL, 5, 'كوتش ساره جداً شاطره و بروفيشنال، جداً متعاونه و تعرف شغلها كويس، جداً لطيفه، كنت لفتره متدربه عندها و كنت أشوف نتايج بطله بالاضافه لكوني اروح اتمرن و أنا مستمتعه، شكراً ساره', 'first', 'نجمة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 4, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('95d7efcb-180c-46b4-ac9a-ac0d58019cb3', 'legacy', NULL, NULL, NULL, 5, 'ممتاز جدول حلو ومرتب جدا وفرق معي كثير 🤍', 'first', 'سعود', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 5, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('575e03ba-696d-4429-b7a0-2e0976e31717', 'legacy', NULL, NULL, NULL, 5, 'كنت اعاني من الم بظهري مستمررر سنوات وانحراف بالعمود ولكن بفضل الله ثم المدربة تحسنت بنسبة كبيرة وتابع معي خطوة بخطوة بكل أمانة وإتقان الله يكثر من امثالك 🤍', 'first', 'ش**س**', 'أغسطس 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 6, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('6cab3425-5772-4bee-8b94-f641ac3d888f', 'legacy', NULL, NULL, NULL, 5, 'الشكر يعجز عنك يااروع كوتش باشتراكي معك شفت صحة وراحة بعد الله وساعدتيني مره بمشكلة ظهري وضعف العضلات العلوية وانعكس على نفسيتي وادائي اليومي شكررا شكرا من القلب وياحظنا فيك', 'first', 'فاطمة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 7, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('2c882b47-2fca-40a8-beb6-6b994a073096', 'legacy', NULL, NULL, NULL, 5, 'مره استفدت بالتدريب مع كوتش ناف و مبسوطه ان في احد بذمة و ضمير جالس يتابع تقدمي و ينصحني من قلب الله يسعدك ويوفقك ❤️', 'first', 'ميثاء', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 8, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('bc6f1616-14da-48d0-b3e7-e8ec7f2e297b', 'legacy', NULL, NULL, NULL, 5, 'تجربه ولا أروع ! أحب جداولها وقد ايش تختصر وتعطيك المهم والاهم والنتايج رهيييبه ❤️', 'first', 'أمجاد', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 9, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('49506efd-19bf-47cd-9b14-82e2afa495d7', 'legacy', NULL, NULL, NULL, 5, 'افضل مدربة بالمجرة، كنت دبه ونحفت بثلاث شهور بس، i highly recommend her she is the best 💗', 'first', 'شروق', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 10, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('9b939487-3151-4110-b651-5c7326270dcb', 'legacy', NULL, NULL, NULL, 5, 'الجدول ممتاز و فعّال لفترة الصيام، يساعدك تنظم وقتك ويقدّم توصيات غذائيه و خطه تمارين تساعدك تحافظ على لياقتك بدون إرهاق 👍🏻. خيار ممتاز خاصة للأشخاص للي وقتها محدود ومزحوم فرمضان.', 'first', 'خديجة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 11, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;



INSERT INTO public.site_settings VALUES ('reminders', '{"review_text": "مرحباً {name}، تذكير بمراجعتك الأسبوعية: المراجعة مفتوحة من {window_start} إلى {window_end}.", "sub_expiry_days": [7, 3], "sub_expiry_text": "مرحباً {name}، اشتراكك في {product} ينتهي بتاريخ {end_date}. للتجديد أو الاستفسار تواصل معنا.", "review_lead_days": 1, "missed_review_text": "مرحباً {name}، ما وصلتنا مراجعة الأسبوع المنتهي في {window_end}. متى ما تيسّر لك، حدّثها عشان نتابع تقدمك.", "review_window_days": 2, "manual_cooldown_minutes": 10}', false, NULL, '2026-09-27 13:37:23.408576+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('hero', '{"lead": "خطة تدريب وغذاء منظمة، متابعة للتقدم، وتعديلات أسبوعية تناسب مستواك وظروفك.", "title": "برامج تدريب وتغذية مخصصة لأهدافك", "eyebrow": "Nav Coaching · الكوتش ساره", "tagline": "Where Passion Meets Quality", "title_tail": "تحت إشراف مدربة يدفعها الشغف"}', true, NULL, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('badges', '["خصم 10% للطلاب", "مجاني لأهل غزة", "ضمان استرجاع المبلغ بشروط"]', true, NULL, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('why', '[{"body": "البرنامج يُصمم بعد استبيان مفصل لهدفك وأيامك المتاحة وأدواتك وأي إصابة تحتاج مراعاة.", "title": "مبني على هدفك ومستواك"}, {"body": "مراجعة منتظمة بالفيديو أو الصوت، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.", "title": "متابعة أسبوعية واضحة"}, {"body": "نعدّل التمرين والسعرات بناءً على قياساتك والتزامك، عشان تثبت النتيجة.", "title": "تعديلات حسب تقدمك"}]', true, NULL, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('how_steps', '[{"body": "اختر الباقة والمدة، وعبّي استبيان قصير عن هدفك ومستواك وأيامك وأي إصابة.", "title": "اختر برنامجك وعبّي الاستبيان"}, {"body": "بعد الاستبيان يظهر لك رقم طلبك وبيانات الحساب. حوّل وارفع صورة الإيصال من صفحة طلبك.", "title": "حوّل المبلغ"}, {"body": "بعد التحقق من التحويل أتواصل معك خلال 48 ساعة عمل، وتستلم ملف برنامجك وتبدأ المتابعة.", "title": "استلم برنامجك وابدأ"}]', true, NULL, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('about', '{"bio": "مدربة شخصية معتمدة، أدرب منذ 2017. أساعدك تبني روتين تدريب وتغذية واضح يناسب هدفك ووقتك ومستواك، مع متابعة أسبوعية تساعدك تستمر وتتقدم.", "fit": ["اللي يؤمن إن التمرين أسلوب حياة، مو تمرين لشكل مؤقت أو لفترة الصيف بس.", "**وإذا ما التزمت؟** أحاول أفهم أسبابك، وأساعدك تعالجها بقدر ما أقدر. وإذا كان الموضوع أكبر من اللي أقدر أقدمه، أقول لك بصراحة وأعتذر عن تدريبك."], "name": "الكوتش ساره | ناڤ", "certs": ["Saudi Reps — Level 4", "NCSF", "Menno Henselmans CPT", "Functional Mobility", "Pre & Postnatal Training", "Prenatal Fitness Training — Aspire Academy", "ماجستير تدريب رياضي — جامعة ستيرلنق"], "notes": [{"body": "لأني جاية من عالم الرياضات الإلكترونية، صممت باقة خاصة للقيمرز: لياقة أفضل داخل وخارج الشاشة، والتعامل مع آلام الظهر والمفاصل من الجلوس الطويل.", "href": "/programs/gamers", "label": "شوف باقة القيمرز ←", "title": "للاعبي الألعاب الإلكترونية"}, {"body": "تدريب الحوامل عندي حضوري فقط. أونلاين يصعب أتأكد إن التمرين يتنفذ بإتقان، والحمل فترة مهمة جداً تحتاج هالتأكد. أونلاين أقدم للحوامل متابعة التغذية فقط.", "href": "", "label": "", "title": "للحوامل"}], "story": ["قبل ما أصير مدربة، كنت متدربة تعبت من التجارب. اشتركت مع مدربات أجانب، وما لقيت أحد يشرح لي التمرين صح أو يهتم بأهدافي.", "لين اشتركت مع الكوتش سحر الحارثي. غيّرت نظرتي للتمرين، وحفّزتني أصير كوتش، وإلى اليوم أشكرها على كل اللي علمتني إياه. من هنا قررت أكون الشخص اللي احتجته أنا.", "والرياضة جزء مني من بدري: لعبت كرة السلة وكنت كابتن فريق السلة في جامعة الإمام عبدالرحمن بن فيصل، ولعبت باحتراف في الرياضات الإلكترونية. بدأت التدريب في 2017 مع كرة السلة، واشتغلت مساعد مدرب في نادي الجامعة، وبعدها دربت في بيور جم وجمنيشن وفتنس لاونج ونوادي خاصة."], "points": ["برنامج مبني على هدفك ومستواك.", "متابعة أسبوعية واضحة.", "تعديلات مستمرة حسب تقدمك والتزامك."], "pillars": [{"body": "ما أرسل لك جدول وأتركك. أراجعه معك بمقطع فيديو أشرح فيه كل شي، عشان تبدأ وأنت فاهم وش تسوي وليش.", "title": "جدولك مشروح بالفيديو"}, {"body": "ما أمشي على أنظمة الحرمان أبداً. خطتك تناسب حياتك، مو قائمة ممنوعات.", "title": "بدون حرمان"}, {"body": "أتابعك كل أسبوع وأهتم بالتزامك، وأعدّل خطتك حسب تقدمك وظروفك.", "title": "متابعة جادة وخطة واقعية"}, {"body": "حب تعليم الناس معي من الصغر. اللي أعرفه ما أبخل فيه، علمياً ونفسياً، وما أوقف عن البحث والتعلم عشان أتطور وأطورك معي.", "title": "أعلّمك، مو بس أدربك"}], "home_bio": "مدربة شخصية معتمدة، أدرب منذ 2017، وكابتن سابقة لفريق السلة في جامعة الإمام عبدالرحمن بن فيصل. أساعدك تبني روتين تدريب وتغذية واضح يناسب هدفك ووقتك ومستواك، مع متابعة أسبوعية وبدون أنظمة حرمان.", "fit_title": "أكثر شخص أفرق معه", "experience": ["أدرب منذ 2017، والبداية في كرة السلة.", "مساعد مدرب في نادي الجامعة.", "مدربة في بيور جم، وجمنيشن، وفتنس لاونج، ونوادي خاصة."], "story_title": "صرت الشخص اللي كنت أحتاجه", "pillars_title": "وش يميز التدريب معي؟", "experience_title": "شهاداتي وخبرتي"}', true, NULL, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('intro_video', '{"url": "", "body": "مقطع قصير أتكلم فيه عن نفسي وخلفيتي وطريقة شغلي مع المتدربين.", "title": "تعرّف عليّ في دقيقة"}', true, NULL, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('testimonials_disclaimer', '"التجارب شخصية وتختلف النتائج من شخص لآخر حسب الالتزام والحالة، والتدريب لا يغني عن استشارة الطبيب أو أخصائي العلاج الطبيعي."', true, NULL, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('prices_note', '"الأسعار بالريال السعودي. الدفع بتحويل بنكي على حساب المؤسسة."', true, NULL, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('checkins', '{"enabled": true, "questions": [{"q": "ملاحظاتك الصحية؟ الحركة اليومية وجودة الحياة صارت أحسن؟", "topic": "الصحة العامة"}, {"q": "أداؤك في التمارين؟ في تقدم في الأوزان والأداء؟", "topic": "التمارين"}, {"q": "فرق في شكلك ومظهرك؟ إيجابي أو سلبي؟", "topic": "المظهر"}, {"q": "فرق في الملابس أو المقاسات؟ إيجابي أو سلبي؟", "topic": "الملابس"}, {"q": "النظام الغذائي — قدرت تمشي عليه؟ فيه صعوبة؟", "topic": "الغذاء"}, {"q": "تحسّ بالجوع واجد؟ إن وُجد، كم تعطيه من 5؟", "topic": "الجوع"}, {"q": "أي ملاحظات سلبية تبي تشاركها؟ (مهمة أو بسيطة — نتقبل النقد)", "topic": "ملاحظات سلبية"}, {"q": "أي إشكاليات أو ملاحظات إضافية تحتاج مساعدة فيها؟", "topic": "ملاحظات أخرى"}, {"q": "وصلت لأي أسبوع تدريبي الآن؟", "topic": "الأسبوع"}]}', true, NULL, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('contact', '{"whatsapp": "966599162724", "instagram": "https://www.instagram.com/navvcoaching/"}', true, NULL, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('response_time', '"48 ساعة عمل (الأحد – الخميس، 12 ظهراً – 9 مساءً)"', true, NULL, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('legal', '{"cr": "7050950752", "name": "مؤسسة ناف كوتشنق للتدريب الرياضي"}', true, NULL, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('bank', '{"iban": "SA1280000139608016245411", "bankName": "مصرف الراجحي", "accountName": "مؤسسة ناف كوتشنق للتدريب الرياضي"}', true, NULL, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('program_shots', '[{"h": 368, "w": 1310, "alt": "لقطة من ملف المتدرب: جدول اليوم الأول لتمارين الجزء السفلي مع الجولات والتكرارات وRIR", "src": "shots/training.webp", "title": "جدول التمرين", "caption": "جدول لكل يوم تدريبي: التمرين، الجولات، التكرارات، الوزن، وRIR، وتظهر العضلة الأساسية والثانوية تلقائياً."}, {"h": 473, "w": 1472, "alt": "لقطة من ملف المتدرب: قائمة منسدلة لاختيار التمرين أو البديل مع العضلة الأساسية والثانوية", "src": "shots/exercise-picker.webp", "title": "اختيار التمرين والبدائل", "caption": "تختار التمرين أو بديله من قائمة منسدلة، وتتحدث العضلات المستهدفة مباشرة."}, {"h": 634, "w": 1034, "alt": "لقطة من لوحة التقدم في ملف المتدرب ببيانات مثال: الوزن والقياسات والخطوات الأسبوعية مقابل الهدف", "src": "shots/progress.webp", "title": "لوحة التقدم", "caption": "متوسط الوزن الأسبوعي والقياسات والخطوات مقابل الهدف، ببيانات مثال."}, {"h": 641, "w": 1600, "alt": "لقطة من ورقة المراجعة الأسبوعية في ملف المتدرب: أسئلة المراجعة بدون إجابات", "src": "shots/weekly-review.webp", "title": "المراجعة الأسبوعية", "caption": "أسئلة ثابتة كل أسبوع عن الصحة والتمارين والغذاء والجوع، وبجانبها ملاحظات المدربة."}]', true, NULL, '2026-09-27 13:37:23.796574+00') ON CONFLICT DO NOTHING;
COMMIT;
