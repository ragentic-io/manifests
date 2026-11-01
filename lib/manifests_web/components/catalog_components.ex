defmodule ManifestsWeb.CatalogComponents do
  @moduledoc "Small pieces shared by the catalog and manifest pages."
  use Phoenix.Component
  import ManifestsWeb.CoreComponents, only: [icon: 1]
  alias Phoenix.LiveView.JS

  attr :manifest, :map, required: true
  attr :class, :string, default: "size-10"

  def app_logo(assigns) do
    ~H"""
    <div class={[
      @class,
      "grid shrink-0 place-items-center overflow-hidden rounded-field border border-base-300 bg-base-200"
    ]}>
      <img
        :if={@manifest.logo}
        src={@manifest.logo}
        alt=""
        loading="lazy"
        referrerpolicy="no-referrer"
        class="size-full object-contain p-1"
        onerror="this.remove()"
      />
      <span
        :if={!@manifest.logo}
        class="font-mono text-sm font-semibold text-base-content/60"
        aria-hidden="true"
      >
        {@manifest.title
        |> String.replace(~r/^Connection to /, "")
        |> String.first()
        |> String.upcase()}
      </span>
    </div>
    """
  end

  attr :protocol, :string, required: true

  def protocol_badge(assigns) do
    ~H"""
    <span class={[
      "badge badge-sm font-mono",
      case @protocol do
        "openapi" -> "badge-info badge-soft"
        "graphql" -> "badge-secondary badge-soft"
        _ -> "badge-accent badge-soft"
      end
    ]}>{@protocol}</span>
    """
  end

  attr :method, :string, required: true

  def method_badge(assigns) do
    ~H"""
    <span class={[
      "inline-block w-16 shrink-0 rounded-field px-1.5 py-0.5 text-center font-mono text-[11px] font-semibold uppercase",
      case @method do
        "get" -> "bg-info/15 text-info"
        "post" -> "bg-success/15 text-success"
        "put" -> "bg-warning/15 text-warning"
        "patch" -> "bg-warning/15 text-warning"
        "delete" -> "bg-error/15 text-error"
        _ -> "bg-base-300 text-base-content/70"
      end
    ]}>{@method || "op"}</span>
    """
  end

  attr :id, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, default: "Copy"

  def copy_button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      class="btn btn-ghost btn-xs"
      data-copy={@value}
      phx-click={JS.dispatch("manifests:copy")}
      aria-label={@label}
      title={@label}
    >
      <.icon name="hero-clipboard-document" class="size-4" />
    </button>
    """
  end

  @doc "The value half of a `key:value` label."
  def label_value(label), do: label |> String.split(":", parts: 2) |> List.last() |> humanize()

  defp humanize(value), do: String.replace(value, ["_", "-"], " ")

  @doc """
  A bar chart of `[{period_start, count}]`, drawn as SVG on the server so it
  updates over the LiveView socket like any other markup. Short series are
  right-aligned against a minimum number of slots so one bar isn't page-wide.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :series, :list, required: true
  attr :label, :any, required: true, doc: "period start -> label"
  attr :slots, :integer, default: 12

  def bar_chart(assigns) do
    counts = Enum.map(assigns.series, &elem(&1, 1))
    peak = Enum.max([1 | counts])
    slots = max(length(assigns.series), assigns.slots)
    offset = slots - length(assigns.series)

    bars =
      assigns.series
      |> Enum.with_index()
      |> Enum.map(fn {{start, n}, i} ->
        h = if n == 0, do: 0, else: max(n / peak * 96, 2)
        %{x: (offset + i) * 10 + 1, y: 100 - h, h: h, title: "#{assigns.label.(start)}: #{number(n)}"}
      end)

    {first, _} = List.first(assigns.series)
    {last, _} = List.last(assigns.series)

    assigns =
      assign(assigns,
        bars: bars,
        width: slots * 10,
        pad: Float.round(offset / slots * 100, 2),
        peak: Enum.max([0 | counts]),
        total: Enum.sum(counts),
        first: assigns.label.(first),
        last: assigns.label.(last)
      )

    ~H"""
    <figure id={@id} class="min-w-0 rounded-box border border-base-300 bg-base-100 p-3">
      <figcaption class="mb-2 flex items-baseline justify-between gap-2 text-xs">
        <span class="font-semibold">{@title}</span>
        <span class="text-base-content/60">
          {number(@total)} total · peak {number(@peak)}
        </span>
      </figcaption>
      <svg
        viewBox={"0 0 #{@width} 100"}
        preserveAspectRatio="none"
        class="h-24 w-full"
        role="img"
        aria-label={"#{@title}: #{number(@total)} downloads from #{@first} to #{@last}, peak #{number(@peak)}"}
      >
        <line x1="0" y1="99.5" x2={@width} y2="99.5" class="stroke-base-300" stroke-width="1" />
        <rect
          :for={bar <- @bars}
          x={bar.x}
          y={bar.y}
          width="8"
          height={bar.h}
          rx="1"
          class="fill-primary"
        >
          <title>{bar.title}</title>
        </rect>
      </svg>
      <div
        class="mt-1 flex justify-between font-mono text-[10px] text-base-content/50"
        style={"padding-left: #{@pad}%"}
      >
        <span>{@first}</span>
        <span>{@last}</span>
      </div>
    </figure>
    """
  end

  @doc "An integer with thousands separators."
  def number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
