defmodule Argus.Analyses.SqlInjectionTest do
  use ExUnit.Case, async: true

  alias Argus.Analyses.UnsafeInput
  alias Argus.Test.Fixtures.SqlComments
  alias Argus.Test.Fixtures.SqlInjection
  alias Argus.Test.Fixtures.SqlRepoApplication
  alias Argus.Test.Fixtures.SqlRepoConstructed
  alias Argus.Test.Fixtures.SqlRepoGenerated
  alias Argus.Test.Fixtures.SqlRepoMixed
  alias Argus.Test.Fixtures.SqlRepoTwoCalls
  alias Argus.Test.Memo

  setup_all do
    {:ok, results} =
      Memo.analyze(
        [
          SqlInjection,
          SqlComments,
          SqlRepoGenerated,
          SqlRepoConstructed,
          SqlRepoMixed,
          SqlRepoTwoCalls,
          SqlRepoApplication
        ],
        :unsafe_input
      )

    %{rows: results["sql_injection"]}
  end

  test "generated Ecto Repo wrappers forward SQL as an API boundary", %{rows: rows} do
    refute Enum.any?(rows, fn [_, func, _] ->
             String.starts_with?(func, "#{inspect(SqlRepoGenerated)}:")
           end)

    refute Enum.any?(rows, fn [_, func, _] ->
             func == "#{inspect(SqlRepoMixed)}:query!/3"
           end)
  end

  test "generated interpolation and application queries remain reportable", %{rows: rows} do
    for {mod, function} <- [
          {SqlRepoConstructed, "query/3"},
          {SqlRepoConstructed, "query!/3"},
          {SqlRepoMixed, "query/3"},
          {SqlRepoApplication, "query/3"},
          {SqlRepoApplication, "direct/2"}
        ] do
      assert Enum.any?(rows, fn [_, func, _] -> func == "#{inspect(mod)}:#{function}" end),
             "#{inspect(mod)}:#{function}"
    end
  end

  test "forwarding at another generated call does not suppress construction", %{rows: rows} do
    assert Enum.any?(rows, fn [_, func, context] ->
             func == "#{inspect(SqlRepoTwoCalls)}:query/3" and context == "string"
           end)
  end

  test "SQL construction is checked at callers of the generated API", %{rows: rows} do
    for name <- ["through_repo/1", "through_default/1", "through_two_args/1"] do
      assert Enum.any?(rows, fn [_, func, context] ->
               func == "#{inspect(SqlRepoApplication)}:#{name}" and context == "string"
             end),
             name
    end

    for name <- ["repo_bound/1", "repo_literal/0", "unrelated_query/1"] do
      refute Enum.any?(rows, fn [_, func, _] ->
               func == "#{inspect(SqlRepoApplication)}:#{name}"
             end),
             name
    end
  end

  test "reports each SQL lexical context with its own explanation", %{rows: rows} do
    titles = for row <- rows, do: UnsafeInput.finding(:sql_injection, row).title

    assert "SQL injection through a quoted identifier" in titles
    assert "SQL injection through a dollar-quoted block" in titles
    assert "SQL injection through a query comment" in titles
    assert "SQL injection through an interpolated value" in titles
    assert "SQL injection through a dynamic statement" in titles

    assert Enum.all?(rows, fn row ->
             UnsafeInput.finding(:sql_injection, row).severity == :error
           end)
  end

  test "bound values, literal statements and correctly quoted identifiers are quiet", %{
    rows: rows
  } do
    for name <- [
          "bound/2",
          "literal/1",
          "escaped_identifier/2",
          "constant_helper/2",
          "fresh_dollar/2",
          "validated/1",
          "joined_literal_separator/2",
          "joined_empty/2",
          "joined_singleton/2",
          "joined_without_separator/2"
        ] do
      refute Enum.any?(rows, fn [_, func, _] -> String.ends_with?(func, ":#{name}") end), name
    end
  end
end
