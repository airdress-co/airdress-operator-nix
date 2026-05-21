# Binary-fetching flake for airdress-operator.
# Fetches the pre-built static musl binary from downloads.airdress.co.
# Source repo is private; this packaging repo is public (SPEC-024 v1.3).
#
# Usage:
#   nix run github:airdress-co/airdress-operator-nix -- --version
#   nix profile install github:airdress-co/airdress-operator-nix
#
# The version and per-system hashes below are updated automatically by the
# airdress-bot GitHub App after each GA release (SPEC-024 FR-67).
{
  description = "airdress-operator";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      # --- version-pinned block (updated by airdress-bot on each release) ---
      version = "v0.1.1-alpha.36";

      artifacts = {
        "x86_64-linux" = {
          platform = "linux-amd64";
          hash     = "sha256-EQvQmvYlNPjNuS8IRLdnMmFMtWNuTuO+0p9DWHSl8Hg=";
        };
        "aarch64-linux" = {
          platform = "linux-arm64";
          hash     = "sha256-GZtG0lNQlmXKaNb8xc1EzjXm5scdzY/cPJxUhcFLftU=";
        };
        "aarch64-darwin" = {
          platform = "darwin-arm64";
          hash     = "sha256-ZFcfOHfIxhjqKk/5wOYXa0t5gr0/R64yPuo4wrPvRRo=";
        };
      };
      # --- end version-pinned block ---

      forEachSystem = f: nixpkgs.lib.genAttrs (builtins.attrNames artifacts) f;
    in
    {
      packages = forEachSystem (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          art  = artifacts.${system};
        in
        {
          default = pkgs.stdenv.mkDerivation {
            pname   = "airdress-operator";
            inherit version;

            src = pkgs.fetchurl {
              url  = "https://downloads.airdress.co/airdress-operator/${version}/airdress-operator-${art.platform}";
              hash = art.hash;
            };

            dontUnpack    = true;
            dontConfigure = true;
            dontBuild     = true;

            nativeBuildInputs = [ pkgs.autoPatchelfHook ];
            buildInputs       = [ pkgs.stdenv.cc.cc.lib ];

            installPhase = ''
              install -Dm755 $src $out/bin/airdress-operator
            '';

            meta = with pkgs.lib; {
              description = "airdress operator daemon";
              homepage    = "https://airdress.co";
              mainProgram = "airdress-operator";
              platforms   = [ system ];
            };
          };
        }
      );
    };
}
