#!/bin/bash

set -uo pipefail

SUITE_ROOT="$(cd "$(dirname "$0")" && pwd)"
XVECTOR_DIR="${SUITE_ROOT}/xvector-dev"
XFAISS_DIR="${SUITE_ROOT}/xfaiss"
PACKAGES_DIR="${SUITE_ROOT}/packages"
BUILD_DIR="${PACKAGES_DIR}/build"
XVECTOR_SH="${XVECTOR_DIR}/scripts/xvector.sh"
PACKAGING_SH="${XVECTOR_DIR}/scripts/packaging.sh"

# VERSION file paths
XVECTOR_VERSION_FILE="${XVECTOR_DIR}/VERSION"
XCOMPUTE_VERSION_FILE="${XVECTOR_DIR}/VERSION_XCOMPUTE"
XFAISS_VERSION_FILE="${XFAISS_DIR}/VERSION"

# Default representative branches per submodule
XVECTOR_DEFAULT_BRANCH="main"
XFAISS_DEFAULT_BRANCH="faiss-1.13.0-xcena"

# --- Logging (self-contained, no submodule dependency) ---
log_info()  { echo -e "\033[0;32m[INFO]\033[0m  $*"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }
log_warn()  { echo -e "\033[0;33m[WARN]\033[0m  $*"; }

# --- Step tracking & timing ---
_STEP_NUM=0
_STEP_TOTAL=0
_STEP_START=0
_PACKAGE_START=0
declare -a _STEP_TIMES=()
declare -a _STEP_NAMES=()

# Format seconds into human-readable duration
format_duration() {
    local secs="$1"
    if (( secs >= 60 )); then
        printf "%dm %ds" $((secs / 60)) $((secs % 60))
    else
        printf "%ds" "${secs}"
    fi
}

# Begin a numbered step: step_begin <total> <description>
step_begin() {
    local total="$1"; shift
    local desc="$*"
    _STEP_TOTAL="${total}"
    ((_STEP_NUM++))
    _STEP_START=$(date +%s)
    _STEP_NAMES+=("${desc}")
    echo ""
    echo -e "\033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    echo -e "\033[1;36m  [${_STEP_NUM}/${total}] ${desc}\033[0m"
    echo -e "\033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
}

# End current step, record elapsed time
step_end() {
    local elapsed=$(( $(date +%s) - _STEP_START ))
    _STEP_TIMES+=("${elapsed}")
    echo -e "\033[0;32m  ✓ Done ($(format_duration ${elapsed}))\033[0m"
}

# Print final timing summary
print_summary() {
    local total_elapsed=$(( $(date +%s) - _PACKAGE_START ))
    echo ""
    echo -e "\033[1;35m╔══════════════════════════════════════════════════════════════════════╗\033[0m"
    printf "\033[1;35m║  %-68s║\033[0m\n" "Packaging Summary"
    echo -e "\033[1;35m╠══════════════════════════════════════════════════════════════════════╣\033[0m"
    for i in "${!_STEP_NAMES[@]}"; do
        local dur
        dur=$(format_duration "${_STEP_TIMES[$i]}")
        printf "\033[1;35m║\033[0m  [%d/%d] %-52s %8s \033[1;35m║\033[0m\n" \
            $((i + 1)) "${_STEP_TOTAL}" "${_STEP_NAMES[$i]}" "${dur}"
    done
    echo -e "\033[1;35m╠══════════════════════════════════════════════════════════════════════╣\033[0m"
    printf "\033[1;35m║\033[0m  %-58s \033[1;33m%8s\033[0m \033[1;35m║\033[0m\n" \
        "Total" "$(format_duration ${total_elapsed})"
    echo -e "\033[1;35m╚══════════════════════════════════════════════════════════════════════╝\033[0m"
}

# --- Submodule commit verification ---

# Get current branch name for a git repo
get_current_branch() {
    local repo_dir="$1"
    git -C "${repo_dir}" rev-parse --abbrev-ref HEAD 2>/dev/null
}

# Get the commit hash that the parent repo expects for a submodule
get_expected_hash() {
    local submodule_path="$1"
    git -C "${SUITE_ROOT}" ls-tree HEAD -- "${submodule_path}" | awk '{print $3}'
}

# Verify submodules are at the commit hashes recorded in xvector-suite
verify_submodule_commits() {
    local failed=0

    local expected_xvector actual_xvector
    expected_xvector=$(get_expected_hash "xvector-dev")
    actual_xvector=$(git -C "${XVECTOR_DIR}" rev-parse HEAD 2>/dev/null)
    if [[ "${actual_xvector}" != "${expected_xvector}" ]]; then
        log_error "xvector-dev commit mismatch:"
        log_error "  expected: ${expected_xvector:0:12}"
        log_error "  actual:   ${actual_xvector:0:12}"
        failed=1
    fi

    local expected_xfaiss actual_xfaiss
    expected_xfaiss=$(get_expected_hash "xfaiss")
    actual_xfaiss=$(git -C "${XFAISS_DIR}" rev-parse HEAD 2>/dev/null)
    if [[ "${actual_xfaiss}" != "${expected_xfaiss}" ]]; then
        log_error "xfaiss commit mismatch:"
        log_error "  expected: ${expected_xfaiss:0:12}"
        log_error "  actual:   ${actual_xfaiss:0:12}"
        failed=1
    fi

    if [[ ${failed} -ne 0 ]]; then
        log_error "Submodule commit mismatch. Run 'git submodule update --init' to sync."
        exit 1
    fi

    log_info "Submodule commits verified"
    log_info "  xvector-dev = ${actual_xvector}"
    log_info "  xfaiss      = ${actual_xfaiss}"
}


# --- Helpers ---

# Get full git hash for a repo
get_git_hash() {
    local repo_dir="$1"
    git -C "${repo_dir}" rev-parse HEAD
}

# --- Version helpers ---

# Read version from VERSION file (pure semver, e.g. "0.1.4")
read_version() {
    local file="$1"
    if [[ ! -f "${file}" ]]; then
        log_error "VERSION file not found: ${file}"
        exit 1
    fi
    _VERSION=$(head -1 "${file}" | tr -d '[:space:]')
}

# Read xfaiss version → sets _VERSION, _UPSTREAM
read_xfaiss_version() {
    read_version "$1"
    _UPSTREAM=$(grep '^upstream=' "$1" 2>/dev/null | cut -d= -f2)
    _UPSTREAM="${_UPSTREAM:-unknown}"
}

# Bump semver component: bump_semver <current_version> <type> → prints new version
bump_semver() {
    local version="$1"
    local bump_type="$2"
    local major minor patch
    IFS='.' read -r major minor patch <<< "${version}"
    major=${major:-0}; minor=${minor:-0}; patch=${patch:-0}

    case "${bump_type}" in
        major) echo "$((major + 1)).0.0" ;;
        minor) echo "${major}.$((minor + 1)).0" ;;
        patch) echo "${major}.${minor}.$((patch + 1))" ;;
        *) log_error "Invalid bump type: ${bump_type}. Must be major, minor, or patch."; exit 1 ;;
    esac
}

# --- bump ---

cmd_bump() {
    local target="${1:-}"
    local bump_type="${2:-}"

    if [[ -z "${target}" || -z "${bump_type}" ]]; then
        log_error "Usage: package.sh bump <target> <type>"
        log_error "  target: xvector, xcompute, xfaiss"
        log_error "  type:   major, minor, patch"
        exit 1
    fi

    case "${target}" in
        xvector|xcompute|xfaiss) ;;
        *) log_error "Invalid target: ${target}. Must be xvector, xcompute, or xfaiss."; exit 1 ;;
    esac

    local version_file
    case "${target}" in
        xvector)  version_file="${XVECTOR_VERSION_FILE}" ;;
        xcompute) version_file="${XCOMPUTE_VERSION_FILE}" ;;
        xfaiss)   version_file="${XFAISS_VERSION_FILE}" ;;
    esac

    case "${bump_type}" in
        major|minor|patch) ;;
        *) log_error "Invalid bump type: ${bump_type}. Must be major, minor, or patch."; exit 1 ;;
    esac

    # Read current version (first line)
    read_version "${version_file}"
    local current="${_VERSION}"
    local new_version
    new_version=$(bump_semver "${current}" "${bump_type}")

    log_info "Bumping ${target}: ${current} -> ${new_version}"

    if [[ "${target}" == "xfaiss" ]]; then
        # Preserve upstream= line
        read_xfaiss_version "${version_file}"
        printf '%s\n' "${new_version}" "upstream=${_UPSTREAM}" > "${version_file}"
    else
        echo "${new_version}" > "${version_file}"
    fi

    log_info "Updated ${version_file}"
    log_info "Don't forget to commit in the submodule and update xvector-suite."
}

# Validate target argument
validate_target() {
    local target="$1"
    case "${target}" in
        xvector|xcompute|xfaiss|all) return 0 ;;
        *) log_error "Invalid target: ${target}. Must be xvector, xcompute, xfaiss, or all."; exit 1 ;;
    esac
}

# --- show ---

cmd_show() {
    local target="${1:-all}"
    validate_target "${target}"

    if [[ "${target}" == "all" || "${target}" == "xvector" ]]; then
        read_version "${XVECTOR_VERSION_FILE}"
        echo "xvector    ${_VERSION} ($(git -C "${XVECTOR_DIR}" rev-parse HEAD))"
    fi
    if [[ "${target}" == "all" || "${target}" == "xcompute" ]]; then
        read_version "${XCOMPUTE_VERSION_FILE}"
        echo "xcompute   ${_VERSION} ($(git -C "${XVECTOR_DIR}" rev-parse HEAD))"
    fi
    if [[ "${target}" == "all" || "${target}" == "xfaiss" ]]; then
        read_xfaiss_version "${XFAISS_VERSION_FILE}"
        echo "xfaiss     ${_VERSION} ($(git -C "${XFAISS_DIR}" rev-parse HEAD)) upstream=${_UPSTREAM}"
    fi
}

# --- package ---

cmd_package() {
    local target="${1:-all}"
    validate_target "${target}"

    mkdir -p "${BUILD_DIR}"

    if [[ ! -x "${XVECTOR_SH}" ]]; then
        log_error "xvector.sh not found: ${XVECTOR_SH}"
        exit 1
    fi

    # Count total steps based on target
    local total_steps=0
    if [[ "${target}" == "all" || "${target}" == "xvector" || "${target}" == "xcompute" ]]; then
        ((total_steps += 3))  # build + deb + docs build
    fi
    if [[ "${target}" == "all" || "${target}" == "xcompute" ]]; then
        ((total_steps += 1))  # examples
    fi
    if [[ "${target}" == "all" || "${target}" == "xfaiss" ]]; then
        ((total_steps += 1))  # xfaiss archive
    fi
    if [[ "${target}" == "all" || "${target}" == "xvector" ]]; then
        ((total_steps += 1))  # xvector docs package
    fi
    if [[ "${target}" == "all" || "${target}" == "xcompute" ]]; then
        ((total_steps += 1))  # xcompute docs package
    fi

    _STEP_NUM=0
    _STEP_TIMES=()
    _STEP_NAMES=()
    _PACKAGE_START=$(date +%s)

    # 1. Build xvector-dev (clean release)
    if [[ "${target}" == "all" || "${target}" == "xvector" || "${target}" == "xcompute" ]]; then
        step_begin "${total_steps}" "Build xvector-dev (clean release)"
        if ! "${XVECTOR_SH}" build --release --clean; then
            log_error "xvector-dev build failed"
            exit 1
        fi
        step_end
    fi

    # 2. Create .deb packages (libxvector-dev + libxcompute-dev)
    if [[ "${target}" == "all" || "${target}" == "xvector" || "${target}" == "xcompute" ]]; then
        step_begin "${total_steps}" "Create Debian packages"
        package_deb
        step_end
    fi

    # 3. Create xcompute examples tarball
    if [[ "${target}" == "all" || "${target}" == "xcompute" ]]; then
        step_begin "${total_steps}" "Create xcompute examples tarball"
        package_examples
        step_end
    fi

    # 4. Create xfaiss source archive
    if [[ "${target}" == "all" || "${target}" == "xfaiss" ]]; then
        step_begin "${total_steps}" "Create xfaiss source archive"
        package_xfaiss
        step_end
    fi

    # 5. Build documentation (MkDocs + Doxygen)
    if [[ "${target}" == "all" || "${target}" == "xvector" || "${target}" == "xcompute" ]]; then
        step_begin "${total_steps}" "Build documentation (MkDocs + Doxygen)"
        build_docs_xvector_dev
        step_end
    fi

    # 6. Package xvector docs
    if [[ "${target}" == "all" || "${target}" == "xvector" ]]; then
        step_begin "${total_steps}" "Package xvector documentation"
        docs_xvector
        step_end
    fi

    # 7. Package xcompute docs
    if [[ "${target}" == "all" || "${target}" == "xcompute" ]]; then
        step_begin "${total_steps}" "Package xcompute documentation"
        docs_xcompute
        step_end
    fi

    # Print timing summary
    print_summary

    echo ""
    log_info "Artifacts in ${BUILD_DIR}/:"
    ls -lh "${BUILD_DIR}/"
}

package_deb() {
    log_info "Creating Debian packages..."
    if ! "${PACKAGING_SH}" deb --output "${BUILD_DIR}"; then
        log_error "Debian package creation failed"
        exit 1
    fi
}

package_examples() {
    log_info "Creating xcompute examples tarball..."
    if ! "${PACKAGING_SH}" examples --output "${BUILD_DIR}"; then
        log_error "Examples tarball creation failed"
        exit 1
    fi
}

package_xfaiss() {
    read_xfaiss_version "${XFAISS_VERSION_FILE}"
    local version="${_VERSION}"
    local upstream_short="${_UPSTREAM#faiss-}"
    local tarball_name="xfaiss-${version}+faiss${upstream_short}-source.tar.gz"

    log_info "Creating ${tarball_name}..."

    if [[ ! -e "${XFAISS_DIR}/.git" ]]; then
        log_error "xfaiss is not a git repository: ${XFAISS_DIR}"
        exit 1
    fi

    local temp_dir
    temp_dir=$(mktemp -d)
    local archive_dir="${temp_dir}/xfaiss-${version}"

    # Extract source via git archive (respects .gitattributes export-ignore)
    mkdir -p "${archive_dir}"
    git -C "${XFAISS_DIR}" archive --worktree-attributes HEAD | tar -x -C "${archive_dir}"

    # Insert VERSION file into tarball
    cp "${XFAISS_VERSION_FILE}" "${archive_dir}/VERSION"

    # Create tarball
    tar -czf "${BUILD_DIR}/${tarball_name}" -C "${temp_dir}" "xfaiss-${version}"
    rm -rf "${temp_dir}"

    log_info "Created: ${tarball_name}"
}

# --- tag ---

cmd_tag() {
    local target="${1:-all}"
    validate_target "${target}"

    # Check for uncommitted changes in suite
    if ! git -C "${SUITE_ROOT}" diff --quiet HEAD 2>/dev/null; then
        log_error "Uncommitted changes in xvector-suite. Please commit first."
        exit 1
    fi

    # Verify build artifacts exist
    if [[ ! -d "${BUILD_DIR}" ]] || [[ -z "$(ls -A "${BUILD_DIR}" 2>/dev/null)" ]]; then
        log_error "No build artifacts found in ${BUILD_DIR}. Run build first."
        exit 1
    fi

    # Create release directory: build-YYYYMMDD-<suite_hash>
    local date_str suite_hash release_name release_dir
    date_str=$(date +%Y%m%d)
    suite_hash=$(git -C "${SUITE_ROOT}" rev-parse --short=7 HEAD)
    release_name="build-${date_str}-${suite_hash}"
    release_dir="${PACKAGES_DIR}/${release_name}"

    if [[ -d "${release_dir}" ]]; then
        log_error "Release directory already exists: ${release_dir}"
        exit 1
    fi

    # Copy build artifacts to release directory
    cp -r "${BUILD_DIR}" "${release_dir}"
    log_info "Artifacts copied to ${release_dir}/"

    # Record manifest in release directory
    local manifest="${release_dir}/manifest.json"
    local xv_hash xf_hash
    xv_hash=$(get_git_hash "${XVECTOR_DIR}")
    xf_hash=$(get_git_hash "${XFAISS_DIR}")

    read_version "${XVECTOR_VERSION_FILE}";  local xv_ver="${_VERSION}"
    read_version "${XCOMPUTE_VERSION_FILE}"; local xc_ver="${_VERSION}"
    read_xfaiss_version "${XFAISS_VERSION_FILE}"; local xf_ver="${_VERSION}"

    jq -n \
        --arg suite_hash "$(git -C "${SUITE_ROOT}" rev-parse HEAD)" \
        --arg xv_hash "${xv_hash}" \
        --arg xf_hash "${xf_hash}" \
        --arg xv_ver "${xv_ver}" \
        --arg xc_ver "${xc_ver}" \
        --arg xf_ver "${xf_ver}" \
        --arg date "${date_str}" \
        '{
            date: $date,
            suite_commit: $suite_hash,
            xvector: { version: $xv_ver, git_hash: $xv_hash },
            xcompute: { version: $xc_ver, git_hash: $xv_hash },
            xfaiss: { version: $xf_ver, git_hash: $xf_hash },
            artifacts: []
        }' > "${manifest}"

    # List artifacts
    local artifacts=()
    for f in "${release_dir}"/*; do
        [[ "$(basename "$f")" == "manifest.json" ]] && continue
        artifacts+=("$(basename "$f")")
    done
    local artifacts_json
    artifacts_json=$(printf '%s\n' "${artifacts[@]}" | jq -R . | jq -s .)
    jq --argjson arts "${artifacts_json}" '.artifacts = $arts' "${manifest}" > "${manifest}.tmp"
    mv "${manifest}.tmp" "${manifest}"

    log_info "Manifest written: ${manifest}"

    # Create git tags
    # xvector and xcompute are always tagged together (same repo, same commit)
    if [[ "${target}" == "all" || "${target}" == "xvector" || "${target}" == "xcompute" ]]; then
        tag_target "xvector"
        tag_target "xcompute"
    fi
    if [[ "${target}" == "all" || "${target}" == "xfaiss" ]]; then
        tag_target "xfaiss"
    fi

    # Save manifest to repo for history tracking
    local releases_dir="${SUITE_ROOT}/releases"
    local epoch
    epoch=$(date +%s)
    mkdir -p "${releases_dir}"
    cp "${manifest}" "${releases_dir}/manifest-${epoch}.json"
    git -C "${SUITE_ROOT}" add "releases/manifest-${epoch}.json"
    git -C "${SUITE_ROOT}" commit -m "Add release manifest (xvector=${xv_ver}, xcompute=${xc_ver}, xfaiss=${xf_ver})"
    log_info "Manifest committed: releases/manifest-${epoch}.json"

    # Tag xvector-suite itself (after manifest commit)
    local suite_tag="release-${epoch}"
    git -C "${SUITE_ROOT}" tag -a "${suite_tag}" -m "Release ${date_str} (xvector=${xv_ver}, xcompute=${xc_ver}, xfaiss=${xf_ver})"
    log_info "Created tag: ${suite_tag} in xvector-suite"

    echo ""
    log_info "Release: ${release_name}"
    log_info "  suite         = $(git -C "${SUITE_ROOT}" rev-parse HEAD)"
    log_info "  xvector-dev   = ${xv_hash}"
    log_info "  xfaiss        = ${xf_hash}"
    echo ""
    ls -lh "${release_dir}/"

    # Push suite tag and create GitHub Release
    echo ""
    log_info "Pushing tag ${suite_tag} to origin..."
    git -C "${SUITE_ROOT}" push origin HEAD "${suite_tag}"

    # Collect artifact files (exclude manifest.json)
    local release_files=()
    for f in "${release_dir}"/*; do
        [[ "$(basename "$f")" == "manifest.json" ]] && continue
        release_files+=("${f}")
    done
    # Include manifest as well
    release_files+=("${release_dir}/manifest.json")

    local release_body
    release_body=$(cat <<GHEOF
## ${suite_tag}

| Component | Version | Commit |
|-----------|---------|--------|
| xvector | ${xv_ver} | \`${xv_hash}\` |
| xcompute | ${xc_ver} | \`${xv_hash}\` |
| xfaiss | ${xf_ver} | \`${xf_hash}\` |

**Suite commit:** \`$(git -C "${SUITE_ROOT}" rev-parse HEAD)\`
GHEOF
)

    log_info "Creating GitHub Release ${suite_tag}..."
    if gh release create "${suite_tag}" \
        --title "${suite_tag}" \
        --notes "${release_body}" \
        "${release_files[@]}"; then
        log_info "GitHub Release created: ${suite_tag}"
    else
        log_warn "GitHub Release creation failed. You can create it manually with:"
        log_warn "  gh release create ${suite_tag} ${release_dir}/*"
    fi
}

tag_target() {
    local target="$1"
    local version_file repo_dir

    case "${target}" in
        xvector)
            version_file="${XVECTOR_VERSION_FILE}"
            repo_dir="${XVECTOR_DIR}"
            ;;
        xcompute)
            version_file="${XCOMPUTE_VERSION_FILE}"
            repo_dir="${XVECTOR_DIR}"
            ;;
        xfaiss)
            version_file="${XFAISS_VERSION_FILE}"
            repo_dir="${XFAISS_DIR}"
            ;;
    esac

    read_version "${version_file}"
    local tag_name="${target}-v${_VERSION}"

    if git -C "${repo_dir}" tag -l "${tag_name}" | grep -q "${tag_name}"; then
        log_warn "Tag ${tag_name} already exists in $(basename "${repo_dir}"), skipping"
        return
    fi

    git -C "${repo_dir}" tag -a "${tag_name}" -m "Release ${target} ${_VERSION}"
    log_info "Created tag: ${tag_name} in $(basename "${repo_dir}")"
}

# --- docs (called from cmd_package) ---

build_docs_xvector_dev() {
    if [[ ! -d "${XVECTOR_DIR}/.venv" ]]; then
        log_info "Python venv not found. Running setup..."
        if ! "${XVECTOR_SH}" setup; then
            log_error "Setup failed"
            exit 1
        fi
    fi

    log_info "Building documentation (MkDocs + Doxygen)..."
    if ! "${XVECTOR_SH}" docs build; then
        log_error "Documentation build failed"
        exit 1
    fi
}

docs_xvector() {
    read_version "${XVECTOR_VERSION_FILE}"
    local version="${_VERSION}"
    local site_dir="${XVECTOR_DIR}/build/site/xvector"
    local tarball_name="xvector-docs_${version}.tar.gz"

    if [[ ! -d "${site_dir}" ]]; then
        log_error "Documentation not found: ${site_dir}"
        exit 1
    fi

    log_info "Packaging xvector ${version} documentation..."
    tar -czf "${BUILD_DIR}/${tarball_name}" -C "${XVECTOR_DIR}/build/site" "xvector"
    log_info "Created: ${tarball_name}"
}

docs_xcompute() {
    read_version "${XCOMPUTE_VERSION_FILE}"
    local version="${_VERSION}"
    local site_dir="${XVECTOR_DIR}/build/site/xcompute"
    local tarball_name="xcompute-docs_${version}.tar.gz"

    if [[ ! -d "${site_dir}" ]]; then
        log_error "Documentation not found: ${site_dir}"
        exit 1
    fi

    log_info "Packaging xcompute ${version} documentation..."
    tar -czf "${BUILD_DIR}/${tarball_name}" -C "${XVECTOR_DIR}/build/site" "xcompute"
    log_info "Created: ${tarball_name}"
}


# --- sync ---

cmd_sync() {
    local changed=0

    # Ensure submodules are initialized and checked out
    log_info "Initializing submodules..."
    git -C "${SUITE_ROOT}" submodule update --init

    # xvector-dev
    log_info "Fetching xvector-dev origin/${XVECTOR_DEFAULT_BRANCH}..."
    git -C "${XVECTOR_DIR}" fetch origin "${XVECTOR_DEFAULT_BRANCH}"

    local xv_before xv_after
    xv_before=$(git -C "${XVECTOR_DIR}" rev-parse HEAD)
    xv_after=$(git -C "${XVECTOR_DIR}" rev-parse "origin/${XVECTOR_DEFAULT_BRANCH}")

    if [[ "${xv_before}" != "${xv_after}" ]]; then
        git -C "${XVECTOR_DIR}" checkout "${XVECTOR_DEFAULT_BRANCH}" 2>/dev/null \
            || git -C "${XVECTOR_DIR}" checkout -b "${XVECTOR_DEFAULT_BRANCH}" "origin/${XVECTOR_DEFAULT_BRANCH}"
        git -C "${XVECTOR_DIR}" merge --ff-only "origin/${XVECTOR_DEFAULT_BRANCH}"
        log_info "xvector-dev: ${xv_before:0:7} -> ${xv_after:0:7}"
        changed=1
    else
        log_info "xvector-dev: already up to date (${xv_before:0:7})"
    fi

    # xfaiss
    log_info "Fetching xfaiss origin/${XFAISS_DEFAULT_BRANCH}..."
    git -C "${XFAISS_DIR}" fetch origin "${XFAISS_DEFAULT_BRANCH}"

    local xf_before xf_after
    xf_before=$(git -C "${XFAISS_DIR}" rev-parse HEAD)
    xf_after=$(git -C "${XFAISS_DIR}" rev-parse "origin/${XFAISS_DEFAULT_BRANCH}")

    if [[ "${xf_before}" != "${xf_after}" ]]; then
        git -C "${XFAISS_DIR}" checkout "${XFAISS_DEFAULT_BRANCH}" 2>/dev/null \
            || git -C "${XFAISS_DIR}" checkout -b "${XFAISS_DEFAULT_BRANCH}" "origin/${XFAISS_DEFAULT_BRANCH}"
        git -C "${XFAISS_DIR}" merge --ff-only "origin/${XFAISS_DEFAULT_BRANCH}"
        log_info "xfaiss: ${xf_before:0:7} -> ${xf_after:0:7}"
        changed=1
    else
        log_info "xfaiss: already up to date (${xf_before:0:7})"
    fi

    # Check if parent repo's recorded commits differ from actual submodule HEADs
    local expected_xv expected_xf actual_xv actual_xf
    expected_xv=$(get_expected_hash "xvector-dev")
    expected_xf=$(get_expected_hash "xfaiss")
    actual_xv=$(git -C "${XVECTOR_DIR}" rev-parse HEAD)
    actual_xf=$(git -C "${XFAISS_DIR}" rev-parse HEAD)

    if [[ "${expected_xv}" != "${actual_xv}" || "${expected_xf}" != "${actual_xf}" ]]; then
        changed=1
    fi

    # Commit updated submodule references in parent repo
    if [[ ${changed} -ne 0 ]]; then
        echo ""
        git -C "${SUITE_ROOT}" add xvector-dev xfaiss
        git -C "${SUITE_ROOT}" commit -m "Update submodule references for xvector-dev and xfaiss"
        log_info "Submodule references committed."
    else
        echo ""
        log_info "Nothing to update."
    fi
}

# --- Usage ---

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [options]

Packaging and release management for xvector-suite.
Version is managed in each submodule's VERSION file (pure semver).

Commands:
  show [target]      Show version(s)
  sync               Fetch latest submodule commits and commit references
  build [target]     Build artifacts into packages/build/
  bump <target> <type>
                     Bump version (major, minor, patch)
                     Targets: xvector, xcompute, xfaiss
  tag [target]       Create git tags and finalize release to packages/build-YYYYMMDD-<hash>/
  publish            Publish documentation to gh-pages (always fresh, no stale files)

Targets:
  xvector    libxvector-dev .deb package / API docs
  xcompute   libxcompute-dev .deb package / examples / API docs
  xfaiss     xfaiss source tarball
  all        All targets (default)

Examples:
    $(basename "$0") show
    $(basename "$0") show xvector
    $(basename "$0") build
    $(basename "$0") build xfaiss
    $(basename "$0") tag all
    $(basename "$0") bump xvector patch   # 0.1.0 -> 0.1.1
    $(basename "$0") bump xfaiss minor    # 0.1.0 -> 0.2.0 (preserves upstream= line)
    $(basename "$0") sync                 # Update submodules to latest remote
    $(basename "$0") publish               # Publish docs to gh-pages
EOF
}

# --- Interactive menu ---

interactive_menu() {
    echo ""
    echo -e "\033[1;36m  xvector-suite packaging\033[0m"
    echo ""
    echo "  1) build    Sync submodules + build artifacts"
    echo "  2) bump     Bump version (after testing)"
    echo "  3) tag      Create git tags"
    echo "  4) publish  Publish docs to gh-pages"
    echo ""
    echo "  h) help     Show full usage"
    echo "  q) quit"
    echo ""

    local choice
    read -rp "  Select [1-4, h, q]: " choice

    case "${choice}" in
        1) interactive_build ;;
        2) interactive_bump ;;
        3) verify_submodule_commits; interactive_tag ;;
        4) cmd_publish ;;
        h) usage ;;
        q) exit 0 ;;
        *) log_error "Invalid choice: ${choice}"; exit 1 ;;
    esac
}

interactive_bump() {
    echo ""
    echo "  Target:"
    echo "    1) xvector"
    echo "    2) xcompute"
    echo "    3) xfaiss"
    echo ""
    local target_choice
    read -rp "  Select target [1-3]: " target_choice
    local target
    case "${target_choice}" in
        1) target="xvector" ;;
        2) target="xcompute" ;;
        3) target="xfaiss" ;;
        *) log_error "Invalid target"; exit 1 ;;
    esac

    echo ""
    echo "  Bump type:"
    echo "    1) patch  (0.1.0 -> 0.1.1)"
    echo "    2) minor  (0.1.0 -> 0.2.0)"
    echo "    3) major  (0.1.0 -> 1.0.0)"
    echo ""
    local type_choice
    read -rp "  Select type [1-3]: " type_choice
    local bump_type
    case "${type_choice}" in
        1) bump_type="patch" ;;
        2) bump_type="minor" ;;
        3) bump_type="major" ;;
        *) log_error "Invalid bump type"; exit 1 ;;
    esac

    cmd_bump "${target}" "${bump_type}"
}

interactive_build() {
    cmd_sync
    verify_submodule_commits
    cmd_show
    echo ""
    cmd_package "all"
}

interactive_tag() {
    echo ""
    echo "  Target:"
    echo "    1) all"
    echo "    2) xvector + xcompute  (always tagged together)"
    echo "    3) xfaiss"
    echo ""
    local choice
    read -rp "  Select target [1-3]: " choice
    local target
    case "${choice}" in
        1) target="all" ;;
        2) target="xvector" ;;
        3) target="xfaiss" ;;
        *) log_error "Invalid target"; exit 1 ;;
    esac

    cmd_tag "${target}"
}

# --- publish (gh-pages) ---

cmd_publish() {
    local site_dir="${XVECTOR_DIR}/build/site"

    if [[ ! -d "${site_dir}/xvector" ]] || [[ ! -d "${site_dir}/xcompute" ]]; then
        log_error "Documentation not found in ${site_dir}."
        log_error "Run './package.sh build' first to generate docs."
        exit 1
    fi

    log_info "Deploying documentation to gh-pages..."

    # Work in a temporary clone to avoid touching the working tree
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "${tmp_dir}"' EXIT

    # Copy site contents first (before any git ops in tmp)
    cp -r "${site_dir}/." "${tmp_dir}/site"

    # Initialize a fresh repo with an orphan gh-pages branch
    git -C "${tmp_dir}" init -b gh-pages
    git -C "${tmp_dir}" remote add origin "$(git -C "${SUITE_ROOT}" remote get-url origin)"

    # Move site contents into the repo root
    mv "${tmp_dir}/site"/* "${tmp_dir}/"
    rmdir "${tmp_dir}/site"

    # Add a .nojekyll so GitHub serves raw HTML
    touch "${tmp_dir}/.nojekyll"

    # Commit everything
    git -C "${tmp_dir}" add -A
    git -C "${tmp_dir}" commit -m "Deploy docs ($(date +%Y-%m-%d))"

    # Force-push to gh-pages (replaces entire branch — always fresh)
    log_info "Force-pushing to origin/gh-pages..."
    git -C "${tmp_dir}" push --force origin gh-pages

    log_info "Documentation deployed to gh-pages."
    log_info "Contents:"
    log_info "  /xvector/          MkDocs + Doxygen API reference"
    log_info "  /xcompute/         MkDocs + Doxygen API reference"
}

# --- Main ---

main() {
    if ! command -v jq &>/dev/null; then
        log_error "jq is required but not installed. Install with: sudo apt install jq"
        exit 1
    fi

    if [[ $# -lt 1 ]]; then
        interactive_menu
        exit 0
    fi

    local command="$1"
    shift

    case "${command}" in
        show)    verify_submodule_commits; cmd_show "$@" ;;
        build)   verify_submodule_commits; cmd_package "$@" ;;
        tag)     verify_submodule_commits; cmd_tag "$@" ;;
        bump)    cmd_bump "$@" ;;
        sync)    cmd_sync "$@" ;;
        publish) cmd_publish "$@" ;;
        -h|--help) usage; exit 0 ;;
        *)
            log_error "Unknown command: ${command}"
            usage
            exit 1
            ;;
    esac
}

main "$@"
