defmodule Argus.Autoresearch.Config do
  @moduledoc """
  Loads and validates the `.autoresearch/config.exs` file.

  The config is an Elixir map (not JSON) so it supports comments and
  the loader can catch typos at read time via pattern matching. It's
  committed to the repo alongside the baseline so autoresearch runs
  are reproducible.

  ## Schema

      %{
        corpus_root: "~/dev/beam_box/sample_projects",
        tiers: %{
          "fast" => ~w(poolboy phoenix_pubsub plug jason bandit),
          "medium" => ~w(... more projects ...),
          "full" => :all
        },
        default_tier: "fast",
        canary_project: "poolboy",
        checks_barrier: [
          ["mix", ["format", "--check-formatted"]],
          ["mix", ["compile", "--warnings-as-errors"]],
          ["mix", ["test"]],
          ["mix", ["dialyzer"]]
        ],
        measure_concurrency: 4,
        measure_timeout_s: 300
      }

  ## Tier resolution

  A tier value is either a list of project directory names (relative
  to `corpus_root`) or the atom `:all`, meaning "every directory
  under `corpus_root` that contains a `mix.exs` or `rebar.config`".
  """

  @type tier_name :: String.t()
  @type project_name :: String.t()
  @type tier_value :: [project_name()] | :all

  @type command :: [String.t() | [String.t()]]

  @type t :: %__MODULE__{
          corpus_root: String.t(),
          tiers: %{tier_name() => tier_value()},
          default_tier: tier_name(),
          canary_project: project_name(),
          checks_barrier: [command()],
          measure_concurrency: pos_integer(),
          measure_timeout_s: pos_integer()
        }

  defstruct corpus_root: "~/dev/beam_box/sample_projects",
            tiers: %{"fast" => [], "full" => :all},
            default_tier: "fast",
            canary_project: nil,
            checks_barrier: [
              ["mix", ["format", "--check-formatted"]],
              ["mix", ["compile", "--warnings-as-errors"]],
              ["mix", ["test"]]
            ],
            measure_concurrency: 4,
            measure_timeout_s: 300

  @default_path ".autoresearch/config.exs"

  @doc """
  Returns the default path to the config file (relative to repo root).
  """
  @spec default_path() :: Path.t()
  def default_path, do: @default_path

  @doc """
  Loads and validates a config file at the given path (defaults to
  `.autoresearch/config.exs`).

  Returns `{:ok, config}` on success. Error reasons:
  - `:enoent` — file not found
  - `{:invalid, reason}` — file loaded but failed validation
  """
  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path \\ @default_path) do
    if File.exists?(path) do
      try do
        {raw, _bindings} = Code.eval_file(path)
        from_map(raw)
      rescue
        e -> {:error, {:eval_failed, Exception.message(e)}}
      end
    else
      {:error, :enoent}
    end
  end

  @doc """
  Builds a `%Config{}` from a raw map. Use directly when you have the
  config in-memory (e.g. for tests); prefer `load/1` for the committed
  file.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(raw) when is_map(raw) do
    with {:ok, corpus_root} <- fetch_string(raw, :corpus_root),
         {:ok, tiers} <- fetch_tiers(raw),
         {:ok, default_tier} <- fetch_string(raw, :default_tier),
         :ok <- validate_default_tier(default_tier, tiers),
         {:ok, checks_barrier} <- fetch_checks_barrier(raw),
         {:ok, concurrency} <- fetch_pos_int(raw, :measure_concurrency, 4),
         {:ok, timeout_s} <- fetch_pos_int(raw, :measure_timeout_s, 300) do
      {:ok,
       %__MODULE__{
         corpus_root: expand_path(corpus_root),
         tiers: tiers,
         default_tier: default_tier,
         canary_project: Map.get(raw, :canary_project),
         checks_barrier: checks_barrier,
         measure_concurrency: concurrency,
         measure_timeout_s: timeout_s
       }}
    end
  end

  def from_map(_), do: {:error, {:invalid, :not_a_map}}

  @doc """
  Resolves a tier name to a list of absolute project paths.

  Returns `{:ok, [{name, path}]}` on success, or `{:error, reason}` if
  the tier is unknown or the corpus root doesn't exist. Missing
  projects within a tier are **not** errors — they're returned as
  `{name, nil}` so callers can decide how to handle them (usually:
  skip and log).
  """
  @spec resolve_tier(t(), tier_name()) ::
          {:ok, [{project_name(), Path.t() | nil}]} | {:error, term()}
  def resolve_tier(%__MODULE__{} = config, tier_name) do
    with {:ok, tier} <- fetch_tier(config, tier_name),
         :ok <- ensure_corpus_root(config.corpus_root) do
      {:ok, resolve_projects(config.corpus_root, tier)}
    end
  end

  defp fetch_tier(%__MODULE__{tiers: tiers}, tier_name) do
    case Map.fetch(tiers, tier_name) do
      {:ok, tier} -> {:ok, tier}
      :error -> {:error, {:unknown_tier, tier_name}}
    end
  end

  defp ensure_corpus_root(root) do
    if File.dir?(root), do: :ok, else: {:error, {:corpus_root_missing, root}}
  end

  # :all means "every directory under corpus_root that looks like a
  # mix or rebar3 project". Listed tiers get resolved to whichever of
  # the named directories exist.
  defp resolve_projects(corpus_root, :all) do
    corpus_root
    |> File.ls!()
    |> Enum.sort()
    |> Enum.map(fn name ->
      path = Path.join(corpus_root, name)
      {name, if(project_dir?(path), do: path, else: nil)}
    end)
    |> Enum.filter(fn {_, path} -> path != nil end)
  end

  defp resolve_projects(corpus_root, names) when is_list(names) do
    Enum.map(names, fn name ->
      path = Path.join(corpus_root, name)
      {name, if(project_dir?(path), do: path, else: nil)}
    end)
  end

  defp project_dir?(path) do
    File.dir?(path) and
      (File.exists?(Path.join(path, "mix.exs")) or
         File.exists?(Path.join(path, "rebar.config")))
  end

  # ── Field extraction ─────────────────────────────────────────────────

  defp fetch_string(raw, key) do
    case Map.fetch(raw, key) do
      {:ok, v} when is_binary(v) -> {:ok, v}
      {:ok, _} -> {:error, {:invalid, "#{key} must be a string"}}
      :error -> {:error, {:invalid, "missing required key: #{key}"}}
    end
  end

  defp fetch_pos_int(raw, key, default) do
    case Map.get(raw, key, default) do
      n when is_integer(n) and n > 0 -> {:ok, n}
      _ -> {:error, {:invalid, "#{key} must be a positive integer"}}
    end
  end

  defp fetch_tiers(raw) do
    case Map.fetch(raw, :tiers) do
      {:ok, tiers} when is_map(tiers) and map_size(tiers) > 0 ->
        validate_tiers(tiers)

      {:ok, _} ->
        {:error, {:invalid, "tiers must be a non-empty map"}}

      :error ->
        {:error, {:invalid, "missing required key: tiers"}}
    end
  end

  defp validate_tiers(tiers) do
    Enum.reduce_while(tiers, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      cond do
        not is_binary(name) ->
          {:halt, {:error, {:invalid, "tier name must be a string: #{inspect(name)}"}}}

        value == :all ->
          {:cont, {:ok, Map.put(acc, name, :all)}}

        is_list(value) and Enum.all?(value, &is_binary/1) ->
          {:cont, {:ok, Map.put(acc, name, value)}}

        true ->
          {:halt, {:error, {:invalid, "tier #{name}: value must be a list of strings or :all"}}}
      end
    end)
  end

  defp validate_default_tier(default, tiers) do
    if Map.has_key?(tiers, default) do
      :ok
    else
      {:error, {:invalid, "default_tier #{inspect(default)} not found in tiers"}}
    end
  end

  defp fetch_checks_barrier(raw) do
    case Map.get(raw, :checks_barrier) do
      nil ->
        {:ok, %__MODULE__{}.checks_barrier}

      list when is_list(list) ->
        if Enum.all?(list, &valid_command?/1),
          do: {:ok, list},
          else: {:error, {:invalid, "checks_barrier entries must be [cmd, [args...]] lists"}}

      _ ->
        {:error, {:invalid, "checks_barrier must be a list"}}
    end
  end

  defp valid_command?([cmd, args]) when is_binary(cmd) and is_list(args),
    do: Enum.all?(args, &is_binary/1)

  defp valid_command?(_), do: false

  defp expand_path(path), do: Path.expand(path)
end
