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

> **Status: under construction.** [`docs/BRIEF.md`](docs/BRIEF.md)
> records the settled design. The three workflow files in
> `.github/workflows/` are still the language-neutral skeletons this
> repository started from; each lane replaces its skeleton as it lands.
> Do not call them from a project yet.

## Lanes

<!-- markdownlint-disable MD013 -->

| Workflow                                    | Purpose                                                       | Trigger         | Tracking |
| ------------------------------------------- | ------------------------------------------------------------- | --------------- | -------- |
| `.github/workflows/build-test.yaml`         | Verify: build, test, audit, SBOM and Grype scan               | Pull request    | #4       |
| `.github/workflows/build-test-release.yaml` | Model A: tag-driven release, with opt-in crates.io publishing | Tag push        | #5       |
| `.github/workflows/merge.yaml`              | Model B: merge-driven, release-file triggered publishing      | Merge to `main` | #6       |

<!-- markdownlint-enable MD013 -->

[#8](https://github.com/lfreleng-actions/rust-workflows/issues/8)
tracks the whole Rust toolkit, including enhancements in the action
repositories.

The verify lane runs, after a metadata job that resolves one exact
toolchain for the whole run (jobs in `{ }` run concurrently; `->`
denotes sequence):

```text
rust-metadata -> build -> { tests | audit | sbom -> grype }
```

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
| Publish  | [rust-crate-publish-action](https://github.com/lfreleng-actions/rust-crate-publish-action) |

<!-- markdownlint-enable MD013 -->

Linting runs through the organisation's separate linting workflow and
[standalone-linting-action](https://github.com/lfreleng-actions/standalone-linting-action),
which prepares the project's Rust toolchain for `cargo fmt` and
`cargo clippy` hooks. The lanes here do not lint.
[test-rust-project](https://github.com/lfreleng-actions/test-rust-project)
and its `variants/` provide the fixtures the self-test runs against.

## Release models

The workflows support both release models, so a project can adopt
either:

- **Model A, tag-driven** (`build-test-release.yaml`): the version
  comes from a validated, signed SemVer tag; a GitHub release carries
  the attested artefacts, and crates.io publishing is opt-in through
  Trusted Publishing.
- **Model B, merge-driven** (`merge.yaml`): every merge builds and
  dry-runs the publish, keeping the result as a workflow artefact,
  since crates.io has no snapshots; a release file under `releases/`
  in the merged change triggers the real publish and the tag.

## Gerrit support

The workflows are Gerrit-aware: when a caller sets `gerrit_refspec`
they check out the change with `checkout-gerrit-change-action` instead
of `actions/checkout`. Voting and comments live in the `gerrit.yaml`
caller examples, never inside the reusable workflows.

## GitHub CLI telemetry

The release workflow shells out to `gh`, which posts usage events to
`cafe.github.com` unless told otherwise. The workflow and its caller
examples set `GH_TELEMETRY: 'false'`: no step needs that endpoint, a
blocked call adds noise under harden-runner's `block` policy, and
allowing it would widen egress across the organisation. A
workflow-level `env:` block does not cross the `workflow_call`
boundary, so both sides set it.

## Testing

[`.github/workflows/testing.yaml`](.github/workflows/testing.yaml)
calls the workflows by self-repository path
(`uses: $/.github/workflows/build-test.yaml`), which resolves this
repository at the commit already running. Until the verify lane lands,
it exercises the skeleton.

[pre-commit.ci results page]: https://results.pre-commit.ci/latest/github/lfreleng-actions/rust-workflows/main
[pre-commit.ci status badge]: https://results.pre-commit.ci/badge/github/lfreleng-actions/rust-workflows/main.svg
