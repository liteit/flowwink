
-- Sales Intelligence Profiles table
CREATE TABLE public.sales_intelligence_profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  type text NOT NULL DEFAULT 'company',
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  data jsonb NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(type, user_id)
);

-- Enable RLS
ALTER TABLE public.sales_intelligence_profiles ENABLE ROW LEVEL SECURITY;

-- Admins full access
CREATE POLICY "Admins can manage sales intelligence profiles"
  ON public.sales_intelligence_profiles FOR ALL
  TO authenticated
  USING (has_role(auth.uid(), 'admin'::app_role))
  WITH CHECK (has_role(auth.uid(), 'admin'::app_role));

-- Authenticated can read company profile
CREATE POLICY "Authenticated can view company profiles"
  ON public.sales_intelligence_profiles FOR SELECT
  TO authenticated
  USING (type = 'company');

-- Users can manage their own user profile
CREATE POLICY "Users can manage own user profile"
  ON public.sales_intelligence_profiles FOR ALL
  TO authenticated
  USING (type = 'user' AND user_id = auth.uid())
  WITH CHECK (type = 'user' AND user_id = auth.uid());

-- System can upsert (for edge functions with service role)
CREATE POLICY "System can insert profiles"
  ON public.sales_intelligence_profiles FOR INSERT
  TO public
  WITH CHECK (true);

CREATE POLICY "System can update profiles"
  ON public.sales_intelligence_profiles FOR UPDATE
  TO public
  USING (true);

-- Updated_at trigger
CREATE TRIGGER update_sales_intelligence_profiles_updated_at
  BEFORE UPDATE ON public.sales_intelligence_profiles
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();
