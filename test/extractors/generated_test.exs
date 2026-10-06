defmodule Argus.Extractors.GeneratedTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.Generated
  alias Argus.Test.Fixtures.LateMessage

  defp facts(mod) do
    {:ok, facts} = Argus.Pipeline.extract([mod], extractors: [Generated])
    facts
  end

  describe "macro_written" do
    test "a function whose every clause a macro wrote" do
      assert ["#{inspect(LateMessage.Warmer)}:handle_info/2"] in facts(LateMessage.Warmer)[
               :macro_written
             ]
    end

    test "a macro's clause ahead of the module's own marks the definition, not every clause" do
      facts = facts(LateMessage.MixedHandler)
      func = "#{inspect(LateMessage.MixedHandler)}:handle_info/2"

      assert Enum.any?(facts[:macro_generated], &match?([^func, _], &1))
      refute [func] in Map.get(facts, :macro_written, [])
    end
  end

  describe "default-argument shims" do
    # Elixir 1.20 gives every shim the compiler's own context
    # (`:elixir_def`); a shim was written where its definition was.
    test "a module's own definition's shims are its own" do
      [{_mod, bin}] =
        Code.compile_string("""
        defmodule Argus.GeneratedTest.OwnDefaults do
          def own(a, b \\\\ 1, c \\\\ 2), do: {a, b, c}
        end
        """)

      {:ok, facts} = Argus.Pipeline.extract([bin], extractors: [Generated])
      assert Map.get(facts, :macro_generated, []) == []
      assert Map.get(facts, :macro_written, []) == []
    end

    test "a macro's definition's shims are the macro's" do
      facts = facts(Argus.Test.Fixtures.SqlRepoGenerated)
      mod = "Argus.Test.Fixtures.SqlRepoGenerated"

      for fun <- ~w(query/1 query/2 query!/1 query!/2) do
        assert ["#{mod}:#{fun}", "Ecto.Adapters.SQL"] in facts[:macro_generated], fun
        assert ["#{mod}:#{fun}"] in facts[:macro_written], fun
      end
    end
  end

  describe "an OTP header's functions" do
    test "a function under a -file naming an OTP header is that header's" do
      facts = facts(:header_catchall)

      assert Enum.sort(facts[:macro_generated]) == [
               [":header_catchall:yecctoken2string/1", "yeccpre.hrl"],
               [":header_catchall:yecctoken_to_string/1", "yeccpre.hrl"]
             ]

      # The program's own header, and the module's own code, are not.
      refute [":header_catchall:from_own_header/1"] in facts[:macro_written]
      refute [":header_catchall:own/1"] in facts[:macro_written]
    end

    test "without debug info, yecc's output is known by the names it fixes" do
      {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(:header_catchall)))

      parser =
        data
        |> Map.put(:debug_info, :error)
        |> Map.update!(:functions, fn functions ->
          [{:function, :yeccpars0, 5, 0, []} | functions]
        end)

      written = parser |> Generated.extract() |> Map.fetch!(:macro_written) |> Enum.sort()

      assert written == [
               [":header_catchall:yeccpars0/5"],
               [":header_catchall:yecctoken2string/1"],
               [":header_catchall:yecctoken_to_string/1"]
             ]

      # Without yeccpars0/5 a yecc-like name is nobody's but the module's.
      assert data |> Map.put(:debug_info, :error) |> Generated.extract() == %{}
    end
  end
end
