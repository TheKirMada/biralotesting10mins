#!/bin/bash

BACKUP_NAME="vps_backup.tar.gz"
LAST_BACKUP_FILE="last_backup_url.txt"

function restore_backup() {
  echo "🔄 Restoring backup..."
  if [ ! -f "$LAST_BACKUP_FILE" ]; then
    echo "No previous backup found, starting fresh."
    return 1
  fi
  BACKUP_URL=$(cat $LAST_BACKUP_FILE)
  curl -s --fail "$BACKUP_URL" -o $BACKUP_NAME || {
    echo "❌ Failed to download backup."
    return 1
  }
  tar -xzf $BACKUP_NAME || {
    echo "❌ Failed to extract backup."
    return 1
  }
  echo "✅ Backup restored."
}

function backup_and_upload() {
  echo "💾 Creating backup and uploading..."
  # Change these folders to whatever you want backed up
  tar czf $BACKUP_NAME ./data ./scripts ./configs 2>/dev/null || {
    echo "⚠️ Nothing to backup or folders do not exist."
    return 1
  }
  UPLOAD_LINK=$(curl --upload-file $BACKUP_NAME https://transfer.sh/$BACKUP_NAME)
  echo "🆙 Backup uploaded: $UPLOAD_LINK"
  echo $UPLOAD_LINK > $LAST_BACKUP_FILE
}

# Accept argument: restore_backup or backup_and_upload
if [ "$1" == "restore_backup" ]; then
  restore_backup
elif [ "$1" == "backup_and_upload" ]; then
  backup_and_upload
else
  echo "Usage: $0 [restore_backup|backup_and_upload]"
fi
