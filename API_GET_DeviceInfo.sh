#!/bin/bash

set -euo pipefail

####### Description and Notes
# Retrieve detailed device information from ABM API using MacSerials CSV
# Reads TokenName, ServerName, DeviceID from MacSerials_*.csv in REPORTS folder
# Uses TokenName to determine which ABM token/API to use
# Fetches device details from /v1/orgDevices/{DeviceID} endpoint
# Handles 429 (rate limit), 401 (token refresh), 404 (not found)
# Creates CSV report with flattened device attributes and original metadata
# 2025 12 11 MK ABM Device Details from MacSerials List

####### VARIABLES
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOKEN_CONFIG="${SCRIPT_DIR}/config/token_config.env"
REPORTS_DIR="${SCRIPT_DIR}/REPORTS"
DATE=$(date +%Y%m%d)
API_SLEEP="1"

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
    
    # Find all CSV files that match the pattern
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
    
    curl -s -k -w "\n%{http_code}" \
        -X "${method}" \
        -H "Authorization: Bearer ${access_token}" \
        -H "Accept: application/json" \
        "https://api-business.apple.com${endpoint}"
}

####### Fetch device info for a DeviceID (serial) with smart rate-limit handling
fetch_device_info() {
    local access_token="$1"
    local device_id="$2"
    local retry_count=0
    local max_retries=5
    local wait_time=1
    
    while [[ ${retry_count} -lt ${max_retries} ]]; do
        log "INFO" "  Fetching device info for: ${device_id} (attempt $((retry_count+1))/${max_retries})"
        
        local response
        response=$(call_abm_api "${access_token}" GET "/v1/orgDevices/${device_id}" 2>/dev/null)
        
        # Parse HTTP status code (last line)
        local http_code
        http_code=$(echo "${response}" | sed -n '$p')
        
        # Get response body (all lines except last)
        local body
        body=$(echo "${response}" | sed '$d')
        
        # Extract Retry-After header if present (would need to be captured from curl headers)
        # For now we'll estimate based on response
        
        # Handle 429 - Too Many Requests
        if [[ "${http_code}" == "429" ]]; then
            retry_count=$((retry_count+1))
            
            # Exponential backoff: 2^retry_count seconds (1, 2, 4, 8, 16)
            wait_time=$((2 ** retry_count))
            
            log "WARN" "Rate limited (429) on ${device_id}. Waiting ${wait_time} seconds before retry $((retry_count+1))/${max_retries}..."
            sleep ${wait_time}
            continue
        fi
        
        # Handle 401 - Unauthorized
        if [[ "${http_code}" == "401" ]]; then
            echo "ERROR|401|Unauthorized"
            return 0
        fi
        
        # Handle 403 - Forbidden
        if [[ "${http_code}" == "403" ]]; then
            echo "ERROR|403|Forbidden"
            return 0
        fi
        
        # Handle 404 - Not Found
        if [[ "${http_code}" == "404" ]]; then
            echo "NOT_FOUND|${device_id}"
            return 0
        fi
        
        # Handle other non-200 codes
        if [[ "${http_code}" != "200" ]]; then
            echo "ERROR|${http_code}|HTTP ${http_code}"
            return 0
        fi
        
        # Validate JSON
        if ! echo "${body}" | jq empty 2>/dev/null; then
            echo "ERROR|JSON_PARSE|Failed to parse JSON response"
            return 0
        fi
        
        # Success - return OK with JSON body
        echo "OK|${body}"
        return 0
    done
    
    # Max retries exceeded
    echo "ERROR|MAX_RETRIES|Exceeded maximum retry attempts for 429"
    return 0
}


####### THE JOB

log "INFO" "Starting device details fetch from MacSerials CSV..."

####### Step 1: Select CSV file
input_csv=$(select_csv_file)
log "INFO" "Processing: ${input_csv}"

# Extract token name from filename: MacSerials_180-nl-Omnicom_DSO_20251210.csv
filename_only="${input_csv##*/}"
token_from_filename=$(echo "${filename_only}" | sed 's/MacSerials_//; s/_[^_]*_[0-9]*\.csv//')

####### Step 2: Verify CSV has headers
if ! head -1 "${input_csv}" | grep -q "TokenName"; then
    error_exit "CSV file does not have expected format (missing TokenName header)"
fi

if ! head -1 "${input_csv}" | grep -q "DeviceID"; then
    error_exit "CSV file does not have expected format (missing DeviceID header)"
fi

####### Step 3: Count total records
total_records=$(tail -n +2 "${input_csv}" | grep -c . || echo 0)
[[ ${total_records} -eq 0 ]] && error_exit "No device records found in CSV"

log "INFO" "Found ${total_records} device records to process"

####### Step 4: Cache all tokens needed upfront
declare -a cached_token_names
declare -a cached_tokens

log "INFO" "Pre-caching access tokens..."

token_found=0
access_token=""
stderr_file=""

# First pass: extract unique token names and cache them
while IFS=',' read -r token_name server_name device_id; do
    # Skip header
    [[ "${token_name}" == "TokenName" ]] && continue
    
    # Remove quotes from CSV fields
    token_name=$(echo "${token_name}" | tr -d '"')
    
    # Check if we already have this token cached
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
        
        cached_token_names+=("${token_name}")
        cached_tokens+=("${access_token}")
    fi
done < "${input_csv}"

log "INFO" "Pre-cached ${#cached_token_names[@]} unique token(s)"

####### Step 5: Temporary files for tracking results
temp_dir="/tmp/abm_devices_${DATE}"
mkdir -p "${temp_dir}" || error_exit "Failed to create temp directory: ${temp_dir}"

temp_success="${temp_dir}/success.txt"
temp_not_found="${temp_dir}/not_found.txt"
temp_errors="${temp_dir}/errors.txt"

touch "${temp_success}" "${temp_not_found}" "${temp_errors}" || error_exit "Failed to create temp files"

log "INFO" "Temp directory: ${temp_dir}"

####### Step 6: Process each device
line_num=0
success_count=0
not_found_count=0
error_count=0
rate_limit_hits=0
adaptive_delay=0.1

json_storage_dir="${temp_dir}/json_storage"
mkdir -p "${json_storage_dir}"

# Initialize unique_tokens tracker
unique_tokens=""

log "INFO" "Processing devices..."

while IFS=',' read -r token_name server_name device_id; do
    # Skip header
    [[ "${token_name}" == "TokenName" ]] && continue
    
    # Remove quotes from CSV fields
    token_name=$(echo "${token_name}" | tr -d '"')
    server_name=$(echo "${server_name}" | tr -d '"')
    device_id=$(echo "${device_id}" | tr -d '"')
    
    # Track unique tokens
    if ! echo "${unique_tokens}" | grep -q "${token_name}"; then
        unique_tokens="${unique_tokens}${token_name}|"
    fi

    line_num=$((line_num+1))
    
    # Find the cached token
    token_index=-1
    if [[ ${#cached_token_names[@]} -gt 0 ]]; then
        for i in "${!cached_token_names[@]}"; do
            if [[ "${cached_token_names[$i]}" == "${token_name}" ]]; then
                token_index=$i
                break
            fi
        done
    fi
    
    if [[ ${token_index} -lt 0 ]]; then
        log "ERROR" "No token found for ${token_name}"
        printf '%s\n' "${token_name}|${server_name}|${device_id}|NO_TOKEN" >> "${temp_errors}"
        error_count=$((error_count+1))
        continue
    fi
    
    access_token="${cached_tokens[$token_index]}"
    
    # Fetch device info
    result=$(fetch_device_info "${access_token}" "${device_id}") || result="ERROR|FETCH_FAILED|Function returned non-zero"
    
    # Add adaptive delay between API calls to avoid rate limits
    sleep ${adaptive_delay}
    
    first_line=$(echo "${result}" | head -n1)
    rest_of_result=$(echo "${result}" | tail -n +2)
    status=$(echo "${first_line}" | cut -d'|' -f1)
    
    if [[ "${status}" == "OK" ]]; then
        first_line_body=$(echo "${first_line}" | cut -d'|' -f2-)
        json_body="${first_line_body}"
        if [[ -n "${rest_of_result}" ]]; then
            json_body="${json_body}
${rest_of_result}"
        fi
        
        # Compact JSON
        json_body=$(echo "${json_body}" | jq -c '.' 2>&1)
        jq_result=$?
        
        if [[ ${jq_result} -ne 0 ]]; then
            log "ERROR" "Failed to compact JSON for ${device_id}"
            printf '%s\n' "${token_name}|${server_name}|${device_id}|JSON_COMPACT_ERROR" >> "${temp_errors}"
            error_count=$((error_count+1))
            continue
        fi
        
        # Write metadata and store JSON separately
        printf '%s\n' "${token_name}|${server_name}|${device_id}" >> "${temp_success}"
        echo "${json_body}" > "${json_storage_dir}/${device_id}.json"
        
        success_count=$((success_count+1))
        log "INFO" "  ✓ Found: ${device_id}"
        
        # Decrease delay on successful request (we're doing fine)
        adaptive_delay=$(echo "${adaptive_delay} * 0.95" | bc)
        if (( $(echo "${adaptive_delay} < 0.05" | bc -l) )); then
            adaptive_delay=0.05
        fi
        
    elif [[ "${status}" == "NOT_FOUND" ]]; then
        printf '%s\n' "${token_name}|${server_name}|${device_id}" >> "${temp_not_found}"
        not_found_count=$((not_found_count+1))
        log "WARN" "  ✗ Not found: ${device_id}"
        
    elif [[ "${status}" == "ERROR" ]]; then
        error_detail=$(echo "${first_line}" | cut -d'|' -f3-)
        printf '%s\n' "${token_name}|${server_name}|${device_id}|${error_detail}" >> "${temp_errors}"
        error_count=$((error_count+1))
        
        # If rate limited, increase adaptive delay significantly
        if [[ "${error_detail}" == *"429"* ]] || [[ "${error_detail}" == *"MAX_RETRIES"* ]]; then
            rate_limit_hits=$((rate_limit_hits+1))
            adaptive_delay=$(echo "${adaptive_delay} * 2.0" | bc)
            log "ERROR" "  ! Rate limit hit (${rate_limit_hits}). Increasing delay to ${adaptive_delay}s"
        else
            log "ERROR" "  ! Error on ${device_id}: ${error_detail}"
        fi
    else
        log "ERROR" "Unknown status for ${device_id}: [${status}]"
        printf '%s\n' "${token_name}|${server_name}|${device_id}|UNKNOWN_STATUS:${status}" >> "${temp_errors}"
        error_count=$((error_count+1))
    fi
    
done < "${input_csv}"

log "INFO" "Fetch complete: ${success_count} found, ${not_found_count} not found, ${error_count} errors"
if [[ ${rate_limit_hits} -gt 0 ]]; then
    log "WARN" "Total rate limit hits: ${rate_limit_hits}"
fi


####### Step 7: Build per-token CSV reports
if [[ ${success_count} -gt 0 ]]; then
    log "INFO" "Building per-token CSV reports..."
    
    if [[ ! -s "${temp_success}" ]]; then
        log "WARN" "Temp success file is empty"
    else
        # Extract all unique attribute keys
        log "DEBUG" "Extracting attribute keys..."
        for json_file in "${json_storage_dir}"/*.json; do
            [[ -f "${json_file}" ]] && cat "${json_file}" | jq -r '.data.attributes | keys | .[]' 2>/dev/null
        done | sort -u > /tmp/all_keys.txt
        
        log "DEBUG" "Attribute keys extracted: $(wc -l < /tmp/all_keys.txt) keys"
        
        # Build CSV header once
        csv_header="TokenName,ServerName,InputDeviceID,ResponseID,ResponseType"
        if [[ -s /tmp/all_keys.txt ]]; then
            while IFS= read -r attr_key; do
                csv_header="${csv_header},${attr_key}"
            done < /tmp/all_keys.txt
        fi
        
        # Process each unique token
        IFS='|' read -ra token_array <<< "${unique_tokens}"
        for token in "${token_array[@]}"; do
            [[ -z "${token}" ]] && continue
            
            csv_report="${REPORTS_DIR}/Devices_Details_${token}_${DATE}.csv"
            log "INFO" "Creating CSV for token: ${token}"
            
            # Write header
            echo "${csv_header}" > "${csv_report}"
            
            # Write data rows for this token only
            row_count=0
            while IFS='|' read -r csv_token server_name device_id; do
                # Skip rows for other tokens
                [[ "${csv_token}" != "${token}" ]] && continue
                
                json_file="${json_storage_dir}/${device_id}.json"
                
                if [[ ! -f "${json_file}" ]]; then
                    log "WARN" "JSON file missing for ${device_id}"
                    continue
                fi
                
                json_data=$(cat "${json_file}")
                response_id=$(echo "${json_data}" | jq -r '.data.id // ""' 2>/dev/null)
                response_type=$(echo "${json_data}" | jq -r '.data.type // ""' 2>/dev/null)
                
                csv_row="${csv_token},${server_name},${device_id},${response_id},${response_type}"
                
                # Add attribute values
                if [[ -s /tmp/all_keys.txt ]]; then
                    while IFS= read -r attr_key; do
                        attr_value=$(echo "${json_data}" | jq -r ".data.attributes[\"${attr_key}\"] // \"\"" 2>/dev/null)
                        
                        if [[ "${attr_value}" == "["* ]]; then
                            attr_value=$(echo "${json_data}" | jq -r ".data.attributes[\"${attr_key}\"] | join(\";\")" 2>/dev/null)
                        fi
                        
                        if [[ "${attr_value}" == *","* ]] || [[ "${attr_value}" == *$'\n'* ]] || [[ "${attr_value}" == *"\""* ]]; then
                            attr_value="\"$(echo "${attr_value}" | sed 's/"/""/g')\""
                        fi
                        
                        csv_row="${csv_row},${attr_value}"
                    done < /tmp/all_keys.txt
                fi
                
                echo "${csv_row}" >> "${csv_report}"
                row_count=$((row_count+1))
            done < "${temp_success}"
            
            log "INFO" "  Token ${token}: ${row_count} rows"
            wc -l "${csv_report}" >&2
        done
    fi
else
    log "WARN" "No successful device lookups - CSV not created"
fi


####### Step 8: Generate JSON summary
log "INFO" "Generating summary..."

cat << EOF

========================================
  FINAL SUMMARY (JSON)
========================================
{
  "input_csv": "$(basename ${input_csv})",
  "total_devices": ${total_records},
  "found": ${success_count},
  "not_found": ${not_found_count},
  "errors": ${error_count},
  "output_csv": "$(basename ${csv_report})",
  "timestamp": "${DATE}"
}
========================================

EOF

# Print details if there are not_found or errors
if [[ -f "${temp_not_found}" ]] && [[ -s "${temp_not_found}" ]]; then
    echo "NOT FOUND DEVICES:" >&2
    awk -F'|' '{printf "  • %s (Server: %s)\n", $3, $2}' "${temp_not_found}" >&2
    echo "" >&2
fi

if [[ -f "${temp_errors}" ]] && [[ -s "${temp_errors}" ]]; then
    echo "DEVICES WITH ERRORS:" >&2
    awk -F'|' '{printf "  • %s: %s\n", $3, $4}' "${temp_errors}" >&2
    echo "" >&2
fi

####### Cleanup
rm -rf "${temp_dir}" /tmp/all_keys.txt

log "INFO" "Device details fetch complete!"
if [[ -f "${csv_report}" ]]; then
    ls -lh "${csv_report}" 2>/dev/null >&2
fi

