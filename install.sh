#!/bin/bash
# Intentioned.tech - Linux/macOS Installation Script
# Run with: bash install.sh

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default installation path
INSTALL_PATH="${INSTALL_PATH:-$HOME/.local/share/intentioned}"
OPEN_CONFIG=true
INSTALL_BACKEND="${INSTALL_BACKEND:-auto}"
INSTALL_LLAMA_CPP=true
INSTALL_SYSTEMD_SERVICE=true
GGUF_MODEL=""
SKIP_REPO_DOWNLOAD=false
REPO_PATH_CLI=""

# Where the build comes from: "release" pulls the compiled build this licence is
# entitled to from private R2 through the licence Worker; "git" clones the
# source (maintainers only); "local" uses an existing checkout or dist.
SOURCE_MODE="release"
# Default MUST be a hostname that actually resolves, or every public install
# fails at the entitlement check. license.intentioned.tech is NXDOMAIN as of
# this writing; the deployed Worker answers on its workers.dev hostname.
# Point this at a custom domain once one is created and routed to the Worker.
WORKER_URL="${INTENTIONED_WORKER_URL:-https://intentioned-license-credentials.jansherremway.workers.dev}"
REL_USERNAME="${INTENTIONED_USERNAME:-}"
REL_PASSWORD="${INTENTIONED_PASSWORD:-}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-config)
            OPEN_CONFIG=false
            shift
            ;;
        --backend)
            INSTALL_BACKEND="$2"
            shift 2
            ;;
        --install-path)
            INSTALL_PATH="$2"
            shift 2
            ;;
        --skip-repo-download)
            SKIP_REPO_DOWNLOAD=true
            SOURCE_MODE="local"
            shift
            ;;
        --from-git)
            SOURCE_MODE="git"
            shift
            ;;
        --username)
            REL_USERNAME="$2"
            shift 2
            ;;
        --password)
            # Prefer INTENTIONED_PASSWORD: an argument is visible in /proc to
            # every local user for the lifetime of the process.
            REL_PASSWORD="$2"
            shift 2
            ;;
        --worker-url)
            WORKER_URL="$2"
            shift 2
            ;;
        --repo-path)
            REPO_PATH_CLI="$2"
            shift 2
            ;;
        --no-llama-cpp)
            INSTALL_LLAMA_CPP=false
            shift
            ;;
        --no-systemd-service)
            INSTALL_SYSTEMD_SERVICE=false
            shift
            ;;
        --gguf)
            GGUF_MODEL="$2"
            shift 2
            ;;
        -h|--help)
            echo "Intentioned.tech Installer"
            echo ""
            echo "Usage: bash install.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --install-path PATH   Set custom installation path"
            echo "  --backend BACKEND     PyTorch backend: auto, cuda, rocm, or cpu"
            echo "  --username USER       Licence username (or \$INTENTIONED_USERNAME)"
            echo "  --password PASS       Licence password (prefer \$INTENTIONED_PASSWORD;"
            echo "                        an argument is readable via /proc by any local user)"
            echo "  --worker-url URL      Licence server (default: the hosted Worker,"
            echo "                        or \$INTENTIONED_WORKER_URL)"
            echo "  --from-git            MAINTAINERS ONLY: clone the (private) source repo"
            echo "                        licensed build. Maintainers only."
            echo "  --skip-repo-download  Skip step [5/8] entirely. Use the current directory"
            echo "                        as the repo (or pass --repo-path)."
            echo "  --repo-path PATH      With --skip-repo-download only: use this checkout instead of \$PWD"
            echo "  --no-config           Skip opening config tool after install"
            echo "  --no-llama-cpp        Skip building llama-cpp-python (GGUF support)"
            echo "  --no-systemd-service  Do not install/enable the intentioned-server systemd"
            echo "                        service. The 'intentioned' foreground launcher is"
            echo "                        created either way; this only skips the background"
            echo "                        daemon. Always skipped on macOS (no systemd)."
            echo "  --gguf REPO[:FILE]    Configure a GGUF model as the LLM"
            echo "                        e.g. bartowski/Qwen2.5-3B-Instruct-GGUF:*Q4_K_M*.gguf"
            echo "                        or /abs/path/to/file.gguf"
            echo "  -h, --help            Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo -e "${CYAN}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║         Intentioned.tech - Social Skills Training Platform         ║"
echo "║                  Linux/macOS Installer v1.0                   ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Detect OS
OS="$(uname -s)"
case "${OS}" in
    Linux*)     PLATFORM=Linux;;
    Darwin*)    PLATFORM=macOS;;
    *)          PLATFORM="UNKNOWN:${OS}"
esac
echo -e "${YELLOW}Detected platform: ${PLATFORM}${NC}"

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Run a command with root privileges. Plain `sudo` fails on the minimal images
# (containers, cloud base boxes) that run as root without sudo installed.
_as_root() {
    if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi
}

detect_backend() {
    case "${INSTALL_BACKEND,,}" in
        auto|"")
            if command_exists nvidia-smi; then
                echo "cuda"
            elif command_exists rocm-smi || command_exists rocminfo; then
                echo "rocm"
            else
                echo "cpu"
            fi
            ;;
        cuda|rocm|cpu)
            echo "${INSTALL_BACKEND,,}"
            ;;
        *)
            echo -e "${RED}Unknown backend '${INSTALL_BACKEND}'. Use auto, cuda, rocm, or cpu.${NC}" >&2
            exit 1
            ;;
    esac
}

# Check for Python
#
# 3.12 EXACTLY, not "3.10 or newer". Kokoro TTS and NeMo/Parakeet both require
# 3.12 (see the header of requirements.txt), and the Cython dist ships
# `cpython-312-*.so` modules that will not load under any other minor version.
#
# Resolving this by version rather than by the name `python3` matters on
# rolling-release distros: `python3` there tracks the newest interpreter (3.14
# at time of writing), which sails past a ">= 3.10" test and then produces a
# venv nothing in this project can use. The failure surfaces much later as an
# unrelated-looking import error, so check it here instead.
echo -e "\n${YELLOW}[1/8] Checking Python installation...${NC}"

is_py312() {
    [ -x "$1" ] || command_exists "$1" || return 1
    "$1" -c 'import sys; sys.exit(0 if sys.version_info[:2] == (3, 12) else 1)' 2>/dev/null
}

PYTHON_BIN=""
# $INTENTIONED_PYTHON wins, then the versioned name, then whatever `python3`
# happens to be, then a pyenv install. pyenv is checked last because a shim on
# PATH is less predictable than an absolute interpreter path.
for _cand in "${INTENTIONED_PYTHON:-}" python3.12 python3 python; do
    [ -n "$_cand" ] || continue
    if is_py312 "$_cand"; then PYTHON_BIN="$(command -v "$_cand" || echo "$_cand")"; break; fi
done
if [ -z "$PYTHON_BIN" ] && [ -d "$HOME/.pyenv/versions" ]; then
    for _p in "$HOME"/.pyenv/versions/3.12.*/bin/python3.12; do
        if is_py312 "$_p"; then PYTHON_BIN="$_p"; break; fi
    done
fi

if [ -z "$PYTHON_BIN" ]; then
    echo -e "${RED}   Python 3.12 is required and was not found.${NC}"
    echo -e "${RED}   Kokoro TTS and NeMo/Parakeet need 3.12 specifically — not 3.11, not 3.13+.${NC}"
    if command_exists python3; then
        echo -e "${YELLOW}   (python3 on this system is $(python3 --version 2>&1 | cut -d' ' -f2).)${NC}"
    fi
    echo -e "${YELLOW}   Install it, then re-run — or point the installer at an existing one:${NC}"
    echo -e "${YELLOW}       INTENTIONED_PYTHON=/path/to/python3.12 bash install.sh${NC}"
    if [ "$PLATFORM" = "Linux" ]; then
        if command_exists apt-get; then
            echo -e "${YELLOW}       sudo apt-get install -y python3.12 python3.12-venv${NC}"
        elif command_exists dnf; then
            echo -e "${YELLOW}       sudo dnf install -y python3.12${NC}"
        elif command_exists pacman; then
            # Arch/CachyOS drop old minors from the repos; the AUR package or
            # pyenv is the realistic route once 3.12 is no longer current.
            echo -e "${YELLOW}       yay -S python312     # or: pyenv install 3.12${NC}"
        fi
    elif [ "$PLATFORM" = "macOS" ]; then
        echo -e "${YELLOW}       brew install python@3.12${NC}"
    fi
    exit 1
fi
echo -e "${GREEN}   Found: $("$PYTHON_BIN" --version 2>&1) at $PYTHON_BIN ✓${NC}"

# Check for Git
echo -e "\n${YELLOW}[2/8] Checking Git installation...${NC}"
if command_exists git; then
    GIT_VERSION=$(git --version)
    echo -e "${GREEN}   Found: $GIT_VERSION ✓${NC}"
else
    echo -e "${YELLOW}   Git not found. Installing...${NC}"
    if [ "$PLATFORM" = "Linux" ]; then
        if command_exists apt-get; then
            sudo apt-get install -y git
        elif command_exists dnf; then
            sudo dnf install -y git
        elif command_exists pacman; then
            sudo pacman -S --noconfirm git
        fi
    elif [ "$PLATFORM" = "macOS" ]; then
        brew install git
    fi
fi

# Check for ffmpeg
echo -e "\n${YELLOW}[3/8] Checking system dependencies and C/C++ build tools...${NC}"
if command_exists ffmpeg; then
    FFMPEG_VERSION=$(ffmpeg -version 2>&1 | head -n1)
    echo -e "${GREEN}   Found: $FFMPEG_VERSION ✓${NC}"
else
    echo -e "${YELLOW}   ffmpeg not found. Installing...${NC}"
    if [ "$PLATFORM" = "Linux" ]; then
        if command_exists apt-get; then
            sudo apt-get install -y ffmpeg
        elif command_exists dnf; then
            sudo dnf install -y ffmpeg
        elif command_exists pacman; then
            sudo pacman -S --noconfirm ffmpeg
        fi
    elif [ "$PLATFORM" = "macOS" ]; then
        brew install ffmpeg
    fi
fi

# Check for a C/C++ toolchain (llama-cpp-python is built from source)
#
# llama-cpp-python publishes no Linux wheels, so every install compiles the
# 71 MB sdist. scikit-build-core injects Python's *sysconfig* CC/CXX into the
# CMake environment whenever they are unset (builder/generator.py). On Debian
# and Ubuntu those are the triplet names `x86_64-linux-gnu-gcc` / `-g++`, which
# exist only when gcc is actually installed, so a host without build-essential
# fails during configure with
#     Could not find the compiler specified in the environment variable CC
# before any CUDA or HIP flag is even considered. Resolving a real toolchain
# here — and exporting it later — means sysconfig's guess is never consulted.
#
# Checked at step 3 rather than at build time so the failure lands before the
# multi-gigabyte PyTorch download, not after it.
CC_BIN=""
CXX_BIN=""
LLAMA_COMPILER_ARGS=""
LLAMA_TOOLCHAIN_OK=false

resolve_compilers() {
    CC_BIN=""
    CXX_BIN=""
    # $CC/$CXX win when they point at something real; a stale value (the
    # sysconfig triplet, a compiler removed since the venv was made) falls
    # through to whatever this system actually has.
    for _c in "${CC:-}" cc gcc clang; do
        [ -n "$_c" ] || continue
        if command_exists "$_c"; then CC_BIN="$(command -v "$_c")"; break; fi
    done
    for _x in "${CXX:-}" c++ g++ clang++; do
        [ -n "$_x" ] || continue
        if command_exists "$_x"; then CXX_BIN="$(command -v "$_x")"; break; fi
    done
    [ -n "$CC_BIN" ] && [ -n "$CXX_BIN" ]
}

if [ "$INSTALL_LLAMA_CPP" != true ]; then
    echo -e "${YELLOW}   Skipping compiler check (--no-llama-cpp).${NC}"
elif resolve_compilers; then
    echo -e "${GREEN}   Found: $CC_BIN, $CXX_BIN ✓${NC}"
    LLAMA_TOOLCHAIN_OK=true
else
    echo -e "${YELLOW}   No C/C++ compiler found (needed to build llama-cpp-python). Installing...${NC}"
    # Every branch is `|| true`: under `set -e` a missing sudo or a declined
    # password would otherwise abort an install that can still finish without
    # GGUF. A failure here just leaves LLAMA_TOOLCHAIN_OK false.
    if [ "$PLATFORM" = "Linux" ]; then
        if command_exists apt-get; then
            _as_root apt-get install -y build-essential || true
        elif command_exists dnf; then
            _as_root dnf install -y gcc gcc-c++ make || true
        elif command_exists pacman; then
            _as_root pacman -S --needed --noconfirm base-devel || true
        elif command_exists zypper; then
            _as_root zypper install -y gcc gcc-c++ make || true
        fi
    elif [ "$PLATFORM" = "macOS" ]; then
        xcode-select --install 2>/dev/null || true
    fi
    if resolve_compilers; then
        echo -e "${GREEN}   Found: $CC_BIN, $CXX_BIN ✓${NC}"
        LLAMA_TOOLCHAIN_OK=true
    else
        echo -e "${RED}   Still no C/C++ compiler. GGUF support will be skipped.${NC}"
        echo -e "${YELLOW}   Install one and re-run, or pass --no-llama-cpp to silence this:${NC}"
        if [ "$PLATFORM" = "macOS" ]; then
            echo -e "${YELLOW}       xcode-select --install${NC}"
        elif command_exists dnf; then
            echo -e "${YELLOW}       sudo dnf install -y gcc gcc-c++ make${NC}"
        elif command_exists pacman; then
            echo -e "${YELLOW}       sudo pacman -S --needed base-devel${NC}"
        else
            echo -e "${YELLOW}       sudo apt-get install -y build-essential${NC}"
        fi
        echo -e "${YELLOW}   Or install every system dependency at once:${NC}"
        echo -e "${YELLOW}       bash install-deps.sh${NC}"
    fi
fi

# Check for Tk (tkinter)
#
# run_config_tool.py is a tkinter GUI, and tkinter is the one stdlib module distros
# routinely omit: it lives in a separate `-tk` package. A venv inherits the
# omission from the interpreter it was built on, so `pip install` cannot fix it
# afterwards — the package has to be there before myenv is created.
#
# Every detected interpreter is covered, not just the 3.12 this install will
# use. Which one run_config_tool.py ends up running under depends on the venv, on
# $INTENTIONED_PYTHON and on whatever the operator upgrades to next, and the
# packages are a few hundred KB each.
TK_MIN_MINOR=9
TK_MAX_MINOR=14

# tkinter's package name, most specific first. Debian/Fedora/SUSE split it per
# interpreter; Arch shares one system-wide `tk` that its `python` links against.
tk_packages_for() {
    local py="$1" nodot="${1//./}"
    if command_exists apt-get;   then echo "python${py}-tk python3-tk"
    elif command_exists dnf;     then echo "python${py}-tkinter python3-tkinter"
    elif command_exists pacman;  then echo "tk"
    elif command_exists zypper;  then echo "python${nodot}-tk python3-tk"
    elif [ "$PLATFORM" = "macOS" ]; then echo "python-tk@${py} python-tk"
    fi
}

install_tk_package() {
    local pkg
    for pkg in $(tk_packages_for "$1"); do
        if [ "$PLATFORM" = "macOS" ]; then
            brew install "$pkg" >/dev/null 2>&1 && return 0
        elif command_exists apt-get; then
            _as_root apt-get install -y "$pkg" >/dev/null 2>&1 && return 0
        elif command_exists dnf; then
            _as_root dnf install -y "$pkg" >/dev/null 2>&1 && return 0
        elif command_exists pacman; then
            _as_root pacman -S --needed --noconfirm "$pkg" >/dev/null 2>&1 && return 0
        elif command_exists zypper; then
            _as_root zypper --non-interactive install -y "$pkg" >/dev/null 2>&1 && return 0
        fi
    done
    return 1
}

# `import tkinter` alone is NOT a valid test. The pure-Python half of tkinter
# ships in the base stdlib, and removing the -tk package leaves the now-empty
# /usr/lib/pythonX.Y/tkinter/ directory behind — which Python then imports
# happily as a namespace package, __file__ = None and no Tk in sight. Import
# the C extension too, and touch an attribute that only the real __init__.py
# defines. Tk() is deliberately NOT constructed: that needs a display.
TK_PROBE='import tkinter, _tkinter; tkinter.Tk'

TK_MISSING=""
for _v in $(seq "$TK_MAX_MINOR" -1 "$TK_MIN_MINOR"); do
    _py="python3.$_v"
    command_exists "$_py" || continue
    if "$_py" -c "$TK_PROBE" >/dev/null 2>&1; then
        echo -e "${GREEN}   $_py: tkinter ✓${NC}"
        continue
    fi
    echo -e "${YELLOW}   $_py: tkinter missing, installing...${NC}"
    install_tk_package "3.$_v" || true
    if "$_py" -c "$TK_PROBE" >/dev/null 2>&1; then
        echo -e "${GREEN}   $_py: tkinter ✓${NC}"
    else
        echo -e "${YELLOW}   $_py: tkinter still missing${NC}"
        TK_MISSING="$TK_MISSING $_py"
    fi
done
if [ -n "$TK_MISSING" ]; then
    echo -e "${YELLOW}   Configuration tool needs tkinter; missing for:${TK_MISSING}${NC}"
    echo -e "${YELLOW}   Install it, then re-run:  bash install-deps.sh${NC}"
fi

# Create installation directory
echo -e "\n${YELLOW}[4/8] Creating installation directory...${NC}"

# With --skip-repo-download the checkout already exists and IS the install; step
# 5 resolves it. Creating (or migrating) the default path here would leave a
# stray empty directory behind and misreport the location afterwards.
if [ "$SKIP_REPO_DOWNLOAD" = true ]; then
    echo -e "${GREEN}   Using an existing checkout; nothing to create ✓${NC}"
else

# The app is installed directly into $INSTALL_PATH — there is no extra
# intentioned.tech/ level below it. Everything downstream (the launchers, the
# desktop entries, merge-dist.sh on upgrade) records this path, so resolve it to
# an absolute one first. A relative --install-path would otherwise produce
# launchers that only work from the directory the installer happened to run in,
# and a quoted "~/..." would create a directory literally named ~.
case "$INSTALL_PATH" in
    "~") INSTALL_PATH="$HOME" ;;
    "~/"*) INSTALL_PATH="$HOME/${INSTALL_PATH#\~/}" ;;
esac
mkdir -p "$INSTALL_PATH"
INSTALL_PATH="$(cd "$INSTALL_PATH" && pwd -P)"
echo -e "${GREEN}   Path: $INSTALL_PATH ✓${NC}"

# Migrate the old nested layout
#
# Installs made before the flattening put the app in
# $INSTALL_PATH/intentioned.tech and the launchers beside it. Left alone, a
# re-run would install afresh into $INSTALL_PATH and orphan the old tree —
# taking config.json, the activation token and the TLS material with it, which
# merge-dist.sh would no longer find to preserve. Lift the contents up instead.
LEGACY_PATH="$INSTALL_PATH/intentioned.tech"
if [ -d "$LEGACY_PATH" ] && [ -f "$LEGACY_PATH/requirements.txt" ]; then
    echo -e "${YELLOW}   Found the old nested layout at $LEGACY_PATH${NC}"
    echo -e "${YELLOW}   Moving it up into $INSTALL_PATH...${NC}"
    # Regenerated below, and they would collide with the move.
    rm -f "$INSTALL_PATH/start-intentioned.sh" "$INSTALL_PATH/config-intentioned.sh"
    (
        shopt -s dotglob nullglob
        mv "$LEGACY_PATH"/* "$INSTALL_PATH"/
    ) || {
        echo -e "${RED}   Could not move the old install. Nothing was changed.${NC}" >&2
        echo -e "${YELLOW}   Move it by hand, or install elsewhere with --install-path.${NC}" >&2
        exit 1
    }
    rmdir "$LEGACY_PATH" 2>/dev/null || true

    # A virtualenv bakes its own absolute path into the shebang of every console
    # script and into bin/activate, so the move breaks it: bin/python is a
    # symlink and still resolves, but ./myenv/bin/pip now starts with a
    # `#!/old/path/myenv/bin/python3.12` that no longer exists.
    #
    # Rewriting those strings is what saves re-downloading several GB of torch.
    # `python -m venv` over the existing directory does NOT do it — ensurepip
    # skips pip when pip is already installed, so it exits 0 having changed
    # nothing, and every console script keeps the stale shebang.
    if [ -d "$INSTALL_PATH/myenv" ]; then
        echo -e "${YELLOW}   Relocating the virtualenv to its new path...${NC}"
        "$PYTHON_BIN" - "$INSTALL_PATH/myenv" "$LEGACY_PATH/myenv" "$INSTALL_PATH/myenv" <<'PY' || true
import os, sys

venv, old, new = sys.argv[1:4]
old_b, new_b = old.encode(), new.encode()

targets = [os.path.join(venv, "pyvenv.cfg")]
bindir = os.path.join(venv, "bin")
if os.path.isdir(bindir):
    targets += [os.path.join(bindir, n) for n in os.listdir(bindir)]

for path in targets:
    # Symlinks point outside the venv (bin/python -> the base interpreter);
    # following one would rewrite a file that is not ours.
    if not os.path.isfile(path) or os.path.islink(path):
        continue
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError:
        continue
    if b"\0" in data or old_b not in data:
        continue
    with open(path, "wb") as fh:
        fh.write(data.replace(old_b, new_b))
PY
        if "$INSTALL_PATH/myenv/bin/pip" --version >/dev/null 2>&1; then
            echo -e "${GREEN}   Virtualenv relocated ✓${NC}"
        else
            echo -e "${YELLOW}   Relocation failed; rebuilding it (dependencies re-download).${NC}"
            rm -rf "$INSTALL_PATH/myenv"
        fi
    fi
    echo -e "${GREEN}   Migrated to the flat layout ✓${NC}"
fi

fi  # end --skip-repo-download guard

# Clone or update repository
if [ "$SKIP_REPO_DOWNLOAD" = true ]; then
    if [ -n "$REPO_PATH_CLI" ]; then
        REPO_PATH="$(cd "$REPO_PATH_CLI" && pwd -P)"
    else
        REPO_PATH="$(pwd -P)"
    fi
    echo -e "\n${YELLOW}[5/8] Skipping repository download (--skip-repo-download)${NC}"
    if [ ! -f "$REPO_PATH/requirements.txt" ]; then
        echo -e "${RED}   No project checkout at:${NC}"
        echo -e "${RED}   $REPO_PATH${NC}" >&2
        echo -e "${YELLOW}   cd into the intentioned.tech repo and run again, or use:${NC}"
        echo -e "${YELLOW}     --skip-repo-download --repo-path /path/to/intentioned.tech${NC}" >&2
        exit 1
    fi
    # The checkout is the install: keep the two in step so the launchers and the
    # closing summary name the directory the app actually runs from.
    INSTALL_PATH="$REPO_PATH"
    echo -e "${GREEN}   Using existing repo: $REPO_PATH ✓${NC}"
elif [ "$SOURCE_MODE" = "git" ]; then
    # Maintainer path only: this clones the full proprietary source. It is NOT
    # how a customer installs — see the release path below.
    if [ -n "$REPO_PATH_CLI" ]; then
        echo -e "${RED}   --repo-path is only valid with --skip-repo-download${NC}" >&2
        exit 1
    fi
    REPO_PATH="$INSTALL_PATH"
    echo -e "\n${YELLOW}[5/8] Cloning source (--from-git)...${NC}"
    # MAINTAINERS ONLY. The source repo is private, so this path fails with an
    # authentication error for anyone without access — which is intended. It is
    # not a customer install route; customers use release mode (the default).
    # INTENTIONED_SOURCE_REPO lets a maintainer point at a fork or SSH remote.
    SOURCE_REPO="${INTENTIONED_SOURCE_REPO:-git@github.com:intentioned-tech/intentioned.tech.git}"
    if [ -d "$REPO_PATH" ]; then
        echo -e "${YELLOW}   Updating existing checkout...${NC}"
        (cd "$REPO_PATH" && git pull)
    else
        echo -e "${YELLOW}   Note: --from-git is for maintainers; the source repo is private.${NC}"
        git clone "$SOURCE_REPO" "$REPO_PATH"
    fi
    echo -e "${GREEN}   Cloned ✓${NC}"
else
    # ── Release mode (default) ────────────────────────────────────────────────
    #
    # Fetches the compiled build this account is entitled to from the private
    # R2 bucket, through the licence Worker's authenticated routes. This
    # replaces a `git clone` of the source repo, which handed every customer the
    # full proprietary tree and only worked while that repo stayed public.
    #
    # The bucket has no public URL. The caller never names an object key either:
    # the Worker resolves the key from the account's entitlement, so there is no
    # path to traverse and no way to fetch another customer's build.
    if [ -n "$REPO_PATH_CLI" ]; then
        echo -e "${RED}   --repo-path is only valid with --skip-repo-download${NC}" >&2
        exit 1
    fi
    REPO_PATH="$INSTALL_PATH"
    echo -e "\n${YELLOW}[5/8] Downloading your licensed build...${NC}"

    command_exists curl || { echo -e "${RED}   curl is required to download the release.${NC}" >&2; exit 1; }
    if ! command_exists zstd && ! tar --help 2>/dev/null | grep -q zstd; then
        echo -e "${RED}   zstd is required to unpack the release (tar.zst).${NC}" >&2
        echo -e "${YELLOW}   Install it: apt-get install zstd | dnf install zstd | pacman -S zstd${NC}" >&2
        exit 1
    fi

    WORKER_URL="${WORKER_URL%/}"
    # Prompt on /dev/tty, not stdin. This script is meant to be runnable as
    # `curl ... | bash`, where stdin IS the script — a bare `read` would swallow
    # the rest of the installer instead of waiting for the operator. If there is
    # no terminal at all (CI, provisioning), fall through to the error below and
    # tell them which env vars to set.
    if [ -t 0 ] || [ -e /dev/tty ]; then
        [ -n "$REL_USERNAME" ] || read -r -p "   Licence username: " REL_USERNAME < /dev/tty || true
        if [ -z "$REL_PASSWORD" ]; then
            read -r -s -p "   Licence password: " REL_PASSWORD < /dev/tty || true
            echo
        fi
    fi
    if [ -z "$REL_USERNAME" ] || [ -z "$REL_PASSWORD" ]; then
        echo -e "${RED}   Username and password are required to download a build.${NC}" >&2
        echo -e "${YELLOW}   Non-interactive: INTENTIONED_USERNAME=... INTENTIONED_PASSWORD=... bash install.sh${NC}" >&2
        exit 1
    fi

    DL_WORK="$(mktemp -d)"
    trap 'rm -rf "$DL_WORK"' EXIT
    # Credentials go in a mode-600 curl config, never in argv: /proc/*/cmdline is
    # world-readable, so a password on the command line leaks to every local user.
    AUTHFILE="$DL_WORK/curl-auth"
    : > "$AUTHFILE"; chmod 600 "$AUTHFILE"
    printf 'user = "%s:%s"\n' "$REL_USERNAME" "$REL_PASSWORD" >> "$AUTHFILE"

    echo -e "${YELLOW}   Checking entitlement: $WORKER_URL/api/v1/update/check${NC}"
    printf '{"current_version":null}' > "$DL_WORK/check-req.json"
    HTTP="$(curl -sS --retry 3 --max-time 60 -K "$AUTHFILE" \
        -o "$DL_WORK/check.json" -w '%{http_code}' \
        -H 'content-type: application/json' \
        --data-binary "@$DL_WORK/check-req.json" \
        "$WORKER_URL/api/v1/update/check" || echo 000)"
    if [ "$HTTP" = "401" ]; then
        echo -e "${RED}   Authentication failed — check the username and password.${NC}" >&2; exit 1
    elif [ "$HTTP" != "200" ]; then
        echo -e "${RED}   Entitlement check failed (HTTP $HTTP).${NC}" >&2
        [ -s "$DL_WORK/check.json" ] && head -c 400 "$DL_WORK/check.json" >&2 && echo >&2
        exit 1
    fi

    # Parse with the interpreter already located in [1/8] rather than adding a
    # jq dependency for three fields.
    REL_VERSION="$("$PYTHON_BIN" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("version") or "")' "$DL_WORK/check.json")"
    REL_SHA256="$("$PYTHON_BIN" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("sha256") or "")' "$DL_WORK/check.json")"
    if [ -z "$REL_VERSION" ]; then
        echo -e "${RED}   No release is available for this account.${NC}" >&2
        "$PYTHON_BIN" -c 'import json,sys;print("   "+(json.load(open(sys.argv[1])).get("message") or ""))' "$DL_WORK/check.json" >&2 || true
        exit 1
    fi
    echo -e "${GREEN}   Entitled to version $REL_VERSION ✓${NC}"

    # ?version= pins the bytes to what the check returned, so a release published
    # between the two calls cannot swap them under the hash we verify next.
    # -C - resumes a partial download rather than restarting a multi-GB transfer.
    echo -e "${YELLOW}   Downloading (resumable)...${NC}"
    HTTP="$(curl -sS --retry 3 --retry-delay 5 --max-time 3600 -C - -K "$AUTHFILE" \
        -o "$DL_WORK/release.tar.zst" -w '%{http_code}' --progress-bar \
        "$WORKER_URL/api/v1/update/download?version=$REL_VERSION" || echo 000)"
    case "$HTTP" in
        200|206) ;;
        409) echo -e "${RED}   A new release was published mid-download; re-run the installer.${NC}" >&2; exit 1 ;;
        *)   echo -e "${RED}   Download failed (HTTP $HTTP).${NC}" >&2; exit 1 ;;
    esac

    if [ -n "$REL_SHA256" ]; then
        echo -e "${YELLOW}   Verifying checksum...${NC}"
        GOT="$("$PYTHON_BIN" - "$DL_WORK/release.tar.zst" <<'PY'
import hashlib, sys
h = hashlib.sha256()
with open(sys.argv[1], "rb") as fh:
    for chunk in iter(lambda: fh.read(1 << 20), b""):
        h.update(chunk)
print(h.hexdigest())
PY
)"
        if [ "$GOT" != "$REL_SHA256" ]; then
            echo -e "${RED}   Checksum mismatch — refusing to install.${NC}" >&2
            echo -e "${RED}     expected $REL_SHA256${NC}" >&2
            echo -e "${RED}     got      $GOT${NC}" >&2
            exit 1
        fi
        echo -e "${GREEN}   Checksum verified ✓${NC}"
    else
        echo -e "${YELLOW}   Release registry published no sha256; skipping verification.${NC}"
    fi

    # Unpack beside the target and swap, so a failed extraction cannot leave a
    # half-written install where a working one used to be.
    STAGE="$DL_WORK/stage"; mkdir -p "$STAGE"
    tar --zstd -xf "$DL_WORK/release.tar.zst" -C "$STAGE" \
        || { echo -e "${RED}   Failed to unpack the release archive.${NC}" >&2; exit 1; }
    # Releases are packed with a single top-level directory; tolerate both shapes.
    SRC_ROOT="$STAGE"
    if [ "$(find "$STAGE" -maxdepth 1 -mindepth 1 | wc -l)" -eq 1 ]; then
        _only="$(find "$STAGE" -maxdepth 1 -mindepth 1)"
        [ -d "$_only" ] && SRC_ROOT="$_only"
    fi

    mkdir -p "$(dirname "$REPO_PATH")"
    if [ -d "$REPO_PATH" ]; then
        # merge-dist.sh owns in-place upgrades precisely because it preserves
        # config.json, credentials and TLS material. Do not re-implement that
        # here; hand over to it when it is present.
        #
        # It takes NO positional arguments: the source is --from and the
        # destination is only ever $INTENTIONED_DIST (its built-in default is a
        # ../intentioned.tech_cython_dist sibling of its own location, which is
        # wrong for every installed layout). Passing paths positionally makes it
        # exit 1 on "Unknown option" before it copies anything. Keep this call
        # byte-compatible with updater.sh's — they drive the same script.
        #
        # Tested with -f, not -x: package-cython.sh chmods it best-effort
        # (`2>/dev/null || true`), so a release unpacked under a restrictive
        # umask can ship it non-executable — and falling through to the else
        # branch would then move the live install out from under a running
        # server rather than merging into it.
        if [ -f "$REPO_PATH/merge-dist.sh" ]; then
            echo -e "${YELLOW}   Existing install found — merging via merge-dist.sh (preserves settings)...${NC}"
            INTENTIONED_DIST="$REPO_PATH" bash "$REPO_PATH/merge-dist.sh" --from "$SRC_ROOT" \
                || { echo -e "${RED}   merge-dist.sh failed.${NC}" >&2; exit 1; }
        else
            echo -e "${YELLOW}   Existing install found — backing it up to $REPO_PATH.bak${NC}"
            rm -rf "$REPO_PATH.bak"; mv "$REPO_PATH" "$REPO_PATH.bak"
            mv "$SRC_ROOT" "$REPO_PATH"
        fi
    else
        mv "$SRC_ROOT" "$REPO_PATH"
    fi

    # Stamp the version marker updater.sh reads. Without it the updater falls
    # back to config.json's version field — but config.json is preserved across
    # merges by design (it holds operator secrets), so that field never advances
    # and the nightly updater would re-download and re-merge the release we just
    # installed, every night, until the next one ships.
    echo "$REL_VERSION" > "$REPO_PATH/.installed_version" 2>/dev/null || true

    rm -rf "$DL_WORK"; trap - EXIT
    echo -e "${GREEN}   Installed build $REL_VERSION to $REPO_PATH ✓${NC}"
fi

# Create virtual environment and install dependencies
echo -e "\n${YELLOW}[6/8] Installing Python dependencies...${NC}"
cd "$REPO_PATH"
# Test the interpreter, not the directory. `[ ! -d myenv ]` alone treats a venv
# whose interpreter has vanished as usable, and every later ./myenv/bin/pip call
# then fails with a bare "No such file or directory". That is not hypothetical:
# a distro upgrade that retires the old minor version deletes the very binary
# these symlinks point at, leaving a full 9 GB tree with a dangling bin/python.
if ! ./myenv/bin/python -c 'import sys; sys.exit(0 if sys.version_info[:2]==(3,12) else 1)' 2>/dev/null; then
    if [ -d "myenv" ]; then
        echo -e "${YELLOW}   Existing myenv is unusable (missing or non-3.12 interpreter); rebuilding.${NC}"
        echo -e "${YELLOW}   The previous tree is kept at myenv.broken until this install succeeds.${NC}"
        rm -rf myenv.broken
        mv myenv myenv.broken
    fi
    "$PYTHON_BIN" -m venv myenv || {
        echo -e "${RED}   Could not create the virtualenv with $PYTHON_BIN.${NC}"
        echo -e "${RED}   On Debian/Ubuntu this usually means python3.12-venv is missing.${NC}"
        exit 1
    }
fi
# ROCm wheels use manylinux_2_28; pip < 24 often reports "No matching distribution"
# for torchvision/torchaudio even when wheels exist. Keep setuptools/wheel current too.
./myenv/bin/pip install --upgrade 'pip>=24.2' setuptools wheel

SELECTED_BACKEND="$(detect_backend)"
echo -e "${YELLOW}   Selected PyTorch backend: ${SELECTED_BACKEND}${NC}"

case "$SELECTED_BACKEND" in
    cuda)
        echo -e "${YELLOW}   Installing PyTorch with CUDA 13.0 support...${NC}"
        # PyTorch 2.11.0 requires setuptools<82, nv-one-logger requires setuptools>=79
        ./myenv/bin/pip install 'setuptools>=79,<82' >/dev/null 2>&1 || true
        ./myenv/bin/pip install --no-cache-dir \
            torch==2.11.0 torchvision==0.26.0 torchaudio==2.11.0 \
            --index-url https://download.pytorch.org/whl/cu130
        echo -e "${YELLOW}   Installing NVIDIA-only acceleration packages...${NC}"
        ./myenv/bin/pip install 'cuda-python>=12.9.0' 'bitsandbytes>=0.49.1' || \
            echo -e "${YELLOW}   Optional CUDA acceleration packages failed; continuing.${NC}"
        ;;
    rocm)
        echo -e "${YELLOW}   Installing PyTorch with AMD ROCm 7.2.1 support...${NC}"
        ./myenv/bin/pip uninstall -y torch torchvision torchaudio pytorch-triton-rocm >/dev/null 2>&1 || true
        # Pin a matched trio from the ROCm index so pip always resolves consistent wheels
        # (open requirements can yield "No matching distribution" for torchvision on some setups).
        ./myenv/bin/pip install --no-cache-dir \
            torch==2.9.1 torchvision==0.24.1 torchaudio==2.9.1 \
            --index-url https://download.pytorch.org/whl/rocm7.2
        echo -e "${YELLOW}   Removing CUDA-only packages if present...${NC}"
        ./myenv/bin/pip uninstall -y bitsandbytes cuda-python >/dev/null 2>&1 || true
        ;;
    cpu)
        echo -e "${YELLOW}   Installing PyTorch CPU/macOS wheels...${NC}"
        ./myenv/bin/pip install torch torchvision torchaudio
        ;;
esac

./myenv/bin/pip install -r requirements.txt

# Drop the GPL-3.0 G2P extras that arrive transitively.
#
# Dropping `misaki[en]` from requirements.txt is NOT enough: `kokoro` itself
# declares `Requires-Dist: misaki[en]>=0.9.4`, and that extra requires
# phonemizer-fork and espeakng-loader — the latter bundling a GPL-3.0
# libespeak-ng.so. So they come back on every clean install no matter how
# requirements.txt lists misaki. pip has no "install this but not that extra",
# hence removing them afterwards.
#
# Kokoro keeps working: server.py::_ensure_kokoro_importable() seeds a GPL-free
# stub for `misaki.espeak`, and Kokoro's own try/except then falls back to its
# documented degraded mode. The only cost is that out-of-dictionary English
# words are skipped rather than guessed at.
#
# Operators who are NOT redistributing and want full G2P coverage can opt back
# in — it is a licensing decision, not a dependency one:
#     ./myenv/bin/pip install phonemizer-fork espeakng_loader
./myenv/bin/pip uninstall -y -q phonemizer-fork espeakng-loader >/dev/null 2>&1 || true

# requirements.txt can pull optional deps; keep AMD stacks free of NVIDIA-only wheels.
if [ "$SELECTED_BACKEND" = "rocm" ]; then
    echo -e "${YELLOW}   Removing CUDA-only Python packages (NeMo/ROCm hosts have no libcuda.so.1)...${NC}"
    ./myenv/bin/pip uninstall -y bitsandbytes cuda-python >/dev/null 2>&1 || true
fi

if [ "$INSTALL_LLAMA_CPP" = true ] && [ "$LLAMA_TOOLCHAIN_OK" = true ]; then
    echo -e "${YELLOW}   Building llama-cpp-python for ${SELECTED_BACKEND} (GGUF support)...${NC}"

    # Pin the toolchain resolved in [3/8] two ways: exported, so scikit-build-core
    # leaves its sysconfig CC/CXX defaults alone, and as cache variables, so an
    # inherited CC/CXX from the caller's shell cannot win either.
    export CC="$CC_BIN"
    export CXX="$CXX_BIN"
    LLAMA_COMPILER_ARGS="-DCMAKE_C_COMPILER=${CC_BIN} -DCMAKE_CXX_COMPILER=${CXX_BIN}"

    # Shared last resort. A CPU-only build still loads GGUF models — it only
    # gives up GPU offload — so it beats disabling GGUF outright. Any arguments
    # are appended to CMAKE_ARGS, for backend-specific flags to switch off.
    _llama_cpu_fallback() {
        echo -e "${YELLOW}   Falling back to a CPU-only llama-cpp-python build (GGUF works, no GPU offload)...${NC}"
        FORCE_CMAKE=1 CMAKE_ARGS="-DGGML_CUDA=OFF ${LLAMA_COMPILER_ARGS} $*" \
            ./myenv/bin/pip install --upgrade --no-cache-dir --no-binary llama-cpp-python \
            'llama-cpp-python>=0.3.0' || \
            echo -e "${YELLOW}   llama-cpp-python CPU build failed; GGUF disabled.${NC}"
    }

    # CUDA's host_config.h caps the supported host GCC (e.g. CUDA 13.x
    # rejects GCC 16). On rolling-release distros (Arch/CachyOS) the
    # system gcc can exceed that cap, failing the build with
    # "unsupported GNU version". Detect a compatible older gcc-N/g++-N
    # and pin it as the CUDA host compiler (and C/C++ compiler, so the
    # host and device object files share one libstdc++ ABI).
    _llama_cuda_build() {
        CUDA_HOST_ARGS=""
        _maxg=15
        _hc="$(dirname "$(dirname "$(readlink -f "$(command -v nvcc 2>/dev/null)" 2>/dev/null)")" 2>/dev/null)/targets/x86_64-linux/include/crt/host_config.h"
        if [ -f "$_hc" ]; then
            _g="$(grep -oE '__GNUC__ > [0-9]+' "$_hc" | grep -oE '[0-9]+' | head -1)"
            [ -n "$_g" ] && _maxg="$_g"
        fi
        _curg="$(gcc -dumpversion 2>/dev/null | cut -d. -f1)"
        if [ -n "$_curg" ] && [ "$_curg" -gt "$_maxg" ]; then
            for _v in $(seq "$_maxg" -1 9); do
                if command -v "gcc-$_v" >/dev/null 2>&1 && command -v "g++-$_v" >/dev/null 2>&1; then
                    CUDA_HOST_ARGS="-DCMAKE_C_COMPILER=$(command -v "gcc-$_v") -DCMAKE_CXX_COMPILER=$(command -v "g++-$_v") -DCMAKE_CUDA_HOST_COMPILER=$(command -v "g++-$_v")"
                    echo -e "${YELLOW}   System gcc $_curg > CUDA max $_maxg; pinning gcc-$_v as CUDA host compiler.${NC}"
                    break
                fi
            done
            [ -z "$CUDA_HOST_ARGS" ] && echo -e "${YELLOW}   System gcc $_curg > CUDA max $_maxg and no older gcc-N found; CUDA build may fail. Install gcc-$_maxg (e.g. 'gcc15' on Arch).${NC}"
        fi
        CMAKE_ARGS="-DGGML_CUDA=on ${CUDA_HOST_ARGS:-$LLAMA_COMPILER_ARGS}" \
            ./myenv/bin/pip install --upgrade --no-cache-dir 'llama-cpp-python>=0.3.0'
    }

    case "$SELECTED_BACKEND" in
        cuda)
            # GGML_CUDA=on turns on CMake's CUDA language, which needs nvcc — and
            # the backend was detected from nvidia-smi, which ships with the
            # driver, not the toolkit. Distro CUDA packages land on PATH; the
            # .run and network installers put nvcc under /usr/local/cuda instead.
            #
            # A machine can carry both: Ubuntu 24.04's nvidia-cuda-toolkit is
            # still CUDA 12, so a box that also has a current toolkit from
            # NVIDIA's repository has an old /usr/bin/nvcc shadowing the new
            # /usr/local/cuda/bin/nvcc. PATH order alone would build against the
            # older one, so compare the two and take the newer.
            _nvcc_version() {
                "$1" --version 2>/dev/null |
                    sed -n 's/.*release \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1
            }
            if [ -x /usr/local/cuda/bin/nvcc ]; then
                _path_nvcc="$(command -v nvcc 2>/dev/null || true)"
                _local_v="$(_nvcc_version /usr/local/cuda/bin/nvcc)"
                _path_v="$(_nvcc_version "${_path_nvcc:-/nonexistent}")"
                if [ -z "$_path_nvcc" ] || {
                        [ -n "$_local_v" ] && [ "$_path_v" != "$_local_v" ] &&
                        [ "$(printf '%s\n%s\n' "$_path_v" "$_local_v" | sort -V | tail -1)" = "$_local_v" ]
                   }; then
                    export PATH="/usr/local/cuda/bin:$PATH"
                fi
            fi
            if command_exists nvcc; then
                _nv="$(_nvcc_version "$(command -v nvcc)")"
                echo -e "${GREEN}   Using CUDA $_nv from $(command -v nvcc)${NC}"
                # Minor versions are compatible within a major release, so only a
                # major-version gap is a real problem: it compiles, then fails to
                # initialise CUDA at runtime.
                _drv="$(nvidia-smi 2>/dev/null |
                    sed -n 's/.*CUDA Version:[[:space:]]*\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1)"
                if [ -n "$_drv" ] && [ -n "$_nv" ] && [ "${_nv%%.*}" -gt "${_drv%%.*}" ] 2>/dev/null; then
                    echo -e "${YELLOW}   Warning: the driver supports only up to CUDA $_drv.${NC}"
                    echo -e "${YELLOW}   A CUDA $_nv build will compile but fail to run. Update the${NC}"
                    echo -e "${YELLOW}   driver, or install a matching toolkit:${NC}"
                    echo -e "${YELLOW}       bash install-deps.sh --cuda-version $_drv${NC}"
                fi
            fi
            if ! command_exists nvcc; then
                echo -e "${YELLOW}   nvcc not found: NVIDIA driver present but no CUDA toolkit.${NC}"
                echo -e "${YELLOW}   Install the CUDA toolkit and re-run to get GPU offload for GGUF.${NC}"
                _llama_cpu_fallback
            elif ! _llama_cuda_build; then
                echo -e "${YELLOW}   llama-cpp-python CUDA build failed.${NC}"
                _llama_cpu_fallback
            fi
            ;;
        rocm)
            # Prebuilt manylinux wheels may link libcuda.so.1; AMD boxes have no NVIDIA
            # driver, so import fails and server.py reports GGUF "not installed". Force a
            # local build: disable GGML_CUDA, prefer HIPBLAS, fall back to CPU-only.
            echo -e "${YELLOW}   Removing any pip wheel llama-cpp-python (rebuild from source)...${NC}"
            ./myenv/bin/pip uninstall -y llama-cpp-python >/dev/null 2>&1 || true
            ROCM_LLAMA_BASE="-DGGML_CUDA=OFF"
            ROCM_GFX="$(rocminfo 2>/dev/null | grep -oE 'gfx[0-9a-f]+' | head -1 || true)"
            _rocm_llama_cpu_fallback() {
                echo -e "${YELLOW}   HIP llama-cpp-python failed; trying CPU-only (GGUF still works)...${NC}"
                _llama_cpu_fallback -DGGML_HIPBLAS=OFF
            }
            if [ -n "$ROCM_GFX" ]; then
                FORCE_CMAKE=1 CMAKE_ARGS="${ROCM_LLAMA_BASE} -DGGML_HIPBLAS=on -DAMDGPU_TARGETS=${ROCM_GFX} -DCMAKE_C_COMPILER=hipcc -DCMAKE_CXX_COMPILER=hipcc" \
                    ./myenv/bin/pip install --upgrade --no-cache-dir --no-binary llama-cpp-python \
                    'llama-cpp-python>=0.3.0' || \
                    {
                        echo -e "${YELLOW}   ROCm HIP build with target ${ROCM_GFX} failed; retrying without AMDGPU_TARGETS...${NC}"
                        FORCE_CMAKE=1 CMAKE_ARGS="${ROCM_LLAMA_BASE} -DGGML_HIPBLAS=on -DCMAKE_C_COMPILER=hipcc -DCMAKE_CXX_COMPILER=hipcc" \
                            ./myenv/bin/pip install --upgrade --no-cache-dir --no-binary llama-cpp-python \
                            'llama-cpp-python>=0.3.0' || _rocm_llama_cpu_fallback
                    }
            else
                FORCE_CMAKE=1 CMAKE_ARGS="${ROCM_LLAMA_BASE} -DGGML_HIPBLAS=on -DCMAKE_C_COMPILER=hipcc -DCMAKE_CXX_COMPILER=hipcc" \
                    ./myenv/bin/pip install --upgrade --no-cache-dir --no-binary llama-cpp-python \
                    'llama-cpp-python>=0.3.0' || _rocm_llama_cpu_fallback
            fi
            ;;
        cpu)
            CMAKE_ARGS="-DGGML_CUDA=OFF ${LLAMA_COMPILER_ARGS}" \
                ./myenv/bin/pip install --upgrade --no-cache-dir 'llama-cpp-python>=0.3.0' || \
                echo -e "${YELLOW}   llama-cpp-python CPU build failed; GGUF disabled.${NC}"
            ;;
    esac
elif [ "$INSTALL_LLAMA_CPP" = true ]; then
    echo -e "${YELLOW}   Skipping llama-cpp-python: no C/C++ compiler (see [3/8]). GGUF models will not load.${NC}"
else
    echo -e "${YELLOW}   Skipping llama-cpp-python (--no-llama-cpp). GGUF models will not load.${NC}"
fi

if [ -n "$GGUF_MODEL" ]; then
    echo -e "${YELLOW}   Configuring GGUF LLM: ${GGUF_MODEL}${NC}"
    GGUF_MODEL="$GGUF_MODEL" ./myenv/bin/python - <<'PY'
import json
import os
from pathlib import Path

raw = os.environ.get("GGUF_MODEL", "").strip()
if not raw:
    raise SystemExit(0)

path = Path("config.json")
if path.exists():
    try:
        config = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        config = {}
else:
    try:
        from config_tool import DEFAULT_CONFIG
        config = json.loads(json.dumps(DEFAULT_CONFIG))
    except Exception:
        config = {}

models = config.setdefault("models", {})

if raw.lower().endswith(".gguf") and os.path.sep in raw and not raw.startswith(("http://", "https://")):
    # Local filesystem path.
    models["llm_model_id"] = raw
    models["llm_gguf_filename"] = ""
elif ":" in raw and not raw.lower().endswith(".gguf"):
    repo, _, filename = raw.partition(":")
    models["llm_model_id"] = repo
    models["llm_gguf_filename"] = filename
else:
    models["llm_model_id"] = raw
    models["llm_gguf_filename"] = models.get("llm_gguf_filename", "")

models["llm_runtime"] = "llama_cpp"
print(f"   GGUF model -> {models['llm_model_id']}  filename={models['llm_gguf_filename']!r}")

path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
PY
fi

if [ "$SELECTED_BACKEND" = "rocm" ]; then
    echo -e "${YELLOW}   Configuring ROCm defaults (16bit quantization)...${NC}"
    ./myenv/bin/python - <<'PY'
import json
from pathlib import Path

path = Path("config.json")
if path.exists():
    try:
        config = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        config = {}
else:
    try:
        from config_tool import DEFAULT_CONFIG
        config = json.loads(json.dumps(DEFAULT_CONFIG))
    except Exception:
        config = {}

advanced = config.setdefault("advanced", {})
hardware = config.setdefault("hardware", {})
models = config.setdefault("models", {})
summarization = config.setdefault("summarization", {})

advanced["compute_backend"] = "rocm"
hardware["use_gpu"] = True
hardware["use_cpu"] = False
models["quantization_type"] = "16bit"
models["analysis_quantization_type"] = "16bit"

ROCM_FRIENDLY_LLM = "Qwen/Qwen2.5-3B-Instruct"
ROCM_FRIENDLY_SUMMARIZER = "Qwen/Qwen2.5-1.5B-Instruct"

OVERSIZED_FOR_16GB = (
    "google/gemma-4-e4b-it",
    "google/gemma-4-E4B-it",
    "meta-llama/Llama-3.2-7B-Instruct",
    "Qwen/Qwen2.5-7B-Instruct",
    "mistralai/Mistral-7B-Instruct-v0.3",
)

current_llm = (models.get("llm_model_id") or "").strip()
if not current_llm or current_llm in OVERSIZED_FOR_16GB:
    print(f"   ROCm: pinning llm_model_id -> {ROCM_FRIENDLY_LLM}")
    models["llm_model_id"] = ROCM_FRIENDLY_LLM

current_analysis = (models.get("analysis_model_id") or "").strip()
if not current_analysis or current_analysis in OVERSIZED_FOR_16GB:
    print(f"   ROCm: pinning analysis_model_id -> {ROCM_FRIENDLY_LLM}")
    models["analysis_model_id"] = ROCM_FRIENDLY_LLM

current_summ = (summarization.get("model_id") or "").strip()
if not current_summ or current_summ in OVERSIZED_FOR_16GB:
    print(f"   ROCm: pinning summarization.model_id -> {ROCM_FRIENDLY_SUMMARIZER}")
    summarization["model_id"] = ROCM_FRIENDLY_SUMMARIZER

summarization["quantization_type"] = "16bit"

path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
PY
fi
echo -e "${GREEN}   Dependencies installed ✓${NC}"

# The server entry point
#
# This installer targets the Cython dist, whose entry point is run_server.py.
# Named once here so the unit file, both launchers, the desktop entries and the
# post-install config launch all agree; getting this wrong is what produced a
# restart-looping service with "can't open file '.../server.py': [Errno 2] No
# such file or directory".
SERVER_ENTRY="run_server.py"
CONFIG_ENTRY="run_config_tool.py"
SERVER_DIR="$INSTALL_PATH"

for _e in "$SERVER_ENTRY" "$CONFIG_ENTRY"; do
    if [ -f "$SERVER_DIR/$_e" ]; then
        echo -e "${GREEN}   Entry point: ${SERVER_DIR}/${_e} ✓${NC}"
    else
        echo -e "${RED}   ${SERVER_DIR}/${_e} is missing — the install looks incomplete.${NC}"
        echo -e "${YELLOW}   The launchers will still be written pointing at it.${NC}"
    fi
done

# Setup the systemd service, and passwordless sudo to restart it
echo -e "\n${YELLOW}[7/8] Setting up systemd units...${NC}"
CURRENT_USER=$(whoami)
SUDOERS_FILE="/etc/sudoers.d/intentioned-restart"
UNIT_MANIFEST="$INSTALL_PATH/.installed_units"
SERVICE_INSTALLED=false
SERVICE_NAME_DEFAULT="intentioned-server.service"
INSTALLED_UNITS=""
INSTALLED_SERVICES=""
ONESHOT_UNITS=""
TIMER_UNITS=""

if [ "$PLATFORM" != "Linux" ]; then
    echo -e "${YELLOW}   Skipping systemd and sudoers setup (not supported on ${PLATFORM}).${NC}"
    echo -e "${YELLOW}   Use the 'intentioned' launcher to run the app in the foreground.${NC}"
elif [ "$INSTALL_SYSTEMD_SERVICE" != true ]; then
    echo -e "${YELLOW}   Skipping (--no-systemd-service). Use the 'intentioned' launcher instead.${NC}"
elif ! command_exists systemctl; then
    echo -e "${YELLOW}   No systemd on this system; skipping. Use the 'intentioned' launcher instead.${NC}"
else
    # The release ships its own unit files — the server, the nightly updater and
    # its timer. Install those rather than generating one here: they are part of
    # the build and change with it, so a unit written by this script would drift
    # from whatever the release actually expects.
    #
    # systemd/ beside the app is where the release puts them. Checked by name
    # first so the common case does not depend on the recursive search below
    # behaving, and so the searched locations can be named when nothing is
    # found. The sibling form covers a layout where the app directory and the
    # systemd directory sit next to each other rather than one inside the other.
    UNIT_SEARCH_DIRS=""
    for _ud in "$SERVER_DIR/systemd" "$INSTALL_PATH/systemd" "$(dirname "$INSTALL_PATH")/intentioned/systemd"; do
        case " $UNIT_SEARCH_DIRS " in
            *" $_ud "*) ;;
            *) UNIT_SEARCH_DIRS="$UNIT_SEARCH_DIRS $_ud" ;;
        esac
    done
    # The units are shipped as templates, so the filename carries a suffix past
    # the unit type — intentioned-server.service.template and the like. Matching
    # only bare *.service found nothing at all. Both forms are accepted, and the
    # unit name is whatever precedes the .service / .timer.
    #
    # Editor and packaging leftovers sitting beside a template would otherwise
    # be installed as if they were units.
    _unit_name_for() {
        local _n
        _n="$(basename "$1")"
        case "$_n" in
            *.service|*.service.*) echo "${_n%%.service*}.service" ;;
            *.timer|*.timer.*)     echo "${_n%%.timer*}.timer" ;;
        esac
    }

    _is_junk() {
        case "$1" in
            *~|*.bak|*.orig|*.rej|*.swp|*.dpkg-*|*.rpm*|*.disabled) return 0 ;;
        esac
        return 1
    }

    # Deduplicated by resolved unit name, not by path: with both a rendered
    # foo.service and a foo.service.template present, the bare file is already
    # the output and is taken, since the plain globs are listed first.
    DIST_UNITS=""
    _seen_units=""
    _collect_unit() {
        local _src="$1" _name
        [ -f "$_src" ] || return 0
        _is_junk "$_src" && return 0
        _name="$(_unit_name_for "$_src")"
        [ -n "$_name" ] || return 0
        case " $_seen_units " in
            *" $_name "*) return 0 ;;
        esac
        _seen_units="$_seen_units $_name"
        DIST_UNITS="$DIST_UNITS $_src"
    }

    for _ud in $UNIT_SEARCH_DIRS; do
        [ -d "$_ud" ] || continue
        for _uf in "$_ud"/*.service "$_ud"/*.timer "$_ud"/*.service.* "$_ud"/*.timer.*; do
            _collect_unit "$_uf"
        done
    done

    # Anywhere else under the install tree, for a release that moves them.
    # myenv is pruned: a virtualenv can contain unit files belonging to
    # unrelated packages.
    if [ -z "$DIST_UNITS" ]; then
        for _uf in $(find "$SERVER_DIR" -maxdepth 6 \
            \( -type d -name myenv -prune \) -o \
            \( -type f \( -name '*.service' -o -name '*.timer' \
                       -o -name '*.service.*' -o -name '*.timer.*' \) -print \) 2>/dev/null | sort); do
            _collect_unit "$_uf"
        done
    fi
    DIST_UNITS="$(printf '%s\n' $DIST_UNITS | sort)"

    GENERATED_UNIT_DIR=""
    if [ -z "$DIST_UNITS" ]; then
        # No units in the release. Generate one for the server so the app still
        # runs as a daemon — leaving the machine with no service at all is the
        # worse outcome. Anything the release ships beyond the server (an
        # updater and its timer) cannot be reconstructed here and is not
        # attempted; run the app's own updater by hand if you need it.
        echo -e "${RED}   No .service or .timer files found. Looked in:${NC}"
        for _ud in $UNIT_SEARCH_DIRS; do
            if [ -d "$_ud" ]; then
                echo -e "${YELLOW}      $_ud (exists, but holds no unit files)${NC}"
            else
                echo -e "${YELLOW}      $_ud (does not exist)${NC}"
            fi
        done
        echo -e "${YELLOW}      and recursively under $SERVER_DIR${NC}"
        echo -e "${YELLOW}   Generating ${SERVICE_NAME_DEFAULT} for the server instead —${NC}"
        echo -e "${YELLOW}   the updater and its timer cannot be reconstructed here.${NC}"

        # GPU device nodes (/dev/nvidia*, /dev/kfd, /dev/dri/renderD*) are owned
        # by the video/render groups. A user added to those groups mid-session
        # does not see it in their current login shell until they log out and
        # back in, but a service's SupplementaryGroups= is resolved fresh at
        # start time. Only groups that exist are named: a missing one fails the
        # whole service to start.
        SERVICE_GROUPS=""
        if [ "$SELECTED_BACKEND" = "rocm" ]; then
            for _g in render video; do
                getent group "$_g" >/dev/null 2>&1 && SERVICE_GROUPS="$SERVICE_GROUPS $_g"
            done
        fi

        GENERATED_UNIT_DIR="$(mktemp -d)"
        {
            echo "[Unit]"
            echo "Description=Intentioned.tech voice coaching server"
            echo "After=network.target"
            echo ""
            echo "[Service]"
            echo "Type=simple"
            echo "User=${CURRENT_USER}"
            [ -n "$SERVICE_GROUPS" ] && echo "SupplementaryGroups=${SERVICE_GROUPS# }"
            echo "WorkingDirectory=${SERVER_DIR}"
            echo "Environment=HOME=${HOME}"
            echo "ExecStart=${REPO_PATH}/myenv/bin/python ${SERVER_DIR}/${SERVER_ENTRY}"
            echo "Restart=on-failure"
            echo "RestartSec=5"
            echo ""
            echo "[Install]"
            echo "WantedBy=multi-user.target"
        } > "${GENERATED_UNIT_DIR}/${SERVICE_NAME_DEFAULT}"
        DIST_UNITS="${GENERATED_UNIT_DIR}/${SERVICE_NAME_DEFAULT}"
    fi

    if [ -n "$DIST_UNITS" ]; then
        if [ -z "$GENERATED_UNIT_DIR" ]; then
            echo -e "${YELLOW}   Found $(printf '%s\n' "$DIST_UNITS" | wc -l) unit file(s) in the release.${NC}"
        fi

        # Some placeholders are the name of another unit in the same set — a
        # timer's Unit= pointing at its payload, an updater restarting the
        # server. Resolve those from what was actually discovered, so a release
        # that renames a unit still wires up correctly.
        UNIT_SERVER_NAME=""
        UNIT_UPDATER_NAME=""
        UNIT_TIMER_NAME=""
        for _src in $DIST_UNITS; do
            _n="$(_unit_name_for "$_src")"
            case "$_n" in
                *updater*.service) [ -n "$UNIT_UPDATER_NAME" ] || UNIT_UPDATER_NAME="$_n" ;;
                *.timer)           [ -n "$UNIT_TIMER_NAME" ]   || UNIT_TIMER_NAME="$_n" ;;
                *.service)         [ -n "$UNIT_SERVER_NAME" ]  || UNIT_SERVER_NAME="$_n" ;;
            esac
        done

        # Templates carry placeholders for what only the installing machine
        # knows. Four spellings are substituted — __NAME__, @NAME@, {{NAME}}
        # and %NAME% — because the convention differs per packaging tool and
        # guessing one wrong leaves a unit that fails at start. ${NAME} is
        # deliberately not touched: systemd expands that itself.
        _UNIT_VARS=(
            "DIST_DIR=${SERVER_DIR}"
            "INSTALL_PATH=${SERVER_DIR}"
            "INSTALL_DIR=${SERVER_DIR}"
            "APP_DIR=${SERVER_DIR}"
            "WORKING_DIR=${SERVER_DIR}"
            "WORKDIR=${SERVER_DIR}"
            "USER=${CURRENT_USER}"
            "GROUP=$(id -gn 2>/dev/null || echo "${CURRENT_USER}")"
            "HOME=${HOME}"
            "PYTHON=${REPO_PATH}/myenv/bin/python"
            "VENV=${REPO_PATH}/myenv"
            "VENV_PATH=${REPO_PATH}/myenv"
            "ENTRY=${SERVER_ENTRY}"
            "ENTRY_POINT=${SERVER_DIR}/${SERVER_ENTRY}"
            "SERVICE=${UNIT_SERVER_NAME}"
            "SERVICE_NAME=${UNIT_SERVER_NAME}"
            "SERVER_SERVICE=${UNIT_SERVER_NAME}"
            "UPDATER_SERVICE=${UNIT_UPDATER_NAME}"
            "UPDATER_TIMER=${UNIT_TIMER_NAME}"
            "TIMER=${UNIT_TIMER_NAME}"
        )

        for _src in $DIST_UNITS; do
            _unit="$(_unit_name_for "$_src")"
            _tmp="$(mktemp --suffix=".${_unit##*.}")"
            cp "$_src" "$_tmp"
            for _kv in "${_UNIT_VARS[@]}"; do
                _k="${_kv%%=*}"
                _v="${_kv#*=}"
                # An empty value means the thing it names was not found. Leaving
                # the placeholder in place lets the check below report it, rather
                # than substituting nothing and installing a broken unit.
                [ -n "$_v" ] || continue
                # Doubled delimiters first. @@VAR@@ is what these templates
                # use, and matching the single form against it consumes only
                # the inner pair — leaving User=@administrator@ and
                # WorkingDirectory=@/home/...@, which systemd rejects as a
                # non-absolute path and a malformed user name.
                sed -i -e "s#@@${_k}@@#${_v}#g" \
                       -e "s#%%${_k}%%#${_v}#g" \
                       -e "s#__${_k}__#${_v}#g" \
                       -e "s#@${_k}@#${_v}#g" \
                       -e "s#{{[[:space:]]*${_k}[[:space:]]*}}#${_v}#g" \
                       -e "s#%${_k}%#${_v}#g" "$_tmp"
            done

            # A leftover placeholder means the release uses a name this script
            # does not know. Installing it would produce a unit that fails at
            # start with an unhelpful error, so say so instead. %NAME% needs two
            # or more characters to avoid matching systemd's own %h, %n and %i.
            _left="$(grep -oE '__[A-Z_]+__|@[A-Z_]+@|\{\{[[:space:]]*[A-Z_]+[[:space:]]*\}\}|%[A-Z_]{2,}%' "$_tmp" | sort -u || true)"
            if [ -n "$_left" ]; then
                echo -e "${RED}   ${_unit}: unresolved placeholder(s):${NC}"
                printf '%s\n' "$_left" | sed 's/^/      /'
                echo -e "${YELLOW}   Skipping it; report these so the installer can fill them in.${NC}"
                rm -f "$_tmp"
                continue
            fi

            # Reported, not enforced. These units are part of the release, so
            # refusing to install one leaves the app without a service it
            # expects — a worse outcome than installing it and letting systemd
            # report the real problem at start. verify is also stricter than
            # systemd itself: it fails a unit whose ExecStart binary is not
            # present yet, which is legitimate for anything built later.
            if command_exists systemd-analyze; then
                # Captured, not discarded: this output names the offending
                # directive, and throwing it away leaves "bad unit file setting"
                # at start time as the only clue.
                _verify_out="$(systemd-analyze verify "$_tmp" 2>&1)" || {
                    echo -e "${YELLOW}   ${_unit}: did not pass validation, installing anyway:${NC}"
                    printf '%s\n' "$_verify_out" | sed 's/^/      /'
                }
            fi

            # Read from the staged copy while it is still here. Re-reading the
            # installed path instead was a bug: on any failure to read it, a
            # Type=oneshot updater looked long-running and got started
            # immediately — running an update in the middle of the install.
            _is_oneshot=false
            grep -qiE '^[[:space:]]*Type=oneshot' "$_tmp" && _is_oneshot=true

            if sudo install -o root -g root -m 0644 "$_tmp" "/etc/systemd/system/${_unit}"; then
                INSTALLED_UNITS="$INSTALLED_UNITS $_unit"
                case "$_unit" in
                    *.timer) TIMER_UNITS="$TIMER_UNITS $_unit" ;;
                    *.service)
                        if [ "$_is_oneshot" = true ]; then
                            ONESHOT_UNITS="$ONESHOT_UNITS $_unit"
                        else
                            INSTALLED_SERVICES="$INSTALLED_SERVICES $_unit"
                        fi
                        ;;
                esac
                echo -e "${GREEN}   ${_unit} installed ✓${NC}"
            else
                echo -e "${RED}   ${_unit}: could not be installed.${NC}"
            fi
            rm -f "$_tmp"
        done

        if [ -n "$INSTALLED_UNITS" ] && sudo systemctl daemon-reload; then
            # Record what was installed so emergency-uninstall.sh removes exactly
            # these, rather than guessing from a name pattern.
            printf '%s\n' $INSTALLED_UNITS | sudo tee "$UNIT_MANIFEST" >/dev/null 2>&1 || true

            for _unit in $INSTALLED_UNITS; do
                # Enabling is what survives a reboot; a unit with no [Install]
                # section (a timer's oneshot payload, typically) legitimately
                # cannot be enabled, so that failure is not reported as an error.
                sudo systemctl enable "$_unit" >/dev/null 2>&1 || true
            done

            # A oneshot is the payload of a timer. Enabled above so it survives a
            # reboot, but deliberately not started: starting the updater here
            # would run an update in the middle of the install.
            for _unit in $ONESHOT_UNITS; do
                echo -e "${GREEN}   ${_unit} installed (oneshot; left for its timer) ✓${NC}"
            done

            for _unit in $TIMER_UNITS; do
                if sudo systemctl restart "$_unit"; then
                    echo -e "${GREEN}   ${_unit} enabled and started ✓${NC}"
                else
                    echo -e "${YELLOW}   ${_unit} installed but would not start.${NC}"
                fi
            done

            for _unit in $INSTALLED_SERVICES; do
                if sudo systemctl restart "$_unit"; then
                    sleep 1
                    if sudo systemctl is-active --quiet "$_unit"; then
                        echo -e "${GREEN}   ${_unit} enabled and running ✓${NC}"
                    else
                        echo -e "${YELLOW}   ${_unit} started but exited.${NC}"
                        echo -e "${YELLOW}   Check: journalctl -u ${_unit} -n 50${NC}"
                    fi
                    SERVICE_INSTALLED=true
                else
                    echo -e "${RED}   ${_unit} failed to start:${NC}"
                    # systemd's own reason, inline. "bad unit file setting" on
                    # its own does not say which setting, and the detail is in
                    # these two places.
                    sudo systemctl status --no-pager --lines=0 "$_unit" 2>&1 |
                        sed 's/^/      /' | head -12
                    if command_exists systemd-analyze; then
                        systemd-analyze verify "/etc/systemd/system/${_unit}" 2>&1 |
                            sed 's/^/      /' | head -12
                    fi
                    echo -e "${YELLOW}   Full log: journalctl -u ${_unit} -n 50${NC}"
                fi
            done
        elif [ -n "$INSTALLED_UNITS" ]; then
            echo -e "${RED}   daemon-reload failed (no systemd bus reachable?).${NC}"
            echo -e "${YELLOW}   Use the 'intentioned' launcher, or re-run with --no-systemd-service.${NC}"
        fi
    fi
    [ -n "$GENERATED_UNIT_DIR" ] && rm -rf "$GENERATED_UNIT_DIR"

    # The app's config tool restarts the server after a settings change, so the
    # rule covers every long-running service that was actually installed —
    # scoped to `restart` on those specific units, not blanket systemctl access.
    if [ -z "$INSTALLED_SERVICES" ]; then
        echo -e "${YELLOW}   No long-running service installed; skipping the sudoers rule.${NC}"
    else
        echo -e "${YELLOW}   Creating sudoers rule for ${CURRENT_USER}...${NC}"
        _sudo_cmds=""
        for _unit in $INSTALLED_SERVICES; do
            _sudo_cmds="${_sudo_cmds}, /usr/bin/systemctl restart ${_unit}"
        done
        TEMP_SUDOERS=$(mktemp)
        echo "${CURRENT_USER} ALL=(ALL) NOPASSWD:${_sudo_cmds#,}" > "$TEMP_SUDOERS"

        if sudo visudo -cf "$TEMP_SUDOERS" > /dev/null 2>&1; then
            sudo install -o root -g root -m 0440 "$TEMP_SUDOERS" "$SUDOERS_FILE"
            echo -e "${GREEN}   Sudoers rule installed for:${INSTALLED_SERVICES} ✓${NC}"

            _verify_unit="${INSTALLED_SERVICES%% *}"
            _verify_unit="${_verify_unit# }"
            if [ "$SERVICE_INSTALLED" = true ] && sudo -n systemctl status "$_verify_unit" > /dev/null 2>&1; then
                echo -e "${GREEN}   Passwordless sudo verified ✓${NC}"
            else
                echo -e "${YELLOW}   Sudoers rule installed but service not running to verify against${NC}"
            fi
        else
            echo -e "${RED}   Sudoers syntax validation failed${NC}"
            echo -e "${YELLOW}   You may need to manually configure sudoers${NC}"
        fi

        rm -f "$TEMP_SUDOERS"
    fi
fi

# Apply NeMo CUDA graph patches (fixes cu_call unpacking bug)
echo -e "${YELLOW}   Applying NeMo patches...${NC}"
./myenv/bin/python apply_nemo_patch.py || echo -e "${YELLOW}   NeMo patch skipped (will retry at startup)${NC}"
echo -e "${GREEN}   NeMo patches applied ✓${NC}"

# Create start scripts
echo -e "\n${YELLOW}[8/8] Creating launch scripts...${NC}"

# The launchers live in ~/.local/bin, not in the install directory.
#
# Now that the app is installed directly into $INSTALL_PATH, a wrapper script
# sitting there would be inside the tree merge-dist.sh rewrites on every
# upgrade — and anything it removed would leave a dangling command behind.
# Keeping them out of that tree also means $INSTALL_PATH holds the application
# and nothing else.
USER_BIN="$HOME/.local/bin"
mkdir -p "$USER_BIN"

# Replaces the symlink earlier versions created here.
rm -f "$USER_BIN/intentioned" "$USER_BIN/intentioned-config"

# The venv lives at the install root even when the app itself sits a level
# down, so activate by absolute path rather than relative to the working
# directory.
cat > "$USER_BIN/intentioned" << EOF
#!/bin/bash
cd "$SERVER_DIR"
source "$REPO_PATH/myenv/bin/activate"
python "$SERVER_ENTRY"
EOF
chmod +x "$USER_BIN/intentioned"

cat > "$USER_BIN/intentioned-config" << EOF
#!/bin/bash
cd "$SERVER_DIR"
source "$REPO_PATH/myenv/bin/activate"
python "$CONFIG_ENTRY"
EOF
chmod +x "$USER_BIN/intentioned-config"

# Old installs kept the launchers beside the nested app directory. They point at
# a path that no longer exists after the migration above.
rm -f "$INSTALL_PATH/start-intentioned.sh" "$INSTALL_PATH/config-intentioned.sh"

# Add to PATH if needed
if [[ ":$PATH:" != *":$USER_BIN:"* ]]; then
    echo "export PATH=\"\$PATH:$USER_BIN\"" >> "$HOME/.bashrc"
    echo "export PATH=\"\$PATH:$USER_BIN\"" >> "$HOME/.zshrc" 2>/dev/null || true
    echo -e "${YELLOW}   Added $USER_BIN to PATH (restart shell to apply)${NC}"
fi

# Create desktop entry for Linux
if [ "$PLATFORM" = "Linux" ]; then
    DESKTOP_DIR="$HOME/.local/share/applications"
    mkdir -p "$DESKTOP_DIR"
    
    cat > "$DESKTOP_DIR/intentioned.desktop" << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Intentioned.tech
Comment=Social Skills Training Platform
Exec=$USER_BIN/intentioned
Icon=$SERVER_DIR/favicon.ico
Terminal=true
Categories=Education;
EOF

    cat > "$DESKTOP_DIR/intentioned-config.desktop" << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Intentioned.tech Config
Comment=Intentioned.tech Configuration Tool
Exec=$USER_BIN/intentioned-config
Icon=$SERVER_DIR/favicon.ico
Terminal=false
Categories=Education;Settings;
EOF

    echo -e "${GREEN}   Desktop entries created ✓${NC}"
fi

echo -e "${GREEN}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║                  Installation Complete! 🎉                     ║"
echo "╠═══════════════════════════════════════════════════════════════╣"
echo "║  To start Intentioned.tech:                                        ║"
echo "║    intentioned                                                 ║"
echo "║    or: $USER_BIN/intentioned                      "
echo "║                                                                ║"
echo "║  To configure:                                                 ║"
echo "║    intentioned-config                                          ║"
echo "║    or: $USER_BIN/intentioned-config                     "
echo "║                                                                ║"
echo "║  Installation path: $INSTALL_PATH                              "
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

if [ -n "$INSTALLED_UNITS" ]; then
    echo -e "${CYAN}systemd units installed:${INSTALLED_UNITS}${NC}"
    echo -e "${CYAN}    systemctl status${INSTALLED_UNITS}${NC}"
    echo -e "${CYAN}    systemctl list-timers 'intentioned*'${NC}"
    for _unit in $INSTALLED_SERVICES; do
        echo -e "${CYAN}    journalctl -u ${_unit} -f${NC}"
        echo -e "${CYAN}    sudo systemctl restart ${_unit}   (no password needed)${NC}"
    done
    if [ "$SERVICE_INSTALLED" = true ]; then
        echo -e "${CYAN}The 'intentioned' launcher above runs a separate foreground copy —${NC}"
        echo -e "${CYAN}stop the service first to avoid two instances competing for the${NC}"
        echo -e "${CYAN}same port and GPU.${NC}"
    fi
    echo ""
fi

# Offer to open config tool
if [ "$OPEN_CONFIG" = true ]; then
    echo -e "\n${CYAN}Would you like to configure Intentioned.tech now? (Y/n)${NC}"
    read -r response
    if [[ ! "$response" =~ ^[Nn]$ ]]; then
        echo -e "${CYAN}Opening Configuration Tool...${NC}"
        cd "$SERVER_DIR"
        source "$REPO_PATH/myenv/bin/activate"
        python "$CONFIG_ENTRY"
    fi
fi

echo -e "\n${CYAN}Thank you for installing Intentioned.tech!${NC}"
