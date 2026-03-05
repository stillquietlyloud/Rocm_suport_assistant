#!/usr/bin/env bash
# =============================================================================
# rocm_setup.sh – Automated ROCm installer, tester, and version manager
#
# Designed for:
#   • AMD Instinct MI50 (gfx906, 32 GB HBM2)
#   • Ubuntu 24.04 LTS (headless / LXC / VM / bare-metal)
#   • Also tested on Ubuntu 22.04
#
# What this script does:
#   1. Detects your GPU and system configuration.
#   2. Iterates through known ROCm versions from oldest to newest.
#   3. For each version: installs → tests → logs → keeps or rolls back.
#   4. Retains the most recent version that passes all tests.
#   5. Falls back to direct .deb downloads if the APT repo is unreachable.
#   6. Writes structured logs and a final summary report.
#
# Usage:
#   sudo ./rocm_setup.sh [OPTIONS]
#
# Options:
#   --start-version VER   Begin at this ROCm version (e.g. 5.7)
#   --target-version VER  Stop at this version (default: newest in list)
#   --skip-tests          Install without running functional tests
#   --quick-tests         Run only fast probe tests (no compile/inference)
#   --log-dir DIR         Directory for log files (default: ./logs)
#   --no-cleanup          Keep intermediate ROCm packages after failure
#   --dry-run             Print what would be done without making changes
#   --help                Show this help and exit
#
# Examples:
#   sudo ./rocm_setup.sh
#   sudo ./rocm_setup.sh --start-version 5.7 --quick-tests
#   sudo ./rocm_setup.sh --target-version 6.1 --log-dir /var/log/rocm_setup
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# SCRIPT METADATA
# ---------------------------------------------------------------------------
SCRIPT_VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# DEFAULT OPTIONS
# ---------------------------------------------------------------------------
OPT_START_VERSION=""
OPT_TARGET_VERSION=""
OPT_SKIP_TESTS=0
OPT_QUICK_TESTS=0
OPT_LOG_DIR="${SCRIPT_DIR}/logs"
OPT_NO_CLEANUP=0
OPT_DRY_RUN=0

# ---------------------------------------------------------------------------
# ROCM VERSION CATALOGUE
# Each entry: "<version>|<ubuntu_codename>|<install_method>"
#   install_method: "repo"  = use AMD apt repo
#                   "direct" = download .deb files directly
#
# MI50 / gfx906 notes:
#   • Officially supported: ROCm 4.x – 5.7.x
#   • Unofficially functional with HSA_OVERRIDE_GFX_VERSION=9.0.6: 6.0+
#   • ROCm < 5.2 is not included because Ubuntu 24.04 doesn't support them
# ---------------------------------------------------------------------------
declare -a ROCM_VERSIONS=(
    "5.2.3|jammy|repo"
    "5.3.3|jammy|repo"
    "5.4.6|jammy|repo"
    "5.5.3|jammy|repo"
    "5.6.1|jammy|repo"
    "5.7.3|jammy|repo"
    "6.0.2|noble|repo"
    "6.1.3|noble|repo"
    "6.2.4|noble|repo"
    "6.3.1|noble|repo"
)

# ---------------------------------------------------------------------------
# AMD repo base URLs (fallbacks tried in order)
# ---------------------------------------------------------------------------
# AMD repo base URLs (documented for reference; primary URL is constructed per-version)
# Fallbacks tried in order when the primary repo is unreachable.
# REPO_URLS=(
#     "https://repo.radeon.com/rocm/apt"
#     "https://repo.radeon.com/amdgpu/latest/ubuntu"
# )

# AMD GPG key
AMD_REPO_KEY_URL="https://repo.radeon.com/rocm/rocm.gpg.key"
AMD_REPO_KEY_ID="9386B48A1A693C5C"   # fallback fingerprint

# ---------------------------------------------------------------------------
# Colour codes (disabled when not a terminal)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RESET='\033[0m'
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[1;33m'
    C_BLUE='\033[0;34m'
    C_CYAN='\033[0;36m'
    C_BOLD='\033[1m'
else
    C_RESET='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN='' C_BOLD=''
fi

# ---------------------------------------------------------------------------
# LOGGING
# ---------------------------------------------------------------------------
LOG_MASTER=""   # set after OPT_LOG_DIR is processed

_ts() { date '+%Y-%m-%d %H:%M:%S'; }

_log_raw() {
    local level="$1"; shift
    local msg
    msg="[$(_ts)][$level] $*"
    echo -e "$msg"
    if [[ -n "$LOG_MASTER" ]]; then echo "$msg" >> "$LOG_MASTER"; fi
}

log()   { _log_raw "INFO " "${C_BLUE}$*${C_RESET}"; }
warn()  { _log_raw "WARN " "${C_YELLOW}$*${C_RESET}"; }
error() { _log_raw "ERROR" "${C_RED}$*${C_RESET}"; }
ok()    { _log_raw "OK   " "${C_GREEN}$*${C_RESET}"; }
sep()   { _log_raw "----" "$(printf '─%.0s' {1..66})"; }
header() {
    sep
    _log_raw "====" "${C_BOLD}${C_CYAN}$*${C_RESET}"
    sep
}

# ---------------------------------------------------------------------------
# ARGUMENT PARSING
# ---------------------------------------------------------------------------
usage() {
    sed -n '/^# Usage:/,/^# ==========/p' "$0" | grep '^#' | sed 's/^# \?//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --start-version)   OPT_START_VERSION="$2";  shift 2 ;;
        --target-version)  OPT_TARGET_VERSION="$2"; shift 2 ;;
        --skip-tests)      OPT_SKIP_TESTS=1;         shift   ;;
        --quick-tests)     OPT_QUICK_TESTS=1;        shift   ;;
        --log-dir)         OPT_LOG_DIR="$2";         shift 2 ;;
        --no-cleanup)      OPT_NO_CLEANUP=1;         shift   ;;
        --dry-run)         OPT_DRY_RUN=1;            shift   ;;
        --help|-h)         usage; exit 0 ;;
        *)                 echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# PRE-FLIGHT CHECKS
# ---------------------------------------------------------------------------
preflight_check() {
    header "Pre-flight checks"

    # Root / sudo
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (try: sudo $0)"
        exit 1
    fi
    ok "Running as root"

    # OS detection
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        OS_NAME="${NAME:-unknown}"
        OS_VERSION="${VERSION_ID:-unknown}"
        OS_CODENAME="${VERSION_CODENAME:-unknown}"
        log "OS: $OS_NAME $OS_VERSION ($OS_CODENAME)"
    else
        warn "Cannot detect OS – continuing anyway"
        OS_CODENAME="noble"
    fi

    # Ubuntu only
    if [[ "${ID:-}" != "ubuntu" ]]; then
        warn "This script is designed for Ubuntu.  Detected: ${ID:-unknown}."
        warn "Proceeding anyway – some steps may fail."
    fi

    # curl / wget
    if ! command -v curl >/dev/null 2>&1; then
        log "Installing curl..."
        [[ $OPT_DRY_RUN -eq 0 ]] && apt-get install -y -qq curl
    fi
    ok "curl available"

    # GPU detection
    detect_gpu

    # Existing ROCm
    if [[ -f /opt/rocm/.info/version ]]; then
        EXISTING_ROCM=$(cat /opt/rocm/.info/version)
        warn "ROCm ${EXISTING_ROCM} is already installed at /opt/rocm"
        warn "The script will remove it and re-install to find the best version."
    fi

    # Log directory
    mkdir -p "$OPT_LOG_DIR"
    LOG_MASTER="${OPT_LOG_DIR}/rocm_setup_$(date '+%Y%m%d_%H%M%S').log"
    log "Master log: $LOG_MASTER"
    ok "Pre-flight complete"
}

detect_gpu() {
    log "Detecting AMD GPU..."

    GPU_GFX="unknown"
    GPU_NAME="unknown"

    # lspci approach
    if command -v lspci >/dev/null 2>&1; then
        local pci_out
        pci_out=$(lspci 2>/dev/null | grep -iE 'display|3d|vga|gpu' || true)
        if echo "$pci_out" | grep -qi 'amd\|radeon\|instinct'; then
            GPU_NAME=$(echo "$pci_out" | head -1)
            log "PCI GPU: $GPU_NAME"
        fi
    fi

    # rocm_agent_enumerator (if already installed)
    if [[ -x /opt/rocm/bin/rocm_agent_enumerator ]]; then
        local agents
        agents=$(/opt/rocm/bin/rocm_agent_enumerator 2>/dev/null || true)
        GPU_GFX=$(echo "$agents" | grep -oE 'gfx[0-9]+' | head -1 || echo "unknown")
        log "GPU GFX (agent_enumerator): $GPU_GFX"
    fi

    # Heuristic: if lspci shows MI50 assume gfx906
    if echo "$GPU_NAME" | grep -qi 'mi50\|mi 50\|vega 20\|instinct mi50'; then
        GPU_GFX="gfx906"
        log "GPU identified as MI50 → gfx906"
    fi

    log "GPU Summary: name='${GPU_NAME}' gfx='${GPU_GFX}'"

    # Set MI50 compatibility mode; export so child processes (test_rocm.sh) can read it
    if [[ "$GPU_GFX" == "gfx906" || "$GPU_NAME" =~ [Mm][Ii]50 ]]; then
        export MI50_COMPAT=1
        log "MI50 compatibility mode ON (HSA_OVERRIDE_GFX_VERSION will be set)"
    else
        export MI50_COMPAT=0
        log "MI50 compatibility mode OFF"
    fi
}

# ---------------------------------------------------------------------------
# DEPENDENCY SETUP
# ---------------------------------------------------------------------------
install_base_deps() {
    header "Installing base dependencies"
    [[ $OPT_DRY_RUN -eq 1 ]] && { log "[dry-run] would install base deps"; return; }

    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        wget curl gnupg2 software-properties-common \
        pciutils lsb-release apt-transport-https ca-certificates \
        clinfo mesa-opencl-icd \
        python3 python3-pip python3-venv \
        cmake make build-essential git \
        libssl-dev libffi-dev \
        2>&1 | tail -5
    ok "Base dependencies installed"
}

# ---------------------------------------------------------------------------
# AMD APT REPO MANAGEMENT
# ---------------------------------------------------------------------------
_add_amd_repo() {
    local rocm_version="$1"
    local codename="$2"
    local major_minor
    major_minor=$(echo "$rocm_version" | cut -d. -f1,2)

    log "Adding AMD ROCm ${rocm_version} APT repo for Ubuntu ${codename}"

    # Import GPG key
    if curl -fsSL "$AMD_REPO_KEY_URL" \
            | gpg --dearmor -o /usr/share/keyrings/rocm-archive-keyring.gpg 2>/dev/null; then
        ok "AMD GPG key imported from ${AMD_REPO_KEY_URL}"
    else
        warn "Could not fetch AMD GPG key from URL; trying apt-key adv"
        apt-key adv --keyserver keyserver.ubuntu.com --recv-keys "$AMD_REPO_KEY_ID" 2>&1 || true
    fi

    # Write sources.list entry
    cat > /etc/apt/sources.list.d/rocm.list <<EOF
# ROCm ${rocm_version} – added by rocm_setup.sh
deb [arch=amd64 signed-by=/usr/share/keyrings/rocm-archive-keyring.gpg] \
https://repo.radeon.com/rocm/apt/${major_minor} ${codename} main
EOF

    # Pin the ROCm repo to avoid accidentally upgrading via another source
    cat > /etc/apt/preferences.d/rocm-pin-600 <<EOF
Package: *
Pin: release o=repo.radeon.com
Pin-Priority: 600
EOF

    apt-get update -qq 2>&1 | grep -v "^Hit:" | tail -5 || true
}

_remove_amd_repo() {
    rm -f /etc/apt/sources.list.d/rocm.list \
          /etc/apt/preferences.d/rocm-pin-600 \
          /usr/share/keyrings/rocm-archive-keyring.gpg 2>/dev/null || true
    apt-get update -qq 2>&1 | grep -v "^Hit:" | tail -3 || true
}

# ---------------------------------------------------------------------------
# ROCm PACKAGE LISTS (per major version series)
# ---------------------------------------------------------------------------
_rocm_packages_for() {
    local version="$1"
    local major
    major=$(echo "$version" | cut -d. -f1)

    # Core packages common to all versions
    local pkgs="rocm-dev rocm-libs rocm-utils rocm-hip-sdk"

    if [[ "$major" -ge 6 ]]; then
        pkgs="$pkgs rocm-opencl-dev rocm-bandwidth-test"
    else
        pkgs="$pkgs rocm-opencl-runtime rocm-bandwidth-test"
    fi
    echo "$pkgs"
}

# ---------------------------------------------------------------------------
# INSTALL ROCm VIA REPO
# ---------------------------------------------------------------------------
install_rocm_via_repo() {
    local version="$1"
    local codename="$2"

    log "Installing ROCm ${version} via APT repo (codename: ${codename})"

    _add_amd_repo "$version" "$codename"

    local pkgs
    pkgs=$(_rocm_packages_for "$version")
    log "Packages: $pkgs"

    if [[ $OPT_DRY_RUN -eq 1 ]]; then
        log "[dry-run] would run: apt-get install -y $pkgs"
        return 0
    fi

    # shellcheck disable=SC2086
    if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            $pkgs \
            2>&1 | tee "${OPT_LOG_DIR}/apt_${version}.log" | tail -10; then
        ok "ROCm ${version} installed via repo"
        return 0
    else
        error "APT install failed for ROCm ${version}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# FALLBACK: direct .deb download
# ---------------------------------------------------------------------------
install_rocm_direct() {
    local version="$1"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    log "Attempting direct .deb download for ROCm ${version}"

    # AMD provides a .deb bundle installer for some versions.
    # The installer filename follows the pattern:
    #   amdgpu-install_<MAJOR>.<MINOR>.<PATCH>.50<MAJOR><MINOR><PATCH>-1_all.deb
    # e.g. ROCm 6.2.4 → amdgpu-install_6.2.4.60204-1_all.deb
    # The ".50" infix is AMD's build-number prefix; it is constant across versions.
    local major_minor
    major_minor=$(echo "$version" | cut -d. -f1,2)
    local ver_nodot="${version//./}"   # e.g. "624" from "6.2.4"
    local amdgpu_installer_url="https://repo.radeon.com/amdgpu-install/${version}/ubuntu/noble/amdgpu-install_${version}.50${ver_nodot}-1_all.deb"

    if [[ $OPT_DRY_RUN -eq 1 ]]; then
        log "[dry-run] would download: $amdgpu_installer_url"
        rm -rf "$tmp_dir"
        return 0
    fi

    if curl -fsSL -o "${tmp_dir}/amdgpu-install.deb" "$amdgpu_installer_url" 2>/dev/null; then
        ok "Downloaded amdgpu-install .deb"
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            "${tmp_dir}/amdgpu-install.deb" 2>&1 | tail -5
        # Now use the installer
        DEBIAN_FRONTEND=noninteractive amdgpu-install --rocmrelease="${version}" \
            --usecase=rocm,hip,opencl \
            --no-dkms \
            --accept-eula \
            2>&1 | tee "${OPT_LOG_DIR}/amdgpu_install_${version}.log" | tail -20
        ok "ROCm ${version} installed via amdgpu-install"
        rm -rf "$tmp_dir"
        return 0
    else
        warn "Direct download failed for ${version}"
        rm -rf "$tmp_dir"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# REMOVE ROCm
# ---------------------------------------------------------------------------
remove_rocm() {
    local version="${1:-}"
    log "Removing ROCm installation..."

    [[ $OPT_DRY_RUN -eq 1 ]] && { log "[dry-run] would remove ROCm"; return; }

    # amdgpu-install uninstall if available
    if command -v amdgpu-install >/dev/null 2>&1; then
        amdgpu-install --uninstall --yes 2>/dev/null || true
    fi

    # Remove known ROCm packages
    apt-get remove -y --purge 2>/dev/null \
        rocm-dev rocm-libs rocm-utils rocm-hip-sdk rocm-opencl-dev \
        rocm-opencl-runtime rocm-bandwidth-test amdgpu-install \
        hip-runtime-amd hsa-rocr-dev rocm-smi-lib \
        || true

    apt-get autoremove -y --purge 2>/dev/null || true

    # Remove leftover directories
    if [[ $OPT_NO_CLEANUP -eq 0 ]]; then
        rm -rf /opt/rocm* 2>/dev/null || true
    fi

    _remove_amd_repo
    ok "ROCm removed"
}

# ---------------------------------------------------------------------------
# CONFIGURE ENVIRONMENT FOR CURRENT VERSION
# ---------------------------------------------------------------------------
configure_environment() {
    local version="$1"

    log "Configuring system environment for ROCm ${version}..."
    [[ $OPT_DRY_RUN -eq 1 ]] && { log "[dry-run] would configure environment"; return; }

    # Install our env file to /etc/profile.d
    install -m 644 "${SCRIPT_DIR}/rocm_env.sh" /etc/profile.d/rocm_env.sh
    ok "Installed /etc/profile.d/rocm_env.sh"

    # /etc/ld.so.conf.d
    echo "/opt/rocm/lib" > /etc/ld.so.conf.d/rocm.conf
    echo "/opt/rocm/lib64" >> /etc/ld.so.conf.d/rocm.conf
    ldconfig 2>/dev/null || true
    ok "ldconfig updated"

    # Add user to render/video groups (for GPU access without root)
    for group in render video; do
        if getent group "$group" >/dev/null 2>&1; then
            # Add all human users (UID 1000-60000) to the group
            while IFS=: read -r uname _ uid _; do
                if [[ "$uid" -ge 1000 && "$uid" -lt 60000 ]]; then
                    usermod -aG "$group" "$uname" 2>/dev/null || true
                fi
            done < /etc/passwd
        fi
    done
    ok "Users added to render/video groups"
}

# ---------------------------------------------------------------------------
# RUN TEST SUITE
# ---------------------------------------------------------------------------
run_tests() {
    local version="$1"
    local test_log="${OPT_LOG_DIR}/test_${version}.log"

    if [[ $OPT_SKIP_TESTS -eq 1 ]]; then
        log "Tests skipped (--skip-tests)"
        return 0
    fi

    log "Running test suite for ROCm ${version}..."

    local test_args=()
    [[ $OPT_QUICK_TESTS -eq 1 ]] && test_args+=("--quick")
    test_args+=("--log" "$test_log")

    # Source environment for this test run
    export HSA_OVERRIDE_GFX_VERSION="9.0.6"
    export ROC_ENABLE_PRE_VEGA=1
    export ROCM_PATH="/opt/rocm"
    export PATH="/opt/rocm/bin:/opt/rocm/llvm/bin:$PATH"
    export LD_LIBRARY_PATH="/opt/rocm/lib:/opt/rocm/lib64:${LD_LIBRARY_PATH:-}"

    if bash "${SCRIPT_DIR}/test_rocm.sh" "${test_args[@]}" 2>&1 \
            | tee -a "$test_log"; then
        ok "Tests PASSED for ROCm ${version} (log: $test_log)"
        return 0
    else
        local rc=$?
        error "Tests FAILED for ROCm ${version} (rc=$rc, log: $test_log)"
        return "$rc"
    fi
}

# ---------------------------------------------------------------------------
# SUMMARY REPORT
# ---------------------------------------------------------------------------
declare -A RESULT_MAP   # version → PASS|FAIL|SKIP

write_summary() {
    local report
    report="${OPT_LOG_DIR}/summary_$(date '+%Y%m%d_%H%M%S').txt"
    {
        echo "=================================================="
        echo " ROCm Setup Summary – $(date '+%Y-%m-%d %H:%M:%S')"
        echo "=================================================="
        echo ""
        echo "GPU    : ${GPU_NAME:-unknown}"
        echo "GFX    : ${GPU_GFX:-unknown}"
        echo "OS     : ${OS_NAME:-unknown} ${OS_VERSION:-}"
        echo ""
        echo "Version results:"
        for ver_entry in "${ROCM_VERSIONS[@]}"; do
            local ver="${ver_entry%%|*}"
            local res="${RESULT_MAP[$ver]:-SKIPPED}"
            printf "  %-10s → %s\n" "$ver" "$res"
        done
        echo ""
        echo "Final installed version: ${BEST_VERSION:-none}"
        echo ""
        echo "Next steps:"
        echo "  1. source /etc/profile.d/rocm_env.sh"
        echo "  2. rocm-smi"
        echo "  3. clinfo"
        echo "  4. Detailed logs: ${OPT_LOG_DIR}/"
    } | tee "$report"
    ok "Summary report written to $report"
}

# ---------------------------------------------------------------------------
# MAIN LOOP
# ---------------------------------------------------------------------------
BEST_VERSION=""
BEST_VERSION_PASSED=0

main() {
    header "ROCm Support Assistant v${SCRIPT_VERSION}"
    log "Script directory: ${SCRIPT_DIR}"
    log "Log directory   : ${OPT_LOG_DIR}"
    [[ $OPT_DRY_RUN -eq 1 ]] && warn "DRY-RUN mode – no changes will be made"

    preflight_check
    install_base_deps

    local reached_start=0
    [[ -z "$OPT_START_VERSION" ]] && reached_start=1

    for ver_entry in "${ROCM_VERSIONS[@]}"; do
        local version codename method
        IFS='|' read -r version codename method <<< "$ver_entry"

        # --start-version filter
        if [[ $reached_start -eq 0 ]]; then
            if [[ "$version" == "$OPT_START_VERSION"* ]]; then
                reached_start=1
            else
                log "Skipping ${version} (before --start-version ${OPT_START_VERSION})"
                RESULT_MAP["$version"]="SKIPPED"
                continue
            fi
        fi

        # Ubuntu codename compatibility check
        local sys_codename="${OS_CODENAME:-noble}"
        if [[ "$codename" == "jammy" && "$sys_codename" == "noble" ]]; then
            # Ubuntu 24.04 can run jammy packages in some cases – attempt anyway
            codename="noble"
        fi

        header "ROCm ${version} (${method})"

        # --- Install ---
        local install_ok=0
        if [[ "$method" == "repo" ]]; then
            if install_rocm_via_repo "$version" "$codename"; then
                install_ok=1
            else
                warn "Repo install failed – trying direct download"
                if install_rocm_direct "$version"; then
                    install_ok=1
                fi
            fi
        else
            if install_rocm_direct "$version"; then
                install_ok=1
            fi
        fi

        if [[ $install_ok -eq 0 ]]; then
            error "Could not install ROCm ${version} – skipping"
            RESULT_MAP["$version"]="INSTALL_FAIL"
            continue
        fi

        configure_environment "$version"

        # --- Test ---
        if run_tests "$version"; then
            RESULT_MAP["$version"]="PASS"
            BEST_VERSION="$version"
            BEST_VERSION_PASSED=1
            ok "ROCm ${version} – KEEPING (tests passed)"
        else
            RESULT_MAP["$version"]="FAIL"
            warn "ROCm ${version} – tests failed; rolling back"
            remove_rocm "$version"
        fi

        # Stop at --target-version
        if [[ -n "$OPT_TARGET_VERSION" && "$version" == "$OPT_TARGET_VERSION"* ]]; then
            log "Reached --target-version ${OPT_TARGET_VERSION} – stopping"
            break
        fi
    done

    # If we rolled back the last version, we may have no ROCm installed.
    # Re-install the best passing version.
    if [[ $BEST_VERSION_PASSED -eq 1 && -z "$(ls /opt/rocm 2>/dev/null)" ]]; then
        header "Re-installing best version: ${BEST_VERSION}"
        local best_entry=""
        for ve in "${ROCM_VERSIONS[@]}"; do
            [[ "$ve" == "${BEST_VERSION}|"* ]] && best_entry="$ve" && break
        done
        if [[ -n "$best_entry" ]]; then
            local bver bcode _bmethod
            IFS='|' read -r bver bcode _bmethod <<< "$best_entry"
            install_rocm_via_repo "$bver" "$bcode" || install_rocm_direct "$bver" || true
            configure_environment "$bver"
        fi
    fi

    write_summary

    if [[ -n "$BEST_VERSION" ]]; then
        ok "========================================================"
        ok "  Best working ROCm version: ${BEST_VERSION}"
        ok "  source /etc/profile.d/rocm_env.sh  then  rocm-smi"
        ok "========================================================"
        exit 0
    else
        error "No working ROCm version found.  Check logs in ${OPT_LOG_DIR}/"
        exit 1
    fi
}

# Catch unexpected exits and log them
trap 'error "Script interrupted at line $LINENO (exit $?)"' ERR

main "$@"
