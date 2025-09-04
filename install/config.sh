# config.sh

# Application configuration

APP_NAME="scanoss"
APP_DIR="/opt/$APP_NAME"
LOG_FILE="/var/log/$APP_NAME-install.log"
RUNTIME_USER=scanoss
VERSION="latest"

# Knowledge base configuration

REMOTE_LDB_LOCATION=/ldb/compressed/full/latest/oss/
FREE_SPACE_REQUIRED="${FREE_SPACE_REQUIRED:-19350}"
REAL_LDB_LOCATION=""
LDB_LOCATION=/var/lib/ldb
TMP_UPDATE=""

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