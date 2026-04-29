ALTER TABLE public.manufacturing_orders REPLICA IDENTITY FULL;
ALTER PUBLICATION supabase_realtime ADD TABLE public.manufacturing_orders;