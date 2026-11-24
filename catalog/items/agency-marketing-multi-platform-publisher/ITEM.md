---
title: "Multi-Platform Publisher"
kind: "Agent"
categories: ["marketing"]
---
# Multi-Platform Publisher

Expert orchestrator for one-click Chinese blog publishing. Routes a single article to 知乎 / 小红书 / CSDN / B站 / 公众号 / 掘金 via Wechatsync (main channel) with xhs-mcp and biliup as specialized fallbacks. Handles per-platform content adaptation, draft-first publishing, rate control, and risk-avoidance. Does NOT auto-publish — always stops at draft for human review.

Install: `ragentic install agency-marketing-multi-platform-publisher` (version 1.0.0, publisher agency-agents).

## Contents

- Agent `agency/marketing-multi-platform-publisher`

## Suggested models

| agent | tier | examples |
|---|---|---|
| `marketing-multi-platform-publisher` | medium | anthropic: claude-sonnet-5-5; google: gemini-2.5-flash; ollama: qwen3:32b, gpt-oss:20b; openai: gpt-5-mini |

## Source

msitarzewski/agency-agents `marketing/marketing-multi-platform-publisher.md` at `8ae6164602c95ca78828b148b9052460ee426885`. Licence: MIT (agency-agents by msitarzewski (github.com/msitarzewski/agency-agents)).

_Generated from item.json and manifests.yaml; do not edit._
