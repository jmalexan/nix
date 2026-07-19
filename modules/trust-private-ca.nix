# Trust our private CA host-wide so internal services and tools (Music
# Assistant, scripts, anything using OpenSSL/Python) can verify the certs it
# issues — served by nasa's nginx for *.nasa.jmalexan.com. Imported by every
# NixOS host via commonModules; nasa additionally signs with this CA in
# hosts/nasa/services/cert-renew.nix.
{ ... }:

{
  security.pki.certificateFiles = [ ../certs/ca.crt ];
}
