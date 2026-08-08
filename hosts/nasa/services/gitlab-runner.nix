{ config, ... }: {
  age.secrets.gitlab-runner-token = {
    file = ../../../secrets/gitlab-runner-token.age;
  };

  users.users.gitlab-runner = {
    isSystemUser = true;
    group = "gitlab-runner";
    extraGroups = [ "docker" ];
  };
  users.groups.gitlab-runner = { };

  services.gitlab-runner = {
    enable = true;
    settings.concurrent = 4;

    services.docker = {
      authenticationTokenConfigFile = config.age.secrets.gitlab-runner-token.path;
      executor = "docker";
      # renovate: datasource=docker depName=docker.io/library/alpine
      dockerImage = "alpine:latest";
      requestConcurrency = 4;
    };
  };
}
