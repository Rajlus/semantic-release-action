#!/usr/bin/env bash
set -euo pipefail

# Run npm audit, apply allowlist, generate markdown report.
# Fails the pipeline if unallowlisted vulnerabilities meet the severity threshold.
#
# Writes report to /tmp/security-audit.md and posts as PR comment.
#
# Requires: npm, node, GITHUB_TOKEN, PR_NUMBER (optional for comment)
# Sources: parse-dependency-policy.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=parse-dependency-policy.sh
source "$SCRIPT_DIR/parse-dependency-policy.sh"

# --- Run npm audit ---
echo "::group::Running npm audit"
AUDIT_CMD="npm audit --json"
if [ "$POLICY_AUDIT_PRODUCTION_ONLY" = "true" ]; then
  AUDIT_CMD="$AUDIT_CMD --omit=dev"
  echo "::notice::Auditing production dependencies only (--omit=dev)"
fi
$AUDIT_CMD > /tmp/npm-audit.json 2>/dev/null || true
echo "::endgroup::"

# --- Parse and evaluate ---
AUDIT_EXIT_CODE=0

node -e "
const fs = require('fs');

// --- Severity ordering ---
const SEVERITY_ORDER = { critical: 4, high: 3, moderate: 2, low: 1, info: 0 };

function sevNum(s) {
  return SEVERITY_ORDER[(s || '').toLowerCase()] || 0;
}

// --- Read audit data ---
let auditData = {};
try {
  auditData = JSON.parse(fs.readFileSync('/tmp/npm-audit.json', 'utf8'));
} catch (e) {
  // No audit data or invalid JSON
}

const vulns = auditData.vulnerabilities || {};

// --- Extract unique advisories ---
const advisories = [];
const seen = new Set();

for (const [pkg, info] of Object.entries(vulns)) {
  for (const via of (info.via || [])) {
    if (typeof via !== 'object' || !via.url) continue;

    const ghsaMatch = via.url.match(/GHSA-[a-z0-9-]+/);
    const ghsaId = ghsaMatch ? ghsaMatch[0] : String(via.source);

    if (seen.has(ghsaId)) continue;
    seen.add(ghsaId);

    const fix = info.fixAvailable
      ? (typeof info.fixAvailable === 'object'
        ? info.fixAvailable.name + '@' + info.fixAvailable.version
        : 'Yes')
      : 'No';

    advisories.push({
      id: ghsaId,
      severity: (via.severity || 'unknown').toLowerCase(),
      package: via.name || pkg,
      title: via.title || 'Unknown',
      fix,
      url: via.url,
    });
  }
}

// --- Read allowlist ---
const allowlist = new Map();
const allowlistFile = process.env.POLICY_ALLOWLIST_FILE;
if (allowlistFile) {
  try {
    const lines = fs.readFileSync(allowlistFile, 'utf8').trim().split('\n');
    for (const line of lines) {
      const [id, reason, expires] = line.split('\t');
      if (id) allowlist.set(id.trim(), { reason: reason || '', expires: expires || '' });
    }
  } catch (e) { /* no allowlist */ }
}

// --- Apply allowlist and threshold ---
const threshold = process.env.POLICY_AUDIT_FAIL_ON || 'high';
const thresholdNum = sevNum(threshold);
const today = new Date().toISOString().split('T')[0];

const failing = [];
const waived = [];
const belowThreshold = [];

for (const adv of advisories) {
  const entry = allowlist.get(adv.id);

  if (entry) {
    // Check expiry
    if (entry.expires && entry.expires < today) {
      // Expired — treat as not allowlisted
    } else {
      waived.push({ ...adv, reason: entry.reason, expires: entry.expires });
      continue;
    }
  }

  if (sevNum(adv.severity) >= thresholdNum) {
    failing.push(adv);
  } else {
    belowThreshold.push(adv);
  }
}

// --- Build markdown ---
let md = '## 🔒 Security Audit\n\n';

const total = advisories.length;

if (total === 0) {
  md += '✅ **No vulnerabilities found.** Clean audit.\n\n';
} else {
  // Summary counts
  const counts = {};
  for (const a of advisories) {
    counts[a.severity] = (counts[a.severity] || 0) + 1;
  }
  const countStr = Object.entries(counts)
    .sort((a, b) => sevNum(b[0]) - sevNum(a[0]))
    .map(([sev, n]) => n + ' ' + sev)
    .join(', ');

  if (failing.length > 0) {
    const vulnWord = failing.length === 1 ? 'vulnerability' : 'vulnerabilities';
    md += '❌ **' + failing.length + ' ' + vulnWord + '** above threshold (\`' + threshold + '\`)\n\n';
  } else {
    md += '✅ **No unallowlisted vulnerabilities** above threshold (\`' + threshold + '\`)\n\n';
  }

  md += 'Total: ' + total + ' advisories (' + countStr + ')\n\n';

  // Failing table
  if (failing.length > 0) {
    md += '### Failing Vulnerabilities\n\n';
    md += '| Advisory | Severity | Package | Description | Fix |\n';
    md += '|----------|----------|---------|-------------|-----|\n';
    for (const a of failing.sort((x, y) => sevNum(y.severity) - sevNum(x.severity))) {
      const sevEmoji = a.severity === 'critical' ? '🔴' : '🟠';
      md += '| [' + a.id + '](' + a.url + ') | ' + sevEmoji + ' ' + a.severity + ' | ' + a.package + ' | ' + a.title + ' | ' + a.fix + ' |\n';
    }
    md += '\n';
  }

  // Waived table
  if (waived.length > 0) {
    md += '### Allowlisted (waived)\n\n';
    md += '| Advisory | Severity | Package | Reason | Expires |\n';
    md += '|----------|----------|---------|--------|--------:|\n';
    for (const a of waived) {
      md += '| ' + a.id + ' | ' + a.severity + ' | ' + a.package + ' | ' + a.reason + ' | ' + (a.expires || '—') + ' |\n';
    }
    md += '\n';
  }

  // Below threshold
  if (belowThreshold.length > 0) {
    md += '<details><summary>Below threshold (' + belowThreshold.length + ' advisories)</summary>\n\n';
    md += '| Advisory | Severity | Package | Description | Fix |\n';
    md += '|----------|----------|---------|-------------|-----|\n';
    for (const a of belowThreshold.sort((x, y) => sevNum(y.severity) - sevNum(x.severity))) {
      md += '| [' + a.id + '](' + a.url + ') | ' + a.severity + ' | ' + a.package + ' | ' + a.title + ' | ' + a.fix + ' |\n';
    }
    md += '\n</details>\n\n';
  }
}

md += '---\n';
md += '*Threshold: \`' + threshold + '\` | Generated by [semantic-release-action](https://github.com/Rajlus/semantic-release-action)*\n';

fs.writeFileSync('/tmp/security-audit.md', md);

// Set output
const status = failing.length > 0 ? 'fail' : 'pass';
fs.appendFileSync(process.env.GITHUB_OUTPUT, 'status=' + status + '\n');

if (failing.length > 0) {
  // Write exit code marker for bash to read
  fs.writeFileSync('/tmp/security-audit-exit', '1');
  console.log('::error::Security audit found ' + failing.length + ' unallowlisted vulnerabilities at or above \'' + threshold + '\' severity. See PR comment for details.');
} else {
  fs.writeFileSync('/tmp/security-audit-exit', '0');
  console.log('Security audit passed: ' + total + ' total advisories, ' + waived.length + ' waived, 0 above threshold.');
}
" || {
  echo "::error::security-audit.sh: node script failed"
  echo "status=fail" >> "$GITHUB_OUTPUT"
  AUDIT_EXIT_CODE=1
}

# Read exit code from node script
if [ -f /tmp/security-audit-exit ]; then
  AUDIT_EXIT_CODE=$(cat /tmp/security-audit-exit)
fi

# --- Post PR comment (before potential exit 1) ---
if [ -n "${PR_NUMBER:-}" ]; then
  bash "$SCRIPT_DIR/update-pr-comment.sh" \
    "SECURITY_AUDIT" \
    "/tmp/security-audit.md" \
    "security audit"
fi

# --- Exit with appropriate code ---
exit "$AUDIT_EXIT_CODE"
