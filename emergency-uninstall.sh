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
KEEP_SYSTEM_PACKAGES=false
REMOVE_GIT_CURL=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --install-path)   INSTALL_PATH="$2"; shift 2 ;;
        --dry-run)        DRY_RUN=true; shift ;;
        -y|--yes)         ASSUME_YES=true; shift ;;
        --keep-models)    KEEP_MODELS=true; shift ;;
        --keep-cache)     KEEP_CACHE=true; shift ;;
        --keep-shell-rc)  KEEP_SHELL_RC=true; shift ;;
        --keep-system-packages) KEEP_SYSTEM_PACKAGES=true; shift ;;
        --remove-git-curl) REMOVE_GIT_CURL=true; shift ;;
        # Accepted and ignored: removing system packages is the default now.
        --system-packages) shift ;;
        -h|--help)
            echo "Intentioned.tech emergency uninstaller"
            echo ""
            echo "Usage: bash emergency-uninstall.sh [OPTIONS]"
            echo ""
            echo "Removes the application, its virtualenv, launchers, desktop entries,"
            echo "systemd units, the sudoers rule, the model/build caches, AND the"
            echo "development toolchain: gcc, make, cmake, ninja, the CUDA toolkit, Tk"
            echo "and the Python headers."
            echo ""
            echo "GPU drivers, kernel modules and the C runtime are never removed."
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
            echo "  --keep-system-packages"
            echo "                       Keep gcc, cmake, CUDA, Tk and ffmpeg. Use this to"
            echo "                       remove only the app and its caches."
            echo "  --remove-git-curl    ALSO remove git and curl. Off by default: curl is"
            echo "                       what fetches install.sh and this script in the first"
            echo "                       place, and other software commonly shells out to git."
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

# The launcher is the most reliable record of where install.sh actually put
# things — INSTALL_PATH is configurable and the caller may not remember what
# they passed. Current installs write a real script into ~/.local/bin whose
# `cd` line names the install directory.
if [ -z "$INSTALL_PATH" ] && [ -f "$USER_BIN/intentioned" ] && [ ! -L "$USER_BIN/intentioned" ]; then
    INSTALL_PATH="$(sed -n 's/^cd "\(.*\)"$/\1/p' "$USER_BIN/intentioned" 2>/dev/null | head -1)"
fi
# Installs made before the launchers moved: ~/.local/bin/intentioned was a
# symlink to $INSTALL_PATH/start-intentioned.sh, with the app nested one level
# further down in $INSTALL_PATH/intentioned.tech. Removing $INSTALL_PATH still
# takes the nested tree with it.
if [ -z "$INSTALL_PATH" ] && [ -L "$USER_BIN/intentioned" ]; then
    _target="$(readlink -f "$USER_BIN/intentioned" 2>/dev/null || true)"
    [ -n "$_target" ] && INSTALL_PATH="$(dirname "$_target")"
fi
if [ -z "$INSTALL_PATH" ]; then
    INSTALL_PATH="$HOME/.local/share/intentioned"
fi

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

    # The units come from the release, so their names are not guaranteed to
    # match intentioned*. install.sh records exactly what it installed; fold
    # that in so a differently-named unit is not left running afterwards.
    if [ -r "$INSTALL_PATH/.installed_units" ]; then
        while IFS= read -r _u; do
            [ -n "$_u" ] || continue
            case " $SYSTEM_UNITS " in
                *" $_u "*) ;;
                *) SYSTEM_UNITS="$SYSTEM_UNITS $_u" ;;
            esac
        done < "$INSTALL_PATH/.installed_units"
    fi
fi

# ---------------------------------------------------------------------------
# System packages
#
# This is a deep clean: the compiler itself goes, along with cmake, ninja, the
# CUDA toolkit, Tk and the Python headers — the machine ends up as if it had
# never built anything. The GPU driver stays.
#
# That distinction is the whole difficulty. `cuda`, `cuda-drivers` and
# `nvidia-driver-*` sit in one dependency graph, and `akmod-nvidia` on Fedora
# pulls in gcc to build its kernel module, so a naive "remove gcc and cuda"
# takes the driver with it. Three independent guards below:
#
#   1. a curated pattern of what may be considered at all, never a blanket
#      wildcard over installed packages;
#   2. a protected pattern (drivers, kernel modules, display stack, and the C
#      runtime every binary on the system links against) subtracted from it;
#   3. a package-manager *simulation* of each removal, with the candidate
#      dropped if the simulated transaction touches anything protected. This
#      is what catches the indirect cases the first two cannot see.
# ---------------------------------------------------------------------------

# Drivers, kernel modules, display stack. Losing these is not a recoverable
# "oops" on a headless box. cuda-drivers is here rather than with the toolkit
# because it is the driver metapackage, despite the name.
DRIVER_RE='(nvidia-driver|nvidia-dkms|nvidia-utils|nvidia-kernel|nvidia-firmware|nvidia-compute|nvidia-persistenced|nvidia-settings|nvidia-prime|nvidia-modprobe|nvidia-open|libnvidia|cuda-drivers|akmod-nvidia|kmod-nvidia|dkms|linux-headers|linux-image|linux-modules|kernel-devel|kernel-core|amdgpu|xf86-video|mesa|xserver|xorg|rocm|hip-runtime|libdrm)'

# The C runtime, not the C compiler. libgcc-s1 and libstdc++6 are linked by
# essentially every binary on the box, and gcc-N-base is their common parent —
# removing any of them is a bricked system, not a clean demo machine.
PROTECTED_RE="(^gcc-[0-9.]+-base$|^libgcc-s1$|^libgcc1$|^libstdc\+\+6$|^libc6$|^libc-bin$|^glibc$|^libgcc$|^libstdc\+\+$|$DRIVER_RE)"

# What a deep clean is allowed to consider. Deliberately absent: git, curl,
# ca-certificates and the Python interpreters. They predate this app on any real
# machine and removing them breaks unrelated tooling. git and curl can be added
# back in with --remove-git-curl; ca-certificates and the interpreters cannot,
# since removing either breaks apt/dnf/pacman/zypper themselves on many systems.
case "$PLATFORM" in
    macOS) DEV_RE='^(cmake|ninja|pkg-config|ffmpeg|zstd|python-tk(@.*)?)$' ;;
    *)     DEV_RE='^(build-essential|gcc|g\+\+|cpp|gcc-[0-9]+|g\+\+-[0-9]+|cpp-[0-9]+|gcc-c\+\+|libstdc\+\+-[0-9]+-dev|libstdc\+\+-devel|libgcc-[0-9]+-dev|libc6-dev|libc-dev-bin|glibc-devel|linux-libc-dev|make|cmake|cmake-data|ninja|ninja-build|pkg-config|pkgconf|pkgconf-bin|libpkgconf[0-9]*|pkgconfig|ffmpeg|zstd|tk|python3(\.[0-9]+)?-tk|python3(\.[0-9]+)?-dev|python3(\.[0-9]+)?-devel|python3(\.[0-9]+)?-tkinter|python[0-9]+-tk|python[0-9]+-devel|libpython3(\.[0-9]+)?-dev|nvidia-cuda-toolkit|nvidia-cuda-dev|cuda|cuda-toolkit.*|cuda-[a-z].*|libcudnn.*|libcublas.*|libcufft.*|libcurand.*|libcusolver.*|libcusparse.*|libnpp.*|libnvjitlink.*|libnvrtc.*|libnvjpeg.*)$' ;;
esac

# Opt-in, not folded into DEV_RE: this is a much smaller, hand-picked set
# (just the two commands, not their libraries — libcurlN stays, since removing
# it would cascade into anything on the box linked against it).
GIT_CURL_RE='^(git|curl)$'

PKG=""
if [ "$PLATFORM" = "macOS" ]; then
    command_exists brew && PKG="brew"
elif command_exists apt-get; then PKG="apt"
elif command_exists dnf;     then PKG="dnf"
elif command_exists pacman;  then PKG="pacman"
elif command_exists zypper;  then PKG="zypper"
fi

# Installed packages, one name per line.
installed_packages() {
    case "$PKG" in
        apt)    dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\n' 2>/dev/null |
                    awk '/^i/ {print $2}' | sed 's/:.*$//' ;;
        dnf|zypper) rpm -qa --qf '%{NAME}\n' 2>/dev/null ;;
        pacman) pacman -Qq 2>/dev/null ;;
        brew)   brew list --formula 2>/dev/null ;;
    esac
}

# Text of the transaction the manager *would* perform. Parsed only well enough
# to spot protected names in it, so an unparsed line is harmless — it simply
# fails to match and the candidate is kept.
#
# No --auto-remove / --clean-deps / -s anywhere: the depth of this uninstall
# comes from the curated list naming gcc, cpp-N, libstdc++-N-dev and friends
# explicitly, not from letting the package manager sweep orphans. An orphan
# sweep is precisely how `remove gcc` ends up removing a DKMS-built driver.
simulate_removal() {
    case "$PKG" in
        apt)    apt-get purge -s "$@" 2>/dev/null | grep -E '^(Remv|Purg)' || true ;;
        dnf)    dnf remove --assumeno --setopt=clean_requirements_on_remove=False "$@" 2>&1 || true ;;
        pacman) pacman -Rnp --print-format '%n' "$@" 2>/dev/null || true ;;
        zypper) zypper --non-interactive remove --dry-run "$@" 2>&1 || true ;;
        brew)   echo "$*" ;;   # brew never removes a formula's dependents
    esac
}

# True when a simulated transaction would touch something protected. The text is
# split on whitespace so the anchored entries in PROTECTED_RE match whole
# package names; apt's trailing "[version]" fields are stripped first.
touches_protected() {
    [ -n "$1" ] || return 1
    printf '%s\n' "$1" | tr -s ' \t' '\n\n' | sed 's/^\[.*//' | grep -qE "$PROTECTED_RE"
}

REMOVE_PKGS=""
SKIPPED_PKGS=""
KEPT_DRIVERS=""
BATCH_SAFE=true
if [ "$KEEP_SYSTEM_PACKAGES" != true ] && [ -n "$PKG" ]; then
    echo -e "${YELLOW}Working out which development packages can be removed safely...${NC}"

    # Guard 1+2 first, over every installed package: cheap regex matching, no
    # package-manager calls. Curated-set membership (or git/curl under
    # --remove-git-curl) and self-protection are decided here.
    CANDIDATES=""
    for _p in $(installed_packages | sort -u); do
        if ! printf '%s' "$_p" | grep -qE "$DEV_RE"; then
            if [ "$REMOVE_GIT_CURL" != true ] || ! printf '%s' "$_p" | grep -qE "$GIT_CURL_RE"; then
                continue
            fi
        fi
        if printf '%s' "$_p" | grep -qE "$PROTECTED_RE"; then
            KEPT_DRIVERS="$KEPT_DRIVERS $_p"
            continue
        fi
        CANDIDATES="$CANDIDATES $_p"
    done

    # Guard 3, batched: `apt-get purge -s` runs a full dependency solve, which
    # costs a few seconds per call — cheap once, but a machine with several
    # dozen candidate packages turns a call-per-package loop into a minute or
    # more of silent "computing" before the confirmation prompt even shows.
    # One simulate of the whole candidate set costs the same single solve and
    # covers both guard 3 (does any candidate drag out something protected)
    # and the old separate "removals interact" batch check at once — a set
    # that's clean together is clean individually too.
    if [ -n "$CANDIDATES" ]; then
        # shellcheck disable=SC2086
        if touches_protected "$(simulate_removal $CANDIDATES)"; then
            # A real conflict: fall back to finding which candidate(s) are
            # responsible. This path is the slow one, but it is now the
            # exception rather than the rule, so it earns a progress readout.
            echo -e "${YELLOW}   A conflict was found; checking candidates individually...${NC}"
            for _p in $CANDIDATES; do
                printf '.' >&2
                if touches_protected "$(simulate_removal "$_p")"; then
                    SKIPPED_PKGS="$SKIPPED_PKGS $_p"
                else
                    REMOVE_PKGS="$REMOVE_PKGS $_p"
                fi
            done
            echo "" >&2
            # The individually-clean survivors can still interact as a set;
            # this is the same check the fast path skips because a jointly
            # clean CANDIDATES set makes it redundant.
            if [ -n "$REMOVE_PKGS" ]; then
                # shellcheck disable=SC2086
                if touches_protected "$(simulate_removal $REMOVE_PKGS)"; then
                    BATCH_SAFE=false
                fi
            fi
        else
            REMOVE_PKGS="$CANDIDATES"
        fi
    fi
fi

# Whether git/curl actually made it into the removal set — --remove-git-curl
# was requested does not guarantee it: guard 2 or guard 3 could still have
# skipped either one. Used below for the plan warning and the closing summary.
GIT_REMOVED=false
CURL_REMOVED=false
for _p in $REMOVE_PKGS; do
    [ "$_p" = "git" ]  && GIT_REMOVED=true
    [ "$_p" = "curl" ] && CURL_REMOVED=true
done

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
    printf '%s\n' $REMOVE_PKGS | sed 's/^/   /' | while IFS= read -r _l; do
        echo -e "${RED}$_l${NC}"
    done
    if [ -n "$KEPT_DRIVERS" ]; then
        echo -e "${GREEN}Protected (driver / kernel / C runtime), staying installed:${NC}"
        printf '%s\n' $KEPT_DRIVERS | sed 's/^/   /'
    fi
    if [ -n "$SKIPPED_PKGS" ]; then
        echo -e "${GREEN}Skipped — removing these would have taken a protected package too:${NC}"
        printf '%s\n' $SKIPPED_PKGS | sed 's/^/   /'
    fi
    if [ "$BATCH_SAFE" != true ]; then
        echo -e "${YELLOW}Batch removal would touch a protected package; removing one at a${NC}"
        echo -e "${YELLOW}time instead and skipping any that turns unsafe.${NC}"
    fi
    if [ "$CURL_REMOVED" = true ]; then
        echo ""
        echo -e "${RED}curl will be removed. It is what fetched install.sh and this script —${NC}"
        echo -e "${RED}without it, 'curl -fsSL ... -o install.sh' and install-deps.sh's own${NC}"
        echo -e "${RED}downloads stop working. Save any file you still need before proceeding;${NC}"
        echo -e "${RED}your package manager can put curl back afterwards.${NC}"
    fi
elif [ "$KEEP_SYSTEM_PACKAGES" = true ]; then
    echo ""
    echo -e "${GREEN}Keeping the toolchain, CUDA, Tk and ffmpeg (--keep-system-packages).${NC}"
fi

if [ "$KEEP_MODELS" = true ]; then
    echo ""
    echo -e "${GREEN}Keeping ~/.cache/huggingface and ~/.cache/torch (--keep-models).${NC}"
fi

NEVER_TOUCHED="GPU drivers, CUDA/ROCm kernel modules, your Python installations,"
[ "$GIT_REMOVED" = true ]  || NEVER_TOUCHED="$NEVER_TOUCHED git,"
[ "$CURL_REMOVED" = true ] || NEVER_TOUCHED="$NEVER_TOUCHED curl,"
NEVER_TOUCHED="$NEVER_TOUCHED and anything outside the paths above."
echo ""
echo -e "${GREEN}Never touched: ${NEVER_TOUCHED}${NC}"

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
# Both layouts: the app sits in $INSTALL_PATH now, one level down before that.
for _venv in "$INSTALL_PATH/myenv" "$INSTALL_PATH/intentioned.tech/myenv"; do
    if [ -x "$_venv/bin/python" ]; then
        pkill -f "^$_venv/bin/python" >/dev/null 2>&1 || true
    fi
done

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

# 6. System packages: the toolchain, CUDA, Tk, ffmpeg.
echo -e "\n${YELLOW}[6/6] Removing development packages...${NC}"
if [ -z "$REMOVE_PKGS" ]; then
    if [ "$KEEP_SYSTEM_PACKAGES" = true ]; then
        echo -e "${GREEN}   Skipped (--keep-system-packages) ✓${NC}"
    else
        echo -e "${GREEN}   Nothing removable found ✓${NC}"
    fi
else
    do_removal() {
        case "$PKG" in
            apt)    _as_root apt-get purge -y "$@" ;;
            dnf)    _as_root dnf remove -y --setopt=clean_requirements_on_remove=False "$@" ;;
            pacman) _as_root pacman -Rn --noconfirm "$@" ;;
            zypper) _as_root zypper --non-interactive remove "$@" ;;
            brew)   brew uninstall "$@" ;;
        esac
    }

    if [ "$BATCH_SAFE" = true ]; then
        # shellcheck disable=SC2086
        do_removal $REMOVE_PKGS || BATCH_SAFE=false
    fi
    if [ "$BATCH_SAFE" != true ]; then
        # One at a time, re-simulating each against the machine's *current*
        # state — earlier removals change what the next one would cascade into.
        for _p in $REMOVE_PKGS; do
            if touches_protected "$(simulate_removal "$_p")"; then
                echo -e "${YELLOW}   skipped $_p (would take a protected package)${NC}"
                continue
            fi
            do_removal "$_p" >/dev/null 2>&1 || echo -e "${YELLOW}   skipped $_p (removal failed)${NC}"
        done
    fi
    echo -e "${GREEN}   Development packages removed ✓${NC}"
    echo -e "${YELLOW}   Orphaned support libraries are left in place on purpose — an${NC}"
    echo -e "${YELLOW}   orphan sweep is how 'remove gcc' ends up removing a DKMS driver.${NC}"

    # The one claim this script makes that is worth verifying out loud.
    if command_exists nvidia-smi; then
        if nvidia-smi >/dev/null 2>&1; then
            echo -e "${GREEN}   NVIDIA driver still working ✓${NC}"
        else
            echo -e "${YELLOW}   nvidia-smi present but not responding; a reboot may be pending.${NC}"
        fi
    fi
    if command_exists rocminfo && rocminfo >/dev/null 2>&1; then
        echo -e "${GREEN}   ROCm runtime still working ✓${NC}"
    fi
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
if [ "$CURL_REMOVED" = true ]; then
    echo -e "${RED}curl is gone. Reinstall it before trying to fetch install.sh again.${NC}"
fi
echo -e "${CYAN}Open a new shell to drop the removed PATH entry.${NC}"
