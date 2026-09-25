defmodule Argus.Extractors.Generated do
  @moduledoc """
  Functions another module's macro wrote into this one.

  `use Ecto.Repo` defines `stop/1`, `all/2` and some sixty others in the
  repo module, every one on the `use` line. Their call sites are the
  library's, not the program's: a rule that compares how the program's
  own sites handle a callee (`failure.inconsistent_handling`) must not
  count them, or report them, as the program's choice.

  Elixir records, in each definition's metadata in the debug info, the
  module whose `quote` produced it (`context:`), and `generated: true`
  where the macro asked for it. A definition whose context is another
  module, or that is marked generated, is emitted here. Erlang modules
  and beams without Elixir debug info yield nothing: their macros are
  the preprocessor's, and leave no trace to read.

  A definition's own metadata is its first clause's: a `use` that
  injects a clause ahead of the module's own (`use Sequin.ProcessMetrics`
  before SlotMessageStore's handle_info/2 clauses) marks the whole
  definition. Each clause carries its metadata too, and `macro_written`
  asks every one.

  ## Emitted facts

  - `macro_generated(func, by)` — `func` was defined by a macro of module
    `by` (inspected), or `generated` when only the `generated: true`
    marker says so.
  - `macro_written(func)` — every clause of `func` was written by another
    module's macro (or marked generated): the module wrote none of it,
    as `use Cachex.Warmer`'s handle_info/2
  """

  @behaviour Argus.Extractor

  import Argus.Extractor.Facts, only: [add_fact: 3]

  alias Argus.Extractor.Helpers

  alias Argus.Pipeline.Normalize

  @impl true
  def relations, do: [:macro_generated, :macro_written]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    mod = module_data.module

    for {{name, arity}, _kind, meta, clauses} <- definitions(module_data),
        by = generated_by(meta, mod),
        by != nil,
        reduce: %{} do
      acc ->
        func_id = Normalize.func_id(mod, name, arity)
        acc = add_fact(acc, :macro_generated, [func_id, by])

        if Enum.all?(clauses, &clause_generated?(&1, mod)),
          do: add_fact(acc, :macro_written, [func_id]),
          else: acc
    end
  end

  defp clause_generated?({meta, _args, _guards, _body}, mod), do: generated_by(meta, mod) != nil
  defp clause_generated?(_clause, _mod), do: false

  defp generated_by(meta, mod) do
    case {Keyword.get(meta, :context), Keyword.get(meta, :generated, false)} do
      {context, _} when is_atom(context) and context not in [nil, mod] -> inspect(context)
      {_, true} -> "generated"
      _ -> nil
    end
  end

  defp definitions(module_data) do
    with {:ok, {:debug_info_v1, backend, data}} <- Helpers.debug_info(module_data),
         {:ok, %{definitions: definitions}} <-
           backend.debug_info(:elixir_v1, module_data.module, data, []) do
      definitions
    else
      _ -> []
    end
  rescue
    # A backend that cannot answer for :elixir_v1 may raise rather than
    # return an error; such a module has no Elixir definitions to read.
    _ -> []
  end
end
