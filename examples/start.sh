#!/bin/bash
#===============================================================================
# Application Startup Script (for EC2 instances)
# Author: Muhammad Reza
# Purpose: Start/restart the application during deployment
#===============================================================================

set -euo pipefail

# Configuration
APP_NAME="${APPLICATION_NAME:-my-web-app}"
APP_DIR="/opt/${APP_NAME}"
LOG_DIR="/var/log/${APP_NAME}"
PID_FILE="/var/run/${APP_NAME}.pid"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "[$timestamp] [$level] $message"
}

# Create necessary directories
mkdir -p "$APP_DIR" "$LOG_DIR"

log "INFO" "Starting ${APP_NAME}..."

# Stop existing application if running
if [[ -f "$PID_FILE" ]]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        log "INFO" "Stopping existing application (PID: $OLD_PID)..."
        kill "$OLD_PID" || true
        sleep 5
        
        # Force kill if still running
        if kill -0 "$OLD_PID" 2>/dev/null; then
            log "WARN" "Force killing application..."
            kill -9 "$OLD_PID" || true
        fi
    fi
    rm -f "$PID_FILE"
fi

# Extract application artifact
if ls "${APP_DIR}"/*.tar.gz 1>/dev/null 2>&1; then
    log "INFO" "Extracting application artifact..."
    tar -xzf "${APP_DIR}"/*.tar.gz -C "$APP_DIR"
    rm -f "${APP_DIR}"/*.tar.gz
fi

# Set permissions
chmod +x "${APP_DIR}/app/start.sh" 2>/dev/null || true

# Start the application
# Modify this section based on your application type
cd "$APP_DIR"

case "${APP_TYPE:-node}" in
    node)
        if [[ -f "package.json" ]]; then
            npm install --production
            nohup npm start > "${LOG_DIR}/app.log" 2>&1 &
            echo $! > "$PID_FILE"
        fi
        ;;
    python)
        if [[ -f "requirements.txt" ]]; then
            pip install -r requirements.txt
        fi
        nohup python app.py > "${LOG_DIR}/app.log" 2>&1 &
        echo $! > "$PID_FILE"
        ;;
    java)
        nohup java -jar "${APP_DIR}/app.jar" > "${LOG_DIR}/app.log" 2>&1 &
        echo $! > "$PID_FILE"
        ;;
    go)
        nohup "${APP_DIR}/app/main" > "${LOG_DIR}/app.log" 2>&1 &
        echo $! > "$PID_FILE"
        ;;
    *)
        # Custom startup command
        if [[ -f "start.sh" ]]; then
            nohup ./start.sh > "${LOG_DIR}/app.log" 2>&1 &
            echo $! > "$PID_FILE"
        fi
        ;;
esac

# Wait for application to start
sleep 5

# Verify application is running
if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    log "INFO" "${GREEN}Application started successfully!${NC}"
    log "INFO" "PID: $(cat "$PID_FILE")"
    exit 0
else
    log "ERROR" "${RED}Application failed to start!${NC}"
    log "ERROR" "Check logs: ${LOG_DIR}/app.log"
    exit 1
fi
