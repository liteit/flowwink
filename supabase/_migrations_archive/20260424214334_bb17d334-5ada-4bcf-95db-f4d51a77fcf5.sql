-- =========================================================
-- Federation v2: directional connections + finding attribution
-- =========================================================

-- 1) Direction enum
DO $$ BEGIN
  CREATE TYPE public.connection_direction AS ENUM ('outbound', 'inbound', 'bidirectional');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- 2) Connection transport enum (separate from peer-level transport so a peer can have several)
DO $$ BEGIN
  CREATE TYPE public.connection_transport AS ENUM ('a2a', 'openresponses', 'mcp');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- 3) federation_connections table
CREATE TABLE IF NOT EXISTS public.federation_connections (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  peer_id uuid NOT NULL REFERENCES public.a2a_peers(id) ON DELETE CASCADE,
  direction public.connection_direction NOT NULL,
  transport public.connection_transport NOT NULL,
  -- Outbound: where we call them (URL + token we hold)
  endpoint_url text,
  outbound_token text,
  -- Inbound: which of our api_keys they use to call us
  api_key_id uuid REFERENCES public.api_keys(id) ON DELETE SET NULL,
  -- Operational
  status text NOT NULL DEFAULT 'active',
  last_activity_at timestamptz,
  request_count integer NOT NULL DEFAULT 0,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  -- One row per (peer, direction, transport) combo
  UNIQUE (peer_id, direction, transport)
);

CREATE INDEX IF NOT EXISTS idx_fed_conn_peer ON public.federation_connections(peer_id);
CREATE INDEX IF NOT EXISTS idx_fed_conn_apikey ON public.federation_connections(api_key_id) WHERE api_key_id IS NOT NULL;

ALTER TABLE public.federation_connections ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins manage federation connections" ON public.federation_connections;
CREATE POLICY "Admins manage federation connections"
  ON public.federation_connections
  FOR ALL
  USING (public.has_role(auth.uid(), 'admin'::app_role))
  WITH CHECK (public.has_role(auth.uid(), 'admin'::app_role));

DROP POLICY IF EXISTS "System reads connections" ON public.federation_connections;
CREATE POLICY "System reads connections"
  ON public.federation_connections
  FOR SELECT
  USING (true);

-- updated_at trigger
DROP TRIGGER IF EXISTS update_federation_connections_updated_at ON public.federation_connections;
CREATE TRIGGER update_federation_connections_updated_at
  BEFORE UPDATE ON public.federation_connections
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- 4) Backfill connections from existing a2a_peers
-- For each peer:
--  - if transport=a2a => bidirectional/a2a connection
--  - if transport=openresponses => outbound/openresponses connection
--  - if peer has api_key_id => inbound/mcp connection (they call our MCP)
INSERT INTO public.federation_connections (peer_id, direction, transport, endpoint_url, outbound_token, api_key_id, status, last_activity_at)
SELECT
  p.id,
  'bidirectional'::connection_direction,
  'a2a'::connection_transport,
  p.url,
  p.outbound_token,
  NULL,
  p.status::text,
  p.last_seen_at
FROM public.a2a_peers p
WHERE p.transport = 'a2a'
ON CONFLICT (peer_id, direction, transport) DO NOTHING;

INSERT INTO public.federation_connections (peer_id, direction, transport, endpoint_url, outbound_token, api_key_id, status, last_activity_at)
SELECT
  p.id,
  'outbound'::connection_direction,
  'openresponses'::connection_transport,
  p.url,
  NULLIF(p.gateway_token, ''),
  NULL,
  p.status::text,
  p.last_seen_at
FROM public.a2a_peers p
WHERE p.transport = 'openresponses'
ON CONFLICT (peer_id, direction, transport) DO NOTHING;

INSERT INTO public.federation_connections (peer_id, direction, transport, endpoint_url, outbound_token, api_key_id, status, last_activity_at)
SELECT
  p.id,
  'inbound'::connection_direction,
  'mcp'::connection_transport,
  NULL,
  NULL,
  p.api_key_id,
  p.status::text,
  p.last_seen_at
FROM public.a2a_peers p
WHERE p.api_key_id IS NOT NULL
ON CONFLICT (peer_id, direction, transport) DO NOTHING;

-- 5) Fix orphan MCP api_keys: ensure Clawwink's key has the right scopes
UPDATE public.api_keys
SET scopes = ARRAY['mcp:*']
WHERE id = '10a8775e-0af7-4ddd-bf68-7bfa8a78ac38'
  AND (scopes IS NULL OR array_length(scopes, 1) IS NULL);

-- 6) Add reported_by to beta_test_findings (attribution for MCP findings)
ALTER TABLE public.beta_test_findings
  ADD COLUMN IF NOT EXISTS reported_by text;

CREATE INDEX IF NOT EXISTS idx_beta_findings_reported_by ON public.beta_test_findings(reported_by);

-- Default existing rows: distinguish flowpilot heartbeat from external
UPDATE public.beta_test_findings
SET reported_by = 'flowpilot'
WHERE reported_by IS NULL;
