defmodule Argus.CoupledSiblingsDemoTest do
  use ExUnit.Case, async: true

  alias Argus.Test.Fixtures.DemoNotifier
  alias Argus.Test.Fixtures.DemoSonar

  describe "one_for_one: notifier crash silently degrades sonar" do
    @tag :tmp_dir
    test "sonar keeps running with stale state after notifier restarts", %{tmp_dir: tmp_dir} do
      notifier_name = :"notifier_#{tmp_dir}" |> unique_name()
      sonar_name = :"sonar_#{tmp_dir}" |> unique_name()

      children = [
        {DemoNotifier, name: notifier_name},
        {DemoSonar, name: sonar_name, notifier: notifier_name}
      ]

      {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)

      # Registration worked: Sonar registered itself as a listener during init.
      sonar_pid = GenServer.whereis(sonar_name)
      assert MapSet.member?(DemoNotifier.listeners(notifier_name, :sonar), sonar_pid)

      # Register the test process as a listener so we can observe notifications.
      DemoNotifier.listen(notifier_name, :sonar)

      # Ping works: Sonar broadcasts via Notifier, test process receives it.
      assert DemoSonar.ping(sonar_name) == :ok
      assert_receive {:notification, :sonar, %{ping: true}}

      # Kill the Notifier. The one_for_one supervisor restarts only Notifier.
      notifier_pid = GenServer.whereis(notifier_name)
      Process.exit(notifier_pid, :kill)

      # Wait for Notifier to come back with a new pid.
      poll_until(fn ->
        new_pid = GenServer.whereis(notifier_name)
        new_pid != nil and new_pid != notifier_pid
      end)

      # Sonar was never restarted — same pid as before.
      assert GenServer.whereis(sonar_name) == sonar_pid

      # The new Notifier has an empty listener list — registration was lost.
      assert DemoNotifier.listeners(notifier_name, :sonar) == MapSet.new()

      # Re-register the test process so we can check if pings still deliver.
      DemoNotifier.listen(notifier_name, :sonar)

      # Ping still "succeeds" (the GenServer.call completes)...
      assert DemoSonar.ping(sonar_name) == :ok

      # ...but Sonar's notification goes only to the test process, not to Sonar itself.
      # Sonar is no longer a listener, so it silently stopped receiving pings.
      # This is the bug: silent degradation with no error signal.
      assert_receive {:notification, :sonar, %{ping: true}}
      refute MapSet.member?(DemoNotifier.listeners(notifier_name, :sonar), sonar_pid)

      Supervisor.stop(sup)
    end
  end

  describe "rest_for_one: notifier crash properly restarts sonar" do
    @tag :tmp_dir
    test "sonar re-registers after notifier restarts", %{tmp_dir: tmp_dir} do
      notifier_name = :"notifier_rfo_#{tmp_dir}" |> unique_name()
      sonar_name = :"sonar_rfo_#{tmp_dir}" |> unique_name()

      children = [
        {DemoNotifier, name: notifier_name},
        {DemoSonar, name: sonar_name, notifier: notifier_name}
      ]

      {:ok, sup} = Supervisor.start_link(children, strategy: :rest_for_one)

      # Save original pids.
      notifier_pid = GenServer.whereis(notifier_name)
      sonar_pid = GenServer.whereis(sonar_name)

      # Kill the Notifier. rest_for_one restarts Notifier and everything after it (Sonar).
      Process.exit(notifier_pid, :kill)

      # Wait for both processes to come back with new pids.
      poll_until(fn ->
        new_notifier = GenServer.whereis(notifier_name)
        new_sonar = GenServer.whereis(sonar_name)

        new_notifier != nil and new_notifier != notifier_pid and
          new_sonar != nil and new_sonar != sonar_pid
      end)

      # Sonar got a new pid — it was restarted.
      new_sonar_pid = GenServer.whereis(sonar_name)
      assert new_sonar_pid != sonar_pid

      # The new Sonar re-registered itself as a listener during its fresh init.
      assert MapSet.member?(DemoNotifier.listeners(notifier_name, :sonar), new_sonar_pid)

      # Register the test process to observe notifications.
      DemoNotifier.listen(notifier_name, :sonar)

      # Ping works end-to-end: Sonar broadcasts, test process receives.
      assert DemoSonar.ping(sonar_name) == :ok
      assert_receive {:notification, :sonar, %{ping: true}}

      Supervisor.stop(sup)
    end
  end

  # --- Helpers ---

  # Generates a unique registered name to avoid conflicts in async tests.
  defp unique_name(base) do
    :"#{base}_#{System.unique_integer([:positive, :monotonic])}"
  end

  # Polls a function until it returns truthy or times out.
  defp poll_until(fun, timeout \\ 1000, interval \\ 10) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_poll(fun, deadline, interval)
  end

  defp do_poll(fun, deadline, interval) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("poll_until timed out after waiting for condition")
      else
        Process.sleep(interval)
        do_poll(fun, deadline, interval)
      end
    end
  end
end
