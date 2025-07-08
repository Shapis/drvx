#!/bin/bash

# This script automates the creation of a custom Debian live ISO
# with a desktop environment and a specific binary downloaded into /usr/local/bin.

#-------------------------------
# Step 0: Run as root check
#-------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run with sudo or as root"
    sudo -v  # Prompt for sudo password
    if [[ $? -ne 0 ]]; then
        echo "Failed to acquire sudo privileges. Exiting."
        exit 1
    fi
fi

#-------------------------------
# Step 1: Define configuration variables
#-------------------------------
LIVE_DIR=~/debian-live                         # Working directory
DESKTOP_ENV="task-xfce-desktop"               # Desktop environment (change if desired)
PREINSTALLED_APPS="git curl"                  # Extra packages to include in live ISO
FILE_URL="https://github.com/Shapis/drvx/releases/download/Binary2/drvx"  # Binary URL
SAVE_PATH="/usr/local/bin/drvx"               # Destination inside live system
ISO_NAME="debian-live-custom.iso"             # Output ISO name

#-------------------------------
# Step 2: Install dependencies
#-------------------------------
echo "[*] Installing live-build and curl..."
sudo apt update
sudo apt install -y live-build curl

#-------------------------------
# Step 3: Set up live-build directory
#-------------------------------
echo "[*] Creating working directory..."
mkdir -p "$LIVE_DIR"
cd "$LIVE_DIR" || exit 1

#-------------------------------
# Step 4: Configure live-build
#-------------------------------
echo "[*] Configuring live-build..."
lb config \
--distribution bookworm \
--debian-installer live \
--archive-areas "main contrib non-free non-free-firmware" \
--bootappend-live "boot=live components quiet splash"

#-------------------------------
# Step 5: Add package list (desktop + extras)
#-------------------------------
echo "[*] Adding package list..."
mkdir -p config/package-lists
echo "$PREINSTALLED_APPS" > config/package-lists/custom.list.chroot
echo "$DESKTOP_ENV" > config/package-lists/desktop.list.chroot

#-------------------------------
# Step 6: Create hook to download binary during build
#-------------------------------
echo "[*] Creating chroot hook to download drvx binary..."
mkdir -p config/hooks/normal
cat << EOF > config/hooks/normal/01-download-drvx.chroot
#!/bin/bash
set -e

echo "[HOOK] Downloading drvx binary into $SAVE_PATH..."
curl -L "$FILE_URL" -o "$SAVE_PATH"
chmod +x "$SAVE_PATH"
EOF

# Make sure the hook is executable
chmod +x config/hooks/normal/01-download-drvx.chroot

#-------------------------------
# Step 7: Build the ISO
#-------------------------------
echo "[*] Building the Debian live ISO (this may take some time)..."
sudo lb build

#-------------------------------
# Step 8: Rename the ISO file
#-------------------------------
if [ -f live-image-amd64.hybrid.iso ]; then
    mv live-image-amd64.hybrid.iso "$ISO_NAME"
    echo "[*] ISO renamed to: $ISO_NAME"
else
    echo "[!] Error: ISO was not generated as expected."
    exit 1
fi

#-------------------------------
# Step 8.5: Cleanup everything except the ISO
#-------------------------------
echo "[*] Cleaning up temporary build files..."
find "$LIVE_DIR" -mindepth 1 ! -name "$ISO_NAME" -exec sudo rm -rf {} +

#-------------------------------
# Step 9: Done & Open Folder
#-------------------------------
echo "[✓] Process complete!"
echo "Your custom Debian Live ISO is ready: $LIVE_DIR/$ISO_NAME"
xdg-open "$LIVE_DIR" >/dev/null 2>&1 &
