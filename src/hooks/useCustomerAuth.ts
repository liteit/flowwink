import { useAuth } from '@/hooks/useAuth';
import { supabase } from '@/integrations/supabase/client';

/**
 * Customer-specific auth hook.
 *
 * Customer signup goes through the public `customer-signup` edge function
 * (service-role) so it keeps working even when staff signup is globally
 * disabled (`auth.disable_signup`). The edge function enforces the
 * `site_settings.customer_portal` policy.
 */
export function useCustomerAuth() {
  const auth = useAuth();

  const isCustomer = auth.role === 'customer';
  const isLoggedIn = !!auth.user;

  const customerSignUp = async (email: string, password: string, fullName: string) => {
    try {
      const res = await fetch(
        `${import.meta.env.VITE_SUPABASE_URL}/functions/v1/customer-signup`,
        {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            Authorization: `Bearer ${import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY}`,
          },
          body: JSON.stringify({ email, password, fullName }),
        },
      );
      const body = await res.json().catch(() => ({}));
      if (!res.ok) {
        return { error: new Error(body?.error || 'Signup failed') };
      }
      return { error: null as Error | null, requiresVerification: !!body?.requires_verification };
    } catch (err) {
      return { error: err instanceof Error ? err : new Error('Signup failed') };
    }
  };

  const customerSignIn = async (email: string, password: string) => {
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    return { error: error as Error | null };
  };

  return {
    ...auth,
    isCustomer,
    isLoggedIn,
    customerSignUp,
    customerSignIn,
  };
}
