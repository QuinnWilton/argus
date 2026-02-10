defmodule Argus.Test.Fixtures.ConstantPropagationFixture do
  @moduledoc false

  # Linear constant chain: val assigned a literal, then used.
  def constant_chain do
    val = :hello
    result = val
    result
  end

  # Branching with different literals.
  def branching(flag) do
    x =
      if flag do
        :yes
      else
        :no
      end

    x
  end
end
