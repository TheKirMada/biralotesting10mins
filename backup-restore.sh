#!/usr/bin/env bash
# backup-restore.sh  - Robust backup & restore helpers for the VPS workflow
# Usage:
#   ./backup-restore.sh restore_backup
#   ./backup-restore.sh backup_and_upload

set -u

BACKUP_NAME="vps_backup.tar.gz"
LAST_BACKUP_FILE="last_backup_url.txt"
TRANSFER_BASE="https://transfer.sh"
RETRIES=3
RETRY_DELAY=5
# Directories to include in backup - keeps archive smaller than full root but
# preserves packages, configs and common service data:
INCLUDE_DIRS=(/etc /var /usr/local /opt /home)
# Exclusions (avoid special, volatile or huge caches)
EXCLUDES=(
  "/proc/*"
  "/sys/*"
  "/dev/*"
  "/run/*"
  "/tmp/*"
  "/var/tmp/*"
  "/var/cache/apt/archives/*"
  "/mnt/*"
  "/media/*"
  "*/lost+found"
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
  # download with retries
  curl_opts=(--silent --show-error --fail --location)
  for i in $(seq 1 $RETRIES); do
    if curl "${curl_opts[@]}" --output "$BACKUP_NAME" --max-time 1200 --retry 2 --retry-delay 5 "$BACKUP_URL"; then
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

  # extract (requires sudo to write to system locations)
  if [ -f "$BACKUP_NAME" ]; then
    log "🔧 Extracting $BACKUP_NAME (this may overwrite files) ..."
    # Extract with sudo; if extract fails we report error
    if sudo tar -xzf "$BACKUP_NAME" -C /; then
      log "✅ Extraction completed."
      return 0
    else
      err "Failed to extract backup archive (tar exit != 0)."
      return 3
    fi
  else
    err "Downloaded archive not found: $BACKUP_NAME"
    return 4
  fi
}

backup_and_upload() {
  log "💾 backup_and_upload: starting"

  # prepare metadata
  mkdir -p backup_meta
  log "📦 Saving installed package list to backup_meta/installed_packages.txt"
  dpkg --get-selections > backup_meta/installed_packages.txt 2>/dev/null || log "⚠️ dpkg list failed (non-debian or no permission)"

  # Build tar arguments for includes and excludes
  TAR_ARGS=()
  for d in "${INCLUDE_DIRS[@]}"; do
    TAR_ARGS+=( "$d" )
  done
  for ex in "${EXCLUDES[@]}"; do
    TAR_ARGS+=( --exclude="$ex" )
  done
  TAR_ARGS+=( backup_meta )

  # Create archive; capture exit code but don't print massive tar warnings
  log "🔨 Creating archive $BACKUP_NAME (this may take a while)..."
  if sudo tar czf "$BACKUP_NAME" "${TAR_ARGS[@]}" 2>/tmp/tar.stderr; then
    log "✅ Archive created: $BACKUP_NAME"
  else
    # Show last few lines of tar stderr for debugging
    log "⚠️ tar reported warnings/errors (they are in /tmp/tar.stderr). Continuing best-effort."
    tail -n 50 /tmp/tar.stderr || true
    # If archive exists but tar returned non-zero, we will still try to upload if present
    if [ ! -f "$BACKUP_NAME" ]; then
      err "tar failed and archive wasn't created. Nothing to upload."
      return 5
    fi
  fi

  # sanity check archive size (warn if too big)
  size_bytes=0
  if [ -f "$BACKUP_NAME" ]; then
    size_bytes=$(stat -c%s "$BACKUP_NAME" 2>/dev/null || echo 0)
    size_mb=$((size_bytes / 1024 / 1024))
    log "📏 Archive size: ${size_mb}MB"
    if [ "$size_bytes" -gt $((10 * 1024 * 1024 * 1024)) ]; then
      err "Archive >10GB; transfer.sh may reject this. Consider smaller includes."
      # we still attempt upload, but warn
    fi
  fi

  # Upload with retries
  log "⬆️  Uploading to $TRANSFER_BASE ..."
  UPLOAD_LINK=""
  for i in $(seq 1 $RETRIES); do
    UPLOAD_LINK=$(curl --silent --show-error --fail --retry 2 --retry-delay 5 --upload-file "$BACKUP_NAME" "$TRANSFER_BASE/$BACKUP_NAME" 2>/dev/null) || UPLOAD_LINK=""
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

  # save URL to file for workflow to commit
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
