#!/usr/bin/env bash
# Improved Arch installer script (fixed handling of partially-run installs and chroot/service issues)
# - Handles existing LUKS mappings / mounted points (closes/umounts before re-running)
# - Avoids systemctl calls that require DBus inside chroot (creates symlinks to enable units)
# - Ensures all pacman/pacstrap operations are non-interactive after explicit confirmations
# - Safer locale uncomment (simple, robust sed)
#
# Run as root from Arch live ISO. All prompts are ASCII. Destructive confirmations require exact YES.
set -euo pipefail
IFS=$'\n\t'

# ---------- Configuration ----------
DEFAULT_DISK="/dev/sda"
ESP_SIZE_G="1G"
ROOT_SIZE_G="120G"
HOME_SIZE_G="250G"
HOSTNAME="myarch"
USERNAME="user404"
USER_SHELL="/usr/bin/zsh"
TIMEZONE="Europe/Amsterdam"
BTRFS_MOUNT_OPTS="noatime,compress=zstd"
PACSTRAP_PKGS=(base linux linux-firmware btrfs-progs intel-ucode git nano networkmanager)
CHROOT_PKGS=(zsh zsh-completions sudo cryptsetup mkinitcpio snapper zram-generator \
             nvidia nvidia-utils nvidia-settings hyprland xorg-xwayland qt6-wayland egl-wayland \
             xdg-desktop-portal xdg-desktop-portal-hyprland firefox wezterm \
             ttf-nerd-fonts-symbols-mono noto-fonts noto-fonts-emoji ttf-dejavu)
# ----------------------------------------------------------------

log(){ printf '%s %s\n' "$(date -Is)" "$*"; }
err(){ log "ERROR: $*" >&2; exit 1; }

require_root(){
  if [ "$EUID" -ne 0 ]; then
    err "This script must be run as root."
  fi
}

pause_confirm(){
  local prompt="$1"
  local ans
  printf "\n%s\n" "$prompt"
  printf "Type YES to continue, anything else to abort: "
  read -r ans
  if [ "$ans" != "YES" ]; then
    err "User aborted."
  fi
}

# cleanup partial mounts and mappings that could block re-run
cleanup_partial(){
  log "Cleaning up potential previous mounts/mappings..."
  # Unmount common mountpoints under /mnt if present
  if mountpoint -q /mnt/boot 2>/dev/null; then umount /mnt/boot || true; fi
  if mountpoint -q /mnt/home 2>/dev/null; then umount -R /mnt/home || true; fi
  if mountpoint -q /mnt 2>/dev/null; then umount -R /mnt || true; fi

  # Close crypt mappings if open
  for m in root home; do
    if [ -e "/dev/mapper/$m" ]; then
      log "Found /dev/mapper/$m - attempting to close..."
      cryptsetup close "$m" || log "cryptsetup close $m failed or already closed"
    fi
  done

  # Ensure device-mapper nodes are removed
  sleep 1
}

# wait helper for background pids (spinner)
wait_for(){
  local pid=$1
  local delay=0.3
  local spin='|/-\'
  while kill -0 "$pid" 2>/dev/null; do
    for ((i=0;i<4;i++)); do
      printf "\r[%c] waiting..." "${spin:i:1}"
      sleep $delay
    done
  done
  printf "\r"
}

# check that required commands exist or try to install minimal ones
ensure_command(){
  local cmd=$1 pkg=$2
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log "$cmd missing, installing package $pkg (non-interactive)..."
    pacman -Sy --noconfirm --needed "$pkg"
  fi
}

main(){
  require_root
  log "Starting improved installer"

  log "Displaying block devices:"
  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE

  printf "\nDefault disk is %s\n" "$DEFAULT_DISK"
  printf "If you want another disk, enter full path (e.g. /dev/nvme0n1). Otherwise press ENTER to accept default: "
  read -r DISK_INPUT
  DISK="${DISK_INPUT:-$DEFAULT_DISK}"

  if [ ! -b "$DISK" ]; then
    err "Disk $DISK not found."
  fi

  # Basic safety: ensure we are on UEFI environment
  if [ ! -d /sys/firmware/efi ]; then
    log "Warning: EFI firmware not detected. Proceeding may fail for UEFI installation."
  fi

  cleanup_partial

  pause_confirm "WARNING: The script will DESTROY DATA on $DISK (partitions P1..P3). Proceed only if you are SURE."

  # ensure sgdisk available
  ensure_command sgdisk gptfdisk

  log "Creating GPT partitions on $DISK (ESP ${ESP_SIZE_G}, ROOT ${ROOT_SIZE_G}, HOME ${HOME_SIZE_G})..."
  sgdisk --zap-all "$DISK"
  sgdisk --clear "$DISK"
  sgdisk -n 1:0:+${ESP_SIZE_G} -t 1:ef00 "$DISK"
  sgdisk -n 2:0:+${ROOT_SIZE_G} -t 2:8300 "$DISK"
  sgdisk -n 3:0:+${HOME_SIZE_G} -t 3:8300 "$DISK"
  sgdisk -p "$DISK"
  partprobe "$DISK" || true
  sleep 1

  ESP="${DISK}1"
  P2="${DISK}2"
  P3="${DISK}3"

  log "Partitions set: ESP=$ESP, ROOT=$P2, HOME=$P3"

  pause_confirm "About to setup LUKS on ${P2} and ${P3} and create filesystems. This will irrevocably overwrite data on these partitions."

  # Before formatting, ensure any previously opened mappings are closed
  cleanup_partial

  # If partitions already contain LUKS and user wants to reuse instead of reformat, allow
  for part in "$P2" "$P3"; do
    if cryptsetup isLuks "$part" >/dev/null 2>&1; then
      log "$part already contains a LUKS header."
      printf "Do you want to REUSE existing LUKS on %s (open)? Type REUSE to open, FORMAT to reformat, or anything else to abort: " "$part"
      read -r choice
      case "$choice" in
        REUSE)
          log "Opening existing LUKS on $part. You will be prompted for passphrase."
          if [ "$part" = "$P2" ]; then cryptsetup open "$part" root; else cryptsetup open "$part" home; fi
          ;;
        FORMAT)
          log "Formatting (luksFormat) $part - you will be prompted to confirm and provide a new passphrase."
          cryptsetup luksFormat --type luks2 --pbkdf argon2id --iter-time 5000 "$part"
          if [ "$part" = "$P2" ]; then cryptsetup open "$part" root; else cryptsetup open "$part" home; fi
          ;;
        *)
          err "User aborted due to existing LUKS header on $part."
          ;;
      esac
    else
      # no LUKS header - create new
      log "Creating new LUKS on $part"
      cryptsetup luksFormat --type luks2 --pbkdf argon2id --iter-time 5000 "$part"
      if [ "$part" = "$P2" ]; then cryptsetup open "$part" root; else cryptsetup open "$part" home; fi
    fi
  done

  log "Formatting filesystems..."
  mkfs.fat -F32 "$ESP"
  mkfs.btrfs -f /dev/mapper/root
  mkfs.btrfs -f /dev/mapper/home

  log "Creating Btrfs subvolumes (root)..."
  mount /dev/mapper/root /mnt
  btrfs subvolume create /mnt/@
  btrfs subvolume create /mnt/@snapshots
  btrfs subvolume create /mnt/@var_log
  btrfs subvolume create /mnt/@var_tmp
  btrfs subvolume create /mnt/@pkg
  umount /mnt

  log "Creating Btrfs subvolumes (home)..."
  mount /dev/mapper/home /mnt
  btrfs subvolume create /mnt/@home
  btrfs subvolume create /mnt/@home.snapshots
  umount /mnt

  log "Mounting subvolumes to /mnt..."
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

  log "Running pacstrap (non-interactive)..."
  pacstrap /mnt "${PACSTRAP_PKGS[@]}" --noconfirm --needed

  log "Generating fstab..."
  genfstab -U /mnt > /mnt/etc/fstab

  # Create chroot helper script (improved)
  cat > /mnt/root/chroot_setup.sh <<'CHROOT'
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
log(){ printf '%s %s\n' "$(date -Is)" "$*"; }

log "Inside chroot: basic configuration starting..."

# Timezone and hwclock
ln -sf /usr/share/zoneinfo/Europe/Amsterdam /etc/localtime
hwclock --systohc || true

# Locale: safely uncomment two lines (remove leading '#' and spaces)
sed -i 's/^[[:space:]]*#\?[[:space:]]*en_US\.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen || true
sed -i 's/^[[:space:]]*#\?[[:space:]]*ru_RU\.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/' /etc/locale.gen || true
locale-gen || true
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Vconsole for TTY
cat >/etc/vconsole.conf <<'EOF'
KEYMAP=us
FONT=cyr-sun16
FONT_MAP=8859-5
EOF

echo "myarch" > /etc/hostname

log "Installing extra packages (non-interactive)..."
pacman -Syu --noconfirm --needed zsh zsh-completions sudo cryptsetup mkinitcpio snapper zram-generator \
    nvidia nvidia-utils nvidia-settings hyprland xorg-xwayland qt6-wayland egl-wayland \
    xdg-desktop-portal xdg-desktop-portal-hyprland firefox wezterm \
    ttf-nerd-fonts-symbols-mono noto-fonts noto-fonts-emoji ttf-dejavu || true

log "Creating user and setting passwords (interactive prompts)..."
if ! id -u user404 >/dev/null 2>&1; then
  useradd -m -G wheel -s /usr/bin/zsh user404 || true
fi

echo "Please set password for root:"
passwd
echo "Please set password for user404:"
passwd user404

echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

log "NVIDIA early KMS options"
mkdir -p /etc/modprobe.d
cat >/etc/modprobe.d/nvidia.conf <<'EOF'
options nvidia-drm modeset=1
EOF

log "Configuring mkinitcpio for systemd + btrfs + kms"
sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_drm nvidia_modeset btrfs)/' /etc/mkinitcpio.conf || true
sed -i 's%^BINARIES=.*%BINARIES=(/usr/bin/btrfs)%' /etc/mkinitcpio.conf || true
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect modconf kms keyboard sd-vconsole block sd-encrypt btrfs filesystems fsck)/' /etc/mkinitcpio.conf || true
mkinitcpio -P || true

log "Installing systemd-boot"
bootctl install || true

UUID_ROOT=$(blkid -s UUID -o value /dev/sda2 || blkid -s UUID -o value /dev/mapper/root || true)
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

log "Writing /etc/crypttab for home"
UUID_HOME=$(blkid -s UUID -o value /dev/sda3 || blkid -s UUID -o value /dev/mapper/home || true)
cat >/etc/crypttab <<EOF
home    UUID=${UUID_HOME}    none    luks,discard
EOF

log "Enabling services by creating systemd symlinks (avoiding systemctl DBus requirement)"
mkdir -p /etc/systemd/system/multi-user.target.wants
mkdir -p /etc/systemd/system/timers.target.wants

# Link NetworkManager into multi-user target
if [ -f /usr/lib/systemd/system/NetworkManager.service ]; then
  ln -sf /usr/lib/systemd/system/NetworkManager.service /etc/systemd/system/multi-user.target.wants/NetworkManager.service
fi
# Link fstrim.timer into timers.target
if [ -f /usr/lib/systemd/system/fstrim.timer ]; then
  ln -sf /usr/lib/systemd/system/fstrim.timer /etc/systemd/system/timers.target.wants/fstrim.timer
fi

log "Configuring zram-generator (file created, enabling swap unit deferred to boot-time generator)"
cat >/etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = 16G
compression-algorithm = zstd
EOF

log "Installing and configuring snapper (manual snapshots)"
pacman -S --noconfirm --needed snapper || true
snapper -c root create-config / || true
snapper -c home create-config /home || true
sed -i 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="no"/' /etc/snapper/configs/root || true
sed -i 's/^NUMBER_CLEANUP=.*/NUMBER_CLEANUP="no"/' /etc/snapper/configs/root || true
sed -i 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="no"/' /etc/snapper/configs/home || true
sed -i 's/^NUMBER_CLEANUP=.*/NUMBER_CLEANUP="no"/' /etc/snapper/configs/home || true
snapper -c root create --description "baseline-0" || true

log "Hyprland user config and zprofile"
install -d -m 0700 -o user404 -g user404 /home/user404/.config
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
chown -R user404:user404 /home/user404/.config || true

cat >/home/user404/.zprofile <<'EOF'
if [ "$(tty)" = "/dev/tty1" ]; then
  exec dbus-run-session Hyprland
fi
EOF
chown user404:user404 /home/user404/.zprofile || true
chmod 0644 /home/user404/.zprofile || true

log "Permissions hygiene"
chmod 0644 /etc/mkinitcpio.conf /boot/loader/loader.conf || true
chmod 0644 /boot/loader/entries/arch.conf || true
chmod 0600 /etc/crypttab || true
install -d -m 0700 -o user404 -g user404 /home/user404/.config
chown -R user404:user404 /home/user404/.config || true

log "Chroot script finished."
CHROOT

  chmod +x /mnt/root/chroot_setup.sh

  log "Entering chroot to run configuration script (arch-chroot /mnt /root/chroot_setup.sh)..."
  arch-chroot /mnt /root/chroot_setup.sh || {
    log "Warning: chroot script returned non-zero exit code. Inspect /mnt/root/chroot_setup.sh and /var/log for details."
  }

  log "Removing chroot helper..."
  rm -f /mnt/root/chroot_setup.sh || true

  log "Final cleanup and reboot prompt."
  printf "\nInstallation main steps finished. Type YES to unmount /mnt, close LUKS mappings and reboot now. Anything else will leave the system mounted for manual inspection: "
  read -r final
  if [ "$final" = "YES" ]; then
    log "Unmounting and closing mappings..."
    umount -R /mnt || true
    cryptsetup close root || true
    cryptsetup close home || true
    reboot
  else
    log "Finished without reboot. /mnt remains mounted for inspection."
    exit 0
  fi
}

main "$@"
