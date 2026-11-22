defmodule Manifests.Items.AgencyRoles do
  @moduledoc """
  **A copy of ragentic's `Ragentic.Teams.Sources.Roles`** (lib/ragentic/teams/sources/roles.ex),
  kept equal to it by the shared fixture `test/fixtures/agency-mini/` (both repos
  assert the same `expected.json`). Change both in the same goal, never one.

  Role files to Agent and Team documents, for a `TeamSource`. Pure: no
  database, no network.

  A role file (the agency-agents format) is YAML frontmatter and a markdown
  body:

      ---
      name: Frontend Developer
      description: Builds accessible, fast interfaces.
      emoji: 🎨
      color: cyan
      vibe: Pixel-perfect and pragmatic.
      ---
      # Frontend Developer
      You are …

  `plan/2` turns the files into documents:

  - the agent's name is the file's slug (`engineering/engineering-frontend-developer.md`
    → `engineering-frontend-developer`), lowercase, at most 63 characters,
    a collision suffixed `-2`, `-3`…;
  - `name`, `description`, `emoji`, `color`, `vibe` go on the Agent's
    `description` and `profile`; every other frontmatter key is ignored and
    reported;
  - the body is the system prompt, after one line naming the team and its lead;
  - one Team per top folder (`teams.byDirectory`, the default) or per
    explicit group (`teams.explicit: {web: ["engineering/*frontend*"]}`), led
    by the role `leads` names or a generated `<team>-lead` coordinator, with
    `disciplines` derived from the slugs (`engineering-frontend-developer` in
    `engineering` → `frontend-developer`).

  Imported text is untrusted: it only ever becomes a prompt, a description
  or a profile. Model, tools, memory and the rest come from the source's
  `defaults` and `overrides` alone.
  """

  @known ~w(name description color emoji vibe)
  # what defaults/overrides may set on an imported agent
  @agent_keys ~w(model fallback tools memory context turnTimeoutMinutes sandbox budget scaling)
  @max_name 63
  @limits %{
    "displayName" => 120,
    "description" => 1000,
    "emoji" => 16,
    "color" => 32,
    "vibe" => 300
  }
  @max_body 64 * 1024
  # frontmatter is untrusted YAML: kept small before it is parsed at all
  @max_frontmatter 16 * 1024

  @doc "The spec keys `defaults` and `overrides` may set."
  def agent_keys, do: @agent_keys

  @type role :: %{
          path: String.t(),
          slug: String.t(),
          dir: String.t(),
          meta: map(),
          body: String.t(),
          ignored: [String.t()]
        }

  # ---------------------------------------------------------------- parsing

  @doc """
  One role file: `{:ok, role}`, or `{:skip, reason}` when it is not a role
  (no frontmatter under `format: agency-agents`, or an empty body).
  """
  @spec parse(String.t(), binary(), String.t()) :: {:ok, role()} | {:skip, String.t()}
  def parse(path, content, format \\ "agency-agents") do
    text =
      content
      |> String.replace_prefix("﻿", "")
      |> String.replace("\r\n", "\n")

    cond do
      not String.valid?(text) ->
        {:skip, "not UTF-8 text"}

      true ->
        case split_frontmatter(text) do
          {:ok, front, _body} when byte_size(front) > @max_frontmatter ->
            {:skip, "frontmatter larger than #{div(@max_frontmatter, 1024)} KB"}

          {:ok, front, body} ->
            role(path, frontmatter(front), body)

          :none when format == "auto" ->
            role(path, {%{}, []}, text)

          :none ->
            {:skip, "no frontmatter"}
        end
    end
  end

  defp role(path, {meta, ignored}, body) do
    body = body |> String.trim() |> truncate(@max_body)

    if body == "" do
      {:skip, "no prompt"}
    else
      meta =
        if meta["name"] in [nil, ""],
          do: put_some(meta, "name", heading(body)),
          else: meta

      {:ok,
       %{
         path: path,
         slug: path |> Path.basename() |> Path.rootname() |> slugify(),
         dir: path |> Path.split() |> hd() |> slugify(),
         meta: meta,
         body: body,
         ignored: ignored
       }}
    end
  end

  defp split_frontmatter("---\n" <> rest) do
    case Regex.run(~r/\A(.*?)^---[ \t]*(?:\n|\z)(.*)\z/ms, rest) do
      [_, front, body] -> {:ok, front, body}
      _ -> :none
    end
  end

  defp split_frontmatter(_), do: :none

  # The five known keys, as trimmed strings; the names of every other key.
  defp frontmatter(front) do
    map =
      case YamlElixir.read_from_string(front) do
        {:ok, %{} = m} -> m
        _ -> loose(front)
      end

    ignored = map |> Map.keys() |> Enum.map(&to_string/1) |> Enum.reject(&(&1 in @known))

    meta =
      for k <- @known, v = scalar(map[k]), v != "", into: %{} do
        {k, truncate(v, @limits[if(k == "name", do: "displayName", else: k)])}
      end

    {meta, Enum.sort(ignored)}
  end

  # `key: value` lines, for frontmatter YAML cannot read (an unquoted `: ` in a value).
  defp loose(front) do
    for line <- String.split(front, "\n"),
        [_, k, v] <- [Regex.run(~r/^([A-Za-z0-9_-]+)\s*:\s*(.*)$/, line)],
        into: %{} do
      {k, v |> String.trim() |> unquote_value()}
    end
  end

  defp unquote_value(<<q, rest::binary>> = v) when q in [?", ?'] do
    if String.ends_with?(rest, <<q>>), do: String.slice(rest, 0..-2//1), else: v
  end

  defp unquote_value(v), do: v

  defp scalar(v) when is_binary(v), do: v |> String.replace(~r/\s+/, " ") |> String.trim()
  defp scalar(v) when is_number(v) or is_boolean(v), do: to_string(v)
  defp scalar(_), do: nil

  defp heading(body) do
    case Regex.run(~r/^#\s+(.+)$/m, body) do
      [_, h] -> h |> String.trim() |> truncate(@limits["displayName"])
      _ -> nil
    end
  end

  defp truncate(s, max) do
    if String.length(s) > max, do: String.slice(s, 0, max), else: s
  end

  @doc "A name as a manifest name: lowercase letters, digits and dashes."
  @spec slugify(String.t()) :: String.t()
  def slugify(s) do
    s
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, @max_name)
    |> String.trim("-")
  end

  # ------------------------------------------------------------------- globs

  @doc """
  Whether a path matches a glob: `*` and `?` within one folder, `**` across
  folders (`**/README.md` matches a README at any depth).
  """
  @spec glob?(String.t(), String.t()) :: boolean()
  def glob?(pattern, path) do
    re =
      pattern
      |> Regex.escape()
      |> String.replace("\\*\\*/", "(?:.*/)?")
      |> String.replace("\\*\\*", ".*")
      |> String.replace("\\*", "[^/]*")
      |> String.replace("\\?", "[^/]")

    Regex.match?(~r/\A#{re}\z/, path)
  end

  @doc "Whether a repository path is a role file the spec takes: a `.md` in a folder."
  @spec wanted?(String.t(), map()) :: boolean()
  def wanted?(path, spec) do
    include = spec["include"] || []
    exclude = spec["exclude"] || ["**/README.md"]

    String.ends_with?(path, ".md") and String.contains?(path, "/") and
      (include == [] or Enum.any?(include, &glob?(&1, path))) and
      not Enum.any?(exclude, &glob?(&1, path))
  end

  # ---------------------------------------------------------------- planning

  @doc """
  The Agent and Team documents for parsed roles.

  Options: `:namespace`, `:source` (the TeamSource's name, for labels),
  `:origin` (what the teams' descriptions cite), `:taken` (`%{"Agent" =>
  MapSet, "Team" => MapSet}` of names held by manifests this source does not
  own — their roles and teams are conflicts, never written).

  Answers `%{agents: [doc], teams: [doc], conflicts: [msg], errors: [msg]}`.
  """
  @spec plan([role()], map(), keyword()) :: map()
  def plan(roles, spec, opts) do
    taken = opts[:taken] || %{}
    taken_agents = Map.get(taken, "Agent", MapSet.new())
    taken_teams = Map.get(taken, "Team", MapSet.new())

    grouped = group(Enum.sort_by(roles, & &1.path), spec)

    {named, used} =
      Enum.map_reduce(grouped, MapSet.new(), fn {team, role}, used ->
        name = unique(role.slug, used)
        {{team, Map.put(role, :name, name)}, MapSet.put(used, name)}
      end)

    {named, agent_conflicts} =
      Enum.split_with(named, fn {_team, r} -> not MapSet.member?(taken_agents, r.name) end)

    teams = named |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
    agent_names = MapSet.new(named, fn {_t, r} -> r.name end)

    {team_plans, {_used, lead_errors}} =
      Enum.map_reduce(teams, {MapSet.union(used, taken_agents), []}, fn team, {used, errs} ->
        members = for {^team, r} <- named, do: r
        wanted = get_in(spec, ["leads", team])

        cond do
          is_binary(wanted) and MapSet.member?(agent_names, wanted) ->
            {%{name: team, lead: wanted, generated: nil, members: members}, {used, errs}}

          true ->
            lead = unique("#{team}-lead", used)

            errs =
              if is_binary(wanted),
                do: ["leads.#{team}: no imported role #{wanted}; #{lead} leads" | errs],
                else: errs

            {%{name: team, lead: lead, generated: lead, members: members},
             {MapSet.put(used, lead), errs}}
        end
      end)

    {team_plans, team_conflicts} =
      Enum.split_with(team_plans, &(not MapSet.member?(taken_teams, &1.name)))

    agents =
      Enum.flat_map(team_plans, fn t ->
        roles = for r <- t.members, do: role_agent(r, t, spec, opts)
        lead = if t.generated, do: [lead_agent(t, spec, opts)], else: []
        lead ++ roles
      end)

    %{
      agents: agents,
      teams: Enum.map(team_plans, &team_doc(&1, opts)),
      conflicts:
        Enum.map(agent_conflicts, fn {_, r} ->
          "Agent #{r.name}: an agent of that name already exists (#{r.path})"
        end) ++
          Enum.map(team_conflicts, &"Team #{&1.name}: a team of that name already exists"),
      errors: Enum.reverse(lead_errors)
    }
  end

  # {team, role}: by top folder, or by the first explicit group (by name) that matches
  defp group(roles, spec) do
    case get_in(spec, ["teams", "explicit"]) do
      %{} = groups when map_size(groups) > 0 ->
        groups = groups |> Enum.map(fn {t, globs} -> {slugify(t), globs} end) |> Enum.sort()

        for r <- roles,
            team = Enum.find_value(groups, fn {t, globs} -> if hit?(globs, r.path), do: t end),
            team not in [nil, ""],
            do: {team, r}

      _ ->
        for r <- roles, r.dir != "", do: {r.dir, r}
    end
  end

  defp hit?(globs, path) when is_list(globs), do: Enum.any?(globs, &glob?(&1, path))
  defp hit?(glob, path) when is_binary(glob), do: glob?(glob, path)
  defp hit?(_, _), do: false

  defp unique(base, used) do
    base = if base == "", do: "role", else: base

    if MapSet.member?(used, base) do
      Enum.find_value(2..10_000, fn i ->
        suffix = "-#{i}"
        n = String.slice(base, 0, @max_name - byte_size(suffix)) |> String.trim("-")
        name = n <> suffix
        if not MapSet.member?(used, name), do: name
      end)
    else
      base
    end
  end

  @doc "The discipline a role covers in its team: its slug without the team's or folder's prefix."
  @spec discipline(String.t(), String.t(), String.t()) :: String.t()
  def discipline(name, team, dir) do
    Enum.find_value([team, dir], name, fn prefix ->
      case String.split(name, prefix <> "-", parts: 2) do
        ["", rest] when rest != "" -> rest
        _ -> nil
      end
    end)
  end

  defp disciplines(t) do
    t.members
    |> Enum.reduce(%{}, fn r, acc ->
      d = discipline(r.name, t.name, r.dir)
      if Map.has_key?(acc, d), do: Map.put_new(acc, r.name, r.name), else: Map.put(acc, d, r.name)
    end)
  end

  defp agent_spec(name, spec) do
    defaults = Map.take(spec["defaults"] || %{}, @agent_keys)
    over = Map.take(get_in(spec, ["overrides", name]) || %{}, @agent_keys)
    Map.merge(defaults, over)
  end

  defp role_agent(r, t, spec, opts) do
    display = r.meta["name"] || r.name

    profile =
      %{}
      |> put_some("displayName", r.meta["name"])
      |> put_some("emoji", r.meta["emoji"])
      |> put_some("color", r.meta["color"])
      |> put_some("vibe", r.meta["vibe"])

    system =
      "You are #{display} (#{r.name}) on team #{t.name}; its lead is #{t.lead}.\n\n" <> r.body

    agent_spec(r.name, spec)
    |> Map.put("system", system)
    |> put_some("description", r.meta["description"])
    |> then(&if profile == %{}, do: &1, else: Map.put(&1, "profile", profile))
    |> doc("Agent", r.name, opts, %{"ragentic.io/source-path" => r.path})
  end

  defp lead_agent(t, spec, opts) do
    roster =
      t
      |> disciplines()
      |> Enum.sort()
      |> Enum.map_join("\n", fn {d, a} -> "- #{d}: #{a}" end)

    system = """
    You are #{t.lead}, the lead of team #{t.name}. You coordinate: you plan the work, \
    hand each task to the member whose discipline it is, judge their results against \
    the criteria and re-plan. You do not do the members' work yourself.

    Your team, by discipline:
    #{roster}
    """

    agent_spec(t.lead, spec)
    |> Map.put("system", String.trim(system))
    |> Map.put("description", "Coordinates team #{t.name}: plans and delegates")
    |> Map.put("profile", %{"displayName" => "#{t.name} lead"})
    |> doc("Agent", t.lead, opts, %{})
  end

  defp team_doc(t, opts) do
    members = t.members |> Enum.map(& &1.name) |> Enum.reject(&(&1 == t.lead)) |> Enum.sort()

    %{
      "lead" => t.lead,
      "members" => members,
      "disciplines" => disciplines(t),
      "description" =>
        "Imported from #{opts[:origin] || "a TeamSource"}: #{length(t.members)} roles"
    }
    |> doc("Team", t.name, opts, %{})
  end

  defp doc(spec, kind, name, opts, annotations) do
    # the source's id too: only what this very source applied is ever adopted as its own
    annotations = put_some(annotations, "ragentic.io/source-id", opts[:source_id])

    meta =
      %{"name" => name, "labels" => %{"ragentic.io/source" => opts[:source]}}
      |> put_some("namespace", opts[:namespace])
      |> then(&if annotations == %{}, do: &1, else: Map.put(&1, "annotations", annotations))

    %{"apiVersion" => "ragentic.io/v1", "kind" => kind, "metadata" => meta, "spec" => spec}
  end

  defp put_some(map, _k, nil), do: map
  defp put_some(map, k, v), do: Map.put(map, k, v)
end
