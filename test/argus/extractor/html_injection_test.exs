defmodule Argus.Extractor.HtmlInjectionTest do
  use ExUnit.Case, async: true
  use Argus.Test.Peer

  alias Argus.Extractors.HtmlInjection
  alias Argus.Test.Fixtures.HtmlInjection, as: Fixture
  alias Argus.Test.Peer

  setup_all do
    {:ok, facts} = Argus.Pipeline.extract([Fixture], extractors: [HtmlInjection])
    %{facts: facts}
  end

  defp escaped?(facts, function) do
    Enum.any?(Map.get(facts, :html_input_escaped, []), fn [_, func, _] ->
      String.ends_with?(func, ":" <> function)
    end)
  end

  test "QR library names and fixed options do not establish safety", %{
    facts: facts
  } do
    refute escaped?(facts, "qr_svg/1")
    refute escaped?(facts, "qr_local/1")
    refute escaped?(facts, "qr_dynamic_options/2")
    refute escaped?(facts, "qr_dynamic_matrix/1")
    refute escaped?(facts, "qr_attribute/2")
    refute escaped?(facts, "qr_literal_attribute/1")
  end

  test "anonymous callbacks retain unknown invocation arguments", %{facts: facts} do
    refute escaped?(facts, "captured_sink/2")
    refute escaped?(facts, "controller/2")
  end

  @tag :flowlog
  test "a different implementation of a known renderer name is never trusted" do
    peer = Peer.start!(store: :own)

    Peer.run(peer, fn ->
      beams =
        Code.compile_string(~S"""
        defmodule EQRCode do
          @compile {:no_warn_undefined, [Phoenix.HTML]}
          def encode(value), do: value
          def svg(value, _options), do: value
          def render(value), do: Phoenix.HTML.raw(svg(encode(value), width: 200))
        end

        defmodule QrNamedCaller do
          @compile {:no_warn_undefined, [Phoenix.HTML]}
          def render(value), do: Phoenix.HTML.raw(EQRCode.svg(EQRCode.encode(value), width: 200))
        end
        """)

      {_, caller_beam} = Enum.find(beams, fn {mod, _} -> mod == QrNamedCaller end)
      {:ok, data} = Argus.Pipeline.Disassemble.disassemble_path(caller_beam)
      facts = HtmlInjection.extract(data)
      assert Map.get(facts, :html_input_escaped, []) == []

      {:ok, rows} = Argus.analyze(Enum.map(beams, &elem(&1, 1)), :unsafe_input)

      assert Enum.any?(rows["unescaped_html_from_input"], fn [_, func, _] ->
               func == "EQRCode:render/1"
             end)
    end)
  end
end
