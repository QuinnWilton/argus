defmodule Argus.Extractors.Tooling do
  @moduledoc """
  Modules only developers' tools or tests run, as the module's name and
  the path it was compiled from say.

  A dev or test build compiles more than the product: Mix tasks and the
  helpers they share, a project's test support (`elixirc_paths(:dev)`
  often lists `test/support`), and the test helpers a library ships
  inside its own `lib/` (`Phoenix.ConnTest`, `Phoenix.LiveViewTest`,
  `Plug.Adapters.Test.Conn`). A defect there costs a developer's command
  or a test run, and every analysis steps it down
  (`Argus.Findings.Tooling`).

  ## Emitted facts

  - `tooling_module(mod, "mix")` — an Elixir module under `Mix.`: a
    task, a generator's helper, a compiler. Mix loads it; a release does
    not ship Mix.
  - `tooling_module(mod, "test_support")` — compiled from a file under a
    `test` directory that is either followed by `support`
    (`test/support/conn_case.ex`) or sits within three directories of a
    `lib` (`lib/phoenix_live_view/test/client_proxy.ex`), with no
    `lib`, `src`, `apps`, `deps` or `_build` directory below it. A
    checkout under a directory named `test` (`/ci/test/app/lib/x.ex`)
    has `lib` below it and is not; nor is a project's `test/fixtures`,
    whose modules stand for the product in its own tests.

  The path is the one `compile_info` records; a beam built without it
  (`+deterministic`) says nothing about its path.
  """

  @behaviour Argus.Extractor

  import Argus.Extractor.Facts, only: [add_fact: 3]

  @nested ~w(lib src apps deps _build)

  @impl true
  def relations, do: [:tooling_module]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    mod = inspect(module_data.module)

    cond do
      String.starts_with?(mod, "Mix.") -> add_fact(%{}, :tooling_module, [mod, "mix"])
      test_support?(source(module_data)) -> add_fact(%{}, :tooling_module, [mod, "test_support"])
      true -> %{}
    end
  end

  @doc false
  # Whether a source path is test support by its directories (see the
  # moduledoc); public for its unit test.
  @spec test_support?(String.t() | nil) :: boolean()
  def test_support?(nil), do: false

  def test_support?(path) do
    dirs = path |> Path.split() |> Enum.drop(-1)

    dirs
    |> Enum.with_index()
    |> Enum.any?(fn
      {"test", i} ->
        below = Enum.drop(dirs, i + 1)
        above = dirs |> Enum.take(i) |> Enum.take(-3)

        not Enum.any?(below, &(&1 in @nested)) and
          (List.first(below) == "support" or "lib" in above)

      _ ->
        false
    end)
  end

  # The source path compile_info records, read from the beam the
  # pipeline disassembled.
  defp source(module_data) do
    with {:ok, beam} <- beam(module_data),
         {:ok, {_mod, [compile_info: info]}} <- :beam_lib.chunks(beam, [:compile_info]),
         source when is_list(source) <- Keyword.get(info, :source) do
      List.to_string(source)
    else
      _ -> nil
    end
  end

  defp beam(%{beam: beam}) when is_binary(beam) do
    cond do
      BeamSpy.BeamFile.beam_data?(beam) -> {:ok, beam}
      File.regular?(beam) -> {:ok, String.to_charlist(beam)}
      true -> :error
    end
  end

  defp beam(%{module: mod}) do
    case :code.which(mod) do
      path when is_list(path) -> {:ok, path}
      _ -> :error
    end
  end
end
