{
  user = {
    name = "jmalexan";
    fullName = "Jonathan Alexander";
    email = "me@jmalexan.com";
  };

  timeZone = "America/New_York";
  repository = "github:jmalexan/nix";

  nasa = {
    domain = "nasa.jmalexan.com";
    serviceRoot = "/Data/smb/Internal/Services";
    hostVethIP = "10.200.200.1";
    namespaceVethIP = "10.200.200.2";
    lanSubnet = "10.0.0.0/23";
  };
}
