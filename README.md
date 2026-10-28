# Carina provider release

Shared build, GitHub release, signing, publish, and yank components for
[Carina](https://github.com/carina-rs/carina) providers. See
[`examples/release.yml`](examples/release.yml) for a generic third-party caller
workflow.

## Why the pipeline is split

The build runs as a reusable workflow, but signing and registry publish/yank run as
composite actions inside the provider repository's own release jobs. A reusable
workflow would make its workflow identity this repository's workflow. In contrast,
a composite action keeps the caller job's OIDC `job_workflow_ref` and the Fulcio
certificate SAN as
`<provider repo>/.github/workflows/release.yml@refs/tags/vX`.

That identity is part of the registry's trusted-publisher check and the signer that
clients pin. See the registry [publish API design](https://github.com/carina-rs/registry/blob/main/docs/publish-api-design.md#oidc-%E3%81%AB%E3%82%88%E3%82%8B%E3%82%A2%E3%82%AF%E3%82%BB%E3%82%B9%E5%85%83%E3%81%AE%E8%AA%8D%E8%A8%BC)
and protocol [§3, "Signer identity"](https://github.com/carina-rs/registry/blob/main/docs/protocol.md#signer-identity).
The reusable build workflow therefore has no OIDC permission.

## Caller contract

The provider repository must:

- expose a Cargo binary whose name is the `provider` input;
- include `scripts/docs-bundle.py` with `build <archive>` and `check <archive>`
  commands;
- make `docs-generate` generate the docs and fail when committed generated files
  are stale;
- define a GitHub environment named `release` and restrict it to `v*` tags; and
- configure the registry trusted-publisher policy in
  `release-tag-environment` mode with environment `release`, pointing to the
  caller's `.github/workflows/release.yml`.

The release workflow should trigger on `v*` tag pushes and reserve manual dispatch
for yank. The `provider` value is also the artifact prefix, so the Cargo binary and
release files use the same name.

## Example

Use [`examples/release.yml`](examples/release.yml) as the generic third-party
caller template; replace its artifact prefix, registry name and namespace, docs
directory, and all-zero SHA.

## Pinning

Reference this repository by a full 40-character commit SHA, never by a branch or
tag. A SHA makes reviewed release code immutable and prevents a moved ref from
changing what runs in a privileged caller job. Replace the all-zero placeholder in
the example only after reviewing the target commit's diff.

## Inputs

### `.github/workflows/build.yml`

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `provider` | yes | — | Cargo binary name and artifact prefix |
| `wasm-toolchain` | no | `stable` | Rust toolchain for the WASM build |
| `docs-generate` | yes | — | Bash script that generates and verifies docs before bundling |

### `github-release/action.yml`

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `provider` | yes | — | Artifact prefix |

### `publish/action.yml`

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `provider` | yes | — | Artifact prefix |
| `name` | yes | — | Registry provider name |
| `namespace` | yes | — | Registry namespace |

### `yank/action.yml`

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `name` | yes | — | Registry provider name |
| `namespace` | yes | — | Registry namespace |

## Security

Composite actions run with the caller job's permissions and secrets. The publish
and yank jobs hold `id-token: write`, so any action they run can mint a registry
OIDC token for that provider. Pin this repository by full commit SHA and review the
diff before every bump. Keep `id-token: write` off the build and GitHub release
jobs. The registry audience and write endpoints are fixed by the actions so a
registry-scoped token cannot be redirected to another host.
