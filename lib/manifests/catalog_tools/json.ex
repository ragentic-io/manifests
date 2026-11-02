defmodule Manifests.CatalogTools.Json do
  @moduledoc """
  JSON with the semantics of Python's `json` module, which the catalog's files were
  written with.

  Decoding keeps object key order, because the operation graph follows the order of
  the embedded OpenAPI document: an object decodes to `{:o, [{key, value}]}`, with
  duplicate keys resolved like a Python `dict` (first position, last value). `NaN`,
  `Infinity` and `-Infinity` decode to `:nan`, `:infinity` and `:neg_infinity`.
  Errors carry Python's messages, e.g. `Expecting value: line 1 column 1 (char 0)`.

  Encoding writes what `json.dumps(..., ensure_ascii=False)` writes:

    * `pretty/1`: `indent=2, sort_keys=True` plus a newline (`manifest.json`)
    * `canonical/1`: `sort_keys=True, separators=(",", ":")` (signed payloads)
    * `compact/1`: `separators=(",", ":")`, insertion order (envelopes)
    * `dumps/1`: the defaults, insertion order (front matter values)

  Objects built in code may be plain maps; they are always written in key order.
  """

  alias Manifests.CatalogTools.{Error, Py}

  # --- Decoding ---------------------------------------------------------------

  @doc "`json.loads(text)` for a str."
  def decode!(<<0xEF, 0xBB, 0xBF, _::binary>> = text),
    do: fail("Unexpected UTF-8 BOM (decode using utf-8-sig)", text, 0)

  def decode!(text) when is_binary(text) do
    case fast_decode(text) do
      {:ok, value} -> value
      :error -> slow_decode!(text)
    end
  end

  # OTP's :json does the work for well-formed input, building ordered objects; the
  # decoder below handles what it rejects: Python's NaN/Infinity, out-of-range
  # floats, and Python's error messages.
  defp fast_decode(text) do
    decoders = %{null: nil, object_finish: &finish_object/2}
    {value, :ok, rest} = :json.decode(text, :ok, decoders)
    if ws(rest) == <<>>, do: {:ok, value}, else: :error
  catch
    _, _ -> :error
  end

  defp finish_object(acc, old), do: {{:o, finish_pairs(acc)}, old}

  defp slow_decode!(text) do
    unless String.valid?(text),
      do: raise(Error, "'utf-8' codec can't decode the JSON text: invalid UTF-8")

    {value, rest} = value(ws(text), text)

    case ws(rest) do
      <<>> -> value
      extra -> fail("Extra data", text, extra)
    end
  end

  @doc "`json.loads(data)` for bytes: a UTF-8 BOM is dropped first."
  def decode_bytes!(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: decode!(rest)
  def decode_bytes!(data), do: decode!(data)

  defp ws(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\r], do: ws(rest)
  defp ws(rest), do: rest

  defp value(<<?", rest::binary>> = s, orig), do: string(rest, orig, s, [])
  defp value(<<?{, rest::binary>>, orig), do: object_start(ws(rest), orig)
  defp value(<<?[, rest::binary>>, orig), do: array_start(ws(rest), orig)
  defp value(<<"null", rest::binary>>, _), do: {nil, rest}
  defp value(<<"true", rest::binary>>, _), do: {true, rest}
  defp value(<<"false", rest::binary>>, _), do: {false, rest}
  defp value(<<"NaN", rest::binary>>, _), do: {:nan, rest}
  defp value(<<"Infinity", rest::binary>>, _), do: {:infinity, rest}
  defp value(<<"-Infinity", rest::binary>>, _), do: {:neg_infinity, rest}
  defp value(s, orig), do: number(s, orig)

  defp object_start(<<?}, rest::binary>>, _), do: {{:o, []}, rest}
  defp object_start(s, orig), do: member(s, orig, [])

  defp member(<<?", rest::binary>> = s, orig, acc) do
    {key, rest} = string(rest, orig, s, [])

    case ws(rest) do
      <<?:, rest::binary>> ->
        {val, rest} = value(ws(rest), orig)
        acc = [{key, val} | acc]

        case ws(rest) do
          <<?}, rest::binary>> ->
            {{:o, finish_pairs(acc)}, rest}

          <<?,, after_comma::binary>> = comma ->
            case ws(after_comma) do
              <<?}, _::binary>> ->
                fail("Illegal trailing comma before end of object", orig, comma)

              next ->
                member(next, orig, acc)
            end

          other ->
            fail("Expecting ',' delimiter", orig, other)
        end

      other ->
        fail("Expecting ':' delimiter", orig, other)
    end
  end

  defp member(s, orig, _), do: fail("Expecting property name enclosed in double quotes", orig, s)

  defp finish_pairs([]), do: []
  defp finish_pairs([_] = acc), do: acc

  defp finish_pairs(acc) do
    pairs = :lists.reverse(acc)
    last = Map.new(pairs)

    if map_size(last) == length(pairs) do
      pairs
    else
      pairs |> Enum.uniq_by(&elem(&1, 0)) |> Enum.map(fn {k, _} -> {k, Map.fetch!(last, k)} end)
    end
  end

  defp array_start(<<?], rest::binary>>, _), do: {[], rest}
  defp array_start(s, orig), do: items(s, orig, [])

  defp items(s, orig, acc) do
    {val, rest} = value(s, orig)
    acc = [val | acc]

    case ws(rest) do
      <<?], rest::binary>> ->
        {:lists.reverse(acc), rest}

      <<?,, after_comma::binary>> = comma ->
        case ws(after_comma) do
          <<?], _::binary>> -> fail("Illegal trailing comma before end of array", orig, comma)
          next -> items(next, orig, acc)
        end

      other ->
        fail("Expecting ',' delimiter", orig, other)
    end
  end

  defp string(s, orig, quote, acc) do
    n = plain_len(s, 0)
    <<chunk::binary-size(^n), rest::binary>> = s
    acc = [acc | chunk]

    case rest do
      <<?", rest::binary>> -> {IO.iodata_to_binary(acc), rest}
      <<?\\, rest::binary>> -> escape(rest, orig, quote, acc)
      <<>> -> fail("Unterminated string starting at", orig, quote)
      _control -> fail("Invalid control character at", orig, rest)
    end
  end

  defp plain_len(<<c, rest::binary>>, n) when c != ?" and c != ?\\ and c >= 0x20,
    do: plain_len(rest, n + 1)

  defp plain_len(_, n), do: n

  @escapes %{
    ?" => ?",
    ?\\ => ?\\,
    ?/ => ?/,
    ?b => ?\b,
    ?f => ?\f,
    ?n => ?\n,
    ?r => ?\r,
    ?t => ?\t
  }

  defp escape(<<>>, orig, quote, _), do: fail("Unterminated string starting at", orig, quote)

  defp escape(<<?u, rest::binary>> = u, orig, quote, acc) do
    case rest do
      <<h::binary-size(4), _::binary-size(1), _::binary>> ->
        c = hex4!(h, orig, u)
        <<_::binary-size(4), rest::binary>> = rest

        cond do
          c in 0xD800..0xDBFF ->
            case rest do
              <<?\\, ?u, h2::binary-size(4), _::binary-size(1), _::binary>> ->
                <<_, u2::binary>> = rest
                c2 = hex4!(h2, orig, u2)

                if c2 in 0xDC00..0xDFFF do
                  <<_::binary-size(6), rest::binary>> = rest
                  joined = 0x10000 + Bitwise.bsl(c - 0xD800, 10) + (c2 - 0xDC00)
                  string(rest, orig, quote, [acc | <<joined::utf8>>])
                else
                  lone_surrogate(orig, u)
                end

              _ ->
                lone_surrogate(orig, u)
            end

          c in 0xDC00..0xDFFF ->
            lone_surrogate(orig, u)

          true ->
            string(rest, orig, quote, [acc | <<c::utf8>>])
        end

      _ ->
        fail("Invalid \\uXXXX escape", orig, u)
    end
  end

  defp escape(<<c, rest::binary>> = s, orig, quote, acc) do
    case @escapes do
      %{^c => char} -> string(rest, orig, quote, [acc, char])
      _ -> fail("Invalid \\escape", orig, byte_size(orig) - byte_size(s) - 1)
    end
  end

  defp hex4!(h, orig, at) do
    if h =~ ~r/\A[0-9a-fA-F]{4}\z/,
      do: String.to_integer(h, 16),
      else: fail("Invalid \\uXXXX escape", orig, at)
  end

  # Python keeps lone surrogates in a str; they cannot be written back as UTF-8.
  defp lone_surrogate(orig, at),
    do: fail("Lone surrogate \\uXXXX escape is not supported", orig, at)

  defp number(s, orig) do
    {negative, unsigned} =
      case s do
        <<?-, r::binary>> -> {true, r}
        _ -> {false, s}
      end

    {int, rest} =
      case unsigned do
        <<?0, r::binary>> -> {"0", r}
        <<c, _::binary>> when c in ?1..?9 -> digits(unsigned)
        _ -> fail("Expecting value", orig, s)
      end

    {frac, rest} =
      case rest do
        <<?., c, _::binary>> when c in ?0..?9 ->
          <<?., r::binary>> = rest
          digits(r)

        _ ->
          {nil, rest}
      end

    {exp, rest} =
      case rest do
        <<e, r::binary>> when e in [?e, ?E] ->
          {sign, r} =
            case r do
              <<sg, r2::binary>> when sg in [?+, ?-] -> {<<sg>>, r2}
              _ -> {"", r}
            end

          case r do
            <<c, _::binary>> when c in ?0..?9 ->
              {d, r} = digits(r)
              {sign <> d, r}

            _ ->
              {nil, rest}
          end

        _ ->
          {nil, rest}
      end

    value =
      if is_nil(frac) and is_nil(exp) do
        i = String.to_integer(int)
        if negative, do: -i, else: i
      else
        to_float(negative, int, frac || "0", exp || "0")
      end

    {value, rest}
  end

  defp digits(s) do
    n = count_digits(s, 0)
    <<d::binary-size(^n), rest::binary>> = s
    {d, rest}
  end

  defp count_digits(<<c, rest::binary>>, n) when c in ?0..?9, do: count_digits(rest, n + 1)
  defp count_digits(_, n), do: n

  defp to_float(negative, int, frac, exp) do
    f =
      try do
        :erlang.binary_to_float(int <> "." <> frac <> "e" <> exp)
      rescue
        ArgumentError -> if String.starts_with?(exp, "-"), do: 0.0, else: :infinity
      end

    cond do
      not negative -> f
      f == :infinity -> :neg_infinity
      true -> -f
    end
  end

  defp fail(msg, orig, rest) when is_binary(rest),
    do: fail(msg, orig, byte_size(orig) - byte_size(rest))

  defp fail(msg, orig, byte_pos) do
    prefix = binary_part(orig, 0, byte_pos)
    pos = Py.cp_len(prefix)

    {line, col} =
      case :binary.matches(prefix, "\n") do
        [] ->
          {1, pos + 1}

        newlines ->
          {last, _} = List.last(newlines)
          {length(newlines) + 1, pos - Py.cp_len(binary_part(prefix, 0, last))}
      end

    raise Error, "#{msg}: line #{line} column #{col} (char #{pos})"
  end

  # --- Encoding ---------------------------------------------------------------

  @doc "`json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=False) + \"\\n\"`."
  def pretty(term), do: IO.iodata_to_binary([enc(term, {true, 2, ",", ": "}, 0), ?\n])

  @doc "`json.dumps(obj, sort_keys=True, separators=(\",\", \":\"), ensure_ascii=False)`."
  def canonical(term), do: IO.iodata_to_binary(enc(term, {true, nil, ",", ":"}, 0))

  @doc "`json.dumps(obj, separators=(\",\", \":\"), ensure_ascii=False)`."
  def compact(term), do: IO.iodata_to_binary(enc(term, {false, nil, ",", ":"}, 0))

  @doc "`json.dumps(obj, ensure_ascii=False)`."
  def dumps(term), do: IO.iodata_to_binary(enc(term, {false, nil, ", ", ": "}, 0))

  defp enc(nil, _, _), do: "null"
  defp enc(true, _, _), do: "true"
  defp enc(false, _, _), do: "false"
  defp enc(:nan, _, _), do: "NaN"
  defp enc(:infinity, _, _), do: "Infinity"
  defp enc(:neg_infinity, _, _), do: "-Infinity"
  defp enc(s, _, _) when is_binary(s), do: [?", escape_string(s), ?"]
  defp enc(i, _, _) when is_integer(i), do: Integer.to_string(i)
  defp enc(f, _, _) when is_float(f), do: Py.float_repr(f)
  defp enc([], _, _), do: "[]"

  defp enc(list, {_, nil, item, _} = opts, level) when is_list(list),
    do: [?[, Enum.map_intersperse(list, item, &enc(&1, opts, level)), ?]]

  defp enc(list, {_, indent, item, _} = opts, level) when is_list(list) do
    inner = ["\n" | String.duplicate(" ", indent * (level + 1))]

    [
      ?[,
      inner,
      Enum.map_intersperse(list, [item | inner], &enc(&1, opts, level + 1)),
      ?\n,
      String.duplicate(" ", indent * level),
      ?]
    ]
  end

  defp enc({:o, pairs}, {sort, _, _, _} = opts, level),
    do: enc_object(if(sort, do: sort_pairs(pairs), else: pairs), opts, level)

  defp enc(map, opts, level) when is_map(map),
    do: enc_object(sort_pairs(Map.to_list(map)), opts, level)

  defp enc({:py_unencodable, type}, _, _),
    do: raise(Error, "Object of type #{type} is not JSON serializable")

  defp enc(other, _, _), do: raise(Error, "Object #{inspect(other)} is not JSON serializable")

  defp enc_object([], _, _), do: "{}"

  defp enc_object(pairs, {_, nil, item, key_sep} = opts, level) do
    [?{, Enum.map_intersperse(pairs, item, &enc_pair(&1, key_sep, opts, level)), ?}]
  end

  defp enc_object(pairs, {_, indent, item, key_sep} = opts, level) do
    inner = ["\n" | String.duplicate(" ", indent * (level + 1))]

    [
      ?{,
      inner,
      Enum.map_intersperse(pairs, [item | inner], &enc_pair(&1, key_sep, opts, level + 1)),
      ?\n,
      String.duplicate(" ", indent * level),
      ?}
    ]
  end

  defp enc_pair({k, v}, key_sep, opts, level),
    do: [?", escape_string(key(k)), ?", key_sep, enc(v, opts, level)]

  # json.dumps converts these key types to strings; anything else is a TypeError.
  defp key(k) when is_binary(k), do: k
  defp key(true), do: "true"
  defp key(false), do: "false"
  defp key(nil), do: "null"
  defp key(k) when is_integer(k), do: Integer.to_string(k)
  defp key(k) when is_float(k), do: Py.float_repr(k)
  defp key(:nan), do: "NaN"
  defp key(:infinity), do: "Infinity"
  defp key(:neg_infinity), do: "-Infinity"
  defp key(k), do: raise(Error, "keys must be str, int, float, bool or None, not #{inspect(k)}")

  # sorted(dct.items()): str keys sort by code point (= UTF-8 byte order); numbers
  # (and bools) sort among themselves; mixing the two is a TypeError in Python.
  defp sort_pairs([]), do: []
  defp sort_pairs([_] = pairs), do: pairs

  defp sort_pairs(pairs) do
    cond do
      Enum.all?(pairs, fn {k, _} -> is_binary(k) end) ->
        Enum.sort_by(pairs, &elem(&1, 0))

      Enum.all?(pairs, fn {k, _} -> is_number(k) or is_boolean(k) end) ->
        Enum.sort_by(pairs, fn {k, _} -> number_key(k) end)

      true ->
        raise Error, "'<' not supported between instances of mixed key types"
    end
  end

  defp number_key(true), do: 1
  defp number_key(false), do: 0
  defp number_key(n), do: n

  defp escape_string(s) do
    if :binary.match(s, escape_pattern()) == :nomatch, do: s, else: escape_string(s, s, 0, 0, [])
  end

  defp escape_pattern do
    case :persistent_term.get({__MODULE__, :escape}, nil) do
      nil ->
        pattern = :binary.compile_pattern([<<?">>, <<?\\>> | for(c <- 0..0x1F, do: <<c>>)])
        :persistent_term.put({__MODULE__, :escape}, pattern)
        pattern

      pattern ->
        pattern
    end
  end

  defp escape_string(<<>>, orig, start, len, acc), do: [acc | binary_part(orig, start, len)]

  defp escape_string(<<c, rest::binary>>, orig, start, len, acc)
       when c < 0x20 or c == ?" or c == ?\\ do
    acc = [acc, binary_part(orig, start, len) | escape_char(c)]
    escape_string(rest, orig, start + len + 1, 0, acc)
  end

  defp escape_string(<<_, rest::binary>>, orig, start, len, acc),
    do: escape_string(rest, orig, start, len + 1, acc)

  defp escape_char(?"), do: "\\\""
  defp escape_char(?\\), do: "\\\\"
  defp escape_char(?\n), do: "\\n"
  defp escape_char(?\r), do: "\\r"
  defp escape_char(?\t), do: "\\t"
  defp escape_char(?\b), do: "\\b"
  defp escape_char(?\f), do: "\\f"

  defp escape_char(c),
    do: "\\u" <> (c |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0"))

  # --- Access -----------------------------------------------------------------

  @doc "Whether a value is a JSON object (`isinstance(x, dict)`)."
  def dict?({:o, _}), do: true
  def dict?(m) when is_map(m), do: true
  def dict?(_), do: false

  @doc "`obj.get(key, default)`; `default` for anything that isn't an object."
  def get(obj, key, default \\ nil)

  def get({:o, pairs}, key, default) do
    case find(pairs, key) do
      {:ok, v} -> v
      :error -> default
    end
  end

  def get(m, key, default) when is_map(m), do: Map.get(m, key, default)
  def get(_, _, default), do: default

  defp find([{k, v} | _], key) when k == key, do: {:ok, v}
  defp find([_ | rest], key), do: find(rest, key)
  defp find([], _), do: :error

  @doc "`obj[key]`, raising `KeyError` like Python."
  def fetch!(obj, key) do
    case has?(obj, key) do
      true -> get(obj, key)
      false -> raise KeyError, key: key, term: obj
    end
  end

  @doc "`key in obj`."
  def has?({:o, pairs}, key), do: find(pairs, key) != :error
  def has?(m, key) when is_map(m), do: Map.has_key?(m, key)
  def has?(_, _), do: false

  @doc "`obj[key] = value`, keeping the key's position."
  def put({:o, pairs}, key, value) do
    if has?({:o, pairs}, key),
      do: {:o, Enum.map(pairs, fn {k, v} -> if k == key, do: {k, value}, else: {k, v} end)},
      else: {:o, pairs ++ [{key, value}]}
  end

  def put(m, key, value) when is_map(m), do: Map.put(m, key, value)

  @doc "`obj.items()` in order (maps in key order); `[]` for non-objects."
  def items({:o, pairs}), do: pairs
  def items(m) when is_map(m), do: m |> Map.to_list() |> Enum.sort_by(&elem(&1, 0))
  def items(_), do: []

  @doc "`list(obj)`: the keys in order."
  def keys(obj), do: Enum.map(items(obj), &elem(&1, 0))

  @doc "The object without `key`."
  def delete({:o, pairs}, key), do: {:o, Enum.reject(pairs, fn {k, _} -> k == key end)}
  def delete(m, key) when is_map(m), do: Map.delete(m, key)

  @doc "Plain maps all the way down, for Python's order-insensitive `==` on dicts."
  def plain({:o, pairs}), do: Map.new(pairs, fn {k, v} -> {k, plain(v)} end)
  def plain(m) when is_map(m), do: Map.new(m, fn {k, v} -> {k, plain(v)} end)
  def plain(l) when is_list(l), do: Enum.map(l, &plain/1)
  def plain(other), do: other

  @doc "Python `==` on decoded JSON values."
  def eq?(a, b), do: plain(a) == plain(b)
end
