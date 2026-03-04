#!/bin/bash

set -uo pipefail

SUITE_ROOT="$(cd "$(dirname "$0")" && pwd)"
XVECTOR_DIR="${SUITE_ROOT}/xvector-dev"
XFAISS_DIR="${SUITE_ROOT}/xfaiss"
DIST_DIR="${SUITE_ROOT}/dist"
BUILD_DIR="${DIST_DIR}/build"
XVECTOR_SH="${XVECTOR_DIR}/scripts/xvector.sh"
PACKAGING_SH="${XVECTOR_DIR}/scripts/packaging.sh"
DOCS_SH="${XVECTOR_DIR}/scripts/docs.sh"

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

# --- Target resolver (centralized target → version_file / repo_dir mapping) ---

resolve_target() {
    local target="$1"
    case "${target}" in
        xvector)  _TARGET_VERSION_FILE="${XVECTOR_VERSION_FILE}"; _TARGET_REPO_DIR="${XVECTOR_DIR}" ;;
        xcompute) _TARGET_VERSION_FILE="${XCOMPUTE_VERSION_FILE}"; _TARGET_REPO_DIR="${XVECTOR_DIR}" ;;
        xfaiss)   _TARGET_VERSION_FILE="${XFAISS_VERSION_FILE}"; _TARGET_REPO_DIR="${XFAISS_DIR}" ;;
        *) log_error "Invalid target: ${target}"; exit 1 ;;
    esac
}

get_target_version() {
    resolve_target "$1"
    if [[ "$1" == "xfaiss" ]]; then
        read_xfaiss_version "${_TARGET_VERSION_FILE}"
    else
        read_version "${_TARGET_VERSION_FILE}"
    fi
}

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

# Validate target argument
validate_target() {
    local target="$1"
    case "${target}" in
        xvector|xcompute|xfaiss|all) return 0 ;;
        *) log_error "Invalid target: ${target}. Must be xvector, xcompute, xfaiss, or all."; exit 1 ;;
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

    resolve_target "${target}"
    local version_file="${_TARGET_VERSION_FILE}"

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

# --- build ---

_pkg_build_xvector() {
    if ! "${XVECTOR_SH}" build --release --clean; then
        log_error "xvector-dev build failed"
        exit 1
    fi
}

_pkg_build_docs() {
    # docs.sh must run AFTER xvector.sh build --clean, which wipes build/site/
    if ! "${DOCS_SH}" build; then
        log_error "Documentation build failed"
        exit 1
    fi
}

cmd_build() {
    local target="${1:-all}"
    validate_target "${target}"

    # Always start clean
    cmd_clean
    mkdir -p "${BUILD_DIR}"

    if [[ ! -x "${XVECTOR_SH}" ]]; then
        log_error "xvector.sh not found: ${XVECTOR_SH}"
        exit 1
    fi

    # Build step registry
    local steps=() step_funcs=()

    if [[ "${target}" == "all" || "${target}" == "xvector" || "${target}" == "xcompute" ]]; then
        steps+=("Build xvector-dev (clean release)");      step_funcs+=("_pkg_build_xvector")
        steps+=("Build documentation (Jekyll + Doxygen)"); step_funcs+=("_pkg_build_docs")
        steps+=("Create Debian packages");                 step_funcs+=("package_deb")
    fi
    if [[ "${target}" == "all" || "${target}" == "xcompute" ]]; then
        steps+=("Create xcompute examples tarball");       step_funcs+=("package_examples")
    fi
    if [[ "${target}" == "all" || "${target}" == "xfaiss" ]]; then
        steps+=("Create xfaiss source archive");           step_funcs+=("package_xfaiss")
    fi

    local total=${#steps[@]}

    _STEP_NUM=0
    _STEP_TIMES=()
    _STEP_NAMES=()
    _PACKAGE_START=$(date +%s)

    for i in "${!steps[@]}"; do
        step_begin "${total}" "${steps[$i]}"
        "${step_funcs[$i]}" || { log_error "${steps[$i]} failed"; exit 1; }
        step_end
    done

    # Print timing summary
    print_summary

    echo ""
    log_info "Artifacts in ${BUILD_DIR}/:"
    ls -lh "${BUILD_DIR}/"

    # Create distribution tarball when building all targets
    if [[ "${target}" == "all" ]]; then
        _build_dist_tarball
    fi
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

tag_validate() {
    local target="$1"

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

    # Verify artifact versions match current VERSION files
    tag_verify_artifact_versions "${target}"
}

tag_verify_artifact_versions() {
    local target="$1"
    local stale=0

    if [[ "${target}" == "all" || "${target}" == "xvector" || "${target}" == "xcompute" ]]; then
        get_target_version "xvector"
        local xv_ver="${_VERSION}"
        if ! ls "${BUILD_DIR}"/libxvector-dev*"${xv_ver}"* &>/dev/null; then
            log_error "No artifact matching xvector version ${xv_ver} in ${BUILD_DIR}/"
            stale=1
        fi
        get_target_version "xcompute"
        local xc_ver="${_VERSION}"
        if ! ls "${BUILD_DIR}"/libxcompute-dev*"${xc_ver}"* &>/dev/null; then
            log_error "No artifact matching xcompute version ${xc_ver} in ${BUILD_DIR}/"
            stale=1
        fi
    fi
    if [[ "${target}" == "all" || "${target}" == "xfaiss" ]]; then
        get_target_version "xfaiss"
        local xf_ver="${_VERSION}"
        if ! ls "${BUILD_DIR}"/xfaiss*"${xf_ver}"* &>/dev/null; then
            log_error "No artifact matching xfaiss version ${xf_ver} in ${BUILD_DIR}/"
            stale=1
        fi
    fi

    if [[ ${stale} -ne 0 ]]; then
        log_error "Build artifacts appear stale. Rebuild after version bump."
        exit 1
    fi
}

tag_create_release_dir() {
    local date_str suite_hash
    date_str=$(date +%Y%m%d)
    suite_hash=$(git -C "${SUITE_ROOT}" rev-parse --short=7 HEAD)
    _RELEASE_NAME="build-${date_str}-${suite_hash}"
    _RELEASE_DIR="${DIST_DIR}/${_RELEASE_NAME}"

    if [[ -d "${_RELEASE_DIR}" ]]; then
        log_error "Release directory already exists: ${_RELEASE_DIR}"
        exit 1
    fi

    cp -r "${BUILD_DIR}" "${_RELEASE_DIR}"
    log_info "Artifacts copied to ${_RELEASE_DIR}/"
}

tag_write_manifest() {
    local manifest="${_RELEASE_DIR}/manifest.json"
    local date_str
    date_str=$(date +%Y%m%d)

    _TAG_XV_HASH=$(get_git_hash "${XVECTOR_DIR}")
    _TAG_XF_HASH=$(get_git_hash "${XFAISS_DIR}")

    get_target_version "xvector";  _TAG_XV_VER="${_VERSION}"
    get_target_version "xcompute"; _TAG_XC_VER="${_VERSION}"
    get_target_version "xfaiss";   _TAG_XF_VER="${_VERSION}"

    jq -n \
        --arg suite_hash "$(git -C "${SUITE_ROOT}" rev-parse HEAD)" \
        --arg xv_hash "${_TAG_XV_HASH}" \
        --arg xf_hash "${_TAG_XF_HASH}" \
        --arg xv_ver "${_TAG_XV_VER}" \
        --arg xc_ver "${_TAG_XC_VER}" \
        --arg xf_ver "${_TAG_XF_VER}" \
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
    for f in "${_RELEASE_DIR}"/*; do
        [[ "$(basename "$f")" == "manifest.json" ]] && continue
        artifacts+=("$(basename "$f")")
    done
    local artifacts_json
    artifacts_json=$(printf '%s\n' "${artifacts[@]}" | jq -R . | jq -s .)
    jq --argjson arts "${artifacts_json}" '.artifacts = $arts' "${manifest}" > "${manifest}.tmp"
    mv "${manifest}.tmp" "${manifest}"

    log_info "Manifest written: ${manifest}"
}

tag_create_git_tags() {
    local target="$1"

    if [[ "${target}" == "all" || "${target}" == "xvector" || "${target}" == "xcompute" ]]; then
        tag_target "xvector"
        tag_target "xcompute"
    fi
    if [[ "${target}" == "all" || "${target}" == "xfaiss" ]]; then
        tag_target "xfaiss"
    fi
}

tag_commit_manifest() {
    local manifests_dir="${SUITE_ROOT}/manifests"
    local epoch date_str
    epoch=$(date +%s)
    date_str=$(date +%Y%m%d)
    mkdir -p "${manifests_dir}"
    cp "${_RELEASE_DIR}/manifest.json" "${manifests_dir}/manifest-${epoch}.json"
    git -C "${SUITE_ROOT}" add "manifests/manifest-${epoch}.json"
    git -C "${SUITE_ROOT}" commit -m "Add release manifest (xvector=${_TAG_XV_VER}, xcompute=${_TAG_XC_VER}, xfaiss=${_TAG_XF_VER})"
    log_info "Manifest committed: manifests/manifest-${epoch}.json"

    _SUITE_TAG="release-${epoch}"
    git -C "${SUITE_ROOT}" tag -a "${_SUITE_TAG}" -m "Release ${date_str} (xvector=${_TAG_XV_VER}, xcompute=${_TAG_XC_VER}, xfaiss=${_TAG_XF_VER})"
    log_info "Created tag: ${_SUITE_TAG} in xvector-suite"
}

tag_push_and_release() {
    echo ""
    log_info "Release: ${_RELEASE_NAME}"
    log_info "  suite         = $(git -C "${SUITE_ROOT}" rev-parse HEAD)"
    log_info "  xvector-dev   = ${_TAG_XV_HASH}"
    log_info "  xfaiss        = ${_TAG_XF_HASH}"
    echo ""
    ls -lh "${_RELEASE_DIR}/"

    echo ""
    log_info "Pushing tag ${_SUITE_TAG} to origin..."
    git -C "${SUITE_ROOT}" push origin HEAD "${_SUITE_TAG}"

    # Upload only the dist tarball and manifest
    get_target_version "xvector"
    local dist_tarball="${_RELEASE_DIR}/xvector-suite-${_VERSION}-dist.tar.gz"
    if [[ ! -f "${dist_tarball}" ]]; then
        log_error "Dist tarball not found: ${dist_tarball}"
        exit 1
    fi
    local release_files=("${dist_tarball}" "${_RELEASE_DIR}/manifest.json")

    local release_body
    release_body=$(cat <<GHEOF
## ${_SUITE_TAG}

| Component | Version | Commit |
|-----------|---------|--------|
| xvector | ${_TAG_XV_VER} | \`${_TAG_XV_HASH}\` |
| xcompute | ${_TAG_XC_VER} | \`${_TAG_XV_HASH}\` |
| xfaiss | ${_TAG_XF_VER} | \`${_TAG_XF_HASH}\` |

**Suite commit:** \`$(git -C "${SUITE_ROOT}" rev-parse HEAD)\`
GHEOF
)

    log_info "Creating GitHub Release ${_SUITE_TAG}..."
    if gh release create "${_SUITE_TAG}" \
        --title "${_SUITE_TAG}" \
        --notes "${release_body}" \
        "${release_files[@]}"; then
        log_info "GitHub Release created: ${_SUITE_TAG}"
    else
        log_warn "GitHub Release creation failed. You can create it manually with:"
        log_warn "  gh release create ${_SUITE_TAG} ${_RELEASE_DIR}/*"
    fi
}

tag_target() {
    local target="$1"
    resolve_target "${target}"
    local version_file="${_TARGET_VERSION_FILE}"
    local repo_dir="${_TARGET_REPO_DIR}"

    read_version "${version_file}"
    local tag_name="${target}-v${_VERSION}"

    if git -C "${repo_dir}" tag -l "${tag_name}" | grep -q "${tag_name}"; then
        log_warn "Tag ${tag_name} already exists in $(basename "${repo_dir}"), skipping"
        return
    fi

    git -C "${repo_dir}" tag -a "${tag_name}" -m "Release ${target} ${_VERSION}"
    log_info "Created tag: ${tag_name} in $(basename "${repo_dir}")"
}

cmd_release() {
    local target="${1:-all}"
    validate_target "${target}"

    tag_validate "${target}"
    cmd_build "all"
    tag_create_release_dir
    tag_write_manifest
    tag_create_git_tags "${target}"
    tag_commit_manifest
    tag_push_and_release

    # Rebuild docs now that the release tag and GitHub Release exist,
    # so download links in Getting Started point to the correct release.
    log_info "Rebuilding documentation with new release tag..."
    _pkg_build_docs
    cmd_publish
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

# --- clean ---

cmd_clean() {
    if [[ -d "${BUILD_DIR}" ]]; then
        rm -rf "${BUILD_DIR}"
        log_info "Removed ${BUILD_DIR}"
    else
        log_info "Nothing to clean"
    fi
}

# --- dist (internal helper, called from cmd_build when target=all) ---

_build_dist_tarball() {
    read_version "${XVECTOR_VERSION_FILE}"
    local xv_ver="${_VERSION}"

    read_version "${XCOMPUTE_VERSION_FILE}"
    local xc_ver="${_VERSION}"

    read_xfaiss_version "${XFAISS_VERSION_FILE}"
    local xf_ver="${_VERSION}"
    local upstream_short="${_UPSTREAM#faiss-}"

    local deb_xvector="libxvector-dev_${xv_ver}_amd64.deb"
    local deb_xcompute="libxcompute-dev_${xc_ver}_amd64.deb"
    local tar_xfaiss="xfaiss-${xf_ver}+faiss${upstream_short}-source.tar.gz"
    local tar_examples="xcompute-examples-${xc_ver}.tar.gz"

    # Validate artifacts
    local missing=0
    for artifact in "${deb_xvector}" "${deb_xcompute}" "${tar_xfaiss}" \
                    "${tar_examples}"; do
        if [[ ! -f "${BUILD_DIR}/${artifact}" ]]; then
            log_error "Missing artifact: ${BUILD_DIR}/${artifact}"
            missing=1
        fi
    done
    if [[ ${missing} -ne 0 ]]; then
        log_error "Build artifacts incomplete; dist tarball not created."
        return 1
    fi

    # Validate setup.sh
    if [[ ! -f "${SUITE_ROOT}/installer/setup.sh" ]]; then
        log_error "setup.sh not found at ${SUITE_ROOT}/installer/setup.sh"
        return 1
    fi

    local suite_name="xvector-suite-${xv_ver}"
    local tarball_name="${suite_name}-dist.tar.gz"

    local temp_dir
    temp_dir=$(mktemp -d)
    local staging_dir="${temp_dir}/${suite_name}"
    mkdir -p "${staging_dir}"

    # Copy artifacts and setup.sh into staging directory
    cp "${BUILD_DIR}/${deb_xvector}"       "${staging_dir}/"
    cp "${BUILD_DIR}/${deb_xcompute}"      "${staging_dir}/"
    cp "${BUILD_DIR}/${tar_xfaiss}"        "${staging_dir}/"
    cp "${BUILD_DIR}/${tar_examples}"      "${staging_dir}/"
    cp "${SUITE_ROOT}/installer/setup.sh"   "${staging_dir}/"
    chmod +x "${staging_dir}/setup.sh"

    # Create distribution tarball
    tar -czf "${BUILD_DIR}/${tarball_name}" -C "${temp_dir}" "${suite_name}"
    rm -rf "${temp_dir}"

    local tarball_path="${BUILD_DIR}/${tarball_name}"
    local tarball_size
    tarball_size=$(du -sh "${tarball_path}" | cut -f1)
    log_info "Created dist tarball: ${tarball_path} (${tarball_size})"
}

# --- status ---

cmd_status() {
    echo ""
    echo -e "\033[1;36m  xvector-suite status\033[0m"
    echo ""

    # Suite dirty state
    if git -C "${SUITE_ROOT}" diff --quiet HEAD 2>/dev/null; then
        echo "  Suite repo:     clean"
    else
        echo -e "  Suite repo:     \033[0;33mdirty\033[0m"
    fi

    # Submodule alignment
    local expected_xv actual_xv expected_xf actual_xf
    expected_xv=$(get_expected_hash "xvector-dev")
    actual_xv=$(git -C "${XVECTOR_DIR}" rev-parse HEAD 2>/dev/null)
    expected_xf=$(get_expected_hash "xfaiss")
    actual_xf=$(git -C "${XFAISS_DIR}" rev-parse HEAD 2>/dev/null)

    if [[ "${expected_xv}" == "${actual_xv}" ]]; then
        echo "  xvector-dev:    ok (${actual_xv:0:7})"
    else
        echo -e "  xvector-dev:    \033[0;31mMISMATCH\033[0m expected=${expected_xv:0:7} actual=${actual_xv:0:7}"
    fi
    if [[ "${expected_xf}" == "${actual_xf}" ]]; then
        echo "  xfaiss:         ok (${actual_xf:0:7})"
    else
        echo -e "  xfaiss:         \033[0;31mMISMATCH\033[0m expected=${expected_xf:0:7} actual=${actual_xf:0:7}"
    fi

    # Versions with tag existence
    echo ""
    for t in xvector xcompute xfaiss; do
        get_target_version "${t}"
        local tag_name="${t}-v${_VERSION}"
        local tag_status
        if git -C "${_TARGET_REPO_DIR}" tag -l "${tag_name}" | grep -q "${tag_name}"; then
            tag_status="tagged"
        else
            tag_status="untagged"
        fi
        printf "  %-12s v%-10s %s\n" "${t}" "${_VERSION}" "${tag_status}"
    done

    # Build artifacts
    echo ""
    if [[ -d "${BUILD_DIR}" ]]; then
        local artifact_count
        artifact_count=$(find "${BUILD_DIR}" -maxdepth 1 -type f | wc -l)
        echo "  Build artifacts: ${artifact_count} file(s) in ${BUILD_DIR}/"
    else
        echo "  Build artifacts: none"
    fi

    # Release directories
    local release_count
    release_count=$(find "${DIST_DIR}" -maxdepth 1 -name 'build-*' -type d 2>/dev/null | wc -l)
    echo "  Releases:        ${release_count} directory(ies) in ${DIST_DIR}/"
    echo ""
}

# --- publish (gh-pages) ---

cmd_publish() {
    local site_dir="${XVECTOR_DIR}/build/site/xvector-suite"

    if [[ ! -d "${site_dir}/xvector" ]] || [[ ! -d "${site_dir}/xcompute" ]]; then
        log_error "Documentation not found in ${site_dir}."
        log_error "Run './package.sh build' first (includes docs build)."
        exit 1
    fi

    log_info "Deploying documentation to gh-pages..."

    # Work in a temporary directory to avoid touching the working tree
    local tmp_dir
    tmp_dir=$(mktemp -d)

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

    # Clean up
    rm -rf "${tmp_dir}"

    log_info "Documentation deployed to gh-pages."
    log_info "Contents:"
    log_info "  /xvector/          Jekyll + Doxygen API reference"
    log_info "  /xcompute/         Jekyll + Doxygen API reference"
}

# --- Usage ---

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [options]

Packaging and release management for xvector-suite.
Version is managed in each submodule's VERSION file (pure semver).

Commands:
  status             Show repo state, versions, build artifacts
  sync               Fetch latest submodule commits and commit references
  build [target]     Build artifacts + dist tarball into dist/build/
  bump <target> <type>
                     Bump version (major, minor, patch)
                     Targets: xvector, xcompute, xfaiss
  release [target]   Build + tag + GitHub Release
  publish            Publish documentation to gh-pages
  clean              Remove build artifacts (dist/build/)

Targets:
  xvector    libxvector-dev .deb package
  xcompute   libxcompute-dev .deb package / examples
  xfaiss     xfaiss source tarball
  all        All targets (default)

Examples:
    $(basename "$0") status
    $(basename "$0") build
    $(basename "$0") build xfaiss
    $(basename "$0") release all
    $(basename "$0") bump xvector patch   # 0.1.0 -> 0.1.1
    $(basename "$0") bump xfaiss minor    # 0.1.0 -> 0.2.0 (preserves upstream= line)
    $(basename "$0") sync                 # Update submodules to latest remote
    $(basename "$0") publish              # Publish docs to gh-pages
    $(basename "$0") clean                # Remove build artifacts
EOF
}

# --- Interactive menu ---

interactive_menu() {
    echo ""
    echo -e "\033[1;36m  xvector-suite packaging\033[0m"
    echo ""
    echo "  1) status    Show repo state, versions, artifacts"
    echo "  2) sync      Fetch & update submodules"
    echo "  3) build     Build all artifacts + dist tarball"
    echo "  4) bump      Bump a version"
    echo "  5) release   Build + tag + GitHub Release"
    echo "  6) publish   Publish docs to gh-pages"
    echo ""
    echo "  c) clean     Remove build artifacts"
    echo "  h) help      q) quit"
    echo ""

    local choice
    read -rp "  Select [1-6, c, h, q]: " choice

    case "${choice}" in
        1) cmd_status ;;
        2) cmd_sync ;;
        3) interactive_build ;;
        4) interactive_bump ;;
        5) verify_submodule_commits; interactive_release ;;
        6) cmd_publish ;;
        c) cmd_clean ;;
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
    cmd_build "all"
}

interactive_release() {
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

    cmd_release "${target}"
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
        status)  cmd_status "$@" ;;
        build)   verify_submodule_commits; cmd_build "$@" ;;
        release) verify_submodule_commits; cmd_release "$@" ;;
        bump)    cmd_bump "$@" ;;
        sync)    cmd_sync "$@" ;;
        publish) cmd_publish "$@" ;;
        clean)   cmd_clean "$@" ;;
        -h|--help) usage; exit 0 ;;
        *)
            log_error "Unknown command: ${command}"
            usage
            exit 1
            ;;
    esac
}

main "$@"
