#!/usr/bin/env bash
# Proxmox resource usage breakdown
# Shows CPU, RAM, disk, and network usage for all VMs, LXCs, and Docker containers
#
# Usage: ./runners/proxmox-usage.sh

set -Eeuo pipefail

BOLD="\033[1m"
DIM="\033[2m"
CYAN="\033[36m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

hr() { printf '%*s\n' "${COLUMNS:-80}" '' | tr ' ' '─'; }
header() { echo -e "\n${BOLD}${CYAN}$1${RESET}"; hr; }

human_bytes() {
    local bytes=$1
    if (( bytes >= 1073741824 )); then
        printf "%.1f GB" "$(echo "scale=1; $bytes / 1073741824" | bc)"
    elif (( bytes >= 1048576 )); then
        printf "%.0f MB" "$(echo "scale=0; $bytes / 1048576" | bc)"
    elif (( bytes >= 1024 )); then
        printf "%.0f KB" "$(echo "scale=0; $bytes / 1024" | bc)"
    else
        printf "%d B" "$bytes"
    fi
}

bar() {
    local pct=$1
    local width=30
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local color=$GREEN
    if (( pct >= 90 )); then color=$RED
    elif (( pct >= 70 )); then color=$YELLOW
    fi
    printf "${color}["
    printf '%*s' "$filled" '' | tr ' ' '█'
    printf '%*s' "$empty" '' | tr ' ' '░'
    printf "]${RESET} %3d%%" "$pct"
}

########################################
# Host overview
########################################

header "HOST OVERVIEW"

# CPU
cpu_count=$(nproc)
cpu_load=$(awk '{print $1}' /proc/loadavg)
cpu_pct=$(awk "BEGIN {printf \"%.0f\", ($cpu_load / $cpu_count) * 100}")
(( cpu_pct > 100 )) && cpu_pct=100

printf "  %-14s " "CPU ($cpu_count cores)"
bar "$cpu_pct"
printf "  load: %s\n" "$cpu_load"

# RAM
read -r mem_total mem_avail <<< "$(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{print t*1024, a*1024}' /proc/meminfo)"
mem_used=$((mem_total - mem_avail))
mem_pct=$((mem_used * 100 / mem_total))

printf "  %-14s " "RAM"
bar "$mem_pct"
printf "  %s / %s\n" "$(human_bytes $mem_used)" "$(human_bytes $mem_total)"

# Swap
read -r swap_total swap_free <<< "$(awk '/SwapTotal/{t=$2} /SwapFree/{f=$2} END{print t*1024, f*1024}' /proc/meminfo)"
if (( swap_total > 0 )); then
    swap_used=$((swap_total - swap_free))
    swap_pct=$((swap_used * 100 / swap_total))
    printf "  %-14s " "Swap"
    bar "$swap_pct"
    printf "  %s / %s\n" "$(human_bytes $swap_used)" "$(human_bytes $swap_total)"
fi

# Disk
echo ""
printf "  ${BOLD}%-30s %8s %8s %8s %5s${RESET}\n" "Mount" "Size" "Used" "Avail" "Use%"
df -h --output=target,size,used,avail,pcent -x tmpfs -x devtmpfs -x squashfs 2>/dev/null | tail -n +2 | sort | while read -r mount size used avail pct; do
    printf "  %-30s %8s %8s %8s %5s\n" "$mount" "$size" "$used" "$avail" "$pct"
done

########################################
# ZFS pools (if present)
########################################

if command -v zpool >/dev/null 2>&1 && zpool list >/dev/null 2>&1; then
    header "ZFS POOLS"
    zpool list -o name,size,alloc,free,cap,health 2>/dev/null | while IFS= read -r line; do
        echo "  $line"
    done
fi

########################################
# Proxmox VMs
########################################

header "VIRTUAL MACHINES (QEMU)"

printf "  ${BOLD}%-6s %-30s %-10s %6s %10s %10s${RESET}\n" "VMID" "Name" "Status" "CPUs" "RAM" "Disk"

qm list 2>/dev/null | tail -n +2 | while read -r vmid name status mem_mb disk_gb cpus; do
    # Skip header artifacts
    [[ "$vmid" =~ ^[0-9]+$ ]] || continue
    printf "  %-6s %-30s %-10s %6s %8s MB %8s GB\n" "$vmid" "$name" "$status" "$cpus" "$mem_mb" "${disk_gb:-?}"
done

vm_count=$(qm list 2>/dev/null | tail -n +2 | wc -l)
vm_running=$(qm list 2>/dev/null | grep -c "running" || true)
echo -e "\n  ${DIM}Total: ${vm_count} VMs (${vm_running} running)${RESET}"

########################################
# Proxmox LXC containers
########################################

header "LXC CONTAINERS"

printf "  ${BOLD}%-6s %-30s %-10s %6s %10s %10s${RESET}\n" "CTID" "Name" "Status" "CPUs" "RAM" "Disk"

pct list 2>/dev/null | tail -n +2 | while read -r ctid status _ name; do
    [[ "$ctid" =~ ^[0-9]+$ ]] || continue
    cores=$(pct config "$ctid" 2>/dev/null | awk '/^cores:/{print $2}')
    mem=$(pct config "$ctid" 2>/dev/null | awk '/^memory:/{print $2}')
    disk=$(pct config "$ctid" 2>/dev/null | grep '^rootfs:' | grep -oP 'size=\K[^,]+')
    printf "  %-6s %-30s %-10s %6s %8s MB %10s\n" "$ctid" "$name" "$status" "${cores:-?}" "${mem:-?}" "${disk:-?}"
done

lxc_count=$(pct list 2>/dev/null | tail -n +2 | wc -l)
lxc_running=$(pct list 2>/dev/null | grep -c "running" || true)
echo -e "\n  ${DIM}Total: ${lxc_count} containers (${lxc_running} running)${RESET}"

########################################
# Docker containers (on this host)
########################################

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    header "DOCKER CONTAINERS"

    printf "  ${BOLD}%-40s %-12s %8s %8s %15s${RESET}\n" "Name" "Status" "CPU %" "RAM" "Net I/O"

    docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}' 2>/dev/null | sort | while IFS=$'\t' read -r name cpu mem net; do
        status=$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null || echo "?")
        mem_short=$(echo "$mem" | awk -F' / ' '{print $1}')
        printf "  %-40s %-12s %8s %8s %15s\n" "$name" "$status" "$cpu" "$mem_short" "$net"
    done

    echo ""

    # Docker disk usage
    echo -e "  ${BOLD}Docker Disk Usage:${RESET}"
    docker system df 2>/dev/null | while IFS= read -r line; do
        echo "    $line"
    done
fi

########################################
# Docker in VMs/LXCs (scan running guests)
########################################

header "DOCKER IN GUEST VMs/LXCs"

# Check running LXC containers for Docker
for ctid in $(pct list 2>/dev/null | awk '/running/{print $1}'); do
    name=$(pct config "$ctid" 2>/dev/null | awk '/^hostname:/{print $2}')
    docker_out=$(pct exec "$ctid" -- docker ps --format '{{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null) || continue
    if [[ -n "$docker_out" ]]; then
        echo -e "\n  ${BOLD}LXC ${ctid} (${name}):${RESET}"
        printf "    ${BOLD}%-35s %-25s %s${RESET}\n" "Container" "Status" "Image"
        echo "$docker_out" | while IFS=$'\t' read -r cname cstatus cimage; do
            printf "    %-35s %-25s %s\n" "$cname" "$cstatus" "$cimage"
        done
    fi
done

# Check running VMs via SSH (only if guest agent is available)
for vmid in $(qm list 2>/dev/null | awk '/running/{print $1}'); do
    name=$(qm config "$vmid" 2>/dev/null | awk '/^name:/{print $2}')
    ip=$(qm guest cmd "$vmid" network-get-interfaces 2>/dev/null \
        | jq -r '[.[].["ip-addresses"][] | select(.["ip-address-type"] == "ipv4") | .["ip-address"] | select(startswith("127.") | not)] | first // empty' 2>/dev/null) || continue
    [[ -n "$ip" ]] || continue

    docker_out=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 -o BatchMode=yes "$ip" \
        "docker ps --format '{{.Names}}\t{{.Status}}\t{{.Image}}'" 2>/dev/null) || continue
    if [[ -n "$docker_out" ]]; then
        echo -e "\n  ${BOLD}VM ${vmid} (${name} @ ${ip}):${RESET}"
        printf "    ${BOLD}%-35s %-25s %s${RESET}\n" "Container" "Status" "Image"
        echo "$docker_out" | while IFS=$'\t' read -r cname cstatus cimage; do
            printf "    %-35s %-25s %s\n" "$cname" "$cstatus" "$cimage"
        done
    fi
done

########################################
# Summary
########################################

header "RESOURCE TOTALS"

# Total allocated vs available
total_vm_cores=0
total_vm_mem=0
total_lxc_cores=0
total_lxc_mem=0

while read -r vmid name status mem_mb _ cpus; do
    [[ "$vmid" =~ ^[0-9]+$ ]] || continue
    [[ "$status" == "running" ]] || continue
    total_vm_cores=$((total_vm_cores + cpus))
    total_vm_mem=$((total_vm_mem + mem_mb))
done < <(qm list 2>/dev/null | tail -n +2)

for ctid in $(pct list 2>/dev/null | awk '/running/{print $1}'); do
    cores=$(pct config "$ctid" 2>/dev/null | awk '/^cores:/{print $2}')
    mem=$(pct config "$ctid" 2>/dev/null | awk '/^memory:/{print $2}')
    total_lxc_cores=$((total_lxc_cores + ${cores:-0}))
    total_lxc_mem=$((total_lxc_mem + ${mem:-0}))
done

total_cores=$((total_vm_cores + total_lxc_cores))
total_mem=$((total_vm_mem + total_lxc_mem))

printf "  %-20s %6d cores  %8s MB\n" "Running VMs:" "$total_vm_cores" "$total_vm_mem"
printf "  %-20s %6d cores  %8s MB\n" "Running LXCs:" "$total_lxc_cores" "$total_lxc_mem"
hr
printf "  ${BOLD}%-20s %6d cores  %8s MB${RESET}\n" "Total allocated:" "$total_cores" "$total_mem"
printf "  %-20s %6d cores  %8s MB\n" "Host physical:" "$cpu_count" "$((mem_total / 1048576))"

overcommit_cpu=$((total_cores * 100 / cpu_count))
overcommit_mem=$((total_mem * 100 / (mem_total / 1048576)))
echo ""
printf "  CPU overcommit:  %d%%\n" "$overcommit_cpu"
printf "  RAM overcommit:  %d%%\n" "$overcommit_mem"

echo ""
