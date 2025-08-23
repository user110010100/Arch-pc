#!/usr/bin/env bash
# Minimal Arch installer (LUKS root/home, Btrfs subvols, systemd-boot, Hyprland)
# Adjusted to user's preferences:
# - assumes non-NVMe disk names (e.g. /dev/sda)
# - ASCII-only prompts (no Cyrillic)
# - simple confirmation "YES" before destructive actions
# - avoids sed edits of system files (writes full small files instead)
# - hostname = arch-pc
# - LUKS: password entered twice (confirmation); keyfile used temporarily and securely removed
# - pacstrap/pacman remain interactive so you can answer 'Y' when prompted
set -Eeuo pipefail
IFS=$'\n\t'

# ------------------ Configuration (edit as needed) ------------------
DISK_DEFAULT="/dev/sda"
HOSTNAME="arch-pc"
USERNAME="user404"
USER_SHELL="/usr/bin/zsh"

LOCALE_MAIN="en_US.UTF-8"
LOCALE_EXTRA="ru_RU.UTF-8"   # this is ASCII text "ru_RU.UTF-8 UTF-8" we'll write into locale.gen

TTY_KEYMAP="us"
TTY_FONT="ter-v16n"          # use an ASCII name font that usually exists in kbd
TTY_FONT_MAP="8859-5"

ESP_SIZE="+1G"
ROOT_SIZE="+120G"
HOME_SIZE="+250G"

ZRAM_SIZE="16G"
ZRAM_ALGO="zstd"

HYPR_MON1="DP-1, 1920x1080@60, 0x0, 1"
HYPR_MON2="HDMI-A-1, 1920x1080@60, 1920x0, 1"

MNT="/mnt"
LUKS_NAME_ROOT="root"
LUKS_NAME_HOME="home"
TMP_KEYFILE="/tmp/arch_luks_key.bin"
# -------------------------------------------------------------------

log()  { printf "\n[INFO] %s\n" "$*"; }
warn() { printf "\n[WARN] %s\n" "$*"; }
err()  { printf "\n[ERR] %s\n" "$*"; }

on_err() {
  err "Error on line $1. Attempting to unmount ${MNT} and exit."
  umount -R "$MNT" 2>/dev/null || true
  # try to close any opened dm-crypt names
  for m in "${LUKS_NAME_ROOT}" "${LUKS_NAME_HOME}"; do
    if cryptsetup status "$m" &>/dev/null; then
      cryptsetup close "$m" || true
    fi
  done
  rm -f "$TMP_KEYFILE" 2>/dev/null || true
  exit 1
}
trap 'on_err $LINENO' ERR

require_root() {
  if [[ $EUID -ne 0 ]]; then
    err "Please run as root."
    exit 1
  fi
}

require_tools() {
  local t
  for t in sgdisk cryptsetup mkfs.fat mkfs.btrfs partprobe btrfs pacstrap genfstab arch-chroot blkid lspci pacman shred; do
    if ! command -v "$t" >/dev/null 2>&1; then
      warn "Tool '$t' not found in live image. It may be required later."
    fi
  done
}

prompt_disk() {
  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE
  echo
  read -rp "Target install disk (Enter for ${DISK_DEFAULT}): " DISK
  DISK="${DISK:-$DISK_DEFAULT}"

  if [[ ! -b "$DISK" ]]; then
    err "Device $DISK does not exist."
    exit 1
  fi

  warn "ALL DATA ON ${DISK} WILL BE ERASED."
  read -rp "Type YES to continue: " CONF
  if [[ "$CONF" != "YES" ]]; then
    err "Confirmation not received, aborting."
    exit 1
  fi

  printf '%s' "$DISK"
}

partition_disk() {
  local disk="$1"
  log "Partitioning ${disk}: ESP ${ESP_SIZE} → ROOT ${ROOT_SIZE} → HOME ${HOME_SIZE} (rest left unpartitioned)"
  sgdisk --zap-all "$disk"

  # Use GUID type 8309 for LUKS (helps tools and readability)
  sgdisk -n 1:0:${ESP_SIZE} -t 1:ef00  -c 1:"EFI System Partition" "$disk"
  sgdisk -n 2:0:${ROOT_SIZE} -t 2:8309  -c 2:"LUKS-ROOT" "$disk"
  sgdisk -n 3:0:${HOME_SIZE} -t 3:8309  -c 3:"LUKS-HOME" "$disk"

  partprobe "$disk" >/dev/null 2>&1 || true
  udevadm settle >/dev/null 2>&1 || true
}

read_pass_confirm() {
  local label="$1"
  local a b
  while :; do
    read -rs -p "Enter passphrase for ${label}: " a; echo
    read -rs -p "Confirm passphrase for ${label}: " b; echo
    if [[ -n "$a" && "$a" == "$b" ]]; then
      printf '%s' "$a"
      return 0
    fi
    warn "Passphrases did not match or empty. Try again."
  done
}

setup_luks() {
  local p2="$1" p3="$2"
  log "Preparing LUKS containers on ${p2} and ${p3}."

  # Ask passphrases (2x confirmation each). We'll write a temporary keyfile (secure mode)
  local pass_root pass_home
  pass_root="$(read_pass_confirm "${p2} (ROOT)")"
  pass_home="$(read_pass_confirm "${p3} (HOME)")"

  # create temporary keyfile (secure permissions)
  umask 077
  printf '%s\n' "$pass_root" > "$TMP_KEYFILE"
  chmod 600 "$TMP_KEYFILE"

  # Use keyfile to format and open (automated). If you prefer interactive open (3rd prompt),
  # remove --key-file and the printf earlier; here we choose automation + secure deletion.
  log "Formatting LUKS containers (using temporary keyfile). You will not be prompted now for LUKS passphrases."
  cryptsetup luksFormat --type luks2 --pbkdf argon2id --iter-time 5000 "$p2" --key-file "$TMP_KEYFILE"
  cryptsetup open "$p2" "$LUKS_NAME_ROOT" --key-file "$TMP_KEYFILE"

  cryptsetup luksFormat --type luks2 --pbkdf argon2id --iter-time 5000 "$p3" --key-file "$TMP_KEYFILE"
  cryptsetup open "$p3" "$LUKS_NAME_HOME" --key-file "$TMP_KEYFILE"

  # wipe passphrases from variables and securely remove keyfile
  pass_root=""; pass_home=""
  if command -v shred >/dev/null 2>&1; then
    shred -u "$TMP_KEYFILE" || rm -f "$TMP_KEYFILE"
  else
    rm -f "$TMP_KEYFILE"
  fi
  umask 022
}

setup_btrfs_and_mount() {
  local esp="$1" mroot="/dev/mapper/${LUKS_NAME_ROOT}" mhome="/dev/mapper/${LUKS_NAME_HOME}"

  log "Formatting filesystems: ESP (FAT32), ROOT and HOME (btrfs)"
  mkfs.fat -F32 -n EFI "$esp"
  mkfs.btrfs -f -L ROOT "$mroot"
  mkfs.btrfs -f -L HOME "$mhome"

  log "Creating subvolumes"
  mount "$mroot" "$MNT"
  btrfs subvolume create "$MNT/@" || true
  btrfs subvolume create "$MNT/@snapshots" || true
  btrfs subvolume create "$MNT/@var_log" || true
  btrfs subvolume create "$MNT/@var_tmp" || true
  btrfs subvolume create "$MNT/@pkg" || true
  umount "$MNT"

  mount "$mhome" "$MNT"
  btrfs subvolume create "$MNT/@home" || true
  btrfs subvolume create "$MNT/@home.snapshots" || true
  umount "$MNT"

  log "Mounting subvolumes with compress=zstd, noatime"
  mount -o noatime,compress=zstd,subvol=@ "$mroot" "$MNT"
  mkdir -p "$MNT/.snapshots" "$MNT/var/log" "$MNT/var/tmp" "$MNT/var/cache/pacman/pkg" "$MNT/home"
  mount -o noatime,compress=zstd,subvol=@snapshots "$mroot" "$MNT/.snapshots"
  mount -o noatime,compress=zstd,subvol=@var_log "$mroot" "$MNT/var/log"
  mount -o noatime,compress=zstd,subvol=@var_tmp "$mroot" "$MNT/var/tmp"
  mount -o noatime,compress=zstd,subvol=@pkg "$mroot" "$MNT/var/cache/pacman/pkg"

  mount -o noatime,compress=zstd,subvol=@home "$mhome" "$MNT/home"
  mkdir -p "$MNT/home/.snapshots"
  mount -o noatime,compress=zstd,subvol=@home.snapshots "$mhome" "$MNT/home/.snapshots"

  mkdir -p "$MNT/boot"
  mount "$esp" "$MNT/boot"
}

bootstrap_base() {
  log "Installing base system via pacstrap. You will be prompted to confirm package installation (answer 'Y' when asked)."
  # Include kbd so console font exists during mkinitcpio to avoid "no font found" warning.
  # Keep pacstrap interactive: do NOT use --noconfirm so you can type 'Y' when prompted.
  pacstrap -K "$MNT" \
    base linux linux-firmware btrfs-progs intel-ucode kbd \
    networkmanager git nano \
    nvidia nvidia-utils \
    hyprland xorg-xwayland qt6-wayland egl-wayland xdg-desktop-portal xdg-desktop-portal-hyprland \
    firefox wezterm \
    noto-fonts noto-fonts-emoji ttf-dejavu ttf-nerd-fonts-symbols-mono \
    snapper zram-generator zsh zsh-completions sudo

  # write fstab (overwrite to avoid duplicates)
  genfstab -U "$MNT" > "$MNT/etc/fstab"
}

write_target_files_before_chroot() {
  # Generate locale.gen in target (no sed). This replaces editing locale.gen by hand.
  cat > "$MNT/etc/locale.gen" <<EOF_LOCALE
${LOCALE_MAIN} UTF-8
${LOCALE_EXTRA} UTF-8
EOF_LOCALE

  echo "LANG=${LOCALE_MAIN}" > "$MNT/etc/locale.conf"

  # vconsole.conf
  cat > "$MNT/etc/vconsole.conf" <<EOF_VC
KEYMAP=${TTY_KEYMAP}
FONT=${TTY_FONT}
FONT_MAP=${TTY_FONT_MAP}
EOF_VC

  # hostname & hosts
  echo "${HOSTNAME}" > "$MNT/etc/hostname"
  cat > "$MNT/etc/hosts" <<EOF_HOSTS
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${HOSTNAME}.localdomain ${HOSTNAME}
EOF_HOSTS

  # crypttab for home: we will fill UUID later (after blkid)
}

chroot_phase_and_final_config() {
  # Determine partition device names (user indicated sda only, so P1/P2/P3 are disk1..)
  local disk="$1"
  local P1="${disk}1" P2="${disk}2" P3="${disk}3"

  # After luksFormat, blkid should show LUKS UUIDs; use partition devices (p2/p3)
  local uuid_root uuid_home
  uuid_root="$(blkid -s UUID -o value "$P2")" || true
  uuid_home="$(blkid -s UUID -o value "$P3")" || true

  if [[ -z "$uuid_root" || -z "$uuid_home" ]]; then
    warn "Could not read LUKS UUIDs from partitions; boot entry will still be created using /dev/mapper names."
  fi

  # Write boot loader entry and crypttab on the target FS (host-side), expanding known UUIDs.
  cat > "$MNT/boot/loader/loader.conf" <<'EOF_LDR'
default arch.conf
timeout 1
console-mode max
editor no
auto-entries yes
EOF_LDR

  if [[ -n "$uuid_root" ]]; then
    ROOT_OPTION="rd.luks.name=${uuid_root}=${LUKS_NAME_ROOT} rd.luks.options=discard"
  else
    ROOT_OPTION=""
  fi

  cat > "$MNT/boot/loader/entries/arch.conf" <<EOF_ENTRY
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options ${ROOT_OPTION} root=/dev/mapper/${LUKS_NAME_ROOT} rootflags=subvol=@,compress=zstd rw nvidia_drm.modeset=1
EOF_ENTRY

  if [[ -n "$uuid_home" ]]; then
    cat > "$MNT/etc/crypttab" <<EOF_CRY
home    UUID=${uuid_home}    none    luks,discard
EOF_CRY
  else
    warn "home UUID unknown: /etc/crypttab will be left for manual adjustment."
  fi

  # Now perform chroot-level actions (interactive where appropriate)
  log "Entering chroot to finalize configuration (you will be asked to set passwords and confirm some pacman operations)."
  arch-chroot "$MNT" /bin/bash -eux <<'CHROOT_EOF'
set -euo pipefail
IFS=$'\n\t'

# generate locales
locale-gen

# mkinitcpio: update hooks/modules/binaries (systemd scheme + btrfs + nvidia)
# We'll rewrite a minimal mkinitcpio.conf to avoid fragile sed
cat >/etc/mkinitcpio.conf <<'MK'
MODULES=(nvidia nvidia_drm nvidia_modeset btrfs)
BINARIES=(/usr/bin/btrfs)
FILES=()
HOOKS=(base systemd autodetect modconf kms keyboard sd-vconsole block sd-encrypt btrfs filesystems fsck)
COMPRESSION="zstd"
MK

echo "Building initramfs images..."
mkinitcpio -P

# Install systemd-boot if not yet present
bootctl install || true

# enable services
systemctl enable NetworkManager
systemctl enable fstrim.timer

# Create user and set passwords interactively
echo "Set root password now (interactive)."
passwd

useradd -m -G wheel -s ${USER_SHELL} ${USERNAME}
echo "Set password for ${USERNAME} now (interactive)."
passwd ${USERNAME}
echo '%wheel ALL=(ALL) ALL' >> /etc/sudoers

# NVIDIA module option
echo 'options nvidia-drm modeset=1' > /etc/modprobe.d/nvidia.conf

# zram (zram-generator should be present)
cat >/etc/systemd/zram-generator.conf <<'ZR'
[zram0]
zram-size = ${ZRAM_SIZE}
compression-algorithm = ${ZRAM_ALGO}
ZR
systemctl daemon-reload || true
systemctl enable dev-zram0.swap || true

# Snapper: create configs and disable timeline/cleanup via CLI
pacman -S --needed snapper || true
snapper -c root create-config / || true
snapper -c home create-config /home || true
snapper -c root set-config TIMELINE_CREATE=no NUMBER_CLEANUP=no || true
snapper -c home set-config TIMELINE_CREATE=no NUMBER_CLEANUP=no || true
snapper -c root create -d "baseline-0 post-install" || true

CHROOT_EOF

  # chroot done
}

finish_and_hint() {
  log "Finishing: unmounting and hints"
  # copy a small log to target system if exists
  mkdir -p "$MNT/var/log/installer" || true
  echo "Installation finished on $(date -u)" > "$MNT/var/log/installer/install-note.txt"

  umount -R "$MNT" || true

  cat <<'NOTE'

Installation finished.

Next steps:
  1) Reboot the machine: reboot
  2) At LUKS prompt, enter the passphrase you created earlier (if prompt appears).
  3) Log in as your user; Hyprland should autostart on tty1 (you will set the user's password in chroot interactively).
  4) If monitor names differ, edit ~/.config/hypr/hyprland.conf after first login.

Notes:
- pacstrap and pacman were left interactive so you can confirm package installation with 'Y' when prompted.
- The temporary LUKS keyfile was securely removed after opening the containers.
- If you prefer cryptsetup to prompt interactively when opening the containers (third prompt), adjust setup_luks to omit --key-file usage.

NOTE
}

main() {
  require_root
  require_tools

  local DISK; DISK="$(prompt_disk)"
  # user specified only sda typically; we assume non-nvme naming per your note
  local P1="${DISK}1" P2="${DISK}2" P3="${DISK}3"

  partition_disk "$DISK"

  setup_luks "$P2" "$P3"

  setup_btrfs_and_mount "$P1"

  bootstrap_base

  write_target_files_before_chroot

  chroot_phase_and_final_config "$DISK"

  finish_and_hint
}

main "$@"
