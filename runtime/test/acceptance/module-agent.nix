# The worker LaunchAgent that nix/module.nix declares, as nix-darwin's plist keys.
# nix eval --json --impure --expr 'import ./module-agent.nix { flake = builtins.getFlake "git+file://$PWD"; package = "/nix/store/...-beep-boop-0.1.0"; configFile = "/Users/admin/lab/config.toml"; stateDirectory = "/Users/admin/lab/state"; }'
{
  flake,
  package,
  configFile,
  stateDirectory,
  system ? "aarch64-darwin",
}: let
  pkgs = import flake.inputs.nixpkgs {inherit system;};
  inherit (pkgs) lib;
  anything = lib.mkOption {type = lib.types.anything;};
  evaluated = lib.evalModules {
    specialArgs = {inherit pkgs;};
    modules = [
      (import "${flake}/nix/module.nix" {self = flake;})
      {
        options.assertions = anything;
        options.environment.systemPackages = anything;
        options.launchd.user.agents = anything;
      }
      {
        services.agent = {
          enable = true;
          role = "worker";
          inherit package configFile stateDirectory;
        };
      }
    ];
  };
  agent = evaluated.config.launchd.user.agents.agent;
in
  # nix-darwin names user agents org.nixos.<name> and maps environment to EnvironmentVariables.
  agent.serviceConfig
  // {
    Label = "org.nixos.agent";
    EnvironmentVariables = agent.environment;
  }
