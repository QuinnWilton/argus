defmodule Mix.Tasks.Argus.Autoresearch do
  @shortdoc "Autoresearch loop: measure, diff, and rank coverage improvements"

  @moduledoc """
  Autoresearch loop subcommands for iterative coverage improvement.

  ## Subcommands

      mix argus.autoresearch init            # scaffold .autoresearch/ directory
      mix argus.autoresearch measure         # run coverage on corpus tier
      mix argus.autoresearch diff            # diff current vs baseline
      mix argus.autoresearch rank            # ranked priority list
      mix argus.autoresearch checks          # run pre-accept barrier
      mix argus.autoresearch accept          # promote current → baseline
      mix argus.autoresearch revert          # log a reverted attempt
      mix argus.autoresearch status          # session summary (the "resume" command)
      mix argus.autoresearch note "text"     # append a free-form note

  ## Options (global)

      --tier TIER      Override corpus tier (default: from config)
      --initial        For `accept`: mark as the first baseline

  ## Typical workflow

      $ mix argus.autoresearch init
      $ mix argus.autoresearch measure
      $ mix argus.autoresearch accept --initial
      # edit an extractor
      $ mix argus.autoresearch checks
      $ mix argus.autoresearch measure
      $ mix argus.autoresearch diff
      # review the diff
      $ mix argus.autoresearch accept
  """

  use Mix.Task

  alias Argus.Autoresearch

  @impl Mix.Task
  def run(args) do
    # Ensure the app is loaded so Config/Measure can find priv/ and ebin dirs.
    Mix.Task.run("app.start", ["--no-start"])

    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [
          tier: :string,
          initial: :boolean,
          limit: :integer,
          include_unchanged: :boolean,
          skip_canary: :boolean,
          force: :boolean
        ]
      )

    case positional do
      ["init" | _] -> cmd_init(opts)
      ["measure" | _] -> cmd_measure(opts)
      ["diff" | _] -> cmd_diff(opts)
      ["rank" | _] -> cmd_rank(opts)
      ["checks" | _] -> cmd_checks(opts)
      ["accept" | _] -> cmd_accept(opts)
      ["revert" | rest] -> cmd_revert(rest, opts)
      ["status" | _] -> cmd_status(opts)
      ["note" | rest] -> cmd_note(rest)
      _ -> cmd_help()
    end
  end

  defp cmd_init(opts) do
    case Autoresearch.init(opts) do
      :ok ->
        IO.puts("Initialized .autoresearch/ scaffold.")
        IO.puts("")
        IO.puts("Next steps:")
        IO.puts("  1. Review .autoresearch/config.exs (set corpus_root)")
        IO.puts("  2. mix argus.autoresearch measure")
        IO.puts("  3. mix argus.autoresearch accept --initial")
        IO.puts("  4. git add .autoresearch/")

      {:error, :already_initialized} ->
        IO.puts(:stderr, ".autoresearch/ already exists. Use --force to reinitialize.")
        exit({:shutdown, 1})

      {:error, reason} ->
        IO.puts(:stderr, "init failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp cmd_measure(opts) do
    IO.puts("Measuring corpus...")

    on_progress = fn name, result ->
      status =
        case result do
          {:ok, _} -> "ok"
          {:error, reason} -> "error: #{inspect(reason)}"
          {:missing, _} -> "missing"
        end

      IO.puts("  #{name}: #{status}")
    end

    case Autoresearch.measure(Keyword.put(opts, :on_progress, on_progress)) do
      {:ok, snapshot} ->
        total_imprecision =
          snapshot.counts.imprecision_event
          |> Map.values()
          |> Enum.map(& &1.total)
          |> Enum.sum()

        total_shape_gaps =
          snapshot.counts.shape_gaps
          |> Map.values()
          |> Enum.map(& &1.total)
          |> Enum.sum()

        IO.puts("")
        IO.puts("Snapshot written to .autoresearch/current/snapshot.json")
        IO.puts("  Projects: #{length(snapshot.projects)}")
        IO.puts("  Imprecision events: #{total_imprecision}")
        IO.puts("  Shape-gap rows: #{total_shape_gaps}")
        IO.puts("  Categories: #{map_size(snapshot.counts.imprecision_event)}")

      {:error, reason} ->
        IO.puts(:stderr, "measure failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp cmd_diff(_opts) do
    case Autoresearch.diff() do
      {:ok, diff} ->
        IO.puts("Coverage diff (baseline → current)")
        IO.puts("  Net imprecision change: #{diff.net_total}")
        IO.puts("")

        if diff.improvements != [] do
          IO.puts("  Improvements:")

          for delta <- diff.improvements do
            name = delta_name(delta)
            IO.puts("    #{name}: #{delta.delta} (#{delta.baseline} → #{delta.current})")
          end

          IO.puts("")
        end

        if diff.regressions != [] do
          IO.puts("  Regressions:")

          for delta <- diff.regressions do
            name = delta_name(delta)
            IO.puts("    #{name}: +#{delta.delta} (#{delta.baseline} → #{delta.current})")
          end

          IO.puts("")
        end

        if diff.new_categories != [] do
          IO.puts("  New categories: #{Enum.join(diff.new_categories, ", ")}")
        end

        if diff.removed_categories != [] do
          IO.puts("  Removed categories: #{Enum.join(diff.removed_categories, ", ")}")
        end

        if diff.improvements == [] and diff.regressions == [] do
          IO.puts("  No changes detected.")
        end

      {:error, :no_baseline} ->
        IO.puts(
          :stderr,
          "No baseline found. Run `mix argus.autoresearch accept --initial` first."
        )

        exit({:shutdown, 1})

      {:error, :schema_mismatch} ->
        IO.puts(
          :stderr,
          "Schema version mismatch. Run `mix argus.autoresearch init --force` to rebaseline."
        )

        exit({:shutdown, 1})

      {:error, reason} ->
        IO.puts(:stderr, "diff failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp cmd_rank(opts) do
    case Autoresearch.rank(opts) do
      {:ok, targets} ->
        if targets == [] do
          IO.puts("No targets to rank. The diff may be empty or all categories are dead-ended.")
        else
          IO.puts("Top autoresearch targets:")
          IO.puts("")

          for {target, idx} <- Enum.with_index(targets, 1) do
            extractor = target.suggested_extractor || "(unknown)"

            IO.puts(
              "  #{idx}. #{target.category} (score: #{Float.round(target.score, 1)}, #{target.kind})"
            )

            IO.puts("     #{target.rationale}")
            IO.puts("     Extractor: #{extractor}")

            if target.sample_funcs != [] do
              IO.puts("     Sample: #{Enum.take(target.sample_funcs, 3) |> Enum.join(", ")}")
            end

            IO.puts("")
          end
        end

      {:error, reason} ->
        IO.puts(:stderr, "rank failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp cmd_checks(opts) do
    IO.puts("Running checks barrier...")

    on_step = fn step, status ->
      case {step, status} do
        {{:command, cmd}, :start} ->
          IO.write("  #{Enum.join(cmd, " ")} ... ")

        {{:command, _cmd}, {:done, :ok}} ->
          IO.puts("ok")

        {{:command, _cmd}, {:done, {:error, _}}} ->
          IO.puts("FAILED")

        {:canary, :start} ->
          IO.write("  Canary cross-check ... ")

        {:canary, {:done, :ok}} ->
          IO.puts("ok")

        {:canary, {:done, :skipped}} ->
          IO.puts("skipped (no fixture)")

        {:canary, {:done, {:error, _}}} ->
          IO.puts("DRIFT DETECTED")

        _ ->
          :ok
      end
    end

    case Autoresearch.checks(Keyword.put(opts, :on_step, on_step)) do
      :ok ->
        IO.puts("")
        IO.puts("All checks passed.")

      {:error, {:command_failed, cmd, code, tail}} ->
        IO.puts("")
        IO.puts(:stderr, "Barrier failed: #{Enum.join(cmd, " ")} exited #{code}")
        IO.puts(:stderr, String.trim(tail))
        exit({:shutdown, 1})

      {:error, {:canary_drift, drift}} ->
        IO.puts("")
        IO.puts(:stderr, "Canary correctness drift detected:")

        for {analysis, %{baseline: b, current: c, delta: d}} <- drift do
          IO.puts(:stderr, "  #{analysis}: #{b} → #{c} (#{sign(d)})")
        end

        exit({:shutdown, 1})
    end
  end

  defp cmd_accept(opts) do
    case Autoresearch.accept(opts) do
      :ok ->
        IO.puts("Baseline promoted.")
        IO.puts("  git add .autoresearch/baseline/")

      {:error, :checks_not_passing} ->
        IO.puts(:stderr, "Cannot accept: checks barrier hasn't passed for this working tree.")
        IO.puts(:stderr, "Run `mix argus.autoresearch checks` first.")
        exit({:shutdown, 1})

      {:error, reason} ->
        IO.puts(:stderr, "accept failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp cmd_revert(rest, _opts) do
    reason = Enum.join(rest, " ")
    reason = if reason == "", do: "manual revert", else: reason

    Autoresearch.revert(reason: reason)
    IO.puts("Revert logged. Run `git checkout .` to discard working tree changes.")
  end

  defp cmd_status(_opts) do
    status = Autoresearch.status()

    IO.puts("Autoresearch status")
    IO.puts("═══════════════════")
    IO.puts("")
    IO.puts("  Config: #{if status.config_loaded, do: "loaded", else: "NOT FOUND"}")
    IO.puts("  Baseline: #{if status.baseline_exists, do: "exists", else: "none"}")
    IO.puts("  Current snapshot: #{if status.current_exists, do: "exists", else: "none"}")
    IO.puts("")

    focus = status.notes.current_focus

    if focus && focus != "" && focus != "(none)" do
      IO.puts("  Current focus: #{focus}")
    else
      IO.puts("  Current focus: (none)")
    end

    if status.notes.dead_ends != [] do
      IO.puts("  Dead ends: #{Enum.join(status.notes.dead_ends, ", ")}")
    end

    IO.puts("")

    if status.recent_events != [] do
      IO.puts("  Recent events:")

      for event <- Enum.take(status.recent_events, 10) do
        t = Map.get(event, "t", "")
        type = Map.get(event, "event", "?")
        IO.puts("    [#{t}] #{type}")
      end

      IO.puts("")
    end

    # If both baseline and current exist, show the top-3 ranked targets.
    if status.baseline_exists and status.current_exists do
      case Autoresearch.rank(limit: 3, include_unchanged: true) do
        {:ok, targets} when targets != [] ->
          IO.puts("  Top targets:")

          for target <- targets do
            IO.puts("    #{target.category} (score: #{Float.round(target.score, 1)})")
          end

          IO.puts("")

        _ ->
          :ok
      end
    end
  end

  defp cmd_note([]) do
    IO.puts(:stderr, "Usage: mix argus.autoresearch note \"your text here\"")
    exit({:shutdown, 1})
  end

  defp cmd_note(rest) do
    text = Enum.join(rest, " ")
    Autoresearch.note(text)
    IO.puts("Note logged.")
  end

  defp cmd_help do
    IO.puts(@moduledoc)
  end

  defp delta_name(%Argus.Autoresearch.Diff.CategoryDelta{category: c}), do: c
  defp delta_name(%Argus.Autoresearch.Diff.GapDelta{relation: r}), do: r

  defp sign(n) when n > 0, do: "+#{n}"
  defp sign(n), do: "#{n}"
end
