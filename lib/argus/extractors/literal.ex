defmodule Argus.Extractors.Literal do
  @moduledoc """
  Tagged tuples built into registers: the constructor, the register, and the
  leading atom.

  `literal_value` already records scalars written by `move`, including atoms,
  with the register they landed in. It does not record `put_tuple2`, so a
  message like `{:get, key}` is invisible where a bare `:get` is not — and
  those are different messages, one of which would crash a server expecting
  the other.

  ## Why the register matters

  `def_use` says which write feeds which read; it does not say which
  *operand* of the reader. `GenServer.call(pid, {:get, key})` reads `{x,0}`
  and `{x,1}`, so two edges arrive and nothing on the edge distinguishes the
  destination from the message. The write knows, so recording it here makes
  the pairing sound without changing `def_use`.

  That pairing is what `message_contract` needed and did not have. It was
  reverted because a backward textual scan attributed a stale `{x,1}` write
  to a later call — `:amqp_channel` reported as casting `:ok` when the write
  was really `gen_server:reply(From, ok)`. A reaching-definition edge plus a
  register answers it exactly.

  ## Emitted facts

  - `tuple_literal(id, reg, tag, size)` — a tuple with a literal atom head
  """

  @behaviour Argus.Extractor

  alias Argus.InstrId

  import Argus.Extractor.Helpers, only: [add_fact: 3, scan_functions: 4]

  @impl true
  def extract(%{module: mod, functions: functions}) do
    scan_functions(mod, functions, %{}, fn facts, ctx, instr ->
      case classify(instr) do
        nil ->
          facts

        {reg, tag, size} ->
          add_fact(facts, :tuple_literal, [
            InstrId.mint(ctx.func_id, ctx.idx),
            reg,
            inspect(tag),
            to_string(size)
          ])
      end
    end)
  end

  defp classify({:put_tuple2, reg, {:list, [{:atom, tag} | rest]}}) when is_atom(tag) do
    with {:ok, r} <- register(reg), do: {r, tag, length(rest) + 1}
  end

  defp classify({:move, {:literal, t}, reg}) when is_tuple(t) and tuple_size(t) > 0 do
    case elem(t, 0) do
      tag when is_atom(tag) -> with({:ok, r} <- register(reg), do: {r, tag, tuple_size(t)})
      _ -> nil
    end
  end

  defp classify(_instr), do: nil

  # x-registers only. A y-register is a stack slot whose number is frame
  # relative, so it means nothing to a rule matching on an argument position.
  defp register({:x, n}) when is_integer(n), do: {:ok, "x#{n}"}
  defp register(_other), do: :error
end
