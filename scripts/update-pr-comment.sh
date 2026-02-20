#!/usr/bin/env bash
set -euo pipefail

# Generic script to create or update a PR comment identified by a unique HTML marker.
# Used by dependency-check.sh and security-audit.sh.
#
# Usage: update-pr-comment.sh <marker> <content_file> <comment_label>
#
# Requires: GH_TOKEN (or GITHUB_TOKEN), PR_NUMBER

MARKER="${1:?Usage: update-pr-comment.sh <marker> <content_file> <comment_label>}"
CONTENT_FILE="${2:?}"
COMMENT_LABEL="${3:?}"

if [ -z "${PR_NUMBER:-}" ]; then
  echo "::warning::PR_NUMBER not set, skipping PR comment"
  exit 0
fi

if [ ! -f "$CONTENT_FILE" ]; then
  echo "::warning::No content file found at $CONTENT_FILE"
  exit 0
fi

CONTENT=$(cat "$CONTENT_FILE")
FULL_BODY="<!-- ${MARKER} -->
${CONTENT}"

# Find existing comment with this marker
COMMENT_ID=$(gh api \
  "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" \
  --paginate \
  --jq ".[] | select(.body | startswith(\"<!-- ${MARKER} -->\")) | .id" \
  2>/dev/null | head -1 || echo "")

TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT
printf '%s\n' "$FULL_BODY" > "$TMPFILE"

if [ -n "$COMMENT_ID" ]; then
  echo "::notice::Updating existing ${COMMENT_LABEL} comment (ID: ${COMMENT_ID})"
  if ! gh api \
    -X PATCH \
    "repos/${GITHUB_REPOSITORY}/issues/comments/${COMMENT_ID}" \
    -F "body=@${TMPFILE}" 2>/dev/null; then
    echo "::warning::Failed to update ${COMMENT_LABEL} comment (ID: ${COMMENT_ID}), trying to create new one"
    if ! gh pr comment "$PR_NUMBER" --body-file "$TMPFILE" 2>/dev/null; then
      echo "::warning::Failed to post ${COMMENT_LABEL} comment on PR #${PR_NUMBER}"
    fi
  fi
else
  echo "::notice::Creating new ${COMMENT_LABEL} comment on PR #${PR_NUMBER}"
  if ! gh pr comment "$PR_NUMBER" --body-file "$TMPFILE" 2>/dev/null; then
    echo "::warning::Failed to post ${COMMENT_LABEL} comment on PR #${PR_NUMBER}"
  fi
fi

echo "::notice::PR #${PR_NUMBER} updated with ${COMMENT_LABEL}"
