# f5-airgap-k8s

Two-stage Ansible pipeline for deploying F5 BIG-IP Container Ingress Services
(CIS) and NGINX Plus Ingress Controller into an air-gapped Kubernetes
environment.

```
INTERNET SIDE                            CLOSED NETWORK
─────────────                            ──────────────
pull/  →  airgap-bundle.tar.gz  →  push/  →  (registry)  →  cluster
```

## Projects

This monorepo contains two self-contained Ansible projects:

| Directory | Purpose | Where it runs |
|-----------|---------|---------------|
| **[pull/](pull/)** | Pulls container images and Helm charts from public/private registries, bundles them with a SHA-256 manifest | Internet-connected workstation |
| **[push/](push/)** | Verifies the bundle and pushes everything into a closed-network Docker Registry v2 (HTTP or HTTPS, with or without auth) | Closed-network host |

The contract between the two sides is the bundle manifest (per-file SHA-256
checksums). Each project's `ARCHITECTURE.md` documents the contract.

## For Operators

Download the side you need from the latest release. Internet-side and
closed-network operators each download a single zip — neither has to clone
the repository.

1. Go to **[Releases](../../releases/latest)**.
2. Download **`f5-airgap-pull-vX.Y.Z.zip`** for the internet side or
   **`f5-airgap-push-vX.Y.Z.zip`** for the closed-network side.
3. Verify the SHA-256 against `SHA256SUMS` (attached to the release).
4. Extract, follow the project's own `README.md` for setup and operation.

## For Developers

Clone the monorepo:

```bash
git clone https://github.com/<your-org>/f5-airgap-k8s.git
cd f5-airgap-k8s
```

Each project has its own:

- `README.md` — operator-facing setup and quick-start
- `ARCHITECTURE.md` — engineering reference (design decisions, variable
  tables, idempotency contract, failure mode matrix, contributor guide)

### Releasing a new version

Cut a release by tagging on `main`:

```bash
git tag v1.2.0
git push origin v1.2.0
```

The release workflow (`.github/workflows/release.yml`) builds both project
zips, computes a `SHA256SUMS` file, and creates a GitHub Release with
auto-generated notes from PR titles since the last tag.

### Versioning

Semantic versioning:

- `v1.0.1` — bug fix, doc change
- `v1.1.0` — backward-compatible feature (new image, new toggle)
- `v2.0.0` — breaking change to the bundle manifest schema (any change
  here requires coordinated updates on both sides)

## Repository Layout

```
f5-airgap-k8s/
├── README.md                       ← this file
├── LICENSE
├── CONTRIBUTING.md
├── .gitignore
├── .github/
│   ├── CODEOWNERS
│   └── workflows/
│       ├── lint.yml                ← YAML + syntax checks on every push/PR
│       └── release.yml             ← Build zips on v* tag, create release
├── pull/                           ← internet-side project
│   ├── README.md
│   ├── ARCHITECTURE.md
│   ├── ansible.cfg
│   ├── setup.sh
│   ├── vault.yaml.example
│   ├── collections/requirements.yml
│   ├── inventory/hosts.yaml
│   ├── group_vars/all/main.yaml
│   └── open-pull/
│       ├── README.md
│       ├── playbooks/
│       └── tasks/
└── push/                           ← closed-network project
    ├── README.md
    ├── ARCHITECTURE.md
    ├── ansible.cfg
    ├── setup.sh
    ├── vault.yaml.example
    ├── collections/requirements.yml
    ├── inventory/hosts.yaml
    ├── group_vars/all/main.yaml
    └── ccn-push/
        ├── README.md
        ├── playbooks/
        └── tasks/
```

## License

[Apache 2.0](LICENSE).
