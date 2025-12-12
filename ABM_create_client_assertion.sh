#!/bin/zsh

####### Description and Notes
# zsh version of Implementing OAuth for the Apple School and Business Manager API
# Adapted from https://github.com/cantscript/AxM_API
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
if [[ $# -ne 3 ]]; then
    echo "ERROR: Invalid arguments" >&2
    echo "Usage: $0 <pem_file_path> <client_id> <key_id>" >&2
    exit 1
fi

private_key_file="$1"
client_id="$2"
key_id="$3"
team_id="$client_id"

debug "Starting ABM_create_client_assertion.sh"

####### Validation
if [[ ! -f "${private_key_file}" ]]; then
    echo "ERROR: Private key file not found: ${private_key_file}" >&2
    exit 1
fi

if [[ -z "${client_id}" ]] || [[ -z "${key_id}" ]]; then
    echo "ERROR: Client ID or Key ID are missing" >&2
    exit 1
fi

for tool in openssl jq uuidgen xxd; do
    if ! command -v "$tool" &> /dev/null; then
        echo "ERROR: Required tool not found: $tool" >&2
        exit 1
    fi
done

####### Configuration
audience="https://account.apple.com/auth/oauth2/v2/token"
alg="ES256"

iat=$(date -u +%s)
exp=$((iat + 86400 * 180))
jti=$(uuidgen)

####### Helper Functions
b64url() {
    echo -n "$1" | openssl base64 -e -A | tr '+/' '-_' | tr -d '='
}

pad64() {
    local hex="$1"
    printf "%064s" "$hex" | tr ' ' 0
}

####### Generate JWT
header=$(jq -nc --arg alg "$alg" --arg kid "$key_id" '{alg: $alg, kid: $kid, typ: "JWT"}')
payload=$(jq -nc \
    --arg sub "$client_id" \
    --arg aud "$audience" \
    --argjson iat "$iat" \
    --argjson exp "$exp" \
    --arg jti "$jti" \
    --arg iss "$team_id" \
    '{sub: $sub, aud: $aud, iat: $iat, exp: $exp, jti: $jti, iss: $iss}')

header_b64=$(b64url "$header")
payload_b64=$(b64url "$payload")
signing_input="${header_b64}.${payload_b64}"

####### Create temporary file for signature
sigfile=$(mktemp /tmp/sig.der.XXXXXX)
trap "rm -f $sigfile" EXIT

debug "Signing with openssl..."

####### Sign using EC private key
echo -n "$signing_input" | openssl dgst -sha256 -sign "${private_key_file}" > "$sigfile" 2>/dev/null || {
    echo "ERROR: Failed to sign with private key" >&2
    exit 1
}

####### Extract R and S - SIMPLIFIED VERSION!!!
# REALLY! This was a bugger to variablised inputs!
debug "Extracting R and S from signature..."

####### Get the two INTEGER lines and extract hex values 
#Use sed to extract only the hex value portion
asn1_output=$(openssl asn1parse -in "$sigfile" -inform DER 2>/dev/null | grep "INTEGER")

####### Extract first INTEGER (R)
r_hex=$(echo "$asn1_output" | head -n1 | sed 's/.*://;s/^[[:space:]]*//;s/[[:space:]]*$//')
debug "R hex: ${r_hex:0:32}..."

####### Extract second INTEGER (S)
s_hex=$(echo "$asn1_output" | tail -n1 | sed 's/.*://;s/^[[:space:]]*//;s/[[:space:]]*$//')
debug "S hex: ${s_hex:0:32}..."

####### Validate we got both
if [[ -z "$r_hex" ]] || [[ -z "$s_hex" ]]; then
    echo "ERROR: Failed to extract R and S from signature" >&2
    echo "R: '$r_hex'" >&2
    echo "S: '$s_hex'" >&2
    exit 1
fi

####### Pad to 64 hex chars (32 bytes)
r=$(pad64 "$r_hex")
s=$(pad64 "$s_hex")

debug "R padded: ${r:0:32}..."
debug "S padded: ${s:0:32}..."

####### Convert to base64url
rs_b64url=$(echo "$r$s" | xxd -r -p | openssl base64 -A | tr '+/' '-_' | tr -d '=')

debug "RS B64URL: ${rs_b64url:0:32}..."

####### Form the completed JWT
jwt="${signing_input}.${rs_b64url}"

debug "JWT created (${#jwt} chars)"

####### Output JWT as JSON
output=$(jq -nc \
    --arg token "$jwt" \
    --argjson exp_time "$exp" \
    '{token: $token, exp_time: $exp_time, expires_at: ($exp_time | tostring)}')

echo "$output"

