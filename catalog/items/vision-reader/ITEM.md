---
title: "Vision reader"
kind: "Agent"
categories: ["ai","examples"]
---
# Vision reader

Reads pictures (labels, gauges, documents) with a vision model, from a workflow and a page to upload to.

Install: `ragentic install vision-reader` (version 1.0.0, publisher ragentic).

## Contents

- Workspace `vision`
- Agent `vision/reader`
- Workflow `vision/read-image`
- Site `vision/lab`
- Page `vision/read`

## Suggested models

| agent | tier | examples |
|---|---|---|
| `reader` | medium+vision+tools | anthropic: claude-sonnet-5-5; google: gemini-2.5-flash; ollama: qwen2.5vl:7b, llava; openai: gpt-5-mini |

## Source

ragentic-io/ragentic `examples/vision-reader.yaml` at `0bdc0bc57cfb2dddad758ad8ccad654032e93564`. Licence: PolyForm-Noncommercial-1.0.0 (ragentic).

_Generated from item.json and manifests.yaml; do not edit._
