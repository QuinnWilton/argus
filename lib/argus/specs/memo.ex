defmodule Argus.Specs.Memo do
  @moduledoc false

  alias Argus.Specs.Source

  @enforce_keys [:table, :source]
  defstruct [:table, :source]

  @type t :: %__MODULE__{table: :ets.tid(), source: Source.t() | nil}
  @type context :: t() | :ets.tid()

  @spec new(Source.t() | nil) :: t()
  def new(source) do
    %__MODULE__{
      table: :ets.new(:argus_extraction_memo, [:set, :public, read_concurrency: true]),
      source: source
    }
  end

  @spec table(context()) :: :ets.tid()
  def table(%__MODULE__{table: table}), do: table
  def table(table), do: table

  @spec close(context()) :: true
  def close(memo), do: :ets.delete(table(memo))

  @spec source(context()) :: Source.t() | nil
  def source(%__MODULE__{source: source}), do: source

  # Keep accepting the ETS contexts used by direct Specs callers.
  def source(table) do
    case :ets.lookup(table, :specs_source) do
      [{:specs_source, source}] -> source
      [] -> nil
    end
  end
end
