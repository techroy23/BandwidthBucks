#!/bin/bash
set -euo pipefail

# -----------------------------
# Usage / Help Output
# -----------------------------
print_usage() {
    echo -e " "
    echo -e "\033[1;34m   ╔═══════════════════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;34m   ║\033[0m  # # # # # # # # # # # \033[1;36mBandwidth Bucks\033[0m # # # # # # # # # # #  \033[1;34m║\033[0m"
    echo -e "\033[1;34m   ╠═══════════════════════════════════════════════════════════════╣\033[0m"
    echo -e "\033[1;34m   ║\033[0m                                                               \033[1;34m║\033[0m"
    echo -e "\033[1;34m   ║\033[0m  \033[1;35mUsage:\033[0m      bandwidthBucks.sh \033[1mCOMMAND\033[0m                        \033[1;34m║\033[0m"
    echo -e "\033[1;34m   ║\033[0m                                                               \033[1;34m║\033[0m"
    echo -e "\033[1;34m   ║\033[0m  \033[1;35mCommands:\033[0m                                                    \033[1;34m║\033[0m"
    echo -e "\033[1;34m   ║\033[0m    \033[1;32mSTART\033[0m   - Deploy enabled containers (direct or via proxy)  \033[1;34m║\033[0m"
    echo -e "\033[1;34m   ║\033[0m    \033[1;31mSTOP\033[0m    - Stop and remove all tracked containers           \033[1;34m║\033[0m"
    echo -e "\033[1;34m   ║\033[0m    \033[1;33mPULL\033[0m    - Pull latest images for enabled containers        \033[1;34m║\033[0m"
    echo -e "\033[1;34m   ║\033[0m    \033[1;36mCLEAN\033[0m   - Force-remove leftovers and reset state           \033[1;34m║\033[0m"
    echo -e "\033[1;34m   ║\033[0m                                                               \033[1;34m║\033[0m"
    echo -e "\033[1;34m   ║\033[0m  \033[1;35mNotes:\033[0m                                                       \033[1;34m║\033[0m"
    echo -e "\033[1;34m   ║\033[0m    Set \033[1;32mPROXY=ENABLED\033[0m in .env and list proxies in proxy.txt    \033[1;34m║\033[0m"
    echo -e "\033[1;34m   ║\033[0m    Single proxy → one tun2socks + apps with shared suffix     \033[1;34m║\033[0m"
    echo -e "\033[1;34m   ║\033[0m    Multiple proxies → tun2socks + apps with counter suffixes  \033[1;34m║\033[0m"
    echo -e "\033[1;34m   ║\033[0m                                                               \033[1;34m║\033[0m"
    echo -e "\033[1;34m   ╚═══════════════════════════════════════════════════════════════╝\033[0m"
    echo -e " "
}

# -----------------------------
# Privilege & Docker Checks
# -----------------------------
if [[ $EUID -ne 0 ]]; then
    echo "❌ This script must be run as root. Exiting."
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "❌ Docker is not installed or not in PATH."
    echo "⚠️ Please install Docker before running this script."
    exit 1
fi

if ! groups root | grep -q '\bdocker\b'; then
    echo "❌ Root is not part of the 'docker' group."
    echo "⚠️ Add with: sudo usermod -aG docker root"
    echo "⚠️ Then log out/in or restart before retrying."
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo "❌ Docker daemon not reachable. Is it running?"
    exit 1
fi

# -----------------------------
# Load environment
# -----------------------------
if [[ -f .env ]]; then
    source .env
else
    echo ".env file not found!"
    exit 1
fi

RUN_SUFFIX=""
STATE_FILE=".containers/state"
FAILED_FILE=".containers/failed_removals.log"
mkdir -p ".containers"

# -----------------------------
# Script Helpers
# -----------------------------
random_suffix() {
    shuf -i 10000-99999 -n 1
}

generate_unique_suffix() {
    local suffix
    while true; do
        suffix=$(shuf -i 10000-99999 -n 1)
        if ! docker ps -a --format '{{.Names}}' | grep -q "_${suffix}\(_[0-9]\{5\}\)\?$"; then
            echo "$suffix"
            return
        fi
        echo "⚠️ Suffix $suffix already in use, retrying..."
    done
}

record_container() {
    local app="$1"
    local cname="$2"
    echo "$app:$cname" >> "$STATE_FILE"
}

dns_flags() {
    echo "--dns 1.1.1.1 --dns 8.8.8.8 --dns 9.9.9.9"
}

extra_flags() {
    local restart="${RESTART_MODE:-always}"
    local shm="${SHM_SIZE:-2g}"
    echo "--privileged --restart=${restart} --shm-size=${shm}"
}

log_driver_flag() {
    if [[ "${LOG:-DISABLED}" == "DISABLED" ]]; then
        echo "--log-driver=none"
    else
        echo "--log-driver=json-file --log-opt max-size=5m --log-opt max-file=1"
    fi
}

# -----------------------------
# Sysctl Settings
# -----------------------------
apply_sysctl_settings() {
    local SYSCTL_SETTINGS=(
        "net.core.rmem_max=8000000"
        "net.core.wmem_max=8000000"
        "net.core.somaxconn=65535"
        "net.core.netdev_max_backlog=65535"
        "net.ipv4.ip_forward=1"
    )

    echo "Applying kernel sysctl settings..."
    for setting in "${SYSCTL_SETTINGS[@]}"; do
        key="${setting%%=*}"
        val="${setting#*=}"
        echo "  - $key = $val"
        sysctl -w "$key=$val" >/dev/null
    done

    if [[ -w /etc/sysctl.conf ]]; then
        for setting in "${SYSCTL_SETTINGS[@]}"; do
            key="${setting%%=*}"
            sed -i "/^[[:space:]]*${key}[[:space:]]*=/d" /etc/sysctl.conf
            echo "$setting" >> /etc/sysctl.conf
        done
        echo "♻️ Reloading persisted sysctl settings from /etc/sysctl.conf..."
        sysctl -p >/dev/null
    else
        echo "⚠️ Cannot persist sysctl settings (no write access to /etc/sysctl.conf)."
    fi
}

# -----------------------------
# Proxy Helpers
# -----------------------------
valid_proxy_line() {
    local line="$1"
    [[ "$line" =~ ^(http|socks4|socks5|relay):// ]] && return 0 || return 1
}

run_tun2socks() {
    local proxy_url="$1"
    local index="$2"
    local cname
    if [[ -z "$index" ]]; then
        cname="tun2socks_${RUN_SUFFIX}"
    else
        cname=$(printf "tun2socks_%s_%05d" "$RUN_SUFFIX" "$index")
    fi
    echo "Deploying tun2socks as $cname with proxy $proxy_url..." >&2
    cid=$(docker create --name="$cname" $(extra_flags) $(dns_flags) $(log_driver_flag) --sysctl net.ipv4.ip_forward=1 \
        -e PROXY="$proxy_url" \
        xjasonlyu/tun2socks) || {
        echo "❌ Failed to create $cname"
        return 1
    }
    record_container "tun2socks" "$cname"
    if ! docker start "$cid" >/dev/null; then
        echo "⚠️ $cname stuck in CREATED"
    fi
    echo "$cname"
}

run_proxies() {
    if [[ ! -f proxy.txt ]]; then
        echo "❌ proxy.txt not found, cannot run in PROXY mode."
        exit 1
    fi

    mapfile -t proxies < <(
        grep -v '^[[:space:]]*$' proxy.txt | \
        grep -v '^[[:space:]]*#' | \
        sed 's/[[:space:]]//g'
    )

    local valid_proxies=()
    for line in "${proxies[@]}"; do
        if valid_proxy_line "$line"; then
            valid_proxies+=("$line")
        else
            echo "⚠️ Skipping invalid proxy line: $line"
        fi
    done

    local count=${#valid_proxies[@]}
    if (( count == 0 )); then
        echo "❌ No valid proxies found in proxy.txt"
        exit 1
    fi

    local tun_names=()
    local idx=1
    for proxy_url in "${valid_proxies[@]}"; do
        local tun_cname
        if (( count == 1 )); then
            tun_cname=$(run_tun2socks "$proxy_url" "")
        else
            tun_cname=$(run_tun2socks "$proxy_url" "$idx")
        fi
        tun_names+=("$tun_cname")
        ((idx++))
    done

    local idy=1
    for tun_cname in "${tun_names[@]}"; do
        local counter=""
        (( count > 1 )) && counter="$idy"
        [[ "${app_CastarSDK:-DISABLED}"      == "ENABLED" ]] && run_proxy_cmd_CastarSDK      "$tun_cname" "$counter"
        [[ "${app_PacketSDK:-DISABLED}"      == "ENABLED" ]] && run_proxy_cmd_PacketSDK      "$tun_cname" "$counter"
        [[ "${app_TraffMonetizer:-DISABLED}" == "ENABLED" ]] && run_proxy_cmd_TraffMonetizer "$tun_cname" "$counter"
        [[ "${app_UrNetwork:-DISABLED}"      == "ENABLED" ]] && run_proxy_cmd_UrNetwork      "$tun_cname" "$counter"
        [[ "${app_EarnFM:-DISABLED}"         == "ENABLED" ]] && run_proxy_cmd_EarnFM         "$tun_cname" "$counter"
        [[ "${app_RePocket:-DISABLED}"       == "ENABLED" ]] && run_proxy_cmd_RePocket       "$tun_cname" "$counter"
        [[ "${app_Pawns:-DISABLED}"          == "ENABLED" ]] && run_proxy_cmd_Pawns          "$tun_cname" "$counter"
        [[ "${app_HoneyGain:-DISABLED}"      == "ENABLED" ]] && run_proxy_cmd_HoneyGain      "$tun_cname" "$counter"
        [[ "${app_PacketStream:-DISABLED}"   == "ENABLED" ]] && run_proxy_cmd_PacketStream   "$tun_cname" "$counter"
        [[ "${app_Peer2Profit:-DISABLED}"    == "ENABLED" ]] && run_proxy_cmd_Peer2Profit    "$tun_cname" "$counter"
        [[ "${app_Wipter:-DISABLED}"         == "ENABLED" ]] && run_proxy_cmd_Wipter         "$tun_cname" "$counter"
        [[ "${app_Adnade_Surfbar:-DISABLED}" == "ENABLED" ]] && run_proxy_cmd_Adnade_Surfbar "$tun_cname" "$counter"
        [[ "${app_Adnade_PTP:-DISABLED}"     == "ENABLED" ]] && run_proxy_cmd_Adnade_PTP     "$tun_cname" "$counter"
        ((idy++))
    done
}

# -----------------------------
# PULL logic
# -----------------------------
pull_all() {
    echo "Pulling latest images for enabled apps..."
    [[ "${PROXY:-DISABLED}"                  == "ENABLED" ]] && docker pull xjasonlyu/tun2socks
    [[ "${app_CastarSDK:-DISABLED}"          == "ENABLED" ]] && docker pull techroy23/docker-castarsdk
    [[ "${app_PacketSDK:-DISABLED}"          == "ENABLED" ]] && docker pull techroy23/docker-packetsdk
    [[ "${app_TraffMonetizer:-DISABLED}"     == "ENABLED" ]] && docker pull techroy23/docker-traffmonetizer
    [[ "${app_UrNetwork:-DISABLED}"          == "ENABLED" ]] && docker pull techroy23/docker-urnetwork
    [[ "${app_EarnFM:-DISABLED}"             == "ENABLED" ]] && docker pull techroy23/docker-earnfm
    [[ "${app_RePocket:-DISABLED}"           == "ENABLED" ]] && docker pull repocket/repocket
    [[ "${app_Pawns:-DISABLED}"              == "ENABLED" ]] && docker pull techroy23/docker-pawns
    [[ "${app_HoneyGain:-DISABLED}"          == "ENABLED" ]] && docker pull honeygain/honeygain
    [[ "${app_PacketStream:-DISABLED}"       == "ENABLED" ]] && docker pull techroy23/docker-packetstream
    [[ "${app_Peer2Profit:-DISABLED}"        == "ENABLED" ]] && docker pull techroy23/docker-peer2profit
    [[ "${app_Wipter:-DISABLED}"             == "ENABLED" ]] && docker pull techroy23/docker-wipter
    [[ "${app_Adnade_Surfbar:-DISABLED}"     == "ENABLED" ]] && docker pull techroy23/docker-chrome-kiosk
    [[ "${app_Adnade_PTP:-DISABLED}"         == "ENABLED" ]] && docker pull techroy23/docker-chrome-kiosk
}

# -----------------------------
# Preflight Checks
# -----------------------------
validate_env_vars() {
    local missing=0

    check_var() {
        local varname="$1"
        if [[ -z "${!varname:-}" ]]; then
            echo "❌ Required variable $varname is not set in .env"
            missing=1
        fi
    }

    [[ "${app_CastarSDK:-DISABLED}"          == "ENABLED" ]] && { check_var "var_CastarSDK_AppKey"; }
    [[ "${app_PacketSDK:-DISABLED}"          == "ENABLED" ]] && { check_var "var_PacketSDK_AppKey"; }
    [[ "${app_TraffMonetizer:-DISABLED}"     == "ENABLED" ]] && { check_var "var_TraffMonetizer_Token"; }
    [[ "${app_UrNetwork:-DISABLED}"          == "ENABLED" ]] && { check_var "var_UrNetwork_Email";      check_var "var_UrNetwork_Password"; }
    [[ "${app_EarnFM:-DISABLED}"             == "ENABLED" ]] && { check_var "var_EarnFM_Token"; }
    [[ "${app_RePocket:-DISABLED}"           == "ENABLED" ]] && { check_var "var_RePocket_Email";       check_var "var_RePocket_API_Key"; }
    [[ "${app_Pawns:-DISABLED}"              == "ENABLED" ]] && { check_var "var_Pawns_Email";          check_var "var_Pawns_Password"; }
    [[ "${app_HoneyGain:-DISABLED}"          == "ENABLED" ]] && { check_var "var_HoneyGain_Email";      check_var "var_HoneyGain_Password"; }
    [[ "${app_PacketStream:-DISABLED}"       == "ENABLED" ]] && { check_var "var_PacketStream_Token"; }
    [[ "${app_Peer2Profit:-DISABLED}"        == "ENABLED" ]] && { check_var "var_Peer2Profit_Email"; }
    [[ "${app_Wipter:-DISABLED}"             == "ENABLED" ]] && { check_var "var_Wipter_Email";         check_var "var_Wipter_Password"; }
    [[ "${app_Adnade_Surfbar:-DISABLED}"     == "ENABLED" ]] && { check_var "var_Adnade_Surfbar_URL"; }
    [[ "${app_Adnade_PTP:-DISABLED}"         == "ENABLED" ]] && { check_var "var_Adnade_PTP_URL"; }

    if (( missing )); then
        echo "⚠️ One or more required variables are missing. Fix .env and retry."
        exit 1
    fi
}

# -----------------------------
# STOP logic
# -----------------------------
stop_all() {
    echo "Stopping and removing all containers..."
    rm -f "$FAILED_FILE"

    if [[ ! -f "$STATE_FILE" ]]; then
        echo "No containers recorded."
        return 0
    fi

    local tmp_state=".containers/state.tmp"
    : > "$tmp_state"

    while IFS=: read -r app cname; do
        [[ -z "$cname" ]] && continue

        if docker ps -a --format '{{.Names}}' | grep -q "^$cname$"; then
            if docker rm -f "$cname" >/dev/null 2>&1; then
                echo "Removed $app ($cname)"
            else
                echo "❌ Failed to remove $app ($cname)"
                echo "$app:$cname" >> "$FAILED_FILE"
                echo "$app:$cname" >> "$tmp_state"
                echo "⚠️ Suggestion: run 'docker ps -a' to inspect, or try 'docker rm -f $cname' manually."
            fi
        else
            echo "$app ($cname) not found in Docker, assuming already deleted."
        fi
    done < "$STATE_FILE"

    mv "$tmp_state" "$STATE_FILE"
    if [[ ! -s "$STATE_FILE" ]]; then
        echo "✅ All containers removed successfully."
        rm -f "$STATE_FILE"
    else
        echo "⚠️ Some containers could not be removed. See $FAILED_FILE and $STATE_FILE."
    fi

    orphans=$(docker ps -a --filter "status=created" --format '{{.Names}}' | \
              grep -E '^(CastarSDK|PacketSDK|TraffMonetizer|UrNetwork|EarnFM|RePocket|Pawns|HoneyGain|PacketStream|Peer2Profit|Wipter|tun2socks)_')
    for cname in $orphans; do
        echo "🧹 Cleaning orphaned container $cname"
        docker rm -f "$cname" >/dev/null 2>&1 || true
    done
}

# -----------------------------
# CLEAN logic (post-crash recovery)
# -----------------------------
clean_all() {
    echo "🧹 Forcing cleanup of all bandwidthBucks containers..."
    local patterns='^(CastarSDK|PacketSDK|TraffMonetizer|UrNetwork|EarnFM|RePocket|Pawns|HoneyGain|PacketStream|Peer2Profit|Wipter|tun2socks)_[0-9]{5}(_[0-9]{5})?$'
    local found
    found=$(docker ps -a --format '{{.Names}}' | grep -E "$patterns" || true)

    if [[ -n "$found" ]]; then
        echo "Removing the following containers:"
        echo "$found" | sed 's/^/  - /'
        echo "$found" | xargs -r docker rm -f >/dev/null 2>&1
        echo "✅ Cleanup complete. Removed $(echo "$found" | wc -l) containers."
    else
        echo "No matching containers found."
    fi

    rm -f "$STATE_FILE" "$FAILED_FILE"
    echo "✅ Cleanup complete. State reset."
}


# -----------------------------
# App runners (direct mode)
# -----------------------------
run_cmd_CastarSDK() {
    local cname="CastarSDK_${RUN_SUFFIX}"
    echo "Deploying CastarSDK as $cname..."
    cid=$(docker create --name="$cname" $(extra_flags) $(dns_flags) $(log_driver_flag) \
        -e APPKEY="$var_CastarSDK_AppKey" \
        techroy23/docker-castarsdk) || { echo "❌ Failed to create $cname"; return 1; }
    record_container "CastarSDK" "$cname"
    docker start "$cid" >/dev/null || echo "⚠️ $cname stuck in CREATED"
}

run_cmd_PacketSDK() {
    local cname="PacketSDK_${RUN_SUFFIX}"
    echo "Deploying PacketSDK as $cname..."
    cid=$(docker create --name="$cname" $(extra_flags) $(dns_flags) $(log_driver_flag) \
        -e APPKEY="$var_PacketSDK_AppKey" \
        techroy23/docker-packetsdk) || { echo "❌ Failed to create $cname"; return 1; }
    record_container "PacketSDK" "$cname"
    docker start "$cid" >/dev/null || echo "⚠️ $cname stuck in CREATED"
}

run_cmd_TraffMonetizer() {
    local cname="TraffMonetizer_${RUN_SUFFIX}"
    echo "Deploying TraffMonetizer as $cname..."
    cid=$(docker create --name="$cname" $(extra_flags) $(dns_flags) $(log_driver_flag) \
        -e TOKEN="$var_TraffMonetizer_Token" \
        -e DEVNAME="$cname" \
        techroy23/docker-traffmonetizer) || { echo "❌ Failed to create $cname"; return 1; }
    record_container "TraffMonetizer" "$cname"
    docker start "$cid" >/dev/null || echo "⚠️ $cname stuck in CREATED"
}

run_cmd_UrNetwork() {
    local cname="UrNetwork_${RUN_SUFFIX}"
    echo "Deploying UrNetwork as $cname..."
    cid=$(docker create --name="$cname" $(extra_flags) $(dns_flags) $(log_driver_flag) \
        -e USER_AUTH="$var_UrNetwork_Email" \
        -e PASSWORD="$var_UrNetwork_Password" \
        techroy23/docker-urnetwork) || { echo "❌ Failed to create $cname"; return 1; }
    record_container "UrNetwork" "$cname"
    docker start "$cid" >/dev/null || echo "⚠️ $cname stuck in CREATED"
}

run_cmd_EarnFM() {
    local cname="EarnFM_${RUN_SUFFIX}"
    echo "Deploying EarnFM as $cname..."
    cid=$(docker create --name="$cname" $(extra_flags) $(dns_flags) $(log_driver_flag) \
        -e TOKEN="$var_EarnFM_Token" \
        techroy23/docker-earnfm) || { echo "❌ Failed to create $cname"; return 1; }
    record_container "EarnFM" "$cname"
    docker start "$cid" >/dev/null || echo "⚠️ $cname stuck in CREATED"
}

run_cmd_RePocket() {
    local cname="RePocket_${RUN_SUFFIX}"
    echo "Deploying RePocket as $cname..."
    cid=$(docker create --name="$cname" $(extra_flags) $(dns_flags) $(log_driver_flag) \
        -e RP_EMAIL="$var_RePocket_Email" \
        -e RP_API_KEY="$var_RePocket_API_Key" \
        repocket/repocket) || { echo "❌ Failed to create $cname"; return 1; }
    record_container "RePocket" "$cname"
    docker start "$cid" >/dev/null || echo "⚠️ $cname stuck in CREATED"
}

run_cmd_Pawns() {
    local cname="Pawns_${RUN_SUFFIX}"
    echo "Deploying Pawns as $cname..."
    cid=$(docker create --name="$cname" $(extra_flags) $(dns_flags) $(log_driver_flag) \
        -e EMAIL="$var_Pawns_Email" \
        -e PASSWORD="$var_Pawns_Password" \
        techroy23/docker-pawns) || { echo "❌ Failed to create $cname"; return 1; }
    record_container "Pawns" "$cname"
    docker start "$cid" >/dev/null || echo "⚠️ $cname stuck in CREATED"
}

run_cmd_HoneyGain() {
    local cname="HoneyGain_${RUN_SUFFIX}"
    echo "Deploying HoneyGain as $cname..."
    cid=$(docker create --name="$cname" $(extra_flags) $(dns_flags) $(log_driver_flag) \
        honeygain/honeygain \
        -tou-accept \
        -email "$var_HoneyGain_Email" \
        -pass "$var_HoneyGain_Password" \
        -device "$cname") || { echo "❌ Failed to create $cname"; return 1; }
    record_container "HoneyGain" "$cname"
    docker start "$cid" >/dev/null || echo "⚠️ $cname stuck in CREATED"
}

run_cmd_PacketStream() {
    local cname="PacketStream_${RUN_SUFFIX}"
    echo "Deploying PacketStream as $cname..."
    cid=$(docker create --name="$cname" $(extra_flags) $(dns_flags) $(log_driver_flag) \
        -e TOKEN="$var_PacketStream_Token" \
        techroy23/docker-packetstream) || { echo "❌ Failed to create $cname"; return 1; }
    record_container "PacketStream" "$cname"
    docker start "$cid" >/dev/null || echo "⚠️ $cname stuck in CREATED"
}

run_cmd_Peer2Profit() {
    local cname="Peer2Profit_${RUN_SUFFIX}"
    echo "Deploying Peer2Profit as $cname..."
    cid=$(docker create --name="$cname" $(extra_flags) $(dns_flags) $(log_driver_flag) \
        -e P2P_EMAIL="$var_Peer2Profit_Email" \
        techroy23/docker-peer2profit) || { echo "❌ Failed to create $cname"; return 1; }
    record_container "Peer2Profit" "$cname"
    docker start "$cid" >/dev/null || echo "⚠️ $cname stuck in CREATED"
}

run_cmd_Wipter() {
    local cname="Wipter_${RUN_SUFFIX}"
    echo "Deploying Wipter as $cname..."
    cid=$(docker create --name="$cname" $(extra_flags) $(dns_flags) $(log_driver_flag) \
        -e WIPTER_EMAIL="$var_Wipter_Email" \
        -e WIPTER_PASSWORD="$var_Wipter_Password" \
        techroy23/docker-wipter) || { echo "❌ Failed to create $cname"; return 1; }
    record_container "Wipter" "$cname"
    docker start "$cid" >/dev/null || echo "⚠️ $cname stuck in CREATED"
}

run_cmd_Adnade_Surfbar() {
    local cname="Adnade_Surfbar_${RUN_SUFFIX}"
    echo "Deploying Adnade_Surfbar as $cname..."
    cid=$(docker create --name="$cname" $(extra_flags) $(dns_flags) $(log_driver_flag) \
        -e WEBSITE="$var_Adnade_Surfbar_URL" \
        -e DISCORDWEBHOOKURL="$var_Adnade_Surfbar_DISCORDWEBHOOKURL" \
        techroy23/docker-chrome-kiosk) || { echo "❌ Failed to create $cname"; return 1; }
    record_container "Adnade_Surfbar" "$cname"
    docker start "$cid" >/dev/null || echo "⚠️ $cname stuck in CREATED"
}

run_cmd_Adnade_PTP() {
    local cname="Adnade_PTP_${RUN_SUFFIX}"
    echo "Deploying Adnade_PTP as $cname..."
    cid=$(docker create --name="$cname" $(extra_flags) $(dns_flags) $(log_driver_flag) \
        -e WEBSITE="$var_Adnade_PTP_URL" \
        -e DISCORDWEBHOOKURL="$var_Adnade_Surfbar_DISCORDWEBHOOKURL" \
        techroy23/docker-chrome-kiosk) || { echo "❌ Failed to create $cname"; return 1; }
    record_container "Adnade_PTP" "$cname"
    docker start "$cid" >/dev/null || echo "⚠️ $cname stuck in CREATED"
}

# -----------------------------
# App runners (proxy mode)
# -----------------------------
run_proxy_cmd_CastarSDK() {
    local tun_cname="$1"; local index="$2"
    local cname=${index:+$(printf "CastarSDK_%s_%05d" "$RUN_SUFFIX" "$index")}
    cname=${cname:-"CastarSDK_${RUN_SUFFIX}"}
    echo "Deploying CastarSDK as $cname (via $tun_cname)..."
    cid=$(docker create --name="$cname" $(extra_flags) $(log_driver_flag) --network=container:"$tun_cname" \
        -e APPKEY="$var_CastarSDK_AppKey" \
        techroy23/docker-castarsdk:latest) || { echo "❌ Failed to create $cname"; return 1; }
    record_container "CastarSDK" "$cname"
    docker start "$cid" >/dev/null || echo "⚠️ $cname stuck in CREATED"
}

run_proxy_cmd_PacketSDK() {
    local tun_cname="$1"; local index="$2"
    local cname=${index:+$(printf "PacketSDK_%s_%05d" "$RUN_SUFFIX" "$index")}
    cname=${cname:-"PacketSDK_${RUN_SUFFIX}"}
    echo "Deploying PacketSDK as $cname (via $tun_cname)..."
    cid=$(docker create --name="$cname" $(extra_flags) $(log_driver_flag) --network=container:"$tun_cname" \
        -e APPKEY="$var_PacketSDK_AppKey" \
        techroy23/docker-packetsdk:latest) || { echo "❌ Failed to create $cname"; return 1; }
    record_container "PacketSDK" "$cname"
    docker start "$cid" >/dev/null || echo "⚠️ $cname stuck in CREATED"
}

run_proxy_cmd_TraffMonetizer() {
    local tun_cname="$1"; local index="$2"
    local cname=${index:+$(printf "TraffMonetizer_%s_%05d" "$RUN_SUFFIX" "$index")}
    cname=${cname:-"TraffMonetizer_${RUN_SUFFIX}"}
    echo "Deploying TraffMonetizer as $cname (via $tun_cname)..."
    cid=$(docker create --name="$cname" $(extra_flags) $(log_driver_flag) --network=container:"$tun_cname" \
        -e TOKEN="$var_TraffMonetizer_Token" \
        -e DEVNAME="$cname" \
        techroy23/docker-traffmonetizer) || { echo "❌ Failed to create $cname"; return 1; }
    record_container "TraffMonetizer" "$cname"
    docker start "$cid" >/dev/null || echo "⚠️ $cname stuck in CREATED"
}

run_proxy_cmd_UrNetwork() {
    local tun_cname="$1"; local index="$2"
    local cname=${index:+$(printf "UrNetwork_%s_%05d" "$RUN_SUFFIX" "$index")}
    cname=${cname:-"UrNetwork_${RUN_SUFFIX}"}
    echo "Deploying UrNetwork as $cname (via $tun_cname)..."
    cid=$(docker create --name="$cname" $(extra_flags) $(log_driver_flag) --network=container:"$tun_cname" \
        -e USER_AUTH="$var_UrNetwork_Email" \
        -e PASSWORD="$var_UrNetwork_Password" \
        techroy23/docker-urnetwork) || { echo "❌ Failed to create $cname"; return 1; }
    record_container "UrNetwork" "$cname"
    docker start "$cid" >/dev/null || echo "⚠️ $cname stuck in CREATED"
}

run_proxy_cmd_EarnFM() {
    local tun_cname="$1"; local index="$2"
    local cname=${index:+$(printf "EarnFM_%s_%05d" "$RUN_SUFFIX" "$index")}
    cname=${cname:-"EarnFM_${RUN_SUFFIX}"}
    echo "Deploying EarnFM as $cname (via $tun_cname)..."
    cid=$(docker create --name="$cname" $(extra_flags) $(log_driver_flag) --network=container:"$tun_cname" \
        -e TOKEN="$var_EarnFM_Token" \
        techroy23/docker-earnfm) || { echo "❌ Failed to create $cname"; return 1; }
    record_container "EarnFM" "$cname"
    docker start "$cid" >/dev/null || echo "⚠️ $cname stuck in CREATED"
}

run_proxy_cmd_RePocket() {
    local tun_cname="$1"; local index="$2"
    local cname=${index:+$(printf "RePocket_%s_%05d" "$RUN_SUFFIX" "$index")}
    cname=${cname:-"RePocket_${RUN_SUFFIX}"}
    echo "Deploying RePocket as $cname (via $tun_cname)..."
    cid=$(docker create --name="$cname" $(extra_flags) $(log_driver_flag) --network=container:"$tun_cname" \
        -e RP_EMAIL="$var_RePocket_Email" \
        -e RP_API_KEY="$var_RePocket_API_Key" \
        repocket/repocket) || { echo "❌ Failed to create $cname"; return 1; }
    record_container "RePocket" "$cname"
    docker start "$cid" >/dev/null || echo "⚠️ $cname stuck in CREATED"
}

run_proxy_cmd_Pawns() {
    local tun_cname="$1"; local index="$2"
    local cname=${index:+$(printf "Pawns_%s_%05d" "$RUN_SUFFIX" "$index")}
    cname=${cname:-"Pawns_${RUN_SUFFIX}"}
    echo "Deploying Pawns as $cname (via $tun_cname)..."
    cid=$(docker create --name="$cname" $(extra_flags) $(log_driver_flag) --network=container:"$tun_cname" \
        -e EMAIL="$var_Pawns_Email" \
        -e PASSWORD="$var_Pawns_Password" \
        techroy23/docker-pawns) || { echo "❌ Failed to create $cname"; return 1; }
    record_container "Pawns" "$cname"
    docker start "$cid" >/dev/null || echo "⚠️ $cname stuck in CREATED"
}

run_proxy_cmd_HoneyGain() {
    local tun_cname="$1"; local index="$2"
    local cname=${index:+$(printf "HoneyGain_%s_%05d" "$RUN_SUFFIX" "$index")}
    cname=${cname:-"HoneyGain_${RUN_SUFFIX}"}
    echo "Deploying HoneyGain as $cname (via $tun_cname)..."
    cid=$(docker create --name="$cname" $(extra_flags) $(log_driver_flag) --network=container:"$tun_cname" \
        honeygain/honeygain \
        -tou-accept \
        -email "$var_HoneyGain_Email" \
        -pass "$var_HoneyGain_Password" \
        -device "$cname") || { echo "❌ Failed to create $cname"; return 1; }
    record_container "HoneyGain" "$cname"
    docker start "$cid" >/dev/null || echo "⚠️ $cname stuck in CREATED"
}

run_proxy_cmd_PacketStream() {
    local tun_cname="$1"; local index="$2"
    local cname=${index:+$(printf "PacketStream_%s_%05d" "$RUN_SUFFIX" "$index")}
    cname=${cname:-"PacketStream_${RUN_SUFFIX}"}
    echo "Deploying PacketStream as $cname (via $tun_cname)..."
    cid=$(docker create --name="$cname" $(extra_flags) $(log_driver_flag) --network=container:"$tun_cname" \
        -e TOKEN="$var_PacketStream_Token" \
        techroy23/docker-packetstream) || { echo "❌ Failed to create $cname"; return 1; }
    record_container "PacketStream" "$cname"
    docker start "$cid" >/dev/null || echo "⚠️ $cname stuck in CREATED"
}

run_proxy_cmd_Peer2Profit() {
    local tun_cname="$1"; local index="$2"
    local cname=${index:+$(printf "Peer2Profit_%s_%05d" "$RUN_SUFFIX" "$index")}
    cname=${cname:-"Peer2Profit_${RUN_SUFFIX}"}
    echo "Deploying Peer2Profit as $cname (via $tun_cname)..."
    cid=$(docker create --name="$cname" $(extra_flags) $(log_driver_flag) --network=container:"$tun_cname" \
        -e P2P_EMAIL="$var_Peer2Profit_Email" \
        techroy23/docker-peer2profit) || { echo "❌ Failed to create $cname"; return 1; }
    record_container "Peer2Profit" "$cname"
    docker start "$cid" >/dev/null || echo "⚠️ $cname stuck in CREATED"
}

run_proxy_cmd_Wipter() {
    local tun_cname="$1"; local index="$2"
    local cname=${index:+$(printf "Wipter_%s_%05d" "$RUN_SUFFIX" "$index")}
    cname=${cname:-"Wipter_${RUN_SUFFIX}"}
    echo "Deploying Wipter as $cname (via $tun_cname)..."
    cid=$(docker create --name="$cname" $(extra_flags) $(log_driver_flag) --network=container:"$tun_cname" \
        -e WIPTER_EMAIL="$var_Wipter_Email" \
        -e WIPTER_PASSWORD="$var_Wipter_Password" \
        techroy23/docker-wipter) || { echo "❌ Failed to create $cname"; return 1; }
    record_container "Wipter" "$cname"
    docker start "$cid" >/dev/null || echo "⚠️ $cname stuck in CREATED"
}

run_proxy_cmd_Adnade_Surfbar() {
    local tun_cname="$1"; local index="$2"
    local cname=${index:+$(printf "Adnade_Surfbar_%s_%05d" "$RUN_SUFFIX" "$index")}
    cname=${cname:-"Adnade_Surfbar_${RUN_SUFFIX}"}
    echo "Deploying Adnade_Surfbar as $cname (via $tun_cname)..."
    cid=$(docker create --name="$cname" $(extra_flags) $(log_driver_flag) --network=container:"$tun_cname" \
        -e WEBSITE="$var_Adnade_Surfbar_URL" \
        -e DISCORDWEBHOOKURL="$var_Adnade_Surfbar_DISCORDWEBHOOKURL" \
        techroy23/docker-chrome-kiosk) || { echo "❌ Failed to create $cname"; return 1; }
    record_container "Adnade_Surfbar" "$cname"
    docker start "$cid" >/dev/null || echo "⚠️ $cname stuck in CREATED"
}

run_proxy_cmd_Adnade_PTP() {
    local tun_cname="$1"; local index="$2"
    local cname=${index:+$(printf "Adnade_PTP_%s_%05d" "$RUN_SUFFIX" "$index")}
    cname=${cname:-"Adnade_PTP_${RUN_SUFFIX}"}
    echo "Deploying Adnade_PTP as $cname (via $tun_cname)..."
    cid=$(docker create --name="$cname" $(extra_flags) $(log_driver_flag) --network=container:"$tun_cname" \
        -e WEBSITE="$var_Adnade_PTP_URL" \
        -e DISCORDWEBHOOKURL="$var_Adnade_Surfbar_DISCORDWEBHOOKURL" \
        techroy23/docker-chrome-kiosk) || { echo "❌ Failed to create $cname"; return 1; }
    record_container "Adnade_PTP" "$cname"
    docker start "$cid" >/dev/null || echo "⚠️ $cname stuck in CREATED"
}

# -----------------------------
# Main
# -----------------------------
case "${1:-}" in
    START)
        if [[ -f "$STATE_FILE" && -s "$STATE_FILE" ]]; then
            echo "❌ Containers already exist in $STATE_FILE."
            echo "⚠️ Run STOP first to clean them up."
            exit 1
        fi

        orphans=$(docker ps -a --format '{{.Names}}' | \
                  grep -E '^(CastarSDK|PacketSDK|TraffMonetizer|UrNetwork|EarnFM|RePocket|Pawns|HoneyGain|PacketStream|Peer2Profit|Wipter|tun2socks)_[0-9]{5}(_[0-9]{5})?$' || true)

        if [[ -n "$orphans" ]]; then
            echo "❌ START aborted: Found leftover containers from a previous run:"
            echo "$orphans" | sed 's/^/   - /'
            echo
            echo "⚠️ Please run:  ./bandwidthBucks.sh CLEAN"
            echo "   (This will force-remove leftovers and reset state.)"
            echo
            exit 1
        fi

        validate_env_vars

        RUN_SUFFIX=$(generate_unique_suffix)

        apply_sysctl_settings

        if [[ "${PROXY:-DISABLED}" == "ENABLED" ]]; then
            run_proxies
        else
            [[ "${app_CastarSDK:-DISABLED}"      == "ENABLED" ]] && run_cmd_CastarSDK
            [[ "${app_PacketSDK:-DISABLED}"      == "ENABLED" ]] && run_cmd_PacketSDK
            [[ "${app_TraffMonetizer:-DISABLED}" == "ENABLED" ]] && run_cmd_TraffMonetizer
            [[ "${app_UrNetwork:-DISABLED}"      == "ENABLED" ]] && run_cmd_UrNetwork
            [[ "${app_EarnFM:-DISABLED}"         == "ENABLED" ]] && run_cmd_EarnFM
            [[ "${app_RePocket:-DISABLED}"       == "ENABLED" ]] && run_cmd_RePocket
            [[ "${app_Pawns:-DISABLED}"          == "ENABLED" ]] && run_cmd_Pawns
            [[ "${app_HoneyGain:-DISABLED}"      == "ENABLED" ]] && run_cmd_HoneyGain
            [[ "${app_PacketStream:-DISABLED}"   == "ENABLED" ]] && run_cmd_PacketStream
            [[ "${app_Peer2Profit:-DISABLED}"    == "ENABLED" ]] && run_cmd_Peer2Profit
            [[ "${app_Wipter:-DISABLED}"         == "ENABLED" ]] && run_cmd_Wipter
            [[ "${app_Adnade_Surfbar:-DISABLED}" == "ENABLED" ]] && run_cmd_Adnade_Surfbar
            [[ "${app_Adnade_PTP:-DISABLED}"     == "ENABLED" ]] && run_cmd_Adnade_PTP
        fi
        ;;
    STOP)
        stop_all
        ;;
    PULL)
        pull_all
        ;;
    CLEAN)
        clean_all
        ;;
    *)
        print_usage
        exit 1
        ;;
esac
