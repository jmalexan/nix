{ pkgs, ... }: let
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
    # 26.05 dropped `acceleration`; the backend is chosen by picking the
    # matching package variant instead.
    package = pkgs.ollama-cuda;
    host = "127.0.0.1";
    port = 11434;

    # The RTX 3080 has 10 GiB of VRAM and is shared with Frigate (TensorRT
    # detection + NVDEC) and Jellyfin (NVENC). Frigate alone holds ~1.2 GiB
    # steady-state, so the practical inference budget is ~8 GiB. Every setting
    # below exists to keep a model fully resident inside that budget — a model
    # that spills layers to CPU runs roughly an order of magnitude slower on
    # the spilled portion, which dominates any other tuning.
    environmentVariables = {
      # Reserve 2 GiB that Ollama's autosizing will never allocate. Without
      # this, a model loaded while the cameras are quiet can size itself
      # against VRAM that Frigate needs once activity picks up, and video
      # recording matters more here than chat latency.
      OLLAMA_GPU_OVERHEAD = "2147483648";

      # Halves KV cache memory versus the f16 default at negligible quality
      # cost. Requires flash attention, which is off by default.
      OLLAMA_FLASH_ATTENTION = "1";
      OLLAMA_KV_CACHE_TYPE = "q8_0";

      # Each parallel slot reserves its own KV cache, so >1 multiplies KV
      # memory. This is effectively single-user, so keep it at 1. (Also the
      # current Ollama default — previously set to 2, which doubled KV for
      # no benefit.)
      OLLAMA_NUM_PARALLEL = "1";

      # Pin the context rather than letting Ollama auto-pick from free VRAM;
      # auto-sizing is exactly the fragile behaviour to avoid on a shared GPU.
      # At q8_0 KV this costs roughly 0.5–1 GiB depending on the model. Raise
      # toward 32768 only if `nvidia-smi` shows spare headroom in practice;
      # qwen3.5:9b is close enough to the budget that context is the first
      # thing to cut if it starts offloading.
      OLLAMA_CONTEXT_LENGTH = "16384";

      # Release VRAM back to Frigate promptly. Reloading a few GiB from page
      # cache costs a few seconds, which is the right trade against holding
      # the card idle for half an hour.
      OLLAMA_KEEP_ALIVE = "5m";
    };

    # Pre-pull on activation; ad-hoc `ollama pull <name>` still works.
    #
    # Sized to fit the ~8 GiB budget. The previous qwen2.5-coder:14b is 9.0 GiB
    # of weights alone and could not fit, so it always ran partly on CPU.
    # Models are loaded on demand and evicted to make room, so each only has to
    # fit individually — the combined footprint here is not a constraint.
    #
    # Ruled out as too large for this card: qwen3.5:27b (17 GiB), qwen3.6
    # (27B/35B), qwen3-coder (no variant below 30B-A3B at 19 GiB), gemma4:12b,
    # devstral and codestral. None can be usefully offloaded to RAM either —
    # the ZFS ARC cap leaves only ~16 GiB of system memory for every service
    # on the host.
    loadModels = [
      # 6.6 GiB — current-gen general/agentic model, tool calling + thinking
      # modes, which is what the harness actually exercises. Supersedes both
      # llama3.1:8b and qwen3:8b. This is the largest model that fits, so
      # confirm it stays 100% GPU at the context set above before trusting it.
      "qwen3.5:9b"

      # 4.7 GiB — kept despite its age specifically for fill-in-middle, which
      # editor autocomplete needs and general instruct models are not trained
      # for. Qwen3.5-Coder does ship 7B/14B tiers upstream but has no official
      # Ollama packaging yet; revisit this pin once it lands.
      "qwen2.5-coder:7b"

      # 3.4 GiB — current-gen small model with room to spare, for when the 9B
      # is too tight alongside camera activity or a faster reply matters.
      "qwen3.5:4b"
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
        # Ollama validates the Host header and rejects anything that isn't
        # loopback with a bare 403 — no body, and nothing in nginx's error log,
        # because nginx proxied happily and simply relayed upstream's refusal.
        # recommendedProxySettings sends `Host $host`, so every request through
        # this vhost arrived as ollama.nasa.jmalexan.com and was refused.
        #
        # Overriding Host in extraConfig does not work: the module emits
        # locations.<n>.extraConfig *before* the recommended-settings include,
        # so `Host $host` would win. Disable the include for this location and
        # set the forwarding headers explicitly instead.
        recommendedProxySettings = false;
        extraConfig = ''
          proxy_set_header Host localhost:11434;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
        '';
      };
    };
  };
}
