#!/usr/bin/env bash
# Add a Proxmox apt repository on an arm64 Debian trixie system, for Architecture: all
# packages only.
#
#   scripts/proxmox-apt.sh devel   # build deps (proxmox-widget-toolkit-dev)
#   scripts/proxmox-apt.sh pbs     # runtime deps (widget toolkit, extjs, i18n, docs, ...)
#
# Proxmox only publishes amd64 indexes, so amd64 is added as a foreign architecture to read
# them, and apt is pinned so nothing amd64 is ever installed from these repos.
set -euo pipefail

KEY_URL=https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg
KEY_FPR=24B30F06ECC1836A4E5EFECBA7BCD1420BFE778E # Proxmox Trixie Release Key
KEYRING=/usr/share/keyrings/proxmox-archive-keyring.gpg

case "${1:?usage: proxmox-apt.sh devel|pbs}" in
  devel) URI=http://download.proxmox.com/debian/devel; SUITE=trixie; COMP=main ;;
  pbs)   URI=http://download.proxmox.com/debian/pbs;   SUITE=trixie; COMP=pbs-no-subscription ;;
  *) echo "unknown repo: $1" >&2; exit 1 ;;
esac

if [[ ! -s $KEYRING ]]; then
  command -v curl >/dev/null && command -v gpg >/dev/null ||
    { apt-get update -q && apt-get install -yq --no-install-recommends curl ca-certificates gpg; }
  curl -fsSL "$KEY_URL" -o "$KEYRING.tmp"
  gpg --show-keys --with-colons "$KEYRING.tmp" | grep -q "^fpr:::::::::$KEY_FPR:" ||
    { echo "Proxmox keyring does not contain $KEY_FPR" >&2; rm -f "$KEYRING.tmp"; exit 1; }
  mv "$KEYRING.tmp" "$KEYRING"
fi

dpkg --add-architecture amd64
cat > "/etc/apt/sources.list.d/proxmox-$1.sources" <<EOF
Types: deb
URIs: $URI
Suites: $SUITE
Components: $COMP
Architectures: amd64
Signed-By: $KEYRING
EOF

# never install foreign-architecture packages; arch:all packages are unaffected
cat > /etc/apt/preferences.d/no-amd64 <<'EOF'
Package: *:amd64
Pin: release *
Pin-Priority: -1
EOF
