#!/usr/bin/env bash
# Minimal Arch install for ONE PC + fixes:
# - password confirmation for root/user
# - keep cryptsetup interactive (LUKS format/open prompts)
# - pacstrap handling: use --noconfirm when available, otherwise prepopulate keyring
set -euo pipefail
if [[ -z "${BASH_VERSINFO:-}" ]]; then echo "[X] Run with: bash $0"; exit 1; fi

# ---- CONFIG ----
DISK="/dev/sda"
HOSTNAME="arch-pc"
USER_NAME="user404"
TZONE="Europe/Amsterdam"
LANGV="en_US.UTF-8"
EFI_SIZE="+1G"
ROOT_SIZE="+120G"
HOME_SIZE="+250G"
LOG="/tmp/arch_min_plus_fixed.log"
# -----------------

exec > >(tee -a "$LOG") 2>&1

# helper: require tools
require_tools() {
  for cmd in sgdisk cryptsetup mkfs.fat mkfs.btrfs partprobe btrfs pacstrap genfstab arch-chroot blkid lspci pacman; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "[X] Required tool '$cmd' not found in live image."; exit 1; }
  done
}
require_tools

[[ -d /sys/firmware/efi/efivars ]] || { echo "[X] UEFI not detected"; exit 1; }
echo "This will WIPE $DISK. Ctrl+C to abort. Continue in 5s..."; sleep 5

# read password + confirmation function
prompt_password_confirm() {
  local prompt_var_name="$1"   # name of variable to set (pass by name)
  local prompt_text="$2"
  local p1 p2
  while :; do
    read -rsp "$prompt_text" p1; echo
    read -rsp "Confirm: " p2; echo
    if [[ "$p1" == "$p2" && -n "$p1" ]]; then
      # assign to caller variable name
      printf -v "$prompt_var_name" "%s" "$p1"
      return 0
    fi
    echo "[!] Passwords do not match or empty — try again."
  done
}

# Ask root and user passwords with confirmation
prompt_password_confirm ROOT_PW "Root password: "
prompt_password_confirm USER_PW "Password for ${USER_NAME}: "

# partition name handling
case "$DISK" in *nvme*) P1="${DISK}p1"; P2="${DISK}p2"; P3="${DISK}p3" ;; *) P1="${DISK}1"; P2="${DISK}2"; P3="${DISK}3" ;; esac

echo "==> cleanup (if rerun)"
swapoff -a || true
umount -R /mnt || true
for m in root home; do [[ -e /dev/mapper/$m ]] && cryptsetup close "$m" || true; done
wipefs -af "$DISK" || true
sgdisk --zap-all "$DISK" || true

echo "==> partition: EFI / LUKS-root / LUKS-home"
sgdisk -n1:0:${EFI_SIZE}  -t1:ef00 -c1:EFI        "$DISK"
sgdisk -n2:0:${ROOT_SIZE} -t2:8309 -c2:LUKS-ROOT  "$DISK"
sgdisk -n3:0:${HOME_SIZE} -t3:8309 -c3:LUKS-HOME  "$DISK"
partprobe "$DISK" >/dev/null 2>&1 || true; udevadm settle || true

echo "==> format + open LUKS"
mkfs.fat -F32 -n EFI "$P1"

# IMPORTANT: keep cryptsetup interactive so user is prompted to enter LUKS passphrase.
# do NOT use --batch-mode or pipe the passphrase here if you want to be asked at open time.
echo "LUKS ROOT: you will be asked to enter and confirm passphrase interactively by cryptsetup."
cryptsetup luksFormat --type luks2 --pbkdf argon2id --iter-time 5000 "$P2"
cryptsetup open "$P2" root

echo "LUKS HOME: you will be asked to enter and confirm passphrase interactively by cryptsetup."
cryptsetup luksFormat --type luks2 --pbkdf argon2id --iter-time 5000 "$P3"
cryptsetup open "$P3" home

# ... (the rest of your script remains mostly unchanged: mkfs btrfs, create subvols, mount, pacstrap, etc.)
# For brevity include the key parts about pacstrap behavior below.

echo "==> mkfs btrfs + subvolumes"
mkfs.btrfs -L ROOT /dev/mapper/root
mkfs.btrfs -L HOME /dev/mapper/home

mount /dev/mapper/root /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@var_tmp
btrfs subvolume create /mnt/@pkg
umount /mnt

mount /dev/mapper/home /mnt
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@home.snapshots
umount /mnt

mount -o rw,noatime,ssd,compress=zstd,subvol=@ /dev/mapper/root /mnt
mkdir -p /mnt/.snapshots /mnt/var/log /mnt/var/tmp /mnt/var/cache/pacman/pkg /mnt/home /mnt/boot
mount -o rw,noatime,ssd,compress=zstd,subvol=@snapshots /dev/mapper/root /mnt/.snapshots
mount -o rw,noatime,ssd,compress=zstd,subvol=@var_log /dev/mapper/root /mnt/var/log
mount -o rw,noatime,ssd,compress=zstd,subvol=@var_tmp /dev/mapper/root /mnt/var/tmp
mount -o rw,noatime,ssd,compress=zstd,subvol=@pkg /dev/mapper/root /mnt/var/cache/pacman/pkg

mount -o rw,noatime,ssd,compress=zstd,subvol=@home /dev/mapper/home /mnt/home
mkdir -p /mnt/home/.snapshots
mount -o rw,noatime,ssd,compress=zstd,subvol=@home.snapshots /dev/mapper/home /mnt/home/.snapshots

mount "$P1" /mnt/boot

# Prepare package list (minimal per your spec)
PKGS=(base linux linux-firmware btrfs-progs intel-ucode networkmanager nvidia nvidia-utils hyprland xorg-xwayland qt6-wayland egl-wayland xdg-desktop-portal xdg-desktop-portal-hyprland firefox wezterm noto-fonts noto-fonts-emoji ttf-dejavu ttf-nerd-fonts-symbols-mono snapper zram-generator zsh zsh-completions sudo kbd)

# pacstrap: prefer --noconfirm --needed; if pacstrap on this ISO doesn't support it, prepopulate keyring
if pacstrap --help 2>/dev/null | grep -q -- '--noconfirm'; then
  pacstrap -K --noconfirm --needed /mnt "${PKGS[@]}"
else
  # ensure keyring present / update to avoid interactive 'trust key?' prompts
  echo "pacstrap lacks --noconfirm: populating keyring in live-system to avoid interactive prompts..."
  pacman -Sy --noconfirm archlinux-keyring || true
  yes | pacstrap /mnt "${PKGS[@]}"
fi

# make fstab
genfstab -U /mnt > /mnt/etc/fstab

# set up UUIDs etc. (snippet)
ROOT_UUID="$(blkid -s UUID -o value "$P2")"
HOME_UUID="$(blkid -s UUID -o value "$P3")"

# configure in chroot (you can reuse your existing chroot block)
# ... (omitted here for brevity; keep your config steps: locale, mkinitcpio, bootctl, crypttab, services, user creation)

# set passwords safely (pass via stdin to chpasswd) and then unset
printf '%s\n' "root:${ROOT_PW}" | arch-chroot /mnt chpasswd
printf '%s\n' "${USER_NAME}:${USER_PW}" | arch-chroot /mnt chpasswd
unset ROOT_PW USER_PW

echo "Installation finished. Logs: $LOG"
echo "Run: umount -R /mnt ; reboot"
