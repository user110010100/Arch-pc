#!/usr/bin/env bash
# Arch minimal install with LUKS (root/home), Btrfs subvolumes, systemd-boot,
# NVIDIA KMS, Hyprland (no DM), zram, fstrim.timer, Snapper manual, baseline snapshot.
# Idempotent: fully wipes target disk on each run.

set -Eeuo pipefail

### ======== USER VARS (you can edit) ========
DISK_DEFAULT="/dev/sda"          # например: /dev/nvme0n1
HOSTNAME_DEFAULT="archpc"
USERNAME_DEFAULT="user404"
TZ_DEFAULT="Europe/Amsterdam"
LOCALES_DEFAULT=("en_US.UTF-8 UTF-8" "ru_RU.UTF-8 UTF-8")
LANG_DEFAULT="en_US.UTF-8"
# Разметка: 1G (EFI) + 120G (LUKS-root) + 250G (LUKS-home) + остальное свободно
EFI_SIZE="+1G"
ROOT_SIZE="+120G"
HOME_SIZE="+250G"
# Сабволюмы
ROOT_SUBVOLS=(@ @snapshots @var_log @var_tmp @pkg)
HOME_SUBVOLS=(@home @home.snapshots)
# Мониторы Hyprland (при необходимости потом поправите именования выходов)
HYPR_MON1="DP-1, 1920x1080@60, 0x0, 1"
HYPR_MON2="HDMI-A-1, 1920x1080@60, 1920x0, 1"
### =========================================

ts="$(date +%F_%H%M%S)"
LOG="/tmp/arch_install_${ts}.log"
exec > >(tee -a "$LOG") 2>&1

on_error() {
  echo "ERROR at line $1. См. лог: $LOG"
}
trap 'on_error $LINENO' ERR

cecho() { echo -e "\n\033[1;36m==> $*\033[0m\n"; }
wecho() { echo -e "\033[1;33m[!] $*\033[0m"; }
fecho() { echo -e "\033[1;31m[✗] $*\033[0m"; }

require_root() { [[ $EUID -eq 0 ]] || { fecho "Run as root"; exit 1; }; }

check_uefi() {
  if [[ ! -d /sys/firmware/efi/efivars ]]; then
    fecho "UEFI среда не обнаружена. Перезагрузитесь в UEFI."
    exit 1
  fi
}

prompt_vars() {
  read -rp "Диск для установки [${DISK_DEFAULT}]: " DISK || true
  DISK="${DISK:-$DISK_DEFAULT}"
  read -rp "Имя хоста [${HOSTNAME_DEFAULT}]: " HOSTNAME || true
  HOSTNAME="${HOSTNAME:-$HOSTNAME_DEFAULT}"
  read -rp "Имя пользователя [${USERNAME_DEFAULT}]: " USERNAME || true
  USERNAME="${USERNAME:-$USERNAME_DEFAULT}"
  read -rsp "Пароль пользователя ${USERNAME}: " USER_PW; echo
  read -rsp "Пароль root: " ROOT_PW; echo
  wecho "Во время LUKS-форматирования вам нужно будет ВВЕСТИ ПАРОЛИ для root/home контейнеров."
  echo
}

ensure_net() {
  cecho "Проверка сети…"
  ping -c1 archlinux.org >/dev/null 2>&1 || {
    fecho "Нет сети. Подключите интернет и повторите."
    exit 1
  }
}

cleanup_previous() {
  cecho "Отключаем и размонтируем остатки предыдущего запуска…"
  swapoff -a || true
  umount -R /mnt || true
  for m in root home; do
    if /usr/bin/ls /dev/mapper/$m >/dev/null 2>&1; then
      cryptsetup close "$m" || true
    fi
  done
}

wipe_and_partition() {
  cecho "Полная очистка диска $DISK и разметка (EFI / LUKS-root / LUKS-home)…"
  sgdisk --zap-all "$DISK"
  wipefs -af "$DISK"
  partprobe "$DISK"

  # GPT: 1 - EFI, 2 - LUKS-root, 3 - LUKS-home; оставшееся место неразмечено
  sgdisk -n1:0:${EFI_SIZE}  -t1:ef00 -c1:"EFI"        "$DISK"
  sgdisk -n2:0:${ROOT_SIZE} -t2:8309 -c2:"LUKS-ROOT"  "$DISK"  # 8309 = Linux LUKS
  sgdisk -n3:0:${HOME_SIZE} -t3:8309 -c3:"LUKS-HOME"  "$DISK"
  partprobe "$DISK"; udevadm settle

  # Определяем имена разделов (nvme vs sda)
  if [[ "$DISK" =~ nvme ]]; then
    P1="${DISK}p1"; P2="${DISK}p2"; P3="${DISK}p3"
  else
    P1="${DISK}1";  P2="${DISK}2";  P3="${DISK}3"
  fi

  export P1 P2 P3
}

format_encrypt() {
  cecho "Форматирование: EFI (vfat), LUKS для root/home…"
  mkfs.fat -F32 -n EFI "$P1"

  echo
  wecho "Введите ПАРОЛЬ для LUKS ROOT (/dev/mapper/root):"
  cryptsetup luksFormat --type luks2 --pbkdf argon2id --iter-time 5000 "$P2"
  cryptsetup open "$P2" root

  wecho "Введите ПАРОЛЬ для LUKS HOME (/dev/mapper/home):"
  cryptsetup luksFormat --type luks2 --pbkdf argon2id --iter-time 5000 "$P3"
  cryptsetup open "$P3" home

  cecho "Создание файловых систем Btrfs…"
  mkfs.btrfs -L ROOT /dev/mapper/root
  mkfs.btrfs -L HOME /dev/mapper/home
}

create_subvols() {
  cecho "Создание сабволюмов на ROOT…"
  mount /dev/mapper/root /mnt
  for sv in "${ROOT_SUBVOLS[@]}"; do
    btrfs subvolume create "/mnt/$sv"
  done
  umount /mnt

  cecho "Создание сабволюмов на HOME…"
  mount /dev/mapper/home /mnt
  for sv in "${HOME_SUBVOLS[@]}"; do
    btrfs subvolume create "/mnt/$sv"
  done
  umount /mnt
}

mount_all() {
  cecho "Монтирование субтомов…"
  # ROOT
  mount -o noatime,ssd,compress=zstd:3,subvol=@ /dev/mapper/root /mnt
  mkdir -p /mnt/.snapshots /mnt/var/log /mnt/var/tmp /mnt/var/cache/pacman/pkg /mnt/home
  mount -o noatime,ssd,compress=zstd:3,subvol=@snapshots /dev/mapper/root /mnt/.snapshots
  mount -o noatime,ssd,compress=zstd:3,subvol=@var_log   /dev/mapper/root /mnt/var/log
  mount -o noatime,ssd,compress=zstd:3,subvol=@var_tmp   /dev/mapper/root /mnt/var/tmp
  mount -o noatime,ssd,compress=zstd:3,subvol=@pkg       /dev/mapper/root /mnt/var/cache/pacman/pkg

  # HOME
  mount -o noatime,ssd,compress=zstd:3,subvol=@home /dev/mapper/home /mnt/home
  mkdir -p /mnt/home/.snapshots
  mount -o noatime,ssd,compress=zstd:3,subvol=@home.snapshots /dev/mapper/home /mnt/home/.snapshots

  # EFI
  mkdir -p /mnt/boot
  mount "$P1" /mnt/boot
}

pacstrap_base() {
  cecho "Установка базовой системы и пакетов…"
  # Минимум + микрокод + btrfs + сеть + nvidia + hyprland + порталы + fonts + firefox + wezterm + snapper + zram
  pacstrap -K /mnt \
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

  cecho "Базовая конфигурация внутри системы…"
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

  # hostname & hosts
  echo "$HOSTNAME" > /mnt/etc/hostname
  cat >/mnt/etc/hosts <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${HOSTNAME}.localdomain ${HOSTNAME}
EOF

  # mkinitcpio: MODULES/BINARIES/HOOKS (systemd схема + btrfs + sd-encrypt + KMS NVIDIA)
  sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_modeset nvidia_drm tpm tpm_tis btrfs)/' /mnt/etc/mkinitcpio.conf
  sed -i 's|^BINARIES=.*|BINARIES=(/usr/bin/btrfs)|' /mnt/etc/mkinitcpio.conf
  sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect modconf kms keyboard sd-vconsole block sd-encrypt btrfs filesystems fsck)/' /mnt/etc/mkinitcpio.conf
  in_chroot "mkinitcpio -P"

  # NVIDIA KMS
  mkdir -p /mnt/etc/modprobe.d
  echo "options nvidia-drm modeset=1" > /mnt/etc/modprobe.d/nvidia.conf

  # systemd-boot
  in_chroot "bootctl install"
  cat >/mnt/boot/loader/loader.conf <<'EOF'
default arch.conf
timeout 1
console-mode max
editor no
auto-entries yes
EOF
  cat >/mnt/boot/loader/entries/arch.conf <<EOF
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options rd.luks.name=${ROOT_UUID}=root rd.luks.options=discard root=/dev/mapper/root rootflags=subvol=@,compress=zstd rw nvidia_drm.modeset=1
EOF

  # crypttab (home с discard — TRIM через LUKS)
  echo "home UUID=${HOME_UUID} none luks,discard" > /mnt/etc/crypttab

  # TRIM еженедельно (без discard в fstab)
  in_chroot "systemctl enable fstrim.timer"

  # zram 16G zstd
  cat >/mnt/etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = 16G
compression-algorithm = zstd
EOF

  # сеть
  in_chroot "systemctl enable NetworkManager"
}

configure_snapper() {
  cecho "Настройка Snapper (ручной режим + baseline)…"
  in_chroot "umount /.snapshots || true; umount /home/.snapshots || true; true"
  in_chroot "snapper -c root create-config /"
  in_chroot "snapper -c home create-config /home"

  # Отключаем timeline/cleanup
  in_chroot "sed -i 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE=\"no\"/' /etc/snapper/configs/root"
  in_chroot "sed -i 's/^NUMBER_CLEANUP=.*/NUMBER_CLEANUP=\"no\"/' /etc/snapper/configs/root"
  in_chroot "sed -i 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE=\"no\"/' /etc/snapper/configs/home"
  in_chroot "sed -i 's/^NUMBER_CLEANUP=.*/NUMBER_CLEANUP=\"no\"/' /etc/snapper/configs/home"

  # Перемонтируем точки снапшотов (могли отмонтироваться при create-config)
  in_chroot "mount -a"

  # Базовый снапшот root
  in_chroot "snapper -c root create -d 'baseline-0 post-install'"
}

create_user_env() {
  cecho "Создание пользователя и окружения Hyprland/WezTerm…"
  in_chroot "pacman -S --noconfirm zsh zsh-completions sudo"
  in_chroot "useradd -m -G wheel -s /usr/bin/zsh ${USERNAME}"
  # Пароли
  echo "root:${ROOT_PW}" | in_chroot "chpasswd"
  echo "${USERNAME}:${USER_PW}" | in_chroot "chpasswd"
  echo "%wheel ALL=(ALL) ALL" >> /mnt/etc/sudoers

  # Автозапуск Hyprland с tty1
  in_chroot "install -d -m 0700 /home/${USERNAME}"
  cat >/mnt/home/${USERNAME}/.zprofile <<'EOF'
# Автозапуск Hyprland с tty1 без дисплей-менеджера
if [[ -z "$DISPLAY" && "$(tty)" == "/dev/tty1" ]]; then
  exec Hyprland
fi
EOF
  in_chroot "chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.zprofile"

  # Hyprland конфиг
  in_chroot "install -d -m 0700 /home/${USERNAME}/.config/hypr"
  cat >/mnt/home/${USERNAME}/.config/hypr/hyprland.conf <<EOF
monitor = ${HYPR_MON1}
monitor = ${HYPR_MON2}
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
EOF
  in_chroot "chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.config"

  # WezTerm конфиг + fallback шрифты
  in_chroot "install -d -m 0700 /home/${USERNAME}/.config/wezterm"
  cat >/mnt/home/${USERNAME}/.config/wezterm/wezterm.lua <<'EOF'
local wezterm = require 'wezterm'
return {
  enable_wayland = true,
  font = wezterm.font_with_fallback({
    "DejaVu Sans Mono",
    "Symbols Nerd Font Mono",
  }),
  color_scheme = "Builtin Tango Dark",
}
EOF
  in_chroot "chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.config/wezterm"
}

copy_log_and_finish() {
  cecho "Копирование лога в установленную систему…"
  mkdir -p /mnt/var/log/installer
  cp -a "$LOG" /mnt/var/log/installer/

  cecho "Готово! Можно перезагружаться."
  echo "Команды проверки после первого входа:"
  cat <<'EOCHECKS'
  lsblk
  bootctl status
  systemctl status fstrim.timer
  swapon --show
  snapper -c root list
  hyprctl monitors   # проверить имена выходов
EOCHECKS
}

main() {
  require_root
  check_uefi
  prompt_vars
  ensure_net
  cleanup_previous
  wipe_and_partition
  format_encrypt
  create_subvols
  mount_all
  pacstrap_base
  configure_system
  configure_snapper
  create_user_env
  copy_log_and_finish

  wecho "ВНИМАНИЕ: Если имена выводов мониторов отличаются от DP-1/HDMI-A-1 — поправьте ~/.config/hypr/hyprland.conf после входа."
  wecho "TRIM: discard в fstab НЕ используем; работает fstrim.timer и discard через LUKS (rd.luks.options=discard, crypttab)."
}

main "$@"
