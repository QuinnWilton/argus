defmodule Argus.Extractors.ToolingTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.Tooling

  defp rows(mods) do
    {:ok, facts} = Argus.Pipeline.extract(mods, extractors: [Tooling])
    Enum.sort(Map.get(facts, :tooling_module, []))
  end

  # A module compiled from `path`, as a beam binary the pipeline reads.
  defp compiled(name, path) do
    [{_mod, beam}] = Code.compile_string("defmodule #{name} do\n def x, do: 1\nend", path)
    beam
  end

  test "a module under Mix. is tooling by its name" do
    assert rows([Mix.ArgusFixtures.Seed, Argus.Test.Fixtures.Tooling.Product]) == [
             ["Mix.ArgusFixtures.Seed", "mix"]
           ]
  end

  test "a module compiled from test support is tooling by its path" do
    beams = [
      compiled("Argus.ToolingTest.Case", "/proj/test/support/conn_case.ex"),
      compiled("Argus.ToolingTest.Client", "/proj/deps/lv/lib/lv/test/client_proxy.ex"),
      compiled("Argus.ToolingTest.Server", "/proj/lib/app/server.ex")
    ]

    assert rows(beams) == [
             ["Argus.ToolingTest.Case", "test_support"],
             ["Argus.ToolingTest.Client", "test_support"]
           ]
  end

  describe "test_support?/1" do
    test "test/support, and a test directory within three of a lib" do
      assert Tooling.test_support?("/p/test/support/data_case.ex")
      assert Tooling.test_support?("/p/test/support/proto/mock.pb.ex")
      assert Tooling.test_support?("/p/deps/phoenix/lib/phoenix/test/conn_test.ex")
      assert Tooling.test_support?("/p/deps/plug/lib/plug/adapters/test/conn.ex")
    end

    test "a checkout under a directory named test, a test fixture, a file named test" do
      # The project sits below the test directory: lib under it.
      refute Tooling.test_support?("/ci/test/app/lib/app/server.ex")
      refute Tooling.test_support?("/ci/test/app/src/server.erl")
      # A project's own test fixtures stand for the product in its tests.
      refute Tooling.test_support?("/home/me/argus/test/fixtures/secret_fixture.ex")
      refute Tooling.test_support?("/p/lib/app/test.ex")
      refute Tooling.test_support?("/p/lib/app/ab_test/variant.ex")
      refute Tooling.test_support?(nil)
    end
  end
end
