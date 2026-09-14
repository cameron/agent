{
  description = "Run agent harnesses with shared instructions, transcripts, and process audits";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    md2man.url = "git+ssh://git@forge/srv/git/md2man.git?ref=main";
    md2man.inputs.nixpkgs.follows = "nixpkgs";
    content2title.url =
      "git+ssh://git@forge/srv/git/content2title.git?ref=main";
    content2title.inputs.nixpkgs.follows = "nixpkgs";
    content2title.inputs.md2man.follows = "md2man";
    microvm.url = "github:microvm-nix/microvm.nix";
    microvm.inputs.nixpkgs.follows = "nixpkgs";
    rm4agent.url = "git+ssh://git@forge/srv/git/rm4agent.git?ref=main";
    rm4agent.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, md2man, content2title, microvm, rm4agent }:
    let
      systems = [ "x86_64-linux" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      hookFor = system: md2man.packages.${system}.md2manHook;
    in
    {
      packages = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system}; in
        rec {
          agent = pkgs.callPackage ./nix/package.nix {
            md2manHook = hookFor system;
            agentTemplate = agent-template;
            agentTranscripts = agent-transcripts;
            content2titlePkg = content2title.packages.${system}.default;
          };
          agent-template = pkgs.callPackage ./agent-template/package.nix {
            md2manHook = hookFor system;
          };
          agent-process-collect =
            pkgs.callPackage ./agent-process-collect/package.nix {
              md2manHook = hookFor system;
            };
          agent-transcripts =
            pkgs.callPackage ./agent-transcripts/package.nix {
              md2manHook = hookFor system;
            };
          default = agent;
        });

      nixosModules.agent-process-collect = { config, lib, pkgs, ... }: {
        imports = [ ./nixos/agent-process-collect.nix ];
        services.agent-process-collect.package = lib.mkDefault
          (pkgs.callPackage ./agent-process-collect/package.nix {
            auditLoginUid = config.services.agent-process-collect.auditLoginUid;
            md2manHook = hookFor pkgs.stdenv.hostPlatform.system;
          });
      };

      checks = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system}; in
        {
          # agent-template's buildGoModule check phase runs its Go tests.
          package = self.packages.${system}.agent;
          agent-template = self.packages.${system}.agent-template;
          agent-process-collect = self.packages.${system}.agent-process-collect;
          agent-transcripts = self.packages.${system}.agent-transcripts;
        }
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          behavior = import ./nix/specs.nix {
            inherit pkgs;
            rm4agent = rm4agent.packages.${system}.default;
          };
          process-collect-microvm =
            import ./nixos/tests/agent-process-collect.nix {
              inherit pkgs nixpkgs microvm;
              inputs = { inherit md2man; };
            };
        });
    };
}
