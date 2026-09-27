defmodule Argus.Report.Text do
  @moduledoc """
  The report for a person at a terminal, on stderr: each notice on a
  line of its own (`argus: ...`), then each finding's pentiment frame
  (`Argus.Report.Pentiment`) followed by a blank line, then the summary
  (`N findings (x errors, y warnings, z infos)`).

  Stdout stays free for what a pipe wants (`Argus.Report.Json`).

  ## Color

  `:color` is `:auto` (the default: color when ANSI is enabled, as
  Elixir decides it for the terminal), `:always` (color even into a
  pipe: the rebar3 plugin relays the escript's stderr and asks for it on
  a terminal) or `:never`.
  """

  alias Argus.Report
  alias Argus.Report.{Entry, Notice}

  @typedoc "When the frames are colored."
  @type color :: :auto | :always | :never

  @doc """
  The report as text: the notices, the frames and the summary, each
  line ending in a newline.
  """
  @spec format([Entry.t()], [Notice.t()], String.t(), keyword()) :: String.t()
  def format(entries, notices, cwd, opts \\ []) do
    color = Keyword.get(opts, :color, :auto)

    with_color(color, fn ->
      IO.iodata_to_binary([
        Enum.map(notices, &[notice(&1), "\n"]),
        Enum.map(entries, &[Report.Pentiment.format(&1, cwd, colors: color != :never), "\n\n"]),
        Report.summary(entries),
        "\n"
      ])
    end)
  end

  @doc "Prints `format/4` to stderr."
  @spec print([Entry.t()], [Notice.t()], String.t(), keyword()) :: :ok
  def print(entries, notices, cwd, opts \\ []) do
    IO.write(:stderr, format(entries, notices, cwd, opts))
  end

  @doc "A notice as the text report prints it."
  @spec notice(Notice.t()) :: String.t()
  def notice(%Notice{message: message}), do: "argus: " <> message

  # Pentiment colors only when ANSI is enabled: `:always` enables it for
  # the call.
  defp with_color(:always, fun) do
    previous = Application.fetch_env(:elixir, :ansi_enabled)
    Application.put_env(:elixir, :ansi_enabled, true)

    try do
      fun.()
    after
      case previous do
        {:ok, value} -> Application.put_env(:elixir, :ansi_enabled, value)
        :error -> Application.delete_env(:elixir, :ansi_enabled)
      end
    end
  end

  defp with_color(color, fun) when color in [:auto, :never], do: fun.()
end
