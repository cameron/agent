{ inputs, pkgs, nixpkgs, microvm }:

let
  fakeAgent = pkgs.writeShellScriptBin "agent" ''
    set -euo pipefail

    {
      printf 'label=%s\n' "''${AGENT_PROCESS_LABEL_STATUS:-missing}"
      loginuid="$(${pkgs.coreutils}/bin/cat /proc/self/loginuid)"
      printf 'loginuid=%s\n' "$loginuid"
      ${pkgs.gawk}/bin/awk '$1 == "CapEff:" { print "capeff=" $2 }' \
        /proc/self/status
      printf 'argument=<%s>\n' "$@"
    } > /tmp/agent-process-label-result

    ${pkgs.coreutils}/bin/true
  '';
  collectorPackage = pkgs.callPackage ../../agent-process-collect/package.nix {
    agentCommand = "${fakeAgent}/bin/agent";
    md2manHook = inputs.md2man.packages.${pkgs.stdenv.hostPlatform.system}.md2manHook;
  };
  processCollectTest = pkgs.writeShellApplication {
    name = "agent-process-collect-microvm-test";
    runtimeInputs = [
      collectorPackage
      pkgs.audit
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.jq
      pkgs.procps
      pkgs.systemd
      pkgs.util-linux
    ];
    text = ''
      set -euo pipefail

      fail() {
        printf 'FAIL: %s\n' "$*" >&2
        exit 1
      }

      wait_for_command() {
        description="$1"
        shift
        for _ in $(seq 1 90); do
          if "$@" >/dev/null 2>&1; then
            return 0
          fi
          sleep 0.5
        done
        fail "timed out waiting for $description"
      }

      assert_contains() {
        [[ "$1" == *"$2"* ]] || fail "missing <$2> in: $1"
      }

      assert_not_contains() {
        [[ "$1" != *"$2"* ]] || fail "unexpected <$2> in: $1"
      }

      wait_for_command auditd systemctl is-active --quiet auditd.service
      wait_for_command audit-rules systemctl is-active --quiet audit-rules-nixos.service
      wait_for_command process-accounting systemctl is-active --quiet agent-process-accounting.service
      [[ "$(systemctl show agent-process-index-bootstrap.service -p Result --value)" == success ]] ||
        fail 'the index bootstrap did not succeed'
      [[ "$(systemctl is-enabled agent-process-index-bootstrap.service)" == enabled ]] ||
        fail 'the index bootstrap is not enabled'

      [[ "$(stat -c %a /var/log/agent-process-collect)" == 700 ]] ||
        fail 'the collection directory mode is not 0700'
      [[ "$(stat -c %a /var/log/agent-process-collect/pacct/current)" == 600 ]] ||
        fail 'the process-accounting log mode is not 0600'
      [[ "$(stat -c %a /var/log/agent-process-collect/audit/current)" == 600 ]] ||
        fail 'the audit log mode is not 0600'
      [[ "$(stat -c %a /var/log/agent-process-collect/index/process.sqlite3)" == 600 ]] ||
        fail 'the process index mode is not 0600'
      auditctl -l | grep -q agent_exec || fail 'the agent exec audit rule is absent'
      grep -q '^active = yes' /etc/audit/plugins.d/agent_process_index.conf ||
        fail 'the audit index plugin is inactive'
      grep -q '^path = /run/current-system/sw/bin/agent-process-index$' \
        /etc/audit/plugins.d/agent_process_index.conf ||
        fail 'the audit index plugin has the wrong executable'
      wait_for_command indexer pgrep -f \
        '^.*/run/current-system/sw/bin/agent-process-index ingest '
      systemctl start agent-process-index-bootstrap.service
      wait_for_command restarted-indexer pgrep -f \
        '^.*/run/current-system/sw/bin/agent-process-index ingest '

      runuser -l alice -c '/run/wrappers/bin/agent-process-label claude --model opus'
      result="$(cat /tmp/agent-process-label-result)"
      assert_contains "$result" 'label=labeled'
      assert_contains "$result" 'loginuid=4294967294'
      assert_contains "$result" 'capeff=0000000000000000'
      assert_contains "$result" 'argument=<claude>'
      assert_contains "$result" 'argument=<--model>'
      assert_contains "$result" 'argument=<opus>'

      session_found=0
      for _ in $(seq 1 90); do
        if agent-process-collect sessions --json | jq -e \
          'select(.uid == 1000 and .audit_auid == 4294967294
            and .label_status == "labeled" and .harness == "claude"
            and .launcher_argv[1:] == ["claude", "--model", "opus"])' \
          >/dev/null; then
          session_found=1
          break
        fi
        sleep 0.5
      done
      [[ "$session_found" == 1 ]] || fail 'the labeled session was not indexed'
      session="$(agent-process-collect sessions --json |
        jq -c 'select(.uid == 1000)' | head -n1)"
      [[ -n "$session" ]] || fail 'the indexed Alice session is absent'
      [[ "$(jq -r .host <<<"$session")" == collector-test ]] ||
        fail 'the indexed host is wrong'
      [[ "$(jq -r .cwd <<<"$session")" == /home/alice ]] ||
        fail 'the indexed working directory is wrong'

      chmod 000 /var/log/agent-process-collect/audit/current
      agent-process-collect sessions --json |
        jq -e 'select(.uid == 1000)' >/dev/null ||
        fail 'the index was unavailable when the audit log was unreadable'
      report="$(agent-process-collect report --days 7)"
      assert_contains "$report" '- Agent launches: 1'
      chmod 600 /var/log/agent-process-collect/audit/current

      accounting_found=0
      for _ in $(seq 1 90); do
        if agent-process-collect lastcomm -- --command agent | grep -q agent; then
          accounting_found=1
          break
        fi
        sleep 0.5
      done
      [[ "$accounting_found" == 1 ]] || fail 'lastcomm did not see the agent'
      agent-process-collect sa -- -a | grep -q agent ||
        fail 'sa did not see the agent'
      status="$(agent-process-collect status)"
      assert_contains "$status" 'agent-labeler: ready'
      assert_contains "$status" 'index: ready'
      assert_contains "$status" 'indexer: active'

      report="$(/run/wrappers/bin/sudo -u alice /run/wrappers/bin/sudo -n \
        /run/current-system/sw/bin/agent-process-collect report --days 7)"
      assert_contains "$report" '- Collection health: healthy'
      assert_contains "$report" '- Agent launches: 1'
      assert_contains "$report" '- Agent-tree exec attempts:'
      assert_not_contains "$report" '--model'
      if /run/wrappers/bin/sudo -u alice /run/wrappers/bin/sudo -n \
        /run/current-system/sw/bin/agent-process-collect status; then
        fail 'Alice could run the privileged status command'
      fi

      auditctl --loginuid-immutable
      # The command substitution belongs to the shell that runuser starts.
      # shellcheck disable=SC2016
      runuser -l alice -c \
        'if test $(cat /proc/self/loginuid) = 4294967295; then
           printf 1000 > /proc/self/loginuid
         fi
         exec ${collectorPackage}/libexec/agent-process-label codex direct'
      degraded="$(cat /tmp/agent-process-label-result)"
      assert_contains "$degraded" 'label=degraded'
      assert_contains "$degraded" 'capeff=0000000000000000'
      assert_contains "$degraded" 'argument=<codex>'

      systemctl start agent-process-collect-rotate.service
      process_archives=(/var/log/agent-process-collect/pacct/archive/*.pacct)
      audit_archives=(/var/log/agent-process-collect/audit/archive/*.log)
      [[ -s "''${process_archives[0]}" ]] || fail 'the process archive is empty'
      [[ -s "''${audit_archives[0]}" ]] || fail 'the audit archive is empty'
      [[ -f /var/log/agent-process-collect/pacct/current ]] ||
        fail 'rotation did not recreate the process log'
      [[ -f /var/log/agent-process-collect/audit/current ]] ||
        fail 'rotation did not recreate the audit log'
    '';
  };
in
import ../../nix/tests/run-microvm-test.nix {
  inherit pkgs nixpkgs microvm;
  name = "agent-process-collect";
  testCommand = "${processCollectTest}/bin/agent-process-collect-microvm-test";
  timeout = 1800;

  modules = [
    {
      imports = [ ../agent-process-collect.nix ];
      networking.hostName = "collector-test";
      services.agent-process-collect = {
        enable = true;
        package = collectorPackage;
        retentionDays = 30;
        reportUsers = [ "alice" ];
      };
      users.users.alice = {
        isNormalUser = true;
        uid = 1000;
      };
      environment.systemPackages = [ pkgs.jq processCollectTest ];
    }
  ];
}
