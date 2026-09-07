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
#   services.airdress-operator.instances       attrs    — named instances, see below
#
# ## Several operators on one host
#
# A machine can be an inference pool member AND a place where a hosted
# operator runs containers. Those are different trust postures, so they
# are different processes rather than one process with a wider role
# (RDR-035 §5.8):
#
#   services.airdress-operator.instances = {
#     compute = {
#       enable = true;
#       role   = "compute";
#       homing = "https://ipv6-operator.alice.airdr.es";
#       compute.poolMemberName = "ai-nas-0-compute";
#       settings.bind              = "127.0.0.1:8080";
#       settings.database.data_dir = "/var/lib/airdress-operator-compute/postgres";
#     };
#     apps = {
#       enable = true;
#       settings.bind              = "127.0.0.1:8081";
#       settings.database.data_dir = "/var/lib/airdress-operator-apps/postgres";
#       settings.apps.backends.container.binary = "docker";
#     };
#   };
#
# Each instance gets its own unit, DynamicUser, state directory and
# credentials, so one cannot read another's. Every option above is
# available per instance. The single-instance surface still works and is
# the instance named "default", which keeps the original unit and state
# directory names — an existing host sees no rename.
#
# The module asserts at eval time that instances do not collide on bind
# address, PostgreSQL data directory, healthz bind, pool member name or
# TUN interface name. It cannot assert that they fit in the host's RAM.
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
      version = "v0.1.20";

      artifacts = {
        "x86_64-linux" = {
          platform = "linux-amd64";
          hash     = "sha256-d+Iq4qXdAO9QaEZotRenltUGvikitXUVTzGA5AiIt6I=";
        };
        "aarch64-linux" = {
          platform = "linux-arm64";
          hash     = "sha256-Qwh5Dh9HhDEooAa9WfOVJ5sd9fbg4/Sn8f2ksCMwBIs=";
        };
        "aarch64-darwin" = {
          platform = "darwin-arm64";
          hash     = "sha256-L2wSy9hTCOPG7dpGxc0bQEabBJScTtdbKlslvGHHL/A=";
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
