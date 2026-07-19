/**
 * Contact Finder — internal skill handler
 *
 * Finds business contacts by domain (Hunter.io Domain Search)
 * or finds a specific person's email (Hunter.io Email Finder).
 *
 * Actions:
 *   - domain_search: Find all contacts at a domain
 *   - email_finder: Find a specific person's email by name + domain
 *
 * Moved from the standalone `contact-finder` edge function
 * (edge-surface refactor B1a, wave 0 — see
 * docs/architecture/edge-surface-classification.md). The response objects are
 * byte-identical to what the edge function returned; agent-execute's edge:
 * dispatch always parsed the JSON body regardless of HTTP status, so callers
 * see exactly the same shapes.
 *
 * Used by: agent-execute (`internal:contact_finder`), prospect-research
 * (direct library import once it moves in wave 1).
 */

export interface ContactFinderInput {
  action?: 'domain_search' | 'email_finder';
  domain: string;
  first_name?: string;
  last_name?: string;
  limit?: number;
}

interface HunterContact {
  first_name: string | null;
  last_name: string | null;
  email: string;
  phone_number: string | null;
  position: string | null;
  department: string | null;
  confidence: number;
}

export async function executeContactFinder(args: Record<string, unknown>): Promise<Record<string, unknown>> {
  try {
    const input = args as unknown as ContactFinderInput;
    const action = input.action || 'domain_search';

    if (!input.domain) {
      return { success: false, error: 'domain is required' };
    }

    const hunterKey = Deno.env.get('HUNTER_API_KEY');
    if (!hunterKey) {
      // Soft fail — orchestrator can continue without contacts
      return {
        success: false,
        error: 'HUNTER_API_KEY not configured. Add it in Settings → Secrets.',
        contacts: [],
      };
    }

    const domain = input.domain.replace(/^www\./, '');

    // --- Email Finder: find specific person ---
    if (action === 'email_finder') {
      if (!input.first_name || !input.last_name) {
        return { success: false, error: 'first_name and last_name required for email_finder' };
      }

      console.log(`[contact-finder] Email Finder: ${input.first_name} ${input.last_name} @ ${domain}`);

      const params = new URLSearchParams({
        domain,
        first_name: input.first_name,
        last_name: input.last_name,
        api_key: hunterKey,
      });

      const res = await fetch(`https://api.hunter.io/v2/email-finder?${params}`);
      if (!res.ok) {
        console.warn('[contact-finder] Hunter Email Finder failed:', res.status);
        return { success: false, error: `Hunter API error: ${res.status}`, contact: null };
      }

      const data = await res.json();
      const contact = data.data?.email ? {
        email: data.data.email,
        confidence: data.data.confidence,
        first_name: data.data.first_name,
        last_name: data.data.last_name,
        position: data.data.position || null,
      } : null;

      console.log(`[contact-finder] Email Finder result:`, contact ? 'found' : 'not found');

      return {
        success: true,
        action: 'email_finder',
        contact,
        domain,
      };
    }

    // --- Domain Search: find all contacts ---
    console.log(`[contact-finder] Domain Search: ${domain} (limit: ${input.limit || 10})`);

    const res = await fetch(
      `https://api.hunter.io/v2/domain-search?domain=${domain}&api_key=${hunterKey}&limit=${input.limit || 10}`
    );

    if (!res.ok) {
      console.warn('[contact-finder] Hunter Domain Search failed:', res.status);
      return { success: false, error: `Hunter API error: ${res.status}`, contacts: [] };
    }

    const data = await res.json();
    const contacts: HunterContact[] = (data.data?.emails || []).map((e: any) => ({
      first_name: e.first_name || null,
      last_name: e.last_name || null,
      email: e.value,
      phone_number: e.phone_number || null,
      position: e.position || null,
      department: e.department || null,
      confidence: e.confidence || 0,
    }));

    console.log(`[contact-finder] Found ${contacts.length} contacts at ${domain}`);

    return {
      success: true,
      action: 'domain_search',
      contacts,
      domain,
      total_results: data.data?.total || contacts.length,
    };

  } catch (error) {
    console.error('[contact-finder] Error:', error);
    return { success: false, error: error instanceof Error ? error.message : 'Unknown error' };
  }
}
