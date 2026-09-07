# Eval tests

No `nix flake check` here: the module is system-agnostic and the useful
assertions are about *evaluation* — which units exist, what they are
named, what the generated TOML says — not about building anything.

`eval.nix` checks unit naming, state directories and the collision
assertions. `eval-compute.nix` checks that a compute-role instance
points at the right per-unit systemd credentials path.

Run them on a machine with Nix:

```sh
nix eval --impure --json --expr \
  'import ./tests/eval.nix { nixpkgs = builtins.getFlake "github:NixOS/nixpkgs/nixos-25.05"; module = ./modules/airdress-operator.nix; }'
```

Or, on a machine without Nix (which is most of ours), through a
container — this is how the multi-instance change was actually verified:

```sh
podman run --rm -v "$PWD:/src:ro" docker.io/nixos/nix:latest \
  sh -c 'nix --extra-experimental-features "nix-command flakes" eval --impure --json \
    --expr "import /src/tests/eval.nix { nixpkgs = builtins.getFlake \"github:NixOS/nixpkgs/nixos-25.05\"; }"'
```

What to look for:

- `legacyUnits` is `["airdress-operator"]` and `legacyState` is
  `airdress-operator`. The single-instance surface must never rename the
  unit or the state directory — a rename loses the embedded PostgreSQL
  data directory on an existing host.
- `twoUnits` / `twoStateDirs` are suffixed per instance.
- `computeCaps` carries `CAP_NET_ADMIN` and `appsCaps` does not.
- `collisionMsgs` is non-empty for two instances sharing a bind address.

Note the harnesses pin `postgresql_16` where they force the PG install
derivation: the module defaults to `postgresql_18`, which only exists in
nixpkgs 25.11 and later. That is a property of the test, not of the
module.
