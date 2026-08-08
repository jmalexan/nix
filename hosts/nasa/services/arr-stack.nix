{ lib, ... }:

let
  apps = [
    "sonarr"
    "radarr"
    "lidarr"
    "bazarr"
  ];

  mkArrService = name: {
    users.users.${name}.extraGroups = [ "media" ];

    services.${name} = {
      enable = true;
      dataDir = "/Data/smb/Internal/Services/${name}";
      openFirewall = false;
    };

    # The applications share Mullvad's namespace: internet traffic exits the
    # VPN, inter-app traffic uses localhost, and nginx reaches each UI over the
    # namespace veth at the documented port.
    systemd.services.${name} = {
      after = [
        "mullvad-netns.service"
      ]
      ++ lib.optional (name == "bazarr") "nasa-service-directories.service";
      requires = [
        "mullvad-netns.service"
      ]
      ++ lib.optional (name == "bazarr") "nasa-service-directories.service";
      serviceConfig.NetworkNamespacePath = "/run/netns/mullvad";
    };
  };
in
lib.mkMerge (map mkArrService apps)
