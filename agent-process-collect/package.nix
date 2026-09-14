{
  acct,
  agentCommand ? "/run/current-system/sw/bin/agent",
  audit,
  auditLoginUid ? 4294967294,
  bash,
  coreutils,
  findutils,
  gawk,
  gnugrep,
  lib,
  libcap,
  makeWrapper,
  md2manHook,
  pkg-config,
  python3,
  stdenv,
  systemd,
  util-linux,
}:

stdenv.mkDerivation {
  pname = "agent-process-collect";
  version = "0.2.0";

  dontUnpack = true;
  nativeBuildInputs = [ makeWrapper md2manHook pkg-config ];
  buildInputs = [ audit libcap ];
  markdownManpagesRoot = ./docs/man;

  buildPhase = ''
    runHook preBuild

    $CC -std=c11 -Wall -Wextra -Werror -O2 \
      -DAGENT_COMMAND=${lib.escapeShellArg (builtins.toJSON agentCommand)} \
      -DAGENT_AUDIT_LOGIN_UID=${toString auditLoginUid}U \
      $(pkg-config --cflags audit libcap) \
      ${./agent-process-label.c} \
      $(pkg-config --libs audit libcap) \
      -o agent-process-label

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 agent-process-label "$out/libexec/agent-process-label"
    install -Dm755 ${./agent-process-collect} \
      "$out/libexec/agent-process-collect"
    install -Dm755 ${./agent_process_index.py} \
      "$out/libexec/agent-process-index"
    substituteInPlace "$out/libexec/agent-process-index" \
      --replace-fail '#!/usr/bin/env python3' '#!${python3}/bin/python3'

    makeWrapper "$out/libexec/agent-process-collect" \
      "$out/bin/agent-process-collect" \
      --set AGENT_PROCESS_COLLECT_INDEXER \
        "$out/libexec/agent-process-index" \
      --prefix PATH : ${lib.makeBinPath [
        acct
        audit
        bash
        coreutils
        findutils
        gawk
        gnugrep
        libcap
        python3
        systemd
        util-linux
      ]} \
      --suffix PATH : /run/current-system/sw/bin

    ln -s ../libexec/agent-process-index "$out/bin/agent-process-index"

    runHook postInstall
  '';

  meta = {
    description = "Collect process accounting and Audit records for agent sessions";
    license = lib.licenses.mit;
    mainProgram = "agent-process-collect";
    platforms = lib.platforms.linux;
  };
}
