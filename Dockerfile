# Proxmox Backup Server runtime image.
# The arch-specific .debs are built by scripts/build.sh (CI) and placed in ./debs; everything
# else comes unmodified from Proxmox's signed pbs-no-subscription repository.
ARG DEBIAN_IMAGE=debian:trixie-20261020-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad
FROM ${DEBIAN_IMAGE}

ARG PBS_VERSION
LABEL org.opencontainers.image.title="Proxmox Backup Server (arm64 build)" \
      org.opencontainers.image.description="Unofficial build of Proxmox Backup Server from official source" \
      org.opencontainers.image.version="${PBS_VERSION}" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later" \
      org.opencontainers.image.source="https://github.com/dasunNimantha/pbs-arm64"

COPY scripts/proxmox-apt.sh /usr/local/sbin/
COPY docker/no-subscription-nag.sh /usr/local/sbin/
COPY debs/ /tmp/debs/

# policy-rc.d: package scripts must not try to start services (there is no systemd here)
RUN set -eux; \
    printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; chmod +x /usr/sbin/policy-rc.d; \
    /usr/local/sbin/proxmox-apt.sh pbs; \
    apt-get update -q; \
    DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends tini \
      /tmp/debs/proxmox-backup-server_*.deb \
      /tmp/debs/proxmox-backup-client_*.deb \
      /tmp/debs/proxmox-termproxy_*.deb \
      /tmp/debs/proxmox-mini-journalreader_*.deb; \
    test "$(dpkg-query -W -f='${Version}' proxmox-backup-server | cut -d- -f1)" = "${PBS_VERSION}"; \
    test "$(dpkg-query -W -f='${Architecture}' proxmox-backup-server)" = "$(dpkg --print-architecture)"; \
    /usr/local/sbin/no-subscription-nag.sh; \
    rm -rf /tmp/debs /var/lib/apt/lists/* /var/cache/apt/*

COPY docker/entrypoint.sh /usr/local/sbin/pbs-entrypoint

VOLUME ["/etc/proxmox-backup", "/var/lib/proxmox-backup", "/var/log/proxmox-backup"]
EXPOSE 8007
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/sbin/pbs-entrypoint"]
