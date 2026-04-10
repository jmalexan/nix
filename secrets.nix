let
  # Host key — machine decrypts secrets at boot
  nasa = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII8xM12gVZXzdvRDHwXwP9kIxj5fecxG5gU39rSTxUXr root@nixhost";

  # Your personal key — lets you re-encrypt secrets from your laptop
  jmalexan = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBlAyfNwSQbGKAGoNBPJzUfwDWwFoeuVUnXOM7p8rnkH jmalexan@nixhost";

  allKeys = [ nasa jmalexan ];
in {
  "secrets/cloudflare-token.age".publicKeys     = allKeys;
  "secrets/backblaze-env.age".publicKeys        = allKeys;
  "secrets/restic-password.age".publicKeys      = allKeys;
  "secrets/step-ca-key.age".publicKeys          = allKeys;
  "secrets/samba-password.age".publicKeys       = allKeys;
}
