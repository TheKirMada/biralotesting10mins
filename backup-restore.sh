#!/usr/bin/env bash
# OPTIMIZED backup-restore.sh - Fast and reliable backup for VPS

set -u

BACKUP_NAME="vps_backup.tar.gz"
LAST_BACKUP_FILE="last_backup_url.txt"
TRANSFER_BASE="https://transfer.sh"
RETRIES=3
RETRY_DELAY=5

# CRITICAL DIRECTORIES ONLY (fast backup)
INCLUDE_DIRS=(/etc /home /usr/local /opt /var/lib/pufferpanel)

# SMART EXCLUSIONS (avoid huge directories)
EXCLUDES=(
  "/var/lib/docker/*"      # Docker images - HUGE
  "/var/log/*"             # Log files - HUGE
  "/var/cache/apt/*"       # APT cache - large
  "/var/tmp/*"             # Temporary files
  "/tmp/*"                 # Temporary files
  "/proc/*"                # Virtual filesystem
  "/sys/*"                 # Virtual filesystem
  "/dev/*"                 # Device files
  "/run/*"                 # Runtime data
  "/mnt/*"                 # Mount points
  "/media/*"               # Media mounts
  "*/lost+found"           # Recovery directories
)

log() { printf '%b\n' "$*"; }
err() { printf '%b\n' "ERROR: $*" >&2; }

restore_backup() {
  log "🔄 restore_backup: starting"

  if [ ! -f "$LAST_BACKUP_FILE" ]; then
    log "⚠️  No $LAST_BACKUP_FILE found — nothing to restore."
    return 1
  fi

  BACKUP_URL=$(cat "$LAST_BACKUP_FILE" | tr -d '\r\n')
  if [ -z "$BACKUP_URL" ]; then
    err "last backup URL file exists but is empty"
    return 1
  fi

  log "➡️  Downloading backup from: $BACKUP_URL"
  curl_opts=(--silent --show-error --fail --location --max-time 1200)
  for i in $(seq 1 $RETRIES); do
    if curl "${curl_opts[@]}" --output "$BACKUP_NAME" "$BACKUP_URL"; then
      log "✅ Download succeeded."
      break
    else
      err "download attempt $i failed; retrying in ${RETRY_DELAY}s..."
      sleep $RETRY_DELAY
      if [ "$i" -eq "$RETRIES" ]; then
        err "Failed to download backup after $RETRIES attempts."
        return 2
      fi
    fi
  done

  if [ -f "$BACKUP_NAME" ]; then
    log "🔧 Extracting $BACKUP_NAME..."
    if sudo tar -xzf "$BACKUP_NAME" -C /; then
      log "✅ Extraction completed."
      return 0
    else
      err "Failed to extract backup archive."
      return 3
    fi
  else
    err "Downloaded archive not found: $BACKUP_NAME"
    return 4
  fi
}

backup_and_upload() {
  log "💾 backup_and_upload: starting (FAST MODE)"

  # Save package list
  mkdir -p backup_meta
  log "📦 Saving installed package list"
  dpkg --get-selections > backup_meta/installed_packages.txt 2>/dev/null || log "⚠️ dpkg list failed"

  # Build tar command
  TAR_CMD="sudo tar -czf $BACKUP_NAME"
  
  # Add excludes
  for ex in "${EXCLUDES[@]}"; do
    TAR_CMD="$TAR_CMD --exclude=\"$ex\""
  done
  
  # Add includes
  TAR_CMD="$TAR_CMD ${INCLUDE_DIRS[@]} backup_meta"

  log "🔨 Creating archive $BACKUP_NAME (FAST MODE)..."
  eval $TAR_CMD 2>/tmp/tar.stderr
  
  if [ $? -eq 0 ]; then
    log "✅ Archive created: $BACKUP_NAME"
  else
    log "⚠️ tar had issues (check /tmp/tar.stderr), but continuing..."
  fi

  # Check size
  if [ -f "$BACKUP_NAME" ]; then
    size_bytes=$(stat -c%s "$BACKUP_NAME" 2>/dev/null || echo 0)
    size_mb=$((size_bytes / 1024 / 1024))
    log "📏 Archive size: ${size_mb}MB"
  fi

  # Upload
  log "⬆️  Uploading to $TRANSFER_BASE ..."
  UPLOAD_LINK=""
  for i in $(seq 1 $RETRIES); do
    UPLOAD_LINK=$(curl --silent --show-error --fail --max-time 300 --upload-file "$BACKUP_NAME" "$TRANSFER_BASE/$BACKUP_NAME") || UPLOAD_LINK=""
    if [ -n "$UPLOAD_LINK" ]; then
      log "🆙 Upload succeeded: $UPLOAD_LINK"
      break
    else
      err "Upload attempt $i failed; retrying in ${RETRY_DELAY}s..."
      sleep $RETRY_DELAY
    fi
  done

  if [ -z "$UPLOAD_LINK" ]; then
    err "Failed to upload backup after $RETRIES attempts."
    return 6
  fi

  echo "$UPLOAD_LINK" > "$LAST_BACKUP_FILE"
  log "💾 Saved upload link to $LAST_BACKUP_FILE"
  return 0
}

# ----- main dispatch -----
if [ $# -lt 1 ]; then
  echo "Usage: $0 [restore_backup|backup_and_upload]"
  exit 10
fi

case "$1" in
  restore_backup)
    restore_backup
    exit $?
    ;;
  backup_and_upload)
    backup_and_upload
    exit $?
    ;;
  *)
    echo "Usage: $0 [restore_backup|backup_and_upload]"
    exit 11
    ;;
esac