#!/bin/bash -eu

log "Moving clips to archive..."

NUM_FILES_MOVED=0
NUM_FILES_SKIPPED=0
NUM_FILES_FAILED=0
NUM_FILES_DELETED=0

function connectionmonitor {
  while true
  do
    for i in $(seq 1 10)
    do
      if timeout 3 /root/bin/archive-is-reachable.sh $ARCHIVE_HOST_NAME
      then
        # sleep and then continue outer loop
        sleep 5
        continue 2
      fi
    done
    log "connection dead, killing archive-clips"
    # The archive loop might be stuck on an unresponsive server, so kill it hard.
    # (should be no worse than losing power in the middle of an operation)
    kill -9 $1
    return
  done
}

function clipAlreadyArchived() {
  file_name="$1"
  size=$(stat -c%s "$ROOT/$file_name")
  archive_file_name="$ARCHIVE_MOUNT/$file_name"
  existing_size=$(sql_query "SELECT size FROM archived_files_pending_delete WHERE name = '$file_name'")
  if  [[ $existing_size -eq $size ]] || [[ -f "$archive_file_name" && $(stat -c%s "$archive_file_name") -eq $size ]]
  then
    return 0
  else
    return 1
  fi
}

function markClipAsArchived() {
  file_name="$1"
  size=$(stat -c%s "$ROOT/$file_name")
  existing_size=$(sql_query "SELECT size FROM archived_files_pending_delete WHERE name = '$file_name'")
  if [[ $existing_size -ne $size ]]
  then
    log "Marking '$file_name' as archived with file size $size"
    sql_query "INSERT OR REPLACE INTO archived_files_pending_delete (name, size, archived_at) VALUES ('$file_name', $size, CURRENT_TIMESTAMP);"
  fi
}

function moveclips() {
  ROOT="$1"
  PATTERN="$2"

  if [ ! -d "$ROOT" ]
  then
    log "$ROOT does not exist, skipping"
    return
  fi

  while read file_name
  do
    outdir=$(dirname "$file_name")
    archive_directory="$ARCHIVE_MOUNT/$outdir"
    archive_file_name="$ARCHIVE_MOUNT/$file_name"
    if [ ! -d "$archive_directory" ]
    then
      log "Creating output directory '$outdir'"
      if ! mkdir -p "$archive_directory"
      then
        log "Failed to create '$outdir', check that archive server is writable and has free space"
        return
      fi
    fi
    if [ -f "$ROOT/$file_name" ]
    then
      if ! clipAlreadyArchived "$file_name"
      then
        log "Moving '$file_name'"
        outdir=$(dirname "$file_name")
        if cp --preserve=timestamps "$ROOT/$file_name" "$ARCHIVE_MOUNT/$outdir"
        then
          log "Moved '$file_name'"
          markClipAsArchived "$file_name"
          NUM_FILES_MOVED=$((NUM_FILES_MOVED + 1))
        else
          log "Failed to move '$file_name'"
          NUM_FILES_FAILED=$((NUM_FILES_FAILED + 1))
        fi
      else
        log "'$file_name' already present in archive, skipping"
        markClipAsArchived "$file_name"
        NUM_FILES_SKIPPED=$((NUM_FILES_SKIPPED + 1))
      fi
    else
      log "$file_name not found"
    fi
  done <<< $(cd "$ROOT"; find $PATTERN -type f -mmin +5)
}

connectionmonitor $$ &

# legacy file name pattern, firmware 2018.*
moveclips "$CAM_MOUNT/TeslaCam" 'saved*'

# new file name pattern, firmware 2019.*
moveclips "$CAM_MOUNT/TeslaCam/SavedClips" '*'

kill %1

# delete empty directories under SavedClips
# rmdir --ignore-fail-on-non-empty "$CAM_MOUNT/TeslaCam/SavedClips"/* || true

log "Moved $NUM_FILES_MOVED file(s), failed to copy $NUM_FILES_FAILED, deleted $NUM_FILES_DELETED."

if [ $NUM_FILES_MOVED -gt 0 ]
then
  /root/bin/send-push-message "TeslaUSB:" "Moved $NUM_FILES_MOVED dashcam file(s), failed to copy $NUM_FILES_FAILED, deleted $NUM_FILES_DELETED."
fi

log "Finished moving clips to archive."
