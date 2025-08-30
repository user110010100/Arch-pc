#!/usr/bin/env bash
# Arch Linux (Btrfs+LUKS), минимальная установка + Hyprland + ZRAM + Snapper

set -Eeuo pipefail
IFS=$'\n\t'

# ──────────────────────────────────────────────────────────────────[...]
# Параметры (при необходимости подредактируйте)
# ──────────────────────────────────────────────────────────────────[...]
DEFAULT_DISK="/dev/sda"
ESP_SIZE_G="1G"            # EFI
ROOT_SIZE_G="120G"         # root (LUKS)
HOME_SIZE_G="250G"         # home (LUKS)
HOSTNAME="arch-pc"
USERNAME="user404"
USER_SHELL="/usr/bin/zsh"
TIMEZONE="Europe/Amsterdam"

BTRFS_OPTS="noatime,compress=zstd"
PACSTRAP_PKGS=(base linux linux-firmware btrfs-progs intel-ucode git nano networkmanager curl dbus fontconfig)
HYPRLAND_URL="https://raw.githubusercontent.com/user110010100/Arch-pc/refs/heads/main/hyprland.conf"
WEZTERM_URL="https://raw.githubusercontent.com/user110010100/Arch-pc/refs/heads/main/wezterm.lua"

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

# ──────────────────────────────────────────────────────────────────[...]
# partition helper: supports /dev/sda, /dev/nvme0n1, /dev/mmcblk0
partition() {
  local disk="$1" num="$2"
  if [[ "$disk" =~ nvme ]] || [[ "$disk" =~ mmcblk ]]; then
    printf "%sp%s" "$disk" "$num"
  else
    printf "%s%s" "$disk" "$num"
  fi
}

# ──────────────────────────────────────────────────────────────────[...]
# chroot-скрипт (настройка системы «изнутри»)
# ──────────────────────────────────────────────────────────────────[...]
create_chroot_script(){
  local uuid_root="$1"
  local uuid_home="$2"
  cat > /mnt/root/chroot_setup.sh <<CHROOT
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=\$'\n\t'
log(){ printf '%s %s\n' "\$(date -Is)" "\$*"; }

HOSTNAME="${HOSTNAME}"
USERNAME="${USERNAME}"
TIMEZONE="${TIMEZONE}"
UUID_ROOT="${uuid_root}"
UUID_HOME="${uuid_home}"

log "Timezone, locale, console"
ln -sf /usr/share/zoneinfo/\${TIMEZONE} /etc/localtime
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

echo "\${HOSTNAME}" > /etc/hostname

log "Installing GUI stack (Hyprland), NVIDIA, portals, browser, terminal, snapper & zram-generator"
pacman -Syu --noconfirm --needed \
  zsh zsh-completions sudo cryptsetup mkinitcpio \
  nvidia nvidia-utils nvidia-settings \
  hyprland xorg-xwayland qt6-wayland egl-wayland \
  xdg-desktop-portal xdg-desktop-portal-hyprland \
  firefox wezterm \
  zram-generator snapper \
  ttf-firacode-nerd noto-fonts noto-fonts-emoji noto-fonts-extra ttf-dejavu ttf-nerd-fonts-symbols-mono

if ! id -u "\${USERNAME}" >/dev/null 2>&1; then
  useradd -m -G wheel -s /usr/bin/zsh "\${USERNAME}"
fi

# Безопасное добавление в sudoers
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/99-wheel
chmod 0440 /etc/sudoers.d/99-wheel

echo "Set password for root:"
passwd
echo "Set password for \${USERNAME}:"
passwd "\${USERNAME}"

log "Configuring NVIDIA KMS + mkinitcpio"
mkdir -p /etc/modprobe.d
cat >/etc/modprobe.d/nvidia.conf <<'EOF'
options nvidia-drm modeset=1
EOF

sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_drm nvidia_modeset btrfs)/' /etc/mkinitcpio.conf
sed -i 's%^BINARIES=.*%BINARIES=(/usr/bin/btrfs)%' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect modconf kms keyboard sd-vconsole block sd-encrypt btrfs filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

log "Installing GRUB (UEFI) and enabling grub-btrfs"
pacman -S --noconfirm --needed grub efibootmgr grub-btrfs inotify-tools || true

# Ensure kernel cmdline matches our LUKS+Btrfs layout
sed -i \'s/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="rd.luks.name=${UUID_ROOT}=root rd.luks.options=discard root=\\/dev\\/mapper\\/root rootflags=subvol=@,compress=zstd rw nvidia-drm.modeset=1"/\' /etc/default/grub || true
grep -q "^GRUB_CMDLINE_LINUX=" /etc/default/grub || echo 'GRUB_CMDLINE_LINUX="rd.luks.name=${UUID_ROOT}=root rd.luks.options=discard root=/dev/mapper/root rootflags=subvol=@,compress=zstd rw nvidia-drm.modeset=1"' >> /etc/default/grub

# Optional but harmless with ESP-mounted /boot
grep -q "^GRUB_ENABLE_CRYPTODISK=" /etc/default/grub || echo 'GRUB_ENABLE_CRYPTODISK=y' >> /etc/default/grub

# Install GRUB to the EFI System Partition and generate config
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# Enable grub-btrfs daemon to auto-add snapshot boot entries
systemctl enable --now grub-btrfsd.service || true

log "Writing /etc/crypttab for HOME"
cat >/etc/crypttab <<EOF
home    UUID=\${UUID_HOME}    none    luks,discard
EOF
chmod 0600 /etc/crypttab

log "Enabling NetworkManager & fstrim.timer via wanted symlinks"
mkdir -p /etc/systemd/system/multi-user.target.wants /etc/systemd/system/timers.target.wants
ln -sf /usr/lib/systemd/system/NetworkManager.service /etc/systemd/system/multi-user.target.wants/NetworkManager.service
ln -sf /usr/lib/systemd/system/fstrim.timer        /etc/systemd/system/timers.target.wants/fstrim.timer

log "Writing zram-generator config (ram/2, zstd)"
install -Dm644 /dev/stdin /etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
EOF

systemctl disable --now systemd-swap.service 2>/dev/null || true

log "Configuring Snapper (idempotent; no baseline snapshots here)"
install -d /etc/snapper/configs

_ensure_sn_configs() {
  local f=/etc/conf.d/snapper
  if [[ ! -f "\$f" ]]; then
    install -Dm644 /dev/stdin "\$f" <<< 'SNAPPER_CONFIGS=""'
  fi
  local cur
  cur="\$(sed -n -E 's/^SNAPPER_CONFIGS="(.*)"/\1/p' "\$f")"
  local combined
  combined="\${cur:+\$cur }\$*"
  local arr=(\$(printf '%s\n' \$combined | sed '/^$/d' | awk '!x[\$0]++'))
  local new; new="\$(printf '%s ' "\${arr[@]}" | sed 's/ \$//')"
  if grep -qE '^SNAPPER_CONFIGS=' "\$f"; then
    sed -i -E "s|^SNAPPER_CONFIGS=.*\$|SNAPPER_CONFIGS=\"\${new}\"|" "\$f"
  else
    printf 'SNAPPER_CONFIGS="%s"\n' "\${new}" >> "\$f"
  fi
}

_make_cfg() {
  local cfgname="\${1:?_make_cfg: missing config name (expected: root|home)}"
  local mp="\${2:?_make_cfg: missing mountpoint (expected: / or /home)}"
  local cfg="/etc/snapper/configs/\${cfgname}"
  install -Dm600 /dev/stdin "\$cfg" <<EOF
FSTYPE="btrfs"
SUBVOLUME="\${mp}"
ALLOW_GROUPS="wheel"
SYNC_ACL="yes"
TIMELINE_CREATE="yes"
NUMBER_CLEANUP="yes"
EOF
  _ensure_sn_configs "\$cfgname"
}

if btrfs subvolume show /.snapshots &>/dev/null; then
  log "Snapper: /.snapshots exists -> writing /etc/snapper/configs/root manually"
  _make_cfg root /
else
  log "Snapper: creating config via snapper create-config (root)"
  snapper --no-dbus -c root create-config /
fi

if mountpoint -q /home && btrfs subvolume show /home/.snapshots &>/dev/null; then
  log "Snapper: /home/.snapshots exists -> writing /etc/snapper/configs/home manually"
  _make_cfg home /home
else
  log "Snapper: trying create-config for /home (safe to skip if not a separate subvolume)"
  snapper --no-dbus -c home create-config /home 2>/dev/null || true
fi

chmod 750 /.snapshots          2>/dev/null || true
chmod 750 /home/.snapshots     2>/dev/null || true

mkdir -p /etc/systemd/system/timers.target.wants
ln -sf /usr/lib/systemd/system/snapper-timeline.timer /etc/systemd/system/timers.target.wants/snapper-timeline.timer
ln -sf /usr/lib/systemd/system/snapper-cleanup.timer  /etc/systemd/system/timers.target.wants/snapper-cleanup.timer

install -d -m 0700 -o "\${USERNAME}" -g "\${USERNAME}" /home/\${USERNAME}/.config/hypr
install -d -m 0700 -o "\${USERNAME}" -g "\${USERNAME}" /home/\${USERNAME}/.config/wezterm

if curl -fsSL "${HYPRLAND_URL}" \
   -o /home/\${USERNAME}/.config/hypr/hyprland.conf; then
  chown \${USERNAME}:\${USERNAME} /home/\${USERNAME}/.config/hypr/hyprland.conf
else
  cat >/home/\${USERNAME}/.config/hypr/hyprland.conf <<'EOF'
monitor = ,preferred,auto,auto
\$terminal = wezterm
bind = SUPER, Return, exec, \$terminal
exec-once = firefox
EOF
  chown \${USERNAME}:\${USERNAME} /home/\${USERNAME}/.config/hypr/hyprland.conf
fi

if curl -fsSL "${WEZTERM_URL}" \
   -o /home/\${USERNAME}/.config/wezterm/wezterm.lua; then
  chown \${USERNAME}:\${USERNAME} /home/\${USERNAME}/.config/wezterm/wezterm.lua
else
  cat >/home/\${USERNAME}/.config/wezterm/wezterm.lua <<'EOF'
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
  chown \${USERNAME}:\${USERNAME} /home/\${USERNAME}/.config/wezterm/wezterm.lua
fi

cat >/home/\${USERNAME}/.zprofile <<'EOF'
if [ "\$(tty)" = "/dev/tty1" ]; then
  exec dbus-run-session Hyprland
fi
EOF
chown \${USERNAME}:\${USERNAME} /home/\${USERNAME}/.zprofile
chmod 0644 /home/\${USERNAME}/.zprofile

chmod 0644 /etc/mkinitcpio.conf /etc/default/grub /boot/grub/grub.cfg
chmod 0600 /etc/crypttab

log "chroot_setup.sh finished."
CHROOT
  chmod +x /mnt/root/chroot_setup.sh
}

# ──────────────────────────────────────────────────────────────────[...]
trap 'ret=$?; cleanup_partial; if [[ $ret -ne 0 ]]; then log "Exited with $ret"; fi; exit $ret' EXIT

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

  log "Partitioning ${DISK} (GPT: 1=ESP, 2=LUKS root, 3=LUKS home; leave free tail for VeraCrypt)"
  sgdisk --zap-all "$DISK"
  sgdisk --clear    "$DISK"
  sgdisk -n 1:0:+${ESP_SIZE_G}  -t 1:ef00 "$DISK"
  sgdisk -n 2:0:+${ROOT_SIZE_G} -t 2:8309 "$DISK"
  sgdisk -n 3:0:+${HOME_SIZE_G} -t 3:8309 "$DISK"
  sgdisk -p "$DISK"
  partprobe "$DISK" || true
  sleep 1

  ESP="$(partition "$DISK" 1)"
  P2="$(partition "$DISK" 2)"
  P3="$(partition "$DISK" 3)"

  # Получаем UUID для root и home и передаём их в chroot
  UUID_ROOT="$(blkid -s UUID -o value "$P2" || true)"
  UUID_HOME="$(blkid -s UUID -o value "$P3" || true)"

  log "Initializing LUKS2 on ${P2} (root) and ${P3} (home)"
  cryptsetup luksFormat --type luks2 --pbkdf argon2id --iter-time 5000 "$P2"
  until cryptsetup open "$P2" root; do echo "Wrong passphrase for root. Try again."; done

  cryptsetup luksFormat --type luks2 --pbkdf argon2id --iter-time 5000 "$P3"
  until cryptsetup open "$P3" home; do echo "Wrong passphrase for home. Try again."; done

  log "Formatting filesystems"
  mkfs.fat -F32 "$ESP"
  mkfs.btrfs /dev/mapper/root
  mkfs.btrfs /dev/mapper/home

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

  log "Mounting with: ${BTRFS_OPTS}"
  mount -o "${BTRFS_OPTS},subvol=@" /dev/mapper/root /mnt
  mkdir -p /mnt/.snapshots /mnt/var/log /mnt/var/tmp /mnt/var/cache/pacman/pkg /mnt/home
  mount -o "${BTRFS_OPTS},subvol=@snapshots" /dev/mapper/root /mnt/.snapshots
  mount -o "${BTRFS_OPTS},subvol=@var_log"   /dev/mapper/root /mnt/var/log
  mount -o "${BTRFS_OPTS},subvol=@var_tmp"   /dev/mapper/root /mnt/var/tmp
  mount -o "${BTRFS_OPTS},subvol=@pkg"       /dev/mapper/root /mnt/var/cache/pacman/pkg

  mount -o "${BTRFS_OPTS},subvol=@home"           /dev/mapper/home /mnt/home
  mkdir -p /mnt/home/.snapshots
  mount -o "${BTRFS_OPTS},subvol=@home.snapshots" /dev/mapper/home /mnt/home/.snapshots

  mkdir -p /mnt/boot
  mount "$ESP" /mnt/boot

  log "Pacstrapping base system"
  pacstrap /mnt "${PACSTRAP_PKGS[@]}"

  log "Generating fstab"
  genfstab -U /mnt > /mnt/etc/fstab

  create_chroot_script "$UUID_ROOT" "$UUID_HOME"
  log "Running arch-chroot setup"
  arch-chroot /mnt /root/chroot_setup.sh

  log "Installation finished."
  echo
  echo "Do you want to reboot into the installed system now?"
  read -r -p 'Type "YES" to unmount, close LUKS, and reboot (anything else to leave mounted): ' ans
  if [[ $ans == YES ]]; then
    umount -R /mnt || true
    swapoff -a 2>/dev/null || true
    for m in home root; do
      [[ -e /dev/mapper/$m ]] && cryptsetup close "$m" || true
    done
    reboot
  else
    log "Left mounted at /mnt for manual inspection."
  fi
}

main "$@"
  grub \
  efibootmgr \
  grub-btrfs \
  inotify-tools \