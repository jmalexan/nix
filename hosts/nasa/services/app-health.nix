{ pkgs, ... }:
{
  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "nasa-apps-health";
      runtimeInputs = [ pkgs.curl ];
      text = ''
        # Probe nginx, TLS, the short Host, and the current authentication API.
        # An active systemd unit alone can still be running an old backend.
        for app in approve updates notifications backups; do
          endpoint=/api/auth/methods
          if [[ "$app" == notifications ]]; then endpoint=/health; fi
          curl --fail --silent --show-error --output /dev/null \
            --max-time 10 --retry 5 --retry-delay 1 --retry-all-errors \
            --resolve "$app:443:127.0.0.1" "https://$app$endpoint"
        done
      '';
    })
  ];
}
