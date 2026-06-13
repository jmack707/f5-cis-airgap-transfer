# Security Policy

## Reporting a Vulnerability

If you discover a security issue in this project, do NOT open a public
GitHub issue. Instead:

1. Email the maintainers directly (see `.github/CODEOWNERS` for the list)
2. Include:
   - A clear description of the vulnerability
   - Steps to reproduce
   - The impact you believe it has
   - Any suggested mitigations

You'll get an acknowledgement within a few business days. We'll work
with you on a coordinated disclosure timeline if appropriate.

## Threat Model

This project moves container images and Helm charts across an air gap.
Three classes of threats are in scope:

1. **In-transit corruption** — the bundle is corrupted (intentionally
   or accidentally) between the pull stage and the push stage
2. **Manifest tampering** — the bundle's `manifest.json` is modified
   to claim different SHA-256 values than the files actually have
3. **Credential leakage** — robot tokens or JWTs are exposed through
   process listings, logs, or committed files

The current mitigations:

| Threat | Mitigation |
|--------|------------|
| Transit corruption | Outer SHA-256 (`airgap-bundle.tar.gz.sha256`) verified at the start of the push stage |
| Per-file corruption | Per-file SHA-256 in `manifest.json` verified before any docker load |
| Manifest tampering | None currently — the manifest is signed by no key. Future work: cosign signature on the bundle. |
| Credential in process listing | `--password-stdin` on `docker login`, `helm registry login` |
| Credential in logs | `no_log: true` on every task that touches a credential |
| Credential committed | `.gitignore` excludes `vault.yaml`; CI secret scanning catches accidents |

If you can demonstrate a way around any of these, please report it
privately.

## Out of Scope

The following are explicitly NOT in scope for this project:

- Securing the registry itself (that's the registry's responsibility)
- Authentication and authorization within Kubernetes (handled by the
  cluster, not by this pipeline)
- Network-level controls on the air gap (handled by the physical
  transfer process)
- Supply chain trust for upstream images (we trust what Docker Hub,
  Quay.io, and F5 NGINX serve us)
