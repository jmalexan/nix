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
      dockerImage = "alpine:latest@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b";
      requestConcurrency = 4;
    };
  };
}
