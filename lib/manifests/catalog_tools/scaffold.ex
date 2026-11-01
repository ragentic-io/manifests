defmodule Manifests.CatalogTools.Scaffold do
  @moduledoc """
  `new`: scaffold a draft application from an OpenAPI or Swagger definition, like
  `tools/catalog.py new`. The definition (JSON, else YAML) is fetched, embedded and
  recorded with its URL and SHA-256 under `provenance`; the operation graph is
  generated and `apps/<id>/manifest.json`, `MANIFEST.md` and `CATALOG.md` are written.

  `http(s)://` and `file://` URLs are supported, as with Python's `urlopen`.
  """

  alias Manifests.CatalogTools.{Catalog, Docs, Error, Graph, Json, Py, Trust, Validate, Yaml}

  @credentials ~w(none static_bearer api_key_header)

  def credentials, do: @credentials

  @doc """
  Options: `:openapi` (URL, required), `:categories` (list, required), `:title`,
  `:endpoint`, `:credential`, `:header`, `:prefix`, `:now` (unix seconds, pins
  `provenance.fetched_at`).
  """
  def run(c, app_id, opts) do
    unless Validate.valid_id?(app_id),
      do: raise(Error, "id must match [a-z0-9][a-z0-9._-]{0,127}")

    if File.exists?(Path.join(Catalog.apps_dir(c), app_id)),
      do: raise(Error, "apps/#{app_id} already exists")

    known = Catalog.categories(c)
    categories = Keyword.fetch!(opts, :categories)
    unknown = Enum.reject(categories, &Json.has?(known, &1))

    if unknown != [] do
      raise Error,
            "unknown categories #{Py.repr(unknown)}; choose from #{Enum.join(Json.keys(known), ", ")}"
    end

    url = Keyword.fetch!(opts, :openapi)
    {raw, doc} = fetch_document(url)
    unless Json.dict?(doc), do: raise(Error, "the definition at #{url} is not an object")
    info = doc |> Json.get("info") |> Py.py_or(%{})

    https_server =
      doc
      |> Json.get("servers")
      |> Py.py_or([])
      |> Enum.find(&String.starts_with?(Py.str(Json.get(&1, "url", "")), "https://"))

    endpoint =
      Py.py_or(Keyword.get(opts, :endpoint), https_server && Json.get(https_server, "url"))

    title = opts |> Keyword.get(:title) |> Py.py_or(Json.get(info, "title")) |> Py.py_or(app_id)
    base = %{"protocol" => "openapi", "specification" => %{"document" => doc}, "type" => "app"}
    base = if Py.truthy?(endpoint), do: Map.put(base, "endpoint", endpoint), else: base

    payload = %{
      "a2ui" => %{},
      "app" => app_id,
      "graph" => Graph.openapi_graph(app_id, doc),
      "kind" => "bundle",
      "manifest" => %{
        "apiVersion" => "ragentic.dev/v1",
        "kind" => "ConnectorTemplate",
        "metadata" => %{"name" => app_id},
        "spec" => %{
          "base" => base,
          "category" => "app",
          "connector" => %{},
          "status" => "draft",
          "title" => title
        }
      },
      "protocol" => "openapi",
      "provenance" => %{
        "fetched_at" => fetched_at(Keyword.get(opts, :now)),
        "license" => Json.get(info, "license"),
        "origins" => [
          %{
            "format" => "openapi",
            "url" => url,
            "version" => Py.str(Py.py_or(Json.get(doc, "openapi"), Json.get(doc, "swagger")))
          }
        ],
        "sha256" => Trust.sha256(raw),
        "source_id" => app_id,
        "source_updated" => nil,
        "url" => url
      },
      "readiness" => "discovered",
      "review_required" => %{
        "authentication" => true,
        "branding" => true,
        "connection_test" => true,
        "external_references" => [],
        "setup_guide" => true,
        "source_currency" => true
      },
      "setup_verification" => "not_live_verified",
      "version" => Py.str(Py.py_or(Json.get(info, "version"), "1"))
    }

    payload =
      case Keyword.get(opts, :credential) do
        cred when cred in [nil, ""] ->
          payload

        cred ->
          credential = %{"type" => cred}
          header = Keyword.get(opts, :header)

          credential =
            if Py.truthy?(header),
              do:
                Map.merge(credential, %{
                  "header" => header,
                  "prefix" => Py.py_or(Keyword.get(opts, :prefix), "")
                }),
              else: credential

          Map.put(payload, "setup", %{"credential" => credential})
      end

    listing = {:o, [{"title", title}, {"catalog", "drafts"}, {"categories", categories}]}
    {signed, _} = Catalog.signed_state(c)
    Catalog.write_app(c, app_id, payload, listing, signed)
    Catalog.write!(Catalog.path(c, "CATALOG.md"), Docs.render_catalog(c, signed))

    IO.puts(
      "wrote apps/#{app_id}/manifest.json and MANIFEST.md (#{length(payload["graph"]["nodes"]) - 1} graph nodes)"
    )

    IO.puts(
      "next: review both files, run `python tools/catalog.py validate`, then open a pull request"
    )

    :ok
  end

  # datetime.now(timezone.utc).isoformat()
  defp fetched_at(now) do
    us = if now, do: now * 1_000_000, else: System.system_time(:microsecond)
    dt = DateTime.from_unix!(us, :microsecond)
    {micro, _} = dt.microsecond

    fraction =
      if micro == 0, do: "", else: "." <> String.pad_leading(Integer.to_string(micro), 6, "0")

    Calendar.strftime(dt, "%Y-%m-%dT%H:%M:%S") <> fraction <> "+00:00"
  end

  @doc "`{raw bytes, decoded document}` of a definition URL: JSON first, else YAML."
  def fetch_document(url) do
    raw = fetch(url)

    unless String.valid?(raw),
      do: raise(Error, "'utf-8' codec can't decode the definition at #{url}")

    doc =
      try do
        Json.decode_bytes!(raw)
      rescue
        Error -> Yaml.safe_load!(raw)
      end

    {raw, doc}
  end

  defp fetch("file://" <> _ = url) do
    path = URI.decode(URI.parse(url).path || "")
    Catalog.read_bytes!(path)
  end

  defp fetch(url) do
    {:ok, _} = Application.ensure_all_started(:req)

    case Req.get(url,
           headers: [{"user-agent", "ragentic-manifests-catalog"}],
           decode_body: false,
           compressed: false,
           retry: false,
           receive_timeout: 60_000
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        body

      {:ok, %Req.Response{status: status}} ->
        raise Error, "HTTP Error #{status} fetching #{url}"

      {:error, exception} ->
        raise Error, "could not fetch #{url}: #{Exception.message(exception)}"
    end
  end
end
