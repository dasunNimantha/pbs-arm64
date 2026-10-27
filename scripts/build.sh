#!/usr/bin/env bash
# Build the architecture-specific PBS packages inside a Debian trixie container (as root):
#   proxmox-backup-server, proxmox-backup-client(-static), proxmox-backup-file-restore,
#   proxmox-termproxy, proxmox-mini-journalreader
#
#   scripts/build.sh <workdir> <outdir>
#
# Everything else PBS needs is Architecture: all and is taken from Proxmox's signed repo
# at image build time (see Dockerfile).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=/dev/null
source "$ROOT/versions.env"
WORK=$(realpath -m "${1:?usage: build.sh <workdir> <outdir>}")
OUT=$(realpath -m "${2:?usage: build.sh <workdir> <outdir>}")
export DEBIAN_FRONTEND=noninteractive
export DEB_BUILD_OPTIONS="nocheck nodoc parallel=$(nproc)"
export BIOME=true # the JS linter only runs as a build gate; it's x86-only
export BUILD_MODE=release

apt_setup() {
  "$ROOT/scripts/proxmox-apt.sh" devel
  apt-get update -q
  apt-get install -yq --no-install-recommends \
    build-essential devscripts equivs git ca-certificates curl jq \
    cargo rustc libstd-rust-dev
  rustc --version
  cargo --version
}

build_deps() { # dir [profiles]
  (cd "$1" && mk-build-deps -i -r ${2:+--build-profiles "$2"} \
    -t "apt-get -yq --no-install-recommends -o Debug::pkgProblemResolver=yes" debian/control)
}

# copy the committed lockfile into the package build dir and pre-fetch all crates, so the
# actual build runs offline against exactly what's locked
lock_and_fetch() { # builddir lockname
  cp "$ROOT/locks/$PBS_VERSION/$2.Cargo.lock" "$1/Cargo.lock"
  (cd "$1" && CARGO_HOME="$PWD/debian/cargo_home" cargo fetch --locked)
}

dpkg_build() { # builddir [dpkg-buildpackage args...]
  local d=$1
  shift
  (cd "$d" && CARGO_NET_OFFLINE=true dpkg-buildpackage -b -us -uc "$@")
}

apt_setup
"$ROOT/scripts/prepare.sh" "$WORK"
cd "$WORK"

# --- proxmox-backup (server, client, static client, file-restore)
make -C proxmox-backup build
# the Makefile copies workspace members found via `cargo metadata | jq`; make sure none were missed
for m in pbs-buildcfg pbs-client pbs-config pbs-datastore pbs-tools; do
  [[ -f proxmox-backup/build/$m/Cargo.toml ]] || { echo "build: workspace member $m missing from build dir" >&2; exit 1; }
done
build_deps proxmox-backup/build nodoc
lock_and_fetch proxmox-backup/build proxmox-backup
dpkg_build proxmox-backup/build --no-pre-clean --build-profiles=nodoc

# --- proxmox-termproxy
TP=proxmox-termproxy-$TERMPROXY_VERSION
make -C pve-xtermjs/termproxy "$TP"
build_deps "pve-xtermjs/termproxy/$TP"
lock_and_fetch "pve-xtermjs/termproxy/$TP" termproxy
dpkg_build "pve-xtermjs/termproxy/$TP"

# --- proxmox-mini-journalreader (plain C)
JR=proxmox-mini-journalreader-$JOURNALREADER_VERSION
make -C proxmox-mini-journalreader "$JR"
build_deps "proxmox-mini-journalreader/$JR"
dpkg_build "proxmox-mini-journalreader/$JR"

mkdir -p "$OUT"
find "$WORK" -maxdepth 4 -name '*.deb' -not -name '*-dbgsym_*' -exec cp -v {} "$OUT/" \;
(cd "$OUT" && sha256sum ./*.deb > SHA256SUMS && cat SHA256SUMS)
