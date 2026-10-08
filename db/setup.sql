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

-- ---------- المحتوى المستورد من الموقع الحالي ----------
INSERT INTO public.exercises VALUES ('35ae948b-d31a-43b8-b86c-f425c067c81e', 'Seated Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/0G3W83dFUeY', 'اسحب باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness | تحدب الظهر / Postural Thoracic Kyphosis', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', 'تقوية سحب وانكماش لوح الكتف', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moseley et al. 1992 — AJSM (EMG, scapular muscles) | Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://pubmed.ncbi.nlm.nih.gov/1558238/ | https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5a6c9231-42c7-4ddd-b705-e2cb1e097b92', 'Forward Lunges', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/_DLAdo2Pvjs', 'تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness | ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, 'تقوية الورك ضمن نمط حركي وظيفي', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Distefano et al. 2009 — JOSPT (EMG) | Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin)', 'https://pubmed.ncbi.nlm.nih.gov/19574661/ | https://pubmed.ncbi.nlm.nih.gov/33344003/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8bec3fb9-fac7-4ee9-a8dc-8ecbd8422cc1', 'Bird Dog', 'Core / البطن والكور', '{"Lower back / أسفل الظهر","Glutes / المؤخرة"}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/L91QMACdA6Q?si=KBnuQDcm9WcUXxxI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Anti-Rotation / مقاومة الدوران', 'Isometric Anti-Rotation / تثبيت الجذع ضد الدوران', NULL, 'التحكم الحركي وتحمّل الجذع', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d97fb29b-e445-42d9-9586-9ab47575eaa6', 'Single Leg Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'وزن الجسم', 'متقدم', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/136/single-leg-squat/', 'ضعف الألوية الكبرى / Gluteus Maximus Weakness | ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Single-leg Squat / سكوات رجل واحدة', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, 'تقوية باسطات ومبعدات الورك وتحكم أحادي الطرف', 'متقدمة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ يتطلب تحكماً جيداً بالركبة والحوض', 'Distefano et al. 2009 — JOSPT (EMG) | Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin)', 'https://pubmed.ncbi.nlm.nih.gov/19574661/ | https://pubmed.ncbi.nlm.nih.gov/33344003/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1c40d006-2c7b-4c03-ab54-334d9db3a4a9', 'Hip Abduction', 'Abductors / مبعدات الفخذ', '{"Glutes / المؤخرة"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/_ARUxqrII3Y?si=Jcz5uh2Uu-IdVCS1', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL, 'تقوية مبعدات الورك بمقاومة خارجية', 'مبكرة–متوسطة', 'منخفض–متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ الدليل يخص إبعاد الورك بمقاومة خارجية؛ يُتحقق من نوع الأداء', 'Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin)', 'https://pubmed.ncbi.nlm.nih.gov/33344003/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0af7ce9e-dd17-4487-9608-c7903f661ba4', 'Side Step Up', 'Glutes / المؤخرة', '{"Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/xOwIRnI4VxA?si=SJOgODRmNGdfHPb4', 'يد فيها الوزن واليد الثانية سندها على الجدار', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية المتوسطة / Gluteus Medius Weakness | ضعف الألوية الصغرى / Gluteus Minimus Weakness', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, 'تقوية مبعدات الورك والتحكم بالحوض على رجل واحدة', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin) | Ganderton et al. — GMin/GMed EMG (RMIT University)', 'https://pubmed.ncbi.nlm.nih.gov/33344003/ | https://research-repository.rmit.edu.au/articles/journal_contribution/Gluteus_Minimus_and_Gluteus_Medius_Muscle_Activity_during_Common_Rehabilitation_Exercises_in_Healthy_Postmenopausal_Women/27572301', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('78269001-0f21-480e-a6d2-a6fe6f688b17', 'Glute Bridge', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', NULL, 'مبتدئ', NULL, 'https://www.youtube.com/watch?v=dtlGynVdHYM', 'ممكن تسويه بالسميث مشين او البار الحر ، اختر بوكس او بنش يكون بمستوى اكتافك الخلفية وانت جالس، لما ترفع البار فوق المفروض ركبك تكون بنفس مستوى القدم.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness | آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, 'تقوية بسط الورك وتحمّل الجذع', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Boren et al. 2011 — IJSPT (EMG) | JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/22034614/ | https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('090d298e-0479-4098-845d-c876651a4a5b', 'DB Floor Glute Bridge', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/iOrJXNUH3to?si=JySX6JMhoP2vWEVa', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, 'تقوية بسط الورك بتحميل خارجي متدرج', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Boren et al. 2011 — IJSPT (EMG)', 'https://pubmed.ncbi.nlm.nih.gov/22034614/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ea80faf4-0e7f-4068-b184-8686b12b890c', 'Single DB RDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/U3prDlAbJDw?si=MRSBcSIcf9M-WQBH', 'وقف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، انزل وادفع مؤخرتك لآخر شي تقدر عليه للخلف وكأنك بتلمس جدار خلفك مع انثناء بسيط بالركب', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, 'تقوية باسطات الورك وتحكم أحادي الطرف', 'متقدمة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ مع الحفاظ على وضع محايد للظهر', 'Distefano et al. 2009 — JOSPT (EMG)', 'https://pubmed.ncbi.nlm.nih.gov/19574661/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('58064354-9d2a-4e72-b499-1c699759a3ea', 'Upper Back Horizontal Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/TSWohpfMlso', 'ثبت نفسك بالكرسي، فتحة واسعة، الكيبل بمستوى أعلى صدرك، واسحب لما تنقبض الترابز.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Wide-grip Row / تجديف بقبضة واسعة', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', 'تقوية انكماش لوح الكتف والظهر العلوي', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moseley et al. 1992 — AJSM (EMG, scapular muscles)', 'https://pubmed.ncbi.nlm.nih.gov/1558238/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('103462c2-4bc7-4e57-9b92-1a85cc4b6478', 'Band Seated Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/Jy-WCFAofBY?si=9gqVby588rk1zFi9', 'فتحة واسعة، واسحب لما تنقبض عضلات الظهر.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness | تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', 'تقوية سحب لوح الكتف بمقاومة منخفضة', 'مبكرة–متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moseley et al. 1992 — AJSM (EMG, scapular muscles) | Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://pubmed.ncbi.nlm.nih.gov/1558238/ | https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d028abb6-5a86-401b-b979-e646b4353765', 'Chest Supported Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/DgHtyrQEMJ4?si=oTfTKVgD9j1H12wA', 'ثبت صدرك على الكرسي، فتحة واسعة، واسحب لما تنقبض عضلات الظهر.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', 'تقوية انكماش لوح الكتف مع دعم الجذع', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moseley et al. 1992 — AJSM (EMG, scapular muscles)', 'https://pubmed.ncbi.nlm.nih.gov/1558238/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6782b7c5-7f85-4676-8b25-5e42bd760f1f', 'Plank', 'Core / البطن والكور', '{"Shoulders / الأكتاف","Glutes / المؤخرة"}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/pvIjsG5Svck?si=cTP8ZyfMAJPfaEhw', 'لما ترتفع الاكتاف تكون فوق الكوع والرجل ممتدة بالكامل.', NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL, 'تحمّل عضلات الجذع', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b3eed6cc-e3dd-472d-90a3-9e1799c80b2f', 'deadbug', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/g_BYB0R-4Ws?si=D4nwJri73eBqJRqL', NULL, 'اسم مشابه موجود في المكتبة (deadbug / dead bug) — تُراجَع قبل الحذف أو الدمج', 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'rejected', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL, 'التحكم الحركي وتحمّل الجذع', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('bd114250-7f1c-4006-8e47-c4d95ad91568', 'Band Dead Bug', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'مطاط', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/iW_CtYtzbeU?si=Epequw3rqA3_TwTr', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL, 'التحكم الحركي وتحمّل الجذع بمقاومة', 'مبكرة–متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a4ad49a4-f13b-4be5-92b9-27590f335641', 'Side Plank', 'Core / البطن والكور', '{"Abductors / مبعدات الفخذ","Shoulders / الأكتاف"}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'لما ترتفع الاكتاف تكون فوق الكوع والرجل ممتدة بالكامل.', NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain | ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Anti-Lateral Flexion / مقاومة الميلان الجانبي', 'Isometric Anti-Lateral Flexion / تثبيت الجذع ضد الميلان', NULL, 'تحمّل الجذع الجانبي وتنشيط مبعدات الورك', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.) | Boren et al. 2011 — IJSPT (EMG)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/ | https://pubmed.ncbi.nlm.nih.gov/22034614/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('90615188-a65f-44e4-942d-ad35ddf9c62c', 'McGill Big 3', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/jZylx81_kfg?si=_jP064GZIzvEvzyN', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Mixed (McGill Big 3) / مختلط', 'Isometric Trunk Stabilization / تثبيت الجذع', NULL, 'التحكم الحركي وتحمّل الجذع', 'مبكرة–متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7c0fa428-a5c6-4f85-a313-fad191dff3d8', 'Dead Bug', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/bxn9FBrt4-A', 'نحرك الرجلين ببطئ قليلا و بتحكم باستخدام عضلات البطن', 'اسم مشابه موجود في المكتبة (deadbug / dead bug) — تُراجَع قبل الحذف أو الدمج', 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL, 'التحكم الحركي وتحمّل الجذع', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ffa011dc-3bcd-4e16-93d3-02237b1ac742', 'High-Load Heel Raise (Towel Under Toes)', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', NULL, 'مبتدئ', NULL, NULL, 'رفع الكعب على رجل واحدة مع منشفة ملفوفة تحت أصابع القدم؛ صعود بطيء ثم ثبات قصير ثم نزول بطيء.', 'أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Rathleff et al. 2015 — Scand J Med Sci Sports (RCT)', 'https://doi.org/10.1111/sms.12313', 'اللفافة الأخمصية / Plantar Fasciopathy', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL, 'تحميل تدريجي للقدم والكاحل', 'متقدمة', 'مرتفع', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ يُبدأ بعد تحسّن الأعراض وبتدرّج', 'Rathleff et al. 2015 — Scand J Med Sci Sports (RCT) | JOSPT CPG 2023 — Heel Pain/Plantar Fasciitis (Koc et al.)', 'https://doi.org/10.1111/sms.12313 | https://pubmed.ncbi.nlm.nih.gov/38037331/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d11e78a8-2a76-4f30-839b-ecf5aa6a4139', 'Side Lunge', 'Adductors / الأفخاذ الداخلية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/50/side-lunge/', 'ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Lateral Lunge / لانج جانبي', 'Knee/Hip Extension + Hip Adduction / مد الركبة والورك + تقريب الورك', NULL, 'تقوية مبعدات الورك والتحكم بالحوض', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin)', 'https://pubmed.ncbi.nlm.nih.gov/33344003/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('69c18108-c7d7-4409-836d-fdf84299ca0e', 'Hip Hitch (Pelvic Drop)', 'Abductors / مبعدات الفخذ', '{}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Ganderton et al. — GMin/GMed EMG (RMIT University)', 'https://research-repository.rmit.edu.au/articles/journal_contribution/Gluteus_Minimus_and_Gluteus_Medius_Muscle_Activity_during_Common_Rehabilitation_Exercises_in_Healthy_Postmenopausal_Women/27572301', 'ضعف الألوية المتوسطة / Gluteus Medius Weakness | ضعف الألوية الصغرى / Gluteus Minimus Weakness', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Pelvic Drop (Stance Leg) / تثبيت الحوض برجل الارتكاز', 'Hip Abduction of Stance Leg / تبعيد ورك رجل الارتكاز', NULL, 'تنشيط وتقوية مبعدات الورك (الألوية المتوسطة والصغرى) والتحكم بالحوض', 'مبكرة–متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Ganderton et al. — GMin/GMed EMG (RMIT University) | Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin)', 'https://research-repository.rmit.edu.au/articles/journal_contribution/Gluteus_Minimus_and_Gluteus_Medius_Muscle_Activity_during_Common_Rehabilitation_Exercises_in_Healthy_Postmenopausal_Women/27572301 | https://pubmed.ncbi.nlm.nih.gov/33344003/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c889ca22-53bf-4a80-a02e-cc95bf0a77b4', 'Shoulder I-Y-T-W Series', 'Rotator cuffs / الكفة المدورة', '{"Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/237/shoulder-stability-mobility-series-i-y-t-w-formations/', 'تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture | ضعف العضلة المعينية / Rhomboid Weakness', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'I-Y-T-W / تمارين I-Y-T-W', 'Scapular Retraction/Depression + Arm Elevation / سحب وخفض لوح الكتف مع رفع الذراع', NULL, 'تقوية وتحكم عضلات لوح الكتف (الانكماش والتدوير)', 'مبكرة–متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis) | Sheikhhoseini et al. 2018 — JMPT (Systematic review, FHP) | Castelein et al. 2016 — Man Ther (EMG, rhomboid)', 'https://doi.org/10.1186/s12891-024-07224-4 | https://pubmed.ncbi.nlm.nih.gov/30107937/ | https://pubmed.ncbi.nlm.nih.gov/26409441/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('42ae559b-3c32-4bb6-88a5-0f7eabc146cb', 'Supine Snow Angel (Wipers)', 'Rotator cuffs / الكفة المدورة', '{"Shoulders / الأكتاف","Core / البطن والكور"}', 'Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/124/supine-snow-angel-wipers-exercise/', 'تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Snow Angel / الملاك', 'Shoulder Abduction/Adduction + Scapular Control / تبعيد وتقريب الكتف مع تحكم لوح الكتف', NULL, 'حركة الكتف والتحكم بلوح الكتف', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('278fd68b-2962-4b30-92b1-02b49e56d1dd', 'Single Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/82IuSLk5zNc?si=FTMqZrmawQFRr8dN', 'اجلس وثبت ظهرك السفلي كويس، تأكد ان مسمار الارتفاع يكون بمستوى ركبتك، امسك المقابض لزيادة الثبات، إرفع الوزن اثبت ثانية فوق ثم انزل نزول كامل بتحكم.

ملاحظات مهمة:
• اعمل برجل واحدة بنفس ضبط الجهاز
• ثبّت الجذع ولا تتمايل لتعويض الوزن
• افرد الركبة ببطء وانزل بتحكم
• وزن أخف من العمل بالرجلين', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0a70e856-da1b-405e-9802-1e22ea1e1a12', 'Back Extension', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة","Hamstrings / الخلفية"}', 'Spinal Extension / بسط الجذع', 'كور', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/bs7S3RFyIYs?si=tDLl3OYuDBIwK4Fj', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «Functional Training»)', 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain | تحدب الظهر / Postural Thoracic Kyphosis', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Back Extension / بسط الظهر', 'Hip Extension + Spinal Extension / بسط الورك + بسط العمود الفقري', NULL, 'تقوية باسطات الظهر', 'متقدمة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ يُراجَع إذا زاد الألم مع الامتداد', 'JOSPT CPG 2021 — Low Back Pain (George et al.) | Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/ | https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('776a64b3-f85e-43fe-8959-63a3579c9226', 'Supermans', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة","Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Spinal Extension / بسط الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/9/supermans/', 'تحدب الظهر / Postural Thoracic Kyphosis | آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Prone Extension / بسط على البطن', 'Spinal Extension / بسط العمود الفقري', NULL, 'تقوية باسطات الظهر والتحكم الوضعي', 'متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis) | JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://doi.org/10.1186/s12891-024-07224-4 | https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('18210728-3d86-4d26-99d7-762d9ab399ad', 'Standing Dorsi-Flexion (Calf Stretch)', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/152/standing-dorsi-flexion-calf-stretch/', 'اللفافة الأخمصية / Plantar Fasciopathy', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Calf Stretch / إطالة البطات', 'Ankle Dorsiflexion / ثني ظهري للكاحل', NULL, 'إطالة عضلات الساق', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2023 — Heel Pain/Plantar Fasciitis (Koc et al.)', 'https://pubmed.ncbi.nlm.nih.gov/38037331/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6d81fa81-fd94-4f6a-a6d0-26993e97d508', 'Cat-Cow', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/15/cat-cow/', 'تحدب الظهر / Postural Thoracic Kyphosis | آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Spinal Mobility / مرونة العمود الفقري', 'Spinal Flexion/Extension / ثني وبسط العمود الفقري', NULL, 'حركة العمود الفقري ضمن مدى حركة مريح', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis) | JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://doi.org/10.1186/s12891-024-07224-4 | https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2d211c3f-00d0-4925-b675-d1043188c09f', 'Plantar Fascia-Specific Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'تُسحب أصابع القدم للخلف باليد حتى يُشعر بشد في باطن القدم، مع تحسّس اللفافة للتأكد من الشد.', 'أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Rathleff et al. 2015 — Scand J Med Sci Sports (RCT)', 'https://doi.org/10.1111/sms.12313', 'اللفافة الأخمصية / Plantar Fasciopathy', 'review', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Plantar Fascia Stretch / إطالة اللفافة الأخمصية', 'Toe Extension + Ankle Dorsiflexion / مد أصابع القدم + ثني ظهري', NULL, 'إطالة اللفافة الأخمصية', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2023 — Heel Pain/Plantar Fasciitis (Koc et al.) | Rathleff et al. 2015 — Scand J Med Sci Sports (RCT)', 'https://pubmed.ncbi.nlm.nih.gov/38037331/ | https://doi.org/10.1111/sms.12313', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b90ca25b-8e4c-46da-bc28-16e1f11ff137', 'Crab Reach (Thoracic Bridge)', 'Functional / التمارين الوظيفية', '{"Glutes / المؤخرة","Shoulders / الأكتاف"}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://www.youtube.com/watch?v=fgsUe3Lc3hI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'تحدب الظهر / Postural Thoracic Kyphosis', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Thoracic Bridge / جسر صدري', 'Hip Extension + Thoracic Rotation / بسط الورك + دوران الصدر', NULL, 'حركة الامتداد والدوران الصدري', 'متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ يتطلب تحمّلاً جيداً للرسغ والكتف', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4c27557c-3cb4-4840-8c93-1fdcc1dbd0d8', 'Prone Swimmer', 'Functional / التمارين الوظيفية', '{"Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Shoulder Rear Pull / سحب خلفي للكتف', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://www.youtube.com/watch?v=M8a1cgnhyqk', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Prone Swimmer / سبّاح على البطن', 'Shoulder Extension/Abduction + Rotation / مد وتبعيد الكتف مع الدوران', NULL, 'تحمّل عضلات لوح الكتف والامتداد الصدري', 'متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1e375d22-3419-4a7e-9422-c4ea357aa69b', 'Isometric Wrist Extension', 'Forearms / الساعد', '{}', 'Wrist Extension / مد الرسغ', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'مرفق التنس / Lateral Elbow Tendinopathy', 'review', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Isometric / ثابت', 'Wrist Extension / مد الرسغ', NULL, 'تحميل تدريجي لباسطات الرسغ (انقباض ثابت)', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ ضمن ألم مقبول لا يتزايد بعد التمرين', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8f7dafe8-fbb1-47f8-8c1f-cbf773993b29', 'Eccentric Wrist Extension', 'Forearms / الساعد', '{}', 'Wrist Extension / مد الرسغ', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'مرفق التنس / Lateral Elbow Tendinopathy', 'review', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Eccentric / لامركزي', 'Wrist Extension / مد الرسغ', NULL, 'تحميل تدريجي لباسطات الرسغ (لامركزي)', 'متوسطة', 'منخفض–متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ ضمن ألم مقبول لا يتزايد بعد التمرين', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('58928856-d186-48af-bc66-25b70439b80f', 'Chin Tuck (Deep Neck Flexor)', 'Neck / الرقبة', '{}', 'Neck Flexion (Deep Flexors) / ثني الرقبة العميق', 'إحماء/تفعيل', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Sheikhhoseini et al. 2018 — JMPT (Systematic review, FHP)', 'https://pubmed.ncbi.nlm.nih.gov/30107937/', 'وضعية الرأس للأمام / Forward Head Posture', 'review', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Chin Tuck / سحب الذقن', 'Upper Cervical Flexion + Retraction / ثني علوي للرقبة مع سحبها للخلف', NULL, 'تحكم عضلات الرقبة العميقة ووضعية الرأس', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ يُوقف مع دوخة أو ألم/تنميل يمتد للذراع', 'Sheikhhoseini et al. 2018 — JMPT (Systematic review, FHP) | Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://pubmed.ncbi.nlm.nih.gov/30107937/ | https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cc662779-535d-433e-b96b-66f73fbc9122', 'Terminal Knee Extension (Band)', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'مطاط', 'مبتدئ', 'منزل', NULL, 'اربط الشريط المطاطي خلف الركبة وقف بثبات. من ركبة مثنية قليلاً، افرد الركبة بالكامل ببطء وشد عضلة الفخذ الأمامية ثانية، ثم ارجع ببطء. 2–3 مجموعات × 12–15 تكرار.', NULL, 'مصدر خارجي موثوق', 'JOSPT CPG 2019 — Patellofemoral Pain (Willy et al.)', 'https://doi.org/10.2519/jospt.2019.0302', 'ألم الرضفة والفخذ (الركبة الأمامية) / Patellofemoral Pain', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Knee Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, 'تقوية الفخذ الأمامي في مدى آمن للركبة', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي. يكون الألم أثناء التمرين خفيفاً ومقبولاً (حتى 3 من 10) ويهدأ خلال 24 ساعة، وإذا زاد الألم أو ظهر تورم أو إحساس بقفل أو خذلان في الركبة يتوقف التمرين وتُراجَع أخصائي.', 'Willy et al. 2019 — JOSPT (Patellofemoral Pain CPG) | Lack et al. 2015 — Br J Sports Med (Proximal muscle rehabilitation for PFP, meta-analysis)', 'https://doi.org/10.2519/jospt.2019.0302 | https://bjsm.bmj.com/content/49/21/1365', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f69c64d3-a6d4-4544-a679-57658c27278d', 'Mini Squat (Partial Range)', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'انزل نزولاً جزئياً فقط (حتى نحو 45° من ثني الركبة) مع ثبات الركبة فوق القدم وعدم انهيارها للداخل، ثم اصعد. 2–3 مجموعات × 10–15 تكرار. زد المدى تدريجياً حسب الراحة.', NULL, 'مصدر خارجي موثوق', 'JOSPT CPG 2019 — Patellofemoral Pain (Willy et al.)', 'https://doi.org/10.2519/jospt.2019.0302', 'ألم الرضفة والفخذ (الركبة الأمامية) / Patellofemoral Pain', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, 'تقوية الفخذ الأمامي والورك بحمل خفيف على مفصل الرضفة', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي. يكون الألم أثناء التمرين خفيفاً ومقبولاً (حتى 3 من 10) ويهدأ خلال 24 ساعة، وإذا زاد الألم أو ظهر تورم أو إحساس بقفل أو خذلان في الركبة يتوقف التمرين وتُراجَع أخصائي.', 'Willy et al. 2019 — JOSPT (Patellofemoral Pain CPG) | Lack et al. 2015 — Br J Sports Med (Proximal muscle rehabilitation for PFP, meta-analysis)', 'https://doi.org/10.2519/jospt.2019.0302 | https://bjsm.bmj.com/content/49/21/1365', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f34c2179-fe45-4530-88a5-7917ac7b5a58', 'Lateral Step-Down (Slow Eccentric)', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', NULL, 'قف على حافة درجة بقدم واحدة. انزل بالقدم الأخرى ببطء (3 ثوانٍ) مع إبقاء الحوض مستوياً والركبة فوق أصابع القدم، المس الأرض بخفة ثم اصعد. 2–3 مجموعات × 8–12 تكرار لكل رجل.', NULL, 'مصدر خارجي موثوق', 'JOSPT CPG 2019 — Patellofemoral Pain (Willy et al.)', 'https://doi.org/10.2519/jospt.2019.0302', 'ألم الرضفة والفخذ (الركبة الأمامية) / Patellofemoral Pain', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Step-up / صعود الدرجة', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, 'تحكم الورك والركبة أثناء الحمل على رجل واحدة', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي. يكون الألم أثناء التمرين خفيفاً ومقبولاً (حتى 3 من 10) ويهدأ خلال 24 ساعة، وإذا زاد الألم أو ظهر تورم أو إحساس بقفل أو خذلان في الركبة يتوقف التمرين وتُراجَع أخصائي.', 'Willy et al. 2019 — JOSPT (Patellofemoral Pain CPG) | Lack et al. 2015 — Br J Sports Med (Proximal muscle rehabilitation for PFP, meta-analysis)', 'https://doi.org/10.2519/jospt.2019.0302 | https://bjsm.bmj.com/content/49/21/1365', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5cc80451-4fda-4b88-b400-c5858f99d28b', 'Clamshell', 'Glutes / المؤخرة', '{"Abductors / مبعدات الفخذ"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'استلقِ على جنبك وركبتاك مثنيتان 45° وقدماك ملتصقتان. افتح الركبة العليا كالصدفة دون تحريك الحوض للخلف، ثم أغلقها ببطء. 2–3 مجموعات × 12–20 تكرار. يمكن إضافة شريط مطاطي للتدرج.', NULL, 'مصدر خارجي موثوق', 'BJSM 2015 — Proximal muscle rehabilitation for PFP (Lack et al.)', 'https://bjsm.bmj.com/content/49/21/1365', 'ألم الرضفة والفخذ (الركبة الأمامية) / Patellofemoral Pain', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Hip External Rotation / دوران الورك للخارج', 'Hip External Rotation / دوران الورك للخارج', NULL, 'تقوية دوران الورك الخارجي والألوية الوسطى', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي. يكون الألم أثناء التمرين خفيفاً ومقبولاً (حتى 3 من 10) ويهدأ خلال 24 ساعة، وإذا زاد الألم أو ظهر تورم أو إحساس بقفل أو خذلان في الركبة يتوقف التمرين وتُراجَع أخصائي.', 'Willy et al. 2019 — JOSPT (Patellofemoral Pain CPG) | Lack et al. 2015 — Br J Sports Med (Proximal muscle rehabilitation for PFP, meta-analysis)', 'https://doi.org/10.2519/jospt.2019.0302 | https://bjsm.bmj.com/content/49/21/1365', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5b519b79-8a38-4a51-8f9a-5e91ceb1540f', 'Wall Sit (Isometric Quad Hold)', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'ضع ظهرك على الحائط وانزل حتى ركبتين مثنيتين بزاوية مريحة (نحو 60–90°) وثبّت. 4–5 مجموعات × 30–45 ثانية مع راحة دقيقتين. يُستخدم عند ألم الوتر لتخفيف الألم قبل التمارين الأخرى.', NULL, 'مصدر خارجي موثوق', 'Br J Sports Med 2015 — Isometric exercise in patellar tendinopathy (Rio et al.)', 'https://pubmed.ncbi.nlm.nih.gov/25979840/', 'اعتلال وتر الرضفة / Patellar Tendinopathy | ألم الرضفة والفخذ (الركبة الأمامية) / Patellofemoral Pain', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Isometric Knee Extension / انقباض ثابت لمد الركبة', NULL, 'تخفيف الألم وتحميل آمن لوتر الرضفة بالانقباض الثابت', 'مبكرة', 'منخفض–متوسط', 'يُستخدم بعد تقييم فردي. يكون الألم أثناء التمرين خفيفاً ومقبولاً (حتى 3 من 10) ويهدأ خلال 24 ساعة، وإذا زاد الألم أو ظهر تورم أو إحساس بقفل أو خذلان في الركبة يتوقف التمرين وتُراجَع أخصائي.', 'Rio et al. 2015 — Br J Sports Med (Isometric exercise and analgesia in patellar tendinopathy) | Willy et al. 2019 — JOSPT (Patellofemoral Pain CPG) | Lack et al. 2015 — Br J Sports Med (Proximal muscle rehabilitation for PFP, meta-analysis)', 'https://pubmed.ncbi.nlm.nih.gov/25979840/ | https://doi.org/10.2519/jospt.2019.0302 | https://bjsm.bmj.com/content/49/21/1365', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0f23ec7d-502f-4855-ac7f-a9113a7301b7', 'Isometric Leg Extension Hold (Machine)', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'جهاز', 'متوسط', 'نادي', NULL, 'اجلس على جهاز فرد الركبة وثبّت الزاوية عند نحو 60° من ثني الركبة. ادفع بجهد متوسط–عالٍ (نحو 70% من أقصى قوة) وثبّت 45 ثانية، 5 مجموعات مع راحة دقيقتين. بروتوكول الدراسة المرجعية.', NULL, 'مصدر خارجي موثوق', 'Br J Sports Med 2015 — Isometric exercise in patellar tendinopathy (Rio et al.)', 'https://pubmed.ncbi.nlm.nih.gov/25979840/', 'اعتلال وتر الرضفة / Patellar Tendinopathy', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Isometric / ثابت', 'Isometric Knee Extension / انقباض ثابت لمد الركبة', NULL, 'تخفيف ألم الوتر وتقليل التثبيط العضلي', 'مبكرة', 'متوسط', 'يُستخدم بعد تقييم فردي. يكون الألم أثناء التمرين خفيفاً ومقبولاً (حتى 3 من 10) ويهدأ خلال 24 ساعة، وإذا زاد الألم أو ظهر تورم أو إحساس بقفل أو خذلان في الركبة يتوقف التمرين وتُراجَع أخصائي.', 'Rio et al. 2015 — Br J Sports Med (Isometric exercise and analgesia in patellar tendinopathy)', 'https://pubmed.ncbi.nlm.nih.gov/25979840/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c1d9aa94-7d76-41f7-a6ef-d5b53ec32793', 'Slow Leg Press (Heavy Slow Resistance)', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'متوسط', 'نادي', NULL, 'ضغط الأرجل بحركة بطيئة جداً: 3 ثوانٍ للدفع و3 ثوانٍ للنزول بدون توقف. تزيد الأوزان وتقل التكرارات تدريجياً (من 15 إلى 6) خلال 12 أسبوعاً، 3 أيام في الأسبوع بالتناوب مع تمرين سكوات وهاك سكوات.', NULL, 'مصدر خارجي موثوق', 'Scand J Med Sci Sports 2009 — HSR in patellar tendinopathy (Kongsgaard et al.)', 'https://pubmed.ncbi.nlm.nih.gov/19793213/', 'اعتلال وتر الرضفة / Patellar Tendinopathy', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Leg Press / ضغط الأرجل', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, 'تحميل تدريجي لوتر الرضفة بمقاومة عالية وبطيئة', 'متوسطة–متقدمة', 'مرتفع', 'يُستخدم بعد تقييم فردي. يكون الألم أثناء التمرين خفيفاً ومقبولاً (حتى 3 من 10) ويهدأ خلال 24 ساعة، وإذا زاد الألم أو ظهر تورم أو إحساس بقفل أو خذلان في الركبة يتوقف التمرين وتُراجَع أخصائي.', 'Kongsgaard et al. 2009 — Scand J Med Sci Sports (Heavy slow resistance vs eccentric decline squat vs corticosteroid in patellar tendinopathy)', 'https://pubmed.ncbi.nlm.nih.gov/19793213/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1ff27f19-34af-4dea-a16c-62a82e64c477', 'Modified Curl-Up (McGill)', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'استلقِ على ظهرك، ركبة مثنية والأخرى مفرودة، ويداك تحت أسفل الظهر للحفاظ على انحنائه الطبيعي. ارفع الرأس والكتفين قليلاً فقط (دون ثني أسفل الظهر) وثبّت 7–10 ثوانٍ، ثم ارجع. 3 جولات (تنازلية 6-4-2) حسب برنامج ماكجيل.', NULL, 'مصدر خارجي موثوق', 'McGill 2010 — Core training (Strength Cond J)', NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL, 'تقوية عضلات البطن بأقل حمل على العمود الفقري', 'مبكرة', 'منخفض', 'لا يُجرى مع ألم حاد أو ألم ينتشر للساق أو تنميل. يتوقف التمرين إذا زاد الألم، وتُراجَع أخصائي.', 'NICE NG59 (2020) — Low back pain and sciatica in over 16s | Hayden et al. 2021 — Cochrane (Exercise therapy for chronic low back pain) | McGill 2010 — Strength Cond J (Core training)', 'https://www.nice.org.uk/guidance/ng59 | https://doi.org/10.1002/14651858.CD009790.pub2', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6636d1b6-1657-4993-ad8e-7096cffe0659', 'Supine Pelvic Tilt', 'Core / البطن والكور', '{"Glutes / المؤخرة"}', 'Core Activation & Breathing / تفعيل الجذع والتنفس', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'استلقِ على ظهرك وركبتاك مثنيتان. اضغط أسفل الظهر برفق نحو الأرض بشد البطن والألوية قليلاً، ثبّت 5 ثوانٍ مع تنفس طبيعي ثم استرخِ. 2 مجموعات × 10 تكرارات.', NULL, 'مصدر خارجي موثوق', 'NICE NG59 — Low back pain and sciatica in over 16s', 'https://www.nice.org.uk/guidance/ng59', 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Pelvic Control / التحكم بالحوض', 'Posterior Pelvic Tilt / إمالة الحوض للخلف', NULL, 'تفعيل الجذع وتحسين وعي الحوض في المراحل الأولى', 'مبكرة', 'منخفض', 'تمرين تمهيدي خفيف. لا تدفع بقوة، ويتوقف عند زيادة الألم.', 'NICE NG59 (2020) | Hayden et al. 2021 — Cochrane (دليل عام على التمارين، ولا توجد تجربة تعزل هذا التمرين بعينه)', 'https://www.nice.org.uk/guidance/ng59 | https://doi.org/10.1002/14651858.CD009790.pub2', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7b88d7af-3a57-4d37-a638-c7830e9f7da3', 'Tyler Twist (FlexBar)', 'Forearms / الساعد', '{}', 'Wrist Extension / مد الرسغ', 'قوة', 'أخرى', 'متوسط', 'منزل', NULL, 'أمسك قضيب FlexBar عمودياً: اليد المصابة من الأعلى والسليمة من الأسفل، والرسغ المصاب مفرود للخلف. لفّ القضيب باليد السليمة (التواء)، ثم مدّ الذراعين أمامك وأرخِ الالتواء ببطء بالرسغ المصاب حتى يستقيم (حركة لامركزية بطيئة). 3 مجموعات × 15 تكرار يومياً، وتزيد مقاومة القضيب تدريجياً. هذا الوصف مبسّط، فيُراجَع مع أخصائي عند أول استخدام.', NULL, 'مصدر خارجي موثوق', 'J Shoulder Elbow Surg 2010 — Tyler Twist (Tyler et al.)', NULL, 'مرفق التنس / Lateral Elbow Tendinopathy', 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Eccentric / لامركزي', 'Wrist Extension / مد الرسغ', NULL, 'تقوية لامركزية لباسطات الرسغ لألم مرفق التنس', 'مبكرة–متوسطة', 'منخفض–متوسط', 'يكون الألم أثناء التمرين خفيفاً ومقبولاً. إذا زاد الألم أو ظهر تنميل أو ضعف في اليد يتوقف التمرين وتُراجَع أخصائي.', 'Tyler et al. 2010 — J Shoulder Elbow Surg 19(6):917–922 (Tyler Twist with FlexBar)', NULL, 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2744253a-3cf0-4f4c-be24-0b56a928ce3c', 'Single Leg Raise', 'Core / البطن والكور', '{"Glutes / المؤخرة","Hamstrings / الخلفية"}', NULL, NULL, 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/ZJodU5OOaiA?si=p6ZD9dpzyRKBUn16', 'ملاحظات مهمة:
• استلقِ وثبّت أسفل الظهر على الأرض
• ارفع الرجل بتحكم دون تقوّس الظهر
• نزول بطيء
• لا ترتد', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d29225ac-5d4a-47f7-86d2-ba9e5f07cdf8', 'Nordic Hamstring Curl', 'Hamstrings / الخلفية', '{}', 'Knee Flexion / ثني الركبة', 'قوة', 'وزن الجسم', 'متقدم', 'بدون معدات', 'https://youtu.be/Lgibr8od0yA?si=nfRetEkDRk55Bu0a', 'ملاحظات مهمة:
• ثبّت الكعبين جيداً وانزل ببطء بجسم مستقيم من الركبة للرأس
• استخدم اليدين لتخفيف الحمل في البداية
• عُد بدفع خفيف باليدين
• ابدأ بمدى قصير لتجنب شد الخلفية', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Nordic (Eccentric) / نوردك (لامركزي)', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2e96c8bd-869f-4cf5-8d93-cb3c53f978fd', 'Box Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtube.com/shorts/9uhEh9gpwUU?si=xaTY7AJiCeQfa3by', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل.

ملاحظات مهمة:
• اجلس للخلف على الصندوق بتحكم وجذع مرفوع ولا ترتمِ عليه
• توقف لحظة دون إرخاء العضلات ثم ادفع الأرض بالكعبين
• الصندوق بارتفاع يجعل الفخذ موازياً للأرض تقريباً
• الخطأ الشائع: تقوّس الظهر عند الانطلاق من الصندوق', 'تعليمات بديلة في المصدر (صف 13): ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل، انزل واثبت على البوكس ثانية وارفع.', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d6262429-012e-446f-940a-c536000c22ae', 'Back Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/bEv6CCg2BC8', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل.

ملاحظات مهمة:
• البار على أعلى الظهر (عضلة الترابيس) لا على الرقبة، والقبضة ثابتة، والصدر مرفوع
• القدمان بعرض الكتفين وأصابعهما للخارج قليلاً، والركبتان تتبعان اتجاه الأصابع
• انزل بعمق يسمح به مدى الورك والكاحل مع شد البطن، وتجنّب انحناء أسفل الظهر في القاع
• الخطأ الشائع: رفع الكعبين أو انهيار الركبتين للداخل', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('dab86bf0-9c23-466f-aee0-0405844d9c6c', 'Hack Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/0tn5K9NlCfo', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.

ملاحظات مهمة:
• ظهر وأرداف ملتصقان بالمسند طوال الحركة
• القدمان بعرض الكتفين على منتصف المنصة، وإنزالهما للأسفل يزيد تركيز الفخذ الأمامي
• انزل حتى مدى مريح للركبة ثم ادفع بكامل القدم
• لا تفرد الركبتين بقوة في الأعلى', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Machine Squat / سكوات بالجهاز', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('495bdfe7-92fa-41e5-95c5-703d493e64a3', 'Mid Leg Press', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/s9-zeWzPUmA', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.

ملاحظات مهمة:
• ضع القدمين في منتصف المنصة بعرض الكتفين
• أنزل المنصة حتى ثني الركبة نحو 90° دون أن يرتفع الحوض عن المقعد
• ادفع بكامل القدم، ولا تغلق الركبتين بقوة في الأعلى
• لا تضع اليدين على الركبتين للمساعدة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Leg Press / ضغط الأرجل', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2cc1d092-a2e2-4a6a-a92f-203ed177ac88', 'Quads Leg Press', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/A218isnErfM', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي، ثبت القدمين أسفل اللوح لاستهداف أكبر للكوادز.

ملاحظات مهمة:
• القدمان منخفضتان على المنصة وقريبتان من بعض قليلاً لزيادة تركيز الفخذ الأمامي
• الركبتان تتجهان فوق أصابع القدم أثناء النزول
• نزول بطيء بتحكم ثم دفع بدون ارتداد
• احذر ارتفاع الحوض وتقوّس أسفل الظهر عند النزول العميق', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Leg Press / ضغط الأرجل', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c3e53b68-e19f-45fe-a508-8093d8528c5f', 'Deficit Goblet Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/9719SO5zvpU?si=whohbunAsXkH3j6f', 'وقف باتساع اكتافك تقريبًا، ادفع ركبك للامام وانزل، انزل لأقصى حد تقدر عليه بدون ما يتقوس ظهرك السفلي.

ملاحظات مهمة:
• ثبّت الدمبل أمام الصدر والمرفقان للأسفل
• القدمان على منصة صغيرة (ديفيزيت) تزيد مدى الحركة، فانزل بتحكم ولا تتجاوز مدى كاحلك
• حافظ على الجذع مرفوعاً والكعبين ثابتين
• الخطأ الشائع: ارتداد القاع وانحناء الظهر', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d21dec43-2173-47df-acfa-b8f8bbe8a9cf', 'Front Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'بار', 'متوسط', 'نادي', NULL, 'ثبت البار على الأكتاف، ادفع ركبك للامام وانزل.

ملاحظات مهمة:
• البار على مقدمة الكتفين مع مرفقين عاليين أمام الجسم
• الجذع مستقيم أكثر من السكوات الخلفي والركبتان للأمام
• شد البطن وانزل بتحكم
• الخطأ الشائع: سقوط المرفقين فيسقط البار للأمام', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('dbe0f863-b00c-48a8-8001-aa30f6758454', 'V Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://www.youtube.com/watch?v=u_GSjH58s0g', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.

ملاحظات مهمة:
• ثبّت الظهر والأرداف على الجهاز واجعل القدمين على المنصة بعرض الكتفين
• انزل بتحكم حتى مدى مريح وادفع بالكعبين
• لا تفرد الركبتين بالكامل بعنف
• ابقِ الركبتين باتجاه أصابع القدم', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Machine Squat / سكوات بالجهاز', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e680b389-9b6a-4ec9-bf76-1a8f4fe9f82b', 'Resistance Band Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/6rE0IYlMPZA?si=goqtRTlR_W4HSGBN', 'ثبت الباند علي جوانب اكتافك، ادفع ركبك للأمام وإنزل.

ملاحظات مهمة:
• ثبّت الشريط تحت القدمين ومرره على الكتفين أو أمام الصدر
• الشد يزيد في أعلى الحركة، فادفع بتحكم ولا تقفز
• ركبتان باتجاه الأصابع وصدر مرفوع
• تأكد من سلامة الشريط وثباته', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0adb8588-55e8-4e9d-84ad-be8966e23eba', 'Squat Smith Machine', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/oBwhrRcNWyM', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل.

ملاحظات مهمة:
• ضع القدمين أمام خط البار قليلاً ليتمكن الجذع من البقاء مستقيماً
• انزل حتى مدى مريح مع ثبات الكعبين
• اضبط حوامل الأمان قبل البدء
• الخطأ الشائع: وضع القدمين تحت البار تماماً فيضغط على الركبتين', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Machine Squat / سكوات بالجهاز', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8b3b8966-04a0-42c5-ac2d-fd0c7d1a810a', 'Single Arm Cable Facing Away Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/6sO-pK7pTPs?feature=share', 'ملاحظات مهمة:
• بيد واحدة مع ثبات الجذع
• المرفق ثابت
• اثنِ بتحكم
• نزول بطيء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('740745cf-0902-4667-97a1-c585c4178578', 'Single Leg Press', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/ZYDTJaAM-gE', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.

ملاحظات مهمة:
• ضع قدماً واحدة على منتصف المنصة والأخرى بعيداً عنها
• لا يرتفع الحوض عن المقعد ولا ينحرف للجانب
• انزل حتى 90° تقريباً بتحكم
• لا تفرد الركبة بقوة في الأعلى', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Single-leg Press / ضغط رجل واحدة', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('43a0b6dd-50ee-4bb8-bbc6-71f5fec267f2', 'Drop Lunges', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/WH8lteLrMIs?si=61QSVA7iw_Z6Zr3p', 'تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.

ملاحظات مهمة:
• ارجع بقدم خلفاً بقوس خلف القدم الثابتة وانزل للأسفل بتحكم
• الجذع مستقيم والركبة الأمامية فوق القدم
• ادفع بكعب الرجل الأمامية للعودة
• ابدأ بوزن خفيف لإتقان التوازن', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c057dee3-1048-4b03-9c69-b02f8a417c23', 'Beginner Lunges', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/QOVaHwm-Q6U', 'تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.

ملاحظات مهمة:
• خطوة طويلة بما يكفي لتبقى الركبة الأمامية فوق القدم
• انزل عمودياً حتى تقترب الركبة الخلفية من الأرض
• ادفع بكعب الرجل الأمامية
• يمكنك الإمساك بسند للتوازن في البداية', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d3d6c598-671a-48d7-80eb-e45e38d3f6e4', 'Standing Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/rDRwAURNbzU', 'الحركة كلها بثني ومد الركبة

ملاحظات مهمة:
• قف بثبات وأمسك سنداً
• اثنِ الركبة بتحكم والجذع ثابت
• لا تتأرجح بالورك
• نزول بطيء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cf9cf7e5-c062-4e51-be95-36ed8cf7288c', 'Supported BSS', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/poBie3TTeGE?si=QSiMUYtcHhrmg8mx', 'وقف عند البنش او الستيب، ارفع رجلك وثبت اصابع قدمك على البنش، خذ خطوة وحدة للأمام برجلك الثانية ثم ابدأ التمرين، تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.

ملاحظات مهمة:
• ضع القدم الخلفية على مقعد واستند بيدك على ثابت
• انزل عمودياً والركبة الأمامية فوق القدم
• الجذع مائل قليلاً للأمام يزيد تفعيل الألوية
• لا تدفع بالقدم الخلفية', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Split Squat / سبليت سكوات', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9e2fe2fc-5233-4f75-ae69-cafaeadbfbaa', 'Supported Reverse Lunge', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/WH8lteLrMIs?si=M9s9a7qOVvvyDm82', 'ملاحظات مهمة:
• ابقَ ممسكاً بسند خفيف للتوازن، وخطوة للخلف ثم نزول عمودي
• ادفع بكعب الرجل الأمامية للعودة
• حوض مستوٍ وجذع مستقيم
• الخطأ الشائع: الاتكاء على السند بدل الرجل', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('349784c5-1d73-4380-bfe9-98b13ef6c6bc', 'Smith Machine Reverse Lunge', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/zAVYcwnlxrQ?si=M5HL4sG-bsYBFyDQ', 'استخدم ارتفاع بسيط مثل الستيب ، ارفع نفسك بالضغط علي الرجل المرفوعة بتحكم بدون قفز.

ملاحظات مهمة:
• اضبط البار بحيث تكون القدم الأمامية تحته أو أمامه قليلاً
• خطوة للخلف ونزول بتحكم
• ادفع بكعب الرجل الأمامية
• تأكد من حوامل الأمان', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('17fb0c9f-dd60-419a-9f43-b5cf181e0605', 'Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/gtZ4AwZVtMI', 'اجلس وثبت ظهرك السفلي كويس، تأكد ان مسمار الارتفاع يكون بمستوى ركبتك، امسك المقابض لزيادة الثبات، إرفع الوزن اثبت ثانية فوق ثم انزل نزول كامل بتحكم.

ملاحظات مهمة:
• اضبط مسند الظهر لتكون الركبة عند محور الجهاز
• افرد الركبة بتحكم وثبّت لحظة في الأعلى
• نزول بطيء 2–3 ثوانٍ دون ارتداد الوزن
• تجنّب الأوزان الثقيلة جداً عند ألم الركبة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fe89150b-4b21-4e31-93d5-878217afee70', 'Band Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/hs7D3gDw3UM', 'اجلس وثبت ظهرك السفلي كويس وامسك الكرسي للثبات، اثبت ثانية فوق ثم انزل نزول كامل بتحكم.

ملاحظات مهمة:
• ثبّت الشريط خلف الكاحل وثبّت الطرف الآخر أمامك
• افرد الركبة ببطء ثم انزل بتحكم
• الشد يزداد في الأعلى فاضغط الفخذ لحظة
• تأكد من ثبات الشريط', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('67838f5f-9595-4867-b0fc-8b18b16045be', 'Sissy Squat', 'Quadriceps / الأمامية', '{"Adductors / الأفخاذ الداخلية"}', 'Knee Extension / مد الركبة', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://youtu.be/yONKTprKCDA', 'الورك ثابت طول الجولة والحركة كلها من مفصل الركبة، اذا توازنك يخرب عليك ادبل الوزن بيد واليد الثانية امسك فيها جدار او عصى

ملاحظات مهمة:
• ابدأ بسند وبمدى قصير فالتمرين متقدم على الركبة
• مِل بالجذع والركبتين للأمام وكعباك مرفوعان بخط واحد من الركبة للكتف
• انزل ببطء وارجع بتحكم
• تجنّب التمرين مع ألم الركبة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Sissy Squat / سيسي سكوات', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0f8924a7-5f2e-423a-b78d-3566c58d21ba', 'Cable Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/ebjD98gZd8E', 'اجلس وثبت ظهرك السفلي كويس وامسك الكرسي للثبات، اثبت ثانية فوق ثم انزل نزول كامل بتحكم.

ملاحظات مهمة:
• ثبّت الكيبل على الكاحل واجلس بثبات
• افرد الركبة بتحكم ولا تتأرجح بالجذع
• شد الكيبل مستمر طوال الحركة
• نزول بطيء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a1a8cef8-0f95-4d39-a527-4cc352e51525', 'Standing Leg Extension', 'Quadriceps / الأمامية', '{"Core / البطن والكور"}', 'Knee Extension / مد الركبة', 'قوة', NULL, 'مبتدئ', NULL, NULL, 'ملاحظات مهمة:
• قف على رجل ثابتة وأمسك سنداً
• افرد الركبة بالرجل الأخرى بتحكم دون ميلان الجذع
• شد في الأعلى لحظة
• وزن خفيف مع حركة منضبطة', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/133/standing-leg-extension/', NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('17039fbc-327a-4528-b5f7-d65ca29f6c45', 'Bodyweight Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Lower back / أسفل الظهر"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'ملاحظات مهمة:
• القدمان بعرض الكتفين والذراعان أمامك للتوازن
• انزل بالورك للخلف وللأسفل والصدر مرفوع
• ركبتان باتجاه الأصابع والكعبان ثابتان
• ارتفع بدفع الأرض بكامل القدم', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/135/bodyweight-squat/', NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('32c4b10a-8036-49bd-ac94-c28c75bbf5e3', 'Cable Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/mBJXWg8ZOy0', 'اجلس على الكرسي وثبت ظهرك السفلي على المقعد تمامًا، ممكن تقدّم ظهرك العلوي وتمسك المقابض لزيادة الثبات، انزل لأقصى حد تقدر عليه وارفع لحد ما تستقيم ركبتك.

ملاحظات مهمة:
• ثبّت الكيبل على الكاحل ومرجع ثابت لليد
• اثنِ الركبة بتحكم والورك ثابت
• عودة بطيئة
• وزن مناسب دون ميلان الجذع', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e728ff26-5a3a-4525-bda2-aeae37e93d59', 'DB Glutes Step Ups', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/GCnJiYJfboA?feature=share', 'استخدم ارتفاع يكون بحدود ارتفاع ركبتك أو أقل، ارفع نفسك بالضغط علي الرجل المرفوعة بتحكم بدون قفز.

ملاحظات مهمة:
• استخدم صندوقاً بارتفاع يجعل الركبة نحو 90°
• أمل الجذع قليلاً للأمام لتفعيل الألوية وادفع بكعب القدم التي على الصندوق
• انزل بتحكم دون ارتماء
• لا تدفع بالرجل الخلفية', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('07e351dc-4712-4056-ba9a-8a5e7bfcd431', 'Supported Glutes Step Ups', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/ZKzoOkQALaY?si=-56txwBlxSSCQYJd', 'استخدم ارتفاع يكون بحدود ارتفاع ركبتك أو أقل، ارفع نفسك بالضغط علي الرجل المرفوعة بتحكم بدون قفز.

ملاحظات مهمة:
• أمسك سنداً خفيفاً للتوازن فقط
• اصعد بالرجل التي على الصندوق وجذع مائل قليلاً
• نزول بطيء ببطء
• لا تعتمد على اليد في الصعود', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('06f07963-f2fe-4d3a-9539-99d7651dbb47', 'Cable Glutes Step Ups', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', NULL, 'ملاحظات مهمة:
• ثبّت الكيبل مناسباً للحزام أو اليدين
• اصعد بتحكم والجذع مستقيم مع إمالة بسيطة
• شد الكيبل لا يسحبك للخلف
• نزول بطيء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a215b45e-8333-4e23-aae0-746c279fa9cf', 'Single Arm Cable Facing In Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/I-197ZW9Ffo?si=M1Yq4R1PIpdZMXRx', 'ملاحظات مهمة:
• بيد واحدة مع ثبات الجذع
• المرفق للأمام قليلاً
• اثنِ بتحكم
• نزول بطيء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('957520a2-7ff3-4c58-84fe-bcb661219c98', 'Glute Pushdown', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/8h2kZ64Sp5k?si=NLPf4tywxhDGY9em', 'تمسك بمقابض الجهاز، (كل ما زاد ارتفاع البنش زادت الصعوبة) + الطلوع والنزول يكون بواسطة القدم المرفوعة على البنش مو بالقدم اللي تحت، ارفع بتحكم الى أقصى ارتفاع تقدرعليه بدون ما يتقوس ظهرك السفلي، انزل لحد ما تقفل ركبتك تماما

ملاحظات مهمة:
• ثبّت جسمك على الجهاز وادفع بالقدم بتحكم
• ركّز على انقباض الألوية في نهاية الدفع
• لا تقوّس أسفل الظهر
• نزول بطيء دون ارتداد', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('802bf807-fe22-4856-8782-1545673dc0c4', 'Glute Max Kickbacks', 'Glutes / المؤخرة', '{}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/t5mwSx4uNMc?feature=share', 'ثبت الحبل على الكاحل، ارجع خطوة للخلف وانحني للامام قليلاً وتمسك بالكيبل لزيادة الثبات، اسحب للخلف مع انثناء بسيط بالركب.

ملاحظات مهمة:
• ثبّت الكيبل على الكاحل وأمسك بسند بيد
• ارفع الرجل للخلف من الورك دون تقوّس أسفل الظهر
• انقباض الألوية لحظة في الأعلى
• وزن خفيف مع حركة منضبطة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Kickback / ركلة خلفية', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5d8bc35d-0eab-4182-b641-e4b53ef94fc7', 'Smith Machine Kickback', 'Glutes / المؤخرة', '{}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/GR4ny80bmhM?si=WeZcWM1hyfoLElM2', 'ملاحظات مهمة:
• ضع القدم الخلفية على البار وأمسك السميث
• ادفع للأعلى وللخلف من الورك
• الحوض ثابت دون دوران
• نزول بطيء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Kickback / ركلة خلفية', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('89e44d85-4d83-41e1-9813-96c1b66c9c5c', 'Glute Medius Kickbacks', 'Abductors / مبعدات الفخذ', '{"Glutes / المؤخرة"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/kccsnZNbMFA?si=6c-VoB8Zsz8NxoyM', 'ثبت الحبل على الكاحل، ارجع خطوة للخلف وانحني للامام قليلاً وتمسك بالكيبل لزيادة الثبات، اسحب للخلف وللخارج مع انثناء بسيط بالركب.

ملاحظات مهمة:
• ثبّت الكيبل على الكاحل البعيد عن الكيبل وارفع الرجل للجانب والخلف
• حافظ على حوض ثابت دون دوران وجذع مستقيم
• انقباض لحظة في الأعلى
• وزن خفيف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Abduction Kickback / ركلة خلفية مع تبعيد', 'Hip Abduction + Hip Extension / تبعيد الورك + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4e7b92bc-0fc6-4290-9741-112bc2fa1a13', 'Hip Thrusts Machine', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/0xfdeCBwoYw?si=HgJcNeB0a24gODkK', 'ممكن تسويه بالسميث مشين او البار الحر ، اختر بوكس او بنش يكون بمستوى اكتافك الخلفية وانت جالس، لما ترفع البار فوق المفروض ركبك تكون بنفس مستوى القدم.

ملاحظات مهمة:
• اضبط الجهاز ليكون الحزام على الحوض
• ادفع بالكعبين مع انقباض الألوية في الأعلى
• ذقن للأسفل قليلاً والأضلاع للأسفل
• لا تقوّس أسفل الظهر', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('00d32c3c-33b9-4d5c-bb25-15ba55c4f109', 'Hip Thrusts', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/O0EoaP7gR1A?si=cGPZ8iIwM2mQjwSb', 'ملاحظات مهمة:
• ظهر الكتفين على مقعد والبار على الحوض (مع وسادة)
• ركبتان بزاوية نحو 90° في الأعلى
• ادفع بالكعبين وانقباض الألوية لحظة
• الخطأ الشائع: ثني مفرط لأسفل الظهر', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9232e4b2-8747-4907-be1f-4edb4d0770ee', 'Glute Raise', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/X_kL_x4m77c', 'ثبت رجولك تحت، الاسفنجة تكون تحت الورك أعلى الفخذ مو على الورك مباشرة، امسك وزن بيدينك بذراع مستقيمة، ارفع وكأنك تبي تدخل القلوتس جوا الاسفنجة، بمجرد ما تنقبض مؤخرتك وقف لا ترفع أكثر.

ملاحظات مهمة:
• اضبط الجهاز بحيث يتحرك الورك بحرية
• ارفع الجسم من الورك حتى استقامة الجسم فقط
• لا تبالغ في تقوّس الظهر
• انقباض الألوية في الأعلى', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', '45° Hip Extension / بسط الورك على جهاز الظهر', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('bd5b5d26-5dd2-484c-8ebf-373ee9bda9c8', 'Single Hip Thrusts', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/ymg2AMDAwrY?si=fY8kBPTDYWRMHuAs', 'اختر بوكس او بنش يكون بمستوى اكتافك الخلفية وانت جالس، لما ترفع فوق المفروض ركبك تكون بنفس مستوى القدم، التمرين صعب طبيعي تواجه صعوبة بالبداية لذلك لا تستعجل باضافة الاوزان

ملاحظات مهمة:
• اعمل برجل واحدة والأخرى مرفوعة أو مثنية
• حافظ على حوض مستوٍ دون ميلان
• ادفع بالكعب وانقباض الألوية
• ابدأ بوزن الجسم قبل زيادة الحمل', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8e871fc6-0bb2-4f27-a492-13e85405a681', 'DB Preacher', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/DZJNTb-zzn0?si=SwbdZ0O_0eTOET-5', 'ملاحظات مهمة:
• العضد على المسند ولا يرتفع
• اثنِ وانزل ببطء دون فرد المرفق بعنف
• وزن مناسب دون زخم
• رسغ محايد', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Preacher Curl / ثني على مسند', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('47a3a849-e23c-43de-815d-5097fc807c85', 'Glute Press', 'Glutes / المؤخرة', '{}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', NULL, 'ملاحظات مهمة:
• ثبّت الجذع على الجهاز وادفع بالقدم بتحكم
• ركّز على انقباض الألوية وليس الظهر
• لا تفرد الركبة بقوة
• نزول بطيء', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/293/glute-press/', NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Kickback / ركلة خلفية', 'Hip Extension + Knee Extension / بسط الورك + مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('32ce292e-4fe1-4c9a-bb16-208fd0a0754f', 'Bulgarian Split Squat', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, NULL, 'ملاحظات مهمة:
• القدم الخلفية على مقعد خلفك والأمامية بمسافة كافية
• انزل عمودياً والركبة الأمامية فوق القدم
• مِل بالجذع قليلاً للأمام لتفعيل الألوية، وبشكل مستقيم للفخذ الأمامي
• ادفع بكعب الرجل الأمامية', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/366/bulgarian-split-squat/', NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Split Squat / سبليت سكوات', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4758af80-7890-4cee-8634-02c9baf7fa7b', 'Sumo Deadlift', 'Hamstrings / الخلفية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://www.youtube.com/watch?v=cDlOSfu-zHY', 'وقف بفتحة أرجل واسعة بحيث الركب تكون خط مستقيم مع كعب القدم و اصابع الرجل باتجاه الخارج، البار بمنتصف القدم، شد ظهرك العلوي وادفع الارض برجولك واسحب البار للأعلى، وقف لما تنقبض مؤخرتك ولا تبالغ بتقفيل حوضك.

ملاحظات مهمة:
• وقفة واسعة وأصابع للخارج والقبضة داخل الركبتين
• ركبتان باتجاه الأصابع وظهر محايد
• ادفع الأرض بالقدمين وارفع الورك والكتفين معاً
• البار قريب من الجسم', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Deadlift / ديدلفت', 'Hip Extension + Knee Extension / بسط الورك + مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d2e71fb8-475d-41d7-ba49-3840029c1330', 'Conventional Deadlift', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/GxsLrTzyGUU', 'وقف باتساع اكتافك أو أوسع شوي، البار بمنتصف القدم، شد ظهرك العلوي وادفع الارض برجولك واسحب البار للأعلى، وقف لما تنقبض مؤخرتك ولا تبالغ بتقفيل حوضك.

ملاحظات مهمة:
• القدمان بعرض الحوض والبار فوق منتصف القدم
• شد البطن وثبّت الظهر محايداً قبل الرفع
• ادفع الأرض ثم افرد الورك
• البار على الجسم ولا ينحني الظهر في أي مرحلة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Deadlift / ديدلفت', 'Hip Extension + Knee Extension / بسط الورك + مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('096a3f33-478f-4b26-b126-00be0eaacb75', 'Supine Cable Hamstring Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/sDCc1F5J8XA?si=Fi3D39aJogrB5ihd', 'الركبة ثبت مكانها، اسحب الحبل لاقصى حد تقدر عليه واترك رجلك تستقيم تمامًا في الانبساط.

ملاحظات مهمة:
• استلقِ على الظهر وثبّت الكيبل على الكاحل
• اسحب الكعب نحو الأرداف مع بقاء الحوض على الأرض أو مرفوعاً حسب الأداء
• تحكم في العودة
• لا تقوّس الظهر', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7d9c7fe0-7619-4329-bd5f-9b685c2c5d1a', 'BB RDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/mZxxJEncsyw', 'وقف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، انزل وادفع مؤخرتك لآخر شي تقدر عليه للخلف وكأنك بتلمس جدار خلفك مع انثناء بسيط بالركب

ملاحظات مهمة:
• ثني بسيط ثابت في الركبتين والبار قريب من الساقين
• ادفع الورك للخلف حتى تمدد الخلفية ثم عُد بدفع الورك للأمام
• ظهر محايد وكتفان للخلف
• لا تنزل أبعد من مدى مرونتك', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b4b2d04d-457c-4bb5-8774-114c3190cda4', 'DB RDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/RApyTtH6qAo', 'وقف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، انزل وادفع مؤخرتك لآخر شي تقدر عليه للخلف وكأنك بتلمس جدار خلفك مع انثناء بسيط بالركب

ملاحظات مهمة:
• الدمبلان قريبان من الساقين
• ادفع الورك للخلف وليس انحناء الظهر
• انزل حتى تمدد الخلفية ثم ارتفع بدفع الورك
• كتفان للخلف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e3a29645-e1ea-488d-9a4b-9756471ae16a', 'SM SLDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/0cB0_SzqgBU', 'ملاحظات مهمة:
• القدمان تحت البار والركبتان شبه مفرودتين
• ادفع الورك للخلف والبار على الساقين
• ظهر محايد وانزل حتى تمدد الخلفية
• حوامل أمان', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('84d44831-39c2-40ae-bc51-e74329c01e25', 'SLDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/RApyTtH6qAo', 'قف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، ابدأ الحركة بدفع مؤخرتك للخلف والأعلى وانزل

ملاحظات مهمة:
• ركبتان شبه مفرودتين دون قفل
• الحركة من الورك وظهر مستقيم
• انزل حتى تمدد الخلفية
• ارجع بدفع الورك للأمام', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1db94037-7f51-4fd1-8d46-424eaaf68ec2', 'Single DB SLDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/U3prDlAbJDw?si=MRSBcSIcf9M-WQBH', 'قف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، ابدأ الحركة بدفع مؤخرتك للخلف والأعلى وانزل

ملاحظات مهمة:
• دمبل بيد وثبات على رجل مع ثني بسيط
• ادفع الورك للخلف والرجل الأخرى تمتد خلفك
• حوض مستوٍ دون دوران
• استعن بسند عند صعوبة التوازن', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ca4cede5-9a8d-41cf-9c59-f1f8fdb565ef', 'Good Morning', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/f23vXjoG2e8?si=9rkfUF_6XUEcQ3Xs', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع مؤخرتك لأقصى قدر تقدر عليه وكأنك بتلمس جدار خلفك.

ملاحظات مهمة:
• البار على الظهر مع ثني بسيط في الركبتين
• ادفع الورك للخلف بظهر محايد حتى تمدد الخلفية
• ارجع بدفع الورك للأمام
• وزن خفيف جداً في البداية', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Good Morning / قود مورنينق', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9c9a80e6-c3dc-49ab-a51b-c5dfb12e5e08', 'Seated Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/o_J6MWyt5jM', 'اجلس على الكرسي وثبت ظهرك السفلي على المقعد تمامًا، انزل لأقصى حد تقدر عليه وارفع لحد ما تستقيم ركبتك.

ملاحظات مهمة:
• اضبط محور الركبة مع محور الجهاز وثبّت المسند على الفخذ
• اثنِ الركبة بتحكم وثبّت لحظة
• عودة بطيئة
• لا ترفع الورك عن المقعد', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b860e705-3286-4378-bb10-1b202a0c3a54', 'Band Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/I-HTMUrJnxs', 'ثبت الباند فوق الكعب، اجلس على طرف البنش وتمسك بيدينك لزيادة الثبات، اسحب الحبل لاقصى حد تقدر عليه واترك رجلك تستقيم تمامًا في الانبساط.

ملاحظات مهمة:
• ثبّت الشريط على الكاحل ومرجع ثابت
• اثنِ الركبة بتحكم دون تمايل
• عودة بطيئة
• تأكد من ثبات الشريط', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a8b42f17-b769-495e-88e2-8a16c71f848f', 'Lying Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/vl5nUdE9mWM', 'حوضك ثابت على البنش، ارفع الوزن بثني ومد الركبة بدون ما يرتفع حوضك عن الكرسي

ملاحظات مهمة:
• استلقِ بحيث تكون الركبة عند محور الجهاز
• اثنِ الركبة بتحكم دون رفع الحوض
• انقباض لحظة وعودة بطيئة
• لا تقوّس أسفل الظهر', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b274331b-4735-4cb0-bfeb-e7854c3b9aca', 'DB Lying Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/ZHlBSI6JPsA?si=SpBiHxluwrYE8CTP', 'ركبك ثابته على الارض، ارفع الوزن بثني ومد الركبة بدون ما يرتفع حوضك

ملاحظات مهمة:
• ثبّت الدمبل بين القدمين
• اثنِ الركبة بتحكم دون رفع الحوض
• وزن خفيف مع سيطرة
• نزول بطيء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ce64bdf2-38df-43a6-a878-d13e6cd4d8e0', 'Stability Ball Hamstring Curl', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة"}', 'Knee Flexion / ثني الركبة', 'قوة', 'كرة سويسرية', 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• ارفع الحوض ثم اسحب الكرة نحو الأرداف بالكعبين
• حافظ على الحوض مرفوعاً دون تقوّس
• عودة بطيئة
• تحكم في الكرة', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/59/stability-ball-hamstring-curl/', NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Bridge Curl / ثني الركبة مع رفع الورك', 'Knee Flexion + Hip Extension / ثني الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4c1ba64a-9930-4e37-bbd3-5a8ef3d10039', 'Hip Hinge', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', NULL, 'مبتدئ', NULL, NULL, 'ملاحظات مهمة:
• وزن الجسم والعصا على الظهر لمراقبة الاستقامة
• ادفع الورك للخلف مع ثني بسيط للركبتين
• ظهر محايد
• لا تثنِ العمود الفقري', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/33/hip-hinge/', NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Hinge Drill / تمرين مفصلة الورك', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2fc652e1-8c66-461c-8b42-842269481267', 'TRX Hamstrings Curl', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة"}', 'Knee Flexion / ثني الركبة', 'قوة', 'TRX', 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• القدمان في الحزام والحوض مرفوع
• اثنِ الركبتين بالسحب نحو الأرداف مع بقاء الحوض مرتفعاً
• عودة بتحكم
• شد البطن لتجنب تقوّس الظهر', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/86/trx-reg-hamstrings-curl/', NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Bridge Curl / ثني الركبة مع رفع الورك', 'Knee Flexion + Hip Extension / ثني الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b388fb78-88d2-44fa-9061-f0729d04b311', 'Flat DB Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/xphvjGDZeYE', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا

ملاحظات مهمة:
• ثبّت لوحي الكتف للخلف وللأسفل على المقعد
• انزل الدمبلين بتحكم حتى مستوى الصدر، والمرفقان بزاوية نحو 45–70°
• ادفع للأعلى دون رفع الكتفين
• حافظ على قدمين ثابتتين وأرداف على المقعد', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('256bdf68-fafd-45bc-b334-c64f36611efa', 'DB Floor Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/UBmpZ7l5Nlk?si=kDcN-ueaTFxfKtbr', 'ملاحظات مهمة:
• استلقِ على الأرض وانزل حتى لمس العضد للأرض بخفة
• ادفع للأعلى دون ارتداد
• لوحا الكتف للخلف
• مدى أقصر من المقعد وهو آمن للكتف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7a356a65-8b52-4a28-ab30-7f2e20f1b105', 'Flat Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/vcBig73ojpE', 'استلق على بنش،القبضة بنفس مستوى الاكتاف أو أوسع قليلًا، قوّس ظهرك العلوي قليلاً، انزل لين تلمس صدرك واثبت ثانية ثم ارفع.

ملاحظات مهمة:
• العينان تحت البار وقبضة أوسع قليلاً من الكتفين
• ثبّت لوحي الكتف للخلف وللأسفل وصدر مرفوع
• انزل بتحكم إلى أسفل الصدر وادفع بخط ثابت
• استعن بمساعد أو حوامل أمان عند الأوزان الثقيلة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7a14c108-37c2-4361-8211-151a8fbebd5f', 'Machine Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/pOCRC2kpxB8?si=02xGtrfPjiYpspMv', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا

ملاحظات مهمة:
• اضبط المقعد ليكون المقبض بمستوى منتصف الصدر
• الكتفان للخلف والظهر ملتصق بالمسند
• ادفع دون قفل المرفقين وانزل بتحكم
• لا ترفع الكتفين', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b0ac0fdd-19b4-4d88-a226-26125e0adc27', 'Feet Up Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/HrehfM1dmBE', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا

ملاحظات مهمة:
• القدمان مرفوعتان على المقعد لتقليل تقوّس الظهر
• ثبّت الظهر على المقعد وانزل بتحكم
• وزن أخف من الضغط العادي
• حافظ على لوحي الكتف للخلف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('013c5b46-5ab2-4661-8357-c1c94851ef04', 'Torso Elevated Push Up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/noaPB7u4_CU', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا

ملاحظات مهمة:
• اليدان على مرتفع (مقعد) لتخفيف الحمل
• جسم مستقيم من الرأس للكعب والبطن مشدود
• انزل بالصدر نحو المرتفع والمرفقان بزاوية نحو 45°
• لا تدلِّ الورك', 'تصنيف فرعي: اليدان مرفوعتان؛ زاوية الضغط بالنسبة للجذع تشبه الضغط المائل لأسفل رغم تسميته الشائعة Incline Push-up — يحدده المدرب', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Decline Press / ضغط مائل لأسفل', 'Horizontal Adduction + Shoulder Extension / تقريب أفقي + مد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('33055d31-372a-4193-921a-b4019be0474b', 'Push Up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://youtu.be/WDIpL0pjun0?si=utydS_A8QfRIJtJm', 'ملاحظات مهمة:
• اليدان بعرض الكتفين أو أوسع قليلاً والجسم خط مستقيم
• انزل بالصدر حتى قرب الأرض والمرفقان بزاوية 45°
• ادفع دون تدلي الورك أو رفعه
• شد البطن والألوية', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a91d5560-90f2-4e70-8214-ffc724bc6a3b', 'Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://www.youtube.com/watch?v=JvOJdUtx6UQ', 'استلق على بنش،القبضة بنفس مستوى الاكتاف أو أوسع قليلًا، قوّس ظهرك العلوي قليلاً، انزل لين تلمس صدرك واثبت ثانية ثم ارفع.

ملاحظات مهمة:
• العينان تحت البار وقبضة أوسع قليلاً من الكتفين
• ثبّت لوحي الكتف وصدر مرفوع، وقدمان ثابتتان
• انزل بتحكم وادفع بخط ثابت
• حوامل أمان أو مساعد للأوزان الثقيلة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8f3f4858-a859-4c6b-b4af-d738ee052aaa', 'Paused Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://www.youtube.com/shorts/Q3GmnmJISwE', 'استلق على بنش،القبضة بنفس مستوى الاكتاف أو أوسع قليلًا، قوّس ظهرك العلوي قليلاً، انزل لين تلمس صدرك واثبت 3 ثواني ثم ارفع.

ملاحظات مهمة:
• انزل بتحكم واثبت ثانية على الصدر دون استرخاء ثم ادفع
• الوزن أخف من الضغط العادي
• ثبّت لوحي الكتف طوال التوقف
• لا ترتد بالبار', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c62e792d-d8c5-4bdc-a286-478d3020377a', 'Incline Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/0G2_XV7slIg', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا

ملاحظات مهمة:
• اضبط الميل بزاوية معتدلة (نحو 30°)
• ثبّت لوحي الكتف وانزل بتحكم إلى أعلى الصدر
• لا ترفع الأرداف
• لا تجعل الميل شديداً فيتحول التمرين لكتف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Incline Press / ضغط مائل لأعلى', 'Shoulder Flexion + Horizontal Adduction / ثني الكتف + تقريب أفقي', 'Incline Press / ضغط مائل لأعلى', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('49d9cb83-bb38-4c7a-be73-02537427d1df', 'Smith Machine Incline Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/EeLLZMdg6zI?si=UVsgFN7jhXMm0vW3', 'ملاحظات مهمة:
• ضع المقعد بحيث ينزل البار على أعلى الصدر
• ثبّت لوحي الكتف وانزل بتحكم
• اضبط الحوامل
• لا ترفع الأرداف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Incline Press / ضغط مائل لأعلى', 'Shoulder Flexion + Horizontal Adduction / ثني الكتف + تقريب أفقي', 'Incline Press / ضغط مائل لأعلى', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('37a941a5-1e00-4c6f-9cd7-ed6d5beff623', 'Cable Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/tAILewhtCb0', 'اجلس على بنش انكلاين، اضبط الكيبل بمستوى صدرك تقريبا، ادفع الوزن للأمام باتجاه الداخل، احرص ان كوعك ما يكون بنفس ارتفاع كتفك

ملاحظات مهمة:
• اضبط الكيبل بمستوى الصدر أو أعلى حسب الميل
• قف أو اجلس بثبات وادفع للأمام مع تقريب اليدين
• تحكم في العودة
• الجذع ثابت دون ميلان', 'تصنيف فرعي: التعليمات تذكر بنش انكلاين، وتصنيف المصدر iso_push_chest — يُحسم بين Incline Press وعزل الصدر', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Incline Press / ضغط مائل لأعلى', 'Shoulder Flexion + Horizontal Adduction / ثني الكتف + تقريب أفقي', 'Incline Press / ضغط مائل لأعلى', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6944ff43-0b0f-471d-9c1f-b9a435674c29', 'Sternal Cable Press Around', 'Chest / الصدر', '{}', 'Horizontal Push / دفع أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/y8XQibXDnNo', 'اضبط الكيبل بمستوى صدرك تقريبا، حافظ على ذراعك قريبة من جسمك،ادفع الحبل للأمام باتجاه الداخل.

ملاحظات مهمة:
• ادفع بتقريب اليدين أمام منتصف الصدر
• لا تغلق المرفقين بقوة
• ركّز على انقباض الصدر
• الجذع ثابت وكتفان للخلف', 'تصنيف فرعي: حركة مختلطة بين الضغط والـ Fly — يُحسم بين Flat Press وعزل الصدر', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Press-around / ضغط مع تقريب', 'Horizontal Adduction + Elbow Extension / تقريب أفقي + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7ff62329-7562-4cef-b10a-c7b163d939f8', 'Machine Chest Fly', 'Chest / الصدر', '{}', 'Horizontal Adduction (Fly) / تقريب أفقي للكتف (فلاي)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', NULL, 'ملاحظات مهمة:
• اضبط المقعد ليكون المرفقان بمستوى الصدر
• ثني بسيط ثابت في المرفقين
• افتح حتى تمدد مريح ثم ضم بقوة
• لا ترفع الكتفين', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Chest Isolation / عزل الصدر', 'Horizontal Adduction / تقريب أفقي للكتف', 'Chest Isolation / عزل الصدر', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('08a84b76-c346-48f2-b365-c349efcaa175', 'Bar Cable Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/NhD3h6RG2TA?si=SoyNTIGB-nY2KiXl', 'ملاحظات مهمة:
• استخدم القضيب أمام الصدر والكيبل بالمنتصف
• ادفع بتحكم دون ميلان الجذع
• الكتفان للخلف
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e3b9abe5-1c29-4c2c-9e4c-1c5ef7aa1910', 'DB Chest Supported Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/H75im9fAUMc', 'ثبت صدرك على الكرسي، فتحة واسعة، واسحب الدمبل باتجاه الورك.

ملاحظات مهمة:
• صدرك على مقعد مائل لتثبيت الجذع
• اسحب الدمبلين نحو الجانبين مع ضم لوحي الكتف
• لا ترفع الصدر عن المقعد
• انزل ببطء حتى تمدد', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ec741050-4d08-4fa4-82f2-9ac77f35c3dc', 'Cable Chest Fly', 'Chest / الصدر', '{"Shoulders / الأكتاف"}', 'Horizontal Adduction (Fly) / تقريب أفقي للكتف (فلاي)', 'قوة', 'كيبل', 'مبتدئ', 'نادي', NULL, 'ملاحظات مهمة:
• ضع الكيبل بمستوى الكتف أو أعلى وخطوة أمامية للثبات
• ثني بسيط ثابت في المرفقين
• قرّب اليدين أمام الصدر بقوس
• لا تنزل اليدين أسفل مستوى الصدر', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/160/standing-chest-fly/', NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Chest Isolation / عزل الصدر', 'Horizontal Adduction / تقريب أفقي للكتف', 'Chest Isolation / عزل الصدر', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('96945929-e857-4dfe-b505-043114ca97ab', 'Bent Knee Push-up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'ملاحظات مهمة:
• الركبتان على الأرض والجسم خط من الركبة للرأس
• انزل بالصدر حتى قرب الأرض والمرفقان 45°
• ادفع بدون تدلي الحوض
• تدرّج لاحقاً للضغط الكامل', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/13/bent-knee-push-up/', NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d8177ff6-bd28-4371-8def-32be04236d35', 'Stability Ball Push-Up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس","Core / البطن والكور"}', 'Horizontal Push / دفع أفقي', 'قوة', 'كرة سويسرية', 'متوسط', 'منزل', NULL, 'ملاحظات مهمة:
• اليدان على الكرة أو القدمان عليها حسب الصعوبة
• حافظ على جسم مستقيم وثبات الكرة
• نزول بتحكم
• الخطأ الشائع: تمايل الكرة وتدلّي الورك', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف فرعي: الزاوية تعتمد على موضع الكرة (تحت اليدين أو القدمين) — غير محدد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/63/stability-ball-push-up/', NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f86eb1ae-972b-4429-8abd-80d8311e5509', 'Cable Reardelt Rows', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/uIdXVGjcfFE', 'ثبت نفسك بالكرسي، فتحة واسعة، الكيبل بمستوى اسفل صدرك، واسحب لما تنقبض اكتافك الخلفية.

ملاحظات مهمة:
• اجلس أو قف وأمسك الحبل بقبضة والمرفقان للجانبين بمستوى الكتف
• اسحب نحو الوجه والمرفقان عاليان مع ضم لوحي الكتف
• لا تتمايل بالجذع
• وزن خفيف مع انقباض لحظة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Wide-grip Row / تجديف بقبضة واسعة', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a4bab736-1725-43fd-910c-29229df133d4', 'DB Triceps Extensions', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/d7SXlU5HkYM?si=WuuPa9-yeByaP5sI', 'ملاحظات مهمة:
• مرفقان قريبان من الرأس وثابتان
• انزل خلف الرأس بتحكم ثم افرد المرفقين
• شد البطن وجذع ثابت
• وزن مناسب', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Overhead Extension / مد فوق الرأس', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5f3040f5-39b2-450c-bb80-a37b9c5d759f', 'DB Chest Supported Reardelt Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/x0v6GWYzI18?si=-jDt3D-ARIHouHjp', 'ثبت صدرك على الكرسي، فتحة واسعة، واسحب لما تنقبض اكتافك الخلفية.

ملاحظات مهمة:
• صدرك على مقعد مائل والدمبلان للأسفل
• ارفع المرفقين للجانبين بمستوى الكتف
• لا ترفع الرقبة ولا تستخدم الزخم
• وزن خفيف مع انقباض الكتف الخلفي', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Wide-grip Row / تجديف بقبضة واسعة', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f42e6330-0dde-4165-a1b7-d44543e9f6ef', 'Bent-over Barbell Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'بار', 'متوسط', 'نادي', NULL, 'ادفع مؤخرتك للخلف واثني ركبك، قبضتك بنفس مستوى اكتافك، اسحب لما تنقبض عضلات الظهر.

ملاحظات مهمة:
• انحنِ من الورك حتى جذع شبه موازٍ للأرض وظهر محايد
• اسحب البار نحو أسفل الصدر والمرفقان قريبان من الجسم
• ثبّت الجذع ولا ترفعه لتعويض الوزن
• الخطأ الشائع: تقوّس الظهر وتأرجح الجذع', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5b8e07fc-5ac1-42d7-8535-fef6dcfbb037', 'Cable Reardelt Fly', 'Shoulders / الأكتاف', '{"Rotator cuffs / الكفة المدورة"}', 'Shoulder Rear Pull / سحب خلفي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/bkejPHrPkmA?si=-O8q_5e72udoPRiY', 'ملاحظات مهمة:
• مرفقان مثنيان قليلاً وثابتان
• افتح الذراعين للجانبين بمستوى الكتف باتجاه الخلف
• لا تتمايل بالجذع
• وزن خفيف وانقباض لحظة', 'تصنيف فرعي: حركة Fly (تبعيد أفقي للكتف) وليست سحباً أفقياً أو عمودياً', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Rear Delt Fly / فتح خلفي', 'Horizontal Abduction / تبعيد أفقي للكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('17f8ea87-1501-4c72-86d2-0f16e9283aa4', 'Head Supported Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/c6lkPMhuyFA?si=eUivRGYSi0W7PmVe', 'راسك ثابت على البنش بدون أي ميلان بالرقبة.

ملاحظات مهمة:
• الجبهة أو الصدر على المسند لتثبيت الجذع
• اسحب بالمرفقين وضم لوحي الكتف
• لا ترفع الرقبة
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d2af4a93-39eb-4c5f-91b7-d03a7d93c7e3', 'Single Arm Dumbbell Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/QBjaGx8mS1o', 'اسحب باتجاه الورك.

ملاحظات مهمة:
• ركبة ويد على المقعد وظهر مسطح
• اسحب الدمبل نحو الورك والمرفق قريب من الجسم
• لا تدوّر الجذع
• انزل حتى تمدد لوح الكتف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9eaec49f-f949-4adc-a53c-9f182c248de9', 'Single Arm Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/Qn_mHGObb8E?si=IZ0q9_tseiRIMtcs', 'اسحب باتجاه الورك.

ملاحظات مهمة:
• ثبات القدمين والجذع
• اسحب المقبض نحو الخصر مع ضم لوح الكتف
• لا تميل أو تدوّر الجذع
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('028d5950-abf4-4cbc-94c0-c13a6375317d', 'Chin Ups', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متقدم', 'نادي', 'https://youtube.com/shorts/aV9Mz9nCsMw?si=E_ullJojGO_7srW2', 'ملاحظات مهمة:
• قبضة معكوسة بعرض الكتفين
• اسحب المرفقين للأسفل وللخلف حتى الذقن فوق القضيب
• تعلّق كامل في الأسفل
• تجنّب التأرجح', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cd80004f-dff9-481f-9458-069424eed5c0', 'Chest Supported Machine Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/BZrdEAiR2Xs?si=WhKaSGhR0gKeeies', 'ملاحظات مهمة:
• اضبط المقعد ليكون الصدر على المسند والذراعان ممدودتان
• اسحب المقبضين وضم لوحي الكتف
• لا ترفع الكتفين
• عودة بتحكم', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6ef41d3b-ce3b-4149-9cbf-8cb315ea6eab', 'T-Bar Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/6OtcNinT0HM?si=UPfYyypfZCaN9tTA', 'ملاحظات مهمة:
• ظهر محايد وانحناء من الورك
• اسحب نحو الصدر والمرفقان قريبان من الجسم
• لا تدور الجذع
• حافظ على قبضة ثابتة وركبتين مثنيتين قليلاً', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ab88c24a-16a9-4244-9dbf-4730886b1274', 'Lats Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/CQkT-W18N5g', 'الكيبل بنفس مستوى بطنك، اسحب باتجاه الورك.

ملاحظات مهمة:
• اسحب المقبض نحو أسفل البطن وليس الصدر
• المرفقان قريبان من الجسم وصدر مرفوع
• لا تميل للخلف كثيراً
• تمدد اللاتس في العودة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Lat-focused Row / تجديف لاتس', 'Shoulder Extension / مد الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('02b6f31f-1a2f-40a3-80f9-15215f63de79', 'Upperback Pulldowns', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/bNmvKpJSWKM?si=hy5HgBDAHkzFHcvv', 'ملاحظات مهمة:
• اسحب القضيب نحو أعلى الصدر مع ضم لوحي الكتف والمرفقان للجانبين
• جذع مائل قليلاً للخلف دون تأرجح
• لا ترفع الكتفين
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Wide-grip Pulldown / سحب علوي بقبضة واسعة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('02da076b-c47b-4651-8f0d-b177f2c6fe28', 'Straight Arm Pulldown', 'Back & Lats / الظهر واللاتس', '{}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/hAMcfubonDc?si=ocU_a8VQ4VzZnTg3', 'ملاحظات مهمة:
• ذراعان شبه مستقيمتين
• اسحب القضيب للأسفل نحو الفخذين بحركة من الكتف
• شد البطن ولا تقوّس الظهر
• شعور بتمدد اللاتس في الأعلى', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Straight-arm Pull / سحب بذراع مستقيمة', 'Shoulder Extension + Scapular Depression / مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('da10b4a4-2521-4a88-98e1-c9d0d9a61669', 'DB Y Raises', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/lXp16YozXgk', 'ثبت صدرك على البنش،ارفع الوزن على شكل Y.

ملاحظات مهمة:
• ارفع الذراعين بشكل Y أمام الجسم والإبهام للأعلى
• وزن خفيف جداً
• ثبّت الصدر ولا تتمايل
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Y Raise (Scaption) / رفع Y بمستوى لوح الكتف', 'Shoulder Elevation in Scapular Plane (Scaption) / رفع الذراع بمستوى لوح الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b2976bdf-c631-4bfd-a84c-4097d1cfff91', 'DB Pullover', 'Back & Lats / الظهر واللاتس', '{"Chest / الصدر","Triceps / الترايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/ieFKuQAGYIA?si=uwqyrbKhBL6Id3_-', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.

ملاحظات مهمة:
• استلقِ على مقعد والدمبل بكلتا اليدين فوق الصدر
• انزل خلف الرأس بذراعين شبه مستقيمتين حتى تمدد مريح
• عُد بالسحب بالكتف
• لا تقوّس الظهر ولا تنزل أكثر من مدى كتفك', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Straight-arm Pull / سحب بذراع مستقيمة', 'Shoulder Extension + Scapular Depression / مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('62801db0-576d-4ad0-9d69-9d58fa064d47', 'Band Lat Pulldown', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/5R0RYj3Y9Ro', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.

ملاحظات مهمة:
• ثبّت الشريط عالياً واسحب نحو أعلى الصدر
• المرفقان للأسفل وللجانبين
• لا تتمايل بالجذع
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('05e1192c-ca6c-4af8-a030-22c59703d2f9', 'Band Assisted Pull Ups', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://youtu.be/Ks8ah-8P1b0', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.

ملاحظات مهمة:
• ضع الشريط على الركبة أو القدم لتخفيف الوزن
• ابدأ من تعلّق كامل واسحب حتى الذقن فوق القضيب
• تجنّب التأرجح
• انزل ببطء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('84d36b2e-866b-456c-bfa3-f694cfa69884', 'Pull Ups', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متقدم', 'نادي', 'https://youtu.be/x3NPAxiMRPw?si=Mwg6U1Df5aIFpjKB', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.

ملاحظات مهمة:
• قبضة أوسع قليلاً من الكتفين وتعلّق كامل بكتفين منخفضين
• اسحب المرفقين نحو الجنبين حتى الذقن فوق القضيب
• تجنّب التأرجح واللعب بالرأس
• انزل ببطء 2–3 ثوانٍ', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9dc6cf95-8425-4ec6-81c1-ac3ef5a24cb9', 'Negative Pull-Up', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://youtu.be/gbPURTSxQLY?si=TvQF5zDWfU_rR1Ax', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر، نزول بطيء.

ملاحظات مهمة:
• اصعد بقفزة أو بمساعدة ثم انزل ببطء 3–5 ثوانٍ
• تحكم كامل حتى تعلّق كامل
• الكتفان منخفضان
• لا تسقط في النهاية', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fffb5456-d3f2-49ab-b25d-526f45e2c62c', 'Neutral Grip Lat Pulldown', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/kVB6SlEyjQM', 'القبضة بنفس مستوى الكتف، اسحب باتجاه اعلى الصدر.

ملاحظات مهمة:
• قبضة محايدة والمقبض قريب
• اسحب نحو أعلى الصدر والمرفقان للأسفل
• جذع مائل قليلاً دون تأرجح
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d864e320-9d25-4f10-b5ca-be46f36eb3d2', 'Single Lats Pulldown', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/Qed5O9toqT8', 'اجلس على بنش واسند صدرك عليه، ارجع للخلف قليلا بحيث ان الكيبل ما يكون فوق راسك مباشرة، اسحب الكوع باتجاه الورك.

ملاحظات مهمة:
• اعمل بيد واحدة مع ثبات الجذع
• اسحب المرفق نحو الجنب
• لا تدوّر الجذع
• عودة بطيئة حتى تمدد اللاتس', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('25183420-e87a-4b94-b1c4-65a679b18d09', 'Band Assisted Chin Ups', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://youtu.be/i0yC-0YK6Uk?si=gNX26kIFz_THnR4p', 'مسكة ضيقة بمستوى الأكتاف، كل ما كان الحبل خفيف زادت المقاومة وزدات صعوبة التمرين لذلك ابدأ بحبل ثقيل وخفف كل ما تحسن مستواك.

ملاحظات مهمة:
• قبضة معكوسة وشريط مساعد
• اسحب حتى الذقن فوق القضيب
• تحكم بالنزول
• لا تتأرجح', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b52c3247-1994-47d4-9be3-6fdd78d9772f', 'Kneeling Lat Pulldown', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', NULL, 'متوسط', NULL, NULL, 'ملاحظات مهمة:
• اركع بثبات وجذع مستقيم
• اسحب الكيبل نحو أعلى الصدر أو الخصر بحسب الاتجاه
• لا تجلس على الكعبين
• عودة بطيئة', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/35/kneeling-lat-pulldown/', NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f33b11af-c5a1-4a5e-b057-902d813e7501', 'TRX Back Row', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس","Core / البطن والكور","Lower back / أسفل الظهر"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'TRX', 'متوسط', 'منزل', NULL, 'ملاحظات مهمة:
• جسم مستقيم ومائل للخلف حسب الصعوبة
• اسحب الصدر نحو المقابض وضم لوحي الكتف
• الورك لا يتدلى
• عودة بطيئة', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/84/trx-reg-back-row/', NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ee1cfed8-80ca-476e-a3a3-f3150f46c174', 'Shrug', 'Back & Lats / الظهر واللاتس', '{"Trapezius / الترابيس"}', 'Scapular Elevation / رفع لوح الكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, 'ملاحظات مهمة:
• ارفع الكتفين مباشرة نحو الأذنين دون تدوير
• ثبّت لحظة في الأعلى وانزل بتحكم
• ذراعان مستقيمتان
• لا تحرك الرقبة للأمام', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف فرعي: رفع الأكتاف (Shrug) ليس نمط سحب أفقي أو عمودي', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/72/shrug/', NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Shrug / هز الكتفين', 'Scapular Elevation / رفع لوح الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('bbb9592a-9936-4213-bf01-97547446e847', 'DB Shoulder Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/NKeyUrDYqPk', 'قوّس ظهرك العلوي قليلاً، الكوع قريب من الجسم، النزول الى مستوى الاكتاف

ملاحظات مهمة:
• اجلس بظهر مسنود وانزل الدمبلين حتى مستوى الأذنين
• ادفع للأعلى بخط فوق الكتفين
• لا تغلق المرفقين بعنف
• لا تبالغ في تقوّس الظهر', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('654cf770-70f2-4c62-9a94-39e86dbc15e3', 'DB Standing Shoulder Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/wO0l5jW2NtQ?si=MVvS4F_7iFS8ji9R', 'ملاحظات مهمة:
• قف بثبات وشد البطن والألوية
• ادفع للأعلى دون ميلان الجذع للخلف
• انزل حتى الأذنين
• وزن مناسب دون زخم', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('75d37d45-8d3c-42ba-a689-e96e2329c504', 'Machine Shoulder Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/3R14MnZbcpw', 'قوّس ظهرك العلوي قليلاً، الكوع قريب من الجسم، النزول الى مستوى الاكتاف

ملاحظات مهمة:
• اضبط المقعد ليكون المقبض بمستوى الكتف
• الظهر ملتصق بالمسند
• ادفع دون رفع الكتفين
• عودة بتحكم', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('bc7a7c1b-6f36-441d-8d67-a08c9c073457', 'BB Overhead Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/_RlRDWO2jfg', 'ملاحظات مهمة:
• قبضة أوسع قليلاً من الكتفين
• شد البطن والألوية وادفع بخط مستقيم
• حرّك الرأس للخلف ثم للأمام عند مرور البار
• لا تقوّس أسفل الظهر', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('659c0842-9970-45f7-a161-025e4f292414', 'DB Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/qqntiuPmLDM?feature=share', 'انحني للأمام قليلًا، ارفع للأعلى الى أن تصل لمستوى الأكتاف.

ملاحظات مهمة:
• ارفع بمرفق مثني قليلاً حتى مستوى الكتف فقط
• قدّم المرفق على اليد ولا ترفع الكتفين نحو الأذنين
• نزول بطيء 2–3 ثوانٍ
• لا تتأرجح بالجذع', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4e68c4f1-1da2-4ad6-b398-3d2884841ca5', 'Seated Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/v7fwGurZ9SU?feature=share', 'انحني للأمام قليلًا، ارفع للأعلى الى أن تصل لمستوى الأكتاف.

ملاحظات مهمة:
• اجلس بظهر مسنود لإزالة الزخم
• ارفع حتى مستوى الكتف والمرفقان مثنيان قليلاً
• نزول بطيء
• وزن خفيف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d7c8fa2f-9604-479c-b3f9-9586c68f1bbb', 'Lateral Raise Machine', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/d0pRsZ9SY5w?si=XuXb_Ti0Flow7qvW', 'ملاحظات مهمة:
• اضبط المقعد ليكون محور الكتف مع محور الجهاز
• ارفع الذراعين للجانبين دون رفع الكتفين
• نزول بطيء
• لا تدفع بالجذع', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('dfd5f2d3-2a52-484b-a048-510c4b79afca', 'Cable Crossover Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/wKgCc5UQjoU?si=zsaz3i31PnEU9A43', 'الكيبل يبدأ من الأسفل، انحني للأمام قليلًا، ارفع للأعلى وتحكم بالنزول.

ملاحظات مهمة:
• الكيبل من الجهة المقابلة
• ارفع الذراع قطرياً للجانب حتى مستوى الكتف
• جذع ثابت
• وزن خفيف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e024c235-5358-408a-ac6b-a28b517c125e', 'Cable Y Raises', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/P7u6PEeOn6Q?feature=share', 'الكيبل يبدأ من تحت،ارفع الوزن على شكل Y.

ملاحظات مهمة:
• الكيبل من الأسفل ويدك على شكل Y
• ارفع نحو الأعلى وللخارج بخط قطري
• وزن خفيف وثبات الجذع
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Y Raise (Scaption) / رفع Y بمستوى لوح الكتف', 'Shoulder Elevation in Scapular Plane (Scaption) / رفع الذراع بمستوى لوح الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('52c47158-5686-4026-bbb1-9789cb1eab01', 'Single Arm DB Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/Jm6GqVhWhNY', 'انحني للأمام قليلًا، ارفع للأعلى الى أن تصل لمستوى الأكتاف.

ملاحظات مهمة:
• اعمل بيد واحدة وأمسك سنداً بالأخرى
• ارفع حتى مستوى الكتف دون ميلان الجذع
• نزول بطيء
• وزن خفيف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3d535b51-a843-470d-9756-89f68ef3ab95', 'Single Arm Cable Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/J-6uEOkYAKM', 'الكيبل يبدأ من الأسفل، انحني للأمام قليلًا، ارفع للأعلى وتحكم بالنزول.

ملاحظات مهمة:
• ثبّت الجذع وارفع الذراع للجانب
• الكيبل يعطي شداً من البداية فتحكم في الأسفل
• حتى مستوى الكتف
• لا ترفع الكتف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4a2aa12b-264e-449c-ad99-6bf045c25589', 'Front Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Front Raise / رفع أمامي للكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, 'ملاحظات مهمة:
• ارفع حتى مستوى الكتف فقط والمرفق مثني قليلاً
• لا تتأرجح بالجذع
• نزول بطيء
• وزن مناسب', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/54/front-raise/', NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Front Raise / رفع أمامي', 'Shoulder Flexion / ثني الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f9fea517-19c5-4775-9248-f312fc8965ea', 'Diagonal Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, 'ملاحظات مهمة:
• ارفع بخط قطري من الفخذ المقابل نحو الكتف
• حرّك بتحكم دون تدوير الجذع
• وزن خفيف
• حتى مستوى الكتف', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/371/diagonal-raise/', NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Diagonal Raise / رفع قطري', 'Shoulder Flexion + Abduction (Diagonal) / ثني وتبعيد الكتف (قطري)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('eeece670-d0b2-4b34-883b-4347673f1cbd', 'High Row', 'Shoulders / الأكتاف', '{}', 'Shoulder Rear Pull / سحب خلفي للكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, 'ملاحظات مهمة:
• اسحب نحو الوجه والمرفقان للأعلى وللجانبين
• دوّر الذراعين للخارج في النهاية
• لا تتمايل للخلف
• الرسغ مستقيم', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/336/high-row/', NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'High Row / Face Pull / سحب عالٍ باتجاه الوجه', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('77ecdcb5-6434-46e4-9bef-a7679e7443c8', 'Biceps Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/09AYfVFf7pg?si=dcwLVAYqIbDLM6jd', 'ملاحظات مهمة:
• المرفقان ثابتان بجانب الجسم ولا تتأرجح
• اثنِ حتى انقباض كامل وانزل ببطء 2–3 ثوانٍ
• رسغ محايد
• لا ترفع الكتفين', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('22b300a5-e1c5-4cf5-8cf7-641f4f34a5b9', 'Cable Rope Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/xNXUTJ6TBZA?si=-r-Ql97awoVZla_1', 'ملاحظات مهمة:
• قبضة محايدة بالحبل والمرفقان ثابتان
• اثنِ وأدر الحبل للخارج في الأعلى
• نزول بطيء
• الجذع ثابت', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Hammer / Neutral-grip Curl / ثني بقبضة محايدة', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3ef613aa-1dd0-49b5-8339-bd4954a8a33a', 'Cable Facing Away Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/fV9BpknCjGM', 'ملاحظات مهمة:
• وجهك بعيداً عن الكيبل والذراعان للخلف قليلاً
• اثنِ بالمرفقين مع ثباتهما
• تمدد البايسبس في الأسفل
• لا تتأرجح', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ed5e9a34-efd7-4216-a0f1-3737ad3d7c70', 'DB Incline Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/js_StxxyxBM', 'ملاحظات مهمة:
• على مقعد مائل والذراعان خلف الجسم
• اثنِ بالمرفقين دون تقديمهما للأمام
• تمدد كامل في الأسفل
• وزن خفيف نسبياً', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e11c1ed5-923f-468b-b0df-566860ba9099', 'Cable Facing In Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/5z4y7QRTx1w', 'ملاحظات مهمة:
• وجهك للكيبل والمرفقان للأمام قليلاً
• اثنِ حتى انقباض كامل
• حافظ على شد الكيبل
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('702608a3-3982-44a7-b70a-504a9dd407a0', 'Preacher Curl Machine', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/TouYMA3-ua4?feature=share', 'ملاحظات مهمة:
• اضبط المقعد ليكون العضد على المسند
• اثنِ حتى انقباض
• نزول بطيء دون فرد عنيف
• لا ترفع الكتفين', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Preacher Curl / ثني على مسند', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0137969c-4ec4-4e56-90f4-4d0aea0ed82c', 'DB Spider Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/cTMjzB2_IH8?si=qsIKEEFVfEvPXwqf', 'ملاحظات مهمة:
• الصدر على مقعد مائل والذراعان للأسفل
• اثنِ بالمرفقين مع ثباتهما
• انقباض في الأعلى
• نزول بطيء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5d1714be-8a76-4463-a8db-5f43bf512fa2', 'Zottman Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://www.youtube.com/watch?v=ZXbOOIOPOi8', 'ملاحظات مهمة:
• اثنِ بقبضة عادية ثم دوّر الرسغ في الأعلى وانزل بقبضة معكوسة
• نزول بطيء
• وزن خفيف للساعد
• المرفق ثابت', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('360607f6-c9db-499f-85e1-a5fc48a8eaa9', 'Hammer Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• قبضة محايدة والمرفقان ثابتان
• اثنِ دون تأرجح
• نزول بطيء
• الإبهام للأعلى', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/10/hammer-curl/', NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Hammer / Neutral-grip Curl / ثني بقبضة محايدة', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('39c8dd99-8ffd-4873-82f3-c37bfb069843', 'TRX Biceps Curl', 'Biceps / البايسبس', '{"Forearms / الساعد","Core / البطن والكور"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'TRX', 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• جسم مستقيم ومائل للخلف والمرفقان للأمام
• اثنِ المرفقين نحو الجبهة
• عودة بطيئة
• الورك لا يتدلى', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/78/trx-reg-biceps-curl/', NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6fa175fb-27fb-4296-9319-214a3e1a51fd', 'DB Floor Triceps Extensions', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/dpFav9Ve4rY?si=ZBdKK8VF4aPMpi3v', 'ملاحظات مهمة:
• استلقِ على الأرض والمرفقان للأعلى
• انزل نحو الجبهة أو خلف الرأس بتحكم
• افرد المرفقين دون تحريك العضد
• وزن خفيف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Lying Extension / مد مستلقٍ', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d7ed0f13-e135-4640-895c-9da5cb27142d', 'Cable Crossbody Extensions', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://www.youtube.com/watch?v=jtLTcED38Dg', 'الكيبل يبدأ بالمنتصف زي الفيديو، بحيث لما تسحب الكيبل يكون بنفس مستوى الترابس، الأكواع والأكتاف ثابتين مكانهم والحركة كلها بثني وفرد الكوع.

ملاحظات مهمة:
• اسحب الكيبل بالمرفق ثابتاً وعبر الجسم
• افرد بالكامل مع انقباض الترايسبس
• العضد ثابت
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Cross-body Extension / مد عرضي', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b0f2e958-9be7-4c55-b92f-f5041e14b8d6', 'Triceps Pushdown', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/QsoN4u6j8nM?feature=share', 'انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.

ملاحظات مهمة:
• المرفقان ثابتان بجانب الجسم
• افرد المرفقين بالكامل مع انقباض لحظة
• عودة بطيئة دون رفع الكتفين
• لا تتمايل', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('19231e4e-32e6-4d46-8706-586a872e5b14', 'Cable Crossover Pressdowns', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/Y3CDzx-oj3k', 'الكيبل يبدأ من الأعلى،انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.

ملاحظات مهمة:
• ادفع من الجهتين بمرفقين ثابتين
• افرد بالكامل وانقباض
• عودة بطيئة
• جذع ثابت', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('df3e211c-6d3f-4268-bcd9-74c5265dd22e', 'Band Triceps Pushdown', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/mYs1rEYtZK4?si=k8vdZxNNEB5wj2CA', 'الكيبل يبدأ من الأعلى،انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.

ملاحظات مهمة:
• ثبّت الشريط عالياً
• افرد المرفقين مع بقاء العضد ثابتاً
• عودة بطيئة
• تأكد من ثبات الشريط', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8bda3c4e-7c69-4948-827e-5189bfc5f44d', 'Single Cable Triceps Pressdowns', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/8rl4ioij6lc', 'الكيبل يبدأ من الأعلى،انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.

ملاحظات مهمة:
• بيد واحدة والمرفق ثابت
• افرد بالكامل
• عودة بطيئة
• جذع ثابت', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f0b56696-fa5d-435a-b211-b612538b6db0', 'Cable Overhead Extension', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://www.youtube.com/shorts/Q3bO1Fh4734', 'اترك الحبل يسحب معصمك وكوعك ثابت لما تستطيل التراي ثم ارفع الوزن لما تستقيم اليد، كوعك ثابت طول الوقت والحركة ثني ومد من مفصل الكوع، ممكن تطبق كل يد لحالها اذا كان اسهل لك.

ملاحظات مهمة:
• وجهك للأمام أو الخلف والمرفقان قريبان من الرأس
• افرد المرفقين فوق الرأس بتحكم
• شد البطن لتجنب التقوّس
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Overhead Extension / مد فوق الرأس', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d0a65529-ade3-4af6-ade4-7b89cb9c7374', 'Triceps Dips', 'Triceps / الترايسبس', '{"Chest / الصدر","Shoulders / الأكتاف"}', 'Vertical Push / دفع عمودي', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/SpSE_A5L-YA?si=bSAzRM9SBuX-3mE0', 'ملاحظات مهمة:
• جسم مستقيم على مقعد أو متوازي
• انزل بالمرفقين حتى 90° تقريباً
• لا تتجاوز مدى كتفك
• توقف عند ألم الكتف', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Dip / متوازي', 'Shoulder Extension + Elbow Extension / مد الكتف + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fd8b74d4-0c27-4167-a2ed-5b02597afc34', 'Triceps Kickback', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/YebyKE3Ts8o?si=H_h9z5BXutFBbFhq', 'ملاحظات مهمة:
• العضد موازٍ للجسم وثابت
• افرد المرفق للخلف بتحكم
• انقباض في الأعلى
• وزن خفيف', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/55/triceps-kickback/', NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Triceps Kickback / ركلة الترايسبس', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f2efabb8-0430-4fbc-a080-a69f6b5a98b8', 'Suitcase Carry', 'Core / البطن والكور', '{"Forearms / الساعد"}', 'Loaded Carry / حمل ومشي', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/BaRMAhD7SP4?si=KkiMH8OSIEz_TB53', 'ملاحظات مهمة:
• امشِ بجذع مستقيم دون ميلان نحو الوزن
• كتفان ثابتان وخطوات منتظمة
• شد البطن
• بدّل الجهة', 'نفس التمرين ورد أيضاً تحت التصنيف «Functional Training» (صف المصدر 160) || رابط آخر في المصدر (صف 160): https://youtu.be/BaRMAhD7SP4?si=dCR2n2VSPaHhxfL3', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Suitcase Carry / حمل جانبي', 'Isometric Trunk + Grip Under Load / تثبيت الجذع والقبضة أثناء المشي', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('853ed6ff-7654-4b55-a4ff-010c2871982b', 'Cable Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/ToJeyhydUxU?si=Z5dv34foxX4VtRH6', 'الحركة عبارة عن ثني للعمود الفقري وكأنك تقرب صدرك لوركك.

ملاحظات مهمة:
• اركع أمام الكيبل والحبل عند الرأس
• اثنِ الجذع نحو الأرض بتقوّسه
• الحوض ثابت والحركة من البطن
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Crunch / كرنش', 'Trunk Flexion / ثني الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fca235c8-7e60-481a-ae15-4fd49bca7814', 'Leg Raises', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/UqmbxvOgnX4?si=U3pDG4Jf0x1mtC_7', 'ملاحظات مهمة:
• علّق أو استلقِ وثبّت الظهر
• ارفع الرجلين بتحكم دون تأرجح
• اثنِ الركبتين عند الصعوبة
• نزول بطيء', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Reverse Crunch / Leg Raise / كرنش عكسي ورفع الأرجل', 'Hip Flexion + Posterior Pelvic Tilt / ثني الورك + إمالة الحوض للخلف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('bc0adcfd-9ca2-4f1e-864a-3e3f502f5e09', 'Bosu Ball Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'أخرى', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/KjvDgHPxXcg?si=zad59CHC6Y-calzi', 'ملاحظات مهمة:
• استلقِ على الكرة وأسفل الظهر مدعوم
• اثنِ الجذع للأعلى بتحكم
• لا تسحب الرقبة
• عودة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Crunch / كرنش', 'Trunk Flexion / ثني الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('20ee16f3-c014-409e-964c-60932cbdb1c7', 'Bent Knee V-Up', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/sbyFIM30_G8?si=dED0NQSRS44dz5G9', 'ملاحظات مهمة:
• ارفع الجذع والركبتين معاً نحو بعضهما
• حركة بطيئة بتحكم
• أسفل الظهر لا يتقوس
• زفير عند الرفع', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'V-up / في أب', 'Trunk Flexion + Hip Flexion / ثني الجذع + ثني الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('574a6016-c862-40ea-8b2a-f4d4f851aceb', 'Reverse Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/esYVzdEfs04?si=N44MZZHlVeSQc1S3', 'ملاحظات مهمة:
• ارفع الحوض عن الأرض بتقوّس أسفل الظهر
• لا تستخدم الزخم
• نزول بطيء
• الركبتان مثنيتان', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Reverse Crunch / Leg Raise / كرنش عكسي ورفع الأرجل', 'Hip Flexion + Posterior Pelvic Tilt / ثني الورك + إمالة الحوض للخلف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('08cf0882-a474-4245-a53c-0419b6cfef0e', 'Belly Breathing', 'Core / البطن والكور', '{}', 'Core Activation & Breathing / تفعيل الجذع والتنفس', 'إحماء/تفعيل', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/Shk8cmgv0Ew?si=mXkcj9PH6eH_tLcd', 'نفس عميق من الانف ننفخ فيه البطن ثم نطلعه من الفم ببطئ مع ضغط البطن للداخل اثناء اخراج النفس

ملاحظات مهمة:
• شهيق بطيء من الأنف يوسّع البطن
• زفير بطيء من الفم
• الكتفان مرتخيان
• لا ترفع الصدر', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Diaphragmatic Breathing / تنفس حجابي', 'Diaphragmatic Breathing + Abdominal Bracing / تنفس حجابي + شد البطن', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c9b72760-9094-4cb4-8e0e-507ea304c190', 'Reverse Tabletop Bridge', 'Core / البطن والكور', '{"Glutes / المؤخرة"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://youtu.be/d1yE9cGtPWo?si=2aoNqmUAN054rP75', 'اخذ نفس اثناء الطلوع، اثبت ثواني فوق واشد عضلات بطني، اطلع النفس اثناء النزول

ملاحظات مهمة:
• ارفع الورك حتى استقامة الجسم مع اليدين خلفك
• انقباض الألوية
• الرأس محايد
• لا تبالغ في تقوّس الظهر', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d836356d-f6b0-4fbb-926e-2f210662cab6', 'Pelvic Tilting', 'Core / البطن والكور', '{}', 'Core Activation & Breathing / تفعيل الجذع والتنفس', 'إحماء/تفعيل', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/DqqUIfMuDX4?si=uzl0SRl_M9guUT3j', 'الحركة من الحوض، اخذ نفس وادف حوضي للاعلى قليلا، اطلع النفس اثناء نزول الحوض والصق اسفل ظهري بالارض

ملاحظات مهمة:
• حركة صغيرة ناعمة من الحوض بشد البطن
• لا ترفع الأرداف
• تنفس طبيعي
• لا تضغط بقوة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Pelvic Tilt / إمالة الحوض', 'Posterior Pelvic Tilt / إمالة الحوض للخلف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9a753a1e-d352-4dd9-b3c8-b8bac516a13e', 'Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'ملاحظات مهمة:
• ارفع الكتفين فقط عن الأرض
• لا تسحب الرقبة باليدين
• زفير عند الرفع وانقباض لحظة
• نزول بطيء', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/52/crunch/', NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Crunch / كرنش', 'Trunk Flexion / ثني الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ad77336e-c72c-4604-b1a9-3d6130b46e3b', 'Standing Wood Chop', 'Core / البطن والكور', '{}', 'Trunk Rotation / دوران الجذع', 'كور', NULL, 'مبتدئ', NULL, NULL, 'ملاحظات مهمة:
• دوّر من الجذع والورك والذراعان شبه مستقيمتين
• حرّك من الأعلى للأسفل بخط قطري
• الحوض مستقر
• تحكم في العودة', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/108/standing-wood-chop/', NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Rotation / Chop / دوران وتقطيع', 'Trunk Rotation / دوران الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('55ed01b1-e535-4e41-acd8-13dad9b11b19', 'Russian Twist', 'Core / البطن والكور', '{"Lower back / أسفل الظهر"}', 'Trunk Rotation / دوران الجذع', 'كور', NULL, 'مبتدئ', NULL, NULL, 'ملاحظات مهمة:
• اجلس مائلاً قليلاً بجذع مستقيم
• دوّر الكتفين والجذع لا اليدين فقط
• الرجلان على الأرض عند الصعوبة
• حركة بطيئة', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/65/russian-twist/', NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Rotation / Chop / دوران وتقطيع', 'Trunk Rotation / دوران الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d827f7ef-4ea2-4ae0-8913-fa5331302ada', 'Cable Twisted', 'Core / البطن والكور', '{"Lower back / أسفل الظهر"}', 'Trunk Rotation / دوران الجذع', 'كور', 'كيبل', 'مبتدئ', 'نادي', NULL, 'ملاحظات مهمة:
• ثبّت الحوض ودوّر من الجذع
• ذراعان شبه مستقيمتين
• تحكم في العودة
• وزن مناسب', NULL, 'إضافة المدربة', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Rotation / Chop / دوران وتقطيع', 'Trunk Rotation / دوران الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('211054ad-84ff-4609-8e21-b4b43723feab', 'Calves On Leg Press', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/XdtWVYFVhGU', 'ثبت أصابعك أو مقدمة رجلك على الجهاز، لا تبالغ بالوزن، انزل بكعبك لين تمتد بطاتك بشكل كامل ثم ادفع.

ملاحظات مهمة:
• القدمان على الحافة السفلى للمنصة والركبتان مفرودتان قليلاً دون قفل
• ادفع بمقدمة القدم لأقصى ارتفاع ثم انزل حتى تمدد البطة
• توقف لحظة في الأعلى والأسفل
• لا ترتد', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f935ae95-a906-4a53-bf40-629cdddbea18', 'Calves Raise', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/H6WptvjXkgw', 'حط تحت اقدامك بليتس أو أي شي يرفعك عن الأرض، انزل من اصابعك اقصى نزول ثم ادفع للأعلى

ملاحظات مهمة:
• ارتفع على أطراف الأصابع لأقصى مدى
• انزل حتى تمدد البطة
• توقف في الأعلى
• حركة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b152309f-149a-4d69-9ea4-31df312794c9', 'Calf Raise (Machine)', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', 'جهاز', 'مبتدئ', 'نادي', NULL, 'ملاحظات مهمة:
• ضع الكتفين تحت المساند وأصابع القدم على الحافة
• ارتفع لأقصى مدى وانزل حتى تمدد
• توقف لحظة في الأعلى
• لا ترتد', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/294/calf-raise/', NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e83b47cf-c2f2-4b2c-ade7-2706f1ce6bea', 'Calf Raises (Barbell)', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', 'بار', 'مبتدئ', 'نادي', NULL, 'ملاحظات مهمة:
• البار على أعلى الظهر وقوف ثابت
• ارتفع على الأصابع بتحكم
• مدى كامل بدون ارتداد
• سند للتوازن', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/51/calf-raises/', NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('799855e3-c8d8-407b-b6a5-0fb5b93a223c', 'Adductor Slides', 'Adductors / الأفخاذ الداخلية', '{}', 'Hip Adduction / تقريب الورك', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/6U7dfuxaX9g?si=lkH35E7tZxGBePBj', 'ملاحظات مهمة:
• انزلق بالرجل للجانب بتحكم
• الجذع ثابت
• ادفع للعودة بالعضلة الداخلية
• حركة بطيئة', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor strength»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Adductor Slide / انزلاق للتقريب', 'Hip Adduction / تقريب الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('de3c3400-6508-4d4c-8fd4-18b4fad2a7f3', 'Adductor Machine', 'Adductors / الأفخاذ الداخلية', '{}', 'Hip Adduction / تقريب الورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/SU1LQhq3o2g?si=_55FKBOlcn8Ilw4X', 'ملاحظات مهمة:
• اضبط مدى مريح للبداية
• اضغط الفخذين معاً بتحكم
• عودة بطيئة دون ارتداد
• لا تفتح أكثر من مدى مريح', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Adductor Machine / جهاز التقريب', 'Hip Adduction / تقريب الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('89744779-51c2-4271-a56b-fcee29aa3cbd', 'Supine Hamstrings Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'استلقِ على ظهرك وارفع رجلاً واحدة ومدّها ببطء مع سحب أصابع القدم نحوك، دون أي حركة في الحوض أو أسفل الظهر. اثبت 15–30 ثانية، 2–4 مرات لكل رجل.

ملاحظات مهمة:
• استلقِ وارفع رجلاً بمساعدة شريط أو يدين
• ركبة شبه مفرودة بدون ألم
• شد مريح للخلفية
• ثبّت 20–40 ثانية', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/235/supine-hamstrings-stretch/', NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Hamstring Stretch / إطالة الخلفية', 'Hip Flexion with Knee Extended / ثني الورك مع مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a392bf3b-3edb-4507-abc9-b6a10552bbd2', 'Seated Abductor Machine', 'Abductors / مبعدات الفخذ', '{}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/riEMreTHNbM?si=wE3vfJBYQY7j_oJ2', 'ملاحظات مهمة:
• ظهر ملتصق بالمسند
• افتح الركبتين للخارج بتحكم
• انقباض لحظة
• عودة بطيئة', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor strength»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c5298e5b-9889-4d6c-a611-471ded9aa89f', 'Hip Abductor Plank', 'Abductors / مبعدات الفخذ', '{"Core / البطن والكور"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/2lB5RL91yWo?si=WRm9rUORpFK6dXPl', 'ملاحظات مهمة:
• بلانك جانبي بجسم مستقيم
• ارفع الرجل العليا بتحكم
• الحوض لا يميل
• ثبّت الكتف تحت المرفق', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor strength»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7fc4c740-f4c9-4d5f-b6a1-f24132ef85ef', 'Dirty Dog', 'Abductors / مبعدات الفخذ', '{"Core / البطن والكور"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'ملاحظات مهمة:
• على أربع مع ظهر محايد
• ارفع الركبة للجانب كالكلب بتحكم
• الحوض ثابت دون ميلان
• حركة بطيئة', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/109/dirty-dog/', NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('37b2fd10-3050-4069-af65-a3c8494d64ac', 'Rotator Cuff', 'Rotator cuffs / الكفة المدورة', '{}', 'Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/mO8YJAxVG2M?si=KL_llR6Z47Yt89uk', 'ملاحظات مهمة:
• وزن خفيف جداً والمرفق ملتصق بالجسم
• دوّر الساعد للخارج بتحكم دون ألم
• حركة بطيئة
• لا تقوّس الظهر', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «Functional Training»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'External Rotation / دوران خارجي', 'Shoulder External Rotation / دوران خارجي للكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1d291a92-f1b1-4db0-a5b3-673bf9ecb36c', 'Side Lying Quadriceps Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'استلقِ على جنبك وشد البطن، واسحب كعب الرجل العلوية نحو المؤخرة بيدك مع إبقاء الركبة في خط الورك. اثبت 30–45 ثانية، 2–5 مرات لكل جهة.

ملاحظات مهمة:
• على الجنب اسحب الكعب نحو الأرداف
• الركبتان متقاربتان والحوض ثابت
• شد مريح بدون ألم الركبة
• ثبّت 20–40 ثانية', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/149/side-lying-quadriceps-stretch/', NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Quadriceps Stretch / إطالة الأمامية', 'Knee Flexion + Hip Extension (End Range) / ثني الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('10c133f4-3e1d-4719-b18e-790c489e6930', 'Stability Ball Reverse Extensions', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة"}', 'Spinal Extension / بسط الجذع', 'كور', 'كرة سويسرية', 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• على بطنك على الكرة
• ارفع الرجلين بتحكم حتى استقامة الجسم
• لا تبالغ بالتقوّس
• شد الألوية', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/64/stability-ball-reverse-extensions/', NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Reverse Extension / بسط عكسي', 'Hip Extension + Spinal Extension / بسط الورك + بسط العمود الفقري', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('025983b2-fb85-4642-8a0f-c39690cd8e3f', 'Contralateral Limb Raises', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة","Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Spinal Extension / بسط الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'ملاحظات مهمة:
• على أربع، ارفع اليد والرجل المقابلة بتحكم
• الحوض والظهر ثابتان دون ميلان
• ثبّت لحظة
• بدّل الجهة', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/53/contralateral-limb-raises/', NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Prone Extension / بسط على البطن', 'Spinal Extension / بسط العمود الفقري', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3befcd1c-681e-4a2b-b30d-469a3d7fb085', 'Inner Thigh Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/uqCfJYKojLU?si=Gev0VeOwVp5z6gB2', 'الضغط والدفع يكون من جهة الفخذ ، لا تدفع من ركبتك!

ملاحظات مهمة:
• اجلس بفتح الرجلين وقدمين ملتصقتين
• اضغط الركبتين للأسفل برفق
• شد مريح وليس ألماً
• ثبّت 20–40 ثانية', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «stretch»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Adductor Stretch / إطالة المقربات', 'Hip Abduction (Adductor Stretch) / تبعيد الورك (إطالة المقربات)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8196ffd8-de45-4f82-abb9-7a60524515b2', 'Hips Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/uqCfJYKojLU?si=Gev0VeOwVp5z6gB2', 'ملاحظات مهمة:
• وضعية ممتدة للورك بجذع مستقيم
• اضغط برفق دون ألم
• تنفس بهدوء
• ثبّت 20–40 ثانية', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «stretch»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Hip Stretch / إطالة الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c627201e-0128-4b45-a325-e11580c9425d', 'Kneeling Hip-flexor Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'من وضع الركوع: الركبة الخلفية تحت الورك والقدم الأمامية أمامك والركبة فوق الكاحل. شد البطن وادفع الحوض للأمام دون تقويس أسفل الظهر، واعصر مؤخرة الجهة الخلفية لزيادة الإطالة. اثبت 30–45 ثانية، 2–5 مرات.

ملاحظات مهمة:
• ركبة على الأرض والأخرى أمامك
• ادفع الحوض للأمام مع شد البطن
• شد في مقدمة الورك
• لا تقوّس أسفل الظهر', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/142/kneeling-hip-flexor-stretch/', NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Hip Flexor Stretch / إطالة ثانيات الورك', 'Hip Extension (End Range) / بسط الورك في نهاية المدى', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('134548eb-60b9-4c7b-95bb-c2d766faec2e', 'Standing Lunge Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'ملاحظات مهمة:
• وضعية لانج ثابتة وحوض للأمام
• جذع مستقيم وشد البطن
• شد في مقدمة ورك الرجل الخلفية
• ثبّت 20–40 ثانية', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/137/standing-lunge-stretch/', NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Hip Flexor Stretch / إطالة ثانيات الورك', 'Hip Extension (End Range) / بسط الورك في نهاية المدى', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cbfbeffc-b548-474a-ab10-a0a28a7b7a66', 'Lateral Bound', 'Plyometrics / التمارين الانفجارية', '{"Glutes / المؤخرة","Quadriceps / الأمامية","Abductors / مبعدات الفخذ"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://www.youtube.com/watch?v=soqQy4dzEts', 'ملاحظات مهمة:
• اقفز جانبياً وهبوط ناعم على رجل واحدة
• الركبة فوق القدم دون انهيار
• ثبّت لحظة
• ابدأ بمسافة قصيرة', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «Functional Training»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Lateral Jump / قفز جانبي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8b573091-8dfa-4c0f-bda5-c576513e5696', 'Box Jumps', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Calves / البطات"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'أخرى', 'متوسط', 'نادي', NULL, 'ملاحظات مهمة:
• اقفز بانفجار وهبوط ناعم على صندوق
• الركبتان مثنيتان عند الهبوط
• انزل بالخطوة لا بالقفز
• ابدأ بارتفاع منخفض', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «CrossFit»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Vertical Jump / قفز عمودي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8f5c2fd1-5012-44e9-b3be-7feab3b4aed6', 'Squat Jump', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متوسط', 'بدون معدات', NULL, 'قف بعرض الحوض، ادفع الورك للخلف وانزل، ثم اقفز بقوة بمدّ الكاحل والركبة والورك معاً. انزل بهدوء على منتصف القدم مع دفع الورك للخلف ودون قفل الركب. ابدأ بقفزات صغيرة حتى تتقن الهبوط.

ملاحظات مهمة:
• انزل بسكوات ثم اقفز لأعلى بانفجار
• هبوط ناعم على كامل القدم
• الركبتان باتجاه الأصابع
• أوقف المجموعة عند هبوط الأداء', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/222/squat-jump/', NULL, 'review', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Vertical Jump / قفز عمودي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7a7b0b89-1957-47a7-ab90-80cd2bcc2793', 'Tuck Jump', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متقدم', 'بدون معدات', NULL, 'استخدم الذراعين للزخم: أرجعهما للخلف عند النزول وأرجحهما للأمام والأعلى عند القفز، واسحب الركبتين نحو الصدر في الهواء.

ملاحظات مهمة:
• اقفز واسحب الركبتين نحو الصدر
• هبوط ناعم والركبتان مثنيتان
• حافظ على جذع مستقيم
• مجموعات قصيرة', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/180/tuck-jump/', NULL, 'review', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Vertical Jump / قفز عمودي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('205622e7-a996-40f9-be6d-df8077f18227', 'Cycled Split-Squat Jump', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Hamstrings / الخلفية"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متقدم', 'بدون معدات', NULL, 'ملاحظات مهمة:
• من وضع لانج اقفز وبدّل الرجلين في الهواء
• هبوط ناعم والركبة فوق القدم
• جذع مرفوع
• مجموعات قصيرة', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/234/cycled-split-squat-jump/', NULL, 'review', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Split Jump / قفز سبليت', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ae417979-f142-484d-93ed-d889273386db', 'Lateral Cone Jumps', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Calves / البطات"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'أخرى', 'متوسط', 'نادي', NULL, 'ملاحظات مهمة:
• اقفز جانبياً فوق الحواجز بتحكم
• هبوط ناعم وركبتان مثنيتان
• حافظ على الجسم متزناً
• مسافة آمنة', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/120/lateral-cone-jumps/', NULL, 'review', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Lateral Jump / قفز جانبي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('dbac4b5f-881a-4c5d-8537-47197e329432', 'Forward Linear Jumps', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Hamstrings / الخلفية"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متوسط', 'بدون معدات', NULL, 'ملاحظات مهمة:
• اقفز للأمام بانفجار وهبوط ناعم
• ركبتان باتجاه الأصابع
• حافظ على توازنك قبل القفزة التالية
• مسافات قصيرة في البداية', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/177/forward-linear-jumps/', NULL, 'review', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Horizontal Jump / قفز أمامي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('25256958-b577-45ca-afed-d68e2c379ae0', 'Jogging', 'CrossFit / كروس فت', '{"Quadriceps / الأمامية","Hamstrings / الخلفية","Calves / البطات"}', 'Locomotion / مشي وجري ودفع', 'كارديو', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'ملاحظات مهمة:
• ابدأ بإحماء تدريجي وخطوات خفيفة
• جذع مستقيم وكتفان مرتخيان
• زد السرعة والمسافة تدريجياً
• حذاء مناسب', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Running / جري', 'Gait: Alternating Hip/Knee Extension / نمط المشي والجري', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0a15de10-121f-4ccf-86b7-7b3d99f9d1e5', 'Wall Ball', 'CrossFit / كروس فت', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Shoulders / الأكتاف"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'أخرى', 'متوسط', 'نادي', NULL, 'ملاحظات مهمة:
• سكوات ثم رمي الكرة على الهدف بانفجار
• ابدأ بوزن خفيف
• استقبل الكرة بذراعين مرنتين
• ركبتان باتجاه الأصابع', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Squat to Throw / سكوات مع رمي', 'Knee/Hip Extension + Shoulder Flexion / مد الركبة والورك + ثني الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('234787c2-fdb8-4342-8858-d679274c1409', 'Snatch', 'CrossFit / كروس فت', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Shoulders / الأكتاف"}', 'Olympic Lift (Triple Extension) / رفعات أولمبية (بسط ثلاثي)', 'قدرة', 'بار', 'متقدم', 'نادي', NULL, 'ملاحظات مهمة:
• تقنية معقدة، تعلّمها بعصا أو وزن خفيف وبإشراف مدرب
• البار قريب من الجسم
• الدفع من الورك والركبة والكاحل
• ظهر محايد', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Snatch / سناتش', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0fb47938-8cde-4f23-bf31-494d40c22af7', 'Clean', 'CrossFit / كروس فت', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Quadriceps / الأمامية"}', 'Olympic Lift (Triple Extension) / رفعات أولمبية (بسط ثلاثي)', 'قدرة', 'بار', 'متقدم', 'نادي', NULL, 'ملاحظات مهمة:
• تقنية معقدة، ابدأ بوزن خفيف وبإشراف مدرب
• الدفع من الورك ثم استقبال البار بمرفقين عاليين
• البار قريب من الجسم
• ظهر محايد', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Clean / كلين', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9b6932fe-c602-47b7-8e66-82bbb78e5b8d', 'Turkish Get-Up', 'Functional / التمارين الوظيفية', '{"Shoulders / الأكتاف","Core / البطن والكور","Glutes / المؤخرة"}', 'Full-body Integrated / حركة متكاملة للجسم', 'قوة', 'كيتلبل', 'متقدم', 'منزل', 'https://www.youtube.com/watch?v=0bWRPC49-KI', 'ملاحظات مهمة:
• تحرك بخطوات واضحة وعيناك على الوزن
• الذراع عمودية فوقك طوال الحركة
• ابدأ بدون وزن
• حركة بطيئة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Turkish Get-Up / النهوض التركي', 'Multi-joint Integrated / حركة متعددة المفاصل', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d4f9199e-7edf-4688-8819-90fd9f437c3e', 'Sled Pull/Push', 'Functional / التمارين الوظيفية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Calves / البطات"}', 'Locomotion / مشي وجري ودفع', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://www.youtube.com/watch?v=3KWK7SIdPz4', 'ملاحظات مهمة:
• جذع ثابت مائل للأمام
• خطوات قوية متتالية
• تنفس منتظم
• وزن يسمح بالحفاظ على الوضعية', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Sled Push / Pull / دفع وسحب الزلاجة', 'Hip/Knee Extension in Gait / بسط الورك والركبة بنمط المشي', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('311ee988-ffd9-4b5a-b296-d702906dce9d', 'Farmer’s Walk', 'Functional / التمارين الوظيفية', '{"Forearms / الساعد","Core / البطن والكور","Back & Lats / الظهر واللاتس"}', 'Loaded Carry / حمل ومشي', 'قوة', NULL, 'مبتدئ', NULL, 'https://www.youtube.com/watch?v=hx24PM6gXs8', 'ملاحظات مهمة:
• قبضة قوية وكتفان للخلف
• جذع مستقيم وخطوات قصيرة
• شد البطن
• لا تتمايل', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Farmer''s Walk / مشي المزارع', 'Isometric Trunk + Grip Under Load / تثبيت الجذع والقبضة أثناء المشي', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('441e6059-5038-42ec-9709-8d944df11879', '90s Transition', 'Functional / التمارين الوظيفية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://www.youtube.com/watch?v=ogU-azeGe_k', 'ملاحظات مهمة:
• اجلس بزاوية 90° للورك والركبة وانتقل بتحكم
• جذع مستقيم
• حركة بطيئة ضمن مدى مريح
• لا تفرض المدى', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Hip Rotation Mobility (90/90) / مرونة دوران الورك', 'Hip Internal/External Rotation / دوران الورك الداخلي والخارجي', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('98bacc93-a7cb-4f7d-a3c5-a6b8da4d782e', 'Kettlebell Swing', 'Functional / التمارين الوظيفية', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Core / البطن والكور"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قدرة', 'كيتلبل', 'متوسط', 'منزل', 'https://www.youtube.com/watch?v=d94xX-AQZ0A', 'ملاحظات مهمة:
• ادفع الورك للأمام بانفجار ولا ترفع الكيتلبل بالذراعين
• ظهر محايد وركبتان مثنيتان قليلاً
• شد الألوية في الأعلى
• الكيتلبل يعود بين الساقين بتحكم', 'نفس التمرين ورد أيضاً تحت التصنيف «CrossFit» (صف المصدر 168)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Ballistic Hinge (Swing) / مفصلة انفجارية (سوينق)', 'Hip Extension (Ballistic) / بسط الورك الانفجاري', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4502580f-10f5-461c-804f-a1b0f28cdaaf', 'Serratus Punches Supine', 'Functional / التمارين الوظيفية', '{"Shoulders / الأكتاف","Chest / الصدر"}', 'Horizontal Push / دفع أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/cxaAqmdlrgk?si=2YRAIgFFXPAvDadG', 'ملاحظات مهمة:
• استلقِ والذراعان نحو السقف
• ادفع الكتف للأعلى بحركة لوح الكتف دون ثني المرفق
• حركة صغيرة بتحكم
• لا ترفع الرأس', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'Scapular Protraction / دفع لوح الكتف', 'Scapular Protraction / دفع لوح الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;



INSERT INTO public.exercise_alternatives VALUES ('d6262429-012e-446f-940a-c536000c22ae', '2e96c8bd-869f-4cf5-8d93-cb3c53f978fd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d6262429-012e-446f-940a-c536000c22ae', 'c3e53b68-e19f-45fe-a508-8093d8528c5f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d6262429-012e-446f-940a-c536000c22ae', 'd21dec43-2173-47df-acfa-b8f8bbe8a9cf', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d6262429-012e-446f-940a-c536000c22ae', 'e680b389-9b6a-4ec9-bf76-1a8f4fe9f82b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d6262429-012e-446f-940a-c536000c22ae', '17039fbc-327a-4528-b5f7-d65ca29f6c45', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2e96c8bd-869f-4cf5-8d93-cb3c53f978fd', 'd6262429-012e-446f-940a-c536000c22ae', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2e96c8bd-869f-4cf5-8d93-cb3c53f978fd', 'c3e53b68-e19f-45fe-a508-8093d8528c5f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2e96c8bd-869f-4cf5-8d93-cb3c53f978fd', 'd21dec43-2173-47df-acfa-b8f8bbe8a9cf', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2e96c8bd-869f-4cf5-8d93-cb3c53f978fd', 'e680b389-9b6a-4ec9-bf76-1a8f4fe9f82b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2e96c8bd-869f-4cf5-8d93-cb3c53f978fd', '17039fbc-327a-4528-b5f7-d65ca29f6c45', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dab86bf0-9c23-466f-aee0-0405844d9c6c', 'dbe0f863-b00c-48a8-8001-aa30f6758454', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dab86bf0-9c23-466f-aee0-0405844d9c6c', '0adb8588-55e8-4e9d-84ad-be8966e23eba', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dab86bf0-9c23-466f-aee0-0405844d9c6c', 'd6262429-012e-446f-940a-c536000c22ae', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dab86bf0-9c23-466f-aee0-0405844d9c6c', '2e96c8bd-869f-4cf5-8d93-cb3c53f978fd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dab86bf0-9c23-466f-aee0-0405844d9c6c', '495bdfe7-92fa-41e5-95c5-703d493e64a3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('495bdfe7-92fa-41e5-95c5-703d493e64a3', '2cc1d092-a2e2-4a6a-a92f-203ed177ac88', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('495bdfe7-92fa-41e5-95c5-703d493e64a3', 'd6262429-012e-446f-940a-c536000c22ae', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('495bdfe7-92fa-41e5-95c5-703d493e64a3', '2e96c8bd-869f-4cf5-8d93-cb3c53f978fd', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('495bdfe7-92fa-41e5-95c5-703d493e64a3', 'dab86bf0-9c23-466f-aee0-0405844d9c6c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('495bdfe7-92fa-41e5-95c5-703d493e64a3', 'c3e53b68-e19f-45fe-a508-8093d8528c5f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2cc1d092-a2e2-4a6a-a92f-203ed177ac88', '495bdfe7-92fa-41e5-95c5-703d493e64a3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2cc1d092-a2e2-4a6a-a92f-203ed177ac88', 'd6262429-012e-446f-940a-c536000c22ae', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2cc1d092-a2e2-4a6a-a92f-203ed177ac88', '2e96c8bd-869f-4cf5-8d93-cb3c53f978fd', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2cc1d092-a2e2-4a6a-a92f-203ed177ac88', 'dab86bf0-9c23-466f-aee0-0405844d9c6c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2cc1d092-a2e2-4a6a-a92f-203ed177ac88', 'c3e53b68-e19f-45fe-a508-8093d8528c5f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c3e53b68-e19f-45fe-a508-8093d8528c5f', 'd6262429-012e-446f-940a-c536000c22ae', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c3e53b68-e19f-45fe-a508-8093d8528c5f', '2e96c8bd-869f-4cf5-8d93-cb3c53f978fd', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c3e53b68-e19f-45fe-a508-8093d8528c5f', 'd21dec43-2173-47df-acfa-b8f8bbe8a9cf', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c3e53b68-e19f-45fe-a508-8093d8528c5f', 'e680b389-9b6a-4ec9-bf76-1a8f4fe9f82b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c3e53b68-e19f-45fe-a508-8093d8528c5f', '17039fbc-327a-4528-b5f7-d65ca29f6c45', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d21dec43-2173-47df-acfa-b8f8bbe8a9cf', 'd6262429-012e-446f-940a-c536000c22ae', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d21dec43-2173-47df-acfa-b8f8bbe8a9cf', '2e96c8bd-869f-4cf5-8d93-cb3c53f978fd', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d21dec43-2173-47df-acfa-b8f8bbe8a9cf', 'c3e53b68-e19f-45fe-a508-8093d8528c5f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d21dec43-2173-47df-acfa-b8f8bbe8a9cf', 'e680b389-9b6a-4ec9-bf76-1a8f4fe9f82b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d21dec43-2173-47df-acfa-b8f8bbe8a9cf', '17039fbc-327a-4528-b5f7-d65ca29f6c45', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dbe0f863-b00c-48a8-8001-aa30f6758454', 'dab86bf0-9c23-466f-aee0-0405844d9c6c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dbe0f863-b00c-48a8-8001-aa30f6758454', '0adb8588-55e8-4e9d-84ad-be8966e23eba', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dbe0f863-b00c-48a8-8001-aa30f6758454', 'd6262429-012e-446f-940a-c536000c22ae', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dbe0f863-b00c-48a8-8001-aa30f6758454', '2e96c8bd-869f-4cf5-8d93-cb3c53f978fd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dbe0f863-b00c-48a8-8001-aa30f6758454', '495bdfe7-92fa-41e5-95c5-703d493e64a3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e680b389-9b6a-4ec9-bf76-1a8f4fe9f82b', 'd6262429-012e-446f-940a-c536000c22ae', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e680b389-9b6a-4ec9-bf76-1a8f4fe9f82b', '2e96c8bd-869f-4cf5-8d93-cb3c53f978fd', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e680b389-9b6a-4ec9-bf76-1a8f4fe9f82b', 'c3e53b68-e19f-45fe-a508-8093d8528c5f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e680b389-9b6a-4ec9-bf76-1a8f4fe9f82b', 'd21dec43-2173-47df-acfa-b8f8bbe8a9cf', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e680b389-9b6a-4ec9-bf76-1a8f4fe9f82b', '17039fbc-327a-4528-b5f7-d65ca29f6c45', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0adb8588-55e8-4e9d-84ad-be8966e23eba', 'dab86bf0-9c23-466f-aee0-0405844d9c6c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0adb8588-55e8-4e9d-84ad-be8966e23eba', 'dbe0f863-b00c-48a8-8001-aa30f6758454', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0adb8588-55e8-4e9d-84ad-be8966e23eba', 'd6262429-012e-446f-940a-c536000c22ae', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0adb8588-55e8-4e9d-84ad-be8966e23eba', '2e96c8bd-869f-4cf5-8d93-cb3c53f978fd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0adb8588-55e8-4e9d-84ad-be8966e23eba', '495bdfe7-92fa-41e5-95c5-703d493e64a3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('740745cf-0902-4667-97a1-c585c4178578', '43a0b6dd-50ee-4bb8-bbc6-71f5fec267f2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('740745cf-0902-4667-97a1-c585c4178578', 'c057dee3-1048-4b03-9c69-b02f8a417c23', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('740745cf-0902-4667-97a1-c585c4178578', '5a6c9231-42c7-4ddd-b705-e2cb1e097b92', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('740745cf-0902-4667-97a1-c585c4178578', 'cf9cf7e5-c062-4e51-be95-36ed8cf7288c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('740745cf-0902-4667-97a1-c585c4178578', '9e2fe2fc-5233-4f75-ae69-cafaeadbfbaa', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('43a0b6dd-50ee-4bb8-bbc6-71f5fec267f2', 'c057dee3-1048-4b03-9c69-b02f8a417c23', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('43a0b6dd-50ee-4bb8-bbc6-71f5fec267f2', '5a6c9231-42c7-4ddd-b705-e2cb1e097b92', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('43a0b6dd-50ee-4bb8-bbc6-71f5fec267f2', '9e2fe2fc-5233-4f75-ae69-cafaeadbfbaa', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('43a0b6dd-50ee-4bb8-bbc6-71f5fec267f2', '349784c5-1d73-4380-bfe9-98b13ef6c6bc', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('43a0b6dd-50ee-4bb8-bbc6-71f5fec267f2', '740745cf-0902-4667-97a1-c585c4178578', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c057dee3-1048-4b03-9c69-b02f8a417c23', '43a0b6dd-50ee-4bb8-bbc6-71f5fec267f2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c057dee3-1048-4b03-9c69-b02f8a417c23', '5a6c9231-42c7-4ddd-b705-e2cb1e097b92', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c057dee3-1048-4b03-9c69-b02f8a417c23', '9e2fe2fc-5233-4f75-ae69-cafaeadbfbaa', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c057dee3-1048-4b03-9c69-b02f8a417c23', '349784c5-1d73-4380-bfe9-98b13ef6c6bc', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c057dee3-1048-4b03-9c69-b02f8a417c23', '740745cf-0902-4667-97a1-c585c4178578', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5a6c9231-42c7-4ddd-b705-e2cb1e097b92', '43a0b6dd-50ee-4bb8-bbc6-71f5fec267f2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5a6c9231-42c7-4ddd-b705-e2cb1e097b92', 'c057dee3-1048-4b03-9c69-b02f8a417c23', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5a6c9231-42c7-4ddd-b705-e2cb1e097b92', '9e2fe2fc-5233-4f75-ae69-cafaeadbfbaa', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5a6c9231-42c7-4ddd-b705-e2cb1e097b92', '349784c5-1d73-4380-bfe9-98b13ef6c6bc', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5a6c9231-42c7-4ddd-b705-e2cb1e097b92', '740745cf-0902-4667-97a1-c585c4178578', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cf9cf7e5-c062-4e51-be95-36ed8cf7288c', '740745cf-0902-4667-97a1-c585c4178578', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cf9cf7e5-c062-4e51-be95-36ed8cf7288c', '43a0b6dd-50ee-4bb8-bbc6-71f5fec267f2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cf9cf7e5-c062-4e51-be95-36ed8cf7288c', 'c057dee3-1048-4b03-9c69-b02f8a417c23', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cf9cf7e5-c062-4e51-be95-36ed8cf7288c', '5a6c9231-42c7-4ddd-b705-e2cb1e097b92', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cf9cf7e5-c062-4e51-be95-36ed8cf7288c', '9e2fe2fc-5233-4f75-ae69-cafaeadbfbaa', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9e2fe2fc-5233-4f75-ae69-cafaeadbfbaa', '43a0b6dd-50ee-4bb8-bbc6-71f5fec267f2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9e2fe2fc-5233-4f75-ae69-cafaeadbfbaa', 'c057dee3-1048-4b03-9c69-b02f8a417c23', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9e2fe2fc-5233-4f75-ae69-cafaeadbfbaa', '5a6c9231-42c7-4ddd-b705-e2cb1e097b92', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9e2fe2fc-5233-4f75-ae69-cafaeadbfbaa', '349784c5-1d73-4380-bfe9-98b13ef6c6bc', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9e2fe2fc-5233-4f75-ae69-cafaeadbfbaa', '740745cf-0902-4667-97a1-c585c4178578', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('349784c5-1d73-4380-bfe9-98b13ef6c6bc', '43a0b6dd-50ee-4bb8-bbc6-71f5fec267f2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('349784c5-1d73-4380-bfe9-98b13ef6c6bc', 'c057dee3-1048-4b03-9c69-b02f8a417c23', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('349784c5-1d73-4380-bfe9-98b13ef6c6bc', '5a6c9231-42c7-4ddd-b705-e2cb1e097b92', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('349784c5-1d73-4380-bfe9-98b13ef6c6bc', '9e2fe2fc-5233-4f75-ae69-cafaeadbfbaa', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('349784c5-1d73-4380-bfe9-98b13ef6c6bc', '740745cf-0902-4667-97a1-c585c4178578', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('17fb0c9f-dd60-419a-9f43-b5cf181e0605', '278fd68b-2962-4b30-92b1-02b49e56d1dd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('17fb0c9f-dd60-419a-9f43-b5cf181e0605', 'fe89150b-4b21-4e31-93d5-878217afee70', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('17fb0c9f-dd60-419a-9f43-b5cf181e0605', '0f8924a7-5f2e-423a-b78d-3566c58d21ba', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('17fb0c9f-dd60-419a-9f43-b5cf181e0605', 'a1a8cef8-0f95-4d39-a527-4cc352e51525', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('17fb0c9f-dd60-419a-9f43-b5cf181e0605', '67838f5f-9595-4867-b0fc-8b18b16045be', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('278fd68b-2962-4b30-92b1-02b49e56d1dd', '17fb0c9f-dd60-419a-9f43-b5cf181e0605', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('278fd68b-2962-4b30-92b1-02b49e56d1dd', 'fe89150b-4b21-4e31-93d5-878217afee70', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('278fd68b-2962-4b30-92b1-02b49e56d1dd', '0f8924a7-5f2e-423a-b78d-3566c58d21ba', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('278fd68b-2962-4b30-92b1-02b49e56d1dd', 'a1a8cef8-0f95-4d39-a527-4cc352e51525', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('278fd68b-2962-4b30-92b1-02b49e56d1dd', '67838f5f-9595-4867-b0fc-8b18b16045be', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe89150b-4b21-4e31-93d5-878217afee70', '17fb0c9f-dd60-419a-9f43-b5cf181e0605', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe89150b-4b21-4e31-93d5-878217afee70', '278fd68b-2962-4b30-92b1-02b49e56d1dd', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe89150b-4b21-4e31-93d5-878217afee70', '0f8924a7-5f2e-423a-b78d-3566c58d21ba', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe89150b-4b21-4e31-93d5-878217afee70', 'a1a8cef8-0f95-4d39-a527-4cc352e51525', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe89150b-4b21-4e31-93d5-878217afee70', '67838f5f-9595-4867-b0fc-8b18b16045be', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('67838f5f-9595-4867-b0fc-8b18b16045be', '17fb0c9f-dd60-419a-9f43-b5cf181e0605', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('67838f5f-9595-4867-b0fc-8b18b16045be', '278fd68b-2962-4b30-92b1-02b49e56d1dd', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('67838f5f-9595-4867-b0fc-8b18b16045be', 'fe89150b-4b21-4e31-93d5-878217afee70', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('67838f5f-9595-4867-b0fc-8b18b16045be', '0f8924a7-5f2e-423a-b78d-3566c58d21ba', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('67838f5f-9595-4867-b0fc-8b18b16045be', 'a1a8cef8-0f95-4d39-a527-4cc352e51525', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0f8924a7-5f2e-423a-b78d-3566c58d21ba', '17fb0c9f-dd60-419a-9f43-b5cf181e0605', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0f8924a7-5f2e-423a-b78d-3566c58d21ba', '278fd68b-2962-4b30-92b1-02b49e56d1dd', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0f8924a7-5f2e-423a-b78d-3566c58d21ba', 'fe89150b-4b21-4e31-93d5-878217afee70', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0f8924a7-5f2e-423a-b78d-3566c58d21ba', 'a1a8cef8-0f95-4d39-a527-4cc352e51525', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0f8924a7-5f2e-423a-b78d-3566c58d21ba', '67838f5f-9595-4867-b0fc-8b18b16045be', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a1a8cef8-0f95-4d39-a527-4cc352e51525', '17fb0c9f-dd60-419a-9f43-b5cf181e0605', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a1a8cef8-0f95-4d39-a527-4cc352e51525', '278fd68b-2962-4b30-92b1-02b49e56d1dd', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a1a8cef8-0f95-4d39-a527-4cc352e51525', 'fe89150b-4b21-4e31-93d5-878217afee70', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a1a8cef8-0f95-4d39-a527-4cc352e51525', '0f8924a7-5f2e-423a-b78d-3566c58d21ba', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a1a8cef8-0f95-4d39-a527-4cc352e51525', '67838f5f-9595-4867-b0fc-8b18b16045be', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('17039fbc-327a-4528-b5f7-d65ca29f6c45', 'd6262429-012e-446f-940a-c536000c22ae', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('17039fbc-327a-4528-b5f7-d65ca29f6c45', '2e96c8bd-869f-4cf5-8d93-cb3c53f978fd', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('17039fbc-327a-4528-b5f7-d65ca29f6c45', 'c3e53b68-e19f-45fe-a508-8093d8528c5f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('17039fbc-327a-4528-b5f7-d65ca29f6c45', 'd21dec43-2173-47df-acfa-b8f8bbe8a9cf', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('17039fbc-327a-4528-b5f7-d65ca29f6c45', 'e680b389-9b6a-4ec9-bf76-1a8f4fe9f82b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d97fb29b-e445-42d9-9586-9ab47575eaa6', '740745cf-0902-4667-97a1-c585c4178578', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d97fb29b-e445-42d9-9586-9ab47575eaa6', '43a0b6dd-50ee-4bb8-bbc6-71f5fec267f2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d97fb29b-e445-42d9-9586-9ab47575eaa6', 'c057dee3-1048-4b03-9c69-b02f8a417c23', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d97fb29b-e445-42d9-9586-9ab47575eaa6', '5a6c9231-42c7-4ddd-b705-e2cb1e097b92', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d97fb29b-e445-42d9-9586-9ab47575eaa6', 'cf9cf7e5-c062-4e51-be95-36ed8cf7288c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e728ff26-5a3a-4525-bda2-aeae37e93d59', '07e351dc-4712-4056-ba9a-8a5e7bfcd431', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e728ff26-5a3a-4525-bda2-aeae37e93d59', '06f07963-f2fe-4d3a-9539-99d7651dbb47', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e728ff26-5a3a-4525-bda2-aeae37e93d59', '957520a2-7ff3-4c58-84fe-bcb661219c98', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('07e351dc-4712-4056-ba9a-8a5e7bfcd431', 'e728ff26-5a3a-4525-bda2-aeae37e93d59', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('07e351dc-4712-4056-ba9a-8a5e7bfcd431', '06f07963-f2fe-4d3a-9539-99d7651dbb47', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('07e351dc-4712-4056-ba9a-8a5e7bfcd431', '957520a2-7ff3-4c58-84fe-bcb661219c98', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('06f07963-f2fe-4d3a-9539-99d7651dbb47', 'e728ff26-5a3a-4525-bda2-aeae37e93d59', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('06f07963-f2fe-4d3a-9539-99d7651dbb47', '07e351dc-4712-4056-ba9a-8a5e7bfcd431', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('06f07963-f2fe-4d3a-9539-99d7651dbb47', '957520a2-7ff3-4c58-84fe-bcb661219c98', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('957520a2-7ff3-4c58-84fe-bcb661219c98', 'e728ff26-5a3a-4525-bda2-aeae37e93d59', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('957520a2-7ff3-4c58-84fe-bcb661219c98', '07e351dc-4712-4056-ba9a-8a5e7bfcd431', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('957520a2-7ff3-4c58-84fe-bcb661219c98', '06f07963-f2fe-4d3a-9539-99d7651dbb47', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('802bf807-fe22-4856-8782-1545673dc0c4', '5d8bc35d-0eab-4182-b641-e4b53ef94fc7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('802bf807-fe22-4856-8782-1545673dc0c4', '47a3a849-e23c-43de-815d-5097fc807c85', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('802bf807-fe22-4856-8782-1545673dc0c4', '4e7b92bc-0fc6-4290-9741-112bc2fa1a13', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('802bf807-fe22-4856-8782-1545673dc0c4', '00d32c3c-33b9-4d5c-bb25-15ba55c4f109', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('802bf807-fe22-4856-8782-1545673dc0c4', '78269001-0f21-480e-a6d2-a6fe6f688b17', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1c40d006-2c7b-4c03-ab54-334d9db3a4a9', 'a392bf3b-3edb-4507-abc9-b6a10552bbd2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1c40d006-2c7b-4c03-ab54-334d9db3a4a9', 'c5298e5b-9889-4d6c-a611-471ded9aa89f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1c40d006-2c7b-4c03-ab54-334d9db3a4a9', '7fc4c740-f4c9-4d5f-b6a1-f24132ef85ef', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1c40d006-2c7b-4c03-ab54-334d9db3a4a9', '89e44d85-4d83-41e1-9813-96c1b66c9c5c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1c40d006-2c7b-4c03-ab54-334d9db3a4a9', '69c18108-c7d7-4409-836d-fdf84299ca0e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5d8bc35d-0eab-4182-b641-e4b53ef94fc7', '802bf807-fe22-4856-8782-1545673dc0c4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5d8bc35d-0eab-4182-b641-e4b53ef94fc7', '47a3a849-e23c-43de-815d-5097fc807c85', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5d8bc35d-0eab-4182-b641-e4b53ef94fc7', '4e7b92bc-0fc6-4290-9741-112bc2fa1a13', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5d8bc35d-0eab-4182-b641-e4b53ef94fc7', '00d32c3c-33b9-4d5c-bb25-15ba55c4f109', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5d8bc35d-0eab-4182-b641-e4b53ef94fc7', '78269001-0f21-480e-a6d2-a6fe6f688b17', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89e44d85-4d83-41e1-9813-96c1b66c9c5c', '1c40d006-2c7b-4c03-ab54-334d9db3a4a9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89e44d85-4d83-41e1-9813-96c1b66c9c5c', 'a392bf3b-3edb-4507-abc9-b6a10552bbd2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89e44d85-4d83-41e1-9813-96c1b66c9c5c', 'c5298e5b-9889-4d6c-a611-471ded9aa89f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89e44d85-4d83-41e1-9813-96c1b66c9c5c', '7fc4c740-f4c9-4d5f-b6a1-f24132ef85ef', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89e44d85-4d83-41e1-9813-96c1b66c9c5c', '69c18108-c7d7-4409-836d-fdf84299ca0e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0af7ce9e-dd17-4487-9608-c7903f661ba4', 'e728ff26-5a3a-4525-bda2-aeae37e93d59', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0af7ce9e-dd17-4487-9608-c7903f661ba4', '07e351dc-4712-4056-ba9a-8a5e7bfcd431', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0af7ce9e-dd17-4487-9608-c7903f661ba4', '06f07963-f2fe-4d3a-9539-99d7651dbb47', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0af7ce9e-dd17-4487-9608-c7903f661ba4', '957520a2-7ff3-4c58-84fe-bcb661219c98', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4e7b92bc-0fc6-4290-9741-112bc2fa1a13', '00d32c3c-33b9-4d5c-bb25-15ba55c4f109', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4e7b92bc-0fc6-4290-9741-112bc2fa1a13', '78269001-0f21-480e-a6d2-a6fe6f688b17', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4e7b92bc-0fc6-4290-9741-112bc2fa1a13', '090d298e-0479-4098-845d-c876651a4a5b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4e7b92bc-0fc6-4290-9741-112bc2fa1a13', 'bd5b5d26-5dd2-484c-8ebf-373ee9bda9c8', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4e7b92bc-0fc6-4290-9741-112bc2fa1a13', '802bf807-fe22-4856-8782-1545673dc0c4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('00d32c3c-33b9-4d5c-bb25-15ba55c4f109', '4e7b92bc-0fc6-4290-9741-112bc2fa1a13', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('00d32c3c-33b9-4d5c-bb25-15ba55c4f109', '78269001-0f21-480e-a6d2-a6fe6f688b17', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('00d32c3c-33b9-4d5c-bb25-15ba55c4f109', '090d298e-0479-4098-845d-c876651a4a5b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('00d32c3c-33b9-4d5c-bb25-15ba55c4f109', 'bd5b5d26-5dd2-484c-8ebf-373ee9bda9c8', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('00d32c3c-33b9-4d5c-bb25-15ba55c4f109', '802bf807-fe22-4856-8782-1545673dc0c4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('78269001-0f21-480e-a6d2-a6fe6f688b17', '4e7b92bc-0fc6-4290-9741-112bc2fa1a13', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('78269001-0f21-480e-a6d2-a6fe6f688b17', '00d32c3c-33b9-4d5c-bb25-15ba55c4f109', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('78269001-0f21-480e-a6d2-a6fe6f688b17', '090d298e-0479-4098-845d-c876651a4a5b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('78269001-0f21-480e-a6d2-a6fe6f688b17', 'bd5b5d26-5dd2-484c-8ebf-373ee9bda9c8', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('78269001-0f21-480e-a6d2-a6fe6f688b17', '802bf807-fe22-4856-8782-1545673dc0c4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('090d298e-0479-4098-845d-c876651a4a5b', '4e7b92bc-0fc6-4290-9741-112bc2fa1a13', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('090d298e-0479-4098-845d-c876651a4a5b', '00d32c3c-33b9-4d5c-bb25-15ba55c4f109', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('090d298e-0479-4098-845d-c876651a4a5b', '78269001-0f21-480e-a6d2-a6fe6f688b17', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('090d298e-0479-4098-845d-c876651a4a5b', 'bd5b5d26-5dd2-484c-8ebf-373ee9bda9c8', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('090d298e-0479-4098-845d-c876651a4a5b', '802bf807-fe22-4856-8782-1545673dc0c4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9232e4b2-8747-4907-be1f-4edb4d0770ee', '802bf807-fe22-4856-8782-1545673dc0c4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9232e4b2-8747-4907-be1f-4edb4d0770ee', '5d8bc35d-0eab-4182-b641-e4b53ef94fc7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9232e4b2-8747-4907-be1f-4edb4d0770ee', '4e7b92bc-0fc6-4290-9741-112bc2fa1a13', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9232e4b2-8747-4907-be1f-4edb4d0770ee', '00d32c3c-33b9-4d5c-bb25-15ba55c4f109', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9232e4b2-8747-4907-be1f-4edb4d0770ee', '78269001-0f21-480e-a6d2-a6fe6f688b17', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bd5b5d26-5dd2-484c-8ebf-373ee9bda9c8', '4e7b92bc-0fc6-4290-9741-112bc2fa1a13', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bd5b5d26-5dd2-484c-8ebf-373ee9bda9c8', '00d32c3c-33b9-4d5c-bb25-15ba55c4f109', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bd5b5d26-5dd2-484c-8ebf-373ee9bda9c8', '78269001-0f21-480e-a6d2-a6fe6f688b17', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bd5b5d26-5dd2-484c-8ebf-373ee9bda9c8', '090d298e-0479-4098-845d-c876651a4a5b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bd5b5d26-5dd2-484c-8ebf-373ee9bda9c8', '802bf807-fe22-4856-8782-1545673dc0c4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('47a3a849-e23c-43de-815d-5097fc807c85', '802bf807-fe22-4856-8782-1545673dc0c4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('47a3a849-e23c-43de-815d-5097fc807c85', '5d8bc35d-0eab-4182-b641-e4b53ef94fc7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('47a3a849-e23c-43de-815d-5097fc807c85', '4e7b92bc-0fc6-4290-9741-112bc2fa1a13', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('47a3a849-e23c-43de-815d-5097fc807c85', '00d32c3c-33b9-4d5c-bb25-15ba55c4f109', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('47a3a849-e23c-43de-815d-5097fc807c85', '78269001-0f21-480e-a6d2-a6fe6f688b17', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('32ce292e-4fe1-4c9a-bb16-208fd0a0754f', 'e728ff26-5a3a-4525-bda2-aeae37e93d59', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('32ce292e-4fe1-4c9a-bb16-208fd0a0754f', '07e351dc-4712-4056-ba9a-8a5e7bfcd431', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('32ce292e-4fe1-4c9a-bb16-208fd0a0754f', '06f07963-f2fe-4d3a-9539-99d7651dbb47', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('32ce292e-4fe1-4c9a-bb16-208fd0a0754f', '957520a2-7ff3-4c58-84fe-bcb661219c98', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4758af80-7890-4cee-8634-02c9baf7fa7b', '7d9c7fe0-7619-4329-bd5f-9b685c2c5d1a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4758af80-7890-4cee-8634-02c9baf7fa7b', 'b4b2d04d-457c-4bb5-8774-114c3190cda4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4758af80-7890-4cee-8634-02c9baf7fa7b', 'e3a29645-e1ea-488d-9a4b-9756471ae16a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4758af80-7890-4cee-8634-02c9baf7fa7b', 'ea80faf4-0e7f-4068-b184-8686b12b890c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4758af80-7890-4cee-8634-02c9baf7fa7b', '84d44831-39c2-40ae-bc51-e74329c01e25', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d2e71fb8-475d-41d7-ba49-3840029c1330', '7d9c7fe0-7619-4329-bd5f-9b685c2c5d1a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d2e71fb8-475d-41d7-ba49-3840029c1330', 'b4b2d04d-457c-4bb5-8774-114c3190cda4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d2e71fb8-475d-41d7-ba49-3840029c1330', 'e3a29645-e1ea-488d-9a4b-9756471ae16a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d2e71fb8-475d-41d7-ba49-3840029c1330', 'ea80faf4-0e7f-4068-b184-8686b12b890c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d2e71fb8-475d-41d7-ba49-3840029c1330', '84d44831-39c2-40ae-bc51-e74329c01e25', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7d9c7fe0-7619-4329-bd5f-9b685c2c5d1a', 'b4b2d04d-457c-4bb5-8774-114c3190cda4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7d9c7fe0-7619-4329-bd5f-9b685c2c5d1a', 'e3a29645-e1ea-488d-9a4b-9756471ae16a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7d9c7fe0-7619-4329-bd5f-9b685c2c5d1a', 'ea80faf4-0e7f-4068-b184-8686b12b890c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7d9c7fe0-7619-4329-bd5f-9b685c2c5d1a', '84d44831-39c2-40ae-bc51-e74329c01e25', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7d9c7fe0-7619-4329-bd5f-9b685c2c5d1a', '1db94037-7f51-4fd1-8d46-424eaaf68ec2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b4b2d04d-457c-4bb5-8774-114c3190cda4', '7d9c7fe0-7619-4329-bd5f-9b685c2c5d1a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b4b2d04d-457c-4bb5-8774-114c3190cda4', 'e3a29645-e1ea-488d-9a4b-9756471ae16a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b4b2d04d-457c-4bb5-8774-114c3190cda4', 'ea80faf4-0e7f-4068-b184-8686b12b890c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b4b2d04d-457c-4bb5-8774-114c3190cda4', '84d44831-39c2-40ae-bc51-e74329c01e25', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b4b2d04d-457c-4bb5-8774-114c3190cda4', '1db94037-7f51-4fd1-8d46-424eaaf68ec2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3a29645-e1ea-488d-9a4b-9756471ae16a', '7d9c7fe0-7619-4329-bd5f-9b685c2c5d1a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3a29645-e1ea-488d-9a4b-9756471ae16a', 'b4b2d04d-457c-4bb5-8774-114c3190cda4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3a29645-e1ea-488d-9a4b-9756471ae16a', 'ea80faf4-0e7f-4068-b184-8686b12b890c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3a29645-e1ea-488d-9a4b-9756471ae16a', '84d44831-39c2-40ae-bc51-e74329c01e25', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3a29645-e1ea-488d-9a4b-9756471ae16a', '1db94037-7f51-4fd1-8d46-424eaaf68ec2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ea80faf4-0e7f-4068-b184-8686b12b890c', '7d9c7fe0-7619-4329-bd5f-9b685c2c5d1a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ea80faf4-0e7f-4068-b184-8686b12b890c', 'b4b2d04d-457c-4bb5-8774-114c3190cda4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ea80faf4-0e7f-4068-b184-8686b12b890c', 'e3a29645-e1ea-488d-9a4b-9756471ae16a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ea80faf4-0e7f-4068-b184-8686b12b890c', '84d44831-39c2-40ae-bc51-e74329c01e25', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ea80faf4-0e7f-4068-b184-8686b12b890c', '1db94037-7f51-4fd1-8d46-424eaaf68ec2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84d44831-39c2-40ae-bc51-e74329c01e25', '7d9c7fe0-7619-4329-bd5f-9b685c2c5d1a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84d44831-39c2-40ae-bc51-e74329c01e25', 'b4b2d04d-457c-4bb5-8774-114c3190cda4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84d44831-39c2-40ae-bc51-e74329c01e25', 'e3a29645-e1ea-488d-9a4b-9756471ae16a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84d44831-39c2-40ae-bc51-e74329c01e25', 'ea80faf4-0e7f-4068-b184-8686b12b890c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84d44831-39c2-40ae-bc51-e74329c01e25', '1db94037-7f51-4fd1-8d46-424eaaf68ec2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1db94037-7f51-4fd1-8d46-424eaaf68ec2', '7d9c7fe0-7619-4329-bd5f-9b685c2c5d1a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1db94037-7f51-4fd1-8d46-424eaaf68ec2', 'b4b2d04d-457c-4bb5-8774-114c3190cda4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1db94037-7f51-4fd1-8d46-424eaaf68ec2', 'e3a29645-e1ea-488d-9a4b-9756471ae16a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1db94037-7f51-4fd1-8d46-424eaaf68ec2', 'ea80faf4-0e7f-4068-b184-8686b12b890c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1db94037-7f51-4fd1-8d46-424eaaf68ec2', '84d44831-39c2-40ae-bc51-e74329c01e25', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ca4cede5-9a8d-41cf-9c59-f1f8fdb565ef', '7d9c7fe0-7619-4329-bd5f-9b685c2c5d1a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ca4cede5-9a8d-41cf-9c59-f1f8fdb565ef', 'b4b2d04d-457c-4bb5-8774-114c3190cda4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ca4cede5-9a8d-41cf-9c59-f1f8fdb565ef', 'e3a29645-e1ea-488d-9a4b-9756471ae16a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ca4cede5-9a8d-41cf-9c59-f1f8fdb565ef', 'ea80faf4-0e7f-4068-b184-8686b12b890c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ca4cede5-9a8d-41cf-9c59-f1f8fdb565ef', '84d44831-39c2-40ae-bc51-e74329c01e25', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9c9a80e6-c3dc-49ab-a51b-c5dfb12e5e08', 'b860e705-3286-4378-bb10-1b202a0c3a54', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9c9a80e6-c3dc-49ab-a51b-c5dfb12e5e08', 'a8b42f17-b769-495e-88e2-8a16c71f848f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9c9a80e6-c3dc-49ab-a51b-c5dfb12e5e08', 'b274331b-4735-4cb0-bfeb-e7854c3b9aca', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9c9a80e6-c3dc-49ab-a51b-c5dfb12e5e08', 'd3d6c598-671a-48d7-80eb-e45e38d3f6e4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9c9a80e6-c3dc-49ab-a51b-c5dfb12e5e08', '32c4b10a-8036-49bd-ac94-c28c75bbf5e3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b860e705-3286-4378-bb10-1b202a0c3a54', '9c9a80e6-c3dc-49ab-a51b-c5dfb12e5e08', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b860e705-3286-4378-bb10-1b202a0c3a54', 'a8b42f17-b769-495e-88e2-8a16c71f848f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b860e705-3286-4378-bb10-1b202a0c3a54', 'b274331b-4735-4cb0-bfeb-e7854c3b9aca', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b860e705-3286-4378-bb10-1b202a0c3a54', 'd3d6c598-671a-48d7-80eb-e45e38d3f6e4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b860e705-3286-4378-bb10-1b202a0c3a54', '32c4b10a-8036-49bd-ac94-c28c75bbf5e3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a8b42f17-b769-495e-88e2-8a16c71f848f', '9c9a80e6-c3dc-49ab-a51b-c5dfb12e5e08', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a8b42f17-b769-495e-88e2-8a16c71f848f', 'b860e705-3286-4378-bb10-1b202a0c3a54', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a8b42f17-b769-495e-88e2-8a16c71f848f', 'b274331b-4735-4cb0-bfeb-e7854c3b9aca', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a8b42f17-b769-495e-88e2-8a16c71f848f', 'd3d6c598-671a-48d7-80eb-e45e38d3f6e4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a8b42f17-b769-495e-88e2-8a16c71f848f', '32c4b10a-8036-49bd-ac94-c28c75bbf5e3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b274331b-4735-4cb0-bfeb-e7854c3b9aca', '9c9a80e6-c3dc-49ab-a51b-c5dfb12e5e08', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b274331b-4735-4cb0-bfeb-e7854c3b9aca', 'b860e705-3286-4378-bb10-1b202a0c3a54', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b274331b-4735-4cb0-bfeb-e7854c3b9aca', 'a8b42f17-b769-495e-88e2-8a16c71f848f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b274331b-4735-4cb0-bfeb-e7854c3b9aca', 'd3d6c598-671a-48d7-80eb-e45e38d3f6e4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b274331b-4735-4cb0-bfeb-e7854c3b9aca', '32c4b10a-8036-49bd-ac94-c28c75bbf5e3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3d6c598-671a-48d7-80eb-e45e38d3f6e4', '9c9a80e6-c3dc-49ab-a51b-c5dfb12e5e08', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3d6c598-671a-48d7-80eb-e45e38d3f6e4', 'b860e705-3286-4378-bb10-1b202a0c3a54', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3d6c598-671a-48d7-80eb-e45e38d3f6e4', 'a8b42f17-b769-495e-88e2-8a16c71f848f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3d6c598-671a-48d7-80eb-e45e38d3f6e4', 'b274331b-4735-4cb0-bfeb-e7854c3b9aca', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d3d6c598-671a-48d7-80eb-e45e38d3f6e4', '32c4b10a-8036-49bd-ac94-c28c75bbf5e3', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('32c4b10a-8036-49bd-ac94-c28c75bbf5e3', '9c9a80e6-c3dc-49ab-a51b-c5dfb12e5e08', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('32c4b10a-8036-49bd-ac94-c28c75bbf5e3', 'b860e705-3286-4378-bb10-1b202a0c3a54', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('32c4b10a-8036-49bd-ac94-c28c75bbf5e3', 'a8b42f17-b769-495e-88e2-8a16c71f848f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('32c4b10a-8036-49bd-ac94-c28c75bbf5e3', 'b274331b-4735-4cb0-bfeb-e7854c3b9aca', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('32c4b10a-8036-49bd-ac94-c28c75bbf5e3', 'd3d6c598-671a-48d7-80eb-e45e38d3f6e4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('096a3f33-478f-4b26-b126-00be0eaacb75', '9c9a80e6-c3dc-49ab-a51b-c5dfb12e5e08', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('096a3f33-478f-4b26-b126-00be0eaacb75', 'b860e705-3286-4378-bb10-1b202a0c3a54', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('096a3f33-478f-4b26-b126-00be0eaacb75', 'a8b42f17-b769-495e-88e2-8a16c71f848f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('096a3f33-478f-4b26-b126-00be0eaacb75', 'b274331b-4735-4cb0-bfeb-e7854c3b9aca', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('096a3f33-478f-4b26-b126-00be0eaacb75', 'd3d6c598-671a-48d7-80eb-e45e38d3f6e4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d29225ac-5d4a-47f7-86d2-ba9e5f07cdf8', '9c9a80e6-c3dc-49ab-a51b-c5dfb12e5e08', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d29225ac-5d4a-47f7-86d2-ba9e5f07cdf8', 'b860e705-3286-4378-bb10-1b202a0c3a54', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d29225ac-5d4a-47f7-86d2-ba9e5f07cdf8', 'a8b42f17-b769-495e-88e2-8a16c71f848f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d29225ac-5d4a-47f7-86d2-ba9e5f07cdf8', 'b274331b-4735-4cb0-bfeb-e7854c3b9aca', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d29225ac-5d4a-47f7-86d2-ba9e5f07cdf8', 'd3d6c598-671a-48d7-80eb-e45e38d3f6e4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce64bdf2-38df-43a6-a878-d13e6cd4d8e0', '2fc652e1-8c66-461c-8b42-842269481267', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce64bdf2-38df-43a6-a878-d13e6cd4d8e0', '9c9a80e6-c3dc-49ab-a51b-c5dfb12e5e08', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce64bdf2-38df-43a6-a878-d13e6cd4d8e0', 'b860e705-3286-4378-bb10-1b202a0c3a54', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce64bdf2-38df-43a6-a878-d13e6cd4d8e0', 'a8b42f17-b769-495e-88e2-8a16c71f848f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce64bdf2-38df-43a6-a878-d13e6cd4d8e0', 'b274331b-4735-4cb0-bfeb-e7854c3b9aca', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c1ba64a-9930-4e37-bbd3-5a8ef3d10039', '7d9c7fe0-7619-4329-bd5f-9b685c2c5d1a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c1ba64a-9930-4e37-bbd3-5a8ef3d10039', 'b4b2d04d-457c-4bb5-8774-114c3190cda4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c1ba64a-9930-4e37-bbd3-5a8ef3d10039', 'e3a29645-e1ea-488d-9a4b-9756471ae16a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c1ba64a-9930-4e37-bbd3-5a8ef3d10039', 'ea80faf4-0e7f-4068-b184-8686b12b890c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c1ba64a-9930-4e37-bbd3-5a8ef3d10039', '84d44831-39c2-40ae-bc51-e74329c01e25', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2fc652e1-8c66-461c-8b42-842269481267', 'ce64bdf2-38df-43a6-a878-d13e6cd4d8e0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2fc652e1-8c66-461c-8b42-842269481267', '9c9a80e6-c3dc-49ab-a51b-c5dfb12e5e08', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2fc652e1-8c66-461c-8b42-842269481267', 'b860e705-3286-4378-bb10-1b202a0c3a54', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2fc652e1-8c66-461c-8b42-842269481267', 'a8b42f17-b769-495e-88e2-8a16c71f848f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2fc652e1-8c66-461c-8b42-842269481267', 'b274331b-4735-4cb0-bfeb-e7854c3b9aca', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b388fb78-88d2-44fa-9061-f0729d04b311', '256bdf68-fafd-45bc-b334-c64f36611efa', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b388fb78-88d2-44fa-9061-f0729d04b311', '7a356a65-8b52-4a28-ab30-7f2e20f1b105', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b388fb78-88d2-44fa-9061-f0729d04b311', '7a14c108-37c2-4361-8211-151a8fbebd5f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b388fb78-88d2-44fa-9061-f0729d04b311', 'b0ac0fdd-19b4-4d88-a226-26125e0adc27', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b388fb78-88d2-44fa-9061-f0729d04b311', '33055d31-372a-4193-921a-b4019be0474b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('256bdf68-fafd-45bc-b334-c64f36611efa', 'b388fb78-88d2-44fa-9061-f0729d04b311', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('256bdf68-fafd-45bc-b334-c64f36611efa', '7a356a65-8b52-4a28-ab30-7f2e20f1b105', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('256bdf68-fafd-45bc-b334-c64f36611efa', '7a14c108-37c2-4361-8211-151a8fbebd5f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('256bdf68-fafd-45bc-b334-c64f36611efa', 'b0ac0fdd-19b4-4d88-a226-26125e0adc27', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('256bdf68-fafd-45bc-b334-c64f36611efa', '33055d31-372a-4193-921a-b4019be0474b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a356a65-8b52-4a28-ab30-7f2e20f1b105', 'b388fb78-88d2-44fa-9061-f0729d04b311', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a356a65-8b52-4a28-ab30-7f2e20f1b105', '256bdf68-fafd-45bc-b334-c64f36611efa', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a356a65-8b52-4a28-ab30-7f2e20f1b105', '7a14c108-37c2-4361-8211-151a8fbebd5f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a356a65-8b52-4a28-ab30-7f2e20f1b105', 'b0ac0fdd-19b4-4d88-a226-26125e0adc27', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a356a65-8b52-4a28-ab30-7f2e20f1b105', '33055d31-372a-4193-921a-b4019be0474b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a14c108-37c2-4361-8211-151a8fbebd5f', 'b388fb78-88d2-44fa-9061-f0729d04b311', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a14c108-37c2-4361-8211-151a8fbebd5f', '256bdf68-fafd-45bc-b334-c64f36611efa', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a14c108-37c2-4361-8211-151a8fbebd5f', '7a356a65-8b52-4a28-ab30-7f2e20f1b105', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a14c108-37c2-4361-8211-151a8fbebd5f', 'b0ac0fdd-19b4-4d88-a226-26125e0adc27', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a14c108-37c2-4361-8211-151a8fbebd5f', '33055d31-372a-4193-921a-b4019be0474b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b0ac0fdd-19b4-4d88-a226-26125e0adc27', 'b388fb78-88d2-44fa-9061-f0729d04b311', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b0ac0fdd-19b4-4d88-a226-26125e0adc27', '256bdf68-fafd-45bc-b334-c64f36611efa', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b0ac0fdd-19b4-4d88-a226-26125e0adc27', '7a356a65-8b52-4a28-ab30-7f2e20f1b105', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b0ac0fdd-19b4-4d88-a226-26125e0adc27', '7a14c108-37c2-4361-8211-151a8fbebd5f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b0ac0fdd-19b4-4d88-a226-26125e0adc27', '33055d31-372a-4193-921a-b4019be0474b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('013c5b46-5ab2-4661-8357-c1c94851ef04', 'b388fb78-88d2-44fa-9061-f0729d04b311', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('013c5b46-5ab2-4661-8357-c1c94851ef04', '256bdf68-fafd-45bc-b334-c64f36611efa', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('013c5b46-5ab2-4661-8357-c1c94851ef04', '7a356a65-8b52-4a28-ab30-7f2e20f1b105', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('013c5b46-5ab2-4661-8357-c1c94851ef04', '7a14c108-37c2-4361-8211-151a8fbebd5f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('013c5b46-5ab2-4661-8357-c1c94851ef04', 'b0ac0fdd-19b4-4d88-a226-26125e0adc27', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('33055d31-372a-4193-921a-b4019be0474b', 'b388fb78-88d2-44fa-9061-f0729d04b311', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('33055d31-372a-4193-921a-b4019be0474b', '256bdf68-fafd-45bc-b334-c64f36611efa', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('33055d31-372a-4193-921a-b4019be0474b', '7a356a65-8b52-4a28-ab30-7f2e20f1b105', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('33055d31-372a-4193-921a-b4019be0474b', '7a14c108-37c2-4361-8211-151a8fbebd5f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('33055d31-372a-4193-921a-b4019be0474b', 'b0ac0fdd-19b4-4d88-a226-26125e0adc27', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a91d5560-90f2-4e70-8214-ffc724bc6a3b', 'b388fb78-88d2-44fa-9061-f0729d04b311', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a91d5560-90f2-4e70-8214-ffc724bc6a3b', '256bdf68-fafd-45bc-b334-c64f36611efa', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a91d5560-90f2-4e70-8214-ffc724bc6a3b', '7a356a65-8b52-4a28-ab30-7f2e20f1b105', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a91d5560-90f2-4e70-8214-ffc724bc6a3b', '7a14c108-37c2-4361-8211-151a8fbebd5f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a91d5560-90f2-4e70-8214-ffc724bc6a3b', 'b0ac0fdd-19b4-4d88-a226-26125e0adc27', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f3f4858-a859-4c6b-b4af-d738ee052aaa', 'b388fb78-88d2-44fa-9061-f0729d04b311', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f3f4858-a859-4c6b-b4af-d738ee052aaa', '256bdf68-fafd-45bc-b334-c64f36611efa', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f3f4858-a859-4c6b-b4af-d738ee052aaa', '7a356a65-8b52-4a28-ab30-7f2e20f1b105', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f3f4858-a859-4c6b-b4af-d738ee052aaa', '7a14c108-37c2-4361-8211-151a8fbebd5f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f3f4858-a859-4c6b-b4af-d738ee052aaa', 'b0ac0fdd-19b4-4d88-a226-26125e0adc27', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c62e792d-d8c5-4bdc-a286-478d3020377a', '49d9cb83-bb38-4c7a-be73-02537427d1df', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c62e792d-d8c5-4bdc-a286-478d3020377a', '37a941a5-1e00-4c6f-9cd7-ed6d5beff623', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c62e792d-d8c5-4bdc-a286-478d3020377a', 'b388fb78-88d2-44fa-9061-f0729d04b311', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c62e792d-d8c5-4bdc-a286-478d3020377a', '256bdf68-fafd-45bc-b334-c64f36611efa', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c62e792d-d8c5-4bdc-a286-478d3020377a', '7a356a65-8b52-4a28-ab30-7f2e20f1b105', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('49d9cb83-bb38-4c7a-be73-02537427d1df', 'c62e792d-d8c5-4bdc-a286-478d3020377a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('49d9cb83-bb38-4c7a-be73-02537427d1df', '37a941a5-1e00-4c6f-9cd7-ed6d5beff623', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('49d9cb83-bb38-4c7a-be73-02537427d1df', 'b388fb78-88d2-44fa-9061-f0729d04b311', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('49d9cb83-bb38-4c7a-be73-02537427d1df', '256bdf68-fafd-45bc-b334-c64f36611efa', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('49d9cb83-bb38-4c7a-be73-02537427d1df', '7a356a65-8b52-4a28-ab30-7f2e20f1b105', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('37a941a5-1e00-4c6f-9cd7-ed6d5beff623', 'c62e792d-d8c5-4bdc-a286-478d3020377a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('37a941a5-1e00-4c6f-9cd7-ed6d5beff623', '49d9cb83-bb38-4c7a-be73-02537427d1df', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('37a941a5-1e00-4c6f-9cd7-ed6d5beff623', 'b388fb78-88d2-44fa-9061-f0729d04b311', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('37a941a5-1e00-4c6f-9cd7-ed6d5beff623', '256bdf68-fafd-45bc-b334-c64f36611efa', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('37a941a5-1e00-4c6f-9cd7-ed6d5beff623', '7a356a65-8b52-4a28-ab30-7f2e20f1b105', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6944ff43-0b0f-471d-9c1f-b9a435674c29', 'b388fb78-88d2-44fa-9061-f0729d04b311', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6944ff43-0b0f-471d-9c1f-b9a435674c29', '256bdf68-fafd-45bc-b334-c64f36611efa', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6944ff43-0b0f-471d-9c1f-b9a435674c29', '7a356a65-8b52-4a28-ab30-7f2e20f1b105', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6944ff43-0b0f-471d-9c1f-b9a435674c29', '7a14c108-37c2-4361-8211-151a8fbebd5f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6944ff43-0b0f-471d-9c1f-b9a435674c29', 'b0ac0fdd-19b4-4d88-a226-26125e0adc27', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7ff62329-7562-4cef-b10a-c7b163d939f8', 'ec741050-4d08-4fa4-82f2-9ac77f35c3dc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7ff62329-7562-4cef-b10a-c7b163d939f8', 'b388fb78-88d2-44fa-9061-f0729d04b311', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7ff62329-7562-4cef-b10a-c7b163d939f8', '256bdf68-fafd-45bc-b334-c64f36611efa', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('08a84b76-c346-48f2-b365-c349efcaa175', 'b388fb78-88d2-44fa-9061-f0729d04b311', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('08a84b76-c346-48f2-b365-c349efcaa175', '256bdf68-fafd-45bc-b334-c64f36611efa', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('08a84b76-c346-48f2-b365-c349efcaa175', '7a356a65-8b52-4a28-ab30-7f2e20f1b105', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('08a84b76-c346-48f2-b365-c349efcaa175', '7a14c108-37c2-4361-8211-151a8fbebd5f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('08a84b76-c346-48f2-b365-c349efcaa175', 'b0ac0fdd-19b4-4d88-a226-26125e0adc27', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ec741050-4d08-4fa4-82f2-9ac77f35c3dc', '7ff62329-7562-4cef-b10a-c7b163d939f8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ec741050-4d08-4fa4-82f2-9ac77f35c3dc', 'b388fb78-88d2-44fa-9061-f0729d04b311', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ec741050-4d08-4fa4-82f2-9ac77f35c3dc', '256bdf68-fafd-45bc-b334-c64f36611efa', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('96945929-e857-4dfe-b505-043114ca97ab', 'b388fb78-88d2-44fa-9061-f0729d04b311', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('96945929-e857-4dfe-b505-043114ca97ab', '256bdf68-fafd-45bc-b334-c64f36611efa', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('96945929-e857-4dfe-b505-043114ca97ab', '7a356a65-8b52-4a28-ab30-7f2e20f1b105', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('96945929-e857-4dfe-b505-043114ca97ab', '7a14c108-37c2-4361-8211-151a8fbebd5f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('96945929-e857-4dfe-b505-043114ca97ab', 'b0ac0fdd-19b4-4d88-a226-26125e0adc27', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d8177ff6-bd28-4371-8def-32be04236d35', 'b388fb78-88d2-44fa-9061-f0729d04b311', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d8177ff6-bd28-4371-8def-32be04236d35', '256bdf68-fafd-45bc-b334-c64f36611efa', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d8177ff6-bd28-4371-8def-32be04236d35', '7a356a65-8b52-4a28-ab30-7f2e20f1b105', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d8177ff6-bd28-4371-8def-32be04236d35', '7a14c108-37c2-4361-8211-151a8fbebd5f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d8177ff6-bd28-4371-8def-32be04236d35', 'b0ac0fdd-19b4-4d88-a226-26125e0adc27', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f86eb1ae-972b-4429-8abd-80d8311e5509', '58064354-9d2a-4e72-b499-1c699759a3ea', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f86eb1ae-972b-4429-8abd-80d8311e5509', '5f3040f5-39b2-450c-bb80-a37b9c5d759f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f86eb1ae-972b-4429-8abd-80d8311e5509', 'f42e6330-0dde-4165-a1b7-d44543e9f6ef', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f86eb1ae-972b-4429-8abd-80d8311e5509', 'e3b9abe5-1c29-4c2c-9e4c-1c5ef7aa1910', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f86eb1ae-972b-4429-8abd-80d8311e5509', '17f8ea87-1501-4c72-86d2-0f16e9283aa4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('58064354-9d2a-4e72-b499-1c699759a3ea', 'f86eb1ae-972b-4429-8abd-80d8311e5509', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('58064354-9d2a-4e72-b499-1c699759a3ea', '5f3040f5-39b2-450c-bb80-a37b9c5d759f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('58064354-9d2a-4e72-b499-1c699759a3ea', 'f42e6330-0dde-4165-a1b7-d44543e9f6ef', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('58064354-9d2a-4e72-b499-1c699759a3ea', 'e3b9abe5-1c29-4c2c-9e4c-1c5ef7aa1910', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('58064354-9d2a-4e72-b499-1c699759a3ea', '17f8ea87-1501-4c72-86d2-0f16e9283aa4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5f3040f5-39b2-450c-bb80-a37b9c5d759f', 'f86eb1ae-972b-4429-8abd-80d8311e5509', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5f3040f5-39b2-450c-bb80-a37b9c5d759f', '58064354-9d2a-4e72-b499-1c699759a3ea', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5f3040f5-39b2-450c-bb80-a37b9c5d759f', 'f42e6330-0dde-4165-a1b7-d44543e9f6ef', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5f3040f5-39b2-450c-bb80-a37b9c5d759f', 'e3b9abe5-1c29-4c2c-9e4c-1c5ef7aa1910', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5f3040f5-39b2-450c-bb80-a37b9c5d759f', '17f8ea87-1501-4c72-86d2-0f16e9283aa4', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f42e6330-0dde-4165-a1b7-d44543e9f6ef', 'e3b9abe5-1c29-4c2c-9e4c-1c5ef7aa1910', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f42e6330-0dde-4165-a1b7-d44543e9f6ef', '17f8ea87-1501-4c72-86d2-0f16e9283aa4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f42e6330-0dde-4165-a1b7-d44543e9f6ef', 'd2af4a93-39eb-4c5f-91b7-d03a7d93c7e3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f42e6330-0dde-4165-a1b7-d44543e9f6ef', '9eaec49f-f949-4adc-a53c-9f182c248de9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f42e6330-0dde-4165-a1b7-d44543e9f6ef', '35ae948b-d31a-43b8-b86c-f425c067c81e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5b8e07fc-5ac1-42d7-8535-fef6dcfbb037', 'eeece670-d0b2-4b34-883b-4347673f1cbd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5b8e07fc-5ac1-42d7-8535-fef6dcfbb037', 'bbb9592a-9936-4213-bf01-97547446e847', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5b8e07fc-5ac1-42d7-8535-fef6dcfbb037', '654cf770-70f2-4c62-9a94-39e86dbc15e3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3b9abe5-1c29-4c2c-9e4c-1c5ef7aa1910', 'f42e6330-0dde-4165-a1b7-d44543e9f6ef', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3b9abe5-1c29-4c2c-9e4c-1c5ef7aa1910', '17f8ea87-1501-4c72-86d2-0f16e9283aa4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3b9abe5-1c29-4c2c-9e4c-1c5ef7aa1910', 'd2af4a93-39eb-4c5f-91b7-d03a7d93c7e3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3b9abe5-1c29-4c2c-9e4c-1c5ef7aa1910', '9eaec49f-f949-4adc-a53c-9f182c248de9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3b9abe5-1c29-4c2c-9e4c-1c5ef7aa1910', '35ae948b-d31a-43b8-b86c-f425c067c81e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('17f8ea87-1501-4c72-86d2-0f16e9283aa4', 'f42e6330-0dde-4165-a1b7-d44543e9f6ef', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('17f8ea87-1501-4c72-86d2-0f16e9283aa4', 'e3b9abe5-1c29-4c2c-9e4c-1c5ef7aa1910', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('17f8ea87-1501-4c72-86d2-0f16e9283aa4', 'd2af4a93-39eb-4c5f-91b7-d03a7d93c7e3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('17f8ea87-1501-4c72-86d2-0f16e9283aa4', '9eaec49f-f949-4adc-a53c-9f182c248de9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('17f8ea87-1501-4c72-86d2-0f16e9283aa4', '35ae948b-d31a-43b8-b86c-f425c067c81e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d2af4a93-39eb-4c5f-91b7-d03a7d93c7e3', 'f42e6330-0dde-4165-a1b7-d44543e9f6ef', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d2af4a93-39eb-4c5f-91b7-d03a7d93c7e3', 'e3b9abe5-1c29-4c2c-9e4c-1c5ef7aa1910', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d2af4a93-39eb-4c5f-91b7-d03a7d93c7e3', '17f8ea87-1501-4c72-86d2-0f16e9283aa4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d2af4a93-39eb-4c5f-91b7-d03a7d93c7e3', '9eaec49f-f949-4adc-a53c-9f182c248de9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d2af4a93-39eb-4c5f-91b7-d03a7d93c7e3', '35ae948b-d31a-43b8-b86c-f425c067c81e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9eaec49f-f949-4adc-a53c-9f182c248de9', 'f42e6330-0dde-4165-a1b7-d44543e9f6ef', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9eaec49f-f949-4adc-a53c-9f182c248de9', 'e3b9abe5-1c29-4c2c-9e4c-1c5ef7aa1910', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9eaec49f-f949-4adc-a53c-9f182c248de9', '17f8ea87-1501-4c72-86d2-0f16e9283aa4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9eaec49f-f949-4adc-a53c-9f182c248de9', 'd2af4a93-39eb-4c5f-91b7-d03a7d93c7e3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9eaec49f-f949-4adc-a53c-9f182c248de9', '35ae948b-d31a-43b8-b86c-f425c067c81e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('35ae948b-d31a-43b8-b86c-f425c067c81e', 'f42e6330-0dde-4165-a1b7-d44543e9f6ef', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('35ae948b-d31a-43b8-b86c-f425c067c81e', 'e3b9abe5-1c29-4c2c-9e4c-1c5ef7aa1910', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('35ae948b-d31a-43b8-b86c-f425c067c81e', '17f8ea87-1501-4c72-86d2-0f16e9283aa4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('35ae948b-d31a-43b8-b86c-f425c067c81e', 'd2af4a93-39eb-4c5f-91b7-d03a7d93c7e3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('35ae948b-d31a-43b8-b86c-f425c067c81e', '9eaec49f-f949-4adc-a53c-9f182c248de9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('103462c2-4bc7-4e57-9b92-1a85cc4b6478', 'f42e6330-0dde-4165-a1b7-d44543e9f6ef', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('103462c2-4bc7-4e57-9b92-1a85cc4b6478', 'e3b9abe5-1c29-4c2c-9e4c-1c5ef7aa1910', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('103462c2-4bc7-4e57-9b92-1a85cc4b6478', '17f8ea87-1501-4c72-86d2-0f16e9283aa4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('103462c2-4bc7-4e57-9b92-1a85cc4b6478', 'd2af4a93-39eb-4c5f-91b7-d03a7d93c7e3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('103462c2-4bc7-4e57-9b92-1a85cc4b6478', '9eaec49f-f949-4adc-a53c-9f182c248de9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d028abb6-5a86-401b-b979-e646b4353765', 'f42e6330-0dde-4165-a1b7-d44543e9f6ef', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d028abb6-5a86-401b-b979-e646b4353765', 'e3b9abe5-1c29-4c2c-9e4c-1c5ef7aa1910', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d028abb6-5a86-401b-b979-e646b4353765', '17f8ea87-1501-4c72-86d2-0f16e9283aa4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d028abb6-5a86-401b-b979-e646b4353765', 'd2af4a93-39eb-4c5f-91b7-d03a7d93c7e3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d028abb6-5a86-401b-b979-e646b4353765', '9eaec49f-f949-4adc-a53c-9f182c248de9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd80004f-dff9-481f-9458-069424eed5c0', 'f42e6330-0dde-4165-a1b7-d44543e9f6ef', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd80004f-dff9-481f-9458-069424eed5c0', 'e3b9abe5-1c29-4c2c-9e4c-1c5ef7aa1910', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd80004f-dff9-481f-9458-069424eed5c0', '17f8ea87-1501-4c72-86d2-0f16e9283aa4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd80004f-dff9-481f-9458-069424eed5c0', 'd2af4a93-39eb-4c5f-91b7-d03a7d93c7e3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd80004f-dff9-481f-9458-069424eed5c0', '9eaec49f-f949-4adc-a53c-9f182c248de9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6ef41d3b-ce3b-4149-9cbf-8cb315ea6eab', 'f42e6330-0dde-4165-a1b7-d44543e9f6ef', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6ef41d3b-ce3b-4149-9cbf-8cb315ea6eab', 'e3b9abe5-1c29-4c2c-9e4c-1c5ef7aa1910', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6ef41d3b-ce3b-4149-9cbf-8cb315ea6eab', '17f8ea87-1501-4c72-86d2-0f16e9283aa4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6ef41d3b-ce3b-4149-9cbf-8cb315ea6eab', 'd2af4a93-39eb-4c5f-91b7-d03a7d93c7e3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6ef41d3b-ce3b-4149-9cbf-8cb315ea6eab', '9eaec49f-f949-4adc-a53c-9f182c248de9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab88c24a-16a9-4244-9dbf-4730886b1274', 'f86eb1ae-972b-4429-8abd-80d8311e5509', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab88c24a-16a9-4244-9dbf-4730886b1274', '58064354-9d2a-4e72-b499-1c699759a3ea', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab88c24a-16a9-4244-9dbf-4730886b1274', '5f3040f5-39b2-450c-bb80-a37b9c5d759f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab88c24a-16a9-4244-9dbf-4730886b1274', 'f42e6330-0dde-4165-a1b7-d44543e9f6ef', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ab88c24a-16a9-4244-9dbf-4730886b1274', 'e3b9abe5-1c29-4c2c-9e4c-1c5ef7aa1910', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02b6f31f-1a2f-40a3-80f9-15215f63de79', '02da076b-c47b-4651-8f0d-b177f2c6fe28', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02b6f31f-1a2f-40a3-80f9-15215f63de79', '62801db0-576d-4ad0-9d69-9d58fa064d47', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02b6f31f-1a2f-40a3-80f9-15215f63de79', '05e1192c-ca6c-4af8-a030-22c59703d2f9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02b6f31f-1a2f-40a3-80f9-15215f63de79', '84d36b2e-866b-456c-bfa3-f694cfa69884', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02b6f31f-1a2f-40a3-80f9-15215f63de79', '9dc6cf95-8425-4ec6-81c1-ac3ef5a24cb9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02da076b-c47b-4651-8f0d-b177f2c6fe28', '02b6f31f-1a2f-40a3-80f9-15215f63de79', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02da076b-c47b-4651-8f0d-b177f2c6fe28', '62801db0-576d-4ad0-9d69-9d58fa064d47', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02da076b-c47b-4651-8f0d-b177f2c6fe28', '05e1192c-ca6c-4af8-a030-22c59703d2f9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02da076b-c47b-4651-8f0d-b177f2c6fe28', '84d36b2e-866b-456c-bfa3-f694cfa69884', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('02da076b-c47b-4651-8f0d-b177f2c6fe28', '9dc6cf95-8425-4ec6-81c1-ac3ef5a24cb9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b2976bdf-c631-4bfd-a84c-4097d1cfff91', '02da076b-c47b-4651-8f0d-b177f2c6fe28', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b2976bdf-c631-4bfd-a84c-4097d1cfff91', '02b6f31f-1a2f-40a3-80f9-15215f63de79', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b2976bdf-c631-4bfd-a84c-4097d1cfff91', '62801db0-576d-4ad0-9d69-9d58fa064d47', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b2976bdf-c631-4bfd-a84c-4097d1cfff91', '05e1192c-ca6c-4af8-a030-22c59703d2f9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b2976bdf-c631-4bfd-a84c-4097d1cfff91', '84d36b2e-866b-456c-bfa3-f694cfa69884', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('62801db0-576d-4ad0-9d69-9d58fa064d47', 'fffb5456-d3f2-49ab-b25d-526f45e2c62c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('62801db0-576d-4ad0-9d69-9d58fa064d47', 'd864e320-9d25-4f10-b5ca-be46f36eb3d2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('62801db0-576d-4ad0-9d69-9d58fa064d47', 'b52c3247-1994-47d4-9be3-6fdd78d9772f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('62801db0-576d-4ad0-9d69-9d58fa064d47', '02b6f31f-1a2f-40a3-80f9-15215f63de79', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('62801db0-576d-4ad0-9d69-9d58fa064d47', '02da076b-c47b-4651-8f0d-b177f2c6fe28', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('05e1192c-ca6c-4af8-a030-22c59703d2f9', '84d36b2e-866b-456c-bfa3-f694cfa69884', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('05e1192c-ca6c-4af8-a030-22c59703d2f9', '9dc6cf95-8425-4ec6-81c1-ac3ef5a24cb9', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('05e1192c-ca6c-4af8-a030-22c59703d2f9', '25183420-e87a-4b94-b1c4-65a679b18d09', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('05e1192c-ca6c-4af8-a030-22c59703d2f9', '028d5950-abf4-4cbc-94c0-c13a6375317d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('05e1192c-ca6c-4af8-a030-22c59703d2f9', '02b6f31f-1a2f-40a3-80f9-15215f63de79', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84d36b2e-866b-456c-bfa3-f694cfa69884', '05e1192c-ca6c-4af8-a030-22c59703d2f9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84d36b2e-866b-456c-bfa3-f694cfa69884', '9dc6cf95-8425-4ec6-81c1-ac3ef5a24cb9', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84d36b2e-866b-456c-bfa3-f694cfa69884', '25183420-e87a-4b94-b1c4-65a679b18d09', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84d36b2e-866b-456c-bfa3-f694cfa69884', '028d5950-abf4-4cbc-94c0-c13a6375317d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('84d36b2e-866b-456c-bfa3-f694cfa69884', '02b6f31f-1a2f-40a3-80f9-15215f63de79', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9dc6cf95-8425-4ec6-81c1-ac3ef5a24cb9', '05e1192c-ca6c-4af8-a030-22c59703d2f9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9dc6cf95-8425-4ec6-81c1-ac3ef5a24cb9', '84d36b2e-866b-456c-bfa3-f694cfa69884', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9dc6cf95-8425-4ec6-81c1-ac3ef5a24cb9', '25183420-e87a-4b94-b1c4-65a679b18d09', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9dc6cf95-8425-4ec6-81c1-ac3ef5a24cb9', '028d5950-abf4-4cbc-94c0-c13a6375317d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9dc6cf95-8425-4ec6-81c1-ac3ef5a24cb9', '02b6f31f-1a2f-40a3-80f9-15215f63de79', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fffb5456-d3f2-49ab-b25d-526f45e2c62c', '62801db0-576d-4ad0-9d69-9d58fa064d47', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fffb5456-d3f2-49ab-b25d-526f45e2c62c', 'd864e320-9d25-4f10-b5ca-be46f36eb3d2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fffb5456-d3f2-49ab-b25d-526f45e2c62c', 'b52c3247-1994-47d4-9be3-6fdd78d9772f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fffb5456-d3f2-49ab-b25d-526f45e2c62c', '02b6f31f-1a2f-40a3-80f9-15215f63de79', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fffb5456-d3f2-49ab-b25d-526f45e2c62c', '02da076b-c47b-4651-8f0d-b177f2c6fe28', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d864e320-9d25-4f10-b5ca-be46f36eb3d2', '62801db0-576d-4ad0-9d69-9d58fa064d47', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d864e320-9d25-4f10-b5ca-be46f36eb3d2', 'fffb5456-d3f2-49ab-b25d-526f45e2c62c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d864e320-9d25-4f10-b5ca-be46f36eb3d2', 'b52c3247-1994-47d4-9be3-6fdd78d9772f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d864e320-9d25-4f10-b5ca-be46f36eb3d2', '02b6f31f-1a2f-40a3-80f9-15215f63de79', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d864e320-9d25-4f10-b5ca-be46f36eb3d2', '02da076b-c47b-4651-8f0d-b177f2c6fe28', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('25183420-e87a-4b94-b1c4-65a679b18d09', '05e1192c-ca6c-4af8-a030-22c59703d2f9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('25183420-e87a-4b94-b1c4-65a679b18d09', '84d36b2e-866b-456c-bfa3-f694cfa69884', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('25183420-e87a-4b94-b1c4-65a679b18d09', '9dc6cf95-8425-4ec6-81c1-ac3ef5a24cb9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('25183420-e87a-4b94-b1c4-65a679b18d09', '028d5950-abf4-4cbc-94c0-c13a6375317d', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('25183420-e87a-4b94-b1c4-65a679b18d09', '02b6f31f-1a2f-40a3-80f9-15215f63de79', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('028d5950-abf4-4cbc-94c0-c13a6375317d', '05e1192c-ca6c-4af8-a030-22c59703d2f9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('028d5950-abf4-4cbc-94c0-c13a6375317d', '84d36b2e-866b-456c-bfa3-f694cfa69884', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('028d5950-abf4-4cbc-94c0-c13a6375317d', '9dc6cf95-8425-4ec6-81c1-ac3ef5a24cb9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('028d5950-abf4-4cbc-94c0-c13a6375317d', '25183420-e87a-4b94-b1c4-65a679b18d09', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('028d5950-abf4-4cbc-94c0-c13a6375317d', '02b6f31f-1a2f-40a3-80f9-15215f63de79', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b52c3247-1994-47d4-9be3-6fdd78d9772f', '62801db0-576d-4ad0-9d69-9d58fa064d47', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b52c3247-1994-47d4-9be3-6fdd78d9772f', 'fffb5456-d3f2-49ab-b25d-526f45e2c62c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b52c3247-1994-47d4-9be3-6fdd78d9772f', 'd864e320-9d25-4f10-b5ca-be46f36eb3d2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b52c3247-1994-47d4-9be3-6fdd78d9772f', '02b6f31f-1a2f-40a3-80f9-15215f63de79', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b52c3247-1994-47d4-9be3-6fdd78d9772f', '02da076b-c47b-4651-8f0d-b177f2c6fe28', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f33b11af-c5a1-4a5e-b057-902d813e7501', 'f42e6330-0dde-4165-a1b7-d44543e9f6ef', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f33b11af-c5a1-4a5e-b057-902d813e7501', 'e3b9abe5-1c29-4c2c-9e4c-1c5ef7aa1910', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f33b11af-c5a1-4a5e-b057-902d813e7501', '17f8ea87-1501-4c72-86d2-0f16e9283aa4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f33b11af-c5a1-4a5e-b057-902d813e7501', 'd2af4a93-39eb-4c5f-91b7-d03a7d93c7e3', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f33b11af-c5a1-4a5e-b057-902d813e7501', '9eaec49f-f949-4adc-a53c-9f182c248de9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ee1cfed8-80ca-476e-a3a3-f3150f46c174', 'f86eb1ae-972b-4429-8abd-80d8311e5509', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ee1cfed8-80ca-476e-a3a3-f3150f46c174', '58064354-9d2a-4e72-b499-1c699759a3ea', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ee1cfed8-80ca-476e-a3a3-f3150f46c174', '5f3040f5-39b2-450c-bb80-a37b9c5d759f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bbb9592a-9936-4213-bf01-97547446e847', '654cf770-70f2-4c62-9a94-39e86dbc15e3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bbb9592a-9936-4213-bf01-97547446e847', '75d37d45-8d3c-42ba-a689-e96e2329c504', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bbb9592a-9936-4213-bf01-97547446e847', 'bc7a7c1b-6f36-441d-8d67-a08c9c073457', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('654cf770-70f2-4c62-9a94-39e86dbc15e3', 'bbb9592a-9936-4213-bf01-97547446e847', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('654cf770-70f2-4c62-9a94-39e86dbc15e3', '75d37d45-8d3c-42ba-a689-e96e2329c504', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('654cf770-70f2-4c62-9a94-39e86dbc15e3', 'bc7a7c1b-6f36-441d-8d67-a08c9c073457', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75d37d45-8d3c-42ba-a689-e96e2329c504', 'bbb9592a-9936-4213-bf01-97547446e847', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75d37d45-8d3c-42ba-a689-e96e2329c504', '654cf770-70f2-4c62-9a94-39e86dbc15e3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75d37d45-8d3c-42ba-a689-e96e2329c504', 'bc7a7c1b-6f36-441d-8d67-a08c9c073457', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bc7a7c1b-6f36-441d-8d67-a08c9c073457', 'bbb9592a-9936-4213-bf01-97547446e847', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bc7a7c1b-6f36-441d-8d67-a08c9c073457', '654cf770-70f2-4c62-9a94-39e86dbc15e3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bc7a7c1b-6f36-441d-8d67-a08c9c073457', '75d37d45-8d3c-42ba-a689-e96e2329c504', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('659c0842-9970-45f7-a161-025e4f292414', '4e68c4f1-1da2-4ad6-b398-3d2884841ca5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('659c0842-9970-45f7-a161-025e4f292414', 'd7c8fa2f-9604-479c-b3f9-9586c68f1bbb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('659c0842-9970-45f7-a161-025e4f292414', 'dfd5f2d3-2a52-484b-a048-510c4b79afca', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('659c0842-9970-45f7-a161-025e4f292414', '52c47158-5686-4026-bbb1-9789cb1eab01', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('659c0842-9970-45f7-a161-025e4f292414', '3d535b51-a843-470d-9756-89f68ef3ab95', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4e68c4f1-1da2-4ad6-b398-3d2884841ca5', '659c0842-9970-45f7-a161-025e4f292414', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4e68c4f1-1da2-4ad6-b398-3d2884841ca5', 'd7c8fa2f-9604-479c-b3f9-9586c68f1bbb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4e68c4f1-1da2-4ad6-b398-3d2884841ca5', 'dfd5f2d3-2a52-484b-a048-510c4b79afca', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4e68c4f1-1da2-4ad6-b398-3d2884841ca5', '52c47158-5686-4026-bbb1-9789cb1eab01', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4e68c4f1-1da2-4ad6-b398-3d2884841ca5', '3d535b51-a843-470d-9756-89f68ef3ab95', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d7c8fa2f-9604-479c-b3f9-9586c68f1bbb', '659c0842-9970-45f7-a161-025e4f292414', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d7c8fa2f-9604-479c-b3f9-9586c68f1bbb', '4e68c4f1-1da2-4ad6-b398-3d2884841ca5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d7c8fa2f-9604-479c-b3f9-9586c68f1bbb', 'dfd5f2d3-2a52-484b-a048-510c4b79afca', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d7c8fa2f-9604-479c-b3f9-9586c68f1bbb', '52c47158-5686-4026-bbb1-9789cb1eab01', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d7c8fa2f-9604-479c-b3f9-9586c68f1bbb', '3d535b51-a843-470d-9756-89f68ef3ab95', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dfd5f2d3-2a52-484b-a048-510c4b79afca', '659c0842-9970-45f7-a161-025e4f292414', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dfd5f2d3-2a52-484b-a048-510c4b79afca', '4e68c4f1-1da2-4ad6-b398-3d2884841ca5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dfd5f2d3-2a52-484b-a048-510c4b79afca', 'd7c8fa2f-9604-479c-b3f9-9586c68f1bbb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dfd5f2d3-2a52-484b-a048-510c4b79afca', '52c47158-5686-4026-bbb1-9789cb1eab01', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dfd5f2d3-2a52-484b-a048-510c4b79afca', '3d535b51-a843-470d-9756-89f68ef3ab95', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('da10b4a4-2521-4a88-98e1-c9d0d9a61669', 'e024c235-5358-408a-ac6b-a28b517c125e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('da10b4a4-2521-4a88-98e1-c9d0d9a61669', '659c0842-9970-45f7-a161-025e4f292414', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('da10b4a4-2521-4a88-98e1-c9d0d9a61669', '4e68c4f1-1da2-4ad6-b398-3d2884841ca5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('da10b4a4-2521-4a88-98e1-c9d0d9a61669', 'd7c8fa2f-9604-479c-b3f9-9586c68f1bbb', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('da10b4a4-2521-4a88-98e1-c9d0d9a61669', 'dfd5f2d3-2a52-484b-a048-510c4b79afca', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e024c235-5358-408a-ac6b-a28b517c125e', 'da10b4a4-2521-4a88-98e1-c9d0d9a61669', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e024c235-5358-408a-ac6b-a28b517c125e', '659c0842-9970-45f7-a161-025e4f292414', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e024c235-5358-408a-ac6b-a28b517c125e', '4e68c4f1-1da2-4ad6-b398-3d2884841ca5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e024c235-5358-408a-ac6b-a28b517c125e', 'd7c8fa2f-9604-479c-b3f9-9586c68f1bbb', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e024c235-5358-408a-ac6b-a28b517c125e', 'dfd5f2d3-2a52-484b-a048-510c4b79afca', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('52c47158-5686-4026-bbb1-9789cb1eab01', '659c0842-9970-45f7-a161-025e4f292414', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('52c47158-5686-4026-bbb1-9789cb1eab01', '4e68c4f1-1da2-4ad6-b398-3d2884841ca5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('52c47158-5686-4026-bbb1-9789cb1eab01', 'd7c8fa2f-9604-479c-b3f9-9586c68f1bbb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('52c47158-5686-4026-bbb1-9789cb1eab01', 'dfd5f2d3-2a52-484b-a048-510c4b79afca', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('52c47158-5686-4026-bbb1-9789cb1eab01', '3d535b51-a843-470d-9756-89f68ef3ab95', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d535b51-a843-470d-9756-89f68ef3ab95', '659c0842-9970-45f7-a161-025e4f292414', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d535b51-a843-470d-9756-89f68ef3ab95', '4e68c4f1-1da2-4ad6-b398-3d2884841ca5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d535b51-a843-470d-9756-89f68ef3ab95', 'd7c8fa2f-9604-479c-b3f9-9586c68f1bbb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d535b51-a843-470d-9756-89f68ef3ab95', 'dfd5f2d3-2a52-484b-a048-510c4b79afca', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d535b51-a843-470d-9756-89f68ef3ab95', '52c47158-5686-4026-bbb1-9789cb1eab01', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a2aa12b-264e-449c-ad99-6bf045c25589', '5b8e07fc-5ac1-42d7-8535-fef6dcfbb037', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a2aa12b-264e-449c-ad99-6bf045c25589', 'bbb9592a-9936-4213-bf01-97547446e847', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a2aa12b-264e-449c-ad99-6bf045c25589', '654cf770-70f2-4c62-9a94-39e86dbc15e3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9fea517-19c5-4775-9248-f312fc8965ea', '659c0842-9970-45f7-a161-025e4f292414', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9fea517-19c5-4775-9248-f312fc8965ea', '4e68c4f1-1da2-4ad6-b398-3d2884841ca5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9fea517-19c5-4775-9248-f312fc8965ea', 'd7c8fa2f-9604-479c-b3f9-9586c68f1bbb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9fea517-19c5-4775-9248-f312fc8965ea', 'dfd5f2d3-2a52-484b-a048-510c4b79afca', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9fea517-19c5-4775-9248-f312fc8965ea', 'da10b4a4-2521-4a88-98e1-c9d0d9a61669', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eeece670-d0b2-4b34-883b-4347673f1cbd', '5b8e07fc-5ac1-42d7-8535-fef6dcfbb037', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eeece670-d0b2-4b34-883b-4347673f1cbd', 'bbb9592a-9936-4213-bf01-97547446e847', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eeece670-d0b2-4b34-883b-4347673f1cbd', '654cf770-70f2-4c62-9a94-39e86dbc15e3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('77ecdcb5-6434-46e4-9bef-a7679e7443c8', '3ef613aa-1dd0-49b5-8339-bd4954a8a33a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('77ecdcb5-6434-46e4-9bef-a7679e7443c8', 'ed5e9a34-efd7-4216-a0f1-3737ad3d7c70', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('77ecdcb5-6434-46e4-9bef-a7679e7443c8', 'e11c1ed5-923f-468b-b0df-566860ba9099', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('77ecdcb5-6434-46e4-9bef-a7679e7443c8', '8b3b8966-04a0-42c5-ac2d-fd0c7d1a810a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('77ecdcb5-6434-46e4-9bef-a7679e7443c8', 'a215b45e-8333-4e23-aae0-746c279fa9cf', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22b300a5-e1c5-4cf5-8cf7-641f4f34a5b9', '360607f6-c9db-499f-85e1-a5fc48a8eaa9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22b300a5-e1c5-4cf5-8cf7-641f4f34a5b9', '77ecdcb5-6434-46e4-9bef-a7679e7443c8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22b300a5-e1c5-4cf5-8cf7-641f4f34a5b9', '3ef613aa-1dd0-49b5-8339-bd4954a8a33a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22b300a5-e1c5-4cf5-8cf7-641f4f34a5b9', 'ed5e9a34-efd7-4216-a0f1-3737ad3d7c70', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('22b300a5-e1c5-4cf5-8cf7-641f4f34a5b9', 'e11c1ed5-923f-468b-b0df-566860ba9099', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3ef613aa-1dd0-49b5-8339-bd4954a8a33a', '77ecdcb5-6434-46e4-9bef-a7679e7443c8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3ef613aa-1dd0-49b5-8339-bd4954a8a33a', 'ed5e9a34-efd7-4216-a0f1-3737ad3d7c70', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3ef613aa-1dd0-49b5-8339-bd4954a8a33a', 'e11c1ed5-923f-468b-b0df-566860ba9099', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3ef613aa-1dd0-49b5-8339-bd4954a8a33a', '8b3b8966-04a0-42c5-ac2d-fd0c7d1a810a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3ef613aa-1dd0-49b5-8339-bd4954a8a33a', 'a215b45e-8333-4e23-aae0-746c279fa9cf', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ed5e9a34-efd7-4216-a0f1-3737ad3d7c70', '77ecdcb5-6434-46e4-9bef-a7679e7443c8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ed5e9a34-efd7-4216-a0f1-3737ad3d7c70', '3ef613aa-1dd0-49b5-8339-bd4954a8a33a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ed5e9a34-efd7-4216-a0f1-3737ad3d7c70', 'e11c1ed5-923f-468b-b0df-566860ba9099', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ed5e9a34-efd7-4216-a0f1-3737ad3d7c70', '8b3b8966-04a0-42c5-ac2d-fd0c7d1a810a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ed5e9a34-efd7-4216-a0f1-3737ad3d7c70', 'a215b45e-8333-4e23-aae0-746c279fa9cf', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e11c1ed5-923f-468b-b0df-566860ba9099', '77ecdcb5-6434-46e4-9bef-a7679e7443c8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e11c1ed5-923f-468b-b0df-566860ba9099', '3ef613aa-1dd0-49b5-8339-bd4954a8a33a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e11c1ed5-923f-468b-b0df-566860ba9099', 'ed5e9a34-efd7-4216-a0f1-3737ad3d7c70', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e11c1ed5-923f-468b-b0df-566860ba9099', '8b3b8966-04a0-42c5-ac2d-fd0c7d1a810a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e11c1ed5-923f-468b-b0df-566860ba9099', 'a215b45e-8333-4e23-aae0-746c279fa9cf', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b3b8966-04a0-42c5-ac2d-fd0c7d1a810a', '77ecdcb5-6434-46e4-9bef-a7679e7443c8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b3b8966-04a0-42c5-ac2d-fd0c7d1a810a', '3ef613aa-1dd0-49b5-8339-bd4954a8a33a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b3b8966-04a0-42c5-ac2d-fd0c7d1a810a', 'ed5e9a34-efd7-4216-a0f1-3737ad3d7c70', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b3b8966-04a0-42c5-ac2d-fd0c7d1a810a', 'e11c1ed5-923f-468b-b0df-566860ba9099', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b3b8966-04a0-42c5-ac2d-fd0c7d1a810a', 'a215b45e-8333-4e23-aae0-746c279fa9cf', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a215b45e-8333-4e23-aae0-746c279fa9cf', '77ecdcb5-6434-46e4-9bef-a7679e7443c8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a215b45e-8333-4e23-aae0-746c279fa9cf', '3ef613aa-1dd0-49b5-8339-bd4954a8a33a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a215b45e-8333-4e23-aae0-746c279fa9cf', 'ed5e9a34-efd7-4216-a0f1-3737ad3d7c70', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a215b45e-8333-4e23-aae0-746c279fa9cf', 'e11c1ed5-923f-468b-b0df-566860ba9099', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a215b45e-8333-4e23-aae0-746c279fa9cf', '8b3b8966-04a0-42c5-ac2d-fd0c7d1a810a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8e871fc6-0bb2-4f27-a492-13e85405a681', '702608a3-3982-44a7-b70a-504a9dd407a0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8e871fc6-0bb2-4f27-a492-13e85405a681', '77ecdcb5-6434-46e4-9bef-a7679e7443c8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8e871fc6-0bb2-4f27-a492-13e85405a681', '22b300a5-e1c5-4cf5-8cf7-641f4f34a5b9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8e871fc6-0bb2-4f27-a492-13e85405a681', '3ef613aa-1dd0-49b5-8339-bd4954a8a33a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8e871fc6-0bb2-4f27-a492-13e85405a681', 'ed5e9a34-efd7-4216-a0f1-3737ad3d7c70', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('702608a3-3982-44a7-b70a-504a9dd407a0', '8e871fc6-0bb2-4f27-a492-13e85405a681', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('702608a3-3982-44a7-b70a-504a9dd407a0', '77ecdcb5-6434-46e4-9bef-a7679e7443c8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('702608a3-3982-44a7-b70a-504a9dd407a0', '22b300a5-e1c5-4cf5-8cf7-641f4f34a5b9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('702608a3-3982-44a7-b70a-504a9dd407a0', '3ef613aa-1dd0-49b5-8339-bd4954a8a33a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('702608a3-3982-44a7-b70a-504a9dd407a0', 'ed5e9a34-efd7-4216-a0f1-3737ad3d7c70', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0137969c-4ec4-4e56-90f4-4d0aea0ed82c', '77ecdcb5-6434-46e4-9bef-a7679e7443c8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0137969c-4ec4-4e56-90f4-4d0aea0ed82c', '3ef613aa-1dd0-49b5-8339-bd4954a8a33a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0137969c-4ec4-4e56-90f4-4d0aea0ed82c', 'ed5e9a34-efd7-4216-a0f1-3737ad3d7c70', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0137969c-4ec4-4e56-90f4-4d0aea0ed82c', 'e11c1ed5-923f-468b-b0df-566860ba9099', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0137969c-4ec4-4e56-90f4-4d0aea0ed82c', '8b3b8966-04a0-42c5-ac2d-fd0c7d1a810a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5d1714be-8a76-4463-a8db-5f43bf512fa2', '77ecdcb5-6434-46e4-9bef-a7679e7443c8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5d1714be-8a76-4463-a8db-5f43bf512fa2', '3ef613aa-1dd0-49b5-8339-bd4954a8a33a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5d1714be-8a76-4463-a8db-5f43bf512fa2', 'ed5e9a34-efd7-4216-a0f1-3737ad3d7c70', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5d1714be-8a76-4463-a8db-5f43bf512fa2', 'e11c1ed5-923f-468b-b0df-566860ba9099', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5d1714be-8a76-4463-a8db-5f43bf512fa2', '8b3b8966-04a0-42c5-ac2d-fd0c7d1a810a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('360607f6-c9db-499f-85e1-a5fc48a8eaa9', '22b300a5-e1c5-4cf5-8cf7-641f4f34a5b9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('360607f6-c9db-499f-85e1-a5fc48a8eaa9', '77ecdcb5-6434-46e4-9bef-a7679e7443c8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('360607f6-c9db-499f-85e1-a5fc48a8eaa9', '3ef613aa-1dd0-49b5-8339-bd4954a8a33a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('360607f6-c9db-499f-85e1-a5fc48a8eaa9', 'ed5e9a34-efd7-4216-a0f1-3737ad3d7c70', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('360607f6-c9db-499f-85e1-a5fc48a8eaa9', 'e11c1ed5-923f-468b-b0df-566860ba9099', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39c8dd99-8ffd-4873-82f3-c37bfb069843', '77ecdcb5-6434-46e4-9bef-a7679e7443c8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39c8dd99-8ffd-4873-82f3-c37bfb069843', '3ef613aa-1dd0-49b5-8339-bd4954a8a33a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39c8dd99-8ffd-4873-82f3-c37bfb069843', 'ed5e9a34-efd7-4216-a0f1-3737ad3d7c70', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39c8dd99-8ffd-4873-82f3-c37bfb069843', 'e11c1ed5-923f-468b-b0df-566860ba9099', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39c8dd99-8ffd-4873-82f3-c37bfb069843', '8b3b8966-04a0-42c5-ac2d-fd0c7d1a810a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a4bab736-1725-43fd-910c-29229df133d4', 'f0b56696-fa5d-435a-b211-b612538b6db0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a4bab736-1725-43fd-910c-29229df133d4', '6fa175fb-27fb-4296-9319-214a3e1a51fd', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a4bab736-1725-43fd-910c-29229df133d4', 'd7ed0f13-e135-4640-895c-9da5cb27142d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a4bab736-1725-43fd-910c-29229df133d4', 'b0f2e958-9be7-4c55-b92f-f5041e14b8d6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a4bab736-1725-43fd-910c-29229df133d4', '19231e4e-32e6-4d46-8706-586a872e5b14', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6fa175fb-27fb-4296-9319-214a3e1a51fd', 'a4bab736-1725-43fd-910c-29229df133d4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6fa175fb-27fb-4296-9319-214a3e1a51fd', 'd7ed0f13-e135-4640-895c-9da5cb27142d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6fa175fb-27fb-4296-9319-214a3e1a51fd', 'b0f2e958-9be7-4c55-b92f-f5041e14b8d6', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6fa175fb-27fb-4296-9319-214a3e1a51fd', '19231e4e-32e6-4d46-8706-586a872e5b14', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6fa175fb-27fb-4296-9319-214a3e1a51fd', 'df3e211c-6d3f-4268-bcd9-74c5265dd22e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d7ed0f13-e135-4640-895c-9da5cb27142d', 'a4bab736-1725-43fd-910c-29229df133d4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d7ed0f13-e135-4640-895c-9da5cb27142d', '6fa175fb-27fb-4296-9319-214a3e1a51fd', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d7ed0f13-e135-4640-895c-9da5cb27142d', 'b0f2e958-9be7-4c55-b92f-f5041e14b8d6', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d7ed0f13-e135-4640-895c-9da5cb27142d', '19231e4e-32e6-4d46-8706-586a872e5b14', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d7ed0f13-e135-4640-895c-9da5cb27142d', 'df3e211c-6d3f-4268-bcd9-74c5265dd22e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b0f2e958-9be7-4c55-b92f-f5041e14b8d6', '19231e4e-32e6-4d46-8706-586a872e5b14', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b0f2e958-9be7-4c55-b92f-f5041e14b8d6', 'df3e211c-6d3f-4268-bcd9-74c5265dd22e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b0f2e958-9be7-4c55-b92f-f5041e14b8d6', '8bda3c4e-7c69-4948-827e-5189bfc5f44d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b0f2e958-9be7-4c55-b92f-f5041e14b8d6', 'a4bab736-1725-43fd-910c-29229df133d4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b0f2e958-9be7-4c55-b92f-f5041e14b8d6', '6fa175fb-27fb-4296-9319-214a3e1a51fd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19231e4e-32e6-4d46-8706-586a872e5b14', 'b0f2e958-9be7-4c55-b92f-f5041e14b8d6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19231e4e-32e6-4d46-8706-586a872e5b14', 'df3e211c-6d3f-4268-bcd9-74c5265dd22e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19231e4e-32e6-4d46-8706-586a872e5b14', '8bda3c4e-7c69-4948-827e-5189bfc5f44d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19231e4e-32e6-4d46-8706-586a872e5b14', 'a4bab736-1725-43fd-910c-29229df133d4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19231e4e-32e6-4d46-8706-586a872e5b14', '6fa175fb-27fb-4296-9319-214a3e1a51fd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('df3e211c-6d3f-4268-bcd9-74c5265dd22e', 'b0f2e958-9be7-4c55-b92f-f5041e14b8d6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('df3e211c-6d3f-4268-bcd9-74c5265dd22e', '19231e4e-32e6-4d46-8706-586a872e5b14', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('df3e211c-6d3f-4268-bcd9-74c5265dd22e', '8bda3c4e-7c69-4948-827e-5189bfc5f44d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('df3e211c-6d3f-4268-bcd9-74c5265dd22e', 'a4bab736-1725-43fd-910c-29229df133d4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('df3e211c-6d3f-4268-bcd9-74c5265dd22e', '6fa175fb-27fb-4296-9319-214a3e1a51fd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8bda3c4e-7c69-4948-827e-5189bfc5f44d', 'b0f2e958-9be7-4c55-b92f-f5041e14b8d6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8bda3c4e-7c69-4948-827e-5189bfc5f44d', '19231e4e-32e6-4d46-8706-586a872e5b14', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8bda3c4e-7c69-4948-827e-5189bfc5f44d', 'df3e211c-6d3f-4268-bcd9-74c5265dd22e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8bda3c4e-7c69-4948-827e-5189bfc5f44d', 'a4bab736-1725-43fd-910c-29229df133d4', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8bda3c4e-7c69-4948-827e-5189bfc5f44d', '6fa175fb-27fb-4296-9319-214a3e1a51fd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0b56696-fa5d-435a-b211-b612538b6db0', 'a4bab736-1725-43fd-910c-29229df133d4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0b56696-fa5d-435a-b211-b612538b6db0', '6fa175fb-27fb-4296-9319-214a3e1a51fd', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0b56696-fa5d-435a-b211-b612538b6db0', 'd7ed0f13-e135-4640-895c-9da5cb27142d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0b56696-fa5d-435a-b211-b612538b6db0', 'b0f2e958-9be7-4c55-b92f-f5041e14b8d6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f0b56696-fa5d-435a-b211-b612538b6db0', '19231e4e-32e6-4d46-8706-586a872e5b14', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d0a65529-ade3-4af6-ade4-7b89cb9c7374', 'a4bab736-1725-43fd-910c-29229df133d4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d0a65529-ade3-4af6-ade4-7b89cb9c7374', '6fa175fb-27fb-4296-9319-214a3e1a51fd', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d0a65529-ade3-4af6-ade4-7b89cb9c7374', 'd7ed0f13-e135-4640-895c-9da5cb27142d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fd8b74d4-0c27-4167-a2ed-5b02597afc34', 'a4bab736-1725-43fd-910c-29229df133d4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fd8b74d4-0c27-4167-a2ed-5b02597afc34', '6fa175fb-27fb-4296-9319-214a3e1a51fd', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fd8b74d4-0c27-4167-a2ed-5b02597afc34', 'd7ed0f13-e135-4640-895c-9da5cb27142d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fd8b74d4-0c27-4167-a2ed-5b02597afc34', 'b0f2e958-9be7-4c55-b92f-f5041e14b8d6', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fd8b74d4-0c27-4167-a2ed-5b02597afc34', '19231e4e-32e6-4d46-8706-586a872e5b14', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6782b7c5-7f85-4676-8b25-5e42bd760f1f', 'bd114250-7f1c-4006-8e47-c4d95ad91568', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6782b7c5-7f85-4676-8b25-5e42bd760f1f', '7c0fa428-a5c6-4f85-a313-fad191dff3d8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6782b7c5-7f85-4676-8b25-5e42bd760f1f', 'a4ad49a4-f13b-4be5-92b9-27590f335641', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6782b7c5-7f85-4676-8b25-5e42bd760f1f', '90615188-a65f-44e4-942d-ad35ddf9c62c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6782b7c5-7f85-4676-8b25-5e42bd760f1f', '8bec3fb9-fac7-4ee9-a8dc-8ecbd8422cc1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b3eed6cc-e3dd-472d-90a3-9e1799c80b2f', '6782b7c5-7f85-4676-8b25-5e42bd760f1f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b3eed6cc-e3dd-472d-90a3-9e1799c80b2f', 'bd114250-7f1c-4006-8e47-c4d95ad91568', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b3eed6cc-e3dd-472d-90a3-9e1799c80b2f', '7c0fa428-a5c6-4f85-a313-fad191dff3d8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b3eed6cc-e3dd-472d-90a3-9e1799c80b2f', 'a4ad49a4-f13b-4be5-92b9-27590f335641', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b3eed6cc-e3dd-472d-90a3-9e1799c80b2f', '90615188-a65f-44e4-942d-ad35ddf9c62c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bd114250-7f1c-4006-8e47-c4d95ad91568', '6782b7c5-7f85-4676-8b25-5e42bd760f1f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bd114250-7f1c-4006-8e47-c4d95ad91568', '7c0fa428-a5c6-4f85-a313-fad191dff3d8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bd114250-7f1c-4006-8e47-c4d95ad91568', 'a4ad49a4-f13b-4be5-92b9-27590f335641', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bd114250-7f1c-4006-8e47-c4d95ad91568', '90615188-a65f-44e4-942d-ad35ddf9c62c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bd114250-7f1c-4006-8e47-c4d95ad91568', '8bec3fb9-fac7-4ee9-a8dc-8ecbd8422cc1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a4ad49a4-f13b-4be5-92b9-27590f335641', '6782b7c5-7f85-4676-8b25-5e42bd760f1f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a4ad49a4-f13b-4be5-92b9-27590f335641', 'bd114250-7f1c-4006-8e47-c4d95ad91568', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a4ad49a4-f13b-4be5-92b9-27590f335641', '90615188-a65f-44e4-942d-ad35ddf9c62c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a4ad49a4-f13b-4be5-92b9-27590f335641', '7c0fa428-a5c6-4f85-a313-fad191dff3d8', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a4ad49a4-f13b-4be5-92b9-27590f335641', '8bec3fb9-fac7-4ee9-a8dc-8ecbd8422cc1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('90615188-a65f-44e4-942d-ad35ddf9c62c', '6782b7c5-7f85-4676-8b25-5e42bd760f1f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('90615188-a65f-44e4-942d-ad35ddf9c62c', 'bd114250-7f1c-4006-8e47-c4d95ad91568', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('90615188-a65f-44e4-942d-ad35ddf9c62c', 'a4ad49a4-f13b-4be5-92b9-27590f335641', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('90615188-a65f-44e4-942d-ad35ddf9c62c', '7c0fa428-a5c6-4f85-a313-fad191dff3d8', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('90615188-a65f-44e4-942d-ad35ddf9c62c', '8bec3fb9-fac7-4ee9-a8dc-8ecbd8422cc1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f2efabb8-0430-4fbc-a080-a69f6b5a98b8', '6782b7c5-7f85-4676-8b25-5e42bd760f1f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f2efabb8-0430-4fbc-a080-a69f6b5a98b8', 'bd114250-7f1c-4006-8e47-c4d95ad91568', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f2efabb8-0430-4fbc-a080-a69f6b5a98b8', 'a4ad49a4-f13b-4be5-92b9-27590f335641', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2744253a-3cf0-4f4c-be24-0b56a928ce3c', '6782b7c5-7f85-4676-8b25-5e42bd760f1f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2744253a-3cf0-4f4c-be24-0b56a928ce3c', 'bd114250-7f1c-4006-8e47-c4d95ad91568', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2744253a-3cf0-4f4c-be24-0b56a928ce3c', 'a4ad49a4-f13b-4be5-92b9-27590f335641', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('853ed6ff-7654-4b55-a4ff-010c2871982b', 'bc0adcfd-9ca2-4f1e-864a-3e3f502f5e09', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('853ed6ff-7654-4b55-a4ff-010c2871982b', '9a753a1e-d352-4dd9-b3c8-b8bac516a13e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('853ed6ff-7654-4b55-a4ff-010c2871982b', 'fca235c8-7e60-481a-ae15-4fd49bca7814', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('853ed6ff-7654-4b55-a4ff-010c2871982b', '20ee16f3-c014-409e-964c-60932cbdb1c7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('853ed6ff-7654-4b55-a4ff-010c2871982b', '574a6016-c862-40ea-8b2a-f4d4f851aceb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fca235c8-7e60-481a-ae15-4fd49bca7814', '574a6016-c862-40ea-8b2a-f4d4f851aceb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fca235c8-7e60-481a-ae15-4fd49bca7814', '853ed6ff-7654-4b55-a4ff-010c2871982b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fca235c8-7e60-481a-ae15-4fd49bca7814', 'bc0adcfd-9ca2-4f1e-864a-3e3f502f5e09', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fca235c8-7e60-481a-ae15-4fd49bca7814', '20ee16f3-c014-409e-964c-60932cbdb1c7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fca235c8-7e60-481a-ae15-4fd49bca7814', '9a753a1e-d352-4dd9-b3c8-b8bac516a13e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bc0adcfd-9ca2-4f1e-864a-3e3f502f5e09', '853ed6ff-7654-4b55-a4ff-010c2871982b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bc0adcfd-9ca2-4f1e-864a-3e3f502f5e09', '9a753a1e-d352-4dd9-b3c8-b8bac516a13e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bc0adcfd-9ca2-4f1e-864a-3e3f502f5e09', 'fca235c8-7e60-481a-ae15-4fd49bca7814', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bc0adcfd-9ca2-4f1e-864a-3e3f502f5e09', '20ee16f3-c014-409e-964c-60932cbdb1c7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bc0adcfd-9ca2-4f1e-864a-3e3f502f5e09', '574a6016-c862-40ea-8b2a-f4d4f851aceb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('20ee16f3-c014-409e-964c-60932cbdb1c7', '853ed6ff-7654-4b55-a4ff-010c2871982b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('20ee16f3-c014-409e-964c-60932cbdb1c7', 'fca235c8-7e60-481a-ae15-4fd49bca7814', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('20ee16f3-c014-409e-964c-60932cbdb1c7', 'bc0adcfd-9ca2-4f1e-864a-3e3f502f5e09', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('20ee16f3-c014-409e-964c-60932cbdb1c7', '574a6016-c862-40ea-8b2a-f4d4f851aceb', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('20ee16f3-c014-409e-964c-60932cbdb1c7', '9a753a1e-d352-4dd9-b3c8-b8bac516a13e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('574a6016-c862-40ea-8b2a-f4d4f851aceb', 'fca235c8-7e60-481a-ae15-4fd49bca7814', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('574a6016-c862-40ea-8b2a-f4d4f851aceb', '853ed6ff-7654-4b55-a4ff-010c2871982b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('574a6016-c862-40ea-8b2a-f4d4f851aceb', 'bc0adcfd-9ca2-4f1e-864a-3e3f502f5e09', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('574a6016-c862-40ea-8b2a-f4d4f851aceb', '20ee16f3-c014-409e-964c-60932cbdb1c7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('574a6016-c862-40ea-8b2a-f4d4f851aceb', '9a753a1e-d352-4dd9-b3c8-b8bac516a13e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('08cf0882-a474-4245-a53c-0419b6cfef0e', 'd836356d-f6b0-4fbb-926e-2f210662cab6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('08cf0882-a474-4245-a53c-0419b6cfef0e', '6782b7c5-7f85-4676-8b25-5e42bd760f1f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('08cf0882-a474-4245-a53c-0419b6cfef0e', 'bd114250-7f1c-4006-8e47-c4d95ad91568', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7c0fa428-a5c6-4f85-a313-fad191dff3d8', '6782b7c5-7f85-4676-8b25-5e42bd760f1f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7c0fa428-a5c6-4f85-a313-fad191dff3d8', 'bd114250-7f1c-4006-8e47-c4d95ad91568', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7c0fa428-a5c6-4f85-a313-fad191dff3d8', 'a4ad49a4-f13b-4be5-92b9-27590f335641', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7c0fa428-a5c6-4f85-a313-fad191dff3d8', '90615188-a65f-44e4-942d-ad35ddf9c62c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7c0fa428-a5c6-4f85-a313-fad191dff3d8', '8bec3fb9-fac7-4ee9-a8dc-8ecbd8422cc1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9b72760-9094-4cb4-8e0e-507ea304c190', '6782b7c5-7f85-4676-8b25-5e42bd760f1f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9b72760-9094-4cb4-8e0e-507ea304c190', 'bd114250-7f1c-4006-8e47-c4d95ad91568', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9b72760-9094-4cb4-8e0e-507ea304c190', 'a4ad49a4-f13b-4be5-92b9-27590f335641', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8bec3fb9-fac7-4ee9-a8dc-8ecbd8422cc1', '6782b7c5-7f85-4676-8b25-5e42bd760f1f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8bec3fb9-fac7-4ee9-a8dc-8ecbd8422cc1', 'bd114250-7f1c-4006-8e47-c4d95ad91568', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8bec3fb9-fac7-4ee9-a8dc-8ecbd8422cc1', 'a4ad49a4-f13b-4be5-92b9-27590f335641', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8bec3fb9-fac7-4ee9-a8dc-8ecbd8422cc1', '90615188-a65f-44e4-942d-ad35ddf9c62c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8bec3fb9-fac7-4ee9-a8dc-8ecbd8422cc1', '7c0fa428-a5c6-4f85-a313-fad191dff3d8', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d836356d-f6b0-4fbb-926e-2f210662cab6', '08cf0882-a474-4245-a53c-0419b6cfef0e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d836356d-f6b0-4fbb-926e-2f210662cab6', '6782b7c5-7f85-4676-8b25-5e42bd760f1f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d836356d-f6b0-4fbb-926e-2f210662cab6', 'bd114250-7f1c-4006-8e47-c4d95ad91568', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9a753a1e-d352-4dd9-b3c8-b8bac516a13e', '853ed6ff-7654-4b55-a4ff-010c2871982b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9a753a1e-d352-4dd9-b3c8-b8bac516a13e', 'bc0adcfd-9ca2-4f1e-864a-3e3f502f5e09', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9a753a1e-d352-4dd9-b3c8-b8bac516a13e', 'fca235c8-7e60-481a-ae15-4fd49bca7814', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9a753a1e-d352-4dd9-b3c8-b8bac516a13e', '20ee16f3-c014-409e-964c-60932cbdb1c7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9a753a1e-d352-4dd9-b3c8-b8bac516a13e', '574a6016-c862-40ea-8b2a-f4d4f851aceb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ad77336e-c72c-4604-b1a9-3d6130b46e3b', '55ed01b1-e535-4e41-acd8-13dad9b11b19', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ad77336e-c72c-4604-b1a9-3d6130b46e3b', 'd827f7ef-4ea2-4ae0-8913-fa5331302ada', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ad77336e-c72c-4604-b1a9-3d6130b46e3b', '6782b7c5-7f85-4676-8b25-5e42bd760f1f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('55ed01b1-e535-4e41-acd8-13dad9b11b19', 'ad77336e-c72c-4604-b1a9-3d6130b46e3b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('55ed01b1-e535-4e41-acd8-13dad9b11b19', 'd827f7ef-4ea2-4ae0-8913-fa5331302ada', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('55ed01b1-e535-4e41-acd8-13dad9b11b19', '6782b7c5-7f85-4676-8b25-5e42bd760f1f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d827f7ef-4ea2-4ae0-8913-fa5331302ada', 'ad77336e-c72c-4604-b1a9-3d6130b46e3b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d827f7ef-4ea2-4ae0-8913-fa5331302ada', '55ed01b1-e535-4e41-acd8-13dad9b11b19', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d827f7ef-4ea2-4ae0-8913-fa5331302ada', '6782b7c5-7f85-4676-8b25-5e42bd760f1f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('211054ad-84ff-4609-8e21-b4b43723feab', 'f935ae95-a906-4a53-bf40-629cdddbea18', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('211054ad-84ff-4609-8e21-b4b43723feab', 'b152309f-149a-4d69-9ea4-31df312794c9', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('211054ad-84ff-4609-8e21-b4b43723feab', 'e83b47cf-c2f2-4b2c-ade7-2706f1ce6bea', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('211054ad-84ff-4609-8e21-b4b43723feab', 'ffa011dc-3bcd-4e16-93d3-02237b1ac742', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f935ae95-a906-4a53-bf40-629cdddbea18', '211054ad-84ff-4609-8e21-b4b43723feab', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f935ae95-a906-4a53-bf40-629cdddbea18', 'b152309f-149a-4d69-9ea4-31df312794c9', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f935ae95-a906-4a53-bf40-629cdddbea18', 'e83b47cf-c2f2-4b2c-ade7-2706f1ce6bea', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f935ae95-a906-4a53-bf40-629cdddbea18', 'ffa011dc-3bcd-4e16-93d3-02237b1ac742', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b152309f-149a-4d69-9ea4-31df312794c9', '211054ad-84ff-4609-8e21-b4b43723feab', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b152309f-149a-4d69-9ea4-31df312794c9', 'f935ae95-a906-4a53-bf40-629cdddbea18', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b152309f-149a-4d69-9ea4-31df312794c9', 'e83b47cf-c2f2-4b2c-ade7-2706f1ce6bea', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b152309f-149a-4d69-9ea4-31df312794c9', 'ffa011dc-3bcd-4e16-93d3-02237b1ac742', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e83b47cf-c2f2-4b2c-ade7-2706f1ce6bea', '211054ad-84ff-4609-8e21-b4b43723feab', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e83b47cf-c2f2-4b2c-ade7-2706f1ce6bea', 'f935ae95-a906-4a53-bf40-629cdddbea18', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e83b47cf-c2f2-4b2c-ade7-2706f1ce6bea', 'b152309f-149a-4d69-9ea4-31df312794c9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e83b47cf-c2f2-4b2c-ade7-2706f1ce6bea', 'ffa011dc-3bcd-4e16-93d3-02237b1ac742', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ffa011dc-3bcd-4e16-93d3-02237b1ac742', '211054ad-84ff-4609-8e21-b4b43723feab', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ffa011dc-3bcd-4e16-93d3-02237b1ac742', 'f935ae95-a906-4a53-bf40-629cdddbea18', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ffa011dc-3bcd-4e16-93d3-02237b1ac742', 'b152309f-149a-4d69-9ea4-31df312794c9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ffa011dc-3bcd-4e16-93d3-02237b1ac742', 'e83b47cf-c2f2-4b2c-ade7-2706f1ce6bea', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('799855e3-c8d8-407b-b6a5-0fb5b93a223c', 'de3c3400-6508-4d4c-8fd4-18b4fad2a7f3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('799855e3-c8d8-407b-b6a5-0fb5b93a223c', 'd11e78a8-2a76-4f30-839b-ecf5aa6a4139', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('de3c3400-6508-4d4c-8fd4-18b4fad2a7f3', '799855e3-c8d8-407b-b6a5-0fb5b93a223c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('de3c3400-6508-4d4c-8fd4-18b4fad2a7f3', 'd11e78a8-2a76-4f30-839b-ecf5aa6a4139', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d11e78a8-2a76-4f30-839b-ecf5aa6a4139', '799855e3-c8d8-407b-b6a5-0fb5b93a223c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d11e78a8-2a76-4f30-839b-ecf5aa6a4139', 'de3c3400-6508-4d4c-8fd4-18b4fad2a7f3', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a392bf3b-3edb-4507-abc9-b6a10552bbd2', '1c40d006-2c7b-4c03-ab54-334d9db3a4a9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a392bf3b-3edb-4507-abc9-b6a10552bbd2', 'c5298e5b-9889-4d6c-a611-471ded9aa89f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a392bf3b-3edb-4507-abc9-b6a10552bbd2', '7fc4c740-f4c9-4d5f-b6a1-f24132ef85ef', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a392bf3b-3edb-4507-abc9-b6a10552bbd2', '89e44d85-4d83-41e1-9813-96c1b66c9c5c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a392bf3b-3edb-4507-abc9-b6a10552bbd2', '69c18108-c7d7-4409-836d-fdf84299ca0e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c5298e5b-9889-4d6c-a611-471ded9aa89f', '1c40d006-2c7b-4c03-ab54-334d9db3a4a9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c5298e5b-9889-4d6c-a611-471ded9aa89f', 'a392bf3b-3edb-4507-abc9-b6a10552bbd2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c5298e5b-9889-4d6c-a611-471ded9aa89f', '7fc4c740-f4c9-4d5f-b6a1-f24132ef85ef', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c5298e5b-9889-4d6c-a611-471ded9aa89f', '89e44d85-4d83-41e1-9813-96c1b66c9c5c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c5298e5b-9889-4d6c-a611-471ded9aa89f', '69c18108-c7d7-4409-836d-fdf84299ca0e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7fc4c740-f4c9-4d5f-b6a1-f24132ef85ef', '1c40d006-2c7b-4c03-ab54-334d9db3a4a9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7fc4c740-f4c9-4d5f-b6a1-f24132ef85ef', 'a392bf3b-3edb-4507-abc9-b6a10552bbd2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7fc4c740-f4c9-4d5f-b6a1-f24132ef85ef', 'c5298e5b-9889-4d6c-a611-471ded9aa89f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7fc4c740-f4c9-4d5f-b6a1-f24132ef85ef', '89e44d85-4d83-41e1-9813-96c1b66c9c5c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7fc4c740-f4c9-4d5f-b6a1-f24132ef85ef', '69c18108-c7d7-4409-836d-fdf84299ca0e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('69c18108-c7d7-4409-836d-fdf84299ca0e', '1c40d006-2c7b-4c03-ab54-334d9db3a4a9', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('69c18108-c7d7-4409-836d-fdf84299ca0e', '89e44d85-4d83-41e1-9813-96c1b66c9c5c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('69c18108-c7d7-4409-836d-fdf84299ca0e', 'a392bf3b-3edb-4507-abc9-b6a10552bbd2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('69c18108-c7d7-4409-836d-fdf84299ca0e', 'c5298e5b-9889-4d6c-a611-471ded9aa89f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('69c18108-c7d7-4409-836d-fdf84299ca0e', '7fc4c740-f4c9-4d5f-b6a1-f24132ef85ef', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('37b2fd10-3050-4069-af65-a3c8494d64ac', 'c889ca22-53bf-4a80-a02e-cc95bf0a77b4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('37b2fd10-3050-4069-af65-a3c8494d64ac', '42ae559b-3c32-4bb6-88a5-0f7eabc146cb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c889ca22-53bf-4a80-a02e-cc95bf0a77b4', '37b2fd10-3050-4069-af65-a3c8494d64ac', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c889ca22-53bf-4a80-a02e-cc95bf0a77b4', '42ae559b-3c32-4bb6-88a5-0f7eabc146cb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('42ae559b-3c32-4bb6-88a5-0f7eabc146cb', '37b2fd10-3050-4069-af65-a3c8494d64ac', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('42ae559b-3c32-4bb6-88a5-0f7eabc146cb', 'c889ca22-53bf-4a80-a02e-cc95bf0a77b4', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0a70e856-da1b-405e-9802-1e22ea1e1a12', '776a64b3-f85e-43fe-8959-63a3579c9226', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0a70e856-da1b-405e-9802-1e22ea1e1a12', '10c133f4-3e1d-4719-b18e-790c489e6930', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0a70e856-da1b-405e-9802-1e22ea1e1a12', '025983b2-fb85-4642-8a0f-c39690cd8e3f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('776a64b3-f85e-43fe-8959-63a3579c9226', '025983b2-fb85-4642-8a0f-c39690cd8e3f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('776a64b3-f85e-43fe-8959-63a3579c9226', '0a70e856-da1b-405e-9802-1e22ea1e1a12', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('776a64b3-f85e-43fe-8959-63a3579c9226', '10c133f4-3e1d-4719-b18e-790c489e6930', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('10c133f4-3e1d-4719-b18e-790c489e6930', '0a70e856-da1b-405e-9802-1e22ea1e1a12', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('10c133f4-3e1d-4719-b18e-790c489e6930', '776a64b3-f85e-43fe-8959-63a3579c9226', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('10c133f4-3e1d-4719-b18e-790c489e6930', '025983b2-fb85-4642-8a0f-c39690cd8e3f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('025983b2-fb85-4642-8a0f-c39690cd8e3f', '776a64b3-f85e-43fe-8959-63a3579c9226', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('025983b2-fb85-4642-8a0f-c39690cd8e3f', '0a70e856-da1b-405e-9802-1e22ea1e1a12', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('025983b2-fb85-4642-8a0f-c39690cd8e3f', '10c133f4-3e1d-4719-b18e-790c489e6930', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3befcd1c-681e-4a2b-b30d-469a3d7fb085', '8196ffd8-de45-4f82-abb9-7a60524515b2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3befcd1c-681e-4a2b-b30d-469a3d7fb085', 'c627201e-0128-4b45-a325-e11580c9425d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3befcd1c-681e-4a2b-b30d-469a3d7fb085', '89744779-51c2-4271-a56b-fcee29aa3cbd', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3befcd1c-681e-4a2b-b30d-469a3d7fb085', '1d291a92-f1b1-4db0-a5b3-673bf9ecb36c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3befcd1c-681e-4a2b-b30d-469a3d7fb085', '18210728-3d86-4d26-99d7-762d9ab399ad', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8196ffd8-de45-4f82-abb9-7a60524515b2', '3befcd1c-681e-4a2b-b30d-469a3d7fb085', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8196ffd8-de45-4f82-abb9-7a60524515b2', 'c627201e-0128-4b45-a325-e11580c9425d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8196ffd8-de45-4f82-abb9-7a60524515b2', '89744779-51c2-4271-a56b-fcee29aa3cbd', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8196ffd8-de45-4f82-abb9-7a60524515b2', '1d291a92-f1b1-4db0-a5b3-673bf9ecb36c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8196ffd8-de45-4f82-abb9-7a60524515b2', '18210728-3d86-4d26-99d7-762d9ab399ad', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c627201e-0128-4b45-a325-e11580c9425d', '134548eb-60b9-4c7b-95bb-c2d766faec2e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c627201e-0128-4b45-a325-e11580c9425d', '3befcd1c-681e-4a2b-b30d-469a3d7fb085', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c627201e-0128-4b45-a325-e11580c9425d', '8196ffd8-de45-4f82-abb9-7a60524515b2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c627201e-0128-4b45-a325-e11580c9425d', '89744779-51c2-4271-a56b-fcee29aa3cbd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c627201e-0128-4b45-a325-e11580c9425d', '1d291a92-f1b1-4db0-a5b3-673bf9ecb36c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89744779-51c2-4271-a56b-fcee29aa3cbd', '3befcd1c-681e-4a2b-b30d-469a3d7fb085', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89744779-51c2-4271-a56b-fcee29aa3cbd', '8196ffd8-de45-4f82-abb9-7a60524515b2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89744779-51c2-4271-a56b-fcee29aa3cbd', 'c627201e-0128-4b45-a325-e11580c9425d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89744779-51c2-4271-a56b-fcee29aa3cbd', '1d291a92-f1b1-4db0-a5b3-673bf9ecb36c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89744779-51c2-4271-a56b-fcee29aa3cbd', '18210728-3d86-4d26-99d7-762d9ab399ad', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1d291a92-f1b1-4db0-a5b3-673bf9ecb36c', '3befcd1c-681e-4a2b-b30d-469a3d7fb085', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1d291a92-f1b1-4db0-a5b3-673bf9ecb36c', '8196ffd8-de45-4f82-abb9-7a60524515b2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1d291a92-f1b1-4db0-a5b3-673bf9ecb36c', 'c627201e-0128-4b45-a325-e11580c9425d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1d291a92-f1b1-4db0-a5b3-673bf9ecb36c', '89744779-51c2-4271-a56b-fcee29aa3cbd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1d291a92-f1b1-4db0-a5b3-673bf9ecb36c', '18210728-3d86-4d26-99d7-762d9ab399ad', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('18210728-3d86-4d26-99d7-762d9ab399ad', '3befcd1c-681e-4a2b-b30d-469a3d7fb085', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('18210728-3d86-4d26-99d7-762d9ab399ad', '8196ffd8-de45-4f82-abb9-7a60524515b2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('18210728-3d86-4d26-99d7-762d9ab399ad', 'c627201e-0128-4b45-a325-e11580c9425d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('18210728-3d86-4d26-99d7-762d9ab399ad', '89744779-51c2-4271-a56b-fcee29aa3cbd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('18210728-3d86-4d26-99d7-762d9ab399ad', '1d291a92-f1b1-4db0-a5b3-673bf9ecb36c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6d81fa81-fd94-4f6a-a6d0-26993e97d508', '3befcd1c-681e-4a2b-b30d-469a3d7fb085', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6d81fa81-fd94-4f6a-a6d0-26993e97d508', '8196ffd8-de45-4f82-abb9-7a60524515b2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6d81fa81-fd94-4f6a-a6d0-26993e97d508', 'c627201e-0128-4b45-a325-e11580c9425d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6d81fa81-fd94-4f6a-a6d0-26993e97d508', '89744779-51c2-4271-a56b-fcee29aa3cbd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6d81fa81-fd94-4f6a-a6d0-26993e97d508', '1d291a92-f1b1-4db0-a5b3-673bf9ecb36c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('134548eb-60b9-4c7b-95bb-c2d766faec2e', 'c627201e-0128-4b45-a325-e11580c9425d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('134548eb-60b9-4c7b-95bb-c2d766faec2e', '3befcd1c-681e-4a2b-b30d-469a3d7fb085', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('134548eb-60b9-4c7b-95bb-c2d766faec2e', '8196ffd8-de45-4f82-abb9-7a60524515b2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('134548eb-60b9-4c7b-95bb-c2d766faec2e', '89744779-51c2-4271-a56b-fcee29aa3cbd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('134548eb-60b9-4c7b-95bb-c2d766faec2e', '1d291a92-f1b1-4db0-a5b3-673bf9ecb36c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d211c3f-00d0-4925-b675-d1043188c09f', '3befcd1c-681e-4a2b-b30d-469a3d7fb085', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d211c3f-00d0-4925-b675-d1043188c09f', '8196ffd8-de45-4f82-abb9-7a60524515b2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d211c3f-00d0-4925-b675-d1043188c09f', 'c627201e-0128-4b45-a325-e11580c9425d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d211c3f-00d0-4925-b675-d1043188c09f', '89744779-51c2-4271-a56b-fcee29aa3cbd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2d211c3f-00d0-4925-b675-d1043188c09f', '1d291a92-f1b1-4db0-a5b3-673bf9ecb36c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cbfbeffc-b548-474a-ab10-a0a28a7b7a66', '8b573091-8dfa-4c0f-bda5-c576513e5696', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8f5c2fd1-5012-44e9-b3be-7feab3b4aed6', '8b573091-8dfa-4c0f-bda5-c576513e5696', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a7b0b89-1957-47a7-ab90-80cd2bcc2793', '8b573091-8dfa-4c0f-bda5-c576513e5696', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('205622e7-a996-40f9-be6d-df8077f18227', '8b573091-8dfa-4c0f-bda5-c576513e5696', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ae417979-f142-484d-93ed-d889273386db', '8b573091-8dfa-4c0f-bda5-c576513e5696', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dbac4b5f-881a-4c5d-8537-47197e329432', '8b573091-8dfa-4c0f-bda5-c576513e5696', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('25256958-b577-45ca-afed-d68e2c379ae0', '0a15de10-121f-4ccf-86b7-7b3d99f9d1e5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('25256958-b577-45ca-afed-d68e2c379ae0', '234787c2-fdb8-4342-8858-d679274c1409', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('25256958-b577-45ca-afed-d68e2c379ae0', '0fb47938-8cde-4f23-bf31-494d40c22af7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0a15de10-121f-4ccf-86b7-7b3d99f9d1e5', '25256958-b577-45ca-afed-d68e2c379ae0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0a15de10-121f-4ccf-86b7-7b3d99f9d1e5', '234787c2-fdb8-4342-8858-d679274c1409', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0a15de10-121f-4ccf-86b7-7b3d99f9d1e5', '0fb47938-8cde-4f23-bf31-494d40c22af7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('234787c2-fdb8-4342-8858-d679274c1409', '0fb47938-8cde-4f23-bf31-494d40c22af7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('234787c2-fdb8-4342-8858-d679274c1409', '25256958-b577-45ca-afed-d68e2c379ae0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('234787c2-fdb8-4342-8858-d679274c1409', '0a15de10-121f-4ccf-86b7-7b3d99f9d1e5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0fb47938-8cde-4f23-bf31-494d40c22af7', '234787c2-fdb8-4342-8858-d679274c1409', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0fb47938-8cde-4f23-bf31-494d40c22af7', '25256958-b577-45ca-afed-d68e2c379ae0', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0fb47938-8cde-4f23-bf31-494d40c22af7', '0a15de10-121f-4ccf-86b7-7b3d99f9d1e5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9b6932fe-c602-47b7-8e66-82bbb78e5b8d', '311ee988-ffd9-4b5a-b296-d702906dce9d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9b6932fe-c602-47b7-8e66-82bbb78e5b8d', '98bacc93-a7cb-4f7d-a3c5-a6b8da4d782e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b90ca25b-8e4c-46da-bc28-16e1f11ff137', '9b6932fe-c602-47b7-8e66-82bbb78e5b8d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b90ca25b-8e4c-46da-bc28-16e1f11ff137', '311ee988-ffd9-4b5a-b296-d702906dce9d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b90ca25b-8e4c-46da-bc28-16e1f11ff137', '98bacc93-a7cb-4f7d-a3c5-a6b8da4d782e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d4f9199e-7edf-4688-8819-90fd9f437c3e', '9b6932fe-c602-47b7-8e66-82bbb78e5b8d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d4f9199e-7edf-4688-8819-90fd9f437c3e', '311ee988-ffd9-4b5a-b296-d702906dce9d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d4f9199e-7edf-4688-8819-90fd9f437c3e', '98bacc93-a7cb-4f7d-a3c5-a6b8da4d782e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('311ee988-ffd9-4b5a-b296-d702906dce9d', '9b6932fe-c602-47b7-8e66-82bbb78e5b8d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('311ee988-ffd9-4b5a-b296-d702906dce9d', '98bacc93-a7cb-4f7d-a3c5-a6b8da4d782e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('441e6059-5038-42ec-9709-8d944df11879', '9b6932fe-c602-47b7-8e66-82bbb78e5b8d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('441e6059-5038-42ec-9709-8d944df11879', '311ee988-ffd9-4b5a-b296-d702906dce9d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('441e6059-5038-42ec-9709-8d944df11879', '98bacc93-a7cb-4f7d-a3c5-a6b8da4d782e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c27557c-3cb4-4840-8c93-1fdcc1dbd0d8', '9b6932fe-c602-47b7-8e66-82bbb78e5b8d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c27557c-3cb4-4840-8c93-1fdcc1dbd0d8', '311ee988-ffd9-4b5a-b296-d702906dce9d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4c27557c-3cb4-4840-8c93-1fdcc1dbd0d8', '98bacc93-a7cb-4f7d-a3c5-a6b8da4d782e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('98bacc93-a7cb-4f7d-a3c5-a6b8da4d782e', '9b6932fe-c602-47b7-8e66-82bbb78e5b8d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('98bacc93-a7cb-4f7d-a3c5-a6b8da4d782e', '311ee988-ffd9-4b5a-b296-d702906dce9d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4502580f-10f5-461c-804f-a1b0f28cdaaf', '9b6932fe-c602-47b7-8e66-82bbb78e5b8d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4502580f-10f5-461c-804f-a1b0f28cdaaf', '311ee988-ffd9-4b5a-b296-d702906dce9d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4502580f-10f5-461c-804f-a1b0f28cdaaf', '98bacc93-a7cb-4f7d-a3c5-a6b8da4d782e', 2) ON CONFLICT DO NOTHING;



INSERT INTO public.faqs VALUES ('3635743b-83c6-48e6-a916-06e1b7e38f0d', 'متى يوصلني الرد بعد الاشتراك؟', 'خلال 48 ساعة عمل. أيام العمل من الأحد إلى الخميس، من 12 الظهر حتى 9 مساءً، والتواصل على واتساب.', 0, true, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('061f73ce-5d4d-471f-bdb7-586e65773386', 'كيف تتم المتابعة؟', 'ترسل مراجعتك الأسبوعية في يوم المراجعة، وأرد عليك بتعديلات مسجلة (فيديو أو صوت). في الباقة الأساسية المتابعة كل أسبوعين. التواصل اليومي على واتساب مع رد خلال 48 ساعة.', 1, true, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('5e281454-07f4-471a-900d-be340625b524', 'أنا مبتدئ تماماً، هل يناسبني؟', 'نعم. البرنامج يُبنى على مستواك الحالي، والتمارين مشروحة، وتقدر ترسل مقاطع أدائك لتصحيح التكنيك.', 2, true, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('e22f6046-db69-4a92-ad64-f3b97d779c66', 'أتمرن في البيت، ماذا أحتاج من أدوات؟', 'تحدد في النموذج الأدوات المتوفرة عندك (دمبلز، حبال مقاومة، بار…) ويُبنى جدولك عليها.', 3, true, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('611a8a7d-656b-47f2-919a-70d1c24e297f', 'كيف أدفع؟', 'بتحويل بنكي بعد تعبئة الاستبيان. أول ما ترسل الاستبيان يظهر لك رقم طلبك والمبلغ وبيانات الحساب. حوّل المبلغ وارفع صورة الإيصال من صفحة طلبك، ويتأكد اشتراكك بعد التحقق من وصول المبلغ.', 4, true, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('2fa01a51-7945-4680-8bcc-d311a4ccbcb0', 'ما شروط ضمان استرجاع المبلغ؟', 'في اشتراكات 3 أشهر لباقات المتابعة (المكثفة، المتقدمة، الأساسية): إذا لم يتحسن أي مؤشر من مؤشرات تقدمك بعد 12 أسبوعاً، يرجع لك المبلغ كاملاً.
مؤشرات التقدم (بحسب هدفك): متوسط الوزن الأسبوعي، أو محيط الخصر، أو القوة في التمارين الأساسية (الوزن أو التكرارات).
شروط الضمان:
- إرسال المراجعة الأسبوعية كل أسبوع.
- أخذ القياسات بانتظام.
- تصوير التمارين وإرسالها.
- الالتزام بجدول التغذية المخصص (في الباقات التي تشمل تغذية).
يُطلب الاسترجاع عبر واتساب خلال 14 يوماً من نهاية الأشهر الثلاثة.', 5, true, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('54ee4c2a-64d2-4df1-8d7c-02f813e74fa1', 'هل الجداول لي بعد انتهاء الاشتراك؟', 'نعم، جميع الجداول لك مدى الحياة وتقدر تعدّل عليها.', 6, true, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('04ebaf1f-dc0e-45ae-a048-76de813f6632', 'ما هو التجديد المجاني؟', 'مكافأة للملتزمين: إذا كان اشتراكك 3 أشهر تحصل على 3 أشهر إضافية مجاناً، فيصير المجموع 6 أشهر بسعر 3.
الشروط:
- نسبة التزام 90% فأكثر: المراجعات الأسبوعية المرسلة والتمارين المسجلة.
- تقدم واضح في مؤشرات التقدم نفسها المذكورة في الضمان.
- للمتدربين الرجال: إرسال صور التطور (قبل وبعد) للمدربة للتوثيق، مع تغطية الوجه والسرة.
نشر الصور في السوشل ميديا اختياري بالكامل حسب موافقتك، ولا يؤثر على استحقاقك للتجديد.', 7, true, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('4078c3fa-ea8f-4dea-a5c3-e29fc92b4f84', 'من يطّلع على بياناتي؟', 'المدربة فقط، وتُستخدم لتصميم برنامجك ومتابعتك. لا تُنشر نتيجتك أو صورتك إلا بموافقتك الصريحة في النموذج.', 8, true, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;



INSERT INTO public.foods VALUES ('89e91990-27c2-470b-9fcd-390cb4a17e14', 'حليب بروتين سادة (ندى 320 مل)', 'Nada Protein Plain Milk 320ml', 'مشروبات بروتينية', 60.0, 8.5, 8.7, 0.1, 320.0, 'عبوة 320 مل', 'coach', 'nada.com.sa/protein-plain-milk', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('fce18083-2481-492d-9745-02125b1d0836', 'رز أبيض مطبوخ', 'Rice, white, long-grain, regular, enriched, cooked', 'حبوب ونشويات', 130.0, 2.7, 28.2, 0.3, 150.0, 'كوب إلا ربع', 'usda', '168878', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'حبوب ونشويات', 0.4, '{"iron": 1.2, "zinc": 0.49, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.04, "vit_k": 0, "folate": 97, "vit_b6": 0.093, "calcium": 10, "vit_b12": 0, "magnesium": 12, "potassium": 35}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('60c23c11-359a-41a2-837e-51e658234157', 'رز بني مطبوخ', 'Rice, brown, long-grain, cooked (Includes foods for USDA''s Food Distribution Program)', 'حبوب ونشويات', 123.0, 2.7, 25.6, 1.0, 150.0, NULL, 'usda', '169704', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'حبوب ونشويات', 1.6, '{"iron": 0.56, "zinc": 0.71, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.17, "vit_k": 0.2, "folate": 9, "vit_b6": 0.123, "calcium": 3, "vit_b12": 0, "magnesium": 39, "potassium": 86}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('7cc39870-b5a3-424a-b846-0f0022aad392', 'رز أبيض (غير مطبوخ)', 'Rice, white, long-grain, regular, raw, enriched', 'حبوب ونشويات', 365.0, 7.1, 80.0, 0.7, 75.0, NULL, 'usda', '168877', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'حبوب ونشويات', 1.3, '{"iron": 4.31, "zinc": 1.09, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.11, "vit_k": 0.1, "folate": 387, "vit_b6": 0.164, "calcium": 28, "vit_b12": 0, "magnesium": 25, "potassium": 115}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('e746badc-1e93-44f3-9ef3-805f1f2f1b27', 'مكرونة مطبوخة', 'Pasta, cooked, enriched, without added salt', 'حبوب ونشويات', 158.0, 5.8, 30.9, 0.9, 140.0, 'كوب', 'usda', '169737', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'حبوب ونشويات', 1.8, '{"iron": 1.28, "zinc": 0.51, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.06, "vit_k": 0, "folate": 119, "vit_b6": 0.049, "calcium": 7, "vit_b12": 0, "magnesium": 18, "potassium": 44}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3cf985aa-1d83-49dd-90a9-4efde3b37425', 'مكرونة (غير مطبوخة)', 'Pasta, dry, enriched', 'حبوب ونشويات', 371.0, 13.0, 74.7, 1.5, 75.0, NULL, 'usda', '169736', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'حبوب ونشويات', 3.2, '{"iron": 3.3, "zinc": 1.41, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.11, "vit_k": 0.1, "folate": 391, "vit_b6": 0.142, "calcium": 21, "vit_b12": 0, "magnesium": 53, "potassium": 223}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3c1bd8a6-5c0e-4302-8ab5-02aeba9e3dbf', 'شوفان', 'Cereals, oats, regular and quick, not fortified, dry', 'حبوب ونشويات', 379.0, 13.2, 67.7, 6.5, 40.0, 'نص كوب', 'usda', '173904', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'حبوب ونشويات', 10.1, '{"iron": 4.25, "zinc": 3.64, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.42, "vit_k": 2, "folate": 32, "vit_b6": 0.1, "calcium": 52, "vit_b12": 0, "magnesium": 138, "potassium": 362}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('76206aa8-fd73-4237-845b-735f9b8b2f5f', 'خبز أبيض (توست)', 'Bread, white, commercially prepared (includes soft bread crumbs)', 'خبز', 266.0, 8.9, 49.4, 3.3, 28.0, 'شريحة', 'usda', '174924', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'حبوب ونشويات', 2.7, '{"iron": 3.61, "zinc": 0.74, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.22, "vit_k": 0.2, "folate": 171, "vit_b6": 0.087, "calcium": 144, "vit_b12": 0, "magnesium": 23, "potassium": 126}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('0a763244-e994-4283-8929-f80fcd9a04c4', 'خبز بر (توست أسمر)', 'Bread, whole-wheat, commercially prepared', 'خبز', 252.0, 12.5, 42.7, 3.5, 32.0, 'شريحة', 'usda', '172688', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'حبوب ونشويات', 6.0, '{"iron": 2.47, "zinc": 1.77, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 2.66, "vit_k": 7.8, "folate": 42, "vit_b6": 0.215, "calcium": 161, "vit_b12": 0, "magnesium": 75, "potassium": 254}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('0822eab3-23d4-4c87-871c-6cdc99bfd152', 'خبز عربي أبيض', 'Bread, pita, white, enriched', 'خبز', 275.0, 9.1, 55.7, 1.2, 60.0, 'رغيف صغير', 'usda', '174915', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'حبوب ونشويات', 2.2, '{"iron": 2.62, "zinc": 0.84, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.3, "vit_k": 0.2, "folate": 165, "vit_b6": 0.034, "calcium": 86, "vit_b12": 0, "magnesium": 26, "potassium": 120}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('4ad511aa-55c8-481b-8739-ab644e7b4d5d', 'خبز عربي بر', 'Bread, pita, whole-wheat', 'خبز', 262.0, 9.8, 55.9, 1.7, 64.0, 'رغيف صغير', 'usda', '174916', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'حبوب ونشويات', 6.1, '{"iron": 3.06, "zinc": 1.52, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.61, "vit_k": 1.4, "folate": 35, "vit_b6": 0.265, "calcium": 15, "vit_b12": 0, "magnesium": 69, "potassium": 170}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('c3766d10-b8f8-46e0-aef2-255b359b52b0', 'تورتيلا قمح', 'Tortillas, ready-to-bake or -fry, flour, refrigerated', 'خبز', 306.0, 8.2, 49.4, 8.0, 45.0, 'حبة', 'usda', '175037', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'حبوب ونشويات', 3.5, '{"iron": 3.63, "zinc": 0.53, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0, "vit_k": 7.2, "folate": 149, "vit_b6": 0.059, "calcium": 146, "vit_b12": 0, "magnesium": 22, "potassium": 125}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('4f09fb09-bd3d-462a-949f-0a57add888a1', 'بطاطس مسلوقة', 'Potatoes, boiled, cooked without skin, flesh, without salt', 'حبوب ونشويات', 86.0, 1.7, 20.0, 0.1, 150.0, 'حبة وسط', 'usda', '170440', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'خضار نشوية', 1.8, '{"iron": 0.31, "zinc": 0.27, "vit_a": 0, "vit_c": 7.4, "vit_d": 0, "vit_e": 0.01, "vit_k": 2.2, "folate": 9, "vit_b6": 0.269, "calcium": 8, "vit_b12": 0, "magnesium": 20, "potassium": 328}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('fa4c14a4-a81c-493d-b1c7-f9b712407a0e', 'بطاطا حلوة مشوية', 'Sweet potato, cooked, baked in skin, flesh, without salt', 'حبوب ونشويات', 90.0, 2.0, 20.7, 0.2, 150.0, 'حبة وسط', 'usda', '168483', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'خضار نشوية', 3.3, '{"iron": 0.69, "zinc": 0.32, "vit_a": 961, "vit_c": 19.6, "vit_d": 0, "vit_e": 0.71, "vit_k": 2.3, "folate": 6, "vit_b6": 0.286, "calcium": 38, "vit_b12": 0, "magnesium": 27, "potassium": 475}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('2f365427-3dfb-4a34-9013-c5a528c2a562', 'برغل مطبوخ', 'Bulgur, cooked', 'حبوب ونشويات', 83.0, 3.1, 18.6, 0.2, 150.0, NULL, 'usda', '170287', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'حبوب ونشويات', 4.5, '{"iron": 0.96, "zinc": 0.57, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.01, "vit_k": 0.5, "folate": 18, "vit_b6": 0.083, "calcium": 10, "vit_b12": 0, "magnesium": 32, "potassium": 68}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('63097ac5-4a55-4787-bc11-71f192601fdd', 'كينوا مطبوخة', 'Quinoa, cooked', 'حبوب ونشويات', 120.0, 4.4, 21.3, 1.9, 150.0, NULL, 'usda', '168917', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'حبوب ونشويات', 2.8, '{"iron": 1.49, "zinc": 1.09, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.63, "vit_k": 0, "folate": 42, "vit_b6": 0.123, "calcium": 17, "vit_b12": 0, "magnesium": 64, "potassium": 172}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('7de22e02-e309-4fcd-bd74-7cb52efe0e57', 'كورن فليكس', 'Cereals ready-to-eat, RALSTON Corn Flakes', 'حبوب ونشويات', 384.0, 5.9, 88.0, 0.9, 30.0, NULL, 'usda', '174648', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'حبوب ونشويات', 2.7, '{"iron": 19.4, "zinc": 0.2, "vit_a": 981, "vit_c": 65, "vit_d": 7.1, "vit_e": 0.02, "vit_k": 0, "vit_b6": 1.907, "calcium": 2, "vit_b12": 5.36, "magnesium": 7, "potassium": 107}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('70d8c80d-d95f-4951-8b12-e40af97688c8', 'صدر دجاج مشوي', 'Chicken, broilers or fryers, breast, meat only, cooked, roasted', 'لحوم ودواجن', 165.0, 31.0, 0.0, 3.6, 100.0, NULL, 'usda', '171477', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'لحوم بيضاء (دواجن)', 0.0, '{"iron": 1.04, "zinc": 1, "vit_a": 6, "vit_c": 0, "vit_d": 0.1, "vit_e": 0.27, "vit_k": 0.3, "folate": 4, "vit_b6": 0.6, "calcium": 15, "vit_b12": 0.34, "magnesium": 29, "potassium": 256}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('1b5fe9a8-5eb3-45c4-ac4e-4f4a298bcd55', 'صدر دجاج نيء', 'Chicken, broiler or fryers, breast, skinless, boneless, meat only, raw', 'لحوم ودواجن', 120.0, 22.5, 0.0, 2.6, 150.0, NULL, 'usda', '171077', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'لحوم بيضاء (دواجن)', 0.0, '{"iron": 0.37, "zinc": 0.68, "vit_a": 9, "vit_c": 0, "vit_d": 0, "vit_e": 0.56, "vit_k": 0, "folate": 9, "vit_b6": 0.811, "calcium": 5, "vit_b12": 0.21, "magnesium": 28, "potassium": 334}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('27810f89-790d-4b2c-865f-d42feba2d732', 'فخذ دجاج مشوي (بدون جلد)', 'Chicken, broilers or fryers, thigh, meat only, cooked, roasted', 'لحوم ودواجن', 179.0, 24.8, 0.0, 8.2, 100.0, NULL, 'usda', '172388', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'لحوم بيضاء (دواجن)', 0.0, '{"iron": 1.13, "zinc": 1.92, "vit_a": 8, "vit_c": 0, "vit_d": 0.2, "vit_e": 0.18, "vit_k": 3.9, "folate": 5, "vit_b6": 0.462, "calcium": 9, "vit_b12": 0.42, "magnesium": 24, "potassium": 269}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('9ed5b1ec-7656-42c8-b02c-fca0bce2f9ab', 'لحم بقري مفروم 90% مطبوخ', 'Beef, ground, 90% lean meat / 10% fat, patty, cooked, broiled', 'لحوم ودواجن', 217.0, 26.1, 0.0, 11.8, 100.0, NULL, 'usda', '174031', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'لحوم حمراء', 0.0, '{"iron": 2.71, "zinc": 6.37, "vit_a": 3, "vit_c": 0, "vit_d": 0, "vit_e": 0.12, "vit_k": 1.1, "folate": 8, "vit_b6": 0.397, "calcium": 13, "vit_b12": 2.56, "magnesium": 22, "potassium": 333}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('4560d2b3-22c7-4ded-a6ec-fc0bf0039e95', 'لحم بقري مفروم 80% مطبوخ', 'Beef, ground, 80% lean meat / 20% fat, patty, cooked, broiled', 'لحوم ودواجن', 270.0, 25.8, 0.0, 17.8, 100.0, NULL, 'usda', '171797', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'لحوم حمراء', 0.0, '{"iron": 2.48, "zinc": 6.25, "vit_a": 3, "vit_c": 0, "vit_d": 0, "vit_e": 0.12, "vit_k": 1.6, "folate": 10, "vit_b6": 0.366, "calcium": 24, "vit_b12": 2.73, "magnesium": 20, "potassium": 304}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('4b008812-18f6-45f9-98f6-33e1bf5a3994', 'لحم غنم مطبوخ', 'Lamb, composite of trimmed retail cuts, separable lean only, trimmed to 1/4" fat, choice, cooked', 'لحوم ودواجن', 206.0, 28.2, 0.0, 9.5, 100.0, NULL, 'usda', '174308', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'لحوم حمراء', 0.0, '{"iron": 2.05, "zinc": 5.27, "vit_a": 0, "vit_c": 0, "vit_e": 0.19, "folate": 23, "vit_b6": 0.16, "calcium": 15, "vit_b12": 2.61, "magnesium": 26, "potassium": 344}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('486c2c18-3cca-4889-96af-0cb10f9ecac7', 'ديك رومي (شرائح)', 'Turkey, whole, breast, meat only, cooked, roasted', 'لحوم ودواجن', 147.0, 30.1, 0.0, 2.1, 50.0, NULL, 'usda', '171496', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'لحوم بيضاء (دواجن)', 0.0, '{"iron": 0.71, "zinc": 1.72, "vit_a": 3, "vit_c": 0, "vit_d": 0.3, "vit_e": 0.06, "vit_k": 0, "folate": 9, "vit_b6": 0.807, "calcium": 9, "vit_b12": 0.39, "magnesium": 32, "potassium": 249}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a4676ff7-ddf7-42ab-8141-c8c935638bdd', 'تونة معلبة بالماء', 'Fish, tuna, light, canned in water, drained solids (Includes foods for USDA''s Food Distribution Program)', 'أسماك', 86.0, 19.4, 0.0, 1.0, 100.0, 'علبة صغيرة مصفاة', 'usda', '173709', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'أسماك ومأكولات بحرية', 0.0, '{"iron": 1.63, "zinc": 0.69, "vit_a": 17, "vit_c": 0, "vit_d": 1.2, "vit_e": 0.33, "vit_k": 0.2, "folate": 4, "vit_b6": 0.319, "calcium": 17, "vit_b12": 2.55, "magnesium": 23, "potassium": 179}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('90a6b56e-9acd-4a79-8a77-1a2e37c326da', 'تونة معلبة بالزيت', 'Fish, tuna, light, canned in oil, drained solids', 'أسماك', 198.0, 29.1, 0.0, 8.2, 100.0, NULL, 'usda', '173708', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'أسماك ومأكولات بحرية', 0.0, '{"iron": 1.39, "zinc": 0.9, "vit_a": 23, "vit_c": 0, "vit_d": 6.7, "vit_e": 0.87, "vit_k": 44, "folate": 5, "vit_b6": 0.11, "calcium": 13, "vit_b12": 2.2, "magnesium": 31, "potassium": 207}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('bc1cc0ae-7efb-439d-a97e-f37a343f540e', 'سلمون مطبوخ', 'Fish, salmon, Atlantic, farmed, cooked, dry heat', 'أسماك', 206.0, 22.1, 0.0, 12.4, 120.0, NULL, 'usda', '175168', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'أسماك ومأكولات بحرية', 0.0, '{"iron": 0.34, "zinc": 0.43, "vit_a": 69, "vit_c": 3.7, "vit_d": 13.1, "vit_e": 1.14, "vit_k": 0.1, "folate": 34, "vit_b6": 0.647, "calcium": 15, "vit_b12": 2.8, "magnesium": 30, "potassium": 384}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('de5afc2e-2664-408e-9e3a-142741a59f28', 'سلمون مدخن', 'Fish, salmon, chinook, smoked', 'أسماك', 117.0, 18.3, 0.0, 4.3, 60.0, NULL, 'usda', '173687', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'أسماك ومأكولات بحرية', 0.0, '{"iron": 0.85, "zinc": 0.31, "vit_a": 26, "vit_c": 0, "vit_d": 17.1, "vit_e": 1.35, "vit_k": 0.1, "folate": 2, "vit_b6": 0.278, "calcium": 11, "vit_b12": 3.26, "magnesium": 18, "potassium": 175}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('0d0048f1-138b-4ed6-a08a-0757525a0ba0', 'روبيان مطبوخ', 'Crustaceans, shrimp, cooked', 'أسماك', 99.0, 24.0, 0.2, 0.3, 100.0, NULL, 'usda', '175180', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'أسماك ومأكولات بحرية', 0.0, '{"iron": 0.51, "zinc": 1.64, "calcium": 70, "magnesium": 39, "potassium": 259}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('5075d386-64aa-4f97-a62e-cbd7640dd9a2', 'هامور/سمك أبيض مطبوخ', 'Fish, grouper, mixed species, cooked, dry heat', 'أسماك', 118.0, 24.8, 0.0, 1.3, 150.0, NULL, 'usda', '171963', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'أسماك ومأكولات بحرية', 0.0, '{"iron": 1.14, "zinc": 0.51, "vit_a": 50, "vit_c": 0, "folate": 10, "vit_b6": 0.35, "calcium": 21, "vit_b12": 0.69, "magnesium": 37, "potassium": 475}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('96855aa2-5475-41ee-b98f-ed084946a796', 'بيض كامل', 'Egg, whole, raw, fresh', 'بيض وألبان', 143.0, 12.6, 0.7, 9.5, 50.0, 'بيضة', 'usda', '171287', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'بيض', 0.0, '{"iron": 1.75, "zinc": 1.29, "vit_a": 160, "vit_c": 0, "vit_d": 2, "vit_e": 1.05, "vit_k": 0.3, "folate": 47, "vit_b6": 0.17, "calcium": 56, "vit_b12": 0.89, "magnesium": 12, "potassium": 138}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('e10a23c7-c756-445e-8d85-a38c11c77842', 'بياض بيض', 'Egg, white, raw, fresh', 'بيض وألبان', 52.0, 10.9, 0.7, 0.2, 33.0, 'بياض بيضة', 'usda', '172183', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'بيض', 0.0, '{"iron": 0.08, "zinc": 0.03, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0, "vit_k": 0, "folate": 4, "vit_b6": 0.005, "calcium": 7, "vit_b12": 0.09, "magnesium": 11, "potassium": 163}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('2adc2356-968d-4247-a255-ee39021c40a4', 'بيض مسلوق', 'Egg, whole, cooked, hard-boiled', 'بيض وألبان', 155.0, 12.6, 1.1, 10.6, 50.0, 'بيضة', 'usda', '173424', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'بيض', 0.0, '{"iron": 1.19, "zinc": 1.05, "vit_a": 149, "vit_c": 0, "vit_d": 2.2, "vit_e": 1.03, "vit_k": 0.3, "folate": 44, "vit_b6": 0.121, "calcium": 50, "vit_b12": 1.11, "magnesium": 10, "potassium": 126}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('375beaea-1dca-475c-9570-dcb9bb318a45', 'حليب كامل الدسم', 'Milk, whole, 3.25% milkfat, with added vitamin D', 'بيض وألبان', 61.0, 3.2, 4.8, 3.3, 244.0, 'كوب', 'usda', '171265', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', 0.0, '{"iron": 0.03, "zinc": 0.37, "vit_a": 46, "vit_c": 0, "vit_d": 1.3, "vit_e": 0.07, "vit_k": 0.3, "folate": 5, "vit_b6": 0.036, "calcium": 113, "vit_b12": 0.45, "magnesium": 10, "potassium": 132}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('7973810e-6edd-4ec8-bf3e-33f0bfdde995', 'حليب قليل الدسم 1%', 'Milk, lowfat, fluid, 1% milkfat, with added vitamin A and vitamin D', 'بيض وألبان', 42.0, 3.4, 5.0, 1.0, 244.0, 'كوب', 'usda', '170872', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', 0.0, '{"iron": 0.03, "zinc": 0.42, "vit_a": 58, "vit_c": 0, "vit_d": 1.2, "vit_e": 0.01, "vit_k": 0.1, "folate": 5, "vit_b6": 0.037, "calcium": 125, "vit_b12": 0.47, "magnesium": 11, "potassium": 150}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('70c57379-3be2-46a7-85b3-2d38326a8466', 'حليب خالي الدسم', 'Milk, nonfat, fluid, with added vitamin A and vitamin D (fat free or skim)', 'بيض وألبان', 34.0, 3.4, 5.0, 0.1, 245.0, 'كوب', 'usda', '171269', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', 0.0, '{"iron": 0.03, "zinc": 0.42, "vit_a": 61, "vit_c": 0, "vit_d": 1.2, "vit_e": 0.01, "vit_k": 0, "folate": 5, "vit_b6": 0.037, "calcium": 122, "vit_b12": 0.5, "magnesium": 11, "potassium": 156}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d2d95d1c-ec28-4abc-be8e-f83f9c585061', 'زبادي كامل الدسم', 'Yogurt, plain, whole milk', 'بيض وألبان', 61.0, 3.5, 4.7, 3.3, 170.0, NULL, 'usda', '171284', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', 0.0, '{"iron": 0.05, "zinc": 0.59, "vit_a": 27, "vit_c": 0.5, "vit_d": 0.1, "vit_e": 0.06, "vit_k": 0.2, "folate": 7, "vit_b6": 0.032, "calcium": 121, "vit_b12": 0.37, "magnesium": 12, "potassium": 155}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ea98ac43-c52e-44a5-ae6f-2f473d41cd8c', 'زبادي قليل الدسم', 'Yogurt, plain, low fat', 'بيض وألبان', 63.0, 5.3, 7.0, 1.6, 170.0, NULL, 'usda', '170886', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', 0.0, '{"iron": 0.08, "zinc": 0.89, "vit_a": 14, "vit_c": 0.8, "vit_d": 0, "vit_e": 0.03, "vit_k": 0.2, "folate": 11, "vit_b6": 0.049, "calcium": 183, "vit_b12": 0.56, "magnesium": 17, "potassium": 234}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3eba927f-d418-4db7-9562-e992ce49661d', 'زبادي يوناني قليل الدسم', 'Yogurt, Greek, plain, lowfat', 'بيض وألبان', 73.0, 10.0, 3.9, 1.9, 170.0, NULL, 'usda', '170903', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', 0.0, '{"iron": 0.04, "zinc": 0.6, "vit_a": 90, "vit_c": 0.8, "vit_d": 0, "vit_e": 0.04, "vit_k": 0.2, "folate": 12, "vit_b6": 0.055, "calcium": 115, "vit_b12": 0.52, "magnesium": 11, "potassium": 141}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d28f71db-fa4d-4092-a152-47b271b1559e', 'زبادي يوناني خالي الدسم', 'Yogurt, Greek, plain, nonfat (Includes foods for USDA''s Food Distribution Program)', 'بيض وألبان', 59.0, 10.2, 3.6, 0.4, 170.0, NULL, 'usda', '170894', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', 0.0, '{"iron": 0.07, "zinc": 0.52, "vit_a": 1, "vit_c": 0, "vit_d": 0, "vit_e": 0.01, "vit_k": 0, "folate": 7, "vit_b6": 0.063, "calcium": 110, "vit_b12": 0.75, "magnesium": 11, "potassium": 141}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('650a9067-8c8e-4a93-b6f1-25d8c666afc5', 'جبنة قريش (كوتج)', 'Cheese, cottage, lowfat, 2% milkfat', 'بيض وألبان', 81.0, 10.5, 4.8, 2.3, 113.0, 'نص كوب', 'usda', '172182', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', 0.0, '{"iron": 0.13, "zinc": 0.51, "vit_a": 68, "vit_c": 0, "vit_d": 0, "vit_e": 0.08, "vit_k": 0, "folate": 8, "vit_b6": 0.057, "calcium": 111, "vit_b12": 0.47, "magnesium": 9, "potassium": 125}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a880f82a-8d29-4228-b7a9-5ebbf9d96aa1', 'جبنة موزاريلا قليلة الدسم', 'Cheese, mozzarella, part skim milk', 'بيض وألبان', 254.0, 24.3, 2.8, 15.9, 28.0, NULL, 'usda', '170847', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', 0.0, '{"iron": 0.22, "zinc": 2.76, "vit_a": 127, "vit_c": 0, "vit_d": 0.3, "vit_e": 0.14, "vit_k": 1.6, "folate": 9, "vit_b6": 0.07, "calcium": 782, "vit_b12": 0.82, "magnesium": 23, "potassium": 84}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d4a30cae-ef4b-44f3-8ada-a632c3ad8016', 'جبنة شيدر', 'Cheese, cheddar (Includes foods for USDA''s Food Distribution Program)', 'بيض وألبان', 403.0, 22.9, 3.4, 33.3, 28.0, 'شريحة', 'usda', '173414', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', 0.0, '{"iron": 0.14, "zinc": 3.64, "vit_a": 337, "vit_c": 0, "vit_d": 0.6, "vit_e": 0.71, "vit_k": 2.4, "folate": 27, "vit_b6": 0.066, "calcium": 710, "vit_b12": 1.1, "magnesium": 27, "potassium": 76}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('019afddf-415c-482a-abd7-06b677c42f1e', 'جبنة فيتا', 'Cheese, feta', 'بيض وألبان', 265.0, 14.2, 3.9, 21.5, 28.0, NULL, 'usda', '173420', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', 0.0, '{"iron": 0.65, "zinc": 2.88, "vit_a": 125, "vit_c": 0, "vit_d": 0.4, "vit_e": 0.18, "vit_k": 1.8, "folate": 32, "vit_b6": 0.424, "calcium": 493, "vit_b12": 1.69, "magnesium": 19, "potassium": 62}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3ac312c4-69a1-4937-8163-79bcb46a8cbd', 'جبنة كريمية', 'Cheese, cream', 'بيض وألبان', 350.0, 6.2, 5.5, 34.4, 30.0, NULL, 'usda', '173418', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', 0.0, '{"iron": 0.11, "zinc": 0.5, "vit_a": 308, "vit_c": 0, "vit_d": 0, "vit_e": 0.86, "vit_k": 2.1, "folate": 9, "vit_b6": 0.056, "calcium": 97, "vit_b12": 0.22, "magnesium": 9, "potassium": 132}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('16da1d15-f816-464e-a3e7-3e82ef9230fa', 'واي بروتين', 'Beverages, Whey protein powder isolate', 'مكملات', 359.0, 58.1, 29.1, 1.2, 30.0, 'سكوب', 'usda', '173177', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'مكملات', 0.0, '{"iron": 1.26, "zinc": 8.72, "vit_a": 872, "vit_c": 34.9, "vit_d": 0, "vit_e": 7.85, "vit_k": 46.5, "folate": 395, "vit_b6": 1.163, "calcium": 698, "vit_b12": 3.49, "magnesium": 233, "potassium": 872}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('57d36b7a-c058-4d02-8c3a-62856d9bf553', 'عدس مطبوخ', 'Lentils, mature seeds, cooked, boiled, without salt', 'بقوليات', 116.0, 9.0, 20.1, 0.4, 150.0, NULL, 'usda', '172421', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'بقوليات', 7.9, '{"iron": 3.33, "zinc": 1.27, "vit_a": 0, "vit_c": 1.5, "vit_d": 0, "vit_e": 0.11, "vit_k": 1.7, "folate": 181, "vit_b6": 0.178, "calcium": 19, "vit_b12": 0, "magnesium": 36, "potassium": 369}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f3e08986-784b-4d2d-a0f0-d378cbe559e2', 'حمص مطبوخ', 'Chickpeas (garbanzo beans, bengal gram), mature seeds, cooked, boiled, without salt', 'بقوليات', 164.0, 8.9, 27.4, 2.6, 150.0, NULL, 'usda', '173757', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'بقوليات', 7.6, '{"iron": 2.89, "zinc": 1.53, "vit_a": 1, "vit_c": 1.3, "vit_d": 0, "vit_e": 0.35, "vit_k": 4, "folate": 172, "vit_b6": 0.139, "calcium": 49, "vit_b12": 0, "magnesium": 48, "potassium": 291}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('66b27c5f-2def-48df-a320-437cf4106a97', 'فول مدمس (مطبوخ)', 'Broadbeans (fava beans), mature seeds, cooked, boiled, without salt', 'بقوليات', 110.0, 7.6, 19.7, 0.4, 150.0, NULL, 'usda', '173753', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'بقوليات', 5.4, '{"iron": 1.5, "zinc": 1.01, "vit_a": 1, "vit_c": 0.3, "vit_d": 0, "vit_e": 0.02, "vit_k": 2.9, "folate": 104, "vit_b6": 0.072, "calcium": 36, "vit_b12": 0, "magnesium": 43, "potassium": 268}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d9f88fbf-6e6d-43cb-8d85-d267309ff845', 'فاصوليا حمراء مطبوخة', 'Beans, kidney, all types, mature seeds, cooked, boiled, without salt', 'بقوليات', 127.0, 8.7, 22.8, 0.5, 150.0, NULL, 'usda', '173740', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'بقوليات', 6.4, '{"iron": 2.22, "zinc": 1, "vit_a": 0, "vit_c": 1.2, "vit_d": 0, "vit_e": 0.03, "vit_k": 8.4, "folate": 130, "vit_b6": 0.12, "calcium": 35, "vit_b12": 0, "magnesium": 42, "potassium": 405}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3b4129b8-2b7e-4fcf-9495-5057ed193ecd', 'حمص بطحينة (حمص جاهز)', 'Hummus, commercial', 'بقوليات', 237.0, 7.8, 15.0, 17.8, 60.0, NULL, 'usda', '174289', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'بقوليات', 5.5, '{"iron": 2.54, "zinc": 1.44, "vit_a": 1, "vit_c": 0, "vit_d": 0, "vit_e": 1.54, "vit_k": 22.8, "folate": 48, "vit_b6": 0.146, "calcium": 47, "vit_b12": 0, "magnesium": 75, "potassium": 312}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('bb53d7fd-1110-4622-8eab-f5ac965059c8', 'تمر مجدول', 'Dates, medjool', 'فواكه', 277.0, 1.8, 75.0, 0.2, 24.0, 'حبة', 'usda', '168191', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'فواكه', 6.7, '{"iron": 0.9, "zinc": 0.44, "vit_a": 7, "vit_c": 0, "vit_d": 0, "vit_k": 2.7, "folate": 15, "vit_b6": 0.249, "calcium": 64, "magnesium": 54, "potassium": 696}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('187e8e9d-d69c-4f6a-8303-73166c4a3ed9', 'تمر (دقلة نور)', 'Dates, deglet noor', 'فواكه', 282.0, 2.5, 75.0, 0.4, 7.0, 'حبة', 'usda', '171726', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'فواكه', 8.0, '{"iron": 1.02, "zinc": 0.29, "vit_a": 0, "vit_c": 0.4, "vit_d": 0, "vit_e": 0.05, "vit_k": 2.7, "folate": 19, "vit_b6": 0.165, "calcium": 39, "vit_b12": 0, "magnesium": 43, "potassium": 656}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('7286b4d7-6a69-4e77-8614-4fedbb78eb0c', 'موز', 'Bananas, raw', 'فواكه', 89.0, 1.1, 22.8, 0.3, 118.0, 'حبة وسط', 'usda', '173944', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'فواكه', 2.6, '{"iron": 0.26, "zinc": 0.15, "vit_a": 3, "vit_c": 8.7, "vit_d": 0, "vit_e": 0.1, "vit_k": 0.5, "folate": 20, "vit_b6": 0.367, "calcium": 5, "vit_b12": 0, "magnesium": 27, "potassium": 358}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f91e4dba-3f88-46b3-8043-b095a4beee2d', 'تفاح', 'Apples, raw, with skin (Includes foods for USDA''s Food Distribution Program)', 'فواكه', 52.0, 0.3, 13.8, 0.2, 182.0, 'حبة وسط', 'usda', '171688', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'فواكه', 2.4, '{"iron": 0.12, "zinc": 0.04, "vit_a": 3, "vit_c": 4.6, "vit_d": 0, "vit_e": 0.18, "vit_k": 2.2, "folate": 3, "vit_b6": 0.041, "calcium": 6, "vit_b12": 0, "magnesium": 5, "potassium": 107}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('8678a384-e1be-46d2-9fe6-68f8309f0f65', 'برتقال', 'Oranges, raw, all commercial varieties', 'فواكه', 47.0, 0.9, 11.8, 0.1, 131.0, 'حبة', 'usda', '169097', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'فواكه', 2.4, '{"iron": 0.1, "zinc": 0.07, "vit_a": 11, "vit_c": 53.2, "vit_d": 0, "vit_e": 0.18, "vit_k": 0, "folate": 30, "vit_b6": 0.06, "calcium": 40, "vit_b12": 0, "magnesium": 10, "potassium": 181}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3e7dfea1-cd05-44dc-81fc-5dcfb15a6f99', 'فراولة', 'Strawberries, raw', 'فواكه', 32.0, 0.7, 7.7, 0.3, 150.0, 'كوب', 'usda', '167762', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'فواكه', 2.0, '{"iron": 0.41, "zinc": 0.14, "vit_a": 1, "vit_c": 58.8, "vit_d": 0, "vit_e": 0.29, "vit_k": 2.2, "folate": 24, "vit_b6": 0.047, "calcium": 16, "vit_b12": 0, "magnesium": 13, "potassium": 153}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('c462732e-6d57-4e08-ad11-343d18bf5bdf', 'عنب', 'Grapes, red or green (European type, such as Thompson seedless), raw', 'فواكه', 69.0, 0.7, 18.1, 0.2, 150.0, 'كوب', 'usda', '174683', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'فواكه', 0.9, '{"iron": 0.36, "zinc": 0.07, "vit_a": 3, "vit_c": 3.2, "vit_d": 0, "vit_e": 0.19, "vit_k": 14.6, "folate": 2, "vit_b6": 0.086, "calcium": 10, "vit_b12": 0, "magnesium": 7, "potassium": 191}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('1b42c060-7fd3-4c37-819a-d964887a69a1', 'بطيخ', 'Watermelon, raw', 'فواكه', 30.0, 0.6, 7.6, 0.2, 280.0, 'كوب ونص', 'usda', '167765', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'فواكه', 0.4, '{"iron": 0.24, "zinc": 0.1, "vit_a": 28, "vit_c": 8.1, "vit_d": 0, "vit_e": 0.05, "vit_k": 0.1, "folate": 3, "vit_b6": 0.045, "calcium": 7, "vit_b12": 0, "magnesium": 10, "potassium": 112}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('9c6cd7e3-8a21-4de9-b795-5757a322eec8', 'مانجو', 'Mangos, raw', 'فواكه', 60.0, 0.8, 15.0, 0.4, 165.0, 'كوب', 'usda', '169910', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'فواكه', 1.6, '{"iron": 0.16, "zinc": 0.09, "vit_a": 54, "vit_c": 36.4, "vit_d": 0, "vit_e": 0.9, "vit_k": 4.2, "folate": 43, "vit_b6": 0.119, "calcium": 11, "vit_b12": 0, "magnesium": 10, "potassium": 168}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ea9f9e44-7671-43e1-94b3-d28de6fc2e4c', 'أناناس', 'Pineapple, raw, all varieties', 'فواكه', 50.0, 0.5, 13.1, 0.1, 165.0, 'كوب', 'usda', '169124', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'فواكه', 1.4, '{"iron": 0.29, "zinc": 0.12, "vit_a": 3, "vit_c": 47.8, "vit_d": 0, "vit_e": 0.02, "vit_k": 0.7, "folate": 18, "vit_b6": 0.112, "calcium": 13, "vit_b12": 0, "magnesium": 12, "potassium": 109}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d322aa2a-98e5-480b-8abe-1a23b587797b', 'توت أزرق', 'Blueberries, raw', 'فواكه', 57.0, 0.7, 14.5, 0.3, 148.0, 'كوب', 'usda', '171711', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'فواكه', 2.4, '{"iron": 0.28, "zinc": 0.16, "vit_a": 3, "vit_c": 9.7, "vit_d": 0, "vit_e": 0.57, "vit_k": 19.3, "folate": 6, "vit_b6": 0.052, "calcium": 6, "vit_b12": 0, "magnesium": 6, "potassium": 77}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('1dc6fab2-6090-4dae-b132-4a9190fcd013', 'كيوي', 'Kiwifruit, green, raw', 'فواكه', 61.0, 1.1, 14.7, 0.5, 75.0, 'حبة', 'usda', '168153', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'فواكه', 3.0, '{"iron": 0.31, "zinc": 0.14, "vit_a": 4, "vit_c": 92.7, "vit_d": 0, "vit_e": 1.46, "vit_k": 40.3, "folate": 25, "vit_b6": 0.063, "calcium": 34, "vit_b12": 0, "magnesium": 17, "potassium": 312}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('c9aeb264-3de9-4b9f-8671-9356abc93c60', 'رمان', 'Pomegranates, raw', 'فواكه', 83.0, 1.7, 18.7, 1.2, 87.0, 'نص كوب حبوب', 'usda', '169134', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'فواكه', 4.0, '{"iron": 0.3, "zinc": 0.35, "vit_a": 0, "vit_c": 10.2, "vit_d": 0, "vit_e": 0.6, "vit_k": 16.4, "folate": 38, "vit_b6": 0.075, "calcium": 10, "vit_b12": 0, "magnesium": 12, "potassium": 236}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('46e43654-3bd6-46d8-b306-c5abff5e41d7', 'خيار', 'Cucumber, with peel, raw', 'خضار', 15.0, 0.7, 3.6, 0.1, 100.0, NULL, 'usda', '168409', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'خضار', 0.5, '{"iron": 0.28, "zinc": 0.2, "vit_a": 5, "vit_c": 2.8, "vit_d": 0, "vit_e": 0.03, "vit_k": 16.4, "folate": 7, "vit_b6": 0.04, "calcium": 16, "vit_b12": 0, "magnesium": 13, "potassium": 147}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('4318c9c6-0ffe-433a-ac70-aa1ff6082ce4', 'طماطم', 'Tomatoes, red, ripe, raw, year round average', 'خضار', 18.0, 0.9, 3.9, 0.2, 120.0, 'حبة وسط', 'usda', '170457', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'خضار', 1.2, '{"iron": 0.27, "zinc": 0.17, "vit_a": 42, "vit_c": 13.7, "vit_d": 0, "vit_e": 0.54, "vit_k": 7.9, "folate": 15, "vit_b6": 0.08, "calcium": 10, "vit_b12": 0, "magnesium": 11, "potassium": 237}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d77a07cc-5b99-44a4-a240-c5e173dddd4e', 'خس', 'Lettuce, cos or romaine, raw', 'خضار', 17.0, 1.2, 3.3, 0.3, 50.0, NULL, 'usda', '169247', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'خضار', 2.1, '{"iron": 0.97, "zinc": 0.23, "vit_a": 436, "vit_c": 4, "vit_d": 0, "vit_e": 0.13, "vit_k": 102.5, "folate": 136, "vit_b6": 0.074, "calcium": 33, "vit_b12": 0, "magnesium": 14, "potassium": 247}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('abd6e762-990a-41ef-ae3d-3d9188be1794', 'جزر', 'Carrots, raw', 'خضار', 41.0, 0.9, 9.6, 0.2, 60.0, 'حبة', 'usda', '170393', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'خضار', 2.8, '{"iron": 0.3, "zinc": 0.24, "vit_a": 835, "vit_c": 5.9, "vit_d": 0, "vit_e": 0.66, "vit_k": 13.2, "folate": 19, "vit_b6": 0.138, "calcium": 33, "vit_b12": 0, "magnesium": 12, "potassium": 320}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('88aa3165-e536-4148-815b-d52cae63bcfb', 'بروكلي مطبوخ', 'Broccoli, cooked, boiled, drained, without salt', 'خضار', 35.0, 2.4, 7.2, 0.4, 90.0, NULL, 'usda', '169967', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'خضار', 3.3, '{"iron": 0.67, "zinc": 0.45, "vit_a": 77, "vit_c": 64.9, "vit_d": 0, "vit_e": 1.45, "vit_k": 141.1, "folate": 108, "vit_b6": 0.2, "calcium": 40, "vit_b12": 0, "magnesium": 21, "potassium": 293}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3f407b89-2943-4fa8-b7e9-07be64833041', 'سبانخ', 'Spinach, raw', 'خضار', 23.0, 2.9, 3.6, 0.4, 30.0, 'كوب', 'usda', '168462', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'خضار', 2.2, '{"iron": 2.71, "zinc": 0.53, "vit_a": 469, "vit_c": 28.1, "vit_d": 0, "vit_e": 2.03, "vit_k": 482.9, "folate": 194, "vit_b6": 0.195, "calcium": 99, "vit_b12": 0, "magnesium": 79, "potassium": 558}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b892f57a-3577-4490-8fef-5116a5ce9c5f', 'فلفل رومي أحمر', 'Peppers, sweet, red, raw', 'خضار', 26.0, 1.0, 6.0, 0.3, 120.0, 'حبة', 'usda', '170108', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'خضار', 2.1, '{"iron": 0.43, "zinc": 0.25, "vit_a": 157, "vit_c": 127.7, "vit_d": 0, "vit_e": 1.58, "vit_k": 4.9, "folate": 46, "vit_b6": 0.291, "calcium": 7, "vit_b12": 0, "magnesium": 12, "potassium": 211}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('2698752d-b37d-4fc2-936c-936db19a4032', 'بصل', 'Onions, raw', 'خضار', 40.0, 1.1, 9.3, 0.1, 110.0, 'حبة وسط', 'usda', '170000', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'خضار', 1.7, '{"iron": 0.21, "zinc": 0.17, "vit_a": 0, "vit_c": 7.4, "vit_d": 0, "vit_e": 0.02, "vit_k": 0.4, "folate": 19, "vit_b6": 0.12, "calcium": 23, "vit_b12": 0, "magnesium": 10, "potassium": 146}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('1f1cc6fd-9023-4cb1-8cb0-5be734f34811', 'فطر (مشروم)', 'Mushrooms, white, raw', 'خضار', 22.0, 3.1, 3.3, 0.3, 70.0, 'كوب', 'usda', '169251', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'خضار', 1.0, '{"iron": 0.5, "zinc": 0.52, "vit_a": 0, "vit_c": 2.1, "vit_d": 0.2, "vit_e": 0.01, "vit_k": 0, "folate": 17, "vit_b6": 0.104, "calcium": 3, "vit_b12": 0.04, "magnesium": 9, "potassium": 318}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('19152f4b-af40-40de-8245-a0327684e5ad', 'كوسا مطبوخة', 'Squash, summer, zucchini, includes skin, cooked, boiled, drained, without salt', 'خضار', 15.0, 1.1, 2.7, 0.4, 180.0, NULL, 'usda', '169292', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'خضار', 1.0, '{"iron": 0.37, "zinc": 0.33, "vit_a": 56, "vit_c": 12.9, "vit_d": 0, "vit_e": 0.12, "vit_k": 4.2, "folate": 28, "vit_b6": 0.08, "calcium": 18, "vit_b12": 0, "magnesium": 19, "potassium": 264}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b2a62319-7412-4380-9414-ce158262a760', 'باذنجان مطبوخ', 'Eggplant, cooked, boiled, drained, without salt', 'خضار', 35.0, 0.8, 8.7, 0.2, 100.0, NULL, 'usda', '169229', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'خضار', 2.5, '{"iron": 0.25, "zinc": 0.12, "vit_a": 2, "vit_c": 1.3, "vit_d": 0, "vit_e": 0.41, "vit_k": 2.9, "folate": 14, "vit_b6": 0.086, "calcium": 6, "vit_b12": 0, "magnesium": 11, "potassium": 123}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('aa9566b9-449f-4d05-910f-1a461ad29b78', 'ذرة حلوة مطبوخة', 'Corn, sweet, yellow, cooked, boiled, drained, without salt', 'خضار', 96.0, 3.4, 21.0, 1.5, 150.0, NULL, 'usda', '169999', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'خضار نشوية', 2.4, '{"iron": 0.45, "zinc": 0.62, "vit_a": 13, "vit_c": 5.5, "vit_d": 0, "vit_e": 0.09, "vit_k": 0.4, "folate": 23, "vit_b6": 0.139, "calcium": 3, "vit_b12": 0, "magnesium": 26, "potassium": 218}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('2cd51bbf-8321-49f0-a561-e2698e7e5054', 'أفوكادو', 'Avocados, raw, all commercial varieties', 'دهون ومكسرات', 160.0, 2.0, 8.5, 14.7, 50.0, 'ثلث حبة', 'usda', '171705', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'فواكه', 6.7, '{"iron": 0.55, "zinc": 0.64, "vit_a": 7, "vit_c": 10, "vit_d": 0, "vit_e": 2.07, "vit_k": 21, "folate": 81, "vit_b6": 0.257, "calcium": 12, "vit_b12": 0, "magnesium": 29, "potassium": 485}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('38d38a16-8dcc-45b5-b58d-53a84c62bbc4', 'زيت زيتون', 'Oil, olive, salad or cooking', 'دهون ومكسرات', 884.0, 0.0, 0.0, 100.0, 5.0, 'ملعقة صغيرة', 'usda', '171413', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'دهون وزيوت', 0.0, '{"iron": 0.56, "zinc": 0, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 14.35, "vit_k": 60.2, "folate": 0, "vit_b6": 0, "calcium": 1, "vit_b12": 0, "magnesium": 0, "potassium": 1}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('8400650a-0024-4576-ad44-0f668757d5cd', 'زبدة', 'Butter, salted', 'دهون ومكسرات', 717.0, 0.9, 0.1, 81.1, 5.0, 'ملعقة صغيرة', 'usda', '173410', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'دهون وزيوت', 0.0, '{"iron": 0.02, "zinc": 0.09, "vit_a": 684, "vit_c": 0, "vit_d": 0, "vit_e": 2.32, "vit_k": 7, "folate": 3, "vit_b6": 0.003, "calcium": 24, "vit_b12": 0.17, "magnesium": 2, "potassium": 24}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('e47906ff-242c-431c-afb4-94fdff5e188b', 'لوز', 'Nuts, almonds', 'دهون ومكسرات', 579.0, 21.2, 21.6, 49.9, 28.0, 'حفنة', 'usda', '170567', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'مكسرات وبذور', 12.5, '{"iron": 3.71, "zinc": 3.12, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 25.63, "vit_k": 0, "folate": 44, "vit_b6": 0.137, "calcium": 269, "vit_b12": 0, "magnesium": 270, "potassium": 733}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b5e65b69-b050-48ff-8e93-eeed3909cc4e', 'كاجو', 'Nuts, cashew nuts, raw', 'دهون ومكسرات', 553.0, 18.2, 30.2, 43.9, 28.0, 'حفنة', 'usda', '170162', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'مكسرات وبذور', 3.3, '{"iron": 6.68, "zinc": 5.78, "vit_a": 0, "vit_c": 0.5, "vit_d": 0, "vit_e": 0.9, "vit_k": 34.1, "folate": 25, "vit_b6": 0.417, "calcium": 37, "vit_b12": 0, "magnesium": 292, "potassium": 660}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('55866be2-4d0a-43d0-9e42-525ba7851605', 'فستق حلبي', 'Nuts, pistachio nuts, raw', 'دهون ومكسرات', 560.0, 20.2, 27.2, 45.3, 28.0, 'حفنة', 'usda', '170184', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'مكسرات وبذور', 10.6, '{"iron": 3.92, "zinc": 2.2, "vit_a": 26, "vit_c": 5.6, "vit_d": 0, "vit_e": 2.86, "folate": 51, "vit_b6": 1.7, "calcium": 105, "vit_b12": 0, "magnesium": 121, "potassium": 1025}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('bf4de5bf-1819-4456-a551-5cd50aafb64b', 'جوز (عين الجمل)', 'Nuts, walnuts, english', 'دهون ومكسرات', 654.0, 15.2, 13.7, 65.2, 28.0, 'حفنة', 'usda', '170187', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'مكسرات وبذور', 6.7, '{"iron": 2.91, "zinc": 3.09, "vit_a": 1, "vit_c": 1.3, "vit_d": 0, "vit_e": 0.7, "vit_k": 2.7, "folate": 98, "vit_b6": 0.537, "calcium": 98, "vit_b12": 0, "magnesium": 158, "potassium": 441}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('68ca045a-0301-4a4e-9cda-e3a1ce9dbafa', 'زبدة فول سوداني', 'Peanut butter, smooth style, without salt', 'دهون ومكسرات', 598.0, 22.2, 22.3, 51.4, 16.0, 'ملعقة كبيرة', 'usda', '172470', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'مكسرات وبذور', 5.0, '{"iron": 1.74, "zinc": 2.51, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 9.1, "vit_k": 0.3, "folate": 87, "vit_b6": 0.441, "calcium": 49, "vit_b12": 0, "magnesium": 168, "potassium": 558}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('bfb6e16c-a21d-4937-a3c2-3621e01e7bdb', 'فول سوداني', 'Peanuts, all types, raw', 'دهون ومكسرات', 567.0, 25.8, 16.1, 49.2, 28.0, 'حفنة', 'usda', '172430', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'مكسرات وبذور', 8.5, '{"iron": 4.58, "zinc": 3.27, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 8.33, "vit_k": 0, "folate": 240, "vit_b6": 0.348, "calcium": 92, "vit_b12": 0, "magnesium": 168, "potassium": 705}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b156c69f-4a6f-4658-92cb-5e5ceb83435e', 'طحينة', 'Seeds, sesame butter, tahini, from roasted and toasted kernels (most common type)', 'دهون ومكسرات', 595.0, 17.0, 21.2, 53.8, 15.0, 'ملعقة كبيرة', 'usda', '170189', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'مكسرات وبذور', 9.3, '{"iron": 8.95, "zinc": 4.62, "vit_a": 3, "vit_c": 0, "vit_d": 0, "vit_e": 0.25, "vit_k": 0, "folate": 98, "vit_b6": 0.149, "calcium": 426, "vit_b12": 0, "magnesium": 95, "potassium": 414}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a784ad7a-806b-483d-b82e-7a3b0120e8b6', 'بذور الشيا', 'Seeds, chia seeds, dried', 'دهون ومكسرات', 486.0, 16.5, 42.1, 30.7, 12.0, 'ملعقة كبيرة', 'usda', '170554', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'مكسرات وبذور', 34.4, '{"iron": 7.72, "zinc": 4.58, "vit_c": 1.6, "vit_e": 0.5, "calcium": 631, "vit_b12": 0, "magnesium": 335, "potassium": 407}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3a587481-9536-4bad-acc0-5fa95ad94a15', 'عسل', 'Honey', 'حلويات ومشروبات', 304.0, 0.3, 82.4, 0.0, 21.0, 'ملعقة كبيرة', 'usda', '169640', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'حلويات ومحليات', 0.2, '{"iron": 0.42, "zinc": 0.22, "vit_a": 0, "vit_c": 0.5, "vit_d": 0, "vit_e": 0, "vit_k": 0, "folate": 2, "vit_b6": 0.024, "calcium": 6, "vit_b12": 0, "magnesium": 2, "potassium": 52}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('14720857-524a-466f-a0bb-675cd84e5d1d', 'سكر أبيض', 'Sugars, granulated', 'حلويات ومشروبات', 387.0, 0.0, 100.0, 0.0, 4.0, 'ملعقة صغيرة', 'usda', '169655', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'حلويات ومحليات', 0.0, '{"iron": 0.05, "zinc": 0.01, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0, "vit_k": 0, "folate": 0, "vit_b6": 0, "calcium": 1, "vit_b12": 0, "magnesium": 0, "potassium": 2}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('2ec19381-0bed-4b2c-8d38-f82bd95772d2', 'شوكولاتة داكنة 70-85%', 'Chocolate, dark, 70-85% cacao solids', 'حلويات ومشروبات', 598.0, 7.8, 45.9, 42.6, 20.0, NULL, 'usda', '170273', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'حلويات ومحليات', 10.9, '{"iron": 11.9, "zinc": 3.31, "vit_a": 2, "vit_e": 0.59, "vit_k": 7.3, "vit_b6": 0.038, "calcium": 73, "vit_b12": 0.28, "magnesium": 228, "potassium": 715}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('15926c59-4ec8-4cb5-942e-2a1980c99cac', 'عصير برتقال', 'Orange juice, raw (Includes foods for USDA''s Food Distribution Program)', 'حلويات ومشروبات', 45.0, 0.7, 10.4, 0.2, 248.0, 'كوب', 'usda', '169098', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'مشروبات', 0.2, '{"iron": 0.2, "zinc": 0.05, "vit_a": 10, "vit_c": 50, "vit_d": 0, "vit_e": 0.04, "vit_k": 0.1, "folate": 30, "vit_b6": 0.04, "calcium": 11, "vit_b12": 0, "magnesium": 11, "potassium": 200}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('7144b65d-fb5e-4e86-a104-ac6830e507ae', 'مايونيز', 'Salad dressing, mayonnaise, regular', 'صوصات', 680.0, 1.0, 0.6, 74.9, 15.0, 'ملعقة كبيرة', 'usda', '171009', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'دهون وزيوت', 0.0, '{"iron": 0.21, "zinc": 0.15, "vit_a": 16, "vit_c": 0, "vit_d": 0.2, "vit_e": 3.28, "vit_k": 163, "folate": 5, "vit_b6": 0.008, "calcium": 8, "vit_b12": 0.12, "magnesium": 1, "potassium": 20}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('120f1645-9cfa-4806-acff-e8c7d398418d', 'كاتشب', 'Catsup', 'صوصات', 101.0, 1.0, 27.4, 0.1, 17.0, 'ملعقة كبيرة', 'usda', '168556', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'صلصات', 0.3, '{"iron": 0.35, "zinc": 0.17, "vit_a": 26, "vit_c": 4.1, "vit_d": 0, "vit_e": 1.46, "vit_k": 3, "folate": 9, "vit_b6": 0.158, "calcium": 15, "vit_b12": 0, "magnesium": 13, "potassium": 281}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('4ffd6665-4efd-4701-8f6f-7ef3490b854e', 'حليب بروتين قهوة (ندى 320 مل)', 'Nada Protein Milk Coffee 320ml', 'مشروبات بروتينية', 87.0, 9.5, 10.0, 0.1, 320.0, 'عبوة 320 مل', 'coach', 'nada.com.sa/protein-milk-320ml-coffee', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('159fe408-ac22-4ae1-811c-6740038584d3', 'حليب بروتين شوكولاتة (ندى 320 مل)', 'Nada Protein Chocolate Milk 320ml', 'مشروبات بروتينية', 84.0, 8.5, 12.5, 0.1, 320.0, 'عبوة 320 مل', 'coach', 'nada.com.sa/protein-chocolate-milk', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('847e15f4-b537-4bb3-aef0-1e23cc132baa', 'حليب بروتين تمر (ندى 320 مل)', 'Nada Protein Dates Milk 320ml', 'مشروبات بروتينية', 108.0, 8.5, 15.0, 1.5, 320.0, 'عبوة 320 مل', 'coach', 'nada.com.sa/protein-dates-milk', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('30339e9f-f4de-4b90-87d4-5192395d6efa', 'باور ميلك قهوة (ندى 425 مل)', 'Nada Power Milk Coffee 425ml', 'مشروبات بروتينية', 87.0, 9.5, 10.0, 0.1, 425.0, 'عبوة 425 مل', 'coach', 'nada.com.sa/power-milk-425ml-coffee', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('c78c033b-82cc-4914-aa39-591850282790', 'باور ميلك شوكولاتة (ندى)', 'Nada Power Milk Chocolate', 'مشروبات بروتينية', 87.0, 9.5, 12.5, 0.1, NULL, NULL, 'coach', 'nada.com.sa/power-milk-chocolate', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('bf372b35-35a6-4a1a-9fea-7ae83cb49cc0', 'باور ميلك فانيلا (ندى)', 'Nada Power Milk Vanilla', 'مشروبات بروتينية', 87.0, 9.5, 12.5, 0.1, NULL, NULL, 'coach', 'nada.com.sa/power-milk-vanilla-mixed-fru', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('dd122d0a-86f4-417f-9ed4-d752177662ab', 'حليب بروتين شوكولاتة (المراعي 400 مل)', 'Almarai Protein Milk Chocolate 400ml', 'مشروبات بروتينية', 73.0, 8.5, 9.6, 0.4, 400.0, 'عبوة 400 مل', 'coach', 'almarai.com/protein-milk-chocolate', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b104574a-be5c-443c-a8e8-bcbadeccaf01', 'حليب بروتين فراولة وموز (المراعي 400 مل)', 'Almarai Protein Milk Strawberry Banana 400ml', 'مشروبات بروتينية', 71.0, 8.5, 9.2, 0.3, 400.0, 'عبوة 400 مل', 'coach', 'almarai.com/protein-milk-strawberry-bana', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b428cbe1-ccaa-4782-ba5c-6c011f8819f6', 'حليب بروتين فانيلا (المراعي 400 مل)', 'Almarai Protein Milk Vanilla 400ml', 'مشروبات بروتينية', 72.0, 8.5, 9.4, 0.3, 400.0, 'عبوة 400 مل', 'coach', 'almarai.com/protein-milk-vanilla', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b4920249-157a-41ee-ab0d-e778b829d59f', 'ماسل ميلك شوكولاتة (المراعي 400 مل)', 'Almarai Muscle Milk Chocolate 400ml', 'مشروبات بروتينية', 68.0, 10.0, 6.1, 0.3, 400.0, 'عبوة 400 مل', 'coach', 'almarai.com/muscle-milk-chocolate', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('071f2ffd-bcbc-4aec-87af-3f460f5a7a42', 'ماسل ميلك سادة (المراعي 400 مل)', 'Almarai Muscle Milk Plain 400ml', 'مشروبات بروتينية', 58.0, 10.0, 3.8, 0.2, 400.0, 'عبوة 400 مل', 'coach', 'almarai.com/muscle-milk-plain', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('5726b1f1-2149-4f87-bd49-687b7c23a61b', 'زبادي يوناني كامل الدسم فراولة (ندى 160 غ)', 'Nada Greek Yoghurt Full Fat Strawberry 160g', 'زبادي يوناني', 147.0, 7.0, 14.0, 7.0, 160.0, 'عبوة 160 غ', 'coach', 'nada.com.sa/greek-yoghurt-full-fat-straw', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('abc4f81f-39c0-4348-892e-b81863f532b7', 'زبادي يوناني كامل الدسم توت أزرق (ندى)', 'Nada Greek Yoghurt Blueberry Full Cream', 'زبادي يوناني', 147.0, 7.0, 14.0, 7.0, NULL, NULL, 'coach', 'nada.com.sa/greek-yoghurt-with-blueberry', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('10f2ae59-6313-45d3-8b88-e62686d5c570', 'زبادي يوناني ليمون ونعناع (ندى)', 'Nada Greek Yoghurt Lemon Mint', 'زبادي يوناني', 137.0, 7.0, 11.5, 7.0, NULL, NULL, 'coach', 'nada.com.sa/greek-yoghurt-with-lemon-min', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('91879ddd-99f6-4a82-9db8-ebbd1ede573e', 'زبادي يوناني توت مشكل كامل الدسم (ندى)', 'Nada Greek Yoghurt Mixed Berry Full Cream', 'زبادي يوناني', 148.0, 7.0, 14.3, 7.0, NULL, NULL, 'coach', 'nada.com.sa/greek-yoghurt-with-mixed-ber', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('997c287a-7f03-4b09-93cf-9b77b92c22f6', 'زبادي يوناني سادة (ندى 160)', 'Nada Greek Yoghurt Plain', 'زبادي يوناني', 111.0, 7.0, 5.0, 7.0, 160.0, 'عبوة 160 مل', 'coach', 'nada.com.sa/greek-yoghurt-plain', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('5e01bc72-8fdd-4eff-aaf7-bb395df874dc', 'زبادي يوناني 0% دهون سادة (ندى 160)', 'Nada Greek Yoghurt 0% Fat Plain', 'زبادي يوناني', 63.0, 10.0, 5.0, 0.3, 160.0, 'عبوة 160 مل', 'coach', 'nada.com.sa/greek-yoghurt-0-fat-plain', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('fe18bead-0b26-47af-823c-151579aad111', 'زبادي يوناني قليل الدسم سادة (ندى 160)', 'Nada Greek Yoghurt Low Fat Plain', 'زبادي يوناني', 66.0, 7.0, 5.0, 2.0, 160.0, 'عبوة 160 مل', 'coach', 'nada.com.sa/greek-yoghurt-low-fat-plain', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('02d32a1d-f3c6-4b7a-af79-971697fd9ee0', 'زبادي يوناني بالعسل الطبيعي (ندى 160)', 'Nada Greek Yoghurt Natural Honey', 'زبادي يوناني', 141.0, 7.0, 12.5, 7.0, 160.0, 'عبوة 160 مل', 'coach', 'nada.com.sa/greek-yoghurt-natural-honey', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('cc398a2b-939d-46a1-919a-161edc36d93e', 'زبادي يوناني توت أسود وتوت العليق (ندى 160)', 'Nada Greek Yoghurt Blackberry Raspberry', 'زبادي يوناني', 151.0, 7.0, 15.0, 7.0, 160.0, 'عبوة 160 مل', 'coach', 'nada.com.sa/greek-yoghurt-berry', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f7ce5cb7-1568-4d83-b55f-2cb8968cf18c', 'زبادي يوناني 0% دهون توت مشكل (ندى 160)', 'Nada Greek Yoghurt 0% Fat Mixed Berry', 'زبادي يوناني', 100.0, 10.0, 14.3, 0.3, 160.0, 'عبوة 160 مل', 'coach', 'nada.com.sa/greek-yoghurt-0-fat-mixed-be', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('fec24e4a-cf35-4058-8f7a-a4c2b444ffe7', 'زبادي يوناني قليل الدسم توت أزرق (ندى 160)', 'Nada Greek Yoghurt Low Fat Blueberry', 'زبادي يوناني', 102.0, 7.0, 14.0, 2.0, 160.0, 'عبوة 160 مل', 'coach', 'nada.com.sa/greek-yoghurt-low-fat-bluebe', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('664f1221-29a0-46b5-aa30-ce2de8e6da76', 'زبادي يوناني 0% دهون مانجو وخوخ (ندى 160)', 'Nada Greek Yoghurt 0% Fat Mango Peach', 'زبادي يوناني', 111.0, 10.0, 17.0, 0.3, 160.0, 'عبوة 160 مل', 'coach', 'nada.com.sa/greek-yoghurt-0-fat-mango-pe', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('25c82944-7ad9-4186-9edb-59cae68e3ba0', 'زبادي يوناني قليل الدسم فراولة (ندى 160)', 'Nada Greek Yoghurt Low Fat Strawberry', 'زبادي يوناني', 98.0, 6.0, 14.0, 2.0, 160.0, 'عبوة 160 مل', 'coach', 'nada.com.sa/greek-yoghurt-low-fat-strawb', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('187d4cf4-cd58-4eb9-9b64-ec9fad577864', 'لبن زبادي طازج قليل الدسم (ندى 150 غ)', 'Nada Fresh Yoghurt Low Fat', 'زبادي يوناني', 45.0, 3.1, 5.5, 1.2, 150.0, 'عبوة 150 غ', 'coach', 'nada.com.sa/fresh-yoghurt-low-fat', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('2159cf8b-37d3-4f8c-bde7-eaaead09c548', 'زبادي يوناني للشرب سادة (ندى 330 مل)', 'Nada Drinking Greek Yoghurt Plain', 'زبادي يوناني', 68.0, 9.1, 4.5, 1.5, 330.0, 'عبوة 330 مل', 'coach', 'nada.com.sa/drinking-greek-yoghurt-plain', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('1b104a52-b2e1-4462-a0a4-0262e799ee05', 'زبادي يوناني للشرب توت أسود وتوت العليق (ندى 330 مل)', 'Nada Drinking Greek Yoghurt Blackberry Raspberry', 'زبادي يوناني', 97.0, 8.2, 12.7, 1.5, 330.0, 'عبوة 330 مل', 'coach', 'nada.com.sa/drinking-greek-yoghurt-berry', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('8a209fce-1897-4a8c-8ada-b36fced515ac', 'زبادي يوناني للشرب مانجو (ندى 330 مل)', 'Nada Drinking Greek Yoghurt Mango', 'زبادي يوناني', 94.0, 8.2, 11.9, 1.5, 330.0, 'عبوة 330 مل', 'coach', 'nada.com.sa/drinking-greek-yoghurt-mango', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('fa59bb1d-5702-4b9f-8ab3-a1601e9f52a5', 'زبادي يوناني للشرب باشن فروت وبذور الشيا (ندى 330 مل)', 'Nada Drinking Greek Yoghurt Passion Chia', 'زبادي يوناني', 101.0, 8.2, 13.6, 1.5, 330.0, 'عبوة 330 مل', 'coach', 'nada.com.sa/drinking-greek-yoghurt-passi', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('050a5171-fefd-45b8-ad70-65d7bd53c5c1', 'زبادي يوناني للشرب فراولة وحبوب (ندى 330 مل)', 'Nada Drinking Greek Yoghurt Strawberry Cereal', 'زبادي يوناني', 94.0, 8.2, 11.9, 1.5, 330.0, 'عبوة 330 مل', 'coach', 'nada.com.sa/drinking-greek-yoghurt-straw', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('5ff00ed3-009e-4392-be0d-bd980636d294', 'زبادي يوناني سادة (المراعي 150 غ)', 'Almarai Plain Greek Style Yoghurt 150g', 'زبادي يوناني', 139.0, 6.7, 8.7, 8.7, 150.0, 'عبوة 150 غ', 'coach', 'almarai.com/plain-greek-style-yoghurt', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('cdcab65b-50e4-4726-8920-e3b6cfd19162', 'زبادي يوناني فراولة (المراعي 150 غ)', 'Almarai Strawberry Greek Style Yoghurt 150g', 'زبادي يوناني', 150.0, 6.0, 15.3, 7.3, 150.0, 'عبوة 150 غ', 'coach', 'almarai.com/strawberry-greek-style-yoghu', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f6317ea4-5569-4e3e-8ebb-4c02a2d9ed25', 'زبادي يوناني مانجو (المراعي 150 غ)', 'Almarai Mango Greek Style Yoghurt 150g', 'زبادي يوناني', 150.0, 5.9, 15.3, 7.2, 150.0, 'عبوة 150 غ', 'coach', 'almarai.com/mango-greek-style-yoghurt', true, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', 'ألبان وأجبان', NULL, NULL) ON CONFLICT DO NOTHING;



INSERT INTO public.policies VALUES ('terms', 'الشروط والأحكام', '- يبدأ الاشتراك بعد التحقق من وصول التحويل البنكي، وتعبئة استبيان المتدرب.
- ساعات العمل: الأحد – الخميس، 12 ظهراً – 9 مساءً. الرد على الرسائل خلال 48 ساعة عمل.
- البرنامج لا يغني عن الاستشارة الطبية، والمتدرب مسؤول عن الإفصاح عن أي إصابة أو حالة صحية.
- الجداول ملك المتدرب مدى الحياة ويمكنه التعديل عليها.
- الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي.', 0, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;
INSERT INTO public.policies VALUES ('refund', 'الضمان والاسترجاع', '- في اشتراكات 3 أشهر لباقات المتابعة (المكثفة، المتقدمة، الأساسية): يُسترد المبلغ كاملاً إذا لم يتحسن أي من مؤشرات التقدم (متوسط الوزن الأسبوعي، محيط الخصر، القوة في التمارين الأساسية) بعد 12 أسبوعاً.
- شروط الضمان: إرسال المراجعة الأسبوعية كل أسبوع، وأخذ القياسات بانتظام، وتصوير التمارين وإرسالها، والالتزام بجدول التغذية المخصص في الباقات التي تشملها.
- يُطلب الاسترجاع عبر واتساب خلال 14 يوماً من نهاية الأشهر الثلاثة، ويُرجع المبلغ بتحويل بنكي.
- التجديد المجاني: اشتراك 3 أشهر يُكافأ بـ 3 أشهر إضافية عند التزام 90% فأكثر وتقدم واضح في مؤشرات التقدم. صور التطور تُرسل للمدربة للتوثيق (للرجال مع تغطية الوجه والسرة)، ونشرها اختياري.', 1, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;
INSERT INTO public.policies VALUES ('privacy', 'سياسة الخصوصية', '- نجمع: الاسم، البريد الإلكتروني (للدخول إلى حسابك)، رقم الجوال (واتساب)، الباقة المختارة، ومعلومات الاستبيان التي تكتبها بنفسك (ومنها معلومات صحية وقياسات اختيارية).
- الغرض: تنفيذ طلبك، وتصميم برنامجك ومتابعتك، والتواصل معك بخصوصه فقط.
- المعلومات الصحية تُحفظ منفصلة، ولا يطّلع عليها إلا أنت والمدربة، ولا تُرسل في رسائل البريد أو التنبيهات.
- الدفع بتحويل بنكي مباشر لحساب المؤسسة، والموقع لا يطلب أو يخزن أي بيانات بنكية أو بيانات بطاقات. إيصال التحويل يُستخدم لتأكيد طلبك فقط، ويُحفظ في تخزين خاص لا يُفتح إلا لك وللمدربة.
- لا نبيع بياناتك ولا نشاركها مع أي طرف لأغراض تسويقية، ولا تُنشر نتيجتك أو صورتك إلا بموافقتك الصريحة.
- تقدر تطلب نسخة من بياناتك أو حذفها أو سحب موافقتك على النشر بمراسلتنا على واتساب.
- القياس والتحليلات: نستخدم Google Analytics لقياس زيارات صفحات الموقع العامة وتحسين تجربتك، وذلك فقط بعد موافقتك على الشريط الذي يظهر عند أول زيارة، وتقدر ترفض فلا نقيس زيارتك. لا نفعّل القياس داخل حسابك أو صفحات الطلب والدفع والبرامج، ولا نربطه ببياناتك الصحية أو الشخصية، ولا نستخدمه للإعلانات. تُعالَج بيانات القياس لدى Google، وهي مجهولة الهوية في غالبها (عنوان IP يُقنَّع، وبدون ميزات الإعلانات المخصصة). تقدر تسحب موافقتك بمسح بيانات الموقع من متصفحك، فيظهر لك الشريط مرة ثانية.', 2, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;
INSERT INTO public.policies VALUES ('reviews', 'سياسة التقييمات', '- يكتب التقييم فقط من اشترى خدمة وبدأها فعلاً، وتقييم واحد لكل طلب.
- كل تقييم يُراجع قبل ظهوره للعامة، ولا يُعدّل نصه أبداً.
- تختار بنفسك طريقة ظهور اسمك: الاسم كامل، أو الاسم الأول فقط، أو بدون اسم. والموافقة على النشر منفصلة واختيارية.
- لا يُنشر تقييم يحتوي أرقام هواتف أو بريد أو روابط أو تفاصيل صحية خاصة أو إساءة لأي شخص.
- يحق للمدربة الرد على التقييم، أو إخفاء التقييم المخالف لهذه السياسة مع تسجيل السبب.
- تقدر تطلب إخفاء تقييمك في أي وقت بمراسلتنا على واتساب.', 3, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;



INSERT INTO public.products VALUES ('b5538d03-b270-444e-b3a7-d701c9652202', 'intensive', 'follow', 'الباقة المكثفة', 'الأنسب للمبتدئين ولمن يحتاج متابعة أسبوعية مع زوم: تمرين + تغذية + زوم + جلسة حضورية', '[{"text": "جلسة حضورية مجانية لمدة ساعة لتصحيح التكنيك والتأكد من جودة التمرين (للبنات في المنطقة الشرقية)", "included": true}, {"text": "ملف شامل للخطة التدريبية والتغذية مع شروحات وافية للتمارين، بالمنزل أو بالنادي", "included": true}, {"text": "4 مكالمات زوم شهرياً نتابع فيها تطورك واستفساراتك الرياضية والنفسية", "included": true}, {"text": "مناقشة أسبوعية لتطورك البدني والنفسي (فيديو أو تسجيل صوتي) مع تعديل السعرات أو التمرين عند الحاجة", "included": true}, {"text": "شرح سهل ومبسط لتطبيق حساب السعرات MyFitnessPal", "included": true}, {"text": "كتيب شامل للرياضة والتغذية", "included": true}, {"text": "مساعدتك على اختيارات أنسب لصحتك ونمط حياتك في التغذية والروتين اليومي", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}]', NULL, 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.', true, NULL, 'published', 0, false, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('6f440cac-3168-4d63-99f5-cda6663ad2b4', 'advanced', 'follow', 'الباقة المتقدمة', 'لمن عنده خبرة ويحتاج تمرين + تغذية مع متابعة أسبوعية، بدون زوم', '[{"text": "ملف شامل للخطة التدريبية والتغذية مع شروحات وافية للتمارين، بالمنزل أو بالنادي", "included": true}, {"text": "مناقشة أسبوعية لتطورك البدني والنفسي (فيديو أو تسجيل صوتي) مع تعديل السعرات أو التمرين عند الحاجة", "included": true}, {"text": "كتيب شامل للرياضة والتغذية", "included": true}, {"text": "مساعدتك على اختيارات أنسب لصحتك ونمط حياتك في التمرين والروتين اليومي", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}, {"text": "مكالمات زوم والجلسة الحضورية (في المكثفة فقط)", "included": false}]', NULL, 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.', false, NULL, 'published', 1, false, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('8331fd33-4e81-4c1e-bd71-23c7d00c7737', 'basic', 'follow', 'الباقة الأساسية', 'لمن يعرف يضبط أكله ويحتاج خطة تمرين فقط، ومتابعة كل أسبوعين', '[{"text": "ملف شامل للخطة التدريبية مع شروحات وافية للتمارين، بالمنزل أو بالنادي", "included": true}, {"text": "مناقشة كل أسبوعين لتطورك البدني والنفسي (فيديو أو تسجيل صوتي) مع تعديل التمرين عند الحاجة", "included": true}, {"text": "كتيب شامل للرياضة والتغذية", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}, {"text": "بدون خطة تغذية", "included": false}]', NULL, 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.', false, NULL, 'published', 2, false, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('2cd3de2d-fa82-4681-b6f6-b22633ad4af6', 'nutrition', 'follow', 'باقة التغذية', 'لمن يحتاج خطة تغذية شاملة ويتعلم حساب السعرات، بدون خطة تمرين', '[{"text": "خطة تغذية شاملة تناسب هدفك ونمط حياتك", "included": true}, {"text": "تحديد السعرات المناسبة لك ولهدفك", "included": true}, {"text": "تعليمك حسبة السعرات ومساعدتك باختيارات تغذية تناسبك", "included": true}, {"text": "ملف Excel لمتابعة التطور والقياسات", "included": true}, {"text": "مناقشة أسبوعية لعلاقتك بالتغذية في المنزل أو خارجه", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}, {"text": "لا تحتاجها إذا كنت مشتركاً في المكثفة أو المتقدمة، لأن التغذية ضمنها", "included": false}]', 'شهر واحد · غالباً لا تحتاج تجديد', 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي، ولا يوجد تجديد تلقائي. ضمان الاسترجاع يشمل اشتراكات 3 أشهر للمكثفة والمتقدمة والأساسية فقط.', false, NULL, 'published', 3, false, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('8ae935d4-2bfc-4f9a-b518-febc1f2e2438', 'custom-training-plan', 'files', 'بديل التدريب الشخصي', 'لمن لا يحتاج متابعة (متقدم)، أو كبديل أوفر للتدريب الشخصي', '[{"text": "جدول تمرين مخصص لعدد أيام التمرين اللي تحتاجها", "included": true}, {"text": "طريقة حساب الجهد وعدد الجولات المطلوبة", "included": true}, {"text": "تقدر تحمّل الجدول على جهازك", "included": true}]', NULL, 'جدول مخصص بعد الاستبيان تستلمه كملف، وتقدر تحمّله على جهازك. بدون متابعة.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي. الجداول لك مدى الحياة وتقدر تعدّل عليها.', false, NULL, 'published', 4, false, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('6c1b6ec8-b86e-43c5-aaef-49405bf8c3ce', 'training-nutrition-plan', 'files', 'جدول تمارين مع التغذية', 'لمن لا يحتاج متابعة (متقدم)، أو كبديل أوفر للتدريب الشخصي', '[{"text": "جدول تمرين مخصص لعدد أيام التمرين اللي تحتاجها", "included": true}, {"text": "طريقة حساب الجهد وعدد الجولات المطلوبة", "included": true}, {"text": "جدول تغذية فيه خيارات تناسب هدفك الرياضي", "included": true}, {"text": "تقدر تحمّل الجدول على جهازك", "included": true}]', NULL, 'جدول مخصص بعد الاستبيان تستلمه كملف، وتقدر تحمّله على جهازك. بدون متابعة.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي. الجداول لك مدى الحياة وتقدر تعدّل عليها.', false, NULL, 'published', 5, false, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('f3add678-25f8-4bd9-bc0e-adb6d32b0372', 'nutrition-consultation', 'consult', 'جلسة استشارة تغذية', 'لمن عنده أسئلة محددة في التغذية: جلسة وحدة تكفي لحسبة سعراتك ونصائح الأكل.', '[{"text": "مناقشة كل أسئلتك في مجال التغذية", "included": true}, {"text": "حسبة سعرات مناسبة لهدفك مع اقتراحات لأصناف الطعام", "included": true}, {"text": "نصائح في المكملات، وكيف تأكل برّا بطريقة صحيحة", "included": true}]', NULL, 'جلسة عبر Google Meet أو واتساب — المناسب لك.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي.', false, NULL, 'published', 6, false, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('6804b34f-bc0c-41aa-9471-2eb186024848', 'training-consultation', 'consult', 'جلسة استشارة تمرين', 'لمن عنده أسئلة محددة في التمرين: جلسة وحدة تكفي لتعديل جدولك وتصحيح التكنيك.', '[{"text": "مناقشة كل أسئلتك في مجال التمرين", "included": true}, {"text": "تعديل جدولك الرياضي بما يناسب هدفك، مع اقتراحات لتمارين المرونة", "included": true}, {"text": "تصحيح تكنيك التمارين اللي تشك إنها غلط أو تسبب لك ألم", "included": true}, {"text": "التأكد من أن جودة تمرينك مناسبة للبناء العضلي", "included": true}]', NULL, 'جلسة عبر Google Meet أو واتساب — المناسب لك.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي.', false, NULL, 'published', 7, false, '2026-10-08 21:40:57.749859+00', '2026-10-08 21:40:57.749859+00', false) ON CONFLICT DO NOTHING;



INSERT INTO public.product_offers VALUES ('24826dea-e43d-407b-b77d-abaf204526bc', 'b5538d03-b270-444e-b3a7-d701c9652202', 'int1', 'شهر واحد', 1, 59900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('eb113f8b-d340-49a8-b5cd-738ce30f9700', 'b5538d03-b270-444e-b3a7-d701c9652202', 'int3', '3 أشهر', 3, 155000, 'SAR', true, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('6c4f9d76-1ad2-47b1-b1dd-8b1f1f9393e0', '6f440cac-3168-4d63-99f5-cda6663ad2b4', 'adv1', 'شهر واحد', 1, 49900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('212fd05a-80f9-4639-8bc4-f916ab794147', '6f440cac-3168-4d63-99f5-cda6663ad2b4', 'adv3', '3 أشهر', 3, 125000, 'SAR', true, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('167ffb5d-4d7f-43c8-8a7c-cadedea389a2', '8331fd33-4e81-4c1e-bd71-23c7d00c7737', 'bas1', 'شهر واحد', 1, 34900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('a95d926e-a005-4a99-ab8a-43c4ffd56a9e', '8331fd33-4e81-4c1e-bd71-23c7d00c7737', 'bas3', '3 أشهر', 3, 95000, 'SAR', true, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('5f73cc37-9909-4747-a963-6a23b376002d', '2cd3de2d-fa82-4681-b6f6-b22633ad4af6', 'nut1', 'شهر واحد', 1, 25000, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('ec04b64c-5bac-4817-8c5c-efa47eef2cfe', '8ae935d4-2bfc-4f9a-b518-febc1f2e2438', 'diy', 'دفعة واحدة', 0, 19900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('743e8c31-b2c7-42ab-8ac5-cad553825c74', '6c1b6ec8-b86e-43c5-aaef-49405bf8c3ce', 'diyN', 'دفعة واحدة', 0, 25000, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('69b6e683-3053-4449-a7d7-3051f8cb6b43', 'f3add678-25f8-4bd9-bc0e-adb6d32b0372', 'cN', 'دفعة واحدة', 0, 15000, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('1bf82456-64f8-4732-ab31-bcb2b6829a6b', '6804b34f-bc0c-41aa-9471-2eb186024848', 'cT', 'دفعة واحدة', 0, 18900, 'SAR', true, 0) ON CONFLICT DO NOTHING;



INSERT INTO public.reviews VALUES ('71ea3334-4e54-4f35-ae94-fb7493596f6d', 'legacy', NULL, NULL, NULL, NULL, 'اشتركت معها 3 شهور وكانت أول مره التزم بالتمرين بعد سحبات سنين، اسلوبها سهل وسريع بس نتايجه واضحه من اول اسبوعين قياسات جسمي بدت تتغير والكوتش مريحه نفسيًا وشاطرة الله يعطيها العافيه غيرت حياتي واعطتني افضل بداية 🙏🏻', 'first', 'ريم', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 0, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('e0d85b21-b727-4d1d-af6c-d93056cede3b', 'legacy', NULL, NULL, NULL, 5, 'من أصدق التجارب اللي مرّيت فيها! تدريبك ما كان بس جداول رياضه وتغذية كان دعم نفسي وتحفيز وتغيير حقيقي في حياتي حسّيت بفرق كبير في جسمي وطاقتي وثقتي بنفسي من أول أسبوع شكراً من القلب على تعبك وحرصك على كل تفصيلة وتعطي من قلبك، فعلاً you are the best coach ever تستاهلين كل النجاح والله ❤️', 'first', 'نورة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 1, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('fbcfaf8f-9b54-4dbe-86e4-3def5a2a4394', 'legacy', NULL, NULL, NULL, 5, 'بعد شهر من الالتزام بالجدول، لاحظت فرق واضح! متنوع وفعال، أنصح فيه بشدة 😍👌', 'first', 'البندري', 'مارس 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 2, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('44dc5d4f-1675-4287-aff2-7c5b54d53135', 'legacy', NULL, NULL, NULL, NULL, 'رغم ان فتره تدريبي معاها كانت اقل من شهرين السنه الماضيه الا ان نتايج هالشهرين مستمره معي الى اليوم 😍 اسلوب احترافي وفعال وتركز على بناء وتطوير عادات تدوم مو بس تمارين مؤقته 👍🏻', 'first', 'خديجة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 3, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('1dab98f7-bdd3-4ebf-af09-3d892f0158b1', 'legacy', NULL, NULL, NULL, 5, 'كوتش ساره جداً شاطره و بروفيشنال، جداً متعاونه و تعرف شغلها كويس، جداً لطيفه، كنت لفتره متدربه عندها و كنت أشوف نتايج بطله بالاضافه لكوني اروح اتمرن و أنا مستمتعه، شكراً ساره', 'first', 'نجمة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 4, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('cafb131f-050a-4f9d-8600-540197ee45ef', 'legacy', NULL, NULL, NULL, 5, 'ممتاز جدول حلو ومرتب جدا وفرق معي كثير 🤍', 'first', 'سعود', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 5, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('0c1ceb8c-7d6b-4ddb-a30c-d9fd7e773297', 'legacy', NULL, NULL, NULL, 5, 'كنت اعاني من الم بظهري مستمررر سنوات وانحراف بالعمود ولكن بفضل الله ثم المدربة تحسنت بنسبة كبيرة وتابع معي خطوة بخطوة بكل أمانة وإتقان الله يكثر من امثالك 🤍', 'first', 'ش**س**', 'أغسطس 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 6, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('a1278966-15b3-43d1-b6d6-6bcb6d0e7447', 'legacy', NULL, NULL, NULL, 5, 'الشكر يعجز عنك يااروع كوتش باشتراكي معك شفت صحة وراحة بعد الله وساعدتيني مره بمشكلة ظهري وضعف العضلات العلوية وانعكس على نفسيتي وادائي اليومي شكررا شكرا من القلب وياحظنا فيك', 'first', 'فاطمة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 7, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('d254e269-e4bd-4cbc-966e-24d6b26e0cc6', 'legacy', NULL, NULL, NULL, 5, 'مره استفدت بالتدريب مع كوتش ناف و مبسوطه ان في احد بذمة و ضمير جالس يتابع تقدمي و ينصحني من قلب الله يسعدك ويوفقك ❤️', 'first', 'ميثاء', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 8, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('77a54465-6905-4d46-aabd-30d9ecd82039', 'legacy', NULL, NULL, NULL, 5, 'تجربه ولا أروع ! أحب جداولها وقد ايش تختصر وتعطيك المهم والاهم والنتايج رهيييبه ❤️', 'first', 'أمجاد', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 9, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('89293578-db5a-4306-8b74-b9438bffb0c8', 'legacy', NULL, NULL, NULL, 5, 'افضل مدربة بالمجرة، كنت دبه ونحفت بثلاث شهور بس، i highly recommend her she is the best 💗', 'first', 'شروق', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 10, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('4e020d42-8bc0-4620-a1dc-13b59fdac881', 'legacy', NULL, NULL, NULL, 5, 'الجدول ممتاز و فعّال لفترة الصيام، يساعدك تنظم وقتك ويقدّم توصيات غذائيه و خطه تمارين تساعدك تحافظ على لياقتك بدون إرهاق 👍🏻. خيار ممتاز خاصة للأشخاص للي وقتها محدود ومزحوم فرمضان.', 'first', 'خديجة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 11, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;



INSERT INTO public.site_settings VALUES ('reminders', '{"review_text": "مرحباً {name}، تذكير بمراجعتك الأسبوعية: المراجعة مفتوحة من {window_start} إلى {window_end}.", "sub_expiry_days": [7, 3], "sub_expiry_text": "مرحباً {name}، اشتراكك في {product} ينتهي بتاريخ {end_date}. للتجديد أو الاستفسار تواصل معنا.", "review_lead_days": 1, "missed_review_text": "مرحباً {name}، ما وصلتنا مراجعة الأسبوع المنتهي في {window_end}. متى ما تيسّر لك، حدّثها عشان نتابع تقدمك.", "review_window_days": 2, "manual_cooldown_minutes": 10}', false, NULL, '2026-10-08 21:40:57.300855+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('hero', '{"lead": "خطة تدريب وغذاء منظمة، متابعة للتقدم، وتعديلات أسبوعية تناسب مستواك وظروفك.", "title": "برامج تدريب وتغذية مخصصة لأهدافك", "eyebrow": "Nav Coaching · الكوتش ساره", "tagline": "Where Passion Meets Quality", "title_tail": "تحت إشراف مدربة يدفعها الشغف"}', true, NULL, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('badges', '["خصم 10% للطلاب", "مجاني لأهل غزة", "ضمان استرجاع المبلغ بشروط"]', true, NULL, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('why', '[{"body": "البرنامج يُصمم بعد استبيان مفصل لهدفك وأيامك المتاحة وأدواتك وأي إصابة تحتاج مراعاة.", "title": "مبني على هدفك ومستواك"}, {"body": "مراجعة منتظمة بالفيديو أو الصوت، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.", "title": "متابعة أسبوعية واضحة"}, {"body": "نعدّل التمرين والسعرات بناءً على قياساتك والتزامك، عشان تثبت النتيجة.", "title": "تعديلات حسب تقدمك"}]', true, NULL, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('how_steps', '[{"body": "اختر الباقة والمدة، وعبّي استبيان قصير عن هدفك ومستواك وأيامك وأي إصابة.", "title": "اختر برنامجك وعبّي الاستبيان"}, {"body": "بعد الاستبيان يظهر لك رقم طلبك وبيانات الحساب. حوّل وارفع صورة الإيصال من صفحة طلبك.", "title": "حوّل المبلغ"}, {"body": "بعد التحقق من التحويل أتواصل معك خلال 48 ساعة عمل، وتستلم ملف برنامجك وتبدأ المتابعة.", "title": "استلم برنامجك وابدأ"}]', true, NULL, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('about', '{"bio": "مدربة شخصية معتمدة، أدرب منذ 2017. أساعدك تبني روتين تدريب وتغذية واضح يناسب هدفك ووقتك ومستواك، مع متابعة أسبوعية تساعدك تستمر وتتقدم.", "fit": ["اللي يؤمن إن التمرين أسلوب حياة، مو تمرين لشكل مؤقت أو لفترة الصيف بس.", "**وإذا ما التزمت؟** أحاول أفهم أسبابك، وأساعدك تعالجها بقدر ما أقدر. وإذا كان الموضوع أكبر من اللي أقدر أقدمه، أقول لك بصراحة وأعتذر عن تدريبك."], "name": "الكوتش ساره | ناڤ", "certs": ["Saudi Reps — Level 4", "NCSF", "Menno Henselmans CPT", "Functional Mobility", "Pre & Postnatal Training", "Prenatal Fitness Training — Aspire Academy", "ماجستير تدريب رياضي — جامعة ستيرلنق"], "notes": [{"body": "لأني جاية من عالم الرياضات الإلكترونية، صممت باقة خاصة للقيمرز: لياقة أفضل داخل وخارج الشاشة، والتعامل مع آلام الظهر والمفاصل من الجلوس الطويل.", "href": "/programs/gamers", "label": "شوف باقة القيمرز ←", "title": "للاعبي الألعاب الإلكترونية"}, {"body": "تدريب الحوامل عندي حضوري فقط. أونلاين يصعب أتأكد إن التمرين يتنفذ بإتقان، والحمل فترة مهمة جداً تحتاج هالتأكد. أونلاين أقدم للحوامل متابعة التغذية فقط.", "href": "", "label": "", "title": "للحوامل"}], "story": ["قبل ما أصير مدربة، كنت متدربة تعبت من التجارب. اشتركت مع مدربات أجانب، وما لقيت أحد يشرح لي التمرين صح أو يهتم بأهدافي.", "لين اشتركت مع الكوتش سحر الحارثي. غيّرت نظرتي للتمرين، وحفّزتني أصير كوتش، وإلى اليوم أشكرها على كل اللي علمتني إياه. من هنا قررت أكون الشخص اللي احتجته أنا.", "والرياضة جزء مني من بدري: لعبت كرة السلة وكنت كابتن فريق السلة في جامعة الإمام عبدالرحمن بن فيصل، ولعبت باحتراف في الرياضات الإلكترونية. بدأت التدريب في 2017 مع كرة السلة، واشتغلت مساعد مدرب في نادي الجامعة، وبعدها دربت في بيور جم وجمنيشن وفتنس لاونج ونوادي خاصة."], "points": ["برنامج مبني على هدفك ومستواك.", "متابعة أسبوعية واضحة.", "تعديلات مستمرة حسب تقدمك والتزامك."], "pillars": [{"body": "ما أرسل لك جدول وأتركك. أراجعه معك بمقطع فيديو أشرح فيه كل شي، عشان تبدأ وأنت فاهم وش تسوي وليش.", "title": "جدولك مشروح بالفيديو"}, {"body": "ما أمشي على أنظمة الحرمان أبداً. خطتك تناسب حياتك، مو قائمة ممنوعات.", "title": "بدون حرمان"}, {"body": "أتابعك كل أسبوع وأهتم بالتزامك، وأعدّل خطتك حسب تقدمك وظروفك.", "title": "متابعة جادة وخطة واقعية"}, {"body": "حب تعليم الناس معي من الصغر. اللي أعرفه ما أبخل فيه، علمياً ونفسياً، وما أوقف عن البحث والتعلم عشان أتطور وأطورك معي.", "title": "أعلّمك، مو بس أدربك"}], "home_bio": "مدربة شخصية معتمدة، أدرب منذ 2017، وكابتن سابقة لفريق السلة في جامعة الإمام عبدالرحمن بن فيصل. أساعدك تبني روتين تدريب وتغذية واضح يناسب هدفك ووقتك ومستواك، مع متابعة أسبوعية وبدون أنظمة حرمان.", "fit_title": "أكثر شخص أفرق معه", "experience": ["أدرب منذ 2017، والبداية في كرة السلة.", "مساعد مدرب في نادي الجامعة.", "مدربة في بيور جم، وجمنيشن، وفتنس لاونج، ونوادي خاصة."], "story_title": "صرت الشخص اللي كنت أحتاجه", "pillars_title": "وش يميز التدريب معي؟", "experience_title": "شهاداتي وخبرتي"}', true, NULL, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('intro_video', '{"url": "", "body": "مقطع قصير أتكلم فيه عن نفسي وخلفيتي وطريقة شغلي مع المتدربين.", "title": "تعرّف عليّ في دقيقة"}', true, NULL, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('testimonials_disclaimer', '"التجارب شخصية وتختلف النتائج من شخص لآخر حسب الالتزام والحالة، والتدريب لا يغني عن استشارة الطبيب أو أخصائي العلاج الطبيعي."', true, NULL, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('prices_note', '"الأسعار بالريال السعودي. الدفع بتحويل بنكي على حساب المؤسسة."', true, NULL, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('checkins', '{"enabled": true, "questions": [{"q": "ملاحظاتك الصحية؟ الحركة اليومية وجودة الحياة صارت أحسن؟", "topic": "الصحة العامة"}, {"q": "أداؤك في التمارين؟ في تقدم في الأوزان والأداء؟", "topic": "التمارين"}, {"q": "فرق في شكلك ومظهرك؟ إيجابي أو سلبي؟", "topic": "المظهر"}, {"q": "فرق في الملابس أو المقاسات؟ إيجابي أو سلبي؟", "topic": "الملابس"}, {"q": "النظام الغذائي — قدرت تمشي عليه؟ فيه صعوبة؟", "topic": "الغذاء"}, {"q": "تحسّ بالجوع واجد؟ إن وُجد، كم تعطيه من 5؟", "topic": "الجوع"}, {"q": "أي ملاحظات سلبية تبي تشاركها؟ (مهمة أو بسيطة — نتقبل النقد)", "topic": "ملاحظات سلبية"}, {"q": "أي إشكاليات أو ملاحظات إضافية تحتاج مساعدة فيها؟", "topic": "ملاحظات أخرى"}, {"q": "وصلت لأي أسبوع تدريبي الآن؟", "topic": "الأسبوع"}]}', true, NULL, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('contact', '{"whatsapp": "966599162724", "instagram": "https://www.instagram.com/navvcoaching/"}', true, NULL, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('response_time', '"48 ساعة عمل (الأحد – الخميس، 12 ظهراً – 9 مساءً)"', true, NULL, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('legal', '{"cr": "7050950752", "name": "مؤسسة ناف كوتشنق للتدريب الرياضي"}', true, NULL, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('bank', '{"iban": "SA1280000139608016245411", "bankName": "مصرف الراجحي", "accountName": "مؤسسة ناف كوتشنق للتدريب الرياضي"}', true, NULL, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('program_shots', '[{"h": 720, "w": 754, "alt": "لقطة من صفحة «حسابي» ببيانات مثال: شريط الالتزام، أيام تمرين الأسبوع الحالي، ملخص تغذية اليوم، وروتين المكملات", "src": "shots/my-program.webp", "title": "برنامجي", "caption": "أول ما تدخل حسابك: نسبة التزامك وأسابيعك المتتالية، أيام تمرين الأسبوع، تغذية اليوم مقابل أهدافك، وروتين المكملات."}, {"h": 960, "w": 1148, "alt": "لقطة من صفحة برنامج التمرين ببيانات مثال: أيام الأسبوع، وبطاقة كل تمرين مع المستهدف وخانات الوزن والتكرارات وRIR", "src": "shots/training-log.webp", "title": "تسجيل التمرين", "caption": "لكل تمرين المستهدف من الجولات والتكرارات وRIR، وتسجّل وزنك وتكراراتك من جوالك، ولك تبديله ببديل تختاره المدربة."}, {"h": 1020, "w": 1148, "alt": "لقطة من صفحة التغذية ببيانات مثال: ملخص اليوم مقابل الأهداف، ونموذج إضافة أكلة، وأكل اليوم حسب الوجبات", "src": "shots/nutrition-day.webp", "title": "التغذية اليومية", "caption": "أهدافك اليومية من السعرات والماكروز وكم باقي لك، وتسجّل أكلك من جداولك الغذائية أو بالغرام من قاعدة الأكل."}, {"h": 307, "w": 1116, "alt": "لقطة من لوحة التقدم ببيانات مثال: رسم الوزن ورسم القياسات", "src": "shots/progress-charts.webp", "title": "لوحة التقدم", "caption": "وزنك وقياساتك برسوم واضحة أسبوعاً بأسبوع، ببيانات مثال."}]', true, NULL, '2026-10-08 21:40:57.749859+00') ON CONFLICT DO NOTHING;
COMMIT;
