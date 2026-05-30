# Security Scanning

Local, containerized security scanning for the Solidity codebase, set up per the
[Continuous Security Testing/Auditing](https://www.notion.so/3521aee1232480958886c3666758b9f0)
recommendation. Supplementary to formal audits, not a replacement.

## Threat model: why local + containerized + pinned

This repository is **public** and the contracts **hold real value**, which drives
two distinct controls:

1. **No public CI.** Every place a GitHub Action surfaces output is public on a
   public repo — issues, PR comments, **Actions logs, and artifacts**. Scanners
   print findings to the log, so running them in CI would leak live, unfixed
   vulnerabilities. All scanning runs locally; reports go to `security/reports/`
   (gitignored) and are never committed or posted.

2. **The AI skills are an untrusted supply chain.** The community skill repos are
   third-party and community-writable, and their content is loaded as
   *instructions* into a tool-enabled agent. Two mitigations:
   - **Pinning (integrity):** `security/vendor-skills.sh` checks out exact,
     reviewed commit SHAs and fails closed if a commit is gone — so a poisoned
     upstream commit can't silently run. Bump a SHA only after reviewing the diff.
   - **Containment:** every scanner runs inside a locked-down Docker container so
     a malicious skill can't read host files/secrets or exfiltrate:
     - **Static tier** (Slither/Aderyn/Solhint): `--network none`, `--cap-drop ALL`,
       source mounted **read-only**. Fully airtight.
     - **AI tier** (review/audit/skills/summarize): egress restricted to the
       **Anthropic API only** (`security/docker/init-firewall.sh`),
       the Claude credential is the only secret present, source mounted read-only.

Pinning + container = integrity + containment. Note what containment does **not**
fix: a poisoned skill can still produce dishonest *output* (e.g. hide a finding),
so AI results stay advisory and should be cross-checked against the static tools.

## Prerequisites

- **Docker.** Build the pinned toolchain image once:
  ```sh
  make security-build
  ```
  The image (`security/docker/Dockerfile`) bundles Foundry, Slither, Aderyn,
  Solhint, and the Claude CLI at pinned versions, with `solc` pre-cached so the
  static tier compiles with no network.
- **AI tier only:** a credential, resolved at run time — no permanent env var
  needed. See [Credentials](#credentials) below. The static tier needs nothing.

## Credentials

The AI tier authenticates with a **Claude Code OAuth token** (tied to your own
Claude subscription — no separate API billing). The token is **per-developer**,
so each person stores their own; there is no shared key. It is fetched at run
time and injected into the sealed container by reference (`-e NAME`, never on the
command line), and is never written to disk in the repo or kept in your shell.

One-time setup, per developer (default: macOS Keychain, zero extra tooling):

```sh
claude setup-token       # mint a long-lived token tied to your account
make security-set-token  # paste it once; stored encrypted in your login Keychain
```

After that, `make security-ai-*` fetches it automatically.

Credential resolution (precedence, highest first):

1. `CLAUDE_CODE_OAUTH_TOKEN` in the environment → used directly (CI / power users).
2. `ANTHROPIC_API_KEY` in the environment → used directly.
3. **1Password**, *only if* `FCM_OP_TOKEN_REF='op://<your-vault>/<item>/credential'`
   is set (use your own/Private vault — the token is personal, not shared).
4. **macOS Keychain** (the default) — what `make security-set-token` writes.

## Make targets

| Target | Tier | Notes |
|--------|------|-------|
| `make security` | all | everything: build + all static + all AI |
| `make security-build` | — | build the scanner image (run once / after updates) |
| `make security-set-token` | — | store your Claude OAuth token in the Keychain (one-time) |
| `make security-static` | static | all static analyzers: Slither + Aderyn + Solhint |
| `make security-slither` | static | report → `security/reports/slither-report-<ts>.txt` |
| `make security-aderyn` | static | report → `security/reports/aderyn-report-<ts>.md` |
| `make security-solhint` | static | report → `security/reports/solhint-report-<ts>.txt` |
| `make security-ai` | AI | all AI tiers: review + audit + skills + summarize |
| `make security-ai-review` | AI | reviews current branch changes |
| `make security-ai-audit` | AI | full-codebase audit |
| `make security-ai-skills` | AI | `SKILL=<name>`; vendors pinned skills, then audits |
| `make security-ai-summarize` | AI | rolls up all reports by severity to stdout |

## How it fits together

- **Prompts** live in `security/prompts/` and encode the vault/curator threat
  model. They forbid creating issues/comments or writing findings to tracked files.
- **`security/scan.sh`** is the single dispatcher: it builds the image on demand
  and runs each tool with the right isolation flags (static = no network, AI =
  API-only egress + key).
- **`security/docker/`** holds the `Dockerfile`, the two entrypoints
  (`entry-static.sh`, `entry-ai.sh`), and the egress allowlist
  (`init-firewall.sh`).
- **`security/vendor-skills.sh`** clones the pinned skill SHAs on the host, into a
  gitignored `.claude/skills/`, which is mounted read-only into the sealed
  container (so the container needs no GitHub egress).

## Reports

All reports are written under `security/reports/` (gitignored). **Do not commit or
share these files** — they may describe live, unfixed vulnerabilities. AI is
non-deterministic; run audits more than once and cross-check.

## Updating a skill

Review the upstream diff, then update the corresponding `*_SHA` in
`security/vendor-skills.sh`. Never point at a floating branch.

## Config files (safe to commit)

- `solidity/slither.config.json` — filters out `lib/`, `test/`, `script/`.
- `solidity/.solhint.json`, `solidity/.solhintignore` — Solhint rules/ignores.
