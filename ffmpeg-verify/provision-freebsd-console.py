#!/usr/bin/env python3
"""Provision the FreeBSD verification guest through its serial console.

Runs ON the Proxmox host. FreeBSD 14.3's VM images ship nuageinit rather than
Python cloud-init: it honours `users:` and SSH keys from the NoCloud drive, but
silently ignores `packages:`, `runcmd:` and network configuration. That leaves
no in-band way to reach root on a fresh guest, so this drives the boot loader
into single-user mode and installs the root key itself.

Single-user is also the only place the root filesystem can be modified before
sshd starts, which is what makes this reproducible from a pristine image.

Usage: provision-freebsd-console.py <vmid> <authorized_key> [static_ip] [gateway]
"""

import re
import socket
import subprocess
import sys
import time

SOCKET_TEMPLATE = "/var/run/qemu-server/{vmid}.serial0"
BOOT_MENU = re.compile(rb"Autoboot in|Boot Multi user|Welcome to FreeBSD")
SINGLE_USER_PROMPT = re.compile(rb"Enter full pathname of shell or RETURN for /bin/sh")
SHELL_PROMPT = re.compile(rb"# $|#\s*$")


class Console:
    def __init__(self, vmid):
        self.path = SOCKET_TEMPLATE.format(vmid=vmid)
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(self.path)
        self.sock.settimeout(1.0)
        self.buffer = b""

    def read_until(self, pattern, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                chunk = self.sock.recv(4096)
            except socket.timeout:
                continue
            if not chunk:
                time.sleep(0.1)
                continue
            self.buffer += chunk
            sys.stdout.write(chunk.decode("utf-8", "replace"))
            sys.stdout.flush()
            if pattern.search(self.buffer[-4096:]):
                return True
        return False

    def send(self, text):
        self.sock.sendall(text.encode())
        time.sleep(0.4)

    def run(self, command, settle=1.5):
        """Send a command and give the guest time to finish it.

        The console gives no reliable completion signal for long-running
        commands, so callers pass a settle time sized to the work.
        """
        self.buffer = b""
        self.send(command + "\n")
        time.sleep(settle)
        try:
            while True:
                chunk = self.sock.recv(4096)
                if not chunk:
                    break
                self.buffer += chunk
                sys.stdout.write(chunk.decode("utf-8", "replace"))
        except socket.timeout:
            pass
        sys.stdout.flush()


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2

    vmid = sys.argv[1]
    authorized_key = sys.argv[2]
    static_ip = sys.argv[3] if len(sys.argv) > 3 else ""
    gateway = sys.argv[4] if len(sys.argv) > 4 else ""

    # ACPI shutdown, never `qm stop`. A hard power-off leaves UFS dirty, and the
    # next boot aborts in fsck before sshd ever starts — which looks exactly
    # like a provisioning failure and is not one.
    subprocess.run(["qm", "shutdown", vmid, "--timeout", "90"], check=False)
    time.sleep(5)
    subprocess.run(["qm", "start", vmid], check=True)
    time.sleep(2)

    console = Console(vmid)

    print("\n── waiting for the boot menu ──")
    if not console.read_until(BOOT_MENU, timeout=90):
        print("❌ never saw the boot menu")
        return 1

    print("\n── selecting single user ──")
    console.send("2")

    if not console.read_until(SINGLE_USER_PROMPT, timeout=120):
        print("❌ never reached the single-user prompt")
        return 1
    console.send("\n")
    time.sleep(2)

    print("\n── provisioning ──")
    console.run("mount -u /")
    console.run("mount -a")
    console.run("mkdir -p /root/.ssh && chmod 700 /root/.ssh")
    console.run(f"printf '%s\\n' '{authorized_key}' > /root/.ssh/authorized_keys")
    console.run("chmod 600 /root/.ssh/authorized_keys")
    console.run("sysrc sshd_enable=YES")
    console.run("sysrc -f /etc/ssh/sshd_config.nomercy x=1 >/dev/null 2>&1 || true")
    console.run(
        "grep -q '^PermitRootLogin prohibit-password' /etc/ssh/sshd_config "
        "|| echo 'PermitRootLogin prohibit-password' >> /etc/ssh/sshd_config"
    )

    if static_ip and gateway:
        console.run(f'sysrc ifconfig_vtnet0="inet {static_ip} netmask 255.255.255.0"')
        console.run(f'sysrc defaultrouter="{gateway}"')
        console.run('sysrc -x ifconfig_DEFAULT >/dev/null 2>&1 || true')

    console.run("cat /root/.ssh/authorized_keys")
    console.run("grep -E 'sshd_enable|ifconfig|defaultrouter' /etc/rc.conf")

    print("\n── rebooting into multi-user ──")
    console.run("reboot", settle=3)
    return 0


if __name__ == "__main__":
    sys.exit(main())
