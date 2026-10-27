# pbs-arm64

Unofficial arm64 build of [Proxmox Backup Server](https://www.proxmox.com/en/products/proxmox-backup-server),
built from Proxmox's official source and published as a container image.

Proxmox only ships PBS for amd64. Nothing in this repo changes how PBS backs up, deduplicates,
encrypts or verifies data. The only changes are to how it's packaged, so it builds with plain
`cargo` on any architecture.

```
ghcr.io/dasunnimantha/pbs-arm64:<pbs-version>
```

Not affiliated with or supported by Proxmox Server Solutions GmbH.

## How it's built

| Step | What happens |
|---|---|
| Pin (`scripts/pin.sh`) | `proxmox-backup` at the release tag. Its Rust crate repos (`proxmox`, `pxar`, `pathpatterns`, `proxmox-fuse`) at the last commit at or before the release. `proxmox-termproxy` and `proxmox-mini-journalreader` at the commits that produced the versions Proxmox currently ships. Everything is cloned over https and checked against the pinned commit. |
| Prepare (`scripts/prepare.sh`) | The upstream Debian packaging expects Proxmox's Debian-packaged Rust crates, which only exist for amd64. Instead, every Proxmox crate is resolved via Cargo's `[patch.crates-io]` to its pinned git revision, and the other crates come from crates.io as locked in `locks/<version>/*.Cargo.lock`. Each packaging edit is asserted, so the build fails instead of silently diverging if upstream changes. |
| Build (`scripts/build.sh`) | Runs on a native arm64 GitHub runner in the official `rust:<version>-slim-trixie` image (pinned by digest), using the same rustc version Proxmox builds PBS with. The build is offline (`--locked`), uses the `nodoc` profile, and skips the x86-only JS linter (`BIOME=true`). |
| Image (`Dockerfile`) | Our arch-specific `.deb`s plus the `Architecture: all` packages (web UI toolkit, ExtJS, i18n, docs, ACME plugins) unchanged from Proxmox's signed `pbs-no-subscription` repo. |
| Publish | Image pushed to GHCR, signed with cosign (keyless), with SBOM and provenance attestations. The `.deb`s are attached to a GitHub release. |
| Update (`upstream.yml`) | Daily check for a new `vX.Y.Z` tag of `proxmox-backup`. When there is one, it re-pins and builds automatically. The first build of a version generates and commits its lockfiles. |

Packages built here: `proxmox-backup-server`, `proxmox-backup-client`, `proxmox-backup-client-static`,
`proxmox-backup-file-restore`, `proxmox-termproxy`, `proxmox-mini-journalreader`.

## Running

```yaml
services:
  pbs:
    image: ghcr.io/dasunnimantha/pbs-arm64:4.2.8
    restart: unless-stopped
    ports: ["8007:8007"]
    tmpfs: [/run]
    volumes:
      - ./etc:/etc/proxmox-backup
      - ./lib:/var/lib/proxmox-backup
      - ./log:/var/log/proxmox-backup
      - /mnt/data/pbs:/datastore
    secrets: [pbs_admin_password]
secrets:
  pbs_admin_password:
    file: ./admin-password   # used once on first start to create admin@pbs
```

There is no default password. On first start, `admin@pbs` is created from the secret. Then add a
datastore at `/datastore` in the UI (`https://<host>:8007`) or with
`proxmox-backup-manager datastore create`.

Limitations of running in a container: no ZFS, no PAM users (use `@pbs` users), and the web
shell is unavailable.

Verify an image:

```
cosign verify ghcr.io/dasunnimantha/pbs-arm64:4.2.8 \
  --certificate-identity-regexp 'https://github.com/dasunNimantha/pbs-arm64/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Credits

The approach of building PBS outside Proxmox's Debian Rust infrastructure was pioneered by
[ayufan/pve-backup-server-dockerfiles](https://github.com/ayufan/pve-backup-server-dockerfiles).
This repo is an independent implementation.

## License

AGPL-3.0-or-later, same as Proxmox Backup Server.
