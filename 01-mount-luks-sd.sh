#!/data/data/com.termux/files/usr/bin/bash

# ==============================================================================
# CONFIGURATION
# ==============================================================================

# Log file location
LOGFILE="$(dirname "$0")/LuksSD.log"

# LUKS Configuration
LUKS_DEVICE="/dev/block/mmcblk1p1"
LUKS_NAME="LuksSD"
MAPPER_PATH="/dev/mapper/$LUKS_NAME"
PASSWORD="LUKS_PASSWORD"

# Mount Configuration
# We mount to a stable system location first, then bind to the visible SD path.
REAL_MOUNT_POINT="/mnt/LuksSD_Root"
VISIBLE_MOUNT_POINT="/sdcard/SD"

# Internal Folders Redirection
# These folders on Internal Storage will be moved to SD and bind-mounted back.
# CAUTION: Data will be moved physically to the encrypted SD card.
REDIRECT_FOLDERS=(
    "DCIM/Camera"
    "Download"
)

# Folder on the LUKS SD where redirected folders are stored
# We start with a dot (.) to hide it from standard file explorers
HIDDEN_SD_STORAGE=".mountedinternal"

# Filesystem Type (exfat, f2fs, ext4, etc.)
FILESYSTEM="exfat"

# Binaries
CRYPTSETUP_BIN="/data/data/com.termux/files/usr/bin/cryptsetup"

# Notification Settings
NOTIFICATIONS=true

# ==============================================================================
# FUNCTIONS
# ==============================================================================

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOGFILE"
}

notify() {
    if [ "$NOTIFICATIONS" = true ]; then
        if command -v termux-notification >/dev/null 2>&1; then
            timeout 5s termux-notification --title "SD Card Mount" \
                --content "$1" \
                --priority high
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

# Function to unmount specific bind folders (Downloads, DCIM, etc.)
unbind_internal_folders() {
    log "Unmounting redirected internal folders..."
    
    # Reverse loop through folders to handle potential nesting correctly
    # (though usually not an issue with simple list)
    for (( idx=${#REDIRECT_FOLDERS[@]}-1 ; idx>=0 ; idx-- )); do
        folder="${REDIRECT_FOLDERS[idx]}"
        target_path="/sdcard/$folder"
        
        # Check if it is a mountpoint
        if su -Mc "mount | grep -q \" $target_path \""; then
            if su -Mc "umount \"$target_path\""; then
                log "Unbound: $folder"
            else
                log "Failed to unbind: $folder"
                notify "Error: Could not unmount $folder"
            fi
        fi
    done
}

unmount_sd() {
    log "Starting unmount process..."

    # 1. Unmount redirected internal folders FIRST
    unbind_internal_folders

    # 2. Unmount the visible bind mount
    if su -Mc "mount | grep -q \"$VISIBLE_MOUNT_POINT\""; then
        if su -Mc "umount \"$VISIBLE_MOUNT_POINT\""; then
            log "Unmounted bind point $VISIBLE_MOUNT_POINT."
        else
            log "Failed to unmount $VISIBLE_MOUNT_POINT."
        fi
    fi

    # 3. Unmount the real mount point
    if su -Mc "mount | grep -q \"$REAL_MOUNT_POINT\""; then
        if su -Mc "umount \"$REAL_MOUNT_POINT\""; then
            log "Unmounted real mount point $REAL_MOUNT_POINT."
        else
            log "Failed to unmount $REAL_MOUNT_POINT."
        fi
    fi

    # 4. Close LUKS container
    if [ -e "$MAPPER_PATH" ]; then
        if su -Mc "$CRYPTSETUP_BIN luksClose $LUKS_NAME"; then
            log "LUKS container closed successfully."
        else
            log "Failed to close LUKS container."
        fi
    fi

    notify "Unmounting SD Card completed."
    log "Unmount process completed."
    exit 0
}

bind_redirect_folders() {
    log "Starting folder redirection..."
    
    # Define the physical storage path on the mounted SD
    SD_STORAGE_PATH="$REAL_MOUNT_POINT/$HIDDEN_SD_STORAGE"
    
    # Create the storage directory on SD
    su -Mc "mkdir -p \"$SD_STORAGE_PATH\""
    
    # Create .nomedia to prevent Gallery duplicates in the raw SD folder
    # (Since files are visible in the bind target, we don't want them indexed twice)
    su -Mc "touch \"$SD_STORAGE_PATH/.nomedia\""

    # Fix permissions for the storage root
    if [[ "$FILESYSTEM" != "exfat" && "$FILESYSTEM" != "vfat" ]]; then
        su -Mc "chown 1023:9997 \"$SD_STORAGE_PATH\""
        su -Mc "chmod 775 \"$SD_STORAGE_PATH\""
    fi

    for folder in "${REDIRECT_FOLDERS[@]}"; do
        INTERNAL_PATH="/sdcard/$folder"
        SD_PATH="$SD_STORAGE_PATH/$folder"

        # 1. Create destination folder on SD if missing
        su -Mc "mkdir -p \"$SD_PATH\""
        
        # Permissions for subfolder
        if [[ "$FILESYSTEM" != "exfat" && "$FILESYSTEM" != "vfat" ]]; then
            su -Mc "chown 1023:9997 \"$SD_PATH\""
            su -Mc "chmod 775 \"$SD_PATH\""
        fi

        # 2. Check if Internal path exists and has content
        # We only move data if the internal path exists and is NOT already a mountpoint
        if su -Mc "[ -d \"$INTERNAL_PATH\" ]" && ! su -Mc "mount | grep -q \" $INTERNAL_PATH \""; then
            
            # Check if directory is not empty
            if su -Mc "[ \"\$(ls -A \"$INTERNAL_PATH\")\" ]"; then
                log "Migrating data for $folder to SD card..."
                
                # Move content. We use 'cp -rn' and 'rm' logic or 'mv' depending on preference.
                # 'mv' is atomic on same FS, but copy-delete across FS.
                # using 'mv' inside su -c.
                # We use -n (no clobber) to prevent overwriting if file already exists on SD
                
                if su -Mc "mv -n \"$INTERNAL_PATH\"/* \"$SD_PATH\"/"; then
                    log "Moved content of $folder successfully."
                    # Clean up empty files on internal that were moved (mv -n leaves duplicates if they exist)
                    # For safety, we only remove files if we are sure they exist on destination?
                    # Simplified: We trust mv here. If files remain in Internal, they will be hidden by the mount.
                else
                    log "WARNING: Error moving files for $folder. Check logs. Proceeding with mount anyway."
                    notify "Warning: Moving files for $folder failed."
                fi
            else
                log "$folder is empty or only contains hidden files. No migration needed."
            fi
        fi

        # 3. Create Internal mountpoint if it doesn't exist
        su -Mc "mkdir -p \"$INTERNAL_PATH\""
        su -Mc "chown media_rw:media_rw \"$INTERNAL_PATH\""

        # 4. Bind Mount
        if su -Mc "mount --bind \"$SD_PATH\" \"$INTERNAL_PATH\""; then
            log "Bound $folder to SD card."
        else
            log "Failed to bind mount $folder."
            notify "Failed to mount $folder"
            continue
        fi
        
        # 5. Restore SELinux Context on the bind mount
        # Crucial for apps to access the bind-mounted folder
        su -Mc "chcon u:object_r:sdcardfs:s0 \"$INTERNAL_PATH\""
    done
}

# ==============================================================================
# MAIN SCRIPT
# ==============================================================================

log "Starting 01-mount-luks-sd.sh..."

# Check if script is run with --umount argument
if [ "$1" == "--umount" ]; then
    unmount_sd
fi

# 1. Check if main SD is already mounted
if su -Mc "mount | grep -q \"$VISIBLE_MOUNT_POINT\""; then
    log "Mount point $VISIBLE_MOUNT_POINT is already mounted."
    # If main SD is mounted, check if redirects are missing and try to add them?
    # For now, just exit to prevent double mounts.
    notify "Mounting Skipped: Already mounted."
    exit 0
fi

# 2. Check if the block device exists
if ! su -Mc "[ -b \"$LUKS_DEVICE\" ]"; then
    log "No SD card device detected at $LUKS_DEVICE."
    notify "Mounting Failed: Device not found."
    exit 1
fi

# 3. Unlock LUKS Container (if not already open)
if [ ! -e "$MAPPER_PATH" ]; then
    log "Opening LUKS container..."
    if su -Mc 'echo "'"$PASSWORD"'" | '"$CRYPTSETUP_BIN"' luksOpen '"$LUKS_DEVICE"' '"$LUKS_NAME"' -'; then
        log "LUKS container unlocked successfully."
    else
        log "Failed to unlock LUKS container. Check password or device."
        notify "Mounting Failed: LUKS unlock error."
        exit 1
    fi
else
    log "LUKS container already open."
fi

# 4. Prepare Mount Points
su -Mc "mkdir -p \"$REAL_MOUNT_POINT\""
su -Mc "mkdir -p \"$VISIBLE_MOUNT_POINT\""

# 5. Determine Mount Options based on Filesystem
# Android apps require specific UIDs (often media_rw/1023) and GIDs (everybody/9997).
# Native filesystems (f2fs/ext4) set this via chown after mounting.
# FAT/exFAT must set this via mount options.

MOUNT_OPTS="rw,noatime"

if [[ "$FILESYSTEM" == "exfat" || "$FILESYSTEM" == "vfat" || "$FILESYSTEM" == "ntfs" ]]; then
    # UID 1023 = media_rw, GID 9997 = everybody
    # mask 0002 allows group write access (rwxrwxr-x)
    # context=... tries to set SELinux label at mount time
    MOUNT_OPTS="$MOUNT_OPTS,uid=1023,gid=9997,fmask=0002,dmask=0002,context=u:object_r:sdcardfs:s0"
    log "Filesystem is $FILESYSTEM. Using options for permissions: $MOUNT_OPTS"
else
    log "Filesystem is $FILESYSTEM. Permissions will be fixed after mount."
fi

# 6. Mount the filesystem
if su -Mc "mount -t $FILESYSTEM -o $MOUNT_OPTS $MAPPER_PATH \"$REAL_MOUNT_POINT\""; then
    log "$FILESYSTEM mounted to $REAL_MOUNT_POINT."
else
    log "Failed to mount to $REAL_MOUNT_POINT."
    notify "Mounting Failed: FS Mount error."
    exit 1
fi

# 7. Apply Permissions (if using native FS like ext4/f2fs)
if [[ "$FILESYSTEM" != "exfat" && "$FILESYSTEM" != "vfat" && "$FILESYSTEM" != "ntfs" ]]; then
    log "Applying ownership and permissions for native filesystem..."
    su -Mc "chown -R 1023:9997 \"$REAL_MOUNT_POINT\"" # media_rw:everybody
    su -Mc "chmod -R 775 \"$REAL_MOUNT_POINT\""
fi

# 8. Apply SELinux Context (CRITICAL for App Access)
# We try to apply this even if mounted with context= option, just to be safe.
if su -Mc "chcon -R u:object_r:sdcardfs:s0 \"$REAL_MOUNT_POINT\""; then
    log "SELinux context applied."
else
    log "Warning: Failed to apply SELinux context (might be supported by mount option only)."
fi

# 9. Bind Mount to visible location (/sdcard/SD)
# This makes the mount visible in the user storage area
if su -Mc "mount --bind \"$REAL_MOUNT_POINT\" \"$VISIBLE_MOUNT_POINT\""; then
    log "Bind mount created at $VISIBLE_MOUNT_POINT."
else
    log "Failed to create bind mount."
    notify "Mounting Failed: Bind error."
    # Attempt cleanup
    su -Mc "umount \"$REAL_MOUNT_POINT\""
    exit 1
fi

log "Script completed successfully."
notify "SD Card Mounted Successfully."
exit 0