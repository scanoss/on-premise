# config.sh

# Application configuration

APP_NAME="scanoss"
APP_DIR="/opt/$APP_NAME"
LOG_FILE="/var/log/$APP_NAME-install.log"
RUNTIME_USER=scanoss
VERSION="latest"

# Knowledge base configuration

LDB_LOCATION=/var/lib/ldb

# SFTP credentials
SCANOSS_SFTP_USER=""
SCANOSS_SFTP_PASSWORD=""

# System information
OS=""

# Installation testing
TEST_FILE_NAME="file_match.wfp"

function log {
  local MESSAGE=$1
  echo "$(date +'%Y-%m-%d %H:%M:%S') - $MESSAGE" >> $LOG_FILE
}