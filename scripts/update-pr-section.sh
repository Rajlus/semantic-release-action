#!/usr/bin/env bash
set -euo pipefail

# Generic script to update a section in a PR description between HTML comment markers.
# Used by update-pr-changelog.sh and update-pr-review.sh.
#
# Usage: update-pr-section.sh <start_marker> <end_marker> <content_file> <section_label>
#
# Requires: GH_TOKEN (or GITHUB_TOKEN), PR_NUMBER

START_MARKER="${1:?Usage: update-pr-section.sh <start_marker> <end_marker> <content_file> <section_label>}"
END_MARKER="${2:?}"
CONTENT_FILE="${3:?}"
SECTION_LABEL="${4:?}"

if [ -z "${PR_NUMBER:-}" ]; then
  echo "::warning::PR_NUMBER not set, skipping PR body update"
  exit 0
fi

if [ ! -f "$CONTENT_FILE" ]; then
  echo "::warning::No content file found at $CONTENT_FILE"
  exit 0
fi

SECTION_CONTENT=$(cat "$CONTENT_FILE")

SECTION="${START_MARKER}
${SECTION_CONTENT}
${END_MARKER}"

# Get current PR body (// "" ensures null becomes empty string)
CURRENT_BODY=$(gh pr view "$PR_NUMBER" --json body --jq '.body // ""' 2>/dev/null || echo "")

# Write current body to temp file for reliable line-based processing
BODY_FILE=$(mktemp)
printf '%s' "$CURRENT_BODY" > "$BODY_FILE"

if grep -qF "$START_MARKER" "$BODY_FILE"; then
  echo "::notice::Updating existing $SECTION_LABEL section in PR description"

  # Get line numbers of markers
  START_LINE=$(grep -nF "$START_MARKER" "$BODY_FILE" | head -1 | cut -d: -f1)
  END_LINE=$(grep -nF "$END_MARKER" "$BODY_FILE" | tail -1 | cut -d: -f1)

  # Extract before (up to but not including START_MARKER line)
  BEFORE=""
  if [ "$START_LINE" -gt 1 ]; then
    BEFORE=$(head -n $((START_LINE - 1)) "$BODY_FILE")
  fi

  # Extract after (everything after END_MARKER line)
  TOTAL_LINES=$(wc -l < "$BODY_FILE")
  AFTER=""
  if [ "$END_LINE" -lt "$TOTAL_LINES" ]; then
    AFTER=$(tail -n +$((END_LINE + 1)) "$BODY_FILE")
  fi

  # Compose new body: trim trailing blank lines from BEFORE
  if [ -n "$BEFORE" ]; then
    BEFORE=$(printf '%s' "$BEFORE" | sed -e :a -e '/^[[:space:]]*$/{ $d; N; ba; }')
    NEW_BODY="${BEFORE}

${SECTION}"
  else
    NEW_BODY="${SECTION}"
  fi

  # Append AFTER if present
  if [ -n "$AFTER" ]; then
    NEW_BODY="${NEW_BODY}
${AFTER}"
  fi
else
  echo "::notice::Appending $SECTION_LABEL section to PR description"
  if [ -n "$CURRENT_BODY" ]; then
    NEW_BODY="${CURRENT_BODY}

${SECTION}"
  else
    NEW_BODY="${SECTION}"
  fi
fi

rm -f "$BODY_FILE"

# Update PR body via temp file (avoids argument length limits)
TMPFILE=$(mktemp)
printf '%s\n' "$NEW_BODY" > "$TMPFILE"
gh pr edit "$PR_NUMBER" --body-file "$TMPFILE"
rm -f "$TMPFILE"

echo "::notice::PR #$PR_NUMBER body updated with $SECTION_LABEL"
