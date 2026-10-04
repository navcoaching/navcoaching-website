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
INSERT INTO public.exercises VALUES ('7316dbed-1e2a-4507-b282-5f9d0f902bcf', 'Single Leg Raise', 'Core / البطن والكور', '{"Glutes / المؤخرة","Hamstrings / الخلفية"}', NULL, NULL, 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/ZJodU5OOaiA?si=p6ZD9dpzyRKBUn16', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e6fa6527-f9b7-4106-a07d-87264f89b50b', 'left over db', 'Functional / التمارين الوظيفية', '{}', NULL, NULL, 'دمبل', NULL, 'منزل', 'https://youtu.be/pLnRt-caepc?si=DAS9jeYr8vS6RRtz', 'طبق الحركة بأقصى عدد ممكن من التكرارات وأحسبها كجولة، ثم ابدأ بالجولة الثانية بنفس الطريقة', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('89e96d6a-7438-4e63-9704-a2af03aef649', 'Forward Lunges', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/_DLAdo2Pvjs', 'تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness | ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, 'تقوية الورك ضمن نمط حركي وظيفي', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Distefano et al. 2009 — JOSPT (EMG) | Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin)', 'https://pubmed.ncbi.nlm.nih.gov/19574661/ | https://pubmed.ncbi.nlm.nih.gov/33344003/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8cfd4124-5f05-4a7e-bdbc-561b3a13d2ac', 'Single Leg Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'وزن الجسم', 'متقدم', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/136/single-leg-squat/', 'ضعف الألوية الكبرى / Gluteus Maximus Weakness | ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Single-leg Squat / سكوات رجل واحدة', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, 'تقوية باسطات ومبعدات الورك وتحكم أحادي الطرف', 'متقدمة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ يتطلب تحكماً جيداً بالركبة والحوض', 'Distefano et al. 2009 — JOSPT (EMG) | Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin)', 'https://pubmed.ncbi.nlm.nih.gov/19574661/ | https://pubmed.ncbi.nlm.nih.gov/33344003/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('bbf3b861-0622-41ec-9180-e0db7de7e597', 'Hip Abduction', 'Abductors / مبعدات الفخذ', '{"Glutes / المؤخرة"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/_ARUxqrII3Y?si=Jcz5uh2Uu-IdVCS1', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL, 'تقوية مبعدات الورك بمقاومة خارجية', 'مبكرة–متوسطة', 'منخفض–متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ الدليل يخص إبعاد الورك بمقاومة خارجية؛ يُتحقق من نوع الأداء', 'Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin)', 'https://pubmed.ncbi.nlm.nih.gov/33344003/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('903a9e33-bf48-46ad-bcd6-cf1df2d00834', 'Side Step Up', 'Glutes / المؤخرة', '{"Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/xOwIRnI4VxA?si=SJOgODRmNGdfHPb4', 'يد فيها الوزن واليد الثانية سندها على الجدار', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية المتوسطة / Gluteus Medius Weakness | ضعف الألوية الصغرى / Gluteus Minimus Weakness', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, 'تقوية مبعدات الورك والتحكم بالحوض على رجل واحدة', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin) | Ganderton et al. — GMin/GMed EMG (RMIT University)', 'https://pubmed.ncbi.nlm.nih.gov/33344003/ | https://research-repository.rmit.edu.au/articles/journal_contribution/Gluteus_Minimus_and_Gluteus_Medius_Muscle_Activity_during_Common_Rehabilitation_Exercises_in_Healthy_Postmenopausal_Women/27572301', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9f66a499-3b22-418d-b9a1-40ba022ba516', 'Glute Bridge', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', NULL, 'مبتدئ', NULL, 'https://www.youtube.com/watch?v=dtlGynVdHYM', 'ممكن تسويه بالسميث مشين او البار الحر ، اختر بوكس او بنش يكون بمستوى اكتافك الخلفية وانت جالس، لما ترفع البار فوق المفروض ركبك تكون بنفس مستوى القدم.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness | آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, 'تقوية بسط الورك وتحمّل الجذع', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Boren et al. 2011 — IJSPT (EMG) | JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/22034614/ | https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('677ab63e-2c76-4bf0-a0f6-e4731c733533', 'DB Floor Glute Bridge', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/iOrJXNUH3to?si=JySX6JMhoP2vWEVa', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, 'تقوية بسط الورك بتحميل خارجي متدرج', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Boren et al. 2011 — IJSPT (EMG)', 'https://pubmed.ncbi.nlm.nih.gov/22034614/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('120118ca-94ab-4915-a62c-9120528cddc9', 'Single DB RDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/U3prDlAbJDw?si=MRSBcSIcf9M-WQBH', 'وقف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، انزل وادفع مؤخرتك لآخر شي تقدر عليه للخلف وكأنك بتلمس جدار خلفك مع انثناء بسيط بالركب', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف الألوية الكبرى / Gluteus Maximus Weakness', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, 'تقوية باسطات الورك وتحكم أحادي الطرف', 'متقدمة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ مع الحفاظ على وضع محايد للظهر', 'Distefano et al. 2009 — JOSPT (EMG)', 'https://pubmed.ncbi.nlm.nih.gov/19574661/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('bfa93a90-2721-49f9-881a-5ffb31c0cc79', 'Upper Back Horizontal Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/TSWohpfMlso', 'ثبت نفسك بالكرسي، فتحة واسعة، الكيبل بمستوى أعلى صدرك، واسحب لما تنقبض الترابز.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Wide-grip Row / تجديف بقبضة واسعة', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', 'تقوية انكماش لوح الكتف والظهر العلوي', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moseley et al. 1992 — AJSM (EMG, scapular muscles)', 'https://pubmed.ncbi.nlm.nih.gov/1558238/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6bfffecb-1da8-446c-a757-c1a705356c47', 'Seated Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/0G3W83dFUeY', 'اسحب باتجاه الورك.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness | تحدب الظهر / Postural Thoracic Kyphosis', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', 'تقوية سحب وانكماش لوح الكتف', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moseley et al. 1992 — AJSM (EMG, scapular muscles) | Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://pubmed.ncbi.nlm.nih.gov/1558238/ | https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('11731a7a-aeaf-4b80-9d6e-333bbda92732', 'Band Seated Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/Jy-WCFAofBY?si=9gqVby588rk1zFi9', 'فتحة واسعة، واسحب لما تنقبض عضلات الظهر.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness | تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', 'تقوية سحب لوح الكتف بمقاومة منخفضة', 'مبكرة–متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moseley et al. 1992 — AJSM (EMG, scapular muscles) | Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://pubmed.ncbi.nlm.nih.gov/1558238/ | https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2ba56edc-e215-4a95-a4b3-996f8b91aadd', 'Chest Supported Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/DgHtyrQEMJ4?si=oTfTKVgD9j1H12wA', 'ثبت صدرك على الكرسي، فتحة واسعة، واسحب لما تنقبض عضلات الظهر.', NULL, 'المكتبة الأصلية', NULL, NULL, 'ضعف العضلة المعينية / Rhomboid Weakness', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', 'تقوية انكماش لوح الكتف مع دعم الجذع', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moseley et al. 1992 — AJSM (EMG, scapular muscles)', 'https://pubmed.ncbi.nlm.nih.gov/1558238/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e8f36187-38ca-4f7f-a8f2-112c7a96dbaf', 'Plank', 'Core / البطن والكور', '{"Shoulders / الأكتاف","Glutes / المؤخرة"}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/pvIjsG5Svck?si=cTP8ZyfMAJPfaEhw', 'لما ترتفع الاكتاف تكون فوق الكوع والرجل ممتدة بالكامل.', NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL, 'تحمّل عضلات الجذع', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('715fb635-5d30-4b20-ab62-2b863bcca46a', 'deadbug', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/g_BYB0R-4Ws?si=D4nwJri73eBqJRqL', NULL, 'اسم مشابه موجود في المكتبة (deadbug / dead bug) — تُراجَع قبل الحذف أو الدمج', 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'rejected', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL, 'التحكم الحركي وتحمّل الجذع', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7da5aeb0-6856-4cec-b7fb-145598a12e89', 'Band Dead Bug', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'مطاط', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/iW_CtYtzbeU?si=Epequw3rqA3_TwTr', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL, 'التحكم الحركي وتحمّل الجذع بمقاومة', 'مبكرة–متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a7782ff9-42df-41ab-9dfa-676554488e5b', 'Side Plank', 'Core / البطن والكور', '{"Abductors / مبعدات الفخذ","Shoulders / الأكتاف"}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'لما ترتفع الاكتاف تكون فوق الكوع والرجل ممتدة بالكامل.', NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain | ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Anti-Lateral Flexion / مقاومة الميلان الجانبي', 'Isometric Anti-Lateral Flexion / تثبيت الجذع ضد الميلان', NULL, 'تحمّل الجذع الجانبي وتنشيط مبعدات الورك', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.) | Boren et al. 2011 — IJSPT (EMG)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/ | https://pubmed.ncbi.nlm.nih.gov/22034614/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('10259de7-32cf-4ee8-baeb-8f31c65b19cf', 'McGill Big 3', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/jZylx81_kfg?si=_jP064GZIzvEvzyN', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Mixed (McGill Big 3) / مختلط', 'Isometric Trunk Stabilization / تثبيت الجذع', NULL, 'التحكم الحركي وتحمّل الجذع', 'مبكرة–متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f5240e82-ae6d-4243-a04c-9d2de3d2ed1c', 'Dead Bug', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/bxn9FBrt4-A', 'نحرك الرجلين ببطئ قليلا و بتحكم باستخدام عضلات البطن', 'اسم مشابه موجود في المكتبة (deadbug / dead bug) — تُراجَع قبل الحذف أو الدمج', 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL, 'التحكم الحركي وتحمّل الجذع', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4b9e3f17-3a25-4ccd-a5be-837366041264', 'Bird Dog', 'Core / البطن والكور', '{"Lower back / أسفل الظهر","Glutes / المؤخرة"}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/L91QMACdA6Q?si=KBnuQDcm9WcUXxxI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Anti-Rotation / مقاومة الدوران', 'Isometric Anti-Rotation / تثبيت الجذع ضد الدوران', NULL, 'التحكم الحركي وتحمّل الجذع', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8bdc0885-9945-4a34-a377-b59d4016dbf8', 'High-Load Heel Raise (Towel Under Toes)', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', NULL, 'مبتدئ', NULL, NULL, 'رفع الكعب على رجل واحدة مع منشفة ملفوفة تحت أصابع القدم؛ صعود بطيء ثم ثبات قصير ثم نزول بطيء.', 'أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Rathleff et al. 2015 — Scand J Med Sci Sports (RCT)', 'https://doi.org/10.1111/sms.12313', 'اللفافة الأخمصية / Plantar Fasciopathy', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL, 'تحميل تدريجي للقدم والكاحل', 'متقدمة', 'مرتفع', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ يُبدأ بعد تحسّن الأعراض وبتدرّج', 'Rathleff et al. 2015 — Scand J Med Sci Sports (RCT) | JOSPT CPG 2023 — Heel Pain/Plantar Fasciitis (Koc et al.)', 'https://doi.org/10.1111/sms.12313 | https://pubmed.ncbi.nlm.nih.gov/38037331/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0c265167-6ec2-4d23-a62b-009ed6ebb17e', 'Side Lunge', 'Adductors / الأفخاذ الداخلية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/50/side-lunge/', 'ضعف الألوية المتوسطة / Gluteus Medius Weakness', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Lateral Lunge / لانج جانبي', 'Knee/Hip Extension + Hip Adduction / مد الركبة والورك + تقريب الورك', NULL, 'تقوية مبعدات الورك والتحكم بالحوض', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin)', 'https://pubmed.ncbi.nlm.nih.gov/33344003/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2856d763-a287-4778-ae0e-2ce21cdcbef9', 'Hip Hitch (Pelvic Drop)', 'Abductors / مبعدات الفخذ', '{}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Ganderton et al. — GMin/GMed EMG (RMIT University)', 'https://research-repository.rmit.edu.au/articles/journal_contribution/Gluteus_Minimus_and_Gluteus_Medius_Muscle_Activity_during_Common_Rehabilitation_Exercises_in_Healthy_Postmenopausal_Women/27572301', 'ضعف الألوية المتوسطة / Gluteus Medius Weakness | ضعف الألوية الصغرى / Gluteus Minimus Weakness', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Pelvic Drop (Stance Leg) / تثبيت الحوض برجل الارتكاز', 'Hip Abduction of Stance Leg / تبعيد ورك رجل الارتكاز', NULL, 'تنشيط وتقوية مبعدات الورك (الألوية المتوسطة والصغرى) والتحكم بالحوض', 'مبكرة–متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Ganderton et al. — GMin/GMed EMG (RMIT University) | Moore et al. 2020 — IJSPT (Systematic review, GMed/GMin)', 'https://research-repository.rmit.edu.au/articles/journal_contribution/Gluteus_Minimus_and_Gluteus_Medius_Muscle_Activity_during_Common_Rehabilitation_Exercises_in_Healthy_Postmenopausal_Women/27572301 | https://pubmed.ncbi.nlm.nih.gov/33344003/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('002a8c0f-53a7-421f-8a6d-9b0af59434a1', 'Shoulder I-Y-T-W Series', 'Rotator cuffs / الكفة المدورة', '{"Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/237/shoulder-stability-mobility-series-i-y-t-w-formations/', 'تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture | ضعف العضلة المعينية / Rhomboid Weakness', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'I-Y-T-W / تمارين I-Y-T-W', 'Scapular Retraction/Depression + Arm Elevation / سحب وخفض لوح الكتف مع رفع الذراع', NULL, 'تقوية وتحكم عضلات لوح الكتف (الانكماش والتدوير)', 'مبكرة–متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis) | Sheikhhoseini et al. 2018 — JMPT (Systematic review, FHP) | Castelein et al. 2016 — Man Ther (EMG, rhomboid)', 'https://doi.org/10.1186/s12891-024-07224-4 | https://pubmed.ncbi.nlm.nih.gov/30107937/ | https://pubmed.ncbi.nlm.nih.gov/26409441/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cb981cfb-2d25-4235-b1a4-c408a199e581', 'Supine Snow Angel (Wipers)', 'Rotator cuffs / الكفة المدورة', '{"Shoulders / الأكتاف","Core / البطن والكور"}', 'Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/124/supine-snow-angel-wipers-exercise/', 'تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Snow Angel / الملاك', 'Shoulder Abduction/Adduction + Scapular Control / تبعيد وتقريب الكتف مع تحكم لوح الكتف', NULL, 'حركة الكتف والتحكم بلوح الكتف', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('50dbcb6e-dfec-4c0e-9a94-4cd82cdfdd45', 'Back Extension', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة","Hamstrings / الخلفية"}', 'Spinal Extension / بسط الجذع', 'كور', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/bs7S3RFyIYs?si=tDLl3OYuDBIwK4Fj', NULL, 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «Functional Training»)', 'المكتبة الأصلية', NULL, NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain | تحدب الظهر / Postural Thoracic Kyphosis', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Back Extension / بسط الظهر', 'Hip Extension + Spinal Extension / بسط الورك + بسط العمود الفقري', NULL, 'تقوية باسطات الظهر', 'متقدمة', 'متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ يُراجَع إذا زاد الألم مع الامتداد', 'JOSPT CPG 2021 — Low Back Pain (George et al.) | Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://pubmed.ncbi.nlm.nih.gov/34719942/ | https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('79fd97af-8700-4fbc-ae38-d5e3768f1a56', 'Supermans', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة","Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Spinal Extension / بسط الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/9/supermans/', 'تحدب الظهر / Postural Thoracic Kyphosis | آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Prone Extension / بسط على البطن', 'Spinal Extension / بسط العمود الفقري', NULL, 'تقوية باسطات الظهر والتحكم الوضعي', 'متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis) | JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://doi.org/10.1186/s12891-024-07224-4 | https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9af66d5a-2694-49ec-b7ff-9d488bb73d31', 'Standing Dorsi-Flexion (Calf Stretch)', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/152/standing-dorsi-flexion-calf-stretch/', 'اللفافة الأخمصية / Plantar Fasciopathy', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Calf Stretch / إطالة البطات', 'Ankle Dorsiflexion / ثني ظهري للكاحل', NULL, 'إطالة عضلات الساق', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2023 — Heel Pain/Plantar Fasciitis (Koc et al.)', 'https://pubmed.ncbi.nlm.nih.gov/38037331/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b7205f18-01e0-411c-b5d0-a044cf023eb0', 'Cat-Cow', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/15/cat-cow/', 'تحدب الظهر / Postural Thoracic Kyphosis | آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Spinal Mobility / مرونة العمود الفقري', 'Spinal Flexion/Extension / ثني وبسط العمود الفقري', NULL, 'حركة العمود الفقري ضمن مدى حركة مريح', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis) | JOSPT CPG 2021 — Low Back Pain (George et al.)', 'https://doi.org/10.1186/s12891-024-07224-4 | https://pubmed.ncbi.nlm.nih.gov/34719942/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c6be0795-8101-4108-8021-b0fd0c309eaf', 'Plantar Fascia-Specific Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'تُسحب أصابع القدم للخلف باليد حتى يُشعر بشد في باطن القدم، مع تحسّس اللفافة للتأكد من الشد.', 'أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Rathleff et al. 2015 — Scand J Med Sci Sports (RCT)', 'https://doi.org/10.1111/sms.12313', 'اللفافة الأخمصية / Plantar Fasciopathy', 'review', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Plantar Fascia Stretch / إطالة اللفافة الأخمصية', 'Toe Extension + Ankle Dorsiflexion / مد أصابع القدم + ثني ظهري', NULL, 'إطالة اللفافة الأخمصية', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'JOSPT CPG 2023 — Heel Pain/Plantar Fasciitis (Koc et al.) | Rathleff et al. 2015 — Scand J Med Sci Sports (RCT)', 'https://pubmed.ncbi.nlm.nih.gov/38037331/ | https://doi.org/10.1111/sms.12313', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d62d0cbd-1ccf-4b04-9713-fa66de7b1ada', 'Bosu Ball Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'أخرى', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/KjvDgHPxXcg?si=zad59CHC6Y-calzi', 'ملاحظات مهمة:
• ارفع الكتفين بتقوّس الجذع قليلاً ولا تسحب الرقبة باليدين.
• زفير عند الرفع وانقباض البطن لثانية.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Crunch / كرنش', 'Trunk Flexion / ثني الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('803aa33d-830a-4461-9369-c8a8c0ab4a55', 'Crab Reach (Thoracic Bridge)', 'Functional / التمارين الوظيفية', '{"Glutes / المؤخرة","Shoulders / الأكتاف"}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://www.youtube.com/watch?v=fgsUe3Lc3hI', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'تحدب الظهر / Postural Thoracic Kyphosis', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Thoracic Bridge / جسر صدري', 'Hip Extension + Thoracic Rotation / بسط الورك + دوران الصدر', NULL, 'حركة الامتداد والدوران الصدري', 'متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ يتطلب تحمّلاً جيداً للرسغ والكتف', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c9cb6258-2ed7-4b08-b64d-2075f4d8d4cd', 'Prone Swimmer', 'Functional / التمارين الوظيفية', '{"Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Shoulder Rear Pull / سحب خلفي للكتف', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://www.youtube.com/watch?v=M8a1cgnhyqk', NULL, NULL, 'المكتبة الأصلية', NULL, NULL, 'تحدب الظهر / Postural Thoracic Kyphosis | وضعية الرأس للأمام / Forward Head Posture', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Prone Swimmer / سبّاح على البطن', 'Shoulder Extension/Abduction + Rotation / مد وتبعيد الكتف مع الدوران', NULL, 'تحمّل عضلات لوح الكتف والامتداد الصدري', 'متوسطة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة', 'Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c068ff33-c85e-4a0d-895e-1d0f8e3d999c', 'Isometric Wrist Extension', 'Forearms / الساعد', '{}', 'Wrist Extension / مد الرسغ', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'مرفق التنس / Lateral Elbow Tendinopathy', 'review', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Isometric / ثابت', 'Wrist Extension / مد الرسغ', NULL, 'تحميل تدريجي لباسطات الرسغ (انقباض ثابت)', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ ضمن ألم مقبول لا يتزايد بعد التمرين', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a9f4dcde-bf3d-4a58-84d8-427a0d3f2ed5', 'Eccentric Wrist Extension', 'Forearms / الساعد', '{}', 'Wrist Extension / مد الرسغ', 'قوة', NULL, 'مبتدئ', NULL, NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'مرفق التنس / Lateral Elbow Tendinopathy', 'review', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Eccentric / لامركزي', 'Wrist Extension / مد الرسغ', NULL, 'تحميل تدريجي لباسطات الرسغ (لامركزي)', 'متوسطة', 'منخفض–متوسط', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ ضمن ألم مقبول لا يتزايد بعد التمرين', 'JOSPT CPG 2022 — Lateral Elbow Pain (Lucado et al.)', 'https://www.orthopt.org/uploads/content_files/files/jospt.2022.0302.pdf', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6253e2bb-430c-4f54-b35f-10156bedd126', 'Chin Tuck (Deep Neck Flexor)', 'Neck / الرقبة', '{}', 'Neck Flexion (Deep Flexors) / ثني الرقبة العميق', 'إحماء/تفعيل', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, NULL, 'خطوات الأداء التفصيلية في «رابط المصدر» / حسب المختص || أُضيف لسد نقص في التصنيف التأهيلي', 'مصدر خارجي موثوق', 'Sheikhhoseini et al. 2018 — JMPT (Systematic review, FHP)', 'https://pubmed.ncbi.nlm.nih.gov/30107937/', 'وضعية الرأس للأمام / Forward Head Posture', 'review', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Chin Tuck / سحب الذقن', 'Upper Cervical Flexion + Retraction / ثني علوي للرقبة مع سحبها للخلف', NULL, 'تحكم عضلات الرقبة العميقة ووضعية الرأس', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي وتحت إشراف مختص عند الحاجة؛ يُوقف مع دوخة أو ألم/تنميل يمتد للذراع', 'Sheikhhoseini et al. 2018 — JMPT (Systematic review, FHP) | Sepehri et al. 2024 — BMC Musculoskelet Disord (Systematic review: FHP / kyphosis)', 'https://pubmed.ncbi.nlm.nih.gov/30107937/ | https://doi.org/10.1186/s12891-024-07224-4', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f2282c3e-840b-4074-a40d-63e13697fb5d', 'Terminal Knee Extension (Band)', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'مطاط', 'مبتدئ', 'منزل', NULL, 'اربط الشريط المطاطي خلف الركبة وقف بثبات. من ركبة مثنية قليلاً، افرد الركبة بالكامل ببطء وشد عضلة الفخذ الأمامية ثانية، ثم ارجع ببطء. 2–3 مجموعات × 12–15 تكرار.', NULL, 'مصدر خارجي موثوق', 'JOSPT CPG 2019 — Patellofemoral Pain (Willy et al.)', 'https://doi.org/10.2519/jospt.2019.0302', 'ألم الرضفة والفخذ (الركبة الأمامية) / Patellofemoral Pain', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Knee Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, 'تقوية الفخذ الأمامي في مدى آمن للركبة', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي. يكون الألم أثناء التمرين خفيفاً ومقبولاً (حتى 3 من 10) ويهدأ خلال 24 ساعة، وإذا زاد الألم أو ظهر تورم أو إحساس بقفل أو خذلان في الركبة يتوقف التمرين وتُراجَع أخصائي.', 'Willy et al. 2019 — JOSPT (Patellofemoral Pain CPG) | Lack et al. 2015 — Br J Sports Med (Proximal muscle rehabilitation for PFP, meta-analysis)', 'https://doi.org/10.2519/jospt.2019.0302 | https://bjsm.bmj.com/content/49/21/1365', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ffc9ccbf-85fe-4022-af22-676561ee5d47', 'Single Leg Press', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/ZYDTJaAM-gE', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.

ملاحظات مهمة:
• لا تفرد الركبة بقوة في الأعلى، وحافظ على الحوض ثابتاً على المقعد.
• انزل بتحكم بدون أن ترتفع الأرداف.
• اضبط المقعد والمساند لتتماشى مفاصلك مع محور الجهاز قبل البدء، وسجّل الإعدادات لتكررها.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Single-leg Press / ضغط رجل واحدة', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('07ffc2c5-09fa-4c50-8899-03fd296b7690', 'Mini Squat (Partial Range)', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'انزل نزولاً جزئياً فقط (حتى نحو 45° من ثني الركبة) مع ثبات الركبة فوق القدم وعدم انهيارها للداخل، ثم اصعد. 2–3 مجموعات × 10–15 تكرار. زد المدى تدريجياً حسب الراحة.', NULL, 'مصدر خارجي موثوق', 'JOSPT CPG 2019 — Patellofemoral Pain (Willy et al.)', 'https://doi.org/10.2519/jospt.2019.0302', 'ألم الرضفة والفخذ (الركبة الأمامية) / Patellofemoral Pain', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, 'تقوية الفخذ الأمامي والورك بحمل خفيف على مفصل الرضفة', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي. يكون الألم أثناء التمرين خفيفاً ومقبولاً (حتى 3 من 10) ويهدأ خلال 24 ساعة، وإذا زاد الألم أو ظهر تورم أو إحساس بقفل أو خذلان في الركبة يتوقف التمرين وتُراجَع أخصائي.', 'Willy et al. 2019 — JOSPT (Patellofemoral Pain CPG) | Lack et al. 2015 — Br J Sports Med (Proximal muscle rehabilitation for PFP, meta-analysis)', 'https://doi.org/10.2519/jospt.2019.0302 | https://bjsm.bmj.com/content/49/21/1365', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('55579ba6-8f24-42e7-a036-7aef6ac7b143', 'Lateral Step-Down (Slow Eccentric)', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Abductors / مبعدات الفخذ"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', NULL, 'قف على حافة درجة بقدم واحدة. انزل بالقدم الأخرى ببطء (3 ثوانٍ) مع إبقاء الحوض مستوياً والركبة فوق أصابع القدم، المس الأرض بخفة ثم اصعد. 2–3 مجموعات × 8–12 تكرار لكل رجل.', NULL, 'مصدر خارجي موثوق', 'JOSPT CPG 2019 — Patellofemoral Pain (Willy et al.)', 'https://doi.org/10.2519/jospt.2019.0302', 'ألم الرضفة والفخذ (الركبة الأمامية) / Patellofemoral Pain', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Step-up / صعود الدرجة', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, 'تحكم الورك والركبة أثناء الحمل على رجل واحدة', 'متوسطة', 'متوسط', 'يُستخدم بعد تقييم فردي. يكون الألم أثناء التمرين خفيفاً ومقبولاً (حتى 3 من 10) ويهدأ خلال 24 ساعة، وإذا زاد الألم أو ظهر تورم أو إحساس بقفل أو خذلان في الركبة يتوقف التمرين وتُراجَع أخصائي.', 'Willy et al. 2019 — JOSPT (Patellofemoral Pain CPG) | Lack et al. 2015 — Br J Sports Med (Proximal muscle rehabilitation for PFP, meta-analysis)', 'https://doi.org/10.2519/jospt.2019.0302 | https://bjsm.bmj.com/content/49/21/1365', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1e4b9ce9-5145-4bb2-8e71-68326f1ba5f5', 'Clamshell', 'Glutes / المؤخرة', '{"Abductors / مبعدات الفخذ"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'استلقِ على جنبك وركبتاك مثنيتان 45° وقدماك ملتصقتان. افتح الركبة العليا كالصدفة دون تحريك الحوض للخلف، ثم أغلقها ببطء. 2–3 مجموعات × 12–20 تكرار. يمكن إضافة شريط مطاطي للتدرج.', NULL, 'مصدر خارجي موثوق', 'BJSM 2015 — Proximal muscle rehabilitation for PFP (Lack et al.)', 'https://bjsm.bmj.com/content/49/21/1365', 'ألم الرضفة والفخذ (الركبة الأمامية) / Patellofemoral Pain', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Hip External Rotation / دوران الورك للخارج', 'Hip External Rotation / دوران الورك للخارج', NULL, 'تقوية دوران الورك الخارجي والألوية الوسطى', 'مبكرة', 'منخفض', 'يُستخدم بعد تقييم فردي. يكون الألم أثناء التمرين خفيفاً ومقبولاً (حتى 3 من 10) ويهدأ خلال 24 ساعة، وإذا زاد الألم أو ظهر تورم أو إحساس بقفل أو خذلان في الركبة يتوقف التمرين وتُراجَع أخصائي.', 'Willy et al. 2019 — JOSPT (Patellofemoral Pain CPG) | Lack et al. 2015 — Br J Sports Med (Proximal muscle rehabilitation for PFP, meta-analysis)', 'https://doi.org/10.2519/jospt.2019.0302 | https://bjsm.bmj.com/content/49/21/1365', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7da5bc06-8c0f-488f-807d-3a2ace4cc608', 'Wall Sit (Isometric Quad Hold)', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'ضع ظهرك على الحائط وانزل حتى ركبتين مثنيتين بزاوية مريحة (نحو 60–90°) وثبّت. 4–5 مجموعات × 30–45 ثانية مع راحة دقيقتين. يُستخدم عند ألم الوتر لتخفيف الألم قبل التمارين الأخرى.', NULL, 'مصدر خارجي موثوق', 'Br J Sports Med 2015 — Isometric exercise in patellar tendinopathy (Rio et al.)', 'https://pubmed.ncbi.nlm.nih.gov/25979840/', 'اعتلال وتر الرضفة / Patellar Tendinopathy | ألم الرضفة والفخذ (الركبة الأمامية) / Patellofemoral Pain', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Isometric Knee Extension / انقباض ثابت لمد الركبة', NULL, 'تخفيف الألم وتحميل آمن لوتر الرضفة بالانقباض الثابت', 'مبكرة', 'منخفض–متوسط', 'يُستخدم بعد تقييم فردي. يكون الألم أثناء التمرين خفيفاً ومقبولاً (حتى 3 من 10) ويهدأ خلال 24 ساعة، وإذا زاد الألم أو ظهر تورم أو إحساس بقفل أو خذلان في الركبة يتوقف التمرين وتُراجَع أخصائي.', 'Rio et al. 2015 — Br J Sports Med (Isometric exercise and analgesia in patellar tendinopathy) | Willy et al. 2019 — JOSPT (Patellofemoral Pain CPG) | Lack et al. 2015 — Br J Sports Med (Proximal muscle rehabilitation for PFP, meta-analysis)', 'https://pubmed.ncbi.nlm.nih.gov/25979840/ | https://doi.org/10.2519/jospt.2019.0302 | https://bjsm.bmj.com/content/49/21/1365', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('985adbc4-c8a8-4dba-9b13-2faee40aafc6', 'Drop Lunges', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/WH8lteLrMIs?si=61QSVA7iw_Z6Zr3p', 'تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.

ملاحظات مهمة:
• خطوة طويلة بما يكفي ليبقى الساق الأمامي بزاوية نحو 90° والركبة فوق القدم.
• جذع مستقيم وشدّ البطن، وادفع بكعب الرجل الأمامية.
• تحكم في التوازن قبل زيادة الوزن.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c109058f-a6b5-4d62-8617-4e97bd937fdc', 'Isometric Leg Extension Hold (Machine)', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'جهاز', 'متوسط', 'نادي', NULL, 'اجلس على جهاز فرد الركبة وثبّت الزاوية عند نحو 60° من ثني الركبة. ادفع بجهد متوسط–عالٍ (نحو 70% من أقصى قوة) وثبّت 45 ثانية، 5 مجموعات مع راحة دقيقتين. بروتوكول الدراسة المرجعية.', NULL, 'مصدر خارجي موثوق', 'Br J Sports Med 2015 — Isometric exercise in patellar tendinopathy (Rio et al.)', 'https://pubmed.ncbi.nlm.nih.gov/25979840/', 'اعتلال وتر الرضفة / Patellar Tendinopathy', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Isometric / ثابت', 'Isometric Knee Extension / انقباض ثابت لمد الركبة', NULL, 'تخفيف ألم الوتر وتقليل التثبيط العضلي', 'مبكرة', 'متوسط', 'يُستخدم بعد تقييم فردي. يكون الألم أثناء التمرين خفيفاً ومقبولاً (حتى 3 من 10) ويهدأ خلال 24 ساعة، وإذا زاد الألم أو ظهر تورم أو إحساس بقفل أو خذلان في الركبة يتوقف التمرين وتُراجَع أخصائي.', 'Rio et al. 2015 — Br J Sports Med (Isometric exercise and analgesia in patellar tendinopathy)', 'https://pubmed.ncbi.nlm.nih.gov/25979840/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7056ed64-8395-453c-9503-2de7060b1dbb', 'Slow Leg Press (Heavy Slow Resistance)', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'متوسط', 'نادي', NULL, 'ضغط الأرجل بحركة بطيئة جداً: 3 ثوانٍ للدفع و3 ثوانٍ للنزول بدون توقف. تزيد الأوزان وتقل التكرارات تدريجياً (من 15 إلى 6) خلال 12 أسبوعاً، 3 أيام في الأسبوع بالتناوب مع تمرين سكوات وهاك سكوات.', NULL, 'مصدر خارجي موثوق', 'Scand J Med Sci Sports 2009 — HSR in patellar tendinopathy (Kongsgaard et al.)', 'https://pubmed.ncbi.nlm.nih.gov/19793213/', 'اعتلال وتر الرضفة / Patellar Tendinopathy', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Leg Press / ضغط الأرجل', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, 'تحميل تدريجي لوتر الرضفة بمقاومة عالية وبطيئة', 'متوسطة–متقدمة', 'مرتفع', 'يُستخدم بعد تقييم فردي. يكون الألم أثناء التمرين خفيفاً ومقبولاً (حتى 3 من 10) ويهدأ خلال 24 ساعة، وإذا زاد الألم أو ظهر تورم أو إحساس بقفل أو خذلان في الركبة يتوقف التمرين وتُراجَع أخصائي.', 'Kongsgaard et al. 2009 — Scand J Med Sci Sports (Heavy slow resistance vs eccentric decline squat vs corticosteroid in patellar tendinopathy)', 'https://pubmed.ncbi.nlm.nih.gov/19793213/', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('18b783de-6ccc-4f71-9a85-9223f79b3989', 'Modified Curl-Up (McGill)', 'Core / البطن والكور', '{}', 'Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'استلقِ على ظهرك، ركبة مثنية والأخرى مفرودة، ويداك تحت أسفل الظهر للحفاظ على انحنائه الطبيعي. ارفع الرأس والكتفين قليلاً فقط (دون ثني أسفل الظهر) وثبّت 7–10 ثوانٍ، ثم ارجع. 3 جولات (تنازلية 6-4-2) حسب برنامج ماكجيل.', NULL, 'مصدر خارجي موثوق', 'McGill 2010 — Core training (Strength Cond J)', NULL, 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Anti-Extension / مقاومة البسط', 'Isometric Anti-Extension / تثبيت الجذع ضد البسط', NULL, 'تقوية عضلات البطن بأقل حمل على العمود الفقري', 'مبكرة', 'منخفض', 'لا يُجرى مع ألم حاد أو ألم ينتشر للساق أو تنميل. يتوقف التمرين إذا زاد الألم، وتُراجَع أخصائي.', 'NICE NG59 (2020) — Low back pain and sciatica in over 16s | Hayden et al. 2021 — Cochrane (Exercise therapy for chronic low back pain) | McGill 2010 — Strength Cond J (Core training)', 'https://www.nice.org.uk/guidance/ng59 | https://doi.org/10.1002/14651858.CD009790.pub2', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6cbfa7c0-e737-4549-b3db-0d7d5783cc47', 'Supine Pelvic Tilt', 'Core / البطن والكور', '{"Glutes / المؤخرة"}', 'Core Activation & Breathing / تفعيل الجذع والتنفس', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'استلقِ على ظهرك وركبتاك مثنيتان. اضغط أسفل الظهر برفق نحو الأرض بشد البطن والألوية قليلاً، ثبّت 5 ثوانٍ مع تنفس طبيعي ثم استرخِ. 2 مجموعات × 10 تكرارات.', NULL, 'مصدر خارجي موثوق', 'NICE NG59 — Low back pain and sciatica in over 16s', 'https://www.nice.org.uk/guidance/ng59', 'آلام أسفل الظهر غير النوعية / Non-specific Low Back Pain', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Pelvic Control / التحكم بالحوض', 'Posterior Pelvic Tilt / إمالة الحوض للخلف', NULL, 'تفعيل الجذع وتحسين وعي الحوض في المراحل الأولى', 'مبكرة', 'منخفض', 'تمرين تمهيدي خفيف. لا تدفع بقوة، ويتوقف عند زيادة الألم.', 'NICE NG59 (2020) | Hayden et al. 2021 — Cochrane (دليل عام على التمارين، ولا توجد تجربة تعزل هذا التمرين بعينه)', 'https://www.nice.org.uk/guidance/ng59 | https://doi.org/10.1002/14651858.CD009790.pub2', 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('85f63104-3aa8-40ef-ab97-4ce041daad10', 'Tyler Twist (FlexBar)', 'Forearms / الساعد', '{}', 'Wrist Extension / مد الرسغ', 'قوة', 'أخرى', 'متوسط', 'منزل', NULL, 'أمسك قضيب FlexBar عمودياً: اليد المصابة من الأعلى والسليمة من الأسفل، والرسغ المصاب مفرود للخلف. لفّ القضيب باليد السليمة (التواء)، ثم مدّ الذراعين أمامك وأرخِ الالتواء ببطء بالرسغ المصاب حتى يستقيم (حركة لامركزية بطيئة). 3 مجموعات × 15 تكرار يومياً، وتزيد مقاومة القضيب تدريجياً. هذا الوصف مبسّط، فيُراجَع مع أخصائي عند أول استخدام.', NULL, 'مصدر خارجي موثوق', 'J Shoulder Elbow Surg 2010 — Tyler Twist (Tyler et al.)', NULL, 'مرفق التنس / Lateral Elbow Tendinopathy', 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Eccentric / لامركزي', 'Wrist Extension / مد الرسغ', NULL, 'تقوية لامركزية لباسطات الرسغ لألم مرفق التنس', 'مبكرة–متوسطة', 'منخفض–متوسط', 'يكون الألم أثناء التمرين خفيفاً ومقبولاً. إذا زاد الألم أو ظهر تنميل أو ضعف في اليد يتوقف التمرين وتُراجَع أخصائي.', 'Tyler et al. 2010 — J Shoulder Elbow Surg 19(6):917–922 (Tyler Twist with FlexBar)', NULL, 'needs_review') ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c2c3767e-f41a-45c6-b7a1-25e55dcfce02', 'Box Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtube.com/shorts/9uhEh9gpwUU?si=xaTY7AJiCeQfa3by', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل.

ملاحظات مهمة:
• ركبتان بنفس اتجاه أصابع القدم وثبات الكعبين على الأرض.
• صدر مرفوع وجذع محايد، وانزل بعمق يسمح به مدى حركتك دون ثني أسفل الظهر.
• ادفع الأرض بكامل القدم وليس بالأصابع فقط.
• ثبّت قبضة البار وارفع بتحكم، واستعن بمساعد أو حوامل أمان عند الأوزان الثقيلة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'تعليمات بديلة في المصدر (صف 13): ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل، انزل واثبت على البوكس ثانية وارفع.', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('18368443-c491-4eb3-9c76-c405f0979823', 'Back Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/bEv6CCg2BC8', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل.

ملاحظات مهمة:
• ركبتان بنفس اتجاه أصابع القدم وثبات الكعبين على الأرض.
• صدر مرفوع وجذع محايد، وانزل بعمق يسمح به مدى حركتك دون ثني أسفل الظهر.
• ادفع الأرض بكامل القدم وليس بالأصابع فقط.
• ثبّت قبضة البار وارفع بتحكم، واستعن بمساعد أو حوامل أمان عند الأوزان الثقيلة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8ddd7267-00b4-4796-95b1-1e6aca9437c1', 'Hack Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/0tn5K9NlCfo', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.

ملاحظات مهمة:
• ثبّت ظهرك على المسند وضع القدمين بوضع مريح للركبة.
• انزل بتحكم وادفع بالكعبين وكامل القدم دون تقوّس الظهر.
• اضبط المقعد والمساند لتتماشى مفاصلك مع محور الجهاز قبل البدء، وسجّل الإعدادات لتكررها.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Machine Squat / سكوات بالجهاز', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4966b0dc-b20e-4cc9-8452-83fb4f98b2bd', 'Mid Leg Press', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/s9-zeWzPUmA', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.

ملاحظات مهمة:
• لا ترفع الأرداف عن المقعد ولا تفرد الركبتين بقوة في الأعلى.
• ضع القدمين بحيث تبقى الركبتان باتجاه أصابع القدم، وانزل لمدى يسمح بأسفل ظهر ملتصق بالمسند.
• تحكم في النزول 2–3 ثوانٍ.
• اضبط المقعد والمساند لتتماشى مفاصلك مع محور الجهاز قبل البدء، وسجّل الإعدادات لتكررها.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Leg Press / ضغط الأرجل', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1aea3c49-3990-405d-aa97-68dbe2dd7de2', 'Quads Leg Press', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/A218isnErfM', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي، ثبت القدمين أسفل اللوح لاستهداف أكبر للكوادز.

ملاحظات مهمة:
• لا ترفع الأرداف عن المقعد ولا تفرد الركبتين بقوة في الأعلى.
• ضع القدمين بحيث تبقى الركبتان باتجاه أصابع القدم، وانزل لمدى يسمح بأسفل ظهر ملتصق بالمسند.
• تحكم في النزول 2–3 ثوانٍ.
• اضبط المقعد والمساند لتتماشى مفاصلك مع محور الجهاز قبل البدء، وسجّل الإعدادات لتكررها.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Leg Press / ضغط الأرجل', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ef3eb703-8cb1-4597-95e9-3ac4a93049b7', 'Deficit Goblet Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/9719SO5zvpU?si=whohbunAsXkH3j6f', 'وقف باتساع اكتافك تقريبًا، ادفع ركبك للامام وانزل، انزل لأقصى حد تقدر عليه بدون ما يتقوس ظهرك السفلي.

ملاحظات مهمة:
• ركبتان بنفس اتجاه أصابع القدم وثبات الكعبين على الأرض.
• صدر مرفوع وجذع محايد، وانزل بعمق يسمح به مدى حركتك دون ثني أسفل الظهر.
• ادفع الأرض بكامل القدم وليس بالأصابع فقط.
• اختر وزناً تتحكم به في كل تكرار دون تأرجح، وأنزل الدمبلين بنفس السرعة التي رفعتهما.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c5043fa2-8f4d-4e47-86be-18b641ad2c47', 'Front Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'بار', 'متوسط', 'نادي', NULL, 'ثبت البار على الأكتاف، ادفع ركبك للامام وانزل.

ملاحظات مهمة:
• ركبتان بنفس اتجاه أصابع القدم وثبات الكعبين على الأرض.
• صدر مرفوع وجذع محايد، وانزل بعمق يسمح به مدى حركتك دون ثني أسفل الظهر.
• ادفع الأرض بكامل القدم وليس بالأصابع فقط.
• ثبّت قبضة البار وارفع بتحكم، واستعن بمساعد أو حوامل أمان عند الأوزان الثقيلة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('55728cd0-876b-4e00-972c-c727ba807a76', 'V Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://www.youtube.com/watch?v=u_GSjH58s0g', 'تمسك بالمقابض لزيادة الثبات، ثبت موخرتك وظهرك السفلي كويس، انزل قد ما تقدر لكن لا تبالغ بالنزول لدرجة يتقوس ظهرك السفلي.

ملاحظات مهمة:
• ثبّت ظهرك على المسند وضع القدمين بوضع مريح للركبة.
• انزل بتحكم وادفع بالكعبين وكامل القدم دون تقوّس الظهر.
• اضبط المقعد والمساند لتتماشى مفاصلك مع محور الجهاز قبل البدء، وسجّل الإعدادات لتكررها.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Machine Squat / سكوات بالجهاز', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('88c5c913-611d-47b7-95b6-45898d63fdcf', 'Resistance Band Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/6rE0IYlMPZA?si=goqtRTlR_W4HSGBN', 'ثبت الباند علي جوانب اكتافك، ادفع ركبك للأمام وإنزل.

ملاحظات مهمة:
• ركبتان بنفس اتجاه أصابع القدم وثبات الكعبين على الأرض.
• صدر مرفوع وجذع محايد، وانزل بعمق يسمح به مدى حركتك دون ثني أسفل الظهر.
• ادفع الأرض بكامل القدم وليس بالأصابع فقط.
• تأكد من سلامة الشريط وثبّته جيداً، واحرص على شد ثابت طوال الحركة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('452e1e38-b5a2-4e4e-85c4-eff748bb0f9e', 'Squat Smith Machine', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/oBwhrRcNWyM', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع ركبك للامام وانزل.

ملاحظات مهمة:
• ثبّت ظهرك على المسند وضع القدمين بوضع مريح للركبة.
• انزل بتحكم وادفع بالكعبين وكامل القدم دون تقوّس الظهر.
• ضع القدمين بزاوية مناسبة وأمامية قليلاً، واضبط حوامل الأمان قبل البدء.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Machine Squat / سكوات بالجهاز', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('994033f8-952d-4447-bc43-31ec80b3acb5', 'Beginner Lunges', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/QOVaHwm-Q6U', 'تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.

ملاحظات مهمة:
• خطوة طويلة بما يكفي ليبقى الساق الأمامي بزاوية نحو 90° والركبة فوق القدم.
• جذع مستقيم وشدّ البطن، وادفع بكعب الرجل الأمامية.
• تحكم في التوازن قبل زيادة الوزن.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ea4c7b4f-e713-4971-ad4d-534299a59750', 'Standing Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/rDRwAURNbzU', 'الحركة كلها بثني ومد الركبة

ملاحظات مهمة:
• اضبط الجهاز ليتماشى محور الركبة مع محور الجهاز.
• اسحب بتحكم وبدون رفع الورك عن المقعد، وانزل ببطء.
• انقباض لثانية في أقصى الثني.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e3bd55bc-8db5-4dfb-894c-db52ce2e5475', 'Supported BSS', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/poBie3TTeGE?si=QSiMUYtcHhrmg8mx', 'وقف عند البنش او الستيب، ارفع رجلك وثبت اصابع قدمك على البنش، خذ خطوة وحدة للأمام برجلك الثانية ثم ابدأ التمرين، تمسك بالبنش أو الجدار بيدك الثانية لزيادة الثبات.

ملاحظات مهمة:
• وضعية ثابتة بوقفة طويلة، وانزل عمودياً لا للأمام.
• ادفع بكعب الرجل الأمامية وحافظ على الحوض مستوياً.
• ثبّت قبل التكرار الأول لضمان التوازن.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Split Squat / سبليت سكوات', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d6cfa5b9-b20f-4f3e-867c-be5d3808741b', 'Supported Reverse Lunge', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/WH8lteLrMIs?si=M9s9a7qOVvvyDm82', 'ملاحظات مهمة:
• خطوة طويلة بما يكفي ليبقى الساق الأمامي بزاوية نحو 90° والركبة فوق القدم.
• جذع مستقيم وشدّ البطن، وادفع بكعب الرجل الأمامية.
• تحكم في التوازن قبل زيادة الوزن.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4e95c4cc-9f5b-4784-ab19-d70137cc8201', 'Smith Machine Reverse Lunge', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/zAVYcwnlxrQ?si=M5HL4sG-bsYBFyDQ', 'استخدم ارتفاع بسيط مثل الستيب ، ارفع نفسك بالضغط علي الرجل المرفوعة بتحكم بدون قفز.

ملاحظات مهمة:
• خطوة طويلة بما يكفي ليبقى الساق الأمامي بزاوية نحو 90° والركبة فوق القدم.
• جذع مستقيم وشدّ البطن، وادفع بكعب الرجل الأمامية.
• تحكم في التوازن قبل زيادة الوزن.
• ضع القدمين بزاوية مناسبة وأمامية قليلاً، واضبط حوامل الأمان قبل البدء.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Lunge / لانج', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5fb7469a-673b-42bc-baa9-7854adddbbd8', 'Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/gtZ4AwZVtMI', 'اجلس وثبت ظهرك السفلي كويس، تأكد ان مسمار الارتفاع يكون بمستوى ركبتك، امسك المقابض لزيادة الثبات، إرفع الوزن اثبت ثانية فوق ثم انزل نزول كامل بتحكم.

ملاحظات مهمة:
• اضبط مسند الظهر بحيث تكون الركبة مقابلة لمحور الجهاز.
• افرد الركبة بتحكم دون قذف الوزن، وانقباض لثانية في الأعلى.
• تجنّب الأوزان الثقيلة جداً إذا شعرت بألم في الركبة.
• اضبط المقعد والمساند لتتماشى مفاصلك مع محور الجهاز قبل البدء، وسجّل الإعدادات لتكررها.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fcb2a4a2-c1c0-4a34-ad07-f21bb8ecd459', 'Single Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/82IuSLk5zNc?si=FTMqZrmawQFRr8dN', 'اجلس وثبت ظهرك السفلي كويس، تأكد ان مسمار الارتفاع يكون بمستوى ركبتك، امسك المقابض لزيادة الثبات، إرفع الوزن اثبت ثانية فوق ثم انزل نزول كامل بتحكم.

ملاحظات مهمة:
• اضبط مسند الظهر بحيث تكون الركبة مقابلة لمحور الجهاز.
• افرد الركبة بتحكم دون قذف الوزن، وانقباض لثانية في الأعلى.
• تجنّب الأوزان الثقيلة جداً إذا شعرت بألم في الركبة.
• اضبط المقعد والمساند لتتماشى مفاصلك مع محور الجهاز قبل البدء، وسجّل الإعدادات لتكررها.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('915bc11b-5b58-4277-9324-0aa7d95b80bc', 'Band Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/hs7D3gDw3UM', 'اجلس وثبت ظهرك السفلي كويس وامسك الكرسي للثبات، اثبت ثانية فوق ثم انزل نزول كامل بتحكم.

ملاحظات مهمة:
• اضبط مسند الظهر بحيث تكون الركبة مقابلة لمحور الجهاز.
• افرد الركبة بتحكم دون قذف الوزن، وانقباض لثانية في الأعلى.
• تجنّب الأوزان الثقيلة جداً إذا شعرت بألم في الركبة.
• تأكد من سلامة الشريط وثبّته جيداً، واحرص على شد ثابت طوال الحركة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9c6e3687-1d6f-49e8-90cb-f1ca5357a913', 'Sissy Squat', 'Quadriceps / الأمامية', '{"Adductors / الأفخاذ الداخلية"}', 'Knee Extension / مد الركبة', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://youtu.be/yONKTprKCDA', 'الورك ثابت طول الجولة والحركة كلها من مفصل الركبة، اذا توازنك يخرب عليك ادبل الوزن بيد واليد الثانية امسك فيها جدار او عصى

ملاحظات مهمة:
• حركة متقدمة: ابدأ بمدى قصير بمساندة ثم زد المدى.
• حافظ على خط مستقيم من الركبة إلى الكتف.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Sissy Squat / سيسي سكوات', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9ac21553-f8de-47be-9837-e8100129fbe2', 'Cable Leg Extension', 'Quadriceps / الأمامية', '{}', 'Knee Extension / مد الركبة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/ebjD98gZd8E', 'اجلس وثبت ظهرك السفلي كويس وامسك الكرسي للثبات، اثبت ثانية فوق ثم انزل نزول كامل بتحكم.

ملاحظات مهمة:
• اضبط مسند الظهر بحيث تكون الركبة مقابلة لمحور الجهاز.
• افرد الركبة بتحكم دون قذف الوزن، وانقباض لثانية في الأعلى.
• تجنّب الأوزان الثقيلة جداً إذا شعرت بألم في الركبة.
• اضبط الارتفاع بما يناسب الحركة، وحافظ على شدّ الكيبل طوال التمرين دون ترك الوزن يرتطم.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('eb9d22b5-deb2-4407-ba9c-b13f2dc8058b', 'Standing Leg Extension', 'Quadriceps / الأمامية', '{"Core / البطن والكور"}', 'Knee Extension / مد الركبة', 'قوة', NULL, 'مبتدئ', NULL, NULL, 'ملاحظات مهمة:
• اضبط مسند الظهر بحيث تكون الركبة مقابلة لمحور الجهاز.
• افرد الركبة بتحكم دون قذف الوزن، وانقباض لثانية في الأعلى.
• تجنّب الأوزان الثقيلة جداً إذا شعرت بألم في الركبة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/133/standing-leg-extension/', NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Leg Extension / مد الركبة', 'Knee Extension / مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fc616803-46dd-42e0-88d1-0309a93b5ba5', 'Bodyweight Squat', 'Quadriceps / الأمامية', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Lower back / أسفل الظهر"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'ملاحظات مهمة:
• ركبتان بنفس اتجاه أصابع القدم وثبات الكعبين على الأرض.
• صدر مرفوع وجذع محايد، وانزل بعمق يسمح به مدى حركتك دون ثني أسفل الظهر.
• ادفع الأرض بكامل القدم وليس بالأصابع فقط.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/135/bodyweight-squat/', NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Free / Bodyweight Squat / سكوات حر أو بوزن الجسم', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7043733b-9a3d-4587-a346-9db4967f4a21', 'Cable Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/mBJXWg8ZOy0', 'اجلس على الكرسي وثبت ظهرك السفلي على المقعد تمامًا، ممكن تقدّم ظهرك العلوي وتمسك المقابض لزيادة الثبات، انزل لأقصى حد تقدر عليه وارفع لحد ما تستقيم ركبتك.

ملاحظات مهمة:
• اضبط الجهاز ليتماشى محور الركبة مع محور الجهاز.
• اسحب بتحكم وبدون رفع الورك عن المقعد، وانزل ببطء.
• انقباض لثانية في أقصى الثني.
• اضبط الارتفاع بما يناسب الحركة، وحافظ على شدّ الكيبل طوال التمرين دون ترك الوزن يرتطم.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('71cde207-be4a-4b5a-a158-2154bee69fc0', 'DB Glutes Step Ups', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/GCnJiYJfboA?feature=share', 'استخدم ارتفاع يكون بحدود ارتفاع ركبتك أو أقل، ارفع نفسك بالضغط علي الرجل المرفوعة بتحكم بدون قفز.

ملاحظات مهمة:
• اصعد بقوة الرجل التي على الدرجة لا بدفع الرجل الخلفية.
• اختر ارتفاعاً بحيث تكون الركبة نحو 90° أو أقل، وانزل بتحكم.
• جذع مرفوع وحوض مستوٍ.
• اختر وزناً تتحكم به في كل تكرار دون تأرجح، وأنزل الدمبلين بنفس السرعة التي رفعتهما.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8e9853bf-80fb-4735-af70-84f5d35f521a', 'Supported Glutes Step Ups', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/ZKzoOkQALaY?si=-56txwBlxSSCQYJd', 'استخدم ارتفاع يكون بحدود ارتفاع ركبتك أو أقل، ارفع نفسك بالضغط علي الرجل المرفوعة بتحكم بدون قفز.

ملاحظات مهمة:
• اصعد بقوة الرجل التي على الدرجة لا بدفع الرجل الخلفية.
• اختر ارتفاعاً بحيث تكون الركبة نحو 90° أو أقل، وانزل بتحكم.
• جذع مرفوع وحوض مستوٍ.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cd97d05a-2090-455a-896b-5910d0d397ad', 'Cable Glutes Step Ups', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', NULL, 'ملاحظات مهمة:
• اصعد بقوة الرجل التي على الدرجة لا بدفع الرجل الخلفية.
• اختر ارتفاعاً بحيث تكون الركبة نحو 90° أو أقل، وانزل بتحكم.
• جذع مرفوع وحوض مستوٍ.
• اضبط الارتفاع بما يناسب الحركة، وحافظ على شدّ الكيبل طوال التمرين دون ترك الوزن يرتطم.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('78757c23-6489-43fa-84a0-42ee53349dcd', 'Glute Pushdown', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/8h2kZ64Sp5k?si=NLPf4tywxhDGY9em', 'تمسك بمقابض الجهاز، (كل ما زاد ارتفاع البنش زادت الصعوبة) + الطلوع والنزول يكون بواسطة القدم المرفوعة على البنش مو بالقدم اللي تحت، ارفع بتحكم الى أقصى ارتفاع تقدرعليه بدون ما يتقوس ظهرك السفلي، انزل لحد ما تقفل ركبتك تماما

ملاحظات مهمة:
• اصعد بقوة الرجل التي على الدرجة لا بدفع الرجل الخلفية.
• اختر ارتفاعاً بحيث تكون الركبة نحو 90° أو أقل، وانزل بتحكم.
• جذع مرفوع وحوض مستوٍ.
• اضبط المقعد والمساند لتتماشى مفاصلك مع محور الجهاز قبل البدء، وسجّل الإعدادات لتكررها.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Step-up / صعود', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7cc18d79-59d0-47d7-a044-5a5ca27c539a', 'Glute Max Kickbacks', 'Glutes / المؤخرة', '{}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/t5mwSx4uNMc?feature=share', 'ثبت الحبل على الكاحل، ارجع خطوة للخلف وانحني للامام قليلاً وتمسك بالكيبل لزيادة الثبات، اسحب للخلف مع انثناء بسيط بالركب.

ملاحظات مهمة:
• حرّك الرجل من الورك دون تقوّس أسفل الظهر.
• انقباض الألوية في نهاية الحركة، ونزول بطيء.
• اضبط الارتفاع بما يناسب الحركة، وحافظ على شدّ الكيبل طوال التمرين دون ترك الوزن يرتطم.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Kickback / ركلة خلفية', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a25bdcf5-1319-4adc-b51a-8dcfe809206e', 'Smith Machine Kickback', 'Glutes / المؤخرة', '{}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/GR4ny80bmhM?si=WeZcWM1hyfoLElM2', 'ملاحظات مهمة:
• حرّك الرجل من الورك دون تقوّس أسفل الظهر.
• انقباض الألوية في نهاية الحركة، ونزول بطيء.
• ضع القدمين بزاوية مناسبة وأمامية قليلاً، واضبط حوامل الأمان قبل البدء.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Kickback / ركلة خلفية', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('24003d2e-b3c7-4d9f-9594-39900e25ac82', 'Glute Medius Kickbacks', 'Abductors / مبعدات الفخذ', '{"Glutes / المؤخرة"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/kccsnZNbMFA?si=6c-VoB8Zsz8NxoyM', 'ثبت الحبل على الكاحل، ارجع خطوة للخلف وانحني للامام قليلاً وتمسك بالكيبل لزيادة الثبات، اسحب للخلف وللخارج مع انثناء بسيط بالركب.

ملاحظات مهمة:
• ارفع الرجل للخلف وللخارج دون دوران الحوض.
• وزن خفيف وانقباض واضح للألوية.
• اضبط الارتفاع بما يناسب الحركة، وحافظ على شدّ الكيبل طوال التمرين دون ترك الوزن يرتطم.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Abduction Kickback / ركلة خلفية مع تبعيد', 'Hip Abduction + Hip Extension / تبعيد الورك + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a9809a70-8c1d-4c98-9f1d-221bce2408e2', 'Hip Thrusts Machine', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/0xfdeCBwoYw?si=HgJcNeB0a24gODkK', 'ممكن تسويه بالسميث مشين او البار الحر ، اختر بوكس او بنش يكون بمستوى اكتافك الخلفية وانت جالس، لما ترفع البار فوق المفروض ركبك تكون بنفس مستوى القدم.

ملاحظات مهمة:
• ذقن للأسفل قليلاً وضلوع للأسفل، ولا تبالغ في تقوّس أسفل الظهر في الأعلى.
• ادفع بالكعبين، وانقباض الألوية في الأعلى لثانية.
• ركبتان بزاوية نحو 90° في أعلى الحركة.
• اضبط المقعد والمساند لتتماشى مفاصلك مع محور الجهاز قبل البدء، وسجّل الإعدادات لتكررها.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('39d8345f-295b-4501-9571-74028c76e339', 'Hip Thrusts', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/O0EoaP7gR1A?si=cGPZ8iIwM2mQjwSb', 'ملاحظات مهمة:
• ذقن للأسفل قليلاً وضلوع للأسفل، ولا تبالغ في تقوّس أسفل الظهر في الأعلى.
• ادفع بالكعبين، وانقباض الألوية في الأعلى لثانية.
• ركبتان بزاوية نحو 90° في أعلى الحركة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0a1f1673-1717-457f-bf8c-92567b5c2821', 'Glute Raise', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/X_kL_x4m77c', 'ثبت رجولك تحت، الاسفنجة تكون تحت الورك أعلى الفخذ مو على الورك مباشرة، امسك وزن بيدينك بذراع مستقيمة، ارفع وكأنك تبي تدخل القلوتس جوا الاسفنجة، بمجرد ما تنقبض مؤخرتك وقف لا ترفع أكثر.

ملاحظات مهمة:
• الحركة من الورك لا من أسفل الظهر، وتوقف حين يستقيم الجسم دون تقوّس.
• اضبط المسند بحيث يكون الورك حراً للانثناء.
• اضبط المقعد والمساند لتتماشى مفاصلك مع محور الجهاز قبل البدء، وسجّل الإعدادات لتكررها.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', '45° Hip Extension / بسط الورك على جهاز الظهر', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7ee4f100-8845-463c-a7ed-438b0b95fbfb', 'Single Hip Thrusts', 'Glutes / المؤخرة', '{"Hamstrings / الخلفية"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/ymg2AMDAwrY?si=fY8kBPTDYWRMHuAs', 'اختر بوكس او بنش يكون بمستوى اكتافك الخلفية وانت جالس، لما ترفع فوق المفروض ركبك تكون بنفس مستوى القدم، التمرين صعب طبيعي تواجه صعوبة بالبداية لذلك لا تستعجل باضافة الاوزان

ملاحظات مهمة:
• ذقن للأسفل قليلاً وضلوع للأسفل، ولا تبالغ في تقوّس أسفل الظهر في الأعلى.
• ادفع بالكعبين، وانقباض الألوية في الأعلى لثانية.
• ركبتان بزاوية نحو 90° في أعلى الحركة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2e787fdb-20cc-404d-b02a-409521caf982', 'Glute Press', 'Glutes / المؤخرة', '{}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', NULL, 'ملاحظات مهمة:
• حرّك الرجل من الورك دون تقوّس أسفل الظهر.
• انقباض الألوية في نهاية الحركة، ونزول بطيء.
• اضبط المقعد والمساند لتتماشى مفاصلك مع محور الجهاز قبل البدء، وسجّل الإعدادات لتكررها.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/293/glute-press/', NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Kickback / ركلة خلفية', 'Hip Extension + Knee Extension / بسط الورك + مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9e23165c-918b-4b1a-839b-b90eedfdcc16', 'Bulgarian Split Squat', 'Glutes / المؤخرة', '{"Quadriceps / الأمامية","Adductors / الأفخاذ الداخلية"}', 'Lunge / Single-leg / لانج وحركات الرجل الواحدة', 'قوة', NULL, 'متوسط', NULL, NULL, 'ملاحظات مهمة:
• وضعية ثابتة بوقفة طويلة، وانزل عمودياً لا للأمام.
• ادفع بكعب الرجل الأمامية وحافظ على الحوض مستوياً.
• ثبّت قبل التكرار الأول لضمان التوازن.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/366/bulgarian-split-squat/', NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Split Squat / سبليت سكوات', 'Knee Extension + Hip Extension / مد الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5b2e5875-ae26-4762-a9b9-f4cd12438795', 'Sumo Deadlift', 'Hamstrings / الخلفية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://www.youtube.com/watch?v=cDlOSfu-zHY', 'وقف بفتحة أرجل واسعة بحيث الركب تكون خط مستقيم مع كعب القدم و اصابع الرجل باتجاه الخارج، البار بمنتصف القدم، شد ظهرك العلوي وادفع الارض برجولك واسحب البار للأعلى، وقف لما تنقبض مؤخرتك ولا تبالغ بتقفيل حوضك.

ملاحظات مهمة:
• ثبّت الظهر محايداً قبل الرفع وشدّ البطن (Brace) ثم ادفع الأرض بالقدمين.
• ابقِ البار قريباً من الجسم طوال الحركة.
• لا تقوّس أسفل الظهر عند أي مرحلة، ولا تفرد الركبتين قبل الورك.
• ثبّت قبضة البار وارفع بتحكم، واستعن بمساعد أو حوامل أمان عند الأوزان الثقيلة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Deadlift / ديدلفت', 'Hip Extension + Knee Extension / بسط الورك + مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('aac6c048-f99b-41b5-8376-84dabffd5872', 'Conventional Deadlift', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/GxsLrTzyGUU', 'وقف باتساع اكتافك أو أوسع شوي، البار بمنتصف القدم، شد ظهرك العلوي وادفع الارض برجولك واسحب البار للأعلى، وقف لما تنقبض مؤخرتك ولا تبالغ بتقفيل حوضك.

ملاحظات مهمة:
• ثبّت الظهر محايداً قبل الرفع وشدّ البطن (Brace) ثم ادفع الأرض بالقدمين.
• ابقِ البار قريباً من الجسم طوال الحركة.
• لا تقوّس أسفل الظهر عند أي مرحلة، ولا تفرد الركبتين قبل الورك.
• ثبّت قبضة البار وارفع بتحكم، واستعن بمساعد أو حوامل أمان عند الأوزان الثقيلة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Deadlift / ديدلفت', 'Hip Extension + Knee Extension / بسط الورك + مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ce0546e6-f7e8-4bcc-b222-e970df2f421d', 'Supine Cable Hamstring Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/sDCc1F5J8XA?si=Fi3D39aJogrB5ihd', 'الركبة ثبت مكانها، اسحب الحبل لاقصى حد تقدر عليه واترك رجلك تستقيم تمامًا في الانبساط.

ملاحظات مهمة:
• اضبط الجهاز ليتماشى محور الركبة مع محور الجهاز.
• اسحب بتحكم وبدون رفع الورك عن المقعد، وانزل ببطء.
• انقباض لثانية في أقصى الثني.
• اضبط الارتفاع بما يناسب الحركة، وحافظ على شدّ الكيبل طوال التمرين دون ترك الوزن يرتطم.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('09e16888-4cee-4bb3-a4df-457603bd3c69', 'BB RDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/mZxxJEncsyw', 'وقف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، انزل وادفع مؤخرتك لآخر شي تقدر عليه للخلف وكأنك بتلمس جدار خلفك مع انثناء بسيط بالركب

ملاحظات مهمة:
• ادفع الورك للخلف مع ثني بسيط ثابت في الركبتين، والبار قريب من الساقين.
• انزل حتى تمدد في الخلفية دون تقوّس الظهر، ثم ادفع الورك للأمام.
• الحركة من الورك وليست انحناء بالظهر.
• ثبّت قبضة البار وارفع بتحكم، واستعن بمساعد أو حوامل أمان عند الأوزان الثقيلة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c59a52ca-12ea-4dd6-96b0-4e2bcd59fbd0', 'Bent Knee V-Up', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/sbyFIM30_G8?si=dED0NQSRS44dz5G9', 'ملاحظات مهمة:
• ارفع الجذع والرجلين معاً بتحكم، وأبقِ الحركة بطيئة.
• إن شعرت بشد في أسفل الظهر خفّف المدى أو اثنِ الركبتين.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'V-up / في أب', 'Trunk Flexion + Hip Flexion / ثني الجذع + ثني الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fe42790d-78f9-4726-9e0e-a24a4d6a43bb', 'DB RDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/RApyTtH6qAo', 'وقف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، انزل وادفع مؤخرتك لآخر شي تقدر عليه للخلف وكأنك بتلمس جدار خلفك مع انثناء بسيط بالركب

ملاحظات مهمة:
• ادفع الورك للخلف مع ثني بسيط ثابت في الركبتين، والبار قريب من الساقين.
• انزل حتى تمدد في الخلفية دون تقوّس الظهر، ثم ادفع الورك للأمام.
• الحركة من الورك وليست انحناء بالظهر.
• اختر وزناً تتحكم به في كل تكرار دون تأرجح، وأنزل الدمبلين بنفس السرعة التي رفعتهما.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1a30fc87-1455-4036-aabb-5f58eed615df', 'SM SLDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/0cB0_SzqgBU', 'ملاحظات مهمة:
• ادفع الورك للخلف مع ثني بسيط ثابت في الركبتين، والبار قريب من الساقين.
• انزل حتى تمدد في الخلفية دون تقوّس الظهر، ثم ادفع الورك للأمام.
• الحركة من الورك وليست انحناء بالظهر.
• ضع القدمين بزاوية مناسبة وأمامية قليلاً، واضبط حوامل الأمان قبل البدء.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e3f33107-e350-46d8-89be-31db54be255c', 'SLDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/RApyTtH6qAo', 'قف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، ابدأ الحركة بدفع مؤخرتك للخلف والأعلى وانزل

ملاحظات مهمة:
• ادفع الورك للخلف مع ثني بسيط ثابت في الركبتين، والبار قريب من الساقين.
• انزل حتى تمدد في الخلفية دون تقوّس الظهر، ثم ادفع الورك للأمام.
• الحركة من الورك وليست انحناء بالظهر.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3bb93d6c-4bf3-4eeb-9313-d5c346456513', 'Single DB SLDL', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/U3prDlAbJDw?si=MRSBcSIcf9M-WQBH', 'قف باتساع اكتافك واحرص ان راسك ونظرك ثابتين تحت طول التمرين، ابدأ الحركة بدفع مؤخرتك للخلف والأعلى وانزل

ملاحظات مهمة:
• ادفع الورك للخلف مع ثني بسيط ثابت في الركبتين، والبار قريب من الساقين.
• انزل حتى تمدد في الخلفية دون تقوّس الظهر، ثم ادفع الورك للأمام.
• الحركة من الورك وليست انحناء بالظهر.
• اختر وزناً تتحكم به في كل تكرار دون تأرجح، وأنزل الدمبلين بنفس السرعة التي رفعتهما.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Romanian / Stiff-leg Deadlift / ديدلفت روماني أو بأرجل مستقيمة', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('eb3c1124-5096-4af5-bd43-cd1fbc5adf4b', 'Good Morning', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة","Lower back / أسفل الظهر"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/f23vXjoG2e8?si=9rkfUF_6XUEcQ3Xs', 'ثبت البار على الترابس او الاكتاف الخلفية وشد البار وكأنك بتكسره من النص، ادفع مؤخرتك لأقصى قدر تقدر عليه وكأنك بتلمس جدار خلفك.

ملاحظات مهمة:
• بار ثابت على أعلى الظهر، ودفع الورك للخلف مع ظهر محايد.
• ابدأ بوزن خفيف جداً لإتقان الحركة.
• ثبّت قبضة البار وارفع بتحكم، واستعن بمساعد أو حوامل أمان عند الأوزان الثقيلة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Good Morning / قود مورنينق', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('415044e2-e51a-4b30-b260-3453f8d7ce25', 'Cable Facing In Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/5z4y7QRTx1w', 'ملاحظات مهمة:
• أبقِ المرفقين ثابتين بجانب الجسم ولا تتأرجح بالجذع.
• اثنِ حتى انقباض كامل وانزل ببطء 2–3 ثوانٍ.
• رسغ محايد دون ثني.
• اضبط الارتفاع بما يناسب الحركة، وحافظ على شدّ الكيبل طوال التمرين دون ترك الوزن يرتطم.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3b783732-a934-4c79-9be2-1ca0e4a5438b', 'Seated Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/o_J6MWyt5jM', 'اجلس على الكرسي وثبت ظهرك السفلي على المقعد تمامًا، انزل لأقصى حد تقدر عليه وارفع لحد ما تستقيم ركبتك.

ملاحظات مهمة:
• اضبط الجهاز ليتماشى محور الركبة مع محور الجهاز.
• اسحب بتحكم وبدون رفع الورك عن المقعد، وانزل ببطء.
• انقباض لثانية في أقصى الثني.
• اضبط المقعد والمساند لتتماشى مفاصلك مع محور الجهاز قبل البدء، وسجّل الإعدادات لتكررها.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5200941a-3b4e-40bf-8df9-9e793f62fa6f', 'Band Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/I-HTMUrJnxs', 'ثبت الباند فوق الكعب، اجلس على طرف البنش وتمسك بيدينك لزيادة الثبات، اسحب الحبل لاقصى حد تقدر عليه واترك رجلك تستقيم تمامًا في الانبساط.

ملاحظات مهمة:
• اضبط الجهاز ليتماشى محور الركبة مع محور الجهاز.
• اسحب بتحكم وبدون رفع الورك عن المقعد، وانزل ببطء.
• انقباض لثانية في أقصى الثني.
• تأكد من سلامة الشريط وثبّته جيداً، واحرص على شد ثابت طوال الحركة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('08894260-98d8-40f4-8333-9685f10bc547', 'Lying Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/vl5nUdE9mWM', 'حوضك ثابت على البنش، ارفع الوزن بثني ومد الركبة بدون ما يرتفع حوضك عن الكرسي

ملاحظات مهمة:
• اضبط الجهاز ليتماشى محور الركبة مع محور الجهاز.
• اسحب بتحكم وبدون رفع الورك عن المقعد، وانزل ببطء.
• انقباض لثانية في أقصى الثني.
• اضبط المقعد والمساند لتتماشى مفاصلك مع محور الجهاز قبل البدء، وسجّل الإعدادات لتكررها.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6adb9f5d-49d1-4735-84e9-59946151e277', 'DB Lying Leg Curl', 'Hamstrings / الخلفية', '{"Calves / البطات"}', 'Knee Flexion / ثني الركبة', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/ZHlBSI6JPsA?si=SpBiHxluwrYE8CTP', 'ركبك ثابته على الارض، ارفع الوزن بثني ومد الركبة بدون ما يرتفع حوضك

ملاحظات مهمة:
• اضبط الجهاز ليتماشى محور الركبة مع محور الجهاز.
• اسحب بتحكم وبدون رفع الورك عن المقعد، وانزل ببطء.
• انقباض لثانية في أقصى الثني.
• اختر وزناً تتحكم به في كل تكرار دون تأرجح، وأنزل الدمبلين بنفس السرعة التي رفعتهما.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Leg Curl / ثني الركبة', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3ea5f668-0f0f-4342-854b-83012e1e4230', 'Nordic Hamstring Curl', 'Hamstrings / الخلفية', '{}', 'Knee Flexion / ثني الركبة', 'قوة', 'وزن الجسم', 'متقدم', 'بدون معدات', 'https://youtu.be/Lgibr8od0yA?si=nfRetEkDRk55Bu0a', 'ملاحظات مهمة:
• ثبّت الكعبين جيداً وانزل ببطء قدر الإمكان بجسم مستقيم من الركبة للرأس.
• استخدم اليدين لتخفيف الحمل في البداية، وتقدّم تدريجياً لتجنب شد الخلفية.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Nordic (Eccentric) / نوردك (لامركزي)', 'Knee Flexion / ثني الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('85a9f4ab-6fe4-449e-bf9d-c260db9455ba', 'Stability Ball Hamstring Curl', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة"}', 'Knee Flexion / ثني الركبة', 'قوة', 'كرة سويسرية', 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• ارفع الورك ثم اسحب الكعبين نحو الأرداف بتحكم.
• لا تقوّس أسفل الظهر، ونزول بطيء.
• ثبّت الكرة جيداً قبل البدء، وتحرك ببطء لتجنب الانزلاق.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/59/stability-ball-hamstring-curl/', NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Bridge Curl / ثني الركبة مع رفع الورك', 'Knee Flexion + Hip Extension / ثني الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3edaa29d-eedd-4d2b-a4e9-ffc98a062f06', 'Hip Hinge', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قوة', NULL, 'مبتدئ', NULL, NULL, 'ملاحظات مهمة:
• تعلّم الحركة بوزن خفيف: ورك للخلف وظهر محايد.
• العصا على الظهر تساعدك على مراقبة الاستقامة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/33/hip-hinge/', NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Hinge Drill / تمرين مفصلة الورك', 'Hip Extension with Knees Nearly Fixed / بسط الورك مع ركبة شبه ثابتة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('225cb8bd-3ce6-4dd9-9d9b-eff2d4565b9f', 'TRX Hamstrings Curl', 'Hamstrings / الخلفية', '{"Glutes / المؤخرة"}', 'Knee Flexion / ثني الركبة', 'قوة', 'TRX', 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• ارفع الورك ثم اسحب الكعبين نحو الأرداف بتحكم.
• لا تقوّس أسفل الظهر، ونزول بطيء.
• تأكد من تثبيت الأحزمة جيداً، وحافظ على جسم مستقيم وتحكم في زاوية الميل لضبط الصعوبة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/86/trx-reg-hamstrings-curl/', NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Bridge Curl / ثني الركبة مع رفع الورك', 'Knee Flexion + Hip Extension / ثني الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('82465684-1e29-4271-baf0-10a0f281aead', 'Flat DB Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/xphvjGDZeYE', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا

ملاحظات مهمة:
• ثبّت لوحي الكتف للخلف وللأسفل وأبقِ الصدر مرفوعاً طوال التمرين.
• انزل بتحكم حتى مستوى الصدر، والمرفقان بزاوية نحو 45–70° من الجسم لا مفتوحين تماماً.
• ادفع بخط ثابت دون رفع الكتفين نحو الأذن.
• اختر وزناً تتحكم به في كل تكرار دون تأرجح، وأنزل الدمبلين بنفس السرعة التي رفعتهما.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a777837f-eaa7-4f6e-ab0b-13789bc32dd2', 'DB Floor Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/UBmpZ7l5Nlk?si=kDcN-ueaTFxfKtbr', 'ملاحظات مهمة:
• ثبّت لوحي الكتف للخلف وللأسفل وأبقِ الصدر مرفوعاً طوال التمرين.
• انزل بتحكم حتى مستوى الصدر، والمرفقان بزاوية نحو 45–70° من الجسم لا مفتوحين تماماً.
• ادفع بخط ثابت دون رفع الكتفين نحو الأذن.
• اختر وزناً تتحكم به في كل تكرار دون تأرجح، وأنزل الدمبلين بنفس السرعة التي رفعتهما.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1b049f63-42f4-459d-a78c-4edc23de430d', 'Flat Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/vcBig73ojpE', 'استلق على بنش،القبضة بنفس مستوى الاكتاف أو أوسع قليلًا، قوّس ظهرك العلوي قليلاً، انزل لين تلمس صدرك واثبت ثانية ثم ارفع.

ملاحظات مهمة:
• ثبّت لوحي الكتف للخلف وللأسفل وأبقِ الصدر مرفوعاً طوال التمرين.
• انزل بتحكم حتى مستوى الصدر، والمرفقان بزاوية نحو 45–70° من الجسم لا مفتوحين تماماً.
• ادفع بخط ثابت دون رفع الكتفين نحو الأذن.
• ثبّت قبضة البار وارفع بتحكم، واستعن بمساعد أو حوامل أمان عند الأوزان الثقيلة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7a1abf40-c1d4-4b0d-ab71-cb364cec806e', 'Machine Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/pOCRC2kpxB8?si=02xGtrfPjiYpspMv', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا

ملاحظات مهمة:
• ثبّت لوحي الكتف للخلف وللأسفل وأبقِ الصدر مرفوعاً طوال التمرين.
• انزل بتحكم حتى مستوى الصدر، والمرفقان بزاوية نحو 45–70° من الجسم لا مفتوحين تماماً.
• ادفع بخط ثابت دون رفع الكتفين نحو الأذن.
• اضبط المقعد والمساند لتتماشى مفاصلك مع محور الجهاز قبل البدء، وسجّل الإعدادات لتكررها.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a9b85785-8c7f-4104-b5e5-15b0bb825abc', 'Incline Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/0G2_XV7slIg', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا

ملاحظات مهمة:
• اضبط الميل بزاوية معتدلة (نحو 30°) ليبقى التركيز على أعلى الصدر دون أن يطغى الكتف.
• ثبّت لوحي الكتف للخلف وانزل بتحكم.
• لا ترفع الأرداف عن المقعد.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Incline Press / ضغط مائل لأعلى', 'Shoulder Flexion + Horizontal Adduction / ثني الكتف + تقريب أفقي', 'Incline Press / ضغط مائل لأعلى', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('34922616-74c4-40be-882b-9a5ab9e03345', 'Feet Up Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/HrehfM1dmBE', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا

ملاحظات مهمة:
• ثبّت لوحي الكتف للخلف وللأسفل وأبقِ الصدر مرفوعاً طوال التمرين.
• انزل بتحكم حتى مستوى الصدر، والمرفقان بزاوية نحو 45–70° من الجسم لا مفتوحين تماماً.
• ادفع بخط ثابت دون رفع الكتفين نحو الأذن.
• ثبّت قبضة البار وارفع بتحكم، واستعن بمساعد أو حوامل أمان عند الأوزان الثقيلة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8ecf3b9b-82b4-4e26-ab7a-7d196aef3524', 'Torso Elevated Push Up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/noaPB7u4_CU', 'قوّس ظهرك العلوي قليلاً، الكوع قريب قليلا من الجسم، النزول الى تساوي اليد مع الصدر تقريبا

ملاحظات مهمة:
• ثبّت جسمك جيداً قبل البدء وانزل بتحكم إلى أسفل الصدر.
• حافظ على الرسغ مستقيماً فوق الساعد.
• استخدم مساعداً أو جهاز أمان عند الأوزان الثقيلة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'تصنيف فرعي: اليدان مرفوعتان؛ زاوية الضغط بالنسبة للجذع تشبه الضغط المائل لأسفل رغم تسميته الشائعة Incline Push-up — يحدده المدرب', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Decline Press / ضغط مائل لأسفل', 'Horizontal Adduction + Shoulder Extension / تقريب أفقي + مد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('186b94a2-c071-47fa-98a5-8ef3e479bfa1', 'Push Up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://youtu.be/WDIpL0pjun0?si=utydS_A8QfRIJtJm', 'ملاحظات مهمة:
• ثبّت لوحي الكتف للخلف وللأسفل وأبقِ الصدر مرفوعاً طوال التمرين.
• انزل بتحكم حتى مستوى الصدر، والمرفقان بزاوية نحو 45–70° من الجسم لا مفتوحين تماماً.
• ادفع بخط ثابت دون رفع الكتفين نحو الأذن.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0fbc9de1-9329-41fe-bae3-1355660ebbd8', 'Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://www.youtube.com/watch?v=JvOJdUtx6UQ', 'استلق على بنش،القبضة بنفس مستوى الاكتاف أو أوسع قليلًا، قوّس ظهرك العلوي قليلاً، انزل لين تلمس صدرك واثبت ثانية ثم ارفع.

ملاحظات مهمة:
• ثبّت لوحي الكتف للخلف وللأسفل وأبقِ الصدر مرفوعاً طوال التمرين.
• انزل بتحكم حتى مستوى الصدر، والمرفقان بزاوية نحو 45–70° من الجسم لا مفتوحين تماماً.
• ادفع بخط ثابت دون رفع الكتفين نحو الأذن.
• ثبّت قبضة البار وارفع بتحكم، واستعن بمساعد أو حوامل أمان عند الأوزان الثقيلة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6618a027-17e2-45d3-948e-9be7b71a955f', 'Paused Bench Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://www.youtube.com/shorts/Q3GmnmJISwE', 'استلق على بنش،القبضة بنفس مستوى الاكتاف أو أوسع قليلًا، قوّس ظهرك العلوي قليلاً، انزل لين تلمس صدرك واثبت 3 ثواني ثم ارفع.

ملاحظات مهمة:
• ثبّت لوحي الكتف للخلف وللأسفل وأبقِ الصدر مرفوعاً طوال التمرين.
• انزل بتحكم حتى مستوى الصدر، والمرفقان بزاوية نحو 45–70° من الجسم لا مفتوحين تماماً.
• ادفع بخط ثابت دون رفع الكتفين نحو الأذن.
• ثبّت قبضة البار وارفع بتحكم، واستعن بمساعد أو حوامل أمان عند الأوزان الثقيلة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('be114bb8-7dee-4500-87ca-2d5ff8ed1cd7', 'Biceps Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/09AYfVFf7pg?si=dcwLVAYqIbDLM6jd', 'ملاحظات مهمة:
• أبقِ المرفقين ثابتين بجانب الجسم ولا تتأرجح بالجذع.
• اثنِ حتى انقباض كامل وانزل ببطء 2–3 ثوانٍ.
• رسغ محايد دون ثني.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('98e7e303-392d-4d78-ad41-3a403a4e58b7', 'Smith Machine Incline Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'سميث', 'مبتدئ', 'نادي', 'https://youtu.be/EeLLZMdg6zI?si=UVsgFN7jhXMm0vW3', 'ملاحظات مهمة:
• اضبط الميل بزاوية معتدلة (نحو 30°) ليبقى التركيز على أعلى الصدر دون أن يطغى الكتف.
• ثبّت لوحي الكتف للخلف وانزل بتحكم.
• لا ترفع الأرداف عن المقعد.
• ضع القدمين بزاوية مناسبة وأمامية قليلاً، واضبط حوامل الأمان قبل البدء.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Incline Press / ضغط مائل لأعلى', 'Shoulder Flexion + Horizontal Adduction / ثني الكتف + تقريب أفقي', 'Incline Press / ضغط مائل لأعلى', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('70ed4590-e8e9-4959-8c6d-84cdea52b9d8', 'Cable Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/tAILewhtCb0', 'اجلس على بنش انكلاين، اضبط الكيبل بمستوى صدرك تقريبا، ادفع الوزن للأمام باتجاه الداخل، احرص ان كوعك ما يكون بنفس ارتفاع كتفك

ملاحظات مهمة:
• اضبط الميل بزاوية معتدلة (نحو 30°) ليبقى التركيز على أعلى الصدر دون أن يطغى الكتف.
• ثبّت لوحي الكتف للخلف وانزل بتحكم.
• لا ترفع الأرداف عن المقعد.
• اضبط الارتفاع بما يناسب الحركة، وحافظ على شدّ الكيبل طوال التمرين دون ترك الوزن يرتطم.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'تصنيف فرعي: التعليمات تذكر بنش انكلاين، وتصنيف المصدر iso_push_chest — يُحسم بين Incline Press وعزل الصدر', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Incline Press / ضغط مائل لأعلى', 'Shoulder Flexion + Horizontal Adduction / ثني الكتف + تقريب أفقي', 'Incline Press / ضغط مائل لأعلى', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1288e862-ff80-4872-82d9-5af42b2a5c65', 'Sternal Cable Press Around', 'Chest / الصدر', '{}', 'Horizontal Push / دفع أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/y8XQibXDnNo', 'اضبط الكيبل بمستوى صدرك تقريبا، حافظ على ذراعك قريبة من جسمك،ادفع الحبل للأمام باتجاه الداخل.

ملاحظات مهمة:
• لا تغلق المرفقين بقوة في أعلى الحركة، وركّز على تقريب الذراعين نحو منتصف الصدر.
• حافظ على كتفين ثابتين وللخلف.
• اضبط الارتفاع بما يناسب الحركة، وحافظ على شدّ الكيبل طوال التمرين دون ترك الوزن يرتطم.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'تصنيف فرعي: حركة مختلطة بين الضغط والـ Fly — يُحسم بين Flat Press وعزل الصدر', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Press-around / ضغط مع تقريب', 'Horizontal Adduction + Elbow Extension / تقريب أفقي + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d54646de-140a-446b-af7e-fd9c6e98c588', 'Machine Chest Fly', 'Chest / الصدر', '{}', 'Horizontal Adduction (Fly) / تقريب أفقي للكتف (فلاي)', 'قوة', 'جهاز', 'مبتدئ', 'نادي', NULL, 'ملاحظات مهمة:
• مرفقان بثني خفيف ثابت طوال الحركة، والحركة من مفصل الكتف.
• افتح حتى إحساس بتمدد مريح في الصدر ولا تتجاوزه.
• اعصر الصدر في الأعلى لثانية.
• اضبط المقعد والمساند لتتماشى مفاصلك مع محور الجهاز قبل البدء، وسجّل الإعدادات لتكررها.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Chest Isolation / عزل الصدر', 'Horizontal Adduction / تقريب أفقي للكتف', 'Chest Isolation / عزل الصدر', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('398f657b-9bec-4cac-b3ef-5005ce953f27', 'Bar Cable Chest Press', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/NhD3h6RG2TA?si=SoyNTIGB-nY2KiXl', 'ملاحظات مهمة:
• ثبّت لوحي الكتف للخلف وللأسفل وأبقِ الصدر مرفوعاً طوال التمرين.
• انزل بتحكم حتى مستوى الصدر، والمرفقان بزاوية نحو 45–70° من الجسم لا مفتوحين تماماً.
• ادفع بخط ثابت دون رفع الكتفين نحو الأذن.
• اضبط الارتفاع بما يناسب الحركة، وحافظ على شدّ الكيبل طوال التمرين دون ترك الوزن يرتطم.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f30becf2-8e03-4202-9c68-7f749de8d105', 'Cable Chest Fly', 'Chest / الصدر', '{"Shoulders / الأكتاف"}', 'Horizontal Adduction (Fly) / تقريب أفقي للكتف (فلاي)', 'قوة', 'كيبل', 'مبتدئ', 'نادي', NULL, 'ملاحظات مهمة:
• مرفقان بثني خفيف ثابت طوال الحركة، والحركة من مفصل الكتف.
• افتح حتى إحساس بتمدد مريح في الصدر ولا تتجاوزه.
• اعصر الصدر في الأعلى لثانية.
• اضبط الارتفاع بما يناسب الحركة، وحافظ على شدّ الكيبل طوال التمرين دون ترك الوزن يرتطم.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/160/standing-chest-fly/', NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Chest Isolation / عزل الصدر', 'Horizontal Adduction / تقريب أفقي للكتف', 'Chest Isolation / عزل الصدر', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('35ba2997-2e18-4fd1-8670-84f95736c745', 'Bent Knee Push-up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس"}', 'Horizontal Push / دفع أفقي', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'ملاحظات مهمة:
• ثبّت لوحي الكتف للخلف وللأسفل وأبقِ الصدر مرفوعاً طوال التمرين.
• انزل بتحكم حتى مستوى الصدر، والمرفقان بزاوية نحو 45–70° من الجسم لا مفتوحين تماماً.
• ادفع بخط ثابت دون رفع الكتفين نحو الأذن.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/13/bent-knee-push-up/', NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('609d7a93-71ef-4386-b63b-fba09cfd78d7', 'Stability Ball Push-Up', 'Chest / الصدر', '{"Shoulders / الأكتاف","Triceps / الترايسبس","Core / البطن والكور"}', 'Horizontal Push / دفع أفقي', 'قوة', 'كرة سويسرية', 'متوسط', 'منزل', NULL, 'ملاحظات مهمة:
• ثبّت لوحي الكتف للخلف وللأسفل وأبقِ الصدر مرفوعاً طوال التمرين.
• انزل بتحكم حتى مستوى الصدر، والمرفقان بزاوية نحو 45–70° من الجسم لا مفتوحين تماماً.
• ادفع بخط ثابت دون رفع الكتفين نحو الأذن.
• ثبّت الكرة جيداً قبل البدء، وتحرك ببطء لتجنب الانزلاق.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف فرعي: الزاوية تعتمد على موضع الكرة (تحت اليدين أو القدمين) — غير محدد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/63/stability-ball-push-up/', NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Flat / Normal Press / ضغط مستوٍ أو عادي', 'Horizontal Adduction / تقريب أفقي للكتف', 'Flat / Normal Press / ضغط مستوٍ أو عادي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9fe8a880-21bd-4847-a90d-2e636385119b', 'Cable Reardelt Rows', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/uIdXVGjcfFE', 'ثبت نفسك بالكرسي، فتحة واسعة، الكيبل بمستوى اسفل صدرك، واسحب لما تنقبض اكتافك الخلفية.

ملاحظات مهمة:
• المرفقان بزاوية أوسع، اسحب نحو أعلى الصدر مع ضم لوحي الكتف.
• حافظ على ظهر محايد دون تدوير الكتفين للأمام.
• اضبط الارتفاع بما يناسب الحركة، وحافظ على شدّ الكيبل طوال التمرين دون ترك الوزن يرتطم.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Wide-grip Row / تجديف بقبضة واسعة', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('70e38129-3814-4f52-9487-0e24ab782764', 'Single Lats Pulldown', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/Qed5O9toqT8', 'اجلس على بنش واسند صدرك عليه، ارجع للخلف قليلا بحيث ان الكيبل ما يكون فوق راسك مباشرة، اسحب الكوع باتجاه الورك.

ملاحظات مهمة:
• ابدأ بخفض لوحي الكتف ثم اسحب المرفقين للأسفل نحو الجنبين.
• أبقِ الصدر مرفوعاً ولا تتمايل للخلف أكثر من ميلان بسيط.
• ارجع للأعلى ببطء حتى تمدد كامل للاتس.
• اضبط الارتفاع بما يناسب الحركة، وحافظ على شدّ الكيبل طوال التمرين دون ترك الوزن يرتطم.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ec960d28-d044-406c-8c97-2cccff7902db', 'DB Chest Supported Reardelt Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/x0v6GWYzI18?si=-jDt3D-ARIHouHjp', 'ثبت صدرك على الكرسي، فتحة واسعة، واسحب لما تنقبض اكتافك الخلفية.

ملاحظات مهمة:
• المرفقان بزاوية أوسع، اسحب نحو أعلى الصدر مع ضم لوحي الكتف.
• حافظ على ظهر محايد دون تدوير الكتفين للأمام.
• اختر وزناً تتحكم به في كل تكرار دون تأرجح، وأنزل الدمبلين بنفس السرعة التي رفعتهما.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Wide-grip Row / تجديف بقبضة واسعة', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ed9f329f-417b-436c-af09-91e7b451ada3', 'Cable Rope Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/xNXUTJ6TBZA?si=-r-Ql97awoVZla_1', 'ملاحظات مهمة:
• قبضة محايدة (الإبهام للأعلى) والمرفقان ثابتان.
• لا تتأرجح، وانزل بتحكم.
• اضبط الارتفاع بما يناسب الحركة، وحافظ على شدّ الكيبل طوال التمرين دون ترك الوزن يرتطم.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Hammer / Neutral-grip Curl / ثني بقبضة محايدة', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8da26da0-6107-41a1-9c46-76c96c3300e7', 'Bent-over Barbell Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'بار', 'متوسط', 'نادي', NULL, 'ادفع مؤخرتك للخلف واثني ركبك، قبضتك بنفس مستوى اكتافك، اسحب لما تنقبض عضلات الظهر.

ملاحظات مهمة:
• ابدأ الحركة بسحب لوحي الكتف نحو بعضهما ثم اسحب بالمرفقين.
• اجعل الصدر ثابتاً ولا تتمايل بالجذع لإكمال التكرار.
• اضغط في نهاية الحركة لثانية وارجع ببطء.
• ثبّت قبضة البار وارفع بتحكم، واستعن بمساعد أو حوامل أمان عند الأوزان الثقيلة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('483f9428-be07-4b18-81e6-6ac3ca541f19', 'Cable Reardelt Fly', 'Shoulders / الأكتاف', '{"Rotator cuffs / الكفة المدورة"}', 'Shoulder Rear Pull / سحب خلفي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/bkejPHrPkmA?si=-O8q_5e72udoPRiY', 'ملاحظات مهمة:
• مرفقان مثنيان قليلاً وافتح للجانبين مع تركيز على الكتف الخلفي.
• حافظ على الظهر محايداً ولا تستخدم الزخم.
• وزن خفيف مع انقباض لثانية في الأعلى.
• اضبط الارتفاع بما يناسب الحركة، وحافظ على شدّ الكيبل طوال التمرين دون ترك الوزن يرتطم.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'تصنيف فرعي: حركة Fly (تبعيد أفقي للكتف) وليست سحباً أفقياً أو عمودياً', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Rear Delt Fly / فتح خلفي', 'Horizontal Abduction / تبعيد أفقي للكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5a1479df-3088-4330-a644-3d9cb139b19c', 'DB Chest Supported Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/H75im9fAUMc', 'ثبت صدرك على الكرسي، فتحة واسعة، واسحب الدمبل باتجاه الورك.

ملاحظات مهمة:
• ابدأ الحركة بسحب لوحي الكتف نحو بعضهما ثم اسحب بالمرفقين.
• اجعل الصدر ثابتاً ولا تتمايل بالجذع لإكمال التكرار.
• اضغط في نهاية الحركة لثانية وارجع ببطء.
• اختر وزناً تتحكم به في كل تكرار دون تأرجح، وأنزل الدمبلين بنفس السرعة التي رفعتهما.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('48f24e9c-f7c3-4806-b5f4-e65441098dca', 'Head Supported Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/c6lkPMhuyFA?si=eUivRGYSi0W7PmVe', 'راسك ثابت على البنش بدون أي ميلان بالرقبة.

ملاحظات مهمة:
• ابدأ الحركة بسحب لوحي الكتف نحو بعضهما ثم اسحب بالمرفقين.
• اجعل الصدر ثابتاً ولا تتمايل بالجذع لإكمال التكرار.
• اضغط في نهاية الحركة لثانية وارجع ببطء.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8d08ec77-f347-4969-8dab-f3f75b129ce2', 'Single Arm Dumbbell Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/QBjaGx8mS1o', 'اسحب باتجاه الورك.

ملاحظات مهمة:
• ابدأ الحركة بسحب لوحي الكتف نحو بعضهما ثم اسحب بالمرفقين.
• اجعل الصدر ثابتاً ولا تتمايل بالجذع لإكمال التكرار.
• اضغط في نهاية الحركة لثانية وارجع ببطء.
• اختر وزناً تتحكم به في كل تكرار دون تأرجح، وأنزل الدمبلين بنفس السرعة التي رفعتهما.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cc912fda-c2c9-40b7-94aa-cef1b00c8cbb', 'Single Arm Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/Qn_mHGObb8E?si=IZ0q9_tseiRIMtcs', 'اسحب باتجاه الورك.

ملاحظات مهمة:
• ابدأ الحركة بسحب لوحي الكتف نحو بعضهما ثم اسحب بالمرفقين.
• اجعل الصدر ثابتاً ولا تتمايل بالجذع لإكمال التكرار.
• اضغط في نهاية الحركة لثانية وارجع ببطء.
• اضبط الارتفاع بما يناسب الحركة، وحافظ على شدّ الكيبل طوال التمرين دون ترك الوزن يرتطم.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('00faaa8b-e0fd-4aed-8a32-23b15f5f2b2d', 'Chest Supported Machine Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/BZrdEAiR2Xs?si=WhKaSGhR0gKeeies', 'ملاحظات مهمة:
• ابدأ الحركة بسحب لوحي الكتف نحو بعضهما ثم اسحب بالمرفقين.
• اجعل الصدر ثابتاً ولا تتمايل بالجذع لإكمال التكرار.
• اضغط في نهاية الحركة لثانية وارجع ببطء.
• اضبط المقعد والمساند لتتماشى مفاصلك مع محور الجهاز قبل البدء، وسجّل الإعدادات لتكررها.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5271b8a3-62a9-4a36-af81-601b5af94fd6', 'T-Bar Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/6OtcNinT0HM?si=UPfYyypfZCaN9tTA', 'ملاحظات مهمة:
• ابدأ الحركة بسحب لوحي الكتف نحو بعضهما ثم اسحب بالمرفقين.
• اجعل الصدر ثابتاً ولا تتمايل بالجذع لإكمال التكرار.
• اضغط في نهاية الحركة لثانية وارجع ببطء.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3b98a3d3-9025-4bf3-9874-ecc9ed27e94d', 'Lats Cable Row', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/CQkT-W18N5g', 'الكيبل بنفس مستوى بطنك، اسحب باتجاه الورك.

ملاحظات مهمة:
• اسحب المرفق نحو الورك لا نحو الخلف، وركّز على عضلة اللاتس.
• لا تحرك الجذع للتعويض عن الوزن.
• اضبط الارتفاع بما يناسب الحركة، وحافظ على شدّ الكيبل طوال التمرين دون ترك الوزن يرتطم.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Lat-focused Row / تجديف لاتس', 'Shoulder Extension / مد الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e76edb03-4da1-4ca6-a822-fcba35256a4a', 'Upperback Pulldowns', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/bNmvKpJSWKM?si=hy5HgBDAHkzFHcvv', 'ملاحظات مهمة:
• اسحب القضيب نحو أعلى الصدر لا خلف الرقبة.
• قبضة ثابتة والمرفقان للأسفل، ولا تستخدم زخم الجسم.
• اضبط الارتفاع بما يناسب الحركة، وحافظ على شدّ الكيبل طوال التمرين دون ترك الوزن يرتطم.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Wide-grip Pulldown / سحب علوي بقبضة واسعة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('359c6b11-a9df-4a7c-b676-1f9d8e74ff89', 'Straight Arm Pulldown', 'Back & Lats / الظهر واللاتس', '{}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/hAMcfubonDc?si=ocU_a8VQ4VzZnTg3', 'ملاحظات مهمة:
• ذراعان شبه مستقيمتين وحرّك الكتف فقط.
• شدّ البطن ولا تقوّس الظهر.
• اشعر بالتمدد في اللاتس أعلى الحركة.
• اضبط الارتفاع بما يناسب الحركة، وحافظ على شدّ الكيبل طوال التمرين دون ترك الوزن يرتطم.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Straight-arm Pull / سحب بذراع مستقيمة', 'Shoulder Extension + Scapular Depression / مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3da48b5c-46c3-4a85-99ea-f51340dd56e9', 'DB Pullover', 'Back & Lats / الظهر واللاتس', '{"Chest / الصدر","Triceps / الترايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/ieFKuQAGYIA?si=uwqyrbKhBL6Id3_-', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.

ملاحظات مهمة:
• ذراعان شبه مستقيمتين وحرّك الكتف فقط.
• شدّ البطن ولا تقوّس الظهر.
• اشعر بالتمدد في اللاتس أعلى الحركة.
• اختر وزناً تتحكم به في كل تكرار دون تأرجح، وأنزل الدمبلين بنفس السرعة التي رفعتهما.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Straight-arm Pull / سحب بذراع مستقيمة', 'Shoulder Extension + Scapular Depression / مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('392eac94-9221-4c89-b21b-9816d5ebc048', 'Cable Facing Away Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/fV9BpknCjGM', 'ملاحظات مهمة:
• أبقِ المرفقين ثابتين بجانب الجسم ولا تتأرجح بالجذع.
• اثنِ حتى انقباض كامل وانزل ببطء 2–3 ثوانٍ.
• رسغ محايد دون ثني.
• اضبط الارتفاع بما يناسب الحركة، وحافظ على شدّ الكيبل طوال التمرين دون ترك الوزن يرتطم.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0279b6a7-c05d-4669-87bd-e2de67f447f5', 'Band Lat Pulldown', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtu.be/5R0RYj3Y9Ro', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.

ملاحظات مهمة:
• ابدأ بخفض لوحي الكتف ثم اسحب المرفقين للأسفل نحو الجنبين.
• أبقِ الصدر مرفوعاً ولا تتمايل للخلف أكثر من ميلان بسيط.
• ارجع للأعلى ببطء حتى تمدد كامل للاتس.
• تأكد من سلامة الشريط وثبّته جيداً، واحرص على شد ثابت طوال الحركة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6ecb1df8-c6d9-4c41-aff1-f2af3f81c407', 'Band Assisted Pull Ups', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://youtu.be/Ks8ah-8P1b0', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.

ملاحظات مهمة:
• ابدأ من تعلّق كامل بكتفين منخفضين، واسحب حتى الذقن فوق القضيب.
• تجنّب التأرجح، وانزل ببطء 2–3 ثوانٍ.
• استخدم مطاطاً أو جهاز مساعدة إذا لم تكمل التكرارات بتقنية جيدة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d668cb04-51df-4f95-a468-07d9066b8722', 'Pull Ups', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متقدم', 'نادي', 'https://youtu.be/x3NPAxiMRPw?si=Mwg6U1Df5aIFpjKB', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر.

ملاحظات مهمة:
• ابدأ من تعلّق كامل بكتفين منخفضين، واسحب حتى الذقن فوق القضيب.
• تجنّب التأرجح، وانزل ببطء 2–3 ثوانٍ.
• استخدم مطاطاً أو جهاز مساعدة إذا لم تكمل التكرارات بتقنية جيدة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a4281140-68e8-4b8f-9a63-a0f2fadf64ea', 'Negative Pull-Up', 'Back & Lats / الظهر واللاتس', '{"Shoulders / الأكتاف","Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://youtu.be/gbPURTSxQLY?si=TvQF5zDWfU_rR1Ax', 'القبضة اوسع من الكتف شوي، اسحب باتجاه اعلى الصدر، نزول بطيء.

ملاحظات مهمة:
• ابدأ من تعلّق كامل بكتفين منخفضين، واسحب حتى الذقن فوق القضيب.
• تجنّب التأرجح، وانزل ببطء 2–3 ثوانٍ.
• استخدم مطاطاً أو جهاز مساعدة إذا لم تكمل التكرارات بتقنية جيدة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('864bfef1-a01f-4f55-8ec6-bf9a48c99c69', 'Neutral Grip Lat Pulldown', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/kVB6SlEyjQM', 'القبضة بنفس مستوى الكتف، اسحب باتجاه اعلى الصدر.

ملاحظات مهمة:
• ابدأ بخفض لوحي الكتف ثم اسحب المرفقين للأسفل نحو الجنبين.
• أبقِ الصدر مرفوعاً ولا تتمايل للخلف أكثر من ميلان بسيط.
• ارجع للأعلى ببطء حتى تمدد كامل للاتس.
• اضبط الارتفاع بما يناسب الحركة، وحافظ على شدّ الكيبل طوال التمرين دون ترك الوزن يرتطم.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d423db2c-76c3-488b-8400-eac6a9e7a13b', 'Cable Y Raises', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/P7u6PEeOn6Q?feature=share', 'الكيبل يبدأ من تحت،ارفع الوزن على شكل Y.

ملاحظات مهمة:
• ارفع الذراعين بشكل Y بزاوية نحو 30° أمام الجسم والإبهام للأعلى.
• استخدم وزناً خفيفاً وحافظ على الصدر ثابتاً.
• اضبط الارتفاع بما يناسب الحركة، وحافظ على شدّ الكيبل طوال التمرين دون ترك الوزن يرتطم.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Y Raise (Scaption) / رفع Y بمستوى لوح الكتف', 'Shoulder Elevation in Scapular Plane (Scaption) / رفع الذراع بمستوى لوح الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('56dadba9-4982-4804-ae2f-8d332d25a90a', 'Band Assisted Chin Ups', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://youtu.be/i0yC-0YK6Uk?si=gNX26kIFz_THnR4p', 'مسكة ضيقة بمستوى الأكتاف، كل ما كان الحبل خفيف زادت المقاومة وزدات صعوبة التمرين لذلك ابدأ بحبل ثقيل وخفف كل ما تحسن مستواك.

ملاحظات مهمة:
• ابدأ من تعلّق كامل بكتفين منخفضين، واسحب حتى الذقن فوق القضيب.
• تجنّب التأرجح، وانزل ببطء 2–3 ثوانٍ.
• استخدم مطاطاً أو جهاز مساعدة إذا لم تكمل التكرارات بتقنية جيدة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4f981a19-0d42-4c36-bb80-4e267c949f00', 'Chin Ups', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', 'أخرى', 'متقدم', 'نادي', 'https://youtube.com/shorts/aV9Mz9nCsMw?si=E_ullJojGO_7srW2', 'ملاحظات مهمة:
• ابدأ من تعلّق كامل بكتفين منخفضين، واسحب حتى الذقن فوق القضيب.
• تجنّب التأرجح، وانزل ببطء 2–3 ثوانٍ.
• استخدم مطاطاً أو جهاز مساعدة إذا لم تكمل التكرارات بتقنية جيدة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Pull-up / Chin-up / عقلة', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fc23e310-a48c-418c-bd13-ee3b08f6046f', 'Kneeling Lat Pulldown', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس"}', 'Vertical Pull / سحب عمودي', 'قوة', NULL, 'متوسط', NULL, NULL, 'ملاحظات مهمة:
• ابدأ بخفض لوحي الكتف ثم اسحب المرفقين للأسفل نحو الجنبين.
• أبقِ الصدر مرفوعاً ولا تتمايل للخلف أكثر من ميلان بسيط.
• ارجع للأعلى ببطء حتى تمدد كامل للاتس.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/35/kneeling-lat-pulldown/', NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Lat-focused Pull / سحب لاتس', 'Shoulder Adduction/Extension + Scapular Depression / تقريب أو مد الكتف + خفض لوح الكتف', 'Vertical Pull / سحب عمودي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f18361e8-27b6-425a-b853-f54bfdea3526', 'TRX Back Row', 'Back & Lats / الظهر واللاتس', '{"Biceps / البايسبس","Core / البطن والكور","Lower back / أسفل الظهر"}', 'Horizontal Pull / سحب أفقي', 'قوة', 'TRX', 'متوسط', 'منزل', NULL, 'ملاحظات مهمة:
• ابدأ الحركة بسحب لوحي الكتف نحو بعضهما ثم اسحب بالمرفقين.
• اجعل الصدر ثابتاً ولا تتمايل بالجذع لإكمال التكرار.
• اضغط في نهاية الحركة لثانية وارجع ببطء.
• تأكد من تثبيت الأحزمة جيداً، وحافظ على جسم مستقيم وتحكم في زاوية الميل لضبط الصعوبة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/84/trx-reg-back-row/', NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Scapular Retraction / سحب لوح الكتف', 'Shoulder Extension + Scapular Retraction / مد الكتف + سحب لوح الكتف', 'Horizontal Pull / سحب أفقي', NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e4aff8d6-8d01-45a8-a1f1-7db1d294096e', 'Shrug', 'Back & Lats / الظهر واللاتس', '{"Trapezius / الترابيس"}', 'Scapular Elevation / رفع لوح الكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, 'ملاحظات مهمة:
• ارفع الكتفين مباشرة نحو الأذنين دون تدوير.
• توقف لثانية في الأعلى ونزول بطيء، وذراعان مستقيمتان.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف فرعي: رفع الأكتاف (Shrug) ليس نمط سحب أفقي أو عمودي', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/72/shrug/', NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Shrug / هز الكتفين', 'Scapular Elevation / رفع لوح الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ec7ac55c-0da3-4bc3-b749-6d51a33bccae', 'DB Shoulder Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtu.be/NKeyUrDYqPk', 'قوّس ظهرك العلوي قليلاً، الكوع قريب من الجسم، النزول الى مستوى الاكتاف

ملاحظات مهمة:
• شدّ البطن والألوية ولا تبالغ في تقوّس أسفل الظهر.
• ادفع للأعلى بخط مستقيم فوق الكتفين ولا تغلق المرفقين بعنف.
• انزل حتى مستوى الأذن تقريباً بتحكم.
• اختر وزناً تتحكم به في كل تكرار دون تأرجح، وأنزل الدمبلين بنفس السرعة التي رفعتهما.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('75661d4e-af51-4249-a721-b3f30dfc85cb', 'DB Standing Shoulder Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'دمبل', 'متوسط', 'منزل', 'https://youtube.com/shorts/wO0l5jW2NtQ?si=MVvS4F_7iFS8ji9R', 'ملاحظات مهمة:
• شدّ البطن والألوية ولا تبالغ في تقوّس أسفل الظهر.
• ادفع للأعلى بخط مستقيم فوق الكتفين ولا تغلق المرفقين بعنف.
• انزل حتى مستوى الأذن تقريباً بتحكم.
• اختر وزناً تتحكم به في كل تكرار دون تأرجح، وأنزل الدمبلين بنفس السرعة التي رفعتهما.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('fabbe74c-b888-48b7-962e-199bf44f3289', 'Machine Shoulder Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/3R14MnZbcpw', 'قوّس ظهرك العلوي قليلاً، الكوع قريب من الجسم، النزول الى مستوى الاكتاف

ملاحظات مهمة:
• شدّ البطن والألوية ولا تبالغ في تقوّس أسفل الظهر.
• ادفع للأعلى بخط مستقيم فوق الكتفين ولا تغلق المرفقين بعنف.
• انزل حتى مستوى الأذن تقريباً بتحكم.
• اضبط المقعد والمساند لتتماشى مفاصلك مع محور الجهاز قبل البدء، وسجّل الإعدادات لتكررها.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9f54f714-1da0-425f-95b5-899d04bd3de9', 'BB Overhead Press', 'Shoulders / الأكتاف', '{"Triceps / الترايسبس"}', 'Vertical Push / دفع عمودي', 'قوة', 'بار', 'متوسط', 'نادي', 'https://youtu.be/_RlRDWO2jfg', 'ملاحظات مهمة:
• شدّ البطن والألوية ولا تبالغ في تقوّس أسفل الظهر.
• ادفع للأعلى بخط مستقيم فوق الكتفين ولا تغلق المرفقين بعنف.
• انزل حتى مستوى الأذن تقريباً بتحكم.
• ثبّت قبضة البار وارفع بتحكم، واستعن بمساعد أو حوامل أمان عند الأوزان الثقيلة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Shoulder Press / ضغط الكتف', 'Shoulder Flexion/Abduction + Elbow Extension / ثني أو تبعيد الكتف + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('516ab4a6-b6c7-4302-9e62-6b7bb50cef72', 'DB Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/qqntiuPmLDM?feature=share', 'انحني للأمام قليلًا، ارفع للأعلى الى أن تصل لمستوى الأكتاف.

ملاحظات مهمة:
• ارفع بمرفق مثني قليلاً حتى مستوى الكتف فقط، ولا ترفع أعلى.
• قدّم المرفق على اليد، ولا ترفع الكتفين نحو الأذنين.
• نزول بطيء 2–3 ثوانٍ، وخفّف الوزن إذا احتجت للتأرجح.
• اختر وزناً تتحكم به في كل تكرار دون تأرجح، وأنزل الدمبلين بنفس السرعة التي رفعتهما.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('edffa6e1-4041-496e-9df5-939e5a2baaec', 'Seated Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/v7fwGurZ9SU?feature=share', 'انحني للأمام قليلًا، ارفع للأعلى الى أن تصل لمستوى الأكتاف.

ملاحظات مهمة:
• ارفع بمرفق مثني قليلاً حتى مستوى الكتف فقط، ولا ترفع أعلى.
• قدّم المرفق على اليد، ولا ترفع الكتفين نحو الأذنين.
• نزول بطيء 2–3 ثوانٍ، وخفّف الوزن إذا احتجت للتأرجح.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2a8ff943-6323-41d8-b26c-6a3fd69e5a04', 'Lateral Raise Machine', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/d0pRsZ9SY5w?si=XuXb_Ti0Flow7qvW', 'ملاحظات مهمة:
• ارفع بمرفق مثني قليلاً حتى مستوى الكتف فقط، ولا ترفع أعلى.
• قدّم المرفق على اليد، ولا ترفع الكتفين نحو الأذنين.
• نزول بطيء 2–3 ثوانٍ، وخفّف الوزن إذا احتجت للتأرجح.
• اضبط المقعد والمساند لتتماشى مفاصلك مع محور الجهاز قبل البدء، وسجّل الإعدادات لتكررها.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('16ebd49f-e9c8-4325-aa04-290ba761de39', 'DB Incline Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/js_StxxyxBM', 'ملاحظات مهمة:
• أبقِ المرفقين ثابتين بجانب الجسم ولا تتأرجح بالجذع.
• اثنِ حتى انقباض كامل وانزل ببطء 2–3 ثوانٍ.
• رسغ محايد دون ثني.
• اختر وزناً تتحكم به في كل تكرار دون تأرجح، وأنزل الدمبلين بنفس السرعة التي رفعتهما.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1c42ee8a-1d4d-4401-a7fc-0d02d7380dd2', 'Cable Crossover Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/wKgCc5UQjoU?si=zsaz3i31PnEU9A43', 'الكيبل يبدأ من الأسفل، انحني للأمام قليلًا، ارفع للأعلى وتحكم بالنزول.

ملاحظات مهمة:
• ارفع بمرفق مثني قليلاً حتى مستوى الكتف فقط، ولا ترفع أعلى.
• قدّم المرفق على اليد، ولا ترفع الكتفين نحو الأذنين.
• نزول بطيء 2–3 ثوانٍ، وخفّف الوزن إذا احتجت للتأرجح.
• اضبط الارتفاع بما يناسب الحركة، وحافظ على شدّ الكيبل طوال التمرين دون ترك الوزن يرتطم.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c8b60f9d-9dde-4b81-ad3a-f43fadda6189', 'DB Y Raises', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/lXp16YozXgk', 'ثبت صدرك على البنش،ارفع الوزن على شكل Y.

ملاحظات مهمة:
• ارفع الذراعين بشكل Y بزاوية نحو 30° أمام الجسم والإبهام للأعلى.
• استخدم وزناً خفيفاً وحافظ على الصدر ثابتاً.
• اختر وزناً تتحكم به في كل تكرار دون تأرجح، وأنزل الدمبلين بنفس السرعة التي رفعتهما.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Y Raise (Scaption) / رفع Y بمستوى لوح الكتف', 'Shoulder Elevation in Scapular Plane (Scaption) / رفع الذراع بمستوى لوح الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f986162d-e099-4860-8ab2-6e7a38172d09', 'Single Arm DB Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/Jm6GqVhWhNY', 'انحني للأمام قليلًا، ارفع للأعلى الى أن تصل لمستوى الأكتاف.

ملاحظات مهمة:
• ارفع بمرفق مثني قليلاً حتى مستوى الكتف فقط، ولا ترفع أعلى.
• قدّم المرفق على اليد، ولا ترفع الكتفين نحو الأذنين.
• نزول بطيء 2–3 ثوانٍ، وخفّف الوزن إذا احتجت للتأرجح.
• اختر وزناً تتحكم به في كل تكرار دون تأرجح، وأنزل الدمبلين بنفس السرعة التي رفعتهما.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a658f3f8-b649-49bc-900a-ce64d62e6b71', 'Single Arm Cable Lateral Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/J-6uEOkYAKM', 'الكيبل يبدأ من الأسفل، انحني للأمام قليلًا، ارفع للأعلى وتحكم بالنزول.

ملاحظات مهمة:
• ارفع بمرفق مثني قليلاً حتى مستوى الكتف فقط، ولا ترفع أعلى.
• قدّم المرفق على اليد، ولا ترفع الكتفين نحو الأذنين.
• نزول بطيء 2–3 ثوانٍ، وخفّف الوزن إذا احتجت للتأرجح.
• اضبط الارتفاع بما يناسب الحركة، وحافظ على شدّ الكيبل طوال التمرين دون ترك الوزن يرتطم.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Lateral Raise / رفع جانبي', 'Shoulder Abduction / تبعيد الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ef067648-4e99-463d-bba0-b7aee6f6a59b', 'Front Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Front Raise / رفع أمامي للكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, 'ملاحظات مهمة:
• ارفع حتى مستوى الكتف فقط ولا تتأرجح بالجذع.
• مرفق مثني قليلاً ونزول بطيء.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/54/front-raise/', NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Front Raise / رفع أمامي', 'Shoulder Flexion / ثني الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4b2557e4-13e6-4c68-8695-8440472e9422', 'Diagonal Raise', 'Shoulders / الأكتاف', '{}', 'Shoulder Lateral Raise / رفع جانبي للكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, 'ملاحظات مهمة:
• ارفع بخط قطري بتحكم دون تدوير الجذع.
• وزن خفيف مع انتباه لمستوى الكتف.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/371/diagonal-raise/', NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Diagonal Raise / رفع قطري', 'Shoulder Flexion + Abduction (Diagonal) / ثني وتبعيد الكتف (قطري)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9a7c3ffc-3f62-41c9-98da-66db9dc4eea8', 'High Row', 'Shoulders / الأكتاف', '{}', 'Shoulder Rear Pull / سحب خلفي للكتف', 'قوة', NULL, 'مبتدئ', NULL, NULL, 'ملاحظات مهمة:
• اسحب نحو الوجه والمرفقان للأعلى وللجانبين، ثم دوّر الذراعين للخارج في النهاية.
• لا تتمايل للخلف، وأبقِ الرسغ مستقيماً.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/336/high-row/', NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'High Row / Face Pull / سحب عالٍ باتجاه الوجه', 'Horizontal Abduction + Scapular Retraction / تبعيد أفقي للكتف + سحب لوح الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9be11638-547c-4319-92fb-19db7cb857f2', 'Single Arm Cable Facing Away Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/6sO-pK7pTPs?feature=share', 'ملاحظات مهمة:
• أبقِ المرفقين ثابتين بجانب الجسم ولا تتأرجح بالجذع.
• اثنِ حتى انقباض كامل وانزل ببطء 2–3 ثوانٍ.
• رسغ محايد دون ثني.
• اضبط الارتفاع بما يناسب الحركة، وحافظ على شدّ الكيبل طوال التمرين دون ترك الوزن يرتطم.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6b7d289c-7622-475d-a9a0-22245ed0d3af', 'Single Arm Cable Facing In Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/I-197ZW9Ffo?si=M1Yq4R1PIpdZMXRx', 'ملاحظات مهمة:
• أبقِ المرفقين ثابتين بجانب الجسم ولا تتأرجح بالجذع.
• اثنِ حتى انقباض كامل وانزل ببطء 2–3 ثوانٍ.
• رسغ محايد دون ثني.
• اضبط الارتفاع بما يناسب الحركة، وحافظ على شدّ الكيبل طوال التمرين دون ترك الوزن يرتطم.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a955214b-3166-4a82-aa41-f2f23cab1f73', 'DB Preacher', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/DZJNTb-zzn0?si=SwbdZ0O_0eTOET-5', 'ملاحظات مهمة:
• ثبّت العضد على المسند ولا ترفعه.
• لا تفرد المرفق بالكامل بسرعة في الأسفل، ونزول بطيء.
• اختر وزناً تتحكم به في كل تكرار دون تأرجح، وأنزل الدمبلين بنفس السرعة التي رفعتهما.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Preacher Curl / ثني على مسند', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('766e7102-7d18-4c7f-b556-f20a4d82b38c', 'Preacher Curl Machine', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/TouYMA3-ua4?feature=share', 'ملاحظات مهمة:
• ثبّت العضد على المسند ولا ترفعه.
• لا تفرد المرفق بالكامل بسرعة في الأسفل، ونزول بطيء.
• اضبط المقعد والمساند لتتماشى مفاصلك مع محور الجهاز قبل البدء، وسجّل الإعدادات لتكررها.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Preacher Curl / ثني على مسند', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('19b46b68-10b5-42b3-90be-7bc48081df26', 'DB Spider Curls', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/cTMjzB2_IH8?si=qsIKEEFVfEvPXwqf', 'ملاحظات مهمة:
• أبقِ المرفقين ثابتين بجانب الجسم ولا تتأرجح بالجذع.
• اثنِ حتى انقباض كامل وانزل ببطء 2–3 ثوانٍ.
• رسغ محايد دون ثني.
• اختر وزناً تتحكم به في كل تكرار دون تأرجح، وأنزل الدمبلين بنفس السرعة التي رفعتهما.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b2142e44-b3c3-4648-aeb7-7950f35cedcf', 'Zottman Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://www.youtube.com/watch?v=ZXbOOIOPOi8', 'ملاحظات مهمة:
• أبقِ المرفقين ثابتين بجانب الجسم ولا تتأرجح بالجذع.
• اثنِ حتى انقباض كامل وانزل ببطء 2–3 ثوانٍ.
• رسغ محايد دون ثني.
• اختر وزناً تتحكم به في كل تكرار دون تأرجح، وأنزل الدمبلين بنفس السرعة التي رفعتهما.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a64ad054-3283-465b-9253-291a6c9e60d5', 'Hammer Curl', 'Biceps / البايسبس', '{"Forearms / الساعد"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• قبضة محايدة (الإبهام للأعلى) والمرفقان ثابتان.
• لا تتأرجح، وانزل بتحكم.
• اختر وزناً تتحكم به في كل تكرار دون تأرجح، وأنزل الدمبلين بنفس السرعة التي رفعتهما.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/10/hammer-curl/', NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Hammer / Neutral-grip Curl / ثني بقبضة محايدة', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5d5433b6-cc11-4c7a-8fe5-5ed5d2c43184', 'TRX Biceps Curl', 'Biceps / البايسبس', '{"Forearms / الساعد","Core / البطن والكور"}', 'Elbow Flexion / ثني الكوع', 'قوة', 'TRX', 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• أبقِ المرفقين ثابتين بجانب الجسم ولا تتأرجح بالجذع.
• اثنِ حتى انقباض كامل وانزل ببطء 2–3 ثوانٍ.
• رسغ محايد دون ثني.
• تأكد من تثبيت الأحزمة جيداً، وحافظ على جسم مستقيم وتحكم في زاوية الميل لضبط الصعوبة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/78/trx-reg-biceps-curl/', NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Biceps Curl / ثني البايسبس', 'Elbow Flexion / ثني الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('80ac915b-8e37-4347-b74d-0d56eeed0a2a', 'DB Triceps Extensions', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtu.be/d7SXlU5HkYM?si=WuuPa9-yeByaP5sI', 'ملاحظات مهمة:
• أبقِ المرفقين مثبتين وقريبين من الرأس، والحركة من المرفق فقط.
• شدّ البطن لتجنب تقوّس الظهر، ومدى كامل بتحكم.
• اختر وزناً تتحكم به في كل تكرار دون تأرجح، وأنزل الدمبلين بنفس السرعة التي رفعتهما.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Overhead Extension / مد فوق الرأس', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3d822a1b-427e-4770-9769-ceeb47f57782', 'DB Floor Triceps Extensions', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'دمبل', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/dpFav9Ve4rY?si=ZBdKK8VF4aPMpi3v', 'ملاحظات مهمة:
• أبقِ العضد ثابتاً وحرّك الساعد فقط.
• انزل بتحكم نحو الجبهة أو خلف الرأس بزاوية مريحة للمرفق.
• اختر وزناً تتحكم به في كل تكرار دون تأرجح، وأنزل الدمبلين بنفس السرعة التي رفعتهما.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Lying Extension / مد مستلقٍ', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d46236ed-652b-469d-a5a5-9ce75753c570', 'Cable Crossbody Extensions', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://www.youtube.com/watch?v=jtLTcED38Dg', 'الكيبل يبدأ بالمنتصف زي الفيديو، بحيث لما تسحب الكيبل يكون بنفس مستوى الترابس، الأكواع والأكتاف ثابتين مكانهم والحركة كلها بثني وفرد الكوع.

ملاحظات مهمة:
• أبقِ العضد ثابتاً، وركّز على الانقباض الكامل للترايسبس.
• اضبط الارتفاع بما يناسب الحركة، وحافظ على شدّ الكيبل طوال التمرين دون ترك الوزن يرتطم.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Cross-body Extension / مد عرضي', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a41e2a76-111a-4946-9589-9b95c587497f', 'Triceps Pushdown', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/QsoN4u6j8nM?feature=share', 'انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.

ملاحظات مهمة:
• المرفقان ثابتان بجانب الجسم، والحركة من المرفق فقط.
• افرد بالكامل مع انقباض لثانية، وارجع ببطء دون ارتفاع الكتفين.
• اضبط الارتفاع بما يناسب الحركة، وحافظ على شدّ الكيبل طوال التمرين دون ترك الوزن يرتطم.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('69b4a718-c836-4dee-ae4e-88721090b80e', 'Cable Crossover Pressdowns', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/Y3CDzx-oj3k', 'الكيبل يبدأ من الأعلى،انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.

ملاحظات مهمة:
• المرفقان ثابتان بجانب الجسم، والحركة من المرفق فقط.
• افرد بالكامل مع انقباض لثانية، وارجع ببطء دون ارتفاع الكتفين.
• اضبط الارتفاع بما يناسب الحركة، وحافظ على شدّ الكيبل طوال التمرين دون ترك الوزن يرتطم.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('cbc8519a-18f7-401e-8284-c11e66f76ba5', 'Band Triceps Pushdown', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'مطاط', 'مبتدئ', 'منزل', 'https://youtube.com/shorts/mYs1rEYtZK4?si=k8vdZxNNEB5wj2CA', 'الكيبل يبدأ من الأعلى،انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.

ملاحظات مهمة:
• المرفقان ثابتان بجانب الجسم، والحركة من المرفق فقط.
• افرد بالكامل مع انقباض لثانية، وارجع ببطء دون ارتفاع الكتفين.
• تأكد من سلامة الشريط وثبّته جيداً، واحرص على شد ثابت طوال الحركة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('74f33b86-0d40-4c4d-9091-34ac4451f53b', 'Single Cable Triceps Pressdowns', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/8rl4ioij6lc', 'الكيبل يبدأ من الأعلى،انحني للأمام قليلاً، امسك طرف الحبل، ثبتي اكواعك مكانها واسحب الحبل للأسفل باتجاه الخارج.

ملاحظات مهمة:
• المرفقان ثابتان بجانب الجسم، والحركة من المرفق فقط.
• افرد بالكامل مع انقباض لثانية، وارجع ببطء دون ارتفاع الكتفين.
• اضبط الارتفاع بما يناسب الحركة، وحافظ على شدّ الكيبل طوال التمرين دون ترك الوزن يرتطم.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Pushdown / دفع للأسفل', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('398fa57d-fe4d-41ff-8d05-725e4c915644', 'Cable Overhead Extension', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', 'كيبل', 'مبتدئ', 'نادي', 'https://www.youtube.com/shorts/Q3bO1Fh4734', 'اترك الحبل يسحب معصمك وكوعك ثابت لما تستطيل التراي ثم ارفع الوزن لما تستقيم اليد، كوعك ثابت طول الوقت والحركة ثني ومد من مفصل الكوع، ممكن تطبق كل يد لحالها اذا كان اسهل لك.

ملاحظات مهمة:
• أبقِ المرفقين مثبتين وقريبين من الرأس، والحركة من المرفق فقط.
• شدّ البطن لتجنب تقوّس الظهر، ومدى كامل بتحكم.
• اضبط الارتفاع بما يناسب الحركة، وحافظ على شدّ الكيبل طوال التمرين دون ترك الوزن يرتطم.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Overhead Extension / مد فوق الرأس', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('203581d3-1189-430b-a8ee-31eb6e845b45', 'Triceps Dips', 'Triceps / الترايسبس', '{"Chest / الصدر","Shoulders / الأكتاف"}', 'Vertical Push / دفع عمودي', 'قوة', NULL, 'متوسط', NULL, 'https://youtube.com/shorts/SpSE_A5L-YA?si=bSAzRM9SBuX-3mE0', 'ملاحظات مهمة:
• انزل حتى زاوية مريحة للكتف (نحو 90° في المرفق) ولا تتجاوزها.
• أبقِ الصدر مرفوعاً قليلاً للأمام لتركيز أكبر على الصدر، ومستقيماً للترايسبس.
• توقف إذا شعرت بألم في مقدمة الكتف.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Dip / متوازي', 'Shoulder Extension + Elbow Extension / مد الكتف + مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('16e03046-a8df-4136-9309-b5f9e1b3f02f', 'Triceps Kickback', 'Triceps / الترايسبس', '{}', 'Elbow Extension / مد الكوع', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/YebyKE3Ts8o?si=H_h9z5BXutFBbFhq', 'ملاحظات مهمة:
• العضد موازٍ للجسم وثابت، والحركة من المرفق.
• وزن خفيف وانقباض في الأعلى.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/55/triceps-kickback/', NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Triceps Kickback / ركلة الترايسبس', 'Elbow Extension / مد الكوع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('df9fd7cc-c694-40ca-bc1c-486f5f0539af', 'Suitcase Carry', 'Core / البطن والكور', '{"Forearms / الساعد"}', 'Loaded Carry / حمل ومشي', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/BaRMAhD7SP4?si=KkiMH8OSIEz_TB53', 'ملاحظات مهمة:
• امشِ بجذع مستقيم دون ميلان نحو الوزن.
• كتف ثابت ومشي بخطوات منتظمة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'نفس التمرين ورد أيضاً تحت التصنيف «Functional Training» (صف المصدر 160) || رابط آخر في المصدر (صف 160): https://youtu.be/BaRMAhD7SP4?si=dCR2n2VSPaHhxfL3', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Suitcase Carry / حمل جانبي', 'Isometric Trunk + Grip Under Load / تثبيت الجذع والقبضة أثناء المشي', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4a395c7a-6bce-421b-9808-9678987f7289', 'Cable Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'كيبل', 'مبتدئ', 'نادي', 'https://youtu.be/ToJeyhydUxU?si=Z5dv34foxX4VtRH6', 'الحركة عبارة عن ثني للعمود الفقري وكأنك تقرب صدرك لوركك.

ملاحظات مهمة:
• ارفع الكتفين بتقوّس الجذع قليلاً ولا تسحب الرقبة باليدين.
• زفير عند الرفع وانقباض البطن لثانية.
• اضبط الارتفاع بما يناسب الحركة، وحافظ على شدّ الكيبل طوال التمرين دون ترك الوزن يرتطم.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Crunch / كرنش', 'Trunk Flexion / ثني الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('476bf474-217c-4367-a765-4e6e3fd029bd', 'Leg Raises', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', NULL, 'مبتدئ', NULL, 'https://youtube.com/shorts/UqmbxvOgnX4?si=U3pDG4Jf0x1mtC_7', 'ملاحظات مهمة:
• ارفع الحوض عن الأرض بتحكم لا بالزخم.
• حافظ على أسفل الظهر ملتصقاً بالأرض.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Reverse Crunch / Leg Raise / كرنش عكسي ورفع الأرجل', 'Hip Flexion + Posterior Pelvic Tilt / ثني الورك + إمالة الحوض للخلف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6145193c-c7ab-4ac9-8886-74a2ecda1d74', 'Reverse Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/esYVzdEfs04?si=N44MZZHlVeSQc1S3', 'ملاحظات مهمة:
• ارفع الحوض عن الأرض بتحكم لا بالزخم.
• حافظ على أسفل الظهر ملتصقاً بالأرض.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Reverse Crunch / Leg Raise / كرنش عكسي ورفع الأرجل', 'Hip Flexion + Posterior Pelvic Tilt / ثني الورك + إمالة الحوض للخلف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c3600678-796f-4244-a904-6859a6312777', 'Belly Breathing', 'Core / البطن والكور', '{}', 'Core Activation & Breathing / تفعيل الجذع والتنفس', 'إحماء/تفعيل', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/Shk8cmgv0Ew?si=mXkcj9PH6eH_tLcd', 'نفس عميق من الانف ننفخ فيه البطن ثم نطلعه من الفم ببطئ مع ضغط البطن للداخل اثناء اخراج النفس

ملاحظات مهمة:
• شهيق من الأنف يوسّع البطن والأضلاع، وزفير بطيء من الفم.
• الكتفان مرتخيان ولا ترفع الصدر.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Diaphragmatic Breathing / تنفس حجابي', 'Diaphragmatic Breathing + Abdominal Bracing / تنفس حجابي + شد البطن', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7938c9b2-fdbe-477a-a17e-a80decf49322', 'Reverse Tabletop Bridge', 'Core / البطن والكور', '{"Glutes / المؤخرة"}', 'Glute Hip Extension / دفع خلفي للورك', 'قوة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://youtu.be/d1yE9cGtPWo?si=2aoNqmUAN054rP75', 'اخذ نفس اثناء الطلوع، اثبت ثواني فوق واشد عضلات بطني، اطلع النفس اثناء النزول

ملاحظات مهمة:
• ذقن للأسفل قليلاً وضلوع للأسفل، ولا تبالغ في تقوّس أسفل الظهر في الأعلى.
• ادفع بالكعبين، وانقباض الألوية في الأعلى لثانية.
• ركبتان بزاوية نحو 90° في أعلى الحركة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Hip Thrust / Bridge / بسط الورك (ثرست وجسر)', 'Hip Extension / بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1130f999-e559-4853-a222-14a6dce01e59', 'Pelvic Tilting', 'Core / البطن والكور', '{}', 'Core Activation & Breathing / تفعيل الجذع والتنفس', 'إحماء/تفعيل', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/DqqUIfMuDX4?si=uzl0SRl_M9guUT3j', 'الحركة من الحوض، اخذ نفس وادف حوضي للاعلى قليلا، اطلع النفس اثناء نزول الحوض والصق اسفل ظهري بالارض

ملاحظات مهمة:
• حركة صغيرة ناعمة من الحوض دون رفع الأرداف.
• تنفس طبيعي ولا تضغط بقوة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Pelvic Tilt / إمالة الحوض', 'Posterior Pelvic Tilt / إمالة الحوض للخلف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('154d09f2-0b82-46b1-8ba4-bd0ce19dc85f', 'Crunch', 'Core / البطن والكور', '{}', 'Trunk Flexion / ثني الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'ملاحظات مهمة:
• ارفع الكتفين بتقوّس الجذع قليلاً ولا تسحب الرقبة باليدين.
• زفير عند الرفع وانقباض البطن لثانية.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/52/crunch/', NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Crunch / كرنش', 'Trunk Flexion / ثني الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('19ae161d-d1dc-4355-8815-03e151fe77d3', 'Standing Wood Chop', 'Core / البطن والكور', '{}', 'Trunk Rotation / دوران الجذع', 'كور', NULL, 'مبتدئ', NULL, NULL, 'ملاحظات مهمة:
• دوّر من الجذع والورك، وأبقِ الذراعين شبه مستقيمتين.
• أبقِ الحوض مستقراً وتحكم في العودة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/108/standing-wood-chop/', NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Rotation / Chop / دوران وتقطيع', 'Trunk Rotation / دوران الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('55f51450-7387-4435-ba85-314e8184ff2e', 'Russian Twist', 'Core / البطن والكور', '{"Lower back / أسفل الظهر"}', 'Trunk Rotation / دوران الجذع', 'كور', NULL, 'مبتدئ', NULL, NULL, 'ملاحظات مهمة:
• دوّر من الجذع والورك، وأبقِ الذراعين شبه مستقيمتين.
• أبقِ الحوض مستقراً وتحكم في العودة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/65/russian-twist/', NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Rotation / Chop / دوران وتقطيع', 'Trunk Rotation / دوران الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('063a1035-bc0d-4f0d-afa4-cf8f89cb440a', 'Cable Twisted', 'Core / البطن والكور', '{"Lower back / أسفل الظهر"}', 'Trunk Rotation / دوران الجذع', 'كور', 'كيبل', 'مبتدئ', 'نادي', NULL, 'ملاحظات مهمة:
• دوّر من الجذع والورك، وأبقِ الذراعين شبه مستقيمتين.
• أبقِ الحوض مستقراً وتحكم في العودة.
• اضبط الارتفاع بما يناسب الحركة، وحافظ على شدّ الكيبل طوال التمرين دون ترك الوزن يرتطم.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'إضافة المدربة', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Rotation / Chop / دوران وتقطيع', 'Trunk Rotation / دوران الجذع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('29634278-242e-4a73-926c-4fc3d7fa8344', 'Calves On Leg Press', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/XdtWVYFVhGU', 'ثبت أصابعك أو مقدمة رجلك على الجهاز، لا تبالغ بالوزن، انزل بكعبك لين تمتد بطاتك بشكل كامل ثم ادفع.

ملاحظات مهمة:
• مدى كامل: انزل حتى تمدد البطة ثم ارتفع على أطراف الأصابع بالكامل.
• توقف لثانية في الأعلى والأسفل، وبدون ارتداد.
• حافظ على الركبة ثابتة (مفرودة للبطة السفلية أو مثنية لعضلة النعلية).
• اضبط المقعد والمساند لتتماشى مفاصلك مع محور الجهاز قبل البدء، وسجّل الإعدادات لتكررها.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6e4db18e-1a9d-4229-87e7-48fd0a1e4940', 'Calves Raise', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/H6WptvjXkgw', 'حط تحت اقدامك بليتس أو أي شي يرفعك عن الأرض، انزل من اصابعك اقصى نزول ثم ادفع للأعلى

ملاحظات مهمة:
• مدى كامل: انزل حتى تمدد البطة ثم ارتفع على أطراف الأصابع بالكامل.
• توقف لثانية في الأعلى والأسفل، وبدون ارتداد.
• حافظ على الركبة ثابتة (مفرودة للبطة السفلية أو مثنية لعضلة النعلية).
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('0eabdbff-a244-40a9-bd1c-2272f3013b8d', 'Calf Raise (Machine)', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', 'جهاز', 'مبتدئ', 'نادي', NULL, 'ملاحظات مهمة:
• مدى كامل: انزل حتى تمدد البطة ثم ارتفع على أطراف الأصابع بالكامل.
• توقف لثانية في الأعلى والأسفل، وبدون ارتداد.
• حافظ على الركبة ثابتة (مفرودة للبطة السفلية أو مثنية لعضلة النعلية).
• اضبط المقعد والمساند لتتماشى مفاصلك مع محور الجهاز قبل البدء، وسجّل الإعدادات لتكررها.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/294/calf-raise/', NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('43426287-f020-4ddd-a06d-593a411083fb', 'Calf Raises (Barbell)', 'Calves / البطات', '{}', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', 'قوة', 'بار', 'مبتدئ', 'نادي', NULL, 'ملاحظات مهمة:
• مدى كامل: انزل حتى تمدد البطة ثم ارتفع على أطراف الأصابع بالكامل.
• توقف لثانية في الأعلى والأسفل، وبدون ارتداد.
• حافظ على الركبة ثابتة (مفرودة للبطة السفلية أو مثنية لعضلة النعلية).
• ثبّت قبضة البار وارفع بتحكم، واستعن بمساعد أو حوامل أمان عند الأوزان الثقيلة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/51/calf-raises/', NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Calf Raise / رفع الكعب', 'Ankle Plantar Flexion / ثني أخمصي للكاحل', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('7aa8ab2d-7794-4ddd-b0cb-136062e8dd6d', 'Adductor Slides', 'Adductors / الأفخاذ الداخلية', '{}', 'Hip Adduction / تقريب الورك', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/6U7dfuxaX9g?si=lkH35E7tZxGBePBj', 'ملاحظات مهمة:
• حرّك الرجل بتحكم دون إجهاد أسفل الظهر.
• وزن الجسم مثبت على الرجل الأخرى.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor strength»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Adductor Slide / انزلاق للتقريب', 'Hip Adduction / تقريب الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b046ad36-c3b2-436b-8801-f710d66616bf', 'Adductor Machine', 'Adductors / الأفخاذ الداخلية', '{}', 'Hip Adduction / تقريب الورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtu.be/SU1LQhq3o2g?si=_55FKBOlcn8Ilw4X', 'ملاحظات مهمة:
• اضبط مدى بداية مريح ولا تفتح أكثر من المدى الطبيعي.
• اضغط بتحكم وارجع ببطء دون ارتداد.
• اضبط المقعد والمساند لتتماشى مفاصلك مع محور الجهاز قبل البدء، وسجّل الإعدادات لتكررها.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Adductor Machine / جهاز التقريب', 'Hip Adduction / تقريب الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('c6de5636-833c-4360-97e0-16a5dd483c1d', 'Seated Abductor Machine', 'Abductors / مبعدات الفخذ', '{}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'جهاز', 'مبتدئ', 'نادي', 'https://youtube.com/shorts/riEMreTHNbM?si=wE3vfJBYQY7j_oJ2', 'ملاحظات مهمة:
• حرّك الرجلين للخارج بتحكم دون ميلان الجذع.
• اضغط في نهاية الحركة لثانية وارجع ببطء.
• اضبط المقعد والمساند لتتماشى مفاصلك مع محور الجهاز قبل البدء، وسجّل الإعدادات لتكررها.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor strength»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('59126625-27f4-4db0-96e4-4525729faa37', 'Hip Abductor Plank', 'Abductors / مبعدات الفخذ', '{"Core / البطن والكور"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtu.be/2lB5RL91yWo?si=WRm9rUORpFK6dXPl', 'ملاحظات مهمة:
• حرّك الرجلين للخارج بتحكم دون ميلان الجذع.
• اضغط في نهاية الحركة لثانية وارجع ببطء.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «adductor strength»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('b3b15007-6569-4d42-889d-d42bf587a4ef', 'Dirty Dog', 'Abductors / مبعدات الفخذ', '{"Core / البطن والكور"}', 'Glute Hip Abduction / دفع جانبي للورك', 'قوة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'ملاحظات مهمة:
• حرّك الرجلين للخارج بتحكم دون ميلان الجذع.
• اضغط في نهاية الحركة لثانية وارجع ببطء.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/109/dirty-dog/', NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Hip Abduction / تبعيد الورك', 'Hip Abduction / تبعيد الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d73b2c8e-f6f7-4ce6-8dcd-3e2a68b135c1', 'Rotator Cuff', 'Rotator cuffs / الكفة المدورة', '{}', 'Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف', 'قوة', NULL, 'مبتدئ', NULL, 'https://youtu.be/mO8YJAxVG2M?si=KL_llR6Z47Yt89uk', 'ملاحظات مهمة:
• وزن خفيف جداً، المرفق ملتصق بالجسم (يمكن وضع منشفة تحته).
• حركة بطيئة بمدى مريح دون ألم.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «Functional Training»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'External Rotation / دوران خارجي', 'Shoulder External Rotation / دوران خارجي للكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('f9eec034-08de-4969-8afa-4d6dd3e9eb94', 'Supine Hamstrings Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'استلقِ على ظهرك وارفع رجلاً واحدة ومدّها ببطء مع سحب أصابع القدم نحوك، دون أي حركة في الحوض أو أسفل الظهر. اثبت 15–30 ثانية، 2–4 مرات لكل رجل.

ملاحظات مهمة:
• حركة بطيئة بمدى مريح دون ألم.
• تنفس بهدوء ولا تفرض المدى.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/235/supine-hamstrings-stretch/', NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Hamstring Stretch / إطالة الخلفية', 'Hip Flexion with Knee Extended / ثني الورك مع مد الركبة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('1e951baa-ee28-4a07-afa2-cf5138b8f0a8', 'Stability Ball Reverse Extensions', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة"}', 'Spinal Extension / بسط الجذع', 'كور', 'كرة سويسرية', 'مبتدئ', 'منزل', NULL, 'ملاحظات مهمة:
• ارفع الرجلين بتحكم حتى استقامة الجسم دون ارتداد.
• اضغط الألوية في الأعلى.
• ثبّت الكرة جيداً قبل البدء، وتحرك ببطء لتجنب الانزلاق.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/64/stability-ball-reverse-extensions/', NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Reverse Extension / بسط عكسي', 'Hip Extension + Spinal Extension / بسط الورك + بسط العمود الفقري', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('2aa21bf1-bcaf-4410-ace6-1048520fb74e', 'Contralateral Limb Raises', 'Lower back / أسفل الظهر', '{"Glutes / المؤخرة","Back & Lats / الظهر واللاتس","Shoulders / الأكتاف"}', 'Spinal Extension / بسط الجذع', 'كور', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'ملاحظات مهمة:
• ارفع الصدر قليلاً فقط، ولا تبالغ في تقوّس أسفل الظهر.
• حركة بطيئة مع تنفس منتظم.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'خطوات الأداء التفصيلية في «رابط المصدر» || تصنيف مقترح: ACE تذكر عدة عضلات أساسية (عمود «العضلات المستهدفة في المصدر») — يُراجَع قبل الاعتماد', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/53/contralateral-limb-raises/', NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Prone Extension / بسط على البطن', 'Spinal Extension / بسط العمود الفقري', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8a3e7493-6f5e-485b-beab-e4fa9e0f0fee', 'Inner Thigh Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/uqCfJYKojLU?si=Gev0VeOwVp5z6gB2', 'الضغط والدفع يكون من جهة الفخذ ، لا تدفع من ركبتك!

ملاحظات مهمة:
• حركة بطيئة بمدى مريح دون ألم.
• تنفس بهدوء ولا تفرض المدى.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «stretch»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Adductor Stretch / إطالة المقربات', 'Hip Abduction (Adductor Stretch) / تبعيد الورك (إطالة المقربات)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4f20af2b-a69d-43df-a549-b2b9d18ac5a8', 'Hips Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://youtube.com/shorts/uqCfJYKojLU?si=Gev0VeOwVp5z6gB2', 'ملاحظات مهمة:
• حركة بطيئة بمدى مريح دون ألم.
• تنفس بهدوء ولا تفرض المدى.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «stretch»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Hip Stretch / إطالة الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('36407719-83f1-4e39-b871-1e4d802fe656', 'Kneeling Hip-flexor Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'من وضع الركوع: الركبة الخلفية تحت الورك والقدم الأمامية أمامك والركبة فوق الكاحل. شد البطن وادفع الحوض للأمام دون تقويس أسفل الظهر، واعصر مؤخرة الجهة الخلفية لزيادة الإطالة. اثبت 30–45 ثانية، 2–5 مرات.

ملاحظات مهمة:
• حركة بطيئة بمدى مريح دون ألم.
• تنفس بهدوء ولا تفرض المدى.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/142/kneeling-hip-flexor-stretch/', NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Hip Flexor Stretch / إطالة ثانيات الورك', 'Hip Extension (End Range) / بسط الورك في نهاية المدى', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e67f8cfe-420c-4d9d-b101-4a9f42d0ead5', 'Side Lying Quadriceps Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'استلقِ على جنبك وشد البطن، واسحب كعب الرجل العلوية نحو المؤخرة بيدك مع إبقاء الركبة في خط الورك. اثبت 30–45 ثانية، 2–5 مرات لكل جهة.

ملاحظات مهمة:
• حركة بطيئة بمدى مريح دون ألم.
• تنفس بهدوء ولا تفرض المدى.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/149/side-lying-quadriceps-stretch/', NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Quadriceps Stretch / إطالة الأمامية', 'Knee Flexion + Hip Extension (End Range) / ثني الركبة + بسط الورك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('89434721-b4fa-4aed-8561-824cc14f3f2a', 'Standing Lunge Stretch', 'Stretching / الإطالات', '{}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'ملاحظات مهمة:
• حركة بطيئة بمدى مريح دون ألم.
• تنفس بهدوء ولا تفرض المدى.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/137/standing-lunge-stretch/', NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Hip Flexor Stretch / إطالة ثانيات الورك', 'Hip Extension (End Range) / بسط الورك في نهاية المدى', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a4d6906d-9fce-421e-b7c5-e0550c65b175', 'Lateral Bound', 'Plyometrics / التمارين الانفجارية', '{"Glutes / المؤخرة","Quadriceps / الأمامية","Abductors / مبعدات الفخذ"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متوسط', 'بدون معدات', 'https://www.youtube.com/watch?v=soqQy4dzEts', 'ملاحظات مهمة:
• اهبط بنعومة وتوازن على رجل واحدة قبل القفزة التالية.
• ركبة فوق القدم ولا تلتوي للداخل.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «Functional Training»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Lateral Jump / قفز جانبي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('4c426ce5-3e4e-432f-b8b0-59090708ce86', 'Box Jumps', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Calves / البطات"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'أخرى', 'متوسط', 'نادي', NULL, 'ملاحظات مهمة:
• انزل بتحكم ثم اقفز بانفجار وهبوط ناعم على كامل القدم والركبتان مثنيتان.
• أوقف المجموعة عند هبوط تقنية الأداء.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'العضلة محددة من اسم التمرين نفسه (تصنيفه في المصدر «CrossFit»)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Vertical Jump / قفز عمودي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('6bdd7a4b-acd6-47b9-adcf-b0e236a4b04f', 'Squat Jump', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متوسط', 'بدون معدات', NULL, 'قف بعرض الحوض، ادفع الورك للخلف وانزل، ثم اقفز بقوة بمدّ الكاحل والركبة والورك معاً. انزل بهدوء على منتصف القدم مع دفع الورك للخلف ودون قفل الركب. ابدأ بقفزات صغيرة حتى تتقن الهبوط.

ملاحظات مهمة:
• انزل بتحكم ثم اقفز بانفجار وهبوط ناعم على كامل القدم والركبتان مثنيتان.
• أوقف المجموعة عند هبوط تقنية الأداء.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/222/squat-jump/', NULL, 'review', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Vertical Jump / قفز عمودي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('a63da586-c0cc-4c9a-97d7-9754e466f0d1', 'Tuck Jump', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متقدم', 'بدون معدات', NULL, 'استخدم الذراعين للزخم: أرجعهما للخلف عند النزول وأرجحهما للأمام والأعلى عند القفز، واسحب الركبتين نحو الصدر في الهواء.

ملاحظات مهمة:
• انزل بتحكم ثم اقفز بانفجار وهبوط ناعم على كامل القدم والركبتان مثنيتان.
• أوقف المجموعة عند هبوط تقنية الأداء.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/180/tuck-jump/', NULL, 'review', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Vertical Jump / قفز عمودي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('95ec9d9a-ab56-4896-9418-ccb28fe4047a', 'Cycled Split-Squat Jump', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Hamstrings / الخلفية"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متقدم', 'بدون معدات', NULL, 'ملاحظات مهمة:
• هبوط ناعم والركبة فوق القدم دون انهيار للداخل.
• أبقِ الجذع مرفوعاً.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/234/cycled-split-squat-jump/', NULL, 'review', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Split Jump / قفز سبليت', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('3fe4870f-7d0e-46d4-975d-76cb63c69836', 'Lateral Cone Jumps', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Calves / البطات"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'أخرى', 'متوسط', 'نادي', NULL, 'ملاحظات مهمة:
• اهبط بنعومة وتوازن على رجل واحدة قبل القفزة التالية.
• ركبة فوق القدم ولا تلتوي للداخل.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/120/lateral-cone-jumps/', NULL, 'review', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Lateral Jump / قفز جانبي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('5fbc2948-247a-446c-8c94-c82e388d7388', 'Forward Linear Jumps', 'Plyometrics / التمارين الانفجارية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Hamstrings / الخلفية"}', 'Jump / Plyometric / قفز وحركات انفجارية', 'قدرة', 'وزن الجسم', 'متوسط', 'بدون معدات', NULL, 'ملاحظات مهمة:
• اهبط بنعومة واثنِ الركبتين لامتصاص الصدمة.
• ابدأ بمسافات قصيرة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'خطوات الأداء التفصيلية في «رابط المصدر»', 'مصدر خارجي موثوق', 'ACE Fitness (American Council on Exercise) — Exercise Library', 'https://www.acefitness.org/resources/everyone/exercise-library/177/forward-linear-jumps/', NULL, 'review', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Horizontal Jump / قفز أمامي', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('dd1ddca7-c7e8-495a-bf14-93099f40c680', 'Jogging', 'CrossFit / كروس فت', '{"Quadriceps / الأمامية","Hamstrings / الخلفية","Calves / البطات"}', 'Locomotion / مشي وجري ودفع', 'كارديو', 'وزن الجسم', 'مبتدئ', 'بدون معدات', NULL, 'ملاحظات مهمة:
• ابدأ بإحماء تدريجي، وخطوات خفيفة بوضعية مستقيمة.
• زد المسافة أو السرعة بالتدريج لتجنب الإصابة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Running / جري', 'Gait: Alternating Hip/Knee Extension / نمط المشي والجري', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('907cd39c-2902-4bb6-9ed9-6ea2e40285c4', 'Wall Ball', 'CrossFit / كروس فت', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Shoulders / الأكتاف"}', 'Squat (Knee-dominant) / سكوات (هيمنة الركبة)', 'قوة', 'أخرى', 'متوسط', 'نادي', NULL, 'ملاحظات مهمة:
• اجعل الحركة سلسة: سكوات ثم دفع انفجاري من الورك والركبة للرمي.
• ابدأ بوزن خفيف جداً لإتقان التوقيت.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Squat to Throw / سكوات مع رمي', 'Knee/Hip Extension + Shoulder Flexion / مد الركبة والورك + ثني الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('21a47a0c-212f-4fae-a652-9ee1ad9b2ff8', 'Snatch', 'CrossFit / كروس فت', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Shoulders / الأكتاف"}', 'Olympic Lift (Triple Extension) / رفعات أولمبية (بسط ثلاثي)', 'قدرة', 'بار', 'متقدم', 'نادي', NULL, 'ملاحظات مهمة:
• تقنية معقدة: تعلّمها بعصا أو وزن خفيف أولاً وبإشراف مدرب.
• حافظ على ظهر محايد والبار قريباً من الجسم.
• ثبّت قبضة البار وارفع بتحكم، واستعن بمساعد أو حوامل أمان عند الأوزان الثقيلة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Snatch / سناتش', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8d4bcd42-4ed9-4b23-b185-7da8e64efc39', 'Clean', 'CrossFit / كروس فت', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Quadriceps / الأمامية"}', 'Olympic Lift (Triple Extension) / رفعات أولمبية (بسط ثلاثي)', 'قدرة', 'بار', 'متقدم', 'نادي', NULL, 'ملاحظات مهمة:
• تقنية معقدة: ابدأ بوزن خفيف وبإشراف مدرب.
• الدفع من الورك والركبة والكاحل ثم استقبال البار بمرفقين عاليين.
• ثبّت قبضة البار وارفع بتحكم، واستعن بمساعد أو حوامل أمان عند الأوزان الثقيلة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Clean / كلين', 'Triple Extension (Hip, Knee, Ankle) / بسط ثلاثي (الورك والركبة والكاحل)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('70fcc68c-b43d-4bd9-8dca-a81ebd1f8c39', 'Turkish Get-Up', 'Functional / التمارين الوظيفية', '{"Shoulders / الأكتاف","Core / البطن والكور","Glutes / المؤخرة"}', 'Full-body Integrated / حركة متكاملة للجسم', 'قوة', 'كيتلبل', 'متقدم', 'منزل', 'https://www.youtube.com/watch?v=0bWRPC49-KI', 'ملاحظات مهمة:
• تحرك بخطوات واضحة، وعيناك على الوزن مع بقاء الذراع عمودية.
• ابدأ بدون وزن أو بوزن خفيف جداً.
• أبقِ الكيتلبل قريباً من الجسم وقبضة آمنة، ولا تتجاوز وزناً تتحكم فيه.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Turkish Get-Up / النهوض التركي', 'Multi-joint Integrated / حركة متعددة المفاصل', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('d968264b-ea4b-4946-a8e9-59c389ba76ef', 'Sled Pull/Push', 'Functional / التمارين الوظيفية', '{"Quadriceps / الأمامية","Glutes / المؤخرة","Calves / البطات"}', 'Locomotion / مشي وجري ودفع', 'قوة', 'أخرى', 'متوسط', 'نادي', 'https://www.youtube.com/watch?v=3KWK7SIdPz4', 'ملاحظات مهمة:
• جذع ثابت ومائل للأمام، وادفع بخطوات قوية ومتتالية.
• تنفس منتظم، وابدأ بوزن يسمح بالحفاظ على الوضعية.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Sled Push / Pull / دفع وسحب الزلاجة', 'Hip/Knee Extension in Gait / بسط الورك والركبة بنمط المشي', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('9a5cd794-1438-491c-a337-e77522d0f897', 'Farmer’s Walk', 'Functional / التمارين الوظيفية', '{"Forearms / الساعد","Core / البطن والكور","Back & Lats / الظهر واللاتس"}', 'Loaded Carry / حمل ومشي', 'قوة', NULL, 'مبتدئ', NULL, 'https://www.youtube.com/watch?v=hx24PM6gXs8', 'ملاحظات مهمة:
• قبضة قوية وكتفان للخلف، والجذع مستقيم.
• خطوات قصيرة ثابتة دون تمايل.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Farmer''s Walk / مشي المزارع', 'Isometric Trunk + Grip Under Load / تثبيت الجذع والقبضة أثناء المشي', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('8b24a99e-6e24-4f9e-87a7-813447504ae8', '90s Transition', 'Functional / التمارين الوظيفية', '{"Glutes / المؤخرة","Adductors / الأفخاذ الداخلية"}', 'Mobility / Stretch / إطالة ومرونة', 'مرونة', 'وزن الجسم', 'مبتدئ', 'بدون معدات', 'https://www.youtube.com/watch?v=ogU-azeGe_k', 'ملاحظات مهمة:
• حافظ على جذع مستقيم وتحرك ضمن مدى مريح.
• لا تتجاوز مدى يسبب ألماً في الركبة.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Hip Rotation Mobility (90/90) / مرونة دوران الورك', 'Hip Internal/External Rotation / دوران الورك الداخلي والخارجي', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('e74572d5-a402-4449-90d7-91533caa7864', 'Kettlebell Swing', 'Functional / التمارين الوظيفية', '{"Glutes / المؤخرة","Hamstrings / الخلفية","Core / البطن والكور"}', 'Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)', 'قدرة', 'كيتلبل', 'متوسط', 'منزل', 'https://www.youtube.com/watch?v=d94xX-AQZ0A', 'ملاحظات مهمة:
• ادفع من الورك بانفجار وليس برفع الذراعين.
• حافظ على ظهر محايد ولا تتجاوز وزناً تقدر عليه بتقنية سليمة.
• أبقِ الكيتلبل قريباً من الجسم وقبضة آمنة، ولا تتجاوز وزناً تتحكم فيه.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', 'نفس التمرين ورد أيضاً تحت التصنيف «CrossFit» (صف المصدر 168)', 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Ballistic Hinge (Swing) / مفصلة انفجارية (سوينق)', 'Hip Extension (Ballistic) / بسط الورك الانفجاري', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public.exercises VALUES ('ba1bd581-230b-4351-8553-a37f266743fd', 'Serratus Punches Supine', 'Functional / التمارين الوظيفية', '{"Shoulders / الأكتاف","Chest / الصدر"}', 'Horizontal Push / دفع أفقي', 'قوة', NULL, 'متوسط', NULL, 'https://youtu.be/cxaAqmdlrgk?si=2YRAIgFFXPAvDadG', 'ملاحظات مهمة:
• حرّك لوحي الكتف فقط والمرفقان مفرودان.
• لا تكن الحركة من الجذع أو الورك.
• اترك عدد التكرارات الاحتياطية التي كتبتها المدربة (RIR)، ولا تضحِّ بالتقنية لأجل الوزن. توقف عند ألم حاد أو غير معتاد، وراجع المدربة.', NULL, 'المكتبة الأصلية', NULL, NULL, NULL, 'approved', '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'Scapular Protraction / دفع لوح الكتف', 'Scapular Protraction / دفع لوح الكتف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;



INSERT INTO public.exercise_alternatives VALUES ('18368443-c491-4eb3-9c76-c405f0979823', 'c2c3767e-f41a-45c6-b7a1-25e55dcfce02', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('18368443-c491-4eb3-9c76-c405f0979823', 'ef3eb703-8cb1-4597-95e9-3ac4a93049b7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('18368443-c491-4eb3-9c76-c405f0979823', 'c5043fa2-8f4d-4e47-86be-18b641ad2c47', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('18368443-c491-4eb3-9c76-c405f0979823', '88c5c913-611d-47b7-95b6-45898d63fdcf', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('18368443-c491-4eb3-9c76-c405f0979823', 'fc616803-46dd-42e0-88d1-0309a93b5ba5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c2c3767e-f41a-45c6-b7a1-25e55dcfce02', '18368443-c491-4eb3-9c76-c405f0979823', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c2c3767e-f41a-45c6-b7a1-25e55dcfce02', 'ef3eb703-8cb1-4597-95e9-3ac4a93049b7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c2c3767e-f41a-45c6-b7a1-25e55dcfce02', 'c5043fa2-8f4d-4e47-86be-18b641ad2c47', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c2c3767e-f41a-45c6-b7a1-25e55dcfce02', '88c5c913-611d-47b7-95b6-45898d63fdcf', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c2c3767e-f41a-45c6-b7a1-25e55dcfce02', 'fc616803-46dd-42e0-88d1-0309a93b5ba5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8ddd7267-00b4-4796-95b1-1e6aca9437c1', '55728cd0-876b-4e00-972c-c727ba807a76', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8ddd7267-00b4-4796-95b1-1e6aca9437c1', '452e1e38-b5a2-4e4e-85c4-eff748bb0f9e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8ddd7267-00b4-4796-95b1-1e6aca9437c1', '18368443-c491-4eb3-9c76-c405f0979823', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8ddd7267-00b4-4796-95b1-1e6aca9437c1', 'c2c3767e-f41a-45c6-b7a1-25e55dcfce02', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8ddd7267-00b4-4796-95b1-1e6aca9437c1', '4966b0dc-b20e-4cc9-8452-83fb4f98b2bd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4966b0dc-b20e-4cc9-8452-83fb4f98b2bd', '1aea3c49-3990-405d-aa97-68dbe2dd7de2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4966b0dc-b20e-4cc9-8452-83fb4f98b2bd', '18368443-c491-4eb3-9c76-c405f0979823', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4966b0dc-b20e-4cc9-8452-83fb4f98b2bd', 'c2c3767e-f41a-45c6-b7a1-25e55dcfce02', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4966b0dc-b20e-4cc9-8452-83fb4f98b2bd', '8ddd7267-00b4-4796-95b1-1e6aca9437c1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4966b0dc-b20e-4cc9-8452-83fb4f98b2bd', 'ef3eb703-8cb1-4597-95e9-3ac4a93049b7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1aea3c49-3990-405d-aa97-68dbe2dd7de2', '4966b0dc-b20e-4cc9-8452-83fb4f98b2bd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1aea3c49-3990-405d-aa97-68dbe2dd7de2', '18368443-c491-4eb3-9c76-c405f0979823', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1aea3c49-3990-405d-aa97-68dbe2dd7de2', 'c2c3767e-f41a-45c6-b7a1-25e55dcfce02', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1aea3c49-3990-405d-aa97-68dbe2dd7de2', '8ddd7267-00b4-4796-95b1-1e6aca9437c1', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1aea3c49-3990-405d-aa97-68dbe2dd7de2', 'ef3eb703-8cb1-4597-95e9-3ac4a93049b7', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ef3eb703-8cb1-4597-95e9-3ac4a93049b7', '18368443-c491-4eb3-9c76-c405f0979823', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ef3eb703-8cb1-4597-95e9-3ac4a93049b7', 'c2c3767e-f41a-45c6-b7a1-25e55dcfce02', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ef3eb703-8cb1-4597-95e9-3ac4a93049b7', 'c5043fa2-8f4d-4e47-86be-18b641ad2c47', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ef3eb703-8cb1-4597-95e9-3ac4a93049b7', '88c5c913-611d-47b7-95b6-45898d63fdcf', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ef3eb703-8cb1-4597-95e9-3ac4a93049b7', 'fc616803-46dd-42e0-88d1-0309a93b5ba5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c5043fa2-8f4d-4e47-86be-18b641ad2c47', '18368443-c491-4eb3-9c76-c405f0979823', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c5043fa2-8f4d-4e47-86be-18b641ad2c47', 'c2c3767e-f41a-45c6-b7a1-25e55dcfce02', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c5043fa2-8f4d-4e47-86be-18b641ad2c47', 'ef3eb703-8cb1-4597-95e9-3ac4a93049b7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c5043fa2-8f4d-4e47-86be-18b641ad2c47', '88c5c913-611d-47b7-95b6-45898d63fdcf', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c5043fa2-8f4d-4e47-86be-18b641ad2c47', 'fc616803-46dd-42e0-88d1-0309a93b5ba5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('55728cd0-876b-4e00-972c-c727ba807a76', '8ddd7267-00b4-4796-95b1-1e6aca9437c1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('55728cd0-876b-4e00-972c-c727ba807a76', '452e1e38-b5a2-4e4e-85c4-eff748bb0f9e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('55728cd0-876b-4e00-972c-c727ba807a76', '18368443-c491-4eb3-9c76-c405f0979823', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('55728cd0-876b-4e00-972c-c727ba807a76', 'c2c3767e-f41a-45c6-b7a1-25e55dcfce02', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('55728cd0-876b-4e00-972c-c727ba807a76', '4966b0dc-b20e-4cc9-8452-83fb4f98b2bd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('88c5c913-611d-47b7-95b6-45898d63fdcf', '18368443-c491-4eb3-9c76-c405f0979823', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('88c5c913-611d-47b7-95b6-45898d63fdcf', 'c2c3767e-f41a-45c6-b7a1-25e55dcfce02', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('88c5c913-611d-47b7-95b6-45898d63fdcf', 'ef3eb703-8cb1-4597-95e9-3ac4a93049b7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('88c5c913-611d-47b7-95b6-45898d63fdcf', 'c5043fa2-8f4d-4e47-86be-18b641ad2c47', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('88c5c913-611d-47b7-95b6-45898d63fdcf', 'fc616803-46dd-42e0-88d1-0309a93b5ba5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('452e1e38-b5a2-4e4e-85c4-eff748bb0f9e', '8ddd7267-00b4-4796-95b1-1e6aca9437c1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('452e1e38-b5a2-4e4e-85c4-eff748bb0f9e', '55728cd0-876b-4e00-972c-c727ba807a76', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('452e1e38-b5a2-4e4e-85c4-eff748bb0f9e', '18368443-c491-4eb3-9c76-c405f0979823', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('452e1e38-b5a2-4e4e-85c4-eff748bb0f9e', 'c2c3767e-f41a-45c6-b7a1-25e55dcfce02', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('452e1e38-b5a2-4e4e-85c4-eff748bb0f9e', '4966b0dc-b20e-4cc9-8452-83fb4f98b2bd', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ffc9ccbf-85fe-4022-af22-676561ee5d47', '985adbc4-c8a8-4dba-9b13-2faee40aafc6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ffc9ccbf-85fe-4022-af22-676561ee5d47', '994033f8-952d-4447-bc43-31ec80b3acb5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ffc9ccbf-85fe-4022-af22-676561ee5d47', '89e96d6a-7438-4e63-9704-a2af03aef649', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ffc9ccbf-85fe-4022-af22-676561ee5d47', 'e3bd55bc-8db5-4dfb-894c-db52ce2e5475', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ffc9ccbf-85fe-4022-af22-676561ee5d47', 'd6cfa5b9-b20f-4f3e-867c-be5d3808741b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('985adbc4-c8a8-4dba-9b13-2faee40aafc6', '994033f8-952d-4447-bc43-31ec80b3acb5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('985adbc4-c8a8-4dba-9b13-2faee40aafc6', '89e96d6a-7438-4e63-9704-a2af03aef649', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('985adbc4-c8a8-4dba-9b13-2faee40aafc6', 'd6cfa5b9-b20f-4f3e-867c-be5d3808741b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('985adbc4-c8a8-4dba-9b13-2faee40aafc6', '4e95c4cc-9f5b-4784-ab19-d70137cc8201', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('985adbc4-c8a8-4dba-9b13-2faee40aafc6', 'ffc9ccbf-85fe-4022-af22-676561ee5d47', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('994033f8-952d-4447-bc43-31ec80b3acb5', '985adbc4-c8a8-4dba-9b13-2faee40aafc6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('994033f8-952d-4447-bc43-31ec80b3acb5', '89e96d6a-7438-4e63-9704-a2af03aef649', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('994033f8-952d-4447-bc43-31ec80b3acb5', 'd6cfa5b9-b20f-4f3e-867c-be5d3808741b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('994033f8-952d-4447-bc43-31ec80b3acb5', '4e95c4cc-9f5b-4784-ab19-d70137cc8201', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('994033f8-952d-4447-bc43-31ec80b3acb5', 'ffc9ccbf-85fe-4022-af22-676561ee5d47', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89e96d6a-7438-4e63-9704-a2af03aef649', '985adbc4-c8a8-4dba-9b13-2faee40aafc6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89e96d6a-7438-4e63-9704-a2af03aef649', '994033f8-952d-4447-bc43-31ec80b3acb5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89e96d6a-7438-4e63-9704-a2af03aef649', 'd6cfa5b9-b20f-4f3e-867c-be5d3808741b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89e96d6a-7438-4e63-9704-a2af03aef649', '4e95c4cc-9f5b-4784-ab19-d70137cc8201', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89e96d6a-7438-4e63-9704-a2af03aef649', 'ffc9ccbf-85fe-4022-af22-676561ee5d47', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3bd55bc-8db5-4dfb-894c-db52ce2e5475', 'ffc9ccbf-85fe-4022-af22-676561ee5d47', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3bd55bc-8db5-4dfb-894c-db52ce2e5475', '985adbc4-c8a8-4dba-9b13-2faee40aafc6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3bd55bc-8db5-4dfb-894c-db52ce2e5475', '994033f8-952d-4447-bc43-31ec80b3acb5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3bd55bc-8db5-4dfb-894c-db52ce2e5475', '89e96d6a-7438-4e63-9704-a2af03aef649', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3bd55bc-8db5-4dfb-894c-db52ce2e5475', 'd6cfa5b9-b20f-4f3e-867c-be5d3808741b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d6cfa5b9-b20f-4f3e-867c-be5d3808741b', '985adbc4-c8a8-4dba-9b13-2faee40aafc6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d6cfa5b9-b20f-4f3e-867c-be5d3808741b', '994033f8-952d-4447-bc43-31ec80b3acb5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d6cfa5b9-b20f-4f3e-867c-be5d3808741b', '89e96d6a-7438-4e63-9704-a2af03aef649', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d6cfa5b9-b20f-4f3e-867c-be5d3808741b', '4e95c4cc-9f5b-4784-ab19-d70137cc8201', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d6cfa5b9-b20f-4f3e-867c-be5d3808741b', 'ffc9ccbf-85fe-4022-af22-676561ee5d47', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4e95c4cc-9f5b-4784-ab19-d70137cc8201', '985adbc4-c8a8-4dba-9b13-2faee40aafc6', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4e95c4cc-9f5b-4784-ab19-d70137cc8201', '994033f8-952d-4447-bc43-31ec80b3acb5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4e95c4cc-9f5b-4784-ab19-d70137cc8201', '89e96d6a-7438-4e63-9704-a2af03aef649', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4e95c4cc-9f5b-4784-ab19-d70137cc8201', 'd6cfa5b9-b20f-4f3e-867c-be5d3808741b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4e95c4cc-9f5b-4784-ab19-d70137cc8201', 'ffc9ccbf-85fe-4022-af22-676561ee5d47', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5fb7469a-673b-42bc-baa9-7854adddbbd8', 'fcb2a4a2-c1c0-4a34-ad07-f21bb8ecd459', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5fb7469a-673b-42bc-baa9-7854adddbbd8', '915bc11b-5b58-4277-9324-0aa7d95b80bc', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5fb7469a-673b-42bc-baa9-7854adddbbd8', '9ac21553-f8de-47be-9837-e8100129fbe2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5fb7469a-673b-42bc-baa9-7854adddbbd8', 'eb9d22b5-deb2-4407-ba9c-b13f2dc8058b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5fb7469a-673b-42bc-baa9-7854adddbbd8', '9c6e3687-1d6f-49e8-90cb-f1ca5357a913', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fcb2a4a2-c1c0-4a34-ad07-f21bb8ecd459', '5fb7469a-673b-42bc-baa9-7854adddbbd8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fcb2a4a2-c1c0-4a34-ad07-f21bb8ecd459', '915bc11b-5b58-4277-9324-0aa7d95b80bc', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fcb2a4a2-c1c0-4a34-ad07-f21bb8ecd459', '9ac21553-f8de-47be-9837-e8100129fbe2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fcb2a4a2-c1c0-4a34-ad07-f21bb8ecd459', 'eb9d22b5-deb2-4407-ba9c-b13f2dc8058b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fcb2a4a2-c1c0-4a34-ad07-f21bb8ecd459', '9c6e3687-1d6f-49e8-90cb-f1ca5357a913', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('915bc11b-5b58-4277-9324-0aa7d95b80bc', '5fb7469a-673b-42bc-baa9-7854adddbbd8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('915bc11b-5b58-4277-9324-0aa7d95b80bc', 'fcb2a4a2-c1c0-4a34-ad07-f21bb8ecd459', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('915bc11b-5b58-4277-9324-0aa7d95b80bc', '9ac21553-f8de-47be-9837-e8100129fbe2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('915bc11b-5b58-4277-9324-0aa7d95b80bc', 'eb9d22b5-deb2-4407-ba9c-b13f2dc8058b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('915bc11b-5b58-4277-9324-0aa7d95b80bc', '9c6e3687-1d6f-49e8-90cb-f1ca5357a913', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9c6e3687-1d6f-49e8-90cb-f1ca5357a913', '5fb7469a-673b-42bc-baa9-7854adddbbd8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9c6e3687-1d6f-49e8-90cb-f1ca5357a913', 'fcb2a4a2-c1c0-4a34-ad07-f21bb8ecd459', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9c6e3687-1d6f-49e8-90cb-f1ca5357a913', '915bc11b-5b58-4277-9324-0aa7d95b80bc', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9c6e3687-1d6f-49e8-90cb-f1ca5357a913', '9ac21553-f8de-47be-9837-e8100129fbe2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9c6e3687-1d6f-49e8-90cb-f1ca5357a913', 'eb9d22b5-deb2-4407-ba9c-b13f2dc8058b', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ac21553-f8de-47be-9837-e8100129fbe2', '5fb7469a-673b-42bc-baa9-7854adddbbd8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ac21553-f8de-47be-9837-e8100129fbe2', 'fcb2a4a2-c1c0-4a34-ad07-f21bb8ecd459', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ac21553-f8de-47be-9837-e8100129fbe2', '915bc11b-5b58-4277-9324-0aa7d95b80bc', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ac21553-f8de-47be-9837-e8100129fbe2', 'eb9d22b5-deb2-4407-ba9c-b13f2dc8058b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9ac21553-f8de-47be-9837-e8100129fbe2', '9c6e3687-1d6f-49e8-90cb-f1ca5357a913', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb9d22b5-deb2-4407-ba9c-b13f2dc8058b', '5fb7469a-673b-42bc-baa9-7854adddbbd8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb9d22b5-deb2-4407-ba9c-b13f2dc8058b', 'fcb2a4a2-c1c0-4a34-ad07-f21bb8ecd459', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb9d22b5-deb2-4407-ba9c-b13f2dc8058b', '915bc11b-5b58-4277-9324-0aa7d95b80bc', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb9d22b5-deb2-4407-ba9c-b13f2dc8058b', '9ac21553-f8de-47be-9837-e8100129fbe2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb9d22b5-deb2-4407-ba9c-b13f2dc8058b', '9c6e3687-1d6f-49e8-90cb-f1ca5357a913', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc616803-46dd-42e0-88d1-0309a93b5ba5', '18368443-c491-4eb3-9c76-c405f0979823', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc616803-46dd-42e0-88d1-0309a93b5ba5', 'c2c3767e-f41a-45c6-b7a1-25e55dcfce02', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc616803-46dd-42e0-88d1-0309a93b5ba5', 'ef3eb703-8cb1-4597-95e9-3ac4a93049b7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc616803-46dd-42e0-88d1-0309a93b5ba5', 'c5043fa2-8f4d-4e47-86be-18b641ad2c47', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc616803-46dd-42e0-88d1-0309a93b5ba5', '88c5c913-611d-47b7-95b6-45898d63fdcf', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8cfd4124-5f05-4a7e-bdbc-561b3a13d2ac', 'ffc9ccbf-85fe-4022-af22-676561ee5d47', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8cfd4124-5f05-4a7e-bdbc-561b3a13d2ac', '985adbc4-c8a8-4dba-9b13-2faee40aafc6', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8cfd4124-5f05-4a7e-bdbc-561b3a13d2ac', '994033f8-952d-4447-bc43-31ec80b3acb5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8cfd4124-5f05-4a7e-bdbc-561b3a13d2ac', '89e96d6a-7438-4e63-9704-a2af03aef649', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8cfd4124-5f05-4a7e-bdbc-561b3a13d2ac', 'e3bd55bc-8db5-4dfb-894c-db52ce2e5475', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('71cde207-be4a-4b5a-a158-2154bee69fc0', '8e9853bf-80fb-4735-af70-84f5d35f521a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('71cde207-be4a-4b5a-a158-2154bee69fc0', 'cd97d05a-2090-455a-896b-5910d0d397ad', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('71cde207-be4a-4b5a-a158-2154bee69fc0', '78757c23-6489-43fa-84a0-42ee53349dcd', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8e9853bf-80fb-4735-af70-84f5d35f521a', '71cde207-be4a-4b5a-a158-2154bee69fc0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8e9853bf-80fb-4735-af70-84f5d35f521a', 'cd97d05a-2090-455a-896b-5910d0d397ad', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8e9853bf-80fb-4735-af70-84f5d35f521a', '78757c23-6489-43fa-84a0-42ee53349dcd', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd97d05a-2090-455a-896b-5910d0d397ad', '71cde207-be4a-4b5a-a158-2154bee69fc0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd97d05a-2090-455a-896b-5910d0d397ad', '8e9853bf-80fb-4735-af70-84f5d35f521a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cd97d05a-2090-455a-896b-5910d0d397ad', '78757c23-6489-43fa-84a0-42ee53349dcd', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('78757c23-6489-43fa-84a0-42ee53349dcd', '71cde207-be4a-4b5a-a158-2154bee69fc0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('78757c23-6489-43fa-84a0-42ee53349dcd', '8e9853bf-80fb-4735-af70-84f5d35f521a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('78757c23-6489-43fa-84a0-42ee53349dcd', 'cd97d05a-2090-455a-896b-5910d0d397ad', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7cc18d79-59d0-47d7-a044-5a5ca27c539a', 'a25bdcf5-1319-4adc-b51a-8dcfe809206e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7cc18d79-59d0-47d7-a044-5a5ca27c539a', '2e787fdb-20cc-404d-b02a-409521caf982', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7cc18d79-59d0-47d7-a044-5a5ca27c539a', 'a9809a70-8c1d-4c98-9f1d-221bce2408e2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7cc18d79-59d0-47d7-a044-5a5ca27c539a', '39d8345f-295b-4501-9571-74028c76e339', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7cc18d79-59d0-47d7-a044-5a5ca27c539a', '9f66a499-3b22-418d-b9a1-40ba022ba516', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bbf3b861-0622-41ec-9180-e0db7de7e597', 'c6de5636-833c-4360-97e0-16a5dd483c1d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bbf3b861-0622-41ec-9180-e0db7de7e597', '59126625-27f4-4db0-96e4-4525729faa37', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bbf3b861-0622-41ec-9180-e0db7de7e597', 'b3b15007-6569-4d42-889d-d42bf587a4ef', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bbf3b861-0622-41ec-9180-e0db7de7e597', '24003d2e-b3c7-4d9f-9594-39900e25ac82', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bbf3b861-0622-41ec-9180-e0db7de7e597', '2856d763-a287-4778-ae0e-2ce21cdcbef9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a25bdcf5-1319-4adc-b51a-8dcfe809206e', '7cc18d79-59d0-47d7-a044-5a5ca27c539a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a25bdcf5-1319-4adc-b51a-8dcfe809206e', '2e787fdb-20cc-404d-b02a-409521caf982', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a25bdcf5-1319-4adc-b51a-8dcfe809206e', 'a9809a70-8c1d-4c98-9f1d-221bce2408e2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a25bdcf5-1319-4adc-b51a-8dcfe809206e', '39d8345f-295b-4501-9571-74028c76e339', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a25bdcf5-1319-4adc-b51a-8dcfe809206e', '9f66a499-3b22-418d-b9a1-40ba022ba516', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('24003d2e-b3c7-4d9f-9594-39900e25ac82', 'bbf3b861-0622-41ec-9180-e0db7de7e597', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('24003d2e-b3c7-4d9f-9594-39900e25ac82', 'c6de5636-833c-4360-97e0-16a5dd483c1d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('24003d2e-b3c7-4d9f-9594-39900e25ac82', '59126625-27f4-4db0-96e4-4525729faa37', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('24003d2e-b3c7-4d9f-9594-39900e25ac82', 'b3b15007-6569-4d42-889d-d42bf587a4ef', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('24003d2e-b3c7-4d9f-9594-39900e25ac82', '2856d763-a287-4778-ae0e-2ce21cdcbef9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('903a9e33-bf48-46ad-bcd6-cf1df2d00834', '71cde207-be4a-4b5a-a158-2154bee69fc0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('903a9e33-bf48-46ad-bcd6-cf1df2d00834', '8e9853bf-80fb-4735-af70-84f5d35f521a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('903a9e33-bf48-46ad-bcd6-cf1df2d00834', 'cd97d05a-2090-455a-896b-5910d0d397ad', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('903a9e33-bf48-46ad-bcd6-cf1df2d00834', '78757c23-6489-43fa-84a0-42ee53349dcd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a9809a70-8c1d-4c98-9f1d-221bce2408e2', '39d8345f-295b-4501-9571-74028c76e339', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a9809a70-8c1d-4c98-9f1d-221bce2408e2', '9f66a499-3b22-418d-b9a1-40ba022ba516', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a9809a70-8c1d-4c98-9f1d-221bce2408e2', '677ab63e-2c76-4bf0-a0f6-e4731c733533', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a9809a70-8c1d-4c98-9f1d-221bce2408e2', '7ee4f100-8845-463c-a7ed-438b0b95fbfb', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a9809a70-8c1d-4c98-9f1d-221bce2408e2', '7cc18d79-59d0-47d7-a044-5a5ca27c539a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39d8345f-295b-4501-9571-74028c76e339', 'a9809a70-8c1d-4c98-9f1d-221bce2408e2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39d8345f-295b-4501-9571-74028c76e339', '9f66a499-3b22-418d-b9a1-40ba022ba516', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39d8345f-295b-4501-9571-74028c76e339', '677ab63e-2c76-4bf0-a0f6-e4731c733533', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39d8345f-295b-4501-9571-74028c76e339', '7ee4f100-8845-463c-a7ed-438b0b95fbfb', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('39d8345f-295b-4501-9571-74028c76e339', '7cc18d79-59d0-47d7-a044-5a5ca27c539a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9f66a499-3b22-418d-b9a1-40ba022ba516', 'a9809a70-8c1d-4c98-9f1d-221bce2408e2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9f66a499-3b22-418d-b9a1-40ba022ba516', '39d8345f-295b-4501-9571-74028c76e339', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9f66a499-3b22-418d-b9a1-40ba022ba516', '677ab63e-2c76-4bf0-a0f6-e4731c733533', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9f66a499-3b22-418d-b9a1-40ba022ba516', '7ee4f100-8845-463c-a7ed-438b0b95fbfb', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9f66a499-3b22-418d-b9a1-40ba022ba516', '7cc18d79-59d0-47d7-a044-5a5ca27c539a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('677ab63e-2c76-4bf0-a0f6-e4731c733533', 'a9809a70-8c1d-4c98-9f1d-221bce2408e2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('677ab63e-2c76-4bf0-a0f6-e4731c733533', '39d8345f-295b-4501-9571-74028c76e339', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('677ab63e-2c76-4bf0-a0f6-e4731c733533', '9f66a499-3b22-418d-b9a1-40ba022ba516', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('677ab63e-2c76-4bf0-a0f6-e4731c733533', '7ee4f100-8845-463c-a7ed-438b0b95fbfb', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('677ab63e-2c76-4bf0-a0f6-e4731c733533', '7cc18d79-59d0-47d7-a044-5a5ca27c539a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0a1f1673-1717-457f-bf8c-92567b5c2821', '7cc18d79-59d0-47d7-a044-5a5ca27c539a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0a1f1673-1717-457f-bf8c-92567b5c2821', 'a25bdcf5-1319-4adc-b51a-8dcfe809206e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0a1f1673-1717-457f-bf8c-92567b5c2821', 'a9809a70-8c1d-4c98-9f1d-221bce2408e2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0a1f1673-1717-457f-bf8c-92567b5c2821', '39d8345f-295b-4501-9571-74028c76e339', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0a1f1673-1717-457f-bf8c-92567b5c2821', '9f66a499-3b22-418d-b9a1-40ba022ba516', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7ee4f100-8845-463c-a7ed-438b0b95fbfb', 'a9809a70-8c1d-4c98-9f1d-221bce2408e2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7ee4f100-8845-463c-a7ed-438b0b95fbfb', '39d8345f-295b-4501-9571-74028c76e339', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7ee4f100-8845-463c-a7ed-438b0b95fbfb', '9f66a499-3b22-418d-b9a1-40ba022ba516', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7ee4f100-8845-463c-a7ed-438b0b95fbfb', '677ab63e-2c76-4bf0-a0f6-e4731c733533', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7ee4f100-8845-463c-a7ed-438b0b95fbfb', '7cc18d79-59d0-47d7-a044-5a5ca27c539a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2e787fdb-20cc-404d-b02a-409521caf982', '7cc18d79-59d0-47d7-a044-5a5ca27c539a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2e787fdb-20cc-404d-b02a-409521caf982', 'a25bdcf5-1319-4adc-b51a-8dcfe809206e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2e787fdb-20cc-404d-b02a-409521caf982', 'a9809a70-8c1d-4c98-9f1d-221bce2408e2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2e787fdb-20cc-404d-b02a-409521caf982', '39d8345f-295b-4501-9571-74028c76e339', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2e787fdb-20cc-404d-b02a-409521caf982', '9f66a499-3b22-418d-b9a1-40ba022ba516', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9e23165c-918b-4b1a-839b-b90eedfdcc16', '71cde207-be4a-4b5a-a158-2154bee69fc0', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9e23165c-918b-4b1a-839b-b90eedfdcc16', '8e9853bf-80fb-4735-af70-84f5d35f521a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9e23165c-918b-4b1a-839b-b90eedfdcc16', 'cd97d05a-2090-455a-896b-5910d0d397ad', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9e23165c-918b-4b1a-839b-b90eedfdcc16', '78757c23-6489-43fa-84a0-42ee53349dcd', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5b2e5875-ae26-4762-a9b9-f4cd12438795', '09e16888-4cee-4bb3-a4df-457603bd3c69', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5b2e5875-ae26-4762-a9b9-f4cd12438795', 'fe42790d-78f9-4726-9e0e-a24a4d6a43bb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5b2e5875-ae26-4762-a9b9-f4cd12438795', '1a30fc87-1455-4036-aabb-5f58eed615df', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5b2e5875-ae26-4762-a9b9-f4cd12438795', '120118ca-94ab-4915-a62c-9120528cddc9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5b2e5875-ae26-4762-a9b9-f4cd12438795', 'e3f33107-e350-46d8-89be-31db54be255c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aac6c048-f99b-41b5-8376-84dabffd5872', '09e16888-4cee-4bb3-a4df-457603bd3c69', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aac6c048-f99b-41b5-8376-84dabffd5872', 'fe42790d-78f9-4726-9e0e-a24a4d6a43bb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aac6c048-f99b-41b5-8376-84dabffd5872', '1a30fc87-1455-4036-aabb-5f58eed615df', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aac6c048-f99b-41b5-8376-84dabffd5872', '120118ca-94ab-4915-a62c-9120528cddc9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('aac6c048-f99b-41b5-8376-84dabffd5872', 'e3f33107-e350-46d8-89be-31db54be255c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('09e16888-4cee-4bb3-a4df-457603bd3c69', 'fe42790d-78f9-4726-9e0e-a24a4d6a43bb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('09e16888-4cee-4bb3-a4df-457603bd3c69', '1a30fc87-1455-4036-aabb-5f58eed615df', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('09e16888-4cee-4bb3-a4df-457603bd3c69', '120118ca-94ab-4915-a62c-9120528cddc9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('09e16888-4cee-4bb3-a4df-457603bd3c69', 'e3f33107-e350-46d8-89be-31db54be255c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('09e16888-4cee-4bb3-a4df-457603bd3c69', '3bb93d6c-4bf3-4eeb-9313-d5c346456513', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe42790d-78f9-4726-9e0e-a24a4d6a43bb', '09e16888-4cee-4bb3-a4df-457603bd3c69', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe42790d-78f9-4726-9e0e-a24a4d6a43bb', '1a30fc87-1455-4036-aabb-5f58eed615df', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe42790d-78f9-4726-9e0e-a24a4d6a43bb', '120118ca-94ab-4915-a62c-9120528cddc9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe42790d-78f9-4726-9e0e-a24a4d6a43bb', 'e3f33107-e350-46d8-89be-31db54be255c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fe42790d-78f9-4726-9e0e-a24a4d6a43bb', '3bb93d6c-4bf3-4eeb-9313-d5c346456513', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1a30fc87-1455-4036-aabb-5f58eed615df', '09e16888-4cee-4bb3-a4df-457603bd3c69', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1a30fc87-1455-4036-aabb-5f58eed615df', 'fe42790d-78f9-4726-9e0e-a24a4d6a43bb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1a30fc87-1455-4036-aabb-5f58eed615df', '120118ca-94ab-4915-a62c-9120528cddc9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1a30fc87-1455-4036-aabb-5f58eed615df', 'e3f33107-e350-46d8-89be-31db54be255c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1a30fc87-1455-4036-aabb-5f58eed615df', '3bb93d6c-4bf3-4eeb-9313-d5c346456513', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('120118ca-94ab-4915-a62c-9120528cddc9', '09e16888-4cee-4bb3-a4df-457603bd3c69', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('120118ca-94ab-4915-a62c-9120528cddc9', 'fe42790d-78f9-4726-9e0e-a24a4d6a43bb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('120118ca-94ab-4915-a62c-9120528cddc9', '1a30fc87-1455-4036-aabb-5f58eed615df', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('120118ca-94ab-4915-a62c-9120528cddc9', 'e3f33107-e350-46d8-89be-31db54be255c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('120118ca-94ab-4915-a62c-9120528cddc9', '3bb93d6c-4bf3-4eeb-9313-d5c346456513', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3f33107-e350-46d8-89be-31db54be255c', '09e16888-4cee-4bb3-a4df-457603bd3c69', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3f33107-e350-46d8-89be-31db54be255c', 'fe42790d-78f9-4726-9e0e-a24a4d6a43bb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3f33107-e350-46d8-89be-31db54be255c', '1a30fc87-1455-4036-aabb-5f58eed615df', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3f33107-e350-46d8-89be-31db54be255c', '120118ca-94ab-4915-a62c-9120528cddc9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e3f33107-e350-46d8-89be-31db54be255c', '3bb93d6c-4bf3-4eeb-9313-d5c346456513', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3bb93d6c-4bf3-4eeb-9313-d5c346456513', '09e16888-4cee-4bb3-a4df-457603bd3c69', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3bb93d6c-4bf3-4eeb-9313-d5c346456513', 'fe42790d-78f9-4726-9e0e-a24a4d6a43bb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3bb93d6c-4bf3-4eeb-9313-d5c346456513', '1a30fc87-1455-4036-aabb-5f58eed615df', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3bb93d6c-4bf3-4eeb-9313-d5c346456513', '120118ca-94ab-4915-a62c-9120528cddc9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3bb93d6c-4bf3-4eeb-9313-d5c346456513', 'e3f33107-e350-46d8-89be-31db54be255c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb3c1124-5096-4af5-bd43-cd1fbc5adf4b', '09e16888-4cee-4bb3-a4df-457603bd3c69', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb3c1124-5096-4af5-bd43-cd1fbc5adf4b', 'fe42790d-78f9-4726-9e0e-a24a4d6a43bb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb3c1124-5096-4af5-bd43-cd1fbc5adf4b', '1a30fc87-1455-4036-aabb-5f58eed615df', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb3c1124-5096-4af5-bd43-cd1fbc5adf4b', '120118ca-94ab-4915-a62c-9120528cddc9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('eb3c1124-5096-4af5-bd43-cd1fbc5adf4b', 'e3f33107-e350-46d8-89be-31db54be255c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3b783732-a934-4c79-9be2-1ca0e4a5438b', '5200941a-3b4e-40bf-8df9-9e793f62fa6f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3b783732-a934-4c79-9be2-1ca0e4a5438b', '08894260-98d8-40f4-8333-9685f10bc547', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3b783732-a934-4c79-9be2-1ca0e4a5438b', '6adb9f5d-49d1-4735-84e9-59946151e277', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3b783732-a934-4c79-9be2-1ca0e4a5438b', 'ea4c7b4f-e713-4971-ad4d-534299a59750', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3b783732-a934-4c79-9be2-1ca0e4a5438b', '7043733b-9a3d-4587-a346-9db4967f4a21', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5200941a-3b4e-40bf-8df9-9e793f62fa6f', '3b783732-a934-4c79-9be2-1ca0e4a5438b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5200941a-3b4e-40bf-8df9-9e793f62fa6f', '08894260-98d8-40f4-8333-9685f10bc547', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5200941a-3b4e-40bf-8df9-9e793f62fa6f', '6adb9f5d-49d1-4735-84e9-59946151e277', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5200941a-3b4e-40bf-8df9-9e793f62fa6f', 'ea4c7b4f-e713-4971-ad4d-534299a59750', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5200941a-3b4e-40bf-8df9-9e793f62fa6f', '7043733b-9a3d-4587-a346-9db4967f4a21', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('08894260-98d8-40f4-8333-9685f10bc547', '3b783732-a934-4c79-9be2-1ca0e4a5438b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('08894260-98d8-40f4-8333-9685f10bc547', '5200941a-3b4e-40bf-8df9-9e793f62fa6f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('08894260-98d8-40f4-8333-9685f10bc547', '6adb9f5d-49d1-4735-84e9-59946151e277', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('08894260-98d8-40f4-8333-9685f10bc547', 'ea4c7b4f-e713-4971-ad4d-534299a59750', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('08894260-98d8-40f4-8333-9685f10bc547', '7043733b-9a3d-4587-a346-9db4967f4a21', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6adb9f5d-49d1-4735-84e9-59946151e277', '3b783732-a934-4c79-9be2-1ca0e4a5438b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6adb9f5d-49d1-4735-84e9-59946151e277', '5200941a-3b4e-40bf-8df9-9e793f62fa6f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6adb9f5d-49d1-4735-84e9-59946151e277', '08894260-98d8-40f4-8333-9685f10bc547', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6adb9f5d-49d1-4735-84e9-59946151e277', 'ea4c7b4f-e713-4971-ad4d-534299a59750', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6adb9f5d-49d1-4735-84e9-59946151e277', '7043733b-9a3d-4587-a346-9db4967f4a21', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ea4c7b4f-e713-4971-ad4d-534299a59750', '3b783732-a934-4c79-9be2-1ca0e4a5438b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ea4c7b4f-e713-4971-ad4d-534299a59750', '5200941a-3b4e-40bf-8df9-9e793f62fa6f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ea4c7b4f-e713-4971-ad4d-534299a59750', '08894260-98d8-40f4-8333-9685f10bc547', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ea4c7b4f-e713-4971-ad4d-534299a59750', '6adb9f5d-49d1-4735-84e9-59946151e277', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ea4c7b4f-e713-4971-ad4d-534299a59750', '7043733b-9a3d-4587-a346-9db4967f4a21', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7043733b-9a3d-4587-a346-9db4967f4a21', '3b783732-a934-4c79-9be2-1ca0e4a5438b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7043733b-9a3d-4587-a346-9db4967f4a21', '5200941a-3b4e-40bf-8df9-9e793f62fa6f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7043733b-9a3d-4587-a346-9db4967f4a21', '08894260-98d8-40f4-8333-9685f10bc547', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7043733b-9a3d-4587-a346-9db4967f4a21', '6adb9f5d-49d1-4735-84e9-59946151e277', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7043733b-9a3d-4587-a346-9db4967f4a21', 'ea4c7b4f-e713-4971-ad4d-534299a59750', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce0546e6-f7e8-4bcc-b222-e970df2f421d', '3b783732-a934-4c79-9be2-1ca0e4a5438b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce0546e6-f7e8-4bcc-b222-e970df2f421d', '5200941a-3b4e-40bf-8df9-9e793f62fa6f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce0546e6-f7e8-4bcc-b222-e970df2f421d', '08894260-98d8-40f4-8333-9685f10bc547', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce0546e6-f7e8-4bcc-b222-e970df2f421d', '6adb9f5d-49d1-4735-84e9-59946151e277', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ce0546e6-f7e8-4bcc-b222-e970df2f421d', 'ea4c7b4f-e713-4971-ad4d-534299a59750', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3ea5f668-0f0f-4342-854b-83012e1e4230', '3b783732-a934-4c79-9be2-1ca0e4a5438b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3ea5f668-0f0f-4342-854b-83012e1e4230', '5200941a-3b4e-40bf-8df9-9e793f62fa6f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3ea5f668-0f0f-4342-854b-83012e1e4230', '08894260-98d8-40f4-8333-9685f10bc547', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3ea5f668-0f0f-4342-854b-83012e1e4230', '6adb9f5d-49d1-4735-84e9-59946151e277', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3ea5f668-0f0f-4342-854b-83012e1e4230', 'ea4c7b4f-e713-4971-ad4d-534299a59750', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('85a9f4ab-6fe4-449e-bf9d-c260db9455ba', '225cb8bd-3ce6-4dd9-9d9b-eff2d4565b9f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('85a9f4ab-6fe4-449e-bf9d-c260db9455ba', '3b783732-a934-4c79-9be2-1ca0e4a5438b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('85a9f4ab-6fe4-449e-bf9d-c260db9455ba', '5200941a-3b4e-40bf-8df9-9e793f62fa6f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('85a9f4ab-6fe4-449e-bf9d-c260db9455ba', '08894260-98d8-40f4-8333-9685f10bc547', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('85a9f4ab-6fe4-449e-bf9d-c260db9455ba', '6adb9f5d-49d1-4735-84e9-59946151e277', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3edaa29d-eedd-4d2b-a4e9-ffc98a062f06', '09e16888-4cee-4bb3-a4df-457603bd3c69', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3edaa29d-eedd-4d2b-a4e9-ffc98a062f06', 'fe42790d-78f9-4726-9e0e-a24a4d6a43bb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3edaa29d-eedd-4d2b-a4e9-ffc98a062f06', '1a30fc87-1455-4036-aabb-5f58eed615df', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3edaa29d-eedd-4d2b-a4e9-ffc98a062f06', '120118ca-94ab-4915-a62c-9120528cddc9', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3edaa29d-eedd-4d2b-a4e9-ffc98a062f06', 'e3f33107-e350-46d8-89be-31db54be255c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('225cb8bd-3ce6-4dd9-9d9b-eff2d4565b9f', '85a9f4ab-6fe4-449e-bf9d-c260db9455ba', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('225cb8bd-3ce6-4dd9-9d9b-eff2d4565b9f', '3b783732-a934-4c79-9be2-1ca0e4a5438b', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('225cb8bd-3ce6-4dd9-9d9b-eff2d4565b9f', '5200941a-3b4e-40bf-8df9-9e793f62fa6f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('225cb8bd-3ce6-4dd9-9d9b-eff2d4565b9f', '08894260-98d8-40f4-8333-9685f10bc547', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('225cb8bd-3ce6-4dd9-9d9b-eff2d4565b9f', '6adb9f5d-49d1-4735-84e9-59946151e277', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('82465684-1e29-4271-baf0-10a0f281aead', 'a777837f-eaa7-4f6e-ab0b-13789bc32dd2', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('82465684-1e29-4271-baf0-10a0f281aead', '1b049f63-42f4-459d-a78c-4edc23de430d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('82465684-1e29-4271-baf0-10a0f281aead', '7a1abf40-c1d4-4b0d-ab71-cb364cec806e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('82465684-1e29-4271-baf0-10a0f281aead', '34922616-74c4-40be-882b-9a5ab9e03345', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('82465684-1e29-4271-baf0-10a0f281aead', '186b94a2-c071-47fa-98a5-8ef3e479bfa1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a777837f-eaa7-4f6e-ab0b-13789bc32dd2', '82465684-1e29-4271-baf0-10a0f281aead', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a777837f-eaa7-4f6e-ab0b-13789bc32dd2', '1b049f63-42f4-459d-a78c-4edc23de430d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a777837f-eaa7-4f6e-ab0b-13789bc32dd2', '7a1abf40-c1d4-4b0d-ab71-cb364cec806e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a777837f-eaa7-4f6e-ab0b-13789bc32dd2', '34922616-74c4-40be-882b-9a5ab9e03345', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a777837f-eaa7-4f6e-ab0b-13789bc32dd2', '186b94a2-c071-47fa-98a5-8ef3e479bfa1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1b049f63-42f4-459d-a78c-4edc23de430d', '82465684-1e29-4271-baf0-10a0f281aead', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1b049f63-42f4-459d-a78c-4edc23de430d', 'a777837f-eaa7-4f6e-ab0b-13789bc32dd2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1b049f63-42f4-459d-a78c-4edc23de430d', '7a1abf40-c1d4-4b0d-ab71-cb364cec806e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1b049f63-42f4-459d-a78c-4edc23de430d', '34922616-74c4-40be-882b-9a5ab9e03345', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1b049f63-42f4-459d-a78c-4edc23de430d', '186b94a2-c071-47fa-98a5-8ef3e479bfa1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a1abf40-c1d4-4b0d-ab71-cb364cec806e', '82465684-1e29-4271-baf0-10a0f281aead', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a1abf40-c1d4-4b0d-ab71-cb364cec806e', 'a777837f-eaa7-4f6e-ab0b-13789bc32dd2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a1abf40-c1d4-4b0d-ab71-cb364cec806e', '1b049f63-42f4-459d-a78c-4edc23de430d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a1abf40-c1d4-4b0d-ab71-cb364cec806e', '34922616-74c4-40be-882b-9a5ab9e03345', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7a1abf40-c1d4-4b0d-ab71-cb364cec806e', '186b94a2-c071-47fa-98a5-8ef3e479bfa1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('34922616-74c4-40be-882b-9a5ab9e03345', '82465684-1e29-4271-baf0-10a0f281aead', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('34922616-74c4-40be-882b-9a5ab9e03345', 'a777837f-eaa7-4f6e-ab0b-13789bc32dd2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('34922616-74c4-40be-882b-9a5ab9e03345', '1b049f63-42f4-459d-a78c-4edc23de430d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('34922616-74c4-40be-882b-9a5ab9e03345', '7a1abf40-c1d4-4b0d-ab71-cb364cec806e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('34922616-74c4-40be-882b-9a5ab9e03345', '186b94a2-c071-47fa-98a5-8ef3e479bfa1', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8ecf3b9b-82b4-4e26-ab7a-7d196aef3524', '82465684-1e29-4271-baf0-10a0f281aead', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8ecf3b9b-82b4-4e26-ab7a-7d196aef3524', 'a777837f-eaa7-4f6e-ab0b-13789bc32dd2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8ecf3b9b-82b4-4e26-ab7a-7d196aef3524', '1b049f63-42f4-459d-a78c-4edc23de430d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8ecf3b9b-82b4-4e26-ab7a-7d196aef3524', '7a1abf40-c1d4-4b0d-ab71-cb364cec806e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8ecf3b9b-82b4-4e26-ab7a-7d196aef3524', '34922616-74c4-40be-882b-9a5ab9e03345', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('186b94a2-c071-47fa-98a5-8ef3e479bfa1', '82465684-1e29-4271-baf0-10a0f281aead', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('186b94a2-c071-47fa-98a5-8ef3e479bfa1', 'a777837f-eaa7-4f6e-ab0b-13789bc32dd2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('186b94a2-c071-47fa-98a5-8ef3e479bfa1', '1b049f63-42f4-459d-a78c-4edc23de430d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('186b94a2-c071-47fa-98a5-8ef3e479bfa1', '7a1abf40-c1d4-4b0d-ab71-cb364cec806e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('186b94a2-c071-47fa-98a5-8ef3e479bfa1', '34922616-74c4-40be-882b-9a5ab9e03345', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0fbc9de1-9329-41fe-bae3-1355660ebbd8', '82465684-1e29-4271-baf0-10a0f281aead', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0fbc9de1-9329-41fe-bae3-1355660ebbd8', 'a777837f-eaa7-4f6e-ab0b-13789bc32dd2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0fbc9de1-9329-41fe-bae3-1355660ebbd8', '1b049f63-42f4-459d-a78c-4edc23de430d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0fbc9de1-9329-41fe-bae3-1355660ebbd8', '7a1abf40-c1d4-4b0d-ab71-cb364cec806e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0fbc9de1-9329-41fe-bae3-1355660ebbd8', '34922616-74c4-40be-882b-9a5ab9e03345', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6618a027-17e2-45d3-948e-9be7b71a955f', '82465684-1e29-4271-baf0-10a0f281aead', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6618a027-17e2-45d3-948e-9be7b71a955f', 'a777837f-eaa7-4f6e-ab0b-13789bc32dd2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6618a027-17e2-45d3-948e-9be7b71a955f', '1b049f63-42f4-459d-a78c-4edc23de430d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6618a027-17e2-45d3-948e-9be7b71a955f', '7a1abf40-c1d4-4b0d-ab71-cb364cec806e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6618a027-17e2-45d3-948e-9be7b71a955f', '34922616-74c4-40be-882b-9a5ab9e03345', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a9b85785-8c7f-4104-b5e5-15b0bb825abc', '98e7e303-392d-4d78-ad41-3a403a4e58b7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a9b85785-8c7f-4104-b5e5-15b0bb825abc', '70ed4590-e8e9-4959-8c6d-84cdea52b9d8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a9b85785-8c7f-4104-b5e5-15b0bb825abc', '82465684-1e29-4271-baf0-10a0f281aead', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a9b85785-8c7f-4104-b5e5-15b0bb825abc', 'a777837f-eaa7-4f6e-ab0b-13789bc32dd2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a9b85785-8c7f-4104-b5e5-15b0bb825abc', '1b049f63-42f4-459d-a78c-4edc23de430d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('98e7e303-392d-4d78-ad41-3a403a4e58b7', 'a9b85785-8c7f-4104-b5e5-15b0bb825abc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('98e7e303-392d-4d78-ad41-3a403a4e58b7', '70ed4590-e8e9-4959-8c6d-84cdea52b9d8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('98e7e303-392d-4d78-ad41-3a403a4e58b7', '82465684-1e29-4271-baf0-10a0f281aead', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('98e7e303-392d-4d78-ad41-3a403a4e58b7', 'a777837f-eaa7-4f6e-ab0b-13789bc32dd2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('98e7e303-392d-4d78-ad41-3a403a4e58b7', '1b049f63-42f4-459d-a78c-4edc23de430d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('70ed4590-e8e9-4959-8c6d-84cdea52b9d8', 'a9b85785-8c7f-4104-b5e5-15b0bb825abc', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('70ed4590-e8e9-4959-8c6d-84cdea52b9d8', '98e7e303-392d-4d78-ad41-3a403a4e58b7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('70ed4590-e8e9-4959-8c6d-84cdea52b9d8', '82465684-1e29-4271-baf0-10a0f281aead', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('70ed4590-e8e9-4959-8c6d-84cdea52b9d8', 'a777837f-eaa7-4f6e-ab0b-13789bc32dd2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('70ed4590-e8e9-4959-8c6d-84cdea52b9d8', '1b049f63-42f4-459d-a78c-4edc23de430d', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1288e862-ff80-4872-82d9-5af42b2a5c65', '82465684-1e29-4271-baf0-10a0f281aead', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1288e862-ff80-4872-82d9-5af42b2a5c65', 'a777837f-eaa7-4f6e-ab0b-13789bc32dd2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1288e862-ff80-4872-82d9-5af42b2a5c65', '1b049f63-42f4-459d-a78c-4edc23de430d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1288e862-ff80-4872-82d9-5af42b2a5c65', '7a1abf40-c1d4-4b0d-ab71-cb364cec806e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1288e862-ff80-4872-82d9-5af42b2a5c65', '34922616-74c4-40be-882b-9a5ab9e03345', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d54646de-140a-446b-af7e-fd9c6e98c588', 'f30becf2-8e03-4202-9c68-7f749de8d105', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d54646de-140a-446b-af7e-fd9c6e98c588', '82465684-1e29-4271-baf0-10a0f281aead', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d54646de-140a-446b-af7e-fd9c6e98c588', 'a777837f-eaa7-4f6e-ab0b-13789bc32dd2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('398f657b-9bec-4cac-b3ef-5005ce953f27', '82465684-1e29-4271-baf0-10a0f281aead', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('398f657b-9bec-4cac-b3ef-5005ce953f27', 'a777837f-eaa7-4f6e-ab0b-13789bc32dd2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('398f657b-9bec-4cac-b3ef-5005ce953f27', '1b049f63-42f4-459d-a78c-4edc23de430d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('398f657b-9bec-4cac-b3ef-5005ce953f27', '7a1abf40-c1d4-4b0d-ab71-cb364cec806e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('398f657b-9bec-4cac-b3ef-5005ce953f27', '34922616-74c4-40be-882b-9a5ab9e03345', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f30becf2-8e03-4202-9c68-7f749de8d105', 'd54646de-140a-446b-af7e-fd9c6e98c588', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f30becf2-8e03-4202-9c68-7f749de8d105', '82465684-1e29-4271-baf0-10a0f281aead', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f30becf2-8e03-4202-9c68-7f749de8d105', 'a777837f-eaa7-4f6e-ab0b-13789bc32dd2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('35ba2997-2e18-4fd1-8670-84f95736c745', '82465684-1e29-4271-baf0-10a0f281aead', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('35ba2997-2e18-4fd1-8670-84f95736c745', 'a777837f-eaa7-4f6e-ab0b-13789bc32dd2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('35ba2997-2e18-4fd1-8670-84f95736c745', '1b049f63-42f4-459d-a78c-4edc23de430d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('35ba2997-2e18-4fd1-8670-84f95736c745', '7a1abf40-c1d4-4b0d-ab71-cb364cec806e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('35ba2997-2e18-4fd1-8670-84f95736c745', '34922616-74c4-40be-882b-9a5ab9e03345', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('609d7a93-71ef-4386-b63b-fba09cfd78d7', '82465684-1e29-4271-baf0-10a0f281aead', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('609d7a93-71ef-4386-b63b-fba09cfd78d7', 'a777837f-eaa7-4f6e-ab0b-13789bc32dd2', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('609d7a93-71ef-4386-b63b-fba09cfd78d7', '1b049f63-42f4-459d-a78c-4edc23de430d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('609d7a93-71ef-4386-b63b-fba09cfd78d7', '7a1abf40-c1d4-4b0d-ab71-cb364cec806e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('609d7a93-71ef-4386-b63b-fba09cfd78d7', '34922616-74c4-40be-882b-9a5ab9e03345', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9fe8a880-21bd-4847-a90d-2e636385119b', 'bfa93a90-2721-49f9-881a-5ffb31c0cc79', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9fe8a880-21bd-4847-a90d-2e636385119b', 'ec960d28-d044-406c-8c97-2cccff7902db', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9fe8a880-21bd-4847-a90d-2e636385119b', '8da26da0-6107-41a1-9c46-76c96c3300e7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9fe8a880-21bd-4847-a90d-2e636385119b', '5a1479df-3088-4330-a644-3d9cb139b19c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9fe8a880-21bd-4847-a90d-2e636385119b', '48f24e9c-f7c3-4806-b5f4-e65441098dca', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bfa93a90-2721-49f9-881a-5ffb31c0cc79', '9fe8a880-21bd-4847-a90d-2e636385119b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bfa93a90-2721-49f9-881a-5ffb31c0cc79', 'ec960d28-d044-406c-8c97-2cccff7902db', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bfa93a90-2721-49f9-881a-5ffb31c0cc79', '8da26da0-6107-41a1-9c46-76c96c3300e7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bfa93a90-2721-49f9-881a-5ffb31c0cc79', '5a1479df-3088-4330-a644-3d9cb139b19c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('bfa93a90-2721-49f9-881a-5ffb31c0cc79', '48f24e9c-f7c3-4806-b5f4-e65441098dca', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ec960d28-d044-406c-8c97-2cccff7902db', '9fe8a880-21bd-4847-a90d-2e636385119b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ec960d28-d044-406c-8c97-2cccff7902db', 'bfa93a90-2721-49f9-881a-5ffb31c0cc79', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ec960d28-d044-406c-8c97-2cccff7902db', '8da26da0-6107-41a1-9c46-76c96c3300e7', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ec960d28-d044-406c-8c97-2cccff7902db', '5a1479df-3088-4330-a644-3d9cb139b19c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ec960d28-d044-406c-8c97-2cccff7902db', '48f24e9c-f7c3-4806-b5f4-e65441098dca', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8da26da0-6107-41a1-9c46-76c96c3300e7', '5a1479df-3088-4330-a644-3d9cb139b19c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8da26da0-6107-41a1-9c46-76c96c3300e7', '48f24e9c-f7c3-4806-b5f4-e65441098dca', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8da26da0-6107-41a1-9c46-76c96c3300e7', '8d08ec77-f347-4969-8dab-f3f75b129ce2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8da26da0-6107-41a1-9c46-76c96c3300e7', 'cc912fda-c2c9-40b7-94aa-cef1b00c8cbb', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8da26da0-6107-41a1-9c46-76c96c3300e7', '6bfffecb-1da8-446c-a757-c1a705356c47', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('483f9428-be07-4b18-81e6-6ac3ca541f19', '9a7c3ffc-3f62-41c9-98da-66db9dc4eea8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('483f9428-be07-4b18-81e6-6ac3ca541f19', 'ec7ac55c-0da3-4bc3-b749-6d51a33bccae', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('483f9428-be07-4b18-81e6-6ac3ca541f19', '75661d4e-af51-4249-a721-b3f30dfc85cb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5a1479df-3088-4330-a644-3d9cb139b19c', '8da26da0-6107-41a1-9c46-76c96c3300e7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5a1479df-3088-4330-a644-3d9cb139b19c', '48f24e9c-f7c3-4806-b5f4-e65441098dca', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5a1479df-3088-4330-a644-3d9cb139b19c', '8d08ec77-f347-4969-8dab-f3f75b129ce2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5a1479df-3088-4330-a644-3d9cb139b19c', 'cc912fda-c2c9-40b7-94aa-cef1b00c8cbb', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5a1479df-3088-4330-a644-3d9cb139b19c', '6bfffecb-1da8-446c-a757-c1a705356c47', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('48f24e9c-f7c3-4806-b5f4-e65441098dca', '8da26da0-6107-41a1-9c46-76c96c3300e7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('48f24e9c-f7c3-4806-b5f4-e65441098dca', '5a1479df-3088-4330-a644-3d9cb139b19c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('48f24e9c-f7c3-4806-b5f4-e65441098dca', '8d08ec77-f347-4969-8dab-f3f75b129ce2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('48f24e9c-f7c3-4806-b5f4-e65441098dca', 'cc912fda-c2c9-40b7-94aa-cef1b00c8cbb', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('48f24e9c-f7c3-4806-b5f4-e65441098dca', '6bfffecb-1da8-446c-a757-c1a705356c47', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d08ec77-f347-4969-8dab-f3f75b129ce2', '8da26da0-6107-41a1-9c46-76c96c3300e7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d08ec77-f347-4969-8dab-f3f75b129ce2', '5a1479df-3088-4330-a644-3d9cb139b19c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d08ec77-f347-4969-8dab-f3f75b129ce2', '48f24e9c-f7c3-4806-b5f4-e65441098dca', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d08ec77-f347-4969-8dab-f3f75b129ce2', 'cc912fda-c2c9-40b7-94aa-cef1b00c8cbb', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d08ec77-f347-4969-8dab-f3f75b129ce2', '6bfffecb-1da8-446c-a757-c1a705356c47', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cc912fda-c2c9-40b7-94aa-cef1b00c8cbb', '8da26da0-6107-41a1-9c46-76c96c3300e7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cc912fda-c2c9-40b7-94aa-cef1b00c8cbb', '5a1479df-3088-4330-a644-3d9cb139b19c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cc912fda-c2c9-40b7-94aa-cef1b00c8cbb', '48f24e9c-f7c3-4806-b5f4-e65441098dca', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cc912fda-c2c9-40b7-94aa-cef1b00c8cbb', '8d08ec77-f347-4969-8dab-f3f75b129ce2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cc912fda-c2c9-40b7-94aa-cef1b00c8cbb', '6bfffecb-1da8-446c-a757-c1a705356c47', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6bfffecb-1da8-446c-a757-c1a705356c47', '8da26da0-6107-41a1-9c46-76c96c3300e7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6bfffecb-1da8-446c-a757-c1a705356c47', '5a1479df-3088-4330-a644-3d9cb139b19c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6bfffecb-1da8-446c-a757-c1a705356c47', '48f24e9c-f7c3-4806-b5f4-e65441098dca', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6bfffecb-1da8-446c-a757-c1a705356c47', '8d08ec77-f347-4969-8dab-f3f75b129ce2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6bfffecb-1da8-446c-a757-c1a705356c47', 'cc912fda-c2c9-40b7-94aa-cef1b00c8cbb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('11731a7a-aeaf-4b80-9d6e-333bbda92732', '8da26da0-6107-41a1-9c46-76c96c3300e7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('11731a7a-aeaf-4b80-9d6e-333bbda92732', '5a1479df-3088-4330-a644-3d9cb139b19c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('11731a7a-aeaf-4b80-9d6e-333bbda92732', '48f24e9c-f7c3-4806-b5f4-e65441098dca', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('11731a7a-aeaf-4b80-9d6e-333bbda92732', '8d08ec77-f347-4969-8dab-f3f75b129ce2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('11731a7a-aeaf-4b80-9d6e-333bbda92732', 'cc912fda-c2c9-40b7-94aa-cef1b00c8cbb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2ba56edc-e215-4a95-a4b3-996f8b91aadd', '8da26da0-6107-41a1-9c46-76c96c3300e7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2ba56edc-e215-4a95-a4b3-996f8b91aadd', '5a1479df-3088-4330-a644-3d9cb139b19c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2ba56edc-e215-4a95-a4b3-996f8b91aadd', '48f24e9c-f7c3-4806-b5f4-e65441098dca', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2ba56edc-e215-4a95-a4b3-996f8b91aadd', '8d08ec77-f347-4969-8dab-f3f75b129ce2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2ba56edc-e215-4a95-a4b3-996f8b91aadd', 'cc912fda-c2c9-40b7-94aa-cef1b00c8cbb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('00faaa8b-e0fd-4aed-8a32-23b15f5f2b2d', '8da26da0-6107-41a1-9c46-76c96c3300e7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('00faaa8b-e0fd-4aed-8a32-23b15f5f2b2d', '5a1479df-3088-4330-a644-3d9cb139b19c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('00faaa8b-e0fd-4aed-8a32-23b15f5f2b2d', '48f24e9c-f7c3-4806-b5f4-e65441098dca', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('00faaa8b-e0fd-4aed-8a32-23b15f5f2b2d', '8d08ec77-f347-4969-8dab-f3f75b129ce2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('00faaa8b-e0fd-4aed-8a32-23b15f5f2b2d', 'cc912fda-c2c9-40b7-94aa-cef1b00c8cbb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5271b8a3-62a9-4a36-af81-601b5af94fd6', '8da26da0-6107-41a1-9c46-76c96c3300e7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5271b8a3-62a9-4a36-af81-601b5af94fd6', '5a1479df-3088-4330-a644-3d9cb139b19c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5271b8a3-62a9-4a36-af81-601b5af94fd6', '48f24e9c-f7c3-4806-b5f4-e65441098dca', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5271b8a3-62a9-4a36-af81-601b5af94fd6', '8d08ec77-f347-4969-8dab-f3f75b129ce2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5271b8a3-62a9-4a36-af81-601b5af94fd6', 'cc912fda-c2c9-40b7-94aa-cef1b00c8cbb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3b98a3d3-9025-4bf3-9874-ecc9ed27e94d', '9fe8a880-21bd-4847-a90d-2e636385119b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3b98a3d3-9025-4bf3-9874-ecc9ed27e94d', 'bfa93a90-2721-49f9-881a-5ffb31c0cc79', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3b98a3d3-9025-4bf3-9874-ecc9ed27e94d', 'ec960d28-d044-406c-8c97-2cccff7902db', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3b98a3d3-9025-4bf3-9874-ecc9ed27e94d', '8da26da0-6107-41a1-9c46-76c96c3300e7', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3b98a3d3-9025-4bf3-9874-ecc9ed27e94d', '5a1479df-3088-4330-a644-3d9cb139b19c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e76edb03-4da1-4ca6-a822-fcba35256a4a', '359c6b11-a9df-4a7c-b676-1f9d8e74ff89', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e76edb03-4da1-4ca6-a822-fcba35256a4a', '0279b6a7-c05d-4669-87bd-e2de67f447f5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e76edb03-4da1-4ca6-a822-fcba35256a4a', '6ecb1df8-c6d9-4c41-aff1-f2af3f81c407', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e76edb03-4da1-4ca6-a822-fcba35256a4a', 'd668cb04-51df-4f95-a468-07d9066b8722', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e76edb03-4da1-4ca6-a822-fcba35256a4a', 'a4281140-68e8-4b8f-9a63-a0f2fadf64ea', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('359c6b11-a9df-4a7c-b676-1f9d8e74ff89', 'e76edb03-4da1-4ca6-a822-fcba35256a4a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('359c6b11-a9df-4a7c-b676-1f9d8e74ff89', '0279b6a7-c05d-4669-87bd-e2de67f447f5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('359c6b11-a9df-4a7c-b676-1f9d8e74ff89', '6ecb1df8-c6d9-4c41-aff1-f2af3f81c407', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('359c6b11-a9df-4a7c-b676-1f9d8e74ff89', 'd668cb04-51df-4f95-a468-07d9066b8722', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('359c6b11-a9df-4a7c-b676-1f9d8e74ff89', 'a4281140-68e8-4b8f-9a63-a0f2fadf64ea', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3da48b5c-46c3-4a85-99ea-f51340dd56e9', '359c6b11-a9df-4a7c-b676-1f9d8e74ff89', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3da48b5c-46c3-4a85-99ea-f51340dd56e9', 'e76edb03-4da1-4ca6-a822-fcba35256a4a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3da48b5c-46c3-4a85-99ea-f51340dd56e9', '0279b6a7-c05d-4669-87bd-e2de67f447f5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3da48b5c-46c3-4a85-99ea-f51340dd56e9', '6ecb1df8-c6d9-4c41-aff1-f2af3f81c407', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3da48b5c-46c3-4a85-99ea-f51340dd56e9', 'd668cb04-51df-4f95-a468-07d9066b8722', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0279b6a7-c05d-4669-87bd-e2de67f447f5', '864bfef1-a01f-4f55-8ec6-bf9a48c99c69', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0279b6a7-c05d-4669-87bd-e2de67f447f5', '70e38129-3814-4f52-9487-0e24ab782764', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0279b6a7-c05d-4669-87bd-e2de67f447f5', 'fc23e310-a48c-418c-bd13-ee3b08f6046f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0279b6a7-c05d-4669-87bd-e2de67f447f5', 'e76edb03-4da1-4ca6-a822-fcba35256a4a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0279b6a7-c05d-4669-87bd-e2de67f447f5', '359c6b11-a9df-4a7c-b676-1f9d8e74ff89', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6ecb1df8-c6d9-4c41-aff1-f2af3f81c407', 'd668cb04-51df-4f95-a468-07d9066b8722', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6ecb1df8-c6d9-4c41-aff1-f2af3f81c407', 'a4281140-68e8-4b8f-9a63-a0f2fadf64ea', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6ecb1df8-c6d9-4c41-aff1-f2af3f81c407', '56dadba9-4982-4804-ae2f-8d332d25a90a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6ecb1df8-c6d9-4c41-aff1-f2af3f81c407', '4f981a19-0d42-4c36-bb80-4e267c949f00', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6ecb1df8-c6d9-4c41-aff1-f2af3f81c407', 'e76edb03-4da1-4ca6-a822-fcba35256a4a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d668cb04-51df-4f95-a468-07d9066b8722', '6ecb1df8-c6d9-4c41-aff1-f2af3f81c407', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d668cb04-51df-4f95-a468-07d9066b8722', 'a4281140-68e8-4b8f-9a63-a0f2fadf64ea', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d668cb04-51df-4f95-a468-07d9066b8722', '56dadba9-4982-4804-ae2f-8d332d25a90a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d668cb04-51df-4f95-a468-07d9066b8722', '4f981a19-0d42-4c36-bb80-4e267c949f00', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d668cb04-51df-4f95-a468-07d9066b8722', 'e76edb03-4da1-4ca6-a822-fcba35256a4a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a4281140-68e8-4b8f-9a63-a0f2fadf64ea', '6ecb1df8-c6d9-4c41-aff1-f2af3f81c407', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a4281140-68e8-4b8f-9a63-a0f2fadf64ea', 'd668cb04-51df-4f95-a468-07d9066b8722', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a4281140-68e8-4b8f-9a63-a0f2fadf64ea', '56dadba9-4982-4804-ae2f-8d332d25a90a', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a4281140-68e8-4b8f-9a63-a0f2fadf64ea', '4f981a19-0d42-4c36-bb80-4e267c949f00', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a4281140-68e8-4b8f-9a63-a0f2fadf64ea', 'e76edb03-4da1-4ca6-a822-fcba35256a4a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('864bfef1-a01f-4f55-8ec6-bf9a48c99c69', '0279b6a7-c05d-4669-87bd-e2de67f447f5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('864bfef1-a01f-4f55-8ec6-bf9a48c99c69', '70e38129-3814-4f52-9487-0e24ab782764', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('864bfef1-a01f-4f55-8ec6-bf9a48c99c69', 'fc23e310-a48c-418c-bd13-ee3b08f6046f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('864bfef1-a01f-4f55-8ec6-bf9a48c99c69', 'e76edb03-4da1-4ca6-a822-fcba35256a4a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('864bfef1-a01f-4f55-8ec6-bf9a48c99c69', '359c6b11-a9df-4a7c-b676-1f9d8e74ff89', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('70e38129-3814-4f52-9487-0e24ab782764', '0279b6a7-c05d-4669-87bd-e2de67f447f5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('70e38129-3814-4f52-9487-0e24ab782764', '864bfef1-a01f-4f55-8ec6-bf9a48c99c69', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('70e38129-3814-4f52-9487-0e24ab782764', 'fc23e310-a48c-418c-bd13-ee3b08f6046f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('70e38129-3814-4f52-9487-0e24ab782764', 'e76edb03-4da1-4ca6-a822-fcba35256a4a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('70e38129-3814-4f52-9487-0e24ab782764', '359c6b11-a9df-4a7c-b676-1f9d8e74ff89', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('56dadba9-4982-4804-ae2f-8d332d25a90a', '6ecb1df8-c6d9-4c41-aff1-f2af3f81c407', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('56dadba9-4982-4804-ae2f-8d332d25a90a', 'd668cb04-51df-4f95-a468-07d9066b8722', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('56dadba9-4982-4804-ae2f-8d332d25a90a', 'a4281140-68e8-4b8f-9a63-a0f2fadf64ea', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('56dadba9-4982-4804-ae2f-8d332d25a90a', '4f981a19-0d42-4c36-bb80-4e267c949f00', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('56dadba9-4982-4804-ae2f-8d332d25a90a', 'e76edb03-4da1-4ca6-a822-fcba35256a4a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4f981a19-0d42-4c36-bb80-4e267c949f00', '6ecb1df8-c6d9-4c41-aff1-f2af3f81c407', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4f981a19-0d42-4c36-bb80-4e267c949f00', 'd668cb04-51df-4f95-a468-07d9066b8722', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4f981a19-0d42-4c36-bb80-4e267c949f00', 'a4281140-68e8-4b8f-9a63-a0f2fadf64ea', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4f981a19-0d42-4c36-bb80-4e267c949f00', '56dadba9-4982-4804-ae2f-8d332d25a90a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4f981a19-0d42-4c36-bb80-4e267c949f00', 'e76edb03-4da1-4ca6-a822-fcba35256a4a', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc23e310-a48c-418c-bd13-ee3b08f6046f', '0279b6a7-c05d-4669-87bd-e2de67f447f5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc23e310-a48c-418c-bd13-ee3b08f6046f', '864bfef1-a01f-4f55-8ec6-bf9a48c99c69', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc23e310-a48c-418c-bd13-ee3b08f6046f', '70e38129-3814-4f52-9487-0e24ab782764', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc23e310-a48c-418c-bd13-ee3b08f6046f', 'e76edb03-4da1-4ca6-a822-fcba35256a4a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fc23e310-a48c-418c-bd13-ee3b08f6046f', '359c6b11-a9df-4a7c-b676-1f9d8e74ff89', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f18361e8-27b6-425a-b853-f54bfdea3526', '8da26da0-6107-41a1-9c46-76c96c3300e7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f18361e8-27b6-425a-b853-f54bfdea3526', '5a1479df-3088-4330-a644-3d9cb139b19c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f18361e8-27b6-425a-b853-f54bfdea3526', '48f24e9c-f7c3-4806-b5f4-e65441098dca', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f18361e8-27b6-425a-b853-f54bfdea3526', '8d08ec77-f347-4969-8dab-f3f75b129ce2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f18361e8-27b6-425a-b853-f54bfdea3526', 'cc912fda-c2c9-40b7-94aa-cef1b00c8cbb', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e4aff8d6-8d01-45a8-a1f1-7db1d294096e', '9fe8a880-21bd-4847-a90d-2e636385119b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e4aff8d6-8d01-45a8-a1f1-7db1d294096e', 'bfa93a90-2721-49f9-881a-5ffb31c0cc79', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e4aff8d6-8d01-45a8-a1f1-7db1d294096e', 'ec960d28-d044-406c-8c97-2cccff7902db', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ec7ac55c-0da3-4bc3-b749-6d51a33bccae', '75661d4e-af51-4249-a721-b3f30dfc85cb', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ec7ac55c-0da3-4bc3-b749-6d51a33bccae', 'fabbe74c-b888-48b7-962e-199bf44f3289', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ec7ac55c-0da3-4bc3-b749-6d51a33bccae', '9f54f714-1da0-425f-95b5-899d04bd3de9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75661d4e-af51-4249-a721-b3f30dfc85cb', 'ec7ac55c-0da3-4bc3-b749-6d51a33bccae', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75661d4e-af51-4249-a721-b3f30dfc85cb', 'fabbe74c-b888-48b7-962e-199bf44f3289', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('75661d4e-af51-4249-a721-b3f30dfc85cb', '9f54f714-1da0-425f-95b5-899d04bd3de9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fabbe74c-b888-48b7-962e-199bf44f3289', 'ec7ac55c-0da3-4bc3-b749-6d51a33bccae', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fabbe74c-b888-48b7-962e-199bf44f3289', '75661d4e-af51-4249-a721-b3f30dfc85cb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('fabbe74c-b888-48b7-962e-199bf44f3289', '9f54f714-1da0-425f-95b5-899d04bd3de9', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9f54f714-1da0-425f-95b5-899d04bd3de9', 'ec7ac55c-0da3-4bc3-b749-6d51a33bccae', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9f54f714-1da0-425f-95b5-899d04bd3de9', '75661d4e-af51-4249-a721-b3f30dfc85cb', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9f54f714-1da0-425f-95b5-899d04bd3de9', 'fabbe74c-b888-48b7-962e-199bf44f3289', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('516ab4a6-b6c7-4302-9e62-6b7bb50cef72', 'edffa6e1-4041-496e-9df5-939e5a2baaec', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('516ab4a6-b6c7-4302-9e62-6b7bb50cef72', '2a8ff943-6323-41d8-b26c-6a3fd69e5a04', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('516ab4a6-b6c7-4302-9e62-6b7bb50cef72', '1c42ee8a-1d4d-4401-a7fc-0d02d7380dd2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('516ab4a6-b6c7-4302-9e62-6b7bb50cef72', 'f986162d-e099-4860-8ab2-6e7a38172d09', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('516ab4a6-b6c7-4302-9e62-6b7bb50cef72', 'a658f3f8-b649-49bc-900a-ce64d62e6b71', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('edffa6e1-4041-496e-9df5-939e5a2baaec', '516ab4a6-b6c7-4302-9e62-6b7bb50cef72', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('edffa6e1-4041-496e-9df5-939e5a2baaec', '2a8ff943-6323-41d8-b26c-6a3fd69e5a04', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('edffa6e1-4041-496e-9df5-939e5a2baaec', '1c42ee8a-1d4d-4401-a7fc-0d02d7380dd2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('edffa6e1-4041-496e-9df5-939e5a2baaec', 'f986162d-e099-4860-8ab2-6e7a38172d09', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('edffa6e1-4041-496e-9df5-939e5a2baaec', 'a658f3f8-b649-49bc-900a-ce64d62e6b71', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2a8ff943-6323-41d8-b26c-6a3fd69e5a04', '516ab4a6-b6c7-4302-9e62-6b7bb50cef72', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2a8ff943-6323-41d8-b26c-6a3fd69e5a04', 'edffa6e1-4041-496e-9df5-939e5a2baaec', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2a8ff943-6323-41d8-b26c-6a3fd69e5a04', '1c42ee8a-1d4d-4401-a7fc-0d02d7380dd2', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2a8ff943-6323-41d8-b26c-6a3fd69e5a04', 'f986162d-e099-4860-8ab2-6e7a38172d09', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2a8ff943-6323-41d8-b26c-6a3fd69e5a04', 'a658f3f8-b649-49bc-900a-ce64d62e6b71', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1c42ee8a-1d4d-4401-a7fc-0d02d7380dd2', '516ab4a6-b6c7-4302-9e62-6b7bb50cef72', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1c42ee8a-1d4d-4401-a7fc-0d02d7380dd2', 'edffa6e1-4041-496e-9df5-939e5a2baaec', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1c42ee8a-1d4d-4401-a7fc-0d02d7380dd2', '2a8ff943-6323-41d8-b26c-6a3fd69e5a04', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1c42ee8a-1d4d-4401-a7fc-0d02d7380dd2', 'f986162d-e099-4860-8ab2-6e7a38172d09', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1c42ee8a-1d4d-4401-a7fc-0d02d7380dd2', 'a658f3f8-b649-49bc-900a-ce64d62e6b71', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c8b60f9d-9dde-4b81-ad3a-f43fadda6189', 'd423db2c-76c3-488b-8400-eac6a9e7a13b', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c8b60f9d-9dde-4b81-ad3a-f43fadda6189', '516ab4a6-b6c7-4302-9e62-6b7bb50cef72', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c8b60f9d-9dde-4b81-ad3a-f43fadda6189', 'edffa6e1-4041-496e-9df5-939e5a2baaec', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c8b60f9d-9dde-4b81-ad3a-f43fadda6189', '2a8ff943-6323-41d8-b26c-6a3fd69e5a04', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c8b60f9d-9dde-4b81-ad3a-f43fadda6189', '1c42ee8a-1d4d-4401-a7fc-0d02d7380dd2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d423db2c-76c3-488b-8400-eac6a9e7a13b', 'c8b60f9d-9dde-4b81-ad3a-f43fadda6189', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d423db2c-76c3-488b-8400-eac6a9e7a13b', '516ab4a6-b6c7-4302-9e62-6b7bb50cef72', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d423db2c-76c3-488b-8400-eac6a9e7a13b', 'edffa6e1-4041-496e-9df5-939e5a2baaec', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d423db2c-76c3-488b-8400-eac6a9e7a13b', '2a8ff943-6323-41d8-b26c-6a3fd69e5a04', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d423db2c-76c3-488b-8400-eac6a9e7a13b', '1c42ee8a-1d4d-4401-a7fc-0d02d7380dd2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f986162d-e099-4860-8ab2-6e7a38172d09', '516ab4a6-b6c7-4302-9e62-6b7bb50cef72', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f986162d-e099-4860-8ab2-6e7a38172d09', 'edffa6e1-4041-496e-9df5-939e5a2baaec', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f986162d-e099-4860-8ab2-6e7a38172d09', '2a8ff943-6323-41d8-b26c-6a3fd69e5a04', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f986162d-e099-4860-8ab2-6e7a38172d09', '1c42ee8a-1d4d-4401-a7fc-0d02d7380dd2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f986162d-e099-4860-8ab2-6e7a38172d09', 'a658f3f8-b649-49bc-900a-ce64d62e6b71', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a658f3f8-b649-49bc-900a-ce64d62e6b71', '516ab4a6-b6c7-4302-9e62-6b7bb50cef72', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a658f3f8-b649-49bc-900a-ce64d62e6b71', 'edffa6e1-4041-496e-9df5-939e5a2baaec', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a658f3f8-b649-49bc-900a-ce64d62e6b71', '2a8ff943-6323-41d8-b26c-6a3fd69e5a04', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a658f3f8-b649-49bc-900a-ce64d62e6b71', '1c42ee8a-1d4d-4401-a7fc-0d02d7380dd2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a658f3f8-b649-49bc-900a-ce64d62e6b71', 'f986162d-e099-4860-8ab2-6e7a38172d09', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ef067648-4e99-463d-bba0-b7aee6f6a59b', '483f9428-be07-4b18-81e6-6ac3ca541f19', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ef067648-4e99-463d-bba0-b7aee6f6a59b', 'ec7ac55c-0da3-4bc3-b749-6d51a33bccae', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ef067648-4e99-463d-bba0-b7aee6f6a59b', '75661d4e-af51-4249-a721-b3f30dfc85cb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b2557e4-13e6-4c68-8695-8440472e9422', '516ab4a6-b6c7-4302-9e62-6b7bb50cef72', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b2557e4-13e6-4c68-8695-8440472e9422', 'edffa6e1-4041-496e-9df5-939e5a2baaec', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b2557e4-13e6-4c68-8695-8440472e9422', '2a8ff943-6323-41d8-b26c-6a3fd69e5a04', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b2557e4-13e6-4c68-8695-8440472e9422', '1c42ee8a-1d4d-4401-a7fc-0d02d7380dd2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b2557e4-13e6-4c68-8695-8440472e9422', 'c8b60f9d-9dde-4b81-ad3a-f43fadda6189', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9a7c3ffc-3f62-41c9-98da-66db9dc4eea8', '483f9428-be07-4b18-81e6-6ac3ca541f19', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9a7c3ffc-3f62-41c9-98da-66db9dc4eea8', 'ec7ac55c-0da3-4bc3-b749-6d51a33bccae', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9a7c3ffc-3f62-41c9-98da-66db9dc4eea8', '75661d4e-af51-4249-a721-b3f30dfc85cb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('be114bb8-7dee-4500-87ca-2d5ff8ed1cd7', '392eac94-9221-4c89-b21b-9816d5ebc048', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('be114bb8-7dee-4500-87ca-2d5ff8ed1cd7', '16ebd49f-e9c8-4325-aa04-290ba761de39', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('be114bb8-7dee-4500-87ca-2d5ff8ed1cd7', '415044e2-e51a-4b30-b260-3453f8d7ce25', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('be114bb8-7dee-4500-87ca-2d5ff8ed1cd7', '9be11638-547c-4319-92fb-19db7cb857f2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('be114bb8-7dee-4500-87ca-2d5ff8ed1cd7', '6b7d289c-7622-475d-a9a0-22245ed0d3af', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ed9f329f-417b-436c-af09-91e7b451ada3', 'a64ad054-3283-465b-9253-291a6c9e60d5', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ed9f329f-417b-436c-af09-91e7b451ada3', 'be114bb8-7dee-4500-87ca-2d5ff8ed1cd7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ed9f329f-417b-436c-af09-91e7b451ada3', '392eac94-9221-4c89-b21b-9816d5ebc048', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ed9f329f-417b-436c-af09-91e7b451ada3', '16ebd49f-e9c8-4325-aa04-290ba761de39', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ed9f329f-417b-436c-af09-91e7b451ada3', '415044e2-e51a-4b30-b260-3453f8d7ce25', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('392eac94-9221-4c89-b21b-9816d5ebc048', 'be114bb8-7dee-4500-87ca-2d5ff8ed1cd7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('392eac94-9221-4c89-b21b-9816d5ebc048', '16ebd49f-e9c8-4325-aa04-290ba761de39', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('392eac94-9221-4c89-b21b-9816d5ebc048', '415044e2-e51a-4b30-b260-3453f8d7ce25', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('392eac94-9221-4c89-b21b-9816d5ebc048', '9be11638-547c-4319-92fb-19db7cb857f2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('392eac94-9221-4c89-b21b-9816d5ebc048', '6b7d289c-7622-475d-a9a0-22245ed0d3af', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16ebd49f-e9c8-4325-aa04-290ba761de39', 'be114bb8-7dee-4500-87ca-2d5ff8ed1cd7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16ebd49f-e9c8-4325-aa04-290ba761de39', '392eac94-9221-4c89-b21b-9816d5ebc048', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16ebd49f-e9c8-4325-aa04-290ba761de39', '415044e2-e51a-4b30-b260-3453f8d7ce25', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16ebd49f-e9c8-4325-aa04-290ba761de39', '9be11638-547c-4319-92fb-19db7cb857f2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16ebd49f-e9c8-4325-aa04-290ba761de39', '6b7d289c-7622-475d-a9a0-22245ed0d3af', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('415044e2-e51a-4b30-b260-3453f8d7ce25', 'be114bb8-7dee-4500-87ca-2d5ff8ed1cd7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('415044e2-e51a-4b30-b260-3453f8d7ce25', '392eac94-9221-4c89-b21b-9816d5ebc048', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('415044e2-e51a-4b30-b260-3453f8d7ce25', '16ebd49f-e9c8-4325-aa04-290ba761de39', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('415044e2-e51a-4b30-b260-3453f8d7ce25', '9be11638-547c-4319-92fb-19db7cb857f2', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('415044e2-e51a-4b30-b260-3453f8d7ce25', '6b7d289c-7622-475d-a9a0-22245ed0d3af', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9be11638-547c-4319-92fb-19db7cb857f2', 'be114bb8-7dee-4500-87ca-2d5ff8ed1cd7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9be11638-547c-4319-92fb-19db7cb857f2', '392eac94-9221-4c89-b21b-9816d5ebc048', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9be11638-547c-4319-92fb-19db7cb857f2', '16ebd49f-e9c8-4325-aa04-290ba761de39', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9be11638-547c-4319-92fb-19db7cb857f2', '415044e2-e51a-4b30-b260-3453f8d7ce25', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9be11638-547c-4319-92fb-19db7cb857f2', '6b7d289c-7622-475d-a9a0-22245ed0d3af', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6b7d289c-7622-475d-a9a0-22245ed0d3af', 'be114bb8-7dee-4500-87ca-2d5ff8ed1cd7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6b7d289c-7622-475d-a9a0-22245ed0d3af', '392eac94-9221-4c89-b21b-9816d5ebc048', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6b7d289c-7622-475d-a9a0-22245ed0d3af', '16ebd49f-e9c8-4325-aa04-290ba761de39', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6b7d289c-7622-475d-a9a0-22245ed0d3af', '415044e2-e51a-4b30-b260-3453f8d7ce25', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6b7d289c-7622-475d-a9a0-22245ed0d3af', '9be11638-547c-4319-92fb-19db7cb857f2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a955214b-3166-4a82-aa41-f2f23cab1f73', '766e7102-7d18-4c7f-b556-f20a4d82b38c', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a955214b-3166-4a82-aa41-f2f23cab1f73', 'be114bb8-7dee-4500-87ca-2d5ff8ed1cd7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a955214b-3166-4a82-aa41-f2f23cab1f73', 'ed9f329f-417b-436c-af09-91e7b451ada3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a955214b-3166-4a82-aa41-f2f23cab1f73', '392eac94-9221-4c89-b21b-9816d5ebc048', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a955214b-3166-4a82-aa41-f2f23cab1f73', '16ebd49f-e9c8-4325-aa04-290ba761de39', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('766e7102-7d18-4c7f-b556-f20a4d82b38c', 'a955214b-3166-4a82-aa41-f2f23cab1f73', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('766e7102-7d18-4c7f-b556-f20a4d82b38c', 'be114bb8-7dee-4500-87ca-2d5ff8ed1cd7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('766e7102-7d18-4c7f-b556-f20a4d82b38c', 'ed9f329f-417b-436c-af09-91e7b451ada3', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('766e7102-7d18-4c7f-b556-f20a4d82b38c', '392eac94-9221-4c89-b21b-9816d5ebc048', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('766e7102-7d18-4c7f-b556-f20a4d82b38c', '16ebd49f-e9c8-4325-aa04-290ba761de39', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19b46b68-10b5-42b3-90be-7bc48081df26', 'be114bb8-7dee-4500-87ca-2d5ff8ed1cd7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19b46b68-10b5-42b3-90be-7bc48081df26', '392eac94-9221-4c89-b21b-9816d5ebc048', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19b46b68-10b5-42b3-90be-7bc48081df26', '16ebd49f-e9c8-4325-aa04-290ba761de39', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19b46b68-10b5-42b3-90be-7bc48081df26', '415044e2-e51a-4b30-b260-3453f8d7ce25', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19b46b68-10b5-42b3-90be-7bc48081df26', '9be11638-547c-4319-92fb-19db7cb857f2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b2142e44-b3c3-4648-aeb7-7950f35cedcf', 'be114bb8-7dee-4500-87ca-2d5ff8ed1cd7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b2142e44-b3c3-4648-aeb7-7950f35cedcf', '392eac94-9221-4c89-b21b-9816d5ebc048', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b2142e44-b3c3-4648-aeb7-7950f35cedcf', '16ebd49f-e9c8-4325-aa04-290ba761de39', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b2142e44-b3c3-4648-aeb7-7950f35cedcf', '415044e2-e51a-4b30-b260-3453f8d7ce25', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b2142e44-b3c3-4648-aeb7-7950f35cedcf', '9be11638-547c-4319-92fb-19db7cb857f2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a64ad054-3283-465b-9253-291a6c9e60d5', 'ed9f329f-417b-436c-af09-91e7b451ada3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a64ad054-3283-465b-9253-291a6c9e60d5', 'be114bb8-7dee-4500-87ca-2d5ff8ed1cd7', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a64ad054-3283-465b-9253-291a6c9e60d5', '392eac94-9221-4c89-b21b-9816d5ebc048', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a64ad054-3283-465b-9253-291a6c9e60d5', '16ebd49f-e9c8-4325-aa04-290ba761de39', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a64ad054-3283-465b-9253-291a6c9e60d5', '415044e2-e51a-4b30-b260-3453f8d7ce25', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5d5433b6-cc11-4c7a-8fe5-5ed5d2c43184', 'be114bb8-7dee-4500-87ca-2d5ff8ed1cd7', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5d5433b6-cc11-4c7a-8fe5-5ed5d2c43184', '392eac94-9221-4c89-b21b-9816d5ebc048', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5d5433b6-cc11-4c7a-8fe5-5ed5d2c43184', '16ebd49f-e9c8-4325-aa04-290ba761de39', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5d5433b6-cc11-4c7a-8fe5-5ed5d2c43184', '415044e2-e51a-4b30-b260-3453f8d7ce25', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5d5433b6-cc11-4c7a-8fe5-5ed5d2c43184', '9be11638-547c-4319-92fb-19db7cb857f2', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('80ac915b-8e37-4347-b74d-0d56eeed0a2a', '398fa57d-fe4d-41ff-8d05-725e4c915644', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('80ac915b-8e37-4347-b74d-0d56eeed0a2a', '3d822a1b-427e-4770-9769-ceeb47f57782', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('80ac915b-8e37-4347-b74d-0d56eeed0a2a', 'd46236ed-652b-469d-a5a5-9ce75753c570', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('80ac915b-8e37-4347-b74d-0d56eeed0a2a', 'a41e2a76-111a-4946-9589-9b95c587497f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('80ac915b-8e37-4347-b74d-0d56eeed0a2a', '69b4a718-c836-4dee-ae4e-88721090b80e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d822a1b-427e-4770-9769-ceeb47f57782', '80ac915b-8e37-4347-b74d-0d56eeed0a2a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d822a1b-427e-4770-9769-ceeb47f57782', 'd46236ed-652b-469d-a5a5-9ce75753c570', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d822a1b-427e-4770-9769-ceeb47f57782', 'a41e2a76-111a-4946-9589-9b95c587497f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d822a1b-427e-4770-9769-ceeb47f57782', '69b4a718-c836-4dee-ae4e-88721090b80e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3d822a1b-427e-4770-9769-ceeb47f57782', 'cbc8519a-18f7-401e-8284-c11e66f76ba5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d46236ed-652b-469d-a5a5-9ce75753c570', '80ac915b-8e37-4347-b74d-0d56eeed0a2a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d46236ed-652b-469d-a5a5-9ce75753c570', '3d822a1b-427e-4770-9769-ceeb47f57782', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d46236ed-652b-469d-a5a5-9ce75753c570', 'a41e2a76-111a-4946-9589-9b95c587497f', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d46236ed-652b-469d-a5a5-9ce75753c570', '69b4a718-c836-4dee-ae4e-88721090b80e', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d46236ed-652b-469d-a5a5-9ce75753c570', 'cbc8519a-18f7-401e-8284-c11e66f76ba5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a41e2a76-111a-4946-9589-9b95c587497f', '69b4a718-c836-4dee-ae4e-88721090b80e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a41e2a76-111a-4946-9589-9b95c587497f', 'cbc8519a-18f7-401e-8284-c11e66f76ba5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a41e2a76-111a-4946-9589-9b95c587497f', '74f33b86-0d40-4c4d-9091-34ac4451f53b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a41e2a76-111a-4946-9589-9b95c587497f', '80ac915b-8e37-4347-b74d-0d56eeed0a2a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a41e2a76-111a-4946-9589-9b95c587497f', '3d822a1b-427e-4770-9769-ceeb47f57782', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('69b4a718-c836-4dee-ae4e-88721090b80e', 'a41e2a76-111a-4946-9589-9b95c587497f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('69b4a718-c836-4dee-ae4e-88721090b80e', 'cbc8519a-18f7-401e-8284-c11e66f76ba5', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('69b4a718-c836-4dee-ae4e-88721090b80e', '74f33b86-0d40-4c4d-9091-34ac4451f53b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('69b4a718-c836-4dee-ae4e-88721090b80e', '80ac915b-8e37-4347-b74d-0d56eeed0a2a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('69b4a718-c836-4dee-ae4e-88721090b80e', '3d822a1b-427e-4770-9769-ceeb47f57782', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cbc8519a-18f7-401e-8284-c11e66f76ba5', 'a41e2a76-111a-4946-9589-9b95c587497f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cbc8519a-18f7-401e-8284-c11e66f76ba5', '69b4a718-c836-4dee-ae4e-88721090b80e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cbc8519a-18f7-401e-8284-c11e66f76ba5', '74f33b86-0d40-4c4d-9091-34ac4451f53b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cbc8519a-18f7-401e-8284-c11e66f76ba5', '80ac915b-8e37-4347-b74d-0d56eeed0a2a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cbc8519a-18f7-401e-8284-c11e66f76ba5', '3d822a1b-427e-4770-9769-ceeb47f57782', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('74f33b86-0d40-4c4d-9091-34ac4451f53b', 'a41e2a76-111a-4946-9589-9b95c587497f', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('74f33b86-0d40-4c4d-9091-34ac4451f53b', '69b4a718-c836-4dee-ae4e-88721090b80e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('74f33b86-0d40-4c4d-9091-34ac4451f53b', 'cbc8519a-18f7-401e-8284-c11e66f76ba5', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('74f33b86-0d40-4c4d-9091-34ac4451f53b', '80ac915b-8e37-4347-b74d-0d56eeed0a2a', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('74f33b86-0d40-4c4d-9091-34ac4451f53b', '3d822a1b-427e-4770-9769-ceeb47f57782', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('398fa57d-fe4d-41ff-8d05-725e4c915644', '80ac915b-8e37-4347-b74d-0d56eeed0a2a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('398fa57d-fe4d-41ff-8d05-725e4c915644', '3d822a1b-427e-4770-9769-ceeb47f57782', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('398fa57d-fe4d-41ff-8d05-725e4c915644', 'd46236ed-652b-469d-a5a5-9ce75753c570', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('398fa57d-fe4d-41ff-8d05-725e4c915644', 'a41e2a76-111a-4946-9589-9b95c587497f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('398fa57d-fe4d-41ff-8d05-725e4c915644', '69b4a718-c836-4dee-ae4e-88721090b80e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('203581d3-1189-430b-a8ee-31eb6e845b45', '80ac915b-8e37-4347-b74d-0d56eeed0a2a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('203581d3-1189-430b-a8ee-31eb6e845b45', '3d822a1b-427e-4770-9769-ceeb47f57782', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('203581d3-1189-430b-a8ee-31eb6e845b45', 'd46236ed-652b-469d-a5a5-9ce75753c570', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16e03046-a8df-4136-9309-b5f9e1b3f02f', '80ac915b-8e37-4347-b74d-0d56eeed0a2a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16e03046-a8df-4136-9309-b5f9e1b3f02f', '3d822a1b-427e-4770-9769-ceeb47f57782', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16e03046-a8df-4136-9309-b5f9e1b3f02f', 'd46236ed-652b-469d-a5a5-9ce75753c570', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16e03046-a8df-4136-9309-b5f9e1b3f02f', 'a41e2a76-111a-4946-9589-9b95c587497f', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('16e03046-a8df-4136-9309-b5f9e1b3f02f', '69b4a718-c836-4dee-ae4e-88721090b80e', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e8f36187-38ca-4f7f-a8f2-112c7a96dbaf', '7da5aeb0-6856-4cec-b7fb-145598a12e89', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e8f36187-38ca-4f7f-a8f2-112c7a96dbaf', 'f5240e82-ae6d-4243-a04c-9d2de3d2ed1c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e8f36187-38ca-4f7f-a8f2-112c7a96dbaf', 'a7782ff9-42df-41ab-9dfa-676554488e5b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e8f36187-38ca-4f7f-a8f2-112c7a96dbaf', '10259de7-32cf-4ee8-baeb-8f31c65b19cf', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e8f36187-38ca-4f7f-a8f2-112c7a96dbaf', '4b9e3f17-3a25-4ccd-a5be-837366041264', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('715fb635-5d30-4b20-ab62-2b863bcca46a', 'e8f36187-38ca-4f7f-a8f2-112c7a96dbaf', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('715fb635-5d30-4b20-ab62-2b863bcca46a', '7da5aeb0-6856-4cec-b7fb-145598a12e89', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('715fb635-5d30-4b20-ab62-2b863bcca46a', 'f5240e82-ae6d-4243-a04c-9d2de3d2ed1c', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('715fb635-5d30-4b20-ab62-2b863bcca46a', 'a7782ff9-42df-41ab-9dfa-676554488e5b', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('715fb635-5d30-4b20-ab62-2b863bcca46a', '10259de7-32cf-4ee8-baeb-8f31c65b19cf', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7da5aeb0-6856-4cec-b7fb-145598a12e89', 'e8f36187-38ca-4f7f-a8f2-112c7a96dbaf', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7da5aeb0-6856-4cec-b7fb-145598a12e89', 'f5240e82-ae6d-4243-a04c-9d2de3d2ed1c', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7da5aeb0-6856-4cec-b7fb-145598a12e89', 'a7782ff9-42df-41ab-9dfa-676554488e5b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7da5aeb0-6856-4cec-b7fb-145598a12e89', '10259de7-32cf-4ee8-baeb-8f31c65b19cf', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7da5aeb0-6856-4cec-b7fb-145598a12e89', '4b9e3f17-3a25-4ccd-a5be-837366041264', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a7782ff9-42df-41ab-9dfa-676554488e5b', 'e8f36187-38ca-4f7f-a8f2-112c7a96dbaf', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a7782ff9-42df-41ab-9dfa-676554488e5b', '7da5aeb0-6856-4cec-b7fb-145598a12e89', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a7782ff9-42df-41ab-9dfa-676554488e5b', '10259de7-32cf-4ee8-baeb-8f31c65b19cf', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a7782ff9-42df-41ab-9dfa-676554488e5b', 'f5240e82-ae6d-4243-a04c-9d2de3d2ed1c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a7782ff9-42df-41ab-9dfa-676554488e5b', '4b9e3f17-3a25-4ccd-a5be-837366041264', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('10259de7-32cf-4ee8-baeb-8f31c65b19cf', 'e8f36187-38ca-4f7f-a8f2-112c7a96dbaf', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('10259de7-32cf-4ee8-baeb-8f31c65b19cf', '7da5aeb0-6856-4cec-b7fb-145598a12e89', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('10259de7-32cf-4ee8-baeb-8f31c65b19cf', 'a7782ff9-42df-41ab-9dfa-676554488e5b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('10259de7-32cf-4ee8-baeb-8f31c65b19cf', 'f5240e82-ae6d-4243-a04c-9d2de3d2ed1c', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('10259de7-32cf-4ee8-baeb-8f31c65b19cf', '4b9e3f17-3a25-4ccd-a5be-837366041264', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('df9fd7cc-c694-40ca-bc1c-486f5f0539af', 'e8f36187-38ca-4f7f-a8f2-112c7a96dbaf', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('df9fd7cc-c694-40ca-bc1c-486f5f0539af', '7da5aeb0-6856-4cec-b7fb-145598a12e89', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('df9fd7cc-c694-40ca-bc1c-486f5f0539af', 'a7782ff9-42df-41ab-9dfa-676554488e5b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7316dbed-1e2a-4507-b282-5f9d0f902bcf', 'e8f36187-38ca-4f7f-a8f2-112c7a96dbaf', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7316dbed-1e2a-4507-b282-5f9d0f902bcf', '7da5aeb0-6856-4cec-b7fb-145598a12e89', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7316dbed-1e2a-4507-b282-5f9d0f902bcf', 'a7782ff9-42df-41ab-9dfa-676554488e5b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a395c7a-6bce-421b-9808-9678987f7289', 'd62d0cbd-1ccf-4b04-9713-fa66de7b1ada', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a395c7a-6bce-421b-9808-9678987f7289', '154d09f2-0b82-46b1-8ba4-bd0ce19dc85f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a395c7a-6bce-421b-9808-9678987f7289', '476bf474-217c-4367-a765-4e6e3fd029bd', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a395c7a-6bce-421b-9808-9678987f7289', 'c59a52ca-12ea-4dd6-96b0-4e2bcd59fbd0', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4a395c7a-6bce-421b-9808-9678987f7289', '6145193c-c7ab-4ac9-8886-74a2ecda1d74', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('476bf474-217c-4367-a765-4e6e3fd029bd', '6145193c-c7ab-4ac9-8886-74a2ecda1d74', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('476bf474-217c-4367-a765-4e6e3fd029bd', '4a395c7a-6bce-421b-9808-9678987f7289', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('476bf474-217c-4367-a765-4e6e3fd029bd', 'd62d0cbd-1ccf-4b04-9713-fa66de7b1ada', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('476bf474-217c-4367-a765-4e6e3fd029bd', 'c59a52ca-12ea-4dd6-96b0-4e2bcd59fbd0', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('476bf474-217c-4367-a765-4e6e3fd029bd', '154d09f2-0b82-46b1-8ba4-bd0ce19dc85f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d62d0cbd-1ccf-4b04-9713-fa66de7b1ada', '4a395c7a-6bce-421b-9808-9678987f7289', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d62d0cbd-1ccf-4b04-9713-fa66de7b1ada', '154d09f2-0b82-46b1-8ba4-bd0ce19dc85f', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d62d0cbd-1ccf-4b04-9713-fa66de7b1ada', '476bf474-217c-4367-a765-4e6e3fd029bd', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d62d0cbd-1ccf-4b04-9713-fa66de7b1ada', 'c59a52ca-12ea-4dd6-96b0-4e2bcd59fbd0', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d62d0cbd-1ccf-4b04-9713-fa66de7b1ada', '6145193c-c7ab-4ac9-8886-74a2ecda1d74', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c59a52ca-12ea-4dd6-96b0-4e2bcd59fbd0', '4a395c7a-6bce-421b-9808-9678987f7289', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c59a52ca-12ea-4dd6-96b0-4e2bcd59fbd0', '476bf474-217c-4367-a765-4e6e3fd029bd', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c59a52ca-12ea-4dd6-96b0-4e2bcd59fbd0', 'd62d0cbd-1ccf-4b04-9713-fa66de7b1ada', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c59a52ca-12ea-4dd6-96b0-4e2bcd59fbd0', '6145193c-c7ab-4ac9-8886-74a2ecda1d74', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c59a52ca-12ea-4dd6-96b0-4e2bcd59fbd0', '154d09f2-0b82-46b1-8ba4-bd0ce19dc85f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6145193c-c7ab-4ac9-8886-74a2ecda1d74', '476bf474-217c-4367-a765-4e6e3fd029bd', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6145193c-c7ab-4ac9-8886-74a2ecda1d74', '4a395c7a-6bce-421b-9808-9678987f7289', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6145193c-c7ab-4ac9-8886-74a2ecda1d74', 'd62d0cbd-1ccf-4b04-9713-fa66de7b1ada', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6145193c-c7ab-4ac9-8886-74a2ecda1d74', 'c59a52ca-12ea-4dd6-96b0-4e2bcd59fbd0', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6145193c-c7ab-4ac9-8886-74a2ecda1d74', '154d09f2-0b82-46b1-8ba4-bd0ce19dc85f', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c3600678-796f-4244-a904-6859a6312777', '1130f999-e559-4853-a222-14a6dce01e59', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c3600678-796f-4244-a904-6859a6312777', 'e8f36187-38ca-4f7f-a8f2-112c7a96dbaf', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c3600678-796f-4244-a904-6859a6312777', '7da5aeb0-6856-4cec-b7fb-145598a12e89', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f5240e82-ae6d-4243-a04c-9d2de3d2ed1c', 'e8f36187-38ca-4f7f-a8f2-112c7a96dbaf', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f5240e82-ae6d-4243-a04c-9d2de3d2ed1c', '7da5aeb0-6856-4cec-b7fb-145598a12e89', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f5240e82-ae6d-4243-a04c-9d2de3d2ed1c', 'a7782ff9-42df-41ab-9dfa-676554488e5b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f5240e82-ae6d-4243-a04c-9d2de3d2ed1c', '10259de7-32cf-4ee8-baeb-8f31c65b19cf', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f5240e82-ae6d-4243-a04c-9d2de3d2ed1c', '4b9e3f17-3a25-4ccd-a5be-837366041264', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7938c9b2-fdbe-477a-a17e-a80decf49322', 'e8f36187-38ca-4f7f-a8f2-112c7a96dbaf', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7938c9b2-fdbe-477a-a17e-a80decf49322', '7da5aeb0-6856-4cec-b7fb-145598a12e89', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7938c9b2-fdbe-477a-a17e-a80decf49322', 'a7782ff9-42df-41ab-9dfa-676554488e5b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b9e3f17-3a25-4ccd-a5be-837366041264', 'e8f36187-38ca-4f7f-a8f2-112c7a96dbaf', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b9e3f17-3a25-4ccd-a5be-837366041264', '7da5aeb0-6856-4cec-b7fb-145598a12e89', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b9e3f17-3a25-4ccd-a5be-837366041264', 'a7782ff9-42df-41ab-9dfa-676554488e5b', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b9e3f17-3a25-4ccd-a5be-837366041264', '10259de7-32cf-4ee8-baeb-8f31c65b19cf', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4b9e3f17-3a25-4ccd-a5be-837366041264', 'f5240e82-ae6d-4243-a04c-9d2de3d2ed1c', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1130f999-e559-4853-a222-14a6dce01e59', 'c3600678-796f-4244-a904-6859a6312777', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1130f999-e559-4853-a222-14a6dce01e59', 'e8f36187-38ca-4f7f-a8f2-112c7a96dbaf', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1130f999-e559-4853-a222-14a6dce01e59', '7da5aeb0-6856-4cec-b7fb-145598a12e89', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('154d09f2-0b82-46b1-8ba4-bd0ce19dc85f', '4a395c7a-6bce-421b-9808-9678987f7289', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('154d09f2-0b82-46b1-8ba4-bd0ce19dc85f', 'd62d0cbd-1ccf-4b04-9713-fa66de7b1ada', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('154d09f2-0b82-46b1-8ba4-bd0ce19dc85f', '476bf474-217c-4367-a765-4e6e3fd029bd', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('154d09f2-0b82-46b1-8ba4-bd0ce19dc85f', 'c59a52ca-12ea-4dd6-96b0-4e2bcd59fbd0', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('154d09f2-0b82-46b1-8ba4-bd0ce19dc85f', '6145193c-c7ab-4ac9-8886-74a2ecda1d74', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19ae161d-d1dc-4355-8815-03e151fe77d3', '55f51450-7387-4435-ba85-314e8184ff2e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19ae161d-d1dc-4355-8815-03e151fe77d3', '063a1035-bc0d-4f0d-afa4-cf8f89cb440a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('19ae161d-d1dc-4355-8815-03e151fe77d3', 'e8f36187-38ca-4f7f-a8f2-112c7a96dbaf', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('55f51450-7387-4435-ba85-314e8184ff2e', '19ae161d-d1dc-4355-8815-03e151fe77d3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('55f51450-7387-4435-ba85-314e8184ff2e', '063a1035-bc0d-4f0d-afa4-cf8f89cb440a', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('55f51450-7387-4435-ba85-314e8184ff2e', 'e8f36187-38ca-4f7f-a8f2-112c7a96dbaf', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('063a1035-bc0d-4f0d-afa4-cf8f89cb440a', '19ae161d-d1dc-4355-8815-03e151fe77d3', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('063a1035-bc0d-4f0d-afa4-cf8f89cb440a', '55f51450-7387-4435-ba85-314e8184ff2e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('063a1035-bc0d-4f0d-afa4-cf8f89cb440a', 'e8f36187-38ca-4f7f-a8f2-112c7a96dbaf', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('29634278-242e-4a73-926c-4fc3d7fa8344', '6e4db18e-1a9d-4229-87e7-48fd0a1e4940', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('29634278-242e-4a73-926c-4fc3d7fa8344', '0eabdbff-a244-40a9-bd1c-2272f3013b8d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('29634278-242e-4a73-926c-4fc3d7fa8344', '43426287-f020-4ddd-a06d-593a411083fb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('29634278-242e-4a73-926c-4fc3d7fa8344', '8bdc0885-9945-4a34-a377-b59d4016dbf8', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6e4db18e-1a9d-4229-87e7-48fd0a1e4940', '29634278-242e-4a73-926c-4fc3d7fa8344', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6e4db18e-1a9d-4229-87e7-48fd0a1e4940', '0eabdbff-a244-40a9-bd1c-2272f3013b8d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6e4db18e-1a9d-4229-87e7-48fd0a1e4940', '43426287-f020-4ddd-a06d-593a411083fb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6e4db18e-1a9d-4229-87e7-48fd0a1e4940', '8bdc0885-9945-4a34-a377-b59d4016dbf8', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0eabdbff-a244-40a9-bd1c-2272f3013b8d', '29634278-242e-4a73-926c-4fc3d7fa8344', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0eabdbff-a244-40a9-bd1c-2272f3013b8d', '6e4db18e-1a9d-4229-87e7-48fd0a1e4940', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0eabdbff-a244-40a9-bd1c-2272f3013b8d', '43426287-f020-4ddd-a06d-593a411083fb', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0eabdbff-a244-40a9-bd1c-2272f3013b8d', '8bdc0885-9945-4a34-a377-b59d4016dbf8', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('43426287-f020-4ddd-a06d-593a411083fb', '29634278-242e-4a73-926c-4fc3d7fa8344', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('43426287-f020-4ddd-a06d-593a411083fb', '6e4db18e-1a9d-4229-87e7-48fd0a1e4940', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('43426287-f020-4ddd-a06d-593a411083fb', '0eabdbff-a244-40a9-bd1c-2272f3013b8d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('43426287-f020-4ddd-a06d-593a411083fb', '8bdc0885-9945-4a34-a377-b59d4016dbf8', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8bdc0885-9945-4a34-a377-b59d4016dbf8', '29634278-242e-4a73-926c-4fc3d7fa8344', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8bdc0885-9945-4a34-a377-b59d4016dbf8', '6e4db18e-1a9d-4229-87e7-48fd0a1e4940', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8bdc0885-9945-4a34-a377-b59d4016dbf8', '0eabdbff-a244-40a9-bd1c-2272f3013b8d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8bdc0885-9945-4a34-a377-b59d4016dbf8', '43426287-f020-4ddd-a06d-593a411083fb', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7aa8ab2d-7794-4ddd-b0cb-136062e8dd6d', 'b046ad36-c3b2-436b-8801-f710d66616bf', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('7aa8ab2d-7794-4ddd-b0cb-136062e8dd6d', '0c265167-6ec2-4d23-a62b-009ed6ebb17e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b046ad36-c3b2-436b-8801-f710d66616bf', '7aa8ab2d-7794-4ddd-b0cb-136062e8dd6d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b046ad36-c3b2-436b-8801-f710d66616bf', '0c265167-6ec2-4d23-a62b-009ed6ebb17e', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c265167-6ec2-4d23-a62b-009ed6ebb17e', '7aa8ab2d-7794-4ddd-b0cb-136062e8dd6d', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('0c265167-6ec2-4d23-a62b-009ed6ebb17e', 'b046ad36-c3b2-436b-8801-f710d66616bf', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6de5636-833c-4360-97e0-16a5dd483c1d', 'bbf3b861-0622-41ec-9180-e0db7de7e597', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6de5636-833c-4360-97e0-16a5dd483c1d', '59126625-27f4-4db0-96e4-4525729faa37', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6de5636-833c-4360-97e0-16a5dd483c1d', 'b3b15007-6569-4d42-889d-d42bf587a4ef', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6de5636-833c-4360-97e0-16a5dd483c1d', '24003d2e-b3c7-4d9f-9594-39900e25ac82', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6de5636-833c-4360-97e0-16a5dd483c1d', '2856d763-a287-4778-ae0e-2ce21cdcbef9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59126625-27f4-4db0-96e4-4525729faa37', 'bbf3b861-0622-41ec-9180-e0db7de7e597', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59126625-27f4-4db0-96e4-4525729faa37', 'c6de5636-833c-4360-97e0-16a5dd483c1d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59126625-27f4-4db0-96e4-4525729faa37', 'b3b15007-6569-4d42-889d-d42bf587a4ef', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59126625-27f4-4db0-96e4-4525729faa37', '24003d2e-b3c7-4d9f-9594-39900e25ac82', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('59126625-27f4-4db0-96e4-4525729faa37', '2856d763-a287-4778-ae0e-2ce21cdcbef9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b3b15007-6569-4d42-889d-d42bf587a4ef', 'bbf3b861-0622-41ec-9180-e0db7de7e597', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b3b15007-6569-4d42-889d-d42bf587a4ef', 'c6de5636-833c-4360-97e0-16a5dd483c1d', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b3b15007-6569-4d42-889d-d42bf587a4ef', '59126625-27f4-4db0-96e4-4525729faa37', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b3b15007-6569-4d42-889d-d42bf587a4ef', '24003d2e-b3c7-4d9f-9594-39900e25ac82', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b3b15007-6569-4d42-889d-d42bf587a4ef', '2856d763-a287-4778-ae0e-2ce21cdcbef9', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2856d763-a287-4778-ae0e-2ce21cdcbef9', 'bbf3b861-0622-41ec-9180-e0db7de7e597', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2856d763-a287-4778-ae0e-2ce21cdcbef9', '24003d2e-b3c7-4d9f-9594-39900e25ac82', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2856d763-a287-4778-ae0e-2ce21cdcbef9', 'c6de5636-833c-4360-97e0-16a5dd483c1d', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2856d763-a287-4778-ae0e-2ce21cdcbef9', '59126625-27f4-4db0-96e4-4525729faa37', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2856d763-a287-4778-ae0e-2ce21cdcbef9', 'b3b15007-6569-4d42-889d-d42bf587a4ef', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d73b2c8e-f6f7-4ce6-8dcd-3e2a68b135c1', '002a8c0f-53a7-421f-8a6d-9b0af59434a1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d73b2c8e-f6f7-4ce6-8dcd-3e2a68b135c1', 'cb981cfb-2d25-4235-b1a4-c408a199e581', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('002a8c0f-53a7-421f-8a6d-9b0af59434a1', 'd73b2c8e-f6f7-4ce6-8dcd-3e2a68b135c1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('002a8c0f-53a7-421f-8a6d-9b0af59434a1', 'cb981cfb-2d25-4235-b1a4-c408a199e581', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cb981cfb-2d25-4235-b1a4-c408a199e581', 'd73b2c8e-f6f7-4ce6-8dcd-3e2a68b135c1', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('cb981cfb-2d25-4235-b1a4-c408a199e581', '002a8c0f-53a7-421f-8a6d-9b0af59434a1', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('50dbcb6e-dfec-4c0e-9a94-4cd82cdfdd45', '79fd97af-8700-4fbc-ae38-d5e3768f1a56', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('50dbcb6e-dfec-4c0e-9a94-4cd82cdfdd45', '1e951baa-ee28-4a07-afa2-cf5138b8f0a8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('50dbcb6e-dfec-4c0e-9a94-4cd82cdfdd45', '2aa21bf1-bcaf-4410-ace6-1048520fb74e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('79fd97af-8700-4fbc-ae38-d5e3768f1a56', '2aa21bf1-bcaf-4410-ace6-1048520fb74e', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('79fd97af-8700-4fbc-ae38-d5e3768f1a56', '50dbcb6e-dfec-4c0e-9a94-4cd82cdfdd45', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('79fd97af-8700-4fbc-ae38-d5e3768f1a56', '1e951baa-ee28-4a07-afa2-cf5138b8f0a8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1e951baa-ee28-4a07-afa2-cf5138b8f0a8', '50dbcb6e-dfec-4c0e-9a94-4cd82cdfdd45', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1e951baa-ee28-4a07-afa2-cf5138b8f0a8', '79fd97af-8700-4fbc-ae38-d5e3768f1a56', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('1e951baa-ee28-4a07-afa2-cf5138b8f0a8', '2aa21bf1-bcaf-4410-ace6-1048520fb74e', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2aa21bf1-bcaf-4410-ace6-1048520fb74e', '79fd97af-8700-4fbc-ae38-d5e3768f1a56', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2aa21bf1-bcaf-4410-ace6-1048520fb74e', '50dbcb6e-dfec-4c0e-9a94-4cd82cdfdd45', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('2aa21bf1-bcaf-4410-ace6-1048520fb74e', '1e951baa-ee28-4a07-afa2-cf5138b8f0a8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8a3e7493-6f5e-485b-beab-e4fa9e0f0fee', '4f20af2b-a69d-43df-a549-b2b9d18ac5a8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8a3e7493-6f5e-485b-beab-e4fa9e0f0fee', '36407719-83f1-4e39-b871-1e4d802fe656', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8a3e7493-6f5e-485b-beab-e4fa9e0f0fee', 'f9eec034-08de-4969-8afa-4d6dd3e9eb94', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8a3e7493-6f5e-485b-beab-e4fa9e0f0fee', 'e67f8cfe-420c-4d9d-b101-4a9f42d0ead5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8a3e7493-6f5e-485b-beab-e4fa9e0f0fee', '9af66d5a-2694-49ec-b7ff-9d488bb73d31', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4f20af2b-a69d-43df-a549-b2b9d18ac5a8', '8a3e7493-6f5e-485b-beab-e4fa9e0f0fee', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4f20af2b-a69d-43df-a549-b2b9d18ac5a8', '36407719-83f1-4e39-b871-1e4d802fe656', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4f20af2b-a69d-43df-a549-b2b9d18ac5a8', 'f9eec034-08de-4969-8afa-4d6dd3e9eb94', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4f20af2b-a69d-43df-a549-b2b9d18ac5a8', 'e67f8cfe-420c-4d9d-b101-4a9f42d0ead5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('4f20af2b-a69d-43df-a549-b2b9d18ac5a8', '9af66d5a-2694-49ec-b7ff-9d488bb73d31', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('36407719-83f1-4e39-b871-1e4d802fe656', '89434721-b4fa-4aed-8561-824cc14f3f2a', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('36407719-83f1-4e39-b871-1e4d802fe656', '8a3e7493-6f5e-485b-beab-e4fa9e0f0fee', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('36407719-83f1-4e39-b871-1e4d802fe656', '4f20af2b-a69d-43df-a549-b2b9d18ac5a8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('36407719-83f1-4e39-b871-1e4d802fe656', 'f9eec034-08de-4969-8afa-4d6dd3e9eb94', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('36407719-83f1-4e39-b871-1e4d802fe656', 'e67f8cfe-420c-4d9d-b101-4a9f42d0ead5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9eec034-08de-4969-8afa-4d6dd3e9eb94', '8a3e7493-6f5e-485b-beab-e4fa9e0f0fee', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9eec034-08de-4969-8afa-4d6dd3e9eb94', '4f20af2b-a69d-43df-a549-b2b9d18ac5a8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9eec034-08de-4969-8afa-4d6dd3e9eb94', '36407719-83f1-4e39-b871-1e4d802fe656', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9eec034-08de-4969-8afa-4d6dd3e9eb94', 'e67f8cfe-420c-4d9d-b101-4a9f42d0ead5', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('f9eec034-08de-4969-8afa-4d6dd3e9eb94', '9af66d5a-2694-49ec-b7ff-9d488bb73d31', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e67f8cfe-420c-4d9d-b101-4a9f42d0ead5', '8a3e7493-6f5e-485b-beab-e4fa9e0f0fee', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e67f8cfe-420c-4d9d-b101-4a9f42d0ead5', '4f20af2b-a69d-43df-a549-b2b9d18ac5a8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e67f8cfe-420c-4d9d-b101-4a9f42d0ead5', '36407719-83f1-4e39-b871-1e4d802fe656', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e67f8cfe-420c-4d9d-b101-4a9f42d0ead5', 'f9eec034-08de-4969-8afa-4d6dd3e9eb94', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e67f8cfe-420c-4d9d-b101-4a9f42d0ead5', '9af66d5a-2694-49ec-b7ff-9d488bb73d31', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9af66d5a-2694-49ec-b7ff-9d488bb73d31', '8a3e7493-6f5e-485b-beab-e4fa9e0f0fee', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9af66d5a-2694-49ec-b7ff-9d488bb73d31', '4f20af2b-a69d-43df-a549-b2b9d18ac5a8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9af66d5a-2694-49ec-b7ff-9d488bb73d31', '36407719-83f1-4e39-b871-1e4d802fe656', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9af66d5a-2694-49ec-b7ff-9d488bb73d31', 'f9eec034-08de-4969-8afa-4d6dd3e9eb94', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9af66d5a-2694-49ec-b7ff-9d488bb73d31', 'e67f8cfe-420c-4d9d-b101-4a9f42d0ead5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7205f18-01e0-411c-b5d0-a044cf023eb0', '8a3e7493-6f5e-485b-beab-e4fa9e0f0fee', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7205f18-01e0-411c-b5d0-a044cf023eb0', '4f20af2b-a69d-43df-a549-b2b9d18ac5a8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7205f18-01e0-411c-b5d0-a044cf023eb0', '36407719-83f1-4e39-b871-1e4d802fe656', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7205f18-01e0-411c-b5d0-a044cf023eb0', 'f9eec034-08de-4969-8afa-4d6dd3e9eb94', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('b7205f18-01e0-411c-b5d0-a044cf023eb0', 'e67f8cfe-420c-4d9d-b101-4a9f42d0ead5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89434721-b4fa-4aed-8561-824cc14f3f2a', '36407719-83f1-4e39-b871-1e4d802fe656', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89434721-b4fa-4aed-8561-824cc14f3f2a', '8a3e7493-6f5e-485b-beab-e4fa9e0f0fee', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89434721-b4fa-4aed-8561-824cc14f3f2a', '4f20af2b-a69d-43df-a549-b2b9d18ac5a8', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89434721-b4fa-4aed-8561-824cc14f3f2a', 'f9eec034-08de-4969-8afa-4d6dd3e9eb94', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('89434721-b4fa-4aed-8561-824cc14f3f2a', 'e67f8cfe-420c-4d9d-b101-4a9f42d0ead5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6be0795-8101-4108-8021-b0fd0c309eaf', '8a3e7493-6f5e-485b-beab-e4fa9e0f0fee', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6be0795-8101-4108-8021-b0fd0c309eaf', '4f20af2b-a69d-43df-a549-b2b9d18ac5a8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6be0795-8101-4108-8021-b0fd0c309eaf', '36407719-83f1-4e39-b871-1e4d802fe656', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6be0795-8101-4108-8021-b0fd0c309eaf', 'f9eec034-08de-4969-8afa-4d6dd3e9eb94', 3) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c6be0795-8101-4108-8021-b0fd0c309eaf', 'e67f8cfe-420c-4d9d-b101-4a9f42d0ead5', 4) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a4d6906d-9fce-421e-b7c5-e0550c65b175', '4c426ce5-3e4e-432f-b8b0-59090708ce86', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('6bdd7a4b-acd6-47b9-adcf-b0e236a4b04f', '4c426ce5-3e4e-432f-b8b0-59090708ce86', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('a63da586-c0cc-4c9a-97d7-9754e466f0d1', '4c426ce5-3e4e-432f-b8b0-59090708ce86', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('95ec9d9a-ab56-4896-9418-ccb28fe4047a', '4c426ce5-3e4e-432f-b8b0-59090708ce86', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('3fe4870f-7d0e-46d4-975d-76cb63c69836', '4c426ce5-3e4e-432f-b8b0-59090708ce86', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('5fbc2948-247a-446c-8c94-c82e388d7388', '4c426ce5-3e4e-432f-b8b0-59090708ce86', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dd1ddca7-c7e8-495a-bf14-93099f40c680', '907cd39c-2902-4bb6-9ed9-6ea2e40285c4', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dd1ddca7-c7e8-495a-bf14-93099f40c680', '21a47a0c-212f-4fae-a652-9ee1ad9b2ff8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('dd1ddca7-c7e8-495a-bf14-93099f40c680', '8d4bcd42-4ed9-4b23-b185-7da8e64efc39', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('907cd39c-2902-4bb6-9ed9-6ea2e40285c4', 'dd1ddca7-c7e8-495a-bf14-93099f40c680', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('907cd39c-2902-4bb6-9ed9-6ea2e40285c4', '21a47a0c-212f-4fae-a652-9ee1ad9b2ff8', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('907cd39c-2902-4bb6-9ed9-6ea2e40285c4', '8d4bcd42-4ed9-4b23-b185-7da8e64efc39', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('21a47a0c-212f-4fae-a652-9ee1ad9b2ff8', '8d4bcd42-4ed9-4b23-b185-7da8e64efc39', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('21a47a0c-212f-4fae-a652-9ee1ad9b2ff8', 'dd1ddca7-c7e8-495a-bf14-93099f40c680', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('21a47a0c-212f-4fae-a652-9ee1ad9b2ff8', '907cd39c-2902-4bb6-9ed9-6ea2e40285c4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d4bcd42-4ed9-4b23-b185-7da8e64efc39', '21a47a0c-212f-4fae-a652-9ee1ad9b2ff8', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d4bcd42-4ed9-4b23-b185-7da8e64efc39', 'dd1ddca7-c7e8-495a-bf14-93099f40c680', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8d4bcd42-4ed9-4b23-b185-7da8e64efc39', '907cd39c-2902-4bb6-9ed9-6ea2e40285c4', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('70fcc68c-b43d-4bd9-8dca-a81ebd1f8c39', '9a5cd794-1438-491c-a337-e77522d0f897', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('70fcc68c-b43d-4bd9-8dca-a81ebd1f8c39', 'e74572d5-a402-4449-90d7-91533caa7864', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('803aa33d-830a-4461-9369-c8a8c0ab4a55', '70fcc68c-b43d-4bd9-8dca-a81ebd1f8c39', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('803aa33d-830a-4461-9369-c8a8c0ab4a55', '9a5cd794-1438-491c-a337-e77522d0f897', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('803aa33d-830a-4461-9369-c8a8c0ab4a55', 'e74572d5-a402-4449-90d7-91533caa7864', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d968264b-ea4b-4946-a8e9-59c389ba76ef', '70fcc68c-b43d-4bd9-8dca-a81ebd1f8c39', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d968264b-ea4b-4946-a8e9-59c389ba76ef', '9a5cd794-1438-491c-a337-e77522d0f897', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('d968264b-ea4b-4946-a8e9-59c389ba76ef', 'e74572d5-a402-4449-90d7-91533caa7864', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9a5cd794-1438-491c-a337-e77522d0f897', '70fcc68c-b43d-4bd9-8dca-a81ebd1f8c39', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('9a5cd794-1438-491c-a337-e77522d0f897', 'e74572d5-a402-4449-90d7-91533caa7864', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b24a99e-6e24-4f9e-87a7-813447504ae8', '70fcc68c-b43d-4bd9-8dca-a81ebd1f8c39', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b24a99e-6e24-4f9e-87a7-813447504ae8', '9a5cd794-1438-491c-a337-e77522d0f897', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('8b24a99e-6e24-4f9e-87a7-813447504ae8', 'e74572d5-a402-4449-90d7-91533caa7864', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9cb6258-2ed7-4b08-b64d-2075f4d8d4cd', '70fcc68c-b43d-4bd9-8dca-a81ebd1f8c39', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9cb6258-2ed7-4b08-b64d-2075f4d8d4cd', '9a5cd794-1438-491c-a337-e77522d0f897', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('c9cb6258-2ed7-4b08-b64d-2075f4d8d4cd', 'e74572d5-a402-4449-90d7-91533caa7864', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e74572d5-a402-4449-90d7-91533caa7864', '70fcc68c-b43d-4bd9-8dca-a81ebd1f8c39', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e74572d5-a402-4449-90d7-91533caa7864', '9a5cd794-1438-491c-a337-e77522d0f897', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e6fa6527-f9b7-4106-a07d-87264f89b50b', '70fcc68c-b43d-4bd9-8dca-a81ebd1f8c39', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e6fa6527-f9b7-4106-a07d-87264f89b50b', '9a5cd794-1438-491c-a337-e77522d0f897', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('e6fa6527-f9b7-4106-a07d-87264f89b50b', 'e74572d5-a402-4449-90d7-91533caa7864', 2) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba1bd581-230b-4351-8553-a37f266743fd', '70fcc68c-b43d-4bd9-8dca-a81ebd1f8c39', 0) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba1bd581-230b-4351-8553-a37f266743fd', '9a5cd794-1438-491c-a337-e77522d0f897', 1) ON CONFLICT DO NOTHING;
INSERT INTO public.exercise_alternatives VALUES ('ba1bd581-230b-4351-8553-a37f266743fd', 'e74572d5-a402-4449-90d7-91533caa7864', 2) ON CONFLICT DO NOTHING;



INSERT INTO public.faqs VALUES ('097b08af-5c6f-4c55-91ee-42e399f658e4', 'متى يوصلني الرد بعد الاشتراك؟', 'خلال 48 ساعة عمل. أيام العمل من الأحد إلى الخميس، من 12 الظهر حتى 9 مساءً، والتواصل على واتساب.', 0, true, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('b28138ce-b08b-4433-b00f-c422abbd23f9', 'كيف تتم المتابعة؟', 'ترسل مراجعتك الأسبوعية في يوم المراجعة، وأرد عليك بتعديلات مسجلة (فيديو أو صوت). في الباقة الأساسية المتابعة كل أسبوعين. التواصل اليومي على واتساب مع رد خلال 48 ساعة.', 1, true, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('b97e7db0-a5a2-41f2-8227-8ab19b85874d', 'أنا مبتدئ تماماً، هل يناسبني؟', 'نعم. البرنامج يُبنى على مستواك الحالي، والتمارين مشروحة، وتقدر ترسل مقاطع أدائك لتصحيح التكنيك.', 2, true, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('f88f9fdf-b0ff-4943-b2d9-a3e1d7954273', 'أتمرن في البيت، ماذا أحتاج من أدوات؟', 'تحدد في النموذج الأدوات المتوفرة عندك (دمبلز، حبال مقاومة، بار…) ويُبنى جدولك عليها.', 3, true, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('9667946e-17aa-48a9-87d2-6b5579eb6498', 'كيف أدفع؟', 'بتحويل بنكي بعد تعبئة الاستبيان. أول ما ترسل الاستبيان يظهر لك رقم طلبك والمبلغ وبيانات الحساب. حوّل المبلغ وارفع صورة الإيصال من صفحة طلبك، ويتأكد اشتراكك بعد التحقق من وصول المبلغ.', 4, true, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('484d7955-3ee0-4ab2-a33b-5e7a62a12878', 'ما شروط ضمان استرجاع المبلغ؟', 'في اشتراكات 3 أشهر لباقات المتابعة (المكثفة، المتقدمة، الأساسية): إذا لم يتحسن أي مؤشر من مؤشرات تقدمك بعد 12 أسبوعاً، يرجع لك المبلغ كاملاً.
مؤشرات التقدم (بحسب هدفك): متوسط الوزن الأسبوعي، أو محيط الخصر، أو القوة في التمارين الأساسية (الوزن أو التكرارات).
شروط الضمان:
- إرسال المراجعة الأسبوعية كل أسبوع.
- أخذ القياسات بانتظام.
- تصوير التمارين وإرسالها.
- الالتزام بجدول التغذية المخصص (في الباقات التي تشمل تغذية).
يُطلب الاسترجاع عبر واتساب خلال 14 يوماً من نهاية الأشهر الثلاثة.', 5, true, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('0fd4b6e9-2c70-45fc-8f07-0d05712e154e', 'هل الجداول لي بعد انتهاء الاشتراك؟', 'نعم، جميع الجداول لك مدى الحياة وتقدر تعدّل عليها.', 6, true, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('0e4c86d2-f071-42cc-9925-e9d0ba2329fd', 'ما هو التجديد المجاني؟', 'مكافأة للملتزمين: إذا كان اشتراكك 3 أشهر تحصل على 3 أشهر إضافية مجاناً، فيصير المجموع 6 أشهر بسعر 3.
الشروط:
- نسبة التزام 90% فأكثر: المراجعات الأسبوعية المرسلة والتمارين المسجلة.
- تقدم واضح في مؤشرات التقدم نفسها المذكورة في الضمان.
- للمتدربين الرجال: إرسال صور التطور (قبل وبعد) للمدربة للتوثيق، مع تغطية الوجه والسرة.
نشر الصور في السوشل ميديا اختياري بالكامل حسب موافقتك، ولا يؤثر على استحقاقك للتجديد.', 7, true, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;
INSERT INTO public.faqs VALUES ('27c4a2a5-145d-4079-9b9f-f20f62301095', 'من يطّلع على بياناتي؟', 'المدربة فقط، وتُستخدم لتصميم برنامجك ومتابعتك. لا تُنشر نتيجتك أو صورتك إلا بموافقتك الصريحة في النموذج.', 8, true, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;



INSERT INTO public.foods VALUES ('c227c20b-bf47-48b9-81ac-9ab0f0ab41c9', 'رز أبيض مطبوخ', 'Rice, white, long-grain, regular, enriched, cooked', 'حبوب ونشويات', 130.0, 2.7, 28.2, 0.3, 150.0, 'كوب إلا ربع', 'usda', '168878', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'حبوب ونشويات', 0.4, '{"iron": 1.2, "zinc": 0.49, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.04, "vit_k": 0, "folate": 97, "vit_b6": 0.093, "calcium": 10, "vit_b12": 0, "magnesium": 12, "potassium": 35}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('75c86652-acc1-4d16-99e3-5a5360b4d9ea', 'رز بني مطبوخ', 'Rice, brown, long-grain, cooked (Includes foods for USDA''s Food Distribution Program)', 'حبوب ونشويات', 123.0, 2.7, 25.6, 1.0, 150.0, NULL, 'usda', '169704', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'حبوب ونشويات', 1.6, '{"iron": 0.56, "zinc": 0.71, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.17, "vit_k": 0.2, "folate": 9, "vit_b6": 0.123, "calcium": 3, "vit_b12": 0, "magnesium": 39, "potassium": 86}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('47216b48-0946-488f-b535-4e53b32d8e10', 'رز أبيض (غير مطبوخ)', 'Rice, white, long-grain, regular, raw, enriched', 'حبوب ونشويات', 365.0, 7.1, 80.0, 0.7, 75.0, NULL, 'usda', '168877', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'حبوب ونشويات', 1.3, '{"iron": 4.31, "zinc": 1.09, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.11, "vit_k": 0.1, "folate": 387, "vit_b6": 0.164, "calcium": 28, "vit_b12": 0, "magnesium": 25, "potassium": 115}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('0221f5d4-7a6a-4196-8e4d-20eaaf3aa6e6', 'مكرونة مطبوخة', 'Pasta, cooked, enriched, without added salt', 'حبوب ونشويات', 158.0, 5.8, 30.9, 0.9, 140.0, 'كوب', 'usda', '169737', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'حبوب ونشويات', 1.8, '{"iron": 1.28, "zinc": 0.51, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.06, "vit_k": 0, "folate": 119, "vit_b6": 0.049, "calcium": 7, "vit_b12": 0, "magnesium": 18, "potassium": 44}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('0be15161-8730-49c4-948f-10fae7479ece', 'مكرونة (غير مطبوخة)', 'Pasta, dry, enriched', 'حبوب ونشويات', 371.0, 13.0, 74.7, 1.5, 75.0, NULL, 'usda', '169736', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'حبوب ونشويات', 3.2, '{"iron": 3.3, "zinc": 1.41, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.11, "vit_k": 0.1, "folate": 391, "vit_b6": 0.142, "calcium": 21, "vit_b12": 0, "magnesium": 53, "potassium": 223}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('50f791fd-3bf1-478f-b61f-b4f9589c9bb5', 'شوفان', 'Cereals, oats, regular and quick, not fortified, dry', 'حبوب ونشويات', 379.0, 13.2, 67.7, 6.5, 40.0, 'نص كوب', 'usda', '173904', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'حبوب ونشويات', 10.1, '{"iron": 4.25, "zinc": 3.64, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.42, "vit_k": 2, "folate": 32, "vit_b6": 0.1, "calcium": 52, "vit_b12": 0, "magnesium": 138, "potassium": 362}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('36554aa6-b5b0-4b54-b5e0-9cdf5dc4479e', 'خبز أبيض (توست)', 'Bread, white, commercially prepared (includes soft bread crumbs)', 'خبز', 266.0, 8.9, 49.4, 3.3, 28.0, 'شريحة', 'usda', '174924', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'حبوب ونشويات', 2.7, '{"iron": 3.61, "zinc": 0.74, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.22, "vit_k": 0.2, "folate": 171, "vit_b6": 0.087, "calcium": 144, "vit_b12": 0, "magnesium": 23, "potassium": 126}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('bf253c3f-5da3-433e-aba3-3e448d500cf6', 'خبز بر (توست أسمر)', 'Bread, whole-wheat, commercially prepared', 'خبز', 252.0, 12.5, 42.7, 3.5, 32.0, 'شريحة', 'usda', '172688', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'حبوب ونشويات', 6.0, '{"iron": 2.47, "zinc": 1.77, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 2.66, "vit_k": 7.8, "folate": 42, "vit_b6": 0.215, "calcium": 161, "vit_b12": 0, "magnesium": 75, "potassium": 254}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('23329c5a-f492-4a9b-8c5d-2c85a8f2c7fa', 'خبز عربي أبيض', 'Bread, pita, white, enriched', 'خبز', 275.0, 9.1, 55.7, 1.2, 60.0, 'رغيف صغير', 'usda', '174915', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'حبوب ونشويات', 2.2, '{"iron": 2.62, "zinc": 0.84, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.3, "vit_k": 0.2, "folate": 165, "vit_b6": 0.034, "calcium": 86, "vit_b12": 0, "magnesium": 26, "potassium": 120}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('89bf2ac6-b8a5-49c8-a4ff-ae0fac8d0f72', 'خبز عربي بر', 'Bread, pita, whole-wheat', 'خبز', 262.0, 9.8, 55.9, 1.7, 64.0, 'رغيف صغير', 'usda', '174916', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'حبوب ونشويات', 6.1, '{"iron": 3.06, "zinc": 1.52, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.61, "vit_k": 1.4, "folate": 35, "vit_b6": 0.265, "calcium": 15, "vit_b12": 0, "magnesium": 69, "potassium": 170}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('dde379da-9c84-472b-be3c-b8ab21a465bc', 'تورتيلا قمح', 'Tortillas, ready-to-bake or -fry, flour, refrigerated', 'خبز', 306.0, 8.2, 49.4, 8.0, 45.0, 'حبة', 'usda', '175037', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'حبوب ونشويات', 3.5, '{"iron": 3.63, "zinc": 0.53, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0, "vit_k": 7.2, "folate": 149, "vit_b6": 0.059, "calcium": 146, "vit_b12": 0, "magnesium": 22, "potassium": 125}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('8d034fef-a001-40fa-acea-ec4dcb70106d', 'بطاطس مسلوقة', 'Potatoes, boiled, cooked without skin, flesh, without salt', 'حبوب ونشويات', 86.0, 1.7, 20.0, 0.1, 150.0, 'حبة وسط', 'usda', '170440', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'خضار نشوية', 1.8, '{"iron": 0.31, "zinc": 0.27, "vit_a": 0, "vit_c": 7.4, "vit_d": 0, "vit_e": 0.01, "vit_k": 2.2, "folate": 9, "vit_b6": 0.269, "calcium": 8, "vit_b12": 0, "magnesium": 20, "potassium": 328}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('84ae6d6f-ebeb-4c47-8053-314ff73fb0d4', 'بطاطا حلوة مشوية', 'Sweet potato, cooked, baked in skin, flesh, without salt', 'حبوب ونشويات', 90.0, 2.0, 20.7, 0.2, 150.0, 'حبة وسط', 'usda', '168483', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'خضار نشوية', 3.3, '{"iron": 0.69, "zinc": 0.32, "vit_a": 961, "vit_c": 19.6, "vit_d": 0, "vit_e": 0.71, "vit_k": 2.3, "folate": 6, "vit_b6": 0.286, "calcium": 38, "vit_b12": 0, "magnesium": 27, "potassium": 475}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d7b9942f-b9dc-4f64-880b-d3e1840edb15', 'برغل مطبوخ', 'Bulgur, cooked', 'حبوب ونشويات', 83.0, 3.1, 18.6, 0.2, 150.0, NULL, 'usda', '170287', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'حبوب ونشويات', 4.5, '{"iron": 0.96, "zinc": 0.57, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.01, "vit_k": 0.5, "folate": 18, "vit_b6": 0.083, "calcium": 10, "vit_b12": 0, "magnesium": 32, "potassium": 68}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('5d055978-555f-4487-9665-b8abe97729fd', 'كينوا مطبوخة', 'Quinoa, cooked', 'حبوب ونشويات', 120.0, 4.4, 21.3, 1.9, 150.0, NULL, 'usda', '168917', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'حبوب ونشويات', 2.8, '{"iron": 1.49, "zinc": 1.09, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0.63, "vit_k": 0, "folate": 42, "vit_b6": 0.123, "calcium": 17, "vit_b12": 0, "magnesium": 64, "potassium": 172}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('cc577d3a-5a95-46de-80c9-229fdc7a2471', 'كورن فليكس', 'Cereals ready-to-eat, RALSTON Corn Flakes', 'حبوب ونشويات', 384.0, 5.9, 88.0, 0.9, 30.0, NULL, 'usda', '174648', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'حبوب ونشويات', 2.7, '{"iron": 19.4, "zinc": 0.2, "vit_a": 981, "vit_c": 65, "vit_d": 7.1, "vit_e": 0.02, "vit_k": 0, "vit_b6": 1.907, "calcium": 2, "vit_b12": 5.36, "magnesium": 7, "potassium": 107}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('84ae5f56-e25f-4512-a7ff-54b3bf7e72eb', 'صدر دجاج مشوي', 'Chicken, broilers or fryers, breast, meat only, cooked, roasted', 'لحوم ودواجن', 165.0, 31.0, 0.0, 3.6, 100.0, NULL, 'usda', '171477', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'لحوم بيضاء (دواجن)', 0.0, '{"iron": 1.04, "zinc": 1, "vit_a": 6, "vit_c": 0, "vit_d": 0.1, "vit_e": 0.27, "vit_k": 0.3, "folate": 4, "vit_b6": 0.6, "calcium": 15, "vit_b12": 0.34, "magnesium": 29, "potassium": 256}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('767e2be9-01e0-46fd-bd67-b7a1acf95d8d', 'صدر دجاج نيء', 'Chicken, broiler or fryers, breast, skinless, boneless, meat only, raw', 'لحوم ودواجن', 120.0, 22.5, 0.0, 2.6, 150.0, NULL, 'usda', '171077', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'لحوم بيضاء (دواجن)', 0.0, '{"iron": 0.37, "zinc": 0.68, "vit_a": 9, "vit_c": 0, "vit_d": 0, "vit_e": 0.56, "vit_k": 0, "folate": 9, "vit_b6": 0.811, "calcium": 5, "vit_b12": 0.21, "magnesium": 28, "potassium": 334}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('c83406a9-893b-4eba-9079-e68b61ae4543', 'فخذ دجاج مشوي (بدون جلد)', 'Chicken, broilers or fryers, thigh, meat only, cooked, roasted', 'لحوم ودواجن', 179.0, 24.8, 0.0, 8.2, 100.0, NULL, 'usda', '172388', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'لحوم بيضاء (دواجن)', 0.0, '{"iron": 1.13, "zinc": 1.92, "vit_a": 8, "vit_c": 0, "vit_d": 0.2, "vit_e": 0.18, "vit_k": 3.9, "folate": 5, "vit_b6": 0.462, "calcium": 9, "vit_b12": 0.42, "magnesium": 24, "potassium": 269}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a114670e-9556-49c6-9a8e-c3571a12a3db', 'لحم بقري مفروم 90% مطبوخ', 'Beef, ground, 90% lean meat / 10% fat, patty, cooked, broiled', 'لحوم ودواجن', 217.0, 26.1, 0.0, 11.8, 100.0, NULL, 'usda', '174031', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'لحوم حمراء', 0.0, '{"iron": 2.71, "zinc": 6.37, "vit_a": 3, "vit_c": 0, "vit_d": 0, "vit_e": 0.12, "vit_k": 1.1, "folate": 8, "vit_b6": 0.397, "calcium": 13, "vit_b12": 2.56, "magnesium": 22, "potassium": 333}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('91c67162-8bc4-4463-9039-390d498e8c08', 'لحم بقري مفروم 80% مطبوخ', 'Beef, ground, 80% lean meat / 20% fat, patty, cooked, broiled', 'لحوم ودواجن', 270.0, 25.8, 0.0, 17.8, 100.0, NULL, 'usda', '171797', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'لحوم حمراء', 0.0, '{"iron": 2.48, "zinc": 6.25, "vit_a": 3, "vit_c": 0, "vit_d": 0, "vit_e": 0.12, "vit_k": 1.6, "folate": 10, "vit_b6": 0.366, "calcium": 24, "vit_b12": 2.73, "magnesium": 20, "potassium": 304}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b7c6f546-67a1-4349-a350-a34e40f2e921', 'لحم غنم مطبوخ', 'Lamb, composite of trimmed retail cuts, separable lean only, trimmed to 1/4" fat, choice, cooked', 'لحوم ودواجن', 206.0, 28.2, 0.0, 9.5, 100.0, NULL, 'usda', '174308', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'لحوم حمراء', 0.0, '{"iron": 2.05, "zinc": 5.27, "vit_a": 0, "vit_c": 0, "vit_e": 0.19, "folate": 23, "vit_b6": 0.16, "calcium": 15, "vit_b12": 2.61, "magnesium": 26, "potassium": 344}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('7a1514b3-3fb3-4eb1-aa0e-bb65c1d3423d', 'ديك رومي (شرائح)', 'Turkey, whole, breast, meat only, cooked, roasted', 'لحوم ودواجن', 147.0, 30.1, 0.0, 2.1, 50.0, NULL, 'usda', '171496', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'لحوم بيضاء (دواجن)', 0.0, '{"iron": 0.71, "zinc": 1.72, "vit_a": 3, "vit_c": 0, "vit_d": 0.3, "vit_e": 0.06, "vit_k": 0, "folate": 9, "vit_b6": 0.807, "calcium": 9, "vit_b12": 0.39, "magnesium": 32, "potassium": 249}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('32cb5056-317c-4f9c-924d-fd9d68740336', 'تونة معلبة بالماء', 'Fish, tuna, light, canned in water, drained solids (Includes foods for USDA''s Food Distribution Program)', 'أسماك', 86.0, 19.4, 0.0, 1.0, 100.0, 'علبة صغيرة مصفاة', 'usda', '173709', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'أسماك ومأكولات بحرية', 0.0, '{"iron": 1.63, "zinc": 0.69, "vit_a": 17, "vit_c": 0, "vit_d": 1.2, "vit_e": 0.33, "vit_k": 0.2, "folate": 4, "vit_b6": 0.319, "calcium": 17, "vit_b12": 2.55, "magnesium": 23, "potassium": 179}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3e0c08c8-b85f-42a7-a805-cd3bb2acbdf5', 'تونة معلبة بالزيت', 'Fish, tuna, light, canned in oil, drained solids', 'أسماك', 198.0, 29.1, 0.0, 8.2, 100.0, NULL, 'usda', '173708', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'أسماك ومأكولات بحرية', 0.0, '{"iron": 1.39, "zinc": 0.9, "vit_a": 23, "vit_c": 0, "vit_d": 6.7, "vit_e": 0.87, "vit_k": 44, "folate": 5, "vit_b6": 0.11, "calcium": 13, "vit_b12": 2.2, "magnesium": 31, "potassium": 207}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('4143571d-5c9e-4c14-b94e-e0ebf4943d9d', 'سلمون مطبوخ', 'Fish, salmon, Atlantic, farmed, cooked, dry heat', 'أسماك', 206.0, 22.1, 0.0, 12.4, 120.0, NULL, 'usda', '175168', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'أسماك ومأكولات بحرية', 0.0, '{"iron": 0.34, "zinc": 0.43, "vit_a": 69, "vit_c": 3.7, "vit_d": 13.1, "vit_e": 1.14, "vit_k": 0.1, "folate": 34, "vit_b6": 0.647, "calcium": 15, "vit_b12": 2.8, "magnesium": 30, "potassium": 384}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('509478c8-f53d-4509-a06e-eeea7f4dae7f', 'سلمون مدخن', 'Fish, salmon, chinook, smoked', 'أسماك', 117.0, 18.3, 0.0, 4.3, 60.0, NULL, 'usda', '173687', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'أسماك ومأكولات بحرية', 0.0, '{"iron": 0.85, "zinc": 0.31, "vit_a": 26, "vit_c": 0, "vit_d": 17.1, "vit_e": 1.35, "vit_k": 0.1, "folate": 2, "vit_b6": 0.278, "calcium": 11, "vit_b12": 3.26, "magnesium": 18, "potassium": 175}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('21ed019a-c737-4ab1-94e9-60f006aea31f', 'روبيان مطبوخ', 'Crustaceans, shrimp, cooked', 'أسماك', 99.0, 24.0, 0.2, 0.3, 100.0, NULL, 'usda', '175180', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'أسماك ومأكولات بحرية', 0.0, '{"iron": 0.51, "zinc": 1.64, "calcium": 70, "magnesium": 39, "potassium": 259}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('fb953e34-e6d8-4680-ad5b-eeb526f14576', 'هامور/سمك أبيض مطبوخ', 'Fish, grouper, mixed species, cooked, dry heat', 'أسماك', 118.0, 24.8, 0.0, 1.3, 150.0, NULL, 'usda', '171963', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'أسماك ومأكولات بحرية', 0.0, '{"iron": 1.14, "zinc": 0.51, "vit_a": 50, "vit_c": 0, "folate": 10, "vit_b6": 0.35, "calcium": 21, "vit_b12": 0.69, "magnesium": 37, "potassium": 475}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('2368b1b3-116c-4c55-ae6b-5bc8173a5f02', 'بيض كامل', 'Egg, whole, raw, fresh', 'بيض وألبان', 143.0, 12.6, 0.7, 9.5, 50.0, 'بيضة', 'usda', '171287', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'بيض', 0.0, '{"iron": 1.75, "zinc": 1.29, "vit_a": 160, "vit_c": 0, "vit_d": 2, "vit_e": 1.05, "vit_k": 0.3, "folate": 47, "vit_b6": 0.17, "calcium": 56, "vit_b12": 0.89, "magnesium": 12, "potassium": 138}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('bccafb8a-ced0-4a3e-9701-150f2e1170f2', 'بياض بيض', 'Egg, white, raw, fresh', 'بيض وألبان', 52.0, 10.9, 0.7, 0.2, 33.0, 'بياض بيضة', 'usda', '172183', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'بيض', 0.0, '{"iron": 0.08, "zinc": 0.03, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0, "vit_k": 0, "folate": 4, "vit_b6": 0.005, "calcium": 7, "vit_b12": 0.09, "magnesium": 11, "potassium": 163}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('6729f074-abc8-4d7b-a27a-616fc3f0744d', 'بيض مسلوق', 'Egg, whole, cooked, hard-boiled', 'بيض وألبان', 155.0, 12.6, 1.1, 10.6, 50.0, 'بيضة', 'usda', '173424', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'بيض', 0.0, '{"iron": 1.19, "zinc": 1.05, "vit_a": 149, "vit_c": 0, "vit_d": 2.2, "vit_e": 1.03, "vit_k": 0.3, "folate": 44, "vit_b6": 0.121, "calcium": 50, "vit_b12": 1.11, "magnesium": 10, "potassium": 126}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3bdc568f-90b1-454b-bb78-6a691b6c80d2', 'حليب كامل الدسم', 'Milk, whole, 3.25% milkfat, with added vitamin D', 'بيض وألبان', 61.0, 3.2, 4.8, 3.3, 244.0, 'كوب', 'usda', '171265', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'ألبان وأجبان', 0.0, '{"iron": 0.03, "zinc": 0.37, "vit_a": 46, "vit_c": 0, "vit_d": 1.3, "vit_e": 0.07, "vit_k": 0.3, "folate": 5, "vit_b6": 0.036, "calcium": 113, "vit_b12": 0.45, "magnesium": 10, "potassium": 132}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('420bf9cb-ed00-4ffb-89b1-3cb4a5b15992', 'حليب قليل الدسم 1%', 'Milk, lowfat, fluid, 1% milkfat, with added vitamin A and vitamin D', 'بيض وألبان', 42.0, 3.4, 5.0, 1.0, 244.0, 'كوب', 'usda', '170872', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'ألبان وأجبان', 0.0, '{"iron": 0.03, "zinc": 0.42, "vit_a": 58, "vit_c": 0, "vit_d": 1.2, "vit_e": 0.01, "vit_k": 0.1, "folate": 5, "vit_b6": 0.037, "calcium": 125, "vit_b12": 0.47, "magnesium": 11, "potassium": 150}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('0c3ff6d1-93ef-4f1f-a714-b488acada23f', 'حليب خالي الدسم', 'Milk, nonfat, fluid, with added vitamin A and vitamin D (fat free or skim)', 'بيض وألبان', 34.0, 3.4, 5.0, 0.1, 245.0, 'كوب', 'usda', '171269', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'ألبان وأجبان', 0.0, '{"iron": 0.03, "zinc": 0.42, "vit_a": 61, "vit_c": 0, "vit_d": 1.2, "vit_e": 0.01, "vit_k": 0, "folate": 5, "vit_b6": 0.037, "calcium": 122, "vit_b12": 0.5, "magnesium": 11, "potassium": 156}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d54528f8-66e4-4dfd-a417-8126f37373fa', 'زبادي كامل الدسم', 'Yogurt, plain, whole milk', 'بيض وألبان', 61.0, 3.5, 4.7, 3.3, 170.0, NULL, 'usda', '171284', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'ألبان وأجبان', 0.0, '{"iron": 0.05, "zinc": 0.59, "vit_a": 27, "vit_c": 0.5, "vit_d": 0.1, "vit_e": 0.06, "vit_k": 0.2, "folate": 7, "vit_b6": 0.032, "calcium": 121, "vit_b12": 0.37, "magnesium": 12, "potassium": 155}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('5d1cca5e-4c47-4548-94e9-a31b8b630013', 'زبادي قليل الدسم', 'Yogurt, plain, low fat', 'بيض وألبان', 63.0, 5.3, 7.0, 1.6, 170.0, NULL, 'usda', '170886', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'ألبان وأجبان', 0.0, '{"iron": 0.08, "zinc": 0.89, "vit_a": 14, "vit_c": 0.8, "vit_d": 0, "vit_e": 0.03, "vit_k": 0.2, "folate": 11, "vit_b6": 0.049, "calcium": 183, "vit_b12": 0.56, "magnesium": 17, "potassium": 234}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('348da5e6-65c1-4a88-b795-f32455be9b2e', 'زبادي يوناني قليل الدسم', 'Yogurt, Greek, plain, lowfat', 'بيض وألبان', 73.0, 10.0, 3.9, 1.9, 170.0, NULL, 'usda', '170903', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'ألبان وأجبان', 0.0, '{"iron": 0.04, "zinc": 0.6, "vit_a": 90, "vit_c": 0.8, "vit_d": 0, "vit_e": 0.04, "vit_k": 0.2, "folate": 12, "vit_b6": 0.055, "calcium": 115, "vit_b12": 0.52, "magnesium": 11, "potassium": 141}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('4c0ae90f-a5a1-4e5f-add9-c8d305341c56', 'زبادي يوناني خالي الدسم', 'Yogurt, Greek, plain, nonfat (Includes foods for USDA''s Food Distribution Program)', 'بيض وألبان', 59.0, 10.2, 3.6, 0.4, 170.0, NULL, 'usda', '170894', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'ألبان وأجبان', 0.0, '{"iron": 0.07, "zinc": 0.52, "vit_a": 1, "vit_c": 0, "vit_d": 0, "vit_e": 0.01, "vit_k": 0, "folate": 7, "vit_b6": 0.063, "calcium": 110, "vit_b12": 0.75, "magnesium": 11, "potassium": 141}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('84279cdc-f559-4383-91c4-ea960b8c1de5', 'جبنة قريش (كوتج)', 'Cheese, cottage, lowfat, 2% milkfat', 'بيض وألبان', 81.0, 10.5, 4.8, 2.3, 113.0, 'نص كوب', 'usda', '172182', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'ألبان وأجبان', 0.0, '{"iron": 0.13, "zinc": 0.51, "vit_a": 68, "vit_c": 0, "vit_d": 0, "vit_e": 0.08, "vit_k": 0, "folate": 8, "vit_b6": 0.057, "calcium": 111, "vit_b12": 0.47, "magnesium": 9, "potassium": 125}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('d163a8d1-79e8-40b7-9736-c3d31fd9393e', 'جبنة موزاريلا قليلة الدسم', 'Cheese, mozzarella, part skim milk', 'بيض وألبان', 254.0, 24.3, 2.8, 15.9, 28.0, NULL, 'usda', '170847', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'ألبان وأجبان', 0.0, '{"iron": 0.22, "zinc": 2.76, "vit_a": 127, "vit_c": 0, "vit_d": 0.3, "vit_e": 0.14, "vit_k": 1.6, "folate": 9, "vit_b6": 0.07, "calcium": 782, "vit_b12": 0.82, "magnesium": 23, "potassium": 84}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a21ffb17-ea7a-4731-976e-16a2ef44f01b', 'جبنة شيدر', 'Cheese, cheddar (Includes foods for USDA''s Food Distribution Program)', 'بيض وألبان', 403.0, 22.9, 3.4, 33.3, 28.0, 'شريحة', 'usda', '173414', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'ألبان وأجبان', 0.0, '{"iron": 0.14, "zinc": 3.64, "vit_a": 337, "vit_c": 0, "vit_d": 0.6, "vit_e": 0.71, "vit_k": 2.4, "folate": 27, "vit_b6": 0.066, "calcium": 710, "vit_b12": 1.1, "magnesium": 27, "potassium": 76}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('977c8dd0-adaa-49fd-a157-460eb7102d8d', 'جبنة فيتا', 'Cheese, feta', 'بيض وألبان', 265.0, 14.2, 3.9, 21.5, 28.0, NULL, 'usda', '173420', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'ألبان وأجبان', 0.0, '{"iron": 0.65, "zinc": 2.88, "vit_a": 125, "vit_c": 0, "vit_d": 0.4, "vit_e": 0.18, "vit_k": 1.8, "folate": 32, "vit_b6": 0.424, "calcium": 493, "vit_b12": 1.69, "magnesium": 19, "potassium": 62}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a4fad67d-0cc9-493d-9739-37051635ba22', 'جبنة كريمية', 'Cheese, cream', 'بيض وألبان', 350.0, 6.2, 5.5, 34.4, 30.0, NULL, 'usda', '173418', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'ألبان وأجبان', 0.0, '{"iron": 0.11, "zinc": 0.5, "vit_a": 308, "vit_c": 0, "vit_d": 0, "vit_e": 0.86, "vit_k": 2.1, "folate": 9, "vit_b6": 0.056, "calcium": 97, "vit_b12": 0.22, "magnesium": 9, "potassium": 132}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('f3df80bd-6728-4a1c-af79-b4ac1b577d40', 'واي بروتين', 'Beverages, Whey protein powder isolate', 'مكملات', 359.0, 58.1, 29.1, 1.2, 30.0, 'سكوب', 'usda', '173177', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'مكملات', 0.0, '{"iron": 1.26, "zinc": 8.72, "vit_a": 872, "vit_c": 34.9, "vit_d": 0, "vit_e": 7.85, "vit_k": 46.5, "folate": 395, "vit_b6": 1.163, "calcium": 698, "vit_b12": 3.49, "magnesium": 233, "potassium": 872}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('52d75e82-3511-48c9-8aee-3890f15f1ef4', 'عدس مطبوخ', 'Lentils, mature seeds, cooked, boiled, without salt', 'بقوليات', 116.0, 9.0, 20.1, 0.4, 150.0, NULL, 'usda', '172421', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'بقوليات', 7.9, '{"iron": 3.33, "zinc": 1.27, "vit_a": 0, "vit_c": 1.5, "vit_d": 0, "vit_e": 0.11, "vit_k": 1.7, "folate": 181, "vit_b6": 0.178, "calcium": 19, "vit_b12": 0, "magnesium": 36, "potassium": 369}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('58e415aa-ae1c-4bfc-9d19-7c91666d79a0', 'حمص مطبوخ', 'Chickpeas (garbanzo beans, bengal gram), mature seeds, cooked, boiled, without salt', 'بقوليات', 164.0, 8.9, 27.4, 2.6, 150.0, NULL, 'usda', '173757', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'بقوليات', 7.6, '{"iron": 2.89, "zinc": 1.53, "vit_a": 1, "vit_c": 1.3, "vit_d": 0, "vit_e": 0.35, "vit_k": 4, "folate": 172, "vit_b6": 0.139, "calcium": 49, "vit_b12": 0, "magnesium": 48, "potassium": 291}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('be0118f5-45ae-4301-97e6-285da6e37945', 'فول مدمس (مطبوخ)', 'Broadbeans (fava beans), mature seeds, cooked, boiled, without salt', 'بقوليات', 110.0, 7.6, 19.7, 0.4, 150.0, NULL, 'usda', '173753', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'بقوليات', 5.4, '{"iron": 1.5, "zinc": 1.01, "vit_a": 1, "vit_c": 0.3, "vit_d": 0, "vit_e": 0.02, "vit_k": 2.9, "folate": 104, "vit_b6": 0.072, "calcium": 36, "vit_b12": 0, "magnesium": 43, "potassium": 268}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('bb29a001-f830-4a21-b2ac-e65210c6e464', 'فاصوليا حمراء مطبوخة', 'Beans, kidney, all types, mature seeds, cooked, boiled, without salt', 'بقوليات', 127.0, 8.7, 22.8, 0.5, 150.0, NULL, 'usda', '173740', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'بقوليات', 6.4, '{"iron": 2.22, "zinc": 1, "vit_a": 0, "vit_c": 1.2, "vit_d": 0, "vit_e": 0.03, "vit_k": 8.4, "folate": 130, "vit_b6": 0.12, "calcium": 35, "vit_b12": 0, "magnesium": 42, "potassium": 405}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('0f5fae89-4ec3-40c0-a392-75d6aac9a8e8', 'حمص بطحينة (حمص جاهز)', 'Hummus, commercial', 'بقوليات', 237.0, 7.8, 15.0, 17.8, 60.0, NULL, 'usda', '174289', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'بقوليات', 5.5, '{"iron": 2.54, "zinc": 1.44, "vit_a": 1, "vit_c": 0, "vit_d": 0, "vit_e": 1.54, "vit_k": 22.8, "folate": 48, "vit_b6": 0.146, "calcium": 47, "vit_b12": 0, "magnesium": 75, "potassium": 312}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('34c913b3-2475-4669-b0e6-af06ed670768', 'تمر مجدول', 'Dates, medjool', 'فواكه', 277.0, 1.8, 75.0, 0.2, 24.0, 'حبة', 'usda', '168191', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'فواكه', 6.7, '{"iron": 0.9, "zinc": 0.44, "vit_a": 7, "vit_c": 0, "vit_d": 0, "vit_k": 2.7, "folate": 15, "vit_b6": 0.249, "calcium": 64, "magnesium": 54, "potassium": 696}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('485fa169-4b11-4a3c-a849-dda2ec9e1700', 'تمر (دقلة نور)', 'Dates, deglet noor', 'فواكه', 282.0, 2.5, 75.0, 0.4, 7.0, 'حبة', 'usda', '171726', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'فواكه', 8.0, '{"iron": 1.02, "zinc": 0.29, "vit_a": 0, "vit_c": 0.4, "vit_d": 0, "vit_e": 0.05, "vit_k": 2.7, "folate": 19, "vit_b6": 0.165, "calcium": 39, "vit_b12": 0, "magnesium": 43, "potassium": 656}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('713ff34b-2eaa-40ad-a429-48f5625b6864', 'موز', 'Bananas, raw', 'فواكه', 89.0, 1.1, 22.8, 0.3, 118.0, 'حبة وسط', 'usda', '173944', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'فواكه', 2.6, '{"iron": 0.26, "zinc": 0.15, "vit_a": 3, "vit_c": 8.7, "vit_d": 0, "vit_e": 0.1, "vit_k": 0.5, "folate": 20, "vit_b6": 0.367, "calcium": 5, "vit_b12": 0, "magnesium": 27, "potassium": 358}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('137b4c70-1933-42b7-8f60-c0445ef4facd', 'تفاح', 'Apples, raw, with skin (Includes foods for USDA''s Food Distribution Program)', 'فواكه', 52.0, 0.3, 13.8, 0.2, 182.0, 'حبة وسط', 'usda', '171688', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'فواكه', 2.4, '{"iron": 0.12, "zinc": 0.04, "vit_a": 3, "vit_c": 4.6, "vit_d": 0, "vit_e": 0.18, "vit_k": 2.2, "folate": 3, "vit_b6": 0.041, "calcium": 6, "vit_b12": 0, "magnesium": 5, "potassium": 107}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('deb6f618-fd08-4c58-ab0f-41252f9ed088', 'برتقال', 'Oranges, raw, all commercial varieties', 'فواكه', 47.0, 0.9, 11.8, 0.1, 131.0, 'حبة', 'usda', '169097', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'فواكه', 2.4, '{"iron": 0.1, "zinc": 0.07, "vit_a": 11, "vit_c": 53.2, "vit_d": 0, "vit_e": 0.18, "vit_k": 0, "folate": 30, "vit_b6": 0.06, "calcium": 40, "vit_b12": 0, "magnesium": 10, "potassium": 181}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('e2ecd2ee-5079-4177-82f6-1b71df9b0795', 'فراولة', 'Strawberries, raw', 'فواكه', 32.0, 0.7, 7.7, 0.3, 150.0, 'كوب', 'usda', '167762', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'فواكه', 2.0, '{"iron": 0.41, "zinc": 0.14, "vit_a": 1, "vit_c": 58.8, "vit_d": 0, "vit_e": 0.29, "vit_k": 2.2, "folate": 24, "vit_b6": 0.047, "calcium": 16, "vit_b12": 0, "magnesium": 13, "potassium": 153}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('92203732-a86e-4976-b07e-aeb9a8d98f93', 'عنب', 'Grapes, red or green (European type, such as Thompson seedless), raw', 'فواكه', 69.0, 0.7, 18.1, 0.2, 150.0, 'كوب', 'usda', '174683', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'فواكه', 0.9, '{"iron": 0.36, "zinc": 0.07, "vit_a": 3, "vit_c": 3.2, "vit_d": 0, "vit_e": 0.19, "vit_k": 14.6, "folate": 2, "vit_b6": 0.086, "calcium": 10, "vit_b12": 0, "magnesium": 7, "potassium": 191}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('aa042c81-7bac-470d-8d5c-6bffbf12ac9b', 'بطيخ', 'Watermelon, raw', 'فواكه', 30.0, 0.6, 7.6, 0.2, 280.0, 'كوب ونص', 'usda', '167765', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'فواكه', 0.4, '{"iron": 0.24, "zinc": 0.1, "vit_a": 28, "vit_c": 8.1, "vit_d": 0, "vit_e": 0.05, "vit_k": 0.1, "folate": 3, "vit_b6": 0.045, "calcium": 7, "vit_b12": 0, "magnesium": 10, "potassium": 112}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('a7b54343-5752-4ca9-94c5-89ec0ea7e397', 'مانجو', 'Mangos, raw', 'فواكه', 60.0, 0.8, 15.0, 0.4, 165.0, 'كوب', 'usda', '169910', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'فواكه', 1.6, '{"iron": 0.16, "zinc": 0.09, "vit_a": 54, "vit_c": 36.4, "vit_d": 0, "vit_e": 0.9, "vit_k": 4.2, "folate": 43, "vit_b6": 0.119, "calcium": 11, "vit_b12": 0, "magnesium": 10, "potassium": 168}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('1eb0d366-b220-4107-a2c6-cd177e8cea5b', 'أناناس', 'Pineapple, raw, all varieties', 'فواكه', 50.0, 0.5, 13.1, 0.1, 165.0, 'كوب', 'usda', '169124', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'فواكه', 1.4, '{"iron": 0.29, "zinc": 0.12, "vit_a": 3, "vit_c": 47.8, "vit_d": 0, "vit_e": 0.02, "vit_k": 0.7, "folate": 18, "vit_b6": 0.112, "calcium": 13, "vit_b12": 0, "magnesium": 12, "potassium": 109}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('7b4eb627-89c4-4022-acd5-9b2e5e970984', 'توت أزرق', 'Blueberries, raw', 'فواكه', 57.0, 0.7, 14.5, 0.3, 148.0, 'كوب', 'usda', '171711', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'فواكه', 2.4, '{"iron": 0.28, "zinc": 0.16, "vit_a": 3, "vit_c": 9.7, "vit_d": 0, "vit_e": 0.57, "vit_k": 19.3, "folate": 6, "vit_b6": 0.052, "calcium": 6, "vit_b12": 0, "magnesium": 6, "potassium": 77}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('310c25f4-97da-4142-93fd-1de478caa5ce', 'كيوي', 'Kiwifruit, green, raw', 'فواكه', 61.0, 1.1, 14.7, 0.5, 75.0, 'حبة', 'usda', '168153', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'فواكه', 3.0, '{"iron": 0.31, "zinc": 0.14, "vit_a": 4, "vit_c": 92.7, "vit_d": 0, "vit_e": 1.46, "vit_k": 40.3, "folate": 25, "vit_b6": 0.063, "calcium": 34, "vit_b12": 0, "magnesium": 17, "potassium": 312}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('1d8f6a81-8a03-43f7-80b4-ac7f8a30ceff', 'رمان', 'Pomegranates, raw', 'فواكه', 83.0, 1.7, 18.7, 1.2, 87.0, 'نص كوب حبوب', 'usda', '169134', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'فواكه', 4.0, '{"iron": 0.3, "zinc": 0.35, "vit_a": 0, "vit_c": 10.2, "vit_d": 0, "vit_e": 0.6, "vit_k": 16.4, "folate": 38, "vit_b6": 0.075, "calcium": 10, "vit_b12": 0, "magnesium": 12, "potassium": 236}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('cb49794d-028d-471f-b787-ef3331361688', 'خيار', 'Cucumber, with peel, raw', 'خضار', 15.0, 0.7, 3.6, 0.1, 100.0, NULL, 'usda', '168409', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'خضار', 0.5, '{"iron": 0.28, "zinc": 0.2, "vit_a": 5, "vit_c": 2.8, "vit_d": 0, "vit_e": 0.03, "vit_k": 16.4, "folate": 7, "vit_b6": 0.04, "calcium": 16, "vit_b12": 0, "magnesium": 13, "potassium": 147}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('5dee18fd-5910-4486-989c-628700cb18f2', 'طماطم', 'Tomatoes, red, ripe, raw, year round average', 'خضار', 18.0, 0.9, 3.9, 0.2, 120.0, 'حبة وسط', 'usda', '170457', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'خضار', 1.2, '{"iron": 0.27, "zinc": 0.17, "vit_a": 42, "vit_c": 13.7, "vit_d": 0, "vit_e": 0.54, "vit_k": 7.9, "folate": 15, "vit_b6": 0.08, "calcium": 10, "vit_b12": 0, "magnesium": 11, "potassium": 237}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('6e27c348-ee0c-4232-a541-4d4018d55aa8', 'خس', 'Lettuce, cos or romaine, raw', 'خضار', 17.0, 1.2, 3.3, 0.3, 50.0, NULL, 'usda', '169247', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'خضار', 2.1, '{"iron": 0.97, "zinc": 0.23, "vit_a": 436, "vit_c": 4, "vit_d": 0, "vit_e": 0.13, "vit_k": 102.5, "folate": 136, "vit_b6": 0.074, "calcium": 33, "vit_b12": 0, "magnesium": 14, "potassium": 247}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('571e53da-4a65-4b33-a743-e716f2f1f1d7', 'جزر', 'Carrots, raw', 'خضار', 41.0, 0.9, 9.6, 0.2, 60.0, 'حبة', 'usda', '170393', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'خضار', 2.8, '{"iron": 0.3, "zinc": 0.24, "vit_a": 835, "vit_c": 5.9, "vit_d": 0, "vit_e": 0.66, "vit_k": 13.2, "folate": 19, "vit_b6": 0.138, "calcium": 33, "vit_b12": 0, "magnesium": 12, "potassium": 320}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('5b42c6f7-2c7c-4b2d-8326-5db7b3788f62', 'بروكلي مطبوخ', 'Broccoli, cooked, boiled, drained, without salt', 'خضار', 35.0, 2.4, 7.2, 0.4, 90.0, NULL, 'usda', '169967', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'خضار', 3.3, '{"iron": 0.67, "zinc": 0.45, "vit_a": 77, "vit_c": 64.9, "vit_d": 0, "vit_e": 1.45, "vit_k": 141.1, "folate": 108, "vit_b6": 0.2, "calcium": 40, "vit_b12": 0, "magnesium": 21, "potassium": 293}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('30f15f48-bb4e-40a2-84ef-a6232bfddc30', 'سبانخ', 'Spinach, raw', 'خضار', 23.0, 2.9, 3.6, 0.4, 30.0, 'كوب', 'usda', '168462', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'خضار', 2.2, '{"iron": 2.71, "zinc": 0.53, "vit_a": 469, "vit_c": 28.1, "vit_d": 0, "vit_e": 2.03, "vit_k": 482.9, "folate": 194, "vit_b6": 0.195, "calcium": 99, "vit_b12": 0, "magnesium": 79, "potassium": 558}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('1b6da911-4d2a-4899-bec8-ceb2b04a7e76', 'فلفل رومي أحمر', 'Peppers, sweet, red, raw', 'خضار', 26.0, 1.0, 6.0, 0.3, 120.0, 'حبة', 'usda', '170108', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'خضار', 2.1, '{"iron": 0.43, "zinc": 0.25, "vit_a": 157, "vit_c": 127.7, "vit_d": 0, "vit_e": 1.58, "vit_k": 4.9, "folate": 46, "vit_b6": 0.291, "calcium": 7, "vit_b12": 0, "magnesium": 12, "potassium": 211}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('25c99e8a-9b9c-4be3-9bd6-37d666687d5f', 'بصل', 'Onions, raw', 'خضار', 40.0, 1.1, 9.3, 0.1, 110.0, 'حبة وسط', 'usda', '170000', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'خضار', 1.7, '{"iron": 0.21, "zinc": 0.17, "vit_a": 0, "vit_c": 7.4, "vit_d": 0, "vit_e": 0.02, "vit_k": 0.4, "folate": 19, "vit_b6": 0.12, "calcium": 23, "vit_b12": 0, "magnesium": 10, "potassium": 146}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('bcd0dbf1-6ff3-4e67-aa15-2dfede8f4dad', 'فطر (مشروم)', 'Mushrooms, white, raw', 'خضار', 22.0, 3.1, 3.3, 0.3, 70.0, 'كوب', 'usda', '169251', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'خضار', 1.0, '{"iron": 0.5, "zinc": 0.52, "vit_a": 0, "vit_c": 2.1, "vit_d": 0.2, "vit_e": 0.01, "vit_k": 0, "folate": 17, "vit_b6": 0.104, "calcium": 3, "vit_b12": 0.04, "magnesium": 9, "potassium": 318}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('63e1668b-d9ab-4e94-8545-58398734fb32', 'كوسا مطبوخة', 'Squash, summer, zucchini, includes skin, cooked, boiled, drained, without salt', 'خضار', 15.0, 1.1, 2.7, 0.4, 180.0, NULL, 'usda', '169292', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'خضار', 1.0, '{"iron": 0.37, "zinc": 0.33, "vit_a": 56, "vit_c": 12.9, "vit_d": 0, "vit_e": 0.12, "vit_k": 4.2, "folate": 28, "vit_b6": 0.08, "calcium": 18, "vit_b12": 0, "magnesium": 19, "potassium": 264}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('8679959a-f020-43af-a45f-7a59f7ff3627', 'باذنجان مطبوخ', 'Eggplant, cooked, boiled, drained, without salt', 'خضار', 35.0, 0.8, 8.7, 0.2, 100.0, NULL, 'usda', '169229', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'خضار', 2.5, '{"iron": 0.25, "zinc": 0.12, "vit_a": 2, "vit_c": 1.3, "vit_d": 0, "vit_e": 0.41, "vit_k": 2.9, "folate": 14, "vit_b6": 0.086, "calcium": 6, "vit_b12": 0, "magnesium": 11, "potassium": 123}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('64db9f51-3faf-4985-b78c-8c116acf9efc', 'ذرة حلوة مطبوخة', 'Corn, sweet, yellow, cooked, boiled, drained, without salt', 'خضار', 96.0, 3.4, 21.0, 1.5, 150.0, NULL, 'usda', '169999', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'خضار نشوية', 2.4, '{"iron": 0.45, "zinc": 0.62, "vit_a": 13, "vit_c": 5.5, "vit_d": 0, "vit_e": 0.09, "vit_k": 0.4, "folate": 23, "vit_b6": 0.139, "calcium": 3, "vit_b12": 0, "magnesium": 26, "potassium": 218}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('6c4877d6-eba7-4ccd-9658-051203b171bc', 'أفوكادو', 'Avocados, raw, all commercial varieties', 'دهون ومكسرات', 160.0, 2.0, 8.5, 14.7, 50.0, 'ثلث حبة', 'usda', '171705', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'فواكه', 6.7, '{"iron": 0.55, "zinc": 0.64, "vit_a": 7, "vit_c": 10, "vit_d": 0, "vit_e": 2.07, "vit_k": 21, "folate": 81, "vit_b6": 0.257, "calcium": 12, "vit_b12": 0, "magnesium": 29, "potassium": 485}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('315cf871-55d2-48bc-8654-5313612217a0', 'زيت زيتون', 'Oil, olive, salad or cooking', 'دهون ومكسرات', 884.0, 0.0, 0.0, 100.0, 5.0, 'ملعقة صغيرة', 'usda', '171413', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'دهون وزيوت', 0.0, '{"iron": 0.56, "zinc": 0, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 14.35, "vit_k": 60.2, "folate": 0, "vit_b6": 0, "calcium": 1, "vit_b12": 0, "magnesium": 0, "potassium": 1}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('fd88e19b-bbab-4dc1-9068-478f2c1aca99', 'زبدة', 'Butter, salted', 'دهون ومكسرات', 717.0, 0.9, 0.1, 81.1, 5.0, 'ملعقة صغيرة', 'usda', '173410', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'دهون وزيوت', 0.0, '{"iron": 0.02, "zinc": 0.09, "vit_a": 684, "vit_c": 0, "vit_d": 0, "vit_e": 2.32, "vit_k": 7, "folate": 3, "vit_b6": 0.003, "calcium": 24, "vit_b12": 0.17, "magnesium": 2, "potassium": 24}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('651773d6-81f5-4c3e-a1d5-f6429d976af8', 'لوز', 'Nuts, almonds', 'دهون ومكسرات', 579.0, 21.2, 21.6, 49.9, 28.0, 'حفنة', 'usda', '170567', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'مكسرات وبذور', 12.5, '{"iron": 3.71, "zinc": 3.12, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 25.63, "vit_k": 0, "folate": 44, "vit_b6": 0.137, "calcium": 269, "vit_b12": 0, "magnesium": 270, "potassium": 733}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('199d5139-3b28-4372-a4e4-6d3e36bc5eab', 'كاجو', 'Nuts, cashew nuts, raw', 'دهون ومكسرات', 553.0, 18.2, 30.2, 43.9, 28.0, 'حفنة', 'usda', '170162', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'مكسرات وبذور', 3.3, '{"iron": 6.68, "zinc": 5.78, "vit_a": 0, "vit_c": 0.5, "vit_d": 0, "vit_e": 0.9, "vit_k": 34.1, "folate": 25, "vit_b6": 0.417, "calcium": 37, "vit_b12": 0, "magnesium": 292, "potassium": 660}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('3bc825c4-9db3-4dd5-91cc-eeaaffd2e0df', 'فستق حلبي', 'Nuts, pistachio nuts, raw', 'دهون ومكسرات', 560.0, 20.2, 27.2, 45.3, 28.0, 'حفنة', 'usda', '170184', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'مكسرات وبذور', 10.6, '{"iron": 3.92, "zinc": 2.2, "vit_a": 26, "vit_c": 5.6, "vit_d": 0, "vit_e": 2.86, "folate": 51, "vit_b6": 1.7, "calcium": 105, "vit_b12": 0, "magnesium": 121, "potassium": 1025}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('e59410f4-d2c9-4592-9b1c-8cb27909ef0e', 'جوز (عين الجمل)', 'Nuts, walnuts, english', 'دهون ومكسرات', 654.0, 15.2, 13.7, 65.2, 28.0, 'حفنة', 'usda', '170187', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'مكسرات وبذور', 6.7, '{"iron": 2.91, "zinc": 3.09, "vit_a": 1, "vit_c": 1.3, "vit_d": 0, "vit_e": 0.7, "vit_k": 2.7, "folate": 98, "vit_b6": 0.537, "calcium": 98, "vit_b12": 0, "magnesium": 158, "potassium": 441}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('ca748844-fbf8-483d-9e14-25003a7e1c36', 'زبدة فول سوداني', 'Peanut butter, smooth style, without salt', 'دهون ومكسرات', 598.0, 22.2, 22.3, 51.4, 16.0, 'ملعقة كبيرة', 'usda', '172470', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'مكسرات وبذور', 5.0, '{"iron": 1.74, "zinc": 2.51, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 9.1, "vit_k": 0.3, "folate": 87, "vit_b6": 0.441, "calcium": 49, "vit_b12": 0, "magnesium": 168, "potassium": 558}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('816c5bb9-7954-407e-b84b-be939ad80a9f', 'فول سوداني', 'Peanuts, all types, raw', 'دهون ومكسرات', 567.0, 25.8, 16.1, 49.2, 28.0, 'حفنة', 'usda', '172430', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'مكسرات وبذور', 8.5, '{"iron": 4.58, "zinc": 3.27, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 8.33, "vit_k": 0, "folate": 240, "vit_b6": 0.348, "calcium": 92, "vit_b12": 0, "magnesium": 168, "potassium": 705}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('35d16e14-8014-4491-9e02-bc303b45520a', 'طحينة', 'Seeds, sesame butter, tahini, from roasted and toasted kernels (most common type)', 'دهون ومكسرات', 595.0, 17.0, 21.2, 53.8, 15.0, 'ملعقة كبيرة', 'usda', '170189', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'مكسرات وبذور', 9.3, '{"iron": 8.95, "zinc": 4.62, "vit_a": 3, "vit_c": 0, "vit_d": 0, "vit_e": 0.25, "vit_k": 0, "folate": 98, "vit_b6": 0.149, "calcium": 426, "vit_b12": 0, "magnesium": 95, "potassium": 414}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('1f9c2e64-0c43-45e4-ba4e-6e84a2775cc1', 'بذور الشيا', 'Seeds, chia seeds, dried', 'دهون ومكسرات', 486.0, 16.5, 42.1, 30.7, 12.0, 'ملعقة كبيرة', 'usda', '170554', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'مكسرات وبذور', 34.4, '{"iron": 7.72, "zinc": 4.58, "vit_c": 1.6, "vit_e": 0.5, "calcium": 631, "vit_b12": 0, "magnesium": 335, "potassium": 407}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('9e28f170-0fab-412d-bb19-f0bda5082395', 'عسل', 'Honey', 'حلويات ومشروبات', 304.0, 0.3, 82.4, 0.0, 21.0, 'ملعقة كبيرة', 'usda', '169640', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'حلويات ومحليات', 0.2, '{"iron": 0.42, "zinc": 0.22, "vit_a": 0, "vit_c": 0.5, "vit_d": 0, "vit_e": 0, "vit_k": 0, "folate": 2, "vit_b6": 0.024, "calcium": 6, "vit_b12": 0, "magnesium": 2, "potassium": 52}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('eb2e39dc-08a5-49b7-9924-4d0d47345e1a', 'سكر أبيض', 'Sugars, granulated', 'حلويات ومشروبات', 387.0, 0.0, 100.0, 0.0, 4.0, 'ملعقة صغيرة', 'usda', '169655', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'حلويات ومحليات', 0.0, '{"iron": 0.05, "zinc": 0.01, "vit_a": 0, "vit_c": 0, "vit_d": 0, "vit_e": 0, "vit_k": 0, "folate": 0, "vit_b6": 0, "calcium": 1, "vit_b12": 0, "magnesium": 0, "potassium": 2}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('594ac4fe-4190-4287-82aa-289a2f6f4f19', 'شوكولاتة داكنة 70-85%', 'Chocolate, dark, 70-85% cacao solids', 'حلويات ومشروبات', 598.0, 7.8, 45.9, 42.6, 20.0, NULL, 'usda', '170273', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'حلويات ومحليات', 10.9, '{"iron": 11.9, "zinc": 3.31, "vit_a": 2, "vit_e": 0.59, "vit_k": 7.3, "vit_b6": 0.038, "calcium": 73, "vit_b12": 0.28, "magnesium": 228, "potassium": 715}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('98eb1379-f098-4cdb-bb5d-7825bd0f8d87', 'عصير برتقال', 'Orange juice, raw (Includes foods for USDA''s Food Distribution Program)', 'حلويات ومشروبات', 45.0, 0.7, 10.4, 0.2, 248.0, 'كوب', 'usda', '169098', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'مشروبات', 0.2, '{"iron": 0.2, "zinc": 0.05, "vit_a": 10, "vit_c": 50, "vit_d": 0, "vit_e": 0.04, "vit_k": 0.1, "folate": 30, "vit_b6": 0.04, "calcium": 11, "vit_b12": 0, "magnesium": 11, "potassium": 200}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('b5a09cdb-68c4-4b55-87e6-6ba54e7742cf', 'مايونيز', 'Salad dressing, mayonnaise, regular', 'صوصات', 680.0, 1.0, 0.6, 74.9, 15.0, 'ملعقة كبيرة', 'usda', '171009', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'دهون وزيوت', 0.0, '{"iron": 0.21, "zinc": 0.15, "vit_a": 16, "vit_c": 0, "vit_d": 0.2, "vit_e": 3.28, "vit_k": 163, "folate": 5, "vit_b6": 0.008, "calcium": 8, "vit_b12": 0.12, "magnesium": 1, "potassium": 20}') ON CONFLICT DO NOTHING;
INSERT INTO public.foods VALUES ('c8f549e6-a942-475e-87ae-7e849f0de93f', 'كاتشب', 'Catsup', 'صوصات', 101.0, 1.0, 27.4, 0.1, 17.0, 'ملعقة كبيرة', 'usda', '168556', true, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', 'صلصات', 0.3, '{"iron": 0.35, "zinc": 0.17, "vit_a": 26, "vit_c": 4.1, "vit_d": 0, "vit_e": 1.46, "vit_k": 3, "folate": 9, "vit_b6": 0.158, "calcium": 15, "vit_b12": 0, "magnesium": 13, "potassium": 281}') ON CONFLICT DO NOTHING;



INSERT INTO public.policies VALUES ('terms', 'الشروط والأحكام', '- يبدأ الاشتراك بعد التحقق من وصول التحويل البنكي، وتعبئة استبيان المتدرب.
- ساعات العمل: الأحد – الخميس، 12 ظهراً – 9 مساءً. الرد على الرسائل خلال 48 ساعة عمل.
- البرنامج لا يغني عن الاستشارة الطبية، والمتدرب مسؤول عن الإفصاح عن أي إصابة أو حالة صحية.
- الجداول ملك المتدرب مدى الحياة ويمكنه التعديل عليها.
- الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي.', 0, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;
INSERT INTO public.policies VALUES ('refund', 'الضمان والاسترجاع', '- في اشتراكات 3 أشهر لباقات المتابعة (المكثفة، المتقدمة، الأساسية): يُسترد المبلغ كاملاً إذا لم يتحسن أي من مؤشرات التقدم (متوسط الوزن الأسبوعي، محيط الخصر، القوة في التمارين الأساسية) بعد 12 أسبوعاً.
- شروط الضمان: إرسال المراجعة الأسبوعية كل أسبوع، وأخذ القياسات بانتظام، وتصوير التمارين وإرسالها، والالتزام بجدول التغذية المخصص في الباقات التي تشملها.
- يُطلب الاسترجاع عبر واتساب خلال 14 يوماً من نهاية الأشهر الثلاثة، ويُرجع المبلغ بتحويل بنكي.
- التجديد المجاني: اشتراك 3 أشهر يُكافأ بـ 3 أشهر إضافية عند التزام 90% فأكثر وتقدم واضح في مؤشرات التقدم. صور التطور تُرسل للمدربة للتوثيق (للرجال مع تغطية الوجه والسرة)، ونشرها اختياري.', 1, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;
INSERT INTO public.policies VALUES ('privacy', 'سياسة الخصوصية', '- نجمع: الاسم، البريد الإلكتروني (للدخول إلى حسابك)، رقم الجوال (واتساب)، الباقة المختارة، ومعلومات الاستبيان التي تكتبها بنفسك (ومنها معلومات صحية وقياسات اختيارية).
- الغرض: تنفيذ طلبك، وتصميم برنامجك ومتابعتك، والتواصل معك بخصوصه فقط.
- المعلومات الصحية تُحفظ منفصلة، ولا يطّلع عليها إلا أنت والمدربة، ولا تُرسل في رسائل البريد أو التنبيهات.
- الدفع بتحويل بنكي مباشر لحساب المؤسسة، والموقع لا يطلب أو يخزن أي بيانات بنكية أو بيانات بطاقات. إيصال التحويل يُستخدم لتأكيد طلبك فقط، ويُحفظ في تخزين خاص لا يُفتح إلا لك وللمدربة.
- لا نبيع بياناتك ولا نشاركها مع أي طرف لأغراض تسويقية، ولا تُنشر نتيجتك أو صورتك إلا بموافقتك الصريحة.
- تقدر تطلب نسخة من بياناتك أو حذفها أو سحب موافقتك على النشر بمراسلتنا على واتساب.', 2, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;
INSERT INTO public.policies VALUES ('reviews', 'سياسة التقييمات', '- يكتب التقييم فقط من اشترى خدمة وبدأها فعلاً، وتقييم واحد لكل طلب.
- كل تقييم يُراجع قبل ظهوره للعامة، ولا يُعدّل نصه أبداً.
- تختار بنفسك طريقة ظهور اسمك: الاسم كامل، أو الاسم الأول فقط، أو بدون اسم. والموافقة على النشر منفصلة واختيارية.
- لا يُنشر تقييم يحتوي أرقام هواتف أو بريد أو روابط أو تفاصيل صحية خاصة أو إساءة لأي شخص.
- يحق للمدربة الرد على التقييم، أو إخفاء التقييم المخالف لهذه السياسة مع تسجيل السبب.
- تقدر تطلب إخفاء تقييمك في أي وقت بمراسلتنا على واتساب.', 3, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;



INSERT INTO public.products VALUES ('db19da10-4801-4ba5-aa51-1d07107bc2ee', 'intensive', 'follow', 'الباقة المكثفة', 'الأنسب للمبتدئين ولمن يحتاج متابعة أسبوعية مع زوم: تمرين + تغذية + زوم + جلسة حضورية', '[{"text": "جلسة حضورية مجانية لمدة ساعة لتصحيح التكنيك والتأكد من جودة التمرين (للبنات في المنطقة الشرقية)", "included": true}, {"text": "ملف شامل للخطة التدريبية والتغذية مع شروحات وافية للتمارين، بالمنزل أو بالنادي", "included": true}, {"text": "4 مكالمات زوم شهرياً نتابع فيها تطورك واستفساراتك الرياضية والنفسية", "included": true}, {"text": "مناقشة أسبوعية لتطورك البدني والنفسي (فيديو أو تسجيل صوتي) مع تعديل السعرات أو التمرين عند الحاجة", "included": true}, {"text": "شرح سهل ومبسط لتطبيق حساب السعرات MyFitnessPal", "included": true}, {"text": "كتيب شامل للرياضة والتغذية", "included": true}, {"text": "مساعدتك على اختيارات أنسب لصحتك ونمط حياتك في التغذية والروتين اليومي", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}]', NULL, 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.', true, NULL, 'published', 0, false, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('92cead07-34e8-4ee5-92cc-6f91fabbff84', 'advanced', 'follow', 'الباقة المتقدمة', 'لمن عنده خبرة ويحتاج تمرين + تغذية مع متابعة أسبوعية، بدون زوم', '[{"text": "ملف شامل للخطة التدريبية والتغذية مع شروحات وافية للتمارين، بالمنزل أو بالنادي", "included": true}, {"text": "مناقشة أسبوعية لتطورك البدني والنفسي (فيديو أو تسجيل صوتي) مع تعديل السعرات أو التمرين عند الحاجة", "included": true}, {"text": "كتيب شامل للرياضة والتغذية", "included": true}, {"text": "مساعدتك على اختيارات أنسب لصحتك ونمط حياتك في التمرين والروتين اليومي", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}, {"text": "مكالمات زوم والجلسة الحضورية (في المكثفة فقط)", "included": false}]', NULL, 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.', false, NULL, 'published', 1, false, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('024178f0-4ea4-4007-88f5-fedb56df5188', 'basic', 'follow', 'الباقة الأساسية', 'لمن يعرف يضبط أكله ويحتاج خطة تمرين فقط، ومتابعة كل أسبوعين', '[{"text": "ملف شامل للخطة التدريبية مع شروحات وافية للتمارين، بالمنزل أو بالنادي", "included": true}, {"text": "مناقشة كل أسبوعين لتطورك البدني والنفسي (فيديو أو تسجيل صوتي) مع تعديل التمرين عند الحاجة", "included": true}, {"text": "كتيب شامل للرياضة والتغذية", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}, {"text": "بدون خطة تغذية", "included": false}]', NULL, 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة لكل باقة ومدة بتحويل بنكي، ولا يوجد تجديد تلقائي. اشتراك 3 أشهر يشمله ضمان استرجاع المبلغ بشروط، والتجديد المجاني للملتزمين.', false, NULL, 'published', 2, false, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('15b52d53-849a-459a-9a43-0c9e405b600b', 'nutrition', 'follow', 'باقة التغذية', 'لمن يحتاج خطة تغذية شاملة ويتعلم حساب السعرات، بدون خطة تمرين', '[{"text": "خطة تغذية شاملة تناسب هدفك ونمط حياتك", "included": true}, {"text": "تحديد السعرات المناسبة لك ولهدفك", "included": true}, {"text": "تعليمك حسبة السعرات ومساعدتك باختيارات تغذية تناسبك", "included": true}, {"text": "ملف Excel لمتابعة التطور والقياسات", "included": true}, {"text": "مناقشة أسبوعية لعلاقتك بالتغذية في المنزل أو خارجه", "included": true}, {"text": "تواصل يومي والرد على الاستفسارات خلال 48 ساعة من ساعات العمل", "included": true}, {"text": "لا تحتاجها إذا كنت مشتركاً في المكثفة أو المتقدمة، لأن التغذية ضمنها", "included": false}]', 'شهر واحد · غالباً لا تحتاج تجديد', 'ملف برنامج مخصص بعد الاستبيان، ومراجعة منتظمة بالفيديو أو التسجيل الصوتي، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي، ولا يوجد تجديد تلقائي. ضمان الاسترجاع يشمل اشتراكات 3 أشهر للمكثفة والمتقدمة والأساسية فقط.', false, NULL, 'published', 3, false, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('e397d39a-89b8-4669-8282-1ab5486daab6', 'custom-training-plan', 'files', 'بديل التدريب الشخصي', 'لمن لا يحتاج متابعة (متقدم)، أو كبديل أوفر للتدريب الشخصي', '[{"text": "جدول تمرين مخصص لعدد أيام التمرين اللي تحتاجها", "included": true}, {"text": "طريقة حساب الجهد وعدد الجولات المطلوبة", "included": true}, {"text": "تقدر تحمّل الجدول على جهازك", "included": true}]', NULL, 'جدول مخصص بعد الاستبيان تستلمه كملف، وتقدر تحمّله على جهازك. بدون متابعة.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي. الجداول لك مدى الحياة وتقدر تعدّل عليها.', false, NULL, 'published', 4, false, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('38db4fae-fdd7-41bb-be06-27576b29a66e', 'training-nutrition-plan', 'files', 'جدول تمارين مع التغذية', 'لمن لا يحتاج متابعة (متقدم)، أو كبديل أوفر للتدريب الشخصي', '[{"text": "جدول تمرين مخصص لعدد أيام التمرين اللي تحتاجها", "included": true}, {"text": "طريقة حساب الجهد وعدد الجولات المطلوبة", "included": true}, {"text": "جدول تغذية فيه خيارات تناسب هدفك الرياضي", "included": true}, {"text": "تقدر تحمّل الجدول على جهازك", "included": true}]', NULL, 'جدول مخصص بعد الاستبيان تستلمه كملف، وتقدر تحمّله على جهازك. بدون متابعة.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي. الجداول لك مدى الحياة وتقدر تعدّل عليها.', false, NULL, 'published', 5, false, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('a7f6c797-6ec5-4c52-b39b-8218a8081137', 'nutrition-consultation', 'consult', 'جلسة استشارة تغذية', 'لمن عنده أسئلة محددة في التغذية: جلسة وحدة تكفي لحسبة سعراتك ونصائح الأكل.', '[{"text": "مناقشة كل أسئلتك في مجال التغذية", "included": true}, {"text": "حسبة سعرات مناسبة لهدفك مع اقتراحات لأصناف الطعام", "included": true}, {"text": "نصائح في المكملات، وكيف تأكل برّا بطريقة صحيحة", "included": true}]', NULL, 'جلسة عبر Google Meet أو واتساب — المناسب لك.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي.', false, NULL, 'published', 6, false, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', false) ON CONFLICT DO NOTHING;
INSERT INTO public.products VALUES ('c577c352-e028-4804-8a73-3b2f47e436c8', 'training-consultation', 'consult', 'جلسة استشارة تمرين', 'لمن عنده أسئلة محددة في التمرين: جلسة وحدة تكفي لتعديل جدولك وتصحيح التكنيك.', '[{"text": "مناقشة كل أسئلتك في مجال التمرين", "included": true}, {"text": "تعديل جدولك الرياضي بما يناسب هدفك، مع اقتراحات لتمارين المرونة", "included": true}, {"text": "تصحيح تكنيك التمارين اللي تشك إنها غلط أو تسبب لك ألم", "included": true}, {"text": "التأكد من أن جودة تمرينك مناسبة للبناء العضلي", "included": true}]', NULL, 'جلسة عبر Google Meet أو واتساب — المناسب لك.', 'تعبئة استبيان المتدرب (5 خطوات)، ثم التحويل البنكي ورفع صورة الإيصال. يبدأ الاشتراك بعد التحقق من وصول التحويل وتعبئة الاستبيان.', 'الدفع مرة واحدة بتحويل بنكي.', false, NULL, 'published', 7, false, '2026-10-04 07:25:44.888657+00', '2026-10-04 07:25:44.888657+00', false) ON CONFLICT DO NOTHING;



INSERT INTO public.product_offers VALUES ('4b6e4ba2-3054-46ef-8fde-8cd48f2e8cf2', 'db19da10-4801-4ba5-aa51-1d07107bc2ee', 'int1', 'شهر واحد', 1, 59900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('3ff874b4-4a4e-4680-96f9-a694fea0c21c', 'db19da10-4801-4ba5-aa51-1d07107bc2ee', 'int3', '3 أشهر', 3, 155000, 'SAR', true, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('033526bb-8753-49a4-977a-7d69e6731749', '92cead07-34e8-4ee5-92cc-6f91fabbff84', 'adv1', 'شهر واحد', 1, 49900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('ea19296c-3efc-47fd-a84b-d0a0b4942a32', '92cead07-34e8-4ee5-92cc-6f91fabbff84', 'adv3', '3 أشهر', 3, 125000, 'SAR', true, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('0e2b1af2-bc17-4323-8eb2-f963011d0ade', '024178f0-4ea4-4007-88f5-fedb56df5188', 'bas1', 'شهر واحد', 1, 34900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('6f0abfdd-95a0-45ac-8b8a-9f829ca40916', '024178f0-4ea4-4007-88f5-fedb56df5188', 'bas3', '3 أشهر', 3, 95000, 'SAR', true, 1) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('104253af-ddb9-48fd-a19b-320c3b9ce8c7', '15b52d53-849a-459a-9a43-0c9e405b600b', 'nut1', 'شهر واحد', 1, 25000, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('506b76a0-083c-45f9-a0dc-a78992fc8b40', 'e397d39a-89b8-4669-8282-1ab5486daab6', 'diy', 'دفعة واحدة', 0, 19900, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('945e759a-f31a-45f4-960d-34cdc947611e', '38db4fae-fdd7-41bb-be06-27576b29a66e', 'diyN', 'دفعة واحدة', 0, 25000, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('5cf230c0-823c-4a05-8b1f-2eca2bfeb3b7', 'a7f6c797-6ec5-4c52-b39b-8218a8081137', 'cN', 'دفعة واحدة', 0, 15000, 'SAR', true, 0) ON CONFLICT DO NOTHING;
INSERT INTO public.product_offers VALUES ('ac22a374-5673-4fa0-b117-e3b2296e95dc', 'c577c352-e028-4804-8a73-3b2f47e436c8', 'cT', 'دفعة واحدة', 0, 18900, 'SAR', true, 0) ON CONFLICT DO NOTHING;



INSERT INTO public.reviews VALUES ('c5f9d64a-8eaf-4279-8d84-62927f1ed027', 'legacy', NULL, NULL, NULL, NULL, 'اشتركت معها 3 شهور وكانت أول مره التزم بالتمرين بعد سحبات سنين، اسلوبها سهل وسريع بس نتايجه واضحه من اول اسبوعين قياسات جسمي بدت تتغير والكوتش مريحه نفسيًا وشاطرة الله يعطيها العافيه غيرت حياتي واعطتني افضل بداية 🙏🏻', 'first', 'ريم', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 0, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('83bb947b-1210-4792-b9e3-2fc804479890', 'legacy', NULL, NULL, NULL, 5, 'من أصدق التجارب اللي مرّيت فيها! تدريبك ما كان بس جداول رياضه وتغذية كان دعم نفسي وتحفيز وتغيير حقيقي في حياتي حسّيت بفرق كبير في جسمي وطاقتي وثقتي بنفسي من أول أسبوع شكراً من القلب على تعبك وحرصك على كل تفصيلة وتعطي من قلبك، فعلاً you are the best coach ever تستاهلين كل النجاح والله ❤️', 'first', 'نورة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 1, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('ca119c10-578d-4a5e-8820-d013ede46289', 'legacy', NULL, NULL, NULL, 5, 'بعد شهر من الالتزام بالجدول، لاحظت فرق واضح! متنوع وفعال، أنصح فيه بشدة 😍👌', 'first', 'البندري', 'مارس 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 2, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('cfd67ee7-50c8-4b62-af5a-67223e9367bf', 'legacy', NULL, NULL, NULL, NULL, 'رغم ان فتره تدريبي معاها كانت اقل من شهرين السنه الماضيه الا ان نتايج هالشهرين مستمره معي الى اليوم 😍 اسلوب احترافي وفعال وتركز على بناء وتطوير عادات تدوم مو بس تمارين مؤقته 👍🏻', 'first', 'خديجة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 3, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('b3ad557c-6668-441f-b224-27966cb67218', 'legacy', NULL, NULL, NULL, 5, 'كوتش ساره جداً شاطره و بروفيشنال، جداً متعاونه و تعرف شغلها كويس، جداً لطيفه، كنت لفتره متدربه عندها و كنت أشوف نتايج بطله بالاضافه لكوني اروح اتمرن و أنا مستمتعه، شكراً ساره', 'first', 'نجمة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 4, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('5e6a0872-9821-42d0-88f8-04ee4b4d0d5d', 'legacy', NULL, NULL, NULL, 5, 'ممتاز جدول حلو ومرتب جدا وفرق معي كثير 🤍', 'first', 'سعود', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 5, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('86f9580f-a09c-4ac0-8fc3-c8f261c8ff56', 'legacy', NULL, NULL, NULL, 5, 'كنت اعاني من الم بظهري مستمررر سنوات وانحراف بالعمود ولكن بفضل الله ثم المدربة تحسنت بنسبة كبيرة وتابع معي خطوة بخطوة بكل أمانة وإتقان الله يكثر من امثالك 🤍', 'first', 'ش**س**', 'أغسطس 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 6, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('e090baae-630b-47d5-bc10-54a2f5d4101b', 'legacy', NULL, NULL, NULL, 5, 'الشكر يعجز عنك يااروع كوتش باشتراكي معك شفت صحة وراحة بعد الله وساعدتيني مره بمشكلة ظهري وضعف العضلات العلوية وانعكس على نفسيتي وادائي اليومي شكررا شكرا من القلب وياحظنا فيك', 'first', 'فاطمة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 7, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('bb02e45a-c84d-4f28-8e1b-b0bd0279f1da', 'legacy', NULL, NULL, NULL, 5, 'مره استفدت بالتدريب مع كوتش ناف و مبسوطه ان في احد بذمة و ضمير جالس يتابع تقدمي و ينصحني من قلب الله يسعدك ويوفقك ❤️', 'first', 'ميثاء', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 8, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('2c9b7500-cb06-4410-89ce-091b16b9608d', 'legacy', NULL, NULL, NULL, 5, 'تجربه ولا أروع ! أحب جداولها وقد ايش تختصر وتعطيك المهم والاهم والنتايج رهيييبه ❤️', 'first', 'أمجاد', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 9, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('53d464f5-7e66-4f3e-b7db-5813948bf5f9', 'legacy', NULL, NULL, NULL, 5, 'افضل مدربة بالمجرة، كنت دبه ونحفت بثلاث شهور بس، i highly recommend her she is the best 💗', 'first', 'شروق', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 10, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;
INSERT INTO public.reviews VALUES ('fc4c5451-3c08-4321-915a-6216c90772b7', 'legacy', NULL, NULL, NULL, 5, 'الجدول ممتاز و فعّال لفترة الصيام، يساعدك تنظم وقتك ويقدّم توصيات غذائيه و خطه تمارين تساعدك تحافظ على لياقتك بدون إرهاق 👍🏻. خيار ممتاز خاصة للأشخاص للي وقتها محدود ومزحوم فرمضان.', 'first', 'خديجة', 'يوليو 2025', true, NULL, 'published', NULL, NULL, NULL, NULL, 11, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;



INSERT INTO public.site_settings VALUES ('reminders', '{"review_text": "مرحباً {name}، تذكير بمراجعتك الأسبوعية: المراجعة مفتوحة من {window_start} إلى {window_end}.", "sub_expiry_days": [7, 3], "sub_expiry_text": "مرحباً {name}، اشتراكك في {product} ينتهي بتاريخ {end_date}. للتجديد أو الاستفسار تواصل معنا.", "review_lead_days": 1, "missed_review_text": "مرحباً {name}، ما وصلتنا مراجعة الأسبوع المنتهي في {window_end}. متى ما تيسّر لك، حدّثها عشان نتابع تقدمك.", "review_window_days": 2, "manual_cooldown_minutes": 10}', false, NULL, '2026-10-04 07:25:44.601209+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('hero', '{"lead": "خطة تدريب وغذاء منظمة، متابعة للتقدم، وتعديلات أسبوعية تناسب مستواك وظروفك.", "title": "برامج تدريب وتغذية مخصصة لأهدافك", "eyebrow": "Nav Coaching · الكوتش ساره", "tagline": "Where Passion Meets Quality", "title_tail": "تحت إشراف مدربة يدفعها الشغف"}', true, NULL, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('badges', '["خصم 10% للطلاب", "مجاني لأهل غزة", "ضمان استرجاع المبلغ بشروط"]', true, NULL, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('why', '[{"body": "البرنامج يُصمم بعد استبيان مفصل لهدفك وأيامك المتاحة وأدواتك وأي إصابة تحتاج مراعاة.", "title": "مبني على هدفك ومستواك"}, {"body": "مراجعة منتظمة بالفيديو أو الصوت، وتواصل يومي على واتساب مع رد خلال 48 ساعة عمل.", "title": "متابعة أسبوعية واضحة"}, {"body": "نعدّل التمرين والسعرات بناءً على قياساتك والتزامك، عشان تثبت النتيجة.", "title": "تعديلات حسب تقدمك"}]', true, NULL, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('how_steps', '[{"body": "اختر الباقة والمدة، وعبّي استبيان قصير عن هدفك ومستواك وأيامك وأي إصابة.", "title": "اختر برنامجك وعبّي الاستبيان"}, {"body": "بعد الاستبيان يظهر لك رقم طلبك وبيانات الحساب. حوّل وارفع صورة الإيصال من صفحة طلبك.", "title": "حوّل المبلغ"}, {"body": "بعد التحقق من التحويل أتواصل معك خلال 48 ساعة عمل، وتستلم ملف برنامجك وتبدأ المتابعة.", "title": "استلم برنامجك وابدأ"}]', true, NULL, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('about', '{"bio": "مدربة شخصية معتمدة، أدرب منذ 2017. أساعدك تبني روتين تدريب وتغذية واضح يناسب هدفك ووقتك ومستواك، مع متابعة أسبوعية تساعدك تستمر وتتقدم.", "fit": ["اللي يؤمن إن التمرين أسلوب حياة، مو تمرين لشكل مؤقت أو لفترة الصيف بس.", "**وإذا ما التزمت؟** أحاول أفهم أسبابك، وأساعدك تعالجها بقدر ما أقدر. وإذا كان الموضوع أكبر من اللي أقدر أقدمه، أقول لك بصراحة وأعتذر عن تدريبك."], "name": "الكوتش ساره | ناڤ", "certs": ["Saudi Reps — Level 4", "NCSF", "Menno Henselmans CPT", "Functional Mobility", "Pre & Postnatal Training", "Prenatal Fitness Training — Aspire Academy", "ماجستير تدريب رياضي — جامعة ستيرلنق"], "notes": [{"body": "لأني جاية من عالم الرياضات الإلكترونية، صممت باقة خاصة للقيمرز: لياقة أفضل داخل وخارج الشاشة، والتعامل مع آلام الظهر والمفاصل من الجلوس الطويل.", "href": "/programs/gamers", "label": "شوف باقة القيمرز ←", "title": "للاعبي الألعاب الإلكترونية"}, {"body": "تدريب الحوامل عندي حضوري فقط. أونلاين يصعب أتأكد إن التمرين يتنفذ بإتقان، والحمل فترة مهمة جداً تحتاج هالتأكد. أونلاين أقدم للحوامل متابعة التغذية فقط.", "href": "", "label": "", "title": "للحوامل"}], "story": ["قبل ما أصير مدربة، كنت متدربة تعبت من التجارب. اشتركت مع مدربات أجانب، وما لقيت أحد يشرح لي التمرين صح أو يهتم بأهدافي.", "لين اشتركت مع الكوتش سحر الحارثي. غيّرت نظرتي للتمرين، وحفّزتني أصير كوتش، وإلى اليوم أشكرها على كل اللي علمتني إياه. من هنا قررت أكون الشخص اللي احتجته أنا.", "والرياضة جزء مني من بدري: لعبت كرة السلة وكنت كابتن فريق السلة في جامعة الإمام عبدالرحمن بن فيصل، ولعبت باحتراف في الرياضات الإلكترونية. بدأت التدريب في 2017 مع كرة السلة، واشتغلت مساعد مدرب في نادي الجامعة، وبعدها دربت في بيور جم وجمنيشن وفتنس لاونج ونوادي خاصة."], "points": ["برنامج مبني على هدفك ومستواك.", "متابعة أسبوعية واضحة.", "تعديلات مستمرة حسب تقدمك والتزامك."], "pillars": [{"body": "ما أرسل لك جدول وأتركك. أراجعه معك بمقطع فيديو أشرح فيه كل شي، عشان تبدأ وأنت فاهم وش تسوي وليش.", "title": "جدولك مشروح بالفيديو"}, {"body": "ما أمشي على أنظمة الحرمان أبداً. خطتك تناسب حياتك، مو قائمة ممنوعات.", "title": "بدون حرمان"}, {"body": "أتابعك كل أسبوع وأهتم بالتزامك، وأعدّل خطتك حسب تقدمك وظروفك.", "title": "متابعة جادة وخطة واقعية"}, {"body": "حب تعليم الناس معي من الصغر. اللي أعرفه ما أبخل فيه، علمياً ونفسياً، وما أوقف عن البحث والتعلم عشان أتطور وأطورك معي.", "title": "أعلّمك، مو بس أدربك"}], "home_bio": "مدربة شخصية معتمدة، أدرب منذ 2017، وكابتن سابقة لفريق السلة في جامعة الإمام عبدالرحمن بن فيصل. أساعدك تبني روتين تدريب وتغذية واضح يناسب هدفك ووقتك ومستواك، مع متابعة أسبوعية وبدون أنظمة حرمان.", "fit_title": "أكثر شخص أفرق معه", "experience": ["أدرب منذ 2017، والبداية في كرة السلة.", "مساعد مدرب في نادي الجامعة.", "مدربة في بيور جم، وجمنيشن، وفتنس لاونج، ونوادي خاصة."], "story_title": "صرت الشخص اللي كنت أحتاجه", "pillars_title": "وش يميز التدريب معي؟", "experience_title": "شهاداتي وخبرتي"}', true, NULL, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('intro_video', '{"url": "", "body": "مقطع قصير أتكلم فيه عن نفسي وخلفيتي وطريقة شغلي مع المتدربين.", "title": "تعرّف عليّ في دقيقة"}', true, NULL, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('testimonials_disclaimer', '"التجارب شخصية وتختلف النتائج من شخص لآخر حسب الالتزام والحالة، والتدريب لا يغني عن استشارة الطبيب أو أخصائي العلاج الطبيعي."', true, NULL, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('prices_note', '"الأسعار بالريال السعودي. الدفع بتحويل بنكي على حساب المؤسسة."', true, NULL, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('checkins', '{"enabled": true, "questions": [{"q": "ملاحظاتك الصحية؟ الحركة اليومية وجودة الحياة صارت أحسن؟", "topic": "الصحة العامة"}, {"q": "أداؤك في التمارين؟ في تقدم في الأوزان والأداء؟", "topic": "التمارين"}, {"q": "فرق في شكلك ومظهرك؟ إيجابي أو سلبي؟", "topic": "المظهر"}, {"q": "فرق في الملابس أو المقاسات؟ إيجابي أو سلبي؟", "topic": "الملابس"}, {"q": "النظام الغذائي — قدرت تمشي عليه؟ فيه صعوبة؟", "topic": "الغذاء"}, {"q": "تحسّ بالجوع واجد؟ إن وُجد، كم تعطيه من 5؟", "topic": "الجوع"}, {"q": "أي ملاحظات سلبية تبي تشاركها؟ (مهمة أو بسيطة — نتقبل النقد)", "topic": "ملاحظات سلبية"}, {"q": "أي إشكاليات أو ملاحظات إضافية تحتاج مساعدة فيها؟", "topic": "ملاحظات أخرى"}, {"q": "وصلت لأي أسبوع تدريبي الآن؟", "topic": "الأسبوع"}]}', true, NULL, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('contact', '{"whatsapp": "966599162724", "instagram": "https://www.instagram.com/navvcoaching/"}', true, NULL, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('response_time', '"48 ساعة عمل (الأحد – الخميس، 12 ظهراً – 9 مساءً)"', true, NULL, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('legal', '{"cr": "7050950752", "name": "مؤسسة ناف كوتشنق للتدريب الرياضي"}', true, NULL, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('bank', '{"iban": "SA1280000139608016245411", "bankName": "مصرف الراجحي", "accountName": "مؤسسة ناف كوتشنق للتدريب الرياضي"}', true, NULL, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;
INSERT INTO public.site_settings VALUES ('program_shots', '[{"h": 720, "w": 754, "alt": "لقطة من صفحة «حسابي» ببيانات مثال: شريط الالتزام، أيام تمرين الأسبوع الحالي، ملخص تغذية اليوم، وروتين المكملات", "src": "shots/my-program.webp", "title": "برنامجي", "caption": "أول ما تدخل حسابك: نسبة التزامك وأسابيعك المتتالية، أيام تمرين الأسبوع، تغذية اليوم مقابل أهدافك، وروتين المكملات."}, {"h": 960, "w": 1148, "alt": "لقطة من صفحة برنامج التمرين ببيانات مثال: أيام الأسبوع، وبطاقة كل تمرين مع المستهدف وخانات الوزن والتكرارات وRIR", "src": "shots/training-log.webp", "title": "تسجيل التمرين", "caption": "لكل تمرين المستهدف من الجولات والتكرارات وRIR، وتسجّل وزنك وتكراراتك من جوالك، ولك تبديله ببديل تختاره المدربة."}, {"h": 1020, "w": 1148, "alt": "لقطة من صفحة التغذية ببيانات مثال: ملخص اليوم مقابل الأهداف، ونموذج إضافة أكلة، وأكل اليوم حسب الوجبات", "src": "shots/nutrition-day.webp", "title": "التغذية اليومية", "caption": "أهدافك اليومية من السعرات والماكروز وكم باقي لك، وتسجّل أكلك من جداولك الغذائية أو بالغرام من قاعدة الأكل."}, {"h": 307, "w": 1116, "alt": "لقطة من لوحة التقدم ببيانات مثال: رسم الوزن ورسم القياسات", "src": "shots/progress-charts.webp", "title": "لوحة التقدم", "caption": "وزنك وقياساتك برسوم واضحة أسبوعاً بأسبوع، ببيانات مثال."}]', true, NULL, '2026-10-04 07:25:44.888657+00') ON CONFLICT DO NOTHING;
COMMIT;
