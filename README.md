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

Each package has an independent version, following the `MAJOR.MINOR.PATCH-REVISION` format.

| Package | VERSION File | Description |
|---------|-------------|-------------|
| xvector | `xvector-dev/VERSION` | libxvector-dev .deb package |
| xcompute | `xvector-dev/VERSION_XCOMPUTE` | libxcompute-dev .deb package |
| xfaiss | `xfaiss/VERSION` | xfaiss source tarball |

- **Base version** (`MAJOR.MINOR.PATCH`): Changed via the `bump` command
- **Revision**: Automatically incremented on each `package` run, reset to 1 on `bump`
- Example: `0.1.0-1` → `0.1.0-2` → (patch bump) → `0.1.1-1`

## deploy.sh

### Check Version

```bash
./deploy.sh show              # Show all versions
./deploy.sh show xvector      # Show xvector version only
```

Example output:
```
xvector    0.1.0-1
xcompute   0.1.0-1
xfaiss     0.1.0-1 (faiss-1.13.0)
```

### Version Bump

```bash
./deploy.sh bump patch xvector    # 0.1.0-1 -> 0.1.1-1
./deploy.sh bump minor xcompute   # 0.1.0-1 -> 0.2.0-1
./deploy.sh bump major xfaiss     # 0.1.0-1 -> 1.0.0-1
./deploy.sh bump patch all        # Patch bump all packages
```

When bumping xvector, `project(xvector VERSION ...)` in `xvector-dev/CMakeLists.txt` is also updated.

### Packaging

```bash
./deploy.sh package               # Package all
./deploy.sh package xvector       # Generate libxvector-dev .deb only
./deploy.sh package xcompute      # Generate libxcompute-dev .deb only
./deploy.sh package xfaiss        # Generate xfaiss source tarball only
```

When packaging runs:
1. xvector/xcompute: Builds via `xvector-dev/scripts/build.sh --clean --release`, then generates .deb with cpack
2. xfaiss: Generates source tarball via `git archive` (`.gitattributes` export-ignore applied)
3. The revision of the packaged target is automatically incremented by +1

Generated artifacts:
```
packages/
  libxvector-dev_0.1.0-1_amd64.deb
  libxcompute-dev_0.1.0-1_amd64.deb
  xfaiss-0.1.0-1+faiss1.13.0-source.tar.gz
```

### Git Tag

```bash
./deploy.sh tag                   # Tag all
./deploy.sh tag xvector           # Tag xvector only
```

Tag format: `{target}-v{version}` (e.g., `xvector-v0.1.0-1`, `xfaiss-v0.1.0-1`)

Tag creation is rejected if there are uncommitted changes.

## Build Dependencies

The following are required for xvector/xcompute packaging:

- CMake 3.11+
- pxl (MU accelerator SDK)
- mu_std (`/usr/local/mu_library/mu`)
- dpkg-dev (cpack DEB generator)

Using a dev-container environment is recommended.
