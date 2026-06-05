
CREATE OR REPLACE FUNCTION public.seed_demo_contracts(p_run_id uuid, p_scenario text DEFAULT 'default')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_count int := 0; v_id uuid; v_suffix text; v_body text; r record;
BEGIN
  v_suffix := substring(p_run_id::text,1,6);
  FOR r IN SELECT * FROM (VALUES
    ('MSA – Acme Corp ('||v_suffix||')',      'service'::contract_type, 'active'::contract_status,    'Acme Corp AB',         'legal+'||v_suffix||'@acme.example',     (current_date - 90)::date, (current_date + 275)::date, 'auto'::renewal_type, 12000000::bigint, 'SEK'),
    ('NDA – Beta Industries ('||v_suffix||')','nda'::contract_type,     'active'::contract_status,    'Beta Industries Ltd',  'legal+'||v_suffix||'@beta.example',     (current_date - 200)::date, (current_date + 165)::date,'none'::renewal_type,         0::bigint, 'SEK'),
    ('SOW – Northwind ('||v_suffix||')',      'service'::contract_type, 'draft'::contract_status,     'Northwind Trading',    'procurement+'||v_suffix||'@northwind.example', NULL, NULL, 'none'::renewal_type,           4500000::bigint, 'SEK'),
    ('Reseller – Gamma EU ('||v_suffix||')',  'other'::contract_type,   'pending_signature'::contract_status,'Gamma EU GmbH','contracts+'||v_suffix||'@gamma.example',(current_date - 5)::date,(current_date + 360)::date,'auto'::renewal_type, 25000000::bigint, 'EUR'),
    ('Old MSA – Delta Co ('||v_suffix||')',   'service'::contract_type, 'expired'::contract_status,   'Delta Co',             'admin+'||v_suffix||'@delta.example',    (current_date - 800)::date,(current_date - 60)::date, 'none'::renewal_type, 8000000::bigint, 'SEK')
  ) AS t(title,ctype,cstatus,cname,cmail,sd,ed,rt,val,cur) LOOP
    v_body := E'# ' || r.title || E'\n\n'
      || E'**Parties.** This agreement is entered into between the Provider and ' || r.cname || E'.\n\n'
      || E'## 1. Scope\nThe Provider shall deliver the agreed services described in the accompanying Statement of Work. This demo contract is generated automatically as part of demo data.\n\n'
      || E'## 2. Term\nThe agreement starts on the effective date and remains in force until terminated by either party with written notice in accordance with the renewal terms.\n\n'
      || E'## 3. Fees\nFees and currency are as stated in the contract metadata. Invoices are issued monthly in arrears unless otherwise agreed.\n\n'
      || E'## 4. Confidentiality\nBoth parties shall keep all non-public information confidential and shall not disclose it to any third party without prior written consent.\n\n'
      || E'## 5. Governing law\nThis agreement is governed by Swedish law. Disputes shall be resolved by the courts of Stockholm.\n\n'
      || E'_Seeded by demo run ' || v_suffix || E'._';
    INSERT INTO public.contracts(title,contract_type,status,counterparty_name,counterparty_email,start_date,end_date,renewal_type,value_cents,currency,notes,body_markdown)
    VALUES (r.title,r.ctype,r.cstatus,r.cname,r.cmail,r.sd,r.ed,r.rt,r.val,r.cur,'Demo contract seeded by run '||v_suffix, v_body) RETURNING id INTO v_id;
    PERFORM public._demo_register_row(p_run_id,'contracts',v_id);
    v_count := v_count+1;
  END LOOP;
  RETURN jsonb_build_object('contracts', v_count);
END $$;
