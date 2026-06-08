
-- Consultant profiles table for the Resume module
CREATE TABLE public.consultant_profiles (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  name TEXT NOT NULL,
  title TEXT,
  email TEXT,
  phone TEXT,
  bio TEXT,
  skills TEXT[] NOT NULL DEFAULT '{}',
  experience_years INTEGER DEFAULT 0,
  education JSONB DEFAULT '[]',
  certifications TEXT[] DEFAULT '{}',
  languages TEXT[] DEFAULT '{}',
  portfolio_url TEXT,
  linkedin_url TEXT,
  avatar_url TEXT,
  hourly_rate_cents INTEGER,
  currency TEXT NOT NULL DEFAULT 'SEK',
  availability TEXT DEFAULT 'available',
  summary TEXT,
  experience_json JSONB DEFAULT '[]',
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_by UUID,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- RLS
ALTER TABLE public.consultant_profiles ENABLE ROW LEVEL SECURITY;

-- Admins can manage
CREATE POLICY "Admins can manage consultant profiles"
  ON public.consultant_profiles FOR ALL
  TO authenticated
  USING (has_role(auth.uid(), 'admin'::app_role))
  WITH CHECK (has_role(auth.uid(), 'admin'::app_role));

-- Staff can view
CREATE POLICY "Staff can view consultant profiles"
  ON public.consultant_profiles FOR SELECT
  TO authenticated
  USING (has_role(auth.uid(), 'writer'::app_role) OR has_role(auth.uid(), 'approver'::app_role) OR has_role(auth.uid(), 'admin'::app_role));

-- Public can view active profiles (for the block)
CREATE POLICY "Public can view active profiles"
  ON public.consultant_profiles FOR SELECT
  TO anon
  USING (is_active = true);

-- System can manage (for edge functions)
CREATE POLICY "System can insert consultant profiles"
  ON public.consultant_profiles FOR INSERT
  TO public
  WITH CHECK (true);

-- Updated_at trigger
CREATE TRIGGER update_consultant_profiles_updated_at
  BEFORE UPDATE ON public.consultant_profiles
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();
