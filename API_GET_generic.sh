#!/bin/bash

####### Description and Notes
# Geneic script for a single ABM pull
# 2025 12 10 MK Initial Commmit

####### Usage
# ./API_GET_generic.sh $1 $2 $3
# 1=$TOKEN_NAME 
# 2=APICALL (default GET)
# 3=API Endpoint, ie /v1/mdmServers

set -euo pipefail

####### Varibles
# The one important one to find all the other scripts
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

####### Get Token and Make API Call
call_abm_api() {
    local token_name="$1"
    local method="${2:-GET}"
    local endpoint="$3"
    
    if [[ -z "${token_name}" ]] || [[ -z "${endpoint}" ]]; then
        echo "ERROR: Usage: $0 <token_name> [method] <endpoint>" >&2
        echo "Example: $0 omc GET /v1/mdmServers" >&2
        exit 1
    fi
    
    # Get access token
    local access_token
    access_token=$("${SCRIPT_DIR}/ABM_tokenManager.sh" get "${token_name}")
    
    if [[ -z "${access_token}" ]]; then
        echo "ERROR: Failed to get access token for ${token_name}" >&2
        exit 1
    fi
    
    # Make API call to Apple Business Manager API
    curl -s -k \
        -X "${method}" \
        -H "Authorization: Bearer ${access_token}" \
        -H "Accept: application/json" \
        "https://api-business.apple.com${endpoint}"
}

# Main
call_abm_api "$@"

