let
  # Host key — machine decrypts secrets at boot
  nasa = "age1hzthzt8uw8272vj40xektzmnzwcexmlmew4hm9jpkw32knswuajsaf9cl0";

  # Your personal key — lets you re-encrypt secrets from your laptop
  jmalexan = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL8aGLgotG8GS662Qw4Vce2B8LrBsKxDuHgFU9JIzPQH jmalexan@Book";

  # Same user, the `home` workstation. Not a flake-managed host (only nasa,
  # htpc and Book are), but it is where most editing actually happens, and
  # agenix can only edit a secret it can DECRYPT — so it has to be a recipient
  # in its own right. ~/.ssh/id_ed25519 there is picked up automatically.
  #
  # ⚠️  Adding a recipient here does nothing on its own: every .age file stores
  # its recipient list at encryption time, so existing secrets stay unreadable
  # from `home` until they are rekeyed. See the note at the bottom of this file.
  jmalexanHome = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL7zRypF8PuTmVcdl1Gi+uLdrKpUk4IaF9zjPXIDRdDK jmalexan@home";

  allKeys = [
    nasa
    jmalexan
    jmalexanHome
  ];
in
{
  "secrets/cloudflare-token.age".publicKeys = allKeys;
  # Legacy ACME environment file. It is not deployed anymore, but remains in
  # the managed inventory until its contents are compared with cloudflare-token
  # and it can be removed without discarding the only encrypted copy.
  "secrets/cloudflare-acme-env.age".publicKeys = allKeys;
  "secrets/backblaze-env.age".publicKeys = allKeys;
  "secrets/restic-password.age".publicKeys = allKeys;
  "secrets/step-ca-key.age".publicKeys = allKeys;
  "secrets/samba-password.age".publicKeys = allKeys;
  "secrets/mullvad-wg.age".publicKeys = allKeys;
  "secrets/gitlab-runner-token.age".publicKeys = allKeys;
  "secrets/calibre-desktop-password.age".publicKeys = allKeys;
  "secrets/immich-db-password.age".publicKeys = allKeys;
  "secrets/eufy-credentials.age".publicKeys = allKeys;
  "secrets/grimmory-db-password.age".publicKeys = allKeys;
  "secrets/bookorbit-env.age".publicKeys = allKeys;
}
# ── Adding or removing a key ──────────────────────────────────────────────────
# The recipient list above is only consulted when a secret is (re-)encrypted.
# After editing it, rekey every secret ONCE, from a machine that already holds
# a private key able to decrypt them — otherwise there is nothing to re-encrypt
# from. `agenix -r` reads this file and rewrites each .age in place:
#
#   nix develop            # puts agenix on PATH
#   agenix -r
#   git commit -am "Rekey secrets" && git push
#
# From Book that is just `agenix -r` (it finds ~/.ssh/id_ed25519). From nasa
# itself, point it at the host key instead:
#
#   agenix -r -i /etc/ssh/ssh_host_ed25519_key
#
# eufy-credentials.age is already encrypted to all three recipients — it was
# created after jmalexanHome was added — so it is editable from `home` today.
# Everything above it in the list is not, until the rekey runs.
