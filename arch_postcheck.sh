#!/usr/bin/env zsh
# Проверка установки: ZRAM, Snapper, WezTerm (+шрифты)
# Запуск: zsh arch_postcheck.zsh

# --- zsh guard ---
if [[ -z "${ZSH_VERSION:-}" ]]; then exec zsh "$0" "$@"; fi
set -u  # жёсткий режим на неинициализированные переменные (но без -e, чтобы не обрывать отчёт)

have() { command -v "$1" >/dev/null 2>&1; }

section() { echo; echo "== $1"; }
kv()      { printf '%-28s %s\n' "$1" "$2"; }
pass()    { printf '[PASS] %s\n' "$1"; }
warn()    { printf '[WARN] %s\n' "$1"; }
fail()    { printf '[FAIL] %s\n' "$1"; }

# ---------------------------
section "System"
kv "Kernel"    "$(uname -r)"
kv "Hostname"  "$(hostnamectl --static 2>/dev/null || cat /etc/hostname 2>/dev/null || uname -n)"
kv "Shell"     "$SHELL"

# ---------------------------
section "ZRAM"
if [[ -f /etc/systemd/zram-generator.conf ]]; then
  pass "Found /etc/systemd/zram-generator.conf"
  sed -n '1,80p' /etc/systemd/zram-generator.conf
else
  fail "Missing /etc/systemd/zram-generator.conf"
fi

if have zramctl; then
  echo; kv "zramctl" "present"; zramctl
else
  warn "zramctl not found (util-linux)."
fi

echo
kv "Active swap" ""
swapon --show || true

# Алгоритм и размер
if [[ -e /sys/block/zram0/comp_algorithm ]]; then
  alg="$(cat /sys/block/zram0/comp_algorithm)"
  kv "comp_algorithm" "$alg"
  if echo "$alg" | grep -q '\[zstd\]'; then pass "ZRAM compression is zstd"; else warn "zstd is not active"; fi
fi
ram_kb="$(grep MemTotal /proc/meminfo | awk '{print $2}')"
ram_mib=$(( ram_kb / 1024 ))
want=$(( ram_mib / 2 ))
actual="$(zramctl --bytes 2>/dev/null | awk '/zram0/ {printf "%.0f", $3/1048576}')" || actual=0
kv "RAM total"      "${ram_mib} MiB"
kv "Expected zram"  "${want} MiB"
kv "Actual zram"    "${actual} MiB"
if (( actual > 0 && (actual >= want-64) && (actual <= want+64) )); then pass "zram size ≈ 1/2 RAM"; else warn "zram size differs"; fi

# zswap статус
zswap="N"
[[ -f /sys/module/zswap/parameters/enabled ]] && grep -qi 'y' /sys/module/zswap/parameters/enabled && zswap="Y"
kv "zswap" "$zswap"

# ---------------------------
section "Snapper"
if have snapper; then
  cfgs="$(snapper list-configs 2>/dev/null | awk 'NR>2{print $1}' | paste -sd' ' -)"
  if [[ -n "$cfgs" ]]; then kv "Configs" "$cfgs"; else fail "No snapper configs"; fi

  for cfg in root home; do
    if echo " $cfgs " | grep -q " $cfg "; then
      pass "Snapper config '$cfg' exists"
      snapper -c "$cfg" get-config | egrep '^(ALLOW_GROUPS|FSTYPE|NUMBER_CLEANUP|SUBVOLUME|SYNC_ACL|TIMELINE_CREATE)' || true
      echo
      snapper -c "$cfg" list | tail -n 5 || true
    fi
  done

  # timers
  systemctl is-enabled snapper-timeline.timer >/dev/null 2>&1 && pass "snapper-timeline.timer enabled" || warn "timeline timer not enabled"
  systemctl is-enabled snapper-cleanup.timer  >/dev/null 2>&1 && pass "snapper-cleanup.timer enabled"  || warn "cleanup timer not enabled"

  echo; echo "-- .snapshots mountpoints --"
  findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS /.snapshots 2>/dev/null || true
  findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS /home/.snapshots 2>/dev/null || true
else
  fail "snapper is not installed"
fi

# ---------------------------
section "WezTerm & Fonts"
if have wezterm; then
  kv "wezterm" "$(wezterm --version 2>/dev/null)"
  # Ищем конфиг
  cfg=""
  [[ -f "$HOME/.config/wezterm/wezterm.lua" ]] && cfg="$HOME/.config/wezterm/wezterm.lua"
  [[ -z "$cfg" && -f "$HOME/.wezterm.lua" ]] && cfg="$HOME/.wezterm.lua"
  if [[ -n "$cfg" ]]; then
    pass "WezTerm config: $cfg"
    # простая проверка: есть ли font(...) или font_with_fallback(...)
    if grep -Eq 'font_with_fallback|font\s*\(' "$cfg"; then
      kv "font in config" "present"
    else
      warn "No explicit font in config (falling back to system default)"
    fi
  else
    warn "WezTerm config not found"
  fi

  echo; echo "-- system fonts (wezterm ls-fonts --list-system) --"
  wezterm ls-fonts --list-system >/tmp/_wez_fonts.txt 2>/dev/null || true
  for fam in "FiraCode Nerd Font Mono" "Noto Color Emoji" "Noto Sans" "DejaVu Sans Mono"; do
    if grep -iq -- "$fam" /tmp/_wez_fonts.txt; then pass "$fam FOUND"; else warn "$fam MISSING"; fi
  done

  echo; echo "-- shaping sample --"
  wezterm ls-fonts --text 'AaBbCc 0123 Привет 😺 ' 2>/dev/null || true
else
  warn "wezterm not installed or not in PATH"
fi

# ---------------------------
section "Btrfs (top subvolumes)"
btrfs subvolume list -t / 2>/dev/null | head -n 200 || true

echo; echo "Done."
