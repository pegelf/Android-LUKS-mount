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
PASSWORD="LUKS_PW" # Replace with your password

# Mount Configuration
# MOUNT_POINT: The raw mount point (hidden from apps usually)
MOUNT_POINT="/mnt/LuksSD.bind"
# BIND_TARGET: The visible mount point for the user
BIND_TARGET="/sdcard/SD"

# Internal Folders Redirection
# These folders will be moved to the encrypted SD and mounted back via bindfs.
REDIRECT_FOLDERS=(
    # "Test1"
    # "Download"
)

# Folder on the raw SD where redirected folders are stored
HIDDEN_SD_STORAGE=".mountedinternal"

# Bindfs User Configuration
# user like u0_a384. You can check other folders permissions with ls -lah ~/storage/shared
BIND_USER="media_rw"
BIND_GROUP="9997" # 9997 is everybody/everybody

# Filesystem Type
FILESYSTEM="exfat"

# Binaries
CRYPTSETUP_BIN="/data/data/com.termux/files/usr/bin/cryptsetup"
BINDFS_BIN="/data/data/com.termux/files/usr/bin/bindfs"

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

# Wrapper for su to run commands
run_su() {
    su -Mc "$1"
}

# Helper to check available space (Source vs Destination)
check_space() {
    local src_path="$1"
    local dest_path="$2"
    
    # We need to run these checks as root to see protected dirs
    local src_size=$(run_su "du -sk \"$src_path\"" | awk '{print $1}')
    local dest_avail=$(run_su "df -k \"$dest_path\"" | awk 'NR==2 {print $4}')
    
    # 10% Safety buffer
    local required_space=$((src_size + (src_size / 10)))
    
    if [ "$dest_avail" -gt "$required_space" ]; then
        return 0
    else
        log "Not enough space! Needed: ${required_space}KB, Avail: ${dest_avail}KB"
        return 1
    fi
}

# Helper to check if folder is busy (open files)
is_folder_busy() {
    local folder="$1"
    if run_su "lsof +D \"$folder\" > /dev/null 2>&1"; then
        return 0 # Busy
    fi
    return 1 # Not busy
}

# Function to unmount
unmount_sd() {
    log "Starting unmount process..."

    # 1. Unmount Redirect Folders (Reverse order)
    if [ ${#REDIRECT_FOLDERS[@]} -gt 0 ]; then
        for (( idx=${#REDIRECT_FOLDERS[@]}-1 ; idx>=0 ; idx-- )); do
            folder="${REDIRECT_FOLDERS[idx]}"
            target="/sdcard/$folder"
            
            # Check if mounted
            if run_su "mount | grep -q \" $target \""; then
                if run_su "umount -l \"$target\""; then
                    log "Unmounted redirect: $folder"
                else
                    log "Failed to unmount redirect: $folder"
                    notify "Error: Failed to unmount $folder"
                fi
            fi
        done
    fi

    # 2. Unmount bindfs (Visible SD)
    if run_su "mount | grep -q \"$BIND_TARGET\""; then
        if run_su "umount -l \"$BIND_TARGET\""; then
            log "Bindfs unmounted successfully from $BIND_TARGET."
        else
            log "Failed to unmount bindfs from $BIND_TARGET."
        fi
    fi

    # 3. Unmount main mount point (Raw SD)
    if run_su "mount | grep -q \"$MOUNT_POINT\""; then
        if run_su "umount -l \"$MOUNT_POINT\""; then
            log "Unmounted successfully from $MOUNT_POINT."
        else
            log "Failed to unmount $MOUNT_POINT."
        fi
    fi

    # 4. Close LUKS container
    if [ -e "/dev/mapper/$LUKS_NAME" ]; then
        if run_su "$CRYPTSETUP_BIN luksClose $LUKS_NAME"; then
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
    if [ ${#REDIRECT_FOLDERS[@]} -eq 0 ]; then return; fi
    log "Starting folder redirection..."
    
    # Path where data physically lives on the encrypted partition
    RAW_STORAGE_ROOT="$MOUNT_POINT/$HIDDEN_SD_STORAGE"
    
    # Create hidden storage folder
    run_su "mkdir -p \"$RAW_STORAGE_ROOT\""
    run_su "touch \"$RAW_STORAGE_ROOT/.nomedia\"" # Prevent double scanning
    
    # We set permissive rights on the physical folder, bindfs handles the rest
    run_su "chmod 777 \"$RAW_STORAGE_ROOT\""

    for folder in "${REDIRECT_FOLDERS[@]}"; do
        INTERNAL_PATH="/sdcard/$folder"
        RAW_PATH="$RAW_STORAGE_ROOT/$folder"

        # 1. Ensure Raw Destination Exists
        run_su "mkdir -p \"$RAW_PATH\""
        run_su "chmod 777 \"$RAW_PATH\""

        # 2. Migration Logic (Move files if they exist internally and are NOT mounted)
        if run_su "[ -d \"$INTERNAL_PATH\" ]" && ! run_su "mount | grep -q \" $INTERNAL_PATH \""; then
            # Check if not empty
            if run_su "[ \"\$(ls -A \"$INTERNAL_PATH\" 2>/dev/null)\" ]"; then
                log "Found content in $INTERNAL_PATH. Checking migration..."
                
                if ! check_space "$INTERNAL_PATH" "$MOUNT_POINT"; then
                    log "SKIP MIGRATION for $folder: Not enough space."
                    notify "Error: Not enough space to move $folder"
                elif is_folder_busy "$INTERNAL_PATH"; then
                    log "SKIP MIGRATION for $folder: Folder is busy."
                    notify "Warning: $folder is in use. Files not moved."
                else
                    log "Migrating $folder to encrypted storage..."
                    notify "Moving files for $folder..."
                    
                    # Move content. bash -c needed for shopt dotglob
                    if run_su "bash -c 'shopt -s dotglob; mv -n \"$INTERNAL_PATH\"/* \"$RAW_PATH\"/'"; then
                        log "Moved content of $folder successfully."
                    else
                        log "Error moving files for $folder."
                        notify "Warning: Moving files for $folder failed."
                    fi
                fi
            else
                log "$folder is empty or missing. No migration needed."
            fi
        fi

        # 3. Create Internal Mountpoint if missing
        if ! run_su "[ -d \"$INTERNAL_PATH\" ]"; then
            run_su "mkdir -p \"$INTERNAL_PATH\""
            run_su "chown media_rw:media_rw \"$INTERNAL_PATH\""
            log "Created mountpoint: $INTERNAL_PATH"
        fi

        # 4. Mount using BINDFS
        if run_su "$BINDFS_BIN \
            -o nosuid,nodev,nonempty \
            -u $BIND_USER -g $BIND_GROUP \
            -p a-rwx,ug+rw,o+rwx,ugo+X \
            --create-with-perms=a-rwx,ug+rw,o+rwx,ugo+X \
            --xattr-none --chown-ignore --chgrp-ignore --chmod-ignore \
            \"$RAW_PATH\" \"$INTERNAL_PATH\""; then
            
            log "Mounted $folder via bindfs."
        else
            log "Failed to mount $folder via bindfs."
            notify "Mounting $folder failed."
        fi
    done
}


# ==============================================================================
# MAIN SCRIPT
# ==============================================================================

log "Starting 01-mount-luks-sd.sh..."

# Check if script is run with --umount
if [ "$1" == "--umount" ]; then
    unmount_sd
fi

# Check if already mounted
if run_su "mount | grep -q \"$MOUNT_POINT\""; then
    log "Mount point $MOUNT_POINT is already mounted."
    notify "Mounting SD Card Skipped: Already mounted."
    exit 0
fi

# Check if an SD card is inserted
if ! run_su "[ -b \"$LUKS_DEVICE\" ]"; then
    log "No SD card detected at $LUKS_DEVICE."
    notify "Mounting SD Card Failed: No SD card detected."
    exit 1
fi

# Unlock the LUKS container
if [ ! -e "$MAPPER_PATH" ]; then
    if run_su 'echo "'"$PASSWORD"'" | '"$CRYPTSETUP_BIN"' luksOpen '"$LUKS_DEVICE"' '"$LUKS_NAME"' -'; then
        log "LUKS container unlocked successfully."
    else
        log "Failed to unlock LUKS container."
        notify "Mounting SD Card Failed: LUKS unlock failed."
        exit 1
    fi
fi

# Create mount point
run_su "mkdir -p \"$MOUNT_POINT\""
run_su "chown media_rw:media_rw $MOUNT_POINT"

# Create bind target
run_su "mkdir -p \"$BIND_TARGET\""

# Mount the partition with the specified filesystem
log "Using filesystem: $FILESYSTEM"
# Added uid=0,gid=0 to ensure root owns the raw mount. 
# This helps bindfs (running as root) to perform privileged ops like 'utime'.
if run_su "mount -t $FILESYSTEM \
    -o rw,umask=0000,uid=0,gid=0 \
    $MAPPER_PATH $MOUNT_POINT"; then
    log "$FILESYSTEM partition mounted successfully."
else
    log "Failed to mount $FILESYSTEM partition."
    notify "Mounting SD Card Failed: $FILESYSTEM mount failed."
    exit 1
fi

# Use Bindfs for main SD
if run_su "$BINDFS_BIN \
    -o nosuid,nodev,nonempty \
    -u $BIND_USER -g $BIND_GROUP \
    -p a-rwx,ug+rw,o+rwx,ugo+X \
    --create-with-perms=a-rwx,ug+rw,o+rwx,ugo+X \
    --xattr-none --chown-ignore --chgrp-ignore --chmod-ignore \
    $MOUNT_POINT $BIND_TARGET"; then
    log "Bindfs mounted successfully."
else
    log "Failed to mount with bindfs."
    notify "Mounting SD Card Failed: Bindfs mount failed."
    exit 1
fi

# Process Redirected Folders
bind_redirect_folders

log "mount completed successfully."
notify "Mounting SD Card Successful."
exit 0