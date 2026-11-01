defmodule Manifests.CatalogTools.Py do
  @moduledoc """
  The few pieces of Python semantics the catalog's generated files depend on, so the
  Elixir tools write byte-identical output to the original `tools/catalog.py`:
  `repr()`/`str()`, truthiness, `str.isspace()` whitespace, the `float` repr,
  code point lengths and `urllib.parse.unquote`.

  Values are decoded JSON as produced by `Manifests.CatalogTools.Json`: objects are
  `{:o, pairs}` (or plain maps for objects built in code), and `:nan`, `:infinity`
  and `:neg_infinity` stand for the non-finite floats Python's `json` accepts.
  """

  alias Manifests.CatalogTools.Json

  # --- Truthiness and str() ---------------------------------------------------

  @doc "Python truthiness."
  def truthy?(nil), do: false
  def truthy?(false), do: false
  def truthy?(""), do: false
  def truthy?([]), do: false
  def truthy?({:o, []}), do: false
  def truthy?(m) when is_map(m), do: map_size(m) > 0
  def truthy?(n) when is_number(n), do: n != 0
  def truthy?(_), do: true

  @doc "Python's `a or b`: the first truthy value, else the last one."
  def py_or(a, b), do: if(truthy?(a), do: a, else: b)

  @doc "`str(value)`, as an f-string interpolates it."
  def str(s) when is_binary(s), do: s
  def str(other), do: repr(other)

  @doc "`repr(value)` for the values JSON (or YAML) can produce."
  def repr(nil), do: "None"
  def repr(true), do: "True"
  def repr(false), do: "False"
  def repr(:nan), do: "nan"
  def repr(:infinity), do: "inf"
  def repr(:neg_infinity), do: "-inf"
  def repr(i) when is_integer(i), do: Integer.to_string(i)
  def repr(f) when is_float(f), do: float_repr(f)
  def repr(s) when is_binary(s), do: repr_string(s)
  def repr(l) when is_list(l), do: "[" <> Enum.map_join(l, ", ", &repr/1) <> "]"

  def repr({:o, _} = obj) do
    "{" <>
      Enum.map_join(Json.items(obj), ", ", fn {k, v} -> repr(k) <> ": " <> repr(v) end) <> "}"
  end

  def repr(m) when is_map(m), do: repr({:o, Json.items(m)})
  def repr(other), do: inspect(other)

  defp repr_string(s) do
    quote_char = if String.contains?(s, "'") and not String.contains?(s, "\""), do: ?", else: ?'
    body = for <<c::utf8 <- s>>, into: "", do: repr_char(c, quote_char)
    <<quote_char>> <> body <> <<quote_char>>
  end

  defp repr_char(c, c), do: <<?\\, c>>
  defp repr_char(?\\, _), do: "\\\\"
  defp repr_char(?\t, _), do: "\\t"
  defp repr_char(?\n, _), do: "\\n"
  defp repr_char(?\r, _), do: "\\r"
  defp repr_char(c, _) when c < 0x20 or c == 0x7F, do: "\\x" <> hex(c, 2)
  defp repr_char(c, _) when c < 0x7F, do: <<c>>

  defp repr_char(c, _) do
    cond do
      printable?(c) -> <<c::utf8>>
      c <= 0xFF -> "\\x" <> hex(c, 2)
      c <= 0xFFFF -> "\\u" <> hex(c, 4)
      true -> "\\U" <> hex(c, 8)
    end
  end

  # str.isprintable(): everything but the Other and Separator categories (space aside).
  defp printable?(c) do
    not Regex.match?(regex(:unprintable), <<c::utf8>>)
  end

  defp hex(c, width),
    do: c |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")

  # --- Floats -----------------------------------------------------------------

  @doc """
  Python's `repr(float)`: the shortest round-tripping digits, in fixed notation
  when the decimal exponent is in -4..16 and in `1e+16` notation otherwise.
  """
  def float_repr(f) when is_float(f) do
    {negative, text} =
      case :erlang.float_to_binary(f, [:short]) do
        "-" <> rest -> {true, rest}
        rest -> {false, rest}
      end

    {mantissa, exp} =
      case String.split(text, ["e", "E"]) do
        [m, e] -> {m, String.to_integer(e)}
        [m] -> {m, 0}
      end

    {int_part, frac_part} =
      case String.split(mantissa, ".") do
        [i, fr] -> {i, fr}
        [i] -> {i, ""}
      end

    {digits, decpt} = strip_leading_zeros(int_part <> frac_part, byte_size(int_part) + exp)
    digits = String.trim_trailing(digits, "0")
    sign = if negative, do: "-", else: ""

    if digits == "" do
      sign <> "0.0"
    else
      sign <> format_digits(digits, decpt)
    end
  end

  defp strip_leading_zeros("0" <> rest, decpt), do: strip_leading_zeros(rest, decpt - 1)
  defp strip_leading_zeros(digits, decpt), do: {digits, decpt}

  defp format_digits(digits, decpt) do
    n = byte_size(digits)

    cond do
      decpt <= -4 or decpt > 16 ->
        <<first::binary-size(1), rest::binary>> = digits
        mantissa = if rest == "", do: first, else: first <> "." <> rest
        e = decpt - 1
        esign = if e < 0, do: "-", else: "+"
        mantissa <> "e" <> esign <> String.pad_leading(Integer.to_string(abs(e)), 2, "0")

      decpt <= 0 ->
        "0." <> String.duplicate("0", -decpt) <> digits

      decpt >= n ->
        digits <> String.duplicate("0", decpt - n) <> ".0"

      true ->
        <<a::binary-size(decpt), b::binary>> = digits
        a <> "." <> b
    end
  end

  # --- Whitespace and text ----------------------------------------------------

  @doc "Python's `str.isspace()` for one code point (what `\\s` and `strip()` use)."
  def space?(c) when c in [9, 10, 11, 12, 13, 28, 29, 30, 31, 32, 0x85, 0xA0, 0x1680], do: true
  def space?(c) when c in 0x2000..0x200A, do: true
  def space?(c) when c in [0x2028, 0x2029, 0x202F, 0x205F, 0x3000], do: true
  def space?(_), do: false

  @doc "`re.sub(r\"\\s+\", \" \", text)`."
  def collapse_ws(text), do: text |> collapse(false, []) |> IO.iodata_to_binary()

  defp collapse(<<c::utf8, rest::binary>>, in_space, acc) do
    cond do
      not space?(c) -> collapse(rest, false, [acc, <<c::utf8>>])
      in_space -> collapse(rest, true, acc)
      true -> collapse(rest, true, [acc, ?\s])
    end
  end

  defp collapse(<<>>, _, acc), do: acc

  @doc "`str.strip()`."
  def strip(text), do: text |> lstrip() |> rstrip()

  @doc "`str.lstrip()`."
  def lstrip(<<c::utf8, rest::binary>> = text) do
    if space?(c), do: lstrip(rest), else: text
  end

  def lstrip(<<>>), do: <<>>

  @doc "`str.rstrip()`."
  def rstrip(text), do: binary_part(text, 0, content_end(text, 0, 0))

  defp content_end(<<c::utf8, rest::binary>> = text, offset, last) do
    size = byte_size(text) - byte_size(rest)
    last = if space?(c), do: last, else: offset + size
    content_end(rest, offset + size, last)
  end

  defp content_end(<<>>, _, last), do: last

  @doc "`len(text)`: code points, not graphemes."
  def cp_len(text), do: cp_len(text, 0)
  defp cp_len(<<_::utf8, rest::binary>>, n), do: cp_len(rest, n + 1)
  defp cp_len(<<>>, n), do: n

  @doc "`text[:n]` in code points."
  def cp_take(text, n), do: binary_part(text, 0, cp_offset(text, n, 0))

  defp cp_offset(_, 0, offset), do: offset
  defp cp_offset(<<>>, _, offset), do: offset

  defp cp_offset(<<_::utf8, rest::binary>> = text, n, offset),
    do: cp_offset(rest, n - 1, offset + byte_size(text) - byte_size(rest))

  @doc """
  The first sentence of a description, whitespace collapsed, at most `limit` code
  points (`_short` in the Python tool).
  """
  def short(text, limit \\ 160)

  def short(text, limit) when is_binary(text) do
    text = text |> collapse_ws() |> strip()

    case first_sentence(text, 0, 0) do
      nil -> truncate(text, limit)
      len -> if len <= limit, do: cp_take(text, len), else: truncate(text, limit)
    end
  end

  def short(_, _), do: nil

  defp truncate(text, limit) do
    if cp_len(text) <= limit, do: text, else: rstrip(cp_take(text, limit - 1)) <> "…"
  end

  # `(.+?[.!?])(\s|$)` on collapsed text: the shortest prefix of at least two code
  # points that ends in . ! or ? followed by a space or the end.
  defp first_sentence(<<c::utf8, rest::binary>>, index, _)
       when c in [?., ?!, ??] and index >= 1 do
    case rest do
      <<>> -> index + 1
      <<?\s, _::binary>> -> index + 1
      _ -> first_sentence(rest, index + 1, nil)
    end
  end

  defp first_sentence(<<_::utf8, rest::binary>>, index, acc),
    do: first_sentence(rest, index + 1, acc)

  defp first_sentence(<<>>, _, _), do: nil

  # --- urllib.parse.unquote ---------------------------------------------------

  @doc "`urllib.parse.unquote(text)`: percent-decoding as UTF-8 with replacement."
  def url_unquote(text) when is_binary(text) do
    if String.contains?(text, "%") do
      text
      |> ascii_runs([])
      |> Enum.map(fn
        {:ascii, run} -> run |> percent_bytes() |> utf8_replace([])
        {:other, run} -> run
      end)
      |> IO.iodata_to_binary()
    else
      text
    end
  end

  defp ascii_runs(<<>>, acc), do: Enum.reverse(acc)

  defp ascii_runs(<<c, rest::binary>>, [{:ascii, run} | acc]) when c < 0x80,
    do: ascii_runs(rest, [{:ascii, <<run::binary, c>>} | acc])

  defp ascii_runs(<<c, rest::binary>>, acc) when c < 0x80,
    do: ascii_runs(rest, [{:ascii, <<c>>} | acc])

  defp ascii_runs(<<c::utf8, rest::binary>>, [{:other, run} | acc]),
    do: ascii_runs(rest, [{:other, <<run::binary, c::utf8>>} | acc])

  defp ascii_runs(<<c::utf8, rest::binary>>, acc),
    do: ascii_runs(rest, [{:other, <<c::utf8>>} | acc])

  defp percent_bytes(run) do
    Regex.replace(~r/%([0-9a-fA-F]{2})/, run, fn _, h -> <<String.to_integer(h, 16)>> end)
  end

  defp utf8_replace(<<>>, acc), do: IO.iodata_to_binary(Enum.reverse(acc))
  defp utf8_replace(<<c::utf8, rest::binary>>, acc), do: utf8_replace(rest, [<<c::utf8>> | acc])

  defp utf8_replace(bin, acc) do
    n = maximal_subpart(bin)
    <<_::binary-size(n), rest::binary>> = bin
    utf8_replace(rest, ["\uFFFD" | acc])
  end

  # Length of the invalid sequence the UTF-8 decoder replaces with one U+FFFD.
  defp maximal_subpart(<<b0, rest::binary>>) do
    {len, second} =
      cond do
        b0 in 0xC2..0xDF -> {2, 0x80..0xBF}
        b0 == 0xE0 -> {3, 0xA0..0xBF}
        b0 in 0xE1..0xEC or b0 in 0xEE..0xEF -> {3, 0x80..0xBF}
        b0 == 0xED -> {3, 0x80..0x9F}
        b0 == 0xF0 -> {4, 0x90..0xBF}
        b0 in 0xF1..0xF3 -> {4, 0x80..0xBF}
        b0 == 0xF4 -> {4, 0x80..0x8F}
        true -> {1, nil}
      end

    if len == 1, do: 1, else: 1 + continuation(rest, len - 1, second)
  end

  defp continuation(<<b, rest::binary>>, left, range) when left > 0 do
    if b in range, do: 1 + continuation(rest, left - 1, 0x80..0xBF), else: 0
  end

  defp continuation(_, _, _), do: 0

  # --- Regexes ----------------------------------------------------------------

  @doc false
  def regex(name) do
    key = {__MODULE__, :regex, name}

    case :persistent_term.get(key, nil) do
      nil ->
        compiled = Regex.compile!(regex_source(name), "u")
        :persistent_term.put(key, compiled)
        compiled

      compiled ->
        compiled
    end
  end

  defp regex_source(:unprintable),
    do: "[\\p{Cc}\\p{Cf}\\p{Cs}\\p{Co}\\p{Cn}\\p{Zl}\\p{Zp}\\p{Zs}]"
end
