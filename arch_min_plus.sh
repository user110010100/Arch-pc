#!/usr/bin/env bash
# Improved minimal Arch installer (fits your ТЗ).
# - fixed partition sizes: +1G, +120G, +250G, rest untouched
# - two LUKS containers (root/home)
# - btrfs subvol scheme and mount options per spec
# - rd.luks.options=discard for root, crypttab luks,discard for home
# - systemd-boot, mkinitcpio systemd scheme, NVIDIA KMS support
# - minimal pacstrap set (no base-devel / linux-headers)
set -euo pipefail

# --- CONFIG (edit only if you really want) ---
DISK="/dev/sda"
HOSTNAME="arch-pc"
USER_NAME="user404"
TZONE="Europe/Amsterdam"
LANGV="en_US.UTF-8"
EFI_SIZE="+1G"
ROOT_SIZE="+120G"
HOME_SIZE="+250G"
LOG="/tmp/arch_install_$(date +%F_%H%M%S).log"
# -------------------------------------------

# prerequisites
if [[ -z "${BASH_VERSINFO:-}" ]]; then echo "[X] Run with: bash $0"; exit 1; fi
exec > >(tee -a "$LOG") 2>&1

require_tools() {
  for cmd in sgdisk cryptsetup mkfs.fat mkfs.btrfs partprobe btrfs pacstrap genfstab arch-chroot blkid lspci; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "[X] Required tool '$cmd' missing in live image."; exit 1; }
  done
}
require_tools

[[ -d /sys/firmware/efi/efivars ]] || { echo "[X] UEFI not detected. Boot in UEFI mode."; exit 1; }

echo "This will WIPE $DISK. Ctrl+C to abort. Continuing in 5s..."; sleep 5

# passwords (keep only briefly)
read -rsp "Root password: " ROOT_PW; echo
read -rsp "Password for ${USER_NAME}: " USER_PW; echo

# partition name handling
dn=$(basename "$DISK")
if [[ $dn == nvme* ]]; then
  P1="${DISK}p1"; P2="${DISK}p2"; P3="${DISK}p3"
else
  P1="${DISK}1"; P2="${DISK}2"; P3="${DISK}3"
fi

# cleanup previous runs (idempotence)
swapoff -a || true
umount -R /mnt || true
for m in root home; do
  if cryptsetup status "$m" >/dev/null 2>&1; then cryptsetup close "$m" || true; fi
done
wipefs -af "$DISK" || true
sgdisk --zap-all "$DISK" || true
partprobe "$DISK" >/dev/null 2>&1 || true; udevadm settle || true

# partitioning fixed sizes
echo "==> Partitioning $DISK..."
sgdisk -n1:0:${EFI_SIZE}  -t1:ef00 -c1:"EFI"        "$DISK"
sgdisk -n2:0:${ROOT_SIZE} -t2:8309 -c2:"LUKS-ROOT" "$DISK"
sgdisk -n3:0:${HOME_SIZE} -t3:8309 -c3:"LUKS-HOME" "$DISK"
partprobe "$DISK" >/dev/null 2>&1; udevadm settle || true

# format + open LUKS
echo "==> Formatting EFI and LUKS..."
mkfs.fat -F32 -n EFI "$P1"
echo "LUKS ROOT: enter passphrase"
cryptsetup luksFormat --batch-mode --type luks2 --pbkdf argon2id --iter-time 5000 "$P2"
cryptsetup open "$P2" root
echo "LUKS HOME: enter passphrase"
cryptsetup luksFormat --batch-mode --type luks2 --pbkdf argon2id --iter-time 5000 "$P3"
cryptsetup open "$P3" home

# make filesystems and subvols
echo "==> Creating btrfs filesystems and subvolumes..."
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

# mount scheme
echo "==> Mounting subvolumes..."
mount -o rw,noatime,ssd,compress=zstd,subvol=@ /dev/mapper/root /mnt
mkdir -p /mnt/.snapshots /mnt/var/log /mnt/var/tmp /mnt/var/cache/pacman/pkg /mnt/home /mnt/boot
mount -o rw,noatime,ssd,compress=zstd,subvol=@snapshots /dev/mapper/root /mnt/.snapshots
mount -o rw,noatime,ssd,compress=zstd,subvol=@var_log   /dev/mapper/root /mnt/var/log
mount -o rw,noatime,ssd,compress=zstd,subvol=@var_tmp   /dev/mapper/root /mnt/var/tmp
mount -o rw,noatime,ssd,compress=zstd,subvol=@pkg       /dev/mapper/root /mnt/var/cache/pacman/pkg
mount -o rw,noatime,ssd,compress=zstd,subvol=@home      /dev/mapper/home /mnt/home
mkdir -p /mnt/home/.snapshots
mount -o rw,noatime,ssd,compress=zstd,subvol=@home.snapshots /dev/mapper/home /mnt/home/.snapshots
mount "$P1" /mnt/boot

# decide conditional packages
PKGS=(base linux linux-firmware btrfs-progs networkmanager kbd zram-generator snapper hyprland xorg-xwayland qt6-wayland egl-wayland xdg-desktop-portal xdg-desktop-portal-hyprland firefox wezterm noto-fonts noto-fonts-emoji ttf-dejavu ttf-nerd-fonts-symbols-mono zsh zsh-completions sudo)
# intel-ucode if CPU vendor Intel
if grep -m1 -i "vendor_id" /proc/cpuinfo | grep -iq "GenuineIntel"; then PKGS+=(intel-ucode); fi
# nvidia: detect via lspci
if lspci | grep -i -E 'vga|3d' | grep -iq nvidia; then PKGS+=(nvidia nvidia-utils); fi

echo "==> pacstrap (installing ${#PKGS[@]} packages)..."
# Use pacstrap with --noconfirm/--needed when available
if pacstrap --help 2>&1 | grep -q -- '--noconfirm'; then
  pacstrap -K --noconfirm --needed /mnt "${PKGS[@]}"
else
  # fallback for ISOs without that pacstrap flag
  yes | pacstrap /mnt "${PKGS[@]}"
fi

genfstab -U /mnt > /mnt/etc/fstab

ROOT_UUID="$(blkid -s UUID -o value "$P2")"
HOME_UUID="$(blkid -s UUID -o value "$P3")"
if [[ -z "$ROOT_UUID" || -z "$HOME_UUID" ]]; then echo "[X] blkid failed to get LUKS UUIDs"; exit 1; fi

# chroot config: write full files (no sed hacks)
echo "==> Configuring system in chroot..."
arch-chroot /mnt /bin/bash -eux <<EOF
set -euo pipefail

# locales
cat >/etc/locale.gen <<LC
${LANGV} UTF-8
ru_RU.UTF-8 UTF-8
LC
locale-gen
echo "LANG=${LANGV}" > /etc/locale.conf

# vconsole
cat >/etc/vconsole.conf <<VC
KEYMAP=us
FONT=ter-v16n
VC

# timezone
ln -sf /usr/share/zoneinfo/${TZONE} /etc/localtime
hwclock --systohc

# hostname/hosts
echo "${HOSTNAME}" > /etc/hostname
cat >/etc/hosts <<H
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${HOSTNAME}.localdomain ${HOSTNAME}
H

# mkinitcpio (systemd scheme + btrfs + NVIDIA KMS modules)
cat >/etc/mkinitcpio.conf <<MK
MODULES=(nvidia nvidia_modeset nvidia_drm tpm tpm_tis btrfs)
BINARIES=(/usr/bin/btrfs)
FILES=()
HOOKS=(base systemd autodetect modconf kms keyboard sd-vconsole block sd-encrypt btrfs filesystems fsck)
COMPRESSION="zstd"
MK
mkinitcpio -P

# nvidia options (if package present)
if pacman -Qi nvidia >/dev/null 2>&1; then
  mkdir -p /etc/modprobe.d
  echo "options nvidia-drm modeset=1" > /etc/modprobe.d/nvidia.conf
fi

# systemd-boot
bootctl --path=/boot install || true
cat >/boot/loader/loader.conf <<LD
default arch.conf
timeout 1
console-mode max
editor no
auto-entries yes
LD

cat >/boot/loader/entries/arch.conf <<E
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options rd.luks.name=${ROOT_UUID}=root rd.luks.options=discard root=/dev/mapper/root rootflags=subvol=@,compress=zstd rw nvidia_drm.modeset=1
E

# crypttab for home (allow discard via LUKS)
echo "home UUID=${HOME_UUID} none luks,discard" > /etc/crypttab

# enable services
systemctl enable NetworkManager
systemctl enable fstrim.timer

# zram
cat >/etc/systemd/zram-generator.conf <<Z
[zram0]
zram-size = 16G
compression-algorithm = zstd
Z

# minimal user + shell + sudo
pacman -S --noconfirm --needed zsh zsh-completions sudo || true
useradd -m -G wheel -s /usr/bin/zsh ${USER_NAME}
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

EOF

# set passwords safely, then clear variables
printf '%s\n' "root:${ROOT_PW}" | arch-chroot /mnt chpasswd
printf '%s\n' "${USER_NAME}:${USER_PW}" | arch-chroot /mnt chpasswd
unset ROOT_PW USER_PW

# user environment (hyprland, wezterm, configs)
arch-chroot /mnt /bin/bash -eux <<'CH'
set -euo pipefail
U="${USER_NAME}"
install -d -m 0700 /home/$U
cat >/home/$U/.zprofile <<'ZP'
if [[ -z "$DISPLAY" && "$(tty)" == "/dev/tty1" ]]; then
  exec Hyprland
fi
ZP
chown $U:$U /home/$U/.zprofile

install -d -m 0700 /home/$U/.config/hypr
cat >/home/$U/.config/hypr/hyprland.conf <<HY
monitor = DP-1, 1920x1080@60, 0x0, 1
monitor = HDMI-A-1, 1920x1080@60, 1920x0, 1
workspace = 1, monitor:DP-1
workspace = 2, monitor:HDMI-A-1

env = XDG_CURRENT_DESKTOP,Hyprland
env = XDG_SESSION_TYPE,wayland
env = MOZ_ENABLE_WAYLAND,1
env = WLR_NO_HARDWARE_CURSORS,0

input {
  kb_layout = us,ru
  kb_options = grp:caps_toggle,terminate:ctrl_alt_bksp
}

exec-once = firefox
exec-once = wezterm
HY
chown -R $U:$U /home/$U/.config

install -d -m 0700 /home/$U/.config/wezterm
cat >/home/$U/.config/wezterm/wezterm.lua <<WZ
local wezterm = require 'wezterm'
return {
  enable_wayland = true,
  font = wezterm.font_with_fallback({
    "DejaVu Sans Mono",
    "Symbols Nerd Font Mono",
  }),
  color_scheme = "Builtin Tango Dark",
}
WZ
chown -R $U:$U /home/$U/.config/wezterm
CH

# snapper: manual + baseline
arch-chroot /mnt /bin/bash -eux <<'SN'
set -euo pipefail
snapper -c root create-config /
snapper -c home create-config /home || true
snapper -c root set-config TIMELINE_CREATE=no NUMBER_CLEANUP=no
snapper -c home set-config TIMELINE_CREATE=no NUMBER_CLEANUP=no || true
mount -a || true
snapper -c root create -d "baseline-0 post-install" || true
SN

# copy log into target
mkdir -p /mnt/var/log/installer
cp -a "$LOG" /mnt/var/log/installer/

echo "==> Installation finished. Unmounting..."
umount -R /mnt || true

echo "Done. Reboot now? (y/N)"
read -r REBOOTANS && [[ "$REBOOTANS" =~ ^[Yy]$ ]] && reboot
