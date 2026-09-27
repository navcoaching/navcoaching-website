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

-- ---------- المحتوى المستورد من الموقع الحالي ----------
INSERT INTO public.exercises VALUES ('f4cd39db-0991-4468-b6ad-d3b6e9c11626', 'Back Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/bEv6CCg2BC8', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('66f0d0dd-c865-4bc1-b512-c66cdfe3ff10', 'Box Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtube.com/shorts/9uhEh9gpwUU?si=xaTY7AJiCeQfa3by', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل.', 'تعليمات بديلة في المصدر (صف 13): ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل، انزل واثبت على البوكس ثانية وارفع.', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f9a2a3f4-60e9-46a3-937e-6d70c721acb0', 'Hack Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/0tn5K9NlCfo', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Machine Squat / سكوات بالجهاز', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fe06a0a7-5b1c-4be8-9645-446fb327c25e', 'Mid Leg Press', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/s9-zeWzPUmA', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Leg Press / ضغط الأرجل', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a6039c53-2818-44e6-95c3-9346f93f3d47', 'Quads Leg Press', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/A218isnErfM', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي، ثبت القدمين أسفل اللوح لاستهداف أكبر للكوادز.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Leg Press / ضغط الأرجل', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d3f8d53c-0e8f-4bd8-ad7c-a5aff9925fc9', 'Deficit Goblet Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/9719SO5zvpU?si=whohbunAsXkH3j6f', 'وقف باتساع اكتافك تقريبًا، ادفع ركبك للامام وانزل، انزل لأقصى حد تقدر عليه بدون ما يتقوس ظهرك السفلي.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('861c687e-6cab-45dd-84b4-5145ce710774', 'Front Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'بار', 'متوسط', 'نادي', NULL, 'ثبت البار على الأكتاف، ادفع ركبك للامام وانزل.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3f76e849-a6eb-4c3e-ab54-a2b69869b301', 'V Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://www.youtube.com/watch?v=u_GSjH58s0g', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Machine Squat / سكوات بالجهاز', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('dfe1b612-41d3-4234-8b02-09044fee017a', 'Resistance Band Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/6rE0IYlMPZA?si=goqtRTlR_W4HSGBN', 'ثبت الباند علي جوانب اكتافك، ادفع ركبك للأمام وإنزل.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3f829839-965b-4ade-8191-c2691a7ff616', 'Squat Smith Machine', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/oBwhrRcNWyM', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Machine Squat / سكوات بالجهاز', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('38bf1318-fb87-40fc-a7b4-637dfe3918c9', 'Single Leg Press', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/ZYDTJaAM-gE', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Single-leg Press / ضغط رجل واحدة', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('56b0e22f-7935-48e8-b7d0-68c2e0b6dd4c', 'Drop Lunges', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/WH8lteLrMIs?si=61QSVA7iw_Z6Zr3p', 'تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b9f13d94-0932-4f90-aebe-f247951b3879', 'Beginner Lunges', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/QOVaHwm-Q6U', 'تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2045070a-7609-4fe3-99b5-313ffe4d22ff', 'Forward Lunges', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/_DLAdo2Pvjs', 'تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness | ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2319325a-b5a8-4ce3-8a50-5056cb7683bc', 'Supported BSS', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/poBie3TTeGE?si=QSiMUYtcHhrmg8mx', 'وقف عند البنش او الستيب، ارفع رجلك وثبت اصابع قدمك على البنش، خذ خطوة وحدة للأمام برجلك الثانية ثم ابدأ التمرين، تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Split Squat / سبليت سكوات', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cd86eb8c-15b1-4e0f-9d55-ce514145afc4', 'Supported Reverse Lunge', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/WH8lteLrMIs?si=M9s9a7qOVvvyDm82', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('501fe070-caed-4d03-a38b-b4ed054b70ed', 'Smith Machine Reverse Lunge', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/zAVYcwnlxrQ?si=M5HL4sG-bsYBFyDQ', 'استخدم ارتفاع بسيط مثل الستيب ، ارفع نفسك بالضغط علي الرجل المرفوعة بتحكم بدون قفز.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('36189c40-8bbf-465d-b997-2c20bc77fee8', 'Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/gtZ4AwZVtMI', 'اجلس وثبت ظهرك السفلي كويس، تأكد ان مسمار الارتفاع يكون بمستوى ركبتك، امسك المقابض لزيادة الثبات، إرفع الوزن اثبت ثانية فوق ثم انزل نزول كامل بتحكم.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('79063b15-b2ac-4843-91cb-35f1f2a21936', 'Single Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/82IuSLk5zNc?si=FTMqZrmawQFRr8dN', 'اجلس وثبت ظهرك السفلي كويس، تأكد ان مسمار الارتفاع يكون بمستوى ركبتك، امسك المقابض لزيادة الثبات، إرفع الوزن اثبت ثانية فوق ثم انزل نزول كامل بتحكم.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6486840a-5d59-40a2-b838-7e991e2a22c0', 'Band Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/hs7D3gDw3UM', 'اجلس وثبت ظهرك السفلي كويس وامسك الكرسي للثبات، اثبت ثانية فوق ثم انزل نزول كامل بتحكم.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('71be87fc-cc76-43fd-a6ac-306ac664d21d', 'Standing Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/fyF6FQOUGDI', 'الحركة كلها بثني ومد الركبة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0e2555a5-d883-42a4-8383-bae310510ea5', 'Sissy Squat', 'Quadriceps / الأمامية', '{"Adductors / الأفخاذ الداخلية"}', 'Knee Extension / مد الركبة', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://youtu.be/yONKTprKCDA', 'الورك ثابت طول الجولة والحركة كلها من مفصل الركبة، اذا توازنك يخرب عليك ادبل الوزن بيد واليد الثانية امسك فيها جدار او عصى', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Sissy Squat / سيسي سكوات', 'Knee Extension / مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b5fc501c-260e-466f-a384-8369279c8312', 'Cable Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/ebjD98gZd8E', 'اجلس وثبت ظهرك السفلي كويس وامسك الكرسي للثبات، اثبت ثانية فوق ثم انزل نزول كامل بتحكم.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7af621d7-1a02-4991-bd62-c8109d116440', 'Standing Leg Extension', 'Quadriceps / الأمامية', '{"Core / البطن والكور"}', 'Knee Extension / مد الركبة', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/133/standing-leg-extension/', NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d74cb6a0-29d3-4ca1-bc2c-1fdd331795cc', 'Bodyweight Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Lower back / أسفل الظهر"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/135/bodyweight-squat/', NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('46c20362-96a4-4bed-a4ac-b244090e4765', 'Single Leg Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'وزن الجسم', 'متقدم', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/136/single-leg-squat/', 'ضعف الألوية الكبرى / Gluteus Maximus Weakness | ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Single-leg Squat / سكوات رجل واحدة', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('463a9a8c-ac07-4935-a02c-febf8ca48a61', 'DB Glutes Step Ups', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/GCnJiYJfboA?feature=share', 'استخدم ارتفاع يكون بحدود ارتفاع ركبتك أو أقل، ارفع نفسك بالضغط علي الرجل المرفوعة بتحكم بدون قفز.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('186ce481-4474-4657-90a2-b94c5f575b78', 'Supported Glutes Step Ups', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/ZKzoOkQALaY?si=-56txwBlxSSCQYJd', 'استخدم ارتفاع يكون بحدود ارتفاع ركبتك أو أقل، ارفع نفسك بالضغط علي الرجل المرفوعة بتحكم بدون قفز.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ffe653fe-250c-414b-a93d-a6e0a3aa2d9b', 'Cable Glutes Step Ups', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a85255fe-1453-4159-817c-50b747e6fce2', 'Glute Pushdown', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/8h2kZ64Sp5k?si=NLPf4tywxhDGY9em', 'تمسك بمقابض الجهاز، (كل ما زاد ارتفاع البنش زادت الصعوبة) + الطلوع والنزول يكون بواسطة القدم المرفوعة على البنش مو بالقدم اللي تحت، ارفع بتحكم الى أقصى ارتفاع تقدرعليه بدون ما يتقوس ظهرك السفلي، انزل لحد ما تقفل ركبتك تماما', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f6f5eb4b-4dfc-477c-84b2-8ecdbcd793eb', 'Glute Max Kickbacks', 'Glutes / المؤخرة', '{}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/t5mwSx4uNMc?feature=share', 'ثبت الحبل على الكاحل، ارجع خطوة للخلف وانحني للامام قليلاً وتمسك بالكيبل لزيادة الثبات، اسحب للخلف مع انثناء بسيط بالركب.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Kickback / ركلة خلفية', 'Hip Extension / بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7912eeca-7e8c-49e0-83b9-a70134824b1c', 'Hip Abduction', 'Abductors / مبعدات الفخذ', '{"Glutes / المؤخرة"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/_ARUxqrII3Y?si=Jcz5uh2Uu-IdVCS1', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('608011f9-82e5-47ef-ab8b-d19d91af3ff1', 'Smith Machine Kickback', 'Glutes / المؤخرة', '{}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/GR4ny80bmhM?si=WeZcWM1hyfoLElM2', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Kickback / ركلة خلفية', 'Hip Extension / بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('369b3080-a974-4a86-8ed0-e7cc0b200cf1', 'Glute Medius Kickbacks', 'Abductors / مبعدات الفخذ', '{"Glutes / المؤخرة"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/kccsnZNbMFA?si=6c-VoB8Zsz8NxoyM', 'ثبت الحبل على الكاحل، ارجع خطوة للخلف وانحني للامام قليلاً وتمسك بالكيبل لزيادة الثبات، اسحب للخلف وللخارج مع انثناء بسيط بالركب.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Abduction Kickback / ركلة خلفية مع تبعيد', 'Hip Abduction + Hip Extension / تبعيد الورك + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('38797c04-f268-4837-884b-1177dc3771ee', 'Side Step Up', 'Glutes / المؤخرة', '{"Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/xOwIRnI4VxA?si=SJOgODRmNGdfHPb4', 'يد فيها الوزن واليد الثانية سندها على الجدار', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية المتوسطة / Gluteus Medius Weakness | ضعف الألوية الصغرى / Gluteus Minimus Weakness', 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('bb61c189-4aa5-40ba-b3a1-a96c9dfbb33b', 'Hip Thrusts Machine', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/0xfdeCBwoYw?si=HgJcNeB0a24gODkK', 'ممكن تسويه بالسميث مشين او البار الحر ، اختر بوكس او بنش يكون بمستوى اكتافك الخلفية وانت جالس، لما ترفع البار فوق المفروض ركبك تكون بنفس مستوى القدم.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5dd8e92a-2509-4744-8e2b-c0805b45a17f', 'Hip Thrusts', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/O0EoaP7gR1A?si=cGPZ8iIwM2mQjwSb', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('609b2b48-2196-4c38-9f2d-b19e41999946', 'Glute Bridge', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', NULL, 'مبتدئ', NULL, 'https://www.youtube.com/watch?v=dtlGynVdHYM', 'ممكن تسويه بالسميث مشين او البار الحر ، اختر بوكس او بنش يكون بمستوى اكتافك الخلفية وانت جالس، لما ترفع البار فوق المفروض ركبك تكون بنفس مستوى القدم.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness | آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ad189d52-5b53-44de-8544-8be52393cd57', 'DB Floor Glute Bridge', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/iOrJXNUH3to?si=JySX6JMhoP2vWEVa', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness', 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fb6a5d97-170a-4251-898b-c3ba9816f49c', 'Glute Raise', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/X_kL_x4m77c', 'ثبت رجولك تحت، الاسفنجة تكون تحت الورك أعلى الفخذ مو على الورك مباشرة، امسك وزن بيدينك بذراع مستقيمة، ارفع وكأنك تبي تدخل القلوتس جوا الاسفنجة، بمجرد ما تنقبض مؤخرتك وقف لا ترفع أكثر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', '45° Hip Extension / بسط الورك على جهاز الظهر', 'Hip Extension / بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4e12965f-01b2-4de4-bafe-851903f414f0', 'Single Hip Thrusts', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/ymg2AMDAwrY?si=fY8kBPTDYWRMHuAs', 'اختر بوكس او بنش يكون بمستوى اكتافك الخلفية وانت جالس، لما ترفع فوق المفروض ركبك تكون بنفس مستوى القدم، التمرين صعب طبيعي تواجه صعوبة بالبداية لذلك لا تستعجل باضافة الاوزان', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('52a68e9d-d224-47be-b7f8-5ae4221e927c', 'Glute Press', 'Glutes / المؤخرة', '{}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/293/glute-press/', NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Kickback / ركلة خلفية', 'Hip Extension + Knee Extension / بسط الورك + مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f337ca91-83b6-4c1d-ac12-12c2e87b8896', 'Bulgarian Split Squat', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/366/bulgarian-split-squat/', NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Split Squat / سبليت سكوات', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6df478d8-18d0-4ff6-9eee-5b878e38fdac', 'Sumo Deadlift', 'Hamstrings / الخلفية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://www.youtube.com/watch?v=cDlOSfu-zHY', 'وقف بفتحة أرجل واسعة بحيث الركب تكون خط مستقيم مع كعب القدم و اصابع الرجل باتجاه الخارج، البار بمنتصف القدم، شد ظهرك العلوي وادفع الارض برجولك واسحب البار للأعلى، وقف لما تنقبض مؤخرتك ولا تبالغ بتقفيل حوضك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Deadlift / ديدلفت', 'Hip Extension + Knee Extension / بسط الورك + مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fbe2da22-974d-44a8-87f4-2eb2ae1869c7', 'DB Lying Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/ZHlBSI6JPsA?si=SpBiHxluwrYE8CTP', 'ركبك ثابته على الارض، ارفع الوزن بثني ومد الركبة بدون ما يرتفع حوضك', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('90cb2eb1-4578-40a2-9c67-853c4016c022', 'Conventional Deadlift', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/GxsLrTzyGUU', 'وقف باتساع اكتافك أو أوسع شوي، البار بمنتصف القدم، شد ظهرك العلوي وادفع الارض برجولك واسحب البار للأعلى، وقف لما تنقبض مؤخرتك ولا تبالغ بتقفيل حوضك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Deadlift / ديدلفت', 'Hip Extension + Knee Extension / بسط الورك + مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0121ae9b-726f-42a2-b6e6-23fbe940e162', 'BB RDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/mZxxJEncsyw', 'وقف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، انزل وادفع مؤخرتك لآخر شي تقدر عليه للخلف وكأنك بتلمس جدار خلفك مع انثناء بسيط بالركب', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('80fd829b-8d60-4f8a-8615-8b883f09eedf', 'DB RDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/RApyTtH6qAo', 'وقف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، انزل وادفع مؤخرتك لآخر شي تقدر عليه للخلف وكأنك بتلمس جدار خلفك مع انثناء بسيط بالركب', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('66d3bab4-78e2-4b64-a050-bf9f7b866c48', 'SM SLDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/qlL1wnpLQj4?si=-jD_X6mIJkkI8SwX', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('bf9955b5-a4ef-44b8-8e31-a36f2117953c', 'Single DB RDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/U3prDlAbJDw?si=MRSBcSIcf9M-WQBH', 'وقف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، انزل وادفع مؤخرتك لآخر شي تقدر عليه للخلف وكأنك بتلمس جدار خلفك مع انثناء بسيط بالركب', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness', 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1ffc7539-1c58-4bcc-91b2-73ceecae84f6', 'SLDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/RApyTtH6qAo', 'قف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، ابدأ الحركة بدفع مؤخرتك للخلف والأعلى وانزل', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ff1cdeda-5be9-48cc-abfa-a11506c50aa1', 'Single DB SLDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/U3prDlAbJDw?si=MRSBcSIcf9M-WQBH', 'قف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، ابدأ الحركة بدفع مؤخرتك للخلف والأعلى وانزل', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3d295c94-59db-4717-98ee-a18f1e4c03b1', 'Good Morning', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/f23vXjoG2e8?si=9rkfUF_6XUEcQ3Xs', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع مؤخرتك لأقصى قدر تقدر عليه وكأنك بتلمس جدار خلفك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Good Morning / قود مورنينق', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('39e10252-78e1-49e9-b249-8cd4a9e9b481', 'Seated Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/o_J6MWyt5jM', 'اجلس على الكرسي وثبت ظهرك السفلي على المقعد تمامًا، انزل لأقصى حد تقدر عليه وارفع لحد ما تستقيم ركبتك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e0873193-0059-4fd8-aeba-19b4ad084dd2', 'Band Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/I-HTMUrJnxs', 'ثبت الباند فوق الكعب، اجلس على طرف البنش وتمسك بيدينك لزيادة الثبات، اسحب الحبل لاقصى حد تقدر عليه واترك رجلك تستقيم تمامًا في الانبساط.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cec4e075-5a93-4dc5-b98a-fde7ce46eb30', 'Lying Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/vl5nUdE9mWM', 'حوضك ثابت على البنش، ارفع الوزن بثني ومد الركبة بدون ما يرتفع حوضك عن الكرسي', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e2dc9ef0-edb5-47af-a3d3-595d88f98b14', 'Cable Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/mBJXWg8ZOy0', 'اجلس على الكرسي وثبت ظهرك السفلي على المقعد تمامًا، ممكن تقدّم ظهرك العلوي وتمسك المقابض لزيادة الثبات، انزل لأقصى حد تقدر عليه وارفع لحد ما تستقيم ركبتك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5a40b6e0-d66a-4220-a411-c6ec717955dd', 'Supine Cable Hamstring Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/sDCc1F5J8XA?si=Fi3D39aJogrB5ihd', 'الركبة ثبت مكانها، اسحب الحبل لاقصى حد تقدر عليه واترك رجلك تستقيم تمامًا في الانبساط.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d77ae08b-8e56-4e53-a839-ba52ca9a589b', 'Nordic Hamstring Curl', 'Hamstrings / الخلفية', '{}', 'Knee Flexion / ثني الركبة', 'قوة', 'وزن الجسم', 'متقدم', 'بدون معدات', 'https://youtu.be/Lgibr8od0yA?si=nfRetEkDRk55Bu0a', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Nordic (Eccentric) / نوردك (لامركزي)', 'Knee Flexion / ثني الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2f2f1c9d-f6c9-40fb-ab9d-eb2e42d2351e', 'Stability Ball Hamstring Curl', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة"}', 'Knee Flexion / ثني الركبة', 'قوة', 'كرة سويسرية', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/59/stability-ball-hamstring-curl/', NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Bridge Curl / ثني الركبة مع رفع الورك', 'Knee Flexion + Hip Extension / ثني الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3bcaf688-1aee-416f-bcd5-62010321a652', 'Hip Hinge', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/33/hip-hinge/', NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Hinge Drill / تمرين مفصلة الورك', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('50a0e624-b48e-4a1f-bb0f-a06b5fd5ec4c', 'TRX Hamstrings Curl', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة"}', 'Knee Flexion / ثني الركبة', 'قوة', 'TRX', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/86/trx-reg-hamstrings-curl/', NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Bridge Curl / ثني الركبة مع رفع الورك', 'Knee Flexion + Hip Extension / ثني الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('70bfb7df-7fb6-4f33-936c-228f89427161', 'Flat DB Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/xphvjGDZeYE', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0ceb1310-a66b-4372-ba3f-ed6460911784', 'DB Floor Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/UBmpZ7l5Nlk?si=kDcN-ueaTFxfKtbr', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('df035e48-d887-4833-b5f0-816c6cefe488', 'Flat Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/vcBig73ojpE', 'استلق على بنش،القبضة بنفس مستوى الاكتاف أو أوسع قليلًا، قوّس ظهرك العلوي قليلاً، انزل لين تلمس صدرك واثبت ثانية ثم ارفع.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('51938cc6-a925-4c3c-b770-591527f607f9', 'Machine Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/pOCRC2kpxB8?si=02xGtrfPjiYpspMv', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('586a44f6-4219-48b0-9875-219f4018e447', 'Feet Up Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/HrehfM1dmBE', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2a36dd8d-183a-494c-ae38-bc04647f7bb2', 'Torso Elevated Push Up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/noaPB7u4_CU', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا', 'تصنيف فرعي: اليدان مرفوعتان؛ زاوية الضغط بالنسبة للجذع تشبه الضغط المائل لأسفل رغم تسميته الشائعة Incline Push-up — يحدده المدرب', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Decline Press / ضغط مائل لأسفل', 'Horizontal Adduction + Shoulder Extension / تقريب أفقي + مد الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c6e6bdbc-12aa-4600-bb6b-2ad072e25d6f', 'Push Up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://youtu.be/WDIpL0pjun0?si=utydS_A8QfRIJtJm', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('84089b63-30d4-453b-84d9-cb6654a5dbc4', 'Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://www.youtube.com/watch?v=JvOJdUtx6UQ', 'استلق على بنش،القبضة بنفس مستوى الاكتاف أو أوسع قليلًا، قوّس ظهرك العلوي قليلاً، انزل لين تلمس صدرك واثبت ثانية ثم ارفع.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3448c18f-dce9-4937-83c0-3ebd52f601b3', 'Paused Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://www.youtube.com/shorts/Q3GmnmJISwE', 'استلق على بنش،القبضة بنفس مستوى الاكتاف أو أوسع قليلًا، قوّس ظهرك العلوي قليلاً، انزل لين تلمس صدرك واثبت 3 ثواني ثم ارفع.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f888ac34-e35a-420b-a616-93f4c2b08822', 'Incline Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/0G2_XV7slIg', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Incline Press / ضغط مائل لأعلى', 'Shoulder Flexion + Horizontal Adduction / ثني الكتف + تقريب أفقي', 'Incline Press / ضغط مائل لأعلى') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d3bd2143-66a5-4f40-baa6-55ec7be87f50', 'Smith Machine Incline Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/EeLLZMdg6zI?si=UVsgFN7jhXMm0vW3', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Incline Press / ضغط مائل لأعلى', 'Shoulder Flexion + Horizontal Adduction / ثني الكتف + تقريب أفقي', 'Incline Press / ضغط مائل لأعلى') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2d5fe2c4-636c-44de-96fd-f47488224a32', 'Cable Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/tAILewhtCb0', 'اجلس على بنش انكلاين، اضبط الكيبل بمستوى صدرك تقريبا، ادفع الوزن للأمام باتجاه الداخل، احرص ان كوعك ما يكون بنفس ارتفاع كتفك', 'تصنيف فرعي: التعليمات تذكر بنش انكلاين، وتصنيف المصدر iso_push_chest — يُحسم بين Incline Press وعزل الصدر', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Incline Press / ضغط مائل لأعلى', 'Shoulder Flexion + Horizontal Adduction / ثني الكتف + تقريب أفقي', 'Incline Press / ضغط مائل لأعلى') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2d7ee715-48f0-4c9e-bee9-a04bdfe0ba6a', 'Sternal Cable Press Around', 'Chest / الصدر', '{}', 'Horizontal Push / دفع أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/y8XQibXDnNo', 'اضبط الكيبل بمستوى صدرك تقريبا، حافظ على ذراعك قريبة من جسمك،ادفع الحبل للأمام باتجاه الداخل.', 'تصنيف فرعي: حركة مختلطة بين الضغط والـ Fly — يُحسم بين Flat Press وعزل الصدر', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Press-around / ضغط مع تقريب', 'Horizontal Adduction + Elbow Extension / تقريب أفقي + مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6a7d269f-8122-4262-b81c-8f8f1a299faf', 'Machine Chest Fly', 'Chest / الصدر', '{}', 'Horizontal Adduction (Fly) / تقريب أفقي للكتف (فلاي)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Chest Isolation / عزل الصدر', 'Horizontal Adduction / تقريب أفقي للكتف', 'Chest Isolation / عزل الصدر') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('973b0498-1000-4011-9bb1-c71d8964f6a7', 'Bar Cable Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/NhD3h6RG2TA?si=SoyNTIGB-nY2KiXl', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4c2727b3-650d-42c8-8eeb-bd27bcbd8cbb', 'Cable Chest Fly', 'Chest / الصدر', '{"Shoulders / الأكتاف"}', 'Horizontal Adduction (Fly) / تقريب أفقي للكتف (فلاي)', 'قوة', 'كيبل', 'مبتدئ', 'نادي', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/160/standing-chest-fly/', NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Chest Isolation / عزل الصدر', 'Horizontal Adduction / تقريب أفقي للكتف', 'Chest Isolation / عزل الصدر') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d0c9678b-3e0f-4e7c-8840-80ecd490dd3e', 'Bent Knee Push-up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/13/bent-knee-push-up/', NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f030a6bb-a478-403e-bd6d-fca0063cdc0c', 'Stability Ball Push-Up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس","Core / البطن والكور"}', 'Horizontal Push / دفع أفقي', 'قوة', 'كرة سويسرية', 'متوسط', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف فرعي: الزاوية تعتمد على موضع الكرة (تحت اليدين أو القدمين) — غير محدد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/63/stability-ball-push-up/', NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f415690e-17d7-431e-834d-ea26bf6040d4', 'Cable Reardelt Rows', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/uIdXVGjcfFE', 'ثبت نفسك بالكرسي، فتحة واسعة، الكيبل بمستوى اسفل صدرك، واسحب لما تنقبض اكتافك الخلفية.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Wide-grip Row / تجديف بقبضة واسعة', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9ebbe40d-0597-49aa-9529-38657204588c', 'Upper Back Horizontal Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/TSWohpfMlso', 'ثبت نفسك بالكرسي، فتحة واسعة، الكيبل بمستوى أعلى صدرك، واسحب لما تنقبض الترابز.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness', 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Wide-grip Row / تجديف بقبضة واسعة', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('86bdd100-6cd3-432c-bff2-7f4cf8a54795', 'DB Chest Supported Reardelt Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/x0v6GWYzI18?si=-jDt3D-ARIHouHjp', 'ثبت صدرك على الكرسي، فتحة واسعة، واسحب لما تنقبض اكتافك الخلفية.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Wide-grip Row / تجديف بقبضة واسعة', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c7d13b11-e9ea-4932-a3c9-190de5337daa', 'Bent-over Barbell Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'بار', 'متوسط', 'نادي', NULL, 'ادفع مؤخرتك للخلف واثني ركبك، قبضتك بنفس مستوى اكتافك، اسحب لما تنقبض عضلات الظهر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('76356866-3fa5-4f6a-97d3-ae94cea75eb3', 'Cable Reardelt Fly', 'Shoulders / الأكتاف', '{"Rotator cuffs / الكفة المدورة"}', 'Shoulder Rear Pull / سحب خلفي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/bkejPHrPkmA?si=-O8q_5e72udoPRiY', NULL, 'تصنيف فرعي: حركة Fly (تبعيد أفقي للكتف) وليست سحباً أفقياً أو عمودياً', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Rear Delt Fly / فتح خلفي', 'Horizontal Abduction / تبعيد أفقي للكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4fa60160-a11f-436c-a11c-dc2de1318142', 'DB Chest Supported Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/H75im9fAUMc', 'ثبت صدرك على الكرسي، فتحة واسعة، واسحب الدمبل باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ae7d002c-4077-4e0a-b842-d6c4435e04d3', 'Head Supported Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/c6lkPMhuyFA?si=eUivRGYSi0W7PmVe', 'راسك ثابت على البنش بدون أي ميلان بالرقبة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('026279a4-e80e-4378-b8ad-e6cd58900af4', 'Single Arm Dumbbell Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/QBjaGx8mS1o', 'اسحب باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f53efd70-955a-4a39-8b80-7fe9bc531c8a', 'Single Arm Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/Qn_mHGObb8E?si=IZ0q9_tseiRIMtcs', 'اسحب باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a2119abd-555e-4f27-b509-aa8212405611', 'Seated Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/0G3W83dFUeY', 'اسحب باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness | تحدب الظهر / Postural Thoracic Kyphosis', 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d4accc26-ddcd-4bfb-b141-f24bdfb2e503', 'Band Seated Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/Jy-WCFAofBY?si=9gqVby588rk1zFi9', 'فتحة واسعة، واسحب لما تنقبض عضلات الظهر.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness | تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture', 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4dd9656c-ea67-4f9a-b3e0-b5a37a8b85de', 'Chest Supported Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/DgHtyrQEMJ4?si=oTfTKVgD9j1H12wA', 'ثبت صدرك على الكرسي، فتحة واسعة، واسحب لما تنقبض عضلات الظهر.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness', 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('656f14bb-921d-4775-ade6-70e408adcecf', 'Chest Supported Machine Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/BZrdEAiR2Xs?si=WhKaSGhR0gKeeies', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a109ae7f-2ca1-41e3-980f-18ed97b2d87c', 'T-Bar Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/6OtcNinT0HM?si=UPfYyypfZCaN9tTA', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ec467b59-368a-4bc4-b873-74596a085f47', 'Lats Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/CQkT-W18N5g', 'الكيبل بنفس مستوى بطنك، اسحب باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Lat-focused Row / تجديف لاتس', 'Shoulder Extension / مد الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1e27de44-887f-40a7-a123-47f19cfcd868', 'Upperback Pulldowns', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/bNmvKpJSWKM?si=hy5HgBDAHkzFHcvv', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Wide-grip Pulldown / سحب علوي بقبضة واسعة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('620fdf9b-7dc6-4968-8b42-0878c8c889ad', 'Straight Arm Pulldown', 'Back & Lats / الظهر واللاتس', '{}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/hAMcfubonDc?si=ocU_a8VQ4VzZnTg3', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Straight-arm Pull / سحب بذراع مستقيمة', 'Shoulder Extension + Scapular Depression / مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d5d6b7d3-2d56-4db0-aca0-3543c119911a', 'DB Pullover', 'Back & Lats / الظهر واللاتس', '{"Chest / الصدر","Triceps / الترايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/ieFKuQAGYIA?si=uwqyrbKhBL6Id3_-', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Straight-arm Pull / سحب بذراع مستقيمة', 'Shoulder Extension + Scapular Depression / مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6bbd8401-9a32-4b9a-85e5-1d0c4c870288', 'Band Lat Pulldown', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/5R0RYj3Y9Ro', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d798681b-5dce-4270-853d-5b13da979595', 'Band Assisted Pull Ups', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://youtu.be/Ks8ah-8P1b0', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('369f656a-9772-4d4e-a533-e5978e220941', 'Pull Ups', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متقدم', 'نادي', 'https://youtu.be/x3NPAxiMRPw?si=Mwg6U1Df5aIFpjKB', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2366ca86-c838-42b7-baea-0456952f73c2', 'Negative Pull-Up', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://youtu.be/gbPURTSxQLY?si=TvQF5zDWfU_rR1Ax', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر، نزول بطيء.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('65fab8f1-a21f-4db5-931c-0f31f5a3ee62', 'Neutral Grip Lat Pulldown', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/kVB6SlEyjQM', 'القبضة بنفس مستوى الكتف، اسحب باتجاه اعلى الصدر.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('80349409-5b48-483f-9cbe-936d552ea595', 'Single Lats Pulldown', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/Qed5O9toqT8', 'اجلس على بنش واسند صدرك عليه، ارجع للخلف قليلا بحيث ان الكيبل ما يكون فوق راسك مباشرة، اسحب الكوع باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e1445303-174b-4510-848b-325d96e00e34', 'Band Assisted Chin Ups', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://youtu.be/i0yC-0YK6Uk?si=gNX26kIFz_THnR4p', 'مسكة ضيقة بمستوى الأكتاف، كل ما كان الحبل خفيف زادت المقاومة وزدات صعوبة التمرين لذلك ابدأ بحبل ثقيل وخفف كل ما تحسن مستواك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8e55cb37-1421-45a5-bf37-22582bc35800', 'Chin Ups', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متقدم', 'نادي', 'https://youtube.com/shorts/aV9Mz9nCsMw?si=E_ullJojGO_7srW2', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3900b9b4-75f3-4a5e-8956-6e76df418eca', 'Kneeling Lat Pulldown', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', NULL, 'متوسط', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/35/kneeling-lat-pulldown/', NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f3d13923-e29e-4534-8823-6927c386822c', 'TRX Back Row', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس","Core / البطن والكور","Lower back / أسفل الظهر"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'TRX', 'متوسط', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/84/trx-reg-back-row/', NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('168a9d86-467d-4e7c-8ea5-488218141349', 'Shrug', 'Back & Lats / الظهر واللاتس', '{"Trapezius / الترابيس"}', 'Scapular Elevation / رفع لوح الكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف فرعي: رفع الأكتاف (Shrug) ليس نمط سحب أفقي أو عمودي', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/72/shrug/', NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Shrug / هز الكتفين', 'Scapular Elevation / رفع لوح الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f63b1de7-621a-44d9-9e2d-6fcd83395dd0', 'DB Shoulder Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/NKeyUrDYqPk', 'قوّس ظهرك العلوي قليلاً، الكوع قريب من الجسم، النزول الى مستوى الاكتاف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('94ab28eb-f6ac-4a65-a59f-281fa30dc92d', 'DB Standing Shoulder Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/wO0l5jW2NtQ?si=MVvS4F_7iFS8ji9R', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cd3e4811-b696-4790-a273-6b23ba30ea51', 'Machine Shoulder Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/3R14MnZbcpw', 'قوّس ظهرك العلوي قليلاً، الكوع قريب من الجسم، النزول الى مستوى الاكتاف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('97bfef6c-b7c8-419d-ba64-aeacb2ce4540', 'BB Overhead Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/_RlRDWO2jfg', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6dbd4c70-48dd-46be-ac30-cc329f4e2b72', 'DB Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/qqntiuPmLDM?feature=share', 'انحني للأمام قليلًا، ارفع للأعلى الى أن تصل لمستوى الأكتاف.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c36e10c8-4ef9-4997-96e5-ce20b1affa52', 'Seated Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/v7fwGurZ9SU?feature=share', 'انحني للأمام قليلًا، ارفع للأعلى الى أن تصل لمستوى الأكتاف.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b173bd10-0145-4c62-a0f1-48e7f10de33a', 'Lateral Raise Machine', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/d0pRsZ9SY5w?si=XuXb_Ti0Flow7qvW', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('279be5b5-370e-4239-b48c-a9551f35bd45', 'Cable Crossover Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/wKgCc5UQjoU?si=zsaz3i31PnEU9A43', 'الكيبل يبدأ من الأسفل، انحني للأمام قليلًا، ارفع للأعلى وتحكم بالنزول.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7ca755e3-6b63-4a35-b2a2-a7151c7677fa', 'DB Y Raises', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/lXp16YozXgk', 'ثبت صدرك على البنش،ارفع الوزن على شكل Y.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Y Raise (Scaption) / رفع Y بمستوى لوح الكتف', 'Shoulder Elevation in Scapular Plane (Scaption) / رفع الذراع بمستوى لوح الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7270de5c-0322-4e59-b8d2-81999f01cba4', 'Cable Y Raises', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/P7u6PEeOn6Q?feature=share', 'الكيبل يبدأ من تحت،ارفع الوزن على شكل Y.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Y Raise (Scaption) / رفع Y بمستوى لوح الكتف', 'Shoulder Elevation in Scapular Plane (Scaption) / رفع الذراع بمستوى لوح الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f7ca5914-c7bb-43e9-beeb-39529ac19ca9', 'Single Arm DB Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/Jm6GqVhWhNY', 'انحني للأمام قليلًا، ارفع للأعلى الى أن تصل لمستوى الأكتاف.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('dddb7a49-e98b-45ce-9f0b-02b50ad7ea4d', 'Single Arm Cable Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/J-6uEOkYAKM', 'الكيبل يبدأ من الأسفل، انحني للأمام قليلًا، ارفع للأعلى وتحكم بالنزول.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0b91ef46-bad9-4122-8450-bce18fa47d28', 'Front Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Front Raise / رفع أمامي للكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/54/front-raise/', NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Front Raise / رفع أمامي', 'Shoulder Flexion / ثني الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5c631ac6-9b41-401b-9cac-3913fa9ba3d7', 'Diagonal Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/371/diagonal-raise/', NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Diagonal Raise / رفع قطري', 'Shoulder Flexion + Abduction (Diagonal) / ثني وتبعيد الكتف (قطري)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e371b332-8d42-4605-9301-8b930665d01b', 'High Row', 'Shoulders / الأكتاف', '{}', 'Shoulder Rear Pull / سحب خلفي للكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/336/high-row/', NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'High Row / Face Pull / سحب عالٍ باتجاه الوجه', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8b59fe55-a202-4649-b731-be50d5b00da5', 'Biceps Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/09AYfVFf7pg?si=dcwLVAYqIbDLM6jd', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0cf3642e-ca29-431e-a2ab-6dda0c75ab5e', 'Cable Rope Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/xNXUTJ6TBZA?si=-r-Ql97awoVZla_1', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Hammer / Neutral-grip Curl / ثني بقبضة محايدة', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a442f2e7-264e-4ce5-9fe8-7f9ec42b349a', 'Cable Facing Away Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/fV9BpknCjGM', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d0a55f33-f73b-4d86-b1c1-8d68b30be653', 'DB Incline Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/js_StxxyxBM', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('86db302e-de79-4e64-80b9-e68834ee1075', 'Cable Facing In Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/5z4y7QRTx1w', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('683ecafa-f0cb-4906-b797-96d4a2ac0e81', 'Single Arm Cable Facing Away Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/6sO-pK7pTPs?feature=share', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d8f11896-c200-4074-9342-a4f37d15f881', 'Single Arm Cable Facing In Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/I-197ZW9Ffo?si=M1Yq4R1PIpdZMXRx', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ec55642f-bb18-468f-9599-bd02dc8ac979', 'DB Preacher', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/DZJNTb-zzn0?si=SwbdZ0O_0eTOET-5', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Preacher Curl / ثني على مسند', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7d9e0900-3a16-4715-87b7-717a95dd2e6f', 'Preacher Curl Machine', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/TouYMA3-ua4?feature=share', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Preacher Curl / ثني على مسند', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('085d361d-0bee-4508-9ee3-87542f3e6779', 'DB Spider Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/cTMjzB2_IH8?si=qsIKEEFVfEvPXwqf', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('524de411-c37b-4675-8915-4005498e40de', 'Zottman Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://www.youtube.com/watch?v=ZXbOOIOPOi8', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('954803d8-80dc-4cf0-b3dd-da03c645ffc6', 'Hammer Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/10/hammer-curl/', NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Hammer / Neutral-grip Curl / ثني بقبضة محايدة', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e7110bbe-433b-4478-b359-e50159462999', 'TRX Biceps Curl', 'Biceps / البايسبس', '{"Forearms / الساعد","Core / البطن والكور"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'TRX', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/78/trx-reg-biceps-curl/', NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a3ad91b5-adc2-434c-99a3-52301f1cb1ec', 'DB Triceps Extensions', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/d7SXlU5HkYM?si=WuuPa9-yeByaP5sI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Overhead Extension / مد فوق الرأس', 'Elbow Extension / مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('461d721e-e6fa-4049-8a6f-3f51a49b649f', 'DB Floor Triceps Extensions', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/dpFav9Ve4rY?si=ZBdKK8VF4aPMpi3v', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Lying Extension / مد مستلقٍ', 'Elbow Extension / مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c3a5241b-d7df-4d8c-9837-99f0e65a0595', 'Cable Crossbody Extensions', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://www.youtube.com/watch?v=jtLTcED38Dg', 'الكيبل يبدأ بالمنتصف زي الفيديو، بحيث لما تسحب الكيبل يكون بنفس مستوى الترابس، الأكواع والأكتاف ثابتين مكانهم والحركة كلها بثني وفرد الكوع.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Cross-body Extension / مد عرضي', 'Elbow Extension / مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('88db0b7c-d1d3-43a7-8529-62e1b4294e85', 'Triceps Pushdown', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/QsoN4u6j8nM?feature=share', 'انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5c88222d-d872-4c3f-8ce9-0998e550c031', 'Cable Crossover Pressdowns', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/Y3CDzx-oj3k', 'الكيبل يبدأ من الأعلى،انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('542a2f1a-96b0-4895-bbd3-91529397f7a3', 'Band Triceps Pushdown', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/mYs1rEYtZK4?si=k8vdZxNNEB5wj2CA', 'الكيبل يبدأ من الأعلى،انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a91594a0-7459-4a0b-a5e2-22f529103553', 'Single Cable Triceps Pressdowns', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/8rl4ioij6lc', 'الكيبل يبدأ من الأعلى،انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('64d24204-387a-483d-aee8-a73ab652794e', 'Cable Overhead Extension', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://www.youtube.com/shorts/Q3bO1Fh4734', 'اترك الحبل يسحب معصمك وكوعك ثابت لما تستطيل التراي ثم ارفع الوزن لما تستقيم اليد، كوعك ثابت طول الوقت والحركة ثني ومد من مفصل الكوع، ممكن تطبق كل يد لحالها اذا كان اسهل لك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Overhead Extension / مد فوق الرأس', 'Elbow Extension / مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('74245e82-d288-419d-97a8-a542ab3e828b', 'Triceps Dips', 'Triceps / الترايسبس', '{"Chest / الصدر","Shoulders / الأكتاف"}', 'Vertical Push / دفع عمودي', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/SpSE_A5L-YA?si=bSAzRM9SBuX-3mE0', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Dip / متوازي', 'Shoulder Extension + Elbow Extension / مد الكتف + مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4a37d258-865f-45f4-a1cd-23de18b00f5d', 'Triceps Kickback', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/YebyKE3Ts8o?si=H_h9z5BXutFBbFhq', NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/55/triceps-kickback/', NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Triceps Kickback / ركلة الترايسبس', 'Elbow Extension / مد الكوع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6a7c7195-624d-47e7-b50b-01bc4d97bd09', 'Plank', 'Core / البطن والكور', '{"Shoulders / الأكتاف","Glutes / المؤخرة"}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/pvIjsG5Svck?si=cTP8ZyfMAJPfaEhw', 'لما ترتفع الاكتاف تكون فوق الكوع والرجل ممتدة بالكامل.', NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a8153622-f179-465b-9b2a-bbb90eb35949', 'deadbug', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/g_BYB0R-4Ws?si=D4nwJri73eBqJRqL', NULL, 'اسم مشابه موجود في المكتبة (deadbug / dead bug) — تُراجَع قبل الحذف أو الدمج', 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'rejected', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0f4fa70b-55dc-47a1-9d2c-686050086045', 'Band Dead Bug', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'مطاط', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/iW_CtYtzbeU?si=Epequw3rqA3_TwTr', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('65da5b92-b7c4-47e9-8a2d-dfe2ecf2f873', 'Side Plank', 'Core / البطن والكور', '{"Abductors / مبعدات الفخذ","Shoulders / الأكتاف"}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'لما ترتفع الاكتاف تكون فوق الكوع والرجل ممتدة بالكامل.', NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain | ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Anti-Lateral Flexion / مقاومة الميلان الجانبي', 'Isometric Anti-Lateral Flexion / تثبيت الجذع ضد الميلان', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cc4e8d64-83bb-4523-863b-395140c67099', 'McGill Big 3', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/jZylx81_kfg?si=_jP064GZIzvEvzyN', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Mixed (McGill Big 3) / مختلط', 'Isometric Trunk Stabilization / تثبيت الجذع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('55f8f20c-4e9c-481a-97d5-44b177f2a2e1', 'Suitcase Carry', 'Core / البطن والكور', '{"Forearms / الساعد"}', 'Loaded Carry / حمل ومشي', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/BaRMAhD7SP4?si=KkiMH8OSIEz_TB53', NULL, 'نفس التمرين ورد أيضاً تحت التصنيف «Functional Training» (صف المصدر 160) || رابط آخر في المصدر (صف 160): https://youtu.be/BaRMAhD7SP4?si=dCR2n2VSPaHhxfL3', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Suitcase Carry / حمل جانبي', 'Isometric Trunk + Grip Under Load / تثبيت الجذع والقبضة أثناء المشي', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b54ed274-8a4b-44b0-be4a-1dd5c4ba5864', 'Single Leg Raise', 'Core / البطن والكور', '{"Glutes / المؤخرة","Hamstrings / الخلفية"}', NULL, NULL, 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/ZJodU5OOaiA?si=p6ZD9dpzyRKBUn16', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9c11a1ab-6cc8-41ac-8f4e-d039717c7f2f', 'Cable Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/ToJeyhydUxU?si=Z5dv34foxX4VtRH6', 'الحركة عبارة عن ثني للعمود الفقري وكأنك تقرب صدرك لوركك.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Crunch / كرنش', 'Trunk Flexion / ثني الجذع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('10544a38-93b1-4b53-86e2-c00d1c13620a', 'Leg Raises', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/UqmbxvOgnX4?si=U3pDG4Jf0x1mtC_7', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Reverse Crunch / Leg Raise / كرنش عكسي ورفع الأرجل', 'Hip Flexion + Posterior Pelvic Tilt / ثني الورك + إمالة الحوض للخلف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4cb57e06-87f4-487f-9ca1-7284ea6c71ad', 'Bosu Ball Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'أخرى', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/KjvDgHPxXcg?si=zad59CHC6Y-calzi', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Crunch / كرنش', 'Trunk Flexion / ثني الجذع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('255d6fd1-02ca-49f3-9017-674881d08b92', 'Bent Knee V-Up', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/sbyFIM30_G8?si=dED0NQSRS44dz5G9', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'V-up / في أب', 'Trunk Flexion + Hip Flexion / ثني الجذع + ثني الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cdc41d88-817b-4fa2-912b-b357b7b865f6', 'Reverse Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/esYVzdEfs04?si=N44MZZHlVeSQc1S3', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Reverse Crunch / Leg Raise / كرنش عكسي ورفع الأرجل', 'Hip Flexion + Posterior Pelvic Tilt / ثني الورك + إمالة الحوض للخلف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4c008ec6-a7c7-47df-bb61-e80c373d83f9', 'Belly Breathing', 'Core / البطن والكور', '{}', 'Core Activation & Breathing / تفعيل الجذع والتنفس', 'إحماء/تفعيل', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/Shk8cmgv0Ew?si=mXkcj9PH6eH_tLcd', 'نفس عميق من الانف ننفخ فيه البطن ثم نطلعه من الفم ببطئ مع ضغط البطن للداخل اثناء اخراج النفس', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Diaphragmatic Breathing / تنفس حجابي', 'Diaphragmatic Breathing + Abdominal Bracing / تنفس حجابي + شد البطن', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b452dccb-78c3-4148-8443-8b4c42f9f461', 'Dead Bug', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/_zkkMOtXuOQ?si=GIkLuCUJvdaOk5FP', 'نحرك الرجلين ببطئ قليلا و بتحكم باستخدام عضلات البطن', 'اسم مشابه موجود في المكتبة (deadbug / dead bug) — تُراجَع قبل الحذف أو الدمج', 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('395bf540-fa09-409a-a588-4cdb9ff5d437', 'Reverse Tabletop Bridge', 'Core / البطن والكور', '{"Glutes / المؤخرة"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://youtu.be/d1yE9cGtPWo?si=2aoNqmUAN054rP75', 'اخذ نفس اثناء الطلوع، اثبت ثواني فوق واشد عضلات بطني، اطلع النفس اثناء النزول', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2f0a14f6-120b-4f64-92cb-2829c6b862fd', 'Bird Dog', 'Core / البطن والكور', '{"Lower back / أسفل الظهر","Glutes / المؤخرة"}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/L91QMACdA6Q?si=KBnuQDcm9WcUXxxI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Anti-Rotation / مقاومة الدوران', 'Isometric Anti-Rotation / تثبيت الجذع ضد الدوران', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('062ad450-ab6f-465c-8b3f-44821e39de92', 'Pelvic Tilting', 'Core / البطن والكور', '{}', 'Core Activation & Breathing / تفعيل الجذع والتنفس', 'إحماء/تفعيل', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/DqqUIfMuDX4?si=uzl0SRl_M9guUT3j', 'الحركة من الحوض، اخذ نفس وادف حوضي للاعلى قليلا، اطلع النفس اثناء نزول الحوض والصق اسفل ظهري بالارض', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Pelvic Tilt / إمالة الحوض', 'Posterior Pelvic Tilt / إمالة الحوض للخلف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('36554e5e-c90e-41c0-b638-58dca11371ef', 'Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/52/crunch/', NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Crunch / كرنش', 'Trunk Flexion / ثني الجذع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c0acfaef-f563-46a5-9571-e231ab06758d', 'Standing Wood Chop', 'Core / البطن والكور', '{}', 'Trunk Rotation / دوران الجذع', 'كور', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/108/standing-wood-chop/', NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Rotation / Chop / دوران وتقطيع', 'Trunk Rotation / دوران الجذع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0bb0d594-fc38-440e-9c29-898181d6e875', 'Russian Twist', 'Core / البطن والكور', '{"Lower back / أسفل الظهر"}', 'Trunk Rotation / دوران الجذع', 'كور', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/65/russian-twist/', NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Rotation / Chop / دوران وتقطيع', 'Trunk Rotation / دوران الجذع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('418cc5a5-0c2f-47f0-b945-79ef6567cd41', 'Cable Twisted', 'Core / البطن والكور', '{"Lower back / أسفل الظهر"}', 'Trunk Rotation / دوران الجذع', 'كور', 'كيبل', 'مبتدئ', 'نادي', NULL, NULL, NULL, 'إضافة المدربة', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Rotation / Chop / دوران وتقطيع', 'Trunk Rotation / دوران الجذع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('af3090f3-2453-4c26-9827-6a076e66d5a0', 'Calves On Leg Press', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/XdtWVYFVhGU', 'ثبت أصابعك أو مقدمة رجلك على الجهاز، لا تبالغ بالوزن، انزل بكعبك لين تمتد بطاتك بشكل كامل ثم ادفع.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d40213be-1b33-4b4e-9074-4f49e97542be', 'Calves Raise', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/H6WptvjXkgw', 'حط تحت اقدامك بليتس أو أي شي يرفعك عن الأرض، انزل من اصابعك اقصى نزول ثم ادفع للأعلى', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0ae624e4-2dcc-4849-9dd0-3e5569d745bc', 'Calf Raise (Machine)', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', 'جهاز', 'مبتدئ', 'نادي', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/294/calf-raise/', NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c50284fe-f54f-4c6b-9c00-eea278a18cbe', 'Calf Raises (Barbell)', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', 'بار', 'مبتدئ', 'نادي', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/51/calf-raises/', NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('938a51ae-5a8e-43e7-9989-79cbabefb809', 'High-Load Heel Raise (Towel Under Toes)', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', NULL, 'مبتدئ', NULL, NULL, 'رفع الكعب على رجل واحدة مع منشفة ملفوفة تحت أصابع القدم؛ صعود بطيء ثم ثبات قصير ثم نزول بطيء.', 'أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Rathleff et al. 2015 — Scand J Med Sci Sports (RCT)', 'https://doi.org/10.1111/sms.12313', 'اللفافة الأخمصية / Plantar Fasciopathy', 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6855230d-4cdb-4be8-a0bc-42b5cb34e2aa', 'Adductor Slides', 'Adductors / الأفخاذ الداخلية', '{}', 'Hip Adduction / تقريب الورك', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/6U7dfuxaX9g?si=lkH35E7tZxGBePBj', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor strength»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Adductor Slide / انزلاق للتقريب', 'Hip Adduction / تقريب الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4ef0595a-748d-46db-9563-7d80d8590c19', 'Adductor Machine', 'Adductors / الأفخاذ الداخلية', '{}', 'Hip Adduction / تقريب الورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/SU1LQhq3o2g?si=_55FKBOlcn8Ilw4X', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Adductor Machine / جهاز التقريب', 'Hip Adduction / تقريب الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6fe17bc1-aeae-4bb0-a6c5-d88d8d33ab56', 'Side Lunge', 'Adductors / الأفخاذ الداخلية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/50/side-lunge/', 'ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Lateral Lunge / لانج جانبي', 'Knee/Hip Extension + Hip Adduction / مد الركبة والورك + تقريب الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('441a8a31-a623-4a31-bc69-e5796d01c0a2', 'Seated Abductor Machine', 'Abductors / مبعدات الفخذ', '{}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/riEMreTHNbM?si=wE3vfJBYQY7j_oJ2', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor strength»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0724aa3c-bf0e-4953-8088-b94e3291945d', 'Sled Pull/Push', 'Functional / التمارين الوظيفية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Calves / البطات"}', 'Locomotion / مشي وجري ودفع', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://www.youtube.com/watch?v=3KWK7SIdPz4', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Sled Push / Pull / دفع وسحب الزلاجة', 'Hip/Knee Extension in Gait / بسط الورك والركبة بنمط المشي', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d878fd67-64f6-4fb5-a5d3-787955037782', 'Hip Abductor Plank', 'Abductors / مبعدات الفخذ', '{"Core / البطن والكور"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/2lB5RL91yWo?si=WRm9rUORpFK6dXPl', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor strength»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c719c143-b0c3-4218-9efa-aad9c8e1e1cb', 'Dirty Dog', 'Abductors / مبعدات الفخذ', '{"Core / البطن والكور"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/109/dirty-dog/', NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b88ddf87-6d95-41b9-aa76-38d3ab4ece4f', 'Hip Hitch (Pelvic Drop)', 'Abductors / مبعدات الفخذ', '{}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Ganderton et al. — GMin/GMed EMG (RMIT University)', 'https://research-repository.rmit.edu.au/articles/journal_contribution/Gluteus_Minimus_and_Gluteus_Medius_Muscle_Activity_during_Common_Rehabilitation_Exercises_in_Healthy_Postmenopausal_Women/27572301', 'ضعف الألوية المتوسطة / Gluteus Medius Weakness | ضعف الألوية الصغرى / Gluteus Minimus Weakness', 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Pelvic Drop (Stance Leg) / تثبيت الحوض برجل الارتكاز', 'Hip Abduction of Stance Leg / تبعيد ورك رجل الارتكاز', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b29ff3c2-c22e-4947-8305-f252c0c181d9', 'Rotator Cuff', 'Rotator cuffs / الكفة المدورة', '{}', 'Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/mO8YJAxVG2M?si=KL_llR6Z47Yt89uk', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «Functional Training»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'External Rotation / دوران خارجي', 'Shoulder External Rotation / دوران خارجي للكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fad9b657-2750-4aea-b676-19f27fb5eb62', 'Shoulder I-Y-T-W Series', 'Rotator cuffs / الكفة المدورة', '{"Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/237/shoulder-stability-mobility-series-i-y-t-w-formations/', 'تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture | ضعف العضلة المعينية / Rhomboid Weakness', 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'I-Y-T-W / تمارين I-Y-T-W', 'Scapular Retraction/Depression + Arm Elevation / سحب وخفض لوح الكتف مع رفع الذراع', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('19cd864d-6c70-495a-828a-4163737fe839', 'Supine Snow Angel (Wipers)', 'Rotator cuffs / الكفة المدورة', '{"Shoulders / الأكتاف","Core / البطن والكور"}', 'Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/124/supine-snow-angel-wipers-exercise/', 'تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture', 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Snow Angel / الملاك', 'Shoulder Abduction/Adduction + Scapular Control / تبعيد وتقريب الكتف مع تحكم لوح الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('61b4e409-ae08-4390-8805-fa29d641ed0b', 'Back Extension', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة","Hamstrings / الخلفية"}', 'Spinal Extension / بسط الجذع', 'كور', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/bs7S3RFyIYs?si=tDLl3OYuDBIwK4Fj', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «Functional Training»)', 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain | تحدب الظهر / Postural Thoracic Kyphosis', 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Back Extension / بسط الظهر', 'Hip Extension + Spinal Extension / بسط الورك + بسط العمود الفقري', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('07edebf9-045a-4978-960f-d052b5eda37f', 'Supermans', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة","Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Spinal Extension / بسط الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/9/supermans/', 'تحدب الظهر / Postural Thoracic Kyphosis | آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Prone Extension / بسط على البطن', 'Spinal Extension / بسط العمود الفقري', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7bd7b75c-f146-46a2-9fad-13f4c893be5b', 'Stability Ball Reverse Extensions', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة"}', 'Spinal Extension / بسط الجذع', 'كور', 'كرة سويسرية', 'مبتدئ', 'منزل', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/64/stability-ball-reverse-extensions/', NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Reverse Extension / بسط عكسي', 'Hip Extension + Spinal Extension / بسط الورك + بسط العمود الفقري', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f8a656c9-fdff-4749-aaec-11b86fa73c0f', 'Farmer’s Walk', 'Functional / التمارين الوظيفية', '{"Forearms / الساعد","Core / البطن والكور","Back & Lats / الظهر واللاتس"}', 'Loaded Carry / حمل ومشي', 'قوة', NULL, 'مبتدئ', NULL, 'https://www.youtube.com/watch?v=hx24PM6gXs8', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Farmer''s Walk / مشي المزارع', 'Isometric Trunk + Grip Under Load / تثبيت الجذع والقبضة أثناء المشي', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8abbfa39-9863-4b6a-82d1-4aca5838fcdf', 'Contralateral Limb Raises', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة","Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Spinal Extension / بسط الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/53/contralateral-limb-raises/', NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Prone Extension / بسط على البطن', 'Spinal Extension / بسط العمود الفقري', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e727ce3c-3e61-4b77-835f-9d034046d40d', 'Inner Thigh Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/uqCfJYKojLU?si=Gev0VeOwVp5z6gB2', 'الضغط والدفع يكون من جهة الفخذ ، لا تدفع من ركبتك!', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «stretch»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Adductor Stretch / إطالة المقربات', 'Hip Abduction (Adductor Stretch) / تبعيد الورك (إطالة المقربات)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c0ca9f7e-04ca-4ad0-ab1e-0e665712fb90', 'Hips Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/uqCfJYKojLU?si=Gev0VeOwVp5z6gB2', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «stretch»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Hip Stretch / إطالة الورك', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('26d35087-a03c-4103-bc8a-45a82722b991', 'Kneeling Hip-flexor Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'من وضع الركوع: الركبة الخلفية تحت الورك والقدم الأمامية أمامك والركبة فوق الكاحل. شد البطن وادفع الحوض للأمام دون تقويس أسفل الظهر، واعصر مؤخرة الجهة الخلفية لزيادة الإطالة. اثبت 30–45 ثانية، 2–5 مرات.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/142/kneeling-hip-flexor-stretch/', NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Hip Flexor Stretch / إطالة ثانيات الورك', 'Hip Extension (End Range) / بسط الورك في نهاية المدى', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6a305b77-dc22-42df-ad43-dbe68cafeb89', 'Supine Hamstrings Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'استلقِ على ظهرك وارفع رجلاً واحدة ومدّها ببطء مع سحب أصابع القدم نحوك، دون أي حركة في الحوض أو أسفل الظهر. اثبت 15–30 ثانية، 2–4 مرات لكل رجل.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/235/supine-hamstrings-stretch/', NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Hamstring Stretch / إطالة الخلفية', 'Hip Flexion with Knee Extended / ثني الورك مع مد الركبة', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('07f4608e-0558-45d6-be7a-3818cfefe44c', 'Side Lying Quadriceps Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'استلقِ على جنبك وشد البطن، واسحب كعب الرجل العلوية نحو المؤخرة بيدك مع إبقاء الركبة في خط الورك. اثبت 30–45 ثانية، 2–5 مرات لكل جهة.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/149/side-lying-quadriceps-stretch/', NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Quadriceps Stretch / إطالة الأمامية', 'Knee Flexion + Hip Extension (End Range) / ثني الركبة + بسط الورك', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0b116f3c-5b08-4c81-a289-cc7869c9c674', 'Standing Dorsi-Flexion (Calf Stretch)', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/152/standing-dorsi-flexion-calf-stretch/', 'اللفافة الأخمصية / Plantar Fasciopathy', 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Calf Stretch / إطالة البطات', 'Ankle Dorsiflexion / ثني ظهري للكاحل', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e513f595-0ec6-455d-9acb-0251c710b513', 'Cat-Cow', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/15/cat-cow/', 'تحدب الظهر / Postural Thoracic Kyphosis | آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Spinal Mobility / مرونة العمود الفقري', 'Spinal Flexion/Extension / ثني وبسط العمود الفقري', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('82dcc92b-00a8-4dd7-8d8e-4f142909d8fc', 'Standing Lunge Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/137/standing-lunge-stretch/', NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Hip Flexor Stretch / إطالة ثانيات الورك', 'Hip Extension (End Range) / بسط الورك في نهاية المدى', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ab215499-24c4-42a0-9efc-955a75f8a6c6', 'Plantar Fascia-Specific Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'تُسحب أصابع القدم للخلف باليد حتى يُشعر بشد في باطن القدم، مع تحسّس اللفافة للتأكد من الشد.', 'أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Rathleff et al. 2015 — Scand J Med Sci Sports (RCT)', 'https://doi.org/10.1111/sms.12313', 'اللفافة الأخمصية / Plantar Fasciopathy', 'review', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Plantar Fascia Stretch / إطالة اللفافة الأخمصية', 'Toe Extension + Ankle Dorsiflexion / مد أصابع القدم + ثني ظهري', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('820099be-6382-4015-b88f-635a4406a62c', 'Crab Reach (Thoracic Bridge)', 'Functional / التمارين الوظيفية', '{"Glutes / المؤخرة","Shoulders / الأكتاف"}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://www.youtube.com/watch?v=fgsUe3Lc3hI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'تحدب الظهر / Postural Thoracic Kyphosis', 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Thoracic Bridge / جسر صدري', 'Hip Extension + Thoracic Rotation / بسط الورك + دوران الصدر', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d7014800-3ba3-4483-8923-34697476473c', 'Lateral Bound', 'Plyometrics / التمارين الانفجارية', '{"Glutes / المؤخرة","Quadriceps / الأمامية","Abductors / مبعدات الفخذ"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://www.youtube.com/watch?v=soqQy4dzEts', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «Functional Training»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Lateral Jump / قفز جانبي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b9d6c97c-3bf6-48a8-ab66-7729acfddb83', 'Box Jumps', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Calves / البطات"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'أخرى', 'متوسط', 'نادي', NULL, NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «CrossFit»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Vertical Jump / قفز عمودي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2bb5e2e3-ee63-41cb-aff0-df0c38464379', 'Squat Jump', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متوسط', 'بدون معدات', NULL, 'قف بعرض الحوض، ادفع الورك للخلف وانزل، ثم اقفز بقوة بمدّ الكاحل والركبة والورك معاً. انزل بهدوء على منتصف القدم مع دفع الورك للخلف ودون قفل الركب. ابدأ بقفزات صغيرة حتى تتقن الهبوط.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/222/squat-jump/', NULL, 'review', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Vertical Jump / قفز عمودي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d6ee8e27-cd91-43c6-81db-d2c466bfc6a2', 'Tuck Jump', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متقدم', 'بدون معدات', NULL, 'استخدم الذراعين للزخم: أرجعهما للخلف عند النزول وأرجحهما للأمام والأعلى عند القفز، واسحب الركبتين نحو الصدر في الهواء.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/180/tuck-jump/', NULL, 'review', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Vertical Jump / قفز عمودي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d1181a29-919f-4419-9621-84479d88b092', 'Cycled Split-Squat Jump', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Hamstrings / الخلفية"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متقدم', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/234/cycled-split-squat-jump/', NULL, 'review', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Split Jump / قفز سبليت', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0b436e91-8fc4-49ad-9efd-dd5009cece84', 'Lateral Cone Jumps', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Calves / البطات"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'أخرى', 'متوسط', 'نادي', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/120/lateral-cone-jumps/', NULL, 'review', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Lateral Jump / قفز جانبي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('20ebf276-985c-4a34-9670-e8a15c319b38', 'Forward Linear Jumps', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Hamstrings / الخلفية"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متوسط', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/177/forward-linear-jumps/', NULL, 'review', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Horizontal Jump / قفز أمامي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2402a78b-4dca-4e49-b3ed-25df7591aa18', 'Jogging', 'CrossFit / كروس فت', '{"Quadriceps / الأمامية","Hamstrings / الخلفية","Calves / البطات"}', 'Locomotion / مشي وجري ودفع', 'كارديو', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Running / جري', 'Gait: Alternating Hip/Knee Extension / نمط المشي والجري', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7b68cc34-999c-434c-9562-a4133b64f87a', 'Wall Ball', 'CrossFit / كروس فت', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Shoulders / الأكتاف"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'أخرى', 'متوسط', 'نادي', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Squat to Throw / سكوات مع رمي', 'Knee/Hip Extension + Shoulder Flexion / مد الركبة والورك + ثني الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('811fa331-9584-46e6-a3e9-74cc2b85629d', 'Snatch', 'CrossFit / كروس فت', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Shoulders / الأكتاف"}', 'Olympic Lift (Triple Extension) / رفعات أولمبية (بسط ثلاثي)', 'قدرة', 'بار', 'متقدم', 'نادي', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Snatch / سناتش', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9561a0ff-79eb-4549-a413-8676c765a901', 'Clean', 'CrossFit / كروس فت', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Quadriceps / الأمامية"}', 'Olympic Lift (Triple Extension) / رفعات أولمبية (بسط ثلاثي)', 'قدرة', 'بار', 'متقدم', 'نادي', NULL, NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Clean / كلين', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('43deac5b-f102-4b59-b362-a7a109750f8b', 'Turkish Get-Up', 'Functional / التمارين الوظيفية', '{"Shoulders / الأكتاف","Core / البطن والكور","Glutes / المؤخرة"}', 'Full-body Integrated / حركة متكاملة للجسم', 'قوة', 'كيتلبل', 'متقدم', 'منزل', 'https://www.youtube.com/watch?v=0bWRPC49-KI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Turkish Get-Up / النهوض التركي', 'Multi-joint Integrated / حركة متعددة المفاصل', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3d195ede-42fd-4256-9125-9ac2dd68c62b', '90s Transition', 'Functional / التمارين الوظيفية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://www.youtube.com/watch?v=ogU-azeGe_k', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Hip Rotation Mobility (90/90) / مرونة دوران الورك', 'Hip Internal/External Rotation / دوران الورك الداخلي والخارجي', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('39bab3c6-1a9e-4951-9f64-00b319b541c9', 'Prone Swimmer', 'Functional / التمارين الوظيفية', '{"Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Shoulder Rear Pull / سحب خلفي للكتف', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://www.youtube.com/watch?v=M8a1cgnhyqk', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture', 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Prone Swimmer / سبّاح على البطن', 'Shoulder Extension/Abduction + Rotation / مد وتبعيد الكتف مع الدوران', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('47ba53b6-a029-4d0d-896a-a3bd1ec102b5', 'Kettlebell Swing', 'Functional / التمارين الوظيفية', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Core / البطن والكور"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قدرة', 'كيتلبل', 'متوسط', 'منزل', 'https://www.youtube.com/watch?v=d94xX-AQZ0A', NULL, 'نفس التمرين ورد أيضاً تحت التصنيف «CrossFit» (صف المصدر 168)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Ballistic Hinge (Swing) / مفصلة انفجارية (سوينق)', 'Hip Extension (Ballistic) / بسط الورك الانفجاري', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8f98df7a-cf14-4ff3-99da-70a57639d262', 'left over db', 'Functional / التمارين الوظيفية', '{}', NULL, NULL, 'دمبل', NULL, 'منزل', 'https://youtu.be/pLnRt-caepc?si=DAS9jeYr8vS6RRtz', 'طبق الحركة بأقصى عدد ممكن من التكرارات وأحسبها كجولة، ثم ابدأ بالجولة الثانية بنفس الطريقة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('43f26816-e648-47e6-8a53-1f79751cc662', 'Serratus Punches Supine', 'Functional / التمارين الوظيفية', '{"Shoulders / الأكتاف","Chest / الصدر"}', 'Horizontal Push / دفع أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/cxaAqmdlrgk?si=2YRAIgFFXPAvDadG', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Scapular Protraction / دفع لوح الكتف', 'Scapular Protraction / دفع لوح الكتف', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5dc760c2-ec8c-4824-9077-6b10f0e56969', 'Isometric Wrist Extension', 'Forearms / الساعد', '{}', 'Wrist Extension / مد الرسغ', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'مرفق التنس / Lateral Elbow Tendinopathy', 'review', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Isometric / ثابت', 'Wrist Extension / مد الرسغ', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4a13372b-a7db-48c4-aae8-57d171175a0d', 'Eccentric Wrist Extension', 'Forearms / الساعد', '{}', 'Wrist Extension / مد الرسغ', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'مرفق التنس / Lateral Elbow Tendinopathy', 'review', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Eccentric / لامركزي', 'Wrist Extension / مد الرسغ', NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('16367e83-a42a-47fd-ba4a-29ee5d51b4bb', 'Chin Tuck (Deep Neck Flexor)', 'Neck / الرقبة', '{}', 'Neck Flexion (Deep Flexors) / ثني الرقبة العميق', 'إحماء/تفعيل', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Sheikhhoseini et al. 2018 — JMPT (Systematic review, FHP)', 'https://pubmed.ncbi.nlm.nih.gov/30107937/', 'وضعية الرأس للأمام / Forward Head Posture', 'review', '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00', 'Chin Tuck / سحب الذقن', 'Upper Cervical Flexion + Retraction / ثني علوي للرقبة مع سحبها للخلف', NULL) ON CONFLICT DO NOTHING;



INSERT INTO public.exercise_alternatives VALUES ('f4cd39db-0991-4468-b6ad-d3b6e9c11626', '66f0d0dd-c865-4bc1-b512-c66cdfe3ff10', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f4cd39db-0991-4468-b6ad-d3b6e9c11626', 'd3f8d53c-0e8f-4bd8-ad7c-a5aff9925fc9', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f4cd39db-0991-4468-b6ad-d3b6e9c11626', '861c687e-6cab-45dd-84b4-5145ce710774', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f4cd39db-0991-4468-b6ad-d3b6e9c11626', 'dfe1b612-41d3-4234-8b02-09044fee017a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f4cd39db-0991-4468-b6ad-d3b6e9c11626', 'd74cb6a0-29d3-4ca1-bc2c-1fdd331795cc', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('66f0d0dd-c865-4bc1-b512-c66cdfe3ff10', 'f4cd39db-0991-4468-b6ad-d3b6e9c11626', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('66f0d0dd-c865-4bc1-b512-c66cdfe3ff10', 'd3f8d53c-0e8f-4bd8-ad7c-a5aff9925fc9', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('66f0d0dd-c865-4bc1-b512-c66cdfe3ff10', '861c687e-6cab-45dd-84b4-5145ce710774', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('66f0d0dd-c865-4bc1-b512-c66cdfe3ff10', 'dfe1b612-41d3-4234-8b02-09044fee017a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('66f0d0dd-c865-4bc1-b512-c66cdfe3ff10', 'd74cb6a0-29d3-4ca1-bc2c-1fdd331795cc', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9a2a3f4-60e9-46a3-937e-6d70c721acb0', '3f76e849-a6eb-4c3e-ab54-a2b69869b301', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9a2a3f4-60e9-46a3-937e-6d70c721acb0', '3f829839-965b-4ade-8191-c2691a7ff616', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9a2a3f4-60e9-46a3-937e-6d70c721acb0', 'f4cd39db-0991-4468-b6ad-d3b6e9c11626', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9a2a3f4-60e9-46a3-937e-6d70c721acb0', '66f0d0dd-c865-4bc1-b512-c66cdfe3ff10', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9a2a3f4-60e9-46a3-937e-6d70c721acb0', 'fe06a0a7-5b1c-4be8-9645-446fb327c25e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe06a0a7-5b1c-4be8-9645-446fb327c25e', 'a6039c53-2818-44e6-95c3-9346f93f3d47', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe06a0a7-5b1c-4be8-9645-446fb327c25e', 'f4cd39db-0991-4468-b6ad-d3b6e9c11626', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe06a0a7-5b1c-4be8-9645-446fb327c25e', '66f0d0dd-c865-4bc1-b512-c66cdfe3ff10', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe06a0a7-5b1c-4be8-9645-446fb327c25e', 'f9a2a3f4-60e9-46a3-937e-6d70c721acb0', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe06a0a7-5b1c-4be8-9645-446fb327c25e', 'd3f8d53c-0e8f-4bd8-ad7c-a5aff9925fc9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6039c53-2818-44e6-95c3-9346f93f3d47', 'fe06a0a7-5b1c-4be8-9645-446fb327c25e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6039c53-2818-44e6-95c3-9346f93f3d47', 'f4cd39db-0991-4468-b6ad-d3b6e9c11626', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6039c53-2818-44e6-95c3-9346f93f3d47', '66f0d0dd-c865-4bc1-b512-c66cdfe3ff10', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6039c53-2818-44e6-95c3-9346f93f3d47', 'f9a2a3f4-60e9-46a3-937e-6d70c721acb0', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a6039c53-2818-44e6-95c3-9346f93f3d47', 'd3f8d53c-0e8f-4bd8-ad7c-a5aff9925fc9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3f8d53c-0e8f-4bd8-ad7c-a5aff9925fc9', 'f4cd39db-0991-4468-b6ad-d3b6e9c11626', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3f8d53c-0e8f-4bd8-ad7c-a5aff9925fc9', '66f0d0dd-c865-4bc1-b512-c66cdfe3ff10', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3f8d53c-0e8f-4bd8-ad7c-a5aff9925fc9', '861c687e-6cab-45dd-84b4-5145ce710774', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3f8d53c-0e8f-4bd8-ad7c-a5aff9925fc9', 'dfe1b612-41d3-4234-8b02-09044fee017a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3f8d53c-0e8f-4bd8-ad7c-a5aff9925fc9', 'd74cb6a0-29d3-4ca1-bc2c-1fdd331795cc', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('861c687e-6cab-45dd-84b4-5145ce710774', 'f4cd39db-0991-4468-b6ad-d3b6e9c11626', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('861c687e-6cab-45dd-84b4-5145ce710774', '66f0d0dd-c865-4bc1-b512-c66cdfe3ff10', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('861c687e-6cab-45dd-84b4-5145ce710774', 'd3f8d53c-0e8f-4bd8-ad7c-a5aff9925fc9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('861c687e-6cab-45dd-84b4-5145ce710774', 'dfe1b612-41d3-4234-8b02-09044fee017a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('861c687e-6cab-45dd-84b4-5145ce710774', 'd74cb6a0-29d3-4ca1-bc2c-1fdd331795cc', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f76e849-a6eb-4c3e-ab54-a2b69869b301', 'f9a2a3f4-60e9-46a3-937e-6d70c721acb0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f76e849-a6eb-4c3e-ab54-a2b69869b301', '3f829839-965b-4ade-8191-c2691a7ff616', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f76e849-a6eb-4c3e-ab54-a2b69869b301', 'f4cd39db-0991-4468-b6ad-d3b6e9c11626', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f76e849-a6eb-4c3e-ab54-a2b69869b301', '66f0d0dd-c865-4bc1-b512-c66cdfe3ff10', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f76e849-a6eb-4c3e-ab54-a2b69869b301', 'fe06a0a7-5b1c-4be8-9645-446fb327c25e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dfe1b612-41d3-4234-8b02-09044fee017a', 'f4cd39db-0991-4468-b6ad-d3b6e9c11626', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dfe1b612-41d3-4234-8b02-09044fee017a', '66f0d0dd-c865-4bc1-b512-c66cdfe3ff10', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dfe1b612-41d3-4234-8b02-09044fee017a', 'd3f8d53c-0e8f-4bd8-ad7c-a5aff9925fc9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dfe1b612-41d3-4234-8b02-09044fee017a', '861c687e-6cab-45dd-84b4-5145ce710774', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dfe1b612-41d3-4234-8b02-09044fee017a', 'd74cb6a0-29d3-4ca1-bc2c-1fdd331795cc', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f829839-965b-4ade-8191-c2691a7ff616', 'f9a2a3f4-60e9-46a3-937e-6d70c721acb0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f829839-965b-4ade-8191-c2691a7ff616', '3f76e849-a6eb-4c3e-ab54-a2b69869b301', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f829839-965b-4ade-8191-c2691a7ff616', 'f4cd39db-0991-4468-b6ad-d3b6e9c11626', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f829839-965b-4ade-8191-c2691a7ff616', '66f0d0dd-c865-4bc1-b512-c66cdfe3ff10', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3f829839-965b-4ade-8191-c2691a7ff616', 'fe06a0a7-5b1c-4be8-9645-446fb327c25e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('38bf1318-fb87-40fc-a7b4-637dfe3918c9', '56b0e22f-7935-48e8-b7d0-68c2e0b6dd4c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('38bf1318-fb87-40fc-a7b4-637dfe3918c9', 'b9f13d94-0932-4f90-aebe-f247951b3879', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('38bf1318-fb87-40fc-a7b4-637dfe3918c9', '2045070a-7609-4fe3-99b5-313ffe4d22ff', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('38bf1318-fb87-40fc-a7b4-637dfe3918c9', '2319325a-b5a8-4ce3-8a50-5056cb7683bc', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('38bf1318-fb87-40fc-a7b4-637dfe3918c9', 'cd86eb8c-15b1-4e0f-9d55-ce514145afc4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('56b0e22f-7935-48e8-b7d0-68c2e0b6dd4c', 'b9f13d94-0932-4f90-aebe-f247951b3879', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('56b0e22f-7935-48e8-b7d0-68c2e0b6dd4c', '2045070a-7609-4fe3-99b5-313ffe4d22ff', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('56b0e22f-7935-48e8-b7d0-68c2e0b6dd4c', 'cd86eb8c-15b1-4e0f-9d55-ce514145afc4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('56b0e22f-7935-48e8-b7d0-68c2e0b6dd4c', '501fe070-caed-4d03-a38b-b4ed054b70ed', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('56b0e22f-7935-48e8-b7d0-68c2e0b6dd4c', '38bf1318-fb87-40fc-a7b4-637dfe3918c9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b9f13d94-0932-4f90-aebe-f247951b3879', '56b0e22f-7935-48e8-b7d0-68c2e0b6dd4c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b9f13d94-0932-4f90-aebe-f247951b3879', '2045070a-7609-4fe3-99b5-313ffe4d22ff', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b9f13d94-0932-4f90-aebe-f247951b3879', 'cd86eb8c-15b1-4e0f-9d55-ce514145afc4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b9f13d94-0932-4f90-aebe-f247951b3879', '501fe070-caed-4d03-a38b-b4ed054b70ed', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b9f13d94-0932-4f90-aebe-f247951b3879', '38bf1318-fb87-40fc-a7b4-637dfe3918c9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2045070a-7609-4fe3-99b5-313ffe4d22ff', '56b0e22f-7935-48e8-b7d0-68c2e0b6dd4c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2045070a-7609-4fe3-99b5-313ffe4d22ff', 'b9f13d94-0932-4f90-aebe-f247951b3879', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2045070a-7609-4fe3-99b5-313ffe4d22ff', 'cd86eb8c-15b1-4e0f-9d55-ce514145afc4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2045070a-7609-4fe3-99b5-313ffe4d22ff', '501fe070-caed-4d03-a38b-b4ed054b70ed', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2045070a-7609-4fe3-99b5-313ffe4d22ff', '38bf1318-fb87-40fc-a7b4-637dfe3918c9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2319325a-b5a8-4ce3-8a50-5056cb7683bc', '38bf1318-fb87-40fc-a7b4-637dfe3918c9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2319325a-b5a8-4ce3-8a50-5056cb7683bc', '56b0e22f-7935-48e8-b7d0-68c2e0b6dd4c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2319325a-b5a8-4ce3-8a50-5056cb7683bc', 'b9f13d94-0932-4f90-aebe-f247951b3879', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2319325a-b5a8-4ce3-8a50-5056cb7683bc', '2045070a-7609-4fe3-99b5-313ffe4d22ff', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2319325a-b5a8-4ce3-8a50-5056cb7683bc', 'cd86eb8c-15b1-4e0f-9d55-ce514145afc4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd86eb8c-15b1-4e0f-9d55-ce514145afc4', '56b0e22f-7935-48e8-b7d0-68c2e0b6dd4c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd86eb8c-15b1-4e0f-9d55-ce514145afc4', 'b9f13d94-0932-4f90-aebe-f247951b3879', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd86eb8c-15b1-4e0f-9d55-ce514145afc4', '2045070a-7609-4fe3-99b5-313ffe4d22ff', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd86eb8c-15b1-4e0f-9d55-ce514145afc4', '501fe070-caed-4d03-a38b-b4ed054b70ed', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd86eb8c-15b1-4e0f-9d55-ce514145afc4', '38bf1318-fb87-40fc-a7b4-637dfe3918c9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('501fe070-caed-4d03-a38b-b4ed054b70ed', '56b0e22f-7935-48e8-b7d0-68c2e0b6dd4c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('501fe070-caed-4d03-a38b-b4ed054b70ed', 'b9f13d94-0932-4f90-aebe-f247951b3879', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('501fe070-caed-4d03-a38b-b4ed054b70ed', '2045070a-7609-4fe3-99b5-313ffe4d22ff', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('501fe070-caed-4d03-a38b-b4ed054b70ed', 'cd86eb8c-15b1-4e0f-9d55-ce514145afc4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('501fe070-caed-4d03-a38b-b4ed054b70ed', '38bf1318-fb87-40fc-a7b4-637dfe3918c9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('36189c40-8bbf-465d-b997-2c20bc77fee8', '79063b15-b2ac-4843-91cb-35f1f2a21936', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('36189c40-8bbf-465d-b997-2c20bc77fee8', '6486840a-5d59-40a2-b838-7e991e2a22c0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('36189c40-8bbf-465d-b997-2c20bc77fee8', 'b5fc501c-260e-466f-a384-8369279c8312', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('36189c40-8bbf-465d-b997-2c20bc77fee8', '7af621d7-1a02-4991-bd62-c8109d116440', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('36189c40-8bbf-465d-b997-2c20bc77fee8', '0e2555a5-d883-42a4-8383-bae310510ea5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('79063b15-b2ac-4843-91cb-35f1f2a21936', '36189c40-8bbf-465d-b997-2c20bc77fee8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('79063b15-b2ac-4843-91cb-35f1f2a21936', '6486840a-5d59-40a2-b838-7e991e2a22c0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('79063b15-b2ac-4843-91cb-35f1f2a21936', 'b5fc501c-260e-466f-a384-8369279c8312', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('79063b15-b2ac-4843-91cb-35f1f2a21936', '7af621d7-1a02-4991-bd62-c8109d116440', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('79063b15-b2ac-4843-91cb-35f1f2a21936', '0e2555a5-d883-42a4-8383-bae310510ea5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6486840a-5d59-40a2-b838-7e991e2a22c0', '36189c40-8bbf-465d-b997-2c20bc77fee8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6486840a-5d59-40a2-b838-7e991e2a22c0', '79063b15-b2ac-4843-91cb-35f1f2a21936', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6486840a-5d59-40a2-b838-7e991e2a22c0', 'b5fc501c-260e-466f-a384-8369279c8312', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6486840a-5d59-40a2-b838-7e991e2a22c0', '7af621d7-1a02-4991-bd62-c8109d116440', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6486840a-5d59-40a2-b838-7e991e2a22c0', '0e2555a5-d883-42a4-8383-bae310510ea5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0e2555a5-d883-42a4-8383-bae310510ea5', '36189c40-8bbf-465d-b997-2c20bc77fee8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0e2555a5-d883-42a4-8383-bae310510ea5', '79063b15-b2ac-4843-91cb-35f1f2a21936', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0e2555a5-d883-42a4-8383-bae310510ea5', '6486840a-5d59-40a2-b838-7e991e2a22c0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0e2555a5-d883-42a4-8383-bae310510ea5', 'b5fc501c-260e-466f-a384-8369279c8312', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0e2555a5-d883-42a4-8383-bae310510ea5', '7af621d7-1a02-4991-bd62-c8109d116440', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b5fc501c-260e-466f-a384-8369279c8312', '36189c40-8bbf-465d-b997-2c20bc77fee8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b5fc501c-260e-466f-a384-8369279c8312', '79063b15-b2ac-4843-91cb-35f1f2a21936', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b5fc501c-260e-466f-a384-8369279c8312', '6486840a-5d59-40a2-b838-7e991e2a22c0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b5fc501c-260e-466f-a384-8369279c8312', '7af621d7-1a02-4991-bd62-c8109d116440', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b5fc501c-260e-466f-a384-8369279c8312', '0e2555a5-d883-42a4-8383-bae310510ea5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7af621d7-1a02-4991-bd62-c8109d116440', '36189c40-8bbf-465d-b997-2c20bc77fee8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7af621d7-1a02-4991-bd62-c8109d116440', '79063b15-b2ac-4843-91cb-35f1f2a21936', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7af621d7-1a02-4991-bd62-c8109d116440', '6486840a-5d59-40a2-b838-7e991e2a22c0', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7af621d7-1a02-4991-bd62-c8109d116440', 'b5fc501c-260e-466f-a384-8369279c8312', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7af621d7-1a02-4991-bd62-c8109d116440', '0e2555a5-d883-42a4-8383-bae310510ea5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d74cb6a0-29d3-4ca1-bc2c-1fdd331795cc', 'f4cd39db-0991-4468-b6ad-d3b6e9c11626', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d74cb6a0-29d3-4ca1-bc2c-1fdd331795cc', '66f0d0dd-c865-4bc1-b512-c66cdfe3ff10', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d74cb6a0-29d3-4ca1-bc2c-1fdd331795cc', 'd3f8d53c-0e8f-4bd8-ad7c-a5aff9925fc9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d74cb6a0-29d3-4ca1-bc2c-1fdd331795cc', '861c687e-6cab-45dd-84b4-5145ce710774', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d74cb6a0-29d3-4ca1-bc2c-1fdd331795cc', 'dfe1b612-41d3-4234-8b02-09044fee017a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('46c20362-96a4-4bed-a4ac-b244090e4765', '38bf1318-fb87-40fc-a7b4-637dfe3918c9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('46c20362-96a4-4bed-a4ac-b244090e4765', '56b0e22f-7935-48e8-b7d0-68c2e0b6dd4c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('46c20362-96a4-4bed-a4ac-b244090e4765', 'b9f13d94-0932-4f90-aebe-f247951b3879', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('46c20362-96a4-4bed-a4ac-b244090e4765', '2045070a-7609-4fe3-99b5-313ffe4d22ff', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('46c20362-96a4-4bed-a4ac-b244090e4765', '2319325a-b5a8-4ce3-8a50-5056cb7683bc', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('463a9a8c-ac07-4935-a02c-febf8ca48a61', '186ce481-4474-4657-90a2-b94c5f575b78', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('463a9a8c-ac07-4935-a02c-febf8ca48a61', 'ffe653fe-250c-414b-a93d-a6e0a3aa2d9b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('463a9a8c-ac07-4935-a02c-febf8ca48a61', 'a85255fe-1453-4159-817c-50b747e6fce2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('186ce481-4474-4657-90a2-b94c5f575b78', '463a9a8c-ac07-4935-a02c-febf8ca48a61', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('186ce481-4474-4657-90a2-b94c5f575b78', 'ffe653fe-250c-414b-a93d-a6e0a3aa2d9b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('186ce481-4474-4657-90a2-b94c5f575b78', 'a85255fe-1453-4159-817c-50b747e6fce2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ffe653fe-250c-414b-a93d-a6e0a3aa2d9b', '463a9a8c-ac07-4935-a02c-febf8ca48a61', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ffe653fe-250c-414b-a93d-a6e0a3aa2d9b', '186ce481-4474-4657-90a2-b94c5f575b78', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ffe653fe-250c-414b-a93d-a6e0a3aa2d9b', 'a85255fe-1453-4159-817c-50b747e6fce2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a85255fe-1453-4159-817c-50b747e6fce2', '463a9a8c-ac07-4935-a02c-febf8ca48a61', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a85255fe-1453-4159-817c-50b747e6fce2', '186ce481-4474-4657-90a2-b94c5f575b78', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a85255fe-1453-4159-817c-50b747e6fce2', 'ffe653fe-250c-414b-a93d-a6e0a3aa2d9b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f6f5eb4b-4dfc-477c-84b2-8ecdbcd793eb', '608011f9-82e5-47ef-ab8b-d19d91af3ff1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f6f5eb4b-4dfc-477c-84b2-8ecdbcd793eb', '52a68e9d-d224-47be-b7f8-5ae4221e927c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f6f5eb4b-4dfc-477c-84b2-8ecdbcd793eb', 'bb61c189-4aa5-40ba-b3a1-a96c9dfbb33b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f6f5eb4b-4dfc-477c-84b2-8ecdbcd793eb', '5dd8e92a-2509-4744-8e2b-c0805b45a17f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f6f5eb4b-4dfc-477c-84b2-8ecdbcd793eb', '609b2b48-2196-4c38-9f2d-b19e41999946', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7912eeca-7e8c-49e0-83b9-a70134824b1c', '441a8a31-a623-4a31-bc69-e5796d01c0a2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7912eeca-7e8c-49e0-83b9-a70134824b1c', 'd878fd67-64f6-4fb5-a5d3-787955037782', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7912eeca-7e8c-49e0-83b9-a70134824b1c', 'c719c143-b0c3-4218-9efa-aad9c8e1e1cb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7912eeca-7e8c-49e0-83b9-a70134824b1c', '369b3080-a974-4a86-8ed0-e7cc0b200cf1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7912eeca-7e8c-49e0-83b9-a70134824b1c', 'b88ddf87-6d95-41b9-aa76-38d3ab4ece4f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('608011f9-82e5-47ef-ab8b-d19d91af3ff1', 'f6f5eb4b-4dfc-477c-84b2-8ecdbcd793eb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('608011f9-82e5-47ef-ab8b-d19d91af3ff1', '52a68e9d-d224-47be-b7f8-5ae4221e927c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('608011f9-82e5-47ef-ab8b-d19d91af3ff1', 'bb61c189-4aa5-40ba-b3a1-a96c9dfbb33b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('608011f9-82e5-47ef-ab8b-d19d91af3ff1', '5dd8e92a-2509-4744-8e2b-c0805b45a17f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('608011f9-82e5-47ef-ab8b-d19d91af3ff1', '609b2b48-2196-4c38-9f2d-b19e41999946', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('369b3080-a974-4a86-8ed0-e7cc0b200cf1', '7912eeca-7e8c-49e0-83b9-a70134824b1c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('369b3080-a974-4a86-8ed0-e7cc0b200cf1', '441a8a31-a623-4a31-bc69-e5796d01c0a2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('369b3080-a974-4a86-8ed0-e7cc0b200cf1', 'd878fd67-64f6-4fb5-a5d3-787955037782', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('369b3080-a974-4a86-8ed0-e7cc0b200cf1', 'c719c143-b0c3-4218-9efa-aad9c8e1e1cb', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('369b3080-a974-4a86-8ed0-e7cc0b200cf1', 'b88ddf87-6d95-41b9-aa76-38d3ab4ece4f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('38797c04-f268-4837-884b-1177dc3771ee', '463a9a8c-ac07-4935-a02c-febf8ca48a61', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('38797c04-f268-4837-884b-1177dc3771ee', '186ce481-4474-4657-90a2-b94c5f575b78', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('38797c04-f268-4837-884b-1177dc3771ee', 'ffe653fe-250c-414b-a93d-a6e0a3aa2d9b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('38797c04-f268-4837-884b-1177dc3771ee', 'a85255fe-1453-4159-817c-50b747e6fce2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bb61c189-4aa5-40ba-b3a1-a96c9dfbb33b', '5dd8e92a-2509-4744-8e2b-c0805b45a17f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bb61c189-4aa5-40ba-b3a1-a96c9dfbb33b', '609b2b48-2196-4c38-9f2d-b19e41999946', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bb61c189-4aa5-40ba-b3a1-a96c9dfbb33b', 'ad189d52-5b53-44de-8544-8be52393cd57', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bb61c189-4aa5-40ba-b3a1-a96c9dfbb33b', '4e12965f-01b2-4de4-bafe-851903f414f0', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bb61c189-4aa5-40ba-b3a1-a96c9dfbb33b', 'f6f5eb4b-4dfc-477c-84b2-8ecdbcd793eb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5dd8e92a-2509-4744-8e2b-c0805b45a17f', 'bb61c189-4aa5-40ba-b3a1-a96c9dfbb33b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5dd8e92a-2509-4744-8e2b-c0805b45a17f', '609b2b48-2196-4c38-9f2d-b19e41999946', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5dd8e92a-2509-4744-8e2b-c0805b45a17f', 'ad189d52-5b53-44de-8544-8be52393cd57', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5dd8e92a-2509-4744-8e2b-c0805b45a17f', '4e12965f-01b2-4de4-bafe-851903f414f0', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5dd8e92a-2509-4744-8e2b-c0805b45a17f', 'f6f5eb4b-4dfc-477c-84b2-8ecdbcd793eb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('609b2b48-2196-4c38-9f2d-b19e41999946', 'bb61c189-4aa5-40ba-b3a1-a96c9dfbb33b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('609b2b48-2196-4c38-9f2d-b19e41999946', '5dd8e92a-2509-4744-8e2b-c0805b45a17f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('609b2b48-2196-4c38-9f2d-b19e41999946', 'ad189d52-5b53-44de-8544-8be52393cd57', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('609b2b48-2196-4c38-9f2d-b19e41999946', '4e12965f-01b2-4de4-bafe-851903f414f0', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('609b2b48-2196-4c38-9f2d-b19e41999946', 'f6f5eb4b-4dfc-477c-84b2-8ecdbcd793eb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ad189d52-5b53-44de-8544-8be52393cd57', 'bb61c189-4aa5-40ba-b3a1-a96c9dfbb33b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ad189d52-5b53-44de-8544-8be52393cd57', '5dd8e92a-2509-4744-8e2b-c0805b45a17f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ad189d52-5b53-44de-8544-8be52393cd57', '609b2b48-2196-4c38-9f2d-b19e41999946', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ad189d52-5b53-44de-8544-8be52393cd57', '4e12965f-01b2-4de4-bafe-851903f414f0', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ad189d52-5b53-44de-8544-8be52393cd57', 'f6f5eb4b-4dfc-477c-84b2-8ecdbcd793eb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fb6a5d97-170a-4251-898b-c3ba9816f49c', 'f6f5eb4b-4dfc-477c-84b2-8ecdbcd793eb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fb6a5d97-170a-4251-898b-c3ba9816f49c', '608011f9-82e5-47ef-ab8b-d19d91af3ff1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fb6a5d97-170a-4251-898b-c3ba9816f49c', 'bb61c189-4aa5-40ba-b3a1-a96c9dfbb33b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fb6a5d97-170a-4251-898b-c3ba9816f49c', '5dd8e92a-2509-4744-8e2b-c0805b45a17f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fb6a5d97-170a-4251-898b-c3ba9816f49c', '609b2b48-2196-4c38-9f2d-b19e41999946', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4e12965f-01b2-4de4-bafe-851903f414f0', 'bb61c189-4aa5-40ba-b3a1-a96c9dfbb33b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4e12965f-01b2-4de4-bafe-851903f414f0', '5dd8e92a-2509-4744-8e2b-c0805b45a17f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4e12965f-01b2-4de4-bafe-851903f414f0', '609b2b48-2196-4c38-9f2d-b19e41999946', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4e12965f-01b2-4de4-bafe-851903f414f0', 'ad189d52-5b53-44de-8544-8be52393cd57', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4e12965f-01b2-4de4-bafe-851903f414f0', 'f6f5eb4b-4dfc-477c-84b2-8ecdbcd793eb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('52a68e9d-d224-47be-b7f8-5ae4221e927c', 'f6f5eb4b-4dfc-477c-84b2-8ecdbcd793eb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('52a68e9d-d224-47be-b7f8-5ae4221e927c', '608011f9-82e5-47ef-ab8b-d19d91af3ff1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('52a68e9d-d224-47be-b7f8-5ae4221e927c', 'bb61c189-4aa5-40ba-b3a1-a96c9dfbb33b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('52a68e9d-d224-47be-b7f8-5ae4221e927c', '5dd8e92a-2509-4744-8e2b-c0805b45a17f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('52a68e9d-d224-47be-b7f8-5ae4221e927c', '609b2b48-2196-4c38-9f2d-b19e41999946', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f337ca91-83b6-4c1d-ac12-12c2e87b8896', '463a9a8c-ac07-4935-a02c-febf8ca48a61', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f337ca91-83b6-4c1d-ac12-12c2e87b8896', '186ce481-4474-4657-90a2-b94c5f575b78', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f337ca91-83b6-4c1d-ac12-12c2e87b8896', 'ffe653fe-250c-414b-a93d-a6e0a3aa2d9b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f337ca91-83b6-4c1d-ac12-12c2e87b8896', 'a85255fe-1453-4159-817c-50b747e6fce2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6df478d8-18d0-4ff6-9eee-5b878e38fdac', '0121ae9b-726f-42a2-b6e6-23fbe940e162', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6df478d8-18d0-4ff6-9eee-5b878e38fdac', '80fd829b-8d60-4f8a-8615-8b883f09eedf', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6df478d8-18d0-4ff6-9eee-5b878e38fdac', '66d3bab4-78e2-4b64-a050-bf9f7b866c48', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6df478d8-18d0-4ff6-9eee-5b878e38fdac', 'bf9955b5-a4ef-44b8-8e31-a36f2117953c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6df478d8-18d0-4ff6-9eee-5b878e38fdac', '1ffc7539-1c58-4bcc-91b2-73ceecae84f6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('90cb2eb1-4578-40a2-9c67-853c4016c022', '0121ae9b-726f-42a2-b6e6-23fbe940e162', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('90cb2eb1-4578-40a2-9c67-853c4016c022', '80fd829b-8d60-4f8a-8615-8b883f09eedf', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('90cb2eb1-4578-40a2-9c67-853c4016c022', '66d3bab4-78e2-4b64-a050-bf9f7b866c48', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('90cb2eb1-4578-40a2-9c67-853c4016c022', 'bf9955b5-a4ef-44b8-8e31-a36f2117953c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('90cb2eb1-4578-40a2-9c67-853c4016c022', '1ffc7539-1c58-4bcc-91b2-73ceecae84f6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0121ae9b-726f-42a2-b6e6-23fbe940e162', '80fd829b-8d60-4f8a-8615-8b883f09eedf', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0121ae9b-726f-42a2-b6e6-23fbe940e162', '66d3bab4-78e2-4b64-a050-bf9f7b866c48', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0121ae9b-726f-42a2-b6e6-23fbe940e162', 'bf9955b5-a4ef-44b8-8e31-a36f2117953c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0121ae9b-726f-42a2-b6e6-23fbe940e162', '1ffc7539-1c58-4bcc-91b2-73ceecae84f6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0121ae9b-726f-42a2-b6e6-23fbe940e162', 'ff1cdeda-5be9-48cc-abfa-a11506c50aa1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('80fd829b-8d60-4f8a-8615-8b883f09eedf', '0121ae9b-726f-42a2-b6e6-23fbe940e162', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('80fd829b-8d60-4f8a-8615-8b883f09eedf', '66d3bab4-78e2-4b64-a050-bf9f7b866c48', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('80fd829b-8d60-4f8a-8615-8b883f09eedf', 'bf9955b5-a4ef-44b8-8e31-a36f2117953c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('80fd829b-8d60-4f8a-8615-8b883f09eedf', '1ffc7539-1c58-4bcc-91b2-73ceecae84f6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('80fd829b-8d60-4f8a-8615-8b883f09eedf', 'ff1cdeda-5be9-48cc-abfa-a11506c50aa1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('66d3bab4-78e2-4b64-a050-bf9f7b866c48', '0121ae9b-726f-42a2-b6e6-23fbe940e162', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('66d3bab4-78e2-4b64-a050-bf9f7b866c48', '80fd829b-8d60-4f8a-8615-8b883f09eedf', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('66d3bab4-78e2-4b64-a050-bf9f7b866c48', 'bf9955b5-a4ef-44b8-8e31-a36f2117953c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('66d3bab4-78e2-4b64-a050-bf9f7b866c48', '1ffc7539-1c58-4bcc-91b2-73ceecae84f6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('66d3bab4-78e2-4b64-a050-bf9f7b866c48', 'ff1cdeda-5be9-48cc-abfa-a11506c50aa1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bf9955b5-a4ef-44b8-8e31-a36f2117953c', '0121ae9b-726f-42a2-b6e6-23fbe940e162', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bf9955b5-a4ef-44b8-8e31-a36f2117953c', '80fd829b-8d60-4f8a-8615-8b883f09eedf', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bf9955b5-a4ef-44b8-8e31-a36f2117953c', '66d3bab4-78e2-4b64-a050-bf9f7b866c48', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bf9955b5-a4ef-44b8-8e31-a36f2117953c', '1ffc7539-1c58-4bcc-91b2-73ceecae84f6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bf9955b5-a4ef-44b8-8e31-a36f2117953c', 'ff1cdeda-5be9-48cc-abfa-a11506c50aa1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ffc7539-1c58-4bcc-91b2-73ceecae84f6', '0121ae9b-726f-42a2-b6e6-23fbe940e162', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ffc7539-1c58-4bcc-91b2-73ceecae84f6', '80fd829b-8d60-4f8a-8615-8b883f09eedf', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ffc7539-1c58-4bcc-91b2-73ceecae84f6', '66d3bab4-78e2-4b64-a050-bf9f7b866c48', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ffc7539-1c58-4bcc-91b2-73ceecae84f6', 'bf9955b5-a4ef-44b8-8e31-a36f2117953c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1ffc7539-1c58-4bcc-91b2-73ceecae84f6', 'ff1cdeda-5be9-48cc-abfa-a11506c50aa1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ff1cdeda-5be9-48cc-abfa-a11506c50aa1', '0121ae9b-726f-42a2-b6e6-23fbe940e162', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ff1cdeda-5be9-48cc-abfa-a11506c50aa1', '80fd829b-8d60-4f8a-8615-8b883f09eedf', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ff1cdeda-5be9-48cc-abfa-a11506c50aa1', '66d3bab4-78e2-4b64-a050-bf9f7b866c48', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ff1cdeda-5be9-48cc-abfa-a11506c50aa1', 'bf9955b5-a4ef-44b8-8e31-a36f2117953c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ff1cdeda-5be9-48cc-abfa-a11506c50aa1', '1ffc7539-1c58-4bcc-91b2-73ceecae84f6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d295c94-59db-4717-98ee-a18f1e4c03b1', '0121ae9b-726f-42a2-b6e6-23fbe940e162', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d295c94-59db-4717-98ee-a18f1e4c03b1', '80fd829b-8d60-4f8a-8615-8b883f09eedf', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d295c94-59db-4717-98ee-a18f1e4c03b1', '66d3bab4-78e2-4b64-a050-bf9f7b866c48', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d295c94-59db-4717-98ee-a18f1e4c03b1', 'bf9955b5-a4ef-44b8-8e31-a36f2117953c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d295c94-59db-4717-98ee-a18f1e4c03b1', '1ffc7539-1c58-4bcc-91b2-73ceecae84f6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39e10252-78e1-49e9-b249-8cd4a9e9b481', 'e0873193-0059-4fd8-aeba-19b4ad084dd2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39e10252-78e1-49e9-b249-8cd4a9e9b481', 'cec4e075-5a93-4dc5-b98a-fde7ce46eb30', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39e10252-78e1-49e9-b249-8cd4a9e9b481', 'fbe2da22-974d-44a8-87f4-2eb2ae1869c7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39e10252-78e1-49e9-b249-8cd4a9e9b481', '71be87fc-cc76-43fd-a6ac-306ac664d21d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39e10252-78e1-49e9-b249-8cd4a9e9b481', 'e2dc9ef0-edb5-47af-a3d3-595d88f98b14', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e0873193-0059-4fd8-aeba-19b4ad084dd2', '39e10252-78e1-49e9-b249-8cd4a9e9b481', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e0873193-0059-4fd8-aeba-19b4ad084dd2', 'cec4e075-5a93-4dc5-b98a-fde7ce46eb30', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e0873193-0059-4fd8-aeba-19b4ad084dd2', 'fbe2da22-974d-44a8-87f4-2eb2ae1869c7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e0873193-0059-4fd8-aeba-19b4ad084dd2', '71be87fc-cc76-43fd-a6ac-306ac664d21d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e0873193-0059-4fd8-aeba-19b4ad084dd2', 'e2dc9ef0-edb5-47af-a3d3-595d88f98b14', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cec4e075-5a93-4dc5-b98a-fde7ce46eb30', '39e10252-78e1-49e9-b249-8cd4a9e9b481', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cec4e075-5a93-4dc5-b98a-fde7ce46eb30', 'e0873193-0059-4fd8-aeba-19b4ad084dd2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cec4e075-5a93-4dc5-b98a-fde7ce46eb30', 'fbe2da22-974d-44a8-87f4-2eb2ae1869c7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cec4e075-5a93-4dc5-b98a-fde7ce46eb30', '71be87fc-cc76-43fd-a6ac-306ac664d21d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cec4e075-5a93-4dc5-b98a-fde7ce46eb30', 'e2dc9ef0-edb5-47af-a3d3-595d88f98b14', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fbe2da22-974d-44a8-87f4-2eb2ae1869c7', '39e10252-78e1-49e9-b249-8cd4a9e9b481', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fbe2da22-974d-44a8-87f4-2eb2ae1869c7', 'e0873193-0059-4fd8-aeba-19b4ad084dd2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fbe2da22-974d-44a8-87f4-2eb2ae1869c7', 'cec4e075-5a93-4dc5-b98a-fde7ce46eb30', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fbe2da22-974d-44a8-87f4-2eb2ae1869c7', '71be87fc-cc76-43fd-a6ac-306ac664d21d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fbe2da22-974d-44a8-87f4-2eb2ae1869c7', 'e2dc9ef0-edb5-47af-a3d3-595d88f98b14', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('71be87fc-cc76-43fd-a6ac-306ac664d21d', '39e10252-78e1-49e9-b249-8cd4a9e9b481', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('71be87fc-cc76-43fd-a6ac-306ac664d21d', 'e0873193-0059-4fd8-aeba-19b4ad084dd2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('71be87fc-cc76-43fd-a6ac-306ac664d21d', 'cec4e075-5a93-4dc5-b98a-fde7ce46eb30', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('71be87fc-cc76-43fd-a6ac-306ac664d21d', 'fbe2da22-974d-44a8-87f4-2eb2ae1869c7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('71be87fc-cc76-43fd-a6ac-306ac664d21d', 'e2dc9ef0-edb5-47af-a3d3-595d88f98b14', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e2dc9ef0-edb5-47af-a3d3-595d88f98b14', '39e10252-78e1-49e9-b249-8cd4a9e9b481', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e2dc9ef0-edb5-47af-a3d3-595d88f98b14', 'e0873193-0059-4fd8-aeba-19b4ad084dd2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e2dc9ef0-edb5-47af-a3d3-595d88f98b14', 'cec4e075-5a93-4dc5-b98a-fde7ce46eb30', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e2dc9ef0-edb5-47af-a3d3-595d88f98b14', 'fbe2da22-974d-44a8-87f4-2eb2ae1869c7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e2dc9ef0-edb5-47af-a3d3-595d88f98b14', '71be87fc-cc76-43fd-a6ac-306ac664d21d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5a40b6e0-d66a-4220-a411-c6ec717955dd', '39e10252-78e1-49e9-b249-8cd4a9e9b481', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5a40b6e0-d66a-4220-a411-c6ec717955dd', 'e0873193-0059-4fd8-aeba-19b4ad084dd2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5a40b6e0-d66a-4220-a411-c6ec717955dd', 'cec4e075-5a93-4dc5-b98a-fde7ce46eb30', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5a40b6e0-d66a-4220-a411-c6ec717955dd', 'fbe2da22-974d-44a8-87f4-2eb2ae1869c7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5a40b6e0-d66a-4220-a411-c6ec717955dd', '71be87fc-cc76-43fd-a6ac-306ac664d21d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d77ae08b-8e56-4e53-a839-ba52ca9a589b', '39e10252-78e1-49e9-b249-8cd4a9e9b481', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d77ae08b-8e56-4e53-a839-ba52ca9a589b', 'e0873193-0059-4fd8-aeba-19b4ad084dd2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d77ae08b-8e56-4e53-a839-ba52ca9a589b', 'cec4e075-5a93-4dc5-b98a-fde7ce46eb30', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d77ae08b-8e56-4e53-a839-ba52ca9a589b', 'fbe2da22-974d-44a8-87f4-2eb2ae1869c7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d77ae08b-8e56-4e53-a839-ba52ca9a589b', '71be87fc-cc76-43fd-a6ac-306ac664d21d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2f2f1c9d-f6c9-40fb-ab9d-eb2e42d2351e', '50a0e624-b48e-4a1f-bb0f-a06b5fd5ec4c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2f2f1c9d-f6c9-40fb-ab9d-eb2e42d2351e', '39e10252-78e1-49e9-b249-8cd4a9e9b481', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2f2f1c9d-f6c9-40fb-ab9d-eb2e42d2351e', 'e0873193-0059-4fd8-aeba-19b4ad084dd2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2f2f1c9d-f6c9-40fb-ab9d-eb2e42d2351e', 'cec4e075-5a93-4dc5-b98a-fde7ce46eb30', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2f2f1c9d-f6c9-40fb-ab9d-eb2e42d2351e', 'fbe2da22-974d-44a8-87f4-2eb2ae1869c7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3bcaf688-1aee-416f-bcd5-62010321a652', '0121ae9b-726f-42a2-b6e6-23fbe940e162', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3bcaf688-1aee-416f-bcd5-62010321a652', '80fd829b-8d60-4f8a-8615-8b883f09eedf', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3bcaf688-1aee-416f-bcd5-62010321a652', '66d3bab4-78e2-4b64-a050-bf9f7b866c48', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3bcaf688-1aee-416f-bcd5-62010321a652', 'bf9955b5-a4ef-44b8-8e31-a36f2117953c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3bcaf688-1aee-416f-bcd5-62010321a652', '1ffc7539-1c58-4bcc-91b2-73ceecae84f6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('50a0e624-b48e-4a1f-bb0f-a06b5fd5ec4c', '2f2f1c9d-f6c9-40fb-ab9d-eb2e42d2351e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('50a0e624-b48e-4a1f-bb0f-a06b5fd5ec4c', '39e10252-78e1-49e9-b249-8cd4a9e9b481', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('50a0e624-b48e-4a1f-bb0f-a06b5fd5ec4c', 'e0873193-0059-4fd8-aeba-19b4ad084dd2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('50a0e624-b48e-4a1f-bb0f-a06b5fd5ec4c', 'cec4e075-5a93-4dc5-b98a-fde7ce46eb30', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('50a0e624-b48e-4a1f-bb0f-a06b5fd5ec4c', 'fbe2da22-974d-44a8-87f4-2eb2ae1869c7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('70bfb7df-7fb6-4f33-936c-228f89427161', '0ceb1310-a66b-4372-ba3f-ed6460911784', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('70bfb7df-7fb6-4f33-936c-228f89427161', 'df035e48-d887-4833-b5f0-816c6cefe488', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('70bfb7df-7fb6-4f33-936c-228f89427161', '51938cc6-a925-4c3c-b770-591527f607f9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('70bfb7df-7fb6-4f33-936c-228f89427161', '586a44f6-4219-48b0-9875-219f4018e447', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('70bfb7df-7fb6-4f33-936c-228f89427161', 'c6e6bdbc-12aa-4600-bb6b-2ad072e25d6f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0ceb1310-a66b-4372-ba3f-ed6460911784', '70bfb7df-7fb6-4f33-936c-228f89427161', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0ceb1310-a66b-4372-ba3f-ed6460911784', 'df035e48-d887-4833-b5f0-816c6cefe488', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0ceb1310-a66b-4372-ba3f-ed6460911784', '51938cc6-a925-4c3c-b770-591527f607f9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0ceb1310-a66b-4372-ba3f-ed6460911784', '586a44f6-4219-48b0-9875-219f4018e447', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0ceb1310-a66b-4372-ba3f-ed6460911784', 'c6e6bdbc-12aa-4600-bb6b-2ad072e25d6f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('df035e48-d887-4833-b5f0-816c6cefe488', '70bfb7df-7fb6-4f33-936c-228f89427161', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('df035e48-d887-4833-b5f0-816c6cefe488', '0ceb1310-a66b-4372-ba3f-ed6460911784', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('df035e48-d887-4833-b5f0-816c6cefe488', '51938cc6-a925-4c3c-b770-591527f607f9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('df035e48-d887-4833-b5f0-816c6cefe488', '586a44f6-4219-48b0-9875-219f4018e447', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('df035e48-d887-4833-b5f0-816c6cefe488', 'c6e6bdbc-12aa-4600-bb6b-2ad072e25d6f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('51938cc6-a925-4c3c-b770-591527f607f9', '70bfb7df-7fb6-4f33-936c-228f89427161', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('51938cc6-a925-4c3c-b770-591527f607f9', '0ceb1310-a66b-4372-ba3f-ed6460911784', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('51938cc6-a925-4c3c-b770-591527f607f9', 'df035e48-d887-4833-b5f0-816c6cefe488', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('51938cc6-a925-4c3c-b770-591527f607f9', '586a44f6-4219-48b0-9875-219f4018e447', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('51938cc6-a925-4c3c-b770-591527f607f9', 'c6e6bdbc-12aa-4600-bb6b-2ad072e25d6f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('586a44f6-4219-48b0-9875-219f4018e447', '70bfb7df-7fb6-4f33-936c-228f89427161', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('586a44f6-4219-48b0-9875-219f4018e447', '0ceb1310-a66b-4372-ba3f-ed6460911784', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('586a44f6-4219-48b0-9875-219f4018e447', 'df035e48-d887-4833-b5f0-816c6cefe488', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('586a44f6-4219-48b0-9875-219f4018e447', '51938cc6-a925-4c3c-b770-591527f607f9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('586a44f6-4219-48b0-9875-219f4018e447', 'c6e6bdbc-12aa-4600-bb6b-2ad072e25d6f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2a36dd8d-183a-494c-ae38-bc04647f7bb2', '70bfb7df-7fb6-4f33-936c-228f89427161', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2a36dd8d-183a-494c-ae38-bc04647f7bb2', '0ceb1310-a66b-4372-ba3f-ed6460911784', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2a36dd8d-183a-494c-ae38-bc04647f7bb2', 'df035e48-d887-4833-b5f0-816c6cefe488', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2a36dd8d-183a-494c-ae38-bc04647f7bb2', '51938cc6-a925-4c3c-b770-591527f607f9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2a36dd8d-183a-494c-ae38-bc04647f7bb2', '586a44f6-4219-48b0-9875-219f4018e447', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6e6bdbc-12aa-4600-bb6b-2ad072e25d6f', '70bfb7df-7fb6-4f33-936c-228f89427161', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6e6bdbc-12aa-4600-bb6b-2ad072e25d6f', '0ceb1310-a66b-4372-ba3f-ed6460911784', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6e6bdbc-12aa-4600-bb6b-2ad072e25d6f', 'df035e48-d887-4833-b5f0-816c6cefe488', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6e6bdbc-12aa-4600-bb6b-2ad072e25d6f', '51938cc6-a925-4c3c-b770-591527f607f9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6e6bdbc-12aa-4600-bb6b-2ad072e25d6f', '586a44f6-4219-48b0-9875-219f4018e447', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84089b63-30d4-453b-84d9-cb6654a5dbc4', '70bfb7df-7fb6-4f33-936c-228f89427161', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84089b63-30d4-453b-84d9-cb6654a5dbc4', '0ceb1310-a66b-4372-ba3f-ed6460911784', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84089b63-30d4-453b-84d9-cb6654a5dbc4', 'df035e48-d887-4833-b5f0-816c6cefe488', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84089b63-30d4-453b-84d9-cb6654a5dbc4', '51938cc6-a925-4c3c-b770-591527f607f9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84089b63-30d4-453b-84d9-cb6654a5dbc4', '586a44f6-4219-48b0-9875-219f4018e447', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3448c18f-dce9-4937-83c0-3ebd52f601b3', '70bfb7df-7fb6-4f33-936c-228f89427161', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3448c18f-dce9-4937-83c0-3ebd52f601b3', '0ceb1310-a66b-4372-ba3f-ed6460911784', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3448c18f-dce9-4937-83c0-3ebd52f601b3', 'df035e48-d887-4833-b5f0-816c6cefe488', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3448c18f-dce9-4937-83c0-3ebd52f601b3', '51938cc6-a925-4c3c-b770-591527f607f9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3448c18f-dce9-4937-83c0-3ebd52f601b3', '586a44f6-4219-48b0-9875-219f4018e447', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f888ac34-e35a-420b-a616-93f4c2b08822', 'd3bd2143-66a5-4f40-baa6-55ec7be87f50', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f888ac34-e35a-420b-a616-93f4c2b08822', '2d5fe2c4-636c-44de-96fd-f47488224a32', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f888ac34-e35a-420b-a616-93f4c2b08822', '70bfb7df-7fb6-4f33-936c-228f89427161', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f888ac34-e35a-420b-a616-93f4c2b08822', '0ceb1310-a66b-4372-ba3f-ed6460911784', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f888ac34-e35a-420b-a616-93f4c2b08822', 'df035e48-d887-4833-b5f0-816c6cefe488', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3bd2143-66a5-4f40-baa6-55ec7be87f50', 'f888ac34-e35a-420b-a616-93f4c2b08822', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3bd2143-66a5-4f40-baa6-55ec7be87f50', '2d5fe2c4-636c-44de-96fd-f47488224a32', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3bd2143-66a5-4f40-baa6-55ec7be87f50', '70bfb7df-7fb6-4f33-936c-228f89427161', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3bd2143-66a5-4f40-baa6-55ec7be87f50', '0ceb1310-a66b-4372-ba3f-ed6460911784', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3bd2143-66a5-4f40-baa6-55ec7be87f50', 'df035e48-d887-4833-b5f0-816c6cefe488', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d5fe2c4-636c-44de-96fd-f47488224a32', 'f888ac34-e35a-420b-a616-93f4c2b08822', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d5fe2c4-636c-44de-96fd-f47488224a32', 'd3bd2143-66a5-4f40-baa6-55ec7be87f50', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d5fe2c4-636c-44de-96fd-f47488224a32', '70bfb7df-7fb6-4f33-936c-228f89427161', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d5fe2c4-636c-44de-96fd-f47488224a32', '0ceb1310-a66b-4372-ba3f-ed6460911784', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d5fe2c4-636c-44de-96fd-f47488224a32', 'df035e48-d887-4833-b5f0-816c6cefe488', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d7ee715-48f0-4c9e-bee9-a04bdfe0ba6a', '70bfb7df-7fb6-4f33-936c-228f89427161', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d7ee715-48f0-4c9e-bee9-a04bdfe0ba6a', '0ceb1310-a66b-4372-ba3f-ed6460911784', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d7ee715-48f0-4c9e-bee9-a04bdfe0ba6a', 'df035e48-d887-4833-b5f0-816c6cefe488', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d7ee715-48f0-4c9e-bee9-a04bdfe0ba6a', '51938cc6-a925-4c3c-b770-591527f607f9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d7ee715-48f0-4c9e-bee9-a04bdfe0ba6a', '586a44f6-4219-48b0-9875-219f4018e447', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6a7d269f-8122-4262-b81c-8f8f1a299faf', '4c2727b3-650d-42c8-8eeb-bd27bcbd8cbb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6a7d269f-8122-4262-b81c-8f8f1a299faf', '70bfb7df-7fb6-4f33-936c-228f89427161', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6a7d269f-8122-4262-b81c-8f8f1a299faf', '0ceb1310-a66b-4372-ba3f-ed6460911784', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('973b0498-1000-4011-9bb1-c71d8964f6a7', '70bfb7df-7fb6-4f33-936c-228f89427161', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('973b0498-1000-4011-9bb1-c71d8964f6a7', '0ceb1310-a66b-4372-ba3f-ed6460911784', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('973b0498-1000-4011-9bb1-c71d8964f6a7', 'df035e48-d887-4833-b5f0-816c6cefe488', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('973b0498-1000-4011-9bb1-c71d8964f6a7', '51938cc6-a925-4c3c-b770-591527f607f9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('973b0498-1000-4011-9bb1-c71d8964f6a7', '586a44f6-4219-48b0-9875-219f4018e447', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c2727b3-650d-42c8-8eeb-bd27bcbd8cbb', '6a7d269f-8122-4262-b81c-8f8f1a299faf', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c2727b3-650d-42c8-8eeb-bd27bcbd8cbb', '70bfb7df-7fb6-4f33-936c-228f89427161', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c2727b3-650d-42c8-8eeb-bd27bcbd8cbb', '0ceb1310-a66b-4372-ba3f-ed6460911784', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d0c9678b-3e0f-4e7c-8840-80ecd490dd3e', '70bfb7df-7fb6-4f33-936c-228f89427161', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d0c9678b-3e0f-4e7c-8840-80ecd490dd3e', '0ceb1310-a66b-4372-ba3f-ed6460911784', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d0c9678b-3e0f-4e7c-8840-80ecd490dd3e', 'df035e48-d887-4833-b5f0-816c6cefe488', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d0c9678b-3e0f-4e7c-8840-80ecd490dd3e', '51938cc6-a925-4c3c-b770-591527f607f9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d0c9678b-3e0f-4e7c-8840-80ecd490dd3e', '586a44f6-4219-48b0-9875-219f4018e447', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f030a6bb-a478-403e-bd6d-fca0063cdc0c', '70bfb7df-7fb6-4f33-936c-228f89427161', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f030a6bb-a478-403e-bd6d-fca0063cdc0c', '0ceb1310-a66b-4372-ba3f-ed6460911784', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f030a6bb-a478-403e-bd6d-fca0063cdc0c', 'df035e48-d887-4833-b5f0-816c6cefe488', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f030a6bb-a478-403e-bd6d-fca0063cdc0c', '51938cc6-a925-4c3c-b770-591527f607f9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f030a6bb-a478-403e-bd6d-fca0063cdc0c', '586a44f6-4219-48b0-9875-219f4018e447', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f415690e-17d7-431e-834d-ea26bf6040d4', '9ebbe40d-0597-49aa-9529-38657204588c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f415690e-17d7-431e-834d-ea26bf6040d4', '86bdd100-6cd3-432c-bff2-7f4cf8a54795', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f415690e-17d7-431e-834d-ea26bf6040d4', 'c7d13b11-e9ea-4932-a3c9-190de5337daa', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f415690e-17d7-431e-834d-ea26bf6040d4', '4fa60160-a11f-436c-a11c-dc2de1318142', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f415690e-17d7-431e-834d-ea26bf6040d4', 'ae7d002c-4077-4e0a-b842-d6c4435e04d3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ebbe40d-0597-49aa-9529-38657204588c', 'f415690e-17d7-431e-834d-ea26bf6040d4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ebbe40d-0597-49aa-9529-38657204588c', '86bdd100-6cd3-432c-bff2-7f4cf8a54795', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ebbe40d-0597-49aa-9529-38657204588c', 'c7d13b11-e9ea-4932-a3c9-190de5337daa', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ebbe40d-0597-49aa-9529-38657204588c', '4fa60160-a11f-436c-a11c-dc2de1318142', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ebbe40d-0597-49aa-9529-38657204588c', 'ae7d002c-4077-4e0a-b842-d6c4435e04d3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('86bdd100-6cd3-432c-bff2-7f4cf8a54795', 'f415690e-17d7-431e-834d-ea26bf6040d4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('86bdd100-6cd3-432c-bff2-7f4cf8a54795', '9ebbe40d-0597-49aa-9529-38657204588c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('86bdd100-6cd3-432c-bff2-7f4cf8a54795', 'c7d13b11-e9ea-4932-a3c9-190de5337daa', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('86bdd100-6cd3-432c-bff2-7f4cf8a54795', '4fa60160-a11f-436c-a11c-dc2de1318142', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('86bdd100-6cd3-432c-bff2-7f4cf8a54795', 'ae7d002c-4077-4e0a-b842-d6c4435e04d3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c7d13b11-e9ea-4932-a3c9-190de5337daa', '4fa60160-a11f-436c-a11c-dc2de1318142', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c7d13b11-e9ea-4932-a3c9-190de5337daa', 'ae7d002c-4077-4e0a-b842-d6c4435e04d3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c7d13b11-e9ea-4932-a3c9-190de5337daa', '026279a4-e80e-4378-b8ad-e6cd58900af4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c7d13b11-e9ea-4932-a3c9-190de5337daa', 'f53efd70-955a-4a39-8b80-7fe9bc531c8a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c7d13b11-e9ea-4932-a3c9-190de5337daa', 'a2119abd-555e-4f27-b509-aa8212405611', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('76356866-3fa5-4f6a-97d3-ae94cea75eb3', 'e371b332-8d42-4605-9301-8b930665d01b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('76356866-3fa5-4f6a-97d3-ae94cea75eb3', 'f63b1de7-621a-44d9-9e2d-6fcd83395dd0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('76356866-3fa5-4f6a-97d3-ae94cea75eb3', '94ab28eb-f6ac-4a65-a59f-281fa30dc92d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4fa60160-a11f-436c-a11c-dc2de1318142', 'c7d13b11-e9ea-4932-a3c9-190de5337daa', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4fa60160-a11f-436c-a11c-dc2de1318142', 'ae7d002c-4077-4e0a-b842-d6c4435e04d3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4fa60160-a11f-436c-a11c-dc2de1318142', '026279a4-e80e-4378-b8ad-e6cd58900af4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4fa60160-a11f-436c-a11c-dc2de1318142', 'f53efd70-955a-4a39-8b80-7fe9bc531c8a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4fa60160-a11f-436c-a11c-dc2de1318142', 'a2119abd-555e-4f27-b509-aa8212405611', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ae7d002c-4077-4e0a-b842-d6c4435e04d3', 'c7d13b11-e9ea-4932-a3c9-190de5337daa', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ae7d002c-4077-4e0a-b842-d6c4435e04d3', '4fa60160-a11f-436c-a11c-dc2de1318142', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ae7d002c-4077-4e0a-b842-d6c4435e04d3', '026279a4-e80e-4378-b8ad-e6cd58900af4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ae7d002c-4077-4e0a-b842-d6c4435e04d3', 'f53efd70-955a-4a39-8b80-7fe9bc531c8a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ae7d002c-4077-4e0a-b842-d6c4435e04d3', 'a2119abd-555e-4f27-b509-aa8212405611', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('026279a4-e80e-4378-b8ad-e6cd58900af4', 'c7d13b11-e9ea-4932-a3c9-190de5337daa', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('026279a4-e80e-4378-b8ad-e6cd58900af4', '4fa60160-a11f-436c-a11c-dc2de1318142', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('026279a4-e80e-4378-b8ad-e6cd58900af4', 'ae7d002c-4077-4e0a-b842-d6c4435e04d3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('026279a4-e80e-4378-b8ad-e6cd58900af4', 'f53efd70-955a-4a39-8b80-7fe9bc531c8a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('026279a4-e80e-4378-b8ad-e6cd58900af4', 'a2119abd-555e-4f27-b509-aa8212405611', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f53efd70-955a-4a39-8b80-7fe9bc531c8a', 'c7d13b11-e9ea-4932-a3c9-190de5337daa', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f53efd70-955a-4a39-8b80-7fe9bc531c8a', '4fa60160-a11f-436c-a11c-dc2de1318142', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f53efd70-955a-4a39-8b80-7fe9bc531c8a', 'ae7d002c-4077-4e0a-b842-d6c4435e04d3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f53efd70-955a-4a39-8b80-7fe9bc531c8a', '026279a4-e80e-4378-b8ad-e6cd58900af4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f53efd70-955a-4a39-8b80-7fe9bc531c8a', 'a2119abd-555e-4f27-b509-aa8212405611', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a2119abd-555e-4f27-b509-aa8212405611', 'c7d13b11-e9ea-4932-a3c9-190de5337daa', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a2119abd-555e-4f27-b509-aa8212405611', '4fa60160-a11f-436c-a11c-dc2de1318142', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a2119abd-555e-4f27-b509-aa8212405611', 'ae7d002c-4077-4e0a-b842-d6c4435e04d3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a2119abd-555e-4f27-b509-aa8212405611', '026279a4-e80e-4378-b8ad-e6cd58900af4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a2119abd-555e-4f27-b509-aa8212405611', 'f53efd70-955a-4a39-8b80-7fe9bc531c8a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d4accc26-ddcd-4bfb-b141-f24bdfb2e503', 'c7d13b11-e9ea-4932-a3c9-190de5337daa', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d4accc26-ddcd-4bfb-b141-f24bdfb2e503', '4fa60160-a11f-436c-a11c-dc2de1318142', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d4accc26-ddcd-4bfb-b141-f24bdfb2e503', 'ae7d002c-4077-4e0a-b842-d6c4435e04d3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d4accc26-ddcd-4bfb-b141-f24bdfb2e503', '026279a4-e80e-4378-b8ad-e6cd58900af4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d4accc26-ddcd-4bfb-b141-f24bdfb2e503', 'f53efd70-955a-4a39-8b80-7fe9bc531c8a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4dd9656c-ea67-4f9a-b3e0-b5a37a8b85de', 'c7d13b11-e9ea-4932-a3c9-190de5337daa', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4dd9656c-ea67-4f9a-b3e0-b5a37a8b85de', '4fa60160-a11f-436c-a11c-dc2de1318142', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4dd9656c-ea67-4f9a-b3e0-b5a37a8b85de', 'ae7d002c-4077-4e0a-b842-d6c4435e04d3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4dd9656c-ea67-4f9a-b3e0-b5a37a8b85de', '026279a4-e80e-4378-b8ad-e6cd58900af4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4dd9656c-ea67-4f9a-b3e0-b5a37a8b85de', 'f53efd70-955a-4a39-8b80-7fe9bc531c8a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('656f14bb-921d-4775-ade6-70e408adcecf', 'c7d13b11-e9ea-4932-a3c9-190de5337daa', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('656f14bb-921d-4775-ade6-70e408adcecf', '4fa60160-a11f-436c-a11c-dc2de1318142', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('656f14bb-921d-4775-ade6-70e408adcecf', 'ae7d002c-4077-4e0a-b842-d6c4435e04d3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('656f14bb-921d-4775-ade6-70e408adcecf', '026279a4-e80e-4378-b8ad-e6cd58900af4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('656f14bb-921d-4775-ade6-70e408adcecf', 'f53efd70-955a-4a39-8b80-7fe9bc531c8a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a109ae7f-2ca1-41e3-980f-18ed97b2d87c', 'c7d13b11-e9ea-4932-a3c9-190de5337daa', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a109ae7f-2ca1-41e3-980f-18ed97b2d87c', '4fa60160-a11f-436c-a11c-dc2de1318142', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a109ae7f-2ca1-41e3-980f-18ed97b2d87c', 'ae7d002c-4077-4e0a-b842-d6c4435e04d3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a109ae7f-2ca1-41e3-980f-18ed97b2d87c', '026279a4-e80e-4378-b8ad-e6cd58900af4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a109ae7f-2ca1-41e3-980f-18ed97b2d87c', 'f53efd70-955a-4a39-8b80-7fe9bc531c8a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ec467b59-368a-4bc4-b873-74596a085f47', 'f415690e-17d7-431e-834d-ea26bf6040d4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ec467b59-368a-4bc4-b873-74596a085f47', '9ebbe40d-0597-49aa-9529-38657204588c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ec467b59-368a-4bc4-b873-74596a085f47', '86bdd100-6cd3-432c-bff2-7f4cf8a54795', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ec467b59-368a-4bc4-b873-74596a085f47', 'c7d13b11-e9ea-4932-a3c9-190de5337daa', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ec467b59-368a-4bc4-b873-74596a085f47', '4fa60160-a11f-436c-a11c-dc2de1318142', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1e27de44-887f-40a7-a123-47f19cfcd868', '620fdf9b-7dc6-4968-8b42-0878c8c889ad', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1e27de44-887f-40a7-a123-47f19cfcd868', '6bbd8401-9a32-4b9a-85e5-1d0c4c870288', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1e27de44-887f-40a7-a123-47f19cfcd868', 'd798681b-5dce-4270-853d-5b13da979595', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1e27de44-887f-40a7-a123-47f19cfcd868', '369f656a-9772-4d4e-a533-e5978e220941', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1e27de44-887f-40a7-a123-47f19cfcd868', '2366ca86-c838-42b7-baea-0456952f73c2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('620fdf9b-7dc6-4968-8b42-0878c8c889ad', '1e27de44-887f-40a7-a123-47f19cfcd868', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('620fdf9b-7dc6-4968-8b42-0878c8c889ad', '6bbd8401-9a32-4b9a-85e5-1d0c4c870288', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('620fdf9b-7dc6-4968-8b42-0878c8c889ad', 'd798681b-5dce-4270-853d-5b13da979595', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('620fdf9b-7dc6-4968-8b42-0878c8c889ad', '369f656a-9772-4d4e-a533-e5978e220941', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('620fdf9b-7dc6-4968-8b42-0878c8c889ad', '2366ca86-c838-42b7-baea-0456952f73c2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d5d6b7d3-2d56-4db0-aca0-3543c119911a', '620fdf9b-7dc6-4968-8b42-0878c8c889ad', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d5d6b7d3-2d56-4db0-aca0-3543c119911a', '1e27de44-887f-40a7-a123-47f19cfcd868', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d5d6b7d3-2d56-4db0-aca0-3543c119911a', '6bbd8401-9a32-4b9a-85e5-1d0c4c870288', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d5d6b7d3-2d56-4db0-aca0-3543c119911a', 'd798681b-5dce-4270-853d-5b13da979595', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d5d6b7d3-2d56-4db0-aca0-3543c119911a', '369f656a-9772-4d4e-a533-e5978e220941', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6bbd8401-9a32-4b9a-85e5-1d0c4c870288', '65fab8f1-a21f-4db5-931c-0f31f5a3ee62', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6bbd8401-9a32-4b9a-85e5-1d0c4c870288', '80349409-5b48-483f-9cbe-936d552ea595', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6bbd8401-9a32-4b9a-85e5-1d0c4c870288', '3900b9b4-75f3-4a5e-8956-6e76df418eca', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6bbd8401-9a32-4b9a-85e5-1d0c4c870288', '1e27de44-887f-40a7-a123-47f19cfcd868', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6bbd8401-9a32-4b9a-85e5-1d0c4c870288', '620fdf9b-7dc6-4968-8b42-0878c8c889ad', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d798681b-5dce-4270-853d-5b13da979595', '369f656a-9772-4d4e-a533-e5978e220941', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d798681b-5dce-4270-853d-5b13da979595', '2366ca86-c838-42b7-baea-0456952f73c2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d798681b-5dce-4270-853d-5b13da979595', 'e1445303-174b-4510-848b-325d96e00e34', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d798681b-5dce-4270-853d-5b13da979595', '8e55cb37-1421-45a5-bf37-22582bc35800', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d798681b-5dce-4270-853d-5b13da979595', '1e27de44-887f-40a7-a123-47f19cfcd868', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('369f656a-9772-4d4e-a533-e5978e220941', 'd798681b-5dce-4270-853d-5b13da979595', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('369f656a-9772-4d4e-a533-e5978e220941', '2366ca86-c838-42b7-baea-0456952f73c2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('369f656a-9772-4d4e-a533-e5978e220941', 'e1445303-174b-4510-848b-325d96e00e34', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('369f656a-9772-4d4e-a533-e5978e220941', '8e55cb37-1421-45a5-bf37-22582bc35800', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('369f656a-9772-4d4e-a533-e5978e220941', '1e27de44-887f-40a7-a123-47f19cfcd868', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2366ca86-c838-42b7-baea-0456952f73c2', 'd798681b-5dce-4270-853d-5b13da979595', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2366ca86-c838-42b7-baea-0456952f73c2', '369f656a-9772-4d4e-a533-e5978e220941', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2366ca86-c838-42b7-baea-0456952f73c2', 'e1445303-174b-4510-848b-325d96e00e34', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2366ca86-c838-42b7-baea-0456952f73c2', '8e55cb37-1421-45a5-bf37-22582bc35800', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2366ca86-c838-42b7-baea-0456952f73c2', '1e27de44-887f-40a7-a123-47f19cfcd868', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('65fab8f1-a21f-4db5-931c-0f31f5a3ee62', '6bbd8401-9a32-4b9a-85e5-1d0c4c870288', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('65fab8f1-a21f-4db5-931c-0f31f5a3ee62', '80349409-5b48-483f-9cbe-936d552ea595', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('65fab8f1-a21f-4db5-931c-0f31f5a3ee62', '3900b9b4-75f3-4a5e-8956-6e76df418eca', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('65fab8f1-a21f-4db5-931c-0f31f5a3ee62', '1e27de44-887f-40a7-a123-47f19cfcd868', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('65fab8f1-a21f-4db5-931c-0f31f5a3ee62', '620fdf9b-7dc6-4968-8b42-0878c8c889ad', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('80349409-5b48-483f-9cbe-936d552ea595', '6bbd8401-9a32-4b9a-85e5-1d0c4c870288', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('80349409-5b48-483f-9cbe-936d552ea595', '65fab8f1-a21f-4db5-931c-0f31f5a3ee62', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('80349409-5b48-483f-9cbe-936d552ea595', '3900b9b4-75f3-4a5e-8956-6e76df418eca', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('80349409-5b48-483f-9cbe-936d552ea595', '1e27de44-887f-40a7-a123-47f19cfcd868', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('80349409-5b48-483f-9cbe-936d552ea595', '620fdf9b-7dc6-4968-8b42-0878c8c889ad', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e1445303-174b-4510-848b-325d96e00e34', 'd798681b-5dce-4270-853d-5b13da979595', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e1445303-174b-4510-848b-325d96e00e34', '369f656a-9772-4d4e-a533-e5978e220941', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e1445303-174b-4510-848b-325d96e00e34', '2366ca86-c838-42b7-baea-0456952f73c2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e1445303-174b-4510-848b-325d96e00e34', '8e55cb37-1421-45a5-bf37-22582bc35800', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e1445303-174b-4510-848b-325d96e00e34', '1e27de44-887f-40a7-a123-47f19cfcd868', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8e55cb37-1421-45a5-bf37-22582bc35800', 'd798681b-5dce-4270-853d-5b13da979595', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8e55cb37-1421-45a5-bf37-22582bc35800', '369f656a-9772-4d4e-a533-e5978e220941', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8e55cb37-1421-45a5-bf37-22582bc35800', '2366ca86-c838-42b7-baea-0456952f73c2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8e55cb37-1421-45a5-bf37-22582bc35800', 'e1445303-174b-4510-848b-325d96e00e34', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8e55cb37-1421-45a5-bf37-22582bc35800', '1e27de44-887f-40a7-a123-47f19cfcd868', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3900b9b4-75f3-4a5e-8956-6e76df418eca', '6bbd8401-9a32-4b9a-85e5-1d0c4c870288', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3900b9b4-75f3-4a5e-8956-6e76df418eca', '65fab8f1-a21f-4db5-931c-0f31f5a3ee62', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3900b9b4-75f3-4a5e-8956-6e76df418eca', '80349409-5b48-483f-9cbe-936d552ea595', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3900b9b4-75f3-4a5e-8956-6e76df418eca', '1e27de44-887f-40a7-a123-47f19cfcd868', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3900b9b4-75f3-4a5e-8956-6e76df418eca', '620fdf9b-7dc6-4968-8b42-0878c8c889ad', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f3d13923-e29e-4534-8823-6927c386822c', 'c7d13b11-e9ea-4932-a3c9-190de5337daa', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f3d13923-e29e-4534-8823-6927c386822c', '4fa60160-a11f-436c-a11c-dc2de1318142', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f3d13923-e29e-4534-8823-6927c386822c', 'ae7d002c-4077-4e0a-b842-d6c4435e04d3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f3d13923-e29e-4534-8823-6927c386822c', '026279a4-e80e-4378-b8ad-e6cd58900af4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f3d13923-e29e-4534-8823-6927c386822c', 'f53efd70-955a-4a39-8b80-7fe9bc531c8a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('168a9d86-467d-4e7c-8ea5-488218141349', 'f415690e-17d7-431e-834d-ea26bf6040d4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('168a9d86-467d-4e7c-8ea5-488218141349', '9ebbe40d-0597-49aa-9529-38657204588c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('168a9d86-467d-4e7c-8ea5-488218141349', '86bdd100-6cd3-432c-bff2-7f4cf8a54795', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f63b1de7-621a-44d9-9e2d-6fcd83395dd0', '94ab28eb-f6ac-4a65-a59f-281fa30dc92d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f63b1de7-621a-44d9-9e2d-6fcd83395dd0', 'cd3e4811-b696-4790-a273-6b23ba30ea51', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f63b1de7-621a-44d9-9e2d-6fcd83395dd0', '97bfef6c-b7c8-419d-ba64-aeacb2ce4540', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('94ab28eb-f6ac-4a65-a59f-281fa30dc92d', 'f63b1de7-621a-44d9-9e2d-6fcd83395dd0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('94ab28eb-f6ac-4a65-a59f-281fa30dc92d', 'cd3e4811-b696-4790-a273-6b23ba30ea51', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('94ab28eb-f6ac-4a65-a59f-281fa30dc92d', '97bfef6c-b7c8-419d-ba64-aeacb2ce4540', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd3e4811-b696-4790-a273-6b23ba30ea51', 'f63b1de7-621a-44d9-9e2d-6fcd83395dd0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd3e4811-b696-4790-a273-6b23ba30ea51', '94ab28eb-f6ac-4a65-a59f-281fa30dc92d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd3e4811-b696-4790-a273-6b23ba30ea51', '97bfef6c-b7c8-419d-ba64-aeacb2ce4540', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('97bfef6c-b7c8-419d-ba64-aeacb2ce4540', 'f63b1de7-621a-44d9-9e2d-6fcd83395dd0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('97bfef6c-b7c8-419d-ba64-aeacb2ce4540', '94ab28eb-f6ac-4a65-a59f-281fa30dc92d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('97bfef6c-b7c8-419d-ba64-aeacb2ce4540', 'cd3e4811-b696-4790-a273-6b23ba30ea51', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6dbd4c70-48dd-46be-ac30-cc329f4e2b72', 'c36e10c8-4ef9-4997-96e5-ce20b1affa52', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6dbd4c70-48dd-46be-ac30-cc329f4e2b72', 'b173bd10-0145-4c62-a0f1-48e7f10de33a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6dbd4c70-48dd-46be-ac30-cc329f4e2b72', '279be5b5-370e-4239-b48c-a9551f35bd45', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6dbd4c70-48dd-46be-ac30-cc329f4e2b72', 'f7ca5914-c7bb-43e9-beeb-39529ac19ca9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6dbd4c70-48dd-46be-ac30-cc329f4e2b72', 'dddb7a49-e98b-45ce-9f0b-02b50ad7ea4d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c36e10c8-4ef9-4997-96e5-ce20b1affa52', '6dbd4c70-48dd-46be-ac30-cc329f4e2b72', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c36e10c8-4ef9-4997-96e5-ce20b1affa52', 'b173bd10-0145-4c62-a0f1-48e7f10de33a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c36e10c8-4ef9-4997-96e5-ce20b1affa52', '279be5b5-370e-4239-b48c-a9551f35bd45', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c36e10c8-4ef9-4997-96e5-ce20b1affa52', 'f7ca5914-c7bb-43e9-beeb-39529ac19ca9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c36e10c8-4ef9-4997-96e5-ce20b1affa52', 'dddb7a49-e98b-45ce-9f0b-02b50ad7ea4d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b173bd10-0145-4c62-a0f1-48e7f10de33a', '6dbd4c70-48dd-46be-ac30-cc329f4e2b72', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b173bd10-0145-4c62-a0f1-48e7f10de33a', 'c36e10c8-4ef9-4997-96e5-ce20b1affa52', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b173bd10-0145-4c62-a0f1-48e7f10de33a', '279be5b5-370e-4239-b48c-a9551f35bd45', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b173bd10-0145-4c62-a0f1-48e7f10de33a', 'f7ca5914-c7bb-43e9-beeb-39529ac19ca9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b173bd10-0145-4c62-a0f1-48e7f10de33a', 'dddb7a49-e98b-45ce-9f0b-02b50ad7ea4d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('279be5b5-370e-4239-b48c-a9551f35bd45', '6dbd4c70-48dd-46be-ac30-cc329f4e2b72', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('279be5b5-370e-4239-b48c-a9551f35bd45', 'c36e10c8-4ef9-4997-96e5-ce20b1affa52', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('279be5b5-370e-4239-b48c-a9551f35bd45', 'b173bd10-0145-4c62-a0f1-48e7f10de33a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('279be5b5-370e-4239-b48c-a9551f35bd45', 'f7ca5914-c7bb-43e9-beeb-39529ac19ca9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('279be5b5-370e-4239-b48c-a9551f35bd45', 'dddb7a49-e98b-45ce-9f0b-02b50ad7ea4d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7ca755e3-6b63-4a35-b2a2-a7151c7677fa', '7270de5c-0322-4e59-b8d2-81999f01cba4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7ca755e3-6b63-4a35-b2a2-a7151c7677fa', '6dbd4c70-48dd-46be-ac30-cc329f4e2b72', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7ca755e3-6b63-4a35-b2a2-a7151c7677fa', 'c36e10c8-4ef9-4997-96e5-ce20b1affa52', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7ca755e3-6b63-4a35-b2a2-a7151c7677fa', 'b173bd10-0145-4c62-a0f1-48e7f10de33a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7ca755e3-6b63-4a35-b2a2-a7151c7677fa', '279be5b5-370e-4239-b48c-a9551f35bd45', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7270de5c-0322-4e59-b8d2-81999f01cba4', '7ca755e3-6b63-4a35-b2a2-a7151c7677fa', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7270de5c-0322-4e59-b8d2-81999f01cba4', '6dbd4c70-48dd-46be-ac30-cc329f4e2b72', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7270de5c-0322-4e59-b8d2-81999f01cba4', 'c36e10c8-4ef9-4997-96e5-ce20b1affa52', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7270de5c-0322-4e59-b8d2-81999f01cba4', 'b173bd10-0145-4c62-a0f1-48e7f10de33a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7270de5c-0322-4e59-b8d2-81999f01cba4', '279be5b5-370e-4239-b48c-a9551f35bd45', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f7ca5914-c7bb-43e9-beeb-39529ac19ca9', '6dbd4c70-48dd-46be-ac30-cc329f4e2b72', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f7ca5914-c7bb-43e9-beeb-39529ac19ca9', 'c36e10c8-4ef9-4997-96e5-ce20b1affa52', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f7ca5914-c7bb-43e9-beeb-39529ac19ca9', 'b173bd10-0145-4c62-a0f1-48e7f10de33a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f7ca5914-c7bb-43e9-beeb-39529ac19ca9', '279be5b5-370e-4239-b48c-a9551f35bd45', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f7ca5914-c7bb-43e9-beeb-39529ac19ca9', 'dddb7a49-e98b-45ce-9f0b-02b50ad7ea4d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dddb7a49-e98b-45ce-9f0b-02b50ad7ea4d', '6dbd4c70-48dd-46be-ac30-cc329f4e2b72', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dddb7a49-e98b-45ce-9f0b-02b50ad7ea4d', 'c36e10c8-4ef9-4997-96e5-ce20b1affa52', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dddb7a49-e98b-45ce-9f0b-02b50ad7ea4d', 'b173bd10-0145-4c62-a0f1-48e7f10de33a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dddb7a49-e98b-45ce-9f0b-02b50ad7ea4d', '279be5b5-370e-4239-b48c-a9551f35bd45', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dddb7a49-e98b-45ce-9f0b-02b50ad7ea4d', 'f7ca5914-c7bb-43e9-beeb-39529ac19ca9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0b91ef46-bad9-4122-8450-bce18fa47d28', '76356866-3fa5-4f6a-97d3-ae94cea75eb3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0b91ef46-bad9-4122-8450-bce18fa47d28', 'f63b1de7-621a-44d9-9e2d-6fcd83395dd0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0b91ef46-bad9-4122-8450-bce18fa47d28', '94ab28eb-f6ac-4a65-a59f-281fa30dc92d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5c631ac6-9b41-401b-9cac-3913fa9ba3d7', '6dbd4c70-48dd-46be-ac30-cc329f4e2b72', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5c631ac6-9b41-401b-9cac-3913fa9ba3d7', 'c36e10c8-4ef9-4997-96e5-ce20b1affa52', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5c631ac6-9b41-401b-9cac-3913fa9ba3d7', 'b173bd10-0145-4c62-a0f1-48e7f10de33a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5c631ac6-9b41-401b-9cac-3913fa9ba3d7', '279be5b5-370e-4239-b48c-a9551f35bd45', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5c631ac6-9b41-401b-9cac-3913fa9ba3d7', '7ca755e3-6b63-4a35-b2a2-a7151c7677fa', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e371b332-8d42-4605-9301-8b930665d01b', '76356866-3fa5-4f6a-97d3-ae94cea75eb3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e371b332-8d42-4605-9301-8b930665d01b', 'f63b1de7-621a-44d9-9e2d-6fcd83395dd0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e371b332-8d42-4605-9301-8b930665d01b', '94ab28eb-f6ac-4a65-a59f-281fa30dc92d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b59fe55-a202-4649-b731-be50d5b00da5', 'a442f2e7-264e-4ce5-9fe8-7f9ec42b349a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b59fe55-a202-4649-b731-be50d5b00da5', 'd0a55f33-f73b-4d86-b1c1-8d68b30be653', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b59fe55-a202-4649-b731-be50d5b00da5', '86db302e-de79-4e64-80b9-e68834ee1075', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b59fe55-a202-4649-b731-be50d5b00da5', '683ecafa-f0cb-4906-b797-96d4a2ac0e81', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b59fe55-a202-4649-b731-be50d5b00da5', 'd8f11896-c200-4074-9342-a4f37d15f881', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0cf3642e-ca29-431e-a2ab-6dda0c75ab5e', '954803d8-80dc-4cf0-b3dd-da03c645ffc6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0cf3642e-ca29-431e-a2ab-6dda0c75ab5e', '8b59fe55-a202-4649-b731-be50d5b00da5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0cf3642e-ca29-431e-a2ab-6dda0c75ab5e', 'a442f2e7-264e-4ce5-9fe8-7f9ec42b349a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0cf3642e-ca29-431e-a2ab-6dda0c75ab5e', 'd0a55f33-f73b-4d86-b1c1-8d68b30be653', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0cf3642e-ca29-431e-a2ab-6dda0c75ab5e', '86db302e-de79-4e64-80b9-e68834ee1075', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a442f2e7-264e-4ce5-9fe8-7f9ec42b349a', '8b59fe55-a202-4649-b731-be50d5b00da5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a442f2e7-264e-4ce5-9fe8-7f9ec42b349a', 'd0a55f33-f73b-4d86-b1c1-8d68b30be653', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a442f2e7-264e-4ce5-9fe8-7f9ec42b349a', '86db302e-de79-4e64-80b9-e68834ee1075', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a442f2e7-264e-4ce5-9fe8-7f9ec42b349a', '683ecafa-f0cb-4906-b797-96d4a2ac0e81', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a442f2e7-264e-4ce5-9fe8-7f9ec42b349a', 'd8f11896-c200-4074-9342-a4f37d15f881', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d0a55f33-f73b-4d86-b1c1-8d68b30be653', '8b59fe55-a202-4649-b731-be50d5b00da5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d0a55f33-f73b-4d86-b1c1-8d68b30be653', 'a442f2e7-264e-4ce5-9fe8-7f9ec42b349a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d0a55f33-f73b-4d86-b1c1-8d68b30be653', '86db302e-de79-4e64-80b9-e68834ee1075', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d0a55f33-f73b-4d86-b1c1-8d68b30be653', '683ecafa-f0cb-4906-b797-96d4a2ac0e81', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d0a55f33-f73b-4d86-b1c1-8d68b30be653', 'd8f11896-c200-4074-9342-a4f37d15f881', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('86db302e-de79-4e64-80b9-e68834ee1075', '8b59fe55-a202-4649-b731-be50d5b00da5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('86db302e-de79-4e64-80b9-e68834ee1075', 'a442f2e7-264e-4ce5-9fe8-7f9ec42b349a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('86db302e-de79-4e64-80b9-e68834ee1075', 'd0a55f33-f73b-4d86-b1c1-8d68b30be653', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('86db302e-de79-4e64-80b9-e68834ee1075', '683ecafa-f0cb-4906-b797-96d4a2ac0e81', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('86db302e-de79-4e64-80b9-e68834ee1075', 'd8f11896-c200-4074-9342-a4f37d15f881', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('683ecafa-f0cb-4906-b797-96d4a2ac0e81', '8b59fe55-a202-4649-b731-be50d5b00da5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('683ecafa-f0cb-4906-b797-96d4a2ac0e81', 'a442f2e7-264e-4ce5-9fe8-7f9ec42b349a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('683ecafa-f0cb-4906-b797-96d4a2ac0e81', 'd0a55f33-f73b-4d86-b1c1-8d68b30be653', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('683ecafa-f0cb-4906-b797-96d4a2ac0e81', '86db302e-de79-4e64-80b9-e68834ee1075', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('683ecafa-f0cb-4906-b797-96d4a2ac0e81', 'd8f11896-c200-4074-9342-a4f37d15f881', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d8f11896-c200-4074-9342-a4f37d15f881', '8b59fe55-a202-4649-b731-be50d5b00da5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d8f11896-c200-4074-9342-a4f37d15f881', 'a442f2e7-264e-4ce5-9fe8-7f9ec42b349a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d8f11896-c200-4074-9342-a4f37d15f881', 'd0a55f33-f73b-4d86-b1c1-8d68b30be653', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d8f11896-c200-4074-9342-a4f37d15f881', '86db302e-de79-4e64-80b9-e68834ee1075', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d8f11896-c200-4074-9342-a4f37d15f881', '683ecafa-f0cb-4906-b797-96d4a2ac0e81', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ec55642f-bb18-468f-9599-bd02dc8ac979', '7d9e0900-3a16-4715-87b7-717a95dd2e6f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ec55642f-bb18-468f-9599-bd02dc8ac979', '8b59fe55-a202-4649-b731-be50d5b00da5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ec55642f-bb18-468f-9599-bd02dc8ac979', '0cf3642e-ca29-431e-a2ab-6dda0c75ab5e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ec55642f-bb18-468f-9599-bd02dc8ac979', 'a442f2e7-264e-4ce5-9fe8-7f9ec42b349a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ec55642f-bb18-468f-9599-bd02dc8ac979', 'd0a55f33-f73b-4d86-b1c1-8d68b30be653', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7d9e0900-3a16-4715-87b7-717a95dd2e6f', 'ec55642f-bb18-468f-9599-bd02dc8ac979', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7d9e0900-3a16-4715-87b7-717a95dd2e6f', '8b59fe55-a202-4649-b731-be50d5b00da5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7d9e0900-3a16-4715-87b7-717a95dd2e6f', '0cf3642e-ca29-431e-a2ab-6dda0c75ab5e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7d9e0900-3a16-4715-87b7-717a95dd2e6f', 'a442f2e7-264e-4ce5-9fe8-7f9ec42b349a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7d9e0900-3a16-4715-87b7-717a95dd2e6f', 'd0a55f33-f73b-4d86-b1c1-8d68b30be653', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('085d361d-0bee-4508-9ee3-87542f3e6779', '8b59fe55-a202-4649-b731-be50d5b00da5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('085d361d-0bee-4508-9ee3-87542f3e6779', 'a442f2e7-264e-4ce5-9fe8-7f9ec42b349a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('085d361d-0bee-4508-9ee3-87542f3e6779', 'd0a55f33-f73b-4d86-b1c1-8d68b30be653', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('085d361d-0bee-4508-9ee3-87542f3e6779', '86db302e-de79-4e64-80b9-e68834ee1075', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('085d361d-0bee-4508-9ee3-87542f3e6779', '683ecafa-f0cb-4906-b797-96d4a2ac0e81', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('524de411-c37b-4675-8915-4005498e40de', '8b59fe55-a202-4649-b731-be50d5b00da5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('524de411-c37b-4675-8915-4005498e40de', 'a442f2e7-264e-4ce5-9fe8-7f9ec42b349a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('524de411-c37b-4675-8915-4005498e40de', 'd0a55f33-f73b-4d86-b1c1-8d68b30be653', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('524de411-c37b-4675-8915-4005498e40de', '86db302e-de79-4e64-80b9-e68834ee1075', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('524de411-c37b-4675-8915-4005498e40de', '683ecafa-f0cb-4906-b797-96d4a2ac0e81', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('954803d8-80dc-4cf0-b3dd-da03c645ffc6', '0cf3642e-ca29-431e-a2ab-6dda0c75ab5e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('954803d8-80dc-4cf0-b3dd-da03c645ffc6', '8b59fe55-a202-4649-b731-be50d5b00da5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('954803d8-80dc-4cf0-b3dd-da03c645ffc6', 'a442f2e7-264e-4ce5-9fe8-7f9ec42b349a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('954803d8-80dc-4cf0-b3dd-da03c645ffc6', 'd0a55f33-f73b-4d86-b1c1-8d68b30be653', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('954803d8-80dc-4cf0-b3dd-da03c645ffc6', '86db302e-de79-4e64-80b9-e68834ee1075', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e7110bbe-433b-4478-b359-e50159462999', '8b59fe55-a202-4649-b731-be50d5b00da5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e7110bbe-433b-4478-b359-e50159462999', 'a442f2e7-264e-4ce5-9fe8-7f9ec42b349a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e7110bbe-433b-4478-b359-e50159462999', 'd0a55f33-f73b-4d86-b1c1-8d68b30be653', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e7110bbe-433b-4478-b359-e50159462999', '86db302e-de79-4e64-80b9-e68834ee1075', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e7110bbe-433b-4478-b359-e50159462999', '683ecafa-f0cb-4906-b797-96d4a2ac0e81', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a3ad91b5-adc2-434c-99a3-52301f1cb1ec', '64d24204-387a-483d-aee8-a73ab652794e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a3ad91b5-adc2-434c-99a3-52301f1cb1ec', '461d721e-e6fa-4049-8a6f-3f51a49b649f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a3ad91b5-adc2-434c-99a3-52301f1cb1ec', 'c3a5241b-d7df-4d8c-9837-99f0e65a0595', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a3ad91b5-adc2-434c-99a3-52301f1cb1ec', '88db0b7c-d1d3-43a7-8529-62e1b4294e85', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a3ad91b5-adc2-434c-99a3-52301f1cb1ec', '5c88222d-d872-4c3f-8ce9-0998e550c031', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('461d721e-e6fa-4049-8a6f-3f51a49b649f', 'a3ad91b5-adc2-434c-99a3-52301f1cb1ec', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('461d721e-e6fa-4049-8a6f-3f51a49b649f', 'c3a5241b-d7df-4d8c-9837-99f0e65a0595', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('461d721e-e6fa-4049-8a6f-3f51a49b649f', '88db0b7c-d1d3-43a7-8529-62e1b4294e85', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('461d721e-e6fa-4049-8a6f-3f51a49b649f', '5c88222d-d872-4c3f-8ce9-0998e550c031', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('461d721e-e6fa-4049-8a6f-3f51a49b649f', '542a2f1a-96b0-4895-bbd3-91529397f7a3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c3a5241b-d7df-4d8c-9837-99f0e65a0595', 'a3ad91b5-adc2-434c-99a3-52301f1cb1ec', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c3a5241b-d7df-4d8c-9837-99f0e65a0595', '461d721e-e6fa-4049-8a6f-3f51a49b649f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c3a5241b-d7df-4d8c-9837-99f0e65a0595', '88db0b7c-d1d3-43a7-8529-62e1b4294e85', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c3a5241b-d7df-4d8c-9837-99f0e65a0595', '5c88222d-d872-4c3f-8ce9-0998e550c031', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c3a5241b-d7df-4d8c-9837-99f0e65a0595', '542a2f1a-96b0-4895-bbd3-91529397f7a3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('88db0b7c-d1d3-43a7-8529-62e1b4294e85', '5c88222d-d872-4c3f-8ce9-0998e550c031', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('88db0b7c-d1d3-43a7-8529-62e1b4294e85', '542a2f1a-96b0-4895-bbd3-91529397f7a3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('88db0b7c-d1d3-43a7-8529-62e1b4294e85', 'a91594a0-7459-4a0b-a5e2-22f529103553', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('88db0b7c-d1d3-43a7-8529-62e1b4294e85', 'a3ad91b5-adc2-434c-99a3-52301f1cb1ec', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('88db0b7c-d1d3-43a7-8529-62e1b4294e85', '461d721e-e6fa-4049-8a6f-3f51a49b649f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5c88222d-d872-4c3f-8ce9-0998e550c031', '88db0b7c-d1d3-43a7-8529-62e1b4294e85', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5c88222d-d872-4c3f-8ce9-0998e550c031', '542a2f1a-96b0-4895-bbd3-91529397f7a3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5c88222d-d872-4c3f-8ce9-0998e550c031', 'a91594a0-7459-4a0b-a5e2-22f529103553', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5c88222d-d872-4c3f-8ce9-0998e550c031', 'a3ad91b5-adc2-434c-99a3-52301f1cb1ec', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5c88222d-d872-4c3f-8ce9-0998e550c031', '461d721e-e6fa-4049-8a6f-3f51a49b649f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('542a2f1a-96b0-4895-bbd3-91529397f7a3', '88db0b7c-d1d3-43a7-8529-62e1b4294e85', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('542a2f1a-96b0-4895-bbd3-91529397f7a3', '5c88222d-d872-4c3f-8ce9-0998e550c031', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('542a2f1a-96b0-4895-bbd3-91529397f7a3', 'a91594a0-7459-4a0b-a5e2-22f529103553', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('542a2f1a-96b0-4895-bbd3-91529397f7a3', 'a3ad91b5-adc2-434c-99a3-52301f1cb1ec', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('542a2f1a-96b0-4895-bbd3-91529397f7a3', '461d721e-e6fa-4049-8a6f-3f51a49b649f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a91594a0-7459-4a0b-a5e2-22f529103553', '88db0b7c-d1d3-43a7-8529-62e1b4294e85', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a91594a0-7459-4a0b-a5e2-22f529103553', '5c88222d-d872-4c3f-8ce9-0998e550c031', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a91594a0-7459-4a0b-a5e2-22f529103553', '542a2f1a-96b0-4895-bbd3-91529397f7a3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a91594a0-7459-4a0b-a5e2-22f529103553', 'a3ad91b5-adc2-434c-99a3-52301f1cb1ec', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a91594a0-7459-4a0b-a5e2-22f529103553', '461d721e-e6fa-4049-8a6f-3f51a49b649f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('64d24204-387a-483d-aee8-a73ab652794e', 'a3ad91b5-adc2-434c-99a3-52301f1cb1ec', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('64d24204-387a-483d-aee8-a73ab652794e', '461d721e-e6fa-4049-8a6f-3f51a49b649f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('64d24204-387a-483d-aee8-a73ab652794e', 'c3a5241b-d7df-4d8c-9837-99f0e65a0595', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('64d24204-387a-483d-aee8-a73ab652794e', '88db0b7c-d1d3-43a7-8529-62e1b4294e85', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('64d24204-387a-483d-aee8-a73ab652794e', '5c88222d-d872-4c3f-8ce9-0998e550c031', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('74245e82-d288-419d-97a8-a542ab3e828b', 'a3ad91b5-adc2-434c-99a3-52301f1cb1ec', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('74245e82-d288-419d-97a8-a542ab3e828b', '461d721e-e6fa-4049-8a6f-3f51a49b649f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('74245e82-d288-419d-97a8-a542ab3e828b', 'c3a5241b-d7df-4d8c-9837-99f0e65a0595', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a37d258-865f-45f4-a1cd-23de18b00f5d', 'a3ad91b5-adc2-434c-99a3-52301f1cb1ec', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a37d258-865f-45f4-a1cd-23de18b00f5d', '461d721e-e6fa-4049-8a6f-3f51a49b649f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a37d258-865f-45f4-a1cd-23de18b00f5d', 'c3a5241b-d7df-4d8c-9837-99f0e65a0595', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a37d258-865f-45f4-a1cd-23de18b00f5d', '88db0b7c-d1d3-43a7-8529-62e1b4294e85', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a37d258-865f-45f4-a1cd-23de18b00f5d', '5c88222d-d872-4c3f-8ce9-0998e550c031', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6a7c7195-624d-47e7-b50b-01bc4d97bd09', '0f4fa70b-55dc-47a1-9d2c-686050086045', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6a7c7195-624d-47e7-b50b-01bc4d97bd09', 'b452dccb-78c3-4148-8443-8b4c42f9f461', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6a7c7195-624d-47e7-b50b-01bc4d97bd09', '65da5b92-b7c4-47e9-8a2d-dfe2ecf2f873', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6a7c7195-624d-47e7-b50b-01bc4d97bd09', 'cc4e8d64-83bb-4523-863b-395140c67099', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6a7c7195-624d-47e7-b50b-01bc4d97bd09', '2f0a14f6-120b-4f64-92cb-2829c6b862fd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a8153622-f179-465b-9b2a-bbb90eb35949', '6a7c7195-624d-47e7-b50b-01bc4d97bd09', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a8153622-f179-465b-9b2a-bbb90eb35949', '0f4fa70b-55dc-47a1-9d2c-686050086045', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a8153622-f179-465b-9b2a-bbb90eb35949', 'b452dccb-78c3-4148-8443-8b4c42f9f461', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a8153622-f179-465b-9b2a-bbb90eb35949', '65da5b92-b7c4-47e9-8a2d-dfe2ecf2f873', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a8153622-f179-465b-9b2a-bbb90eb35949', 'cc4e8d64-83bb-4523-863b-395140c67099', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0f4fa70b-55dc-47a1-9d2c-686050086045', '6a7c7195-624d-47e7-b50b-01bc4d97bd09', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0f4fa70b-55dc-47a1-9d2c-686050086045', 'b452dccb-78c3-4148-8443-8b4c42f9f461', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0f4fa70b-55dc-47a1-9d2c-686050086045', '65da5b92-b7c4-47e9-8a2d-dfe2ecf2f873', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0f4fa70b-55dc-47a1-9d2c-686050086045', 'cc4e8d64-83bb-4523-863b-395140c67099', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0f4fa70b-55dc-47a1-9d2c-686050086045', '2f0a14f6-120b-4f64-92cb-2829c6b862fd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('65da5b92-b7c4-47e9-8a2d-dfe2ecf2f873', '6a7c7195-624d-47e7-b50b-01bc4d97bd09', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('65da5b92-b7c4-47e9-8a2d-dfe2ecf2f873', '0f4fa70b-55dc-47a1-9d2c-686050086045', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('65da5b92-b7c4-47e9-8a2d-dfe2ecf2f873', 'cc4e8d64-83bb-4523-863b-395140c67099', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('65da5b92-b7c4-47e9-8a2d-dfe2ecf2f873', 'b452dccb-78c3-4148-8443-8b4c42f9f461', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('65da5b92-b7c4-47e9-8a2d-dfe2ecf2f873', '2f0a14f6-120b-4f64-92cb-2829c6b862fd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cc4e8d64-83bb-4523-863b-395140c67099', '6a7c7195-624d-47e7-b50b-01bc4d97bd09', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cc4e8d64-83bb-4523-863b-395140c67099', '0f4fa70b-55dc-47a1-9d2c-686050086045', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cc4e8d64-83bb-4523-863b-395140c67099', '65da5b92-b7c4-47e9-8a2d-dfe2ecf2f873', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cc4e8d64-83bb-4523-863b-395140c67099', 'b452dccb-78c3-4148-8443-8b4c42f9f461', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cc4e8d64-83bb-4523-863b-395140c67099', '2f0a14f6-120b-4f64-92cb-2829c6b862fd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('55f8f20c-4e9c-481a-97d5-44b177f2a2e1', '6a7c7195-624d-47e7-b50b-01bc4d97bd09', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('55f8f20c-4e9c-481a-97d5-44b177f2a2e1', '0f4fa70b-55dc-47a1-9d2c-686050086045', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('55f8f20c-4e9c-481a-97d5-44b177f2a2e1', '65da5b92-b7c4-47e9-8a2d-dfe2ecf2f873', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b54ed274-8a4b-44b0-be4a-1dd5c4ba5864', '6a7c7195-624d-47e7-b50b-01bc4d97bd09', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b54ed274-8a4b-44b0-be4a-1dd5c4ba5864', '0f4fa70b-55dc-47a1-9d2c-686050086045', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b54ed274-8a4b-44b0-be4a-1dd5c4ba5864', '65da5b92-b7c4-47e9-8a2d-dfe2ecf2f873', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9c11a1ab-6cc8-41ac-8f4e-d039717c7f2f', '4cb57e06-87f4-487f-9ca1-7284ea6c71ad', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9c11a1ab-6cc8-41ac-8f4e-d039717c7f2f', '36554e5e-c90e-41c0-b638-58dca11371ef', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9c11a1ab-6cc8-41ac-8f4e-d039717c7f2f', '10544a38-93b1-4b53-86e2-c00d1c13620a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9c11a1ab-6cc8-41ac-8f4e-d039717c7f2f', '255d6fd1-02ca-49f3-9017-674881d08b92', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9c11a1ab-6cc8-41ac-8f4e-d039717c7f2f', 'cdc41d88-817b-4fa2-912b-b357b7b865f6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('10544a38-93b1-4b53-86e2-c00d1c13620a', 'cdc41d88-817b-4fa2-912b-b357b7b865f6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('10544a38-93b1-4b53-86e2-c00d1c13620a', '9c11a1ab-6cc8-41ac-8f4e-d039717c7f2f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('10544a38-93b1-4b53-86e2-c00d1c13620a', '4cb57e06-87f4-487f-9ca1-7284ea6c71ad', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('10544a38-93b1-4b53-86e2-c00d1c13620a', '255d6fd1-02ca-49f3-9017-674881d08b92', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('10544a38-93b1-4b53-86e2-c00d1c13620a', '36554e5e-c90e-41c0-b638-58dca11371ef', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4cb57e06-87f4-487f-9ca1-7284ea6c71ad', '9c11a1ab-6cc8-41ac-8f4e-d039717c7f2f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4cb57e06-87f4-487f-9ca1-7284ea6c71ad', '36554e5e-c90e-41c0-b638-58dca11371ef', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4cb57e06-87f4-487f-9ca1-7284ea6c71ad', '10544a38-93b1-4b53-86e2-c00d1c13620a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4cb57e06-87f4-487f-9ca1-7284ea6c71ad', '255d6fd1-02ca-49f3-9017-674881d08b92', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4cb57e06-87f4-487f-9ca1-7284ea6c71ad', 'cdc41d88-817b-4fa2-912b-b357b7b865f6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('255d6fd1-02ca-49f3-9017-674881d08b92', '9c11a1ab-6cc8-41ac-8f4e-d039717c7f2f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('255d6fd1-02ca-49f3-9017-674881d08b92', '10544a38-93b1-4b53-86e2-c00d1c13620a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('255d6fd1-02ca-49f3-9017-674881d08b92', '4cb57e06-87f4-487f-9ca1-7284ea6c71ad', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('255d6fd1-02ca-49f3-9017-674881d08b92', 'cdc41d88-817b-4fa2-912b-b357b7b865f6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('255d6fd1-02ca-49f3-9017-674881d08b92', '36554e5e-c90e-41c0-b638-58dca11371ef', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cdc41d88-817b-4fa2-912b-b357b7b865f6', '10544a38-93b1-4b53-86e2-c00d1c13620a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cdc41d88-817b-4fa2-912b-b357b7b865f6', '9c11a1ab-6cc8-41ac-8f4e-d039717c7f2f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cdc41d88-817b-4fa2-912b-b357b7b865f6', '4cb57e06-87f4-487f-9ca1-7284ea6c71ad', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cdc41d88-817b-4fa2-912b-b357b7b865f6', '255d6fd1-02ca-49f3-9017-674881d08b92', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cdc41d88-817b-4fa2-912b-b357b7b865f6', '36554e5e-c90e-41c0-b638-58dca11371ef', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c008ec6-a7c7-47df-bb61-e80c373d83f9', '062ad450-ab6f-465c-8b3f-44821e39de92', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c008ec6-a7c7-47df-bb61-e80c373d83f9', '6a7c7195-624d-47e7-b50b-01bc4d97bd09', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c008ec6-a7c7-47df-bb61-e80c373d83f9', '0f4fa70b-55dc-47a1-9d2c-686050086045', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b452dccb-78c3-4148-8443-8b4c42f9f461', '6a7c7195-624d-47e7-b50b-01bc4d97bd09', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b452dccb-78c3-4148-8443-8b4c42f9f461', '0f4fa70b-55dc-47a1-9d2c-686050086045', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b452dccb-78c3-4148-8443-8b4c42f9f461', '65da5b92-b7c4-47e9-8a2d-dfe2ecf2f873', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b452dccb-78c3-4148-8443-8b4c42f9f461', 'cc4e8d64-83bb-4523-863b-395140c67099', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b452dccb-78c3-4148-8443-8b4c42f9f461', '2f0a14f6-120b-4f64-92cb-2829c6b862fd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('395bf540-fa09-409a-a588-4cdb9ff5d437', '6a7c7195-624d-47e7-b50b-01bc4d97bd09', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('395bf540-fa09-409a-a588-4cdb9ff5d437', '0f4fa70b-55dc-47a1-9d2c-686050086045', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('395bf540-fa09-409a-a588-4cdb9ff5d437', '65da5b92-b7c4-47e9-8a2d-dfe2ecf2f873', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2f0a14f6-120b-4f64-92cb-2829c6b862fd', '6a7c7195-624d-47e7-b50b-01bc4d97bd09', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2f0a14f6-120b-4f64-92cb-2829c6b862fd', '0f4fa70b-55dc-47a1-9d2c-686050086045', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2f0a14f6-120b-4f64-92cb-2829c6b862fd', '65da5b92-b7c4-47e9-8a2d-dfe2ecf2f873', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2f0a14f6-120b-4f64-92cb-2829c6b862fd', 'cc4e8d64-83bb-4523-863b-395140c67099', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2f0a14f6-120b-4f64-92cb-2829c6b862fd', 'b452dccb-78c3-4148-8443-8b4c42f9f461', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('062ad450-ab6f-465c-8b3f-44821e39de92', '4c008ec6-a7c7-47df-bb61-e80c373d83f9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('062ad450-ab6f-465c-8b3f-44821e39de92', '6a7c7195-624d-47e7-b50b-01bc4d97bd09', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('062ad450-ab6f-465c-8b3f-44821e39de92', '0f4fa70b-55dc-47a1-9d2c-686050086045', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('36554e5e-c90e-41c0-b638-58dca11371ef', '9c11a1ab-6cc8-41ac-8f4e-d039717c7f2f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('36554e5e-c90e-41c0-b638-58dca11371ef', '4cb57e06-87f4-487f-9ca1-7284ea6c71ad', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('36554e5e-c90e-41c0-b638-58dca11371ef', '10544a38-93b1-4b53-86e2-c00d1c13620a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('36554e5e-c90e-41c0-b638-58dca11371ef', '255d6fd1-02ca-49f3-9017-674881d08b92', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('36554e5e-c90e-41c0-b638-58dca11371ef', 'cdc41d88-817b-4fa2-912b-b357b7b865f6', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c0acfaef-f563-46a5-9571-e231ab06758d', '0bb0d594-fc38-440e-9c29-898181d6e875', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c0acfaef-f563-46a5-9571-e231ab06758d', '418cc5a5-0c2f-47f0-b945-79ef6567cd41', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c0acfaef-f563-46a5-9571-e231ab06758d', '6a7c7195-624d-47e7-b50b-01bc4d97bd09', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0bb0d594-fc38-440e-9c29-898181d6e875', 'c0acfaef-f563-46a5-9571-e231ab06758d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0bb0d594-fc38-440e-9c29-898181d6e875', '418cc5a5-0c2f-47f0-b945-79ef6567cd41', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0bb0d594-fc38-440e-9c29-898181d6e875', '6a7c7195-624d-47e7-b50b-01bc4d97bd09', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('418cc5a5-0c2f-47f0-b945-79ef6567cd41', 'c0acfaef-f563-46a5-9571-e231ab06758d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('418cc5a5-0c2f-47f0-b945-79ef6567cd41', '0bb0d594-fc38-440e-9c29-898181d6e875', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('418cc5a5-0c2f-47f0-b945-79ef6567cd41', '6a7c7195-624d-47e7-b50b-01bc4d97bd09', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('af3090f3-2453-4c26-9827-6a076e66d5a0', 'd40213be-1b33-4b4e-9074-4f49e97542be', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('af3090f3-2453-4c26-9827-6a076e66d5a0', '0ae624e4-2dcc-4849-9dd0-3e5569d745bc', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('af3090f3-2453-4c26-9827-6a076e66d5a0', 'c50284fe-f54f-4c6b-9c00-eea278a18cbe', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('af3090f3-2453-4c26-9827-6a076e66d5a0', '938a51ae-5a8e-43e7-9989-79cbabefb809', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d40213be-1b33-4b4e-9074-4f49e97542be', 'af3090f3-2453-4c26-9827-6a076e66d5a0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d40213be-1b33-4b4e-9074-4f49e97542be', '0ae624e4-2dcc-4849-9dd0-3e5569d745bc', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d40213be-1b33-4b4e-9074-4f49e97542be', 'c50284fe-f54f-4c6b-9c00-eea278a18cbe', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d40213be-1b33-4b4e-9074-4f49e97542be', '938a51ae-5a8e-43e7-9989-79cbabefb809', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0ae624e4-2dcc-4849-9dd0-3e5569d745bc', 'af3090f3-2453-4c26-9827-6a076e66d5a0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0ae624e4-2dcc-4849-9dd0-3e5569d745bc', 'd40213be-1b33-4b4e-9074-4f49e97542be', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0ae624e4-2dcc-4849-9dd0-3e5569d745bc', 'c50284fe-f54f-4c6b-9c00-eea278a18cbe', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0ae624e4-2dcc-4849-9dd0-3e5569d745bc', '938a51ae-5a8e-43e7-9989-79cbabefb809', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c50284fe-f54f-4c6b-9c00-eea278a18cbe', 'af3090f3-2453-4c26-9827-6a076e66d5a0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c50284fe-f54f-4c6b-9c00-eea278a18cbe', 'd40213be-1b33-4b4e-9074-4f49e97542be', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c50284fe-f54f-4c6b-9c00-eea278a18cbe', '0ae624e4-2dcc-4849-9dd0-3e5569d745bc', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c50284fe-f54f-4c6b-9c00-eea278a18cbe', '938a51ae-5a8e-43e7-9989-79cbabefb809', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('938a51ae-5a8e-43e7-9989-79cbabefb809', 'af3090f3-2453-4c26-9827-6a076e66d5a0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('938a51ae-5a8e-43e7-9989-79cbabefb809', 'd40213be-1b33-4b4e-9074-4f49e97542be', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('938a51ae-5a8e-43e7-9989-79cbabefb809', '0ae624e4-2dcc-4849-9dd0-3e5569d745bc', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('938a51ae-5a8e-43e7-9989-79cbabefb809', 'c50284fe-f54f-4c6b-9c00-eea278a18cbe', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6855230d-4cdb-4be8-a0bc-42b5cb34e2aa', '4ef0595a-748d-46db-9563-7d80d8590c19', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6855230d-4cdb-4be8-a0bc-42b5cb34e2aa', '6fe17bc1-aeae-4bb0-a6c5-d88d8d33ab56', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4ef0595a-748d-46db-9563-7d80d8590c19', '6855230d-4cdb-4be8-a0bc-42b5cb34e2aa', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4ef0595a-748d-46db-9563-7d80d8590c19', '6fe17bc1-aeae-4bb0-a6c5-d88d8d33ab56', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6fe17bc1-aeae-4bb0-a6c5-d88d8d33ab56', '6855230d-4cdb-4be8-a0bc-42b5cb34e2aa', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6fe17bc1-aeae-4bb0-a6c5-d88d8d33ab56', '4ef0595a-748d-46db-9563-7d80d8590c19', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('441a8a31-a623-4a31-bc69-e5796d01c0a2', '7912eeca-7e8c-49e0-83b9-a70134824b1c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('441a8a31-a623-4a31-bc69-e5796d01c0a2', 'd878fd67-64f6-4fb5-a5d3-787955037782', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('441a8a31-a623-4a31-bc69-e5796d01c0a2', 'c719c143-b0c3-4218-9efa-aad9c8e1e1cb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('441a8a31-a623-4a31-bc69-e5796d01c0a2', '369b3080-a974-4a86-8ed0-e7cc0b200cf1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('441a8a31-a623-4a31-bc69-e5796d01c0a2', 'b88ddf87-6d95-41b9-aa76-38d3ab4ece4f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d878fd67-64f6-4fb5-a5d3-787955037782', '7912eeca-7e8c-49e0-83b9-a70134824b1c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d878fd67-64f6-4fb5-a5d3-787955037782', '441a8a31-a623-4a31-bc69-e5796d01c0a2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d878fd67-64f6-4fb5-a5d3-787955037782', 'c719c143-b0c3-4218-9efa-aad9c8e1e1cb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d878fd67-64f6-4fb5-a5d3-787955037782', '369b3080-a974-4a86-8ed0-e7cc0b200cf1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d878fd67-64f6-4fb5-a5d3-787955037782', 'b88ddf87-6d95-41b9-aa76-38d3ab4ece4f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c719c143-b0c3-4218-9efa-aad9c8e1e1cb', '7912eeca-7e8c-49e0-83b9-a70134824b1c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c719c143-b0c3-4218-9efa-aad9c8e1e1cb', '441a8a31-a623-4a31-bc69-e5796d01c0a2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c719c143-b0c3-4218-9efa-aad9c8e1e1cb', 'd878fd67-64f6-4fb5-a5d3-787955037782', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c719c143-b0c3-4218-9efa-aad9c8e1e1cb', '369b3080-a974-4a86-8ed0-e7cc0b200cf1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c719c143-b0c3-4218-9efa-aad9c8e1e1cb', 'b88ddf87-6d95-41b9-aa76-38d3ab4ece4f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b88ddf87-6d95-41b9-aa76-38d3ab4ece4f', '7912eeca-7e8c-49e0-83b9-a70134824b1c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b88ddf87-6d95-41b9-aa76-38d3ab4ece4f', '369b3080-a974-4a86-8ed0-e7cc0b200cf1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b88ddf87-6d95-41b9-aa76-38d3ab4ece4f', '441a8a31-a623-4a31-bc69-e5796d01c0a2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b88ddf87-6d95-41b9-aa76-38d3ab4ece4f', 'd878fd67-64f6-4fb5-a5d3-787955037782', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b88ddf87-6d95-41b9-aa76-38d3ab4ece4f', 'c719c143-b0c3-4218-9efa-aad9c8e1e1cb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b29ff3c2-c22e-4947-8305-f252c0c181d9', 'fad9b657-2750-4aea-b676-19f27fb5eb62', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b29ff3c2-c22e-4947-8305-f252c0c181d9', '19cd864d-6c70-495a-828a-4163737fe839', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fad9b657-2750-4aea-b676-19f27fb5eb62', 'b29ff3c2-c22e-4947-8305-f252c0c181d9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fad9b657-2750-4aea-b676-19f27fb5eb62', '19cd864d-6c70-495a-828a-4163737fe839', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19cd864d-6c70-495a-828a-4163737fe839', 'b29ff3c2-c22e-4947-8305-f252c0c181d9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19cd864d-6c70-495a-828a-4163737fe839', 'fad9b657-2750-4aea-b676-19f27fb5eb62', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('61b4e409-ae08-4390-8805-fa29d641ed0b', '07edebf9-045a-4978-960f-d052b5eda37f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('61b4e409-ae08-4390-8805-fa29d641ed0b', '7bd7b75c-f146-46a2-9fad-13f4c893be5b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('61b4e409-ae08-4390-8805-fa29d641ed0b', '8abbfa39-9863-4b6a-82d1-4aca5838fcdf', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('07edebf9-045a-4978-960f-d052b5eda37f', '8abbfa39-9863-4b6a-82d1-4aca5838fcdf', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('07edebf9-045a-4978-960f-d052b5eda37f', '61b4e409-ae08-4390-8805-fa29d641ed0b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('07edebf9-045a-4978-960f-d052b5eda37f', '7bd7b75c-f146-46a2-9fad-13f4c893be5b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7bd7b75c-f146-46a2-9fad-13f4c893be5b', '61b4e409-ae08-4390-8805-fa29d641ed0b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7bd7b75c-f146-46a2-9fad-13f4c893be5b', '07edebf9-045a-4978-960f-d052b5eda37f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7bd7b75c-f146-46a2-9fad-13f4c893be5b', '8abbfa39-9863-4b6a-82d1-4aca5838fcdf', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8abbfa39-9863-4b6a-82d1-4aca5838fcdf', '07edebf9-045a-4978-960f-d052b5eda37f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8abbfa39-9863-4b6a-82d1-4aca5838fcdf', '61b4e409-ae08-4390-8805-fa29d641ed0b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8abbfa39-9863-4b6a-82d1-4aca5838fcdf', '7bd7b75c-f146-46a2-9fad-13f4c893be5b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e727ce3c-3e61-4b77-835f-9d034046d40d', 'c0ca9f7e-04ca-4ad0-ab1e-0e665712fb90', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e727ce3c-3e61-4b77-835f-9d034046d40d', '26d35087-a03c-4103-bc8a-45a82722b991', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e727ce3c-3e61-4b77-835f-9d034046d40d', '6a305b77-dc22-42df-ad43-dbe68cafeb89', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e727ce3c-3e61-4b77-835f-9d034046d40d', '07f4608e-0558-45d6-be7a-3818cfefe44c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e727ce3c-3e61-4b77-835f-9d034046d40d', '0b116f3c-5b08-4c81-a289-cc7869c9c674', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c0ca9f7e-04ca-4ad0-ab1e-0e665712fb90', 'e727ce3c-3e61-4b77-835f-9d034046d40d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c0ca9f7e-04ca-4ad0-ab1e-0e665712fb90', '26d35087-a03c-4103-bc8a-45a82722b991', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c0ca9f7e-04ca-4ad0-ab1e-0e665712fb90', '6a305b77-dc22-42df-ad43-dbe68cafeb89', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c0ca9f7e-04ca-4ad0-ab1e-0e665712fb90', '07f4608e-0558-45d6-be7a-3818cfefe44c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c0ca9f7e-04ca-4ad0-ab1e-0e665712fb90', '0b116f3c-5b08-4c81-a289-cc7869c9c674', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('26d35087-a03c-4103-bc8a-45a82722b991', '82dcc92b-00a8-4dd7-8d8e-4f142909d8fc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('26d35087-a03c-4103-bc8a-45a82722b991', 'e727ce3c-3e61-4b77-835f-9d034046d40d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('26d35087-a03c-4103-bc8a-45a82722b991', 'c0ca9f7e-04ca-4ad0-ab1e-0e665712fb90', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('26d35087-a03c-4103-bc8a-45a82722b991', '6a305b77-dc22-42df-ad43-dbe68cafeb89', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('26d35087-a03c-4103-bc8a-45a82722b991', '07f4608e-0558-45d6-be7a-3818cfefe44c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6a305b77-dc22-42df-ad43-dbe68cafeb89', 'e727ce3c-3e61-4b77-835f-9d034046d40d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6a305b77-dc22-42df-ad43-dbe68cafeb89', 'c0ca9f7e-04ca-4ad0-ab1e-0e665712fb90', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6a305b77-dc22-42df-ad43-dbe68cafeb89', '26d35087-a03c-4103-bc8a-45a82722b991', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6a305b77-dc22-42df-ad43-dbe68cafeb89', '07f4608e-0558-45d6-be7a-3818cfefe44c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6a305b77-dc22-42df-ad43-dbe68cafeb89', '0b116f3c-5b08-4c81-a289-cc7869c9c674', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('07f4608e-0558-45d6-be7a-3818cfefe44c', 'e727ce3c-3e61-4b77-835f-9d034046d40d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('07f4608e-0558-45d6-be7a-3818cfefe44c', 'c0ca9f7e-04ca-4ad0-ab1e-0e665712fb90', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('07f4608e-0558-45d6-be7a-3818cfefe44c', '26d35087-a03c-4103-bc8a-45a82722b991', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('07f4608e-0558-45d6-be7a-3818cfefe44c', '6a305b77-dc22-42df-ad43-dbe68cafeb89', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('07f4608e-0558-45d6-be7a-3818cfefe44c', '0b116f3c-5b08-4c81-a289-cc7869c9c674', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0b116f3c-5b08-4c81-a289-cc7869c9c674', 'e727ce3c-3e61-4b77-835f-9d034046d40d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0b116f3c-5b08-4c81-a289-cc7869c9c674', 'c0ca9f7e-04ca-4ad0-ab1e-0e665712fb90', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0b116f3c-5b08-4c81-a289-cc7869c9c674', '26d35087-a03c-4103-bc8a-45a82722b991', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0b116f3c-5b08-4c81-a289-cc7869c9c674', '6a305b77-dc22-42df-ad43-dbe68cafeb89', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0b116f3c-5b08-4c81-a289-cc7869c9c674', '07f4608e-0558-45d6-be7a-3818cfefe44c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e513f595-0ec6-455d-9acb-0251c710b513', 'e727ce3c-3e61-4b77-835f-9d034046d40d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e513f595-0ec6-455d-9acb-0251c710b513', 'c0ca9f7e-04ca-4ad0-ab1e-0e665712fb90', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e513f595-0ec6-455d-9acb-0251c710b513', '26d35087-a03c-4103-bc8a-45a82722b991', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e513f595-0ec6-455d-9acb-0251c710b513', '6a305b77-dc22-42df-ad43-dbe68cafeb89', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e513f595-0ec6-455d-9acb-0251c710b513', '07f4608e-0558-45d6-be7a-3818cfefe44c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('82dcc92b-00a8-4dd7-8d8e-4f142909d8fc', '26d35087-a03c-4103-bc8a-45a82722b991', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('82dcc92b-00a8-4dd7-8d8e-4f142909d8fc', 'e727ce3c-3e61-4b77-835f-9d034046d40d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('82dcc92b-00a8-4dd7-8d8e-4f142909d8fc', 'c0ca9f7e-04ca-4ad0-ab1e-0e665712fb90', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('82dcc92b-00a8-4dd7-8d8e-4f142909d8fc', '6a305b77-dc22-42df-ad43-dbe68cafeb89', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('82dcc92b-00a8-4dd7-8d8e-4f142909d8fc', '07f4608e-0558-45d6-be7a-3818cfefe44c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab215499-24c4-42a0-9efc-955a75f8a6c6', 'e727ce3c-3e61-4b77-835f-9d034046d40d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab215499-24c4-42a0-9efc-955a75f8a6c6', 'c0ca9f7e-04ca-4ad0-ab1e-0e665712fb90', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab215499-24c4-42a0-9efc-955a75f8a6c6', '26d35087-a03c-4103-bc8a-45a82722b991', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab215499-24c4-42a0-9efc-955a75f8a6c6', '6a305b77-dc22-42df-ad43-dbe68cafeb89', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab215499-24c4-42a0-9efc-955a75f8a6c6', '07f4608e-0558-45d6-be7a-3818cfefe44c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d7014800-3ba3-4483-8923-34697476473c', 'b9d6c97c-3bf6-48a8-ab66-7729acfddb83', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2bb5e2e3-ee63-41cb-aff0-df0c38464379', 'b9d6c97c-3bf6-48a8-ab66-7729acfddb83', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d6ee8e27-cd91-43c6-81db-d2c466bfc6a2', 'b9d6c97c-3bf6-48a8-ab66-7729acfddb83', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d1181a29-919f-4419-9621-84479d88b092', 'b9d6c97c-3bf6-48a8-ab66-7729acfddb83', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0b436e91-8fc4-49ad-9efd-dd5009cece84', 'b9d6c97c-3bf6-48a8-ab66-7729acfddb83', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('20ebf276-985c-4a34-9670-e8a15c319b38', 'b9d6c97c-3bf6-48a8-ab66-7729acfddb83', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2402a78b-4dca-4e49-b3ed-25df7591aa18', '7b68cc34-999c-434c-9562-a4133b64f87a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2402a78b-4dca-4e49-b3ed-25df7591aa18', '811fa331-9584-46e6-a3e9-74cc2b85629d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2402a78b-4dca-4e49-b3ed-25df7591aa18', '9561a0ff-79eb-4549-a413-8676c765a901', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7b68cc34-999c-434c-9562-a4133b64f87a', '2402a78b-4dca-4e49-b3ed-25df7591aa18', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7b68cc34-999c-434c-9562-a4133b64f87a', '811fa331-9584-46e6-a3e9-74cc2b85629d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7b68cc34-999c-434c-9562-a4133b64f87a', '9561a0ff-79eb-4549-a413-8676c765a901', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('811fa331-9584-46e6-a3e9-74cc2b85629d', '9561a0ff-79eb-4549-a413-8676c765a901', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('811fa331-9584-46e6-a3e9-74cc2b85629d', '2402a78b-4dca-4e49-b3ed-25df7591aa18', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('811fa331-9584-46e6-a3e9-74cc2b85629d', '7b68cc34-999c-434c-9562-a4133b64f87a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9561a0ff-79eb-4549-a413-8676c765a901', '811fa331-9584-46e6-a3e9-74cc2b85629d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9561a0ff-79eb-4549-a413-8676c765a901', '2402a78b-4dca-4e49-b3ed-25df7591aa18', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9561a0ff-79eb-4549-a413-8676c765a901', '7b68cc34-999c-434c-9562-a4133b64f87a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('43deac5b-f102-4b59-b362-a7a109750f8b', 'f8a656c9-fdff-4749-aaec-11b86fa73c0f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('43deac5b-f102-4b59-b362-a7a109750f8b', '47ba53b6-a029-4d0d-896a-a3bd1ec102b5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('820099be-6382-4015-b88f-635a4406a62c', '43deac5b-f102-4b59-b362-a7a109750f8b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('820099be-6382-4015-b88f-635a4406a62c', 'f8a656c9-fdff-4749-aaec-11b86fa73c0f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('820099be-6382-4015-b88f-635a4406a62c', '47ba53b6-a029-4d0d-896a-a3bd1ec102b5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0724aa3c-bf0e-4953-8088-b94e3291945d', '43deac5b-f102-4b59-b362-a7a109750f8b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0724aa3c-bf0e-4953-8088-b94e3291945d', 'f8a656c9-fdff-4749-aaec-11b86fa73c0f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0724aa3c-bf0e-4953-8088-b94e3291945d', '47ba53b6-a029-4d0d-896a-a3bd1ec102b5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f8a656c9-fdff-4749-aaec-11b86fa73c0f', '43deac5b-f102-4b59-b362-a7a109750f8b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f8a656c9-fdff-4749-aaec-11b86fa73c0f', '47ba53b6-a029-4d0d-896a-a3bd1ec102b5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d195ede-42fd-4256-9125-9ac2dd68c62b', '43deac5b-f102-4b59-b362-a7a109750f8b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d195ede-42fd-4256-9125-9ac2dd68c62b', 'f8a656c9-fdff-4749-aaec-11b86fa73c0f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d195ede-42fd-4256-9125-9ac2dd68c62b', '47ba53b6-a029-4d0d-896a-a3bd1ec102b5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39bab3c6-1a9e-4951-9f64-00b319b541c9', '43deac5b-f102-4b59-b362-a7a109750f8b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39bab3c6-1a9e-4951-9f64-00b319b541c9', 'f8a656c9-fdff-4749-aaec-11b86fa73c0f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39bab3c6-1a9e-4951-9f64-00b319b541c9', '47ba53b6-a029-4d0d-896a-a3bd1ec102b5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('47ba53b6-a029-4d0d-896a-a3bd1ec102b5', '43deac5b-f102-4b59-b362-a7a109750f8b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('47ba53b6-a029-4d0d-896a-a3bd1ec102b5', 'f8a656c9-fdff-4749-aaec-11b86fa73c0f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f98df7a-cf14-4ff3-99da-70a57639d262', '43deac5b-f102-4b59-b362-a7a109750f8b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f98df7a-cf14-4ff3-99da-70a57639d262', 'f8a656c9-fdff-4749-aaec-11b86fa73c0f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f98df7a-cf14-4ff3-99da-70a57639d262', '47ba53b6-a029-4d0d-896a-a3bd1ec102b5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('43f26816-e648-47e6-8a53-1f79751cc662', '43deac5b-f102-4b59-b362-a7a109750f8b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('43f26816-e648-47e6-8a53-1f79751cc662', 'f8a656c9-fdff-4749-aaec-11b86fa73c0f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('43f26816-e648-47e6-8a53-1f79751cc662', '47ba53b6-a029-4d0d-896a-a3bd1ec102b5', 2) ON CONFLICT DO NOTHING;



INSERT INTO public.faqs VALUES ('6897a4b5-9080-458d-b992-29a614d24c64', 'متى يوصلني الرد بعد الاشتراك؟', 'خلال 48 ساعة عمل. أيام العمل من الأحد إلى الخميس، من 12 الظهر حتى 9 مساءً، والتواصل على واتساب.', 0, true, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('38b81dcf-b011-4200-83f6-6c0189523e38', 'كيف تتم المتابعة؟', 'ترسل مراجعتك الأسبوعية في يوم المراجعة، وأرد عليك بتعديلات مسجلة (فيديو أو صوت). في الباقة الأساسية المتابعة كل أسبوعين. التواصل اليومي على واتساب مع رد خلال 48 ساعة.', 1, true, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('13a7dc0a-1aa1-4a24-9b4d-5a0be2f7f67b', 'أنا مبتدئ تماماً، هل يناسبني؟', 'نعم. البرنامج يُبنى على مستواك الحالي، والتمارين مشروحة، وتقدر ترسل مقاطع أدائك لتصحيح التكنيك.', 2, true, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('4f8d2590-c679-48bf-bef7-836b09fc55ef', 'أتمرن في البيت، ماذا أحتاج من أدوات؟', 'تحدد في النموذج الأدوات المتوفرة عندك (دمبلز، حبال مقاومة، بار…) ويُبنى جدولك عليها.', 3, true, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('a3b24e24-62c2-47c0-a6ac-ca74a0718afb', 'كيف أدفع؟', 'بتحويل بنكي بعد تعبئة الاستبيان. أول ما ترسل الاستبيان يظهر لك رقم طلبك والمبلغ وبيانات الحساب. حوّل المبلغ وارفع صورة الإيصال من صفحة طلبك، ويتأكد اشتراكك بعد التحقق من وصول المبلغ.', 4, true, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('0d74dbd8-b9fe-4667-bc05-8fd2bfe41708', 'ما شروط ضمان استرجاع المبلغ؟', 'في اشتراكات 3 أشهر لباقات المتابعة (المكثفة، المتقدمة، الأساسية): إذا لم يتحسن أي مؤشر من مؤشرات تقدمك بعد 12 أسبوعاً، يرجع لك المبلغ كاملاً.
مؤشرات التقدم (بحسب هدفك): متوسط الوزن الأسبوعي، أو محيط الخصر، أو القوة في التمارين الأساسية (الوزن أو التكرارات).
شروط الضمان:
- إرسال المراجعة الأسبوعية كل أسبوع.
- أخذ القياسات بانتظام.
- تصوير التمارين وإرسالها.
- الالتزام بجدول التغذية المخصص (في الباقات التي تشمل تغذية).
يُطلب الاسترجاع عبر واتساب خلال 14 يوماً من نهاية الأشهر الثلاثة.', 5, true, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('a91b2229-79c3-4edd-9f78-302e78de7382', 'هل الجداول لي بعد انتهاء الاشتراك؟', 'نعم، جميع الجداول لك مدى الحياة وتقدر تعدّل عليها.', 6, true, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('9c5b3b37-42a4-4de1-b21f-f296712d1db2', 'ما هو التجديد المجاني؟', 'مكافأة للملتزمين: إذا كان اشتراكك 3 أشهر تحصل على 3 أشهر إضافية مجاناً، فيصير المجموع 6 أشهر بسعر 3.
الشروط:
- نسبة التزام 90% فأكثر: المراجعات الأسبوعية المرسلة والتمارين المسجلة.
- تقدم واضح في مؤشرات التقدم نفسها المذكورة في الضمان.
- للمتدربين الرجال: إرسال صور التطور (قبل وبعد) للمدربة للتوثيق، مع تغطية الوجه والسرة.
نشر الصور في السوشل ميديا اختياري بالكامل حسب موافقتك، ولا يؤثر على استحقاقك للتجديد.', 7, true, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('8529e1fc-07d2-44b8-b1e1-7c6d3f22c889', 'من يطّلع على بياناتي؟', 'المدربة فقط، وتُستخدم لتصميم برنامجك ومتابعتك. لا تُنشر نتيجتك أو صورتك إلا بموافقتك الصريحة في النموذج.', 8, true, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;



INSERT INTO public.policies VALUES ('terms', 'الشروط والأحكام', '- يبدأ الاشتراك بعد التحقق من وصول التحويل البنكي، وتعبئة استبيان المتدرب.
- ساعات العمل: الأحد – الخميس، 12 ظهراً – 9 مساءً. الرد على الرسائل خلال 48 ساعة عمل.
- البرنامج لا يغني عن الاستشارة الطبية، والمتدرب مسؤول عن الإفصاح عن أي إصابة أو حالة صحية.
- الجداول ملك المتدرب مدى الحياة ويمكنه التعديل عليها.
- الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي.', 0, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.policies VALUES ('refund', 'الضمان والاسترجاع', '- في اشتراكات 3 أشهر لباقات المتابعة (المكثفة، المتقدمة، الأساسية): يُسترد المبلغ كاملاً إذا لم يتحسن أي من مؤشرات التقدم (متوسط الوزن الأسبوعي، محيط الخصر، القوة في التمارين الأساسية) بعد 12 أسبوعاً.
- شروط الضمان: إرسال المراجعة الأسبوعية كل أسبوع، وأخذ القياسات بانتظام، وتصوير التمارين وإرسالها، والالتزام بجدول التغذية المخصص في الباقات التي تشملها.
- يُطلب الاسترجاع عبر واتساب خلال 14 يوماً من نهاية الأشهر الثلاثة، ويُرجع المبلغ بتحويل بنكي.
- التجديد المجاني: اشتراك 3 أشهر يُكافأ بـ 3 أشهر إضافية عند التزام 90% فأكثر وتقدم واضح في مؤشرات التقدم. صور التطور تُرسل للمدربة للتوثيق (للرجال مع تغطية الوجه والسرة)، ونشرها اختياري.', 1, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.policies VALUES ('privacy', 'سياسة الخصوصية', '- نجمع: الاسم، البريد الإلكتروني (للدخول إلى حسابك)، رقم الجوال (واتساب)، الباقة المختارة، ومعلومات الاستبيان التي تكتبها بنفسك (ومنها معلومات صحية وقياسات اختيارية).
- الغرض: تنفيذ طلبك، وتصميم برنامجك ومتابعتك، والتواصل معك بخصوصه فقط.
- المعلومات الصحية تُحفظ منفصلة، ولا يطّلع عليها إلا أنت والمدربة، ولا تُرسل في رسائل البريد أو التنبيهات.
- الدفع بتحويل بنكي مباشر لحساب المؤسسة، والموقع لا يطلب أو يخزن أي بيانات بنكية أو بيانات بطاقات. إيصال التحويل يُستخدم لتأكيد طلبك فقط، ويُحفظ في تخزين خاص لا يُفتح إلا لك وللمدربة.
- لا نبيع بياناتك ولا نشاركها مع أي طرف لأغراض تسويقية، ولا تُنشر نتيجتك أو صورتك إلا بموافقتك الصريحة.
- تقدر تطلب نسخة من بياناتك أو حذفها أو سحب موافقتك على النشر بمراسلتنا على واتساب.', 2, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.policies VALUES ('reviews', 'سياسة التقييمات', '- يكتب التقييم فقط من اشترى خدمة وبدأها فعلاً، وتقييم واحد لكل طلب.
- كل تقييم يُراجع قبل ظهوره للعامة، ولا يُعدّل نصه أبداً.
- تختار بنفسك طريقة ظهور اسمك: الاسم كامل، أو الاسم الأول فقط، أو بدون اسم. والموافقة على النشر منفصلة واختيارية.
- لا يُنشر تقييم يحتوي أرقام هواتف أو بريد أو روابط أو تفاصيل صحية خاصة أو إساءة لأي شخص.
- يحق للمدربة الرد على التقييم، أو إخفاء التقييم المخالف لهذه السياسة مع تسجيل السبب.
- تقدر تطلب إخفاء تقييمك في أي وقت بمراسلتنا على واتساب.', 3, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;



INSERT INTO public.products VALUES ('ffc30e10-4984-4e59-873c-fe324b5d2505', 'intensive', 'follow', 'الباقة المكثفة', 'الأنسب للمبتدئين ولمن يحتاج متابعة أسبوعية مع زوم: تمرين + تغذية + زوم + جلسة حضورية', '[{"text": "جلسة حضورية مجانية لمدة ساعة لتصحيح التكنيك والتأكد من جودة التمرين (للبنات في المنطقة الشرقية)", "included": true}, {"text": "ملف شامل للخطة التدريبية والتغذية مع شروحات وافية للتمارين، بالمنزل أو بالنادي", "included": true}, {"text": "4 مكالمات زوم شهرياً نتابع فيها تطورك واستفساراتك الرياضية والنفسية", "included": true}, {"text": "مناقشة أسبوعية لتطورك البدني والنفسي (فيديو أو تسجيل صوتي) مع تعديل السعرات أو التمرين عند الحاجة", "included": true}, {"text": "شرح سهل ومبسط لتطبيق حساب السعرات MyFitnessPal", "included": true}, {"text": "كتيب شامل للرياضة والتغذية", "included": true}, {"text": "مساعدتك على اختيارات أنسب لصحتك ونمط حياتك في التغذية والروتين اليومي", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}]', NULL, 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.', true, NULL, 'published', 0, false, '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('35ca0373-4999-416a-b5ee-7bfffe58e14f', 'advanced', 'follow', 'الباقة المتقدمة', 'لمن عنده خبرة ويحتاج تمرين + تغذية مع متابعة أسبوعية، بدون زوم', '[{"text": "ملف شامل للخطة التدريبية والتغذية مع شروحات وافية للتمارين، بالمنزل أو بالنادي", "included": true}, {"text": "مناقشة أسبوعية لتطورك البدني والنفسي (فيديو أو تسجيل صوتي) مع تعديل السعرات أو التمرين عند الحاجة", "included": true}, {"text": "كتيب شامل للرياضة والتغذية", "included": true}, {"text": "مساعدتك على اختيارات أنسب لصحتك ونمط حياتك في التمرين والروتين اليومي", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}, {"text": "مكالمات زوم والجلسة الحضورية (في المكثفة فقط)", "included": false}]', NULL, 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.', false, NULL, 'published', 1, false, '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('1cb11474-bd6f-41a3-b52a-4317720e6020', 'basic', 'follow', 'الباقة الأساسية', 'لمن يعرف يضبط أكله ويحتاج خطة تمرين فقط، ومتابعة كل أسبوعين', '[{"text": "ملف شامل للخطة التدريبية مع شروحات وافية للتمارين، بالمنزل أو بالنادي", "included": true}, {"text": "مناقشة كل أسبوعين لتطورك البدني والنفسي (فيديو أو تسجيل صوتي) مع تعديل التمرين عند الحاجة", "included": true}, {"text": "كتيب شامل للرياضة والتغذية", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}, {"text": "بدون خطة تغذية", "included": false}]', NULL, 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.', false, NULL, 'published', 2, false, '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('5acf5171-e3d6-4ba2-8077-e819d8df03ce', 'nutrition', 'follow', 'باقة التغذية', 'لمن يحتاج خطة تغذية شاملة ويتعلم حساب السعرات، بدون خطة تمرين', '[{"text": "خطة تغذية شاملة تناسب هدفك ونمط حياتك", "included": true}, {"text": "تحديد السعرات المناسبة لك ولهدفك", "included": true}, {"text": "تعليمك حسبة السعرات ومساعدتك باختيارات تغذية تناسبك", "included": true}, {"text": "ملف Excel لمتابعة التطور والقياسات", "included": true}, {"text": "مناقشة أسبوعية لعلاقتك بالتغذية في المنزل أو خارجه", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}, {"text": "لا تحتاجها إذا كنت مشتركاً في المكثفة أو المتقدمة، لأن التغذية ضمنها", "included": false}]', 'شهر واحد · غالباً لا تحتاج تجديد', 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي، ولا يوجد تجديد تلقائي. ضمان الاسترجاع يشمل اشتراكات 3 أشهر للمكثفة والمتقدمة والأساسية فقط.', false, NULL, 'published', 3, false, '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('a133013d-b999-417b-8273-9879b5f27c2e', 'custom-training-plan', 'files', 'بديل التدريب الشخصي', 'لمن لا يحتاج متابعة (متقدم)، أو كبديل أوفر للتدريب الشخصي', '[{"text": "جدول تمرين مخصص لعدد أيام التمرين اللي تحتاجها", "included": true}, {"text": "طريقة حساب الجهد وعدد الجولات المطلوبة", "included": true}, {"text": "تقدر تحمّل الجدول على جهازك", "included": true}]', NULL, 'جدول مخصص بعد الاستبيان تستلمه كملف، وتقدر تحمّله على جهازك. بدون متابعة.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي. الجداول لك مدى الحياة وتقدر تعدّل عليها.', false, NULL, 'published', 4, false, '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('4a3af901-6b1c-4811-aa7d-0092a5baa697', 'training-nutrition-plan', 'files', 'جدول تمارين مع التغذية', 'لمن لا يحتاج متابعة (متقدم)، أو كبديل أوفر للتدريب الشخصي', '[{"text": "جدول تمرين مخصص لعدد أيام التمرين اللي تحتاجها", "included": true}, {"text": "طريقة حساب الجهد وعدد الجولات المطلوبة", "included": true}, {"text": "جدول تغذية فيه خيارات تناسب هدفك الرياضي", "included": true}, {"text": "تقدر تحمّل الجدول على جهازك", "included": true}]', NULL, 'جدول مخصص بعد الاستبيان تستلمه كملف، وتقدر تحمّله على جهازك. بدون متابعة.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي. الجداول لك مدى الحياة وتقدر تعدّل عليها.', false, NULL, 'published', 5, false, '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('57b4bde9-ab09-4fde-8e61-3a72326552f7', 'nutrition-consultation', 'consult', 'جلسة استشارة تغذية', 'لمن عنده أسئلة محددة في التغذية: جلسة وحدة تكفي لحسبة سعراتك ونصائح الأكل.', '[{"text": "مناقشة كل أسئلتك في مجال التغذية", "included": true}, {"text": "حسبة سعرات مناسبة لهدفك مع اقتراحات لأصناف الطعام", "included": true}, {"text": "نصائح في المكملات، وكيف تأكل برّا بطريقة صحيحة", "included": true}]', NULL, 'جلسة عبر Google Meet أو واتساب — المناسب لك.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي.', false, NULL, 'published', 6, false, '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('9c2e6d70-9385-45d6-83a4-025657bef77e', 'training-consultation', 'consult', 'جلسة استشارة تمرين', 'لمن عنده أسئلة محددة في التمرين: جلسة وحدة تكفي لتعديل جدولك وتصحيح التكنيك.', '[{"text": "مناقشة كل أسئلتك في مجال التمرين", "included": true}, {"text": "تعديل جدولك الرياضي بما يناسب هدفك، مع اقتراحات لتمارين المرونة", "included": true}, {"text": "تصحيح تكنيك التمارين اللي تشك إنها غلط أو تسبب لك ألم", "included": true}, {"text": "التأكد من أن جودة تمرينك مناسبة للبناء العضلي", "included": true}]', NULL, 'جلسة عبر Google Meet أو واتساب — المناسب لك.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي.', false, NULL, 'published', 7, false, '2026-09-27 12:11:58.471849+00', '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;



INSERT INTO public.product_offers VALUES ('deb18d89-c869-4509-9b10-e027681ae8d9', 'ffc30e10-4984-4e59-873c-fe324b5d2505', 'int1', 'شهر واحد', 1, 59900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('e91de6f2-b341-4c59-8197-f2a305e7af60', 'ffc30e10-4984-4e59-873c-fe324b5d2505', 'int3', '3 أشهر', 3, 155000, 'SAR', true, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('fe9cdf55-d9b7-4a2b-bec2-188d59808a5d', '35ca0373-4999-416a-b5ee-7bfffe58e14f', 'adv1', 'شهر واحد', 1, 49900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('c2e3f205-2908-4d9b-9240-d63ced537f74', '35ca0373-4999-416a-b5ee-7bfffe58e14f', 'adv3', '3 أشهر', 3, 125000, 'SAR', true, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('1b6ed734-01d7-464a-b2a1-a1f48909dc0f', '1cb11474-bd6f-41a3-b52a-4317720e6020', 'bas1', 'شهر واحد', 1, 34900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('d5cd8919-9da1-4f9b-9811-1c121ebcb1ba', '1cb11474-bd6f-41a3-b52a-4317720e6020', 'bas3', '3 أشهر', 3, 95000, 'SAR', true, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('981af861-7ed6-4a6c-9791-5b798c453805', '5acf5171-e3d6-4ba2-8077-e819d8df03ce', 'nut1', 'شهر واحد', 1, 25000, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('4124fb66-7764-43cf-9953-5d50cec1d7d7', 'a133013d-b999-417b-8273-9879b5f27c2e', 'diy', 'دفعة واحدة', 0, 19900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('cb61aab6-2630-4daf-97c9-6b16ef9abe65', '4a3af901-6b1c-4811-aa7d-0092a5baa697', 'diyN', 'دفعة واحدة', 0, 25000, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('d338b6cf-17da-48b7-9fcc-79f92f5e8b7b', '57b4bde9-ab09-4fde-8e61-3a72326552f7', 'cN', 'دفعة واحدة', 0, 15000, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('bd8bb48e-5aef-4e19-b91b-63205be630cf', '9c2e6d70-9385-45d6-83a4-025657bef77e', 'cT', 'دفعة واحدة', 0, 18900, 'SAR', true, 0) ON CONFLICT DO NOTHING;



INSERT INTO public.reviews VALUES ('ad5cefb0-f928-43ea-9041-84b3f85a65aa', 'legacy', NULL, NULL, NULL, NULL, 'اشتركت معها 3 شهور وكانت أول مره التزم بالتمرين بعد سحبات سنين، اسلوبها سهل وسريع بس نتايجه واضحه من اول اسبوعين قياسات جسمي بدت تتغير والكوتش مريحه نفسيًا وشاطرة الله يعطيها العافيه غيرت حياتي واعطتني افضل بداية 🙏🏻', 'first', 'ريم', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 0, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('2b433ae9-8e0a-4788-a70c-082470b89849', 'legacy', NULL, NULL, NULL, 5, 'من أصدق التجارب اللي مرّيت فيها! تدريبك ما كان بس جداول رياضه وتغذية كان دعم نفسي وتحفيز وتغيير حقيقي في حياتي حسّيت بفرق كبير في جسمي وطاقتي وثقتي بنفسي من أول أسبوع شكراً من القلب على تعبك وحرصك على كل تفصيلة وتعطي من قلبك، فعلاً you are the best coach ever تستاهلين كل النجاح والله ❤️', 'first', 'نورة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 1, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('23864526-9e5c-4a5b-b959-22aa20ffebcf', 'legacy', NULL, NULL, NULL, 5, 'بعد شهر من الالتزام بالجدول، لاحظت فرق واضح! متنوع وفعال، أنصح فيه بشدة 😍👌', 'first', 'البندري', 'مارس 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 2, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('f4fe9dc4-8c73-4286-8e47-ef2990c289cb', 'legacy', NULL, NULL, NULL, NULL, 'رغم ان فتره تدريبي معاها كانت اقل من شهرين السنه الماضيه الا ان نتايج هالشهرين مستمره معي الى اليوم 😍 اسلوب احترافي وفعال وتركز على بناء وتطوير عادات تدوم مو بس تمارين مؤقته 👍🏻', 'first', 'خديجة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 3, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('a52b5445-bbb0-47e9-b342-21d722b4f4e7', 'legacy', NULL, NULL, NULL, 5, 'كوتش ساره جداً شاطره و بروفيشنال، جداً متعاونه و تعرف شغلها كويس، جداً لطيفه، كنت لفتره متدربه عندها و كنت أشوف نتايج بطله بالاضافه لكوني اروح اتمرن و أنا مستمتعه، شكراً ساره', 'first', 'نجمة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 4, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('b524fecb-ffdf-4895-8075-5b3c19743bdf', 'legacy', NULL, NULL, NULL, 5, 'ممتاز جدول حلو ومرتب جدا وفرق معي كثير 🤍', 'first', 'سعود', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 5, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('f6719d3d-0887-47ba-9501-02f5787feec0', 'legacy', NULL, NULL, NULL, 5, 'كنت اعاني من الم بظهري مستمررر سنوات وانحراف بالعمود ولكن بفضل الله ثم المدربة تحسنت بنسبة كبيرة وتابع معي خطوة بخطوة بكل أمانة وإتقان الله يكثر من امثالك 🤍', 'first', 'ش**س**', 'أغسطس 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 6, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('33fec562-d955-4a80-bbd3-95595fe00b08', 'legacy', NULL, NULL, NULL, 5, 'الشكر يعجز عنك يااروع كوتش باشتراكي معك شفت صحة وراحة بعد الله وساعدتيني مره بمشكلة ظهري وضعف العضلات العلوية وانعكس على نفسيتي وادائي اليومي شكررا شكرا من القلب وياحظنا فيك', 'first', 'فاطمة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 7, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('f2688306-b6e6-4a93-b3b9-51555b978250', 'legacy', NULL, NULL, NULL, 5, 'مره استفدت بالتدريب مع كوتش ناف و مبسوطه ان في احد بذمة و ضمير جالس يتابع تقدمي و ينصحني من قلب الله يسعدك ويوفقك ❤️', 'first', 'ميثاء', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 8, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('35149445-25c1-422d-9a27-40c4ab599b78', 'legacy', NULL, NULL, NULL, 5, 'تجربه ولا أروع ! أحب جداولها وقد ايش تختصر وتعطيك المهم والاهم والنتايج رهيييبه ❤️', 'first', 'أمجاد', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 9, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('c8663f6f-0689-4f11-95a6-766841c1a300', 'legacy', NULL, NULL, NULL, 5, 'افضل مدربة بالمجرة، كنت دبه ونحفت بثلاث شهور بس، i highly recommend her she is the best 💗', 'first', 'شروق', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 10, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('48fb0456-4bc9-43a1-b4b9-fb0fa3c666b3', 'legacy', NULL, NULL, NULL, 5, 'الجدول ممتاز و فعّال لفترة الصيام، يساعدك تنظم وقتك ويقدّم توصيات غذائيه و خطه تمارين تساعدك تحافظ على لياقتك بدون إرهاق 👍🏻. خيار ممتاز خاصة للأشخاص للي وقتها محدود ومزحوم فرمضان.', 'first', 'خديجة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 11, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;



INSERT INTO public.site_settings VALUES ('reminders', '{"review_text": "مرحباً {name}، تذكير بمراجعتك الأسبوعية: المراجعة مفتوحة من {window_start} إلى {window_end}.", "sub_expiry_days": [7, 3], "sub_expiry_text": "مرحباً {name}، اشتراكك في {product} ينتهي بتاريخ {end_date}. للتجديد أو الاستفسار تواصل معنا.", "review_lead_days": 1, "missed_review_text": "مرحباً {name}، ما وصلتنا مراجعة الأسبوع المنتهي في {window_end}. متى ما تيسّر لك، حدّثها عشان نتابع تقدمك.", "review_window_days": 2, "manual_cooldown_minutes": 10}', false, NULL, '2026-09-27 12:11:58.268655+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('hero', '{"lead": "خطة تدريب وغذاء منظمة، متابعة للتقدم، وتعديلات أسبوعية تناسب مستواك وظروفك.", "title": "برامج تدريب وتغذية مخصصة لأهدافك", "eyebrow": "Nav Coaching · الكوتش ساره", "tagline": "Where Passion Meets Quality", "title_tail": "تحت إشراف مدربة يدفعها الشغف"}', true, NULL, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('badges', '["خصم 10% للطلاب", "مجاني لأهل غزة", "ضمان استرجاع المبلغ بشروط"]', true, NULL, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('why', '[{"body": "البرنامج يُصمم بعد استبيان مفصل لهدفك وأيامك المتاحة وأدواتك وأي إصابة تحتاج مراعاة.", "title": "مبني على هدفك ومستواك"}, {"body": "مراجعة منتظمة بالفيديو أو الصوت، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.", "title": "متابعة أسبوعية واضحة"}, {"body": "نعدّل التمرين والسعرات بناءً على قياساتك والتزامك، عشان تثبت النتيجة.", "title": "تعديلات حسب تقدمك"}]', true, NULL, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('how_steps', '[{"body": "اختر الباقة والمدة، وعبّي استبيان قصير عن هدفك ومستواك وأيامك وأي إصابة.", "title": "اختر برنامجك وعبّي الاستبيان"}, {"body": "بعد الاستبيان يظهر لك رقم طلبك وبيانات الحساب. حوّل وارفع صورة الإيصال من صفحة طلبك.", "title": "حوّل المبلغ"}, {"body": "بعد التحقق من التحويل أتواصل معك خلال 48 ساعة عمل، وتستلم ملف برنامجك وتبدأ المتابعة.", "title": "استلم برنامجك وابدأ"}]', true, NULL, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('about', '{"bio": "مدربة شخصية معتمدة، أدرب منذ 2017. أساعدك تبني روتين تدريب وتغذية واضح يناسب هدفك ووقتك ومستواك، مع متابعة أسبوعية تساعدك تستمر وتتقدم.", "fit": ["اللي يؤمن إن التمرين أسلوب حياة، مو تمرين لشكل مؤقت أو لفترة الصيف بس.", "**وإذا ما التزمت؟** أحاول أفهم أسبابك، وأساعدك تعالجها بقدر ما أقدر. وإذا كان الموضوع أكبر من اللي أقدر أقدمه، أقول لك بصراحة وأعتذر عن تدريبك."], "name": "الكوتش ساره | ناڤ", "certs": ["Saudi Reps — Level 4", "NCSF", "Menno Henselmans CPT", "Functional Mobility", "Pre & Postnatal Training", "Prenatal Fitness Training — Aspire Academy", "ماجستير تدريب رياضي — جامعة ستيرلنق"], "notes": [{"body": "لأني جاية من عالم الرياضات الإلكترونية، صممت باقة خاصة للقيمرز: لياقة أفضل داخل وخارج الشاشة، والتعامل مع آلام الظهر والمفاصل من الجلوس الطويل.", "href": "/programs/gamers", "label": "شوف باقة القيمرز ←", "title": "للاعبي الألعاب الإلكترونية"}, {"body": "تدريب الحوامل عندي حضوري فقط. أونلاين يصعب أتأكد إن التمرين يتنفذ بإتقان، والحمل فترة مهمة جداً تحتاج هالتأكد. أونلاين أقدم للحوامل متابعة التغذية فقط.", "href": "", "label": "", "title": "للحوامل"}], "story": ["قبل ما أصير مدربة، كنت متدربة تعبت من التجارب. اشتركت مع مدربات أجانب، وما لقيت أحد يشرح لي التمرين صح أو يهتم بأهدافي.", "لين اشتركت مع الكوتش سحر الحارثي. غيّرت نظرتي للتمرين، وحفّزتني أصير كوتش، وإلى اليوم أشكرها على كل اللي علمتني إياه. من هنا قررت أكون الشخص اللي احتجته أنا.", "والرياضة جزء مني من بدري: لعبت كرة السلة وكنت كابتن فريق السلة في جامعة الإمام عبدالرحمن بن فيصل، ولعبت باحتراف في الرياضات الإلكترونية. بدأت التدريب في 2017 مع كرة السلة، واشتغلت مساعد مدرب في نادي الجامعة، وبعدها دربت في بيور جم وجمنيشن وفتنس لاونج ونوادي خاصة."], "points": ["برنامج مبني على هدفك ومستواك.", "متابعة أسبوعية واضحة.", "تعديلات مستمرة حسب تقدمك والتزامك."], "pillars": [{"body": "ما أرسل لك جدول وأتركك. أراجعه معك بمقطع فيديو أشرح فيه كل شي، عشان تبدأ وأنت فاهم وش تسوي وليش.", "title": "جدولك مشروح بالفيديو"}, {"body": "ما أمشي على أنظمة الحرمان أبداً. خطتك تناسب حياتك، مو قائمة ممنوعات.", "title": "بدون حرمان"}, {"body": "أتابعك كل أسبوع وأهتم بالتزامك، وأعدّل خطتك حسب تقدمك وظروفك.", "title": "متابعة جادة وخطة واقعية"}, {"body": "حب تعليم الناس معي من الصغر. اللي أعرفه ما أبخل فيه، علمياً ونفسياً، وما أوقف عن البحث والتعلم عشان أتطور وأطورك معي.", "title": "أعلّمك، مو بس أدربك"}], "home_bio": "مدربة شخصية معتمدة، أدرب منذ 2017، وكابتن سابقة لفريق السلة في جامعة الإمام عبدالرحمن بن فيصل. أساعدك تبني روتين تدريب وتغذية واضح يناسب هدفك ووقتك ومستواك، مع متابعة أسبوعية وبدون أنظمة حرمان.", "fit_title": "أكثر شخص أفرق معه", "experience": ["أدرب منذ 2017، والبداية في كرة السلة.", "مساعد مدرب في نادي الجامعة.", "مدربة في بيور جم، وجمنيشن، وفتنس لاونج، ونوادي خاصة."], "story_title": "صرت الشخص اللي كنت أحتاجه", "pillars_title": "وش يميز التدريب معي؟", "experience_title": "شهاداتي وخبرتي"}', true, NULL, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('intro_video', '{"url": "", "body": "مقطع قصير أتكلم فيه عن نفسي وخلفيتي وطريقة شغلي مع المتدربين.", "title": "تعرّف عليّ في دقيقة"}', true, NULL, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('testimonials_disclaimer', '"التجارب شخصية وتختلف النتائج من شخص لآخر حسب الالتزام والحالة، والتدريب لا يغني عن استشارة الطبيب أو أخصائي العلاج الطبيعي."', true, NULL, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('prices_note', '"الأسعار بالريال السعودي. الدفع بتحويل بنكي على حساب المؤسسة."', true, NULL, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('checkins', '{"enabled": true, "questions": [{"q": "ملاحظاتك الصحية؟ الحركة اليومية وجودة الحياة صارت أحسن؟", "topic": "الصحة العامة"}, {"q": "أداؤك في التمارين؟ في تقدم في الأوزان والأداء؟", "topic": "التمارين"}, {"q": "فرق في شكلك ومظهرك؟ إيجابي أو سلبي؟", "topic": "المظهر"}, {"q": "فرق في الملابس أو المقاسات؟ إيجابي أو سلبي؟", "topic": "الملابس"}, {"q": "النظام الغذائي — قدرت تمشي عليه؟ فيه صعوبة؟", "topic": "الغذاء"}, {"q": "تحسّ بالجوع واجد؟ إن وُجد، كم تعطيه من 5؟", "topic": "الجوع"}, {"q": "أي ملاحظات سلبية تبي تشاركها؟ (مهمة أو بسيطة — نتقبل النقد)", "topic": "ملاحظات سلبية"}, {"q": "أي إشكاليات أو ملاحظات إضافية تحتاج مساعدة فيها؟", "topic": "ملاحظات أخرى"}, {"q": "وصلت لأي أسبوع تدريبي الآن؟", "topic": "الأسبوع"}]}', true, NULL, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('contact', '{"whatsapp": "966599162724", "instagram": "https://www.instagram.com/navvcoaching/"}', true, NULL, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('response_time', '"48 ساعة عمل (الأحد – الخميس، 12 ظهراً – 9 مساءً)"', true, NULL, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('legal', '{"cr": "7050950752", "name": "مؤسسة ناف كوتشنق للتدريب الرياضي"}', true, NULL, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('bank', '{"iban": "SA1280000139608016245411", "bankName": "مصرف الراجحي", "accountName": "مؤسسة ناف كوتشنق للتدريب الرياضي"}', true, NULL, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('program_shots', '[{"h": 368, "w": 1310, "alt": "لقطة من ملف المتدرب: جدول اليوم الأول لتمارين الجزء السفلي مع الجولات والتكرارات وRIR", "src": "shots/training.webp", "title": "جدول التمرين", "caption": "جدول لكل يوم تدريبي: التمرين، الجولات، التكرارات، الوزن، وRIR، وتظهر العضلة الأساسية والثانوية تلقائياً."}, {"h": 473, "w": 1472, "alt": "لقطة من ملف المتدرب: قائمة منسدلة لاختيار التمرين أو البديل مع العضلة الأساسية والثانوية", "src": "shots/exercise-picker.webp", "title": "اختيار التمرين والبدائل", "caption": "تختار التمرين أو بديله من قائمة منسدلة، وتتحدث العضلات المستهدفة مباشرة."}, {"h": 634, "w": 1034, "alt": "لقطة من لوحة التقدم في ملف المتدرب ببيانات مثال: الوزن والقياسات والخطوات الأسبوعية مقابل الهدف", "src": "shots/progress.webp", "title": "لوحة التقدم", "caption": "متوسط الوزن الأسبوعي والقياسات والخطوات مقابل الهدف، ببيانات مثال."}, {"h": 641, "w": 1600, "alt": "لقطة من ورقة المراجعة الأسبوعية في ملف المتدرب: أسئلة المراجعة بدون إجابات", "src": "shots/weekly-review.webp", "title": "المراجعة الأسبوعية", "caption": "أسئلة ثابتة كل أسبوع عن الصحة والتمارين والغذاء والجوع، وبجانبها ملاحظات المدربة."}]', true, NULL, '2026-09-27 12:11:58.471849+00') ON CONFLICT DO NOTHING;
COMMIT;
