# Changes relative to upstream/main

Comparison scope:

- Current branch compared with `upstream/main`.
- The purpose of this document is to explain what changed and why each change exists.

The standard for keeping a divergence should be strict:

- It directly supports the main goal: preserve the undo tree when file contents change outside Neovim, including while
Neovim is closed.
- It makes preservation failures visible instead of silently clearing state.
- It has tests that would fail if the behavior regressed.
- It does not exist only because it was convenient during the fork.

## High-level diff

The current branch changes 24 files relative to `upstream/main`:

- Adds vendored `promise-async` runtime files and license.
- Changes setup/config reload behavior.
- Adds new autocmd handling for `BufUnload` and `FileChangedShellPost`.
- Changes undo archive transfer and fallback repair semantics.
- Hardens file-copy, archive-pruning, path-normalization, and event-emission helpers.
- Adds integration, subprocess, and utility tests.

## Changes that should stay

### Vendored promise/async runtime

Files:

- `lua/promise.lua`
- `lua/async.lua`
- `lua/promise-async/*`
- `LICENSE.promise-async`
- `Makefile`
- `README.md`

What changed:

- The plugin no longer relies on installing `kevinhwang91/promise-async` via plugin manager or luarocks.
- The runtime is included in-tree with its BSD-3-Clause license.
- The test target no longer installs `promise-async` as an external dependency.
- The README documents the vendored dependency source and commit.

Why it exists:

- Owning the dependency removes one variable from undo preservation behavior.
- It makes tests and local development deterministic.
- It matches the stated fork direction: own every component that can affect preservation.

### Reloadable setup/config

Files:

- `lua/fundo.lua`
- `lua/fundo/config.lua`
- `spec/config_spec.lua`

What changed:

- `setup()` stores new config, reloads `fundo.config` if already loaded, disables the current instance, and enables
again.
- `Config.reload()` mutates the existing config table instead of replacing the module return value.

Why it exists:

- Tests and users can call `setup()` repeatedly with different `archives_dir` and `limit_archives_size` values.
- Repeated setup is required by the integration tests because each test uses isolated temp directories.

### Attach already-loaded buffers

File:

- `lua/fundo/manager.lua`

What changed:

- During `Manager:initialize()`, loaded buffers are attached and checked immediately.

Why it exists:

- Plugin managers can load Fundo after buffers already exist.
- Without this, those buffers would not be tracked until another event happened.

### Preserve across unload, wipeout, and closed Neovim

Files:

- `lua/fundo/main.lua`
- `lua/fundo/manager.lua`
- `lua/fundo/model/undo.lua`
- `spec/fundo_spec.lua`
- `spec/session_spec.lua`
- `spec/helper/session.lua`

What changed:

- `BufUnload` is tracked alongside `BufWipeout`.
- Detach now attempts a synchronous transfer before forgetting the buffer.
- `VimLeave` and `VimSuspend` use blocking sync.
- Tests now launch independent headless Neovim child processes to prove closed-session behavior.

Why it exists:

- The core data-loss case happens when Neovim is closed, a tool edits a file, and Neovim later reopens it.
- Same-process tests can pass while the real lifecycle still loses undo history.
- Synchronous transfer at unload/exit is appropriate because preserving state is more important than avoiding a small
blocking operation.

### Handle external file changes while buffers remain loaded

Files:

- `lua/fundo/main.lua`
- `lua/fundo/manager.lua`
- `lua/fundo/model/undo.lua`
- `spec/fundo_spec.lua`

What changed:

- `FileChangedShellPost` calls `u:check()`.
- Loaded-buffer external changes are tested with `:checktime`.
- After fallback replay, the object is marked dirty so the repaired pair can be persisted.

Why it exists:

- External tools can modify files while Neovim is still running.
- The plugin must preserve undo history for both open-buffer and closed-session external edits.

### Atomic native undo/fallback archive transfer

Files:

- `lua/fundo/model/undo.lua`
- `lua/fundo/manager.lua`
- `spec/fundo_spec.lua`

What changed:

- `transfer()` and `transferSync()` now abort if `wundo` fails.
- They also abort if the source file cannot be statted or copied to the fallback archive.
- `isDirty` is cleared only after both native undo save and fallback archive copy succeed.
- `syncAll()` reports rejected transfer promises.
- `detach()` returns failure information for direct callers.

Why it exists:

- A native undo file and fallback archive are a pair. Updating one without the other can create a corrupt recovery
state.
- The previous fork behavior could copy a new archive after a failed `wundo`, then mark the buffer clean.
- Silent success here is worse than an explicit failure because it hides a data-loss condition.

### Fallback repair only succeeds when `rundo` succeeds

Files:

- `lua/fundo/model/undo.lua`
- `spec/fundo_spec.lua`

What changed:

- `loadFileAndUndo()` now treats failed `rundo` as a failed repair.
- It restores buffer lines, modified state, and view before failing.
- `loadFallBack()` only reports success when the fallback file replay and undo tree load both succeed.

Why it exists:

- Replaying fallback file content without loading the matching undo tree is not a repaired undo history.
- Reporting success after failed `rundo` can lead later transfer paths to overwrite useful artifacts.

### Archive pruning and filesystem hardening

Files:

- `lua/fundo/fs/init.lua`
- `lua/fundo/manager.lua`
- `spec/fs_spec.lua`
- `spec/fundo_spec.lua`

What changed:

- `copyFile()` uses unique temp paths and removes temp files when rename fails.
- `copyFileSync()` was added for synchronous unload/exit transfer.
- `mkdirpSync()` was added for archive directory creation.
- Archive pruning uses settled results and logs failed deletions instead of failing the whole scan.

Why it exists:

- Archive writes need to avoid partial target files.
- Synchronous transfer needs synchronous copy support.
- Pruning should not break preservation because one stale archive cannot be removed.

### Path normalization fixes

Files:

- `lua/fundo/fs/path.lua`
- `spec/path_spec.lua`

What changed:

- `Path.normalize()` handles Windows drive prefixes, repeated separators, trailing separators, absolute paths, and
unresolved relative parents.
- Recent fixes ensure:
  - `../..` stays `../..`
  - `../../x` stays `../../x`
  - `a/../../b` becomes `../b`
  - `/..` becomes `/`
  - `/a/../../b` becomes `/b`

Why it exists:

- Archive path calculation depends on predictable path utilities.
- The earlier forked normalization was wrong for unresolved parents and paths above root.

## Test coverage added for these changes

### External-change coverage matrix

| Area                                     | Status                             | Evidence / decision                                                                                                                                                                                                                                     |
|------------------------------------------|------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Open loaded clean buffer                 | covered, strengthened in this pass | `spec/fundo_spec.lua` covers overwrite, append, truncate, and multiple external writes before one `:checktime`; undo returns to the last internal state.                                                                                                |
| Open dirty loaded buffer                 | added in this pass                 | `:checktime` leaves a modified buffer unchanged after an external overwrite. Fundo does not report a repair because Neovim does not reload the dirty buffer in this path.                                                                               |
| Open unloaded buffer                     | added in this pass                 | Explicit `:bunload` now has coverage separate from `bufhidden=unload`; undo survives an external edit before reopen.                                                                                                                                    |
| Open deleted/wiped buffer                | covered, strengthened in this pass | Existing wipeout coverage remains; explicit `:bdelete` coverage was added for the common user command path.                                                                                                                                             |
| Open lifecycle sync                      | partially added in this pass       | `FocusLost` and `TermEnter` are proven to schedule useful sync work. Non-`: CmdlineEnter` remains guarded. A deterministic headless `CmdlineEnter` external-command race was not found, so `CmdlineEnter` remains unresolved rather than proven useful. |
| Open save-as / path boundary             | added in this pass                 | `:saveas` coverage verifies the current buffer path is tracked and later external edits to the new path preserve undo.                                                                                                                                  |
| Closed linear history                    | covered, strengthened in this pass | `spec/session_spec.lua` covers overwrite, append, truncate, empty overwrite, and multiple external overwrites while Neovim is closed.                                                                                                                   |
| Closed branch history                    | covered, strengthened in this pass | Existing branch overwrite coverage remains; external append was added and verifies undo/redo branch shape.                                                                                                                                              |
| Closed multi-external                    | added in this pass                 | Multiple external overwrites while closed reopen to the final version and undo to the prior internal state.                                                                                                                                             |
| Missing native undo                      | covered, clarified in this pass    | With native undo missing, fallback-only recovery fails safely: no error and no false restored history claim.                                                                                                                                            |
| Missing fallback archive                 | covered, clarified in this pass    | If the file is unchanged, `shouldTransfer()` recreates the fallback archive from native undo. After an external edit with the fallback missing, recovery fails safely because the native undo is no longer enough to repair.                            |
| Corrupted/stale fallback archive         | added in this pass                 | A stale fallback archive is not accepted as a successful repair to unrelated stale content. Corrupted native undo still fails visibly.                                                                                                                  |
| Archive directory deleted while open     | added and fixed in this pass       | Transfer now recreates the archive parent directory before copying fallback content, using libuv-safe directory creation for fast-event paths.                                                                                                          |
| Binary or invalid UTF-8 external content | deferred                           | Neovim text buffer semantics do not reliably preserve arbitrary bytes such as NUL; this needs a separate byte-oriented feasibility pass.                                                                                                                |

Important new coverage:

- Repeated setup reloads config.
- Event emit continues after listener failure or self-disposal.
- Archive copy cleans temporary files on rename failure.
- Archive directory creation handles nested missing parents.
- Archive directory recreation after deletion while Neovim is open.
- Undo preservation after:
  - wipeout
  - unload
  - explicit `:bunload`
  - explicit `:bdelete`
  - loaded-buffer external edits
  - loaded-buffer external append, truncate, and multiple pending external edits
  - closed-session external append, truncate, empty overwrite, and multiple overwrites
  - missing native undo file
  - missing fallback archive
  - closed Neovim followed by external edits
  - branched undo trees across separate Neovim processes, including external append
- Failure semantics for:
  - failed native undo save
  - failed archive copy
  - retry after failed detach transfer
  - failed fallback undo load
  - failed async sync
  - corrupted native undo file
  - stale fallback archive content
- Path normalization edge cases on Unix and Windows-style paths.

Current verification:

- `make test`
- `98 successes / 0 failures / 0 errors / 0 pending`

## File-by-file reason map

| File                       | Reason to keep                                                                                     |
|----------------------------|----------------------------------------------------------------------------------------------------|
| `LICENSE.promise-async`    | Required license for vendored runtime.                                                             |
| `Makefile`                 | Stops installing external `promise-async`; improves Lua version target selection.                  |
| `README.md`                | Documents vendored dependency; no longer advertises the no-op install hook.                        |
| `lua/async.lua`            | Vendored async entrypoint.                                                                         |
| `lua/promise.lua`          | Vendored promise runtime.                                                                          |
| `lua/promise-async/*`      | Vendored compatibility/runtime support.                                                            |
| `lua/fundo.lua`            | Reloads config and restarts plugin on repeated setup.                                              |
| `lua/fundo/config.lua`     | Mutates module config table on reload.                                                             |
| `lua/fundo/main.lua`       | Adds unload and file-change events to the preservation lifecycle.                                  |
| `lua/fundo/manager.lua`    | Attaches loaded buffers, persists on detach, reports transfer failures, prunes archives robustly.  |
| `lua/fundo/model/undo.lua` | Implements fallback archive repair, atomic transfer, sync transfer, and failure-correct semantics. |
| `lua/fundo/fs/init.lua`    | Adds atomic copy helpers, sync copy, and mkdirp support needed by persistence.                     |
| `lua/fundo/fs/path.lua`    | Normalizes archive paths predictably across edge cases.                                            |
| `lua/fundo/lib/event.lua`  | Makes event iteration robust; conditional keep due to swallowed errors.                            |
| `spec/config_spec.lua`     | Covers repeated setup behavior.                                                                    |
| `spec/event_spec.lua`      | Covers robust event emission.                                                                      |
| `spec/fs_spec.lua`         | Covers fs helper hardening.                                                                        |
| `spec/fundo_spec.lua`      | Covers core undo preservation and failure semantics in-process.                                    |
| `spec/helper/session.lua`  | Provides real subprocess Neovim lifecycle tests.                                                   |
| `spec/path_spec.lua`       | Covers path behavior added by the fork.                                                            |
| `spec/session_spec.lua`    | Covers closed-Neovim external-edit preservation.                                                   |

## Bottom line

Most of the divergence has a coherent reason: protect the native undo/fallback archive pair across external edits and
process restarts. The critical keepers are the atomic transfer semantics, fallback repair correctness, unload/exit
persistence, and subprocess tests.

## Utility audit log

### 2026-06-30

Baseline before this audit:

- `make test`: 76 successes / 0 failures / 0 errors.

Verification after this audit:

- `make test BUSTED_ARGS=spec/config_spec.lua`: 1 success / 0 failures / 0 errors.
- `make test BUSTED_ARGS=spec/event_spec.lua`: 3 successes / 0 failures / 0 errors.
- `make test BUSTED_ARGS=spec/fs_spec.lua`: 12 successes / 0 failures / 0 errors.
- `make test BUSTED_ARGS=spec/fundo_spec.lua`: 39 successes / 0 failures / 0 errors.
- `make test BUSTED_ARGS=spec/path_spec.lua`: 26 successes / 0 failures / 0 errors.
- `make test BUSTED_ARGS=spec/session_spec.lua`: 11 successes / 0 failures / 0 errors.
- `make test`: 98 successes / 0 failures / 0 errors.

Changes made:

- Removed `run = function() require('fundo').install() end` from README install examples.
- Kept `require('fundo').install()` as a compatibility shim and documented that vendored dependencies mean it has no
current install-time work.
- Added event-emitter coverage that verifies listener failures are logged while later listeners still run.
- Added filesystem coverage that verifies `copyFileSync()` removes temporary files when rename fails.
- Added integration coverage for buffers loaded before `setup()`, invalid archive-directory setup, and failed detach
transfer state.
- Fixed `Manager:detach()` so a failed synchronous archive transfer does not dispose and remove the tracked undo object.
- Fixed `Undo:shouldTransfer()` so missing-fallback checks do not call non-fast Neovim APIs from fast-event async paths.
- Fixed setup failure handling so a bad archive path does not leave the manager initialized or leak event handlers from
a partial enable.
- Added external-change matrix coverage for open loaded append/truncate/multiple edits, dirty loaded `:checktime`,
explicit `:bunload`, explicit `:bdelete`, `:saveas`, lifecycle sync, closed-session append/truncate/empty/multiple
external edits, branch append, stale fallback archives, and archive-directory deletion.
- Fixed fallback transfer so a deleted archive directory is recreated before copy.
- Reworked `fs.mkdirpSync()` to use libuv calls instead of `vim.fn.mkdir()`, because async transfer can run from
fast-event paths where Vimscript functions are rejected.

Decisions:

- Remove: README install hook. It was misleading because the vendored runtime requires no install step.
- Keep: runtime `install()` symbol, but only as a compatibility shim for existing configs.
- Keep: vendored `promise-async` as a deterministic supply/test dependency, not as a local behavior patch.
- Keep: repeated setup/config reload. `spec/config_spec.lua` covers changing `archives_dir` and `limit_archives_size` on
repeated setup.
- Keep: attaching already-loaded buffers. `spec/fundo_spec.lua` now proves a file opened before `setup()` is tracked and
preserves undo after an external edit.
- Keep: `BufUnload`, `BufWipeout`, `VimLeave`, and `VimSuspend` sync behavior. Existing integration and closed-session
tests cover these preservation paths.
- Keep: `FileChangedShellPost`. The loaded-buffer external-change test covers `:checktime` restoring file content and
undo history.
- Keep: `FocusLost` and `TermEnter` sync hooks. New tests prove they can persist dirty undo state before a later
external edit.
- Keep/Fix: archive transfer and fallback repair semantics. The audit found that failed detach transfer used to drop the
undo object; it now stays tracked and dirty for retry.
- Keep/Fix: failed detach retry. New coverage proves a failed fallback copy leaves the undo object tracked and a later
successful detach produces an archive that can restore undo after an external edit.
- Keep/Fix: event listener isolation. Listener failures remain isolated, and tests now prove they are observable via
logging.
- Experiment still needed: `CmdlineEnter` sync. Non-colon command-line entry is covered by a guard test. A deterministic
headless shell-command mutation did not provide reliable proof for colon `CmdlineEnter`, so it remains unresolved rather
than proven useful.
- Clarified: a missing native undo file or missing fallback archive after an external edit fails safely but cannot
restore history. Missing fallback archives are recreated when the file has not changed and native undo can still be
loaded.
- Deferred: binary-ish external content with NUL or invalid UTF-8 remains out of scope for this pass because Neovim text
buffers do not provide byte-preserving semantics for arbitrary file content.
- Keep current path exports. `basename`, `dirname`, `normalize`, and `join` all have production callers, so the scope
risk is future expansion rather than currently unused code.

Vendored runtime evidence:

- Compared local vendored files against `kevinhwang91/promise-async` commit `119e8961014c9bfaf1487bf3c2a393d254f337e2`.
- `lua/promise.lua`: identical.
- `lua/async.lua`: identical.
- `lua/promise-async/compat.lua`: identical.
- `lua/promise-async/error.lua`: identical.
- `lua/promise-async/loop.lua`: identical.
- `lua/promise-async/utils.lua`: identical.
- Conclusion: vendoring is currently a packaging/determinism decision. There are no local runtime modifications to audit
separately.

Known remaining audit questions:

- `CmdlineEnter` sync still needs a targeted scenario showing that it prevents a real external-edit race, or a
performance check showing that its extra background sync attempts are negligible.
- Path helper behavior should not expand beyond archive naming, config path normalization, Windows/root handling, and
parent traversal safety without new production callers and tests.
