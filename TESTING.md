# Undo recovery validation

Run `make test` and `make lint` from the repository. The tests use isolated
files and archive directories. The session specs launch clean child Neovim
processes to verify persistence across an actual exit and restart.

Regression tests reproduce the reported failures before their fixes. Run the
commands above for the current test count and lint results. Validation uses
Neovim 0.12.5. Only the latest stable Neovim release is supported.

The review corrected these cases:

- Detached pending history is recovered after an external change before the
  reopened buffer replaces its snapshot. Tests cover synchronous and asynchronous
  retries, continued storage failures, and recovery in a subsequent process.
- Explicit `:edit!` reloads persist native undo history, as `:checktime` reloads do.
- Invalid metadata and unsupported snapshot formats prevent recovery from
  guessing a decoder. Tests preserve a literal leading U+FEFF in the baseline.
- Disabling baselines removes metadata for baseline-only records and updates
  records with a retained fallback. Orphan metadata is subject to retention and
  size limits. Metadata write and deletion failures remain retryable.
- After `:checktime`, Neovim can retain its native undo tree while changing the
  buffer text. Fundo now marks that state for persistence so the fallback still
  matches after exit. A test uses separate Neovim sessions and verifies undo and
  redo after another external change.
- Failed snapshots survive disabling and re-enabling Fundo and explicit buffer
  renames. Successful synchronous retries also clear the active buffer's pending
  state. The tests inject write failures and verify subsequent recovery.
- Edits saved while Fundo is disabled take precedence over older pending
  snapshots when Fundo is re-enabled. The regression verifies the saved archive
  and undo recovery after a later external change.
- Failed baseline deletion reports a baseline-stage error and remains retryable.
  The tests cover buffers with and without native undo history.
- Configuration resolves the archive directory to an absolute path. Changing
  the working directory no longer changes its destination, and a trailing
  separator no longer allows Fundo to track its own archive files.

The corrupted native undo test also verifies recovery after Neovim reports
`E823`: current text remains intact, undo restores the baseline, and redo restores
the current text.

| Area | Cases checked |
| --- | --- |
| External changes | Overwrite, append, truncate, empty contents, repeated changes, deletion, rename, deletion followed by recreation |
| Timing | Before synchronization, loaded-buffer reload, unload, wipeout, exit, and a subsequent Neovim process |
| Buffer state | Clean, modified, newly created, empty, renamed with `:file`, saved with `:saveas`, hidden, and displayed in multiple windows |
| Undo history | Linear history, branches, undo and redo across external changes, no native tree, missing native undo, and corrupted recovery artifacts |
| Retry behavior | Failed fallback writes, failed baseline writes, invalid buffers after unload, source disappearance after unload, and an older pending transfer competing with a newer save |
| Text | Empty lines, trailing carriage returns, UTF-8, embedded NUL bytes, UTF-16 baselines, and legacy UTF-16 baselines without metadata |
| Storage identity | Files ending in `.base`, same-named files with `undodir=.`, and migration of ambiguous old archive names when metadata identifies their source |
| Storage policy | Baseline-only retention, complete-record expiry, archive size pruning, baseline limits, failed pruning, missing archive directories, and private permissions |
| Configuration | Filters, repeated setup, failed setup, disabling `undofile` after attachment, and enabling Fundo over a modified buffer |
| Diagnostics | Healthy records, usable baseline-only records, invalid metadata, and existing status and doctor checks |

Transfers now capture buffer text and undo data together on the Neovim main
loop. A retry owns those captured bytes, so it does not depend on a live buffer
or a source pathname. Publication runs without yielding between artifacts to
prevent an unload or another save from interleaving with it. Individual file
writes use temporary files and rename. Publication of the whole record is not
a filesystem transaction across processes or power loss.

New snapshots store buffer lines in UTF-8 with LF separators. The manifest
identifies this format separately from legacy copies of source files. Recovery
leaves source encoding and end-of-line options under Neovim's control.

The two filename collision cases use an archive key derived from the full
source path. Existing records with matching source metadata are copied to the
new key on attachment. Ambiguous legacy records without source metadata are
not assigned to a file by guessing.

Interactive verification uses isolated tmux sessions at 160 columns by 30 rows.
The deletion/recreation and rename scenarios check visible messages, buffer
contents, undo, redo, and persistence after reopening. `E211` for a missing file
and `W12` for a conflicting external write are Neovim messages, not evidence of
an archive failure.

Arbitrary external moves remain outside automatic recovery. After moving an
open file, `:file new-path` associates its buffer and history with the new path.
Opening only a previously unknown destination after a closed-session move does
not locate the old archive. Windows, concurrent editor processes writing the
same record, and sudden power loss were not validated by this run.
