defmodule Argus.Extractor.NeverReturns do
  @moduledoc """
  The functions of a module that never return to their caller: every way
  out of one raises, or tail-calls a function that never returns.

  Elixir lifts a `with`'s `else` clauses into a local fun of the module
  (`-write/4-fun-0-`) that every failing step tail-calls, and a module's
  own `fail!/1` helper raises the same way. A path that calls one ends
  in a raise as surely as a path that calls `:erlang.error/1` itself.

  A function returns when it holds a `return`, or a tail call to
  anything but a raising BIF or a function of the module that never
  returns. The set is the greatest that holds, so a function whose only
  way out is a call to itself (a loop with no exit) is in it: it does not
  return either. Unreachable code counts, which only keeps a function out.
  """

  alias Argus.Extractor.Helpers
  alias Argus.Instr
  alias Argus.InstrId

  # The calls that raise instead of returning.
  @raising [
    {:erlang, :error, 1},
    {:erlang, :error, 2},
    {:erlang, :error, 3},
    {:erlang, :exit, 1},
    {:erlang, :throw, 1},
    {:erlang, :raise, 3},
    {:erlang, :nif_error, 1},
    {:erlang, :nif_error, 2}
  ]

  @doc "Whether `instr` calls a BIF that raises instead of returning."
  @spec raising_call?(Instr.instr()) :: boolean()
  def raising_call?(instr) do
    case Helpers.match_remote_call(instr) do
      {:ok, m, f, a} -> {m, f, a} in @raising
      :none -> false
    end
  end

  @doc """
  Whether `instr` is a call that never returns: a raising BIF, or a
  local call to one of `never` (function IDs, `functions/1`).
  """
  @spec call?(Instr.instr(), MapSet.t(String.t())) :: boolean()
  def call?(instr, never) do
    raising_call?(instr) or
      case Helpers.match_local_call(instr) do
        {:ok, m, f, a} -> MapSet.member?(never, InstrId.func_id(m, f, a))
        :none -> false
      end
  end

  @doc "The function IDs of the module's functions that never return."
  @spec functions(Argus.Extractor.module_data()) :: MapSet.t(String.t())
  def functions(%{module: mod, functions: functions}) do
    exits =
      Map.new(functions, fn {:function, name, arity, _entry, instrs} ->
        {InstrId.func_id(mod, name, arity), Enum.filter(instrs, &Instr.exits?/1)}
      end)

    exits
    |> Map.keys()
    |> MapSet.new()
    |> shrink(exits)
  end

  # Drops every function with a way out that returns, until none has.
  defp shrink(never, exits) do
    kept =
      MapSet.filter(never, fn func ->
        exits |> Map.fetch!(func) |> Enum.all?(&(&1 != :return and call?(&1, never)))
      end)

    if MapSet.equal?(kept, never), do: never, else: shrink(kept, exits)
  end
end
