# Sol-loop review

Scope: `experiments` against `origin/main`, including undo preservation, checkpoints,
recovery, storage policies, and editor workflows. New features and broad refactors
are outside this review.

- Base: `c2b83cb19e4ac475f2b08aaf775afe3da19bc495`.
- Initial head: `a0f531f`.
- Diff command: `git diff c2b83cb19e4ac475f2b08aaf775afe3da19bc495`.
- Reviewer: Codex provider, `gpt-6.1-sol`, high reasoning effort.
- Verdict: `APPROVE` after two of three allowed rounds.
- Round 1 returned `CHANGES`; round 2 resolved S1 with no new findings.
- Usage: not exposed. No push requested or performed.
- Initial diff: 61 files, 11,958 insertions, 168 deletions.
- Final diff: 62 files, 12,019 insertions, 168 deletions, including this record.
- Fix diff against the initial head, excluding this record: two files,
  26 insertions, one deletion.
- Fix commit: `022a2ce`. Commits are unsigned because the signing agent was unavailable.

| ID | Severity | Outcome | Evidence |
| --- | --- | --- | --- |
| S1 | should | Fixed and resolved in round 2 | Matching baseline-only recovery now succeeds. The empty-tree sync removes the journal after publication. |

The restart regression first failed with
`pending snapshot still requires recovery into its buffer`. After the recovery
fix, the test exposed a journal left behind by the empty-tree sync path.
The final fix publishes the baseline and removes its journal without changing
the text, modified flag, or undo entry count.

Validation on Neovim 0.12.6:

- Initial `make test`: 340 successes, no failures or errors.
- After S1, `make test`: 341 successes, no failures or errors.
- `make lint`: no problems found before or after the fix.
- Round 2: journal session tests passed with four successes. `git diff --check` passed.
- Declined findings: none.

## GPT-6.2 Sol review

Review started at `327e3e9` on `experiments`. The base is
`c2b83cb19e4ac475f2b08aaf775afe3da19bc495`. The diff covers undo preservation,
checkpoints, storage failures, recovery, and buffer persistence options.

Codex ran `gpt-6.2-sol` with high reasoning effort. All five rounds returned
`CHANGES`. The loop reached its five-round budget with S5 and S11 open. The
review extended past three rounds after Sol reproduced loss of the only
pending draft in S4. The review tool did not expose token usage. No push was
requested or performed.

| ID | Severity | Outcome | Evidence |
| --- | --- | --- | --- |
| S1 | blocker | Resolved in round 2 | A scratch buffer verifies the undo file against the archived text before recovery changes the source. The regression compares the native undo file before and after a failed recovery. |
| S2 | blocker | Resolved in round 4 | Fundo checks for a foreign native tree when opening a file or enabling Fundo with a buffer already open. It enumerates manifests using the literal archive directory path. The regression uses matching text and includes `arc[2026]`. |
| S3 | should | Resolved in round 2 | Disabling baselines switches a baseline pointer to a full generation and preserves other full captures. |
| S4 | should | Resolved in round 4 | Both sync paths hold pending transfers while persistence is off. A skipped detach keeps the pending draft. Reopening retains the original native tree before loading the pending draft. |
| S5 | should | Open after round 5 | The immediate redisplay regression passes for `:edit`. An aborted `bufload()` in an autocmd window leaves no `BufLeave` marker for the source, so immediate display can recover undo before applying `noundofile`. |
| S6 | should | Resolved in round 2 | Delete pruning keeps pointerless generation directories with captures. The test repairs a pointer after startup cleanup. |
| S7 | nit | Deferred | Directory synchronization for a search-only ancestor is a separate filesystem change. |
| S8 | nit | Deferred | The unreachable fast-event branches have no effect on recovery. |
| S9 | should | Resolved in round 3 | The association probe identifies the destination source before reading its legacy baseline. |
| S10 | should | Resolved in round 3 | Disabling baselines loads the promoted full generation on the same open. |
| S11 | blocker | Open after round 5 | Both drafts survive if archive writes resume before the second save. If archive writes still fail while the recovery journal is writable, `storage.retain()` fails before Fundo journals the second draft. |

On Neovim 0.12.6, the seven regression cases failed at `327e3e9` and passed after
the fixes. `make test` passed 347 tests. `make lint` and `git diff --check`
against the base passed. The base diff went from 62 files with 12,019 insertions
and 168 deletions to 62 files with 12,218 insertions and 169 deletions before
this record was updated.

With the updated specs, seven cases failed at `af41728` and passed after the
round 2 fixes. `make test` passed 348 tests. `make lint` and `git diff --check`
passed. The fix commits are unsigned because the signing agent was unavailable.

Four additional cases failed at `d6627a3` with the updated specs. The round 3
fixes cover both ownership checks, reopen with a pending draft and an older
native tree, and an aborted read with `eventignore=User`. `make test` passed
351 tests in standard and shuffled order with seed `48271`. `make lint` and
`git diff --check` passed.

Three cases failed at `8e5ca9c` with the updated specs. After the round 4 fixes,
`make test` passed 353 tests in standard and shuffled order with seed `48271`.
`make lint` and `git diff --check` passed.

### Final recheck at `0463447`

- S11 reproduced after exit. The journal held the first draft. The journal
  and archive lacked the newer draft. Capture and journal the active snapshot
  before retaining the detached draft or finishing its journal.
- S5 reproduced with `eventignore=User`, an `E823` from `bufload()`, and
  immediate `:buffer` display. `undofile` stayed enabled and `:undo` restored
  the archived draft. Route autocmd-window reads through the existing
  deferred modeline check.

Before this final record, `git diff --shortstat` against the base reported
62 files with 12,490 insertions and 169 deletions. At the start it reported
62 files with 12,019 insertions and 168 deletions.
