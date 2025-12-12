#!/bin/bash

####### Description and Notes
# Apple ABM/ASM API - Exchange JWT for Access Token
# Adapted from https://github.com/cantscript/AxM_API
# Updated to work with ABM_tokenManager.sh for multi-token support
# 2025 12 10 MK Initial Commmit

set -euo pipefail

####### Debug Mode
DEBUG="${DEBUG:-0}"
debug() {
    if [[ "${DEBUG}" == "1" ]]; then
        echo "DEBUG: $*" >&2
    fi
}

####### Parse Arguments
if [[ $# -lt 3 ]]; then
    echo "ERROR: Invalid arguments" >&2
    echo "Usage: $0 <client_assertion_jwt> <client_id> <scope>" >&2
    exit 1
fi

client_assertion="$1"
client_id="$2"
scope="${3:-business.api}"

debug "Starting ABM_create_access_token.sh"
debug "Client ID: ${client_id}"
debug "Scope: ${scope}"

####### Validation
if [[ -z "${client_assertion}" ]]; then
    echo "ERROR: Client assertion (JWT) is empty" >&2
    exit 1
fi

# Basic JWT format check (3 parts separated by dots)
if [[ ! "${client_assertion}" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]; then
    echo "ERROR: Invalid JWT format" >&2
    exit 1
fi

if [[ -z "${client_id}" ]]; then
    echo "ERROR: Client ID is empty" >&2
    exit 1
fi

for tool in curl jq; do
    if ! command -v "$tool" &> /dev/null; then
        echo "ERROR: Required tool not found: $tool" >&2
        exit 1
    fi
done

####### Configuration
token_endpoint="https://account.apple.com/auth/oauth2/token"

####### Exchange JWT for Access Token
debug "Exchanging JWT for access token"

# Make request using the EXACT same format as the working original
# Note: client_assertion_type (with "client-" prefix) is CRITICAL!
response=$(curl -s -X POST \
    -H 'Host: account.apple.com' \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    "${token_endpoint}?grant_type=client_credentials&client_id=${client_id}&client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer&client_assertion=${client_assertion}&scope=${scope}" \
    -w "\n%{http_code}")

# Parse response - use sed '$d' for macOS compatibility
http_code=$(echo "$response" | tail -n1)
response_body=$(echo "$response" | sed '$d')

debug "HTTP Status: ${http_code}"
debug "Response: ${response_body:0:150}..."

####### Validate Response
if [[ "${http_code}" != "200" ]]; then
    echo "ERROR: Token endpoint returned HTTP ${http_code}" >&2
    echo "Response: ${response_body}" >&2
    exit 1
fi

# Validate JSON response
if ! echo "${response_body}" | jq empty 2>/dev/null; then
    echo "ERROR: Invalid JSON response from token endpoint" >&2
    echo "Response: ${response_body}" >&2
    exit 1
fi

# Check for OAuth error in response
if echo "${response_body}" | jq -e '.error' &>/dev/null; then
    error=$(echo "${response_body}" | jq -r '.error')
    error_desc=$(echo "${response_body}" | jq -r '.error_description // "No description"')
    echo "ERROR: OAuth error: ${error} - ${error_desc}" >&2
    exit 1
fi

# Validate we got an access token
if ! echo "${response_body}" | jq -e '.access_token' &>/dev/null; then
    echo "ERROR: No access_token in response" >&2
    echo "Response: ${response_body}" >&2
    exit 1
fi

####### Extract and Format Output
access_token=$(echo "${response_body}" | jq -r '.access_token')
expires_in=$(echo "${response_body}" | jq -r '.expires_in // 3600')
token_type=$(echo "${response_body}" | jq -r '.token_type // "Bearer"')

# Calculate expiration timestamp
exp_time=$(($(date +%s) + expires_in))

debug "Access token obtained, expires in ${expires_in} seconds"

####### Output as JSON
output=$(jq -nc \
    --arg access_token "$access_token" \
    --argjson exp_time "$exp_time" \
    --arg token_type "$token_type" \
    --argjson expires_in "$expires_in" \
    '{access_token: $access_token, exp_time: $exp_time, token_type: $token_type, expires_in: $expires_in}')

echo "$output"

