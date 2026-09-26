defmodule Argus.Test.Soundness.G9.ExamWeb.GradeController do
  @moduledoc "A request reaches the grader."
  @behaviour Plug

  @doc false
  @spec init(term()) :: term()
  def init(o), do: o

  @doc false
  @spec call(map(), term()) :: map()
  def call(conn, _o) do
    Argus.Test.Soundness.G9.Exam.Test.Grader.tag(conn.params["tag"])
    conn
  end
end
