let
  # Host key — machine decrypts secrets at boot
  nasa = "age1hzthzt8uw8272vj40xektzmnzwcexmlmew4hm9jpkw32knswuajsaf9cl0";

  # Your personal key — lets you re-encrypt secrets from your laptop
  jmalexan = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL8aGLgotG8GS662Qw4Vce2B8LrBsKxDuHgFU9JIzPQH jmalexan@Book";

  allKeys = [ nasa jmalexan ];
in {
  "secrets/cloudflare-token.age".publicKeys     = allKeys;
  "secrets/backblaze-env.age".publicKeys        = allKeys;
  "secrets/restic-password.age".publicKeys      = allKeys;
  "secrets/step-ca-key.age".publicKeys          = allKeys;
  "secrets/samba-password.age".publicKeys       = allKeys;
  "secrets/mullvad-wg.age".publicKeys           = allKeys;
}
