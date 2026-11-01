defmodule Manifests.CatalogTools.Error do
  @moduledoc """
  An expected failure of a catalog tool: what the Python tool reported with
  `die()`, or raised as an `OSError`/`ValueError` (unreadable files, malformed JSON
  or front matter, bad base64).

  Mix tasks print it as `error: <message>` and exit with status 1. `validate` catches
  it while loading an application and reports it as that application's error, like
  the Python tool did.
  """
  defexception [:message]
end
