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

-- ---------- 040_alert_reads.sql ----------
-- =====================================================================
-- «تمت القراءة» لتنبيهات المتابعة في لوحة الإدارة.
-- التنبيهات تُحسب وقت فتح الصفحة (ما لها جدول)، فنحفظ مفتاح كل تنبيه قرأته المدربة ويختفي.
-- المفتاح يتغيّر إذا تغيّر سبب التنبيه (مثل مراجعة أسبوع جديد)، فيظهر التنبيه الجديد عادي.
-- =====================================================================
CREATE TABLE IF NOT EXISTS coach_alert_reads (
  key text PRIMARY KEY CHECK (length(key) BETWEEN 3 AND 200),
  read_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE coach_alert_reads ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS alert_reads_coach ON coach_alert_reads;
CREATE POLICY alert_reads_coach ON coach_alert_reads FOR ALL USING (app.is_coach()) WITH CHECK (app.is_coach());
GRANT SELECT, INSERT, DELETE ON coach_alert_reads TO nav_app;

INSERT INTO schema_migrations (name) VALUES ('040_alert_reads.sql');

-- ---------- 041_program_start_lock.sql ----------
-- =====================================================================
-- الاشتراك اللي اختار فيه المتدرب «تاريخ أحدده»: البرنامج (التمرين والتغذية والمكملات) ما يظهر له
-- ولا يقبل تسجيلاً إلا من تاريخ بداية الاشتراك، حتى لو أسندته المدربة قبلها.
-- - المرجع: تاريخ بداية الاشتراك بتوقيت الرياض (sub_start_at)؛ فإذا غيّرته المدربة لتاريخ أبكر ينفتح من تاريخها.
-- - «بأقرب وقت» (preferred_start فارغ) والتجديد بدون تاريخ مختار: لا تغيير.
-- - المدربة تشوف كل شي دائماً.
-- =====================================================================
CREATE OR REPLACE FUNCTION app.program_started(p_order uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT NOT EXISTS (
    SELECT 1 FROM orders o
     WHERE o.id = p_order AND o.preferred_start IS NOT NULL AND o.sub_start_at IS NOT NULL
       AND (o.sub_start_at AT TIME ZONE 'Asia/Riyadh')::date > (now() AT TIME ZONE 'Asia/Riyadh')::date)
$$;
REVOKE ALL ON FUNCTION app.program_started(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.program_started(uuid) TO nav_app;

CREATE OR REPLACE FUNCTION app.block_visible(p_block uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT app.is_coach() OR EXISTS (SELECT 1 FROM blocks b WHERE b.id = p_block AND app.order_entitled(b.order_id) AND app.program_started(b.order_id))
$$;

CREATE OR REPLACE FUNCTION app.plan_visible(p_plan uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT app.is_coach() OR EXISTS (SELECT 1 FROM nutrition_plans p WHERE p.id = p_plan AND p.order_id IS NOT NULL AND NOT p.archived
                                    AND app.order_entitled(p.order_id) AND app.program_started(p.order_id))
$$;

CREATE OR REPLACE FUNCTION app.routine_visible(p_routine uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT app.is_coach() OR EXISTS (SELECT 1 FROM supplement_routines r WHERE r.id = p_routine AND r.order_id IS NOT NULL AND NOT r.archived
                                    AND app.order_entitled(r.order_id) AND app.program_started(r.order_id))
$$;

DROP POLICY IF EXISTS targets_read ON nutrition_targets;
CREATE POLICY targets_read ON nutrition_targets FOR SELECT USING (
  app.is_coach() OR (app.order_entitled(order_id) AND app.program_started(order_id) AND (kcal_source <> 'auto' OR kcal_confirmed_at IS NOT NULL))
);

-- التسجيل على البرنامج (التمارين، تقييم اليوم، الخطوات…) يمر على my_active_block: يُرفض قبل تاريخ البداية
CREATE OR REPLACE FUNCTION app.my_active_block(p_block uuid) RETURNS blocks
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v blocks%ROWTYPE;
BEGIN
  PERFORM app.require_user();
  SELECT * INTO v FROM blocks WHERE id = p_block;
  IF NOT FOUND OR v.user_id <> app.uid() OR NOT app.order_entitled(v.order_id) THEN
    RAISE EXCEPTION 'البرنامج غير موجود.' USING ERRCODE = 'P0001';
  END IF;
  IF NOT app.program_started(v.order_id) THEN
    RAISE EXCEPTION 'برنامجك يبدأ من تاريخ بداية الاشتراك.' USING ERRCODE = 'P0001';
  END IF;
  IF v.status <> 'active' THEN RAISE EXCEPTION 'هذا البرنامج منتهي ولا يقبل تعديلات.' USING ERRCODE = 'P0001'; END IF;
  RETURN v;
END $$;

INSERT INTO schema_migrations (name) VALUES ('041_program_start_lock.sql');

-- ---------- 042_booklet_sales.sql ----------
-- =====================================================================
-- الكتيبات: لمشتركي باقات المتابعة فقط، وتُباع منفردة لغيرهم.
-- - يفتح الكتيب: المدربة، أو من له اشتراك في باقة تشمل الكتيبات (الأساسية/المكثفة/المتقدمة؛ ويبقى بعد الانتهاء)،
--   أو من اشترى نفس الكتيب.
--   الباقات الأخرى (ملفات، استشارة، خدمات التطبيق) ما تفتحها بعد الآن.
-- - البيع: لكل كتيب منتج مخفي (category = files، products.booklet_id) بعرض واحد بسعره. الدفع بنفس مسار الطلبات.
--   منتج الكتيب ما يظهر في البرامج ولا الاستبيان (الفلترة في التطبيق)، ويُدار من صفحة الكتيبات فقط.
-- - الشراء يفتح الكتيب من تأكيد الدفع (قيد الإعداد فما بعد).
-- =====================================================================
ALTER TABLE products ADD COLUMN booklet_id uuid UNIQUE REFERENCES booklets (id) ON DELETE SET NULL;
-- الباقات اللي تشمل الكتيبات (الأساسية والمكثفة والمتقدمة)؛ المدربة تغيّرها من صفحة المنتج
ALTER TABLE products ADD COLUMN includes_booklets boolean NOT NULL DEFAULT false;
UPDATE products SET includes_booklets = true WHERE slug IN ('basic', 'intensive', 'advanced');

-- اشتراك في باقة تشمل الكتيبات (يبقى بعد انتهاء الاشتراك)
CREATE OR REPLACE FUNCTION app.has_follow_program() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT app.uid() IS NOT NULL AND EXISTS (
    SELECT 1 FROM orders o JOIN products p ON p.id = o.product_id
     WHERE o.user_id = app.uid() AND p.includes_booklets AND o.status IN ('active', 'delivered', 'completed'));
$$;

-- اشترى هذا الكتيب (من تأكيد الدفع)
CREATE OR REPLACE FUNCTION app.bought_booklet(p_booklet uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT app.uid() IS NOT NULL AND EXISTS (
    SELECT 1 FROM orders o JOIN products p ON p.id = o.product_id
     WHERE o.user_id = app.uid() AND p.booklet_id = p_booklet AND o.status IN ('preparing', 'active', 'delivered', 'completed'));
$$;

DROP POLICY IF EXISTS booklets_read ON booklets;
CREATE POLICY booklets_read ON booklets FOR SELECT USING (
  app.is_coach() OR (published AND app.has_follow_program()) OR app.bought_booklet(id)
);
REVOKE ALL ON FUNCTION app.has_follow_program() FROM PUBLIC;
REVOKE ALL ON FUNCTION app.bought_booklet(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.has_follow_program() TO nav_app;
GRANT EXECUTE ON FUNCTION app.bought_booklet(uuid) TO nav_app;

-- حذف كتيب: منتجه يُؤرشف (الطلبات السابقة تبقى كما هي)
CREATE OR REPLACE FUNCTION app.booklet_archive_product() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  UPDATE products SET status = 'archived', updated_at = now() WHERE booklet_id = OLD.id;
  RETURN OLD;
END $$;
CREATE TRIGGER booklets_archive_product BEFORE DELETE ON booklets FOR EACH ROW EXECUTE FUNCTION app.booklet_archive_product();

-- المدربة: سعر البيع (NULL أو 0 = غير معروض للبيع). ينشئ/يحدّث منتج الكتيب وعرضه، ويتبع اسمه وظهوره
CREATE OR REPLACE FUNCTION app.coach_set_booklet_price(p_booklet uuid, p_price_halalas int) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_coach text := app.require_coach();
  v_b booklets%ROWTYPE;
  v_product uuid;
  v_tag text;
  v_status text;
BEGIN
  SELECT * INTO v_b FROM booklets WHERE id = p_booklet;
  IF NOT FOUND THEN RAISE EXCEPTION 'الكتيب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  IF p_price_halalas IS NOT NULL AND (p_price_halalas < 0 OR p_price_halalas > 10000000) THEN
    RAISE EXCEPTION 'السعر غير صالح.' USING ERRCODE = 'P0001';
  END IF;
  v_status := CASE WHEN coalesce(p_price_halalas, 0) > 0 AND v_b.published THEN 'published' ELSE 'draft' END;
  v_tag := left(replace(v_b.id::text, '-', ''), 12);
  SELECT id INTO v_product FROM products WHERE booklet_id = p_booklet;
  IF v_product IS NULL THEN
    IF coalesce(p_price_halalas, 0) = 0 THEN RETURN; END IF;
    INSERT INTO products (slug, category, name, audience, status, booklet_id, delivery)
    VALUES ('booklet-' || v_tag, 'files', 'كتيب: ' || v_b.title, '', v_status, p_booklet, 'ملف PDF يُحمّل من «حسابي» بعد تأكيد الدفع.')
    RETURNING id INTO v_product;
    INSERT INTO product_offers (product_id, sku, label, months, price_halalas)
    VALUES (v_product, 'bk-' || v_tag, 'ملف PDF', 0, p_price_halalas);
  ELSE
    UPDATE products SET name = 'كتيب: ' || v_b.title, status = v_status, updated_at = now() WHERE id = v_product;
    UPDATE product_offers SET price_halalas = CASE WHEN coalesce(p_price_halalas, 0) > 0 THEN p_price_halalas ELSE price_halalas END,
                              active = coalesce(p_price_halalas, 0) > 0
     WHERE product_id = v_product;
  END IF;
  INSERT INTO admin_log (actor_id, action, target, details)
  VALUES (v_coach, 'booklet.price', v_b.title, jsonb_build_object('price_halalas', p_price_halalas));
END $$;
REVOKE ALL ON FUNCTION app.coach_set_booklet_price(uuid, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.coach_set_booklet_price(uuid, int) TO nav_app;

-- الصفحة العامة: الكتيبات المعروضة للبيع (بدون مفتاح الملف)، مع حالة المستخدم الحالي إن وُجد
CREATE OR REPLACE FUNCTION app.booklets_for_sale()
RETURNS TABLE (id uuid, title text, description text, file_size int, sku text, price_halalas int, owned boolean, pending_order text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT b.id, b.title, b.description, b.file_size, o.sku, o.price_halalas,
         app.has_follow_program() OR app.bought_booklet(b.id),
         (SELECT x.order_no FROM orders x WHERE app.uid() IS NOT NULL AND x.user_id = app.uid() AND x.product_id = p.id
             AND x.status IN ('awaiting_quote', 'awaiting_payment', 'payment_review') ORDER BY x.created_at DESC LIMIT 1)
    FROM booklets b
    JOIN products p ON p.booklet_id = b.id AND p.status = 'published'
    JOIN product_offers o ON o.product_id = p.id AND o.active AND o.price_halalas > 0
   WHERE b.published
   ORDER BY b.sort, b.created_at
$$;
REVOKE ALL ON FUNCTION app.booklets_for_sale() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.booklets_for_sale() TO nav_app;

INSERT INTO schema_migrations (name) VALUES ('042_booklet_sales.sql');

-- ---------- 043_exercise_place.sql ----------
-- =====================================================================
-- تصنيف التمارين: «البيت» أو «النادي» فقط، وقالب/برنامج المتدرب له مكان.
-- - البيت: وزن الجسم، الدمبل والكيتلبل، الباند، البار والبنش، والأدوات الصغيرة (كرة سويسرية، TRX، عقلة).
-- - النادي: الأجهزة والكيبل والسميث، وأي تمرين باسمه جهاز (Machine, Cable, Leg Press, Pulldown, Sled…).
-- - برنامج «البيت»: بدائل المتدرب عند التبديل من تمارين البيت فقط، والمدربة تضيف من تمارين البيت فقط.
-- =====================================================================

-- المكان يُحسب من المعدات واسم التمرين (نفس منطق placeFor في src/lib/exercises.ts)
CREATE OR REPLACE FUNCTION app.exercise_place(p_equipment text, p_name text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN coalesce(p_name, '') ~* '\mband' THEN 'منزل'
    WHEN p_equipment IN ('جهاز', 'كيبل', 'سميث') THEN 'نادي'
    WHEN coalesce(p_name, '') ~* '(machine|cable|smith|leg press|pulldown|pull-down|pec deck|sled|hack squat|wall ball)' THEN 'نادي'
    ELSE 'منزل'
  END
$$;

-- القيم القديمة («بدون معدات» وغيرها) تُحوَّل تلقائياً، والمدربة تقدر تختار المكان يدوياً من صفحة التمرين
CREATE OR REPLACE FUNCTION app.exercise_place_norm() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.place IS NULL OR NEW.place NOT IN ('منزل', 'نادي') THEN
    NEW.place := app.exercise_place(NEW.equipment, NEW.name);
  END IF;
  RETURN NEW;
END $$;

ALTER TABLE exercises DROP CONSTRAINT IF EXISTS exercises_place_check;
UPDATE exercises SET place = app.exercise_place(equipment, name);
ALTER TABLE exercises ALTER COLUMN place SET NOT NULL;
ALTER TABLE exercises ADD CONSTRAINT exercises_place_check CHECK (place IN ('منزل', 'نادي'));
CREATE TRIGGER exercises_place_norm BEFORE INSERT OR UPDATE ON exercises FOR EACH ROW EXECUTE FUNCTION app.exercise_place_norm();

-- مكان القالب والبرنامج (البرنامج ينسخ مكان قالبه عند الإسناد)
ALTER TABLE program_templates ADD COLUMN place text NOT NULL DEFAULT 'نادي' CHECK (place IN ('منزل', 'نادي'));
UPDATE program_templates SET place = 'منزل' WHERE name ~* '(منزل|بيت|home)';
ALTER TABLE blocks ADD COLUMN place text NOT NULL DEFAULT 'نادي' CHECK (place IN ('منزل', 'نادي'));
UPDATE blocks b SET place = t.place FROM program_templates t WHERE t.id = b.template_id;
UPDATE blocks SET place = 'منزل' WHERE template_id IS NULL AND name ~* '(منزل|بيت|home)';

CREATE OR REPLACE FUNCTION app.block_place_from_template() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NEW.template_id IS NOT NULL THEN
    SELECT t.place INTO NEW.place FROM program_templates t WHERE t.id = NEW.template_id;
    NEW.place := coalesce(NEW.place, 'نادي');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER blocks_place_from_template BEFORE INSERT ON blocks FOR EACH ROW EXECUTE FUNCTION app.block_place_from_template();

-- بدائل المتدرب: برنامج البيت يعرض تمارين البيت فقط (اختيار المدربة الأصلي يبقى دائماً)
CREATE OR REPLACE FUNCTION app.swap_options(p_item uuid)
RETURNS TABLE (id uuid, name text, video_url text, is_coach_choice boolean, is_current boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_item block_items%ROWTYPE;
  v_base exercises%ROWTYPE;
  v_home boolean;
BEGIN
  SELECT * INTO v_item FROM block_items WHERE block_items.id = p_item;
  IF NOT FOUND OR NOT app.block_visible(app.item_block(p_item)) THEN RETURN; END IF;
  SELECT * INTO v_base FROM exercises WHERE exercises.id = v_item.coach_exercise_id;
  SELECT b.place = 'منزل' INTO v_home FROM block_days d JOIN blocks b ON b.id = d.block_id WHERE d.id = v_item.day_id;
  IF EXISTS (SELECT 1 FROM exercise_alternatives a WHERE a.exercise_id = v_base.id) THEN
    RETURN QUERY
      SELECT v_base.id, v_base.name, v_base.video_url, true, v_base.id = v_item.exercise_id
      UNION ALL
      SELECT e.id, e.name, e.video_url, false, e.id = v_item.exercise_id
        FROM (SELECT a.alt_id, a.position FROM exercise_alternatives a WHERE a.exercise_id = v_base.id ORDER BY a.position) x
        JOIN exercises e ON e.id = x.alt_id AND e.status = 'approved' AND (NOT coalesce(v_home, false) OR e.place = 'منزل');
  ELSE
    RETURN QUERY
      SELECT v_base.id, v_base.name, v_base.video_url, true, v_base.id = v_item.exercise_id
      UNION ALL
      (SELECT e.id, e.name, e.video_url, false, e.id = v_item.exercise_id
         FROM exercises e
        WHERE e.status = 'approved' AND e.id <> v_base.id AND e.primary_muscle = v_base.primary_muscle
          AND e.pattern IS NOT DISTINCT FROM v_base.pattern
          AND (NOT coalesce(v_home, false) OR e.place = 'منزل')
        ORDER BY e.name LIMIT 8);
  END IF;
END $$;

INSERT INTO schema_migrations (name) VALUES ('043_exercise_place.sql');

-- ---------- المحتوى المستورد من الموقع الحالي ----------
INSERT INTO public.exercises VALUES ('d5ed6197-5daa-463e-8024-9258344d973e', 'Forward Lunges', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', 'منزل', 'https://youtu.be/_DLAdo2Pvjs', 'تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness | ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, 'تقوية الورك ضمن نمط حركي وظيفي', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Distefano et al. 2009 — JOSPT (EMG) | Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin)', 'https://pubmed.ncbi.nlm.nih.gov/19574661/ | https://pubmed.ncbi.nlm.nih.gov/33344003/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4010faf7-0c1a-4134-ad5d-d6936c36b338', 'Single Leg Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'وزن الجسم', 'متقدم', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/136/single-leg-squat/', 'ضعف الألوية الكبرى / Gluteus Maximus Weakness | ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Single-leg Squat / سكوات رجل واحدة', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, 'تقوية باسطات ومبعدات الورك وتحكم أحادي الطرف', 'متقدمة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ يتطلب تحكماً جيداً بالركبة والحوض', 'Distefano et al. 2009 — JOSPT (EMG) | Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin)', 'https://pubmed.ncbi.nlm.nih.gov/19574661/ | https://pubmed.ncbi.nlm.nih.gov/33344003/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f802dc53-7dae-4c8e-88f9-205160433a9e', 'Hip Abduction', 'Abductors / مبعدات الفخذ', '{"Glutes / المؤخرة"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', NULL, 'مبتدئ', 'منزل', 'https://youtu.be/_ARUxqrII3Y?si=Jcz5uh2Uu-IdVCS1', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL, 'تقوية مبعدات الورك بمقاومة خارجية', 'مبكرة–متوسطة', 'منخفض–متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ الدليل يخص إبعاد الورك بمقاومة خارجية؛ يُتحقق من نوع الأداء', 'Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin)', 'https://pubmed.ncbi.nlm.nih.gov/33344003/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b9d4cbe9-d6a1-449b-a1b0-e20d2ffaa286', 'Side Step Up', 'Glutes / المؤخرة', '{"Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', 'منزل', 'https://youtube.com/shorts/xOwIRnI4VxA?si=SJOgODRmNGdfHPb4', 'يد فيها الوزن واليد الثانية سندها على الجدار', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية المتوسطة / Gluteus Medius Weakness | ضعف الألوية الصغرى / Gluteus Minimus Weakness', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, 'تقوية مبعدات الورك والتحكم بالحوض على رجل واحدة', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin) | Ganderton et al. — GMin/GMed EMG (RMIT University)', 'https://pubmed.ncbi.nlm.nih.gov/33344003/ | https://research-repository.rmit.edu.au/articles/journal_contribution/Gluteus_Minimus_and_Gluteus_Medius_Muscle_Activity_during_Common_Rehabilitation_Exercises_in_Healthy_Postmenopausal_Women/27572301', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('87a6c696-351a-4f72-b8a0-41b2105484d2', 'Glute Bridge', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', NULL, 'مبتدئ', 'منزل', 'https://www.youtube.com/watch?v=dtlGynVdHYM', 'ممكن تسويه بالسميث مشين او البار الحر ، اختر بوكس او بنش يكون بمستوى اكتافك الخلفية وانت جالس، لما ترفع البار فوق المفروض ركبك تكون بنفس مستوى القدم.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness | آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, 'تقوية بسط الورك وتحمّل الجذع', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Boren et al. 2011 — IJSPT (EMG) | JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/22034614/ | https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ca2595b5-10a1-4ceb-8081-ebbe4a9aaa58', 'DB Floor Glute Bridge', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/iOrJXNUH3to?si=JySX6JMhoP2vWEVa', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, 'تقوية بسط الورك بتحميل خارجي متدرج', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Boren et al. 2011 — IJSPT (EMG)', 'https://pubmed.ncbi.nlm.nih.gov/22034614/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('21f2a83a-dd84-4848-8e46-13dfe0b3421c', 'Single DB RDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/U3prDlAbJDw?si=MRSBcSIcf9M-WQBH', 'وقف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، انزل وادفع مؤخرتك لآخر شي تقدر عليه للخلف وكأنك بتلمس جدار خلفك مع انثناء بسيط بالركب', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, 'تقوية باسطات الورك وتحكم أحادي الطرف', 'متقدمة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ مع الحفاظ على وضع محايد للظهر', 'Distefano et al. 2009 — JOSPT (EMG)', 'https://pubmed.ncbi.nlm.nih.gov/19574661/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('684de4d9-5836-4c36-a909-bc137757c3f4', 'Upper Back Horizontal Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/TSWohpfMlso', 'ثبت نفسك بالكرسي، فتحة واسعة، الكيبل بمستوى أعلى صدرك، واسحب لما تنقبض الترابز.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Wide-grip Row / تجديف بقبضة واسعة', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', 'تقوية انكماش لوح الكتف والظهر العلوي', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moseley et al. 1992 — AJSM (EMG, scapular muscles)', 'https://pubmed.ncbi.nlm.nih.gov/1558238/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ea65bd24-467b-4e7b-9e4a-8dc651f45c65', 'Seated Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/0G3W83dFUeY', 'اسحب باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness | تحدب الظهر / Postural Thoracic Kyphosis', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', 'تقوية سحب وانكماش لوح الكتف', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moseley et al. 1992 — AJSM (EMG, scapular muscles) | Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://pubmed.ncbi.nlm.nih.gov/1558238/ | https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3292597b-b40e-41e3-8623-3ec3c13bd344', 'Band Seated Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/Jy-WCFAofBY?si=9gqVby588rk1zFi9', 'فتحة واسعة، واسحب لما تنقبض عضلات الظهر.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness | تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', 'تقوية سحب لوح الكتف بمقاومة منخفضة', 'مبكرة–متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moseley et al. 1992 — AJSM (EMG, scapular muscles) | Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://pubmed.ncbi.nlm.nih.gov/1558238/ | https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8dbbd81d-eb08-4026-be76-3466b51207b1', 'Chest Supported Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/DgHtyrQEMJ4?si=oTfTKVgD9j1H12wA', 'ثبت صدرك على الكرسي، فتحة واسعة، واسحب لما تنقبض عضلات الظهر.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', 'تقوية انكماش لوح الكتف مع دعم الجذع', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moseley et al. 1992 — AJSM (EMG, scapular muscles)', 'https://pubmed.ncbi.nlm.nih.gov/1558238/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ba8e7515-0ef4-4de9-b863-e07e3f5e18e9', 'Plank', 'Core / البطن والكور', '{"Shoulders / الأكتاف","Glutes / المؤخرة"}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'منزل', 'https://youtu.be/pvIjsG5Svck?si=cTP8ZyfMAJPfaEhw', 'لما ترتفع الاكتاف تكون فوق الكوع والرجل ممتدة بالكامل.', NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL, 'تحمّل عضلات الجذع', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5314ea3e-9589-40b3-905d-4848da5316b8', 'deadbug', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'منزل', 'https://youtu.be/g_BYB0R-4Ws?si=D4nwJri73eBqJRqL', NULL, 'اسم مشابه موجود في المكتبة (deadbug / dead bug) — تُراجَع قبل الحذف أو الدمج', 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'rejected', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL, 'التحكم الحركي وتحمّل الجذع', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('33e749fe-f621-4e0d-b573-ab725f6eecfb', 'Band Dead Bug', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'مطاط', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/iW_CtYtzbeU?si=Epequw3rqA3_TwTr', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL, 'التحكم الحركي وتحمّل الجذع بمقاومة', 'مبكرة–متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('55d441a0-1831-4766-842e-6e2c2846b1d5', 'Side Plank', 'Core / البطن والكور', '{"Abductors / مبعدات الفخذ","Shoulders / الأكتاف"}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'منزل', NULL, 'لما ترتفع الاكتاف تكون فوق الكوع والرجل ممتدة بالكامل.', NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain | ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Anti-Lateral Flexion / مقاومة الميلان الجانبي', 'Isometric Anti-Lateral Flexion / تثبيت الجذع ضد الميلان', NULL, 'تحمّل الجذع الجانبي وتنشيط مبعدات الورك', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.) | Boren et al. 2011 — IJSPT (EMG)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/ | https://pubmed.ncbi.nlm.nih.gov/22034614/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b360242e-c646-4e07-9ab9-190659071aab', 'McGill Big 3', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'منزل', 'https://youtu.be/jZylx81_kfg?si=_jP064GZIzvEvzyN', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Mixed (McGill Big 3) / مختلط', 'Isometric Trunk Stabilization / تثبيت الجذع', NULL, 'التحكم الحركي وتحمّل الجذع', 'مبكرة–متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('33322f12-75e7-4c77-808f-643544922ef1', 'Dead Bug', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'منزل', 'https://youtu.be/bxn9FBrt4-A', 'نحرك الرجلين ببطئ قليلا و بتحكم باستخدام عضلات البطن', 'اسم مشابه موجود في المكتبة (deadbug / dead bug) — تُراجَع قبل الحذف أو الدمج', 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL, 'التحكم الحركي وتحمّل الجذع', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8980ecae-5617-438f-b80b-b68936bfb7bb', 'Bird Dog', 'Core / البطن والكور', '{"Lower back / أسفل الظهر","Glutes / المؤخرة"}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/L91QMACdA6Q?si=KBnuQDcm9WcUXxxI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Anti-Rotation / مقاومة الدوران', 'Isometric Anti-Rotation / تثبيت الجذع ضد الدوران', NULL, 'التحكم الحركي وتحمّل الجذع', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f2fb9cc7-3322-4236-a6d4-7254637d4e01', 'High-Load Heel Raise (Towel Under Toes)', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', NULL, 'مبتدئ', 'منزل', NULL, 'رفع الكعب على رجل واحدة مع منشفة ملفوفة تحت أصابع القدم؛ صعود بطيء ثم ثبات قصير ثم نزول بطيء.', 'أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Rathleff et al. 2015 — Scand J Med Sci Sports (RCT)', 'https://doi.org/10.1111/sms.12313', 'اللفافة الأخمصية / Plantar Fasciopathy', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL, 'تحميل تدريجي للقدم والكاحل', 'متقدمة', 'مرتفع', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ يُبدأ بعد تحسّن الأعراض وبتدرّج', 'Rathleff et al. 2015 — Scand J Med Sci Sports (RCT) | JOSPT CPG 2023 — Heel Pain/Plantar Fasciitis (Koc et al.)', 'https://doi.org/10.1111/sms.12313 | https://pubmed.ncbi.nlm.nih.gov/38037331/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6137f5b4-0cc1-4b1c-9e2b-0e9bdb114b8a', 'Side Lunge', 'Adductors / الأفخاذ الداخلية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/50/side-lunge/', 'ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Lateral Lunge / لانج جانبي', 'Knee/Hip Extension + Hip Adduction / مد الركبة والورك + تقريب الورك', NULL, 'تقوية مبعدات الورك والتحكم بالحوض', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin)', 'https://pubmed.ncbi.nlm.nih.gov/33344003/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0fd85dca-eb00-48fb-9d8d-6af147bda7cd', 'Hip Hitch (Pelvic Drop)', 'Abductors / مبعدات الفخذ', '{}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Ganderton et al. — GMin/GMed EMG (RMIT University)', 'https://research-repository.rmit.edu.au/articles/journal_contribution/Gluteus_Minimus_and_Gluteus_Medius_Muscle_Activity_during_Common_Rehabilitation_Exercises_in_Healthy_Postmenopausal_Women/27572301', 'ضعف الألوية المتوسطة / Gluteus Medius Weakness | ضعف الألوية الصغرى / Gluteus Minimus Weakness', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Pelvic Drop (Stance Leg) / تثبيت الحوض برجل الارتكاز', 'Hip Abduction of Stance Leg / تبعيد ورك رجل الارتكاز', NULL, 'تنشيط وتقوية مبعدات الورك (الألوية المتوسطة والصغرى) والتحكم بالحوض', 'مبكرة–متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Ganderton et al. — GMin/GMed EMG (RMIT University) | Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin)', 'https://research-repository.rmit.edu.au/articles/journal_contribution/Gluteus_Minimus_and_Gluteus_Medius_Muscle_Activity_during_Common_Rehabilitation_Exercises_in_Healthy_Postmenopausal_Women/27572301 | https://pubmed.ncbi.nlm.nih.gov/33344003/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ccdf4687-a3f1-4b1c-a312-f3070282a0f0', 'Shoulder I-Y-T-W Series', 'Rotator cuffs / الكفة المدورة', '{"Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف', 'قوة', NULL, 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/237/shoulder-stability-mobility-series-i-y-t-w-formations/', 'تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture | ضعف العضلة المعينية / Rhomboid Weakness', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'I-Y-T-W / تمارين I-Y-T-W', 'Scapular Retraction/Depression + Arm Elevation / سحب وخفض لوح الكتف مع رفع الذراع', NULL, 'تقوية وتحكم عضلات لوح الكتف (الانكماش والتدوير)', 'مبكرة–متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis) | Sheikhhoseini et al. 2018 — JMPT (Systematic review, FHP) | Castelein et al. 2016 — Man Ther (EMG, rhomboid)', 'https://doi.org/10.1186/s12891-024-07224-4 | https://pubmed.ncbi.nlm.nih.gov/30107937/ | https://pubmed.ncbi.nlm.nih.gov/26409441/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('922a1283-452c-432f-8b79-8f210cb238e0', 'Supine Snow Angel (Wipers)', 'Rotator cuffs / الكفة المدورة', '{"Shoulders / الأكتاف","Core / البطن والكور"}', 'Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف', 'قوة', 'وزن الجسم', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/124/supine-snow-angel-wipers-exercise/', 'تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Snow Angel / الملاك', 'Shoulder Abduction/Adduction + Scapular Control / تبعيد وتقريب الكتف مع تحكم لوح الكتف', NULL, 'حركة الكتف والتحكم بلوح الكتف', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3dcd648f-24d7-46e3-90c6-fff8d9b8bbbf', 'Back Extension', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة","Hamstrings / الخلفية"}', 'Spinal Extension / بسط الجذع', 'كور', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/bs7S3RFyIYs?si=tDLl3OYuDBIwK4Fj', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «Functional Training»)', 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain | تحدب الظهر / Postural Thoracic Kyphosis', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Back Extension / بسط الظهر', 'Hip Extension + Spinal Extension / بسط الورك + بسط العمود الفقري', NULL, 'تقوية باسطات الظهر', 'متقدمة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ يُراجَع إذا زاد الألم مع الامتداد', 'JOSPT CPG 2021 — Low Back Pain (George et al.) | Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/ | https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('19a95d1c-0c4a-4575-a4a7-cb4ad93f0af4', 'Single Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/82IuSLk5zNc?si=FTMqZrmawQFRr8dN', 'اجلس وثبت ظهرك السفلي كويس، تأكد ان مسمار الارتفاع يكون بمستوى ركبتك، امسك المقابض لزيادة الثبات، إرفع الوزن اثبت ثانية فوق ثم انزل نزول كامل بتحكم.

ملاحظات مهمة:
• اعمل برجل واحدة بنفس ضبط الجهاز
• ثبّت الجذع ولا تتمايل لتعويض الوزن
• افرد الركبة ببطء وانزل بتحكم
• وزن أخف من العمل بالرجلين', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('86fef347-6455-43ec-9438-06eb63bbe33d', 'Supermans', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة","Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Spinal Extension / بسط الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/9/supermans/', 'تحدب الظهر / Postural Thoracic Kyphosis | آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Prone Extension / بسط على البطن', 'Spinal Extension / بسط العمود الفقري', NULL, 'تقوية باسطات الظهر والتحكم الوضعي', 'متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis) | JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://doi.org/10.1186/s12891-024-07224-4 | https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('29f6aa16-98f7-4750-8c75-ab831c6685e4', 'Standing Dorsi-Flexion (Calf Stretch)', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/152/standing-dorsi-flexion-calf-stretch/', 'اللفافة الأخمصية / Plantar Fasciopathy', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Calf Stretch / إطالة البطات', 'Ankle Dorsiflexion / ثني ظهري للكاحل', NULL, 'إطالة عضلات الساق', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2023 — Heel Pain/Plantar Fasciitis (Koc et al.)', 'https://pubmed.ncbi.nlm.nih.gov/38037331/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ba1a6b58-4053-4ad3-849d-09ed17d0469d', 'Cat-Cow', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/15/cat-cow/', 'تحدب الظهر / Postural Thoracic Kyphosis | آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Spinal Mobility / مرونة العمود الفقري', 'Spinal Flexion/Extension / ثني وبسط العمود الفقري', NULL, 'حركة العمود الفقري ضمن مدى حركة مريح', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis) | JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://doi.org/10.1186/s12891-024-07224-4 | https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f0f4a5d4-60ef-4a1b-8c38-6494dd356deb', 'Plantar Fascia-Specific Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'منزل', NULL, 'تُسحب أصابع القدم للخلف باليد حتى يُشعر بشد في باطن القدم، مع تحسّس اللفافة للتأكد من الشد.', 'أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Rathleff et al. 2015 — Scand J Med Sci Sports (RCT)', 'https://doi.org/10.1111/sms.12313', 'اللفافة الأخمصية / Plantar Fasciopathy', 'review', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Plantar Fascia Stretch / إطالة اللفافة الأخمصية', 'Toe Extension + Ankle Dorsiflexion / مد أصابع القدم + ثني ظهري', NULL, 'إطالة اللفافة الأخمصية', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2023 — Heel Pain/Plantar Fasciitis (Koc et al.) | Rathleff et al. 2015 — Scand J Med Sci Sports (RCT)', 'https://pubmed.ncbi.nlm.nih.gov/38037331/ | https://doi.org/10.1111/sms.12313', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('816474e2-5713-4a5f-a3c0-13dbfff4e67f', 'Crab Reach (Thoracic Bridge)', 'Functional / التمارين الوظيفية', '{"Glutes / المؤخرة","Shoulders / الأكتاف"}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'منزل', 'https://www.youtube.com/watch?v=fgsUe3Lc3hI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'تحدب الظهر / Postural Thoracic Kyphosis', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Thoracic Bridge / جسر صدري', 'Hip Extension + Thoracic Rotation / بسط الورك + دوران الصدر', NULL, 'حركة الامتداد والدوران الصدري', 'متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ يتطلب تحمّلاً جيداً للرسغ والكتف', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b60f6efb-d3cf-4603-ac9b-186bbf1fc7a4', 'Prone Swimmer', 'Functional / التمارين الوظيفية', '{"Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Shoulder Rear Pull / سحب خلفي للكتف', 'قوة', 'وزن الجسم', 'مبتدئ', 'منزل', 'https://www.youtube.com/watch?v=M8a1cgnhyqk', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Prone Swimmer / سبّاح على البطن', 'Shoulder Extension/Abduction + Rotation / مد وتبعيد الكتف مع الدوران', NULL, 'تحمّل عضلات لوح الكتف والامتداد الصدري', 'متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('545f60f2-b3e7-41e9-bd3d-9b5c9fbaa430', 'Isometric Wrist Extension', 'Forearms / الساعد', '{}', 'Wrist Extension / مد الرسغ', 'قوة', NULL, 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'مرفق التنس / Lateral Elbow Tendinopathy', 'review', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Isometric / ثابت', 'Wrist Extension / مد الرسغ', NULL, 'تحميل تدريجي لباسطات الرسغ (انقباض ثابت)', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ ضمن ألم مقبول لا يتزايد بعد التمرين', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('af7a2868-1c77-4989-80a3-6769d025a4ce', 'Eccentric Wrist Extension', 'Forearms / الساعد', '{}', 'Wrist Extension / مد الرسغ', 'قوة', NULL, 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'مرفق التنس / Lateral Elbow Tendinopathy', 'review', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Eccentric / لامركزي', 'Wrist Extension / مد الرسغ', NULL, 'تحميل تدريجي لباسطات الرسغ (لامركزي)', 'متوسطة', 'منخفض–متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ ضمن ألم مقبول لا يتزايد بعد التمرين', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ae4e3e66-8b6d-4074-b80b-b1cc72198e65', 'Chin Tuck (Deep Neck Flexor)', 'Neck / الرقبة', '{}', 'Neck Flexion (Deep Flexors) / ثني الرقبة العميق', 'إحماء/تفعيل', 'وزن الجسم', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Sheikhhoseini et al. 2018 — JMPT (Systematic review, FHP)', 'https://pubmed.ncbi.nlm.nih.gov/30107937/', 'وضعية الرأس للأمام / Forward Head Posture', 'review', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Chin Tuck / سحب الذقن', 'Upper Cervical Flexion + Retraction / ثني علوي للرقبة مع سحبها للخلف', NULL, 'تحكم عضلات الرقبة العميقة ووضعية الرأس', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ يُوقف مع دوخة أو ألم/تنميل يمتد للذراع', 'Sheikhhoseini et al. 2018 — JMPT (Systematic review, FHP) | Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://pubmed.ncbi.nlm.nih.gov/30107937/ | https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('254a9a3c-f74e-443c-b2ce-4628a13acb38', 'Terminal Knee Extension (Band)', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'مطاط', 'مبتدئ', 'منزل', NULL, 'اربط الشريط المطاطي خلف الركبة وقف بثبات. من ركبة مثنية قليلاً، افرد الركبة بالكامل ببطء وشد عضلة الفخذ الأمامية ثانية، ثم ارجع ببطء. 2–3 مجموعات × 12–15 تكرار.', NULL, 'مصدر خارجي موثوق', 'JOSPT CPG 2019 — Patellofemoral Pain (Willy et al.)', 'https://doi.org/10.2519/jospt.2019.0302', 'ألم الرضفة والفخذ (الركبة الأمامية) / Patellofemoral Pain', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Knee Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, 'تقوية الفخذ الأمامي في مدى آمن للركبة', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي. يكون الألم أثناء التمرين خفيفاً ومقبولاً (حتى 3 من 10) ويهدأ خلال 24 ساعة، وإذا زاد الألم أو ظهر تورم أو إحساس بقفل أو خذلان في الركبة يتوقف التمرين وتُراجَع أخصائي.', 'Willy et al. 2019 — JOSPT (Patellofemoral Pain CPG) | Lack et al. 2015 — Br J Sports Med (Proximal muscle rehabilitation for PFP, meta-analysis)', 'https://doi.org/10.2519/jospt.2019.0302 | https://bjsm.bmj.com/content/49/21/1365', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5ccd2f8b-0e8a-485d-bdb0-1d53aa9118dd', 'Mini Squat (Partial Range)', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'وزن الجسم', 'مبتدئ', 'منزل', NULL, 'انزل نزولاً جزئياً فقط (حتى نحو 45° من ثني الركبة) مع ثبات الركبة فوق القدم وعدم انهيارها للداخل، ثم اصعد. 2–3 مجموعات × 10–15 تكرار. زد المدى تدريجياً حسب الراحة.', NULL, 'مصدر خارجي موثوق', 'JOSPT CPG 2019 — Patellofemoral Pain (Willy et al.)', 'https://doi.org/10.2519/jospt.2019.0302', 'ألم الرضفة والفخذ (الركبة الأمامية) / Patellofemoral Pain', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, 'تقوية الفخذ الأمامي والورك بحمل خفيف على مفصل الرضفة', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي. يكون الألم أثناء التمرين خفيفاً ومقبولاً (حتى 3 من 10) ويهدأ خلال 24 ساعة، وإذا زاد الألم أو ظهر تورم أو إحساس بقفل أو خذلان في الركبة يتوقف التمرين وتُراجَع أخصائي.', 'Willy et al. 2019 — JOSPT (Patellofemoral Pain CPG) | Lack et al. 2015 — Br J Sports Med (Proximal muscle rehabilitation for PFP, meta-analysis)', 'https://doi.org/10.2519/jospt.2019.0302 | https://bjsm.bmj.com/content/49/21/1365', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('637f2f36-c59b-4812-a4ad-fff17ff20be9', 'Lateral Step-Down (Slow Eccentric)', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'وزن الجسم', 'متوسط', 'منزل', NULL, 'قف على حافة درجة بقدم واحدة. انزل بالقدم الأخرى ببطء (3 ثوانٍ) مع إبقاء الحوض مستوياً والركبة فوق أصابع القدم، المس الأرض بخفة ثم اصعد. 2–3 مجموعات × 8–12 تكرار لكل رجل.', NULL, 'مصدر خارجي موثوق', 'JOSPT CPG 2019 — Patellofemoral Pain (Willy et al.)', 'https://doi.org/10.2519/jospt.2019.0302', 'ألم الرضفة والفخذ (الركبة الأمامية) / Patellofemoral Pain', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Step-up / صعود الدرجة', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, 'تحكم الورك والركبة أثناء الحمل على رجل واحدة', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي. يكون الألم أثناء التمرين خفيفاً ومقبولاً (حتى 3 من 10) ويهدأ خلال 24 ساعة، وإذا زاد الألم أو ظهر تورم أو إحساس بقفل أو خذلان في الركبة يتوقف التمرين وتُراجَع أخصائي.', 'Willy et al. 2019 — JOSPT (Patellofemoral Pain CPG) | Lack et al. 2015 — Br J Sports Med (Proximal muscle rehabilitation for PFP, meta-analysis)', 'https://doi.org/10.2519/jospt.2019.0302 | https://bjsm.bmj.com/content/49/21/1365', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b7d57c4d-be28-4ffd-8e36-364b41756dec', 'Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/gtZ4AwZVtMI', 'اجلس وثبت ظهرك السفلي كويس، تأكد ان مسمار الارتفاع يكون بمستوى ركبتك، امسك المقابض لزيادة الثبات، إرفع الوزن اثبت ثانية فوق ثم انزل نزول كامل بتحكم.

ملاحظات مهمة:
• اضبط مسند الظهر لتكون الركبة عند محور الجهاز
• افرد الركبة بتحكم وثبّت لحظة في الأعلى
• نزول بطيء 2–3 ثوانٍ دون ارتداد الوزن
• تجنّب الأوزان الثقيلة جداً عند ألم الركبة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4e5b746a-8036-4ef3-b136-1a02e6bbb85a', 'Clamshell', 'Glutes / المؤخرة', '{"Abductors / مبعدات الفخذ"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'منزل', NULL, 'استلقِ على جنبك وركبتاك مثنيتان 45° وقدماك ملتصقتان. افتح الركبة العليا كالصدفة دون تحريك الحوض للخلف، ثم أغلقها ببطء. 2–3 مجموعات × 12–20 تكرار. يمكن إضافة شريط مطاطي للتدرج.', NULL, 'مصدر خارجي موثوق', 'BJSM 2015 — Proximal muscle rehabilitation for PFP (Lack et al.)', 'https://bjsm.bmj.com/content/49/21/1365', 'ألم الرضفة والفخذ (الركبة الأمامية) / Patellofemoral Pain', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Hip External Rotation / دوران الورك للخارج', 'Hip External Rotation / دوران الورك للخارج', NULL, 'تقوية دوران الورك الخارجي والألوية الوسطى', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي. يكون الألم أثناء التمرين خفيفاً ومقبولاً (حتى 3 من 10) ويهدأ خلال 24 ساعة، وإذا زاد الألم أو ظهر تورم أو إحساس بقفل أو خذلان في الركبة يتوقف التمرين وتُراجَع أخصائي.', 'Willy et al. 2019 — JOSPT (Patellofemoral Pain CPG) | Lack et al. 2015 — Br J Sports Med (Proximal muscle rehabilitation for PFP, meta-analysis)', 'https://doi.org/10.2519/jospt.2019.0302 | https://bjsm.bmj.com/content/49/21/1365', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ff1fe014-262b-40df-a091-38d2ffc29982', 'Wall Sit (Isometric Quad Hold)', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'وزن الجسم', 'مبتدئ', 'منزل', NULL, 'ضع ظهرك على الحائط وانزل حتى ركبتين مثنيتين بزاوية مريحة (نحو 60–90°) وثبّت. 4–5 مجموعات × 30–45 ثانية مع راحة دقيقتين. يُستخدم عند ألم الوتر لتخفيف الألم قبل التمارين الأخرى.', NULL, 'مصدر خارجي موثوق', 'Br J Sports Med 2015 — Isometric exercise in patellar tendinopathy (Rio et al.)', 'https://pubmed.ncbi.nlm.nih.gov/25979840/', 'اعتلال وتر الرضفة / Patellar Tendinopathy | ألم الرضفة والفخذ (الركبة الأمامية) / Patellofemoral Pain', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Isometric Knee Extension / انقباض ثابت لمد الركبة', NULL, 'تخفيف الألم وتحميل آمن لوتر الرضفة بالانقباض الثابت', 'مبكرة', 'منخفض–متوسط', 'يُستخدم بعد تقييم فردي. يكون الألم أثناء التمرين خفيفاً ومقبولاً (حتى 3 من 10) ويهدأ خلال 24 ساعة، وإذا زاد الألم أو ظهر تورم أو إحساس بقفل أو خذلان في الركبة يتوقف التمرين وتُراجَع أخصائي.', 'Rio et al. 2015 — Br J Sports Med (Isometric exercise and analgesia in patellar tendinopathy) | Willy et al. 2019 — JOSPT (Patellofemoral Pain CPG) | Lack et al. 2015 — Br J Sports Med (Proximal muscle rehabilitation for PFP, meta-analysis)', 'https://pubmed.ncbi.nlm.nih.gov/25979840/ | https://doi.org/10.2519/jospt.2019.0302 | https://bjsm.bmj.com/content/49/21/1365', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0585175c-4ac5-425b-be67-01c82a85db68', 'Isometric Leg Extension Hold (Machine)', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'جهاز', 'متوسط', 'نادي', NULL, 'اجلس على جهاز فرد الركبة وثبّت الزاوية عند نحو 60° من ثني الركبة. ادفع بجهد متوسط–عالٍ (نحو 70% من أقصى قوة) وثبّت 45 ثانية، 5 مجموعات مع راحة دقيقتين. بروتوكول الدراسة المرجعية.', NULL, 'مصدر خارجي موثوق', 'Br J Sports Med 2015 — Isometric exercise in patellar tendinopathy (Rio et al.)', 'https://pubmed.ncbi.nlm.nih.gov/25979840/', 'اعتلال وتر الرضفة / Patellar Tendinopathy', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Isometric / ثابت', 'Isometric Knee Extension / انقباض ثابت لمد الركبة', NULL, 'تخفيف ألم الوتر وتقليل التثبيط العضلي', 'مبكرة', 'متوسط', 'يُستخدم بعد تقييم فردي. يكون الألم أثناء التمرين خفيفاً ومقبولاً (حتى 3 من 10) ويهدأ خلال 24 ساعة، وإذا زاد الألم أو ظهر تورم أو إحساس بقفل أو خذلان في الركبة يتوقف التمرين وتُراجَع أخصائي.', 'Rio et al. 2015 — Br J Sports Med (Isometric exercise and analgesia in patellar tendinopathy)', 'https://pubmed.ncbi.nlm.nih.gov/25979840/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8058dc75-3621-4a45-8f94-d3d3d511b749', 'Slow Leg Press (Heavy Slow Resistance)', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'متوسط', 'نادي', NULL, 'ضغط الأرجل بحركة بطيئة جداً: 3 ثوانٍ للدفع و3 ثوانٍ للنزول بدون توقف. تزيد الأوزان وتقل التكرارات تدريجياً (من 15 إلى 6) خلال 12 أسبوعاً، 3 أيام في الأسبوع بالتناوب مع تمرين سكوات وهاك سكوات.', NULL, 'مصدر خارجي موثوق', 'Scand J Med Sci Sports 2009 — HSR in patellar tendinopathy (Kongsgaard et al.)', 'https://pubmed.ncbi.nlm.nih.gov/19793213/', 'اعتلال وتر الرضفة / Patellar Tendinopathy', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Leg Press / ضغط الأرجل', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, 'تحميل تدريجي لوتر الرضفة بمقاومة عالية وبطيئة', 'متوسطة–متقدمة', 'مرتفع', 'يُستخدم بعد تقييم فردي. يكون الألم أثناء التمرين خفيفاً ومقبولاً (حتى 3 من 10) ويهدأ خلال 24 ساعة، وإذا زاد الألم أو ظهر تورم أو إحساس بقفل أو خذلان في الركبة يتوقف التمرين وتُراجَع أخصائي.', 'Kongsgaard et al. 2009 — Scand J Med Sci Sports (Heavy slow resistance vs eccentric decline squat vs corticosteroid in patellar tendinopathy)', 'https://pubmed.ncbi.nlm.nih.gov/19793213/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2e5b49f6-275b-4243-b937-465ab70d4768', 'Modified Curl-Up (McGill)', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'منزل', NULL, 'استلقِ على ظهرك، ركبة مثنية والأخرى مفرودة، ويداك تحت أسفل الظهر للحفاظ على انحنائه الطبيعي. ارفع الرأس والكتفين قليلاً فقط (دون ثني أسفل الظهر) وثبّت 7–10 ثوانٍ، ثم ارجع. 3 جولات (تنازلية 6-4-2) حسب برنامج ماكجيل.', NULL, 'مصدر خارجي موثوق', 'McGill 2010 — Core training (Strength Cond J)', NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL, 'تقوية عضلات البطن بأقل حمل على العمود الفقري', 'مبكرة', 'منخفض', 'لا يُجرى مع ألم حاد أو ألم ينتشر للساق أو تنميل. يتوقف التمرين إذا زاد الألم، وتُراجَع أخصائي.', 'NICE NG59 (2020) — Low back pain and sciatica in over 16s | Hayden et al. 2021 — Cochrane (Exercise therapy for chronic low back pain) | McGill 2010 — Strength Cond J (Core training)', 'https://www.nice.org.uk/guidance/ng59 | https://doi.org/10.1002/14651858.CD009790.pub2', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('96a54855-a6b4-4002-afb4-00fe31944168', 'Supine Pelvic Tilt', 'Core / البطن والكور', '{"Glutes / المؤخرة"}', 'Core Activation & Breathing / تفعيل الجذع والتنفس', 'كور', 'وزن الجسم', 'مبتدئ', 'منزل', NULL, 'استلقِ على ظهرك وركبتاك مثنيتان. اضغط أسفل الظهر برفق نحو الأرض بشد البطن والألوية قليلاً، ثبّت 5 ثوانٍ مع تنفس طبيعي ثم استرخِ. 2 مجموعات × 10 تكرارات.', NULL, 'مصدر خارجي موثوق', 'NICE NG59 — Low back pain and sciatica in over 16s', 'https://www.nice.org.uk/guidance/ng59', 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Pelvic Control / التحكم بالحوض', 'Posterior Pelvic Tilt / إمالة الحوض للخلف', NULL, 'تفعيل الجذع وتحسين وعي الحوض في المراحل الأولى', 'مبكرة', 'منخفض', 'تمرين تمهيدي خفيف. لا تدفع بقوة، ويتوقف عند زيادة الألم.', 'NICE NG59 (2020) | Hayden et al. 2021 — Cochrane (دليل عام على التمارين، ولا توجد تجربة تعزل هذا التمرين بعينه)', 'https://www.nice.org.uk/guidance/ng59 | https://doi.org/10.1002/14651858.CD009790.pub2', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9f44ad8d-ea3a-4ad4-a9cf-a3f631186af8', 'Tyler Twist (FlexBar)', 'Forearms / الساعد', '{}', 'Wrist Extension / مد الرسغ', 'قوة', 'أخرى', 'متوسط', 'منزل', NULL, 'أمسك قضيب FlexBar عمودياً: اليد المصابة من الأعلى والسليمة من الأسفل، والرسغ المصاب مفرود للخلف. لفّ القضيب باليد السليمة (التواء)، ثم مدّ الذراعين أمامك وأرخِ الالتواء ببطء بالرسغ المصاب حتى يستقيم (حركة لامركزية بطيئة). 3 مجموعات × 15 تكرار يومياً، وتزيد مقاومة القضيب تدريجياً. هذا الوصف مبسّط، فيُراجَع مع أخصائي عند أول استخدام.', NULL, 'مصدر خارجي موثوق', 'J Shoulder Elbow Surg 2010 — Tyler Twist (Tyler et al.)', NULL, 'مرفق التنس / Lateral Elbow Tendinopathy', 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Eccentric / لامركزي', 'Wrist Extension / مد الرسغ', NULL, 'تقوية لامركزية لباسطات الرسغ لألم مرفق التنس', 'مبكرة–متوسطة', 'منخفض–متوسط', 'يكون الألم أثناء التمرين خفيفاً ومقبولاً. إذا زاد الألم أو ظهر تنميل أو ضعف في اليد يتوقف التمرين وتُراجَع أخصائي.', 'Tyler et al. 2010 — J Shoulder Elbow Surg 19(6):917–922 (Tyler Twist with FlexBar)', NULL, 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1cd0378e-24da-49cb-bfd2-3e21fc474496', 'Nordic Hamstring Curl', 'Hamstrings / الخلفية', '{}', 'Knee Flexion / ثني الركبة', 'قوة', 'وزن الجسم', 'متقدم', 'منزل', 'https://youtu.be/Lgibr8od0yA?si=nfRetEkDRk55Bu0a', 'ملاحظات مهمة:
• ثبّت الكعبين جيداً وانزل ببطء بجسم مستقيم من الركبة للرأس
• استخدم اليدين لتخفيف الحمل في البداية
• عُد بدفع خفيف باليدين
• ابدأ بمدى قصير لتجنب شد الخلفية', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Nordic (Eccentric) / نوردك (لامركزي)', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4fd156a3-a978-4640-82d3-a85ea7965eb4', 'DB Floor Triceps Extensions', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/dpFav9Ve4rY?si=ZBdKK8VF4aPMpi3v', 'ملاحظات مهمة:
• استلقِ على الأرض والمرفقان للأعلى
• انزل نحو الجبهة أو خلف الرأس بتحكم
• افرد المرفقين دون تحريك العضد
• وزن خفيف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Lying Extension / مد مستلقٍ', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('257f1a6f-5e51-4e41-844b-8c67b7d7b303', 'Chest Supported Machine Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/BZrdEAiR2Xs?si=WhKaSGhR0gKeeies', 'ملاحظات مهمة:
• اضبط المقعد ليكون الصدر على المسند والذراعان ممدودتان
• اسحب المقبضين وضم لوحي الكتف
• لا ترفع الكتفين
• عودة بتحكم', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0c3353e7-5cc0-498c-9378-b02b6c3ddda6', 'Box Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'بار', 'متوسط', 'منزل', 'https://youtube.com/shorts/9uhEh9gpwUU?si=xaTY7AJiCeQfa3by', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل.

ملاحظات مهمة:
• اجلس للخلف على الصندوق بتحكم وجذع مرفوع ولا ترتمِ عليه
• توقف لحظة دون إرخاء العضلات ثم ادفع الأرض بالكعبين
• الصندوق بارتفاع يجعل الفخذ موازياً للأرض تقريباً
• الخطأ الشائع: تقوّس الظهر عند الانطلاق من الصندوق', 'تعليمات بديلة في المصدر (صف 13): ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل، انزل واثبت على البوكس ثانية وارفع.', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('bbd65866-6cf4-4822-afaf-a511bd30ad19', 'Back Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'بار', 'متوسط', 'منزل', 'https://youtu.be/bEv6CCg2BC8', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل.

ملاحظات مهمة:
• البار على أعلى الظهر (عضلة الترابيس) لا على الرقبة، والقبضة ثابتة، والصدر مرفوع
• القدمان بعرض الكتفين وأصابعهما للخارج قليلاً، والركبتان تتبعان اتجاه الأصابع
• انزل بعمق يسمح به مدى الورك والكاحل مع شد البطن، وتجنّب انحناء أسفل الظهر في القاع
• الخطأ الشائع: رفع الكعبين أو انهيار الركبتين للداخل', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5a0ccb0d-b9df-4ba2-a32f-26da46e744e5', 'Hack Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/0tn5K9NlCfo', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.

ملاحظات مهمة:
• ظهر وأرداف ملتصقان بالمسند طوال الحركة
• القدمان بعرض الكتفين على منتصف المنصة، وإنزالهما للأسفل يزيد تركيز الفخذ الأمامي
• انزل حتى مدى مريح للركبة ثم ادفع بكامل القدم
• لا تفرد الركبتين بقوة في الأعلى', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Machine Squat / سكوات بالجهاز', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('475de381-73a9-4722-8a6b-1b0094ec0a56', 'Mid Leg Press', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/s9-zeWzPUmA', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.

ملاحظات مهمة:
• ضع القدمين في منتصف المنصة بعرض الكتفين
• أنزل المنصة حتى ثني الركبة نحو 90° دون أن يرتفع الحوض عن المقعد
• ادفع بكامل القدم، ولا تغلق الركبتين بقوة في الأعلى
• لا تضع اليدين على الركبتين للمساعدة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Leg Press / ضغط الأرجل', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c608fd63-f37b-4181-a02f-a1846809b393', 'Quads Leg Press', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/A218isnErfM', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي، ثبت القدمين أسفل اللوح لاستهداف أكبر للكوادز.

ملاحظات مهمة:
• القدمان منخفضتان على المنصة وقريبتان من بعض قليلاً لزيادة تركيز الفخذ الأمامي
• الركبتان تتجهان فوق أصابع القدم أثناء النزول
• نزول بطيء بتحكم ثم دفع بدون ارتداد
• احذر ارتفاع الحوض وتقوّس أسفل الظهر عند النزول العميق', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Leg Press / ضغط الأرجل', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d863a32c-694d-4190-b844-f8242ee7db4d', 'Deficit Goblet Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/9719SO5zvpU?si=whohbunAsXkH3j6f', 'وقف باتساع اكتافك تقريبًا، ادفع ركبك للامام وانزل، انزل لأقصى حد تقدر عليه بدون ما يتقوس ظهرك السفلي.

ملاحظات مهمة:
• ثبّت الدمبل أمام الصدر والمرفقان للأسفل
• القدمان على منصة صغيرة (ديفيزيت) تزيد مدى الحركة، فانزل بتحكم ولا تتجاوز مدى كاحلك
• حافظ على الجذع مرفوعاً والكعبين ثابتين
• الخطأ الشائع: ارتداد القاع وانحناء الظهر', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ae3ba584-acf3-49a1-ac72-0ee6ed51f66c', 'Front Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'بار', 'متوسط', 'منزل', NULL, 'ثبت البار على الأكتاف، ادفع ركبك للامام وانزل.

ملاحظات مهمة:
• البار على مقدمة الكتفين مع مرفقين عاليين أمام الجسم
• الجذع مستقيم أكثر من السكوات الخلفي والركبتان للأمام
• شد البطن وانزل بتحكم
• الخطأ الشائع: سقوط المرفقين فيسقط البار للأمام', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c158a260-f51e-4615-a22f-babe5a4c93ae', 'V Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://www.youtube.com/watch?v=u_GSjH58s0g', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.

ملاحظات مهمة:
• ثبّت الظهر والأرداف على الجهاز واجعل القدمين على المنصة بعرض الكتفين
• انزل بتحكم حتى مدى مريح وادفع بالكعبين
• لا تفرد الركبتين بالكامل بعنف
• ابقِ الركبتين باتجاه أصابع القدم', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Machine Squat / سكوات بالجهاز', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('94635f06-5bc4-4fc0-8c2d-9e7408fc7002', 'Resistance Band Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/6rE0IYlMPZA?si=goqtRTlR_W4HSGBN', 'ثبت الباند علي جوانب اكتافك، ادفع ركبك للأمام وإنزل.

ملاحظات مهمة:
• ثبّت الشريط تحت القدمين ومرره على الكتفين أو أمام الصدر
• الشد يزيد في أعلى الحركة، فادفع بتحكم ولا تقفز
• ركبتان باتجاه الأصابع وصدر مرفوع
• تأكد من سلامة الشريط وثباته', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('470e98d3-e4db-4c2a-abfa-13cdcab1f5f8', 'Squat Smith Machine', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/oBwhrRcNWyM', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل.

ملاحظات مهمة:
• ضع القدمين أمام خط البار قليلاً ليتمكن الجذع من البقاء مستقيماً
• انزل حتى مدى مريح مع ثبات الكعبين
• اضبط حوامل الأمان قبل البدء
• الخطأ الشائع: وضع القدمين تحت البار تماماً فيضغط على الركبتين', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Machine Squat / سكوات بالجهاز', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5870ec67-f436-469d-bc6f-4b69162db8a9', 'Single Leg Press', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/ZYDTJaAM-gE', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.

ملاحظات مهمة:
• ضع قدماً واحدة على منتصف المنصة والأخرى بعيداً عنها
• لا يرتفع الحوض عن المقعد ولا ينحرف للجانب
• انزل حتى 90° تقريباً بتحكم
• لا تفرد الركبة بقوة في الأعلى', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Single-leg Press / ضغط رجل واحدة', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('607cb44a-4431-4005-91ad-8c20f007ec56', 'Drop Lunges', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', 'منزل', 'https://youtu.be/WH8lteLrMIs?si=61QSVA7iw_Z6Zr3p', 'تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.

ملاحظات مهمة:
• ارجع بقدم خلفاً بقوس خلف القدم الثابتة وانزل للأسفل بتحكم
• الجذع مستقيم والركبة الأمامية فوق القدم
• ادفع بكعب الرجل الأمامية للعودة
• ابدأ بوزن خفيف لإتقان التوازن', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d3ec1ff6-2660-4c60-9a8f-1b8e29630963', 'Beginner Lunges', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'وزن الجسم', 'مبتدئ', 'منزل', 'https://youtu.be/QOVaHwm-Q6U', 'تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.

ملاحظات مهمة:
• خطوة طويلة بما يكفي لتبقى الركبة الأمامية فوق القدم
• انزل عمودياً حتى تقترب الركبة الخلفية من الأرض
• ادفع بكعب الرجل الأمامية
• يمكنك الإمساك بسند للتوازن في البداية', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1c7b6f58-68a0-48e1-b54f-b9980ce94c96', 'Standing Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', NULL, 'مبتدئ', 'منزل', 'https://youtu.be/rDRwAURNbzU', 'الحركة كلها بثني ومد الركبة

ملاحظات مهمة:
• قف بثبات وأمسك سنداً
• اثنِ الركبة بتحكم والجذع ثابت
• لا تتأرجح بالورك
• نزول بطيء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a6229455-c50c-4d3a-af50-56a54127703d', 'Supported BSS', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'مبتدئ', 'منزل', 'https://youtube.com/shorts/poBie3TTeGE?si=QSiMUYtcHhrmg8mx', 'وقف عند البنش او الستيب، ارفع رجلك وثبت اصابع قدمك على البنش، خذ خطوة وحدة للأمام برجلك الثانية ثم ابدأ التمرين، تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.

ملاحظات مهمة:
• ضع القدم الخلفية على مقعد واستند بيدك على ثابت
• انزل عمودياً والركبة الأمامية فوق القدم
• الجذع مائل قليلاً للأمام يزيد تفعيل الألوية
• لا تدفع بالقدم الخلفية', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Split Squat / سبليت سكوات', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2a591130-36e5-44ea-817d-28c433989b38', 'Supported Reverse Lunge', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'مبتدئ', 'منزل', 'https://youtu.be/WH8lteLrMIs?si=M9s9a7qOVvvyDm82', 'ملاحظات مهمة:
• ابقَ ممسكاً بسند خفيف للتوازن، وخطوة للخلف ثم نزول عمودي
• ادفع بكعب الرجل الأمامية للعودة
• حوض مستوٍ وجذع مستقيم
• الخطأ الشائع: الاتكاء على السند بدل الرجل', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('84ba0a07-b6d4-40a5-bd8d-c6800fb10fd5', 'Smith Machine Reverse Lunge', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/zAVYcwnlxrQ?si=M5HL4sG-bsYBFyDQ', 'استخدم ارتفاع بسيط مثل الستيب ، ارفع نفسك بالضغط علي الرجل المرفوعة بتحكم بدون قفز.

ملاحظات مهمة:
• اضبط البار بحيث تكون القدم الأمامية تحته أو أمامه قليلاً
• خطوة للخلف ونزول بتحكم
• ادفع بكعب الرجل الأمامية
• تأكد من حوامل الأمان', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8307a5df-f598-4264-b357-76c390ae3504', 'Cable Glutes Step Ups', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', NULL, 'ملاحظات مهمة:
• ثبّت الكيبل مناسباً للحزام أو اليدين
• اصعد بتحكم والجذع مستقيم مع إمالة بسيطة
• شد الكيبل لا يسحبك للخلف
• نزول بطيء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c04f4b86-4961-4cfd-bbae-da2cd9e52372', 'Band Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/hs7D3gDw3UM', 'اجلس وثبت ظهرك السفلي كويس وامسك الكرسي للثبات، اثبت ثانية فوق ثم انزل نزول كامل بتحكم.

ملاحظات مهمة:
• ثبّت الشريط خلف الكاحل وثبّت الطرف الآخر أمامك
• افرد الركبة ببطء ثم انزل بتحكم
• الشد يزداد في الأعلى فاضغط الفخذ لحظة
• تأكد من ثبات الشريط', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f5d34dbb-0e9c-4efa-8619-7536c5d47a35', 'Sissy Squat', 'Quadriceps / الأمامية', '{"Adductors / الأفخاذ الداخلية"}', 'Knee Extension / مد الركبة', 'قوة', 'وزن الجسم', 'متوسط', 'منزل', 'https://youtu.be/yONKTprKCDA', 'الورك ثابت طول الجولة والحركة كلها من مفصل الركبة، اذا توازنك يخرب عليك ادبل الوزن بيد واليد الثانية امسك فيها جدار او عصى

ملاحظات مهمة:
• ابدأ بسند وبمدى قصير فالتمرين متقدم على الركبة
• مِل بالجذع والركبتين للأمام وكعباك مرفوعان بخط واحد من الركبة للكتف
• انزل ببطء وارجع بتحكم
• تجنّب التمرين مع ألم الركبة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Sissy Squat / سيسي سكوات', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c9ad1f47-c29b-43bf-bd95-967336bdb165', 'Cable Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/ebjD98gZd8E', 'اجلس وثبت ظهرك السفلي كويس وامسك الكرسي للثبات، اثبت ثانية فوق ثم انزل نزول كامل بتحكم.

ملاحظات مهمة:
• ثبّت الكيبل على الكاحل واجلس بثبات
• افرد الركبة بتحكم ولا تتأرجح بالجذع
• شد الكيبل مستمر طوال الحركة
• نزول بطيء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('de7c5c4c-e640-4d3a-bdee-791c40e664f5', 'Standing Leg Extension', 'Quadriceps / الأمامية', '{"Core / البطن والكور"}', 'Knee Extension / مد الركبة', 'قوة', NULL, 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• قف على رجل ثابتة وأمسك سنداً
• افرد الركبة بالرجل الأخرى بتحكم دون ميلان الجذع
• شد في الأعلى لحظة
• وزن خفيف مع حركة منضبطة', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/133/standing-leg-extension/', NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('bb38965f-fd8d-4916-82ed-00b61e409366', 'Bodyweight Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Lower back / أسفل الظهر"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'وزن الجسم', 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• القدمان بعرض الكتفين والذراعان أمامك للتوازن
• انزل بالورك للخلف وللأسفل والصدر مرفوع
• ركبتان باتجاه الأصابع والكعبان ثابتان
• ارتفع بدفع الأرض بكامل القدم', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/135/bodyweight-squat/', NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('21ac47f6-4cdf-4d7f-b637-4d3ce9c54f1a', 'Cable Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/mBJXWg8ZOy0', 'اجلس على الكرسي وثبت ظهرك السفلي على المقعد تمامًا، ممكن تقدّم ظهرك العلوي وتمسك المقابض لزيادة الثبات، انزل لأقصى حد تقدر عليه وارفع لحد ما تستقيم ركبتك.

ملاحظات مهمة:
• ثبّت الكيبل على الكاحل ومرجع ثابت لليد
• اثنِ الركبة بتحكم والورك ثابت
• عودة بطيئة
• وزن مناسب دون ميلان الجذع', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b67445f7-e786-441c-94a6-a6a8bb8aa968', 'DB Glutes Step Ups', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/GCnJiYJfboA?feature=share', 'استخدم ارتفاع يكون بحدود ارتفاع ركبتك أو أقل، ارفع نفسك بالضغط علي الرجل المرفوعة بتحكم بدون قفز.

ملاحظات مهمة:
• استخدم صندوقاً بارتفاع يجعل الركبة نحو 90°
• أمل الجذع قليلاً للأمام لتفعيل الألوية وادفع بكعب القدم التي على الصندوق
• انزل بتحكم دون ارتماء
• لا تدفع بالرجل الخلفية', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('954a965a-ffea-40b5-890e-4abf6d9fa58c', 'Supported Glutes Step Ups', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'مبتدئ', 'منزل', 'https://youtube.com/shorts/ZKzoOkQALaY?si=-56txwBlxSSCQYJd', 'استخدم ارتفاع يكون بحدود ارتفاع ركبتك أو أقل، ارفع نفسك بالضغط علي الرجل المرفوعة بتحكم بدون قفز.

ملاحظات مهمة:
• أمسك سنداً خفيفاً للتوازن فقط
• اصعد بالرجل التي على الصندوق وجذع مائل قليلاً
• نزول بطيء ببطء
• لا تعتمد على اليد في الصعود', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6deed81b-1ba8-4bf6-b90c-16398080dca3', 'Preacher Curl Machine', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/TouYMA3-ua4?feature=share', 'ملاحظات مهمة:
• اضبط المقعد ليكون العضد على المسند
• اثنِ حتى انقباض
• نزول بطيء دون فرد عنيف
• لا ترفع الكتفين', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Preacher Curl / ثني على مسند', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('aed244cc-2c21-47ed-82c0-fbba42ceec78', 'Glute Pushdown', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/8h2kZ64Sp5k?si=NLPf4tywxhDGY9em', 'تمسك بمقابض الجهاز، (كل ما زاد ارتفاع البنش زادت الصعوبة) + الطلوع والنزول يكون بواسطة القدم المرفوعة على البنش مو بالقدم اللي تحت، ارفع بتحكم الى أقصى ارتفاع تقدرعليه بدون ما يتقوس ظهرك السفلي، انزل لحد ما تقفل ركبتك تماما

ملاحظات مهمة:
• ثبّت جسمك على الجهاز وادفع بالقدم بتحكم
• ركّز على انقباض الألوية في نهاية الدفع
• لا تقوّس أسفل الظهر
• نزول بطيء دون ارتداد', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e88fb0d8-f7d8-4e95-a755-2cc8f545cea5', 'Glute Max Kickbacks', 'Glutes / المؤخرة', '{}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/t5mwSx4uNMc?feature=share', 'ثبت الحبل على الكاحل، ارجع خطوة للخلف وانحني للامام قليلاً وتمسك بالكيبل لزيادة الثبات، اسحب للخلف مع انثناء بسيط بالركب.

ملاحظات مهمة:
• ثبّت الكيبل على الكاحل وأمسك بسند بيد
• ارفع الرجل للخلف من الورك دون تقوّس أسفل الظهر
• انقباض الألوية لحظة في الأعلى
• وزن خفيف مع حركة منضبطة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Kickback / ركلة خلفية', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3a61149c-2f6e-4800-9756-e3c2913764eb', 'Smith Machine Kickback', 'Glutes / المؤخرة', '{}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/GR4ny80bmhM?si=WeZcWM1hyfoLElM2', 'ملاحظات مهمة:
• ضع القدم الخلفية على البار وأمسك السميث
• ادفع للأعلى وللخلف من الورك
• الحوض ثابت دون دوران
• نزول بطيء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Kickback / ركلة خلفية', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f60c851d-270b-4ca5-83d9-c6e4e88902dd', 'Glute Medius Kickbacks', 'Abductors / مبعدات الفخذ', '{"Glutes / المؤخرة"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/kccsnZNbMFA?si=6c-VoB8Zsz8NxoyM', 'ثبت الحبل على الكاحل، ارجع خطوة للخلف وانحني للامام قليلاً وتمسك بالكيبل لزيادة الثبات، اسحب للخلف وللخارج مع انثناء بسيط بالركب.

ملاحظات مهمة:
• ثبّت الكيبل على الكاحل البعيد عن الكيبل وارفع الرجل للجانب والخلف
• حافظ على حوض ثابت دون دوران وجذع مستقيم
• انقباض لحظة في الأعلى
• وزن خفيف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Abduction Kickback / ركلة خلفية مع تبعيد', 'Hip Abduction + Hip Extension / تبعيد الورك + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e1bad5f9-8d55-4672-9fa6-a949fd82fef1', 'Hip Thrusts Machine', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/0xfdeCBwoYw?si=HgJcNeB0a24gODkK', 'ممكن تسويه بالسميث مشين او البار الحر ، اختر بوكس او بنش يكون بمستوى اكتافك الخلفية وانت جالس، لما ترفع البار فوق المفروض ركبك تكون بنفس مستوى القدم.

ملاحظات مهمة:
• اضبط الجهاز ليكون الحزام على الحوض
• ادفع بالكعبين مع انقباض الألوية في الأعلى
• ذقن للأسفل قليلاً والأضلاع للأسفل
• لا تقوّس أسفل الظهر', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4445dc05-6894-4599-912d-7584646d6e92', 'Hip Thrusts', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', NULL, 'متوسط', 'منزل', 'https://youtube.com/shorts/O0EoaP7gR1A?si=cGPZ8iIwM2mQjwSb', 'ملاحظات مهمة:
• ظهر الكتفين على مقعد والبار على الحوض (مع وسادة)
• ركبتان بزاوية نحو 90° في الأعلى
• ادفع بالكعبين وانقباض الألوية لحظة
• الخطأ الشائع: ثني مفرط لأسفل الظهر', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('536fd4b0-55d5-46e7-9c7a-2ae48e2309b3', 'Glute Raise', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/X_kL_x4m77c', 'ثبت رجولك تحت، الاسفنجة تكون تحت الورك أعلى الفخذ مو على الورك مباشرة، امسك وزن بيدينك بذراع مستقيمة، ارفع وكأنك تبي تدخل القلوتس جوا الاسفنجة، بمجرد ما تنقبض مؤخرتك وقف لا ترفع أكثر.

ملاحظات مهمة:
• اضبط الجهاز بحيث يتحرك الورك بحرية
• ارفع الجسم من الورك حتى استقامة الجسم فقط
• لا تبالغ في تقوّس الظهر
• انقباض الألوية في الأعلى', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', '45° Hip Extension / بسط الورك على جهاز الظهر', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('faaac551-5d58-476b-8049-13e17d3187cf', 'Single Hip Thrusts', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', NULL, 'متوسط', 'منزل', 'https://youtube.com/shorts/ymg2AMDAwrY?si=fY8kBPTDYWRMHuAs', 'اختر بوكس او بنش يكون بمستوى اكتافك الخلفية وانت جالس، لما ترفع فوق المفروض ركبك تكون بنفس مستوى القدم، التمرين صعب طبيعي تواجه صعوبة بالبداية لذلك لا تستعجل باضافة الاوزان

ملاحظات مهمة:
• اعمل برجل واحدة والأخرى مرفوعة أو مثنية
• حافظ على حوض مستوٍ دون ميلان
• ادفع بالكعب وانقباض الألوية
• ابدأ بوزن الجسم قبل زيادة الحمل', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9cbeefd6-e6ce-4de4-b839-49f371b86aae', 'DB Spider Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/cTMjzB2_IH8?si=qsIKEEFVfEvPXwqf', 'ملاحظات مهمة:
• الصدر على مقعد مائل والذراعان للأسفل
• اثنِ بالمرفقين مع ثباتهما
• انقباض في الأعلى
• نزول بطيء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('86330e7d-8a6b-4a54-80d3-fdc33aa979f1', 'Glute Press', 'Glutes / المؤخرة', '{}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', NULL, 'ملاحظات مهمة:
• ثبّت الجذع على الجهاز وادفع بالقدم بتحكم
• ركّز على انقباض الألوية وليس الظهر
• لا تفرد الركبة بقوة
• نزول بطيء', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/293/glute-press/', NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Kickback / ركلة خلفية', 'Hip Extension + Knee Extension / بسط الورك + مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('27e4b438-ea37-4149-8b8b-7e03abc869db', 'Bulgarian Split Squat', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', 'منزل', NULL, 'ملاحظات مهمة:
• القدم الخلفية على مقعد خلفك والأمامية بمسافة كافية
• انزل عمودياً والركبة الأمامية فوق القدم
• مِل بالجذع قليلاً للأمام لتفعيل الألوية، وبشكل مستقيم للفخذ الأمامي
• ادفع بكعب الرجل الأمامية', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/366/bulgarian-split-squat/', NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Split Squat / سبليت سكوات', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7a62bfe7-ab3c-4e0e-aab5-8d74855fd9bf', 'Sumo Deadlift', 'Hamstrings / الخلفية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'منزل', 'https://www.youtube.com/watch?v=cDlOSfu-zHY', 'وقف بفتحة أرجل واسعة بحيث الركب تكون خط مستقيم مع كعب القدم و اصابع الرجل باتجاه الخارج، البار بمنتصف القدم، شد ظهرك العلوي وادفع الارض برجولك واسحب البار للأعلى، وقف لما تنقبض مؤخرتك ولا تبالغ بتقفيل حوضك.

ملاحظات مهمة:
• وقفة واسعة وأصابع للخارج والقبضة داخل الركبتين
• ركبتان باتجاه الأصابع وظهر محايد
• ادفع الأرض بالقدمين وارفع الورك والكتفين معاً
• البار قريب من الجسم', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Deadlift / ديدلفت', 'Hip Extension + Knee Extension / بسط الورك + مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8a115e62-4bff-4096-b465-3c9893da7266', 'Conventional Deadlift', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'منزل', 'https://youtu.be/GxsLrTzyGUU', 'وقف باتساع اكتافك أو أوسع شوي، البار بمنتصف القدم، شد ظهرك العلوي وادفع الارض برجولك واسحب البار للأعلى، وقف لما تنقبض مؤخرتك ولا تبالغ بتقفيل حوضك.

ملاحظات مهمة:
• القدمان بعرض الحوض والبار فوق منتصف القدم
• شد البطن وثبّت الظهر محايداً قبل الرفع
• ادفع الأرض ثم افرد الورك
• البار على الجسم ولا ينحني الظهر في أي مرحلة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Deadlift / ديدلفت', 'Hip Extension + Knee Extension / بسط الورك + مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9fcc8ba0-7d99-4439-b7e0-aa36be834ba7', 'Supine Cable Hamstring Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/sDCc1F5J8XA?si=Fi3D39aJogrB5ihd', 'الركبة ثبت مكانها، اسحب الحبل لاقصى حد تقدر عليه واترك رجلك تستقيم تمامًا في الانبساط.

ملاحظات مهمة:
• استلقِ على الظهر وثبّت الكيبل على الكاحل
• اسحب الكعب نحو الأرداف مع بقاء الحوض على الأرض أو مرفوعاً حسب الأداء
• تحكم في العودة
• لا تقوّس الظهر', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3721b848-c7b5-4ba3-9a05-4a7531ef5280', 'BB RDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'منزل', 'https://youtu.be/mZxxJEncsyw', 'وقف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، انزل وادفع مؤخرتك لآخر شي تقدر عليه للخلف وكأنك بتلمس جدار خلفك مع انثناء بسيط بالركب

ملاحظات مهمة:
• ثني بسيط ثابت في الركبتين والبار قريب من الساقين
• ادفع الورك للخلف حتى تمدد الخلفية ثم عُد بدفع الورك للأمام
• ظهر محايد وكتفان للخلف
• لا تنزل أبعد من مدى مرونتك', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2b601da3-be55-44c5-995e-4b1ff113c36e', 'DB RDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/RApyTtH6qAo', 'وقف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، انزل وادفع مؤخرتك لآخر شي تقدر عليه للخلف وكأنك بتلمس جدار خلفك مع انثناء بسيط بالركب

ملاحظات مهمة:
• الدمبلان قريبان من الساقين
• ادفع الورك للخلف وليس انحناء الظهر
• انزل حتى تمدد الخلفية ثم ارتفع بدفع الورك
• كتفان للخلف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3a0bb214-545b-432f-86ed-434995892b11', 'SM SLDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/0cB0_SzqgBU', 'ملاحظات مهمة:
• القدمان تحت البار والركبتان شبه مفرودتين
• ادفع الورك للخلف والبار على الساقين
• ظهر محايد وانزل حتى تمدد الخلفية
• حوامل أمان', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f4a7068d-7999-475e-b939-a09f70f64ced', 'SLDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', NULL, 'متوسط', 'منزل', 'https://youtu.be/RApyTtH6qAo', 'قف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، ابدأ الحركة بدفع مؤخرتك للخلف والأعلى وانزل

ملاحظات مهمة:
• ركبتان شبه مفرودتين دون قفل
• الحركة من الورك وظهر مستقيم
• انزل حتى تمدد الخلفية
• ارجع بدفع الورك للأمام', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('604fe75b-018e-4fb2-819f-9daa4c8ef639', 'Single DB SLDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/U3prDlAbJDw?si=MRSBcSIcf9M-WQBH', 'قف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، ابدأ الحركة بدفع مؤخرتك للخلف والأعلى وانزل

ملاحظات مهمة:
• دمبل بيد وثبات على رجل مع ثني بسيط
• ادفع الورك للخلف والرجل الأخرى تمتد خلفك
• حوض مستوٍ دون دوران
• استعن بسند عند صعوبة التوازن', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ce1b55e3-bb82-408f-8197-db9bee3b4d41', 'Good Morning', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'منزل', 'https://youtu.be/f23vXjoG2e8?si=9rkfUF_6XUEcQ3Xs', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع مؤخرتك لأقصى قدر تقدر عليه وكأنك بتلمس جدار خلفك.

ملاحظات مهمة:
• البار على الظهر مع ثني بسيط في الركبتين
• ادفع الورك للخلف بظهر محايد حتى تمدد الخلفية
• ارجع بدفع الورك للأمام
• وزن خفيف جداً في البداية', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Good Morning / قود مورنينق', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('35f18e4e-da4b-45f7-9d8c-c11884b29d9b', 'Seated Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/o_J6MWyt5jM', 'اجلس على الكرسي وثبت ظهرك السفلي على المقعد تمامًا، انزل لأقصى حد تقدر عليه وارفع لحد ما تستقيم ركبتك.

ملاحظات مهمة:
• اضبط محور الركبة مع محور الجهاز وثبّت المسند على الفخذ
• اثنِ الركبة بتحكم وثبّت لحظة
• عودة بطيئة
• لا ترفع الورك عن المقعد', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fa81f5e7-2364-4410-9310-461c9eb5f05a', 'Band Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/I-HTMUrJnxs', 'ثبت الباند فوق الكعب، اجلس على طرف البنش وتمسك بيدينك لزيادة الثبات، اسحب الحبل لاقصى حد تقدر عليه واترك رجلك تستقيم تمامًا في الانبساط.

ملاحظات مهمة:
• ثبّت الشريط على الكاحل ومرجع ثابت
• اثنِ الركبة بتحكم دون تمايل
• عودة بطيئة
• تأكد من ثبات الشريط', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b2953191-2fba-4625-85ee-e7c2f4810ec8', 'Lying Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/vl5nUdE9mWM', 'حوضك ثابت على البنش، ارفع الوزن بثني ومد الركبة بدون ما يرتفع حوضك عن الكرسي

ملاحظات مهمة:
• استلقِ بحيث تكون الركبة عند محور الجهاز
• اثنِ الركبة بتحكم دون رفع الحوض
• انقباض لحظة وعودة بطيئة
• لا تقوّس أسفل الظهر', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9f2d473d-4cec-4ade-bbcf-568dfdc47981', 'DB Lying Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/ZHlBSI6JPsA?si=SpBiHxluwrYE8CTP', 'ركبك ثابته على الارض، ارفع الوزن بثني ومد الركبة بدون ما يرتفع حوضك

ملاحظات مهمة:
• ثبّت الدمبل بين القدمين
• اثنِ الركبة بتحكم دون رفع الحوض
• وزن خفيف مع سيطرة
• نزول بطيء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('162a5e52-5804-4ad1-b107-943b0df7c87f', 'Stability Ball Hamstring Curl', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة"}', 'Knee Flexion / ثني الركبة', 'قوة', 'كرة سويسرية', 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• ارفع الحوض ثم اسحب الكرة نحو الأرداف بالكعبين
• حافظ على الحوض مرفوعاً دون تقوّس
• عودة بطيئة
• تحكم في الكرة', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/59/stability-ball-hamstring-curl/', NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Bridge Curl / ثني الركبة مع رفع الورك', 'Knee Flexion + Hip Extension / ثني الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('51454a27-2039-4599-afef-11a9f8f38a1a', 'Hip Hinge', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', NULL, 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• وزن الجسم والعصا على الظهر لمراقبة الاستقامة
• ادفع الورك للخلف مع ثني بسيط للركبتين
• ظهر محايد
• لا تثنِ العمود الفقري', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/33/hip-hinge/', NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Hinge Drill / تمرين مفصلة الورك', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f39dc23f-aa04-42a4-826d-c2db2b091968', 'TRX Hamstrings Curl', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة"}', 'Knee Flexion / ثني الركبة', 'قوة', 'TRX', 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• القدمان في الحزام والحوض مرفوع
• اثنِ الركبتين بالسحب نحو الأرداف مع بقاء الحوض مرتفعاً
• عودة بتحكم
• شد البطن لتجنب تقوّس الظهر', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/86/trx-reg-hamstrings-curl/', NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Bridge Curl / ثني الركبة مع رفع الورك', 'Knee Flexion + Hip Extension / ثني الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e36fdca4-0784-4f3a-9c8b-91d16fc4d122', 'Flat DB Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/xphvjGDZeYE', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا

ملاحظات مهمة:
• ثبّت لوحي الكتف للخلف وللأسفل على المقعد
• انزل الدمبلين بتحكم حتى مستوى الصدر، والمرفقان بزاوية نحو 45–70°
• ادفع للأعلى دون رفع الكتفين
• حافظ على قدمين ثابتتين وأرداف على المقعد', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f3cd7571-df55-4b53-91a5-85d3eba86974', 'DB Floor Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/UBmpZ7l5Nlk?si=kDcN-ueaTFxfKtbr', 'ملاحظات مهمة:
• استلقِ على الأرض وانزل حتى لمس العضد للأرض بخفة
• ادفع للأعلى دون ارتداد
• لوحا الكتف للخلف
• مدى أقصر من المقعد وهو آمن للكتف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e3ec6a6f-4c09-43b8-b328-1fe50c25b45c', 'Flat Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'منزل', 'https://youtu.be/vcBig73ojpE', 'استلق على بنش،القبضة بنفس مستوى الاكتاف أو أوسع قليلًا، قوّس ظهرك العلوي قليلاً، انزل لين تلمس صدرك واثبت ثانية ثم ارفع.

ملاحظات مهمة:
• العينان تحت البار وقبضة أوسع قليلاً من الكتفين
• ثبّت لوحي الكتف للخلف وللأسفل وصدر مرفوع
• انزل بتحكم إلى أسفل الصدر وادفع بخط ثابت
• استعن بمساعد أو حوامل أمان عند الأوزان الثقيلة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4c231bb1-4a9e-45f5-8674-816abe9e00e3', 'Machine Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/pOCRC2kpxB8?si=02xGtrfPjiYpspMv', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا

ملاحظات مهمة:
• اضبط المقعد ليكون المقبض بمستوى منتصف الصدر
• الكتفان للخلف والظهر ملتصق بالمسند
• ادفع دون قفل المرفقين وانزل بتحكم
• لا ترفع الكتفين', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('abfcbdea-d10f-45b4-815c-63651d25bf3b', 'Feet Up Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'منزل', 'https://youtu.be/HrehfM1dmBE', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا

ملاحظات مهمة:
• القدمان مرفوعتان على المقعد لتقليل تقوّس الظهر
• ثبّت الظهر على المقعد وانزل بتحكم
• وزن أخف من الضغط العادي
• حافظ على لوحي الكتف للخلف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b7fffa7a-924f-4a94-881e-6c38c7337156', 'Torso Elevated Push Up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'وزن الجسم', 'مبتدئ', 'منزل', 'https://youtu.be/noaPB7u4_CU', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا

ملاحظات مهمة:
• اليدان على مرتفع (مقعد) لتخفيف الحمل
• جسم مستقيم من الرأس للكعب والبطن مشدود
• انزل بالصدر نحو المرتفع والمرفقان بزاوية نحو 45°
• لا تدلِّ الورك', 'تصنيف فرعي: اليدان مرفوعتان؛ زاوية الضغط بالنسبة للجذع تشبه الضغط المائل لأسفل رغم تسميته الشائعة Incline Push-up — يحدده المدرب', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Decline Press / ضغط مائل لأسفل', 'Horizontal Adduction + Shoulder Extension / تقريب أفقي + مد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('220e3252-4646-41e3-9b63-c120913a3a6a', 'Push Up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'وزن الجسم', 'متوسط', 'منزل', 'https://youtu.be/WDIpL0pjun0?si=utydS_A8QfRIJtJm', 'ملاحظات مهمة:
• اليدان بعرض الكتفين أو أوسع قليلاً والجسم خط مستقيم
• انزل بالصدر حتى قرب الأرض والمرفقان بزاوية 45°
• ادفع دون تدلي الورك أو رفعه
• شد البطن والألوية', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b6b9cc02-1c8b-42c1-93c5-a5de80478b61', 'Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'منزل', 'https://www.youtube.com/watch?v=JvOJdUtx6UQ', 'استلق على بنش،القبضة بنفس مستوى الاكتاف أو أوسع قليلًا، قوّس ظهرك العلوي قليلاً، انزل لين تلمس صدرك واثبت ثانية ثم ارفع.

ملاحظات مهمة:
• العينان تحت البار وقبضة أوسع قليلاً من الكتفين
• ثبّت لوحي الكتف وصدر مرفوع، وقدمان ثابتتان
• انزل بتحكم وادفع بخط ثابت
• حوامل أمان أو مساعد للأوزان الثقيلة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('eb07dc8d-727e-4045-9c44-108d48a89e72', 'Paused Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'منزل', 'https://www.youtube.com/shorts/Q3GmnmJISwE', 'استلق على بنش،القبضة بنفس مستوى الاكتاف أو أوسع قليلًا، قوّس ظهرك العلوي قليلاً، انزل لين تلمس صدرك واثبت 3 ثواني ثم ارفع.

ملاحظات مهمة:
• انزل بتحكم واثبت ثانية على الصدر دون استرخاء ثم ادفع
• الوزن أخف من الضغط العادي
• ثبّت لوحي الكتف طوال التوقف
• لا ترتد بالبار', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c8c4a94e-30f7-4547-b04c-f8aa2e6403ed', 'Incline Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', NULL, 'متوسط', 'منزل', 'https://youtu.be/0G2_XV7slIg', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا

ملاحظات مهمة:
• اضبط الميل بزاوية معتدلة (نحو 30°)
• ثبّت لوحي الكتف وانزل بتحكم إلى أعلى الصدر
• لا ترفع الأرداف
• لا تجعل الميل شديداً فيتحول التمرين لكتف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Incline Press / ضغط مائل لأعلى', 'Shoulder Flexion + Horizontal Adduction / ثني الكتف + تقريب أفقي', 'Incline Press / ضغط مائل لأعلى', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cb4c676f-e2fb-46fd-bee5-43b5f76d21f7', 'Smith Machine Incline Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/EeLLZMdg6zI?si=UVsgFN7jhXMm0vW3', 'ملاحظات مهمة:
• ضع المقعد بحيث ينزل البار على أعلى الصدر
• ثبّت لوحي الكتف وانزل بتحكم
• اضبط الحوامل
• لا ترفع الأرداف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Incline Press / ضغط مائل لأعلى', 'Shoulder Flexion + Horizontal Adduction / ثني الكتف + تقريب أفقي', 'Incline Press / ضغط مائل لأعلى', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('168549c7-67b9-412d-82b0-d5717ebdbe09', 'Cable Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/tAILewhtCb0', 'اجلس على بنش انكلاين، اضبط الكيبل بمستوى صدرك تقريبا، ادفع الوزن للأمام باتجاه الداخل، احرص ان كوعك ما يكون بنفس ارتفاع كتفك

ملاحظات مهمة:
• اضبط الكيبل بمستوى الصدر أو أعلى حسب الميل
• قف أو اجلس بثبات وادفع للأمام مع تقريب اليدين
• تحكم في العودة
• الجذع ثابت دون ميلان', 'تصنيف فرعي: التعليمات تذكر بنش انكلاين، وتصنيف المصدر iso_push_chest — يُحسم بين Incline Press وعزل الصدر', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Incline Press / ضغط مائل لأعلى', 'Shoulder Flexion + Horizontal Adduction / ثني الكتف + تقريب أفقي', 'Incline Press / ضغط مائل لأعلى', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a6b19d51-2f27-4513-83b5-d1f444ebf092', 'Sternal Cable Press Around', 'Chest / الصدر', '{}', 'Horizontal Push / دفع أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/y8XQibXDnNo', 'اضبط الكيبل بمستوى صدرك تقريبا، حافظ على ذراعك قريبة من جسمك،ادفع الحبل للأمام باتجاه الداخل.

ملاحظات مهمة:
• ادفع بتقريب اليدين أمام منتصف الصدر
• لا تغلق المرفقين بقوة
• ركّز على انقباض الصدر
• الجذع ثابت وكتفان للخلف', 'تصنيف فرعي: حركة مختلطة بين الضغط والـ Fly — يُحسم بين Flat Press وعزل الصدر', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Press-around / ضغط مع تقريب', 'Horizontal Adduction + Elbow Extension / تقريب أفقي + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('728e68fd-f6a5-4156-8d79-a292205c4b52', 'Machine Chest Fly', 'Chest / الصدر', '{}', 'Horizontal Adduction (Fly) / تقريب أفقي للكتف (فلاي)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', NULL, 'ملاحظات مهمة:
• اضبط المقعد ليكون المرفقان بمستوى الصدر
• ثني بسيط ثابت في المرفقين
• افتح حتى تمدد مريح ثم ضم بقوة
• لا ترفع الكتفين', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Chest Isolation / عزل الصدر', 'Horizontal Adduction / تقريب أفقي للكتف', 'Chest Isolation / عزل الصدر', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('bc4bfef5-cd97-456e-8ca6-ea1c14a7b26a', 'Bar Cable Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/NhD3h6RG2TA?si=SoyNTIGB-nY2KiXl', 'ملاحظات مهمة:
• استخدم القضيب أمام الصدر والكيبل بالمنتصف
• ادفع بتحكم دون ميلان الجذع
• الكتفان للخلف
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8a79afc2-2299-431d-9797-0f08b25d0275', 'Head Supported Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', NULL, 'متوسط', 'منزل', 'https://youtube.com/shorts/c6lkPMhuyFA?si=eUivRGYSi0W7PmVe', 'راسك ثابت على البنش بدون أي ميلان بالرقبة.

ملاحظات مهمة:
• الجبهة أو الصدر على المسند لتثبيت الجذع
• اسحب بالمرفقين وضم لوحي الكتف
• لا ترفع الرقبة
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a2da64b8-8b0f-4cbb-9bc6-9afc5aa86ec3', 'Cable Chest Fly', 'Chest / الصدر', '{"Shoulders / الأكتاف"}', 'Horizontal Adduction (Fly) / تقريب أفقي للكتف (فلاي)', 'قوة', 'كيبل', 'مبتدئ', 'نادي', NULL, 'ملاحظات مهمة:
• ضع الكيبل بمستوى الكتف أو أعلى وخطوة أمامية للثبات
• ثني بسيط ثابت في المرفقين
• قرّب اليدين أمام الصدر بقوس
• لا تنزل اليدين أسفل مستوى الصدر', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/160/standing-chest-fly/', NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Chest Isolation / عزل الصدر', 'Horizontal Adduction / تقريب أفقي للكتف', 'Chest Isolation / عزل الصدر', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('be12d1de-c742-4469-8e59-0987df6786ee', 'Bent Knee Push-up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'وزن الجسم', 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• الركبتان على الأرض والجسم خط من الركبة للرأس
• انزل بالصدر حتى قرب الأرض والمرفقان 45°
• ادفع بدون تدلي الحوض
• تدرّج لاحقاً للضغط الكامل', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/13/bent-knee-push-up/', NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e386b724-ba00-41b1-abf7-675e014a3efc', 'Stability Ball Push-Up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس","Core / البطن والكور"}', 'Horizontal Push / دفع أفقي', 'قوة', 'كرة سويسرية', 'متوسط', 'منزل', NULL, 'ملاحظات مهمة:
• اليدان على الكرة أو القدمان عليها حسب الصعوبة
• حافظ على جسم مستقيم وثبات الكرة
• نزول بتحكم
• الخطأ الشائع: تمايل الكرة وتدلّي الورك', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف فرعي: الزاوية تعتمد على موضع الكرة (تحت اليدين أو القدمين) — غير محدد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/63/stability-ball-push-up/', NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('425caa19-c13a-4372-afac-d319cf38cd70', 'Cable Reardelt Rows', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/uIdXVGjcfFE', 'ثبت نفسك بالكرسي، فتحة واسعة، الكيبل بمستوى اسفل صدرك، واسحب لما تنقبض اكتافك الخلفية.

ملاحظات مهمة:
• اجلس أو قف وأمسك الحبل بقبضة والمرفقان للجانبين بمستوى الكتف
• اسحب نحو الوجه والمرفقان عاليان مع ضم لوحي الكتف
• لا تتمايل بالجذع
• وزن خفيف مع انقباض لحظة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Wide-grip Row / تجديف بقبضة واسعة', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4936fde0-bcba-4130-80f5-694265d88abc', 'DB Chest Supported Reardelt Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/x0v6GWYzI18?si=-jDt3D-ARIHouHjp', 'ثبت صدرك على الكرسي، فتحة واسعة، واسحب لما تنقبض اكتافك الخلفية.

ملاحظات مهمة:
• صدرك على مقعد مائل والدمبلان للأسفل
• ارفع المرفقين للجانبين بمستوى الكتف
• لا ترفع الرقبة ولا تستخدم الزخم
• وزن خفيف مع انقباض الكتف الخلفي', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Wide-grip Row / تجديف بقبضة واسعة', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5a542d84-aaa0-4e87-8999-757b0e54a1dd', 'Bent-over Barbell Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'بار', 'متوسط', 'منزل', NULL, 'ادفع مؤخرتك للخلف واثني ركبك، قبضتك بنفس مستوى اكتافك، اسحب لما تنقبض عضلات الظهر.

ملاحظات مهمة:
• انحنِ من الورك حتى جذع شبه موازٍ للأرض وظهر محايد
• اسحب البار نحو أسفل الصدر والمرفقان قريبان من الجسم
• ثبّت الجذع ولا ترفعه لتعويض الوزن
• الخطأ الشائع: تقوّس الظهر وتأرجح الجذع', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6fff6a66-e254-4e70-aaa9-eb914ca515d5', 'Cable Reardelt Fly', 'Shoulders / الأكتاف', '{"Rotator cuffs / الكفة المدورة"}', 'Shoulder Rear Pull / سحب خلفي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/bkejPHrPkmA?si=-O8q_5e72udoPRiY', 'ملاحظات مهمة:
• مرفقان مثنيان قليلاً وثابتان
• افتح الذراعين للجانبين بمستوى الكتف باتجاه الخلف
• لا تتمايل بالجذع
• وزن خفيف وانقباض لحظة', 'تصنيف فرعي: حركة Fly (تبعيد أفقي للكتف) وليست سحباً أفقياً أو عمودياً', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Rear Delt Fly / فتح خلفي', 'Horizontal Abduction / تبعيد أفقي للكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3ea3d8e2-1719-4799-8abf-63153969bfa1', 'DB Chest Supported Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/H75im9fAUMc', 'ثبت صدرك على الكرسي، فتحة واسعة، واسحب الدمبل باتجاه الورك.

ملاحظات مهمة:
• صدرك على مقعد مائل لتثبيت الجذع
• اسحب الدمبلين نحو الجانبين مع ضم لوحي الكتف
• لا ترفع الصدر عن المقعد
• انزل ببطء حتى تمدد', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4f4b351d-d401-411d-ac7f-3bda69471be4', 'Single Arm Dumbbell Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/QBjaGx8mS1o', 'اسحب باتجاه الورك.

ملاحظات مهمة:
• ركبة ويد على المقعد وظهر مسطح
• اسحب الدمبل نحو الورك والمرفق قريب من الجسم
• لا تدوّر الجذع
• انزل حتى تمدد لوح الكتف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('760026f9-66cb-48e3-8654-ee0ad4c2a280', 'Single Arm Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/Qn_mHGObb8E?si=IZ0q9_tseiRIMtcs', 'اسحب باتجاه الورك.

ملاحظات مهمة:
• ثبات القدمين والجذع
• اسحب المقبض نحو الخصر مع ضم لوح الكتف
• لا تميل أو تدوّر الجذع
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('99137280-da46-4a7e-bf22-88cea08e94a3', 'Single Arm Cable Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/J-6uEOkYAKM', 'الكيبل يبدأ من الأسفل، انحني للأمام قليلًا، ارفع للأعلى وتحكم بالنزول.

ملاحظات مهمة:
• ثبّت الجذع وارفع الذراع للجانب
• الكيبل يعطي شداً من البداية فتحكم في الأسفل
• حتى مستوى الكتف
• لا ترفع الكتف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8f69363d-a423-4043-8aac-22faef860829', 'T-Bar Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', NULL, 'متوسط', 'منزل', 'https://youtube.com/shorts/6OtcNinT0HM?si=UPfYyypfZCaN9tTA', 'ملاحظات مهمة:
• ظهر محايد وانحناء من الورك
• اسحب نحو الصدر والمرفقان قريبان من الجسم
• لا تدور الجذع
• حافظ على قبضة ثابتة وركبتين مثنيتين قليلاً', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('addebdec-ce40-4f51-806e-edbadf40c043', 'Lats Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/CQkT-W18N5g', 'الكيبل بنفس مستوى بطنك، اسحب باتجاه الورك.

ملاحظات مهمة:
• اسحب المقبض نحو أسفل البطن وليس الصدر
• المرفقان قريبان من الجسم وصدر مرفوع
• لا تميل للخلف كثيراً
• تمدد اللاتس في العودة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Lat-focused Row / تجديف لاتس', 'Shoulder Extension / مد الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a28b58f0-6c5e-4750-ac64-c8a7c9ef39cb', 'Upperback Pulldowns', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/bNmvKpJSWKM?si=hy5HgBDAHkzFHcvv', 'ملاحظات مهمة:
• اسحب القضيب نحو أعلى الصدر مع ضم لوحي الكتف والمرفقان للجانبين
• جذع مائل قليلاً للخلف دون تأرجح
• لا ترفع الكتفين
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Wide-grip Pulldown / سحب علوي بقبضة واسعة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('23909417-173d-4604-a977-b98c36eca851', 'Straight Arm Pulldown', 'Back & Lats / الظهر واللاتس', '{}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/hAMcfubonDc?si=ocU_a8VQ4VzZnTg3', 'ملاحظات مهمة:
• ذراعان شبه مستقيمتين
• اسحب القضيب للأسفل نحو الفخذين بحركة من الكتف
• شد البطن ولا تقوّس الظهر
• شعور بتمدد اللاتس في الأعلى', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Straight-arm Pull / سحب بذراع مستقيمة', 'Shoulder Extension + Scapular Depression / مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('00d0d74c-187f-4318-8670-fbf97173292d', 'DB Pullover', 'Back & Lats / الظهر واللاتس', '{"Chest / الصدر","Triceps / الترايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/ieFKuQAGYIA?si=uwqyrbKhBL6Id3_-', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.

ملاحظات مهمة:
• استلقِ على مقعد والدمبل بكلتا اليدين فوق الصدر
• انزل خلف الرأس بذراعين شبه مستقيمتين حتى تمدد مريح
• عُد بالسحب بالكتف
• لا تقوّس الظهر ولا تنزل أكثر من مدى كتفك', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Straight-arm Pull / سحب بذراع مستقيمة', 'Shoulder Extension + Scapular Depression / مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4c523504-e73f-4905-874f-7e56f9be4568', 'Band Lat Pulldown', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/5R0RYj3Y9Ro', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.

ملاحظات مهمة:
• ثبّت الشريط عالياً واسحب نحو أعلى الصدر
• المرفقان للأسفل وللجانبين
• لا تتمايل بالجذع
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('52b78fc5-cbaa-4a41-8f49-de905ca87162', 'DB Y Raises', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/lXp16YozXgk', 'ثبت صدرك على البنش،ارفع الوزن على شكل Y.

ملاحظات مهمة:
• ارفع الذراعين بشكل Y أمام الجسم والإبهام للأعلى
• وزن خفيف جداً
• ثبّت الصدر ولا تتمايل
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Y Raise (Scaption) / رفع Y بمستوى لوح الكتف', 'Shoulder Elevation in Scapular Plane (Scaption) / رفع الذراع بمستوى لوح الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8ebcfd36-429d-4def-84ee-3cfb70601854', 'Band Assisted Pull Ups', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متوسط', 'منزل', 'https://youtu.be/Ks8ah-8P1b0', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.

ملاحظات مهمة:
• ضع الشريط على الركبة أو القدم لتخفيف الوزن
• ابدأ من تعلّق كامل واسحب حتى الذقن فوق القضيب
• تجنّب التأرجح
• انزل ببطء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('154eec82-c76d-430d-807f-abed89b68545', 'Pull Ups', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متقدم', 'منزل', 'https://youtu.be/x3NPAxiMRPw?si=Mwg6U1Df5aIFpjKB', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.

ملاحظات مهمة:
• قبضة أوسع قليلاً من الكتفين وتعلّق كامل بكتفين منخفضين
• اسحب المرفقين نحو الجنبين حتى الذقن فوق القضيب
• تجنّب التأرجح واللعب بالرأس
• انزل ببطء 2–3 ثوانٍ', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e9e065a4-8b84-4d44-b594-d2475237f0b3', 'Negative Pull-Up', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متوسط', 'منزل', 'https://youtu.be/gbPURTSxQLY?si=TvQF5zDWfU_rR1Ax', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر، نزول بطيء.

ملاحظات مهمة:
• اصعد بقفزة أو بمساعدة ثم انزل ببطء 3–5 ثوانٍ
• تحكم كامل حتى تعلّق كامل
• الكتفان منخفضان
• لا تسقط في النهاية', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8b59877a-78d5-4720-9891-5d7988a42a45', 'Neutral Grip Lat Pulldown', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/kVB6SlEyjQM', 'القبضة بنفس مستوى الكتف، اسحب باتجاه اعلى الصدر.

ملاحظات مهمة:
• قبضة محايدة والمقبض قريب
• اسحب نحو أعلى الصدر والمرفقان للأسفل
• جذع مائل قليلاً دون تأرجح
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9ff1f486-2acd-4590-bf45-a1d615325f86', 'Single Lats Pulldown', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/Qed5O9toqT8', 'اجلس على بنش واسند صدرك عليه، ارجع للخلف قليلا بحيث ان الكيبل ما يكون فوق راسك مباشرة، اسحب الكوع باتجاه الورك.

ملاحظات مهمة:
• اعمل بيد واحدة مع ثبات الجذع
• اسحب المرفق نحو الجنب
• لا تدوّر الجذع
• عودة بطيئة حتى تمدد اللاتس', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('72165e12-037a-4514-ae50-fdb0aa91fdcd', 'Band Assisted Chin Ups', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متوسط', 'منزل', 'https://youtu.be/i0yC-0YK6Uk?si=gNX26kIFz_THnR4p', 'مسكة ضيقة بمستوى الأكتاف، كل ما كان الحبل خفيف زادت المقاومة وزدات صعوبة التمرين لذلك ابدأ بحبل ثقيل وخفف كل ما تحسن مستواك.

ملاحظات مهمة:
• قبضة معكوسة وشريط مساعد
• اسحب حتى الذقن فوق القضيب
• تحكم بالنزول
• لا تتأرجح', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d66b35ee-dd3b-43a7-ac33-1ecb9e0fc1ac', 'Chin Ups', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متقدم', 'منزل', 'https://youtube.com/shorts/aV9Mz9nCsMw?si=E_ullJojGO_7srW2', 'ملاحظات مهمة:
• قبضة معكوسة بعرض الكتفين
• اسحب المرفقين للأسفل وللخلف حتى الذقن فوق القضيب
• تعلّق كامل في الأسفل
• تجنّب التأرجح', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('07a09c1d-7036-4560-a399-d75ba4e5a8e7', 'Kneeling Lat Pulldown', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', NULL, 'متوسط', 'نادي', NULL, 'ملاحظات مهمة:
• اركع بثبات وجذع مستقيم
• اسحب الكيبل نحو أعلى الصدر أو الخصر بحسب الاتجاه
• لا تجلس على الكعبين
• عودة بطيئة', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/35/kneeling-lat-pulldown/', NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a66bd822-d786-4068-b151-8c41835c821e', 'Cable Y Raises', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/P7u6PEeOn6Q?feature=share', 'الكيبل يبدأ من تحت،ارفع الوزن على شكل Y.

ملاحظات مهمة:
• الكيبل من الأسفل ويدك على شكل Y
• ارفع نحو الأعلى وللخارج بخط قطري
• وزن خفيف وثبات الجذع
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Y Raise (Scaption) / رفع Y بمستوى لوح الكتف', 'Shoulder Elevation in Scapular Plane (Scaption) / رفع الذراع بمستوى لوح الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('bfd073c7-b8c7-4c4d-b278-46a527a80d7c', 'TRX Back Row', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس","Core / البطن والكور","Lower back / أسفل الظهر"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'TRX', 'متوسط', 'منزل', NULL, 'ملاحظات مهمة:
• جسم مستقيم ومائل للخلف حسب الصعوبة
• اسحب الصدر نحو المقابض وضم لوحي الكتف
• الورك لا يتدلى
• عودة بطيئة', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/84/trx-reg-back-row/', NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fc938ab2-0f73-4e01-9595-6e9401dc10fb', 'Shrug', 'Back & Lats / الظهر واللاتس', '{"Trapezius / الترابيس"}', 'Scapular Elevation / رفع لوح الكتف', 'قوة', NULL, 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• ارفع الكتفين مباشرة نحو الأذنين دون تدوير
• ثبّت لحظة في الأعلى وانزل بتحكم
• ذراعان مستقيمتان
• لا تحرك الرقبة للأمام', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف فرعي: رفع الأكتاف (Shrug) ليس نمط سحب أفقي أو عمودي', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/72/shrug/', NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Shrug / هز الكتفين', 'Scapular Elevation / رفع لوح الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fdea39bf-967d-4140-b608-0814b7bb6952', 'DB Shoulder Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/NKeyUrDYqPk', 'قوّس ظهرك العلوي قليلاً، الكوع قريب من الجسم، النزول الى مستوى الاكتاف

ملاحظات مهمة:
• اجلس بظهر مسنود وانزل الدمبلين حتى مستوى الأذنين
• ادفع للأعلى بخط فوق الكتفين
• لا تغلق المرفقين بعنف
• لا تبالغ في تقوّس الظهر', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c5c335dd-c214-44ff-8d76-0390a320faf6', 'DB Standing Shoulder Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/wO0l5jW2NtQ?si=MVvS4F_7iFS8ji9R', 'ملاحظات مهمة:
• قف بثبات وشد البطن والألوية
• ادفع للأعلى دون ميلان الجذع للخلف
• انزل حتى الأذنين
• وزن مناسب دون زخم', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b95e77e9-e5cd-4b9e-9fb5-44961dc45814', 'Machine Shoulder Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/3R14MnZbcpw', 'قوّس ظهرك العلوي قليلاً، الكوع قريب من الجسم، النزول الى مستوى الاكتاف

ملاحظات مهمة:
• اضبط المقعد ليكون المقبض بمستوى الكتف
• الظهر ملتصق بالمسند
• ادفع دون رفع الكتفين
• عودة بتحكم', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1585be60-f37b-4e9e-978a-437ba9aeb4ee', 'BB Overhead Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'بار', 'متوسط', 'منزل', 'https://youtu.be/_RlRDWO2jfg', 'ملاحظات مهمة:
• قبضة أوسع قليلاً من الكتفين
• شد البطن والألوية وادفع بخط مستقيم
• حرّك الرأس للخلف ثم للأمام عند مرور البار
• لا تقوّس أسفل الظهر', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('def93a43-6d90-449b-8483-1abb14e86b81', 'DB Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/qqntiuPmLDM?feature=share', 'انحني للأمام قليلًا، ارفع للأعلى الى أن تصل لمستوى الأكتاف.

ملاحظات مهمة:
• ارفع بمرفق مثني قليلاً حتى مستوى الكتف فقط
• قدّم المرفق على اليد ولا ترفع الكتفين نحو الأذنين
• نزول بطيء 2–3 ثوانٍ
• لا تتأرجح بالجذع', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('23ffe64f-c1b1-4fc4-821e-51af1426106a', 'Seated Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', NULL, 'مبتدئ', 'منزل', 'https://youtube.com/shorts/v7fwGurZ9SU?feature=share', 'انحني للأمام قليلًا، ارفع للأعلى الى أن تصل لمستوى الأكتاف.

ملاحظات مهمة:
• اجلس بظهر مسنود لإزالة الزخم
• ارفع حتى مستوى الكتف والمرفقان مثنيان قليلاً
• نزول بطيء
• وزن خفيف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('40477cac-bc89-4b00-8070-0d00ae751acc', 'Lateral Raise Machine', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/d0pRsZ9SY5w?si=XuXb_Ti0Flow7qvW', 'ملاحظات مهمة:
• اضبط المقعد ليكون محور الكتف مع محور الجهاز
• ارفع الذراعين للجانبين دون رفع الكتفين
• نزول بطيء
• لا تدفع بالجذع', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f4a4ceec-33ca-4421-b96c-7f629a59f387', 'Cable Crossover Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/wKgCc5UQjoU?si=zsaz3i31PnEU9A43', 'الكيبل يبدأ من الأسفل، انحني للأمام قليلًا، ارفع للأعلى وتحكم بالنزول.

ملاحظات مهمة:
• الكيبل من الجهة المقابلة
• ارفع الذراع قطرياً للجانب حتى مستوى الكتف
• جذع ثابت
• وزن خفيف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('18aee5ab-c93b-4827-82e7-fb40337e9e03', 'Single Arm DB Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/Jm6GqVhWhNY', 'انحني للأمام قليلًا، ارفع للأعلى الى أن تصل لمستوى الأكتاف.

ملاحظات مهمة:
• اعمل بيد واحدة وأمسك سنداً بالأخرى
• ارفع حتى مستوى الكتف دون ميلان الجذع
• نزول بطيء
• وزن خفيف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('09fa8a01-c129-47fb-9bc8-25ef07aa1813', 'Front Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Front Raise / رفع أمامي للكتف', 'قوة', NULL, 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• ارفع حتى مستوى الكتف فقط والمرفق مثني قليلاً
• لا تتأرجح بالجذع
• نزول بطيء
• وزن مناسب', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/54/front-raise/', NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Front Raise / رفع أمامي', 'Shoulder Flexion / ثني الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cf8875c1-ca2c-487b-a1b1-aac9c9f46ae6', 'Diagonal Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', NULL, 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• ارفع بخط قطري من الفخذ المقابل نحو الكتف
• حرّك بتحكم دون تدوير الجذع
• وزن خفيف
• حتى مستوى الكتف', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/371/diagonal-raise/', NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Diagonal Raise / رفع قطري', 'Shoulder Flexion + Abduction (Diagonal) / ثني وتبعيد الكتف (قطري)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('74f7a3f6-0ea9-4022-bccf-0bd69c7a5f8c', 'High Row', 'Shoulders / الأكتاف', '{}', 'Shoulder Rear Pull / سحب خلفي للكتف', 'قوة', NULL, 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• اسحب نحو الوجه والمرفقان للأعلى وللجانبين
• دوّر الذراعين للخارج في النهاية
• لا تتمايل للخلف
• الرسغ مستقيم', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/336/high-row/', NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'High Row / Face Pull / سحب عالٍ باتجاه الوجه', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('41f9015b-e09c-40cb-b24b-c277dd7bae8a', 'Biceps Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', NULL, 'مبتدئ', 'منزل', 'https://youtube.com/shorts/09AYfVFf7pg?si=dcwLVAYqIbDLM6jd', 'ملاحظات مهمة:
• المرفقان ثابتان بجانب الجسم ولا تتأرجح
• اثنِ حتى انقباض كامل وانزل ببطء 2–3 ثوانٍ
• رسغ محايد
• لا ترفع الكتفين', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ef689b4e-d5ad-4889-893c-ba1e77353fc3', 'Cable Rope Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/xNXUTJ6TBZA?si=-r-Ql97awoVZla_1', 'ملاحظات مهمة:
• قبضة محايدة بالحبل والمرفقان ثابتان
• اثنِ وأدر الحبل للخارج في الأعلى
• نزول بطيء
• الجذع ثابت', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Hammer / Neutral-grip Curl / ثني بقبضة محايدة', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('203e79b6-9246-4224-bfbc-313fdd3b6070', 'Cable Facing Away Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/fV9BpknCjGM', 'ملاحظات مهمة:
• وجهك بعيداً عن الكيبل والذراعان للخلف قليلاً
• اثنِ بالمرفقين مع ثباتهما
• تمدد البايسبس في الأسفل
• لا تتأرجح', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('300f7881-8ecf-4b2f-9f6f-cc9768880546', 'DB Incline Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/js_StxxyxBM', 'ملاحظات مهمة:
• على مقعد مائل والذراعان خلف الجسم
• اثنِ بالمرفقين دون تقديمهما للأمام
• تمدد كامل في الأسفل
• وزن خفيف نسبياً', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6124df92-d88a-4a21-be03-979b9dc01bd4', 'Cable Facing In Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/5z4y7QRTx1w', 'ملاحظات مهمة:
• وجهك للكيبل والمرفقان للأمام قليلاً
• اثنِ حتى انقباض كامل
• حافظ على شد الكيبل
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cc8fab44-37d1-4f3d-9604-b5da3ec64908', 'Single Arm Cable Facing Away Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/6sO-pK7pTPs?feature=share', 'ملاحظات مهمة:
• بيد واحدة مع ثبات الجذع
• المرفق ثابت
• اثنِ بتحكم
• نزول بطيء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6ba17c87-c709-4670-9963-13c1bdfce840', 'Single Arm Cable Facing In Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/I-197ZW9Ffo?si=M1Yq4R1PIpdZMXRx', 'ملاحظات مهمة:
• بيد واحدة مع ثبات الجذع
• المرفق للأمام قليلاً
• اثنِ بتحكم
• نزول بطيء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9bf427d6-807b-421a-8bf8-baaed673b81b', 'DB Preacher', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/DZJNTb-zzn0?si=SwbdZ0O_0eTOET-5', 'ملاحظات مهمة:
• العضد على المسند ولا يرتفع
• اثنِ وانزل ببطء دون فرد المرفق بعنف
• وزن مناسب دون زخم
• رسغ محايد', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Preacher Curl / ثني على مسند', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('24a7820f-ec8c-4ef4-a309-cff12a4a320e', 'Zottman Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://www.youtube.com/watch?v=ZXbOOIOPOi8', 'ملاحظات مهمة:
• اثنِ بقبضة عادية ثم دوّر الرسغ في الأعلى وانزل بقبضة معكوسة
• نزول بطيء
• وزن خفيف للساعد
• المرفق ثابت', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c8f89540-1aa4-419b-ac69-a423a6573a71', 'Hammer Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• قبضة محايدة والمرفقان ثابتان
• اثنِ دون تأرجح
• نزول بطيء
• الإبهام للأعلى', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/10/hammer-curl/', NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Hammer / Neutral-grip Curl / ثني بقبضة محايدة', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('bfb0df1b-d27a-4b0f-8546-f0e47d8b46b4', 'TRX Biceps Curl', 'Biceps / البايسبس', '{"Forearms / الساعد","Core / البطن والكور"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'TRX', 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• جسم مستقيم ومائل للخلف والمرفقان للأمام
• اثنِ المرفقين نحو الجبهة
• عودة بطيئة
• الورك لا يتدلى', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/78/trx-reg-biceps-curl/', NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3e7b60c1-f898-49a2-9764-472e6061a6d5', 'DB Triceps Extensions', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/d7SXlU5HkYM?si=WuuPa9-yeByaP5sI', 'ملاحظات مهمة:
• مرفقان قريبان من الرأس وثابتان
• انزل خلف الرأس بتحكم ثم افرد المرفقين
• شد البطن وجذع ثابت
• وزن مناسب', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Overhead Extension / مد فوق الرأس', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('09f9ab7e-7c18-4e1f-bdcb-3e24da2b39de', 'Cable Crossbody Extensions', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://www.youtube.com/watch?v=jtLTcED38Dg', 'الكيبل يبدأ بالمنتصف زي الفيديو، بحيث لما تسحب الكيبل يكون بنفس مستوى الترابس، الأكواع والأكتاف ثابتين مكانهم والحركة كلها بثني وفرد الكوع.

ملاحظات مهمة:
• اسحب الكيبل بالمرفق ثابتاً وعبر الجسم
• افرد بالكامل مع انقباض الترايسبس
• العضد ثابت
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Cross-body Extension / مد عرضي', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('664c9b40-efdd-487e-b191-17b258509ae7', 'Triceps Pushdown', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/QsoN4u6j8nM?feature=share', 'انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.

ملاحظات مهمة:
• المرفقان ثابتان بجانب الجسم
• افرد المرفقين بالكامل مع انقباض لحظة
• عودة بطيئة دون رفع الكتفين
• لا تتمايل', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6689ceeb-b9bc-4e21-b798-bb269c470898', 'Cable Crossover Pressdowns', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/Y3CDzx-oj3k', 'الكيبل يبدأ من الأعلى،انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.

ملاحظات مهمة:
• ادفع من الجهتين بمرفقين ثابتين
• افرد بالكامل وانقباض
• عودة بطيئة
• جذع ثابت', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c029815c-0d4d-46ec-b638-e930e532b057', 'Band Triceps Pushdown', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/mYs1rEYtZK4?si=k8vdZxNNEB5wj2CA', 'الكيبل يبدأ من الأعلى،انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.

ملاحظات مهمة:
• ثبّت الشريط عالياً
• افرد المرفقين مع بقاء العضد ثابتاً
• عودة بطيئة
• تأكد من ثبات الشريط', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f896cf88-a53d-4939-83a1-2314669aeb0a', 'Single Cable Triceps Pressdowns', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/8rl4ioij6lc', 'الكيبل يبدأ من الأعلى،انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.

ملاحظات مهمة:
• بيد واحدة والمرفق ثابت
• افرد بالكامل
• عودة بطيئة
• جذع ثابت', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('be734907-f0da-4d3a-b408-9adc7d35d6ab', 'Cable Overhead Extension', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://www.youtube.com/shorts/Q3bO1Fh4734', 'اترك الحبل يسحب معصمك وكوعك ثابت لما تستطيل التراي ثم ارفع الوزن لما تستقيم اليد، كوعك ثابت طول الوقت والحركة ثني ومد من مفصل الكوع، ممكن تطبق كل يد لحالها اذا كان اسهل لك.

ملاحظات مهمة:
• وجهك للأمام أو الخلف والمرفقان قريبان من الرأس
• افرد المرفقين فوق الرأس بتحكم
• شد البطن لتجنب التقوّس
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Overhead Extension / مد فوق الرأس', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('18f8716d-87bd-4f93-8f41-acd31847e7b4', 'Triceps Dips', 'Triceps / الترايسبس', '{"Chest / الصدر","Shoulders / الأكتاف"}', 'Vertical Push / دفع عمودي', 'قوة', NULL, 'متوسط', 'منزل', 'https://youtube.com/shorts/SpSE_A5L-YA?si=bSAzRM9SBuX-3mE0', 'ملاحظات مهمة:
• جسم مستقيم على مقعد أو متوازي
• انزل بالمرفقين حتى 90° تقريباً
• لا تتجاوز مدى كتفك
• توقف عند ألم الكتف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Dip / متوازي', 'Shoulder Extension + Elbow Extension / مد الكتف + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('899e9a8a-9452-4e7f-ac13-f5133744da99', 'Triceps Kickback', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', NULL, 'مبتدئ', 'منزل', 'https://youtube.com/shorts/YebyKE3Ts8o?si=H_h9z5BXutFBbFhq', 'ملاحظات مهمة:
• العضد موازٍ للجسم وثابت
• افرد المرفق للخلف بتحكم
• انقباض في الأعلى
• وزن خفيف', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/55/triceps-kickback/', NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Triceps Kickback / ركلة الترايسبس', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('647a0fa9-1de9-4f58-8525-0a076d90d26c', 'Pelvic Tilting', 'Core / البطن والكور', '{}', 'Core Activation & Breathing / تفعيل الجذع والتنفس', 'إحماء/تفعيل', 'وزن الجسم', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/DqqUIfMuDX4?si=uzl0SRl_M9guUT3j', 'الحركة من الحوض، اخذ نفس وادف حوضي للاعلى قليلا، اطلع النفس اثناء نزول الحوض والصق اسفل ظهري بالارض

ملاحظات مهمة:
• حركة صغيرة ناعمة من الحوض بشد البطن
• لا ترفع الأرداف
• تنفس طبيعي
• لا تضغط بقوة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Pelvic Tilt / إمالة الحوض', 'Posterior Pelvic Tilt / إمالة الحوض للخلف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c4b6fd1c-0584-4cf0-b5e3-f681f9013778', 'Suitcase Carry', 'Core / البطن والكور', '{"Forearms / الساعد"}', 'Loaded Carry / حمل ومشي', 'قوة', NULL, 'مبتدئ', 'منزل', 'https://youtu.be/BaRMAhD7SP4?si=KkiMH8OSIEz_TB53', 'ملاحظات مهمة:
• امشِ بجذع مستقيم دون ميلان نحو الوزن
• كتفان ثابتان وخطوات منتظمة
• شد البطن
• بدّل الجهة', 'نفس التمرين ورد أيضاً تحت التصنيف «Functional Training» (صف المصدر 160) || رابط آخر في المصدر (صف 160): https://youtu.be/BaRMAhD7SP4?si=dCR2n2VSPaHhxfL3', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Suitcase Carry / حمل جانبي', 'Isometric Trunk + Grip Under Load / تثبيت الجذع والقبضة أثناء المشي', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f1cdff23-fedc-4fd3-a8d0-0e557b76d25a', 'Single Leg Raise', 'Core / البطن والكور', '{"Glutes / المؤخرة","Hamstrings / الخلفية"}', NULL, NULL, 'وزن الجسم', 'مبتدئ', 'منزل', 'https://youtu.be/ZJodU5OOaiA?si=p6ZD9dpzyRKBUn16', 'ملاحظات مهمة:
• استلقِ وثبّت أسفل الظهر على الأرض
• ارفع الرجل بتحكم دون تقوّس الظهر
• نزول بطيء
• لا ترتد', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4ee841b6-d5c7-49cc-a15b-020e031422e4', 'Cable Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/ToJeyhydUxU?si=Z5dv34foxX4VtRH6', 'الحركة عبارة عن ثني للعمود الفقري وكأنك تقرب صدرك لوركك.

ملاحظات مهمة:
• اركع أمام الكيبل والحبل عند الرأس
• اثنِ الجذع نحو الأرض بتقوّسه
• الحوض ثابت والحركة من البطن
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Crunch / كرنش', 'Trunk Flexion / ثني الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('aa15354d-9140-45e7-950d-debe368a64bf', 'Leg Raises', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', NULL, 'مبتدئ', 'منزل', 'https://youtube.com/shorts/UqmbxvOgnX4?si=U3pDG4Jf0x1mtC_7', 'ملاحظات مهمة:
• علّق أو استلقِ وثبّت الظهر
• ارفع الرجلين بتحكم دون تأرجح
• اثنِ الركبتين عند الصعوبة
• نزول بطيء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Reverse Crunch / Leg Raise / كرنش عكسي ورفع الأرجل', 'Hip Flexion + Posterior Pelvic Tilt / ثني الورك + إمالة الحوض للخلف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b563b65f-00aa-4133-a2e6-9224fef5ae38', 'Bosu Ball Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'أخرى', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/KjvDgHPxXcg?si=zad59CHC6Y-calzi', 'ملاحظات مهمة:
• استلقِ على الكرة وأسفل الظهر مدعوم
• اثنِ الجذع للأعلى بتحكم
• لا تسحب الرقبة
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Crunch / كرنش', 'Trunk Flexion / ثني الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('74e4bb29-4c4f-49b3-aa8d-6c7446af72e6', 'Bent Knee V-Up', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'منزل', 'https://youtu.be/sbyFIM30_G8?si=dED0NQSRS44dz5G9', 'ملاحظات مهمة:
• ارفع الجذع والركبتين معاً نحو بعضهما
• حركة بطيئة بتحكم
• أسفل الظهر لا يتقوس
• زفير عند الرفع', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'V-up / في أب', 'Trunk Flexion + Hip Flexion / ثني الجذع + ثني الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('513758e1-b088-4c86-b48f-45df505eef9f', 'Reverse Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/esYVzdEfs04?si=N44MZZHlVeSQc1S3', 'ملاحظات مهمة:
• ارفع الحوض عن الأرض بتقوّس أسفل الظهر
• لا تستخدم الزخم
• نزول بطيء
• الركبتان مثنيتان', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Reverse Crunch / Leg Raise / كرنش عكسي ورفع الأرجل', 'Hip Flexion + Posterior Pelvic Tilt / ثني الورك + إمالة الحوض للخلف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('97fc17e9-7835-4fc9-9a92-f137e11f37f3', 'Belly Breathing', 'Core / البطن والكور', '{}', 'Core Activation & Breathing / تفعيل الجذع والتنفس', 'إحماء/تفعيل', 'وزن الجسم', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/Shk8cmgv0Ew?si=mXkcj9PH6eH_tLcd', 'نفس عميق من الانف ننفخ فيه البطن ثم نطلعه من الفم ببطئ مع ضغط البطن للداخل اثناء اخراج النفس

ملاحظات مهمة:
• شهيق بطيء من الأنف يوسّع البطن
• زفير بطيء من الفم
• الكتفان مرتخيان
• لا ترفع الصدر', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Diaphragmatic Breathing / تنفس حجابي', 'Diaphragmatic Breathing + Abdominal Bracing / تنفس حجابي + شد البطن', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1a0575d5-7af8-4d3e-9a50-189e7e1df2e8', 'Reverse Tabletop Bridge', 'Core / البطن والكور', '{"Glutes / المؤخرة"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'وزن الجسم', 'متوسط', 'منزل', 'https://youtu.be/d1yE9cGtPWo?si=2aoNqmUAN054rP75', 'اخذ نفس اثناء الطلوع، اثبت ثواني فوق واشد عضلات بطني، اطلع النفس اثناء النزول

ملاحظات مهمة:
• ارفع الورك حتى استقامة الجسم مع اليدين خلفك
• انقباض الألوية
• الرأس محايد
• لا تبالغ في تقوّس الظهر', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ea1d7563-de12-45f1-bbcc-fe3b56ed4c24', 'Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• ارفع الكتفين فقط عن الأرض
• لا تسحب الرقبة باليدين
• زفير عند الرفع وانقباض لحظة
• نزول بطيء', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/52/crunch/', NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Crunch / كرنش', 'Trunk Flexion / ثني الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('65807324-fcfe-457c-86e0-d9038ac505eb', 'Standing Wood Chop', 'Core / البطن والكور', '{}', 'Trunk Rotation / دوران الجذع', 'كور', NULL, 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• دوّر من الجذع والورك والذراعان شبه مستقيمتين
• حرّك من الأعلى للأسفل بخط قطري
• الحوض مستقر
• تحكم في العودة', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/108/standing-wood-chop/', NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Rotation / Chop / دوران وتقطيع', 'Trunk Rotation / دوران الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('52382b55-a14b-4ca7-9b8f-01a9f6854d5f', 'Russian Twist', 'Core / البطن والكور', '{"Lower back / أسفل الظهر"}', 'Trunk Rotation / دوران الجذع', 'كور', NULL, 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• اجلس مائلاً قليلاً بجذع مستقيم
• دوّر الكتفين والجذع لا اليدين فقط
• الرجلان على الأرض عند الصعوبة
• حركة بطيئة', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/65/russian-twist/', NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Rotation / Chop / دوران وتقطيع', 'Trunk Rotation / دوران الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('731672da-cbb2-4468-b51f-d9069ef43059', 'Cable Twisted', 'Core / البطن والكور', '{"Lower back / أسفل الظهر"}', 'Trunk Rotation / دوران الجذع', 'كور', 'كيبل', 'مبتدئ', 'نادي', NULL, 'ملاحظات مهمة:
• ثبّت الحوض ودوّر من الجذع
• ذراعان شبه مستقيمتين
• تحكم في العودة
• وزن مناسب', NULL, 'إضافة المدربة', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Rotation / Chop / دوران وتقطيع', 'Trunk Rotation / دوران الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('801c9df5-cae5-44c9-9d36-c02fbc920322', 'Calves On Leg Press', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/XdtWVYFVhGU', 'ثبت أصابعك أو مقدمة رجلك على الجهاز، لا تبالغ بالوزن، انزل بكعبك لين تمتد بطاتك بشكل كامل ثم ادفع.

ملاحظات مهمة:
• القدمان على الحافة السفلى للمنصة والركبتان مفرودتان قليلاً دون قفل
• ادفع بمقدمة القدم لأقصى ارتفاع ثم انزل حتى تمدد البطة
• توقف لحظة في الأعلى والأسفل
• لا ترتد', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f51f344c-441e-4b84-8777-4135164a8d7c', 'Calves Raise', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', NULL, 'مبتدئ', 'منزل', 'https://youtu.be/H6WptvjXkgw', 'حط تحت اقدامك بليتس أو أي شي يرفعك عن الأرض، انزل من اصابعك اقصى نزول ثم ادفع للأعلى

ملاحظات مهمة:
• ارتفع على أطراف الأصابع لأقصى مدى
• انزل حتى تمدد البطة
• توقف في الأعلى
• حركة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('82ff63d2-a963-42a7-a549-d12ecfeae048', 'Calf Raise (Machine)', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', 'جهاز', 'مبتدئ', 'نادي', NULL, 'ملاحظات مهمة:
• ضع الكتفين تحت المساند وأصابع القدم على الحافة
• ارتفع لأقصى مدى وانزل حتى تمدد
• توقف لحظة في الأعلى
• لا ترتد', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/294/calf-raise/', NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a68e34eb-e561-457f-8115-85a1e64fc530', 'Calf Raises (Barbell)', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', 'بار', 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• البار على أعلى الظهر وقوف ثابت
• ارتفع على الأصابع بتحكم
• مدى كامل بدون ارتداد
• سند للتوازن', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/51/calf-raises/', NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7e1abedc-8936-49a0-9171-0f2f1e1e33bb', 'Adductor Slides', 'Adductors / الأفخاذ الداخلية', '{}', 'Hip Adduction / تقريب الورك', 'قوة', NULL, 'مبتدئ', 'منزل', 'https://youtu.be/6U7dfuxaX9g?si=lkH35E7tZxGBePBj', 'ملاحظات مهمة:
• انزلق بالرجل للجانب بتحكم
• الجذع ثابت
• ادفع للعودة بالعضلة الداخلية
• حركة بطيئة', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor strength»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Adductor Slide / انزلاق للتقريب', 'Hip Adduction / تقريب الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f0b4f3f0-cd34-4f50-bd00-2a88a6e5a7e1', 'Adductor Machine', 'Adductors / الأفخاذ الداخلية', '{}', 'Hip Adduction / تقريب الورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/SU1LQhq3o2g?si=_55FKBOlcn8Ilw4X', 'ملاحظات مهمة:
• اضبط مدى مريح للبداية
• اضغط الفخذين معاً بتحكم
• عودة بطيئة دون ارتداد
• لا تفتح أكثر من مدى مريح', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Adductor Machine / جهاز التقريب', 'Hip Adduction / تقريب الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a48a919c-0706-40a4-a50c-2121fea51f04', 'Seated Abductor Machine', 'Abductors / مبعدات الفخذ', '{}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/riEMreTHNbM?si=wE3vfJBYQY7j_oJ2', 'ملاحظات مهمة:
• ظهر ملتصق بالمسند
• افتح الركبتين للخارج بتحكم
• انقباض لحظة
• عودة بطيئة', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor strength»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b6cbf67a-fe33-4ced-92f1-1a006023acd9', 'Hip Abductor Plank', 'Abductors / مبعدات الفخذ', '{"Core / البطن والكور"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'منزل', 'https://youtu.be/2lB5RL91yWo?si=WRm9rUORpFK6dXPl', 'ملاحظات مهمة:
• بلانك جانبي بجسم مستقيم
• ارفع الرجل العليا بتحكم
• الحوض لا يميل
• ثبّت الكتف تحت المرفق', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor strength»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('93c5bc26-50c9-4d10-b9d8-dc8d9f68a313', 'Dirty Dog', 'Abductors / مبعدات الفخذ', '{"Core / البطن والكور"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• على أربع مع ظهر محايد
• ارفع الركبة للجانب كالكلب بتحكم
• الحوض ثابت دون ميلان
• حركة بطيئة', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/109/dirty-dog/', NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('08880eb8-7d98-44af-9369-55d6b7e4d1db', 'Rotator Cuff', 'Rotator cuffs / الكفة المدورة', '{}', 'Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف', 'قوة', NULL, 'مبتدئ', 'منزل', 'https://youtu.be/mO8YJAxVG2M?si=KL_llR6Z47Yt89uk', 'ملاحظات مهمة:
• وزن خفيف جداً والمرفق ملتصق بالجسم
• دوّر الساعد للخارج بتحكم دون ألم
• حركة بطيئة
• لا تقوّس الظهر', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «Functional Training»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'External Rotation / دوران خارجي', 'Shoulder External Rotation / دوران خارجي للكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9d1babb8-b2f3-473a-9983-21df7207983c', 'Stability Ball Reverse Extensions', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة"}', 'Spinal Extension / بسط الجذع', 'كور', 'كرة سويسرية', 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• على بطنك على الكرة
• ارفع الرجلين بتحكم حتى استقامة الجسم
• لا تبالغ بالتقوّس
• شد الألوية', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/64/stability-ball-reverse-extensions/', NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Reverse Extension / بسط عكسي', 'Hip Extension + Spinal Extension / بسط الورك + بسط العمود الفقري', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fe98e001-1eed-4172-8120-6d245c69f6b3', 'Contralateral Limb Raises', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة","Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Spinal Extension / بسط الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• على أربع، ارفع اليد والرجل المقابلة بتحكم
• الحوض والظهر ثابتان دون ميلان
• ثبّت لحظة
• بدّل الجهة', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/53/contralateral-limb-raises/', NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Prone Extension / بسط على البطن', 'Spinal Extension / بسط العمود الفقري', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4d08c298-9d76-4019-a17d-fbad6b7ef6f8', 'Inner Thigh Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/uqCfJYKojLU?si=Gev0VeOwVp5z6gB2', 'الضغط والدفع يكون من جهة الفخذ ، لا تدفع من ركبتك!

ملاحظات مهمة:
• اجلس بفتح الرجلين وقدمين ملتصقتين
• اضغط الركبتين للأسفل برفق
• شد مريح وليس ألماً
• ثبّت 20–40 ثانية', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «stretch»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Adductor Stretch / إطالة المقربات', 'Hip Abduction (Adductor Stretch) / تبعيد الورك (إطالة المقربات)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c51cb1ea-4866-40b8-bd29-9cdc701a4919', 'Hips Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/uqCfJYKojLU?si=Gev0VeOwVp5z6gB2', 'ملاحظات مهمة:
• وضعية ممتدة للورك بجذع مستقيم
• اضغط برفق دون ألم
• تنفس بهدوء
• ثبّت 20–40 ثانية', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «stretch»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Hip Stretch / إطالة الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cb244032-272c-4450-a5b0-56244a3a5361', 'Kneeling Hip-flexor Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'منزل', NULL, 'من وضع الركوع: الركبة الخلفية تحت الورك والقدم الأمامية أمامك والركبة فوق الكاحل. شد البطن وادفع الحوض للأمام دون تقويس أسفل الظهر، واعصر مؤخرة الجهة الخلفية لزيادة الإطالة. اثبت 30–45 ثانية، 2–5 مرات.

ملاحظات مهمة:
• ركبة على الأرض والأخرى أمامك
• ادفع الحوض للأمام مع شد البطن
• شد في مقدمة الورك
• لا تقوّس أسفل الظهر', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/142/kneeling-hip-flexor-stretch/', NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Hip Flexor Stretch / إطالة ثانيات الورك', 'Hip Extension (End Range) / بسط الورك في نهاية المدى', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6f155850-05a4-4989-8bee-caf4b86c501c', 'Supine Hamstrings Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'منزل', NULL, 'استلقِ على ظهرك وارفع رجلاً واحدة ومدّها ببطء مع سحب أصابع القدم نحوك، دون أي حركة في الحوض أو أسفل الظهر. اثبت 15–30 ثانية، 2–4 مرات لكل رجل.

ملاحظات مهمة:
• استلقِ وارفع رجلاً بمساعدة شريط أو يدين
• ركبة شبه مفرودة بدون ألم
• شد مريح للخلفية
• ثبّت 20–40 ثانية', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/235/supine-hamstrings-stretch/', NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Hamstring Stretch / إطالة الخلفية', 'Hip Flexion with Knee Extended / ثني الورك مع مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e4b016ad-e1c1-416e-b28a-896e8afc610b', 'Side Lying Quadriceps Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'منزل', NULL, 'استلقِ على جنبك وشد البطن، واسحب كعب الرجل العلوية نحو المؤخرة بيدك مع إبقاء الركبة في خط الورك. اثبت 30–45 ثانية، 2–5 مرات لكل جهة.

ملاحظات مهمة:
• على الجنب اسحب الكعب نحو الأرداف
• الركبتان متقاربتان والحوض ثابت
• شد مريح بدون ألم الركبة
• ثبّت 20–40 ثانية', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/149/side-lying-quadriceps-stretch/', NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Quadriceps Stretch / إطالة الأمامية', 'Knee Flexion + Hip Extension (End Range) / ثني الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fed2559c-c6c0-4508-948a-552368c53935', 'Standing Lunge Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• وضعية لانج ثابتة وحوض للأمام
• جذع مستقيم وشد البطن
• شد في مقدمة ورك الرجل الخلفية
• ثبّت 20–40 ثانية', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/137/standing-lunge-stretch/', NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Hip Flexor Stretch / إطالة ثانيات الورك', 'Hip Extension (End Range) / بسط الورك في نهاية المدى', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a5b82b2d-5366-4c70-9019-a243bd0e5fa0', 'Lateral Bound', 'Plyometrics / التمارين الانفجارية', '{"Glutes / المؤخرة","Quadriceps / الأمامية","Abductors / مبعدات الفخذ"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متوسط', 'منزل', 'https://www.youtube.com/watch?v=soqQy4dzEts', 'ملاحظات مهمة:
• اقفز جانبياً وهبوط ناعم على رجل واحدة
• الركبة فوق القدم دون انهيار
• ثبّت لحظة
• ابدأ بمسافة قصيرة', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «Functional Training»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Lateral Jump / قفز جانبي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8a92bbfb-a3c5-4dbc-9697-ea753f61826a', 'Box Jumps', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Calves / البطات"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'أخرى', 'متوسط', 'منزل', NULL, 'ملاحظات مهمة:
• اقفز بانفجار وهبوط ناعم على صندوق
• الركبتان مثنيتان عند الهبوط
• انزل بالخطوة لا بالقفز
• ابدأ بارتفاع منخفض', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «CrossFit»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Vertical Jump / قفز عمودي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('add3dc83-d283-4c33-b771-d5839c23398f', 'Squat Jump', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متوسط', 'منزل', NULL, 'قف بعرض الحوض، ادفع الورك للخلف وانزل، ثم اقفز بقوة بمدّ الكاحل والركبة والورك معاً. انزل بهدوء على منتصف القدم مع دفع الورك للخلف ودون قفل الركب. ابدأ بقفزات صغيرة حتى تتقن الهبوط.

ملاحظات مهمة:
• انزل بسكوات ثم اقفز لأعلى بانفجار
• هبوط ناعم على كامل القدم
• الركبتان باتجاه الأصابع
• أوقف المجموعة عند هبوط الأداء', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/222/squat-jump/', NULL, 'review', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Vertical Jump / قفز عمودي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f107174f-ba4d-41c8-a5e1-22d622efc73d', 'Tuck Jump', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متقدم', 'منزل', NULL, 'استخدم الذراعين للزخم: أرجعهما للخلف عند النزول وأرجحهما للأمام والأعلى عند القفز، واسحب الركبتين نحو الصدر في الهواء.

ملاحظات مهمة:
• اقفز واسحب الركبتين نحو الصدر
• هبوط ناعم والركبتان مثنيتان
• حافظ على جذع مستقيم
• مجموعات قصيرة', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/180/tuck-jump/', NULL, 'review', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Vertical Jump / قفز عمودي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c9da1602-3c87-447f-8373-f32deabb074e', 'Cycled Split-Squat Jump', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Hamstrings / الخلفية"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متقدم', 'منزل', NULL, 'ملاحظات مهمة:
• من وضع لانج اقفز وبدّل الرجلين في الهواء
• هبوط ناعم والركبة فوق القدم
• جذع مرفوع
• مجموعات قصيرة', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/234/cycled-split-squat-jump/', NULL, 'review', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Split Jump / قفز سبليت', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0cf7ed1a-32bf-4c6c-9fea-8b72c23dac60', 'Lateral Cone Jumps', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Calves / البطات"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'أخرى', 'متوسط', 'منزل', NULL, 'ملاحظات مهمة:
• اقفز جانبياً فوق الحواجز بتحكم
• هبوط ناعم وركبتان مثنيتان
• حافظ على الجسم متزناً
• مسافة آمنة', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/120/lateral-cone-jumps/', NULL, 'review', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Lateral Jump / قفز جانبي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('365b2793-cfeb-49af-a9b2-9a3e501fb522', 'Forward Linear Jumps', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Hamstrings / الخلفية"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متوسط', 'منزل', NULL, 'ملاحظات مهمة:
• اقفز للأمام بانفجار وهبوط ناعم
• ركبتان باتجاه الأصابع
• حافظ على توازنك قبل القفزة التالية
• مسافات قصيرة في البداية', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/177/forward-linear-jumps/', NULL, 'review', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Horizontal Jump / قفز أمامي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b60c8cfb-5d08-449e-a434-0b6bf2f7a138', 'Jogging', 'CrossFit / كروس فت', '{"Quadriceps / الأمامية","Hamstrings / الخلفية","Calves / البطات"}', 'Locomotion / مشي وجري ودفع', 'كارديو', 'وزن الجسم', 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• ابدأ بإحماء تدريجي وخطوات خفيفة
• جذع مستقيم وكتفان مرتخيان
• زد السرعة والمسافة تدريجياً
• حذاء مناسب', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Running / جري', 'Gait: Alternating Hip/Knee Extension / نمط المشي والجري', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('34afce1e-d9de-46d8-8c01-db47660e5afe', 'Wall Ball', 'CrossFit / كروس فت', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Shoulders / الأكتاف"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'أخرى', 'متوسط', 'نادي', NULL, 'ملاحظات مهمة:
• سكوات ثم رمي الكرة على الهدف بانفجار
• ابدأ بوزن خفيف
• استقبل الكرة بذراعين مرنتين
• ركبتان باتجاه الأصابع', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Squat to Throw / سكوات مع رمي', 'Knee/Hip Extension + Shoulder Flexion / مد الركبة والورك + ثني الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('dbbefc75-074e-493e-9ceb-b0a5d07e1bda', 'Snatch', 'CrossFit / كروس فت', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Shoulders / الأكتاف"}', 'Olympic Lift (Triple Extension) / رفعات أولمبية (بسط ثلاثي)', 'قدرة', 'بار', 'متقدم', 'منزل', NULL, 'ملاحظات مهمة:
• تقنية معقدة، تعلّمها بعصا أو وزن خفيف وبإشراف مدرب
• البار قريب من الجسم
• الدفع من الورك والركبة والكاحل
• ظهر محايد', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Snatch / سناتش', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fa7ebcfd-0904-463c-a85a-1712e09cf236', 'Clean', 'CrossFit / كروس فت', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Quadriceps / الأمامية"}', 'Olympic Lift (Triple Extension) / رفعات أولمبية (بسط ثلاثي)', 'قدرة', 'بار', 'متقدم', 'منزل', NULL, 'ملاحظات مهمة:
• تقنية معقدة، ابدأ بوزن خفيف وبإشراف مدرب
• الدفع من الورك ثم استقبال البار بمرفقين عاليين
• البار قريب من الجسم
• ظهر محايد', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Clean / كلين', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4e113937-bc8a-4a76-8e6a-9c5f8aaa17af', 'Turkish Get-Up', 'Functional / التمارين الوظيفية', '{"Shoulders / الأكتاف","Core / البطن والكور","Glutes / المؤخرة"}', 'Full-body Integrated / حركة متكاملة للجسم', 'قوة', 'كيتلبل', 'متقدم', 'منزل', 'https://www.youtube.com/watch?v=0bWRPC49-KI', 'ملاحظات مهمة:
• تحرك بخطوات واضحة وعيناك على الوزن
• الذراع عمودية فوقك طوال الحركة
• ابدأ بدون وزن
• حركة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Turkish Get-Up / النهوض التركي', 'Multi-joint Integrated / حركة متعددة المفاصل', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f3dfc00d-056e-4a51-8e84-c6f5a82277ec', 'Sled Pull/Push', 'Functional / التمارين الوظيفية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Calves / البطات"}', 'Locomotion / مشي وجري ودفع', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://www.youtube.com/watch?v=3KWK7SIdPz4', 'ملاحظات مهمة:
• جذع ثابت مائل للأمام
• خطوات قوية متتالية
• تنفس منتظم
• وزن يسمح بالحفاظ على الوضعية', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Sled Push / Pull / دفع وسحب الزلاجة', 'Hip/Knee Extension in Gait / بسط الورك والركبة بنمط المشي', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f84d66c2-024f-454b-aea1-a931ccbc447e', 'Farmer’s Walk', 'Functional / التمارين الوظيفية', '{"Forearms / الساعد","Core / البطن والكور","Back & Lats / الظهر واللاتس"}', 'Loaded Carry / حمل ومشي', 'قوة', NULL, 'مبتدئ', 'منزل', 'https://www.youtube.com/watch?v=hx24PM6gXs8', 'ملاحظات مهمة:
• قبضة قوية وكتفان للخلف
• جذع مستقيم وخطوات قصيرة
• شد البطن
• لا تتمايل', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Farmer''s Walk / مشي المزارع', 'Isometric Trunk + Grip Under Load / تثبيت الجذع والقبضة أثناء المشي', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('18901064-b1a7-4a02-a99b-48bb3ac9470b', '90s Transition', 'Functional / التمارين الوظيفية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'منزل', 'https://www.youtube.com/watch?v=ogU-azeGe_k', 'ملاحظات مهمة:
• اجلس بزاوية 90° للورك والركبة وانتقل بتحكم
• جذع مستقيم
• حركة بطيئة ضمن مدى مريح
• لا تفرض المدى', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Hip Rotation Mobility (90/90) / مرونة دوران الورك', 'Hip Internal/External Rotation / دوران الورك الداخلي والخارجي', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1dd715a7-ded4-4f72-9138-644b91c31a55', 'Kettlebell Swing', 'Functional / التمارين الوظيفية', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Core / البطن والكور"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قدرة', 'كيتلبل', 'متوسط', 'منزل', 'https://www.youtube.com/watch?v=d94xX-AQZ0A', 'ملاحظات مهمة:
• ادفع الورك للأمام بانفجار ولا ترفع الكيتلبل بالذراعين
• ظهر محايد وركبتان مثنيتان قليلاً
• شد الألوية في الأعلى
• الكيتلبل يعود بين الساقين بتحكم', 'نفس التمرين ورد أيضاً تحت التصنيف «CrossFit» (صف المصدر 168)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Ballistic Hinge (Swing) / مفصلة انفجارية (سوينق)', 'Hip Extension (Ballistic) / بسط الورك الانفجاري', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('16041e30-ccf2-4ae1-8133-e6a6c3d875dc', 'Serratus Punches Supine', 'Functional / التمارين الوظيفية', '{"Shoulders / الأكتاف","Chest / الصدر"}', 'Horizontal Push / دفع أفقي', 'قوة', NULL, 'متوسط', 'منزل', 'https://youtu.be/cxaAqmdlrgk?si=2YRAIgFFXPAvDadG', 'ملاحظات مهمة:
• استلقِ والذراعان نحو السقف
• ادفع الكتف للأعلى بحركة لوح الكتف دون ثني المرفق
• حركة صغيرة بتحكم
• لا ترفع الرأس', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'Scapular Protraction / دفع لوح الكتف', 'Scapular Protraction / دفع لوح الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;



INSERT INTO public.exercise_alternatives VALUES ('bbd65866-6cf4-4822-afaf-a511bd30ad19', '0c3353e7-5cc0-498c-9378-b02b6c3ddda6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bbd65866-6cf4-4822-afaf-a511bd30ad19', 'd863a32c-694d-4190-b844-f8242ee7db4d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bbd65866-6cf4-4822-afaf-a511bd30ad19', 'ae3ba584-acf3-49a1-ac72-0ee6ed51f66c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bbd65866-6cf4-4822-afaf-a511bd30ad19', '94635f06-5bc4-4fc0-8c2d-9e7408fc7002', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bbd65866-6cf4-4822-afaf-a511bd30ad19', 'bb38965f-fd8d-4916-82ed-00b61e409366', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c3353e7-5cc0-498c-9378-b02b6c3ddda6', 'bbd65866-6cf4-4822-afaf-a511bd30ad19', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c3353e7-5cc0-498c-9378-b02b6c3ddda6', 'd863a32c-694d-4190-b844-f8242ee7db4d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c3353e7-5cc0-498c-9378-b02b6c3ddda6', 'ae3ba584-acf3-49a1-ac72-0ee6ed51f66c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c3353e7-5cc0-498c-9378-b02b6c3ddda6', '94635f06-5bc4-4fc0-8c2d-9e7408fc7002', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c3353e7-5cc0-498c-9378-b02b6c3ddda6', 'bb38965f-fd8d-4916-82ed-00b61e409366', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5a0ccb0d-b9df-4ba2-a32f-26da46e744e5', 'c158a260-f51e-4615-a22f-babe5a4c93ae', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5a0ccb0d-b9df-4ba2-a32f-26da46e744e5', '470e98d3-e4db-4c2a-abfa-13cdcab1f5f8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5a0ccb0d-b9df-4ba2-a32f-26da46e744e5', 'bbd65866-6cf4-4822-afaf-a511bd30ad19', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5a0ccb0d-b9df-4ba2-a32f-26da46e744e5', '0c3353e7-5cc0-498c-9378-b02b6c3ddda6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5a0ccb0d-b9df-4ba2-a32f-26da46e744e5', '475de381-73a9-4722-8a6b-1b0094ec0a56', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('475de381-73a9-4722-8a6b-1b0094ec0a56', 'c608fd63-f37b-4181-a02f-a1846809b393', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('475de381-73a9-4722-8a6b-1b0094ec0a56', 'bbd65866-6cf4-4822-afaf-a511bd30ad19', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('475de381-73a9-4722-8a6b-1b0094ec0a56', '0c3353e7-5cc0-498c-9378-b02b6c3ddda6', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('475de381-73a9-4722-8a6b-1b0094ec0a56', '5a0ccb0d-b9df-4ba2-a32f-26da46e744e5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('475de381-73a9-4722-8a6b-1b0094ec0a56', 'd863a32c-694d-4190-b844-f8242ee7db4d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c608fd63-f37b-4181-a02f-a1846809b393', '475de381-73a9-4722-8a6b-1b0094ec0a56', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c608fd63-f37b-4181-a02f-a1846809b393', 'bbd65866-6cf4-4822-afaf-a511bd30ad19', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c608fd63-f37b-4181-a02f-a1846809b393', '0c3353e7-5cc0-498c-9378-b02b6c3ddda6', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c608fd63-f37b-4181-a02f-a1846809b393', '5a0ccb0d-b9df-4ba2-a32f-26da46e744e5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c608fd63-f37b-4181-a02f-a1846809b393', 'd863a32c-694d-4190-b844-f8242ee7db4d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d863a32c-694d-4190-b844-f8242ee7db4d', 'bbd65866-6cf4-4822-afaf-a511bd30ad19', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d863a32c-694d-4190-b844-f8242ee7db4d', '0c3353e7-5cc0-498c-9378-b02b6c3ddda6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d863a32c-694d-4190-b844-f8242ee7db4d', 'ae3ba584-acf3-49a1-ac72-0ee6ed51f66c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d863a32c-694d-4190-b844-f8242ee7db4d', '94635f06-5bc4-4fc0-8c2d-9e7408fc7002', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d863a32c-694d-4190-b844-f8242ee7db4d', 'bb38965f-fd8d-4916-82ed-00b61e409366', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ae3ba584-acf3-49a1-ac72-0ee6ed51f66c', 'bbd65866-6cf4-4822-afaf-a511bd30ad19', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ae3ba584-acf3-49a1-ac72-0ee6ed51f66c', '0c3353e7-5cc0-498c-9378-b02b6c3ddda6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ae3ba584-acf3-49a1-ac72-0ee6ed51f66c', 'd863a32c-694d-4190-b844-f8242ee7db4d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ae3ba584-acf3-49a1-ac72-0ee6ed51f66c', '94635f06-5bc4-4fc0-8c2d-9e7408fc7002', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ae3ba584-acf3-49a1-ac72-0ee6ed51f66c', 'bb38965f-fd8d-4916-82ed-00b61e409366', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c158a260-f51e-4615-a22f-babe5a4c93ae', '5a0ccb0d-b9df-4ba2-a32f-26da46e744e5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c158a260-f51e-4615-a22f-babe5a4c93ae', '470e98d3-e4db-4c2a-abfa-13cdcab1f5f8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c158a260-f51e-4615-a22f-babe5a4c93ae', 'bbd65866-6cf4-4822-afaf-a511bd30ad19', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c158a260-f51e-4615-a22f-babe5a4c93ae', '0c3353e7-5cc0-498c-9378-b02b6c3ddda6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c158a260-f51e-4615-a22f-babe5a4c93ae', '475de381-73a9-4722-8a6b-1b0094ec0a56', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('94635f06-5bc4-4fc0-8c2d-9e7408fc7002', 'bbd65866-6cf4-4822-afaf-a511bd30ad19', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('94635f06-5bc4-4fc0-8c2d-9e7408fc7002', '0c3353e7-5cc0-498c-9378-b02b6c3ddda6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('94635f06-5bc4-4fc0-8c2d-9e7408fc7002', 'd863a32c-694d-4190-b844-f8242ee7db4d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('94635f06-5bc4-4fc0-8c2d-9e7408fc7002', 'ae3ba584-acf3-49a1-ac72-0ee6ed51f66c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('94635f06-5bc4-4fc0-8c2d-9e7408fc7002', 'bb38965f-fd8d-4916-82ed-00b61e409366', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('470e98d3-e4db-4c2a-abfa-13cdcab1f5f8', '5a0ccb0d-b9df-4ba2-a32f-26da46e744e5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('470e98d3-e4db-4c2a-abfa-13cdcab1f5f8', 'c158a260-f51e-4615-a22f-babe5a4c93ae', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('470e98d3-e4db-4c2a-abfa-13cdcab1f5f8', 'bbd65866-6cf4-4822-afaf-a511bd30ad19', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('470e98d3-e4db-4c2a-abfa-13cdcab1f5f8', '0c3353e7-5cc0-498c-9378-b02b6c3ddda6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('470e98d3-e4db-4c2a-abfa-13cdcab1f5f8', '475de381-73a9-4722-8a6b-1b0094ec0a56', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5870ec67-f436-469d-bc6f-4b69162db8a9', '607cb44a-4431-4005-91ad-8c20f007ec56', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5870ec67-f436-469d-bc6f-4b69162db8a9', 'd3ec1ff6-2660-4c60-9a8f-1b8e29630963', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5870ec67-f436-469d-bc6f-4b69162db8a9', 'd5ed6197-5daa-463e-8024-9258344d973e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5870ec67-f436-469d-bc6f-4b69162db8a9', 'a6229455-c50c-4d3a-af50-56a54127703d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5870ec67-f436-469d-bc6f-4b69162db8a9', '2a591130-36e5-44ea-817d-28c433989b38', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('607cb44a-4431-4005-91ad-8c20f007ec56', 'd3ec1ff6-2660-4c60-9a8f-1b8e29630963', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('607cb44a-4431-4005-91ad-8c20f007ec56', 'd5ed6197-5daa-463e-8024-9258344d973e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('607cb44a-4431-4005-91ad-8c20f007ec56', '2a591130-36e5-44ea-817d-28c433989b38', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('607cb44a-4431-4005-91ad-8c20f007ec56', '84ba0a07-b6d4-40a5-bd8d-c6800fb10fd5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('607cb44a-4431-4005-91ad-8c20f007ec56', '5870ec67-f436-469d-bc6f-4b69162db8a9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3ec1ff6-2660-4c60-9a8f-1b8e29630963', '607cb44a-4431-4005-91ad-8c20f007ec56', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3ec1ff6-2660-4c60-9a8f-1b8e29630963', 'd5ed6197-5daa-463e-8024-9258344d973e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3ec1ff6-2660-4c60-9a8f-1b8e29630963', '2a591130-36e5-44ea-817d-28c433989b38', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3ec1ff6-2660-4c60-9a8f-1b8e29630963', '84ba0a07-b6d4-40a5-bd8d-c6800fb10fd5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3ec1ff6-2660-4c60-9a8f-1b8e29630963', '5870ec67-f436-469d-bc6f-4b69162db8a9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d5ed6197-5daa-463e-8024-9258344d973e', '607cb44a-4431-4005-91ad-8c20f007ec56', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d5ed6197-5daa-463e-8024-9258344d973e', 'd3ec1ff6-2660-4c60-9a8f-1b8e29630963', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d5ed6197-5daa-463e-8024-9258344d973e', '2a591130-36e5-44ea-817d-28c433989b38', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d5ed6197-5daa-463e-8024-9258344d973e', '84ba0a07-b6d4-40a5-bd8d-c6800fb10fd5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d5ed6197-5daa-463e-8024-9258344d973e', '5870ec67-f436-469d-bc6f-4b69162db8a9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6229455-c50c-4d3a-af50-56a54127703d', '5870ec67-f436-469d-bc6f-4b69162db8a9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6229455-c50c-4d3a-af50-56a54127703d', '607cb44a-4431-4005-91ad-8c20f007ec56', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6229455-c50c-4d3a-af50-56a54127703d', 'd3ec1ff6-2660-4c60-9a8f-1b8e29630963', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6229455-c50c-4d3a-af50-56a54127703d', 'd5ed6197-5daa-463e-8024-9258344d973e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6229455-c50c-4d3a-af50-56a54127703d', '2a591130-36e5-44ea-817d-28c433989b38', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2a591130-36e5-44ea-817d-28c433989b38', '607cb44a-4431-4005-91ad-8c20f007ec56', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2a591130-36e5-44ea-817d-28c433989b38', 'd3ec1ff6-2660-4c60-9a8f-1b8e29630963', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2a591130-36e5-44ea-817d-28c433989b38', 'd5ed6197-5daa-463e-8024-9258344d973e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2a591130-36e5-44ea-817d-28c433989b38', '84ba0a07-b6d4-40a5-bd8d-c6800fb10fd5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2a591130-36e5-44ea-817d-28c433989b38', '5870ec67-f436-469d-bc6f-4b69162db8a9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84ba0a07-b6d4-40a5-bd8d-c6800fb10fd5', '607cb44a-4431-4005-91ad-8c20f007ec56', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84ba0a07-b6d4-40a5-bd8d-c6800fb10fd5', 'd3ec1ff6-2660-4c60-9a8f-1b8e29630963', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84ba0a07-b6d4-40a5-bd8d-c6800fb10fd5', 'd5ed6197-5daa-463e-8024-9258344d973e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84ba0a07-b6d4-40a5-bd8d-c6800fb10fd5', '2a591130-36e5-44ea-817d-28c433989b38', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84ba0a07-b6d4-40a5-bd8d-c6800fb10fd5', '5870ec67-f436-469d-bc6f-4b69162db8a9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7d57c4d-be28-4ffd-8e36-364b41756dec', '19a95d1c-0c4a-4575-a4a7-cb4ad93f0af4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7d57c4d-be28-4ffd-8e36-364b41756dec', 'c04f4b86-4961-4cfd-bbae-da2cd9e52372', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7d57c4d-be28-4ffd-8e36-364b41756dec', 'c9ad1f47-c29b-43bf-bd95-967336bdb165', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7d57c4d-be28-4ffd-8e36-364b41756dec', 'de7c5c4c-e640-4d3a-bdee-791c40e664f5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7d57c4d-be28-4ffd-8e36-364b41756dec', 'f5d34dbb-0e9c-4efa-8619-7536c5d47a35', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19a95d1c-0c4a-4575-a4a7-cb4ad93f0af4', 'b7d57c4d-be28-4ffd-8e36-364b41756dec', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19a95d1c-0c4a-4575-a4a7-cb4ad93f0af4', 'c04f4b86-4961-4cfd-bbae-da2cd9e52372', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19a95d1c-0c4a-4575-a4a7-cb4ad93f0af4', 'c9ad1f47-c29b-43bf-bd95-967336bdb165', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19a95d1c-0c4a-4575-a4a7-cb4ad93f0af4', 'de7c5c4c-e640-4d3a-bdee-791c40e664f5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19a95d1c-0c4a-4575-a4a7-cb4ad93f0af4', 'f5d34dbb-0e9c-4efa-8619-7536c5d47a35', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c04f4b86-4961-4cfd-bbae-da2cd9e52372', 'b7d57c4d-be28-4ffd-8e36-364b41756dec', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c04f4b86-4961-4cfd-bbae-da2cd9e52372', '19a95d1c-0c4a-4575-a4a7-cb4ad93f0af4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c04f4b86-4961-4cfd-bbae-da2cd9e52372', 'c9ad1f47-c29b-43bf-bd95-967336bdb165', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c04f4b86-4961-4cfd-bbae-da2cd9e52372', 'de7c5c4c-e640-4d3a-bdee-791c40e664f5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c04f4b86-4961-4cfd-bbae-da2cd9e52372', 'f5d34dbb-0e9c-4efa-8619-7536c5d47a35', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f5d34dbb-0e9c-4efa-8619-7536c5d47a35', 'b7d57c4d-be28-4ffd-8e36-364b41756dec', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f5d34dbb-0e9c-4efa-8619-7536c5d47a35', '19a95d1c-0c4a-4575-a4a7-cb4ad93f0af4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f5d34dbb-0e9c-4efa-8619-7536c5d47a35', 'c04f4b86-4961-4cfd-bbae-da2cd9e52372', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f5d34dbb-0e9c-4efa-8619-7536c5d47a35', 'c9ad1f47-c29b-43bf-bd95-967336bdb165', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f5d34dbb-0e9c-4efa-8619-7536c5d47a35', 'de7c5c4c-e640-4d3a-bdee-791c40e664f5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9ad1f47-c29b-43bf-bd95-967336bdb165', 'b7d57c4d-be28-4ffd-8e36-364b41756dec', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9ad1f47-c29b-43bf-bd95-967336bdb165', '19a95d1c-0c4a-4575-a4a7-cb4ad93f0af4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9ad1f47-c29b-43bf-bd95-967336bdb165', 'c04f4b86-4961-4cfd-bbae-da2cd9e52372', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9ad1f47-c29b-43bf-bd95-967336bdb165', 'de7c5c4c-e640-4d3a-bdee-791c40e664f5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9ad1f47-c29b-43bf-bd95-967336bdb165', 'f5d34dbb-0e9c-4efa-8619-7536c5d47a35', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('de7c5c4c-e640-4d3a-bdee-791c40e664f5', 'b7d57c4d-be28-4ffd-8e36-364b41756dec', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('de7c5c4c-e640-4d3a-bdee-791c40e664f5', '19a95d1c-0c4a-4575-a4a7-cb4ad93f0af4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('de7c5c4c-e640-4d3a-bdee-791c40e664f5', 'c04f4b86-4961-4cfd-bbae-da2cd9e52372', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('de7c5c4c-e640-4d3a-bdee-791c40e664f5', 'c9ad1f47-c29b-43bf-bd95-967336bdb165', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('de7c5c4c-e640-4d3a-bdee-791c40e664f5', 'f5d34dbb-0e9c-4efa-8619-7536c5d47a35', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bb38965f-fd8d-4916-82ed-00b61e409366', 'bbd65866-6cf4-4822-afaf-a511bd30ad19', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bb38965f-fd8d-4916-82ed-00b61e409366', '0c3353e7-5cc0-498c-9378-b02b6c3ddda6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bb38965f-fd8d-4916-82ed-00b61e409366', 'd863a32c-694d-4190-b844-f8242ee7db4d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bb38965f-fd8d-4916-82ed-00b61e409366', 'ae3ba584-acf3-49a1-ac72-0ee6ed51f66c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bb38965f-fd8d-4916-82ed-00b61e409366', '94635f06-5bc4-4fc0-8c2d-9e7408fc7002', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4010faf7-0c1a-4134-ad5d-d6936c36b338', '5870ec67-f436-469d-bc6f-4b69162db8a9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4010faf7-0c1a-4134-ad5d-d6936c36b338', '607cb44a-4431-4005-91ad-8c20f007ec56', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4010faf7-0c1a-4134-ad5d-d6936c36b338', 'd3ec1ff6-2660-4c60-9a8f-1b8e29630963', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4010faf7-0c1a-4134-ad5d-d6936c36b338', 'd5ed6197-5daa-463e-8024-9258344d973e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4010faf7-0c1a-4134-ad5d-d6936c36b338', 'a6229455-c50c-4d3a-af50-56a54127703d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b67445f7-e786-441c-94a6-a6a8bb8aa968', '954a965a-ffea-40b5-890e-4abf6d9fa58c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b67445f7-e786-441c-94a6-a6a8bb8aa968', '8307a5df-f598-4264-b357-76c390ae3504', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b67445f7-e786-441c-94a6-a6a8bb8aa968', 'aed244cc-2c21-47ed-82c0-fbba42ceec78', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('954a965a-ffea-40b5-890e-4abf6d9fa58c', 'b67445f7-e786-441c-94a6-a6a8bb8aa968', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('954a965a-ffea-40b5-890e-4abf6d9fa58c', '8307a5df-f598-4264-b357-76c390ae3504', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('954a965a-ffea-40b5-890e-4abf6d9fa58c', 'aed244cc-2c21-47ed-82c0-fbba42ceec78', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8307a5df-f598-4264-b357-76c390ae3504', 'b67445f7-e786-441c-94a6-a6a8bb8aa968', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8307a5df-f598-4264-b357-76c390ae3504', '954a965a-ffea-40b5-890e-4abf6d9fa58c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8307a5df-f598-4264-b357-76c390ae3504', 'aed244cc-2c21-47ed-82c0-fbba42ceec78', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aed244cc-2c21-47ed-82c0-fbba42ceec78', 'b67445f7-e786-441c-94a6-a6a8bb8aa968', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aed244cc-2c21-47ed-82c0-fbba42ceec78', '954a965a-ffea-40b5-890e-4abf6d9fa58c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aed244cc-2c21-47ed-82c0-fbba42ceec78', '8307a5df-f598-4264-b357-76c390ae3504', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e88fb0d8-f7d8-4e95-a755-2cc8f545cea5', '3a61149c-2f6e-4800-9756-e3c2913764eb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e88fb0d8-f7d8-4e95-a755-2cc8f545cea5', '86330e7d-8a6b-4a54-80d3-fdc33aa979f1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e88fb0d8-f7d8-4e95-a755-2cc8f545cea5', 'e1bad5f9-8d55-4672-9fa6-a949fd82fef1', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e88fb0d8-f7d8-4e95-a755-2cc8f545cea5', '4445dc05-6894-4599-912d-7584646d6e92', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e88fb0d8-f7d8-4e95-a755-2cc8f545cea5', '87a6c696-351a-4f72-b8a0-41b2105484d2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f802dc53-7dae-4c8e-88f9-205160433a9e', 'a48a919c-0706-40a4-a50c-2121fea51f04', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f802dc53-7dae-4c8e-88f9-205160433a9e', 'b6cbf67a-fe33-4ced-92f1-1a006023acd9', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f802dc53-7dae-4c8e-88f9-205160433a9e', '93c5bc26-50c9-4d10-b9d8-dc8d9f68a313', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f802dc53-7dae-4c8e-88f9-205160433a9e', 'f60c851d-270b-4ca5-83d9-c6e4e88902dd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f802dc53-7dae-4c8e-88f9-205160433a9e', '0fd85dca-eb00-48fb-9d8d-6af147bda7cd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a61149c-2f6e-4800-9756-e3c2913764eb', 'e88fb0d8-f7d8-4e95-a755-2cc8f545cea5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a61149c-2f6e-4800-9756-e3c2913764eb', '86330e7d-8a6b-4a54-80d3-fdc33aa979f1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a61149c-2f6e-4800-9756-e3c2913764eb', 'e1bad5f9-8d55-4672-9fa6-a949fd82fef1', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a61149c-2f6e-4800-9756-e3c2913764eb', '4445dc05-6894-4599-912d-7584646d6e92', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a61149c-2f6e-4800-9756-e3c2913764eb', '87a6c696-351a-4f72-b8a0-41b2105484d2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f60c851d-270b-4ca5-83d9-c6e4e88902dd', 'f802dc53-7dae-4c8e-88f9-205160433a9e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f60c851d-270b-4ca5-83d9-c6e4e88902dd', 'a48a919c-0706-40a4-a50c-2121fea51f04', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f60c851d-270b-4ca5-83d9-c6e4e88902dd', 'b6cbf67a-fe33-4ced-92f1-1a006023acd9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f60c851d-270b-4ca5-83d9-c6e4e88902dd', '93c5bc26-50c9-4d10-b9d8-dc8d9f68a313', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f60c851d-270b-4ca5-83d9-c6e4e88902dd', '0fd85dca-eb00-48fb-9d8d-6af147bda7cd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b9d4cbe9-d6a1-449b-a1b0-e20d2ffaa286', 'b67445f7-e786-441c-94a6-a6a8bb8aa968', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b9d4cbe9-d6a1-449b-a1b0-e20d2ffaa286', '954a965a-ffea-40b5-890e-4abf6d9fa58c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b9d4cbe9-d6a1-449b-a1b0-e20d2ffaa286', '8307a5df-f598-4264-b357-76c390ae3504', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b9d4cbe9-d6a1-449b-a1b0-e20d2ffaa286', 'aed244cc-2c21-47ed-82c0-fbba42ceec78', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e1bad5f9-8d55-4672-9fa6-a949fd82fef1', '4445dc05-6894-4599-912d-7584646d6e92', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e1bad5f9-8d55-4672-9fa6-a949fd82fef1', '87a6c696-351a-4f72-b8a0-41b2105484d2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e1bad5f9-8d55-4672-9fa6-a949fd82fef1', 'ca2595b5-10a1-4ceb-8081-ebbe4a9aaa58', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e1bad5f9-8d55-4672-9fa6-a949fd82fef1', 'faaac551-5d58-476b-8049-13e17d3187cf', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e1bad5f9-8d55-4672-9fa6-a949fd82fef1', 'e88fb0d8-f7d8-4e95-a755-2cc8f545cea5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4445dc05-6894-4599-912d-7584646d6e92', 'e1bad5f9-8d55-4672-9fa6-a949fd82fef1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4445dc05-6894-4599-912d-7584646d6e92', '87a6c696-351a-4f72-b8a0-41b2105484d2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4445dc05-6894-4599-912d-7584646d6e92', 'ca2595b5-10a1-4ceb-8081-ebbe4a9aaa58', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4445dc05-6894-4599-912d-7584646d6e92', 'faaac551-5d58-476b-8049-13e17d3187cf', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4445dc05-6894-4599-912d-7584646d6e92', 'e88fb0d8-f7d8-4e95-a755-2cc8f545cea5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('87a6c696-351a-4f72-b8a0-41b2105484d2', 'e1bad5f9-8d55-4672-9fa6-a949fd82fef1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('87a6c696-351a-4f72-b8a0-41b2105484d2', '4445dc05-6894-4599-912d-7584646d6e92', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('87a6c696-351a-4f72-b8a0-41b2105484d2', 'ca2595b5-10a1-4ceb-8081-ebbe4a9aaa58', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('87a6c696-351a-4f72-b8a0-41b2105484d2', 'faaac551-5d58-476b-8049-13e17d3187cf', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('87a6c696-351a-4f72-b8a0-41b2105484d2', 'e88fb0d8-f7d8-4e95-a755-2cc8f545cea5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ca2595b5-10a1-4ceb-8081-ebbe4a9aaa58', 'e1bad5f9-8d55-4672-9fa6-a949fd82fef1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ca2595b5-10a1-4ceb-8081-ebbe4a9aaa58', '4445dc05-6894-4599-912d-7584646d6e92', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ca2595b5-10a1-4ceb-8081-ebbe4a9aaa58', '87a6c696-351a-4f72-b8a0-41b2105484d2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ca2595b5-10a1-4ceb-8081-ebbe4a9aaa58', 'faaac551-5d58-476b-8049-13e17d3187cf', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ca2595b5-10a1-4ceb-8081-ebbe4a9aaa58', 'e88fb0d8-f7d8-4e95-a755-2cc8f545cea5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('536fd4b0-55d5-46e7-9c7a-2ae48e2309b3', 'e88fb0d8-f7d8-4e95-a755-2cc8f545cea5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('536fd4b0-55d5-46e7-9c7a-2ae48e2309b3', '3a61149c-2f6e-4800-9756-e3c2913764eb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('536fd4b0-55d5-46e7-9c7a-2ae48e2309b3', 'e1bad5f9-8d55-4672-9fa6-a949fd82fef1', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('536fd4b0-55d5-46e7-9c7a-2ae48e2309b3', '4445dc05-6894-4599-912d-7584646d6e92', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('536fd4b0-55d5-46e7-9c7a-2ae48e2309b3', '87a6c696-351a-4f72-b8a0-41b2105484d2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('faaac551-5d58-476b-8049-13e17d3187cf', 'e1bad5f9-8d55-4672-9fa6-a949fd82fef1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('faaac551-5d58-476b-8049-13e17d3187cf', '4445dc05-6894-4599-912d-7584646d6e92', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('faaac551-5d58-476b-8049-13e17d3187cf', '87a6c696-351a-4f72-b8a0-41b2105484d2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('faaac551-5d58-476b-8049-13e17d3187cf', 'ca2595b5-10a1-4ceb-8081-ebbe4a9aaa58', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('faaac551-5d58-476b-8049-13e17d3187cf', 'e88fb0d8-f7d8-4e95-a755-2cc8f545cea5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('86330e7d-8a6b-4a54-80d3-fdc33aa979f1', 'e88fb0d8-f7d8-4e95-a755-2cc8f545cea5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('86330e7d-8a6b-4a54-80d3-fdc33aa979f1', '3a61149c-2f6e-4800-9756-e3c2913764eb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('86330e7d-8a6b-4a54-80d3-fdc33aa979f1', 'e1bad5f9-8d55-4672-9fa6-a949fd82fef1', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('86330e7d-8a6b-4a54-80d3-fdc33aa979f1', '4445dc05-6894-4599-912d-7584646d6e92', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('86330e7d-8a6b-4a54-80d3-fdc33aa979f1', '87a6c696-351a-4f72-b8a0-41b2105484d2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('27e4b438-ea37-4149-8b8b-7e03abc869db', 'b67445f7-e786-441c-94a6-a6a8bb8aa968', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('27e4b438-ea37-4149-8b8b-7e03abc869db', '954a965a-ffea-40b5-890e-4abf6d9fa58c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('27e4b438-ea37-4149-8b8b-7e03abc869db', '8307a5df-f598-4264-b357-76c390ae3504', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('27e4b438-ea37-4149-8b8b-7e03abc869db', 'aed244cc-2c21-47ed-82c0-fbba42ceec78', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a62bfe7-ab3c-4e0e-aab5-8d74855fd9bf', '3721b848-c7b5-4ba3-9a05-4a7531ef5280', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a62bfe7-ab3c-4e0e-aab5-8d74855fd9bf', '2b601da3-be55-44c5-995e-4b1ff113c36e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a62bfe7-ab3c-4e0e-aab5-8d74855fd9bf', '3a0bb214-545b-432f-86ed-434995892b11', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a62bfe7-ab3c-4e0e-aab5-8d74855fd9bf', '21f2a83a-dd84-4848-8e46-13dfe0b3421c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a62bfe7-ab3c-4e0e-aab5-8d74855fd9bf', 'f4a7068d-7999-475e-b939-a09f70f64ced', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8a115e62-4bff-4096-b465-3c9893da7266', '3721b848-c7b5-4ba3-9a05-4a7531ef5280', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8a115e62-4bff-4096-b465-3c9893da7266', '2b601da3-be55-44c5-995e-4b1ff113c36e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8a115e62-4bff-4096-b465-3c9893da7266', '3a0bb214-545b-432f-86ed-434995892b11', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8a115e62-4bff-4096-b465-3c9893da7266', '21f2a83a-dd84-4848-8e46-13dfe0b3421c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8a115e62-4bff-4096-b465-3c9893da7266', 'f4a7068d-7999-475e-b939-a09f70f64ced', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3721b848-c7b5-4ba3-9a05-4a7531ef5280', '2b601da3-be55-44c5-995e-4b1ff113c36e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3721b848-c7b5-4ba3-9a05-4a7531ef5280', '3a0bb214-545b-432f-86ed-434995892b11', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3721b848-c7b5-4ba3-9a05-4a7531ef5280', '21f2a83a-dd84-4848-8e46-13dfe0b3421c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3721b848-c7b5-4ba3-9a05-4a7531ef5280', 'f4a7068d-7999-475e-b939-a09f70f64ced', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3721b848-c7b5-4ba3-9a05-4a7531ef5280', '604fe75b-018e-4fb2-819f-9daa4c8ef639', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2b601da3-be55-44c5-995e-4b1ff113c36e', '3721b848-c7b5-4ba3-9a05-4a7531ef5280', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2b601da3-be55-44c5-995e-4b1ff113c36e', '3a0bb214-545b-432f-86ed-434995892b11', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2b601da3-be55-44c5-995e-4b1ff113c36e', '21f2a83a-dd84-4848-8e46-13dfe0b3421c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2b601da3-be55-44c5-995e-4b1ff113c36e', 'f4a7068d-7999-475e-b939-a09f70f64ced', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2b601da3-be55-44c5-995e-4b1ff113c36e', '604fe75b-018e-4fb2-819f-9daa4c8ef639', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a0bb214-545b-432f-86ed-434995892b11', '3721b848-c7b5-4ba3-9a05-4a7531ef5280', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a0bb214-545b-432f-86ed-434995892b11', '2b601da3-be55-44c5-995e-4b1ff113c36e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a0bb214-545b-432f-86ed-434995892b11', '21f2a83a-dd84-4848-8e46-13dfe0b3421c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a0bb214-545b-432f-86ed-434995892b11', 'f4a7068d-7999-475e-b939-a09f70f64ced', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3a0bb214-545b-432f-86ed-434995892b11', '604fe75b-018e-4fb2-819f-9daa4c8ef639', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('21f2a83a-dd84-4848-8e46-13dfe0b3421c', '3721b848-c7b5-4ba3-9a05-4a7531ef5280', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('21f2a83a-dd84-4848-8e46-13dfe0b3421c', '2b601da3-be55-44c5-995e-4b1ff113c36e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('21f2a83a-dd84-4848-8e46-13dfe0b3421c', '3a0bb214-545b-432f-86ed-434995892b11', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('21f2a83a-dd84-4848-8e46-13dfe0b3421c', 'f4a7068d-7999-475e-b939-a09f70f64ced', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('21f2a83a-dd84-4848-8e46-13dfe0b3421c', '604fe75b-018e-4fb2-819f-9daa4c8ef639', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f4a7068d-7999-475e-b939-a09f70f64ced', '3721b848-c7b5-4ba3-9a05-4a7531ef5280', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f4a7068d-7999-475e-b939-a09f70f64ced', '2b601da3-be55-44c5-995e-4b1ff113c36e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f4a7068d-7999-475e-b939-a09f70f64ced', '3a0bb214-545b-432f-86ed-434995892b11', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f4a7068d-7999-475e-b939-a09f70f64ced', '21f2a83a-dd84-4848-8e46-13dfe0b3421c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f4a7068d-7999-475e-b939-a09f70f64ced', '604fe75b-018e-4fb2-819f-9daa4c8ef639', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('604fe75b-018e-4fb2-819f-9daa4c8ef639', '3721b848-c7b5-4ba3-9a05-4a7531ef5280', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('604fe75b-018e-4fb2-819f-9daa4c8ef639', '2b601da3-be55-44c5-995e-4b1ff113c36e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('604fe75b-018e-4fb2-819f-9daa4c8ef639', '3a0bb214-545b-432f-86ed-434995892b11', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('604fe75b-018e-4fb2-819f-9daa4c8ef639', '21f2a83a-dd84-4848-8e46-13dfe0b3421c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('604fe75b-018e-4fb2-819f-9daa4c8ef639', 'f4a7068d-7999-475e-b939-a09f70f64ced', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce1b55e3-bb82-408f-8197-db9bee3b4d41', '3721b848-c7b5-4ba3-9a05-4a7531ef5280', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce1b55e3-bb82-408f-8197-db9bee3b4d41', '2b601da3-be55-44c5-995e-4b1ff113c36e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce1b55e3-bb82-408f-8197-db9bee3b4d41', '3a0bb214-545b-432f-86ed-434995892b11', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce1b55e3-bb82-408f-8197-db9bee3b4d41', '21f2a83a-dd84-4848-8e46-13dfe0b3421c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce1b55e3-bb82-408f-8197-db9bee3b4d41', 'f4a7068d-7999-475e-b939-a09f70f64ced', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('35f18e4e-da4b-45f7-9d8c-c11884b29d9b', 'fa81f5e7-2364-4410-9310-461c9eb5f05a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('35f18e4e-da4b-45f7-9d8c-c11884b29d9b', 'b2953191-2fba-4625-85ee-e7c2f4810ec8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('35f18e4e-da4b-45f7-9d8c-c11884b29d9b', '9f2d473d-4cec-4ade-bbcf-568dfdc47981', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('35f18e4e-da4b-45f7-9d8c-c11884b29d9b', '1c7b6f58-68a0-48e1-b54f-b9980ce94c96', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('35f18e4e-da4b-45f7-9d8c-c11884b29d9b', '21ac47f6-4cdf-4d7f-b637-4d3ce9c54f1a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fa81f5e7-2364-4410-9310-461c9eb5f05a', '35f18e4e-da4b-45f7-9d8c-c11884b29d9b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fa81f5e7-2364-4410-9310-461c9eb5f05a', 'b2953191-2fba-4625-85ee-e7c2f4810ec8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fa81f5e7-2364-4410-9310-461c9eb5f05a', '9f2d473d-4cec-4ade-bbcf-568dfdc47981', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fa81f5e7-2364-4410-9310-461c9eb5f05a', '1c7b6f58-68a0-48e1-b54f-b9980ce94c96', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fa81f5e7-2364-4410-9310-461c9eb5f05a', '21ac47f6-4cdf-4d7f-b637-4d3ce9c54f1a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b2953191-2fba-4625-85ee-e7c2f4810ec8', '35f18e4e-da4b-45f7-9d8c-c11884b29d9b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b2953191-2fba-4625-85ee-e7c2f4810ec8', 'fa81f5e7-2364-4410-9310-461c9eb5f05a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b2953191-2fba-4625-85ee-e7c2f4810ec8', '9f2d473d-4cec-4ade-bbcf-568dfdc47981', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b2953191-2fba-4625-85ee-e7c2f4810ec8', '1c7b6f58-68a0-48e1-b54f-b9980ce94c96', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b2953191-2fba-4625-85ee-e7c2f4810ec8', '21ac47f6-4cdf-4d7f-b637-4d3ce9c54f1a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9f2d473d-4cec-4ade-bbcf-568dfdc47981', '35f18e4e-da4b-45f7-9d8c-c11884b29d9b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9f2d473d-4cec-4ade-bbcf-568dfdc47981', 'fa81f5e7-2364-4410-9310-461c9eb5f05a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9f2d473d-4cec-4ade-bbcf-568dfdc47981', 'b2953191-2fba-4625-85ee-e7c2f4810ec8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9f2d473d-4cec-4ade-bbcf-568dfdc47981', '1c7b6f58-68a0-48e1-b54f-b9980ce94c96', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9f2d473d-4cec-4ade-bbcf-568dfdc47981', '21ac47f6-4cdf-4d7f-b637-4d3ce9c54f1a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1c7b6f58-68a0-48e1-b54f-b9980ce94c96', '35f18e4e-da4b-45f7-9d8c-c11884b29d9b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1c7b6f58-68a0-48e1-b54f-b9980ce94c96', 'fa81f5e7-2364-4410-9310-461c9eb5f05a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1c7b6f58-68a0-48e1-b54f-b9980ce94c96', 'b2953191-2fba-4625-85ee-e7c2f4810ec8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1c7b6f58-68a0-48e1-b54f-b9980ce94c96', '9f2d473d-4cec-4ade-bbcf-568dfdc47981', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1c7b6f58-68a0-48e1-b54f-b9980ce94c96', '21ac47f6-4cdf-4d7f-b637-4d3ce9c54f1a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('21ac47f6-4cdf-4d7f-b637-4d3ce9c54f1a', '35f18e4e-da4b-45f7-9d8c-c11884b29d9b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('21ac47f6-4cdf-4d7f-b637-4d3ce9c54f1a', 'fa81f5e7-2364-4410-9310-461c9eb5f05a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('21ac47f6-4cdf-4d7f-b637-4d3ce9c54f1a', 'b2953191-2fba-4625-85ee-e7c2f4810ec8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('21ac47f6-4cdf-4d7f-b637-4d3ce9c54f1a', '9f2d473d-4cec-4ade-bbcf-568dfdc47981', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('21ac47f6-4cdf-4d7f-b637-4d3ce9c54f1a', '1c7b6f58-68a0-48e1-b54f-b9980ce94c96', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9fcc8ba0-7d99-4439-b7e0-aa36be834ba7', '35f18e4e-da4b-45f7-9d8c-c11884b29d9b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9fcc8ba0-7d99-4439-b7e0-aa36be834ba7', 'fa81f5e7-2364-4410-9310-461c9eb5f05a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9fcc8ba0-7d99-4439-b7e0-aa36be834ba7', 'b2953191-2fba-4625-85ee-e7c2f4810ec8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9fcc8ba0-7d99-4439-b7e0-aa36be834ba7', '9f2d473d-4cec-4ade-bbcf-568dfdc47981', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9fcc8ba0-7d99-4439-b7e0-aa36be834ba7', '1c7b6f58-68a0-48e1-b54f-b9980ce94c96', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1cd0378e-24da-49cb-bfd2-3e21fc474496', '35f18e4e-da4b-45f7-9d8c-c11884b29d9b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1cd0378e-24da-49cb-bfd2-3e21fc474496', 'fa81f5e7-2364-4410-9310-461c9eb5f05a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1cd0378e-24da-49cb-bfd2-3e21fc474496', 'b2953191-2fba-4625-85ee-e7c2f4810ec8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1cd0378e-24da-49cb-bfd2-3e21fc474496', '9f2d473d-4cec-4ade-bbcf-568dfdc47981', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1cd0378e-24da-49cb-bfd2-3e21fc474496', '1c7b6f58-68a0-48e1-b54f-b9980ce94c96', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('162a5e52-5804-4ad1-b107-943b0df7c87f', 'f39dc23f-aa04-42a4-826d-c2db2b091968', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('162a5e52-5804-4ad1-b107-943b0df7c87f', '35f18e4e-da4b-45f7-9d8c-c11884b29d9b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('162a5e52-5804-4ad1-b107-943b0df7c87f', 'fa81f5e7-2364-4410-9310-461c9eb5f05a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('162a5e52-5804-4ad1-b107-943b0df7c87f', 'b2953191-2fba-4625-85ee-e7c2f4810ec8', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('162a5e52-5804-4ad1-b107-943b0df7c87f', '9f2d473d-4cec-4ade-bbcf-568dfdc47981', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('51454a27-2039-4599-afef-11a9f8f38a1a', '3721b848-c7b5-4ba3-9a05-4a7531ef5280', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('51454a27-2039-4599-afef-11a9f8f38a1a', '2b601da3-be55-44c5-995e-4b1ff113c36e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('51454a27-2039-4599-afef-11a9f8f38a1a', '3a0bb214-545b-432f-86ed-434995892b11', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('51454a27-2039-4599-afef-11a9f8f38a1a', '21f2a83a-dd84-4848-8e46-13dfe0b3421c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('51454a27-2039-4599-afef-11a9f8f38a1a', 'f4a7068d-7999-475e-b939-a09f70f64ced', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f39dc23f-aa04-42a4-826d-c2db2b091968', '162a5e52-5804-4ad1-b107-943b0df7c87f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f39dc23f-aa04-42a4-826d-c2db2b091968', '35f18e4e-da4b-45f7-9d8c-c11884b29d9b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f39dc23f-aa04-42a4-826d-c2db2b091968', 'fa81f5e7-2364-4410-9310-461c9eb5f05a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f39dc23f-aa04-42a4-826d-c2db2b091968', 'b2953191-2fba-4625-85ee-e7c2f4810ec8', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f39dc23f-aa04-42a4-826d-c2db2b091968', '9f2d473d-4cec-4ade-bbcf-568dfdc47981', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e36fdca4-0784-4f3a-9c8b-91d16fc4d122', 'f3cd7571-df55-4b53-91a5-85d3eba86974', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e36fdca4-0784-4f3a-9c8b-91d16fc4d122', 'e3ec6a6f-4c09-43b8-b328-1fe50c25b45c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e36fdca4-0784-4f3a-9c8b-91d16fc4d122', '4c231bb1-4a9e-45f5-8674-816abe9e00e3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e36fdca4-0784-4f3a-9c8b-91d16fc4d122', 'abfcbdea-d10f-45b4-815c-63651d25bf3b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e36fdca4-0784-4f3a-9c8b-91d16fc4d122', '220e3252-4646-41e3-9b63-c120913a3a6a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f3cd7571-df55-4b53-91a5-85d3eba86974', 'e36fdca4-0784-4f3a-9c8b-91d16fc4d122', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f3cd7571-df55-4b53-91a5-85d3eba86974', 'e3ec6a6f-4c09-43b8-b328-1fe50c25b45c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f3cd7571-df55-4b53-91a5-85d3eba86974', '4c231bb1-4a9e-45f5-8674-816abe9e00e3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f3cd7571-df55-4b53-91a5-85d3eba86974', 'abfcbdea-d10f-45b4-815c-63651d25bf3b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f3cd7571-df55-4b53-91a5-85d3eba86974', '220e3252-4646-41e3-9b63-c120913a3a6a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3ec6a6f-4c09-43b8-b328-1fe50c25b45c', 'e36fdca4-0784-4f3a-9c8b-91d16fc4d122', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3ec6a6f-4c09-43b8-b328-1fe50c25b45c', 'f3cd7571-df55-4b53-91a5-85d3eba86974', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3ec6a6f-4c09-43b8-b328-1fe50c25b45c', '4c231bb1-4a9e-45f5-8674-816abe9e00e3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3ec6a6f-4c09-43b8-b328-1fe50c25b45c', 'abfcbdea-d10f-45b4-815c-63651d25bf3b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3ec6a6f-4c09-43b8-b328-1fe50c25b45c', '220e3252-4646-41e3-9b63-c120913a3a6a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c231bb1-4a9e-45f5-8674-816abe9e00e3', 'e36fdca4-0784-4f3a-9c8b-91d16fc4d122', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c231bb1-4a9e-45f5-8674-816abe9e00e3', 'f3cd7571-df55-4b53-91a5-85d3eba86974', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c231bb1-4a9e-45f5-8674-816abe9e00e3', 'e3ec6a6f-4c09-43b8-b328-1fe50c25b45c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c231bb1-4a9e-45f5-8674-816abe9e00e3', 'abfcbdea-d10f-45b4-815c-63651d25bf3b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c231bb1-4a9e-45f5-8674-816abe9e00e3', '220e3252-4646-41e3-9b63-c120913a3a6a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('abfcbdea-d10f-45b4-815c-63651d25bf3b', 'e36fdca4-0784-4f3a-9c8b-91d16fc4d122', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('abfcbdea-d10f-45b4-815c-63651d25bf3b', 'f3cd7571-df55-4b53-91a5-85d3eba86974', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('abfcbdea-d10f-45b4-815c-63651d25bf3b', 'e3ec6a6f-4c09-43b8-b328-1fe50c25b45c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('abfcbdea-d10f-45b4-815c-63651d25bf3b', '4c231bb1-4a9e-45f5-8674-816abe9e00e3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('abfcbdea-d10f-45b4-815c-63651d25bf3b', '220e3252-4646-41e3-9b63-c120913a3a6a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7fffa7a-924f-4a94-881e-6c38c7337156', 'e36fdca4-0784-4f3a-9c8b-91d16fc4d122', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7fffa7a-924f-4a94-881e-6c38c7337156', 'f3cd7571-df55-4b53-91a5-85d3eba86974', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7fffa7a-924f-4a94-881e-6c38c7337156', 'e3ec6a6f-4c09-43b8-b328-1fe50c25b45c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7fffa7a-924f-4a94-881e-6c38c7337156', '4c231bb1-4a9e-45f5-8674-816abe9e00e3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7fffa7a-924f-4a94-881e-6c38c7337156', 'abfcbdea-d10f-45b4-815c-63651d25bf3b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('220e3252-4646-41e3-9b63-c120913a3a6a', 'e36fdca4-0784-4f3a-9c8b-91d16fc4d122', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('220e3252-4646-41e3-9b63-c120913a3a6a', 'f3cd7571-df55-4b53-91a5-85d3eba86974', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('220e3252-4646-41e3-9b63-c120913a3a6a', 'e3ec6a6f-4c09-43b8-b328-1fe50c25b45c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('220e3252-4646-41e3-9b63-c120913a3a6a', '4c231bb1-4a9e-45f5-8674-816abe9e00e3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('220e3252-4646-41e3-9b63-c120913a3a6a', 'abfcbdea-d10f-45b4-815c-63651d25bf3b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b6b9cc02-1c8b-42c1-93c5-a5de80478b61', 'e36fdca4-0784-4f3a-9c8b-91d16fc4d122', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b6b9cc02-1c8b-42c1-93c5-a5de80478b61', 'f3cd7571-df55-4b53-91a5-85d3eba86974', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b6b9cc02-1c8b-42c1-93c5-a5de80478b61', 'e3ec6a6f-4c09-43b8-b328-1fe50c25b45c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b6b9cc02-1c8b-42c1-93c5-a5de80478b61', '4c231bb1-4a9e-45f5-8674-816abe9e00e3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b6b9cc02-1c8b-42c1-93c5-a5de80478b61', 'abfcbdea-d10f-45b4-815c-63651d25bf3b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb07dc8d-727e-4045-9c44-108d48a89e72', 'e36fdca4-0784-4f3a-9c8b-91d16fc4d122', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb07dc8d-727e-4045-9c44-108d48a89e72', 'f3cd7571-df55-4b53-91a5-85d3eba86974', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb07dc8d-727e-4045-9c44-108d48a89e72', 'e3ec6a6f-4c09-43b8-b328-1fe50c25b45c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb07dc8d-727e-4045-9c44-108d48a89e72', '4c231bb1-4a9e-45f5-8674-816abe9e00e3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb07dc8d-727e-4045-9c44-108d48a89e72', 'abfcbdea-d10f-45b4-815c-63651d25bf3b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c8c4a94e-30f7-4547-b04c-f8aa2e6403ed', 'cb4c676f-e2fb-46fd-bee5-43b5f76d21f7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c8c4a94e-30f7-4547-b04c-f8aa2e6403ed', '168549c7-67b9-412d-82b0-d5717ebdbe09', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c8c4a94e-30f7-4547-b04c-f8aa2e6403ed', 'e36fdca4-0784-4f3a-9c8b-91d16fc4d122', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c8c4a94e-30f7-4547-b04c-f8aa2e6403ed', 'f3cd7571-df55-4b53-91a5-85d3eba86974', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c8c4a94e-30f7-4547-b04c-f8aa2e6403ed', 'e3ec6a6f-4c09-43b8-b328-1fe50c25b45c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cb4c676f-e2fb-46fd-bee5-43b5f76d21f7', 'c8c4a94e-30f7-4547-b04c-f8aa2e6403ed', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cb4c676f-e2fb-46fd-bee5-43b5f76d21f7', '168549c7-67b9-412d-82b0-d5717ebdbe09', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cb4c676f-e2fb-46fd-bee5-43b5f76d21f7', 'e36fdca4-0784-4f3a-9c8b-91d16fc4d122', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cb4c676f-e2fb-46fd-bee5-43b5f76d21f7', 'f3cd7571-df55-4b53-91a5-85d3eba86974', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cb4c676f-e2fb-46fd-bee5-43b5f76d21f7', 'e3ec6a6f-4c09-43b8-b328-1fe50c25b45c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('168549c7-67b9-412d-82b0-d5717ebdbe09', 'c8c4a94e-30f7-4547-b04c-f8aa2e6403ed', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('168549c7-67b9-412d-82b0-d5717ebdbe09', 'cb4c676f-e2fb-46fd-bee5-43b5f76d21f7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('168549c7-67b9-412d-82b0-d5717ebdbe09', 'e36fdca4-0784-4f3a-9c8b-91d16fc4d122', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('168549c7-67b9-412d-82b0-d5717ebdbe09', 'f3cd7571-df55-4b53-91a5-85d3eba86974', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('168549c7-67b9-412d-82b0-d5717ebdbe09', 'e3ec6a6f-4c09-43b8-b328-1fe50c25b45c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6b19d51-2f27-4513-83b5-d1f444ebf092', 'e36fdca4-0784-4f3a-9c8b-91d16fc4d122', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6b19d51-2f27-4513-83b5-d1f444ebf092', 'f3cd7571-df55-4b53-91a5-85d3eba86974', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6b19d51-2f27-4513-83b5-d1f444ebf092', 'e3ec6a6f-4c09-43b8-b328-1fe50c25b45c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6b19d51-2f27-4513-83b5-d1f444ebf092', '4c231bb1-4a9e-45f5-8674-816abe9e00e3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6b19d51-2f27-4513-83b5-d1f444ebf092', 'abfcbdea-d10f-45b4-815c-63651d25bf3b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('728e68fd-f6a5-4156-8d79-a292205c4b52', 'a2da64b8-8b0f-4cbb-9bc6-9afc5aa86ec3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('728e68fd-f6a5-4156-8d79-a292205c4b52', 'e36fdca4-0784-4f3a-9c8b-91d16fc4d122', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('728e68fd-f6a5-4156-8d79-a292205c4b52', 'f3cd7571-df55-4b53-91a5-85d3eba86974', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bc4bfef5-cd97-456e-8ca6-ea1c14a7b26a', 'e36fdca4-0784-4f3a-9c8b-91d16fc4d122', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bc4bfef5-cd97-456e-8ca6-ea1c14a7b26a', 'f3cd7571-df55-4b53-91a5-85d3eba86974', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bc4bfef5-cd97-456e-8ca6-ea1c14a7b26a', 'e3ec6a6f-4c09-43b8-b328-1fe50c25b45c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bc4bfef5-cd97-456e-8ca6-ea1c14a7b26a', '4c231bb1-4a9e-45f5-8674-816abe9e00e3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bc4bfef5-cd97-456e-8ca6-ea1c14a7b26a', 'abfcbdea-d10f-45b4-815c-63651d25bf3b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a2da64b8-8b0f-4cbb-9bc6-9afc5aa86ec3', '728e68fd-f6a5-4156-8d79-a292205c4b52', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a2da64b8-8b0f-4cbb-9bc6-9afc5aa86ec3', 'e36fdca4-0784-4f3a-9c8b-91d16fc4d122', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a2da64b8-8b0f-4cbb-9bc6-9afc5aa86ec3', 'f3cd7571-df55-4b53-91a5-85d3eba86974', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('be12d1de-c742-4469-8e59-0987df6786ee', 'e36fdca4-0784-4f3a-9c8b-91d16fc4d122', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('be12d1de-c742-4469-8e59-0987df6786ee', 'f3cd7571-df55-4b53-91a5-85d3eba86974', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('be12d1de-c742-4469-8e59-0987df6786ee', 'e3ec6a6f-4c09-43b8-b328-1fe50c25b45c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('be12d1de-c742-4469-8e59-0987df6786ee', '4c231bb1-4a9e-45f5-8674-816abe9e00e3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('be12d1de-c742-4469-8e59-0987df6786ee', 'abfcbdea-d10f-45b4-815c-63651d25bf3b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e386b724-ba00-41b1-abf7-675e014a3efc', 'e36fdca4-0784-4f3a-9c8b-91d16fc4d122', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e386b724-ba00-41b1-abf7-675e014a3efc', 'f3cd7571-df55-4b53-91a5-85d3eba86974', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e386b724-ba00-41b1-abf7-675e014a3efc', 'e3ec6a6f-4c09-43b8-b328-1fe50c25b45c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e386b724-ba00-41b1-abf7-675e014a3efc', '4c231bb1-4a9e-45f5-8674-816abe9e00e3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e386b724-ba00-41b1-abf7-675e014a3efc', 'abfcbdea-d10f-45b4-815c-63651d25bf3b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('425caa19-c13a-4372-afac-d319cf38cd70', '684de4d9-5836-4c36-a909-bc137757c3f4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('425caa19-c13a-4372-afac-d319cf38cd70', '4936fde0-bcba-4130-80f5-694265d88abc', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('425caa19-c13a-4372-afac-d319cf38cd70', '5a542d84-aaa0-4e87-8999-757b0e54a1dd', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('425caa19-c13a-4372-afac-d319cf38cd70', '3ea3d8e2-1719-4799-8abf-63153969bfa1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('425caa19-c13a-4372-afac-d319cf38cd70', '8a79afc2-2299-431d-9797-0f08b25d0275', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('684de4d9-5836-4c36-a909-bc137757c3f4', '425caa19-c13a-4372-afac-d319cf38cd70', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('684de4d9-5836-4c36-a909-bc137757c3f4', '4936fde0-bcba-4130-80f5-694265d88abc', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('684de4d9-5836-4c36-a909-bc137757c3f4', '5a542d84-aaa0-4e87-8999-757b0e54a1dd', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('684de4d9-5836-4c36-a909-bc137757c3f4', '3ea3d8e2-1719-4799-8abf-63153969bfa1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('684de4d9-5836-4c36-a909-bc137757c3f4', '8a79afc2-2299-431d-9797-0f08b25d0275', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4936fde0-bcba-4130-80f5-694265d88abc', '425caa19-c13a-4372-afac-d319cf38cd70', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4936fde0-bcba-4130-80f5-694265d88abc', '684de4d9-5836-4c36-a909-bc137757c3f4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4936fde0-bcba-4130-80f5-694265d88abc', '5a542d84-aaa0-4e87-8999-757b0e54a1dd', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4936fde0-bcba-4130-80f5-694265d88abc', '3ea3d8e2-1719-4799-8abf-63153969bfa1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4936fde0-bcba-4130-80f5-694265d88abc', '8a79afc2-2299-431d-9797-0f08b25d0275', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5a542d84-aaa0-4e87-8999-757b0e54a1dd', '3ea3d8e2-1719-4799-8abf-63153969bfa1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5a542d84-aaa0-4e87-8999-757b0e54a1dd', '8a79afc2-2299-431d-9797-0f08b25d0275', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5a542d84-aaa0-4e87-8999-757b0e54a1dd', '4f4b351d-d401-411d-ac7f-3bda69471be4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5a542d84-aaa0-4e87-8999-757b0e54a1dd', '760026f9-66cb-48e3-8654-ee0ad4c2a280', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5a542d84-aaa0-4e87-8999-757b0e54a1dd', 'ea65bd24-467b-4e7b-9e4a-8dc651f45c65', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6fff6a66-e254-4e70-aaa9-eb914ca515d5', '74f7a3f6-0ea9-4022-bccf-0bd69c7a5f8c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6fff6a66-e254-4e70-aaa9-eb914ca515d5', 'fdea39bf-967d-4140-b608-0814b7bb6952', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6fff6a66-e254-4e70-aaa9-eb914ca515d5', 'c5c335dd-c214-44ff-8d76-0390a320faf6', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3ea3d8e2-1719-4799-8abf-63153969bfa1', '5a542d84-aaa0-4e87-8999-757b0e54a1dd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3ea3d8e2-1719-4799-8abf-63153969bfa1', '8a79afc2-2299-431d-9797-0f08b25d0275', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3ea3d8e2-1719-4799-8abf-63153969bfa1', '4f4b351d-d401-411d-ac7f-3bda69471be4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3ea3d8e2-1719-4799-8abf-63153969bfa1', '760026f9-66cb-48e3-8654-ee0ad4c2a280', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3ea3d8e2-1719-4799-8abf-63153969bfa1', 'ea65bd24-467b-4e7b-9e4a-8dc651f45c65', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8a79afc2-2299-431d-9797-0f08b25d0275', '5a542d84-aaa0-4e87-8999-757b0e54a1dd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8a79afc2-2299-431d-9797-0f08b25d0275', '3ea3d8e2-1719-4799-8abf-63153969bfa1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8a79afc2-2299-431d-9797-0f08b25d0275', '4f4b351d-d401-411d-ac7f-3bda69471be4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8a79afc2-2299-431d-9797-0f08b25d0275', '760026f9-66cb-48e3-8654-ee0ad4c2a280', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8a79afc2-2299-431d-9797-0f08b25d0275', 'ea65bd24-467b-4e7b-9e4a-8dc651f45c65', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4f4b351d-d401-411d-ac7f-3bda69471be4', '5a542d84-aaa0-4e87-8999-757b0e54a1dd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4f4b351d-d401-411d-ac7f-3bda69471be4', '3ea3d8e2-1719-4799-8abf-63153969bfa1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4f4b351d-d401-411d-ac7f-3bda69471be4', '8a79afc2-2299-431d-9797-0f08b25d0275', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4f4b351d-d401-411d-ac7f-3bda69471be4', '760026f9-66cb-48e3-8654-ee0ad4c2a280', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4f4b351d-d401-411d-ac7f-3bda69471be4', 'ea65bd24-467b-4e7b-9e4a-8dc651f45c65', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('760026f9-66cb-48e3-8654-ee0ad4c2a280', '5a542d84-aaa0-4e87-8999-757b0e54a1dd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('760026f9-66cb-48e3-8654-ee0ad4c2a280', '3ea3d8e2-1719-4799-8abf-63153969bfa1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('760026f9-66cb-48e3-8654-ee0ad4c2a280', '8a79afc2-2299-431d-9797-0f08b25d0275', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('760026f9-66cb-48e3-8654-ee0ad4c2a280', '4f4b351d-d401-411d-ac7f-3bda69471be4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('760026f9-66cb-48e3-8654-ee0ad4c2a280', 'ea65bd24-467b-4e7b-9e4a-8dc651f45c65', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ea65bd24-467b-4e7b-9e4a-8dc651f45c65', '5a542d84-aaa0-4e87-8999-757b0e54a1dd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ea65bd24-467b-4e7b-9e4a-8dc651f45c65', '3ea3d8e2-1719-4799-8abf-63153969bfa1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ea65bd24-467b-4e7b-9e4a-8dc651f45c65', '8a79afc2-2299-431d-9797-0f08b25d0275', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ea65bd24-467b-4e7b-9e4a-8dc651f45c65', '4f4b351d-d401-411d-ac7f-3bda69471be4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ea65bd24-467b-4e7b-9e4a-8dc651f45c65', '760026f9-66cb-48e3-8654-ee0ad4c2a280', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3292597b-b40e-41e3-8623-3ec3c13bd344', '5a542d84-aaa0-4e87-8999-757b0e54a1dd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3292597b-b40e-41e3-8623-3ec3c13bd344', '3ea3d8e2-1719-4799-8abf-63153969bfa1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3292597b-b40e-41e3-8623-3ec3c13bd344', '8a79afc2-2299-431d-9797-0f08b25d0275', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3292597b-b40e-41e3-8623-3ec3c13bd344', '4f4b351d-d401-411d-ac7f-3bda69471be4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3292597b-b40e-41e3-8623-3ec3c13bd344', '760026f9-66cb-48e3-8654-ee0ad4c2a280', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8dbbd81d-eb08-4026-be76-3466b51207b1', '5a542d84-aaa0-4e87-8999-757b0e54a1dd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8dbbd81d-eb08-4026-be76-3466b51207b1', '3ea3d8e2-1719-4799-8abf-63153969bfa1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8dbbd81d-eb08-4026-be76-3466b51207b1', '8a79afc2-2299-431d-9797-0f08b25d0275', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8dbbd81d-eb08-4026-be76-3466b51207b1', '4f4b351d-d401-411d-ac7f-3bda69471be4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8dbbd81d-eb08-4026-be76-3466b51207b1', '760026f9-66cb-48e3-8654-ee0ad4c2a280', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('257f1a6f-5e51-4e41-844b-8c67b7d7b303', '5a542d84-aaa0-4e87-8999-757b0e54a1dd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('257f1a6f-5e51-4e41-844b-8c67b7d7b303', '3ea3d8e2-1719-4799-8abf-63153969bfa1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('257f1a6f-5e51-4e41-844b-8c67b7d7b303', '8a79afc2-2299-431d-9797-0f08b25d0275', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('257f1a6f-5e51-4e41-844b-8c67b7d7b303', '4f4b351d-d401-411d-ac7f-3bda69471be4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('257f1a6f-5e51-4e41-844b-8c67b7d7b303', '760026f9-66cb-48e3-8654-ee0ad4c2a280', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f69363d-a423-4043-8aac-22faef860829', '5a542d84-aaa0-4e87-8999-757b0e54a1dd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f69363d-a423-4043-8aac-22faef860829', '3ea3d8e2-1719-4799-8abf-63153969bfa1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f69363d-a423-4043-8aac-22faef860829', '8a79afc2-2299-431d-9797-0f08b25d0275', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f69363d-a423-4043-8aac-22faef860829', '4f4b351d-d401-411d-ac7f-3bda69471be4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f69363d-a423-4043-8aac-22faef860829', '760026f9-66cb-48e3-8654-ee0ad4c2a280', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('addebdec-ce40-4f51-806e-edbadf40c043', '425caa19-c13a-4372-afac-d319cf38cd70', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('addebdec-ce40-4f51-806e-edbadf40c043', '684de4d9-5836-4c36-a909-bc137757c3f4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('addebdec-ce40-4f51-806e-edbadf40c043', '4936fde0-bcba-4130-80f5-694265d88abc', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('addebdec-ce40-4f51-806e-edbadf40c043', '5a542d84-aaa0-4e87-8999-757b0e54a1dd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('addebdec-ce40-4f51-806e-edbadf40c043', '3ea3d8e2-1719-4799-8abf-63153969bfa1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a28b58f0-6c5e-4750-ac64-c8a7c9ef39cb', '23909417-173d-4604-a977-b98c36eca851', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a28b58f0-6c5e-4750-ac64-c8a7c9ef39cb', '4c523504-e73f-4905-874f-7e56f9be4568', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a28b58f0-6c5e-4750-ac64-c8a7c9ef39cb', '8ebcfd36-429d-4def-84ee-3cfb70601854', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a28b58f0-6c5e-4750-ac64-c8a7c9ef39cb', '154eec82-c76d-430d-807f-abed89b68545', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a28b58f0-6c5e-4750-ac64-c8a7c9ef39cb', 'e9e065a4-8b84-4d44-b594-d2475237f0b3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('23909417-173d-4604-a977-b98c36eca851', 'a28b58f0-6c5e-4750-ac64-c8a7c9ef39cb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('23909417-173d-4604-a977-b98c36eca851', '4c523504-e73f-4905-874f-7e56f9be4568', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('23909417-173d-4604-a977-b98c36eca851', '8ebcfd36-429d-4def-84ee-3cfb70601854', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('23909417-173d-4604-a977-b98c36eca851', '154eec82-c76d-430d-807f-abed89b68545', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('23909417-173d-4604-a977-b98c36eca851', 'e9e065a4-8b84-4d44-b594-d2475237f0b3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('00d0d74c-187f-4318-8670-fbf97173292d', '23909417-173d-4604-a977-b98c36eca851', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('00d0d74c-187f-4318-8670-fbf97173292d', 'a28b58f0-6c5e-4750-ac64-c8a7c9ef39cb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('00d0d74c-187f-4318-8670-fbf97173292d', '4c523504-e73f-4905-874f-7e56f9be4568', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('00d0d74c-187f-4318-8670-fbf97173292d', '8ebcfd36-429d-4def-84ee-3cfb70601854', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('00d0d74c-187f-4318-8670-fbf97173292d', '154eec82-c76d-430d-807f-abed89b68545', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c523504-e73f-4905-874f-7e56f9be4568', '8b59877a-78d5-4720-9891-5d7988a42a45', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c523504-e73f-4905-874f-7e56f9be4568', '9ff1f486-2acd-4590-bf45-a1d615325f86', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c523504-e73f-4905-874f-7e56f9be4568', '07a09c1d-7036-4560-a399-d75ba4e5a8e7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c523504-e73f-4905-874f-7e56f9be4568', 'a28b58f0-6c5e-4750-ac64-c8a7c9ef39cb', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c523504-e73f-4905-874f-7e56f9be4568', '23909417-173d-4604-a977-b98c36eca851', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8ebcfd36-429d-4def-84ee-3cfb70601854', '154eec82-c76d-430d-807f-abed89b68545', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8ebcfd36-429d-4def-84ee-3cfb70601854', 'e9e065a4-8b84-4d44-b594-d2475237f0b3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8ebcfd36-429d-4def-84ee-3cfb70601854', '72165e12-037a-4514-ae50-fdb0aa91fdcd', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8ebcfd36-429d-4def-84ee-3cfb70601854', 'd66b35ee-dd3b-43a7-ac33-1ecb9e0fc1ac', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8ebcfd36-429d-4def-84ee-3cfb70601854', 'a28b58f0-6c5e-4750-ac64-c8a7c9ef39cb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('154eec82-c76d-430d-807f-abed89b68545', '8ebcfd36-429d-4def-84ee-3cfb70601854', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('154eec82-c76d-430d-807f-abed89b68545', 'e9e065a4-8b84-4d44-b594-d2475237f0b3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('154eec82-c76d-430d-807f-abed89b68545', '72165e12-037a-4514-ae50-fdb0aa91fdcd', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('154eec82-c76d-430d-807f-abed89b68545', 'd66b35ee-dd3b-43a7-ac33-1ecb9e0fc1ac', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('154eec82-c76d-430d-807f-abed89b68545', 'a28b58f0-6c5e-4750-ac64-c8a7c9ef39cb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e9e065a4-8b84-4d44-b594-d2475237f0b3', '8ebcfd36-429d-4def-84ee-3cfb70601854', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e9e065a4-8b84-4d44-b594-d2475237f0b3', '154eec82-c76d-430d-807f-abed89b68545', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e9e065a4-8b84-4d44-b594-d2475237f0b3', '72165e12-037a-4514-ae50-fdb0aa91fdcd', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e9e065a4-8b84-4d44-b594-d2475237f0b3', 'd66b35ee-dd3b-43a7-ac33-1ecb9e0fc1ac', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e9e065a4-8b84-4d44-b594-d2475237f0b3', 'a28b58f0-6c5e-4750-ac64-c8a7c9ef39cb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b59877a-78d5-4720-9891-5d7988a42a45', '4c523504-e73f-4905-874f-7e56f9be4568', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b59877a-78d5-4720-9891-5d7988a42a45', '9ff1f486-2acd-4590-bf45-a1d615325f86', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b59877a-78d5-4720-9891-5d7988a42a45', '07a09c1d-7036-4560-a399-d75ba4e5a8e7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b59877a-78d5-4720-9891-5d7988a42a45', 'a28b58f0-6c5e-4750-ac64-c8a7c9ef39cb', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b59877a-78d5-4720-9891-5d7988a42a45', '23909417-173d-4604-a977-b98c36eca851', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ff1f486-2acd-4590-bf45-a1d615325f86', '4c523504-e73f-4905-874f-7e56f9be4568', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ff1f486-2acd-4590-bf45-a1d615325f86', '8b59877a-78d5-4720-9891-5d7988a42a45', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ff1f486-2acd-4590-bf45-a1d615325f86', '07a09c1d-7036-4560-a399-d75ba4e5a8e7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ff1f486-2acd-4590-bf45-a1d615325f86', 'a28b58f0-6c5e-4750-ac64-c8a7c9ef39cb', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ff1f486-2acd-4590-bf45-a1d615325f86', '23909417-173d-4604-a977-b98c36eca851', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('72165e12-037a-4514-ae50-fdb0aa91fdcd', '8ebcfd36-429d-4def-84ee-3cfb70601854', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('72165e12-037a-4514-ae50-fdb0aa91fdcd', '154eec82-c76d-430d-807f-abed89b68545', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('72165e12-037a-4514-ae50-fdb0aa91fdcd', 'e9e065a4-8b84-4d44-b594-d2475237f0b3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('72165e12-037a-4514-ae50-fdb0aa91fdcd', 'd66b35ee-dd3b-43a7-ac33-1ecb9e0fc1ac', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('72165e12-037a-4514-ae50-fdb0aa91fdcd', 'a28b58f0-6c5e-4750-ac64-c8a7c9ef39cb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d66b35ee-dd3b-43a7-ac33-1ecb9e0fc1ac', '8ebcfd36-429d-4def-84ee-3cfb70601854', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d66b35ee-dd3b-43a7-ac33-1ecb9e0fc1ac', '154eec82-c76d-430d-807f-abed89b68545', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d66b35ee-dd3b-43a7-ac33-1ecb9e0fc1ac', 'e9e065a4-8b84-4d44-b594-d2475237f0b3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d66b35ee-dd3b-43a7-ac33-1ecb9e0fc1ac', '72165e12-037a-4514-ae50-fdb0aa91fdcd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d66b35ee-dd3b-43a7-ac33-1ecb9e0fc1ac', 'a28b58f0-6c5e-4750-ac64-c8a7c9ef39cb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('07a09c1d-7036-4560-a399-d75ba4e5a8e7', '4c523504-e73f-4905-874f-7e56f9be4568', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('07a09c1d-7036-4560-a399-d75ba4e5a8e7', '8b59877a-78d5-4720-9891-5d7988a42a45', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('07a09c1d-7036-4560-a399-d75ba4e5a8e7', '9ff1f486-2acd-4590-bf45-a1d615325f86', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('07a09c1d-7036-4560-a399-d75ba4e5a8e7', 'a28b58f0-6c5e-4750-ac64-c8a7c9ef39cb', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('07a09c1d-7036-4560-a399-d75ba4e5a8e7', '23909417-173d-4604-a977-b98c36eca851', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bfd073c7-b8c7-4c4d-b278-46a527a80d7c', '5a542d84-aaa0-4e87-8999-757b0e54a1dd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bfd073c7-b8c7-4c4d-b278-46a527a80d7c', '3ea3d8e2-1719-4799-8abf-63153969bfa1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bfd073c7-b8c7-4c4d-b278-46a527a80d7c', '8a79afc2-2299-431d-9797-0f08b25d0275', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bfd073c7-b8c7-4c4d-b278-46a527a80d7c', '4f4b351d-d401-411d-ac7f-3bda69471be4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bfd073c7-b8c7-4c4d-b278-46a527a80d7c', '760026f9-66cb-48e3-8654-ee0ad4c2a280', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc938ab2-0f73-4e01-9595-6e9401dc10fb', '425caa19-c13a-4372-afac-d319cf38cd70', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc938ab2-0f73-4e01-9595-6e9401dc10fb', '684de4d9-5836-4c36-a909-bc137757c3f4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc938ab2-0f73-4e01-9595-6e9401dc10fb', '4936fde0-bcba-4130-80f5-694265d88abc', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fdea39bf-967d-4140-b608-0814b7bb6952', 'c5c335dd-c214-44ff-8d76-0390a320faf6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fdea39bf-967d-4140-b608-0814b7bb6952', 'b95e77e9-e5cd-4b9e-9fb5-44961dc45814', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fdea39bf-967d-4140-b608-0814b7bb6952', '1585be60-f37b-4e9e-978a-437ba9aeb4ee', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c5c335dd-c214-44ff-8d76-0390a320faf6', 'fdea39bf-967d-4140-b608-0814b7bb6952', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c5c335dd-c214-44ff-8d76-0390a320faf6', 'b95e77e9-e5cd-4b9e-9fb5-44961dc45814', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c5c335dd-c214-44ff-8d76-0390a320faf6', '1585be60-f37b-4e9e-978a-437ba9aeb4ee', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b95e77e9-e5cd-4b9e-9fb5-44961dc45814', 'fdea39bf-967d-4140-b608-0814b7bb6952', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b95e77e9-e5cd-4b9e-9fb5-44961dc45814', 'c5c335dd-c214-44ff-8d76-0390a320faf6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b95e77e9-e5cd-4b9e-9fb5-44961dc45814', '1585be60-f37b-4e9e-978a-437ba9aeb4ee', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1585be60-f37b-4e9e-978a-437ba9aeb4ee', 'fdea39bf-967d-4140-b608-0814b7bb6952', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1585be60-f37b-4e9e-978a-437ba9aeb4ee', 'c5c335dd-c214-44ff-8d76-0390a320faf6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1585be60-f37b-4e9e-978a-437ba9aeb4ee', 'b95e77e9-e5cd-4b9e-9fb5-44961dc45814', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('def93a43-6d90-449b-8483-1abb14e86b81', '23ffe64f-c1b1-4fc4-821e-51af1426106a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('def93a43-6d90-449b-8483-1abb14e86b81', '40477cac-bc89-4b00-8070-0d00ae751acc', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('def93a43-6d90-449b-8483-1abb14e86b81', 'f4a4ceec-33ca-4421-b96c-7f629a59f387', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('def93a43-6d90-449b-8483-1abb14e86b81', '18aee5ab-c93b-4827-82e7-fb40337e9e03', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('def93a43-6d90-449b-8483-1abb14e86b81', '99137280-da46-4a7e-bf22-88cea08e94a3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('23ffe64f-c1b1-4fc4-821e-51af1426106a', 'def93a43-6d90-449b-8483-1abb14e86b81', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('23ffe64f-c1b1-4fc4-821e-51af1426106a', '40477cac-bc89-4b00-8070-0d00ae751acc', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('23ffe64f-c1b1-4fc4-821e-51af1426106a', 'f4a4ceec-33ca-4421-b96c-7f629a59f387', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('23ffe64f-c1b1-4fc4-821e-51af1426106a', '18aee5ab-c93b-4827-82e7-fb40337e9e03', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('23ffe64f-c1b1-4fc4-821e-51af1426106a', '99137280-da46-4a7e-bf22-88cea08e94a3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('40477cac-bc89-4b00-8070-0d00ae751acc', 'def93a43-6d90-449b-8483-1abb14e86b81', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('40477cac-bc89-4b00-8070-0d00ae751acc', '23ffe64f-c1b1-4fc4-821e-51af1426106a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('40477cac-bc89-4b00-8070-0d00ae751acc', 'f4a4ceec-33ca-4421-b96c-7f629a59f387', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('40477cac-bc89-4b00-8070-0d00ae751acc', '18aee5ab-c93b-4827-82e7-fb40337e9e03', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('40477cac-bc89-4b00-8070-0d00ae751acc', '99137280-da46-4a7e-bf22-88cea08e94a3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f4a4ceec-33ca-4421-b96c-7f629a59f387', 'def93a43-6d90-449b-8483-1abb14e86b81', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f4a4ceec-33ca-4421-b96c-7f629a59f387', '23ffe64f-c1b1-4fc4-821e-51af1426106a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f4a4ceec-33ca-4421-b96c-7f629a59f387', '40477cac-bc89-4b00-8070-0d00ae751acc', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f4a4ceec-33ca-4421-b96c-7f629a59f387', '18aee5ab-c93b-4827-82e7-fb40337e9e03', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f4a4ceec-33ca-4421-b96c-7f629a59f387', '99137280-da46-4a7e-bf22-88cea08e94a3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('52b78fc5-cbaa-4a41-8f49-de905ca87162', 'a66bd822-d786-4068-b151-8c41835c821e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('52b78fc5-cbaa-4a41-8f49-de905ca87162', 'def93a43-6d90-449b-8483-1abb14e86b81', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('52b78fc5-cbaa-4a41-8f49-de905ca87162', '23ffe64f-c1b1-4fc4-821e-51af1426106a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('52b78fc5-cbaa-4a41-8f49-de905ca87162', '40477cac-bc89-4b00-8070-0d00ae751acc', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('52b78fc5-cbaa-4a41-8f49-de905ca87162', 'f4a4ceec-33ca-4421-b96c-7f629a59f387', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a66bd822-d786-4068-b151-8c41835c821e', '52b78fc5-cbaa-4a41-8f49-de905ca87162', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a66bd822-d786-4068-b151-8c41835c821e', 'def93a43-6d90-449b-8483-1abb14e86b81', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a66bd822-d786-4068-b151-8c41835c821e', '23ffe64f-c1b1-4fc4-821e-51af1426106a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a66bd822-d786-4068-b151-8c41835c821e', '40477cac-bc89-4b00-8070-0d00ae751acc', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a66bd822-d786-4068-b151-8c41835c821e', 'f4a4ceec-33ca-4421-b96c-7f629a59f387', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('18aee5ab-c93b-4827-82e7-fb40337e9e03', 'def93a43-6d90-449b-8483-1abb14e86b81', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('18aee5ab-c93b-4827-82e7-fb40337e9e03', '23ffe64f-c1b1-4fc4-821e-51af1426106a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('18aee5ab-c93b-4827-82e7-fb40337e9e03', '40477cac-bc89-4b00-8070-0d00ae751acc', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('18aee5ab-c93b-4827-82e7-fb40337e9e03', 'f4a4ceec-33ca-4421-b96c-7f629a59f387', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('18aee5ab-c93b-4827-82e7-fb40337e9e03', '99137280-da46-4a7e-bf22-88cea08e94a3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('99137280-da46-4a7e-bf22-88cea08e94a3', 'def93a43-6d90-449b-8483-1abb14e86b81', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('99137280-da46-4a7e-bf22-88cea08e94a3', '23ffe64f-c1b1-4fc4-821e-51af1426106a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('99137280-da46-4a7e-bf22-88cea08e94a3', '40477cac-bc89-4b00-8070-0d00ae751acc', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('99137280-da46-4a7e-bf22-88cea08e94a3', 'f4a4ceec-33ca-4421-b96c-7f629a59f387', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('99137280-da46-4a7e-bf22-88cea08e94a3', '18aee5ab-c93b-4827-82e7-fb40337e9e03', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('09fa8a01-c129-47fb-9bc8-25ef07aa1813', '6fff6a66-e254-4e70-aaa9-eb914ca515d5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('09fa8a01-c129-47fb-9bc8-25ef07aa1813', 'fdea39bf-967d-4140-b608-0814b7bb6952', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('09fa8a01-c129-47fb-9bc8-25ef07aa1813', 'c5c335dd-c214-44ff-8d76-0390a320faf6', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cf8875c1-ca2c-487b-a1b1-aac9c9f46ae6', 'def93a43-6d90-449b-8483-1abb14e86b81', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cf8875c1-ca2c-487b-a1b1-aac9c9f46ae6', '23ffe64f-c1b1-4fc4-821e-51af1426106a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cf8875c1-ca2c-487b-a1b1-aac9c9f46ae6', '40477cac-bc89-4b00-8070-0d00ae751acc', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cf8875c1-ca2c-487b-a1b1-aac9c9f46ae6', 'f4a4ceec-33ca-4421-b96c-7f629a59f387', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cf8875c1-ca2c-487b-a1b1-aac9c9f46ae6', '52b78fc5-cbaa-4a41-8f49-de905ca87162', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('74f7a3f6-0ea9-4022-bccf-0bd69c7a5f8c', '6fff6a66-e254-4e70-aaa9-eb914ca515d5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('74f7a3f6-0ea9-4022-bccf-0bd69c7a5f8c', 'fdea39bf-967d-4140-b608-0814b7bb6952', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('74f7a3f6-0ea9-4022-bccf-0bd69c7a5f8c', 'c5c335dd-c214-44ff-8d76-0390a320faf6', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('41f9015b-e09c-40cb-b24b-c277dd7bae8a', '203e79b6-9246-4224-bfbc-313fdd3b6070', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('41f9015b-e09c-40cb-b24b-c277dd7bae8a', '300f7881-8ecf-4b2f-9f6f-cc9768880546', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('41f9015b-e09c-40cb-b24b-c277dd7bae8a', '6124df92-d88a-4a21-be03-979b9dc01bd4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('41f9015b-e09c-40cb-b24b-c277dd7bae8a', 'cc8fab44-37d1-4f3d-9604-b5da3ec64908', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('41f9015b-e09c-40cb-b24b-c277dd7bae8a', '6ba17c87-c709-4670-9963-13c1bdfce840', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ef689b4e-d5ad-4889-893c-ba1e77353fc3', 'c8f89540-1aa4-419b-ac69-a423a6573a71', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ef689b4e-d5ad-4889-893c-ba1e77353fc3', '41f9015b-e09c-40cb-b24b-c277dd7bae8a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ef689b4e-d5ad-4889-893c-ba1e77353fc3', '203e79b6-9246-4224-bfbc-313fdd3b6070', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ef689b4e-d5ad-4889-893c-ba1e77353fc3', '300f7881-8ecf-4b2f-9f6f-cc9768880546', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ef689b4e-d5ad-4889-893c-ba1e77353fc3', '6124df92-d88a-4a21-be03-979b9dc01bd4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('203e79b6-9246-4224-bfbc-313fdd3b6070', '41f9015b-e09c-40cb-b24b-c277dd7bae8a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('203e79b6-9246-4224-bfbc-313fdd3b6070', '300f7881-8ecf-4b2f-9f6f-cc9768880546', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('203e79b6-9246-4224-bfbc-313fdd3b6070', '6124df92-d88a-4a21-be03-979b9dc01bd4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('203e79b6-9246-4224-bfbc-313fdd3b6070', 'cc8fab44-37d1-4f3d-9604-b5da3ec64908', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('203e79b6-9246-4224-bfbc-313fdd3b6070', '6ba17c87-c709-4670-9963-13c1bdfce840', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('300f7881-8ecf-4b2f-9f6f-cc9768880546', '41f9015b-e09c-40cb-b24b-c277dd7bae8a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('300f7881-8ecf-4b2f-9f6f-cc9768880546', '203e79b6-9246-4224-bfbc-313fdd3b6070', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('300f7881-8ecf-4b2f-9f6f-cc9768880546', '6124df92-d88a-4a21-be03-979b9dc01bd4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('300f7881-8ecf-4b2f-9f6f-cc9768880546', 'cc8fab44-37d1-4f3d-9604-b5da3ec64908', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('300f7881-8ecf-4b2f-9f6f-cc9768880546', '6ba17c87-c709-4670-9963-13c1bdfce840', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6124df92-d88a-4a21-be03-979b9dc01bd4', '41f9015b-e09c-40cb-b24b-c277dd7bae8a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6124df92-d88a-4a21-be03-979b9dc01bd4', '203e79b6-9246-4224-bfbc-313fdd3b6070', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6124df92-d88a-4a21-be03-979b9dc01bd4', '300f7881-8ecf-4b2f-9f6f-cc9768880546', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6124df92-d88a-4a21-be03-979b9dc01bd4', 'cc8fab44-37d1-4f3d-9604-b5da3ec64908', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6124df92-d88a-4a21-be03-979b9dc01bd4', '6ba17c87-c709-4670-9963-13c1bdfce840', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cc8fab44-37d1-4f3d-9604-b5da3ec64908', '41f9015b-e09c-40cb-b24b-c277dd7bae8a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cc8fab44-37d1-4f3d-9604-b5da3ec64908', '203e79b6-9246-4224-bfbc-313fdd3b6070', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cc8fab44-37d1-4f3d-9604-b5da3ec64908', '300f7881-8ecf-4b2f-9f6f-cc9768880546', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cc8fab44-37d1-4f3d-9604-b5da3ec64908', '6124df92-d88a-4a21-be03-979b9dc01bd4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cc8fab44-37d1-4f3d-9604-b5da3ec64908', '6ba17c87-c709-4670-9963-13c1bdfce840', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6ba17c87-c709-4670-9963-13c1bdfce840', '41f9015b-e09c-40cb-b24b-c277dd7bae8a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6ba17c87-c709-4670-9963-13c1bdfce840', '203e79b6-9246-4224-bfbc-313fdd3b6070', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6ba17c87-c709-4670-9963-13c1bdfce840', '300f7881-8ecf-4b2f-9f6f-cc9768880546', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6ba17c87-c709-4670-9963-13c1bdfce840', '6124df92-d88a-4a21-be03-979b9dc01bd4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6ba17c87-c709-4670-9963-13c1bdfce840', 'cc8fab44-37d1-4f3d-9604-b5da3ec64908', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9bf427d6-807b-421a-8bf8-baaed673b81b', '6deed81b-1ba8-4bf6-b90c-16398080dca3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9bf427d6-807b-421a-8bf8-baaed673b81b', '41f9015b-e09c-40cb-b24b-c277dd7bae8a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9bf427d6-807b-421a-8bf8-baaed673b81b', 'ef689b4e-d5ad-4889-893c-ba1e77353fc3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9bf427d6-807b-421a-8bf8-baaed673b81b', '203e79b6-9246-4224-bfbc-313fdd3b6070', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9bf427d6-807b-421a-8bf8-baaed673b81b', '300f7881-8ecf-4b2f-9f6f-cc9768880546', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6deed81b-1ba8-4bf6-b90c-16398080dca3', '9bf427d6-807b-421a-8bf8-baaed673b81b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6deed81b-1ba8-4bf6-b90c-16398080dca3', '41f9015b-e09c-40cb-b24b-c277dd7bae8a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6deed81b-1ba8-4bf6-b90c-16398080dca3', 'ef689b4e-d5ad-4889-893c-ba1e77353fc3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6deed81b-1ba8-4bf6-b90c-16398080dca3', '203e79b6-9246-4224-bfbc-313fdd3b6070', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6deed81b-1ba8-4bf6-b90c-16398080dca3', '300f7881-8ecf-4b2f-9f6f-cc9768880546', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9cbeefd6-e6ce-4de4-b839-49f371b86aae', '41f9015b-e09c-40cb-b24b-c277dd7bae8a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9cbeefd6-e6ce-4de4-b839-49f371b86aae', '203e79b6-9246-4224-bfbc-313fdd3b6070', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9cbeefd6-e6ce-4de4-b839-49f371b86aae', '300f7881-8ecf-4b2f-9f6f-cc9768880546', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9cbeefd6-e6ce-4de4-b839-49f371b86aae', '6124df92-d88a-4a21-be03-979b9dc01bd4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9cbeefd6-e6ce-4de4-b839-49f371b86aae', 'cc8fab44-37d1-4f3d-9604-b5da3ec64908', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('24a7820f-ec8c-4ef4-a309-cff12a4a320e', '41f9015b-e09c-40cb-b24b-c277dd7bae8a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('24a7820f-ec8c-4ef4-a309-cff12a4a320e', '203e79b6-9246-4224-bfbc-313fdd3b6070', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('24a7820f-ec8c-4ef4-a309-cff12a4a320e', '300f7881-8ecf-4b2f-9f6f-cc9768880546', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('24a7820f-ec8c-4ef4-a309-cff12a4a320e', '6124df92-d88a-4a21-be03-979b9dc01bd4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('24a7820f-ec8c-4ef4-a309-cff12a4a320e', 'cc8fab44-37d1-4f3d-9604-b5da3ec64908', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c8f89540-1aa4-419b-ac69-a423a6573a71', 'ef689b4e-d5ad-4889-893c-ba1e77353fc3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c8f89540-1aa4-419b-ac69-a423a6573a71', '41f9015b-e09c-40cb-b24b-c277dd7bae8a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c8f89540-1aa4-419b-ac69-a423a6573a71', '203e79b6-9246-4224-bfbc-313fdd3b6070', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c8f89540-1aa4-419b-ac69-a423a6573a71', '300f7881-8ecf-4b2f-9f6f-cc9768880546', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c8f89540-1aa4-419b-ac69-a423a6573a71', '6124df92-d88a-4a21-be03-979b9dc01bd4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bfb0df1b-d27a-4b0f-8546-f0e47d8b46b4', '41f9015b-e09c-40cb-b24b-c277dd7bae8a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bfb0df1b-d27a-4b0f-8546-f0e47d8b46b4', '203e79b6-9246-4224-bfbc-313fdd3b6070', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bfb0df1b-d27a-4b0f-8546-f0e47d8b46b4', '300f7881-8ecf-4b2f-9f6f-cc9768880546', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bfb0df1b-d27a-4b0f-8546-f0e47d8b46b4', '6124df92-d88a-4a21-be03-979b9dc01bd4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bfb0df1b-d27a-4b0f-8546-f0e47d8b46b4', 'cc8fab44-37d1-4f3d-9604-b5da3ec64908', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3e7b60c1-f898-49a2-9764-472e6061a6d5', 'be734907-f0da-4d3a-b408-9adc7d35d6ab', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3e7b60c1-f898-49a2-9764-472e6061a6d5', '4fd156a3-a978-4640-82d3-a85ea7965eb4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3e7b60c1-f898-49a2-9764-472e6061a6d5', '09f9ab7e-7c18-4e1f-bdcb-3e24da2b39de', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3e7b60c1-f898-49a2-9764-472e6061a6d5', '664c9b40-efdd-487e-b191-17b258509ae7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3e7b60c1-f898-49a2-9764-472e6061a6d5', '6689ceeb-b9bc-4e21-b798-bb269c470898', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4fd156a3-a978-4640-82d3-a85ea7965eb4', '3e7b60c1-f898-49a2-9764-472e6061a6d5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4fd156a3-a978-4640-82d3-a85ea7965eb4', '09f9ab7e-7c18-4e1f-bdcb-3e24da2b39de', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4fd156a3-a978-4640-82d3-a85ea7965eb4', '664c9b40-efdd-487e-b191-17b258509ae7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4fd156a3-a978-4640-82d3-a85ea7965eb4', '6689ceeb-b9bc-4e21-b798-bb269c470898', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4fd156a3-a978-4640-82d3-a85ea7965eb4', 'c029815c-0d4d-46ec-b638-e930e532b057', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('09f9ab7e-7c18-4e1f-bdcb-3e24da2b39de', '3e7b60c1-f898-49a2-9764-472e6061a6d5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('09f9ab7e-7c18-4e1f-bdcb-3e24da2b39de', '4fd156a3-a978-4640-82d3-a85ea7965eb4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('09f9ab7e-7c18-4e1f-bdcb-3e24da2b39de', '664c9b40-efdd-487e-b191-17b258509ae7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('09f9ab7e-7c18-4e1f-bdcb-3e24da2b39de', '6689ceeb-b9bc-4e21-b798-bb269c470898', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('09f9ab7e-7c18-4e1f-bdcb-3e24da2b39de', 'c029815c-0d4d-46ec-b638-e930e532b057', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('664c9b40-efdd-487e-b191-17b258509ae7', '6689ceeb-b9bc-4e21-b798-bb269c470898', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('664c9b40-efdd-487e-b191-17b258509ae7', 'c029815c-0d4d-46ec-b638-e930e532b057', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('664c9b40-efdd-487e-b191-17b258509ae7', 'f896cf88-a53d-4939-83a1-2314669aeb0a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('664c9b40-efdd-487e-b191-17b258509ae7', '3e7b60c1-f898-49a2-9764-472e6061a6d5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('664c9b40-efdd-487e-b191-17b258509ae7', '4fd156a3-a978-4640-82d3-a85ea7965eb4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6689ceeb-b9bc-4e21-b798-bb269c470898', '664c9b40-efdd-487e-b191-17b258509ae7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6689ceeb-b9bc-4e21-b798-bb269c470898', 'c029815c-0d4d-46ec-b638-e930e532b057', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6689ceeb-b9bc-4e21-b798-bb269c470898', 'f896cf88-a53d-4939-83a1-2314669aeb0a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6689ceeb-b9bc-4e21-b798-bb269c470898', '3e7b60c1-f898-49a2-9764-472e6061a6d5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6689ceeb-b9bc-4e21-b798-bb269c470898', '4fd156a3-a978-4640-82d3-a85ea7965eb4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c029815c-0d4d-46ec-b638-e930e532b057', '664c9b40-efdd-487e-b191-17b258509ae7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c029815c-0d4d-46ec-b638-e930e532b057', '6689ceeb-b9bc-4e21-b798-bb269c470898', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c029815c-0d4d-46ec-b638-e930e532b057', 'f896cf88-a53d-4939-83a1-2314669aeb0a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c029815c-0d4d-46ec-b638-e930e532b057', '3e7b60c1-f898-49a2-9764-472e6061a6d5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c029815c-0d4d-46ec-b638-e930e532b057', '4fd156a3-a978-4640-82d3-a85ea7965eb4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f896cf88-a53d-4939-83a1-2314669aeb0a', '664c9b40-efdd-487e-b191-17b258509ae7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f896cf88-a53d-4939-83a1-2314669aeb0a', '6689ceeb-b9bc-4e21-b798-bb269c470898', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f896cf88-a53d-4939-83a1-2314669aeb0a', 'c029815c-0d4d-46ec-b638-e930e532b057', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f896cf88-a53d-4939-83a1-2314669aeb0a', '3e7b60c1-f898-49a2-9764-472e6061a6d5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f896cf88-a53d-4939-83a1-2314669aeb0a', '4fd156a3-a978-4640-82d3-a85ea7965eb4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('be734907-f0da-4d3a-b408-9adc7d35d6ab', '3e7b60c1-f898-49a2-9764-472e6061a6d5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('be734907-f0da-4d3a-b408-9adc7d35d6ab', '4fd156a3-a978-4640-82d3-a85ea7965eb4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('be734907-f0da-4d3a-b408-9adc7d35d6ab', '09f9ab7e-7c18-4e1f-bdcb-3e24da2b39de', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('be734907-f0da-4d3a-b408-9adc7d35d6ab', '664c9b40-efdd-487e-b191-17b258509ae7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('be734907-f0da-4d3a-b408-9adc7d35d6ab', '6689ceeb-b9bc-4e21-b798-bb269c470898', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('18f8716d-87bd-4f93-8f41-acd31847e7b4', '3e7b60c1-f898-49a2-9764-472e6061a6d5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('18f8716d-87bd-4f93-8f41-acd31847e7b4', '4fd156a3-a978-4640-82d3-a85ea7965eb4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('18f8716d-87bd-4f93-8f41-acd31847e7b4', '09f9ab7e-7c18-4e1f-bdcb-3e24da2b39de', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('899e9a8a-9452-4e7f-ac13-f5133744da99', '3e7b60c1-f898-49a2-9764-472e6061a6d5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('899e9a8a-9452-4e7f-ac13-f5133744da99', '4fd156a3-a978-4640-82d3-a85ea7965eb4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('899e9a8a-9452-4e7f-ac13-f5133744da99', '09f9ab7e-7c18-4e1f-bdcb-3e24da2b39de', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('899e9a8a-9452-4e7f-ac13-f5133744da99', '664c9b40-efdd-487e-b191-17b258509ae7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('899e9a8a-9452-4e7f-ac13-f5133744da99', '6689ceeb-b9bc-4e21-b798-bb269c470898', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba8e7515-0ef4-4de9-b863-e07e3f5e18e9', '33e749fe-f621-4e0d-b573-ab725f6eecfb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba8e7515-0ef4-4de9-b863-e07e3f5e18e9', '33322f12-75e7-4c77-808f-643544922ef1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba8e7515-0ef4-4de9-b863-e07e3f5e18e9', '55d441a0-1831-4766-842e-6e2c2846b1d5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba8e7515-0ef4-4de9-b863-e07e3f5e18e9', 'b360242e-c646-4e07-9ab9-190659071aab', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba8e7515-0ef4-4de9-b863-e07e3f5e18e9', '8980ecae-5617-438f-b80b-b68936bfb7bb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5314ea3e-9589-40b3-905d-4848da5316b8', 'ba8e7515-0ef4-4de9-b863-e07e3f5e18e9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5314ea3e-9589-40b3-905d-4848da5316b8', '33e749fe-f621-4e0d-b573-ab725f6eecfb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5314ea3e-9589-40b3-905d-4848da5316b8', '33322f12-75e7-4c77-808f-643544922ef1', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5314ea3e-9589-40b3-905d-4848da5316b8', '55d441a0-1831-4766-842e-6e2c2846b1d5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5314ea3e-9589-40b3-905d-4848da5316b8', 'b360242e-c646-4e07-9ab9-190659071aab', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('33e749fe-f621-4e0d-b573-ab725f6eecfb', 'ba8e7515-0ef4-4de9-b863-e07e3f5e18e9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('33e749fe-f621-4e0d-b573-ab725f6eecfb', '33322f12-75e7-4c77-808f-643544922ef1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('33e749fe-f621-4e0d-b573-ab725f6eecfb', '55d441a0-1831-4766-842e-6e2c2846b1d5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('33e749fe-f621-4e0d-b573-ab725f6eecfb', 'b360242e-c646-4e07-9ab9-190659071aab', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('33e749fe-f621-4e0d-b573-ab725f6eecfb', '8980ecae-5617-438f-b80b-b68936bfb7bb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('55d441a0-1831-4766-842e-6e2c2846b1d5', 'ba8e7515-0ef4-4de9-b863-e07e3f5e18e9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('55d441a0-1831-4766-842e-6e2c2846b1d5', '33e749fe-f621-4e0d-b573-ab725f6eecfb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('55d441a0-1831-4766-842e-6e2c2846b1d5', 'b360242e-c646-4e07-9ab9-190659071aab', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('55d441a0-1831-4766-842e-6e2c2846b1d5', '33322f12-75e7-4c77-808f-643544922ef1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('55d441a0-1831-4766-842e-6e2c2846b1d5', '8980ecae-5617-438f-b80b-b68936bfb7bb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b360242e-c646-4e07-9ab9-190659071aab', 'ba8e7515-0ef4-4de9-b863-e07e3f5e18e9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b360242e-c646-4e07-9ab9-190659071aab', '33e749fe-f621-4e0d-b573-ab725f6eecfb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b360242e-c646-4e07-9ab9-190659071aab', '55d441a0-1831-4766-842e-6e2c2846b1d5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b360242e-c646-4e07-9ab9-190659071aab', '33322f12-75e7-4c77-808f-643544922ef1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b360242e-c646-4e07-9ab9-190659071aab', '8980ecae-5617-438f-b80b-b68936bfb7bb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c4b6fd1c-0584-4cf0-b5e3-f681f9013778', 'ba8e7515-0ef4-4de9-b863-e07e3f5e18e9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c4b6fd1c-0584-4cf0-b5e3-f681f9013778', '33e749fe-f621-4e0d-b573-ab725f6eecfb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c4b6fd1c-0584-4cf0-b5e3-f681f9013778', '55d441a0-1831-4766-842e-6e2c2846b1d5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f1cdff23-fedc-4fd3-a8d0-0e557b76d25a', 'ba8e7515-0ef4-4de9-b863-e07e3f5e18e9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f1cdff23-fedc-4fd3-a8d0-0e557b76d25a', '33e749fe-f621-4e0d-b573-ab725f6eecfb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f1cdff23-fedc-4fd3-a8d0-0e557b76d25a', '55d441a0-1831-4766-842e-6e2c2846b1d5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4ee841b6-d5c7-49cc-a15b-020e031422e4', 'b563b65f-00aa-4133-a2e6-9224fef5ae38', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4ee841b6-d5c7-49cc-a15b-020e031422e4', 'ea1d7563-de12-45f1-bbcc-fe3b56ed4c24', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4ee841b6-d5c7-49cc-a15b-020e031422e4', 'aa15354d-9140-45e7-950d-debe368a64bf', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4ee841b6-d5c7-49cc-a15b-020e031422e4', '74e4bb29-4c4f-49b3-aa8d-6c7446af72e6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4ee841b6-d5c7-49cc-a15b-020e031422e4', '513758e1-b088-4c86-b48f-45df505eef9f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aa15354d-9140-45e7-950d-debe368a64bf', '513758e1-b088-4c86-b48f-45df505eef9f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aa15354d-9140-45e7-950d-debe368a64bf', '4ee841b6-d5c7-49cc-a15b-020e031422e4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aa15354d-9140-45e7-950d-debe368a64bf', 'b563b65f-00aa-4133-a2e6-9224fef5ae38', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aa15354d-9140-45e7-950d-debe368a64bf', '74e4bb29-4c4f-49b3-aa8d-6c7446af72e6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aa15354d-9140-45e7-950d-debe368a64bf', 'ea1d7563-de12-45f1-bbcc-fe3b56ed4c24', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b563b65f-00aa-4133-a2e6-9224fef5ae38', '4ee841b6-d5c7-49cc-a15b-020e031422e4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b563b65f-00aa-4133-a2e6-9224fef5ae38', 'ea1d7563-de12-45f1-bbcc-fe3b56ed4c24', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b563b65f-00aa-4133-a2e6-9224fef5ae38', 'aa15354d-9140-45e7-950d-debe368a64bf', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b563b65f-00aa-4133-a2e6-9224fef5ae38', '74e4bb29-4c4f-49b3-aa8d-6c7446af72e6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b563b65f-00aa-4133-a2e6-9224fef5ae38', '513758e1-b088-4c86-b48f-45df505eef9f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('74e4bb29-4c4f-49b3-aa8d-6c7446af72e6', '4ee841b6-d5c7-49cc-a15b-020e031422e4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('74e4bb29-4c4f-49b3-aa8d-6c7446af72e6', 'aa15354d-9140-45e7-950d-debe368a64bf', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('74e4bb29-4c4f-49b3-aa8d-6c7446af72e6', 'b563b65f-00aa-4133-a2e6-9224fef5ae38', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('74e4bb29-4c4f-49b3-aa8d-6c7446af72e6', '513758e1-b088-4c86-b48f-45df505eef9f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('74e4bb29-4c4f-49b3-aa8d-6c7446af72e6', 'ea1d7563-de12-45f1-bbcc-fe3b56ed4c24', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('513758e1-b088-4c86-b48f-45df505eef9f', 'aa15354d-9140-45e7-950d-debe368a64bf', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('513758e1-b088-4c86-b48f-45df505eef9f', '4ee841b6-d5c7-49cc-a15b-020e031422e4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('513758e1-b088-4c86-b48f-45df505eef9f', 'b563b65f-00aa-4133-a2e6-9224fef5ae38', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('513758e1-b088-4c86-b48f-45df505eef9f', '74e4bb29-4c4f-49b3-aa8d-6c7446af72e6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('513758e1-b088-4c86-b48f-45df505eef9f', 'ea1d7563-de12-45f1-bbcc-fe3b56ed4c24', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('97fc17e9-7835-4fc9-9a92-f137e11f37f3', '647a0fa9-1de9-4f58-8525-0a076d90d26c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('97fc17e9-7835-4fc9-9a92-f137e11f37f3', 'ba8e7515-0ef4-4de9-b863-e07e3f5e18e9', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('97fc17e9-7835-4fc9-9a92-f137e11f37f3', '33e749fe-f621-4e0d-b573-ab725f6eecfb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('33322f12-75e7-4c77-808f-643544922ef1', 'ba8e7515-0ef4-4de9-b863-e07e3f5e18e9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('33322f12-75e7-4c77-808f-643544922ef1', '33e749fe-f621-4e0d-b573-ab725f6eecfb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('33322f12-75e7-4c77-808f-643544922ef1', '55d441a0-1831-4766-842e-6e2c2846b1d5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('33322f12-75e7-4c77-808f-643544922ef1', 'b360242e-c646-4e07-9ab9-190659071aab', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('33322f12-75e7-4c77-808f-643544922ef1', '8980ecae-5617-438f-b80b-b68936bfb7bb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1a0575d5-7af8-4d3e-9a50-189e7e1df2e8', 'ba8e7515-0ef4-4de9-b863-e07e3f5e18e9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1a0575d5-7af8-4d3e-9a50-189e7e1df2e8', '33e749fe-f621-4e0d-b573-ab725f6eecfb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1a0575d5-7af8-4d3e-9a50-189e7e1df2e8', '55d441a0-1831-4766-842e-6e2c2846b1d5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8980ecae-5617-438f-b80b-b68936bfb7bb', 'ba8e7515-0ef4-4de9-b863-e07e3f5e18e9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8980ecae-5617-438f-b80b-b68936bfb7bb', '33e749fe-f621-4e0d-b573-ab725f6eecfb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8980ecae-5617-438f-b80b-b68936bfb7bb', '55d441a0-1831-4766-842e-6e2c2846b1d5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8980ecae-5617-438f-b80b-b68936bfb7bb', 'b360242e-c646-4e07-9ab9-190659071aab', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8980ecae-5617-438f-b80b-b68936bfb7bb', '33322f12-75e7-4c77-808f-643544922ef1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('647a0fa9-1de9-4f58-8525-0a076d90d26c', '97fc17e9-7835-4fc9-9a92-f137e11f37f3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('647a0fa9-1de9-4f58-8525-0a076d90d26c', 'ba8e7515-0ef4-4de9-b863-e07e3f5e18e9', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('647a0fa9-1de9-4f58-8525-0a076d90d26c', '33e749fe-f621-4e0d-b573-ab725f6eecfb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ea1d7563-de12-45f1-bbcc-fe3b56ed4c24', '4ee841b6-d5c7-49cc-a15b-020e031422e4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ea1d7563-de12-45f1-bbcc-fe3b56ed4c24', 'b563b65f-00aa-4133-a2e6-9224fef5ae38', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ea1d7563-de12-45f1-bbcc-fe3b56ed4c24', 'aa15354d-9140-45e7-950d-debe368a64bf', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ea1d7563-de12-45f1-bbcc-fe3b56ed4c24', '74e4bb29-4c4f-49b3-aa8d-6c7446af72e6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ea1d7563-de12-45f1-bbcc-fe3b56ed4c24', '513758e1-b088-4c86-b48f-45df505eef9f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('65807324-fcfe-457c-86e0-d9038ac505eb', '52382b55-a14b-4ca7-9b8f-01a9f6854d5f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('65807324-fcfe-457c-86e0-d9038ac505eb', '731672da-cbb2-4468-b51f-d9069ef43059', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('65807324-fcfe-457c-86e0-d9038ac505eb', 'ba8e7515-0ef4-4de9-b863-e07e3f5e18e9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('52382b55-a14b-4ca7-9b8f-01a9f6854d5f', '65807324-fcfe-457c-86e0-d9038ac505eb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('52382b55-a14b-4ca7-9b8f-01a9f6854d5f', '731672da-cbb2-4468-b51f-d9069ef43059', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('52382b55-a14b-4ca7-9b8f-01a9f6854d5f', 'ba8e7515-0ef4-4de9-b863-e07e3f5e18e9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('731672da-cbb2-4468-b51f-d9069ef43059', '65807324-fcfe-457c-86e0-d9038ac505eb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('731672da-cbb2-4468-b51f-d9069ef43059', '52382b55-a14b-4ca7-9b8f-01a9f6854d5f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('731672da-cbb2-4468-b51f-d9069ef43059', 'ba8e7515-0ef4-4de9-b863-e07e3f5e18e9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('801c9df5-cae5-44c9-9d36-c02fbc920322', 'f51f344c-441e-4b84-8777-4135164a8d7c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('801c9df5-cae5-44c9-9d36-c02fbc920322', '82ff63d2-a963-42a7-a549-d12ecfeae048', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('801c9df5-cae5-44c9-9d36-c02fbc920322', 'a68e34eb-e561-457f-8115-85a1e64fc530', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('801c9df5-cae5-44c9-9d36-c02fbc920322', 'f2fb9cc7-3322-4236-a6d4-7254637d4e01', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f51f344c-441e-4b84-8777-4135164a8d7c', '801c9df5-cae5-44c9-9d36-c02fbc920322', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f51f344c-441e-4b84-8777-4135164a8d7c', '82ff63d2-a963-42a7-a549-d12ecfeae048', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f51f344c-441e-4b84-8777-4135164a8d7c', 'a68e34eb-e561-457f-8115-85a1e64fc530', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f51f344c-441e-4b84-8777-4135164a8d7c', 'f2fb9cc7-3322-4236-a6d4-7254637d4e01', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('82ff63d2-a963-42a7-a549-d12ecfeae048', '801c9df5-cae5-44c9-9d36-c02fbc920322', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('82ff63d2-a963-42a7-a549-d12ecfeae048', 'f51f344c-441e-4b84-8777-4135164a8d7c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('82ff63d2-a963-42a7-a549-d12ecfeae048', 'a68e34eb-e561-457f-8115-85a1e64fc530', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('82ff63d2-a963-42a7-a549-d12ecfeae048', 'f2fb9cc7-3322-4236-a6d4-7254637d4e01', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a68e34eb-e561-457f-8115-85a1e64fc530', '801c9df5-cae5-44c9-9d36-c02fbc920322', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a68e34eb-e561-457f-8115-85a1e64fc530', 'f51f344c-441e-4b84-8777-4135164a8d7c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a68e34eb-e561-457f-8115-85a1e64fc530', '82ff63d2-a963-42a7-a549-d12ecfeae048', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a68e34eb-e561-457f-8115-85a1e64fc530', 'f2fb9cc7-3322-4236-a6d4-7254637d4e01', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f2fb9cc7-3322-4236-a6d4-7254637d4e01', '801c9df5-cae5-44c9-9d36-c02fbc920322', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f2fb9cc7-3322-4236-a6d4-7254637d4e01', 'f51f344c-441e-4b84-8777-4135164a8d7c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f2fb9cc7-3322-4236-a6d4-7254637d4e01', '82ff63d2-a963-42a7-a549-d12ecfeae048', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f2fb9cc7-3322-4236-a6d4-7254637d4e01', 'a68e34eb-e561-457f-8115-85a1e64fc530', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7e1abedc-8936-49a0-9171-0f2f1e1e33bb', 'f0b4f3f0-cd34-4f50-bd00-2a88a6e5a7e1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7e1abedc-8936-49a0-9171-0f2f1e1e33bb', '6137f5b4-0cc1-4b1c-9e2b-0e9bdb114b8a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0b4f3f0-cd34-4f50-bd00-2a88a6e5a7e1', '7e1abedc-8936-49a0-9171-0f2f1e1e33bb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0b4f3f0-cd34-4f50-bd00-2a88a6e5a7e1', '6137f5b4-0cc1-4b1c-9e2b-0e9bdb114b8a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6137f5b4-0cc1-4b1c-9e2b-0e9bdb114b8a', '7e1abedc-8936-49a0-9171-0f2f1e1e33bb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6137f5b4-0cc1-4b1c-9e2b-0e9bdb114b8a', 'f0b4f3f0-cd34-4f50-bd00-2a88a6e5a7e1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a48a919c-0706-40a4-a50c-2121fea51f04', 'f802dc53-7dae-4c8e-88f9-205160433a9e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a48a919c-0706-40a4-a50c-2121fea51f04', 'b6cbf67a-fe33-4ced-92f1-1a006023acd9', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a48a919c-0706-40a4-a50c-2121fea51f04', '93c5bc26-50c9-4d10-b9d8-dc8d9f68a313', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a48a919c-0706-40a4-a50c-2121fea51f04', 'f60c851d-270b-4ca5-83d9-c6e4e88902dd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a48a919c-0706-40a4-a50c-2121fea51f04', '0fd85dca-eb00-48fb-9d8d-6af147bda7cd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b6cbf67a-fe33-4ced-92f1-1a006023acd9', 'f802dc53-7dae-4c8e-88f9-205160433a9e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b6cbf67a-fe33-4ced-92f1-1a006023acd9', 'a48a919c-0706-40a4-a50c-2121fea51f04', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b6cbf67a-fe33-4ced-92f1-1a006023acd9', '93c5bc26-50c9-4d10-b9d8-dc8d9f68a313', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b6cbf67a-fe33-4ced-92f1-1a006023acd9', 'f60c851d-270b-4ca5-83d9-c6e4e88902dd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b6cbf67a-fe33-4ced-92f1-1a006023acd9', '0fd85dca-eb00-48fb-9d8d-6af147bda7cd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('93c5bc26-50c9-4d10-b9d8-dc8d9f68a313', 'f802dc53-7dae-4c8e-88f9-205160433a9e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('93c5bc26-50c9-4d10-b9d8-dc8d9f68a313', 'a48a919c-0706-40a4-a50c-2121fea51f04', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('93c5bc26-50c9-4d10-b9d8-dc8d9f68a313', 'b6cbf67a-fe33-4ced-92f1-1a006023acd9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('93c5bc26-50c9-4d10-b9d8-dc8d9f68a313', 'f60c851d-270b-4ca5-83d9-c6e4e88902dd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('93c5bc26-50c9-4d10-b9d8-dc8d9f68a313', '0fd85dca-eb00-48fb-9d8d-6af147bda7cd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0fd85dca-eb00-48fb-9d8d-6af147bda7cd', 'f802dc53-7dae-4c8e-88f9-205160433a9e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0fd85dca-eb00-48fb-9d8d-6af147bda7cd', 'f60c851d-270b-4ca5-83d9-c6e4e88902dd', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0fd85dca-eb00-48fb-9d8d-6af147bda7cd', 'a48a919c-0706-40a4-a50c-2121fea51f04', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0fd85dca-eb00-48fb-9d8d-6af147bda7cd', 'b6cbf67a-fe33-4ced-92f1-1a006023acd9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0fd85dca-eb00-48fb-9d8d-6af147bda7cd', '93c5bc26-50c9-4d10-b9d8-dc8d9f68a313', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('08880eb8-7d98-44af-9369-55d6b7e4d1db', 'ccdf4687-a3f1-4b1c-a312-f3070282a0f0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('08880eb8-7d98-44af-9369-55d6b7e4d1db', '922a1283-452c-432f-8b79-8f210cb238e0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ccdf4687-a3f1-4b1c-a312-f3070282a0f0', '08880eb8-7d98-44af-9369-55d6b7e4d1db', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ccdf4687-a3f1-4b1c-a312-f3070282a0f0', '922a1283-452c-432f-8b79-8f210cb238e0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('922a1283-452c-432f-8b79-8f210cb238e0', '08880eb8-7d98-44af-9369-55d6b7e4d1db', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('922a1283-452c-432f-8b79-8f210cb238e0', 'ccdf4687-a3f1-4b1c-a312-f3070282a0f0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3dcd648f-24d7-46e3-90c6-fff8d9b8bbbf', '86fef347-6455-43ec-9438-06eb63bbe33d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3dcd648f-24d7-46e3-90c6-fff8d9b8bbbf', '9d1babb8-b2f3-473a-9983-21df7207983c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3dcd648f-24d7-46e3-90c6-fff8d9b8bbbf', 'fe98e001-1eed-4172-8120-6d245c69f6b3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('86fef347-6455-43ec-9438-06eb63bbe33d', 'fe98e001-1eed-4172-8120-6d245c69f6b3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('86fef347-6455-43ec-9438-06eb63bbe33d', '3dcd648f-24d7-46e3-90c6-fff8d9b8bbbf', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('86fef347-6455-43ec-9438-06eb63bbe33d', '9d1babb8-b2f3-473a-9983-21df7207983c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9d1babb8-b2f3-473a-9983-21df7207983c', '3dcd648f-24d7-46e3-90c6-fff8d9b8bbbf', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9d1babb8-b2f3-473a-9983-21df7207983c', '86fef347-6455-43ec-9438-06eb63bbe33d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9d1babb8-b2f3-473a-9983-21df7207983c', 'fe98e001-1eed-4172-8120-6d245c69f6b3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe98e001-1eed-4172-8120-6d245c69f6b3', '86fef347-6455-43ec-9438-06eb63bbe33d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe98e001-1eed-4172-8120-6d245c69f6b3', '3dcd648f-24d7-46e3-90c6-fff8d9b8bbbf', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe98e001-1eed-4172-8120-6d245c69f6b3', '9d1babb8-b2f3-473a-9983-21df7207983c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4d08c298-9d76-4019-a17d-fbad6b7ef6f8', 'c51cb1ea-4866-40b8-bd29-9cdc701a4919', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4d08c298-9d76-4019-a17d-fbad6b7ef6f8', 'cb244032-272c-4450-a5b0-56244a3a5361', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4d08c298-9d76-4019-a17d-fbad6b7ef6f8', '6f155850-05a4-4989-8bee-caf4b86c501c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4d08c298-9d76-4019-a17d-fbad6b7ef6f8', 'e4b016ad-e1c1-416e-b28a-896e8afc610b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4d08c298-9d76-4019-a17d-fbad6b7ef6f8', '29f6aa16-98f7-4750-8c75-ab831c6685e4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c51cb1ea-4866-40b8-bd29-9cdc701a4919', '4d08c298-9d76-4019-a17d-fbad6b7ef6f8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c51cb1ea-4866-40b8-bd29-9cdc701a4919', 'cb244032-272c-4450-a5b0-56244a3a5361', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c51cb1ea-4866-40b8-bd29-9cdc701a4919', '6f155850-05a4-4989-8bee-caf4b86c501c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c51cb1ea-4866-40b8-bd29-9cdc701a4919', 'e4b016ad-e1c1-416e-b28a-896e8afc610b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c51cb1ea-4866-40b8-bd29-9cdc701a4919', '29f6aa16-98f7-4750-8c75-ab831c6685e4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cb244032-272c-4450-a5b0-56244a3a5361', 'fed2559c-c6c0-4508-948a-552368c53935', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cb244032-272c-4450-a5b0-56244a3a5361', '4d08c298-9d76-4019-a17d-fbad6b7ef6f8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cb244032-272c-4450-a5b0-56244a3a5361', 'c51cb1ea-4866-40b8-bd29-9cdc701a4919', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cb244032-272c-4450-a5b0-56244a3a5361', '6f155850-05a4-4989-8bee-caf4b86c501c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cb244032-272c-4450-a5b0-56244a3a5361', 'e4b016ad-e1c1-416e-b28a-896e8afc610b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6f155850-05a4-4989-8bee-caf4b86c501c', '4d08c298-9d76-4019-a17d-fbad6b7ef6f8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6f155850-05a4-4989-8bee-caf4b86c501c', 'c51cb1ea-4866-40b8-bd29-9cdc701a4919', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6f155850-05a4-4989-8bee-caf4b86c501c', 'cb244032-272c-4450-a5b0-56244a3a5361', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6f155850-05a4-4989-8bee-caf4b86c501c', 'e4b016ad-e1c1-416e-b28a-896e8afc610b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6f155850-05a4-4989-8bee-caf4b86c501c', '29f6aa16-98f7-4750-8c75-ab831c6685e4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e4b016ad-e1c1-416e-b28a-896e8afc610b', '4d08c298-9d76-4019-a17d-fbad6b7ef6f8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e4b016ad-e1c1-416e-b28a-896e8afc610b', 'c51cb1ea-4866-40b8-bd29-9cdc701a4919', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e4b016ad-e1c1-416e-b28a-896e8afc610b', 'cb244032-272c-4450-a5b0-56244a3a5361', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e4b016ad-e1c1-416e-b28a-896e8afc610b', '6f155850-05a4-4989-8bee-caf4b86c501c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e4b016ad-e1c1-416e-b28a-896e8afc610b', '29f6aa16-98f7-4750-8c75-ab831c6685e4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('29f6aa16-98f7-4750-8c75-ab831c6685e4', '4d08c298-9d76-4019-a17d-fbad6b7ef6f8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('29f6aa16-98f7-4750-8c75-ab831c6685e4', 'c51cb1ea-4866-40b8-bd29-9cdc701a4919', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('29f6aa16-98f7-4750-8c75-ab831c6685e4', 'cb244032-272c-4450-a5b0-56244a3a5361', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('29f6aa16-98f7-4750-8c75-ab831c6685e4', '6f155850-05a4-4989-8bee-caf4b86c501c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('29f6aa16-98f7-4750-8c75-ab831c6685e4', 'e4b016ad-e1c1-416e-b28a-896e8afc610b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba1a6b58-4053-4ad3-849d-09ed17d0469d', '4d08c298-9d76-4019-a17d-fbad6b7ef6f8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba1a6b58-4053-4ad3-849d-09ed17d0469d', 'c51cb1ea-4866-40b8-bd29-9cdc701a4919', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba1a6b58-4053-4ad3-849d-09ed17d0469d', 'cb244032-272c-4450-a5b0-56244a3a5361', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba1a6b58-4053-4ad3-849d-09ed17d0469d', '6f155850-05a4-4989-8bee-caf4b86c501c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba1a6b58-4053-4ad3-849d-09ed17d0469d', 'e4b016ad-e1c1-416e-b28a-896e8afc610b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fed2559c-c6c0-4508-948a-552368c53935', 'cb244032-272c-4450-a5b0-56244a3a5361', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fed2559c-c6c0-4508-948a-552368c53935', '4d08c298-9d76-4019-a17d-fbad6b7ef6f8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fed2559c-c6c0-4508-948a-552368c53935', 'c51cb1ea-4866-40b8-bd29-9cdc701a4919', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fed2559c-c6c0-4508-948a-552368c53935', '6f155850-05a4-4989-8bee-caf4b86c501c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fed2559c-c6c0-4508-948a-552368c53935', 'e4b016ad-e1c1-416e-b28a-896e8afc610b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0f4a5d4-60ef-4a1b-8c38-6494dd356deb', '4d08c298-9d76-4019-a17d-fbad6b7ef6f8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0f4a5d4-60ef-4a1b-8c38-6494dd356deb', 'c51cb1ea-4866-40b8-bd29-9cdc701a4919', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0f4a5d4-60ef-4a1b-8c38-6494dd356deb', 'cb244032-272c-4450-a5b0-56244a3a5361', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0f4a5d4-60ef-4a1b-8c38-6494dd356deb', '6f155850-05a4-4989-8bee-caf4b86c501c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0f4a5d4-60ef-4a1b-8c38-6494dd356deb', 'e4b016ad-e1c1-416e-b28a-896e8afc610b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a5b82b2d-5366-4c70-9019-a243bd0e5fa0', '8a92bbfb-a3c5-4dbc-9697-ea753f61826a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('add3dc83-d283-4c33-b771-d5839c23398f', '8a92bbfb-a3c5-4dbc-9697-ea753f61826a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f107174f-ba4d-41c8-a5e1-22d622efc73d', '8a92bbfb-a3c5-4dbc-9697-ea753f61826a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9da1602-3c87-447f-8373-f32deabb074e', '8a92bbfb-a3c5-4dbc-9697-ea753f61826a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0cf7ed1a-32bf-4c6c-9fea-8b72c23dac60', '8a92bbfb-a3c5-4dbc-9697-ea753f61826a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('365b2793-cfeb-49af-a9b2-9a3e501fb522', '8a92bbfb-a3c5-4dbc-9697-ea753f61826a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b60c8cfb-5d08-449e-a434-0b6bf2f7a138', '34afce1e-d9de-46d8-8c01-db47660e5afe', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b60c8cfb-5d08-449e-a434-0b6bf2f7a138', 'dbbefc75-074e-493e-9ceb-b0a5d07e1bda', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b60c8cfb-5d08-449e-a434-0b6bf2f7a138', 'fa7ebcfd-0904-463c-a85a-1712e09cf236', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('34afce1e-d9de-46d8-8c01-db47660e5afe', 'b60c8cfb-5d08-449e-a434-0b6bf2f7a138', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('34afce1e-d9de-46d8-8c01-db47660e5afe', 'dbbefc75-074e-493e-9ceb-b0a5d07e1bda', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('34afce1e-d9de-46d8-8c01-db47660e5afe', 'fa7ebcfd-0904-463c-a85a-1712e09cf236', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dbbefc75-074e-493e-9ceb-b0a5d07e1bda', 'fa7ebcfd-0904-463c-a85a-1712e09cf236', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dbbefc75-074e-493e-9ceb-b0a5d07e1bda', 'b60c8cfb-5d08-449e-a434-0b6bf2f7a138', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dbbefc75-074e-493e-9ceb-b0a5d07e1bda', '34afce1e-d9de-46d8-8c01-db47660e5afe', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fa7ebcfd-0904-463c-a85a-1712e09cf236', 'dbbefc75-074e-493e-9ceb-b0a5d07e1bda', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fa7ebcfd-0904-463c-a85a-1712e09cf236', 'b60c8cfb-5d08-449e-a434-0b6bf2f7a138', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fa7ebcfd-0904-463c-a85a-1712e09cf236', '34afce1e-d9de-46d8-8c01-db47660e5afe', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4e113937-bc8a-4a76-8e6a-9c5f8aaa17af', 'f84d66c2-024f-454b-aea1-a931ccbc447e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4e113937-bc8a-4a76-8e6a-9c5f8aaa17af', '1dd715a7-ded4-4f72-9138-644b91c31a55', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('816474e2-5713-4a5f-a3c0-13dbfff4e67f', '4e113937-bc8a-4a76-8e6a-9c5f8aaa17af', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('816474e2-5713-4a5f-a3c0-13dbfff4e67f', 'f84d66c2-024f-454b-aea1-a931ccbc447e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('816474e2-5713-4a5f-a3c0-13dbfff4e67f', '1dd715a7-ded4-4f72-9138-644b91c31a55', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f3dfc00d-056e-4a51-8e84-c6f5a82277ec', '4e113937-bc8a-4a76-8e6a-9c5f8aaa17af', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f3dfc00d-056e-4a51-8e84-c6f5a82277ec', 'f84d66c2-024f-454b-aea1-a931ccbc447e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f3dfc00d-056e-4a51-8e84-c6f5a82277ec', '1dd715a7-ded4-4f72-9138-644b91c31a55', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f84d66c2-024f-454b-aea1-a931ccbc447e', '4e113937-bc8a-4a76-8e6a-9c5f8aaa17af', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f84d66c2-024f-454b-aea1-a931ccbc447e', '1dd715a7-ded4-4f72-9138-644b91c31a55', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('18901064-b1a7-4a02-a99b-48bb3ac9470b', '4e113937-bc8a-4a76-8e6a-9c5f8aaa17af', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('18901064-b1a7-4a02-a99b-48bb3ac9470b', 'f84d66c2-024f-454b-aea1-a931ccbc447e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('18901064-b1a7-4a02-a99b-48bb3ac9470b', '1dd715a7-ded4-4f72-9138-644b91c31a55', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b60f6efb-d3cf-4603-ac9b-186bbf1fc7a4', '4e113937-bc8a-4a76-8e6a-9c5f8aaa17af', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b60f6efb-d3cf-4603-ac9b-186bbf1fc7a4', 'f84d66c2-024f-454b-aea1-a931ccbc447e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b60f6efb-d3cf-4603-ac9b-186bbf1fc7a4', '1dd715a7-ded4-4f72-9138-644b91c31a55', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1dd715a7-ded4-4f72-9138-644b91c31a55', '4e113937-bc8a-4a76-8e6a-9c5f8aaa17af', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1dd715a7-ded4-4f72-9138-644b91c31a55', 'f84d66c2-024f-454b-aea1-a931ccbc447e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16041e30-ccf2-4ae1-8133-e6a6c3d875dc', '4e113937-bc8a-4a76-8e6a-9c5f8aaa17af', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16041e30-ccf2-4ae1-8133-e6a6c3d875dc', 'f84d66c2-024f-454b-aea1-a931ccbc447e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16041e30-ccf2-4ae1-8133-e6a6c3d875dc', '1dd715a7-ded4-4f72-9138-644b91c31a55', 2) ON CONFLICT DO NOTHING;



INSERT INTO public.faqs VALUES ('6b72cf8a-4c4f-4eb1-97a2-44a3fadf4334', 'متى يوصلني الرد بعد الاشتراك؟', 'خلال 48 ساعة عمل. أيام العمل من الأحد إلى الخميس، من 12 الظهر حتى 9 مساءً، والتواصل على واتساب.', 0, true, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('59402cf8-0c0d-44c9-a382-a6384f0c90e6', 'كيف تتم المتابعة؟', 'المراجعة الأسبوعية تُرسل في يوم المراجعة، وأرد عليها بتعديلات مسجلة (فيديو أو صوت). في الباقة الأساسية المتابعة كل أسبوعين. التواصل اليومي على واتساب مع رد خلال 48 ساعة.', 1, true, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('46a6a7b1-c8ea-4f9c-a39c-c0b2beb0c37a', 'هل يناسب المبتدئين تماماً؟', 'نعم. البرنامج يُبنى على مستواك الحالي، والتمارين مشروحة، وبإمكانك إرسال مقاطع الأداء لتصحيح التكنيك.', 2, true, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('6b3c299a-a604-41ec-823e-5062fe7f9a47', 'أتمرن في البيت، ماذا أحتاج من أدوات؟', 'النموذج فيه خانة للأدوات المتوفرة (دمبلز، حبال مقاومة، بار…) ويُبنى جدولك عليها.', 3, true, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('b674102e-98f4-4554-b60d-3464267bd341', 'كيف أدفع؟', 'بتحويل بنكي بعد تعبئة الاستبيان. أول ما يُرسل الاستبيان يظهر رقم الطلب والمبلغ وبيانات الحساب. تحويل المبلغ ثم رفع صورة الإيصال من صفحة الطلب، ويتأكد اشتراكك بعد التحقق من وصول المبلغ.', 4, true, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('1a1ec7e4-f469-43ef-abc4-7cff25e64fb5', 'ما شروط ضمان استرجاع المبلغ؟', 'في اشتراكات 3 أشهر لباقات المتابعة (المكثفة، المتقدمة، الأساسية): إذا لم يتحسن أي مؤشر من مؤشرات تقدمك بعد 12 أسبوعاً، يُسترجع المبلغ كاملاً.
مؤشرات التقدم (بحسب هدفك): متوسط الوزن الأسبوعي، أو محيط الخصر، أو القوة في التمارين الأساسية (الوزن أو التكرارات).
شروط الضمان:
- إرسال المراجعة الأسبوعية كل أسبوع.
- أخذ القياسات بانتظام.
- تصوير التمارين وإرسالها.
- الالتزام بجدول التغذية المخصص (في الباقات التي تشمل تغذية).
يُطلب الاسترجاع عبر واتساب خلال 14 يوماً من نهاية الأشهر الثلاثة.', 5, true, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('01eb7c50-5424-4094-926c-6097740565eb', 'هل الجداول لي بعد انتهاء الاشتراك؟', 'نعم، جميع الجداول لك مدى الحياة والتعديل عليها متاح.', 6, true, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('a49517d8-b276-4961-a4a7-263848fc466c', 'ما هو التجديد المجاني؟', 'مكافأة للملتزمين: اشتراك 3 أشهر يحصل على 3 أشهر إضافية مجاناً، فيصير المجموع 6 أشهر بسعر 3.
الشروط:
- نسبة التزام 90% فأكثر: المراجعات الأسبوعية المرسلة والتمارين المسجلة.
- تقدم واضح في مؤشرات التقدم نفسها المذكورة في الضمان.
- للمتدربين الرجال: إرسال صور التطور (قبل وبعد) للمدربة للتوثيق، مع تغطية الوجه والسرة.
نشر الصور في السوشل ميديا اختياري بالكامل حسب موافقتك، ولا يؤثر على استحقاقك للتجديد.', 7, true, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('086a8cc5-2ef2-4f89-8024-61fcf5a16512', 'من يطّلع على بياناتي؟', 'المدربة فقط، وتُستخدم لتصميم برنامجك ومتابعتك. لا تُنشر نتيجتك أو صورتك إلا بموافقتك الصريحة في النموذج.', 8, true, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;



INSERT INTO public.foods VALUES ('0e1402b0-7d5d-4ede-82b2-afba6c87d0b6', 'زبادي يوناني كامل الدسم توت أزرق (ندى)', 'Nada Greek Yoghurt Blueberry Full Cream', 'زبادي يوناني', 147.0, 7.0, 14.0, 7.0, NULL, NULL, 'coach', 'nada.com.sa/greek-yoghurt-with-blueberry', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('4cf2eadb-b3d0-42c4-87d8-891cee1fc640', 'خيار', 'Cucumber, with peel, raw', 'خضار', 15.0, 0.7, 3.6, 0.1, 100.0, NULL, 'usda', '168409', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'خضار', 0.5, '{"iron": 0.28, "zinc": 0.2, "vit_a": 5, "vit_c": 2.8, "vit_d": 0, "vit_e": 0.03, "vit_k": 16.4, "folate": 7, "vit_b6": 0.04, "calcium": 16, "vit_b12": 0, "magnesium": 13, "potassium": 147}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('204469d9-85d5-475a-a04c-c54470dbbdcc', 'رز أبيض مطبوخ', 'Rice, white, long-grain, regular, enriched, cooked', 'حبوب ونشويات', 130.0, 2.7, 28.2, 0.3, 150.0, 'كوب إلا ربع', 'usda', '168878', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'حبوب ونشويات', 0.4, '{"iron": 1.2, "zinc": 0.49, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.04, "vit_k": 0, "folate": 97, "vit_b6": 0.093, "calcium": 10, "vit_b12": 0, "magnesium": 12, "potassium": 35}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('0fe2a5b3-1224-4035-ad77-46c62d19c605', 'رز بني مطبوخ', 'Rice, brown, long-grain, cooked (Includes foods for USDA''s Food Distribution Program)', 'حبوب ونشويات', 123.0, 2.7, 25.6, 1.0, 150.0, NULL, 'usda', '169704', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'حبوب ونشويات', 1.6, '{"iron": 0.56, "zinc": 0.71, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.17, "vit_k": 0.2, "folate": 9, "vit_b6": 0.123, "calcium": 3, "vit_b12": 0, "magnesium": 39, "potassium": 86}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('372f8114-c4b0-406b-827c-d6f9123cbee5', 'ماسل ميلك شوكولاتة (المراعي 400 مل)', 'Almarai Muscle Milk Chocolate 400ml', 'مشروبات بروتينية', 68.0, 10.0, 6.1, 0.3, 400.0, 'عبوة 400 مل', 'coach', 'almarai.com/muscle-milk-chocolate', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('e3dc2f65-1d28-4991-a383-1f684fce6cbd', 'رز أبيض (غير مطبوخ)', 'Rice, white, long-grain, regular, raw, enriched', 'حبوب ونشويات', 365.0, 7.1, 80.0, 0.7, 75.0, NULL, 'usda', '168877', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'حبوب ونشويات', 1.3, '{"iron": 4.31, "zinc": 1.09, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.11, "vit_k": 0.1, "folate": 387, "vit_b6": 0.164, "calcium": 28, "vit_b12": 0, "magnesium": 25, "potassium": 115}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('febffd43-d420-48bd-b541-97b07d3e6cb1', 'مكرونة مطبوخة', 'Pasta, cooked, enriched, without added salt', 'حبوب ونشويات', 158.0, 5.8, 30.9, 0.9, 140.0, 'كوب', 'usda', '169737', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'حبوب ونشويات', 1.8, '{"iron": 1.28, "zinc": 0.51, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.06, "vit_k": 0, "folate": 119, "vit_b6": 0.049, "calcium": 7, "vit_b12": 0, "magnesium": 18, "potassium": 44}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('5540a94d-093a-490f-ac2f-ea23e08d236e', 'مكرونة (غير مطبوخة)', 'Pasta, dry, enriched', 'حبوب ونشويات', 371.0, 13.0, 74.7, 1.5, 75.0, NULL, 'usda', '169736', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'حبوب ونشويات', 3.2, '{"iron": 3.3, "zinc": 1.41, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.11, "vit_k": 0.1, "folate": 391, "vit_b6": 0.142, "calcium": 21, "vit_b12": 0, "magnesium": 53, "potassium": 223}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('01a9b13b-a139-4175-9f64-2fe124071fce', 'شوفان', 'Cereals, oats, regular and quick, not fortified, dry', 'حبوب ونشويات', 379.0, 13.2, 67.7, 6.5, 40.0, 'نص كوب', 'usda', '173904', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'حبوب ونشويات', 10.1, '{"iron": 4.25, "zinc": 3.64, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.42, "vit_k": 2, "folate": 32, "vit_b6": 0.1, "calcium": 52, "vit_b12": 0, "magnesium": 138, "potassium": 362}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b346f877-0eab-42fe-ba69-649e0e7fd7e8', 'خبز أبيض (توست)', 'Bread, white, commercially prepared (includes soft bread crumbs)', 'خبز', 266.0, 8.9, 49.4, 3.3, 28.0, 'شريحة', 'usda', '174924', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'حبوب ونشويات', 2.7, '{"iron": 3.61, "zinc": 0.74, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.22, "vit_k": 0.2, "folate": 171, "vit_b6": 0.087, "calcium": 144, "vit_b12": 0, "magnesium": 23, "potassium": 126}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('9f22d8d7-e87d-4ac6-a495-67fa0a9c5f21', 'خبز بر (توست أسمر)', 'Bread, whole-wheat, commercially prepared', 'خبز', 252.0, 12.5, 42.7, 3.5, 32.0, 'شريحة', 'usda', '172688', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'حبوب ونشويات', 6.0, '{"iron": 2.47, "zinc": 1.77, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 2.66, "vit_k": 7.8, "folate": 42, "vit_b6": 0.215, "calcium": 161, "vit_b12": 0, "magnesium": 75, "potassium": 254}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f07c7ccd-9f1e-4193-afc5-3c24aa85cf47', 'خبز عربي أبيض', 'Bread, pita, white, enriched', 'خبز', 275.0, 9.1, 55.7, 1.2, 60.0, 'رغيف صغير', 'usda', '174915', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'حبوب ونشويات', 2.2, '{"iron": 2.62, "zinc": 0.84, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.3, "vit_k": 0.2, "folate": 165, "vit_b6": 0.034, "calcium": 86, "vit_b12": 0, "magnesium": 26, "potassium": 120}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('9ba9fd52-e729-4776-8902-7c97128e5a4f', 'خبز عربي بر', 'Bread, pita, whole-wheat', 'خبز', 262.0, 9.8, 55.9, 1.7, 64.0, 'رغيف صغير', 'usda', '174916', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'حبوب ونشويات', 6.1, '{"iron": 3.06, "zinc": 1.52, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.61, "vit_k": 1.4, "folate": 35, "vit_b6": 0.265, "calcium": 15, "vit_b12": 0, "magnesium": 69, "potassium": 170}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('e631574d-19e0-439e-a23c-0b0883659ada', 'تورتيلا قمح', 'Tortillas, ready-to-bake or -fry, flour, refrigerated', 'خبز', 306.0, 8.2, 49.4, 8.0, 45.0, 'حبة', 'usda', '175037', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'حبوب ونشويات', 3.5, '{"iron": 3.63, "zinc": 0.53, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0, "vit_k": 7.2, "folate": 149, "vit_b6": 0.059, "calcium": 146, "vit_b12": 0, "magnesium": 22, "potassium": 125}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('752c4f22-8efb-49ba-9b63-967ac2300587', 'بطاطس مسلوقة', 'Potatoes, boiled, cooked without skin, flesh, without salt', 'حبوب ونشويات', 86.0, 1.7, 20.0, 0.1, 150.0, 'حبة وسط', 'usda', '170440', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'خضار نشوية', 1.8, '{"iron": 0.31, "zinc": 0.27, "vit_a": 0, "vit_c": 7.4, "vit_d": 0, "vit_e": 0.01, "vit_k": 2.2, "folate": 9, "vit_b6": 0.269, "calcium": 8, "vit_b12": 0, "magnesium": 20, "potassium": 328}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d227a751-cd9e-42e8-80c0-ffaf5ca2853a', 'بطاطا حلوة مشوية', 'Sweet potato, cooked, baked in skin, flesh, without salt', 'حبوب ونشويات', 90.0, 2.0, 20.7, 0.2, 150.0, 'حبة وسط', 'usda', '168483', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'خضار نشوية', 3.3, '{"iron": 0.69, "zinc": 0.32, "vit_a": 961, "vit_c": 19.6, "vit_d": 0, "vit_e": 0.71, "vit_k": 2.3, "folate": 6, "vit_b6": 0.286, "calcium": 38, "vit_b12": 0, "magnesium": 27, "potassium": 475}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('4b5f7c52-b004-41cd-adba-9dceaef48fa5', 'برغل مطبوخ', 'Bulgur, cooked', 'حبوب ونشويات', 83.0, 3.1, 18.6, 0.2, 150.0, NULL, 'usda', '170287', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'حبوب ونشويات', 4.5, '{"iron": 0.96, "zinc": 0.57, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.01, "vit_k": 0.5, "folate": 18, "vit_b6": 0.083, "calcium": 10, "vit_b12": 0, "magnesium": 32, "potassium": 68}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('8f65ffef-e566-406d-a4f8-8090abeb9717', 'كينوا مطبوخة', 'Quinoa, cooked', 'حبوب ونشويات', 120.0, 4.4, 21.3, 1.9, 150.0, NULL, 'usda', '168917', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'حبوب ونشويات', 2.8, '{"iron": 1.49, "zinc": 1.09, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.63, "vit_k": 0, "folate": 42, "vit_b6": 0.123, "calcium": 17, "vit_b12": 0, "magnesium": 64, "potassium": 172}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('e9a44bac-9d9d-44b3-9641-af874322611a', 'كورن فليكس', 'Cereals ready-to-eat, RALSTON Corn Flakes', 'حبوب ونشويات', 384.0, 5.9, 88.0, 0.9, 30.0, NULL, 'usda', '174648', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'حبوب ونشويات', 2.7, '{"iron": 19.4, "zinc": 0.2, "vit_a": 981, "vit_c": 65, "vit_d": 7.1, "vit_e": 0.02, "vit_k": 0, "vit_b6": 1.907, "calcium": 2, "vit_b12": 5.36, "magnesium": 7, "potassium": 107}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('0cf984f0-e485-4cdc-b4d2-93c0f9085aa7', 'صدر دجاج مشوي', 'Chicken, broilers or fryers, breast, meat only, cooked, roasted', 'لحوم ودواجن', 165.0, 31.0, 0.0, 3.6, 100.0, NULL, 'usda', '171477', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'لحوم بيضاء (دواجن)', 0.0, '{"iron": 1.04, "zinc": 1, "vit_a": 6, "vit_c": 0, "vit_d": 0.1, "vit_e": 0.27, "vit_k": 0.3, "folate": 4, "vit_b6": 0.6, "calcium": 15, "vit_b12": 0.34, "magnesium": 29, "potassium": 256}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('30b07fa9-c95e-4cde-92e1-abd357f33286', 'صدر دجاج نيء', 'Chicken, broiler or fryers, breast, skinless, boneless, meat only, raw', 'لحوم ودواجن', 120.0, 22.5, 0.0, 2.6, 150.0, NULL, 'usda', '171077', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'لحوم بيضاء (دواجن)', 0.0, '{"iron": 0.37, "zinc": 0.68, "vit_a": 9, "vit_c": 0, "vit_d": 0, "vit_e": 0.56, "vit_k": 0, "folate": 9, "vit_b6": 0.811, "calcium": 5, "vit_b12": 0.21, "magnesium": 28, "potassium": 334}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3ee5aab3-40c4-4d2c-934d-95ca1636faeb', 'فخذ دجاج مشوي (بدون جلد)', 'Chicken, broilers or fryers, thigh, meat only, cooked, roasted', 'لحوم ودواجن', 179.0, 24.8, 0.0, 8.2, 100.0, NULL, 'usda', '172388', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'لحوم بيضاء (دواجن)', 0.0, '{"iron": 1.13, "zinc": 1.92, "vit_a": 8, "vit_c": 0, "vit_d": 0.2, "vit_e": 0.18, "vit_k": 3.9, "folate": 5, "vit_b6": 0.462, "calcium": 9, "vit_b12": 0.42, "magnesium": 24, "potassium": 269}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('dd61a152-6628-4013-9b6c-98b0333d10ce', 'لحم بقري مفروم 90% مطبوخ', 'Beef, ground, 90% lean meat / 10% fat, patty, cooked, broiled', 'لحوم ودواجن', 217.0, 26.1, 0.0, 11.8, 100.0, NULL, 'usda', '174031', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'لحوم حمراء', 0.0, '{"iron": 2.71, "zinc": 6.37, "vit_a": 3, "vit_c": 0, "vit_d": 0, "vit_e": 0.12, "vit_k": 1.1, "folate": 8, "vit_b6": 0.397, "calcium": 13, "vit_b12": 2.56, "magnesium": 22, "potassium": 333}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('1a3e9e56-0d27-4532-990a-3295976f4a9a', 'لحم بقري مفروم 80% مطبوخ', 'Beef, ground, 80% lean meat / 20% fat, patty, cooked, broiled', 'لحوم ودواجن', 270.0, 25.8, 0.0, 17.8, 100.0, NULL, 'usda', '171797', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'لحوم حمراء', 0.0, '{"iron": 2.48, "zinc": 6.25, "vit_a": 3, "vit_c": 0, "vit_d": 0, "vit_e": 0.12, "vit_k": 1.6, "folate": 10, "vit_b6": 0.366, "calcium": 24, "vit_b12": 2.73, "magnesium": 20, "potassium": 304}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f10af2c7-073a-4719-9242-e83250044572', 'لحم غنم مطبوخ', 'Lamb, composite of trimmed retail cuts, separable lean only, trimmed to 1/4" fat, choice, cooked', 'لحوم ودواجن', 206.0, 28.2, 0.0, 9.5, 100.0, NULL, 'usda', '174308', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'لحوم حمراء', 0.0, '{"iron": 2.05, "zinc": 5.27, "vit_a": 0, "vit_c": 0, "vit_e": 0.19, "folate": 23, "vit_b6": 0.16, "calcium": 15, "vit_b12": 2.61, "magnesium": 26, "potassium": 344}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('6e75de6c-ef20-4103-8c02-d9e1fab86a5f', 'ديك رومي (شرائح)', 'Turkey, whole, breast, meat only, cooked, roasted', 'لحوم ودواجن', 147.0, 30.1, 0.0, 2.1, 50.0, NULL, 'usda', '171496', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'لحوم بيضاء (دواجن)', 0.0, '{"iron": 0.71, "zinc": 1.72, "vit_a": 3, "vit_c": 0, "vit_d": 0.3, "vit_e": 0.06, "vit_k": 0, "folate": 9, "vit_b6": 0.807, "calcium": 9, "vit_b12": 0.39, "magnesium": 32, "potassium": 249}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3f26d13a-bfb6-44e6-bdb0-66a7058ff16a', 'تونة معلبة بالماء', 'Fish, tuna, light, canned in water, drained solids (Includes foods for USDA''s Food Distribution Program)', 'أسماك', 86.0, 19.4, 0.0, 1.0, 100.0, 'علبة صغيرة مصفاة', 'usda', '173709', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'أسماك ومأكولات بحرية', 0.0, '{"iron": 1.63, "zinc": 0.69, "vit_a": 17, "vit_c": 0, "vit_d": 1.2, "vit_e": 0.33, "vit_k": 0.2, "folate": 4, "vit_b6": 0.319, "calcium": 17, "vit_b12": 2.55, "magnesium": 23, "potassium": 179}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3aeaeeb2-e6ef-4a1b-bc00-daa3b00c1e7b', 'تونة معلبة بالزيت', 'Fish, tuna, light, canned in oil, drained solids', 'أسماك', 198.0, 29.1, 0.0, 8.2, 100.0, NULL, 'usda', '173708', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'أسماك ومأكولات بحرية', 0.0, '{"iron": 1.39, "zinc": 0.9, "vit_a": 23, "vit_c": 0, "vit_d": 6.7, "vit_e": 0.87, "vit_k": 44, "folate": 5, "vit_b6": 0.11, "calcium": 13, "vit_b12": 2.2, "magnesium": 31, "potassium": 207}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('8288a14b-54cc-44d6-9ad2-fcf91a245680', 'سلمون مطبوخ', 'Fish, salmon, Atlantic, farmed, cooked, dry heat', 'أسماك', 206.0, 22.1, 0.0, 12.4, 120.0, NULL, 'usda', '175168', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'أسماك ومأكولات بحرية', 0.0, '{"iron": 0.34, "zinc": 0.43, "vit_a": 69, "vit_c": 3.7, "vit_d": 13.1, "vit_e": 1.14, "vit_k": 0.1, "folate": 34, "vit_b6": 0.647, "calcium": 15, "vit_b12": 2.8, "magnesium": 30, "potassium": 384}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('37035a35-e757-427d-98ce-b5f5f528beb9', 'سلمون مدخن', 'Fish, salmon, chinook, smoked', 'أسماك', 117.0, 18.3, 0.0, 4.3, 60.0, NULL, 'usda', '173687', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'أسماك ومأكولات بحرية', 0.0, '{"iron": 0.85, "zinc": 0.31, "vit_a": 26, "vit_c": 0, "vit_d": 17.1, "vit_e": 1.35, "vit_k": 0.1, "folate": 2, "vit_b6": 0.278, "calcium": 11, "vit_b12": 3.26, "magnesium": 18, "potassium": 175}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('9a1fadc6-1ad6-418f-9f66-0caf5fbcc051', 'روبيان مطبوخ', 'Crustaceans, shrimp, cooked', 'أسماك', 99.0, 24.0, 0.2, 0.3, 100.0, NULL, 'usda', '175180', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'أسماك ومأكولات بحرية', 0.0, '{"iron": 0.51, "zinc": 1.64, "calcium": 70, "magnesium": 39, "potassium": 259}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ab4a31ae-c048-4cfb-8e9f-a9bdc9165037', 'هامور/سمك أبيض مطبوخ', 'Fish, grouper, mixed species, cooked, dry heat', 'أسماك', 118.0, 24.8, 0.0, 1.3, 150.0, NULL, 'usda', '171963', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'أسماك ومأكولات بحرية', 0.0, '{"iron": 1.14, "zinc": 0.51, "vit_a": 50, "vit_c": 0, "folate": 10, "vit_b6": 0.35, "calcium": 21, "vit_b12": 0.69, "magnesium": 37, "potassium": 475}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('17ddac91-54aa-43e4-ab80-44ba0f3a2042', 'بيض كامل', 'Egg, whole, raw, fresh', 'بيض وألبان', 143.0, 12.6, 0.7, 9.5, 50.0, 'بيضة', 'usda', '171287', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'بيض', 0.0, '{"iron": 1.75, "zinc": 1.29, "vit_a": 160, "vit_c": 0, "vit_d": 2, "vit_e": 1.05, "vit_k": 0.3, "folate": 47, "vit_b6": 0.17, "calcium": 56, "vit_b12": 0.89, "magnesium": 12, "potassium": 138}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ccde9b35-b7d6-4588-9ffe-8f59234b9290', 'بياض بيض', 'Egg, white, raw, fresh', 'بيض وألبان', 52.0, 10.9, 0.7, 0.2, 33.0, 'بياض بيضة', 'usda', '172183', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'بيض', 0.0, '{"iron": 0.08, "zinc": 0.03, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0, "vit_k": 0, "folate": 4, "vit_b6": 0.005, "calcium": 7, "vit_b12": 0.09, "magnesium": 11, "potassium": 163}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('4c0af337-182f-46de-9b3c-28b7e2e847e1', 'بيض مسلوق', 'Egg, whole, cooked, hard-boiled', 'بيض وألبان', 155.0, 12.6, 1.1, 10.6, 50.0, 'بيضة', 'usda', '173424', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'بيض', 0.0, '{"iron": 1.19, "zinc": 1.05, "vit_a": 149, "vit_c": 0, "vit_d": 2.2, "vit_e": 1.03, "vit_k": 0.3, "folate": 44, "vit_b6": 0.121, "calcium": 50, "vit_b12": 1.11, "magnesium": 10, "potassium": 126}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('5e9b3ba5-b747-4f55-99e4-e51d94ae4ebf', 'حليب كامل الدسم', 'Milk, whole, 3.25% milkfat, with added vitamin D', 'بيض وألبان', 61.0, 3.2, 4.8, 3.3, 244.0, 'كوب', 'usda', '171265', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', 0.0, '{"iron": 0.03, "zinc": 0.37, "vit_a": 46, "vit_c": 0, "vit_d": 1.3, "vit_e": 0.07, "vit_k": 0.3, "folate": 5, "vit_b6": 0.036, "calcium": 113, "vit_b12": 0.45, "magnesium": 10, "potassium": 132}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('7dc3bd6d-3e5a-46c7-be90-8a88e1db9d3e', 'حليب قليل الدسم 1%', 'Milk, lowfat, fluid, 1% milkfat, with added vitamin A and vitamin D', 'بيض وألبان', 42.0, 3.4, 5.0, 1.0, 244.0, 'كوب', 'usda', '170872', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', 0.0, '{"iron": 0.03, "zinc": 0.42, "vit_a": 58, "vit_c": 0, "vit_d": 1.2, "vit_e": 0.01, "vit_k": 0.1, "folate": 5, "vit_b6": 0.037, "calcium": 125, "vit_b12": 0.47, "magnesium": 11, "potassium": 150}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a2e6579c-ee1a-4d13-84fd-8394c2b394e3', 'حليب خالي الدسم', 'Milk, nonfat, fluid, with added vitamin A and vitamin D (fat free or skim)', 'بيض وألبان', 34.0, 3.4, 5.0, 0.1, 245.0, 'كوب', 'usda', '171269', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', 0.0, '{"iron": 0.03, "zinc": 0.42, "vit_a": 61, "vit_c": 0, "vit_d": 1.2, "vit_e": 0.01, "vit_k": 0, "folate": 5, "vit_b6": 0.037, "calcium": 122, "vit_b12": 0.5, "magnesium": 11, "potassium": 156}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('9d5e3dd7-ba0a-4e5a-b987-a5c34d6d4f5c', 'زبادي كامل الدسم', 'Yogurt, plain, whole milk', 'بيض وألبان', 61.0, 3.5, 4.7, 3.3, 170.0, NULL, 'usda', '171284', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', 0.0, '{"iron": 0.05, "zinc": 0.59, "vit_a": 27, "vit_c": 0.5, "vit_d": 0.1, "vit_e": 0.06, "vit_k": 0.2, "folate": 7, "vit_b6": 0.032, "calcium": 121, "vit_b12": 0.37, "magnesium": 12, "potassium": 155}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('6cab1ec6-bdd9-4c62-bf5e-25f032296888', 'زبادي قليل الدسم', 'Yogurt, plain, low fat', 'بيض وألبان', 63.0, 5.3, 7.0, 1.6, 170.0, NULL, 'usda', '170886', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', 0.0, '{"iron": 0.08, "zinc": 0.89, "vit_a": 14, "vit_c": 0.8, "vit_d": 0, "vit_e": 0.03, "vit_k": 0.2, "folate": 11, "vit_b6": 0.049, "calcium": 183, "vit_b12": 0.56, "magnesium": 17, "potassium": 234}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('8edce6b2-373e-4c9f-8385-c6c698f6cd49', 'زبادي يوناني قليل الدسم', 'Yogurt, Greek, plain, lowfat', 'بيض وألبان', 73.0, 10.0, 3.9, 1.9, 170.0, NULL, 'usda', '170903', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', 0.0, '{"iron": 0.04, "zinc": 0.6, "vit_a": 90, "vit_c": 0.8, "vit_d": 0, "vit_e": 0.04, "vit_k": 0.2, "folate": 12, "vit_b6": 0.055, "calcium": 115, "vit_b12": 0.52, "magnesium": 11, "potassium": 141}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ec1bf791-01fa-41d6-886b-1daa1326e8ce', 'زبادي يوناني خالي الدسم', 'Yogurt, Greek, plain, nonfat (Includes foods for USDA''s Food Distribution Program)', 'بيض وألبان', 59.0, 10.2, 3.6, 0.4, 170.0, NULL, 'usda', '170894', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', 0.0, '{"iron": 0.07, "zinc": 0.52, "vit_a": 1, "vit_c": 0, "vit_d": 0, "vit_e": 0.01, "vit_k": 0, "folate": 7, "vit_b6": 0.063, "calcium": 110, "vit_b12": 0.75, "magnesium": 11, "potassium": 141}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('86309eec-b9e1-4234-8565-414aa43e6663', 'جبنة قريش (كوتج)', 'Cheese, cottage, lowfat, 2% milkfat', 'بيض وألبان', 81.0, 10.5, 4.8, 2.3, 113.0, 'نص كوب', 'usda', '172182', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', 0.0, '{"iron": 0.13, "zinc": 0.51, "vit_a": 68, "vit_c": 0, "vit_d": 0, "vit_e": 0.08, "vit_k": 0, "folate": 8, "vit_b6": 0.057, "calcium": 111, "vit_b12": 0.47, "magnesium": 9, "potassium": 125}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f87a1d38-5370-43c0-b279-71525eee9b77', 'جبنة موزاريلا قليلة الدسم', 'Cheese, mozzarella, part skim milk', 'بيض وألبان', 254.0, 24.3, 2.8, 15.9, 28.0, NULL, 'usda', '170847', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', 0.0, '{"iron": 0.22, "zinc": 2.76, "vit_a": 127, "vit_c": 0, "vit_d": 0.3, "vit_e": 0.14, "vit_k": 1.6, "folate": 9, "vit_b6": 0.07, "calcium": 782, "vit_b12": 0.82, "magnesium": 23, "potassium": 84}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('4bb8d686-87b9-46c0-9a1e-d153f2faaf28', 'جبنة شيدر', 'Cheese, cheddar (Includes foods for USDA''s Food Distribution Program)', 'بيض وألبان', 403.0, 22.9, 3.4, 33.3, 28.0, 'شريحة', 'usda', '173414', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', 0.0, '{"iron": 0.14, "zinc": 3.64, "vit_a": 337, "vit_c": 0, "vit_d": 0.6, "vit_e": 0.71, "vit_k": 2.4, "folate": 27, "vit_b6": 0.066, "calcium": 710, "vit_b12": 1.1, "magnesium": 27, "potassium": 76}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b40c713d-faf1-4dba-aada-4f0135ff0b1a', 'جبنة فيتا', 'Cheese, feta', 'بيض وألبان', 265.0, 14.2, 3.9, 21.5, 28.0, NULL, 'usda', '173420', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', 0.0, '{"iron": 0.65, "zinc": 2.88, "vit_a": 125, "vit_c": 0, "vit_d": 0.4, "vit_e": 0.18, "vit_k": 1.8, "folate": 32, "vit_b6": 0.424, "calcium": 493, "vit_b12": 1.69, "magnesium": 19, "potassium": 62}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('1d0ef553-f97e-41be-91d3-6dba57762256', 'جبنة كريمية', 'Cheese, cream', 'بيض وألبان', 350.0, 6.2, 5.5, 34.4, 30.0, NULL, 'usda', '173418', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', 0.0, '{"iron": 0.11, "zinc": 0.5, "vit_a": 308, "vit_c": 0, "vit_d": 0, "vit_e": 0.86, "vit_k": 2.1, "folate": 9, "vit_b6": 0.056, "calcium": 97, "vit_b12": 0.22, "magnesium": 9, "potassium": 132}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('1aca4f33-69ec-49f0-9a65-6418cfb89d65', 'واي بروتين', 'Beverages, Whey protein powder isolate', 'مكملات', 359.0, 58.1, 29.1, 1.2, 30.0, 'سكوب', 'usda', '173177', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'مكملات', 0.0, '{"iron": 1.26, "zinc": 8.72, "vit_a": 872, "vit_c": 34.9, "vit_d": 0, "vit_e": 7.85, "vit_k": 46.5, "folate": 395, "vit_b6": 1.163, "calcium": 698, "vit_b12": 3.49, "magnesium": 233, "potassium": 872}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('13f08666-df6b-48ab-a126-6bcb3b896f8f', 'عدس مطبوخ', 'Lentils, mature seeds, cooked, boiled, without salt', 'بقوليات', 116.0, 9.0, 20.1, 0.4, 150.0, NULL, 'usda', '172421', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'بقوليات', 7.9, '{"iron": 3.33, "zinc": 1.27, "vit_a": 0, "vit_c": 1.5, "vit_d": 0, "vit_e": 0.11, "vit_k": 1.7, "folate": 181, "vit_b6": 0.178, "calcium": 19, "vit_b12": 0, "magnesium": 36, "potassium": 369}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('da5d7b38-5c27-4d50-9976-60125c65df05', 'حمص مطبوخ', 'Chickpeas (garbanzo beans, bengal gram), mature seeds, cooked, boiled, without salt', 'بقوليات', 164.0, 8.9, 27.4, 2.6, 150.0, NULL, 'usda', '173757', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'بقوليات', 7.6, '{"iron": 2.89, "zinc": 1.53, "vit_a": 1, "vit_c": 1.3, "vit_d": 0, "vit_e": 0.35, "vit_k": 4, "folate": 172, "vit_b6": 0.139, "calcium": 49, "vit_b12": 0, "magnesium": 48, "potassium": 291}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('35496ab1-bac2-4d61-9612-d899991430bd', 'فول مدمس (مطبوخ)', 'Broadbeans (fava beans), mature seeds, cooked, boiled, without salt', 'بقوليات', 110.0, 7.6, 19.7, 0.4, 150.0, NULL, 'usda', '173753', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'بقوليات', 5.4, '{"iron": 1.5, "zinc": 1.01, "vit_a": 1, "vit_c": 0.3, "vit_d": 0, "vit_e": 0.02, "vit_k": 2.9, "folate": 104, "vit_b6": 0.072, "calcium": 36, "vit_b12": 0, "magnesium": 43, "potassium": 268}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b2c34604-cbdd-43ab-b05d-7d437b6e5418', 'فاصوليا حمراء مطبوخة', 'Beans, kidney, all types, mature seeds, cooked, boiled, without salt', 'بقوليات', 127.0, 8.7, 22.8, 0.5, 150.0, NULL, 'usda', '173740', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'بقوليات', 6.4, '{"iron": 2.22, "zinc": 1, "vit_a": 0, "vit_c": 1.2, "vit_d": 0, "vit_e": 0.03, "vit_k": 8.4, "folate": 130, "vit_b6": 0.12, "calcium": 35, "vit_b12": 0, "magnesium": 42, "potassium": 405}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('45aac08d-bea4-44ae-be17-53edd63a217f', 'حمص بطحينة (حمص جاهز)', 'Hummus, commercial', 'بقوليات', 237.0, 7.8, 15.0, 17.8, 60.0, NULL, 'usda', '174289', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'بقوليات', 5.5, '{"iron": 2.54, "zinc": 1.44, "vit_a": 1, "vit_c": 0, "vit_d": 0, "vit_e": 1.54, "vit_k": 22.8, "folate": 48, "vit_b6": 0.146, "calcium": 47, "vit_b12": 0, "magnesium": 75, "potassium": 312}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ac3fe409-5fd4-4166-af64-002e4eb9ff76', 'تمر مجدول', 'Dates, medjool', 'فواكه', 277.0, 1.8, 75.0, 0.2, 24.0, 'حبة', 'usda', '168191', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'فواكه', 6.7, '{"iron": 0.9, "zinc": 0.44, "vit_a": 7, "vit_c": 0, "vit_d": 0, "vit_k": 2.7, "folate": 15, "vit_b6": 0.249, "calcium": 64, "magnesium": 54, "potassium": 696}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('6b77c9dd-4374-465c-9916-1563d2048560', 'تمر (دقلة نور)', 'Dates, deglet noor', 'فواكه', 282.0, 2.5, 75.0, 0.4, 7.0, 'حبة', 'usda', '171726', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'فواكه', 8.0, '{"iron": 1.02, "zinc": 0.29, "vit_a": 0, "vit_c": 0.4, "vit_d": 0, "vit_e": 0.05, "vit_k": 2.7, "folate": 19, "vit_b6": 0.165, "calcium": 39, "vit_b12": 0, "magnesium": 43, "potassium": 656}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('961728ac-ea64-4f2c-b0fd-f1487c9da8e6', 'موز', 'Bananas, raw', 'فواكه', 89.0, 1.1, 22.8, 0.3, 118.0, 'حبة وسط', 'usda', '173944', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'فواكه', 2.6, '{"iron": 0.26, "zinc": 0.15, "vit_a": 3, "vit_c": 8.7, "vit_d": 0, "vit_e": 0.1, "vit_k": 0.5, "folate": 20, "vit_b6": 0.367, "calcium": 5, "vit_b12": 0, "magnesium": 27, "potassium": 358}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('90f40602-c7fb-4214-a0bc-8c3fd9057d65', 'تفاح', 'Apples, raw, with skin (Includes foods for USDA''s Food Distribution Program)', 'فواكه', 52.0, 0.3, 13.8, 0.2, 182.0, 'حبة وسط', 'usda', '171688', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'فواكه', 2.4, '{"iron": 0.12, "zinc": 0.04, "vit_a": 3, "vit_c": 4.6, "vit_d": 0, "vit_e": 0.18, "vit_k": 2.2, "folate": 3, "vit_b6": 0.041, "calcium": 6, "vit_b12": 0, "magnesium": 5, "potassium": 107}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('0aae7593-ffeb-4735-942b-fe91cd5f9ddb', 'برتقال', 'Oranges, raw, all commercial varieties', 'فواكه', 47.0, 0.9, 11.8, 0.1, 131.0, 'حبة', 'usda', '169097', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'فواكه', 2.4, '{"iron": 0.1, "zinc": 0.07, "vit_a": 11, "vit_c": 53.2, "vit_d": 0, "vit_e": 0.18, "vit_k": 0, "folate": 30, "vit_b6": 0.06, "calcium": 40, "vit_b12": 0, "magnesium": 10, "potassium": 181}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f094a807-678b-4a2d-8f7d-d39ae2755c9f', 'فراولة', 'Strawberries, raw', 'فواكه', 32.0, 0.7, 7.7, 0.3, 150.0, 'كوب', 'usda', '167762', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'فواكه', 2.0, '{"iron": 0.41, "zinc": 0.14, "vit_a": 1, "vit_c": 58.8, "vit_d": 0, "vit_e": 0.29, "vit_k": 2.2, "folate": 24, "vit_b6": 0.047, "calcium": 16, "vit_b12": 0, "magnesium": 13, "potassium": 153}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('80dbfb5f-0583-48da-b37a-548acb3b70b7', 'عنب', 'Grapes, red or green (European type, such as Thompson seedless), raw', 'فواكه', 69.0, 0.7, 18.1, 0.2, 150.0, 'كوب', 'usda', '174683', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'فواكه', 0.9, '{"iron": 0.36, "zinc": 0.07, "vit_a": 3, "vit_c": 3.2, "vit_d": 0, "vit_e": 0.19, "vit_k": 14.6, "folate": 2, "vit_b6": 0.086, "calcium": 10, "vit_b12": 0, "magnesium": 7, "potassium": 191}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('8ff1fd21-d43b-43de-a6cf-4d4e0f6ea7bd', 'بطيخ', 'Watermelon, raw', 'فواكه', 30.0, 0.6, 7.6, 0.2, 280.0, 'كوب ونص', 'usda', '167765', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'فواكه', 0.4, '{"iron": 0.24, "zinc": 0.1, "vit_a": 28, "vit_c": 8.1, "vit_d": 0, "vit_e": 0.05, "vit_k": 0.1, "folate": 3, "vit_b6": 0.045, "calcium": 7, "vit_b12": 0, "magnesium": 10, "potassium": 112}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('9734354c-181e-46e2-8cff-207c4c281457', 'مانجو', 'Mangos, raw', 'فواكه', 60.0, 0.8, 15.0, 0.4, 165.0, 'كوب', 'usda', '169910', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'فواكه', 1.6, '{"iron": 0.16, "zinc": 0.09, "vit_a": 54, "vit_c": 36.4, "vit_d": 0, "vit_e": 0.9, "vit_k": 4.2, "folate": 43, "vit_b6": 0.119, "calcium": 11, "vit_b12": 0, "magnesium": 10, "potassium": 168}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b326837a-220e-446d-830a-77388bd9a33d', 'أناناس', 'Pineapple, raw, all varieties', 'فواكه', 50.0, 0.5, 13.1, 0.1, 165.0, 'كوب', 'usda', '169124', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'فواكه', 1.4, '{"iron": 0.29, "zinc": 0.12, "vit_a": 3, "vit_c": 47.8, "vit_d": 0, "vit_e": 0.02, "vit_k": 0.7, "folate": 18, "vit_b6": 0.112, "calcium": 13, "vit_b12": 0, "magnesium": 12, "potassium": 109}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a3c1d8c1-fe2e-4224-9963-63340d3a1d12', 'توت أزرق', 'Blueberries, raw', 'فواكه', 57.0, 0.7, 14.5, 0.3, 148.0, 'كوب', 'usda', '171711', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'فواكه', 2.4, '{"iron": 0.28, "zinc": 0.16, "vit_a": 3, "vit_c": 9.7, "vit_d": 0, "vit_e": 0.57, "vit_k": 19.3, "folate": 6, "vit_b6": 0.052, "calcium": 6, "vit_b12": 0, "magnesium": 6, "potassium": 77}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('e27933b1-0718-4450-a739-7333ccd0e2b5', 'كيوي', 'Kiwifruit, green, raw', 'فواكه', 61.0, 1.1, 14.7, 0.5, 75.0, 'حبة', 'usda', '168153', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'فواكه', 3.0, '{"iron": 0.31, "zinc": 0.14, "vit_a": 4, "vit_c": 92.7, "vit_d": 0, "vit_e": 1.46, "vit_k": 40.3, "folate": 25, "vit_b6": 0.063, "calcium": 34, "vit_b12": 0, "magnesium": 17, "potassium": 312}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f32f11a8-ca07-4242-b25c-645667bf796e', 'رمان', 'Pomegranates, raw', 'فواكه', 83.0, 1.7, 18.7, 1.2, 87.0, 'نص كوب حبوب', 'usda', '169134', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'فواكه', 4.0, '{"iron": 0.3, "zinc": 0.35, "vit_a": 0, "vit_c": 10.2, "vit_d": 0, "vit_e": 0.6, "vit_k": 16.4, "folate": 38, "vit_b6": 0.075, "calcium": 10, "vit_b12": 0, "magnesium": 12, "potassium": 236}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('07e8330f-39e9-4c03-aa01-c8b63e21f927', 'طماطم', 'Tomatoes, red, ripe, raw, year round average', 'خضار', 18.0, 0.9, 3.9, 0.2, 120.0, 'حبة وسط', 'usda', '170457', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'خضار', 1.2, '{"iron": 0.27, "zinc": 0.17, "vit_a": 42, "vit_c": 13.7, "vit_d": 0, "vit_e": 0.54, "vit_k": 7.9, "folate": 15, "vit_b6": 0.08, "calcium": 10, "vit_b12": 0, "magnesium": 11, "potassium": 237}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a0c15132-6593-4eb5-843c-6aa38b123afc', 'خس', 'Lettuce, cos or romaine, raw', 'خضار', 17.0, 1.2, 3.3, 0.3, 50.0, NULL, 'usda', '169247', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'خضار', 2.1, '{"iron": 0.97, "zinc": 0.23, "vit_a": 436, "vit_c": 4, "vit_d": 0, "vit_e": 0.13, "vit_k": 102.5, "folate": 136, "vit_b6": 0.074, "calcium": 33, "vit_b12": 0, "magnesium": 14, "potassium": 247}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('7cfcfa4e-aa69-4e5f-a5e3-89e3c5d51e3a', 'جزر', 'Carrots, raw', 'خضار', 41.0, 0.9, 9.6, 0.2, 60.0, 'حبة', 'usda', '170393', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'خضار', 2.8, '{"iron": 0.3, "zinc": 0.24, "vit_a": 835, "vit_c": 5.9, "vit_d": 0, "vit_e": 0.66, "vit_k": 13.2, "folate": 19, "vit_b6": 0.138, "calcium": 33, "vit_b12": 0, "magnesium": 12, "potassium": 320}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('090c2b2b-42d3-416a-892c-ec1e9de8d4ed', 'بروكلي مطبوخ', 'Broccoli, cooked, boiled, drained, without salt', 'خضار', 35.0, 2.4, 7.2, 0.4, 90.0, NULL, 'usda', '169967', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'خضار', 3.3, '{"iron": 0.67, "zinc": 0.45, "vit_a": 77, "vit_c": 64.9, "vit_d": 0, "vit_e": 1.45, "vit_k": 141.1, "folate": 108, "vit_b6": 0.2, "calcium": 40, "vit_b12": 0, "magnesium": 21, "potassium": 293}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('e3fef320-288c-4777-8c41-f4e8553edfe7', 'سبانخ', 'Spinach, raw', 'خضار', 23.0, 2.9, 3.6, 0.4, 30.0, 'كوب', 'usda', '168462', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'خضار', 2.2, '{"iron": 2.71, "zinc": 0.53, "vit_a": 469, "vit_c": 28.1, "vit_d": 0, "vit_e": 2.03, "vit_k": 482.9, "folate": 194, "vit_b6": 0.195, "calcium": 99, "vit_b12": 0, "magnesium": 79, "potassium": 558}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3649584a-1a09-40f7-b335-be62a66aa166', 'فلفل رومي أحمر', 'Peppers, sweet, red, raw', 'خضار', 26.0, 1.0, 6.0, 0.3, 120.0, 'حبة', 'usda', '170108', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'خضار', 2.1, '{"iron": 0.43, "zinc": 0.25, "vit_a": 157, "vit_c": 127.7, "vit_d": 0, "vit_e": 1.58, "vit_k": 4.9, "folate": 46, "vit_b6": 0.291, "calcium": 7, "vit_b12": 0, "magnesium": 12, "potassium": 211}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('c4986d5e-9db8-4da7-86c7-424b219aa2d8', 'بصل', 'Onions, raw', 'خضار', 40.0, 1.1, 9.3, 0.1, 110.0, 'حبة وسط', 'usda', '170000', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'خضار', 1.7, '{"iron": 0.21, "zinc": 0.17, "vit_a": 0, "vit_c": 7.4, "vit_d": 0, "vit_e": 0.02, "vit_k": 0.4, "folate": 19, "vit_b6": 0.12, "calcium": 23, "vit_b12": 0, "magnesium": 10, "potassium": 146}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('8c3fb4db-4692-4b97-a4e7-75527fe924bd', 'فطر (مشروم)', 'Mushrooms, white, raw', 'خضار', 22.0, 3.1, 3.3, 0.3, 70.0, 'كوب', 'usda', '169251', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'خضار', 1.0, '{"iron": 0.5, "zinc": 0.52, "vit_a": 0, "vit_c": 2.1, "vit_d": 0.2, "vit_e": 0.01, "vit_k": 0, "folate": 17, "vit_b6": 0.104, "calcium": 3, "vit_b12": 0.04, "magnesium": 9, "potassium": 318}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('571f4f94-dbe1-4131-ab18-63dc1714e62b', 'كوسا مطبوخة', 'Squash, summer, zucchini, includes skin, cooked, boiled, drained, without salt', 'خضار', 15.0, 1.1, 2.7, 0.4, 180.0, NULL, 'usda', '169292', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'خضار', 1.0, '{"iron": 0.37, "zinc": 0.33, "vit_a": 56, "vit_c": 12.9, "vit_d": 0, "vit_e": 0.12, "vit_k": 4.2, "folate": 28, "vit_b6": 0.08, "calcium": 18, "vit_b12": 0, "magnesium": 19, "potassium": 264}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f4bad026-a29a-462e-8838-6758001891fe', 'باذنجان مطبوخ', 'Eggplant, cooked, boiled, drained, without salt', 'خضار', 35.0, 0.8, 8.7, 0.2, 100.0, NULL, 'usda', '169229', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'خضار', 2.5, '{"iron": 0.25, "zinc": 0.12, "vit_a": 2, "vit_c": 1.3, "vit_d": 0, "vit_e": 0.41, "vit_k": 2.9, "folate": 14, "vit_b6": 0.086, "calcium": 6, "vit_b12": 0, "magnesium": 11, "potassium": 123}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3df5dae3-8db1-4bcb-b113-3b0d67396dea', 'ذرة حلوة مطبوخة', 'Corn, sweet, yellow, cooked, boiled, drained, without salt', 'خضار', 96.0, 3.4, 21.0, 1.5, 150.0, NULL, 'usda', '169999', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'خضار نشوية', 2.4, '{"iron": 0.45, "zinc": 0.62, "vit_a": 13, "vit_c": 5.5, "vit_d": 0, "vit_e": 0.09, "vit_k": 0.4, "folate": 23, "vit_b6": 0.139, "calcium": 3, "vit_b12": 0, "magnesium": 26, "potassium": 218}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('335d78d5-d4ac-41b7-810a-55332a86634f', 'أفوكادو', 'Avocados, raw, all commercial varieties', 'دهون ومكسرات', 160.0, 2.0, 8.5, 14.7, 50.0, 'ثلث حبة', 'usda', '171705', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'فواكه', 6.7, '{"iron": 0.55, "zinc": 0.64, "vit_a": 7, "vit_c": 10, "vit_d": 0, "vit_e": 2.07, "vit_k": 21, "folate": 81, "vit_b6": 0.257, "calcium": 12, "vit_b12": 0, "magnesium": 29, "potassium": 485}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('8da76f3e-7c02-40cb-a78b-ea69ea49f71a', 'زيت زيتون', 'Oil, olive, salad or cooking', 'دهون ومكسرات', 884.0, 0.0, 0.0, 100.0, 5.0, 'ملعقة صغيرة', 'usda', '171413', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'دهون وزيوت', 0.0, '{"iron": 0.56, "zinc": 0, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 14.35, "vit_k": 60.2, "folate": 0, "vit_b6": 0, "calcium": 1, "vit_b12": 0, "magnesium": 0, "potassium": 1}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('01568e2f-c16c-4780-bbe5-2f36c44b48b9', 'زبدة', 'Butter, salted', 'دهون ومكسرات', 717.0, 0.9, 0.1, 81.1, 5.0, 'ملعقة صغيرة', 'usda', '173410', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'دهون وزيوت', 0.0, '{"iron": 0.02, "zinc": 0.09, "vit_a": 684, "vit_c": 0, "vit_d": 0, "vit_e": 2.32, "vit_k": 7, "folate": 3, "vit_b6": 0.003, "calcium": 24, "vit_b12": 0.17, "magnesium": 2, "potassium": 24}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('bf5e0dda-8cba-47ff-ac65-99f1a2432974', 'لوز', 'Nuts, almonds', 'دهون ومكسرات', 579.0, 21.2, 21.6, 49.9, 28.0, 'حفنة', 'usda', '170567', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'مكسرات وبذور', 12.5, '{"iron": 3.71, "zinc": 3.12, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 25.63, "vit_k": 0, "folate": 44, "vit_b6": 0.137, "calcium": 269, "vit_b12": 0, "magnesium": 270, "potassium": 733}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('c7edff3c-ac88-4911-8ad7-d22aed2d59c7', 'كاجو', 'Nuts, cashew nuts, raw', 'دهون ومكسرات', 553.0, 18.2, 30.2, 43.9, 28.0, 'حفنة', 'usda', '170162', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'مكسرات وبذور', 3.3, '{"iron": 6.68, "zinc": 5.78, "vit_a": 0, "vit_c": 0.5, "vit_d": 0, "vit_e": 0.9, "vit_k": 34.1, "folate": 25, "vit_b6": 0.417, "calcium": 37, "vit_b12": 0, "magnesium": 292, "potassium": 660}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f48e519d-5e76-435b-826d-71ad623fa33c', 'فستق حلبي', 'Nuts, pistachio nuts, raw', 'دهون ومكسرات', 560.0, 20.2, 27.2, 45.3, 28.0, 'حفنة', 'usda', '170184', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'مكسرات وبذور', 10.6, '{"iron": 3.92, "zinc": 2.2, "vit_a": 26, "vit_c": 5.6, "vit_d": 0, "vit_e": 2.86, "folate": 51, "vit_b6": 1.7, "calcium": 105, "vit_b12": 0, "magnesium": 121, "potassium": 1025}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('00c28f93-16eb-434f-b42a-23fa433a2645', 'جوز (عين الجمل)', 'Nuts, walnuts, english', 'دهون ومكسرات', 654.0, 15.2, 13.7, 65.2, 28.0, 'حفنة', 'usda', '170187', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'مكسرات وبذور', 6.7, '{"iron": 2.91, "zinc": 3.09, "vit_a": 1, "vit_c": 1.3, "vit_d": 0, "vit_e": 0.7, "vit_k": 2.7, "folate": 98, "vit_b6": 0.537, "calcium": 98, "vit_b12": 0, "magnesium": 158, "potassium": 441}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('1019bb5f-26ac-435a-87c8-e697831f5fbb', 'زبدة فول سوداني', 'Peanut butter, smooth style, without salt', 'دهون ومكسرات', 598.0, 22.2, 22.3, 51.4, 16.0, 'ملعقة كبيرة', 'usda', '172470', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'مكسرات وبذور', 5.0, '{"iron": 1.74, "zinc": 2.51, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 9.1, "vit_k": 0.3, "folate": 87, "vit_b6": 0.441, "calcium": 49, "vit_b12": 0, "magnesium": 168, "potassium": 558}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('650cc458-83f1-4e82-b885-5a897c4aa11a', 'فول سوداني', 'Peanuts, all types, raw', 'دهون ومكسرات', 567.0, 25.8, 16.1, 49.2, 28.0, 'حفنة', 'usda', '172430', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'مكسرات وبذور', 8.5, '{"iron": 4.58, "zinc": 3.27, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 8.33, "vit_k": 0, "folate": 240, "vit_b6": 0.348, "calcium": 92, "vit_b12": 0, "magnesium": 168, "potassium": 705}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('89dde26d-f39b-4187-b151-3dc37d23717f', 'طحينة', 'Seeds, sesame butter, tahini, from roasted and toasted kernels (most common type)', 'دهون ومكسرات', 595.0, 17.0, 21.2, 53.8, 15.0, 'ملعقة كبيرة', 'usda', '170189', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'مكسرات وبذور', 9.3, '{"iron": 8.95, "zinc": 4.62, "vit_a": 3, "vit_c": 0, "vit_d": 0, "vit_e": 0.25, "vit_k": 0, "folate": 98, "vit_b6": 0.149, "calcium": 426, "vit_b12": 0, "magnesium": 95, "potassium": 414}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a84e49fa-fed9-462b-a712-3641c8f85049', 'بذور الشيا', 'Seeds, chia seeds, dried', 'دهون ومكسرات', 486.0, 16.5, 42.1, 30.7, 12.0, 'ملعقة كبيرة', 'usda', '170554', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'مكسرات وبذور', 34.4, '{"iron": 7.72, "zinc": 4.58, "vit_c": 1.6, "vit_e": 0.5, "calcium": 631, "vit_b12": 0, "magnesium": 335, "potassium": 407}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ca57a5a3-1d95-4399-9b12-0c0407bbf4c8', 'عسل', 'Honey', 'حلويات ومشروبات', 304.0, 0.3, 82.4, 0.0, 21.0, 'ملعقة كبيرة', 'usda', '169640', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'حلويات ومحليات', 0.2, '{"iron": 0.42, "zinc": 0.22, "vit_a": 0, "vit_c": 0.5, "vit_d": 0, "vit_e": 0, "vit_k": 0, "folate": 2, "vit_b6": 0.024, "calcium": 6, "vit_b12": 0, "magnesium": 2, "potassium": 52}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a7ee35c3-e351-4d63-ba61-53423f8d9a37', 'سكر أبيض', 'Sugars, granulated', 'حلويات ومشروبات', 387.0, 0.0, 100.0, 0.0, 4.0, 'ملعقة صغيرة', 'usda', '169655', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'حلويات ومحليات', 0.0, '{"iron": 0.05, "zinc": 0.01, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0, "vit_k": 0, "folate": 0, "vit_b6": 0, "calcium": 1, "vit_b12": 0, "magnesium": 0, "potassium": 2}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('eebbc266-8f83-4991-93e0-fb73c93b3949', 'شوكولاتة داكنة 70-85%', 'Chocolate, dark, 70-85% cacao solids', 'حلويات ومشروبات', 598.0, 7.8, 45.9, 42.6, 20.0, NULL, 'usda', '170273', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'حلويات ومحليات', 10.9, '{"iron": 11.9, "zinc": 3.31, "vit_a": 2, "vit_e": 0.59, "vit_k": 7.3, "vit_b6": 0.038, "calcium": 73, "vit_b12": 0.28, "magnesium": 228, "potassium": 715}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('dfb3f266-e50a-4668-b7a7-0f3335529a6c', 'عصير برتقال', 'Orange juice, raw (Includes foods for USDA''s Food Distribution Program)', 'حلويات ومشروبات', 45.0, 0.7, 10.4, 0.2, 248.0, 'كوب', 'usda', '169098', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'مشروبات', 0.2, '{"iron": 0.2, "zinc": 0.05, "vit_a": 10, "vit_c": 50, "vit_d": 0, "vit_e": 0.04, "vit_k": 0.1, "folate": 30, "vit_b6": 0.04, "calcium": 11, "vit_b12": 0, "magnesium": 11, "potassium": 200}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d2f5464f-f0c3-4fd1-b457-5a4ab1f0d815', 'مايونيز', 'Salad dressing, mayonnaise, regular', 'صوصات', 680.0, 1.0, 0.6, 74.9, 15.0, 'ملعقة كبيرة', 'usda', '171009', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'دهون وزيوت', 0.0, '{"iron": 0.21, "zinc": 0.15, "vit_a": 16, "vit_c": 0, "vit_d": 0.2, "vit_e": 3.28, "vit_k": 163, "folate": 5, "vit_b6": 0.008, "calcium": 8, "vit_b12": 0.12, "magnesium": 1, "potassium": 20}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('78024843-1ea2-4d41-b9cb-d0dfef2f2f18', 'كاتشب', 'Catsup', 'صوصات', 101.0, 1.0, 27.4, 0.1, 17.0, 'ملعقة كبيرة', 'usda', '168556', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'صلصات', 0.3, '{"iron": 0.35, "zinc": 0.17, "vit_a": 26, "vit_c": 4.1, "vit_d": 0, "vit_e": 1.46, "vit_k": 3, "folate": 9, "vit_b6": 0.158, "calcium": 15, "vit_b12": 0, "magnesium": 13, "potassium": 281}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('39f9ee11-c216-400e-9af7-cab230fd0df5', 'ثوم', 'Garlic, raw', 'خضار', 149.0, 6.4, 33.1, 0.5, 5.0, 'فص ونص', 'usda', '169230', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'خضار', 2.1, '{"iron": 1.7, "zinc": 1.16, "vit_a": 0, "vit_c": 31.2, "vit_d": 0, "vit_e": 0.08, "vit_k": 1.7, "folate": 3, "vit_b6": 1.235, "calcium": 181, "vit_b12": 0, "magnesium": 25, "potassium": 401}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d2193a78-b130-407d-bcb4-bb903ab8d347', 'معجون طماطم', 'Tomato products, canned, paste, without salt added (Includes foods for USDA''s Food Distribution Program)', 'صوصات', 82.0, 4.3, 18.9, 0.5, 16.0, 'ملعقة كبيرة', 'usda', '170459', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'صلصات', 4.1, '{"iron": 2.98, "zinc": 0.63, "vit_a": 76, "vit_c": 21.9, "vit_d": 0, "vit_e": 4.3, "vit_k": 11.4, "folate": 12, "vit_b6": 0.216, "calcium": 36, "vit_b12": 0, "magnesium": 42, "potassium": 1014}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a1bb4abf-559e-4fa1-af16-99058a10e680', 'صلصة طماطم', 'Tomato products, canned, sauce', 'صوصات', 24.0, 1.2, 5.3, 0.3, 60.0, 'ربع كوب', 'usda', '170054', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'صلصات', 1.5, '{"iron": 0.96, "zinc": 0.22, "vit_a": 22, "vit_c": 7, "vit_d": 0, "vit_e": 1.44, "vit_k": 2.8, "folate": 9, "vit_b6": 0.098, "calcium": 14, "vit_b12": 0, "magnesium": 15, "potassium": 297}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('110632be-28c5-4b48-bb29-af177cce861b', 'ماسل ميلك سادة (المراعي 400 مل)', 'Almarai Muscle Milk Plain 400ml', 'مشروبات بروتينية', 58.0, 10.0, 3.8, 0.2, 400.0, 'عبوة 400 مل', 'coach', 'almarai.com/muscle-milk-plain', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('be882e3a-c423-4e75-ae0d-a3adf7e47a9f', 'خردل', 'Mustard, prepared, yellow', 'صوصات', 60.0, 3.7, 5.8, 3.3, 5.0, 'ملعقة صغيرة', 'usda', '172234', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'صلصات', 4.0, '{"iron": 1.61, "zinc": 0.64, "vit_a": 5, "vit_c": 0.3, "vit_d": 0, "vit_e": 0.36, "vit_k": 1.4, "folate": 7, "vit_b6": 0.07, "calcium": 63, "vit_b12": 0, "magnesium": 48, "potassium": 152}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('8cf303a5-d9e2-421f-a1aa-801ea2f09f57', 'صلصة رانش', 'Salad dressing, ranch dressing, regular', 'صوصات', 430.0, 1.3, 5.9, 44.5, 15.0, 'ملعقة كبيرة', 'usda', '173592', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'صلصات', 0.0, '{"iron": 0.3, "zinc": 0.17, "vit_a": 15, "vit_c": 0, "vit_d": 0.1, "vit_e": 2.22, "vit_k": 134.3, "folate": 4, "vit_b6": 0.03, "calcium": 28, "vit_b12": 0.17, "magnesium": 5, "potassium": 64}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ac6ea062-9b9c-498c-84bc-7a833a364953', 'كريمة طبخ', 'Cream, fluid, light (coffee cream or table cream)', 'بيض وألبان', 195.0, 3.0, 3.7, 19.1, 30.0, 'ملعقتين كبار', 'usda', '170857', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', 0.0, '{"iron": 0.05, "zinc": 0.32, "vit_a": 120, "vit_c": 0.8, "vit_d": 1.1, "vit_e": 0.12, "vit_k": 1.7, "folate": 2, "vit_b6": 0.044, "calcium": 91, "vit_b12": 0.14, "magnesium": 9, "potassium": 136}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('be0c7ab7-d171-4b34-9b08-cd8f30c0807f', 'جبنة كريمية لايت (فيلادلفيا لايت)', 'Cheese, cream, low fat', 'بيض وألبان', 208.0, 7.9, 6.7, 16.7, 30.0, 'ملعقتين كبار', 'usda', '169079', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', 0.0, '{"iron": 0.17, "zinc": 0.57, "vit_a": 161, "vit_c": 0, "vit_d": 0.3, "vit_e": 0.27, "vit_k": 1.1, "folate": 19, "vit_b6": 0.045, "calcium": 148, "vit_b12": 0.92, "magnesium": 8, "potassium": 247}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('21196de0-c76c-4aae-98f7-71870d1a6a22', 'جبنة بارميزان مبشورة', 'Cheese, parmesan, grated', 'بيض وألبان', 420.0, 28.4, 13.9, 27.8, 10.0, 'ملعقة كبيرة', 'usda', '171247', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', 0.0, '{"iron": 0.49, "zinc": 4.2, "vit_a": 262, "vit_c": 0, "vit_d": 0.5, "vit_e": 0.53, "vit_k": 1.7, "folate": 6, "vit_b6": 0.081, "calcium": 853, "vit_b12": 1.4, "magnesium": 34, "potassium": 180}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('c4c1fcf7-ff77-4cfe-a7db-8766e833b14a', 'جبنة شرائح (مطبوخة)', 'Cheese, pasteurized process, American, fortified with vitamin D', 'بيض وألبان', 366.0, 18.1, 4.8, 30.7, 20.0, 'شريحة', 'usda', '170853', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', 0.0, '{"iron": 0.63, "zinc": 2.49, "vit_a": 317, "vit_c": 0, "vit_d": 7.5, "vit_e": 0.8, "vit_k": 3.7, "folate": 8, "vit_b6": 0.054, "calcium": 1045, "vit_b12": 1.5, "magnesium": 26, "potassium": 132}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('7b63cf57-6c8c-40bf-b726-c80cbd62cdd0', 'جبنة بروفولون (بديل القشقوان)', 'Cheese, provolone', 'بيض وألبان', 351.0, 25.6, 2.1, 26.6, 25.0, 'شريحة', 'usda', '170850', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', 0.0, '{"iron": 0.52, "zinc": 3.23, "vit_a": 236, "vit_c": 0, "vit_d": 0.5, "vit_e": 0.23, "vit_k": 2.2, "folate": 10, "vit_b6": 0.073, "calcium": 756, "vit_b12": 1.46, "magnesium": 28, "potassium": 138}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('8e95ba95-232b-404b-8eea-bcd70ee13552', 'حليب بودرة خالي الدسم', 'Milk, dry, nonfat, regular, without added vitamin A and vitamin D', 'بيض وألبان', 362.0, 36.2, 52.0, 0.8, 10.0, 'ملعقة كبيرة', 'usda', '170877', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', 0.0, '{"iron": 0.32, "zinc": 4.08, "vit_a": 6, "vit_c": 6.8, "vit_d": 0, "vit_e": 0, "vit_k": 0.1, "folate": 50, "vit_b6": 0.361, "calcium": 1257, "vit_b12": 4.03, "magnesium": 110, "potassium": 1794}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('47f06276-2dc3-4691-97d8-e9cf03aa9cbe', 'دقيق بر (أسمر)', 'Wheat flour, whole-grain (Includes foods for USDA''s Food Distribution Program)', 'حبوب ونشويات', 340.0, 13.2, 72.0, 2.5, 30.0, 'ربع كوب', 'usda', '168893', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'حبوب ونشويات', 10.7, '{"iron": 3.6, "zinc": 2.6, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.71, "vit_k": 1.9, "folate": 44, "vit_b6": 0.407, "calcium": 34, "vit_b12": 0, "magnesium": 137, "potassium": 363}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('81dc460f-fa1e-49f6-a90a-2848d157e83d', 'دقيق أبيض', 'Wheat flour, white, all-purpose, enriched, unbleached', 'حبوب ونشويات', 364.0, 10.3, 76.3, 1.0, 30.0, 'ربع كوب', 'usda', '168936', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'حبوب ونشويات', 2.7, '{"iron": 4.64, "zinc": 0.7, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.23, "vit_k": 0.3, "folate": 291, "vit_b6": 0.044, "calcium": 15, "vit_b12": 0, "magnesium": 22, "potassium": 107}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('4a9c87a5-92bc-45d2-9b8c-f0d2ff5cb2df', 'نشا الذرة', 'Cornstarch', 'حبوب ونشويات', 381.0, 0.3, 91.3, 0.1, 8.0, 'ملعقة كبيرة', 'usda', '169698', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'حبوب ونشويات', 0.9, '{"iron": 0.47, "zinc": 0.06, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0, "vit_k": 0, "folate": 0, "vit_b6": 0, "calcium": 2, "vit_b12": 0, "magnesium": 3, "potassium": 3}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ae5e0240-6da7-4263-a362-62e53fc85770', 'كاكاو بودرة (بدون سكر)', 'Cocoa, dry powder, unsweetened', 'حلويات ومشروبات', 228.0, 19.6, 57.9, 13.7, 5.0, 'ملعقة كبيرة', 'usda', '169593', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'حلويات ومحليات', 37.0, '{"iron": 13.86, "zinc": 6.81, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.1, "vit_k": 2.5, "folate": 32, "vit_b6": 0.118, "calcium": 128, "vit_b12": 0, "magnesium": 499, "potassium": 1524}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('10f730c3-3f0f-4b3c-b1a0-ba46073cb767', 'باكنج باودر', 'Leavening agents, baking powder, double-acting, straight phosphate', 'حلويات ومشروبات', 51.0, 0.1, 24.1, 0.0, 4.0, 'ملعقة صغيرة', 'usda', '172804', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'حلويات ومحليات', 0.2, '{"iron": 11.27, "zinc": 0.02, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0, "vit_k": 0, "folate": 0, "vit_b6": 0, "calcium": 7364, "vit_b12": 0, "magnesium": 39, "potassium": 5}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('6141eaa6-7f19-49ef-a3af-3d434196d31b', 'شوكولاتة بالحليب', 'Candies, milk chocolate', 'حلويات ومشروبات', 535.0, 7.7, 59.4, 29.7, 20.0, 'مربعين', 'usda', '167587', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'حلويات ومحليات', 3.4, '{"iron": 2.35, "zinc": 2.3, "vit_a": 59, "vit_c": 0, "vit_d": 0, "vit_e": 0.51, "vit_k": 5.7, "folate": 11, "vit_b6": 0.036, "calcium": 189, "vit_b12": 0.75, "magnesium": 63, "potassium": 372}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('312bb553-f62c-4f5c-9886-f76ebffe4222', 'زبادي يوناني كامل الدسم فراولة (ندى 160 غ)', 'Nada Greek Yoghurt Full Fat Strawberry 160g', 'زبادي يوناني', 147.0, 7.0, 14.0, 7.0, 160.0, 'عبوة 160 غ', 'coach', 'nada.com.sa/greek-yoghurt-full-fat-straw', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('bf819599-a205-4d53-8d1a-d82002ea98da', 'آيسكريم فانيلا', 'Ice creams, vanilla', 'حلويات ومشروبات', 207.0, 3.5, 23.6, 11.0, 66.0, 'نص كوب', 'usda', '167575', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'حلويات ومحليات', 0.7, '{"iron": 0.09, "zinc": 0.69, "vit_a": 118, "vit_c": 0.6, "vit_d": 0.2, "vit_e": 0.3, "vit_k": 0.3, "folate": 5, "vit_b6": 0.048, "calcium": 128, "vit_b12": 0.39, "magnesium": 14, "potassium": 199}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b656192a-ca04-41cf-98f2-c2ec38fd1219', 'بسكويت سادة (جراهام)', 'Cookies, graham crackers, plain or honey (includes cinnamon)', 'حلويات ومشروبات', 430.0, 6.7, 77.7, 10.6, 15.0, 'حبتين', 'usda', '174957', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'حلويات ومحليات', 3.4, '{"iron": 3.78, "zinc": 0.96, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 1.51, "vit_k": 14.3, "folate": 142, "vit_b6": 0.156, "calcium": 77, "vit_b12": 0, "magnesium": 40, "potassium": 170}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('7f505355-eeaf-4770-9cc0-8374b37dc373', 'كريمة خفق بودرة (دريم ويب)', 'Dessert topping, powdered', 'حلويات ومشروبات', 577.0, 4.9, 52.5, 39.9, 10.0, 'ملعقتين كبار', 'usda', '170865', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'حلويات ومحليات', 0.0, '{"iron": 0.03, "zinc": 0.08, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 1.52, "vit_k": 9.9, "folate": 0, "vit_b6": 0, "calcium": 17, "vit_b12": 0, "magnesium": 7, "potassium": 166}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('e15ae0a3-8da9-49cf-8efa-a3951112c7b2', 'خبز بريوش', 'Bread, egg', 'خبز', 287.0, 9.5, 47.8, 6.0, 40.0, 'شريحة', 'usda', '172673', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'حبوب ونشويات', 2.3, '{"iron": 3.04, "zinc": 0.79, "vit_a": 63, "vit_c": 0, "vit_d": 0.4, "vit_e": 0.26, "vit_k": 0.9, "folate": 130, "vit_b6": 0.064, "calcium": 93, "vit_b12": 0.1, "magnesium": 19, "potassium": 115}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b06bc316-94f5-4876-9170-0bdffcc46669', 'بيكان', 'Nuts, pecans', 'دهون ومكسرات', 691.0, 9.2, 13.9, 72.0, 15.0, 'حفنة صغيرة', 'usda', '170182', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'مكسرات وبذور', 9.6, '{"iron": 2.53, "zinc": 4.53, "vit_a": 3, "vit_c": 1.1, "vit_d": 0, "vit_e": 1.4, "vit_k": 3.5, "folate": 22, "vit_b6": 0.21, "calcium": 70, "vit_b12": 0, "magnesium": 121, "potassium": 410}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('527b9667-e1ba-40f4-90d5-7ddfce95dff7', 'بطاطس نيئة', 'Potatoes, flesh and skin, raw', 'حبوب ونشويات', 77.0, 2.1, 17.5, 0.1, 150.0, 'حبة متوسطة', 'usda', '170026', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'خضار نشوية', 2.1, '{"iron": 0.81, "zinc": 0.3, "vit_a": 0, "vit_c": 19.7, "vit_d": 0, "vit_e": 0.01, "vit_k": 2, "folate": 15, "vit_b6": 0.298, "calcium": 12, "vit_b12": 0, "magnesium": 23, "potassium": 425}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('908e747c-6aeb-445d-8ff2-272162ffab17', 'لحم بقري مفروم 90% نيء', 'Beef, ground, 90% lean meat / 10% fat, raw', 'لحوم ودواجن', 176.0, 20.0, 0.0, 10.0, 120.0, 'قطعة برجر', 'usda', '174030', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'لحوم حمراء', 0.0, '{"iron": 2.24, "zinc": 4.79, "vit_a": 4, "vit_c": 0, "vit_d": 0.1, "vit_e": 0.17, "vit_k": 0.8, "folate": 6, "vit_b6": 0.369, "calcium": 12, "vit_b12": 2.21, "magnesium": 20, "potassium": 321}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('2d1abe88-4a14-43d4-9e6d-0664fbcc6b26', 'تندرلوين بقري نيء (بدون دهن)', 'Beef, tenderloin, steak, separable lean only, trimmed to 1/8" fat, select, raw', 'لحوم ودواجن', 148.0, 22.1, 0.0, 5.9, 150.0, 'قطعة', 'usda', '171803', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'لحوم حمراء', 0.0, '{"iron": 1.6, "zinc": 3.97, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.31, "vit_k": 1.2, "folate": 13, "vit_b6": 0.622, "calcium": 22, "vit_b12": 0.93, "magnesium": 23, "potassium": 354}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('085e2793-61fa-4c05-86e7-aaefa4d8660d', 'قهوة سريعة التحضير (بودرة)', 'Beverages, coffee, instant, regular, powder', 'حلويات ومشروبات', 353.0, 12.2, 75.4, 0.5, 2.0, 'ملعقة صغيرة', 'usda', '171893', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'مشروبات', 0.0, '{"iron": 4.41, "zinc": 0.35, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0, "vit_k": 1.9, "folate": 0, "vit_b6": 0.029, "calcium": 141, "vit_b12": 0, "magnesium": 327, "potassium": 3535}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('8065260a-22ac-4a9e-a9ab-231f6671e37e', 'حليب بروتين قهوة (ندى 320 مل)', 'Nada Protein Milk Coffee 320ml', 'مشروبات بروتينية', 87.0, 9.5, 10.0, 0.1, 320.0, 'عبوة 320 مل', 'coach', 'nada.com.sa/protein-milk-320ml-coffee', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('87e49ec5-4d7e-4585-9fb6-bd24256a7831', 'حليب بروتين سادة (ندى 320 مل)', 'Nada Protein Plain Milk 320ml', 'مشروبات بروتينية', 60.0, 8.5, 8.7, 0.1, 320.0, 'عبوة 320 مل', 'coach', 'nada.com.sa/protein-plain-milk', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('442b4fd7-5b98-486a-b157-f9b3a6de9c76', 'حليب بروتين شوكولاتة (ندى 320 مل)', 'Nada Protein Chocolate Milk 320ml', 'مشروبات بروتينية', 84.0, 8.5, 12.5, 0.1, 320.0, 'عبوة 320 مل', 'coach', 'nada.com.sa/protein-chocolate-milk', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('e1b1029c-0af9-4e5f-920e-77eb4c49d703', 'حليب بروتين تمر (ندى 320 مل)', 'Nada Protein Dates Milk 320ml', 'مشروبات بروتينية', 108.0, 8.5, 15.0, 1.5, 320.0, 'عبوة 320 مل', 'coach', 'nada.com.sa/protein-dates-milk', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('8f4ab0de-cf3d-43b6-b704-8a735b779117', 'باور ميلك قهوة (ندى 425 مل)', 'Nada Power Milk Coffee 425ml', 'مشروبات بروتينية', 87.0, 9.5, 10.0, 0.1, 425.0, 'عبوة 425 مل', 'coach', 'nada.com.sa/power-milk-425ml-coffee', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ce5bb347-f490-4479-871d-583806f48eee', 'باور ميلك شوكولاتة (ندى)', 'Nada Power Milk Chocolate', 'مشروبات بروتينية', 87.0, 9.5, 12.5, 0.1, NULL, NULL, 'coach', 'nada.com.sa/power-milk-chocolate', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('dfafc3ec-a64c-4aa3-8fe2-f4c37d5018a2', 'باور ميلك فانيلا (ندى)', 'Nada Power Milk Vanilla', 'مشروبات بروتينية', 87.0, 9.5, 12.5, 0.1, NULL, NULL, 'coach', 'nada.com.sa/power-milk-vanilla-mixed-fru', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('6c45e2e5-7cb5-4bbb-bd12-114063c35392', 'حليب بروتين شوكولاتة (المراعي 400 مل)', 'Almarai Protein Milk Chocolate 400ml', 'مشروبات بروتينية', 73.0, 8.5, 9.6, 0.4, 400.0, 'عبوة 400 مل', 'coach', 'almarai.com/protein-milk-chocolate', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a1c1d107-a125-42b6-b083-b8a3824e5734', 'حليب بروتين فراولة وموز (المراعي 400 مل)', 'Almarai Protein Milk Strawberry Banana 400ml', 'مشروبات بروتينية', 71.0, 8.5, 9.2, 0.3, 400.0, 'عبوة 400 مل', 'coach', 'almarai.com/protein-milk-strawberry-bana', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('c5bca3ae-928d-4876-af5b-eeb50d57b49d', 'حليب بروتين فانيلا (المراعي 400 مل)', 'Almarai Protein Milk Vanilla 400ml', 'مشروبات بروتينية', 72.0, 8.5, 9.4, 0.3, 400.0, 'عبوة 400 مل', 'coach', 'almarai.com/protein-milk-vanilla', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a42c8bb6-4b6e-4c14-942f-5c59c64e406b', 'زبادي يوناني ليمون ونعناع (ندى)', 'Nada Greek Yoghurt Lemon Mint', 'زبادي يوناني', 137.0, 7.0, 11.5, 7.0, NULL, NULL, 'coach', 'nada.com.sa/greek-yoghurt-with-lemon-min', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ae4da413-9d5c-439e-9e59-6d2ed76a028a', 'زبادي يوناني توت مشكل كامل الدسم (ندى)', 'Nada Greek Yoghurt Mixed Berry Full Cream', 'زبادي يوناني', 148.0, 7.0, 14.3, 7.0, NULL, NULL, 'coach', 'nada.com.sa/greek-yoghurt-with-mixed-ber', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('0d9d901f-909e-499f-9426-2dea78e938a7', 'زبادي يوناني سادة (ندى 160)', 'Nada Greek Yoghurt Plain', 'زبادي يوناني', 111.0, 7.0, 5.0, 7.0, 160.0, 'عبوة 160 مل', 'coach', 'nada.com.sa/greek-yoghurt-plain', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('4cd0cca5-d9c9-47bd-9893-0105fec88896', 'زبادي يوناني 0% دهون سادة (ندى 160)', 'Nada Greek Yoghurt 0% Fat Plain', 'زبادي يوناني', 63.0, 10.0, 5.0, 0.3, 160.0, 'عبوة 160 مل', 'coach', 'nada.com.sa/greek-yoghurt-0-fat-plain', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('7c4dd998-8364-431a-9e6f-eb85ad57db60', 'زبادي يوناني قليل الدسم سادة (ندى 160)', 'Nada Greek Yoghurt Low Fat Plain', 'زبادي يوناني', 66.0, 7.0, 5.0, 2.0, 160.0, 'عبوة 160 مل', 'coach', 'nada.com.sa/greek-yoghurt-low-fat-plain', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('e83bd1a6-a344-4776-b7d7-1f9e74950db6', 'زبادي يوناني بالعسل الطبيعي (ندى 160)', 'Nada Greek Yoghurt Natural Honey', 'زبادي يوناني', 141.0, 7.0, 12.5, 7.0, 160.0, 'عبوة 160 مل', 'coach', 'nada.com.sa/greek-yoghurt-natural-honey', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('536bc365-01a7-4693-9812-244178273280', 'زبادي يوناني توت أسود وتوت العليق (ندى 160)', 'Nada Greek Yoghurt Blackberry Raspberry', 'زبادي يوناني', 151.0, 7.0, 15.0, 7.0, 160.0, 'عبوة 160 مل', 'coach', 'nada.com.sa/greek-yoghurt-berry', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('58bd09cb-b451-4835-a418-9f76c73360a5', 'زبادي يوناني 0% دهون توت مشكل (ندى 160)', 'Nada Greek Yoghurt 0% Fat Mixed Berry', 'زبادي يوناني', 100.0, 10.0, 14.3, 0.3, 160.0, 'عبوة 160 مل', 'coach', 'nada.com.sa/greek-yoghurt-0-fat-mixed-be', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('56b79bca-c772-4f20-b2ec-c294a87e5209', 'زبادي يوناني قليل الدسم توت أزرق (ندى 160)', 'Nada Greek Yoghurt Low Fat Blueberry', 'زبادي يوناني', 102.0, 7.0, 14.0, 2.0, 160.0, 'عبوة 160 مل', 'coach', 'nada.com.sa/greek-yoghurt-low-fat-bluebe', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('11f632d2-0a15-42ff-803e-98938c8d972e', 'زبادي يوناني 0% دهون مانجو وخوخ (ندى 160)', 'Nada Greek Yoghurt 0% Fat Mango Peach', 'زبادي يوناني', 111.0, 10.0, 17.0, 0.3, 160.0, 'عبوة 160 مل', 'coach', 'nada.com.sa/greek-yoghurt-0-fat-mango-pe', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('9ce0c9e1-774d-46b7-938b-2693dfa65d49', 'زبادي يوناني قليل الدسم فراولة (ندى 160)', 'Nada Greek Yoghurt Low Fat Strawberry', 'زبادي يوناني', 98.0, 6.0, 14.0, 2.0, 160.0, 'عبوة 160 مل', 'coach', 'nada.com.sa/greek-yoghurt-low-fat-strawb', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('1059f7bb-e896-448d-81a4-02ce7f34c8e6', 'لبن زبادي طازج قليل الدسم (ندى 150 غ)', 'Nada Fresh Yoghurt Low Fat', 'زبادي يوناني', 45.0, 3.1, 5.5, 1.2, 150.0, 'عبوة 150 غ', 'coach', 'nada.com.sa/fresh-yoghurt-low-fat', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('63712f2e-f3ef-4ab3-afc0-ea8acc6f0551', 'زبادي يوناني للشرب سادة (ندى 330 مل)', 'Nada Drinking Greek Yoghurt Plain', 'زبادي يوناني', 68.0, 9.1, 4.5, 1.5, 330.0, 'عبوة 330 مل', 'coach', 'nada.com.sa/drinking-greek-yoghurt-plain', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('1acbc234-b010-42b8-8469-4accdd07c7bd', 'زبادي يوناني للشرب توت أسود وتوت العليق (ندى 330 مل)', 'Nada Drinking Greek Yoghurt Blackberry Raspberry', 'زبادي يوناني', 97.0, 8.2, 12.7, 1.5, 330.0, 'عبوة 330 مل', 'coach', 'nada.com.sa/drinking-greek-yoghurt-berry', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('00b18b05-0a96-475b-9555-0abd4eabba5b', 'زبادي يوناني للشرب مانجو (ندى 330 مل)', 'Nada Drinking Greek Yoghurt Mango', 'زبادي يوناني', 94.0, 8.2, 11.9, 1.5, 330.0, 'عبوة 330 مل', 'coach', 'nada.com.sa/drinking-greek-yoghurt-mango', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('468fbad6-77fa-4edb-bbd4-f67c89cc726b', 'زبادي يوناني للشرب باشن فروت وبذور الشيا (ندى 330 مل)', 'Nada Drinking Greek Yoghurt Passion Chia', 'زبادي يوناني', 101.0, 8.2, 13.6, 1.5, 330.0, 'عبوة 330 مل', 'coach', 'nada.com.sa/drinking-greek-yoghurt-passi', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('6ae202ac-ffea-4fad-94c4-f25c0ebd2991', 'زبادي يوناني للشرب فراولة وحبوب (ندى 330 مل)', 'Nada Drinking Greek Yoghurt Strawberry Cereal', 'زبادي يوناني', 94.0, 8.2, 11.9, 1.5, 330.0, 'عبوة 330 مل', 'coach', 'nada.com.sa/drinking-greek-yoghurt-straw', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('4ef11626-302b-48a5-a2a6-df6adfa43e7b', 'زبادي يوناني سادة (المراعي 150 غ)', 'Almarai Plain Greek Style Yoghurt 150g', 'زبادي يوناني', 139.0, 6.7, 8.7, 8.7, 150.0, 'عبوة 150 غ', 'coach', 'almarai.com/plain-greek-style-yoghurt', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('1fba0916-a3ef-4cf7-aa31-3e9a38b2fd34', 'زبادي يوناني فراولة (المراعي 150 غ)', 'Almarai Strawberry Greek Style Yoghurt 150g', 'زبادي يوناني', 150.0, 6.0, 15.3, 7.3, 150.0, 'عبوة 150 غ', 'coach', 'almarai.com/strawberry-greek-style-yoghu', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ecfc7a39-a7ae-45af-8b1c-4f3d9ad9db32', 'زبادي يوناني مانجو (المراعي 150 غ)', 'Almarai Mango Greek Style Yoghurt 150g', 'زبادي يوناني', 150.0, 5.9, 15.3, 7.2, 150.0, 'عبوة 150 غ', 'coach', 'almarai.com/mango-greek-style-yoghurt', true, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;



INSERT INTO public.policies VALUES ('terms', 'الشروط والأحكام', '- يُقصد بالمتدرب كل من يشترك في الخدمة من الجنسين.
- يبدأ الاشتراك بعد التحقق من وصول التحويل البنكي، وتعبئة استبيان المتدرب.
- ساعات العمل: الأحد – الخميس، 12 ظهراً – 9 مساءً. الرد على الرسائل خلال 48 ساعة عمل.
- البرنامج لا يغني عن الاستشارة الطبية، والمتدرب مسؤول عن الإفصاح عن أي إصابة أو حالة صحية.
- الجداول ملك المتدرب مدى الحياة والتعديل عليها متاح.
- الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي.', 0, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;
INSERT INTO public.policies VALUES ('refund', 'الضمان والاسترجاع', '- في اشتراكات 3 أشهر لباقات المتابعة (المكثفة، المتقدمة، الأساسية): يُسترد المبلغ كاملاً إذا لم يتحسن أي من مؤشرات التقدم (متوسط الوزن الأسبوعي، محيط الخصر، القوة في التمارين الأساسية) بعد 12 أسبوعاً.
- شروط الضمان: إرسال المراجعة الأسبوعية كل أسبوع، وأخذ القياسات بانتظام، وتصوير التمارين وإرسالها، والالتزام بجدول التغذية المخصص في الباقات التي تشملها.
- يُطلب الاسترجاع عبر واتساب خلال 14 يوماً من نهاية الأشهر الثلاثة، ويُرجع المبلغ بتحويل بنكي.
- التجديد المجاني: اشتراك 3 أشهر يُكافأ بـ 3 أشهر إضافية عند التزام 90% فأكثر وتقدم واضح في مؤشرات التقدم. صور التطور تُرسل للمدربة للتوثيق (للرجال مع تغطية الوجه والسرة)، ونشرها اختياري.', 1, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;
INSERT INTO public.policies VALUES ('privacy', 'سياسة الخصوصية', '- نجمع: الاسم، البريد الإلكتروني (للدخول إلى حسابك)، رقم الجوال (واتساب)، الباقة المختارة، ومعلومات الاستبيان التي تكتبها بنفسك (ومنها معلومات صحية وقياسات اختيارية).
- الغرض: تنفيذ طلبك، وتصميم برنامجك ومتابعتك، والتواصل معك بخصوصه فقط.
- المعلومات الصحية تُحفظ منفصلة، ولا يطّلع عليها إلا أنت والمدربة، ولا تُرسل في رسائل البريد أو التنبيهات.
- الدفع بتحويل بنكي مباشر لحساب المؤسسة، والموقع لا يطلب أو يخزن أي بيانات بنكية أو بيانات بطاقات. إيصال التحويل يُستخدم لتأكيد طلبك فقط، ويُحفظ في تخزين خاص لا يُفتح إلا لك وللمدربة.
- لا نبيع بياناتك ولا نشاركها مع أي طرف لأغراض تسويقية، ولا تُنشر نتيجتك أو صورتك إلا بموافقتك الصريحة.
- يحق طلب نسخة من البيانات أو حذفها أو سحب موافقتك على النشر بمراسلتنا على واتساب.
- القياس والتحليلات: نستخدم Google Analytics لقياس زيارات صفحات الموقع العامة وتحسين تجربتك، وذلك فقط بعد موافقتك على الشريط الذي يظهر عند أول زيارة، والرفض متاح فلا تُقاس الزيارة. لا نفعّل القياس داخل حسابك أو صفحات الطلب والدفع والبرامج، ولا نربطه ببياناتك الصحية أو الشخصية، ولا نستخدمه للإعلانات. تُعالَج بيانات القياس لدى Google، وهي مجهولة الهوية في غالبها (عنوان IP يُقنَّع، وبدون ميزات الإعلانات المخصصة). تقدر تسحب موافقتك بمسح بيانات الموقع من متصفحك، فيظهر لك الشريط مرة ثانية.', 2, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;
INSERT INTO public.policies VALUES ('reviews', 'سياسة التقييمات', '- يكتب التقييم فقط من اشترى خدمة وبدأها فعلاً، وتقييم واحد لكل طلب.
- كل تقييم يُراجع قبل ظهوره للعامة، ولا يُعدّل نصه أبداً.
- طريقة ظهور الاسم اختيارية: الاسم كامل، أو الاسم الأول فقط، أو بدون اسم. والموافقة على النشر منفصلة واختيارية.
- لا يُنشر تقييم يحتوي أرقام هواتف أو بريد أو روابط أو تفاصيل صحية خاصة أو إساءة لأي شخص.
- يحق للمدربة الرد على التقييم، أو إخفاء التقييم المخالف لهذه السياسة مع تسجيل السبب.
- يحق طلب إخفاء التقييم في أي وقت بمراسلتنا على واتساب.', 3, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;



INSERT INTO public.products VALUES ('afa6b2bb-c1b1-4e55-9f41-958c4ae1c54d', 'intensive', 'follow', 'الباقة المكثفة', 'الأنسب للمبتدئين ولمن يحتاج متابعة أسبوعية مع زوم: تمرين + تغذية + زوم + جلسة حضورية', '[{"text": "جلسة حضورية مجانية لمدة ساعة لتصحيح التكنيك والتأكد من جودة التمرين (للبنات في المنطقة الشرقية)", "included": true}, {"text": "ملف شامل للخطة التدريبية والتغذية مع شروحات وافية للتمارين، بالمنزل أو بالنادي", "included": true}, {"text": "4 مكالمات زوم شهرياً نتابع فيها تطورك واستفساراتك الرياضية والنفسية", "included": true}, {"text": "مناقشة أسبوعية لتطورك البدني والنفسي (فيديو أو تسجيل صوتي) مع تعديل السعرات أو التمرين عند الحاجة", "included": true}, {"text": "شرح سهل ومبسط لتطبيق حساب السعرات MyFitnessPal", "included": true}, {"text": "كتيب شامل للرياضة والتغذية", "included": true}, {"text": "مساعدتك على اختيارات أنسب لصحتك ونمط حياتك في التغذية والروتين اليومي", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}]', NULL, 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.', true, NULL, 'published', 0, false, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', false, NULL, 1, NULL, true) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('48f74351-f1a7-47ce-8a91-a5e81722ba7c', 'advanced', 'follow', 'الباقة المتقدمة', 'لمن عنده خبرة ويحتاج تمرين + تغذية مع متابعة أسبوعية، بدون زوم', '[{"text": "ملف شامل للخطة التدريبية والتغذية مع شروحات وافية للتمارين، بالمنزل أو بالنادي", "included": true}, {"text": "مناقشة أسبوعية لتطورك البدني والنفسي (فيديو أو تسجيل صوتي) مع تعديل السعرات أو التمرين عند الحاجة", "included": true}, {"text": "كتيب شامل للرياضة والتغذية", "included": true}, {"text": "مساعدتك على اختيارات أنسب لصحتك ونمط حياتك في التمرين والروتين اليومي", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}, {"text": "مكالمات زوم والجلسة الحضورية (في المكثفة فقط)", "included": false}]', NULL, 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.', false, NULL, 'published', 1, false, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', false, NULL, 1, NULL, true) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('fd8bab72-c7bd-465b-bb3f-617379d268c7', 'basic', 'follow', 'الباقة الأساسية', 'لمن يعرف يضبط أكله ويحتاج خطة تمرين فقط، ومتابعة كل أسبوعين', '[{"text": "ملف شامل للخطة التدريبية مع شروحات وافية للتمارين، بالمنزل أو بالنادي", "included": true}, {"text": "مناقشة كل أسبوعين لتطورك البدني والنفسي (فيديو أو تسجيل صوتي) مع تعديل التمرين عند الحاجة", "included": true}, {"text": "كتيب شامل للرياضة والتغذية", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}, {"text": "بدون خطة تغذية", "included": false}]', NULL, 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.', false, NULL, 'published', 2, false, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', false, NULL, 2, NULL, true) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('7cd4f34c-9135-4d64-b358-a81140c321a2', 'nutrition', 'follow', 'باقة التغذية', 'لمن يحتاج خطة تغذية شاملة ويتعلم حساب السعرات، بدون خطة تمرين', '[{"text": "خطة تغذية شاملة تناسب هدفك ونمط حياتك", "included": true}, {"text": "تحديد السعرات المناسبة لك ولهدفك", "included": true}, {"text": "تعليمك حسبة السعرات ومساعدتك باختيارات تغذية تناسبك", "included": true}, {"text": "ملف Excel لمتابعة التطور والقياسات", "included": true}, {"text": "مناقشة أسبوعية لعلاقتك بالتغذية في المنزل أو خارجه", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}, {"text": "لا تحتاجها إذا كنت مشتركاً في المكثفة أو المتقدمة، لأن التغذية ضمنها", "included": false}]', 'شهر واحد · غالباً لا تحتاج تجديد', 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي، ولا يوجد تجديد تلقائي. ضمان الاسترجاع يشمل اشتراكات 3 أشهر للمكثفة والمتقدمة والأساسية فقط.', false, NULL, 'published', 3, false, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', false, NULL, 1, NULL, false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('73a68580-832d-4773-9bc4-01d01f284c61', 'custom-training-plan', 'files', 'بديل التدريب الشخصي', 'لمن لا يحتاج متابعة (متقدم)، أو كبديل أوفر للتدريب الشخصي', '[{"text": "جدول تمرين مخصص لعدد أيام التمرين اللي تحتاجها", "included": true}, {"text": "طريقة حساب الجهد وعدد الجولات المطلوبة", "included": true}, {"text": "تقدر تحمّل الجدول على جهازك", "included": true}]', NULL, 'جدول مخصص بعد الاستبيان تستلمه كملف، وتقدر تحمّله على جهازك. بدون متابعة.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي. الجداول لك مدى الحياة وتقدر تعدّل عليها.', false, NULL, 'published', 4, false, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', false, NULL, 1, NULL, false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('27cbba7c-8041-48ac-8030-736ce4abba4f', 'training-nutrition-plan', 'files', 'جدول تمارين مع التغذية', 'لمن لا يحتاج متابعة (متقدم)، أو كبديل أوفر للتدريب الشخصي', '[{"text": "جدول تمرين مخصص لعدد أيام التمرين اللي تحتاجها", "included": true}, {"text": "طريقة حساب الجهد وعدد الجولات المطلوبة", "included": true}, {"text": "جدول تغذية فيه خيارات تناسب هدفك الرياضي", "included": true}, {"text": "تقدر تحمّل الجدول على جهازك", "included": true}]', NULL, 'جدول مخصص بعد الاستبيان تستلمه كملف، وتقدر تحمّله على جهازك. بدون متابعة.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي. الجداول لك مدى الحياة وتقدر تعدّل عليها.', false, NULL, 'published', 5, false, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', false, NULL, 1, NULL, false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('e41c03ba-f18d-4e1f-a973-5d063b828b47', 'nutrition-consultation', 'consult', 'جلسة استشارة تغذية', 'لمن عنده أسئلة محددة في التغذية: جلسة وحدة تكفي لحسبة سعراتك ونصائح الأكل.', '[{"text": "مناقشة كل أسئلتك في مجال التغذية", "included": true}, {"text": "حسبة سعرات مناسبة لهدفك مع اقتراحات لأصناف الطعام", "included": true}, {"text": "نصائح في المكملات، وكيف تأكل برّا بطريقة صحيحة", "included": true}]', NULL, 'جلسة عبر Google Meet أو واتساب — المناسب لك.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي.', false, NULL, 'published', 6, false, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', false, NULL, 1, NULL, false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('50a92ca8-78b3-485e-a0eb-26e85c270bac', 'training-consultation', 'consult', 'جلسة استشارة تمرين', 'لمن عنده أسئلة محددة في التمرين: جلسة وحدة تكفي لتعديل جدولك وتصحيح التكنيك.', '[{"text": "مناقشة كل أسئلتك في مجال التمرين", "included": true}, {"text": "تعديل جدولك الرياضي بما يناسب هدفك، مع اقتراحات لتمارين المرونة", "included": true}, {"text": "تصحيح تكنيك التمارين اللي تشك إنها غلط أو تسبب لك ألم", "included": true}, {"text": "التأكد من أن جودة تمرينك مناسبة للبناء العضلي", "included": true}]', NULL, 'جلسة عبر Google Meet أو واتساب — المناسب لك.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي.', false, NULL, 'published', 7, false, '2026-10-19 13:52:42.775264+00', '2026-10-19 13:52:42.775264+00', false, NULL, 1, NULL, false) ON CONFLICT DO NOTHING;



INSERT INTO public.product_offers VALUES ('e1e09068-f033-409a-b280-f9d9f9e1d31b', 'afa6b2bb-c1b1-4e55-9f41-958c4ae1c54d', 'int1', 'شهر واحد', 1, 59900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('515ddd69-9cbf-4dba-a152-d4b99a6517fc', 'afa6b2bb-c1b1-4e55-9f41-958c4ae1c54d', 'int3', '3 أشهر', 3, 155000, 'SAR', true, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('ac965746-55ae-4571-ae82-d57f1d2cacd3', '48f74351-f1a7-47ce-8a91-a5e81722ba7c', 'adv1', 'شهر واحد', 1, 49900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('d3dafb8c-372b-4a48-819e-1cb77df92b4a', '48f74351-f1a7-47ce-8a91-a5e81722ba7c', 'adv3', '3 أشهر', 3, 125000, 'SAR', true, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('69a5dcab-fe43-4e0a-8b8f-218e16ddd3bf', 'fd8bab72-c7bd-465b-bb3f-617379d268c7', 'bas1', 'شهر واحد', 1, 34900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('ad825084-26da-4162-acd4-e575b66d6a3f', 'fd8bab72-c7bd-465b-bb3f-617379d268c7', 'bas3', '3 أشهر', 3, 95000, 'SAR', true, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('47c45868-3ddc-45b6-9384-2e7fb2a922f2', '7cd4f34c-9135-4d64-b358-a81140c321a2', 'nut1', 'شهر واحد', 1, 25000, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('a2aa7564-f959-4d20-88b0-f215afd90226', '73a68580-832d-4773-9bc4-01d01f284c61', 'diy', 'دفعة واحدة', 0, 19900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('75c9a0aa-c982-4c6e-b406-6707eae066b0', '27cbba7c-8041-48ac-8030-736ce4abba4f', 'diyN', 'دفعة واحدة', 0, 25000, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('f564afc1-f4bd-4bc5-8faa-0266b7ee4783', 'e41c03ba-f18d-4e1f-a973-5d063b828b47', 'cN', 'دفعة واحدة', 0, 15000, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('8aef83fc-a26a-47c3-923b-309bc66cb516', '50a92ca8-78b3-485e-a0eb-26e85c270bac', 'cT', 'دفعة واحدة', 0, 18900, 'SAR', true, 0) ON CONFLICT DO NOTHING;



INSERT INTO public.reviews VALUES ('5a69ff51-a718-44d5-b85e-47a4526c9719', 'legacy', NULL, NULL, NULL, NULL, 'اشتركت معها 3 شهور وكانت أول مره التزم بالتمرين بعد سحبات سنين، اسلوبها سهل وسريع بس نتايجه واضحه من اول اسبوعين قياسات جسمي بدت تتغير والكوتش مريحه نفسيًا وشاطرة الله يعطيها العافيه غيرت حياتي واعطتني افضل بداية 🙏🏻', 'first', 'ريم', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 0, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('6048f33a-cb64-46a2-b1d4-05d42df8fc17', 'legacy', NULL, NULL, NULL, 5, 'من أصدق التجارب اللي مرّيت فيها! تدريبك ما كان بس جداول رياضه وتغذية كان دعم نفسي وتحفيز وتغيير حقيقي في حياتي حسّيت بفرق كبير في جسمي وطاقتي وثقتي بنفسي من أول أسبوع شكراً من القلب على تعبك وحرصك على كل تفصيلة وتعطي من قلبك، فعلاً you are the best coach ever تستاهلين كل النجاح والله ❤️', 'first', 'نورة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 1, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('5b94c3ce-cc27-4f4c-b3a3-9f81d50379ab', 'legacy', NULL, NULL, NULL, 5, 'بعد شهر من الالتزام بالجدول، لاحظت فرق واضح! متنوع وفعال، أنصح فيه بشدة 😍👌', 'first', 'البندري', 'مارس 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 2, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('1d919851-e19f-451b-be66-8a7c7e204326', 'legacy', NULL, NULL, NULL, NULL, 'رغم ان فتره تدريبي معاها كانت اقل من شهرين السنه الماضيه الا ان نتايج هالشهرين مستمره معي الى اليوم 😍 اسلوب احترافي وفعال وتركز على بناء وتطوير عادات تدوم مو بس تمارين مؤقته 👍🏻', 'first', 'خديجة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 3, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('2bdce2d4-7c76-4f8b-aafd-231c35627adf', 'legacy', NULL, NULL, NULL, 5, 'كوتش ساره جداً شاطره و بروفيشنال، جداً متعاونه و تعرف شغلها كويس، جداً لطيفه، كنت لفتره متدربه عندها و كنت أشوف نتايج بطله بالاضافه لكوني اروح اتمرن و أنا مستمتعه، شكراً ساره', 'first', 'نجمة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 4, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('fa58c6f1-e176-4506-9894-7c13791ab667', 'legacy', NULL, NULL, NULL, 5, 'ممتاز جدول حلو ومرتب جدا وفرق معي كثير 🤍', 'first', 'سعود', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 5, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('f3490b43-f130-48da-9860-cb5fb76ba0e9', 'legacy', NULL, NULL, NULL, 5, 'كنت اعاني من الم بظهري مستمررر سنوات وانحراف بالعمود ولكن بفضل الله ثم المدربة تحسنت بنسبة كبيرة وتابع معي خطوة بخطوة بكل أمانة وإتقان الله يكثر من امثالك 🤍', 'first', 'ش**س**', 'أغسطس 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 6, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('ba06f51c-2a6d-449e-82fa-6f1feb2de6d8', 'legacy', NULL, NULL, NULL, 5, 'الشكر يعجز عنك يااروع كوتش باشتراكي معك شفت صحة وراحة بعد الله وساعدتيني مره بمشكلة ظهري وضعف العضلات العلوية وانعكس على نفسيتي وادائي اليومي شكررا شكرا من القلب وياحظنا فيك', 'first', 'فاطمة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 7, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('b275665d-7244-4040-8ac5-a5421ff3e933', 'legacy', NULL, NULL, NULL, 5, 'مره استفدت بالتدريب مع كوتش ناف و مبسوطه ان في احد بذمة و ضمير جالس يتابع تقدمي و ينصحني من قلب الله يسعدك ويوفقك ❤️', 'first', 'ميثاء', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 8, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('1e2ed506-1702-42b4-97c7-2f3635d6ef27', 'legacy', NULL, NULL, NULL, 5, 'تجربه ولا أروع ! أحب جداولها وقد ايش تختصر وتعطيك المهم والاهم والنتايج رهيييبه ❤️', 'first', 'أمجاد', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 9, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('2a288650-a5a1-4f41-9a88-e88414139c57', 'legacy', NULL, NULL, NULL, 5, 'افضل مدربة بالمجرة، كنت دبه ونحفت بثلاث شهور بس، i highly recommend her she is the best 💗', 'first', 'شروق', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 10, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('465a60f9-98c9-4764-bb80-b6f48723dcd7', 'legacy', NULL, NULL, NULL, 5, 'الجدول ممتاز و فعّال لفترة الصيام، يساعدك تنظم وقتك ويقدّم توصيات غذائيه و خطه تمارين تساعدك تحافظ على لياقتك بدون إرهاق 👍🏻. خيار ممتاز خاصة للأشخاص للي وقتها محدود ومزحوم فرمضان.', 'first', 'خديجة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 11, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;



INSERT INTO public.site_settings VALUES ('reminders', '{"review_text": "مرحباً {name}، تذكير بمراجعتك الأسبوعية: المراجعة مفتوحة من {window_start} إلى {window_end}.", "sub_expiry_days": [7, 3], "sub_expiry_text": "مرحباً {name}، اشتراكك في {product} ينتهي بتاريخ {end_date}. للتجديد أو الاستفسار تواصل معنا.", "review_lead_days": 1, "missed_review_text": "مرحباً {name}، ما وصلتنا مراجعة الأسبوع المنتهي في {window_end}. متى ما تيسّر لك، حدّثها عشان نتابع تقدمك.", "review_window_days": 2, "manual_cooldown_minutes": 10}', false, NULL, '2026-10-19 13:52:42.295973+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('hero', '{"lead": "تدريب وتغذية مخصصة لهدفك ومستواك، مع مراجعة وتعديل أسبوعي من الكوتش ساره.", "title": "برنامج مبني عليك،", "eyebrow": "Nav Coaching · الكوتش ساره", "tagline": "Where Passion Meets Quality", "title_tail": "مو جدول جاهز"}', true, NULL, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('badges', '["أدرّب منذ 2017", "ماجستير تدريب رياضي · جامعة ستيرلنق", "ضمان استرجاع المبلغ بشروط"]', true, NULL, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('why', '[{"body": "البرنامج يُصمم بعد استبيان مفصل لهدفك وأيامك المتاحة وأدواتك وأي إصابة تحتاج مراعاة.", "title": "مبني على هدفك ومستواك"}, {"body": "مراجعة منتظمة بالفيديو أو الصوت، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.", "title": "متابعة أسبوعية واضحة"}, {"body": "نعدّل التمرين والسعرات بناءً على قياساتك والتزامك، عشان تثبت النتيجة.", "title": "تعديلات حسب تقدمك"}]', true, NULL, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('how_steps', '[{"body": "اختيار الباقة والمدة، ثم استبيان قصير عن الهدف والمستوى والأيام المتاحة وأي إصابة.", "title": "اختيار البرنامج وتعبئة الاستبيان"}, {"body": "بعد الاستبيان يظهر رقم الطلب وبيانات الحساب. التحويل ثم رفع صورة الإيصال من صفحة الطلب.", "title": "تحويل المبلغ"}, {"body": "بعد التحقق من التحويل أتواصل خلال 48 ساعة عمل، ويُسلَّم ملف البرنامج وتبدأ المتابعة.", "title": "استلام البرنامج والبدء"}]', true, NULL, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('about', '{"bio": "مدربة شخصية معتمدة، أدرب منذ 2017. أساعدك تبني روتين تدريب وتغذية واضح يناسب هدفك ووقتك ومستواك، مع متابعة أسبوعية تساعدك تستمر وتتقدم.", "fit": ["كل من يؤمن إن التمرين أسلوب حياة، مو تمرين لشكل مؤقت أو لفترة الصيف بس.", "**وإذا ما صار التزام؟** أحاول أفهم أسبابك، وأساعدك تعالجها بقدر ما أقدر. وإذا كان الموضوع أكبر من اللي أقدر أقدمه، أقولها بصراحة وأعتذر عن تدريبك."], "name": "الكوتش ساره | ناڤ", "certs": ["Saudi Reps — Level 4", "NCSF", "Menno Henselmans CPT", "Functional Mobility", "Pre & Postnatal Training", "Prenatal Fitness Training — Aspire Academy", "ماجستير تدريب رياضي — جامعة ستيرلنق"], "notes": [{"body": "لأني جاية من عالم الرياضات الإلكترونية، صممت باقة خاصة للقيمرز: لياقة أفضل داخل وخارج الشاشة، والتعامل مع آلام الظهر والمفاصل من الجلوس الطويل.", "href": "/programs/gamers", "label": "باقة القيمرز ←", "title": "للاعبي الألعاب الإلكترونية"}, {"body": "تدريب الحوامل عندي حضوري فقط. أونلاين يصعب أتأكد إن التمرين يتنفذ بإتقان، والحمل فترة مهمة جداً تحتاج هالتأكد. أونلاين أقدم للحوامل متابعة التغذية فقط.", "href": "", "label": "", "title": "للحوامل"}], "story": ["قبل ما أصير مدربة، كنت متدربة تعبت من التجارب. اشتركت مع مدربات أجانب، وما لقيت أحد يشرح لي التمرين صح أو يهتم بأهدافي.", "لين اشتركت مع الكوتش سحر الحارثي. غيّرت نظرتي للتمرين، وحفّزتني أصير كوتش، وإلى اليوم أشكرها على كل اللي علمتني إياه. من هنا قررت أكون الشخص اللي احتجته أنا.", "والرياضة جزء مني من بدري: لعبت كرة السلة وكنت كابتن فريق السلة في جامعة الإمام عبدالرحمن بن فيصل، ولعبت باحتراف في الرياضات الإلكترونية. بدأت التدريب في 2017 مع كرة السلة، واشتغلت مساعد مدرب في نادي الجامعة، وبعدها دربت في بيور جم وجمنيشن وفتنس لاونج ونوادي خاصة."], "points": ["برنامج مبني على هدفك ومستواك.", "متابعة أسبوعية واضحة.", "تعديلات مستمرة حسب تقدمك والتزامك."], "pillars": [{"body": "ما أرسل جدول وأترك المتابعة. أراجعه معك بمقطع فيديو أشرح فيه كل شي، عشان تكون البداية بفهم كامل: وش نسوي وليش.", "title": "جدولك مشروح بالفيديو"}, {"body": "ما أمشي على أنظمة الحرمان أبداً. خطتك تناسب حياتك، مو قائمة ممنوعات.", "title": "بدون حرمان"}, {"body": "أتابعك كل أسبوع وأهتم بالتزامك، وأعدّل خطتك حسب تقدمك وظروفك.", "title": "متابعة جادة وخطة واقعية"}, {"body": "حب تعليم الناس معي من الصغر. اللي أعرفه ما أبخل فيه، علمياً ونفسياً، وما أوقف عن البحث والتعلم عشان أتطور وأطورك معي.", "title": "أعلّمك، مو بس أدربك"}], "home_bio": "مدربة شخصية معتمدة، أدرب منذ 2017، وكابتن سابقة لفريق السلة في جامعة الإمام عبدالرحمن بن فيصل. أساعدك تبني روتين تدريب وتغذية واضح يناسب هدفك ووقتك ومستواك، مع متابعة أسبوعية وبدون أنظمة حرمان.", "fit_title": "أكثر شخص أفرق معه", "experience": ["أدرب منذ 2017، والبداية في كرة السلة.", "مساعد مدرب في نادي الجامعة.", "مدربة في بيور جم، وجمنيشن، وفتنس لاونج، ونوادي خاصة."], "story_title": "صرت الشخص اللي كنت أحتاجه", "pillars_title": "وش يميز التدريب معي؟", "experience_title": "شهاداتي وخبرتي"}', true, NULL, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('intro_video', '{"url": "", "body": "مقطع قصير أتكلم فيه عن نفسي وخلفيتي وطريقة شغلي مع المتدربين.", "title": "تعرّف عليّ في دقيقة"}', true, NULL, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('testimonials_disclaimer', '"التجارب شخصية وتختلف النتائج من شخص لآخر حسب الالتزام والحالة، والتدريب لا يغني عن استشارة الطبيب أو أخصائي العلاج الطبيعي."', true, NULL, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('prices_note', '"الأسعار بالريال السعودي. الدفع بتحويل بنكي على حساب المؤسسة."', true, NULL, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('checkins', '{"enabled": true, "questions": [{"q": "ملاحظاتك الصحية؟ الحركة اليومية وجودة الحياة صارت أحسن؟", "topic": "الصحة العامة"}, {"q": "أداؤك في التمارين؟ في تقدم في الأوزان والأداء؟", "topic": "التمارين"}, {"q": "فرق في شكلك ومظهرك؟ إيجابي أو سلبي؟", "topic": "المظهر"}, {"q": "فرق في الملابس أو المقاسات؟ إيجابي أو سلبي؟", "topic": "الملابس"}, {"q": "النظام الغذائي — قدرت تمشي عليه؟ فيه صعوبة؟", "topic": "الغذاء"}, {"q": "تحسّ بالجوع واجد؟ إن وُجد، كم تعطيه من 5؟", "topic": "الجوع"}, {"q": "أي ملاحظات سلبية تبي تشاركها؟ (مهمة أو بسيطة — نتقبل النقد)", "topic": "ملاحظات سلبية"}, {"q": "أي إشكاليات أو ملاحظات إضافية تحتاج مساعدة فيها؟", "topic": "ملاحظات أخرى"}, {"q": "وصلت لأي أسبوع تدريبي الآن؟", "topic": "الأسبوع"}]}', true, NULL, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('contact', '{"tiktok": "https://www.tiktok.com/@navcoaching", "whatsapp": "966599162724", "instagram": "https://www.instagram.com/navvcoaching/"}', true, NULL, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('response_time', '"48 ساعة عمل (الأحد – الخميس، 12 ظهراً – 9 مساءً)"', true, NULL, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('legal', '{"cr": "7050950752", "name": "مؤسسة ناف كوتشنق للتدريب الرياضي"}', true, NULL, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('bank', '{"iban": "SA1280000139608016245411", "bankName": "مصرف الراجحي", "accountName": "مؤسسة ناف كوتشنق للتدريب الرياضي"}', true, NULL, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('program_shots', '[{"h": 720, "w": 754, "alt": "لقطة من صفحة «حسابي» ببيانات مثال: شريط الالتزام، أيام تمرين الأسبوع الحالي، ملخص تغذية اليوم، وروتين المكملات", "src": "shots/my-program.webp", "title": "برنامجي", "caption": "أول ما تدخل حسابك: نسبة التزامك وأسابيعك المتتالية، أيام تمرين الأسبوع، تغذية اليوم مقابل أهدافك، وروتين المكملات."}, {"h": 960, "w": 1148, "alt": "لقطة من صفحة برنامج التمرين ببيانات مثال: أيام الأسبوع، وبطاقة كل تمرين مع المستهدف وخانات الوزن والتكرارات وRIR", "src": "shots/training-log.webp", "title": "تسجيل التمرين", "caption": "لكل تمرين المستهدف من الجولات والتكرارات وRIR، وتسجّل وزنك وتكراراتك من جوالك، ولك تبديله ببديل تختاره المدربة."}, {"h": 1020, "w": 1148, "alt": "لقطة من صفحة التغذية ببيانات مثال: ملخص اليوم مقابل الأهداف، ونموذج إضافة أكلة، وأكل اليوم حسب الوجبات", "src": "shots/nutrition-day.webp", "title": "التغذية اليومية", "caption": "أهدافك اليومية من السعرات والماكروز وكم باقي لك، وتسجّل أكلك من جداولك الغذائية أو بالغرام من قاعدة الأكل."}, {"h": 307, "w": 1116, "alt": "لقطة من لوحة التقدم ببيانات مثال: رسم الوزن ورسم القياسات", "src": "shots/progress-charts.webp", "title": "لوحة التقدم", "caption": "وزنك وقياساتك برسوم واضحة أسبوعاً بأسبوع، ببيانات مثال."}]', true, NULL, '2026-10-19 13:52:42.775264+00') ON CONFLICT DO NOTHING;
COMMIT;
