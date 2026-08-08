{ pkgs, ... }: {
  # Shared runtime for every OCI application on nasa. Keeping this here avoids
  # making unrelated containers depend on whichever application happened to
  # enable Docker first.
  virtualisation.docker = {
    enable = true;
    package = pkgs.docker_29;
  };
  virtualisation.oci-containers.backend = "docker";
}
