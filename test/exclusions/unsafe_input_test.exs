defmodule Argus.Exclusions.UnsafeInputTest do
  @moduledoc """
  Regression cases for unsafe-input exclusions. Suppressed cases have a reported
  twin or supporting row so missing extraction cannot make the check pass.
  Fixtures: test/fixtures/exclusions/unsafe_input.ex.
  """
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Test.Batch
  alias Argus.Test.Rows
  alias Excl.UnsafeInput, as: U

  @stream_and_start [
    U.StreamAndStart.TaskSup,
    U.StreamAndStart.Checker,
    U.StreamAndStart.CheckLive
  ]

  # Every test reads its fixtures' rows from one solve of them all
  # (`Argus.Test.Batch`; ARGUS_VERIFY_BATCH=1 checks each slice against a
  # solve of its own).
  @batched [
    [U.TryAfterSink.Scratch],
    [U.BoundedDecode.Snapshot],
    [U.OpenDecode.Snapshot],
    @stream_and_start
  ]

  setup_all do
    %{batch: Batch.solve(:unsafe_input, @batched)}
  end

  defp results(%{batch: batch}, set) do
    {:ok, results} = Batch.analyze(batch, set)
    results
  end

  # {function, api, sink} of each sink no request reaches.
  defp sinks(ctx, set) do
    for [func, api, sink] <-
          Rows.where(results(ctx, set), :unsafe_input, "sink_without_request_path",
            drop: [:id, :source, :permille, :safety]
          ),
        do: {func |> String.split(":") |> List.last(), api, sink}
  end

  describe "a sink" do
    # unsafe_input.dl, sink: !repeated_site(id).
    test "a try's `after` block the compiler emits twice is one sink", ctx do
      assert sinks(ctx, [U.TryAfterSink.Scratch]) ==
               [{"with_scratch_dir/2", ":os.cmd/1", "code"}]
    end

    # unsafe_input.dl, sink: !bounded_input(id, func).
    test "binary_to_term/1 on a blob the guard compared equal to the program's own", ctx do
      assert sinks(ctx, [U.BoundedDecode.Snapshot]) == []

      assert sinks(ctx, [U.OpenDecode.Snapshot]) ==
               [{"decode/1", ":erlang.binary_to_term/1", "deserialization"}]
    end
  end

  describe "kept: children a request starts without bound" do
    # unsafe_input.dl, stream_only: !starts_tasks_otherwise(via).
    test "a start_child beside an async stream on the same uncapped supervisor", ctx do
      assert [["Excl.UnsafeInput.StreamAndStart.TaskSup", "Task", _, "live_view"]] =
               Rows.where(
                 results(ctx, @stream_and_start),
                 :unsafe_input,
                 "unbounded_children_from_request",
                 drop: []
               )
    end
  end
end
