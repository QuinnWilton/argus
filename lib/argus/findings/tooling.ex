defmodule Argus.Findings.Tooling do
  @moduledoc """
  Findings in code only developers' tools or tests run, a step down.

  A dev or test build compiles more than the product — Mix tasks, a
  project's test support, a library's test helpers, a development-only
  seed or dashboard — and an analysis reports what it finds there as it
  would anywhere. A deadlock in a Mix task hangs a developer's command,
  a race in a seed script loses a row of fake data, a crash in a test
  client fails a test: the defect is real and worth a look, and it costs
  no running system. Every analysis includes `clientlib/tooling.dl` and
  outputs its `tooling` rows beside its findings (`relation/0` declares
  them, `retier: :tooling`); `Argus.Findings.Build` steps each finding
  anchored in such a module down one level (`retier/2`) and says why.
  An `:info` finding stays `:info`; nothing is removed.

  How the module is known is the row's `basis`: `mix` and
  `test_support` are structural (`Argus.Extractors.Tooling`: a module
  under `Mix.`, or compiled from a `test/support/` directory or a `test/`
  directory within a `lib/`). The finding keeps its provenance; its help
  says what the module is.
  """

  @basis %{
    "mix" =>
      "a Mix task or a helper Mix tasks share: it runs in a developer's shell, not the deployed system",
    "test_support" => "test support compiled into this build: only tests run it"
  }

  @doc """
  The output relation every analysis declares for its `tooling` rows:
  they re-tier the analysis's findings and are no findings themselves.
  """
  @spec relation() :: Argus.Analysis.output_relation()
  def relation do
    %{
      name: :tooling,
      fields: [
        {:mod, :symbol, "the module, inspected"},
        {:basis, :symbol, "mix | test_support — how the module is known to be tooling"},
        {:permille, :number, "1000 for a structural basis"}
      ],
      doc:
        "A module only developers' tools or tests run (clientlib/tooling.dl): a finding " <>
          "anchored in it steps down one level.",
      retier: :tooling
    }
  end

  @doc """
  Steps `finding` down one level when its module is one of `rows`'
  (`[mod, basis, permille]`, `mod` inspected), noting why; any other
  finding is returned as it is.

      iex> f = Argus.Findings.new(:error, "t", "d", at: Argus.Findings.at_module("Mix.Tasks.Seed"))
      iex> f = Argus.Findings.Tooling.retier(f, Argus.Findings.Tooling.index([["Mix.Tasks.Seed", "mix", "1000"]]))
      iex> {f.severity, f.provenance}
      {:warning, :structural}
  """
  @spec retier(map(), %{String.t() => {String.t(), 0..1000}}) :: map()
  def retier(%{module: module} = finding, index) when not is_nil(module) do
    case Map.fetch(index, inspect(module)) do
      {:ok, {basis, _p}} -> structural(finding, basis)
      :error -> finding
    end
  end

  def retier(finding, _index), do: finding

  @doc "The `tooling` rows by module, as `retier/2` reads them."
  @spec index([[String.t()]]) :: %{String.t() => {String.t(), 0..1000}}
  def index(rows) do
    Enum.reduce(rows, %{}, fn [mod, basis, p], acc ->
      Map.put_new(acc, mod, {basis, String.to_integer(p)})
    end)
  end

  defp structural(finding, basis) do
    %{
      finding
      | severity: step_down(finding.severity),
        help: finding.help ++ ["tooling: #{Map.get(@basis, basis, basis)}"]
    }
  end

  defp step_down(:error), do: :warning
  defp step_down(_warning_or_info), do: :info
end
