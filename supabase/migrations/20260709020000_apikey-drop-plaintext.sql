-- API keys: stop keeping the raw secret at rest (2026-07-09, security).
-- The key is shown ONCE at creation (useCreateApiKey returns it) and only its
-- sha256 hash is used to authenticate. The old code also stored key_raw in
-- cleartext, so a DB read / backup leaked every full key. Null out existing
-- plaintext; the frontend no longer writes or selects it. (Column kept nullable
-- for now — can be dropped once the generated types are regenerated.)
UPDATE public.api_keys SET key_raw = NULL WHERE key_raw IS NOT NULL;
COMMENT ON COLUMN public.api_keys.key_raw IS 'DEPRECATED — never populated; the raw key is shown once at creation and only key_hash is stored. Safe to drop.';
