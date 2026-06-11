UI-only work, no migrations/modules touched.

## 1. Inventory Valuation tab (inside InventoryPage)
- Add a new tab "Valuation" alongside existing tabs in `src/pages/admin/InventoryPage.tsx`.
- New component `src/components/admin/inventory/InventoryValuationPanel.tsx`:
  - Calls `supabase.rpc('inventory_valuation_report', { p_limit: 500 })` via TanStack Query (`useInventoryValuation` hook in `src/hooks/useInventoryValuation.ts`).
  - Prominent header card: total inventory value (formatted via `formatPrice(total_value_cents, currency)`).
  - Table (shadcn `Table`): Product · On-hand qty · Avg unit cost · Total value. Right-align numeric cols, sortable by value desc by default.
  - Loading skeleton + empty state ("No stock on hand").
  - Refresh button invalidates the query.

## 2. costing_method on product category
- Extend `ProductCategory` interface in `src/hooks/useProductCategories.ts` with `costing_method: 'average' | 'fifo'` (optional, default `'average'`).
- In the category edit dialog (locate under `src/components/admin/products/` or `ProductCategoriesPage`), add a `Select` with options Average / FIFO right below name/description. Persists via existing `useUpdateProductCategory`.

## 3. cost_cents on ProductDialog
- Extend `Product` interface in `src/hooks/useProducts.ts` with `cost_cents?: number | null`.
- In `src/components/admin/ProductDialog.tsx`, add a `MoneyInput` labeled "Cost price" next to the existing price field, same grid row. Saves via existing update mutation.

## Files touched
- `src/pages/admin/InventoryPage.tsx` (add tab)
- `src/components/admin/inventory/InventoryValuationPanel.tsx` (new)
- `src/hooks/useInventoryValuation.ts` (new)
- `src/hooks/useProducts.ts` (add field to type)
- `src/hooks/useProductCategories.ts` (add field to type)
- `src/components/admin/ProductDialog.tsx` (add Cost price input)
- Category edit dialog (one file under `src/components/admin/products/` — confirmed during build)

## Out of scope
- `supabase/migrations/`, `src/lib/modules/*`, `module-skills.json` — untouched. Assumes Claude has shipped the `inventory_valuation_report` RPC, `product_categories.costing_method`, and `products.cost_cents` columns.
