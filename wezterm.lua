local wezterm = require 'wezterm'

return {
  enable_wayland = false,

  font = wezterm.font_with_fallback({
    'FiraCode Nerd Font Mono',
    'Noto Sans',
    'Noto Color Emoji',
    'DejaVu Sans Mono',
  }),
  font_size = 12.0,

  font_rules = {
    {
      italic = true,
      font = wezterm.font('FiraCode Nerd Font Mono', {italic = true}),
    },
  },
  warn_about_missing_glyphs = false,

  -- FIX: корректное поле
  font_shaper = 'Harfbuzz',
  -- при необходимости можно добавить тонкую настройку:
  -- harfbuzz_features = {"calt=1", "liga=1"},

  -- FIX: удалено несуществующее поле `selection_automatically_copy_to_clipboard`
  -- Действие копирования уже реализовано в mouse_bindings через CompleteSelection="Clipboard"

  mouse_bindings = {
    {
      event = { Down = { streak = 1, button = 'Left' } },
      mods = 'NONE',
      action = wezterm.action { SelectTextAtMouseCursor = 'Cell' },
    },
    {
      event = { Up = { streak = 1, button = 'Left' } },
      mods = 'NONE',
      action = wezterm.action { CompleteSelection = 'Clipboard' },
    },
    {
      event = { Up = { streak = 1, button = 'Right' } },
      mods = 'NONE',
      action = wezterm.action { PasteFrom = 'Clipboard' },
    },
  },

  keys = {
    { key = 'v', mods = 'CTRL|SHIFT', action = wezterm.action { PasteFrom = 'Clipboard' } },
    { key = 'c', mods = 'CTRL|SHIFT', action = wezterm.action { CopyTo = 'ClipboardAndPrimarySelection' } },
  },

  enable_kitty_keyboard = true,
  hide_mouse_cursor_when_typing = false,
  default_cursor_style = 'BlinkingBlock',
  enable_tab_bar = true,
  use_fancy_tab_bar = false,
  tab_bar_at_bottom = true,
}
