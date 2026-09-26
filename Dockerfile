ARG BASE_IMAGE=debian:13-slim

# Stage 1: download the cloudflare-warp .deb for the target architecture.
# BuildKit runs this stage under TARGETPLATFORM, so apt resolves the right arch.
FROM ${BASE_IMAGE} AS fetch-warp

RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates gnupg && \
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg && \
    . /etc/os-release && \
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${VERSION_CODENAME} main" > /etc/apt/sources.list.d/cloudflare-client.list && \
    apt-get update && \
    mkdir -p /tmp/warp && cd /tmp/warp && \
    apt-get download cloudflare-warp && \
    mv cloudflare-warp_*.deb cloudflare-warp.deb

# Stage 2: download the gost binary for the target architecture.
FROM ${BASE_IMAGE} AS fetch-gost

ARG GOST_VERSION=latest
ARG TARGETPLATFORM=linux/amd64

RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates jq && \
    # resolve GOST_VERSION when it is empty or set to "latest"
    if [ -z "${GOST_VERSION}" ] || [ "${GOST_VERSION}" = "latest" ]; then \
      GOST_VERSION="$(curl -fsSL https://api.github.com/repos/ginuerzh/gost/releases/latest | jq -r '.tag_name // empty' | sed 's/^v//')"; \
      GOST_VERSION="${GOST_VERSION:-2.12.0}"; \
    fi && \
    case "${TARGETPLATFORM}" in \
      "linux/amd64") GOARCH="amd64"; LEGACYARCH="amd64" ;; \
      "linux/arm64") GOARCH="arm64"; LEGACYARCH="armv8" ;; \
      *) echo "Unsupported TARGETPLATFORM: ${TARGETPLATFORM}" && exit 1 ;; \
    esac && \
    MAJOR_VERSION=$(echo "${GOST_VERSION}" | cut -d. -f1) && \
    MINOR_VERSION=$(echo "${GOST_VERSION}" | cut -d. -f2) && \
    # detect if version >= 2.12.0, which uses new filename syntax
    if [ "${MAJOR_VERSION}" -ge 3 ] || [ "${MAJOR_VERSION}" -eq 2 -a "${MINOR_VERSION}" -ge 12 ]; then \
      FILE_NAME="gost_${GOST_VERSION}_linux_${GOARCH}.tar.gz"; \
      curl -fL "https://github.com/ginuerzh/gost/releases/download/v${GOST_VERSION}/${FILE_NAME}" -o /tmp/gost.tar.gz && \
      tar -xzf /tmp/gost.tar.gz -C /tmp gost; \
    else \
      FILE_NAME="gost-linux-${LEGACYARCH}-${GOST_VERSION}.gz"; \
      curl -fL "https://github.com/ginuerzh/gost/releases/download/v${GOST_VERSION}/${FILE_NAME}" -o /tmp/gost.gz && \
      gunzip -c /tmp/gost.gz > /tmp/gost; \
    fi && \
    chmod 755 /tmp/gost && \
    echo "Fetched gost ${GOST_VERSION} (${FILE_NAME})"

# Stage 3: final runtime image.
FROM ${BASE_IMAGE}

# Defaults so the image can be built without passing any --build-arg.
# CI overrides these with exact, pinned versions.
ARG WARP_VERSION=latest
ARG GOST_VERSION=latest
ARG COMMIT_SHA=unknown

LABEL org.opencontainers.image.authors="ndejong"
LABEL org.opencontainers.image.url="https://github.com/threatpatrols/docker-cfwarp"
LABEL WARP_VERSION=${WARP_VERSION}
LABEL GOST_VERSION=${GOST_VERSION}
LABEL COMMIT_SHA=${COMMIT_SHA}

COPY --from=fetch-warp /tmp/warp/cloudflare-warp.deb /tmp/cloudflare-warp.deb
COPY --from=fetch-gost /tmp/gost /usr/local/bin/gost

# Install only the shared libraries the headless warp daemon/cli actually link
# against, then install the cloudflare-warp .deb with --force-depends to skip the
# desktop-only dependency chain (libwebkit2gtk/GTK/Flutter, ~700MB) that the
# package declares but the daemon never uses.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      dbus \
      iproute2 \
      jq \
      libcap2 \
      libdbus-1-3 \
      libgcc-s1 \
      libnss3 \
      libssl3t64 \
      libsystemd0 \
      libtss2-esys-3.0.2-0t64 \
      libtss2-tctildr0t64 \
      libzstd1 \
      nftables \
      sudo \
      zlib1g && \
    dpkg -i --force-depends /tmp/cloudflare-warp.deb; \
    test -x /usr/bin/warp-svc && \
    test -x /usr/bin/warp-cli && \
    rm -rf /usr/lib/warp \
           /usr/bin/warp-dex \
           /usr/bin/warp-diag \
           /usr/bin/warp-desktop \
           /usr/bin/warp-taskbar \
           /usr/share/applications/com.cloudflare.warp.desktop \
           /usr/share/applications/com.cloudflare.WarpTaskbar.desktop \
           /usr/share/dbus-1/services/com.cloudflare.WarpTaskbar.service \
           /usr/share/icons/hicolor/scalable/apps/zero-trust-orange.svg \
           /usr/share/doc/cloudflare-warp \
           /usr/lib/systemd/system/warp-svc.service \
           /usr/lib/systemd/system/multi-user.target.wants/warp-svc.service && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/cloudflare-warp.deb && \
    useradd -m -s /bin/bash warp && \
    echo "warp ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/warp

COPY entrypoint.sh /entrypoint.sh
COPY ./healthcheck /healthcheck
RUN cp /healthcheck/ipcalc /usr/local/bin/ipcalc && \
    chmod 755 /entrypoint.sh /healthcheck/index.sh /usr/local/bin/ipcalc

USER warp

# Accept Cloudflare WARP TOS
RUN mkdir -p /home/warp/.local/share/warp && \
    echo -n 'yes' > /home/warp/.local/share/warp/accepted-tos.txt

ENV GOST_ARGS="-L :1080"
ENV WARP_SLEEP=2
ENV REGISTER_WHEN_MDM_EXISTS=
ENV BETA_FIX_HOST_CONNECTIVITY=
ENV WARP_ENABLE_NAT=

HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
  CMD /healthcheck/index.sh

ENTRYPOINT ["/entrypoint.sh"]
