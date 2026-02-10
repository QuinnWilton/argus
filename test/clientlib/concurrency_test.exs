defmodule Argus.Clientlib.ConcurrencyTest do
  use ExUnit.Case

  alias Argus.Extract
  alias Argus.Souffle.CLI

  @moduletag :tmp_dir

  defp skip_without_souffle do
    unless CLI.available?(), do: flunk("souffle not installed")
  end

  defp priv_dl, do: Path.join(:code.priv_dir(:argus), "dl")

  describe "concurrency.dl" do
    @tag :tmp_dir
    test "identifies sender and receiver functions", %{tmp_dir: tmp_dir} do
      skip_without_souffle()

      facts_dir = Path.join(tmp_dir, "facts")
      {:ok, _} = Extract.run([:gen], facts_dir)

      rules = """
      .include "#{Path.join(priv_dl(), "clientlib/imports.dl")}"

      .decl send_msg(id: symbol)
      .input send_msg

      .decl recv_start(id: symbol, fail: number)
      .input recv_start

      .decl recv_end(id: symbol)
      .input recv_end

      .decl spawn_call(id: symbol, mod: symbol, func: symbol, arity: number, variant: symbol)
      .input spawn_call

      .include "#{Path.join(priv_dl(), "clientlib/concurrency.dl")}"

      .output sender_function
      .output receiver_function
      .output potential_message_path
      .output spawner_function
      """

      rules_path = Path.join(tmp_dir, "test_concurrency.dl")
      File.write!(rules_path, rules)

      # Create empty .facts files for any inputs that may not exist.
      for name <- ~w(send_msg spawn_call) do
        path = Path.join(facts_dir, "#{name}.facts")
        unless File.exists?(path), do: File.write!(path, "")
      end

      assert {:ok, results} = CLI.run(facts_dir, rules_path)

      # :gen has receive instructions, so receiver_function should be populated.
      assert Map.has_key?(results, "receiver_function")
      assert length(results["receiver_function"]) > 0
    end
  end
end
