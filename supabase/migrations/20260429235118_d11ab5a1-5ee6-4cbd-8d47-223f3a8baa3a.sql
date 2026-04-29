-- Trigger: log MO cancellation to audit_logs
CREATE OR REPLACE FUNCTION public.log_mo_cancellation()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status = 'cancelled' AND (OLD.status IS DISTINCT FROM 'cancelled') THEN
    INSERT INTO public.audit_logs (action, entity_type, entity_id, user_id, metadata)
    VALUES (
      'mo.cancelled',
      'manufacturing_order',
      NEW.id,
      auth.uid(),
      jsonb_build_object(
        'mo_number', NEW.mo_number,
        'product_id', NEW.product_id,
        'previous_status', OLD.status,
        'cancelled_at', COALESCE(NEW.cancelled_at, now()),
        'quantity', NEW.quantity,
        'notes_tail', RIGHT(COALESCE(NEW.notes, ''), 500)
      )
    );
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_log_mo_cancellation ON public.manufacturing_orders;
CREATE TRIGGER trg_log_mo_cancellation
AFTER UPDATE OF status ON public.manufacturing_orders
FOR EACH ROW
EXECUTE FUNCTION public.log_mo_cancellation();