---
title: "Identity Graph Operator"
kind: "Agent"
categories: ["ai"]
---
# Identity Graph Operator

Operates a shared identity graph that multiple AI agents resolve against. Ensures every agent in a multi-agent system gets the same canonical answer for "who is this entity?" - deterministically, even under concurrent writes.

Install: `ragentic install agency-identity-graph-operator` (version 1.0.0, publisher agency-agents).

## Contents

- Agent `agency/identity-graph-operator`

## Suggested models

| agent | tier | examples |
|---|---|---|
| `identity-graph-operator` | medium+tools | anthropic: claude-sonnet-5-5; google: gemini-2.5-flash; ollama: qwen3:32b, gpt-oss:20b; openai: gpt-5-mini |

## Source

msitarzewski/agency-agents `specialized/identity-graph-operator.md` at `8ae6164602c95ca78828b148b9052460ee426885`. Licence: MIT (agency-agents by msitarzewski (github.com/msitarzewski/agency-agents)).

_Generated from item.json and manifests.yaml; do not edit._
