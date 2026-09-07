# Eval harness for modules/airdress-operator.nix — checks the module
# evaluates, that legacy config still produces the original unit, and
# that two instances produce two units with distinct state dirs.
{ nixpkgs ? <nixpkgs>, module ? /src/modules/airdress-operator.nix }:
let
  pkgs = import nixpkgs { system = "x86_64-linux"; };
  lib  = pkgs.lib;

  evalWith = extra: (import (nixpkgs + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    modules = [
      module
      ({ config, ... }: {
        boot.loader.grub.enable = false;
        fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; };
        system.stateVersion = "24.05";
        services.airdress-operator.package = pkgs.hello;  # stand-in
      })
      extra
    ];
  }).config;

  legacy = evalWith {
    services.airdress-operator = {
      enable = true;
      settings.bind = "0.0.0.0:8080";
    };
  };

  two = evalWith {
    services.airdress-operator.instances = {
      compute = {
        enable = true;
        role   = "compute";
        homing = "https://op.example";
        compute.poolMemberName = "nas-compute";
        settings.bind = "127.0.0.1:8080";
        settings.database.data_dir = "/var/lib/a/pg";
      };
      apps = {
        enable = true;
        settings.bind = "127.0.0.1:8081";
        settings.database.data_dir = "/var/lib/b/pg";
      };
    };
  };

  collide = (import (nixpkgs + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    modules = [
      module
      ({ ... }: {
        boot.loader.grub.enable = false;
        fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; };
        system.stateVersion = "24.05";
        services.airdress-operator.package = pkgs.hello;
        services.airdress-operator.instances = {
          a = { enable = true; settings.bind = "127.0.0.1:8080"; };
          b = { enable = true; settings.bind = "127.0.0.1:8080"; };
        };
      })
    ];
  }).config;
in {
  legacyUnits   = lib.attrNames (lib.filterAttrs (n: _: lib.hasPrefix "airdress-operator" n) legacy.systemd.services);
  legacyState   = legacy.systemd.services.airdress-operator.serviceConfig.StateDirectory;
  twoUnits      = lib.sort (a: b: a < b) (lib.attrNames (lib.filterAttrs (n: _: lib.hasPrefix "airdress-operator" n) two.systemd.services));
  twoStateDirs  = lib.sort (a: b: a < b) (lib.mapAttrsToList (_: s: s.serviceConfig.StateDirectory)
                    (lib.filterAttrs (n: _: lib.hasPrefix "airdress-operator" n) two.systemd.services));
  computeCaps   = two.systemd.services."airdress-operator-compute".serviceConfig.AmbientCapabilities;
  appsCaps      = two.systemd.services."airdress-operator-apps".serviceConfig.AmbientCapabilities;
  collisionMsgs = map (a: a.message) (lib.filter (a: !a.assertion) collide.assertions);
}
