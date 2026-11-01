defmodule Manifests.CatalogTools.Graph do
  @moduledoc """
  The operation graph of an OpenAPI 3 or Swagger 2 document (`openapi_graph` in the
  Python tool).

  Nodes: the application, each operation (parameters, request and response types,
  tags, scopes, and whether it is safe to call for a preview) and each schema.
  Edges: application EXPOSES operation, operation ACCEPTS / RETURNS schema, and
  schema REFERENCES schema.

  The document is decoded JSON from `Manifests.CatalogTools.Json`, so paths,
  parameters, responses and schemas are visited in document order.
  """

  alias Manifests.CatalogTools.{Json, Py}

  @methods ~w(get put post delete options head patch trace)
  @safe_methods ~w(get head options)
  @schema_refs ["#/components/schemas/", "#/definitions/"]
  @max_enum 25

  def methods, do: @methods

  @doc "The graph of `document` for application `app_id`."
  def openapi_graph(app_id, document) do
    schemas =
      document
      |> Json.get("components")
      |> Py.py_or(%{})
      |> Json.get("schemas")
      |> Py.py_or(Json.get(document, "definitions"))
      |> Py.py_or(%{})

    known = schemas |> Json.keys() |> Enum.map(&Json.plain/1) |> MapSet.new()
    in_schemas = &MapSet.member?(known, &1)

    paths = document |> Json.get("paths") |> Py.py_or(%{}) |> Json.items()

    {ops, exposes, op_links} =
      for {path, item} <- paths,
          Json.dict?(item),
          method <- @methods,
          op = Json.get(item, method),
          Json.dict?(op),
          reduce: {[], [], []} do
        {nodes, edges, links} ->
          op_id = "operation:#{method}:#{Py.str(path)}"
          {node, accepts, returns} = operation(document, path, item, method, op)

          new_links =
            for(
              n <- Enum.sort(accepts),
              in_schemas.(n),
              do: link(op_id, "ACCEPTS", "schema:#{n}")
            ) ++
              for(
                n <- Enum.sort(returns),
                in_schemas.(n),
                do: link(op_id, "RETURNS", "schema:#{n}")
              )

          {[Map.put(node, "id", op_id) | nodes], [link(app_id, "EXPOSES", op_id) | edges],
           [new_links | links]}
      end

    {schema_nodes, ref_links} =
      for {name, schema} <- Json.items(schemas), reduce: {[], []} do
        {nodes, links} ->
          sid = "schema:#{Py.str(name)}"
          node = %{"id" => sid, "kind" => "schema", "name" => name}

          node =
            if Json.dict?(schema) do
              {kind, _} = type(Json.delete(schema, "$ref"), MapSet.new())
              node = if Py.truthy?(kind), do: Map.put(node, "type", kind), else: node
              description = Py.short(Json.get(schema, "description"))

              if Py.truthy?(description),
                do: Map.put(node, "description", description),
                else: node
            else
              node
            end

          refs = references(schema, MapSet.new(), 0)

          new_links =
            for n <- Enum.sort(refs),
                in_schemas.(n),
                n != name,
                do: link(sid, "REFERENCES", "schema:#{n}")

          {[node | nodes], [new_links | links]}
      end

    nodes =
      [%{"id" => app_id, "kind" => "application"} | Enum.reverse(ops)] ++
        Enum.reverse(schema_nodes)

    links = Enum.concat(Enum.reverse(op_links)) ++ Enum.concat(Enum.reverse(ref_links))
    %{"edges" => Enum.reverse(exposes) ++ links, "nodes" => nodes}
  end

  defp link(from, kind, to), do: %{"from" => from, "kind" => kind, "to" => to}

  @doc "Sorted canonical bytes of a graph's nodes and edges, for an order-insensitive comparison."
  def sorted_graph(graph) do
    {
      graph |> Json.get("nodes", []) |> Enum.map(&Json.canonical/1) |> Enum.sort(),
      graph |> Json.get("edges", []) |> Enum.map(&Json.canonical/1) |> Enum.sort()
    }
  end

  defp escape(segment), do: segment |> String.replace("~", "~0") |> String.replace("/", "~1")

  @doc "Follow a local `$ref` (parameters, request bodies, responses), at most a few hops."
  def resolve(document, obj, depth \\ 0) do
    ref = Json.get(obj, "$ref")

    cond do
      Json.dict?(obj) and is_binary(ref) and depth < 5 ->
        if not String.starts_with?(ref, "#/") or String.starts_with?(ref, @schema_refs) do
          obj
        else
          "#/" <> pointer = ref

          target =
            pointer
            |> String.split("/")
            |> Enum.reduce(document, fn part, target ->
              part =
                part |> Py.url_unquote() |> String.replace("~1", "/") |> String.replace("~0", "~")

              if Json.dict?(target), do: Json.get(target, part), else: nil
            end)

          resolve(document, target, depth + 1)
        end

      Json.dict?(obj) ->
        obj

      true ->
        {:o, []}
    end
  end

  defp schema_name(ref) when is_binary(ref) do
    Enum.find_value(@schema_refs, fn prefix ->
      if String.starts_with?(ref, prefix) do
        ref
        |> binary_part(byte_size(prefix), byte_size(ref) - byte_size(prefix))
        |> Py.url_unquote()
        |> String.replace("~1", "/")
        |> String.replace("~0", "~")
      end
    end)
  end

  defp schema_name(_), do: nil

  @doc """
  A compact type for a schema (`Pet`, `Pet[]`, `string`, `A|B`) and `refs` with the
  schema names it names added: `{type, refs}`.
  """
  def type(schema, refs) do
    if Json.dict?(schema), do: dict_type(schema, refs), else: {nil, refs}
  end

  defp dict_type(schema, refs) do
    case schema_name(Json.get(schema, "$ref")) do
      nil ->
        case Enum.find(~w(oneOf anyOf allOf), &is_list(Json.get(schema, &1))) do
          nil -> plain_type(schema, refs)
          combo -> combo_type(Json.get(schema, combo), refs)
        end

      name ->
        {name, MapSet.put(refs, name)}
    end
  end

  defp combo_type(list, refs) do
    {parts, refs} = Enum.map_reduce(list, refs, &type/2)

    joined =
      parts
      |> Enum.filter(&Py.truthy?/1)
      |> Enum.uniq()
      |> Enum.map(&join_part!/1)
      |> Enum.join("|")

    {if(joined == "", do: nil, else: joined), refs}
  end

  defp join_part!(s) when is_binary(s), do: s

  defp join_part!(other),
    do: raise(ArgumentError, "sequence item: expected str, got #{inspect(other)}")

  defp plain_type(schema, refs) do
    kind =
      case Json.get(schema, "type") do
        list when is_list(list) ->
          list |> Enum.reject(&(&1 == "null")) |> Enum.map(&join_part!/1) |> Enum.join("|")

        other ->
          other
      end

    if kind == "array" do
      {inner, refs} = type(Json.get(schema, "items"), refs)
      {if(Py.truthy?(inner), do: "#{Py.str(inner)}[]", else: "array"), refs}
    else
      kind =
        if not Py.truthy?(kind) and Py.truthy?(Json.get(schema, "properties")),
          do: "object",
          else: kind

      format = Json.get(schema, "format")

      if Py.truthy?(kind) and Py.truthy?(format),
        do: {"#{Py.str(kind)}:#{Py.str(format)}", refs},
        else: {kind, refs}
    end
  end

  defp scalar?(v),
    do: is_binary(v) or is_number(v) or is_boolean(v) or v in [:nan, :infinity, :neg_infinity]

  defp parameter(document, raw) do
    p = resolve(document, raw)
    schema = if Json.has?(p, "schema"), do: Json.get(p, "schema"), else: p
    {kind, _} = type(schema, MapSet.new())

    out = [
      {"name", Json.get(p, "name")},
      {"in", Json.get(p, "in")},
      {"required", Py.truthy?(Json.get(p, "required")) or Json.get(p, "in") == "path"},
      {"type", kind},
      {"description", Py.short(Json.get(p, "description"))}
    ]

    enum = if Json.dict?(schema), do: Json.get(schema, "enum"), else: nil

    out =
      if is_list(enum) and Enum.all?(enum, &scalar?/1),
        do: out ++ [{"enum", Enum.take(enum, @max_enum)}],
        else: out

    out =
      if Json.dict?(schema) and scalar?(Json.get(schema, "default")),
        do: out ++ [{"default", Json.get(schema, "default")}],
        else: out

    for {k, v} <- out, v not in [nil, ""], into: %{}, do: {k, v}
  end

  # Content types, and the type of the JSON (or else first) representation.
  defp content(content, refs) do
    if Json.dict?(content) and Py.truthy?(content) do
      types = Json.keys(content)
      chosen = Enum.find(types, hd(types), &(is_binary(&1) and json_type?(&1)))

      {kind, refs} =
        content |> Json.get(chosen) |> Py.py_or(%{}) |> Json.get("schema") |> type(refs)

      {types, kind, refs}
    else
      {[], nil, refs}
    end
  end

  # re.match(r"^application/(.+\+)?json", t)
  defp json_type?("application/" <> rest) do
    String.starts_with?(rest, "json") or
      case :binary.matches(rest, "+json") do
        [] ->
          false

        matches ->
          Enum.any?(matches, fn {pos, _} ->
            pos >= 1 and not String.contains?(binary_part(rest, 0, pos), "\n")
          end)
      end
  end

  defp json_type?(_), do: false

  defp operation(document, path, item, method, op) do
    raws =
      list_or_empty(Json.get(item, "parameters")) ++ list_or_empty(Json.get(op, "parameters"))

    # Operation parameters override path-level ones, keeping the first position.
    seen =
      Enum.reduce(raws, {[], %{}}, fn raw, {order, values} ->
        p = resolve(document, raw)
        key = {Json.plain(Json.get(p, "name")), Json.plain(Json.get(p, "in"))}
        order = if Map.has_key?(values, key), do: order, else: [key | order]
        {order, Map.put(values, key, raw)}
      end)

    {order, values} = seen

    {params, request, accepts} =
      order
      |> Enum.reverse()
      |> Enum.reduce({[], nil, MapSet.new()}, fn key, {params, request, accepts} ->
        raw = Map.fetch!(values, key)
        p = resolve(document, raw)

        if Json.get(p, "in") == "body" do
          consumes =
            Json.get(op, "consumes")
            |> Py.py_or(Json.get(document, "consumes"))
            |> Py.py_or(["application/json"])

          {kind, accepts} = type(Json.get(p, "schema"), accepts)

          request = [
            {"content_types", consumes},
            {"required", Py.truthy?(Json.get(p, "required"))},
            {"type", kind}
          ]

          {params, request, accepts}
        else
          {[parameter(document, raw) | params], request, accepts}
        end
      end)

    params = Enum.reverse(params)

    body = resolve(document, Json.get(op, "requestBody"))

    {request, accepts} =
      if Py.truthy?(body) do
        {types, kind, accepts} = content(Json.get(body, "content"), accepts)

        {[
           {"content_types", types},
           {"required", Py.truthy?(Json.get(body, "required"))},
           {"type", kind}
         ], accepts}
      else
        {request, accepts}
      end

    {responses, returns} =
      op
      |> Json.get("responses")
      |> Py.py_or(%{})
      |> Json.items()
      |> Enum.map_reduce(MapSet.new(), fn {status, raw}, returns ->
        r = resolve(document, raw)
        status = Py.str(status)
        ok = String.starts_with?(status, "2")
        sink = if ok, do: returns, else: MapSet.new()

        {kind, sink} =
          if Json.has?(r, "content") do
            {_, kind, sink} = content(Json.get(r, "content"), sink)
            {kind, sink}
          else
            type(Json.get(r, "schema"), sink)
          end

        response =
          for {k, v} <- [{"status", status}, {"type", kind}], Py.truthy?(v), into: %{}, do: {k, v}

        {response, if(ok, do: sink, else: returns)}
      end)

    summary = Json.get(op, "summary")
    description = Py.short(Json.get(op, "description"))

    node = %{
      "deprecated" => Py.truthy?(Json.get(op, "deprecated", false)),
      "kind" => "operation",
      "method" => method,
      "name" =>
        if(Json.has?(op, "operationId"),
          do: Json.get(op, "operationId"),
          else: "#{method} #{Py.str(path)}"
        ),
      "path" => path,
      "pointer" => "#/paths/#{escape(path)}/#{method}",
      "safe" => method in @safe_methods,
      "security" =>
        if(Json.has?(op, "security"),
          do: Json.get(op, "security"),
          else: Json.get(document, "security", [])
        ),
      "summary" => summary
    }

    node =
      if Py.truthy?(description) and description != Py.short(summary),
        do: Map.put(node, "description", description),
        else: node

    tags = Json.get(op, "tags")
    node = if Py.truthy?(tags), do: Map.put(node, "tags", tags), else: node
    node = if params != [], do: Map.put(node, "parameters", params), else: node

    node =
      if request,
        do:
          Map.put(
            node,
            "request",
            for({k, v} <- request, v not in [nil, []], into: %{}, do: {k, v})
          ),
        else: node

    node = if responses != [], do: Map.put(node, "responses", responses), else: node
    {node, accepts, returns}
  end

  defp list_or_empty(l) when is_list(l), do: l
  defp list_or_empty(_), do: []

  # Schema names a schema refers to, without following the references themselves.
  defp references(_, refs, depth) when depth > 40, do: refs

  defp references(schema, refs, depth) do
    cond do
      Json.dict?(schema) ->
        refs =
          case schema_name(Json.get(schema, "$ref")) do
            nil -> refs
            name -> MapSet.put(refs, name)
          end

        Enum.reduce(Json.items(schema), refs, fn {_, v}, refs ->
          references(v, refs, depth + 1)
        end)

      is_list(schema) ->
        Enum.reduce(schema, refs, &references(&1, &2, depth + 1))

      true ->
        refs
    end
  end
end
