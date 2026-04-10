defmodule Argus.Autoresearch do
  @moduledoc """
  Public API for the autoresearch loop.

  Thin wiring module that composes `Config`, `Measure`, `Snapshot`,
  `Diff`, `Baseline`, `Ranker`, `Session`, and `Checks`. Each
  function here corresponds to one Mix subcommand — the Mix task
  delegates to this module so the logic is unit-testable without
  invoking the task runner.

  ## Typical loop

      Autoresearch.init()
      Autoresearch.measure()
      Autoresearch.accept(initial: true)
      # ← developer edits extractor ←
      Autoresearch.checks()
      Autoresearch.measure()
      Autoresearch.diff()
      # ← developer reviews diff ←
      Autoresearch.accept()
      # loop
  """

  alias Argus.Autoresearch.{Baseline, Checks, Config, Diff, Measure, Ranker, Session, Snapshot}

  @autoresearch_dir ".autoresearch"

  @doc """
  Returns the autoresearch root directory (relative to repo root).
  """
  @spec root_dir() :: Path.t()
  def root_dir, do: @autoresearch_dir

  @doc """
  Initializes the `.autoresearch/` scaffold: config, notes, session
  directory. Copies templates from `priv/autoresearch/templates/`.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec init(keyword()) :: :ok | {:error, term()}
  def init(opts \\ []) do
    force = Keyword.get(opts, :force, false)

    if File.exists?(@autoresearch_dir) and not force do
      {:error, :already_initialized}
    else
      templates_dir = priv_templates_dir()

      with :ok <- File.mkdir_p(Path.join(@autoresearch_dir, "baseline")),
           :ok <- File.mkdir_p(Path.join(@autoresearch_dir, "session")),
           :ok <-
             copy_template(
               templates_dir,
               "config.exs",
               Path.join(@autoresearch_dir, "config.exs"),
               force
             ),
           :ok <-
             copy_template(
               templates_dir,
               "notes.md",
               Path.join(@autoresearch_dir, "notes.md"),
               force
             ) do
        :ok
      end
    end
  end

  @doc """
  Runs the coverage analysis against the configured corpus tier.

  Writes:
  - `.autoresearch/current/snapshot.json` — canonicalized snapshot
  - `.autoresearch/current/raw/<project>/results.json` — per-project reports

  Returns `{:ok, snapshot}` or `{:error, reason}`.
  """
  @spec measure(keyword()) :: {:ok, Snapshot.t()} | {:error, term()}
  def measure(opts \\ []) do
    with {:ok, config} <- Config.load(),
         tier = Keyword.get(opts, :tier, config.default_tier),
         sha = Keyword.get(opts, :argus_git_sha, git_sha()),
         output_dir = Path.join(@autoresearch_dir, "current/raw"),
         {:ok, snapshot, _per_project} <-
           Measure.measure_tier(config, tier,
             output_dir: output_dir,
             argus_git_sha: sha,
             on_progress: Keyword.get(opts, :on_progress, fn _, _ -> :ok end)
           ) do
      snapshot_path = Path.join(@autoresearch_dir, "current/snapshot.json")
      Snapshot.write!(snapshot, snapshot_path)

      Session.append(%{
        event: :measure,
        duration_s: 0,
        tier: tier,
        projects: snapshot.projects
      })

      {:ok, snapshot}
    end
  end

  @doc """
  Computes the diff between the current snapshot and the committed
  baseline. Returns `{:ok, diff}` or `{:error, reason}`.
  """
  @spec diff(keyword()) :: {:ok, Diff.t()} | {:error, term()}
  def diff(_opts \\ []) do
    with {:ok, baseline} <- Baseline.read(),
         {:ok, current} <- load_current_snapshot() do
      Diff.compute(baseline, current)
    end
  end

  @doc """
  Ranks the current diff's deltas and returns `[%Target{}]`.
  """
  @spec rank(keyword()) :: {:ok, [Ranker.Target.t()]} | {:error, term()}
  def rank(opts \\ []) do
    with {:ok, diff} <- diff() do
      dead_ends = load_dead_ends()
      recent = load_recent_categories()

      targets =
        Ranker.rank(diff,
          dead_ends: dead_ends,
          recent_categories: recent,
          limit: Keyword.get(opts, :limit),
          include_unchanged: Keyword.get(opts, :include_unchanged, false)
        )

      Session.append(%{
        event: :rank,
        top5:
          Enum.take(targets, 5) |> Enum.map(fn t -> %{category: t.category, score: t.score} end)
      })

      {:ok, targets}
    end
  end

  @doc """
  Runs the checks barrier and (if available) the canary cross-check.
  """
  @spec checks(keyword()) :: :ok | {:error, term()}
  def checks(opts \\ []) do
    result = Checks.run(opts)

    case result do
      :ok ->
        Session.append(%{event: :checks, result: :pass})
        :ok

      {:error, reason} ->
        Session.append(%{event: :checks, result: :fail, reason: inspect(reason)})
        {:error, reason}
    end
  end

  @doc """
  Promotes the current snapshot to the committed baseline.

  Options:
  - `:initial` — if true, this is the first baseline (no prior
    diff required). Needed because `accept` normally validates
    that checks have passed.
  - `:note` — free-form note stored in baseline metadata.
  """
  @spec accept(keyword()) :: :ok | {:error, term()}
  def accept(opts \\ []) do
    initial = Keyword.get(opts, :initial, false)
    note = Keyword.get(opts, :note)

    with {:ok, current} <- load_current_snapshot(),
         :ok <- validate_accept(initial) do
      Baseline.promote(current, note: note)

      Session.append(%{
        event: if(initial, do: :baseline_set, else: :baseline_promoted),
        sha: current.argus_git_sha,
        tier: current.tier,
        note: note
      })

      :ok
    end
  end

  @doc """
  Reverts the current attempt (logs the revert event, restores
  the baseline pointer). Does NOT touch the working tree — the
  caller (or skill) runs `git checkout .` to discard code changes.
  """
  @spec revert(keyword()) :: :ok
  def revert(opts \\ []) do
    reason = Keyword.get(opts, :reason, "manual revert")

    Session.append(%{
      event: :revert,
      reason: reason
    })

    :ok
  end

  @doc """
  Returns a structured status summary for the "resume" flow.

  The status includes:
  - The last N session events
  - Current focus and dead ends from notes.md
  - Whether a baseline exists
  - The current snapshot tier and project count
  """
  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    count = Keyword.get(opts, :recent_count, 10)

    %{
      baseline_exists: Baseline.exists?(),
      current_exists: current_snapshot_exists?(),
      recent_events: Session.recent(count),
      notes: load_notes_summary(),
      config_loaded: match?({:ok, _}, Config.load())
    }
  end

  @doc """
  Appends a free-form note to the session log.
  """
  @spec note(String.t()) :: :ok
  def note(text) when is_binary(text) do
    Session.append(%{event: :note, text: text})
    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp load_current_snapshot do
    path = Path.join(@autoresearch_dir, "current/snapshot.json")
    Snapshot.read(path)
  end

  defp current_snapshot_exists? do
    File.exists?(Path.join(@autoresearch_dir, "current/snapshot.json"))
  end

  defp load_dead_ends do
    notes_path = Path.join(@autoresearch_dir, "notes.md")

    if File.exists?(notes_path) do
      notes_path |> File.read!() |> Ranker.parse_dead_ends()
    else
      []
    end
  end

  defp load_recent_categories do
    Session.all()
    |> Ranker.recent_categories()
  end

  defp load_notes_summary do
    notes_path = Path.join(@autoresearch_dir, "notes.md")

    if File.exists?(notes_path) do
      content = File.read!(notes_path)

      %{
        current_focus: extract_section(content, "## Current focus"),
        dead_ends: Ranker.parse_dead_ends(content)
      }
    else
      %{current_focus: nil, dead_ends: []}
    end
  end

  defp extract_section(content, heading) do
    content
    |> String.split("\n")
    |> Enum.reduce({:before, nil}, fn
      ^heading, {:before, _} -> {:in_section, ""}
      "## " <> _, {:in_section, acc} -> {:after, String.trim(acc)}
      line, {:in_section, acc} -> {:in_section, acc <> line <> "\n"}
      _line, state -> state
    end)
    |> case do
      {:in_section, acc} -> String.trim(acc)
      {:after, text} -> text
      _ -> nil
    end
  end

  defp validate_accept(true = _initial), do: :ok

  defp validate_accept(false) do
    case Session.last_of(:checks) do
      %{"result" => "pass"} -> :ok
      _ -> {:error, :checks_not_passing}
    end
  end

  defp git_sha do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  end

  defp priv_templates_dir do
    case :code.priv_dir(:argus) do
      {:error, _} -> "priv/autoresearch/templates"
      dir -> Path.join(List.to_string(dir), "autoresearch/templates")
    end
  end

  defp copy_template(templates_dir, filename, dest, force) do
    src = Path.join(templates_dir, filename)

    cond do
      not File.exists?(src) ->
        {:error, {:template_missing, src}}

      File.exists?(dest) and not force ->
        :ok

      true ->
        File.cp(src, dest)
    end
  end
end
