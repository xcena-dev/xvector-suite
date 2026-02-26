# xvector-suite

A monorepo for unified management of xvector-dev and xfaiss.

| Submodule | Description |
|-----------|-------------|
| `xvector-dev` | High-performance vector search library (libxvector-dev, libxcompute-dev) |
| `xfaiss` | XCENA-modified FAISS fork (based on faiss 1.13.0) |

## Setup

```bash
git clone --recursive <repo-url>
# Or from an existing clone:
git submodule update --init
```

## Version Management

Each package has an independent version, following simple semver (`MAJOR.MINOR.PATCH`).
Version is managed directly in each submodule's VERSION file.

| Package | VERSION File | Description |
|---------|-------------|-------------|
| xvector | `xvector-dev/VERSION` | libxvector-dev .deb package |
| xcompute | `xvector-dev/VERSION_XCOMPUTE` | libxcompute-dev .deb package |
| xfaiss | `xfaiss/VERSION` | xfaiss source tarball |

## package.sh

### Check Version

```bash
./package.sh show              # Show all versions
./package.sh show xvector      # Show xvector version only
```

### Sync Submodules

```bash
./package.sh sync              # Fetch latest and commit submodule references
```

### Build Packages

```bash
./package.sh build                # Package all
./package.sh build xvector        # Generate libxvector-dev .deb only
./package.sh build xcompute       # Generate libxcompute-dev .deb only
./package.sh build xfaiss         # Generate xfaiss source tarball only
```

When packaging runs:
1. xvector/xcompute: Builds via `xvector.sh build --clean --release`, then generates .deb with cpack
2. xfaiss: Generates source tarball via `git archive` (`.gitattributes` export-ignore applied)

### Bump Version

```bash
./package.sh bump xvector patch   # 0.1.0 -> 0.1.1
./package.sh bump xcompute minor  # 0.1.0 -> 0.2.0
./package.sh bump xfaiss minor    # 0.1.0 -> 0.2.0 (preserves upstream= line)
```

### Git Tag & Release

```bash
./package.sh tag                   # Tag all
./package.sh tag xvector           # Tag xvector + xcompute (always together)
./package.sh tag xfaiss            # Tag xfaiss only
```

The tag command performs the following steps:

1. Verifies no uncommitted changes and build artifacts exist
2. Copies artifacts to `packages/build-YYYYMMDD-<hash>/` with `manifest.json`
3. Creates submodule tags:
   - xvector/xcompute are always tagged together (same repo, same commit)
   - xfaiss is tagged independently
4. Commits `releases/manifest-<epoch>.json` to repo for history tracking
5. Tags xvector-suite with `release-<epoch>`
6. Pushes tag and creates a GitHub Release with all artifacts

Tag formats:

| Scope | Tag Format | Repository |
|-------|-----------|------------|
| xvector | `xvector-v{version}` | xvector-dev |
| xcompute | `xcompute-v{version}` | xvector-dev |
| xfaiss | `xfaiss-v{version}` | xfaiss |
| suite | `release-{epoch}` | xvector-suite |

### Interactive Mode

```bash
./package.sh                       # Launch interactive menu
```

## Release History

Release manifests are tracked in `releases/manifest-<epoch>.json`.
Each manifest records the date, versions, git hashes, and artifact list.

To delete a published GitHub Release:
```bash
gh release delete <tag-name> --yes --cleanup-tag
```

## Build Dependencies

The following are required for xvector/xcompute packaging:

- CMake 3.11+
- Parallel Xceleration Library (PXL)
- mu_std (`/usr/local/mu_library/mu`)
- dpkg-dev (cpack DEB generator)
- jq
- gh (GitHub CLI, for release upload)
