defmodule Manifests.Analytics do
  @moduledoc """
  Download counts: one per signed bundle served, from any of the bundle routes
  (`/v1/bundles`, `/v1/browse-bundles`, `/api/v1/manifests/:id/bundle`).
  Catalog browsing reads only the indexes, so a download is a client actually
  fetching a definition. Counts are per bundle per UTC day; every count is also
  broadcast on `topic/1` so pages can show it live.
  """
  use Ash.Domain, otp_app: :manifests

  import Ecto.Query
  require Logger
  alias Manifests.Repo

  resources do
    resource Manifests.Analytics.DownloadDay
  end

  @days 30
  @weeks 26

  def topic(manifest_id), do: "downloads:" <> manifest_id

  @doc "Every download, of any application: `{:download, manifest_id, digest, day}`."
  def topic, do: "downloads"

  @doc "Count one download. Never fails the request that served the bundle."
  def record(manifest_id, digest, today \\ Date.utc_today()) do
    Repo.insert_all(
      "manifest_downloads",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          manifest_id: manifest_id,
          digest: digest,
          day: today,
          count: 1
        }
      ],
      on_conflict: [inc: [count: 1]],
      conflict_target: [:digest, :day]
    )

    Phoenix.PubSub.broadcast(Manifests.PubSub, topic(manifest_id), {:download, digest, today})
    Phoenix.PubSub.broadcast(Manifests.PubSub, topic(), {:download, manifest_id, digest, today})
    :ok
  rescue
    error ->
      Logger.warning("download not counted for #{manifest_id}: #{Exception.message(error)}")
      :error
  end

  @doc """
  Totals and chart series for one application, or for every application with
  `:all`: the last #{@days} days, the last #{@weeks} weeks (starting Mondays) and
  every year since the first download, each as `[{start_date, count}]` with
  empty periods filled in. `by_digest` is per bundle, for one application only.
  """
  def summary(manifest_id, today \\ Date.utc_today()) do
    scoped =
      if manifest_id == :all,
        do: from(d in "manifest_downloads"),
        else: from(d in "manifest_downloads", where: d.manifest_id == ^manifest_id)

    by_day =
      Map.new(
        Repo.all(
          from d in scoped,
            group_by: d.day,
            select: {d.day, type(sum(d.count), :integer)}
        )
      )

    by_digest =
      if manifest_id == :all,
        do: %{},
        else:
          Map.new(
            Repo.all(
              from d in scoped,
                group_by: d.digest,
                select: {d.digest, type(sum(d.count), :integer)}
            )
          )

    first = by_day |> Map.keys() |> Enum.min(Date, fn -> today end)

    %{
      today: today,
      total: Enum.sum(Map.values(by_day)),
      on_day: Map.get(by_day, today, 0),
      by_digest: by_digest,
      days: series(by_day, Date.add(today, 1 - @days), today, & &1, &Date.add(&1, 1)),
      weeks:
        series(
          by_day,
          Date.add(Date.beginning_of_week(today), -7 * (@weeks - 1)),
          today,
          &Date.beginning_of_week/1,
          &Date.add(&1, 7)
        ),
      years:
        series(
          by_day,
          Date.new!(Kernel.min(first.year, today.year), 1, 1),
          today,
          &Date.new!(&1.year, 1, 1),
          &Date.new!(&1.year + 1, 1, 1)
        )
    }
  end

  @doc "Fold one live download into a summary instead of re-reading it."
  def bump(%{today: today} = summary, digest, today) do
    bump = fn series -> List.update_at(series, -1, fn {start, n} -> {start, n + 1} end) end

    %{
      summary
      | total: summary.total + 1,
        on_day: summary.on_day + 1,
        by_digest: Map.update(summary.by_digest, digest, 1, &(&1 + 1)),
        days: bump.(summary.days),
        weeks: bump.(summary.weeks),
        years: bump.(summary.years)
    }
  end

  defp series(by_day, from, to, bucket, next) do
    counts =
      Enum.reduce(by_day, %{}, fn {day, n}, acc -> Map.update(acc, bucket.(day), n, &(&1 + n)) end)

    from
    |> Stream.iterate(next)
    |> Enum.take_while(&(Date.compare(&1, to) != :gt))
    |> Enum.map(&{&1, Map.get(counts, &1, 0)})
  end
end
