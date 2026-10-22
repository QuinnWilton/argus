defmodule Argus.Extractors.ErrorHandling.Release do
  @moduledoc """
  What narrows a catch-all's risk: a `try` (or Erlang `catch`) that
  protects nothing but releasing a resource, and a handler that hands a
  runtime function's verdict on its input on as an error value.

  Closing a socket, deleting a table or cancelling a timer fails when
  the resource is already gone: the peer closed the socket, the table's
  owner died with it. A catch-all around the release alone, `try
  ets:delete(T) catch _:_ -> ok end`, is the usual best-effort cleanup,
  and what it hides is narrow: a release that failed for another reason.
  A release is a call the runtime defines as one, or a call to a function
  of the program or a dependency named for one (`close`, `stop`,
  `delete`, ...) whose clause heads cannot fail: one that can raises
  FunctionClauseError for an argument nothing takes, the caller's own
  bug. A runtime function so named, such as `Map.delete/2`, releases
  nothing. The name is the program's own word for what its function
  does, a heuristic, so a rule reading this steps a finding down rather
  than dropping it. The region may also hold boundary operations and
  instructions that cannot raise (`Argus.Extractors.ErrorHandling.Boundary`),
  and nothing else.

  A handler that returns `error` or an `{:error, _}` tuple tells its
  caller that the guarded code failed, and loses only why. That is all
  it loses when every call the try guards is a pure runtime function,
  whose exceptions are its verdict on its input: `try
  binary_to_integer(B) catch _:_ -> error end`. A call into the program,
  or into the runtime for an effect (`Supervisor.start_child/2`, which
  builds a child spec in its caller and raises there for a module with
  no `child_spec/1`), can raise for a bug, which the error value then
  passes off as an expected failure. A handler returning `ok`, a default
  or an empty collection makes a failure look like success.
  """

  alias Argus.EffectModel
  alias Argus.Extractor.Helpers
  alias Argus.Extractor.Runtime
  alias Argus.Extractors.ErrorHandling.Boundary
  alias Argus.Instr
  import Argus.Instr, only: [slot: 1]

  @release_calls MapSet.new([
                   {:ets, :delete, 1},
                   {:dets, :close, 1},
                   {:gen_tcp, :close, 1},
                   {:gen_udp, :close, 1},
                   {:gen_sctp, :close, 1},
                   {:ssl, :close, 1},
                   {:ssl, :close, 2},
                   {:socket, :close, 1},
                   {:inet, :close, 1},
                   {:file, :close, 1},
                   {:file, :delete, 1},
                   {:file, :del_dir, 1},
                   {:disk_log, :close, 1},
                   {:zlib, :close, 1},
                   {:erlang, :cancel_timer, 1},
                   {:erlang, :cancel_timer, 2},
                   {:timer, :cancel, 1},
                   {File, :close, 1},
                   {File, :rm!, 1},
                   {File, :rm_rf!, 1},
                   {Port, :close, 1}
                 ])

  @release_names [:close, :stop, :shutdown, :delete, :cancel, :release, :disconnect]

  @doc """
  What the region `visited` (instruction indices into `table`, the
  function's instructions as a tuple) does when it releases a resource
  and nothing else that can raise: `:releases` when every release is the
  runtime's, `{:named, calls}` when some are calls to functions named for
  one (their indices), whose callees a rule must check
  (`function?/2`); else `:none`.
  """
  @spec region(Enumerable.t(non_neg_integer()), tuple()) ::
          :releases | {:named, [non_neg_integer()]} | :none
  def region(visited, table) do
    kinds = for idx <- Enum.sort(visited), do: {idx, kind(elem(table, idx))}

    cond do
      Enum.any?(kinds, &match?({_, :other}, &1)) -> :none
      Enum.any?(kinds, &match?({_, :named}, &1)) -> {:named, for({i, :named} <- kinds, do: i)}
      Enum.any?(kinds, &match?({_, :release}, &1)) -> :releases
      true -> :none
    end
  end

  defp kind(instr) do
    case named(instr) do
      {:ok, m, f, a} ->
        cond do
          MapSet.member?(@release_calls, {m, f, a}) -> :release
          f in @release_names and not Runtime.module?(m) -> :named
          Boundary.boundary?(instr) or Boundary.inert?(instr) -> :inert
          true -> :other
        end

      :none ->
        if Boundary.boundary?(instr) or Boundary.inert?(instr), do: :inert, else: :other
    end
  end

  defp named(instr) do
    case Helpers.match_remote_call(instr) do
      :none -> Helpers.match_local_call(instr)
      found -> found
    end
  end

  @doc """
  Whether a function is a release by its name, `name`, and cannot fail to
  match its arguments.
  """
  @spec function?(atom(), [tuple() | atom()]) :: boolean()
  def function?(name, instrs),
    do: name in @release_names and not Boundary.clause_can_fail?(instrs)

  @doc """
  Whether every call in the region `visited` is a pure runtime function
  (`Argus.EffectModel`), so that what the region raises is a runtime
  function's verdict on its input.
  """
  @spec pure_runtime?(Enumerable.t(non_neg_integer()), tuple()) :: boolean()
  def pure_runtime?(visited, table) do
    Enum.all?(visited, fn idx ->
      instr = elem(table, idx)

      cond do
        not (Instr.call?(instr) or Instr.tail_call?(instr)) -> true
        match?({:ok, _, _, _}, Helpers.match_remote_call(instr)) -> pure_call?(instr)
        true -> false
      end
    end)
  end

  defp pure_call?(instr) do
    {:ok, m, f, a} = Helpers.match_remote_call(instr)
    Runtime.module?(m) and EffectModel.classify(inspect(m), Atom.to_string(f), a) == :pure
  end

  @doc """
  Whether a handler's body (from after its `try_case` to the first
  return) returns `error` or a tuple tagged `:error` that it builds or
  names as a literal.
  """
  @spec error_return?([tuple() | atom()]) :: boolean()
  def error_return?(body) do
    case Enum.split_while(body, &(&1 != :return)) do
      {before, [:return | _]} -> before |> Enum.reverse() |> last_x0() |> error_value?()
      _ -> false
    end
  end

  defp last_x0(reversed) do
    Enum.find(reversed, fn instr ->
      is_tuple(instr) and {:x, 0} in Enum.map(Instr.defs(instr), &slot/1)
    end)
  end

  defp error_value?({:move, {:atom, :error}, _dst}), do: true

  defp error_value?({:move, {:literal, value}, _dst})
       when is_tuple(value) and tuple_size(value) > 0,
       do: elem(value, 0) == :error

  defp error_value?({:put_tuple2, _dst, {:list, [{:atom, :error} | _]}}), do: true
  defp error_value?(_instr), do: false
end
