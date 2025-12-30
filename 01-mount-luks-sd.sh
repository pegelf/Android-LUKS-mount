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
# REAL_MOUNT_POINT: The physical mount location (system/root level)
# VISIBLE_MOUNT_POINT: Where the user accesses the files
REAL_MOUNT_POINT="/mnt/LuksSD_Root"
VISIBLE_MOUNT_POINT="/sdcard/SD"

# Internal Storage Physical Root
# This is the raw path to internal storage, bypassing the FUSE/sdcardfs layer.
# Mounting here is much more stable and fixes permission denied errors.
# Standard for almost all Android devices is /data/media/0
INTERNAL_STORAGE_ROOT="/data/media/0"

# Internal Folders Redirection
# These folders on Internal Storage will be moved to SD and bind-mounted back.
REDIRECT_FOLDERS=(
    "SwiftBackup"
    "Download"
)

# Folder on the LUKS SD where redirected folders are stored
# We start with a dot (.) to hide it from standard file explorers
HIDDEN_SD_STORAGE=".mountedinternal"

# Filesystem Type (exfat, f2fs, ext4, etc.)
FILESYSTEM="exfat"

# Filesystem Check Settings
ENABLE_FSCK=false

# Permissions Configuration
# Based on your 'ls -lah /data/media/0', we must mimic the system structure:
# Owner: u0_a384 (Your main user)
# Group: media_rw (Standard Android storage group)
MOUNT_OWNER="u0_a384"
MOUNT_GROUP="media_rw"

# Binaries
TERMUX_BASH="/data/data/com.termux/files/usr/bin/bash"
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
            # Timeout is important so script doesn't hang if notification daemon is stuck
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

# Resolve User/Group ID from name (or keep ID if numeric)
resolve_id() {
    local input="$1"
    local default_id="$2"
    
    # Check if input is a number
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        echo "$input"
    else
        # Try to resolve name to ID via 'id -u' inside su
        # We look up the user ID associated with the name
        local resolved_id=$(su -Mc "id -u \"$input\"" 2>/dev/null)
        
        # Check if we got a valid number back
        if [[ "$resolved_id" =~ ^[0-9]+$ ]]; then
            echo "$resolved_id"
        else
            log "Warning: Could not resolve user/group '$input'. Using default '$default_id'."
            echo "$default_id"
        fi
    fi
}

# Function to run filesystem check
run_fsck() {
    if [ "$ENABLE_FSCK" != true ]; then return 0; fi
    log "Running filesystem check on $MAPPER_PATH..."
    local fsck_bin="fsck.$FILESYSTEM"
    if su -Mc "command -v $fsck_bin >/dev/null"; then
        if su -Mc "$fsck_bin -a $MAPPER_PATH"; then
            log "Filesystem check passed."
        else
            log "WARNING: Filesystem check errors."
            notify "Warning: SD Card filesystem errors."
        fi
    else
        log "Fsck tool $fsck_bin not found."
    fi
}

# Function to unmount specific bind folders (Downloads, DCIM, etc.)
unbind_internal_folders() {
    if [ ${#REDIRECT_FOLDERS[@]} -eq 0 ]; then return; fi
    log "Unmounting redirected internal folders..."
    
    for (( idx=${#REDIRECT_FOLDERS[@]}-1 ; idx>=0 ; idx-- )); do
        folder="${REDIRECT_FOLDERS[idx]}"
        
        # Target 1: The FUSE path (cleanup)
        target_fuse="/sdcard/$folder"
        if su -Mc "mount | grep -q \" $target_fuse \""; then
            su -Mc "umount \"$target_fuse\"" && log "Unbound FUSE path: $folder"
        fi

        # Target 2: The Physical path (real target)
        target_phys="$INTERNAL_STORAGE_ROOT/$folder"
        if su -Mc "mount | grep -q \" $target_phys \""; then
            if su -Mc "umount \"$target_phys\""; then
                log "Unbound Physical path: $folder"
            else
                log "Failed to unbind: $target_phys"
                notify "Error: Could not unmount $folder"
            fi
        fi
    done
}

unmount_sd() {
    log "Starting unmount process..."
    unbind_internal_folders

    if su -Mc "mount | grep -q \"$VISIBLE_MOUNT_POINT\""; then
        su -Mc "umount \"$VISIBLE_MOUNT_POINT\"" && log "Unmounted visible mount."
    fi

    if su -Mc "mount | grep -q \"$REAL_MOUNT_POINT\""; then
        su -Mc "umount \"$REAL_MOUNT_POINT\"" && log "Unmounted real mount."
    fi

    if [ -e "$MAPPER_PATH" ]; then
        su -Mc "$CRYPTSETUP_BIN luksClose $LUKS_NAME" && log "LUKS closed."
    fi

    notify "Unmounting SD Card completed."
    exit 0
}

check_space() {
    local src_path="$1"
    local dest_path="$2"
    local src_size=$(su -Mc "du -sk \"$src_path\"" | awk '{print $1}')
    local dest_avail=$(su -Mc "df -k \"$dest_path\"" | awk 'NR==2 {print $4}')
    local required_space=$((src_size + (src_size / 10)))
    if [ "$dest_avail" -gt "$required_space" ]; then return 0; else return 1; fi
}

# Helper to check if folder is busy
is_folder_busy() {
    local folder="$1"
    # Check using lsof if available, otherwise assume safe if not explicitly locked
    # Grep checks if any process has an open file handle in this directory
    if su -Mc "lsof +D \"$folder\" > /dev/null 2>&1"; then
        return 0 # Busy
    fi
    return 1 # Not busy
}

bind_redirect_folders() {
    if [ ${#REDIRECT_FOLDERS[@]} -eq 0 ]; then return; fi
    log "Starting folder redirection..."
    
    if ! su -Mc "[ -d \"$INTERNAL_STORAGE_ROOT\" ]"; then
        log "ERROR: Internal root $INTERNAL_STORAGE_ROOT not found!"
        notify "Error: Internal Storage Root not found."
        return
    fi

    SD_STORAGE_PATH="$REAL_MOUNT_POINT/$HIDDEN_SD_STORAGE"
    su -Mc "mkdir -p \"$SD_STORAGE_PATH\""
    su -Mc "touch \"$SD_STORAGE_PATH/.nomedia\""

    # Set permissions for storage folder dynamically based on Config
    if [[ "$FILESYSTEM" != "exfat" && "$FILESYSTEM" != "vfat" && "$FILESYSTEM" != "ntfs" ]]; then
        su -Mc "chown $ANDROID_UID:$ANDROID_GID \"$SD_STORAGE_PATH\""
        su -Mc "chmod 777 \"$SD_STORAGE_PATH\""
    fi

    for folder in "${REDIRECT_FOLDERS[@]}"; do
        INTERNAL_PATH="$INTERNAL_STORAGE_ROOT/$folder"
        SD_PATH="$SD_STORAGE_PATH/$folder"

        # 1. Create destination on SD
        su -Mc "mkdir -p \"$SD_PATH\""
        if [[ "$FILESYSTEM" != "exfat" && "$FILESYSTEM" != "vfat" && "$FILESYSTEM" != "ntfs" ]]; then
            su -Mc "chown $ANDROID_UID:$ANDROID_GID \"$SD_PATH\""
            su -Mc "chmod 777 \"$SD_PATH\""
        fi

        # 2. Migration Logic
        if su -Mc "[ -d \"$INTERNAL_PATH\" ]" && ! su -Mc "mount | grep -q \" $INTERNAL_PATH \""; then
            if su -Mc "[ \"\$(ls -A \"$INTERNAL_PATH\" 2>/dev/null)\" ]"; then
                if ! check_space "$INTERNAL_PATH" "$REAL_MOUNT_POINT"; then
                    log "SKIP MIGRATION for $folder: Space."
                    notify "Error: Not enough space to move $folder"
                elif is_folder_busy "$INTERNAL_PATH"; then
                    log "SKIP MIGRATION for $folder: Busy."
                    notify "Warning: $folder is in use. Files not moved."
                else
                    log "Migrating $folder..."
                    notify "Moving files for $folder..."
                    if su -Mc "$TERMUX_BASH -c 'shopt -s dotglob; mv -n \"$INTERNAL_PATH\"/* \"$SD_PATH\"/'"; then
                        log "Moved $folder successfully."
                    else
                        log "Error moving $folder."
                    fi
                fi
            fi
        fi

        # 3. Create Internal mountpoint
        if ! su -Mc "[ -d \"$INTERNAL_PATH\" ]"; then
            su -Mc "mkdir -p \"$INTERNAL_PATH\""
            # Set owner/group to match neighbors in /data/media/0
            su -Mc "chown $ANDROID_UID:$ANDROID_GID \"$INTERNAL_PATH\""
            su -Mc "chmod 777 \"$INTERNAL_PATH\""
            log "Created mountpoint: $INTERNAL_PATH"
        fi

        # 4. Bind Mount
        if su -Mc "mount --bind \"$SD_PATH\" \"$INTERNAL_PATH\""; then
            log "Bound $folder to physical path."
        else
            log "Failed to bind $folder."
            continue
        fi
        
        # 5. Restore SELinux Context
        su -Mc "chcon u:object_r:media_rw_data_file:s0 \"$INTERNAL_PATH\"" || \
        su -Mc "chcon u:object_r:sdcardfs:s0 \"$INTERNAL_PATH\""
    done
}

# ==============================================================================
# MAIN SCRIPT
# ==============================================================================

log "Starting 01-mount-luks-sd.sh..."

if [ "$1" == "--umount" ]; then unmount_sd; fi

if su -Mc "mount | grep -q \"$VISIBLE_MOUNT_POINT\""; then
    log "Already mounted."
    notify "Mounting Skipped: Already mounted."
    exit 0
fi

if ! su -Mc "[ -b \"$LUKS_DEVICE\" ]"; then
    log "Device not found."
    notify "Mounting Failed: Device not found."
    exit 1
fi

if [ ! -e "$MAPPER_PATH" ]; then
    if su -Mc 'echo "'"$PASSWORD"'" | '"$CRYPTSETUP_BIN"' luksOpen '"$LUKS_DEVICE"' '"$LUKS_NAME"' -'; then
        log "LUKS unlocked."
    else
        log "LUKS unlock failed."
        notify "Mounting Failed: LUKS unlock error."
        exit 1
    fi
fi

run_fsck
su -Mc "mkdir -p \"$REAL_MOUNT_POINT\""
su -Mc "mkdir -p \"$VISIBLE_MOUNT_POINT\""

# RESOLVE UIDs
# Default to 1023 (media_rw) if u0_a384 not found, but configured owner takes precedence.
ANDROID_UID=$(resolve_id "$MOUNT_OWNER" "1023")
ANDROID_GID=$(resolve_id "$MOUNT_GROUP" "1023") # Default GID to media_rw (1023) if 'media_rw' name fails

MOUNT_OPTS="rw,noatime"
if [[ "$FILESYSTEM" == "exfat" || "$FILESYSTEM" == "vfat" || "$FILESYSTEM" == "ntfs" ]]; then
    # We use 777 (mask 0000) for permissions to be safe, but set correct owner/group
    MOUNT_OPTS="$MOUNT_OPTS,uid=$ANDROID_UID,gid=$ANDROID_GID,fmask=0000,dmask=0000,context=u:object_r:sdcardfs:s0"
fi

if su -Mc "mount -t $FILESYSTEM -o $MOUNT_OPTS $MAPPER_PATH \"$REAL_MOUNT_POINT\""; then
    log "$FILESYSTEM mounted."
else
    log "Mount failed."
    exit 1
fi

if [[ "$FILESYSTEM" != "exfat" && "$FILESYSTEM" != "vfat" && "$FILESYSTEM" != "ntfs" ]]; then
    su -Mc "chown -R $ANDROID_UID:$ANDROID_GID \"$REAL_MOUNT_POINT\""
    su -Mc "chmod -R 777 \"$REAL_MOUNT_POINT\""
fi

# SELinux Context for Main Mount
su -Mc "chcon -R u:object_r:sdcardfs:s0 \"$REAL_MOUNT_POINT\""

# Bind Mount to /sdcard/SD (Visible)
if su -Mc "mount --bind \"$REAL_MOUNT_POINT\" \"$VISIBLE_MOUNT_POINT\""; then
    log "Bind mount created."
else
    log "Bind error."
    su -Mc "umount \"$REAL_MOUNT_POINT\""
    exit 1
fi

bind_redirect_folders

log "Success."
notify "SD Card Mounted"
exit 0