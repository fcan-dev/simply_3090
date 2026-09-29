# simply_3090

Running local LLMs on a single 3090 / 3090 Ti (24 GB),
stock llama.cpp (no custom engine patches), Docker. Each subfolder is one working setup,
fully documented: what it is, why each flag exists, measured numbers, and
scripts you can actually run on your own box.

## Setups

| Folder | What it runs | Highlights |
|---|---|---|
| [`qwen3.8-27b/`](qwen3.8-27b/) | Qwen3.8-27B (Q4_K_XL) + vision, **262k context**, vision offloaded to CPU, built-in MTP drafter | my go-to local coding setup (pi agent) — full 256k context on 24 GB; energy-optimised 350 W power cap with the measured underclock sweep behind it |

## qwen3.8-27b at a glance

**Speed** — 3090 Ti @ 350 W cap, this exact setup:

| Workload | tok/s |
|---|---|
| Decode, short prompt (MTP drafter n=2, 76% acceptance) | 77.6 |
| Decode, ~20k-token context | 66.0 |
| Prefill, ~20k-token context | 1,185 |

![Qwen3.8-27B GGUF quant ladder — top-1% accuracy vs quant size by provider; the running quant UD-Q4_K_XL is circled](qwen3.8-27b/media/quant-ladder-q4kxl.png)

*The circled **UD-Q4_K_XL** is the highest quant that still runs at full 262k
context on 24 GB — the prod-grade pick for daily coding.*

![Underclock sweep 250–400 W: energy cost and speed vs measured GPU power; knee ≈ 350 W](qwen3.8-27b/media/energy_speed_full.png)

*350 W keeps ~91% of prefill and ~78% of long-context decode speed at ~80% of
the 450 W power.*

Every setup folder is self-contained:

```
<setup>/
├── README.md    # the write-up
├── compose/     # docker compose (annotated with the measured boot record)
└── scripts/     # start / stop / power-limit (run on the GPU box)
```
