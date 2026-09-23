defmodule Argus.Findings.NamesTest do
  use ExUnit.Case, async: true

  alias Argus.Findings
  alias Argus.Findings.Names

  doctest Argus.Findings.Names

  test "render/1 rewrites every piece of prose a finding carries, and nothing else" do
    attrs =
      Findings.new(:warning, "Foo:run/1 blocks", "Foo:-run/1-fun-0-/2 calls :gen_server:call/2.",
        at: Findings.at_instr("Foo:run/1#3"),
        at_label: "Foo:run/1 here",
        help: ["Move Foo:run/1."],
        related: [Findings.related("Bar:stop/0 stops it", Findings.at_func("Bar:stop/0"))]
      )

    rendered = Names.render(attrs)

    assert rendered.title == "Foo.run/1 blocks"
    assert rendered.detail == "An anonymous function in Foo.run/1 calls :gen_server.call/2."
    assert rendered.at_label == "Foo.run/1 here"
    assert rendered.help == ["Move Foo.run/1."]
    assert [%{label: "Bar.stop/0 stops it"}] = rendered.related
    assert rendered.instr == attrs.instr
  end

  test "an instruction ID and a raw column keep their spelling" do
    assert Names.plain("at Foo:run/1#3") == "at Foo:run/1#3"
    assert Names.plain("site=Foo:run/1") == "site=Foo:run/1"
    assert Names.plain(nil) == nil
  end

  test "the Argus.Findings delegates are the name helpers" do
    assert Findings.call_name("GenServer:call/2") == Names.call_name("GenServer:call/2")
    assert Findings.elsewhere("M:a/0#1", "M:b/0") == Names.elsewhere("M:a/0#1", "M:b/0")
    assert Findings.rpc_api("erpc") == Names.rpc_api("erpc")
  end
end
