<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 The Linux Foundation
-->

# Design Brief: Reusable Rust Workflows

This document records the design contract for the reusable workflows in
this repository and for the Rust actions they compose. It follows the
shape of the `python-workflows` brief: the goal, each design question,
the decision reached, and the questions still open. Where a decision
matches the Python family, this brief says so and does not repeat the
reasoning.

## Goal

Give Rust projects in the Linux Foundation the same toolkit the Python
and Java families already have: a set of single-purpose actions, and
reusable workflows that compose them into verify, release and merge
pipelines. Each pipeline has a plain GitHub caller and a Gerrit-wrapped
caller.

The toolkit must:

- match the Python family's input names, defaults and job graph
  wherever Rust has a counterpart, so a maintainer who knows one family
  can read the other;
- expose Rust's own strengths (toolchain files, workspaces, features,
  targets, MSRV, `cargo deny`, Trusted Publishing to crates.io) rather
  than hiding them behind the lowest common denominator;
- let a caller switch each stage on or off, and tune it, without
  forking the workflow.

## Building blocks

State on 2026-10-17.

<!-- markdownlint-disable MD013 -->

| Stage        | Repository                  | State                                                                                                 |
| ------------ | --------------------------- | ----------------------------------------------------------------------------------------------------- |
| Metadata     | `build-metadata-action`     | Released v0.10.0 with Rust support                                                                    |
| Lint         | `standalone-linting-action` | Released v0.7.0 with Rust toolchain preparation                                                       |
| Build        | `rust-build-action`         | Released v0.1.0: `version` input for tag-based versioning                                             |
| Test         | `rust-test-action`          | Released v0.0.1                                                                                       |
| Audit        | `rust-audit-action`         | Released v0.0.1                                                                                       |
| SBOM         | `sbom-action`               | Released v0.5.0: `cyclonedx` backend with a `cargo` dependency manager and feature selection          |
| Scan         | `grype-scan-action`         | Released v0.4.0: dependency policy, Cargo graph classification                                        |
| CBOM         | `cbom-action`               | Released v0.0.1; no Rust coverage upstream (#10), so the lanes scan other languages alone             |
| Publish      | `rust-crate-publish-action` | Released v0.3.0: named registries, workspace sets, semver checks, `toolchain` and `version` inputs    |
| Test fixture | `test-rust-project`         | Crate `lfreleng-test-rust-project` 0.1.2 on crates.io, published through Trusted Publishing; variants |

<!-- markdownlint-enable MD013 -->

## Decisions

### Q1: No dedicated lint action

**Decision:** Rust linting runs through `standalone-linting-action`,
not a new `rust-lint-action`. Projects declare `cargo fmt` and
`cargo clippy --workspace` as `language: system` hooks in their
`.pre-commit-config.yaml`; the action prepares the toolchain that
`rust-toolchain.toml` names before `prek` runs them.

prek's `language: rust` ignores `rust-toolchain.toml` and installs its
own toolchain, which would lint with a compiler the project never
builds with. The `language: system` form runs the project's own cargo.

The reusable workflows in this repository do not lint. As in the
Python family, linting belongs to the organisation's separate linting
workflow, which runs on every repository whatever its language.

### Q2: Shared action semantics

Where two Rust actions accept the same input, it has the same name,
default and meaning. Not every action needs every input: the audit
reads the whole lockfile and compiles nothing, so it takes no package,
feature or component selection.

<!-- markdownlint-disable MD013 MD060 -->

| Input                                                 | Default                          | Build | Test | Audit | Publish | Meaning                                                                                 |
| ----------------------------------------------------- | -------------------------------- | ----- | ---- | ----- | ------- | --------------------------------------------------------------------------------------- |
| `path_prefix`                                         | `.`                              | ✅    | ✅   | ✅    | ✅      | Directory holding the project; must stay inside the workspace and must not be a symlink |
| `manifest_path`                                       | `Cargo.toml`                     | ✅    | ✅   | ✅    | ✅      | Manifest, relative to `path_prefix`; same containment rules                             |
| `workspace`                                           | `true`                           | ✅    | ✅   |       | ✅ ¹    | Act on every workspace member (`--workspace`)                                           |
| `packages`                                            | `''`                             | ✅    | ✅   |       | ✅      | Named packages; a non-empty value replaces `--workspace`                                |
| `exclude`                                             | `''`                             | ✅    | ✅   |       | ✅      | Members to skip; needs `workspace: true` and empty `packages`                           |
| `features` / `all_features` / `no_default_features`   | `''` / `false` / `false`         | ✅    | ✅   |       |         | Cargo feature selection                                                                 |
| `toolchain`                                           | `''`                             | ✅    | ✅   | ✅    | ✅      | Override the toolchain; empty uses the project's toolchain file                         |
| `toolchain_components` / `toolchain_targets`          | `''` / `''`                      | ✅    | ✅   |       |         | rustup components and targets to install for the resolved toolchain                     |
| `lockfile_required`                                   | `false`                          | ✅    | ✅   | ✅    |         | Fail when `Cargo.lock` is absent, and build with `--locked`                             |
| `setup_script`                                        | `''`                             | ✅    | ✅   |       |         | Committed script run before cargo (system packages, native libraries)                   |
| `permit_fail`                                         | `false`                          |       | ✅   | ✅    | ✅      | Report failure without failing the step                                                 |
| `summary`                                             | `true`                           | ✅    | ✅   | ✅    | ✅      | Write a job summary                                                                     |
| `artefact_upload` / `artefact_name` / `artefact_path` | `true` / per action / per action | ✅    | ✅   | ✅    |         | Upload reports and outputs as a workflow artefact                                       |

<!-- markdownlint-enable MD013 MD060 -->

¹ The publisher defaults `workspace` to `false`, so a v0.0.1 caller
still publishes the one package `manifest_path` names; the workflows
set it explicitly.

Booleans are strict: anything other than `true` or `false` fails the
step, so a typo cannot flip a default.

The build, test and audit actions report `toolchain`, `toolchain_kind`,
`cargo_version` and `rustc_version` outputs, so a workflow can show and
compare what each job ran. The publisher reports `cargo_version` and,
from v0.2.0, `toolchain`, and takes a `toolchain` input like the
others. It also takes `registry`, to publish to a named Cargo registry,
and `semver_checks`.

### Q3: One toolchain per run

**Decision:** each action resolves the toolchain once and pins it for
every later cargo, rustup and tool call by exporting
`RUSTUP_TOOLCHAIN`. The `toolchain` input overrides the resolution.
A release refuses a path toolchain (a local directory).

In the workflows, a `rust-metadata` job runs `build-metadata-action`
first, and every job that runs cargo waits for it. It lives in its own
reusable workflow, `rust-metadata.yaml`, which each lane calls through
the self-repository form (`$/`), so the three lanes can't drift. It
resolves the project toolchain, passes it to each later job through
the same `toolchain` input, and builds the test matrix (Q6) from it and
`rust_msrv`: the pattern the Python family uses for its interpreter
matrix. `build-metadata-action` reads `[workspace.package]` from the
selected manifest alone, so when `path_prefix` or `manifest_path`
selects a workspace member that inherits `rust-version`,
`rust-metadata` reads the value from the workspace root, found as
Cargo finds it, and builds the `full` matrix from it the same way.

`rust-metadata` also lists the crates the release and merge lanes
publish. It asks Cargo (`cargo metadata --no-deps`, scrubbed, run in
`path_prefix`) rather than `build-metadata-action`, because Cargo
resolves every member's inherited `version` and `publish` settings
even when `path_prefix` or `manifest_path` points at a member
directory, where a manifest read alone misses them and would report
nothing to publish. It keeps the members crates.io accepts, then
applies `packages`, else `workspace` with `exclude`, else the selected
manifest's own package, as the publisher selects them; package lists
split on any whitespace, newlines included.

`build-metadata-action` reports the channel the project names
(`rust_toolchain_channel`), not a compiler version, and nothing when
the project names none. `rust-metadata` turns that into one exact
toolchain for the whole run:

- no toolchain selected at all (`rust_toolchain_kind: none`):
  `stable`, the runner's rustup default. A toolchain file that rustup
  rejects also reports `none`, so when a file exists `rust-metadata`
  asks rustup to read it first, and fails the run on a rejected file
  rather than replace it with `stable`;
- a path toolchain (`rust_toolchain_kind: path`): the run fails, in
  every lane, naming the `toolchain` input as the way to choose a
  channel instead. A path names a directory on the developer's machine,
  which no runner has, and substituting `stable` for it would hide the
  mismatch;
- a moving channel (`stable`, `beta`, `nightly`, or a minor such as
  `1.90`): resolved through its channel manifest on
  `static.rust-lang.org` to the exact release it points at (for
  example `1.90.0`, or a dated `nightly-YYYY-MM-DD`), so a release
  landing mid-run can't give two jobs different compilers;
- an exact version or dated toolchain: forwarded unchanged;
- a host suffix (`stable-x86_64-unknown-linux-gnu`): checked against
  the hosts that release ships for, then dropped, so each platform in
  `runners` installs its own host's build; an unknown host, such as a
  typo, fails the run;
- any other name, such as a toolchain linked on a developer's machine:
  the run fails, since no runner has it.

The test legs resolve the same way, so the MSRV leg runs the latest
patch of the declared minor.

Because every job receives a non-empty `toolchain`, a caller's own
`RUSTUP_TOOLCHAIN` never decides what a job builds with. An override
also makes rustup ignore the project's toolchain file, so its
`components` and `targets` must come with it: `rust-metadata` forwards
`rust_toolchain_components` and `rust_toolchain_targets`, and the
build and test jobs pass them as `toolchain_components` and
`toolchain_targets`, which install them for the forwarded toolchain in
one rustup call. The audit compiles nothing and needs neither.

The publisher takes the same pin through its `toolchain` input. In
`crate-verify` and `publish`, the workflow passes it the resolved
toolchain, which the action installs when missing, from outside the
checkout and with its own environment scrub, and pins for every cargo
call. Both jobs must run the same Cargo, because the archive digest
`publish` checks depends on the Cargo version that packaged it.

The action installs a minimal toolchain, without the toolchain file's
`components` and `targets`. `crate-verify` compiles the packaged
crates, so when the file lists either, the workflow installs them for
the resolved toolchain first, in one scrubbed `rustup` call from
outside the checkout. A project whose `.cargo/config.toml` selects a
target from that list then verifies as it builds. `publish` compiles
nothing and needs neither.

### Q4: Environment scrub (defence in depth)

**Decision:** before every cargo, tool, rustup and `setup_script` call,
each action removes these variables from the child environment:

- `CARGO_REGISTRY_TOKEN` and every `CARGO_REGISTRIES_<NAME>_TOKEN`;
- `ACTIONS_ID_TOKEN_REQUEST_TOKEN`, `ACTIONS_ID_TOKEN_REQUEST_URL`,
  `ACTIONS_RUNTIME_TOKEN`;
- `GITHUB_OUTPUT`, `GITHUB_ENV`, `GITHUB_PATH`, `GITHUB_STATE`,
  `GITHUB_STEP_SUMMARY`.

Build scripts and proc macros run arbitrary code from every dependency.
The scrub stops that code from reading a registry token or an OIDC
request token, and from writing step outputs or environment files that
later steps trust.

One call is exempt by design: the publisher's upload. Publishing needs
the registry token, so `rust-crate-publish-action` hands it to a single
`cargo publish --no-verify` subprocess, run from a trusted directory
outside the project. Cargo can't upload a prebuilt archive: that call
repackages from the sources, and `--no-verify` skips the verification
build, so it runs no crate code. The checks that make this safe happen
first, in scrubbed calls: the publisher packages the crate, compares
its digest with `expected_sha256` or with the verified archive, then
repackages without running crate code and requires byte-identical
output. The token-bearing call relies on those checks; it doesn't
perform them. An implementation of Q4 elsewhere must not strip the
token from that one call.

The scrub is defence in depth, not a security boundary. Job separation
is the boundary: the workflows never give a job that compiles or runs
crate code the `id-token: write` permission or a registry credential
(see Q9).
Findings that need a hostile process already running as the runner user
fall outside what an action can defend against.

### Q5: Workflow inventory and naming

**Decision:** three reusable workflows, each `on: workflow_call`,
matching the template's names:

<!-- markdownlint-disable MD013 -->

| File                      | Purpose                                     | Release model |
| ------------------------- | ------------------------------------------- | ------------- |
| `build-test.yaml`         | Verify: pull requests and Gerrit patch sets | none          |
| `build-test-release.yaml` | Tag-driven release                          | Model A       |
| `merge.yaml`              | Merge-driven publish                        | Model B       |

<!-- markdownlint-enable MD013 -->

There are no `-multiarch` files (D4): every lane takes a `runners`
matrix instead (Q10).

### Q6: Verify job graph

```text
gerrit-validate -> { repository-metadata | rust-metadata }
rust-metadata -> build -> { tests | audit | sbom -> grype | cbom }
```

- `repository-metadata` stays informational and gates nothing.
- `tests`, `audit` and `sbom -> grype` run in parallel after `build`;
  none gates another, so a pull request surfaces every failure at once.
- `tests` runs as a matrix that `rust-metadata` builds, chosen by
  `test_matrix`:
  - `project`: one leg, on the project toolchain;
  - `msrv` (default): the project toolchain plus the declared
    `rust-version`, one leg when they match or the project declares
    none;
  - `full`: the project toolchain plus every version in
    `build-metadata-action`'s `rust_matrix_json` (the MSRV, up to six
    recent stable minors, and `stable`). Every leg resolves to an
    exact release first, so two entries naming one release, such as
    `1.99` and `stable`, share a leg.

  The project toolchain always has a leg, so a pinned or nightly
  toolchain is never left out.
- Each job checks out the source itself. Rust tests and audits work
  from source, not from the build's outputs; the build artefact exists
  for releases and for callers.
- `build` and `tests` run once per entry in `runners` (D4); `tests`
  multiplies that by the toolchain matrix. `audit`, `sbom` and `grype`
  run once: the lockfile they read is the same on every platform.
- With `cache: true` (D1), `build` and `tests` restore and save a
  Cargo cache. The release and merge lanes never restore one, so no
  cache written by a pull request can reach a published crate.
- When the project commits no `Cargo.lock`, `rust-metadata` resolves
  one with `cargo generate-lockfile` and uploads it, and `build`,
  `tests`, `audit` and `sbom` restore it into their checkouts. Every
  job then reads the dependency graph the build used. Without the
  handoff, `sbom-action` would resolve a lockfile of its own, and the
  SBOM, with the Grype scan of it, could describe a graph the build
  never compiled. Resolving a
  lockfile reads the registry index and runs no crate code; Cargo picks
  a lockfile format the declared `rust-version` can read, so the MSRV
  leg reads it too.
- The `sbom` job records whether the change touched `Cargo.toml`,
  `Cargo.lock` or Cargo configuration, comparing the commit under test
  with its first parent, in a `dependency-change.json` sidecar beside
  the SBOM. With `grype_gate_when: dependencies-changed`, Grype gates
  when that answer is yes, treats a missing answer as yes, and
  otherwise reports its findings as warnings.
- `cbom` is advisory (Q13).

### Q7: Release job graph (Model A)

```text
tag-validate -> rust-metadata -> build
  -> { audit | sbom -> grype } -> tests
  -> crate-verify -> attach-artefacts -> publish (opt-in)
  -> promote-release
```

- As in Python, audits gate the test matrix on a release, and nothing
  reaches promotion past a failing gate. A gate the caller switched
  off counts as passed; one that was on and skipped does not.
- `tag-validate` requires a signed SemVer tag that is not a
  pre-release, and fails when the tag already has a published release,
  which immutable releases could no longer change. It resolves the
  tag to its commit, and every later job builds that commit, so a
  caller can't release other source under a valid tag; a `ref`
  naming another commit fails the run. `tag_enforce_increment`,
  `tag_require_branch` and `tag_require_latest` add the ordering and
  branch checks `tag-validate-action` offers. The lane
  leaves out its `require_recent` check: a three-minute window makes
  every later re-run of the validation fail.
- `build` checks the tag against every publishable crate's version
  before compiling, so a mis-tag fails in seconds. The first platform
  runs with `package_crates: true`; with `binaries: true`, every
  platform collects its binaries.
- `crate-verify` runs `rust-crate-publish-action` with `dry_run: true`
  and `release_tag` set. It checks the tag against the crate version,
  checks the archive size, compiles the packaged crate, and records the
  archive digest as `crate_sha256`. A version already on crates.io with
  identical content skips; different content fails the release. It
  doesn't run for a project with no publishable crate, whose release
  carries binaries and SBOMs alone.
- The publisher has no `setup_script` input, yet `crate-verify`
  compiles. When the caller sets `setup_script`, the workflow runs it
  as its own step first, in both models, with the same path validation
  and environment scrub the actions apply. That step installs the
  resolved toolchain first and selects it through `RUSTUP_TOOLCHAIN`,
  since the script may call cargo. The publish job never runs
  it: that job compiles nothing, so it needs no native libraries.
- `attach-artefacts` drafts the release when release-drafter has not,
  and attaches the `.crate` files, binaries, SBOMs and a `SHA256SUMS`
  file, with build provenance attestations (`actions/attest`, over
  `SHA256SUMS`) when `attestations: true` and a cosign Sigstore bundle
  beside each asset when `sigstore_sign: true` (both default `true`,
  as in Python; D3). It requires each `.crate` from the build to match
  `crate-verify`'s digest, so a release asset is byte-identical to the
  crates.io upload. Binaries gain their platform's `arch`, so platforms
  can't clash. Attesting and signing need `id-token: write` and
  `attestations: write`, so this job holds both. It runs no crate code:
  it downloads the artefacts, hashes, attests, signs and uploads them,
  and never executes a downloaded binary.
- `publish` runs before `promote-release`, so a failed upload leaves a
  draft rather than a public release without its crates.
- With `dry_run: true` and a `tag`, the lane rehearses a release on an
  existing tag: it validates, builds, tests, audits and verifies, then
  drafts, attests, signs, publishes and promotes nothing. It uploads
  the assets it would have attached as a `release-assets` artefact
  instead. The self-test uses this mode.

**Versioning.** The maintainer chose tag-based versioning (Option A)
alongside the manifest versioning the lane started with, through
`version_source`:

- `manifest` (the default): the tag must equal the version each
  publishable `Cargo.toml` declares.
- `tag`: every workspace member keeps the placeholder `0.0.0`, and the
  tag supplies the version. `rust-build-action` v0.1.0 (#11) and
  `rust-crate-publish-action` v0.3.0 (#21) take it as `version` and
  write it over the placeholder in `Cargo.toml` and `Cargo.lock`
  before compiling, byte for byte alike, so the archive `build`
  packages still equals the one `crate-verify` records. Each action
  refuses a workspace member that doesn't carry `0.0.0`, and the
  `build` job refuses a publishable one before compiling anything.

Under `tag` the tests, audit and SBOM still read the committed
checkout, so the SBOM names the project's own crates at `0.0.0`
(sbom-action #68). Manifest-versioned releases through the merge lane
(Option B) come later; Model B keeps reading the release file's
version.

### Q8: Merge job graph (Model B)

crates.io has no snapshots, and its versions are immutable, so Model B
changes shape for Rust:

```text
resolve-commit -> check-release -> rust-metadata -> build
  -> { tests | audit | sbom -> grype }
  -> crate-verify -> publish -> tag
```

- Every merge builds, packages, tests, audits and scans the merged
  commit, and dry-runs the publish. The packaged crates stay in the
  build's workflow artefact: the merge's snapshot. That proves the
  merged commit publishable without spending a crates.io version, and
  the full Grype scan catches CVEs published since the pull request
  (grype-scan-action #10, phase 3).
- A release happens when the merged change adds one YAML file directly
  under `releases/`, a regular file with a single top-level
  `version: X.Y.Z`: a final release with no pre-release or build
  part, as Model A requires of its tags. On a GitHub push,
  `check-release` looks at every commit the push added, so a batched
  push or a rebase merge can't hide a release file in an earlier
  commit; on a Gerrit dispatch it compares the merged commit with its
  first parent. `crate-verify`
  passes `v<version>` as the publisher's `release_tag`, which requires
  every crate version to equal it; `publish` uploads; and the `tag` job
  then creates `v<version>` on the merged commit.
- `check-release` records the merged commit once, and every later
  job checks out that commit on both checkout paths. The version
  check, the build, the gates and the upload then all act on one
  commit, and a later merge can't hide this one's release file.
- A Gerrit dispatch names a branch, which a later merge can move
  before the run starts, so `resolve-commit` asks Gerrit, not the
  mirror, which commit merged the change, as node-workflows does.
  The caller forwards `GERRIT_PATCHSET_REVISION` as
  `gerrit_patchset_revision`, and the job maps that revision to the
  commit Gerrit put on the branch. A dispatch that starts after a
  later merge then still checks out its own commit and finds its own
  release file. By submit type:
  - Fast forward, or a rebase if necessary that needed no rebase: the
    revision sits on the branch's first-parent history, and the run
    checks it out.
  - Merge if necessary, merge always: when Gerrit writes a merge
    commit, the run checks out the oldest first-parent commit that
    descends from the revision, its merge. `check-release` compares
    that merge with its first parent, so the release file the change
    adds still counts.
  - Rebase if necessary, rebase always, cherry pick: Gerrit writes a
    new commit. The run resolves it when the dispatcher forwards that
    commit's revision. A revision missing from the branch, such as
    the patch set before the rebase, fails the run: the lane won't
    build or publish code nobody merged.
- Without `gerrit_patchset_revision` the run checks out the branch
  tip, as before, and emits a notice naming the input; a later merge
  can then still hide this one's release file. A change ref in
  `gerrit_refspec` re-runs a merged change; an unmerged one fails the
  run.
- `crate-verify` waits for every gate as well as `check-release`, and
  every gate must pass, or the caller must have turned it off. Its own
  compile covers the
  packaged crate alone, not the workspace, targets or binaries `build`
  covers, so a failed build must stop the release.
- The `tag` job creates a lightweight tag through the GitHub API with
  `GITHUB_TOKEN`, so the tag starts no other workflow. It's idempotent
  on a re-run and fails rather than move a tag on another commit. No
  sibling lane tags yet, and signed tags remain a release-engineering
  decision (docker-workflows #110), so Gerrit projects set
  `create_tag: false` and tag in Gerrit, which replicates to the
  mirror.
- The publish job runs from the merged branch commit, before the tag
  exists, so its environment can't use Model A's tag rule. A
  Model B project restricts its `publish_environment` to the protected
  default branch instead, and registers the merge caller's file and
  that environment as a separate crates.io trusted publisher. A project
  running both models uses two environments.
- Per-merge output stays a workflow artefact. The Linux Foundation's
  Nexus 3 servers run releases older than the first with a Cargo
  format (3.73 Pro, 3.77 Community), and Nexus accepts Cargo uploads
  through `cargo publish` alone (nexus-publish-action #185). Should
  those servers move to a Cargo-capable release, snapshots would
  publish through `rust-crate-publish-action`'s `registry` input, as
  `X.Y.Z-SNAPSHOT.<n>`: the upper-case tag sorts below `alpha` and `rc`,
  and Cargo never selects a pre-release unless a dependency's version
  spec names one.

### Q9: Publishing, Trusted Publishing and secrets

crates.io Trusted Publishing validates the OIDC `workflow_ref` claim,
which names the **caller's** workflow file, not the reusable workflow
(`job_workflow_ref`). That differs from PyPI, which forced the Python
family to move publishing into the caller (its Q9 amendment).

**Decision:** the `publish` job lives inside the reusable workflow,
behind `publish_enabled` (default `false`):

- It runs in the environment named by `publish_environment` (default
  `production`). For Model A, restrict that environment to release
  tags with the pattern `v[0-9]*.[0-9]*.[0-9]*`: GitHub matches it with
  Ruby's `File.fnmatch`, which can't express SemVer in full, so
  `tag-validate` and the publisher's `release_tag` check enforce the
  exact form (Q8 covers Model B).
- It holds `id-token: write`, as `attach-artefacts` does for
  attestations, and like that job it runs no crate code. It exchanges
  the OIDC token through `rust-lang/crates-io-auth-action` and runs
  `rust-crate-publish-action` with `expected_sha256` from
  `crate-verify`; given a digest, the action packages with
  `--no-verify`, and a digest mismatch fails the publish.
- The reusable workflow takes no registry secret. Trusted Publishing
  replaces the token, and the crates.io setting "Require trusted
  publishing" rejects API tokens.
- A called workflow can't raise the permissions its caller grants, so
  the calling job must grant `contents: write`, `id-token: write` and
  `attestations: write`; the examples show it. Inside the reusable
  workflow, every job declares its own `permissions:` block, and no
  job but `attach-artefacts` and `publish` lists `id-token: write`. A job with
  its own block gets nothing beyond it, so the caller's broader grant
  never reaches a job that compiles.

The crates.io trusted publisher entry names the caller's file (for
example `build-test-release.yaml`) and the environment. The first
`test-rust-project` release through this workflow confirms the claim
handling in practice; if crates.io rejects it, the fallback is the
Python pattern, with the publish job in the caller.

### Q10: Input surface (curated middle)

The verify workflow passes through a curated set, as in Python. Names
match the Python family where the meaning matches.

<!-- markdownlint-disable MD013 -->

| Input                                                             | Feeds                 | Default                                                              |
| ----------------------------------------------------------------- | --------------------- | -------------------------------------------------------------------- |
| `repository`, `ref`                                               | checkout              | `''`                                                                 |
| `path_prefix`, `manifest_path`                                    | all Rust jobs         | `.`, `Cargo.toml`                                                    |
| `workspace`, `packages`, `exclude`                                | build, tests          | `true`, `''`, `''`                                                   |
| `features`, `all_features`, `no_default_features`                 | build, tests          | `''`, `false`, `false`                                               |
| `toolchain`                                                       | all Rust jobs         | `''` (project toolchain)                                             |
| `lockfile_required`                                               | all Rust jobs         | `false` (D5)                                                         |
| `setup_script`                                                    | build, tests          | `''`                                                                 |
| `target`, `profile`, `cargo_args`, `binaries`                     | build                 | `''`, `release`, `''`, `false`                                       |
| `tests_enabled`, `test_matrix`                                    | tests                 | `true`, `msrv`                                                       |
| `test_runner`, `test_args`, `doc_tests`                           | tests                 | `cargo`, `''`, `true`                                                |
| `coverage`                                                        | tests                 | `false`                                                              |
| `test_permit_fail`                                                | tests                 | `false`                                                              |
| `audit_enabled`, `audit_permit_fail`                              | audit                 | `true`, `false`                                                      |
| `audit_ignore_vulns`, `audit_allow_list_path`                     | audit                 | `''`                                                                 |
| `deny_enabled`, `deny_checks`                                     | audit (`cargo deny`)  | `false`, `advisories bans licenses sources`                          |
| `sbom_enabled`, `sbom_include_dev`, `sbom_format`                 | sbom                  | `true`, `false` (build-dependencies; Q13), `both`                    |
| `grype_enabled`, `grype_fail_on`, `grype_permit_fail`             | grype                 | `true`, `medium`, `false` (falls back to `vars.NO_BLOCK_AUDIT_FAIL`) |
| `grype_dependency_policy`, `grype_transitive_fail_on`             | grype                 | `all`, `none` (Q13)                                                  |
| `harden_runner_egress`, `harden_runner_allowlist`                 | harden-runner         | `block`, pinned organisation list                                    |
| `gerrit_refspec`, `gerrit_project`, `gerrit_branch`, `gerrit_url` | Gerrit-aware checkout | `''`                                                                 |
| `gerrit_patchset_revision` (merge lane)                           | resolve-commit        | `''` (Q8)                                                            |
| `runners`                                                         | build, tests          | `[{"runner":"ubuntu-latest","arch":"x64"}]` (D4)                     |
| `cache`                                                           | build, tests          | `false` (D1)                                                         |
| `build_timeout_minutes`, `test_timeout_minutes`                   | build, tests          | `20`, `20` (D6)                                                      |
| `audit_timeout_minutes`                                           | audit, sbom, grype    | `10` (D6)                                                            |
| `auditable`                                                       | build                 | `false`                                                              |
| `grype_gate_when`, `grype_only_fixed`, `grype_cache_db`           | grype                 | `always`, `false`, `true`                                            |
| `cbom_enabled`, `cbom_languages`, `cbom_timeout_minutes`          | cbom                  | `false`, `''`, `30` (Q13)                                            |
| `artefact_suffix`                                                 | every artefact name   | `''`                                                                 |

<!-- markdownlint-enable MD013 -->

`runners` takes the same `{runner, arch}` objects as the Python
family's multi-architecture workflows: `runner` supplies `runs-on` and
`arch` names the artefacts. Arm64 runners such as `ubuntu-24.04-arm`
are free on public repositories, so a project adds that leg itself.

`artefact_suffix` follows the Java family's `artifact_suffix`: a
workflow that calls one lane more than once in a run, such as a
monorepo verifying each crate, gives each call its own suffix so their
artefact names can't clash.

The verify lane's test, audit and Grype jobs fall back to the
`NO_BLOCK_AUDIT_FAIL` repository variable when their `permit_fail`
input is `false`, as the template does. The release and merge lanes
honour it for Grype alone, as Python does: a release should not pass a
failing test or audit because of a repository-wide switch.

The release and merge workflows take the same inputs, except that
`lockfile_required` defaults to `true` (D5), `cache` does not exist
(D1), and `grype_gate_when`, `grype_cache_db` and the CBOM inputs
belong to the verify lane alone: a release scan always gates and never
writes the database cache. Both add `semver_checks` (`false`),
`publish_enabled` (`false`), `publish_environment` (`production`) and
`dry_run` (`false`). The release workflow also adds `attestations`
(`true`), `sigstore_sign` (`true`, D3), `tag` (for a dry run) and the
`tag_*` policy inputs, and exposes `tag`, `crate_name`,
`crate_version`, `publish_status` and `release_url`. The merge workflow
adds `create_tag` (`true`) and exposes `has_release`, `version`,
`crate_name`, `crate_sha256`, `publish_status` and `tag`.

**Not exposed** (kept at action defaults, added on demand): tool
versions (`nextest_version`, `llvm_cov_version`,
`cargo_audit_version`, `cargo_deny_version`), `junit`,
`package_crates` (the release workflow sets it), `deny_warnings` and
`max_crate_size_bytes`.

### Q11: Gerrit-aware checkout and voting

Identical to the Python family: the four `gerrit_*` inputs switch each
checkout to `checkout-gerrit-change-action`; voting stays in the
`gerrit.yaml` wrapper, gated on `GERRIT_DISABLED`, which the verify
wrappers carry and the release wrappers don't. The reusable workflows
need no Gerrit secret.

### Q12: Harden-runner egress

Identical to the Python family: `block` by default, with the
organisation allow-list, which includes `crates.io`,
`index.crates.io` and `static.crates.io` from `.github` v0.16.3
onwards. Audit mode is an explicit opt-in, so a typo falls back to
`block`. Tool installs go through `taiki-e/install-action`, whose
downloads the allow-list also covers.

### Q13: SBOM and Grype

**Decision:** the `sbom` job uses `sbom-action`'s `cyclonedx` backend
with the `cargo` dependency manager (v0.4.0), and `grype` scans its
JSON output. The backend drives `cargo-cyclonedx`, which describes the
graph Cargo resolves for a directory, anchored on the crate: a
member's own graph, or one merged document for a workspace root. When
the lane acts on more than one member (`workspace: true`, or named
`packages`), the job scans the workspace root that `rust-metadata`
resolved, so the SBOM covers everything the build does; for a single
package it scans that manifest's directory. The job forwards
`features`, `all_features` and `no_default_features` as sbom-action's
`cargo_features`, `cargo_all_features` and `cargo_no_default_features`
(v0.5.0), so the SBOM describes the graph the build compiled, optional
dependencies included. The action also runs Cargo
in the directory it scans, so when the job scans the workspace root a
`.cargo/config.toml` under `path_prefix` doesn't apply: a member-local
source replacement or patch can make the SBOM step fail after a
build that succeeded. A working-directory input on sbom-action
(#66, in review as #67) fixes this. The SBOM never lists dev-dependencies (the
tool has no option for them);
`sbom_include_dev: true` keeps build-dependencies, marked
`scope: excluded`. The job keeps CycloneDX 1.5, the action's default
and the newest `cargo-cyclonedx` writes. The `syft` backend it replaces
read `Cargo.lock`, listing every locked crate, including those that
serve tests, build scripts or other platforms alone, with no scope.

The action pins no toolchain, so the job installs the run's resolved
toolchain from outside the checkout, with the scrub of Q4, and names
it to the SBOM step through `RUSTUP_TOOLCHAIN`.

The job sets `untrusted_checkout: 'false'`, as the Java lanes do.
Cargo treats a checkout as code: `.cargo/config.toml` can name a rustc
wrapper that `cargo metadata` executes, so the action's `auto` mode
skips fork pull requests and the SBOM would go missing on each one.
That guard buys nothing here: the `build` job has already compiled
this same checkout with the same token, scoped to `contents: read`.

Grype gating by provenance (grype-scan-action v0.4.0, #25 and #31)
trusts a dependency graph from a measured generator and from no other.
For `cargo-cyclonedx` output at CycloneDX 1.4 to 1.6 it counts a
component as part of the project unless its `bom-ref` names a registry
or Git source, so a sibling workspace member stays declared and an
unknown shape gates rather than passes.

The lanes expose the severity threshold, fixed-advisory filtering,
`permit-fail` and, on the verify lane, `gate-when` and `cache-db`.
They also expose the provenance controls as `grype_dependency_policy`
and `grype_transitive_fail_on`, at the action's defaults, `all` and
`none`: every finding gates, as before, until a project opts in. A
project that sets `grype_dependency_policy: declared` gates on the
crates it declares and reports inherited ones as warnings, and
`grype_transitive_fail_on: high` (for one) still gates an inherited
crate at that severity. No sibling family exposes these inputs yet, so
the names follow the lanes' `grype_` convention. `declared-source` and
`declared-dependencies` stay at the action's defaults: the Cargo graph
carries its own provenance. The action reads that graph from the JSON
SBOM, so with `sbom_format: xml` every finding counts as declared and
gates. A release or merge scan always gates,
whatever changed, under the policy the caller chose.

CBOM: `cbom-action` covers Java, Python and Go (C# in preview), and
CBOMkit and sonar-cryptography do not analyse Rust. Rust coverage
stays parked, and cbom-action #10, the investigation, stays closed,
until they do.
The verify lane carries the Python family's CBOM job, off by default
(`cbom_enabled: false`) and advisory, so a Rust project with Python
bindings or Go tooling can scan those sources; on a pure Rust project
the action's detection finds nothing and skips. The lane rejects
`cbom_languages: rust`, which the action would fail on. The default
changes once upstream support exists.

### Q14: Examples and self-test

- `examples/{build-test,build-test-release,merge}/{github,gerrit}.yaml`,
  heavily commented, pinned to a placeholder SHA with a `# vX.Y.Z`
  comment, as in Python.
- `testing.yaml` calls the reusable workflows by self-repository path
  on `pull_request` and `workflow_dispatch`, against `test-rust-project`
  at a pinned commit:
  - the verify lane against the root crate (two platforms, nextest,
    coverage, binaries and dependency-scoped Grype gating) and
    each fixture variant under `variants/`: `workspace`, `no-lockfile`,
    `msrv` (the `full` matrix), `dependencies`, `native` (through
    `setup_script`) and `features`, each selected through
    `path_prefix`. The root call also enables CBOM, which proves the
    job's wiring and its clean skip on a pure Rust project, not a
    scan;
  - the release lane with `dry_run: true` on the signed tag `v0.1.1`;
  - the merge lane with `dry_run: true`, on a commit that adds no
    release file, and again on the fixture's merge commit that adds
    `releases/workspace-0.1.0.yaml`, with `path_prefix:
    variants/workspace`. That version is the workspace variant's, whose
    publishable members carry names crates.io refuses, so the dry run
    always finds them absent. The dry runs need write and OIDC grants
    that `dry_run` never uses, so they run on fork pull requests
    (tokens without write access) and on manual runs of the default
    branch, and skip wherever unreviewed workflow changes on a branch
    of this repository would run with them;
  - a final job that checks the artefacts the lanes left: the resolved
    lockfile, the SBOM contents, the dependency-change sidecar, both
    platforms' binaries, the MSRV leg and the packaged crates. It also
    checks the merge calls' outputs: no release on the first, and on
    the second `has_release: true`, version `0.1.0`, and both
    publishable members, without the `publish = false` one, in
    `crate_name` from crate verification.
- `testing.yaml` does not exercise the publish path: nobody can take a
  crates.io version back. `test-rust-project`'s own tag releases
  exercise it instead. A CBOM scan
  waits on Rust support upstream (Q13): a fixture in another language
  would test cbom-action, not this lane.

### Q15: Delivery

The three lanes, the shared metadata workflow, their examples and the
self-test land together, in one pull request of atomic signed commits
(#4, #6, and #5 bar its last step), so the lanes share one tested
design from the first release. `test-rust-project` then swaps its own
release workflow for a caller of the release lane, which proves Trusted
Publishing through a reusable workflow and completes #5.

## Decisions D1 to D6

A maintainer settled these on 2026-10-09 (#7), accepting each
recommendation. D2 does not exist; the numbering follows the original
proposal.

<!-- markdownlint-disable MD013 -->

| ID  | Question           | Decision                                                                                                                                                                                                            |
| --- | ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| D1  | Caching            | An opt-in `cache` input (default `false`) on the verify lane alone, for `build` and `tests`. The release and merge lanes never restore a cache, so nothing a pull request writes can reach a published crate        |
| D3  | Signing            | Sigstore: build provenance attestations and Sigstore signatures on GitHub release assets, both on by default as in Python. crates.io stores no signatures, so the choice covers release assets alone                |
| D4  | Multi-architecture | A `runners` JSON matrix in each workflow, defaulting to one x64 leg; no `-multiarch` files. The Python split came from a structural difference (a separate metadata job) that every Rust lane has anyway            |
| D5  | Lockfile policy    | `lockfile_required` defaults to `false` on verify and `true` on release and merge. The publisher packages with `--locked`, so requiring the lockfile up front fails a release at its first job, not at publish time |
| D6  | Timeouts           | Python's per-job names: `build_timeout_minutes`, `test_timeout_minutes`, `audit_timeout_minutes`. Rust compiles slower, so build and tests start at 20 minutes; revisit after the first fixture runs                |

<!-- markdownlint-enable MD013 -->

## Follow-ups

<!-- markdownlint-disable MD013 -->

| Repository             | Item                                                                                                                                 | State                                                                    |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------ |
| `rust-workflows`       | Lanes #4, #6 (epic #8)                                                                                                               | Implemented; first release pending                                       |
| `rust-workflows`       | Release lane #5                                                                                                                      | Implemented; open until `test-rust-project` releases through it          |
| `rust-workflows`       | Check `releases/` files at verify time (docker parity #36)                                                                           | Open                                                                     |
| `sbom-action`          | Describe the version a tag-versioned release stamps, rather than the `0.0.0` placeholder (Q7, sbom-action #68)                       | Open                                                                     |
| `sbom-action`          | A Cargo working directory separate from the scanned manifest, so `path_prefix` keeps its `.cargo/config.toml` (Q13, sbom-action #66) | In review (sbom-action #67, after #65)                                   |
| `test-rust-project`    | Release through this repository's release lane (#5)                                                                                  | After the first release of this repository                               |
| `cbom-action`          | CBOM coverage for Rust (#10, closed)                                                                                                 | Parked until [CBOMkit](https://github.com/cbomkit/cbomkit) supports Rust |
| `nexus-publish-action` | Nexus Cargo repositories for snapshots (#185)                                                                                        | Not available on LF Nexus; snapshots stay artefacts (Q8)                 |

<!-- markdownlint-enable MD013 -->
