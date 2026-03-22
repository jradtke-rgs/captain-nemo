# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

`captain-nemo` is an exploration and reference project for running NVIDIA NemoClaw on a personal GPU cluster. It documents setup, configuration, and usage patterns to serve as a guide others can follow.

## Infrastructure

| Node | Address | Role |
|------|---------|------|
| NVIDIA DGX Spark | $USER@10.10.12.251 | Nemotron inference (GPU compute) |
| Mac Mini (Ubuntu 24.04) | $USER@10.10.12.252 | Hosts NemoClaw; calls DGX Spark for inference |
| MacBook Pro | local | Development, Claude orchestration |

**Critical guardrail:** NemoClaw (and OpenClaw) must NEVER be given access to any AI infrastructure other than the DGX Spark. This is a hard security boundary.

## Related Repository

The forked NemoClaw source lives at `../NemoClaw` (sibling directory). Key areas:
- `scripts/setup-spark.sh` — DGX Spark-specific installation
- `spark-install.md` — Spark installation guide
- `nemoclaw-blueprint/policies/` — Security policy presets
- `nemoclaw-blueprint/blueprint.yaml` — Inference profiles (default, nim-local, vllm)

## NemoClaw Stack

- **CLI:** TypeScript (Node.js ≥20), Commander.js — built via `cd nemoclaw && npm install && tsc`
- **Orchestration:** Python 3.11+, PyYAML blueprints
- **Sandbox:** Docker + NVIDIA OpenShell (Landlock + seccomp + network policy)
- **Models:** Nemotron 3 Super 120B (~87 GB); also NIM, vLLM, Ollama backends
- **Docs:** Sphinx + MyST + NVIDIA theme

## NemoClaw Commands (from `../NemoClaw`)

```bash
make check        # Lint TypeScript + Python
make format       # Auto-format all code
make docs         # Build Sphinx documentation
make docs-live    # Serve docs with auto-reload
npm test          # Run Node.js integration tests
```

## Status

NemoClaw is alpha software (available March 16, 2026). Expect breaking changes.
