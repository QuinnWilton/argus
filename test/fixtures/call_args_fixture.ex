# Fixtures for testing call_arg fact emission.
#
# Each module exercises a distinct argument resolution pattern so
# tests can assert the correct `value` field in call_arg facts.

defmodule Argus.Test.Fixtures.CallArgsLiteral do
  @moduledoc false

  # GenServer.call with a literal module target — should emit
  # call_arg with value = "Argus.Test.Fixtures.CallArgsLiteral"
  # (the inspected atom) at arg position 0.
  def ping do
    GenServer.call(__MODULE__, :ping)
  end

  # :ets.lookup with a literal table name.
  def lookup(key) do
    :ets.lookup(:my_test_table, key)
  end
end

defmodule Argus.Test.Fixtures.CallArgsForwarder do
  @moduledoc false

  # Forwards parameter 0 to GenServer.call arg 0 — should emit
  # call_arg with value = "arg:0".
  def call_server(server) do
    GenServer.call(server, :request)
  end

  # Forwards parameter 1 to :ets.lookup arg 0 — should emit
  # call_arg with value = "arg:1" for ets.lookup's arg 0.
  def read_table(_conn, table) do
    :ets.lookup(table, :key)
  end

  # Multi-arg forwarding: parameter 0 → GenServer.call arg 0,
  # parameter 1 is the message (also forwarded).
  def forward_both(server, msg) do
    GenServer.call(server, msg)
  end
end

defmodule Argus.Test.Fixtures.CallArgsMultiArity do
  @moduledoc false

  # 6-argument function to verify the arity cap at 4.
  # Only args 0-3 should appear in call_arg facts.
  def many_args(a, b, c, d, e, f) do
    :erlang.send(a, {b, c, d, e, f})
  end
end

defmodule Argus.Test.Fixtures.CallArgsLocalCall do
  @moduledoc false

  # Local call with a literal arg — verifies local calls are captured.
  def public_api do
    do_work(:literal_arg)
  end

  defp do_work(arg) do
    GenServer.call(arg, :msg)
  end
end
