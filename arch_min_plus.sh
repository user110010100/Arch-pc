#!/usr/bin/env bash
# Arch minimal install with LUKS (root/home), Btrfs subvols, systemd-boot, Hyprland (no DM)
# i5 + RTX 3060; VeraCrypt free tail preserved; NO time sync; NO TPM; NO final checks in this script.

set -Eeuo pipefail
IFS=$'\n\t'

### --- Настройки (можно править) ---
DISK_DEFAULT="/dev/sda"              # Диск по умолчанию
HOSTNAME="myarch"
USERNAME="user404"
USER_SHELL="/usr/bin/zsh"

# Локали/TTY
LOCALE_MAIN="en_US.UTF-8"
LOCALE_EXTRA="ru_RU.UTF-8"
TTY_KEYMAP="us"
TTY_FONT="cyr-sun16"
TTY_FONT_MAP="8859-5"

# Разметка
ESP_SIZE="+1G"
ROOT_SIZE="+120G"
HOME_SIZE="+250G"

# ZRAM
ZRAM_SIZE="16G"
ZRAM_ALGO="zstd"

# Hyprland пример (проверьте имена выходов позже `hyprctl monitors`)
HYPR_MON1="DP-1, 1920x1080@60, 0x0, 1"
HYPR_MON2="HDMI-A-1, 1920x1080@60, 1920x0, 1"

### --- Глобальные переменные ---
MNT="/mnt"
LUKS_NAME_ROOT="root"
LUKS_NAME_HOME="home"

### --- Логирование/ошибки ---
log() { printf "\n\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn(){ printf "\n\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err() { printf "\n\033[1;31m[ERR]\033[0m  %s\n" "$*"; }
on_err() {
  err "Произошла ошибка на строке $1. Скрипт остановлен."
  err "Смонтированные точки будут попытаны к размонтированию."
  umount -R "$MNT" 2>/dev/null || true
  exit 1
}
trap 'on_err $LINENO' ERR

require_root() {
  if [[ $EUID -ne 0 ]]; then
    err "Запустите скрипт от root."
    exit 1
  fi
}

require_uefi() {
  if [[ ! -d /sys/firmware/efi/efivars ]]; then
    err "UEFI не обнаружен. Включите UEFI и отключите Secure Boot."
    exit 1
  fi
}

prompt_disk() {
  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE
  echo
  read -rp "Диск для установки (Enter для ${DISK_DEFAULT}, или укажите явно, напр. /dev/nvme0n1): " DISK
  DISK="${DISK:-$DISK_DEFAULT}"

  if [[ ! -b "$DISK" ]]; then
    err "Устройство $DISK не существует."
    exit 1
  fi

  warn "ВНИМАНИЕ: ВСЕ ДАННЫЕ НА ${DISK} БУДУТ УДАЛЕНЫ."
  read -rp "Для подтверждения введите: YES_TO_ERASE ${DISK} : " CONF
  if [[ "$CONF" != "YES_TO_ERASE ${DISK}" ]]; then
    err "Подтверждение не получено. Выход."
    exit 1
  fi
  echo "$DISK"
}

partition_disk() {
  local disk="$1"
  log "Разметка диска ${disk} (ESP ${ESP_SIZE} → ROOT ${ROOT_SIZE} → HOME ${HOME_SIZE} → остальное свободно)"
  sgdisk --zap-all "$disk"

  # 1: EFI System Partition
  sgdisk -n 1:0:"${ESP_SIZE}"   -t 1:EF00 -c 1:"EFI System Partition" "$disk"
  # 2: LUKS-ROOT
  sgdisk -n 2:0:"${ROOT_SIZE}"  -t 2:8300 -c 2:"LUKS-ROOT"            "$disk"
  # 3: LUKS-HOME
  sgdisk -n 3:0:"${HOME_SIZE}"  -t 3:8300 -c 3:"LUKS-HOME"            "$disk"

  partprobe "$disk"
}

read_pass() {
  local label="$1"
  local pass pass2
  while true; do
    read -rs -p "Введите пароль для ${label}: " pass; echo
    read -rs -p "Повторите пароль для ${label}: " pass2; echo
    if [[ "$pass" == "$pass2" && -n "$pass" ]]; then
      printf '%s' "$pass"
      return 0
    fi
    warn "Пароли не совпадают или пусты. Повторите."
  done
}

setup_luks() {
  local p2="$1" p3="$2"
  log "Форматирование LUKS (root/home)"
  local pass_root pass_home
  pass_root="$(read_pass "${p2} (ROOT)")"
  pass_home="$(read_pass "${p3} (HOME)")"

  # Создание контейнеров (без лишних вопросов)
  printf '%s' "$pass_root" | cryptsetup luksFormat --type luks2 --pbkdf argon2id --iter-time 5000 --batch-mode "$p2" --key-file -
  printf '%s' "$pass_home" | cryptsetup luksFormat --type luks2 --pbkdf argon2id --iter-time 5000 --batch-mode "$p3" --key-file -

  # Открытие
  printf '%s' "$pass_root" | cryptsetup open "$p2" "$LUKS_NAME_ROOT" --key-file -
  printf '%s' "$pass_home" | cryptsetup open "$p3" "$LUKS_NAME_HOME" --key-file -

  # Очистка переменных
  pass_root=""; pass_home=""
}

setup_btrfs_and_mount() {
  local esp="$1" mroot="/dev/mapper/${LUKS_NAME_ROOT}" mhome="/dev/mapper/${LUKS_NAME_HOME}"

  log "Создание ФС: ESP (FAT32), ROOT (btrfs), HOME (btrfs)"
  mkfs.fat -F32 "$esp"
  mkfs.btrfs -f "$mroot"
  mkfs.btrfs -f "$mhome"

  log "Создание сабволюмов (root/home)"
  mount "$mroot" "$MNT"
  btrfs subvolume create "$MNT/@"
  btrfs subvolume create "$MNT/@snapshots"
  btrfs subvolume create "$MNT/@var_log"
  btrfs subvolume create "$MNT/@var_tmp"
  btrfs subvolume create "$MNT/@pkg"
  umount "$MNT"

  mount "$mhome" "$MNT"
  btrfs subvolume create "$MNT/@home"
  btrfs subvolume create "$MNT/@home.snapshots"
  umount "$MNT"

  log "Монтирование сабволюмов"
  mount -o noatime,compress=zstd,subvol=@ "$mroot" "$MNT"
  mkdir -p "$MNT/.snapshots" "$MNT/var/log" "$MNT/var/tmp" "$MNT/var/cache/pacman/pkg" "$MNT/home"
  mount -o noatime,compress=zstd,subvol=@snapshots     "$mroot" "$MNT/.snapshots"
  mount -o noatime,compress=zstd,subvol=@var_log       "$mroot" "$MNT/var/log"
  mount -o noatime,compress=zstd,subvol=@var_tmp       "$mroot" "$MNT/var/tmp"
  mount -o noatime,compress=zstd,subvol=@pkg           "$mroot" "$MNT/var/cache/pacman/pkg"

  mount -o noatime,compress=zstd,subvol=@home          "$mhome" "$MNT/home"
  mkdir -p "$MNT/home/.snapshots"
  mount -o noatime,compress=zstd,subvol=@home.snapshots "$mhome" "$MNT/home/.snapshots"

  mkdir -p "$MNT/boot"
  mount "$esp" "$MNT/boot"
}

bootstrap_base() {
  log "Базовая система (pacstrap) — это может занять несколько минут..."
  # Не задаём вопросы pacman/pacstrap:
  export PACMAN="pacman --noconfirm"
  pacstrap -K "$MNT" base linux linux-firmware btrfs-progs intel-ucode git nano networkmanager
  genfstab -U "$MNT" >> "$MNT/etc/fstab"
}

chroot_phase() {
  local disk="$1"
  local p2="${disk}2"
  local p3="${disk}3"

  local uuid_root uuid_home
  uuid_root="$(blkid -s UUID -o value "$p2")"
  uuid_home="$(blkid -s UUID -o value "$p3")"

  log "Выполнение конфигурации внутри chroot (это займёт время: mkinitcpio, pacman...)"

  arch-chroot "$MNT" /usr/bin/env bash --noprofile --norc -euo pipefail -c "
set -Eeuo pipefail
IFS=\$'\n\t'
export PACMAN_OPTS='--noconfirm --needed'

# Локали/hostname
sed -i \"s/^#\\s*${LOCALE_MAIN}.*/${LOCALE_MAIN} UTF-8/\" /etc/locale.gen
sed -i \"s/^#\\s*${LOCALE_EXTRA}.*/${LOCALE_EXTRA} UTF-8/\" /etc/locale.gen
locale-gen
printf '%s\n' 'LANG=${LOCALE_MAIN}' > /etc/locale.conf
printf '%s\n' '${HOSTNAME}' > /etc/hostname

# vconsole (TTY)
cat >/etc/vconsole.conf <<EOF_VC
KEYMAP=${TTY_KEYMAP}
FONT=${TTY_FONT}
FONT_MAP=${TTY_FONT_MAP}
EOF_VC

# Пользователь/шелл
pacman \${PACMAN_OPTS} -S zsh zsh-completions
echo 'Задайте пароль для root:'
passwd
useradd -m -G wheel -s ${USER_SHELL} ${USERNAME}
echo 'Задайте пароль для пользователя ${USERNAME}:'
passwd ${USERNAME}
echo '%wheel ALL=(ALL) ALL' >> /etc/sudoers

# NVIDIA + KMS
pacman \${PACMAN_OPTS} -S nvidia nvidia-utils nvidia-settings
echo 'options nvidia-drm modeset=1' > /etc/modprobe.d/nvidia.conf

# mkinitcpio (без TPM)
sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_drm nvidia_modeset btrfs)/' /etc/mkinitcpio.conf
sed -i 's|^BINARIES=.*|BINARIES=(/usr/bin/btrfs)|' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect modconf kms keyboard sd-vconsole block sd-encrypt btrfs filesystems fsck)/' /etc/mkinitcpio.conf
echo 'Сборка initramfs... (mkinitcpio -P)'
mkinitcpio -P

# systemd-boot
bootctl install
cat >/boot/loader/loader.conf <<'EOF_LDR'
default arch.conf
timeout 1
console-mode max
editor no
auto-entries yes
EOF_LDR

cat >/boot/loader/entries/arch.conf <<EOF_ENT
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options rd.luks.name=${uuid_root}=root rd.luks.options=discard root=/dev/mapper/root rootflags=subvol=@,compress=zstd rw nvidia-drm.modeset=1
EOF_ENT

# crypttab (TRIM только на уровне LUKS)
cat >/etc/crypttab <<EOF_CRY
home    UUID=${uuid_home}    none    luks,discard
EOF_CRY

# Сеть и TRIM
systemctl enable NetworkManager
systemctl enable fstrim.timer

# Hyprland + порталы + браузер + терминал
pacman \${PACMAN_OPTS} -S hyprland xorg-xwayland qt6-wayland egl-wayland xdg-desktop-portal xdg-desktop-portal-hyprland firefox wezterm

# Конфиг Hyprland
install -d -m 0700 -o ${USERNAME} -g ${USERNAME} /home/${USERNAME}/.config/hypr
cat >/home/${USERNAME}/.config/hypr/hyprland.conf <<'EOF_HYPR'
# Проверьте имена мониторов `hyprctl monitors` после первого входа
monitor = ${HYPR_MON1}
monitor = ${HYPR_MON2}

workspace = 1, monitor:DP-1
workspace = 2, monitor:HDMI-A-1

\$mainMod = SUPER
\$terminal = wezterm

input {
  kb_layout = us,ru
  kb_options = grp:caps_toggle,terminate:ctrl_alt_bksp
}

bind = \$mainMod, Q, exec, \$terminal
bind = \$mainMod, Return, exec, \$terminal

exec-once = firefox
exec-once = wezterm
EOF_HYPR
chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.config/hypr

# Автозапуск Hyprland на tty1 (без DM)
cat >/home/${USERNAME}/.zprofile <<'EOF_ZP'
if [ \"\$(tty)\" = \"/dev/tty1\" ]; then
  exec dbus-run-session Hyprland
fi
EOF_ZP
chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.zprofile
chmod 0644 /home/${USERNAME}/.zprofile

# WezTerm + шрифты
pacman \${PACMAN_OPTS} -S ttf-nerd-fonts-symbols-mono noto-fonts noto-fonts-emoji ttf-dejavu
install -d -m 0700 -o ${USERNAME} -g ${USERNAME} /home/${USERNAME}/.config/wezterm
cat >/home/${USERNAME}/.config/wezterm/wezterm.lua <<'EOF_WZ'
local wezterm = require 'wezterm'
return {
  enable_wayland = true,
  font = wezterm.font_with_fallback({
    'DejaVu Sans Mono',
    'Symbols Nerd Font Mono',
    'Noto Color Emoji',
  }),
}
EOF_WZ
chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.config/wezterm

# ZRAM
pacman \${PACMAN_OPTS} -S zram-generator
cat >/etc/systemd/zram-generator.conf <<'EOF_ZR'
[zram0]
zram-size = ${ZRAM_SIZE}
compression-algorithm = ${ZRAM_ALGO}
EOF_ZR
systemctl daemon-reload
systemctl enable dev-zram0.swap
# стартовать swap на первом буте; сейчас активировать можно, но не обязательно:
systemctl start dev-zram0.swap || true

# Snapper (два конфига, без таймлайна, базовый снапшот)
pacman \${PACMAN_OPTS} -S snapper
snapper -c root create-config /
snapper -c home create-config /home
sed -i 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE=\"no\"/' /etc/snapper/configs/root
sed -i 's/^NUMBER_CLEANUP=.*/NUMBER_CLEANUP=\"no\"/'   /etc/snapper/configs/root
sed -i 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE=\"no\"/' /etc/snapper/configs/home
sed -i 's/^NUMBER_CLEANUP=.*/NUMBER_CLEANUP=\"no\"/'   /etc/snapper/configs/home
snapper -c root create --description 'baseline-0'

# Гигиена прав
install -d -m 0700 -o ${USERNAME} -g ${USERNAME} /home/${USERNAME}/.config
chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.config
chmod 0644 /etc/mkinitcpio.conf /boot/loader/loader.conf
chmod 0644 /boot/loader/entries/arch.conf
chmod 0600 /etc/crypttab

# Важно: locale/tty уже настроены, тайм-синхронизацию специально не выполняем.
"

  # конец arch-chroot
}

finish_and_hint() {
  log "Готово. Размонтирование и подсказки."
  umount -R "$MNT"
  swapoff /dev/zram0 2>/dev/null || true

  cat <<'NOTE'

✅ Установка завершена.

Далее:
1) Перезагрузитесь:  reboot
2) На экране пароля LUKS введите пароль для ROOT-контейнера.
3) Войдите под пользователем, Hyprland стартует автоматически на tty1.
4) При необходимости скорректируйте имена мониторов в:
   ~/.config/hypr/hyprland.conf

Примечания:
- TRIM выполняется еженедельно (fstrim.timer), discard используется только на уровне LUKS.
- Snapper настроен на ручные снапшоты; создан baseline-0.
- Пакеты ставились без подтверждений (—noconfirm), чтобы исключить подвисания.

NOTE
}

main() {
  require_root
  require_uefi
  local DISK; DISK="$(prompt_disk)"
  local P1="${DISK}1" P2="${DISK}2" P3="${DISK}3"

  partition_disk "$DISK"
  setup_luks "$P2" "$P3"
  setup_btrfs_and_mount "$P1"
  bootstrap_base
  chroot_phase "$DISK"
  finish_and_hint
}

main "$@"
