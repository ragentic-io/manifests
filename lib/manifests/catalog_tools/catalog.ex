defmodule Manifests.CatalogTools.Catalog do
  @moduledoc """
  The catalog on disk: its sources (`apps/<id>/manifest.json` and `MANIFEST.md`), its
  configuration (`registry.json`, `categories.json`) and its signed objects
  (`index.json`, `browse-index.json`, `bundles/`, `browse-bundles/`, `sources.json`).

  A port of the shared parts of `tools/catalog.py`. Every function takes the catalog
  struct, whose `root` is the catalog directory (`catalog/` in this repository).
  """

  alias Manifests.CatalogTools.{Docs, Error, Json, Py, Trust}

  defstruct [:root]

  @type t :: %__MODULE__{root: String.t()}

  @max_categories 4
  @max_payload 16_777_216
  @protocols ~w(openapi graphql asyncapi)
  @not_connectable ~w(discovered preview_only)
  # The registry server rejects the whole browse index if any entry has another readiness.
  @draft_readiness ~w(discovered source_reviewed)
  # Catalog name in MANIFEST.md -> {index file, bundle directory, index kind}, in order.
  @catalogs [
    {"published", {"index.json", "bundles", "index"}},
    {"drafts", {"browse-index.json", "browse-bundles", "browse_index"}}
  ]

  def max_categories, do: @max_categories
  def max_payload, do: @max_payload
  def protocols, do: @protocols
  def not_connectable, do: @not_connectable
  def draft_readiness, do: @draft_readiness

  @doc "`[{catalog, {index file, bundle directory, kind}}]` in the Python tool's order."
  def catalogs, do: @catalogs
  def catalog_names, do: Enum.map(@catalogs, &elem(&1, 0))
  def catalog!(name), do: @catalogs |> List.keyfind!(name, 0) |> elem(1)

  @doc "A catalog rooted at `root` (expanded to an absolute path)."
  def new(root), do: %__MODULE__{root: Path.expand(root)}

  def path(%__MODULE__{root: root}, rel), do: Path.join(root, rel)
  def apps_dir(c), do: path(c, "apps")

  # --- Files ------------------------------------------------------------------

  @doc """
  `Path.read_text()`: UTF-8 with universal newlines. Failures raise `Error` with the
  message Python's `OSError`/`UnicodeDecodeError` would have.
  """
  def read_text!(path) do
    text = read_bytes!(path)

    unless String.valid?(text),
      do: raise(Error, "'utf-8' codec can't decode bytes in #{Py.repr(path)}: invalid UTF-8")

    if :binary.match(text, "\r") == :nomatch,
      do: text,
      else: text |> String.replace("\r\n", "\n") |> String.replace("\r", "\n")
  end

  def read_bytes!(path) do
    case File.read(path) do
      {:ok, bytes} -> bytes
      {:error, reason} -> raise Error, os_error(reason, path)
    end
  end

  defp os_error(reason, path) do
    {errno, text} =
      case reason do
        :enoent -> {2, "No such file or directory"}
        :eacces -> {13, "Permission denied"}
        :enotdir -> {20, "Not a directory"}
        :eisdir -> {21, "Is a directory"}
        other -> {0, :file.format_error(other) |> to_string()}
      end

    "[Errno #{errno}] #{text}: #{Py.repr(path)}"
  end

  def write!(path, text), do: File.write!(path, text)

  def read_json!(path), do: path |> read_text!() |> Json.decode!()

  def config(c), do: read_json!(path(c, "registry.json"))

  @doc "Category id -> category, in `categories.json` order (`{:o, pairs}`)."
  def categories(c) do
    list = read_json!(path(c, "categories.json"))
    pairs = Enum.map(list, &{Json.fetch!(&1, "id"), &1})
    {:o, dedupe(pairs)}
  end

  defp dedupe(pairs) do
    last = Map.new(pairs)
    pairs |> Enum.uniq_by(&elem(&1, 0)) |> Enum.map(fn {k, _} -> {k, Map.fetch!(last, k)} end)
  end

  @doc "`Enum.map/2` across all schedulers, keeping order (the catalog's files are independent)."
  # Exceptions are re-raised in the caller, so they surface exactly as in a plain map.
  def pmap(enumerable, fun), do: enumerable |> pstream(fun) |> Enum.to_list()

  @doc "A lazy, ordered `pmap/2`: at most one result per scheduler is held at a time."
  def pstream(enumerable, fun) do
    enumerable
    |> Task.async_stream(
      fn x ->
        try do
          {:ok, fun.(x)}
        rescue
          e -> {:raise, e, __STACKTRACE__}
        end
      end,
      ordered: true,
      timeout: :infinity,
      max_concurrency: System.schedulers_online()
    )
    |> Stream.map(fn
      {:ok, {:ok, value}} -> value
      {:ok, {:raise, e, stacktrace}} -> reraise e, stacktrace
    end)
  end

  def iso(ts) when is_integer(ts) do
    ts |> DateTime.from_unix!() |> Calendar.strftime("%Y-%m-%d %H:%M UTC")
  end

  # --- Signed objects -----------------------------------------------------------

  @doc "`{envelope, index payload}` of a catalog's index, or `{nil, nil}`."
  def read_index(c, catalog) do
    {name, _, _} = catalog!(catalog)
    file = path(c, name)

    if File.exists?(file) do
      env = read_json!(file)
      {env, env |> Json.fetch!("payload") |> Trust.b64d() |> Json.decode_bytes!()}
    else
      {nil, nil}
    end
  end

  def bundle_path(c, catalog, digest) do
    {_, dir, _} = catalog!(catalog)
    path(c, Path.join(dir, "#{Py.str(digest)}.json"))
  end

  @doc "The payload bytes of a bundle (not verified)."
  def bundle_data(c, catalog, digest) do
    c
    |> bundle_path(catalog, digest)
    |> read_json!()
    |> Json.fetch!("envelope")
    |> Json.fetch!("payload")
    |> Trust.b64d()
  end

  def bundle_payload(c, catalog, digest),
    do: c |> bundle_data(catalog, digest) |> Json.decode_bytes!()

  @doc """
  `{state, order}`: id -> `%{catalog, entry, data, expires}` for every application
  in a signed index, and catalog -> ids in index order.

  The Python tool kept each decoded bundle payload; here a payload is kept as its
  signed bytes (`data`), which are its canonical JSON, and decoded only when needed
  (`signed_payload/1`, `same_payload?/2`). That keeps a full catalog in memory cheaply.
  """
  def signed_state(c) do
    Enum.reduce(catalog_names(), {%{}, %{}}, fn catalog, {state, order} ->
      {_, index} = read_index(c, catalog)
      entries = Json.get(Py.py_or(index, %{}), "entries", [])

      loaded =
        pmap(entries, fn entry ->
          id = Json.fetch!(entry, "id")
          data = bundle_data(c, catalog, Json.fetch!(entry, "digest"))
          expires = data |> Json.decode_bytes!() |> Json.get("expires", 0)
          {id, %{catalog: catalog, entry: entry, data: data, expires: expires}}
        end)

      {Map.merge(state, Map.new(loaded)), Map.put(order, catalog, Enum.map(loaded, &elem(&1, 0)))}
    end)
  end

  @doc "The decoded payload of a signed application."
  def signed_payload(s), do: Json.decode_bytes!(s.data)

  @doc "Python's `signed_payload == payload`, without decoding when the bytes already match."
  def same_payload?(s, payload) do
    Json.canonical(payload) == s.data or Json.eq?(signed_payload(s), payload)
  end

  # --- Sources ------------------------------------------------------------------

  @doc "`{listing, body}` of a MANIFEST.md; raises `Error` like the Python `ValueError`s."
  def parse_front_matter(text) do
    case String.split(text, "\n") do
      ["---" | rest] -> parse_meta(rest, 1, [])
      _ -> raise Error, "MANIFEST.md must start with a --- front matter block"
    end
  end

  defp parse_meta([], _, _), do: raise(Error, "front matter block is not closed with ---")

  defp parse_meta(["---" | body], _, acc),
    do: {{:o, dedupe(Enum.reverse(acc))}, Enum.join(body, "\n")}

  defp parse_meta([line | rest], i, acc) do
    case String.split(line, ":", parts: 2) do
      [key, value] ->
        key = Py.strip(key)

        value =
          try do
            Json.decode!(Py.strip(value))
          rescue
            Error ->
              reraise Error,
                      [message: "front matter `#{key}` must be a JSON value, e.g. \"text\""],
                      __STACKTRACE__
          end

        parse_meta(rest, i + 1, [{key, value} | acc])

      [_] ->
        raise Error, "front matter line #{i + 1} is not `key: value`"
    end
  end

  @doc "The front matter block for a listing."
  def front_matter(listing) do
    keys =
      ~w(title catalog categories) ++
        if(Py.truthy?(Json.get(listing, "logo")), do: ["logo"], else: [])

    lines = Enum.map(keys, fn k -> "#{k}: #{Json.dumps(Json.fetch!(listing, k))}\n" end)
    IO.iodata_to_binary(["---\n", lines, "---\n"])
  end

  @doc "`{payload, listing, body}` of an application."
  def load_app(c, app_id) do
    folder = Path.join(apps_dir(c), app_id)
    payload = read_json!(Path.join(folder, "manifest.json"))
    {listing, body} = parse_front_matter(read_text!(Path.join(folder, "MANIFEST.md")))
    {payload, listing, body}
  end

  @doc "Sorted names of the directories under `apps/`."
  def app_ids(c) do
    apps = apps_dir(c)

    case File.ls(apps) do
      {:ok, names} -> names |> Enum.filter(&File.dir?(Path.join(apps, &1))) |> Enum.sort()
      {:error, _} -> []
    end
  end

  def write_app(c, app_id, payload, listing, signed) do
    folder = Path.join(apps_dir(c), app_id)
    File.mkdir_p!(folder)
    write!(Path.join(folder, "manifest.json"), Json.pretty(payload))
    write!(Path.join(folder, "MANIFEST.md"), manifest_md(c, app_id, payload, listing, signed))
  end

  @doc "The full text of an application's MANIFEST.md."
  def manifest_md(c, app_id, payload, listing, signed),
    do: front_matter(listing) <> Docs.render(c, app_id, payload, listing, signed)

  # --- Derivations --------------------------------------------------------------

  @doc """
  The index entry of an application. Categories stay out of index entries: the
  registry server and Ragentic validate entries against a fixed Ash schema that
  rejects unknown fields.
  """
  def index_entry(app_id, payload, listing, digest) do
    entry = %{
      "digest" => digest,
      "id" => app_id,
      "protocol" => Json.fetch!(payload, "protocol"),
      "title" => Json.fetch!(listing, "title"),
      "version" => Json.fetch!(payload, "version")
    }

    entry =
      if Py.truthy?(Json.get(listing, "logo")),
        do: Map.put(entry, "logo", Json.get(listing, "logo")),
        else: entry

    if Json.fetch!(listing, "catalog") == "drafts" do
      entry
      |> Map.put("readiness", Json.fetch!(payload, "readiness"))
      |> Map.put("setup_verification", Json.fetch!(payload, "setup_verification"))
    else
      entry
    end
  end

  @doc "Reasons an application's signed objects differ from its sources (empty when current)."
  def pending(app_id, payload, listing, signed, now, refresh) do
    case Map.get(signed, app_id) do
      nil ->
        ["not signed yet"]

      s ->
        digest = Json.fetch!(s.entry, "digest")

        [
          {not same_payload?(s, payload), "manifest.json changed"},
          {s.catalog != Json.fetch!(listing, "catalog"),
           fn -> "moving from #{s.catalog} to #{Py.str(Json.get(listing, "catalog"))}" end},
          {not Json.eq?(s.entry, index_entry(app_id, payload, listing, digest)),
           "listing changed"},
          {s.expires - now < refresh, "bundle signature expires soon"}
        ]
        |> Enum.filter(&elem(&1, 0))
        |> Enum.map(fn
          {_, f} when is_function(f) -> f.()
          {_, msg} -> msg
        end)
    end
  end

  @doc "Path relative to the root -> SHA-256 of every plain-text file `sources.json` covers."
  def source_files(c) do
    files =
      walk(apps_dir(c)) ++
        walk(path(c, "items")) ++
        walk(path(c, "sources")) ++ [path(c, "CATALOG.md"), path(c, "categories.json")]

    for file <- files, File.exists?(file), into: %{} do
      {Path.relative_to(file, c.root), Trust.sha256(read_bytes!(file))}
    end
  end

  # Path.rglob("*") filtered to is_file(): every file, hidden ones too; symlinked
  # directories are not followed.
  defp walk(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.flat_map(Enum.sort(names), fn name ->
          p = Path.join(dir, name)

          case File.lstat(p) do
            {:ok, %File.Stat{type: :directory}} -> walk(p)
            {:ok, _} -> if File.regular?(p), do: [p], else: []
            {:error, _} -> []
          end
        end)

      {:error, _} ->
        []
    end
  end
end
