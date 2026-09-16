defmodule Mix.Tasks.Argus.Gen.Dl do
  @shortdoc "Regenerates the Souffle fact declarations from Argus.Schema"

  @moduledoc """
  Writes `priv/dl/base.dl` and `priv/dl/layer2.dl` from `Argus.Schema`.

  Fact declarations are positional: `.decl remote_call(id: symbol, mod:
  symbol, ...)` has to agree with the column order `Argus.Pipeline.Emit`
  writes. Souffle cannot check that — a field swapped between two `symbol`
  columns parses fine and silently joins the wrong values — so the
  declarations were the one part of the schema with no mechanical link back
  to it, maintained by hand in 95 places across 19 files.

      mix argus.gen.dl           # rewrite the generated files
      mix argus.gen.dl --check   # verify they match; exit 1 if not

  `--check` is what the test suite runs. Editing a relation in
  `Argus.Schema` and forgetting to regenerate fails the build rather than
  producing facts that decode wrongly.
  """

  use Mix.Task

  alias Argus.Schema

  @targets [
    {:layer_1, "base.dl"},
    {:layer_2, "layer2.dl"}
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [check: :boolean])
    check? = Keyword.get(opts, :check, false)

    results = Enum.map(@targets, &process(&1, check?))

    if check? do
      case Enum.reject(results, &match?({:ok, _}, &1)) do
        [] ->
          Mix.shell().info("dl declarations are up to date (schema v#{Schema.version()})")

        stale ->
          Mix.raise("""
          Generated Souffle declarations are stale:

          #{Enum.map_join(stale, "\n", fn {_, path, why} -> "  #{path} — #{why}" end)}

          Run `mix argus.gen.dl` and commit the result.
          """)
      end
    end
  end

  defp process({layer, filename}, check?) do
    path = target_path(filename)
    expected = Schema.souffle_decls(layer)

    cond do
      not check? ->
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, expected)
        Mix.shell().info("wrote #{Path.relative_to_cwd(path)}")
        {:ok, path}

      not File.exists?(path) ->
        {:stale, path, "missing"}

      File.read!(path) != expected ->
        {:stale, path, "does not match Argus.Schema"}

      true ->
        {:ok, path}
    end
  end

  # Deliberately the source tree, not `:code.priv_dir/1`. Mix links a
  # project's priv into _build, so writing through the code path would
  # either edit the source by way of a symlink or silently write somewhere
  # that gets overwritten on the next compile — neither is a thing to leave
  # ambiguous for a task whose whole job is keeping a checked-in file
  # truthful. Regenerating only makes sense in argus's own tree.
  defp target_path(filename) do
    unless Mix.Project.config()[:app] == :panoptes do
      Mix.raise(
        "mix argus.gen.dl regenerates argus's own checked-in declarations and " <>
          "must be run from the argus project, not from a project that depends on it."
      )
    end

    Path.join([File.cwd!(), "priv", "dl", filename])
  end
end
