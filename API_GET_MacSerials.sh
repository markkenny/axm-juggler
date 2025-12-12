#!/bin/bash

set -euo pipefail

####### Description and Notes
# Retrieve all Mac devices from specified ABM MDM Servers
# Reads CSV output from API_GET_MDMs.sh and fetches all devices with pagination
# Creates individual reports per MDM server
# 2025 12 10 MK Initial Commit

####### VARIABLES
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOKEN_CONFIG="${SCRIPT_DIR}/config/token_config.env"
REPORTS_DIR="${SCRIPT_DIR}/REPORTS"
DATE=$(date +%Y%m%d)

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
    log "INFO" "Looking for MDM CSV files in ${REPORTS_DIR}..."
    
    # Find all CSV files that match the pattern
    local csv_files=()
    while IFS= read -r file; do
        csv_files+=("$file")
    done < <(find "${REPORTS_DIR}" -maxdepth 1 -name "ABM_MDMs*" -type f 2>/dev/null | sort -r)
    
    if [[ ${#csv_files[@]} -eq 0 ]]; then
        error_exit "No MDM CSV files found in ${REPORTS_DIR}"
    fi
    
    log "INFO" "Found ${#csv_files[@]} CSV file(s):"
    for i in "${!csv_files[@]}"; do
        echo "  [$((i+1))] ${csv_files[$i]##*/}" >&2
    done
    
    echo -n "Select CSV file (enter number): " >&2
    read -r selection
    
    # Validate selection
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
    
    if [[ -z "${access_token}" ]] || [[ -z "${endpoint}" ]]; then
        echo "ERROR: Usage: call_abm_api <access_token> [method] <endpoint>" >&2
        return 1
    fi
    
    curl -s -k \
        -X "${method}" \
        -H "Authorization: Bearer ${access_token}" \
        -H "Accept: application/json" \
        "https://api-business.apple.com${endpoint}"
}

####### Fetch all devices for an MDM server with pagination
fetch_devices_for_mdm() {
    local access_token="$1"
    local mdm_id="$2"
    local token_name="$3"
    local server_name="$4"
    
    local report="${REPORTS_DIR}/MacSerials_${token_name}-${server_name}_${DATE}.csv"
    local cursor=""
    local page_count=0
    local total_records=0
    local temp_file="/tmp/abm_devices_${mdm_id}.txt"
    
    # Clean up temp file if exists
    rm -f "${temp_file}"
    
    log "INFO" "Fetching devices for: ${token_name} > ${server_name}"
    
    while true; do
        page_count=$((page_count+1))
        log "INFO" "  Fetching page ${page_count}..."
        
        # Build cursor parameter
        local cursor_param=""
        if [[ -n "${cursor}" ]]; then
            cursor_param="&cursor=${cursor}"
        fi
        
        # Call API
        local response
        response=$(call_abm_api "${access_token}" GET "/v1/mdmServers/${mdm_id}/relationships/devices?limit=1000${cursor_param}")
        
        # Validate JSON response
        if ! echo "${response}" | jq empty 2>/dev/null; then
            log "ERROR" "  Invalid JSON response on page ${page_count}"
            log "DEBUG" "Response: ${response:0:200}"
            return 1
        fi
        
        # Extract device IDs from this page
        local records_on_page
        records_on_page=$(echo "${response}" | jq '.data | length')
        log "INFO" "  Page ${page_count}: ${records_on_page} records"
        
        if [[ "${records_on_page}" -gt 0 ]]; then
            # Extract all device IDs and append to temp file
            echo "${response}" | jq -r '.data[].id' >> "${temp_file}"
            total_records=$((total_records + records_on_page))
        fi
        
        # Check for next page
        cursor=$(echo "${response}" | jq -r '.meta.paging.nextCursor // empty')
        
        if [[ -z "${cursor}" ]]; then
            log "INFO" "  Pagination complete. Total records: ${total_records}"
            break
        fi
    done
    
    # Create report with header and device list
    if [[ -f "${temp_file}" ]]; then
        {
            echo "TokenName,ServerName,DeviceID"
            while IFS= read -r device_id; do
                echo "\"${token_name}\",\"${server_name}\",\"${device_id}\""
            done < "${temp_file}"
        } > "${report}"
        
        log "INFO" "Report saved: ${report}"
        wc -l "${report}" >&2
        
        rm -f "${temp_file}"
    else
        log "WARN" "No devices found for ${server_name}"
        touch "${report}"
    fi
}

####### THE JOB

####### Step 1
# Prompt user to select CSV
input_csv=$(select_csv_file)
log "INFO" "Processing: ${input_csv}"

###### Step 2
# Verify CSV has headers
if ! head -1 "${input_csv}" | grep -q "TokenName"; then
    error_exit "CSV file does not have expected format (missing TokenName header)"
fi

####### Step 3
#Cache all tokens needed upfront
declare -a cached_tokens
declare -a cached_token_names

log "INFO" "Pre-caching access tokens..."

# Declare loop variables BEFORE the loop
token_found=0
access_token=""
stderr_file=""

while IFS=',' read -r token_name server_name mdm_type mdm_id; do
    # Skip header
    [[ "${token_name}" == "TokenName" ]] && continue
    
    # Remove quotes from CSV fields
    token_name=$(echo "${token_name}" | tr -d '"')
    
    # Check if we already have this token cached
    token_found=0
    for i in "${!cached_token_names[@]}"; do
        if [[ "${cached_token_names[$i]}" == "${token_name}" ]]; then
            token_found=1
            break
        fi
    done
    
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
        
        cached_token_names+=("${token_name}")
        cached_tokens+=("${access_token}")
    fi
done < "${input_csv}"

log "INFO" "Pre-cached ${#cached_token_names[@]} unique token(s)"

###### Step 4
# Process each MDM server
log "INFO" "Processing MDM servers..."

while IFS=',' read -r token_name server_name mdm_type mdm_id; do
    # Skip header
    [[ "${token_name}" == "TokenName" ]] && continue
    
    # Remove quotes from CSV fields
    token_name=$(echo "${token_name}" | tr -d '"')
    server_name=$(echo "${server_name}" | tr -d '"')
    mdm_id=$(echo "${mdm_id}" | tr -d '"')
    
    # Find the cached token
    token_index=-1  # ✅ No local
    for i in "${!cached_token_names[@]}"; do
        if [[ "${cached_token_names[$i]}" == "${token_name}" ]]; then
            token_index=$i
            break
        fi
    done
    
    if [[ ${token_index} -lt 0 ]]; then
        log "ERROR" "No token found for ${token_name}"
        continue
    fi
    
    access_token="${cached_tokens[$token_index]}"  # ✅ No local
    
    # Sanitize server name for filename (remove spaces, special chars)
    safe_server_name=$(echo "${server_name}" | sed 's/[^a-zA-Z0-9]/_/g' | sed 's/_+/_/g')  # ✅ No local
    
    # Fetch devices
    fetch_devices_for_mdm "${access_token}" "${mdm_id}" "${token_name}" "${safe_server_name}" || {
        log "ERROR" "Failed to fetch devices for ${server_name}"
        continue
    }
    
done < "${input_csv}"

###### JOB DONE!

log "INFO" "All reports complete!"
ls -lh "${REPORTS_DIR}"/*_${DATE}.csv 2>/dev/null | tail -20 >&2
