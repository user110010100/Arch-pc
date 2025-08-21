#!/usr/bin/env bash
# Minimal Arch install for ONE PC + your "minimum" TZ items.
# ASCII-only messages. No sed edits of system files (write full files instead).
set -euo pipefail
if [[ -z "${BASH_VERSINFO:-}" ]]; then echo "[X] Run with: bash $0"; exit 1; fi

# ---- CONSTANTS (change only if нужно) ----
DISK="/dev/sda"
HOSTNAME="arch-pc"
USER_NAME="user404"
TZONE="Europe/Amsterdam"
LANGV="en_US.UTF-8"

EFI_SIZE="+1G"
ROOT_SIZE="+120G"
HOME_SIZE="+250G"
# ------------------------------------------

[[ -d /sys/firmware/efi/efivars ]] || { echo "[X] UEFI not detected"; exit 1; }
echo "This will WIPE $DISK. Ctrl+C to abort. Continue in 5s..."; sleep 5

read -rsp "Root password: " ROOT_PW; echo
read -rsp "Password for ${USER_NAME}: " USER_PW; echo

case "$DISK" in *nvme*) P1="${DISK}p1"; P2="${DISK}p2"; P3="${DISK}p3" ;; *) P1="${DISK}1"; P2="${DISK}2"; P3="${DISK}3" ;; esac

echo "==> cleanup (if rerun)"
swapoff -a || true
umount -R /mnt || true
for m in root home; do [[ -e /dev/mapper/$m ]] && cryptsetup close "$m" || true; done
wipefs -af "$DISK" || true
sgdisk --zap-all "$DISK" || true

echo "==> partition: EFI / LUKS-root / LUKS-home"
sgdisk -n1:0:${EFI_SIZE}  -t1:ef00 -c1:EFI        "$DISK"
sgdisk -n2:0:${ROOT_SIZE} -t2:8309 -c2:LUKS-ROOT  "$DISK"   # 8309 = Linux LUKS
sgdisk -n3:0:${HOME_SIZE} -t3:8309 -c3:LUKS-HOME  "$DISK"
partprobe "$DISK" >/dev/null 2>&1 || true; udevadm settle || true

echo "==> format + open LUKS"
mkfs.fat -F32 -n EFI "$P1"
echo "LUKS ROOT (enter passphrase):"
cryptsetup luksFormat --type luks2 --pbkdf argon2id --iter-time 5000 "$P2"
cryptsetup open "$P2" root
echo "LUKS HOME (enter passphrase):"
cryptsetup luksFormat --type luks2 --pbkdf argon2id --iter-time 5000 "$P3"
cryptsetup open "$P3" home

echo "==> mkfs.btrfs + subvolumes (extended scheme)"
mkfs.btrfs -L ROOT /dev/mapper/root
mkfs.btrfs -L HOME /dev/mapper/home

# ROOT subvols
mount /dev/mapper/root /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@var_tmp
btrfs subvolume create /mnt/@pkg
umount /mnt

# HOME subvols
mount /dev/mapper/home /mnt
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@home.snapshots
umount /mnt

echo "==> mount subvolumes"
mount -o rw,noatime,ssd,compress=zstd,subvol=@ /dev/mapper/root /mnt
mkdir -p /mnt/.snapshots /mnt/var/log /mnt/var/tmp /mnt/var/cache/pacman/pkg /mnt/home
mount -o rw,noatime,ssd,compress=zstd,subvol=@snapshots     /dev/mapper/root /mnt/.snapshots
mount -o rw,noatime,ssd,compress=zstd,subvol=@var_log       /dev/mapper/root /mnt/var/log
mount -o rw,noatime,ssd,compress=zstd,subvol=@var_tmp       /dev/mapper/root /mnt/var/tmp
mount -o rw,noatime,ssd,compress=zstd,subvol=@pkg           /dev/mapper/root /mnt/var/cache/pacman/pkg

mount -o rw,noatime,ssd,compress=zstd,subvol=@home          /dev/mapper/home /mnt/home
mkdir -p /mnt/home/.snapshots
mount -o rw,noatime,ssd,compress=zstd,subvol=@home.snapshots /dev/mapper/home /mnt/home/.snapshots

mkdir -p /mnt/boot
mount "$P1" /mnt/boot

echo "==> pacstrap (non-interactive)"
# pacstrap on some ISOs has no --noconfirm, so feed 'yes'
yes | pacstrap /mnt \
  base linux linux-firmware btrfs-progs intel-ucode networkmanager \
  nvidia nvidia-utils \
  hyprland xorg-xwayland qt6-wayland egl-wayland xdg-desktop-portal xdg-desktop-portal-hyprland \
  firefox wezterm \
  noto-fonts noto-fonts-emoji ttf-dejavu ttf-nerd-fonts-symbols-mono \
  snapper zram-generator zsh zsh-completions sudo

genfstab -U /mnt >> /mnt/etc/fstab

ROOT_UUID="$(blkid -s UUID -o value "$P2")"
HOME_UUID="$(blkid -s UUID -o value "$P3")"

echo "==> system config in chroot"
arch-chroot /mnt /bin/bash -eux <<EOF
set -euo pipefail

# 1) locales (write full file with only needed locales)
cat >/etc/locale.gen <<'EOLC'
en_US.UTF-8 UTF-8
ru_RU.UTF-8 UTF-8
EOLC
locale-gen
echo "LANG=${LANGV}" > /etc/locale.conf

# 2) console font/map (TTY Cyrillic)
cat >/etc/vconsole.conf <<'EOVC'
KEYMAP=us
FONT=cyr-sun16
FONT_MAP=8859-5
EOVC

# 3) tz & clock
ln -sf /usr/share/zoneinfo/${TZONE} /etc/localtime
hwclock --systohc

# 4) hostname & hosts
echo "${HOSTNAME}" > /etc/hostname
cat >/etc/hosts <<'EOH'
127.0.0.1 localhost
::1       localhost
127.0.1.1 arch-pc.localdomain arch-pc
EOH

# 5) mkinitcpio (full file, systemd scheme + btrfs + NVIDIA KMS)
cat >/etc/mkinitcpio.conf <<'EOMK'
MODULES=(nvidia nvidia_modeset nvidia_drm tpm tpm_tis btrfs)
BINARIES=(/usr/bin/btrfs)
FILES=()
HOOKS=(base systemd autodetect modconf kms keyboard sd-vconsole block sd-encrypt btrfs filesystems fsck)
COMPRESSION="zstd"
EOMK
mkinitcpio -P

# 6) NVIDIA KMS
mkdir -p /etc/modprobe.d
echo "options nvidia-drm modeset=1" > /etc/modprobe.d/nvidia.conf

# 7) systemd-boot
bootctl install
cat >/boot/loader/loader.conf <<'EOLDR'
default arch.conf
timeout 1
console-mode max
editor no
auto-entries yes
EOLDR
cat >/boot/loader/entries/arch.conf <<EOLDE
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options rd.luks.name=${ROOT_UUID}=root rd.luks.options=discard root=/dev/mapper/root rootflags=subvol=@,compress=zstd rw nvidia_drm.modeset=1
EOLDE

# 8) crypttab (discard only via LUKS for HOME)
echo "home UUID=${HOME_UUID} none luks,discard" > /etc/crypttab

# 9) TRIM weekly (no 'discard' in fstab)
systemctl enable fstrim.timer

# 10) zram 16G (zstd)
cat >/etc/systemd/zram-generator.conf <<'EOZ'
[zram0]
zram-size = 16G
compression-algorithm = zstd
EOZ

# 11) network
systemctl enable NetworkManager

# 12) user + zsh + sudo
pacman -S --noconfirm --needed zsh zsh-completions sudo
useradd -m -G wheel -s /usr/bin/zsh ${USER_NAME}
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers
EOF

echo "==> set passwords"
arch-chroot /mnt /bin/bash -c "echo 'root:${ROOT_PW}' | chpasswd"
arch-chroot /mnt /bin/bash -c "echo '${USER_NAME}:${USER_PW}' | chpasswd"

echo "==> Hyprland minimal (no DM) + WezTerm + fonts configs"
arch-chroot /mnt /bin/bash -eux <<'EOF2'
set -euo pipefail
U="${USER_NAME}"

# ~/.zprofile: autostart Hyprland from tty1
install -d -m 0700 /home/$U
cat >/home/$U/.zprofile <<'EOPR'
# Autostart Hyprland from tty1 (no display manager)
if [[ -z "$DISPLAY" && "$(tty)" == "/dev/tty1" ]]; then
  exec Hyprland
fi
EOPR
chown $U:$U /home/$U/.zprofile

# ~/.config/hypr/hyprland.conf
install -d -m 0700 /home/$U/.config/hypr
cat >/home/$U/.config/hypr/hyprland.conf <<'EOHY'
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
EOHY
chown -R $U:$U /home/$U/.config/hypr

# ~/.config/wezterm/wezterm.lua
install -d -m 0700 /home/$U/.config/wezterm
cat >/home/$U/.config/wezterm/wezterm.lua <<'EOWZ'
local wezterm = require 'wezterm'
return {
  enable_wayland = true,
  font = wezterm.font_with_fallback({
    "DejaVu Sans Mono",
    "Symbols Nerd Font Mono",
  }),
  color_scheme = "Builtin Tango Dark",
}
EOWZ
chown -R $U:$U /home/$U/.config/wezterm
EOF2

echo "==> Snapper: two configs, manual mode, baseline"
arch-chroot /mnt /bin/bash -eux <<'EO3'
set -euo pipefail
# create configs
snapper -c root create-config /
snapper -c home create-config /home
# disable timeline/cleanup via CLI (без sed)
snapper -c root set-config "TIMELINE_CREATE=no" "NUMBER_CLEANUP=no"
snapper -c home set-config "TIMELINE_CREATE=no" "NUMBER_CLEANUP=no"
# mount again (create-config may touch mounts)
mount -a
# baseline snapshot for root
snapper -c root create -d "baseline-0 post-install"
EO3

echo "==> done. To finish:"
echo "umount -R /mnt ; reboot"
echo "(After first login: if monitor names differ, edit ~/.config/hypr/hyprland.conf)"
