#!/usr/bin/env bash
# Proxmox resource usage breakdown
# Usage: ./runners/proxmox-usage.sh

set -Eeuo pipefail

# Colors
B="\e[1m"      # bold
D="\e[2m"      # dim
C="\e[36m"     # cyan
G="\e[32m"     # green
Y="\e[33m"     # yellow
R="\e[31m"     # red
W="\e[37m"     # white
N="\e[0m"      # reset

hr()     { printf '  %s\n' "$(printf '%0.s-' {1..76})"; }
header() { printf '\n  %b%b %s %b\n' "$B" "$C" "$1" "$N"; hr; }

human_bytes() {
    local b=$1
    if (( b >= 1073741824 )); then printf "%.1f GB" "$(echo "scale=1; $b/1073741824" | bc)"
    elif (( b >= 1048576 ));  then printf "%.0f MB" "$(echo "scale=0; $b/1048576" | bc)"
    elif (( b >= 1024 ));     then printf "%.0f KB" "$(echo "scale=0; $b/1024" | bc)"
    else printf "%d B" "$b"; fi
}

bar() {
    local pct=$1 width=25
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local c=$G
    (( pct >= 70 )) && c=$Y
    (( pct >= 90 )) && c=$R
    printf "%b" "$c"
    printf '%*s' "$filled" '' | tr ' ' '#'
    printf '%b' "$D"
    printf '%*s' "$empty" '' | tr ' ' '-'
    printf '%b %3d%%' "$N" "$pct"
}

echo ""
printf "  %b%b=== NoMercy Proxmox Resource Usage ===%b\n" "$B" "$C" "$N"

# =========================================================================
header "HOST"
# =========================================================================

cpu_count=$(nproc)
cpu_load=$(awk '{printf "%.2f / %.2f / %.2f", $1, $2, $3}' /proc/loadavg)

# Actual CPU usage from /proc/stat (sample over 1 second)
read -r _ u1 n1 s1 i1 w1 _ <<< "$(head -1 /proc/stat)"
sleep 1
read -r _ u2 n2 s2 i2 w2 _ <<< "$(head -1 /proc/stat)"
idle=$((i2 - i1))
total=$(( (u2+n2+s2+i2+w2) - (u1+n1+s1+i1+w1) ))
if (( total > 0 )); then
    cpu_pct=$(( (total - idle) * 100 / total ))
else
    cpu_pct=0
fi

read -r mem_total mem_avail <<< "$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{print t*1024,a*1024}' /proc/meminfo)"
mem_used=$((mem_total - mem_avail))
mem_pct=$((mem_used * 100 / mem_total))

read -r swap_total swap_free <<< "$(awk '/SwapTotal/{t=$2}/SwapFree/{f=$2}END{print t*1024,f*1024}' /proc/meminfo)"

printf "  %-18s " "CPU (${cpu_count} cores)"
bar "$cpu_pct"
printf "   load %s\n" "$cpu_load"

printf "  %-18s " "Memory"
bar "$mem_pct"
printf "   %s / %s\n" "$(human_bytes $mem_used)" "$(human_bytes $mem_total)"

if (( swap_total > 0 )); then
    swap_used=$((swap_total - swap_free))
    swap_pct=$((swap_used * 100 / swap_total))
    printf "  %-18s " "Swap"
    bar "$swap_pct"
    printf "   %s / %s\n" "$(human_bytes $swap_used)" "$(human_bytes $swap_total)"
fi

# =========================================================================
header "STORAGE"
# =========================================================================

printf "  %b%-32s %7s %7s %7s %5s%b\n" "$B" "Mount" "Size" "Used" "Free" "Use%" "$N"
df -h --output=target,size,used,avail,pcent -x tmpfs -x devtmpfs -x squashfs 2>/dev/null \
    | tail -n +2 | sort | while read -r mount size used avail pct; do
    printf "  %-32s %7s %7s %7s %5s\n" "$mount" "$size" "$used" "$avail" "$pct"
done

if command -v zpool >/dev/null 2>&1 && zpool list -H >/dev/null 2>&1; then
    echo ""
    printf "  %bZFS Pools:%b\n" "$B" "$N"
    zpool list -o name,size,alloc,free,cap,health 2>/dev/null | while IFS= read -r line; do
        echo "  $line"
    done
fi

# =========================================================================
header "VIRTUAL MACHINES"
# =========================================================================

total_vm_cores=0
total_vm_mem=0
vm_count=0
vm_running=0

printf "  %b%-6s %-28s %-10s %5s %8s %8s%b\n" "$B" "VMID" "Name" "Status" "CPUs" "RAM" "Disk" "$N"

for vmid in $(qm list 2>/dev/null | awk 'NR>1{print $1}'); do
    [[ "$vmid" =~ ^[0-9]+$ ]] || continue
    vm_count=$((vm_count + 1))

    cfg=$(qm config "$vmid" 2>/dev/null)
    vm_name=$(echo "$cfg" | awk '/^name:/{print $2}')
    vm_cores=$(echo "$cfg" | awk '/^cores:/{print $2}')
    vm_mem=$(echo "$cfg" | awk '/^memory:/{print $2}')
    vm_status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')

    # Disk: sum all scsi/virtio/sata disks
    vm_disk=$(echo "$cfg" | grep -oP 'size=\K[^,]+' | head -1)

    if [[ "$vm_status" == "running" ]]; then
        vm_running=$((vm_running + 1))
        total_vm_cores=$((total_vm_cores + ${vm_cores:-0}))
        total_vm_mem=$((total_vm_mem + ${vm_mem:-0}))
        printf "  %b%-6s%b %-28s %b%-10s%b %5s %6s M %8s\n" \
            "$G" "$vmid" "$N" "${vm_name:--}" "$G" "$vm_status" "$N" "${vm_cores:-?}" "${vm_mem:-?}" "${vm_disk:-?}"
    else
        printf "  %b%-6s%b %-28s %b%-10s%b %5s %6s M %8s\n" \
            "$D" "$vmid" "$N" "${vm_name:--}" "$D" "$vm_status" "$N" "${vm_cores:-?}" "${vm_mem:-?}" "${vm_disk:-?}"
    fi
done

printf "\n  %bTotal: %d VMs (%d running)%b\n" "$D" "$vm_count" "$vm_running" "$N"

# =========================================================================
header "LXC CONTAINERS"
# =========================================================================

total_lxc_cores=0
total_lxc_mem=0
lxc_count=0
lxc_running=0

printf "  %b%-6s %-28s %-10s %5s %8s %8s%b\n" "$B" "CTID" "Name" "Status" "CPUs" "RAM" "Disk" "$N"

for ctid in $(pct list 2>/dev/null | awk 'NR>1{print $1}'); do
    [[ "$ctid" =~ ^[0-9]+$ ]] || continue
    lxc_count=$((lxc_count + 1))

    cfg=$(pct config "$ctid" 2>/dev/null)
    ct_name=$(echo "$cfg" | awk '/^hostname:/{print $2}')
    ct_cores=$(echo "$cfg" | awk '/^cores:/{print $2}')
    ct_mem=$(echo "$cfg" | awk '/^memory:/{print $2}')
    ct_disk=$(echo "$cfg" | grep '^rootfs:' | grep -oP 'size=\K[^,]+')
    ct_status=$(pct status "$ctid" 2>/dev/null | awk '{print $2}')

    if [[ "$ct_status" == "running" ]]; then
        lxc_running=$((lxc_running + 1))
        total_lxc_cores=$((total_lxc_cores + ${ct_cores:-0}))
        total_lxc_mem=$((total_lxc_mem + ${ct_mem:-0}))
        printf "  %b%-6s%b %-28s %b%-10s%b %5s %6s M %8s\n" \
            "$G" "$ctid" "$N" "${ct_name:--}" "$G" "$ct_status" "$N" "${ct_cores:-?}" "${ct_mem:-?}" "${ct_disk:-?}"
    else
        printf "  %b%-6s%b %-28s %b%-10s%b %5s %6s M %8s\n" \
            "$D" "$ctid" "$N" "${ct_name:--}" "$D" "$ct_status" "$N" "${ct_cores:-?}" "${ct_mem:-?}" "${ct_disk:-?}"
    fi
done

printf "\n  %bTotal: %d containers (%d running)%b\n" "$D" "$lxc_count" "$lxc_running" "$N"

# =========================================================================
header "DOCKER (HOST)"
# =========================================================================

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    printf "  %b%-38s %-10s %7s %10s %14s%b\n" "$B" "Container" "Status" "CPU" "Memory" "Net I/O" "$N"

    docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}' 2>/dev/null \
        | sort | while IFS=$'\t' read -r name cpu mem net; do
        mem_short=$(echo "$mem" | awk -F' / ' '{print $1}')
        printf "  %-38s %-10s %7s %10s %14s\n" "$name" "running" "$cpu" "$mem_short" "$net"
    done

    echo ""
    printf "  %bDisk:%b\n" "$B" "$N"
    docker system df 2>/dev/null | while IFS= read -r line; do
        echo "    $line"
    done
else
    printf "  %bDocker not available on host%b\n" "$D" "$N"
fi

# =========================================================================
header "DOCKER (GUESTS)"
# =========================================================================

found_guest_docker=0

# Reusable function to print docker containers grouped by type
print_guest_docker() {
    local docker_out="$1"
    local runner_count=0
    local svc_lines=""

    while IFS=$'\t' read -r cname cstatus cimage; do
        [[ -n "$cname" ]] || continue
        if [[ "$cname" == *runner* ]]; then
            runner_count=$((runner_count + 1))
        else
            svc_lines="${svc_lines}$(printf '    %-44s %-24s %s' "$cname" "$cstatus" "$cimage")"$'\n'
        fi
    done <<< "$docker_out"

    if [[ -n "$svc_lines" ]]; then
        printf "    %b%-44s %-24s %s%b\n" "$B" "Service" "Status" "Image" "$N"
        printf '%s' "$svc_lines"
        echo ""
    fi

    if (( runner_count > 0 )); then
        printf "    %bGitHub Runners: %d active%b\n" "$B" "$runner_count" "$N"
    fi
}

# LXC guests
for ctid in $(pct list 2>/dev/null | awk '/running/{print $1}'); do
    ct_name=$(pct config "$ctid" 2>/dev/null | awk '/^hostname:/{print $2}')
    docker_out=$(pct exec "$ctid" -- docker ps --format '{{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null) || continue
    [[ -n "$docker_out" ]] || continue
    found_guest_docker=1

    printf "\n  %bLXC %s (%s)%b\n\n" "$B" "$ctid" "${ct_name:--}" "$N"
    print_guest_docker "$docker_out"
done

# VM guests
for vmid in $(qm list 2>/dev/null | awk '/running/{print $1}'); do
    vm_name=$(qm config "$vmid" 2>/dev/null | awk '/^name:/{print $2}')
    ip=$(qm guest cmd "$vmid" network-get-interfaces 2>/dev/null \
        | jq -r '[.[].["ip-addresses"][]|select(.["ip-address-type"]=="ipv4")|.["ip-address"]|select(startswith("127.")|not)]|first//empty' 2>/dev/null) || continue
    [[ -n "$ip" ]] || continue

    docker_out=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 -o BatchMode=yes "$ip" \
        "docker ps --format '{{.Names}}\t{{.Status}}\t{{.Image}}'" 2>/dev/null) || continue
    [[ -n "$docker_out" ]] || continue
    found_guest_docker=1

    printf "\n  %bVM %s (%s @ %s)%b\n\n" "$B" "$vmid" "${vm_name:--}" "$ip" "$N"
    print_guest_docker "$docker_out"
done

(( found_guest_docker )) || printf "  %bNo Docker found in running guests%b\n" "$D" "$N"

# =========================================================================
header "TOTALS"
# =========================================================================

total_cores=$((total_vm_cores + total_lxc_cores))
total_mem=$((total_vm_mem + total_lxc_mem))

printf "  %b%-22s %6s cores   %7s MB%b\n" "$W" "VMs (running):" "$total_vm_cores" "$total_vm_mem" "$N"
printf "  %b%-22s %6s cores   %7s MB%b\n" "$W" "LXCs (running):" "$total_lxc_cores" "$total_lxc_mem" "$N"
hr
printf "  %b%-22s %6s cores   %7s MB%b\n" "$B" "Total allocated:" "$total_cores" "$total_mem" "$N"
printf "  %-22s %6s cores   %7s MB\n" "Host physical:" "$cpu_count" "$((mem_total / 1048576))"

echo ""
if (( cpu_count > 0 && total_cores > 0 )); then
    printf "  CPU overcommit:  %b%dx%b\n" "$B" "$((total_cores / cpu_count))" "$N"
fi
if (( mem_total > 0 && total_mem > 0 )); then
    mem_total_mb=$((mem_total / 1048576))
    if (( mem_total_mb > 0 )); then
        printf "  RAM overcommit:  %b%d%%%b\n" "$B" "$((total_mem * 100 / mem_total_mb))" "$N"
    fi
fi

echo ""
