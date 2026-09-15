# Upstream integration

This fork takes upstream [kunchenguid/firstmate](https://github.com/kunchenguid/firstmate) changes on a recurring schedule.
This page is the maintainer checklist for one integration run; the fork's invariants themselves are listed in [README.md](../README.md) under "Personal fork: what differs".

## Contract

- Integrate on a disposable branch based on the fork's published `origin/main`, never in an operational installation.
- Merge `upstream/main` with a real merge that preserves upstream ancestry, and record the full upstream source commit.
- Land the pull request with a merge commit, never squash or rebase: a squashed integration leaves the installation's commits outside remote ancestry, and the updater then refuses to fast-forward.
- Resolve conflicts by preserving every fork invariant first, taking upstream fixes and tests that do not depend on a dropped dependency second, and preferring the fork's native design where upstream built an alternative, porting only what upstream does better.
- Merge approval stays with the fork owner, and an installation is reconciled only after the merge lands.

## Checklist

1. Fetch `origin` and `upstream`, branch from `origin/main`, and before merging record three commits: `git merge-base origin/main upstream/main` (the upstream commit the previous integration merged), `git rev-parse upstream/main`, and `git rev-parse origin/main`.
2. Run `git merge --no-ff upstream/main`.
   A fully automatic merge still gets every step below; a clean textual merge is the case most likely to hide a semantic break.
3. Run the call-site scan with the three commits recorded in step 1, before any test:

   ```sh
   bin/fm-upstream-callsite-scan.sh <merge-base> <upstream/main> <origin/main>
   ```

   It lists helpers whose definition line upstream changed and every fork-only line that calls one of them.
   Read each reported caller against upstream's new definition, fix any caller whose convention changed, and account for every reported call site in the pull request body.
   The script's `--help` owns the exact matching rules and their limits.
4. Verify the fork's dropped dependencies stay dropped and review what upstream changed under the opt-in: `git grep -n -E 'gh-axi|lavish-axi|chrome-devtools-axi|no-mistakes' -- bin .agents/skills AGENTS.md README.md`, and account for every new hit upstream introduced.
   gh-axi, chrome-devtools-axi, and lavish-axi stay dropped, while `no-mistakes` is an optional opt-in through `config/no-mistakes`, so an upstream change to its pipeline can now belong in the fork instead of being stripped.
5. Check that README "Personal fork: what differs" and `AGENTS.md` section 7 still describe the fork, and look for fork-tuned values inside upstream-owned files that an upstream test now pins.
6. Run `bin/fm-test-run.sh --changed` and `bin/fm-test-run.sh --check-coverage`, then each portable lane from `bin/fm-test-run.sh --list-lanes`, and `bin/fm-lint.sh`.
7. Open the pull request against the fork with `gh pr create --repo lmuehleisen/firstmate --base main`, always passing `--repo` because this checkout also carries the upstream remote.
   Its body states the upstream source commit, that a merge commit is required, every conflict and its resolution, every upstream change dropped or adapted, the call-site scan result, the invariant evidence, and the test results.
