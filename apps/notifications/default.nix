{ pkgs }:
let
  python = pkgs.python3.withPackages (
    ps: with ps; [
      fastapi
      uvicorn
      httpx
      h2
      pyjwt
      cryptography
      pytest
    ]
  );
  frontend = pkgs.runCommand "notification-settings" { } ''
    mkdir -p "$out/shared"
    cp ${./web}/* "$out/"
    cp ${../microapps/web/src/shared/tokens.css} "$out/shared/tokens.css"
    cp ${../microapps/web/src/shared/components.css} "$out/shared/components.css"
  '';
  server = pkgs.writeShellApplication {
    name = "notification-bridge";
    runtimeInputs = [ python ];
    text = ''
      export PYTHONPATH=${./backend}
      export NOTIFICATIONS_STATIC=${frontend}
      exec uvicorn notifications.api:from_environment --factory --host 127.0.0.1 --port "''${PORT:-8093}" --no-access-log
    '';
  };
  worker = pkgs.writeShellApplication {
    name = "notification-delivery";
    runtimeInputs = [ python ];
    text = ''
      export PYTHONPATH=${./backend}
      exec python -m notifications.delivery
    '';
  };
  admin = pkgs.writeShellApplication {
    name = "notification-admin";
    runtimeInputs = [ python ];
    text = ''
      export PYTHONPATH=${./backend}
      exec python -m notifications.admin "$@"
    '';
  };
in
{
  inherit
    python
    frontend
    server
    worker
    admin
    ;
  tests = pkgs.runCommand "notification-tests" { nativeBuildInputs = [ python ]; } ''
    export PYTHONPATH=${./backend}
    export PYTHONDONTWRITEBYTECODE=1
    export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
    pytest -q -p no:cacheprovider ${./backend/tests}
    python ${./export_api.py} > openapi.json
    diff openapi.json ${./openapi.json}
    touch "$out"
  '';
}
