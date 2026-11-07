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
          "dist-auth"
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
      cp ${../../hosts/nasa/services/updates-dashboard/openapi.json} updates-openapi.json
      npx --no-install openapi-typescript updates-openapi.json -o updates-api.d.ts
      npx --no-install prettier --write updates-api.d.ts
      diff updates-api.d.ts ${../../hosts/nasa/services/updates-dashboard/api.d.ts}
      rm updates-api.d.ts updates-openapi.json
    '';
    installPhase = ''
      mkdir -p "$out"
      cp -r dist/. "$out/"
      cp dist-auth/auth.js "$out/auth.js"
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
  accessSource = pkgs.lib.fileset.toSource {
    root = ./backend;
    fileset = pkgs.lib.fileset.unions [
      ./backend/microapps/__init__.py
      ./backend/microapps/access.py
      ./backend/microapps/http.py
    ];
  };
  access = pkgs.writeShellApplication {
    name = "nasa-approved-access";
    runtimeInputs = [
      pkgs.python3
      pkgs.openssh
    ];
    text = ''
      export PYTHONPATH=${accessSource}
      exec python -m microapps.access "$@"
    '';
  };
  authAdmin = pkgs.writeShellApplication {
    name = "microapp-auth-admin";
    runtimeInputs = [ python ];
    text = ''
      export PYTHONPATH=${./backend}
      exec python -m microapps.auth_admin "$@"
    '';
  };
in
{
  inherit
    python
    frontend
    server
    access
    authAdmin
    ;
  tests = pkgs.runCommand "microapps-tests" { nativeBuildInputs = [ python ]; } ''
    cp -R ${./backend} backend
    cp ${./export_api.py} export_api.py
    chmod -R u+w backend
    export PYTHONPATH=$PWD/backend:${../git-broker}:${../../hosts/nasa/services/updates-dashboard}
    export PYTHONDONTWRITEBYTECODE=1
    pytest -q -p no:cacheprovider ${./backend/tests}
    python export_api.py
    diff openapi.json ${./openapi.json}
    python ${../../hosts/nasa/services/updates-dashboard/export_api.py} > updates-openapi.json
    diff updates-openapi.json ${../../hosts/nasa/services/updates-dashboard/openapi.json}
    touch "$out"
  '';
}
