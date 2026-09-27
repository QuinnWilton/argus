defmodule Argus.ConfigError do
  @moduledoc """
  Raised when argus's configuration is invalid, or cannot be read.

  `key` is the path to the offending entry (`[:severity, :mailbx]`),
  `value` what was found there, and the message says what was expected
  — with the closest valid name when the entry looks like a typo of
  one — and where the entry is, spelled as its source spells it: in
  Elixir for `mix.exs` (`:argus → :severity → :mailbx`), in Erlang for
  `rebar.config` and `argus.config` (`argus → severity → mailbx`). Like
  `Mix.Error`, it prints without a stacktrace.
  """

  defexception [:key, :value, :message, mix: true]

  @type t :: %__MODULE__{
          key: [atom()],
          value: term(),
          message: String.t(),
          mix: true
        }

  @typedoc "How a source spells what an error points at."
  @type context :: %{origin: Argus.Config.origin(), erlang?: boolean()}

  @doc "The context an error about a configuration from `origin` is spelled in."
  @spec context(Argus.Config.origin()) :: context()
  def context(origin) do
    %{origin: origin, erlang?: match?({kind, _} when kind in [:rebar3, :file], origin)}
  end

  @doc """
  Builds the error for `value` at `key`, where `expected` says what
  would have been valid. When `candidates` holds a name close to the
  offending one, the message suggests it.
  """
  @spec new([atom()], term(), String.t(), [atom()], Argus.Config.origin()) :: t()
  def new(key, value, expected, candidates \\ [], origin \\ :inline) do
    ctx = context(origin)

    %__MODULE__{
      key: key,
      value: value,
      message:
        "argus: #{expected}" <>
          suggestion(ctx, value, candidates) <> "\n    at: " <> where(ctx, key)
    }
  end

  @doc """
  The error for configuration under scry's name (`what`, as its source
  spells it: `scry:`, the `:scry` compiler), which argus does not read:
  it names the argus spelling to move it to (`renamed`).
  """
  @spec renamed(String.t(), String.t(), Argus.Config.origin()) :: t()
  def renamed(what, renamed, origin) do
    %__MODULE__{
      key: [],
      value: what,
      message:
        "argus: " <>
          Argus.Report.Notice.config_renamed(what, renamed).message <>
          "\n    at: " <> origin_name(origin)
    }
  end

  @doc "The error for a configuration file that cannot be read or parsed."
  @spec unreadable(Path.t(), String.t()) :: t()
  def unreadable(path, reason) do
    %__MODULE__{
      key: [],
      value: path,
      message: "argus: #{path} cannot be read as a configuration: #{reason}"
    }
  end

  @doc """
  The candidate closest to `name`, when one is close enough to be the
  name that was meant.
  """
  @spec closest(term(), [atom()]) :: atom() | nil
  def closest(name, candidates) when is_atom(name) and name != nil do
    target = Atom.to_string(name)

    candidates
    |> Enum.map(&{String.jaro_distance(target, Atom.to_string(&1)), &1})
    |> Enum.filter(fn {distance, _} -> distance >= 0.8 end)
    |> Enum.max_by(fn {distance, _} -> distance end, fn -> nil end)
    |> case do
      {_, candidate} -> candidate
      nil -> nil
    end
  end

  def closest(_name, _candidates), do: nil

  @doc """
  `term` as the configuration's source writes it: `inspect/1` for
  Elixir, `~tp` on one line for Erlang terms.
  """
  @spec show(context(), term()) :: String.t()
  def show(%{erlang?: false}, term), do: inspect(term)

  def show(%{erlang?: true}, term) do
    ~c"~tp"
    |> :io_lib.format([term])
    |> IO.chardata_to_string()
    |> String.replace(~r/\s*\n\s*/, " ")
  end

  defp suggestion(ctx, value, candidates) do
    case closest(value, candidates) do
      nil -> ""
      candidate -> "; did you mean #{show(ctx, candidate)}?"
    end
  end

  defp where(ctx, key) do
    path = Enum.map_join([:argus | key], " → ", &show(ctx, &1))

    case origin_name(ctx.origin) do
      "" -> path
      origin -> "#{path} (#{origin})"
    end
  end

  defp origin_name(:inline), do: ""
  defp origin_name(:cli), do: "on the command line"
  defp origin_name({:mix, path}), do: "in #{Path.basename(path)}'s project/0"
  defp origin_name({:rebar3, path}), do: "in #{Path.basename(path)}"
  defp origin_name({:file, path}), do: "in #{path}"
end
