#!/usr/bin/env bash
# Arch Linux (Btrfs+LUKS), минимальная установка + Hyprland + ZRAM + Snapper
# Комментарии на русском для разработчиков; все пользовательские подсказки и вопросы — на английском.

set -Eeuo pipefail
IFS=$'\n\t'

# ────────────────────────────────────────────────────────────────────────────────
# Параметры (при необходимости подредактируйте)
# ────────────────────────────────────────────────────────────────────────────────
DEFAULT_DISK="/dev/sda"
ESP_SIZE_G="1G"            # EFI
ROOT_SIZE_G="120G"         # root (LUKS)
HOME_SIZE_G="250G"         # home (LUKS) — оставшееся место останется свободно под VeraCrypt
HOSTNAME="arch-pc"
USERNAME="user404"
USER_SHELL="/usr/bin/zsh"
TIMEZONE="Europe/Amsterdam"

# Важно: согласно вашим требованиям к монтированию Btrfs
BTRFS_OPTS="noatime,compress=zstd"

# Пакеты базовой системы
PACSTRAP_PKGS=(base linux linux-firmware btrfs-progs intel-ucode git nano networkmanager curl dbus fontconfig)

# URLs ваших конфигов
HYPRLAND_URL="https://raw.githubusercontent.com/user110010100/Arch-pc/refs/heads/main/hyprland.conf"
WEZTERM_URL="https://raw.githubusercontent.com/user110010100/Arch-pc/refs/heads/main/wezterm.lua"

# ────────────────────────────────────────────────────────────────────────────────
# Утилиты
# ────────────────────────────────────────────────────────────────────────────────
log(){ printf '%s %s\n' "$(date -Is)" "$*"; }
fail(){ log "ERROR: $*" >&2; exit 1; }
require_root(){ [[ $EUID -eq 0 ]] || fail "Run this script as root."; }

confirm(){
  local msg="$1" ans
  printf '\n%s\n' "$msg"
  read -r -p 'Type "YES" to continue: ' ans
  [[ $ans == YES ]] || fail "Canceled by user."
}

cleanup_partial(){
  log "Cleaning up previous mounts/mappings if any..."
  mountpoint -q /mnt/boot  && umount /mnt/boot || true
  mountpoint -q /mnt/home  && umount -R /mnt/home || true
  mountpoint -q /mnt       && umount -R /mnt || true
  for m in root home; do
    [[ -e /dev/mapper/$m ]] && cryptsetup close "$m" || true
  done
  sleep 1
}

need(){
  local cmd="$1" pkg="$2"
  command -v "$cmd" >/dev/null 2>&1 || {
    log "Installing missing tool: $pkg"
    pacman -Sy --noconfirm --needed "$pkg"
  }
}

check_internet(){
  if ! ping -c1 -W2 archlinux.org >/dev/null 2>&1; then
    fail "No internet connectivity. Please ensure networking is up in Live ISO."
  fi
}

# ────────────────────────────────────────────────────────────────────────────────
# chroot-скрипт (настройка системы «изнутри»)
# ────────────────────────────────────────────────────────────────────────────────
create_chroot_script(){
  cat > /mnt/root/chroot_setup.sh <<'CHROOT'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
log(){ printf '%s %s\n' "$(date -Is)" "$*"; }

HOSTNAME="arch-pc"
USERNAME="user404"
TIMEZONE="Europe/Amsterdam"

# ---------- Базовая конфигурация ----------
log "Timezone, locale, console"
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc || true

sed -i 's/^[[:space:]]*#\?[[:space:]]*en_US\.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/^[[:space:]]*#\?[[:space:]]*ru_RU\.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf

cat >/etc/vconsole.conf <<'EOF'
KEYMAP=us
FONT=cyr-sun16
FONT_MAP=8859-5
EOF

echo "${HOSTNAME}" > /etc/hostname

# ---------- Пакеты GUI/NVIDIA/Wayland ----------
log "Installing GUI stack (Hyprland), NVIDIA, portals, browser, terminal, snapper & zram-generator"
pacman -Syu --noconfirm --needed \
  zsh zsh-completions sudo cryptsetup mkinitcpio \
  nvidia nvidia-utils nvidia-settings \
  hyprland xorg-xwayland qt6-wayland egl-wayland \
  xdg-desktop-portal xdg-desktop-portal-hyprland \
  firefox wezterm \
  zram-generator snapper \
  ttf-firacode-nerd noto-fonts noto-fonts-emoji noto-fonts-extra ttf-dejavu ttf-nerd-fonts-symbols-mono

# ---------- Пользователь ----------
if ! id -u "${USERNAME}" >/dev/null 2>&1; then
  useradd -m -G wheel -s /usr/bin/zsh "${USERNAME}"
fi
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

echo "Set password for root:"
passwd
echo "Set password for ${USERNAME}:"
passwd "${USERNAME}"

# ---------- NVIDIA KMS + mkinitcpio ----------
log "Configuring NVIDIA KMS + mkinitcpio"
mkdir -p /etc/modprobe.d
cat >/etc/modprobe.d/nvidia.conf <<'EOF'
options nvidia-drm modeset=1
EOF

sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_drm nvidia_modeset btrfs)/' /etc/mkinitcpio.conf
sed -i 's%^BINARIES=.*%BINARIES=(/usr/bin/btrfs)%' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect modconf kms keyboard sd-vconsole block sd-encrypt btrfs filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# ---------- systemd-boot ----------
log "Installing systemd-boot and entry"
bootctl install

UUID_ROOT=$(blkid -s UUID -o value /dev/sda2 || true)

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

# ---------- HOME через crypttab ----------
log "Writing /etc/crypttab for HOME"
UUID_HOME=$(blkid -s UUID -o value /dev/sda3 || true)
cat >/etc/crypttab <<EOF
home    UUID=${UUID_HOME}    none    luks,discard
EOF
chmod 0600 /etc/crypttab

# ---------- Enable services via symlinks (no systemctl in chroot) ----------
log "Enabling NetworkManager & fstrim.timer via wanted symlinks"
mkdir -p /etc/systemd/system/multi-user.target.wants /etc/systemd/system/timers.target.wants
ln -sf /usr/lib/systemd/system/NetworkManager.service /etc/systemd/system/multi-user.target.wants/NetworkManager.service
ln -sf /usr/lib/systemd/system/fstrim.timer        /etc/systemd/system/timers.target.wants/fstrim.timer

# ---------- ZRAM (zram-generator) ----------
log "Writing zram-generator config (ram/2, zstd)"

# Конфиг создаём атомарно; размер как половина физической RAM; компрессор zstd; высокий приоритет
install -Dm644 /dev/stdin /etc/systemd/zram-generator.conf <<'EOF'
[zram0]
# Размер задаётся от физической RAM: безопаснее и гибче, чем фиксированные "16G"
zram-size = ram / 2
# Оптимальный компрессор по соотношению скорость/сжатие
compression-algorithm = zstd
# Использовать zram раньше любых дисковых swap
swap-priority = 100
EOF

# На всякий случай отключаем устаревшие менеджеры swap, если вдруг стоят
systemctl disable --now systemd-swap.service 2>/dev/null || true

# ---------- Snapper: idempotent setup (supports pre-existing /.snapshots) ----------
# Цель: если сабвольюмы @snapshots / @home.snapshots уже созданы и смонтированы в
# /.snapshots и /home/.snapshots — НЕ вызывать `snapper create-config`, а завести
# конфиги вручную и зарегистрировать их в /etc/conf.d/snapper.
# Официально: конфиг — это файл /etc/snapper/configs/<name>, формат описан в snapper-configs(5).
# `create-config` обычно сам создаёт /.snapshots и прописывает SNAPPER_CONFIGS, но падёт,
# если /.snapshots уже существует. Мы делаем «ручную» инициализацию, сохраняющую минимализм.
log "Configuring Snapper (idempotent; no baseline snapshots here)"

# 0) Утилиты
install -d /etc/snapper/configs

# helper: добавить имена конфигов в /etc/conf.d/snapper (SNAPPER_CONFIGS="root home")
_ensure_sn_configs() {
  local want="$*"
  local f=/etc/conf.d/snapper
  # если файла нет — создаём
  [[ -f "$f" ]] || install -Dm644 /dev/stdin "$f" <<< 'SNAPPER_CONFIGS=""'
  # текущие значения
  local cur; cur="$(sed -n 's/^SNAPPER_CONFIGS="//;s/"$//p' "$f")"
  # собрать уникальный список
  local combined="${cur} ${want}"
  # shellcheck disable=SC2207
  local arr=($(printf '%s\n' $combined | tr ' ' '\n' | sed '/^$/d' | awk '!x[$0]++'))
  local new=$(printf '%s ' "${arr[@]}" | sed 's/ $//')
  sed -i -E "s|^SNAPPER_CONFIGS=.*$|SNAPPER_CONFIGS=\"${new}\"|" "$f"
}

# helper: создать валидный конфиг-файл
_make_cfg() {
  # $1 = имя конфига (root/home), $2 = точка монтирования сабвольюма (/, /home)
  local name="$1" mp="$2" cfg="/etc/snapper/configs/${name}"
  install -Dm600 /dev/stdin "$cfg" <<EOF
# Auto-generated by installer. See snapper-configs(5).
FSTYPE="btrfs"
SUBVOLUME="${mp}"
ALLOW_GROUPS="wheel"
SYNC_ACL="yes"
TIMELINE_CREATE="yes"
NUMBER_CLEANUP="yes"
EOF
  _ensure_sn_configs "$name"
}

# 1) ROOT
if btrfs subvolume show /.snapshots &>/dev/null; then
  # У тебя уже есть отдельный сабвольюм @snapshots, смонтированный в /.snapshots.
  # В этом случае create-config обычно падает — делаем конфиг вручную.
  log "Snapper: /.snapshots exists -> writing /etc/snapper/configs/root manually"
  _make_cfg root /
else
  # Классический путь: позволяем snapper'у сделать /.snapshots и шаблон конфига сам
  log "Snapper: creating config via snapper create-config (root)"
  snapper --no-dbus -c root create-config /
fi

# 2) HOME (опционально; если /home отдельный сабвольюм и есть /home/.snapshots)
if mountpoint -q /home && btrfs subvolume show /home/.snapshots &>/dev/null; then
  log "Snapper: /home/.snapshots exists -> writing /etc/snapper/configs/home manually"
  _make_cfg home /home
else
  log "Snapper: trying create-config for /home (safe to skip if not a separate subvolume)"
  snapper --no-dbus -c home create-config /home 2>/dev/null || true
fi

# 3) Права на каталоги .snapshots (root + ACL синхронизация для группы wheel)
chmod 750 /.snapshots          2>/dev/null || true
chmod 750 /home/.snapshots     2>/dev/null || true

# 4) Включаем таймеры Snapper (timeline/cleanup) — без systemctl, в твоём стиле
mkdir -p /etc/systemd/system/timers.target.wants
ln -sf /usr/lib/systemd/system/snapper-timeline.timer /etc/systemd/system/timers.target.wants/snapper-timeline.timer
ln -sf /usr/lib/systemd/system/snapper-cleanup.timer  /etc/systemd/system/timers.target.wants/snapper-cleanup.timer

# 5) (Важно) Больше НЕ ставим firstboot-snapper.service — снимки сделаешь вручную после загрузки:
#    sudo snapper -c root create --description "baseline-root"
#    sudo snapper -c home create --description "baseline-home"

# ---------- Hyprland & WezTerm конфиги (скачиваем с GitHub с фолбэком) ----------
log "Preparing Hyprland/WezTerm configs"
install -d -m 0700 -o "${USERNAME}" -g "${USERNAME}" /home/${USERNAME}/.config/hypr
install -d -m 0700 -o "${USERNAME}" -g "${USERNAME}" /home/${USERNAME}/.config/wezterm

# Hyprland
if curl -fsSL "https://raw.githubusercontent.com/user110010100/Arch-pc/refs/heads/main/hyprland.conf" \
   -o /home/${USERNAME}/.config/hypr/hyprland.conf; then
  chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.config/hypr/hyprland.conf
else
  # Резервный минимальный конфиг
  cat >/home/${USERNAME}/.config/hypr/hyprland.conf <<'EOF'
monitor = ,preferred,auto,auto
$terminal = wezterm
bind = SUPER, Return, exec, $terminal
exec-once = firefox
EOF
  chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.config/hypr/hyprland.conf
fi

# WezTerm
if curl -fsSL "https://raw.githubusercontent.com/user110010100/Arch-pc/refs/heads/main/wezterm.lua" \
   -o /home/${USERNAME}/.config/wezterm/wezterm.lua; then
  chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.config/wezterm/wezterm.lua
else
  # Резерв: XWayland и базовый шрифт с fallback
  cat >/home/${USERNAME}/.config/wezterm/wezterm.lua <<'EOF'
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
  chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.config/wezterm/wezterm.lua
fi

# Автостарт Hyprland при логине на tty1
cat >/home/${USERNAME}/.zprofile <<'EOF'
if [ "$(tty)" = "/dev/tty1" ]; then
  exec dbus-run-session Hyprland
fi
EOF
chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.zprofile
chmod 0644 /home/${USERNAME}/.zprofile

# Приводим права к безопасным
chmod 0644 /etc/mkinitcpio.conf /boot/loader/loader.conf /boot/loader/entries/arch.conf
chmod 0600 /etc/crypttab

log "chroot_setup.sh finished."
CHROOT
  chmod +x /mnt/root/chroot_setup.sh
}

# ────────────────────────────────────────────────────────────────────────────────
# Основной сценарий
# ────────────────────────────────────────────────────────────────────────────────
main(){
  require_root
  check_internet

  log "Welcome to minimal Arch install (Btrfs+LUKS+Hyprland+ZRAM+Snapper)."
  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE

  read -r -p "Target disk (default ${DEFAULT_DISK}), press Enter to accept or type another (e.g. /dev/nvme0n1): " DISK
  DISK="${DISK:-$DEFAULT_DISK}"
  [[ -b $DISK ]] || fail "Block device not found: $DISK"

  cleanup_partial
  confirm "WARNING: This will DESTROY partitions 1..3 on ${DISK} (EFI, root LUKS, home LUKS). Continue?"

  need sgdisk gptfdisk
  need mkfs.fat dosfstools

  # ---------- Разметка ----------
  log "Partitioning ${DISK} (GPT: 1=ESP, 2=LUKS root, 3=LUKS home; leave free tail for VeraCrypt)"
  sgdisk --zap-all "$DISK"
  sgdisk --clear    "$DISK"
  sgdisk -n 1:0:+${ESP_SIZE_G}  -t 1:ef00 "$DISK"
  sgdisk -n 2:0:+${ROOT_SIZE_G} -t 2:8309 "$DISK"
  sgdisk -n 3:0:+${HOME_SIZE_G} -t 3:8309 "$DISK"
  sgdisk -p "$DISK"
  partprobe "$DISK" || true
  sleep 1

  ESP="${DISK}1"; P2="${DISK}2"; P3="${DISK}3"

  # ---------- LUKS2 + ФС ----------
  log "Initializing LUKS2 on ${P2} (root) and ${P3} (home)"
  cryptsetup luksFormat --type luks2 --pbkdf argon2id --iter-time 5000 "$P2"
  until cryptsetup open "$P2" root; do echo "Wrong passphrase for root. Try again."; done

  cryptsetup luksFormat --type luks2 --pbkdf argon2id --iter-time 5000 "$P3"
  until cryptsetup open "$P3" home; do echo "Wrong passphrase for home. Try again."; done

  log "Formatting filesystems"
  mkfs.fat -F32 "$ESP"
  mkfs.btrfs /dev/mapper/root
  mkfs.btrfs /dev/mapper/home

  # ---------- Сабволюмы ----------
  log "Creating Btrfs subvolumes (root)"
  mount /dev/mapper/root /mnt
  btrfs subvolume create /mnt/@
  btrfs subvolume create /mnt/@snapshots
  btrfs subvolume create /mnt/@var_log
  btrfs subvolume create /mnt/@var_tmp
  btrfs subvolume create /mnt/@pkg
  umount /mnt

  log "Creating Btrfs subvolumes (home)"
  mount /dev/mapper/home /mnt
  btrfs subvolume create /mnt/@home
  btrfs subvolume create /mnt/@home.snapshots
  umount /mnt

  # ---------- Монтирование с вашими опциями ----------
  log "Mounting with: ${BTRFS_OPTS}"
  mount -o ${BTRFS_OPTS},subvol=@ /dev/mapper/root /mnt
  mkdir -p /mnt/.snapshots /mnt/var/log /mnt/var/tmp /mnt/var/cache/pacman/pkg /mnt/home
  mount -o ${BTRFS_OPTS},subvol=@snapshots /dev/mapper/root /mnt/.snapshots
  mount -o ${BTRFS_OPTS},subvol=@var_log   /dev/mapper/root /mnt/var/log
  mount -o ${BTRFS_OPTS},subvol=@var_tmp   /dev/mapper/root /mnt/var/tmp
  mount -o ${BTRFS_OPTS},subvol=@pkg       /dev/mapper/root /mnt/var/cache/pacman/pkg

  mount -o ${BTRFS_OPTS},subvol=@home           /dev/mapper/home /mnt/home
  mkdir -p /mnt/home/.snapshots
  mount -o ${BTRFS_OPTS},subvol=@home.snapshots /dev/mapper/home /mnt/home/.snapshots

  mkdir -p /mnt/boot
  mount "$ESP" /mnt/boot

  # ---------- База системы ----------
  log "Pacstrapping base system"
  pacstrap /mnt "${PACSTRAP_PKGS[@]}"

  log "Generating fstab"
  genfstab -U /mnt >> /mnt/etc/fstab

  # ---------- chroot-шаг ----------
  create_chroot_script
  log "Running arch-chroot setup"
  arch-chroot /mnt /root/chroot_setup.sh

  # ---------- Финал ----------
  log "Installation finished."
  echo
  echo "Do you want to reboot into the installed system now?"
  read -r -p 'Type "YES" to unmount, close LUKS, and reboot (anything else to leave mounted): ' ans
  if [[ $ans == YES ]]; then
    umount -R /mnt || true
    swapoff -a 2>/dev/null || true
    # Закрываем маппинги (на случай если кто-то смонтировал ещё что-то)
    for m in home root; do
      [[ -e /dev/mapper/$m ]] && cryptsetup close "$m" || true
    done
    reboot
  else
    log "Left mounted at /mnt for manual inspection."
  fi
}

main "$@"
