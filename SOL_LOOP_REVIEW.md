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

Codex ran `gpt-6.2-sol` with high reasoning effort. Round 1 returned `CHANGES`.
The fixes below await recheck. The review tool did not expose token usage.

| ID | Severity | Outcome | Evidence |
| --- | --- | --- | --- |
| S1 | blocker | Fixed | A scratch buffer verifies the undo file against the archived text before recovery changes the source. The regression compares the native undo file before and after a failed recovery. |
| S2 | blocker | Fixed | A literal `%` uses a source-specific archive key. Verified legacy ownership permits reuse. The collision test opens `a%b` and `a/b` with the same native undo filename. |
| S3 | should | Fixed | Disabling baselines switches a baseline pointer to a full generation and preserves other full captures. |
| S4 | should | Fixed | Both sync paths hold pending transfers while an active buffer has `noundofile` or an empty `undodir`. |
| S5 | should | Fixed | `BufWinEnter` and `FileChangedShellPost` run recovery after modelines. After a native undo read aborts, recovery runs on the next main-loop turn if modelines are disabled. |
| S6 | should | Fixed | Delete pruning keeps pointerless generation directories with captures. The test repairs a pointer after startup cleanup. |
| S7 | nit | Deferred | Directory synchronization for a search-only ancestor is a separate filesystem change. |
| S8 | nit | Deferred | The unreachable fast-event branches have no effect on recovery. |

On Neovim 0.12.6, the seven regression cases failed at `327e3e9` and passed after
the fixes. `make test` passed 347 tests. `make lint` and `git diff --check`
against the base passed. The base diff went from 62 files with 12,019 insertions
and 168 deletions to 62 files with 12,218 insertions and 169 deletions before
this record was updated.

The fix commit is unsigned because the signing agent was unavailable.
