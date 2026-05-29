# Security Scanning

Continuous, automated security testing for the Solidity codebase, set up per the
[Continuous Security Testing/Auditing](https://www.notion.so/3521aee1232480958886c3666758b9f0)
recommendation. This is **supplementary to formal audits**, not a replacement.

The scanners are split into a non-AI static-analysis tier (fast, free,
deterministic) and an AI tier (claude-code-action). The static tier runs on
every PR. **All AI workflows are manual (dispatch-only) for now** — promote them
to automatic PR / scheduled triggers once the API key is set and they've been
validated for cost and quality.

## Workflows

| Workflow | File | Trigger | Tools |
|----------|------|---------|-------|
| Static Analysis | `.github/workflows/security-static.yml` | PR, push to `main`, manual | Slither, Aderyn, Solhint |
| AI PR Review | `.github/workflows/security-ai-pr.yml` | Manual (pass PR number) | claude-code-action (diff-scoped) |
| AI Full Audit | `.github/workflows/security-ai-audit.yml` | Manual | claude-code-action (full codebase) |
| AI Skills Audit | `.github/workflows/security-ai-skills.yml` | Manual (experimental) | claude-code-action + community audit skills |

To make the AI reviews automatic later: add `on: pull_request` to the PR-review
workflow (it already contains the diff-scoped logic), and a `schedule:` cron to
the full-audit workflow.

### Static analysis (non-AI)

- **Slither** (`crytic/slither-action`) — runs against `solidity/`, auto-installs
  Foundry, uploads SARIF to the **Security → Code scanning** tab. Config:
  `solidity/slither.config.json` (filters out `lib/`, `test/`, `script/`).
- **Aderyn** (Cyfrin) — installed via the official installer, runs in `solidity/`,
  uploads SARIF.
- **Solhint** — linter. Config: `solidity/.solhint.json`, ignores in
  `solidity/.solhintignore`.

None of these block the build on findings (Slither uses `fail-on: none`);
results surface in the Security tab / job logs. Tighten later if desired.

### AI tier (claude-code-action)

All AI workflows **require the `ANTHROPIC_API_KEY` repository secret**. If it's
not set, the jobs detect that and skip cleanly (no failures). Prompts encode the
vault/curator threat model from the recommendation (fund drainage via arbitrary
calldata, NAV manipulation, withdrawal-timing attacks, untested adapter paths,
etc.).

- **PR Review** scopes the review to the PR diff and posts inline comments.
- **Full Audit** reads all of `solidity/src/` and files a summary GitHub issue.
- **Skills Audit** (experimental, manual) vendors community audit skills into
  `.claude/skills/` at runtime (so third-party code isn't committed) and runs a
  chosen skill: `solidity-auditor`/`x-ray` (pashov), `audit-prep` (CDSecurity),
  `scv-scan` (kadenzipfel), or `auditmos`. Validate cost/quality here before
  promoting any skill to a scheduled workflow.

## Setup

1. Add the repository secret `ANTHROPIC_API_KEY` (Settings → Secrets and
   variables → Actions). The non-AI tier needs no secret.
2. (Optional) Create a `security` label so AI audit issues get labeled.
3. The static-analysis tier runs automatically on the next PR/push.

## Notes from the recommendation

- State scope explicitly in prompts (full codebase vs PR changes) — done in the
  workflow prompts.
- State that skills must be used — the skills workflow prompt does this.
- AI is non-deterministic; consider running audits multiple times and
  cross-checking findings (e.g. a false-positive pass) before acting.
