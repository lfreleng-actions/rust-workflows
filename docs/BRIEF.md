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

State on 2026-10-09.

<!-- markdownlint-disable MD013 -->

| Stage        | Repository                  | State                                                                                                                            |
| ------------ | --------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| Metadata     | `build-metadata-action`     | Released v0.10.0 with Rust support                                                                                               |
| Lint         | `standalone-linting-action` | Released v0.7.0 with Rust toolchain preparation                                                                                  |
| Build        | `rust-build-action`         | Released v0.0.1; install-failure wording fix in review (#4)                                                                      |
| Test         | `rust-test-action`          | Released v0.0.1                                                                                                                  |
| Audit        | `rust-audit-action`         | Released v0.0.1                                                                                                                  |
| SBOM         | `sbom-action`               | Released v0.3.0 (`syft` reads `Cargo.lock`); Cargo backend in review (#53)                                                       |
| Scan         | `grype-scan-action`         | Released v0.2.0; Cargo graph classification planned (#31, after #25)                                                             |
| CBOM         | `cbom-action`               | No Rust coverage upstream; tracked in #10                                                                                        |
| Publish      | `rust-crate-publish-action` | Released v0.0.1; named registries (#12) and workspace sets (#13) merged for v0.1.0; semver checks in review (#11)                |
| Test fixture | `test-rust-project`         | Crate `lfreleng-test-rust-project` 0.1.0 on crates.io; fixture variants merged (#12); Trusted Publishing release in review (#11) |

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
| `toolchain`                                           | `''`                             | ✅    | ✅   | ✅    |         | Override the toolchain; empty uses the project's toolchain file                         |
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
compare what each job ran. The publisher reports `cargo_version` alone
and has no `toolchain` input: it pins whatever rustup selects for the
project, which honours `RUSTUP_TOOLCHAIN` (Q3 relies on that). It also
takes `registry`, to publish to a named Cargo registry, and, once #11
merges, `semver_checks`.

### Q3: One toolchain per run

**Decision:** each action resolves the toolchain once and pins it for
every later cargo, rustup and tool call by exporting
`RUSTUP_TOOLCHAIN`. The `toolchain` input overrides the resolution.
A release refuses a path toolchain (a local directory).

In the workflows, a `rust-metadata` job runs `build-metadata-action`
first, and every job that runs cargo waits for it. It resolves the
project toolchain, passes it to each later job through the same
`toolchain` input, and builds the test matrix (Q6) from it and
`rust_msrv`: the pattern the Python family uses for its interpreter
matrix.

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
- a moving channel (`stable`, `beta`, `nightly`): resolved through
  rustup to the exact release it points at (for example `1.90.0`, or a
  dated `nightly-YYYY-MM-DD`), so a release landing mid-run can't give
  two jobs different compilers;
- an exact version or dated toolchain: forwarded unchanged.

Because every job receives a non-empty `toolchain`, a caller's own
`RUSTUP_TOOLCHAIN` never decides what a job builds with. An override
also makes rustup ignore the project's toolchain file, so its
`components` and `targets` must come with it: `rust-metadata` forwards
`rust_toolchain_components` and `rust_toolchain_targets`, and the
build and test jobs pass them as `toolchain_components` and
`toolchain_targets`, which install them for the forwarded toolchain in
one rustup call. The audit compiles nothing and needs neither.

The publisher needs the same pin by another route, since it has no
`toolchain` input. In `crate-verify` and `publish`, the workflow
installs the resolved toolchain and sets `RUSTUP_TOOLCHAIN` to it on
the publisher step; the action resolves its toolchain through
`rustup show active-toolchain`, which honours that variable, and pins
the result for every cargo call. Both jobs must run the same Cargo,
because the archive digest `publish` checks depends on the Cargo
version that packaged it. Once the publisher gains a `toolchain` input,
the workflow passes it like any other action's.

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
rust-metadata -> build -> { tests | audit | sbom -> grype }
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
    recent stable minors, and `stable`).

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
- When the project commits no `Cargo.lock`, `build` resolves one and
  the workflow uploads it. `audit` and `sbom` restore it into their
  checkouts before running, so they read the dependency graph the
  build used. Syft reads `Cargo.lock` and runs no cargo, so without the
  handoff the SBOM, and the Grype scan of it, would miss every Rust
  dependency.

### Q7: Release job graph (Model A)

```text
tag-validate -> rust-metadata -> build
  -> { audit | sbom -> grype } -> tests
  -> crate-verify -> attach-artefacts -> promote-release
  -> publish (opt-in)
```

- As in Python, audits gate the test matrix on a release, and nothing
  reaches promotion past a failing gate.
- `build` runs with `package_crates: true` and, when the project ships
  binaries, `binaries: true`.
- `crate-verify` runs `rust-crate-publish-action` with `dry_run: true`
  and `release_tag` set. It checks the tag against the crate version,
  checks the archive size, compiles the packaged crate, and records the
  archive digest as `crate_sha256`. A version already on crates.io with
  identical content skips; different content fails the release.
- The publisher has no `setup_script` input, yet `crate-verify`
  compiles. When the caller sets `setup_script`, the workflow runs it
  as its own step first, in both models, with the same path validation
  and environment scrub the actions apply. The publish job never runs
  it: that job compiles nothing, so it needs no native libraries.
- `attach-artefacts` attaches the `.crate` files, binaries, SBOMs and a
  `SHA256SUMS` file to the draft release, with build provenance
  attestations when `attestations: true` and Sigstore signatures when
  `sigstore_sign: true` (both default `true`, as in Python; D3).
  Attesting needs
  `id-token: write` and `attestations: write`, so this job holds both
  when attestations are on. It runs no crate code: it downloads the
  artefacts, hashes and attests them, and uploads them, and never
  executes a downloaded binary.

### Q8: Merge job graph (Model B)

crates.io has no snapshots, and its versions are immutable, so Model B
changes shape for Rust:

```text
rust-metadata -> build -> snapshot (workflow artefact, dry run)
rust-metadata -> check-release
{ build | check-release } -> crate-verify -> publish -> tag
```

- Every merge builds, packages and dry-runs the publish, then uploads
  the result as a workflow artefact. That proves the merged commit is
  publishable without spending a crates.io version.
- A release happens when the merged change adds a release file under
  `releases/`. `check-release` requires the file's version to equal the
  crate version, `crate-verify` dry-runs it, `publish` uploads it, and
  the workflow then creates the matching tag.
- `crate-verify` waits for `build` as well as `check-release`, and both
  must succeed. Its own compile covers the packaged crate alone, not
  the workspace, targets or binaries `build` covers, so a failed build
  must stop the release.
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
| `sbom_enabled`, `sbom_include_dev`, `sbom_format`                 | sbom                  | `true`, `false` (no effect with the `syft` backend; Q13), `both`     |
| `grype_enabled`, `grype_fail_on`, `grype_permit_fail`             | grype                 | `true`, `medium`, `false` (falls back to `vars.NO_BLOCK_AUDIT_FAIL`) |
| `harden_runner_egress`, `harden_runner_allowlist`                 | harden-runner         | `block`, pinned organisation list                                    |
| `gerrit_refspec`, `gerrit_project`, `gerrit_branch`, `gerrit_url` | Gerrit-aware checkout | `''`                                                                 |
| `runners`                                                         | build, tests          | `[{"runner":"ubuntu-latest","arch":"x64"}]` (D4)                     |
| `cache`                                                           | build, tests          | `false` (D1)                                                         |
| `build_timeout_minutes`, `test_timeout_minutes`                   | build, tests          | `20`, `20` (D6)                                                      |
| `audit_timeout_minutes`                                           | audit, sbom, grype    | `10` (D6)                                                            |

<!-- markdownlint-enable MD013 -->

`runners` takes the same `{runner, arch}` objects as the Python
family's multi-architecture workflows: `runner` supplies `runs-on` and
`arch` names the artefacts. Arm64 runners such as `ubuntu-24.04-arm`
are free on public repositories, so a project adds that leg itself.

The release and merge workflows take the same inputs, except that
`lockfile_required` defaults to `true` (D5) and `cache` does not exist
(D1). The release workflow adds `attestations` (`true`),
`sigstore_sign` (`true`, D3), `publish_enabled` (`false`) and
`publish_environment` (`production`), and exposes the validated tag as
its `tag` output.

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

**Decision for the first release:** the `sbom` job uses
`sbom-action`'s `syft` backend, which reads `Cargo.lock`, and `grype`
scans its JSON output.

Syft's lockfile reading lists every locked crate, including those that
serve tests, build scripts or other platforms alone, and records no
dependency scope. sbom-action #53 adds a `cargo` dependency manager to
its `cyclonedx` backend, driving `cargo-cyclonedx`, which describes the
graph Cargo resolves, anchored on the crate, with one merged document
for a workspace root. It never lists dev-dependencies (the tool has no
option for them); `include_dev: true` keeps build-dependencies, marked
`scope: excluded`. Once a release carries it, the workflows switch
their SBOM to that backend.

Grype gating by provenance (grype-scan-action #25) trusts a dependency
graph from a measured generator and from no other. The
measurements in #31 show that `cargo-cyclonedx` alone misclassifies a
sibling workspace member's dependencies as inherited. The planned rule
counts a component as part of the project unless its `bom-ref` names a
registry or Git source, so an unknown shape gates rather than passes.

The Python family's CBOM job has no Rust counterpart: CBOMkit and
sonar-cryptography do not analyse Rust (cbom-action #10). The Rust
lanes add one once upstream support exists.

### Q14: Examples and self-test

- `examples/{build-test,build-test-release,merge}/{github,gerrit}.yaml`,
  heavily commented, pinned to a placeholder SHA with a `# vX.Y.Z`
  comment, as in Python.
- `testing.yaml` calls the reusable workflows by self-repository path
  on `pull_request` and `workflow_dispatch`, against `test-rust-project`
  and its fixture variants under `variants/`: `workspace`,
  `no-lockfile`, `msrv`, `dependencies`, `native` (through
  `setup_script`) and `features`, each selected through `path_prefix`.
- `testing.yaml` does not exercise the release lane's publish path:
  nobody can take a crates.io version back. `test-rust-project`'s own
  tag releases exercise it instead.

### Q15: Delivery

Each lane lands as its own pull request against this repository, in
this order, each with atomic signed commits:

1. This brief (merged).
2. Verify lane: `build-test.yaml`, its examples and `testing.yaml`
   (#4).
3. Release lane (Model A): `build-test-release.yaml` and examples (#5).
   `test-rust-project` then swaps its own release jobs for a caller of
   this lane, which proves Trusted Publishing through a reusable
   workflow.
4. Merge lane (Model B): `merge.yaml` and examples (#6).

Every action the lanes pin has a release, and a maintainer has settled
the design decisions below, so work on the verify lane can start.

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

| Repository                  | Item                                                         | State                                                     |
| --------------------------- | ------------------------------------------------------------ | --------------------------------------------------------- |
| `rust-workflows`            | Epic #8; lanes #4, #5, #6                                    | Verify lane next                                          |
| `rust-crate-publish-action` | Workspace sets (#8), named and staging registries (#9)       | Merged; release v0.1.0 pending                            |
| `rust-crate-publish-action` | Semver checks before a release (#10)                         | In review (#11)                                           |
| `rust-build-action`         | `cargo auditable` builds (#3)                                | Released in v0.0.1                                        |
| `test-rust-project`         | Fixture variants (#9)                                        | Merged                                                    |
| `test-rust-project`         | Trusted Publishing releases (#10)                            | In review (#11); later moves onto the release lane        |
| `sbom-action`               | `cargo` dependency manager for the `cyclonedx` backend (#51) | In review (#53)                                           |
| `grype-scan-action`         | Classify Cargo dependency graphs (#31)                       | Measured and planned; lands after #25 and sbom-action #53 |
| `cbom-action`               | CBOM coverage for Rust (#10)                                 | No upstream support; waiting on CBOMkit                   |
| `nexus-publish-action`      | Nexus Cargo repositories for snapshots (#185)                | Not available on LF Nexus; snapshots stay artefacts (Q8)  |

<!-- markdownlint-enable MD013 -->
