#!/bin/bash
# config.sh — SCANOSS On-Premise Installation Configuration

# Application
APP_NAME="scanoss"
APP_DIR="/opt/$APP_NAME"
LOG_FILE="/var/log/$APP_NAME-install.log"
RUNTIME_USER="scanoss"

# Knowledge base
LDB_LOCATION="/var/lib/ldb"

# SFTP defaults
SFTP_HOST="sftp.scanoss.com"
SFTP_PORT="49322"
SFTP_USER=""
SFTP_PASSWORD=""

# Versions — "latest" follows the symlink on SFTP, or specify e.g. "5.4.25"
ENGINE_VERSION="latest"
LDB_VERSION="latest"
API_VERSION="latest"
ENCODER_VERSION="latest"

# System (auto-detected)
OS=""

# Logging
function log {
  local MESSAGE="$1"
  echo "$(date +'%Y-%m-%d %H:%M:%S') - $MESSAGE" | tee -a "$LOG_FILE"
}
