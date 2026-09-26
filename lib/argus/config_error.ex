defmodule Argus.ConfigError do
  @moduledoc """
  Raised when the `scry:` project configuration is invalid.

  `key` is the path to the offending entry (`[:severity, :mailbx]`),
  `value` what was found there, and the message says what was expected
  — with the closest valid name when the entry looks like a typo of
  one. Like `Mix.Error`, it prints without a stacktrace.
  """

  defexception [:key, :value, :message, mix: true]

  @type t :: %__MODULE__{
          key: [atom()],
          value: term(),
          message: String.t(),
          mix: true
        }

  @doc """
  Builds the error for `value` at `key`, where `expected` says what
  would have been valid. When `candidates` holds a name close to the
  offending one, the message suggests it.
  """
  @spec new([atom()], term(), String.t(), [atom()]) :: t()
  def new(key, value, expected, candidates \\ []) do
    %__MODULE__{
      key: key,
      value: value,
      message:
        "scry: #{expected}" <> suggestion(value, candidates) <> "\n    at: #{format_key(key)}"
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

  defp suggestion(value, candidates) do
    case closest(value, candidates) do
      nil -> ""
      candidate -> "; did you mean #{inspect(candidate)}?"
    end
  end

  defp format_key(key), do: Enum.map_join([:scry | key], " → ", &inspect/1)
end
