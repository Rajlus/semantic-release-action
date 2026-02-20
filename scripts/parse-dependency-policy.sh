#!/usr/bin/env bash
# Parse .dependency-policy.yml from repo root, fall back to action inputs.
#
# This script is meant to be sourced by other scripts:
#   source "$(dirname "$0")/parse-dependency-policy.sh"
#
# Reads from environment (action inputs as fallback):
#   INPUT_CORE_PACKAGES       - comma-separated list
#   INPUT_AUDIT_FAIL_ON       - critical|high|moderate|low
#   INPUT_AUDIT_PRODUCTION_ONLY - true|false
#
# Exports:
#   POLICY_CORE_PACKAGES      - newline-separated list of package names
#   POLICY_AUDIT_FAIL_ON      - severity threshold
#   POLICY_AUDIT_PRODUCTION_ONLY - true|false
#   POLICY_ALLOWLIST_FILE     - path to TSV file (id\treason\texpires) or empty

POLICY_FILE=".dependency-policy.yml"
POLICY_ALLOWLIST_FILE=""

if [ -f "$POLICY_FILE" ]; then
  echo "::notice::Using config from $POLICY_FILE"

  # --- Parse core-packages ---
  # Note: uses [ \t] instead of \s for BSD awk (macOS) compatibility
  POLICY_CORE_PACKAGES=$(awk '
    /^core-packages:/ { in_section=1; next }
    in_section && /^[^ \t#]/ { exit }
    in_section && /^[ \t]+-[ \t]+/ {
      sub(/^[ \t]+-[ \t]+/, "")
      gsub(/["'"'"']/, "")
      gsub(/[ \t]*$/, "")
      if ($0 != "") print
    }
  ' "$POLICY_FILE")

  # --- Parse audit.fail-on ---
  POLICY_AUDIT_FAIL_ON=$(awk '
    /^audit:/ { in_audit=1; next }
    in_audit && /^[^ \t#]/ { exit }
    in_audit && /^[ \t]+fail-on:/ {
      sub(/.*fail-on:[ \t]*/, "")
      gsub(/["'"'"']/, "")
      gsub(/[ \t]*$/, "")
      print
    }
  ' "$POLICY_FILE")

  # --- Parse audit.production-only ---
  POLICY_AUDIT_PRODUCTION_ONLY=$(awk '
    /^audit:/ { in_audit=1; next }
    in_audit && /^[^ \t#]/ { exit }
    in_audit && /^[ \t]+production-only:/ {
      sub(/.*production-only:[ \t]*/, "")
      gsub(/["'"'"']/, "")
      gsub(/[ \t]*$/, "")
      print
    }
  ' "$POLICY_FILE")

  # --- Parse audit.allowlist ---
  ALLOWLIST_TMP=$(mktemp)
  trap 'rm -f "$ALLOWLIST_TMP"' EXIT

  # Pass POLICY_FILE as argument (not interpolated into JS string) to prevent injection
  node -e "
    const fs = require('fs');
    const policyFile = process.argv[1];
    const content = fs.readFileSync(policyFile, 'utf8');

    // Find the allowlist section
    const lines = content.split('\n');
    let inAllowlist = false;
    let currentEntry = null;
    const entries = [];

    for (const line of lines) {
      if (/^\s+allowlist:/.test(line)) { inAllowlist = true; continue; }
      if (inAllowlist && /^[^ \t#]/.test(line)) break;
      if (!inAllowlist) continue;

      if (/^\s+-\s+id:/.test(line)) {
        if (currentEntry) entries.push(currentEntry);
        currentEntry = { id: '', reason: '', expires: '' };
        const m = line.match(/id:\s*[\"']?([^\"'\n]+)[\"']?/);
        if (m) currentEntry.id = m[1].trim();
      } else if (currentEntry) {
        const reasonMatch = line.match(/reason:\s*[\"']?([^\"'\n]+)[\"']?/);
        const expiresMatch = line.match(/expires:\s*[\"']?([^\"'\n]+)[\"']?/);
        if (reasonMatch) currentEntry.reason = reasonMatch[1].trim();
        if (expiresMatch) currentEntry.expires = expiresMatch[1].trim();
      }
    }
    if (currentEntry) entries.push(currentEntry);

    for (const e of entries) {
      if (e.id) console.log([e.id, e.reason, e.expires].join('\t'));
    }
  " "$POLICY_FILE" > "$ALLOWLIST_TMP" 2>/dev/null || true

  if [ -s "$ALLOWLIST_TMP" ]; then
    POLICY_ALLOWLIST_FILE="$ALLOWLIST_TMP"
    # Clear trap so file is not deleted
    trap - EXIT
  else
    rm -f "$ALLOWLIST_TMP"
    trap - EXIT
  fi
else
  echo "::notice::No $POLICY_FILE found, using action input defaults"
fi

# --- Apply fallbacks from action inputs ---
if [ -z "$POLICY_CORE_PACKAGES" ] && [ -n "${INPUT_CORE_PACKAGES:-}" ]; then
  # Convert comma-separated to newline-separated
  POLICY_CORE_PACKAGES=$(echo "$INPUT_CORE_PACKAGES" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$')
fi

if [ -z "${POLICY_AUDIT_FAIL_ON:-}" ]; then
  POLICY_AUDIT_FAIL_ON="${INPUT_AUDIT_FAIL_ON:-high}"
fi

if [ -z "${POLICY_AUDIT_PRODUCTION_ONLY:-}" ]; then
  POLICY_AUDIT_PRODUCTION_ONLY="${INPUT_AUDIT_PRODUCTION_ONLY:-false}"
fi

# --- Validate audit-fail-on ---
case "$POLICY_AUDIT_FAIL_ON" in
  critical|high|moderate|low) ;;
  *) echo "::error::Invalid audit-fail-on value: '$POLICY_AUDIT_FAIL_ON' (must be critical, high, moderate, or low)"; exit 1 ;;
esac

export POLICY_CORE_PACKAGES
export POLICY_AUDIT_FAIL_ON
export POLICY_AUDIT_PRODUCTION_ONLY
export POLICY_ALLOWLIST_FILE
