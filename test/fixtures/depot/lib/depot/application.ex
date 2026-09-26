defmodule Depot.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Notifier starts first; Sonar listens on it from handle_continue/2
    # and Queue notifies it on every event. Under :one_for_one a Notifier
    # crash restarts only the Notifier, which comes back with no
    # listeners, and Sonar runs on deaf — the coupling argus reports.
    # Queue's notifications reach the new Notifier by name: it holds
    # nothing there to lose.
    children = [
      Depot.Notifier,
      Depot.Queue,
      Depot.Sonar
    ]

    opts = [strategy: :one_for_one, name: Depot.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
