#!/bin/bash

####### Description and Notes
# Multi-token management for ABM API
# Manages creation and caching of client assertions and access tokens from input file
# 2025 12 10 MK Initial Commmit

####### Usage
# ./tokenManager.sh get_token $TOKEN_NAME
# ./tokenManager.sh list
# ./tokenManager.sh validate
# ./tokenManager.sh clear $TOKEN_NAME (or leave blank for all)

set -euo pipefail

####### VARIABLES
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config/token_config.env"
TOKEN_CACHE_DIR="${SCRIPT_DIR}/tokens"
TOKEN_EXPIRY_THRESHOLD=300  # Refresh if less than 5 mins remaining
DEBUG="${DEBUG:-0}"  # Set DEBUG=1 for verbose output

# Ensure directories exist
mkdir -p "${TOKEN_CACHE_DIR}"

####### Functions
log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*" >&2
}

debug() {
    if [[ "${DEBUG}" == "1" ]]; then
        log "DEBUG" "$@"
    fi
}

error_exit() {
    log "ERROR" "$@"
    exit 1
}

####### Parse Token Configuration
get_token_config() {
    local token_name="$1"
    
    debug "Looking for token config: ${token_name}"
    
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        error_exit "Config file not found in /config: ${CONFIG_FILE}"
    fi
    
    local config_line
    config_line=$(grep "^${token_name}|" "${CONFIG_FILE}" | head -1)
    
    if [[ -z "${config_line}" ]]; then
        error_exit "Token configuration not found: ${token_name}"
    fi
    
    debug "Config line found: ${config_line}"
    
    # Parse: NAME|PEM_PATH|CLIENT_ID|KEY_ID
    IFS='|' read -r name pem_path client_id key_id <<< "${config_line}"
    
    # Cleanup
    pem_path="${pem_path#"${pem_path%%[![:space:]]*}"}"
    pem_path="${pem_path%"${pem_path##*[![:space:]]}"}"
    client_id="${client_id#"${client_id%%[![:space:]]*}"}"
    client_id="${client_id%"${client_id##*[![:space:]]}"}"
    key_id="${key_id#"${key_id%%[![:space:]]*}"}"
    key_id="${key_id%"${key_id##*[![:space:]]}"}"
    
    debug "Parsed - Name: ${name}, PEM: ${pem_path}, Client: ${client_id}, Key: ${key_id}"
    
    # Expand relative paths
    if [[ "${pem_path}" != /* ]]; then
        pem_path="${SCRIPT_DIR}/${pem_path}"
    fi
    
    # Normalize the path (remove /./ sequences)
    pem_path=$(echo "${pem_path}" | sed 's|/\./|/|g')
    
    debug "Expanded PEM path: ${pem_path}"
    
    # Validate PEM exists
    if [[ ! -f "${pem_path}" ]]; then
        error_exit "PEM file not found: ${pem_path}"
    fi
    
    # Validate we have all required values
    if [[ -z "${client_id}" ]] || [[ -z "${key_id}" ]]; then
        error_exit "Invalid config: missing client_id or key_id"
    fi
    
    echo "${pem_path}|${client_id}|${key_id}"
}

####### Token Caching and Validity
token_cache_path() {
    local token_name="$1"
    local token_type="$2"  # "client" or "access"
    echo "${TOKEN_CACHE_DIR}/${token_name}_${token_type}.json"
}

is_token_valid() {
    local cache_file="$1"
    
    if [[ ! -f "${cache_file}" ]]; then
        debug "Token cache file not found: ${cache_file}"
        return 1
    fi
    
    # Extract expiration time (depends on token structure)
    local exp_time
    exp_time=$(jq -r '.exp_time // .expires_at // empty' "${cache_file}" 2>/dev/null || echo "0")
    
    if [[ -z "${exp_time}" ]] || [[ "${exp_time}" == "0" ]]; then
        debug "No expiration time found in cache"
        return 1
    fi
    
    local current_time
    current_time=$(date +%s)
    local time_remaining=$((exp_time - current_time))
    
    debug "Token expires in ${time_remaining} seconds"
    
    if [[ ${time_remaining} -gt ${TOKEN_EXPIRY_THRESHOLD} ]]; then
        return 0
    fi
    
    return 1
}

####### Create Client Assertion - WIP
create_client_assertion() {
    local token_name="$1"
    local pem_path client_id key_id
    
    IFS='|' read -r pem_path client_id key_id <<< "$(get_token_config "${token_name}")"
    
    local cache_file
    cache_file=$(token_cache_path "${token_name}" "client")
    
    # Check if cached token is still valid
    if is_token_valid "${cache_file}"; then
        log "INFO" "Using cached client assertion for ${token_name}"
        cat "${cache_file}" | jq -r '.token'
        return 0
    fi
    
    log "INFO" "Generating new client assertion for ${token_name}"
    debug "Using PEM: ${pem_path}"
    debug "Using CLIENT_ID: ${client_id}"
    debug "Using KEY_ID: ${key_id}"
    
    if [[ ! -f "${SCRIPT_DIR}/ABM_create_client_assertion.sh" ]]; then
        error_exit "ABM_create_client_assertion.sh not found"
    fi
    
    local client_assertion
    local stderr_file stderr_content
    stderr_file=$(mktemp /tmp/ca_stderr.XXXXXX)
    trap "rm -f $stderr_file" RETURN
    
    # Capture stdout only, redirect stderr to temp file
    client_assertion=$("${SCRIPT_DIR}/ABM_create_client_assertion.sh" \
        "${pem_path}" \
        "${client_id}" \
        "${key_id}" 2>"$stderr_file") || {
        
        stderr_content=$(cat "$stderr_file")
        debug "ABM_create_client_assertion.sh stderr: ${stderr_content}"
        error_exit "Failed to create client assertion for ${token_name}"
    }
    
    debug "Client assertion generated successfully (${#client_assertion} chars)"
    
    # Validate JSON response
    if ! echo "${client_assertion}" | jq empty 2>/dev/null; then
        debug "Invalid JSON response: ${client_assertion:0:100}"
        error_exit "ABM_create_client_assertion.sh returned invalid JSON"
    fi
    
    # Cache the full JSON response
    echo "${client_assertion}" > "${cache_file}"
    
    # Return just the token
    echo "${client_assertion}" | jq -r '.token'
}

####### Create Access Token - WIP
create_access_token() {
    local token_name="$1"
    
    local cache_file
    cache_file=$(token_cache_path "${token_name}" "access")
    
    # Check if cached token is still valid
    if is_token_valid "${cache_file}"; then
        log "INFO" "Using cached access token for ${token_name}"
        cat "${cache_file}" | jq -r '.access_token'
        return 0
    fi
    
    log "INFO" "Generating new access token for ${token_name}"
    
    if [[ ! -f "${SCRIPT_DIR}/ABM_create_access_token.sh" ]]; then
        error_exit "ABM_create_access_token.sh not found"
    fi
    
    # Get config values for this token
    local pem_path client_id key_id
    IFS='|' read -r pem_path client_id key_id <<< "$(get_token_config "${token_name}")"
    
    # Get the client assertion JWT
    local client_assertion
    client_assertion=$(create_client_assertion "${token_name}")
    
    debug "Retrieved client assertion (${#client_assertion} chars)"
    
    local scope="business.api"
    
    # Capture stdout only, redirect stderr to temp file
    # Kept reporting stderr as the JSON :-(
    local access_token
    local stderr_file stderr_content
    stderr_file=$(mktemp /tmp/cat_stderr.XXXXXX)
    trap "rm -f $stderr_file" RETURN
    
    access_token=$("${SCRIPT_DIR}/ABM_create_access_token.sh" \
        "${client_assertion}" \
        "${client_id}" \
        "${scope}" 2>"$stderr_file") || {
        
        stderr_content=$(cat "$stderr_file")
        debug "ABM_create_access_token.sh stderr: ${stderr_content}"
        error_exit "Failed to create access token for ${token_name}"
    }
    
    debug "Access token generated (${#access_token} chars)"
    
    # Validate JSON
    if ! echo "${access_token}" | jq empty 2>/dev/null; then
        debug "Invalid JSON response: ${access_token:0:100}"
        error_exit "ABM_create_access_token.sh returned invalid JSON"
    fi
    
    # Cache the full response
    echo "${access_token}" > "${cache_file}"
    
    # Return just the access token
    echo "${access_token}" | jq -r '.access_token'
}

####### Get Named Token (Public Interface)
get_token() {
    local token_name="$1"
    
    # This returns the access token for use in API calls
    create_access_token "${token_name}"
}

####### List Available Tokens

list_tokens() {
    log "INFO" "Available tokens:"
    awk -F'|' 'NF>=2 {print "  - " $1 " (Client: " $3 ")"}' "${CONFIG_FILE}"
}

####### Validate Configuration
validate_config() {
    log "INFO" "Validating configuration..."
    
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        error_exit "Config file not found: ${CONFIG_FILE}"
    fi
    
    log "INFO" "Config file: ${CONFIG_FILE}"
    
    local count=0
    while IFS='|' read -r name pem_path client_id key_id; do
        # Skip comments and empty lines
        [[ "${name}" =~ ^#.*$ ]] && continue
        [[ -z "${name}" ]] && continue
        
        # Cleanup
        name="${name#"${name%%[![:space:]]*}"}"
        name="${name%"${name##*[![:space:]]}"}"
        
        count=$((count + 1))
        
        # Expand relative paths
        local expanded_pem="${pem_path}"
        if [[ "${expanded_pem}" != /* ]]; then
            expanded_pem="${SCRIPT_DIR}/${expanded_pem}"
        fi
        
        log "INFO" "  [$count] ${name}"
        
        if [[ -f "${expanded_pem}" ]]; then
            log "INFO" "      ✓ PEM file exists"
        else
            log "ERROR" "      ✗ PEM file not found: ${expanded_pem}"
        fi
        
        if [[ -n "${client_id}" ]]; then
            log "INFO" "      ✓ Client ID configured"
        else
            log "ERROR" "      ✗ Missing Client ID"
        fi
        
        if [[ -n "${key_id}" ]]; then
            log "INFO" "      ✓ Key ID configured"
        else
            log "ERROR" "      ✗ Missing Key ID"
        fi
        
    done < "${CONFIG_FILE}"
    
    if [[ ${count} -eq 0 ]]; then
        error_exit "No valid configurations found"
    fi
    log "INFO" "Configuration validation complete"
}

####### Clear Token Cache
clear_cache() {
    local token_name="${1:-}"
    
    if [[ -z "${token_name}" ]]; then
        log "INFO" "Clearing all cached tokens"
        rm -f "${TOKEN_CACHE_DIR}"/*.json
    else
        log "INFO" "Clearing cached tokens for ${token_name}"
        rm -f "${TOKEN_CACHE_DIR}/${token_name}"_*.json
    fi
}

####### THE JOB
main() {
    local command="${1:-}"
    
    case "${command}" in
        get|token)
            [[ -z "${2:-}" ]] && error_exit "Usage: $0 get <token_name>"
            get_token "$2"
            ;;
        list)
            list_tokens
            ;;
        validate)
            validate_config
            ;;
        clear)
            clear_cache "${2:-}"
            ;;
        *)
            cat <<EOF
Usage: $0 <command> [options]

Commands:
  get <name>       Get access token for named configuration
  list             List all available token configurations
  validate         Validate configuration file and PEM files
  clear [name]     Clear token cache (all if no name specified)

Environment Variables:
  DEBUG=1          Enable verbose debugging output

Examples:
  $0 get omc
  $0 list
  $0 validate
  $0 clear omc
  DEBUG=1 $0 get omc

EOF
            exit 1
            ;;
    esac
}

main "$@"

