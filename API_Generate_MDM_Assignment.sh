#!/bin/bash

set -euo pipefail

####### Description and Notes
# Generate reassignment CSV from device serials
# 1. Read serials from input CSV
# 2. Look up serials in MacSerials_* files to find token/current server
# 3. Query ABM to get available MDM servers per token
# 4. Prompt user to select new destination server
# 5. Output CSV ready for API_POST_SerialMDM.sh
# 2025 01 16 MK ABM Reassignment Generator

####### VARIABLES
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOKEN_CONFIG="${SCRIPT_DIR}/config/token_config.env"
REPORTS_DIR="${SCRIPT_DIR}/REPORTS"
DATE=$(date +%Y%m%d_%H%M%S)
TEMP_WORK_DIR="/tmp/reassign_gen_${DATE}"

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

####### Prompt user to select input CSV file (serials only)
select_input_file() {
    log "INFO" "Looking for serial CSV files in ${REPORTS_DIR}..."
    
    local csv_files=()
    while IFS= read -r file; do
        # Skip reassignment output files
        if [[ "${file}" =~ Reassignment_Input ]]; then
            continue
        fi
        if [[ "${file}" =~ Reassignment_Results ]]; then
            continue
        fi
        if [[ "${file}" =~ MDM_Lookup ]]; then
            continue
        fi
        if [[ "${file}" =~ ABM_MDMs ]]; then
            continue
        fi
        if [[ "${file}" =~ Devices_Details ]]; then
            continue
        fi
        
        csv_files+=("$file")
    done < <(find "${REPORTS_DIR}" -maxdepth 1 -name "*.csv" -type f 2>/dev/null | sort -r)
    
    if [[ ${#csv_files[@]} -eq 0 ]]; then
        error_exit "No suitable CSV files found in ${REPORTS_DIR}"
    fi
    
    log "INFO" "Found ${#csv_files[@]} CSV file(s):"
    for i in "${!csv_files[@]}"; do
        echo "  [$((i+1))] ${csv_files[$i]##*/}" >&2
    done
    
    echo -n "Select CSV file with serials (enter number): " >&2
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

####### THE JOB

log "INFO" "Starting reassignment CSV generator..."

input_csv=$(select_input_file)
log "INFO" "Processing: ${input_csv}"

# Extract serials from input (simple serial list, one per line)
declare -a device_ids
while IFS= read -r serial; do
    # Skip empty lines
    [[ -z "${serial}" ]] && continue
    
    # Trim whitespace and quotes
    serial=$(echo "${serial}" | tr -d '"' | xargs)
    [[ -z "${serial}" ]] && continue
    
    device_ids+=("${serial}")
done < "${input_csv}"

if [[ ${#device_ids[@]} -eq 0 ]]; then
    error_exit "No serials found in ${input_csv}"
fi

log "INFO" "Found ${#device_ids[@]} serial(s) to process"

####### Map serials to tokens locally
log "INFO" "Looking up current assignments locally..."

device_token_map="${TEMP_WORK_DIR}/device_token_map.txt"
> "${device_token_map}"

for serial in "${device_ids[@]}"; do
    # Search all MacSerials files for this serial
    match_line=$(grep "\"${serial}\"" "${REPORTS_DIR}"/MacSerials_* 2>/dev/null | head -1)
    
    if [[ -z "${match_line}" ]]; then
        log "WARN" "Serial ${serial} not found in local files"
        continue
    fi
    
    # grep returns: filename:line_content
    # Extract just the line content (after the colon and filename)
    line_content=$(echo "${match_line}" | sed 's/^[^:]*://')
    
    # Parse CSV: TokenName,ServerName,DeviceID,NewServerName
    # Column 1: TokenName, Column 2: ServerName, Column 3: DeviceID (serial)
    token_name=$(echo "${line_content}" | cut -d',' -f1 | tr -d '"' | xargs)
    current_server=$(echo "${line_content}" | cut -d',' -f2 | tr -d '"' | xargs)
    
    echo "${serial}|${token_name}|${current_server}" >> "${device_token_map}"
done

device_count=$(wc -l < "${device_token_map}")
log "INFO" "Found ${device_count} serial(s) in local records"

if [[ ${device_count} -eq 0 ]]; then
    error_exit "No serials found in local MacSerials files"
fi

####### Get unique tokens
unique_tokens_file="${TEMP_WORK_DIR}/unique_tokens.txt"
cut -d'|' -f2 "${device_token_map}" | sort -u > "${unique_tokens_file}"

####### Read tokens into array (avoids stdin redirect issue)
declare -a token_array
while IFS= read -r token_name; do
    [[ -z "${token_name}" ]] && continue
    token_array+=("${token_name}")
done < "${unique_tokens_file}"

####### Declare arrays OUTSIDE the loop
declare -a server_ids
declare -a server_names

####### For each token, get available MDM servers and prompt user
log "INFO" "Querying ABM for available MDM servers..."

for token_name in "${token_array[@]}"; do
    log "INFO" "Processing token: ${token_name}"
    
    # Get token
    stderr_file=$(mktemp /tmp/token_stderr.XXXXXX)
    trap "rm -f ${stderr_file}" RETURN
    
    access_token=$("${SCRIPT_DIR}/ABM_tokenManager.sh" get "${token_name}" 2>"${stderr_file}") || {
        log "ERROR" "Failed to get token for ${token_name}"
        cat "${stderr_file}" >&2
        rm -f "${stderr_file}"
        continue
    }
    
    rm -f "${stderr_file}"
    
    if [[ -z "${access_token}" ]]; then
        log "ERROR" "Empty access token for ${token_name}"
        continue
    fi
    
    log "INFO" "  Getting MDM servers..."
    
    # Get MDM servers
    mdm_servers=$(get_mdm_servers "${access_token}") || {
        log "ERROR" "get_mdm_servers failed for ${token_name}"
        continue
    }
    
    if [[ "${mdm_servers}" == "{}" ]] || [[ -z "${mdm_servers}" ]]; then
        log "ERROR" "No MDM servers returned for ${token_name}"
        continue
    fi
    
    log "INFO" "  Parsing MDM servers..."
    
    # Reset arrays for this iteration
    server_ids=()
    server_names=()
    
    # Parse servers to temp file to avoid subshell
    server_data_file="${TEMP_WORK_DIR}/servers_${token_name}.txt"
    echo "${mdm_servers}" | jq -r '.data[] | "\(.id)|\(.attributes.serverName)"' > "${server_data_file}" 2>/dev/null
    
    while IFS='|' read -r srv_id srv_name; do
        [[ -z "${srv_id}" ]] && continue
        [[ -z "${srv_name}" ]] && continue
        
        server_ids+=("${srv_id}")
        server_names+=("${srv_name}")
    done < "${server_data_file}"
    
    rm -f "${server_data_file}"
    
    log "INFO" "  Parsed ${#server_ids[@]} server(s)"
    
    if [[ ${#server_ids[@]} -eq 0 ]]; then
        log "WARN" "No MDM servers found for ${token_name}"
        continue
    fi
    
    # Show serials for this token
    log "INFO" "  Serials for ${token_name}:"
    serials_file="${TEMP_WORK_DIR}/serials_${token_name}.txt"
    grep "^[^|]*|${token_name}|" "${device_token_map}" > "${serials_file}" 2>/dev/null
    
    while IFS='|' read -r serial cur_token cur_server; do
        echo "    ${serial} (currently: ${cur_server})" >&2
    done < "${serials_file}"
    
    rm -f "${serials_file}"
    
    # Prompt user to select destination server
    log "INFO" "  Available MDM servers:"
    for i in "${!server_names[@]}"; do
        echo "    [$((i+1))] ${server_names[$i]}" >&2
    done
    
    echo -n "  Select destination server (enter number): " >&2
    read -r selection
    
    if ! [[ "${selection}" =~ ^[0-9]+$ ]] || [[ ${selection} -lt 1 ]] || [[ ${selection} -gt ${#server_names[@]} ]]; then
        log "WARN" "Invalid selection for ${token_name}, skipping"
        continue
    fi
    
    selected_server_id="${server_ids[$((selection-1))]}"
    selected_server_name="${server_names[$((selection-1))]}"
    
    log "INFO" "  Selected: ${selected_server_name}"
    
    # Store selection
    echo "${token_name}|${selected_server_id}|${selected_server_name}" >> "${TEMP_WORK_DIR}/selections.txt"
    
done

####### Build output reassignment CSV
output_csv="${REPORTS_DIR}/MDM_Reassignment_${DATE}.csv"
echo "TokenName,ServerName,DeviceID,NewServerName" > "${output_csv}"

if [[ ! -f "${TEMP_WORK_DIR}/selections.txt" ]]; then
    error_exit "No token selections made"
fi

# For each serial, find its token and output the reassignment line
# Sort by token name first (column 2)
sort -t'|' -k2 "${device_token_map}" | while IFS='|' read -r serial token_name current_server; do
    # Find this token in selections
    selection_line=$(grep "^${token_name}|" "${TEMP_WORK_DIR}/selections.txt" | head -1)
    
    if [[ -z "${selection_line}" ]]; then
        log "WARN" "No selection found for token ${token_name}, skipping serial ${serial}"
        continue
    fi
    
    selected_server_id=$(echo "${selection_line}" | cut -d'|' -f2)
    selected_server_name=$(echo "${selection_line}" | cut -d'|' -f3)
    
    # Output: TokenName,ServerName,DeviceID,NewServerName
    echo "\"${token_name}\",\"${current_server}\",\"${serial}\",\"${selected_server_name}\"" >> "${output_csv}"
done

output_lines=$(tail -n +2 "${output_csv}" | wc -l)

####### Summary
cat << EOF

========================================
  REASSIGNMENT CSV GENERATED
========================================
Input Serials:    ${#device_ids[@]}
Output Serials:   ${output_lines}
Output File:      ${output_csv}
========================================

Ready to run: ./API_POST_SerialMDM.sh

EOF

log "INFO" "CSV generation complete!"


