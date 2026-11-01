defmodule ManifestsWeb.CatalogLive do
  @moduledoc """
  The catalog: search plus label filters. Every bit of state lives in the URL
  (`q`, `labels`, `protocol`, `catalog`, `sort`, `page`), so any view can be
  linked to and reloaded.

  Download counts (catalog-wide and per card) are live: every bundle served
  arrives on `Manifests.Analytics.topic/0` and is folded in here.
  """
  use ManifestsWeb, :live_view
  alias Manifests.Analytics
  alias Manifests.Registry
  alias Manifests.Registry.Lookup
  import ManifestsWeb.CatalogComponents

  @per_page 48
  @facet_order ~w(category protocol catalog auth readiness)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Manifests.PubSub, Analytics.topic())
    {:ok, assign(socket, downloads: Analytics.summary(:all))}
  end

  @impl true
  def handle_info({:download, id, digest, day}, socket) do
    downloads =
      if day == socket.assigns.downloads.today,
        do: Analytics.bump(socket.assigns.downloads, digest, day) |> Map.put(:by_digest, %{}),
        else: Analytics.summary(:all)

    results =
      Enum.map(socket.assigns.results, fn
        %{id: ^id} = m -> %{m | downloads: m.downloads + 1}
        m -> m
      end)

    {:noreply, assign(socket, downloads: downloads, results: results)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = Lookup.filters(params)

    page =
      params
      |> Map.get("page", "1")
      |> Integer.parse()
      |> case(
        do: (
          {n, _} when n > 0 -> n
          _ -> 1
        )
      )

    results =
      Registry.search_manifests!(filters,
        page: [limit: @per_page, offset: (page - 1) * @per_page, count: true]
      )

    {:noreply,
     socket
     |> assign(
       page_title: title(filters),
       filters: filters,
       page: page,
       pages: max(1, ceil(results.count / @per_page)),
       total: results.count,
       results: results.results,
       facets: order(Lookup.facets(filters))
     )}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply,
     push_patch(socket, to: catalog_path(%{socket.assigns.filters | q: q}), replace: true)}
  end

  def handle_event("sort", %{"sort" => sort}, socket) do
    {:noreply, push_patch(socket, to: catalog_path(%{socket.assigns.filters | sort: sort}))}
  end

  defp order(facets) do
    known = for k <- @facet_order, Map.has_key?(facets, k), do: {k, facets[k]}
    known ++ Enum.sort(Map.drop(facets, @facet_order))
  end

  defp title(%{q: nil, labels: []}), do: "Manifest catalog"
  defp title(%{q: q, labels: labels}), do: Enum.join(Enum.reject([q | labels], &is_nil/1), " · ")

  @doc "The catalog URL for `filters`, dropping empty ones so links stay short."
  def catalog_path(filters, page \\ 1) do
    query =
      [
        q: filters[:q],
        labels: Enum.join(filters[:labels] || [], ","),
        protocol: filters[:protocol],
        catalog: filters[:catalog],
        sort: filters[:sort],
        page: if(page > 1, do: page)
      ]
      |> Enum.reject(fn {_, v} -> v in [nil, ""] end)

    ~p"/?#{query}"
  end

  defp toggle(filters, label) do
    labels = filters.labels

    %{
      filters
      | labels: if(label in labels, do: List.delete(labels, label), else: labels ++ [label])
    }
  end

  defp facet_title("category"), do: "Category"
  defp facet_title("protocol"), do: "Protocol"
  defp facet_title("catalog"), do: "Status"
  defp facet_title("auth"), do: "Authentication"
  defp facet_title("readiness"), do: "Readiness"
  defp facet_title(other), do: String.capitalize(other)

  attr :facets, :list, required: true
  attr :filters, :map, required: true

  defp facet_list(assigns) do
    ~H"""
    <div class="space-y-6">
      <div :if={@filters.labels != []} class="flex flex-wrap gap-1.5">
        <.link
          :for={label <- @filters.labels}
          patch={catalog_path(toggle(@filters, label))}
          class="badge badge-primary gap-1 font-mono text-xs"
          aria-label={"Remove #{label}"}
        >
          {label} <.icon name="hero-x-mark-micro" class="size-3" />
        </.link>
        <.link patch={catalog_path(%{@filters | labels: []})} class="badge badge-ghost text-xs">Clear</.link>
      </div>

      <details
        :for={{key, pairs} <- @facets}
        open={key in ~w(category protocol catalog)}
        class="group"
      >
        <summary class="flex cursor-pointer list-none items-center justify-between text-xs font-semibold tracking-wide text-base-content/60 uppercase">
          {facet_title(key)}
          <.icon name="hero-chevron-down-micro" class="size-4 transition group-open:rotate-180" />
        </summary>
        <ul class="mt-2 space-y-0.5">
          <li :for={{label, count} <- pairs}>
            <.link
              patch={catalog_path(toggle(@filters, label))}
              class={[
                "flex items-center justify-between rounded-field px-2 py-1 text-sm hover:bg-base-200",
                label in @filters.labels && "bg-primary/10 font-medium text-primary"
              ]}
              aria-pressed={to_string(label in @filters.labels)}
            >
              <span class="truncate">{label_value(label)}</span>
              <span class="text-xs tabular-nums text-base-content/50">{count}</span>
            </.link>
          </li>
        </ul>
      </details>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <:search>
        <form id="search" phx-change="search" phx-submit="search" role="search" class="w-full">
          <label class="input input-sm w-full bg-base-100">
            <.icon name="hero-magnifying-glass" class="size-4 opacity-60" />
            <input
              type="search"
              name="q"
              value={@filters.q}
              placeholder="Search apps, endpoints, operations…"
              phx-debounce="200"
              autocomplete="off"
              aria-label="Search the catalog"
            />
          </label>
        </form>
      </:search>

      <section
        id="catalog-downloads"
        aria-labelledby="catalog-downloads-heading"
        class="mb-8 grid gap-4 lg:grid-cols-[15rem_minmax(0,1fr)] lg:gap-8"
      >
        <div class="stats stats-horizontal border border-base-300 bg-base-100 lg:stats-vertical">
          <div class="stat px-4 py-3">
            <div id="catalog-downloads-heading" class="stat-title flex items-center gap-2">
              Downloads
              <span class="relative flex size-2" title="Updates live">
                <span class="absolute inline-flex size-full animate-ping rounded-full bg-success opacity-60"></span>
                <span class="relative inline-flex size-2 rounded-full bg-success"></span>
              </span>
            </div>
            <div
              id="catalog-downloads-total"
              class="stat-value text-3xl tabular-nums"
              aria-live="polite"
            >
              {number(@downloads.total)}
            </div>
            <div class="stat-desc">every application, all time</div>
          </div>
          <div class="stat px-4 py-3">
            <div class="stat-title">Today (UTC)</div>
            <div id="catalog-downloads-today" class="stat-value text-3xl tabular-nums">
              {number(@downloads.on_day)}
            </div>
            <.link
              patch={catalog_path(%{@filters | sort: "downloads"})}
              class="stat-desc link link-hover"
            >Most downloaded →</.link>
          </div>
        </div>
        <div class="grid min-w-0 gap-4 md:grid-cols-3">
          <.bar_chart
            id="catalog-downloads-daily"
            title="Daily · last 30 days"
            series={@downloads.days}
            label={&Calendar.strftime(&1, "%b %-d")}
            slots={30}
          />
          <.bar_chart
            id="catalog-downloads-weekly"
            title="Weekly · last 26 weeks"
            series={@downloads.weeks}
            label={&("Week of " <> Calendar.strftime(&1, "%b %-d, %Y"))}
            slots={26}
          />
          <.bar_chart
            id="catalog-downloads-yearly"
            title="Yearly"
            series={@downloads.years}
            label={&Integer.to_string(&1.year)}
            slots={6}
          />
        </div>
      </section>

      <div class="grid gap-6 lg:grid-cols-[15rem_minmax(0,1fr)] lg:gap-8">
        <details id="filters" class="group/filters min-w-0 lg:hidden">
          <summary class="btn btn-sm w-full justify-between">
            <span>Filters
            <span :if={@filters.labels != []} class="badge badge-xs badge-primary">{length(
              @filters.labels
            )}</span></span>
            <.icon name="hero-adjustments-horizontal" class="size-4" />
          </summary>
          <div class="mt-4"><.facet_list facets={@facets} filters={@filters} /></div>
        </details>
        <aside class="hidden min-w-0 lg:block" aria-label="Filters">
          <.facet_list facets={@facets} filters={@filters} />
        </aside>

        <section class="min-w-0" aria-live="polite">
          <div class="mb-4 flex flex-wrap items-baseline justify-between gap-3">
            <h1 class="text-lg font-semibold">
              {@total} {if @total == 1, do: "application", else: "applications"}
              <span :if={@filters.q} class="font-normal text-base-content/60">
                matching “{@filters.q}”
              </span>
            </h1>
            <form id="sort-form" phx-change="sort" class="flex items-center gap-2 text-sm">
              <label for="sort" class="text-base-content/60">Sort</label>
              <select id="sort" name="sort" class="select select-sm w-auto">
                {Phoenix.HTML.Form.options_for_select(
                  [
                    {"Name", "name"},
                    {"Recently signed", "updated"},
                    {"Most operations", "operations"},
                    {"Most downloaded", "downloads"}
                  ],
                  @filters.sort || "name"
                )}
              </select>
            </form>
          </div>

          <div
            :if={@results == []}
            class="rounded-box border border-dashed border-base-300 p-12 text-center"
          >
            <p class="font-medium">Nothing matches.</p>
            <p class="mt-1 text-sm text-base-content/60">
              Try fewer words or <.link patch={~p"/"} class="link">clear every filter</.link>.
            </p>
          </div>

          <ul class="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-3">
            <li :for={m <- @results}>
              <.link
                navigate={~p"/apps/#{m.id}?#{[version: "latest"]}"}
                class="card card-border h-full bg-base-100 transition hover:border-primary/50 hover:shadow-sm"
              >
                <div class="card-body gap-3 p-4">
                  <div class="flex items-start gap-3">
                    <.app_logo manifest={m} />
                    <div class="min-w-0">
                      <h2 class="truncate font-semibold leading-tight">{m.title}</h2>
                      <p class="truncate font-mono text-xs text-base-content/60">{m.id}</p>
                    </div>
                  </div>
                  <p :if={m.endpoint} class="truncate font-mono text-xs text-base-content/70">
                    {m.endpoint}
                  </p>
                  <div class="mt-auto flex flex-wrap items-center gap-1.5 text-xs">
                    <.protocol_badge protocol={m.protocol} />
                    <span :if={m.catalog == "draft"} class="badge badge-sm badge-warning badge-soft">draft</span>
                    <span
                      class="badge badge-sm badge-ghost max-w-28 font-mono"
                      title={m.latest_version}
                    >
                      <span class="truncate">{m.latest_version}</span>
                    </span>
                    <span class="ml-auto flex items-center gap-2 tabular-nums text-base-content/60">
                      <span>{m.operation_count} ops</span>
                      <span
                        id={"downloads-#{m.id}"}
                        class="flex items-center gap-0.5"
                        title={"#{number(m.downloads)} downloads"}
                      >
                        <.icon name="hero-arrow-down-tray" class="size-3.5" />{number(m.downloads)}
                        <span class="sr-only">downloads</span>
                      </span>
                    </span>
                  </div>
                </div>
              </.link>
            </li>
          </ul>

          <nav :if={@pages > 1} class="mt-8 flex justify-center" aria-label="Pages">
            <div class="join">
              <.link
                :if={@page > 1}
                patch={catalog_path(@filters, @page - 1)}
                class="join-item btn btn-sm"
              >«</.link>
              <span class="join-item btn btn-sm btn-disabled tabular-nums">Page {@page} of {@pages}</span>
              <.link
                :if={@page < @pages}
                patch={catalog_path(@filters, @page + 1)}
                class="join-item btn btn-sm"
              >»</.link>
            </div>
          </nav>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
