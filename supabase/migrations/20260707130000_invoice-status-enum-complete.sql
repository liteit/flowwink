-- System-sweep finding #B2 (2026-07-07): code across agent-execute and
-- migrations filters invoices on status values ('void', 'booked', 'posted')
-- that do not exist in the invoice_status enum — any write of those values
-- throws, and filters silently match nothing. Complete the enum.
-- ALTER TYPE ... ADD VALUE IF NOT EXISTS is idempotent and forward-dated.

ALTER TYPE public.invoice_status ADD VALUE IF NOT EXISTS 'void';
ALTER TYPE public.invoice_status ADD VALUE IF NOT EXISTS 'booked';
ALTER TYPE public.invoice_status ADD VALUE IF NOT EXISTS 'posted';
