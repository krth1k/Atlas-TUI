# Atlas-TUI CI/CD

GitHub Actions pipeline for Atlas-TUI. DevSecOps-focused: SAST, supply-chain signing, GitOps deploy.

## Flow

```
push/PR ─┬─ lint ────────┐
         ├─ sast ────────┤─ build ─ image-scan ─[main]─ publish ─ gitops-bump
         └─ codeql ──────┘                              cosign+    (Helm yq
                                                        SBOM)       bump)
                                                                       │
                                                                       ▼
                                                            ArgoCD auto-sync
                                                            → k3s cluster
```

## Files

| File | Purpose |
|------|---------|
| `workflows/ci.yml` | Main pipeline. Jobs: `lint`, `sast`, `codeql`, `build`, `image-scan`, `publish`, `gitops-bump`. |
| `workflows/codeql.yml` | Weekly scheduled CodeQL scan only. PR/push CodeQL lives in `ci.yml` (gates `build`). |
| `dependabot.yml` | Weekly updates: `pip`, `docker`, `github-actions`. |
| `../.dockerignore` | Excludes `.venv`, `.git`, caches from build context. |
| `../.semgrepignore` | Excludes `.venv`, caches from Semgrep scans. |

## Jobs

### `lint`
Ruff check + format check via `uv run`. ~1min.

### `sast`
Parallel security tooling, all upload SARIF to GitHub Security tab:

| Tool | Scope | Gating |
|------|-------|--------|
| Bandit | Python AST security rules | Fail on MEDIUM+ severity (`-ll`) |
| Semgrep | Rule packs: `security-audit`, `python`, `dockerfile`, `owasp-top-ten` | Fail on any finding (`--error`) |
| Gitleaks | Secret scanning, full git history | Fail on detection |
| pip-audit | Dependency CVEs from `uv export` | Fail on any vuln (`--strict`) |

### `codeql`
GitHub-native deep semantic analysis. Python language, `security-and-quality` query suite. ~5-10min.

### `build`
`docker buildx`, multi-arch `linux/amd64,linux/arm64`. Output: OCI tarball at `/tmp/image.tar`. GHA cache `mode=max`. No registry push.

### `image-scan`
Trivy scans tarball twice:
1. SARIF output → Security tab (informational)
2. Table output, `exit-code: 1` on `CRITICAL,HIGH` → blocks publish

`ignore-unfixed: true` — only fail on CVEs with available fixes.

### `publish` (main branch only)
- Push tags: `<git-sha>`, `main`, `latest` to `ghcr.io/krth1k/atlas-tui`
- `provenance: mode=max` — SLSA build provenance
- `sbom: true` — SPDX SBOM in image manifest
- Cosign keyless sign via OIDC (no key material)
- Syft generates SPDX SBOM from registry digest
- Cosign attest SBOM as predicate

Permissions: `packages: write`, `id-token: write` (OIDC for cosign).

### `gitops-bump` (main branch only)
- Checkout `krth1k/krth1k-IaC` with `IAC_REPO_TOKEN`
- `yq` patches `helm/atlas-tui/values.yaml`:
  ```yaml
  image:
    tag: <git-sha>
    digest: sha256:<digest>
  ```
- Commit + push to IaC main
- ArgoCD auto-syncs within ~3min refresh interval

## Required Setup

### Secrets (repo settings)

| Secret | Required | Purpose |
|--------|----------|---------|
| `GITHUB_TOKEN` | auto | GHCR push (built-in to Actions) |
| `IAC_REPO_TOKEN` | **manual** | Push commits to `krth1k-IaC`. Use fine-grained PAT with `contents: write` scoped only to that repo. GitHub App token preferred. |

### GHCR package visibility

After first push, package is private by default. Options:
- Set public via `Package settings → Change visibility` (simplest for portfolio)
- Keep private, configure `imagePullSecret` in cluster

### Branch protection (recommended)

Settings → Branches → `main` rule → require status checks:
- `lint`
- `sast`
- `codeql`
- `image-scan`

This blocks merge until SAST + image scan pass.

### IaC repo prerequisites

Pipeline assumes `krth1k-IaC` contains:
- `helm/atlas-tui/values.yaml` with `image.tag` and `image.digest` keys
- `helm/atlas-tui/templates/deployment.yaml` referencing `{{ .Values.image.repository }}@{{ .Values.image.digest }}`
- ArgoCD `Application` CR pointing at chart with `syncPolicy.automated.prune=true, selfHeal=true`

Until Helm chart exists, `gitops-bump` fails at `yq` step with missing-file error. Fail-fast by design.

## Known Blocker

**Dockerfile line 73**: trailing typo `]a` after `ENTRYPOINT [...]` array breaks `docker buildx build`. Fix:
```dockerfile
ENTRYPOINT ["python", "-m", "src.main"]
```

Also `-m src.main` needs `src/__main__.py` to work as module form. Alternative:
```dockerfile
ENTRYPOINT ["python", "src/main.py"]
```

Pipeline cannot succeed until fixed.

## Local Verification

Before push, run equivalents locally:

```bash
# Lint
cd Atlas-TUI && uv run ruff check src/ && uv run ruff format --check src/

# SAST
uvx bandit -r src/ -ll
uvx semgrep@latest scan --config=p/security-audit --config=p/python --error
uvx pip-audit -r <(uv export --no-dev --no-hashes)

# Build
docker buildx build --platform linux/amd64,linux/arm64 -t atlas-tui:local .

# Image scan
trivy image atlas-tui:local --severity CRITICAL,HIGH --exit-code 1
```

## End-to-End Verification

Post-merge checklist:

1. Actions tab → all jobs green
2. Security tab → SARIF findings from Bandit/Semgrep/Trivy/CodeQL populated
3. Packages → `ghcr.io/krth1k/atlas-tui` lists new tags `<sha>`, `main`, `latest`
4. Verify cosign signature:
   ```bash
   cosign verify ghcr.io/krth1k/atlas-tui@<digest> \
     --certificate-identity-regexp 'https://github.com/krth1k/Atlas-TUI/.*' \
     --certificate-oidc-issuer https://token.actions.githubusercontent.com
   ```
5. Verify SBOM attestation:
   ```bash
   cosign download attestation ghcr.io/krth1k/atlas-tui@<digest> \
     --predicate-type https://spdx.dev/Document
   ```
6. `krth1k-IaC` repo → new commit `chore(atlas-tui): bump image to <sha>`
7. ArgoCD UI (`argocd.krth1k.dev`) → app `OutOfSync` → auto-sync → `Synced/Healthy`
8. Cluster:
   ```bash
   kubectl -n atlas-tui get pod -o jsonpath='{.items[0].spec.containers[0].image}'
   ```
   Returns image with new digest.

## Failure-Mode Tests

Validate gating works:

| Inject | Expected fail point |
|--------|---------------------|
| Hardcoded password in `src/` | `sast` → Gitleaks |
| `os.system(user_input)` | `sast` → Bandit + Semgrep |
| Pin base image with known CVE | `image-scan` → Trivy |
| Break Dockerfile syntax | `build` |
| Delete `helm/atlas-tui/values.yaml` in IaC | `gitops-bump` |

## Concurrency

`concurrency.group: ci-${{ github.ref }}` with `cancel-in-progress: false`. Prevents race conditions in `gitops-bump` when two commits land on `main` close together — second waits for first to finish push to IaC repo.

## Cost Notes

- CodeQL on every push/PR: ~5-10min runner time. Major portion of budget.
- Multi-arch buildx with QEMU emulation: ~3-5min cold, ~1min warm cache.
- Trivy DB download cached by action.
- GHA cache (`type=gha,mode=max`) shared between `build` and `publish` — second build is mostly metadata + push.

Estimate: ~15-20min total wall clock per push to main, ~10-12min per PR (no publish/bump).

## References

- Cosign keyless: https://docs.sigstore.dev/cosign/signing/overview/
- SLSA provenance: https://slsa.dev/spec/v1.0/provenance
- Trivy action: https://github.com/aquasecurity/trivy-action
- Buildx GHA cache: https://docs.docker.com/build/cache/backends/gha/


---

```
Atlas-TUI/
├── .github/
│   ├── dependabot.yml          weekly pip + docker + actions updates
│   └── workflows/
│       ├── ci.yml              push/PR pipeline (7 jobs)
│       └── codeql.yml          weekly scheduled CodeQL scan
├── .dockerignore               new (Dockerfile assumed it)
└── .semgrepignore              skip .venv, caches

ci.yml job DAG:
push/PR ─┬─ lint ────────┐
          ├─ sast ────────┤── build ── image-scan ──[main only]── publish ── gitops-bump
          └─ codeql ──────┘                                       (cosign+SBOM) (Helm yq)
```

**Pipeline highlights (DevSecOps signals for portfolio):**
- SARIF → Security tab from Bandit, Semgrep, Trivy, CodeQL — single pane visibility
- Multi-arch buildx (amd64+arm64) with GHA cache
- Cosign keyless OIDC sign — no key material in CI
- SPDX SBOM attached as cosign attestation — supply-chain provenance
- SLSA build provenance via provenance: mode=max
- Trivy scan before push — vulnerable images never reach GHCR
- Pure GitOps: pipeline commits to IaC repo, ArgoCD auto-syncs

**Required GitHub setup before first run:**
1. Repo secret IAC_REPO_TOKEN — fine-grained PAT with contents:write on krth1k/krth1k-IaC (or GitHub App token).
2. GHCR package visibility: set public after first push, else cluster needs imagePullSecret.
3. Branch protection on main recommended: require lint, sast, codeql, image-scan checks.

⚠️  **BLOCKER for first build to succeed:** Atlas-TUI/Dockerfile line 73 has trailing typo ]a after the ENTRYPOINT JSON array. Fix to ENTRYPOINT ["python", "-m", "src.main"] before pushing, or docker buildx build errors out. Also python -m src.main requires
src/__main__.py; safer is ["python", "src/main.py"]. Out of scope per plan but flagging — pipeline cannot succeed without it.

**Follow-up tasks (per your scoping):**
- Create helm/atlas-tui/ chart in krth1k-IaC with values.yaml containing image.repository, image.tag, image.digest keys + ArgoCD Application CR.
- helm/atlas-tui/templates/deployment.yaml should ref image as {{ .Values.image.repository }}@{{ .Values.image.digest }} for digest immutability (Kyverno-ready).