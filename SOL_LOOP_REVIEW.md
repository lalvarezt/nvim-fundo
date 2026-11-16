# Sol-loop review

Scope: `experiments` against `origin/main`, including undo preservation, checkpoints,
recovery, storage policies, and editor workflows. New features and broad refactors
are outside this review.

- Base: `c2b83cb19e4ac475f2b08aaf775afe3da19bc495`.
- Initial head: `a0f531f`.
- Diff command: `git diff c2b83cb19e4ac475f2b08aaf775afe3da19bc495`.
- Reviewer: Codex provider, `gpt-6.1-sol`, high reasoning effort.
- Budget: three rounds. Round 1 returned `CHANGES`; round 2 is pending.
- Usage: not exposed. No push requested or performed.
- Initial diff: 61 files, 11,958 insertions, 168 deletions.
- Fix diff against the initial head, excluding this record: two files,
  26 insertions, one deletion.

| ID | Severity | Outcome | Evidence |
| --- | --- | --- | --- |
| S1 | should | Fixed, awaiting recheck | Matching baseline-only recovery now succeeds. The empty-tree sync removes the journal after publication. |

The restart regression first failed with
`pending snapshot still requires recovery into its buffer`. After the recovery
fix, the test exposed a journal left behind by the empty-tree sync path.
The final fix publishes the baseline and removes its journal without changing
the text, modified flag, or undo entry count.

Validation on Neovim 0.12.6:

- Initial `make test`: 340 successes, no failures or errors.
- After S1, `make test`: 341 successes, no failures or errors.
- `make lint`: no problems found before or after the fix.
- Declined findings: none.
