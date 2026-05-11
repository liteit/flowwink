import { supabase } from '@/integrations/supabase/client';

const STORAGE_KEY = 'chat-session-id';
const HEADER_NAME = 'x-chat-session';

/**
 * Mutates the supabase REST client's default headers to include the visitor's
 * chat session id. RLS on chat_conversations / chat_messages requires this
 * header to match the row's session_id for anonymous reads.
 */
export function applyVisitorChatSessionHeader(sessionId?: string | null): string | null {
  const sid = sessionId ?? (typeof window !== 'undefined' ? localStorage.getItem(STORAGE_KEY) : null);
  if (!sid) return null;
  try {
    // PostgrestClient stores default headers on `rest.headers`; mutating it
    // affects every subsequent supabase.from(...) call.
    const rest = (supabase as unknown as { rest?: { headers?: Record<string, string> } }).rest;
    if (rest?.headers) {
      rest.headers[HEADER_NAME] = sid;
    }
  } catch {
    // best-effort — header is also passed via getOrCreate when needed
  }
  return sid;
}

export function getOrCreateVisitorChatSessionId(): string {
  if (typeof window === 'undefined') return '';
  let sid = localStorage.getItem(STORAGE_KEY);
  if (!sid) {
    sid = crypto.randomUUID();
    localStorage.setItem(STORAGE_KEY, sid);
  }
  applyVisitorChatSessionHeader(sid);
  return sid;
}
