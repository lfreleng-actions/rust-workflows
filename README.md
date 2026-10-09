<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# 🦀 Rust Workflows

<!-- prettier-ignore-start -->
<!-- markdownlint-disable-next-line MD013 -->
[![Linux Foundation](https://img.shields.io/badge/Linux-Foundation-blue)](https://linuxfoundation.org/) [![Source Code](https://img.shields.io/badge/GitHub-100000?logo=github&logoColor=white&color=blue)](https://github.com/lfreleng-actions/rust-workflows) [![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0) [![pre-commit.ci status badge]][pre-commit.ci results page] [![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/lfreleng-actions/rust-workflows/badge)](https://scorecard.dev/viewer/?uri=github.com/lfreleng-actions/rust-workflows)
<!-- prettier-ignore-end -->

Reusable GitHub Actions workflows that build, test, audit, describe,
scan, release and publish Rust projects, in the Linux Foundation's
canonical pipeline shape. They compose the organisation's Rust actions
the way `python-workflows` composes the Python ones, with matching
input names wherever Rust has a counterpart.
[`docs/BRIEF.md`](docs/BRIEF.md) records the design and the reasons
behind it.

## Quick start

Copy a caller from [`examples/`](examples/) into your project's
`.github/workflows/`, replace the all-zero SHA with a release of this
repository, and uncomment the inputs you need:

<!-- markdownlint-disable MD013 -->

```yaml
jobs:
  build-test:
    permissions:
      contents: read
      pull-requests: read
      issues: read
    uses: lfreleng-actions/rust-workflows/.github/workflows/build-test.yaml@<sha>  # vX.Y.Z
    with:
      test_matrix: 'msrv'
      grype_gate_when: 'dependencies-changed'
```

<!-- markdownlint-enable MD013 -->

Every input is optional. A project with a `Cargo.toml` at its root, a
committed `Cargo.lock` and, optionally, a `rust-toolchain.toml` needs
none.

## Lanes

<!-- markdownlint-disable MD013 -->

| Workflow                                    | Purpose                                                        | Trigger             | Examples                                                       |
| ------------------------------------------- | -------------------------------------------------------------- | ------------------- | -------------------------------------------------------------- |
| `.github/workflows/build-test.yaml`         | Verify: build, test, audit, SBOM, Grype scan and optional CBOM | Pull request        | [`examples/build-test/`](examples/build-test/)                 |
| `.github/workflows/build-test-release.yaml` | Model A: tag-driven release, with opt-in crates.io publishing  | Release tag push    | [`examples/build-test-release/`](examples/build-test-release/) |
| `.github/workflows/merge.yaml`              | Model B: merge-driven, release-file triggered publishing       | Merge to `main`     | [`examples/merge/`](examples/merge/)                           |
| `.github/workflows/rust-metadata.yaml`      | Internal: shared toolchain, matrix and lockfile resolution     | Called by the lanes | none                                                           |

<!-- markdownlint-enable MD013 -->

Each lane has a GitHub-native caller (`github.yaml`) and a
Gerrit-wrapped caller (`gerrit.yaml`). Jobs in `{ }` run concurrently;
`->` denotes sequence:

```text
Verify:   rust-metadata -> build -> { tests | audit | sbom -> grype | cbom }

Release:  tag-validate -> rust-metadata -> build
            -> { audit | sbom -> grype } -> tests
            -> crate-verify -> attach-artefacts -> publish -> promote-release

Merge:    check-release -> rust-metadata -> build
            -> { tests | audit | sbom -> grype }
            -> crate-verify -> publish -> tag
```

### One toolchain per run

`rust-metadata` reads the project with `build-metadata-action` and
resolves one exact toolchain, which every job then uses:

- the `toolchain` input, when set, wins over the toolchain file;
- `rust-toolchain.toml` or `rust-toolchain` comes next;
- without either, the lane uses `stable`;
- a moving channel (`stable`, `beta`, `nightly`, or a minor such as
  `1.90`) resolves to the release it points at, such as `1.90.0` or
  `nightly-2026-10-08`, so a release landing mid-run can't give two
  jobs different compilers; the test legs resolve the same way;
- a path toolchain, a name no runner can install, or a toolchain file
  rustup rejects fails the run.

`test_matrix` picks the test legs: `project` (the project toolchain),
`msrv` (adds the declared `rust-version`, the default) or `full` (adds
recent stable minors and `stable`). `runners` adds platforms, for
example an `ubuntu-24.04-arm` leg; build and tests run once per entry.

### Lockfiles

The lanes use a committed `Cargo.lock` as is. Without one, the verify lane
resolves a lockfile once in `rust-metadata` and hands it to every job,
and the build, tests, audit and SBOM then read one dependency graph. The
release and merge lanes default `lockfile_required` to `true`: crates
publish with `--locked`, so a release without a lockfile fails at its
first job.

## Behavioural toggles

Every stage can switch off or turn advisory without forking a
workflow. The defaults gate; the inputs below relax them.

<!-- markdownlint-disable MD013 -->

| Input                                         | Lanes          | Default  | Effect                                                                                                                                          |
| --------------------------------------------- | -------------- | -------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `tests_enabled`                               | all            | `true`   | `false` skips the test jobs                                                                                                                     |
| `test_permit_fail`                            | all            | `false`  | Report test failures without failing the job                                                                                                    |
| `audit_enabled`                               | all            | `true`   | `false` skips `cargo audit`                                                                                                                     |
| `audit_permit_fail`                           | all            | `false`  | Report audit failures without failing the job                                                                                                   |
| `audit_ignore_vulns`, `audit_allow_list_path` | all            | `''`     | RUSTSEC advisories to ignore                                                                                                                    |
| `deny_enabled`, `deny_checks`                 | all            | `false`  | Also run `cargo deny` checks                                                                                                                    |
| `sbom_enabled`                                | all            | `true`   | `false` skips the SBOM, and with it the Grype scan                                                                                              |
| `grype_enabled`                               | all            | `true`   | `false` skips the Grype scan but keeps the SBOM                                                                                                 |
| `grype_fail_on`                               | all            | `medium` | Lowest severity that fails the scan; `none` reports without gating                                                                              |
| `grype_permit_fail`                           | all            | `false`  | Report Grype findings without failing the job                                                                                                   |
| `grype_only_fixed`                            | all            | `false`  | Ignore advisories that have no fix                                                                                                              |
| `grype_gate_when`                             | verify         | `always` | `dependencies-changed` gates when the change touches `Cargo.toml`, `Cargo.lock` or `.cargo/config*`, and otherwise reports findings as warnings |
| `grype_cache_db`                              | verify         | `true`   | Grype database cache: `true`, `false`, or restore without saving                                                                                |
| `cbom_enabled`                                | verify         | `false`  | Advisory CBOM job; see [CBOM](#cbom)                                                                                                            |
| `cache`                                       | verify         | `false`  | Cache `~/.cargo` and `target/`; the release and merge lanes never restore a cache                                                               |
| `publish_enabled`                             | release, merge | `false`  | Publish to crates.io through Trusted Publishing                                                                                                 |
| `dry_run`                                     | release, merge | `false`  | Verify everything, publish and tag nothing                                                                                                      |
| `harden_runner_egress`                        | all            | `block`  | `audit` logs egress instead of blocking it                                                                                                      |

<!-- markdownlint-enable MD013 -->

The test, audit and Grype jobs of the verify lane also honour the
`NO_BLOCK_AUDIT_FAIL` repository variable: set it to `true` to make
them advisory across every caller without editing one. On the release
and merge lanes the variable relaxes the Grype scan alone. Callers
grant `issues: read`, which Grype needs to read approved `cve-bypass`
issues.

The Grype gate is moving towards dependency-aware gating in
`grype-scan-action`: thresholds for inherited dependencies and gating
that tracks what a change declared. The lanes will expose those inputs
once a release carries them. Until then, `grype_gate_when`,
`grype_fail_on`, `grype_only_fixed` and `grype_permit_fail` cover the
common cases, and maintainers can approve a bypass for a single CVE
through a `cve-bypass` issue, which the action honours.

## Publishing to crates.io

Both release lanes publish inside the reusable workflow. crates.io
matches its trusted publishers against the OIDC `workflow_ref` claim,
which names the **caller's** workflow file, so the reusable workflow
can publish where PyPI's rules force the Python lanes to publish from
the caller. Before setting `publish_enabled: true`:

1. Create the publish environment (`publish_environment`, default
   `production`) **before** the first release, with a deployment rule:
   - Model A: a tag rule such as `v[0-9]*.[0-9]*.[0-9]*`;
   - Model B: the protected default branch.

   GitHub creates a missing environment, without protection rules, the
   first time a job names it.
2. On crates.io, add a trusted publisher for each crate, naming the
   repository, the **caller's** workflow filename and the environment.
   A project running both models registers two entries with two
   environments.
3. Optionally enable "Require trusted publishing" on crates.io, which
   then rejects API tokens.

The publish job alone holds a crates.io credential. It
runs no crate code: `crate-verify` compiles the packaged crates and
records their digests, and the publisher uploads nothing but archives
byte-identical to those. A re-run after a partial failure skips crates
already on crates.io with identical content.

Model A attaches the `.crate` files (checked against those digests),
binaries, SBOMs and a `SHA256SUMS` file to the GitHub release, with
build provenance attestations and Sigstore bundles (`attestations` and
`sigstore_sign`, both `true` by default). It publishes the crates
before it promotes the release, so a failed upload leaves a draft
rather than a release without its crates.

Keep one workflow per tag push: remove the `release.yaml` that
`actions-template` ships when a project adopts the release lane.

### Model B release files

On a merge, the merge lane reads the YAML files (`.yaml` or `.yml`)
the merge adds directly under `releases/`; on a push, that covers
every commit the push added. Other files there, such as a README,
don't count. Add one file per release, holding the version every
published crate carries, as three numbers with no pre-release part:

```yaml
# releases/1.4.0.yaml
version: 1.4.0
```

The lane then verifies and, with `publish_enabled`, publishes that
version, and tags the merged commit `v1.4.0` (`create_tag`, default
`true`). Gerrit projects set `create_tag: false` and tag in Gerrit.
Merges without a release file still build, test, audit, scan and
dry-run the publish; their packaged crates stay a workflow artefact,
as crates.io has no snapshots.

## Gerrit support

The workflows are Gerrit-aware: when a caller sets `gerrit_refspec`
they check out the change with `checkout-gerrit-change-action` instead
of `actions/checkout`. Voting and comments live in the `gerrit.yaml`
caller examples, never inside the reusable workflows, which need no
Gerrit secret.

## CBOM

`cbom-action` can't analyse Rust: CBOMkit and sonar-cryptography have
no Rust support yet (cbom-action #10). The verify lane's opt-in `cbom`
job scans any Java, Python or Go sources a Rust project also carries,
such as Python bindings, and skips a pure Rust project. It's advisory
and never fails the run. Don't set `cbom_languages` to `rust`; the lane
rejects it.

## Linting

The lanes don't lint. Linting runs through the organisation's linting
workflow and
[standalone-linting-action](https://github.com/lfreleng-actions/standalone-linting-action),
which prepares the project's Rust toolchain for `cargo fmt` and
`cargo clippy` hooks declared as `language: system` in
`.pre-commit-config.yaml`.

## Building blocks

<!-- markdownlint-disable MD013 -->

| Stage    | Action                                                                                     |
| -------- | ------------------------------------------------------------------------------------------ |
| Metadata | [build-metadata-action](https://github.com/lfreleng-actions/build-metadata-action)         |
| Build    | [rust-build-action](https://github.com/lfreleng-actions/rust-build-action)                 |
| Test     | [rust-test-action](https://github.com/lfreleng-actions/rust-test-action)                   |
| Audit    | [rust-audit-action](https://github.com/lfreleng-actions/rust-audit-action)                 |
| SBOM     | [sbom-action](https://github.com/lfreleng-actions/sbom-action)                             |
| Scan     | [grype-scan-action](https://github.com/lfreleng-actions/grype-scan-action)                 |
| CBOM     | [cbom-action](https://github.com/lfreleng-actions/cbom-action)                             |
| Publish  | [rust-crate-publish-action](https://github.com/lfreleng-actions/rust-crate-publish-action) |

<!-- markdownlint-enable MD013 -->

## GitHub CLI telemetry

The release and merge lanes shell out to `gh`, which posts usage
events to `cafe.github.com` unless told otherwise. Both set
`GH_TELEMETRY: 'false'`: no step needs that endpoint, a blocked call
adds noise under harden-runner's `block` policy, and allowing it would
widen egress across the organisation. A workflow-level `env:` block
does not cross the `workflow_call` boundary, so a caller that adds its
own `gh` jobs sets it too.

## Testing

[`.github/workflows/testing.yaml`](.github/workflows/testing.yaml)
calls the lanes by self-repository path
(`uses: $/.github/workflows/build-test.yaml`), which resolves this
repository at the commit already running, against
[test-rust-project](https://github.com/lfreleng-actions/test-rust-project):

- the verify lane against the root crate and each fixture variant
  (`workspace`, `no-lockfile`, `msrv`, `dependencies`, `native`,
  `features`), across two platforms for the root crate;
- the release lane as a dry run on the signed tag `v0.1.1`;
- the merge lane as a dry run, on a commit without a release file;
- a final job that inspects the artefacts the lanes left behind.

Nobody can take a crates.io version back, so the publish path itself
runs in test-rust-project's own releases. The merge lane's release
path awaits a fixture addition in test-rust-project, which
[`docs/BRIEF.md`](docs/BRIEF.md) lists.

[pre-commit.ci results page]: https://results.pre-commit.ci/latest/github/lfreleng-actions/rust-workflows/main
[pre-commit.ci status badge]: https://results.pre-commit.ci/badge/github/lfreleng-actions/rust-workflows/main.svg
