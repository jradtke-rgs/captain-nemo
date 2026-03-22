# captain-nemo

> A reference stack for running [NVIDIA NemoClaw](https://github.com/NVIDIA/NemoClaw) on personal GPU infrastructure — fully on-prem, air-gapped from cloud AI endpoints, and built in collaboration with [Claude Code](https://claude.ai/code).

[![NemoClaw](https://img.shields.io/badge/NemoClaw-0.1.0_alpha-76b900?logo=nvidia&logoColor=white)](https://github.com/NVIDIA/NemoClaw)
[![OpenShell](https://img.shields.io/badge/OpenShell-0.0.13-76b900?logo=nvidia&logoColor=white)](https://github.com/NVIDIA/OpenShell)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04_LTS-E95420?logo=ubuntu&logoColor=white)](https://ubuntu.com)
[![Node.js](https://img.shields.io/badge/Node.js-22.x-339933?logo=nodedotjs&logoColor=white)](https://nodejs.org)
[![License](https://img.shields.io/badge/license-Apache_2.0-blue)](LICENSE)

---

## What This Is

This repo documents the journey of standing up NemoClaw — NVIDIA's security-hardened wrapper around OpenClaw — on a personal GPU cluster. Every script, config, and decision is here so others can follow the same path.

**The core idea:** NemoClaw gives you an autonomous AI agent with kernel-level security enforcement (Landlock + seccomp + network policy). Rather than routing inference to NVIDIA's cloud, we route it to a local DGX Spark — keeping everything on-prem.

## Architecture

```
  MacBook Pro (development)
  └── Claude Code ──────────────────── orchestration & repo
          │
          │ SSH
          ▼
  Mac Mini · Ubuntu 24.04 · 10.10.12.252
  └── Docker
       └── OpenShell gateway
            └── k3s (embedded)
                 └── NemoClaw sandbox pod
                      └── OpenClaw agent + NemoClaw plugin
                               │
                               │ inference (NIM / vLLM)
                               ▼
                      DGX Spark · Ubuntu 24.04 · 10.10.12.251
                      └── NVIDIA GB10 GPU
                           └── Nemotron 3 Super 120B
```

**Security boundary:** NemoClaw's network policy is scoped so it can only reach the DGX Spark for inference. It cannot reach NVIDIA cloud endpoints, the MacBook Pro, or any other AI infrastructure.

## Infrastructure

| Node | OS | Role |
|------|----|------|
| NVIDIA DGX Spark (`10.10.12.251`) | Ubuntu 24.04 | GPU compute — runs Nemotron locally |
| Mac Mini (`10.10.12.252`) | Ubuntu 24.04 | NemoClaw host — sandbox, OpenShell, Docker |
| MacBook Pro | macOS | Development — Claude Code, SSH orchestration |

## Prerequisites

Before running any scripts, ensure:

- SSH access to both nodes (`$USER@10.10.12.251` and `$USER@10.10.12.252`)
- Your user has passwordless sudo on both nodes:
  ```
  $USER ALL=(ALL) NOPASSWD: ALL
  ```
  in `/etc/sudoers.d/$USER` (mode `440`)
- An NVIDIA API key from [build.nvidia.com](https://build.nvidia.com) for initial onboarding

## Setup

### 1. Mac Mini (NemoClaw host)

Installs Docker, fixes cgroup v2 for OpenShell/k3s, installs Node.js 22, OpenShell, and NemoClaw. Idempotent — safe to re-run.

```bash
ssh $USER@10.10.12.252 "bash -s" < scripts/setup-mac-mini.sh
```

### 2. Onboard NemoClaw

Run the interactive wizard on the Mac Mini:

```bash
ssh $USER@10.10.12.252
nemoclaw onboard
```

You will be prompted for your NVIDIA API key and inference preferences.

### 3. Configure Inference for DGX Spark

*(In progress — see [Configuring On-Prem Inference](#configuring-on-prem-inference) below)*

---

## Configuring On-Prem Inference

> **Current status:** NemoClaw is onboarded. This section covers switching inference from NVIDIA cloud to the local DGX Spark.

NemoClaw supports multiple inference backends via profiles in `blueprint.yaml`. The two relevant on-prem options are:

| Profile | Backend | Use case |
|---------|---------|---------|
| `nim-local` | NVIDIA Inference Microservice | Recommended for DGX hardware |
| `vllm` | vLLM | Alternative open-source serving |

*(Configuration steps to follow)*

---

## Why NemoClaw over OpenClaw?

| | OpenClaw | NemoClaw |
|-|----------|----------|
| Security enforcement | Application layer | Kernel level (Landlock + seccomp) |
| Network policy | None | Declarative, per-destination |
| Filesystem access | Unrestricted | Ephemeral `/sandbox` + `/tmp` only |
| Inference backends | Any | Nemotron (scoped by policy) |
| Production-ready | Experimental | Alpha (hardened) |

OpenClaw is designed for experimentation. NemoClaw is designed for situations where you want the power of an autonomous agent but need to control its blast radius.

## Repository Structure

```
captain-nemo/
├── scripts/
│   └── setup-mac-mini.sh   # Full host setup for Ubuntu 24.04
└── README.md
```

## Status & Roadmap

- [x] Mac Mini host provisioned (Docker, OpenShell, Node.js 22, NemoClaw)
- [x] NemoClaw onboarded
- [ ] Configure inference to route to DGX Spark (on-prem, not cloud)
- [ ] Lock network policy to DGX Spark only
- [ ] DGX Spark inference server setup
- [ ] End-to-end validation

---

> Built with [Claude Code](https://claude.ai/code) — Claude helped write every script and configuration in this repo.
