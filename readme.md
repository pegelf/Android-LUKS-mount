
# Mount LUKS Encrypted SD Card on Android with Termux

This script automates the process of mounting a LUKS-encrypted SD card on an Android device. It works with the [Termux](https://f-droid.org/packages/com.termux/) app and can be used with the [Termux:Boot](https://f-droid.org/packages/com.termux.boot/) add-on to automatically mount the SD card on startup.

To use this script, your Android device must be rooted, and the Termux app must be granted root permissions.

## Why?
On some newer Android devices, the option to encrypt SD cards is disabled by the manufacturer. That's the case for newer Sony Xperia Devices.
Other methods like re-enabling internal storage formatting using ADB only caused problems, so I decided to write a Script for mounting a LUKS encrypted SD Card.

A major advantage of this method is that LUKS is supported on more devices than Android. So it's also possible to eject your SD card from your Android device and use it seamlessly on any Linux or macOS computer.


## Encrypt an SD Card

There are several ways to encrypt an SD card with LUKS. If you're using a Linux PC with the Gnome desktop environment (default on Ubuntu and Fedora) and prefer graphical user interfaces, you can use the preinstalled Disk Utility. Open it by searching for "Disks" or by running the `gnome-disks` command:

1. In the Disk Utility, select the SD card on the left.
2. Click the three dots in the upper-right corner and select "Format Disk."
3. Choose LUKS encryption and set a password.
4. Format the SD card.


The Disk Utility only supports ext4 as encrypted partition layout. To change the partition layout to exFAT, use GParted:
1. Open GParted
2. The encrypted SD card should be already opened system-wide from using the Disk Utility before. If not, you can click on "Partition" in the menu bar and then select "Open Encryption".
3. Right-click the ext4 partition and choose "format to" "exFAT"
4. At the bottom of the program, right-click and select "Run All Actions."
5. In the main menu bar, choose "Partition" and then "Label File System". That's the name that Gnome will use when you mount the SD card there.

Once encrypted, insert the SD card into your Android device. It may prompt you to format the card – **do not do this**. To disable this notification, long-tap it, select the gear icon, and turn off system storage notifications. Note: This will also disable notifications for other devices, like USB sticks.

---

## Install Required Packages

On your Android device, open [Termux](https://f-droid.org/packages/com.termux/) and run the following commands to add the necessary repository and install required packages:

```bash
pkg upgrade
pkg install root-repo
pkg install bindfs cryptsetup blk-utils termux-api
pkg install nano wget  # Optional: For editing and downloading files
```

To receive notifications from the script, install the Termux:API app:

[Download Termux:API from F-Droid](https://f-droid.org/packages/com.termux.api/)

---

## Check LUKS Support

To verify if your device supports LUKS, run the following command. It should return `CONFIG_DM_CRYPT=y`:
```bash
su -Mc "zcat /proc/config.gz | grep CONFIG_DM_CRYPT"
```

Ensure the necessary encryption algorithms are available:
```bash
su -Mc "grep -E 'cipher|xts' /proc/crypto"
```

To identify your SD card's path:
```bash
su -Mc "lsblk"
```

In most cases, `mmcblk1` represents the entire SD card, while `mmcblk1p1` corresponds to the encrypted partition.

---

## Running the Script at Boot

Install the [Termux:Boot](https://f-droid.org/packages/com.termux.boot/) app and run it once to grant it permission to execute scripts at startup. After that, continue in Termux:

1. Open Termux and create the `~/.termux/boot/` directory:
   ```bash
   mkdir ~/.termux/boot/
   ```
2. Download the script and make it executable:
   ```bash
   cd ~/.termux/boot/
   wget https://raw.githubusercontent.com/pegelf/Android-LUKS-mount/refs/heads/main/01-mount-luks-sd.sh
   chmod +x 01-mount-luks-sd.sh
   ```
3. Edit the script variables to match your setup:
   ```bash
   nano 01-mount-luks-sd.sh
   ```

To test the script, run:
```bash
./01-mount-luks-sd.sh
```

The mount will persist even after closing Termux because the commands are executed with root permissions. After a reboot, the script will automatically execute at startup.

## Disclaimer
Using LUKS on an Android device works for me, but it may cause issues on your device. There is a possibility of data loss or rendering your device unbootable when using this script, so always back up your SD card and internal storage before proceeding and only use this script if you exactly know what you're doing.

If you have any feedback or questions, feel free to use the issues section of this repository.