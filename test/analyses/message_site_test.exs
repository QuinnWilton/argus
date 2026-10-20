defmodule Argus.Analyses.MessageSiteTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Test.Fixtures.MessageSite, as: M
  alias Argus.Test.Memo

  # The atom sinks reported, by the client export whose input reaches them.
  defp atom_findings(client) do
    assert {:ok, r} = Memo.analyze([M.Atoms, M.Echo, client], :unsafe_input)

    for f <- Argus.Findings.build(Argus.Analyses.UnsafeInput, r),
        f.title =~ "atom",
        do: f.mfa
  end

  test "a client's message reaches the server of the call that carries it" do
    assert atom_findings(M.Interns) != []
  end

  test "a client calling two servers hands its parameter to the one its call names" do
    assert atom_findings(M.Mixed) == []
  end

  test "a call to a pid the client started reaches that server" do
    assert atom_findings(M.OwnServer) != []
  end
end
