---
title: "Mock PLC tank"
kind: "PlcSimulator"
categories: ["industrial","iot"]
---
# Mock PLC tank

A simulated PLC driving a tank, with its connectors, tag streams, workflows and pages: a PLC to try ragentic's industrial tools on without hardware.

Install: `ragentic install mock-plc` (version 1.0.0, publisher ragentic).

## Contents

- Workspace `demo`
- PlcSimulator `demo/tank-sim`
- Connector `demo/tank-plc`
- DataConnector `plc-bus`
- Stream `demo/tank-tags`
- Stream `demo/tank-graph`
- Workflow `demo/tank-start`
- Workflow `demo/tank-stop`
- Workflow `demo/tank-reset`
- Workflow `demo/tank-status`
- Site `demo/tank-hmi`
- Page `demo/tank`
- Workspace `models`
- Connector `models/assets`
- Model `demo/tank`
- Model `demo/tank-pump`
- Model `demo/tank-valve`
- Model `demo/tank-pipes`
- Model `demo/tank-lamp`
- Page `demo/tank-3d`

## Source

ragentic-io/ragentic `examples/mock-plc.yaml` at `0bdc0bc57cfb2dddad758ad8ccad654032e93564`. Licence: PolyForm-Noncommercial-1.0.0 (ragentic).

_Generated from item.json and manifests.yaml; do not edit._
