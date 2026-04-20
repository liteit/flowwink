

# Fix Module Registry Drift — Återanslut quotes/approvals/reconciliation

## Vad är fel

Vitest-guardrailsen (`module-registry.guardrails.test.ts`) failar på 2 av 4 tester. Tre moduler har manifest (`defineModule()`) och exporteras från barrel, men de är **frikopplade från resten av plattformen**:

| Modul | Manifest finns | Settings-key | Importeras i registry | Effekt |
|-------|---------------|--------------|----------------------|--------|
| `quotes` | ✅ | ❌ | ❌ | Skill exponeras inte via MCP, kan inte togglas |
| `approvals` | ✅ | ✅ | ❌ | Settings finns men self-registration sker inte |
| `reconciliation` | ✅ | ✅ | ❌ | Samma — drift mellan manifest och registry |

Detta är **exakt det MCP-problemet du ser**: när ClawWink/externa agenter anropar skills (t.ex. `create_quote`, `approve_expense`, `reconcile_transaction`) hittar MCP-servern ingen aktiv modul och blockerar/404:ar dem — eller så filtrerar `mcp-module-aware-filtering` bort dem trots att deras manifest finns.

Det matchar också `mem://development/new-module-checklist` som kräver: manifest + settings-key + registry-import för varje ny modul.

## Vad som ska göras

### 1. Lägg till `quotes` i `defaultModulesSettings` (`src/hooks/useModules.tsx`)
Ny entry med samma form som `invoicing`/`deals`:
- `name: 'Quotes'`, `category: 'data'`, `autonomy: 'view-required'`, `adminUI: true`
- Beskrivning som speglar offert-funktionen (skicka offerter, konvertera till order/invoice)
- `enhancedByFlowPilot: true` (autonom uppföljning på skickade offerter)

### 2. Lägg till alla tre i `src/lib/module-registry.ts`
Importera `quotesModule`, `approvalsModule`, `reconciliationModule` från `./modules` och registrera dem i samma block där övriga moduler self-registrerar (`moduleRegistry.register(...)`).

### 3. Verifiera att MCP-filtret nu släpper igenom dem
Kör `vitest run src/lib/__tests__/module-registry.guardrails.test.ts` — alla 4 tester ska gå grönt.

Sedan i preview: öppna `/admin/modules` och bekräfta att Quotes/Approvals/Reconciliation visas som riktiga modulkort med toggle.

### 4. Bonus-fix: `ModuleDetailSheet` ref-warning (konsollog)
Konsollen visar `Function components cannot be given refs` från `SheetHeader` i `ModuleDetailSheet.tsx`. Det är en separat, icke-blockerande bug men trivial att laga (wrappa header-komponenten i `React.forwardRef` eller ta bort ref-prop:en). Inkluderas om det är samma kodväg.

## Varför detta löser MCP-felen

ClawWink träffar fel via MCP eftersom:
- `mcp-server` filtrerar skills baserat på `site_settings.modules[id].enabled`
- `quotes`-skills (t.ex. `create_quote`, `send_quote`) registreras i registry vid runtime — men eftersom `quotesModule` aldrig importeras i `module-registry.ts` sker self-registreringen aldrig → MCP exponerar inga `quotes`-tools → externa anrop misslyckas
- `approvals`/`reconciliation` har samma problem; deras heartbeats/skills går inte att rikta från MCP

Efter fixen är manifest, settings-key, registry-import och MCP-exponering i synk — vilket är hela poängen med guardrail-testet.

## Filer som ändras

- `src/hooks/useModules.tsx` — lägg till `quotes`-entry
- `src/lib/module-registry.ts` — importera och registrera 3 moduler
- (valfritt) `src/components/admin/modules/ModuleDetailSheet.tsx` — fixa forwardRef-warning

## Verifiering

```text
npx vitest run src/lib/__tests__/module-registry.guardrails.test.ts
→ Test Files 1 passed (1)
→ Tests       4 passed (4)
```

Sedan testa via MCP att `quotes`/`approvals`/`reconciliation`-skills syns under `/rest/groups` och kan kallas av ClawWink utan 404.

