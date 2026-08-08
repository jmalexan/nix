_:

{
  # Plasma's MPRIS module grabs these media keys before the focused player can
  # receive them. The HTPC uses mpv's own remote-friendly seek intervals, so
  # leave the keys unassigned globally and let them reach mpv directly.
  programs.plasma = {
    enable = true;

    shortcuts = {
      mediacontrol = {
        playpausemedia = [ ];
        stopmedia = [ ];
        seekforwardmedia = [ ];
        seekbackwardmedia = [ ];
      };

      # Keep these synchronized with hosts/htpc/remote.nix.
      kwin."Window Close" = "Alt+F4";
      plasmashell."Toggle Bigscreen Home Overlay" = "Meta+O";
    };
  };
}
