# agency-mini: the shared agency-agents fixture

Three role files in two divisions, in the agency-agents format
(https://github.com/msitarzewski/agency-agents), and `expected.json`: the
Agent and Team documents they become under TeamSource's mapping
(`Ragentic.Teams.Sources.Roles.plan/3`, docs/goals.md) with

    spec:  {leads: {engineering: engineering-software-architect}}
    opts:  namespace: agency, source: agency-agents, origin: agency-agents

The same directory lives in ragentic-io/manifests (`test/fixtures/agency-mini/`),
whose importer (`mix catalog.import agency-agents`) must produce the same
documents. Changing the mapping means changing both copies in the same goal
(docs/registry.md, section 3.1).
