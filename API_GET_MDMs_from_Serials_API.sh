#!/bin/bash

set -euo pipefail

####### Description and Notes
# Query ABM to find which MDM server each device is currently assigned to
# BULK/OPTIMIZED VERSION - Groups devices by token and queries in batches
# Reads a CSV of device serials/IDs
# Searches local MacSerials_* CSV files to identify tokens
# Groups devices by token and queries ABM API with bulk filtering
# 2025 01 16 MK ABM MDM Server Lookup - BULK OPTIMIZED
# BASH 3.2 COMPATIBLE (no associative arrays)

####### VARIABLES
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOKEN_CONFIG="${SCRIPT_DIR}/config/token_config.env"
REPORTS_DIR="${SCRIPT_DIR}/REPORTS"
DATE=$(date +%Y%m%d_%H%M%S)
TEMP_WORK_DIR="/tmp/mdm_lookup_${DATE}"

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

####### Cleanup temp files
cleanup() {
    rm -rf "${TEMP_WORK_DIR}"
}
trap cleanup EXIT

####### Validate prerequisites
if [[ ! -f "${SCRIPT_DIR}/ABM_tokenManager.sh" ]]; then
    error_exit "ABM_tokenManager.sh not found in ${SCRIPT_DIR}"
fi

if [[ ! -f "${TOKEN_CONFIG}" ]]; then
    error_exit "Token config file not found: ${TOKEN_CONFIG}"
fi

mkdir -p "${REPORTS_DIR}"
mkdir -p "${TEMP_WORK_DIR}"

####### Prompt user to select input CSV file
select_input_file() {
    log "INFO" "Looking for CSV files in ${REPORTS_DIR}..."
    
    local csv_files=()
    while IFS= read -r file; do
        csv_files+=("$file")
    done < <(find "${REPORTS_DIR}" -maxdepth 1 -name "*.csv" -type f 2>/dev/null | sort -r)
    
    if [[ ${#csv_files[@]} -eq 0 ]]; then
        error_exit "No CSV files found in ${REPORTS_DIR}"
    fi
    
    log "INFO" "Found ${#csv_files[@]} CSV file(s):"
    for i in "${!csv_files[@]}"; do
        echo "  [$((i+1))] ${csv_files[$i]##*/}" >&2
    done
    
    echo -n "Select CSV file with serials to lookup (enter number): " >&2
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

####### Get all MDM servers for a token (build name->ID map)
get_mdm_servers_map() {
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

####### Query devices in bulk using RSQL filter
####### Query devices in bulk using RSQL filter
get_devices_bulk() {
    local access_token="$1"
    local serial_filter="$2"  # Example: "serialNumber==ABC;serialNumber==DEF"
    
    log "DEBUG" "Filter being sent: ${serial_filter}"
    
    local response
    response=$(call_abm_api "${access_token}" GET "/v1/orgDevices?filter=${serial_filter}" 2>/dev/null)
    
    local http_code
    http_code=$(echo "${response}" | sed -n '$p')
    
    local body
    body=$(echo "${response}" | sed '$d')
    
    if [[ "${http_code}" != "200" ]]; then
        log "DEBUG" "Bulk device query HTTP ${http_code}"
        log "DEBUG" "Response: ${body:0:300}"
        echo "ERROR|${http_code}"
        return 0
    fi
    
    if ! echo "${body}" | jq empty 2>/dev/null; then
        echo "ERROR|JSON_PARSE"
        return 0
    fi
    
    echo "OK"
    echo "${body}"
    return 0
}

####### Get assigned server details by following relationship link
get_assigned_server() {
    local access_token="$1"
    local assigned_server_link="$2"
    
    # Extract path from full URL
    local assigned_server_path="${assigned_server_link#https://api-business.apple.com}"
    
    local response
    response=$(call_abm_api "${access_token}" GET "${assigned_server_path}" 2>/dev/null)
    
    local http_code
    http_code=$(echo "${response}" | sed -n '$p')
    
    local body
    body=$(echo "${response}" | sed '$d')
    
    if [[ "${http_code}" != "200" ]]; then
        log "DEBUG" "Assigned server lookup HTTP ${http_code}"
        echo "ERROR|${http_code}"
        return 0
    fi
    
    if ! echo "${body}" | jq empty 2>/dev/null; then
        echo "ERROR|JSON_PARSE"
        return 0
    fi
    
    echo "OK"
    echo "${body}"
    return 0
}

####### Find which token owns a device ID in MacSerials files
find_token_for_device() {
    local device_id="$1"
    
    # Search all MacSerials files for the device ID (accounting for quotes)
    local match_file
    match_file=$(grep -l "\"${device_id}\"" "${REPORTS_DIR}"/MacSerials_* 2>/dev/null | head -1)
    
    if [[ -z "${match_file}" ]]; then
        return 1
    fi
    
    # Extract token name from first matching line (column 1, remove quotes)
    local token_name
    token_name=$(grep "\"${device_id}\"" "${match_file}" | head -1 | cut -d',' -f1 | tr -d '"' | xargs)
    
    if [[ -z "${token_name}" ]]; then
        return 1
    fi
    
    echo "${token_name}"
    return 0
}

####### Find MDM server name by ID
find_server_name_by_id() {
    local mdm_servers_json="$1"
    local server_id="$2"
    
    echo "${mdm_servers_json}" | jq -r \
        --arg id "${server_id}" \
        '.data[] | select(.id == $id) | .attributes.serverName' 2>/dev/null | head -n1
}

####### THE JOB

log "INFO" "Starting device MDM server lookup (BULK MODE)..."

input_csv=$(select_input_file)
log "INFO" "Processing: ${input_csv}"

# Extract device IDs from input (assume first column or simple list)
declare -a device_ids
while IFS=',' read -r device_id rest; do
    # Skip header rows and empty lines
    [[ "${device_id}" == "DeviceID" ]] && continue
    [[ "${device_id}" == "Serial" ]] && continue
    [[ -z "${device_id}" ]] && continue
    
    # Trim quotes and whitespace
    device_id=$(echo "${device_id}" | tr -d '"' | xargs)
    [[ -z "${device_id}" ]] && continue
    
    device_ids+=("${device_id}")
done < "${input_csv}"

if [[ ${#device_ids[@]} -eq 0 ]]; then
    error_exit "No device IDs found in ${input_csv}"
fi

log "INFO" "Found ${#device_ids[@]} device(s) to lookup"

####### Map devices to tokens - store in temp files (Bash 3.2 compatible)
log "INFO" "Searching MacSerials files to map devices to tokens..."

device_token_map="${TEMP_WORK_DIR}/device_token_map.txt"  # device_id|token_name
token_device_list="${TEMP_WORK_DIR}/token_device_list.txt"  # token_name|device_id1 device_id2...

> "${device_token_map}"
> "${token_device_list}"

unknown_count=0

for device_id in "${device_ids[@]}"; do
    token_name=$(find_token_for_device "${device_id}") || {
        echo "${device_id}|UNKNOWN" >> "${device_token_map}"
        unknown_count=$((unknown_count+1))
        continue
    }
    
    echo "${device_id}|${token_name}" >> "${device_token_map}"
done

log "INFO" "Grouped ${#device_ids[@]} device(s), ${unknown_count} unknown"

# Build unique token list
unique_tokens_file="${TEMP_WORK_DIR}/unique_tokens.txt"
cut -d'|' -f2 "${device_token_map}" | grep -v "^UNKNOWN$" | sort -u > "${unique_tokens_file}"

token_count=$(wc -l < "${unique_tokens_file}")
log "INFO" "Found ${token_count} unique token(s)"

####### Token cache files
token_cache_dir="${TEMP_WORK_DIR}/token_cache"
mkdir -p "${token_cache_dir}"

####### Output file
output_csv="${REPORTS_DIR}/MDM_Lookup_Results_API_${DATE}.csv"
echo "DeviceID,TokenName,AssignedMDMServer,Status,Details" > "${output_csv}"

success_count=0
failure_count=0

####### Process each token
while IFS= read -r token_name; do
    [[ -z "${token_name}" ]] && continue
    
    log "INFO" "Processing token: ${token_name}"
    
    # Get devices for this token from map
    devices_for_token=$(grep "^[^|]*|${token_name}$" "${device_token_map}" | cut -d'|' -f1 | tr '\n' ' ')
    device_array=($devices_for_token)
    
    log "INFO" "  Token ${token_name} has ${#device_array[@]} device(s)"
    
    # Get token
    token_cache_file="${token_cache_dir}/${token_name}"
    
    if [[ ! -f "${token_cache_file}" ]]; then
        log "INFO" "  Getting fresh token..."
        
        stderr_file=$(mktemp /tmp/token_stderr.XXXXXX)
        trap "rm -f ${stderr_file}" RETURN
        
        access_token=$("${SCRIPT_DIR}/ABM_tokenManager.sh" get "${token_name}" 2>"${stderr_file}") || {
            log "ERROR" "Failed to get token for ${token_name}"
            for device_id in "${device_array[@]}"; do
                echo "${device_id},${token_name},,ERROR,Token retrieval failed" >> "${output_csv}"
                failure_count=$((failure_count+1))
            done
            continue
        }
        
        if [[ -z "${access_token}" ]]; then
            log "ERROR" "Empty access token for ${token_name}"
            for device_id in "${device_array[@]}"; do
                echo "${device_id},${token_name},,ERROR,Empty token" >> "${output_csv}"
                failure_count=$((failure_count+1))
            done
            continue
        fi
        
        echo "${access_token}" > "${token_cache_file}"
    fi
    
    access_token=$(cat "${token_cache_file}")
    
    # Get MDM servers for this token (cache in file too)
    mdm_cache_file="${token_cache_dir}/${token_name}.mdm"
    if [[ ! -f "${mdm_cache_file}" ]]; then
        log "INFO" "  Fetching MDM servers for ${token_name}..."
        mdm_servers=$(get_mdm_servers_map "${access_token}")
        echo "${mdm_servers}" > "${mdm_cache_file}"
    else
        mdm_servers=$(cat "${mdm_cache_file}")
    fi
    
    # Query devices individually (ABM doesn't support bulk filter)
    processed=0
    for device_id in "${device_array[@]}"; do
        processed=$((processed + 1))
        
        if [[ $((processed % 10)) -eq 1 ]]; then
            log "INFO" "  Processing device ${processed}/${#device_array[@]}..."
        fi
        
        # Get device details
        device_result=$(call_abm_api "${access_token}" GET "/v1/orgDevices/${device_id}" 2>/dev/null)
        http_code=$(echo "${device_result}" | sed -n '$p')
        device_body=$(echo "${device_result}" | sed '$d')
        
        if [[ "${http_code}" != "200" ]]; then
            log "DEBUG" "Device ${device_id} query returned HTTP ${http_code}"
            echo "${device_id},${token_name},,ERROR,Device not found (HTTP ${http_code})" >> "${output_csv}"
            failure_count=$((failure_count+1))
            continue
        fi
        
        # Extract device JSON
        if ! echo "${device_body}" | jq empty 2>/dev/null; then
            echo "${device_id},${token_name},,ERROR,Invalid JSON response" >> "${output_csv}"
            failure_count=$((failure_count+1))
            continue
        fi
        
        # Check if device has an assignedServer relationship link
        assigned_link=$(echo "${device_body}" | jq -r '.data.relationships.assignedServer.links.related // ""' 2>/dev/null)
        
        if [[ -z "${assigned_link}" ]]; then
            log "DEBUG" "Device ${device_id} has no assignedServer link"
            echo "${device_id},${token_name},,UNASSIGNED,No assignedServer link" >> "${output_csv}"
            failure_count=$((failure_count+1))
            continue
        fi
        
        # Get assigned server details
        server_result=$(get_assigned_server "${access_token}" "${assigned_link}")
        server_status=$(echo "${server_result}" | head -n1 | cut -d'|' -f1)
        
        if [[ "${server_status}" != "OK" ]]; then
            echo "${device_id},${token_name},,ERROR,Failed to fetch assigned server" >> "${output_csv}"
            failure_count=$((failure_count+1))
            continue
        fi
        
        # Extract MDM server ID
        server_body=$(echo "${server_result}" | tail -n +2)
        mdm_server_id=$(echo "${server_body}" | jq -r '.data.id // ""' 2>/dev/null)
        
        if [[ -z "${mdm_server_id}" ]]; then
            echo "${device_id},${token_name},,ERROR,No MDM server ID" >> "${output_csv}"
            failure_count=$((failure_count+1))
            continue
        fi
        
        # Find MDM server name by ID
        mdm_server_name=$(find_server_name_by_id "${mdm_servers}" "${mdm_server_id}")
        
        if [[ -z "${mdm_server_name}" ]]; then
            echo "${device_id},${token_name},${mdm_server_id},RESOLVED_ID_ONLY,Server name lookup failed" >> "${output_csv}"
            failure_count=$((failure_count+1))
            continue
        fi
        
        echo "${device_id},${token_name},${mdm_server_name},SUCCESS," >> "${output_csv}"
        success_count=$((success_count+1))
    done
done < "${unique_tokens_file}"


failure_count=$((failure_count + unknown_count))

####### Summary
cat << EOF

========================================
  MDM LOOKUP SUMMARY (BULK)
========================================
Total Devices:   ${#device_ids[@]}
Successful:      ${success_count}
Failed:          ${failure_count}
Results:         ${output_csv}
========================================

EOF

log "INFO" "Lookup complete!"


