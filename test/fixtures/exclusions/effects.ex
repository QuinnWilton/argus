# Cases for effects exclusions and nearby defects that must remain reported.
# Asserted by test/exclusions/effects_test.exs.

# Each shape has a repo of its own, so the two are disjoint programs.
defmodule Excl.Effects.CapturedBody.Repo do
  @moduledoc false
  @behaviour Ecto.Repo

  def transaction(fun), do: fun.()
  def insert(x), do: {:ok, x}
end

defmodule Excl.Effects.CapturedBody.Ledger do
  @moduledoc false
  alias Excl.Effects.CapturedBody.Repo

  def close_day, do: Repo.insert(:closing_entry)
end

# Tells each subscriber the day is closing, then closes the ledger in a
# transaction handed a remote capture. The function's one closure is the
# notifier, which runs before and outside the transaction: its webhook
# escapes no transaction, and the transaction's body is the capture.
defmodule Excl.Effects.CapturedBody.EndOfDay do
  @moduledoc false
  alias Excl.Effects.CapturedBody.{Ledger, Repo}

  def run(subscribers) do
    Enum.each(subscribers, fn url -> :httpc.request(url) end)
    Repo.transaction(&Ledger.close_day/0)
  end
end

# The same end of day with the webhook inside the transaction's closure:
# a rollback cannot take the request back. The bug the capture above
# does not have.
defmodule Excl.Effects.ClosureBody.Repo do
  @moduledoc false
  @behaviour Ecto.Repo

  def transaction(fun), do: fun.()
  def insert(x), do: {:ok, x}
end

defmodule Excl.Effects.ClosureBody.EndOfDay do
  @moduledoc false
  alias Excl.Effects.ClosureBody.Repo

  def run(subscribers) do
    Repo.transaction(fn ->
      Repo.insert(:closing_entry)
      Enum.each(subscribers, fn url -> :httpc.request(url) end)
    end)
  end
end
