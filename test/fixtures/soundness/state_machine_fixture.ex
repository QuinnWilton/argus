# state_machine bugs review 2 found silenced (item 27):
# test/soundness/state_machine_test.exs asserts the finding each must keep.

defmodule Argus.Test.Soundness.StateMachine.SelfHelperStatem do
  @moduledoc false
  # :legacy is a dead state: nothing but its own clauses names it. Its
  # catch-all re-enters it through a helper (to restart a state timeout),
  # a self-loop spelled as a helper's transition.
  @behaviour :gen_statem

  def callback_mode, do: :state_functions
  def init(_), do: {:ok, :idle, %{}}

  def idle(:cast, :go, data), do: {:next_state, :busy, data}
  def idle(_type, _msg, _data), do: :keep_state_and_data

  def busy(:cast, :done, data), do: {:next_state, :idle, data}
  def busy(_type, _msg, _data), do: :keep_state_and_data

  def legacy(:cast, :upgrade, data), do: {:next_state, :idle, data}
  def legacy(_type, _msg, data), do: rearm_legacy(data)

  defp rearm_legacy(data), do: {:next_state, :legacy, data, [{:state_timeout, 1000, :expire}]}

  def terminate(_r, _s, _d), do: :ok
end

defmodule Argus.Test.Soundness.StateMachine.RemoteTerminalStatem do
  @moduledoc false
  # :closed is entered from :open and hands every event to a shared
  # handler in another module that only ever keeps the state.
  @behaviour :gen_statem

  def callback_mode, do: :state_functions
  def init(_), do: {:ok, :open, %{}}

  def open(:cast, :close, data), do: {:next_state, :closed, data}
  def open(_type, _msg, _data), do: :keep_state_and_data

  def closed(type, msg, data),
    do: Argus.Test.Soundness.StateMachine.RemoteTerminalCommon.ignore(type, msg, data)

  def terminate(_r, _s, _d), do: :ok
end

defmodule Argus.Test.Soundness.StateMachine.RemoteTerminalCommon do
  @moduledoc false
  def ignore({:call, from}, _msg, _data), do: {:keep_state_and_data, [{:reply, from, :closed}]}
  def ignore(_type, _msg, _data), do: :keep_state_and_data
end
