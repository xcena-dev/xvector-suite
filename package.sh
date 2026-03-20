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
XARITH_VERSION_FILE="${XVECTOR_DIR}/VERSION_XARITH"
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
        xvector)  _TARGET_VERSION_FILE="${XVECTOR_VERSION_FILE}" ;;
        xarith)   _TARGET_VERSION_FILE="${XARITH_VERSION_FILE}" ;;
        xfaiss)   _TARGET_VERSION_FILE="${XFAISS_VERSION_FILE}" ;;
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

# Get the commit hash that the parent repo expects for a submodule
get_expected_hash() {
    local submodule_path="$1"
    git -C "${SUITE_ROOT}" ls-tree HEAD -- "${submodule_path}" | awk '{print $3}'
}

# Verify submodules are at the commit hashes recorded in xvector-suite
verify_submodule_commits() {
    local failed=0
    local submodules=("xvector-dev:${XVECTOR_DIR}" "xfaiss:${XFAISS_DIR}")

    for entry in "${submodules[@]}"; do
        local name="${entry%%:*}" dir="${entry#*:}"
        local expected actual
        expected=$(get_expected_hash "${name}")
        actual=$(git -C "${dir}" rev-parse HEAD 2>/dev/null)
        if [[ "${actual}" != "${expected}" ]]; then
            log_error "${name} commit mismatch:"
            log_error "  expected: ${expected}"
            log_error "  actual:   ${actual}"
            failed=1
        fi
    done

    if [[ ${failed} -ne 0 ]]; then
        log_error "Submodule commit mismatch. Run 'git submodule update --init' to sync."
        exit 1
    fi

    log_info "Submodule commits verified"
    for entry in "${submodules[@]}"; do
        local name="${entry%%:*}" dir="${entry#*:}"
        log_info "  ${name} = $(git -C "${dir}" rev-parse HEAD)"
    done
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

# Validate target argument
validate_target() {
    local target="$1"
    case "${target}" in
        xvector|xarith|xfaiss|all) return 0 ;;
        *) log_error "Invalid target: ${target}. Must be xvector, xarith, xfaiss, or all."; exit 1 ;;
    esac
}

confirm_prompt() {
    local msg="$1"
    local answer
    echo ""
    read -rp "  ${msg} [y/N]: " answer
    case "${answer}" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
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

    verify_submodule_commits

    # Always start clean
    rm -rf "${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}"

    if [[ ! -x "${XVECTOR_SH}" ]]; then
        log_error "xvector.sh not found: ${XVECTOR_SH}"
        exit 1
    fi

    # Build step registry
    local steps=() step_funcs=()

    if [[ "${target}" == "all" || "${target}" == "xvector" || "${target}" == "xarith" ]]; then
        steps+=("Build xvector-dev (clean release)");      step_funcs+=("_pkg_build_xvector")
        steps+=("Create Debian packages");                 step_funcs+=("package_deb")
        steps+=("Create examples tarballs");               step_funcs+=("package_examples")
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
    log_info "Creating examples tarballs..."
    if ! "${PACKAGING_SH}" examples --output "${BUILD_DIR}"; then
        log_error "Examples tarballs creation failed"
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

# --- dist (internal helper, called from cmd_build when target=all) ---

_build_dist_tarball() {
    read_version "${XVECTOR_VERSION_FILE}"
    local xv_ver="${_VERSION}"

    read_version "${XARITH_VERSION_FILE}"
    local xc_ver="${_VERSION}"

    read_xfaiss_version "${XFAISS_VERSION_FILE}"
    local xf_ver="${_VERSION}"
    local upstream_short="${_UPSTREAM#faiss-}"

    local deb_xvector="libxvector-dev_${xv_ver}_amd64.deb"
    local deb_xarith="libxarith-dev_${xc_ver}_amd64.deb"
    local tar_xfaiss="xfaiss-${xf_ver}+faiss${upstream_short}-source.tar.gz"
    local tar_xarith_examples="xarith-examples-${xc_ver}.tar.gz"
    local tar_xvector_examples="xvector-examples-${xv_ver}.tar.gz"

    # Validate artifacts
    local missing=0
    for artifact in "${deb_xvector}" "${deb_xarith}" "${tar_xfaiss}" \
                    "${tar_xarith_examples}" "${tar_xvector_examples}"; do
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
    cp "${BUILD_DIR}/${deb_xvector}"           "${staging_dir}/"
    cp "${BUILD_DIR}/${deb_xarith}"          "${staging_dir}/"
    cp "${BUILD_DIR}/${tar_xfaiss}"            "${staging_dir}/"
    cp "${BUILD_DIR}/${tar_xarith_examples}"   "${staging_dir}/"
    cp "${BUILD_DIR}/${tar_xvector_examples}"  "${staging_dir}/"
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

# --- release prepare (local only) ---

tag_verify_artifact_versions() {
    local target="$1"
    local stale=0

    if [[ "${target}" == "all" || "${target}" == "xvector" || "${target}" == "xarith" ]]; then
        get_target_version "xvector"
        local xv_ver="${_VERSION}"
        if ! ls "${BUILD_DIR}"/libxvector-dev*"${xv_ver}"* &>/dev/null; then
            log_error "No artifact matching xvector version ${xv_ver} in ${BUILD_DIR}/"
            stale=1
        fi
        get_target_version "xarith"
        local xc_ver="${_VERSION}"
        if ! ls "${BUILD_DIR}"/libxarith-dev*"${xc_ver}"* &>/dev/null; then
            log_error "No artifact matching xarith version ${xc_ver} in ${BUILD_DIR}/"
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
        log_error "Build artifacts appear stale. Please rebuild."
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
        log_warn "Overwriting existing release directory: ${_RELEASE_DIR}"
        rm -rf "${_RELEASE_DIR}"
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
    get_target_version "xarith"; _TAG_XC_VER="${_VERSION}"
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
            xarith: { version: $xc_ver, git_hash: $xv_hash },
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

tag_commit_manifest() {
    local manifests_dir="${SUITE_ROOT}/manifests"
    local epoch date_str
    epoch=$(date +%s)
    date_str=$(date +%Y%m%d)
    mkdir -p "${manifests_dir}"
    cp "${_RELEASE_DIR}/manifest.json" "${manifests_dir}/manifest-${epoch}.json"
    git -C "${SUITE_ROOT}" add "manifests/manifest-${epoch}.json"
    git -C "${SUITE_ROOT}" commit -m "Add release manifest (xvector=${_TAG_XV_VER}, xarith=${_TAG_XC_VER}, xfaiss=${_TAG_XF_VER})"
    log_info "Manifest committed: manifests/manifest-${epoch}.json"

    _SUITE_TAG="release-${epoch}"
    git -C "${SUITE_ROOT}" tag -a "${_SUITE_TAG}" -m "Release ${date_str} (xvector=${_TAG_XV_VER}, xarith=${_TAG_XC_VER}, xfaiss=${_TAG_XF_VER})"
    log_info "Created tag: ${_SUITE_TAG} in xvector-suite"
}

cmd_release_prepare() {
    local target="${1:-all}"
    validate_target "${target}"

    verify_submodule_commits

    # Verify build artifacts exist (build must be done beforehand)
    if [[ ! -d "${BUILD_DIR}" ]] || [[ -z "$(ls -A "${BUILD_DIR}" 2>/dev/null)" ]]; then
        log_error "No build artifacts found in ${BUILD_DIR}/."
        log_error "Run './package.sh build' first."
        exit 1
    fi

    tag_verify_artifact_versions "${target}"
    log_info "Build artifacts verified."

    # Prepare release directory and manifest
    tag_create_release_dir
    tag_write_manifest

    # Show release summary
    echo ""
    log_info "Release: ${_RELEASE_NAME}"
    log_info "  xvector  = v${_TAG_XV_VER}  (${_TAG_XV_HASH})"
    log_info "  xarith = v${_TAG_XC_VER}  (${_TAG_XV_HASH})"
    log_info "  xfaiss   = v${_TAG_XF_VER}  (${_TAG_XF_HASH})"
    echo ""
    ls -lh "${_RELEASE_DIR}/"

    # Commit manifest and create suite tag
    if ! confirm_prompt "Commit manifest and create suite tag?"; then
        log_warn "Manifest commit skipped. Release directory preserved at ${_RELEASE_DIR}/"
        return 0
    fi
    tag_commit_manifest

    echo ""
    log_info "Release prepared locally."
    log_info "  Tag:       ${_SUITE_TAG}"
    log_info "  Artifacts: ${_RELEASE_DIR}/"
    echo ""
    log_info "Next steps:"
    log_info "  ./package.sh release publish          # push tag + create GitHub Release"
    log_info "  ./package.sh docs build ${_SUITE_TAG}  # build docs with this release tag"
}

# --- release publish (remote) ---

# Load release state from the most recent prepared release directory
_load_release_state() {
    _RELEASE_DIR=$(find "${DIST_DIR}" -maxdepth 1 -name 'build-*' -type d 2>/dev/null | sort -r | head -1)
    if [[ -z "${_RELEASE_DIR}" ]] || [[ ! -f "${_RELEASE_DIR}/manifest.json" ]]; then
        log_error "No prepared release found in ${DIST_DIR}/."
        log_error "Run './package.sh release prepare' first."
        exit 1
    fi
    _RELEASE_NAME=$(basename "${_RELEASE_DIR}")

    _TAG_XV_VER=$(jq -r '.xvector.version' "${_RELEASE_DIR}/manifest.json")
    _TAG_XC_VER=$(jq -r '.xarith.version' "${_RELEASE_DIR}/manifest.json")
    _TAG_XF_VER=$(jq -r '.xfaiss.version' "${_RELEASE_DIR}/manifest.json")
    _TAG_XV_HASH=$(jq -r '.xvector.git_hash' "${_RELEASE_DIR}/manifest.json")
    _TAG_XF_HASH=$(jq -r '.xfaiss.git_hash' "${_RELEASE_DIR}/manifest.json")
}

cmd_release_publish() {
    # Verify gh CLI is authenticated
    if ! command -v gh &>/dev/null; then
        log_error "gh CLI is required for release. Install from https://cli.github.com/"
        exit 1
    fi
    if ! gh auth status &>/dev/null; then
        log_error "gh CLI is not authenticated. Run 'gh auth login' first."
        exit 1
    fi
    log_info "gh CLI authenticated: $(gh auth status 2>&1 | grep 'Logged in' | head -1 | xargs)"

    # Load release state from prepared release
    _load_release_state

    # Determine which tag to publish
    local suite_tag="${1:-}"
    if [[ -z "${suite_tag}" ]]; then
        suite_tag=$(git -C "${SUITE_ROOT}" tag --sort=-creatordate | grep '^release-' | head -1)
        if [[ -z "${suite_tag}" ]]; then
            log_error "No release-* tag found. Run './package.sh release prepare' first."
            exit 1
        fi
    fi

    # Verify tag exists locally
    if ! git -C "${SUITE_ROOT}" rev-parse "${suite_tag}" &>/dev/null; then
        log_error "Tag '${suite_tag}' not found locally."
        exit 1
    fi

    _SUITE_TAG="${suite_tag}"

    # Show publish summary
    echo ""
    log_info "Publishing release: ${_SUITE_TAG}"
    log_info "  Release dir: ${_RELEASE_DIR}/"
    log_info "  xvector  = v${_TAG_XV_VER}  (${_TAG_XV_HASH})"
    log_info "  xarith = v${_TAG_XC_VER}  (${_TAG_XV_HASH})"
    log_info "  xfaiss   = v${_TAG_XF_VER}  (${_TAG_XF_HASH})"
    echo ""
    ls -lh "${_RELEASE_DIR}/"

    if ! confirm_prompt "Push tag '${_SUITE_TAG}' and create GitHub Release?"; then
        log_warn "Publish cancelled."
        return 0
    fi

    echo ""
    log_info "Pushing tag ${_SUITE_TAG} to origin..."
    git -C "${SUITE_ROOT}" push origin HEAD "${_SUITE_TAG}"

    # Upload only the dist tarball and manifest
    local dist_tarball="${_RELEASE_DIR}/xvector-suite-${_TAG_XV_VER}-dist.tar.gz"
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
| xarith | ${_TAG_XC_VER} | \`${_TAG_XV_HASH}\` |
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

    echo ""
    log_info "Release published: ${_SUITE_TAG}"
    log_info ""
    log_info "Next steps (docs):"
    log_info "  ./package.sh docs build ${_SUITE_TAG}   # build docs for this release"
    log_info "  ./package.sh docs preview               # preview locally"
    log_info "  ./package.sh docs publish                # deploy to gh-pages"
}

# --- sync ---

_sync_submodule() {
    local name="$1" repo_dir="$2" branch="$3"

    log_info "Fetching ${name} origin/${branch}..."
    if ! git -C "${repo_dir}" fetch origin "${branch}"; then
        log_error "Failed to fetch ${name}. Check your SSH keys / network."
        exit 1
    fi

    local before after
    before=$(git -C "${repo_dir}" rev-parse HEAD)
    after=$(git -C "${repo_dir}" rev-parse "origin/${branch}")

    if [[ "${before}" != "${after}" ]]; then
        git -C "${repo_dir}" checkout "${branch}" 2>/dev/null \
            || git -C "${repo_dir}" checkout -b "${branch}" "origin/${branch}"
        git -C "${repo_dir}" merge --ff-only "origin/${branch}"
        log_info "${name}: ${before} -> ${after}"
        return 0
    else
        log_info "${name}: already up to date (${before})"
        return 1
    fi
}

cmd_sync() {
    local changed=0

    log_info "Initializing submodules..."
    git -C "${SUITE_ROOT}" submodule update --init

    _sync_submodule "xvector-dev" "${XVECTOR_DIR}" "${XVECTOR_DEFAULT_BRANCH}" && changed=1
    _sync_submodule "xfaiss" "${XFAISS_DIR}" "${XFAISS_DEFAULT_BRANCH}" && changed=1

    # Check if parent repo's recorded commits differ from actual submodule HEADs
    local submodules=("xvector-dev:${XVECTOR_DIR}" "xfaiss:${XFAISS_DIR}")
    for entry in "${submodules[@]}"; do
        local path="${entry%%:*}" dir="${entry#*:}"
        local expected actual
        expected=$(get_expected_hash "${path}")
        actual=$(git -C "${dir}" rev-parse HEAD)
        if [[ "${expected}" != "${actual}" ]]; then
            changed=1
        fi
    done

    echo ""
    if [[ ${changed} -ne 0 ]]; then
        log_info "Submodules updated. Run 'git diff' to review, then commit when ready."
    else
        log_info "Nothing to update."
    fi
}

# --- docs ---

cmd_docs_build() {
    local release_tag="${1:-}"

    if [[ -z "${release_tag}" ]]; then
        # Auto-detect: use the latest release-* tag from the suite repo
        release_tag=$(git -C "${SUITE_ROOT}" tag --sort=-creatordate 2>/dev/null | grep '^release-' | head -1)
        release_tag="${release_tag:-release-latest}"
        log_info "Auto-detected release tag: ${release_tag}"
    fi

    get_target_version "xvector";  local xv_ver="${_VERSION}"
    get_target_version "xarith"; local xc_ver="${_VERSION}"

    local download_url="https://github.com/xcena-dev/xvector-suite/releases/download/${release_tag}/xvector-suite-${xv_ver}-dist.tar.gz"
    log_info "Docs download URL: ${download_url}"

    if ! confirm_prompt "Build docs with release_tag=${release_tag}?"; then
        log_warn "Documentation build cancelled."
        return 0
    fi

    # Generate a version overlay that includes the release tag
    local overlay
    overlay=$(mktemp --suffix=.yml)
    cat > "${overlay}" <<EOF
xvector_version: "${xv_ver}"
xarith_version: "${xc_ver}"
release_tag: "${release_tag}"
EOF

    log_info "Building documentation with release_tag=${release_tag}..."

    # Pass the overlay as an extra Jekyll config via DOCS_VERSION_OVERLAY env var
    export DOCS_VERSION_OVERLAY="${overlay}"
    _pkg_build_docs
    unset DOCS_VERSION_OVERLAY
    rm -f "${overlay}"

    log_info "Documentation built with release_tag=${release_tag}"
}

cmd_docs_preview() {
    local site_dir="${XVECTOR_DIR}/build/site/xvector-suite"

    if [[ ! -d "${site_dir}/xvector" ]] || [[ ! -d "${site_dir}/xarith" ]]; then
        log_error "Documentation not found in ${site_dir}."
        log_error "Run './package.sh docs build' first."
        exit 1
    fi

    log_info "Starting docs preview server..."
    "${DOCS_SH}" serve "$@"
}

cmd_docs_publish() {
    local site_dir="${XVECTOR_DIR}/build/site/xvector-suite"

    if [[ ! -d "${site_dir}/xvector" ]] || [[ ! -d "${site_dir}/xarith" ]]; then
        log_error "Documentation not found in ${site_dir}."
        log_error "Run './package.sh docs build' first."
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
    log_info "  /xarith/         Jekyll + Doxygen API reference"
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
        echo "  xvector-dev:    ok (${actual_xv})"
    else
        echo -e "  xvector-dev:    \033[0;31mMISMATCH\033[0m expected=${expected_xv} actual=${actual_xv}"
    fi
    if [[ "${expected_xf}" == "${actual_xf}" ]]; then
        echo "  xfaiss:         ok (${actual_xf})"
    else
        echo -e "  xfaiss:         \033[0;31mMISMATCH\033[0m expected=${expected_xf} actual=${actual_xf}"
    fi

    # Versions
    echo ""
    for t in xvector xarith xfaiss; do
        get_target_version "${t}"
        printf "  %-12s v%-10s\n" "${t}" "${_VERSION}"
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

    # Latest release tag
    local latest_tag
    latest_tag=$(git -C "${SUITE_ROOT}" tag --sort=-creatordate 2>/dev/null | grep '^release-' | head -1)
    if [[ -n "${latest_tag}" ]]; then
        echo "  Latest tag:      ${latest_tag}"
    fi
    echo ""
}

# --- Usage ---

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [subcommand] [options]

Packaging and release management for xvector-suite.
Version is managed in each submodule's VERSION file (pure semver).

Commands:
  status                Show repo state, versions, build artifacts
  sync                  Fetch latest submodule commits and commit references
  build [target]        Build artifacts + dist tarball into dist/build/
  release prepare [target]  Verify artifacts, create manifest, commit & tag (local)
  release publish [tag]     Push tag + create GitHub Release (remote)
  docs build [tag]      Build documentation with release-specific download paths
  docs preview          Preview built documentation locally (localhost:8000)
  docs publish          Publish documentation to gh-pages

Targets:
  xvector    libxvector-dev .deb package
  xarith   libxarith-dev .deb package / examples
  xfaiss     xfaiss source tarball
  all        All targets (default)

Workflow:
    $(basename "$0") sync                           # Update submodules to latest remote
    $(basename "$0") build                          # Build all artifacts locally
    # ... verify artifacts locally ...
    $(basename "$0") release prepare                # Create manifest + tag (local)
    $(basename "$0") release publish                # Push tag + GitHub Release
    $(basename "$0") docs build                     # Build docs (auto-detect latest tag)
    $(basename "$0") docs build release-1709512345  # Build docs with specific tag
    $(basename "$0") docs preview                   # Preview docs locally
    $(basename "$0") docs publish                   # Deploy docs to gh-pages
EOF
}

# --- Interactive menu ---

interactive_menu() {
    echo ""
    echo -e "\033[1;36m  xvector-suite packaging\033[0m"
    echo ""
    echo "  1) status           Show repo state, versions, artifacts"
    echo "  2) sync             Fetch & update submodules"
    echo "  3) build            Build all artifacts + dist tarball"
    echo "  4) release prepare  Create manifest + tag (local)"
    echo "  5) release publish  Push tag + GitHub Release"
    echo "  6) docs build       Build documentation"
    echo "  7) docs preview     Preview built documentation locally"
    echo "  8) docs publish     Deploy docs to gh-pages"
    echo ""
    echo "  h) help      q) quit"
    echo ""

    local choice
    read -rp "  Select [1-8, h, q]: " choice

    case "${choice}" in
        1) cmd_status ;;
        2) cmd_sync ;;
        3) cmd_build "all" ;;
        4) cmd_release_prepare ;;
        5) cmd_release_publish ;;
        6) cmd_docs_build ;;
        7) cmd_docs_preview ;;
        8) cmd_docs_publish ;;
        h) usage ;;
        q) exit 0 ;;
        *) log_error "Invalid choice: ${choice}"; exit 1 ;;
    esac
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
        sync)    cmd_sync "$@" ;;
        build)   cmd_build "$@" ;;
        release)
            local subcmd="${1:-}"
            if [[ -z "${subcmd}" ]]; then
                log_error "Missing subcommand. Use: release prepare | release publish"
                exit 1
            fi
            shift
            case "${subcmd}" in
                prepare) cmd_release_prepare "$@" ;;
                publish) cmd_release_publish "$@" ;;
                *) log_error "Unknown subcommand: release ${subcmd}"; exit 1 ;;
            esac
            ;;
        docs)
            local subcmd="${1:-}"
            if [[ -z "${subcmd}" ]]; then
                log_error "Missing subcommand. Use: docs build | docs preview | docs publish"
                exit 1
            fi
            shift
            case "${subcmd}" in
                build)   cmd_docs_build "$@" ;;
                preview) cmd_docs_preview "$@" ;;
                publish) cmd_docs_publish "$@" ;;
                *) log_error "Unknown subcommand: docs ${subcmd}"; exit 1 ;;
            esac
            ;;
        -h|--help) usage; exit 0 ;;
        *)
            log_error "Unknown command: ${command}"
            usage
            exit 1
            ;;
    esac
}

main "$@"
