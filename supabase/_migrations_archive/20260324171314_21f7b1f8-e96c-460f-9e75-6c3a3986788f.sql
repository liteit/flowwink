
-- Beta test sessions: tracks each test run from OpenClaw
CREATE TABLE IF NOT EXISTS public.beta_test_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  peer_id UUID REFERENCES public.a2a_peers(id) ON DELETE SET NULL,
  peer_name TEXT NOT NULL DEFAULT 'openclaw',
  scenario TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'completed', 'failed')),
  started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at TIMESTAMPTZ,
  duration_ms INTEGER,
  summary TEXT,
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Beta test findings: individual observations from a session
CREATE TABLE IF NOT EXISTS public.beta_test_findings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id UUID REFERENCES public.beta_test_sessions(id) ON DELETE CASCADE NOT NULL,
  type TEXT NOT NULL CHECK (type IN ('bug', 'ux_issue', 'suggestion', 'positive', 'performance', 'missing_feature')),
  severity TEXT NOT NULL DEFAULT 'medium' CHECK (severity IN ('low', 'medium', 'high', 'critical')),
  title TEXT NOT NULL,
  description TEXT,
  screenshot_url TEXT,
  context JSONB DEFAULT '{}'::jsonb,
  resolved_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Beta test exchanges: messages between OpenClaw and FlowPilot
CREATE TABLE IF NOT EXISTS public.beta_test_exchanges (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id UUID REFERENCES public.beta_test_sessions(id) ON DELETE CASCADE,
  direction TEXT NOT NULL CHECK (direction IN ('openclaw_to_flowpilot', 'flowpilot_to_openclaw')),
  message_type TEXT NOT NULL DEFAULT 'observation' CHECK (message_type IN ('observation', 'instruction', 'feedback', 'learning', 'action_request', 'action_result')),
  content TEXT NOT NULL,
  payload JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.beta_test_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.beta_test_findings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.beta_test_exchanges ENABLE ROW LEVEL SECURITY;

-- Public read for edge functions (auth via anon key), admin write
CREATE POLICY "Allow authenticated read on beta_test_sessions" ON public.beta_test_sessions FOR SELECT TO authenticated USING (true);
CREATE POLICY "Allow authenticated insert on beta_test_sessions" ON public.beta_test_sessions FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "Allow authenticated update on beta_test_sessions" ON public.beta_test_sessions FOR UPDATE TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "Allow authenticated read on beta_test_findings" ON public.beta_test_findings FOR SELECT TO authenticated USING (true);
CREATE POLICY "Allow authenticated insert on beta_test_findings" ON public.beta_test_findings FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "Allow authenticated update on beta_test_findings" ON public.beta_test_findings FOR UPDATE TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "Allow authenticated read on beta_test_exchanges" ON public.beta_test_exchanges FOR SELECT TO authenticated USING (true);
CREATE POLICY "Allow authenticated insert on beta_test_exchanges" ON public.beta_test_exchanges FOR INSERT TO authenticated WITH CHECK (true);

-- Anon access for edge function bridge
CREATE POLICY "Allow anon insert on beta_test_sessions" ON public.beta_test_sessions FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "Allow anon insert on beta_test_findings" ON public.beta_test_findings FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "Allow anon insert on beta_test_exchanges" ON public.beta_test_exchanges FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "Allow anon select on beta_test_sessions" ON public.beta_test_sessions FOR SELECT TO anon USING (true);
CREATE POLICY "Allow anon select on beta_test_findings" ON public.beta_test_findings FOR SELECT TO anon USING (true);
CREATE POLICY "Allow anon select on beta_test_exchanges" ON public.beta_test_exchanges FOR SELECT TO anon USING (true);
CREATE POLICY "Allow anon update on beta_test_sessions" ON public.beta_test_sessions FOR UPDATE TO anon USING (true) WITH CHECK (true);
