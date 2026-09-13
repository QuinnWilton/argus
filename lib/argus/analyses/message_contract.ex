defmodule Argus.Analyses.MessageContract do
  @moduledoc """
  A message a module sends itself and cannot handle.

  A GenServer is one contract written in two places. The client half is an
  ordinary function — `def get(pid, k), do: GenServer.call(pid, {:get, k})`
  — and the server half is a `handle_call/3` clause. Nothing checks they
  agree: rename the tag on one side and it compiles clean.

  `call` then raises `FunctionClauseError` in the server and the caller
  exits with it. `cast` is worse — the caller is told nothing at all, the
  server dies, the supervisor restarts it, and its state is gone.

  ## Why this is sound now and was not before

  An earlier version took the client's tag from an extractor that scanned
  backwards for the last write to `{x,1}`. That is not the write that
  *reaches* the call, and it reported `:amqp_channel` as casting `:ok` when
  the write it found was really `gen_server:reply(From, ok)`.

  The tag is now a join: `def_use` names the write that actually feeds the
  call, and `tuple_literal`/`literal_value` carry the constant and the
  register it landed in — the register mattering because `def_use` says
  which write feeds which read but not which *operand*.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :message_contract

  @impl true
  def description, do: "messages a module sends itself but cannot handle"

  @impl true
  def rules_file, do: "analyses/message_contract.dl"

  @impl true
  def extractors,
    do: [Argus.Extractors.CallbackTag, Argus.Extractors.OTP, Argus.Extractors.ApiCalls]

  @impl true
  def output_relations do
    [
      %{
        name: :unhandled_self_message,
        fields: [
          {:mod, :symbol, "the module"},
          {:sender, :symbol, "the function sending it"},
          {:kind, :symbol, "'call' or 'cast'"},
          {:tag, :symbol, "the message tag"}
        ],
        key: [:mod, :kind, :tag],
        doc: "A tag sent to the module's own server with no matching clause."
      }
    ]
  end

  @impl true
  def finding(:unhandled_self_message, [mod, sender, kind, tag]) do
    Findings.new(
      :error,
      "#{mod} sends itself #{tag}, which it cannot handle",
      "#{sender} sends #{tag} via GenServer.#{kind}/2, and #{mod}'s " <>
        "handle_#{kind} has no clause matching it and no catch-all. " <>
        consequence(kind) <>
        " The two halves of this contract live in different places and " <>
        "nothing checks they agree, so renaming a tag on one side compiles " <>
        "clean and fails only when that path runs. " <>
        "Either add the clause, or fix the tag at the call site.",
      at: Findings.at_func(sender)
    )
  end

  defp consequence("call") do
    "The server raises FunctionClauseError and exits; the caller's " <>
      "GenServer.call exits with it, pointing at the call rather than at the " <>
      "missing clause."
  end

  defp consequence("cast") do
    "Casts are fire-and-forget, so the caller is told nothing: the server " <>
      "dies, the supervisor restarts it, its state is gone, and the only " <>
      "trace is a crash report nobody connected to this function."
  end

  defp consequence(_other), do: ""
end
