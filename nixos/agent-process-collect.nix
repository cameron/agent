{ config, inputs ? null, lib, pkgs, ... }:

let
  cfg = config.services.agent-process-collect;
  logRoot = "/var/log/agent-process-collect";
  defaultPackage =
    if inputs == null then
      throw "services.agent-process-collect.package must be set when the Bench flake inputs are unavailable"
    else
      pkgs.callPackage ../agent-process-collect/package.nix {
        auditLoginUid = cfg.auditLoginUid;
        md2manHook =
          inputs.md2man.packages.${pkgs.stdenv.hostPlatform.system}.md2manHook;
      };
  configuredUserUids = lib.filter (uid: uid != null)
    (map (user: user.uid or null) (lib.attrValues config.users.users));
in
{
  options.services.agent-process-collect = {
    enable = lib.mkEnableOption "agent process collection";

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      defaultText = lib.literalExpression "pkgs.agent-process-collect";
      description = "The agent process collection package.";
    };

    retentionDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = "The number of complete UTC days of process records to retain.";
    };

    auditLoginUid = lib.mkOption {
      type = lib.types.ints.between 0 4294967294;
      default = 4294967294;
      description = "The reserved Audit login ID assigned to agent process trees.";
    };

    reportUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Users that can run the safe summary report without a password.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !(builtins.elem cfg.auditLoginUid configuredUserUids);
        message = "services.agent-process-collect.auditLoginUid must not be assigned to a configured user.";
      }
    ];

    environment.systemPackages = [ cfg.package pkgs.acct pkgs.audit ];
    environment.variables.AGENT_PROCESS_LABELER =
      "/run/wrappers/bin/agent-process-label";

    security.wrappers.agent-process-label = {
      source = "${cfg.package}/libexec/agent-process-label";
      owner = "root";
      group = "root";
      permissions = "u+rx,g+rx,o+rx";
      capabilities = "cap_audit_control,cap_audit_write+ep";
    };

    security.audit = {
      enable = true;
      backlogLimit = 262144;
      rateLimit = 0;
      failureMode = "printk";
      rules = lib.mkAfter [
        "-a always,exit -F arch=b64 -S execve,execveat -F auid=${toString cfg.auditLoginUid} -k agent_exec"
        "-a always,exit -F arch=b32 -S execve,execveat -F auid=${toString cfg.auditLoginUid} -k agent_exec"
      ];
    };

    security.auditd = {
      enable = true;
      plugins.agent_process_index = {
        active = true;
        direction = "out";
        # auditd retains the configured command across reloads. Use the stable
        # system profile path so a reload resolves the newly activated package.
        path = "/run/current-system/sw/bin/agent-process-index";
        args = [
          "ingest"
          "${logRoot}/index/process.sqlite3"
        ];
        format = "string";
      };
      settings = {
        write_logs = true;
        log_file = "${logRoot}/audit/current";
        log_group = "root";
        log_format = "RAW";
        name_format = "hostname";
        flush = "incremental_async";
        freq = 50;
        max_log_file = 256;
        num_logs = 0;
        max_log_file_action = "keep_logs";
        space_left = "10%";
        space_left_action = "syslog";
        admin_space_left = "5%";
        admin_space_left_action = "suspend";
        disk_full_action = "suspend";
        disk_error_action = "syslog";
      };
    };

    security.sudo.extraRules = lib.optional (cfg.reportUsers != [ ]) {
      users = cfg.reportUsers;
      commands = [
        {
          command = "/run/current-system/sw/bin/agent-process-collect report --days *";
          options = [ "NOPASSWD" ];
        }
      ];
    };

    systemd.tmpfiles.rules = [
      "d ${logRoot} 0700 root root -"
      "d ${logRoot}/pacct 0700 root root -"
      "d ${logRoot}/pacct/archive 0700 root root -"
      "f ${logRoot}/pacct/current 0600 root root -"
      "d ${logRoot}/audit 0700 root root -"
      "d ${logRoot}/audit/archive 0700 root root -"
      "d ${logRoot}/index 0700 root root -"
      "d ${logRoot}/index/archive 0700 root root -"
    ];

    systemd.services.agent-process-index-bootstrap = {
      description = "Build the compact agent process index";
      wantedBy = [ "multi-user.target" ];
      unitConfig.DefaultDependencies = false;
      after = [ "local-fs.target" "systemd-tmpfiles-setup.service" ];
      before = [ "auditd.service" ];
      requires = [ "systemd-tmpfiles-setup.service" ];
      environment = {
        AGENT_PROCESS_COLLECT_RETENTION_DAYS = toString cfg.retentionDays;
        AGENT_PROCESS_COLLECT_REPORT_TIMEOUT_SECONDS = "60";
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe cfg.package} index-bootstrap";
        ExecStartPost =
          "-${lib.getExe' pkgs.audit "auditctl"} --signal reload";
        TimeoutStartSec = "30m";
        UMask = "0077";
        Nice = 10;
        IOSchedulingClass = "idle";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ logRoot ];
        Slice = "lab.slice";
      };
    };

    systemd.services.auditd = {
      after = lib.mkAfter [
        "systemd-tmpfiles-setup.service"
        "agent-process-index-bootstrap.service"
      ];
      requires = lib.mkAfter [
        "systemd-tmpfiles-setup.service"
        "agent-process-index-bootstrap.service"
      ];
      restartTriggers = lib.mkAfter [ cfg.package ];
      serviceConfig.UMask = "0077";
    };

    systemd.services.agent-process-accounting = {
      description = "Collect host process accounting records for agent audits";
      after = [ "local-fs.target" ];
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [ cfg.package ];
      environment.AGENT_PROCESS_COLLECT_RETENTION_DAYS =
        toString cfg.retentionDays;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${lib.getExe cfg.package} acct-start";
        ExecStop = "${lib.getExe cfg.package} acct-stop";
        Slice = "lab.slice";
      };
    };

    systemd.services.agent-process-collect-rotate = {
      description = "Rotate retained agent process records";
      after = [
        "agent-process-accounting.service"
        "agent-process-index-bootstrap.service"
        "auditd.service"
      ];
      requires = [
        "agent-process-accounting.service"
        "agent-process-index-bootstrap.service"
        "auditd.service"
      ];
      environment.AGENT_PROCESS_COLLECT_RETENTION_DAYS =
        toString cfg.retentionDays;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe cfg.package} rotate";
        Slice = "lab.slice";
      };
    };

    systemd.timers.agent-process-collect-rotate = {
      description = "Rotate agent process records each UTC day";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 00:10:00 UTC";
        Persistent = true;
        RandomizedDelaySec = "10m";
        Unit = "agent-process-collect-rotate.service";
      };
    };
  };
}
