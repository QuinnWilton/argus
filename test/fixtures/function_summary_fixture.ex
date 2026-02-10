defmodule Argus.Test.Fixtures.FunctionSummaryFixture do
  @moduledoc false

  # Pure delegate: forwards directly to GenServer.call.
  def get_value(server) do
    GenServer.call(server, :get)
  end

  # Two-level wrapper chain: fetch -> get_value -> GenServer.call.
  def fetch(server) do
    get_value(server)
  end

  # Not a delegate: does real work before calling.
  def get_and_transform(server) do
    result = GenServer.call(server, :get)
    {:transformed, result}
  end
end
