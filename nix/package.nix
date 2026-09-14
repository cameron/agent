{ agentTemplate
, agentTranscripts
, content2titlePkg
, coreutils
, curl
, findutils
, gawk
, git
, jq
, lib
, makeWrapper
, md2manHook
, python3
, stdenvNoCC
}:

stdenvNoCC.mkDerivation {
  pname = "agent";
  version = "0.1.0";

  src = lib.cleanSource ../.;

  nativeBuildInputs = [ makeWrapper md2manHook python3 ];

  doInstallCheck = true;
  installCheckPhase = ''
    export AGENT_TRANSCRIPTS_DB="$TMPDIR/transcripts.sqlite"
    export CODEX_HOME="$TMPDIR/codex" CLAUDE_CONFIG_DIR="$TMPDIR/claude"
    export PI_CODING_AGENT_DIR="$TMPDIR/pi"
    mkdir -p "$PI_CODING_AGENT_DIR/sessions"
    cat > "$PI_CODING_AGENT_DIR/sessions/packaged.jsonl" <<'EOF'
    {"type":"session","id":"packaged","cwd":"/fixture"}
    {"type":"message","message":{"role":"user","content":"packaged transcript"}}
    EOF
    "$out/bin/agent" transcripts index --quiet
    "$out/bin/agent" transcripts tail -n 1 --json pi:packaged |
      ${jq}/bin/jq -e '.kind == "user" and .detail == "packaged transcript"'
    "$out/bin/agent-transcripts" sessions --json |
      ${jq}/bin/jq -e '.session_id == "packaged"'
    "$out/bin/agent" resume --list --all
  '';

  # The launcher carries its intrinsic tools so it behaves the same under
  # systemd as in a shell. Harnesses (codex, claude, pi) and tmux stay with
  # the environment: harnesses are pluggable, and the tmux client must match
  # the running server. Filesystem spaces are provided by zfs.space.
  installPhase = ''
    runHook preInstall
    install -Dm755 bin/agent "$out/bin/agent"
    install -Dm755 bin/agent-usage "$out/bin/agent-usage"
    ln -s ${agentTranscripts}/bin/agent-transcripts "$out/bin/agent-transcripts"
    install -Dm755 libexec/agent/usage-claude "$out/libexec/agent/usage-claude"
    install -Dm755 bin/del-agent-user "$out/bin/del-agent-user"
    install -Dm755 bin/lab.repo "$out/bin/lab.repo"
    install -Dm644 share/repository-descriptions.tsv \
      "$out/share/repository-descriptions.tsv"
    install -Dm644 share/emacs/agent-compose.el "$out/share/agent/emacs/agent-compose.el"
    install -Dm644 share/agent/pi/session-id-name.ts \
      "$out/share/agent/pi/session-id-name.ts"
    cp -r ${agentTranscripts}/share/man "$out/share/"
    chmod -R u+w "$out/share/man"
    patchShebangs "$out/bin" "$out/libexec"
    wrapProgram "$out/bin/agent" \
      --set-default AGENT_TRANSCRIPTS_DIR ${agentTranscripts}/libexec/agent \
      --prefix PATH : ${lib.makeBinPath [ agentTemplate content2titlePkg coreutils curl findutils gawk git jq ]}
    wrapProgram "$out/bin/agent-usage" \
      --prefix PATH : ${lib.makeBinPath [ coreutils findutils jq ]}
    wrapProgram "$out/bin/lab.repo" \
      --prefix PATH : ${lib.makeBinPath [ coreutils ]}
    runHook postInstall
  '';

  meta = {
    description = "Run an agent harness inside the workspace conventions";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
    mainProgram = "agent";
  };
}
