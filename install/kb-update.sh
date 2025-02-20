#!/bin/bash

set -e

source ./config.sh

KB_VERSION="latest"
UPDATE_DOWNLOAD="/data/scanoss_kb_updates/"
BASE_REMOTE_PATH="/ldb/compressed/updates"
UPDATE_FREQUENCY=""

function kb_update() {

    echo "Checking for free disk space on $UPDATE_DOWNLOAD"
    log "Checking for free disk space on $UPDATE_DOWNLOAD"

    REMOTE_SIZE=$(lftp -c "open -u "$(cat ~/.ssh_user)":"$(cat ~/.sshpass)"; du -bs $BASE_REMOTE_PATH/$UPDATE_FREQUENCY/$KB_VERSION" | cut -f1)

    LOCAL_SIZE=$(du -sb "$UPDATE_DOWNLOAD" | awk '{print $1}')

    if ((LOCAL_SIZE >= REMOTE_SIZE)); then
        while true; do
            read -p "Do you want to proceed with the download? (y/n) " yn
            case $yn in
                [Yy]* )
                    echo "Downloading Knowledge base update..."
                    log "Downloading Knowledge base update..."
                    lftp -u "$(cat ~/.ssh_user)":"$(cat ~/.sshpass)" -e "mirror -c -e -P 10  $BASE_REMOTE_PATH/$UPDATE_FREQUENCY/$KB_VERSION $DOWNLOAD_LOCATION; exit" sftp://sftp.scanoss.com:49322
                    ;;
                [Nn]* ) 
                    echo "Skipping knowledge base update download..."
                    ;;
                * ) 
                    echo "Please answer yes (y) or no (n).";;
            esac
        done 
    elif ((LOCAL_SIZE <= REMOTE_SIZE )) 
        echo "Disk space insufficient on $LOCAL_SIZE"
        log "Disk space insufficient on $LOCAL_SIZE"
        echo "Exiting script..."
        exit 1
    fi
        
    echo "KB Update downloaded to $UPDATE_DOWNLOAD"
    log "KB Update downloaded to $UPDATE_DOWNLOAD"

    while true; do
            read -p "Do you wish to proceed with the update import? (y/n) " yn
            case $yn in
                [Yy]* )

                    read -p "Enter the directory where to import the update (default: $LDB_LOCATION): " KB_LOCATION

                    echo "Checking for free disk space on $KB_LOCATION"

                    LDB_DISK_SPACE=$(du -sb "$LDB_LOCATION" | awk '{print $1}')
                    UPDATE_SIZE=$(du -sb "$DOWNLOAD_LOCATION" | awk '{print $1}')

                    if ((LDB_DISK_SPACE >= UPDATE_SIZE )) ; then

                    echo "Importing $BASE_REMOTE_PATH/$UPDATE_FREQUENCY/$KB_VERSION to $KB_LOCATION..."
                    log "Importing $BASE_REMOTE_PATH/$UPDATE_FREQUENCY/$KB_VERSION to $KB_LOCATION..."

                    echo 'bulk insert oss from /data/scanoss_kb_updates/25.02/mined WITH (THREADS=6,TMP=/data/scanoss_tmp,FILE_DEL=0)' | ldb

                    else
                        echo "Disk space insufficient on $LDB_DISK_SPACE"
                        log "Disk space insufficient on $LDB_DISK_SPACE"
                        echo "Exiting script..."
                        exit 1
                    fi
                    
                    ;;
                [Nn]* ) 
                    echo "Exiting knowledge base setup..."
                    exit 0
                    ;;
                * ) 
                    echo "Please answer yes (y) or no (n).";;
            esac
    done

}

echo "Starting knowledge base update script..."
log "Starting knowledge base update script..."


if [ "$(id -u)" != "0" ]; then
  echo "This script must be run as root."
  exit 1
fi


while true; do
            read -p "Enter the knowledge base version date (daily/monthly/quarterly): " UPDATE_FREQUENCY
            UPDATE_FREQUENCY=$(echo "$UPDATE_FREQUENCY" | tr '[:upper:]' '[:lower:]')
            case $UPDATE_FREQUENCY in
                daily)
                    UPDATE_FREQUENCY="daily"
                    ;;
                monthly) 
                    UPDATE_FREQUENCY="monthly"
                    ;;
                quarterly)
                    UPDATE_FREQUENCY="quarterly"
                    ;;
                * ) 
                    echo "Please answer a valid option (daily/monthly/quarterly).";;
            esac
done

echo "Available versions: "
echo "-------------------"

lftp -c "open -u \"$(cat ~/.ssh_user):$(cat ~/.sshpass)\"; find $BASE_REMOTE_PATH/$UPDATE_FREQUENCY -maxdepth 1 -type d -exec du -BG {} \; | sed 's/G\t.*\//G\t/'"

echo "-------------------"

read -p "Enter the knowledge base version (default: latest): " KB_VERSION

read -p "Enter the download directory location (default: $UPDATE_DOWNLOAD): " UPDATE_DOWNLOAD

mkdir -p "$UPDATE_DOWNLOAD/$KB_VERSION"

while true; do
    echo
    echo "Knowledge Base Update Menu"
    echo "------------------------"
    echo "1) Start knowledge base update"
    echo "2) Quit"
    echo
    read -p "Enter your choice [1-2]: " choice

    case $choice in
        1)
            kb_update
            ;;
        2)
            echo "Exiting script..."
            exit 0
            ;;
        *)
            echo "Invalid option. Please enter a number between 1-4."
            ;;
    esac
done
