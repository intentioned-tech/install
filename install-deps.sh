#!/bin/bash
# Intentioned.tech - System dependency installer
#
# Installs the OS-level packages the main installer needs but cannot get from
# PyPI:
#
#   * a C/C++ toolchain, so `llama-cpp-python` (GGUF support) can be compiled.
#     It publishes no Linux wheels, so pip always builds the sdist from source.
#   * Tk, for every compatible Python on the box, so `config_tool.py` can open.
#     tkinter is a stdlib module that most distros do NOT ship with their Python
#     package — it lives in a separate `-tk` / `-tkinter` package, and a venv
#     inherits the omission from the interpreter it was created with.
#   * ffmpeg, git, curl and zstd, which install.sh shells out to.
#
# Safe to re-run: every step is a no-op when the package is already present.
#
# Run with: bash install-deps.sh

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Python versions worth wiring Tk into. The app itself requires 3.12 exactly
# (see install.sh), but a dev box usually carries more than one interpreter and
# a missing tkinter is equally fatal in any of them, so cover the range instead
# of only the one install.sh will pick.
PY_MIN_MINOR=9
PY_MAX_MINOR=14

WITH_CUDA=false
WITH_TK=true
DRY_RUN=false
ASSUME_YES=false
CUDA_VERSION=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --cuda)     WITH_CUDA=true; shift ;;
        --cuda-version) WITH_CUDA=true; CUDA_VERSION="$2"; shift 2 ;;
        --no-tk)    WITH_TK=false; shift ;;
        --dry-run)  DRY_RUN=true; shift ;;
        -y|--yes)   ASSUME_YES=true; shift ;;
        -h|--help)
            echo "Intentioned.tech dependency installer"
            echo ""
            echo "Usage: bash install-deps.sh [OPTIONS]"
            echo ""
            echo "Installs the system packages install.sh needs: a C/C++ toolchain for the"
            echo "llama-cpp-python (GGUF) build, Tk for every detected Python, plus ffmpeg,"
            echo "git, curl and zstd."
            echo ""
            echo "Options:"
            echo "  --cuda      Also install the CUDA toolkit (nvcc), needed to build"
            echo "              llama-cpp-python with GPU offload. Large download."
            echo "              Uses NVIDIA's repository, not the distro package, which is"
            echo "              frozen at the version current when the release was cut."
            echo "              Picks the newest version the installed driver supports."
            echo "  --cuda-version X.Y"
            echo "              Install this CUDA version instead of the newest, e.g. 13.0."
            echo "  --no-tk     Skip the Tk packages"
            echo "  --dry-run   Print the package-manager commands without running them"
            echo "  -y, --yes   Do not prompt before installing"
            echo "  -h, --help  Show this message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage."
            exit 1
            ;;
    esac
done

echo -e "${CYAN}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║          Intentioned.tech - System Dependencies               ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

command_exists() { command -v "$1" >/dev/null 2>&1; }

OS="$(uname -s)"
case "${OS}" in
    Linux*)  PLATFORM=Linux ;;
    Darwin*) PLATFORM=macOS ;;
    *)       PLATFORM="UNKNOWN:${OS}" ;;
esac

PKG=""
if [ "$PLATFORM" = "macOS" ]; then
    PKG="brew"
elif command_exists apt-get; then
    PKG="apt"
elif command_exists dnf; then
    PKG="dnf"
elif command_exists pacman; then
    PKG="pacman"
elif command_exists zypper; then
    PKG="zypper"
fi

if [ -z "$PKG" ]; then
    echo -e "${RED}No supported package manager found (apt-get, dnf, pacman, zypper, brew).${NC}"
    echo -e "${YELLOW}Install these by hand, then re-run install.sh:${NC}"
    echo -e "${YELLOW}  a C/C++ compiler and make, Tk for your Python, ffmpeg, git, curl, zstd${NC}"
    exit 1
fi
if [ "$PKG" = "brew" ] && ! command_exists brew; then
    echo -e "${RED}Homebrew is not installed. See https://brew.sh, then re-run.${NC}"
    exit 1
fi
echo -e "${GREEN}Platform: ${PLATFORM}   Package manager: ${PKG} ✓${NC}"

# Homebrew refuses to run under sudo; every other manager needs root.
_as_root() {
    if [ "$PKG" = "brew" ] || [ "$(id -u)" = 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

# Runs a package-manager command, honouring --dry-run. Never aborts the script:
# a missing optional package should not take the whole run down, so callers
# inspect the return value instead.
run() {
    if [ "$DRY_RUN" = true ]; then
        echo -e "${CYAN}   [dry-run] $*${NC}"
        return 0
    fi
    _as_root "$@"
}

# apt's package *names* are resolved below (versioned vs unversioned Tk), and
# apt-cache cannot answer that on a machine whose lists were never fetched —
# a fresh container, or one that has not seen an update in months. Refresh
# first so the name probing is meaningful. Read-only, so it runs before the
# confirmation prompt.
if [ "$PKG" = "apt" ] && [ "$DRY_RUN" != true ]; then
    echo -e "${YELLOW}Refreshing package lists...${NC}"
    _as_root apt-get update -qq || true
fi

# True when the package exists in the configured repositories. Used to choose
# between versioned and unversioned names (python3.12-tk vs python3-tk) without
# emitting a scary "Unable to locate package" for the miss.
pkg_available() {
    case "$PKG" in
        apt)    apt-cache show "$1" >/dev/null 2>&1 ;;
        dnf)    dnf --quiet info "$1" >/dev/null 2>&1 ;;
        pacman) pacman -Si "$1" >/dev/null 2>&1 ;;
        zypper) zypper --non-interactive search --match-exact --type package "$1" >/dev/null 2>&1 ;;
        brew)   brew info "$1" >/dev/null 2>&1 ;;
    esac
}

pkg_install() {
    [ $# -gt 0 ] || return 0
    case "$PKG" in
        apt)    run apt-get install -y "$@" ;;
        dnf)    run dnf install -y "$@" ;;
        pacman) run pacman -S --needed --noconfirm "$@" ;;
        zypper) run zypper --non-interactive install -y "$@" ;;
        brew)   run brew install "$@" ;;
    esac
}

# ---------------------------------------------------------------------------
# Work out what to install
# ---------------------------------------------------------------------------

# Every interpreter on the box, as bare minor versions ("3.12"), newest first.
# Both `python3.N` on PATH and pyenv installs count.
detect_pythons() {
    local found="" v p
    for v in $(seq "$PY_MAX_MINOR" -1 "$PY_MIN_MINOR"); do
        if command_exists "python3.$v"; then
            found="$found 3.$v"
            continue
        fi
        for p in "$HOME"/.pyenv/versions/3."$v".*/bin/python3."$v"; do
            if [ -x "$p" ]; then
                found="$found 3.$v"
                break
            fi
        done
    done
    # A bare `python3` can be a version outside the range above, or a build with
    # no versioned name on PATH; fold its real version in so it is not missed.
    if command_exists python3; then
        v="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)"
        if [ -n "$v" ]; then
            case " $found " in
                *" $v "*) ;;
                *) found="$found $v" ;;
            esac
        fi
    fi
    echo "$found"
}

# Package holding tkinter for a given Python minor version, most specific name
# first. Distros differ on whether Tk is split per interpreter (Debian, Fedora,
# SUSE) or shared system-wide (Arch, whose `python` links the system Tk).
tk_package_for() {
    local py="$1" nodot="${1//./}"
    case "$PKG" in
        apt)    echo "python${py}-tk python3-tk" ;;
        dnf)    echo "python${py}-tkinter python3-tkinter" ;;
        pacman) echo "tk" ;;
        zypper) echo "python${nodot}-tk python3-tk" ;;
        brew)   echo "python-tk@${py} python-tk" ;;
    esac
}

# Headers for building C extensions against a given interpreter. Not needed by
# llama-cpp-python itself (it is ctypes-based and builds a plain shared
# library), but several requirements.txt entries can fall back to an sdist.
dev_package_for() {
    local py="$1" nodot="${1//./}"
    case "$PKG" in
        apt)    echo "python${py}-dev python3-dev" ;;
        dnf)    echo "python${py}-devel python3-devel" ;;
        pacman) echo "" ;;   # headers ship inside the `python` package
        zypper) echo "python${nodot}-devel python3-devel" ;;
        brew)   echo "" ;;   # headers ship inside the formula
    esac
}

# First name in a candidate list that the repos actually carry.
first_available() {
    local c
    for c in $1; do
        if pkg_available "$c"; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

# Appends to a space-separated list, skipping duplicates.
append_unique() {
    local list="$1" item="$2"
    case " $list " in
        *" $item "*) echo "$list" ;;
        *) echo "$list $item" ;;
    esac
}

case "$PKG" in
    apt)    BUILD_PKGS="build-essential cmake ninja-build pkg-config" ;;
    dnf)    BUILD_PKGS="gcc gcc-c++ make cmake ninja-build pkgconfig" ;;
    pacman) BUILD_PKGS="base-devel cmake ninja pkgconf" ;;
    zypper) BUILD_PKGS="gcc gcc-c++ make cmake ninja pkg-config" ;;
    brew)   BUILD_PKGS="cmake ninja pkg-config" ;;
esac

if [ "$PKG" = "brew" ]; then
    TOOL_PKGS="ffmpeg git zstd"
else
    TOOL_PKGS="ffmpeg git curl zstd ca-certificates"
fi

echo -e "${YELLOW}Detecting Python interpreters...${NC}"
PYTHONS="$(detect_pythons)"

TK_PKGS=""
DEV_PKGS=""
if [ "$WITH_TK" = true ]; then
    for _py in $PYTHONS; do
        if _tk="$(first_available "$(tk_package_for "$_py")")"; then
            TK_PKGS="$(append_unique "$TK_PKGS" "$_tk")"
        else
            echo -e "${YELLOW}   No Tk package found for Python $_py; skipping.${NC}"
        fi
        if _dev="$(first_available "$(dev_package_for "$_py")")"; then
            DEV_PKGS="$(append_unique "$DEV_PKGS" "$_dev")"
        fi
    done
fi

# ---------------------------------------------------------------------------
# CUDA toolkit
#
# Distro CUDA packages are frozen at whatever was current when the release was
# cut — Ubuntu 24.04's `nvidia-cuda-toolkit` is still CUDA 12 — so --cuda goes
# to NVIDIA's own repository, which carries every current version.
#
# Newest is not automatically right, though. nvcc produces binaries that need a
# driver from the same CUDA major family: build llama-cpp-python with 13.x
# against a driver that only supports 12.x and it compiles fine, then fails at
# runtime. So the version is capped by what the installed driver reports.
# ---------------------------------------------------------------------------

# Highest CUDA version the installed driver supports, per nvidia-smi's header.
cuda_driver_max() {
    command_exists nvidia-smi || return 1
    nvidia-smi 2>/dev/null |
        sed -n 's/.*CUDA Version:[[:space:]]*\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1
}

# $1 <= $2, compared as version numbers.
ver_le() {
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]
}

# NVIDIA publishes one repository per distro release, named like "ubuntu2404".
nvidia_repo_id() {
    [ -r /etc/os-release ] || return 1
    . /etc/os-release
    case "$ID" in
        ubuntu)                      echo "ubuntu${VERSION_ID//./}" ;;
        debian)                      echo "debian${VERSION_ID%%.*}" ;;
        fedora)                      echo "fedora${VERSION_ID%%.*}" ;;
        rhel|centos|rocky|almalinux) echo "rhel${VERSION_ID%%.*}" ;;
        opensuse*|sles)              echo "opensuse15" ;;
        *) return 1 ;;
    esac
}

nvidia_repo_arch() {
    case "$(uname -m)" in
        x86_64)       echo "x86_64" ;;
        aarch64|arm64) echo "sbsa" ;;
        *) return 1 ;;
    esac
}

add_nvidia_repo() {
    local rid arch base tmp
    rid="$(nvidia_repo_id)" || return 1
    arch="$(nvidia_repo_arch)" || return 1
    base="https://developer.download.nvidia.com/compute/cuda/repos/$rid/$arch"
    case "$PKG" in
        apt)
            tmp="$(mktemp -d)"
            curl -fsSL -o "$tmp/cuda-keyring.deb" "$base/cuda-keyring_1.1-1_all.deb" || {
                rm -rf "$tmp"; return 1
            }
            _as_root dpkg -i "$tmp/cuda-keyring.deb" >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
            rm -rf "$tmp"
            _as_root apt-get update -qq || true
            ;;
        dnf)
            # dnf5 renamed the subcommand; try both spellings.
            _as_root dnf config-manager --add-repo "$base/cuda-$rid.repo" >/dev/null 2>&1 ||
                _as_root dnf config-manager addrepo --from-repofile="$base/cuda-$rid.repo" >/dev/null 2>&1 ||
                return 1
            ;;
        zypper)
            _as_root zypper --non-interactive addrepo "$base/cuda-$rid.repo" >/dev/null 2>&1 || return 1
            _as_root zypper --non-interactive refresh >/dev/null 2>&1 || true
            ;;
        *) return 1 ;;
    esac
}

# Versioned toolkit packages the repositories carry, as "cuda-toolkit-13-3".
cuda_toolkit_packages() {
    case "$PKG" in
        apt)    apt-cache search --names-only '^cuda-toolkit-[0-9]+-[0-9]+$' 2>/dev/null | awk '{print $1}' ;;
        dnf)    dnf repoquery --qf '%{name}\n' 'cuda-toolkit-*' 2>/dev/null |
                    grep -E '^cuda-toolkit-[0-9]+-[0-9]+$' | sort -u ;;
        zypper) zypper --non-interactive search --type package 'cuda-toolkit-*' 2>/dev/null |
                    awk -F'|' '{gsub(/ /,"",$2); print $2}' | grep -E '^cuda-toolkit-[0-9]+-[0-9]+$' | sort -u ;;
    esac
}

# Newest toolkit package the driver can actually run, or "" to fall back.
pick_cuda_toolkit() {
    local cap="$1" best="" best_v="" pkg v
    for pkg in $(cuda_toolkit_packages); do
        v="${pkg#cuda-toolkit-}"
        v="${v//-/.}"
        if [ -n "$cap" ] && ! ver_le "$v" "$cap"; then
            continue
        fi
        if [ -z "$best_v" ] || ver_le "$best_v" "$v"; then
            best_v="$v"
            best="$pkg"
        fi
    done
    echo "$best"
}

CUDA_PKGS=""
CUDA_PLAN=""
if [ "$WITH_CUDA" = true ]; then
    case "$PKG" in
        pacman) CUDA_PKGS="cuda"; CUDA_PLAN="cuda" ;;   # Arch tracks the current release
        brew)   ;;                                       # no CUDA on macOS
        *)      CUDA_PLAN="newest from NVIDIA's repository" ;;
    esac
    if [ -n "$CUDA_VERSION" ]; then
        CUDA_PLAN="$CUDA_VERSION (requested)"
    fi
fi

echo ""
echo -e "${YELLOW}Python versions:${NC} ${PYTHONS:-none found}"
echo -e "${YELLOW}Build toolchain:${NC}$BUILD_PKGS"
echo -e "${YELLOW}Runtime tools:${NC}  $TOOL_PKGS"
[ -n "$TK_PKGS" ]   && echo -e "${YELLOW}Tk (tkinter):${NC}  $TK_PKGS"
[ -n "$DEV_PKGS" ]  && echo -e "${YELLOW}Python headers:${NC}$DEV_PKGS"
[ -n "$CUDA_PLAN" ] && echo -e "${YELLOW}CUDA toolkit:${NC}  $CUDA_PLAN"
echo ""

if [ "$ASSUME_YES" != true ] && [ "$DRY_RUN" != true ]; then
    echo -e "${CYAN}Install these packages? (Y/n)${NC}"
    read -r _resp
    if [[ "$_resp" =~ ^[Nn]$ ]]; then
        echo -e "${YELLOW}Aborted.${NC}"
        exit 0
    fi
fi

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

if [ "$PKG" = "brew" ] && ! command_exists clang && ! command_exists gcc; then
    echo -e "\n${YELLOW}Installing Xcode command line tools (C/C++ compiler)...${NC}"
    xcode-select --install 2>/dev/null || true
    echo -e "${YELLOW}   If a dialog opened, finish it and re-run this script.${NC}"
fi

FAILED=""
install_group() {
    local label="$1"
    shift
    [ $# -gt 0 ] || return 0
    echo -e "\n${YELLOW}Installing ${label}...${NC}"
    if pkg_install "$@"; then
        echo -e "${GREEN}   ${label} ✓${NC}"
    else
        echo -e "${RED}   ${label} failed${NC}"
        FAILED="$FAILED ${label},"
    fi
}

# Unquoted on purpose: these are space-separated package lists.
# shellcheck disable=SC2086
install_group "build toolchain" $BUILD_PKGS
# shellcheck disable=SC2086
install_group "runtime tools" $TOOL_PKGS
if [ -n "$DEV_PKGS" ]; then
    # shellcheck disable=SC2086
    install_group "Python headers" $DEV_PKGS
fi
if [ -n "$TK_PKGS" ]; then
    # shellcheck disable=SC2086
    install_group "Tk (tkinter)" $TK_PKGS
fi
if [ "$WITH_CUDA" = true ] && [ "$PKG" != "brew" ]; then
    if [ -n "$CUDA_PKGS" ]; then
        # Arch: the distro package already tracks the current release.
        # shellcheck disable=SC2086
        install_group "CUDA toolkit" $CUDA_PKGS
    else
        echo -e "\n${YELLOW}Installing CUDA toolkit...${NC}"
        if [ "$DRY_RUN" != true ] && ! add_nvidia_repo; then
            echo -e "${YELLOW}   Could not add NVIDIA's repository for this distribution.${NC}"
        fi

        # An explicit --cuda-version wins; otherwise cap at what the driver runs.
        CUDA_CAP="$CUDA_VERSION"
        if [ -z "$CUDA_CAP" ]; then
            CUDA_CAP="$(cuda_driver_max || true)"
            if [ -n "$CUDA_CAP" ]; then
                echo -e "${YELLOW}   Driver supports up to CUDA $CUDA_CAP; not going past it.${NC}"
            else
                echo -e "${YELLOW}   No driver detected; installing the newest toolkit.${NC}"
            fi
        fi

        CUDA_PKG="$(pick_cuda_toolkit "$CUDA_CAP")"
        if [ -z "$CUDA_PKG" ] && [ -n "$CUDA_CAP" ]; then
            echo -e "${YELLOW}   No toolkit at or below CUDA $CUDA_CAP is available.${NC}"
            echo -e "${YELLOW}   Update the driver, or pass --cuda-version to override.${NC}"
        fi
        if [ -z "$CUDA_PKG" ]; then
            # Distro package as the last resort: old, but it does contain nvcc.
            case "$PKG" in
                apt)    CUDA_PKG="nvidia-cuda-toolkit" ;;
                dnf|zypper) CUDA_PKG="cuda-toolkit" ;;
            esac
            echo -e "${YELLOW}   Falling back to the distribution package ($CUDA_PKG).${NC}"
        fi
        install_group "CUDA toolkit ($CUDA_PKG)" "$CUDA_PKG"
    fi
fi

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

if [ "$DRY_RUN" = true ]; then
    echo -e "\n${CYAN}Dry run complete — nothing was installed.${NC}"
    exit 0
fi

echo -e "\n${YELLOW}Verifying...${NC}"
MISSING=""

check_cmd() {
    if command_exists "$1"; then
        echo -e "${GREEN}   $1 ✓${NC}"
    else
        echo -e "${RED}   $1 MISSING${NC}"
        MISSING="$MISSING $1"
    fi
}

check_cmd cc
check_cmd c++
check_cmd make
check_cmd ffmpeg
check_cmd git

# `import tkinter` alone is NOT a valid test. The pure-Python half of tkinter
# ships in the base stdlib, and removing the -tk package leaves the now-empty
# /usr/lib/pythonX.Y/tkinter/ directory behind — which Python then imports
# happily as a namespace package, __file__ = None and no Tk in sight. Import
# the C extension too, and touch an attribute that only the real __init__.py
# defines. Tk() is deliberately NOT constructed: that needs a display.
TK_PROBE='import tkinter, _tkinter; tkinter.Tk'

if [ "$WITH_TK" = true ]; then
    for _py in $PYTHONS; do
        _bin="python$_py"
        command_exists "$_bin" || continue
        if "$_bin" -c "$TK_PROBE" >/dev/null 2>&1; then
            echo -e "${GREEN}   $_bin: tkinter ✓${NC}"
        else
            echo -e "${RED}   $_bin: tkinter MISSING${NC}"
            MISSING="$MISSING tkinter($_bin)"
        fi
    done
fi

# nvcc is reported, never required: a CPU or ROCm host has no use for it, and on
# a CUDA host without it install.sh falls back to a CPU-only GGUF build.
if command_exists nvcc; then
    echo -e "${GREEN}   nvcc ✓${NC}"
elif [ -x /usr/local/cuda/bin/nvcc ]; then
    echo -e "${YELLOW}   nvcc found in /usr/local/cuda/bin but not on PATH.${NC}"
    echo -e "${YELLOW}   Add it:  export PATH=/usr/local/cuda/bin:\$PATH${NC}"
elif command_exists nvidia-smi; then
    echo -e "${YELLOW}   nvcc not found: NVIDIA driver present but no CUDA toolkit.${NC}"
    echo -e "${YELLOW}   GGUF will build CPU-only. Re-run with --cuda for GPU offload.${NC}"
fi

echo ""
if [ -n "$MISSING" ] || [ -n "$FAILED" ]; then
    [ -n "$FAILED" ]  && echo -e "${RED}Package groups that failed:${FAILED%,}${NC}"
    [ -n "$MISSING" ] && echo -e "${RED}Still missing:${MISSING}${NC}"
    echo -e "${YELLOW}Fix the above, then run: bash install.sh${NC}"
    exit 1
fi

echo -e "${GREEN}All dependencies present ✓${NC}"
echo -e "${CYAN}Next: bash install.sh${NC}"
