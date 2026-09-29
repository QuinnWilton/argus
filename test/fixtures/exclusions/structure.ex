# Cases for structure exclusions and nearby defects that must remain reported.
# Asserted by test/exclusions/structure_test.exs.

# A supervisor that can be switched off: its child_spec/1 says
# `type: :supervisor` when it starts the tree, and hands back an
# `:ignore` start (typeless, so a worker, and rightly: it starts
# nothing) when disabled. The spec that starts the supervisor says so.
defmodule Excl.Structure.SwitchableSpec.Pipeline do
  @moduledoc false
  use Supervisor

  def child_spec(opts) do
    if Keyword.get(opts, :enabled, true) do
      %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :supervisor}
    else
      %{id: __MODULE__, start: {Function, :identity, [:ignore]}}
    end
  end

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: Supervisor.init([], strategy: :one_for_one)
end

defmodule Excl.Structure.SwitchableSpec.App do
  @moduledoc false
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    Supervisor.init([{Excl.Structure.SwitchableSpec.Pipeline, opts}], strategy: :one_for_one)
  end
end

# A supervisor whose own child_spec/1 leaves out `type: :supervisor`:
# its parent registers it as a worker, and gives it a worker's shutdown
# budget. The bug the switchable spec above does not have.
defmodule Excl.Structure.TypelessSpec.Pipeline do
  @moduledoc false
  use Supervisor

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: Supervisor.init([], strategy: :one_for_one)
end

defmodule Excl.Structure.TypelessSpec.App do
  @moduledoc false
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    Supervisor.init([{Excl.Structure.TypelessSpec.Pipeline, opts}], strategy: :one_for_one)
  end
end
