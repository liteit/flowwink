
-- ===== CRM (leads) =====
CREATE OR REPLACE FUNCTION public.seed_demo_crm(p_run_id uuid, p_scenario text DEFAULT 'default')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_count int := 0; v_lead_id uuid; rec record;
BEGIN
  FOR rec IN SELECT * FROM (VALUES
    ('Anna Lindberg',  'anna.lindberg+'||substring(p_run_id::text,1,6)||'@nordicfin.demo',  'lead',        72),
    ('Erik Sjöberg',   'erik+'||substring(p_run_id::text,1,6)||'@sjoberg-bygg.demo',        'opportunity', 88),
    ('Maria Holm',     'maria+'||substring(p_run_id::text,1,6)||'@holm-consulting.demo',    'lead',        45),
    ('Johan Persson',  'johan+'||substring(p_run_id::text,1,6)||'@persson-tech.demo',       'opportunity', 91),
    ('Sara Eklund',    'sara.eklund+'||substring(p_run_id::text,1,6)||'@eklundlaw.demo',    'lead',        58)
  ) AS t(name, email, status, score) LOOP
    INSERT INTO public.leads (email, name, status, score, source, ai_summary)
    VALUES (rec.email, rec.name, rec.status::lead_status, rec.score, 'demo:'||p_scenario, 'Demo lead seeded')
    RETURNING id INTO v_lead_id;
    PERFORM public._demo_register_row(p_run_id, 'leads', v_lead_id);
    v_count := v_count + 1;
  END LOOP;
  RETURN jsonb_build_object('table','leads','inserted',v_count);
END $$;

-- ===== Quotes =====
CREATE OR REPLACE FUNCTION public.seed_demo_quotes(p_run_id uuid, p_scenario text DEFAULT 'default')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_count int := 0; v_id uuid; v_number text; rec record;
BEGIN
  FOR rec IN SELECT * FROM (VALUES
    ('Acme Demo AB',    'kontakt@acme.demo',          'sent',     45000, 'Implementation package Q1'),
    ('Berg & Co Demo',  'info@bergco.demo',           'draft',    18000, 'Audit retainer 6 months'),
    ('Holm Consulting', 'maria@holm-consulting.demo', 'accepted', 92000, 'Annual subscription')
  ) AS t(customer, email, status, total, title) LOOP
    v_number := 'DEMO-Q-'||substring(p_run_id::text,1,6)||'-'||lpad((v_count+1)::text,3,'0');
    INSERT INTO public.quotes (quote_number, status, customer_name, customer_email, title, subtotal_cents, tax_cents, total_cents, currency, line_items, notes)
    VALUES (v_number, rec.status::quote_status, rec.customer, rec.email, rec.title,
      (rec.total*0.8)::int, (rec.total*0.2)::int, rec.total, 'SEK',
      jsonb_build_array(jsonb_build_object('description',rec.title,'quantity',1,'unit_price_cents',(rec.total*0.8)::int)),
      'demo:'||p_scenario)
    RETURNING id INTO v_id;
    PERFORM public._demo_register_row(p_run_id,'quotes',v_id);
    v_count := v_count+1;
  END LOOP;
  RETURN jsonb_build_object('table','quotes','inserted',v_count);
END $$;

-- ===== Invoices =====
CREATE OR REPLACE FUNCTION public.seed_demo_invoices(p_run_id uuid, p_scenario text DEFAULT 'default')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_count int := 0; v_id uuid; v_number text; rec record;
BEGIN
  FOR rec IN SELECT * FROM (VALUES
    ('Acme Demo AB',    'kontakt@acme.demo',          'sent',  45000),
    ('Berg & Co Demo',  'info@bergco.demo',           'draft', 18000),
    ('Holm Consulting', 'maria@holm-consulting.demo', 'paid',  92000)
  ) AS t(customer, email, status, total) LOOP
    v_number := 'DEMO-INV-'||substring(p_run_id::text,1,6)||'-'||lpad((v_count+1)::text,3,'0');
    INSERT INTO public.invoices (invoice_number, status, customer_name, customer_email, subtotal_cents, tax_cents, total_cents, currency, issue_date, due_date, line_items, notes, paid_at, paid_amount_cents)
    VALUES (v_number, rec.status::invoice_status, rec.customer, rec.email,
      (rec.total*0.8)::int, (rec.total*0.2)::int, rec.total, 'SEK',
      CURRENT_DATE-10, CURRENT_DATE+20,
      jsonb_build_array(jsonb_build_object('description','Demo services','quantity',1,'unit_price_cents',(rec.total*0.8)::int)),
      'demo:'||p_scenario,
      CASE WHEN rec.status='paid' THEN now() ELSE NULL END,
      CASE WHEN rec.status='paid' THEN rec.total ELSE 0 END)
    RETURNING id INTO v_id;
    PERFORM public._demo_register_row(p_run_id,'invoices',v_id);
    v_count := v_count+1;
  END LOOP;
  RETURN jsonb_build_object('table','invoices','inserted',v_count);
END $$;

-- ===== Expenses =====
CREATE OR REPLACE FUNCTION public.seed_demo_expenses(p_run_id uuid, p_scenario text DEFAULT 'default')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_count int := 0; v_id uuid; v_user uuid; rec record;
BEGIN
  v_user := auth.uid();
  IF v_user IS NULL THEN
    SELECT user_id INTO v_user FROM public.user_roles WHERE role='admin'::app_role LIMIT 1;
  END IF;
  IF v_user IS NULL THEN
    RETURN jsonb_build_object('table','expenses','inserted',0,'skipped','no admin user');
  END IF;
  FOR rec IN SELECT * FROM (VALUES
    ('Lunch with prospect Acme', 'travel',    45000,  9000,  'Restaurant Demo'),
    ('Office supplies',          'office',    12000,  2400,  'Demo Office Supply'),
    ('Conference ticket Q1',     'training',  250000, 50000, 'TechConf Demo')
  ) AS t(description, category, amount, vat, vendor) LOOP
    INSERT INTO public.expenses (user_id, expense_date, description, amount_cents, vat_cents, currency, category, vendor)
    VALUES (v_user, CURRENT_DATE - (v_count*3), rec.description, rec.amount, rec.vat, 'SEK', rec.category, rec.vendor||' [demo:'||p_scenario||']')
    RETURNING id INTO v_id;
    PERFORM public._demo_register_row(p_run_id,'expenses',v_id);
    v_count := v_count+1;
  END LOOP;
  RETURN jsonb_build_object('table','expenses','inserted',v_count);
END $$;

-- ===== Consultants =====
CREATE OR REPLACE FUNCTION public.seed_demo_consultants(p_run_id uuid, p_scenario text DEFAULT 'default')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_count int := 0; v_id uuid; v_suffix text; rec record;
BEGIN
  v_suffix := substring(p_run_id::text,1,6);
  FOR rec IN SELECT * FROM (VALUES
    ('Anna Lindberg',     'Senior Frontend Engineer',  'Frontend specialist with 8 years building React apps. Loves accessibility and DX.', ARRAY['React','TypeScript','Tailwind','Next.js','Design Systems'],  8,  1450, 'available',           ARRAY['Swedish','English']),
    ('Erik Johansson',    'Cloud Architect',           'AWS-certified architect for event-driven serverless.',                              ARRAY['AWS','Terraform','Kubernetes','Node.js'],                    12, 1850, 'available',           ARRAY['Swedish','English']),
    ('Sofia Bergström',   'Product Designer',          'End-to-end product designer for SaaS teams.',                                       ARRAY['Figma','Prototyping','User Research','Design Systems'],      10, 1350, 'partially_available', ARRAY['Swedish','English']),
    ('Lars Nilsson',      'Backend Engineer',          'Reliable Go and PostgreSQL services with strong observability.',                    ARRAY['Go','PostgreSQL','gRPC','Microservices'],                    9,  1500, 'available',           ARRAY['Swedish','English']),
    ('Maria Andersson',   'Data Engineer',             'Modern data stacks (dbt + Snowflake/BigQuery) for analytics teams.',                ARRAY['dbt','SQL','Snowflake','Airflow','Python'],                  7,  1400, 'available',           ARRAY['Swedish','English']),
    ('Johan Karlsson',    'DevOps Engineer',           'Platform engineer focused on developer productivity and CI/CD.',                    ARRAY['Kubernetes','GitHub Actions','Terraform','ArgoCD'],          11, 1600, 'partially_available', ARRAY['Swedish','English']),
    ('Emma Svensson',     'AI/ML Engineer',            'LLM applications with RAG and structured output. Strong eval mindset.',             ARRAY['Python','LangChain','OpenAI','RAG','PyTorch'],               6,  1750, 'available',           ARRAY['Swedish','English']),
    ('Niklas Persson',    'Mobile Developer',          'React Native and native modules.',                                                  ARRAY['React Native','Swift','Kotlin','iOS','Android'],             9,  1450, 'unavailable',         ARRAY['Swedish','English']),
    ('Linnea Holm',       'Engineering Manager',       'Interim engineering manager for scale-ups.',                                        ARRAY['Leadership','Hiring','OKRs','Agile','Coaching'],             14, 1900, 'partially_available', ARRAY['Swedish','English']),
    ('Oskar Lundgren',    'Security Engineer',         'AppSec and threat modelling for SaaS companies.',                                   ARRAY['AppSec','Threat Modelling','SOC2','ISO 27001','Pentest'],    10, 1700, 'available',           ARRAY['Swedish','English'])
  ) AS t(full_name, role_title, summary_text, skill_arr, exp_years, rate_per_hour, avail_status, lang_arr) LOOP
    INSERT INTO public.consultant_profiles (name, title, email, summary, bio, skills, experience_years, hourly_rate_cents, currency, availability, languages, is_active)
    VALUES (rec.full_name, rec.role_title,
      lower(replace(rec.full_name,' ','.'))||'+'||v_suffix||'@example.demo',
      rec.summary_text, rec.summary_text, rec.skill_arr, rec.exp_years,
      rec.rate_per_hour*100, 'SEK', rec.avail_status, rec.lang_arr, true)
    RETURNING id INTO v_id;
    PERFORM public._demo_register_row(p_run_id,'consultant_profiles',v_id);
    v_count := v_count+1;
  END LOOP;
  RETURN jsonb_build_object('table','consultant_profiles','inserted',v_count);
END $$;

-- ===== Fix tickets enum (feature_request → feature) =====
CREATE OR REPLACE FUNCTION public.seed_demo_tickets(p_run_id uuid, p_scenario text DEFAULT 'default')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_count int := 0; v_id uuid; r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('Login problem on mobile app',     'I cannot log in from my iPhone since this morning.',         'new',         'high',   'bug',     'Maria Andersson','maria@example.com'),
    ('Question about invoicing',        'How do I get a copy of last month''s invoice?',              'open',        'medium', 'billing', 'Per Svensson','per.s@example.com'),
    ('Feature request: dark mode',      'Would love a dark mode for the dashboard.',                  'open',        'low',    'feature', 'Lisa Berg','lisa@example.com'),
    ('Sync error with Google Calendar', 'My bookings aren''t syncing to Google Calendar anymore.',    'in_progress', 'high',   'bug',     'Tom Karlsson','tom@example.com'),
    ('How do I export contacts?',       'Looking for a CSV export option in the CRM.',                'resolved',    'low',    'question','Eva Holm','eva.h@example.com'),
    ('Refund request order #1042',      'Wrong size delivered, would like a refund.',                 'new',         'urgent', 'other',   'Nils Olsson','nils@example.com')
  ) AS t(subject,desc_,status,prio,cat,cname,cemail) LOOP
    INSERT INTO public.tickets(subject,description,status,priority,category,contact_name,contact_email,source)
    VALUES (r.subject,r.desc_,r.status::ticket_status,r.prio::ticket_priority,r.cat::ticket_category,r.cname,r.cemail,'manual')
    RETURNING id INTO v_id;
    PERFORM public._demo_register_row(p_run_id,'tickets',v_id);
    v_count := v_count+1;
  END LOOP;
  RETURN jsonb_build_object('tickets', v_count);
END $$;

GRANT EXECUTE ON FUNCTION public.seed_demo_crm(uuid,text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.seed_demo_quotes(uuid,text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.seed_demo_invoices(uuid,text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.seed_demo_expenses(uuid,text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.seed_demo_consultants(uuid,text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.seed_demo_tickets(uuid,text) TO authenticated, service_role;
