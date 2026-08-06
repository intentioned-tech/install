# Intentioned.tech — Installer

Installs [Intentioned.tech](https://intentioned.tech), a local-first, privacy-first,
GPU-accelerated real-time voice coaching app for social-skills practice.

This repository contains **only the installer**. The application itself is
proprietary and is downloaded during installation using your licence
credentials.

## Requirements

- Linux or macOS
- Python 3.12 (the installer can set this up for you)
- A C/C++ compiler, for the `llama-cpp-python` (GGUF) build — the installer
  offers to install one (`build-essential` / `base-devel` / Xcode CLI tools).
  Skip the build with `--no-llama-cpp` if you do not need GGUF models.
- An Intentioned.tech licence (username + password)
- NVIDIA CUDA, AMD ROCm, or CPU — the backend is auto-detected. GPU offload for
  GGUF also needs the CUDA toolkit (`nvcc`), not just the driver; without it the
  installer builds llama-cpp-python CPU-only.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/intentioned-tech/install/main/install.sh -o install.sh
bash install.sh
```

`install.sh` installs its own system dependencies. If it cannot (no `sudo`, a
locked package manager, an unusual distro), install them separately first:

```bash
curl -fsSL https://raw.githubusercontent.com/intentioned-tech/install/main/install-deps.sh -o install-deps.sh
bash install-deps.sh
```

You will be prompted for your licence username and password. The password is
read from a hidden prompt and is never written to disk or passed on the command
line.

> **Review before you run.** Piping a script straight into a shell
> (`curl … | bash`) means executing code you have not read. Downloading first,
> as above, lets you inspect it. That advice applies to any installer, including
> this one.

### Non-interactive

For automated or fleet installs, supply credentials via the environment:

```bash
INTENTIONED_USERNAME=your-account \
INTENTIONED_PASSWORD='your-password' \
bash install.sh
```

Prefer the environment variables over `--username` / `--password`: process
arguments are visible to every local user through `/proc`.

## Options

| Flag | Description |
| --- | --- |
| `--backend cuda\|rocm\|cpu` | Force a compute backend (default: auto-detect) |
| `--install-path PATH` | Install location (default: `~/.local/share/intentioned`) |
| `--worker-url URL` | Licence server (default: the hosted Worker) |
| `--no-config` | Skip opening the configuration tool afterwards |
| `--skip-repo-download` | Use an existing local checkout or dist |
| `--help` | Full option list |

Environment equivalents: `INTENTIONED_USERNAME`, `INTENTIONED_PASSWORD`,
`INTENTIONED_WORKER_URL`, `INSTALL_PATH`, `INSTALL_BACKEND`.

## System dependencies (`install-deps.sh`)

Installs the OS packages that cannot come from PyPI:

- a **C/C++ toolchain** — `llama-cpp-python` (GGUF support) publishes no Linux
  wheels, so pip compiles it from source on every install
- **Tk**, for every compatible Python found on the machine. `config_tool.py` is
  a tkinter GUI, and most distros ship tkinter in a separate `-tk` package. A
  virtualenv inherits the omission from the interpreter it was built on, so
  this has to be fixed before `myenv` is created — `pip install` cannot.
- **ffmpeg, git, curl, zstd**, which the installer shells out to

| Flag | Description |
| --- | --- |
| `--cuda` | Also install the distro CUDA toolkit (`nvcc`), needed to build llama-cpp-python with GPU offload |
| `--no-tk` | Skip the Tk packages |
| `--dry-run` | Print the package-manager commands without running them |
| `-y`, `--yes` | Do not prompt |

Supports apt, dnf, pacman, zypper and Homebrew. Safe to re-run.

GPU offload for GGUF needs the CUDA **toolkit**, not just the driver —
`nvidia-smi` comes from the driver, `nvcc` does not. Without `nvcc` the
installer builds llama-cpp-python CPU-only, which still loads GGUF models.

## Emergency uninstall

Returns the machine to a pre-development state. Removes the application, the
virtualenv, launchers, desktop entries, systemd units, the sudoers rule, the
PATH line added to your shell rc, the model and build caches — **and the
development toolchain itself**: gcc, g++, make, cmake, ninja, pkg-config, the
CUDA toolkit, Tk, the Python headers and ffmpeg.

Pair it with `install-deps.sh` to demo a clean install from a bare machine.

```bash
curl -fsSL https://raw.githubusercontent.com/intentioned-tech/install/main/emergency-uninstall.sh -o emergency-uninstall.sh
bash emergency-uninstall.sh --dry-run   # print the plan, delete nothing
bash emergency-uninstall.sh             # then, if it looks right
```

It prints every path it will delete, with sizes, and requires you to type
`UNINSTALL` before it touches anything.

| Flag | Description |
| --- | --- |
| `--dry-run` | Print the plan and exit |
| `--install-path PATH` | Install location to remove (default: auto-detected from the launcher symlink) |
| `--keep-models` | Keep `~/.cache/huggingface` and `~/.cache/torch` |
| `--keep-cache` | Keep the pip cache too |
| `--keep-shell-rc` | Do not touch `~/.bashrc` / `~/.zshrc` |
| `--keep-system-packages` | Keep gcc, cmake, CUDA, Tk and ffmpeg — remove only the app and its caches |
| `-y`, `--yes` | Skip the typed confirmation |

### What survives

**GPU drivers are never removed.** Neither are kernel modules, the display
stack, or the C runtime (`libgcc-s1`, `libstdc++6`, `gcc-N-base`, `libc6`) that
every binary on the machine links against. `git`, `curl` and your Python
interpreters are left alone too — they predate this app and other tooling
depends on them.

Keeping the driver while removing gcc and CUDA is the hard part: `cuda`,
`cuda-drivers` and `nvidia-driver-*` share a dependency graph, and Fedora's
`akmod-nvidia` pulls in gcc to build its kernel module, so a naive "remove gcc
and cuda" takes the driver with it. Three independent guards:

1. a curated list of what may be considered at all — never a blanket wildcard
   over installed packages;
2. a protected pattern (drivers, kernel modules, display stack, C runtime)
   subtracted from that list;
3. a package-manager **simulation** of every removal, with the candidate
   dropped if the simulated transaction touches anything protected. This is
   what catches the indirect cases the first two guards cannot see.

No orphan sweep is used — no `apt --auto-remove`, no `pacman -Rs`, no
`zypper --clean-deps`. Depth comes from naming `gcc`, `cpp-N`,
`libstdc++-N-dev` and friends explicitly, because an orphan sweep is exactly
how "remove gcc" ends up removing a DKMS-built driver. Support libraries left
behind are harmless; `apt autoremove` will collect them if you want.

After removing packages the script re-runs `nvidia-smi` (and `rocminfo`) and
reports whether the driver still works.

## How licensing works

Builds are served from private storage and are never publicly downloadable. The
installer authenticates to the licence server, which resolves which release your
account is entitled to and streams it back. Unauthenticated requests are
rejected — there is no public download URL, and the installer never names a
storage key.

Downloads are verified against a published SHA-256 before anything is installed.

## Updates

The installer sets up a daily timer that checks for a newer build at 04:00 local
time, verifies its checksum, and merges it in place while preserving every local
setting (configuration, certificates, licence activation, user accounts, session
data). It is a no-op when you are already current.

Updates authenticate with the activation token created at install time, so no
password is stored on the machine.

## Support

- Website: <https://intentioned.tech>
- Licence issues: contact the address on your licence confirmation

## Licence

The installer script in this repository is provided under the terms in
[LICENSE](LICENSE). Intentioned.tech itself is proprietary software licensed
separately; installing it requires a valid licence. Third-party open-source
components bundled with the application are credited in the
`THIRD_PARTY_LICENSES` file included in every release.
