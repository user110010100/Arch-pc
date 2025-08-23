#!/usr/bin/env bash
# Arch Linux (Btrfs + LUKS), minimal install + Hyprland + ZRAM + Snapper
# Prompts are in English to avoid TTY charset issues on the live ISO.

set -Eeuo pipefail
IFS=$'\n\t'

# ----------------------------- USER SETTINGS ----------------------------------
DEFAULT_DISK="/dev/sda"
ESP_SIZE_G="1G"
ROOT_SIZE_G="120G"
HOME_SIZE_G="250G"
HOSTNAME="arch-pc"
USERNAME="user404"
USER_SHELL="/usr/bin/zsh"
TIMEZONE="Europe/Amsterdam"

# Mount opts influence what genfstab writes into /etc/fstab
BTRFS_OPTS="noatime,compress=zstd:3,ssd,space_cache=v2"

# Base + tools (added: curl, dbus, fontconfig for fc-cache)
PACSTRAP_PKGS=(base linux linux-firmware btrfs-progs intel-ucode git nano networkmanager curl dbus fontconfig)

# Hyprland config URL (your GitHub)
HYPRLAND_CONF_URL="https://raw.githubusercontent.com/user110010100/Arch-pc/refs/heads/main/hyprland.conf"

log(){ printf '%s %s\n' "$(date -Is)" "$*"; }
fail(){ log "ERROR: $*" >&2; exit 1; }
require_root(){ [[ $EUID -eq 0 ]] || fail "Run as root."; }

confirm(){
  local msg="$1" ans
  printf '\n%s\n' "$msg"
  read -r -p 'Type "YES" to continue: ' ans
  [[ $ans == YES ]] || fail "Aborted by user."
}

cleanup_partial(){
  log "Cleaning possible previous mounts/mappings..."
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
  command -v "$cmd" >/dev/null 2>&1 || { log "Installing $pkg for missing command $cmd"; pacman -Sy --noconfirm --needed "$pkg"; }
}

# ------------------------- CHROOT SCRIPT GENERATOR -----------------------------
create_chroot_script(){
  cat > /mnt/root/chroot_setup.sh <<'CHROOT'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
log(){ printf '%s %s\n' "$(date -Is)" "$*"; }

# Read vars supplied by the outer script
source /root/install-vars

# --- Base system setup ---
log "Timezone, locales, console"
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc || true

# Enable locales
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

log "Install desktop stack (Hyprland) & tooling"
pacman -Syu --noconfirm --needed \
  zsh zsh-completions sudo cryptsetup mkinitcpio \
  nvidia nvidia-utils nvidia-settings \
  hyprland xorg-xwayland qt6-wayland egl-wayland \
  xdg-desktop-portal xdg-desktop-portal-hyprland \
  firefox wezterm \
  zram-generator snapper \
  ttf-nerd-fonts-symbols-mono noto-fonts noto-fonts-emoji ttf-dejavu

# Rebuild font cache so GUI apps (wezterm) see fonts immediately
fc-cache -f

# User + sudo
if ! id -u "${USERNAME}" >/dev/null 2>&1; then
  useradd -m -G wheel -s "${USER_SHELL}" "${USERNAME}"
fi
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

echo "Set password for root:"
passwd
echo "Set password for ${USERNAME}:"
passwd "${USERNAME}"

# --- NVIDIA KMS + mkinitcpio ---
log "Configure NVIDIA KMS and mkinitcpio (systemd hooks + btrfs + kms)"
mkdir -p /etc/modprobe.d
cat >/etc/modprobe.d/nvidia.conf <<'EOF'
options nvidia-drm modeset=1
EOF

sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_drm nvidia_modeset btrfs)/' /etc/mkinitcpio.conf
sed -i 's%^BINARIES=.*%BINARIES=(/usr/bin/btrfs)%' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect modconf kms keyboard sd-vconsole block sd-encrypt btrfs filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# --- systemd-boot ---
log "Install systemd-boot and write loader entries"
bootctl install

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
options rd.luks.name=${UUID_ROOT_PART}=root rd.luks.options=discard root=/dev/mapper/root rootflags=subvol=@,compress=zstd:3 rw nvidia-drm.modeset=1
EOF

# --- crypttab for HOME (LUKS TRIM) ---
log "Write /etc/crypttab for HOME"
cat >/etc/crypttab <<EOF
home    UUID=${UUID_HOME_PART}    none    luks,discard
EOF
chmod 0600 /etc/crypttab

# Enable NetworkManager and fstrim.timer via wants-symlink (no systemctl in chroot)
log "Enable NetworkManager and fstrim.timer (via wants symlinks)"
mkdir -p /etc/systemd/system/multi-user.target.wants /etc/systemd/system/timers.target.wants
ln -sf /usr/lib/systemd/system/NetworkManager.service /etc/systemd/system/multi-user.target.wants/NetworkManager.service
ln -sf /usr/lib/systemd/system/fstrim.timer        /etc/systemd/system/timers.target.wants/fstrim.timer

# --- ZRAM via zram-generator (explicit size; no start in chroot) ---
log "Configure zram-generator"
cat >/etc/systemd/zram-generator.conf <<'EOF'
[zram0]
# Explicit size for maximum compatibility with generator versions
zram-size = 16G
compression-algorithm = zstd
swap-priority = 100
EOF
# If some swap manager is present, disable it (ignore errors if absent)
systemctl disable --now systemd-swap.service 2>/dev/null || true

# --- Snapper (create configs without DBus in chroot) ---
log "Create Snapper configs via --no-dbus"
install -d /.snapshots /home/.snapshots /etc/snapper/configs

# Tie configs to actual mountpoints
snapper --no-dbus -c root create-config /
snapper --no-dbus -c home create-config /home

# Align with minimal policy
sed -i 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="no"/' /etc/snapper/configs/root
sed -i 's/^NUMBER_CLEANUP=.*/NUMBER_CLEANUP="no"/'     /etc/snapper/configs/root
sed -i 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="no"/' /etc/snapper/configs/home
sed -i 's/^NUMBER_CLEANUP=.*/NUMBER_CLEANUP="no"/'   /etc/snapper/configs/home

# Make timers (if enabled later) aware of our configs
if [[ -f /etc/conf.d/snapper ]]; then
  sed -i 's/^SNAPPER_CONFIGS=.*/SNAPPER_CONFIGS="root home"/' /etc/conf.d/snapper
else
  echo 'SNAPPER_CONFIGS="root home"' >/etc/conf.d/snapper
fi

log "Create oneshot service for baseline snapshots on first boot (no DBus)"
cat >/etc/systemd/system/firstboot-snapper.service <<'EOF'
[Unit]
Description=Create initial Snapper snapshots (one-time)
After=local-fs.target
ConditionPathExists=/etc/snapper/configs/root

[Service]
Type=oneshot
ExecStart=/usr/bin/snapper --no-dbus -c root create --description "baseline-0"
ExecStart=/usr/bin/snapper --no-dbus -c home create --description "baseline-0-home"
ExecStartPost=/usr/bin/systemctl disable --now firstboot-snapper.service

[Install]
WantedBy=multi-user.target
EOF
ln -sf /etc/systemd/system/firstboot-snapper.service /etc/systemd/system/multi-user.target.wants/firstboot-snapper.service

# --- Hyprland: create dirs and download your config ---
log "Hyprland: create directories and download your config"
install -d -m 0700 -o "${USERNAME}" -g "${USERNAME}" "/home/${USERNAME}/.config/hypr"
install -d -m 0700 -o "${USERNAME}" -g "${USERNAME}" "/home/${USERNAME}/.config/wezterm"

if curl -fsSL "${HYPRLAND_CONF_URL}" -o "/home/${USERNAME}/.config/hypr/hyprland.conf"; then
  chown "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.config/hypr/hyprland.conf"
else
  # Fallback minimal config if download fails
  cat >"/home/${USERNAME}/.config/hypr/hyprland.conf" <<'EOF'
monitor = ,preferred,auto,auto
$terminal = wezterm
bind = SUPER, Return, exec, $terminal
exec-once = firefox
EOF
  chown "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.config/hypr/hyprland.conf"
fi

# WezTerm config (fallback chain covers ascii/nerd/emoji)
cat >"/home/${USERNAME}/.config/wezterm/wezterm.lua" <<'EOF'
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
chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.config/wezterm"

# Autostart Hyprland on tty1 only
cat >"/home/${USERNAME}/.zprofile" <<'EOF'
if [ "$(tty)" = "/dev/tty1" ]; then
  exec dbus-run-session Hyprland
fi
EOF
chown "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.zprofile"
chmod 0644 "/home/${USERNAME}/.zprofile"

# Permissions hygiene
chmod 0644 /etc/mkinitcpio.conf /boot/loader/loader.conf /boot/loader/entries/arch.conf
chmod 0600 /etc/crypttab

log "chroot_setup.sh finished."
CHROOT
  chmod +x /mnt/root/chroot_setup.sh
}

# ------------------------------ MAIN FLOW --------------------------------------
main(){
  require_root
  log "Starting minimal Arch install (Hyprland + ZRAM + Snapper)"
  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE

  read -r -p "Default disk is ${DEFAULT_DISK}. Enter another disk path or press Enter: " DISK
  DISK="${DISK:-$DEFAULT_DISK}"
  [[ -b $DISK ]] || fail "Block device $DISK not found."

  cleanup_partial
  confirm "DANGER: Partitions 1..3 on $DISK will be created/destroyed. Continue?"

  need sgdisk gptfdisk

  # --- Partitioning (GPT) ---
  log "Partitioning $DISK (ESP / root-LUKS / home-LUKS; leaving the rest free)"
  sgdisk --zap-all "$DISK"
  sgdisk --clear    "$DISK"
  sgdisk -n 1:0:+${ESP_SIZE_G}  -t 1:ef00 "$DISK"   # EFI System
  sgdisk -n 2:0:+${ROOT_SIZE_G} -t 2:8309 "$DISK"   # Linux LUKS
  sgdisk -n 3:0:+${HOME_SIZE_G} -t 3:8309 "$DISK"   # Linux LUKS
  sgdisk -p "$DISK"
  partprobe "$DISK" || true
  sleep 1
  ESP="${DISK}1"; P2="${DISK}2"; P3="${DISK}3"

  # --- LUKS2 + filesystems ---
  log "Initialize LUKS2 for root ($P2) and home ($P3)"
  cryptsetup luksFormat --type luks2 --pbkdf argon2id --iter-time 5000 "$P2"
  until cryptsetup open "$P2" root; do echo "Wrong LUKS password for root. Try again."; done

  cryptsetup luksFormat --type luks2 --pbkdf argon2id --iter-time 5000 "$P3"
  until cryptsetup open "$P3" home; do echo "Wrong LUKS password for home. Try again."; done

  log "Format ESP (FAT32) and Btrfs for root/home"
  need mkfs.fat dosfstools
  mkfs.fat -F32 "$ESP"
  mkfs.btrfs /dev/mapper/root
  mkfs.btrfs /dev/mapper/home

  # --- Btrfs subvolumes ---
  log "Create Btrfs subvolumes"
  # ROOT
  mount /dev/mapper/root /mnt
  btrfs subvolume create /mnt/@
  btrfs subvolume create /mnt/@snapshots
  btrfs subvolume create /mnt/@var_log
  btrfs subvolume create /mnt/@var_tmp
  btrfs subvolume create /mnt/@pkg
  umount /mnt
  # HOME
  mount /dev/mapper/home /mnt
  btrfs subvolume create /mnt/@home
  btrfs subvolume create /mnt/@home.snapshots
  umount /mnt

  # --- Mounting ---
  log "Mount subvolumes"
  mount -o ${BTRFS_OPTS},subvol=@ /dev/mapper/root /mnt
  mkdir -p /mnt/.snapshots /mnt/var/log /mnt/var/tmp /mnt/var/cache/pacman/pkg /mnt/home
  mount -o ${BTRFS_OPTS},subvol=@snapshots /dev/mapper/root /mnt/.snapshots
  mount -o ${BTRFS_OPTS},subvol=@var_log   /dev/mapper/root /mnt/var/log
  mount -o ${BTRFS_OPTS},subvol=@var_tmp   /dev/mapper/root /mnt/var/tmp
  mount -o ${BTRFS_OPTS},subvol=@pkg       /dev/mapper/root /mnt/var/cache/pacman/pkg

  mount -o ${BTRFS_OPTS},subvol=@home            /dev/mapper/home /mnt/home
  mkdir -p /mnt/home/.snapshots
  mount -o ${BTRFS_OPTS},subvol=@home.snapshots  /dev/mapper/home /mnt/home/.snapshots

  mkdir -p /mnt/boot
  mount "$ESP" /mnt/boot

  # --- Base system ---
  log "Install base system (pacstrap)"
  pacstrap /mnt "${PACSTRAP_PKGS[@]}"

  log "Generate fstab"
  genfstab -U /mnt >> /mnt/etc/fstab

  # --- Pass variables to chroot ---
  UUID_ROOT_PART=$(blkid -s UUID -o value "$P2")
  UUID_HOME_PART=$(blkid -s UUID -o value "$P3")
  cat > /mnt/root/install-vars <<EOF
HOSTNAME="${HOSTNAME}"
USERNAME="${USERNAME}"
USER_SHELL="${USER_SHELL}"
TIMEZONE="${TIMEZONE}"
UUID_ROOT_PART="${UUID_ROOT_PART}"
UUID_HOME_PART="${UUID_HOME_PART}"
HYPRLAND_CONF_URL="${HYPRLAND_CONF_URL}"
EOF

  # --- Chroot phase ---
  create_chroot_script
  log "Run arch-chroot"
  arch-chroot /mnt /root/chroot_setup.sh

  # --- Final prompt ---
  log "Installation finished."
  echo
  echo "Reboot into the installed system now?"
  read -r -p 'Type YES to unmount /mnt, close LUKS mappings and reboot: ' ans
  if [[ $ans == YES ]]; then
    sync
    umount -R /mnt || true
    swapoff -a 2>/dev/null || true
    for m in root home; do
      [[ -e /dev/mapper/$m ]] && cryptsetup close "$m" || true
    done
    reboot
  else
    log "System remains mounted at /mnt for manual inspection."
  fi
}

main "$@"
