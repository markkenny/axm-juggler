#!/bin/bash

set -euo pipefail

####### Description
# VERSION=20260915a
# ABM MDM Manager for Jamf Self Service
# 2026 09 15 MK Initial Public Release

####### Jamf Policy Context
currentUser=$( echo "show State:/Users/ConsoleUser" | scutil | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
currentHome=$( dscl . read /Users/${currentUser} NFSHomeDirectory | awk '{print $2}' )

####### Report Directory Setup
REPORT_DIR="${currentHome}/Downloads/JAMF API Reports"
if [[ ! -d "${REPORT_DIR}" ]]; then
    /bin/mkdir -p "${REPORT_DIR}" || exit 1
fi
/usr/sbin/chown "${currentUser}:staff" "${REPORT_DIR}"

####### Repository Paths
if [[ -d "${currentHome}/Git/axm-juggler" ]]; then
    REPO_ROOT="${currentHome}/Git/axm-juggler"
else
    /usr/bin/osascript -e 'display notification "AxM Juggler Repo missing" with title "ABM MDM Manager Error"'
    exit 1
fi

TOKEN_CONFIG="${REPO_ROOT}/config/token_config.env"
[[ ! -f "${TOKEN_CONFIG}" ]] && {
    /usr/bin/osascript -e 'display notification "Token config missing" with title "ABM MDM Manager Error"'
    exit 1
}

####### DEBUG MODE - Adds more checks and keeps logs
DEBUG_MODE="${4:-NO}"
if [[ "${DEBUG_MODE}" != "YES" ]] && [[ "${DEBUG_MODE}" != "NO" ]]; then
    DEBUG_MODE="NO"
fi

####### CONFIRMATION MODE - Checks all serials again manually. Takes a lot longer
CONFIRM_MODE="${5:-YES}"
if [[ "${CONFIRM_MODE}" != "YES" ]] && [[ "${CONFIRM_MODE}" != "NO" ]]; then
    CONFIRM_MODE="NO"
fi

####### BULK or SINGLE MODE - Bulks reads a CSV, single only allows one serial. Do you want users to be able to bulk change?
BULK_MODE="${6:-NO}"
if [[ "${BULK_MODE}" != "YES" ]] && [[ "${BULK_MODE}" != "NO" ]]; then
    BULK_MODE="NO"
fi

####### ASSIGN OPTIONS - Limit the options presnted in Self Service, one policy for assign, another policy for another team to unassign
# DRY-RUN (Default) or "ALL" or comma-separated list "ASSIGN_JAMF_1,ASSIGN_JAMF_2,DRY_RUN"
ASSIGN_OPTIONS="${7:-DRY_RUN}"

####### SILENT MODE - Does not prompt with report at end of process.
# Idea being, you run a second script that reads the results of this MDM change to assign to policy, or static group. 
# We use it to update Barcode 1 for scoping, or assign a policy to run the Jamf Migrate binary.
# If you don't know Jamf Migrate and need to move Macs between MDM servers, ask your account manager.
SILENT="${8:-NO}"
if [[ "${SILENT}" != "YES" ]] && [[ "${SILENT}" != "NO" ]]; then
    SILENT="NO"
fi

####### Logging Setup
DATE_TIME=$(date +%Y%m%d_%H%M)
LOG_FILE="/tmp/ABM_MDM_Activity_${DATE_TIME}.log"
temp_dir="/tmp/ABM_MDM_Activity_${DATE_TIME}"
/bin/mkdir -p "${temp_dir}"
results_file="${temp_dir}/activity_results.txt"
verify_results_file="${temp_dir}/verify_results.txt"
skip_list_file="${temp_dir}/skip_list.txt"
lookup_map="${temp_dir}/lookup_map.txt"
touch "${results_file}" "${verify_results_file}" "${skip_list_file}"

MIN_BATCH_SIZE=8
MAX_BATCH_COOLDOWN=32
MAX_TOKEN_COOLDOWN=32
MAX_POLL_INTERVAL=16
MAX_ADAPTIVE_EVENTS=4
ADAPTIVE_TRIGGER_COUNT=0
MAX_BATCH_SIZE=64
MAX_STATUS_CHECKS=8
MAX_RETRIES=4
SECONDS=0
API_MIN_INTERVAL=1
LAST_API_CALL=0

# Adaptive throttling
ADAPTIVE_MODE=0
CURRENT_BATCH_SIZE=${MAX_BATCH_SIZE}
BATCH_COOLDOWN=4
TOKEN_COOLDOWN=4
POLL_INTERVAL=8
RATE_LIMIT_HIT=0
NO_PROGRESS_COUNT=0
MAX_NO_PROGRESS=4

# Verification phase
VERIFY_START_TIME=0

####### Functions

####### NEW FUNCTION: Parse and validate ASSIGN_OPTIONS
parse_assign_options() {
    local options_str="$1"
    local allowed_actions="ASSIGN_JAMF_1 ASSIGN_JAMF_2 UNASSIGN DRY_RUN"
    local output=""
    
    # If ALL, return all actions
    if [[ "${options_str}" == "ALL" ]]; then
        echo "ASSIGN_JAMF_1  ASSIGN_JAMF_2 UNASSIGN DRY_RUN"
        return 0
    fi
    
    # Parse comma-separated list
    local old_ifs="${IFS}"
    IFS=','
    for action in ${options_str}; do
        IFS="${old_ifs}"
        action=$(echo "${action}" | tr -d ' ')  # Remove spaces
        
        # Validate against allowed list
        if echo "${allowed_actions}" | grep -q "${action}"; then
            [[ -n "${output}" ]] && output="${output} "
            output="${output}${action}"
        else
            log "WARN" "Unknown action in ASSIGN_OPTIONS: ${action}"
        fi
        IFS=','
    done
    IFS="${old_ifs}"
    
    [[ -z "${output}" ]] && output="ASSIGN_JAMF_1 ASSIGN_JAMF_2 UNASSIGN DRY_RUN"
    echo "${output}"
}

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    if [[ "${level}" == "DEBUG" ]]; then
        echo "[${timestamp}] [${level}] ${message}" >> "${LOG_FILE}"
        return 0
    fi
    
    echo "[${timestamp}] [${level}] ${message}" | tee -a "${LOG_FILE}" >&2
}

error_exit() {
    log "ERROR" "$@"
    exit 1
}

cleanup() {
    if [[ "${DEBUG_MODE}" == "YES" ]]; then
        log "INFO" "DEBUG MODE: Preserving temp_dir at ${temp_dir}"
        return 0
    fi
    [[ -d "${temp_dir}" ]] && /bin/rm -rf "${temp_dir}"
}
trap cleanup EXIT

####### Select CSV file or serial (osascript) — NOW WITH BULK_MODE ENFORCEMENT

select_input_file() {
    local user_input
    local prompt_text

    # ✅ Dynamic prompt based on BULK_MODE
    if [[ "${BULK_MODE}" == "YES" ]]; then
        prompt_text="Drag a CSV file or paste a single serial number:"
    else
        prompt_text="Enter a single serial number:"
    fi

    user_input=$(/usr/bin/osascript <<OSASCRIPT
        try
            set userResponse to display dialog ¬
                "${prompt_text}" ¬
                default answer "" ¬
                buttons {"Cancel", "OK"} ¬
                default button "OK" ¬
                with title "ABM MDM Manager - Input"

            return text returned of userResponse
        on error number -128
            return "__CANCEL__"
        end try
OSASCRIPT
    )

    if [[ "$user_input" == "__CANCEL__" ]]; then
        log "INFO" "User cancelled input. Exiting."
        exit 0
    fi

    # ✅ CLEAN INPUT
    user_input="${user_input#\"}"
    user_input="${user_input%\"}"
    user_input="${user_input#\'}"
    user_input="${user_input%\'}"

    # ✅ VALIDATION
    if [[ -z "${user_input}" ]]; then
        error_exit "No input provided"
    fi

    # ✅ NEW: BULK_MODE ENFORCEMENT
    if [[ "${user_input}" == *.csv ]]; then
        # CSV file provided
        if [[ "${BULK_MODE}" != "YES" ]]; then
            error_exit "Bulk mode is disabled. Please provide a single serial number instead."
        fi
        
        [[ ! -f "${user_input}" ]] && error_exit "File not found"

        # ✅ NORMALISE INPUT → CLEAN COPY
        input_csv="${temp_dir}/clean_input.csv"

        log "DEBUG" "Normalising CSV input..."

        /usr/bin/iconv -f utf-8 -t utf-8 "${user_input}" 2>/dev/null | \
        tr -d '\r' | \
        sed '1s/^\xEF\xBB\xBF//' | \
        sed 's/"//g' | \
        awk 'NF' > "${input_csv}"

    else
        # Single serial provided
        [[ ! "${user_input}" =~ ^[A-Z0-9]{8,16}$ ]] && error_exit "Invalid serial"

        input_csv="${temp_dir}/single_serial.csv"
        echo "${user_input}" > "${input_csv}"
    fi

}

####### Select action (osascript) — NOW WITH ASSIGN_OPTIONS FILTERING

select_action() {
    local choice
    
    # Parse allowed options from ASSIGN_OPTIONS parameter
    allowed_options=$(parse_assign_options "${ASSIGN_OPTIONS}")
    
    # If only one option available, return it directly without prompting
    local opt_count=$(echo "${allowed_options}" | wc -w | tr -d ' ')
    if [[ ${opt_count} -eq 1 ]]; then
        echo "${allowed_options}"
        return 0
    fi
    
    # Build dynamic osascript arrays based on allowed options
    local action_list=""
    local display_list=""
    
    for opt in ${allowed_options}; do
        case "${opt}" in
            ASSIGN_JAMF_1)
                action_list="${action_list}\"ASSIGN_JAMF_1\", "
                display_list="${display_list}\"Assign to My Jamf Server\", "
                ;;
            ASSIGN_JAMF_2)
                action_list="${action_list}\"ASSIGN_JAMF_2\", "
                display_list="${display_list}\"Assign to Your Jamf Server\", "
                ;;
            UNASSIGN)
                action_list="${action_list}\"UNASSIGN\", "
                display_list="${display_list}\"Unassign from all servers\", "
                ;;
            DRY_RUN)
                action_list="${action_list}\"DRY_RUN\", "
                display_list="${display_list}\"Check assignments (Dry run)\", "
                ;;
        esac
    done
    
    # Remove trailing ", "
    action_list="${action_list%, }"
    display_list="${display_list%, }"
    
    log "DEBUG" "Allowed actions: ${allowed_options}"

    choice=$(/usr/bin/osascript <<OSASCRIPT
        try
            set actionList to {${action_list}}
            set displayList to {${display_list}}
            
            set userChoice to (choose from list displayList with title "ABM MDM Manager" with prompt "Choose an action:")
            
            if userChoice is false then
                return "__CANCEL__"
            end if
            
            set selectedItem to item 1 of userChoice
            set selectedIndex to 0
            
            repeat with i from 1 to count of displayList
                if item i of displayList is equal to selectedItem then
                    set selectedIndex to i
                    exit repeat
                end if
            end repeat
            
            if selectedIndex > 0 then
                return item selectedIndex of actionList
            else
                return "__ERROR__"
            end if

        on error errMsg number errNum
            if errNum is -128 then
                return "__CANCEL__"
            else
                return "__ERROR__"
            end if
        end try
OSASCRIPT
    )

    if [[ "${choice}" == "__CANCEL__" ]]; then
        log "INFO" "User cancelled action selection. Exiting."
        exit 0
    fi

    [[ "${choice}" == "__ERROR__" ]] && error_exit "Invalid selection returned from dialog"

    echo "${choice}"
}

####### Call ABM API with retry
call_abm_api() {
    local access_token="$1"
    local method="${2:-GET}"
    local endpoint="$3"
    local data="${4:-}"
    local retry_count=0
    
    [[ -z "${access_token}" ]] || [[ -z "${endpoint}" ]] && return 1
    
    while [[ ${retry_count} -lt ${MAX_RETRIES} ]]; do
        local response
        if [[ -n "${data}" ]]; then

            # NEW: Global rate limit
            now=$(date +%s)
            delta=$((now - LAST_API_CALL))
            if (( delta < API_MIN_INTERVAL )); then
                sleep $((API_MIN_INTERVAL - delta))
            fi
            LAST_API_CALL=$(date +%s)

            response=$(/usr/bin/curl -s -k --max-time 30 -w "\n%{http_code}" \
                -X "${method}" \
                -H "Authorization: Bearer ${access_token}" \
                -H "Accept: application/json" \
                -H "Content-Type: application/json" \
                -d "${data}" \
                "https://api-business.apple.com${endpoint}")
        else

            # NEW: Global rate limit
            now=$(date +%s)
            delta=$((now - LAST_API_CALL))
            if (( delta < API_MIN_INTERVAL )); then
                sleep $((API_MIN_INTERVAL - delta))
            fi
            LAST_API_CALL=$(date +%s)

            response=$(/usr/bin/curl -s -k --max-time 30 -w "\n%{http_code}" \
                -X "${method}" \
                -H "Authorization: Bearer ${access_token}" \
                -H "Accept: application/json" \
                "https://api-business.apple.com${endpoint}")
        fi
        
        local http_code=$(echo "${response}" | sed -n '$p')
        
        if [[ "${http_code}" == "401" ]] || [[ "${http_code}" == "429" ]]; then
            if [[ "${http_code}" == "429" ]]; then
                RATE_LIMIT_HIT=1
            fi
            retry_count=$((retry_count + 1))
            if [[ ${retry_count} -lt ${MAX_RETRIES} ]]; then
                log "WARN" "HTTP ${http_code}, retry ${retry_count}/${MAX_RETRIES}..."
                
                backoff=$(( (2 ** retry_count) * 5 ))
                jitter=$(( RANDOM % 5 ))
                sleep $((backoff + jitter))

                continue
            fi
        fi
        
        echo "${response}"
        return 0
    done
}

####### Get MDM servers
get_mdm_servers() {
    local access_token="$1"
    local response
    response=$(call_abm_api "${access_token}" GET "/v1/mdmServers" 2>/dev/null)
    
    local http_code=$(echo "${response}" | sed -n '$p')
    local body=$(echo "${response}" | sed '$d')
    
    [[ "${http_code}" != "200" ]] && { echo "{}"; return 0; }
    echo "${body}"
}

####### Find server ID by name
find_server_id() {
    local mdm_servers_json="$1"
    local server_name="$2"
    
    echo "${mdm_servers_json}" | /usr/bin/jq -r \
        --arg name "${server_name}" \
        '.data[] | select(.attributes.serverName == $name) | .id' 2>/dev/null | head -n1
}

####### ✅ NEW FUNCTION: Get assigned server name via /assignedServer endpoint
get_assigned_server_name() {
    local access_token="$1"
    local device_id="$2"
    
    local response
    response=$(call_abm_api "${access_token}" GET "/v1/orgDevices/${device_id}/assignedServer" 2>/dev/null)
    
    local http_code=$(echo "${response}" | sed -n '$p')
    local body=$(echo "${response}" | sed '$d')
    
    # If 404 or empty, device is unassigned
    if [[ "${http_code}" != "200" ]]; then
        echo "UNASSIGNED"
        return 0
    fi
    
    # Extract serverName from the MDM server metadata
    local server_name=$(echo "${body}" | /usr/bin/jq -r '.data.attributes.serverName // ""' 2>/dev/null)
    
    if [[ -z "${server_name}" ]]; then
        echo "UNASSIGNED"
    else
        echo "${server_name}"
    fi
}

####### POST device activity
post_device_activity() {
    local access_token="$1"
    local mdm_server_id="$2"
    local activity_type="$3"
    shift 3
    local device_ids=("$@")
    
    local devices_json=""
    for device_id in "${device_ids[@]}"; do
        [[ -n "${devices_json}" ]] && devices_json="${devices_json},"
        devices_json="${devices_json}{\"type\":\"orgDevices\",\"id\":\"${device_id}\"}"
    done
    
    local payload=$(jq -n \
        --arg mdm_id "${mdm_server_id}" \
        --arg activity_type "${activity_type}" \
        --argjson devices "[${devices_json}]" \
        '{
            data: {
                type: "orgDeviceActivities",
                attributes: {activityType: $activity_type},
                relationships: {
                    mdmServer: {data: {type: "mdmServers", id: $mdm_id}},
                    devices: {data: $devices}
                }
            }
        }')
    
    local response

    # APPLY GLOBAL RATE LIMIT
    now=$(date +%s)
    delta=$((now - LAST_API_CALL))
    if (( delta < API_MIN_INTERVAL )); then
        sleep $((API_MIN_INTERVAL - delta))
    fi
    LAST_API_CALL=$(date +%s)

    response=$(/usr/bin/curl -s -k -w "\n%{http_code}" \
        -X "POST" \
        -H "Authorization: Bearer ${access_token}" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "https://api-business.apple.com/v1/orgDeviceActivities")
    
    local http_code=$(echo "${response}" | sed -n '$p')
    local body=$(echo "${response}" | sed '$d')
    
    [[ "${http_code}" != "201" ]] && { echo "ERROR|${http_code}"; return 0; }
    
    local activity_id=$(echo "${body}" | /usr/bin/jq -r '.data.id // ""' 2>/dev/null)
    [[ -z "${activity_id}" ]] && { echo "ERROR|NO_ID"; return 0; }
    
    echo "OK"
    echo "${body}"
}

####### Get activity status
get_activity_status() {
    local access_token="$1"
    local activity_id="$2"
    
    local response
    response=$(call_abm_api "${access_token}" GET "/v1/orgDeviceActivities/${activity_id}" 2>/dev/null)
    
    local http_code=$(echo "${response}" | sed -n '$p')
    local body=$(echo "${response}" | sed '$d')
    
    [[ "${http_code}" != "200" ]] && { echo "ERROR|${http_code}"; return 0; }
    
    echo "OK"
    echo "${body}"
}

####### Adaptive Throttling for 429 errors
adaptive_throttle() {

    if [[ ${RATE_LIMIT_HIT} -eq 1 ]]; then

        log "WARN" "⚠️  Rate limit detected → entering adaptive mode"

        ADAPTIVE_MODE=1
        RATE_LIMIT_HIT=0

        ADAPTIVE_TRIGGER_COUNT=$((ADAPTIVE_TRIGGER_COUNT + 1))

        # ✅ Stop adapting if too many triggers
        if [[ ${ADAPTIVE_TRIGGER_COUNT} -gt ${MAX_ADAPTIVE_EVENTS} ]]; then
            log "ERROR" "Adaptive limit reached (${MAX_ADAPTIVE_EVENTS}) — stabilising"
            return
        fi

        # ✅ Shrink batch (respect minimum)
        if [[ ${CURRENT_BATCH_SIZE} -gt ${MIN_BATCH_SIZE} ]]; then
            CURRENT_BATCH_SIZE=$((CURRENT_BATCH_SIZE / 2))
            [[ ${CURRENT_BATCH_SIZE} -lt ${MIN_BATCH_SIZE} ]] && CURRENT_BATCH_SIZE=${MIN_BATCH_SIZE}
        fi

        # ✅ Cap cooldown increases
        BATCH_COOLDOWN=$((BATCH_COOLDOWN + 5))
        [[ ${BATCH_COOLDOWN} -gt ${MAX_BATCH_COOLDOWN} ]] && BATCH_COOLDOWN=${MAX_BATCH_COOLDOWN}

        TOKEN_COOLDOWN=$((TOKEN_COOLDOWN + 5))
        [[ ${TOKEN_COOLDOWN} -gt ${MAX_TOKEN_COOLDOWN} ]] && TOKEN_COOLDOWN=${MAX_TOKEN_COOLDOWN}

        POLL_INTERVAL=$((POLL_INTERVAL + 2))
        [[ ${POLL_INTERVAL} -gt ${MAX_POLL_INTERVAL} ]] && POLL_INTERVAL=${MAX_POLL_INTERVAL}

        log "INFO" "Adaptive settings:"
        log "INFO" "  Batch size → ${CURRENT_BATCH_SIZE}"
        log "INFO" "  Batch cooldown → ${BATCH_COOLDOWN}s"
        log "INFO" "  Token cooldown → ${TOKEN_COOLDOWN}s"
        log "INFO" "  Poll interval → ${POLL_INTERVAL}s"
    fi
}

####### CHECK IF SERIAL IS IN SKIP LIST (file-based, Bash 3.2 compatible)
is_serial_skipped() {
    local serial="$1"
    [[ ! -f "${skip_list_file}" ]] && return 1
    grep -q "^${serial}|" "${skip_list_file}" 2>/dev/null && return 0 || return 1
}

####### GET SKIP TIMESTAMP (from skip list file)
get_skip_timestamp() {
    local serial="$1"
    [[ ! -f "${skip_list_file}" ]] && { echo ""; return 1; }
    awk -F'|' -v s="${serial}" '$1 == s {print $2; exit}' "${skip_list_file}"
}

####### VERIFICATION PHASE WITH RETRY LOGIC (Bash 3.2 compatible)
verify_device_assignments() {
    local action="$1"
    local target_server="$2"
    
    # Verify all assignment-related actions
    if [[ "${action}" != "ASSIGN_JAMF_1" ]] && [[ "${action}" != "ASSIGN_JAMF_2" ]] && [[ "${action}" != "UNASSIGN" ]]; then
        log "INFO" "Skipping verification (not an assignment action)"
        return 0
    fi
    
    log "INFO" "============ VERIFICATION PHASE (LIVE ABM CHECK) ============"
    VERIFY_START_TIME=$(date +%s)
    
    # ✅ SETTLE TIME: Wait for ABM inventory to sync
    log "INFO" "Waiting for ABM inventory sync (30 seconds)..."
    sleep 32 # I prefer 32 over 30
    
    # Read changed serials from results file (only devices that were actually changed)
    verify_serials_list=""
    
    if [[ -f "${results_file}" ]]; then
        verify_serials_list=$(cut -d'|' -f1 "${results_file}" | sort -u)
    fi
    
    if [[ -z "${verify_serials_list}" ]]; then
        log "WARN" "No serials to verify (no devices were changed)"
        return 0
    fi
    
    log "INFO" "Verifying changed device(s) against live ABM..."
    
    verify_success=0
    verify_failure=0
    
    # PASS 1: Initial verification
    log "INFO" "PASS 1: Initial verification..."
    
    while IFS= read -r serial; do
        [[ -z "${serial}" ]] && continue
        
        log "DEBUG" "  Checking device: ${serial}"
        
        # Get token from lookup map for this serial
        token=$(awk -F'|' -v s="${serial}" '$1 == s {print $2; exit}' "${lookup_map}")
        [[ -z "${token}" ]] && continue
        
        # Get fresh token
        access_token=$("${REPO_ROOT}/ABM_tokenManager.sh" get "${token}" 2>/dev/null) || {
            log "WARN" "Failed to get token for verification: ${token}"
            echo "${serial}" >> "${temp_dir}/retry_list.txt"
            continue
        }
        
        [[ -z "${access_token}" ]] && { 
            log "WARN" "Empty token for verification"
            continue
        }
        
        # ✅ Use new endpoint function for verification
        assigned_server=$(get_assigned_server_name "${access_token}" "${serial}")
        
        check_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        
        log "DEBUG" "    Device ${serial} → Assigned to: ${assigned_server}"
        
        # ✅ VERIFICATION LOGIC (ACTION-DEPENDENT)
        if [[ "${action}" == "UNASSIGN" ]]; then
            if [[ "${assigned_server}" == "UNASSIGNED" ]] || [[ -z "${assigned_server}" ]]; then
                log "DEBUG" "    ✓ Device ${serial} successfully UNASSIGNED"
                echo "${serial}|${assigned_server}|${check_ts}" >> "${verify_results_file}"
                verify_success=$((verify_success + 1))
            else
                log "DEBUG" "    ⏳ Device ${serial} still assigned (may retry)"
                echo "${serial}|${assigned_server}|${check_ts}" >> "${verify_results_file}"
                echo "${serial}" >> "${temp_dir}/retry_list.txt"
            fi
        else
            # For ASSIGN: verify device is assigned to target server
            if [[ "${assigned_server}" == "${target_server}" ]]; then
                log "DEBUG" "    ✓ Device ${serial} assigned to: ${assigned_server}"
                echo "${serial}|${assigned_server}|${check_ts}" >> "${verify_results_file}"
                verify_success=$((verify_success + 1))
            elif [[ "${assigned_server}" == "UNASSIGNED" ]] || [[ -z "${assigned_server}" ]]; then
                log "DEBUG" "    ⏳ Device ${serial} not yet visible in inventory (API lag, marking for retry)"
                echo "${serial}|${assigned_server}|${check_ts}" >> "${verify_results_file}"
                echo "${serial}" >> "${temp_dir}/retry_list.txt"
            else
                log "WARN" "    ✗ Device ${serial} assigned to wrong server: ${assigned_server}"
                echo "${serial}|${assigned_server}|${check_ts}" >> "${verify_results_file}"
                verify_failure=$((verify_failure + 1))
            fi
        fi
        
        sleep 0.2
    done <<< "${verify_serials_list}"
    
    # PASS 2: Retry failed/lagged devices
    if [[ -f "${temp_dir}/retry_list.txt" ]]; then
        retry_count=$(wc -l < "${temp_dir}/retry_list.txt" | tr -d ' ')
        if [[ ${retry_count} -gt 0 ]]; then
            log "INFO" "PASS 2: Retrying ${retry_count} device(s) (API sync lag)..."
            sleep 15
            
            while IFS= read -r serial; do
                [[ -z "${serial}" ]] && continue
                
                log "DEBUG" "  Re-checking device: ${serial}"
                
                token=$(awk -F'|' -v s="${serial}" '$1 == s {print $2; exit}' "${lookup_map}")
                [[ -z "${token}" ]] && continue
                
                access_token=$("${REPO_ROOT}/ABM_tokenManager.sh" get "${token}" 2>/dev/null) || continue
                [[ -z "${access_token}" ]] && continue
                
                # ✅ Use new endpoint function
                assigned_server=$(get_assigned_server_name "${access_token}" "${serial}")
                
                check_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
                
                # Remove old entry and add retry result
                sed -i "" "/^${serial}|/d" "${verify_results_file}"
                echo "${serial}|${assigned_server}|${check_ts}" >> "${verify_results_file}"
                
                # Re-evaluate
                if [[ "${action}" == "UNASSIGN" ]]; then
                    if [[ "${assigned_server}" == "UNASSIGNED" ]] || [[ -z "${assigned_server}" ]]; then
                        log "DEBUG" "    ✓ RETRY: Device ${serial} successfully UNASSIGNED"
                        verify_success=$((verify_success + 1))
                    else
                        log "WARN" "    ✗ RETRY: Device ${serial} STILL assigned to: ${assigned_server}"
                        verify_failure=$((verify_failure + 1))
                    fi
                else
                    if [[ "${assigned_server}" == "${target_server}" ]]; then
                        log "DEBUG" "    ✓ RETRY: Device ${serial} now assigned to: ${assigned_server}"
                        verify_success=$((verify_success + 1))
                    else
                        log "WARN" "    ✗ RETRY: Device ${serial} mismatch: expected ${target_server}, got ${assigned_server}"
                        verify_failure=$((verify_failure + 1))
                    fi
                fi
                
                sleep 0.2
            done < "${temp_dir}/retry_list.txt"
        fi
    fi
    
    verify_duration=$(($(date +%s) - VERIFY_START_TIME))
    log "INFO" "Verification complete: ${verify_success} success, ${verify_failure} failed"
    log "INFO" "Verification time: $((verify_duration / 60))m $((verify_duration % 60))s"
    log "INFO" "=============================================================="
}

####### MAIN

log "INFO" "Starting ABM MDM Manager (Jamf Self Service)..."
log "INFO" "BULK_MODE . . : ${BULK_MODE}"
log "INFO" "ASSIGN_OPTIONS: ${ASSIGN_OPTIONS}"
log "INFO" "CONFIRM . . . : ${CONFIRM_MODE}"
log "INFO" "SILENT  . . . : ${SILENT}"

select_input_file
log "INFO" "Processing: ${input_csv}"

# ✅ DEBUG: Copy supplied input and log count
supplied_input_copy="${temp_dir}/supplied_input.csv"
/bin/cp "${input_csv}" "${supplied_input_copy}" 2>/dev/null || true

if [[ "${DEBUG_MODE}" == "YES" ]]; then
    raw_count=$(grep -c '.' "${input_csv}" 2>/dev/null || true)
    raw_count=$(echo "${raw_count}" | tr -d '[:space:]')
    [[ -z "${raw_count}" ]] && raw_count=0
    header_count=$(grep -ic "serial" "${input_csv}" 2>/dev/null || true)
    header_count=$(echo "${header_count}" | tr -d '[:space:]')
    [[ -z "${header_count}" ]] && header_count=0
    clean_count=$((raw_count - header_count))
    [[ ${clean_count} -lt 0 ]] && clean_count=0
    log "DEBUG" "Input file copied to: ${supplied_input_copy}"
    log "DEBUG" "Input raw line count: ${raw_count}"
    log "DEBUG" "Header rows found: ${header_count}"
    log "DEBUG" "Cleaned serial count: ${clean_count}"
    log "INFO" "======== DEBUG MODE ACTIVE ========"
    log "INFO" "Debug temp_dir: ${temp_dir}"
    log "INFO" "temp_dir will NOT be deleted on exit"
    log "INFO" "======================================"
fi

action=$(select_action)
log "INFO" "Action: ${action}"

case "${action}" in
    ASSIGN_JAMF_1)
        activity_type="ASSIGN_DEVICES"
        target_server="My Jamf Server"
        actionLabel="ASSIGN_JAMF_1"
        ;;
    ASSIGN_JAMF_2)
        activity_type="ASSIGN_DEVICES"
        target_server="Your Jamf Server"
        actionLabel="ASSIGN_JAMF_2"
        ;;
    UNASSIGN)
        activity_type="UNASSIGN_DEVICES"
        target_server=""
        actionLabel="UNASSIGN"
        ;;
    DRY_RUN)
        actionLabel="DRYRUN"
        ;;
esac

# ========== DRY-RUN HANDLER ==========
if [[ "${action}" == "DRY_RUN" ]]; then
    log "INFO" "DRY-RUN: Checking live MDM assignments (no changes)..."
    
    # ✅ EARLY VALIDATION: /tmp/AxM must exist
    if [[ ! -d "/tmp/AxM" ]]; then
        log "ERROR" "ABM Serials directory not found: /tmp/AxM"
        log "ERROR" "Cannot proceed without MacSerials database"
        /usr/bin/osascript -e 'display notification "ABM Serials directory missing (/tmp/AxM)" with title "ABM MDM Manager Error"'
        error_exit "ABM Serials CSV directory not found"
    fi
    
    # Read input serials
    device_ids_list=""
    device_count=0
    while IFS= read -r serial; do
        [[ -z "${serial}" ]] && continue
        if [[ "${serial}" =~ [Ss][Ee][Rr][Ii][Aa][Ll] ]]; then
            log "DEBUG" "Skipping header row: ${serial}"
            continue
        fi
        device_ids_list="${device_ids_list}${serial}"$'\n'
        device_count=$((device_count + 1))
    done < "${input_csv}"
    
    [[ ${device_count} -eq 0 ]] && error_exit "No serials found"
    log "INFO" "Found ${device_count} serial(s)"

    latest_macserials=$(find "/tmp/AxM" -maxdepth 1 -name "ALL_ABM_MacSerials_*.csv" -type f 2>/dev/null | sort -V | tail -n1)

    if [[ -z "${latest_macserials}" ]]; then
        log "ERROR" "No MacSerials CSV files found in /tmp/AxM"
        /usr/bin/osascript -e 'display notification "ABM Serials CSV file not found" with title "ABM MDM Manager Error"'
        error_exit "ABM Serials CSV not found"
    fi

    log "INFO" "Using local MacSerials: $(basename "${latest_macserials}")"
    
    # Create DRY-RUN report
    master_csv="${REPORT_DIR}/ABM_MDM_${actionLabel}_${DATE_TIME}.csv"
    echo "TokenName,action,serial_number,current_mdm,destination_mdm,result1,result2,timestamp,destination_mdm_check,check_timestamp" > "${master_csv}"

    while IFS= read -r serial; do
        [[ -z "${serial}" ]] && continue
        
        # Get token from MacSerials
        token=$(awk -F',' -v s="${serial}" '{gsub(/"/, "", $1); gsub(/"/, "", $2); if ($2 == s) {print $1; exit}}' "${latest_macserials}")
        
        if [[ -z "${token}" ]]; then
            token="NOT_FOUND"
        fi
        
        # Query ABM for current state
        if [[ "${token}" != "NOT_FOUND" ]]; then
            access_token=$("${REPO_ROOT}/ABM_tokenManager.sh" get "${token}" 2>/dev/null) || {
                echo "${token},DRY_RUN,${serial},NOT_FOUND,NOT_FOUND,NOT_FOUND,NOT_FOUND,NOT_FOUND,NOT_FOUND,NOT_FOUND" >> "${master_csv}"
                continue
            }
            
            [[ -z "${access_token}" ]] && {
                echo "${token},DRY_RUN,${serial},NOT_FOUND,NOT_FOUND,NOT_FOUND,NOT_FOUND,NOT_FOUND,NOT_FOUND,NOT_FOUND" >> "${master_csv}"
                continue
            }
            
            # ✅ Use new endpoint
            current_mdm=$(get_assigned_server_name "${access_token}" "${serial}")
            
            if [[ "${current_mdm}" == "NOT_FOUND" ]]; then
                current_mdm="NOT_FOUND"
            fi
            
            timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
            echo "${token},DRY_RUN,${serial},${current_mdm},DRY-RUN,Checked,No changes,${timestamp},,${timestamp}" >> "${master_csv}"
        else
            echo "NOT_FOUND,DRY_RUN,${serial},NOT_FOUND,NOT_FOUND,NOT_FOUND,NOT_FOUND,NOT_FOUND,NOT_FOUND,NOT_FOUND" >> "${master_csv}"
        fi
    done <<< "${device_ids_list}"

    log "INFO" "DRY-RUN complete: ${master_csv}"
    
    if [[ "${DEBUG_MODE}" == "YES" ]]; then
        temp_csv="${temp_dir}/activity_report.csv"
        /bin/cp "${master_csv}" "${temp_csv}" 2>/dev/null || true
        log "DEBUG" "Master CSV also copied to: ${temp_csv}"
    fi

    /usr/sbin/chown -R "${currentUser}:staff" "${REPORT_DIR}" 2>/dev/null || true
    /usr/sbin/chown "${currentUser}:staff" "${LOG_FILE}" 2>/dev/null || true
    if [[ "${SILENT}" != "YES" ]]; then
        summary_message="✓ DRY-RUN Complete

Serials checked: ${device_count}
Report saved to Downloads"
        
        user_response=$(/usr/bin/osascript << OSASCRIPT
display dialog "${summary_message}" ¬
    buttons {"Done", "Open Report"} ¬
    default button "Done" ¬
    with title "ABM MDM Manager - DRY-RUN Complete"
    
return button returned of the result
OSASCRIPT
        )
        
        [[ "${user_response}" == "Open Report" ]] && /usr/bin/open -R "${master_csv}"
    fi
    
    log "INFO" "DRY-RUN exit!"
    exit 0
fi

# ========== END DRY-RUN HANDLER ==========

# ✅ EARLY VALIDATION: /tmp/AxM must exist (applies to all non-DRY-RUN actions)
if [[ ! -d "/tmp/AxM" ]]; then
    log "ERROR" "ABM Serials directory not found: /tmp/AxM"
    log "ERROR" "Cannot proceed without MacSerials database"
    /usr/bin/osascript -e 'display notification "ABM Serials directory missing (/tmp/AxM)" with title "ABM MDM Manager Error"'
    error_exit "ABM Serials CSV directory not found"
fi

# Read input serials
device_ids_list=""
device_count=0
while IFS= read -r serial; do
    [[ -z "${serial}" ]] && continue
    if [[ "${serial}" =~ [Ss][Ee][Rr][Ii][Aa][Ll] ]]; then
        log "DEBUG" "Skipping header row: ${serial}"
        continue
    fi
    device_ids_list="${device_ids_list}${serial}"$'\n'
    device_count=$((device_count + 1))
done < "${input_csv}"

[[ ${device_count} -eq 0 ]] && error_exit "No serials found"
log "INFO" "Found ${device_count} serial(s)"

# Get latest MacSerials for token lookup only
latest_macserials=$(find "/tmp/AxM" -maxdepth 1 -name "ALL_ABM_MacSerials_*.csv" -type f 2>/dev/null | sort -V | tail -n1)
[[ -z "${latest_macserials}" ]] && error_exit "No MacSerials database found"

log "INFO" "MacSerials: $(basename "${latest_macserials}")"

# ========== PHASE 1B: LIVE ABM LOOKUP ==========
log "INFO" "Online check of ABMs for current MDM assignments..."

> "${lookup_map}"

# Build serial→token→server→timestamp map from MacSerials
# Format: serial|token|current_server|check_timestamp
while IFS= read -r serial; do
    [[ -z "${serial}" ]] && continue
    
    token=$(awk -F',' -v s="${serial}" '{gsub(/"/, "", $1); gsub(/"/, "", $2); if ($2 == s) {print $1; exit}}' "${latest_macserials}")
    
    if [[ -z "${token}" ]]; then
        token="NOT_FOUND"
    fi
    
    if [[ "${token}" == "NOT_FOUND" ]]; then
        log "DEBUG" "Serial ${serial} not found in MacSerials"
        check_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        echo "${serial}|NOT_FOUND|NOT_FOUND|${check_ts}" >> "${lookup_map}"
        continue
    fi
    
    log "DEBUG" "Querying ABM for serial: ${serial} (token: ${token})"
    
    # Get token credential
    access_token=$("${REPO_ROOT}/ABM_tokenManager.sh" get "${token}" 2>/dev/null) || {
        log "WARN" "Failed to get token for ${serial}: ${token}"
        check_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        echo "${serial}|${token}|NOT_FOUND|${check_ts}" >> "${lookup_map}"
        continue
    }
    
    [[ -z "${access_token}" ]] && {
        log "WARN" "Empty access token for ${serial}"
        check_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        echo "${serial}|${token}|NOT_FOUND|${check_ts}" >> "${lookup_map}"
        continue
    }
    
    # ✅ Use get_assigned_server_name() instead of extraction from device endpoint
    current_server=$(get_assigned_server_name "${access_token}" "${serial}")
    
    # Capture timestamp at moment of check
    check_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    
    log "DEBUG" "Serial ${serial} → Current Server: ${current_server} (${check_ts})"
    echo "${serial}|${token}|${current_server}|${check_ts}" >> "${lookup_map}"
    
    sleep 0.2
done <<< "${device_ids_list}"

# ✅ Validate lookup_map
if [[ ! -f "${lookup_map}" ]]; then
    error_exit "lookup_map failed to create"
fi

lookup_lines=$(wc -l < "${lookup_map}" | tr -d ' ')
log "DEBUG" "Live lookup map created: ${lookup_lines} entries"

# Count found vs not found
found=$(awk -F'|' '$3 != "NOT_FOUND" && $3 != "UNASSIGNED" {count++} END {print count+0}' "${lookup_map}" 2>/dev/null || echo "0")
unassigned=$(awk -F'|' '$3 == "UNASSIGNED" {count++} END {print count+0}' "${lookup_map}" 2>/dev/null || echo "0")
not_found=$((lookup_lines - found - unassigned))

log "INFO" "Devices found (assigned): ${found}"
log "INFO" "Devices unassigned: ${unassigned}"
log "INFO" "Devices not found: ${not_found}"

# ========== PHASE 2: Group by token (with skip logic) ==========
# ✅ Build skip list FIRST (file-based for Bash 3.2 compatibility)

while IFS='|' read -r serial token current_server check_ts; do
    [[ -z "${serial}" ]] && continue
    [[ "${token}" == "NOT_FOUND" ]] && continue
    
    # ✅ SKIP IF ALREADY CORRECTLY ASSIGNED
    if [[ "${action}" == "UNASSIGN" ]]; then
        if [[ "${current_server}" == "UNASSIGNED" ]] || [[ -z "${current_server}" ]]; then
            log "DEBUG" "Skipping ${serial}: already unassigned"
            echo "${serial}|${check_ts}" >> "${skip_list_file}"
            continue
        fi
    else
        # For ASSIGN actions: skip if already assigned to target
        if [[ "${current_server}" == "${target_server}" ]]; then
            log "DEBUG" "Skipping ${serial}: already assigned to ${target_server}"
            echo "${serial}|${check_ts}" >> "${skip_list_file}"
            continue
        fi
    fi
done < "${lookup_map}"

# Group devices by token (excluding skipped serials)
group_tokens_str=""
group_devices_str=""

while IFS='|' read -r serial token current_server check_ts; do
    [[ -z "${serial}" ]] && continue
    [[ "${token}" == "NOT_FOUND" ]] && continue
    
    # Check if this serial is skipped
    if is_serial_skipped "${serial}"; then
        continue
    fi
    
    # Add to group (file-based indexed structure)
    group_tokens_str="${group_tokens_str}${token}
"
    group_devices_str="${group_devices_str}${serial}
"
done < "${lookup_map}"

# Remove duplicates from group_tokens (keep order with first occurrence)
group_tokens_unique=$(echo "${group_tokens_str}" | sort -u)

# Count skipped
skipped=$(wc -l < "${skip_list_file}" | tr -d ' ')
[[ ${skipped} -eq 0 ]] && skipped=0

log "INFO" "Devices requiring assignment: $(echo "${group_tokens_unique}" | wc -l | tr -d ' ') token(s)"
if [[ ${skipped} -gt 0 ]]; then
    log "INFO" "Devices already correctly assigned (skipped): ${skipped}"
fi

if [[ -z "${group_tokens_unique}" ]]; then
    log "INFO" "No devices require assignment changes"
fi

success_count=0
failure_count=0

# ========== PHASE 3: Token processing ==========
if [[ -n "${group_tokens_unique}" ]]; then
    log "INFO" "Starting token processing: $(echo "${group_tokens_unique}" | wc -l | tr -d ' ') token(s)"

    while IFS= read -r token; do
        [[ -z "${token}" ]] && continue
        [[ "${token}" == "NOT_FOUND" ]] && continue
        log "INFO" "Processing token: ${token}"
        
        # Get fresh token
        access_token=$("${REPO_ROOT}/ABM_tokenManager.sh" get "${token}" 2>/dev/null) || {
            log "ERROR" "Failed to get token: ${token}"
            failure_count=$((failure_count + 50))
            continue
        }
        
        [[ -z "${access_token}" ]] && { 
            log "ERROR" "Empty token"; 
            continue
        }
        
        # Fetch MDM servers
        log "DEBUG" "Token '${token}' → fetching MDM servers..."
        
        mdm_servers=$(get_mdm_servers "${access_token}")
        
        if [[ -z "${mdm_servers}" ]] || echo "${mdm_servers}" | grep -q "error"; then
            log "ERROR" "MDM servers fetch failed for token: ${token}"
            failure_count=$((failure_count + 50))
            continue
        fi
        
        server_count=$(echo "${mdm_servers}" | jq '.data | length' 2>/dev/null || echo "0")
        server_count=$(echo "${server_count}" | tr -d ' ')
        log "DEBUG" "MDM servers available: ${server_count}"
        
        # Find group devices for this token
        devices_for_token=$(awk -F'|' -v t="${token}" '$2 == t {print $1}' "${lookup_map}")
        
        [[ -z "${devices_for_token}" ]] && continue
        
        # Split into batches
        batch_num=0
        batch_devices_str=""
        
        while IFS= read -r device; do
            [[ -z "${device}" ]] && continue
            
            batch_devices_str="${batch_devices_str}${device}
"
            batch_line_count=$(echo "${batch_devices_str}" | wc -l | tr -d ' ')
            
            if [[ ${batch_line_count} -ge ${CURRENT_BATCH_SIZE} ]]; then
                batch_num=$((batch_num + 1))
                batch_devices_count=$((batch_line_count - 1))
                
                log "INFO" "  Batch ${batch_num}: ${batch_devices_count} device(s)"
                
                # Get current server for first device (for UNASSIGN logic)
                first_device=$(echo "${batch_devices_str}" | head -n1)
                current_server=$(awk -F'|' -v s="${first_device}" '$1 == s {print $3; exit}' "${lookup_map}")
                
                # Handle UNASSIGN logic
                if [[ "${action}" == "UNASSIGN" ]]; then
                    lookup_server="${current_server}"
                else
                    lookup_server="${target_server}"
                fi
                
                # Find server ID
                log "DEBUG" "Looking up server: ${lookup_server}"
                
                server_id=$(find_server_id "${mdm_servers}" "${lookup_server}")
                
                if [[ -z "${server_id}" ]]; then
                    log "ERROR" "Server ID not found for: ${lookup_server}"
                    failure_count=$((failure_count + batch_devices_count))
                    batch_devices_str=""
                    continue
                fi
                
                log "DEBUG" "Server ID: ${server_id}"
                
                # Convert batch devices string to array for post_device_activity
                batch_array_str=$(echo "${batch_devices_str}" | tr '\n' ' ')
                
                # POST activity
                log "INFO" "  Posting activity: ${activity_type} for ${batch_devices_count} device(s)"
                
                activity_result=$(post_device_activity "${access_token}" "${server_id}" "${activity_type}" ${batch_array_str})
                activity_status=$(echo "${activity_result}" | head -n1)
                
                if [[ "${activity_status}" != "OK" ]]; then
                    log "ERROR" "Activity POST failed: ${activity_status}"
                    failure_count=$((failure_count + batch_devices_count))
                    batch_devices_str=""
                    continue
                fi
                
                activity_json=$(echo "${activity_result}" | tail -n +2)
                activity_id=$(echo "${activity_json}" | /usr/bin/jq -r '.data.id // ""' 2>/dev/null)
                [[ -z "${activity_id}" ]] && { log "ERROR" "No activity ID"; batch_devices_str=""; continue; }
                
                log "INFO" "    Activity: ${activity_id}"
                
                # Polling loop
                check_count=0
                activity_completed=0
                
                while [[ ${check_count} -lt ${MAX_STATUS_CHECKS} ]]; do
                    check_count=$((check_count + 1))
                    sleep ${POLL_INTERVAL}
                    
                    log "DEBUG" "Poll check ${check_count}/${MAX_STATUS_CHECKS}..."
                    
                    status_result=$(get_activity_status "${access_token}" "${activity_id}")
                    status_code=$(echo "${status_result}" | head -n1)
                    
                    if [[ "${status_code}" != "OK" ]]; then
                        if [[ "${status_code}" == ERROR* ]] && [[ "${status_code}" == *429* ]]; then
                            log "WARN" "Rate limited during polling, backing off..."
                            sleep 20
                        fi
                        continue
                    fi
                    
                    status_json=$(echo "${status_result}" | tail -n +2)
                    cur_status=$(echo "${status_json}" | /usr/bin/jq -r '.data.attributes.status // ""' 2>/dev/null)
                    
                    if [[ "${cur_status}" == "COMPLETED" ]]; then
                        activity_completed=1
                        log "INFO" "    ✓ Completed"
                        success_count=$((success_count + batch_devices_count))
                        
                        # Capture completion timestamp for each changed device
                        completion_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
                        while IFS= read -r device; do
                            [[ -z "${device}" ]] && continue
                            echo "${device}|${completion_ts}" >> "${results_file}"
                        done <<< "${batch_devices_str}"

                        # ADAPTIVE RECOVERY
                        if [[ ${ADAPTIVE_MODE} -eq 1 ]] && [[ ${RATE_LIMIT_HIT} -eq 0 ]]; then
                            log "INFO" "System stable — easing adaptive controls"
                            CURRENT_BATCH_SIZE=$((CURRENT_BATCH_SIZE + 5))
                            [[ ${CURRENT_BATCH_SIZE} -gt ${MAX_BATCH_SIZE} ]] && CURRENT_BATCH_SIZE=${MAX_BATCH_SIZE}
                            BATCH_COOLDOWN=$((BATCH_COOLDOWN - 1))
                            [[ ${BATCH_COOLDOWN} -lt 8 ]] && BATCH_COOLDOWN=8
                        fi

                        break
                    fi
                done
                
                if [[ ${activity_completed} -eq 0 ]]; then
                    NO_PROGRESS_COUNT=$((NO_PROGRESS_COUNT + 1))
                    if [[ ${NO_PROGRESS_COUNT} -ge ${MAX_NO_PROGRESS} ]]; then
                        log "ERROR" "No progress after ${MAX_NO_PROGRESS} attempts — stopping"
                        break 2
                    fi
                    log "WARN" "    Timeout"
                    failure_count=$((failure_count + batch_devices_count))
                fi

                adaptive_throttle

                log "INFO" "  Cooling down batch..."
                sleep ${BATCH_COOLDOWN}

                [[ ${ADAPTIVE_MODE} -eq 1 ]] && log "INFO" "Adaptive mode active"
                
                batch_devices_str=""
            fi
        done <<< "${devices_for_token}"
        
        # Handle remaining batch
        if [[ -n "${batch_devices_str}" ]]; then
            batch_num=$((batch_num + 1))
            batch_line_count=$(echo "${batch_devices_str}" | wc -l | tr -d ' ')
            batch_devices_count=$((batch_line_count - 1))
            [[ ${batch_devices_count} -le 0 ]] && batch_devices_count=${batch_line_count}
            
            log "INFO" "  Batch ${batch_num}: ${batch_devices_count} device(s)"
            
            first_device=$(echo "${batch_devices_str}" | head -n1)
            current_server=$(awk -F'|' -v s="${first_device}" '$1 == s {print $3; exit}' "${lookup_map}")
            
            if [[ "${action}" == "UNASSIGN" ]]; then
                lookup_server="${current_server}"
            else
                lookup_server="${target_server}"
            fi
            
            log "DEBUG" "Looking up server: ${lookup_server}"
            server_id=$(find_server_id "${mdm_servers}" "${lookup_server}")
            
            if [[ -z "${server_id}" ]]; then
                log "ERROR" "Server ID not found for: ${lookup_server}"
                failure_count=$((failure_count + batch_devices_count))
                continue
            fi
            
            log "DEBUG" "Server ID: ${server_id}"
            log "INFO" "  Posting activity: ${activity_type} for ${batch_devices_count} device(s)"
            
            batch_array_str=$(echo "${batch_devices_str}" | tr '\n' ' ')
            activity_result=$(post_device_activity "${access_token}" "${server_id}" "${activity_type}" ${batch_array_str})
            activity_status=$(echo "${activity_result}" | head -n1)
            
            if [[ "${activity_status}" != "OK" ]]; then
                log "ERROR" "Activity POST failed: ${activity_status}"
                failure_count=$((failure_count + batch_devices_count))
                continue
            fi
            
            activity_json=$(echo "${activity_result}" | tail -n +2)
            activity_id=$(echo "${activity_json}" | /usr/bin/jq -r '.data.id // ""' 2>/dev/null)
            [[ -z "${activity_id}" ]] && { log "ERROR" "No activity ID"; continue; }
            
            log "INFO" "    Activity: ${activity_id}"
            
            check_count=0
            activity_completed=0
            
            while [[ ${check_count} -lt ${MAX_STATUS_CHECKS} ]]; do
                check_count=$((check_count + 1))
                sleep ${POLL_INTERVAL}
                
                log "DEBUG" "Poll check ${check_count}/${MAX_STATUS_CHECKS}..."
                
                status_result=$(get_activity_status "${access_token}" "${activity_id}")
                status_code=$(echo "${status_result}" | head -n1)
                
                if [[ "${status_code}" != "OK" ]]; then
                    continue
                fi
                
                status_json=$(echo "${status_result}" | tail -n +2)
                cur_status=$(echo "${status_json}" | /usr/bin/jq -r '.data.attributes.status // ""' 2>/dev/null)
                
                if [[ "${cur_status}" == "COMPLETED" ]]; then
                    activity_completed=1
                    log "INFO" "    ✓ Completed"
                    success_count=$((success_count + batch_devices_count))
                    
                    completion_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
                    while IFS= read -r device; do
                        [[ -z "${device}" ]] && continue
                        echo "${device}|${completion_ts}" >> "${results_file}"
                    done <<< "${batch_devices_str}"
                    break
                fi
            done
            
            if [[ ${activity_completed} -eq 0 ]]; then
                log "WARN" "    Timeout"
                failure_count=$((failure_count + batch_devices_count))
            fi
        fi

        log "INFO" "Cooling token ${token}..."
        sleep ${TOKEN_COOLDOWN}
    done <<< "${group_tokens_unique}"
fi

# ========== POST-ASSIGNMENT VERIFICATION ==========
if [[ "${CONFIRM_MODE}" == "YES" ]]; then
    verify_device_assignments "${action}" "${target_server}"
fi

# ========== BUILD REPORT ==========
log "INFO" "Building report..."

master_csv="${REPORT_DIR}/ABM_MDM_${actionLabel}_${DATE_TIME}.csv"
echo "TokenName,action,serial_number,current_mdm,destination_mdm,result1,result2,timestamp,destination_mdm_check,check_timestamp" > "${master_csv}"

while IFS='|' read -r serial token current_server check_ts; do
    [[ -z "${serial}" ]] && continue
    
    # Lookup timestamp from results file (for devices that were changed)
    timestamp=""
    if [[ -f "${results_file}" ]]; then
        timestamp=$(grep "^${serial}|" "${results_file}" 2>/dev/null | cut -d'|' -f2 | tail -n1) || true
    fi
    
    # If no timestamp from results (device was skipped), use PHASE 1B check_ts
    if [[ -z "${timestamp}" ]]; then
        timestamp="${check_ts}"
    fi

    # Lookup verification data
    verify_mdm=""
    verify_timestamp=""
    if [[ -f "${verify_results_file}" ]]; then
        verify_line=$(grep "^${serial}|" "${verify_results_file}" 2>/dev/null | tail -n1) || true
        if [[ -n "${verify_line}" ]]; then
            verify_mdm=$(echo "${verify_line}" | cut -d'|' -f2)
            verify_timestamp=$(echo "${verify_line}" | cut -d'|' -f3)
        fi
    fi
    
    # ✅ CLEAN NOT_FOUND REPORTING
    if [[ "${token}" == "NOT_FOUND" ]] || [[ "${current_server}" == "NOT_FOUND" ]]; then
        echo "NOT_FOUND,${action},${serial},NOT_FOUND,NOT_FOUND,NOT_FOUND,NOT_FOUND,NOT_FOUND,NOT_FOUND,NOT_FOUND" >> "${master_csv}"
    elif is_serial_skipped "${serial}"; then
        # Device was already correctly assigned (use PHASE 1B timestamp)
        skip_ts=$(get_skip_timestamp "${serial}")
        [[ -z "${skip_ts}" ]] && skip_ts="${check_ts}"
        echo "${token},${action},${serial},${current_server},${current_server},No change needed,Already assigned,${skip_ts},${current_server},${skip_ts}" >> "${master_csv}"
    else
        # Device was changed
        if [[ "${action}" == "UNASSIGN" ]]; then
            dest_mdm="UNASSIGNED"
        else
            dest_mdm="${target_server}"
        fi
        echo "${token},${action},${serial},${current_server},${dest_mdm},Activity completed,Device updated,${timestamp},${verify_mdm},${verify_timestamp}" >> "${master_csv}"
    fi
done < "${lookup_map}"

log "INFO" "Report: ${master_csv}"

if [[ "${DEBUG_MODE}" == "YES" ]]; then
    temp_csv="${temp_dir}/activity_report.csv"
    /bin/cp "${master_csv}" "${temp_csv}" 2>/dev/null || true
    log "DEBUG" "Master CSV also copied to: ${temp_csv}"
fi

/usr/sbin/chown -R "${currentUser}:staff" "${REPORT_DIR}" 2>/dev/null || true
/usr/sbin/chown "${currentUser}:staff" "${LOG_FILE}" 2>/dev/null || true

duration=$SECONDS

# Summary dialog
if [[ "${SILENT}" != "YES" ]]; then
    if [[ "${CONFIRM_MODE}" == "YES" ]]; then
        summary_message="✓ Complete + Verified

Action: ${action}
Serials: ${device_count}
Skipped: ${skipped}
Changed: ${success_count}
Failed: ${failure_count}
Time: $((${duration} / 60))m $((${duration} % 60))s

Report saved to Downloads"
    else
        summary_message="✓ Complete

Action: ${action}
Serials: ${device_count}
Skipped: ${skipped}
Changed: ${success_count}
Failed: ${failure_count}
Time: $((${duration} / 60))m $((${duration} % 60))s

Report saved to Downloads"
    fi

    user_response=$(/usr/bin/osascript << OSASCRIPT
display dialog "${summary_message}" ¬
    buttons {"Done", "Open Report"} ¬
    default button "Done" ¬
    with title "ABM MDM Manager - Complete"
    
return button returned of the result
OSASCRIPT
    )

    [[ "${user_response}" == "Open Report" ]] && /usr/bin/open -R "${master_csv}"
fi

summary_text="===== ABM MDM SUMMARY =====
Action: ${action}
Serials: ${device_count}
Skipped: ${skipped}
Changed: ${success_count}
Failed: ${failure_count}
Time: $((${duration} / 60))m $((${duration} % 60))s
CONFIRM Mode: ${CONFIRM_MODE}
SILENT Mode : ${SILENT}
============================"

echo "" >> "${LOG_FILE}"
echo "${summary_text}" >> "${LOG_FILE}"

log "INFO" "Complete!"
exit 0

