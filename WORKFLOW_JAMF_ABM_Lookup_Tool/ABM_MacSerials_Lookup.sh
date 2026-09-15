#!/bin/bash
set -euo pipefail

################################################################################
# ABM Serial Lookup Tool
#
# 2026-09-15 MK Initial Public Commit
################################################################################

DATE=$(date +%Y%m%d-%H%M)

CSV_DIR="/tmp/AxM"
CSV_PATTERN="${CSV_DIR}/ALL_ABM_MacSerials_*.csv"

LOGGED_IN_USER=$(/bin/ls -la /dev/console | awk '{print $3}')
CURRENT_HOME=$(/usr/bin/dscl . -read "/Users/${LOGGED_IN_USER}" NFSHomeDirectory | awk '{print $NF}')

REPORT_DIR="${CURRENT_HOME}/Downloads/JAMF API Reports"
REPORT_FILE="${REPORT_DIR}/ABM_Lookup_Report_${DATE}.csv"

TEMP_DIR=$(mktemp -d)

MAX_RETRIES=3
RETRY_COUNT=0
POLICY_ID="123" 
# Jamf policy to run script to install latest /tmp/ALL_ABM_MacSerials_*.csv
# Runs if CSV is missing

################################################################################
# FUNCTIONS
################################################################################

log_info() {
    echo "[INFO] $*" >&2
}

log_error() {
    echo "[ERROR] $*" >&2
}

cleanup() {
    rm -rf "${TEMP_DIR}"
}

trap cleanup EXIT

################################################################################
# CHECK CSV EXISTS
################################################################################

check_csv_exists() {

    log_info "Checking for combined CSV..."

    while [[ ${RETRY_COUNT} -lt ${MAX_RETRIES} ]]; do

        if ls ${CSV_PATTERN} >/dev/null 2>&1; then
            CSV_FILE=$(ls -t ${CSV_PATTERN} | head -1)
            log_info "Found CSV: ${CSV_FILE##*/}"
            return 0
        fi

        RETRY_COUNT=$((RETRY_COUNT + 1))

        if [[ ${RETRY_COUNT} -lt ${MAX_RETRIES} ]]; then
            log_info "CSV not found. Triggering policy ${POLICY_ID}..."
            /usr/local/jamf/bin/jamf policy -id "${POLICY_ID}"
            sleep 3
        fi
    done

    log_error "CSV not found after ${MAX_RETRIES} attempts"
    return 1
}

################################################################################
# ICON
################################################################################

setup_jamf_icon() {
    local icon_file="${TEMP_DIR}/jamf_icon.png"
    local icon_url="https://github.com/markkenny/axm-juggler/blob/main/images/icon.jpg"
    local fallback_icon="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericQuestionMarkIcon.icns"

    if curl -sSLf -o "${icon_file}" "${icon_url}" 2>/dev/null && [[ -s "${icon_file}" ]]; then
        echo "${icon_file}"
    elif [[ -f "${fallback_icon}" ]]; then
        rm -f "${icon_file}"
        echo "${fallback_icon}"
    fi
}

################################################################################
# INPUT
################################################################################

select_input_file() {

    local icon_path="${1:-}"
    local icon_clause="with icon note"

    if [[ -f "${icon_path}" ]]; then
        icon_clause="with icon POSIX file \"${icon_path}\""
    fi

    local user_input

    user_input=$(/usr/bin/osascript <<OSASCRIPT
set userResponse to display dialog ¬
"Enter a CSV file path or a single serial number:" ¬
default answer "" ¬
buttons {"Cancel", "OK"} ¬
default button "OK" ¬
with title "ABM Lookup Tool" ¬
${icon_clause}

if button returned of userResponse is "Cancel" then
    error number -128
end if

return text returned of userResponse
OSASCRIPT
) || exit 0

    user_input="${user_input#\"}"
    user_input="${user_input%\"}"

    [[ -z "${user_input}" ]] && exit 1

    if [[ "${user_input}" == *.csv ]]; then

        [[ ! -f "${user_input}" ]] && {
            log_error "Input CSV not found"
            exit 1
        }

        echo "${user_input}"

    else

        [[ ! "${user_input}" =~ ^[A-Za-z0-9]{8,20}$ ]] && {
            log_error "Invalid serial format"
            exit 1
        }

        local temp_csv="${TEMP_DIR}/single_serial.csv"

        {
            echo "Serial"
            echo "${user_input}"
        } > "${temp_csv}"

        echo "${temp_csv}"
    fi
}

################################################################################
# LOOKUP
################################################################################

lookup_serial() {

    local serial="$1"
    local lookup_file="$2"

    awk -F',' -v serial="${serial}" '
    {
        gsub(/\r/, "", $0)

        serial_col=$2
        gsub(/"/, "", serial_col)

        if (serial_col == serial)
        {
            print
            exit
        }
    }
    ' "${lookup_file}"
}

################################################################################
# MAIN
################################################################################

START_TIME=$(date +%s)
log_info "Let us begin $(date '+%H:%M:%S')"
if ! check_csv_exists; then
    exit 1
fi

mkdir -p "${REPORT_DIR}"

JAMF_ICON=$(setup_jamf_icon || true)

log_info "Prompting user for input..."

INPUT_FILE=$(select_input_file "${JAMF_ICON}")

SERIAL_COUNT=$(
tail -n +2 "${INPUT_FILE}" \
| tr -d '\r' \
| grep -v '^[[:space:]]*$' \
| wc -l \
| xargs
)

log_info "Processing ${SERIAL_COUNT} serial(s)..."

COUNT=0

{
    echo "TokenName,ServerName,DeviceID,NewServerName"

    tail -n +2 "${INPUT_FILE}" \
    | tr -d '\r' \
    | grep -v '^[[:space:]]*$' \
    | while IFS= read -r line
    do

        COUNT=$((COUNT + 1))

        if (( COUNT % 50 == 0 )); then
            log_info "Processed ${COUNT}/${SERIAL_COUNT}"
        fi

        SERIAL=$(printf '%s' "${line}" \
            | cut -d',' -f1 \
            | tr -d '"' \
            | xargs)

        [[ -z "${SERIAL}" ]] && continue

        if LOOKUP_RESULT=$(lookup_serial "${SERIAL}" "${CSV_FILE}"); then

            if [[ -n "${LOOKUP_RESULT}" ]]; then

                LOOKUP_RESULT=$(printf '%s' "${LOOKUP_RESULT}" | tr -d '\r')

                TOKEN_NAME=$(echo "${LOOKUP_RESULT}" | cut -d',' -f1 | tr -d '"')
                DEVICE_ID=$(echo "${LOOKUP_RESULT}" | cut -d',' -f2 | tr -d '"')
                SERVER_NAME=$(echo "${LOOKUP_RESULT}" | cut -d',' -f3 | tr -d '"')

                echo "\"${TOKEN_NAME}\",\"${SERVER_NAME}\",\"${DEVICE_ID}\",\"My Jamf Server\""

            else

                echo "\"NOT FOUND\",\"NOT FOUND\",\"${SERIAL}\",\"NOT FOUND\""

            fi

        else

            echo "\"NOT FOUND\",\"NOT FOUND\",\"${SERIAL}\",\"NOT FOUND\""

        fi

    done

} > "${REPORT_FILE}"

################################################################################
# COUNTS
################################################################################

FOUND_COUNT=$(
tail -n +2 "${REPORT_FILE}" \
| grep -vc '^"NOT FOUND"' \
|| true
)

NOT_FOUND_COUNT=$(
tail -n +2 "${REPORT_FILE}" \
| grep -c '^"NOT FOUND"' \
|| true
)

log_info "Report complete:"
log_info "  Found: ${FOUND_COUNT}"
log_info "  Not Found: ${NOT_FOUND_COUNT}"
log_info "  Report: ${REPORT_FILE}"

################################################################################
# TIMER
################################################################################

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

MINUTES=$((ELAPSED / 60))
SECONDS=$((ELAPSED % 60))

log_info "Durtaton: ${MINUTES}m ${SECONDS}s"
log_info "Finished $(date '+%H:%M:%S')"


################################################################################
# SUMMARY
################################################################################

if [[ ${FOUND_COUNT} -eq 0 ]]; then

    TITLE="ABM Serial Lookup - No Results"
    MESSAGE="No serials found. Total checked: ${SERIAL_COUNT}"

elif [[ ${NOT_FOUND_COUNT} -eq 0 ]]; then

    TITLE="ABM Serial Lookup - All Found"
    MESSAGE="All ${FOUND_COUNT} serial(s) found successfully."

else

    TITLE="ABM Serial Lookup - Partial Results"
    MESSAGE="Found: ${FOUND_COUNT} | Not Found: ${NOT_FOUND_COUNT} | Total: ${SERIAL_COUNT}"

fi

/usr/bin/osascript <<EOF
display notification "${MESSAGE}" with title "${TITLE}"
EOF

open "${REPORT_DIR}"

echo "REPORT_COMPLETE"

