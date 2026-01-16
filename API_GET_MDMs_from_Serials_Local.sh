#!/bin/bash

set -euo pipefail

####### Description and Notes
# Query LOCAL MacSerials_* files to find which MDM server each device is assigned to
# No API calls - pure local file operations
# Reads a CSV of device serials/IDs
# Searches local MacSerials_* CSV files for device assignments
# 2025 01 16 MK ABM MDM Server Lookup - LOCAL ONLY (NO API)

####### VARIABLES
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORTS_DIR="${SCRIPT_DIR}/REPORTS"
DATE=$(date +%Y%m%d_%H%M%S)
TEMP_WORK_DIR="/tmp/mdm_lookup_local_${DATE}"

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

####### Find device in MacSerials files and extract server info
find_device_local() {
    local device_id="$1"
    
    # Search all MacSerials files for the device ID (accounting for quotes)
    local match_file
    match_file=$(grep -l "\"${device_id}\"" "${REPORTS_DIR}"/MacSerials_* 2>/dev/null | head -1)
    
    if [[ -z "${match_file}" ]]; then
        return 1
    fi
    
    # Extract the line with this device
    local match_line
    match_line=$(grep "\"${device_id}\"" "${match_file}" | head -1)
    
    if [[ -z "${match_line}" ]]; then
        return 1
    fi
    
    # Parse CSV fields: TokenName,ServerName,DeviceID,NewServerName
    # Remove quotes and extract each field
    local token_name
    local server_name
    
    token_name=$(echo "${match_line}" | cut -d',' -f1 | tr -d '"' | xargs)
    server_name=$(echo "${match_line}" | cut -d',' -f2 | tr -d '"' | xargs)
    
    # Output as pipe-delimited: token|server
    echo "${token_name}|${server_name}"
    return 0
}

####### THE JOB

log "INFO" "Starting device MDM server lookup (LOCAL MODE - NO API)..."

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

####### Output file
output_csv="${REPORTS_DIR}/MDM_Lookup_Results_LOCAL_${DATE}.csv"
echo "DeviceID,TokenName,AssignedMDMServer,Status,Details" > "${output_csv}"

success_count=0
failure_count=0

log "INFO" "Searching local MacSerials files..."

####### Process each device
for device_id in "${device_ids[@]}"; do
    device_info=$(find_device_local "${device_id}") || {
        log "WARN" "Device ${device_id} not found in local MacSerials files"
        echo "${device_id},,UNKNOWN,NOT_FOUND,Device not in local records" >> "${output_csv}"
        failure_count=$((failure_count+1))
        continue
    }
    
    # Parse result: token|server
    token_name=$(echo "${device_info}" | cut -d'|' -f1)
    server_name=$(echo "${device_info}" | cut -d'|' -f2)
    
    if [[ -z "${token_name}" ]] || [[ -z "${server_name}" ]]; then
        log "WARN" "Device ${device_id} found but parse failed"
        echo "${device_id},,PARSE_ERROR,ERROR,Failed to parse device record" >> "${output_csv}"
        failure_count=$((failure_count+1))
        continue
    fi
    
    log "INFO" "✓ ${device_id} → ${server_name} (${token_name})"
    echo "${device_id},${token_name},${server_name},SUCCESS," >> "${output_csv}"
    success_count=$((success_count+1))
done

####### Summary
cat << EOF

========================================
  MDM LOOKUP SUMMARY (LOCAL)
========================================
Total Devices:   ${#device_ids[@]}
Successful:      ${success_count}
Failed:          ${failure_count}
Results:         ${output_csv}
========================================

EOF

log "INFO" "Lookup complete!"



