defmodule Scry.SourceAnchorBlockTest do
  @moduledoc """
  The end of the source block an anchor sits in, read where the
  bytecode could not close the span.
  """

  use ExUnit.Case, async: true

  alias Scry.SourceAnchor

  @moduletag :tmp_dir

  @source """
  defmodule Guarded do
    def checkout(pid, timeout \\\\ 15_000) do
      :gen_statem.call(pid, :checkout, timeout)
    catch
      :exit, {:timeout, _} ->
        {:error, %Timeout{timeout_ms: timeout}}

      :exit, {reason, _} ->
        {:error, %Exited{reason: reason}}
    end

    def inline(pid) do
      result =
        try do
          :gen_statem.call(pid, :cleanup)
        rescue
          ArgumentError -> {:error, :gone}
        end

      send(self(), {:done, result})
      result
    end

    def bare(pid), do: :gen_statem.call(pid, :cleanup, 5_000)

    def wait(ref) do
      receive do
        {^ref, value} -> value
        :other -> :ignored
      end
    end

    @impl true
    def handle_info(:tick, state) do
      {:noreply, state}
    end

    # A comment between clauses.
    @doc false
    def handle_info({:DOWN, _, _, _, _}, state), do: {:noreply, state}

    def handle_info(:stop, state) do
      {:stop, :normal, state}
    end

    def other(state), do: state
  end
  """

  setup %{tmp_dir: dir} do
    path = Path.join(dir, "guarded.ex")
    File.write!(path, @source)
    %{path: path}
  end

  test "a body-level catch spans to its last clause", %{path: path} do
    assert SourceAnchor.block_end(path, 3, :guard) == 9
  end

  test "an inline try's rescue spans to its end, not past it", %{path: path} do
    assert SourceAnchor.block_end(path, 15, :guard) == 17
  end

  test "a call with no guard has no catch block", %{path: path} do
    assert SourceAnchor.block_end(path, 24, :guard) == nil
  end

  test "a receive spans to its end", %{path: path} do
    assert SourceAnchor.block_end(path, 27, :receive) == 29
    assert SourceAnchor.block_end(path, 28, :receive) == nil
  end

  test "a clause spans to its end; a one-liner has no block", %{path: path} do
    assert SourceAnchor.block_end(path, 34, :clause) == 35
    assert SourceAnchor.block_end(path, 40, :clause) == nil
    assert SourceAnchor.block_end(path, 2, :clause) == 9
  end

  test "a function spans every consecutive clause, attributes and comments between", %{
    path: path
  } do
    assert SourceAnchor.block_end(path, 34, :function) == 43
  end

  test "the guard keyword is what the source says, or nil", %{path: path} do
    assert SourceAnchor.guard_keyword(path, 3) == "catch"
    assert SourceAnchor.guard_keyword(path, 15) == "rescue"
    assert SourceAnchor.guard_keyword(path, 24) == nil
  end

  test "no block, no file: nil", %{path: path} do
    assert SourceAnchor.block_end(path, 3, nil) == nil
    assert SourceAnchor.block_end(Path.join(path, "nope"), 3, :guard) == nil
  end
end
