# Intentioned.tech — Installer

Installs [Intentioned.tech](https://intentioned.tech), a local-first, privacy-first,
GPU-accelerated real-time voice coaching app for social-skills practice.

This repository contains **only the installer**. The application itself is
proprietary and is downloaded during installation using your licence
credentials.

## Requirements

- Linux or macOS
- **Python 3.12** — exactly 3.12, and you install it yourself (see below)
- **curl** — used to fetch the installer and to download your licensed build
- A C/C++ compiler, for the `llama-cpp-python` (GGUF) build — the installer
  offers to install one (`build-essential` / `base-devel` / Xcode CLI tools).
  Skip the build with `--no-llama-cpp` if you do not need GGUF models.
- An Intentioned.tech licence (username + password)
- NVIDIA CUDA, AMD ROCm, or CPU — the backend is auto-detected. GPU offload for
  GGUF also needs the CUDA toolkit (`nvcc`), not just the driver; without it the
  installer builds llama-cpp-python CPU-only.

The compiler, Tk, ffmpeg and the rest are installed for you — by `install.sh`
itself, or by `install-deps.sh`. Python 3.12 and curl are the two you need in
place before you start.

### Installing curl

```bash
sudo apt install -y curl          # Debian, Ubuntu
sudo dnf install -y curl          # Fedora, RHEL
sudo pacman -S --needed curl      # Arch, CachyOS
sudo zypper install -y curl       # openSUSE
```

macOS ships curl already. If you have `wget` but not `curl`, use it to fetch
the installer — but install `curl` anyway, since the installer needs it to
download your build.

### Installing Python 3.12

It must be **3.12 specifically** — not 3.11, not 3.13 or newer. Kokoro TTS and
NeMo/Parakeet both require it, and the shipped build contains
`cpython-312-*.so` modules that will not load under any other minor version.
The installer checks this and stops if 3.12 is missing; it does not install
Python for you.

```bash
# Ubuntu 24.04 and newer — in the repositories
sudo apt install -y python3.12 python3.12-venv python3.12-tk

# Ubuntu 22.04 and older — via the deadsnakes PPA
sudo add-apt-repository -y ppa:deadsnakes/ppa
sudo apt update
sudo apt install -y python3.12 python3.12-venv python3.12-tk

# Fedora / RHEL
sudo dnf install -y python3.12 python3.12-devel python3.12-tkinter

# openSUSE
sudo zypper install -y python312 python312-devel python312-tk

# macOS
brew install python@3.12 python-tk@3.12
```

`python3.12-venv` is not optional on Debian and Ubuntu: without it the
installer cannot create `myenv`. `python3.12-tk` is what the configuration tool
needs — `install-deps.sh` will add it later if you skip it here.

**Arch, CachyOS and Debian 12** do not carry 3.12 (Arch tracks the newest
Python; Debian 12 ships 3.11, and deadsnakes is Ubuntu-only). Use the AUR
package `python312` (`yay -S python312`), or [pyenv][pyenv], which works on any
distribution:

```bash
pyenv install 3.12
```

[pyenv]: https://github.com/pyenv/pyenv#installation

The installer finds a pyenv 3.12 automatically. To point it at an interpreter
somewhere else:

```bash
INTENTIONED_PYTHON=/path/to/python3.12 bash install.sh
```

Check what you have with `python3.12 --version`. A bare `python3` is not
enough — on rolling-release distributions it tracks the newest interpreter,
which will not work.

### Installing CUDA (NVIDIA)

Two separate things, and only the first is required:

- the **driver**, which the app needs. The PyTorch wheels the installer pulls
  bundle their own CUDA runtime, so the driver alone is enough to run everything.
- the **CUDA toolkit** (`nvcc`), needed only to *compile* `llama-cpp-python`
  with GPU offload. Without it the installer builds it CPU-only — GGUF models
  still load, just without the GPU.

`nvidia-smi` comes from the driver, so its presence says nothing about whether
the toolkit is installed. That is why a machine can pass GPU detection and
still build GGUF support CPU-only.

**Driver:**

```bash
sudo ubuntu-drivers install                 # Ubuntu — picks a suitable driver
sudo apt install -y nvidia-driver-580       # or pin one explicitly
sudo dnf install -y akmod-nvidia            # Fedora (needs RPM Fusion)
sudo pacman -S --needed nvidia              # Arch, CachyOS
```

Reboot afterwards, then run `nvidia-smi`. The installer pulls PyTorch built for
CUDA 13, which needs **driver 580 or newer** ([release notes][cuda13]); the
header `nvidia-smi` prints must show `CUDA Version: 13.0` or higher.

**Toolkit** — easiest through the dependency installer:

```bash
bash install-deps.sh --cuda
```

or directly:

```bash
sudo apt install -y nvidia-cuda-toolkit     # Debian, Ubuntu
sudo dnf install -y cuda-toolkit            # Fedora, RHEL
sudo pacman -S --needed cuda                # Arch, CachyOS
```

NVIDIA's own [installer][cuda-dl] is the other route; it puts `nvcc` in
`/usr/local/cuda/bin` rather than on `PATH`. The installer looks there anyway,
but for your own shell:

```bash
export PATH="/usr/local/cuda/bin:$PATH"
```

Verify with `nvcc --version`. If your distribution's gcc is newer than the
toolkit accepts, the installer detects it and pins an older `gcc-N` as the CUDA
host compiler — install one (`gcc15`, `gcc-13`, …) if it reports that none is
available.

[cuda13]: https://docs.nvidia.com/cuda/archive/13.0.0/cuda-toolkit-release-notes/index.html
[cuda-dl]: https://developer.nvidia.com/cuda-downloads

### Installing ROCm (AMD)

The installer pulls PyTorch built for **ROCm 7.2**, so install ROCm 7.x. Follow
AMD's [quick start guide][rocm-qs] for your distribution — the repository
package is version- and release-specific, so a URL here would go stale. On
Ubuntu it is roughly:

```bash
# after installing AMD's amdgpu-install repository package
sudo apt update
sudo apt install -y python3-setuptools python3-wheel
sudo usermod -a -G render,video "$LOGNAME"
sudo apt install -y rocm
sudo reboot
```

The `render` and `video` groups are not optional: the amdgpu device nodes are
owned by them, and without membership every ROCm call fails with a permission
error. If `rocminfo` reports `ROCk module is NOT loaded`, that missing group
membership — or a skipped reboot — is the usual cause.

Verify with:

```bash
rocm-smi
rocminfo | grep gfx
```

The installer reads that `gfx` target itself and passes it to the
`llama-cpp-python` HIP build as `-DAMDGPU_TARGETS`, falling back to a build
without a pinned target, then to CPU-only, if HIP fails. It also selects
`--backend rocm` automatically when `rocminfo` or `rocm-smi` is present, and
pins 16-bit quantization, which fits the 16 GB cards these commonly are.

If your GPU is not officially supported, ROCm can often still drive it by
presenting a supported target — for example a gfx1031 card as gfx1030:

```bash
export HSA_OVERRIDE_GFX_VERSION=10.3.0
```

[rocm-qs]: https://rocm.docs.amd.com/projects/install-on-linux/en/latest/install/quick-start.html

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

### Where things go

```
~/.local/share/intentioned/     the application, its myenv virtualenv,
                                config.json and TLS material
~/.local/bin/intentioned        launcher
~/.local/bin/intentioned-config configuration tool
```

`--install-path` sets the first of those, and the app is written **directly**
into it — there is no extra `intentioned.tech/` level below it. Installs made
before this changed are migrated automatically on the next run: the nested
directory is lifted up, and the virtualenv is relocated in place rather than
rebuilt, so nothing is re-downloaded.

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
