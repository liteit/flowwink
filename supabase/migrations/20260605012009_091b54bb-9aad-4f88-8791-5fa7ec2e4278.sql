
CREATE OR REPLACE FUNCTION public.seed_demo_webinars(p_run_id uuid, p_scenario text DEFAULT 'default')
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_webinars int := 0;
  v_regs int := 0;
  v_wid uuid;
  v_rid uuid;
  r RECORD;
  v_lead RECORD;
  v_reg_count int;
  i int;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('AI for B2B sales: a practical playbook',           'How to use AI agents to qualify leads and book meetings 24/7.',     'Intros · Lead scoring · Live demo · Q&A',  now() - interval '14 days', 45, 'completed', true),
    ('Building autonomous content marketing',            'A live walkthrough of an AI-operated content campaign pipeline.',   'Strategy · Tooling · Live build · Q&A',    now() - interval '5 days',  60, 'completed', true),
    ('From quote to cash, automated',                    'Demo of FlowPilot handling quotes, contracts and invoicing.',       'Pipeline · Demo · Compliance · Q&A',       now() + interval '7 days',  45, 'scheduled', false),
    ('Self-hosted AI on a budget',                       'Choosing models, infra and guardrails for your own deployment.',    'Models · Cost · Privacy · Live setup',     now() + interval '21 days', 75, 'scheduled', false),
    ('Customer support that scales itself',              'Setting up tickets, SLAs and AI-assisted first response.',          'Inbox triage · SLA · Demo · Q&A',          now() + interval '35 days', 45, 'scheduled', false)
  ) AS t(title, desc_, agenda_, when_, dur, status_, has_recording) LOOP

    INSERT INTO webinars (title, description, agenda, date, duration_minutes, max_attendees, platform, meeting_url, recording_url, status, cover_image)
    VALUES (
      r.title, r.desc_, r.agenda_, r.when_, r.dur, 200,
      'google_meet',
      'https://meet.google.com/demo-'||substring(md5(r.title),1,3)||'-'||substring(md5(r.title),4,4)||'-'||substring(md5(r.title),8,3),
      CASE WHEN r.has_recording THEN 'https://example.com/recordings/'||substring(md5(r.title),1,12)||'.mp4' ELSE NULL END,
      r.status_,
      NULL
    )
    RETURNING id INTO v_wid;
    PERFORM _demo_register_row(p_run_id, 'webinars', v_wid);
    v_webinars := v_webinars + 1;

    -- Registrations from existing leads (link real CRM data when possible)
    v_reg_count := 0;
    FOR v_lead IN
      SELECT id, name, email FROM leads
      WHERE email IS NOT NULL
      ORDER BY random()
      LIMIT (5 + floor(random()*8)::int)
    LOOP
      INSERT INTO webinar_registrations (
        webinar_id, name, email, lead_id, registered_at,
        attended, follow_up_sent,
        reminder_confirm_sent_at, reminder_t24_sent_at, reminder_t1_sent_at, reminder_post_sent_at
      ) VALUES (
        v_wid, v_lead.name, v_lead.email, v_lead.id,
        r.when_ - interval '7 days' + (random() * interval '6 days'),
        CASE WHEN r.status_ = 'completed' THEN random() < 0.65 ELSE false END,
        CASE WHEN r.status_ = 'completed' THEN random() < 0.8 ELSE false END,
        r.when_ - interval '7 days',
        CASE WHEN r.when_ < now() + interval '1 day' THEN r.when_ - interval '24 hours' ELSE NULL END,
        CASE WHEN r.when_ < now() + interval '1 hour' THEN r.when_ - interval '1 hour' ELSE NULL END,
        CASE WHEN r.status_ = 'completed' THEN r.when_ + interval '2 hours' ELSE NULL END
      );
      v_regs := v_regs + 1;
      v_reg_count := v_reg_count + 1;
    END LOOP;

    -- Add a few anonymous registrations so the list isn't empty when CRM has no leads
    IF v_reg_count < 3 THEN
      FOR i IN 1..(3 - v_reg_count) LOOP
        INSERT INTO webinar_registrations (webinar_id, name, email, registered_at)
        VALUES (
          v_wid,
          (ARRAY['Alex Demo','Sara Demo','Karl Demo','Mia Demo','Jonas Demo'])[1 + floor(random()*5)::int],
          'demo'||floor(random()*9999)::int||'@example.com',
          r.when_ - interval '5 days'
        );
        v_regs := v_regs + 1;
      END LOOP;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('webinars', v_webinars, 'registrations', v_regs);
END;
$$;

CREATE OR REPLACE FUNCTION public.seed_module_demo(p_module text, p_scenario text DEFAULT 'default')
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_run_id uuid;
  v_result jsonb;
BEGIN
  INSERT INTO demo_runs (module, scenario, status) VALUES (p_module, p_scenario, 'running') RETURNING id INTO v_run_id;

  CASE p_module
    WHEN 'crm', 'leads' THEN v_result := seed_demo_crm(v_run_id, p_scenario);
    WHEN 'quotes' THEN v_result := seed_demo_quotes(v_run_id, p_scenario);
    WHEN 'invoices' THEN v_result := seed_demo_invoices(v_run_id, p_scenario);
    WHEN 'expenses' THEN v_result := seed_demo_expenses(v_run_id, p_scenario);
    WHEN 'tickets' THEN v_result := seed_demo_tickets(v_run_id, p_scenario);
    WHEN 'products' THEN v_result := seed_demo_products(v_run_id, p_scenario);
    WHEN 'orders' THEN v_result := seed_demo_orders(v_run_id, p_scenario);
    WHEN 'subscriptions' THEN v_result := seed_demo_subscriptions(v_run_id, p_scenario);
    WHEN 'kb' THEN v_result := seed_demo_kb(v_run_id, p_scenario);
    WHEN 'blog' THEN v_result := seed_demo_blog(v_run_id, p_scenario);
    WHEN 'bookings' THEN v_result := seed_demo_bookings(v_run_id, p_scenario);
    WHEN 'employees' THEN v_result := seed_demo_employees(v_run_id, p_scenario);
    WHEN 'contracts' THEN v_result := seed_demo_contracts(v_run_id, p_scenario);
    WHEN 'companies' THEN v_result := seed_demo_companies(v_run_id, p_scenario);
    WHEN 'deals' THEN v_result := seed_demo_deals(v_run_id, p_scenario);
    WHEN 'recruitment' THEN v_result := seed_demo_recruitment(v_run_id, p_scenario);
    WHEN 'pricelists' THEN v_result := seed_demo_pricelists(v_run_id, p_scenario);
    WHEN 'surveys' THEN v_result := seed_demo_surveys(v_run_id, p_scenario);
    WHEN 'projects' THEN v_result := seed_demo_projects(v_run_id, p_scenario);
    WHEN 'documents' THEN v_result := seed_demo_documents(v_run_id, p_scenario);
    WHEN 'inventory' THEN v_result := seed_demo_inventory(v_run_id, p_scenario);
    WHEN 'webinars' THEN v_result := seed_demo_webinars(v_run_id, p_scenario);
    ELSE
      UPDATE demo_runs SET status='failed', error='Unknown module: '||p_module, finished_at=now() WHERE id=v_run_id;
      RETURN jsonb_build_object('error', 'Unknown module: '||p_module);
  END CASE;

  UPDATE demo_runs SET status='completed', finished_at=now(), result=v_result WHERE id=v_run_id;
  RETURN jsonb_build_object('run_id', v_run_id, 'result', v_result);
END;
$$;
