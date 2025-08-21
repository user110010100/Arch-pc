#!/usr/bin/env bash
# Arch minimal install with LUKS (root/home), Btrfs subvolumes, systemd-boot,
# NVIDIA KMS, Hyprland (no DM), zram, fstrim.timer, Snapper manual, baseline snapshot.
# Idempotent: fully wipes target disk on each run. ASCII-only messages.

set -Eeuo pipefail

# Try to make TTY readable on Arch ISO (optional)
(setfont ter-v16n >/dev/null 2>&1) || true

### ======== USER VARS (you can edit) ========
DISK_DEFAULT="/dev/sda"          # e.g. /dev/nvme0n1
HOSTNAME_DEFAULT="arch-pc"
USERNAME_DEFAULT="user404"
TZ_DEFAULT="Europe/Amsterdam"
LANG_DEFAULT="en_US.UTF-8"

# Partition sizes: 1G (EFI) + 120G (LUKS-root) + 250G (LUKS-home) + the rest unallocated
EFI_SIZE="+1G"
ROOT_SIZE="+120G"
HOME_SIZE="+250G"

# Btrfs subvolumes
ROOT_SUBVOLS=(@ @snapshots @var_log @var_tmp @pkg)
HOME_SUBVOLS=(@home @home.snapshots)

# Hyprland monitors (adjust later via hyprctl if names differ)
HYPR_MON1="DP-1, 1920x1080@60, 0x0, 1"
HYPR_MON2="HDMI-A-1, 1920x1080@60, 1920x0, 1"
### =========================================

ts="$(date +%F_%H%M%S)"
LOG="/tmp/arch_install_${ts}.log"
exec > >(tee -a "$LOG") 2>&1

on_error() { echo "ERROR at line $1. See log: $LOG"; }
trap 'on_error $LINENO' ERR

cecho() { echo -e "\n==> $*\n"; }
wecho() { echo -e "[!] $*"; }
fecho() { echo -e "[X] $*"; }

require_root() { [[ $EUID -eq 0 ]] || { fecho "Run as root"; exit 1; }; }

check_uefi() {
  if [[ ! -d /sys/firmware/efi/efivars ]]; then
    fecho "UEFI environment not detected. Reboot in UEFI mode."
    exit 1
  fi
}

prompt_nonempty_secret() {
  # $1=prompt; prints to stdout the non-empty secret
  local s
  while :; do
    read -rsp "$1" s; echo
    [[ -n "$s" ]] && { printf "%s" "$s"; return 0; }
    wecho "Password cannot be empty. Please try again."
  done
}

prompt_vars() {
  read -rp "Target disk [${DISK_DEFAULT}]: " DISK || true
  DISK="${DISK:-$DISK_DEFAULT}"
  read -rp "Hostname [${HOSTNAME_DEFAULT}]: " HOSTNAME || true
  HOSTNAME="${HOSTNAME:-$HOSTNAME_DEFAULT}"
  read -rp "Username [${USERNAME_DEFAULT}]: " USERNAME || true
  USERNAME="${USERNAME:-$USERNAME_DEFAULT}"

  USER_PW="$(prompt_nonempty_secret "Password for user ${USERNAME}: ")"
  ROOT_PW="$(prompt_nonempty_secret "Password for root: ")"

  wecho "You will be asked for LUKS passphrases for root/home containers during format."
  echo
}

ensure_net() {
  cecho "Checking network..."
  ping -c1 archlinux.org >/dev/null 2>&1 || {
    fecho "No network. Plug in or configure networking and re-run."
    exit 1
  }
}

cleanup_previous() {
  cecho "Cleaning any previous attempt..."
  pkill -9 pacman >/dev/null 2>&1 || true
  pkill -9 arch-chroot >/dev/null 2>&1 || true

  swapoff -a || true
  umount -R /mnt || true

  for map in root home; do
    [[ -e "/dev/mapper/$map" ]] && cryptsetup close "$map" || true
  done

  (dmsetup remove -f /dev/mapper/root >/dev/null 2>&1) || true
  (dmsetup remove -f /dev/mapper/home >/dev/null 2>&1) || true

  if lsblk -ln -o NAME "${DISK}" >/dev/null 2>&1; then
    for p in $(lsblk -ln -o NAME "/dev/$(basename "$DISK")" | tail -n +2); do
      wipefs -af "/dev/$p" || true
    done
  fi
  wipefs -af "$DISK" || true
  udevadm settle || true
}

wipe_and_partition() {
  cecho "Wiping and partitioning disk $DISK (EFI / LUKS-root / LUKS-home)..."
  sgdisk --zap-all "$DISK" || true
  partprobe "$DISK" >/dev/null 2>&1 || true; udevadm settle || true

  sgdisk -n1:0:${EFI_SIZE}  -t1:ef00 -c1:"EFI"        "$DISK"
  sgdisk -n2:0:${ROOT_SIZE} -t2:8309 -c2:"LUKS-ROOT"  "$DISK"  # 8309 = Linux LUKS
  sgdisk -n3:0:${HOME_SIZE} -t3:8309 -c3:"LUKS-HOME"  "$DISK"

  partprobe "$DISK" >/dev/null 2>&1 || true; udevadm settle || true

  if [[ "$DISK" =~ nvme ]]; then
    P1="${DISK}p1"; P2="${DISK}p2"; P3="${DISK}p3"
  else
    P1="${DISK}1";  P2="${DISK}2";  P3="${DISK}3"
  fi
  export P1 P2 P3
}

format_encrypt() {
  cecho "Formatting: EFI (vfat), LUKS for root/home..."
  mkfs.fat -F32 -n EFI "$P1"

  echo
  wecho "Enter LUKS passphrase for ROOT (/dev/mapper/root):"
  cryptsetup luksFormat --batch-mode --type luks2 --pbkdf argon2id --iter-time 5000 "$P2"
  cryptsetup open "$P2" root

  wecho "Enter LUKS passphrase for HOME (/dev/mapper/home):"
  cryptsetup luksFormat --batch-mode --type luks2 --pbkdf argon2id --iter-time 5000 "$P3"
  cryptsetup open "$P3" home

  cecho "Creating Btrfs filesystems..."
  mkfs.btrfs -L ROOT /dev/mapper/root
  mkfs.btrfs -L HOME /dev/mapper/home
}

create_subvols() {
  cecho "Creating subvolumes on ROOT..."
  mount /dev/mapper/root /mnt
  for sv in "${ROOT_SUBVOLS[@]}"; do
    btrfs subvolume create "/mnt/$sv"
  done
  umount /mnt

  cecho "Creating subvolumes on HOME..."
  mount /dev/mapper/home /mnt
  for sv in "${HOME_SUBVOLS[@]}"; do
    btrfs subvolume create "/mnt/$sv"
  done
  umount /mnt
}

mount_all() {
  cecho "Mounting subvolumes..."
  # ROOT
  mount -o noatime,ssd,compress=zstd,subvol=@ /dev/mapper/root /mnt
  mkdir -p /mnt/.snapshots /mnt/var/log /mnt/var/tmp /mnt/var/cache/pacman/pkg /mnt/home
  mount -o noatime,ssd,compress=zstd,subvol=@snapshots /dev/mapper/root /mnt/.snapshots
  mount -o noatime,ssd,compress=zstd,subvol=@var_log   /dev/mapper/root /mnt/var/log
  mount -o noatime,ssd,compress=zstd,subvol=@var_tmp   /dev/mapper/root /mnt/var/tmp
  mount -o noatime,ssd,compress=zstd,subvol=@pkg       /dev/mapper/root /mnt/var/cache/pacman/pkg

  # HOME
  mount -o noatime,ssd,compress=zstd,subvol=@home /dev/mapper/home /mnt/home
  mkdir -p /mnt/home/.snapshots
  mount -o noatime,ssd,compress=zstd,subvol=@home.snapshots /dev/mapper/home /mnt/home/.snapshots

  # EFI
  mkdir -p /mnt/boot
  mount "$P1" /mnt/boot
}

pacstrap_base() {
  cecho "Installing base system and packages (non-interactive)..."
  pacstrap -K --noconfirm /mnt \
    base linux linux-firmware btrfs-progs intel-ucode networkmanager \
    nvidia nvidia-utils \
    hyprland xorg-xwayland qt6-wayland egl-wayland xdg-desktop-portal xdg-desktop-portal-hyprland \
    firefox wezterm \
    noto-fonts noto-fonts-emoji ttf-dejavu ttf-nerd-fonts-symbols-mono \
    snapper zram-generator

  genfstab -U /mnt >> /mnt/etc/fstab
}

in_chroot() { arch-chroot /mnt /usr/bin/env bash -euxo pipefail -c "$*"; }

configure_system() {
  local ROOT_UUID HOME_UUID
  ROOT_UUID="$(blkid -s UUID -o value "$P2")"
  HOME_UUID="$(blkid -s UUID -o value "$P3")"

  cecho "Configuring system..."
  # locale
  in_chroot "sed -i 's/^#\s*en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen"
  in_chroot "sed -i 's/^#\s*ru_RU.UTF-8/ru_RU.UTF-8/' /etc/locale.gen"
  in_chroot "locale-gen"
  echo "LANG=${LANG_DEFAULT}" > /mnt/etc/locale.conf

  # vconsole
  cat >/mnt/etc/vconsole.conf <<EOF
KEYMAP=us
FONT=cyr-sun16
FONT_MAP=8859-5
EOF

  # timezone & clock
  in_chroot "ln -sf /usr/share/zoneinfo/${TZ_DEFAULT} /etc/localtime"
  in_chroot "hwclock --systohc"

  # ho
