defmodule Argus.Origins do
  @moduledoc """
  Where a module was compiled from, so findings about scaffolding can be
  told apart from findings about the program.

  Sweeping a project compiled in `test` env picks up its fixtures, and on
  some projects that is most of the output — running all of Argus over
  Argus reports its own `Argus.Test.Fixtures.*` modules, which exist
  precisely to make these analyses fire. Every ad-hoc sweep ends up
  reinventing a filter, usually by matching on module names, which is a
  guess.

  It does not have to be. Every BEAM file carries a `compile_info` chunk
  whose `:source` is the absolute path the module was compiled from, so
  this is exactly knowable:

      iex> Argus.Origins.classify(["_build/test/lib/app/ebin/Elixir.App.Thing.beam"])
      %{"App.Thing" => :lib}

  ## Categories

    * `:test` — compiled from a `test/` directory, or from a `support/`
      directory beneath one. Fixtures and helpers.
    * `:dep` — compiled from `deps/`. Third-party, and worth keeping: the
      most severe findings in `docs/findings-2026-08.md` are dependencies.
    * `:lib` — everything else, which is the project's own code.

  Absence of a `:source` is reported as `:unknown` rather than guessed at.
  A module stripped of its compile info is not evidence of anything.

  ## What it is worth

  Argus compiled for test is **294 modules, of which 218 are fixtures** —
  74%. Dropping them takes `call_cycle` from three findings to none and
  `deferred_startup_deadlock` from five to none, because on this project
  every one of them was scaffolding built to make those analyses fire.

  ## Rows anchored on an instruction

  `reject/4` defaults to reading the module from a row's first column,
  which is where most analyses put it. Some anchor on an instruction or
  function ID instead — `atom_safety` rows begin
  `"Argus.Findings:at_parts/3#17"` — and for those the default finds no
  module and keeps everything. Pass a key that extracts one:

      Argus.Origins.reject(rows, origins, [:test], fn [id | _] ->
        {:ok, %{module: mod}} = Argus.InstrId.parse(id)
        mod
      end)

  Filtering nothing is the safe failure here: it leaves noise in rather
  than dropping findings on a key it could not read.
  """

  @type category :: :lib | :test | :dep | :unknown

  @doc """
  Classify each beam path by where its module was compiled from.

  Returns a map keyed by the module's `inspect/1` form, which is how module
  names appear in Datalog rows and therefore in findings.
  """
  @spec classify([Path.t()]) :: %{String.t() => category()}
  def classify(beam_paths) when is_list(beam_paths) do
    Map.new(beam_paths, fn path ->
      case :beam_lib.chunks(to_charlist(path), [:compile_info]) do
        {:ok, {module, [compile_info: info]}} ->
          {inspect(module), categorize(Keyword.get(info, :source))}

        _ ->
          {inspect(module_from_path(path)), :unknown}
      end
    end)
  end

  @doc """
  Drop rows whose module falls in one of `categories`.

  `key` extracts the module name from a row; it defaults to the first
  column, which is where analyses put it.

      Argus.Origins.reject(rows, origins, [:test])
  """
  @spec reject([[String.t()]], %{String.t() => category()}, [category()], (list() -> String.t())) ::
          [[String.t()]]
  def reject(rows, origins, categories, key \\ &hd/1) do
    Enum.reject(rows, fn row ->
      Map.get(origins, key.(row), :unknown) in categories
    end)
  end

  defp categorize(nil), do: :unknown

  defp categorize(source) do
    parts = source |> to_string() |> Path.split()

    cond do
      "test" in parts -> :test
      "deps" in parts -> :dep
      true -> :lib
    end
  end

  defp module_from_path(path) do
    path |> Path.basename(".beam") |> String.to_atom()
  end
end
