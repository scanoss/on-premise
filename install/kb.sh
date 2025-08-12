#!/bin/bash

set -e # Exit immediately if a command exits with a non-zero status.

# Import configuration file
source ./config.sh

function download_kb () {

  local KB=$1

  if [ $KB = Test ]; then
    REMOTE_LDB_LOCATION="/ldb/test-compressed/full/latest/oss/"
    read -p "Download $KB KB (y/abort) [abort]? " -n 1 -r
    echo
  elif [ $KB = SCANOSS ]; then
    read -p "Download $KB KB (y/abort) [abort]? " -n 1 -r
    echo
  fi

  if [[ $REPLY =~ ^[Yy]$ ]] ; then
    echo "Preparing download..."
  else
    echo "Stopping."
    exit 1
  fi

  # Confirm LDB download directory
  read -p "Enter the directory where to download the $KB KB (default: $LDB_LOCATION): " DOWNLOAD_LOCATION
  DOWNLOAD_LOCATION=${DOWNLOAD_LOCATION:-$LDB_LOCATION}

  # Confirm if LDB folder exists. Create it otherwise.
  if [ ! -d $DOWNLOAD_LOCATION ]; then
    mkdir -p $DOWNLOAD_LOCATION
  fi

  # Check for free space in LDB directory
  freespace=$(df --output=avail -B1G $LDB_LOCATION | awk 'NR==2 {print $1}')
  if awk -v freespace="$freespace" -v FREE_SPACE_REQUIRED="$FREE_SPACE_REQUIRED" 'BEGIN { if (freespace > FREE_SPACE_REQUIRED) exit 0; else exit 1 }'; then
    echo "Free space is over $FREE_SPACE_REQUIRED GB"
  else
    echo "Free space is not over $FREE_SPACE_REQUIRED GB"
    exit 1
  fi

  log "Downloading $REMOTE_LDB_LOCATION KB to $DOWNLOAD_LOCATION..."

  lftp -u "$(cat ~/.ssh_user)":"$(cat ~/.sshpass)" -e "mirror -c -e -P 10  $REMOTE_LDB_LOCATION $DOWNLOAD_LOCATION/oss; exit" sftp://sftp.scanoss.com:49322
  
  echo " $KB KB installation successful!"

  read -p "Configure $KB KB permissions and directories on this server (yes/no): " END_USER
  END_USER_LOWER=$(echo "$END_USER" | tr '[:upper:]' '[:lower:]') 
    
  case "$END_USER" in 
    "yes")
      # Create symlink if necesary
      if [[ "$DOWNLOAD_LOCATION" != "$LDB_LOCATION" ]]; then
        log "Creating symlink to $DOWNLOAD_LOCATION"
        echo "Download directory is not the ldb default $LDB_LOCATION. Creating symlink to $DOWNLOAD_LOCATION..."
        ln -s $DOWNLOAD_LOCATION/oss $LDB_LOCATION/oss
      fi

      # At last, update permissions
      chown -R $RUNTIME_USER:$RUNTIME_USER $DOWNLOAD_LOCATION

      echo "Configuration finished!"
    ;;
    "no")
    echo "Skipping $KB KB configuration..."
    ;;
  esac

}
# Main script
echo "Starting knowledge base installation script..."

# Make sure we're running as root
if [ "$(id -u)" != "0" ]; then
  echo "This script must be run as root."
  exit 1
fi

while true; do
    echo
    echo "SCANOSS KB Installation Menu"
    echo "------------------------"
    echo "1) Install SCANOSS KB"
    echo "2) Install Test KB"
    echo "3) Quit"
    read -p "Enter your choice [1-3]: " kb_choice

    case $kb_choice in
        1)
            download_kb "SCANOSS"
            ;;
        2)
            download_kb "Test"
            ;;     
        3)
            echo "Exiting script..."
            exit 0
            ;;
        *)
            echo "Invalid option. Please enter a number between 1-3."
            ;;
    esac
done
