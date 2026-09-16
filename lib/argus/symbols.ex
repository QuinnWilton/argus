defmodule Argus.Symbols do
  @moduledoc """
  Interned fact symbols: every string a fact row carries, mapped once to a
  small integer.

  A raw fact row is a list of short binaries — a few hundred bytes of heap
  for under a hundred bytes of text, copied in full whenever the row
  crosses a process or an ETS table, and re-parsed by every consumer that
  wants the `Argus.InstrId` inside an instruction ID. Interned rows are
  tuples of ids: a few words each, and an ID's parse is cached on the
  table and done once.

  The table is owned by whoever holds the rows. Ids are only meaningful
  next to the table that minted them, so a consumer that persists rows
  persists the table with them — `Argus.Symbols.Store` is the behaviour
  such a consumer implements over its own storage; `Argus.Symbols.ETS` is
  the default for a single run.
  """

  alias Argus.InstrId

  @type id :: pos_integer()

  @type t :: %__MODULE__{store: module(), state: term(), parsed: :ets.tid()}

  @enforce_keys [:store, :state, :parsed]
  defstruct [:store, :state, :parsed]

  defmodule Store do
    @moduledoc """
    Where a `Argus.Symbols` table keeps its mapping. Both directions must
    be safe to call from any process, and `intern/2` must return the same
    id for the same binary for the table's lifetime.
    """

    @callback intern(state :: term(), binary()) :: Argus.Symbols.id()
    @callback resolve(state :: term(), Argus.Symbols.id()) :: binary()
  end

  defmodule ETS do
    @moduledoc """
    The default store: two public ETS tables and an atomic counter, so
    parallel extraction workers intern without coordination. A binary
    that loses the insert race takes the id the winner assigned.
    """

    @behaviour Argus.Symbols.Store

    @type t :: %{forward: :ets.tid(), reverse: :ets.tid(), counter: :atomics.atomics_ref()}

    @spec new() :: t()
    def new do
      %{
        forward:
          :ets.new(:argus_symbols, [
            :set,
            :public,
            read_concurrency: true,
            write_concurrency: true
          ]),
        reverse:
          :ets.new(:argus_symbols, [
            :set,
            :public,
            read_concurrency: true,
            write_concurrency: true
          ]),
        counter: :atomics.new(1, signed: false)
      }
    end

    @impl true
    def intern(%{forward: forward, reverse: reverse, counter: counter}, binary) do
      case :ets.lookup(forward, binary) do
        [{_, id}] ->
          id

        [] ->
          id = :atomics.add_get(counter, 1, 1)

          if :ets.insert_new(forward, {binary, id}) do
            true = :ets.insert(reverse, {id, binary})
            id
          else
            [{_, winner}] = :ets.lookup(forward, binary)
            winner
          end
      end
    end

    @impl true
    def resolve(%{reverse: reverse}, id), do: :ets.lookup_element(reverse, id, 2)

    @spec destroy(t()) :: :ok
    def destroy(%{forward: forward, reverse: reverse}) do
      :ets.delete(forward)
      :ets.delete(reverse)
      :ok
    end
  end

  @doc "A table over the default ETS store."
  @spec new() :: t()
  def new, do: new(ETS, ETS.new())

  @doc "A table over `store`, a `Argus.Symbols.Store`, with its `state`."
  @spec new(module(), term()) :: t()
  def new(store, state) when is_atom(store) do
    %__MODULE__{
      store: store,
      state: state,
      parsed: :ets.new(:argus_symbols_parsed, [:set, :public, read_concurrency: true])
    }
  end

  @doc "The id for `binary`, minting one on first sight."
  @spec intern(t(), binary()) :: id()
  def intern(%__MODULE__{store: store, state: state}, binary) when is_binary(binary),
    do: store.intern(state, binary)

  @doc "The binary behind `id`. Raises for an id this table never minted."
  @spec resolve(t(), id()) :: binary()
  def resolve(%__MODULE__{store: store, state: state}, id) when is_integer(id),
    do: store.resolve(state, id)

  @doc """
  The `Argus.InstrId` an instruction-ID symbol parses to, parsed once per
  id and cached on the table. `:error` for a symbol that is not an
  instruction ID.
  """
  @spec instr_id(t(), id()) :: {:ok, InstrId.t()} | :error
  def instr_id(%__MODULE__{parsed: parsed} = symbols, id) do
    case :ets.lookup(parsed, id) do
      [{_, result}] ->
        result

      [] ->
        result = InstrId.parse(resolve(symbols, id))
        :ets.insert(parsed, {id, result})
        result
    end
  end

  @doc """
  Releases the parse cache, and the store when it is the default ETS one.
  The tables also die with the process that created the table, so this
  is for a long-lived owner that is done with a run.
  """
  @spec destroy(t()) :: :ok
  def destroy(%__MODULE__{store: store, state: state, parsed: parsed}) do
    :ets.delete(parsed)
    if store == ETS, do: ETS.destroy(state)
    :ok
  end
end
