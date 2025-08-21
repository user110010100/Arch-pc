#!/usr/bin/env bash
set -Eeuo pipefail

# === Arch Installer (LUKS+btrfs+NVIDIA+Hyprland) ===
# Схема: sda1: EFI 1G, sda2: LUKS-root 120G, sda3: LUKS-home 250G, хвост пустой
# Авторские параметры: user=user404, host=arch-pc, ZRAM=16G, timeout=1

# --- sanity ---
[[ $EUID -eq 0 ]] || { echo "Запустите от root (sudo -i)"; exit 1; }
[[ -d /sys/firmware/efi ]] || { echo "Нужен UEFI-режим (нет /sys/firmware/efi)"; exit 1; }

echo "=== Этот скрипт ПОЛНОСТЬЮ ОЧИСТИТ /dev/sda ==="
lsblk -dpno NAME,SIZE,MODEL | sed 's/^/  /'
read -r -p "Подтвердите, что ТОЛЬКО /dev/sda подключён как диск для установки. Продолжить? [yes/NO] " ans
[[ "${ans:-NO}" == "yes" ]] || exit 1

# --- constants / defaults ---
DISK="/dev/sda"
EFI_SIZE="1GiB"
ROOT_SIZE="120GiB"
HOME_SIZE="250GiB"
HOSTNAME="arch-pc"
USERNAME="user404"
TZ="Europe/Amsterdam"

echo "Размечаю: EFI=${EFI_SIZE}, root=${ROOT_SIZE}, home=${HOME_SIZE} на ${DISK}"

# --- wipe & partition ---
sgdisk --zap-all "$DISK"
sgdisk -n1:0:+${EFI_SIZE}   -t1:ef00 -c1:"EFI System" "$DISK"
sgdisk -n2:0:+${ROOT_SIZE}  -t2:8300 -c2:"Linux LUKS root" "$DISK"
sgdisk -n3:0:+${HOME_SIZE}  -t3:8300 -c3:"Linux LUKS home" "$DISK"
partprobe "$DISK"; sleep 2

EFI="${DISK}1"; ROOT="${DISK}2"; HOME="${DISK}3"

# --- filesystems & LUKS ---
mkfs.fat -F32 -n EFI "$EFI"

echo "Создаю LUKS на ${ROOT} (root). Введите пароль:"
cryptsetup luksFormat --type luks2 --pbkdf argon2id --iter-time 5000 "$ROOT"
cryptsetup open "$ROOT" root

echo "Создаю LUKS на ${HOME} (home). Введите пароль:"
cryptsetup luksFormat --type luks2 --pbkdf argon2id --iter-time 5000 "$HOME"
cryptsetup open "$HOME" home

mkfs.btrfs -L ROOT /dev/mapper/root
mkfs.btrfs -L HOME /dev/mapper/home

# --- subvolumes ---
mount /dev/mapper/root /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@.snapshots
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@var_tmp
btrfs subvolume create /mnt/@pkg
umount /mnt

mount /dev/mapper/home /mnt
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@home.snap
umount /mnt

# --- mounts ---
mount -o noatime,compress=zstd:3,subvol=@ /dev/mapper/root /mnt
mkdir -p /mnt/{boot,home,.snapshots,var/log,var/tmp,var/cache/pacman/pkg}
mount -o noatime,compress=zstd:3,subvol=@.snapshots   /dev/mapper/root /mnt/.snapshots
mount -o noatime,compress=zstd:3,subvol=@var_log      /dev/mapper/root /mnt/var/log
mount -o noatime,compress=zstd:3,subvol=@var_tmp      /dev/mapper/root /mnt/var/tmp
mount -o noatime,compress=zstd:3,subvol=@pkg          /dev/mapper/root /mnt/var/cache/pacman/pkg

mount -o noatime,compress=zstd:3,subvol=@home         /dev/mapper/home /mnt/home
mkdir -p /mnt/home/.snapshots
mount -o noatime,compress=zstd:3,subvol=@home.snap    /dev/mapper/home /mnt/home/.snapshots

mount "$EFI" /mnt/boot

# --- base system (+drivers, hyprland, portals) ---
pacstrap -K /mnt \
  base linux linux-firmware mkinitcpio btrfs-progs networkmanager sudo \
  intel-ucode \
  nvidia nvidia-utils \
  hyprland xorg-xwayland qt6-wayland egl-wayland \
  xdg-desktop-portal xdg-desktop-portal-hyprland \
  zram-generator zsh git nano firefox wezterm \
  noto-fonts noto-fonts-emoji ttf-dejavu ttf-nerd-fonts-symbols-mono

genfstab -U /mnt >> /mnt/etc/fstab

# --- chroot configure ---
arch-chroot /mnt /bin/bash -e <<CHROOT
set -Eeuo pipefail

# Locale / Time
sed -i 's/^#\(en_US.UTF-8\)/\1/' /etc/locale.gen
sed -i 's/^#\(ru_RU.UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf
ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime
hwclock --systohc

# Console (кириллица в TTY)
cat > /etc/vconsole.conf <<'EOFV'
KEYMAP=us
FONT=cyr-sun16
FONT_MAP=8859-5
EOFV

# Hostname
echo '${HOSTNAME}' > /etc/hostname
# /etc/hosts НЕ трогаем (минимализм)

# mkinitcpio: systemd-схема + nvidia + tpm + btrfs
sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_modeset nvidia_drm tpm tpm_tis btrfs)/' /etc/mkinitcpio.conf
sed -i 's/^BINARIES=.*/BINARIES=(\\/usr\\/bin\\/btrfs)/' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect modconf kms keyboard sd-vconsole block sd-encrypt btrfs filesystems fsck)/' /etc/mkinitcpio.conf

# nvidia KMS
mkdir -p /etc/modprobe.d
echo "options nvidia-drm modeset=1" > /etc/modprobe.d/nvidia.conf

mkinitcpio -P

# systemd-boot
bootctl --path=/boot install
ROOT_UUID="$(blkid -s UUID -o value ${ROOT})"

# loader.conf
cat > /boot/loader/loader.conf <<EOFL
default arch.conf
timeout 1
console-mode max
editor no
auto-entries yes
EOFL

# arch.conf (rd.luks.name + rd.luks.options=discard + root=/dev/mapper/root)
cat > /boot/loader/entries/arch.conf <<EOFA
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options rd.luks.name=${ROOT_UUID}=root rd.luks.options=discard root=/dev/mapper/root rootflags=subvol=@,compress=zstd rw nvidia_drm.modeset=1
EOFA

# crypttab: только HOME тут (root открывается из initramfs); TRIM сквозь LUKS для home
HOME_UUID="$(blkid -s UUID -o value ${HOME})"
echo "home UUID=${HOME_UUID} none luks,discard" > /etc/crypttab

# Services
systemctl enable NetworkManager
systemctl enable fstrim.timer

# ZRAM = 16G
cat > /etc/systemd/zram-generator.conf <<EOFZ
[zram0]
zram-size = 16G
compression-algorithm = zstd
EOFZ

# Пользователь и пароли
useradd -m -G wheel -s /usr/bin/zsh ${USERNAME}
echo "Задайте пароль для пользователя ${USERNAME}:"
passwd ${USERNAME}
echo "Задайте пароль root:"
passwd

# sudo для wheel
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# WezTerm конфиг (кириллица + нерд-символы)
install -d -m 0700 /home/${USERNAME}/.config/wezterm
cat > /home/${USERNAME}/.config/wezterm/wezterm.lua <<'EOFW'
local wezterm = require 'wezterm'
return {
  enable_wayland = true,
  font = wezterm.font_with_fallback({
    "DejaVu Sans Mono",
    "Symbols Nerd Font Mono",
  }),
  font_size = 11.0,
}
EOFW
chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.config/wezterm

# Hyprland конфиг (мониторы, раскладки, автозапуск firefox/wezterm)
install -d -m 0700 /home/${USERNAME}/.config/hypr
cat > /home/${USERNAME}/.config/hypr/hyprland.conf <<'EOFH'
# Мониторы
monitor = DP-1, 1920x1080@60, 0x0, 1
monitor = HDMI-A-1, 1920x1080@60, 1920x0, 1

# Рабочие пространства по мониторам
workspace = 1, monitor:DP-1
workspace = 2, monitor:HDMI-A-1

# Клавиатура: ru/us, Caps = переключение
input {
  kb_layout = us,ru
  kb_options = grp:caps_toggle,terminate:ctrl_alt_bksp
}

# Автозапуск приложений (минимум)
exec-once = firefox
exec-once = wezterm
EOFH
chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.config/hypr

# Автостарт Hyprland после логина в TTY1 (без автологина)
# Пользователь входит в tty1 -> сразу стартует Hyprland
cat >> /home/${USERNAME}/.zprofile <<'EOFZP'

# Автостарт Hyprland на TTY1
if [[ -z "$DISPLAY" && "$(tty)" == "/dev/tty1" ]]; then
  exec Hyprland
fi
EOFZP
chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.zprofile
chmod 0644 /home/${USERNAME}/.zprofile

# Snapper: root + home, только ручные снапшоты
snapper --no-dbus -c root create-config /
sed -i 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="no"/' /etc/snapper/configs/root
sed -i 's/^NUMBER_CLEANUP=.*/NUMBER_CLEANUP="no"/'     /etc/snapper/configs/root
snapper -c root create -d "baseline-0 (post-install)" -t single

snapper --no-dbus -c home create-config /home
sed -i 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="no"/' /etc/snapper/configs/home
sed -i 's/^NUMBER_CLEANUP=.*/NUMBER_CLEANUP="no"/'   /etc/snapper/configs/home

CHROOT

echo "Готово. Отмонтирую и перезагружаю."
umount -R /mnt || true
swapoff -a || true
sleep 2
reboot

