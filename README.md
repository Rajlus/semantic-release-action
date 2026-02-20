# semantic-release-action

Reusable GitHub Composite Action for [semantic-release](https://semantic-release.gitbook.io/) with automatic changelog generation, PR previews, dependency monitoring, and security auditing. Also provides a reusable workflow for [Claude Code Review](#claude-code-review-reusable-workflow).

## Features

- Automatic versioning based on [Conventional Commits](https://www.conventionalcommits.org/)
- CHANGELOG.md generation and commit back to repo
- GitHub Release creation with release notes
- PR changelog preview (updates PR body with upcoming changes)
- **Dependency check**: monitors core packages for major version updates
- **Security audit**: runs `npm audit` with allowlist support and configurable fail threshold
- Zero-config default (generates `.releaserc.yml` if none exists)
- Customizable via extra plugins, repo-level config, and `.dependency-policy.yml`

## Usage

### Release on push to main

```yaml
# .github/workflows/release.yml
name: Release

on:
  push:
    branches: [main]

permissions:
  contents: write
  issues: write
  pull-requests: write

jobs:
  release:
    name: Semantic Release
    runs-on: ubuntu-latest
    if: "!contains(github.event.head_commit.message, 'chore(release)')"

    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          persist-credentials: false

      - uses: Rajlus/semantic-release-action@v1
        with:
          mode: release
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

### PR changelog preview

```yaml
# Add to your existing PR workflow
pr-changelog:
  name: PR Changelog Preview
  runs-on: ubuntu-latest
  if: github.event_name == 'pull_request'
  permissions:
    contents: read
    pull-requests: write

  steps:
    - uses: actions/checkout@v4
      with:
        fetch-depth: 0

    - uses: Rajlus/semantic-release-action@v1
      with:
        mode: pr-changelog
        github-token: ${{ secrets.GITHUB_TOKEN }}
```

### Dependency check on PRs

```yaml
dependency-check:
  name: Dependency Check
  runs-on: ubuntu-latest
  if: github.event_name == 'pull_request'
  permissions:
    contents: read
    pull-requests: write

  steps:
    - uses: actions/checkout@v4

    - uses: Rajlus/semantic-release-action@v1
      with:
        mode: dependency-check
        github-token: ${{ secrets.GITHUB_TOKEN }}
        # Optional fallback if no .dependency-policy.yml exists:
        core-packages: 'react,vite,typescript,tailwindcss'
```

### Security audit on PRs

```yaml
security-audit:
  name: Security Audit
  runs-on: ubuntu-latest
  if: github.event_name == 'pull_request'
  permissions:
    contents: read
    pull-requests: write

  steps:
    - uses: actions/checkout@v4

    - uses: Rajlus/semantic-release-action@v1
      with:
        mode: security-audit
        github-token: ${{ secrets.GITHUB_TOKEN }}
        audit-fail-on: 'high'
```

## Inputs

| Input | Description | Default |
|-------|-------------|---------|
| `mode` | `"release"`, `"pr-changelog"`, `"dependency-check"`, or `"security-audit"` | `"release"` |
| `github-token` | GitHub token (needs contents:write, pull-requests:write) | **required** |
| `node-version` | Node.js version | `"20"` |
| `extra-plugins` | Space-separated additional plugins (release modes only) | `""` |
| `dry-run` | Dry-run mode (release mode only) | `"false"` |
| `core-packages` | Comma-separated core packages to monitor (fallback for dependency-check) | `""` |
| `audit-fail-on` | Severity threshold that fails the pipeline: `critical`, `high`, `moderate`, `low` | `"high"` |
| `audit-production-only` | Only audit production dependencies | `"false"` |

## Outputs

| Output | Description |
|--------|-------------|
| `new-release-published` | `"true"` if a release was created |
| `new-release-version` | The released version (e.g. `1.2.3`) |
| `dependency-check-status` | `"pass"` or `"warn"` (major updates found) |
| `security-audit-status` | `"pass"` or `"fail"` (unallowlisted CVEs above threshold) |

## Default Plugins

| Plugin | Purpose |
|--------|---------|
| `@semantic-release/commit-analyzer` | Determines version bump from commits |
| `@semantic-release/release-notes-generator` | Generates release notes |
| `@semantic-release/changelog` | Updates CHANGELOG.md |
| `@semantic-release/git` | Commits changelog + version back to repo |
| `@semantic-release/github` | Creates GitHub Release |

## Custom Config

Place a `.releaserc.yml` (or any [supported config format](https://semantic-release.gitbook.io/semantic-release/usage/configuration)) in your repo root to override the defaults.

## Dependency Policy Config

Place a `.dependency-policy.yml` in your repo root to configure dependency checks and security audits. All fields are optional — action inputs serve as fallbacks.

```yaml
# .dependency-policy.yml

# Packages to monitor for major version updates (dependency-check mode)
core-packages:
  - react
  - react-dom
  - typescript
  - vite
  - tailwindcss
  - "@tanstack/react-query"

# Security audit configuration (security-audit mode)
audit:
  # Minimum severity that fails the pipeline
  fail-on: high              # critical | high | moderate | low

  # Only audit production deps (skip devDependencies)
  production-only: false

  # Allowlisted (waived) advisories that won't fail the pipeline
  allowlist:
    - id: "GHSA-67mh-4wv8-2f99"
      reason: "esbuild dev server — only affects local dev, not production"
      expires: "2026-06-30"  # Optional expiry date (YYYY-MM-DD)
    - id: "GHSA-2g4f-4pwh-qvx6"
      reason: "ajv ReDoS — only ESLint tooling, no runtime risk"
      # No expiry = permanent waive
```

### Allowlist behavior

- Uses **GHSA IDs** from `npm audit` advisory URLs (e.g. `GHSA-xxxx-yyyy-zzzz`)
- If `expires` is set and the date has passed, the advisory fails again
- Allowlisted advisories still appear in the PR comment (marked as waived)

---

## Claude Code Review (Reusable Workflow)

Automated, incremental PR code reviews powered by [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Provided as a [reusable workflow](https://docs.github.com/en/actions/sharing-automations/reusing-workflows) that can be called from any repository.

### Features

- Incremental reviews: updates a single comment instead of creating duplicates
- Automatically removes fixed issues on subsequent pushes
- PASS/FAIL decision logic with exit codes
- Customizable review focus per project

### Setup

1. Add the `CLAUDE_CODE_OAUTH_TOKEN` secret to your repository (Settings → Secrets → Actions)

2. Add the workflow call to your PR pipeline:

```yaml
# .github/workflows/pr-check.yml
code-review:
  name: Claude Code Review
  if: github.event_name == 'pull_request'
  uses: Rajlus/semantic-release-action/.github/workflows/claude-code-review.yml@main
  secrets:
    CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

### With project-specific review focus

```yaml
code-review:
  name: Claude Code Review
  if: github.event_name == 'pull_request'
  uses: Rajlus/semantic-release-action/.github/workflows/claude-code-review.yml@main
  secrets:
    CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
  with:
    review-focus: |
      - Supabase RLS & Auth: No service keys in client code
      - TanStack React Query: Query key conventions, stale time
      - Vite env vars: Only VITE_ prefixed vars in client bundle
```

### Workflow Inputs

| Input | Description | Default |
|-------|-------------|---------|
| `review-focus` | Additional project-specific review focus points (markdown list) | `""` |

### Secrets

| Secret | Description |
|--------|-------------|
| `CLAUDE_CODE_OAUTH_TOKEN` | OAuth token for Claude Code Action |
