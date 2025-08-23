local wezterm = require 'wezterm'

return {
  -- Явное отключение Wayland-бэкенда для совместимости с Hyprland
  enable_wayland = false,

  -- Настройки шрифтов
  font = wezterm.font_with_fallback {
    -- Основной моноширинный шрифт с поддержкой кириллицы
    'Noto Mono',
    -- Дополнительные шрифты для символов и эмодзи
    'Noto Color Emoji',
    'DejaVu Sans Mono',
    'Symbols Nerd Font Mono',
  },
  font_size = 12.0,

  -- Дополнительные настройки отображения шрифтов
  freetype_load_flags = 'NO_HINTING',
  freetype_render_target = 'HorizontalLcd',

  -- Настройки мыши
  mouse_bindings = {
    -- Выделение и мгновенное копирование в буфер
    {
      event = { Drag = { streak = 1, button = 'Left' } },
      mods = 'NONE',
      action = wezterm.action { SelectText = 'ClipboardAndPrimarySelection' },
    },
    -- Вставка по правой кнопке
    {
      event = { Up = { streak = 1, button = 'Right' } },
      mods = 'NONE',
      action = wezterm.action { PasteFrom = 'Clipboard' },
    },
  },

  -- Клавиатурные сочетания
  keys = {
    -- Вставка по Ctrl+Shift+V
    {
      key = 'v',
      mods = 'CTRL|SHIFT',
      action = wezterm.action { PasteFrom = 'Clipboard' },
    },
    -- Копирование по Ctrl+Shift+C
    {
      key = 'c',
      mods = 'CTRL|SHIFT',
      action = wezterm.action { CopyTo = 'ClipboardAndPrimarySelection' },
    },
  },

  -- Дополнительные настройки
  warn_about_missing_glyphs = false,
  enable_kitty_keyboard = true,
  hide_mouse_cursor_when_typing = false,
  default_cursor_style = 'BlinkingBlock',
  
  -- Настройки для лучшей интеграции с Hyprland
  enable_tab_bar = true,
  use_fancy_tab_bar = false,
  tab_bar_at_bottom = true,
}
