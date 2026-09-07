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
#
# ── Multiple instances on one host (RDR-035 §5.8) ──────────────────────
#
# One machine can be both an inference pool member and a place where a
# hosted operator runs containers. Those are different trust postures —
# a container-runtime grant is root-equivalent, talking to a vLLM the
# user already runs is not — so they are separate operator processes
# with separate users, units, credentials and enrollments, rather than
# one process carrying a wider role.
#
#   services.airdress-operator.instances = {
#     compute = { enable = true; role = "compute"; ... };
#     apps    = { enable = true; settings.bind = "127.0.0.1:8081"; ... };
#   };
#
# The single-instance surface (services.airdress-operator.enable and the
# options beside it) still works unchanged: it is defined as the instance
# named "default", whose unit and state directory keep their original
# names, so an existing host sees no rename and does not lose its
# PostgreSQL data directory.
#
# What two instances do NOT separate is capacity. RAM, CPU and GPU are
# host facts, and one instance's workload can spike into headroom the
# other was counting on. This module asserts that instances do not
# collide on ports, data directories or interface names; it cannot
# assert that they fit.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.airdress-operator;

  # Instances are keyed by arbitrary names. "default" keeps the original
  # unit and state-directory names so the single-instance surface is a
  # pure alias; any other name is suffixed.
  unitNameFor = name:
    if name == "default" then "airdress-operator" else "airdress-operator-${name}";

  stateDirFor = unitNameFor;

  # SPEC-038 — when role is "compute", the operator runs a stripped
  # subsystem set (enrollment + WG + long-poll + vLLM dispatch). The
  # generated TOML gets a `[role]` block driven by the typed options
  # below; users can still override via `settings.role.*` directly.
  computeSettingsFor = name: icfg: lib.optionalAttrs (icfg.role == "compute") {
    role = {
      mode             = "compute";
      homing_operator  = icfg.homing;
      compute = {
        pool_member_name             = icfg.compute.poolMemberName;
        # The path the *service* reads, not the path the operator
        # (person) writes. systemd copies bootstrapTokenFile into the
        # unit's credentials directory below via LoadCredential=;
        # pointing the config at the source instead would have the
        # operator open a root-owned 0400 file as a DynamicUser, which
        # it cannot read — while a perfectly readable copy sits
        # unused two directories away.
        #
        # Per instance: the credentials directory is named after the unit,
        # so a second instance reads a different path.
        enrollment_token_file        =
          "/run/credentials/${unitNameFor name}.service/enrollment_token";
        transport_preference         = icfg.compute.transportPreference;
        wg_handshake_timeout_seconds = icfg.compute.wgHandshakeTimeoutSeconds;
        vllm_local_url               = icfg.compute.vllmLocalUrl;
        auth_secret_ref              = icfg.compute.authSecretRef;
        healthz_bind                 = icfg.compute.healthzBind;
        tun_name                     = icfg.compute.tunName;
        tun_mtu                      = icfg.compute.tunMtu;
      };
    };
  };

  mkPgInstallDir = pg: ver:
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

  format = pkgs.formats.toml { };

  configFileFor = name: icfg:
    format.generate "${unitNameFor name}.toml"
      (lib.recursiveUpdate (computeSettingsFor name icfg) icfg.settings);

  enabledInstances = lib.filterAttrs (_: i: i.enable) cfg.instances;

  # ── Collision detection ────────────────────────────────────────────
  #
  # Two operator processes on one host share every singleton the config
  # names. Catching a duplicate at eval time is the whole reason this is
  # a Nix module rather than a pair of hand-written units: a duplicated
  # bind address is a unit that restarts forever, and a duplicated
  # PostgreSQL data directory is two postmasters fighting over one
  # cluster, which is worse than a crash.
  #
  # `get` returning null or "" means "not set", which is never a
  # collision.
  collisionsOn = get:
    let
      values = lib.filter (v: v != null && v != "")
        (lib.mapAttrsToList (_: get) enabledInstances);
    in
    lib.filter (v: lib.count (x: x == v) values > 1) (lib.unique values);

  mkCollisionAssertion = { label, option, get }:
    let dupes = collisionsOn get;
    in {
      assertion = dupes == [ ];
      message = ''
        Two enabled airdress-operator instances share ${label}: ${
          lib.concatStringsSep ", " (map toString dupes)
        }. Set a distinct `${option}` on each instance — two operator
        processes on one host cannot share it.
      '';
    };

  # `settings` is free-form attrs, so reach into it defensively.
  settingsPath = path: icfg: lib.attrByPath path null icfg.settings;

  # Options that describe ONE operator process. Used twice: once at the
  # top level (the single-instance surface) and once inside each entry of
  # `instances`, so there is exactly one description of what an instance
  # is.
  instanceOptions = {

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

in
{
  # The single-instance surface is the same option set as one entry of
  # `instances`, plus the two options that only make sense at the top
  # level.
  options.services.airdress-operator = instanceOptions // {
    enable = lib.mkEnableOption "airdress-operator relay and routing daemon";

    instances = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = instanceOptions // {
          enable = lib.mkEnableOption "this airdress-operator instance";
          package = lib.mkOption {
            type    = lib.types.package;
            default = cfg.package;
            defaultText = lib.literalExpression "services.airdress-operator.package";
            description = "Operator package for this instance.";
          };
        };
      });
      default = { };
      example = lib.literalExpression ''
        {
          compute = {
            enable = true;
            role   = "compute";
            homing = "https://ipv6-operator.alice.airdr.es";
            compute.poolMemberName = "ai-nas-0-compute";
            settings.bind              = "127.0.0.1:8080";
            settings.database.data_dir = "/var/lib/airdress-operator-compute/postgres";
          };
          apps = {
            enable = true;
            settings.bind              = "127.0.0.1:8081";
            settings.database.data_dir = "/var/lib/airdress-operator-apps/postgres";
            settings.apps.backends.container.binary = "docker";
          };
        }
      '';
      description = ''
        Named operator instances to run on this host, each with its own
        systemd unit, DynamicUser, state directory and credential set.

        One machine can be an inference pool member and a container host
        at the same time. Those are different trust postures and belong
        in different processes (RDR-035 §5.8) — a container-runtime grant
        is root-equivalent; forwarding a request to a vLLM the user
        already runs is not.

        Instances are keyed by arbitrary names; the name becomes the unit
        suffix. The instance named <literal>default</literal> keeps the
        original unit and state-directory names and is what the
        single-instance surface
        (<option>services.airdress-operator.enable</option>) defines, so
        an existing host sees no rename.

        Instances share the host's RAM, CPU and GPU. This module asserts
        that they do not collide on ports, PostgreSQL data directories,
        healthz binds, pool member names or TUN interface names; it
        cannot assert that they fit.
      '';
    };
  };

  config = lib.mkMerge [

    # ── The single-instance surface, expressed as instances."default" ──
    #
    # Everything below operates on `instances`. The legacy options are a
    # pure alias, so an existing host keeps its unit name, its state
    # directory and therefore its PostgreSQL cluster.
    (lib.mkIf cfg.enable {
      services.airdress-operator.instances.default = {
        enable = true;
        inherit (cfg)
          package postgresPackage postgresVersion
          settings secretsFile logLevel contentKeyFile
          role homing compute;
      };
    })

    {
      assertions =
        (lib.flatten (lib.mapAttrsToList (name: icfg:
          let isCompute = icfg.role == "compute"; in [
            {
              assertion = !isCompute || icfg.homing != null;
              message   = "services.airdress-operator.instances.${name}.homing must be set when role = \"compute\".";
            }
            {
              assertion = !isCompute || icfg.compute.poolMemberName != "";
              message   = "services.airdress-operator.instances.${name}.compute.poolMemberName must be set when role = \"compute\".";
            }
            {
              # Linux caps interface names at IFNAMSIZ-1 = 15 bytes, and
              # over-length fails at runtime with a confusing error rather
              # than being rejected as configuration.
              assertion = builtins.stringLength icfg.compute.tunName <= 15;
              message   = "services.airdress-operator.instances.${name}.compute.tunName must be at most 15 bytes.";
            }
          ]) enabledInstances))
        ++ [
          (mkCollisionAssertion {
            label  = "a bind address";
            option = "settings.bind";
            get    = settingsPath [ "bind" ];
          })
          (mkCollisionAssertion {
            label  = "a PostgreSQL data directory";
            option = "settings.database.data_dir";
            get    = settingsPath [ "database" "data_dir" ];
          })
          (mkCollisionAssertion {
            label  = "a compute healthz bind";
            option = "compute.healthzBind";
            get    = i: if i.role == "compute" then i.compute.healthzBind else null;
          })
          (mkCollisionAssertion {
            label  = "a TUN interface name";
            option = "compute.tunName";
            get    = i:
              if i.role == "compute" && i.compute.kernelTun
              then i.compute.tunName else null;
          })
          (mkCollisionAssertion {
            label  = "an inference pool member name";
            option = "compute.poolMemberName";
            get    = i: if i.role == "compute" then i.compute.poolMemberName else null;
          })
        ];

      # Not an assertion: a single instance on the operator's default path
      # is correct, and only becomes a hazard once there are two.
      warnings = lib.optional
        (lib.length (lib.attrNames enabledInstances) > 1
          && lib.any (i: settingsPath [ "database" "data_dir" ] i == null)
               (lib.attrValues enabledInstances))
        ''
          Two or more airdress-operator instances are enabled and at least
          one does not set `settings.database.data_dir`. Each instance
          embeds its own PostgreSQL; instances that fall back to the same
          default path will fight over one cluster.
        '';

      systemd.services = lib.mapAttrs' (name: icfg:
        let
          unit            = unitNameFor name;
          isCompute       = icfg.role == "compute";
          kernelTunActive = isCompute && icfg.compute.kernelTun;
          caps =
            [ "CAP_NET_BIND_SERVICE" ]
            ++ lib.optional kernelTunActive "CAP_NET_ADMIN";

          # SPEC-044 FR-10 — clean up a stale TUN device left behind by a
          # previous crashed instance before we try to create our own.
          tunCleanupScript = pkgs.writeShellScript "${unit}-tun-cleanup" ''
            set -eu
            if ${pkgs.iproute2}/bin/ip link show ${icfg.compute.tunName} 2>/dev/null; then
                ${pkgs.systemd}/bin/systemd-cat -t ${unit} \
                    echo "kernel-tun: cleaning up stale ${icfg.compute.tunName}"
                ${pkgs.iproute2}/bin/ip link delete ${icfg.compute.tunName} || true
            fi
          '';

          secretsEnv = lib.optional (icfg.secretsFile != null)
            "AIRDRESS_SECRETS_FILE=${icfg.secretsFile}";

          secretsReadWritePaths = lib.optional (icfg.secretsFile != null)
            (builtins.dirOf (toString icfg.secretsFile));
        in
        lib.nameValuePair unit {
          description = "Airdress Operator${lib.optionalString (name != "default") " (${name})"}";
          after       = [ "network-online.target" ];
          wants       = [ "network-online.target" ];
          wantedBy    = [ "multi-user.target" ];

          serviceConfig = {
            Type       = "simple";
            ExecStart  = "${icfg.package}/bin/airdress-operator serve";
            ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
            Restart    = "on-failure";
            RestartSec = "10s";
            # initdb on first run can take a while; give it a generous budget.
            TimeoutStartSec = "600";
            TimeoutStopSec  = "30";

            Environment = [
              "AIRDRESS_CONFIG=${configFileFor name icfg}"
              "AIRDRESS_LOG=${icfg.logLevel}"
              # Point embedded-PG at the Nix store (exec-allowed) instead of the
              # state directory (noexec under DynamicUser=yes).
              "AIRDRESS_PG_INSTALLATION_DIR=${
                mkPgInstallDir icfg.postgresPackage icfg.postgresVersion
              }"
            ] ++ secretsEnv;

            # Allow binding privileged ports (DNS port 53) without root.
            # SPEC-044: CAP_NET_ADMIN is added when role=compute + kernelTun=true.
            AmbientCapabilities   = lib.concatStringsSep " " caps;
            CapabilityBoundingSet = lib.concatStringsSep " " caps;

            # SPEC-044 FR-13 — allow the TUN device node when kernel TUN is on.
            DeviceAllow = lib.optional kernelTunActive "/dev/net/tun rw";

            # SPEC-044 FR-10 — pre-flight cleanup of any stale interface.
            ExecStartPre = lib.optional kernelTunActive (toString tunCleanupScript);

            # Systemd hardening — mirrors deploy/airdress-operator.service.
            # DynamicUser gives each instance its own uid, so one instance
            # cannot read another's state directory or credentials. That is
            # the isolation two processes buy over one process with both
            # subsystems.
            DynamicUser           = true;
            ProtectSystem         = "strict";
            ProtectHome           = true;
            NoNewPrivileges       = true;
            PrivateTmp            = true;
            ProtectKernelTunables = true;
            ProtectControlGroups  = true;
            RestrictSUIDSGID      = true;
            StateDirectory        = stateDirFor name;
            StateDirectoryMode    = "0750";

            ReadWritePaths = secretsReadWritePaths;

            # SPEC-035: deliver the 32-byte content key via systemd credential
            # store so it never touches the Nix store or environment variables.
            LoadCredentialEncrypted = [ "content_key:${icfg.contentKeyFile}" ];

            # SPEC-038 FR-Enr1 — deliver the 72h bootstrap token via the
            # systemd plaintext credential store (it's a one-time JWT, not a
            # long-lived secret). Operator reads it from
            # $CREDENTIALS_DIRECTORY/enrollment_token and deletes the source
            # file (FR-Enr8) — caller is responsible for systemd-creds
            # encryption if desired.
            LoadCredential =
              lib.optional (isCompute && icfg.compute.bootstrapTokenFile != null)
                "enrollment_token:${icfg.compute.bootstrapTokenFile}";
          };
        }) enabledInstances;
    }
  ];
}
