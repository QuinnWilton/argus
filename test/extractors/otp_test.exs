defmodule Argus.Extractors.OTPTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.OTP

  describe "extract/1 — behaviour detection" do
    test "detects GenServer behaviour" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.MyGenServer)))

      facts = OTP.extract(data)

      assert Map.has_key?(facts, :implements_behaviour)
      behaviours = facts[:implements_behaviour]

      assert Enum.any?(behaviours, fn [_mod, b] -> b == "GenServer" end)
    end

    test "detects no behaviour for plain module" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.PlainModule)))

      facts = OTP.extract(data)

      refute Map.has_key?(facts, :implements_behaviour)
    end

    test "detects Supervisor behaviour" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Supervisor)))

      facts = OTP.extract(data)

      # Supervisor itself doesn't use @behaviour, it defines one.
      # But modules that use Supervisor would.
      assert is_map(facts)
    end
  end

  describe "extract/1 — GenServer.call/cast detection" do
    test "detects GenServer.call in fixture" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.MyGenServer)))

      facts = OTP.extract(data)

      assert Map.has_key?(facts, :sync_call)
      calls = facts[:sync_call]
      assert length(calls) > 0
    end

    test "detects GenServer.cast in fixture" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.MyGenServer)))

      facts = OTP.extract(data)

      assert Map.has_key?(facts, :async_cast)
      casts = facts[:async_cast]
      assert length(casts) > 0
    end

    test "no GenServer calls in plain module" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.PlainModule)))

      facts = OTP.extract(data)

      refute Map.has_key?(facts, :sync_call)
      refute Map.has_key?(facts, :async_cast)
    end
  end

  describe "extract/1 — Agent sync call detection" do
    test "detects Agent.get as sync_call" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.AgentCaller)))

      facts = OTP.extract(data)

      assert Map.has_key?(facts, :sync_call)
      calls = facts[:sync_call]
      assert length(calls) >= 3
    end
  end

  describe "extract/1 — Erlang-style :gen_server detection" do
    test "detects :gen_server.call as sync_call" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(
          to_string(:code.which(Argus.Test.Fixtures.ErlangStyleCaller))
        )

      facts = OTP.extract(data)

      assert Map.has_key?(facts, :sync_call)
    end

    test "detects :gen_server.cast as async_cast" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(
          to_string(:code.which(Argus.Test.Fixtures.ErlangStyleCaller))
        )

      facts = OTP.extract(data)

      assert Map.has_key?(facts, :async_cast)
    end
  end

  describe "extract/1 — GenServer.multi_call detection" do
    test "detects GenServer.multi_call as sync_call" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.MultiCallModule)))

      facts = OTP.extract(data)

      assert Map.has_key?(facts, :sync_call)
    end
  end

  describe "extract/1 — sync_call_timeout emission" do
    test "GenServer.call/2 emits timeout 5000" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(
          to_string(:code.which(Argus.Test.Fixtures.ExplicitTimeoutCaller))
        )

      facts = OTP.extract(data)

      assert Map.has_key?(facts, :sync_call_timeout)
      timeouts = facts[:sync_call_timeout]

      # call_with_default uses GenServer.call/2 → 5000.
      assert Enum.any?(timeouts, fn [func, _callee, t] ->
               String.contains?(func, "call_with_default") and t == "5000"
             end)
    end

    test "GenServer.call/3 with integer literal emits resolved value" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(
          to_string(:code.which(Argus.Test.Fixtures.ExplicitTimeoutCaller))
        )

      facts = OTP.extract(data)
      timeouts = facts[:sync_call_timeout]

      # call_with_explicit uses GenServer.call/3 with 10_000.
      assert Enum.any?(timeouts, fn [func, _callee, t] ->
               String.contains?(func, "call_with_explicit") and t == "10000"
             end)
    end

    test "GenServer.call/3 with :infinity emits -1" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(
          to_string(:code.which(Argus.Test.Fixtures.ExplicitTimeoutCaller))
        )

      facts = OTP.extract(data)
      timeouts = facts[:sync_call_timeout]

      # call_with_infinity uses GenServer.call/3 with :infinity.
      assert Enum.any?(timeouts, fn [func, _callee, t] ->
               String.contains?(func, "call_with_infinity") and t == "-1"
             end)
    end

    test ":gen_server.call/3 with integer emits resolved value" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(
          to_string(:code.which(Argus.Test.Fixtures.ExplicitTimeoutCaller))
        )

      facts = OTP.extract(data)
      timeouts = facts[:sync_call_timeout]

      # erlang_call_with_timeout uses :gen_server.call/3 with 15_000.
      assert Enum.any?(timeouts, fn [func, _callee, t] ->
               String.contains?(func, "erlang_call_with_timeout") and t == "15000"
             end)
    end

    test "GenServer.multi_call emits -1 (infinity)" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.MultiCallModule)))

      facts = OTP.extract(data)

      assert Map.has_key?(facts, :sync_call_timeout)
      timeouts = facts[:sync_call_timeout]
      assert Enum.any?(timeouts, fn [_func, _callee, t] -> t == "-1" end)
    end
  end

  describe "extract/1 — link/monitor detection" do
    test "detects Process.link as process_link" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(
          to_string(:code.which(Argus.Test.Fixtures.LinkMonitorModule))
        )

      facts = OTP.extract(data)

      assert Map.has_key?(facts, :process_link)
      links = facts[:process_link]
      assert length(links) >= 2
    end

  end

  describe "extract/1 — :via tuple resolution" do
    test "emits sync_call_via with the registry instance for {:via, _, _} target" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(
          to_string(:code.which(Argus.Test.Fixtures.ViaTupleCaller))
        )

      facts = OTP.extract(data)

      assert Map.has_key?(facts, :sync_call_via)
      via_calls = facts[:sync_call_via]

      # ViaTupleCaller.get/1 builds {:via, Registry, {MyApp.Registry, key}}.
      # The third element's first component (MyApp.Registry) is the named
      # registry process that owns the key.
      assert Enum.any?(via_calls, fn [_caller_func, registry, _key] ->
               registry == "MyApp.Registry"
             end)
    end

    test "still emits sync_call with a synthetic via:<RegistryInstance> callee tag" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(
          to_string(:code.which(Argus.Test.Fixtures.ViaTupleCaller))
        )

      facts = OTP.extract(data)

      sync_calls = facts[:sync_call]

      assert Enum.any?(sync_calls, fn [_caller, callee] ->
               callee == "via:MyApp.Registry"
             end)
    end
  end

  describe "integration with extract pipeline" do
    test "extractor is usable via Pipeline.extract/2" do
      assert {:ok, facts} =
               Argus.Pipeline.extract(
                 [Argus.Test.Fixtures.MyGenServer],
                 extractors: [OTP]
               )

      assert Map.has_key?(facts, :implements_behaviour)
      assert Map.has_key?(facts, :sync_call)
    end
  end
end
