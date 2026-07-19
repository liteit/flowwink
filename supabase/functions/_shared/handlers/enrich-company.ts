// enrich_company — internal skill handler.
//
// Data-Only (No AI). Scrapes a company website (via the web-scrape kernel
// function so admin-configured provider priority is respected) and extracts
// metadata (title, description, phone) deterministically. AI-powered analysis
// is FlowPilot's job. OpenClaw alignment: "hand" not "brain".
//
// Moved from the standalone `enrich-company` edge function (edge-surface
// refactor B1a, wave 1). Response objects unchanged; the web-scrape call keeps
// its HTTP hop (web-scrape is a shared utility slated for _shared-lib
// extraction in a later tranche, not this one).

import type { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';
import type { HandlerCtx } from './qualify-lead.ts';

export async function executeEnrichCompany(
  supabase: SupabaseClient,
  args: Record<string, unknown>,
  ctx: HandlerCtx,
): Promise<Record<string, unknown>> {
  try {
    const { domain, companyId } = args as { domain?: string; companyId?: string };

    // Resolve domain from companyId if needed
    let enrichDomain = domain;
    let targetCompanyId = companyId;

    if (!enrichDomain && companyId) {
      const { data: company, error: companyError } = await supabase
        .from('companies')
        .select('id, domain, enriched_at')
        .eq('id', companyId)
        .single();

      if (companyError || !company) {
        return { error: 'Company not found' };
      }

      if (!company.domain) {
        return { error: 'Company has no domain to enrich' };
      }

      if (company.enriched_at) {
        return { success: true, message: 'Already enriched', skipped: true };
      }

      enrichDomain = company.domain;
      targetCompanyId = company.id;
    }

    if (!enrichDomain) {
      return { error: 'Domain or companyId is required' };
    }

    // Normalize domain to URL
    const url = enrichDomain.startsWith('http') ? enrichDomain : `https://${enrichDomain}`;
    console.log(`Scraping website via web-scrape (priority-aware): ${url}`);

    // Delegate to web-scrape edge function so admin-configured provider priority
    // (SearXNG / Firecrawl / Jina order) is respected automatically.
    const scrapeResponse = await fetch(`${ctx.supabaseUrl}/functions/v1/web-scrape`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${ctx.serviceKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ url, max_length: 8000 }),
    });

    if (!scrapeResponse.ok) {
      const errorText = await scrapeResponse.text();
      console.error('web-scrape error:', errorText);
      return { error: 'Failed to scrape website', details: errorText };
    }

    const scrapeData = await scrapeResponse.json();
    const pageContent: string = scrapeData.content || '';
    const metadata: Record<string, any> = scrapeData.metadata || {};
    console.log(`Scraped via provider: ${scrapeData.provider}`);

    // Extract data from metadata (deterministic — no AI)
    const enrichment = {
      website: url,
      description: metadata.description || metadata.ogDescription || null,
      phone: extractPhone(pageContent),
      address: null as string | null,
      raw_content: pageContent.substring(0, 5000), // For FlowPilot to analyze later
    };

    console.log('Enrichment result:', JSON.stringify({ ...enrichment, raw_content: `[${enrichment.raw_content?.length || 0} chars]` }));

    // Update company record
    if (targetCompanyId) {
      const { error: updateError } = await supabase
        .from('companies')
        .update({
          website: enrichment.website,
          notes: enrichment.description || undefined,
          phone: enrichment.phone || undefined,
          enriched_at: new Date().toISOString(),
        })
        .eq('id', targetCompanyId);

      if (updateError) {
        console.error('Failed to update company:', updateError);
      } else {
        console.log(`Company ${targetCompanyId} enriched successfully`);
      }
    }

    return { success: true, data: enrichment, companyId: targetCompanyId };
  } catch (error) {
    console.error('Error in enrich-company:', error);
    return { error: error instanceof Error ? error.message : 'Unknown error' };
  }
}

/** Extract phone number from content using regex (deterministic) */
function extractPhone(content: string): string | null {
  // Swedish and international phone patterns
  const patterns = [
    /(?:tel|phone|telefon)[:\s]*([+\d\s()-]{8,20})/i,
    /(\+46[\s.-]?\d{1,3}[\s.-]?\d{3,4}[\s.-]?\d{2,4})/,
    /(0\d{1,3}[\s.-]?\d{3,4}[\s.-]?\d{2,4})/,
  ];
  for (const p of patterns) {
    const m = content.match(p);
    if (m) return m[1].trim();
  }
  return null;
}
