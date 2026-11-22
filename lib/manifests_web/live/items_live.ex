defmodule ManifestsWeb.ItemsLive do
  @moduledoc """
  Items of any kind — Agents, Teams, Workflows, Sites, Packages — grouped by
  kind, with search and a kind filter in the URL (`q`, `kind`). Each item says
  how to install it: `ragentic install <id>`, or Install in ragentic.
  """
  use ManifestsWeb, :live_view
  alias Manifests.Registry

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(params, _uri, socket) do
    q = blank(params["q"])
    kind = blank(params["kind"])
    all = Registry.search_items!(nil, nil, nil, nil, nil, page: [limit: 200, count: true])
    items = Registry.search_items!(q, kind, nil, nil, nil, page: [limit: 200, count: true])

    {:noreply,
     assign(socket,
       page_title: "Items",
       q: q,
       kind: kind,
       total: items.count,
       kinds: all.results |> Enum.frequencies_by(& &1.kind) |> Enum.sort(),
       groups: items.results |> Enum.group_by(& &1.kind) |> Enum.sort()
     )}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: items_path(blank(q), socket.assigns.kind), replace: true)}
  end

  defp blank(v) when v in [nil, ""], do: nil
  defp blank(v), do: v

  defp items_path(q, kind),
    do: ~p"/items?#{Enum.reject([q: q, kind: kind], fn {_, v} -> is_nil(v) end)}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-6xl space-y-6 px-4 py-8">
        <header class="space-y-2">
          <h1 class="text-2xl font-semibold">Items</h1>
          <p class="text-sm opacity-70">
            Preconfigured agents, teams, workflows, sites and packages: anything that is a ragentic manifest.
            Install one with <code class="font-mono">ragentic install &lt;id&gt;</code>
            or Install in ragentic's registry page; each agent's suggested model maps to one of your providers.
          </p>
        </header>

        <form id="items-search" phx-change="search" phx-submit="search">
          <input
            type="search"
            name="q"
            value={@q}
            placeholder="Search items"
            phx-debounce="250"
            class="w-full rounded-lg border border-base-300 bg-base-100 px-3 py-2"
          />
        </form>

        <nav id="items-kinds" class="flex flex-wrap gap-2">
          <.link
            patch={items_path(@q, nil)}
            class={[
              "rounded-full border px-3 py-1 text-sm",
              is_nil(@kind) && "bg-base-content text-base-100"
            ]}
          >
            All
          </.link>
          <.link
            :for={{kind, n} <- @kinds}
            id={"kind-#{kind}"}
            patch={items_path(@q, kind)}
            class={[
              "rounded-full border px-3 py-1 text-sm",
              @kind == kind && "bg-base-content text-base-100"
            ]}
          >
            {kind} <span class="opacity-60">{n}</span>
          </.link>
        </nav>

        <p :if={@total == 0} id="items-empty" class="opacity-70">No items match.</p>

        <section :for={{kind, items} <- @groups} id={"items-#{kind}"} class="space-y-3">
          <h2 class="text-lg font-semibold">
            {kind} <span class="opacity-60">{length(items)}</span>
          </h2>
          <ul class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            <li
              :for={item <- items}
              id={"item-#{item.item_id}"}
              class="rounded-xl border border-base-300 p-4 transition hover:shadow-md"
            >
              <div class="flex items-baseline justify-between gap-2">
                <h3 class="font-medium">{item.title}</h3>
                <span class="font-mono text-xs opacity-60">{item.version}</span>
              </div>
              <p class="mt-1 line-clamp-3 text-sm opacity-80">{item.description}</p>
              <div class="mt-2 flex flex-wrap gap-1">
                <span
                  :for={t <- item.tiers}
                  class="rounded bg-base-200 px-1.5 py-0.5 font-mono text-xs"
                >
                  {String.replace(t, "+", " · ")}
                </span>
                <span
                  :for={c <- item.categories}
                  class="rounded border px-1.5 py-0.5 text-xs opacity-70"
                >{c}</span>
              </div>
              <code class="mt-3 block font-mono text-xs opacity-80">ragentic install {item.item_id}</code>
            </li>
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
