defmodule ManifestsWeb.ManifestLive do
  @moduledoc """
  One application at one version. The URL always names the version
  (`?version=latest`, `?version=<version>` or `?version=sha256:<digest>`); a link
  without one is rewritten to `latest`. `tab`, `op` and `ops` (operation filter)
  are in the URL too, so any view of any version can be deep-linked.

  Download counts on the overview are live: every bundle served for this
  application is broadcast (`Manifests.Analytics.topic/1`) and folded in here.
  """
  use ManifestsWeb, :live_view
  alias Manifests.Analytics
  alias Manifests.Registry.Lookup
  import ManifestsWeb.CatalogComponents

  @tabs [
    {"overview", "Overview"},
    {"operations", "Operations"},
    {"versions", "Versions"},
    {"manifest", "Manifest"}
  ]

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, digest: nil, downloads_for: nil)}

  @impl true
  def handle_params(%{"id" => id} = params, _uri, socket) do
    case Lookup.resolve(id, params["version"]) do
      {:ok, manifest, version} ->
        {:noreply,
         socket |> load(manifest, version) |> track_downloads(manifest.id) |> assign_view(params)}

      {:error, :version_required} ->
        {:noreply,
         push_patch(socket, to: link_to(id, Map.put(params, "version", "latest")), replace: true)}

      {:error, :version_not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "#{id} has no version “#{params["version"]}”. Showing the latest.")
         |> push_patch(
           to: link_to(id, Map.merge(params, %{"version" => "latest", "tab" => "versions"})),
           replace: true
         )}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "No application called “#{id}”.")
         |> push_navigate(to: ~p"/?#{[q: id]}")}
    end
  end

  # The bundle is decoded once per version, not per tab or filter change.
  defp load(socket, manifest, version) do
    if socket.assigns.digest == version.digest do
      assign(socket, manifest: manifest)
    else
      payload = Lookup.payload(version)
      nodes = get_in(payload, ["graph", "nodes"]) || []

      assign(socket,
        digest: version.digest,
        manifest: manifest,
        version: version,
        versions: Lookup.versions(manifest.id),
        operations: Enum.filter(nodes, &(&1["kind"] == "operation")),
        schemas: Enum.count(nodes, &(&1["kind"] == "schema")),
        setup: payload["setup"] || %{},
        provenance: payload["provenance"] || %{},
        rights: payload["rights"] || %{},
        review: payload["review_required"] || %{},
        manifest_json: manifest_json(payload["manifest"]),
        page_title: "#{manifest.title} #{version.version}"
      )
    end
  end

  defp track_downloads(%{assigns: %{downloads_for: id}} = socket, id), do: socket

  defp track_downloads(socket, id) do
    if connected?(socket) do
      if old = socket.assigns.downloads_for,
        do: Phoenix.PubSub.unsubscribe(Manifests.PubSub, Analytics.topic(old))

      Phoenix.PubSub.subscribe(Manifests.PubSub, Analytics.topic(id))
    end

    assign(socket, downloads_for: id, downloads: Analytics.summary(id))
  end

  @impl true
  def handle_info({:download, digest, day}, socket) do
    downloads =
      if day == socket.assigns.downloads.today,
        do: Analytics.bump(socket.assigns.downloads, digest, day),
        else: Analytics.summary(socket.assigns.downloads_for)

    {:noreply, assign(socket, downloads: downloads)}
  end

  defp assign_view(socket, params) do
    tab = if params["tab"] in Enum.map(@tabs, &elem(&1, 0)), do: params["tab"], else: "overview"
    ops_q = params["ops"] |> to_string() |> String.trim()
    op = params["op"] && Enum.find(socket.assigns.operations, &(&1["id"] == params["op"]))
    tab = if op, do: "operations", else: tab

    assign(socket,
      params: Map.take(params, ~w(version tab op ops)),
      tab: tab,
      ops_q: ops_q,
      op: op,
      shown_ops: filter_ops(socket.assigns.operations, ops_q),
      requested: params["version"]
    )
  end

  defp filter_ops(ops, ""), do: ops

  defp filter_ops(ops, q) do
    terms = q |> String.downcase() |> String.split()

    Enum.filter(ops, fn op ->
      hay =
        String.downcase(
          "#{op["method"]} #{op["path"]} #{op["name"]} #{op["summary"]} #{Enum.join(op["tags"] || [], " ")}"
        )

      Enum.all?(terms, &String.contains?(hay, &1))
    end)
  end

  # The embedded API definition can run to megabytes; it's in the bundle download.
  defp manifest_json(nil), do: "{}"

  defp manifest_json(manifest) do
    manifest
    |> update_in(["spec", Access.key("base", %{}), Access.key("specification", %{})], fn
      %{"document" => _} = spec ->
        Map.put(spec, "document", "… embedded definition, see the signed bundle …")

      other ->
        other
    end)
    |> Jason.encode!(pretty: true)
  end

  @impl true
  def handle_event("version", %{"version" => v}, socket),
    do: {:noreply, push_patch(socket, to: here(socket, %{"version" => v, "op" => nil}))}

  def handle_event("filter_ops", %{"ops" => q}, socket),
    do:
      {:noreply,
       push_patch(socket, to: here(socket, %{"ops" => q, "tab" => "operations"}), replace: true)}

  defp here(%Phoenix.LiveView.Socket{assigns: assigns}, changes), do: here(assigns, changes)

  defp here(assigns, changes),
    do: link_to(assigns.manifest.id, Map.merge(assigns.params, changes))

  @doc "A manifest page URL; `version` first, empty params dropped."
  def link_to(id, params) do
    query =
      for k <- ~w(version tab op ops),
          v = params[k],
          v not in [nil, ""],
          not (k == "tab" and v == "overview"),
          do: {k, v}

    ~p"/apps/#{id}?#{query}"
  end

  defp permalink(assigns),
    do:
      link_to(assigns.manifest.id, %{
        assigns.params
        | "version" => "sha256:" <> assigns.version.digest
      })

  defp absolute(path), do: ManifestsWeb.Endpoint.url() <> path

  defp latest?(assigns), do: assigns.version.digest == assigns.manifest.latest_digest

  defp current_root?(version), do: version.signed_by == Manifests.Catalog.root_key_id()

  defp expired?(version), do: DateTime.compare(version.expires, DateTime.utc_now()) == :lt

  defp date(dt), do: Calendar.strftime(dt, "%Y-%m-%d")

  # When the latest version string was first signed; re-signings keep the date.
  defp latest_release(assigns) do
    assigns.versions
    |> Enum.filter(&(&1.version == assigns.manifest.latest_version))
    |> Enum.min_by(& &1.not_before, DateTime, fn -> nil end)
  end

  defp ago(dt) do
    case Date.diff(Date.utc_today(), DateTime.to_date(dt)) do
      0 -> "today"
      1 -> "yesterday"
      n -> "#{number(n)} days ago"
    end
  end

  defp day_label(d), do: Calendar.strftime(d, "%b %-d")
  defp week_label(d), do: "Week of " <> Calendar.strftime(d, "%b %-d, %Y")
  defp year_label(d), do: Integer.to_string(d.year)

  @impl true
  def render(assigns) do
    assigns = assign(assigns, tabs: @tabs)

    ~H"""
    <Layouts.app flash={@flash}>
      <:search>
        <form action={~p"/"} method="get" role="search" class="w-full">
          <label class="input input-sm w-full bg-base-100">
            <.icon name="hero-magnifying-glass" class="size-4 opacity-60" />
            <input
              type="search"
              name="q"
              placeholder="Search the catalog…"
              aria-label="Search the catalog"
            />
          </label>
        </form>
      </:search>
      <nav class="mb-4 text-sm" aria-label="Breadcrumb">
        <.link navigate={~p"/"} class="link link-hover text-base-content/60">Catalog</.link>
        <span class="text-base-content/40">/</span>
        <span class="font-mono">{@manifest.id}</span>
      </nav>

      <header class="flex flex-col gap-5 border-b border-base-300 pb-6 md:flex-row md:items-start md:justify-between">
        <div class="flex min-w-0 items-start gap-4">
          <.app_logo manifest={@manifest} class="size-14" />
          <div class="min-w-0 space-y-2">
            <h1 class="text-2xl font-semibold leading-tight">{@manifest.title}</h1>
            <p class="font-mono text-sm text-base-content/60">{@manifest.id}</p>
            <ul class="flex flex-wrap gap-1.5" aria-label="Labels">
              <li :for={label <- @manifest.labels}>
                <.link
                  navigate={~p"/?#{[labels: label]}"}
                  class="badge badge-sm badge-outline font-mono hover:badge-primary"
                  title={"Every application labelled #{label}"}
                >
                  {label}
                </.link>
              </li>
            </ul>
          </div>
        </div>

        <div class="w-full shrink-0 space-y-2 md:w-80">
          <form id="version-picker" phx-change="version">
            <label
              for="version"
              class="text-xs font-semibold tracking-wide text-base-content/60 uppercase"
            >Version</label>
            <select id="version" name="version" class="select select-sm mt-1 w-full font-mono">
              <option value="latest" selected={@requested == "latest"}>
                latest ({@manifest.latest_version})
              </option>
              <option
                :for={v <- @versions}
                value={"sha256:" <> v.digest}
                selected={@requested != "latest" and v.digest == @version.digest}
              >
                {v.version} · {date(v.not_before)} · {String.slice(v.digest, 0, 8)}
              </option>
            </select>
          </form>
          <div class="flex items-center gap-1 rounded-field bg-base-200 px-2 py-1">
            <span
              class="min-w-0 flex-1 truncate font-mono text-xs"
              title="Permalink to exactly this signed bundle"
            >
              {URI.decode(permalink(assigns))}
            </span>
            <.copy_button
              id="copy-permalink"
              value={absolute(permalink(assigns))}
              label="Copy permalink"
            />
          </div>
        </div>
      </header>

      <div :if={not latest?(assigns)} role="status" class="alert alert-warning alert-soft mt-4">
        <.icon name="hero-clock" class="size-5" />
        <span>
          You're viewing <span class="font-mono">{@version.version}</span>, signed {date(
            @version.not_before
          )}.
          The latest is <span class="font-mono">{@manifest.latest_version}</span>.
        </span>
        <.link patch={here(assigns, %{"version" => "latest"})} class="btn btn-sm">View latest</.link>
      </div>

      <div role="tablist" class="tabs tabs-border mt-4">
        <.link
          :for={{key, name} <- @tabs}
          patch={here(assigns, %{"tab" => key, "op" => nil})}
          role="tab"
          class={["tab", @tab == key && "tab-active"]}
          aria-selected={to_string(@tab == key)}
        >
          {name}
          <span :if={key == "operations"} class="ml-1.5 text-xs tabular-nums opacity-60">{length(
            @operations
          )}</span>
          <span :if={key == "versions"} class="ml-1.5 text-xs tabular-nums opacity-60">{length(
            @versions
          )}</span>
        </.link>
      </div>

      <section class="pt-6">
        <.overview :if={@tab == "overview"} {assigns} />
        <.operations :if={@tab == "operations"} {assigns} />
        <.versions :if={@tab == "versions"} {assigns} />
        <div :if={@tab == "manifest"} class="space-y-3">
          <div class="flex flex-wrap items-center gap-2 text-sm">
            <a
              href={
                ~p"/api/v1/manifests/#{@manifest.id}/bundle?#{[version: "sha256:" <> @version.digest]}"
              }
              class="btn btn-sm"
            >
              <.icon name="hero-arrow-down-tray" class="size-4" /> Signed bundle
            </a>
            <a
              href={~p"/api/v1/manifests/#{@manifest.id}?#{[version: "sha256:" <> @version.digest]}"}
              class="btn btn-sm btn-ghost"
            >
              <.icon name="hero-code-bracket" class="size-4" /> API
            </a>
          </div>
          <pre class="max-h-[70vh] overflow-auto rounded-box bg-base-200 p-4 font-mono text-xs leading-relaxed"><code>{@manifest_json}</code></pre>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp overview(assigns) do
    assigns = assign(assigns, release: latest_release(assigns))

    ~H"""
    <section id="downloads" aria-labelledby="downloads-heading" class="mb-8 space-y-4">
      <h2 id="downloads-heading" class="sr-only">Downloads</h2>
      <div class="stats stats-vertical w-full border border-base-300 bg-base-100 sm:stats-horizontal">
        <div class="stat">
          <div class="stat-title flex items-center gap-2">
            Downloads
            <span class="relative flex size-2" title="Updates live">
              <span class="absolute inline-flex size-full animate-ping rounded-full bg-success opacity-60"></span>
              <span class="relative inline-flex size-2 rounded-full bg-success"></span>
            </span>
          </div>
          <div id="downloads-total" class="stat-value tabular-nums" aria-live="polite">
            {number(@downloads.total)}
          </div>
          <div class="stat-desc">{number(@downloads.on_day)} today (UTC)</div>
        </div>
        <div class="stat">
          <div class="stat-title">This version</div>
          <div id="downloads-version" class="stat-value tabular-nums">
            {number(Map.get(@downloads.by_digest, @version.digest, 0))}
          </div>
          <div class="stat-desc font-mono">
            {@version.version} · {String.slice(@version.digest, 0, 8)}
          </div>
        </div>
        <div class="stat">
          <div class="stat-title">Latest release</div>
          <div id="latest-release" class="stat-value text-2xl">
            {if @release, do: date(@release.not_before), else: "—"}
          </div>
          <div :if={@release} class="stat-desc">
            <.link
              patch={link_to(@manifest.id, %{"version" => "latest"})}
              class="link link-hover font-mono"
            >{@manifest.latest_version}</.link>
            · {ago(@release.not_before)}
          </div>
        </div>
      </div>
      <div class="grid gap-4 md:grid-cols-3">
        <.bar_chart
          id="downloads-daily"
          title="Daily · last 30 days"
          series={@downloads.days}
          label={&day_label/1}
          slots={30}
        />
        <.bar_chart
          id="downloads-weekly"
          title="Weekly · last 26 weeks"
          series={@downloads.weeks}
          label={&week_label/1}
          slots={26}
        />
        <.bar_chart
          id="downloads-yearly"
          title="Yearly"
          series={@downloads.years}
          label={&year_label/1}
          slots={6}
        />
      </div>
    </section>

    <div class="grid gap-6 lg:grid-cols-3">
      <dl class="grid grid-cols-[8rem_1fr] gap-x-4 gap-y-3 text-sm lg:col-span-2">
        <dt class="text-base-content/60">Endpoint</dt>
        <dd class="break-all font-mono">{@version.endpoint || "—"}</dd>
        <dt class="text-base-content/60">Protocol</dt>
        <dd><.protocol_badge protocol={@version.protocol} /></dd>
        <dt class="text-base-content/60">Credential</dt>
        <dd class="font-mono">{@version.credential || "none"}</dd>
        <dt :if={@setup["probe"]} class="text-base-content/60">Connection test</dt>
        <dd :if={@setup["probe"]} class="break-all font-mono">
          {@setup["probe"]["method"]} {@setup["probe"]["endpoint"]}
        </dd>
        <dt class="text-base-content/60">Status</dt>
        <dd>
          <span class={[
            "badge badge-sm",
            @version.catalog == "published" && "badge-success badge-soft",
            @version.catalog == "draft" && "badge-warning badge-soft"
          ]}>
            {@version.catalog}
          </span>
          <span class="ml-2 font-mono text-xs text-base-content/60">{@version.readiness}</span>
        </dd>
        <dt class="text-base-content/60">Graph</dt>
        <dd>{length(@operations)} operations · {@schemas} schemas</dd>
        <dt :if={@provenance["url"]} class="text-base-content/60">Source</dt>
        <dd :if={@provenance["url"]} class="break-all">
          <a
            href={@provenance["url"]}
            class="link font-mono text-xs"
            rel="noopener noreferrer"
            target="_blank"
          >{@provenance["url"]}</a>
        </dd>
        <dt :if={@provenance["license"]} class="text-base-content/60">License</dt>
        <dd :if={@provenance["license"]}>{license(@provenance["license"])}</dd>
        <dt :if={@rights["brand"]["attribution"]} class="text-base-content/60">Brand</dt>
        <dd :if={@rights["brand"]["attribution"]} class="text-base-content/80">
          {@rights["brand"]["attribution"]}
        </dd>
      </dl>

      <aside class="space-y-4">
        <div class="card card-border bg-base-100">
          <div class="card-body gap-2 p-4 text-sm">
            <h2 class="font-semibold">Signature</h2>
            <p class="flex items-center gap-1.5">
              <.icon
                name={if current_root?(@version), do: "hero-check-badge", else: "hero-archive-box"}
                class={[
                  "size-4",
                  if(current_root?(@version), do: "text-success", else: "text-base-content/60")
                ]}
              />
              {if current_root?(@version),
                do: "Signed by the current root",
                else: "Signed by a retired root"}
            </p>
            <p class="text-base-content/70">
              Valid {date(@version.not_before)} to {date(@version.expires)}
              <span :if={expired?(@version)} class="badge badge-xs badge-ghost ml-1">expired</span>
            </p>
            <p
              class="break-all font-mono text-xs text-base-content/60"
              title="SHA-256 of the signed payload"
            >
              sha256:{@version.digest}
            </p>
            <p :if={@version.commit} class="font-mono text-xs text-base-content/60">
              commit {String.slice(@version.commit, 0, 12)}
            </p>
          </div>
        </div>

        <div :if={@review != %{}} class="card card-border bg-base-100">
          <div class="card-body gap-2 p-4 text-sm">
            <h2 class="font-semibold">Review before signing</h2>
            <ul class="space-y-1.5">
              <li :for={{check, value} <- Enum.sort(@review)}>
                <span class="flex items-center gap-2">
                  <.icon
                    name={
                      if pending?(value), do: "hero-exclamation-circle", else: "hero-check-circle"
                    }
                    class={[
                      "size-4 shrink-0",
                      if(pending?(value), do: "text-warning", else: "text-success")
                    ]}
                  />
                  {String.replace(check, "_", " ")}
                  <span class="sr-only">{if pending?(value), do: "needs review", else: "reviewed"}</span>
                </span>
                <ul
                  :if={is_list(value) and value != []}
                  class="mt-1 ml-6 list-disc space-y-1 text-xs text-base-content/70"
                >
                  <li :for={note <- value}>{note}</li>
                </ul>
                <p :if={is_map(value)} class="mt-1 ml-6 font-mono text-xs text-base-content/70">
                  {Enum.map_join(value, ", ", fn {k, v} -> "#{String.replace(k, "_", " ")}: #{v}" end)}
                </p>
              </li>
            </ul>
          </div>
        </div>
      </aside>
    </div>
    """
  end

  # The same version string signed again (a renewal or re-key) is a separate bundle.
  defp duplicate?(versions, v), do: Enum.count(versions, &(&1.version == v.version)) > 1

  defp pending?(value),
    do: value == true or (is_list(value) and value != []) or (is_map(value) and value != %{})

  defp license(%{"name" => name}), do: name
  defp license(%{"spdx" => spdx}), do: spdx
  defp license(l) when is_binary(l), do: l
  defp license(l), do: inspect(l)

  defp operations(assigns) do
    ~H"""
    <div class="grid gap-6 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
      <div class="min-w-0">
        <form id="filter-ops" phx-change="filter_ops" phx-submit="filter_ops" class="mb-3">
          <label class="input input-sm w-full">
            <.icon name="hero-funnel" class="size-4 opacity-60" />
            <input
              type="search"
              name="ops"
              value={@ops_q}
              placeholder="Filter by method, path, name or tag"
              phx-debounce="150"
              aria-label="Filter operations"
            />
          </label>
        </form>
        <p class="mb-2 text-xs text-base-content/60">
          {length(@shown_ops)} of {length(@operations)} operations
        </p>
        <ul class="divide-y divide-base-300 rounded-box border border-base-300">
          <li :for={op <- Enum.take(@shown_ops, 400)}>
            <.link
              patch={here(assigns, %{"op" => op["id"], "tab" => "operations"})}
              class={[
                "flex items-center gap-3 px-3 py-2 text-sm hover:bg-base-200",
                @op && @op["id"] == op["id"] && "bg-primary/10"
              ]}
            >
              <.method_badge method={op["method"]} />
              <span class="min-w-0 flex-1">
                <span class="block truncate font-mono text-xs">{op["path"] || op["name"]}</span>
                <span :if={op["summary"]} class="block truncate text-xs text-base-content/60">{op[
                  "summary"
                ]}</span>
              </span>
              <span :if={op["deprecated"]} class="badge badge-xs badge-ghost">deprecated</span>
            </.link>
          </li>
        </ul>
        <p :if={length(@shown_ops) > 400} class="mt-2 text-xs text-base-content/60">
          Showing the first 400. Narrow the filter to see the rest.
        </p>
      </div>

      <div class="min-w-0">
        <div
          :if={!@op}
          class="rounded-box border border-dashed border-base-300 p-8 text-center text-sm text-base-content/60"
        >
          Pick an operation to see its parameters and responses. Its link is shareable.
        </div>
        <article :if={@op} class="sticky top-20 space-y-4">
          <header class="space-y-1">
            <div class="flex items-center gap-2">
              <.method_badge method={@op["method"]} />
              <h2 class="min-w-0 truncate font-mono text-sm font-semibold">
                {@op["path"] || @op["name"]}
              </h2>
              <.copy_button
                id="copy-op"
                value={
                  absolute(
                    here(assigns, %{
                      "op" => @op["id"],
                      "tab" => "operations",
                      "version" => "sha256:" <> @version.digest
                    })
                  )
                }
                label="Copy link to this operation"
              />
            </div>
            <p class="font-mono text-xs text-base-content/60">{@op["name"]}</p>
            <p :if={@op["summary"]} class="text-sm">{@op["summary"]}</p>
            <div class="flex flex-wrap gap-1.5 text-xs">
              <span :if={@op["safe"]} class="badge badge-sm badge-success badge-soft">read only</span>
              <span :if={@op["safe"] == false} class="badge badge-sm badge-warning badge-soft">writes</span>
              <span :for={tag <- @op["tags"] || []} class="badge badge-sm badge-ghost">{tag}</span>
            </div>
          </header>

          <div :if={(@op["parameters"] || []) != []}>
            <h3 class="mb-2 text-xs font-semibold tracking-wide text-base-content/60 uppercase">
              Parameters
            </h3>
            <table class="table table-sm">
              <tbody>
                <tr :for={p <- @op["parameters"]}>
                  <td class="font-mono text-xs">
                    {p["name"]}<span :if={p["required"]} class="text-error" title="required">*</span>
                  </td>
                  <td class="text-xs text-base-content/60">{p["in"]}</td>
                  <td class="font-mono text-xs">{p["type"]}</td>
                  <td class="text-xs">{p["description"]}</td>
                </tr>
              </tbody>
            </table>
          </div>

          <div :if={@op["request"]}>
            <h3 class="mb-2 text-xs font-semibold tracking-wide text-base-content/60 uppercase">
              Request body
            </h3>
            <p class="font-mono text-xs">
              {@op["request"]["type"]}
              <span class="text-base-content/60">{Enum.join(
                @op["request"]["content_types"] || [],
                ", "
              )}</span>
            </p>
          </div>

          <div :if={(@op["responses"] || []) != []}>
            <h3 class="mb-2 text-xs font-semibold tracking-wide text-base-content/60 uppercase">
              Responses
            </h3>
            <ul class="space-y-1 font-mono text-xs">
              <li :for={r <- @op["responses"]}>
                <span class={[
                  "mr-2",
                  String.starts_with?(to_string(r["status"]), "2") && "text-success"
                ]}>{r["status"]}</span>
                {r["type"]}
              </li>
            </ul>
          </div>
        </article>
      </div>
    </div>
    """
  end

  defp versions(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="table table-sm">
        <thead>
          <tr>
            <th>Version</th>
            <th>Signed</th>
            <th>Expires</th>
            <th>Status</th>
            <th>Digest</th>
            <th class="sr-only">Links</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={v <- @versions} class={[v.digest == @version.digest && "bg-primary/5"]}>
            <td class="font-mono">
              <.link
                patch={here(assigns, %{"version" => "sha256:" <> v.digest})}
                class="link link-hover"
              >{v.version}</.link>
              <span :if={duplicate?(@versions, v)} class="ml-1 text-xs text-base-content/50">re-signed</span>
              <span
                :if={v.digest == @manifest.latest_digest}
                class="badge badge-xs badge-primary ml-1"
              >latest</span>
            </td>
            <td class="tabular-nums">{date(v.not_before)}</td>
            <td class={["tabular-nums", expired?(v) && "text-base-content/50"]}>{date(v.expires)}</td>
            <td>
              <span class="text-xs">{v.catalog}</span>
              <span
                :if={!current_root?(v)}
                class="badge badge-xs badge-ghost ml-1"
                title="Signed before the root key rotation"
              >retired root</span>
            </td>
            <td class="font-mono text-xs text-base-content/60" title={v.digest}>
              {String.slice(v.digest, 0, 12)}
            </td>
            <td class="text-right">
              <.copy_button
                id={"copy-#{v.digest}"}
                value={absolute(link_to(@manifest.id, %{"version" => "sha256:" <> v.digest}))}
                label={"Copy link to #{v.version}"}
              />
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
