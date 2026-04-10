defmodule Argus.Autoresearch.Session do
  @moduledoc """
  Append-only event log for the autoresearch loop.

  `Session` owns `.autoresearch/session/autoresearch.jsonl`. Every
  meaningful loop event (measure, checks run, attempt start/end,
  baseline promotion, revert) gets one JSON line. The jsonl format
  is chosen over a real database because:

  - Append-only semantics are trivial with `File.open(:append)`.
  - Human-readable; a user can `tail -f` it during a run.
  - LLMs can read it with a Read tool and parse each line.
  - Gitignored by default — session state is runtime, not versioned.

  Session **only** writes the jsonl file. It never touches
  `.autoresearch/notes.md` — the LLM owns the narrative, tools own
  the events. This separation is load-bearing: it prevents automated
  writes from racing with the LLM's edits and keeps the "single
  source of narrative truth" rule simple.
  """

  alias Argus.Report

  @type event_type ::
          :baseline_set
          | :measure
          | :rank
          | :attempt_start
          | :checks
          | :remeasure
          | :attempt_end
          | :baseline_promoted
          | :revert
          | :note

  @type event :: %{
          required(:event) => String.t(),
          required(:t) => String.t(),
          optional(atom()) => term()
        }

  @default_dir ".autoresearch/session"
  @log_name "autoresearch.jsonl"

  @doc "Default session directory path."
  @spec default_dir() :: Path.t()
  def default_dir, do: @default_dir

  @doc "Absolute path to the jsonl log inside the given directory."
  @spec log_path(Path.t()) :: Path.t()
  def log_path(dir \\ @default_dir), do: Path.join(dir, @log_name)

  @doc """
  Appends an event to the session log.

  `fields` is a map of event-specific fields. The `:event` key names
  the event type (an atom), and `:t` (timestamp) is set automatically.

  Creates the session directory if it doesn't exist. Returns `:ok`
  or `{:error, reason}`.
  """
  @spec append(map(), Path.t()) :: :ok | {:error, term()}
  def append(fields, dir \\ @default_dir) when is_map(fields) do
    event = normalize_event(fields)
    line = Report.encode_json(event) <> "\n"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(log_path(dir), line, [:append]) do
      :ok
    end
  end

  @doc """
  Returns the last N events from the session log, most recent first.

  Returns `[]` if the log doesn't exist (fresh session).
  """
  @spec recent(non_neg_integer(), Path.t()) :: [map()]
  def recent(count \\ 10, dir \\ @default_dir) do
    path = log_path(dir)

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.to_list()
      |> Enum.reverse()
      |> Enum.take(count)
      |> Enum.flat_map(&decode_line/1)
    else
      []
    end
  end

  @doc """
  Returns all events in chronological order (oldest first).
  """
  @spec all(Path.t()) :: [map()]
  def all(dir \\ @default_dir) do
    path = log_path(dir)

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.flat_map(&decode_line/1)
    else
      []
    end
  end

  @doc """
  Returns the most recent event matching a specific event type, or
  `nil` if no such event exists in the log.
  """
  @spec last_of(event_type(), Path.t()) :: map() | nil
  def last_of(event_type, dir \\ @default_dir) do
    event_str = to_string(event_type)

    dir
    |> all()
    |> Enum.reverse()
    |> Enum.find(fn ev -> Map.get(ev, "event") == event_str end)
  end

  @doc """
  Clears the session log. Destructive — only use for tests or
  explicit reset. Leaves the directory in place.
  """
  @spec clear(Path.t()) :: :ok | {:error, term()}
  def clear(dir \\ @default_dir) do
    path = log_path(dir)

    if File.exists?(path) do
      File.rm(path)
    else
      :ok
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  # Converts a user-supplied fields map into the canonical event shape:
  # stringify the :event atom, add an ISO-8601 :t timestamp if missing.
  defp normalize_event(fields) do
    fields
    |> stringify_event_type()
    |> ensure_timestamp()
    |> Map.new(fn {k, v} -> {to_string(k), normalize_value(v)} end)
  end

  defp stringify_event_type(%{event: event} = fields) when is_atom(event) do
    Map.put(fields, :event, to_string(event))
  end

  defp stringify_event_type(fields), do: fields

  defp ensure_timestamp(%{t: _} = fields), do: fields

  defp ensure_timestamp(fields) do
    Map.put(fields, :t, DateTime.utc_now() |> DateTime.to_iso8601())
  end

  # Recursively normalize atoms to strings so the JSON encoder doesn't
  # choke on e.g. `%{result: :pass}`.
  defp normalize_value(v) when is_atom(v) and v not in [nil, true, false], do: to_string(v)

  defp normalize_value(v) when is_map(v),
    do: Map.new(v, fn {k, vv} -> {to_string(k), normalize_value(vv)} end)

  defp normalize_value(v) when is_list(v), do: Enum.map(v, &normalize_value/1)
  defp normalize_value(v), do: v

  defp decode_line(line) do
    case String.trim(line) do
      "" ->
        []

      content ->
        try do
          [:json.decode(content)]
        rescue
          _ -> []
        end
    end
  end
end
