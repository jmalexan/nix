{ pkgs }:
let
  python = pkgs.python3.withPackages (
    ps: with ps; [
      fastapi
      uvicorn
      webauthn
      pywebpush
      pytest
      httpx
    ]
  );
  frontend = pkgs.buildNpmPackage {
    pname = "microapp-approvals-web";
    version = "0.1.0";
    src = pkgs.lib.cleanSourceWith {
      src = ./web;
      filter =
        path: _:
        !(builtins.elem (builtins.baseNameOf path) [
          "node_modules"
          "dist"
          "test-results"
          "playwright-report"
        ]);
    };
    npmDepsHash = "sha256-BDSSN7KbBW7og0L552pFGoubyertw0eHGekeaRY0IAY=";
    preBuild = ''
      cp ${./openapi.json} ../openapi.json
      cp src/api.d.ts expected-api.d.ts
      npm run api:types
      npx --no-install prettier --write src/api.d.ts
      diff expected-api.d.ts src/api.d.ts
      rm expected-api.d.ts
    '';
    installPhase = ''
      mkdir -p "$out"
      cp -r dist/. "$out/"
    '';
  };
  server = pkgs.writeShellApplication {
    name = "microapp-approvals";
    runtimeInputs = [ python ];
    text = ''
      export PYTHONPATH=${./backend}
      export MICROAPP_STATIC=${frontend}
      exec uvicorn microapps.api:from_environment --factory --host 127.0.0.1 --port "''${PORT:-8092}"
    '';
  };
  access = pkgs.writeShellApplication {
    name = "nasa-approved-access";
    runtimeInputs = [
      python
      pkgs.openssh
    ];
    text = ''
      export PYTHONPATH=${./backend}
      exec python -m microapps.access "$@"
    '';
  };
in
{
  inherit
    python
    frontend
    server
    access
    ;
  tests = pkgs.runCommand "microapps-tests" { nativeBuildInputs = [ python ]; } ''
    cp -R ${./backend} backend
    cp ${./export_api.py} export_api.py
    chmod -R u+w backend
    export PYTHONPATH=$PWD/backend
    export PYTHONDONTWRITEBYTECODE=1
    pytest -q -p no:cacheprovider ${./backend/tests}
    python export_api.py
    diff openapi.json ${./openapi.json}
    touch "$out"
  '';
}
