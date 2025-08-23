#!/usr/bin/env bash
# Minimal Arch installer script (UEFI, LUKS on /dev/sda, Btrfs subvolumes, systemd-boot, Hyprland)
# Based on provided spec. All prompts are in ASCII (Latin). Confirm destructive actions with YES.
# Run from Arch live ISO as root.
#
# Usage: boot live ISO -> connect internet -> mount repo if needed -> su - (root) -> ./arch_install_min.sh
set -euo pipefail
IFS=$'\n\t'

# -------- Configuration (edit only if you know what you do) ----------
DEFAULT_DISK="/dev/sda"
ESP_SIZE_G="1G"
ROOT_SIZE_G="120G"
HOME_SIZE_G="250G"
HOSTNAME="arch-pc"
USERNAME="user404"
USER_SHELL="/usr/bin/zsh"
TIMEZONE="Europe/Moscow"
LOCALE_MAIN="en_US.UTF-8 UTF-8"
LOCALE_RU="ru_RU.UTF-8 UTF-8"
BTRFS_MOUNT_OPTS="noatime,compress=zstd"
# Packages installed via pacstrap (minimal) and extra in chroot
PACSTRAP_PKGS=(base linux linux-firmware btrfs-progs intel-ucode git nano networkmanager)
CHROOT_PKGS=(zsh zsh-completions sudo cryptsetup mkinitcpio linux-headers snapper zram-generator \
             nvidia nvidia-utils nvidia-settings hyprland xorg-xwayland qt6-wayland egl-wayland \
             xdg-desktop-portal xdg-desktop-portal-hyprland firefox wezterm \
             ttf-nerd-fonts-symbols-mono noto-fonts noto-fonts-emoji ttf-dejavu)
# --------------------------------------------------------------------

log() { printf '%s %s\n' "$(date -Is)" "$*"; }
err() { log "ERROR: $*" >&2; exit 1; }

require_root() {
  if [ "$EUID" -ne 0 ]; then
    err "This script must be run as root."
  fi
}

pause_for_user_confirm() {
  local prompt="$1"
  local answer
  printf "\n%s\n" "$prompt"
  printf "Type YES to continue, anything else to abort: "
  read -r answer
  if [ "$answer" != "YES" ]; then
    err "User aborted."
  fi
}

check_command() {
  command -v "$1" >/dev/null 2>&1 || return 1
}

install_if_missing() {
  local pkg="$1"
  if ! pacman -Qq "$pkg" >/dev/null 2>&1; then
    log "Installing helper package: $pkg (non-interactive)"
    pacman -S --noconfirm --needed "$pkg"
  fi
}

# Wait helper - long running commands
wait_for() {
  local pid=$1
  # simple spinner while process runs
  local -r delay=0.5
  local spinstr='|/-\'
  while kill -0 "$pid" 2>/dev/null; do
    for i in $(seq 1 4); do
      printf "\r[%c] waiting..." "${spinstr:i-1:1}"
      sleep $delay
    done
  done
  printf "\r"
}

# -------- Main flow ----------
require_root

log "Displaying block devices. Check which disk to use."
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE

printf "\nDefault disk is %s\n" "$DEFAULT_DISK"
printf "If you want to use a different disk, enter full path (e.g. /dev/nvme0n1). Otherwise press ENTER to accept default: "
read -r DISK_INPUT
DISK="${DISK_INPUT:-$DEFAULT_DISK}"

if [ ! -b "$DISK" ]; then
  err "Disk $DISK not found as block device."
fi

pause_for_user_confirm "WARNING: The script will DESTROY ALL DATA on $DISK. Proceed only when you are SURE."

log "Ensuring gptfdisk (sgdisk) is available..."
if ! check_command sgdisk; then
  log "sgdisk not found. Will install gptfdisk (pacman). This will be non-interactive."
  pacman -Sy --noconfirm gptfdisk
fi

log "Creating new GPT on $DISK and partitions (ESP 1G, ROOT ${ROOT_SIZE_G}, HOME ${HOME_SIZE_G}, rest left unpartitioned)."
# Create GPT and partitions using sgdisk
sgdisk --zap-all "$DISK"
sgdisk --clear "$DISK"
# Partition 1: ESP, type EF00
sgdisk -n 1:0:+${ESP_SIZE_G} -t 1:ef00 "$DISK"
# Partition 2: ROOT
sgdisk -n 2:0:+${ROOT_SIZE_G} -t 2:8303 "$DISK"
# Partition 3: HOME
sgdisk -n 3:0:+${HOME_SIZE_G} -t 3:8303 "$DISK"
# Write changes
sgdisk -p "$DISK"
log "Partitioning done. Running partprobe..."
partprobe "$DISK" || true
sleep 1

ESP="${DISK}1"
P2="${DISK}2"
P3="${DISK}3"

log "Partitions: ESP=$ESP, ROOT=$P2, HOME=$P3"

pause_for_user_confirm "About to setup LUKS on ${P2} and ${P3} and format filesystems. This will overwrite these partitions."

log "Setting up LUKS (LUKS2, argon2id) on $P2 and $P3. You will be prompted for passphrases twice (root and home)."
cryptsetup luksFormat --type luks2 --pbkdf argon2id --iter-time 5000 "$P2"
cryptsetup open "$P2" root
cryptsetup luksFormat --type luks2 --pbkdf argon2id --iter-time 5000 "$P3"
cryptsetup open "$P3" home

log "Formatting filesystems..."
mkfs.fat -F32 "$ESP"
mkfs.btrfs -f /dev/mapper/root
mkfs.btrfs -f /dev/mapper/home

log "Creating Btrfs subvolumes for root..."
mount /dev/mapper/root /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@var_tmp
btrfs subvolume create /mnt/@pkg
umount /mnt

log "Creating Btrfs subvolumes for home..."
mount /dev/mapper/home /mnt
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@home.snapshots
umount /mnt

log "Mounting subvolumes..."
mount -o ${BTRFS_MOUNT_OPTS},subvol=@ /dev/mapper/root /mnt
mkdir -p /mnt/.snapshots /mnt/var/log /mnt/var/tmp /mnt/var/cache/pacman/pkg /mnt/home
mount -o ${BTRFS_MOUNT_OPTS},subvol=@snapshots /dev/mapper/root /mnt/.snapshots
mount -o ${BTRFS_MOUNT_OPTS},subvol=@var_log   /dev/mapper/root /mnt/var/log
mount -o ${BTRFS_MOUNT_OPTS},subvol=@var_tmp   /dev/mapper/root /mnt/var/tmp
mount -o ${BTRFS_MOUNT_OPTS},subvol=@pkg       /dev/mapper/root /mnt/var/cache/pacman/pkg

mount -o ${BTRFS_MOUNT_OPTS},subvol=@home /dev/mapper/home /mnt/home
mkdir -p /mnt/home/.snapshots
mount -o ${BTRFS_MOUNT_OPTS},subvol=@home.snapshots /dev/mapper/home /mnt/home/.snapshots

mkdir -p /mnt/boot
mount "$ESP" /mnt/boot

log "Ready to install base system with pacstrap."
printf "Packages to be installed via pacstrap: %s\n" "${PACSTRAP_PKGS[*]}"
pause_for_user_confirm "Proceed to run pacstrap (will run non-interactively after you confirm)?"

# Run pacstrap non-interactively to avoid interactive pacman prompt issues. User already confirmed.
log "Running pacstrap..."
pacstrap /mnt "${PACSTRAP_PKGS[@]}" --noconfirm --needed

log "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# Create chroot helper script
cat > /mnt/root/chroot_setup.sh <<'CHROOT_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
log(){ printf '%s %s\n' "$(date -Is)" "$*"; }

# -------------- Inside chroot --------------
log "Configuring locale, timezone, hostname..."

# Timezone
ln -sf /usr/share/zoneinfo/Europe/Amsterdam /etc/localtime
hwclock --systohc

# Uncomment locales (safe sed: remove leading '#' and any spaces) for en_US and ru_RU
sed -i 's/^[[:space:]]*#\?[[:space:]]*en_US\.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen || true
sed -i 's/^[[:space:]]*#\?[[:space:]]*ru_RU\.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/' /etc/locale.gen || true
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Vconsole for TTY
cat >/etc/vconsole.conf <<'EOF'
KEYMAP=us
FONT=cyr-sun16
FONT_MAP=8859-5
EOF

echo "myarch" > /etc/hostname

log "Installing additional packages in chroot..."
# We run pacman non-interactively to avoid broken interactive prompts in scripted run.
pacman -Syu --noconfirm --needed zsh zsh-completions sudo cryptsetup mkinitcpio snapper zram-generator \
    nvidia nvidia-utils nvidia-settings hyprland xorg-xwayland qt6-wayland egl-wayland \
    xdg-desktop-portal xdg-desktop-portal-hyprland firefox wezterm \
    ttf-nerd-fonts-symbols-mono noto-fonts noto-fonts-emoji ttf-dejavu

log "Creating user and setting up sudo..."
# Create user (if not exists) and set shell
if ! id -u user404 >/dev/null 2>&1; then
  useradd -m -G wheel -s /usr/bin/zsh user404 || true
fi

echo "Set password for root now."
passwd
echo "Set password for user user404 now."
passwd user404
# Ensure wheel group has sudo
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

log "NVIDIA early KMS: modprobe options"
mkdir -p /etc/modprobe.d
cat >/etc/modprobe.d/nvidia.conf <<'EOF'
options nvidia-drm modeset=1
EOF

log "Configuring mkinitcpio for systemd + btrfs + kms"
# Replace MODULES, BINARIES, and HOOKS lines
sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_drm nvidia_modeset btrfs)/' /etc/mkinitcpio.conf
sed -i 's%^BINARIES=.*%BINARIES=(/usr/bin/btrfs)%' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect modconf kms keyboard sd-vconsole block sd-encrypt btrfs filesystems fsck)/' /etc/mkinitcpio.conf

mkinitcpio -P

log "Installing systemd-boot and creating loader entries..."
bootctl install

UUID_ROOT=$(blkid -s UUID -o value /dev/sda2 || true)
if [ -z "$UUID_ROOT" ]; then
  # fallback: attempt to read by PARTLABEL or use /dev/sda2
  UUID_ROOT=$(blkid -s UUID -o value /dev/mapper/root || true)
fi

cat >/boot/loader/loader.conf <<'EOF'
default arch.conf
timeout 1
console-mode max
editor no
auto-entries yes
EOF

cat >/boot/loader/entries/arch.conf <<EOF
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options rd.luks.name=${UUID_ROOT}=root rd.luks.options=discard root=/dev/mapper/root rootflags=subvol=@,compress=zstd rw nvidia-drm.modeset=1
EOF

log "Writing /etc/crypttab for home with discard"
UUID_HOME=$(blkid -s UUID -o value /dev/sda3 || true)
cat >/etc/crypttab <<EOF
home    UUID=${UUID_HOME}    none    luks,discard
EOF

log "Enabling services: NetworkManager, fstrim.timer"
systemctl enable NetworkManager
systemctl enable fstrim.timer

log "Configuring zram (zram-generator)"
cat >/etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = 16G
compression-algorithm = zstd
EOF

systemctl daemon-reload || true
# enable expected swap unit (name may vary); enable target device swap unit if present
if systemctl list-units --full --all | grep -q 'dev-zram0.swap'; then
  systemctl enable dev-zram0.swap || true
fi

log "Setting up snapper for root and home (manual snapshots only)"
pacman -S --noconfirm --needed snapper
snapper -c root create-config /
snapper -c home create-config /home || true
# Disable timeline and auto NUMBER cleanup
sed -i 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="no"/' /etc/snapper/configs/root || true
sed -i 's/^NUMBER_CLEANUP=.*/NUMBER_CLEANUP="no"/' /etc/snapper/configs/root || true
sed -i 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="no"/' /etc/snapper/configs/home || true
sed -i 's/^NUMBER_CLEANUP=.*/NUMBER_CLEANUP="no"/' /etc/snapper/configs/home || true
snapper -c root create --description "baseline-0" || true

log "Hyprland and user configs"
install -d -m 0700 -o user404 -g user404 /home/user404/.config/hypr
cat >/home/user404/.config/hypr/hyprland.conf <<'EOF'
monitor = DP-1, 1920x1080@60, 0x0, 1
monitor = HDMI-A-1, 1920x1080@60, 1920x0, 1

workspace = 1, monitor:DP-1
workspace = 2, monitor:HDMI-A-1

$mainMod = SUPER
$terminal = wezterm

input {
  kb_layout = us,ru
  kb_options = grp:caps_toggle,terminate:ctrl_alt_bksp
}

bind = $mainMod, Q, exec, $terminal
bind = $mainMod, Return, exec, $terminal

exec-once = firefox
exec-once = wezterm
EOF
chown -R user404:user404 /home/user404/.config

cat >/home/user404/.zprofile <<'EOF'
if [ "$(tty)" = "/dev/tty1" ]; then
  exec dbus-run-session Hyprland
fi
EOF
chown user404:user404 /home/user404/.zprofile
chmod 0644 /home/user404/.zprofile

log "Permissions hygiene"
chmod 0644 /etc/mkinitcpio.conf /boot/loader/loader.conf || true
chmod 0644 /boot/loader/entries/arch.conf || true
chmod 0600 /etc/crypttab || true
install -d -m 0700 -o user404 -g user404 /home/user404/.config
chown -R user404:user404 /home/user404/.config

log "Chroot setup complete. Exit to continue on host."
# End of chroot script
CHROOT_SCRIPT

chmod +x /mnt/root/chroot_setup.sh

log "Entering chroot to finalize setup. You will be prompted for root and user passwords inside chroot."
arch-chroot /mnt /root/chroot_setup.sh

log "Cleaning up chroot helper..."
rm -f /mnt/root/chroot_setup.sh

log "Final steps: unmounting and reboot suggestion."
echo "Installation finished (most steps). Run final checks if needed."
echo "To finalize: exit, umount -R /mnt and reboot."
printf "\nReady to exit script. Type YES to unmount /mnt and reboot now, anything else to abort and stay in live environment: "
read -r FINAL_ANS
if [ "$FINAL_ANS" = "YES" ]; then
  log "Attempting to unmount and reboot..."
  umount -R /mnt || true
  cryptsetup close root || true
  cryptsetup close home || true
  reboot
else
  log "Aborting reboot. You can manually unmount and reboot later."
  exit 0
fi
