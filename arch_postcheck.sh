#!/usr/bin/env zsh
# Post-install verification for Arch + Hyprland + zram-generator + Snapper + WezTerm
# Read-only checks. Prints PASS/WARN/FAIL and writes a log to ~/arch_check.log

set -o pipefail
set -u

# ---------- tiny UI helpers ----------
autoload -Uz colors; colors
_ok()   { print -P "%F{green}[PASS]%f $*"; }
_warn() { print -P "%F{yellow}[WARN]%f $*"; }
_fail() { print -P "%F{red}[FAIL]%f $*"; }
_info() { print -P "%F{cyan}==%f $*"; }

LOG_FILE="${HOME}/arch_check.log"
: > "${LOG_FILE}"
exec > >(tee -a "${LOG_FILE}") 2>&1

print -P "%F{blue}Arch post-install validation (zram, snapper, fonts, wezterm)%f"
print

# =====================================================
# 0) BASIC CONTEXT
# =====================================================
_info "System context"
print "Kernel:       $(uname -r)"
print "Hostname:     $(hostname)"
print "User:         ${USER}"
print "Shell:        ${SHELL}"
print

# =====================================================
# 1) ZRAM (via systemd zram-generator)
#    Задачи:
#    - Проверить наличие /etc/systemd/zram-generator.conf
#    - Убедиться, что /dev/zram0 создан, swap активен
#    - Алгоритм сжатия = zstd
#    - Размер zram = 1/2 RAM (+/- 5%)
#    - Подсветить, если включен zswap (не критично, но полезно знать)
# =====================================================
_info "ZRAM status"
if [[ -r /etc/systemd/zram-generator.conf ]]; then
  _ok "Found /etc/systemd/zram-generator.conf"
  print "--- zram-generator.conf ---"
  sed -n '1,120p' /etc/systemd/zram-generator.conf
else
  _warn "No /etc/systemd/zram-generator.conf"
fi
print

# Показать статусы сервисов и swap; это только диагностика
if systemctl status dev-zram0.swap >/dev/null 2>&1; then
  _ok "dev-zram0.swap unit exists"
else
  _warn "dev-zram0.swap unit not present"
fi

if systemctl status systemd-zram-setup@zram0.service >/dev/null 2>&1; then
  _ok "systemd-zram-setup@zram0.service reachable"
else
  _warn "systemd-zram-setup@zram0.service not found"
fi

print
zramctl || true
print
swapon --show --bytes || true
print

# Проверка: алгоритм = zstd (в /sys/block/zram0/comp_algorithm текущий отмечен [квадратными])
if [[ -r /sys/block/zram0/comp_algorithm ]]; then
  comp_line="$(< /sys/block/zram0/comp_algorithm)"
  print "comp_algorithm: ${comp_line}"
  if print -- "${comp_line}" | grep -q '\[zstd\]'; then
    _ok "ZRAM compression is zstd"
  else
    _fail "ZRAM compression is NOT zstd"
  fi
else
  _warn "No /sys/block/zram0/comp_algorithm (zram0 may be absent)"
fi

# Проверка: размер zram0 ~ 1/2 RAM (+/- 5%)
if command -v zramctl >/dev/null 2>&1 && [[ -e /dev/zram0 ]]; then
  # Получаем MemTotal в KiB
  mem_kib=$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)
  if [[ -n "${mem_kib:-}" ]]; then
    # Ожидаемый размер в байтах = 1/2 RAM
    expected_bytes=$(( mem_kib * 1024 / 2 ))
    # Фактический размер zram0 (в байтах; ключ -b выдаёт байты)
    actual_bytes=$(zramctl -b 2>/dev/null | awk '$1 ~ /zram0/ {print $3; exit}')
    if [[ -n "${actual_bytes:-}" ]]; then
      # Допустимое отклонение = 5%
      low=$(( expected_bytes * 95 / 100 ))
      high=$(( expected_bytes * 105 / 100 ))
      print "RAM total:      $((mem_kib / 1024)) MiB"
      print "Expected zram:  $((expected_bytes / 1024 / 1024)) MiB"
      print "Actual zram:    $((actual_bytes / 1024 / 1024)) MiB"
      if (( actual_bytes >= low && actual_bytes <= high )); then
        _ok "zram size ≈ 1/2 RAM"
      else
        _warn "zram size is outside ±5% of 1/2 RAM"
      fi
    else
      _fail "Cannot read zram0 size"
    fi
  else
    _warn "Cannot read MemTotal from /proc/meminfo"
  fi
else
  _warn "zramctl not available or /dev/zram0 missing"
fi

# Подсветим zswap (для понимания, а не как ошибку)
if [[ -r /sys/module/zswap/parameters/enabled ]]; then
  zswap_state="$(< /sys/module/zswap/parameters/enabled)"
  _info "zswap: ${zswap_state}"
fi
print

# =====================================================
# 2) SNAPPER
#    Задачи:
#    - Есть ли конфиги (root/home) и в SNAPPER_CONFIGS
#    - Снимки читаются (snapper -c root/home list)
#    - Таймеры timeline/cleanup включены
#    - /.snapshots и /home/.snapshots смонтированы отдельными сабвольюмами btrfs
#    - Базовые ключи в конфиге (TIMELINE_CREATE, NUMBER_CLEANUP, SYNC_ACL, ALLOW_GROUPS)
# =====================================================
_info "Snapper status"
if ! command -v snapper >/dev/null 2>&1; then
  _fail "snapper is not installed"
else
  snapper list-configs || true
  print

  # SNAPPER_CONFIGS (Arch)
  if [[ -r /etc/conf.d/snapper ]]; then
    grep -E '^SNAPPER_CONFIGS=' /etc/conf.d/snapper || true
  fi
  print

  for cfg in root home; do
    if snapper -c "$cfg" get-config >/dev/null 2>&1; then
      _ok "Snapper config '$cfg' exists"
      print "--- snapper $cfg get-config ---"
      snapper -c "$cfg" get-config | sed 's/^/  /'
      print "--- latest snapshots ($cfg) ---"
      snapper -c "$cfg" list | tail -n 10 | sed 's/^/  /'
    else
      _warn "Snapper config '$cfg' not found"
    fi
    print
  done

  # Таймеры
  for t in snapper-timeline.timer snapper-cleanup.timer; do
    if systemctl is-enabled "$t" >/dev/null 2>&1; then
      _ok "$t is enabled"
    else
      _warn "$t is NOT enabled"
    fi
  done
  print "== timers overview =="
  systemctl list-timers | grep -E 'snapper-(timeline|cleanup)\.timer' || true
fi
print

# Проверка точек монтирования .snapshots
_info "Check .snapshots mountpoints"
for p in /.snapshots /home/.snapshots; do
  if findmnt -no FSTYPE,SOURCE,OPTIONS "$p" >/dev/null 2>&1; then
    line="$(findmnt -no FSTYPE,SOURCE,OPTIONS "$p")"
    print "$p -> $line"
    if print -- "$line" | grep -q '^btrfs'; then
      _ok "$p is on btrfs (good)"
    else
      _warn "$p is not on btrfs"
    fi
  else
    _warn "Mountpoint $p not found"
  fi
done
print

# =====================================================
# 3) FSTAB sanity for btrfs (quick glance)
#    Задачи:
#    - Убедиться, что корень/снэпшоты используют btrfs и сжатие zstd:* (быстрое подтверждение)
# =====================================================
_info "fstab quick check (btrfs + zstd)"
if [[ -r /etc/fstab ]]; then
  grep -E '^\s*[^#].*\s+btrfs\s' /etc/fstab | sed 's/^/  /' || true
  if grep -E '^\s*[^#].*\s+btrfs\s' /etc/fstab | grep -q 'compress=zstd'; then
    _ok "btrfs entries use zstd compression"
  else
    _warn "No 'compress=zstd' found in btrfs entries"
  fi
else
  _warn "No /etc/fstab"
fi
print

# =====================================================
# 4) FONTS (system via fontconfig) + WEZTERM fonts
#    Задачи:
#    - Показать дефолтные соответствия для generic семейств (sans-serif, monospace, serif)
#    - Показать 5 верхних fallback’ов
#    - Разобрать конфиг wezterm.lua (font()/font_with_fallback{})
#    - Проверить, что семьи из конфига реально установлены
#    - Если доступен 'wezterm', показать, видит ли он эти семьи, и подсветить Noto Color Emoji
# =====================================================
_info "Fontconfig defaults"
if command -v fc-match >/dev/null 2>&1; then
  for fam in "sans-serif" "monospace" "serif"; do
    print "-- fc-match ${fam} --"
    fc-match "${fam}"
    print "-- fallback chain (top 5) for ${fam} --"
    fc-match -s "${fam}" | head -n 5 | sed 's/^/  /'
    print
  done
else
  _warn "fontconfig tools (fc-match) not installed"
fi

# Найдём конфиг WezTerm
_info "WezTerm font settings"
WEZTERM_CFG=""
if [[ -n "${WEZTERM_CONFIG_FILE:-}" && -r "${WEZTERM_CONFIG_FILE}" ]]; then
  WEZTERM_CFG="${WEZTERM_CONFIG_FILE}"
elif [[ -r "${HOME}/.config/wezterm/wezterm.lua" ]]; then
  WEZTERM_CFG="${HOME}/.config/wezterm/wezterm.lua"
elif [[ -r "${HOME}/.wezterm.lua" ]]; then
  WEZTERM_CFG="${HOME}/.wezterm.lua"
fi

if [[ -n "${WEZTERM_CFG}" ]]; then
  _ok "Found WezTerm config: ${WEZTERM_CFG}"
  print "--- snippet (head) ---"
  sed -n '1,120p' "${WEZTERM_CFG}"
  print

  # Извлечём семьи: сначала font_with_fallback{'A','B',...}, затем font("X")
  local -a WZ_FONTS
  WZ_FONTS=()

  # 1) font_with_fallback { 'A', "B", ... }
  #    Извлекаем содержимое фигурных скобок и тянем все строковые литералы
  if grep -qE 'font_with_fallback\s*\{' "${WEZTERM_CFG}"; then
    fonts_raw=$(sed -n 's/.*font_with_fallback\s*{\(.*\)}.*/\1/p' "${WEZTERM_CFG}" | head -n1)
    if [[ -n "${fonts_raw}" ]]; then
      # Вытащим все "..." и '...'
      while read -r name; do
        [[ -n "${name}" ]] && WZ_FONTS+=("${name}")
      done < <(print -- "${fonts_raw}" | grep -oE "'[^']+'|\"[^\"]+\"" | sed "s/^['\"]//; s/['\"]$//")
    fi
  fi

  # 2) Если не нашли fallback — попробуем font("X")
  if [[ ${#WZ_FONTS[@]} -eq 0 ]]; then
    single=$(sed -n 's/.*font\s*(\s*["'\'']\([^"'\'' ]\+\)["'\''].*).*/\1/p' "${WEZTERM_CFG}" | head -n1)
    [[ -n "${single}" ]] && WZ_FONTS+=("${single}")
  fi

  if [[ ${#WZ_FONTS[@]} -gt 0 ]]; then
    _ok "WezTerm configured font(s): ${WZ_FONTS[@]}"
  else
    _warn "No explicit font configured in WezTerm; using default"
  fi

  # Проверим, установлены ли такие семейства в системе (fc-list)
  if command -v fc-list >/dev/null 2>&1 && [[ ${#WZ_FONTS[@]} -gt 0 ]]; then
    for fam in "${WZ_FONTS[@]}"; do
      if fc-list ":family=${fam}" >/dev/null 2>&1 && fc-list ":family=${fam}" | head -n1 | grep -qi .; then
        _ok "Font family '${fam}' is installed (fontconfig can find it)"
      else
        _fail "Font family '${fam}' is NOT installed (fontconfig cannot find it)"
      fi
    done
  fi
else
  _warn "WezTerm config not found"
fi
print

# Если доступен wezterm — проверим видимость семейств и Noto Color Emoji
if command -v wezterm >/dev/null 2>&1; then
  _info "wezterm ls-fonts (system)"
  # Короткая выборка, чтобы не заливать лог
  wezterm ls-fonts --list-system --no-colors | head -n 25 || true

  # Если у нас есть конкретные семьи из конфига — проверим, что wezterm их видит
  if [[ ${#WZ_FONTS[@]:-0} -gt 0 ]]; then
    for fam in "${WZ_FONTS[@]}"; do
      if wezterm ls-fonts --list-system --no-colors | grep -qiE "^\s*family:\s*${fam}\b"; then
        _ok "WezTerm sees family '${fam}'"
      else
        _warn "WezTerm does NOT list family '${fam}'"
      fi
    done
  fi

  # Эмодзи-шрифт
  if fc-list | grep -qi "NotoColorEmoji"; then
    _ok "System has Noto Color Emoji"
  else
    _warn "System does NOT have Noto Color Emoji"
  fi
  if wezterm ls-fonts --list-system --no-colors | grep -qi 'Noto Color Emoji'; then
    _ok "WezTerm sees Noto Color Emoji"
  else
    _warn "WezTerm does NOT list Noto Color Emoji"
  fi
else
  _warn "wezterm CLI not found; skipping wezterm ls-fonts checks"
fi
print

# =====================================================
# 5) OPTIONAL: BTRFS subvol overview (quick)
# =====================================================
_info "btrfs subvolumes (top)"
if command -v btrfs >/dev/null 2>&1; then
  sudo btrfs subvolume list -t / 2>/dev/null | head -n 30 | sed 's/^/  /' || true
else
  _warn "btrfs-progs not installed"
fi
print

# =====================================================
# 6) OPTIONAL: Installer logs (if any)
# =====================================================
_info "Installer logs (if present)"
for f in /root/arch_install.log /var/log/arch_install.log /root/install.log ; do
  if [[ -s "$f" ]]; then
    print "--- $f (tail) ---"
    sudo tail -n 60 "$f" | sed 's/^/  /'
  fi
done
print

_ok "All checks finished. Log saved to ${LOG_FILE}"
