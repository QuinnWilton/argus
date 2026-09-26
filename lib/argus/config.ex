defmodule Argus.Config do
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
  curated quiet set (`Argus.Graph.default_analyses/0`, argus's
  `:default` set); analysis names are validated against the argus
  registry so a typo aborts the compile instead of silently analyzing
  nothing. A named set (`:all`, `:default`, `:otp`, `:security`,
  `:effects`) stands for its members. Findings report under their
  concern's code (`[scry.mailbox]`).

  Severity overrides are keyed the same way: a concern or a set (each
  member takes the severity); later entries win. Every key, at every
  level, is validated: an invalid entry raises `Argus.ConfigError` naming
  where it is, what was expected, and the valid name it most resembles.
  A finding's relation written where its analysis goes (`:registry_race`,
  or `:call_cycle`, one of the names argus retired in 0.17 and dropped in
  0.20) names the analysis that reports it.
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
  `batch_size:`). See `Argus.Graph.Priors`.
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
  @keys [:analyses, :severity, :ignore, :include_deps, :fail_on, :souffle, :priors]
  @ignore_keys [:modules, :files]

  @doc """
  Loads and validates the current project's `scry:` keyword.
  """
  @spec load() :: t()
  def load do
    load(Mix.Project.config()[:scry] || [])
  end

  @doc """
  Validates a raw `scry:` keyword list into a config. Raises
  `Argus.ConfigError` naming the offending entry, what was expected
  there, and the closest valid name when it looks like a typo.
  """
  @spec load(keyword()) :: t()
  def load(raw) do
    raw = keyword!([], raw, "config must be a keyword list")
    unknown_keys!([], raw, @keys)

    ignore = keyword!([:ignore], Keyword.get(raw, :ignore, []), "ignore must be a keyword list")
    unknown_keys!([:ignore], ignore, @ignore_keys)

    %__MODULE__{
      analyses: analyses!(Keyword.get(raw, :analyses, Argus.Graph.default_analyses())),
      severity: severity!(Keyword.get(raw, :severity, [])),
      ignore_modules: ignore_modules!(Keyword.get(ignore, :modules, [])),
      ignore_files: ignore_files!(Keyword.get(ignore, :files, [])),
      include_deps: boolean!(:include_deps, Keyword.get(raw, :include_deps, false)),
      fail_on: enum!([:fail_on], Keyword.get(raw, :fail_on, :error), [:error, :warning]),
      souffle: enum!([:souffle], Keyword.get(raw, :souffle, :warn), [:warn, :require]),
      priors: priors!(Keyword.get(raw, :priors, :off))
    }
  end

  defp keyword!(key, value, expected) do
    if Keyword.keyword?(value),
      do: value,
      else: fail(key, value, "#{expected}, got: #{inspect(value)}")
  end

  defp unknown_keys!(key, keyword, known) do
    case Enum.find(Keyword.keys(keyword), &(&1 not in known)) do
      nil ->
        :ok

      unknown ->
        fail(
          key ++ [unknown],
          unknown,
          "unknown #{describe(key)}key #{inspect(unknown)}; known: #{inspect(known)}",
          known
        )
    end
  end

  defp describe([]), do: ""
  defp describe(key), do: Enum.map_join(key, " ", &to_string/1) <> " "

  @prior_modes [:off, :cached_only, :live]
  @prior_opts [:cassette, :cache_dir, :model, :oracle, :oracle_opts, :batch_size, :concurrency]

  defp priors!(mode) when mode in @prior_modes, do: priors!(mode: mode)

  defp priors!(raw) when is_list(raw) do
    raw = keyword!([:priors], raw, "priors must be a mode or a keyword with mode:")
    mode = enum!([:priors, :mode], Keyword.get(raw, :mode, :off), @prior_modes)
    opts = Keyword.delete(raw, :mode)
    unknown_keys!([:priors], opts, @prior_opts)

    cassette = Keyword.get(opts, :cassette)

    if mode != :off and not is_nil(cassette) and not is_binary(cassette) do
      fail(
        [:priors, :cassette],
        cassette,
        "priors cassette must be a path, got: #{inspect(cassette)}"
      )
    end

    # A run that cannot ask fails at configuration, not after extraction.
    Argus.Priors.check!(priors: mode, priors_opts: Keyword.drop(opts, [:cassette]))
    %{mode: mode, opts: opts}
  end

  defp priors!(other) do
    fail(
      [:priors],
      other,
      "priors must be :off, :cached_only, :live or a keyword with mode:, got: #{inspect(other)}",
      @prior_modes
    )
  end

  defp analyses!(names) when is_list(names) do
    known = known_analyses()

    case Enum.find(names, &(not (is_atom(&1) and resolvable?(&1, known)))) do
      nil ->
        names |> Enum.flat_map(&resolve/1) |> Enum.uniq()

      unknown ->
        unknowns = Enum.reject(names, &(is_atom(&1) and resolvable?(&1, known)))

        unknown_name!(
          [:analyses],
          unknown,
          "unknown analyses #{inspect(unknowns)}; available: #{inspect(Enum.sort(known))}, " <>
            "or a set: #{inspect(Enum.sort(Map.keys(Argus.Analysis.sets())))}",
          known
        )
    end
  end

  defp analyses!(other),
    do: fail([:analyses], other, "analyses must be a list of atoms, got: #{inspect(other)}")

  defp known_analyses, do: Enum.map(Argus.Analysis.builtin_analysis_modules(), & &1.name())

  # Every name a user may write where an analysis goes: a concern or a
  # set.
  defp selectable(known), do: known ++ Map.keys(Argus.Analysis.sets())

  defp resolvable?(name, known), do: name in known or match?({:ok, _}, Argus.Analysis.set(name))

  # A set is its members; anything else resolvable is a concern.
  defp resolve(name) do
    case Argus.Analysis.set(name) do
      {:ok, members} -> members
      :error -> [name]
    end
  end

  # An unknown name is most often a typo of a concern or a set, or the
  # name of a finding written where its analysis goes: an output relation
  # (`:registry_race`), which is also what many of the names argus
  # retired in 0.17 became (`:call_cycle`). The relation's owner is the
  # name that was meant.
  @spec unknown_name!([atom()], term(), String.t(), [atom()]) :: no_return()
  defp unknown_name!(key, name, expected, known) do
    candidates = selectable(known)

    case {Argus.ConfigError.closest(name, candidates), relation_owner(name)} do
      {nil, {relation, owner}} ->
        fail(
          key,
          name,
          expected <>
            "; #{inspect(relation)} is a finding of the #{inspect(owner)} analysis, " <>
            "did you mean #{inspect(owner)}?"
        )

      _ ->
        fail(key, name, expected, candidates)
    end
  end

  # The output relation `name` is, or most resembles, with its analysis.
  defp relation_owner(name) when is_atom(name) do
    owners =
      for mod <- Argus.Analysis.builtin_analysis_modules(),
          %{name: relation} <- mod.output_relations(),
          into: %{},
          do: {relation, mod.name()}

    relation =
      if Map.has_key?(owners, name),
        do: name,
        else: Argus.ConfigError.closest(name, Map.keys(owners))

    if relation, do: {relation, Map.fetch!(owners, relation)}
  end

  defp relation_owner(_name), do: nil

  # Keys name what `analyses:` accepts: a concern or a set (every member
  # takes the severity). Later entries win, so `[default: :warning, mailbox:
  # :error]` raises one concern above the rest of its set.
  defp severity!(pairs) when is_list(pairs) do
    known = known_analyses()

    [:severity]
    |> keyword!(pairs, "severity must be a keyword list")
    |> Enum.flat_map(fn {analysis, severity} ->
      unless severity in @severities do
        fail(
          [:severity, analysis],
          severity,
          "severity must be one of #{inspect(@severities)}, got: #{inspect(severity)}",
          @severities
        )
      end

      unless resolvable?(analysis, known) do
        unknown_name!(
          [:severity, analysis],
          analysis,
          "severity names unknown analysis #{inspect(analysis)}; available: " <>
            "#{inspect(Enum.sort(known))}, or a set: " <>
            "#{inspect(Enum.sort(Map.keys(Argus.Analysis.sets())))}",
          known
        )
      end

      Enum.map(resolve(analysis), &{&1, severity})
    end)
    |> Map.new()
  end

  defp severity!(other),
    do: fail([:severity], other, "severity must be a keyword list, got: #{inspect(other)}")

  defp ignore_modules!(patterns) when is_list(patterns) do
    Enum.each(patterns, fn
      %Regex{} ->
        :ok

      atom when is_atom(atom) ->
        :ok

      other ->
        fail(
          [:ignore, :modules],
          other,
          "ignore modules must be regexes or module atoms, got: #{inspect(other)}"
        )
    end)

    patterns
  end

  defp ignore_modules!(other),
    do: fail([:ignore, :modules], other, "ignore modules must be a list, got: #{inspect(other)}")

  defp ignore_files!(globs) when is_list(globs) do
    Enum.each(globs, fn
      glob when is_binary(glob) ->
        :ok

      other ->
        fail(
          [:ignore, :files],
          other,
          "ignore files must be glob strings, got: #{inspect(other)}"
        )
    end)

    globs
  end

  defp ignore_files!(other),
    do: fail([:ignore, :files], other, "ignore files must be a list, got: #{inspect(other)}")

  defp boolean!(_key, value) when is_boolean(value), do: value

  defp boolean!(key, value),
    do: fail([key], value, "#{key} must be a boolean, got: #{inspect(value)}")

  defp enum!(key, value, allowed) do
    if value in allowed do
      value
    else
      fail(
        key,
        value,
        "#{Enum.join(key, " ")} must be one of #{inspect(allowed)}, got: #{inspect(value)}",
        allowed
      )
    end
  end

  @spec fail([atom()], term(), String.t()) :: no_return()
  defp fail(key, value, expected), do: fail(key, value, expected, [])

  @spec fail([atom()], term(), String.t(), [atom()]) :: no_return()
  defp fail(key, value, expected, candidates) do
    raise Argus.ConfigError.new(key, value, expected, candidates)
  end
end
