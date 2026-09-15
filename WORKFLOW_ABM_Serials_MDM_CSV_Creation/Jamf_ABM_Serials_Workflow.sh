#!/bin/bash

set -uo pipefail

# DEBUGGING
# set -x
# export PS4='+(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'

####### Description and Notes
# ABM Serials Complete Pipeline: Fetch MDM → Fetch Devices → Combine → Generate Installer → Upload to Jamf
# Modular design allows toggling each phase for testing
# Phase 1A: Fetch MDM servers automatically, auto-select latest
# Phase 1B: Fetch all devices from ABM
# Phase 1C: Combine reports
# Phase 2: Generate installer
# Phase 3: Upload to Jamf
# Phase 4: Upload to SharePoint
# Phase 5: Post to Teams
# Phase 5b: Post to Email

# 2026 09 15 MK First Public commit

####### TO-DO
# Commit publicly - DONE!

####### VARIABLES
DEBUG="NO"  # Set to YES for verbose logging and no cleanup, or NO. Needs to be set.
currentUser=$( echo "show State:/Users/ConsoleUser" | scutil | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
serialNumber=$( ioreg -rd1 -c IOPlatformExpertDevice | awk -F'"' '/IOPlatformSerialNumber/{print $4}' )
hostName=$( scutil --get ComputerName )
DATE=$(date +%Y%m%d)
LOG_STAMP=$(date +%Y%m%d-%H:%M)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOKEN_CONFIG="${REPO_ROOT}/config/token_config.env"
REPORTS_DIR="${REPO_ROOT}/REPORTS"
ABM_TEMP_DIR="/tmp/${DATE}_ABM_MAC_SERIALS"
LOG_FILE="/tmp/ABM_Pipeline_${LOG_STAMP}.log"
ADAPTIVE_DELAY="0.5"
MAX_RETRIES=5
SECONDS=0
reportEMAIL="report@example.com"
DEVICE_COUNT_THRESHOLD=128  # Minimum expected device count for validation. 
# Stops the job if the combined report has fewer devices than this threshold.
# If failure to download from all sources, so as not to replace the scripts and files.

# Webhooks
teamsNotification="https://default.XXXX_LOTS_AND_LOTS_OF_CHARACTERS"
sharepointPost="https://default.XXXX_MORE_AND_MORE_CHARACTERS"


# Jamf configuration
JAMFPREFS="$HOME/Library/Preferences/com.jss.plist"
INSTALL_SCRIPT_TEMPLATE="${SCRIPT_DIR}/Install_ABM_Serials_CSV.sh"
SCRIPT_ID="123"  # ABM_MacSerials_InstallCSV.sh 

####### EXECUTION FLAGS - TOGGLE THESE FOR TESTING
# PROD
RUN_FETCH_MDM_SERVERS="YES"       # Fetch fresh MDM servers from ABM
RUN_FETCH_DEVICES="YES"           # Fetch devices from ABM API
RUN_COMBINE_REPORTS="YES"         # Combine individual reports
RUN_GENERATE_INSTALLER="YES"      # Generate install script
RUN_UPLOAD_TO_JAMF="YES"          # Upload to Jamf
RUN_UPLOAD_TO_SHAREPOINT="YES"    # Upload Excel to SharePoint via Power Automate
RUN_POST_TO_TEAMS="YES"           # Post summary to Teams
RUN_POST_TO_EMAIL="YES"           # Post summary to Email

####### UPLOAD TRACKING FLAGS
JAMF_UPLOAD_STATUS="PENDING"
SHAREPOINT_UPLOAD_STATUS="PENDING"
CSV_LINE_COUNT=0

####### FUNCTIONS

log() {
    local level="$1"
    shift
    local timestamp
    timestamp=$(date '+%Y%m%d-%H:%M:%S')
    echo "[${timestamp}] [${level}] $*" | tee -a "${LOG_FILE}" >&2
}

debug_log() {
    [[ "${DEBUG}" == "YES" ]] && log "DEBUG" "$@"
}

error_exit() {
    log "ERROR" "$@"
    exit 1
}

version_check() {
    log "INFO" "========================================"
    log "INFO" "ABM SERIALS PIPELINE - VERSION INFO"
    log "INFO" "========================================"
    log "INFO" "Script Run Date: ${DATE}"
    log "INFO" "DEBUG Mode: ${DEBUG}"
    log "INFO" "Log File: ${LOG_FILE}"
    log "INFO" ""
    log "INFO" "EXECUTION FLAGS:"
    log "INFO" "  RUN_FETCH_MDM_SERVERS: ${RUN_FETCH_MDM_SERVERS}"
    log "INFO" "  RUN_FETCH_DEVICES: ${RUN_FETCH_DEVICES}"
    log "INFO" "  RUN_COMBINE_REPORTS: ${RUN_COMBINE_REPORTS}"
    log "INFO" "  RUN_GENERATE_INSTALLER: ${RUN_GENERATE_INSTALLER}"
    log "INFO" "  RUN_UPLOAD_TO_JAMF: ${RUN_UPLOAD_TO_JAMF}"
    log "INFO" "  RUN_UPLOAD_TO_SHAREPOINT: ${RUN_UPLOAD_TO_SHAREPOINT}"
    log "INFO" "  RUN_POST_TO_TEAMS: ${RUN_POST_TO_TEAMS}"
    log "INFO" ""
}

cleanup_temp_dir() {
    if [[ "${DEBUG}" == "YES" ]]; then
        debug_log "DEBUG mode enabled - skipping cleanup of ${ABM_TEMP_DIR}"
    else
        if [[ -d "${ABM_TEMP_DIR}" ]]; then
            log "INFO" "Cleaning up temporary directory: ${ABM_TEMP_DIR}"
            rm -rf "${ABM_TEMP_DIR}"
        fi
    fi
}

cleanup_reports() {
    if [[ "${DEBUG}" == "YES" ]]; then
        debug_log "DEBUG mode enabled - skipping cleanup of ${REPORTS_DIR}"
        return 0
    fi
    
    if [[ ! -d "${REPORTS_DIR}" ]]; then
        log "INFO" "Reports directory does not exist: ${REPORTS_DIR}"
        return 0
    fi
    
    log "INFO" "Scanning reports directory for files to clean: ${REPORTS_DIR}"
    
    local file_count=0
    local deleted_count=0
    
    # Find all MacSerials_ALL and ABM_MDMs CSV files
    while IFS= read -r file; do
        ((file_count++))
        
        # Get file modification time in seconds
        local mod_time
        mod_time=$(stat -f "%m" "$file" 2>/dev/null)
        
        # Calculate age in days
        local current_time age_days
        current_time=$(date +%s)
        age_days=$(( (current_time - mod_time) / 86400 ))
        
        local filename
        filename=$(basename "$file")
        
        if (( age_days > 5 )); then
            log "INFO" "Deleting [${age_days} days old]: ${filename}"
            rm -f "$file"
            ((deleted_count++))
        else
            log "INFO" "Keeping [${age_days} days old]: ${filename}"
        fi
        
    done < <(find "${REPORTS_DIR}" -maxdepth 1 -type f \( -name "MacSerials_ALL_*.csv" -o -name "ABM_MDMs_*.csv" \) 2>/dev/null)
    
    log "INFO" "Cleanup complete - found ${file_count} reports, deleted ${deleted_count}"
}

####### PHASE 1A: FETCH MDM SERVERS

sanity_check_prerequisites() {
    log "INFO" "Running sanity checks..."
    
    if [[ ! -f "${REPO_ROOT}/ABM_tokenManager.sh" ]]; then
        error_exit "ABM_tokenManager.sh not found in ${SCRIPT_DIR}"
    fi

    if [[ ! -f "${TOKEN_CONFIG}" ]]; then
        error_exit "Token config file not found: ${TOKEN_CONFIG}"
    fi

    if [[ ! -f "${JAMFPREFS}" ]]; then
        error_exit "Jamf Creds file not found: ${JAMFPREFS}"
    fi

    mkdir -p "${REPORTS_DIR}"
    mkdir -p "${ABM_TEMP_DIR}"
    
    log "INFO" "All prerequisites OK"
}

call_abm_api() {
    local access_token="$1"
    local method="${2:-GET}"
    local endpoint="$3"
    
    if [[ -z "${access_token}" ]] || [[ -z "${endpoint}" ]]; then
        echo "ERROR: Usage: call_abm_api <access_token> [method] <endpoint>" >&2
        return 1
    fi
    
    curl -s -k -w "\n%{http_code}" \
        -X "${method}" \
        -H "Authorization: Bearer ${access_token}" \
        -H "Accept: application/json" \
        "https://api-business.apple.com${endpoint}"
}

fetch_mdm_servers_job() {
    log "INFO" "========================================"
    log "INFO" "PHASE 1A: FETCH MDM SERVERS FROM ABM"
    log "INFO" "========================================"
    
    local report="${REPORTS_DIR}/ABM_MDMs_${DATE}.csv"
    
    log "INFO" "Fetching MDM servers from all ABM tokens..."
    
    # Initialize report with headers
    echo "TokenName,ServerName,Type,ID" > "${report}"
    
    # Process each token on-demand (no pre-caching)
    while IFS='|' read -r token_name pem_path client_id key_id; do
        # Skip comments and empty lines
        [[ "${token_name}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${token_name}" ]] && continue
        
        token_name=$(echo "${token_name}" | xargs)
        
        log "INFO" "Fetching MDM servers for token: ${token_name}"
        
        # FETCH TOKEN JUST-IN-TIME
        debug_log "Getting fresh token for: ${token_name}"
        
        stderr_file=$(mktemp /tmp/token_stderr.XXXXXX)
        trap "rm -f ${stderr_file}" RETURN
        
        access_token=$("${REPO_ROOT}/ABM_tokenManager.sh" get "${token_name}" 2>"${stderr_file}") || {
            log "ERROR" "Failed to get token for ${token_name}"
            cat "${stderr_file}" >&2
            rm -f "${stderr_file}"
            continue
        }
        
        rm -f "${stderr_file}"
        
        [[ -z "${access_token}" ]] && { log "ERROR" "Empty token for ${token_name}"; continue; }
        
        # Use token immediately
        response=$(call_abm_api "${access_token}" GET "/v1/mdmServers?limit=1000")
        http_code=$(echo "${response}" | sed -n '$p')
        body=$(echo "${response}" | sed '$d')
        
        if [[ "${http_code}" != "200" ]]; then
            log "WARN" "HTTP ${http_code} for token ${token_name}"
            continue
        fi
        
        if ! echo "${body}" | jq empty 2>/dev/null; then
            log "WARN" "Invalid JSON response for token ${token_name}"
            continue
        fi
        
        # Extract MDM servers
        data_count=$(echo "${body}" | jq '.data | length' 2>/dev/null || echo "0")
        
        if [[ "${data_count}" -gt 0 ]]; then
            echo "${body}" | jq -r \
                --arg token "${token_name}" \
                '.data[] | [$token, .attributes.serverName, .type, .id] | @csv' \
                >> "${report}"
            
            log "INFO" "  Found ${data_count} MDM servers"
        fi
        
        # Token automatically expires after use (no caching needed)
        
    done < "${TOKEN_CONFIG}"
    
    local line_count
    line_count=$(wc -l < "${report}")
    
    log "INFO" "MDM servers report created: ${report##*/}"
    log "INFO" "  Total MDM servers: $((line_count - 1))"
}

####### PHASE 1B: FETCH DEVICES

select_csv_file() {
    log "INFO" "Looking for latest MDM CSV file in ${REPORTS_DIR}..."
    
    local latest_csv
    latest_csv=$(find "${REPORTS_DIR}" -maxdepth 1 -name "ABM_MDMs_*" -type f 2>/dev/null | sort -r | head -1)
    
    if [[ -z "${latest_csv}" ]]; then
        error_exit "No ABM_MDMs_*.csv files found in ${REPORTS_DIR}"
    fi
    
    log "INFO" "Auto-selecting latest MDM file:"
    log "INFO" "  File: ${latest_csv##*/}"
    
    echo "${latest_csv}"
}

fetch_paginated() {
    local access_token="$1"
    local endpoint="$2"
    local output_file="$3"
    local parse_jq="$4"
    local description="$5"
    local token_name="${6:-unknown}"  # NEW: token name for refresh
    
    local cursor=""
    local page_count=0
    local total_records=0
    local current_delay="${ADAPTIVE_DELAY}"
    local rate_limit_hits=0
    
    debug_log "Fetching ${description}..."
    
    while true; do
        page_count=$((page_count+1))
        
        local cursor_param=""
        [[ -n "${cursor}" ]] && cursor_param="&cursor=${cursor}"
        
        local retry_count=0
        local response=""
        local http_code=""
        local body=""
        
        while [[ ${retry_count} -lt ${MAX_RETRIES} ]]; do
            response=$(call_abm_api "${access_token}" GET "${endpoint}${cursor_param}")
            
            http_code=$(echo "${response}" | sed -n '$p')
            body=$(echo "${response}" | sed '$d')
            
            # TOKEN EXPIRED - REFRESH AND RETRY
            if [[ "${http_code}" == "401" ]]; then
                log "WARN" "Token expired (401). Refreshing token for ${token_name}..."
                
                stderr_file=$(mktemp /tmp/token_refresh_stderr.XXXXXX)
                trap "rm -f ${stderr_file}" RETURN
                
                access_token=$("${REPO_ROOT}/ABM_tokenManager.sh" get "${token_name}" 2>"${stderr_file}") || {
                    log "ERROR" "Failed to refresh token for ${token_name}"
                    cat "${stderr_file}" >&2
                    rm -f "${stderr_file}"
                    return 1
                }
                
                rm -f "${stderr_file}"
                
                if [[ -z "${access_token}" ]]; then
                    log "ERROR" "Empty token after refresh for ${token_name}"
                    return 1
                fi
                
                log "INFO" "Token refreshed successfully. Retrying..."
                retry_count=$((retry_count+1))
                sleep 2
                continue
            fi
            
            if [[ "${http_code}" == "429" ]]; then
                retry_count=$((retry_count+1))
                rate_limit_hits=$((rate_limit_hits+1))
                
                local wait_time=$((2 ** retry_count))
                log "WARN" "Rate limited (429). Waiting ${wait_time}s before retry $((retry_count+1))/${MAX_RETRIES}..."
                sleep ${wait_time}
                current_delay=$(echo "${current_delay} * 1.5" | bc 2>/dev/null || echo "${current_delay}")
                continue
            fi
            
            if [[ "${http_code}" == "403" ]]; then
                retry_count=$((retry_count+1))
                if [[ ${retry_count} -lt 2 ]]; then
                    log "WARN" "Access forbidden (403). Waiting 30s before single retry..."
                    sleep 30
                    continue
                else
                    log "ERROR" "Access forbidden (403) - token lacks API permissions"
                    return 1
                fi
            fi
            
            if [[ "${http_code}" != "200" ]]; then
                log "ERROR" "HTTP ${http_code} - ${description} page ${page_count}"
                retry_count=$((retry_count+1))
                
                if [[ ${retry_count} -lt ${MAX_RETRIES} ]]; then
                    sleep 2
                    continue
                else
                    return 1
                fi
            fi
            
            break
        done
        
        if [[ ${retry_count} -ge ${MAX_RETRIES} ]] && [[ "${http_code}" != "200" ]]; then
            log "ERROR" "Max retries exceeded (HTTP ${http_code})"
            return 1
        fi
        
        if ! echo "${body}" | jq empty 2>/dev/null; then
            log "ERROR" "Invalid JSON response"
            return 1
        fi
        
        local records_on_page
        records_on_page=$(echo "${body}" | jq '.data | length')
        
        if [[ "${records_on_page}" -gt 0 ]]; then
            echo "${body}" | jq -r "${parse_jq}" >> "${output_file}"
            total_records=$((total_records + records_on_page))
        fi
        
        cursor=$(echo "${body}" | jq -r '.meta.paging.nextCursor // empty')
        
        if [[ -z "${cursor}" ]]; then
            debug_log "${description}: ${total_records} records"
            break
        fi
        
        sleep $(echo "scale=2; ${current_delay}" | bc 2>/dev/null || echo "${current_delay}")
        current_delay=$(echo "${current_delay} * 0.98" | bc 2>/dev/null || echo "${current_delay}")
        
        if (( $(echo "${current_delay} < 0.1" | bc -l 2>/dev/null || echo 0) )); then
            current_delay="0.1"
        fi
    done
    
    [[ ${rate_limit_hits} -gt 0 ]] && log "WARN" "Rate limit hits: ${rate_limit_hits}"
    
    return 0
}

fetch_all_devices_for_token() {
    local access_token="$1"
    local token_name="$2"
    
    local report="${ABM_TEMP_DIR}/MacSerials_${token_name}_${DATE}.csv"
    local all_devices_file="/tmp/all_devices_${token_name}.txt"
    local mdm_devices_file="/tmp/mdm_devices_${token_name}.txt"
    
    rm -f "${all_devices_file}" "${mdm_devices_file}"
    
    log "INFO" "Fetching ALL devices for token: ${token_name}"
    
    # Fetch all org devices (just getting serial and status)
    fetch_paginated "${access_token}" \
        '/v1/orgDevices?limit=1000' \
        "${all_devices_file}" \
        '.data[] | select(.attributes.productFamily == "Mac") | "\(.attributes.serialNumber)|\(.attributes.status)"' \
        'orgDevices (Mac serials)' "${token_name}" || {
        log "ERROR" "Failed to fetch orgDevices"
        return 1
    }
    
    if [[ ! -f "${all_devices_file}" ]] || [[ ! -s "${all_devices_file}" ]]; then
        log "WARN" "No Mac devices found in orgDevices"
        touch "${report}"
        return 0
    fi
    
    # Find the MDM servers CSV file path to use as the lookup table.
    local mdm_csv="${REPORTS_DIR}/ABM_MDMs_${DATE}.csv"
    if [[ ! -f "${mdm_csv}" ]]; then
        mdm_csv=$(find "${REPORTS_DIR}" -maxdepth 1 -name "ABM_MDMs_*" -type f 2>/dev/null | sort -r | head -1)
    fi

    if [[ -z "${mdm_csv}" ]] || [[ ! -f "${mdm_csv}" ]]; then
        log "ERROR" "MDM servers CSV not found for local lookup. Cannot map server names."
        return 1
    fi

    # Fetch device assignments for each MDM server in this token
    log "INFO" "Fetching device assignments from MDM servers..."
    
    # We only want to fetch MDM servers that belong to THIS token
    local mdm_servers_temp="/tmp/mdm_servers_${token_name}.txt"
    awk -F',' -v token="${token_name}" 'NR>1 { if ($1 == "\"" token "\"") print $4 "|" $2 }' "${mdm_csv}" | tr -d '"' > "${mdm_servers_temp}"
    
    while IFS='|' read -r mdm_id mdm_name; do
        [[ -z "${mdm_id}" ]] && continue
        
        log "INFO" "  Fetching assigned devices from MDM: ${mdm_name}"
        
        local mdm_specific_file="/tmp/mdm_specific_${token_name}_${mdm_id}.txt"
        local safe_mdm_name="${mdm_name//\"/\\\"}"
        
        fetch_paginated "${access_token}" \
            "/v1/mdmServers/${mdm_id}/relationships/devices?limit=1000" \
            "${mdm_specific_file}" \
            ".data[] | \"\(.id)|${safe_mdm_name}\"" \
            "MDM ${mdm_name} devices" "${token_name}"
            
        if [[ -f "${mdm_specific_file}" ]]; then
            cat "${mdm_specific_file}" >> "${mdm_devices_file}"
            rm -f "${mdm_specific_file}"
        fi
        
    done < "${mdm_servers_temp}"
    
    rm -f "${mdm_servers_temp}"
    
    log "INFO" "Processing $(wc -l < "${all_devices_file}" | tr -d ' ') device records locally..."
    
    # Initialize report
    {
        echo "TokenName,DeviceID,Status,${LOG_STAMP}"
    } > "${report}"
    
    touch "${mdm_devices_file}" # Ensure it exists even if no MDM has devices

    # Use awk to join the devices with the MDM server names
    awk -F'|' -v token="${token_name}" '
        BEGIN { OFS="," }
        # Pass 1: Read MDM assignments (serial -> mdm name)
        NR==FNR {
            mdm_map[$1] = $2
            next
        }
        # Pass 2: Read all devices
        {
            serial=$1
            status=$2
            
            if (serial in mdm_map) {
                server_name = mdm_map[serial]
            } else if (status == "UNASSIGNED") {
                server_name = "UNASSIGNED"
            } else {
                server_name = "UNKNOWN_SERVER"
            }
            
            print "\"" token "\"", "\"" serial "\"", "\"" server_name "\""
        }
    ' "${mdm_devices_file}" "${all_devices_file}" >> "${report}"
    
    local total_lines
    total_lines=$(tail -n +2 "${report}" 2>/dev/null | wc -l | tr -d ' ')
    total_lines=${total_lines:-0}
    
    local unassigned_count
    unassigned_count=$(grep -c '"UNASSIGNED"' "${report}" 2>/dev/null || true)
    unassigned_count=${unassigned_count:-0}
    
    local assigned_count=$((total_lines - unassigned_count))
    
    log "INFO" "Report saved: ${report##*/}"
    log "INFO" "  Total devices: ${total_lines} | Assigned: ${assigned_count} | Unassigned: ${unassigned_count}"
    
    rm -f "${all_devices_file}" "${mdm_devices_file}"
}

fetch_devices_job() {
    log "INFO" "========================================"
    log "INFO" "PHASE 1B: ABM DEVICE FETCH"
    log "INFO" "========================================"
    
    input_csv=$(select_csv_file)
    log "INFO" "Processing: ${input_csv##*/}"
    
    if ! head -1 "${input_csv}" | grep -q "TokenName"; then
        error_exit "CSV file does not have expected format (missing TokenName header)"
    fi
    
    # Extract unique tokens from MDM list
    declare -a unique_tokens
    
    while IFS=',' read -r token_name server_name mdm_type mdm_id; do
        [[ "${token_name}" == "TokenName" ]] && continue
        
        token_name=$(echo "${token_name}" | tr -d '"')
        
        # Check if token already processed
        token_found=0
        for processed in "${unique_tokens[@]:-}"; do
            if [[ "${processed}" == "${token_name}" ]]; then
                token_found=1
                break
            fi
        done
        
        if [[ ${token_found} -eq 0 ]]; then
            unique_tokens+=("${token_name}")
        fi
    done < "${input_csv}"
    
    log "INFO" "Processing ${#unique_tokens[@]} unique tokens..."
    
    # FETCH EACH TOKEN ON-DEMAND (just before use)
    for token_name in "${unique_tokens[@]}"; do
        log "INFO" "Fetching devices for token: ${token_name}"
        
        # FETCH TOKEN JUST-IN-TIME
        debug_log "Getting fresh token for: ${token_name}"
        
        stderr_file=$(mktemp /tmp/token_stderr.XXXXXX)
        trap "rm -f ${stderr_file}" RETURN
        
        access_token=$("${REPO_ROOT}/ABM_tokenManager.sh" get "${token_name}" 2>"${stderr_file}") || {
            log "ERROR" "Failed to get token for ${token_name}"
            cat "${stderr_file}" >&2
            rm -f "${stderr_file}"
            continue
        }
        
        rm -f "${stderr_file}"
        
        [[ -z "${access_token}" ]] && { log "ERROR" "Empty token for ${token_name}"; continue; }
        
        # Use token immediately for this token's devices
        fetch_all_devices_for_token "${access_token}" "${token_name}" || {
            log "ERROR" "Failed to fetch devices for ${token_name}"
            continue
        }
        
        # Token automatically expires (no caching)
    done
    
    log "INFO" "All individual token reports complete!"
}

####### PHASE 1C: COMBINE REPORTS

combine_token_reports_job() {
    log "INFO" "========================================"
    log "INFO" "PHASE 1C: COMBINE REPORTS"
    log "INFO" "========================================"
    
    local combined_report="${REPORTS_DIR}/MacSerials_ALL_${DATE}.csv"
    local first_file=true
    
    log "INFO" "Combining individual token reports..."
    
    > "${combined_report}"
    
    while IFS= read -r csv_file; do
        if [[ "${first_file}" == true ]]; then
            cat "${csv_file}" >> "${combined_report}"
            first_file=false
        else
            tail -n +2 "${csv_file}" >> "${combined_report}"
        fi
    done < <(find "${ABM_TEMP_DIR}" -maxdepth 1 -name "MacSerials_*_${DATE}.csv" -type f 2>/dev/null | grep -v "_ALL_" | sort)
    
    if [[ -f "${combined_report}" ]] && [[ -s "${combined_report}" ]]; then
        local total_lines
        total_lines=$(tail -n +2 "${combined_report}" | wc -l)
        CSV_LINE_COUNT=${total_lines}

    if [[ -f "${combined_report}" ]] && [[ -s "${combined_report}" ]]; then
        local total_lines
        total_lines=$(tail -n +2 "${combined_report}" | wc -l)
        CSV_LINE_COUNT=${total_lines}
        log "INFO" "Combined report created: ${combined_report##*/}"
        log "INFO" "Total devices across all tokens: ${total_lines}"
        
        # DEVICE COUNT VALIDATION
        if [[ ${total_lines} -lt ${DEVICE_COUNT_THRESHOLD} ]]; then
            log "ERROR" "❌ DEVICE COUNT BELOW THRESHOLD: ${total_lines} (expected >= ${DEVICE_COUNT_THRESHOLD})"
            log "ERROR" "This indicates missing devices from ABM. Investigation required."
            error_exit "Pipeline halted: Insufficient device count"
        fi
        log "INFO" "✓ Device count validation passed (${total_lines} >= ${DEVICE_COUNT_THRESHOLD})"
        
    else
        log "WARN" "Combined report is empty"
    fi

        log "INFO" "Combined report created: ${combined_report##*/}"
        log "INFO" "Total devices across all tokens: ${total_lines}"
    else
        log "WARN" "Combined report is empty"
    fi
    
    # Generate summary
    declare -a success_tokens=()
    declare -a empty_tokens=()
    declare -a failed_tokens=()
    
    total_devices=0
    total_assigned=0
    total_unassigned=0
    
    for report in "${ABM_TEMP_DIR}"/MacSerials_*_${DATE}.csv; do
        [[ ! -f "${report}" ]] && continue
        [[ "${report}" =~ _ALL_ ]] && continue
        
        token_name=$(basename "${report}" | sed "s/MacSerials_//;s/_${DATE}.csv//")
        
        total=$(tail -n +2 "${report}" 2>/dev/null | wc -l)
        total=${total:-0}
        unassigned=$(tail -n +2 "${report}" 2>/dev/null | grep -c '"UNASSIGNED"' 2>/dev/null || true)
        unassigned=${unassigned:-0}
        assigned=$((total - unassigned))
        
        if [[ ${total} -gt 0 ]]; then
            success_tokens+=("${token_name}|${total}|${assigned}|${unassigned}")
            total_devices=$((total_devices + total))
            total_assigned=$((total_assigned + assigned))
            total_unassigned=$((total_unassigned + unassigned))
        else
            empty_tokens+=("${token_name}")
        fi
    done
    
    success_count=${#success_tokens[@]:-0}
    empty_count=${#empty_tokens[@]:-0}
    failed_count=${#failed_tokens[@]:-0}
    
    {
        echo ""
        echo "==============================================="
        echo "ABM DEVICE SUMMARY REPORT - ${DATE}"
        echo "==============================================="
        echo ""
        
        echo "✓ SUCCESSFUL DOWNLOADS (${success_count} tokens)"
        echo "-------------------------------------------"
        printf "%-30s | %8s | %8s | %10s\n" "TokenName" "Total" "Assigned" "Unassigned"
        echo "-------------------------------------------"
        
        for entry in "${success_tokens[@]:-}"; do
            IFS='|' read -r token total assigned unassigned <<< "${entry}"
            printf "%-30s | %8d | %8d | %10d\n" "${token}" "${total}" "${assigned}" "${unassigned}"
        done
        
        echo ""
        echo "SUCCESS TOTALS:"
        echo "  Total Devices: ${total_devices}"
        echo "  Assigned to MDM: ${total_assigned}"
        echo "  Unassigned: ${total_unassigned}"
        echo ""
        
        if [[ ${empty_count} -gt 0 ]]; then
            echo "⊘ EMPTY (${empty_count} tokens - no devices found)"
            echo "-------------------------------------------"
            for token in "${empty_tokens[@]:-}"; do
                echo "  • ${token}"
            done
            echo ""
        fi
        
        echo "==============================================="
        echo "GRAND TOTALS"
        echo "==============================================="
        total_processed=$((success_count + empty_count + failed_count))
        echo "Total Tokens Processed: ${total_processed}"
        echo "  ✓ Successful: ${success_count}"
        echo "  ⊘ Empty: ${empty_count}"
        echo "  ✗ Failed: ${failed_count}"
        echo ""
        echo "Total Devices Across All Tokens: ${total_devices}"
        echo "  Assigned to MDM: ${total_assigned}"
        echo "  Unassigned: ${total_unassigned}"
        echo ""
        
    } | tee -a "${LOG_FILE}"
}

####### PHASE 2: GENERATE INSTALLER SCRIPT

validate_csv_file() {
    local csv_pattern="${REPORTS_DIR}/MacSerials_ALL_${DATE}.csv"
    
    log "INFO" "Validating CSV file: MacSerials_ALL_${DATE}.csv"
    
    if [[ ! -f "${csv_pattern}" ]]; then
        log "ERROR" "Expected file not found: ${csv_pattern}"
        log "ERROR" "Available files in ${REPORTS_DIR}:"
        ls -lh "${REPORTS_DIR}"/MacSerials_ALL_*.csv 2>/dev/null || log "ERROR" "No MacSerials_ALL_*.csv files found"
        error_exit "Cannot proceed without MacSerials_ALL_${DATE}.csv"
    fi
    
    local file_version=$(basename "${csv_pattern}" | sed 's/MacSerials_ALL_//;s/.csv//')
    
    if [[ "${file_version}" != "${DATE}" ]]; then
        error_exit "Version mismatch! File version: ${file_version}, Script run date: ${DATE}"
    fi
    
    local line_count
    line_count=$(wc -l < "${csv_pattern}")
    
    if [[ ${line_count} -lt 2 ]]; then
        error_exit "CSV file is empty or has no data: ${csv_pattern}"
    fi
    
    debug_log "CSV validation passed: ${csv_pattern##*/} (${line_count} lines, version ${file_version})"
    
    echo "${csv_pattern}"
}

generate_install_script() {
    log "INFO" "========================================"
    log "INFO" "PHASE 2: GENERATE INSTALLER SCRIPT"
    log "INFO" "========================================"
    
    local csv_file
    csv_file=$(validate_csv_file)
    
    local csv_version
    csv_version=$(basename "${csv_file}" | sed 's/MacSerials_ALL_//;s/.csv//')
    
    log "INFO" "Generating: ${INSTALL_SCRIPT_TEMPLATE}"
    log "INFO" "CSV Version: ${csv_version}"
    
    # Create the install script with embedded CSV
    cat > "${INSTALL_SCRIPT_TEMPLATE}" << 'INSTALL_HEADER'
#!/bin/bash

# ABM Serials Install Script (for Jamf Self Service)
# Installs CSV to /tmp/AxM/ for current user
# Auto-generated installer

INSTALL_HEADER

    # Add version info as variables in the script
    cat >> "${INSTALL_SCRIPT_TEMPLATE}" << INSTALL_VARS
VERSION="${LOG_STAMP}"
CSV_DIR="/tmp/AxM"
CSV_FILE="\${CSV_DIR}/ALL_ABM_MacSerials_${csv_version}.csv"
LOGGED_IN_USER=\$(/bin/ls -la /dev/console | /usr/bin/awk '{ print \$3 }')

INSTALL_VARS

    # Add function body
    cat >> "${INSTALL_SCRIPT_TEMPLATE}" << 'INSTALL_BODY'

# Create directory if it doesn't exist
if [[ ! -d "${CSV_DIR}" ]]; then
    mkdir -p "${CSV_DIR}"
fi

# Remove existing CSV with same date if it exists
if [[ -f "${CSV_FILE}" ]]; then
    rm "${CSV_FILE}"
fi

# Write CSV data to file
cat > "${CSV_FILE}" << 'CSVDATA'
INSTALL_BODY

    # Append the actual CSV data
    cat "${csv_file}" >> "${INSTALL_SCRIPT_TEMPLATE}"

    # Close the heredoc and add final commands
    cat >> "${INSTALL_SCRIPT_TEMPLATE}" << 'INSTALL_FOOTER'
CSVDATA

# Set ownership to logged-in user
chown "${LOGGED_IN_USER}" "${CSV_FILE}"
chmod 644 "${CSV_FILE}"

echo "SUCCESS: CSV version ${VERSION} installed to ${CSV_FILE}"
exit 0
INSTALL_FOOTER

    # Make executable
    chmod +x "${INSTALL_SCRIPT_TEMPLATE}"
    
    # Get size
    local script_size
    script_size=$(du -h "${INSTALL_SCRIPT_TEMPLATE}" | awk '{print $1}')
    
    # Verify VERSION in script
    local script_version
    script_version=$(grep '^VERSION=' "${INSTALL_SCRIPT_TEMPLATE}" | head -1 | cut -d'"' -f2)

    debug_log "Embedded VERSION in script: ${script_version}"

    # Compare date portion only (first 8 chars: YYYYMMDD)
    local script_version_date="${script_version:0:8}"

    if [[ "${script_version_date}" != "${csv_version}" ]]; then
        error_exit "Version mismatch in install script! Expected date: ${csv_version}, Found date: ${script_version_date} (full: ${script_version})"
    fi
    
    log "INFO" "Install script generated successfully"
    log "INFO" "  File: ${INSTALL_SCRIPT_TEMPLATE}"
    log "INFO" "  Size: ${script_size}"
    log "INFO" "  VERSION: ${script_version}"
    log "INFO" "  Executable: Yes"
}

####### PHASE 3: UPLOAD TO JAMF

sanity_check_jamf() {
    log "INFO" "Checking Jamf prerequisites..."
    
    if [[ ! -f "${JAMFPREFS}" ]]; then
        error_exit "Jamf credentials not found: ${JAMFPREFS}"
    fi
    
    # Read Jamf credentials
    jssURL=$(defaults read "${JAMFPREFS}" jssURL 2>/dev/null) || error_exit "jssURL not found in ${JAMFPREFS}"
    apiUser=$(defaults read "${JAMFPREFS}" jssUSER 2>/dev/null) || error_exit "jssUSER not found in ${JAMFPREFS}"
    apiPass=$(defaults read "${JAMFPREFS}" jssPASSWORD 2>/dev/null) || error_exit "jssPASSWORD not found in ${JAMFPREFS}"
    
    log "INFO" "Jamf Server: ${jssURL}"
    log "INFO" "Jamf User: ${apiUser}"
    
    # Check required binaries
    requiredBinaries=("jq" "curl")
    for binary in "${requiredBinaries[@]}"; do
        if ! command -v "$binary" > /dev/null; then
            error_exit "$binary is not installed"
        fi
    done
    
    debug_log "All required binaries present"
}

request_jamf_token() {
    debug_log "Requesting Jamf API token..."
    
    authToken=$(curl -s -X POST "${jssURL}/api/v1/auth/token" -u "${apiUser}:${apiPass}") || error_exit "Failed to authenticate with Jamf"
    
    jamfToken=$(echo "${authToken}" | jq -r '.token // empty') || error_exit "Failed to parse Jamf token"
    
    if [[ -z "${jamfToken}" ]]; then
        error_exit "Empty Jamf token received"
    fi
    
    debug_log "Jamf token obtained (${jamfToken:0:10}...)"
}

upload_script_to_jamf() {
    log "INFO" "========================================"
    log "INFO" "PHASE 3: UPLOAD TO JAMF (Pro API)"
    log "INFO" "========================================"
    
    if [[ ! -f "${INSTALL_SCRIPT_TEMPLATE}" ]]; then
        error_exit "Install script not found: ${INSTALL_SCRIPT_TEMPLATE}"
    fi
    
    sanity_check_jamf
    request_jamf_token
    
    # Extract script version
    local script_version
    script_version=$(grep '^VERSION=' "${INSTALL_SCRIPT_TEMPLATE}" | head -1 | cut -d'"' -f2)
    
    log "INFO" "Uploading Install_ABM_Serials.sh (version ${script_version})"
    log "INFO" "Script ID: ${SCRIPT_ID}"
    
    # Create temp file for JSON payload
    local json_temp
    json_temp=$(mktemp /tmp/jamf_script_payload.XXXXXX)
    trap "rm -f ${json_temp}" RETURN
    
    # Build JSON payload using jq -Rs (reads file as raw string, no arg length limit)
    jq -Rs \
        '{
            name: "ABM_Install_Serials_CSV.sh",
            scriptContents: .
        }' "${INSTALL_SCRIPT_TEMPLATE}" > "${json_temp}"
    
    debug_log "JSON payload created from file"
    debug_log "JSON file size: $(du -h ${json_temp} | awk '{print $1}')"
    
    # Validate JSON
    if ! jq empty "${json_temp}" 2>/dev/null; then
        error_exit "Invalid JSON payload"
    fi
    
    debug_log "JSON validation passed"
    
    # Upload to Jamf Pro API using file-based payload
    log "INFO" "Uploading to Jamf..."
    
    local curl_output http_code
    curl_output=$(curl -s -w "\n%{http_code}" -X PUT "${jssURL}/api/v1/scripts/${SCRIPT_ID}" \
        -H "Authorization: Bearer ${jamfToken}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d @"${json_temp}" 2>&1)
    
    # Parse response safely
    http_code=$(echo "${curl_output}" | tail -n 1)
    local body=$(echo "${curl_output}" | sed '$d')
    
    debug_log "HTTP Code: ${http_code}"
    
    # Invalidate token
    curl -s -X POST "${jssURL}/api/v1/auth/invalidate-token" -H "Authorization: Bearer ${jamfToken}" > /dev/null
    debug_log "Jamf token invalidated"
    
    # Check for success and set flag
    if [[ "${http_code}" =~ ^20[01]$ ]]; then
        log "INFO" "✓ Script uploaded successfully to Jamf"
        log "INFO" "  HTTP Code: ${http_code}"
        log "INFO" "  Script ID: ${SCRIPT_ID}"
        log "INFO" "  Version: ${script_version}"
        JAMF_UPLOAD_STATUS="SUCCESS"
    else
        log "ERROR" "Upload failed"
        log "ERROR" "  HTTP Code: ${http_code}"
        debug_log "Response: ${body}"
        JAMF_UPLOAD_STATUS="FAILED"
        error_exit "Failed to upload to Jamf (HTTP ${http_code})"
    fi
}

####### PHASE 4: UPLOAD TO SHAREPOINT

# Helper function to upload to a single endpoint
upload_to_endpoint() {
    local flow_url="$1"
    local file_to_upload="$2"
    local endpoint_name="$3"
    
    log "INFO" "Uploading to ${endpoint_name}..."
    
    # Base64 encode the file
    local file_base64
    file_base64=$(base64 -i "${file_to_upload}") || return 1
    
    # Create temp file for JSON payload
    local payload_temp
    payload_temp=$(mktemp /tmp/sp_payload.XXXXXX)
    trap "rm -f ${payload_temp}" RETURN
    
    # Write JSON to temp file
    cat > "${payload_temp}" <<EOF
{
  "fileName": "ALL_ABM_MacSerials.xlsx",
  "fileContent": "${file_base64}"
}
EOF
    
    # Send POST request
    local curl_output http_code body
    curl_output=$(curl -s -w "\n%{http_code}" -X POST "${flow_url}" \
        -H "Content-Type: application/json" \
        -d @"${payload_temp}")
    
    http_code=$(echo "${curl_output}" | tail -n 1)
    body=$(echo "${curl_output}" | sed '$d')
    
    # ALWAYS log response body for debugging
    debug_log "${endpoint_name} Response Body: ${body}"
    
    # Check result
    if [[ "${http_code}" =~ ^20[0-9]$ ]]; then
        log "INFO" "✓ ${endpoint_name} upload accepted (HTTP ${http_code})"
        debug_log "${endpoint_name} Full Response: ${body}"
        return 0
    else
        log "ERROR" "${endpoint_name} upload failed (HTTP ${http_code})"
        debug_log "Response: ${body}"
        return 1
    fi
}

upload_to_sharepoint_job() {
    log "INFO" "========================================"
    log "INFO" "PHASE 4: UPLOAD TO SHAREPOINT"
    log "INFO" "========================================"
    
    local FLOW_URL_1="$sharepointPost"
    local INPUT_CSV="${REPORTS_DIR}/MacSerials_ALL_${DATE}.csv"
    local OUTPUT_EXCEL="/tmp/ALL_ABM_MacSerials_${DATE}.xlsx"
    
    # Validate input CSV exists
    if [[ ! -f "${INPUT_CSV}" ]]; then
        error_exit "Input CSV not found: ${INPUT_CSV}"
    fi
    
    log "INFO" "Input CSV: ${INPUT_CSV##*/}"
    
    log "INFO" "Checking openpyxl..."
    if ! python3 -c "import openpyxl" 2>/dev/null; then
        log "INFO" "Installing openpyxl..."
        python3 -m pip install --break-system-packages openpyxl -q || {
            error_exit "Failed to install openpyxl. Run: python3 -m pip install --break-system-packages openpyxl"
        }
    else
        log "INFO" "✓ openpyxl already installed"
    fi

    # Convert CSV to Excel
    log "INFO" "Converting CSV to Excel: ALL_ABM_MacSerials_${DATE}.xlsx"
    
    python3 << PYTHON_CONVERT
import csv
from openpyxl import Workbook
import sys

try:
    wb = Workbook()
    ws = wb.active
    
    with open("${INPUT_CSV}", newline="", encoding="utf-8") as f:
        for row in csv.reader(f):
            ws.append([cell.strip() for cell in row])
    
    wb.save("${OUTPUT_EXCEL}")
    print(f"SUCCESS: Excel file created: ${OUTPUT_EXCEL}")
    
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON_CONVERT
    
    if [[ $? -ne 0 ]]; then
        error_exit "Failed to convert CSV to Excel"
    fi
    
    if [[ ! -f "${OUTPUT_EXCEL}" ]]; then
        error_exit "Excel file was not created: ${OUTPUT_EXCEL}"
    fi
    
    # Get file size
    local excel_size
    excel_size=$(du -h "${OUTPUT_EXCEL}" | awk '{print $1}')
    
    log "INFO" "Excel file created successfully"
    log "INFO" "  File: ${OUTPUT_EXCEL##*/}"
    log "INFO" "  Size: ${excel_size}"
    
    # Upload to both endpoints
    local upload1_status
    
    upload_to_endpoint "${FLOW_URL_1}" "${OUTPUT_EXCEL}" "My SharePoint" && upload1_status="SUCCESS" || upload1_status="FAILED"
    
    # Clean up local Excel file
    rm -f "${OUTPUT_EXCEL}"
    
    # Determine overall status
    if [[ "${upload1_status}" == "SUCCESS" ]]; then
        log "INFO" "✓ All uploads completed successfully"
        SHAREPOINT_UPLOAD_STATUS="SUCCESS"
    elif [[ "${upload1_status}" == "SUCCESS" ]]; then
        log "WARN" "Partial success: Endpoint 1=${upload1_status}"
        SHAREPOINT_UPLOAD_STATUS="PARTIAL"
    else
        log "ERROR" "All uploads failed"
        SHAREPOINT_UPLOAD_STATUS="FAILED"
        error_exit "Failed to upload to SharePoint endpoints"
    fi
}

####### PHASE 5: POST TO TEAMS

post_to_teams_job() {
    log "INFO" "========================================"
    log "INFO" "PHASE 5: POST TO TEAMS NOTIFICATION"
    log "INFO" "========================================"

    local TEAMS_WEBHOOK="$teamsNotification"

    # Calculate duration
    local elapsed_seconds=$SECONDS
    local hours=$((elapsed_seconds / 3600))
    local minutes=$(((elapsed_seconds % 3600) / 60))
    local seconds=$((elapsed_seconds % 60))
    local duration_formatted=$(printf "%02d:%02d:%02d" $hours $minutes $seconds)

    # Gather pipeline summary
    local csv_file="${REPORTS_DIR}/MacSerials_ALL_${DATE}.csv"
    local csv_lines=0
    if [[ -f "${csv_file}" ]]; then
        csv_lines=$(tail -n +2 "${csv_file}" 2>/dev/null | wc -l)
        csv_lines=${csv_lines:-0}
    fi

    # Determine overall status and header color
    local overall_status="✓ SUCCESS"
    local header_color="#4caf50"  # Green
    
    if [[ "${JAMF_UPLOAD_STATUS}" == "FAILED" ]] || [[ "${SHAREPOINT_UPLOAD_STATUS}" == "FAILED" ]]; then
        overall_status="⚠ PARTIAL SUCCESS"
        header_color="#FF9500"  # Orange
    fi
    
    if [[ "${JAMF_UPLOAD_STATUS}" == "FAILED" ]] && [[ "${SHAREPOINT_UPLOAD_STATUS}" == "FAILED" ]]; then
        overall_status="✗ FAILED"
        header_color="#f44336"  # Red
    fi

    # Build status icons
    local jamf_status_icon="✓"
    [[ "${JAMF_UPLOAD_STATUS}" == "FAILED" ]] && jamf_status_icon="✗"
    [[ "${JAMF_UPLOAD_STATUS}" == "SKIPPED" ]] && jamf_status_icon="⊘"
    
    local sharepoint_status_icon="✓"
    [[ "${SHAREPOINT_UPLOAD_STATUS}" == "FAILED" ]] && sharepoint_status_icon="✗"
    [[ "${SHAREPOINT_UPLOAD_STATUS}" == "SKIPPED" ]] && sharepoint_status_icon="⊘"

    # Build the HTML message with icon column
    local html_body
    html_body=$(cat <<'EOF'
<html>
<body style="font-family: Arial, sans-serif; margin: 0; padding: 10px; background-color: #f9f9f9;">
<table style="width: 100%; border-collapse: collapse; background: white; border: 1px solid #ddd; border-radius: 5px; overflow: hidden; box-shadow: 0 2px 4px rgba(0,0,0,0.1);">
  <!-- Header -->
  <tr style="background-color: ${HEADER_COLOR}; color: white;">
    <td colspan="2" style="padding: 12px; font-weight: bold; font-size: 14px;">ABM Serials Pipeline - ${OVERALL_STATUS}</td>
  </tr>
  <!-- Data Rows -->
  <tr style="background-color: #f5f5f5; border-bottom: 1px solid #eee;">
    <td style="padding: 10px; font-weight: bold; color: #666; width: 35%;">File</td>
    <td style="padding: 10px;">ALL_ABM_MacSerials_${DATE}.xlsx</td>
  </tr>
  <tr style="border-bottom: 1px solid #eee;">
    <td style="padding: 10px; font-weight: bold; color: #666;">Version</td>
    <td style="padding: 10px;">${LOG_STAMP}</td>
  </tr>
  <tr style="background-color: #f5f5f5; border-bottom: 1px solid #eee;">
    <td style="padding: 10px; font-weight: bold; color: #666;">Total Devices</td>
    <td style="padding: 10px;">${CSV_LINES}</td>
  </tr>
  <tr style="border-bottom: 1px solid #eee;">
    <td style="padding: 10px; font-weight: bold; color: #666;">Duration</td>
    <td style="padding: 10px;">${DURATION_FORMATTED}</td>
  </tr>
  <tr style="background-color: #f5f5f5; border-bottom: 1px solid #eee;">
    <td style="padding: 10px; font-weight: bold; color: #666;">Jamf Upload</td>
    <td style="padding: 10px;">${JAMF_STATUS_ICON} ${JAMF_UPLOAD_STATUS}</td>
  </tr>
  <tr style="border-bottom: 1px solid #eee;">
    <td style="padding: 10px; font-weight: bold; color: #666;">SharePoint Upload</td>
    <td style="padding: 10px;">${SHAREPOINT_STATUS_ICON} ${SHAREPOINT_UPLOAD_STATUS}</td>
  </tr>
  <!-- Footer -->
  <tr style="background-color: #fafafa; border-top: 2px solid #ddd;">
    <td colspan="3" style="padding: 8px; font-size: 11px; color: #999;">Run by ${CURRENT_USER} on ${SERIAL_NUMBER} | ${HOST_NAME}</td>
  </tr>
</table>
</body>
</html>
EOF
)

    log "INFO" "Sending Teams notification..."
    
    local http_code
    http_code=$(curl -s -w "%{http_code}" -o /tmp/teams_response.txt -X POST \
        -H "Content-Type: text/html" \
        -d "$(printf '%s\n' "$html_body" | sed -e 's|\${HEADER_COLOR}|'"$header_color"'|g' \
                                              -e 's|\${OVERALL_STATUS}|'"$overall_status"'|g' \
                                              -e 's|\${DATE}|'"$DATE"'|g' \
                                              -e 's|\${LOG_STAMP}|'"$LOG_STAMP"'|g' \
                                              -e 's|\${CSV_LINES}|'"$csv_lines"'|g' \
                                              -e 's|\${DURATION_FORMATTED}|'"$duration_formatted"'|g' \
                                              -e 's|\${JAMF_STATUS_ICON}|'"$jamf_status_icon"'|g' \
                                              -e 's|\${JAMF_UPLOAD_STATUS}|'"${JAMF_UPLOAD_STATUS}"'|g' \
                                              -e 's|\${SHAREPOINT_STATUS_ICON}|'"$sharepoint_status_icon"'|g' \
                                              -e 's|\${SHAREPOINT_UPLOAD_STATUS}|'"${SHAREPOINT_UPLOAD_STATUS}"'|g' \
                                              -e 's|\${CURRENT_USER}|'"$currentUser"'|g' \
                                              -e 's|\${SERIAL_NUMBER}|'"$serialNumber"'|g' \
                                              -e 's|\${HOST_NAME}|'"$hostName"'|g')" \
        "${TEAMS_WEBHOOK}")
    
    if [[ "${http_code}" =~ ^20[0-9]$ ]]; then
        log "INFO" "✓ Teams notification sent successfully (HTTP ${http_code})"
        return 0
    else
        log "WARN" "Teams notification failed - HTTP ${http_code}"
        debug_log "Response: $(cat /tmp/teams_response.txt 2>/dev/null)"
        return 1
    fi
}

####### PHASE 5B: POST TO EMAIL

post_to_email_job() {
    log "INFO" "========================================"
    log "INFO" "PHASE 5B: POST EMAIL NOTIFICATION"
    log "INFO" "========================================"
    
    local reportEMAIL="$reportEMAIL"
    local csv_file="${REPORTS_DIR}/MacSerials_ALL_${DATE}.csv"
    local csv_lines=0
    
    if [[ -f "${csv_file}" ]]; then
        csv_lines=$(tail -n +2 "${csv_file}" 2>/dev/null | wc -l)
        csv_lines=${csv_lines:-0}
    fi
    
    # Calculate duration
    local elapsed_seconds=$SECONDS
    local hours=$((elapsed_seconds / 3600))
    local minutes=$(((elapsed_seconds % 3600) / 60))
    local seconds=$((elapsed_seconds % 60))
    local duration_formatted=$(printf "%02d:%02d:%02d" $hours $minutes $seconds)
    
    # Determine overall status (ASCII ONLY for email)
    local overall_status="SUCCESS"
    local email_status="SUCCESS"
    if [[ "${JAMF_UPLOAD_STATUS}" == "FAILED" ]] || [[ "${SHAREPOINT_UPLOAD_STATUS}" == "FAILED" ]]; then
        overall_status="⚠ PARTIAL SUCCESS"
        email_status="PARTIAL SUCCESS"
    fi
    if [[ "${JAMF_UPLOAD_STATUS}" == "FAILED" ]] && [[ "${SHAREPOINT_UPLOAD_STATUS}" == "FAILED" ]]; then
        overall_status="✗ FAILED"
        email_status="FAILED"
    fi
    
    log "INFO" "Sending email to: ${reportEMAIL}"
    
    # Build email body with ASCII characters only
    {
        echo "ABM SERIALS PIPELINE EXECUTION REPORT"
        echo "====================================="
        echo ""
        echo "Overall Status: ${email_status}"
        echo "Run Date: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Duration: ${duration_formatted}"
        echo ""
        echo "EXECUTION DETAILS:"
        echo "-------------------"
        echo "User: ${currentUser}"
        echo "Computer: ${hostName}"
        echo "Serial: ${serialNumber}"
        echo ""
        echo "FILE INFORMATION:"
        echo "-------------------"
        echo "Output File: ALL_ABM_MacSerials_${DATE}.xlsx"
        echo "Version: ${LOG_STAMP}"
        echo "Total Devices: ${csv_lines}"
        echo "CSV Source: MacSerials_ALL_${DATE}.csv"
        echo ""
        echo "UPLOAD STATUS:"
        echo "-------------------"
        echo "Jamf Pro Upload: ${JAMF_UPLOAD_STATUS}"
        echo "SharePoint Upload: ${SHAREPOINT_UPLOAD_STATUS}"
        echo ""
        echo "LOG FILE:"
        echo "-------------------"
        echo "${LOG_FILE}"
        echo ""
        echo "End of Report"
    } | mail -s "ABM Serials Pipeline - ${email_status}" "${reportEMAIL}"
    
    if [[ $? -eq 0 ]]; then
        log "INFO" "✓ Email notification sent successfully"
        log "INFO" "  To: ${reportEMAIL}"
        log "INFO" "  Subject: ABM Serials Pipeline - ${overall_status}"
    else
        log "ERROR" "Failed to send email notification"
    fi
}


####### MAIN EXECUTION

# Get latest from repo root
cd "${REPO_ROOT}"
if git pull; then
    log "INFO" "Git repo updated"
else
    log "WARN" "Git pull failed - continuing anyway"
fi
cd "${SCRIPT_DIR}"

log "INFO" ""
version_check
sanity_check_prerequisites

# PHASE 1A: FETCH MDM SERVERS
if [[ "${RUN_FETCH_MDM_SERVERS}" == "YES" ]]; then
    fetch_mdm_servers_job
fi

# PHASE 1B: FETCH DEVICES
if [[ "${RUN_FETCH_DEVICES}" == "YES" ]]; then
    fetch_devices_job
fi

# PHASE 1C: COMBINE REPORTS
if [[ "${RUN_COMBINE_REPORTS}" == "YES" ]]; then
    combine_token_reports_job
fi

# PHASE 2: GENERATE INSTALLER
if [[ "${RUN_GENERATE_INSTALLER}" == "YES" ]]; then
    generate_install_script
fi

# PHASE 3: UPLOAD TO JAMF
if [[ "${RUN_UPLOAD_TO_JAMF}" == "YES" ]]; then
    upload_script_to_jamf
fi

# PHASE 4: UPLOAD TO SHAREPOINT
if [[ "${RUN_UPLOAD_TO_SHAREPOINT}" == "YES" ]]; then
    upload_to_sharepoint_job
fi

# PHASE 5: POST TO TEAMS
if [[ "${RUN_POST_TO_TEAMS}" == "YES" ]]; then
    post_to_teams_job
fi

# PHASE 5B: POST EMAIL
if [[ "${RUN_POST_TO_EMAIL}" == "YES" ]]; then
    post_to_email_job
fi

# Cleanup
cleanup_temp_dir
cleanup_reports

duration=$SECONDS
log "INFO" "========================================"
log "INFO" "Pipeline completed in: $(($duration / 60)) min $(($duration % 60)) sec"
log "INFO" "Log file: ${LOG_FILE}"
log "INFO" "========================================"

gitSTAMP=$(date +%Y%m%d)
log "Git push time is $gitSTAMP"
git add --all
git commit -a -m "AxM Juggler CSV Pipeline by $currentUser on $gitSTAMP"
git push 


exit 0

