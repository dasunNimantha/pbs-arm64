#!/usr/bin/env bash
# Fetch the pinned upstream sources and adapt their Debian packaging so they build on
# any architecture with plain cargo instead of Proxmox's Debian-packaged Rust crates.
#
#   scripts/prepare.sh <workdir>
#
# Every edit is asserted: if upstream changes a line we rely on, this fails loudly
# instead of producing a silently different build.
set -euo pipefail
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=advice.detachedHead GIT_CONFIG_VALUE_0=false

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=/dev/null
source "$ROOT/versions.env"
GIT=${PROXMOX_GIT:-https://git.proxmox.com/git}
WORK=${1:?usage: prepare.sh <workdir>}
mkdir -p "$WORK"
cd "$WORK"

fetch() { # repo dir commit
  rm -rf "$2"
  git init -q "$2"
  git -C "$2" fetch -q --depth 1 "$GIT/$1.git" "$3"
  git -C "$2" checkout -q FETCH_HEAD
  [[ "$(git -C "$2" rev-parse HEAD)" == "$3" ]] || { echo "commit mismatch for $1" >&2; exit 1; }
}

# replace exactly one-or-more matches of a regex, or fail
edit() { # file sed-expr grep-pattern-that-must-match-before description
  grep -qE "$3" "$1" || { echo "prepare: '$4' — pattern not found in $1" >&2; exit 1; }
  sed -i -E "$2" "$1"
}

fetch proxmox-backup proxmox-backup "$PBS_COMMIT"
fetch pve-xtermjs pve-xtermjs "$TERMPROXY_COMMIT"
fetch proxmox-mini-journalreader proxmox-mini-journalreader "$JOURNALREADER_COMMIT"

git_dep() { echo "{ git = \"$GIT/$1.git\", rev = \"$2\" }"; }

# --- Rust crates: patch every crate of the pinned proxmox workspace (plus pxar, pathpatterns,
# proxmox-fuse) to its git revision. Crates PBS doesn't use only produce a cargo warning.
fetch proxmox proxmox "$PROXMOX_COMMIT"
crate_names() { # dir
  find "$1" -name Cargo.toml -not -path '*/target/*' -print0 |
    xargs -0 awk '/^\[package\]/{p=1;next} /^\[/{p=0} p&&/^name *=/{gsub(/[" ]/,""); sub(/^name=/,""); print; nextfile}' |
    sort -u
}
PROXMOX_CRATES=$(crate_names proxmox)
(( $(wc -l <<<"$PROXMOX_CRATES") > 40 )) || { echo "prepare: too few crates found in proxmox workspace" >&2; exit 1; }
rm -rf proxmox

patch_crates() { # Cargo.toml
  local f=$1 c
  # drop upstream's commented-out local-path patch list and any existing [patch.crates-io] header
  sed -i -E '/^#[a-z0-9-]+ *= *\{ *path *= *"\.\.\//d; /^\[patch\.crates-io\]/d' "$f"
  {
    echo
    echo "[patch.crates-io]"
    while read -r c; do echo "$c = $(git_dep proxmox "$PROXMOX_COMMIT")"; done <<<"$PROXMOX_CRATES"
    echo "proxmox-fuse = $(git_dep proxmox-fuse "$PROXMOX_FUSE_COMMIT")"
    echo "pathpatterns = $(git_dep pathpatterns "$PATHPATTERNS_COMMIT")"
    echo "pxar = $(git_dep pxar "$PXAR_COMMIT")"
  } >> "$f"
  echo "prepare: $f: $(wc -l <<<"$PROXMOX_CRATES") proxmox crates + 3 others patched to pinned git revisions"
}

# --- Debian packaging: build against cargo/rustc instead of librust-*-dev packages
debianize() { # package dir containing debian/
  local d=$1
  # drop the Debian-packaged Rust crates and the x86-only biome linter
  edit "$d/debian/control" '/^\s*librust-[^ ,]+.*,?\s*$/d' '^\s*librust-' "drop librust-* build-deps"
  sed -i -E '/^\s*proxmox-biome\b/d' "$d/debian/control"
  # keep cargo/rustc/dh-cargo but take whatever trixie ships
  sed -i -E 's/^(\s*)(cargo|rustc|dh-cargo)(:native)?\s*\([^)]*\)/\1\2\3/' "$d/debian/control"
  # use plain cargo instead of Debian's offline-registry wrapper
  edit "$d/debian/rules" 's|^(export )?CARGO=/usr/share/cargo/bin/cargo$|\1CARGO=/usr/bin/cargo|' \
    '^(export )?CARGO=/usr/share/cargo/bin/cargo$' "use /usr/bin/cargo"
  edit "$d/debian/rules" '/\$\(CARGO\) prepare-debian /d' '\$\(CARGO\) prepare-debian ' "skip prepare-debian"
  # the config prepare-debian would have generated; rustflags line is extended by rules for static builds
  mkdir -p "$d/debian/cargo_home"
  cat > "$d/debian/cargo_home/config.toml" <<'EOF'
[build]
rustflags = ["-g"]

[resolver]
# pick crate versions that still build with Debian trixie's rustc
incompatible-rust-versions = "fallback"

[net]
git-fetch-with-cli = true
EOF
}

# upstream redirects crates.io to Debian's local crate store; keep only their release profile
for cfg in proxmox-backup/.cargo/config.toml pve-xtermjs/.cargo/config.toml; do
  grep -q 'replace-with = "debian-packages"' "$cfg" || { echo "prepare: $cfg no longer redirects crates.io?" >&2; exit 1; }
  printf '[profile.release]\ndebug = true\n' > "$cfg"
done

patch_crates proxmox-backup/Cargo.toml
debianize proxmox-backup

patch_crates pve-xtermjs/termproxy/Cargo.toml
debianize pve-xtermjs/termproxy

# --- Cargo.lock: reuse the committed one for this release, otherwise generate it
for crate in proxmox-backup pve-xtermjs/termproxy; do
  name=$(basename "$crate")
  lock="$ROOT/locks/$PBS_VERSION/$name.Cargo.lock"
  if [[ -f "$lock" ]]; then
    cp "$lock" "$crate/Cargo.lock"
    (cd "$crate" && cargo fetch --locked)
    echo "prepare: $name: using committed lockfile"
  else
    # only choose crate versions that build with this rustc (Debian trixie's), as the package build will
    (cd "$crate" && CARGO_RESOLVER_INCOMPATIBLE_RUST_VERSIONS=fallback cargo generate-lockfile)
    mkdir -p "$ROOT/locks/$PBS_VERSION"
    cp "$crate/Cargo.lock" "$lock"
    echo "prepare: $name: generated new lockfile -> locks/$PBS_VERSION/$name.Cargo.lock"
  fi
done
