// prospect_fit_analysis — internal skill handler.
//
// Data Aggregator (No AI). Collects company data and returns it for FlowPilot
// (or UI) to score. OpenClaw alignment: "hand" not "brain".
//
// Moved from the standalone `prospect-fit-analysis` edge function
// (edge-surface refactor B1a, wave 1). Response objects unchanged.

import type { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';

export async function executeProspectFitAnalysis(
  supabase: SupabaseClient,
  args: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  try {
    const { company_id, company_name } = args as { company_id?: string; company_name?: string };

    if (!company_id && !company_name) {
      return { error: 'company_id or company_name is required' };
    }

    // Load company data
    let company = null;
    if (company_id) {
      const { data } = await supabase
        .from('companies')
        .select('*')
        .eq('id', company_id)
        .single();
      company = data;
    } else if (company_name) {
      const { data } = await supabase
        .from('companies')
        .select('*')
        .ilike('name', `%${company_name}%`)
        .limit(1)
        .maybeSingle();
      company = data;
    }

    // Load related leads
    let relatedLeads: any[] = [];
    if (company) {
      const { data } = await supabase
        .from('leads')
        .select('id, email, name, status, score, source')
        .ilike('company', `%${company.name}%`)
        .limit(10);
      relatedLeads = data || [];
    }

    // Load related deals
    let relatedDeals: any[] = [];
    if (company) {
      const { data } = await supabase
        .from('deals')
        .select('id, title, status, value_cents, currency')
        .eq('company_id', company.id)
        .limit(10);
      relatedDeals = data || [];
    }

    // Return raw data — FlowPilot does the analysis
    return {
      success: true,
      company: company || { name: company_name, note: 'Not found in CRM' },
      related_leads: relatedLeads,
      related_deals: relatedDeals,
      data_completeness: {
        has_industry: !!company?.industry,
        has_size: !!company?.size,
        has_website: !!company?.website,
        has_domain: !!company?.domain,
        is_enriched: !!company?.enriched_at,
        lead_count: relatedLeads.length,
        deal_count: relatedDeals.length,
      },
    };
  } catch (error) {
    console.error('Prospect fit analysis error:', error);
    return { error: error instanceof Error ? error.message : 'Unknown error' };
  }
}
