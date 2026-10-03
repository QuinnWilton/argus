defmodule Argus.Analyses.FailureRpcTargetTest do
  use ExUnit.Case, async: true

  alias Argus.Analyses.Failure
  alias Argus.Test.Fixtures.RpcTarget
  alias Argus.Test.Memo
  alias Argus.Test.Rows

  # `{function, through a wrapper?, callee, why}`, fixture prefix dropped.
  defp undefined do
    assert {:ok, results} =
             Memo.analyze(
               [RpcTarget.Remote, RpcTarget.Wrapper, RpcTarget.Caller],
               :failure
             )

    for [func, anchor, site, callee, why] <- Rows.where(results, :failure, "rpc_undefined", []) do
      short = &String.replace(&1, "Argus.Test.Fixtures.RpcTarget.", "")
      {short.(func), anchor != site, short.(callee), why}
    end
    |> Enum.sort()
  end

  describe "rpc_undefined" do
    @describetag :souffle

    test "an rpc to a function its module does not export, direct or through a wrapper" do
      assert undefined() == [
               {"Caller:forwarded/1", true, "Remote:nope/0", "missing"},
               {"Caller:missing/1", true, "Remote:run_db_request/2", "missing"},
               {"Caller:private/1", false, "Remote:secret/1", "private"},
               {"Caller:wrong_arity/1", false, "Remote:run/3", "missing"}
             ]
    end
  end

  describe "rpc_undefined prose" do
    test "the title names no function; the detail and the wrapper frame do" do
      finding =
        Failure.finding(:rpc_undefined, ["M:f/1", "M:f/1#3", "W:call/4#5", "R:go/2", "missing"])

      assert finding.severity == :error
      refute finding.title =~ "go"
      assert finding.detail =~ "R.go/2"
      assert [%{label: "the rpc the wrapper makes"}] = finding.related
    end
  end
end
