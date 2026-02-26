#!/bin/bash

set -uo pipefail

SUITE_ROOT="$(cd "$(dirname "$0")" && pwd)"
XVECTOR_DIR="${SUITE_ROOT}/xvector-dev"
XFAISS_DIR="${SUITE_ROOT}/xfaiss"
PACKAGES_DIR="${SUITE_ROOT}/packages"
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
    echo -e "\033[1;35m║  Packaging Summary                                                  ║\033[0m"
    echo -e "\033[1;35m╠══════════════════════════════════════════════════════════════════════╣\033[0m"
    for i in "${!_STEP_NAMES[@]}"; do
        local dur
        dur=$(format_duration "${_STEP_TIMES[$i]}")
        printf "\033[1;35m║\033[0m  [%d/%d] %-52s %8s \033[1;35m║\033[0m\n" \
            $((i + 1)) "${_STEP_TOTAL}" "${_STEP_NAMES[$i]}" "${dur}"
    done
    echo -e "\033[1;35m╠══════════════════════════════════════════════════════════════════════╣\033[0m"
    printf "\033[1;35m║\033[0m  %-52s \033[1;33m%8s\033[0m \033[1;35m║\033[0m\n" \
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

    log_info "Submodule commits verified (xvector-dev=${actual_xvector:0:7}, xfaiss=${actual_xfaiss:0:7})"
}

# Check if local submodule HEAD matches remote branch HEAD (warning only)
check_remote_freshness() {
    log_info "Checking remote freshness..."
    local has_warning=0

    local local_hash remote_hash

    # xvector-dev
    local_hash=$(git -C "${XVECTOR_DIR}" rev-parse HEAD 2>/dev/null)
    remote_hash=$(git -C "${XVECTOR_DIR}" ls-remote origin "refs/heads/${XVECTOR_DEFAULT_BRANCH}" 2>/dev/null | awk '{print $1}')
    if [[ -z "${remote_hash}" ]]; then
        log_warn "xvector-dev: could not reach remote (offline?)"
        has_warning=1
    elif [[ "${local_hash}" != "${remote_hash}" ]]; then
        log_warn "xvector-dev is behind origin/${XVECTOR_DEFAULT_BRANCH}:"
        log_warn "  local:  ${local_hash:0:12}"
        log_warn "  remote: ${remote_hash:0:12}"
        has_warning=1
    else
        log_info "xvector-dev: up to date with origin/${XVECTOR_DEFAULT_BRANCH} (${local_hash:0:7})"
    fi

    # xfaiss
    local_hash=$(git -C "${XFAISS_DIR}" rev-parse HEAD 2>/dev/null)
    remote_hash=$(git -C "${XFAISS_DIR}" ls-remote origin "refs/heads/${XFAISS_DEFAULT_BRANCH}" 2>/dev/null | awk '{print $1}')
    if [[ -z "${remote_hash}" ]]; then
        log_warn "xfaiss: could not reach remote (offline?)"
        has_warning=1
    elif [[ "${local_hash}" != "${remote_hash}" ]]; then
        log_warn "xfaiss is behind origin/${XFAISS_DEFAULT_BRANCH}:"
        log_warn "  local:  ${local_hash:0:12}"
        log_warn "  remote: ${remote_hash:0:12}"
        has_warning=1
    else
        log_info "xfaiss: up to date with origin/${XFAISS_DEFAULT_BRANCH} (${local_hash:0:7})"
    fi

    if [[ ${has_warning} -ne 0 ]]; then
        log_warn "Some submodules may not be at the latest remote commit."
        log_warn "Consider running 'git pull' in the submodule(s) before packaging."
    fi
    echo ""
}

# --- Manifest helpers ---

MANIFEST_FILE="${PACKAGES_DIR}/manifest.json"

# Get full git hash for a repo
get_git_hash() {
    local repo_dir="$1"
    git -C "${repo_dir}" rev-parse HEAD
}

# Check manifest for version+hash conflict
# If same version exists with a different hash → error (must bump VERSION in submodule)
check_manifest_conflict() {
    local target="$1"
    local version="$2"
    local git_hash="$3"

    if [[ ! -f "${MANIFEST_FILE}" ]]; then
        return 0
    fi

    local existing_hash
    existing_hash=$(jq -r --arg t "${target}" --arg v "${version}" \
        '(.[$t] // [])[] | select(.version == $v) | .git_hash' \
        "${MANIFEST_FILE}")

    if [[ -z "${existing_hash}" ]]; then
        return 0
    fi

    if [[ "${existing_hash}" == "${git_hash}" ]]; then
        return 0
    fi

    log_error "Version ${version} for ${target} was already built from a different source (${existing_hash})."
    log_error "Current source is ${git_hash}. Bump the VERSION in the submodule first."
    exit 1
}

# Record build entry in manifest.json
record_manifest() {
    local target="$1"
    local version="$2"
    local git_hash="$3"
    local artifact="$4"

    if [[ ! -f "${MANIFEST_FILE}" ]]; then
        echo '{}' > "${MANIFEST_FILE}"
    fi

    local timestamp
    timestamp=$(date +%s)

    local new_entry
    new_entry=$(jq -n --arg v "${version}" --arg h "${git_hash}" \
        --arg a "${artifact}" --argjson ts "${timestamp}" \
        '{version:$v, git_hash:$h, artifact:$a, timestamp:$ts}')

    local updated
    updated=$(jq --arg t "${target}" --arg v "${version}" --argjson entry "${new_entry}" '
        if .[$t] == null then .[$t] = [] else . end
        | if ([.[$t][] | select(.version == $v)] | length) > 0
          then .[$t] = [.[$t][] | if .version == $v then $entry else . end]
          else .[$t] += [$entry]
          end
    ' "${MANIFEST_FILE}")

    echo "${updated}" > "${MANIFEST_FILE}"
    log_info "Recorded ${target} ${version} (${git_hash}) in manifest"
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

    # Show submodule commit hashes for deployer review
    log_info "Submodule commit hashes:"
    echo "  xfaiss      $(git -C "${XFAISS_DIR}" rev-parse HEAD)  ($(get_current_branch "${XFAISS_DIR}"))"
    echo "  xvector-dev $(git -C "${XVECTOR_DIR}" rev-parse HEAD)  ($(get_current_branch "${XVECTOR_DIR}"))"
    echo ""

    # Check against remote (warning only, not blocking)
    check_remote_freshness

    read -rp "Proceed with packaging? [y/N] " confirm
    if [[ "${confirm}" != [yY] ]]; then
        log_info "Aborted."
        exit 0
    fi

    mkdir -p "${PACKAGES_DIR}"

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
    log_info "Artifacts in ${PACKAGES_DIR}/:"
    ls -lh "${PACKAGES_DIR}/"
}

package_deb() {
    read_version "${XVECTOR_VERSION_FILE}"
    local xvector_version="${_VERSION}"
    read_version "${XCOMPUTE_VERSION_FILE}"
    local xcompute_version="${_VERSION}"

    local git_hash
    git_hash=$(get_git_hash "${XVECTOR_DIR}")
    check_manifest_conflict "xvector" "${xvector_version}" "${git_hash}"
    check_manifest_conflict "xcompute" "${xcompute_version}" "${git_hash}"

    log_info "Creating Debian packages..."
    if ! "${PACKAGING_SH}" deb --output "${PACKAGES_DIR}"; then
        log_error "Debian package creation failed"
        exit 1
    fi

    local xvector_deb="libxvector-dev_${xvector_version}_amd64.deb"
    local xcompute_deb="libxcompute-dev_${xcompute_version}_amd64.deb"
    record_manifest "xvector" "${xvector_version}" "${git_hash}" "${xvector_deb}"
    record_manifest "xcompute" "${xcompute_version}" "${git_hash}" "${xcompute_deb}"
}

package_examples() {
    read_version "${XCOMPUTE_VERSION_FILE}"
    local version="${_VERSION}"

    local git_hash
    git_hash=$(get_git_hash "${XVECTOR_DIR}")

    local tarball_name="xcompute-examples-${version}.tar.gz"
    check_manifest_conflict "xcompute-examples" "${version}" "${git_hash}"

    log_info "Creating xcompute examples tarball..."
    if ! "${PACKAGING_SH}" examples --output "${PACKAGES_DIR}"; then
        log_error "Examples tarball creation failed"
        exit 1
    fi

    record_manifest "xcompute-examples" "${version}" "${git_hash}" "${tarball_name}"
}

package_xfaiss() {
    read_xfaiss_version "${XFAISS_VERSION_FILE}"
    local version="${_VERSION}"
    local upstream_short="${_UPSTREAM#faiss-}"
    local tarball_name="xfaiss-${version}+faiss${upstream_short}-source.tar.gz"

    local git_hash
    git_hash=$(get_git_hash "${XFAISS_DIR}")
    check_manifest_conflict "xfaiss" "${version}" "${git_hash}"

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
    tar -czf "${PACKAGES_DIR}/${tarball_name}" -C "${temp_dir}" "xfaiss-${version}"
    rm -rf "${temp_dir}"

    log_info "Created: ${tarball_name}"
    record_manifest "xfaiss" "${version}" "${git_hash}" "${tarball_name}"
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

    if [[ "${target}" == "all" || "${target}" == "xvector" ]]; then
        tag_target "xvector"
    fi
    if [[ "${target}" == "all" || "${target}" == "xcompute" ]]; then
        tag_target "xcompute"
    fi
    if [[ "${target}" == "all" || "${target}" == "xfaiss" ]]; then
        tag_target "xfaiss"
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

    local git_hash
    git_hash=$(get_git_hash "${XVECTOR_DIR}")

    if [[ ! -d "${site_dir}" ]]; then
        log_error "Documentation not found: ${site_dir}"
        exit 1
    fi

    log_info "Packaging xvector ${version} documentation..."
    tar -czf "${PACKAGES_DIR}/${tarball_name}" -C "${XVECTOR_DIR}/build/site" "xvector"
    log_info "Created: ${tarball_name}"
    record_manifest "xvector-docs" "${version}" "${git_hash}" "${tarball_name}"
}

docs_xcompute() {
    read_version "${XCOMPUTE_VERSION_FILE}"
    local version="${_VERSION}"
    local site_dir="${XVECTOR_DIR}/build/site/xcompute"
    local tarball_name="xcompute-docs_${version}.tar.gz"

    local git_hash
    git_hash=$(get_git_hash "${XVECTOR_DIR}")

    if [[ ! -d "${site_dir}" ]]; then
        log_error "Documentation not found: ${site_dir}"
        exit 1
    fi

    log_info "Packaging xcompute ${version} documentation..."
    tar -czf "${PACKAGES_DIR}/${tarball_name}" -C "${XVECTOR_DIR}/build/site" "xcompute"
    log_info "Created: ${tarball_name}"
    record_manifest "xcompute-docs" "${version}" "${git_hash}" "${tarball_name}"
}


# --- Usage ---

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [options]

Packaging and release management for xvector-suite.
Version is managed in each submodule's VERSION file (pure semver).

Commands:
  show [target]      Show version(s)
  build [target]     Build and package artifact(s), generate and bundle docs
                     Records build in packages/manifest.json (requires jq)
                     Documentation generated via 'xvector.sh docs build'
  tag [target]       Create git tag(s)
  bump <target> <type>
                     Bump version (major, minor, patch)
                     Targets: xvector, xcompute, xfaiss

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
EOF
}

# --- Main ---

main() {
    if [[ $# -lt 1 ]]; then
        usage
        exit 1
    fi

    if ! command -v jq &>/dev/null; then
        log_error "jq is required but not installed. Install with: sudo apt install jq"
        exit 1
    fi

    local command="$1"
    shift

    case "${command}" in
        show)    verify_submodule_commits; cmd_show "$@" ;;
        build)   verify_submodule_commits; cmd_package "$@" ;;
        tag)     verify_submodule_commits; cmd_tag "$@" ;;
        bump)    cmd_bump "$@" ;;
        -h|--help) usage; exit 0 ;;
        *)
            log_error "Unknown command: ${command}"
            usage
            exit 1
            ;;
    esac
}

main "$@"
