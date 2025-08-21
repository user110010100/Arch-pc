#!/usr/bin/env bash
# Minimal Arch install for one PC (your layout). ASCII messages only.

set -euo pipefail

# --- CONSTANTS (edit if you really need) ---
DISK="/dev/sda"
HOSTNAME="arch-pc"
USER_NAME="user404"
TZONE="Europe/Amsterdam"
LANGV="en_US.UTF-8"
EFI_SIZE="+1G"
ROOT_SIZE="+120G"
HOME_SIZE="+250G"
# -------------------------------------------

# require bash
if [[ -z "${BASH_VERSINFO:-}" ]]; then
  echo "[X] Run with: bash $0"; exit 1
fi

# check UEFI
[[ -d /sys/firmware/efi/efivars ]] || { echo "[X] UEFI not detected"; exit 1; }

echo "This will WIPE $DISK. Ctrl+C to abort. Continuing in 5s..."; sleep 5

# ask passwords
read -rsp "Root password: " ROOT_PW; echo
read -rsp "Password for ${USER_NAME}: " USER_PW; echo

# derive partition names
case "$DISK" in *nvme*) P1="${DISK}p1"; P2="${DISK}p2"; P3="${DISK}p3" ;; *) P1="${DISK}1"; P2="${DISK}2"; P3="${DISK}3" ;; esac

echo "==> wipe + partition"
sgdisk --zap-all "$DISK" || true
sgdisk -n1:0:${EFI_SIZE}  -t1:ef00 -c1:EFI        "$DISK"
sgdisk -n2:0:${ROOT_SIZE} -t2:8309 -c2:LUKS-ROOT  "$DISK"   # 8309 = Linux LUKS
sgdisk -n3:0:${HOME_SIZE} -t3:8309 -c3:LUKS-HOME  "$DISK"
partprobe "$DISK" >/dev/null 2>&1 || true; udevadm settle || true

echo "==> format/open"
mkfs.fat -F32 -n EFI "$P1"
echo "LUKS ROOT:"
cryptsetup luksFormat --type luks2 --pbkdf argon2id --iter-time 5000 "$P2"
cryptsetup open "$P2" root
echo "LUKS HOME:"
cryptsetup luksFormat --type luks2 --pbkdf argon2id --iter-time 5000 "$P3"
cryptsetup open "$P3" home

echo "==> mkfs.btrfs + subvolumes"
mkfs.btrfs -L ROOT /dev/mapper/root
mkfs.btrfs -L HOME /dev/mapper/home

mount /dev/mapper/root /mnt
btrfs subvolume create /mnt/@
umount /mnt

mount /dev/mapper/home /mnt
btrfs subvolume create /mnt/@home
umount /mnt

echo "==> mount"
mount -o compress=zstd,subvol=@ /dev/mapper/root /mnt
mkdir -p /mnt/home /mnt/boot
mount -o compress=zstd,subvol=@home /dev/mapper/home /mnt/home
mount "$P1" /mnt/boot

echo "==> pacstrap"
# use 'yes' to avoid prompts; keep your original base set
yes | pacstrap /mnt \
  base base-devel linux linux-headers linux-firmware btrfs-progs intel-ucode \
  git nano networkmanager

genfstab -U /mnt >> /mnt/etc/fstab

ROOT_UUID="$(blkid -s UUID -o value "$P2")"
HOME_UUID="$(blkid -s UUID -o value "$P3")"

echo "==> configure in chroot"
arch-chroot /mnt /bin/bash -eux <<EOF
set -euo pipefail

# locales & console
sed -i -e 's/^#en_US.UTF-8/en_US.UTF-8/' -e 's/^#ru_RU.UTF-8/ru_RU.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=${LANGV}" > /etc/locale.conf
cat >/etc/vconsole.conf <<EOVC
KEYMAP=us
FONT=cyr-sun16
FONT_MAP=8859-5
EOVC

# time & hostname & hosts
ln -sf /usr/share/zoneinfo/${TZONE} /etc/localtime
hwclock --systohc
echo "${HOSTNAME}" > /etc/hostname
cat >/etc/hosts <<EOH
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${HOSTNAME}.localdomain ${HOSTNAME}
EOH

# NVIDIA (from your doc)
pacman -S --noconfirm nvidia nvidia-utils nvidia-settings
echo "options nvidia-drm modeset=1" >/etc/modprobe.d/nvidia.conf

# mkinitcpio (systemd scheme + btrfs + nvidia + sd-encrypt), per your doc
sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_drm nvidia_modeset tpm tpm_tis btrfs)/' /etc/mkinitcpio.conf
sed -i 's|^BINARIES=.*|BINARIES=(/usr/bin/btrfs)|' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect modconf kms keyboard sd-vconsole block sd-encrypt btrfs filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# systemd-boot
bootctl install
cat >/boot/loader/loader.conf <<EOL
default arch.conf
timeout 1
console-mode max
editor no
auto-entries yes
EOL
cat >/boot/loader/entries/arch.conf <<EOL
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options rd.luks.name=${ROOT_UUID}=root rd.luks.options=discard root=/dev/mapper/root rootflags=subvol=@,compress=zstd rw nvidia-drm.modeset=1
EOL

# crypttab for HOME (trim via luks)
echo "home UUID=${HOME_UUID} none luks,discard" >/etc/crypttab

# network & user shell
systemctl enable NetworkManager
pacman -S --noconfirm zsh zsh-completions sudo
useradd -m -G wheel -s /usr/bin/zsh ${USER_NAME}
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers
EOF

echo "==> set passwords"
arch-chroot /mnt /bin/bash -c "echo 'root:${ROOT_PW}' | chpasswd"
arch-chroot /mnt /bin/bash -c "echo '${USER_NAME}:${USER_PW}' | chpasswd"

echo "==> done. umount + hint"
echo "Run:  umount -R /mnt ; reboot"
