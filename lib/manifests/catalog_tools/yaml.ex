defmodule Manifests.CatalogTools.Yaml do
  @moduledoc """
  `yaml.safe_load` for OpenAPI definitions published as YAML, with PyYAML's results:
  mapping order is kept (`{:o, pairs}` like `Manifests.CatalogTools.Json`), plain
  scalars resolve with YAML 1.1 rules (`yes`/`on` are booleans, `1_000` and `0x1f`
  are ints, `1e5` is a string, `<<` merges), and dates become a value that cannot be
  written as JSON, as in Python.

  Parsing is yamerl's; `Manifests.CatalogTools.YamlScalar` hands over each untagged
  scalar's raw text.
  """

  alias Manifests.CatalogTools.{Error, YamlScalar}

  @doc "The first document of `text`, or `nil` for an empty stream."
  def safe_load!(text) do
    text = strip_bom(text)

    docs =
      try do
        :yamerl_constr.string(text, [
          :detailed_constr,
          {:schema, :yaml11},
          {:node_mods, [YamlScalar]}
        ])
      catch
        {:yamerl_exception, errors} -> raise Error, "YAML: #{format_errors(errors)}"
      end

    case docs do
      [] -> nil
      [{:yamerl_doc, root} | _] -> convert(root)
    end
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(text), do: text

  defp format_errors(errors) do
    # yamerl lists the most recent error first; report the earliest.
    errors
    |> Enum.reverse()
    |> Enum.take(1)
    |> Enum.map_join("; ", fn
      {:yamerl_parsing_error, _type, text, line, column, _name, _token, _extra} ->
        "#{text} (line #{line}, column #{column})"

      e ->
        inspect(e)
    end)
  end

  defp convert({:yamerl_str, YamlScalar, tag, _, text}) do
    text = List.to_string(text)
    if tag == YamlScalar.plain_tag(), do: resolve(text), else: text
  end

  defp convert({:yamerl_str, _, _, _, text}), do: List.to_string(text)
  defp convert({:yamerl_null, _, _, _}), do: nil
  defp convert({:yamerl_bool, _, _, _, value}), do: value
  defp convert({:yamerl_int, _, _, _, value}), do: value
  defp convert({:yamerl_float, _, _, _, value}), do: special_float(value)
  defp convert({:yamerl_seq, _, _, _, items, _count}), do: Enum.map(items, &convert/1)
  defp convert({:yamerl_map, _, _, _, pairs}), do: {:o, mapping(pairs)}

  defp convert({:yamerl_timestamp, _, _, _, _, _, _, _, _, _, _}),
    do: {:py_unencodable, "datetime"}

  defp convert(other) when is_tuple(other), do: {:py_unencodable, other |> elem(0) |> to_string()}

  defp special_float(:"+inf"), do: :infinity
  defp special_float(:"-inf"), do: :neg_infinity
  defp special_float(:nan), do: :nan
  defp special_float(f), do: f

  # SafeConstructor.flatten_mapping + construct_mapping: merged pairs come first and
  # the mapping's own pairs override them; each key keeps its first position.
  defp mapping(pairs) do
    {merged, own} =
      Enum.reduce(pairs, {[], []}, fn {k, v}, {merged, own} ->
        if merge_key?(k) do
          {Enum.reverse(merge_pairs(v), merged), own}
        else
          {merged, [{key(convert(k)), convert(v)} | own]}
        end
      end)

    dedupe(Enum.reverse(merged) ++ Enum.reverse(own))
  end

  defp merge_key?({:yamerl_str, YamlScalar, tag, _, ~c"<<"}), do: tag == YamlScalar.plain_tag()
  defp merge_key?(_), do: false

  defp merge_pairs({:yamerl_map, _, _, _, _} = node) do
    {:o, pairs} = convert(node)
    pairs
  end

  defp merge_pairs({:yamerl_seq, _, _, _, items, _}) do
    items
    |> Enum.map(fn
      {:yamerl_map, _, _, _, _} = node -> merge_pairs(node)
      _ -> raise Error, "YAML: expected a mapping for merging"
    end)
    |> Enum.reverse()
    |> Enum.concat()
  end

  defp merge_pairs(_),
    do: raise(Error, "YAML: expected a mapping or list of mappings for merging")

  defp key(k) when is_list(k) or (is_tuple(k) and elem(k, 0) == :o),
    do: raise(Error, "YAML: found unhashable key")

  defp key(k), do: k

  defp dedupe(pairs) do
    last = Map.new(pairs)
    pairs |> Enum.uniq_by(&elem(&1, 0)) |> Enum.map(fn {k, _} -> {k, Map.fetch!(last, k)} end)
  end

  # --- PyYAML implicit resolvers -----------------------------------------------

  @bools %{
    "yes" => true,
    "Yes" => true,
    "YES" => true,
    "true" => true,
    "True" => true,
    "TRUE" => true,
    "on" => true,
    "On" => true,
    "ON" => true,
    "no" => false,
    "No" => false,
    "NO" => false,
    "false" => false,
    "False" => false,
    "FALSE" => false,
    "off" => false,
    "Off" => false,
    "OFF" => false
  }

  @float ~S"\A(?:[-+]?(?:[0-9][0-9_]*)\.[0-9_]*(?:[eE][-+][0-9]+)?|\.[0-9][0-9_]*(?:[eE][-+][0-9]+)?|[-+]?[0-9][0-9_]*(?::[0-5]?[0-9])+\.[0-9_]*|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN))\z"
  @int ~S"\A(?:[-+]?0b[0-1_]+|[-+]?0[0-7_]+|[-+]?(?:0|[1-9][0-9_]*)|[-+]?0x[0-9a-fA-F_]+|[-+]?[1-9][0-9_]*(?::[0-5]?[0-9])+)\z"
  @timestamp ~S"\A(?:[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]|[0-9][0-9][0-9][0-9]-[0-9][0-9]?-[0-9][0-9]?(?:[Tt]|[ \t]+)[0-9][0-9]?:[0-9][0-9]:[0-9][0-9](?:\.[0-9]*)?(?:[ \t]*(?:Z|[-+][0-9][0-9]?(?::[0-9][0-9])?))?)\z"

  @doc false
  def resolve(text) do
    cond do
      Map.has_key?(@bools, text) -> Map.fetch!(@bools, text)
      text in ["~", "null", "Null", "NULL", ""] -> nil
      Regex.match?(regex(:int), text) -> to_int(text)
      Regex.match?(regex(:float), text) -> to_float(text)
      Regex.match?(regex(:timestamp), text) -> {:py_unencodable, "date"}
      true -> text
    end
  end

  defp regex(name) do
    key = {__MODULE__, name}

    case :persistent_term.get(key, nil) do
      nil ->
        source =
          case name do
            :int -> @int
            :float -> @float
            :timestamp -> @timestamp
          end

        r = Regex.compile!(source)
        :persistent_term.put(key, r)
        r

      r ->
        r
    end
  end

  defp sign(text) do
    case text do
      "-" <> rest -> {-1, rest}
      "+" <> rest -> {1, rest}
      rest -> {1, rest}
    end
  end

  defp to_int(text) do
    {sign, value} = text |> String.replace("_", "") |> sign()

    cond do
      value == "0" ->
        0

      String.starts_with?(value, "0b") ->
        sign * String.to_integer(String.slice(value, 2..-1//1), 2)

      String.starts_with?(value, "0x") ->
        sign * String.to_integer(String.slice(value, 2..-1//1), 16)

      String.starts_with?(value, "0") ->
        sign * String.to_integer(value, 8)

      String.contains?(value, ":") ->
        sign * sexagesimal(value, &String.to_integer/1, 0)

      true ->
        sign * String.to_integer(value)
    end
  end

  defp to_float(text) do
    {sign, value} = text |> String.replace("_", "") |> String.downcase() |> sign()

    cond do
      value == ".inf" -> if sign < 0, do: :neg_infinity, else: :infinity
      value == ".nan" -> :nan
      String.contains?(value, ":") -> sign * sexagesimal(value, &parse_float/1, 0.0)
      true -> sign * parse_float(value)
    end
  end

  defp sexagesimal(value, parse, zero) do
    value
    |> String.split(":")
    |> Enum.map(parse)
    |> Enum.reverse()
    |> Enum.reduce({zero, 1}, fn digit, {acc, base} -> {acc + digit * base, base * 60} end)
    |> elem(0)
  end

  # Python float() of what the float resolver accepts: `1.`, `.5`, `1.5e+3`, `30`.
  defp parse_float(text) do
    {mantissa, exp} =
      case String.split(text, "e") do
        [m, e] -> {m, e}
        [m] -> {m, "0"}
      end

    {int, frac} =
      case String.split(mantissa, ".") do
        [i, f] -> {i, f}
        [i] -> {i, ""}
      end

    int = if int == "", do: "0", else: int
    frac = if frac == "", do: "0", else: frac
    :erlang.binary_to_float(int <> "." <> frac <> "e" <> exp)
  end
end
