# NixOS module for airdress-operator (SPEC-039).
#
# The embedded-PG path requires the postgres binaries to live in an exec-allowed
# directory. Under DynamicUser=yes the state directory (/var/lib/private/…) is
# noexec, so we build a pgInstallDir derivation in the Nix store (always exec)
# and point AIRDRESS_PG_INSTALLATION_DIR at it.
#
# The derivation mirrors the layout postgresql_embedded expects:
#   <version>/bin/postgres  — matched by postgresql_embedded's setup() call
#   bin/postgres            — matched by the "already installed?" check in
#                             airdress-db/src/embedded.rs; bypasses
#                             bundled-archive extraction
#
# Once SPEC-037 lands (postgresql_embedded ≥ 0.20 + trust_installation_dir),
# the root-level aliases become redundant but harmless.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.airdress-operator;

  pgInstallDir =
    let
      pg  = cfg.postgresPackage;
      ver = cfg.postgresVersion;
    in
    pkgs.runCommand "airdress-pg-install-${ver}" { } ''
      mkdir -p $out/${ver}/bin $out/${ver}/lib $out/bin
      for bin in ${pg}/bin/*; do
        ln -s "$bin" $out/${ver}/bin/
        ln -s "$bin" $out/bin/
      done
      for lib in ${pg}/lib/*; do
        ln -s "$lib" $out/${ver}/lib/
      done
      ln -s ${pg}/share $out/${ver}/share
    '';

  format     = pkgs.formats.toml { };
  configFile = format.generate "airdress-operator.toml" cfg.settings;

  secretsEnv = lib.optional (cfg.secretsFile != null)
    "AIRDRESS_SECRETS_FILE=${cfg.secretsFile}";

  secretsReadWritePaths = lib.optional (cfg.secretsFile != null)
    (builtins.dirOf (toString cfg.secretsFile));

in
{
  options.services.airdress-operator = {
    enable = lib.mkEnableOption "airdress-operator relay and routing daemon";

    package = lib.mkOption {
      type        = lib.types.package;
      description = ''
        The airdress-operator package to use. When this module is imported via the
        flake's <literal>nixosModules.default</literal>, defaults to the pre-built
        binary for the host system. Override to use a locally-built derivation.
      '';
    };

    postgresPackage = lib.mkOption {
      type        = lib.types.package;
      default     = pkgs.postgresql_18;
      description = ''
        NixOS PostgreSQL package to use for the embedded-PG installation
        directory. Must match the major version declared in
        <option>services.airdress-operator.postgresVersion</option>.
      '';
    };

    postgresVersion = lib.mkOption {
      type        = lib.types.str;
      default     = "18.3.0";
      description = ''
        Exact PostgreSQL version string used as the subdirectory name inside the
        pgInstallDir derivation (e.g. <literal>18.3.0</literal>). Must match the
        version the operator binary was compiled against. Check
        <literal>[database] version</literal> in the operator config.
      '';
    };

    settings = lib.mkOption {
      type        = lib.types.attrs;
      default     = { };
      description = ''
        Operator configuration as a Nix attribute set. Serialized to TOML and
        written to the Nix store. Must not contain secrets — use
        <option>services.airdress-operator.secretsFile</option> for those.

        Example:
        <programlisting>
        settings = {
          bind = "0.0.0.0:8080";
          database.data_dir = "/var/lib/airdress-operator/postgres";
          database.version  = "=18.3.0";
          chat.enabled = true;
          dns.enabled  = true;
          dns.zone     = "example.airdress.co";
        };
        </programlisting>
      '';
    };

    secretsFile = lib.mkOption {
      type        = lib.types.nullOr lib.types.path;
      default     = null;
      description = ''
        Path to a TOML file containing secrets (API keys, credentials). Loaded
        as the top-most figment layer at startup and on SIGHUP, overriding any
        value in <option>settings</option>. Manage with sops-nix, agenix, or
        similar. The directory containing this file is added to
        <literal>ReadWritePaths</literal>.

        Requires operator support for AIRDRESS_SECRETS_FILE (SPEC-039 UP-2).
        Until that lands this option has no effect at runtime.
      '';
    };

    logLevel = lib.mkOption {
      type        = lib.types.str;
      default     = "info";
      description = ''
        Log level directive passed as <literal>AIRDRESS_LOG</literal>.
        Accepts EnvFilter syntax (e.g. <literal>info,airdress=debug,sqlx=warn</literal>).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.airdress-operator = {
      description = "Airdress Operator";
      after       = [ "network-online.target" ];
      wants       = [ "network-online.target" ];
      wantedBy    = [ "multi-user.target" ];

      serviceConfig = {
        Type       = "simple";
        ExecStart  = "${cfg.package}/bin/airdress-operator serve";
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        Restart    = "on-failure";
        RestartSec = "10s";
        # initdb on first run can take a while; give it a generous budget.
        TimeoutStartSec = "600";
        TimeoutStopSec  = "30";

        Environment = [
          "AIRDRESS_CONFIG=${configFile}"
          "AIRDRESS_LOG=${cfg.logLevel}"
          # Point embedded-PG at the Nix store (exec-allowed) instead of the
          # state directory (noexec under DynamicUser=yes).
          "AIRDRESS_PG_INSTALLATION_DIR=${pgInstallDir}"
        ] ++ secretsEnv;

        # Allow binding privileged ports (DNS port 53) without root.
        AmbientCapabilities   = "CAP_NET_BIND_SERVICE";
        CapabilityBoundingSet = "CAP_NET_BIND_SERVICE";

        # Systemd hardening — mirrors deploy/airdress-operator.service.
        DynamicUser           = true;
        ProtectSystem         = "strict";
        ProtectHome           = true;
        NoNewPrivileges       = true;
        PrivateTmp            = true;
        ProtectKernelTunables = true;
        ProtectControlGroups  = true;
        RestrictSUIDSGID      = true;
        StateDirectory        = "airdress-operator";
        StateDirectoryMode    = "0750";

        ReadWritePaths = secretsReadWritePaths;
      };
    };
  };
}
