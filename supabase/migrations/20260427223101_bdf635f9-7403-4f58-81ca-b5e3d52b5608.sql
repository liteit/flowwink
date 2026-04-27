UPDATE public.agent_skills
SET
  tool_definition = jsonb_set(
    jsonb_set(
      tool_definition,
      '{function,parameters,properties,body_markdown}',
      '{"type":"string","description":"The FULL agreement text in Markdown (clauses, scope, payment terms, governing law, signatures section). REQUIRED for action=create unless a file_url is attached. Write the actual contract — do not leave empty."}'::jsonb,
      true
    ),
    '{function,parameters,properties,file_url}',
    '{"type":"string","description":"Optional URL to an attached PDF/DOCX of the contract."}'::jsonb,
    true
  ),
  instructions = 'Contracts track agreements with external parties. Status flow: draft → pending_signature → active → expired/terminated. When creating, default currency to SEK. ALWAYS write the full agreement text into body_markdown (Parties, Scope, Term, Fees, Payment, Confidentiality, Termination, Governing law, Signatures) — do NOT create a contract with an empty body unless a file_url PDF is attached. notes is for short internal metadata only, NOT the contract text. For search, match against title and counterparty_name. Swedish: "avtal", "kontrakt", "NDA", "tjänsteavtal".',
  updated_at = now()
WHERE name = 'manage_contract';

-- Also update the notes property description to clarify it's not the body
UPDATE public.agent_skills
SET tool_definition = jsonb_set(
  tool_definition,
  '{function,parameters,properties,notes}',
  '{"type":"string","description":"Short internal note / metadata. NOT the agreement text — use body_markdown for that."}'::jsonb,
  true
)
WHERE name = 'manage_contract';