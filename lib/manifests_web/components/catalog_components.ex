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
end
