defmodule Argus.Extractors.ReplyTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.Reply
  alias Argus.Test.Fixtures.Reply, as: R

  defp extract(mod) do
    {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))
    Reply.extract(data)
  end

  describe "callback_stop_reason" do
    test "a literal atom and a {:shutdown, term} literal are recorded; a computed reason is not" do
      facts = extract(R.StopsNormally)

      reasons =
        facts[:callback_stop_reason]
        |> Enum.map(fn [_id, func, reason] -> {func, reason} end)
        |> Enum.sort()

      assert reasons == [
               {"Argus.Test.Fixtures.Reply.StopsNormally:handle_call/3", ":normal"},
               {"Argus.Test.Fixtures.Reply.StopsNormally:handle_cast/2", ":shutdown"}
             ]
    end
  end

  describe "callback_timeout" do
    test "integer timeouts are recorded in every position; :hibernate and {:continue, _} are not" do
      facts = extract(R.TimesOut)

      timeouts =
        facts[:callback_timeout]
        |> Enum.map(fn [_id, _func, callback, ms] -> {callback, ms} end)
        |> Enum.sort()

      assert timeouts == [{"handle_call", "10"}, {"handle_info", "5000"}, {"init", "0"}]
    end

    test "a return folded into one literal still yields its tag" do
      facts = extract(R.TimesOut)

      assert Enum.any?(facts[:callback_return], fn [_id, func, "init", ":ok"] ->
               String.ends_with?(func, "TimesOut:init/1")
             end)
    end
  end
end
