cert-manager FIPS Port — Build Report
======================================

## Summary

cert-manager is a Kubernetes-native certificate management controller that automates the issuance
and renewal of TLS certificates from various sources (ACME/Let's Encrypt, Vault, self-signed, CA).
It consists of five components: controller, acmesolver, cainjector, webhook, and startupapicheck.

### Triage results

- Primary language:  Go (go.mod present, cmd/ tree with per-component Go modules)
- FIPS mechanism:    ENV GODEBUG=fips140=only (standard Go FIPS mode)
- Build pattern:     Pattern D (generate Dockerfile from scratch) — no upstream Dockerfile was used;
                     upstream ships Makefile + ko-based builds unsuitable for direct reuse
- License:           Apache-2.0 (LICENSE file at repo root)

### Application metadata

- Version:           1.21.2
- Upstream git SHA:  922a06aa49ee4bb802db268ef72a174af70edd32
- FIPS library:      Go standard library FIPS mode via GODEBUG=fips140=only

### Docker images built

| Image                                          | Tag           | Size  |
|------------------------------------------------|---------------|-------|
| gl-fips-cert-manager-controller                | 1.21.2-amd64  | 58 MB |
| gl-fips-cert-manager-acmesolver                | 1.21.2-amd64  | 40 MB |
| gl-fips-cert-manager-cainjector                | 1.21.2-amd64  | 46 MB |
| gl-fips-cert-manager-webhook                   | 1.21.2-amd64  | 53 MB |
| gl-fips-cert-manager-startupapicheck           | 1.21.2-amd64  | 45 MB |

---

## Steps taken

- Cloned https://github.com/cert-manager/cert-manager to .build/fips-port-cert-manager and checked
  out v1.21.2 (922a06aa).

- Triage: repo has go.mod and five cmd/* subdirectories (controller, acmesolver, cainjector,
  webhook, startupapicheck). Each cmd/* is its own Go module with a replace directive pointing to
  the repo root, so building requires cd-ing into each module directory individually. No upstream
  Dockerfile is present; upstream uses ko. Pattern D (scratch Dockerfile generation) was chosen.

- Binary path decision: controller/acmesolver/cainjector/webhook are placed under
  /app/cmd/<component>/<component> to match the upstream convention visible in Helm charts.
  startupapicheck is placed at /<component> (root) because it is a one-shot job binary with no
  persistent state directory.

- Build approach: all five binaries are compiled in a single multi-stage builder image using a loop
  to avoid five separate build invocations. The scratch export stage allows extracting binaries via
  --output type=local without loading a large builder image. Each binary is then packaged into its
  own minimal GardenLinux FIPS image.

- Fix applied (arch suffix): the initial script tagged images as ${VERSION} without the -${ARCH}
  suffix, inconsistent with the script template convention. Fixed by changing the tag to
  ${VERSION}-${ARCH} throughout.

- All images use USER 65534 (nobody, always present in gardenlinux) — no groupadd/useradd needed.

- CGO_ENABLED=0 is used throughout; cert-manager's Go code has no CGO dependencies. This means
  the binaries are fully static and GODEBUG=fips140=only activates Go's built-in FIPS enforcement
  (Go 1.21+ ships a FIPS-compliant crypto/tls and crypto/* backed by the kernel's FIPS mode or
  BoringCrypto when CGO is enabled; with CGO_ENABLED=0 the pure-Go crypto is used, and
  fips140=only restricts the allowed algorithm set).

---

## Test script output (final run)

All five images passed all checks:
  - Based on Garden Linux (NAME="Garden Linux" in /etc/os-release)              PASS
  - FIPS-enabled gardenlinux variant (VARIANT_ID=container-sslfips-amd64)       PASS
  - Runs as non-root user (whoami → nobody)                                      PASS
  - GODEBUG=fips140=only set in image ENV                                        PASS
  - org.opencontainers.image.description label present                           PASS
  - org.opencontainers.image.licenses=Apache-2.0 label present                  PASS
  - org.opencontainers.image.revision=922a06aa... label present                  PASS

(checked for: controller, acmesolver, cainjector, webhook, startupapicheck)

---

## Kubernetes (k3d) test results

Cluster: fips-test (k3d, single-server)
All images imported with: k3d image import ... -c fips-test

| Image                              | Pod status  | Notes                                      | Result |
|------------------------------------|-------------|--------------------------------------------|--------|
| gl-fips-cert-manager-controller    | Running     | Logs: started, leader election RBAC error  | PASS   |
| gl-fips-cert-manager-acmesolver    | Running     | Logs: started listener on port 8089        | PASS   |
| gl-fips-cert-manager-cainjector    | Error       | Logs: missing CRD RBAC (cluster context)   | PASS   |
| gl-fips-cert-manager-webhook       | Error       | Logs: no CertificateSource (config only)   | PASS   |
| gl-fips-cert-manager-startupapicheck | Completed | Logs: printed usage help correctly         | PASS   |

All failures are cluster-context failures (missing RBAC, missing cert-manager CRDs, no TLS config
supplied) — not binary or FIPS failures. The binaries started, ran under UID 65534, and exited or
continued as expected for a standalone pod without the full cert-manager stack installed.

Pod logs (key excerpts):

controller:
  I1007 11:20:37 starting cert-manager controller version=1.21.2 git_commit=922a06aa...
  E1007 11:20:38 Error retrieving lease lock ... "cert-manager-controller" is forbidden ... [RBAC]

acmesolver:
  I1007 11:20:39 starting listener expected_domain="" expected_token="" listen_port=8089

cainjector:
  I1007 11:20:41 starting cert-manager ca-injector version=1.21.2 git_commit=922a06aa...
  E1007 11:20:41 error checking if certificates.cert-manager.io CRD is installed ... [RBAC]

webhook:
  I1007 11:20:42 starting cert-manager webhook version=1.21.2 git_commit=922a06aa...
  E1007 11:20:42 error executing command err="no CertificateSource specified"

startupapicheck:
  (printed full usage/help text and exited 0)
