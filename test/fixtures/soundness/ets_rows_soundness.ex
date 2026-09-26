defmodule Rows.Ets.NamedServer do
  # A server's named table, read by callers through its literal name.
  # Another module's unnamed table made under the same atom does not stand
  # in for it: the literal reaches this one, and the read is reported
  # against this owner.
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def lookup(k), do: :ets.lookup(:rows_same_atom, k)

  @impl true
  def init(o) do
    :ets.new(:rows_same_atom, [:named_table, :public])
    {:ok, o}
  end
end

defmodule Rows.Ets.ScratchSameAtom do
  # An unnamed table under the same atom, kept in the server's state: no
  # literal reaches it.
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o)

  @impl true
  def init(_o), do: {:ok, %{t: :ets.new(:rows_same_atom, [:public])}}
end

defmodule Rows.Ets.StateTableReader do
  # The server's unnamed table, read by an API function out of the state
  # map a caller hands it: the operand is a parameter's field, which may
  # hold the reference, and the read raises while the server restarts.
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def state, do: GenServer.call(__MODULE__, :state)
  def peek(%{tab: t}, k), do: :ets.lookup(t, k)

  @impl true
  def init(_o), do: {:ok, %{tab: :ets.new(:rows_state_tab, [:public])}}

  @impl true
  def handle_call(:state, _from, s), do: {:reply, s, s}
end

defmodule Rows.Ets.OptionNamed do
  # One atom, two creation sites chosen by an option: named on one branch,
  # unnamed on the other. The literal read reaches the named one, and is
  # reported against it.
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def read(k), do: :ets.lookup(:rows_option_tab, k)

  @impl true
  def init(o) do
    tab =
      if Keyword.get(o, :named, true),
        do: :ets.new(:rows_option_tab, [:named_table, :public]),
        else: :ets.new(:rows_option_tab, [:public])

    {:ok, %{tab: tab}}
  end
end

defmodule Rows.Ets.HelperNamed do
  # The named table read through a helper that takes it as a parameter:
  # the caller's literal names the named table, whatever unnamed table
  # shares its atom.
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def get(k), do: fetch(:rows_helper_atom, k)
  defp fetch(t, k), do: :ets.lookup(t, k)

  @impl true
  def init(o) do
    :ets.new(:rows_helper_atom, [:named_table, :public])
    {:ok, o}
  end
end

defmodule Rows.Ets.HelperScratch do
  # An unnamed table under the helper table's atom.
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o)

  @impl true
  def init(_o), do: {:ok, :ets.new(:rows_helper_atom, [])}
end

defmodule Rows.Ets.UnnamedOwner do
  # Negative (mnesia_schema's shape): the server's table is unnamed, and
  # the API reads a named table by the same atom that someone else makes
  # under a name the rule cannot see; the literal cannot reach this one.
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def first, do: :ets.first(:rows_unnamed_atom)

  @impl true
  def init(_o), do: {:ok, %{t: :ets.new(:rows_unnamed_atom, [:public])}}
end

defmodule Rows.Ets.OwnScratchReader do
  # Negative (qlc_pt's shape): a function that makes its own unnamed table
  # under an atom another server's unnamed table also uses, and reads its
  # own through the reference: never the other one.
  def count(items) do
    t = :ets.new(:rows_scratch_atom, [])
    :ets.insert(t, Enum.map(items, &{&1}))
    n = :ets.select_count(t, [{{:_}, [], [true]}])
    :ets.delete(t)
    n
  end
end

defmodule Rows.Ets.ScratchAtomServer do
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o)

  @impl true
  def init(_o), do: {:ok, %{t: :ets.new(:rows_scratch_atom, [:public])}}
end

defmodule Rows.Ets.ConfiguredOptions do
  # The table's options come from the server's start arguments, which the
  # facts do not show: whether it is named is unknown, so a literal read of
  # its atom may reach it and is reported.
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def read(k), do: :ets.lookup(:rows_configured, k)

  @impl true
  def init(o) do
    :ets.new(:rows_configured, Keyword.get(o, :table_opts, [:named_table, :public]))
    {:ok, o}
  end
end
