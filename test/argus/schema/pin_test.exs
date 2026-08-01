defmodule Argus.Schema.PinTest do
  @moduledoc """
  The pin's whole job is to fail a build, so every test here compiles a
  module and asserts on what happened at compile time. Asserting on the
  message text matters more than usual: the message is the only thing the
  next person sees, and a pin that fails without saying what to re-read
  just gets widened blindly.
  """

  use ExUnit.Case, async: true

  # Each test compiles a module, so names must not collide across the run.
  defp unique_module, do: :"Elixir.PinFixture#{System.unique_integer([:positive])}"

  # CompileError's message/1 varies across Elixir versions in whether it
  # prefixes file/line; read the description so assertions test our text.
  defp message(%CompileError{description: description}), do: description
  defp message(other), do: Exception.message(other)

  defp compile(body) do
    name = unique_module()

    Code.compile_string("""
    defmodule #{inspect(name)} do
      #{body}
    end
    """)

    name
  end

  describe "accepting the current version" do
    test "a range spanning it compiles" do
      current = Argus.Schema.version()
      mod = compile("use Argus.Schema.Pin, versions: 3..#{current}")

      assert Enum.to_list(3..current) == mod.__argus_schema_versions__()
    end

    test "an explicit list containing it compiles" do
      current = Argus.Schema.version()
      mod = compile("use Argus.Schema.Pin, versions: [#{current}, 99]")

      assert [current, 99] == mod.__argus_schema_versions__()
    end

    test "a single-version pin compiles when it is the current one" do
      current = Argus.Schema.version()
      mod = compile("use Argus.Schema.Pin, versions: #{current}..#{current}")

      assert [current] == mod.__argus_schema_versions__()
    end

    test "the accessor can be renamed" do
      current = Argus.Schema.version()
      mod = compile("use Argus.Schema.Pin, versions: #{current}..#{current}, as: :pinned")

      assert [current] == mod.pinned()
    end
  end

  describe "rejecting a version outside the pin" do
    test "raises when the schema has moved past the pin" do
      assert_raise CompileError, fn ->
        compile("use Argus.Schema.Pin, versions: 1..2")
      end
    end

    test "raises when the schema is older than the pin" do
      future = Argus.Schema.version() + 10

      assert_raise CompileError, fn ->
        compile("use Argus.Schema.Pin, versions: #{future}..#{future + 1}")
      end
    end

    test "the message names the consumer, both versions, and what to review" do
      err =
        assert_raise CompileError, fn ->
          Code.compile_string("""
          defmodule PinFixtureNamed do
            use Argus.Schema.Pin, versions: 1..2, review: "Widget.Decoder"
          end
          """)
        end

      msg = message(err)

      assert msg =~ "PinFixtureNamed"
      assert msg =~ "versions 1-2"
      assert msg =~ "version #{Argus.Schema.version()}"
      assert msg =~ "Widget.Decoder"
      assert msg =~ "CHANGELOG"
    end

    test "a non-contiguous pin is listed rather than collapsed to a range" do
      err =
        assert_raise CompileError, fn ->
          compile("use Argus.Schema.Pin, versions: [1, 2, 5]")
        end

      # Rendering [1,2,5] as "1-5" would hide the hole, which is the one
      # thing a reader needs to notice.
      assert message(err) =~ "versions 1, 2, 5"
      refute message(err) =~ "versions 1-5"
    end
  end

  describe "rejecting a malformed pin" do
    test "requires :versions" do
      assert_raise CompileError, ~r/requires a :versions option/, fn ->
        compile("use Argus.Schema.Pin, review: \"nothing\"")
      end
    end

    test "rejects an empty list" do
      assert_raise CompileError, ~r/non-empty range or list/, fn ->
        compile("use Argus.Schema.Pin, versions: []")
      end
    end

    test "rejects non-integer versions" do
      assert_raise CompileError, ~r/non-empty range or list/, fn ->
        compile("use Argus.Schema.Pin, versions: [:v8]")
      end
    end

    test "rejects a bare integer, which would silently mean something else" do
      # `versions: 8` is the tempting shorthand, and Enum-ing an integer
      # would raise something unhelpful much later.
      assert_raise CompileError, ~r/non-empty range or list/, fn ->
        compile("use Argus.Schema.Pin, versions: 8")
      end
    end
  end
end
