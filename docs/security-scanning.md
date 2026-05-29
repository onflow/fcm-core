# Security Scanning

Local security scanning for the Solidity codebase, set up per the
[Continuous Security Testing/Auditing](https://www.notion.so/3521aee1232480958886c3666758b9f0)
recommendation. Supplementary to formal audits, not a replacement.

## Why local-only (not CI)

**This repository is public and the contracts hold real value.** Every place a
GitHub Action could surface findings is public on a public repo:

- Issues, PR comments/reviews, and committed files — public.
- **Actions run logs and artifacts — public.** Scanners (Slither, Aderyn, and
  any AI tool) print findings to the job log, which anyone can read.
- Code scanning alerts are private to write-access users, but PR-context runs
  surface them as inline check annotations, which are public on the PR.

There is no way to make a single workflow's logs private on a public repo, so
running these scans in CI would risk leaking a live vulnerability and causing
users to lose funds. Instead, every scan runs **locally**, and all output goes
to `security/reports/` which is **gitignored** — never committed, never posted.

If we later want continuous/automated scanning, the correct place is a **private
repo** that mirrors the code, where logs and alerts stay private.

## Make targets

| Target | Tool | Notes |
|--------|------|-------|
| `make security` | Slither + Aderyn + Solhint | runs all static analyzers |
| `make security-slither` | Slither | report → `security/reports/slither-report.txt` |
| `make security-aderyn` | Aderyn | report → `security/reports/aderyn-report.md` |
| `make security-solhint` | Solhint | prints lint findings |
| `make security-ai-review` | Claude Code | reviews the current branch's changes |
| `make security-ai-audit` | Claude Code | full-codebase audit |
| `make security-ai-skills` | Claude Code + skills | `SKILL=<name>` to choose a skill |

## Prerequisites

Install everything in one shot (idempotent — skips what you already have):

```sh
make install-tools
```

This installs Foundry (`forge`, needed by Slither/Aderyn to compile), Slither,
Aderyn, Solhint, and the [Claude Code](https://docs.claude.com/claude-code) CLI
(`claude`). It relies on having `curl` plus Python (pipx/pip3) and Node/npm
available; anything it can't install is reported with a link. After installing,
you may need to add `~/.foundry/bin` and `~/.cyfrin/bin` to your `PATH`.

## How the AI scans work

- Prompts live in `security/prompts/` (`review-changes.md`, `full-audit.md`,
  `skills-audit.md`) and encode the vault/curator threat model.
- `security/run-ai.sh` runs Claude headlessly with a **read-only tool
  allowlist** (no `gh`, no git writes, no file writes) and pipes the report to a
  gitignored file. The prompts also explicitly forbid creating issues/comments
  or writing findings into tracked files.
- `security/run-skills.sh` vendors community audit skills into `.claude/skills/`
  (gitignored, managed by `security/vendor-skills.sh`) and runs the chosen one:
  `solidity-auditor` / `x-ray` (pashov), `audit-prep` (CDSecurity), `scv-scan`
  (kadenzipfel), or an `auditmos` skill.

## Reports

All reports are written under `security/reports/` (gitignored). **Do not commit
or share these files** — they may describe live, unfixed vulnerabilities. AI is
non-deterministic; consider running an audit more than once and cross-checking.

## Config files (safe to commit)

- `solidity/slither.config.json` — filters out `lib/`, `test/`, `script/`.
- `solidity/.solhint.json`, `solidity/.solhintignore` — Solhint rules/ignores.
