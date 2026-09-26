# 8ebfbd53: a file under a `test/` directory within three of a `lib/` is
# test support. Here `test` is the product's domain (an exam platform's
# Test context), and a controller calls it.
defmodule Argus.Test.Soundness.G9.Exam.Test.Grader do
  @moduledoc "An exam platform's Test context: product code under lib/exam/test/."

  @doc "A submitted answer evaluated in the node: code execution an export reaches."
  @spec grade(String.t()) :: {term(), keyword()}
  def grade(answer), do: Code.eval_string(answer)

  @doc "The submitted tag, interned."
  @spec tag(String.t()) :: atom()
  def tag(name), do: String.to_atom(name)
end
