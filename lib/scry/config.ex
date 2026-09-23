defmodule Scry.Config do
  @moduledoc """
  The `scry:` project configuration, validated loudly.

      def project do
        [
          compilers: Mix.compilers() ++ [:scry],
          scry: [
            analyses: [:coupling, :mailbox],
            severity: [mailbox: :error],
            ignore: [modules: [~r/^MyApp\\.Gen/], files: ["lib/legacy/**"]],
            include_deps: false,
            fail_on: :error,
            souffle: :warn
          ]
        ]
      end

  Every key is optional. `analyses` defaults to the shared layer's
  curated quiet set (`Scry.Analysis.default_analyses/0`, argus's
  `:default` set); analysis names are validated against the argus
  registry so a typo aborts the compile instead of silently analyzing
  nothing. A named set (`:all`, `:default`, `:otp`, `:security`,
  `:effects`) stands for its members. A name argus retired when it
  regrouped its analyses by concern (0.17: `:supervision`,
  `:unsafe_task`, ...) still loads: it expands to the concerns its
  findings live in now, with a notice, and those findings report under
  the concern's code — `[scry.mailbox]`, not `[scry.unsafe_task]`.
  Severity overrides keyed by a retired name follow it.
  """

  @enforce_keys [
    :analyses,
    :severity,
    :ignore_modules,
    :ignore_files,
    :include_deps,
    :fail_on,
    :souffle,
    :priors
  ]
  defstruct [
    :analyses,
    :severity,
    :ignore_modules,
    :ignore_files,
    :include_deps,
    :fail_on,
    :souffle,
    :priors
  ]

  @typedoc """
  `priors:` — `:off` (default), `:cached_only` or `:live`, or a keyword
  with `mode:` and `Argus.Priors` options (`cassette:` a JSONL file
  imported into the cache first, `cache_dir:`, `model:`, `oracle:`,
  `batch_size:`). See `Scry.Priors`.
  """
  @type priors :: %{mode: :off | :cached_only | :live, opts: keyword()}

  @type t :: %__MODULE__{
          analyses: [atom()],
          severity: %{optional(atom()) => :error | :warning | :info},
          ignore_modules: [Regex.t() | module()],
          ignore_files: [String.t()],
          include_deps: boolean(),
          fail_on: :error | :warning,
          souffle: :warn | :require,
          priors: priors()
        }

  @severities [:error, :warning, :info]

  @doc """
  Loads and validates the current project's `scry:` keyword.
  """
  @spec load() :: t()
  def load do
    load(Mix.Project.config()[:scry] || [])
  end

  @doc """
  Validates a raw `scry:` keyword list into a config.
  """
  @spec load(keyword()) :: t()
  def load(raw) when is_list(raw) do
    known_keys = [:analyses, :severity, :ignore, :include_deps, :fail_on, :souffle, :priors]

    case Keyword.keys(raw) -- known_keys do
      [] -> :ok
      unknown -> fail("unknown scry config #{inspect(unknown)}; known: #{inspect(known_keys)}")
    end

    ignore = Keyword.get(raw, :ignore, [])

    %__MODULE__{
      analyses: analyses!(Keyword.get(raw, :analyses, Scry.Analysis.default_analyses())),
      severity: severity!(Keyword.get(raw, :severity, [])),
      ignore_modules: ignore_modules!(Keyword.get(ignore, :modules, [])),
      ignore_files: ignore_files!(Keyword.get(ignore, :files, [])),
      include_deps: boolean!(:include_deps, Keyword.get(raw, :include_deps, false)),
      fail_on: enum!(:fail_on, Keyword.get(raw, :fail_on, :error), [:error, :warning]),
      souffle: enum!(:souffle, Keyword.get(raw, :souffle, :warn), [:warn, :require]),
      priors: priors!(Keyword.get(raw, :priors, :off))
    }
  end

  def load(other) do
    fail("scry config must be a keyword list, got: #{inspect(other)}")
  end

  @prior_modes [:off, :cached_only, :live]
  @prior_opts [:cassette, :cache_dir, :model, :oracle, :oracle_opts, :batch_size, :concurrency]

  defp priors!(mode) when mode in @prior_modes, do: priors!(mode: mode)

  defp priors!(raw) when is_list(raw) do
    mode = enum!(:priors, Keyword.get(raw, :mode, :off), @prior_modes)
    opts = Keyword.delete(raw, :mode)

    case Keyword.keys(opts) -- @prior_opts do
      [] ->
        :ok

      unknown ->
        fail("unknown priors options #{inspect(unknown)}; known: #{inspect(@prior_opts)}")
    end

    if mode != :off and not is_nil(Keyword.get(opts, :cassette)) and
         not is_binary(Keyword.get(opts, :cassette)) do
      fail("priors cassette must be a path, got: #{inspect(Keyword.get(opts, :cassette))}")
    end

    # A run that cannot ask fails at configuration, not after extraction.
    Argus.Priors.check!(priors: mode, priors_opts: Keyword.drop(opts, [:cassette]))
    %{mode: mode, opts: opts}
  end

  defp priors!(other) do
    fail(
      "priors must be :off, :cached_only, :live or a keyword with mode:, got: #{inspect(other)}"
    )
  end

  defp analyses!(names) when is_list(names) do
    known = known_analyses()

    case Enum.reject(names, &(is_atom(&1) and resolvable?(&1, known))) do
      [] ->
        names |> Enum.flat_map(&resolve(&1, known)) |> Enum.uniq()

      unknown ->
        fail(
          "unknown analyses #{inspect(unknown)}; available: #{inspect(Enum.sort(known))}, " <>
            "or a set: #{inspect(Enum.sort(Map.keys(Argus.Analysis.sets())))}"
        )
    end
  end

  defp analyses!(other), do: fail("analyses must be a list of atoms, got: #{inspect(other)}")

  defp known_analyses, do: Enum.map(Argus.Analysis.builtin_analysis_modules(), & &1.name())

  defp resolvable?(name, known) do
    name in known or match?({:ok, _}, Argus.Analysis.set(name)) or
      match?({:ok, _}, Argus.Analysis.alias(name))
  end

  # A concern is itself; a set is its members; a retired name is the
  # concerns its findings live in now, said once so the changed codes in
  # the output are not a surprise.
  defp resolve(name, known) do
    cond do
      name in known ->
        [name]

      match?({:ok, _}, Argus.Analysis.set(name)) ->
        {:ok, members} = Argus.Analysis.set(name)
        members

      true ->
        concerns = retired_concerns(name)

        Mix.shell().info(
          "scry: #{inspect(name)} is retired in argus 0.17; its findings live in " <>
            "#{Enum.map_join(concerns, ", ", &inspect/1)} and report under those codes"
        )

        concerns
    end
  end

  defp retired_concerns(name) do
    {:ok, entries} = Argus.Analysis.alias(name)
    entries |> Enum.map(& &1.analysis) |> Enum.uniq()
  end

  defp severity!(pairs) when is_list(pairs) do
    Enum.each(pairs, fn
      {analysis, severity} when is_atom(analysis) and severity in @severities ->
        :ok

      other ->
        fail(
          "severity entries must be {analysis, :error | :warning | :info}, " <>
            "got: #{inspect(other)}"
        )
    end)

    # An override keyed by a retired name applies to each concern its
    # findings moved to (the analyses notice already named them).
    pairs
    |> Enum.flat_map(fn {analysis, severity} ->
      case Argus.Analysis.alias(analysis) do
        {:ok, _} -> Enum.map(retired_concerns(analysis), &{&1, severity})
        :error -> [{analysis, severity}]
      end
    end)
    |> Map.new()
  end

  defp severity!(other), do: fail("severity must be a keyword list, got: #{inspect(other)}")

  defp ignore_modules!(patterns) when is_list(patterns) do
    Enum.each(patterns, fn
      %Regex{} -> :ok
      atom when is_atom(atom) -> :ok
      other -> fail("ignore modules must be regexes or module atoms, got: #{inspect(other)}")
    end)

    patterns
  end

  defp ignore_modules!(other), do: fail("ignore modules must be a list, got: #{inspect(other)}")

  defp ignore_files!(globs) when is_list(globs) do
    Enum.each(globs, fn
      glob when is_binary(glob) -> :ok
      other -> fail("ignore files must be glob strings, got: #{inspect(other)}")
    end)

    globs
  end

  defp ignore_files!(other), do: fail("ignore files must be a list, got: #{inspect(other)}")

  defp boolean!(_key, value) when is_boolean(value), do: value
  defp boolean!(key, value), do: fail("#{key} must be a boolean, got: #{inspect(value)}")

  defp enum!(key, value, allowed) do
    if value in allowed do
      value
    else
      fail("#{key} must be one of #{inspect(allowed)}, got: #{inspect(value)}")
    end
  end

  @spec fail(String.t()) :: no_return()
  defp fail(message), do: Mix.raise("scry: " <> message)
end
