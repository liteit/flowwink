import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

/**
 * Guardrail: the account portal is cross-functional, not an ecommerce feature.
 *
 * Magnus, 2026-07-22: employees must reach the portal without e-commerce —
 * an HR-only site (leave, payslips, expenses) had NO visible way in, because
 * the header's AccountIndicator was gated on the ecommerce module alone.
 *
 * The rules:
 *   • header entrance   → ecommerce OR hr
 *   • cart              → ecommerce only
 *   • portal nav        → commerce sections (Orders/Addresses/Wishlist) follow
 *     the ecommerce module; employee sections follow the caller's identity
 *     (isEmployee), which is a different axis on purpose
 */

const root = process.cwd();
const read = (p: string) => readFileSync(join(root, p), 'utf8');

describe('account portal access', () => {
  it('the header entrance opens for ecommerce OR hr, the cart for ecommerce only', () => {
    const nav = read('src/components/public/PublicNavigation.tsx');
    expect(nav).toMatch(/accountEnabled = ecommerceEnabled \|\| hrEnabled/);
    // Both desktop and mobile render sites use the shared flag…
    expect(nav.match(/\{accountEnabled && <AccountIndicator \/>\}/g)?.length).toBe(2);
    // …and the cart never widened with it.
    expect(nav.match(/\{ecommerceEnabled && <CartIndicator \/>\}/g)?.length).toBe(2);
    expect(nav).not.toMatch(/accountEnabled && <CartIndicator/);
  });

  it('commerce portal sections follow the ecommerce module, not identity', () => {
    const layout = read('src/pages/account/AccountLayout.tsx');
    expect(layout).toMatch(/\.\.\.\(ecommerceEnabled \? commerceNav : \[\]\)/);
    // Employee self-service stays identity-gated — modules and identity are
    // different axes.
    expect(layout).toMatch(/\.\.\.\(isEmployee \? employeeNav : \[\]\)/);
  });

  it('with ecommerce off, the portal index does not land on the Orders page', () => {
    const layout = read('src/pages/account/AccountLayout.tsx');
    expect(layout).toMatch(/!ecommerceEnabled && location\.pathname === '\/account'/);
    expect(layout).toMatch(/<Navigate to="\/account\/assistant" replace \/>/);
  });
});
