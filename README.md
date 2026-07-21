# nvim-fundo

The goal of nvim-fundo is to make Neovim's undo file become stable and useful.

<https://user-images.githubusercontent.com/17562139/202656014-85bc84ca-30b1-4093-9546-a06f17effc73.mp4>

> WIP. If you like this plugin, star it to let me speed up to end WIP state.

## Features

- Restore undo history even if the file's content has been changed outside Neovim
- Validate archive records with versioned metadata
- Inspect preservation health with `:FundoStatus` and `:FundoDoctor`
- Limit archive size, baseline size, retention age, and selected files

### TODO Features

- Restore undo history even if the file has been moved
- Support useful use cases for undo file

## Quickstart

### Requirements

- [Neovim](https://github.com/neovim/neovim) 0.7.2 or later

### Installation

Install with [Packer.nvim](https://github.com/wbthomason/packer.nvim):

```lua
use {
    'kevinhwang91/nvim-fundo'
}
```

### Minimal configuration

```lua
use {
    'kevinhwang91/nvim-fundo'
}

vim.o.undofile = true
require('fundo').setup()
```

### Usage

Use undo file as usual.

- `:FundoStatus [path]` shows the native undo, fallback, baseline, and manifest
  state for the current buffer or an optional path.
- `:FundoDoctor` checks archive permissions, usage, metadata, and orphaned
  artifacts.

## Documentation

`:h fundo` includes the default configuration, behavior notes, and troubleshooting
details.

### How does nvim-fundo keep the undo history?

Neovim stores undo history in native undo files. Fundo does not replace that undo
engine. If a file changes outside Neovim, the native undo file may no longer
match the current file contents. nvim-fundo keeps a fallback archive of recent
file contents next to the native undo file so the pair can be replayed together
when recovery is needed.

Fundo also keeps a size-limited baseline snapshot for cases where no usable
native undo file is available. If a file later changes while Neovim is closed
and Fundo cannot load native undo, Fundo uses the baseline only to create a
normal Neovim undo step from the previous file contents to the current contents.
After that, `:undo` and `:redo` are handled by Neovim.

Fundo handles the common external-change cases:

- when a file changes while Neovim is closed, Fundo validates the native undo file
  on the next `BufReadPost` and repairs it from the fallback archive when needed;
- when no usable native undo file is available, Fundo bridges from the baseline
  snapshot to the current file contents with one native undo step;
- when a native undo file exists but the matching fallback archive is missing,
  Fundo does not replace the richer native history with a baseline-only step;
- when a clean loaded buffer changes outside Neovim, `:checktime` triggers
  `FileChangedShellPost`, reloads the file, and Fundo preserves the previous undo
  history;
- when a loaded buffer is dirty, Neovim keeps the unsaved buffer unchanged, and
  Fundo does not replace it with external contents;
- external overwrites, appends, and truncates are handled as file-content changes.

Each successfully persisted fallback record has a versioned manifest in the
private `.metadata` archive subdirectory. The manifest records the source,
native undo, fallback, and optional baseline identity so Fundo can validate and
diagnose the record. Existing archives without a manifest remain usable and are
reported as legacy records until Fundo next persists them.

The fallback archives, manifests, and baseline snapshots use disk space.
`limit_archives_size` caps their total size in MB. `baseline_max_file_size`
independently limits one baseline snapshot, and `retention_days` optionally
expires complete records by age. A `filter` callback can exclude paths from
tracking. Pruning removes an expired or over-budget record together with its
metadata.

File moves are still listed as a TODO feature. Today, Fundo tracks the path that
Neovim reports for a buffer and can follow paths changed with `:saveas`, but it
does not claim complete move/rename recovery for arbitrary external moves.

## Vendored Dependencies

`nvim-fundo` vendors `promise-async` from:

- repository: <https://github.com/kevinhwang91/promise-async>
- commit: `119e8961014c9bfaf1487bf3c2a393d254f337e2`

The upstream BSD-3-Clause license is included in [LICENSE.promise-async](./LICENSE.promise-async).

### Setup and description

```lua
{
    archives_dir = {
        description = [[The directory to store the archives]],
        default = vim.fn.stdpath('cache') .. path.separator .. 'fundo'
    },
    limit_archives_size = {
        description = [[Limit the archives directory size, unit is MB(megabyte), elder files will be
        removed based on their modified time]],
        default = 512
    },
    baseline_max_file_size = {
        description = [[Maximum baseline snapshot size in MB. When omitted, it follows
        limit_archives_size.]],
        default = 512
    },
    retention_days = {
        description = [[Optional maximum archive record age in days.]],
        default = nil
    },
    filter = {
        description = [[Return true to track a path and false to exclude it.]],
        default = function(path, bufnr) return true end
    },
    logging = {
        description = [[Logging configuration. Disabled by default. When enabled, Fundo writes
        lifecycle, sync, archive, baseline, and failure events to logging.path. FUNDO_LOG can
        also be set to a level name to enable logging without config.]],
        default = {
            enabled = false,
            level = 'warn',
            path = vim.fn.stdpath('cache') .. path.separator .. 'fundo.log'
        }
    }
}
```

`:h fundo` may help you to get the all default configuration.

### API

[fundo.lua](./lua/fundo.lua)

## Local development

Run the local checks before sending changes:

```sh
make test
make lint
```

The test target runs the specs through headless Neovim. The `build/` directory is
generated dependency state. `lua/fundo/types.lua` contains local Lua language
server helper types for Neovim/libuv objects used by this project.

## Feedback

- If you get an issue or come up with an awesome idea, don't hesitate to open an issue in github.
- If you think this plugin is useful or cool, consider rewarding it a star.

## License

The project is licensed under a BSD-3-clause license. See [LICENSE](./LICENSE) file for details.
