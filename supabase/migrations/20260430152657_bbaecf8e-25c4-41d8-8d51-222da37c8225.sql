-- Auto-emit invoice.registered event on vendor_invoices INSERT
-- Closes the P2P loop: receive_purchase_order → vendor_invoice INSERT → auto-match → auto-approve

CREATE OR REPLACE FUNCTION public.emit_vendor_invoice_registered()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.emit_platform_event(
    'invoice.registered',
    jsonb_build_object(
      'invoice_id', NEW.id,
      'invoice_number', NEW.invoice_number,
      'vendor_id', NEW.vendor_id,
      'purchase_order_id', NEW.purchase_order_id,
      'subtotal_cents', NEW.subtotal_cents,
      'total_cents', NEW.total_cents,
      'currency', NEW.currency,
      'invoice_date', NEW.invoice_date
    ),
    'vendor_invoices.trigger'
  );
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- Never block invoice creation if event bus fails
  RAISE WARNING 'Failed to emit invoice.registered for %: %', NEW.id, SQLERRM;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_emit_vendor_invoice_registered ON public.vendor_invoices;

CREATE TRIGGER trg_emit_vendor_invoice_registered
  AFTER INSERT ON public.vendor_invoices
  FOR EACH ROW
  EXECUTE FUNCTION public.emit_vendor_invoice_registered();