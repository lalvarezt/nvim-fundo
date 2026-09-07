# Undo recovery validation

Run `make test` and `make lint` from the repository. The tests use isolated
files and archive directories. The session specs launch clean child Neovim
processes to verify persistence across an actual exit and restart.

The audit started with 126 passing tests. Regression tests reproduced failures
before the fixes. The resulting suite has 156 passing tests on Neovim 0.12.5.

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
not locate the old archive. Windows, older Neovim releases, concurrent editor
processes writing the same record, and sudden power loss were not validated by
this run.
