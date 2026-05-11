-- Ensure pgcrypto is available in the extensions schema so gen_random_bytes()
-- works in all subsequent migrations regardless of search_path.
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;