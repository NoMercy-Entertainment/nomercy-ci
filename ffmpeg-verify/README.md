# ffmpeg-verify

The hardware fleet that verifies a `nomercy-ffmpeg` Release Candidate before it
becomes a release.

`nomercy-ffmpeg` blocks merges into `master` until every box in the PR's test
checklist is ticked, and each box means "a human downloaded this binary and ran
the full suite on real hardware for that platform". That is six platforms per
release candidate, and an RC is republished on every push to the PR. This fleet
does that work instead.

The point is not speed. It is that a tick becomes evidence: every box is backed
by a verdict file naming the SHA-256 of the bytes that were tested, the machine
that ran them, and whether the binary ran natively or translated. A platform
with no runner leaves its box empty and the merge stays blocked, which is the
same outcome as nobody testing it.

## What runs where

| Checklist item | Machine | How |
|---|---|---|
| `linux-x86_64` | Proxmox LXC 5200 | native |
| `linux-aarch64` | Mac mini, Lima guest | native ARM64 under Apple's vz backend |
| `windows-x86_64` | Stoney's desktop | native |
| `darwin-arm64` | Mac mini | native |
| `darwin-x86_64` | Mac mini | Rosetta 2, recorded as translated |
| `freebsd-x86_64` | Proxmox VM 6100 | Linux runner drives it over SSH |
| Hardware acceleration | Windows desktop / Mac mini | NVENC on the RTX 2080 SUPER, VideoToolbox on the M4 |

Three runners cover all of it: `ffmpeg-verify-linux`, `ffmpeg-verify-mac`, and
`ffmpeg-verify-windows`, each carrying a label per platform it can verify.

## What cannot be verified here

There is no AMD GPU and no Intel iGPU anywhere in the fleet, so **AMF and VPL are
never positively exercised**. The suite skips them and records why, and the bot
reports them as untested rather than folding them into a green tick. Adding an
AMD or Intel card to the Proxmox host is the only thing that would change this.

Linux NVENC is also unverified, but not for the reason it first appeared. The
only NVIDIA card is in the Windows desktop, and the GPU passthrough into WSL2 is
fine: `/dev/dxg` is present, `nvidia-smi` works, and `libnvidia-encode` resolves.
The blocker is the fork itself. WSL2's `libcuda.so.1` is a shim that must
`dlopen` the real driver from `/usr/lib/wsl/drivers/...`, and our statically
linked build cannot complete that second-stage load, so `cuInit` returns
`CUDA_ERROR_OPERATING_SYSTEM`. A stock dynamically linked ffmpeg encodes fine on
the same machine and GPU. Native Linux has no shim, which is why this only shows
up under WSL2. See `probe-nvenc-wsl2.sh` and nomercy-ffmpeg#42.

Windows NVENC is verified natively instead. If that issue is fixed, Linux NVENC
coverage follows on the same box with no new hardware.

## Provisioning

Each script is idempotent and doubles as the repair path.

```bash
# On the Proxmox host — Linux runner and FreeBSD driver
RUNNER_TOKEN=$(gh api -X POST orgs/NoMercy-Entertainment/actions/runners/registration-token --jq .token)
RUNNER_TOKEN="$RUNNER_TOKEN" ./provision-linux-runner.sh

# On the Proxmox host — FreeBSD guest (prints the driver key to authorise)
AUTHORIZED_KEY="<driver public key>" ./provision-freebsd-vm.sh

# On the Mac mini — Rosetta, Lima, and the runner
RUNNER_TOKEN="$RUNNER_TOKEN" ./setup-mac-mini.sh

# On the Windows desktop — runner as a service (run elevated)
./install-runner-windows.ps1 -Token $token
```

The repository then needs three variables so the workflow can find the guests:

| Variable | Value |
|---|---|
| `VERIFY_LIMA_INSTANCE` | `linux-arm64` |
| `VERIFY_LIMA_BIN` | `/Users/stoney/lima/bin/limactl` |
| `VERIFY_FREEBSD_SSH_TARGET` | `root@192.168.2.245` |

## Surviving a reboot on the Mac

`actions-runner`'s `svc.sh` only ever produces a user **LaunchAgent**. Those load
at user login, not at boot, so an unattended reboot leaves every runner on the
Mac down until somebody logs in. That silently removes three of the six
platforms, and the checklist would just stay unticked with no obvious cause.

Hand-writing a LaunchDaemon is the obvious fix and the wrong one: the runner
requires `runsvc.sh` as its entry point, and a daemon outside the GUI session
loses the keychain, signing identities and simulators the Xcode runner needs.

So `install-macos-autostart.sh` makes the login happen instead, and adds a
watchdog for what login alone does not cover:

```bash
./install-macos-autostart.sh --auto-login
```

It prompts for the login password. Pass it on stdin when there is no terminal —
`--auto-login --password-stdin <<<"$pw"`. There is also a `--password` flag for
automation that cannot manage either, but prefer not to: `argv` is readable by
any local user through `ps` for as long as the script runs, and it lands in
shell history.

It enables auto-login, then installs `tv.nomercy.runner-watchdog`, a LaunchAgent
that runs every 5 minutes and starts anything that is down — the Lima guest,
which nothing else would ever start, and any runner service that is not loaded.
The watchdog only ever starts things, so it is safe next to runners owned by
someone else. It covers every `actions.runner.*` agent it finds, including the
Xcode one.

Verified by a real unattended reboot: auto-login took (`/dev/console` owned by
the user), the Lima guest was started by the watchdog, and both runners were
back online about 80 seconds after boot. The runner logs a
`Runner connect error: Conflict` for the first half-minute while the pre-reboot
session times out server-side; it retries and clears on its own.

Two things worth knowing. Auto-login requires FileVault to be **off** — the
installer refuses otherwise rather than leave you believing reboots are covered.
And `sysadminctl -autologin` is broken on macOS 26: it sets the user preference
and then fails the credential with `SACSetAutoLoginPassword error:22`, which
looks like success and is not. The installer verifies `/etc/kcpassword` exists
and writes it directly when that happens.

### The failure the watchdog cannot cover

The watchdog is a LaunchAgent, so it needs the session that auto-login exists to
create. If auto-login itself breaks, the watchdog is not running either, and the
machine comes back from a reboot with no runners and nothing saying why. Given
that `sysadminctl` has already been caught breaking auto-login without saying so,
that is not hypothetical.

`tv.nomercy.autologin-health` covers it. It is a LaunchDaemon, so it runs at boot
regardless of any session, and hourly after that. It checks the user preference,
`/etc/kcpassword` and FileVault, and writes to `/var/log/nomercy-autologin-health.log`
and the system log when any of them is wrong. It never repairs anything —
repairing auto-login needs the login password, and a root daemon holding that
would be worse than the fault it reports.

```bash
tail /var/log/nomercy-autologin-health.log
/usr/bin/log show --predicate 'eventMessage BEGINSWITH "nomercy-autologin:"' --last 1d
```

Spell out `/usr/bin/log`: `log` is a zsh builtin that takes no arguments, so the
bare command fails with `too many arguments` in the default macOS shell.

## Things that cost a rebuild, so they are written down

**Never `qm stop` the FreeBSD guest.** A hard power-off leaves the filesystem
dirty and the next boot aborts in fsck before sshd starts. The symptom is a VM
that pings but refuses SSH, which reads exactly like a provisioning failure and
is not one. Use `qm shutdown`.

**FreeBSD 14.3 images ship nuageinit, not Python cloud-init.** It provisions
users and SSH keys from the NoCloud drive and silently ignores `packages:`,
`runcmd:` and network configuration. It also refuses uid-0 accounts, so neither
`root` nor `toor` can be authorised through it. Anything past a user account has
to be baked into the image, which is why `provision-freebsd-vm.sh` edits the
image offline before first boot.

**Import the pool with `-N` and mount only the root dataset.** Importing with
`-R` alone mounts every dataset, and `/var/tmp` then refuses to unmount; the
export fails, and disconnecting the NBD device under a still-imported pool
suspends it. A suspended pool blocks `zpool export` indefinitely and cannot be
cleared until a device with matching labels is reattached.

**Pin FreeBSD to the version the fork cross-compiles against** — `FREEBSD_VERSION`
in `ffmpeg-freebsd-x86_64.dockerfile`, currently 14.3. A different major version
is a different ABI, so a pass there would not mean the shipped binary works.

**The Windows runner must be a service, not a logon task.** A logon task runs
inside the interactive session: it puts a console window on the owner's desktop
and dies at logout. Installing the service needs one elevated run, and there is
no `svc.cmd` on Windows — the service is created by `config.cmd --runasservice`,
so it must be chosen at registration time rather than converted afterwards.

Session 0 does not break NVENC on this hardware. Verified on an RTX 2080 SUPER
with the service running as `NT AUTHORITY\NETWORK SERVICE`: 23 passed, 0 failed,
NVENC among the passes. Re-check after a driver or GPU change — a session-0 NVENC
failure would look like an ordinary test failure on the one platform nothing else
in the fleet can cover.

## Relationship to Fillz's runner manager

The six `beast-unit` runners are Docker containers on Fillz's box, managed by his
own tool. These three are separate physical machines with their own labels and do
not appear there. They are two independent pools by design — the verification
fleet needs specific hardware, not interchangeable capacity.
