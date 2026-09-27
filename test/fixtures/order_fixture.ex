defmodule Argus.Test.Fixtures.Order do
  @moduledoc false
  # Shapes clientlib/order.dl's runs_after must order: each helper is a
  # distinct remote call, so a test names an instruction by its callee.

  alias Argus.Test.Fixtures.Order.Steps

  # One straight path: first, then second, then third.
  def straight do
    Steps.first()
    Steps.second()
    Steps.third()
  end

  # Two arms of a branch, and what both lead to: neither arm runs after
  # the other, and the join runs after both.
  def arms(flag) do
    if flag, do: Steps.left(), else: Steps.right()
    Steps.join()
  end

  # Two clauses of one function: the second clause's call is later in
  # the function, and never after the first clause's.
  def clauses(:one), do: Steps.clause_one()
  def clauses(:two), do: Steps.clause_two()

  # A receive, a clause's body inside it, and a call after it: the body
  # and the call run after the receive, and the receive after neither
  # (its wait loop is no flow).
  def waits do
    receive do
      :go -> Steps.in_clause()
    end

    Steps.after_receive()
  end

  # A try: the handler runs after the try, not after what it covers.
  def guarded do
    try do
      Steps.covered()
    rescue
      _ -> Steps.handler()
    end
  end
end

defmodule Argus.Test.Fixtures.Order.Steps do
  @moduledoc false
  def first, do: :ok
  def second, do: :ok
  def third, do: :ok
  def left, do: :ok
  def right, do: :ok
  def join, do: :ok
  def clause_one, do: :ok
  def clause_two, do: :ok
  def in_clause, do: :ok
  def after_receive, do: :ok
  def covered, do: :ok
  def handler, do: :ok
end
