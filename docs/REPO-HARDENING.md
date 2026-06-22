# Repository Hardening Guide

A reproducible runbook for locking down this repository
(`jmack707/f5-cis-airgap-transfer`). Every step is the exact config that is
live today, so you can re-apply it after a fork, audit drift, or tighten the
posture later.

The layers, defense-in-depth:

1. **Branch protection** — nothing reaches `main` except via a green PR.
2. **Tag protection** — published release tags can't be moved or deleted.
3. **GitHub security features** — server-side secret blocking + dependency alerts.
4. **CI / supply-chain hardening** — pinned actions, least-privilege tokens.
5. **Optional** — secret scanning in CI, signed commits.

---

## Prerequisites

- The [`gh` CLI](https://cli.github.com/) authenticated as a repo **admin**
  (you, the owner):
  ```bash
  gh auth status     # must list your account with 'repo' + 'workflow' scopes
  # if not logged in:
  gh auth login      # GitHub.com -> HTTPS -> login with a browser
  ```
- `jq` for reading API responses (optional but handy).

Throughout, the repo is referred to as `jmack707/f5-cis-airgap-transfer`.
Change that slug if you apply this elsewhere.

> **Paste tip:** apply JSON-bodied API calls as a **single line** piped into
> `gh api ... --input -`. Multi-line heredocs frequently get mangled when
> pasted into a terminal.

---

## 1. Branch protection on `main`

**Goal (solo-friendly):** no direct pushes, every change via a PR whose CI is
green and up-to-date, linear history, no force-push or deletion — but **0
required approvals** (so you can merge your own PRs) and an admin bypass escape
hatch.

The required status check contexts are the CI job names from
`.github/workflows/lint.yml`. If you rename a job, update this list or the
check will be "expected" forever and block merges.

```bash
echo '{"required_status_checks":{"strict":true,"contexts":["yaml-lint","syntax-check","ee-validate","shellcheck","release-dry-run","rhel-syntax-check (rockylinux/rockylinux:9)","rhel-syntax-check (redhat/ubi9)"]},"enforce_admins":false,"required_pull_request_reviews":{"required_approving_review_count":0,"dismiss_stale_reviews":false,"require_code_owner_reviews":false},"restrictions":null,"required_linear_history":true,"allow_force_pushes":false,"allow_deletions":false,"required_conversation_resolution":true}' \
  | gh api --method PUT -H "Accept: application/vnd.github+json" \
    /repos/jmack707/f5-cis-airgap-transfer/branches/main/protection --input -
```

What each setting does:

| Setting | Value | Effect |
|---|---|---|
| `required_status_checks.strict` | `true` | PR branch must be up-to-date with `main` before merge |
| `required_status_checks.contexts` | 7 jobs | all CI checks must pass |
| `required_pull_request_reviews.required_approving_review_count` | `0` | PR required, but you can merge your own |
| `required_linear_history` | `true` | squash/rebase merges only (no merge commits) |
| `allow_force_pushes` / `allow_deletions` | `false` | `main` can't be force-pushed or deleted |
| `required_conversation_resolution` | `true` | all review threads resolved before merge |
| `enforce_admins` | `false` | admins keep a bypass for emergencies |

**Verify:**

```bash
gh api /repos/jmack707/f5-cis-airgap-transfer/branches/main/protection \
  | jq '{strict: .required_status_checks.strict, checks: .required_status_checks.contexts, admins: .enforce_admins.enabled, approvals: .required_pull_request_reviews.required_approving_review_count, linear: .required_linear_history.enabled, force: .allow_force_pushes.enabled, delete: .allow_deletions.enabled, convo: .required_conversation_resolution.enabled}'
```

**Tighten to strict / team** later by changing two fields and re-running the
PUT: set `required_approving_review_count` to `1`, `require_code_owner_reviews`
to `true` (needs a `.github/CODEOWNERS`, which this repo has), and
`enforce_admins` to `true`. Requires a second account to approve PRs.

---

## 2. Tag protection (`v*` release tags)

Prevents a published release tag from being force-moved or deleted by accident.
Implemented as a **ruleset** (the modern mechanism), with an admin bypass so
intentional re-cuts are still possible.

```bash
gh api --method POST /repos/jmack707/f5-cis-airgap-transfer/rulesets \
  -H "Accept: application/vnd.github+json" --input - <<'JSON'
{"name":"protect-release-tags","target":"tag","enforcement":"active",
 "conditions":{"ref_name":{"include":["refs/tags/v*"],"exclude":[]}},
 "rules":[{"type":"deletion"},{"type":"non_fast_forward"}],
 "bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}]}
JSON
```

`actor_id: 5` is the built-in **Admin** repository role. Verify with
`gh api /repos/jmack707/f5-cis-airgap-transfer/rulesets`.

---

## 3. GitHub security features

Enable in **Settings → Code security**, or via API:

```bash
gh api --method PATCH /repos/jmack707/f5-cis-airgap-transfer \
  -F security_and_analysis[secret_scanning][status]=enabled \
  -F security_and_analysis[secret_scanning_push_protection][status]=enabled
```

- **Secret scanning + push protection** — blocks commits that contain known
  token/key formats *at push time*. The single highest-value control for a
  secrets-adjacent tool: it catches what `.gitignore` can't (e.g. a token
  pasted into a playbook).
- **Dependabot alerts + security updates** — toggle on in the UI.
- **Private vulnerability reporting** — toggle on in the UI; pairs with the
  repo's `SECURITY.md`.

---

## 4. CI / supply-chain hardening

### Pin actions to a commit SHA

A tag like `@v4` is mutable — it can be force-moved to malicious code that then
runs with the workflow token (the release job holds `contents: write`). Pin to
the immutable commit SHA, keeping a version comment for humans.

Resolve the SHA for a version:

```bash
git ls-remote https://github.com/actions/checkout 'refs/tags/v4.2.2^{}'
# -> 11bd71901bbe5b1630ceea73d27597364c9af683
```

Then in the workflow:

```yaml
# before
- uses: actions/checkout@v4
# after
- uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
```

Currently pinned in this repo:

| Action | SHA | Version |
|---|---|---|
| `actions/checkout` | `11bd71901bbe5b1630ceea73d27597364c9af683` | v4.2.2 |
| `softprops/action-gh-release` | `3bb12739c298aeb8a4eeaf626c5b8d85266b0e65` | v2.6.2 |

Audit for any unpinned actions:

```bash
grep -rnE 'uses:.*@v[0-9]' .github/workflows/   # should return nothing
```

### Least-privilege workflow tokens

Default `GITHUB_TOKEN` scope is repo-configurable and often broader than
needed. Declare the minimum per workflow:

- `lint.yml` → `permissions: { contents: read }` (it only reads the tree).
- `release.yml` → `permissions: { contents: write }` (needs to create releases).

### Keep the pins fresh with Dependabot

`.github/dependabot.yml` opens grouped weekly PRs that bump the SHA **and** the
version comment, so pinning doesn't mean going stale:

```yaml
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
    commit-message:
      prefix: "ci"
    groups:
      github-actions:
        patterns: ["*"]
```

Those PRs flow through the branch protection from §1 like any other change.

---

## 5. Optional, heavier controls

- **Secret scanning in CI (gitleaks):** defense-in-depth on every PR. Needs a
  `.gitleaks.toml` allowlist so placeholder files (e.g. `vault.yaml.example`)
  don't false-positive. Add as its own change.
- **Require signed commits:** set `required_signatures` on the branch
  (`gh api --method POST .../branches/main/protection/required_signatures`).
  Adds GPG/SSH-signing friction — worth it for high-assurance, optional solo.

---

## Working under branch protection (day-to-day)

Since `main` rejects direct pushes, the loop is always:

```bash
git checkout -b my-change origin/main
# ...edit, commit...
git push -u origin my-change
gh pr create --fill                       # open the PR
# wait for the 7 checks to go green, then:
gh pr merge --squash --delete-branch      # squash keeps linear history
```

- **"Out of date" PR:** the strict rule needs the branch current. Use the
  "Update branch" button, or `git rebase origin/main && git push -f` on the
  feature branch.
- **Re-cutting a release tag:** the §2 ruleset allows admin bypass, so you can
  delete + re-push a `v*` tag when needed:
  ```bash
  git push origin :refs/tags/vX.Y.Z          # delete remote tag
  git tag -a vX.Y.Z origin/main -m "vX.Y.Z"  # tag the right commit (no checkout)
  git push origin vX.Y.Z
  ```
- **Auto-clean merged branches:** Settings → General → "Automatically delete
  head branches".

---

## Audit checklist

Run periodically to confirm nothing has drifted:

```bash
# branch protection present and strict
gh api /repos/jmack707/f5-cis-airgap-transfer/branches/main/protection \
  | jq '.required_status_checks.strict, .required_linear_history.enabled'

# tag ruleset present
gh api /repos/jmack707/f5-cis-airgap-transfer/rulesets | jq '.[].name'

# security features on
gh api /repos/jmack707/f5-cis-airgap-transfer \
  | jq '.security_and_analysis'

# no unpinned actions
grep -rnE 'uses:.*@v[0-9]' .github/workflows/ && echo "UNPINNED FOUND" || echo "all pinned"
```
