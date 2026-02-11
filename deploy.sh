#!/bin/bash

set -uo pipefail

SUITE_ROOT="$(cd "$(dirname "$0")" && pwd)"
XVECTOR_DIR="${SUITE_ROOT}/xvector-dev"
XFAISS_DIR="${SUITE_ROOT}/xfaiss"
PACKAGES_DIR="${SUITE_ROOT}/packages"

# Deploy branch configuration
XVECTOR_DEPLOY_BRANCH="main"
XFAISS_DEPLOY_BRANCH="faiss-1.13.0-xcena"

# VERSION file paths
XVECTOR_VERSION_FILE="${XVECTOR_DIR}/VERSION"
XCOMPUTE_VERSION_FILE="${XVECTOR_DIR}/VERSION_XCOMPUTE"
XFAISS_VERSION_FILE="${XFAISS_DIR}/VERSION"

# --- Logging (self-contained, no submodule dependency) ---
log_info()  { echo -e "\033[0;32m[INFO]\033[0m  $*"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }
log_warn()  { echo -e "\033[0;33m[WARN]\033[0m  $*"; }

# --- Submodule branch verification ---

# Get current branch name for a git repo
get_current_branch() {
    local repo_dir="$1"
    git -C "${repo_dir}" rev-parse --abbrev-ref HEAD 2>/dev/null
}

# Verify submodules are on their deploy branches
verify_deploy_branches() {
    local failed=0

    local xvector_branch
    xvector_branch=$(get_current_branch "${XVECTOR_DIR}")
    if [[ "${xvector_branch}" != "${XVECTOR_DEPLOY_BRANCH}" ]]; then
        log_error "xvector-dev is on branch '${xvector_branch}', expected '${XVECTOR_DEPLOY_BRANCH}'"
        failed=1
    fi

    local xfaiss_branch
    xfaiss_branch=$(get_current_branch "${XFAISS_DIR}")
    if [[ "${xfaiss_branch}" != "${XFAISS_DEPLOY_BRANCH}" ]]; then
        log_error "xfaiss is on branch '${xfaiss_branch}', expected '${XFAISS_DEPLOY_BRANCH}'"
        failed=1
    fi

    if [[ ${failed} -ne 0 ]]; then
        log_error "Submodule branch mismatch. Please checkout the correct deploy branches."
        log_info "  cd xvector-dev && git checkout ${XVECTOR_DEPLOY_BRANCH}"
        log_info "  cd xfaiss     && git checkout ${XFAISS_DEPLOY_BRANCH}"
        exit 1
    fi

    log_info "Deploy branches verified (xvector-dev=${xvector_branch}, xfaiss=${xfaiss_branch})"
}

# --- Manifest helpers ---

MANIFEST_FILE="${PACKAGES_DIR}/manifest.json"

# Get short git hash for a repo
get_git_hash() {
    local repo_dir="$1"
    git -C "${repo_dir}" rev-parse --short HEAD
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
        echo "xvector    ${_VERSION}"
    fi
    if [[ "${target}" == "all" || "${target}" == "xcompute" ]]; then
        read_version "${XCOMPUTE_VERSION_FILE}"
        echo "xcompute   ${_VERSION}"
    fi
    if [[ "${target}" == "all" || "${target}" == "xfaiss" ]]; then
        read_xfaiss_version "${XFAISS_VERSION_FILE}"
        echo "xfaiss     ${_VERSION} (upstream=${_UPSTREAM})"
    fi
}

# --- package ---

cmd_package() {
    local target="${1:-all}"
    validate_target "${target}"

    mkdir -p "${PACKAGES_DIR}"

    # Build xvector-dev once if packaging xvector or xcompute
    if [[ "${target}" == "all" || "${target}" == "xvector" || "${target}" == "xcompute" ]]; then
        package_build_xvector_dev
    fi

    if [[ "${target}" == "all" || "${target}" == "xvector" ]]; then
        package_xvector
    fi
    if [[ "${target}" == "all" || "${target}" == "xcompute" ]]; then
        package_xcompute
    fi
    if [[ "${target}" == "all" || "${target}" == "xfaiss" ]]; then
        package_xfaiss
    fi

    # Generate documentation (optional — skipped if doxygen is not installed)
    if command -v doxygen &>/dev/null; then
        if [[ "${target}" == "all" || "${target}" == "xvector" ]]; then
            docs_xvector
        fi
        if [[ "${target}" == "all" || "${target}" == "xcompute" ]]; then
            docs_xcompute
        fi
    else
        log_warn "doxygen not found — skipping documentation. Install with: sudo apt install doxygen graphviz"
    fi

    log_info ""
    log_info "Artifacts in ${PACKAGES_DIR}/:"
    ls -lh "${PACKAGES_DIR}/"
}

package_build_xvector_dev() {
    log_info "Building xvector-dev (clean release)..."
    if [[ ! -x "${XVECTOR_DIR}/scripts/build.sh" ]]; then
        log_error "build.sh not found: ${XVECTOR_DIR}/scripts/build.sh"
        exit 1
    fi
    if ! "${XVECTOR_DIR}/scripts/build.sh" --clean --release; then
        log_error "xvector-dev build failed"
        exit 1
    fi
}

package_xvector() {
    read_version "${XVECTOR_VERSION_FILE}"
    local version="${_VERSION}"
    local build_dir="${XVECTOR_DIR}/build/Release"
    local deb_name="libxvector-dev_${version}_amd64.deb"

    local git_hash
    git_hash=$(get_git_hash "${XVECTOR_DIR}")
    check_manifest_conflict "xvector" "${version}" "${git_hash}"

    if [[ ! -d "${build_dir}" ]]; then
        log_error "Build directory not found: ${build_dir}"
        exit 1
    fi

    log_info "Packaging ${deb_name}..."

    (
        cd "${build_dir}" || exit 1

        if ! cpack -G DEB \
            -D CPACK_COMPONENTS_ALL=xvector \
            -D CPACK_PACKAGING_INSTALL_PREFIX=/opt/xvector \
            -D CPACK_DEBIAN_XVECTOR_FILE_NAME="${deb_name}"; then
            log_error "Failed to generate libxvector-dev package"
            exit 1
        fi

        mv "${deb_name}" "${PACKAGES_DIR}/"
    )

    if [[ $? -ne 0 ]]; then
        exit 1
    fi

    log_info "Created: ${deb_name}"
    record_manifest "xvector" "${version}" "${git_hash}" "${deb_name}"
}

package_xcompute() {
    read_version "${XCOMPUTE_VERSION_FILE}"
    local version="${_VERSION}"
    local build_dir="${XVECTOR_DIR}/build/Release"
    local deb_name="libxcompute-dev_${version}_amd64.deb"

    local git_hash
    git_hash=$(get_git_hash "${XVECTOR_DIR}")
    check_manifest_conflict "xcompute" "${version}" "${git_hash}"

    if [[ ! -d "${build_dir}" ]]; then
        log_error "Build directory not found: ${build_dir}"
        exit 1
    fi

    log_info "Packaging ${deb_name}..."

    (
        cd "${build_dir}" || exit 1

        if ! cpack -G DEB \
            -D CPACK_COMPONENTS_ALL=xcompute \
            -D CPACK_PACKAGING_INSTALL_PREFIX=/opt/xcompute \
            -D CPACK_PACKAGE_VERSION="${version}" \
            -D CPACK_DEBIAN_XCOMPUTE_FILE_NAME="${deb_name}"; then
            log_error "Failed to generate libxcompute-dev package"
            exit 1
        fi

        mv "${deb_name}" "${PACKAGES_DIR}/"
    )

    if [[ $? -ne 0 ]]; then
        exit 1
    fi

    log_info "Created: ${deb_name}"
    record_manifest "xcompute" "${version}" "${git_hash}" "${deb_name}"
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

docs_xvector() {
    read_version "${XVECTOR_VERSION_FILE}"
    local version="${_VERSION}"
    local doc_dir="${XVECTOR_DIR}/docs/doxygen-public"
    local tarball_name="xvector-docs_${version}.tar.gz"

    local git_hash
    git_hash=$(get_git_hash "${XVECTOR_DIR}")

    log_info "Generating xvector ${version} documentation (public API)..."

    rm -rf "${doc_dir}"
    if ! doxygen "${XVECTOR_DIR}/Doxyfile.release"; then
        log_error "Doxygen failed for xvector"
        exit 1
    fi

    if [[ ! -d "${doc_dir}/html" ]]; then
        log_error "Documentation output not found: ${doc_dir}/html"
        exit 1
    fi

    tar -czf "${PACKAGES_DIR}/${tarball_name}" -C "${XVECTOR_DIR}/docs" "doxygen-public"
    log_info "Created: ${tarball_name}"
    record_manifest "xvector-docs" "${version}" "${git_hash}" "${tarball_name}"
}

docs_xcompute() {
    read_version "${XCOMPUTE_VERSION_FILE}"
    local version="${_VERSION}"
    local doc_dir="${XVECTOR_DIR}/docs/doxygen-xcompute"
    local tarball_name="xcompute-docs_${version}.tar.gz"

    local git_hash
    git_hash=$(get_git_hash "${XVECTOR_DIR}")

    log_info "Generating xcompute ${version} documentation..."

    rm -rf "${doc_dir}"
    if ! doxygen "${XVECTOR_DIR}/Doxyfile.xcompute"; then
        log_error "Doxygen failed for xcompute"
        exit 1
    fi

    if [[ ! -d "${doc_dir}/html" ]]; then
        log_error "Documentation output not found: ${doc_dir}/html"
        exit 1
    fi

    tar -czf "${PACKAGES_DIR}/${tarball_name}" -C "${XVECTOR_DIR}/docs" "doxygen-xcompute"
    log_info "Created: ${tarball_name}"
    record_manifest "xcompute-docs" "${version}" "${git_hash}" "${tarball_name}"
}


# --- Usage ---

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [options]

Unified deploy script for xvector-suite.
Version is managed in each submodule's VERSION file (pure semver).

Commands:
  show [target]      Show version(s)
  package [target]   Build and package artifact(s), generate docs
                     Records build in packages/manifest.json (requires jq)
                     Documentation requires doxygen and graphviz (optional)
  tag [target]       Create git tag(s)

Targets:
  xvector    libxvector-dev .deb package / API docs
  xcompute   libxcompute-dev .deb package / API docs
  xfaiss     xfaiss source tarball
  all        All targets (default)

Examples:
    $(basename "$0") show
    $(basename "$0") show xvector
    $(basename "$0") package
    $(basename "$0") package xfaiss
    $(basename "$0") tag all
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
        show)    verify_deploy_branches; cmd_show "$@" ;;
        package) verify_deploy_branches; cmd_package "$@" ;;
        tag)     verify_deploy_branches; cmd_tag "$@" ;;
        -h|--help) usage; exit 0 ;;
        *)
            log_error "Unknown command: ${command}"
            usage
            exit 1
            ;;
    esac
}

main "$@"
