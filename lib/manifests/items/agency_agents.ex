defmodule Manifests.Items.AgencyAgents do
  @moduledoc """
  agency-agents (https://github.com/msitarzewski/agency-agents) as items:
  one Agent item per role (`agency-<slug>`) and one Team item per division
  (`agency-team-<division>`: the Team, its lead and its role Agents).

  The conversion is TeamSource's (`Manifests.Items.AgencyRoles`, a copy of
  ragentic's `Ragentic.Teams.Sources.Roles`). Upstream text only ever becomes
  a prompt, a description or a profile: tiers, tools, leads and categories come
  from the reviewed `catalog/sources/agency-agents/tiers.json`, never from
  upstream.
  """

  alias Manifests.CatalogTools.Catalog
  alias Manifests.Items.{AgencyRoles, Importer}

  @max_archive 64 * 1024 * 1024
  @max_file 512 * 1024
  @max_roles 500
  @prefix "agency-"

  def config_path(c), do: Catalog.path(c, "sources/agency-agents/tiers.json")
  def config(c), do: Importer.read_json!(config_path(c))

  @doc """
  Import from a checkout (`:from`) or the pinned commit's archive. Options:
  `:from`, `:commit`. Answers `Importer.write_all/3`'s counts plus `:commit`.
  """
  def run(c, opts \\ []) do
    cfg = config(c)
    {files, commit} = files(cfg, opts)
    payloads = payloads(files, cfg, Importer.model_examples(c), commit)

    c
    |> Importer.write_all(payloads, &String.starts_with?(&1, @prefix))
    |> Map.put(:commit, commit)
  end

  @doc """
  Items from role files (`[{path, bytes}]`), without versions. Pure; the
  importer test runs it on the shared fixture.
  """
  def payloads(files, cfg, examples, commit) do
    roles = roles(files, cfg)
    sha = Map.new(files, fn {path, bytes} -> {path, Importer.sha256(bytes)} end)
    ws = get_in(cfg, ["params", "workspace", "default"]) || "agency"
    plan = plan(roles, cfg, ws)
    agents = Map.new(plan.agents, &{&1["metadata"]["name"], &1})

    models =
      Map.new(plan.agents, fn a ->
        name = a["metadata"]["name"]
        {name, Importer.model(tier_for(name, plan, cfg), examples)}
      end)

    agents = Map.new(agents, fn {name, a} -> {name, with_tools(a, models[name], cfg)} end)

    role_by_name =
      Map.new(
        plan.agents,
        &{&1["metadata"]["name"],
         get_in(&1, ["metadata", "annotations", "ragentic.io/source-path"])}
      )

    role_items =
      for {name, path} <- role_by_name, path != nil do
        agent = agents[name]
        division = path |> Path.split() |> hd()

        base(cfg)
        |> Map.merge(%{
          "id" => @prefix <> name,
          "item" =>
            item(cfg, "Agent", display(agent), description(agent), division, ws)
            |> Map.put("keywords", keywords(agent, division)),
          "manifests" => [agent],
          "models" => %{name => models[name]},
          "provenance" => provenance(cfg, commit, path, sha[path])
        })
      end

    team_items =
      for team <- plan.teams do
        division = team["metadata"]["name"]
        lead = team["spec"]["lead"]
        members = [lead | team["spec"]["members"]] |> Enum.uniq()
        label = get_in(cfg, ["divisions", division, "label"]) || division
        paths = for m <- members, p = role_by_name[m], p != nil, do: p

        base(cfg)
        |> Map.merge(%{
          "id" => @prefix <> "team-" <> division,
          "item" =>
            item(
              cfg,
              "Team",
              "#{label} team",
              "The #{label} division of agency-agents as a ragentic Team: #{length(paths)} roles, led by #{lead}.",
              division,
              ws
            )
            |> Map.put("keywords", Enum.uniq([division, "team", "agency-agents"])),
          "manifests" => Enum.map(members, &agents[&1]) ++ [team],
          "models" => Map.new(members, &{&1, models[&1]}),
          "provenance" =>
            provenance(
              cfg,
              commit,
              division,
              paths
              |> Enum.sort()
              |> Enum.map_join("\n", &"#{sha[&1]}  #{&1}")
              |> Importer.sha256()
            )
        })
      end

    Enum.sort_by(role_items ++ team_items, & &1["id"])
  end

  @doc "The Agent and Team documents of TeamSource's mapping (what the shared fixture pins)."
  def plan(roles, cfg, ws) do
    AgencyRoles.plan(roles, %{"leads" => cfg["leads"] || %{}},
      namespace: ws,
      source: "agency-agents",
      origin: "agency-agents"
    )
  end

  @doc "Parsed roles of the configured divisions, within the bounds."
  def roles(files, cfg) do
    divisions = Map.keys(cfg["divisions"] || %{})

    spec = %{
      "include" => Enum.map(divisions, &"#{&1}/**/*.md"),
      "exclude" => cfg["exclude"] || ["**/README.md"]
    }

    roles =
      for {path, bytes} <- Enum.sort(files),
          AgencyRoles.wanted?(path, spec),
          byte_size(bytes) <= @max_file,
          {:ok, role} <- [AgencyRoles.parse(path, bytes)],
          do: role

    if length(roles) > @max_roles, do: raise("agency-agents: more than #{@max_roles} roles")
    roles
  end

  defp base(cfg) do
    %{
      "kind" => "item",
      "rights" => %{
        "license" => "MIT",
        "attribution" =>
          "agency-agents by msitarzewski (github.com/#{cfg["upstream"]["repository"]})"
      }
    }
  end

  defp item(cfg, kind, title, description, division, ws) do
    %{
      "kind" => kind,
      "title" => String.slice(title, 0, 256),
      "description" => String.slice(description, 0, 2000),
      "categories" => get_in(cfg, ["divisions", division, "categories"]) || ["ai"],
      "publisher" => "agency-agents",
      "requires" => %{
        "ragentic" => cfg["requires"] || ">= 2026.11.0",
        "items" => [],
        "connectors" => []
      },
      "params" => %{
        "workspace" => %{"default" => ws, "description" => "the workspace the agents live in"}
      }
    }
  end

  defp display(agent),
    do: get_in(agent, ["spec", "profile", "displayName"]) || agent["metadata"]["name"]

  defp description(agent) do
    case get_in(agent, ["spec", "description"]) do
      d when is_binary(d) and d != "" -> d
      _ -> "#{display(agent)}, a role from agency-agents."
    end
  end

  defp keywords(agent, division) do
    words =
      agent
      |> display()
      |> String.downcase()
      |> String.split(~r/[^a-z0-9]+/, trim: true)
      |> Enum.filter(&(byte_size(&1) in 3..64))

    Enum.take(Enum.uniq([division | words] ++ ["agency-agents"]), 12)
  end

  defp provenance(cfg, commit, path, sha) do
    %{
      "repository" => cfg["upstream"]["repository"],
      "path" => path,
      "commit" => commit,
      "sha256" => sha
    }
  end

  # tiers.json: default < division < rules (in order, by slug glob) < overrides; leads get `lead`
  defp tier_for(name, plan, cfg) do
    lead? = Enum.any?(plan.teams, &(&1["spec"]["lead"] == name))

    division =
      Enum.find_value(plan.teams, fn t ->
        if name == t["spec"]["lead"] or name in t["spec"]["members"], do: t["metadata"]["name"]
      end)

    rules =
      for r <- cfg["rules"] || [], AgencyRoles.glob?(r["match"], name), do: Map.drop(r, ["match"])

    [cfg["default"], get_in(cfg, ["divisions", division, "tier"])]
    |> Kernel.++(rules)
    |> Kernel.++([if(lead?, do: cfg["lead"]), get_in(cfg, ["overrides", name])])
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(%{}, &Map.merge(&2, &1))
  end

  defp with_tools(agent, model, cfg) do
    if model["tools"],
      do: put_in(agent, ["spec", "tools"], cfg["tools"] || ["graph", "context"]),
      else: update_in(agent, ["spec"], &Map.delete(&1, "tools"))
  end

  ## Upstream files

  defp files(cfg, opts) do
    case opts[:from] do
      dir when is_binary(dir) ->
        commit = opts[:commit] || Importer.git_commit(dir) || cfg["upstream"]["commit"]
        {read_dir(dir), commit}

      nil ->
        commit = opts[:commit] || cfg["upstream"]["commit"] || resolve(cfg)
        {download(cfg["upstream"]["repository"], commit), commit}
    end
  end

  defp read_dir(dir) do
    dir
    |> Path.join("**/*.md")
    |> Path.wildcard()
    |> Enum.map(&{Path.relative_to(&1, dir), &1})
    |> Enum.reject(fn {rel, _} -> String.starts_with?(rel, ".") end)
    |> Enum.filter(fn {_, abs} -> File.regular?(abs) and File.stat!(abs).size <= @max_file end)
    |> Enum.map(fn {rel, abs} -> {rel, File.read!(abs)} end)
  end

  defp resolve(cfg) do
    repo = cfg["upstream"]["repository"]
    ref = cfg["upstream"]["ref"] || "main"

    Req.get!("https://api.github.com/repos/#{repo}/commits/#{ref}",
      headers: [accept: "application/vnd.github.sha"],
      decode_body: false
    ).body
    |> String.trim()
  end

  @doc false
  def download(repo, commit) do
    true = Regex.match?(~r/\A[0-9a-f]{40}\z/, commit)

    %{status: 200, body: body} =
      Req.get!("https://codeload.github.com/#{repo}/tar.gz/#{commit}",
        decode_body: false,
        max_redirects: 2
      )

    if byte_size(body) > @max_archive, do: raise("agency-agents: archive larger than 64 MB")
    {:ok, entries} = :erl_tar.extract({:binary, body}, [:compressed, :memory])

    for {name, bytes} <- entries,
        name = to_string(name),
        [_top | rest] = Path.split(name),
        rest != [],
        rel = Path.join(rest),
        not String.contains?(rel, ".."),
        String.ends_with?(rel, ".md"),
        byte_size(bytes) <= @max_file,
        do: {rel, bytes}
  end
end
