
-- Add inventory columns to products
ALTER TABLE public.products 
  ADD COLUMN IF NOT EXISTS stock_quantity integer DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS track_inventory boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS low_stock_threshold integer NOT NULL DEFAULT 5,
  ADD COLUMN IF NOT EXISTS allow_backorder boolean NOT NULL DEFAULT false;

-- Back-in-stock notification requests
CREATE TABLE IF NOT EXISTS public.back_in_stock_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  email text NOT NULL,
  notified_at timestamp with time zone DEFAULT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  UNIQUE(product_id, email)
);

-- Enable RLS
ALTER TABLE public.back_in_stock_requests ENABLE ROW LEVEL SECURITY;

-- Anyone can request notifications (public form)
CREATE POLICY "Anyone can request back in stock notifications"
  ON public.back_in_stock_requests FOR INSERT
  TO public
  WITH CHECK (true);

-- Admins can view and manage requests
CREATE POLICY "Admins can manage back in stock requests"
  ON public.back_in_stock_requests FOR ALL
  TO public
  USING (public.has_role(auth.uid(), 'admin'::app_role));

-- Index for quick lookup
CREATE INDEX IF NOT EXISTS idx_back_in_stock_product_id ON public.back_in_stock_requests(product_id);
CREATE INDEX IF NOT EXISTS idx_back_in_stock_not_notified ON public.back_in_stock_requests(product_id) WHERE notified_at IS NULL;
