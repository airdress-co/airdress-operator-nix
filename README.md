# airdress-operator-nix

Nix flake for [airdress-operator](https://airdress.co). Fetches the pre-built
binary from `downloads.airdress.co` — no source build, no Rust toolchain required.

## Usage

```bash
# Run without installing
nix run github:airdress-co/airdress-operator-nix -- --version

# Install to user profile
nix profile install github:airdress-co/airdress-operator-nix
```

With flakes in `configuration.nix` or `home.nix`:

```nix
inputs.airdress-operator.url = "github:airdress-co/airdress-operator-nix";

# then in packages / environment.systemPackages:
inputs.airdress-operator.packages.${system}.default
```

## Supported platforms

| Nix system       | Binary          |
|------------------|-----------------|
| `x86_64-linux`   | `linux-amd64`   |
| `aarch64-linux`  | `linux-arm64`   |
| `aarch64-darwin` | `darwin-arm64`  |

## How it works

The `flake.nix` uses `fetchurl` to download the release binary from
`downloads.airdress.co/airdress-operator/<version>/` and applies
`autoPatchelfHook` so the binary runs on NixOS. The per-system SHA-256
hashes are updated automatically by `airdress-bot` after each GA release.

Verify the binary yourself: each release ships a minisign signature at
`downloads.airdress.co/airdress-operator/<version>/airdress-operator-<platform>.minisig`
against the public key at `get.airdress.co/operator.pub`.

## Releases

Releases of `airdress-operator` are published at
`downloads.airdress.co/airdress-operator/` with a full manifest, checksums,
and minisign signatures. The version pinned in this flake tracks the latest
GA release.
