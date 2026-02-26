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

Example output:
```
xvector    0.1.0
xcompute   0.1.0
xfaiss     0.1.0 (upstream=faiss-1.13.0)
```

### Build Packages

```bash
./package.sh build                # Package all
./package.sh build xvector        # Generate libxvector-dev .deb only
./package.sh build xcompute       # Generate libxcompute-dev .deb only
./package.sh build xfaiss         # Generate xfaiss source tarball only
```

When packaging runs:
1. xvector/xcompute: Builds via `xvector-dev/scripts/build.sh --clean --release`, then generates .deb with cpack
2. xfaiss: Generates source tarball via `git archive` (`.gitattributes` export-ignore applied)
3. Build is recorded in `packages/manifest.json` (version + git hash)

Generated artifacts:
```
packages/
  libxvector-dev_0.1.0_amd64.deb
  libxcompute-dev_0.1.0_amd64.deb
  xfaiss-0.1.0+faiss1.13.0-source.tar.gz
```

### Git Tag

```bash
./package.sh tag                   # Tag all
./package.sh tag xvector           # Tag xvector only
```

Tag format: `{target}-v{version}` (e.g., `xvector-v0.1.0`, `xfaiss-v0.1.0`)

Tag creation is rejected if there are uncommitted changes.

## Build Dependencies

The following are required for xvector/xcompute packaging:

- CMake 3.11+
- Parallel Xceleration Library (PXL)
- mu_std (`/usr/local/mu_library/mu`)
- dpkg-dev (cpack DEB generator)
