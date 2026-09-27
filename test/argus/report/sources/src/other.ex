defmodule Shapes.Other do
  # Never compiled: a second file for the frames a finding points into.
  def start(parent) do
    GenServer.start_link(__MODULE__, parent)
  end

  def init(parent) do
    send(parent, :ready)
    {:ok, parent}
  end
end
