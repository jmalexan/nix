{ ... }: let
  ssl = {
    forceSSL          = true;
    sslCertificate    = "/var/lib/nginx/certs/server.crt";
    sslCertificateKey = "/var/lib/nginx/certs/server.key";
  };

  # Streaming LLM responses need buffering off and long timeouts so tokens
  # reach the client live instead of being held by nginx.
  streamingProxy = ''
    proxy_buffering      off;
    proxy_read_timeout   600s;
    proxy_send_timeout   600s;
  '';
in {
  # ── Ollama ─────────────────────────────────────────────────────────────────
  # CUDA-accelerated inference backend. Speaks the OpenAI API at :11434, used
  # both by Open WebUI and by external dev tools (Aider, Continue, Zed) over
  # the tailnet.
  services.ollama = {
    enable = true;
    acceleration = "cuda";
    host = "127.0.0.1";
    port = 11434;

    environmentVariables = {
      # Keep the active model resident for half an hour so back-to-back
      # requests don't pay the VRAM reload cost.
      OLLAMA_KEEP_ALIVE = "30m";
      OLLAMA_NUM_PARALLEL = "2";
    };

    # Pre-pull on activation; ad-hoc `ollama pull <name>` still works.
    loadModels = [
      "qwen2.5-coder:14b"
      "llama3.1:8b"
    ];
  };

  # ── Open WebUI ─────────────────────────────────────────────────────────────
  # ChatGPT-style frontend with multi-user accounts and conversation history.
  # Mobile-friendly so it works from the iPad as a PWA.
  services.open-webui = {
    enable = true;
    host = "127.0.0.1";
    port = 8093;
    environment = {
      OLLAMA_BASE_URL = "http://127.0.0.1:11434";
      ANONYMIZED_TELEMETRY = "False";
      DO_NOT_TRACK = "True";
      SCARF_NO_ANALYTICS = "True";
    };
  };

  # ── Reverse proxy ──────────────────────────────────────────────────────────
  services.nginx.virtualHosts = {
    "chat.nasa.jmalexan.com" = ssl // {
      serverAliases = [ "chat" ];
      extraConfig = streamingProxy;
      locations."/" = {
        proxyPass       = "http://127.0.0.1:8093";
        proxyWebsockets = true;
      };
    };

    "ollama.nasa.jmalexan.com" = ssl // {
      serverAliases = [ "ollama" ];
      # The Ollama API is unauthenticated, so restrict it to the tailnet
      # (100.64.0.0/10 is Tailscale's CGNAT range) and the local LAN bridge.
      extraConfig = streamingProxy + ''
        client_max_body_size 50M;
        allow 100.64.0.0/10;
        allow 10.0.0.0/8;
        allow 127.0.0.1;
        deny  all;
      '';
      locations."/" = {
        proxyPass = "http://127.0.0.1:11434";
      };
    };
  };
}
