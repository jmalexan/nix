{ config, pkgs, ... }: {
  age.secrets.gitlab-runner-token = {
    file = ../../../secrets/gitlab-runner-token.age;
  };

  virtualisation.docker.enable = true;
  virtualisation.docker.package = pkgs.docker_29;

  users.users.gitlab-runner = {
    isSystemUser = true;
    group = "gitlab-runner";
    extraGroups = [ "docker" ];
  };
  users.groups.gitlab-runner = {};

  services.gitlab-runner = {
    enable = true;
    settings.concurrent = 4;

    services.docker = {
      authenticationTokenConfigFile = config.age.secrets.gitlab-runner-token.path;
      executor = "docker";
      dockerImage = "alpine:latest";
      requestConcurrency = 4;
    };
  };
}
