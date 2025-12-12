#!/bin/bash

set -euo pipefail

####### Description and Notes
# Make multiple API calls against multiple ABM servers!
# First version, report all MDM servers in all ABMs 
# 2025 12 10 MK Initial Commmit

####### VARIABLES
# Need the scripts to handle tokens!
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOKEN_CONFIG="${SCRIPT_DIR}/config/token_config.env"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT="${SCRIPT_DIR}/REPORTS/ABM_MDMs_${TIMESTAMP}.csv"

####### Call ABM API with Token
call_abm_api() {
    local access_token="$1"
    local method="${2:-GET}"
    local endpoint="$3"
    
    if [[ -z "${access_token}" ]] || [[ -z "${endpoint}" ]]; then
        echo "ERROR: Usage: call_abm_api <access_token> [method] <endpoint>" >&2
        return 1
    fi
    
    # Make API call to Apple Business Manager API
    curl -s -k \
        -X "${method}" \
        -H "Authorization: Bearer ${access_token}" \
        -H "Accept: application/json" \
        "https://api-business.apple.com${endpoint}"
}

####### THE JOB
# Validate token config exists
if [[ ! -f "${TOKEN_CONFIG}" ]]; then
    echo "Error: Token config file not found: ${TOKEN_CONFIG}" >&2
    exit 1
fi

####### Validate ABM_tokenManager.sh exists
if [[ ! -f "${SCRIPT_DIR}/ABM_tokenManager.sh" ]]; then
    echo "ERROR: ABM_tokenManager.sh not found in ${SCRIPT_DIR}" >&2
    exit 1
fi

####### Declare associative array for tokens (Bash 3.2 compatible - using parallel arrays)
declare -a token_names
declare -a token_tokens

echo "Retrieving all access tokens..." >&2

####### Phase 1: 
# Get all tokens upfront - FAIL if ANY fail
while IFS='|' read -r token_name pem_path client_id key_id; do
    # Skip comments and empty lines
    [[ "${token_name}" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${token_name}" ]] && continue
    
    # Cleanup
    token_name=$(echo "${token_name}" | xargs)

    echo -n " Getting token for ${token_name}..." >&2
    
    # Get access token - SEPARATE STDOUT FROM STDERR
    access_token=""
    stderr_output=""
    stderr_file=$(mktemp /tmp/token_stderr.XXXXXX)
    trap "rm -f ${stderr_file}" RETURN
    
    # Capture stdout to variable, stderr to file
    access_token=$("${SCRIPT_DIR}/ABM_tokenManager.sh" get "${token_name}" 2>"${stderr_file}") || {
        stderr_output=$(cat "${stderr_file}")
        echo " FAILED" >&2
        echo "ERROR: Failed to get access token for ${token_name}" >&2
        echo "Stderr: ${stderr_output}" >&2
        exit 1
    }
    
    # Also check if token is empty
    if [[ -z "${access_token}" ]]; then
        stderr_output=$(cat "${stderr_file}")
        echo " FAILED" >&2
        echo "ERROR: Empty access token for ${token_name}" >&2
        echo "Stderr: ${stderr_output}" >&2
        exit 1
    fi
    
    echo " OK (${#access_token} chars)" >&2
    
    # Store for later use
    token_names+=("${token_name}")
    token_tokens+=("${access_token}")
    
done < "${TOKEN_CONFIG}"

####### Check if we got any tokens
if [[ ${#token_names[@]} -eq 0 ]]; then
    echo "ERROR: No valid tokens found in ${TOKEN_CONFIG}" >&2
    exit 1
fi

echo "Successfully retrieved ${#token_names[@]} access tokens" >&2

####### Phase 2: 
# Initialize report with headers
echo "TokenName,ServerName,Type,ID" > "${REPORT}"

####### Phase 3: 
# Fetch MDM servers for each token
for i in "${!token_names[@]}"; do
    token_name="${token_names[$i]}"
    access_token="${token_tokens[$i]}"
    
    echo "Processing MDM servers for: ${token_name}" >&2
    
    # Call the API with the access token
    body=$(call_abm_api "${access_token}" GET "/v1/mdmServers")
    
    # Check if we got valid JSON
    if ! echo "${body}" | jq empty 2>/dev/null; then
        echo "  Warning: Invalid JSON response" >&2
        continue
    fi
    
    # Extract and add token name to each row
    data_count=$(echo "${body}" | jq '.data | length' 2>/dev/null || echo "0")
    echo " Found ${data_count} MDM servers" >&2
    
    if [[ "${data_count}" -gt 0 ]]; then
        echo "${body}" | jq -r \
            --arg token "${token_name}" \
            '.data[] | [$token, .attributes.serverName, .type, .id] | @csv' \
            >> "${REPORT}"
    fi
done

echo "" >&2
echo "MDM servers report saved to: ${REPORT}" >&2
wc -l "${REPORT}" >&2
echo "" >&2



