#!/usr/bin/env bash
# Delete ALL deployed Supabase Edge Functions for a project.
# Usage:
#   ./scripts/delete-all-edge-functions.sh <project-ref>
#   ./scripts/delete-all-edge-functions.sh --project-ref <project-ref>
#   ./scripts/delete-all-edge-functions.sh -p <project-ref>
#
# Requires: supabase CLI (logged in). jq optional but recommended.
# DANGER: Irreversible. You must type DELETE to confirm.

set -euo pipefail

usage() {
  echo "Usage: $0 <project-ref> | --project-ref <project-ref> | -p <project-ref>"
}

PROJECT_REF=""
DEBUG=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-ref|-p)
      PROJECT_REF="${2:-}"
      shift 2
      ;;
    --debug)
      DEBUG=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -z "$PROJECT_REF" ]]; then
        PROJECT_REF="$1"
        shift
      else
        echo "Unexpected argument: $1"
        usage
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$PROJECT_REF" ]]; then
  usage
  exit 1
fi

if ! command -v supabase >/dev/null 2>&1; then
  echo "Error: 'supabase' CLI not found in PATH."
  exit 1
fi

VALID_RE='^[A-Za-z][A-Za-z0-9_-]*$'
LIST_STDERR=""
LIST_OUTPUT=""
LIST_STATUS=0

run_functions_list() {
  local output_mode="$1"
  local tmp_err
  tmp_err="$(mktemp)"

  set +e
  LIST_OUTPUT="$(supabase functions list --project-ref "$PROJECT_REF" --output "$output_mode" 2>"$tmp_err")"
  LIST_STATUS=$?
  set -e

  LIST_STDERR="$(cat "$tmp_err")"
  rm -f "$tmp_err"

  return $LIST_STATUS
}

extract_names() {
  if command -v jq >/dev/null 2>&1; then
    if run_functions_list json && [[ -n "$LIST_OUTPUT" ]] && echo "$LIST_OUTPUT" | jq empty >/dev/null 2>&1; then
      echo "$LIST_OUTPUT" | jq -r '.[] | (.slug // .name // empty)'
      return 0
    fi
  fi

  if run_functions_list pretty; then
    echo "$LIST_OUTPUT" \
      | LC_ALL=C tr -d '\200-\377' \
      | tr '|' ' ' \
      | awk '{for(i=1;i<=NF;i++) print $i}' \
      | grep -E "$VALID_RE" \
      | grep -Ev '^(ID|NAME|SLUG|VERSION|STATUS|UPDATED|CREATED|ACTIVE|VERIFY_JWT|true|false)$'
    return 0
  fi

  return 1
}

echo "Fetching deployed functions for project: $PROJECT_REF"
RAW="$(extract_names || true)"
FUNCTIONS="$(echo "$RAW" | grep -E "$VALID_RE" | sort -u || true)"

if [[ -z "$FUNCTIONS" ]]; then
  if [[ $LIST_STATUS -ne 0 ]]; then
    echo "Could not list deployed functions for project '$PROJECT_REF'."
    if [[ -n "$LIST_STDERR" ]]; then
      echo ""
      echo "CLI said:"
      echo "$LIST_STDERR"
    fi
    echo ""
    echo "Common causes:"
    echo "  - wrong project ref"
    echo "  - not logged in via 'supabase login'"
    echo "  - missing access to that project"
    echo "  - older Supabase CLI version"
    echo ""
    echo "Try manually: supabase functions list --project-ref $PROJECT_REF --output pretty"
    exit 1
  fi

  echo "No deployed functions found for project '$PROJECT_REF'."
  if [[ $DEBUG -eq 1 && -n "$LIST_OUTPUT" ]]; then
    echo ""
    echo "Raw CLI output:"
    echo "$LIST_OUTPUT"
  fi
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
