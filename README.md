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
