# hexcheck.nvim

Neovim plugin that checks the dependencies declared in `mix.exs` against the latest releases on [hex.pm](https://hex.pm) and annotates lines that have newer versions available.

First plugin ever done, so if you found any errors or have suggestions feel free to open an issue or PR :)

## Features

- Asynchronously queries hex.pm for each dependency in the current project.
- Adds end-of-line virtual text highlighting the latest version when an update is available.
- Plays nicely with existing highlights via the dedicated `HexCheckVirtualText` highlight group.
- Configurable virtual text color, emphasis, and message prefix.
- Compares against the locked versions in `mix.lock`.

## Requirements

- Neovim 0.8 or newer (uses `vim.notify_once`, `vim.api.nvim_buf_set_extmark`, etc.).
- `curl` in your `$PATH` for reaching the hex.pm API.

## Installation

Install it with your preferred plugin manager. Example using [`lazy.nvim`](https://github.com/folke/lazy.nvim) with default options:

```lua
{
  "renews/hexcheck.nvim",
  cmd = "HexCheck",
  opts = {
    highlight_color = "#123716",
    italic = true,
    bold = false,
    message_prefix = "new version available ",
  },
}
```

You dont need to specify the `opts` table or the `cmd` if you want the defaults.
The plugin is a no-op until you run `:HexCheck`, so lazy-loading on the command is a good fit.

## Usage

1. Open your project’s `mix.exs` (or any buffer inside the same project directory).
2. Run `:HexCheck`.
3. Dependencies that have newer releases than what is pinned in `mix.lock` will gain virtual text such as `new version available 1.2.3` at the end of their line.

The command looks for a `mix.exs` in the current buffer, falling back to the current working directory if necessary. Any warnings (missing file, request failures, etc.) are reported through `vim.notify`.

## Configuration

Call `require("hexcheck").setup()` to adjust how the inline hints look:

```lua
require("hexcheck").setup({
  highlight_color = "#fabd2f",
  italic = false,
  bold = true,
  message_prefix = "update available ",
})
```

Options:

- `highlight_color` (`string` or `false`) – hex color applied to the virtual text (`"#8ec07c"` by default). Use `false` to keep your own color.
- `italic` (`boolean`) – apply italic style; defaults to `true`.
- `bold` (`boolean`) – apply bold style; defaults to `false`.
- `message_prefix` (`string`) – text prepended to the fetched version (`"new version available "` by default). Include a trailing space if you want one.

If you would rather manage highlight groups yourself, omit the option and set it manually:

```vim
hi! link HexCheckVirtualText DiagnosticHint
" or
hi HexCheckVirtualText guifg=#8ec07c gui=italic
```

## How it works

- `:HexCheck` scans `mix.exs` to find dependency declarations and their line numbers.
- The plugin reads `mix.lock` to determine the exact versions currently in use.
- Each dependency is queried asynchronously against hex.pm for the newest release.
- When a newer release is found, a virtual text hint is scheduled back into `mix.exs`.
- Only dependencies declared directly in `mix.exs` are checked;

## Troubleshooting

- **No annotations appear** – verify `mix.exs` is reachable, contains tuples like `{:plug_name, "1.2.3"}`, and that `mix.lock` sits alongside it.
- **API requests fail** – make sure you have network access and `curl` is installed.
- **Highlight color clashes** – adjust the `highlight_color`, `italic`, or `bold` options, or redefine `HexCheckVirtualText`.

## Contributing

If you want to contribute or found an issue just open a PR and Im take a look :)
