{ pkgs }:
let
  python = pkgs.python3.withPackages (
    ps: with ps; [
      aiohttp
      fastapi
      uvicorn
      webauthn
      pywebpush
      httpx
      pytest
      cryptography
    ]
  );
  source = pkgs.lib.fileset.toSource {
    root = ./.;
    fileset = pkgs.lib.fileset.unions [
      ./preview.py
      ./serve.py
    ];
  };
in
{
  inherit python;
  package = pkgs.writeShellApplication {
    name = "preview";
    runtimeInputs = [
      python
      pkgs.nodejs
      pkgs.systemd
    ];
    text = ''
      exec python ${source}/preview.py "$@"
    '';
  };
  tests = pkgs.runCommand "preview-tests" { nativeBuildInputs = [ python ]; } ''
    cp -R ${./.} source
    chmod -R u+w source
    cd source
    python -m pytest -q test_preview.py
    touch "$out"
  '';
}
