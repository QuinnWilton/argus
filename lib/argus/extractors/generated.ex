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
  module, or that is marked generated, is emitted here. Erlang's macros
  are the preprocessor's and leave no trace to read, but a function an
  included file defines does: the abstract code places it after a
  `-file` attribute naming that file. A parser yecc or leex generated
  carries its runtime from OTP's templates (`yeccpre.hrl`,
  `leexinc.hrl`), and a header of an installed OTP application
  (`.../lib/<app>-<vsn>/include/x.hrl`) is OTP's too: their functions
  are emitted with the header's name as `by`. A header of the program's
  own is the program's code. A parser compiled without debug info
  (ejabberd's) still shows yecc's output by name: a module defining
  `yeccpars0/5` has its `yecc*` functions from yecc (`yeccpre.hrl`'s
  runtime and the parse tables yecc writes beside it), emitted with
  `yecc` as `by`. Other beams without debug info yield nothing.

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

    facts =
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

    for {name, arity, header} <- included(module_data), reduce: facts do
      acc ->
        func_id = Normalize.func_id(mod, name, arity)

        acc
        |> add_fact(:macro_generated, [func_id, header])
        |> add_fact(:macro_written, [func_id])
    end
  end

  # ── Functions an OTP header defines ────────────────────────────────

  @generator_templates ["yeccpre.hrl", "leexinc.hrl"]

  # The functions an Erlang module's abstract code defines under a
  # `-file` attribute naming an OTP header, as {name, arity, basename}.
  # Without abstract code, yecc's output by the names it fixes.
  defp included(module_data) do
    case Helpers.debug_info(module_data) do
      {:ok, {:debug_info_v1, :erl_abstract_code, {forms, _opts}}} when is_list(forms) ->
        from_forms(forms)

      _ ->
        yecc_runtime(module_data)
    end
  rescue
    # A debug-info backend that cannot hand back abstract code may raise;
    # such a module has no header functions to read.
    _ -> []
  end

  defp yecc_runtime(%{functions: functions}) do
    names = for {:function, name, arity, _entry, _instrs} <- functions, do: {name, arity}

    if {:yeccpars0, 5} in names,
      do:
        for(
          {name, arity} <- names,
          String.starts_with?(Atom.to_string(name), "yecc"),
          do: {name, arity, "yecc"}
        ),
      else: []
  end

  defp from_forms(forms) do
    {rows, _file} =
      Enum.reduce(forms, {[], nil}, fn
        {:attribute, _, :file, {file, _line}}, {rows, _file} ->
          {rows, to_string(file)}

        {:function, _, name, arity, _clauses}, {rows, file} ->
          if otp_header?(file),
            do: {[{name, arity, Path.basename(file)} | rows], file},
            else: {rows, file}

        _form, acc ->
          acc
      end)

    Enum.reverse(rows)
  end

  defp otp_header?(nil), do: false

  defp otp_header?(file) do
    Path.basename(file) in @generator_templates or
      Regex.match?(~r{/lib/[a-z][a-z0-9_]*-[0-9][^/]*/include/[^/]+\.hrl$}, file)
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
