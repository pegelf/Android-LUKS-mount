#!/data/data/com.termux/files/usr/bin/bash

# Variables
LOGFILE="$(dirname "$0")/LuksSD.log"
LUKS_DEVICE="/dev/block/mmcblk1p1"
LUKS_NAME="LuksSD"
MAPPER_PATH="/dev/mapper/$LUKS_NAME"
MOUNT_POINT="/mnt/LuksSD.bind"
BIND_TARGET="/sdcard/SD"
BIND_USER= "media_rw" # insert the output of "whoami" command here, e.g. u0_a123. But media_rw also works for most apps.
CRYPTSETUP_BIN="/data/data/com.termux/files/usr/bin/cryptsetup"
BINDFS_BIN="/data/data/com.termux/files/usr/bin/bindfs"
PASSWORD="LUKS_PASSWORD"
FILESYSTEM="exfat" # Default filesystem
NOTIFICATIONS=true

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOGFILE"
}

notify() {
    if [ "$NOTIFICATIONS" = true ]; then
        if command -v termux-notification >/dev/null 2>&1; then
            timeout 5s termux-notification --title "SD Card Mount" \
                --content "$1" \
                --priority high \
                # Open Log button, doesn't work yet
                ## --button1 "Open Log" \
                ## --button1-action "termux-open --content-type text/plain \"$LOGFILE\""
            if [ $? -ne 0 ]; then
                log "termux-notification failed or timed out. Disabling notifications."
                NOTIFICATIONS=false
            fi
        else
            log "termux-notification command not found. Disabling notifications."
            NOTIFICATIONS=false
        fi
    fi
}

# Start logging
log "Starting 01-mount-luks-sd.sh..."

# Check if already mounted
if su -Mc "mount | grep -q \"$MOUNT_POINT\""; then
    log "Mount point $MOUNT_POINT is already mounted."
    notify "Mounting SD Card Skipped: Already mounted."
    exit 0
fi

# Check if an SD card is inserted
if ! su -Mc "[ -b \"$LUKS_DEVICE\" ]"; then
    log "No SD card detected at $LUKS_DEVICE."
    notify "Mounting SD Card Failed: No SD card detected."
    exit 1
fi

# Unlock the LUKS container
if su -Mc 'echo "'"$PASSWORD"'" | '"$CRYPTSETUP_BIN"' luksOpen '"$LUKS_DEVICE"' '"$LUKS_NAME"' -'; then
    log "LUKS container unlocked successfully."
else
    log "Failed to unlock LUKS container."
    notify "Mounting SD Card Failed: LUKS unlock failed."
    exit 1
fi

# Create mount point
su -Mc "mkdir -p \"$MOUNT_POINT\""
su -Mc "chown media_rw:media_rw $MOUNT_POINT"

 # Create bind target
mkdir -p "$BIND_TARGET"

# Mount the partition with the specified filesystem
log "Using filesystem: $FILESYSTEM"
if su -Mc "mount -t $FILESYSTEM -o rw $MAPPER_PATH $MOUNT_POINT"; then
    log "$FILESYSTEM partition mounted successfully."
else
    log "Failed to mount $FILESYSTEM partition."
    notify "Mounting SD Card Failed: $FILESYSTEM mount failed."
    exit 1
fi

# Use Bindfs
if su -Mc "$BINDFS_BIN -o nosuid,nodev,noatime,nonempty \
    -u $BIND_USER -g 9997 \
    -p a-rwx,ug+rw,ugo+X \
    --create-with-perms=a-rwx,ug+rw,ugo+X \
    --xattr-none --chown-ignore --chgrp-ignore --chmod-ignore \
    $MOUNT_POINT $BIND_TARGET"; then
    log "Bindfs mounted successfully."
else
    log "Failed to mount with bindfs."
    notify "Mounting SD Card Failed: Bindfs mount failed."
    exit 1
fi

log "01-mount-luks-sd.sh completed successfully."
notify "Mounting SD Card Successful."
