
-- Contracts
CREATE OR REPLACE FUNCTION public.seed_demo_contracts(p_run_id uuid, p_scenario text DEFAULT 'default')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_count int := 0; v_id uuid; v_suffix text; r record;
BEGIN
  v_suffix := substring(p_run_id::text,1,6);
  FOR r IN SELECT * FROM (VALUES
    ('MSA – Acme Corp ('||v_suffix||')',      'service'::contract_type, 'active'::contract_status,    'Acme Corp AB',         'legal+'||v_suffix||'@acme.example',     (current_date - 90)::date, (current_date + 275)::date, 'auto'::renewal_type, 12000000::bigint, 'SEK'),
    ('NDA – Beta Industries ('||v_suffix||')','nda'::contract_type,     'active'::contract_status,    'Beta Industries Ltd',  'legal+'||v_suffix||'@beta.example',     (current_date - 200)::date, (current_date + 165)::date,'none'::renewal_type,         0::bigint, 'SEK'),
    ('SOW – Northwind ('||v_suffix||')',      'service'::contract_type, 'draft'::contract_status,     'Northwind Trading',    'procurement+'||v_suffix||'@northwind.example', NULL, NULL, 'none'::renewal_type,           4500000::bigint, 'SEK'),
    ('Reseller – Gamma EU ('||v_suffix||')',  'partnership'::contract_type,'pending_signature'::contract_status,'Gamma EU GmbH','contracts+'||v_suffix||'@gamma.example',(current_date - 5)::date,(current_date + 360)::date,'auto'::renewal_type, 25000000::bigint, 'EUR'),
    ('Old MSA – Delta Co ('||v_suffix||')',   'service'::contract_type, 'expired'::contract_status,   'Delta Co',             'admin+'||v_suffix||'@delta.example',    (current_date - 800)::date,(current_date - 60)::date, 'none'::renewal_type, 8000000::bigint, 'SEK')
  ) AS t(title,ctype,cstatus,cname,cmail,sd,ed,rt,val,cur) LOOP
    INSERT INTO public.contracts(title,contract_type,status,counterparty_name,counterparty_email,start_date,end_date,renewal_type,value_cents,currency,notes)
    VALUES (r.title,r.ctype,r.cstatus,r.cname,r.cmail,r.sd,r.ed,r.rt,r.val,r.cur,'Demo contract seeded by run '||v_suffix) RETURNING id INTO v_id;
    PERFORM public._demo_register_row(p_run_id,'contracts',v_id);
    v_count := v_count+1;
  END LOOP;
  RETURN jsonb_build_object('contracts', v_count);
END $$;

-- Companies
CREATE OR REPLACE FUNCTION public.seed_demo_companies(p_run_id uuid, p_scenario text DEFAULT 'default')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_count int := 0; v_id uuid; v_suffix text; r record;
BEGIN
  v_suffix := substring(p_run_id::text,1,6);
  FOR r IN SELECT * FROM (VALUES
    ('Acme Corp AB ('||v_suffix||')',         'acme-'||v_suffix||'.example',     'Manufacturing', '51-200',  '+4684441000', 'customer'::company_lifecycle_stage),
    ('Beta Industries Ltd ('||v_suffix||')',  'beta-'||v_suffix||'.example',     'Logistics',     '201-500', '+4485550100', 'customer'::company_lifecycle_stage),
    ('Northwind Trading ('||v_suffix||')',    'northwind-'||v_suffix||'.example','Retail',        '11-50',   '+4687123000', 'lead'::company_lifecycle_stage),
    ('Gamma EU GmbH ('||v_suffix||')',        'gamma-'||v_suffix||'.example',    'SaaS',          '51-200',  '+49301234567','opportunity'::company_lifecycle_stage),
    ('Helios Solar ('||v_suffix||')',         'helios-'||v_suffix||'.example',   'Energy',        '11-50',    NULL,         'prospect'::company_lifecycle_stage),
    ('Lumen Health ('||v_suffix||')',         'lumen-'||v_suffix||'.example',    'Healthcare',    '1000+',   '+4684442200', 'lead'::company_lifecycle_stage)
  ) AS t(nm,dom,ind,sz,ph,stg) LOOP
    INSERT INTO public.companies(name,domain,industry,size,phone,website,lifecycle_stage,notes)
    VALUES (r.nm,r.dom,r.ind,r.sz,r.ph,'https://'||r.dom,r.stg,'Demo company seeded by run '||v_suffix) RETURNING id INTO v_id;
    PERFORM public._demo_register_row(p_run_id,'companies',v_id);
    v_count := v_count+1;
  END LOOP;
  RETURN jsonb_build_object('companies', v_count);
END $$;

-- Deals (creates own leads to satisfy NOT NULL FK)
CREATE OR REPLACE FUNCTION public.seed_demo_deals(p_run_id uuid, p_scenario text DEFAULT 'default')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_count int := 0; v_id uuid; v_lead uuid; v_suffix text; r record;
BEGIN
  v_suffix := substring(p_run_id::text,1,6);
  FOR r IN SELECT * FROM (VALUES
    ('Lisa Andersson', 'lisa+'||v_suffix||'@acme.example',      'Acme Corp – platform expansion',  'proposal'::deal_stage,    18000000, (current_date + 30)::date),
    ('Marcus Berg',    'marcus+'||v_suffix||'@northwind.example','Northwind onboarding',           'qualified'::deal_stage,    4500000, (current_date + 45)::date),
    ('Sara Holm',      'sara+'||v_suffix||'@gamma.example',     'Gamma EU – year 2 renewal',       'negotiation'::deal_stage, 25000000, (current_date + 14)::date),
    ('Anders Lind',    'anders+'||v_suffix||'@helios.example',  'Helios pilot',                    'prospecting'::deal_stage,  1200000, (current_date + 60)::date),
    ('Eva Norén',      'eva+'||v_suffix||'@lumen.example',      'Lumen Health analytics',          'closed_won'::deal_stage,   9800000, (current_date - 7)::date)
  ) AS t(nm,em,title,stg,val,close) LOOP
    INSERT INTO public.leads(name,email,status,source,notes)
    VALUES (r.nm,r.em,'opportunity'::lead_status,'demo','Lead for deal: '||r.title) RETURNING id INTO v_lead;
    PERFORM public._demo_register_row(p_run_id,'leads',v_lead);
    INSERT INTO public.deals(lead_id,stage,value_cents,currency,expected_close,notes,closed_at)
    VALUES (v_lead,r.stg,r.val,'SEK',r.close,r.title, CASE WHEN r.stg IN ('closed_won','closed_lost') THEN now() - interval '7 days' ELSE NULL END)
    RETURNING id INTO v_id;
    PERFORM public._demo_register_row(p_run_id,'deals',v_id);
    v_count := v_count+1;
  END LOOP;
  RETURN jsonb_build_object('deals', v_count, 'leads', v_count);
END $$;

-- Recruitment (job_postings)
CREATE OR REPLACE FUNCTION public.seed_demo_recruitment(p_run_id uuid, p_scenario text DEFAULT 'default')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_count int := 0; v_id uuid; v_suffix text; r record;
BEGIN
  v_suffix := substring(p_run_id::text,1,6);
  FOR r IN SELECT * FROM (VALUES
    ('Senior Backend Engineer ('||v_suffix||')',  'senior-backend-'||v_suffix,  'Engineering', 'Stockholm', 'hybrid',  'full_time'::employment_kind, 'published'::job_posting_status, 650000, 850000),
    ('Product Designer ('||v_suffix||')',         'product-designer-'||v_suffix,'Design',      'Remote EU', 'remote',  'full_time'::employment_kind, 'published'::job_posting_status, 550000, 720000),
    ('Customer Success Manager ('||v_suffix||')', 'csm-'||v_suffix,             'Customer',    'Göteborg',  'onsite',  'full_time'::employment_kind, 'published'::job_posting_status, 480000, 620000),
    ('Marketing Intern ('||v_suffix||')',         'marketing-intern-'||v_suffix,'Marketing',   'Stockholm', 'hybrid',  'internship'::employment_kind,'draft'::job_posting_status,     180000, 220000)
  ) AS t(title,slug,dept,loc,remote,etype,stat,smin,smax) LOOP
    INSERT INTO public.job_postings(title,slug,department,location,remote_policy,employment_type,status,salary_min_cents,salary_max_cents,currency,description,requirements,published_at)
    VALUES (r.title,r.slug,r.dept,r.loc,r.remote,r.etype,r.stat,r.smin*100,r.smax*100,'SEK',
      'Demo job posting for '||r.title||'. Join our growing team.',
      'Strong fundamentals, collaborative mindset, fluent in English.',
      CASE WHEN r.stat='published'::job_posting_status THEN now() - interval '10 days' ELSE NULL END)
    RETURNING id INTO v_id;
    PERFORM public._demo_register_row(p_run_id,'job_postings',v_id);
    v_count := v_count+1;
  END LOOP;
  RETURN jsonb_build_object('job_postings', v_count);
END $$;

-- Pricelists
CREATE OR REPLACE FUNCTION public.seed_demo_pricelists(p_run_id uuid, p_scenario text DEFAULT 'default')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_count int := 0; v_id uuid; v_suffix text; r record;
BEGIN
  v_suffix := substring(p_run_id::text,1,6);
  FOR r IN SELECT * FROM (VALUES
    ('Standard SEK ('||v_suffix||')',  'Default retail prices',                 'SEK', true,  100),
    ('Partner 20% ('||v_suffix||')',   'Partner channel with 20% rebate',       'SEK', false,  50),
    ('Campaign Q4 ('||v_suffix||')',   'Limited campaign October–December',     'SEK', false,  25)
  ) AS t(nm,descr,cur,isdef,prio) LOOP
    INSERT INTO public.pricelists(name,description,currency,is_default,priority,is_active,valid_from,valid_until)
    VALUES (r.nm,r.descr,r.cur,r.isdef,r.prio,true,current_date - 30, current_date + 365)
    RETURNING id INTO v_id;
    PERFORM public._demo_register_row(p_run_id,'pricelists',v_id);
    v_count := v_count+1;
  END LOOP;
  RETURN jsonb_build_object('pricelists', v_count);
END $$;

-- Wiki
CREATE OR REPLACE FUNCTION public.seed_demo_wiki(p_run_id uuid, p_scenario text DEFAULT 'default')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_count int := 0; v_suffix text; r record;
BEGIN
  v_suffix := substring(p_run_id::text,1,6);
  FOR r IN SELECT * FROM (VALUES
    ('demo-getting-started-'||v_suffix, 'Getting started',         E'# Getting started\n\nWelcome to the team wiki. This is a demo page.'),
    ('demo-engineering-'||v_suffix,     'Engineering handbook',    E'# Engineering\n\n- Code style: Prettier + ESLint\n- Branching: trunk-based\n- Reviews: at least one approver'),
    ('demo-incident-'||v_suffix,        'Incident response',       E'# Incidents\n\n1. Declare\n2. Mitigate\n3. Communicate\n4. Postmortem'),
    ('demo-onboarding-'||v_suffix,      'New-hire onboarding',     E'# Onboarding\n\nFirst day, first week, first month checklists.'),
    ('demo-tooling-'||v_suffix,         'Tooling and accounts',    E'# Tooling\n\nList of SaaS we use and how to request access.')
  ) AS t(slug,title,md) LOOP
    INSERT INTO public.wiki_pages(slug,title,content_md) VALUES (r.slug,r.title,r.md);
    PERFORM public._demo_register_row(p_run_id,'wiki_pages',
      (SELECT id FROM public.wiki_pages WHERE slug = r.slug));
    v_count := v_count+1;
  END LOOP;
  RETURN jsonb_build_object('wiki_pages', v_count);
END $$;

-- Surveys (templates)
CREATE OR REPLACE FUNCTION public.seed_demo_surveys(p_run_id uuid, p_scenario text DEFAULT 'default')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_count int := 0; v_id uuid; v_suffix text; r record;
BEGIN
  v_suffix := substring(p_run_id::text,1,6);
  FOR r IN SELECT * FROM (VALUES
    ('Customer NPS ('||v_suffix||')',  'nps',  'Quarterly Net Promoter Score',
      '[{"id":"q1","type":"nps","prompt":"How likely are you to recommend us?"},{"id":"q2","type":"text","prompt":"What is the main reason for your score?"}]'::jsonb),
    ('Support CSAT ('||v_suffix||')',  'csat', 'Post-ticket satisfaction',
      '[{"id":"q1","type":"csat","prompt":"How satisfied are you with the support you received?"},{"id":"q2","type":"text","prompt":"Anything we could do better?"}]'::jsonb),
    ('Exit Interview ('||v_suffix||')','custom','Outgoing employee feedback',
      '[{"id":"q1","type":"text","prompt":"Why are you leaving?"},{"id":"q2","type":"text","prompt":"What would have made you stay?"}]'::jsonb)
  ) AS t(nm,kind,descr,qs) LOOP
    INSERT INTO public.survey_templates(name,kind,description,questions,is_active)
    VALUES (r.nm,r.kind,r.descr,r.qs,true) RETURNING id INTO v_id;
    PERFORM public._demo_register_row(p_run_id,'survey_templates',v_id);
    v_count := v_count+1;
  END LOOP;
  RETURN jsonb_build_object('survey_templates', v_count);
END $$;

-- Extend dispatcher
CREATE OR REPLACE FUNCTION public.seed_module_demo(p_module text, p_scenario text DEFAULT 'default')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_run_id uuid; v_result jsonb; v_module text;
BEGIN
  IF NOT has_role(auth.uid(), 'admin'::app_role) THEN
    RAISE EXCEPTION 'Only admins can seed demo data';
  END IF;
  v_module := lower(trim(p_module));
  INSERT INTO demo_runs(module, scenario, created_by) VALUES (v_module, p_scenario, auth.uid()) RETURNING id INTO v_run_id;
  CASE v_module
    WHEN 'crm'          THEN v_result := seed_demo_crm(v_run_id, p_scenario);
    WHEN 'quotes'       THEN v_result := seed_demo_quotes(v_run_id, p_scenario);
    WHEN 'invoices'     THEN v_result := seed_demo_invoices(v_run_id, p_scenario);
    WHEN 'expenses'     THEN v_result := seed_demo_expenses(v_run_id, p_scenario);
    WHEN 'ecommerce'    THEN v_result := seed_demo_ecommerce(v_run_id, p_scenario);
    WHEN 'consultants'  THEN v_result := seed_demo_consultants(v_run_id, p_scenario);
    WHEN 'blog'         THEN v_result := seed_demo_blog(v_run_id, p_scenario);
    WHEN 'kb'           THEN v_result := seed_demo_kb(v_run_id, p_scenario);
    WHEN 'projects'     THEN v_result := seed_demo_projects(v_run_id, p_scenario);
    WHEN 'hr'           THEN v_result := seed_demo_hr(v_run_id, p_scenario);
    WHEN 'tickets'      THEN v_result := seed_demo_tickets(v_run_id, p_scenario);
    WHEN 'bookings'     THEN v_result := seed_demo_bookings(v_run_id, p_scenario);
    WHEN 'newsletter'   THEN v_result := seed_demo_newsletter(v_run_id, p_scenario);
    WHEN 'vendors'      THEN v_result := seed_demo_vendors(v_run_id, p_scenario);
    WHEN 'contracts'    THEN v_result := seed_demo_contracts(v_run_id, p_scenario);
    WHEN 'companies'    THEN v_result := seed_demo_companies(v_run_id, p_scenario);
    WHEN 'deals'        THEN v_result := seed_demo_deals(v_run_id, p_scenario);
    WHEN 'recruitment'  THEN v_result := seed_demo_recruitment(v_run_id, p_scenario);
    WHEN 'pricelists'   THEN v_result := seed_demo_pricelists(v_run_id, p_scenario);
    WHEN 'wiki'         THEN v_result := seed_demo_wiki(v_run_id, p_scenario);
    WHEN 'surveys'      THEN v_result := seed_demo_surveys(v_run_id, p_scenario);
    ELSE
      DELETE FROM demo_runs WHERE id = v_run_id;
      RAISE EXCEPTION 'Unsupported module: %', v_module;
  END CASE;
  RETURN jsonb_build_object('success', true, 'run_id', v_run_id, 'module', v_module, 'scenario', p_scenario, 'detail', v_result);
END $$;
