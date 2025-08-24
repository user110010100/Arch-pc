local wezterm = require 'wezterm'

return {
  -- Явное отключение Wayland-бэкенда для совместимости с Hyprland
  enable_wayland = false,

  -- Настройки шрифтов с приоритетом FiraCode Nerd Font и правильным fallback
  font = wezterm.font_with_fallback({
    'FiraCode Nerd Font Mono',  -- Основной моноширинный шрифт
    'Noto Sans',                -- Основной шрифт для Unicode (включая кириллицу) :cite[9]
    'Noto Sans Cyrillic',       -- Специфичный для кириллицы (если требуется)
    'Noto Color Emoji',         -- Для эмодзи
    'DejaVu Sans Mono',         -- Резервный моноширинный
  }),
  font_size = 12.0,

  -- Дополнительные настройки шрифтов
  font_rules = {
    {
      italic = true,
      font = wezterm.font('FiraCode Nerd Font Mono', {italic = true}),
    },
  },
  warn_about_missing_glyphs = false,
  font_shaping = 'Harfbuzz',  -- Использовать современный шейпинг

  -- Автоматическое копирование при выделении
  selection_automatically_copy_to_clipboard = true,

  -- Настройки мыши
  mouse_bindings = {
    -- Выделение текста
    {
      event = { Down = { streak = 1, button = 'Left' } },
      mods = 'NONE',
      action = wezterm.action { SelectTextAtMouseCursor = 'Cell' },
    },
    -- Завершение выделения (копирование происходит автоматически)
    {
      event = { Up = { streak = 1, button = 'Left' } },
      mods = 'NONE',
      action = wezterm.action { CompleteSelection = 'Clipboard' },
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
  enable_kitty_keyboard = true,
  hide_mouse_cursor_when_typing = false,
  default_cursor_style = 'BlinkingBlock',
  
  -- Настройки для лучшей интеграции с Hyprland
  enable_tab_bar = true,
  use_fancy_tab_bar = false,
  tab_bar_at_bottom = true,
}
