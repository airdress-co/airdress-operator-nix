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

  # SPEC-038 — when role is "compute", the operator runs a stripped
  # subsystem set (enrollment + WG + long-poll + vLLM dispatch). The
  # generated TOML gets a `[role]` block driven by the typed options
  # below; users can still override via `settings.role.*` directly.
  computeSettings = lib.optionalAttrs (cfg.role == "compute") {
    role = {
      mode             = "compute";
      homing_operator  = cfg.homing;
      compute = {
        pool_member_name             = cfg.compute.poolMemberName;
        # The path the *service* reads, not the path the operator
        # (person) writes. systemd copies bootstrapTokenFile into the
        # unit's credentials directory below via LoadCredential=;
        # pointing the config at the source instead would have the
        # operator open a root-owned 0400 file as a DynamicUser, which
        # it cannot read — while a perfectly readable copy sits
        # unused two directories away.
        enrollment_token_file        = "/run/credentials/airdress-operator.service/enrollment_token";
        transport_preference         = cfg.compute.transportPreference;
        wg_handshake_timeout_seconds = cfg.compute.wgHandshakeTimeoutSeconds;
        vllm_local_url               = cfg.compute.vllmLocalUrl;
        auth_secret_ref              = cfg.compute.authSecretRef;
        healthz_bind                 = cfg.compute.healthzBind;
        tun_name                     = cfg.compute.tunName;
        tun_mtu                      = cfg.compute.tunMtu;
      };
    };
  };

  pgInstallDir =
    let
      pg  = cfg.postgresPackage;
      ver = cfg.postgresVersion;
    in
    # Two layouts, deliberately: postgresql_embedded looks for
    # <installdir>/<version>/bin/postgres, while the operator launches
    # <installdir>/bin/postgres directly. Both must be complete.
    #
    # postgres resolves its lib and share directories RELATIVE TO ITS OWN
    # BINARY, so a bin/ without sibling lib/ is not a partial convenience
    # — it is a postmaster that cannot start:
    #
    #   FATAL: could not open directory ".../airdress-pg-install-18.3.0/lib"
    #   HINT:  This may indicate an incomplete PostgreSQL installation
    #
    # The top level had bin/ only, so whichever layout the operator picked
    # decided whether it booted. Mirror all three in both places.
    pkgs.runCommand "airdress-pg-install-${ver}" { } ''
      mkdir -p $out/${ver}/bin $out/${ver}/lib $out/bin $out/lib
      for bin in ${pg}/bin/*; do
        ln -s "$bin" $out/${ver}/bin/
        ln -s "$bin" $out/bin/
      done
      for lib in ${pg}/lib/*; do
        ln -s "$lib" $out/${ver}/lib/
        ln -s "$lib" $out/lib/
      done
      ln -s ${pg}/share $out/${ver}/share
      ln -s ${pg}/share $out/share
    '';

  format     = pkgs.formats.toml { };
  mergedSettings = lib.recursiveUpdate computeSettings cfg.settings;
  configFile = format.generate "airdress-operator.toml" mergedSettings;

  secretsEnv = lib.optional (cfg.secretsFile != null)
    "AIRDRESS_SECRETS_FILE=${cfg.secretsFile}";

  secretsReadWritePaths = lib.optional (cfg.secretsFile != null)
    (builtins.dirOf (toString cfg.secretsFile));

in
{
  options.services.airdress-operator = {
    enable = lib.mkEnableOption "airdress-operator relay and routing daemon";

    contentKeyFile = lib.mkOption {
      type        = lib.types.str;
      default     = "/etc/credstore.encrypted/airdress-content-key";
      description = ''
        Path to the systemd-encrypted content key credential (SPEC-035).
        The file must be created with:
        <literal>dd if=/dev/urandom bs=32 count=1 | systemd-creds encrypt --name=content_key - /etc/credstore.encrypted/airdress-content-key</literal>
        The operator reads it at startup via <literal>$CREDENTIALS_DIRECTORY/content_key</literal>.
      '';
    };

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

    # ── SPEC-038 compute-role options ────────────────────────────────
    role = lib.mkOption {
      type        = lib.types.enum [ "full" "compute" ];
      default     = "full";
      description = ''
        Operator role (SPEC-038 §FR-G1). <literal>full</literal> runs the
        chat / DNS / federation / proxy / apps stack (homing operator);
        <literal>compute</literal> runs only the enrollment client, WG
        interface, T-C poll loop, and local vLLM dispatcher.
      '';
    };

    homing = lib.mkOption {
      type        = lib.types.nullOr lib.types.str;
      default     = null;
      description = ''
        Homing operator FQDN this compute-role op enrolls against
        (e.g. <literal>https://ipv6-operator.alice.airdr.es</literal>).
        Required when <option>role</option> is <literal>compute</literal>.
      '';
    };

    compute = {
      poolMemberName = lib.mkOption {
        type        = lib.types.str;
        default     = "";
        description = ''
          Name of the <literal>InferencePoolMember</literal> manifest
          on the homing op. Must match <literal>spec.computeOperatorRef</literal>
          on the applied manifest (SPEC-038 FR-Enr4).
        '';
      };

      bootstrapTokenFile = lib.mkOption {
        type        = lib.types.nullOr lib.types.str;
        default     = null;
        description = ''
          Path to the 72h bootstrap token issued by the hub's
          <literal>POST /v1/operator/compute-bootstrap</literal>. When
          set the systemd unit gets a matching
          <literal>LoadCredential=enrollment_token:&lt;path&gt;</literal>
          directive and the operator reads it via
          <literal>$CREDENTIALS_DIRECTORY/enrollment_token</literal>.
          File is consumed once at first boot and deleted (FR-Enr8).
        '';
      };

      transportPreference = lib.mkOption {
        type        = lib.types.enum [ "wireguard" "http-longpoll" ];
        default     = "wireguard";
        description = ''
          Transport preference at first enrollment. Negotiation is one-shot:
          <literal>wireguard</literal> is probed first; falls back to
          <literal>http-longpoll</literal> on handshake timeout (FR-NEG2).
        '';
      };

      wgHandshakeTimeoutSeconds = lib.mkOption {
        type        = lib.types.int;
        default     = 15;
        description = ''
          How long to wait for the first WG handshake before declaring
          <literal>transport=http-longpoll</literal>.
        '';
      };

      vllmLocalUrl = lib.mkOption {
        type        = lib.types.str;
        default     = "http://127.0.0.1:8000";
        description = "Local vLLM endpoint the compute op dispatches inference to.";
      };

      authSecretRef = lib.mkOption {
        type        = lib.types.str;
        default     = "";
        description = ''
          Vault key holding the bearer token sent to the local vLLM.
          Empty string = no auth (loopback vLLM with no token).
        '';
      };

      healthzBind = lib.mkOption {
        type        = lib.types.str;
        default     = "127.0.0.1:8765";
        description = "Bind address for the local /healthz endpoint.";
      };

      # ── SPEC-044 kernel TUN routing options ──────────────────────
      kernelTun = lib.mkOption {
        type        = lib.types.bool;
        default     = true;
        description = ''
          Enable kernel TUN routing for the compute op's WG interface
          (SPEC-044). Requires <literal>CAP_NET_ADMIN</literal> and a
          binary built with the <literal>kernel-tun</literal> cargo
          feature. When disabled the operator falls back to T-C HTTP
          long-polling regardless of the WG handshake outcome.
        '';
      };

      tunName = lib.mkOption {
        type        = lib.types.str;
        default     = "airdress-wg00";
        description = "Linux interface name for the kernel TUN device. Max 15 bytes.";
      };

      tunMtu = lib.mkOption {
        type        = lib.types.int;
        default     = 1380;
        description = "TUN MTU. 1380 = 1500 - 80 worst-case WG overhead.";
      };
    };
  };

  config = lib.mkIf cfg.enable (
    let
      isCompute       = cfg.role == "compute";
      kernelTunActive = isCompute && cfg.compute.kernelTun;
      caps =
        [ "CAP_NET_BIND_SERVICE" ]
        ++ lib.optional kernelTunActive "CAP_NET_ADMIN";

      # SPEC-044 FR-10 — clean up a stale TUN device left behind by a
      # previous crashed instance before we try to create our own.
      tunCleanupScript = pkgs.writeShellScript "airdress-tun-cleanup" ''
        set -eu
        if ${pkgs.iproute2}/bin/ip link show ${cfg.compute.tunName} 2>/dev/null; then
            ${pkgs.systemd}/bin/systemd-cat -t airdress-operator \
                echo "kernel-tun: cleaning up stale ${cfg.compute.tunName}"
            ${pkgs.iproute2}/bin/ip link delete ${cfg.compute.tunName} || true
        fi
      '';

      loadCredentials =
        [ "content_key:${cfg.contentKeyFile}" ];
      loadPlaintextCredentials =
        lib.optional (isCompute && cfg.compute.bootstrapTokenFile != null)
          "enrollment_token:${cfg.compute.bootstrapTokenFile}";

      execStartPre =
        lib.optional kernelTunActive (toString tunCleanupScript);
    in
    {
      assertions = [
        {
          assertion = !isCompute || cfg.homing != null;
          message   = "services.airdress-operator.homing must be set when role = \"compute\".";
        }
        {
          assertion = !isCompute || cfg.compute.poolMemberName != "";
          message   = "services.airdress-operator.compute.poolMemberName must be set when role = \"compute\".";
        }
      ];

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
          # SPEC-044: CAP_NET_ADMIN is added when role=compute + kernelTun=true.
          AmbientCapabilities   = lib.concatStringsSep " " caps;
          CapabilityBoundingSet = lib.concatStringsSep " " caps;

          # SPEC-044 FR-13 — allow the TUN device node when kernel TUN is on.
          DeviceAllow = lib.optional kernelTunActive "/dev/net/tun rw";

          # SPEC-044 FR-10 — pre-flight cleanup of any stale interface.
          ExecStartPre = execStartPre;

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

          # SPEC-035: deliver the 32-byte content key via systemd credential
          # store so it never touches the Nix store or environment variables.
          LoadCredentialEncrypted = loadCredentials;

          # SPEC-038 FR-Enr1 — deliver the 72h bootstrap token via the
          # systemd plaintext credential store (it's a one-time JWT, not a
          # long-lived secret). Operator reads it from
          # $CREDENTIALS_DIRECTORY/enrollment_token and deletes the source
          # file (FR-Enr8) — caller is responsible for systemd-creds
          # encryption if desired.
          LoadCredential = loadPlaintextCredentials;
        };
      };
    }
  );
}
