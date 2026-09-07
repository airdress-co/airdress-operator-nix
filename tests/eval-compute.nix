{ nixpkgs, module ? /src/modules/airdress-operator.nix }:
let
  pkgs = import nixpkgs { system = "x86_64-linux"; };
  lib  = pkgs.lib;
  evalWith = extra: (import (nixpkgs + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    modules = [
      module
      ({ ... }: {
        boot.loader.grub.enable = false;
        fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; };
        system.stateVersion = "24.05";
        services.airdress-operator.package = pkgs.hello;
      })
      extra
    ];
  }).config;

  # legacy compute-role host, exactly the ai-nas-0 shape
  legacy = evalWith {
    services.airdress-operator = {
      enable = true;
      role   = "compute";
      homing = "https://op.example";
      compute.poolMemberName = "ai-nas-0";
      compute.bootstrapTokenFile = "/etc/airdress/token";
      settings.bind = "0.0.0.0:8080";
      postgresPackage = pkgs.postgresql_16;
    };
  };
  named = evalWith {
    services.airdress-operator.instances.compute = {
      enable = true;
      role   = "compute";
      homing = "https://op.example";
      compute.poolMemberName = "nas-compute";
      compute.bootstrapTokenFile = "/etc/airdress/token";
      postgresPackage = pkgs.postgresql_16;
    };
  };
  cfgOf = c: unit: builtins.readFile (lib.removePrefix "AIRDRESS_CONFIG="
    (lib.head (lib.filter (e: lib.hasPrefix "AIRDRESS_CONFIG=" e)
      c.systemd.services.${unit}.serviceConfig.Environment)));
in {
  legacyToml = cfgOf legacy "airdress-operator";
  namedToml  = cfgOf named "airdress-operator-compute";
  legacyLoadCred = legacy.systemd.services.airdress-operator.serviceConfig.LoadCredential;
  namedLoadCred  = named.systemd.services."airdress-operator-compute".serviceConfig.LoadCredential;
}
