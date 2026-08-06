#!/bin/bash
# Intentioned.tech - Emergency uninstaller
#
# Removes everything install.sh put on this machine: the application tree, the
# virtualenv, launchers, desktop entries, the systemd units and timers, the
# sudoers rule, the PATH line added to your shell rc, and the multi-gigabyte
# model and build caches.
#
# GPU drivers are never touched. Neither is anything outside the paths listed
# in the plan this script prints before it deletes a single file.
#
# Run with: bash emergency-uninstall.sh [--dry-run]

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALL_PATH=""
DRY_RUN=false
ASSUME_YES=false
KEEP_MODELS=false
KEEP_CACHE=false
KEEP_SHELL_RC=false
SYSTEM_PACKAGES=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --install-path)   INSTALL_PATH="$2"; shift 2 ;;
        --dry-run)        DRY_RUN=true; shift ;;
        -y|--yes)         ASSUME_YES=true; shift ;;
        --keep-models)    KEEP_MODELS=true; shift ;;
        --keep-cache)     KEEP_CACHE=true; shift ;;
        --keep-shell-rc)  KEEP_SHELL_RC=true; shift ;;
        --system-packages) SYSTEM_PACKAGES=true; shift ;;
        -h|--help)
            echo "Intentioned.tech emergency uninstaller"
            echo ""
            echo "Usage: bash emergency-uninstall.sh [OPTIONS]"
            echo ""
            echo "Removes the application, its virtualenv, launchers, desktop entries,"
            echo "systemd units, the sudoers rule, and the model/build caches."
            echo "GPU drivers are never removed."
            echo ""
            echo "Options:"
            echo "  --install-path PATH  Install location to remove"
            echo "                       (default: auto-detected, else ~/.local/share/intentioned)"
            echo "  --dry-run            Print the plan and exit without deleting anything"
            echo "  -y, --yes            Skip the typed confirmation"
            echo "  --keep-models        Keep ~/.cache/huggingface and ~/.cache/torch"
            echo "                       (tens of GB of downloaded models, shared with other"
            echo "                       ML projects on this machine)"
            echo "  --keep-cache         Keep the pip cache too"
            echo "  --keep-shell-rc      Do not touch ~/.bashrc / ~/.zshrc"
            echo "  --system-packages    ALSO remove the build toolchain, Tk, ffmpeg and the"
            echo "                       CUDA toolkit via your package manager. Off by default:"
            echo "                       these are shared with the rest of your system."
            echo "                       Drivers are excluded even with this flag."
            echo "  -h, --help           Show this message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage."
            exit 1
            ;;
    esac
done

echo -e "${RED}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║        Intentioned.tech - EMERGENCY UNINSTALL                 ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

command_exists() { command -v "$1" >/dev/null 2>&1; }

OS="$(uname -s)"
case "${OS}" in
    Linux*)  PLATFORM=Linux ;;
    Darwin*) PLATFORM=macOS ;;
    *)       PLATFORM="UNKNOWN:${OS}" ;;
esac

USER_BIN="$HOME/.local/bin"
DESKTOP_DIR="$HOME/.local/share/applications"
SUDOERS_FILE="/etc/sudoers.d/intentioned-restart"

# ---------------------------------------------------------------------------
# Locate the install
# ---------------------------------------------------------------------------

# The launcher symlink is the most reliable record of where install.sh actually
# put things — INSTALL_PATH is configurable and the caller may not remember what
# they passed. Fall back to the documented default.
if [ -z "$INSTALL_PATH" ] && [ -L "$USER_BIN/intentioned" ]; then
    _target="$(readlink -f "$USER_BIN/intentioned" 2>/dev/null || true)"
    [ -n "$_target" ] && INSTALL_PATH="$(dirname "$_target")"
fi
if [ -z "$INSTALL_PATH" ]; then
    INSTALL_PATH="$HOME/.local/share/intentioned"
fi
REPO_PATH="$INSTALL_PATH/intentioned.tech"

# Refuse to delete anything that is not clearly a private subdirectory. A
# mistyped --install-path must not turn this into `rm -rf $HOME`, so require an
# absolute path at least two levels deep and never equal to $HOME.
path_is_safe() {
    local p="$1"
    [ -n "$p" ] || return 1
    case "$p" in /*) ;; *) return 1 ;; esac
    [ "$p" != "/" ] || return 1
    [ "$p" != "$HOME" ] || return 1
    [ "$(printf '%s' "${p#/}" | tr -cd '/' | wc -c)" -ge 1 ] || return 1
    return 0
}

if ! path_is_safe "$INSTALL_PATH"; then
    echo -e "${RED}Refusing to operate on install path: '${INSTALL_PATH}'${NC}"
    echo -e "${YELLOW}Pass an absolute path at least two levels deep, e.g.${NC}"
    echo -e "${YELLOW}  --install-path \$HOME/.local/share/intentioned${NC}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Build the plan
# ---------------------------------------------------------------------------

REMOVE_PATHS=""
add_path() {
    [ -e "$1" ] || [ -L "$1" ] || return 0
    REMOVE_PATHS="$REMOVE_PATHS
$1"
}

add_path "$INSTALL_PATH"
add_path "$USER_BIN/intentioned"
add_path "$USER_BIN/intentioned-config"
add_path "$DESKTOP_DIR/intentioned.desktop"
add_path "$DESKTOP_DIR/intentioned-config.desktop"

if [ "$KEEP_CACHE" != true ]; then
    add_path "$HOME/.cache/pip"
fi
if [ "$KEEP_MODELS" != true ]; then
    add_path "$HOME/.cache/huggingface"
    add_path "$HOME/.cache/torch"
fi

# systemd units the app or its updater may have registered. Enumerated rather
# than assumed: the nightly updater timer ships inside the licensed build, so
# its exact unit name is not knowable from this repo.
SYSTEM_UNITS=""
USER_UNITS=""
if [ "$PLATFORM" = "Linux" ] && command_exists systemctl; then
    SYSTEM_UNITS="$(systemctl list-unit-files --no-legend --no-pager 'intentioned*' 2>/dev/null | awk '{print $1}' || true)"
    USER_UNITS="$(systemctl --user list-unit-files --no-legend --no-pager 'intentioned*' 2>/dev/null | awk '{print $1}' || true)"
fi

# Package groups, mirroring install-deps.sh. git, curl and ca-certificates are
# deliberately absent: they predate this app on any real machine and removing
# them breaks unrelated tooling.
PKG=""
REMOVE_PKGS=""
if [ "$SYSTEM_PACKAGES" = true ]; then
    if [ "$PLATFORM" = "macOS" ]; then
        PKG="brew"
        REMOVE_PKGS="cmake ninja pkg-config ffmpeg zstd"
    elif command_exists apt-get; then
        PKG="apt"
        REMOVE_PKGS="build-essential cmake ninja-build pkg-config ffmpeg zstd python3-tk nvidia-cuda-toolkit"
        for _v in 9 10 11 12 13 14; do
            REMOVE_PKGS="$REMOVE_PKGS python3.$_v-tk python3.$_v-dev"
        done
    elif command_exists dnf; then
        PKG="dnf"
        REMOVE_PKGS="gcc-c++ cmake ninja-build pkgconfig ffmpeg zstd python3-tkinter cuda-toolkit"
    elif command_exists pacman; then
        PKG="pacman"
        REMOVE_PKGS="cmake ninja pkgconf ffmpeg zstd tk cuda"
    elif command_exists zypper; then
        PKG="zypper"
        REMOVE_PKGS="gcc-c++ cmake ninja pkg-config ffmpeg zstd python3-tk cuda-toolkit"
    fi
fi

# Belt and braces over the hand-written lists above: drop anything that looks
# like a driver, a kernel module or a display stack even if it was listed by
# mistake. Losing the GPU driver is not a recoverable "oops" on a headless box.
DRIVER_PATTERN='^(nvidia-driver|nvidia-dkms|nvidia-utils|nvidia-kernel|libnvidia|nvidia-open|linux-headers|linux-image|amdgpu|xf86-video|mesa|xserver|rocm|hip-runtime|kmod)'
KEPT_DRIVERS=""
FILTERED_PKGS=""
for _p in $REMOVE_PKGS; do
    if [[ "$_p" =~ $DRIVER_PATTERN ]]; then
        KEPT_DRIVERS="$KEPT_DRIVERS $_p"
    else
        FILTERED_PKGS="$FILTERED_PKGS $_p"
    fi
done
REMOVE_PKGS="$FILTERED_PKGS"

# ---------------------------------------------------------------------------
# Show the plan
# ---------------------------------------------------------------------------

echo -e "${YELLOW}Install path:${NC} $INSTALL_PATH"
echo ""
echo -e "${YELLOW}Will delete these paths:${NC}"
if [ -n "$REMOVE_PATHS" ]; then
    printf '%s\n' "$REMOVE_PATHS" | grep -v '^$' | while IFS= read -r _p; do
        _size="$(du -sh "$_p" 2>/dev/null | cut -f1 || true)"
        echo -e "${RED}   $_p${NC} ${_size:+(${_size})}"
    done
else
    echo -e "${GREEN}   (nothing found — already clean)${NC}"
fi

if [ -n "$SYSTEM_UNITS$USER_UNITS" ]; then
    echo ""
    echo -e "${YELLOW}Will stop, disable and remove these systemd units:${NC}"
    for _u in $SYSTEM_UNITS; do echo -e "${RED}   $_u${NC} (system)"; done
    for _u in $USER_UNITS;   do echo -e "${RED}   $_u${NC} (user)"; done
fi

if [ -f "$SUDOERS_FILE" ]; then
    echo ""
    echo -e "${YELLOW}Will remove the sudoers rule:${NC}"
    echo -e "${RED}   $SUDOERS_FILE${NC}"
fi

if [ "$KEEP_SHELL_RC" != true ]; then
    echo ""
    echo -e "${YELLOW}Will remove the installer's PATH line from ~/.bashrc and ~/.zshrc${NC}"
    echo -e "${YELLOW}(a timestamped backup of each file is kept alongside it)${NC}"
fi

if [ -n "$REMOVE_PKGS" ]; then
    echo ""
    echo -e "${YELLOW}Will remove these system packages via ${PKG}:${NC}"
    echo -e "${RED}  $REMOVE_PKGS${NC}"
    echo -e "${GREEN}Drivers are excluded and stay installed.${NC}"
    [ -n "$KEPT_DRIVERS" ] && echo -e "${GREEN}Filtered out as driver-adjacent:$KEPT_DRIVERS${NC}"
fi

if [ "$KEEP_MODELS" = true ]; then
    echo ""
    echo -e "${GREEN}Keeping ~/.cache/huggingface and ~/.cache/torch (--keep-models).${NC}"
fi

echo ""
echo -e "${GREEN}Never touched: GPU drivers, CUDA/ROCm kernel modules, your Python${NC}"
echo -e "${GREEN}installations, git, curl, and anything outside the paths above.${NC}"

if [ "$DRY_RUN" = true ]; then
    echo ""
    echo -e "${CYAN}Dry run — nothing was removed.${NC}"
    exit 0
fi

if [ "$ASSUME_YES" != true ]; then
    echo ""
    echo -e "${RED}This cannot be undone. Session recordings and your configuration go too.${NC}"
    echo -e "${CYAN}Type UNINSTALL to proceed:${NC}"
    read -r _confirm
    if [ "$_confirm" != "UNINSTALL" ]; then
        echo -e "${YELLOW}Aborted. Nothing was removed.${NC}"
        exit 0
    fi
fi

# ---------------------------------------------------------------------------
# Execute
# ---------------------------------------------------------------------------

_as_root() {
    if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi
}

# 1. Stop anything still running, so deletes do not race a live server.
echo -e "\n${YELLOW}[1/6] Stopping running services...${NC}"
for _u in $SYSTEM_UNITS; do
    _as_root systemctl stop "$_u" >/dev/null 2>&1 || true
    _as_root systemctl disable "$_u" >/dev/null 2>&1 || true
    echo -e "${GREEN}   stopped $_u ✓${NC}"
done
for _u in $USER_UNITS; do
    systemctl --user stop "$_u" >/dev/null 2>&1 || true
    systemctl --user disable "$_u" >/dev/null 2>&1 || true
    echo -e "${GREEN}   stopped $_u (user) ✓${NC}"
done
# Matched on the venv interpreter's absolute path, so only processes belonging
# to this install are signalled — never some other python running server.py.
if [ -x "$REPO_PATH/myenv/bin/python" ]; then
    pkill -f "^$REPO_PATH/myenv/bin/python" >/dev/null 2>&1 || true
fi

# 2. Unit files.
echo -e "\n${YELLOW}[2/6] Removing systemd units...${NC}"
if [ -n "$SYSTEM_UNITS$USER_UNITS" ]; then
    for _u in $SYSTEM_UNITS; do
        _as_root rm -f "/etc/systemd/system/$_u" "/usr/lib/systemd/system/$_u" 2>/dev/null || true
    done
    for _u in $USER_UNITS; do
        rm -f "$HOME/.config/systemd/user/$_u" 2>/dev/null || true
    done
    _as_root systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    echo -e "${GREEN}   Units removed ✓${NC}"
else
    echo -e "${GREEN}   None found ✓${NC}"
fi

# 3. Sudoers rule.
echo -e "\n${YELLOW}[3/6] Removing sudoers rule...${NC}"
if [ -f "$SUDOERS_FILE" ]; then
    _as_root rm -f "$SUDOERS_FILE" && echo -e "${GREEN}   $SUDOERS_FILE removed ✓${NC}"
else
    echo -e "${GREEN}   None found ✓${NC}"
fi

# 4. Files and directories.
echo -e "\n${YELLOW}[4/6] Removing files...${NC}"
if [ -n "$REMOVE_PATHS" ]; then
    printf '%s\n' "$REMOVE_PATHS" | grep -v '^$' | while IFS= read -r _p; do
        # Re-checked here rather than trusting the plan: paths are the one thing
        # in this script that can destroy unrelated work.
        if path_is_safe "$_p"; then
            rm -rf "$_p"
            echo -e "${GREEN}   removed $_p ✓${NC}"
        else
            echo -e "${RED}   skipped unsafe path $_p${NC}"
        fi
    done
else
    echo -e "${GREEN}   Nothing to remove ✓${NC}"
fi

# 5. Shell rc PATH line.
echo -e "\n${YELLOW}[5/6] Cleaning shell configuration...${NC}"
if [ "$KEEP_SHELL_RC" = true ]; then
    echo -e "${GREEN}   Skipped (--keep-shell-rc) ✓${NC}"
else
    _stamp="$(date +%Y%m%d%H%M%S)"
    for _rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        [ -f "$_rc" ] || continue
        # Only the exact line install.sh appends, so a hand-written PATH export
        # with the same directory in it survives.
        if grep -qF "export PATH=\"\$PATH:$USER_BIN\"" "$_rc"; then
            cp "$_rc" "$_rc.intentioned-uninstall.$_stamp.bak"
            grep -vF "export PATH=\"\$PATH:$USER_BIN\"" "$_rc" > "$_rc.tmp" && mv "$_rc.tmp" "$_rc"
            echo -e "${GREEN}   cleaned $_rc (backup: $_rc.intentioned-uninstall.$_stamp.bak) ✓${NC}"
        fi
    done
    echo -e "${GREEN}   Shell configuration clean ✓${NC}"
fi

# 6. System packages (opt-in).
echo -e "\n${YELLOW}[6/6] Removing system packages...${NC}"
if [ -z "$REMOVE_PKGS" ]; then
    echo -e "${GREEN}   Skipped (pass --system-packages to include them) ✓${NC}"
else
    case "$PKG" in
        apt)
            # --auto-remove sweeps up dependencies that only these packages
            # pulled in; ignore-missing keeps a package that was never installed
            # from failing the whole run.
            # shellcheck disable=SC2086
            _as_root apt-get purge -y --auto-remove --ignore-missing $REMOVE_PKGS || true
            ;;
        dnf)
            # shellcheck disable=SC2086
            _as_root dnf remove -y $REMOVE_PKGS || true
            ;;
        pacman)
            # shellcheck disable=SC2086
            _as_root pacman -Rns --noconfirm $REMOVE_PKGS || true
            ;;
        zypper)
            # shellcheck disable=SC2086
            _as_root zypper --non-interactive remove --clean-deps $REMOVE_PKGS || true
            ;;
        brew)
            # shellcheck disable=SC2086
            brew uninstall $REMOVE_PKGS || true
            ;;
    esac
    echo -e "${GREEN}   System packages removed ✓${NC}"
fi

echo -e "${GREEN}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║                    Uninstall Complete                         ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "${YELLOW}Your GPU drivers were not touched.${NC}"
if [ "$KEEP_MODELS" = true ]; then
    echo -e "${YELLOW}Model caches kept at ~/.cache/huggingface and ~/.cache/torch.${NC}"
fi
echo -e "${CYAN}Open a new shell to drop the removed PATH entry.${NC}"
