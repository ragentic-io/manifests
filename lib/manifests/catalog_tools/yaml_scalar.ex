defmodule Manifests.CatalogTools.YamlScalar do
  @moduledoc false
  # A yamerl node module that claims every scalar without an explicit tag and keeps
  # its raw text and whether it was plain, so `Manifests.CatalogTools.Yaml` can
  # resolve it the way PyYAML's SafeLoader does (YAML 1.1 implicit types).
  #
  # The node keeps the shape of yamerl's `#yamerl_str{}` record; the tag marks the style.

  @plain ~c"tag:catalog-tools:plain"
  @quoted ~c"tag:catalog-tools:quoted"

  def plain_tag, do: @plain
  def quoted_tag, do: @quoted

  def tags, do: []

  def try_construct_token(
        _constr,
        :undefined,
        {:yamerl_scalar, line, column, tag, _style, substyle, text}
      ) do
    case tag do
      {:yamerl_tag, _, _, {:non_specific, _}} ->
        node_tag = if substyle == :plain, do: @plain, else: @quoted
        {:finished, {:yamerl_str, __MODULE__, node_tag, [line: line, column: column], text}}

      _ ->
        :unrecognized
    end
  end

  def try_construct_token(_, _, _), do: :unrecognized

  def construct_token(constr, node, token), do: try_construct_token(constr, node, token)

  def node_pres({:yamerl_str, _, _, pres, _}), do: pres
end
