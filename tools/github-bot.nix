{ pkgs }:
let
  python = pkgs.python3.withPackages (ps: [ ps.cryptography ]);
in
pkgs.writeShellApplication {
  name = "github-bot";
  runtimeInputs = [
    pkgs.gh
    pkgs.git
  ];
  text = ''
    exec ${python}/bin/python ${./github-bot.py} "$@"
  '';
}
