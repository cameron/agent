{ pkgs
, nixpkgs
, microvm
, name
, testCommand
, modules ? [ ]
, mem ? 1024
, vcpu ? 2
, volumes ? [ ]
, timeout ? 1200
}:

let
  guest = nixpkgs.lib.nixosSystem {
    system = pkgs.stdenv.hostPlatform.system;
    modules = [
      microvm.nixosModules.microvm
      ({ lib, pkgs, ... }: {
        networking = {
          hostName = lib.mkDefault "${name}-test";
          useDHCP = lib.mkDefault false;
        };

        microvm = {
          hypervisor = "qemu";
          inherit mem vcpu;
          volumes = [
            {
              image = "test-output.img";
              label = "test-output";
              mountPoint = "/output";
              size = 32;
            }
          ] ++ volumes;
        };

        systemd.services.microvm-test = {
          description = "Run the ${name} microVM test";
          wantedBy = [ "multi-user.target" ];
          unitConfig.RequiresMountsFor = [ "/output" ];
          serviceConfig = {
            Type = "idle";
            TimeoutStartSec = timeout;
          };
          path = [ pkgs.coreutils pkgs.systemd ];
          script = ''
            result=FAIL
            if ${testCommand} > /output/test.log 2>&1; then
              result=PASS
            fi

            cat /output/test.log > /dev/console
            printf '%s\n' "$result" | tee /dev/console > /output/result
            sync
            # microvm.nix runs QEMU with no-reboot, so reboot exits the
            # hypervisor after the result disk is synchronized.
            systemctl reboot
          '';
        };

        system.stateVersion = lib.trivial.release;
      })
    ] ++ modules;
  };
in
pkgs.runCommand "microvm-test-${name}" {
  nativeBuildInputs = [
    guest.config.microvm.declaredRunner
    pkgs.p7zip
  ];
  requiredSystemFeatures = [ "kvm" ];
  meta.timeout = timeout;
} ''
  microvm-run
  7z e -y test-output.img result test.log
  cat test.log
  if test "$(cat result)" != PASS; then
    echo "${name} failed inside the microVM" >&2
    exit 1
  fi
  mkdir "$out"
  cp result test.log "$out/"
''
