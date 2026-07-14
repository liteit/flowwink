-- Retrieval Engine hybrid-fusion smoke (OpenClaw finding 64f9db79).
-- Proves the weighted RRF + semantic tiebreak makes the semantically-closer
-- chunk win a near-tie, where plain equal-weight RRF left it arbitrary. Run:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f scripts/smoke/retrieval-fusion.sql
-- Self-cleaning: everything is in a rolled-back transaction. Expect: PASS.
--
-- The fixture uses tiny 2-dim embeddings, so real 1536-dim chunks are cleared
-- INSIDE the tx first (rolled back) — otherwise the semantic leg would compare
-- mismatched dimensions. Nothing is persisted.

\set QUIET on
\pset pager off

BEGIN;

-- Clear real chunks for the duration of the tx (rolled back at the end) so the
-- semantic leg only sees the 2-dim fixtures.
DELETE FROM public.knowledge_chunks;

-- Chunk A ("correct"): the query token once (LOWER ts_rank → text rank 2),
-- embedding identical to the query vector (cosine 1 → semantic rank 1).
INSERT INTO public.knowledge_chunks
  (source_table, entity_id, chunk_index, title, content, embedding, visibility, content_hash)
VALUES
  ('docs_pages', 'smoke-fusion-A', 0, 'SMOKE-FUSION correct (semantically near)',
   'zqxten', '[1,0]'::extensions.vector, 'public', 'smoke-a');

-- Chunk B ("off-topic"): the query token repeated (HIGHER ts_rank → text rank
-- 1), embedding orthogonal to the query (cosine 0 → semantic rank 2).
INSERT INTO public.knowledge_chunks
  (source_table, entity_id, chunk_index, title, content, embedding, visibility, content_hash)
VALUES
  ('docs_pages', 'smoke-fusion-B', 0, 'SMOKE-FUSION off-topic (keyword-stuffed)',
   'zqxten zqxten zqxten', '[0,1]'::extensions.vector, 'public', 'smoke-b');

-- Under equal-weight RRF these two tie (A: text#2+sem#1, B: text#1+sem#2).
-- The weighted fusion + semantic tiebreak must put the semantically-near A first.
WITH r AS (
  SELECT entity_id, row_number() OVER () AS pos
  FROM public.search_knowledge_chunks(
    query_text := 'zqxten',
    query_embedding := '[1,0]'::extensions.vector,
    match_count := 5
  )
)
SELECT CASE
  WHEN (SELECT entity_id FROM r WHERE pos = 1) = 'smoke-fusion-A'
  THEN 'PASS weighted fusion ranks the semantically-near chunk first'
  ELSE 'FAIL fusion put ' || COALESCE((SELECT entity_id FROM r WHERE pos = 1), '(none)')
       || ' first — semantic leg is underweighted'
END AS result;

ROLLBACK;
