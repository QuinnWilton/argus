defmodule Argus.Analysis.Sets do
  @moduledoc """
  The concern vocabulary, the named sets of analyses, and how a
  selection (`Argus.Findings.run/2`'s `:analyses`) resolves to modules.

  An analysis answers "what goes wrong". Mechanism (rpc vs
  GenServer.call), phase (init vs terminate) and proximity (export vs
  request-direct) are columns on a relation, never separate analyses; a
  defect has one owner. The concerns below are that axis, and every
  built-in analysis is named after one.

  A set names analyses a caller runs together: `:all` (every built-in
  but `:coverage`, which measures the extractor pipeline rather than the
  analyzed code), `:default` (what scry runs without configuration),
  `:security`, `:effects` and `:otp` (everything else). A selection is a
  set or a list of concern names; a name that is not a built-in is an
  unknown analysis.

  `Argus.Analysis` delegates `concerns/0`, `sets/0` and `set/1` here.
  """

  alias Argus.Analysis.Catalog

  @concerns [
    :startup,
    :shutdown,
    :blocking,
    :coupling,
    :mailbox,
    :failure,
    :structure,
    :races,
    :state_machine,
    :ets,
    :effects,
    :unsafe_input,
    :exposure,
    :coverage
  ]

  @doc "The concern vocabulary: every built-in analysis is named after one."
  @spec concerns() :: [atom()]
  def concerns, do: @concerns

  @doc """
  The named sets of analyses `Argus.run_analyses/2` accepts in place of a
  list: `:all` (every built-in but `:coverage`, which measures the
  extractor pipeline rather than the code), `:default` (what scry runs
  without configuration), `:security`, `:effects` and `:otp` (everything
  else).
  """
  @spec sets() :: %{atom() => [atom()]}
  def sets do
    all = Catalog.names() -- [:coverage]
    security = Enum.filter([:unsafe_input, :exposure], &(&1 in all))
    effects = Enum.filter([:effects], &(&1 in all))

    %{
      all: all,
      default: Enum.filter(default_set(), &(&1 in all)),
      security: security,
      effects: effects,
      otp: all -- (security ++ effects)
    }
  end

  # What scry runs unconfigured: the OTP concerns whose findings are
  # structural and low-noise enough to report on every compile. effects,
  # ets, blocking and the security concerns are asked for by name.
  # unsafe_input stays out: a sink a request reaches is worth a compile's
  # attention, but its atom creation no request reaches — reported where
  # a caller's input reaches it, 65 rows over the evaluation programs
  # (four apps, the Phoenix stack, OTP kernel, stdlib and mnesia) where
  # "reachable from an export" was 261 — is still mostly library API
  # doing what it is for (erl_scan, a generator, a cache naming its
  # processes), with a few real finds among it (a dependency's vulnerable
  # tesla adapter, an Ecto type casting any string to an atom). races
  # is here because its rows are few and real: over the closed-issue
  # corpus and four large programs, one registry race (tesla's), ETS
  # races in postgrex, hammer, ztlp and blockster and OTP's own mnesia
  # internals, Mnesia races in blockster and ztlp — each a read deciding
  # a write another process can interleave.
  defp default_set do
    [
      :startup,
      :coupling,
      :shutdown,
      :structure,
      :races,
      :failure,
      :mailbox
    ]
  end

  @doc "The analyses in a named set: `{:ok, names}` or `:error`."
  @spec set(atom()) :: {:ok, [atom()]} | :error
  def set(name) when is_atom(name), do: Map.fetch(sets(), name)

  @doc """
  The analysis modules a selection names, each once, in the order first
  asked for. A selection is a set name or a list of analysis names; an
  unknown name is `{:error, {:unknown_analysis, name}}`, anything else
  `{:error, {:invalid_analyses, selection}}`.

      iex> Argus.Analysis.Sets.resolve([:mailbox, :startup, :mailbox])
      {:ok, [Argus.Analyses.Mailbox, Argus.Analyses.Startup]}

      iex> Argus.Analysis.Sets.resolve([:supervision])
      {:error, {:unknown_analysis, :supervision}}

      iex> Argus.Analysis.Sets.resolve(:nope)
      {:error, {:invalid_analyses, :nope}}
  """
  @spec resolve(atom() | [atom()] | term()) :: {:ok, [module()]} | {:error, term()}
  def resolve(set) when is_atom(set) do
    case set(set) do
      {:ok, names} -> resolve(names)
      :error -> {:error, {:invalid_analyses, set}}
    end
  end

  def resolve(names) when is_list(names) do
    names
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
      case Catalog.fetch(name) do
        {:ok, mod} -> {:cont, {:ok, [mod | acc]}}
        :error -> {:halt, {:error, {:unknown_analysis, name}}}
      end
    end)
    |> case do
      {:ok, mods} -> {:ok, mods |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  def resolve(other), do: {:error, {:invalid_analyses, other}}
end
