import { supabase } from '@/integrations/supabase/client';

export interface UtmParams {
  utm_source?: string | null;
  utm_medium?: string | null;
  utm_campaign?: string | null;
  utm_term?: string | null;
  utm_content?: string | null;
}

const FIRST_KEY = 'ww_first_utm';
const LAST_KEY = 'ww_last_utm';
const LANDING_KEY = 'ww_landing_url';

export function parseUtmFromLocation(): UtmParams {
  if (typeof window === 'undefined') return {};
  const p = new URLSearchParams(window.location.search);
  const grab = (k: string) => {
    const v = p.get(k);
    return v && v.trim().length > 0 ? v.trim().slice(0, 200) : null;
  };
  return {
    utm_source: grab('utm_source'),
    utm_medium: grab('utm_medium'),
    utm_campaign: grab('utm_campaign'),
    utm_term: grab('utm_term'),
    utm_content: grab('utm_content'),
  };
}

function hasAnyUtm(u: UtmParams): boolean {
  return !!(u.utm_source || u.utm_medium || u.utm_campaign || u.utm_term || u.utm_content);
}

function readStorage(key: string): UtmParams | null {
  try {
    const raw = localStorage.getItem(key);
    if (!raw) return null;
    return JSON.parse(raw) as UtmParams;
  } catch {
    return null;
  }
}

function writeStorage(key: string, value: UtmParams | string) {
  try {
    localStorage.setItem(key, typeof value === 'string' ? value : JSON.stringify(value));
  } catch {
    /* storage may be disabled */
  }
}

/** Captures URL UTMs into storage on landing. Returns the incoming params (if any). */
export function captureUtmOnLanding(): UtmParams {
  const incoming = parseUtmFromLocation();
  if (!hasAnyUtm(incoming)) return incoming;

  // First-touch: only set if not already stored
  if (!readStorage(FIRST_KEY)) writeStorage(FIRST_KEY, incoming);
  // Last-touch: always overwrite
  writeStorage(LAST_KEY, incoming);
  if (typeof window !== 'undefined') writeStorage(LANDING_KEY, window.location.href);
  return incoming;
}

export function getFirstTouchUtm(): UtmParams {
  return readStorage(FIRST_KEY) ?? {};
}

export function getLastTouchUtm(): UtmParams {
  return readStorage(LAST_KEY) ?? {};
}

export function getLandingUrl(): string | null {
  try {
    return localStorage.getItem(LANDING_KEY);
  } catch {
    return null;
  }
}

/** Attribution fields for lead/order rows. */
export function buildAttributionFields() {
  const first = getFirstTouchUtm();
  const last = getLastTouchUtm();
  return {
    first_utm_source: first.utm_source ?? null,
    first_utm_medium: first.utm_medium ?? null,
    first_utm_campaign: first.utm_campaign ?? null,
    last_utm_source: last.utm_source ?? null,
    last_utm_medium: last.utm_medium ?? null,
    last_utm_campaign: last.utm_campaign ?? null,
  };
}

/** Fire-and-forget conversion attribution log (anon-safe). */
export async function logUtmConversion(
  conversion_kind: string,
  conversion_id?: string | null,
): Promise<void> {
  const last = getLastTouchUtm();
  if (!hasAnyUtm(last)) return;
  try {
    let visitor_id: string | null = null;
    let session_id: string | null = null;
    try {
      visitor_id = localStorage.getItem('pez_visitor_id');
      session_id = sessionStorage.getItem('pez_session_id');
    } catch {
      /* ignore */
    }
    await supabase.from('utm_attributions').insert({
      visitor_id,
      session_id,
      utm_source: last.utm_source,
      utm_medium: last.utm_medium,
      utm_campaign: last.utm_campaign,
      utm_term: last.utm_term,
      utm_content: last.utm_content,
      landing_url: getLandingUrl(),
      referrer: typeof document !== 'undefined' ? document.referrer || null : null,
      touch_type: 'conversion',
      conversion_kind,
      conversion_id: conversion_id ?? null,
    });
  } catch {
    // Attribution logging must never break the primary flow.
  }
}
