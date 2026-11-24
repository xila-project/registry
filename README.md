<h1>
<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/brand/header-dark.svg">
  <img src=".github/brand/header-light.svg" alt="Xila Registry — Signed package metadata and publisher keys." width="1280">
</picture>
</h1>

[Documentation](https://www.xila.dev/docs/) ·
[Try Xila](https://platforms.xila.dev/) ·
[Community](https://matrix.to/#/#xila:anneraud.fr)

This repository is the package registry for [Xila](https://github.com/xila-project/core): **metadata only**, like `crates.io-index`. It holds one entry per released package version and the developer keys allowed to publish them; the `.xpk` archives stay where each project releases them. It is served as static files at [registry.xila.dev](https://registry.xila.dev/), so a client fetches exactly the entry it needs: no search service, database or running server.

Devices trust only the registry's **root key**. The published metadata is signed: `root.json` by the offline root key, and `index.json`, every entry, every developer key and every namespace file by the repository key, during publication. See [security and architecture](docs/architecture.md).

## Layout

```text
root.pub, root.json, root.json.sig              root key, and the root-signed list of repository keys
keys/developers/<id>.json                       developer (publisher) keys
namespaces/<namespace>.json                     namespace owners and the developer keys allowed in them
packages/<identifier, dots as />/<version>.json registry entries
```

Publication adds `index.json` and a `.sig` next to every key, namespace file and entry; they are not committed.

For example, `xila.pixel-painter` 0.2.1 is `packages/xila/pixel-painter/0.2.1.json`. The formats are defined in [`xila-project/package_manager`](https://github.com/xila-project/package_manager): [registry entry](https://github.com/xila-project/package_manager/blob/main/schemas/registry-entry.schema.json) (format 2, which records the minimum Xila version as `xila_version`), [developer key](https://github.com/xila-project/package_manager/blob/main/schemas/developer-key.schema.json) and [namespace file](https://github.com/xila-project/package_manager/blob/main/schemas/registry-namespace.schema.json); the identifier and namespace rules are in its [registry trust model](https://github.com/xila-project/package_manager/blob/main/docs/registry-trust.md#identifiers-and-namespaces).

- A **package identifier** is reverse-DNS with at least three components, such as `example.xila.weather`. A **namespace file** `namespaces/<namespace>.json` names the owner of a namespace and the developer keys that may publish in it. Xila's own packages still use the legacy two-component `xila.<name>` identifiers, which need no namespace file and are granted by `"namespaces": ["xila"]` in the developer key.
- A **developer key** (`id`, `author`, Ed25519 `public_key`, optional legacy `namespaces`, `kinds`) signs package manifests and may only publish identifiers that a namespace file grants it (or, through the legacy rule, `xila.<name>`) and whose kind is in its `kinds`. A package is **Wasm** when its target starts with `wasm32-` or `wasm64-` and **native** otherwise. Native code on a microcontroller without a memory protection unit runs fully trusted, so `native` is a separate, explicit grant that a maintainer reviews; a key without `kinds` may publish Wasm only.
- A **registry entry** pins one released archive by HTTPS URL, SHA-256 and size, names its `publisher`, and copies identity, compatibility, capabilities, display name and metadata from the archive's signed manifest. It is **generated from the archive, never written by hand**.

## Publishing a version

1. Release a signed `.xpk` in your project (for example with the [reusable packaging workflow](https://github.com/xila-project/package_manager/blob/main/docs/reusable-wasm-package-workflow.md)).
2. Generate its entry with [`xila-package`](https://github.com/xila-project/package_manager/tree/main/crates/builder):
   ```sh
   xila-package registry entry app.xpk publisher.pub <publisher-id> https://…/app.xpk packages/<namespace>/<name>/<version>.json
   ```
3. Open a pull request. The first contribution of a publisher also adds its `keys/developers/<id>.json`.

Published versions are **immutable**: a pull request may add entries but never modify or delete one; release a new version instead.

Before Xila 1.0, a breaking format migration may replace entries that no supported `xila-package` or device can verify any more. The move to registry entry format 2 did so: the format 1 entries (`minimum_xila_abi`, applications 0.1.0) were removed, since the current package format cannot read their archives, and the applications are republished in format 2 from 0.2.1. `tools/check_immutable.sh` allows removing a format 1 entry and nothing else; every format 2 entry is immutable.

## Validation and publication

[`tools/validate.sh`](tools/validate.sh) installs `xila-package` at the package_manager revision pinned in [`tools/xila-package.sh`](tools/xila-package.sh), then:

- refuses changes to already published entries, naming the archive URL, SHA-256 or size that changed, except the removal of a format 1 entry (pull requests, [`tools/check_immutable.sh`](tools/check_immutable.sh));
- downloads every entry's archive (HTTPS only, redirects included, at most 5 redirects, 16 MiB and 120 seconds each) and runs `xila-package registry check --archives`, which checks key files, entry placement and canonical form, namespace and kind (Wasm or native) authorization, and each archive's size, SHA-256, signature and copied fields. An archive replaced after publication no longer matches its entry, so every run also detects altered releases;
- rehearses signing ([`tools/rehearse_signing.sh`](tools/rehearse_signing.sh)): it signs a copy with throwaway root and repository keys and verifies the result from the throwaway root key, as a device does, so every key and entry is proven to be signed by a repository key and listed in the index, without any secret;
- builds an unsigned `_site/` preview from `keys/`, `namespaces/` and `packages/`.

[`tools/test.sh`](tools/test.sh) tests these rules against fixtures generated on the fly with test-only keys (nothing in the repository is a private key): a signed Wasm and a signed native package in a reverse-DNS namespace and a signed legacy `xila.<name>` package, and cases for each developer key kind, namespace file and the legacy grant, truncated and altered archives, altered, unsigned, foreign-signed and unlisted metadata, a signing key that `root.json` does not list, changed or deleted published entries, and the removal of a format 1 entry.

[`tools/sign.sh`](tools/sign.sh) then runs `xila-package registry sign` with the repository key: it writes `_site/` with `root.json`, every key and entry with its `.sig`, and a signed `index.json` valid for 30 days, and verifies the result from `root.pub` as a device would.

**Validate package registry** runs `test.sh` and `validate.sh` on pull requests and on `main`, with read-only permissions and no secrets. **Publish package registry** runs both scripts on `main` and weekly (to renew the index before it expires), then deploys `_site/` to GitHub Pages. The repository seed is the `XILA_REGISTRY_SIGNING_SEED_B64` secret of the `github-pages` environment, available only to that job; it will move to OpenBao, with new keys, once that is available. Neither workflow builds or executes application code. Run `bash tools/validate.sh` locally (needs `cargo`, `curl`, `git` and `jq`; set `XILA_PACKAGE` to reuse an existing binary).

## Root key

The root key is kept offline and only signs `root.json`:

```sh
xila-package registry root root.seed root-2026 repository.pub repository-2026 <version> root.json
```

Each new `root.json` needs a higher version and a root key of the previous one. Commit `root.json` and `root.json.sig`; `root.pub` is what devices pin.

## Licensing

Refer to [LICENSE](LICENSE). Package authors are responsible for stating appropriate licenses for their own published applications.

<!-- xila:footer:start -->

---

Part of **[Xila](https://www.xila.dev/)** ·
[Repositories](https://github.com/xila-project) ·
[Community](https://matrix.to/#/#xila:anneraud.fr)

Special thanks to [Martin Legand](https://www.behance.net/martinlegand) for generously designing the Xila logo.

<!-- xila:footer:end -->
