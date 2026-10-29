# Quirky's Electrobun fork

This fork carries the native APIs Quirky needs that upstream Electrobun doesn't have yet. Every
patch is temporary: it goes upstream as its own PR and leaves this fork once upstream merges it.
The approved design is Quirky's
`docs/quirk/specs/2026-10-29-electrobun-fork/logic.md`.

This branch, `quirky`, holds only fork tooling. The Electrobun source lives on the other branches.

## Branches and tags

| Name | What it is |
| --- | --- |
| `v2.0.5` | The upstream stable tag the fork builds on. The fork never follows upstream `main` or betas. |
| `patch/<name>` | One patch, cut from the base tag and independent of every other patch, so it can become one upstream PR. |
| `quirky` | This branch: `patches.txt`, `bin/`, `workflows/`, `prs/` and the shared conflict resolutions in `rr-cache/`. |
| `unified/v2.0.5` | The unified build: the base tag, each listed patch merged in order, then a release commit. `bin/rebuild` regenerates it, so it's force-pushed and never edited by hand. |
| `v2.0.5-quirky.N` | An immutable release of the unified build, with the macOS arm64 devkit attached. |

## Writing a patch

1. Work in an Orca worktree of this repo on `patch/<name>`, cut from the base tag.
2. Implement macOS. On Linux and Windows the feature must report itself unsupported, never act
   as a silent no-op.
3. Add a test that fails without the patch. The release workflow runs every listed patch's test,
   because an upstream change can break a patch with no conflict and no compile error.
4. Every patch commit message ends with these trailers:

   ```
   Patch-Reason: upstream | quirky-only
   Quirky-Item: <queue item id>
   Upstream-PR: <url, once it exists>
   ```

5. Build a private test version and run Quirky against it:

   ```sh
   ~/PycharmProjects/PERSONAL/electrobun/bin/test-devkit
   ```

   Run it from the patch worktree. It builds the base tag plus your patch as
   `<base>-quirky.0-<name>` and prints the pin and the `HUTCH_ELECTROBUN_DEVKIT_ROOT` value for
   the Quirky worktree. That version shape can never be released.

## Landing a patch in the unified build

```sh
~/PycharmProjects/PERSONAL/electrobun/bin/land patch/<name> '<test command>'
```

`land` takes the fork lock, adds the patch and its test command to `patches.txt`, commits
`prs/<name>.md` if you wrote one, and runs `bin/rebuild`. The test command runs from the repo root
of the unified build.

A conflict with a patch already listed is yours to resolve. `rebuild` stops in the integration
worktree and prints its path. Resolve there, `git commit --no-edit`, then run
`bin/rebuild --continue`. `git rerere` records the resolution, and `rebuild` saves it in
`rr-cache/`, so later rebuilds replay it. To back out instead, run `bin/rebuild --abort`, which
removes your line from `patches.txt` and releases the lock. Your patch branch always stays based
on the tag.

## Releasing

```sh
bin/release
```

`release` tags the unified build `v<base>-quirky.N` from its package version and pushes the patch
branches, `unified/<base>` and the tag. The `quirky-release` workflow then builds the devkit on a
macOS arm64 runner, runs every patch test and attaches `electrobun-core-darwin-arm64.tar.gz` to the
release. It refuses any tag that isn't `v<x.y.z>-quirky.<N>` with N of 1 or more.

Releases are incremental, one per landed patch. Each release holds every patch listed before it.

## How Quirky uses a release

Quirky pins the release in `apps/desktop/hutch.config.ts`, for example `version: '2.0.5-quirky.2'`,
and sets `HUTCH_ELECTROBUN_DEVKIT_ROOT` to the extracted devkit. Hutch refuses to prepare when the
pin and the devkit version differ, and fails when the variable isn't set, so Quirky can't fall back
to stock Electrobun.

## Moving to a new upstream release

When upstream cuts a stable release, say `v2.0.6`:

1. Drop every patch upstream merged from `patches.txt`. Keep its branch for history.
2. Rebase each remaining patch onto `v2.0.6`, then compare old and new with
   `git range-diff v2.0.5..<old-sha> v2.0.6..patch/<name>`.
3. Run `bin/rebuild v2.0.6`, then `bin/release`. The first release is `v2.0.6-quirky.1`.
   The `unified/v2.0.5` branch and its releases stay as they are.

## Remotes

`origin` is this fork. `upstream` is `blackboardsh/electrobun`, with pushing disabled. Upstream
PRs open from `patch/<name>` branches after the user reviews them. Their text lives in `prs/`.
