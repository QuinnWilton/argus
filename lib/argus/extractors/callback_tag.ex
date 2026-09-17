defmodule Argus.Extractors.CallbackTag do
  @moduledoc """
  The message tags a `handle_call/3`, `handle_cast/2` or `handle_info/2`
  discriminates on, and whether it has a catch-all.

  The server half of a GenServer's contract. The client half — which tag a
  wrapper actually sends — is not extracted here: it is a join over
  `tuple_literal`/`literal_value`, `def_use` and `remote_call`, which is
  what makes it sound. An earlier version scanned backwards from the call
  for the last write to `{x,1}` and attributed a stale one, reporting
  `:amqp_channel` as casting `:ok` when the write was really
  `gen_server:reply(From, ok)`.

  Tags are over-approximated: every atom compared anywhere in the body
  counts, without tracking which register held it. Consumers ask whether a
  tag is NOT handled, so over-approximating suppresses findings rather than
  inventing them.

  ## Emitted facts

  - `callback_tag(func, callback, tag)` — an atom the callback discriminates on
  - `callback_total(func, callback)` — some clause accepts every message,
    whatever it demands of the state (`handle_info(msg, {stack, cont})`
    is a catch-all for messages), so no tag can fail
  """

  @behaviour Argus.Extractor

  alias Argus.Extractor.Dispatch
  alias Argus.InstrId

  import Argus.Extractor.Helpers, only: [add_fact: 3]

  @callbacks %{
    {:handle_call, 3} => "handle_call",
    {:handle_cast, 2} => "handle_cast",
    {:handle_info, 2} => "handle_info"
  }

  @impl true
  def relations,
    do: [
      :callback_tag,
      :callback_total
    ]

  @impl true
  def extract(%{module: mod, functions: functions}) do
    Enum.reduce(functions, %{}, fn {:function, name, arity, _entry, instrs}, acc ->
      case Map.fetch(@callbacks, {name, arity}) do
        :error ->
          acc

        {:ok, callback} ->
          func_id = InstrId.func_id(mod, name, arity)

          acc
          |> emit_tags(func_id, callback, instrs)
          |> emit_total(func_id, callback, instrs)
      end
    end)
  end

  defp emit_tags(facts, func_id, callback, instrs) do
    instrs
    |> Dispatch.compared_atoms(:any)
    |> Enum.reduce(facts, &add_fact(&2, :callback_tag, [func_id, callback, inspect(&1)]))
  end

  defp emit_total(facts, func_id, callback, instrs) do
    if Dispatch.total_on?(instrs, {:x, 0}),
      do: add_fact(facts, :callback_total, [func_id, callback]),
      else: facts
  end
end
