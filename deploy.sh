#!/bin/bash

set -uo pipefail

SUITE_ROOT="$(cd "$(dirname "$0")" && pwd)"
XVECTOR_DIR="${SUITE_ROOT}/xvector-dev"
XFAISS_DIR="${SUITE_ROOT}/xfaiss"
PACKAGES_DIR="${SUITE_ROOT}/packages"

# VERSION file paths
XVECTOR_VERSION_FILE="${XVECTOR_DIR}/VERSION"
XCOMPUTE_VERSION_FILE="${XVECTOR_DIR}/VERSION_XCOMPUTE"
XFAISS_VERSION_FILE="${XFAISS_DIR}/VERSION"

# --- Logging (self-contained, no submodule dependency) ---
log_info()  { echo -e "\033[0;32m[INFO]\033[0m  $*"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }
log_warn()  { echo -e "\033[0;33m[WARN]\033[0m  $*"; }

# --- Version helpers ---

# Read version file → sets _BASE_VERSION, _REVISION
read_version() {
    local file="$1"
    if [[ ! -f "${file}" ]]; then
        log_error "VERSION file not found: ${file}"
        exit 1
    fi
    local first_line
    first_line=$(head -1 "${file}")
    _BASE_VERSION="${first_line%-*}"
    _REVISION="${first_line##*-}"
}

# Read xfaiss version → sets _BASE_VERSION, _REVISION, _UPSTREAM
read_xfaiss_version() {
    read_version "$1"
    _UPSTREAM=$(grep '^upstream=' "$1" 2>/dev/null | cut -d= -f2)
    _UPSTREAM="${_UPSTREAM:-unknown}"
}

# Write version file
write_version() {
    local file="$1"
    local base="$2"
    local rev="$3"
    local upstream="${4:-}"
    echo "${base}-${rev}" > "${file}"
    if [[ -n "${upstream}" ]]; then
        echo "upstream=${upstream}" >> "${file}"
    fi
}

# Get full version string (first line of VERSION file)
get_full_version() {
    head -1 "$1"
}

# Parse semver → sets MAJOR, MINOR, PATCH
parse_semver() {
    local version="$1"
    IFS='.' read -r MAJOR MINOR PATCH <<< "${version}"
    MAJOR=${MAJOR:-0}
    MINOR=${MINOR:-0}
    PATCH=${PATCH:-0}
}

# Bump semver → prints new base version
bump_semver() {
    local base="$1"
    local type="$2"
    parse_semver "${base}"
    case "${type}" in
        major) echo "$((MAJOR + 1)).0.0" ;;
        minor) echo "${MAJOR}.$((MINOR + 1)).0" ;;
        patch) echo "${MAJOR}.${MINOR}.$((PATCH + 1))" ;;
        *) log_error "Invalid bump type: ${type}. Must be major, minor, or patch."; exit 1 ;;
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

# Update xvector-dev/CMakeLists.txt project version
update_cmake_version() {
    local new_version="$1"
    local cmake_file="${XVECTOR_DIR}/CMakeLists.txt"
    if [[ ! -f "${cmake_file}" ]]; then
        log_error "CMakeLists.txt not found: ${cmake_file}"
        exit 1
    fi
    sed -i "s/\(project(xvector VERSION \)[0-9.]*\(.*\)/\1${new_version}\2/" "${cmake_file}"
    log_info "Updated CMakeLists.txt: project(xvector VERSION ${new_version})"
}

# --- show ---

cmd_show() {
    local target="${1:-all}"
    validate_target "${target}"

    if [[ "${target}" == "all" || "${target}" == "xvector" ]]; then
        read_version "${XVECTOR_VERSION_FILE}"
        echo "xvector    ${_BASE_VERSION}-${_REVISION}"
    fi
    if [[ "${target}" == "all" || "${target}" == "xcompute" ]]; then
        read_version "${XCOMPUTE_VERSION_FILE}"
        echo "xcompute   ${_BASE_VERSION}-${_REVISION}"
    fi
    if [[ "${target}" == "all" || "${target}" == "xfaiss" ]]; then
        read_xfaiss_version "${XFAISS_VERSION_FILE}"
        echo "xfaiss     ${_BASE_VERSION}-${_REVISION} (${_UPSTREAM})"
    fi
}

# --- bump ---

cmd_bump() {
    local bump_type="${1:-}"
    local target="${2:-}"

    if [[ -z "${bump_type}" || -z "${target}" ]]; then
        log_error "Usage: deploy.sh bump <major|minor|patch> <xvector|xcompute|xfaiss|all>"
        exit 1
    fi

    validate_target "${target}"

    if [[ "${target}" == "all" || "${target}" == "xvector" ]]; then
        bump_target "xvector" "${bump_type}"
    fi
    if [[ "${target}" == "all" || "${target}" == "xcompute" ]]; then
        bump_target "xcompute" "${bump_type}"
    fi
    if [[ "${target}" == "all" || "${target}" == "xfaiss" ]]; then
        bump_target "xfaiss" "${bump_type}"
    fi
}

bump_target() {
    local target="$1"
    local bump_type="$2"

    case "${target}" in
        xvector)
            read_version "${XVECTOR_VERSION_FILE}"
            local new_base
            new_base=$(bump_semver "${_BASE_VERSION}" "${bump_type}")
            write_version "${XVECTOR_VERSION_FILE}" "${new_base}" "1"
            update_cmake_version "${new_base}"
            log_info "xvector: ${_BASE_VERSION}-${_REVISION} -> ${new_base}-1"
            ;;
        xcompute)
            read_version "${XCOMPUTE_VERSION_FILE}"
            local new_base
            new_base=$(bump_semver "${_BASE_VERSION}" "${bump_type}")
            write_version "${XCOMPUTE_VERSION_FILE}" "${new_base}" "1"
            log_info "xcompute: ${_BASE_VERSION}-${_REVISION} -> ${new_base}-1"
            ;;
        xfaiss)
            read_xfaiss_version "${XFAISS_VERSION_FILE}"
            local new_base
            new_base=$(bump_semver "${_BASE_VERSION}" "${bump_type}")
            write_version "${XFAISS_VERSION_FILE}" "${new_base}" "1" "${_UPSTREAM}"
            log_info "xfaiss: ${_BASE_VERSION}-${_REVISION} -> ${new_base}-1"
            ;;
    esac
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
    local full_version="${_BASE_VERSION}-${_REVISION}"
    local build_dir="${XVECTOR_DIR}/build/Release"
    local deb_name="libxvector-dev_${full_version}_amd64.deb"

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
            -D CPACK_DEBIAN_PACKAGE_RELEASE="${_REVISION}" \
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

    # Increment revision
    _REVISION=$((_REVISION + 1))
    write_version "${XVECTOR_VERSION_FILE}" "${_BASE_VERSION}" "${_REVISION}"
    log_info "xvector revision -> ${_BASE_VERSION}-${_REVISION}"
}

package_xcompute() {
    read_version "${XCOMPUTE_VERSION_FILE}"
    local full_version="${_BASE_VERSION}-${_REVISION}"
    local build_dir="${XVECTOR_DIR}/build/Release"
    local deb_name="libxcompute-dev_${full_version}_amd64.deb"

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
            -D CPACK_PACKAGE_VERSION="${_BASE_VERSION}" \
            -D CPACK_DEBIAN_PACKAGE_RELEASE="${_REVISION}" \
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

    # Increment revision
    _REVISION=$((_REVISION + 1))
    write_version "${XCOMPUTE_VERSION_FILE}" "${_BASE_VERSION}" "${_REVISION}"
    log_info "xcompute revision -> ${_BASE_VERSION}-${_REVISION}"
}

package_xfaiss() {
    read_xfaiss_version "${XFAISS_VERSION_FILE}"
    local full_version="${_BASE_VERSION}-${_REVISION}"
    local upstream_short="${_UPSTREAM#faiss-}"
    local tarball_name="xfaiss-${full_version}+faiss${upstream_short}-source.tar.gz"

    log_info "Creating ${tarball_name}..."

    if [[ ! -e "${XFAISS_DIR}/.git" ]]; then
        log_error "xfaiss is not a git repository: ${XFAISS_DIR}"
        exit 1
    fi

    local temp_dir
    temp_dir=$(mktemp -d)
    local archive_dir="${temp_dir}/xfaiss-${full_version}"

    # Extract source via git archive (respects .gitattributes export-ignore)
    mkdir -p "${archive_dir}"
    git -C "${XFAISS_DIR}" archive --worktree-attributes HEAD | tar -x -C "${archive_dir}"

    # Insert VERSION file into tarball
    cp "${XFAISS_VERSION_FILE}" "${archive_dir}/VERSION"

    # Create tarball
    tar -czf "${PACKAGES_DIR}/${tarball_name}" -C "${temp_dir}" "xfaiss-${full_version}"
    rm -rf "${temp_dir}"

    log_info "Created: ${tarball_name}"

    # Increment revision
    _REVISION=$((_REVISION + 1))
    write_version "${XFAISS_VERSION_FILE}" "${_BASE_VERSION}" "${_REVISION}" "${_UPSTREAM}"
    log_info "xfaiss revision -> ${_BASE_VERSION}-${_REVISION}"
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

    local full_version
    full_version=$(get_full_version "${version_file}")
    local tag_name="${target}-v${full_version}"

    if git -C "${repo_dir}" tag -l "${tag_name}" | grep -q "${tag_name}"; then
        log_warn "Tag ${tag_name} already exists in $(basename "${repo_dir}"), skipping"
        return
    fi

    git -C "${repo_dir}" tag -a "${tag_name}" -m "Release ${target} ${full_version}"
    log_info "Created tag: ${tag_name} in $(basename "${repo_dir}")"
}

# --- Usage ---

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [options]

Unified deploy script for xvector-suite.

Commands:
  show [target]                      Show version(s)
  bump <major|minor|patch> <target>  Bump semver, reset revision to 1
  package [target]                   Build and package artifact(s), increment revision
  tag [target]                       Create git tag(s)

Targets:
  xvector    libxvector-dev .deb package
  xcompute   libxcompute-dev .deb package
  xfaiss     xfaiss source tarball
  all        All targets (default)

Examples:
    $(basename "$0") show
    $(basename "$0") show xvector
    $(basename "$0") bump patch xvector
    $(basename "$0") bump minor all
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

    local command="$1"
    shift

    case "${command}" in
        show)    cmd_show "$@" ;;
        bump)    cmd_bump "$@" ;;
        package) cmd_package "$@" ;;
        tag)     cmd_tag "$@" ;;
        -h|--help) usage; exit 0 ;;
        *)
            log_error "Unknown command: ${command}"
            usage
            exit 1
            ;;
    esac
}

main "$@"
