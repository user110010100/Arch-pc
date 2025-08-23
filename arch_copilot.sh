#!/usr/bin/env bash
# Improved Arch installer script (fixes: re-run safety, hyprland config creation, snapper fallback)
# Run from Arch live ISO as root. Prompts and messages use ASCII only.
# Safety: destructive confirmations require exact "YES".
set -euo pipefail
IFS=$'\n\t'

# ---------- Config (edit only if you know what you do) ----------
DEFAULT_DISK="/dev/sda"
ESP_SIZE_G="1G"
ROOT_SIZE_G="120G"
HOME_SIZE_G="250G"
HOSTNAME="arch-pc"
USERNAME="user404"
USER_SHELL="/usr/bin/zsh"
TIMEZONE="Europe/Amsterdam"
BTRFS_MOUNT_OPTS="noatime,compress=zstd"
PACSTRAP_PKGS=(base linux linux-firmware btrfs-progs intel-ucode git nano networkmanager)
# ----------------------------------------------------------------

log(){ printf '%s %s\n' "$(date -Is)" "$*"; }
err(){ log "ERROR: $*" >&2; exit 1; }

require_root(){ [ "$EUID" -eq 0 ] || err "This script must be run as root."; }

pause_confirm(){
  local prompt="$1" ans
  printf "\n%s\n" "$prompt"
  printf "Type YES to continue, anything else to abort: "
  read -r ans
  [ "$ans" = "YES" ] || err "User aborted."
}

# Unmount /mnt and close mappings if partially left by previous run
cleanup_partial(){
  log "Cleaning up previous mounts and mappings if any..."
  # unmount safely (ignore errors)
  if mountpoint -q /mnt/boot 2>/dev/null; then umount /mnt/boot || true; fi
  if mountpoint -q /mnt/home 2>/dev/null; then umount -R /mnt/home || true; fi
  if mountpoint -q /mnt 2>/dev/null; then umount -R /mnt || true; fi

  # close crypt mappings if open
  for m in root home; do
    if [ -e "/dev/mapper/$m" ]; then
      log "Closing /dev/mapper/$m"
      cryptsetup close "$m" || log "cryptsetup close $m failed or already closed"
    fi
  done
  sleep 1
}

ensure_command(){
  local cmd=$1 pkg=$2
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log "$cmd missing - installing $pkg (non-interactive)"
    pacman -Sy --noconfirm --needed "$pkg"
  fi
}

# chroot helper content (we write this into /mnt/root/chroot_setup.sh and run via arch-chroot)
generate_chroot_script(){
cat > /mnt/root/chroot_setup.sh <<'CHROOT'
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
log(){ printf '%s %s\n' "$(date -Is)" "$*"; }

log "Chroot: basic configuration..."
ln -sf /usr/share/zoneinfo/Europe/Amsterdam /etc/localtime
hwclock --systohc || true

# Safe locale uncomment (remove optional leading '#' and spaces)
sed -i 's/^[[:space:]]*#\?[[:space:]]*en_US\.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen || true
sed -i 's/^[[:space:]]*#\?[[:space:]]*ru_RU\.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/' /etc/locale.gen || true
locale-gen || true
echo "LANG=en_US.UTF-8" > /etc/locale.conf

cat >/etc/vconsole.conf <<'EOF'
KEYMAP=us
FONT=cyr-sun16
FONT_MAP=8859-5
EOF

echo "arch-pc" > /etc/hostname

log "Installing additional packages (non-interactive)..."
pacman -Syu --noconfirm --needed \
  zsh zsh-completions sudo cryptsetup mkinitcpio snapper zram-generator \
  nvidia nvidia-utils nvidia-settings hyprland xorg-xwayland qt6-wayland egl-wayland \
  xdg-desktop-portal xdg-desktop-portal-hyprland firefox wezterm \
  ttf-nerd-fonts-symbols-mono noto-fonts noto-fonts-emoji ttf-dejavu || true

log "Creating user (if needed) and prompting for passwords..."
if ! id -u user404 >/dev/null 2>&1; then
  useradd -m -G wheel -s /usr/bin/zsh user404 || true
fi
echo "Set password for root:"
passwd
echo "Set password for user404:"
passwd user404
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

log "NVIDIA modprobe options"
mkdir -p /etc/modprobe.d
cat >/etc/modprobe.d/nvidia.conf <<'EOF'
options nvidia-drm modeset=1
EOF

log "Configuring mkinitcpio (systemd + btrfs + kms)"
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
chmod 0600 /etc/crypttab || true

log "Enable services by symlinks (avoid systemctl in chroot)"
mkdir -p /etc/systemd/system/multi-user.target.wants /etc/systemd/system/timers.target.wants
[ -f /usr/lib/systemd/system/NetworkManager.service ] && ln -sf /usr/lib/systemd/system/NetworkManager.service /etc/systemd/system/multi-user.target.wants/NetworkManager.service
[ -f /usr/lib/systemd/system/fstrim.timer ] && ln -sf /usr/lib/systemd/system/fstrim.timer /etc/systemd/system/timers.target.wants/fstrim.timer

log "Configure zram-generator"
cat >/etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = 16G
compression-algorithm = zstd
swap-priority = 100
EOF

# --- Snapper: try normal create-config, fallback to template if it fails ---
log "Attempting snapper create-config for root and home..."
if snapper -v >/dev/null 2>&1; then
  if ! snapper -c root create-config / >/dev/null 2>&1; then
    log "snapper create-config root failed - using fallback template"
    mkdir -p /etc/snapper/configs
    cat >/etc/snapper/configs/root <<'EOF'
# Minimal snapper config for root
FSTYPE="btrfs"
SUBVOLUME="/"
TIMELINE_CREATE="no"
NUMBER_CLEANUP="no"
EOF
  fi

  if ! snapper -c home create-config /home >/dev/null 2>&1; then
    log "snapper create-config home failed - using fallback template"
    mkdir -p /etc/snapper/configs
    cat >/etc/snapper/configs/home <<'EOF'
# Minimal snapper config for home
FSTYPE="btrfs"
SUBVOLUME="/home"
TIMELINE_CREATE="no"
NUMBER_CLEANUP="no"
EOF
  fi
else
  log "snapper not present - skipping snapper config"
fi

# try to create baseline snapshot for root when config exists
if [ -f /etc/snapper/configs/root ]; then
  snapper -c root create --description "baseline-0" || log "snapper baseline creation failed or not available"
fi

# --- Hyprland user config: ensure dir exists BEFORE any zprofile autostart ---
log "Creating hyprland and wezterm configs for user404"
install -d -m 0700 -o user404 -g user404 /home/user404/.config/hypr
install -d -m 0700 -o user404 -g user404 /home/user404/.config/wezterm

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
chown user404:user404 /home/user404/.config/hypr/hyprland.conf || true
chmod 0644 /home/user404/.config/hypr/hyprland.conf || true

cat >/home/user404/.config/wezterm/wezterm.lua <<'EOF'
local wezterm = require "wezterm"
return {
  enable_wayland = false,
  font = wezterm.font_with_fallback({
    "DejaVu Sans Mono",
    "Symbols Nerd Font Mono",
    "Noto Color Emoji",
  }),
}
EOF
chown -R user404:user404 /home/user404/.config/wezterm || true

cat >/home/user404/.zprofile <<'EOF'
# Start Hyprland only on tty1 to avoid accidental autostart during chroot/config
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
install -d -m 0700 -o user404 -g user404 /home/user404/.config || true
chown -R user404:user404 /home/user404/.config || true

log "Chroot script completed."
CHROOT
}

main(){
  require_root
  log "Start installation (improved fixes)"

  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE

  printf "\nDefault disk is %s\n" "$DEFAULT_DISK"
  printf "If you want another, enter full path (e.g. /dev/nvme0n1). Otherwise press ENTER: "
  read -r DISK_INPUT
  DISK="${DISK_INPUT:-$DEFAULT_DISK}"
  [ -b "$DISK" ] || err "Disk $DISK not found."

  cleanup_partial

  pause_confirm "WARNING: This will DESTROY DATA on $DISK (partitions P1..P3). Proceed only when you are sure."

  ensure_command sgdisk gptfdisk

  log "Partitioning $DISK..."
  sgdisk --zap-all "$DISK"
  sgdisk --clear "$DISK"
  sgdisk -n 1:0:+${ESP_SIZE_G} -t 1:ef00 "$DISK"
  sgdisk -n 2:0:+${ROOT_SIZE_G} -t 2:8309 "$DISK"
  sgdisk -n 3:0:+${HOME_SIZE_G} -t 3:8309 "$DISK"
  sgdisk -p "$DISK"
  partprobe "$DISK" || true
  sleep 1

  ESP="${DISK}1"
  P2="${DISK}2"
  P3="${DISK}3"
  log "ESP=$ESP, ROOT=$P2, HOME=$P3"

  pause_confirm "About to create LUKS on $P2 and $P3 and format filesystems."

  cleanup_partial

  # Handle existing LUKS intelligently to avoid "device in use" on reruns
  for part in "$P2" "$P3"; do
    if cryptsetup isLuks "$part" >/dev/null 2>&1; then
      log "$part already contains LUKS header."
      printf "Type REUSE to open existing LUKS on %s, FORMAT to reformat (destroy contents), anything else to abort: " "$part"
      read -r choice
      case "$choice" in
        REUSE) [ "$part" = "$P2" ] && cryptsetup open "$part" root || cryptsetup open "$part" home ;;
        FORMAT) cryptsetup luksFormat --type luks2 --pbkdf argon2id --iter-time 5000 "$part"; [ "$part" = "$P2" ] && cryptsetup open "$part" root || cryptsetup open "$part" home ;;
        *) err "Aborted due to existing LUKS on $part." ;;
      esac
    else
      cryptsetup luksFormat --type luks2 --pbkdf argon2id --iter-time 5000 "$part"
      [ "$part" = "$P2" ] && cryptsetup open "$part" root || cryptsetup open "$part" home
    fi
  done

  log "Formatting filesystems..."
  mkfs.fat -F32 "$ESP"
  mkfs.btrfs -f /dev/mapper/root
  mkfs.btrfs -f /dev/mapper/home

  log "Creating btrfs subvolumes..."
  mount /dev/mapper/root /mnt
  btrfs subvolume create /mnt/@ || true
  btrfs subvolume create /mnt/@snapshots || true
  btrfs subvolume create /mnt/@var_log || true
  btrfs subvolume create /mnt/@var_tmp || true
  btrfs subvolume create /mnt/@pkg || true
  umount /mnt || true

  mount /dev/mapper/home /mnt
  btrfs subvolume create /mnt/@home || true
  btrfs subvolume create /mnt/@home.snapshots || true
  umount /mnt || true

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

  log "Installing base packages with pacstrap (non-interactive)..."
  pacstrap /mnt "${PACSTRAP_PKGS[@]}" --noconfirm --needed

  log "Generating /etc/fstab"
  genfstab -U /mnt > /mnt/etc/fstab

  log "Creating chroot helper script"
  generate_chroot_script
  chmod +x /mnt/root/chroot_setup.sh

  log "Running chroot script (arch-chroot /mnt /root/chroot_setup.sh)"
  # If chroot script fails, we continue so user can inspect; provide message.
  if ! arch-chroot /mnt /root/chroot_setup.sh; then
    log "Warning: chroot helper exited with non-zero status. Inspect /mnt/root/chroot_setup.sh output and /mnt/var/log for details."
  fi

  log "Removing chroot helper"
  rm -f /mnt/root/chroot_setup.sh || true

  printf "\nFinished main install steps. Type YES to unmount /mnt, close LUKS mappings and reboot now, anything else to abort and keep /mnt mounted for inspection: "
  read -r final
  if [ "$final" = "YES" ]; then
    log "Unmounting /mnt and closing LUKS mappings..."
    umount -R /mnt || true
    cryptsetup close root || true
    cryptsetup close home || true
    reboot
  else
    log "Leaving system mounted at /mnt for manual inspection."
    exit 0
  fi
}

main "$@"
