# Contributing

This document covers the development workflow for f5-airgap-k8s.
For operating either side, see the respective `pull/README.md` or
`push/README.md`.

## Local Setup

```bash
git clone https://github.com/<your-org>/f5-airgap-k8s.git
cd f5-airgap-k8s
```

You don't need to install Ansible or Docker just to make doc changes —
the CI runs lint and syntax-check for you on every PR. If you want to
exercise the playbooks locally, both stages run inside the Execution
Environment (build it once with `bash ee/build-ee.sh`, then run via
`ansible-navigator` — see `ee/README.md`):

- **Pull side**: see `pull/README.md` — needs a container runtime, a host
  Docker daemon, and internet access
- **Push side**: see `push/README.md` — needs a container runtime, a host
  Docker daemon, and a local Docker Registry v2 for testing

## Repository Layout

Two stages share one repo and one Execution Environment. The stages
communicate only through the bundle manifest. See each project's
`ARCHITECTURE.md` and `ee/README.md`.

```
.
├── ee/        ← Execution Environment definition (ansible-builder)
├── pull/      ← internet-side artifact collection
├── push/      ← closed-network registry import
└── .github/   ← CI workflows
```

## Pull Request Workflow

1. Branch off `main`:
   ```bash
   git checkout -b descriptive-name
   ```

2. Make your changes. If you touch either project's task files, also
   update its `ARCHITECTURE.md` if you changed a design decision or a
   variable's meaning.

3. Push and open a PR. CI runs:
   - **yaml-lint** — generic YAML syntax across `ee/`, `pull/`, `push/`
   - **syntax-check** — `ansible-playbook --syntax-check` on every playbook,
     with collections installed from `ee/requirements.yml`
   - **ee-validate** — `ansible-builder create` validates the EE definition
   - **shellcheck** — static analysis of `ee/build-ee.sh` and `push/host-prep.sh`
   - **rhel-syntax-check** — playbook parse on Rocky 9 / UBI 9 filesystems
   - **release-dry-run** — verifies the release workflow would succeed

4. PRs require at least one approval before merge to `main`. Direct pushes
   to `main` are blocked.

## Documentation Standard

The codebase follows a documentation-heavy style. Every task file opens
with a header docblock covering eight sections:

```yaml
# =============================================================================
# <relative path to this file>
#
# PURPOSE          — one-paragraph what and why
# INPUTS (vars)    — every variable this task file reads
# OUTPUTS          — every set_fact this task file writes
# SIDE EFFECTS     — every file, process, or system state modified
# IDEMPOTENCY      — what happens on re-run
# FAILURE MODES    — what can go wrong, where, how to recover
# DESIGN NOTES     — design decisions worth knowing
# =============================================================================
```

Inline comments explain the *why*, not the *what*. Task names should be
self-explanatory; comments cover the non-obvious choices behind them.

## Cutting a Release

Releases are tagged on `main` and built automatically by GitHub Actions:

```bash
git checkout main
git pull
git tag v1.2.3
git push origin v1.2.3
```

This triggers `.github/workflows/release.yml`, which:

1. Builds `f5-airgap-pull-v1.2.3.zip` and `f5-airgap-push-v1.2.3.zip`
2. Computes a `SHA256SUMS` file
3. Creates a GitHub Release with the three files attached
4. Auto-generates release notes from PR titles since the previous tag

### Versioning

Semantic versioning:

- **Patch (`v1.2.3` → `v1.2.4`)** — bug fix, doc-only change, internal
  refactor that doesn't change behavior
- **Minor (`v1.2.x` → `v1.3.0`)** — backward-compatible feature: new
  image added, new toggle, new optional variable
- **Major (`v1.x.y` → `v2.0.0`)** — breaking change. The most common
  trigger is a change to the bundle manifest schema, which requires
  coordinated updates on both pull and push sides

## Security

Never commit a real `vault.yaml`. The `.gitignore` excludes them by
pattern, but verify with `git status` before every push. If a real
secret is ever committed:

1. **Treat it as compromised.** Removing it from history doesn't help
   if anyone cloned the repo in the meantime.
2. **Rotate the secret immediately.** Then update `vault.yaml` on every
   host that uses it.

Reporting security issues: see [SECURITY.md](SECURITY.md).

## License

By contributing, you agree your work is licensed under the Apache 2.0
license (see [LICENSE](LICENSE)).
