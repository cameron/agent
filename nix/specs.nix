{ pkgs, rm4agent, specs ? [ ] }:
# Terminal fixtures must not see the operator's processes, sockets, or home.
pkgs.runCommand "agent-behavior" {
  nativeBuildInputs = with pkgs; [
    bash coreutils curl diffutils emacs-nox findutils gawk git gnugrep gnused
    gcc go inetutils jq nodejs procps python3 tmux util-linux rm4agent
  ];
} ''
  cp -R ${pkgs.lib.cleanSource ../.} source
  chmod -R u+w source
  cd source
  find spec bin libexec agent-process-collect -type f -exec sed -i \
    's|/usr/bin/env|${pkgs.coreutils}/bin/env|g' {} +
  patchShebangs .
  export HOME="$TMPDIR/home" GOCACHE="$TMPDIR/go-cache"
  export LC_ALL=C.UTF-8
  export XDG_RUNTIME_DIR="$TMPDIR/runtime" RM4AGENT_ROOT="$TMPDIR/archive"
  mkdir -p "$HOME" "$XDG_RUNTIME_DIR"
  git config --global user.name fixture
  git config --global user.email fixture@example.invalid
  printf '%s\n' 'set -g base-index 1' 'setw -g pane-base-index 1' >"$HOME/.tmux.conf"
  for spec in ${if specs == [ ] then "spec/*/test.sh" else
    pkgs.lib.escapeShellArgs (map (name: "spec/${name}/test.sh") specs)}; do
    echo "== $spec"
    bash "$spec"
  done
  touch "$out"
''
