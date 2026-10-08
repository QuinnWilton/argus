defmodule Argus.Clientlib.RunsTest do
  @moduledoc """
  clientlib/runs.dl's messages a process sends itself, solved over
  fixtures and read directly: what the once/again split and the mailbox
  rules take as the process's own messages.
  """
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.{Analysis, Pipeline}
  alias Argus.Test.Files
  alias Argus.Test.Fixtures, as: F
  alias Argus.Test.Soundness.Runs, as: R

  @modules [R.TimeoutAgain, F.StatemDataFromArgs, F.MyEventHandler]

  setup_all do
    dir = Files.tmp_dir!("argus_runs")
    facts = Path.join(dir, "facts")
    {:ok, _} = Pipeline.run(@modules, facts, extractors: Argus.Analyses.Mailbox.extractors())
    :ok = Analysis.derive_stage0(facts)
    :ok = Analysis.derive_points_to(facts)

    lib = Path.join(:code.priv_dir(:argus_beam), "dl/clientlib")
    rules = Path.join(dir, "runs.dl")

    File.write!(rules, """
    .include "#{lib}/imports.dl"
    .include "#{lib}/otp.dl"
    .include "#{lib}/runs.dl"
    .decl timeout(func: symbol)
    .output timeout
    timeout(f) :- self_message(_, f, "info", ":timeout").
    """)

    {:ok, results} = Argus.FlowLog.run(facts, rules)
    %{timeouts: results["timeout"] |> Enum.map(&hd/1) |> Enum.sort()}
  end

  # gen_server's {:ok, state, ms} and {:noreply, state, ms} arm its idle
  # timeout. A gen_statem's {ok, State, Data} with Data its argument, and a
  # gen_event handler's {ok, Reply, State}, are the same three-element :ok
  # tuple, which the OTP extractor reads alike, and arm none.
  test "the :timeout a gen_server's idle timeout sends, and only it", %{timeouts: timeouts} do
    assert timeouts == [
             inspect(R.TimeoutAgain) <> ":handle_cast/2",
             inspect(R.TimeoutAgain) <> ":init/1"
           ]
  end
end
