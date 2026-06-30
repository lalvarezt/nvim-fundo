# nvim-fundo

The goal of nvim-fundo is to make Neovim's undo file become stable and useful.

<https://user-images.githubusercontent.com/17562139/202656014-85bc84ca-30b1-4093-9546-a06f17effc73.mp4>

> WIP. If you like this plugin, star it to let me speed up to end WIP state.

## Features

- Restore undo history even if the file's content has been changed outside Neovim
- Limit size for archives

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

The fallback archives and baseline snapshots use disk space. `limit_archives_size`
caps the archive directory size in MB; when the limit is exceeded, older archives
are pruned by modified time. The same option is also the maximum individual file
size Fundo will copy as a baseline snapshot. Oversized files are skipped, and an
existing baseline is removed when the current file no longer fits the limit.

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
