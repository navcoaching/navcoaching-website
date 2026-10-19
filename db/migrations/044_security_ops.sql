-- =====================================================================
-- سجل الأمان (محاولات الدخول والعمليات الحساسة) وسجل التشغيل (أخطاء الموقع وفشل البريد والإشعارات).
-- القراءة للمدربة فقط، والكتابة عبر دوال فقط (لا INSERT مباشر من اتصال الموقع).
-- يُحذف تلقائياً: سجل الأمان بعد 180 يوماً، وسجل التشغيل بعد 90 يوماً (تقليل البيانات المحفوظة).
-- قفل الحساب يُحسب من السجل نفسه: 5 محاولات فاشلة لنفس البريد خلال 15 دقيقة بعد آخر دخول ناجح.
-- =====================================================================
CREATE TABLE IF NOT EXISTS security_log (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  event text NOT NULL CHECK (event ~ '^[a-z_]{3,40}$'),
  email text CHECK (length(email) <= 320),
  user_id text REFERENCES "user" (id) ON DELETE SET NULL,
  ip text CHECK (length(ip) <= 64),
  detail text CHECK (length(detail) <= 300),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS security_log_email_idx ON security_log (email, created_at DESC);
CREATE INDEX IF NOT EXISTS security_log_time_idx ON security_log (created_at DESC);
ALTER TABLE security_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS security_log_coach ON security_log;
CREATE POLICY security_log_coach ON security_log FOR SELECT USING (app.is_coach());
GRANT SELECT ON security_log TO nav_app;

CREATE TABLE IF NOT EXISTS ops_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kind text NOT NULL CHECK (kind ~ '^[a-z_]{3,40}$'),
  detail text CHECK (length(detail) <= 500),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ops_events_time_idx ON ops_events (created_at DESC);
ALTER TABLE ops_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ops_events_coach ON ops_events;
CREATE POLICY ops_events_coach ON ops_events FOR SELECT USING (app.is_coach());
GRANT SELECT ON ops_events TO nav_app;

CREATE OR REPLACE FUNCTION app.log_security(p_event text, p_email text, p_user text, p_ip text, p_detail text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  INSERT INTO security_log (event, email, user_id, ip, detail)
  VALUES (p_event, lower(left(p_email, 320)), p_user, left(p_ip, 64), left(p_detail, 300));
  IF random() < 0.01 THEN DELETE FROM security_log WHERE created_at < now() - interval '180 days'; END IF;
END $$;

CREATE OR REPLACE FUNCTION app.ops_event(p_kind text, p_detail text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  INSERT INTO ops_events (kind, detail) VALUES (p_kind, left(p_detail, 500));
  IF random() < 0.01 THEN DELETE FROM ops_events WHERE created_at < now() - interval '90 days'; END IF;
END $$;

-- عدد المحاولات الفاشلة لهذا البريد خلال آخر 15 دقيقة، بعد آخر دخول ناجح
CREATE OR REPLACE FUNCTION app.login_failures(p_email text) RETURNS int
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT count(*)::int FROM security_log
   WHERE email = lower(p_email) AND event = 'login_failed' AND created_at > now() - interval '15 minutes'
     AND created_at > coalesce((SELECT max(created_at) FROM security_log WHERE email = lower(p_email) AND event = 'login_ok'), '-infinity');
$$;

REVOKE ALL ON FUNCTION app.log_security(text, text, text, text, text), app.ops_event(text, text), app.login_failures(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.log_security(text, text, text, text, text), app.ops_event(text, text), app.login_failures(text) TO nav_app;
