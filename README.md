# xvector-suite

Packaging and release management for xvector-dev and xfaiss.

| Submodule | Description |
|-----------|-------------|
| `xvector-dev` | Vector search library (libxvector-dev, libxarith-dev) |
| `xfaiss` | XCENA-modified FAISS fork |

## Setup

```bash
git clone --recursive <repo-url>
```

## Usage

```bash
./package.sh [command]       # Run with no args for interactive menu
```

| Command | Description |
|---------|-------------|
| `status` | Show repo state, versions, and build artifacts |
| `show [target]` | Show version(s) and git hashes |
| `sync` | Fetch latest submodule commits and update references |
| `build [target]` | Build artifacts into `dist/build/` |
| `bump <target> <type>` | Bump version (`major`, `minor`, `patch`) |
| `tag [target]` | Create git tags, manifest, and GitHub Release |
| `publish` | Deploy documentation to gh-pages |
| `clean` | Remove `dist/build/` |

**Targets:** `xvector`, `xarith`, `xfaiss`, `all` (default)

## Examples

```bash
./package.sh status
./package.sh show xvector
./package.sh sync
./package.sh build
./package.sh build xfaiss
./package.sh bump xvector patch    # 0.1.0 -> 0.1.1
./package.sh bump xfaiss minor     # 0.1.0 -> 0.2.0
./package.sh tag all
./package.sh publish
./package.sh clean
```

## Version Management

Each package follows semver (`MAJOR.MINOR.PATCH`) via VERSION files in submodules:

| Package | VERSION File |
|---------|-------------|
| xvector | `xvector-dev/VERSION` |
| xarith | `xvector-dev/VERSION_XARITH` |
| xfaiss | `xfaiss/VERSION` |

## Release Workflow

`tag` validates artifacts, creates per-component git tags, commits a manifest to `manifests/`, and publishes a GitHub Release.

| Scope | Tag Format | Repository |
|-------|-----------|------------|
| xvector | `xvector-v{version}` | xvector-dev |
| xarith | `xarith-v{version}` | xvector-dev |
| xfaiss | `xfaiss-v{version}` | xfaiss |
| suite | `release-{epoch}` | xvector-suite |

## Dependencies

CMake 3.11+, PXL, mu_std, dpkg-dev, jq, gh (GitHub CLI)
