#!/usr/bin/env bash
# Delete ALL deployed Supabase Edge Functions for a project.
# Usage: ./scripts/delete-all-edge-functions.sh <project-ref>
#
# Requires: supabase CLI (logged in). jq optional but recommended.
# DANGER: Irreversible. You must type DELETE to confirm.

set -euo pipefail

PROJECT_REF="${1:-}"
if [[ -z "$PROJECT_REF" ]]; then
  echo "Usage: $0 <project-ref>"
  exit 1
fi

if ! command -v supabase >/dev/null 2>&1; then
  echo "Error: 'supabase' CLI not found in PATH."
  exit 1
fi

# Strict validator: must match Supabase function-name rules.
VALID_RE='^[A-Za-z][A-Za-z0-9_-]*$'

extract_names() {
  # Try JSON first.
  if command -v jq >/dev/null 2>&1; then
    local json
    json="$(supabase functions list --project-ref "$PROJECT_REF" --output json 2>/dev/null || true)"
    if [[ -n "$json" ]] && echo "$json" | jq empty 2>/dev/null; then
      echo "$json" | jq -r '.[] | (.slug // .name // empty)'
      return
    fi
  fi

  # Fallback: parse the table. Strip ALL non-ASCII (box chars) + pipes,
  # then keep only tokens that look like valid function names.
  supabase functions list --project-ref "$PROJECT_REF" 2>/dev/null \
    | LC_ALL=C tr -d '\200-\377' \
    | tr '|' ' ' \
    | awk '{for(i=1;i<=NF;i++) print $i}' \
    | grep -E "$VALID_RE" \
    | grep -Ev '^(ID|NAME|SLUG|VERSION|STATUS|UPDATED|CREATED|ACTIVE|VERIFY_JWT|true|false)$'
}

echo "Fetching deployed functions for project: $PROJECT_REF"
RAW="$(extract_names || true)"

# Final filter: dedupe + validate strictly.
FUNCTIONS="$(echo "$RAW" | grep -E "$VALID_RE" | sort -u || true)"

if [[ -z "$FUNCTIONS" ]]; then
  echo "No deployed functions found (or could not parse output)."
  echo ""
  echo "Try manually: supabase functions list --project-ref $PROJECT_REF"
  exit 0
fi

COUNT=$(echo "$FUNCTIONS" | wc -l | tr -d ' ')
echo ""
echo "Found $COUNT deployed function(s):"
echo "$FUNCTIONS" | sed 's/^/  - /'
echo ""
echo "⚠️  This will DELETE ALL $COUNT functions from project $PROJECT_REF."
read -r -p "Type DELETE to confirm: " CONFIRM
if [[ "$CONFIRM" != "DELETE" ]]; then
  echo "Aborted."
  exit 1
fi

FAILED=()
DELETED=0
while IFS= read -r fn; do
  [[ -z "$fn" ]] && continue
  # Re-validate every name right before calling delete.
  if ! [[ "$fn" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]]; then
    echo "→ Skipping invalid name: '$fn'"
    continue
  fi
  echo "→ Deleting $fn ..."
  if supabase functions delete "$fn" --project-ref "$PROJECT_REF"; then
    echo "  ✓ deleted"
    DELETED=$((DELETED + 1))
  else
    echo "  ✗ failed"
    FAILED+=("$fn")
  fi
done <<< "$FUNCTIONS"

echo ""
echo "Deleted: $DELETED / $COUNT"
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "⚠️  Failed:"
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
echo "✅ Done."
