#!/usr/bin/env bash
# Builds the FreeBSD guest that verifies freebsd-x86_64. Run this ON the
# Proxmox host.
#
# FreeBSD is the awkward leg of the fleet and the reasons are worth stating,
# because every one of them cost a rebuild:
#
#   * There is no official GitHub Actions runner for FreeBSD, so a Linux runner
#     drives this guest over SSH. The suite still executes on FreeBSD.
#   * The version is pinned to whatever the fork cross-compiles against
#     (FREEBSD_VERSION in ffmpeg-freebsd-x86_64.dockerfile, currently 14.3).
#     Testing on a different major version tests a different ABI.
#   * FreeBSD 14.3 VM images ship nuageinit, not Python cloud-init. It honours
#     users and SSH keys from the NoCloud drive and ignores packages, runcmd and
#     network configuration. Anything beyond a user account must be baked in.
#   * So the image is prepared offline here: the ZFS variant is imported on the
#     host, edited, and exported before first boot. The pool is imported with -N
#     and only the root dataset is mounted — importing with -R mounts every
#     dataset, and /var/tmp then refuses to unmount, which wedges the pool.
#   * Never `qm stop` this guest. A hard power-off leaves UFS/ZFS dirty and the
#     next boot aborts in fsck before sshd starts, which looks exactly like a
#     provisioning failure. Use `qm shutdown`.
set -euo pipefail

VMID="${VMID:-6100}"
NAME="${NAME:-ffmpeg-verify-freebsd}"
FREEBSD_VERSION="${FREEBSD_VERSION:-14.3}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
CORES="${CORES:-6}"
MEMORY="${MEMORY:-8192}"
STATIC_IP="${STATIC_IP:-192.168.2.245}"
GATEWAY="${GATEWAY:-192.168.2.1}"
NETMASK="${NETMASK:-255.255.255.0}"
AUTHORIZED_KEY="${AUTHORIZED_KEY:-}"
IMAGE_DIR="${IMAGE_DIR:-/var/lib/vz/template/iso}"
IMAGE="${IMAGE_DIR}/freebsd-${FREEBSD_VERSION}-zfs.qcow2"
POOL_ALIAS="${POOL_ALIAS:-fbverify}"
MNT="${MNT:-/mnt/fbverify}"

[[ -n "$AUTHORIZED_KEY" ]] || {
	echo "Error: AUTHORIZED_KEY is required (the driver container's public key)." >&2
	exit 2
}

URL="https://download.freebsd.org/releases/VM-IMAGES/${FREEBSD_VERSION}-RELEASE/amd64/Latest/FreeBSD-${FREEBSD_VERSION}-RELEASE-amd64-BASIC-CLOUDINIT-zfs.qcow2.xz"

if [[ ! -f "$IMAGE" ]]; then
	echo "Downloading FreeBSD ${FREEBSD_VERSION} ZFS image…"
	curl -fsSL -o "${IMAGE}.xz" "$URL"
	unxz -f "${IMAGE}.xz"
fi

cleanup() {
	zpool export "$POOL_ALIAS" 2>/dev/null || true
	qemu-nbd --disconnect /dev/nbd0 >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Preparing the image offline…"
modprobe nbd max_part=16
qemu-nbd --disconnect /dev/nbd0 >/dev/null 2>&1 || true
qemu-nbd --connect=/dev/nbd0 "$IMAGE"
sleep 3

# Import by GUID under an alias: the pool inside the image is called zroot, and
# a host that already has a zroot (or a wedged leftover) would collide.
GUID=$(zpool import 2>/dev/null | awk '/id:/ {print $2; exit}')
[[ -n "$GUID" ]] || {
	echo "No importable pool found in ${IMAGE}." >&2
	exit 1
}

mkdir -p "$MNT"
zpool import -N -f -R "$MNT" "$GUID" "$POOL_ALIAS"
zfs mount "${POOL_ALIAS}/ROOT/default"

echo "Injecting sshd, network and the driver key…"
cat >>"${MNT}/etc/rc.conf" <<RC
sshd_enable="YES"
ifconfig_vtnet0="inet ${STATIC_IP} netmask ${NETMASK}"
defaultrouter="${GATEWAY}"
RC

mkdir -p "${MNT}/root/.ssh"
chmod 700 "${MNT}/root/.ssh"
printf '%s\n' "$AUTHORIZED_KEY" >"${MNT}/root/.ssh/authorized_keys"
chmod 600 "${MNT}/root/.ssh/authorized_keys"
printf 'nameserver %s\n' "$GATEWAY" >"${MNT}/etc/resolv.conf"

# FreeBSD's compiled default is prohibit-password, but be explicit — a future
# image that ships "PermitRootLogin no" would break the driver silently.
if grep -q '^#*PermitRootLogin' "${MNT}/etc/ssh/sshd_config"; then
	sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' "${MNT}/etc/ssh/sshd_config"
else
	echo 'PermitRootLogin prohibit-password' >>"${MNT}/etc/ssh/sshd_config"
fi

echo "Unmounting cleanly…"
zfs unmount "${POOL_ALIAS}/ROOT/default"
zpool export "$POOL_ALIAS"
qemu-nbd --disconnect /dev/nbd0
trap - EXIT

if qm status "$VMID" >/dev/null 2>&1; then
	echo "Removing the previous VM ${VMID}…"
	qm shutdown "$VMID" --timeout 90 2>/dev/null || qm stop "$VMID" 2>/dev/null || true
	sleep 5
	qm destroy "$VMID" --purge --destroy-unreferenced-disks 1 >/dev/null
fi

echo "Creating VM ${VMID}…"
qm create "$VMID" --name "$NAME" --memory "$MEMORY" --cores "$CORES" \
	--net0 "virtio,bridge=${BRIDGE}" --scsihw virtio-scsi-single \
	--ostype other --serial0 socket --vga serial0 --onboot 1
qm importdisk "$VMID" "$IMAGE" "$STORAGE" >/dev/null
qm set "$VMID" --scsi0 "${STORAGE}:vm-${VMID}-disk-0" >/dev/null
qm set "$VMID" --boot order=scsi0 >/dev/null
qm resize "$VMID" scsi0 +10G >/dev/null
qm start "$VMID"

echo "Waiting for sshd on ${STATIC_IP}…"
for _ in $(seq 1 60); do
	if (echo >"/dev/tcp/${STATIC_IP}/22") >/dev/null 2>&1; then
		echo "✅ FreeBSD guest ${VMID} is up at ${STATIC_IP}"
		exit 0
	fi
	sleep 5
done

echo "❌ ${STATIC_IP} never opened port 22 — check the serial console." >&2
exit 1
