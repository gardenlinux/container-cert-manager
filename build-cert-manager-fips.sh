#!/usr/bin/env bash
set -euo pipefail

# --- configuration -----------------------------------------------------------

REPO_URL="${REPO_URL:-https://github.com/cert-manager/cert-manager}"
BASE_IMAGE="${BASE_IMAGE:-ghcr.io/gardenlinux/gardenlinux/fips:1877.22}"
WORKDIR="${WORKDIR:-./.build/cert-manager-fips-build}"
IMAGE_PREFIX="${IMAGE_PREFIX:-gl-fips-cert-manager}"
ARCH="${ARCH:-$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')}"
VERSION="${VERSION:-1.21.2}"
UPSTREAM_GIT_SHA="${UPSTREAM_GIT_SHA:-922a06aa49ee4bb802db268ef72a174af70edd32}"
GO_IMAGE="${GO_IMAGE:-golang:1.26-bookworm}"

# --- prerequisites -----------------------------------------------------------

check_tool() { command -v "$1" &>/dev/null || { echo "error: $1 not found" >&2; exit 1; }; }
check_tool git
check_tool docker
check_tool curl
check_tool jq
docker buildx version &>/dev/null || { echo "error: docker buildx not available" >&2; exit 1; }

# --- buildx driver -----------------------------------------------------------

if ! docker buildx inspect fips-builder &>/dev/null; then
    docker buildx create --name fips-builder --driver docker-container
fi
docker buildx use fips-builder

# --- prepare workspace -------------------------------------------------------

mkdir -p "${WORKDIR}"
SRC_DIR=".build/fips-port-cert-manager"

if [ ! -d "${SRC_DIR}" ]; then
    git clone "${REPO_URL}" "${SRC_DIR}"
fi

cd "${SRC_DIR}"
git checkout "v${VERSION}"
cd - >/dev/null

# --- compile all 5 binaries in a single builder container -------------------

cat > "${WORKDIR}/Dockerfile.builder" <<'BUILDER_EOF'
ARG GO_IMAGE
FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS builder
ARG TARGETARCH
ARG VERSION
ARG UPSTREAM_GIT_SHA
WORKDIR /src
COPY . .
# Each cmd/* is its own Go module with a replace directive pointing to ../../
# so we must cd into each module directory before building.
RUN mkdir -p /out && \
    for COMPONENT in controller acmesolver cainjector webhook startupapicheck; do \
        cd /src/cmd/${COMPONENT} && \
        CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build \
            -trimpath \
            -ldflags "-w -s \
                -X github.com/cert-manager/cert-manager/pkg/util.AppVersion=${VERSION} \
                -X github.com/cert-manager/cert-manager/pkg/util.AppGitCommit=${UPSTREAM_GIT_SHA}" \
            -o /out/${COMPONENT} \
            . ; \
    done

FROM scratch AS export
COPY --from=builder /out /
BUILDER_EOF

# Extract compiled binaries via the scratch export stage
docker buildx build \
    --platform "linux/${ARCH}" \
    --build-arg GO_IMAGE="${GO_IMAGE}" \
    --build-arg TARGETARCH="${ARCH}" \
    --build-arg VERSION="${VERSION}" \
    --build-arg UPSTREAM_GIT_SHA="${UPSTREAM_GIT_SHA}" \
    --output "type=local,dest=${WORKDIR}/bin" \
    --target export \
    -f "${WORKDIR}/Dockerfile.builder" \
    "${SRC_DIR}"

# --- patch Containerfiles and build final images ----------------------------

for COMPONENT in controller acmesolver cainjector webhook startupapicheck; do
    CF_PATCHED="${WORKDIR}/Containerfile.${COMPONENT}.fips"

    BINARY_PATH="/app/cmd/${COMPONENT}/${COMPONENT}"
    if [ "${COMPONENT}" = "startupapicheck" ]; then
        BINARY_PATH="/${COMPONENT}"
    fi

    cat > "${CF_PATCHED}" <<EOF
ARG BASE_IMAGE
FROM \${BASE_IMAGE}
LABEL org.opencontainers.image.description="A FIPS-enabled cert-manager ${COMPONENT} image"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.revision="${UPSTREAM_GIT_SHA}"
COPY ${COMPONENT} ${BINARY_PATH}
ENV GODEBUG=fips140=only
USER 65534
ENTRYPOINT ["${BINARY_PATH}"]
EOF

    # Build context: a small directory with just the binary
    BUILD_CTX="${WORKDIR}/ctx-${COMPONENT}"
    mkdir -p "${BUILD_CTX}"
    cp "${WORKDIR}/bin/${COMPONENT}" "${BUILD_CTX}/${COMPONENT}"

    docker buildx build \
        --platform "linux/${ARCH}" \
        --build-arg BASE_IMAGE="${BASE_IMAGE}" \
        --load \
        --tag "${IMAGE_PREFIX}-${COMPONENT}:${VERSION}-${ARCH}" \
        -f "${CF_PATCHED}" \
        "${BUILD_CTX}"

    echo "Built: ${IMAGE_PREFIX}-${COMPONENT}:${VERSION}-${ARCH}"
done

echo ""
echo "All images built successfully:"
for COMPONENT in controller acmesolver cainjector webhook startupapicheck; do
    echo "  ${IMAGE_PREFIX}-${COMPONENT}:${VERSION}-${ARCH}"
done

# --- SBOM --------------------------------------------------------------------
# Syft version is pinned; update SYFT_VERSION to pick up a newer release.
SYFT_VERSION="${SYFT_VERSION:-1.56.0}"
SYFT_BIN="${WORKDIR}/syft"

install_syft() {
    local arch_syft
    arch_syft=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    local tarball="syft_${SYFT_VERSION}_linux_${arch_syft}.tar.gz"
    local checksum_file="syft_${SYFT_VERSION}_checksums.txt"
    local base_url="https://github.com/anchore/syft/releases/download/v${SYFT_VERSION}"

    curl -sSfL "${base_url}/${tarball}"       -o "/tmp/${tarball}"
    curl -sSfL "${base_url}/${checksum_file}" -o "/tmp/${checksum_file}"
    grep "${tarball}" "/tmp/${checksum_file}" | (cd /tmp && sha256sum -c)
    tar -xzf "/tmp/${tarball}" -C "${WORKDIR}" syft
    chmod +x "${SYFT_BIN}"
}

{ [ -x "${SYFT_BIN}" ] && "${SYFT_BIN}" version 2>/dev/null | grep -q "${SYFT_VERSION}"; } || install_syft

# Generate one SBOM per component image (phase 2: image scan only — Go binaries
# embed full module metadata in the binary via runtime/debug.ReadBuildInfo).
IMAGE_PREFIX_BASE=$(basename "${IMAGE_PREFIX}")
for COMPONENT in controller acmesolver cainjector webhook startupapicheck; do
    IMAGE_TAG="${IMAGE_PREFIX}-${COMPONENT}:${VERSION}-${ARCH}"
    SBOM_IMAGE="${WORKDIR}/${IMAGE_PREFIX_BASE}-${COMPONENT}-${VERSION}-${ARCH}-image.cdx.json"
    SBOM_OUT="${WORKDIR}/${IMAGE_PREFIX_BASE}-${COMPONENT}-${VERSION}-${ARCH}.cdx.json"

    "${SYFT_BIN}" "${IMAGE_TAG}" \
        --output "cyclonedx-json=${SBOM_IMAGE}"

    jq \
        --arg name "cert-manager-${COMPONENT}" \
        --arg version "${VERSION}" \
        --arg purl "pkg:oci/gl-fips-cert-manager-${COMPONENT}@${VERSION}?arch=${ARCH}" \
        --arg revision "${UPSTREAM_GIT_SHA}" \
        --arg arch "${ARCH}" \
        '.metadata.lifecycles = [{"phase": "post-build"}] |
         .metadata.component = {
           "type": "application",
           "name": $name,
           "version": $version,
           "purl": $purl,
           "properties": [
             {"name": "org.opencontainers.image.revision", "value": $revision},
             {"name": "arch", "value": $arch}
           ]
         }' \
        "${SBOM_IMAGE}" > "${SBOM_OUT}"

    echo "SBOM: ${SBOM_OUT}"
done
