#!/bin/bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Logging ---
log_info()  { echo -e "\033[0;32m[INFO]\033[0m  $*"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }
log_warn()  { echo -e "\033[0;33m[WARN]\033[0m  $*"; }

# --- Root check ---
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)."
    exit 1
fi

# --- Find artifacts ---
find_artifact() {
    local label="$1"
    local pattern="$2"
    local matches
    matches=("${SCRIPT_DIR}"/${pattern})

    if [[ ${#matches[@]} -eq 0 || ! -e "${matches[0]}" ]]; then
        log_error "No ${label} found matching: ${pattern}"
        exit 1
    fi
    if [[ ${#matches[@]} -gt 1 ]]; then
        log_error "Multiple ${label} files found matching: ${pattern}"
        exit 1
    fi
    echo "${matches[0]}"
}

DEB_XCOMPUTE="$(find_artifact "libxcompute-dev package" "libxcompute-dev_*.deb")"
DEB_XVECTOR="$(find_artifact "libxvector-dev package" "libxvector-dev_*.deb")"
XFAISS_SRC="$(find_artifact "xfaiss source archive" "xfaiss-*-source.tar.gz")"

log_info "Found libxcompute-dev: $(basename "${DEB_XCOMPUTE}")"
log_info "Found libxvector-dev:  $(basename "${DEB_XVECTOR}")"
log_info "Found xfaiss source:   $(basename "${XFAISS_SRC}")"

# --- Install debs ---
log_info "Installing $(basename "${DEB_XCOMPUTE}") ..."
if ! dpkg -i "${DEB_XCOMPUTE}"; then
    log_error "Failed to install $(basename "${DEB_XCOMPUTE}")"
    exit 1
fi

log_info "Installing $(basename "${DEB_XVECTOR}") ..."
if ! dpkg -i "${DEB_XVECTOR}"; then
    log_error "Failed to install $(basename "${DEB_XVECTOR}")"
    exit 1
fi

# --- Extract xfaiss source ---
log_info "Extracting $(basename "${XFAISS_SRC}") into $(pwd) ..."
if ! tar -xzf "${XFAISS_SRC}"; then
    log_error "Failed to extract $(basename "${XFAISS_SRC}")"
    exit 1
fi

XFAISS_DIRNAME="$(tar -tzf "${XFAISS_SRC}" | head -1 | cut -d/ -f1)"
log_info "xfaiss source extracted to: $(pwd)/${XFAISS_DIRNAME}"

# --- Summary ---
echo ""
log_info "Installation complete."
log_info "  Installed: $(basename "${DEB_XCOMPUTE}")"
log_info "  Installed: $(basename "${DEB_XVECTOR}")"
log_info "  Extracted: $(pwd)/${XFAISS_DIRNAME}"
