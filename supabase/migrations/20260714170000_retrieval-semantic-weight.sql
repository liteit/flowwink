-- Retrieval Engine — weight the semantic leg of the hybrid fusion.
-- OpenClaw finding 64f9db79: plain equal-weight RRF flattened the semantic
-- signal — the right docs ranked high semantically (cosine ~0.5) but off-topic
-- docs with high ts_rank tied/won because both legs contributed 1/(k+rank)
-- equally, so a single rank position decided. Fix: a semantic_weight on the
-- RRF terms (default lean-semantic) + a semantic_score tiebreak when hybrid
-- scores are within epsilon. Text-only fallback intact: query_embedding NULL
-- ⇒ semantic leg empty ⇒ ranking is purely the (down-weighted but monotonic)
-- text term, so order is preserved (Law 4).
--
-- Idempotent: drop the M1 signature (adding a param would otherwise create an
-- overload PostgREST can't disambiguate) then CREATE OR REPLACE the new one.

DROP FUNCTION IF EXISTS public.search_knowledge_chunks(text, extensions.vector, int, int, text[]);

CREATE OR REPLACE FUNCTION public.search_knowledge_chunks(
  query_text text,
  query_embedding extensions.vector DEFAULT NULL,
  match_count int DEFAULT 8,
  rrf_k int DEFAULT 60,
  sources text[] DEFAULT NULL,
  semantic_weight double precision DEFAULT 0.65
) RETURNS TABLE (
  chunk_id uuid,
  source_table text,
  entity_id text,
  title text,
  content text,
  metadata jsonb,
  text_score double precision,
  semantic_score double precision,
  hybrid_score double precision
)
LANGUAGE sql STABLE SECURITY INVOKER
SET search_path TO 'public', 'extensions'
AS $$
  WITH q AS (
    SELECT public.build_or_tsquery(query_text) AS tsq
  ),
  textual AS (
    SELECT c.id,
           ts_rank(c.tsv, q.tsq) AS score,
           row_number() OVER (ORDER BY ts_rank(c.tsv, q.tsq) DESC) AS rank
    FROM public.knowledge_chunks c, q
    WHERE c.tsv @@ q.tsq
      AND (sources IS NULL OR c.source_table = ANY(sources))
    ORDER BY score DESC
    LIMIT greatest(match_count * 4, 40)
  ),
  semantic AS (
    SELECT c.id,
           1 - (c.embedding <=> query_embedding) AS score,
           row_number() OVER (ORDER BY c.embedding <=> query_embedding ASC) AS rank
    FROM public.knowledge_chunks c
    WHERE query_embedding IS NOT NULL AND c.embedding IS NOT NULL
      AND (sources IS NULL OR c.source_table = ANY(sources))
    ORDER BY c.embedding <=> query_embedding ASC
    LIMIT greatest(match_count * 4, 40)
  ),
  fused AS (
    SELECT COALESCE(t.id, s.id) AS id,
           COALESCE(t.score, 0)::double precision AS text_score,
           COALESCE(s.score, 0)::double precision AS semantic_score,
           -- Weighted reciprocal-rank fusion: semantic term × semantic_weight,
           -- text term × (1 - semantic_weight). With the semantic leg absent
           -- (text-only fallback) this is just the monotonic text term.
           (semantic_weight       * COALESCE(1.0 / (rrf_k + s.rank), 0)
            + (1 - semantic_weight) * COALESCE(1.0 / (rrf_k + t.rank), 0))::double precision AS hybrid_score
    FROM textual t
    FULL OUTER JOIN semantic s ON s.id = t.id
  )
  SELECT c.id, c.source_table, c.entity_id, c.title, c.content, c.metadata,
         f.text_score, f.semantic_score, f.hybrid_score
  FROM fused f
  JOIN public.knowledge_chunks c ON c.id = f.id
  -- Semantic-similarity tiebreak: when weighted hybrid scores are ~equal, the
  -- semantically closer chunk wins (this is exactly the near-tie the finding hit).
  ORDER BY f.hybrid_score DESC, f.semantic_score DESC, f.text_score DESC
  LIMIT match_count;
$$;

GRANT EXECUTE ON FUNCTION public.search_knowledge_chunks(text, extensions.vector, int, int, text[], double precision)
  TO anon, authenticated, service_role;
