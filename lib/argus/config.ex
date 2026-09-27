defmodule Argus.Config do
  @moduledoc """
  A project's argus configuration, validated loudly, wherever it was
  written.

  One validator (`load/2`) reads every source (`Argus.Config.Source`):

  | Project | Where |
  |---|---|
  | Mix | `argus:` in `mix.exs`'s `project/0` |
  | rebar3 | `{argus, [...]}` in `rebar.config` (consulted, never evaluated) |
  | Gleam, erlang.mk, bare beams | `argus.config`, a file of Erlang terms |

  In Elixir:

      def project do
        [
          compilers: Mix.compilers() ++ [:argus],
          argus: [
            analyses: [:coupling, :mailbox],
            severity: [mailbox: :error],
            ignore: [modules: [~r/^MyApp\\.Gen/], files: ["lib/legacy/**"]],
            include_deps: false,
            fail_on: :error,
            souffle: :warn
          ]
        ]
      end

  In Erlang terms (`rebar.config`, or `argus.config` without the outer
  tuple — a list, or one `{Key, Value}` term per key):

      {argus, [
          {analyses, [coupling, mailbox]},
          {severity, [{mailbox, error}]},
          {ignore, [{modules, [my_gen, "^my_app_gen_"]}, {files, ["src/legacy/**"]}]}
      ]}.

  Every key is optional. `analyses` defaults to argus's `:default` set
  (`Argus.Graph.default_analyses/0`); a name is validated against the
  registry, so a typo stops the run instead of silently analyzing
  nothing. A named set (`:all`, `:default`, `:otp`, `:security`,
  `:effects`) stands for its members. Findings report under their
  analysis's code (`[argus.mailbox]`).

  Severity overrides are keyed the same way: an analysis or a set (each
  member takes the severity); later entries win. `ignore: [modules: ...]`
  takes module names and regexes (in Erlang terms, a string is a regex),
  matched against a module's name (`MyApp.Gen`, `my_app_gen`) — ignored
  modules are never extracted; `ignore: [files: ...]` takes globs over
  the paths findings are reported at — the findings in those files are
  left out, while their facts still feed every analysis.

  Every key, at every level, is validated: an invalid entry raises
  `Argus.ConfigError` naming where it is (in its source's own syntax),
  what was expected, and the valid name it most resembles. A finding's
  relation written where its analysis goes (`:registry_race`) names the
  analysis that reports it, and a name argus retired in 0.17 and
  stopped reading in 0.20 (`:sync_call_in_init`, `:supervision`) names
  the concerns its findings went to. Configuration under scry's name
  (`scry:`, or the `:scry` compiler) raises with the rename.
  """

  alias Argus.ConfigError

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
  defstruct @enforce_keys

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

  @typedoc """
  Where a configuration was written: a keyword handed in (`:inline`),
  the command line (`:cli`), a Mix project (its `mix.exs`), a
  `rebar.config`, or an `argus.config` of Erlang terms. It decides how
  an error spells the entry it points at.
  """
  @type origin :: :inline | :cli | {:mix, Path.t()} | {:rebar3, Path.t()} | {:file, Path.t()}

  @severities [:error, :warning, :info]
  @keys [:analyses, :severity, :ignore, :include_deps, :fail_on, :souffle, :priors]
  @ignore_keys [:modules, :files]

  # Keys the rebar3 plugin reads from `{argus_plugin, [...]}`: written
  # under `{argus, [...]}`, they are in the wrong tuple.
  @plugin_keys [:escript, :version]

  @doc """
  Loads and validates the current Mix project's `argus:` keyword
  (`Argus.Config.Source.mix/0`).
  """
  @spec load() :: t()
  def load do
    {raw, origin} = Argus.Config.Source.mix()
    load(raw, origin)
  end

  @doc """
  Validates a raw configuration — a keyword list, or its Erlang-term
  spelling (a proplist, strings as charlists) — into a config. Raises
  `Argus.ConfigError` naming the offending entry, what was expected
  there, and the closest valid name when it looks like a typo.
  """
  @spec load(keyword() | term(), origin()) :: t()
  def load(raw, origin \\ :inline) do
    ctx = ConfigError.context(origin)
    raw = keyword!(ctx, [], raw, "config must be a keyword list")
    unknown_keys!(ctx, [], raw, @keys)

    ignore =
      keyword!(ctx, [:ignore], Keyword.get(raw, :ignore, []), "ignore must be a keyword list")

    unknown_keys!(ctx, [:ignore], ignore, @ignore_keys)

    %__MODULE__{
      analyses: analyses!(ctx, Keyword.get(raw, :analyses, Argus.Graph.default_analyses())),
      severity: severity!(ctx, Keyword.get(raw, :severity, [])),
      ignore_modules: ignore_modules!(ctx, Keyword.get(ignore, :modules, [])),
      ignore_files: ignore_files!(ctx, Keyword.get(ignore, :files, [])),
      include_deps: boolean!(ctx, :include_deps, Keyword.get(raw, :include_deps, false)),
      fail_on: enum!(ctx, [:fail_on], Keyword.get(raw, :fail_on, :error), [:error, :warning]),
      souffle: enum!(ctx, [:souffle], Keyword.get(raw, :souffle, :warn), [:warn, :require]),
      priors: priors!(ctx, Keyword.get(raw, :priors, :off))
    }
  end

  @doc """
  The analyses `names` select — concerns and sets, validated as
  `analyses:` is — for a caller that names them apart from the rest of
  the configuration (the command line).
  """
  @spec analyses([atom()], origin()) :: [atom()]
  def analyses(names, origin \\ :cli), do: analyses!(ConfigError.context(origin), names)

  @doc "Every analysis argus can run, sorted: `--all`."
  @spec all_analyses() :: [atom()]
  def all_analyses do
    Argus.Analysis.builtin_analysis_modules()
    |> Enum.reject(&(&1.name() == :coverage))
    |> Enum.map(& &1.name())
    |> Enum.sort()
  end

  defp keyword!(ctx, key, value, expected) do
    if Keyword.keyword?(value),
      do: value,
      else: fail(ctx, key, value, "#{expected}, got: #{show(ctx, value)}")
  end

  defp unknown_keys!(ctx, key, keyword, known) do
    case Enum.find(Keyword.keys(keyword), &(&1 not in known)) do
      nil ->
        :ok

      unknown ->
        fail(
          ctx,
          key ++ [unknown],
          unknown,
          "unknown #{describe(key)}key #{show(ctx, unknown)}; known: #{show(ctx, known)}" <>
            plugin_hint(ctx, key, unknown),
          known
        )
    end
  end

  defp plugin_hint(%{origin: {:rebar3, _}}, [], key) when key in @plugin_keys,
    do: "; the rebar3 plugin's own keys go under {argus_plugin, [...]}"

  defp plugin_hint(_ctx, _key, _unknown), do: ""

  defp describe([]), do: ""
  defp describe(key), do: Enum.map_join(key, " ", &to_string/1) <> " "

  @prior_modes [:off, :cached_only, :live]
  @prior_opts [:cassette, :cache_dir, :model, :oracle, :oracle_opts, :batch_size, :concurrency]

  defp priors!(ctx, mode) when mode in @prior_modes, do: priors!(ctx, mode: mode)

  defp priors!(ctx, raw) when is_list(raw) do
    raw = keyword!(ctx, [:priors], raw, "priors must be a mode or a keyword with mode:")
    mode = enum!(ctx, [:priors, :mode], Keyword.get(raw, :mode, :off), @prior_modes)
    opts = Keyword.delete(raw, :mode)
    unknown_keys!(ctx, [:priors], opts, @prior_opts)

    opts =
      Enum.map(opts, fn
        {key, value} when key in [:cassette, :cache_dir, :model] and value != nil ->
          {key, string!(ctx, [:priors, key], value, "priors #{key} must be a string")}

        other ->
          other
      end)

    # A run that cannot ask fails at configuration, not after extraction.
    Argus.Priors.check!(priors: mode, priors_opts: Keyword.drop(opts, [:cassette]))
    %{mode: mode, opts: opts}
  end

  defp priors!(ctx, other) do
    fail(
      ctx,
      [:priors],
      other,
      "priors must be #{show(ctx, :off)}, #{show(ctx, :cached_only)}, #{show(ctx, :live)} " <>
        "or a keyword with mode:, got: #{show(ctx, other)}",
      @prior_modes
    )
  end

  defp analyses!(ctx, names) when is_list(names) do
    known = known_analyses()

    case Enum.find(names, &(not (is_atom(&1) and resolvable?(&1, known)))) do
      nil ->
        names |> Enum.flat_map(&resolve/1) |> Enum.uniq()

      unknown ->
        unknowns = Enum.reject(names, &(is_atom(&1) and resolvable?(&1, known)))

        unknown_name!(
          ctx,
          [:analyses],
          unknown,
          "unknown analyses #{show(ctx, unknowns)}; available: #{show(ctx, Enum.sort(known))}, " <>
            "or a set: #{show(ctx, Enum.sort(Map.keys(Argus.Analysis.sets())))}",
          known
        )
    end
  end

  defp analyses!(ctx, other),
    do:
      fail(ctx, [:analyses], other, "analyses must be a list of atoms, got: #{show(ctx, other)}")

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

  # The names argus retired in 0.17 (and stopped reading in 0.20), each
  # with the concerns its findings went to, as the alias table removed
  # then (632b69ba, `Argus.Analysis.aliases/0`) sent each entry.
  @retired %{
    atom_safety: [:unsafe_input],
    request_surface: [:unsafe_input],
    unbounded_dynamic_children: [:unsafe_input],
    secret_exposure: [:exposure],
    tls_verification: [:exposure],
    purity: [:effects],
    transaction_safety: [:effects],
    timeout_chain: [:blocking],
    call_cycle: [:blocking],
    process_bottleneck: [:blocking],
    callback_receive: [:blocking],
    one_for_one_coupling: [:coupling],
    sync_call_in_init: [:startup],
    deferred_startup_deadlock: [:blocking, :startup],
    shutdown_safety: [:shutdown],
    supervision: [:coupling, :structure, :startup, :shutdown],
    distributed: [:blocking, :structure, :startup, :failure],
    unlinked_spawn: [:failure],
    process_registry: [:structure, :failure],
    error_handling: [:blocking, :startup, :shutdown, :failure, :mailbox],
    unsafe_task: [:failure, :mailbox],
    monitor_leak: [:shutdown, :mailbox],
    message_contract: [:mailbox],
    reply_contract: [:mailbox],
    gen_statem: [:mailbox, :state_machine]
  }

  @doc false
  # The retired names and their concerns, for the tests.
  @spec retired() :: %{atom() => [atom()]}
  def retired, do: @retired

  # An unknown name is most often a typo of a concern or a set, the name
  # of a finding written where its analysis goes (an output relation,
  # `:registry_race`, whose owner is the name that was meant), or a name
  # argus retired in 0.17 (whose concerns are).
  @spec unknown_name!(ConfigError.context(), [atom()], term(), String.t(), [atom()]) ::
          no_return()
  defp unknown_name!(ctx, key, name, expected, known) do
    candidates = selectable(known)
    owner = relation_owner(name)

    case {ConfigError.closest(name, candidates), owner, Map.fetch(@retired, name)} do
      {_closest, {^name, owner}, retired} ->
        fail(
          ctx,
          key,
          name,
          expected <>
            "; #{show(ctx, name)} is a finding of the #{show(ctx, owner)} analysis, " <>
            "did you mean #{show(ctx, owner)}?" <> retired_too(ctx, name, owner, retired)
        )

      {_closest, _owner, {:ok, [concern]}} ->
        fail(
          ctx,
          key,
          name,
          expected <>
            "; argus retired #{show(ctx, name)} in 0.17, and its findings are the " <>
            "#{show(ctx, concern)} analysis's: did you mean #{show(ctx, concern)}?"
        )

      {_closest, _owner, {:ok, concerns}} ->
        fail(
          ctx,
          key,
          name,
          expected <>
            "; argus retired #{show(ctx, name)} in 0.17, and its findings are reported by " <>
            "the #{Enum.map_join(concerns, ", ", &show(ctx, &1))} analyses: name those instead"
        )

      {nil, {relation, owner}, :error} ->
        fail(
          ctx,
          key,
          name,
          expected <>
            "; #{show(ctx, relation)} is a finding of the #{show(ctx, owner)} analysis, " <>
            "did you mean #{show(ctx, owner)}?"
        )

      {_closest, _owner, :error} ->
        fail(ctx, key, name, expected, candidates)
    end
  end

  # A finding's relation whose name argus also retired as an analysis's
  # (`:monitor_leak`, a relation of `:mailbox` since 0.20): what the
  # retired name reported went to other concerns as well.
  defp retired_too(ctx, name, owner, {:ok, concerns}) when concerns != [owner] do
    " (argus retired #{show(ctx, name)} as an analysis in 0.17; its findings then went to " <>
      "the #{Enum.map_join(concerns, ", ", &show(ctx, &1))} analyses)"
  end

  defp retired_too(_ctx, _name, _owner, _retired), do: ""

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
        else: ConfigError.closest(name, Map.keys(owners))

    if relation, do: {relation, Map.fetch!(owners, relation)}
  end

  defp relation_owner(_name), do: nil

  # Keys name what `analyses:` accepts: a concern or a set (every member
  # takes the severity). Later entries win, so `[default: :warning, mailbox:
  # :error]` raises one concern above the rest of its set.
  defp severity!(ctx, pairs) when is_list(pairs) do
    known = known_analyses()

    ctx
    |> keyword!([:severity], pairs, "severity must be a keyword list")
    |> Enum.flat_map(fn {analysis, severity} ->
      unless severity in @severities do
        fail(
          ctx,
          [:severity, analysis],
          severity,
          "severity must be one of #{show(ctx, @severities)}, got: #{show(ctx, severity)}",
          @severities
        )
      end

      unless resolvable?(analysis, known) do
        unknown_name!(
          ctx,
          [:severity, analysis],
          analysis,
          "severity names unknown analysis #{show(ctx, analysis)}; available: " <>
            "#{show(ctx, Enum.sort(known))}, or a set: " <>
            "#{show(ctx, Enum.sort(Map.keys(Argus.Analysis.sets())))}",
          known
        )
      end

      Enum.map(resolve(analysis), &{&1, severity})
    end)
    |> Map.new()
  end

  defp severity!(ctx, other),
    do: fail(ctx, [:severity], other, "severity must be a keyword list, got: #{show(ctx, other)}")

  defp ignore_modules!(ctx, patterns) when is_list(patterns) do
    Enum.map(patterns, fn
      %Regex{} = regex ->
        regex

      atom when is_atom(atom) ->
        atom

      other ->
        source =
          string!(
            ctx,
            [:ignore, :modules],
            other,
            "ignore modules must be regexes, strings (a regex's source) or module atoms"
          )

        case Regex.compile(source) do
          {:ok, regex} ->
            regex

          {:error, {reason, at}} ->
            fail(
              ctx,
              [:ignore, :modules],
              other,
              "ignore modules: #{show(ctx, other)} is not a regex: #{reason} at #{at}"
            )
        end
    end)
  end

  defp ignore_modules!(ctx, other),
    do:
      fail(
        ctx,
        [:ignore, :modules],
        other,
        "ignore modules must be a list, got: #{show(ctx, other)}"
      )

  defp ignore_files!(ctx, globs) when is_list(globs) do
    Enum.map(globs, &string!(ctx, [:ignore, :files], &1, "ignore files must be glob strings"))
  end

  defp ignore_files!(ctx, other),
    do:
      fail(ctx, [:ignore, :files], other, "ignore files must be a list, got: #{show(ctx, other)}")

  # A string, as Elixir writes one or as Erlang does (a charlist).
  defp string!(_ctx, _key, value, _expected) when is_binary(value), do: value

  defp string!(ctx, key, value, expected) do
    if is_list(value) and value != [] and :io_lib.printable_unicode_list(value) do
      List.to_string(value)
    else
      fail(ctx, key, value, "#{expected}, got: #{show(ctx, value)}")
    end
  end

  defp boolean!(_ctx, _key, value) when is_boolean(value), do: value

  defp boolean!(ctx, key, value),
    do: fail(ctx, [key], value, "#{key} must be a boolean, got: #{show(ctx, value)}")

  defp enum!(ctx, key, value, allowed) do
    if value in allowed do
      value
    else
      fail(
        ctx,
        key,
        value,
        "#{Enum.join(key, " ")} must be one of #{show(ctx, allowed)}, got: #{show(ctx, value)}",
        allowed
      )
    end
  end

  defp show(ctx, term), do: ConfigError.show(ctx, term)

  @spec fail(ConfigError.context(), [atom()], term(), String.t()) :: no_return()
  defp fail(ctx, key, value, expected), do: fail(ctx, key, value, expected, [])

  @spec fail(ConfigError.context(), [atom()], term(), String.t(), [atom()]) :: no_return()
  defp fail(ctx, key, value, expected, candidates) do
    raise ConfigError.new(key, value, expected, candidates, ctx.origin)
  end
end
