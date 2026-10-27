# Ollama

An Omarchy bar widget for the local LLM server [Ollama](https://ollama.com), set up for an
AMD laptop with an integrated GPU (Vulkan) and for Ask Claude's offline mode.

- **Bar:** a robot icon `󰚩`. Bright while a model is in memory or a download runs, faded while
  Ollama is stopped. Left click opens the panel, right click refreshes.
- **Panel:**
  - a switch to start or stop Ollama (stopping frees all model memory), and *Start at login*;
  - RAM available, GPU memory in use (on the Radeon 880M this is GTT, shared system RAM),
    disk used by models;
  - **In memory:** each loaded model, its size, how much of it runs on the GPU, the context
    size, and when it unloads; unload frees the memory now;
  - **Models:** every model on disk with size, quantization and context length; buttons to
    load or unload, run a speed test, use it in Ask Claude when offline, and delete
    (click twice). Click a row to see what it can do (images, tools, thinking) and the
    last test: tokens per second and the model's short Lao answer, so you can judge its
    Lao quality;
  - **Download:** the recommended models not yet installed, any model name from
    [ollama.com/library](https://ollama.com/library), progress over the whole model (its
    size comes from the registry) with speed and time left, a queue, and cancel (pulling
    again resumes). A dropped connection is retried twice, resuming where it stopped.

## Keys

| Key | Action |
|---|---|
| `R` | Refresh |
| `S` | Start or stop Ollama |
| `/` | Type a model name to download |
| `Esc` | Close |

## Command line

`bin/ollamactl` does all the work and is usable on its own:

```sh
ollamactl status --full          # JSON
ollamactl pull gemma4:e4b-it-qat qwen3.6:35b-a3b
ollamactl test gemma4:26b-a4b-it-qat
ollamactl use gemma4:26b-a4b-it-qat   # Ask Claude's offline model
ollamactl unload
ollamactl service start|stop|enable|disable
```

IPC: `omarchy-shell shadowone.ollama toggle | refresh | pull <name> | state`.

## Server

Ollama runs as the systemd **user** unit `~/.config/systemd/user/ollama.service`
(models in `~/.ollama/models`, localhost only, the integrated GPU enabled with
`OLLAMA_IGPU_ENABLE=1`, one model and one request at a time, 8K context by default,
flash attention with a q8 KV cache, Ollama cloud features off). The system unit from the
`ollama` package stays disabled.

Ollama logs every API request to the journal and a user unit cannot filter that, so a
refresh asks only `/api/ps`; the version and model list are cached in
`~/.local/state/ollama-panel/tags-cache.json` until the server restarts or a model is added
or removed.
