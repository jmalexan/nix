{ pkgs }:
let
  platform = import ../microapps { inherit pkgs; };
  static = pkgs.runCommand "backups-web" { } ''
    mkdir -p "$out"
    cp ${./web}/index.html ${./web}/app.js ${./web}/icon.svg ${./web}/manifest.webmanifest "$out/"
    cp ${platform.frontend}/auth.js "$out/auth.js"
    cp ${../microapps/web/src/shared/components.js} "$out/components.js"
    cp ${../microapps/web/src/shared/component-shadow.css} "$out/component-shadow.css"
    cat ${../microapps/web/src/shared/tokens.css} ${../microapps/web/src/shared/components.css} ${./web/styles.css} > "$out/styles.css"
  '';
  server = pkgs.writeShellApplication {
    name = "backups-server";
    runtimeInputs = [ platform.python ];
    text = ''
      export PYTHONPATH=${./.}:${../microapps/backend}
      exec uvicorn api:from_environment --factory --host 127.0.0.1 --port "''${PORT:-8101}" --no-access-log
    '';
  };
in
{
  inherit static server;
  inherit (platform) python;
  tests = pkgs.runCommand "backups-tests" { nativeBuildInputs = [ platform.python ]; } ''
    test -s ${static}/styles.css
    test -x ${server}/bin/backups-server
    export BACKUPS_TEST_LAUNCHER=${server}/bin/backups-server
    export PYTHONPATH=${./.}:${../microapps/backend}:${../../hosts/nasa/services/updates-dashboard}
    export PYTHONDONTWRITEBYTECODE=1
    pytest -q -p no:cacheprovider ${./tests}
    python ${./export_api.py} > openapi.json
    diff openapi.json ${./openapi.json}
    touch "$out"
  '';
}
