{ pkgs }:
let
  python = pkgs.python3.withPackages (
    ps: with ps; [
      fastapi
      uvicorn
      httpx
      pytest
      cryptography
    ]
  );
  client = pkgs.writeShellApplication {
    name = "git-broker";
    runtimeInputs = [
      python
      pkgs.git
    ];
    text = ''
      export PYTHONPATH=${./.}
      exec python -m git_broker.client "$@"
    '';
  };
  server = pkgs.writeShellApplication {
    name = "git-broker-server";
    runtimeInputs = [
      python
      pkgs.git
    ];
    text = ''
      export PYTHONPATH=${./.}
      export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
      export NIX_SSL_CERT_FILE="$SSL_CERT_FILE"
      exec uvicorn git_broker.api:from_environment --factory --host 127.0.0.1 --port "''${PORT:-8097}" --limit-concurrency 8 --no-access-log
    '';
  };
in
{
  inherit python client server;
  tests =
    pkgs.runCommand "git-broker-tests"
      {
        nativeBuildInputs = [
          python
          pkgs.git
        ];
      }
      ''
        export PYTHONPATH=${./.}
        export PYTHONDONTWRITEBYTECODE=1
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        pytest -q -p no:cacheprovider ${./tests}
        touch "$out"
      '';
}
