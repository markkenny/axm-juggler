#!/bin/bash

set -euo pipefail

####### Description and Notes
# Reassign Mac devices between ABM MDM servers using orgDeviceActivities
# Reads TokenName,ServerName,DeviceID,NewServerName from CSV
# POSTs to /v1/orgDeviceActivities with ASSIGN_DEVICES activity
# Polls activity status and downloads CSV results
# 2025 12 11 MK ABM Server Reassignment via Device Activities
# 2025 01 16 MK Updated with exponential backoff polling

####### VARIABLES
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOKEN_CONFIG="${SCRIPT_DIR}/config/token_config.env"
REPORTS_DIR="${SCRIPT_DIR}/REPORTS"
DATE=$(date +%Y%m%d)
MAX_STATUS_CHECKS=12  # Check up to 12 times with exponential backoff (max ~2.5 min)

####### Functions
log() {
    local level="$1"
    shift
    echo "[${level}] $*" >&2
}

error_exit() {
    log "ERROR" "$@"
    exit 1
}

####### Validate prerequisites
if [[ ! -f "${SCRIPT_DIR}/ABM_tokenManager.sh" ]]; then
    error_exit "ABM_tokenManager.sh not found in ${SCRIPT_DIR}"
fi

if [[ ! -f "${TOKEN_CONFIG}" ]]; then
    error_exit "Token config file not found: ${TOKEN_CONFIG}"
fi

mkdir -p "${REPORTS_DIR}"

####### Prompt user to select CSV file
select_csv_file() {
    log "INFO" "Looking for MacSerials CSV files in ${REPORTS_DIR}..."
    
    local csv_files=()
    while IFS= read -r file; do
        csv_files+=("$file")
    done < <(find "${REPORTS_DIR}" -maxdepth 1 -name "MacSerials*" -type f 2>/dev/null | sort -r)
    
    if [[ ${#csv_files[@]} -eq 0 ]]; then
        error_exit "No MacSerials CSV files found in ${REPORTS_DIR}"
    fi
    
    log "INFO" "Found ${#csv_files[@]} CSV file(s):"
    for i in "${!csv_files[@]}"; do
        echo "  [$((i+1))] ${csv_files[$i]##*/}" >&2
    done
    
    echo -n "Select CSV file (enter number): " >&2
    read -r selection
    
    if ! [[ "${selection}" =~ ^[0-9]+$ ]] || [[ ${selection} -lt 1 ]] || [[ ${selection} -gt ${#csv_files[@]} ]]; then
        error_exit "Invalid selection"
    fi
    
    echo "${csv_files[$((selection-1))]}"
}

####### Call ABM API with Token
call_abm_api() {
    local access_token="$1"
    local method="${2:-GET}"
    local endpoint="$3"
    local data="${4:-}"
    
    if [[ -z "${access_token}" ]] || [[ -z "${endpoint}" ]]; then
        echo "ERROR: Usage: call_abm_api <access_token> [method] <endpoint> [data]" >&2
        return 1
    fi
    
    if [[ -n "${data}" ]]; then
        curl -s -k -w "\n%{http_code}" \
            -X "${method}" \
            -H "Authorization: Bearer ${access_token}" \
            -H "Accept: application/json" \
            -H "Content-Type: application/json" \
            -d "${data}" \
            "https://api-business.apple.com${endpoint}"
    else
        curl -s -k -w "\n%{http_code}" \
            -X "${method}" \
            -H "Authorization: Bearer ${access_token}" \
            -H "Accept: application/json" \
            "https://api-business.apple.com${endpoint}"
    fi
}

####### Get all MDM servers for a token
get_mdm_servers() {
    local access_token="$1"
    
    local response
    response=$(call_abm_api "${access_token}" GET "/v1/mdmServers" 2>/dev/null)
    
    local http_code
    http_code=$(echo "${response}" | sed -n '$p')
    
    local body
    body=$(echo "${response}" | sed '$d')
    
    if [[ "${http_code}" != "200" ]]; then
        log "ERROR" "Failed to fetch MDM servers (HTTP ${http_code})"
        echo "{}"
        return 0
    fi
    
    if ! echo "${body}" | jq empty 2>/dev/null; then
        log "ERROR" "Invalid JSON response from MDM servers"
        echo "{}"
        return 0
    fi
    
    echo "${body}"
    return 0
}

####### Find MDM Server ID by name
find_server_id() {
    local mdm_servers_json="$1"
    local server_name="$2"
    
    echo "${mdm_servers_json}" | jq -r \
        --arg name "${server_name}" \
        '.data[] | select(.attributes.serverName == $name) | .id' 2>/dev/null | head -n1
}

####### POST orgDeviceActivities to reassign devices
####### POST orgDeviceActivities to reassign devices
post_device_activity() {
    local access_token="$1"
    local mdm_server_id="$2"
    shift 2
    local device_ids=("$@")
    
    # Build device array JSON
    local devices_json=""
    for device_id in "${device_ids[@]}"; do
        if [[ -n "${devices_json}" ]]; then
            devices_json="${devices_json},"
        fi
        devices_json="${devices_json}{\"type\":\"orgDevices\",\"id\":\"${device_id}\"}"
    done
    
    # Build full payload
    local payload=$(jq -n \
        --arg mdm_id "${mdm_server_id}" \
        --argjson devices "[${devices_json}]" \
        '{
            data: {
                type: "orgDeviceActivities",
                attributes: {
                    activityType: "ASSIGN_DEVICES"
                },
                relationships: {
                    mdmServer: {
                        data: {
                            type: "mdmServers",
                            id: $mdm_id
                        }
                    },
                    devices: {
                        data: $devices
                    }
                }
            }
        }')
    
    log "INFO" "Posting orgDeviceActivities for ${#device_ids[@]} device(s) to server ${mdm_server_id}..."
    
    local response
    response=$(curl -s -k -w "\n%{http_code}" \
        -X "POST" \
        -H "Authorization: Bearer ${access_token}" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "https://api-business.apple.com/v1/orgDeviceActivities")
    
    local http_code
    http_code=$(echo "${response}" | sed -n '$p')
    
    local body
    body=$(echo "${response}" | sed '$d')
    
    log "DEBUG" "HTTP Code: ${http_code}"
    log "DEBUG" "Response Body (first 500 chars): ${body:0:500}"
    
    if [[ "${http_code}" != "201" ]]; then
        log "ERROR" "Failed to create activity (HTTP ${http_code})"
        log "DEBUG" "Full response: ${body}"
        echo "ERROR|${http_code}|${body:0:300}"
        return 0
    fi
    
    if ! echo "${body}" | jq empty 2>/dev/null; then
        log "ERROR" "Invalid JSON response from activity creation"
        log "DEBUG" "Body was: ${body}"
        echo "ERROR|JSON_PARSE|${body:0:300}"
        return 0
    fi
    
    log "DEBUG" "JSON parsed successfully"
    echo "OK"
    echo "${body}"
    return 0
}

####### GET orgDeviceActivities status
####### GET orgDeviceActivities status
get_activity_status() {
    local access_token="$1"
    local activity_id="$2"
    
    local response
    response=$(call_abm_api "${access_token}" GET "/v1/orgDeviceActivities/${activity_id}" 2>/dev/null)
    
    local http_code
    http_code=$(echo "${response}" | sed -n '$p')
    
    local body
    body=$(echo "${response}" | sed '$d')
    
    if [[ "${http_code}" != "200" ]]; then
        log "DEBUG" "get_activity_status HTTP ${http_code}"
        echo "ERROR|${http_code}"
        return 0
    fi
    
    if ! echo "${body}" | jq empty 2>/dev/null; then
        log "ERROR" "Invalid JSON in get_activity_status"
        echo "ERROR|JSON_PARSE"
        return 0
    fi
    
    log "DEBUG" "get_activity_status parsed OK"
    echo "OK"
    echo "${body}"
    return 0
}

####### Download activity CSV results
download_activity_csv() {
    local download_url="$1"
    local activity_id="$2"
    local output_file="$3"
    
    log "INFO" "Downloading CSV from activity ${activity_id}..."
    
    curl -s -k -o "${output_file}" "${download_url}"
    
    if [[ ! -f "${output_file}" ]] || [[ ! -s "${output_file}" ]]; then
        log "ERROR" "Failed to download CSV"
        return 1
    fi
    
    log "INFO" "CSV downloaded to: ${output_file}"
    wc -l "${output_file}" >&2
    return 0
}

####### THE JOB

log "INFO" "Starting server reassignment process..."

input_csv=$(select_csv_file)
log "INFO" "Processing: ${input_csv}"

if ! head -1 "${input_csv}" | grep -q "TokenName"; then
    error_exit "CSV file missing TokenName header"
fi

if ! head -1 "${input_csv}" | grep -q "DeviceID"; then
    error_exit "CSV file missing DeviceID header"
fi

if ! head -1 "${input_csv}" | grep -q "NewServerName"; then
    error_exit "CSV file missing NewServerName header"
fi

total_records=$(tail -n +2 "${input_csv}" | grep -c . || echo 0)
[[ ${total_records} -eq 0 ]] && error_exit "No device records found in CSV"

log "INFO" "Found ${total_records} device records to process"

####### Group devices by Token and NewServerName
declare -a group_keys
declare -a group_tokens
declare -a group_servers
declare -a group_devices

while IFS=',' read -r token_name server_name device_id new_server_name; do
    # Skip header row
    [[ "${token_name}" == "TokenName" ]] && continue
    
    # Skip empty lines
    [[ -z "${token_name}" ]] && continue
    [[ -z "${device_id}" ]] && continue
    [[ -z "${new_server_name}" ]] && continue
    
    # Trim quotes and whitespace
    token_name=$(echo "${token_name}" | tr -d '"' | xargs)
    new_server_name=$(echo "${new_server_name}" | tr -d '"' | xargs)
    device_id=$(echo "${device_id}" | tr -d '"' | xargs)
    
    # Skip if still empty after trimming
    [[ -z "${token_name}" ]] && continue
    [[ -z "${device_id}" ]] && continue
    [[ -z "${new_server_name}" ]] && continue
    
    # Create group key
    group_key="${token_name}|${new_server_name}"
    
    # Check if group already exists
    group_found=0
    if [[ ${#group_keys[@]} -gt 0 ]]; then
        for i in "${!group_keys[@]}"; do
            key="${group_keys[$i]:-}"
            if [[ "${key}" == "${group_key}" ]]; then
                group_found=1
                group_devices[$i]="${group_devices[$i]} ${device_id}"
                break
            fi
        done
    fi
    
    # Add new group if not found
    if [[ ${group_found} -eq 0 ]]; then
        group_keys+=("${group_key}")
        group_tokens+=("${token_name}")
        group_servers+=("${new_server_name}")
        group_devices+=("${device_id}")
    fi
done < "${input_csv}"

log "INFO" "Grouped devices into ${#group_keys[@]} reassignment batch(es)"


####### Cache tokens
declare -a cached_token_names
declare -a cached_tokens
declare -a cached_mdm_servers

log "INFO" "Pre-caching tokens and MDM server info..."

for token_name in "${group_tokens[@]}"; do
    # Check if already cached
    token_found=0
    if [[ ${#cached_token_names[@]} -gt 0 ]]; then
        for i in "${!cached_token_names[@]}"; do
            if [[ "${cached_token_names[$i]}" == "${token_name}" ]]; then
                token_found=1
                break
            fi
        done
    fi
    
    if [[ ${token_found} -eq 0 ]]; then
        log "INFO" "  Getting token for: ${token_name}"
        
        stderr_file=$(mktemp /tmp/token_stderr.XXXXXX)
        trap "rm -f ${stderr_file}" RETURN
        
        access_token=$("${SCRIPT_DIR}/ABM_tokenManager.sh" get "${token_name}" 2>"${stderr_file}") || {
            log "ERROR" "Failed to get token for ${token_name}"
            cat "${stderr_file}" >&2
            exit 1
        }
        
        if [[ -z "${access_token}" ]]; then
            log "ERROR" "Empty access token for ${token_name}"
            exit 1
        fi
        
        # Get MDM servers
        mdm_servers=$(get_mdm_servers "${access_token}")
        
        cached_token_names+=("${token_name}")
        cached_tokens+=("${access_token}")
        cached_mdm_servers+=("${mdm_servers}")
    fi
done

log "INFO" "Pre-cached ${#cached_token_names[@]} unique token(s)"

####### Process each group
temp_dir="/tmp/abm_reassign_${DATE}"
mkdir -p "${temp_dir}"

success_count=0
failure_count=0

for i in "${!group_keys[@]}"; do
    group_key="${group_keys[$i]}"
    token_name="${group_tokens[$i]}"
    new_server_name="${group_servers[$i]}"
    devices_str="${group_devices[$i]}"
    
    # Trim devices string
    devices_str=$(echo "${devices_str}" | xargs)
    
    log "INFO" "Processing group: ${token_name} → ${new_server_name}"
    log "INFO" "  Devices: ${devices_str}"
    
    # Find token index
    token_index=-1
    if [[ ${#cached_token_names[@]} -gt 0 ]]; then
        for j in "${!cached_token_names[@]}"; do
            if [[ "${cached_token_names[$j]}" == "${token_name}" ]]; then
                token_index=$j
                break
            fi
        done
    fi
    
    if [[ ${token_index} -lt 0 ]]; then
        log "ERROR" "No token found for ${token_name}"
        failure_count=$((failure_count+1))
        continue
    fi
    
    access_token="${cached_tokens[$token_index]}"
    mdm_servers="${cached_mdm_servers[$token_index]}"
    
    # Find new server ID
    new_server_id=$(find_server_id "${mdm_servers}" "${new_server_name}")
    
    if [[ -z "${new_server_id}" ]]; then
        log "ERROR" "Server '${new_server_name}' not found in ABM"
        failure_count=$((failure_count+1))
        continue
    fi
    
    log "INFO" "  Target server ID: ${new_server_id}"
    
    # Convert devices string to array
    read -ra device_array <<< "${devices_str}"
    
    # POST activity
    activity_result=$(post_device_activity "${access_token}" "${new_server_id}" "${device_array[@]}")
    activity_status=$(echo "${activity_result}" | head -n1 | cut -d'|' -f1)

    if [[ "${activity_status}" != "OK" ]]; then
        log "ERROR" "Failed to create activity"
        activity_error=$(echo "${activity_result}" | head -n1 | cut -d'|' -f2-)
        log "DEBUG" "Error: ${activity_error}"
        failure_count=$((failure_count+1))
        continue
    fi

    # Get JSON from line 2 onwards (skip the "OK|" prefix)
    activity_json=$(echo "${activity_result}" | tail -n +2)
    activity_id=$(echo "${activity_json}" | jq -r '.data.id // ""' 2>/dev/null)
    
    if [[ -z "${activity_id}" ]]; then
        log "ERROR" "No activity ID returned"
        failure_count=$((failure_count+1))
        continue
    fi
    
    log "INFO" "  Activity ID: ${activity_id}"
    log "INFO" "  Starting status polling with exponential backoff..."
    
    # Poll for activity completion with exponential backoff
    check_count=0
    activity_completed=0
    download_url=""
    
    while [[ ${check_count} -lt ${MAX_STATUS_CHECKS} ]]; do
        check_count=$((check_count+1))
        
        # Calculate exponential backoff: 3s, 6s, 12s, 24s, 48s, 60s...
        if [[ ${check_count} -eq 1 ]]; then
            backoff_wait=3
        else
            backoff_wait=$((3 * (2 ** (check_count - 2))))
            # Cap at 60 seconds to avoid excessive waits
            [[ ${backoff_wait} -gt 60 ]] && backoff_wait=60
        fi
        
        log "INFO" "  Status check ${check_count}/${MAX_STATUS_CHECKS} (waiting ${backoff_wait}s before check)..."
        sleep ${backoff_wait}
        
        status_result=$(get_activity_status "${access_token}" "${activity_id}")
        status_code=$(echo "${status_result}" | head -n1 | cut -d'|' -f1)

        if [[ "${status_code}" != "OK" ]]; then
            log "WARN" "Failed to get activity status (check ${check_count}/${MAX_STATUS_CHECKS})"
            continue
        fi

        # Get JSON from line 2 onwards
        status_json=$(echo "${status_result}" | tail -n +2)
        cur_status=$(echo "${status_json}" | jq -r '.data.attributes.status // ""' 2>/dev/null)
        download_url=$(echo "${status_json}" | jq -r '.data.attributes.downloadUrl // ""' 2>/dev/null)
        
        log "INFO" "  Status: ${cur_status}"
        
        if [[ "${cur_status}" == "COMPLETED" ]]; then
            activity_completed=1
            log "INFO" "  ✓ Activity completed after ${check_count} check(s)"
            break
        fi
    done
    
    if [[ ${activity_completed} -eq 1 ]]; then
        log "INFO" "  ✓ Activity completed successfully!"
        success_count=$((success_count+1))
        
        # Download CSV if available
        if [[ -n "${download_url}" ]]; then
            csv_output="${temp_dir}/Activity_${activity_id}.csv"
            if download_activity_csv "${download_url}" "${activity_id}" "${csv_output}"; then
                # Copy to REPORTS_DIR
                cp "${csv_output}" "${REPORTS_DIR}/Reassignment_Results_${token_name}_${DATE}.csv"
                log "INFO" "  CSV saved to REPORTS"
            fi
        fi
    else
        log "WARN" "  Activity did not complete in time (max checks exceeded)"
        failure_count=$((failure_count+1))
    fi
done

####### Summary
cat << EOF

========================================
  REASSIGNMENT SUMMARY
========================================
Total Batches:   ${#group_keys[@]}
Successful:      ${success_count}
Failed:          ${failure_count}
========================================

EOF

rm -rf "${temp_dir}"

log "INFO" "Server reassignment complete!"

