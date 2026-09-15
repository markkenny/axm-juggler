#!/bin/bash

# ABM Serials Install Script (for Jamf Self Service)
# Installs CSV to /tmp/AxM/ for current user
# Auto-generated installer

VERSION="20260914-09:41"
CSV_DIR="/tmp/AxM"
CSV_FILE="${CSV_DIR}/ALL_ABM_MacSerials_20260914.csv"
LOGGED_IN_USER=$(/bin/ls -la /dev/console | /usr/bin/awk '{ print $3 }')


# Create directory if it doesn't exist
if [[ ! -d "${CSV_DIR}" ]]; then
    mkdir -p "${CSV_DIR}"
fi

# Remove existing CSV with same date if it exists
if [[ -f "${CSV_FILE}" ]]; then
    rm "${CSV_FILE}"
fi

# Write CSV data to file
cat > "${CSV_FILE}" << 'CSVDATA'
TokenName,DeviceID,Status,20260914-22:15
"myabmserver","C02ABCDE1234","My Jamf Server"

CSVDATA

# Set ownership to logged-in user
chown "${LOGGED_IN_USER}" "${CSV_FILE}"
chmod 644 "${CSV_FILE}"

echo "SUCCESS: CSV version ${VERSION} installed to ${CSV_FILE}"
exit 0
