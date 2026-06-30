# Changes relative to upstream/main

Comparison scope:

- Current branch compared with `upstream/main`.
- The purpose of this document is to explain what changed and why each change exists.

This branch is no longer a small patch on top of upstream. It vendors a runtime dependency, changes the undo preservation state machine, adds failure handling, and adds a real test suite for the data-loss cases that motivated the fork.

The standard for keeping a divergence should be strict:

- It directly supports the main goal: preserve the undo tree when file contents change outside Neovim, including while Neovim is closed.
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

Keep if:

- We accept responsibility for auditing and updating vendored async/promise code.
- The vendored commit remains documented.
- License text stays in the repo.

Reconsider if:

- The fork is expected to remain close to upstream or consume upstream dependency updates automatically.

### Reloadable setup/config

Files:

- `lua/fundo.lua`
- `lua/fundo/config.lua`
- `spec/config_spec.lua`

What changed:

- `setup()` stores new config, reloads `fundo.config` if already loaded, disables the current instance, and enables again.
- `Config.reload()` mutates the existing config table instead of replacing the module return value.

Why it exists:

- Tests and users can call `setup()` repeatedly with different `archives_dir` and `limit_archives_size` values.
- Repeated setup is required by the integration tests because each test uses isolated temp directories.

Keep:

- This is justified and covered by `spec/config_spec.lua`.

### Attach already-loaded buffers

File:

- `lua/fundo/manager.lua`

What changed:

- During `Manager:initialize()`, loaded buffers are attached and checked immediately.

Why it exists:

- Plugin managers can load Fundo after buffers already exist.
- Without this, those buffers would not be tracked until another event happened.

Keep:

- This directly supports preservation for lazy-loaded setups.

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
- Synchronous transfer at unload/exit is appropriate because preserving state is more important than avoiding a small blocking operation.

Keep:

- This is the central reason for the fork.
- The subprocess tests prove linear undo, branched undo trees, repeated outside/inside/outside edits, and safe handling of missing/corrupted artifacts.

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

Keep:

- This supports the same preservation goal from a different lifecycle.

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

- A native undo file and fallback archive are a pair. Updating one without the other can create a corrupt recovery state.
- The previous fork behavior could copy a new archive after a failed `wundo`, then mark the buffer clean.
- Silent success here is worse than an explicit failure because it hides a data-loss condition.

Keep:

- This is required for correctness.
- Regression tests cover failed native undo save, failed archive copy, failed fallback undo load, and failed async sync.

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

Keep:

- This closes a real consistency hole.

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

Keep:

- These support the preservation state machine and are tested.

### Path normalization fixes

Files:

- `lua/fundo/fs/path.lua`
- `spec/path_spec.lua`

What changed:

- `Path.normalize()` handles Windows drive prefixes, repeated separators, trailing separators, absolute paths, and unresolved relative parents.
- Recent fixes ensure:
  - `../..` stays `../..`
  - `../../x` stays `../../x`
  - `a/../../b` becomes `../b`
  - `/..` becomes `/`
  - `/a/../../b` becomes `/b`

Why it exists:

- Archive path calculation depends on predictable path utilities.
- The earlier forked normalization was wrong for unresolved parents and paths above root.

Keep:

- Keep the fixed behavior and tests.

## Test coverage added for these changes

Important new coverage:

- Repeated setup reloads config.
- Event emit continues after listener failure or self-disposal.
- Archive copy cleans temporary files on rename failure.
- Archive directory creation handles nested missing parents.
- Undo preservation after:
  - wipeout
  - unload
  - loaded-buffer external edits
  - missing native undo file
  - missing fallback archive
  - closed Neovim followed by external edits
  - branched undo trees across separate Neovim processes
- Failure semantics for:
  - failed native undo save
  - failed archive copy
  - failed fallback undo load
  - failed async sync
  - corrupted native undo file
- Path normalization edge cases on Unix and Windows-style paths.

Current verification:

- `make test`
- `76 successes / 0 failures / 0 errors / 0 pending`

## File-by-file reason map

| File | Reason to keep |
| --- | --- |
| `LICENSE.promise-async` | Required license for vendored runtime. |
| `Makefile` | Stops installing external `promise-async`; improves Lua version target selection. |
| `README.md` | Documents vendored dependency; should remove no-op install hook unless needed. |
| `lua/async.lua` | Vendored async entrypoint. |
| `lua/promise.lua` | Vendored promise runtime. |
| `lua/promise-async/*` | Vendored compatibility/runtime support. |
| `lua/fundo.lua` | Reloads config and restarts plugin on repeated setup. |
| `lua/fundo/config.lua` | Mutates module config table on reload. |
| `lua/fundo/main.lua` | Adds unload and file-change events to the preservation lifecycle. |
| `lua/fundo/manager.lua` | Attaches loaded buffers, persists on detach, reports transfer failures, prunes archives robustly. |
| `lua/fundo/model/undo.lua` | Implements fallback archive repair, atomic transfer, sync transfer, and failure-correct semantics. |
| `lua/fundo/fs/init.lua` | Adds atomic copy helpers, sync copy, and mkdirp support needed by persistence. |
| `lua/fundo/fs/path.lua` | Normalizes archive paths predictably across edge cases. |
| `lua/fundo/lib/event.lua` | Makes event iteration robust; conditional keep due to swallowed errors. |
| `spec/config_spec.lua` | Covers repeated setup behavior. |
| `spec/event_spec.lua` | Covers robust event emission. |
| `spec/fs_spec.lua` | Covers fs helper hardening. |
| `spec/fundo_spec.lua` | Covers core undo preservation and failure semantics in-process. |
| `spec/helper/session.lua` | Provides real subprocess Neovim lifecycle tests. |
| `spec/path_spec.lua` | Covers path behavior added by the fork. |
| `spec/session_spec.lua` | Covers closed-Neovim external-edit preservation. |

## Bottom line

Most of the divergence has a coherent reason: protect the native undo/fallback archive pair across external edits and process restarts. The critical keepers are the atomic transfer semantics, fallback repair correctness, unload/exit persistence, and subprocess tests.

## Things to analyze later for potential removal or recheck

These items are not necessarily wrong, but their reason is weaker than the core undo-preservation changes. They should not become permanent by inertia.

### Event emitter catches listener failures

Files:

- `lua/fundo/lib/event.lua`
- `spec/event_spec.lua`

What changed:

- `Event:emit()` snapshots listeners before iteration.
- It catches listener errors and logs them instead of stopping later listeners.

Why it may exist:

- One failing listener should not prevent cleanup/persistence listeners from running.
- A listener disposing itself during emit should not corrupt iteration.

Concern:

- This can hide internal bugs during development because events no longer fail loudly.

Analyze later:

- Decide whether production should swallow listener failures but tests/debug mode should rethrow them.
- Confirm that important persistence failures are still observable despite event-level `pcall`.

### README still shows a no-op install hook

Files:

- `README.md`
- `lua/fundo.lua`

What changed:

- The README no longer lists `promise-async` as an external requirement.
- It still shows `run = function() require('fundo').install() end`.
- `M.install()` is reserved and currently does nothing.

Why it may exist:

- It preserves upstream installation shape.
- It leaves a future hook for generated help docs or setup work.

Concern:

- A no-op install hook is misleading now that the vendored runtime requires no install step.

Analyze later:

- Remove the `run = ... install()` snippet unless there is a concrete install-time behavior planned.
- If `install()` remains, document what future work it is reserved for.

### Sync on command-line entry

Files:

- `lua/fundo/main.lua`
- `lua/fundo/manager.lua`

What changed:

- This behavior mostly existed upstream, but it remains part of the forked state machine.

Why it may exist:

- It can flush undo/archive state before a user runs commands that may trigger shell tools or external modifications.

Concern:

- It may perform more background sync attempts than necessary.

Analyze later:

- Profile whether command-line entry sync has measurable overhead.
- Keep it only if it prevents a real external-edit race or costs effectively nothing.

### Custom path module scope

Files:

- `lua/fundo/fs/path.lua`
- `spec/path_spec.lua`

What changed:

- The path module now has more behavior than upstream, especially around Windows drives, unresolved parent traversal, absolute roots, and join normalization.

Why it may exist:

- Fundo needs deterministic archive paths on Unix and Windows.

Concern:

- This could drift into a general-purpose path library that the plugin does not need.

Analyze later:

- Keep only path behavior needed for archive naming, config expansion, and tests.
- Remove or simplify path behavior that has no caller.

### Vendored runtime modifications

Files:

- `lua/promise.lua`
- `lua/async.lua`
- `lua/promise-async/*`

What changed:

- The async/promise runtime is vendored into the plugin.

Why it may exist:

- Owning the runtime removes dependency installation as a source of variation.

Concern:

- Local modifications to vendored code would make future audits difficult.

Analyze later:

- Verify the vendored files match the documented upstream dependency commit.
- If local changes are necessary, isolate and document them separately from the vendored import.
