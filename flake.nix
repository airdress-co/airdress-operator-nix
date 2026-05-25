# Binary-fetching flake for airdress-operator.
# Fetches the pre-built static musl binary from downloads.airdress.co.
# Source repo is private; this packaging repo is public (SPEC-024 v1.3).
#
# ## Package usage
#
#   nix run github:airdress-co/airdress-operator-nix -- --version
#   nix profile install github:airdress-co/airdress-operator-nix
#
# ## NixOS module (SPEC-039)
#
# Import the module in your NixOS configuration:
#
#   imports = [
#     (builtins.getFlake "github:airdress-co/airdress-operator-nix").nixosModules.default
#   ];
#
#   services.airdress-operator = {
#     enable = true;
#     settings = {
#       bind = "0.0.0.0:8080";
#       database.data_dir = "/var/lib/airdress-operator/postgres";
#       database.version  = "=18.3.0";
#       chat.enabled = true;
#       dns.enabled  = true;
#       dns.zone     = "example.airdress.co";
#     };
#     # Optional: point at a secrets file managed by sops-nix / agenix.
#     # Requires SPEC-039 UP-2 in the operator binary.
#     # secretsFile = config.sops.secrets."airdress-operator".path;
#   };
#
# Key options:
#   services.airdress-operator.enable          bool     — start the service
#   services.airdress-operator.package         package  — operator binary (default: this flake)
#   services.airdress-operator.postgresPackage package  — NixOS PG package (default: postgresql_18)
#   services.airdress-operator.postgresVersion string   — PG version string (default: "18.3.0")
#   services.airdress-operator.settings        attrs    — operator TOML config as Nix attrs
#   services.airdress-operator.secretsFile     path     — TOML secrets fragment (sops/agenix)
#   services.airdress-operator.logLevel        string   — AIRDRESS_LOG directive (default: "info")
#
# The module handles DynamicUser hardening, CAP_NET_BIND_SERVICE for DNS port 53,
# and builds a pgInstallDir derivation in the Nix store so embedded PostgreSQL
# starts from an exec-allowed path (the state directory is noexec under DynamicUser).
#
# ## Version pinning
#
# The version and per-system hashes below are updated automatically by the
# airdress-bot GitHub App after each GA release (SPEC-024 FR-67).
{
  description = "airdress-operator";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      # --- version-pinned block (updated by airdress-bot on each release) ---
      version = "v0.1.9-alpha.5";

      artifacts = {
        "x86_64-linux" = {
          platform = "linux-amd64";
          hash     = "sha256-nxbfRpHafKWDM5dFawJVR/Tr88vUDjBObWETVXkLfnc=";
        };
        "aarch64-linux" = {
          platform = "linux-arm64";
          hash     = "sha256-kJBbS5vXZWMb204VlXLAn/cmFPv4SyTk7hGq5c0LBJU=";
        };
        "aarch64-darwin" = {
          platform = "darwin-arm64";
          hash     = "sha256-3atUnATuZMQsS9jo2/GfYioQJfGti+H/mhKTxER9hf0=";
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

      # NixOS module — system-agnostic, receives pkgs from the consuming config.
      # See modules/airdress-operator.nix for option definitions and inline docs.
      # The flake wrapper sets the package default to this flake's own binary so
      # consumers do not need to specify it explicitly.
      nixosModules.default = { lib, pkgs, ... }: {
        imports = [ ./modules/airdress-operator.nix ];
        # Wire the flake's own binary as the package default. The consumer can
        # override with services.airdress-operator.package = ...;
        config.services.airdress-operator.package =
          lib.mkDefault self.packages.${pkgs.system}.default;
      };
    };
}
