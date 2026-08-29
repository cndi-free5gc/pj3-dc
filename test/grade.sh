#!/bin/bash

########################################################
# Automated grading script
#
# Usage:
#   ./grade.sh
#
# Description:
#   Runs each grading item in turn and prints a final score
#   table. New grading items should be added as their own
#   `grade_xxx` function, calling `add_result` once, and then
#   invoked from main().
########################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

COMPOSE_FILE="${ROOT_DIR}/docker-compose-dc.yaml"
MASTER_GNB_CONFIG="${ROOT_DIR}/config/gnbcfg-dc-master.yaml"
SECONDARY_GNB_CONFIG="${ROOT_DIR}/config/gnbcfg-dc-secondary.yaml"
UE_CONFIG="${ROOT_DIR}/config/uecfg-dc.yaml"

# set_dc_enabled <true|false> -- toggles gnb-master's staticNrdc and the ue's
# nrdc.enable in place with `sed` (rather than `yq -i`, which would rewrite
# the whole file and strip its blank lines / inline comments).
set_dc_enabled() {
    local value="$1"
    sed -i "s/^  staticNrdc: .*/  staticNrdc: ${value}/" "$MASTER_GNB_CONFIG"
    sed -i "s/^    enable: .*/    enable: ${value}/" "$UE_CONFIG"

    if ! grep -q "^  staticNrdc: ${value}$" "$MASTER_GNB_CONFIG"; then
        echo "WARNING: failed to set staticNrdc=${value} in ${MASTER_GNB_CONFIG}"
    fi
    if ! grep -q "^    enable: ${value}$" "$UE_CONFIG"; then
        echo "WARNING: failed to set nrdc.enable=${value} in ${UE_CONFIG}"
    fi
}

FREE5GC_CONSOLE_BASE_URL='http://127.0.0.1:5000'
FREE5GC_CONSOLE_LOGIN_DATA_FILE="${SCRIPT_DIR}/free5gc-console-login-data.json"
FREE5GC_CONSOLE_SUBSCRIBER_DATA_FILE="${SCRIPT_DIR}/free5gc-console-subscriber-data.json"

# check_required_tools -- fails fast with a clear message instead of letting a
# missing tool surface later as a confusing mid-test error.
check_required_tools() {
    local tool missing=()
    for tool in docker curl jq yq python3; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Missing required tool(s): ${missing[*]}"
        exit 1
    fi
}

free5gc_console_login() {
    local token
    token=$(curl -s -X POST "${FREE5GC_CONSOLE_BASE_URL}/api/login" -H "Content-Type: application/json" -d @"$FREE5GC_CONSOLE_LOGIN_DATA_FILE" | jq -r '.access_token')
    if [ -z "$token" ] || [ "$token" = "null" ]; then
        return 1
    fi
    echo "$token"
}

# free5gc_console_subscriber_action <post|delete>
free5gc_console_subscriber_action() {
    local token
    token=$(free5gc_console_login) || return 1

    local imsi plmn_id
    imsi=$(jq -r '.ueId' "$FREE5GC_CONSOLE_SUBSCRIBER_DATA_FILE" | sed 's/imsi-//')
    plmn_id=$(jq -r '.plmnID' "$FREE5GC_CONSOLE_SUBSCRIBER_DATA_FILE")

    case "$1" in
        "post")
            curl -s --fail -X POST "${FREE5GC_CONSOLE_BASE_URL}/api/subscriber/imsi-${imsi}/${plmn_id}" \
                -H "Content-Type: application/json" -H "Token: $token" -d @"$FREE5GC_CONSOLE_SUBSCRIBER_DATA_FILE" >/dev/null
            ;;
        "delete")
            curl -s --fail -X DELETE "${FREE5GC_CONSOLE_BASE_URL}/api/subscriber/imsi-${imsi}/${plmn_id}" \
                -H "Content-Type: application/json" -H "Token: $token" -d @"$FREE5GC_CONSOLE_SUBSCRIBER_DATA_FILE" >/dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

declare -a RESULT_NAMES
declare -a RESULT_POINTS
declare -a RESULT_MAX_POINTS
declare -a RESULT_STATUS

# add_result <name> <points> <max_points> <status: PASS|FAIL|SKIP>
add_result() {
    RESULT_NAMES+=("$1")
    RESULT_POINTS+=("$2")
    RESULT_MAX_POINTS+=("$3")
    RESULT_STATUS+=("$4")
}

########################################################
# Grading item: Code (make build / make test / make lint)
#
# Worth 0 points on its own: it is a gate. If the code does not
# build, is not covered by passing tests, fails lint, or the
# image can't even be built, none of the later (functional)
# grading items -- which all run against `make image`'s output --
# can produce a meaningful score, so they are skipped.
########################################################
grade_code() {
    echo "===================================================="
    echo "[Code] make build / make test / make lint / make image"
    echo "===================================================="

    local failed_step=""

    echo "--- make build ---"
    if ! (cd "$ROOT_DIR" && make build); then
        failed_step="build"
    fi

    if [ -z "$failed_step" ]; then
        echo "--- make test ---"
        if ! (cd "$ROOT_DIR" && make test); then
            failed_step="test"
        fi
    fi

    if [ -z "$failed_step" ]; then
        echo "--- make lint ---"
        if ! (cd "$ROOT_DIR" && make lint); then
            failed_step="lint"
        fi
    fi

    if [ -z "$failed_step" ]; then
        echo "--- make image ---"
        if ! (cd "$ROOT_DIR" && make image); then
            failed_step="image"
        fi
    fi

    if [ -z "$failed_step" ]; then
        add_result "Code (build/test/lint/image)" 0 0 "✅ PASS"
        CODE_GATE_PASSED=true
    else
        add_result "Code (build/test/lint/image)" 0 0 "❌ FAIL (make ${failed_step})"
        CODE_GATE_PASSED=false
    fi
}

########################################################
# Grading item: both PDU sessions anchored on the master RAN
#
# This is the plain (non-DC) case: pdu session 1 and pdu session 2
# should both be served entirely by gnb-master, and UPF's GTP-U
# traffic for both should only ever reference gnb-master's N3 IP,
# never the second gNB's.
#
# Worth 60 points.
########################################################
grade_pdu_sessions_on_master() {
    echo "===================================================="
    echo "[Functional] Both PDU sessions on master RAN"
    echo "===================================================="

    local item="PDU sessions on master RAN"
    local max_points=60
    local ok=true
    local reason=""
    local subscriber_created=false

    # both mount to ./pcap on the host, so these land in the repo's pcap/ dir
    local upf_pcap="/free5gc/pcap/upf.pcap"
    local ue_pcap="/free-ran-ue/pcap/ue.pcap"

    local master_ip secondary_ip
    master_ip=$(yq -r '.gnb.ranN3Ip' "$MASTER_GNB_CONFIG")
    secondary_ip=$(yq -r '.gnb.ranN3Ip' "$SECONDARY_GNB_CONFIG")

    # do not trust the config's checked-in baseline to still be false: a
    # previous run that crashed/was killed mid-DC-test (before it reached
    # its own set_dc_enabled false reset) leaves staticNrdc/nrdc.enable
    # stuck at true, which would silently invalidate this "master-only"
    # test. Force it explicitly every time instead of assuming.
    echo "--- set staticNrdc / nrdc.enable to false ---"
    set_dc_enabled false

    # best-effort: tear down any stack left over from a previous run that
    # crashed / got killed before its own `down` ran, so this run starts
    # from a known-clean state instead of colliding with stale containers.
    docker compose -f "$COMPOSE_FILE" down --remove-orphans >/dev/null 2>&1

    echo "--- docker compose up ---"
    if ! docker compose -f "$COMPOSE_FILE" up -d --wait --wait-timeout 180; then
        add_result "$item" 0 "$max_points" "❌ FAIL (compose up)"
        MASTER_PDU_PASSED=false
        return
    fi
    sleep 10

    echo "--- install tcpdump in upf / ue ---"
    if $ok && ! docker exec upf bash -c "apt-get update -qq && apt-get install -y -qq tcpdump procps"; then
        ok=false; reason="tcpdump install (upf) failed"
    fi
    if $ok && ! docker exec ue bash -c "apt-get update -qq && apt-get install -y -qq tcpdump procps"; then
        ok=false; reason="tcpdump install (ue) failed"
    fi

    echo "--- create subscriber ---"
    if $ok; then
        # best-effort: clear any stale subscriber left over from a previous
        # run that didn't get to clean up (mongodb data persists across
        # `docker compose down`), so "post" below is idempotent.
        free5gc_console_subscriber_action "delete" >/dev/null 2>&1

        if free5gc_console_subscriber_action "post"; then
            subscriber_created=true
        else
            ok=false; reason="subscriber post failed"
        fi
    fi

    echo "--- start ue ---"
    if $ok; then
        docker exec -d ue ./free-ran-ue ue -c uecfg.yaml
        sleep 8
        if ! docker exec ue ip addr show ueTun0 >/dev/null 2>&1 || ! docker exec ue ip addr show ueTun1 >/dev/null 2>&1; then
            ok=false; reason="ueTun0/ueTun1 did not come up"
        fi
    fi

    local ue_ip0 ue_ip1
    if $ok; then
        ue_ip0=$(docker exec ue sh -c "ip -4 -o addr show ueTun0 | awk '{print \$4}' | cut -d/ -f1")
        ue_ip1=$(docker exec ue sh -c "ip -4 -o addr show ueTun1 | awk '{print \$4}' | cut -d/ -f1")
        if [ -z "$ue_ip0" ] || [ -z "$ue_ip1" ]; then
            ok=false; reason="could not read ueTun0/ueTun1 addresses"
        fi
    fi

    echo "--- start captures ---"
    if $ok; then
        docker exec upf rm -f "$upf_pcap"
        docker exec ue rm -f "$ue_pcap"
        docker exec -d upf tcpdump -i any -w "$upf_pcap"
        docker exec -d ue tcpdump -i any -w "$ue_pcap"
        sleep 1
    fi

    echo "--- ping ueTun0 / ueTun1 ---"
    local ping0_ok=false ping1_ok=false
    if $ok; then
        docker exec ue ping -I ueTun0 1.1.1.1 -c 3 -W 3 && ping0_ok=true
        docker exec ue ping -I ueTun1 1.1.1.1 -c 3 -W 3 && ping1_ok=true
        if ! $ping0_ok || ! $ping1_ok; then
            ok=false; reason="ping failed (ueTun0=${ping0_ok}, ueTun1=${ping1_ok})"
        fi
    fi

    sleep 1
    docker exec upf pkill -INT tcpdump 2>/dev/null
    docker exec ue pkill -INT tcpdump 2>/dev/null
    sleep 1

    echo "--- verify upf.pcap / ue.pcap ---"
    if $ok; then
        # both icmp flows must have completed end to end through upf
        for ue_ip in "$ue_ip0" "$ue_ip1"; do
            if ! docker exec upf tcpdump -r "$upf_pcap" -nn icmp 2>/dev/null | grep -q "IP ${ue_ip} > 1\.1\.1\.1: ICMP echo request"; then
                ok=false; reason="upf.pcap missing echo request from ${ue_ip}"; break
            fi
            if ! docker exec upf tcpdump -r "$upf_pcap" -nn icmp 2>/dev/null | grep -q "IP 1\.1\.1\.1 > ${ue_ip}: ICMP echo reply"; then
                ok=false; reason="upf.pcap missing echo reply to ${ue_ip}"; break
            fi
        done
    fi

    if $ok; then
        # both sessions' GTP-U traffic must be to/from the master RAN only
        local gtp_lines
        gtp_lines=$(docker exec upf tcpdump -r "$upf_pcap" -nn "udp port 2152" 2>/dev/null)
        if ! echo "$gtp_lines" | grep -q "$master_ip"; then
            ok=false; reason="no GTP-U traffic to/from master RAN (${master_ip}) in upf.pcap"
        elif echo "$gtp_lines" | grep -q "$secondary_ip"; then
            ok=false; reason="GTP-U traffic involving second RAN (${secondary_ip}) found in upf.pcap"
        fi
    fi

    if $ok; then
        # ue side should also show both replies actually arriving
        for ue_ip in "$ue_ip0" "$ue_ip1"; do
            if ! docker exec ue tcpdump -r "$ue_pcap" -nn icmp 2>/dev/null | grep -q "IP 1\.1\.1\.1 > ${ue_ip}: ICMP echo reply"; then
                ok=false; reason="ue.pcap missing echo reply to ${ue_ip}"; break
            fi
        done
    fi

    echo "--- cleanup ---"
    if $subscriber_created && ! free5gc_console_subscriber_action "delete"; then
        echo "WARNING: failed to delete subscriber during cleanup"
    fi
    docker compose -f "$COMPOSE_FILE" down

    if $ok; then
        add_result "$item" "$max_points" "$max_points" "✅ PASS"
    else
        add_result "$item" 0 "$max_points" "❌ FAIL (${reason})"
    fi
    MASTER_PDU_PASSED=$ok
}

########################################################
# Grading item: pdu session 1 on master RAN, pdu session 2 on
# the second RAN (static NR-DC)
#
# Same flow as grade_pdu_sessions_on_master, except staticNrdc /
# nrdc.enable are flipped to true beforehand, and this time
# UPF's GTP-U traffic must show BOTH RANs: each one both sending
# uplink and receiving downlink for its own session.
#
# Worth 20 points.
########################################################
grade_pdu_sessions_dc() {
    echo "===================================================="
    echo "[Functional] PDU session 2 on second RAN (static DC)"
    echo "===================================================="

    local item="PDU session 2 on second RAN (DC)"
    local max_points=20
    local ok=true
    local reason=""
    local subscriber_created=false

    # both mount to ./pcap on the host, so these land in the repo's pcap/ dir
    local upf_pcap="/free5gc/pcap/upf.pcap"
    local ue_pcap="/free-ran-ue/pcap/ue.pcap"

    local master_ip secondary_ip upf_ip
    master_ip=$(yq -r '.gnb.ranN3Ip' "$MASTER_GNB_CONFIG")
    secondary_ip=$(yq -r '.gnb.ranN3Ip' "$SECONDARY_GNB_CONFIG")
    upf_ip=$(yq -r '.gnb.upfN3Ip' "$MASTER_GNB_CONFIG")

    echo "--- set staticNrdc / nrdc.enable to true ---"
    set_dc_enabled true

    # best-effort: tear down any stack left over from a previous run that
    # crashed / got killed before its own `down` ran, so this run starts
    # from a known-clean state instead of colliding with stale containers.
    docker compose -f "$COMPOSE_FILE" down --remove-orphans >/dev/null 2>&1

    echo "--- docker compose up ---"
    if ! docker compose -f "$COMPOSE_FILE" up -d --wait --wait-timeout 180; then
        add_result "$item" 0 "$max_points" "❌ FAIL (compose up)"
        set_dc_enabled false
        return
    fi
    sleep 10

    echo "--- install tcpdump in upf / ue ---"
    if $ok && ! docker exec upf bash -c "apt-get update -qq && apt-get install -y -qq tcpdump procps"; then
        ok=false; reason="tcpdump install (upf) failed"
    fi
    if $ok && ! docker exec ue bash -c "apt-get update -qq && apt-get install -y -qq tcpdump procps"; then
        ok=false; reason="tcpdump install (ue) failed"
    fi

    echo "--- create subscriber ---"
    if $ok; then
        # best-effort: clear any stale subscriber left over from a previous
        # run that didn't get to clean up (mongodb data persists across
        # `docker compose down`), so "post" below is idempotent.
        free5gc_console_subscriber_action "delete" >/dev/null 2>&1

        if free5gc_console_subscriber_action "post"; then
            subscriber_created=true
        else
            ok=false; reason="subscriber post failed"
        fi
    fi

    echo "--- start ue ---"
    if $ok; then
        docker exec -d ue ./free-ran-ue ue -c uecfg.yaml
        sleep 8
        if ! docker exec ue ip addr show ueTun0 >/dev/null 2>&1 || ! docker exec ue ip addr show ueTun1 >/dev/null 2>&1; then
            ok=false; reason="ueTun0/ueTun1 did not come up"
        fi
    fi

    local ue_ip0 ue_ip1
    if $ok; then
        ue_ip0=$(docker exec ue sh -c "ip -4 -o addr show ueTun0 | awk '{print \$4}' | cut -d/ -f1")
        ue_ip1=$(docker exec ue sh -c "ip -4 -o addr show ueTun1 | awk '{print \$4}' | cut -d/ -f1")
        if [ -z "$ue_ip0" ] || [ -z "$ue_ip1" ]; then
            ok=false; reason="could not read ueTun0/ueTun1 addresses"
        fi
    fi

    echo "--- start captures ---"
    if $ok; then
        docker exec upf rm -f "$upf_pcap"
        docker exec ue rm -f "$ue_pcap"
        docker exec -d upf tcpdump -i any -w "$upf_pcap"
        docker exec -d ue tcpdump -i any -w "$ue_pcap"
        sleep 1
    fi

    echo "--- ping ueTun0 / ueTun1 ---"
    local ping0_ok=false ping1_ok=false
    if $ok; then
        docker exec ue ping -I ueTun0 1.1.1.1 -c 3 -W 3 && ping0_ok=true
        docker exec ue ping -I ueTun1 1.1.1.1 -c 3 -W 3 && ping1_ok=true
        if ! $ping0_ok || ! $ping1_ok; then
            ok=false; reason="ping failed (ueTun0=${ping0_ok}, ueTun1=${ping1_ok})"
        fi
    fi

    sleep 1
    docker exec upf pkill -INT tcpdump 2>/dev/null
    docker exec ue pkill -INT tcpdump 2>/dev/null
    sleep 1

    echo "--- verify upf.pcap / ue.pcap ---"
    if $ok; then
        # both icmp flows must have completed end to end through upf
        for ue_ip in "$ue_ip0" "$ue_ip1"; do
            if ! docker exec upf tcpdump -r "$upf_pcap" -nn icmp 2>/dev/null | grep -q "IP ${ue_ip} > 1\.1\.1\.1: ICMP echo request"; then
                ok=false; reason="upf.pcap missing echo request from ${ue_ip}"; break
            fi
            if ! docker exec upf tcpdump -r "$upf_pcap" -nn icmp 2>/dev/null | grep -q "IP 1\.1\.1\.1 > ${ue_ip}: ICMP echo reply"; then
                ok=false; reason="upf.pcap missing echo reply to ${ue_ip}"; break
            fi
        done
    fi

    if $ok; then
        # upf must see GTP-U uplink from AND downlink to BOTH RANs: master
        # for pdu session 1, second RAN for pdu session 2.
        local gtp_lines
        gtp_lines=$(docker exec upf tcpdump -r "$upf_pcap" -nn "udp port 2152" 2>/dev/null)
        for ip in "$master_ip" "$secondary_ip"; do
            if ! echo "$gtp_lines" | grep -q "IP ${ip}\.2152 > ${upf_ip}\.2152"; then
                ok=false; reason="no GTP-U uplink from RAN ${ip} in upf.pcap"; break
            fi
            if ! echo "$gtp_lines" | grep -q "IP ${upf_ip}\.2152 > ${ip}\.2152"; then
                ok=false; reason="no GTP-U downlink to RAN ${ip} in upf.pcap"; break
            fi
        done
    fi

    if $ok; then
        # ue side should also show both replies actually arriving
        for ue_ip in "$ue_ip0" "$ue_ip1"; do
            if ! docker exec ue tcpdump -r "$ue_pcap" -nn icmp 2>/dev/null | grep -q "IP 1\.1\.1\.1 > ${ue_ip}: ICMP echo reply"; then
                ok=false; reason="ue.pcap missing echo reply to ${ue_ip}"; break
            fi
        done
    fi

    echo "--- cleanup ---"
    if $subscriber_created && ! free5gc_console_subscriber_action "delete"; then
        echo "WARNING: failed to delete subscriber during cleanup"
    fi
    docker compose -f "$COMPOSE_FILE" down
    set_dc_enabled false

    if $ok; then
        add_result "$item" "$max_points" "$max_points" "✅ PASS"
    else
        add_result "$item" 0 "$max_points" "❌ FAIL (${reason})"
    fi
}

# repeat_char <char> <count> -- prints <char> repeated <count> times, no newline
# (uses a plain loop rather than `tr`, since `tr` mangles multi-byte UTF-8 input)
repeat_char() {
    local char="$1" count="$2" i
    for ((i = 0; i < count; i++)); do
        printf '%s' "$char"
    done
}

# display_width <string> -- terminal column width of a string, counting emoji /
# CJK / other "wide" characters as 2 columns. `${#string}` (and printf's %-*s
# padding) only count codepoints, so a string containing e.g. an emoji looks
# one column narrower than it actually renders, which throws the box borders
# out of alignment.
display_width() {
    python3 -c '
import sys, unicodedata

def char_width(ch):
    cp = ord(ch)
    if cp == 0x200D or 0xFE00 <= cp <= 0xFE0F:  # ZWJ / variation selectors: zero width
        return 0
    if unicodedata.east_asian_width(ch) in ("W", "F"):
        return 2
    if 0x1F300 <= cp <= 0x1FAFF or 0x2600 <= cp <= 0x27BF or 0x2190 <= cp <= 0x21FF:
        return 2
    return 1

s = sys.argv[1] if len(sys.argv) > 1 else ""
print(sum(char_width(c) for c in s))
' "$1"
}

# pad_cell <content> <col_width> -- prints content left-aligned, padded with
# spaces to col_width terminal columns (by display width, not character count)
pad_cell() {
    local content="$1" col_width="$2"
    local dw pad
    dw=$(display_width "$content")
    pad=$((col_width - dw))
    [ "$pad" -lt 0 ] && pad=0
    printf '%s' "$content"
    repeat_char ' ' "$pad"
}

# box_row <w1> <w2> <w3> <col1> <col2> <col3>
box_row() {
    local w1="$1" w2="$2" w3="$3"
    printf "│ "; pad_cell "$4" "$w1"; printf " │ "; pad_cell "$5" "$w2"
    printf " │ "; pad_cell "$6" "$w3"
    printf " │\n"
}

# box_border <left> <mid> <right> <w1> <w2> <w3>
box_border() {
    local left="$1" mid="$2" right="$3" w1="$4" w2="$5" w3="$6"
    printf "%s%s%s%s%s%s%s\n" \
        "$left" "$(repeat_char '─' $((w1 + 2)))" \
        "$mid" "$(repeat_char '─' $((w2 + 2)))" \
        "$mid" "$(repeat_char '─' $((w3 + 2)))" \
        "$right"
}

print_table() {
    local h1="Item" h2="Score" h3="Status"
    local w1 w2 w3
    w1=$(display_width "$h1"); w2=$(display_width "$h2"); w3=$(display_width "$h3")

    local scores=() total=0 max_total=0
    for i in "${!RESULT_NAMES[@]}"; do
        local score="${RESULT_POINTS[$i]}/${RESULT_MAX_POINTS[$i]}"
        scores+=("$score")
        total=$((total + RESULT_POINTS[$i]))
        max_total=$((max_total + RESULT_MAX_POINTS[$i]))

        local dw
        dw=$(display_width "${RESULT_NAMES[$i]}"); [ "$dw" -gt "$w1" ] && w1=$dw
        dw=$(display_width "$score"); [ "$dw" -gt "$w2" ] && w2=$dw
        dw=$(display_width "${RESULT_STATUS[$i]}"); [ "$dw" -gt "$w3" ] && w3=$dw
    done

    local total_label="Total" total_score="${total}/${max_total}"
    local dw
    dw=$(display_width "$total_label"); [ "$dw" -gt "$w1" ] && w1=$dw
    dw=$(display_width "$total_score"); [ "$dw" -gt "$w2" ] && w2=$dw

    echo
    box_border "┌" "┬" "┐" "$w1" "$w2" "$w3"
    box_row "$w1" "$w2" "$w3" "$h1" "$h2" "$h3"
    box_border "├" "┼" "┤" "$w1" "$w2" "$w3"

    for i in "${!RESULT_NAMES[@]}"; do
        box_row "$w1" "$w2" "$w3" "${RESULT_NAMES[$i]}" "${scores[$i]}" "${RESULT_STATUS[$i]}"
    done

    box_border "├" "┼" "┤" "$w1" "$w2" "$w3"
    box_row "$w1" "$w2" "$w3" "$total_label" "$total_score" "-"
    box_border "└" "┴" "┘" "$w1" "$w2" "$w3"
}

main() {
    check_required_tools

    CODE_GATE_PASSED=false
    grade_code

    if [ "$CODE_GATE_PASSED" = true ]; then
        MASTER_PDU_PASSED=false
        grade_pdu_sessions_on_master

        if [ "$MASTER_PDU_PASSED" = true ]; then
            grade_pdu_sessions_dc
        else
            add_result "PDU session 2 on second RAN (DC)" 0 20 "⏭️ SKIP (master test failed)"
        fi
        # TODO: add more grade_xxx items here as they are defined.
    else
        add_result "PDU sessions on master RAN" 0 60 "⏭️ SKIP (code gate failed)"
        add_result "PDU session 2 on second RAN (DC)" 0 20 "⏭️ SKIP (code gate failed)"
    fi

    print_table

    if [ "$CODE_GATE_PASSED" != true ]; then
        echo
        echo "Code gate failed: later grading items would not be meaningful and were skipped."
        exit 1
    fi
}

main "$@"
