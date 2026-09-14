{
  lib,
  md2manHook,
  python3,
  stdenv,
}:

stdenv.mkDerivation {
  pname = "agent-transcripts";
  version = "0.1.0";

  dontUnpack = true;
  nativeBuildInputs = [ md2manHook ];
  markdownManpagesRoot = ./docs/man;

  doCheck = true;
  nativeCheckInputs = [ python3 ];
  checkPhase = ''
    python3 ${./test_usage.py} ${./agent_transcripts.py}
    python3 ${./test_readers.py} ${./agent_transcripts.py}
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 ${./agent_transcripts.py} "$out/libexec/agent/agent_transcripts.py"
    install -Dm755 ${./agent_sessions.py} "$out/libexec/agent/agent_sessions.py"
    for script in "$out"/libexec/agent/*.py; do
      substituteInPlace "$script" \
        --replace-fail '#!/usr/bin/env python3' '#!${python3}/bin/python3'
    done
    mkdir -p "$out/bin"
    ln -s ../libexec/agent/agent_transcripts.py "$out/bin/agent-transcripts"

    runHook postInstall
  '';

  meta = {
    description = "Index agent session transcripts into SQLite for audits";
    license = lib.licenses.mit;
    mainProgram = "agent-transcripts";
    platforms = lib.platforms.unix;
  };
}
