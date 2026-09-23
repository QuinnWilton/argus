defmodule Argus.Findings.AnchorTest do
  use ExUnit.Case, async: true

  alias Argus.Findings
  alias Argus.Findings.Anchor
  alias Argus.InstrId

  doctest Argus.Findings.Anchor

  describe "from_row/1" do
    test "takes the first value that parses, an instruction or a function" do
      assert %{instr: %InstrId{idx: 2}} = Anchor.from_row(["M", "M:f/1#2", "M:g/0"])
      assert %{mfa: {M, :g, 0}, instr: nil} = Anchor.from_row(["M", "dynamic", "M:g/0"])
    end

    test "a module string alone is not an anchor for a row" do
      assert Anchor.from_row(["M", ":lists"]) == Anchor.empty()
      assert Anchor.from_row([]) == Anchor.empty()
    end
  end

  test "the Argus.Findings delegates are the anchor constructors" do
    for id <- ["M:f/1#2", "M:f/1", ":lists", "dynamic", ""] do
      assert Findings.at_instr(id) == Anchor.at_instr(id)
      assert Findings.at_func(id) == Anchor.at_func(id)
      assert Findings.at_module(id) == Anchor.at_module(id)
      assert Findings.at_site(id, "M") == Anchor.at_site(id, "M")
      assert Findings.at_site_in_func(id, "M:g/0") == Anchor.at_site_in_func(id, "M:g/0")
      assert Findings.module_atom(id) == Anchor.module_atom(id)
    end

    assert Findings.at_mfa("M", :init, 1) == Anchor.at_mfa("M", :init, 1)
  end
end
