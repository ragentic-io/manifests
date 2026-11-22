---
title: "Orchestrator and builder"
kind: "Agent"
categories: ["ai","operations"]
---
# Orchestrator and builder

An orchestrator that creates and changes anything in the organization with apply_manifest and asks other agents, and a builder that develops ragentic in a git worktree.

Install: `ragentic install orchestrator` (version 1.0.0, publisher ragentic).

## Contents

- Agent `community/orchestrator`
- Agent `community/builder`

## Suggested models

| agent | tier | examples |
|---|---|---|
| `builder` | large+tools | anthropic: claude-opus-5-5; google: gemini-2.5-pro; ollama: qwen3:235b, deepseek-v3; openai: gpt-5 |
| `orchestrator` | large+tools | anthropic: claude-opus-5-5; google: gemini-2.5-pro; ollama: qwen3:235b, deepseek-v3; openai: gpt-5 |

## Source

ragentic-io/ragentic `examples/orchestrator.yaml` at `0bdc0bc57cfb2dddad758ad8ccad654032e93564`. Licence: PolyForm-Noncommercial-1.0.0 (ragentic).

_Generated from item.json and manifests.yaml; do not edit._
