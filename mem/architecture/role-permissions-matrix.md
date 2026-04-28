---
name: Role Permissions Matrix
description: DB-driven role→module access at /admin/roles. role_module_access table is source of truth; sidebar filters per user roles. Admin/MCP unaffected.
type: feature
---

## Source of truth
- Table `role_module_access (role app_role, module_id text, UNIQUE(role, module_id))`.
- RLS: authenticated read, admin-only write.
- Seeded in migration with the previously hardcoded `allowedRoles` defaults from `adminNavigation.ts`.

## UI
- Page: `/admin/roles` (`RolePermissionsPage.tsx`). Matrix with modules as rows, `FUNCTIONAL_ROLES` as columns, checkbox per cell.
- Hook: `useRoleModuleAccess()` returns `Partial<Record<AppRole, Set<string>>>`.
- Toggle: `useToggleRoleModuleAccess()` insert/delete on (role, module_id).

## Sidebar logic
`AdminSidebar.tsx`:
1. Admin → sees everything (no filter).
2. Build `allowedModuleIds` from union of `accessMap[role]` for all user roles.
3. Items with `moduleId`: visible iff `allowedModuleIds` contains it AND the module itself is enabled.
4. Items without `moduleId` in role-restricted groups (allowedRoles): hidden for non-admins.
5. Items without `moduleId` in open groups (Main/Content/Setup with no allowedRoles): visible if `item.allowedRoles` matches or is unset.
6. `adminOnly` groups (Setup) hidden for non-admins.

## What's still hardcoded
- `NavGroup.allowedRoles` / `NavItem.allowedRoles` in `adminNavigation.ts` are now **only used as defaults for non-module items**. Module items are fully DB-driven.
- Adding a new module → defaults to "no role grants" until admin opens `/admin/roles` and grants it. Seed in a migration if you want it auto-granted.

## MCP unchanged
Skill exposure is module-based, not role-based. The matrix only affects the human admin sidebar.
