defmodule Manifests.AnalyticsTest do
  use Manifests.DataCase, async: true
  alias Manifests.Analytics

  test "counts per bundle per day and rolls up days, weeks and years" do
    today = ~D[2026-11-04]

    for {day, digest, times} <- [
          {~D[2026-11-04], "a", 3},
          {~D[2026-11-02], "b", 1},
          {~D[2026-10-26], "a", 2},
          {~D[2025-03-01], "a", 4}
        ],
        _ <- 1..times,
        do: Analytics.record("pay", digest, day)

    Analytics.record("other", "z", today)

    s = Analytics.summary("pay", today)
    assert s.total == 10 and s.on_day == 3
    assert s.by_digest == %{"a" => 9, "b" => 1}

    assert length(s.days) == 30
    assert List.last(s.days) == {today, 3}
    assert {~D[2026-11-02], 1} in s.days

    # Weeks start on Monday: Nov 2 (Mon) holds the 2nd and 4th, Oct 26 the week before.
    assert length(s.weeks) == 26
    assert Enum.take(s.weeks, -2) == [{~D[2026-10-26], 2}, {~D[2026-11-02], 4}]

    assert s.years == [{~D[2025-01-01], 4}, {~D[2026-01-01], 6}]

    # A live download folded in matches re-reading the counts.
    bumped = Analytics.bump(s, "b", today)
    :ok = Analytics.record("pay", "b", today)
    assert bumped == Analytics.summary("pay", today)
  end

  test "an application nobody downloaded has empty series" do
    s = Analytics.summary("nope", ~D[2026-11-04])
    assert s.total == 0 and s.years == [{~D[2026-01-01], 0}]
    assert Enum.all?(s.days, &(elem(&1, 1) == 0))
  end
end
