#!/usr/bin/env zsh
# Post-install checks for Arch + Hyprland + zram-generator + Snapper + WezTerm
# Read-only diagnostics; prints PASS/FAIL for key fixes.

# --------- tiny ui helpers ----------
autoload -Uz colors; colors
_ok()   { print -P "%F{green}[PASS]%f $*"; }
_warn() { print -P "%F{yellow}[WARN]%f $*"; }
_fail() { print -P "%F{red}[FAIL]%f $*"; }
_info() { print -P "%F{cyan}==%f $*"; }

print -P "%F{blue}Arch post-install validation (zram/snapper/wezterm)%f"
print

# =========================
# 1) CORE SYSTEM FILES
# =========================
_info "/etc/os-release"; cat /etc/os-release
_info "Kernel"; uname -r

_info "/etc/fstab"; sudo sed -n '1,200p' /etc/fstab
_info "bootctl status"; sudo bootctl status --no-pager || _warn "bootctl status returned non-zero"
_info "/boot/loader/loader.conf"; sudo sed -n '1,200p' /boot/loader/loader.conf
_info "/boot/loader/entries (list)"; sudo ls -l /boot/loader/entries
_info "/boot/loader/entries/arch.conf"; sudo sed -n '1,200p' /boot/loader/entries/arch.conf
_info "/etc/crypttab"; sudo sed -n '1,200p' /etc/crypttab
_info "/etc/mkinitcpio.conf"; sudo sed -n '1,200p' /etc/mkinitcpio.conf
_info "/etc/systemd/zram-generator.conf"; sudo sed -n '1,200p' /etc/systemd/zram-generator.conf
_info "/etc/locale.conf"; cat /etc/locale.conf
_info "/etc/vconsole.conf"; cat /etc/vconsole.conf
_info "/etc/hostname"; cat /etc/hostname

_info "NetworkManager enablement/status"
if systemctl is-enabled NetworkManager &>/dev/null; then
  _ok "NetworkManager is enabled"
else
  _fail "NetworkManager is NOT enabled"
fi
systemctl status --no-pager -n 20 NetworkManager || true

_info "Block devices & filesystems"
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,TYPE,UUID

_info "Btrfs subvolumes: /"
sudo btrfs subvolume list -p /
if mount | grep -q " /home "; then
  _info "Btrfs subvolumes: /home"
  sudo btrfs subvolume list -p /home
fi

_info "Installer variables (if present)"
sudo sed -n '1,200p' /root/install-vars 2>/dev/null || print "No /root/install-vars"

# Consistency: compress=zstd:3 in both fstab and arch.conf
typeset fstab_ok arch_ok
fstab_ok=$(grep -E 'compress=zstd:3' /etc/fstab | wc -l)
arch_ok=$(grep -E 'rootflags=.*compress=zstd:3' /boot/loader/entries/arch.conf | wc -l)
(( fstab_ok > 0 )) && _ok "fstab uses compress=zstd:3" || _warn "fstab does not show compress=zstd:3"
(( arch_ok  > 0 )) && _ok "arch.conf uses compress=zstd:3" || _warn "arch.conf does not show compress=zstd:3"

print

# =================================
# 2) SNAPPER: CONFIGS & SNAPSHOTS
# =================================
_info "Snapper configs directory"; sudo ls -l /etc/snapper/configs/ || _fail "/etc/snapper/configs/ is missing"

if [[ -f /etc/snapper/configs/root && -f /etc/snapper/configs/home ]]; then
  _ok "Snapper configs found: root & home"
else
  _fail "Snapper configs missing (root/home)"
fi

_info "snapper list-configs"
sudo snapper list-configs || _warn "snapper list-configs returned non-zero"

_info "snapper -c root list"
if sudo snapper -c root list; then
  if sudo snapper -c root list | grep -q "baseline-0"; then
    _ok "root baseline snapshot exists"
  else
    _warn "root baseline snapshot not found (service may not have run yet)"
  fi
else
  _fail "snapper root config not usable"
fi

_info "snapper -c home list"
if sudo snapper -c home list; then
  if sudo snapper -c home list | grep -q "baseline-0-home"; then
    _ok "home baseline snapshot exists"
  else
    _warn "home baseline snapshot not found (service may not have run yet)"
  fi
else
  _fail "snapper home config not usable"
fi

_info "firstboot-snapper.service status (should be disabled after running once)"
if systemctl is-enabled firstboot-snapper.service &>/dev/null; then
  _warn "firstboot-snapper.service is still enabled (expected disabled after one run)"
else
  _ok "firstboot-snapper.service is not enabled (as expected after one run)"
fi
systemctl status --no-pager firstboot-snapper.service || true
_info "firstboot-snapper journal (this boot)"; journalctl -b -u firstboot-snapper.service --no-pager || true

_info "Snapshot dirs"
sudo ls -la /.snapshots
sudo ls -la /home/.snapshots

print

# ================================
# 3) ZRAM: STATE & PARAMETERS
# ================================
_info "zram generator artifacts (should exist at boot)"
ls /run/systemd/generator/*zram* /run/systemd/generator.late/*zram* 2>/dev/null || _warn "no generator artifacts visible (ok if cleaned later)"

_info "dev-zram0.swap unit"
if systemctl is-active --quiet dev-zram0.swap; then
  _ok "dev-zram0.swap is active"
else
  systemctl status --no-pager dev-zram0.swap || true
  _fail "dev-zram0.swap is NOT active"
fi

_info "systemd-zram-setup@zram0.service journal (this boot)"
journalctl -b -u systemd-zram-setup@zram0.service --no-pager || true

_info "Active swaps (expect /dev/zram0)"
swapon --show --bytes
if swapon --show | grep -q "/dev/zram0"; then
  _ok "zram0 is active swap"
else
  _fail "zram0 not found in /proc/swaps"
fi

_info "zramctl details"; sudo zramctl || _warn "zramctl returned non-zero"
if [[ -r /sys/block/zram0/comp_algorithm ]]; then
  _ok "comp_algorithm: $(< /sys/block/zram0/comp_algorithm)"
else
  _warn "/sys/block/zram0/comp_algorithm not present"
fi
if [[ -r /sys/block/zram0/disksize ]]; then
  _ok "disksize: $(< /sys/block/zram0/disksize)"
fi
print

# ==============================================
# 4) FONTS & WEZTERM
# ==============================================
_info "Fontconfig defaults (fallback)"
print "monospace -> $(fc-match monospace)"
print "sans      -> $(fc-match sans)"
print "serif     -> $(fc-match serif)"

_info "Check presence of key fonts (Noto/DejaVu/Nerd Symbols)"
fc-list | grep -Ei '(Noto|DejaVu|Symbols Nerd)' | sort | uniq | head -n 50

# Verify wezterm binary and version
if command -v wezterm >/dev/null 2>&1; then
  _ok "wezterm in PATH: $(wezterm --version 2>/dev/null)"
else
  _fail "wezterm not found in PATH"
fi

# Local config presence
WEZ_LOCAL="$HOME/.config/wezterm/wezterm.lua"
_info "WezTerm config (local)"; ls -l -- $WEZ_LOCAL 2>/dev/null || _fail "No $WEZ_LOCAL"
[[ -r $WEZ_LOCAL ]] && sed -n '1,120p' -- $WEZ_LOCAL

# Compare local wezterm.lua with remote (download to tmp; read-only)
REMOTE_URL="https://raw.githubusercontent.com/user110010100/Arch-pc/refs/heads/main/wezterm.lua"
if command -v curl >/dev/null 2>&1; then
  _info "Comparing local wezterm.lua with remote (hash only)"
  tmpf="$(mktemp)"
  if curl -fsSL "$REMOTE_URL" -o "$tmpf"; then
    local_hash=$(sha256sum -- "$WEZ_LOCAL" 2>/dev/null | awk '{print $1}')
    remote_hash=$(sha256sum -- "$tmpf" | awk '{print $1}')
    if [[ -n "$local_hash" && "$local_hash" == "$remote_hash" ]]; then
      _ok "wezterm.lua matches remote (sha256: $local_hash)"
    else
      _warn "wezterm.lua differs from remote (local: $local_hash vs remote: $remote_hash)"
    fi
  else
    _warn "cannot fetch remote wezterm.lua for comparison"
  fi
  rm -f -- "$tmpf"
else
  _warn "curl not available; skipping remote wezterm.lua comparison"
fi

# WezTerm font visibility (if wezterm is available)
if command -v wezterm >/dev/null 2>&1; then
  _info "WezTerm sees system fonts (first 50 lines)"
  wezterm ls-fonts --list-system --no-colors | head -n 50 || _warn "wezterm ls-fonts returned non-zero"

  _info "WezTerm glyph coverage sample"
  wezterm ls-fonts --text "→ Hello Привет 😀" --no-colors | head -n 50 || true

  # Grep for our expected fonts in the wezterm-visible list
  if wezterm ls-fonts --list-system --no-colors | grep -qi 'DejaVu Sans Mono'; then
    _ok "WezTerm sees DejaVu Sans Mono"
  else
    _warn "WezTerm does NOT list DejaVu Sans Mono"
  fi
  if wezterm ls-fonts --list-system --no-colors | grep -qi 'Symbols Nerd'; then
    _ok "WezTerm sees Symbols Nerd Font"
  else
    _warn "WezTerm does NOT list Symbols Nerd Font"
  fi
  if wezterm ls-fonts --list-system --no-colors | grep -qi 'Noto Color Emoji'; then
    _ok "WezTerm sees Noto Color Emoji"
  else
    _warn "WezTerm does NOT list Noto Color Emoji"
  fi
fi
print

# =====================================================
# 5) INSTALLER LOGS (IF ANY)
# =====================================================
_info "Try to print any installer logs if present"
for f in /root/arch_install.log /var/log/arch_install.log /root/install.log ; do
  if [[ -s "$f" ]]; then
    print -- "-- $f --"
    sudo sed -n '1,200p' -- "$f"
  fi
done

_info "chroot_setup.sh saved by installer (for reference)"
sudo sed -n '1,120p' /root/chroot_setup.sh 2>/dev/null || print "No /root/chroot_setup.sh"

# (Optional) NVIDIA check
_info "NVIDIA modules & tools (optional)"
lsmod | grep -i nvidia || true
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi || true
else
  print "nvidia-smi not available/runlevel not graphical"
fi

print
_ok "Checks finished."
