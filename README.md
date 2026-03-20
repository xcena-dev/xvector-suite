# xvector-suite

Packaging and release management for xvector-dev and xfaiss.

| Submodule | Description |
|-----------|-------------|
| `xvector-dev` | Vector search library (libxvector-dev, libxarith-dev) |
| `xfaiss` | XCENA-modified FAISS fork |

## Usage

```bash
./package.sh [command]       # Run with no args for interactive menu
```

| Command | Description |
|---------|-------------|
| `status` | Show repo state, versions, and build artifacts |
| `sync` | Fetch latest submodule commits and commit references |
| `build [target]` | Build artifacts + dist tarball into `dist/build/` |
| `release prepare [target]` | Verify artifacts, create manifest, commit & tag (local) |
| `release publish [tag]` | Push tag + create GitHub Release (remote) |
| `docs build [tag]` | Build documentation with release-specific download paths |
| `docs preview` | Preview built documentation locally (localhost:8000) |
| `docs publish` | Deploy documentation to gh-pages |

**Targets:** `xvector`, `xarith`, `xfaiss`, `all` (default)

## Version Management

Each package follows semver (`MAJOR.MINOR.PATCH`) via VERSION files in submodules:

| Package | VERSION File |
|---------|-------------|
| xvector | `xvector-dev/VERSION` |
| xarith | `xvector-dev/VERSION_XARITH` |
| xfaiss | `xfaiss/VERSION` |

## Release Workflow

```bash
./package.sh sync                           # Update submodules to latest remote
./package.sh build                          # Build all artifacts locally
# ... verify artifacts locally ...
./package.sh release prepare                # Create manifest + tag (local)
./package.sh release publish                # Push tag + GitHub Release
./package.sh docs build                     # Build docs (auto-detect latest tag)
./package.sh docs preview                   # Preview docs locally
./package.sh docs publish                   # Deploy docs to gh-pages
```

`release prepare` validates artifacts, creates a release directory in `dist/`, writes a manifest, commits the manifest to `manifests/`, and creates a `release-{epoch}` tag locally.

`release publish` pushes the tag and creates a GitHub Release with the dist tarball and manifest.

Tags are created in xvector-suite with the format `release-{epoch}` (e.g., `release-1709512345`).

## Dependencies

CMake 3.11+, PXL, mu_std, dpkg-dev, jq, gh (GitHub CLI)
