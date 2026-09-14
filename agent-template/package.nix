{
  buildGoModule,
  md2manHook,
}:

buildGoModule {
  pname = "agent-template";
  version = "0.1.0";

  src = ./src;
  vendorHash = null;

  nativeBuildInputs = [ md2manHook ];
  markdownManpagesRoot = ./docs/man;

  postInstall = ''
    mv "$out/bin/agent-template" "$out/bin/agent.template"
  '';

  meta.description = "Render a templated agent instruction file";
}
