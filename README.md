# nvim-fundo

The goal of nvim-fundo is to make Neovim's undo file become stable and useful.

<https://user-images.githubusercontent.com/17562139/202656014-85bc84ca-30b1-4093-9546-a06f17effc73.mp4>

> WIP. If you like this plugin, star it to let me speed up to end WIP state.

## Features

- Restore undo history even if the file's content has been changed outside Neovim
- Undo external changes after opening a file without editing it
- Validate archive records with versioned metadata
- Inspect preservation health with `:FundoStatus` and `:FundoDoctor`
- Limit archive size, baseline size, retention age, and selected files

- Associate archived history with an externally moved file
- Preview recovered changes without changing the source undo position
- Choose capture on open, on write, or by explicit request

See [implemented improvements](./IMPROVEMENTS.md) for behavior and tradeoffs.

## Quickstart

### Requirements

- [Neovim](https://github.com/neovim/neovim/releases/latest) 0.12.5 or later. Only the latest stable release is supported.

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
- `:FundoTrack` starts tracking the current buffer explicitly.
- `:FundoAssociate old-path` associates archived history with the current file.
  Without an argument, it reports a suggestion when file identity is unambiguous.
- `:FundoPreview` compares the recovered previous contents with the current
  buffer in a new tab. Both diff buffers are read-only snapshots. The source
  buffer and its undo position remain unchanged.
- `:FundoForget [path]` previews removal of Fundo records for a file or directory.
  `:FundoForget! [path]` removes them and stops tracking those paths in this
  Neovim session. Native undo files remain. `:FundoTrack` resumes a selected
  buffer; other Neovim sessions can still capture the file.

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

Opening an eligible file starts retaining its contents, even if you never edit
or write it, with the default `track_on = 'open'`. For a file with no previous
undo history or recovery archives:

1. Open the file with contents A. Its undo history is empty, and Fundo saves A
   as a separate baseline snapshot.
2. Close Neovim without editing the file, then change its contents to B externally.
3. Reopen the file. The buffer contains B, `:undo` restores A, and `:redo`
   restores B.

Reopening unchanged contents creates no undo step. Multiple external edits
between opens become one combined change. Fundo cannot recover intermediate
versions it never observed, and recovery requires the saved baseline to survive
cleanup.

Baseline capture requires Fundo to be enabled, `undofile` to be on, and a named,
supported buffer accepted by `filter`. The buffer must be clean, modifiable,
and have undo enabled. The snapshot must fit `baseline_max_file_size`.
`:FundoStatus` reports a saved baseline without a fallback as `baseline-only`.

Baseline capture retains a copy of the buffer text on disk. Fundo checks the
buffer size before copying its lines, then queues persistence for the next
main-loop turn. Unchanged snapshots are not rewritten. Unload, exit, and
`:FundoSync` flush pending snapshots. Disk writes still run on the main thread.
The default limit is 8 MiB per snapshot, or `limit_archives_size` if smaller.
Earlier versions used the full archive budget as the baseline limit. To retain
that behavior, set `baseline_max_file_size` explicitly to your archive budget.
Files above the baseline limit can still have their native undo history
preserved through fallback archives.

Set `baseline_max_file_size = 0` to disable baseline snapshots. Use `filter` to
exclude paths from all Fundo tracking, or `retention_days` to flag old saved
records. Automatic expiry requires `prune_policy = 'delete'`. These controls do
not disable Neovim's own persistent undo files.
Excluding a path does not erase archives already saved for it.

Set `track_on = 'write'` to start new records after the first write, or
`track_on = 'manual'` to start them with `:FundoTrack`. Existing records continue
to recover on open under either policy. Explicit tracking still respects
`filter`, buffer type, and undo settings. A directory passed to `:FundoForget`
selects its descendants, not similarly named sibling directories. Records
whose source cannot be identified are reported and kept.

Fundo handles the common external-change cases:

- when a file changes while Neovim is closed, Fundo validates the native undo file
  on the next `BufReadPost` and repairs it from the fallback archive when needed;
- when no usable native undo file is available, Fundo bridges from the baseline
  snapshot to the current file contents with one native undo step;
- committed generations recover history even when compatibility archives are
  missing or stale. For legacy records without generations, Fundo does not
  replace an unmatched native undo file with a baseline-only step;
- when a clean loaded buffer changes outside Neovim, `:checktime` triggers
  `FileChangedShellPost`, reloads the file, and Fundo preserves the previous undo
  history;
- when a loaded buffer is dirty, Neovim keeps the unsaved buffer unchanged, and
  Fundo does not replace it with external contents;
- external overwrites, appends, and truncates are handled as file-content changes;
- deleting or renaming an open file does not prevent Fundo from archiving its
  buffer and undo history. Reopening the old path can recover that history,
  including when the path is still missing;
- new files are tracked on creation and first write. `:file` and `:saveas`
  update tracking to the buffer's new path.

Transfers capture the buffer text and native undo tree together. They do not
copy from the source pathname, which may have disappeared or changed since the
last write. Failed transfers retain both snapshots for retry after buffer unload.
A newer transfer takes precedence over an older pending snapshot for that path.
Synchronization does not write or recreate the source file.

`:FundoStatus [path]` reports pending transfers even after the buffer closes.
`:FundoDoctor` reports an issue while transfers remain pending, counting each
archive once across open buffers and detached retries. A successful retry clears
the pending state.

Run `:FundoSync` to persist current recovery snapshots and retry pending saves.
It includes modified tracked buffers without writing their source files, and
reports completion or failure. `require('fundo').sync()` returns a promise that
resolves on completion or rejects on failure. Sync requires Fundo to be enabled
and also runs archive cleanup when the manager's hourly scan is due.

Status includes `last_error` with a `stage`, `message`, and Unix timestamp `time`
when a save fails. Stages are `capture`, `fallback`, `undo`, `baseline`,
`manifest`, and `generation`. A failure before a retry snapshot exists reports
`transfer-error`;
a retained snapshot reports `pending-transfer`. `:FundoStatus` prints the error
and time, and `:FundoDoctor` lists failures by source path. A successful retry
clears the error. Details are kept in memory for tracked buffers and detached
pending snapshots; they do not survive restarting Neovim.

New snapshots store Neovim buffer text independently of the source file's
encoding and line endings. A clean file with no undo history can have a usable
baseline without a fallback; `:FundoStatus` reports this as `baseline-only`.

`require('fundo').recovery()` returns a copy of the latest recovered before/after
pair for the current buffer. The pair remains available after synchronization
advances the baseline and until the buffer is detached. The `User FundoRecovered`
event delivers the pair and its source, recovery kind, buffer number, and time
on the next main-loop turn. Previews compare the recovered previous contents
with the buffer's current contents, including any later unsaved edits.

Each successfully persisted fallback record has a versioned manifest in the
private `.metadata` archive subdirectory. The manifest records the source,
native undo, fallback, and optional baseline identity so Fundo can validate and
diagnose the record. Existing archives without a manifest remain usable and are
reported as legacy records until Fundo next persists them.

Recovery transfers also keep immutable generations in `archives_dir/.generations`.
Each generation includes checksummed buffer text and undo data. An atomic pointer
selects the committed generation, with the previous complete generation retained
as a fallback. An interrupted transfer cannot publish half a generation. Old
archives migrate on their next successful save. Writes synchronize file data
before rename and directory entries afterward on Unix. Generation data reaches
that synchronization point before the commit pointer is published, and older
generations are removed only after the pointer's directory is synchronized.
Synchronization failures remain retryable and are reported as failures.
If recovery cannot restore the original buffer after an exception, Fundo keeps
the original text in a recovery buffer and attempts a private backup under
`stdpath('state')/fundo-recovery`. The error reports the backup path and buffer
number. These emergency files survive editor exit and are not automatically pruned.
Durability depends on the filesystem and device honoring these operations.
Windows synchronizes file data but does not provide directory synchronization
through this implementation. Physical power loss and device failures were not
tested.

Per-record locks coordinate Fundo processes sharing the same archive directory.
A stale writer reports a conflict instead of replacing a newer generation.
Preserve any local edits, then reopen the file to use the current generation.
Dead locks on the same host are reclaimed. Acquisition uses a separate `.claim`
guard that is never reclaimed automatically. If acquisition was interrupted,
the sync error identifies the guard path. Stop all Fundo writers using that
archive, inspect the guard's `owner` file, and remove the abandoned guard before
retrying. Native undo files remain under
Neovim's control; committed copies protect Fundo recovery from competing native
undo writes.

The fallback archives, manifests, baseline snapshots, and generations use disk space.
The default `prune_policy = 'preserve'` keeps recovery records when they exceed
`limit_archives_size` or `retention_days`. Scans warn about pressure, and
`:FundoDoctor` reports quota and age issues. Disk usage can exceed the budget.
Set `prune_policy = 'delete'` to automatically remove expired or over-budget
records together with their metadata. That policy can delete the last recovery
copy. Damaged generation directories remain in place for inspection and require
explicit removal. The preservation policy also keeps unreferenced captures left
by interrupted publication. Redundant, complete committed generations can still
be retired after their replacements are synchronized.
`baseline_max_file_size` independently limits one baseline snapshot, and `filter`
can exclude paths from tracking.

Fundo follows buffer paths changed with `:file` or `:saveas`. After an external
move while Neovim is closed, open the destination and run
`:FundoAssociate old-path` to copy its persisted history to the destination.
The source archives remain available. Association does not rename or write
either source file. It requires a clean, eligible destination with no existing
undo history; a matching baseline-only record is allowed. Conflicting history
is rejected before the destination buffer changes.

With no argument, `:FundoAssociate` reports a suggestion without applying it.
Suggestions require one missing source with matching device, inode, birth time,
and contents. Equal contents alone are insufficient. Edited moves, moves across
filesystems, and systems without this identity information need an explicit
old path. `require('fundo').associate(old_path, new_path)` and
`require('fundo').association_candidates(new_path)` expose these operations;
the destination must be loaded and defaults to the current buffer.

Neovim can still report `E211` when `:checktime` detects a missing source file.
That warning does not mean Fundo's archive transfer failed.

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
        description = [[Archive budget in MiB. The preserve policy reports excess usage.
        The delete policy removes older records to meet the budget.]],
        default = 512
    },
    prune_policy = {
        description = [[Preserve recovery records under quota and age pressure, or use delete
        to enable automatic eviction. Damaged generations require explicit removal.]],
        default = 'preserve'
    },
    baseline_max_file_size = {
        description = [[Maximum baseline snapshot size in MiB. When omitted, it is the smaller
        of 8 and limit_archives_size. Set to 0 to disable baseline snapshots.]],
        default = 8
    },
    retention_days = {
        description = [[Optional maximum archive record age in days.]],
        default = nil
    },
    filter = {
        description = [[Return true to track a path and false to exclude it.]],
        default = function(path, bufnr) return true end
    },
    track_on = {
        description = [[Start new records on open, write, or manual request.
        Existing records still recover on open.]],
        default = 'open'
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
See [TESTING.md](./TESTING.md) for the recovery cases and validation boundaries.

## Feedback

- If you get an issue or come up with an awesome idea, don't hesitate to open an issue in github.
- If you think this plugin is useful or cool, consider rewarding it a star.

## License

The project is licensed under a BSD-3-clause license. See [LICENSE](./LICENSE) file for details.
# Competing undo histories

When native undo differs from a committed Fundo capture, Fundo preserves the native
tree as a separate generation before loading the committed tree. The default
`prune_policy = 'preserve'` keeps these competing histories for recovery.

Full text and undo captures are synchronized to a private recovery journal under
`stdpath('state')/fundo-journal` before archive publication. Failed saves survive
editor exit. On restart, Fundo recovers a journal whose archive revision still
matches; conflicting or damaged journals remain available through `:FundoDoctor`.
Successful publication removes its journal. Explicit record removal also removes
the matching journals. Source buffers are not written during recovery.
