defmodule Argus.Test.Fixtures.AppSupervisor do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Argus.Test.Fixtures.WorkerA, []},
      {Argus.Test.Fixtures.WorkerB, []}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end
end
