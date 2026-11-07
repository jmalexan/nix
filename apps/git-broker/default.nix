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
  # Keep server, tests, and packaging edits out of the VM closure.
  clientSource = pkgs.lib.fileset.toSource {
    root = ./.;
    fileset = pkgs.lib.fileset.unions [
      ./git_broker/__init__.py
      ./git_broker/client.py
      ./git_broker/request.py
    ];
  };
  client = pkgs.writeShellApplication {
    name = "git-broker";
    runtimeInputs = [
      pkgs.python3
      pkgs.git
    ];
    text = ''
      export PYTHONPATH=${clientSource}
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
      exec uvicorn git_broker.api:from_environment --factory --host 127.0.0.1 --port "''${PORT:-18097}" --limit-concurrency 8 --no-access-log
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
        export GIT_BROKER_TEST_CLIENT=${client}/bin/git-broker
        export PYTHONPATH=${./.}
        export PYTHONDONTWRITEBYTECODE=1
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        pytest -q -p no:cacheprovider ${./tests}
        touch "$out"
      '';
}
