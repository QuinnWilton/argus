defmodule Argus.Project.Scan do
  @moduledoc """
  Beam discovery and change detection for the driver.

  `scan/2` globs the program's ebins (`Argus.Project`, and its
  dependencies' when `include_deps` is set) into a `module => beam_path`
  map, applying module-level ignores at discovery so ignored modules are
  never even extracted. Ignored modules are still watched: a caller's
  extraction reads their specs (`Argus.Graph` tracks those callers
  through the `:ignored_beam` input).

  The driver syncs what a scan found into the graph's inputs itself
  (`Roux.Sources.sync/5`, `Argus.Driver`).
  """

  @typedoc """
  A module found in more than one ebin: the beam analyzed, and the ones
  passed over.
  """
  @type duplicate :: %{module: module(), used: String.t(), shadowed: [String.t()]}

  @typedoc """
  What a scan found: the modules to analyze, the modules the `ignore`
  patterns matched (`module => beam_path`, the first ebin's again), and
  the duplicates among the analyzed.
  """
  @type scan :: %{
          modules: %{optional(module()) => String.t()},
          ignored: %{optional(module()) => String.t()},
          duplicates: [duplicate()]
        }

  @typedoc """
  A project's scan, with the applications whose ebins it read (`apps`):
  the scan watches their beams, so the environment fingerprint leaves
  them out.
  """
  @type project_scan :: %{
          modules: %{optional(module()) => String.t()},
          ignored: %{optional(module()) => String.t()},
          duplicates: [duplicate()],
          apps: [atom()]
        }

  @doc """
  Discovers the beams to analyze: `module => beam_path` over the
  project's program (`Argus.Project` `apps`; the current Mix project's by
  default) and, with `include_deps`,
  its dependencies, plus the ignored modules (the configuration's, and
  the ones the build tool generates), every module more than one ebin
  defines, and the applications whose ebins were read.
  """
  @spec scan(Argus.Config.t(), Argus.Project.t()) :: project_scan()
  def scan(config, project \\ Argus.Project.Mix.current())

  def scan(%Argus.Config{} = config, %Argus.Project{} = project) do
    ebins = if config.include_deps, do: project.apps ++ project.deps, else: project.apps

    ebins
    |> Enum.map(&elem(&1, 1))
    |> discover(config.ignore_modules ++ project.generated)
    |> Map.put(:apps, ebins |> Enum.map(&elem(&1, 0)) |> Enum.uniq())
  end

  @doc """
  The beams in `ebins`, minus the modules `ignore` matches (regexes over
  the inspected name, or module atoms), which are returned apart.

  A module defined in more than one ebin is taken from the first that
  has it — callers list the project's own ebin first and the rest in a
  fixed order — and reported as a duplicate, never resolved by whichever
  directory happened to be read last.
  """
  @spec discover([String.t()], [Regex.t() | module()]) :: scan()
  def discover(ebins, ignore) do
    {skipped, found} =
      for ebin <- ebins,
          path <- ebin |> Path.join("*.beam") |> Path.wildcard() |> Enum.sort(),
          module = module_of(path) do
        {module, path}
      end
      |> Enum.split_with(fn {module, _path} -> ignored_module?(module, ignore) end)

    by_module = Enum.group_by(found, &elem(&1, 0), &elem(&1, 1))

    duplicates =
      for {module, [used | shadowed]} <- Enum.sort(by_module), shadowed != [] do
        %{module: module, used: used, shadowed: shadowed}
      end

    %{
      modules: Map.new(by_module, fn {module, [path | _]} -> {module, path} end),
      # The first ebin's, as for the analyzed: that is the one on the code
      # path ahead of the others.
      ignored: skipped |> Enum.reverse() |> Map.new(),
      duplicates: duplicates
    }
  end

  # basename → module. `String.to_atom`, not `to_existing_atom`: the
  # env-scoped ebin the compiler chain just wrote is authoritative (this
  # is not `mix argus`'s cross-env glob), and the atom count is bounded
  # by project size.
  defp module_of(path) do
    path |> Path.basename(".beam") |> String.to_atom()
  end

  # A regex matches a module by its name as Elixir spells it
  # (`MyApp.Gen`, `:my_gen`) or as Erlang does (`my_gen`).
  defp ignored_module?(module, patterns) do
    names = Enum.uniq([inspect(module), Atom.to_string(module)])

    Enum.any?(patterns, fn
      %Regex{} = regex -> Enum.any?(names, &Regex.match?(regex, &1))
      atom when is_atom(atom) -> atom == module
    end)
  end
end
