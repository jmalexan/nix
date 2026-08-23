{ pkgs }:

# nixpkgs 26.05 currently packages Igir 5.0.2. Keep the upstream source and
# npm dependency graph pinned here so RomM can use the current release without
# updating the unrelated systems that consume this flake's unstable input.
pkgs.buildNpmPackage rec {
  pname = "igir";
  version = "5.4.0";

  src = pkgs.fetchFromGitHub {
    owner = "emmercm";
    repo = "igir";
    rev = "v${version}";
    hash = "sha256-XdTALeArfODUdYGdiCNfdunses1B+P3OAv5etMtVeSM=";
  };

  npmDepsHash = "sha256-hmp7bdCXoivTeyx03Dq3Oa9Rb5BpGQgA/c1FFxrG3rE=";

  postPatch = ''
    patchShebangs scripts/update-readme-help.sh
  '';

  nativeBuildInputs = [ pkgs.autoPatchelfHook ];

  buildInputs = [
    (pkgs.lib.getLib pkgs.stdenv.cc.cc)
    pkgs.libusb1
    pkgs.libuv
    pkgs.libz
    pkgs.lz4
    pkgs.sdl2-compat
    pkgs.systemd
  ];

  # Bundled but irrelevant to this workflow; the glibc binary is used here.
  autoPatchelfIgnoreMissingDeps = [ "libc.musl-x86_64.so.1" ];

  meta = {
    description = "ROM collection manager for filtering, sorting, patching, archiving, and reporting";
    mainProgram = "igir";
    homepage = "https://igir.io";
    changelog = "https://github.com/emmercm/igir/releases/tag/v${version}";
    license = pkgs.lib.licenses.gpl3Plus;
    platforms = pkgs.lib.platforms.linux;
  };
}
